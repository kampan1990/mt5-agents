"""Logging: console/file logs plus a JSONL journal of every trade event."""
from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def setup_logging(log_dir: str, level: int = logging.INFO) -> None:
    Path(log_dir).mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)-7s %(name)s | %(message)s",
        handlers=[logging.StreamHandler(), logging.FileHandler(Path(log_dir) / "bot.log", encoding="utf-8")],
    )
    logging.getLogger("httpx").setLevel(logging.WARNING)


class Journal:
    def __init__(self, log_dir: str):
        Path(log_dir).mkdir(parents=True, exist_ok=True)
        self.path = Path(log_dir) / "trades.jsonl"

    def record(self, event: str, **data: Any) -> None:
        row = {"ts": datetime.now(timezone.utc).isoformat(), "event": event, **data}
        with self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(row, default=str, ensure_ascii=False) + "\n")
