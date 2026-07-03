//+------------------------------------------------------------------+
//|                                                  ThreeMagicEA.mq5 |
//|   Multi-strategy EA running three independent magic numbers:     |
//|     Magic 1 (1111) Engulfing grid + flip/recovery                |
//|     Magic 2 (2222) Sideway BB+RSI grid + breakout guard          |
//|     Magic 3 (3333) Trend EMA-pullback ladder + runner trailing   |
//+------------------------------------------------------------------+
#property copyright "ThreeMagicEA"
#property version   "1.00"
#property strict

#include "Logger.mqh"
#include "Utils.mqh"
#include "RiskManager.mqh"
#include "TradeManager.mqh"
#include "Strategy_Engulfing.mqh"
#include "Strategy_Sideway.mqh"
#include "Strategy_Trend.mqh"

//==================================================================
//  GLOBAL / RISK INPUTS
//==================================================================
input group "===== GLOBAL / RISK ====="
input int    InpSlippagePoints      = 30;      // Max slippage (points)
input double InpMaxAccountDDPct      = 20.0;    // Account drawdown hard stop (%)
input bool   InpCloseAllOnHalt       = true;    // Flatten everything when halted
input bool   InpLogToFile            = false;   // Also write log to file
input ENUM_LOG_LEVEL InpLogLevel     = LOG_INFO;// Minimum log level

//==================================================================
//  MAGIC 1 - ENGULFING
//==================================================================
input group "===== MAGIC 1: ENGULFING ====="
input bool   InpM1_Enable            = true;
input ENUM_TIMEFRAMES InpM1_TF       = PERIOD_M15;  // Engulfing timeframe
input double InpM1_RetracePercent    = 30.0;   // Retrace % of candle-2 range before entry
input int    InpM1_GridStepPoints    = 150;    // Grid spacing (points)
input int    InpM1_OrdersPerSide     = 5;      // Pending orders per side (limit & stop)
input double InpM1_Lots              = 0.01;   // Base lot per order
input double InpM1_BasketTP          = 50.0;   // Basket take profit (account currency)
input double InpM1_BasketSL          = 300.0;  // Basket hard stop (account currency)
input double InpM1_FlipMaxLoss       = 30.0;   // Flip allowed only while loss <= this ($)
input double InpM1_RecoveryTrigger   = 40.0;   // Start recovery when loss >= this ($)
input double InpM1_RecoveryStep      = 40.0;   // Extra loss between recovery adds ($)
input int    InpM1_RecoveryMaxAdds   = 5;      // Max recovery orders
input double InpM1_RecoveryLotMult   = 1.5;    // Lot multiplier per recovery add

//==================================================================
//  MAGIC 2 - SIDEWAY
//==================================================================
input group "===== MAGIC 2: SIDEWAY ====="
input bool   InpM2_Enable            = true;
input ENUM_TIMEFRAMES InpM2_TF       = PERIOD_M15;
input int    InpM2_BBPeriod          = 20;
input double InpM2_BBDeviation       = 2.0;
input int    InpM2_RSIPeriod         = 14;
input double InpM2_RSIOverbought     = 70.0;
input double InpM2_RSIOversold       = 30.0;
input int    InpM2_ADXPeriod         = 14;
input double InpM2_ADXSidewayMax     = 22.0;   // ADX below this = ranging
input double InpM2_ADXBreakout       = 30.0;   // ADX above this = breakout guard
input double InpM2_BBWidthMaxPct     = 1.5;    // Max BB width (% of price) to trade
input int    InpM2_GridOrders        = 5;
input int    InpM2_GridStepPoints    = 120;
input int    InpM2_BreakoutBufferPts = 100;    // Price beyond band = breakout
input int    InpM2_CooldownBars      = 5;      // Bars to pause after breakout
input double InpM2_Lots              = 0.01;
input double InpM2_BasketTP          = 40.0;
input double InpM2_BasketSL          = 250.0;

//==================================================================
//  MAGIC 3 - TREND
//==================================================================
input group "===== MAGIC 3: TREND ====="
input bool   InpM3_Enable            = true;
input ENUM_TIMEFRAMES InpM3_TF       = PERIOD_M15;
input int    InpM3_EMAFast           = 20;
input int    InpM3_EMASlow           = 50;
input int    InpM3_ADXPeriod         = 14;
input double InpM3_ADXTrendMin       = 25.0;   // ADX above this = trending
input int    InpM3_ATRPeriod         = 14;
input int    InpM3_OrdersPerSide     = 5;      // Limits below + stops above (trend side)
input int    InpM3_GridStepPoints    = 150;
input double InpM3_Lots              = 0.01;
input double InpM3_SLAtrMult         = 1.5;    // Per-order SL = ATR * this
input double InpM3_RunnerTP          = 1500;   // Runner TP (points)
input int    InpM3_KeepRunnerCount   = 2;      // Best-priced tickets kept as runners
input double InpM3_PartialTrigPts    = 300;    // Group profit (points) to trigger partial
input double InpM3_TrailAtrMult      = 2.0;    // Runner trailing distance = ATR * this
input int    InpM3_MaxPositions      = 8;      // Pyramiding cap

//==================================================================
//  GLOBAL OBJECTS
//==================================================================
CLogger            g_log;
CUtils             g_utils;
CRiskManager       g_risk;
CTradeManager      g_trade;
CStrategyEngulfing g_m1;
CStrategySideway   g_m2;
CStrategyTrend     g_m3;
bool               g_haltHandled=false;

//+------------------------------------------------------------------+
//| Build config structs from inputs                                 |
//+------------------------------------------------------------------+
void BuildM1(EngulfingConfig &c)
  {
   c.magic          =1111;
   c.tf             =InpM1_TF;
   c.retracePercent =InpM1_RetracePercent;
   c.gridStepPoints =InpM1_GridStepPoints;
   c.ordersPerSide  =InpM1_OrdersPerSide;
   c.lots           =InpM1_Lots;
   c.basketTP       =InpM1_BasketTP;
   c.basketSL       =InpM1_BasketSL;
   c.flipMaxLoss    =InpM1_FlipMaxLoss;
   c.recoveryTrigger=InpM1_RecoveryTrigger;
   c.recoveryStep   =InpM1_RecoveryStep;
   c.recoveryMaxAdds=InpM1_RecoveryMaxAdds;
   c.recoveryLotMult=InpM1_RecoveryLotMult;
  }

void BuildM2(SidewayConfig &c)
  {
   c.magic           =2222;
   c.tf              =InpM2_TF;
   c.bbPeriod        =InpM2_BBPeriod;
   c.bbDeviation     =InpM2_BBDeviation;
   c.rsiPeriod       =InpM2_RSIPeriod;
   c.rsiOverbought   =InpM2_RSIOverbought;
   c.rsiOversold     =InpM2_RSIOversold;
   c.adxPeriod       =InpM2_ADXPeriod;
   c.adxSidewayMax   =InpM2_ADXSidewayMax;
   c.adxBreakout     =InpM2_ADXBreakout;
   c.bbWidthMaxPct   =InpM2_BBWidthMaxPct;
   c.gridOrders      =InpM2_GridOrders;
   c.gridStepPoints  =InpM2_GridStepPoints;
   c.breakoutBufferPts=InpM2_BreakoutBufferPts;
   c.cooldownBars    =InpM2_CooldownBars;
   c.lots            =InpM2_Lots;
   c.basketTP        =InpM2_BasketTP;
   c.basketSL        =InpM2_BasketSL;
  }

void BuildM3(TrendConfig &c)
  {
   c.magic          =3333;
   c.tf             =InpM3_TF;
   c.emaFast        =InpM3_EMAFast;
   c.emaSlow        =InpM3_EMASlow;
   c.adxPeriod      =InpM3_ADXPeriod;
   c.adxTrendMin    =InpM3_ADXTrendMin;
   c.atrPeriod      =InpM3_ATRPeriod;
   c.ordersPerSide  =InpM3_OrdersPerSide;
   c.gridStepPoints =InpM3_GridStepPoints;
   c.lots           =InpM3_Lots;
   c.slAtrMult      =InpM3_SLAtrMult;
   c.runnerTP       =InpM3_RunnerTP;
   c.keepRunnerCount=InpM3_KeepRunnerCount;
   c.partialTrigPts =InpM3_PartialTrigPts;
   c.trailAtrMult   =InpM3_TrailAtrMult;
   c.maxPositions   =InpM3_MaxPositions;
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_log.Init(InpLogLevel,InpLogToFile);
   g_utils.Init(_Symbol);
   g_risk.Init(&g_utils,&g_log,InpMaxAccountDDPct);
   g_trade.Init(&g_utils,&g_log,InpSlippagePoints);

   if(InpM1_Enable)
     {
      EngulfingConfig c1; BuildM1(c1);
      g_m1.Init(c1,&g_utils,&g_log,&g_risk,&g_trade);
     }
   if(InpM2_Enable)
     {
      SidewayConfig c2; BuildM2(c2);
      if(!g_m2.Init(c2,&g_utils,&g_log,&g_risk,&g_trade))
         return INIT_FAILED;
     }
   if(InpM3_Enable)
     {
      TrendConfig c3; BuildM3(c3);
      if(!g_m3.Init(c3,&g_utils,&g_log,&g_risk,&g_trade))
         return INIT_FAILED;
     }

   g_log.Info("INIT",StringFormat("ThreeMagicEA started on %s | M1=%s M2=%s M3=%s",
              _Symbol,
              (InpM1_Enable?"on":"off"),
              (InpM2_Enable?"on":"off"),
              (InpM3_Enable?"on":"off")));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(InpM2_Enable) g_m2.Deinit();
   if(InpM3_Enable) g_m3.Deinit();
   g_log.Info("DEINIT",StringFormat("ThreeMagicEA stopped (reason=%d)",reason));
  }

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
  {
   // account-level protection first
   if(g_risk.CheckAccountDrawdown() && !g_haltHandled)
     {
      g_haltHandled=true;
      if(InpCloseAllOnHalt)
        {
         g_trade.CloseGroup(1111);
         g_trade.CloseGroup(2222);
         g_trade.CloseGroup(3333);
         g_log.Error("RISK","All groups flattened due to account drawdown halt");
        }
     }
   if(g_risk.IsHalted())
      return;

   if(InpM1_Enable) g_m1.OnTick();
   if(InpM2_Enable) g_m2.OnTick();
   if(InpM3_Enable) g_m3.OnTick();
  }
//+------------------------------------------------------------------+
