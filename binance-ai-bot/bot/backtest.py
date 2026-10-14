"""Bar-by-bar backtester for one symbol.

Execution model (conservative):
- Decisions are made on the close of bar i using candles 0..i only.
- Entries/exits fill at that close +/- slippage, taker fee on both sides.
- SL/TP are checked against the high/low of the following bars. If a bar touches
  both, the stop-loss is assumed to fill first.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Optional

import pandas as pd

from .config import RiskConfig
from .engines import DecisionEngine
from .market_data import LOOKBACK_BARS, build_snapshot
from .models import Action, PositionInfo
from .risk import Rejection, RiskManager

BARS_PER_YEAR = {"5m": 105120, "15m": 35040, "30m": 17520, "1h": 8760, "2h": 4380, "4h": 2190, "1d": 365}


@dataclass
class Trade:
    side: str
    entry_time: pd.Timestamp
    entry_price: float
    qty: float
    stop_loss: float
    take_profit: float
    risk_amount: float
    exit_time: Optional[pd.Timestamp] = None
    exit_price: Optional[float] = None
    exit_reason: str = ""
    pnl: float = 0.0
    fees: float = 0.0
    bars_held: int = 0

    @property
    def r_multiple(self) -> float:
        return self.pnl / self.risk_amount if self.risk_amount else 0.0


@dataclass
class BacktestResult:
    symbol: str
    engine: str
    initial_equity: float
    final_equity: float
    trades: list[Trade]
    equity_curve: pd.Series
    rejections: dict[str, int] = field(default_factory=dict)
    halted: str = ""

    def metrics(self, interval: str = "1h") -> dict:
        closed = [t for t in self.trades if t.exit_time is not None]
        wins = [t for t in closed if t.pnl > 0]
        gross_win = sum(t.pnl for t in wins)
        gross_loss = -sum(t.pnl for t in closed if t.pnl <= 0)
        curve = self.equity_curve
        dd = ((curve.cummax() - curve) / curve.cummax()).max() * 100 if len(curve) else 0.0
        rets = curve.pct_change().dropna()
        sharpe = (
            rets.mean() / rets.std() * math.sqrt(BARS_PER_YEAR.get(interval, 8760))
            if len(rets) > 1 and rets.std() > 0 else 0.0
        )
        return {
            "symbol": self.symbol,
            "engine": self.engine,
            "total_return_pct": round((self.final_equity / self.initial_equity - 1) * 100, 2),
            "max_drawdown_pct": round(float(dd), 2),
            "trades": len(closed),
            "win_rate_pct": round(len(wins) / len(closed) * 100, 1) if closed else 0.0,
            "profit_factor": round(gross_win / gross_loss, 2) if gross_loss else (float("inf") if gross_win else 0.0),
            "avg_r": round(sum(t.r_multiple for t in closed) / len(closed), 2) if closed else 0.0,
            "sharpe": round(float(sharpe), 2),
            "fees_paid": round(sum(t.fees for t in closed), 2),
            "halted": self.halted,
        }


class Backtester:
    def __init__(
        self,
        engine: DecisionEngine,
        risk_cfg: RiskConfig,
        interval: str = "1h",
        initial_equity: float = 10_000.0,
        fee_rate: float = 0.0005,        # Binance USDT-M taker 0.05%
        slippage: float = 0.0002,
        decision_every: int = 1,         # call the engine every N bars
        warmup: int = 210,
        anonymize: bool = True,
    ):
        self.engine = engine
        self.risk_cfg = risk_cfg
        self.interval = interval
        self.initial_equity = initial_equity
        self.fee_rate = fee_rate
        self.slippage = slippage
        self.decision_every = max(1, decision_every)
        self.warmup = warmup
        self.anonymize = anonymize

    def run(self, df: pd.DataFrame, symbol: str) -> BacktestResult:
        risk = RiskManager(self.risk_cfg)
        cash = self.initial_equity
        pos: Optional[Trade] = None
        trades: list[Trade] = []
        rejections: dict[str, int] = {}
        curve: dict[pd.Timestamp, float] = {}

        def close_pos(t: Trade, price: float, ts: pd.Timestamp, reason: str) -> float:
            direction = 1 if t.side == "LONG" else -1
            fee = price * t.qty * self.fee_rate
            t.exit_price, t.exit_time, t.exit_reason = price, ts, reason
            t.pnl += (price - t.entry_price) * t.qty * direction - fee
            t.fees += fee
            return (price - t.entry_price) * t.qty * direction - fee

        highs, lows, closes = df["high"].to_numpy(), df["low"].to_numpy(), df["close"].to_numpy()
        index = df.index
        for i in range(self.warmup, len(df)):
            ts = index[i]
            # 1) the open position lives through bar i: check SL/TP on its range
            if pos is not None:
                pos.bars_held += 1
                hit_sl = lows[i] <= pos.stop_loss if pos.side == "LONG" else highs[i] >= pos.stop_loss
                hit_tp = highs[i] >= pos.take_profit if pos.side == "LONG" else lows[i] <= pos.take_profit
                if hit_sl or hit_tp:
                    level = pos.stop_loss if hit_sl else pos.take_profit
                    slip = -1 if (pos.side == "LONG") == hit_sl else 1  # stops slip against us
                    fill = level * (1 + slip * self.slippage) if hit_sl else level
                    cash += close_pos(pos, fill, ts, "SL" if hit_sl else "TP")
                    trades.append(pos)
                    pos = None

            price = closes[i]
            equity = cash + self._unrealized(pos, price)
            risk.update_equity(equity, ts.date())
            curve[ts] = equity

            if risk.halted:
                if pos is not None:
                    cash += close_pos(pos, self._fill(price, pos.side, exit=True), ts, "HALT")
                    trades.append(pos)
                    pos = None
                    curve[ts] = cash
                break

            # 2) decision on bar close
            if (i - self.warmup) % self.decision_every:
                continue
            info = (
                PositionInfo(side=pos.side, qty=pos.qty, entry_price=pos.entry_price, bars_held=pos.bars_held)
                if pos else None
            )
            snap = build_snapshot(df.iloc[max(0, i + 1 - LOOKBACK_BARS): i + 1], symbol, self.interval,
                                  position=info, anonymize=self.anonymize)
            decision = self.engine.decide(snap)

            if decision.action == Action.CLOSE and pos is not None:
                cash += close_pos(pos, self._fill(price, pos.side, exit=True), ts, "SIGNAL")
                trades.append(pos)
                pos = None
                continue
            if decision.action not in (Action.LONG, Action.SHORT):
                continue

            plan = risk.evaluate(decision, snap, equity, open_positions=1 if pos else 0)
            if isinstance(plan, Rejection):
                rejections[plan.code] = rejections.get(plan.code, 0) + 1
                continue

            fill = self._fill(price, plan.side, exit=False)
            fee = fill * plan.qty * self.fee_rate
            # keep the planned SL/TP distances relative to the actual fill
            shift = fill - plan.entry_price
            pos = Trade(side=plan.side, entry_time=ts, entry_price=fill, qty=plan.qty,
                        stop_loss=plan.stop_loss + shift, take_profit=plan.take_profit + shift,
                        risk_amount=plan.risk_amount, pnl=-fee, fees=fee)
            cash -= fee

        if pos is not None:  # mark-to-market exit at the end of data
            cash += close_pos(pos, closes[-1], index[-1], "END")
            trades.append(pos)
            curve[index[-1]] = cash

        return BacktestResult(
            symbol=symbol, engine=self.engine.name, initial_equity=self.initial_equity,
            final_equity=cash, trades=trades, equity_curve=pd.Series(curve, dtype=float),
            rejections=rejections, halted=risk.halt_reason,
        )

    def _fill(self, price: float, side: str, exit: bool) -> float:
        buying = (side == "LONG") != exit
        return price * (1 + self.slippage) if buying else price * (1 - self.slippage)

    @staticmethod
    def _unrealized(pos: Optional[Trade], price: float) -> float:
        if pos is None:
            return 0.0
        direction = 1 if pos.side == "LONG" else -1
        return (price - pos.entry_price) * pos.qty * direction
