import hashlib
import hmac
import json
from datetime import date
from types import SimpleNamespace
from urllib.parse import parse_qsl, urlsplit

import httpx
import numpy as np
import pandas as pd
import pytest

from bot import indicators as ind
from bot.backtest import Backtester
from bot.binance_client import BinanceAPIError, BinanceFutures, SymbolRules
from bot.config import BinanceConfig, LLMConfig, RiskConfig
from bot.engines import ClaudeEngine, RuleEngine
from bot.market_data import build_snapshot
from bot.models import Action, Decision, MarketSnapshot, PositionInfo
from bot.risk import Rejection, RiskManager


def make_df(n=800, seed=0, drift=0.0005):
    rng = np.random.default_rng(seed)
    close = 100 * np.exp(np.cumsum(rng.normal(drift, 0.01, n)))
    open_ = np.r_[close[0], close[:-1]]
    high = np.maximum(open_, close) * (1 + rng.uniform(0, 0.005, n))
    low = np.minimum(open_, close) * (1 - rng.uniform(0, 0.005, n))
    idx = pd.date_range("2025-01-01", periods=n, freq="1h", tz="UTC")
    return pd.DataFrame({"open": open_, "high": high, "low": low, "close": close,
                         "volume": rng.uniform(100, 200, n)}, index=idx)


def snap(price=100.0, atr=2.0, position=None):
    return MarketSnapshot(symbol="BTCUSDT", price=price, atr=atr, features={}, position=position)


# ---- indicators -------------------------------------------------------------
def test_rsi_bounds_and_extremes():
    up = pd.Series(np.arange(1, 60, dtype=float))
    assert ind.rsi(up).iloc[-1] == 100
    r = ind.rsi(make_df()["close"])
    assert r.iloc[1:].between(0, 100).all()


def test_atr_positive():
    assert (ind.atr(make_df()).iloc[1:] > 0).all()


# ---- snapshot -----------------------------------------------------------------
def test_snapshot_anonymized_hides_absolute_prices():
    df = make_df()
    s = build_snapshot(df, "BTCUSDT", "1h", funding_rate=0.0001, anonymize=True)
    text = json.dumps(s.features)
    assert "BTCUSDT" not in text and "last_price" not in text
    assert s.features["recent_candles_ohlc_rebased"][-1][3] == 100.0
    assert "higher_tf" in s.features
    assert s.features["funding_rate_pct"] == 0.01


def test_snapshot_position_pnl():
    df = make_df()
    price = df["close"].iloc[-1]
    pos = PositionInfo(side="SHORT", qty=1, entry_price=price * 1.02, bars_held=3)
    s = build_snapshot(df, "X", "1h", position=pos)
    assert s.features["position"]["pnl_pct"] > 0


# ---- risk -----------------------------------------------------------------------
def long(conf=0.8, sl=1.5, tp=3.0):
    return Decision(action=Action.LONG, confidence=conf, stop_loss_atr=sl, take_profit_atr=tp, reasoning="t")


def test_risk_sizes_by_percent_of_equity():
    rm = RiskManager(RiskConfig(risk_per_trade_pct=1.0, max_leverage=10))
    plan = rm.evaluate(long(), snap(), equity=10_000, open_positions=0)
    assert not isinstance(plan, Rejection)
    assert plan.stop_loss == pytest.approx(97.0) and plan.take_profit == pytest.approx(106.0)
    assert plan.qty * 3.0 == pytest.approx(100.0)  # 1% of 10k lost at SL


def test_risk_caps_leverage():
    rm = RiskManager(RiskConfig(risk_per_trade_pct=5.0, max_leverage=2))
    plan = rm.evaluate(long(sl=0.5, tp=1.0), snap(), equity=1_000, open_positions=0)
    assert plan.qty * 100 == pytest.approx(2_000)
    assert plan.meta["leverage_capped"]


@pytest.mark.parametrize("decision,code", [
    (long(conf=0.3), "low_confidence"),
    (long(sl=None), "sl_tp_missing"),
    (long(sl=10), "sl_out_of_range"),
    (long(sl=2, tp=2), "low_rr"),
    (Decision.hold("x"), "not_entry"),
])
def test_risk_rejections(decision, code):
    res = RiskManager(RiskConfig()).evaluate(decision, snap(), equity=10_000, open_positions=0)
    assert isinstance(res, Rejection) and res.code == code


def test_drawdown_halts_and_daily_limit_blocks():
    rm = RiskManager(RiskConfig(max_drawdown_pct=10, daily_loss_limit_pct=3))
    rm.update_equity(10_000, date(2025, 1, 1))
    rm.update_equity(9_600, date(2025, 1, 1))
    assert rm.evaluate(long(), snap(), 9_600, 0).code == "daily_loss"
    rm.update_equity(9_600, date(2025, 1, 2))   # new day resets the daily limit
    assert not isinstance(rm.evaluate(long(), snap(), 9_600, 0), Rejection)
    rm.update_equity(8_900, date(2025, 1, 2))
    assert rm.halted
    assert rm.evaluate(long(), snap(), 8_900, 0).code == "halted"


# ---- backtest -------------------------------------------------------------------
class AlwaysLong:
    name = "always_long"

    def decide(self, s):
        if s.position:
            return Decision.hold("in position")
        return long()


def test_backtest_runs_and_every_trade_has_sl_tp():
    res = Backtester(AlwaysLong(), RiskConfig(max_drawdown_pct=90)).run(make_df(), "TEST")
    assert res.trades
    for t in res.trades:
        assert t.stop_loss < t.entry_price < t.take_profit
        assert t.exit_reason in {"SL", "TP", "END", "SIGNAL", "HALT"}
    m = res.metrics()
    assert m["trades"] == len(res.trades)
    # a losing SL trade loses roughly the configured 1% of equity (+ fees/slippage)
    sl_trades = [t for t in res.trades if t.exit_reason == "SL"]
    assert sl_trades and all(-1.5 < t.r_multiple < -0.9 for t in sl_trades)


def test_backtest_stops_at_max_drawdown():
    df = make_df(drift=-0.003, seed=1)   # strong downtrend punishes always-long
    res = Backtester(AlwaysLong(), RiskConfig(max_drawdown_pct=5)).run(df, "TEST")
    assert res.halted
    assert res.metrics()["max_drawdown_pct"] < 8


def test_backtest_has_no_lookahead():
    """Decisions at bar i must not change when future bars change."""
    seen = []

    class Recorder:
        name = "rec"

        def decide(self, s):
            seen.append(json.dumps(s.features, sort_keys=True))
            return Decision.hold("x")

    df = make_df(400)
    Backtester(Recorder(), RiskConfig(), warmup=210).run(df, "T")
    first = list(seen)
    seen.clear()
    df2 = df.copy()
    df2.iloc[300:, :] *= 1.5
    Backtester(Recorder(), RiskConfig(), warmup=210).run(df2, "T")
    assert first[: 300 - 210] == seen[: 300 - 210]


def test_rule_engine_backtest_smoke():
    res = Backtester(RuleEngine(), RiskConfig()).run(make_df(2000, seed=3), "TEST")
    assert res.final_equity > 0


# ---- Claude engine (mocked client) ----------------------------------------------
class FakeMessages:
    def __init__(self, decision=None, stop_reason="end_turn", exc=None):
        self.decision, self.stop_reason, self.exc = decision, stop_reason, exc
        self.calls = []

    def parse(self, **kw):
        self.calls.append(kw)
        if self.exc:
            raise self.exc
        return SimpleNamespace(
            parsed_output=self.decision, stop_reason=self.stop_reason, _request_id="req_1",
            usage=SimpleNamespace(input_tokens=100, output_tokens=50, cache_read_input_tokens=0),
        )


def fake_client(messages):
    return SimpleNamespace(messages=messages, beta=SimpleNamespace(messages=messages))


def test_claude_engine_parses_and_caches(tmp_path):
    msgs = FakeMessages(decision=long())
    eng = ClaudeEngine(LLMConfig(cache_dir=str(tmp_path)), client=fake_client(msgs))
    s = build_snapshot(make_df(), "BTCUSDT", "1h")
    assert eng.decide(s).action == Action.LONG
    assert eng.decide(s).action == Action.LONG   # second call served from disk cache
    assert len(msgs.calls) == 1 and eng.cache_hits == 1
    kw = msgs.calls[0]
    assert kw["model"] == "claude-opus-5-5"
    assert kw["fallbacks"] == "default" and kw["betas"] == ["server-side-fallback-2026-07-01"]
    assert kw["output_format"] is Decision
    assert "BTCUSDT" not in kw["messages"][0]["content"]


def test_claude_engine_refusal_and_errors_hold(tmp_path):
    import anthropic

    s = build_snapshot(make_df(), "BTCUSDT", "1h")
    eng = ClaudeEngine(LLMConfig(cache_dir=str(tmp_path / "a")), client=fake_client(FakeMessages(stop_reason="refusal")))
    assert eng.decide(s).action == Action.HOLD
    err = anthropic.APIConnectionError(request=httpx.Request("POST", "https://api.anthropic.com"))
    eng = ClaudeEngine(LLMConfig(cache_dir=str(tmp_path / "b")), client=fake_client(FakeMessages(exc=err)))
    assert eng.decide(s).action == Action.HOLD


def test_claude_engine_call_budget(tmp_path):
    msgs = FakeMessages(decision=long())
    eng = ClaudeEngine(LLMConfig(cache_dir=str(tmp_path)), client=fake_client(msgs), max_calls=1)
    df = make_df()
    eng.decide(build_snapshot(df.iloc[:-1], "X", "1h"))
    d = eng.decide(build_snapshot(df, "X", "1h"))
    assert d.action == Action.HOLD and len(msgs.calls) == 1


def test_decision_schema_accepted_by_sdk():
    from anthropic.lib._parse._transform import transform_schema

    schema = transform_schema(Decision)
    assert set(schema["required"]) >= {"action", "confidence", "reasoning"}


# ---- Binance client (mocked transport) --------------------------------------------
RULES = {"symbol": "BTCUSDT", "filters": [
    {"filterType": "PRICE_FILTER", "tickSize": "0.10"},
    {"filterType": "LOT_SIZE", "stepSize": "0.001", "minQty": "0.001"},
    {"filterType": "MARKET_LOT_SIZE", "stepSize": "0.001", "minQty": "0.001"},
    {"filterType": "MIN_NOTIONAL", "notional": "100"},
]}


def test_symbol_rules_rounding():
    r = SymbolRules(RULES)
    assert str(r.round_qty(0.12345)) == "0.123"
    assert str(r.round_price(65432.17)) == "65432.20"


def test_signed_conditional_order_uses_algo_endpoint():
    captured = {}

    def handler(request: httpx.Request):
        captured["req"] = request
        return httpx.Response(200, json={"algoId": 42})

    cfg = BinanceConfig(env="testnet", api_key="k", api_secret="s")
    ex = BinanceFutures(cfg, http=httpx.Client(base_url=cfg.base_url, transport=httpx.MockTransport(handler)))
    r = SymbolRules(RULES)
    ex.conditional_order("BTCUSDT", "SELL", "STOP_MARKET", r.round_price(60000), r.round_qty(0.5), "sl-x")

    req = captured["req"]
    assert req.method == "POST" and req.url.path == "/fapi/v1/algoOrder"
    assert req.url.host == "demo-fapi.binance.com"
    assert req.headers["X-MBX-APIKEY"] == "k"
    query = urlsplit(str(req.url)).query
    body, sig = query.rsplit("&signature=", 1)
    assert sig == hmac.new(b"s", body.encode(), hashlib.sha256).hexdigest()
    params = dict(parse_qsl(body))
    assert params["algoType"] == "CONDITIONAL" and params["triggerPrice"] == "60000"
    assert params["reduceOnly"] == "true" and params["quantity"] == "0.5"
    assert "stopPrice" not in params


def test_api_error_raised_with_code():
    def handler(request):
        return httpx.Response(400, json={"code": -4120, "msg": "Order type not supported"})

    cfg = BinanceConfig(api_key="k", api_secret="s")
    ex = BinanceFutures(cfg, http=httpx.Client(base_url=cfg.base_url, transport=httpx.MockTransport(handler)))
    with pytest.raises(BinanceAPIError) as e:
        ex.market_order("BTCUSDT", "BUY", SymbolRules(RULES).round_qty(0.01))
    assert e.value.code == -4120
