"""
audit_logger.py — append-only JSONL audit trail of everything the bridge does.

Every GLM API call/response, every signal write, every circuit-breaker state
change is logged here as one JSON object per line, timestamped in UTC. This is
the paper trail that lets a human reconstruct exactly why a given signal.json
was produced (or why the bridge stopped producing one).

Deliberately dependency-free (stdlib json only) so it can never itself be the
reason the bridge fails to start.
"""

from __future__ import annotations

import json
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class AuditLogger:
    def __init__(self, path: str):
        self._path = Path(path)
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()

    def log(self, event_type: str, payload: dict[str, Any] | None = None) -> None:
        """Append one audit event. Never raises — a logging failure must not take
        down the trading loop; it prints to stderr instead."""
        record = {
            "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "event_type": event_type,
            "payload": payload or {},
        }
        line = json.dumps(record, ensure_ascii=False, default=str)
        try:
            with self._lock:
                with self._path.open("a", encoding="utf-8") as f:
                    f.write(line + "\n")
        except OSError as exc:  # pragma: no cover - defensive only
            print(f"[audit_logger] WARNING: failed to write audit log: {exc}")

    # Convenience wrappers for the most common event types -----------------

    def log_glm_call(
        self,
        signal_id: str,
        request_summary: dict[str, Any],
        response_text: str | None,
        parsed_signal: dict[str, Any] | None,
        latency_seconds: float,
        success: bool,
        error: str | None = None,
    ) -> None:
        self.log(
            "glm_call",
            {
                "signal_id": signal_id,
                "request_summary": request_summary,
                "response_text": (response_text or "")[:4000],  # cap size defensively
                "parsed_signal": parsed_signal,
                "latency_seconds": round(latency_seconds, 3),
                "success": success,
                "error": error,
            },
        )

    def log_signal_written(self, signal: dict[str, Any]) -> None:
        self.log("signal_written", {"signal": signal})

    def log_circuit_breaker(self, state: str, consecutive_failures: int, reason: str) -> None:
        self.log(
            "circuit_breaker",
            {"state": state, "consecutive_failures": consecutive_failures, "reason": reason},
        )

    def log_kill_switch(self, action: str, reason: str) -> None:
        self.log("kill_switch", {"action": action, "reason": reason})

    def log_error(self, source: str, message: str) -> None:
        self.log("error", {"source": source, "message": message})
