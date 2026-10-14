"""Configuration loaded from environment variables (.env supported)."""
from __future__ import annotations

import os
from dataclasses import dataclass, field

try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:  # python-dotenv is optional
    pass

BASE_URLS = {
    "live": "https://fapi.binance.com",
    # Binance USDT-M "Demo Trading" (testnet). Some docs still list
    # https://testnet.binancefuture.com - override with BINANCE_BASE_URL if needed.
    "testnet": "https://demo-fapi.binance.com",
}


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default).strip()


def _env_float(name: str, default: float) -> float:
    return float(_env(name, str(default)))


def _env_int(name: str, default: int) -> int:
    return int(_env(name, str(default)))


def _env_bool(name: str, default: bool) -> bool:
    return _env(name, str(default)).lower() in ("1", "true", "yes", "on")


@dataclass
class RiskConfig:
    risk_per_trade_pct: float = 1.0      # % of equity lost if SL is hit
    max_leverage: float = 3.0            # cap on notional / equity per position
    max_drawdown_pct: float = 15.0       # from peak equity -> halt + flatten
    daily_loss_limit_pct: float = 4.0    # from start-of-day equity -> no new entries today
    max_open_positions: int = 2
    min_confidence: float = 0.6
    min_reward_risk: float = 1.5
    sl_atr_min: float = 0.5              # SL distance bounds in ATR multiples
    sl_atr_max: float = 4.0
    tp_atr_max: float = 12.0


@dataclass
class LLMConfig:
    model: str = "claude-opus-5-5"
    effort: str = "medium"
    use_fallbacks: bool = True
    anonymize: bool = True               # hide symbol/prices/dates from the model
    cache_dir: str = "data/llm_cache"


@dataclass
class BinanceConfig:
    env: str = "testnet"
    api_key: str = ""
    api_secret: str = ""
    base_url: str = ""
    recv_window: int = 5000

    def __post_init__(self) -> None:
        if self.env not in BASE_URLS:
            raise ValueError(f"BINANCE_ENV must be one of {list(BASE_URLS)}, got {self.env!r}")
        if not self.base_url:
            self.base_url = BASE_URLS[self.env]


@dataclass
class Config:
    symbols: list[str] = field(default_factory=lambda: ["BTCUSDT", "ETHUSDT", "SOLUSDT", "BNBUSDT"])
    interval: str = "1h"
    leverage: int = 3
    dry_run: bool = True
    log_dir: str = "logs"
    state_file: str = "data/risk_state.json"   # delete this file to reset a drawdown halt
    risk: RiskConfig = field(default_factory=RiskConfig)
    llm: LLMConfig = field(default_factory=LLMConfig)
    binance: BinanceConfig = field(default_factory=BinanceConfig)


def load_config() -> Config:
    leverage = _env_int("LEVERAGE", 3)
    return Config(
        symbols=[s.strip().upper() for s in _env("SYMBOLS", "BTCUSDT,ETHUSDT,SOLUSDT,BNBUSDT").split(",") if s.strip()],
        interval=_env("INTERVAL", "1h"),
        leverage=leverage,
        dry_run=_env_bool("DRY_RUN", True),
        log_dir=_env("LOG_DIR", "logs"),
        state_file=_env("STATE_FILE", "data/risk_state.json"),
        risk=RiskConfig(
            risk_per_trade_pct=_env_float("RISK_PER_TRADE_PCT", 1.0),
            max_leverage=float(leverage),
            max_drawdown_pct=_env_float("MAX_DRAWDOWN_PCT", 15.0),
            daily_loss_limit_pct=_env_float("DAILY_LOSS_LIMIT_PCT", 4.0),
            max_open_positions=_env_int("MAX_OPEN_POSITIONS", 2),
            min_confidence=_env_float("MIN_CONFIDENCE", 0.6),
            min_reward_risk=_env_float("MIN_REWARD_RISK", 1.5),
        ),
        llm=LLMConfig(
            model=_env("LLM_MODEL", "claude-opus-5-5"),
            effort=_env("LLM_EFFORT", "medium"),
            use_fallbacks=_env_bool("LLM_FALLBACKS", True),
            anonymize=_env_bool("LLM_ANONYMIZE", True),
            cache_dir=_env("LLM_CACHE_DIR", "data/llm_cache"),
        ),
        binance=BinanceConfig(
            env=_env("BINANCE_ENV", "testnet").lower(),
            api_key=_env("BINANCE_API_KEY", ""),
            api_secret=_env("BINANCE_API_SECRET", ""),
            base_url=_env("BINANCE_BASE_URL", ""),
        ),
    )
