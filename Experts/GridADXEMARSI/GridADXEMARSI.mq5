//+------------------------------------------------------------------+
//| GridADXEMARSI.mq5                                                 |
//| GridADXEMARSI EA                                                  |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-14                                               |
//+------------------------------------------------------------------+
#property strict
#property copyright "GridADXEMARSI EA"
#property description "Grid trading EA with ADX + EMA + RSI trend filter, martingale recovery and trailing stop."
#property version "1.00"

#include "Logger.mqh"
#include "TrendFilter.mqh"
#include "RiskManager.mqh"
#include "GridManager.mqh"
#include "RecoveryManager.mqh"
#include "TrailingManager.mqh"

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+

// === Trend Filter ===
input int    InpAdxPeriod          = 14;     // ADX period
input double InpAdxThreshold       = 25.0;   // ADX trend threshold
input int    InpEmaPeriod          = 200;    // EMA period
input int    InpRsiPeriod          = 14;     // RSI period

// === Grid ===
input double InpBaseLot            = 0.01;   // Base lot size
input double InpGridDistance       = 100.0;  // Grid distance (points)
input int    InpMaxGridOrders      = 5;      // Max grid layers
input double InpProfitTarget       = 50.0;   // Profit target to activate trailing (USD)

// === Recovery (Martingale) ===
input double InpRecoveryDistance   = 100.0;  // Recovery trigger distance (points)
input double InpRecoveryMultiplier = 2.0;    // Lot multiplier per recovery layer
input int    InpMaxRecoveryOrders  = 5;      // Max recovery layers

// === Trailing Stop ===
input double InpTrailDistance      = 50.0;   // Trail distance from price (points)
input double InpTrailStep          = 10.0;   // Minimum SL improvement to trigger update (points)

// === Risk ===
input double InpMaxDrawdownPct     = 20.0;   // Max drawdown % before emergency stop
input long   InpMagicNumber        = 20240101; // EA magic number
input int    InpMaxSpreadPoints    = 50;     // Max allowed spread (points)
input bool   InpEmergencyStop      = false;  // Close all & halt immediately
input bool   InpEmergencyReset     = false;  // Reset from EMERGENCY -> IDLE
input bool   InpVerboseLog         = true;   // Enable verbose/debug logging

//+------------------------------------------------------------------+
//| State Machine                                                     |
//+------------------------------------------------------------------+
enum ENUM_EA_STATE
{
   STATE_IDLE         = 0,
   STATE_GRID_RUNNING = 1,
   STATE_RECOVERY     = 2,
   STATE_TRAILING     = 3,
   STATE_EMERGENCY    = 4
};

//+------------------------------------------------------------------+
//| Module instances                                                  |
//+------------------------------------------------------------------+
CLogger          g_logger;
CTrendFilter     g_trend;
CRiskManager     g_risk;
CGridManager     g_grid;
CRecoveryManager g_recovery;
CTrailingManager g_trailer;

ENUM_EA_STATE    g_state = STATE_IDLE;

//+------------------------------------------------------------------+
//| Helper: human-readable state name                                 |
//+------------------------------------------------------------------+
string StateName(ENUM_EA_STATE state)
{
   switch(state)
   {
      case STATE_IDLE:         return "IDLE";
      case STATE_GRID_RUNNING: return "GRID_RUNNING";
      case STATE_RECOVERY:     return "RECOVERY";
      case STATE_TRAILING:     return "TRAILING";
      case STATE_EMERGENCY:    return "EMERGENCY";
      default:                 return "UNKNOWN";
   }
}

//+------------------------------------------------------------------+
//| Helper: transition the state machine and log the change          |
//+------------------------------------------------------------------+
void ChangeState(ENUM_EA_STATE new_state)
{
   if(new_state == g_state) return;
   g_logger.StateChange(StateName(g_state), StateName(new_state));
   g_state = new_state;
}

//+------------------------------------------------------------------+
//| Helper: reset all sub-managers and return to IDLE                |
//+------------------------------------------------------------------+
void ResetAll()
{
   g_grid.Reset();
   g_recovery.Reset();
   g_trailer.Reset();
}

//+------------------------------------------------------------------+
//| Helper: stop-loss distance in points for grid orders             |
//  Hard stop = grid_distance * max_grid_orders points from entry.   |
//+------------------------------------------------------------------+
double GridSLPoints()
{
   return InpGridDistance * InpMaxGridOrders;
}

//+------------------------------------------------------------------+
//| Helper: stop-loss distance in points for recovery orders         |
//+------------------------------------------------------------------+
double RecoverySLPoints()
{
   return InpRecoveryDistance * InpMaxRecoveryOrders;
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_logger.Init("GADX", InpVerboseLog);
   g_logger.Info("OnInit: GridADXEMARSI starting...");

   // Validate inputs
   if(InpBaseLot <= 0.0)
   {
      g_logger.Error("OnInit: InpBaseLot must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpGridDistance <= 0.0)
   {
      g_logger.Error("OnInit: InpGridDistance must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMaxGridOrders < 1)
   {
      g_logger.Error("OnInit: InpMaxGridOrders must be >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMaxDrawdownPct <= 0.0 || InpMaxDrawdownPct > 100.0)
   {
      g_logger.Error("OnInit: InpMaxDrawdownPct must be in (0, 100]");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Initialise trend filter
   if(!g_trend.Init(InpAdxPeriod, InpAdxThreshold, InpEmaPeriod, InpRsiPeriod,
                    _Symbol, PERIOD_CURRENT))
   {
      g_logger.Error("OnInit: TrendFilter.Init failed");
      return INIT_FAILED;
   }

   // Initialise risk manager
   if(!g_risk.Init(InpMaxDrawdownPct, _Symbol, InpMagicNumber))
   {
      g_logger.Error("OnInit: RiskManager.Init failed");
      return INIT_FAILED;
   }

   // Initialise grid manager
   if(!g_grid.Init(InpGridDistance, InpMaxGridOrders, InpBaseLot,
                   InpMagicNumber, _Symbol))
   {
      g_logger.Error("OnInit: GridManager.Init failed");
      return INIT_FAILED;
   }

   // Initialise recovery manager (shares pointer to grid manager)
   if(!g_recovery.Init(InpRecoveryDistance, InpRecoveryMultiplier,
                       InpMaxRecoveryOrders, InpMagicNumber, _Symbol, &g_grid))
   {
      g_logger.Error("OnInit: RecoveryManager.Init failed");
      return INIT_FAILED;
   }

   // Initialise trailing manager
   if(!g_trailer.Init(InpTrailDistance, InpTrailStep, InpMagicNumber, _Symbol))
   {
      g_logger.Error("OnInit: TrailingManager.Init failed");
      return INIT_FAILED;
   }

   g_state = STATE_IDLE;
   g_logger.Info(StringFormat("OnInit: OK  symbol=%s  magic=%I64d  state=IDLE",
                              _Symbol, InpMagicNumber));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   g_trend.Deinit();
   g_logger.Info(StringFormat("OnDeinit: reason=%d", reason));
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // ----------------------------------------------------------------
   // Step 1 — emergency stop override (input flag from user)
   // ----------------------------------------------------------------
   if(InpEmergencyStop)
   {
      if(g_state != STATE_EMERGENCY)
      {
         g_logger.Warn("OnTick: InpEmergencyStop=true — closing all positions");
         g_grid.CloseAll("emergency stop input");
         ResetAll();
         ChangeState(STATE_EMERGENCY);
      }
      return;
   }

   // ----------------------------------------------------------------
   // Step 2 — update peak equity tracker
   // ----------------------------------------------------------------
   g_risk.UpdatePeakEquity();

   // ----------------------------------------------------------------
   // Step 3 — automatic drawdown breach
   // ----------------------------------------------------------------
   if(g_risk.IsDrawdownBreached())
   {
      if(g_state != STATE_EMERGENCY)
      {
         g_logger.Warn(StringFormat("OnTick: drawdown breach %.2f%% >= %.2f%% — emergency stop",
                                    g_risk.GetCurrentDrawdownPct(),
                                    InpMaxDrawdownPct));
         g_grid.CloseAll("drawdown breach");
         ResetAll();
         ChangeState(STATE_EMERGENCY);
      }
      return;
   }

   // ----------------------------------------------------------------
   // Step 4 — handle EMERGENCY state
   // ----------------------------------------------------------------
   if(g_state == STATE_EMERGENCY)
   {
      if(InpEmergencyReset)
      {
         g_logger.Info("OnTick: InpEmergencyReset=true — returning to IDLE");
         ResetAll();
         ChangeState(STATE_IDLE);
      }
      return;
   }

   // ----------------------------------------------------------------
   // Step 5 — connectivity and trade context checks
   // ----------------------------------------------------------------
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      g_logger.Debug("OnTick: terminal not connected — skipping");
      return;
   }
   if(IsTradeContextBusy())
   {
      g_logger.Debug("OnTick: trade context busy — skipping");
      return;
   }

   // ----------------------------------------------------------------
   // Step 6 — spread check
   // ----------------------------------------------------------------
   if(!g_risk.IsSymbolTradable(InpMaxSpreadPoints))
   {
      g_logger.Debug(StringFormat("OnTick: symbol not tradable (spread=%I64d pts)",
                                  SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)));
      return;
   }

   // ----------------------------------------------------------------
   // Step 7 — refresh indicator cache
   // ----------------------------------------------------------------
   if(!g_trend.Update())
   {
      g_logger.Debug("OnTick: trend.Update() returned false — skipping");
      return;
   }

   // ----------------------------------------------------------------
   // Step 8 — sync in-memory order records with live server positions
   // ----------------------------------------------------------------
   g_grid.SyncWithServer();

   // ----------------------------------------------------------------
   // Step 9 — state machine
   // ----------------------------------------------------------------
   switch(g_state)
   {
      //--------------------------------------------------------------
      case STATE_IDLE:
      {
         if(g_trend.HasTrend() && !g_grid.HasActiveOrders())
         {
            ENUM_ORDER_TYPE dir = g_trend.GetTrendDirection();
            double sl_pts       = GridSLPoints();

            if(g_grid.OpenBaseOrder(dir, InpBaseLot, sl_pts))
            {
               g_logger.Info(StringFormat("IDLE: base order opened  dir=%s  ADX=%.2f  EMA=%.5f  RSI=%.2f",
                                          EnumToString(dir),
                                          g_trend.GetADX(),
                                          g_trend.GetEMA(),
                                          g_trend.GetRSI()));
               ChangeState(STATE_GRID_RUNNING);
            }
         }
         break;
      }

      //--------------------------------------------------------------
      case STATE_GRID_RUNNING:
      {
         // --- Profit target reached → activate trailing and transition
         if(g_grid.GetTotalProfit() >= InpProfitTarget)
         {
            g_logger.Info(StringFormat("GRID_RUNNING: profit target reached (%.2f >= %.2f) — activating trail",
                                       g_grid.GetTotalProfit(), InpProfitTarget));
            g_trailer.Activate();
            ChangeState(STATE_TRAILING);
            break;
         }

         // --- Trend has reversed → open first recovery order
         bool trend_reversed = g_trend.HasTrend() &&
                               (g_trend.GetTrendDirection() != g_grid.GetGridDirection());

         if(trend_reversed && g_recovery.IsRecoveryNeeded() && g_recovery.CanRecover())
         {
            g_logger.Info("GRID_RUNNING: trend reversed + price distance met — opening recovery order");
            g_recovery.OpenRecoveryOrder(InpBaseLot, RecoverySLPoints());
            ChangeState(STATE_RECOVERY);
            break;
         }

         // --- Trend continues → expand grid if distance condition met
         bool trend_same = !g_trend.HasTrend() ||
                           (g_trend.GetTrendDirection() == g_grid.GetGridDirection());

         if(trend_same && g_grid.ShouldExpandGrid() && !g_grid.IsGridFull())
         {
            g_logger.Info(StringFormat("GRID_RUNNING: expanding grid  count=%d/%d",
                                       g_grid.GetOrderCount(), InpMaxGridOrders));
            g_grid.ExpandGrid(GridSLPoints());
         }
         break;
      }

      //--------------------------------------------------------------
      case STATE_RECOVERY:
      {
         // --- Profit target reached → activate trailing
         if(g_grid.GetTotalProfit() >= InpProfitTarget)
         {
            g_logger.Info(StringFormat("RECOVERY: profit target reached (%.2f >= %.2f) — activating trail",
                                       g_grid.GetTotalProfit(), InpProfitTarget));
            g_trailer.Activate();
            ChangeState(STATE_TRAILING);
            break;
         }

         // --- Price continued against us → open another recovery layer
         if(g_recovery.ShouldContinueRecovery() && g_recovery.CanRecover())
         {
            g_logger.Info(StringFormat("RECOVERY: continuing recovery  layer=%d/%d",
                                       g_recovery.GetRecoveryCount(), InpMaxRecoveryOrders));
            g_recovery.OpenRecoveryOrder(InpBaseLot, RecoverySLPoints());
            break;
         }

         // --- Recovery exhausted and still losing → close all and reset
         if(!g_recovery.CanRecover() && g_grid.GetTotalProfit() < 0.0)
         {
            g_logger.Warn(StringFormat("RECOVERY: max recovery exhausted and profit %.2f < 0 — closing all",
                                       g_grid.GetTotalProfit()));
            g_grid.CloseAll("max recovery exhausted");
            ResetAll();
            ChangeState(STATE_IDLE);
         }
         break;
      }

      //--------------------------------------------------------------
      case STATE_TRAILING:
      {
         g_trailer.UpdateTrails(&g_grid);

         // Check whether all positions have been closed (hit SL or TP)
         if(!g_grid.HasActiveOrders())
         {
            g_logger.Info("TRAILING: all positions closed — resetting to IDLE");
            ResetAll();
            ChangeState(STATE_IDLE);
         }
         break;
      }

      //--------------------------------------------------------------
      case STATE_EMERGENCY:
      {
         // Already handled above; should not reach here
         break;
      }
   } // end switch

   // ----------------------------------------------------------------
   // Step 10 — dashboard (every tick)
   // ----------------------------------------------------------------
   g_logger.PrintDashboard((int)g_state,
                            g_grid.GetOrderCount(),
                            g_recovery.GetRecoveryCount(),
                            g_grid.GetTotalProfit(),
                            g_risk.GetCurrentDrawdownPct());
}
