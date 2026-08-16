# XAUGLM Architecture

GLM (Zhipu AI)-assisted XAUUSD Expert Advisor for MetaTrader 5.

**Status:** implementation complete, pending `mt5-reviewer` review. Default
deploy configuration is `DEMO_PAPER` — do not switch to a live-trading mode
until review + demo validation are complete.

## 1. Core principle: the EA decides, GLM only advises

```
┌─────────────────────┐        writes JSON files         ┌──────────────────────┐
│  Python Bridge       │ ───────────────────────────────► │  MT5 Common\Files\    │
│  (bridge/*.py)        │   (atomic: .tmp -> os.rename)    │  XAUGLM\               │
│                        │                                  │   signal.json          │
│  - fetches market data │                                  │   heartbeat.json       │
│  - calls GLM API       │                                  │   kill_switch.flag     │
│  - validates response  │                                  └──────────┬────────────┘
└───────────┬────────────┘                                             │ FILE_COMMON reads
            │                                                          │ (poll, OnTimer)
            │ calls GLM API only                                       ▼
            ▼                                                ┌──────────────────────┐
    ┌───────────────┐                                        │  XAUGLM.mq5 (EA)      │
    │ Zhipu AI (GLM) │                                        │  - SignalReader.mqh   │
    └───────────────┘                                        │  - RiskManager.mqh    │
                                                               │  - Strategy.mqh       │
                                                               │  - OrderSend()        │
                                                               └──────────────────────┘
```

The EA **never** calls `WebRequest()` to reach GLM directly. Two independent
processes communicate purely through files on disk:

- The **bridge** (Python, runs outside MT5) fetches market data, calls GLM,
  validates the response, and atomically writes `signal.json` /
  `heartbeat.json`.
- The **EA** (MQL5, runs inside MT5's trading thread) only ever *reads* those
  files on a timer, and is the sole caller of `OrderSend()`. Every filter,
  clamp, and kill-switch lives in `RiskManager.mqh`, which is the mandatory
  final gate before any order is sent — GLM's output can steer *what* is
  proposed, never bypass *whether* it's allowed.

This split exists specifically so a slow/unavailable LLM API can never block
or add latency to the MT5 trading thread, and so a bad/compromised LLM
response can never directly cause a trade — it can only ever produce a
proposal that still has to pass every deterministic risk check.

## 2. File contract (Common\Files\XAUGLM\)

| File | Writer | Reader | Purpose |
|---|---|---|---|
| `signal.json` | bridge | EA | Latest GLM trading judgment |
| `heartbeat.json` | bridge | EA | Proof the bridge process is alive, independent of signal generation success |
| `kill_switch.flag` | bridge (escalation) or operator (manual) | EA | Presence-only: blocks all new order entries |
| `logs/trade_log.csv` | EA | operator | Trade + audit log, correlated by `signal_id` |
| `logs/audit.jsonl` | bridge | operator | Every GLM call/response, signal write, circuit-breaker/kill-switch event |

All bridge writes use the atomic write pattern (write to `*.tmp` in the same
directory, `fsync`, then `os.replace()`/rename into place) so the EA can never
observe a half-written file.

### `signal.json` schema (schema_version 1)

```json
{
  "signal_id": "uuid-v4-string",
  "generated_at_utc": "2026-08-16T07:32:10Z",
  "symbol": "XAUUSD",
  "action": "BUY",
  "confidence": 72.5,
  "sl_atr_multiplier": 1.8,
  "tp_atr_multiplier": 3.2,
  "reason": "short summary, <=200 chars",
  "glm_model": "glm-4-plus",
  "schema_version": 1
}
```

Of these fields, **only** `action`, `confidence`, `sl_atr_multiplier`,
`tp_atr_multiplier`, and `reason` originate from the GLM response. The bridge
itself assigns `signal_id`, `generated_at_utc`, `symbol`, `glm_model`, and
`schema_version` — this is a deliberate prompt-injection defense (see §5).

EA-side parsing rules (`SignalReader.mqh`):

- Missing optional field → EA-side default is used, never an error.
- `action` not in `{BUY,SELL,HOLD}` → treated as invalid → folded into HOLD.
- `schema_version` mismatch → WARN logged, folded into HOLD.
- `signal.json` older than `InpSignalTimeoutSeconds` → stale → HOLD.
- File missing / mid-write / unparsable → retried next poll cycle, **never
  crashes the EA**.

### `heartbeat.json` schema (schema_version 1)

```json
{
  "generated_at_utc": "2026-08-16T07:32:10Z",
  "bridge_status": "running",
  "schema_version": 1,
  "last_signal_id": "uuid-v4-string",
  "circuit_breaker_open": false
}
```

Written on its own timer (`HEARTBEAT_INTERVAL_SECONDS`, default 20s),
independent of the signal-generation cycle — a GLM outage must not look
identical to "bridge process is dead" from the EA's point of view.

## 3. EA read order (mandatory, `SignalReader.mqh`)

Every `OnTimer()` poll checks, **in this exact order**, short-circuiting on
the first failure:

1. **`kill_switch.flag` existence.** If present, trading is blocked
   immediately — heartbeat/signal are not even read.
2. **`heartbeat.json` freshness** (`InpHeartbeatTimeoutSeconds`, default
   120s). Stale/missing → blocked.
3. **`signal.json` parse + schema + freshness** (`InpSignalTimeoutSeconds`,
   default 60s). Any failure → blocked (HOLD).

Only if all three pass does `Strategy.mqh` get to evaluate the signal at all.

## 4. Risk management (`RiskManager.mqh`) — the final gate

`RiskManager::EvaluateGate()` is called twice per trade: once inside
`Strategy::Evaluate()` to decide the trade intent, and again immediately
before `OrderSend()` in `XAUGLM.mq5::SendOrder()` as a last-line-of-defense
re-check (state can move between those two moments on a live account). It
checks, in order:

1. `InpEmergencyStop` (checked first, everywhere, always).
2. Drawdown kill-switch (equity peak-to-current, real-time).
3. Daily loss limit (resets at server-time day rollover).
4. Market/symbol tradable in the requested direction (handles weekend/holiday
   closures and broker LONGONLY/SHORTONLY/CLOSEONLY/DISABLED modes).
5. Max open trades (`InpMaxOpenTrades`).
6. Max consecutive losses (`InpMaxConsecutiveLosses`).
7. Spread filter, in **points** (`InpMaxSpreadPoints`) — not pips, since gold's
   point ≠ pip.
8. Trading session window (`InpTradingSessionStart/End`, server time).
9. Native MQL5 economic-calendar news blackout (`InpEnableNewsFilter`,
   `InpNewsBufferMinutes`) — independent, second layer on top of the bridge's
   own `news_filter.py` check.
10. Valid SL distance, then position sizing.

Position sizing formula:

```
Lot = (Balance × RiskPercentPerTrade / 100) / (SL_Distance_Points × TickValuePerPoint)
```

rounded to `SYMBOL_VOLUME_STEP` and clamped to `[SYMBOL_VOLUME_MIN,
SYMBOL_VOLUME_MAX]`, always derived from live `SymbolInfo*` calls — never
hardcoded. In `LIVE_MIN_LOT` trading mode this formula is bypassed entirely
and `InpMinLotOverride` is forced (still normalized/clamped).

### Drawdown kill-switch policy (confirmed)

When drawdown ≥ `InpMaxDrawdownPercent`: **only new order entries are
blocked.** Existing open positions are left alone — their own SL/TP continue
to work normally, they are never force-closed. The trip is logged with full
context (peak/current equity, drawdown %) and **latches** — it does not
auto-reset. Because the trip state is an in-process static, the only way to
clear it is a genuine EA restart (detach/reattach) or an input toggle,
matching the confirmed manual-reset policy. Note this is distinct from
`kill_switch.flag`, which is the *file-based* kill switch the bridge/operator
control — both are checked, and either one alone is sufficient to block new
entries.

## 5. GLM prompt-injection defense (`bridge/glm_client.py`)

- The system prompt explicitly tells GLM that the market/news data in the
  user message is **data, not instructions**, and to ignore any
  instruction-like text found inside it.
- GLM is asked to return only the *judgment* fields (`action`, `confidence`,
  `sl_atr_multiplier`, `tp_atr_multiplier`, `reason`). Every other field in
  the final `signal.json` — including `signal_id` and `schema_version` — is
  assigned by the bridge itself, so a successful injection can at worst
  distort the judgment fields, all of which the EA independently clamps
  (`InpSL_ATR_MultiplierMin/Max`, `InpTP_ATR_MultiplierMin/Max`) and gates
  before anything is ever traded.
- Requests use a 10s timeout, retry with exponential backoff, and a circuit
  breaker: 3 consecutive failures (configurable) opens the circuit for a
  cooldown period, during which GLM is not called at all. If the circuit
  keeps re-opening (`KILL_SWITCH_ON_REPEATED_CB_FAILURES`, default 10), the
  bridge escalates by writing `kill_switch.flag` itself — this is the one
  case where the bridge proactively blocks trading, on the theory that
  persistent GLM failure likely means misconfiguration that needs a human.

## 6. Module dependency order

```
Utils.mqh  (no deps: JSON parser, symbol-info helpers, ISO-8601 parsing)
   │
   ▼
Logger.mqh  (CSV trade/audit log + terminal Print, correlated by signal_id)
   │
   ▼
SignalReader.mqh  (kill-switch -> heartbeat -> signal, in that order)
   │
   ▼
RiskManager.mqh  (sizing, kill-switches, all filters — the final gate)
   │
   ▼
Strategy.mqh  (signal + light EMA trend confirmation -> RiskManager -> trade intent)
   │
   ▼
XAUGLM.mq5  (OnInit / OnTimer / OnTick / OnDeinit, the only OrderSend() caller)
```

Bridge module call order per poll cycle (`main.py`):

```
config.py → market_data.py → news_filter.py → glm_client.py → signal_writer.py → audit_logger.py
                                                                     ▲
heartbeat.py runs on its own thread/timer, independent of the above ┘
```

## 7. Known integration TODOs (by design, not oversights)

- `bridge/market_data.py`: uses the official `MetaTrader5` Python package
  (Windows + local terminal only). Swap in a different data source per the
  TODO in that file if the bridge runs elsewhere.
- `bridge/news_filter.py`: no economic-calendar data source is wired up yet
  (stub always returns "no blackout"). The EA's own native MQL5
  `CalendarValueHistory`-based filter in `RiskManager.mqh` is a fully
  functional, independent second layer regardless of this stub's state.

## 8. Handoff to mt5-reviewer

Please focus review on:

- Risk-management logic in `RiskManager.mqh`, especially the drawdown
  kill-switch latch/reset semantics and the lot-sizing formula's handling of
  broker tick-value edge cases.
- Edge cases: weekend gap, spread spike, terminal restart with a stale
  `signal.json` still on disk, GLM response that omits optional fields,
  `OrderSend` requote/timeout retry behavior.
- Indicator handle lifecycle (`Strategy::Init`/`Deinit`) for leaks.
- The hand-rolled JSON parser in `Utils.mqh` — it is intentionally minimal
  (flat objects only, basic escape handling) per the fixed schema above; flag
  anything in `signal.json`/`heartbeat.json` handling that could break on a
  legitimately-shaped but unusual GLM response.
