"""
strategies/m2_directional.py — M2 ADX-Based Directional Strategy.

Two operating modes:

1. Normal mode
   - Reads ADX(14), EMA_fast(9), EMA_slow(21) on the configured timeframe.
   - When ADX > adx_threshold AND EMAs confirm direction → open a position
     in the trend direction to complement grid exposure.
   - Maximum 1 open M2 position at a time (refreshed after close).

2. Assist mode (activated by TriggerSystem)
   - M2 opens positions ONLY in the direction that offsets the locked magic's
     cumulative loss (e.g. if M1 BUY grid is losing, M2 opens SELLs).
   - Lot size is scaled by assist_lot_multiplier.
   - Assist mode deactivates when the locked magic recovers above
     loss_unlock_threshold.

Indicator computation:
- OHLCV data fetched via ExchangeClient.get_ohlcv().
- ADX and EMA calculated with pandas-ta.
- A new signal is evaluated once per candle close (not every tick).
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import pandas as pd
from loguru import logger

from config import Config, MAGIC_M2_DIRECTION

if TYPE_CHECKING:
    from core.exchange import ExchangeClient
    from core.risk_manager import RiskManager
    from core.state_manager import StateManager


# Trend direction constants
TREND_BULL = "bull"
TREND_BEAR = "bear"
TREND_NEUTRAL = "neutral"


class M2Directional:
    """ADX-based directional trade module.

    Parameters
    ----------
    config:
        Master config object.
    exchange:
        Async exchange client.
    risk:
        RiskManager instance.
    state:
        StateManager instance.
    """

    MAGIC = MAGIC_M2_DIRECTION

    def __init__(
        self,
        config: Config,
        exchange: "ExchangeClient",
        risk: "RiskManager",
        state: "StateManager",
    ) -> None:
        self.config = config
        self.exchange = exchange
        self.risk = risk
        self.state = state

        # Current trend direction exposed to grid strategies
        self.current_trend: str = TREND_NEUTRAL

        # Whether M2 is in assist mode (set by TriggerSystem)
        self._assist_mode: bool = False
        # Which magic is being assisted (the locked one)
        self._assist_magic: int | None = None

        # Timestamp of last processed candle (prevents duplicate signals)
        self._last_candle_ts: int | None = None

    # ------------------------------------------------------------------
    # Candle handler (called once per new candle close)
    # ------------------------------------------------------------------

    async def on_candle(self) -> str:
        """Fetch latest OHLCV, compute indicators, and act on signal.

        Called by the event loop whenever a new candle closes.

        Returns
        -------
        str
            Current trend direction: 'bull', 'bear', or 'neutral'.
            Consumed by grid strategies for lot-size multiplier selection.
        """
        ohlcv = await self.exchange.get_ohlcv(
            timeframe=self.config.m2.timeframe,
            limit=max(self.config.m2.adx_period, self.config.m2.ema_slow) + 5,
        )
        if not ohlcv:
            return self.current_trend

        df = self._to_dataframe(ohlcv)
        trend, adx_value = self._compute_signal(df)

        self.current_trend = trend
        logger.debug(
            "M2 candle | trend={} adx={:.1f} assist={}",
            trend,
            adx_value,
            self._assist_mode,
        )

        if self._last_candle_ts == ohlcv[-1][0]:
            return trend  # same candle, do not re-enter
        self._last_candle_ts = ohlcv[-1][0]

        await self._act_on_signal(trend)
        return trend

    # ------------------------------------------------------------------
    # Signal computation
    # ------------------------------------------------------------------

    def _to_dataframe(self, ohlcv: list[list]) -> pd.DataFrame:
        """Convert raw ccxt OHLCV list to a pandas DataFrame.

        Parameters
        ----------
        ohlcv:
            List of [timestamp, open, high, low, close, volume].

        Returns
        -------
        pd.DataFrame
            Columns: timestamp, open, high, low, close, volume.
        """
        raise NotImplementedError

    def _compute_signal(self, df: pd.DataFrame) -> tuple[str, float]:
        """Compute ADX and EMA crossover signal from OHLCV DataFrame.

        Algorithm:
        1. Compute ADX(adx_period) via pandas_ta.
        2. Compute EMA_fast and EMA_slow via pandas_ta.
        3. If ADX[-1] > adx_threshold AND EMA_fast[-1] > EMA_slow[-1] → bull.
        4. If ADX[-1] > adx_threshold AND EMA_fast[-1] < EMA_slow[-1] → bear.
        5. Otherwise → neutral.

        Parameters
        ----------
        df:
            OHLCV DataFrame.

        Returns
        -------
        tuple[str, float]
            (trend_direction, latest_adx_value)
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Action on signal
    # ------------------------------------------------------------------

    async def _act_on_signal(self, trend: str) -> None:
        """Open or close M2 position based on current trend and mode.

        Normal mode logic:
        - Close any existing M2 position if trend reversed.
        - If no open M2 position and trend is not neutral → open in trend dir.

        Assist mode logic:
        - Determine needed direction (opposite of locked magic's side).
        - Open in that direction regardless of ADX trend, with assist lot.

        Parameters
        ----------
        trend:
            Output of _compute_signal().
        """
        raise NotImplementedError

    async def _open_position(self, side: str, lot: float) -> None:
        """Place a market order for M2 and persist to StateManager.

        Parameters
        ----------
        side:
            'buy' or 'sell'.
        lot:
            Contract quantity (already sized).
        """
        raise NotImplementedError

    async def _close_existing(self) -> None:
        """Close any open M2 position via market order.

        Fetches open M2 positions from StateManager and closes each one.
        Calls StateManager.delete_position() after successful close.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Assist mode control (called by TriggerSystem)
    # ------------------------------------------------------------------

    def enable_assist(self, locked_magic: int) -> None:
        """Switch M2 into assist mode for the given locked magic.

        Parameters
        ----------
        locked_magic:
            Magic number of the strategy that triggered the loss threshold.
        """
        self._assist_mode = True
        self._assist_magic = locked_magic
        logger.warning(
            "M2 assist mode ENABLED | assisting magic={}", locked_magic
        )

    def disable_assist(self) -> None:
        """Return M2 to normal directional trading mode."""
        self._assist_mode = False
        self._assist_magic = None
        logger.info("M2 assist mode DISABLED — returning to normal mode")

    @property
    def is_assist_mode(self) -> bool:
        """True when M2 is in assist mode."""
        return self._assist_mode
