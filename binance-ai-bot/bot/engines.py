"""Decision engines: Claude (LLM) and a rule-based baseline.

Every engine implements ``decide(snapshot) -> Decision``. Engines never raise:
any failure becomes HOLD so the bot fails safe.
"""
from __future__ import annotations

import hashlib
import json
import logging
from pathlib import Path
from typing import Optional, Protocol

from .config import LLMConfig
from .models import Action, Decision, MarketSnapshot

log = logging.getLogger(__name__)


class DecisionEngine(Protocol):
    name: str

    def decide(self, snap: MarketSnapshot) -> Decision: ...


# --------------------------------------------------------------------------
# Rule-based baseline (free to backtest - use it to sanity-check the pipeline
# and as a benchmark Claude has to beat)
# --------------------------------------------------------------------------
class RuleEngine:
    """Trend + pullback: trade in the direction of EMA50 vs EMA200 when RSI pulls back."""

    name = "rules"

    def __init__(self, sl_atr: float = 1.5, tp_atr: float = 3.0):
        self.sl_atr, self.tp_atr = sl_atr, tp_atr

    def decide(self, snap: MarketSnapshot) -> Decision:
        p = snap.features["primary"]
        d = p["dist_from_ema_pct"]
        rsi = p["rsi14"]
        if d["ema50"] is None or d["ema200"] is None or rsi is None:
            return Decision.hold("not enough data")
        # price above both EMAs and EMA50 above EMA200 <=> d200 > d50 > 0
        uptrend = d["ema200"] > d["ema50"] > 0
        downtrend = d["ema200"] < d["ema50"] < 0
        pos = snap.features.get("position")

        if pos:
            if pos["side"] == "LONG" and (downtrend or rsi > 75):
                return Decision(action=Action.CLOSE, confidence=0.7, reasoning="trend flip / overbought")
            if pos["side"] == "SHORT" and (uptrend or rsi < 25):
                return Decision(action=Action.CLOSE, confidence=0.7, reasoning="trend flip / oversold")
            return Decision.hold("manage open position")

        if uptrend and 35 <= rsi <= 50:
            return Decision(action=Action.LONG, confidence=0.7, stop_loss_atr=self.sl_atr,
                            take_profit_atr=self.tp_atr, reasoning="uptrend pullback")
        if downtrend and 50 <= rsi <= 65:
            return Decision(action=Action.SHORT, confidence=0.7, stop_loss_atr=self.sl_atr,
                            take_profit_atr=self.tp_atr, reasoning="downtrend pullback")
        return Decision.hold("no setup")


# --------------------------------------------------------------------------
# Claude engine
# --------------------------------------------------------------------------
SYSTEM_PROMPT = """You are the decision module of an automated crypto futures trading system (USDT-margined perpetuals).

Each request gives you a JSON market snapshot for one instrument. Prices are rebased so the last close = 100 and absolute prices, symbol and dates may be hidden on purpose: judge only from the data shown, not from anything you may remember about historical markets.

Snapshot fields:
- primary / higher_tf: indicators on the trading interval and a higher timeframe. return_pct = % change over N bars; dist_from_ema_pct = % distance of price above(+)/below(-) each EMA; rsi14; atr14_pct = ATR as % of price; macd_hist_atr = MACD histogram in ATR units; bollinger_pos (0 = lower band, 1 = upper band); volume_vs_20avg.
- recent_candles_ohlc_rebased: last candles, oldest first, as [open, high, low, close].
- funding_rate_pct: current perpetual funding rate (positive = longs pay shorts).
- position: the open position on this instrument (side, pnl_pct, pnl_atr, bars_held) or null.

Choose one action:
- LONG or SHORT: open a new position (only when position is null). You must give stop_loss_atr and take_profit_atr as distances from entry in ATR multiples. Allowed stop range is 0.5-4.0 ATR and take_profit_atr / stop_loss_atr must be at least 1.5.
- CLOSE: exit the open position now (only when a position exists).
- HOLD: do nothing. This is the right answer most of the time.

How to decide:
- Only trade clear, asymmetric setups where trend, momentum and structure agree across timeframes. Preserve capital first; missing a trade costs nothing.
- Avoid entries into extended moves (e.g. RSI extremes, price far from EMA20 relative to ATR) and choppy, directionless conditions.
- Place the stop beyond the level that would invalidate the idea, not at an arbitrary distance.
- For an open position, CLOSE only if the original thesis is clearly invalidated; the exchange already holds the stop-loss and take-profit.
- confidence is your honest probability-like estimate (0.0-1.0) that the action is correct. Trades below 0.6 are ignored by the system.

Position size, leverage and risk limits are enforced by the system - do not reason about them. Keep reasoning to 1-3 sentences."""


class ClaudeEngine:
    name = "claude"

    def __init__(self, cfg: LLMConfig, client=None, max_calls: Optional[int] = None):
        import anthropic

        self.cfg = cfg
        self.client = client or anthropic.Anthropic()
        self.max_calls = max_calls          # budget for API calls (cache hits are free)
        self.calls = 0
        self.cache_hits = 0
        self.cache_dir = Path(cfg.cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.usage = {"input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0}

    def _cache_key(self, payload: str) -> str:
        h = hashlib.sha256()
        for part in (self.cfg.model, self.cfg.effort, SYSTEM_PROMPT, payload):
            h.update(part.encode())
            h.update(b"\0")
        return h.hexdigest()

    def decide(self, snap: MarketSnapshot) -> Decision:
        payload = json.dumps(snap.features, sort_keys=True, separators=(",", ":"))
        key = self._cache_key(payload)
        cache_file = self.cache_dir / f"{key}.json"
        if cache_file.exists():
            self.cache_hits += 1
            return Decision.model_validate_json(cache_file.read_text())

        if self.max_calls is not None and self.calls >= self.max_calls:
            return Decision.hold("LLM call budget exhausted")
        self.calls += 1

        decision = self._call(payload)
        if decision is not None:
            cache_file.write_text(decision.model_dump_json())
            return decision
        return Decision.hold("LLM unavailable - fail safe")

    def _call(self, payload: str) -> Optional[Decision]:
        import anthropic

        kwargs = dict(
            model=self.cfg.model,
            max_tokens=16000,
            system=[{"type": "text", "text": SYSTEM_PROMPT, "cache_control": {"type": "ephemeral"}}],
            output_config={"effort": self.cfg.effort},
            messages=[{"role": "user", "content": f"Market snapshot:\n{payload}"}],
            output_format=Decision,
        )
        try:
            if self.cfg.use_fallbacks:
                # Server-side fallback: if the model declines, the API re-runs the
                # request on Anthropic's recommended fallback model in the same call.
                resp = self.client.beta.messages.parse(
                    betas=["server-side-fallback-2026-07-01"], fallbacks="default", **kwargs
                )
            else:
                resp = self.client.messages.parse(**kwargs)
        except anthropic.RateLimitError as e:
            log.warning("Claude rate limited: %s", e)
            return None
        except anthropic.APIStatusError as e:
            log.error("Claude API error %s: %s", e.status_code, e.message)
            return None
        except anthropic.APIConnectionError as e:
            log.error("Claude connection error: %s", e)
            return None

        usage = resp.usage
        self.usage["input_tokens"] += usage.input_tokens or 0
        self.usage["output_tokens"] += usage.output_tokens or 0
        self.usage["cache_read_input_tokens"] += getattr(usage, "cache_read_input_tokens", 0) or 0

        if resp.stop_reason == "refusal":
            log.warning("Claude refused (request_id=%s)", resp._request_id)
            return Decision.hold("model refused")
        if resp.stop_reason == "max_tokens" or resp.parsed_output is None:
            log.warning("Claude returned no parsable decision (stop_reason=%s)", resp.stop_reason)
            return None
        return Decision.model_validate(resp.parsed_output.model_dump())
