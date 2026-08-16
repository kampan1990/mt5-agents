"""
config.py — XAUGLM bridge configuration.

Loads all runtime configuration from environment variables (via a .env file in
this directory, see .env.example). Nothing here is hardcoded to a specific
machine or user — in particular the MT5 "Common\\Files" path is auto-detected
per-OS with an explicit environment-variable override, since that path differs
per Windows user account and is often wrong to hardcode.

The GLM API key is ALWAYS read from the environment. It is never hardcoded and
must never be logged or printed.
"""

from __future__ import annotations

import os
import platform
import sys
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

# Load .env from this file's directory regardless of the process's cwd.
_ENV_PATH = Path(__file__).resolve().parent / ".env"
load_dotenv(dotenv_path=_ENV_PATH)


def _env_str(name: str, default: str | None = None, required: bool = False) -> str:
    val = os.environ.get(name, default)
    if required and not val:
        raise RuntimeError(
            f"Missing required environment variable: {name}. "
            f"Copy .env.example to .env and fill it in."
        )
    return val or ""


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return int(raw)
    except ValueError:
        raise RuntimeError(f"Environment variable {name}='{raw}' is not a valid integer.")


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return float(raw)
    except ValueError:
        raise RuntimeError(f"Environment variable {name}='{raw}' is not a valid float.")


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _autodetect_mt5_common_files_path() -> str | None:
    """
    Best-effort auto-detection of the MetaTrader 5 "Common\\Files" folder.

    This folder is shared across ALL MT5 terminal installations for the current
    Windows user, at:
        %APPDATA%\\MetaQuotes\\Terminal\\Common\\Files

    On non-Windows hosts (Linux/macOS, e.g. MT5 running under Wine, or the bridge
    running on a different machine than the terminal) auto-detection cannot work
    reliably — MT5_COMMON_FILES_PATH must be set explicitly in that case.
    """
    if platform.system() == "Windows":
        appdata = os.environ.get("APPDATA")
        if appdata:
            candidate = Path(appdata) / "MetaQuotes" / "Terminal" / "Common" / "Files"
            if candidate.exists():
                return str(candidate)
            # Directory may not exist yet on a fresh MT5 install — still a valid
            # target, MetaTrader (or our own signal_writer) will create it.
            return str(candidate)
    return None


@dataclass
class GlmConfig:
    api_key: str
    api_base_url: str
    model: str
    request_timeout_seconds: float
    max_retries: int
    backoff_base_seconds: float
    circuit_breaker_failure_threshold: int
    circuit_breaker_cooldown_seconds: float


@dataclass
class BridgeConfig:
    symbol: str
    mt5_common_files_path: str
    signal_subfolder: str
    poll_interval_seconds: int
    heartbeat_interval_seconds: int
    signal_timeout_seconds: int  # informational; must match the EA's InpSignalTimeoutSeconds
    news_filter_enabled: bool
    news_buffer_minutes: int
    kill_switch_on_repeated_cb_failures: int
    log_level: str
    audit_log_path: str
    glm: GlmConfig = field(default_factory=lambda: None)  # type: ignore[assignment]

    @property
    def signal_dir(self) -> Path:
        return Path(self.mt5_common_files_path) / self.signal_subfolder

    @property
    def signal_file_path(self) -> Path:
        return self.signal_dir / "signal.json"

    @property
    def heartbeat_file_path(self) -> Path:
        return self.signal_dir / "heartbeat.json"

    @property
    def kill_switch_file_path(self) -> Path:
        return self.signal_dir / "kill_switch.flag"

    @property
    def logs_dir(self) -> Path:
        return self.signal_dir / "logs"


def load_config() -> BridgeConfig:
    mt5_common_files_path = os.environ.get("MT5_COMMON_FILES_PATH", "").strip()
    if not mt5_common_files_path:
        detected = _autodetect_mt5_common_files_path()
        if detected:
            mt5_common_files_path = detected
        else:
            print(
                "[config] WARNING: could not auto-detect MT5 Common\\Files path "
                "(not running on Windows, or APPDATA unavailable). "
                "Set MT5_COMMON_FILES_PATH explicitly in .env — e.g. the shared "
                "path MetaTrader reports under Terminal Data Folder -> Common.",
                file=sys.stderr,
            )

    glm = GlmConfig(
        api_key=_env_str("GLM_API_KEY", required=True),
        api_base_url=_env_str(
            "GLM_API_BASE_URL",
            default="https://open.bigmodel.cn/api/paas/v4/chat/completions",
        ),
        model=_env_str("GLM_MODEL", default="glm-4-plus"),
        request_timeout_seconds=_env_float("GLM_REQUEST_TIMEOUT_SECONDS", 10.0),
        max_retries=_env_int("GLM_MAX_RETRIES", 3),
        backoff_base_seconds=_env_float("GLM_BACKOFF_BASE_SECONDS", 1.0),
        circuit_breaker_failure_threshold=_env_int("GLM_CIRCUIT_BREAKER_FAILURE_THRESHOLD", 3),
        circuit_breaker_cooldown_seconds=_env_float("GLM_CIRCUIT_BREAKER_COOLDOWN_SECONDS", 300.0),
    )

    cfg = BridgeConfig(
        symbol=_env_str("SYMBOL", default="XAUUSD"),
        mt5_common_files_path=mt5_common_files_path,
        signal_subfolder=_env_str("SIGNAL_SUBFOLDER", default="XAUGLM"),
        poll_interval_seconds=_env_int("POLL_INTERVAL_SECONDS", 30),
        heartbeat_interval_seconds=_env_int("HEARTBEAT_INTERVAL_SECONDS", 20),
        signal_timeout_seconds=_env_int("SIGNAL_TIMEOUT_SECONDS", 60),
        news_filter_enabled=_env_bool("NEWS_FILTER_ENABLED", True),
        news_buffer_minutes=_env_int("NEWS_BUFFER_MINUTES", 30),
        kill_switch_on_repeated_cb_failures=_env_int("KILL_SWITCH_ON_REPEATED_CB_FAILURES", 10),
        log_level=_env_str("LOG_LEVEL", default="INFO"),
        audit_log_path=_env_str("AUDIT_LOG_PATH", default=""),
        glm=glm,
    )

    if not cfg.audit_log_path:
        cfg.audit_log_path = str(cfg.logs_dir / "audit.jsonl")

    return cfg
