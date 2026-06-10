"""
strategies/grid_m1.py — M1 BUY Grid Strategy.

Opens a BUY position every X pips as price descends.
Mirrors the MQL5 M1 grid logic: counter-trend buying into weakness.

Grid level tracking:
- The last grid price is stored in StateManager.
- A new BUY is placed only when price drops at least one grid_step below
  the previous grid level.
- Lot sizing uses counter_trend_multiplier when ADX trend is bearish,
  with_trend_multiplier when ADX trend is bullish.

TP logic:
- Grid TP is handled by the TPChain (SepTP / PairTP / TotTP), NOT here.
- Positions in the BestSidePool are immune from this module's TP checks.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from loguru import logger

from config import Config, MAGIC_M1_BUY_GRID

if TYPE_CHECKING:
    from core.exchange import ExchangeClient
    from core.risk_manager import RiskManager
    from core.state_manager import StateManager


class M1BuyGrid:
    """BUY grid strategy — opens longs on price descent.

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

    MAGIC = MAGIC_M1_BUY_GRID

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

        # Last price at which a grid BUY was placed (in-memory cache).
        # Populated from DB on startup via load_last_grid_price().
        self._last_grid_price: float | None = None

    # ------------------------------------------------------------------
    # Startup
    # ------------------------------------------------------------------

    async def load_last_grid_price(self) -> None:
        """Restore last grid price from DB so grid spacing survives restarts.

        Queries the most recent M1 position entry_price and sets
        self._last_grid_price accordingly.  If no positions exist the grid
        starts fresh at the first tick price.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Core tick handler
    # ------------------------------------------------------------------

    async def on_tick(self, price: float, adx_trend: str) -> None:
        """Evaluate whether a new grid BUY should be opened.

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

        is_counter_trend = adx_trend == "bear"

        allowed = await self.risk.check_all(self.MAGIC)
        if not allowed:
            logger.debug("M1 grid: risk check failed, skip BUY at {}", price)
            return

        await self._open_buy(price, is_counter_trend)

    # ------------------------------------------------------------------
    # Grid spacing check
    # ------------------------------------------------------------------

    async def _should_open(self, price: float) -> bool:
        """Return True if price has dropped at least one grid step below
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

    async def _open_buy(self, price: float, is_counter_trend: bool) -> None:
        """Place a market BUY order and persist the position.

        Steps:
        1. Calculate lot via RiskManager.calculate_lot().
        2. Place market order via ExchangeClient.place_market_order().
        3. Persist Position to StateManager with magic=MAGIC_M1_BUY_GRID.
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

        Called by TPChain after a SepTP / PairTP / TotTP closes M1 positions.

        Parameters
        ----------
        anchor_price:
            New reference price for the next grid level.
        """
        self._last_grid_price = anchor_price
        logger.info("M1 grid reset | anchor={}", anchor_price)

    async def get_open_count(self) -> int:
        """Return number of currently open M1 positions."""
        positions = await self.state.get_positions_by_magic(self.MAGIC)
        return len(positions)
