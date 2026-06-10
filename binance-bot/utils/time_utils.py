"""
utils/time_utils.py — UTC timestamp helpers.

Thin wrappers around datetime to ensure the bot always operates in UTC
and to centralise any timestamp formatting used across modules.
"""

from __future__ import annotations

from datetime import datetime, timezone


def utcnow() -> datetime:
    """Return timezone-aware current UTC datetime."""
    return datetime.now(tz=timezone.utc)


def utc_date_str() -> str:
    """Return today's UTC date as 'YYYY-MM-DD' string.

    Used as the primary key in the daily_pnl table.
    """
    return utcnow().strftime("%Y-%m-%d")


def iso_now() -> str:
    """Return current UTC time as ISO-8601 string.

    Example: '2026-06-10T14:23:05.123456+00:00'
    """
    return utcnow().isoformat()


def ms_to_datetime(ms: int) -> datetime:
    """Convert a millisecond Unix timestamp to timezone-aware UTC datetime.

    Parameters
    ----------
    ms:
        Milliseconds since epoch (as returned by ccxt OHLCV timestamps).

    Returns
    -------
    datetime
        UTC-aware datetime object.
    """
    return datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc)
