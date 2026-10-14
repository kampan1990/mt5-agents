"""Hard risk rules. The decision engine proposes; this module disposes.

Claude never chooses position size or leverage, and every order it is allowed to
open carries a stop-loss and take-profit computed here.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from datetime import date
from typing import Optional, Union

from .config import RiskConfig
from .models import Action, Decision, MarketSnapshot, OrderPlan


@dataclass
class Rejection:
    code: str      # short machine-readable key for stats
    reason: str


class RiskManager:
    def __init__(self, cfg: RiskConfig):
        self.cfg = cfg
        self.peak_equity: Optional[float] = None
        self.day: Optional[date] = None
        self.day_start_equity: Optional[float] = None
        self.halted = False          # max drawdown hit -> stop trading entirely
        self.halt_reason = ""

    # ---- persistence: a restart must not reset the drawdown guard ------------------
    def save_state(self, path: str) -> None:
        state = {"peak_equity": self.peak_equity, "day": self.day.isoformat() if self.day else None,
                 "day_start_equity": self.day_start_equity, "halted": self.halted, "halt_reason": self.halt_reason}
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        tmp = f"{path}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f)
        os.replace(tmp, path)

    def load_state(self, path: str) -> bool:
        try:
            with open(path, encoding="utf-8") as f:
                st = json.load(f)
            self.peak_equity = st.get("peak_equity")
            self.day = date.fromisoformat(st["day"]) if st.get("day") else None
            self.day_start_equity = st.get("day_start_equity")
            self.halted = bool(st.get("halted"))
            self.halt_reason = st.get("halt_reason", "")
            return True
        except (OSError, ValueError, KeyError):
            return False

    # ---- account-level guards -------------------------------------------------
    def update_equity(self, equity: float, today: date) -> None:
        if self.peak_equity is None or equity > self.peak_equity:
            self.peak_equity = equity
        if self.day != today:
            self.day, self.day_start_equity = today, equity
        dd = self.drawdown_pct(equity)
        if not self.halted and dd >= self.cfg.max_drawdown_pct:
            self.halted = True
            self.halt_reason = f"max drawdown {dd:.2f}% >= {self.cfg.max_drawdown_pct}%"

    def drawdown_pct(self, equity: float) -> float:
        if not self.peak_equity:
            return 0.0
        return max(0.0, (self.peak_equity - equity) / self.peak_equity * 100)

    def daily_loss_pct(self, equity: float) -> float:
        if not self.day_start_equity:
            return 0.0
        return max(0.0, (self.day_start_equity - equity) / self.day_start_equity * 100)

    # ---- per-trade validation -----------------------------------------------
    def evaluate(
        self,
        decision: Decision,
        snap: MarketSnapshot,
        equity: float,
        open_positions: int,
    ) -> Union[OrderPlan, Rejection]:
        cfg = self.cfg
        if decision.action not in (Action.LONG, Action.SHORT):
            return Rejection("not_entry", f"action {decision.action.value} does not open a position")
        if self.halted:
            return Rejection("halted", f"trading halted: {self.halt_reason}")
        if self.daily_loss_pct(equity) >= cfg.daily_loss_limit_pct:
            return Rejection("daily_loss", f"daily loss limit {cfg.daily_loss_limit_pct}% reached")
        if snap.position is not None:
            return Rejection("has_position", "position already open for symbol")
        if open_positions >= cfg.max_open_positions:
            return Rejection("max_positions", f"max open positions ({cfg.max_open_positions}) reached")
        if decision.confidence < cfg.min_confidence:
            return Rejection("low_confidence", f"confidence {decision.confidence:.2f} < {cfg.min_confidence}")
        if snap.atr <= 0 or snap.price <= 0 or equity <= 0:
            return Rejection("invalid_input", "invalid price/ATR/equity")

        sl_atr, tp_atr = decision.stop_loss_atr, decision.take_profit_atr
        if sl_atr is None or tp_atr is None:
            return Rejection("sl_tp_missing", "SL/TP missing - every order must have both")
        if not (cfg.sl_atr_min <= sl_atr <= cfg.sl_atr_max):
            return Rejection("sl_out_of_range", f"SL {sl_atr} ATR outside [{cfg.sl_atr_min}, {cfg.sl_atr_max}]")
        if tp_atr <= 0 or tp_atr > cfg.tp_atr_max:
            return Rejection("tp_out_of_range", f"TP {tp_atr} ATR outside (0, {cfg.tp_atr_max}]")
        if tp_atr / sl_atr < cfg.min_reward_risk:
            return Rejection("low_rr", f"reward/risk {tp_atr / sl_atr:.2f} < {cfg.min_reward_risk}")

        sl_dist, tp_dist = sl_atr * snap.atr, tp_atr * snap.atr
        side = decision.action.value
        if side == "LONG":
            sl, tp = snap.price - sl_dist, snap.price + tp_dist
        else:
            sl, tp = snap.price + sl_dist, snap.price - tp_dist
        if sl <= 0 or tp <= 0:
            return Rejection("invalid_sl_tp", "computed SL/TP not positive")

        risk_amount = equity * cfg.risk_per_trade_pct / 100
        qty = risk_amount / sl_dist
        max_notional = equity * cfg.max_leverage
        capped = False
        if qty * snap.price > max_notional:
            qty, capped = max_notional / snap.price, True
            risk_amount = qty * sl_dist

        return OrderPlan(
            symbol=snap.symbol, side=side, qty=qty, entry_price=snap.price,
            stop_loss=sl, take_profit=tp, risk_amount=risk_amount, decision=decision,
            meta={"sl_atr": sl_atr, "tp_atr": tp_atr, "leverage_capped": capped},
        )
