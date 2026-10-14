"""Live / testnet trading loop.

Once per closed candle, for each symbol:
  sync account -> drawdown guard -> clean orphan SL/TP -> snapshot -> decide
  -> risk check -> market entry -> reduce-only SL + TP on the exchange.
If the stop-loss cannot be placed, the position is closed immediately.
"""
from __future__ import annotations

import json
import logging
import time
import uuid
from datetime import datetime, timezone
from typing import Optional

from .binance_client import BinanceAPIError, BinanceFutures
from .config import Config
from .engines import DecisionEngine
from .journal import Journal
from .market_data import build_snapshot, klines_to_df
from .models import Action, PositionInfo
from .risk import Rejection, RiskManager

log = logging.getLogger(__name__)

INTERVAL_MS = {"1m": 60_000, "5m": 300_000, "15m": 900_000, "30m": 1_800_000,
               "1h": 3_600_000, "2h": 7_200_000, "4h": 14_400_000}


class Trader:
    def __init__(self, cfg: Config, engine: DecisionEngine, exchange: BinanceFutures, journal: Journal):
        self.cfg = cfg
        self.engine = engine
        self.ex = exchange
        self.journal = journal
        self.risk = RiskManager(cfg.risk)
        self.bars_held: dict[str, int] = {}
        self.last_upnl: dict[str, float] = {}     # last seen unrealized PnL, used to estimate exchange-side exits
        self.flattened = False

    # ---- setup -------------------------------------------------------------
    def prepare(self) -> None:
        self.ex.sync_time()
        if self.ex.is_hedge_mode():
            raise RuntimeError("Account is in Hedge Mode - switch Binance Futures to One-way Mode")
        for sym in self.cfg.symbols:
            self.ex.rules(sym)
            if not self.cfg.dry_run:
                self.ex.set_isolated(sym)
                self.ex.set_leverage(sym, self.cfg.leverage)
        if self.risk.load_state(self.cfg.state_file):
            log.info("restored risk state: peak=%s halted=%s", self.risk.peak_equity, self.risk.halted)
        log.info("ready: env=%s dry_run=%s symbols=%s engine=%s",
                 self.cfg.binance.env, self.cfg.dry_run, self.cfg.symbols, self.engine.name)
        r = self.cfg.risk
        self.journal.record(
            "start", env=self.cfg.binance.env, dry_run=self.cfg.dry_run, symbols=self.cfg.symbols,
            engine=self.engine.name, interval=self.cfg.interval, leverage=self.cfg.leverage,
            risk={"risk_per_trade_pct": r.risk_per_trade_pct, "max_drawdown_pct": r.max_drawdown_pct,
                  "daily_loss_limit_pct": r.daily_loss_limit_pct, "max_open_positions": r.max_open_positions,
                  "min_confidence": r.min_confidence, "min_reward_risk": r.min_reward_risk},
        )

    # ---- main loop -----------------------------------------------------------
    def run_forever(self) -> None:
        self.prepare()
        step = INTERVAL_MS[self.cfg.interval]
        while True:
            now = int(time.time() * 1000) + self.ex._time_offset_ms
            next_close = (now // step + 1) * step
            wait = (next_close - now) / 1000 + 3  # small buffer so the candle is final
            log.info("sleeping %.0fs until next %s close", wait, self.cfg.interval)
            time.sleep(wait)
            try:
                self.run_cycle()
            except Exception:  # keep the bot alive; the exchange still holds SL/TP
                log.exception("cycle failed")
                self.journal.record("cycle_error")

    def run_cycle(self) -> None:
        equity = self.ex.equity()
        positions = self.ex.positions()
        self.risk.update_equity(equity, datetime.now(timezone.utc).date())
        self.risk.save_state(self.cfg.state_file)
        self.journal.record(
            "equity", equity=equity, peak=self.risk.peak_equity,
            drawdown_pct=round(self.risk.drawdown_pct(equity), 4),
            daily_loss_pct=round(self.risk.daily_loss_pct(equity), 4), halted=self.risk.halted,
            positions=[{"symbol": sym, "side": "LONG" if float(r["positionAmt"]) > 0 else "SHORT",
                        "qty": abs(float(r["positionAmt"])), "entry": float(r["entryPrice"]),
                        "mark": float(r.get("markPrice") or 0), "upnl": float(r.get("unRealizedProfit") or 0)}
                       for sym, r in positions.items()],
        )
        for sym, r in positions.items():
            self.last_upnl[sym] = float(r.get("unRealizedProfit") or 0)
        log.info("equity=%.2f dd=%.2f%% daily_loss=%.2f%% open=%d",
                 equity, self.risk.drawdown_pct(equity), self.risk.daily_loss_pct(equity), len(positions))

        if self.risk.halted:
            if not self.flattened:
                log.critical("HALT: %s - closing all positions", self.risk.halt_reason)
                self.journal.record("halt", reason=self.risk.halt_reason, equity=equity)
                self.flatten_all(positions)
                self.flattened = True
            return

        for sym in self.cfg.symbols:
            try:
                self.process_symbol(sym, equity, positions)
            except BinanceAPIError as e:
                log.error("%s: Binance error %s", sym, e)
                self.journal.record("error", symbol=sym, code=e.code, msg=e.msg)
            positions = self.ex.positions()

    def process_symbol(self, sym: str, equity: float, positions: dict[str, dict]) -> None:
        raw = positions.get(sym)
        pos = None
        if raw:
            amt = float(raw["positionAmt"])
            self.bars_held[sym] = self.bars_held.get(sym, 0) + 1
            pos = PositionInfo(side="LONG" if amt > 0 else "SHORT", qty=abs(amt),
                               entry_price=float(raw["entryPrice"]),
                               unrealized_pnl=float(raw.get("unRealizedProfit", 0)),
                               bars_held=self.bars_held[sym])
            # every position must be protected by an exchange-side stop-loss
            # (matched on the serialized order so it does not depend on the algo API's exact field names)
            if not self.cfg.dry_run and not any(
                "STOP_MARKET" in json.dumps(o) for o in self.ex.open_algo_orders(sym)
            ):
                log.critical("%s: position has no stop-loss on the exchange - closing it", sym)
                self.journal.record("unprotected_position", symbol=sym, side=pos.side, qty=pos.qty)
                self.close_position(sym, pos, reason="no_stop_loss")
                return
        else:
            if self.bars_held.pop(sym, None) is not None:
                # SL/TP filled on the exchange; the last unrealized PnL is only an estimate of the result
                self.journal.record("position_closed_on_exchange", symbol=sym,
                                    approx_pnl=self.last_upnl.pop(sym, None))
            # SL or TP filled -> the other leg is now an orphan; remove it
            if not self.cfg.dry_run and self.ex.cancel_all_algo_orders(sym):
                log.info("%s: cancelled orphan SL/TP orders", sym)

        now = int(time.time() * 1000) + self.ex._time_offset_ms
        rows = [r for r in self.ex.klines(sym, self.cfg.interval, limit=500) if r[6] < now]
        df = klines_to_df(rows)
        snap = build_snapshot(df, sym, self.cfg.interval, position=pos,
                              funding_rate=self.ex.funding_rate(sym), anonymize=self.cfg.llm.anonymize)
        decision = self.engine.decide(snap)
        log.info("%s: %s conf=%.2f sl=%s tp=%s | %s", sym, decision.action.value, decision.confidence,
                 decision.stop_loss_atr, decision.take_profit_atr, decision.reasoning)
        self.journal.record("decision", symbol=sym, price=snap.price, atr=snap.atr, **decision.model_dump(mode="json"))

        if decision.action == Action.CLOSE and pos is not None:
            if decision.confidence >= self.cfg.risk.min_confidence:
                self.close_position(sym, pos, reason="signal")
            return
        if decision.action not in (Action.LONG, Action.SHORT):
            return

        plan = self.risk.evaluate(decision, snap, equity, open_positions=len(positions))
        if isinstance(plan, Rejection):
            log.info("%s: rejected (%s)", sym, plan.reason)
            self.journal.record("rejected", symbol=sym, code=plan.code, reason=plan.reason)
            return
        self.open_position(plan)

    # ---- execution -----------------------------------------------------------
    def open_position(self, plan) -> None:
        rules = self.ex.rules(plan.symbol)
        qty = rules.round_qty(plan.qty)
        if qty < rules.min_qty or qty * rules.round_price(plan.entry_price) < rules.min_notional:
            log.warning("%s: qty %s below exchange minimum - skip", plan.symbol, qty)
            self.journal.record("rejected", symbol=plan.symbol, code="below_min_qty", qty=str(qty))
            return

        entry_side = "BUY" if plan.side == "LONG" else "SELL"
        exit_side = "SELL" if plan.side == "LONG" else "BUY"
        summary = dict(symbol=plan.symbol, side=plan.side, qty=str(qty), ref_price=plan.entry_price,
                       sl=plan.stop_loss, tp=plan.take_profit, risk=round(plan.risk_amount, 2), meta=plan.meta)
        if self.cfg.dry_run:
            log.info("[DRY RUN] would open %s", summary)
            self.journal.record("dry_run_open", **summary)
            return

        order = self.ex.market_order(plan.symbol, entry_side, qty)
        fill = float(order.get("avgPrice") or plan.entry_price)
        filled_qty = rules.round_qty(float(order.get("executedQty") or qty))
        shift = fill - plan.entry_price          # keep SL/TP distances relative to the real fill
        sl = rules.round_price(plan.stop_loss + shift)
        tp = rules.round_price(plan.take_profit + shift)
        self.journal.record("open", **{**summary, "fill": fill, "qty": str(filled_qty), "sl": str(sl), "tp": str(tp),
                                       "order_id": order.get("orderId")})
        log.info("%s: opened %s %s @ %s SL=%s TP=%s", plan.symbol, plan.side, filled_qty, fill, sl, tp)

        tag = uuid.uuid4().hex[:12]
        try:
            self.ex.conditional_order(plan.symbol, exit_side, "STOP_MARKET", sl, filled_qty, f"sl-{tag}")
        except BinanceAPIError as e:
            log.critical("%s: STOP-LOSS FAILED (%s) - closing position", plan.symbol, e)
            self.journal.record("sl_failed", symbol=plan.symbol, code=e.code, msg=e.msg)
            self.ex.market_order(plan.symbol, exit_side, filled_qty, reduce_only=True)
            return
        try:
            self.ex.conditional_order(plan.symbol, exit_side, "TAKE_PROFIT_MARKET", tp, filled_qty, f"tp-{tag}")
        except BinanceAPIError as e:
            log.critical("%s: TAKE-PROFIT FAILED (%s) - closing position", plan.symbol, e)
            self.journal.record("tp_failed", symbol=plan.symbol, code=e.code, msg=e.msg)
            self.ex.cancel_all_algo_orders(plan.symbol)
            self.ex.market_order(plan.symbol, exit_side, filled_qty, reduce_only=True)
            return
        self.bars_held[plan.symbol] = 0

    def close_position(self, sym: str, pos: PositionInfo, reason: str) -> None:
        if self.cfg.dry_run:
            log.info("[DRY RUN] would close %s %s (%s)", sym, pos.side, reason)
            self.journal.record("dry_run_close", symbol=sym, side=pos.side, reason=reason)
            return
        side = "SELL" if pos.side == "LONG" else "BUY"
        rules = self.ex.rules(sym)
        order = self.ex.market_order(sym, side, rules.round_qty(pos.qty), reduce_only=True)
        self.ex.cancel_all_algo_orders(sym)
        self.bars_held.pop(sym, None)
        fill = float(order.get("avgPrice") or 0) or None
        direction = 1 if pos.side == "LONG" else -1
        pnl = (fill - pos.entry_price) * pos.qty * direction if fill else None
        self.journal.record("close", symbol=sym, side=pos.side, reason=reason, qty=pos.qty,
                            fill=fill, entry=pos.entry_price, approx_pnl=pnl)
        self.last_upnl.pop(sym, None)
        log.info("%s: closed %s (%s) @ %s", sym, pos.side, reason, order.get("avgPrice"))

    def flatten_all(self, positions: Optional[dict[str, dict]] = None) -> None:
        positions = self.ex.positions() if positions is None else positions
        for sym, raw in positions.items():
            amt = float(raw["positionAmt"])
            pos = PositionInfo(side="LONG" if amt > 0 else "SHORT", qty=abs(amt), entry_price=float(raw["entryPrice"]))
            try:
                self.close_position(sym, pos, reason="halt")
            except BinanceAPIError as e:
                log.error("%s: flatten failed: %s", sym, e)
