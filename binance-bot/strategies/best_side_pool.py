"""
strategies/best_side_pool.py — Best Side Pool.

Maintains two separate pools of the "best" open positions:
- BestBuyPool : the N BUY positions with the highest unrealised PNL.
- BestSellPool: the N SELL positions with the highest unrealised PNL.

Rules:
1. After every tick, re-evaluate membership of both pools.
2. A position enters the pool when it is among the top N by PNL.
3. A position leaves the pool when it is displaced by a better position.
4. Positions inside the pool are flagged in_best_pool=True in the DB.
   This flag exempts them from TPChain grid TP checks.
5. Each pool has its own TP target (best_buy_tp_usdt / best_sell_tp_usdt).
   When combined PNL of a pool >= its target, close all pool positions.

Pool membership is stored in StateManager via set_best_pool_flag().
TP evaluation calls RecoveryEngine.run() with the resulting win_sum.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from loguru import logger

from config import Config

if TYPE_CHECKING:
    from core.exchange import ExchangeClient
    from core.state_manager import StateManager, Position
    from strategies.recovery import RecoveryEngine


class BestSidePool:
    """Manages BestBuyPool and BestSellPool.

    Parameters
    ----------
    config:
        Master config object.
    exchange:
        Async exchange client for closing positions.
    state:
        StateManager for position reads and pool flag updates.
    recovery:
        RecoveryEngine — called after pool TP fires.
    """

    def __init__(
        self,
        config: Config,
        exchange: "ExchangeClient",
        state: "StateManager",
        recovery: "RecoveryEngine",
    ) -> None:
        self.config = config
        self.exchange = exchange
        self.state = state
        self.recovery = recovery

    # ------------------------------------------------------------------
    # Main update — called every tick
    # ------------------------------------------------------------------

    async def update(self) -> None:
        """Refresh pool membership and check TP for both pools.

        Order of operations:
        1. Fetch all open positions.
        2. Separate into BUY and SELL lists.
        3. Reselect top-N for each side via _reselect_pool().
        4. Persist membership changes via state.set_best_pool_flag().
        5. Check pool TPs via _check_pool_tp().
        """
        all_positions = await self.state.get_all_positions()
        buy_positions = [p for p in all_positions if p.side == "buy"]
        sell_positions = [p for p in all_positions if p.side == "sell"]

        await self._reselect_pool(buy_positions, "buy")
        await self._reselect_pool(sell_positions, "sell")

        await self._check_pool_tp("buy")
        await self._check_pool_tp("sell")

    # ------------------------------------------------------------------
    # Pool selection
    # ------------------------------------------------------------------

    async def _reselect_pool(
        self,
        positions: list["Position"],
        side: str,
    ) -> None:
        """Select top-N positions by PNL for the given side and update flags.

        Algorithm:
        1. Sort positions by unrealised_pnl descending.
        2. Take first N (where N = best_buy_count or best_sell_count).
        3. For positions that should be in pool but are not → flag True.
        4. For positions that should not be in pool but are → flag False.

        Parameters
        ----------
        positions:
            All open positions for the given side.
        side:
            'buy' or 'sell'.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Pool TP check
    # ------------------------------------------------------------------

    async def _check_pool_tp(self, side: str) -> None:
        """Close pool positions if combined PNL meets pool TP target.

        Parameters
        ----------
        side:
            'buy' or 'sell' — selects which pool to check.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Pool close
    # ------------------------------------------------------------------

    async def _close_pool(self, side: str) -> float:
        """Market-close all pool positions for the given side.

        Steps:
        1. Fetch positions with in_best_pool=True and matching side.
        2. Close each via exchange.close_position().
        3. Delete from StateManager, accumulate realised PNL.
        4. Call recovery.run() with win_sum.
        5. Return total realised PNL.

        Parameters
        ----------
        side:
            'buy' or 'sell'.

        Returns
        -------
        float
            Total realised PNL (USDT) from this pool close.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Query helpers
    # ------------------------------------------------------------------

    async def get_pool_pnl(self, side: str) -> float:
        """Return combined unrealised PNL of the given side's pool.

        Parameters
        ----------
        side:
            'buy' or 'sell'.

        Returns
        -------
        float
            Sum of unrealised_pnl for all in_best_pool positions of that side.
        """
        raise NotImplementedError

    async def is_in_pool(self, order_id: str) -> bool:
        """Return True if the position with order_id is currently in any pool.

        Parameters
        ----------
        order_id:
            Exchange order ID of the position.

        Returns
        -------
        bool
        """
        raise NotImplementedError
