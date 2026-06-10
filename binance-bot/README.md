# Binance Futures Grid Bot

Python port of the MQL5 HybridPro grid/directional EA, targeting Binance USDT-margined perpetual futures.

---

## Architecture Overview

```
binance-bot/
├── main.py                    Entry point — async event loop, task wiring
├── config.py                  All parameters as dataclasses + env-var loading
├── requirements.txt
│
├── core/
│   ├── exchange.py            ccxt.pro wrapper — orders, balance, WebSocket
│   ├── risk_manager.py        Pre-order guards + lot-size calculation
│   └── state_manager.py       SQLite persistence (positions, magic states, PNL)
│
├── strategies/
│   ├── grid_m1.py             M1: BUY grid (opens longs on price descent)
│   ├── grid_m3.py             M3: SELL grid (opens shorts on price ascent)
│   ├── m2_directional.py      M2: ADX + EMA directional / assist trades
│   ├── tp_chain.py            SepTP / PairTP / TotTP priority chain
│   ├── best_side_pool.py      Best N BUY + Best N SELL pool with separate TP
│   ├── recovery.py            Smart Recovery Engine (win-funded loss recovery)
│   └── trigger_system.py      Loss Trigger — locks magic, enables M2 assist
│
├── utils/
│   ├── indicators.py          pandas-ta wrappers (ADX, EMA)
│   ├── logger.py              Loguru sink setup
│   ├── pnl_tracker.py         Unrealised/realised PNL helpers
│   └── time_utils.py          UTC timestamp helpers
│
├── tests/
│   ├── test_pnl_tracker.py
│   ├── test_risk_manager.py
│   └── test_recovery.py
│
└── data/                      Runtime data directory
    ├── bot_state.db           SQLite database (auto-created)
    └── logs/                  Rotating log files (auto-created)
```

---

## System Flow

```
WebSocket (mark price)
        |
        v
  price_feed_task  ──────────────────────────> tick_queue (asyncio.Queue)
                                                      |
  candle_task                                         v
  (every 1m close) ──> M2Directional.on_candle()  main_loop_task
         |                  |                         |
         | adx_trend        | current_trend     TriggerSystem.evaluate()
         v                  v                         |
                     M1BuyGrid.on_tick()  <───────────+
                     M3SellGrid.on_tick() <───────────+
                     BestSidePool.update()

  tp_check_task  (every 1 second)
        |
        v
  TPChain.check()
    ├── TotTP?  → close all 3 magics → RecoveryEngine.run(win_sum)
    ├── PairTP? → close top 2 magics → RecoveryEngine.run(win_sum)
    └── SepTP?  → close per-magic   → RecoveryEngine.run(win_sum)

  BestSidePool.check_pool_tp()  (inside pool update)
    ├── BestBuyTP?  → close BUY pool  → RecoveryEngine.run(win_sum)
    └── BestSellTP? → close SELL pool → RecoveryEngine.run(win_sum)
```

---

## Strategy Logic

### M1 — BUY Grid
- Opens a BUY market order every `m1_grid_step_pips` as price descends.
- Lot size uses `counter_trend_multiplier` when ADX shows bearish trend
  (buying into weakness), `with_trend_multiplier` when bullish.
- Hard cap: `m1_max_levels` open positions.

### M3 — SELL Grid
- Mirror of M1 for the sell side.
- Opens a SELL market order every `m3_grid_step_pips` as price ascends.

### M2 — ADX Directional
- **Normal mode**: opens a position in the ADX+EMA confirmed trend direction.
- **Assist mode** (activated by TriggerSystem): ignores ADX, opens in the
  direction that offsets the locked magic's losses using `assist_lot_multiplier`.

### TP Priority Chain
Evaluated in priority order (highest first):
1. **TotTP** — combined PNL of M1 + M2 + M3 >= `tot_tp_usdt`
2. **PairTP** — top-2-magic combined PNL >= `pair_tp_usdt`
3. **SepTP** — any single magic PNL >= `sep_tp_usdt`

After any TP fires, `RecoveryEngine.run(win_sum)` is called.

### Best Side Pool
- Maintains the best N BUY positions and best N SELL positions by PNL.
- Pool positions are **immune** from TPChain grid TP checks.
- Each pool has its own TP target (`best_buy_tp_usdt` / `best_sell_tp_usdt`).

### Smart Recovery Engine
- Budget = `win_sum * recovery_ratio` (default 30%).
- Sorts losing positions least-negative first.
- Greedily closes positions where `unrealised_pnl + allocated >= 0`.

### Trigger System
- Monitors M1 and M3 per-magic PNL every tick.
- When PNL <= `loss_trigger_threshold` → lock magic + enable M2 assist.
- Unlocks when PNL recovers to >= `loss_unlock_threshold`.

---

## Quick Start

```bash
# 1. Create virtualenv
python3.11 -m venv .venv
source .venv/bin/activate

# 2. Install dependencies
pip install -r requirements.txt

# 3. Configure credentials
cp .env.example .env
# Edit .env: BINANCE_API_KEY, BINANCE_API_SECRET, BINANCE_TESTNET=true

# 4. Run (testnet by default)
python main.py
```

---

## Configuration

All parameters live in `config.py`. Key settings:

| Section | Parameter | Default | Description |
|---------|-----------|---------|-------------|
| SymbolConfig | symbol | BTC/USDT:USDT | ccxt unified perpetual symbol |
| SymbolConfig | leverage | 10 | Futures leverage |
| GridConfig | m1_grid_step_pips | 50.0 | BUY grid spacing in pips |
| GridConfig | m3_grid_step_pips | 50.0 | SELL grid spacing in pips |
| GridConfig | counter_trend_multiplier | 1.5 | Aggressive sizing against trend |
| GridConfig | with_trend_multiplier | 1.0 | Conservative sizing with trend |
| M2Config | adx_threshold | 25.0 | Min ADX to confirm trend |
| TriggerConfig | loss_trigger_threshold | -50.0 USDT | Per-magic loss to trigger lock |
| TPConfig | sep_tp_usdt | 20.0 | Individual magic TP |
| TPConfig | pair_tp_usdt | 50.0 | Two-magic combined TP |
| TPConfig | tot_tp_usdt | 100.0 | All-magic combined TP |
| BestSidePoolConfig | best_buy_count | 3 | BUY pool size |
| BestSidePoolConfig | best_sell_count | 3 | SELL pool size |
| RecoveryConfig | recovery_ratio | 0.30 | Fraction of win to allocate |
| RiskConfig | max_drawdown_pct | 20.0 | Hard stop drawdown % |
| RiskConfig | max_total_positions | 30 | Max open positions |
| RiskConfig | daily_loss_limit_usdt | -200.0 | Daily loss circuit breaker |

---

## Emergency Stop

Touch the sentinel file to halt all order activity immediately:
```bash
touch /tmp/bot_emergency_stop
```

Remove it to resume:
```bash
rm /tmp/bot_emergency_stop
```

The path is configurable via `RiskConfig.emergency_stop_file`.

---

## Running Tests

```bash
pytest tests/ -v
```

---

## Magic Numbers

| Magic | Module | Side |
|-------|--------|------|
| 1001 | M1BuyGrid | BUY |
| 1002 | M2Directional | BUY or SELL |
| 1003 | M3SellGrid | SELL |
