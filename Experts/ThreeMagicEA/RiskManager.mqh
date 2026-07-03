//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|        ThreeMagicEA - Position sizing, basket P/L, drawdown      |
//+------------------------------------------------------------------+
#ifndef THREEMAGIC_RISKMANAGER_MQH
#define THREEMAGIC_RISKMANAGER_MQH
#property strict

#include "Utils.mqh"
#include "Logger.mqh"
#include <Trade/PositionInfo.mqh>

//+------------------------------------------------------------------+
//| CRiskManager                                                    |
//+------------------------------------------------------------------+
class CRiskManager
  {
private:
   CUtils           *m_utils;
   CLogger          *m_log;
   double            m_equityPeak;      // for account drawdown tracking
   double            m_maxDrawdownPct;  // account-level hard stop
   bool              m_halted;          // global trading halt flag

   CPositionInfo     m_pos;

public:
                     CRiskManager(void)
     {
      m_utils=NULL; m_log=NULL;
      m_equityPeak=0.0; m_maxDrawdownPct=0.0; m_halted=false;
     }

   void              Init(CUtils *utils,CLogger *log,double maxDrawdownPct)
     {
      m_utils=utils;
      m_log=log;
      m_maxDrawdownPct=maxDrawdownPct;
      m_equityPeak=AccountInfoDouble(ACCOUNT_EQUITY);
      m_halted=false;
     }

   //--- position size from % risk of balance and stop distance in points
   double            LotByRisk(double riskPercent,double slPoints)
     {
      double balance =AccountInfoDouble(ACCOUNT_BALANCE);
      double riskMoney=balance*riskPercent/100.0;
      double ptValue  =m_utils.PointValuePerLot();
      if(ptValue<=0.0 || slPoints<=0.0)
         return m_utils.NormalizeLots(SymbolInfoDouble(m_utils.Symbol(),SYMBOL_VOLUME_MIN));
      double lots=riskMoney/(slPoints*ptValue);
      return m_utils.NormalizeLots(lots);
     }

   //--- fixed % of balance sizing when there is no per-order SL (grid magics)
   double            LotByBalancePct(double pctPerLot,double lotPer1k)
     {
      // lotPer1k = lots to trade for each 1000 units of balance (simple scaling)
      double balance=AccountInfoDouble(ACCOUNT_BALANCE);
      double lots=(balance/1000.0)*lotPer1k;
      if(pctPerLot>0.0)
        {
         // cap: do not let a single ticket margin exceed pctPerLot% of balance
         double marginOne=0.0;
         if(OrderCalcMargin(ORDER_TYPE_BUY,m_utils.Symbol(),1.0,m_utils.Ask(),marginOne) && marginOne>0.0)
           {
            double maxLots=(balance*pctPerLot/100.0)/marginOne;
            if(lots>maxLots) lots=maxLots;
           }
        }
      return m_utils.NormalizeLots(lots);
     }

   //--- aggregate floating P/L of all open positions for a magic on the symbol
   double            BasketProfit(long magic)
     {
      double sum=0.0;
      int total=PositionsTotal();
      for(int i=0;i<total;i++)
        {
         if(!m_pos.SelectByIndex(i))
            continue;
         if(m_pos.Symbol()!=m_utils.Symbol())
            continue;
         if(m_pos.Magic()!=magic)
            continue;
         sum+=m_pos.Profit()+m_pos.Swap()+m_pos.Commission();
        }
      return sum;
     }

   //--- basket profit expressed in points (net across the magic's positions)
   double            BasketProfitPoints(long magic)
     {
      double money=BasketProfit(magic);
      double ptValue=m_utils.PointValuePerLot();
      double lots=BasketVolume(magic);
      if(ptValue<=0.0 || lots<=0.0)
         return 0.0;
      return money/(ptValue*lots);
     }

   double            BasketVolume(long magic)
     {
      double vol=0.0;
      int total=PositionsTotal();
      for(int i=0;i<total;i++)
        {
         if(!m_pos.SelectByIndex(i)) continue;
         if(m_pos.Symbol()!=m_utils.Symbol()) continue;
         if(m_pos.Magic()!=magic) continue;
         vol+=m_pos.Volume();
        }
      return vol;
     }

   //--- account level drawdown monitor. Returns true if a NEW halt was triggered.
   bool              CheckAccountDrawdown(void)
     {
      double equity=AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity>m_equityPeak)
         m_equityPeak=equity;
      if(m_maxDrawdownPct<=0.0 || m_equityPeak<=0.0)
         return false;
      double ddPct=(m_equityPeak-equity)/m_equityPeak*100.0;
      if(ddPct>=m_maxDrawdownPct && !m_halted)
        {
         m_halted=true;
         if(m_log!=NULL)
            m_log.Error("RISK",StringFormat("Account drawdown %.2f%% >= limit %.2f%% -> trading HALTED",
                        ddPct,m_maxDrawdownPct));
         return true;
        }
      return false;
     }

   bool              IsHalted(void) const { return m_halted; }
   void              ResetHalt(void)      { m_halted=false; m_equityPeak=AccountInfoDouble(ACCOUNT_EQUITY); }

   double            EquityPeak(void) const { return m_equityPeak; }
   double            DrawdownPct(void)
     {
      double eq=AccountInfoDouble(ACCOUNT_EQUITY);
      if(m_equityPeak<=0.0) return 0.0;
      return (m_equityPeak-eq)/m_equityPeak*100.0;
     }
  };
//+------------------------------------------------------------------+
#endif // THREEMAGIC_RISKMANAGER_MQH
