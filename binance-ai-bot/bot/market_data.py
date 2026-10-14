"""Turn raw candles into the feature snapshot a decision engine sees.

The same function is used by the backtester and the live trader so both see
identical inputs. Only closed candles must be passed in (no lookahead).
"""
from __future__ import annotations

from typing import Optional

import numpy as np
import pandas as pd

from . import indicators as ind
from .models import MarketSnapshot, PositionInfo

HIGHER_TF = {"5m": "1h", "15m": "1h", "30m": "4h", "1h": "4h", "2h": "1D", "4h": "1D"}
LOOKBACK_BARS = 400   # enough for EMA200 + warmup
RECENT_CANDLES = 24


def _r(x: float, nd: int = 2) -> float:
    return None if x is None or not np.isfinite(x) else round(float(x), nd)


def _tf_features(df: pd.DataFrame) -> dict:
    close = df["close"]
    last = close.iloc[-1]
    a = ind.atr(df).iloc[-1]
    _, _, hist = ind.macd(close)
    vol_avg = df["volume"].rolling(20).mean().iloc[-1]

    def ret(n: int) -> Optional[float]:
        return _r((last / close.iloc[-1 - n] - 1) * 100) if len(close) > n else None

    def dist(period: int) -> Optional[float]:
        if len(close) < period:
            return None
        return _r((last / ind.ema(close, period).iloc[-1] - 1) * 100)

    return {
        "return_pct": {"1bar": ret(1), "4bar": ret(4), "24bar": ret(24)},
        "dist_from_ema_pct": {"ema20": dist(20), "ema50": dist(50), "ema200": dist(200)},
        "rsi14": _r(ind.rsi(close).iloc[-1], 1),
        "atr14_pct": _r(a / last * 100, 3),
        "macd_hist_atr": _r(hist.iloc[-1] / a, 3) if a else None,
        "bollinger_pos": _r(ind.bollinger_position(close).iloc[-1], 2),
        "volume_vs_20avg": _r(df["volume"].iloc[-1] / vol_avg, 2) if vol_avg else None,
    }


def build_snapshot(
    df: pd.DataFrame,
    symbol: str,
    interval: str,
    position: Optional[PositionInfo] = None,
    funding_rate: Optional[float] = None,
    anonymize: bool = True,
) -> MarketSnapshot:
    """df: closed candles with DatetimeIndex and open/high/low/close/volume columns."""
    df = df.iloc[-LOOKBACK_BARS:]
    price = float(df["close"].iloc[-1])
    atr_val = float(ind.atr(df).iloc[-1])

    # Recent candles expressed relative to the last close (= 100) and ATR, so the
    # model can read structure without seeing absolute prices.
    recent = df.iloc[-RECENT_CANDLES:]
    candles = [
        [_r(o / price * 100, 2), _r(h / price * 100, 2), _r(l / price * 100, 2), _r(c / price * 100, 2)]
        for o, h, l, c in recent[["open", "high", "low", "close"]].itertuples(index=False)
    ]

    features: dict = {
        "interval": interval,
        "primary": _tf_features(df),
        "recent_candles_ohlc_rebased": candles,
    }
    higher = HIGHER_TF.get(interval)
    if higher:
        hdf = ind.resample_ohlcv(df, higher)
        if len(hdf) >= 30:
            features["higher_tf"] = {"interval": higher, **_tf_features(hdf)}
    if funding_rate is not None:
        features["funding_rate_pct"] = _r(funding_rate * 100, 4)
    if position is not None:
        direction = 1 if position.side == "LONG" else -1
        features["position"] = {
            "side": position.side,
            "pnl_pct": _r((price / position.entry_price - 1) * 100 * direction),
            "pnl_atr": _r((price - position.entry_price) * direction / atr_val, 2) if atr_val else None,
            "bars_held": position.bars_held,
        }
    else:
        features["position"] = None
    if not anonymize:
        features["symbol"] = symbol
        features["last_price"] = price
        features["time_utc"] = str(df.index[-1])

    return MarketSnapshot(symbol=symbol, price=price, atr=atr_val, features=features, position=position)


def klines_to_df(rows: list[list]) -> pd.DataFrame:
    """Convert Binance kline rows to a DataFrame indexed by open time (UTC)."""
    df = pd.DataFrame(
        rows,
        columns=["open_time", "open", "high", "low", "close", "volume", "close_time",
                 "quote_volume", "trades", "taker_base", "taker_quote", "ignore"],
    )
    df = df[["open_time", "open", "high", "low", "close", "volume", "close_time"]]
    for col in ["open", "high", "low", "close", "volume"]:
        df[col] = df[col].astype(float)
    df["open_time"] = pd.to_datetime(df["open_time"], unit="ms", utc=True)
    df["close_time"] = df["close_time"].astype("int64")
    return df.set_index("open_time")
