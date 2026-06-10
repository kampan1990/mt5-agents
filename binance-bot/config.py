"""
config.py — Central configuration for Binance Futures Grid Bot.

All tunable parameters live here. Load via Config() singleton.
Environment variables (API keys) are read from a .env file or the shell.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()

# ---------------------------------------------------------------------------
# Exchange / Connection
# ---------------------------------------------------------------------------

@dataclass
class ExchangeConfig:
    api_key: str = field(default_factory=lambda: os.getenv("BINANCE_API_KEY", ""))
    api_secret: str = field(default_factory=lambda: os.getenv("BINANCE_API_SECRET", ""))
    testnet: bool = field(default_factory=lambda: os.getenv("BINANCE_TESTNET", "true").lower() == "true")
    # Rate-limit safety margin — stay below exchange burst limit
    requests_per_second: float = 5.0
    # WebSocket reconnect delay in seconds
    ws_reconnect_delay: float = 3.0


# ---------------------------------------------------------------------------
# Trading Universe
# ---------------------------------------------------------------------------

@dataclass
class SymbolConfig:
    symbol: str = "BTC/USDT:USDT"      # ccxt unified symbol for BTCUSDT perpetual
    leverage: int = 10
    # Minimum notional value enforced by exchange (USDT)
    min_notional: float = 5.0
    # Contract tick size (price precision)
    price_precision: int = 1            # decimal places for price rounding
    # Quantity precision
    qty_precision: int = 3              # decimal places for quantity rounding


# ---------------------------------------------------------------------------
# Magic Numbers — maps each sub-strategy to a unique integer ID
# (mirrors MQL5 magic number concept; stored in DB per position)
# ---------------------------------------------------------------------------

MAGIC_M1_BUY_GRID  = 1001   # M1: BUY grid (price descending)
MAGIC_M3_SELL_GRID = 1003   # M3: SELL grid (price ascending)
MAGIC_M2_DIRECTION = 1002   # M2: ADX-based directional trade


# ---------------------------------------------------------------------------
# Grid System
# ---------------------------------------------------------------------------

@dataclass
class GridConfig:
    # --- M1 BUY grid ---
    m1_grid_step_pips: float = 50.0     # pips between BUY grid levels
    m1_base_lot: float = 0.001          # base contract size per grid level
    m1_max_levels: int = 10             # hard cap on open M1 positions

    # --- M3 SELL grid ---
    m3_grid_step_pips: float = 50.0     # pips between SELL grid levels
    m3_base_lot: float = 0.001
    m3_max_levels: int = 10

    # --- Lot sizing multiplier logic ---
    # counter-trend grid (M1 buying into a downtrend) → aggressive sizing
    counter_trend_multiplier: float = 1.5
    # with-trend grid (M1 buying in an uptrend) → conservative sizing
    with_trend_multiplier: float = 1.0

    # 1 pip value in price units (for BTCUSDT, 1 pip = $1)
    pip_value: float = 1.0


# ---------------------------------------------------------------------------
# M2 — ADX Directional Module
# ---------------------------------------------------------------------------

@dataclass
class M2Config:
    timeframe: str = "1m"               # ccxt timeframe string
    adx_period: int = 14
    adx_threshold: float = 25.0         # minimum ADX for trend confirmation
    ema_fast: int = 9
    ema_slow: int = 21
    base_lot: float = 0.002

    # When in assist mode (triggered by Loss Trigger), M2 opens positions
    # only in the direction that helps offset the losing magic's PNL.
    assist_lot_multiplier: float = 2.0


# ---------------------------------------------------------------------------
# Trigger System
# ---------------------------------------------------------------------------

@dataclass
class TriggerConfig:
    # Loss threshold per magic (USDT).  When unrealised PNL of a single magic
    # drops below  -loss_trigger_threshold  that magic is "locked" (no new
    # orders) and M2 switches to assist mode.
    loss_trigger_threshold: float = -50.0

    # Locked magic will be unlocked when its PNL recovers above this value.
    loss_unlock_threshold: float = -10.0


# ---------------------------------------------------------------------------
# TP Priority Chain
# ---------------------------------------------------------------------------

@dataclass
class TPConfig:
    # SepTP — individual magic take-profit (USDT net PNL per magic)
    sep_tp_usdt: float = 20.0

    # PairTP — combined PNL of the two highest-profit magics
    pair_tp_usdt: float = 50.0

    # TotTP — combined PNL of all three magics
    tot_tp_usdt: float = 100.0

    # Check interval in seconds (to avoid hammering the API)
    check_interval_seconds: float = 1.0


# ---------------------------------------------------------------------------
# Best Side Pool
# ---------------------------------------------------------------------------

@dataclass
class BestSidePoolConfig:
    # Number of best BUY positions kept in the pool
    best_buy_count: int = 3
    # Number of best SELL positions kept in the pool
    best_sell_count: int = 3

    # Take-profit for the best-buy pool (USDT combined PNL)
    best_buy_tp_usdt: float = 30.0
    # Take-profit for the best-sell pool (USDT combined PNL)
    best_sell_tp_usdt: float = 30.0

    # Positions inside the pool are exempt from grid TP checks
    pool_immune_from_grid_tp: bool = True


# ---------------------------------------------------------------------------
# Smart Recovery Engine
# ---------------------------------------------------------------------------

@dataclass
class RecoveryConfig:
    # Fraction of winning-side sum allocated for recovery (0.0–1.0)
    recovery_ratio: float = 0.30        # 30 % of win sum

    # Positions are sorted by loss ascending (least negative first) and
    # covered greedily until budget is exhausted.
    # If net(position + recovery_allocation) >= 0 → close, else skip.
    min_net_to_close: float = 0.0


# ---------------------------------------------------------------------------
# Risk Management
# ---------------------------------------------------------------------------

@dataclass
class RiskConfig:
    # Global max drawdown as % of initial balance — bot halts if breached
    max_drawdown_pct: float = 20.0

    # Max total open positions across all magics
    max_total_positions: int = 30

    # Daily loss limit (USDT) — resets at 00:00 UTC
    daily_loss_limit_usdt: float = -200.0

    # Emergency stop flag file path — touching this file halts all trading
    emergency_stop_file: Path = Path("/tmp/bot_emergency_stop")

    # Minimum free margin ratio before opening new positions
    min_free_margin_ratio: float = 0.20


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

@dataclass
class DBConfig:
    path: str = "data/bot_state.db"
    # WAL mode for concurrent reads from monitoring tools
    wal_mode: bool = True


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

@dataclass
class LogConfig:
    level: str = "INFO"
    rotation: str = "10 MB"
    retention: str = "7 days"
    log_dir: str = "data/logs"
    # Whether to also log to stdout
    stdout: bool = True


# ---------------------------------------------------------------------------
# Master Config — single object passed to every component
# ---------------------------------------------------------------------------

@dataclass
class Config:
    exchange: ExchangeConfig = field(default_factory=ExchangeConfig)
    symbol: SymbolConfig = field(default_factory=SymbolConfig)
    grid: GridConfig = field(default_factory=GridConfig)
    m2: M2Config = field(default_factory=M2Config)
    trigger: TriggerConfig = field(default_factory=TriggerConfig)
    tp: TPConfig = field(default_factory=TPConfig)
    best_pool: BestSidePoolConfig = field(default_factory=BestSidePoolConfig)
    recovery: RecoveryConfig = field(default_factory=RecoveryConfig)
    risk: RiskConfig = field(default_factory=RiskConfig)
    db: DBConfig = field(default_factory=DBConfig)
    log: LogConfig = field(default_factory=LogConfig)


# Convenience singleton — import and use directly
DEFAULT_CONFIG = Config()
