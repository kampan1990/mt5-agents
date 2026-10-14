import json
from pathlib import Path

import pytest

from bot.binance_client import BinanceAPIError, SymbolRules
from bot.config import Config
from bot.journal import Journal
from bot.models import Action, Decision
from bot.trader import Trader
from tests.test_bot import RULES, long, make_df


class FixedEngine:
    name = "fixed"

    def __init__(self, decision=None):
        self.decision = decision or long()

    def decide(self, snap):
        return Decision.hold("in position") if snap.position else self.decision


class FakeExchange:
    """Just enough of BinanceFutures for Trader; prices come from a synthetic closed-candle history."""

    def __init__(self, equity=10_000.0, fail_sl=False, fail_tp=False):
        self._time_offset_ms = 0
        self.eq, self.fail_sl, self.fail_tp = equity, fail_sl, fail_tp
        self.pos, self.algo, self.orders = {}, [], []
        self.df = make_df(500)
        self.price = float(self.df["close"].iloc[-1])

    def sync_time(self): pass
    def is_hedge_mode(self): return False
    def set_isolated(self, sym): pass
    def set_leverage(self, sym, lev): pass
    def equity(self): return self.eq
    def positions(self): return dict(self.pos)
    def funding_rate(self, sym): return 0.0001
    def rules(self, sym): return SymbolRules({**RULES, "symbol": sym})

    def klines(self, sym, interval, limit=500, **kw):
        out = []
        for ts, r in self.df.iterrows():
            ot = int(ts.timestamp() * 1000)
            out.append([ot, r.open, r.high, r.low, r.close, r.volume, ot + 3_599_999, 0, 0, 0, 0, 0])
        return out

    def open_algo_orders(self, symbol=None):
        return [o for o in self.algo if symbol is None or o["symbol"] == symbol]

    def cancel_all_algo_orders(self, symbol):
        n = len(self.open_algo_orders(symbol))
        self.algo = [o for o in self.algo if o["symbol"] != symbol]
        return n

    def market_order(self, symbol, side, qty, reduce_only=False):
        self.orders.append((symbol, side, str(qty), reduce_only))
        if reduce_only:
            self.pos.pop(symbol, None)
        else:
            sign = 1 if side == "BUY" else -1
            self.pos[symbol] = {"positionAmt": str(sign * qty), "entryPrice": str(self.price),
                                "markPrice": str(self.price), "unRealizedProfit": "0"}
        return {"avgPrice": str(self.price), "executedQty": str(qty), "orderId": 1}

    def conditional_order(self, symbol, side, order_type, trigger_price, qty, client_id=None):
        if (order_type == "STOP_MARKET" and self.fail_sl) or (order_type == "TAKE_PROFIT_MARKET" and self.fail_tp):
            raise BinanceAPIError(400, -2021, "Order would immediately trigger.")
        self.algo.append({"symbol": symbol, "algoId": len(self.algo) + 1, "orderType": order_type,
                          "triggerPrice": str(trigger_price), "quantity": str(qty)})


def make_trader(tmp_path, ex=None, engine=None, dry_run=False):
    cfg = Config(symbols=["BTCUSDT"], dry_run=dry_run, log_dir=str(tmp_path / "logs"),
                 state_file=str(tmp_path / "state.json"))
    ex = ex or FakeExchange()
    t = Trader(cfg, engine or FixedEngine(), ex, Journal(cfg.log_dir))
    t.prepare()
    return t, ex


def events(tmp_path):
    p = Path(tmp_path) / "logs" / "trades.jsonl"
    return [json.loads(line) for line in p.read_text().splitlines()]


def kinds(tmp_path):
    return [e["event"] for e in events(tmp_path)]


def test_open_places_protective_orders_and_logs_for_dashboard(tmp_path):
    t, ex = make_trader(tmp_path)
    t.run_cycle()
    assert "BTCUSDT" in ex.pos
    types = {o["orderType"]: float(o["triggerPrice"]) for o in ex.algo}
    assert set(types) == {"STOP_MARKET", "TAKE_PROFIT_MARKET"}
    assert types["STOP_MARKET"] < ex.price < types["TAKE_PROFIT_MARKET"]
    ev = {e["event"]: e for e in events(tmp_path)}
    assert ev["start"]["risk"]["max_drawdown_pct"] == 15 and ev["start"]["env"] == "testnet"
    assert ev["equity"]["equity"] == 10_000 and ev["equity"]["positions"] == []
    assert ev["decision"]["action"] == "LONG" and ev["decision"]["symbol"] == "BTCUSDT"
    assert float(ev["open"]["sl"]) == types["STOP_MARKET"]
    t.run_cycle()                                        # next candle: position now shows up in the equity event
    last_eq = [e for e in events(tmp_path) if e["event"] == "equity"][-1]
    assert last_eq["positions"][0]["symbol"] == "BTCUSDT" and last_eq["positions"][0]["side"] == "LONG"


def test_failed_stop_loss_closes_position(tmp_path):
    t, ex = make_trader(tmp_path, FakeExchange(fail_sl=True))
    t.run_cycle()
    assert ex.pos == {} and ex.orders[-1][3] is True
    assert "sl_failed" in kinds(tmp_path)


def test_failed_take_profit_closes_position_and_cancels_stop(tmp_path):
    t, ex = make_trader(tmp_path, FakeExchange(fail_tp=True))
    t.run_cycle()
    assert ex.pos == {} and ex.algo == []
    assert "tp_failed" in kinds(tmp_path)


def test_position_without_stop_loss_is_closed(tmp_path):
    ex = FakeExchange()
    ex.pos["BTCUSDT"] = {"positionAmt": "0.1", "entryPrice": "100", "markPrice": "100", "unRealizedProfit": "0"}
    t, _ = make_trader(tmp_path, ex, engine=FixedEngine(Decision.hold("x")))
    t.run_cycle()
    assert ex.pos == {} and "unprotected_position" in kinds(tmp_path)


def test_protected_position_is_left_alone(tmp_path):
    t, ex = make_trader(tmp_path)
    t.run_cycle()
    n_orders = len(ex.orders)
    t.run_cycle()
    assert len(ex.orders) == n_orders and "unprotected_position" not in kinds(tmp_path)


def test_dry_run_sends_no_orders(tmp_path):
    t, ex = make_trader(tmp_path, dry_run=True)
    t.run_cycle()
    assert ex.orders == [] and ex.algo == [] and "dry_run_open" in kinds(tmp_path)


def test_exchange_side_exit_logs_estimated_pnl_and_cleans_orphans(tmp_path):
    t, ex = make_trader(tmp_path)
    t.run_cycle()
    ex.pos["BTCUSDT"]["unRealizedProfit"] = "12.5"
    t.run_cycle()                                        # records last unrealized pnl
    ex.pos.clear()                                       # SL/TP filled on the exchange
    t.engine = FixedEngine(Decision.hold("wait"))        # don't let the engine re-enter in this cycle
    t.run_cycle()
    closed = [e for e in events(tmp_path) if e["event"] == "position_closed_on_exchange"]
    assert closed and closed[0]["approx_pnl"] == 12.5
    assert ex.open_algo_orders("BTCUSDT") == []          # the orphaned SL/TP legs were cancelled


def test_drawdown_halt_flattens_and_survives_restart(tmp_path):
    t, ex = make_trader(tmp_path, engine=FixedEngine(Decision.hold("x")))
    t.run_cycle()
    ex.pos["BTCUSDT"] = {"positionAmt": "0.1", "entryPrice": "100", "markPrice": "100", "unRealizedProfit": "0"}
    ex.algo.append({"symbol": "BTCUSDT", "algoId": 9, "orderType": "STOP_MARKET"})
    ex.eq = 8_000.0                                      # -20% from peak > 15% limit
    t.run_cycle()
    assert t.risk.halted and ex.pos == {} and "halt" in kinds(tmp_path)
    assert json.loads(Path(t.cfg.state_file).read_text())["halted"] is True

    ex2 = FakeExchange(equity=10_000.0)                  # "restart": new process, equity looks fine again
    t2, _ = make_trader(tmp_path, ex2)
    t2.run_cycle()
    assert t2.risk.halted and ex2.orders == []           # still halted until the state file is deleted


def test_peak_equity_is_restored_after_restart(tmp_path):
    t, ex = make_trader(tmp_path, engine=FixedEngine(Decision.hold("x")))
    ex.eq = 12_000.0
    t.run_cycle()
    ex.eq = 11_000.0
    t2, _ = make_trader(tmp_path, ex, engine=FixedEngine(Decision.hold("x")))
    t2.run_cycle()
    last = [e for e in events(tmp_path) if e["event"] == "equity"][-1]
    assert last["peak"] == 12_000.0 and last["drawdown_pct"] == pytest.approx(8.3333, abs=1e-3)
