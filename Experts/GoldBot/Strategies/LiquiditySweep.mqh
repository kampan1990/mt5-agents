//+------------------------------------------------------------------+
//| LiquiditySweep.mqh                                                |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Strategy index 10 — Liquidity Sweep
// Detects when price wicks through a recent structural high or low
// (sweeping liquidity), then closes back inside — indicating a
// false breakout and potential reversal.
// Score: 3 sub-conditions, ~33% each (0.0 – 1.0)
//
#pragma once
#include "BaseStrategy.mqh"

//+------------------------------------------------------------------+
//| Input parameters for Liquidity Sweep strategy                     |
//+------------------------------------------------------------------+
input double LS_WickATR   = 1.5;  // Minimum rejection wick size in ATR units
input int    LS_Lookback  = 30;   // Bars to scan for recent structural high/low
input int    LS_EMA_Slow  = 200;  // EMA200 for trend alignment
input int    LS_ATR_Period = 14;  // ATR period for Liquidity Sweep

//+------------------------------------------------------------------+
//| CStratLiquiditySweep                                              |
//+------------------------------------------------------------------+
class CStratLiquiditySweep : public CBaseStrategy
{
private:
    int      m_ema200_handle;  // iMA handle for EMA200
    double   m_ema200[];       // EMA200 buffer

public:
    CStratLiquiditySweep()
    {
        m_name          = "LiquiditySweep";
        m_magic_offset  = 10;
        m_ema200_handle = INVALID_HANDLE;
    }

    //------------------------------------------------------------------
    // Init — create EMA200 handle and ATR
    //------------------------------------------------------------------
    virtual void Init(int atr_period, ENUM_TIMEFRAMES tf) override
    {
        m_ema200_handle = iMA(_Symbol, tf, LS_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
        if(m_ema200_handle == INVALID_HANDLE)
            PrintFormat("[LiquiditySweep] EMA200 handle error %d", GetLastError());

        ArraySetAsSeries(m_ema200, true);
        m_atr.Init(atr_period, tf);
    }

    //------------------------------------------------------------------
    // Deinit — release handles
    //------------------------------------------------------------------
    virtual void Deinit() override
    {
        if(m_ema200_handle != INVALID_HANDLE)
        {
            IndicatorRelease(m_ema200_handle);
            m_ema200_handle = INVALID_HANDLE;
        }
        m_atr.Deinit();
    }

    //------------------------------------------------------------------
    // Evaluate — score 3 sub-conditions (~33% each)
    //   1. Liquidity sweep: price wicked through structural high/low then closed back
    //   2. Rejection wick > LS_WickATR × ATR (strong rejection)
    //   3. Trend aligned with EMA200
    //------------------------------------------------------------------
    virtual StrategyScore Evaluate() override
    {
        StrategyScore result;
        result.name   = m_name;
        result.score  = 0.0;
        result.bias   = 0;
        result.reason = "";

        if(CopyBuffer(m_ema200_handle, 0, 0, 4, m_ema200) < 4)
        {
            result.reason = "EMA200 buffer not ready";
            return result;
        }

        double atr = m_atr.GetATR(1);
        if(atr <= 0.0)
        {
            result.reason = "ATR not ready";
            return result;
        }

        double ema200    = m_ema200[1];
        double price_now = iClose(_Symbol, PERIOD_M15, 1);
        bool   ema_bull  = (price_now > ema200);

        // Find the structural high and low over lookback (excluding bar[1])
        int bars_avail = (int)Bars(_Symbol, PERIOD_M15);
        int scan_end   = MathMin(LS_Lookback + 1, bars_avail - 1);

        int    struct_high_bar = iHighest(_Symbol, PERIOD_M15, MODE_HIGH, LS_Lookback, 2);
        int    struct_low_bar  = iLowest (_Symbol, PERIOD_M15, MODE_LOW,  LS_Lookback, 2);
        double struct_high     = iHigh(_Symbol, PERIOD_M15, struct_high_bar);
        double struct_low      = iLow (_Symbol, PERIOD_M15, struct_low_bar);

        // Bar[1] data (most recent closed bar)
        double h1 = iHigh (_Symbol, PERIOD_M15, 1);
        double l1 = iLow  (_Symbol, PERIOD_M15, 1);
        double o1 = iOpen (_Symbol, PERIOD_M15, 1);
        double c1 = iClose(_Symbol, PERIOD_M15, 1);

        // Check for sweep of structural high (bearish sweep: wick above high, close back below)
        bool bull_sweep_of_low  = (l1 < struct_low  && c1 > struct_low);  // Swept lows, closed above
        bool bear_sweep_of_high = (h1 > struct_high && c1 < struct_high); // Swept highs, closed below

        bool sweep_found = bull_sweep_of_low || bear_sweep_of_high;

        if(!sweep_found)
        {
            result.reason = StringFormat("No sweep: h1=%.2f l1=%.2f struct=[%.2f,%.2f]",
                                         h1, l1, struct_low, struct_high);
            return result;
        }

        result.bias = bull_sweep_of_low ? 1 : -1; // Sweep lows → bullish; sweep highs → bearish
        int conditions_met = 0;

        // Sub-condition 1: Sweep present
        conditions_met++;

        // Sub-condition 2: Rejection wick size
        double range = h1 - l1;
        double rejection_wick;
        if(bull_sweep_of_low)
            rejection_wick = MathMin(o1, c1) - l1; // lower wick for bullish rejection
        else
            rejection_wick = h1 - MathMax(o1, c1); // upper wick for bearish rejection

        if(rejection_wick >= LS_WickATR * atr)
            conditions_met++;

        // Sub-condition 3: EMA200 trend aligned
        if((bull_sweep_of_low  && ema_bull)  ||
           (bear_sweep_of_high && !ema_bull))
            conditions_met++;

        result.score  = conditions_met / 3.0;
        result.reason = StringFormat("sweep=%s wick=%.4f(%.2fATR) ema_bull=%s cond=%d/3",
                                     bull_sweep_of_low ? "bull" : "bear",
                                     rejection_wick, rejection_wick / atr,
                                     ema_bull ? "Y" : "N", conditions_met);
        return result;
    }
};
