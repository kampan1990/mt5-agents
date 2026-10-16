//+------------------------------------------------------------------+
//|                                             EMATrendPullback.mq5 |
//|  EA based on the EMA_Trend_Pullback_Dashboard indicator:         |
//|  EMA200 trend + EMA50 strength/slope + EMA20 pullback / cross.   |
//|  Signals on CLOSED bars only. Every order has SL and TP.         |
//+------------------------------------------------------------------+
#property copyright   "mt5-agents"
#property version     "1.00"
#property description "EMA 20/50/200 trend pullback EA with HTF, slope, ADX and sideways filters."
#property description "Risk: % balance lot sizing, mandatory SL/TP, max drawdown halt, daily loss limit."

#include <Trade/Trade.mqh>
#include "Logger.mqh"
#include "Utils.mqh"
#include "Strategy.mqh"
#include "RiskManager.mqh"

enum ENUM_EXIT_MODE
  {
   EXITM_SLTP_ONLY = 0,   // SL/TP only
   EXITM_EMA_CLOSE = 1    // Also close when bar closes beyond exit EMA
  };
enum ENUM_EXIT_REF
  {
   EXREF_EMA_FAST = 0,    // EMA Fast (20)
   EXREF_EMA_MID  = 1     // EMA Mid (50)
  };

//--- inputs
input group "=== General ==="
input long             InpMagic          = 20260101;     // Magic number
input string           InpComment        = "EMATP";      // Order comment
input int              InpMaxPositions   = 1;            // Max open positions (this EA/symbol)
input bool             InpCloseOpposite  = true;         // Close position on opposite signal
input int              InpSlippagePts    = 30;           // Max slippage (points)
input int              InpMaxRetries     = 3;            // Order retries on requote/price change

input group "=== EMA / Indicators ==="
input int              InpEmaFast        = 20;           // EMA fast (pullback zone / trail)
input int              InpEmaMid         = 50;           // EMA mid (strength / dynamic S-R)
input int              InpEmaSlow        = 200;          // EMA slow (main trend filter)
input int              InpAtrPeriod      = 14;           // ATR period
input int              InpAdxPeriod      = 14;           // ADX period

input group "=== Signal type ==="
input ENUM_SIG_MODE    InpSigMode        = SIG_BOTH;     // Signal mode
input ENUM_ENTRY_MODE  InpEntryMode      = ENTRY_RECLAIM;// Pullback trigger
input int              InpPullbackBars   = 5;            // Look-back bars for EMA20 touch
input double           InpMaxDist        = 1.5;          // Max distance from EMA20 (x ATR)
input double           InpCrossGap       = 0.15;         // Crossover min gap EMA20-EMA50 (x ATR)
input bool             InpCrossNeedDist  = false;        // Apply max distance to CROSS signals too

input group "=== Trend filters ==="
input bool             InpUseHTF         = true;         // Use higher-timeframe trend
input ENUM_TIMEFRAMES  InpHTF            = PERIOD_H4;    // Higher timeframe (> chart TF)
input int              InpHtfFast        = 50;           // HTF EMA fast
input int              InpHtfSlow        = 200;          // HTF EMA slow
input bool             InpUseSlope       = true;         // Use EMA50 slope filter
input int              InpSlopeBars      = 5;            // Slope look-back bars
input double           InpSlopeMult      = 0.3;          // Min slope (x ATR)
input bool             InpUseAdx         = true;         // Use ADX filter
input double           InpAdxMin         = 20.0;         // Min ADX
input bool             InpUseCross       = true;         // Use sideways filter (EMA50 crosses)
input int              InpCrossLookback  = 20;           // Cross look-back bars
input int              InpMaxCrosses     = 3;            // Block when crosses >= this

input group "=== Market filters ==="
input bool             InpUseSession     = false;        // Use session filter (server hour)
input int              InpSessStart      = 7;            // Session start hour
input int              InpSessEnd        = 21;           // Session end hour
input int              InpMaxSpread      = 0;            // Max spread in points (0 = off)
input double           InpMinAtrPts      = 0;            // Min ATR in points (0 = off)
input double           InpMaxAtrPts      = 0;            // Max ATR in points (0 = off)

input group "=== Risk management ==="
input double           InpRiskPct        = 1.0;          // Risk per trade (% of balance)
input ENUM_SL_MODE     InpSlMode         = SL_ATR;       // Stop-loss mode
input double           InpSlAtr          = 1.5;          // SL distance (x ATR)
input int              InpSwingBars      = 10;           // Swing SL look-back bars
input double           InpSwingBufAtr    = 0.2;          // Swing SL buffer (x ATR)
input double           InpRR             = 2.0;          // Take-profit risk:reward
input double           InpMinSlPts       = 0;            // Min SL in points (0 = off)
input double           InpMaxSlPts       = 0;            // Max SL in points, skip if wider (0 = off)
input double           InpMaxLot         = 0;            // Max lot per trade (0 = broker max)
input double           InpMaxDDPct       = 20.0;         // Max equity drawdown % -> halt EA (0 = off)
input bool             InpCloseOnHalt    = true;         // Close all EA positions on DD halt
input double           InpDailyLossPct   = 5.0;          // Daily loss % -> stop for the day (0 = off)
input bool             InpResetDDOnStart = false;        // Reset stored DD peak / halt flag on start

input group "=== Exit management ==="
input ENUM_EXIT_MODE   InpExitMode       = EXITM_SLTP_ONLY; // Exit mode
input ENUM_EXIT_REF    InpExitRef        = EXREF_EMA_MID;   // Exit EMA (for EMA close exit)
input bool             InpUseBreakEven   = true;         // Move SL to break-even
input double           InpBeAtR          = 1.0;          // Break-even trigger (x initial risk R)
input int              InpBeLockPts      = 10;           // Points locked beyond entry at BE
input bool             InpUseTrailEma    = false;        // Trail SL along EMA fast (on new bar)
input double           InpTrailBufAtr    = 0.3;          // Trail buffer beyond EMA fast (x ATR)

input group "=== Logging / Display ==="
input ENUM_LOGLV       InpLogLevel       = LOGLV_INFO;   // Log level
input bool             InpLogToFile      = true;         // Write log file (MQL5/Files)
input bool             InpShowInfo       = true;         // Show status on chart (Comment)

//--- globals
CTrade       g_trade;
CLogger      g_log;
CStrategy    g_strat;
CRiskManager g_risk;
CNewBar      g_newBar;
SSignal      g_lastSig;
bool         g_haveSig   = false;
bool         g_pendingEval = false;   // new bar seen but data was not ready yet
string       g_lastEvent = "-";

//+------------------------------------------------------------------+
int OnInit()
  {
   string logName = StringFormat("EMATrendPullback_%s_%I64d.log", _Symbol, InpMagic);
   g_log.Init(logName, InpLogLevel, InpLogToFile);

   SStrategyParams sp;
   sp.emaFast       = InpEmaFast;
   sp.emaMid        = InpEmaMid;
   sp.emaSlow       = InpEmaSlow;
   sp.atrPeriod     = InpAtrPeriod;
   sp.adxPeriod     = InpAdxPeriod;
   sp.sigMode       = InpSigMode;
   sp.entryMode     = InpEntryMode;
   sp.pullbackBars  = InpPullbackBars;
   sp.maxDist       = InpMaxDist;
   sp.crossGap      = InpCrossGap;
   sp.crossNeedDist = InpCrossNeedDist;
   sp.useHtf        = InpUseHTF;
   sp.htf           = InpHTF;
   sp.htfFast       = InpHtfFast;
   sp.htfSlow       = InpHtfSlow;
   sp.useSlope      = InpUseSlope;
   sp.slopeBars     = InpSlopeBars;
   sp.slopeMult     = InpSlopeMult;
   sp.useAdx        = InpUseAdx;
   sp.adxMin        = InpAdxMin;
   sp.useCross      = InpUseCross;
   sp.crossLookback = InpCrossLookback;
   sp.maxCrosses    = InpMaxCrosses;
   sp.swingBars     = InpSwingBars;

   string err;
   if(!g_strat.Init(_Symbol, _Period, sp, err))
     {
      g_log.Error("Strategy init failed: " + err);
      return INIT_PARAMETERS_INCORRECT;
     }

   SRiskParams rp;
   rp.riskPct      = InpRiskPct;
   rp.slMode       = InpSlMode;
   rp.slAtr        = InpSlAtr;
   rp.swingBufAtr  = InpSwingBufAtr;
   rp.rr           = InpRR;
   rp.minSlPts     = InpMinSlPts;
   rp.maxSlPts     = InpMaxSlPts;
   rp.maxLot       = InpMaxLot;
   rp.maxDDPct     = InpMaxDDPct;
   rp.dailyLossPct = InpDailyLossPct;
   rp.resetOnStart = InpResetDDOnStart;
   if(!g_risk.Init(_Symbol, InpMagic, rp, GetPointer(g_log), err))
     {
      g_log.Error("Risk manager init failed: " + err);
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpMaxPositions < 1 || InpMaxRetries < 1 || (InpUseBreakEven && InpBeAtR <= 0))
     {
      g_log.Error("Invalid general/exit parameters");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePts);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   g_log.Info(StringFormat("EMATrendPullback started on %s %s | magic %I64d | risk %.2f%% | SL mode %s x%.2f | RR %.2f | maxDD %.1f%% | daily %.1f%%",
                           _Symbol, EnumToString(_Period), InpMagic, InpRiskPct, EnumToString(InpSlMode),
                           InpSlAtr, InpRR, InpMaxDDPct, InpDailyLossPct));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_strat.Release();
   g_log.Info(StringFormat("EMATrendPullback stopped, reason %d", reason));
   g_log.Close();
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   g_risk.Update();

   //--- max drawdown halt: optionally flatten, never open new trades
   if(g_risk.IsHalted())
     {
      if(InpCloseOnHalt && CountPositions(_Symbol, InpMagic, 0) > 0)
         ClosePositions(0, "max drawdown halt");
      UpdateInfo();
      return;
     }

   if(InpUseBreakEven)
      ManageBreakEven();

   if(g_newBar.Check(_Symbol, _Period))
      g_pendingEval = true;
   if(!g_pendingEval)
     {
      UpdateInfo();
      return;
     }

   SSignal sig;
   if(!g_strat.Evaluate(sig))
     {
      g_log.Debug("Indicator data not ready - retry on next tick");
      return;
     }
   g_pendingEval = false;
   g_lastSig = sig;
   g_haveSig = true;

   ManageExits(sig);

   if(sig.dir != 0)
     {
      g_log.Info(StringFormat("SIGNAL %s (%s) bar %s close %s | ADX %.1f slope %.2f dist %.2f crosses %d",
                              DirText(sig.dir), CStrategy::TypeText(sig.type),
                              TimeToString(sig.barTime, TIME_DATE | TIME_MINUTES),
                              DoubleToString(sig.close1, _Digits), sig.adx, sig.slope, sig.dist, sig.crosses));
      TryEnter(sig);
     }
   UpdateInfo();
  }

//+------------------------------------------------------------------+
//| Entry pipeline: opposite close -> position limits -> filters ->  |
//| risk guards -> order                                              |
//+------------------------------------------------------------------+
void TryEnter(const SSignal &sig)
  {
   const int dir = sig.dir;

   if(InpCloseOpposite && CountPositions(_Symbol, InpMagic, -dir) > 0)
      ClosePositions(-dir, "opposite signal");

   if(CountPositions(_Symbol, InpMagic, dir) > 0)
     {
      g_log.Info("Skip: position in same direction already open");
      return;
     }
   int total = CountPositions(_Symbol, InpMagic, 0);
   if(total >= InpMaxPositions)
     {
      g_log.Info(StringFormat("Skip: max positions reached (%d)", total));
      return;
     }
   if(!IsHedgingAccount() && total > 0)
     {
      g_log.Info("Skip: netting account with an open opposite position");
      return;
     }

   string why;
   if(!MarketFiltersOk(sig, why))
     {
      g_log.Info("Skip (market filter): " + why);
      return;
     }
   if(!g_risk.CanOpen(why))
     {
      g_log.Warn("Skip (risk guard): " + why);
      return;
     }
   if(!IsTradingAllowed(_Symbol, dir, why))
     {
      g_log.Warn("Skip (trading not allowed): " + why);
      return;
     }

   OpenTrade(sig);
  }

//+------------------------------------------------------------------+
bool MarketFiltersOk(const SSignal &sig, string &why)
  {
   if(InpUseSession && !InSession(TimeCurrent(), InpSessStart, InpSessEnd))
     {
      why = "outside session";
      return false;
     }
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(InpMaxSpread > 0 && spread > InpMaxSpread)
     {
      why = StringFormat("spread %d > %d", (int)spread, InpMaxSpread);
      return false;
     }
   double atrPts = sig.atr / _Point;
   if(InpMinAtrPts > 0 && atrPts < InpMinAtrPts)
     {
      why = StringFormat("ATR %.0f pts < min %.0f", atrPts, InpMinAtrPts);
      return false;
     }
   if(InpMaxAtrPts > 0 && atrPts > InpMaxAtrPts)
     {
      why = StringFormat("ATR %.0f pts > max %.0f", atrPts, InpMaxAtrPts);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Market order with mandatory SL/TP, retry on transient errors     |
//+------------------------------------------------------------------+
bool OpenTrade(const SSignal &sig)
  {
   const int dir = sig.dir;
   const string cmt = InpComment + " " + CStrategy::TypeText(sig.type);

   for(int attempt = 1; attempt <= InpMaxRetries; attempt++)
     {
      MqlTick tk;
      if(!SymbolInfoTick(_Symbol, tk))
        {
         g_log.Error(StringFormat("SymbolInfoTick failed, error %d", GetLastError()));
         return false;
        }
      double entry = (dir == 1) ? tk.ask : tk.bid;

      double sl, tp;
      string why;
      if(!g_risk.BuildStops(dir, entry, sig.atr, sig.swingLow, sig.swingHigh, sl, tp, why))
        {
         g_log.Warn("Skip (SL/TP): " + why);
         return false;
        }
      double lot = g_risk.CalcLot(dir, entry, sl, why);
      if(lot <= 0)
        {
         g_log.Warn("Skip (lot): " + why);
         return false;
        }
      //--- project rule: never send an order without SL and TP
      if(sl <= 0 || tp <= 0)
        {
         g_log.Error("Refusing order without SL/TP");
         return false;
        }

      ResetLastError();
      bool ok = (dir == 1) ? g_trade.Buy(lot, _Symbol, 0.0, sl, tp, cmt)
                : g_trade.Sell(lot, _Symbol, 0.0, sl, tp, cmt);
      int  err = GetLastError();
      uint rc  = g_trade.ResultRetcode();

      if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
        {
         g_lastEvent = StringFormat("OPEN %s %.2f @ %s", DirText(dir), lot, DoubleToString(g_trade.ResultPrice(), _Digits));
         g_log.Trade(StringFormat("OPEN %s %s lot %.2f price %s SL %s TP %s risk %.2f%% | deal #%I64u",
                                  DirText(dir), CStrategy::TypeText(sig.type), lot,
                                  DoubleToString(g_trade.ResultPrice(), _Digits),
                                  DoubleToString(sl, _Digits), DoubleToString(tp, _Digits),
                                  InpRiskPct, g_trade.ResultDeal()));
         return true;
        }

      g_log.Error(StringFormat("Order %s failed (attempt %d/%d): retcode %u %s, GetLastError %d",
                               DirText(dir), attempt, InpMaxRetries, rc,
                               g_trade.ResultRetcodeDescription(), err));

      bool transient = (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED ||
                        rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_TIMEOUT ||
                        rc == TRADE_RETCODE_CONNECTION);
      if(!transient)
         return false;
      Sleep(300);
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Close EA positions; dir: +1 buys, -1 sells, 0 all                |
//+------------------------------------------------------------------+
void ClosePositions(const int dir, const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      long type = PositionGetInteger(POSITION_TYPE);
      int  pdir = (type == POSITION_TYPE_BUY) ? 1 : -1;
      if(dir != 0 && pdir != dir)
         continue;

      ClosePositionTicket(ticket, pdir, reason);
     }
  }

//+------------------------------------------------------------------+
//| Close one position (must be selected) with result checking       |
//+------------------------------------------------------------------+
bool ClosePositionTicket(const ulong ticket, const int pdir, const string reason)
  {
   double profit = PositionGetDouble(POSITION_PROFIT);
   ResetLastError();
   if(g_trade.PositionClose(ticket) &&
      (g_trade.ResultRetcode() == TRADE_RETCODE_DONE || g_trade.ResultRetcode() == TRADE_RETCODE_PLACED))
     {
      g_lastEvent = StringFormat("CLOSE %s (%s)", DirText(pdir), reason);
      g_log.Trade(StringFormat("CLOSE %s #%I64u reason: %s | floating P/L %.2f",
                               DirText(pdir), ticket, reason, profit));
      return true;
     }
   g_log.Error(StringFormat("Close #%I64u failed: retcode %u %s, GetLastError %d",
                            ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription(), GetLastError()));
   return false;
  }

//+------------------------------------------------------------------+
//| Modify SL keeping TP; validates stops & freeze level             |
//+------------------------------------------------------------------+
bool ModifySL(const ulong ticket, const int pdir, const double newSL, const double tp, const string why)
  {
   if(tp <= 0)
      return false;   // never leave a position without TP through this path
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return false;
   double price  = (pdir == 1) ? tk.bid : tk.ask;
   double minGap = (double)MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                   SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * _Point;
   if(pdir == 1 && newSL >= price - minGap)
      return false;
   if(pdir == -1 && newSL <= price + minGap)
      return false;

   double sl = NormalizeToTick(_Symbol, newSL);
   ResetLastError();
   if(g_trade.PositionModify(ticket, sl, tp) && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
     {
      g_log.Trade(StringFormat("MODIFY #%I64u SL -> %s (%s)", ticket, DoubleToString(sl, _Digits), why));
      return true;
     }
   g_log.Error(StringFormat("Modify #%I64u failed: retcode %u %s, GetLastError %d",
                            ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription(), GetLastError()));
   return false;
  }

//+------------------------------------------------------------------+
//| Break-even: initial risk R = |TP - open| / RR (TP is never moved)|
//+------------------------------------------------------------------+
void ManageBreakEven()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      int    pdir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double cur  = PositionGetDouble(POSITION_PRICE_CURRENT);
      if(tp <= 0)
         continue;
      double R = MathAbs(tp - open) / InpRR;
      if(R <= 0)
         continue;
      double beSL = open + pdir * InpBeLockPts * _Point;
      bool   already = (sl > 0) && (pdir == 1 ? sl >= beSL : sl <= beSL);
      if(already)
         continue;
      if(pdir * (cur - open) >= InpBeAtR * R)
         ModifySL(ticket, pdir, beSL, tp, "break-even");
     }
  }

//+------------------------------------------------------------------+
//| New-bar exits: EMA close exit and EMA trailing stop              |
//+------------------------------------------------------------------+
void ManageExits(const SSignal &sig)
  {
   double exitRef = (InpExitRef == EXREF_EMA_FAST) ? sig.emaF1 : sig.emaM1;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      int    pdir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);

      if(InpExitMode == EXITM_EMA_CLOSE)
        {
         bool hit = (pdir == 1) ? sig.close1 < exitRef : sig.close1 > exitRef;
         if(hit)
           {
            ClosePositionTicket(ticket, pdir,
                                StringFormat("close beyond EMA%d", InpExitRef == EXREF_EMA_FAST ? InpEmaFast : InpEmaMid));
            continue;
           }
        }

      if(InpUseTrailEma && sig.atr > 0)
        {
         double trail = sig.emaF1 - pdir * InpTrailBufAtr * sig.atr;
         bool   better = (sl <= 0) || (pdir == 1 ? trail > sl + _Point : trail < sl - _Point);
         if(better)
            ModifySL(ticket, pdir, trail, tp, "EMA trail");
        }
     }
  }

//+------------------------------------------------------------------+
//| Log every deal of this EA (entries, SL/TP hits, manual closes)   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol ||
      HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;

   ENUM_DEAL_ENTRY  entry  = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
     {
      double pl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
                  HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                  HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      string rs = (reason == DEAL_REASON_SL) ? "SL" : (reason == DEAL_REASON_TP ? "TP" :
                  (reason == DEAL_REASON_SO ? "STOP OUT" : "EA/manual"));
      g_lastEvent = StringFormat("EXIT %s P/L %.2f", rs, pl);
      g_log.Trade(StringFormat("DEAL OUT #%I64u by %s | volume %.2f price %s | net P/L %.2f | balance %.2f",
                               trans.deal, rs, HistoryDealGetDouble(trans.deal, DEAL_VOLUME),
                               DoubleToString(HistoryDealGetDouble(trans.deal, DEAL_PRICE), _Digits),
                               pl, AccountInfoDouble(ACCOUNT_BALANCE)));
     }
  }

//+------------------------------------------------------------------+
void UpdateInfo()
  {
   if(!InpShowInfo || (MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)))
      return;
   string s = "EMA Trend Pullback EA  |  " + _Symbol + " " + EnumToString(_Period) + "\n";
   s += StringFormat("Status: %s   DD %.2f%% / %.1f%%   Day loss %.2f%% / %.1f%%\n",
                     g_risk.IsHalted() ? "HALTED (max DD)" : "ACTIVE",
                     g_risk.CurrentDDPct(), InpMaxDDPct, g_risk.DailyLossPct(), InpDailyLossPct);
   s += StringFormat("Positions: %d   Risk/trade %.2f%%   RR %.1f\n",
                     CountPositions(_Symbol, InpMagic, 0), InpRiskPct, InpRR);
   if(g_haveSig)
     {
      string bias = g_lastSig.trend == 1 ? "BULL" : (g_lastSig.trend == -1 ? "BEAR" : "NEUTRAL");
      s += StringFormat("Bar %s  Bias %s  HTF %d  ADX %.1f  Slope %.2f  Crosses %d  Dist %.2f\n",
                        TimeToString(g_lastSig.barTime, TIME_DATE | TIME_MINUTES), bias, g_lastSig.htf,
                        g_lastSig.adx, g_lastSig.slope, g_lastSig.crosses, g_lastSig.dist);
      s += StringFormat("Signal: %s (%s)\n", DirText(g_lastSig.dir), CStrategy::TypeText(g_lastSig.type));
     }
   s += "Last event: " + g_lastEvent;
   Comment(s);
  }
//+------------------------------------------------------------------+
