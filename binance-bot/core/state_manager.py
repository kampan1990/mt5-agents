"""
core/state_manager.py — SQLite-backed persistence layer.

Stores and retrieves:
- Open positions (per magic, per side)
- Grid level tracking per magic
- Magic lock states (from Trigger System)
- Daily PNL accumulator
- Best Side Pool membership
- Recovery engine state

Uses aiosqlite for async I/O to avoid blocking the event loop.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Any

import aiosqlite
from loguru import logger

from config import Config


# ---------------------------------------------------------------------------
# Data classes — in-memory representations of DB rows
# ---------------------------------------------------------------------------

@dataclass
class Position:
    """Represents a single open position / grid slot."""
    id: int | None               # DB primary key (None if not yet persisted)
    magic: int                   # Magic number (MAGIC_M1_BUY_GRID etc.)
    side: str                    # 'buy' or 'sell'
    entry_price: float
    amount: float                # contract quantity
    order_id: str                # exchange order ID
    unrealised_pnl: float = 0.0
    in_best_pool: bool = False   # True if this position is in BestSidePool
    created_at: str = ""         # ISO-8601 UTC timestamp


@dataclass
class MagicState:
    """Tracks aggregate state for a single magic number."""
    magic: int
    locked: bool = False         # True when loss trigger has fired
    assist_mode: bool = False    # True when M2 is assisting this magic
    total_unrealised_pnl: float = 0.0
    open_positions: int = 0


# ---------------------------------------------------------------------------
# StateManager
# ---------------------------------------------------------------------------

class StateManager:
    """Async SQLite state manager.

    Call ``await sm.init()`` once before use.
    All public methods are coroutines safe to call from the event loop.
    """

    def __init__(self, config: Config) -> None:
        self.config = config
        self._db: aiosqlite.Connection | None = None
        self._lock = asyncio.Lock()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def init(self) -> None:
        """Open DB connection and create tables if they do not exist."""
        import os
        os.makedirs(os.path.dirname(self.config.db.path), exist_ok=True)
        self._db = await aiosqlite.connect(self.config.db.path)
        if self.config.db.wal_mode:
            await self._db.execute("PRAGMA journal_mode=WAL")
        await self._create_tables()
        logger.info("StateManager initialised | db={}", self.config.db.path)

    async def close(self) -> None:
        """Flush and close DB connection."""
        if self._db:
            await self._db.close()

    async def _create_tables(self) -> None:
        """Create all required tables."""
        await self._db.executescript("""
            CREATE TABLE IF NOT EXISTS positions (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                magic        INTEGER NOT NULL,
                side         TEXT    NOT NULL,
                entry_price  REAL    NOT NULL,
                amount       REAL    NOT NULL,
                order_id     TEXT    NOT NULL UNIQUE,
                unrealised_pnl REAL  DEFAULT 0.0,
                in_best_pool INTEGER DEFAULT 0,
                created_at   TEXT    NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS magic_states (
                magic        INTEGER PRIMARY KEY,
                locked       INTEGER DEFAULT 0,
                assist_mode  INTEGER DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS daily_pnl (
                date TEXT PRIMARY KEY,
                realised_pnl REAL DEFAULT 0.0
            );

            CREATE TABLE IF NOT EXISTS recovery_log (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                position_id  INTEGER REFERENCES positions(id),
                win_sum      REAL,
                budget       REAL,
                allocated    REAL,
                net          REAL,
                closed       INTEGER DEFAULT 0,
                created_at   TEXT DEFAULT (datetime('now'))
            );
        """)
        await self._db.commit()

    # ------------------------------------------------------------------
    # Position CRUD
    # ------------------------------------------------------------------

    async def save_position(self, pos: Position) -> int:
        """Insert or update a position.  Returns the DB row ID."""
        raise NotImplementedError

    async def delete_position(self, order_id: str) -> None:
        """Remove a position by exchange order ID (called on close)."""
        raise NotImplementedError

    async def get_positions_by_magic(self, magic: int) -> list[Position]:
        """Return all open positions for a given magic number."""
        raise NotImplementedError

    async def get_all_positions(self) -> list[Position]:
        """Return every open position across all magics."""
        raise NotImplementedError

    async def update_unrealised_pnl(self, order_id: str, pnl: float) -> None:
        """Overwrite the unrealised_pnl field for a position."""
        raise NotImplementedError

    async def set_best_pool_flag(self, order_id: str, flag: bool) -> None:
        """Mark or unmark a position as part of the Best Side Pool."""
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Magic State
    # ------------------------------------------------------------------

    async def get_magic_state(self, magic: int) -> MagicState:
        """Return (or create) the MagicState row for a given magic."""
        raise NotImplementedError

    async def set_magic_locked(self, magic: int, locked: bool) -> None:
        """Lock or unlock a magic (Trigger System)."""
        raise NotImplementedError

    async def set_magic_assist(self, magic: int, assist: bool) -> None:
        """Enable or disable M2 assist mode for a magic."""
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Daily PNL
    # ------------------------------------------------------------------

    async def add_realised_pnl(self, amount: float) -> None:
        """Accumulate realised PNL for today (UTC date)."""
        raise NotImplementedError

    async def get_daily_pnl(self) -> float:
        """Return today's accumulated realised PNL."""
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Recovery Log
    # ------------------------------------------------------------------

    async def log_recovery_attempt(
        self,
        position_id: int,
        win_sum: float,
        budget: float,
        allocated: float,
        net: float,
        closed: bool,
    ) -> None:
        """Record a recovery engine decision for audit purposes."""
        raise NotImplementedError
