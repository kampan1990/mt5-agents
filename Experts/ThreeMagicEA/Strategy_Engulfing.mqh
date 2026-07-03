//+------------------------------------------------------------------+
//|                                           Strategy_Engulfing.mqh |
//|   Magic 1 (1111) - 3-bar Engulfing + retrace + grid straddle     |
//|   with basket TP/stop, opposite-signal FLIP and RECOVERY.        |
//+------------------------------------------------------------------+
#ifndef THREEMAGIC_STRATEGY_ENGULFING_MQH
#define THREEMAGIC_STRATEGY_ENGULFING_MQH
#property strict

#include "Utils.mqh"
#include "Logger.mqh"
#include "RiskManager.mqh"
#include "TradeManager.mqh"

//--- lifecycle state of the magic-1 engine
enum ENUM_ENG_STATE
  {
   ENG_IDLE   = 0,   // no signal, waiting for engulfing
   ENG_ARMED  = 1,   // engulfing found, waiting for the retrace trigger
   ENG_ACTIVE = 2    // grid placed, managing the basket
  };

//--- configuration for magic 1
struct EngulfingConfig
  {
   long              magic;
   ENUM_TIMEFRAMES   tf;
   double            retracePercent;     // % of candle-2 range price must retrace before entry
   int               gridStepPoints;     // spacing between grid orders
   int               ordersPerSide;      // pending orders per side (limit & stop)
   double            lots;               // base lot per order
   double            basketTP;           // close whole group at +this money
   double            basketSL;           // close whole group at -this money (hard stop)
   double            flipMaxLoss;        // flip allowed only while loss <= this money
   double            recoveryTrigger;    // start recovery when loss >= this money
   double            recoveryStep;       // extra loss (money) between recovery adds
   int               recoveryMaxAdds;    // cap on recovery orders
   double            recoveryLotMult;    // lot multiplier per recovery add
  };

//+------------------------------------------------------------------+
//| CStrategyEngulfing                                              |
//+------------------------------------------------------------------+
class CStrategyEngulfing
  {
private:
   EngulfingConfig   m_cfg;
   CUtils           *m_utils;
   CLogger          *m_log;
   CRiskManager     *m_risk;
   CTradeManager    *m_trade;

   ENUM_ENG_STATE    m_state;
   datetime          m_lastBar;
   ENUM_SIDE         m_armedSide;      // side we are waiting to enter
   ENUM_SIDE         m_activeSide;     // side of the live group
   double            m_triggerPrice;   // price at which armed grid fires
   int               m_recoveryAdds;   // recovery orders added so far

   //--- detect 3-bar engulfing on the strategy timeframe.
   //--- returns SIDE_SELL for bearish engulfing, SIDE_BUY for bullish, else SIDE_NONE.
   ENUM_SIDE         DetectEngulfing(double &refClose,double &range2)
     {
      double o1=iOpen (m_utils.Symbol(),m_cfg.tf,2);   // candle 1 (older)
      double c1=iClose(m_utils.Symbol(),m_cfg.tf,2);
      double o2=iOpen (m_utils.Symbol(),m_cfg.tf,1);   // candle 2 (engulfing, just closed)
      double c2=iClose(m_utils.Symbol(),m_cfg.tf,1);
      double h2=iHigh (m_utils.Symbol(),m_cfg.tf,1);
      double l2=iLow  (m_utils.Symbol(),m_cfg.tf,1);
      if(o1==0.0 || o2==0.0)
         return SIDE_NONE;

      refClose=c2;
      range2  =MathMax(h2-l2,m_utils.Point());

      bool prevBull=(c1>o1);
      bool prevBear=(c1<o1);
      bool currBear=(c2<o2);
      bool currBull=(c2>o2);

      // bearish engulfing: green candle1 fully engulfed by red candle2 -> SELL
      if(prevBull && currBear && o2>=c1 && c2<=o1)
         return SIDE_SELL;
      // bullish engulfing: red candle1 fully engulfed by green candle2 -> BUY
      if(prevBear && currBull && o2<=c1 && c2>=o1)
         return SIDE_BUY;
      return SIDE_NONE;
     }

   //--- arm a side and compute the retrace trigger price
   void              Arm(ENUM_SIDE side,double refClose,double range2)
     {
      m_armedSide=side;
      double dist=range2*m_cfg.retracePercent/100.0;
      if(side==SIDE_SELL)
         m_triggerPrice=m_utils.Normalize(refClose+dist); // wait for bounce up, then sell
      else
         m_triggerPrice=m_utils.Normalize(refClose-dist); // wait for dip down, then buy
      m_state=ENG_ARMED;
      m_log.Info("M1",StringFormat("ARMED %s trigger=%.5f (retrace %.1f%%)",
                 (side==SIDE_SELL?"SELL":"BUY"),m_triggerPrice,m_cfg.retracePercent));
     }

   //--- place the grid straddle (limit + stop) for the given side
   void              PlaceGrid(ENUM_SIDE side)
     {
      double center=(side==SIDE_SELL ? m_utils.Bid() : m_utils.Ask());
      double step  =m_utils.PointsToPrice(m_cfg.gridStepPoints);
      string cmt   =StringFormat("M1-%s",(side==SIDE_SELL?"SELL":"BUY"));

      for(int i=1;i<=m_cfg.ordersPerSide;i++)
        {
         if(side==SIDE_SELL)
           {
            m_trade.PlacePending(m_cfg.magic,ORDER_TYPE_SELL_LIMIT,center+i*step,m_cfg.lots,0,0,cmt);
            m_trade.PlacePending(m_cfg.magic,ORDER_TYPE_SELL_STOP ,center-i*step,m_cfg.lots,0,0,cmt);
           }
         else
           {
            m_trade.PlacePending(m_cfg.magic,ORDER_TYPE_BUY_LIMIT,center-i*step,m_cfg.lots,0,0,cmt);
            m_trade.PlacePending(m_cfg.magic,ORDER_TYPE_BUY_STOP ,center+i*step,m_cfg.lots,0,0,cmt);
           }
        }
      m_activeSide=side;
      m_recoveryAdds=0;
      m_state=ENG_ACTIVE;
      m_log.Info("M1",StringFormat("GRID placed %s x%d/side @ center %.5f",
                 (side==SIDE_SELL?"SELL":"BUY"),m_cfg.ordersPerSide,center));
     }

   void              CloseGroupAndReset(const string reason)
     {
      m_trade.CloseGroup(m_cfg.magic);
      m_log.Info("M1",StringFormat("GROUP closed (%s)",reason));
      m_state=ENG_IDLE;
      m_armedSide=SIDE_NONE;
      m_activeSide=SIDE_NONE;
      m_recoveryAdds=0;
     }

   //--- add one recovery order in the losing direction (martingale-style average)
   void              AddRecovery(void)
     {
      double lot=m_utils.NormalizeLots(m_cfg.lots*MathPow(m_cfg.recoveryLotMult,m_recoveryAdds+1));
      string cmt=StringFormat("M1-REC%d",m_recoveryAdds+1);
      if(m_trade.OpenMarket(m_cfg.magic,m_activeSide,lot,0,0,cmt))
        {
         m_recoveryAdds++;
         m_log.Warn("M1",StringFormat("RECOVERY add #%d %s lot=%.2f",
                    m_recoveryAdds,(m_activeSide==SIDE_SELL?"SELL":"BUY"),lot));
        }
     }

public:
                     CStrategyEngulfing(void)
     {
      m_utils=NULL; m_log=NULL; m_risk=NULL; m_trade=NULL;
      m_state=ENG_IDLE; m_lastBar=0;
      m_armedSide=SIDE_NONE; m_activeSide=SIDE_NONE;
      m_triggerPrice=0.0; m_recoveryAdds=0;
     }

   void              Init(EngulfingConfig &cfg,CUtils *utils,CLogger *log,
                          CRiskManager *risk,CTradeManager *trade)
     {
      m_cfg=cfg; m_utils=utils; m_log=log; m_risk=risk; m_trade=trade;
      // recover live state after a restart
      if(m_trade.CountPositions(m_cfg.magic)>0)
        {
         m_activeSide=m_trade.NetSide(m_cfg.magic);
         m_state=ENG_ACTIVE;
        }
     }

   long              Magic(void) const { return m_cfg.magic; }

   //--- main per-tick entry point
   void              OnTick(void)
     {
      // 1) evaluate a fresh engulfing signal once per closed bar
      if(m_utils.IsNewBar(m_cfg.tf,m_lastBar))
        {
         double refClose,range2;
         ENUM_SIDE sig=DetectEngulfing(refClose,range2);

         if(sig!=SIDE_NONE)
           {
            if(m_state==ENG_IDLE)
              {
               Arm(sig,refClose,range2);
              }
            else if(m_state==ENG_ARMED && sig!=m_armedSide)
              {
               Arm(sig,refClose,range2);   // re-arm to the newest opposite signal
              }
            else if(m_state==ENG_ACTIVE && sig!=m_activeSide)
              {
               // opposite engulfing while a group is live -> FLIP or ignore.
               double pl=m_risk.BasketProfit(m_cfg.magic);
               if(pl>=-m_cfg.flipMaxLoss)
                 {
                  m_log.Info("M1",StringFormat("FLIP: opposite signal, basket P/L=%.2f within flip range",pl));
                  CloseGroupAndReset("flip");
                  Arm(sig,refClose,range2);
                 }
               else
                 {
                  m_log.Warn("M1",StringFormat("Opposite signal IGNORED (basket loss %.2f exceeds flip limit) -> stay & recover",pl));
                 }
              }
           }
        }

      // 2) armed -> check retrace trigger every tick
      if(m_state==ENG_ARMED)
        {
         double px=(m_armedSide==SIDE_SELL ? m_utils.Bid() : m_utils.Ask());
         bool hit=(m_armedSide==SIDE_SELL ? (px>=m_triggerPrice) : (px<=m_triggerPrice));
         if(hit)
            PlaceGrid(m_armedSide);
        }

      // 3) active -> manage basket TP / stop / recovery
      if(m_state==ENG_ACTIVE)
        {
         // group may have been fully closed by TP/SL of the broker or manually
         if(m_trade.CountPositions(m_cfg.magic)==0 && m_trade.CountPending(m_cfg.magic)==0)
           {
            m_state=ENG_IDLE;
            m_activeSide=SIDE_NONE;
            m_recoveryAdds=0;
            return;
           }

         double pl=m_risk.BasketProfit(m_cfg.magic);

         if(m_cfg.basketTP>0.0 && pl>=m_cfg.basketTP)
           {
            CloseGroupAndReset(StringFormat("basket TP hit +%.2f",pl));
            return;
           }
         if(m_cfg.basketSL>0.0 && pl<=-m_cfg.basketSL)
           {
            CloseGroupAndReset(StringFormat("basket STOP hit %.2f",pl));
            return;
           }

         // recovery: only when there are live positions and loss deep enough
         if(m_trade.CountPositions(m_cfg.magic)>0 && m_cfg.recoveryMaxAdds>0)
           {
            double nextThreshold=m_cfg.recoveryTrigger+m_recoveryAdds*m_cfg.recoveryStep;
            if(pl<=-nextThreshold && m_recoveryAdds<m_cfg.recoveryMaxAdds)
               AddRecovery();
           }
        }
     }
  };
//+------------------------------------------------------------------+
#endif // THREEMAGIC_STRATEGY_ENGULFING_MQH
