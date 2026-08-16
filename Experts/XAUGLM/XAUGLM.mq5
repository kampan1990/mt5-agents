//+------------------------------------------------------------------+
//| XAUGLM.mq5                                                        |
//| XAUGLM — GLM(Zhipu AI)-assisted XAUUSD EA, main program           |
//| Version: 1.0.0                                                    |
//| Created: 2026-08-16                                               |
//|                                                                    |
//| IMPORTANT: this EA NEVER calls the GLM API directly. It only reads|
//| signal.json / heartbeat.json / kill_switch.flag written by the    |
//| external Python bridge into the MT5 Common\Files\XAUGLM\ folder.  |
//| The EA — specifically RiskManager.mqh's EvaluateGate() — is       |
//| always the final decision-maker before any order is sent.         |
//+------------------------------------------------------------------+
#property copyright "XAUGLM"
#property version   "1.00"
#property strict

#include "Utils.mqh"
#include "Logger.mqh"
#include "SignalReader.mqh"
#include "RiskManager.mqh"
#include "Strategy.mqh"

//+------------------------------------------------------------------+
//| Inputs — values below are the user-approved defaults. Do not     |
//| change without explicit re-approval (this trades a live account).|
//+------------------------------------------------------------------+

// --- Signal / GLM ---
input string InpSignalFilePath          = "XAUGLM\\signal.json";     // Signal file (relative to Common\Files)
input string InpHeartbeatFilePath       = "XAUGLM\\heartbeat.json";  // Heartbeat file (relative to Common\Files)
input string InpKillSwitchFilePath      = "XAUGLM\\kill_switch.flag";// Kill-switch flag file (relative to Common\Files)
input int    InpSignalTimeoutSeconds    = 60;    // Max signal.json age before treated as stale
input int    InpHeartbeatTimeoutSeconds = 120;   // Max heartbeat.json age before bridge considered dead
input double InpMinConfidenceThreshold  = 65.0;  // Minimum GLM confidence (%) required to act, ">=" accepted
input bool   InpAllowSignalReversal     = false; // If false, never auto-close+reverse an open position
input int    InpPollIntervalSeconds     = 5;     // OnTimer poll interval

// --- Mode ---
input ENUM_TRADING_MODE InpTradingMode  = DEMO_PAPER; // MUST stay DEMO_PAPER on first deploy
input double InpMinLotOverride          = 0.01;        // Forced lot size when InpTradingMode==LIVE_MIN_LOT

// --- Risk ---
input double InpRiskPercentPerTrade     = 0.3;   // % of balance risked per trade
input double InpMaxDrawdownPercent      = 5.0;   // Equity peak-to-current drawdown that trips the kill-switch
input double InpDailyLossLimitPercent   = 3.0;   // % balance loss per server day that blocks new entries
input int    InpMaxOpenTrades           = 1;     // Max concurrent EA-owned open positions
input int    InpMaxConsecutiveLosses    = 3;     // Max consecutive losing trades before blocking new entries
input int    InpATR_Period              = 14;    // ATR period used for SL/TP sizing and trend filter
input double InpSL_ATR_Multiplier       = 1.5;   // Default SL = ATR * this (used when GLM omits it)
input double InpTP_ATR_Multiplier       = 3.0;   // Default TP = ATR * this (used when GLM omits it)
input double InpSL_ATR_MultiplierMin    = 1.0;   // Clamp floor for GLM-supplied SL multiplier
input double InpSL_ATR_MultiplierMax    = 3.0;   // Clamp ceiling for GLM-supplied SL multiplier
input double InpTP_ATR_MultiplierMin    = 1.5;   // Clamp floor for GLM-supplied TP multiplier
input double InpTP_ATR_MultiplierMax    = 5.0;   // Clamp ceiling for GLM-supplied TP multiplier

// --- Filters ---
input string InpTradingSessionStart     = "08:00"; // Server-time session start (HH:MM)
input string InpTradingSessionEnd       = "20:00"; // Server-time session end (HH:MM)
input double InpMaxSpreadPoints         = 350;     // Max acceptable spread, in points (not pips)
input bool   InpEnableNewsFilter        = true;    // Enable native MQL5 Calendar high-impact news filter
input int    InpNewsBufferMinutes       = 30;      // +/- minutes around a high-impact event to block entries

// --- Safety ---
input bool   InpEmergencyStop           = false;   // Manual kill-all-new-orders override — checked FIRST always
input int    InpMagicNumber             = 990120;  // EA magic number
// REVIEW ADD (mt5-reviewer, critical fix): explicit, logged, operator-only reset path for the
// persisted drawdown kill-switch (see RiskManager::ManualResetDrawdownKillSwitch). Default MUST
// stay false. Set true + reload the EA once to reset a tripped kill-switch, then set back to
// false — leaving it true will re-trigger the reset (harmlessly, but noisily) on every OnInit.
input bool   InpConfirmResetDrawdownKillSwitch = false; // Set true ONLY to manually clear a tripped drawdown kill-switch, then set back to false

// --- Logging ---
input ENUM_LOG_LEVEL InpLogLevel        = LOG_INFO;                    // Minimum log level printed/written
input string          InpLogFilePath    = "XAUGLM\\logs\\trade_log.csv"; // CSV trade/audit log (relative to Common\Files)

//+------------------------------------------------------------------+
//| Light, signal-independent trailing-stop tuning (OnTick only).    |
//| Named constants per project code-quality rule — no bare magic    |
//| numbers. Not part of the GLM contract; purely local risk mgmt.   |
//+------------------------------------------------------------------+
#define XAUGLM_TRAIL_TRIGGER_ATR_MULT   1.0   // Start trailing once profit >= 1x ATR
#define XAUGLM_TRAIL_DISTANCE_ATR_MULT  1.0   // Keep SL trailing 1x ATR behind current price
#define XAUGLM_ORDER_MAX_RETRIES        3     // Max OrderSend retry attempts on retryable errors
#define XAUGLM_ORDER_RETRY_DELAY_MS     300   // Delay between OrderSend retries

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Logger must come up first so every subsequent validation step is captured.
   if(!Logger::Init(InpLogLevel, InpLogFilePath))
     {
      Print("[XAUGLM][FATAL] Logger failed to initialize — aborting OnInit.");
      return INIT_FAILED;
     }

   Logger::Info("XAUGLM OnInit starting. TradingMode=" + EnumToString(InpTradingMode));

   if(InpTradingMode != DEMO_PAPER)
      Logger::Warn(StringFormat(
         "TradingMode is %s — this EA is configured to trade a LIVE-capable mode. "
         "Confirm this is intentional before leaving the EA unattended.",
         EnumToString(InpTradingMode)));

   // --- Input validation -------------------------------------------------
   bool inputsOk = true;

   if(InpSignalTimeoutSeconds <= 0 || InpHeartbeatTimeoutSeconds <= 0 || InpPollIntervalSeconds <= 0)
     {
      Logger::Error("Invalid inputs: signal/heartbeat timeout and poll interval must be > 0.");
      inputsOk = false;
     }
   if(InpMinConfidenceThreshold < 0.0 || InpMinConfidenceThreshold > 100.0)
     {
      Logger::Error("Invalid inputs: InpMinConfidenceThreshold must be within [0,100].");
      inputsOk = false;
     }
   if(InpATR_Period <= 0)
     {
      Logger::Error("Invalid inputs: InpATR_Period must be > 0.");
      inputsOk = false;
     }
   if(InpSL_ATR_MultiplierMin <= 0.0 || InpSL_ATR_MultiplierMax < InpSL_ATR_MultiplierMin ||
      InpTP_ATR_MultiplierMin <= 0.0 || InpTP_ATR_MultiplierMax < InpTP_ATR_MultiplierMin)
     {
      Logger::Error("Invalid inputs: SL/TP ATR multiplier Min/Max ranges are inconsistent.");
      inputsOk = false;
     }
   if(InpRiskPercentPerTrade <= 0.0 || InpRiskPercentPerTrade > 100.0)
     {
      Logger::Error("Invalid inputs: InpRiskPercentPerTrade must be within (0,100].");
      inputsOk = false;
     }
   if(InpMaxOpenTrades <= 0 || InpMaxConsecutiveLosses <= 0)
     {
      Logger::Error("Invalid inputs: InpMaxOpenTrades and InpMaxConsecutiveLosses must be > 0.");
      inputsOk = false;
     }
   if(InpMaxDrawdownPercent <= 0.0 || InpDailyLossLimitPercent <= 0.0)
     {
      Logger::Error("Invalid inputs: drawdown/daily-loss limits must be > 0.");
      inputsOk = false;
     }
   if(InpMinLotOverride < Utils::GetVolumeMin() || InpMinLotOverride > Utils::GetVolumeMax())
     {
      Logger::Warn(StringFormat(
         "InpMinLotOverride=%.2f is outside broker volume range [%.2f,%.2f] — it will be clamped at use.",
         InpMinLotOverride, Utils::GetVolumeMin(), Utils::GetVolumeMax()));
     }

   if(!inputsOk)
     {
      Logger::Error("XAUGLM OnInit aborted due to invalid inputs.");
      return INIT_PARAMETERS_INCORRECT;
     }

   // --- Symbol tradability check ------------------------------------------
   if(!SymbolSelect(_Symbol, true))
     {
      Logger::Error("Failed to select symbol '" + _Symbol + "' in Market Watch.");
      return INIT_FAILED;
     }
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
      Logger::Warn("Symbol trade mode is currently DISABLED (market likely closed) — EA will wait/poll normally.");

   // --- Strategy indicator handles -----------------------------------------
   if(!Strategy::Init(InpATR_Period))
     {
      Logger::Error("Strategy::Init failed — aborting OnInit.");
      return INIT_FAILED;
     }

   // --- Restore persisted risk state (drawdown kill-switch / peak equity / daily loss) --------
   // REVIEW ADD (mt5-reviewer, critical fix): must run before any EvaluateGate call. Without this,
   // a tripped drawdown kill-switch or a mid-day loss tracker could be silently cleared by any
   // event that restarts the EA/terminal (crash, VPS reboot, MT5 auto-update, recompile) — not
   // just a deliberate operator "manual reset". See RiskManager::LoadPersistentState.
   RiskManager::LoadPersistentState(InpMagicNumber);

   if(InpConfirmResetDrawdownKillSwitch)
     {
      if(RiskManager::IsDrawdownKillSwitchTripped())
        {
         Logger::Error("OnInit: InpConfirmResetDrawdownKillSwitch=true — performing MANUAL drawdown "
                        "kill-switch reset now (operator-confirmed). Set this input back to FALSE "
                        "once confirmed, otherwise it will harmlessly re-fire this reset on every "
                        "future restart.");
         RiskManager::ManualResetDrawdownKillSwitch();
        }
      else
        {
         Logger::Warn("OnInit: InpConfirmResetDrawdownKillSwitch=true but the kill-switch was not "
                       "tripped — no action taken. Please set this input back to FALSE.");
        }
     }

   EventSetTimer(InpPollIntervalSeconds);

   Logger::Info(StringFormat(
      "XAUGLM OnInit complete. symbol=%s magic=%d riskPct=%.2f maxDD=%.2f%% dailyLossLimit=%.2f%%",
      _Symbol, InpMagicNumber, InpRiskPercentPerTrade, InpMaxDrawdownPercent, InpDailyLossLimitPercent));

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Build the RiskManager gate params struct from inputs.            |
//+------------------------------------------------------------------+
void BuildRiskGateParams(SRiskGateParams &p)
  {
   p.emergencyStop         = InpEmergencyStop;
   p.tradingMode            = InpTradingMode;
   p.riskPercentPerTrade    = InpRiskPercentPerTrade;
   p.maxDrawdownPercent     = InpMaxDrawdownPercent;
   p.dailyLossLimitPercent  = InpDailyLossLimitPercent;
   p.maxOpenTrades          = InpMaxOpenTrades;
   p.maxConsecutiveLosses   = InpMaxConsecutiveLosses;
   p.maxSpreadPoints        = InpMaxSpreadPoints;
   p.sessionStartHHMM       = InpTradingSessionStart;
   p.sessionEndHHMM         = InpTradingSessionEnd;
   p.newsFilterEnabled      = InpEnableNewsFilter;
   p.newsBufferMinutes      = InpNewsBufferMinutes;
   p.minLotOverride         = InpMinLotOverride;
   p.magicNumber            = InpMagicNumber;
  }

//+------------------------------------------------------------------+
//| SendOrder — the one and only place that calls OrderSend().       |
//| Re-validates SL/TP and re-runs the RiskManager gate immediately  |
//| before sending, retries on retryable errors, logs GetLastError() |
//| on every failure, and always writes a Logger::Trade audit line.  |
//+------------------------------------------------------------------+
bool SendOrder(const STradeIntent &intent)
  {
   // Mandatory project rule: never send an order without a valid SL/TP.
   if(intent.sl <= 0.0 || intent.tp <= 0.0)
     {
      Logger::Error("SendOrder: refusing to send — invalid SL/TP.", intent.signalId);
      return false;
     }

   // Final gate re-check immediately before OrderSend (state can move between the moment
   // Strategy::Evaluate ran and this exact instant — cheap to re-verify on a live account).
   SRiskGateParams rp;
   BuildRiskGateParams(rp);
   SRiskGateResult finalCheck;
   ENUM_SIGNAL_ACTION action = (intent.orderType == ORDER_TYPE_BUY) ? ACTION_BUY : ACTION_SELL;
   RiskManager::EvaluateGate(rp, action, intent.slDistancePrice, finalCheck);
   if(!finalCheck.allowed)
     {
      Logger::Trade("SendOrder: aborted at final gate re-check: " + finalCheck.reason, intent.signalId);
      return false;
     }

   for(int attempt = 1; attempt <= XAUGLM_ORDER_MAX_RETRIES; attempt++)
     {
      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action       = TRADE_ACTION_DEAL;
      request.symbol        = _Symbol;
      request.volume         = finalCheck.lot; // re-sized at final gate, always freshest
      request.type           = intent.orderType;
      request.price          = (intent.orderType == ORDER_TYPE_BUY)
                                   ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                   : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      request.sl              = intent.sl;
      request.tp              = intent.tp;
      request.magic            = InpMagicNumber;
      request.comment          = "XAUGLM_" + intent.signalId;
      request.type_filling     = Utils::GetSupportedFillingMode();
      request.deviation        = 20; // points — reasonable slippage tolerance for gold

      if(!OrderSend(request, result))
        {
         int err = GetLastError();
         Logger::Error(StringFormat("SendOrder attempt %d/%d: OrderSend() returned false, retcode=%d comment=%s lastError=%d",
                                     attempt, XAUGLM_ORDER_MAX_RETRIES, result.retcode, result.comment, err),
                        intent.signalId);
         ResetLastError();

         bool retryable = (result.retcode == TRADE_RETCODE_REQUOTE ||
                            result.retcode == TRADE_RETCODE_PRICE_CHANGED ||
                            result.retcode == TRADE_RETCODE_TIMEOUT ||
                            result.retcode == TRADE_RETCODE_CONNECTION);
         if(retryable && attempt < XAUGLM_ORDER_MAX_RETRIES)
           {
            Sleep(XAUGLM_ORDER_RETRY_DELAY_MS);
            continue;
           }
         Logger::Trade(StringFormat("Order FAILED: %s vol=%.2f sl=%.5f tp=%.5f retcode=%d",
                                     EnumToString(intent.orderType), finalCheck.lot, intent.sl, intent.tp, result.retcode),
                        intent.signalId);
         return false;
        }

      if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_DONE_PARTIAL)
        {
         int err = GetLastError();
         Logger::Error(StringFormat("SendOrder attempt %d/%d: unexpected retcode=%d comment=%s lastError=%d",
                                     attempt, XAUGLM_ORDER_MAX_RETRIES, result.retcode, result.comment, err),
                        intent.signalId);
         ResetLastError();

         bool retryable = (result.retcode == TRADE_RETCODE_REQUOTE || result.retcode == TRADE_RETCODE_PRICE_CHANGED);
         if(retryable && attempt < XAUGLM_ORDER_MAX_RETRIES)
           {
            Sleep(XAUGLM_ORDER_RETRY_DELAY_MS);
            continue;
           }
         Logger::Trade(StringFormat("Order FAILED: %s vol=%.2f sl=%.5f tp=%.5f retcode=%d",
                                     EnumToString(intent.orderType), finalCheck.lot, intent.sl, intent.tp, result.retcode),
                        intent.signalId);
         return false;
        }

      Logger::Trade(StringFormat("Order OPENED: %s vol=%.2f price=%.5f sl=%.5f tp=%.5f deal=%I64u",
                                  EnumToString(intent.orderType), finalCheck.lot, result.price,
                                  intent.sl, intent.tp, result.deal),
                     intent.signalId);
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| OnTimer — polls the GLM bridge and, if everything checks out,    |
//| sends at most one new order per cycle.                           |
//+------------------------------------------------------------------+
void OnTimer()
  {
   // Rule #1, checked before absolutely anything else, every cycle.
   if(InpEmergencyStop)
     {
      Logger::Warn("InpEmergencyStop is TRUE — skipping this poll cycle entirely.");
      return;
     }

   SSignalReadResult signalResult;
   SignalReader::ReadAll(InpSignalFilePath, InpHeartbeatFilePath, InpKillSwitchFilePath,
                         InpSignalTimeoutSeconds, InpHeartbeatTimeoutSeconds, signalResult);

   if(signalResult.killSwitchActive)
      return; // already logged inside SignalReader

   if(!signalResult.tradingAllowed)
     {
      Logger::Debug("OnTimer: no actionable signal this cycle (" + signalResult.blockReason + ").");
      return;
     }

   SStrategyParams sp;
   sp.minConfidenceThreshold  = InpMinConfidenceThreshold;
   sp.allowSignalReversal     = InpAllowSignalReversal;
   sp.slAtrMultiplierDefault  = InpSL_ATR_Multiplier;
   sp.tpAtrMultiplierDefault  = InpTP_ATR_Multiplier;
   sp.slAtrMultiplierMin      = InpSL_ATR_MultiplierMin;
   sp.slAtrMultiplierMax      = InpSL_ATR_MultiplierMax;
   sp.tpAtrMultiplierMin      = InpTP_ATR_MultiplierMin;
   sp.tpAtrMultiplierMax      = InpTP_ATR_MultiplierMax;

   SRiskGateParams rp;
   BuildRiskGateParams(rp);

   STradeIntent intent;
   bool tradeReady = Strategy::Evaluate(signalResult, sp, rp, intent);

   if(!tradeReady)
     {
      Logger::Debug("OnTimer: strategy did not produce a trade this cycle: " + intent.reason,
                     signalResult.signal.signalId);
      return;
     }

   SendOrder(intent);
  }

//+------------------------------------------------------------------+
//| Manage a light, ATR-based trailing stop on open EA positions.    |
//| Independent of the GLM signal entirely — runs every tick.        |
//+------------------------------------------------------------------+
void ManageTrailingStops()
  {
   double atr = Strategy::GetCurrentAtr();
   if(atr <= 0.0)
      return; // indicator not ready yet, skip silently (checked again next tick)

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE posType   = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double              openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double              currentSl = PositionGetDouble(POSITION_SL);
      double              currentTp = PositionGetDouble(POSITION_TP);

      double currentPrice = (posType == POSITION_TYPE_BUY)
                                ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double profitDistance = (posType == POSITION_TYPE_BUY)
                                  ? (currentPrice - openPrice)
                                  : (openPrice - currentPrice);

      double triggerDistance = atr * XAUGLM_TRAIL_TRIGGER_ATR_MULT;
      if(profitDistance < triggerDistance)
         continue; // not enough profit cushion yet to start trailing

      double trailDistance = atr * XAUGLM_TRAIL_DISTANCE_ATR_MULT;
      double candidateSl = (posType == POSITION_TYPE_BUY)
                               ? currentPrice - trailDistance
                               : currentPrice + trailDistance;
      candidateSl = Utils::NormalizePrice(candidateSl);

      bool improves = (posType == POSITION_TYPE_BUY) ? (candidateSl > currentSl)
                                                        : (candidateSl < currentSl || currentSl == 0.0);
      // Never move SL past open price into loss beyond the original stop, and never loosen it.
      if(!improves)
         continue;

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action   = TRADE_ACTION_SLTP;
      request.position   = ticket;
      request.symbol      = _Symbol;
      request.sl           = candidateSl;
      request.tp           = currentTp; // TP untouched — trailing only manages SL

      if(!OrderSend(request, result) || result.retcode != TRADE_RETCODE_DONE)
        {
         int err = GetLastError();
         Logger::Error(StringFormat("ManageTrailingStops: PositionModify failed ticket=%I64u retcode=%d lastError=%d",
                                     ticket, result.retcode, err));
         ResetLastError();
         continue;
        }

      Logger::Trade(StringFormat("Trailing SL updated: ticket=%I64u newSL=%.5f", ticket, candidateSl));
     }
  }

//+------------------------------------------------------------------+
//| OnTick — trailing stop management only. All GLM-signal-driven    |
//| decisions happen exclusively in OnTimer.                         |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(InpEmergencyStop)
      return;
   ManageTrailingStops();
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   Strategy::Deinit();
   Logger::Info(StringFormat("XAUGLM OnDeinit, reason=%d", reason));
   Logger::Close();
  }
//+------------------------------------------------------------------+
