"""
news_filter.py — high-impact economic calendar blackout check.

This is the BRIDGE-side news filter: it should stop the bridge from asking GLM
for (or acting on) a fresh signal around high-impact USD news events, so the
bridge doesn't burn API calls / generate a signal right into a volatility
spike. This is independent of — and in addition to — the EA's own native
MQL5-Calendar-based InpEnableNewsFilter check (defense in depth: two different
data sources, two different processes).

TODO(integration): no economic calendar data source is wired up yet. Pick one
and implement `_fetch_upcoming_high_impact_events()`:
  - A paid calendar API (e.g. TradingEconomics, Finnhub, FMP) — recommended for
    production reliability.
  - Scraping a public calendar (fragile, breaks often, mind ToS).
  - Reuse MT5's own calendar via the MetaTrader5 python package IF the bridge
    runs on the same machine as the terminal (mirrors what the EA does natively
    in RiskManager.mqh — could literally source events via mt5.calendar if
    that API is exposed in future MetaTrader5 package versions).

Until wired up, is_news_blackout() always returns False (fail-open on this
specific check) — the EA's native calendar filter is still an independent
backstop, so this is not the only line of defense.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

logger = logging.getLogger("xauglm.news_filter")


@dataclass
class EconomicEvent:
    event_id: str
    name: str
    country_currency: str  # e.g. "USD"
    time_utc: datetime
    importance: str  # "LOW" | "MEDIUM" | "HIGH"


def _fetch_upcoming_high_impact_events(
    currency: str, window_start_utc: datetime, window_end_utc: datetime
) -> list[EconomicEvent]:
    """
    TODO(integration): replace this stub with a real economic-calendar data
    source (see module docstring). Must return HIGH-importance events for
    `currency` whose time_utc falls within [window_start_utc, window_end_utc].
    """
    logger.debug(
        "news_filter: no economic calendar data source configured yet — "
        "returning no events (fail-open on this specific check)."
    )
    return []


def is_news_blackout(currency: str, buffer_minutes: int, enabled: bool = True) -> bool:
    """Return True if a HIGH-importance event for `currency` falls within
    +/- buffer_minutes of now (UTC). Never raises — a data-source failure here
    must not stop the bridge loop; it degrades to 'not in blackout' with a
    logged warning, relying on the EA's own independent news filter."""
    if not enabled:
        return False

    now = datetime.now(timezone.utc)
    window_start = now - timedelta(minutes=buffer_minutes)
    window_end = now + timedelta(minutes=buffer_minutes)

    try:
        events = _fetch_upcoming_high_impact_events(currency, window_start, window_end)
    except Exception as exc:  # defensive: never let this take the bridge down
        logger.warning("news_filter: failed to fetch calendar events (%s) — treating as no blackout.", exc)
        return False

    if events:
        names = ", ".join(e.name for e in events)
        logger.info("news_filter: blackout window active due to: %s", names)
        return True

    return False
