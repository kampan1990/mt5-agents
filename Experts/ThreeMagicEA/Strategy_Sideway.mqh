//+------------------------------------------------------------------+
//|                                             Strategy_Sideway.mqh |
//|   Magic 2 (2222) - Range trading with Bollinger + RSI grid,      |
//|   basket TP/stop and a breakout guard that flattens & pauses.    |
//+------------------------------------------------------------------+
#ifndef THREEMAGIC_STRATEGY_SIDEWAY_MQH
#define THREEMAGIC_STRATEGY_SIDEWAY_MQH
#property strict

#include "Utils.mqh"
#include "Logger.mqh"
#include "RiskManager.mqh"
#include "TradeManager.mqh"

enum ENUM_SW_STATE
  {
   SW_IDLE   = 0,   // flat, hunting for a range signal
   SW_ACTIVE = 1,   // grid live, managing basket
   SW_PAUSED = 2    // breakout detected, cooling down
  };

struct SidewayConfig
  {
   long              magic;
   ENUM_TIMEFRAMES   tf;
   int               bbPeriod;
   double            bbDeviation;
   int               rsiPeriod;
   double            rsiOverbought;
   double            rsiOversold;
   int               adxPeriod;
   double            adxSidewayMax;   // ADX below this => ranging
   double            adxBreakout;     // ADX at/above this => breakout guard fires
   double            bbWidthMaxPct;   // (upper-lower)/mid *100 must be below this to trade
   int               gridOrders;
   int               gridStepPoints;
   int               breakoutBufferPts;
   int               cooldownBars;
   double            lots;
   double            basketTP;
   double            basketSL;
  };

//+------------------------------------------------------------------+
//| CStrategySideway                                                |
//+------------------------------------------------------------------+
class CStrategySideway
  {
private:
   SidewayConfig     m_cfg;
   CUtils           *m_utils;
   CLogger          *m_log;
   CRiskManager     *m_risk;
   CTradeManager    *m_trade;

   ENUM_SW_STATE     m_state;
   datetime          m_lastBar;
   int               m_cooldownLeft;
   int               m_bbHandle;
   int               m_rsiHandle;
   int               m_adxHandle;
   bool              m_enabled;

   bool              ReadIndicators(double &upper,double &lower,double &mid,
                                    double &rsi,double &adx)
     {
      double bU[],bL[],bM[],r[],a[];
      if(CopyBuffer(m_bbHandle,1,1,1,bU)<1) return false; // upper
      if(CopyBuffer(m_bbHandle,2,1,1,bL)<1) return false; // lower
      if(CopyBuffer(m_bbHandle,0,1,1,bM)<1) return false; // base/mid
      if(CopyBuffer(m_rsiHandle,0,1,1,r)<1) return false;
      if(CopyBuffer(m_adxHandle,0,1,1,a)<1) return false; // main ADX line
      upper=bU[0]; lower=bL[0]; mid=bM[0]; rsi=r[0]; adx=a[0];
      return true;
     }

   void              PlaceGrid(ENUM_SIDE side)
     {
      double center=(side==SIDE_SELL ? m_utils.Bid() : m_utils.Ask());
      double step  =m_utils.PointsToPrice(m_cfg.gridStepPoints);
      string cmt   =StringFormat("M2-%s",(side==SIDE_SELL?"SELL":"BUY"));
      for(int i=0;i<m_cfg.gridOrders;i++)
        {
         if(side==SIDE_SELL)
            m_trade.PlacePending(m_cfg.magic,ORDER_TYPE_SELL_LIMIT,center+(i+1)*step,m_cfg.lots,0,0,cmt);
         else
            m_trade.PlacePending(m_cfg.magic,ORDER_TYPE_BUY_LIMIT ,center-(i+1)*step,m_cfg.lots,0,0,cmt);
        }
      m_state=SW_ACTIVE;
      m_log.Info("M2",StringFormat("RANGE grid %s x%d @ %.5f",
                 (side==SIDE_SELL?"SELL":"BUY"),m_cfg.gridOrders,center));
     }

   void              Flatten(const string reason)
     {
      m_trade.CloseGroup(m_cfg.magic);
      m_log.Info("M2",StringFormat("GROUP closed (%s)",reason));
     }

public:
                     CStrategySideway(void)
     {
      m_utils=NULL; m_log=NULL; m_risk=NULL; m_trade=NULL;
      m_state=SW_IDLE; m_lastBar=0; m_cooldownLeft=0; m_enabled=true;
      m_bbHandle=INVALID_HANDLE; m_rsiHandle=INVALID_HANDLE; m_adxHandle=INVALID_HANDLE;
     }

   //--- runtime control + reporting (dashboard)
   void              SetEnabled(bool e){ m_enabled=e; }
   bool              IsEnabled(void) const { return m_enabled; }
   string            Name(void) const { return "M2 Sideway"; }

   void              CloseAllTrades(void)
     {
      m_trade.CloseGroup(m_cfg.magic);
      m_state=SW_IDLE; m_cooldownLeft=0;
      m_log.Info("M2","Closed by dashboard");
     }

   void              GetStatus(MagicStatus &s)
     {
      s.magic    =m_cfg.magic;
      s.name     ="M2 Range";
      s.enabled  =m_enabled;
      s.state    =(m_state==SW_IDLE?"IDLE":(m_state==SW_ACTIVE?"ACTIVE":"PAUSED"));
      s.side     =m_trade.NetSide(m_cfg.magic);
      s.positions=m_trade.CountPositions(m_cfg.magic);
      s.pending  =m_trade.CountPending(m_cfg.magic);
      s.pl       =m_risk.BasketProfit(m_cfg.magic);
      s.plPts    =m_risk.BasketProfitPoints(m_cfg.magic);
      s.info     =StringFormat("TP $%.0f/SL $%.0f cd %d",
                               m_cfg.basketTP,m_cfg.basketSL,m_cooldownLeft);
     }

   bool              Init(SidewayConfig &cfg,CUtils *utils,CLogger *log,
                          CRiskManager *risk,CTradeManager *trade)
     {
      m_cfg=cfg; m_utils=utils; m_log=log; m_risk=risk; m_trade=trade;
      m_bbHandle =iBands(m_utils.Symbol(),m_cfg.tf,m_cfg.bbPeriod,0,m_cfg.bbDeviation,PRICE_CLOSE);
      m_rsiHandle=iRSI  (m_utils.Symbol(),m_cfg.tf,m_cfg.rsiPeriod,PRICE_CLOSE);
      m_adxHandle=iADX  (m_utils.Symbol(),m_cfg.tf,m_cfg.adxPeriod);
      if(m_bbHandle==INVALID_HANDLE || m_rsiHandle==INVALID_HANDLE || m_adxHandle==INVALID_HANDLE)
        {
         m_log.Error("M2","Failed to create BB/RSI/ADX indicator handles");
         return false;
        }
      if(m_trade.CountPositions(m_cfg.magic)>0)
         m_state=SW_ACTIVE;
      return true;
     }

   void              Deinit(void)
     {
      if(m_bbHandle!=INVALID_HANDLE)  IndicatorRelease(m_bbHandle);
      if(m_rsiHandle!=INVALID_HANDLE) IndicatorRelease(m_rsiHandle);
      if(m_adxHandle!=INVALID_HANDLE) IndicatorRelease(m_adxHandle);
     }

   long              Magic(void) const { return m_cfg.magic; }

   void              OnTick(void)
     {
      bool newBar=m_utils.IsNewBar(m_cfg.tf,m_lastBar);

      // --- basket management every tick while active
      if(m_state==SW_ACTIVE)
        {
         if(m_trade.CountPositions(m_cfg.magic)==0 && m_trade.CountPending(m_cfg.magic)==0)
           {
            m_state=SW_IDLE;
           }
         else
           {
            double pl=m_risk.BasketProfit(m_cfg.magic);
            if(m_cfg.basketTP>0.0 && pl>=m_cfg.basketTP){ Flatten(StringFormat("basket TP +%.2f",pl)); m_state=SW_IDLE; return; }
            if(m_cfg.basketSL>0.0 && pl<=-m_cfg.basketSL){ Flatten(StringFormat("basket STOP %.2f",pl)); m_state=SW_IDLE; return; }
           }
        }

      if(!newBar)
         return;

      double upper,lower,mid,rsi,adx;
      if(!ReadIndicators(upper,lower,mid,rsi,adx))
         return;

      double close=iClose(m_utils.Symbol(),m_cfg.tf,1);
      double widthPct=(mid>0.0 ? (upper-lower)/mid*100.0 : 999.0);
      double buf=m_utils.PointsToPrice(m_cfg.breakoutBufferPts);

      // --- breakout guard (highest priority when active)
      if(m_state==SW_ACTIVE)
        {
         bool brokeOut=(adx>=m_cfg.adxBreakout) ||
                       (close>upper+buf) || (close<lower-buf);
         if(brokeOut)
           {
            Flatten(StringFormat("BREAKOUT guard (ADX=%.1f close=%.5f)",adx,close));
            m_state=SW_PAUSED;
            m_cooldownLeft=m_cfg.cooldownBars;
            return;
           }
        }

      // --- cooldown after breakout
      if(m_state==SW_PAUSED)
        {
         if(m_cooldownLeft>0) m_cooldownLeft--;
         bool regimeBack=(adx<m_cfg.adxSidewayMax && widthPct<=m_cfg.bbWidthMaxPct);
         if(m_cooldownLeft<=0 && regimeBack)
           {
            m_state=SW_IDLE;
            m_log.Info("M2","Cooldown finished, range regime restored");
           }
         return;
        }

      // --- look for a new range entry
      if(m_state==SW_IDLE && m_enabled)
        {
         bool ranging=(adx<m_cfg.adxSidewayMax && widthPct<=m_cfg.bbWidthMaxPct);
         if(!ranging)
            return;
         if(close>=upper && rsi>=m_cfg.rsiOverbought)
            PlaceGrid(SIDE_SELL);
         else if(close<=lower && rsi<=m_cfg.rsiOversold)
            PlaceGrid(SIDE_BUY);
        }
     }
  };
//+------------------------------------------------------------------+
#endif // THREEMAGIC_STRATEGY_SIDEWAY_MQH
