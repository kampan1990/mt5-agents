"""
market_data.py — XAUUSD OHLCV + indicator context for the GLM prompt.

Primary data source: the official `MetaTrader5` Python package, which talks to
a locally-running MT5 terminal over IPC. This is the natural choice since the
EA already runs inside MT5 on the same machine (or the same Windows session).

If that package is not installed / no terminal is reachable, every public
function here raises MarketDataUnavailableError with a clear TODO pointing at
where a different data source (broker REST API, a market-data vendor, ccxt,
etc.) would need to be integrated. main.py treats that as "skip this cycle,
try again next poll" — it must never crash the bridge loop.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from typing import Any

logger = logging.getLogger("xauglm.market_data")

try:
    import MetaTrader5 as mt5  # type: ignore

    _MT5_AVAILABLE = True
except ImportError:  # pragma: no cover - environment dependent
    mt5 = None  # type: ignore
    _MT5_AVAILABLE = False


class MarketDataUnavailableError(RuntimeError):
    pass


@dataclass
class OhlcvBar:
    time_utc: str
    open: float
    high: float
    low: float
    close: float
    volume: float


@dataclass
class MarketContext:
    symbol: str
    generated_at_utc: str
    bid: float
    ask: float
    spread_points: float
    atr: float
    ema_fast: float
    ema_slow: float
    recent_bars: list[OhlcvBar]

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["recent_bars"] = [asdict(b) for b in self.recent_bars]
        return d


_mt5_initialized = False


def _ensure_mt5_initialized() -> None:
    global _mt5_initialized
    if not _MT5_AVAILABLE:
        raise MarketDataUnavailableError(
            "MetaTrader5 python package is not installed. "
            "TODO(integration): either `pip install MetaTrader5` and run this bridge "
            "on the same Windows machine/session as the MT5 terminal, or replace the "
            "functions in this module with calls to a different market-data source "
            "the user selects (broker REST API, market-data vendor, ccxt, etc.)."
        )
    if _mt5_initialized:
        return
    if not mt5.initialize():
        raise MarketDataUnavailableError(
            f"MetaTrader5.initialize() failed: {mt5.last_error()}. "
            "Is a MT5 terminal running and logged in on this machine?"
        )
    _mt5_initialized = True


def shutdown() -> None:
    global _mt5_initialized
    if _MT5_AVAILABLE and _mt5_initialized:
        mt5.shutdown()
        _mt5_initialized = False


def _resolve_symbol(symbol: str) -> str:
    """Resolve a bare symbol like 'XAUUSD' to whatever this broker actually
    lists it as (suffix variants such as XAUUSD., XAUUSDm, XAUUSD.a, ...).
    Never hardcode a broker-specific suffix — search Market Watch instead."""
    _ensure_mt5_initialized()

    info = mt5.symbol_info(symbol)
    if info is not None:
        return symbol

    all_symbols = mt5.symbols_get()
    if all_symbols:
        candidates = [s.name for s in all_symbols if s.name.upper().startswith(symbol.upper())]
        if candidates:
            # Prefer the shortest match (least suffix noise).
            candidates.sort(key=len)
            return candidates[0]

    raise MarketDataUnavailableError(
        f"Could not resolve broker symbol for '{symbol}' — checked Market Watch "
        f"for exact match and prefix matches, found none."
    )


def _simple_ema(values: list[float], period: int) -> float:
    if len(values) < period:
        raise MarketDataUnavailableError(f"Not enough bars ({len(values)}) to compute EMA({period}).")
    k = 2.0 / (period + 1)
    ema = sum(values[:period]) / period
    for v in values[period:]:
        ema = v * k + ema * (1 - k)
    return ema


def _wilder_atr(bars: list[OhlcvBar], period: int) -> float:
    if len(bars) < period + 1:
        raise MarketDataUnavailableError(f"Not enough bars ({len(bars)}) to compute ATR({period}).")
    trs: list[float] = []
    for i in range(1, len(bars)):
        prev_close = bars[i - 1].close
        tr = max(
            bars[i].high - bars[i].low,
            abs(bars[i].high - prev_close),
            abs(bars[i].low - prev_close),
        )
        trs.append(tr)
    atr = sum(trs[:period]) / period
    for tr in trs[period:]:
        atr = (atr * (period - 1) + tr) / period
    return atr


def get_market_context(
    symbol: str,
    timeframe: str = "M15",
    bars_count: int = 100,
    atr_period: int = 14,
    ema_fast_period: int = 20,
    ema_slow_period: int = 50,
) -> MarketContext:
    """Fetch current price + recent OHLCV + a couple of light indicators for
    `symbol`. Raises MarketDataUnavailableError on any failure — callers must
    treat that as 'skip this poll cycle', never crash the process."""
    _ensure_mt5_initialized()

    broker_symbol = _resolve_symbol(symbol)

    tf_map = {
        "M1": mt5.TIMEFRAME_M1,
        "M5": mt5.TIMEFRAME_M5,
        "M15": mt5.TIMEFRAME_M15,
        "M30": mt5.TIMEFRAME_M30,
        "H1": mt5.TIMEFRAME_H1,
        "H4": mt5.TIMEFRAME_H4,
        "D1": mt5.TIMEFRAME_D1,
    }
    mt5_tf = tf_map.get(timeframe.upper())
    if mt5_tf is None:
        raise MarketDataUnavailableError(f"Unsupported timeframe '{timeframe}'.")

    tick = mt5.symbol_info_tick(broker_symbol)
    if tick is None:
        raise MarketDataUnavailableError(f"symbol_info_tick returned None for '{broker_symbol}'.")

    info = mt5.symbol_info(broker_symbol)
    if info is None:
        raise MarketDataUnavailableError(f"symbol_info returned None for '{broker_symbol}'.")

    rates = mt5.copy_rates_from_pos(broker_symbol, mt5_tf, 0, bars_count)
    if rates is None or len(rates) == 0:
        raise MarketDataUnavailableError(f"copy_rates_from_pos returned no data for '{broker_symbol}'.")

    bars = [
        OhlcvBar(
            time_utc=datetime.fromtimestamp(int(r["time"]), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            open=float(r["open"]),
            high=float(r["high"]),
            low=float(r["low"]),
            close=float(r["close"]),
            volume=float(r["tick_volume"]),
        )
        for r in rates
    ]

    closes = [b.close for b in bars]
    atr_value = _wilder_atr(bars, atr_period)
    ema_fast = _simple_ema(closes, ema_fast_period)
    ema_slow = _simple_ema(closes, ema_slow_period)

    spread_points = (tick.ask - tick.bid) / info.point if info.point else 0.0

    return MarketContext(
        symbol=broker_symbol,
        generated_at_utc=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        bid=float(tick.bid),
        ask=float(tick.ask),
        spread_points=round(spread_points, 1),
        atr=round(atr_value, 5),
        ema_fast=round(ema_fast, 5),
        ema_slow=round(ema_slow, 5),
        recent_bars=bars[-20:],  # only send the tail to the LLM to keep the prompt small
    )
