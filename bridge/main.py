"""
main.py — XAUGLM bridge orchestrator.

Loop responsibilities (per architecture spec):
  1. Poll market data + news context.
  2. Call GLM for a trading judgment (with its own retry/circuit-breaker).
  3. Atomically write signal.json when a valid judgment comes back.
  4. Write heartbeat.json on its OWN cadence, via a separate thread, so it
     keeps proving "the bridge process is alive" independently of whether
     GLM calls are currently succeeding.
  5. Skip polling (and thus GLM API calls) when the market looks closed, to
     avoid burning API quota for nothing.
  6. Escalate to writing kill_switch.flag if the GLM circuit breaker keeps
     tripping over and over — a strong signal something is persistently wrong
     (bad API key, GLM outage, misconfiguration) that a human should look at.
     Per the project's kill-switch policy this is NEVER auto-cleared by the
     bridge; an operator must investigate and delete the file manually
     (see signal_writer.clear_kill_switch).

This process never talks to MT5's trading functions directly — it only ever
writes files into MT5's Common\\Files\\XAUGLM folder. The EA is always the
final decision-maker.
"""

from __future__ import annotations

import logging
import signal
import sys
import threading
import time
from datetime import datetime, timezone

from audit_logger import AuditLogger
from config import BridgeConfig, load_config
from glm_client import GlmClient
from heartbeat import emit_heartbeat
from market_data import MarketDataUnavailableError, get_market_context, shutdown as market_data_shutdown
from news_filter import is_news_blackout
from signal_writer import is_kill_switch_active, write_kill_switch, write_signal

logger = logging.getLogger("xauglm.main")


def _setup_logging(level_name: str) -> None:
    level = getattr(logging, level_name.upper(), logging.INFO)
    logging.basicConfig(
        level=level,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%SZ",
    )


def _is_market_likely_closed(now_utc: datetime) -> bool:
    """
    Cheap heuristic to avoid pointless GLM calls while the market is closed.
    NOT authoritative — the EA independently checks the real SYMBOL_TRADE_MODE
    before ever sending an order, which is the actual source of truth. This
    only saves API quota on the bridge side.

    TODO(refinement): if precise broker session times matter, extend
    market_data.py to expose the real SYMBOL_TRADE_MODE / trading session
    info via the MetaTrader5 package instead of this weekday heuristic.
    """
    weekday = now_utc.weekday()  # Mon=0 ... Sun=6
    if weekday == 5:  # Saturday: closed all day
        return True
    if weekday == 6 and now_utc.hour < 21:  # Sunday before ~21:00 UTC open
        return True
    if weekday == 4 and now_utc.hour >= 21:  # Friday after ~21:00 UTC close
        return True
    return False


class HeartbeatThread(threading.Thread):
    def __init__(self, cfg: BridgeConfig, glm_client: GlmClient, shared_state: dict, stop_event: threading.Event):
        super().__init__(name="xauglm-heartbeat", daemon=True)
        self._cfg = cfg
        self._glm = glm_client
        self._shared = shared_state
        self._stop = stop_event

    def run(self) -> None:
        logger.info("Heartbeat thread started (interval=%ds).", self._cfg.heartbeat_interval_seconds)
        while not self._stop.is_set():
            emit_heartbeat(
                self._cfg.signal_dir,
                bridge_status="running",
                last_signal_id=self._shared.get("last_signal_id"),
                circuit_breaker_open=self._glm.is_circuit_open(),
            )
            self._stop.wait(self._cfg.heartbeat_interval_seconds)
        # Final heartbeat announcing shutdown so the EA sees an honest status
        # (it will still go stale and be treated as "not fresh" shortly after).
        emit_heartbeat(
            self._cfg.signal_dir,
            bridge_status="stopped",
            last_signal_id=self._shared.get("last_signal_id"),
            circuit_breaker_open=self._glm.is_circuit_open(),
        )
        logger.info("Heartbeat thread stopped.")


def run() -> None:
    cfg = load_config()
    _setup_logging(cfg.log_level)

    logger.info("XAUGLM bridge starting. symbol=%s signal_dir=%s", cfg.symbol, cfg.signal_dir)
    if not cfg.mt5_common_files_path:
        logger.error(
            "MT5 Common\\Files path could not be determined. Set MT5_COMMON_FILES_PATH in .env. Exiting."
        )
        sys.exit(1)

    cfg.signal_dir.mkdir(parents=True, exist_ok=True)
    cfg.logs_dir.mkdir(parents=True, exist_ok=True)

    audit = AuditLogger(cfg.audit_log_path)
    glm = GlmClient(cfg.glm, audit_logger=audit)

    shared_state: dict = {"last_signal_id": None}
    stop_event = threading.Event()

    def _handle_signal(signum, _frame):
        logger.info("Received signal %s, shutting down gracefully...", signum)
        stop_event.set()

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    heartbeat_thread = HeartbeatThread(cfg, glm, shared_state, stop_event)
    heartbeat_thread.start()

    kill_switch_already_escalated = False

    try:
        while not stop_event.is_set():
            loop_start = time.monotonic()
            now_utc = datetime.now(timezone.utc)

            if is_kill_switch_active(cfg.signal_dir):
                logger.warning(
                    "kill_switch.flag is present — bridge will keep sending heartbeats but "
                    "will NOT call GLM or write new signals until an operator clears it."
                )
                stop_event.wait(cfg.poll_interval_seconds)
                continue

            if _is_market_likely_closed(now_utc):
                logger.debug("Market likely closed (weekend heuristic) — skipping this poll cycle.")
                stop_event.wait(cfg.poll_interval_seconds)
                continue

            try:
                market_ctx = get_market_context(cfg.symbol)
            except MarketDataUnavailableError as exc:
                logger.warning("Market data unavailable this cycle: %s", exc)
                audit.log_error("market_data", str(exc))
                stop_event.wait(cfg.poll_interval_seconds)
                continue

            news_blackout = is_news_blackout(
                currency="USD",
                buffer_minutes=cfg.news_buffer_minutes,
                enabled=cfg.news_filter_enabled,
            )

            signal_payload = glm.generate_signal(cfg.symbol, market_ctx.to_dict(), news_blackout)

            if signal_payload is not None:
                write_signal(cfg.signal_dir, signal_payload)
                audit.log_signal_written(signal_payload)
                shared_state["last_signal_id"] = signal_payload["signal_id"]
                logger.info(
                    "Signal written: action=%s confidence=%.1f id=%s",
                    signal_payload["action"],
                    signal_payload["confidence"],
                    signal_payload["signal_id"],
                )
            else:
                logger.info("No new signal this cycle (GLM call failed or circuit breaker open).")

            if (
                not kill_switch_already_escalated
                and glm.total_circuit_opens >= cfg.kill_switch_on_repeated_cb_failures
            ):
                reason = (
                    f"GLM circuit breaker has opened {glm.total_circuit_opens} times "
                    f"(threshold={cfg.kill_switch_on_repeated_cb_failures}) — persistent failure detected."
                )
                logger.error("ESCALATING TO KILL SWITCH: %s", reason)
                write_kill_switch(cfg.signal_dir, reason)
                audit.log_kill_switch("TRIPPED_BY_BRIDGE", reason)
                kill_switch_already_escalated = True

            elapsed = time.monotonic() - loop_start
            sleep_for = max(0.0, cfg.poll_interval_seconds - elapsed)
            stop_event.wait(sleep_for)

    finally:
        stop_event.set()
        heartbeat_thread.join(timeout=5.0)
        market_data_shutdown()
        logger.info("XAUGLM bridge stopped.")


if __name__ == "__main__":
    run()
