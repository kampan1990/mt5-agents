//+------------------------------------------------------------------+
//| RiskManager.mqh                                                   |
//| GridADXEMARSI EA                                                  |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-14                                               |
//+------------------------------------------------------------------+
#ifndef RISKMANAGER_MQH
#define RISKMANAGER_MQH

#property strict

//+------------------------------------------------------------------+
//| CRiskManager                                                      |
//| Tracks equity high-water mark, monitors drawdown against the      |
//| configured limit, and checks whether the symbol is safe to trade.|
//+------------------------------------------------------------------+
class CRiskManager
{
private:
    double m_max_drawdown_pct;  // absolute limit e.g. 20.0 = 20 %
    double m_initial_balance;   // balance at EA start
    double m_peak_equity;       // highest equity seen since start
    string m_symbol;
    long   m_magic;

public:
    //+------------------------------------------------------------------+
    //| Constructor                                                      |
    //+------------------------------------------------------------------+
    CRiskManager()
    {
        m_max_drawdown_pct = 20.0;
        m_initial_balance  = 0.0;
        m_peak_equity      = 0.0;
        m_symbol           = "";
        m_magic            = 0;
    }

    //+------------------------------------------------------------------+
    //| Init — capture starting balance and equity high-water mark      |
    //| max_drawdown_pct : stop trading when drawdown exceeds this %    |
    //| symbol           : trading symbol                               |
    //| magic            : EA magic number (used for position queries)  |
    //| Returns false if terminal account info is unavailable.          |
    //+------------------------------------------------------------------+
    bool Init(double max_drawdown_pct, string symbol, long magic)
    {
        m_max_drawdown_pct = max_drawdown_pct;
        m_symbol           = symbol;
        m_magic            = magic;

        m_initial_balance = AccountInfoDouble(ACCOUNT_BALANCE);
        if(m_initial_balance <= 0.0)
        {
            Print("CRiskManager::Init — invalid account balance");
            return false;
        }

        m_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
        return true;
    }

    //+------------------------------------------------------------------+
    //| UpdatePeakEquity — call every tick to maintain high-water mark  |
    //+------------------------------------------------------------------+
    void UpdatePeakEquity()
    {
        double equity = AccountInfoDouble(ACCOUNT_EQUITY);
        if(equity > m_peak_equity)
            m_peak_equity = equity;
    }

    //+------------------------------------------------------------------+
    //| GetCurrentDrawdownPct                                            |
    //| Returns drawdown as a positive percentage from peak equity.     |
    //| 0.0 when equity is at or above peak (should not happen often).  |
    //+------------------------------------------------------------------+
    double GetCurrentDrawdownPct()
    {
        if(m_peak_equity <= 0.0)
            return 0.0;

        double equity = AccountInfoDouble(ACCOUNT_EQUITY);
        if(equity >= m_peak_equity)
            return 0.0;

        return (m_peak_equity - equity) / m_peak_equity * 100.0;
    }

    //+------------------------------------------------------------------+
    //| IsDrawdownBreached                                               |
    //| Returns true when current drawdown exceeds the configured limit.|
    //| EA should close all positions and enter EMERGENCY state.        |
    //+------------------------------------------------------------------+
    bool IsDrawdownBreached()
    {
        return GetCurrentDrawdownPct() >= m_max_drawdown_pct;
    }

    //+------------------------------------------------------------------+
    //| IsSymbolTradable                                                 |
    //| Returns false when:                                              |
    //|   - Symbol is not available for trading                         |
    //|   - Current spread exceeds max_spread_points                    |
    //|   - Trade is not allowed by broker at this moment               |
    //| max_spread_points : maximum acceptable spread in integer points |
    //+------------------------------------------------------------------+
    bool IsSymbolTradable(int max_spread_points)
    {
        // Check broker allows trading this symbol
        if(!SymbolInfoInteger(m_symbol, SYMBOL_TRADE_MODE))
            return false;

        // Check account trade is allowed
        if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
            return false;

        // Check EA trade is allowed
        if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
            return false;

        // Check spread
        long spread = SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
        if(spread > max_spread_points)
            return false;

        return true;
    }

    //+------------------------------------------------------------------+
    //| NormalizePrice — round price to symbol digits precision         |
    //+------------------------------------------------------------------+
    double NormalizePrice(double price)
    {
        int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
        return NormalizeDouble(price, digits);
    }

    //+------------------------------------------------------------------+
    //| NormalizeLot — snap lot to the nearest VOLUME_STEP and clamp   |
    //|               between VOLUME_MIN and VOLUME_MAX                 |
    //| Floors (not rounds) to avoid exceeding intended risk.           |
    //+------------------------------------------------------------------+
    double NormalizeLot(double lot)
    {
        double min_lot  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
        double max_lot  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
        double lot_step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);

        if(lot_step <= 0.0)
            lot_step = 0.01;

        // Floor to nearest step
        double normalized = MathFloor(lot / lot_step) * lot_step;

        // Clamp
        if(normalized < min_lot) normalized = min_lot;
        if(normalized > max_lot) normalized = max_lot;

        int step_digits = (int)MathRound(-MathLog10(lot_step));
        if(step_digits < 0) step_digits = 0;

        return NormalizeDouble(normalized, step_digits);
    }
};

#endif // RISKMANAGER_MQH
