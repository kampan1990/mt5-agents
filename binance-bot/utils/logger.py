"""
utils/logger.py — Loguru configuration for the bot.

Sets up:
- Stdout handler (INFO level, coloured)
- Rotating file handler (configurable level, rotation, retention)
- Structured log format including timestamp, level, module, and message

Call setup_logging(config) once at bot startup before any other module
logs messages.
"""

from __future__ import annotations

import sys
from pathlib import Path

from loguru import logger

from config import Config


def setup_logging(config: Config) -> None:
    """Configure loguru sinks from config.log settings.

    Parameters
    ----------
    config:
        Master config object.  Uses config.log.level, config.log.log_dir,
        config.log.rotation, config.log.retention, config.log.stdout.
    """
    log_cfg = config.log

    # Remove default sink
    logger.remove()

    fmt = (
        "<green>{time:YYYY-MM-DD HH:mm:ss.SSS}</green> | "
        "<level>{level: <8}</level> | "
        "<cyan>{name}</cyan>:<cyan>{function}</cyan>:<cyan>{line}</cyan> — "
        "<level>{message}</level>"
    )

    # Stdout sink
    if log_cfg.stdout:
        logger.add(
            sys.stdout,
            format=fmt,
            level=log_cfg.level,
            colorize=True,
            enqueue=True,
        )

    # File sink
    log_dir = Path(log_cfg.log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "bot_{time:YYYY-MM-DD}.log"

    logger.add(
        str(log_file),
        format=fmt,
        level=log_cfg.level,
        rotation=log_cfg.rotation,
        retention=log_cfg.retention,
        enqueue=True,
        backtrace=True,
        diagnose=True,
    )

    logger.info(
        "Logging initialised | level={} dir={}",
        log_cfg.level,
        log_dir,
    )
