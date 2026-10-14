"""Technical indicators on pandas OHLCV frames (columns: open, high, low, close, volume)."""
from __future__ import annotations

import pandas as pd


def ema(series: pd.Series, period: int) -> pd.Series:
    return series.ewm(span=period, adjust=False).mean()


def rsi(close: pd.Series, period: int = 14) -> pd.Series:
    delta = close.diff()
    gain = delta.clip(lower=0).ewm(alpha=1 / period, adjust=False).mean()
    loss = (-delta.clip(upper=0)).ewm(alpha=1 / period, adjust=False).mean()
    out = 100 - 100 / (1 + gain / loss)
    out = out.where(loss != 0, 100.0)
    return out.where((gain != 0) | (loss != 0), 50.0)


def atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    prev_close = df["close"].shift(1)
    tr = pd.concat(
        [df["high"] - df["low"], (df["high"] - prev_close).abs(), (df["low"] - prev_close).abs()],
        axis=1,
    ).max(axis=1)
    return tr.ewm(alpha=1 / period, adjust=False).mean()


def macd(close: pd.Series, fast: int = 12, slow: int = 26, signal: int = 9) -> tuple[pd.Series, pd.Series, pd.Series]:
    line = ema(close, fast) - ema(close, slow)
    sig = ema(line, signal)
    return line, sig, line - sig


def bollinger_position(close: pd.Series, period: int = 20, k: float = 2.0) -> pd.Series:
    """0 = at lower band, 1 = at upper band."""
    mid = close.rolling(period).mean()
    std = close.rolling(period).std()
    upper, lower = mid + k * std, mid - k * std
    return (close - lower) / (upper - lower)


def resample_ohlcv(df: pd.DataFrame, rule: str) -> pd.DataFrame:
    """Resample a DatetimeIndex OHLCV frame to a higher timeframe."""
    return (
        df.resample(rule, label="left", closed="left")
        .agg({"open": "first", "high": "max", "low": "min", "close": "last", "volume": "sum"})
        .dropna()
    )
