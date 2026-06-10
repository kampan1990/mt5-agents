"""
utils/indicators.py — Wrapper around pandas-ta for ADX and EMA.

Provides thin, tested wrappers so strategy modules do not import
pandas-ta directly.  All functions accept a pandas DataFrame with
columns [open, high, low, close, volume] and return scalar values
or Series.
"""

from __future__ import annotations

import pandas as pd


def compute_adx(df: pd.DataFrame, period: int = 14) -> pd.Series:
    """Compute ADX values using pandas-ta.

    Parameters
    ----------
    df:
        OHLCV DataFrame with columns: open, high, low, close.
    period:
        ADX lookback period.

    Returns
    -------
    pd.Series
        ADX values indexed identically to df.  NaN for the first
        (period * 2) rows during warmup.

    Notes
    -----
    pandas-ta adx() returns a DataFrame with columns:
        ADX_{period}, DMP_{period}, DMN_{period}
    This function returns only the ADX column.
    """
    import pandas_ta as ta  # lazy import to keep startup fast

    adx_df = ta.adx(df["high"], df["low"], df["close"], length=period)
    adx_col = f"ADX_{period}"
    if adx_df is None or adx_col not in adx_df.columns:
        return pd.Series([float("nan")] * len(df), index=df.index)
    return adx_df[adx_col]


def compute_ema(df: pd.DataFrame, period: int, column: str = "close") -> pd.Series:
    """Compute EMA for a given period on a DataFrame column.

    Parameters
    ----------
    df:
        DataFrame with at least the target column.
    period:
        EMA period.
    column:
        Column name to compute EMA on (default 'close').

    Returns
    -------
    pd.Series
        EMA values.
    """
    import pandas_ta as ta  # lazy import

    result = ta.ema(df[column], length=period)
    if result is None:
        return pd.Series([float("nan")] * len(df), index=df.index)
    return result


def latest_adx(df: pd.DataFrame, period: int = 14) -> float:
    """Return the most recent ADX value.

    Parameters
    ----------
    df:
        OHLCV DataFrame.
    period:
        ADX period.

    Returns
    -------
    float
        Latest ADX value.  Returns 0.0 if NaN (insufficient data).
    """
    series = compute_adx(df, period)
    val = series.iloc[-1]
    return 0.0 if pd.isna(val) else float(val)


def latest_ema(df: pd.DataFrame, period: int, column: str = "close") -> float:
    """Return the most recent EMA value.

    Parameters
    ----------
    df:
        OHLCV DataFrame.
    period:
        EMA period.
    column:
        Source column.

    Returns
    -------
    float
        Latest EMA value.  Returns 0.0 if NaN.
    """
    series = compute_ema(df, period, column)
    val = series.iloc[-1]
    return 0.0 if pd.isna(val) else float(val)
