//+------------------------------------------------------------------+
//|                                               Strategy_Trend.mqh |
//|   Magic 3 (3333) - EMA pullback, same-direction pending ladder,  |
//|   per-order ATR stop, partial TP keeping the best-priced runners |
//|   with a separate runner TP and ATR trailing stop.               |
//+------------------------------------------------------------------+
#ifndef THREEMAGIC_STRATEGY_TREND_MQH
#define THREEMAGIC_STRATEGY_TREND_MQH
#property strict

#include "Utils.mqh"
#include "Logger.mqh"
#include "RiskManager.mqh"
#include "TradeManager.mqh"

enum ENUM_TR_STATE
  {
   TR_FLAT   = 0,   // no ladder, waiting for pullback signal
   TR_WORKING= 1    // ladder placed / positions live
  };

struct TrendConfig
  {
   long              magic;
   ENUM_TIMEFRAMES   tf;
   int               emaFast;
   int               emaSlow;
   int               adxPeriod;
   double            adxTrendMin;     // ADX must exceed this to call it a trend
   int               atrPeriod;
   int               ordersPerSide;   // limits below + stops above (trend side)
   int               gridStepPoints;
   double            lots;
   double            slAtrMult;       // per-order SL = ATR * this
   double            runnerTP;        // TP (points) for kept runners
   int               keepRunnerCount; // how many best-priced tickets to keep
   double            partialTrigPts;  // group profit (points) that triggers partial reduce
   double            trailAtrMult;    // trailing stop distance = ATR * this
   int               maxPositions;    // pyramiding cap
  };

//+------------------------------------------------------------------+
//| CStrategyTrend                                                  |
//+------------------------------------------------------------------+
class CStrategyTrend
  {
private:
   TrendConfig       m_cfg;
   CUtils           *m_utils;
   CLogger          *m_log;
   CRiskManager     *m_risk;
   CTradeManager    *m_trade;

   ENUM_TR_STATE     m_state;
   datetime          m_lastBar;
   ENUM_SIDE         m_side;
   bool              m_partialDone;
   bool              m_enabled;
   int               m_emaFastH;
   int               m_emaSlowH;
   int               m_adxH;
   int               m_atrH;

   bool              ReadIndicators(double &emaF,double &emaS,double &adx,double &atr)
     {
      double f[],s[],a[],t[];
      if(CopyBuffer(m_emaFastH,0,1,1,f)<1) return false;
      if(CopyBuffer(m_emaSlowH,0,1,1,s)<1) return false;
      if(CopyBuffer(m_adxH,0,1,1,a)<1)     return false;
      if(CopyBuffer(m_atrH,0,1,1,t)<1)     return false;
      emaF=f[0]; emaS=s[0]; adx=a[0]; atr=t[0];
      return true;
     }

   //--- pullback: last bar dipped to fast EMA and closed back in trend direction
   ENUM_SIDE         DetectSignal(double emaF,double emaS,double adx)
     {
      if(adx<m_cfg.adxTrendMin)
         return SIDE_NONE;
      double hi=iHigh (m_utils.Symbol(),m_cfg.tf,1);
      double lo=iLow  (m_utils.Symbol(),m_cfg.tf,1);
      double cl=iClose(m_utils.Symbol(),m_cfg.tf,1);
      if(emaF>emaS && lo<=emaF && cl>emaF) return SIDE_BUY;   // uptrend pullback
      if(emaF<emaS && hi>=emaF && cl<emaF) return SIDE_SELL;  // downtrend pullback
      return SIDE_NONE;
     }

   void              PlaceLadder(ENUM_SIDE side,double atr)
     {
      double center=(side==SIDE_BUY ? m_utils.Ask() : m_utils.Bid());
      double step  =m_utils.PointsToPrice(m_cfg.gridStepPoints);
      double slDist=atr*m_cfg.slAtrMult;
      double tpDist=m_utils.PointsToPrice(m_cfg.runnerTP);
      string cmt   =StringFormat("M3-%s",(side==SIDE_BUY?"BUY":"SELL"));

      for(int i=1;i<=m_cfg.ordersPerSide;i++)
        {
         if(side==SIDE_BUY)
           {
            double pl=center-i*step;                 // buy limit (best price runners)
            m_trade.PlacePending(m_cfg.magic,ORDER_TYPE_BUY_LIMIT,pl,m_cfg.lots,
                                 pl-slDist,pl+tpDist,cmt);
            double ps=center+i*step;                 // buy stop (pyramiding on momentum)
            m_trade.PlacePending(m_cfg.magic,ORDER_TYPE_BUY_STOP,ps,m_cfg.lots,
                                 ps-slDist,ps+tpDist,cmt);
           }
         else
           {
            double pl=center+i*step;                 // sell limit (best price runners)
            m_trade.PlacePending(m_cfg.magic,ORDER_TYPE_SELL_LIMIT,pl,m_cfg.lots,
                                 pl+slDist,pl-tpDist,cmt);
            double ps=center-i*step;                 // sell stop (pyramiding)
            m_trade.PlacePending(m_cfg.magic,ORDER_TYPE_SELL_STOP,ps,m_cfg.lots,
                                 ps+slDist,ps-tpDist,cmt);
           }
        }
      m_side=side;
      m_partialDone=false;
      m_state=TR_WORKING;
      m_log.Info("M3",StringFormat("LADDER %s x%d/side @ %.5f (SL=ATR*%.1f)",
                 (side==SIDE_BUY?"BUY":"SELL"),m_cfg.ordersPerSide,center,m_cfg.slAtrMult));
     }

   //--- keep only the best-priced runners, close the rest
   void              ReduceToRunners(void)
     {
      PositionRec arr[];
      int n=m_trade.GetPositions(m_cfg.magic,arr);
      if(n<=m_cfg.keepRunnerCount)
        { m_partialDone=true; return; }

      // sort by openPrice ascending (simple selection sort, small n)
      for(int i=0;i<n-1;i++)
         for(int j=i+1;j<n;j++)
            if(arr[j].openPrice<arr[i].openPrice)
              {
               PositionRec tmp=arr[i]; arr[i]=arr[j]; arr[j]=tmp;
              }

      // BUY: best = lowest price -> keep first K. SELL: best = highest -> keep last K.
      int closed=0;
      for(int i=0;i<n;i++)
        {
         bool keep;
         if(m_side==SIDE_BUY)
            keep=(i<m_cfg.keepRunnerCount);
         else
            keep=(i>=n-m_cfg.keepRunnerCount);
         if(!keep)
           {
            m_trade.CloseByTicket(arr[i].ticket);
            closed++;
           }
        }
      m_partialDone=true;
      m_log.Info("M3",StringFormat("PARTIAL TP: closed %d, kept %d best-priced runners",
                 closed,m_cfg.keepRunnerCount));
     }

   //--- ATR trailing stop for the surviving runners
   void              TrailRunners(double atr)
     {
      double trail=atr*m_cfg.trailAtrMult;
      if(trail<=0.0) return;
      PositionRec arr[];
      int n=m_trade.GetPositions(m_cfg.magic,arr);
      double bid=m_utils.Bid(), ask=m_utils.Ask();
      for(int i=0;i<n;i++)
        {
         if(!PositionSelectByTicket(arr[i].ticket)) continue;
         double curSL=PositionGetDouble(POSITION_SL);
         double curTP=PositionGetDouble(POSITION_TP);
         if(arr[i].type==POSITION_TYPE_BUY)
           {
            double newSL=m_utils.Normalize(bid-trail);
            if(newSL>curSL && newSL<bid)
               m_trade.ModifyPosition(arr[i].ticket,newSL,curTP);
           }
         else
           {
            double newSL=m_utils.Normalize(ask+trail);
            if((curSL==0.0 || newSL<curSL) && newSL>ask)
               m_trade.ModifyPosition(arr[i].ticket,newSL,curTP);
           }
        }
     }

public:
                     CStrategyTrend(void)
     {
      m_utils=NULL; m_log=NULL; m_risk=NULL; m_trade=NULL;
      m_state=TR_FLAT; m_lastBar=0; m_side=SIDE_NONE; m_partialDone=false; m_enabled=true;
      m_emaFastH=INVALID_HANDLE; m_emaSlowH=INVALID_HANDLE;
      m_adxH=INVALID_HANDLE; m_atrH=INVALID_HANDLE;
     }

   //--- runtime control + reporting (dashboard)
   void              SetEnabled(bool e){ m_enabled=e; }
   bool              IsEnabled(void) const { return m_enabled; }
   string            Name(void) const { return "M3 Trend"; }

   void              CloseAllTrades(void)
     {
      m_trade.CloseGroup(m_cfg.magic);
      m_state=TR_FLAT; m_side=SIDE_NONE; m_partialDone=false;
      m_log.Info("M3","Closed by dashboard");
     }

   void              GetStatus(MagicStatus &s)
     {
      s.magic    =m_cfg.magic;
      s.name     ="M3 Trend";
      s.enabled  =m_enabled;
      s.state    =(m_state==TR_FLAT?"FLAT":"WORKING");
      s.side     =m_side;
      s.positions=m_trade.CountPositions(m_cfg.magic);
      s.pending  =m_trade.CountPending(m_cfg.magic);
      s.pl       =m_risk.BasketProfit(m_cfg.magic);
      s.plPts    =m_risk.BasketProfitPoints(m_cfg.magic);
      s.info     =StringFormat("run %d@%.0fpt partial:%s",
                               m_cfg.keepRunnerCount,m_cfg.runnerTP,(m_partialDone?"done":"wait"));
     }

   bool              Init(TrendConfig &cfg,CUtils *utils,CLogger *log,
                          CRiskManager *risk,CTradeManager *trade)
     {
      m_cfg=cfg; m_utils=utils; m_log=log; m_risk=risk; m_trade=trade;
      m_emaFastH=iMA (m_utils.Symbol(),m_cfg.tf,m_cfg.emaFast,0,MODE_EMA,PRICE_CLOSE);
      m_emaSlowH=iMA (m_utils.Symbol(),m_cfg.tf,m_cfg.emaSlow,0,MODE_EMA,PRICE_CLOSE);
      m_adxH    =iADX(m_utils.Symbol(),m_cfg.tf,m_cfg.adxPeriod);
      m_atrH    =iATR(m_utils.Symbol(),m_cfg.tf,m_cfg.atrPeriod);
      if(m_emaFastH==INVALID_HANDLE || m_emaSlowH==INVALID_HANDLE ||
         m_adxH==INVALID_HANDLE || m_atrH==INVALID_HANDLE)
        {
         m_log.Error("M3","Failed to create EMA/ADX/ATR indicator handles");
         return false;
        }
      if(m_trade.CountPositions(m_cfg.magic)>0)
        {
         m_side=m_trade.NetSide(m_cfg.magic);
         m_state=TR_WORKING;
        }
      return true;
     }

   void              Deinit(void)
     {
      if(m_emaFastH!=INVALID_HANDLE) IndicatorRelease(m_emaFastH);
      if(m_emaSlowH!=INVALID_HANDLE) IndicatorRelease(m_emaSlowH);
      if(m_adxH!=INVALID_HANDLE)     IndicatorRelease(m_adxH);
      if(m_atrH!=INVALID_HANDLE)     IndicatorRelease(m_atrH);
     }

   long              Magic(void) const { return m_cfg.magic; }

   void              OnTick(void)
     {
      double emaF,emaS,adx,atr;
      bool haveInd=ReadIndicators(emaF,emaS,adx,atr);

      // --- manage a live ladder every tick
      if(m_state==TR_WORKING)
        {
         int nPos=m_trade.CountPositions(m_cfg.magic);
         int nPend=m_trade.CountPending(m_cfg.magic);
         if(nPos==0 && nPend==0)
           {
            m_state=TR_FLAT; m_side=SIDE_NONE; m_partialDone=false;
           }
         else
           {
            // pyramiding cap: remove untouched pendings once we hold enough
            if(nPos>=m_cfg.maxPositions && nPend>0)
               m_trade.DeleteAllPending(m_cfg.magic);

            // partial reduction to best-priced runners
            if(!m_partialDone && nPos>m_cfg.keepRunnerCount)
              {
               double plPts=m_risk.BasketProfitPoints(m_cfg.magic);
               if(plPts>=m_cfg.partialTrigPts)
                  ReduceToRunners();
              }

            // trail the runners
            if(m_partialDone && haveInd)
               TrailRunners(atr);
           }
        }

      // --- hunt for a new pullback only when flat and on a fresh bar
      if(m_state==TR_FLAT && m_enabled && m_utils.IsNewBar(m_cfg.tf,m_lastBar) && haveInd)
        {
         ENUM_SIDE sig=DetectSignal(emaF,emaS,adx);
         if(sig!=SIDE_NONE)
            PlaceLadder(sig,atr);
        }
     }
  };
//+------------------------------------------------------------------+
#endif // THREEMAGIC_STRATEGY_TREND_MQH
