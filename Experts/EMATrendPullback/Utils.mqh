//+------------------------------------------------------------------+
//|                                                        Utils.mqh |
//|  Helper functions: new-bar detection, positions, price rounding  |
//+------------------------------------------------------------------+
#ifndef EMATP_UTILS_MQH
#define EMATP_UTILS_MQH

//+------------------------------------------------------------------+
//| Detects the opening of a new bar. The first call only stores the |
//| current bar so an EA attached mid-bar does not act on old data.  |
//+------------------------------------------------------------------+
class CNewBar
  {
private:
   datetime m_last;
public:
            CNewBar() : m_last(0) {}
   bool     Check(const string sym, const ENUM_TIMEFRAMES tf)
     {
      datetime t = iTime(sym, tf, 0);
      if(t == 0)
         return false;
      if(m_last == 0)
        {
         m_last = t;
         return false;
        }
      if(t != m_last)
        {
         m_last = t;
         return true;
        }
      return false;
     }
  };

//--- round price to the symbol tick size
double NormalizeToTick(const string sym, const double price)
  {
   double tick   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(tick > 0)
      return NormalizeDouble(MathRound(price / tick) * tick, digits);
   return NormalizeDouble(price, digits);
  }

//--- number of decimals implied by the volume step (0.01 -> 2, 0.1 -> 1, 1 -> 0)
int VolumeDigits(const double step)
  {
   int    d = 0;
   double t = step;
   while(d < 8 && MathAbs(t - MathRound(t)) > 1e-8)
     {
      t *= 10.0;
      d++;
     }
   return d;
  }

//--- count EA positions; dir: +1 buy, -1 sell, 0 both
int CountPositions(const string sym, const long magic, const int dir)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(dir == 0 || (dir == 1 && type == POSITION_TYPE_BUY) || (dir == -1 && type == POSITION_TYPE_SELL))
         n++;
     }
   return n;
  }

bool IsHedgingAccount()
  {
   return (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
  }

//--- terminal / account / symbol allow automated trading in direction dir
bool IsTradingAllowed(const string sym, const int dir, string &why)
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))  { why = "AutoTrading disabled in terminal"; return false; }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))            { why = "Algo trading not allowed for this EA"; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))     { why = "Expert trading disabled for account"; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))    { why = "Trading disabled for account"; return false; }
   ENUM_SYMBOL_TRADE_MODE m = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   if(m == SYMBOL_TRADE_MODE_DISABLED || m == SYMBOL_TRADE_MODE_CLOSEONLY) { why = "Symbol trade mode disabled/close-only"; return false; }
   if(dir == 1 && m == SYMBOL_TRADE_MODE_SHORTONLY) { why = "Symbol is short-only"; return false; }
   if(dir == -1 && m == SYMBOL_TRADE_MODE_LONGONLY) { why = "Symbol is long-only"; return false; }
   return true;
  }

//--- session check on server hour; start > end means overnight session
bool InSession(const datetime t, const int startHour, const int endHour)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   if(startHour <= endHour)
      return dt.hour >= startHour && dt.hour < endHour;
   return dt.hour >= startHour || dt.hour < endHour;
  }

string DirText(const int dir)
  {
   return dir == 1 ? "BUY" : (dir == -1 ? "SELL" : "NONE");
  }

#endif
//+------------------------------------------------------------------+
