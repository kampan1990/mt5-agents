# GoldBot EA Architecture
## XAUUSD Multi-Strategy Scoring System for MetaTrader 5

**Version:** 1.0  
**Date:** 2026-06-19  
**Symbol:** XAUUSD  
**Timeframes:** M15 (primary signal), H1 (trend filter), H4 (structure)

---

## 1. Overview

GoldBot is a multi-strategy Expert Advisor that aggregates signals from 12 independent strategy
modules. Each strategy evaluates current market conditions and returns a score from 0.0 to 1.0
(representing 0-100%). The ScoreEngine combines all scores into a composite signal. A trade is
opened only when the composite score meets or exceeds a configurable threshold.

### Design Principles

- No trade without SL and TP set simultaneously at order open
- All lot sizes computed from % of balance (supports Cent accounts)
- Each strategy is stateless per tick — it reads indicator buffers and returns a score
- Magic numbers are strategy-specific to allow portfolio tracking per signal
- Emergency stop flag halts all new orders without closing existing positions

---

## 2. File Structure

```
Experts/GoldBot/
├── GoldBot.mq5                  EA entry point, OnInit/OnTick/OnDeinit
├── Strategies/
│   ├── BaseStrategy.mqh         Abstract interface + StrategyScore struct
│   ├── EMAcross.mqh             EMA200 + EMA50 cross + ATR
│   ├── SupplyDemand.mqh         S/D zone detection + RSI + ATR
│   ├── RSIDivergence.mqh        RSI divergence + extreme zones
│   ├── FairValueGap.mqh         FVG identification + gap size + impulse
│   ├── OrderBlock.mqh           ICT order block + ATR + trend
│   ├── LondonBreakout.mqh       Asian range + London open breakout
│   ├── VWAPRejection.mqh        VWAP band + rejection candle + RSI
│   ├── NewsFade.mqh             Spike detection + liquidity return
│   ├── MultiTF.mqh              H1 trend + EMA21 pullback alignment
│   ├── Fibonacci.mqh            Fib 61.8/78.6 + EMA50 filter + swing
│   ├── LiquiditySweep.mqh       Sweep + rejection wick + EMA200
│   └── BosChoch.mqh             BOS/CHoCH structure + consolidation
├── Core/
│   ├── ScoreEngine.mqh          Aggregates 12 strategy scores, bias decision
│   ├── RiskManager.mqh          SL/TP, lot sizing, breakeven, profit lock
│   ├── SessionFilter.mqh        London+NY window, daily profit/loss limits
│   └── Logger.mqh               CSV + Print logging for all trade events
└── Utils/
    └── ATRUtils.mqh             ATR handle management, pip/dollar conversion
```

---

## 3. Input Parameters

All parameters are grouped by module for readability in the MT5 Inputs panel.

### 3.1 General Settings

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| MagicBase | int | 202601 | Base magic number; strategies add their index (0-11) |
| TradeComment | string | "GoldBot" | Order comment prefix |
| EmergencyStop | bool | false | If true, no new orders are opened |
| MaxOpenTrades | int | 3 | Maximum simultaneous positions |
| AllowLong | bool | true | Permit buy orders |
| AllowShort | bool | true | Permit sell orders |

### 3.2 Score Engine

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| ScoreThreshold | double | 65.0 | Minimum composite score (%) to open trade |
| ThresholdMode | enum | THRESHOLD_65 | Options: 50, 65, 75, 85, 100 |
| MinStrategiesActive | int | 3 | Minimum strategies that must score > 0 |
| WeightEMAcross | double | 1.0 | Weight multiplier for EMA Cross signal |
| WeightSupplyDemand | double | 1.2 | Weight for Supply & Demand |
| WeightRSIDivergence | double | 1.0 | Weight for RSI Divergence |
| WeightFVG | double | 1.0 | Weight for Fair Value Gap |
| WeightOrderBlock | double | 1.2 | Weight for ICT Order Block |
| WeightLondonBreakout | double | 1.1 | Weight for London Breakout |
| WeightVWAPRejection | double | 1.0 | Weight for VWAP Rejection |
| WeightNewsFade | double | 0.8 | Weight for News Fade |
| WeightMultiTF | double | 1.3 | Weight for Multi-TF Alignment |
| WeightFibonacci | double | 1.0 | Weight for Fibonacci |
| WeightLiquiditySweep | double | 1.1 | Weight for Liquidity Sweep |
| WeightBosChoch | double | 1.2 | Weight for BOS/CHoCH |

### 3.3 Risk Manager — SL/TP

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| SLMethod | enum | SL_SWING | Options: SL_SWING, SL_ATR |
| SwingLookback | int | 10 | Bars to look back for swing High/Low |
| ATRMultiplierSL | double | 1.0 | ATR multiplier when SL_ATR mode |
| TPMethod | enum | TP_RR | Options: TP_RR, TP_ATR, TP_FIXED |
| TP1_RR | double | 2.0 | Take Profit 1 R:R ratio |
| TP2_RR | double | 3.5 | Take Profit 2 R:R ratio |
| TP1_VolumePct | double | 60.0 | % of position to close at TP1 |
| ATRPeriod | int | 14 | ATR calculation period |
| ATRTimeframe | ENUM_TIMEFRAMES | PERIOD_M15 | Timeframe for ATR |

### 3.4 Risk Manager — Lot Sizing

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| RiskPercent | double | 1.0 | Risk per trade as % of balance |
| LotMin | double | 0.01 | Minimum lot size |
| LotMax | double | 1.0 | Maximum lot size |
| CentAccount | bool | false | If true, divides symbol point by 100 |

### 3.5 Risk Manager — Breakeven

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| EnableBreakeven | bool | true | Activate breakeven system |
| BreakevenTriggerUSD | double | 50.0 | Move SL to entry+offset when profit >= $50 |
| BreakevenOffsetPts | double | 0.5 | SL offset above/below entry in points |

### 3.6 Risk Manager — Profit Lock (Equity-Based)

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| EnableProfitLock | bool | true | Activate equity-based trailing SL |
| ProfitLockTriggerPct | double | 1.5 | Trigger when equity rises 1.5% above day-start |
| ProfitLockTrailPct | double | 0.5 | SL trails 0.5% below equity peak |

### 3.7 Session Filter

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| EnableSessionFilter | bool | true | Restrict trading to London+NY window |
| SessionStartHour | int | 7 | Session open hour (UTC) |
| SessionEndHour | int | 20 | Session close hour (UTC) |
| DailyProfitTargetPct | double | 3.0 | Stop trading after % daily gain |
| DailyProfitTargetUSD | double | 300.0 | Stop trading after $ daily gain |
| DailyFloatingTargetUSD | double | 200.0 | Stop when total floating profit >= $200 |
| DailyLossLimitPct | double | 2.0 | Stop trading after % daily loss |
| MaxDrawdownPct | double | 20.0 | Emergency stop: close all if drawdown > 20% |

### 3.8 Strategy-Specific Parameters

#### EMA Cross
| Parameter | Default | Description |
|-----------|---------|-------------|
| EMAFast | 50 | Fast EMA period |
| EMASlow | 200 | Slow EMA period |
| EMAProximityATR | 0.5 | Max distance to EMA in ATR units |

#### Supply & Demand
| Parameter | Default | Description |
|-----------|---------|-------------|
| SD_ZoneLookback | 50 | Bars to scan for S/D zones |
| SD_ZoneStrength | 2 | Min candles to confirm zone |
| SD_RSIPeriod | 14 | RSI period for alignment filter |
| SD_RSIOverbought | 70.0 | RSI overbought level |
| SD_RSIOversold | 30.0 | RSI oversold level |

#### RSI Divergence
| Parameter | Default | Description |
|-----------|---------|-------------|
| RSI_Period | 14 | RSI period |
| RSI_Extreme_High | 75.0 | Extreme overbought threshold |
| RSI_Extreme_Low | 25.0 | Extreme oversold threshold |
| RSI_DivLookback | 20 | Bars to scan for divergence |

#### Fair Value Gap
| Parameter | Default | Description |
|-----------|---------|-------------|
| FVG_MinGapATR | 0.5 | Minimum gap size in ATR units |
| FVG_Lookback | 30 | Bars to scan for FVG |

#### Order Block ICT
| Parameter | Default | Description |
|-----------|---------|-------------|
| OB_Lookback | 50 | Bars to scan for OB candle |
| OB_ATRThreshold | 1.0 | ATR threshold for valid OB |

#### London Breakout
| Parameter | Default | Description |
|-----------|---------|-------------|
| LB_AsianEndHour | 7 | End hour of Asian session (UTC) |
| LB_LondonStartHour | 7 | London session open (UTC) |
| LB_RangeATRMin | 0.5 | Min range relative to ATR |

#### VWAP Rejection
| Parameter | Default | Description |
|-----------|---------|-------------|
| VWAP_BandWidth | 1.5 | Band width multiplier |
| VWAP_RSIExtreme | 65.0 | RSI level for extreme filter |

#### News Fade
| Parameter | Default | Description |
|-----------|---------|-------------|
| NF_SpikeATR | 1.5 | Spike size threshold in ATR |
| NF_FadeWindow | 3 | Bars after spike to look for fade |

#### Multi-TF Alignment
| Parameter | Default | Description |
|-----------|---------|-------------|
| MTF_TrendTF | PERIOD_H1 | Trend timeframe |
| MTF_EMA21Period | 21 | EMA period for pullback zone |
| MTF_PullbackATR | 0.3 | Max distance from EMA21 in ATR |

#### Fibonacci
| Parameter | Default | Description |
|-----------|---------|-------------|
| FIB_SwingLookback | 100 | Bars to detect swing for fib levels |
| FIB_EMA50Period | 50 | EMA50 for trend filter |

#### Liquidity Sweep
| Parameter | Default | Description |
|-----------|---------|-------------|
| LS_WickATR | 1.5 | Min wick size in ATR units |
| LS_Lookback | 30 | Bars to scan for swept highs/lows |

#### BOS/CHoCH
| Parameter | Default | Description |
|-----------|---------|-------------|
| BOS_StructureLookback | 50 | Bars to define structure |
| BOS_ConsolidationBars | 5 | Min bars of pre-break consolidation |

---

## 4. Class Hierarchy and Interfaces

### 4.1 BaseStrategy (Abstract)

```mql5
// File: Strategies/BaseStrategy.mqh

struct StrategyScore {
    string   name;           // Strategy identifier
    double   score;          // 0.0 - 1.0
    int      bias;           // +1 = bullish, -1 = bearish, 0 = neutral
    string   reason;         // Human-readable summary for Logger
};

class CBaseStrategy {
protected:
    string   m_name;
    int      m_magic_offset; // Added to MagicBase (0-11)
    int      m_atr_handle;
    double   m_atr_buffer[];

public:
    virtual void      Init(int atr_period, ENUM_TIMEFRAMES tf) = 0;
    virtual void      Deinit() = 0;
    virtual StrategyScore Evaluate() = 0;  // Called every tick (new bar flag)
    string            GetName()     { return m_name; }
    int               GetOffset()   { return m_magic_offset; }
};
```

### 4.2 Concrete Strategy Classes

Each file in `Strategies/` implements `CBaseStrategy`:

| Class | File | Magic Offset |
|-------|------|-------------|
| CStratEMAcross | EMAcross.mqh | 0 |
| CStratSupplyDemand | SupplyDemand.mqh | 1 |
| CStratRSIDivergence | RSIDivergence.mqh | 2 |
| CStratFVG | FairValueGap.mqh | 3 |
| CStratOrderBlock | OrderBlock.mqh | 4 |
| CStratLondonBreakout | LondonBreakout.mqh | 5 |
| CStratVWAPRejection | VWAPRejection.mqh | 6 |
| CStratNewsFade | NewsFade.mqh | 7 |
| CStratMultiTF | MultiTF.mqh | 8 |
| CStratFibonacci | Fibonacci.mqh | 9 |
| CStratLiquiditySweep | LiquiditySweep.mqh | 10 |
| CStratBosChoch | BosChoch.mqh | 11 |

### 4.3 ScoreEngine

```mql5
// File: Core/ScoreEngine.mqh

struct CompositeResult {
    double   bull_score;     // 0.0 - 100.0 weighted bullish composite
    double   bear_score;     // 0.0 - 100.0 weighted bearish composite
    int      bias;           // +1 / -1 / 0
    int      active_count;   // Strategies with score > 0
    string   top_contributors; // Comma-separated names for logging
};

class CScoreEngine {
private:
    CBaseStrategy*   m_strategies[12];
    double           m_weights[12];
    double           m_threshold;          // From input ScoreThreshold
    int              m_min_active;

public:
    void             Init(CBaseStrategy* strats[], double weights[], 
                          double threshold, int min_active);
    CompositeResult  Calculate();          // Returns aggregated result
    bool             ShouldTrade(CompositeResult &result, int &out_bias);
};
```

**Score Aggregation Formula:**

```
For each strategy i:
    if bias == +1:  bull_sum += score[i] * weight[i], bull_weight_sum += weight[i]
    if bias == -1:  bear_sum += score[i] * weight[i], bear_weight_sum += weight[i]

bull_score = (bull_weight_sum > 0) ? (bull_sum / bull_weight_sum) * 100 : 0
bear_score = (bear_weight_sum > 0) ? (bear_sum / bear_weight_sum) * 100 : 0

bias = (bull_score > bear_score) && (bull_score >= threshold) ? +1
       (bear_score > bull_score) && (bear_score >= threshold) ? -1 : 0

ShouldTrade = (bias != 0) && (active_count >= min_active)
```

### 4.4 RiskManager

```mql5
// File: Core/RiskManager.mqh

struct TradeSetup {
    double   entry_price;
    double   sl_price;
    double   tp1_price;
    double   tp2_price;
    double   lot_size;
    int      magic;
    string   comment;
};

class CRiskManager {
private:
    double   m_risk_pct;
    double   m_lot_min;
    double   m_lot_max;
    bool     m_cent_account;
    // SL params
    int      m_sl_method;        // SL_SWING or SL_ATR
    int      m_swing_lookback;
    double   m_atr_mult_sl;
    // TP params
    double   m_tp1_rr;
    double   m_tp2_rr;
    double   m_tp1_vol_pct;
    // Breakeven
    bool     m_be_enabled;
    double   m_be_trigger_usd;
    double   m_be_offset_pts;
    // Profit lock
    bool     m_pl_enabled;
    double   m_pl_trigger_pct;
    double   m_pl_trail_pct;
    double   m_day_start_equity;
    double   m_equity_peak;

public:
    void     Init(/* all params */);
    void     SetDayStartEquity(double equity);  // Called at day open

    // SL/TP calculation
    bool     BuildTradeSetup(int bias, int magic, string comment,
                              OUT TradeSetup &setup);
    double   CalcSwingSL(int bias);             // Looks back SwingLookback bars
    double   CalcATRSL(int bias, double atr);
    double   CalcLotSize(double sl_distance_points);

    // Position management (called every tick)
    void     ManageBreakeven();    // Iterates open positions by MagicBase
    void     ManageProfitLock();   // Equity-peak trailing
    bool     CheckMaxDrawdown(double current_equity, double peak_equity);
};
```

### 4.5 SessionFilter

```mql5
// File: Core/SessionFilter.mqh

class CSessionFilter {
private:
    int      m_start_hour;         // UTC
    int      m_end_hour;           // UTC
    double   m_daily_profit_pct;
    double   m_daily_profit_usd;
    double   m_daily_float_usd;
    double   m_daily_loss_pct;
    double   m_day_start_balance;
    double   m_day_start_equity;
    bool     m_daily_target_hit;

public:
    void     Init(/* params */);
    void     OnNewDay(double balance, double equity); // Reset daily counters
    bool     IsSessionActive();    // London+NY window check (UTC)
    bool     IsDailyLimitHit(double current_equity, double floating_profit);
    void     ResetDailyFlags();
};
```

### 4.6 Logger

```mql5
// File: Core/Logger.mqh

class CLogger {
private:
    int      m_file_handle;
    string   m_filename;          // "GoldBot_YYYYMMDD.csv"

public:
    void     Init(string ea_name);
    void     Deinit();
    void     LogSignal(datetime time, string strategy_summary,
                       double bull_score, double bear_score, int bias);
    void     LogOrderOpen(ulong ticket, int bias, double lot,
                          double entry, double sl, double tp1, double tp2);
    void     LogOrderClose(ulong ticket, double profit, string reason);
    void     LogBreakeven(ulong ticket, double new_sl);
    void     LogProfitLock(ulong ticket, double new_sl, double equity_peak);
    void     LogDailyLimit(string reason, double value);
    void     LogError(string context, int error_code);
    // Also calls Print() for MT5 Journal
};
```

### 4.7 ATRUtils

```mql5
// File: Utils/ATRUtils.mqh

class CATRUtils {
private:
    int      m_handle;
    double   m_buffer[];
    int      m_period;
    ENUM_TIMEFRAMES m_tf;

public:
    bool     Init(int period, ENUM_TIMEFRAMES tf);
    void     Deinit();
    double   GetATR(int shift = 1);   // shift=1 returns closed bar ATR
    double   ToUSD(double atr_points);  // Converts ATR points to USD for XAUUSD
    double   ToPoints(double usd);
};
```

---

## 5. Strategy Scoring Logic

Each strategy evaluates 3-5 sub-conditions and scores them equally.

### 5.1 EMA Cross (offset 0)

Sub-conditions (25% each):
1. EMA50 above/below EMA200 (trend direction)
2. Price within 0.5x ATR of EMA50 (proximity)
3. ATR > ATR average (ATR active)
4. Recent EMA50/EMA200 crossover within 5 bars

Score = count_true / 4  
Bias: EMA50 > EMA200 → +1 (bull), else -1 (bear)

### 5.2 Supply & Demand (offset 1)

Sub-conditions (20% each):
1. Price near identified S/D zone (within 0.3x ATR)
2. Zone breakout confirmed (close beyond zone)
3. RSI aligned (RSI < 50 at demand, RSI > 50 at supply)
4. ATR momentum (current ATR > 1.2x average ATR)
5. Candle pattern active (engulfing, pin bar at zone)

### 5.3 RSI Divergence (offset 2)

Sub-conditions (25% each):
1. RSI in extreme zone (> RSI_Extreme_High or < RSI_Extreme_Low)
2. Price at multi-bar extreme (highest high / lowest low in lookback)
3. Divergence confirmed (price new extreme but RSI not)
4. ATR momentum

### 5.4 Fair Value Gap (offset 3)

Sub-conditions (25% each):
1. FVG identified (gap between bar[2].high and bar[0].low for bearish, or bar[2].low and bar[0].high for bullish)
2. Gap size >= 0.5x ATR
3. Trend aligned (FVG direction matches EMA200 slope)
4. Strong impulse candle (body > 0.7x total range)

### 5.5 Order Block ICT (offset 4)

Sub-conditions (25% each):
1. OB candle present (last opposing candle before strong move)
2. Price returned to OB zone
3. ATR > threshold (market not dead)
4. S/D trend aligned (OB in direction of higher TF trend)

### 5.6 London Breakout (offset 5)

Sub-conditions (25% each):
1. London session active (07:00-10:00 UTC)
2. Asian range established (clear high/low 02:00-07:00 UTC)
3. Price breaks Asian range by >= 0.5x ATR
4. ATR expanding vs previous session ATR

### 5.7 VWAP Rejection (offset 6)

Sub-conditions (25% each):
1. 1H session active (first hour of London or NY)
2. Price touched VWAP band (upper or lower)
3. Rejection candle at VWAP (long wick opposing direction)
4. RSI at extreme (> VWAP_RSIExtreme for upper, < (100-VWAP_RSIExtreme) for lower)

### 5.8 News Fade (offset 7)

Sub-conditions (33% each):
1. News hour active (first 30 min after high-impact news time — requires manual news times input or fixed schedule)
2. Spike detected (single candle move > NF_SpikeATR)
3. Liquidity return (next 1-3 candles partially retrace spike)

Note: News times must be pre-programmed or user-entered; no live news feed in MQL5.

### 5.9 Multi-TF Alignment (offset 8)

Sub-conditions (33% each):
1. H1 trend bullish (EMA21 > EMA50 on H1, or use H1 candle direction consensus)
2. M15 pullback to H1 EMA21 area (price within 0.3x H1 ATR of H1 EMA21)
3. M15 pullback zone shows reversal candle (engulfing, inside bar break)

### 5.10 Fibonacci (offset 9)

Sub-conditions (33% each):
1. Price at 61.8% or 78.6% retracement of clear swing
2. Above EMA50 for bull (below for bear)
3. Clear swing defined (swing >= 3x ATR in height)

### 5.11 Liquidity Sweep (offset 10)

Sub-conditions (33% each):
1. Liquidity sweep present (price wicked through recent high/low structure)
2. Rejection wick > 1.5x ATR (strong rejection after sweep)
3. Trend aligned with EMA200

### 5.12 BOS/CHoCH (offset 11)

Sub-conditions (20% each):
1. Structure break confirmed (price closed beyond previous swing high/low)
2. CHoCH confirmed (change of character: first opposing structure break)
3. Pre-break consolidation (BOS_ConsolidationBars bars of tight range before break)
4. ATR momentum (expanding ATR at break candle)
5. BOS direction clear (not a choppy whipsaw — structure clear on M15)

---

## 6. Data Flow

```
OnTick()
  │
  ├── [Gate 1] EmergencyStop == true? → return
  │
  ├── [Gate 2] IsNewBar(PERIOD_M15)?
  │     No → go to Position Management section
  │     Yes → continue signal evaluation
  │
  ├── SessionFilter.IsSessionActive()? → false: skip new orders
  │
  ├── SessionFilter.IsDailyLimitHit()? → true: skip new orders
  │
  ├── CountOpenPositions(MagicBase) >= MaxOpenTrades? → skip new orders
  │
  ├── [Score Phase]
  │     for i in 0..11:
  │         scores[i] = m_strategies[i].Evaluate()
  │     result = ScoreEngine.Calculate(scores)
  │     Logger.LogSignal(result)
  │
  ├── [Decision Phase]
  │     ScoreEngine.ShouldTrade(result, bias)?
  │       No → return
  │       Yes →
  │           RiskManager.BuildTradeSetup(bias, magic, comment, setup)
  │           OrderSend(setup)  with GetLastError() check
  │           Logger.LogOrderOpen(...)
  │
  └── [Position Management — every tick]
        RiskManager.ManageBreakeven()
        RiskManager.ManageProfitLock()
        RiskManager.CheckMaxDrawdown()
        SessionFilter.CheckDailyLimits()
```

---

## 7. OnTick() Execution Order (Detailed)

```
1.  Check EmergencyStop flag → hard return
2.  Detect new M15 bar (static datetime comparison)
3.  ATRUtils.GetATR() → refresh ATR value
4.  SessionFilter.OnNewDay() if date changed → reset daily counters
5.  [Position management — runs every tick regardless of session]
    5a. RiskManager.ManageBreakeven() — scan positions, move SL if profit >= $50
    5b. RiskManager.ManageProfitLock() — update equity peak, adjust SL if triggered
    5c. RiskManager.CheckMaxDrawdown() — if hit, Logger.LogError + EmergencyStop=true
6.  [New bar only below]
7.  SessionFilter.IsSessionActive() → false: return
8.  SessionFilter.IsDailyLimitHit() → true: return
9.  CountOpenPositions() >= MaxOpenTrades → return
10. Evaluate all 12 strategies → StrategyScore[12]
11. ScoreEngine.Calculate() → CompositeResult
12. Log composite score
13. ScoreEngine.ShouldTrade() → if false: return
14. RiskManager.BuildTradeSetup() → TradeSetup struct
    14a. CalcSwingSL (or CalcATRSL)
    14b. CalcLotSize from RiskPercent
    14c. CalcTP from R:R
    14d. Validate: SL distance > MIN_STOP_LEVEL
15. CTrade.Buy() or CTrade.Sell()
16. Check GetLastError() — retry once on REQUOTE (4006)
17. Logger.LogOrderOpen()
```

---

## 8. Magic Number Scheme

```
MagicBase = 202601  (configurable input)

Position magic = MagicBase + strategy_offset

Example with MagicBase 202601:
  202601 → EMA Cross
  202602 → Supply & Demand
  202603 → RSI Divergence
  202604 → Fair Value Gap
  202605 → Order Block ICT
  202606 → London Breakout
  202607 → VWAP Rejection
  202608 → News Fade
  202609 → Multi-TF Alignment
  202610 → Fibonacci
  202611 → Liquidity Sweep
  202612 → BOS/CHoCH
```

When filtering positions for breakeven/profit-lock, use:
```
(position.Magic() >= MagicBase) && (position.Magic() <= MagicBase + 11)
```

---

## 9. Risk Management Rules

### 9.1 Lot Sizing Formula

```
dollar_risk      = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0)
sl_points        = MathAbs(entry_price - sl_price) / SymbolInfoDouble(_Symbol, SYMBOL_POINT)
tick_value       = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE)
tick_size        = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE)
value_per_point  = tick_value / tick_size
lot_raw          = dollar_risk / (sl_points * value_per_point)
lot_size         = MathMax(LotMin, MathMin(LotMax, NormalizeDouble(lot_raw, 2)))

// Cent account adjustment:
// if CentAccount == true: sl_points treated normally (symbol is already in cent)
```

### 9.2 Breakeven Rule

```
For each open position with magic in [MagicBase, MagicBase+11]:
    profit_usd = PositionGetDouble(POSITION_PROFIT)
    if profit_usd >= BreakevenTriggerUSD:
        if position type == BUY:
            new_sl = entry + BreakevenOffsetPts * point
        else:
            new_sl = entry - BreakevenOffsetPts * point
        if new_sl more favorable than current SL:
            ModifySL(ticket, new_sl)
            Logger.LogBreakeven(ticket, new_sl)
```

### 9.3 Profit Lock Rule

```
// Called every tick
current_equity = AccountInfoDouble(ACCOUNT_EQUITY)
if current_equity > m_equity_peak:
    m_equity_peak = current_equity

rise_pct = (m_equity_peak - m_day_start_equity) / m_day_start_equity * 100

if rise_pct >= ProfitLockTriggerPct:
    lock_level_equity = m_equity_peak * (1 - ProfitLockTrailPct / 100)
    if current_equity < lock_level_equity:
        // Close all positions managed by this EA
        CloseAllPositions("ProfitLock trailing hit")
```

### 9.4 Daily Limits

```
daily_pnl_pct    = (current_balance - day_start_balance) / day_start_balance * 100
daily_pnl_usd    = current_balance - day_start_balance
floating_profit  = sum of all open position profits

stop_new_trades if:
    daily_pnl_pct  >= DailyProfitTargetPct   OR
    daily_pnl_usd  >= DailyProfitTargetUSD   OR
    floating_profit >= DailyFloatingTargetUSD OR
    daily_pnl_pct  <= -DailyLossLimitPct

Max Drawdown check (hard stop, closes all positions):
    drawdown_pct = (peak_equity - current_equity) / peak_equity * 100
    if drawdown_pct >= MaxDrawdownPct:
        CloseAllPositions("MaxDrawdown hit")
        EmergencyStop = true
```

---

## 10. Edge Cases and Constraints

| Scenario | Handling |
|----------|----------|
| SL distance < broker MIN_STOP_LEVEL | Expand SL to meet minimum; recalculate lot |
| Lot size below LotMin after risk calc | Use LotMin; log warning (actual risk > intended) |
| Multiple strategies same direction | Only one trade opened per bar (gate on MaxOpenTrades) |
| Strategy score tie (bull == bear) | No trade opened (bias = 0) |
| ATR handle returns empty buffer | Skip tick evaluation; LogError; retry next tick |
| Order rejected (no margin) | LogError(ERR_NO_MONEY); skip; do not retry infinitely |
| Weekend gap (large price move) | CheckMaxDrawdown fires on first tick Monday |
| Cent account symbol naming | User must set CentAccount=true; lot limits still apply |
| News Fade without live feed | Use hardcoded UTC hours for major gold news (08:30, 14:30 NY time) |
| EmergencyStop set mid-session | All open positions remain; only new orders blocked |

---

## 11. Build Order for mt5-coder

Execute in this sequence to satisfy dependencies:

```
Step 1: Utils/ATRUtils.mqh
        Dependencies: none
        
Step 2: Core/Logger.mqh
        Dependencies: none
        
Step 3: Strategies/BaseStrategy.mqh
        Dependencies: ATRUtils.mqh
        
Step 4: Strategies/EMAcross.mqh through BosChoch.mqh (any order, all independent)
        Dependencies: BaseStrategy.mqh, ATRUtils.mqh
        
Step 5: Core/RiskManager.mqh
        Dependencies: ATRUtils.mqh, Logger.mqh
        
Step 6: Core/SessionFilter.mqh
        Dependencies: Logger.mqh
        
Step 7: Core/ScoreEngine.mqh
        Dependencies: BaseStrategy.mqh, all 12 strategy files
        
Step 8: GoldBot.mq5
        Dependencies: all of the above
```

---

## 12. Dashboard Display Plan

The EA should display an on-chart panel (via `ObjectCreate` + `OBJPROP_TEXT`) showing:

```
+-----------------------------------------+
|  GoldBot  |  XAUUSD  |  M15             |
+-----------------------------------------+
|  Session: ACTIVE (London+NY)            |
|  Score: BULL 72.4%  |  BEAR 18.1%       |
|  Threshold: 65%     |  Bias: LONG       |
|  Open Positions: 2 / 3                  |
|  Today P/L: +$142.50 / +1.43%          |
|  Drawdown: 3.2%                         |
+-----------------------------------------+
|  EMA Cross         [===========] 85%    |
|  Supply & Demand   [=======    ] 60%    |
|  RSI Divergence    [           ] 0%     |
|  Fair Value Gap    [========   ] 75%    |
|  Order Block ICT   [=======    ] 60%    |
|  London Breakout   [==========] 80%    |
|  VWAP Rejection    [           ] 0%     |
|  News Fade         [====       ] 33%    |
|  Multi-TF Align    [=========  ] 90%    |
|  Fibonacci         [           ] 0%     |
|  Liquidity Sweep   [=======    ] 67%    |
|  BOS/CHoCH         [======     ] 60%    |
+-----------------------------------------+
|  [EMERGENCY STOP]                       |
+-----------------------------------------+
```

Panel uses `OBJPROP_CORNER` = CORNER_LEFT_UPPER. Emergency Stop button calls
`GlobalVariableSet("GoldBot_EmergencyStop", 1)` which the EA reads each tick.

---

## 13. Handoff Notes to mt5-coder

### Critical Implementation Points

1. **New Bar Detection** — Use static `datetime last_bar_time` compared against
   `iTime(_Symbol, PERIOD_M15, 0)`. Do NOT use `OnCalculate` pattern.

2. **CTrade class** — Use `#include <Trade\Trade.mqh>` for order management.
   Set `m_trade.SetExpertMagicNumber(magic)` per order, not globally.

3. **Multi-timeframe data** — Use `CopyRates()` with explicit symbol and
   timeframe. Cache results in static arrays per strategy. Do not call
   `CopyRates` more than once per tick per timeframe.

4. **VWAP calculation** — MT5 has no built-in VWAP. Compute as:
   `VWAP = SUM(typical_price * volume) / SUM(volume)` from session open bar.
   Reset at SessionStartHour.

5. **Supply & Demand zones** — Store zone as price range struct `{double high, low, int strength, bool broken}`.
   Zones invalidated when price closes beyond them.

6. **Fibonacci levels** — Detect swing using ZigZag-style logic (fractal highs/lows).
   Compute 61.8% = swing_high - (swing_high - swing_low) * 0.618 for bearish,
   reverse for bullish.

7. **TP partial close at TP1** — Open TWO separate positions with TP1_VolumePct
   lot split, or use a single position and close partial with
   `m_trade.PositionClosePartial(ticket, lot_to_close)`.

8. **Thread safety** — MQL5 OnTick is single-threaded; no mutex needed.
   However, ensure `PositionSelect()` is called before any `PositionGet*` call.

9. **Error handling** — After every `m_trade.Buy()` or `m_trade.Sell()`,
   check `m_trade.ResultRetcode()`. Log on any non-TRADE_RETCODE_DONE result.

10. **Chart panel** — Build in a separate `DrawPanel()` function called at end
    of OnTick. Guard with a 1-second throttle to avoid flicker.
