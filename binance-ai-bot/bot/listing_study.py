"""Study: what happens to newly listed USDT-M perpetuals, and is fading them profitable?

Pipeline
  1. collect()      first ~41 days of 1h candles for every perpetual listed in the last N years
                    (live contracts from the REST API; delisted ones from data.binance.vision)
  2. milestones()   price path after listing (returns, run-up, fall from peak, excess vs BTC)
  3. simulate_short() rule-based "listing fade": short N hours after listing with a hard stop
  4. render_report() markdown report incl. an out-of-sample check on the parameter choice

Everything except collect() is pure and offline, so it is unit-testable.
Not modelled: funding payments, order-book depth (real slippage on thin new coins is worse than
the flat assumption), borrow/liquidation, Binance's changing leverage limits for new contracts.
"""
from __future__ import annotations

import io
import logging
import time
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from typing import Optional

import httpx
import numpy as np
import pandas as pd

from .binance_client import PUBLIC_DATA_URL, fetch_history
from .market_data import klines_to_df

log = logging.getLogger(__name__)

HORIZONS_H = (1, 6, 24, 72, 168, 336, 720)
ENTRY_DELAYS_H = (1, 3, 6, 12, 24, 48)
HOLD_H = (72, 168, 336)
SL_PCTS = (0.10, 0.20, 0.35)
FILTERS = ("none", "below_vwap")
FIRST_HOURS = 1000            # one klines request = ~41 days

S3_LIST = "https://s3-ap-northeast-1.amazonaws.com/data.binance.vision"
VISION = "https://data.binance.vision"
S3_NS = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}
VISION_UM_1H = "data/futures/um/monthly/klines/"


# ----------------------------------------------------------------------------
# data collection
# ----------------------------------------------------------------------------
def _get(client: httpx.Client, path: str, params: Optional[dict] = None, retries: int = 5):
    for attempt in range(retries):
        r = client.get(path, params=params)
        if r.status_code in (418, 429) or r.status_code >= 500:
            wait = float(r.headers.get("retry-after", 2 ** attempt))
            log.warning("HTTP %s on %s - sleeping %.0fs", r.status_code, path, wait)
            time.sleep(wait)
            continue
        r.raise_for_status()
        return r.json()
    raise RuntimeError(f"giving up on {path}")


def list_live_perpetuals(client: httpx.Client, since_ms: int) -> tuple[list[tuple[str, int]], set[str]]:
    """(symbol, onboardDate) of USDT perpetuals listed after since_ms, plus every symbol the API knows."""
    info = _get(client, "/fapi/v1/exchangeInfo")
    known = {s["symbol"] for s in info["symbols"]}
    out = [
        (s["symbol"], int(s["onboardDate"]))
        for s in info["symbols"]
        if s.get("contractType") == "PERPETUAL" and s.get("quoteAsset") == "USDT"
        and int(s["onboardDate"]) >= since_ms
    ]
    return sorted(out, key=lambda x: x[1]), known


def fetch_first_hours(client: httpx.Client, symbol: str, onboard_ms: int) -> Optional[pd.DataFrame]:
    rows = _get(client, "/fapi/v1/klines", {"symbol": symbol, "interval": "1h",
                                            "startTime": onboard_ms, "limit": FIRST_HOURS})
    now = int(time.time() * 1000)
    rows = [r for r in rows if r[6] < now]
    return klines_to_df(rows) if rows else None


def s3_list(http: httpx.Client, prefix: str) -> tuple[list[str], list[str]]:
    """List a data.binance.vision 'directory' -> (sub-prefixes, object keys)."""
    prefixes: list[str] = []
    keys: list[str] = []
    marker = None
    while True:
        params = {"prefix": prefix, "delimiter": "/"}
        if marker:
            params["marker"] = marker
        r = http.get(S3_LIST, params=params)
        r.raise_for_status()
        root = ET.fromstring(r.content)
        prefixes += [p.text for p in root.findall("s3:CommonPrefixes/s3:Prefix", S3_NS)]
        keys += [k.text for k in root.findall("s3:Contents/s3:Key", S3_NS)]
        if root.findtext("s3:IsTruncated", namespaces=S3_NS) != "true":
            return prefixes, keys
        marker = root.findtext("s3:NextMarker", namespaces=S3_NS) or (keys or prefixes)[-1]


def parse_vision_zip(content: bytes) -> list[list]:
    with zipfile.ZipFile(io.BytesIO(content)) as z:
        text = z.read(z.namelist()[0]).decode()
    rows = []
    for line in text.splitlines():
        p = line.split(",")
        if len(p) < 12 or not p[0].strip().isdigit():      # header or junk
            continue
        open_t, close_t = int(p[0]), int(p[6])
        if open_t > 10 ** 14:                               # microseconds in newer archives
            open_t, close_t = open_t // 1000, close_t // 1000
        rows.append([open_t, *p[1:6], close_t, *p[7:12]])
    return rows


def list_vision_perpetuals(http: httpx.Client) -> list[str]:
    prefixes, _ = s3_list(http, VISION_UM_1H)
    names = [p.rstrip("/").split("/")[-1] for p in prefixes]
    return [n for n in names if n.endswith("USDT") and "_" not in n]   # drop delivery contracts


def fetch_vision_first_frame(http: httpx.Client, symbol: str, since_month: str) -> Optional[pd.DataFrame]:
    _, keys = s3_list(http, f"{VISION_UM_1H}{symbol}/1h/")
    zips = sorted(k for k in keys if k.endswith(".zip"))
    if not zips or zips[0][-11:-4] < since_month:           # listed before the study window
        return None
    rows: list[list] = []
    for key in zips[:2]:                                    # listing month + next month (>= 31 days)
        r = http.get(f"{VISION}/{key}")
        r.raise_for_status()
        rows += parse_vision_zip(r.content)
    return klines_to_df(rows[:FIRST_HOURS]) if rows else None


def collect(years: float, include_delisted: bool, cache_dir: str = "data/listings") -> dict[str, tuple[pd.DataFrame, str]]:
    """symbol -> (first-hours frame, source) with source in {'live', 'delisted'}."""
    cache = Path(cache_dir)
    since_ms = int((time.time() - years * 365 * 86400) * 1000)
    since_month = pd.to_datetime(since_ms, unit="ms").strftime("%Y-%m")
    out: dict[str, tuple[pd.DataFrame, str]] = {}

    def cached(symbol: str, source: str, loader):
        path = cache / source / f"{symbol}.csv"
        if path.exists():
            return pd.read_csv(path, index_col=0, parse_dates=True)
        df = loader()
        if df is not None and len(df):
            path.parent.mkdir(parents=True, exist_ok=True)
            df[["open", "high", "low", "close", "volume"]].to_csv(path)
            return df[["open", "high", "low", "close", "volume"]]
        return None

    with httpx.Client(base_url=PUBLIC_DATA_URL, timeout=20) as api:
        live, known = list_live_perpetuals(api, since_ms)
        log.info("%d live USDT perpetuals listed in the last %.1f years", len(live), years)
        for i, (sym, onboard) in enumerate(live, 1):
            df = cached(sym, "live", lambda: fetch_first_hours(api, sym, onboard))
            if df is not None and len(df) >= 24:
                out[sym] = (df[["open", "high", "low", "close", "volume"]], "live")
            time.sleep(0.12)
            if i % 25 == 0:
                log.info("live %d/%d", i, len(live))

    if include_delisted:
        with httpx.Client(timeout=60, follow_redirects=True) as http:
            gone = sorted(set(list_vision_perpetuals(http)) - known)
            log.info("%d archived symbols no longer listed - checking which are in the window", len(gone))
            for i, sym in enumerate(gone, 1):
                try:
                    df = cached(sym, "delisted", lambda: fetch_vision_first_frame(http, sym, since_month))
                except httpx.HTTPError as e:
                    log.warning("%s: %s", sym, e)
                    continue
                if df is not None and len(df) >= 24:
                    out[sym] = (df, "delisted")
                if i % 25 == 0:
                    log.info("delisted %d/%d", i, len(gone))
    return out


def fetch_btc(years: float) -> pd.DataFrame:
    rows = fetch_history("BTCUSDT", "1h", int(years * 365) + 60)
    return klines_to_df(rows)[["open", "high", "low", "close", "volume"]]


# ----------------------------------------------------------------------------
# analysis (pure)
# ----------------------------------------------------------------------------
def milestones(df: pd.DataFrame, btc: Optional[pd.DataFrame] = None) -> dict:
    """Price path of one coin relative to its first open."""
    p0 = float(df["open"].iloc[0])
    hi24 = df["high"].iloc[:24].to_numpy()
    peak72 = float(df["high"].iloc[:72].max())
    row: dict = {
        "listed_at": df.index[0], "bars": len(df), "first_open": p0,
        "runup_24h_pct": (hi24.max() / p0 - 1) * 100,
        "peak_hour_24h": int(hi24.argmax()) + 1,
    }
    i0 = None
    if btc is not None:
        i = int(btc.index.searchsorted(df.index[0]))
        if i < len(btc) and btc.index[i] == df.index[0]:
            i0 = i
    for h in HORIZONS_H:
        if len(df) < h:
            continue
        c = float(df["close"].iloc[h - 1])
        row[f"ret_{h}h_pct"] = (c / p0 - 1) * 100
        if h >= 72:
            row[f"from_peak72_at_{h}h_pct"] = (c / peak72 - 1) * 100
        if i0 is not None and i0 + h - 1 < len(btc):
            b = (float(btc["close"].iloc[i0 + h - 1]) / float(btc["open"].iloc[i0]) - 1) * 100
            row[f"excess_{h}h_pct"] = row[f"ret_{h}h_pct"] - b
    return row


def simulate_short(df: pd.DataFrame, delay_h: int, hold_h: int, sl_pct: float,
                   fee_rate: float = 0.0005, slip: float = 0.0005, filt: str = "none") -> Optional[dict]:
    """Short at the close of hour `delay_h` after listing; hard SL; exit on SL or after `hold_h` hours.

    Conservative: if a bar's high reaches the stop the stop fills first (at the bar open when it gapped
    above). Returns None when the entry filter blocks the trade or not enough data exists.
    """
    e = delay_h - 1
    if len(df) < e + 1 + hold_h:
        return None
    close, high, opn = df["close"].to_numpy(), df["high"].to_numpy(), df["open"].to_numpy()
    if filt == "below_vwap":
        vol = df["volume"].to_numpy()
        typical = (df["high"].to_numpy() + df["low"].to_numpy() + close) / 3
        denom = vol[: e + 1].sum()
        if denom <= 0 or close[e] >= (typical[: e + 1] * vol[: e + 1]).sum() / denom:
            return None
    entry = close[e] * (1 - slip)
    stop = entry * (1 + sl_pct)
    seg_hi = high[e + 1: e + 1 + hold_h]
    hit = np.nonzero(seg_hi >= stop)[0]
    if hit.size:
        k = int(hit[0])
        exit_price = max(stop, opn[e + 1 + k]) * (1 + slip)
        reason, mae = "SL", seg_hi[: k + 1].max() / entry - 1
    else:
        exit_price = close[e + hold_h] * (1 + slip)
        reason, mae = "TIME", seg_hi.max() / entry - 1
    return {"ret": (entry - exit_price) / entry - 2 * fee_rate, "reason": reason, "mae": mae}


def run_study(frames: dict[str, tuple[pd.DataFrame, str]], btc: Optional[pd.DataFrame] = None,
              fee_rate: float = 0.0005, slip: float = 0.0005) -> tuple[pd.DataFrame, pd.DataFrame]:
    ms_rows, trades = [], []
    for sym, (df, source) in frames.items():
        ms_rows.append({"symbol": sym, "source": source, **milestones(df, btc)})
        for filt in FILTERS:
            for delay in ENTRY_DELAYS_H:
                for hold in HOLD_H:
                    for sl in SL_PCTS:
                        t = simulate_short(df, delay, hold, sl, fee_rate, slip, filt)
                        if t:
                            trades.append({"symbol": sym, "source": source, "listed_at": df.index[0],
                                           "filter": filt, "delay_h": delay, "hold_h": hold, "sl_pct": sl, **t})
    ms = pd.DataFrame(ms_rows)
    tr = pd.DataFrame(trades)
    if not ms.empty:
        ms = ms.sort_values("listed_at").reset_index(drop=True)
    return ms, tr


CONFIG = ["filter", "delay_h", "hold_h", "sl_pct"]


def summarize(trades: pd.DataFrame, by: Optional[list[str]] = None) -> pd.DataFrame:
    by = by or CONFIG

    def agg(g: pd.DataFrame) -> pd.Series:
        r = g["ret"]
        losses = -r[r <= 0].sum()
        return pd.Series({
            "n": len(g),
            "mean_pct": r.mean() * 100,
            "median_pct": r.median() * 100,
            "win_pct": (r > 0).mean() * 100,
            "profit_factor": r[r > 0].sum() / losses if losses > 0 else np.inf,
            "sl_hit_pct": (g["reason"] == "SL").mean() * 100,
            "avg_mae_pct": g["mae"].mean() * 100,
            "worst_pct": r.min() * 100,
            "p5_pct": r.quantile(0.05) * 100,
        })

    if trades.empty:
        return pd.DataFrame()
    out = trades.groupby(by).apply(agg, include_groups=False).reset_index()
    out["n"] = out["n"].astype(int)
    return out


def walk_forward(trades: pd.DataFrame, min_n: int = 20) -> Optional[dict]:
    """Choose the best config on the earlier half of listings, report it on the later half."""
    if trades.empty:
        return None
    cut = trades.drop_duplicates("symbol")["listed_at"].sort_values().median()   # split coins, not trades
    train, test = trades[trades["listed_at"] < cut], trades[trades["listed_at"] >= cut]
    s = summarize(train)
    s = s[s["n"] >= min_n]
    if s.empty or test.empty:
        return None
    best = s.sort_values("mean_pct", ascending=False).iloc[0]
    cfg = {k: best[k] for k in CONFIG}
    mask = np.ones(len(test), dtype=bool)
    for k, v in cfg.items():
        mask &= (test[k] == v).to_numpy()
    out_sample = test[mask]
    return {"config": cfg, "train": best.to_dict(),
            "test": summarize(out_sample).iloc[0].to_dict() if len(out_sample) else None, "cut": cut}


# ----------------------------------------------------------------------------
# report
# ----------------------------------------------------------------------------
def _fmt(x) -> str:
    if isinstance(x, (float, np.floating)):
        return "inf" if np.isinf(x) else f"{x:.2f}"
    return str(x)


def md_table(df: pd.DataFrame) -> str:
    if df.empty:
        return "_no data_\n"
    head = "| " + " | ".join(df.columns) + " |\n|" + "---|" * len(df.columns) + "\n"
    return head + "".join("| " + " | ".join(_fmt(v) for v in row) + " |\n" for row in df.itertuples(index=False))


def render_report(ms: pd.DataFrame, trades: pd.DataFrame, fee_rate: float, slip: float) -> str:
    out = ["# New-listing study (Binance USDT-M perpetuals)\n"]
    n_del = int((ms["source"] == "delisted").sum()) if not ms.empty else 0
    out.append(f"- Coins analysed: **{len(ms)}** (live {len(ms) - n_del}, delisted {n_del})")
    if not ms.empty:
        out.append(f"- Listings from {ms['listed_at'].min():%Y-%m-%d} to {ms['listed_at'].max():%Y-%m-%d}")
    out.append(f"- Costs assumed: taker fee {fee_rate * 100:.2f}% per side, slippage {slip * 100:.2f}% per fill; funding NOT included")
    if n_del == 0:
        out.append("- ⚠️ **No delisted coins included** - survivorship bias will flatter any 'short the new coin' result. "
                   "Re-run with `--include-delisted`.")
    out.append("")

    out.append("## 1. Price path after listing (return vs first open)\n")
    rows = []
    for h in HORIZONS_H:
        c = f"ret_{h}h_pct"
        if c not in ms:
            continue
        x = ms[c].dropna()
        row = {"after": f"{h}h", "n": len(x), "median_%": x.median(), "mean_%": x.mean(),
               "down_%_of_coins": (x < 0).mean() * 100, "p10_%": x.quantile(.1), "p90_%": x.quantile(.9)}
        e = ms.get(f"excess_{h}h_pct")
        row["median_excess_vs_BTC_%"] = e.dropna().median() if e is not None and e.notna().any() else np.nan
        rows.append(row)
    out.append(md_table(pd.DataFrame(rows)))

    out.append("## 2. The initial pump\n")
    if not ms.empty:
        r = ms["runup_24h_pct"]
        out.append(f"- Median max run-up in first 24h: **{r.median():.1f}%** (p25 {r.quantile(.25):.1f}%, p75 {r.quantile(.75):.1f}%, p95 {r.quantile(.95):.1f}%)")
        out.append(f"- Median hour of the 24h peak: **{ms['peak_hour_24h'].median():.0f}h** after listing")
        for h in (168, 720):
            c = f"from_peak72_at_{h}h_pct"
            if c in ms:
                out.append(f"- Median position at {h // 24}d relative to the 72h peak: **{ms[c].median():.1f}%**")
        out.append("")

    out.append("## 3. 'Listing fade' short simulation\n")
    if trades.empty:
        out.append("_no trades_\n")
        return "\n".join(out)
    s = summarize(trades)
    big = s[s["n"] >= 30].sort_values("mean_pct", ascending=False)
    out.append("Top configs by mean return per trade (n >= 30). **These are the best of "
               f"{len(s)} tried - optimistic by construction (data snooping); use section 4.**\n")
    out.append(md_table(big.head(10)))
    out.append("Worst configs, for contrast:\n")
    out.append(md_table(big.tail(3)))

    out.append("## 4. Out-of-sample check\n")
    wf = walk_forward(trades)
    if wf is None:
        out.append("_not enough data_\n")
    else:
        out.append(f"Best config chosen on listings before {wf['cut']:%Y-%m-%d}, then scored on listings after:\n")
        cfg = {k: (v.item() if hasattr(v, "item") else v) for k, v in wf["config"].items()}
        out.append(f"- Config: `{cfg}`")
        out.append(f"- In-sample: n={wf['train']['n']:.0f}, mean {wf['train']['mean_pct']:.2f}%, win {wf['train']['win_pct']:.0f}%")
        t = wf["test"]
        out.append(f"- **Out-of-sample**: " + (f"n={t['n']:.0f}, mean {t['mean_pct']:.2f}%, win {t['win_pct']:.0f}%, "
                   f"PF {_fmt(t['profit_factor'])}, worst trade {t['worst_pct']:.1f}%" if t else "no trades"))
        out.append("")

    if n_del:
        out.append("## 5. Survivorship check (same configs, live vs delisted)\n")
        top = big.head(3)
        rows = []
        for _, c in top.iterrows():
            sub = trades
            for k in CONFIG:
                sub = sub[sub[k] == c[k]]
            for src, g in sub.groupby("source"):
                rows.append({**{k: c[k] for k in CONFIG}, "source": src, "n": len(g),
                             "mean_%": g["ret"].mean() * 100, "win_%": (g["ret"] > 0).mean() * 100})
        out.append(md_table(pd.DataFrame(rows)))

    out.append("## Reading this report\n")
    out.append("- A real edge needs: positive out-of-sample mean, similar results for delisted coins, and a worst-case "
               "trade you can survive (stop gaps on thin books are worse than simulated).")
    out.append("- If section 1 shows coins falling but median excess vs BTC near 0, the 'edge' is just the market.")
    return "\n".join(out)


def save_plot(ms: pd.DataFrame, frames: dict, path: Path) -> bool:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return False
    n = 168
    paths = [(df["close"].iloc[:n] / df["open"].iloc[0] * 100).to_numpy() for df, _ in frames.values() if len(df) >= n]
    if not paths:
        return False
    arr = np.vstack(paths)
    fig, ax = plt.subplots(figsize=(9, 5))
    ax.fill_between(range(1, n + 1), np.percentile(arr, 25, axis=0), np.percentile(arr, 75, axis=0), alpha=.25, label="p25-p75")
    ax.plot(range(1, n + 1), np.median(arr, axis=0), label="median")
    ax.axhline(100, color="grey", lw=.8)
    ax.set_xlabel("hours after listing"); ax.set_ylabel("price (listing open = 100)")
    ax.set_title(f"First 7 days after listing, {len(arr)} coins"); ax.legend()
    fig.savefig(path, dpi=130, bbox_inches="tight")
    plt.close(fig)
    return True
