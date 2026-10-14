import io
import zipfile

import httpx
import numpy as np
import pandas as pd
import pytest

from bot import listing_study as ls


def coin(path, start="2025-03-01", vol=100.0, wick=0.002):
    """Build a 1h frame from a list of closes (open = previous close)."""
    close = np.asarray(path, dtype=float)
    opn = np.r_[close[0], close[:-1]]
    idx = pd.date_range(start, periods=len(close), freq="1h", tz="UTC")
    return pd.DataFrame({"open": opn, "high": np.maximum(opn, close) * (1 + wick),
                         "low": np.minimum(opn, close) * (1 - wick), "close": close,
                         "volume": np.full(len(close), vol)}, index=idx)


def pump_dump(n=800, peak_h=6, peak=2.0, end=0.5):
    up = np.linspace(1.0, peak, peak_h)
    down = np.linspace(peak, end, n - peak_h)
    return coin(np.r_[up, down])


def pump_moon(n=800):
    return coin(np.linspace(1.0, 4.0, n))


def test_milestones_pump_dump():
    m = ls.milestones(pump_dump())
    assert m["runup_24h_pct"] > 100
    assert m["peak_hour_24h"] in (6, 7)
    assert -40 < m["ret_720h_pct"] < -30   # linear 2.0 -> 0.5 over ~794 bars
    assert m["from_peak72_at_168h_pct"] < 0
    assert "excess_24h_pct" not in m            # no BTC given


def test_milestones_excess_vs_btc():
    df = coin(np.linspace(1, 2, 800))
    btc = coin(np.linspace(100, 110, 1200), start="2025-02-28")
    m = ls.milestones(df, btc)
    assert m["excess_24h_pct"] == pytest.approx(m["ret_24h_pct"] - (btc["close"].iloc[24 + 23] / btc["open"].iloc[24] - 1) * 100)


def test_short_wins_on_dump_and_loses_on_moon():
    win = ls.simulate_short(pump_dump(), delay_h=12, hold_h=168, sl_pct=0.35)
    assert win["reason"] == "TIME" and win["ret"] > 0.1
    loss = ls.simulate_short(pump_moon(), delay_h=12, hold_h=168, sl_pct=0.10)
    assert loss["reason"] == "SL"
    assert -0.16 < loss["ret"] < -0.09          # ~ -10% stop + costs, bounded
    assert loss["mae"] >= 0.10


def test_stop_fills_at_gap_open_not_at_stop():
    close = np.r_[np.full(12, 1.0), 1.0, 1.5, 1.5, 1.5]
    df = coin(close)
    df.loc[df.index[13], "open"] = 1.5          # gap above a 10% stop
    t = ls.simulate_short(df, delay_h=12, hold_h=3, sl_pct=0.10, fee_rate=0, slip=0)
    assert t["reason"] == "SL" and t["ret"] == pytest.approx(-0.5)


def test_not_enough_data_returns_none():
    assert ls.simulate_short(pump_dump(n=100), delay_h=24, hold_h=168, sl_pct=0.2) is None


def test_vwap_filter_blocks_entry_above_vwap():
    df = pump_moon()
    assert ls.simulate_short(df, 12, 72, 0.2, filt="below_vwap") is None        # rising -> price above VWAP
    fast_dump = coin(np.r_[np.linspace(1.0, 2.0, 3), np.linspace(2.0, 1.2, 9), np.full(800, 1.2)])
    assert ls.simulate_short(fast_dump, 12, 72, 0.2, filt="below_vwap") is not None   # close 1.2 < VWAP


def test_no_lookahead_in_entry_filter():
    """The VWAP filter at hour 12 must not depend on later bars."""
    a = coin(np.r_[np.linspace(1.0, 2.0, 3), np.linspace(2.0, 1.2, 9), np.full(800, 1.2)])
    b = a.copy()
    b.iloc[20:, :4] *= 3
    ta = ls.simulate_short(a, 12, 5, 0.9, filt="below_vwap")
    tb = ls.simulate_short(b, 12, 5, 0.9, filt="below_vwap")
    assert (ta is None) == (tb is None)


def build_frames(n=60):
    rng = np.random.default_rng(1)
    frames = {}
    for i in range(n):
        start = (pd.Timestamp("2024-01-01", tz="UTC") + pd.Timedelta(days=10 * i)).strftime("%Y-%m-%d")
        df = pump_dump(peak=1.5 + rng.random()) if i % 4 else pump_moon()
        df.index = pd.date_range(start, periods=len(df), freq="1h", tz="UTC")
        frames[f"C{i}USDT"] = (df, "delisted" if i % 5 == 0 else "live")
    return frames


def test_run_study_summary_walkforward_and_report():
    ms, trades = ls.run_study(build_frames())
    assert len(ms) == 60 and not trades.empty
    s = ls.summarize(trades)
    assert {"mean_pct", "win_pct", "profit_factor", "worst_pct"} <= set(s.columns)
    wf = ls.walk_forward(trades)
    assert wf is not None and wf["test"] is not None
    rep = ls.render_report(ms, trades, 0.0005, 0.0005)
    for section in ("Price path after listing", "The initial pump", "Out-of-sample", "Survivorship check"):
        assert section in rep


def test_report_warns_without_delisted():
    frames = {k: (v[0], "live") for k, v in build_frames(24).items()}
    ms, trades = ls.run_study(frames)
    assert "No delisted coins included" in ls.render_report(ms, trades, 0.0005, 0.0005)


# ---- data.binance.vision parsing (mocked network) ---------------------------------
def vision_zip(rows, header=True, micro=False):
    lines = ["open_time,open,high,low,close,volume,close_time,quote_volume,count,taker_buy_volume,taker_buy_quote_volume,ignore"] if header else []
    for t, p in rows:
        o, c = (t * 1000, (t + 3_599_999) * 1000) if micro else (t, t + 3_599_999)
        lines.append(f"{o},{p},{p * 1.01},{p * 0.99},{p},10,{c},0,1,0,0,0")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("x.csv", "\n".join(lines))
    return buf.getvalue()


T0 = 1_740_000_000_000


def test_parse_vision_zip_header_and_microseconds():
    rows = [(T0 + i * 3_600_000, 1.0 + i / 100) for i in range(3)]
    for micro in (False, True):
        for header in (True, False):
            parsed = ls.parse_vision_zip(vision_zip(rows, header=header, micro=micro))
            assert len(parsed) == 3 and parsed[0][0] == T0 and len(parsed[0]) == 12
    df = ls.klines_to_df(ls.parse_vision_zip(vision_zip(rows)))
    assert df["close"].iloc[2] == pytest.approx(1.02)


def s3_xml(prefixes=(), keys=(), truncated=False, next_marker=None):
    ns = "http://s3.amazonaws.com/doc/2006-03-01/"
    body = f'<ListBucketResult xmlns="{ns}"><IsTruncated>{str(truncated).lower()}</IsTruncated>'
    if next_marker:
        body += f"<NextMarker>{next_marker}</NextMarker>"
    body += "".join(f"<CommonPrefixes><Prefix>{p}</Prefix></CommonPrefixes>" for p in prefixes)
    body += "".join(f"<Contents><Key>{k}</Key></Contents>" for k in keys)
    return body + "</ListBucketResult>"


def test_vision_listing_pagination_and_first_frame():
    base = ls.VISION_UM_1H
    zips = {
        f"{base}NEWUSDT/1h/NEWUSDT-1h-2025-03.zip": vision_zip([(T0 + i * 3_600_000, 1 + i / 1000) for i in range(500)]),
        f"{base}NEWUSDT/1h/NEWUSDT-1h-2025-04.zip": vision_zip([(T0 + (500 + i) * 3_600_000, 2.0) for i in range(500)]),
    }

    def handler(req: httpx.Request):
        url = str(req.url)
        if url.startswith(ls.S3_LIST):
            q = dict(req.url.params)
            if q["prefix"] == base:
                if "marker" not in q:
                    return httpx.Response(200, text=s3_xml(prefixes=[f"{base}AAAUSDT/", f"{base}BBBUSDT_240628/"], truncated=True, next_marker="m1"))
                return httpx.Response(200, text=s3_xml(prefixes=[f"{base}NEWUSDT/", f"{base}XYZUSDC/"]))
            keys = sorted(zips) + [k + ".CHECKSUM" for k in sorted(zips)]
            return httpx.Response(200, text=s3_xml(keys=keys))
        key = url.removeprefix(ls.VISION + "/")
        return httpx.Response(200, content=zips[key])

    http = httpx.Client(transport=httpx.MockTransport(handler))
    syms = ls.list_vision_perpetuals(http)
    assert syms == ["AAAUSDT", "NEWUSDT"]          # paginated; delivery + non-USDT dropped

    df = ls.fetch_vision_first_frame(http, "NEWUSDT", since_month="2025-01")
    assert len(df) == ls.FIRST_HOURS and df.index[0] == pd.to_datetime(T0, unit="ms", utc=True)
    assert ls.fetch_vision_first_frame(http, "NEWUSDT", since_month="2025-06") is None   # listed before window
