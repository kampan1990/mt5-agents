//+------------------------------------------------------------------+
//| RiskManager.mqh                                                  |
//| XAUGLM EA — sizing, kill-switches, all trading filters.          |
//| depends on: Utils.mqh, Logger.mqh                                |
//| This module is the FINAL GATE before any OrderSend call.         |
//| Version: 1.0.0                                                   |
//| Created: 2026-08-16                                              |
//+------------------------------------------------------------------+
#pragma once
#include "Utils.mqh"
#include "Logger.mqh"

//--- All the tunables a single gate evaluation needs, bundled so call sites don't have to
//--- pass a dozen loose parameters (and so it's obvious at a glance what the gate checks).
struct SRiskGateParams
  {
   bool              emergencyStop;
   ENUM_TRADING_MODE tradingMode;
   double            riskPercentPerTrade;
   double            maxDrawdownPercent;
   double            dailyLossLimitPercent;
   int               maxOpenTrades;
   int               maxConsecutiveLosses;
   double            maxSpreadPoints;
   string            sessionStartHHMM;
   string            sessionEndHHMM;
   bool              newsFilterEnabled;
   int               newsBufferMinutes;
   double            minLotOverride;
   int               magicNumber;
  };

//--- Outcome of one gate evaluation. `reason` is always populated (even on success, "ok")
//--- so every call site has something concrete to log.
struct SRiskGateResult
  {
   bool   allowed;
   double lot;
   string reason;
  };

namespace RiskManager
  {
   //--- In-process mirrors of the persisted state below. Kept as plain statics purely as a
   //--- fast-path cache; the terminal-level Global Variables (see PersistKey()/LoadPersistentState()
   //--- below) are the actual source of truth and are what makes the manual-reset policy hold.
   //---
   //--- REVIEW FIX (mt5-reviewer, critical): the original implementation relied on these statics
   //--- ALONE surviving only via "EA restart clears them = manual reset". That is not a safe
   //--- equivalence — a terminal crash, VPS reboot, Windows update, MT5 auto-update, or power loss
   //--- also clears in-process statics, none of which is a deliberate operator decision. On a live
   //--- account that means an unrelated infrastructure restart could SILENTLY un-trip a drawdown
   //--- kill-switch that fired during a real adverse event, and trading would resume with nobody
   //--- having decided that was safe. Fixed by persisting tripped/peak state to the terminal's
   //--- Global Variables store (GlobalVariableSet/Get), which survives process/terminal restarts
   //--- and is only cleared by ManualResetDrawdownKillSwitch() (explicit operator action via
   //--- InpConfirmResetDrawdownKillSwitch) or by the operator deleting the Global Variable by hand.
   double g_peakEquity           = 0.0;
   bool   g_ddKillSwitchTripped  = false;

   //--- Daily loss tracking, reset automatically at server-time day rollover (this one DOES
   //--- reset on its own by design — see architecture spec — unlike the drawdown kill-switch).
   //--- REVIEW FIX: also now persisted (see below) — without persistence, a mid-day EA/terminal
   //--- restart re-seeded g_dayStartBalance from the CURRENT (already-reduced) balance, silently
   //--- granting a fresh daily-loss allowance after any restart instead of only at day rollover.
   int    g_dailyTrackedDay      = -1; // day-of-year marker; -1 = not initialized yet
   double g_dayStartBalance      = 0.0;

   //--- Scope tag for the Global Variable keys below, set once by LoadPersistentState() (called
   //--- from OnInit). Binds persisted state to this account+symbol+magic so it can never collide
   //--- with another EA/account sharing the same terminal installation.
   string g_persistSymbol = "";
   int    g_persistMagic  = 0;
   bool   g_persistReady  = false;

   //=================================================================
   // Persistent state (terminal Global Variables) — survives terminal/EA restarts.
   //=================================================================

   //--- Build one persisted-state key, namespaced by account login + symbol + magic number.
   string PersistKey(const string suffix)
     {
      return StringFormat("XAUGLM_%I64d_%s_%d_%s",
                           AccountInfoInteger(ACCOUNT_LOGIN), g_persistSymbol, g_persistMagic, suffix);
     }

   //--- Must be called once from OnInit (before any EvaluateGate/CheckDrawdownKillSwitch call).
   //--- Restores drawdown kill-switch / peak-equity / daily-loss state from the terminal's Global
   //--- Variables store so a restart of any kind cannot silently clear a tripped kill-switch or a
   //--- mid-day loss allowance.
   void LoadPersistentState(const int magicNumber, const string symbol = NULL)
     {
      g_persistSymbol = Utils::ResolveSymbol(symbol);
      g_persistMagic  = magicNumber;
      g_persistReady  = true;

      if(GlobalVariableCheck(PersistKey("DDTRIP")))
        {
         g_ddKillSwitchTripped = (GlobalVariableGet(PersistKey("DDTRIP")) != 0.0);
         if(g_ddKillSwitchTripped)
            Logger::Error("RiskManager: drawdown kill-switch restored TRIPPED from persisted terminal "
                           "state (this survives EA/terminal restarts by design). New order entries "
                           "remain BLOCKED. Manual reset required: InpConfirmResetDrawdownKillSwitch=true.");
        }
      if(GlobalVariableCheck(PersistKey("DDPEAK")))
         g_peakEquity = GlobalVariableGet(PersistKey("DDPEAK"));
      if(GlobalVariableCheck(PersistKey("DAY")))
         g_dailyTrackedDay = (int)GlobalVariableGet(PersistKey("DAY"));
      if(GlobalVariableCheck(PersistKey("DAYBAL")))
         g_dayStartBalance = GlobalVariableGet(PersistKey("DAYBAL"));
     }

   //--- Explicit, operator-driven reset of the drawdown kill-switch. Only ever called from
   //--- XAUGLM.mq5::OnInit() when InpConfirmResetDrawdownKillSwitch is deliberately set true —
   //--- never called automatically. Clears both the in-memory flag and the persisted Global
   //--- Variables so the reset actually sticks across the next restart too.
   bool ManualResetDrawdownKillSwitch()
     {
      if(!g_ddKillSwitchTripped)
        {
         Logger::Info("RiskManager: manual kill-switch reset requested but it was not tripped — no-op.");
         return false;
        }
      g_ddKillSwitchTripped = false;
      g_peakEquity          = 0.0; // reseed from current equity on next CheckDrawdownKillSwitch call
      GlobalVariableDel(PersistKey("DDTRIP"));
      GlobalVariableDel(PersistKey("DDPEAK"));
      GlobalVariableFlush();
      Logger::Error("RiskManager: DRAWDOWN KILL-SWITCH MANUALLY RESET by operator "
                     "(InpConfirmResetDrawdownKillSwitch=true). New order entries are allowed again "
                     "as of now. Remember to set the input back to FALSE.");
      return true;
     }

   //=================================================================
   // Position sizing
   //=================================================================

   //--- Compute lot size from risk %, per: Lot = (Balance * Risk% / 100) / (SL_Points * TickValuePerPoint)
   //--- Result is always rounded to SYMBOL_VOLUME_STEP and clamped to [SYMBOL_VOLUME_MIN, MAX].
   //--- In LIVE_MIN_LOT mode the risk formula is bypassed entirely and minLotOverride is used
   //--- (still passed through normalization/clamping for safety).
   double CalculateLotSize(const double slDistancePrice, const double riskPercentPerTrade,
                            const ENUM_TRADING_MODE tradingMode, const double minLotOverride,
                            const string symbol = NULL)
     {
      if(tradingMode == LIVE_MIN_LOT)
        {
         double forced = Utils::NormalizeVolume(minLotOverride, symbol);
         Logger::Debug(StringFormat("RiskManager: LIVE_MIN_LOT mode — forcing lot=%.2f", forced));
         return forced;
        }

      if(slDistancePrice <= 0.0)
        {
         Logger::Error("RiskManager::CalculateLotSize: slDistancePrice <= 0, cannot size position.");
         return 0.0;
        }

      double point = Utils::GetPoint(symbol);
      if(point <= 0.0)
        {
         Logger::Error("RiskManager::CalculateLotSize: symbol point size is 0.");
         return 0.0;
        }

      double slDistancePoints = slDistancePrice / point;
      double pointValuePerLot = Utils::GetPointValuePerLot(symbol);
      if(pointValuePerLot <= 0.0)
        {
         Logger::Error("RiskManager::CalculateLotSize: point value per lot is 0 (bad symbol info).");
         return 0.0;
        }

      double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
      double moneyAtRisk = balance * (riskPercentPerTrade / 100.0);
      double riskPerLot   = slDistancePoints * pointValuePerLot;

      if(riskPerLot <= 0.0)
        {
         Logger::Error("RiskManager::CalculateLotSize: computed riskPerLot <= 0.");
         return 0.0;
        }

      double rawLot = moneyAtRisk / riskPerLot;
      double lot    = Utils::NormalizeVolume(rawLot, symbol);

      Logger::Debug(StringFormat(
         "RiskManager: CalculateLotSize balance=%.2f risk%%=%.2f slPts=%.1f rawLot=%.4f -> lot=%.2f",
         balance, riskPercentPerTrade, slDistancePoints, rawLot, lot));

      return lot;
     }

   //=================================================================
   // Drawdown kill-switch (equity peak-to-current, real-time, NOT auto-reset)
   //=================================================================

   //--- Update the tracked equity peak and evaluate drawdown against maxDrawdownPercent.
   //--- Once tripped it LATCHES true and stays true for the rest of this EA run — by design,
   //--- per the confirmed kill-switch policy, this must never auto-reset.
   bool CheckDrawdownKillSwitch(const double maxDrawdownPercent)
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);

      if(g_peakEquity <= 0.0)
         g_peakEquity = equity; // first call: seed the peak

      if(equity > g_peakEquity)
        {
         g_peakEquity = equity;
         if(g_persistReady)
            GlobalVariableSet(PersistKey("DDPEAK"), g_peakEquity);
        }

      double ddPercent = (g_peakEquity > 0.0) ? ((g_peakEquity - equity) / g_peakEquity * 100.0) : 0.0;

      if(!g_ddKillSwitchTripped && ddPercent >= maxDrawdownPercent)
        {
         g_ddKillSwitchTripped = true;
         if(g_persistReady)
           {
            GlobalVariableSet(PersistKey("DDTRIP"), 1.0);
            GlobalVariableFlush(); // force-persist immediately; this event must survive a crash
           }
         Logger::Error(StringFormat(
            "RiskManager: DRAWDOWN KILL-SWITCH TRIPPED. peakEquity=%.2f currentEquity=%.2f drawdown=%.2f%% (limit=%.2f%%). "
            "New order entries are now BLOCKED. Existing positions keep their SL/TP untouched. "
            "State is now PERSISTED across restarts — manual reset required "
            "(InpConfirmResetDrawdownKillSwitch=true).",
            g_peakEquity, equity, ddPercent, maxDrawdownPercent));
        }

      return g_ddKillSwitchTripped;
     }

   //--- Read-only accessor (does not update the peak) for dashboards/logging.
   double GetCurrentDrawdownPercent()
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(g_peakEquity <= 0.0)
         return 0.0;
      return (g_peakEquity - equity) / g_peakEquity * 100.0;
     }

   bool IsDrawdownKillSwitchTripped()
     {
      return g_ddKillSwitchTripped;
     }

   //=================================================================
   // Daily loss limit (auto-resets at server-time day rollover)
   //=================================================================

   //--- Returns true if today's realized loss (balance vs. balance at the start of the
   //--- current server day) has reached/exceeded dailyLossLimitPercent. Rolls the tracked
   //--- day forward automatically — this limit is expected to reset every day, unlike the
   //--- drawdown kill-switch above.
   bool CheckDailyLossLimit(const double dailyLossLimitPercent)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt); // server time, per spec
      int dayOfYear = dt.day_of_year + dt.year * 366;

      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);

      if(g_dailyTrackedDay != dayOfYear)
        {
         g_dailyTrackedDay = dayOfYear;
         g_dayStartBalance = currentBalance;
         if(g_persistReady)
           {
            GlobalVariableSet(PersistKey("DAY"), (double)dayOfYear);
            GlobalVariableSet(PersistKey("DAYBAL"), g_dayStartBalance);
           }
         Logger::Info(StringFormat("RiskManager: new trading day, dayStartBalance=%.2f", g_dayStartBalance));
        }

      if(g_dayStartBalance <= 0.0)
         return false;

      double lossPercent = (g_dayStartBalance - currentBalance) / g_dayStartBalance * 100.0;
      bool exceeded = (lossPercent >= dailyLossLimitPercent);

      if(exceeded)
         Logger::Warn(StringFormat("RiskManager: daily loss limit reached. loss=%.2f%% limit=%.2f%%",
                                    lossPercent, dailyLossLimitPercent));

      return exceeded;
     }

   //=================================================================
   // Open-trade / loss-streak counters
   //=================================================================

   //--- Count currently open positions for this symbol+magic (EA's own positions only).
   int CountOpenTrades(const int magicNumber, const string symbol = NULL)
     {
      string sym = Utils::ResolveSymbol(symbol);
      int count = 0;
      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != sym)
            continue;
         if((int)PositionGetInteger(POSITION_MAGIC) != magicNumber)
            continue;
         count++;
        }
      return count;
     }

   bool CanOpenNewTrade(const int maxOpenTrades, const int magicNumber, const string symbol = NULL)
     {
      int open = CountOpenTrades(magicNumber, symbol);
      bool ok = (open < maxOpenTrades);
      if(!ok)
         Logger::Debug(StringFormat("RiskManager: max open trades reached (%d/%d).", open, maxOpenTrades));
      return ok;
     }

   //--- Count consecutive losing closed trades (most recent first) for this symbol+magic.
   //--- Stops counting at the first winning/breakeven trade encountered going backwards.
   //--- Uses each closing deal's net profit (profit+swap+commission) as the trade result.
   int CountConsecutiveLosses(const int magicNumber, const string symbol = NULL)
     {
      string sym = Utils::ResolveSymbol(symbol);

      datetime from = 0; // beginning of history
      datetime to   = TimeCurrent() + 3600;
      if(!HistorySelect(from, to))
        {
         Logger::Warn("RiskManager: HistorySelect failed, cannot evaluate consecutive losses.");
         return 0;
        }

      int total = HistoryDealsTotal();
      int consecutiveLosses = 0;

      for(int i = total - 1; i >= 0; i--)
        {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket == 0)
            continue;

         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
            continue; // only closing deals represent a finished trade result
         if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != sym)
            continue;
         if((int)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != magicNumber)
            continue;

         double net = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                      HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                      HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

         if(net < 0.0)
           {
            consecutiveLosses++;
            continue;
           }

         break; // first non-loss encountered going backwards -> streak ends
        }

      return consecutiveLosses;
     }

   bool IsMaxConsecutiveLossesExceeded(const int maxConsecutiveLosses, const int magicNumber,
                                        const string symbol = NULL)
     {
      int streak = CountConsecutiveLosses(magicNumber, symbol);
      bool exceeded = (streak >= maxConsecutiveLosses);
      if(exceeded)
         Logger::Warn(StringFormat("RiskManager: consecutive loss limit reached (%d/%d).",
                                    streak, maxConsecutiveLosses));
      return exceeded;
     }

   //=================================================================
   // Spread / session / market-state filters
   //=================================================================

   //--- Spread filter measured in broker POINTS (not pips — correct for gold instruments).
   bool IsSpreadAcceptable(const double maxSpreadPoints, const string symbol = NULL)
     {
      long spread = Utils::GetSpreadPoints(symbol);
      bool ok = (spread <= (long)maxSpreadPoints);
      if(!ok)
         Logger::Debug(StringFormat("RiskManager: spread too wide, spread=%d limit=%.0f pts.",
                                     (int)spread, maxSpreadPoints));
      return ok;
     }

   //--- Internal: parse "HH:MM" into minutes-since-midnight. Returns -1 on malformed input.
   int ParseHHMMToMinutes(const string hhmm)
     {
      string parts[];
      int n = StringSplit(hhmm, ':', parts);
      if(n != 2)
         return -1;
      int h = (int)StringToInteger(parts[0]);
      int m = (int)StringToInteger(parts[1]);
      if(h < 0 || h > 23 || m < 0 || m > 59)
         return -1;
      return h * 60 + m;
     }

   //--- Is current SERVER time within [start,end)? Supports overnight ranges (start > end)
   //--- defensively, though the approved default 08:00-20:00 does not wrap.
   bool IsWithinTradingSession(const string startHHMM, const string endHHMM)
     {
      int startMin = ParseHHMMToMinutes(startHHMM);
      int endMin   = ParseHHMMToMinutes(endHHMM);
      if(startMin < 0 || endMin < 0)
        {
         Logger::Error("RiskManager: malformed session start/end input, blocking trading defensively.");
         return false;
        }

      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int nowMin = dt.hour * 60 + dt.min;

      bool within;
      if(startMin <= endMin)
         within = (nowMin >= startMin && nowMin < endMin);
      else
         within = (nowMin >= startMin || nowMin < endMin); // overnight wrap

      if(!within)
         Logger::Debug(StringFormat("RiskManager: outside trading session (%s-%s), now=%02d:%02d server time.",
                                     startHHMM, endHHMM, dt.hour, dt.min));
      return within;
     }

   //--- Is the symbol actually tradable right now (weekend/holiday/broker-disabled), and
   //--- does the allowed trade mode permit the requested direction?
   bool IsMarketOpenForTrading(const ENUM_SIGNAL_ACTION action, const string symbol = NULL)
     {
      string sym = Utils::ResolveSymbol(symbol);
      ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);

      if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
        {
         Logger::Debug(StringFormat("RiskManager: symbol trade mode=%s, new orders blocked.",
                                     EnumToString(mode)));
         return false;
        }
      if(mode == SYMBOL_TRADE_MODE_LONGONLY && action == ACTION_SELL)
        {
         Logger::Debug("RiskManager: symbol is LONGONLY, SELL signal blocked.");
         return false;
        }
      if(mode == SYMBOL_TRADE_MODE_SHORTONLY && action == ACTION_BUY)
        {
         Logger::Debug("RiskManager: symbol is SHORTONLY, BUY signal blocked.");
         return false;
        }

      // Extra belt-and-suspenders: terminal/account must also be allowed to trade.
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
        {
         Logger::Warn("RiskManager: TERMINAL_TRADE_ALLOWED is false (AutoTrading off?).");
         return false;
        }
      if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
        {
         Logger::Warn("RiskManager: ACCOUNT_TRADE_ALLOWED is false.");
         return false;
        }

      return true;
     }

   //--- Native MQL5 economic-calendar based news filter — independent, defense-in-depth
   //--- check on top of the bridge's own news_filter.py. Blocks new entries when a
   //--- HIGH-importance event for the symbol's profit currency (e.g. USD for XAUUSD) falls
   //--- within +/- newsBufferMinutes of now. Requires terminal Calendar access.
   //---
   //--- REVIEW FIX (mt5-reviewer, critical): the original implementation failed OPEN (returned
   //--- "no blackout" / allowed trading) whenever CalendarValueHistory() itself failed, reasoning
   //--- that bridge/news_filter.py was "the primary control". That reasoning does not hold: as of
   //--- this review bridge/news_filter.py is an intentional stub that ALWAYS returns "no blackout"
   //--- (no calendar data source is wired up yet — see news_filter.py's own docstring). That means
   //--- this native check is, in practice, the ONLY functioning news filter today, and failing open
   //--- here means a live account could trade straight into high-impact news with zero news
   //--- protection and no indication anything was skipped. Flipped to fail CLOSED (block new
   //--- entries) when the Calendar API errors, matching every other filter in this gate. If this
   //--- blocks unexpectedly in the Strategy Tester (Calendar data can be limited/unavailable there),
   //--- disable via InpEnableNewsFilter=false for that specific test run rather than relying on the
   //--- old fail-open behavior in live/demo trading.
   bool IsNewsBlackout(const bool enabled, const int bufferMinutes, const string symbol = NULL)
     {
      if(!enabled)
         return false;

      string sym = Utils::ResolveSymbol(symbol);
      string profitCurrency = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT); // e.g. "USD" for XAUUSD

      datetime now  = TimeGMT();
      datetime from = now - bufferMinutes * 60;
      datetime to   = now + bufferMinutes * 60;

      MqlCalendarValue values[];
      int got = CalendarValueHistory(values, from, to, NULL, profitCurrency);
      if(got < 0)
        {
         Logger::Error(StringFormat(
            "RiskManager: CalendarValueHistory failed (err=%d) — native news filter unavailable. "
            "Failing SAFE: blocking new entries until the Calendar API works again. "
            "(bridge-side news_filter.py is currently a stub and provides no independent coverage — "
            "see docs/XAUGLM_ARCHITECTURE.md section 7.)", GetLastError()));
         return true;
        }

      for(int i = 0; i < ArraySize(values); i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;
         if(ev.importance == CALENDAR_IMPORTANCE_HIGH)
           {
            Logger::Warn(StringFormat("RiskManager: news blackout — high-impact %s event near now (+/-%dmin).",
                                       profitCurrency, bufferMinutes));
            return true;
           }
        }

      return false;
     }

   //=================================================================
   // ATR multiplier clamping (GLM can supply sl/tp multipliers; always clamp)
   //=================================================================

   //--- Clamp a GLM-supplied ATR multiplier into [minV,maxV]. A non-positive value means
   //--- "GLM did not supply this field" -> fall back to defaultValue (already expected to
   //--- be within range) instead of clamping garbage.
   double ClampAtrMultiplier(const double value, const double defaultValue,
                              const double minV, const double maxV, const string label)
     {
      double v = (value > 0.0) ? value : defaultValue;
      if(v < minV)
        {
         Logger::Warn(StringFormat("RiskManager: %s multiplier %.2f below min %.2f, clamped.", label, v, minV));
         v = minV;
        }
      else if(v > maxV)
        {
         Logger::Warn(StringFormat("RiskManager: %s multiplier %.2f above max %.2f, clamped.", label, v, maxV));
         v = maxV;
        }
      return v;
     }

   //=================================================================
   // Final gate — MUST be called immediately before any OrderSend.
   //=================================================================

   //--- Evaluate every safety/risk filter in one place and produce a go/no-go decision plus
   //--- the sized lot. This is intentionally the single choke point: Strategy.mqh calls it
   //--- to decide the trade intent, and XAUGLM.mq5 calls it again immediately before
   //--- OrderSend as a last-line-of-defense re-check (cheap, and state can change between
   //--- signal evaluation and order submission on a live account).
   void EvaluateGate(const SRiskGateParams &p, const ENUM_SIGNAL_ACTION action,
                      const double slDistancePrice, SRiskGateResult &out)
     {
      out.allowed = false;
      out.lot     = 0.0;
      out.reason  = "";

      if(p.emergencyStop)
        {
         out.reason = "InpEmergencyStop is true";
         return;
        }
      if(action != ACTION_BUY && action != ACTION_SELL)
        {
         out.reason = "action is not BUY/SELL";
         return;
        }
      if(CheckDrawdownKillSwitch(p.maxDrawdownPercent))
        {
         out.reason = "drawdown kill-switch tripped (manual reset required)";
         return;
        }
      if(CheckDailyLossLimit(p.dailyLossLimitPercent))
        {
         out.reason = "daily loss limit exceeded";
         return;
        }
      if(!IsMarketOpenForTrading(action))
        {
         out.reason = "market closed / trade mode disallows this direction";
         return;
        }
      if(!CanOpenNewTrade(p.maxOpenTrades, p.magicNumber))
        {
         out.reason = "max open trades reached";
         return;
        }
      if(IsMaxConsecutiveLossesExceeded(p.maxConsecutiveLosses, p.magicNumber))
        {
         out.reason = "max consecutive losses reached";
         return;
        }
      if(!IsSpreadAcceptable(p.maxSpreadPoints))
        {
         out.reason = "spread too wide";
         return;
        }
      if(!IsWithinTradingSession(p.sessionStartHHMM, p.sessionEndHHMM))
        {
         out.reason = "outside trading session";
         return;
        }
      if(IsNewsBlackout(p.newsFilterEnabled, p.newsBufferMinutes))
        {
         out.reason = "news blackout window";
         return;
        }
      if(slDistancePrice <= 0.0)
        {
         out.reason = "invalid SL distance (<=0)";
         return;
        }

      double lot = CalculateLotSize(slDistancePrice, p.riskPercentPerTrade, p.tradingMode, p.minLotOverride);
      if(lot <= 0.0)
        {
         out.reason = "calculated lot size <= 0";
         return;
        }

      out.lot     = lot;
      out.allowed = true;
      out.reason  = "ok";
     }
  }
