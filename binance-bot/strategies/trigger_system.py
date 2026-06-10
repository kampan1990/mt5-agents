"""
strategies/trigger_system.py — Loss Trigger System.

Monitors per-magic unrealised PNL and applies locking / assist logic.

Trigger fire conditions:
- When a magic's total unrealised PNL drops below loss_trigger_threshold:
  1. Lock the magic: no new orders will be placed for it.
  2. Enable M2 assist mode targeting the locked magic.

Unlock conditions:
- When a locked magic's total unrealised PNL recovers above
  loss_unlock_threshold:
  1. Unlock the magic.
  2. Disable M2 assist mode if no other magic is locked.

Evaluation runs every tick (called by main event loop).
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from loguru import logger

from config import Config, MAGIC_M1_BUY_GRID, MAGIC_M2_DIRECTION, MAGIC_M3_SELL_GRID

if TYPE_CHECKING:
    from core.state_manager import StateManager
    from strategies.m2_directional import M2Directional


class TriggerSystem:
    """Per-magic loss trigger monitor.

    Parameters
    ----------
    config:
        Master config object.
    state:
        StateManager for reading magic PNL and updating lock flags.
    m2:
        M2Directional instance — assist mode toggled here.
    """

    MONITORED_MAGICS = [MAGIC_M1_BUY_GRID, MAGIC_M3_SELL_GRID]

    def __init__(
        self,
        config: Config,
        state: "StateManager",
        m2: "M2Directional",
    ) -> None:
        self.config = config
        self.state = state
        self.m2 = m2

        # In-memory set of currently locked magics (mirrored from DB)
        self._locked_magics: set[int] = set()

    # ------------------------------------------------------------------
    # Main evaluation — called every tick
    # ------------------------------------------------------------------

    async def evaluate(self) -> None:
        """Check PNL for each monitored magic and apply trigger logic.

        For each magic in MONITORED_MAGICS:
        - If not locked and PNL <= threshold → lock + assist.
        - If locked and PNL >= unlock threshold → unlock + deassist.
        """
        for magic in self.MONITORED_MAGICS:
            pnl = await self._get_magic_pnl(magic)
            if magic not in self._locked_magics:
                await self._check_lock(magic, pnl)
            else:
                await self._check_unlock(magic, pnl)

    # ------------------------------------------------------------------
    # PNL helpers
    # ------------------------------------------------------------------

    async def _get_magic_pnl(self, magic: int) -> float:
        """Sum unrealised PNL for all open positions of the given magic.

        Parameters
        ----------
        magic:
            Target magic number.

        Returns
        -------
        float
            Total unrealised PNL (USDT), negative if losing.
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Lock / Unlock
    # ------------------------------------------------------------------

    async def _check_lock(self, magic: int, pnl: float) -> None:
        """Lock magic and enable M2 assist if PNL threshold is breached.

        Parameters
        ----------
        magic:
            Magic number to potentially lock.
        pnl:
            Current total unrealised PNL for this magic.
        """
        if pnl <= self.config.trigger.loss_trigger_threshold:
            self._locked_magics.add(magic)
            await self.state.set_magic_locked(magic, True)
            self.m2.enable_assist(magic)
            logger.warning(
                "Trigger FIRED | magic={} pnl={:.2f} threshold={:.2f}",
                magic,
                pnl,
                self.config.trigger.loss_trigger_threshold,
            )

    async def _check_unlock(self, magic: int, pnl: float) -> None:
        """Unlock magic and optionally disable M2 assist if PNL recovered.

        Parameters
        ----------
        magic:
            Magic number to potentially unlock.
        pnl:
            Current total unrealised PNL for this magic.
        """
        if pnl >= self.config.trigger.loss_unlock_threshold:
            self._locked_magics.discard(magic)
            await self.state.set_magic_locked(magic, False)
            # Disable assist only if no other magic is still locked
            if not self._locked_magics:
                self.m2.disable_assist()
            logger.info(
                "Trigger UNLOCKED | magic={} pnl={:.2f}",
                magic,
                pnl,
            )

    # ------------------------------------------------------------------
    # Status
    # ------------------------------------------------------------------

    def is_locked(self, magic: int) -> bool:
        """Return True if the given magic is currently locked.

        Parameters
        ----------
        magic:
            Magic number to query.
        """
        return magic in self._locked_magics

    async def sync_lock_state(self) -> None:
        """Sync in-memory lock set from DB on startup.

        Reads all magic states from StateManager and populates
        self._locked_magics so state is consistent after a restart.
        """
        raise NotImplementedError
