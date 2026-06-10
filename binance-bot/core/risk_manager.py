"""
core/risk_manager.py — Global risk guards and position-sizing.

Checks run before every new order:
1. Emergency stop file present
2. Global max drawdown breached
3. Daily loss limit breached
4. Max total open positions reached
5. Minimum free margin ratio maintained
6. Magic-level lock check

Also provides lot-size helpers used by grid and M2 strategies.
"""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING

from loguru import logger

from config import Config

if TYPE_CHECKING:
    from core.state_manager import StateManager
    from core.exchange import ExchangeClient


class RiskManager:
    """Centralised risk guard.

    All methods are synchronous-safe (no async I/O themselves) except
    ``check_all`` which awaits state queries.
    """

    def __init__(
        self,
        config: Config,
        state: "StateManager",
        exchange: "ExchangeClient",
    ) -> None:
        self.config = config
        self.state = state
        self.exchange = exchange

    # ------------------------------------------------------------------
    # Master gate
    # ------------------------------------------------------------------

    async def check_all(self, magic: int) -> bool:
        """Run every risk check.  Return True only if ALL pass.

        Parameters
        ----------
        magic:
            Magic number of the strategy requesting a new order.

        Returns
        -------
        bool
            True  → safe to open a new position.
            False → at least one check failed; do not open.
        """
        checks = [
            self._check_emergency_stop,
            self._check_max_drawdown,
            self._check_daily_loss,
            self._check_max_positions,
            self._check_free_margin,
        ]
        for check in checks:
            if not await check():
                return False
        if not await self._check_magic_locked(magic):
            return False
        return True

    # ------------------------------------------------------------------
    # Individual checks
    # ------------------------------------------------------------------

    async def _check_emergency_stop(self) -> bool:
        """Return False if the emergency-stop sentinel file exists."""
        stop_file = Path(self.config.risk.emergency_stop_file)
        if stop_file.exists():
            logger.warning("Emergency stop file detected — all trading halted")
            return False
        return True

    async def _check_max_drawdown(self) -> bool:
        """Return False if current drawdown exceeds config threshold.

        Drawdown is calculated as:
            (initial_balance - current_equity) / initial_balance * 100
        Initial balance is stored in the DB on first run.
        """
        raise NotImplementedError

    async def _check_daily_loss(self) -> bool:
        """Return False if today's realised PNL has breached the daily limit."""
        daily_pnl = await self.state.get_daily_pnl()
        if daily_pnl <= self.config.risk.daily_loss_limit_usdt:
            logger.warning(
                "Daily loss limit reached | pnl={:.2f} limit={:.2f}",
                daily_pnl,
                self.config.risk.daily_loss_limit_usdt,
            )
            return False
        return True

    async def _check_max_positions(self) -> bool:
        """Return False if total open positions equals the configured max."""
        positions = await self.state.get_all_positions()
        if len(positions) >= self.config.risk.max_total_positions:
            logger.warning(
                "Max positions reached | open={} max={}",
                len(positions),
                self.config.risk.max_total_positions,
            )
            return False
        return True

    async def _check_free_margin(self) -> bool:
        """Return False if free margin ratio is below the configured minimum.

        free_margin_ratio = balance['free'] / balance['total']
        """
        raise NotImplementedError

    async def _check_magic_locked(self, magic: int) -> bool:
        """Return False if the magic has been locked by the Trigger System."""
        state = await self.state.get_magic_state(magic)
        if state.locked:
            logger.debug("Magic {} is locked — skipping order", magic)
            return False
        return True

    # ------------------------------------------------------------------
    # Position sizing
    # ------------------------------------------------------------------

    def calculate_lot(
        self,
        base_lot: float,
        is_counter_trend: bool,
    ) -> float:
        """Apply directional multiplier to base lot size.

        Parameters
        ----------
        base_lot:
            Base contract quantity from grid/M2 config.
        is_counter_trend:
            True  → grid is opening against the current trend direction.
            False → grid is opening with the current trend direction.

        Returns
        -------
        float
            Adjusted lot size, rounded to exchange qty precision.
        """
        grid_cfg = self.config.grid
        multiplier = (
            grid_cfg.counter_trend_multiplier
            if is_counter_trend
            else grid_cfg.with_trend_multiplier
        )
        raw = base_lot * multiplier
        return self.exchange.round_qty(raw)
