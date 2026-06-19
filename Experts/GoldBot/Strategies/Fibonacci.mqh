//+------------------------------------------------------------------+
//| Fibonacci.mqh                                                     |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Strategy index 9 — Fibonacci Retracement
// Identifies the most recent significant swing using fractal logic,
// then checks if price is at the 61.8% or 78.6% retracement level.
// Score: 3 sub-conditions, ~33% each (0.0 – 1.0)
//
#pragma once
#include "BaseStrategy.mqh"

//+------------------------------------------------------------------+
//| Input parameters for Fibonacci strategy                           |
//+------------------------------------------------------------------+
input int    FIB_SwingLookback = 100;   // Bars to detect swing high/low
input int    FIB_EMA50Period   = 50;    // EMA50 period for trend filter
input double FIB_ZoneBuffer    = 0.003; // Price tolerance around fib levels (0.3%)
input int    FIB_ATR_Period    = 14;    // ATR period for Fibonacci strategy

// Fibonacci retracement levels
static const double FIB_618  = 0.618;
static const double FIB_786  = 0.786;
static const double FIB_MIN_SWING_ATR = 3.0;  // Swing must be >= 3 × ATR

//+------------------------------------------------------------------+
//| CStratFibonacci                                                   |
//+------------------------------------------------------------------+
class CStratFibonacci : public CBaseStrategy
{
private:
    int      m_ema50_handle;   // iMA handle for EMA50
    double   m_ema50[];        // EMA50 buffer

    //------------------------------------------------------------------
    // FindSwing
    // Locates the most recent significant swing high and swing low within
    // FIB_SwingLookback bars. Uses simple fractal detection (bar is higher/lower
    // than both neighboring bars).
    // out_swing_high, out_swing_low: prices of the swing points
    // out_swing_bar_high, out_swing_bar_low: bar indices of swing points
    //------------------------------------------------------------------
    bool FindSwing(double &out_swing_high, double &out_swing_low,
                   int &out_bar_high,      int &out_bar_low)
    {
        int bars_avail = (int)Bars(_Symbol, PERIOD_M15);
        int scan_end   = MathMin(FIB_SwingLookback, bars_avail - 3);

        out_swing_high = -DBL_MAX;
        out_swing_low  =  DBL_MAX;
        out_bar_high   = -1;
        out_bar_low    = -1;

        for(int i = 2; i <= scan_end; i++)
        {
            double h = iHigh(_Symbol, PERIOD_M15, i);
            double l = iLow (_Symbol, PERIOD_M15, i);

            // Fractal high
            if(h > iHigh(_Symbol, PERIOD_M15, i-1) &&
               h > iHigh(_Symbol, PERIOD_M15, i+1) &&
               h > out_swing_high)
            {
                out_swing_high = h;
                out_bar_high   = i;
            }

            // Fractal low
            if(l < iLow(_Symbol, PERIOD_M15, i-1) &&
               l < iLow(_Symbol, PERIOD_M15, i+1) &&
               l < out_swing_low)
            {
                out_swing_low = l;
                out_bar_low   = i;
            }
        }

        return (out_bar_high >= 0 && out_bar_low >= 0);
    }

public:
    CStratFibonacci()
    {
        m_name         = "Fibonacci";
        m_magic_offset = 9;
        m_ema50_handle = INVALID_HANDLE;
    }

    //------------------------------------------------------------------
    // Init — create EMA50 handle and ATR
    //------------------------------------------------------------------
    virtual void Init(int atr_period, ENUM_TIMEFRAMES tf) override
    {
        m_ema50_handle = iMA(_Symbol, tf, FIB_EMA50Period, 0, MODE_EMA, PRICE_CLOSE);
        if(m_ema50_handle == INVALID_HANDLE)
            PrintFormat("[Fibonacci] EMA50 handle error %d", GetLastError());

        ArraySetAsSeries(m_ema50, true);
        m_atr.Init(atr_period, tf);
    }

    //------------------------------------------------------------------
    // Deinit — release handles
    //------------------------------------------------------------------
    virtual void Deinit() override
    {
        if(m_ema50_handle != INVALID_HANDLE)
        {
            IndicatorRelease(m_ema50_handle);
            m_ema50_handle = INVALID_HANDLE;
        }
        m_atr.Deinit();
    }

    //------------------------------------------------------------------
    // Evaluate — score 3 sub-conditions (~33% each)
    //   1. Price at 61.8% or 78.6% retracement of clear swing
    //   2. Price above EMA50 for bull setup, below EMA50 for bear
    //   3. Clear swing: swing height >= FIB_MIN_SWING_ATR × ATR
    //------------------------------------------------------------------
    virtual StrategyScore Evaluate() override
    {
        StrategyScore result;
        result.name   = m_name;
        result.score  = 0.0;
        result.bias   = 0;
        result.reason = "";

        if(CopyBuffer(m_ema50_handle, 0, 0, 3, m_ema50) < 3)
        {
            result.reason = "EMA50 buffer not ready";
            return result;
        }

        double atr = m_atr.GetATR(1);
        if(atr <= 0.0)
        {
            result.reason = "ATR not ready";
            return result;
        }

        double ema50     = m_ema50[1];
        double price_now = iClose(_Symbol, PERIOD_M15, 1);

        // Find swing high and low
        double swing_high, swing_low;
        int    bar_high, bar_low;
        if(!FindSwing(swing_high, swing_low, bar_high, bar_low))
        {
            result.reason = "No swing found";
            return result;
        }

        double swing_range = swing_high - swing_low;
        if(swing_range <= 0.0)
        {
            result.reason = "Invalid swing range";
            return result;
        }

        // Determine bias from swing structure
        // If high bar is older than low bar → price moved up → look for bearish retracement
        // If low bar is older than high bar → price moved down → look for bullish retracement
        bool is_bull_retrace = (bar_low < bar_high); // low is more recent → we came down → expect bounce

        result.bias = is_bull_retrace ? 1 : -1;

        // Fibonacci retracement levels
        double fib618, fib786;
        if(is_bull_retrace)
        {
            // Bullish: measuring pullback from swing_high down to swing_low
            fib618 = swing_high - swing_range * FIB_618;
            fib786 = swing_high - swing_range * FIB_786;
        }
        else
        {
            // Bearish: measuring pullback from swing_low up to swing_high
            fib618 = swing_low + swing_range * FIB_618;
            fib786 = swing_low + swing_range * FIB_786;
        }

        int conditions_met = 0;

        // Sub-condition 1: Price near fib level
        double tol = swing_range * FIB_ZoneBuffer;
        bool at_618 = MathAbs(price_now - fib618) <= tol;
        bool at_786 = MathAbs(price_now - fib786) <= tol;

        if(at_618 || at_786)
            conditions_met++;

        // Sub-condition 2: Price position vs EMA50
        if((is_bull_retrace && price_now > ema50) ||
           (!is_bull_retrace && price_now < ema50))
            conditions_met++;

        // Sub-condition 3: Clear swing (swing height >= FIB_MIN_SWING_ATR × ATR)
        if(swing_range >= FIB_MIN_SWING_ATR * atr)
            conditions_met++;

        result.score  = conditions_met / 3.0;
        result.reason = StringFormat("swing=[%.2f,%.2f] range=%.4f fib618=%.4f fib786=%.4f price=%.2f cond=%d/3",
                                     swing_low, swing_high, swing_range,
                                     fib618, fib786, price_now, conditions_met);
        return result;
    }
};
