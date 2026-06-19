//+------------------------------------------------------------------+
//| ATRUtils.mqh                                                      |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Provides ATR handle management and ATR value retrieval.
// Handles point-to-USD conversion for XAUUSD.
// All strategies use this class for consistent ATR access.
//
#pragma once

//+------------------------------------------------------------------+
//| CATRUtils — manages a single ATR indicator handle                 |
//+------------------------------------------------------------------+
class CATRUtils
{
private:
    int              m_handle;   // iATR indicator handle
    double           m_buffer[]; // CopyBuffer destination
    int              m_period;   // ATR period
    ENUM_TIMEFRAMES  m_tf;       // Timeframe for ATR calculation

public:
    //------------------------------------------------------------------
    // Constructor — mark handle as invalid until Init() is called
    //------------------------------------------------------------------
    CATRUtils() : m_handle(INVALID_HANDLE), m_period(14), m_tf(PERIOD_M15) {}

    //------------------------------------------------------------------
    // Init
    // Creates iATR indicator handle.
    // Returns false and prints error if handle creation fails.
    //------------------------------------------------------------------
    bool Init(int period, ENUM_TIMEFRAMES tf)
    {
        m_period = period;
        m_tf     = tf;

        m_handle = iATR(_Symbol, tf, period);
        if(m_handle == INVALID_HANDLE)
        {
            PrintFormat("[ATRUtils] Init failed: iATR handle error %d", GetLastError());
            return false;
        }
        ArraySetAsSeries(m_buffer, true);
        return true;
    }

    //------------------------------------------------------------------
    // Deinit
    // Releases the indicator handle to free memory.
    // Must be called from strategy Deinit() and EA OnDeinit().
    //------------------------------------------------------------------
    void Deinit()
    {
        if(m_handle != INVALID_HANDLE)
        {
            IndicatorRelease(m_handle);
            m_handle = INVALID_HANDLE;
        }
    }

    //------------------------------------------------------------------
    // GetATR
    // Returns ATR value at bar[shift].
    // shift=1 (default) returns the last closed bar ATR.
    // Returns 0.0 on failure (buffer not ready or handle invalid).
    //------------------------------------------------------------------
    double GetATR(int shift = 1)
    {
        if(m_handle == INVALID_HANDLE)
        {
            Print("[ATRUtils] GetATR called with invalid handle");
            return 0.0;
        }

        int copied = CopyBuffer(m_handle, 0, 0, shift + 1, m_buffer);
        if(copied < shift + 1)
        {
            PrintFormat("[ATRUtils] CopyBuffer returned %d, expected %d (error %d)",
                        copied, shift + 1, GetLastError());
            return 0.0;
        }
        return m_buffer[shift];
    }

    //------------------------------------------------------------------
    // GetATRAverage
    // Returns the simple average of ATR over 'bars' closed bars.
    // Used to determine if ATR is above or below its own average.
    //------------------------------------------------------------------
    double GetATRAverage(int bars = 14)
    {
        if(m_handle == INVALID_HANDLE) return 0.0;

        int needed = bars + 1;
        double tmp[];
        ArraySetAsSeries(tmp, true);
        int copied = CopyBuffer(m_handle, 0, 1, needed, tmp);
        if(copied < bars)
        {
            PrintFormat("[ATRUtils] GetATRAverage: only %d bars copied", copied);
            return 0.0;
        }

        double sum = 0.0;
        for(int i = 0; i < bars; i++)
            sum += tmp[i];

        return sum / bars;
    }

    //------------------------------------------------------------------
    // ToUSD
    // Converts ATR in price points to approximate USD value.
    // For XAUUSD: 1 point movement × tick_value / tick_size × lots(1).
    // Returns USD equivalent of 'atr_points' for 1 standard lot.
    //------------------------------------------------------------------
    double ToUSD(double atr_points)
    {
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        if(tick_size == 0.0) return 0.0;

        double value_per_point = tick_value / tick_size;
        return atr_points * value_per_point;
    }

    //------------------------------------------------------------------
    // ToPoints
    // Converts a USD amount back to price points (inverse of ToUSD).
    // Useful when you have a dollar-risk figure and need point distance.
    //------------------------------------------------------------------
    double ToPoints(double usd)
    {
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        if(tick_value == 0.0 || tick_size == 0.0) return 0.0;

        double value_per_point = tick_value / tick_size;
        if(value_per_point == 0.0) return 0.0;

        return usd / value_per_point;
    }

    //------------------------------------------------------------------
    // IsReady
    // Returns true if the handle is valid and buffer has data.
    //------------------------------------------------------------------
    bool IsReady()
    {
        if(m_handle == INVALID_HANDLE) return false;
        double tmp[];
        ArraySetAsSeries(tmp, true);
        return CopyBuffer(m_handle, 0, 1, 2, tmp) >= 2;
    }
};
