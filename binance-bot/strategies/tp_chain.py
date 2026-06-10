"""
strategies/tp_chain.py — TP Priority Chain.

Implements the three-level take-profit hierarchy ported from MQL5:

    SepTP  → individual magic closes when its own PNL >= sep_tp_usdt
    PairTP → the two highest-PNL magics close together when combined PNL
              >= pair_tp_usdt
    TotTP  → all three magics close together when total PNL >= tot_tp_usdt

Evaluation order (priority):
    TotTP → PairTP → SepTP

When a TP fires:
1. Close all affected positions via ExchangeClient.close_position().
2. Accumulate realised PNL via StateManager.add_realised_pnl().
3. Call grid.reset_grid() on affected grid strategies.
4. Trigger RecoveryEngine.run() with the win_sum from this TP event.
5. Remove closed positions from StateManager.

BestSidePool positions are handled by BestSidePool.check_tp(), not here.
Pool positions must NOT be closed by this module.

Checks run on a fixed interval (tp.check_interval_seconds) driven by the
main event loop.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from loguru import logger

from config import Config, MAGIC_M1_BUY_GRID, MAGIC_M2_DIRECTION, MAGIC_M3_SELL_GRID

if TYPE_CHECKING:
    from core.exchange import ExchangeClient
    from core.state_manager import StateManager
    from strategies.grid_m1 import M1BuyGrid
    from strategies.grid_m3 import M3SellGrid
    from strategies.recovery import RecoveryEngine


class TPChain:
    """Three-level TP priority chain.

    Parameters
    ----------
    config:
        Master config object.
    exchange:
        Async exchange client for closing positions.
    state:
        StateManager for PNL reads and position management.
    m1:
        M1BuyGrid reference — reset_grid() called after M1 TP fires.
    m3:
        M3SellGrid reference — reset_grid() called after M3 TP fires.
    recovery:
        RecoveryEngine reference — run() called with win_sum after every TP.
    """

    ALL_MAGICS = [MAGIC_M1_BUY_GRID, MAGIC_M2_DIRECTION, MAGIC_M3_SELL_GRID]

    def __init__(
        self,
        config: Config,
        exchange: "ExchangeClient",
        state: "StateManager",
        m1: "M1BuyGrid",
        m3: "M3SellGrid",
        recovery: "RecoveryEngine",
    ) -> None:
        self.config = config
        self.exchange = exchange
        self.state = state
        self.m1 = m1
        self.m3 = m3
        self.recovery = recovery

    # ------------------------------------------------------------------
    # Main check — called periodically by event loop
    # ------------------------------------------------------------------

    async def check(self, current_price: float) -> None:
        """Evaluate all TP levels in priority order.

        Evaluation stops as soon as one level fires to avoid double-closing.

        Parameters
        ----------
        current_price:
            Current mark price — used to compute unrealised PNL if not
            already stored in StateManager.
        """
        pnl_by_magic = await self._get_pnl_by_magic()

        if await self._check_tot_tp(pnl_by_magic, current_price):
            return
        if await self._check_pair_tp(pnl_by_magic, current_price):
            return
        await self._check_sep_tp(pnl_by_magic, current_price)

    # ------------------------------------------------------------------
    # PNL aggregation
    # ------------------------------------------------------------------

    async def _get_pnl_by_magic(self) -> dict[int, float]:
        """Return {magic: total_unrealised_pnl} for all open positions.

        Excludes positions flagged as in_best_pool=True.

        Returns
        -------
        dict[int, float]
            Mapping from magic number to summed unrealised PNL (USDT).
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # TotTP — all three magics
    # ------------------------------------------------------------------

    async def _check_tot_tp(
        self,
        pnl_by_magic: dict[int, float],
        current_price: float,
    ) -> bool:
        """Fire TotTP if sum of all magic PNLs >= tot_tp_usdt.

        Returns True if TP fired, False otherwise.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # PairTP — top 2 magics by PNL
    # ------------------------------------------------------------------

    async def _check_pair_tp(
        self,
        pnl_by_magic: dict[int, float],
        current_price: float,
    ) -> bool:
        """Fire PairTP if the two highest-PNL magics combined >= pair_tp_usdt.

        Selection:
        - Sort magics by PNL descending.
        - Take top 2.
        - If their combined PNL >= pair_tp_usdt → close both.

        Returns True if TP fired, False otherwise.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # SepTP — individual magic
    # ------------------------------------------------------------------

    async def _check_sep_tp(
        self,
        pnl_by_magic: dict[int, float],
        current_price: float,
    ) -> bool:
        """Fire SepTP for any magic whose individual PNL >= sep_tp_usdt.

        Processes magics independently; multiple can fire in one check call.

        Returns True if at least one SepTP fired, False otherwise.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Close helpers
    # ------------------------------------------------------------------

    async def _close_magic(self, magic: int, current_price: float) -> float:
        """Close all non-pool positions for a magic and return realised PNL.

        Steps:
        1. Fetch positions via state.get_positions_by_magic(magic).
        2. Filter out in_best_pool positions.
        3. Close each via exchange.close_position().
        4. Sum up PNL, call state.delete_position(), state.add_realised_pnl().
        5. Call grid reset if magic is M1 or M3.

        Parameters
        ----------
        magic:
            Target magic number.
        current_price:
            Used for realised PNL calculation if not already tracked.

        Returns
        -------
        float
            Total realised PNL from this close event (USDT).
        """
        raise NotImplementedError
