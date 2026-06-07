//+------------------------------------------------------------------+
//| TriMagicGrid.mq5                                                 |
//| TriMagicGrid EA                                                  |
//| Version: 1.0.0                                                   |
//| Created: 2026.06.07                                              |
//+------------------------------------------------------------------+
#property strict
#property copyright "TriMagicGrid EA"
#property version   "1.00"
#property description "Three-magic grid EA with M2 assist controller, keeper system, and flexible TP modes."

#include "Defines.mqh"
#include "Utils.mqh"
#include "Logger.mqh"
#include "PositionTracker.mqh"
#include "RiskManager.mqh"
#include "GridEngine.mqh"
#include "M2Controller.mqh"
#include "BestKeeper.mqh"
#include "TPManager.mqh"
#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//|  INPUT PARAMETERS                                                |
//+------------------------------------------------------------------+

// --- Magic numbers ---
input int    MagicM1          = 110001;   // Magic number — buy grid (M1)
input int    MagicM2          = 110002;   // Magic number — assist/hedge (M2)
input int    MagicM3          = 110003;   // Magic number — sell grid (M3)

// --- Grid configuration ---
input double GridPoints       = 100.0;    // Grid spacing in points
input double BaseLotPct       = 0.5;      // Base lot as % of balance (e.g. 0.5 = 0.5%)
input double BuyDownMult      = 2.0;      // Buy lot multiplier on adverse (downward) move
input double BuyUpMult        = 1.1;      // Buy lot multiplier on favourable (upward) move
input double SellUpMult       = 2.0;      // Sell lot multiplier on adverse (upward) move
input double SellDownMult     = 1.1;      // Sell lot multiplier on favourable (downward) move
input double MaxLotPerOrder   = 10.0;     // Maximum lot size for a single order
input double MaxTotalLots     = 50.0;     // Maximum total open lots across all magics

// --- M2 / lock configuration ---
input double LockThreshold    = -500.0;   // Profit threshold (negative) that triggers M2 lock
input int    ADXPeriod        = 14;       // ADX indicator period
input ENUM_TIMEFRAMES ADXTF   = PERIOD_H1;// Timeframe used for ADX calculation
input double ADXThreshold     = 25.0;     // Minimum ADX value to confirm trend direction

// --- TP mode ---
input ENUM_TP_MODE TPMode     = TP_MODE_1;// TP calculation mode

// Mode 1: individual magic profit targets
input double TPProfitM1       = 50.0;     // [Mode 1] M1 profit target in account currency
input double TPProfitM2       = 50.0;     // [Mode 1] M2 profit target in account currency
input double TPProfitM3       = 50.0;     // [Mode 1] M3 profit target in account currency

// Mode 2: paired magic profit targets (use ENUM_MAGIC_ID indices 0/1/2)
input int    TPPair1Magic1    = 0;        // [Mode 2] Pair 1: magic index A (0=M1,1=M3,2=M2)
input int    TPPair1Magic2    = 2;        // [Mode 2] Pair 1: magic index B
input double TPPair1Profit    = 100.0;    // [Mode 2] Pair 1 combined profit target
input int    TPPair2Magic1    = 2;        // [Mode 2] Pair 2: magic index A
input int    TPPair2Magic2    = 1;        // [Mode 2] Pair 2: magic index B
input double TPPair2Profit    = 100.0;    // [Mode 2] Pair 2 combined profit target

// Mode 3: all-magic combined profit target
input double TPAllProfit      = 150.0;    // [Mode 3] Total combined profit target

// --- Loss pull ---
input bool   EnableLossPull   = true;     // Enable automatic close of worst positions
input int    LossPullCount    = 1;        // Number of worst positions to close per cycle

// --- Keeper configuration ---
input int    KeeperCountBuy   = 1;        // Number of best buy positions to protect
input int    KeeperCountSell  = 1;        // Number of best sell positions to protect
input double KeeperTPProfit   = 200.0;    // Combined keeper profit target to close keepers

// --- Risk management ---
input double MaxDrawdownPct   = 20.0;     // Maximum session drawdown % before trading halts
input double DailyLossLimit   = 300.0;    // Maximum daily loss in account currency
input bool   UseHardSL        = false;    // Attach a hard stop-loss to every order
input double HardSLPoints     = 500.0;    // Hard SL distance in points (when UseHardSL=true)

// --- Trading hours ---
input bool   EnableTimeFilter = true;     // Restrict trading to specified hours
input int    StartHour        = 2;        // Trading start hour (server time, 0-23)
input int    EndHour          = 22;       // Trading end hour (server time, 0-23, exclusive)

// --- System ---
input bool   EmergencyStop    = false;    // Hard emergency stop — no new orders when true
input int    SlippagePoints   = 30;       // Maximum allowed slippage in points
input bool   LogToFile        = true;     // Write log output to a file
input string LogFileName      = "TMG_Log";// Base log filename (date appended automatically)

//+------------------------------------------------------------------+
//|  MODULE INSTANCES                                                 |
//+------------------------------------------------------------------+
CLogger*          g_logger   = NULL;
CPositionTracker* g_tracker  = NULL;
CRiskManager*     g_risk     = NULL;
CGridEngine*      g_grid     = NULL;
CM2Controller*    g_m2       = NULL;
CBestKeeper*      g_keeper   = NULL;
CTPManager*       g_tp       = NULL;
CTrade*           g_trade    = NULL;

//--- Day-change detection for daily loss reset
datetime g_lastDayDate = 0;

//+------------------------------------------------------------------+
//| OpenOrder — send a market order through CTrade with full logging |
//| Parameters:                                                       |
//|   magic   — magic number to assign                               |
//|   type    — ORDER_TYPE_BUY or ORDER_TYPE_SELL                    |
//|   lots    — volume                                               |
//| Returns: true when the order was accepted by the broker          |
//+------------------------------------------------------------------+
bool OpenOrder(int magic, ENUM_ORDER_TYPE type, double lots)
{
   // Safety gate — must be called only after IsTradingAllowed() is confirmed
   if(!g_risk.IsTradingAllowed()) return false;

   string symbol = _Symbol;

   // Assign magic and slippage before placing the order
   g_trade.SetExpertMagicNumber(magic);
   g_trade.SetDeviationInPoints((ulong)SlippagePoints);

   double slPrice = 0.0;
   if(UseHardSL)
   {
      double dist = PointsToPrice(symbol, HardSLPoints);
      if(type == ORDER_TYPE_BUY)
         slPrice = SymbolInfoDouble(symbol, SYMBOL_ASK) - dist;
      else
         slPrice = SymbolInfoDouble(symbol, SYMBOL_BID) + dist;

      slPrice = NormalizeDouble(slPrice, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
   }

   bool ok = false;
   if(type == ORDER_TYPE_BUY)
      ok = g_trade.Buy(lots, symbol, 0.0, slPrice, 0.0,
                       StringFormat("TMG_M%d", magic));
   else
      ok = g_trade.Sell(lots, symbol, 0.0, slPrice, 0.0,
                        StringFormat("TMG_M%d", magic));

   if(!ok)
   {
      if(g_logger != NULL)
         g_logger.LogError("OpenOrder",
                           (int)g_trade.ResultRetcode(),
                           StringFormat("type=%s lots=%.2f magic=%d retcode=%d",
                                        EnumToString(type), lots, magic,
                                        (int)g_trade.ResultRetcode()));
      return false;
   }

   ulong ticket = g_trade.ResultOrder();
   double execPrice = g_trade.ResultPrice();

   if(g_logger != NULL)
      g_logger.LogTrade("OPEN", ticket, execPrice, lots, 0.0,
                        StringFormat("magic=%d type=%s sl=%.5f",
                                     magic, EnumToString(type), slPrice));
   return true;
}

//+------------------------------------------------------------------+
//| CheckDayChange — reset daily risk counter when date rolls over   |
//+------------------------------------------------------------------+
void CheckDayChange()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);

   if(today != g_lastDayDate)
   {
      g_lastDayDate = today;
      g_risk.OnNewDay();
   }
}

//+------------------------------------------------------------------+
//| OnInit — create and initialise all EA modules                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // ----- Allocate all modules -----
   g_logger  = new CLogger();
   g_tracker = new CPositionTracker();
   g_risk    = new CRiskManager();
   g_grid    = new CGridEngine();
   g_m2      = new CM2Controller();
   g_keeper  = new CBestKeeper();
   g_tp      = new CTPManager();
   g_trade   = new CTrade();

   if(g_logger  == NULL || g_tracker == NULL || g_risk  == NULL ||
      g_grid    == NULL || g_m2      == NULL || g_keeper == NULL ||
      g_tp      == NULL || g_trade   == NULL)
   {
      Print("TriMagicGrid::OnInit — memory allocation failed");
      return INIT_FAILED;
   }

   // ----- Logger -----
   g_logger.Init(true, LogToFile, LogFileName);

   // ----- PositionTracker -----
   g_tracker.Init(MagicM1, MagicM3, MagicM2, g_logger);

   // ----- RiskManager -----
   g_risk.Init(MaxDrawdownPct, DailyLossLimit, BaseLotPct,
               MaxLotPerOrder, MaxTotalLots, g_logger);

   if(EmergencyStop)
      g_risk.SetKillSwitch(true);

   // ----- GridEngine -----
   g_grid.Init(GridPoints, BuyDownMult, BuyUpMult,
               SellUpMult, SellDownMult,
               _Symbol, g_tracker, g_risk, g_logger);

   // ----- M2Controller -----
   g_m2.Init(LockThreshold, ADXPeriod, ADXTF, ADXThreshold,
             g_tracker, g_logger);

   if(!g_m2.CreateIndicators(_Symbol))
   {
      g_logger.LogError("OnInit", 0, "CM2Controller::CreateIndicators failed — aborting");
      return INIT_FAILED;
   }

   // ----- BestKeeper -----
   g_keeper.Init(KeeperCountBuy, KeeperCountSell, g_tracker, g_logger);

   // ----- TPManager -----
   g_tp.Init(TPMode, g_tracker, g_keeper, g_logger, g_trade);
   g_tp.SetTPMode1Params(TPProfitM1, TPProfitM2, TPProfitM3);
   g_tp.SetTPMode2Params(TPPair1Magic1, TPPair1Magic2, TPPair1Profit,
                         TPPair2Magic1, TPPair2Magic2, TPPair2Profit);
   g_tp.SetTPMode3Params(TPAllProfit);
   g_tp.SetLossPullParams(EnableLossPull, LossPullCount);
   g_tp.SetKeeperTP(KeeperTPProfit);

   // ----- CTrade -----
   g_trade.SetDeviationInPoints((ulong)SlippagePoints);

   // ----- Day tracker -----
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   g_lastDayDate = StructToTime(dt);

   g_logger.LogInfo(StringFormat(
      "TriMagicGrid v1.0.0 initialised on %s — M1=%d M2=%d M3=%d",
      _Symbol, MagicM1, MagicM2, MagicM3));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick — main EA execution loop                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   // 0. Day-change check for daily loss reset
   CheckDayChange();

   // 1. Refresh position registry
   g_tracker.Refresh();

   // 2. Emergency stop / risk gates
   if(EmergencyStop)
   {
      g_logger.LogWarn("OnTick — EmergencyStop active; no trading");
      return;
   }
   if(!g_risk.IsTradingAllowed()) return;

   // 3. Trading hours filter
   if(EnableTimeFilter && !IsWithinTradingHours(StartHour, EndHour)) return;

   // 4. Update keeper flags
   g_keeper.Update();

   // 5. Evaluate TP conditions and execute closes
   g_tp.CheckAndExecuteTP();

   // 6. Run M2 state machine (updates direction + locked flags)
   g_m2.Update();

   // 7. Refresh again after possible TP closes so state is current
   g_tracker.Refresh();

   // ----------------------------------------------------------------
   // 8. M1 buy grid entry (skip when M1 is locked by M2 controller)
   // ----------------------------------------------------------------
   MagicState stM1 = g_tracker.GetMagicState(MAGIC_M1);
   if(!stM1.isLocked)
   {
      double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double nextLot  = 0.0;

      if(g_grid.ShouldAddBuy(askPrice, nextLot))
         OpenOrder(MagicM1, ORDER_TYPE_BUY, nextLot);
   }

   // ----------------------------------------------------------------
   // 9. M3 sell grid entry (skip when M3 is locked by M2 controller)
   // ----------------------------------------------------------------
   MagicState stM3 = g_tracker.GetMagicState(MAGIC_M3);
   if(!stM3.isLocked)
   {
      double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double nextLot  = 0.0;

      if(g_grid.ShouldAddSell(bidPrice, nextLot))
         OpenOrder(MagicM3, ORDER_TYPE_SELL, nextLot);
   }

   // ----------------------------------------------------------------
   // 10. M2 grid entry — direction set by M2 state machine
   // ----------------------------------------------------------------
   int m2Dir = g_m2.GetM2Direction();
   if(m2Dir != -1)
   {
      ENUM_POSITION_TYPE dir = (ENUM_POSITION_TYPE)m2Dir;
      double price    = (dir == POSITION_TYPE_BUY)
                        ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double nextLot  = 0.0;

      if(g_grid.ShouldAddM2(dir, price, nextLot))
      {
         ENUM_ORDER_TYPE otype = (dir == POSITION_TYPE_BUY)
                                 ? ORDER_TYPE_BUY
                                 : ORDER_TYPE_SELL;
         OpenOrder(MagicM2, otype, nextLot);
      }
   }
}

//+------------------------------------------------------------------+
//| OnDeinit — release indicator handles and delete all modules      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_m2 != NULL)
   {
      g_m2.ReleaseIndicators();
      delete g_m2;
      g_m2 = NULL;
   }

   if(g_logger != NULL)
   {
      g_logger.LogInfo(StringFormat(
         "TriMagicGrid deinitialized — reason=%d", reason));
      g_logger.Close();
   }

   // Delete remaining modules in reverse dependency order
   if(g_tp      != NULL) { delete g_tp;      g_tp      = NULL; }
   if(g_keeper  != NULL) { delete g_keeper;  g_keeper  = NULL; }
   if(g_grid    != NULL) { delete g_grid;    g_grid    = NULL; }
   if(g_risk    != NULL) { delete g_risk;    g_risk    = NULL; }
   if(g_tracker != NULL) { delete g_tracker; g_tracker = NULL; }
   if(g_trade   != NULL) { delete g_trade;   g_trade   = NULL; }
   if(g_logger  != NULL) { delete g_logger;  g_logger  = NULL; }
}
