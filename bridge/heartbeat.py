"""
heartbeat.py — writes heartbeat.json on its own cadence.

Deliberately independent from the signal-generation cycle: the EA uses
heartbeat.json freshness to decide "is the bridge process even alive", which
must stay true even during periods where GLM calls are failing / the circuit
breaker is open / a poll cycle was skipped for news. If heartbeat writes were
tied to successful signal generation, a GLM outage would look identical (from
the EA's point of view) to the whole bridge process being dead, when actually
the operator needs to know the difference.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from signal_writer import write_heartbeat

logger = logging.getLogger("xauglm.heartbeat")

SCHEMA_VERSION = 1


def build_heartbeat_payload(
    bridge_status: str,
    last_signal_id: str | None,
    circuit_breaker_open: bool,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    payload = {
        "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "bridge_status": bridge_status,  # e.g. "running", "starting", "shutting_down"
        "schema_version": SCHEMA_VERSION,
        "last_signal_id": last_signal_id,
        "circuit_breaker_open": circuit_breaker_open,
    }
    if extra:
        payload.update(extra)
    return payload


def emit_heartbeat(
    signal_dir: Path,
    bridge_status: str,
    last_signal_id: str | None,
    circuit_breaker_open: bool,
    extra: dict[str, Any] | None = None,
) -> None:
    """Write heartbeat.json atomically. Never raises — a heartbeat write
    failure is logged and swallowed so it can never crash the main loop; the
    EA will simply see a stale heartbeat next poll and safely block trading,
    which is the correct fail-safe behavior anyway."""
    try:
        payload = build_heartbeat_payload(bridge_status, last_signal_id, circuit_breaker_open, extra)
        write_heartbeat(signal_dir, payload)
    except OSError as exc:
        logger.error("heartbeat: failed to write heartbeat.json: %s", exc)
