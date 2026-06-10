"""
strategies/grid_m3.py — M3 SELL Grid Strategy.

Opens a SELL position every X pips as price ascends.
Mirrors the MQL5 M3 grid logic: counter-trend selling into strength.

Grid level tracking:
- A new SELL is placed only when price rises at least one grid_step above
  the previous grid level.
- Lot sizing uses counter_trend_multiplier when ADX trend is bullish,
  with_trend_multiplier when ADX trend is bearish.

TP logic:
- Handled externally by TPChain, not this module.
- BestSidePool positions are immune from grid TP.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from loguru import logger

from config import Config, MAGIC_M3_SELL_GRID

if TYPE_CHECKING:
    from core.exchange import ExchangeClient
    from core.risk_manager import RiskManager
    from core.state_manager import StateManager


class M3SellGrid:
    """SELL grid strategy — opens shorts on price ascent.

    Parameters
    ----------
    config:
        Master config object.
    exchange:
        Async exchange client.
    risk:
        RiskManager instance for pre-order checks and lot sizing.
    state:
        StateManager instance for persistence.
    """

    MAGIC = MAGIC_M3_SELL_GRID

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

        # Last price at which a grid SELL was placed (in-memory cache).
        self._last_grid_price: float | None = None

    # ------------------------------------------------------------------
    # Startup
    # ------------------------------------------------------------------

    async def load_last_grid_price(self) -> None:
        """Restore last grid price from DB so grid spacing survives restarts.

        Queries the most recent M3 position entry_price and sets
        self._last_grid_price accordingly.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Core tick handler
    # ------------------------------------------------------------------

    async def on_tick(self, price: float, adx_trend: str) -> None:
        """Evaluate whether a new grid SELL should be opened.

        Called on every mark-price tick from the event loop.

        Parameters
        ----------
        price:
            Current mark price.
        adx_trend:
            Trend direction from M2 ADX module: 'bull', 'bear', or 'neutral'.
            Used to determine counter-trend vs with-trend lot multiplier.
        """
        if not await self._should_open(price):
            return

        is_counter_trend = adx_trend == "bull"

        allowed = await self.risk.check_all(self.MAGIC)
        if not allowed:
            logger.debug("M3 grid: risk check failed, skip SELL at {}", price)
            return

        await self._open_sell(price, is_counter_trend)

    # ------------------------------------------------------------------
    # Grid spacing check
    # ------------------------------------------------------------------

    async def _should_open(self, price: float) -> bool:
        """Return True if price has risen at least one grid step above
        the last opened level.

        Parameters
        ----------
        price:
            Current mark price.

        Returns
        -------
        bool
            True  → grid condition met, proceed to risk check.
            False → grid spacing not reached yet.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Order placement
    # ------------------------------------------------------------------

    async def _open_sell(self, price: float, is_counter_trend: bool) -> None:
        """Place a market SELL order and persist the position.

        Steps:
        1. Calculate lot via RiskManager.calculate_lot().
        2. Place market order via ExchangeClient.place_market_order().
        3. Persist Position to StateManager with magic=MAGIC_M3_SELL_GRID.
        4. Update self._last_grid_price and DB.

        Parameters
        ----------
        price:
            Entry price (mark price at time of order).
        is_counter_trend:
            Passed to RiskManager.calculate_lot().
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Level management
    # ------------------------------------------------------------------

    async def reset_grid(self, anchor_price: float) -> None:
        """Reset grid anchor to anchor_price (e.g. after TP fires).

        Parameters
        ----------
        anchor_price:
            New reference price for the next grid level.
        """
        self._last_grid_price = anchor_price
        logger.info("M3 grid reset | anchor={}", anchor_price)

    async def get_open_count(self) -> int:
        """Return number of currently open M3 positions."""
        positions = await self.state.get_positions_by_magic(self.MAGIC)
        return len(positions)
