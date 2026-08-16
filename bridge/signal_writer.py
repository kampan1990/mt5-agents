"""
signal_writer.py — atomic writer for everything the EA reads.

All writes follow the same pattern the EA relies on for safety: write to a
temporary file in the SAME directory, flush+fsync it, then os.rename() it into
place. os.rename is atomic on both POSIX and Windows (NTFS) as long as source
and destination are on the same filesystem/volume, so the EA can never observe
a half-written signal.json / heartbeat.json.

The kill_switch.flag is different: it is a presence-only marker (the EA only
checks FileIsExist, not its contents), so writing it is a plain create, and
clearing it is a plain delete guarded by a confirmation to avoid accidental
resets of what is meant to be a manual, deliberate action.
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any


def _atomic_write_text(target_path: Path, content: str) -> None:
    target_path.parent.mkdir(parents=True, exist_ok=True)

    fd, tmp_path = tempfile.mkstemp(
        dir=str(target_path.parent), prefix=target_path.name + ".", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, target_path)  # atomic on POSIX and Windows
    except Exception:
        # Best-effort cleanup of the temp file if the rename never happened.
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise


def write_signal(signal_dir: Path, signal: dict[str, Any]) -> Path:
    """Atomically write signal.json. `signal` must already conform to the
    GLM Signal JSON Schema (schema_version, action, confidence, etc.) — this
    function does not itself validate content, only writes it safely."""
    target = signal_dir / "signal.json"
    _atomic_write_text(target, json.dumps(signal, ensure_ascii=False, indent=2))
    return target


def write_heartbeat(signal_dir: Path, heartbeat: dict[str, Any]) -> Path:
    """Atomically write heartbeat.json. Written on its OWN cadence, independent
    of whether signal generation is currently succeeding — the EA uses this to
    tell 'bridge process alive' apart from 'GLM call failing right now'."""
    target = signal_dir / "heartbeat.json"
    _atomic_write_text(target, json.dumps(heartbeat, ensure_ascii=False, indent=2))
    return target


def write_kill_switch(signal_dir: Path, reason: str) -> Path:
    """Create kill_switch.flag. The EA only checks for the file's *existence*,
    so content is informational (for a human reading it later) only."""
    target = signal_dir / "kill_switch.flag"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        f"reason: {reason}\n"
        f"NOTE: per policy this does NOT auto-reset. "
        f"Delete this file manually once the condition has been investigated "
        f"and resolved to resume trading.\n",
        encoding="utf-8",
    )
    return target


def is_kill_switch_active(signal_dir: Path) -> bool:
    return (signal_dir / "kill_switch.flag").exists()


def clear_kill_switch(signal_dir: Path, confirm: bool = False) -> bool:
    """Delete kill_switch.flag. Requires confirm=True — this is a deliberately
    manual action (see project kill-switch policy: never auto-reset). Intended
    to be called from an operator-run script/REPL, not from the bridge's own
    automatic loop."""
    if not confirm:
        raise ValueError(
            "clear_kill_switch requires confirm=True — this is a manual-only action "
            "per the kill-switch policy (never auto-reset)."
        )
    target = signal_dir / "kill_switch.flag"
    if target.exists():
        target.unlink()
        return True
    return False
