//+------------------------------------------------------------------+
//|                                                        Utils.mqh |
//|                          ThreeMagicEA - Helper functions module  |
//+------------------------------------------------------------------+
#ifndef THREEMAGIC_UTILS_MQH
#define THREEMAGIC_UTILS_MQH
#property strict

//+------------------------------------------------------------------+
//| Trade side enum shared across strategies                        |
//+------------------------------------------------------------------+
enum ENUM_SIDE
  {
   SIDE_NONE = 0,
   SIDE_BUY  = 1,
   SIDE_SELL =-1
  };

//+------------------------------------------------------------------+
//| CUtils - stateless helpers bound to a symbol                    |
//+------------------------------------------------------------------+
class CUtils
  {
private:
   string            m_symbol;
   double            m_point;
   int               m_digits;

public:
                     CUtils(void){ m_symbol=_Symbol; m_point=_Point; m_digits=_Digits; }

   void              Init(const string symbol)
     {
      m_symbol=symbol;
      m_point =SymbolInfoDouble(symbol,SYMBOL_POINT);
      m_digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
     }

   string            Symbol(void) const { return m_symbol; }
   double            Point(void)  const { return m_point;  }
   int               Digits(void) const { return m_digits; }

   //--- price helpers
   double            Bid(void){ return SymbolInfoDouble(m_symbol,SYMBOL_BID); }
   double            Ask(void){ return SymbolInfoDouble(m_symbol,SYMBOL_ASK); }
   double            Normalize(double price){ return NormalizeDouble(price,m_digits); }

   double            PointsToPrice(double points){ return points*m_point; }
   double            PriceToPoints(double priceDiff){ return priceDiff/m_point; }

   //--- broker constraints
   int               StopsLevelPoints(void)
     {
      return (int)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_STOPS_LEVEL);
     }
   int               FreezeLevelPoints(void)
     {
      return (int)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_FREEZE_LEVEL);
     }

   //--- value of 1 point per 1.0 lot in account currency
   double            PointValuePerLot(void)
     {
      double tickValue=SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_VALUE);
      double tickSize =SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_SIZE);
      if(tickSize<=0.0)
         return 0.0;
      return tickValue*(m_point/tickSize);
     }

   //--- normalize a volume to broker lot step / min / max
   double            NormalizeLots(double lots)
     {
      double minLot =SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MIN);
      double maxLot =SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MAX);
      double lotStep=SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_STEP);
      if(lotStep<=0.0) lotStep=0.01;
      lots=MathFloor(lots/lotStep)*lotStep;
      if(lots<minLot) lots=minLot;
      if(lots>maxLot) lots=maxLot;
      return NormalizeDouble(lots,2);
     }

   //--- new-bar detector for a given timeframe
   bool              IsNewBar(ENUM_TIMEFRAMES tf,datetime &lastBarTime)
     {
      datetime t=iTime(m_symbol,tf,0);
      if(t==0)
         return false;
      if(t!=lastBarTime)
        {
         lastBarTime=t;
         return true;
        }
      return false;
     }
  };
//+------------------------------------------------------------------+
#endif // THREEMAGIC_UTILS_MQH
