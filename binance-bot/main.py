"""
main.py — Bot entry point and async event loop.

Startup sequence:
1. Load Config (reads .env for API keys).
2. Setup logging.
3. Init StateManager (open DB, create tables).
4. Init ExchangeClient (connect to Binance, set leverage).
5. Init all strategy components.
6. Restore state from DB (grid prices, lock states).
7. Start event loop tasks:
   - price_feed_task  : WebSocket mark price → tick queue
   - candle_task      : periodic OHLCV fetch → M2 candle signal
   - main_loop_task   : drains tick queue, runs all on_tick handlers
   - tp_check_task    : periodic TP chain evaluation
   - pool_update_task : periodic BestSidePool rebalance
   - trigger_task     : periodic TriggerSystem evaluation

Shutdown:
- Catches KeyboardInterrupt and SIGTERM.
- Cancels all tasks gracefully.
- Closes ExchangeClient and StateManager.

Emergency stop:
- Any task can place the emergency_stop_file to halt all order activity.
  The RiskManager checks for this file on every order attempt.
"""

from __future__ import annotations

import asyncio
import signal
import sys

from loguru import logger

from config import Config
from core.exchange import ExchangeClient
from core.risk_manager import RiskManager
from core.state_manager import StateManager
from strategies.best_side_pool import BestSidePool
from strategies.grid_m1 import M1BuyGrid
from strategies.grid_m3 import M3SellGrid
from strategies.m2_directional import M2Directional
from strategies.recovery import RecoveryEngine
from strategies.tp_chain import TPChain
from strategies.trigger_system import TriggerSystem
from utils.logger import setup_logging


async def main() -> None:
    """Initialise all components and run the bot until shutdown."""
    config = Config()
    setup_logging(config)

    logger.info("Bot starting up...")

    # ------------------------------------------------------------------
    # Core infrastructure
    # ------------------------------------------------------------------
    state = StateManager(config)
    await state.init()

    exchange = ExchangeClient(config)
    await exchange.connect()

    risk = RiskManager(config, state, exchange)

    # ------------------------------------------------------------------
    # Strategy components
    # ------------------------------------------------------------------
    recovery = RecoveryEngine(config, exchange, state)

    m1 = M1BuyGrid(config, exchange, risk, state)
    m3 = M3SellGrid(config, exchange, risk, state)
    m2 = M2Directional(config, exchange, risk, state)

    tp_chain = TPChain(config, exchange, state, m1, m3, recovery)
    best_pool = BestSidePool(config, exchange, state, recovery)
    trigger = TriggerSystem(config, state, m2)

    # ------------------------------------------------------------------
    # Restore persisted state
    # ------------------------------------------------------------------
    await m1.load_last_grid_price()
    await m3.load_last_grid_price()
    await trigger.sync_lock_state()
    logger.info("State restored from DB")

    # ------------------------------------------------------------------
    # Shared tick queue — price_feed_task → main_loop_task
    # ------------------------------------------------------------------
    tick_queue: asyncio.Queue[float] = asyncio.Queue(maxsize=1000)

    # ------------------------------------------------------------------
    # Tasks
    # ------------------------------------------------------------------
    tasks = [
        asyncio.create_task(
            price_feed_task(exchange, tick_queue, config),
            name="price_feed",
        ),
        asyncio.create_task(
            candle_task(m2, config),
            name="candle",
        ),
        asyncio.create_task(
            main_loop_task(tick_queue, m1, m3, trigger, best_pool),
            name="main_loop",
        ),
        asyncio.create_task(
            tp_check_task(tp_chain, config),
            name="tp_check",
        ),
    ]

    # Install shutdown handlers
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, lambda: _shutdown(tasks))

    logger.info("All tasks started — bot is running")

    try:
        await asyncio.gather(*tasks)
    except asyncio.CancelledError:
        logger.info("Tasks cancelled — shutting down")
    finally:
        await exchange.close()
        await state.close()
        logger.info("Bot shutdown complete")


def _shutdown(tasks: list[asyncio.Task]) -> None:
    """Cancel all running tasks (called by signal handler)."""
    logger.warning("Shutdown signal received")
    for task in tasks:
        task.cancel()


# ---------------------------------------------------------------------------
# Task definitions
# ---------------------------------------------------------------------------

async def price_feed_task(
    exchange: ExchangeClient,
    queue: asyncio.Queue,
    config: Config,
) -> None:
    """Stream mark prices from WebSocket into the tick queue.

    Reconnects automatically on disconnect using ws_reconnect_delay.

    Parameters
    ----------
    exchange:
        Exchange client with watch_mark_price() method.
    queue:
        Target queue for price ticks (float values).
    config:
        Used for ws_reconnect_delay.
    """
    raise NotImplementedError


async def candle_task(m2: M2Directional, config: Config) -> None:
    """Periodically fetch new candles and update M2 signal.

    Runs once per candle close interval (derived from m2.timeframe).
    Calls m2.on_candle() and stores the returned trend for grid strategies.

    Parameters
    ----------
    m2:
        M2Directional instance.
    config:
        Used for timeframe → sleep interval mapping.
    """
    raise NotImplementedError


async def main_loop_task(
    queue: asyncio.Queue,
    m1: M1BuyGrid,
    m3: M3SellGrid,
    trigger: TriggerSystem,
    best_pool: BestSidePool,
) -> None:
    """Drain the tick queue and dispatch each price tick to strategies.

    For every tick:
    1. Evaluate TriggerSystem.evaluate().
    2. Call M1BuyGrid.on_tick(price, trend).
    3. Call M3SellGrid.on_tick(price, trend).
    4. Call BestSidePool.update().

    Parameters
    ----------
    queue:
        Source queue of mark price floats.
    m1, m3:
        Grid strategies.
    trigger:
        TriggerSystem for lock evaluation.
    best_pool:
        BestSidePool for membership refresh.
    """
    raise NotImplementedError


async def tp_check_task(tp_chain: TPChain, config: Config) -> None:
    """Periodically evaluate the TP priority chain.

    Sleeps for tp.check_interval_seconds between evaluations.

    Parameters
    ----------
    tp_chain:
        TPChain instance.
    config:
        Used for check_interval_seconds.
    """
    raise NotImplementedError


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
