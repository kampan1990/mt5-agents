"""
strategies/recovery.py — Smart Recovery Engine.

Triggered after every TP fire (grid TP or pool TP).

Algorithm (ported from MQL5):
1. Receive win_sum — total USDT realised from the TP event.
2. Compute recovery_budget = win_sum * recovery_ratio.
3. Fetch all open positions with unrealised_pnl < 0.
4. Sort losing positions by unrealised_pnl ASCENDING (least negative first).
5. Iterate greedily:
   a. allocated = min(abs(pos.unrealised_pnl), remaining_budget)
   b. net = pos.unrealised_pnl + allocated
   c. If net >= min_net_to_close → close the position, deduct allocated from
      remaining_budget, log recovery event.
   d. If net < min_net_to_close → skip (not enough budget to make it whole).
   e. Stop when remaining_budget is exhausted.

No new orders are placed by this module — it only closes existing losers.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from loguru import logger

from config import Config

if TYPE_CHECKING:
    from core.exchange import ExchangeClient
    from core.state_manager import StateManager, Position


class RecoveryEngine:
    """Smart recovery — uses TP winnings to close underwater positions.

    Parameters
    ----------
    config:
        Master config object.
    exchange:
        Async exchange client for market-close orders.
    state:
        StateManager for position reads, PNL updates, and recovery logging.
    """

    def __init__(
        self,
        config: Config,
        exchange: "ExchangeClient",
        state: "StateManager",
    ) -> None:
        self.config = config
        self.exchange = exchange
        self.state = state

    # ------------------------------------------------------------------
    # Main entry point
    # ------------------------------------------------------------------

    async def run(self, win_sum: float) -> None:
        """Execute one recovery pass using win_sum as the funding source.

        Parameters
        ----------
        win_sum:
            Total USDT won by the triggering TP event.  Recovery budget is
            derived from this value via recovery_ratio.
        """
        budget = win_sum * self.config.recovery.recovery_ratio
        if budget <= 0:
            logger.debug("Recovery: budget={:.2f}, skipping", budget)
            return

        logger.info(
            "Recovery started | win_sum={:.2f} budget={:.2f} ratio={}",
            win_sum,
            budget,
            self.config.recovery.recovery_ratio,
        )

        losers = await self._get_sorted_losers()
        if not losers:
            logger.debug("Recovery: no losing positions to recover")
            return

        remaining = budget
        closed_count = 0

        for pos in losers:
            if remaining <= 0:
                break
            remaining, closed = await self._attempt_recovery(pos, remaining)
            if closed:
                closed_count += 1

        logger.info(
            "Recovery complete | closed={} remaining_budget={:.2f}",
            closed_count,
            remaining,
        )

    # ------------------------------------------------------------------
    # Loser selection
    # ------------------------------------------------------------------

    async def _get_sorted_losers(self) -> list["Position"]:
        """Return all losing positions sorted by PNL ascending (least loss first).

        Excludes positions in the BestSidePool (they have their own TP logic).

        Returns
        -------
        list[Position]
            Positions with unrealised_pnl < 0, sorted least-negative first.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Single position recovery attempt
    # ------------------------------------------------------------------

    async def _attempt_recovery(
        self,
        pos: "Position",
        remaining_budget: float,
    ) -> tuple[float, bool]:
        """Try to recover a single position within the remaining budget.

        Steps:
        1. allocated = min(abs(pos.unrealised_pnl), remaining_budget)
        2. net = pos.unrealised_pnl + allocated
        3. If net >= config.recovery.min_net_to_close:
           - Close position via exchange.close_position().
           - Delete from StateManager.
           - Log recovery via state.log_recovery_attempt(closed=True).
           - Deduct allocated from remaining_budget.
           - Return (new_remaining, True).
        4. Else:
           - Log via state.log_recovery_attempt(closed=False).
           - Return (remaining_budget, False) unchanged.

        Parameters
        ----------
        pos:
            The losing position to evaluate.
        remaining_budget:
            USDT budget left for recovery.

        Returns
        -------
        tuple[float, bool]
            (updated_remaining_budget, was_closed)
        """
        raise NotImplementedError
