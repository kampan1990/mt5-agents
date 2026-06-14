//+------------------------------------------------------------------+
//| RiskManager.mqh                                                   |
//| GridADXEMARSI EA                                                  |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-14                                               |
//+------------------------------------------------------------------+
#ifndef RISKMANAGER_MQH
#define RISKMANAGER_MQH

//+------------------------------------------------------------------+
//| CRiskManager — drawdown guard, spread filter, price utilities    |
//+------------------------------------------------------------------+
class CRiskManager
{
private:
   double m_max_drawdown_pct;  // maximum allowed drawdown from peak equity (%)
   double m_initial_balance;   // balance at EA start (reference level)
   double m_peak_equity;       // running maximum equity seen since start
   string m_symbol;
   long   m_magic;

public:
   //--- Constructor: safe defaults
   CRiskManager()
   {
      m_max_drawdown_pct = 20.0;
      m_initial_balance  = 0.0;
      m_peak_equity      = 0.0;
   }

   //--- Initialise the risk manager.
   //  @param max_drawdown_pct  drawdown threshold in percent of peak equity
   //  @param symbol            trading symbol
   //  @param magic             EA magic number (used for trade counting)
   //  @return true always (no external resources needed)
   bool Init(double max_drawdown_pct, string symbol, long magic)
   {
      m_max_drawdown_pct = max_drawdown_pct;
      m_symbol           = symbol;
      m_magic            = magic;
      m_initial_balance  = AccountInfoDouble(ACCOUNT_BALANCE);
      m_peak_equity      = AccountInfoDouble(ACCOUNT_EQUITY);
      return true;
   }

   //--- Call once per tick to keep peak equity up to date.
   //  Monotonically increasing — never decreases the recorded peak.
   void UpdatePeakEquity()
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > m_peak_equity)
         m_peak_equity = equity;
   }

   //--- Return the current drawdown from peak equity as a percentage.
   //  @return value in [0, 100]; 0 means equity equals peak
   double GetCurrentDrawdownPct()
   {
      if(m_peak_equity <= 0.0)
         return 0.0;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double dd = (m_peak_equity - equity) / m_peak_equity * 100.0;
      return dd > 0.0 ? dd : 0.0;
   }

   //--- Returns true when current drawdown has exceeded the configured threshold.
   bool IsDrawdownBreached()
   {
      return GetCurrentDrawdownPct() >= m_max_drawdown_pct;
   }

   //--- Returns true when the symbol is tradable right now.
   //  Checks: market open, spread within limit.
   //  @param max_spread_points  maximum tolerable spread in points
   bool IsSymbolTradable(int max_spread_points)
   {
      // Verify market session is open
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
         return false;

      long spread = SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
      if(spread > max_spread_points)
         return false;

      return true;
   }

   //--- Normalise a price to the symbol's required decimal precision.
   //  @param price  raw price value
   //  @return price rounded to symbol digits
   double NormalizePrice(double price)
   {
      int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      return NormalizeDouble(price, digits);
   }

   //--- Normalise a lot size: round down to VOLUME_STEP, clamp to [VOLUME_MIN, VOLUME_MAX].
   //  @param lot  raw lot size
   //  @return valid lot size, or 0.0 if impossible
   double NormalizeLot(double lot)
   {
      double step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      double min  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double max  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);

      if(step <= 0.0) return 0.0;

      // Floor to nearest step
      lot = MathFloor(lot / step) * step;

      // Clamp
      if(lot < min) lot = min;
      if(lot > max) lot = max;

      return NormalizeDouble(lot, 2);
   }
};

#endif // RISKMANAGER_MQH
