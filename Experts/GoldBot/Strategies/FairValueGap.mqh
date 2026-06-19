//+------------------------------------------------------------------+
//| FairValueGap.mqh                                                  |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Strategy index 3 — Fair Value Gap (FVG / Imbalance)
// Detects 3-candle imbalance patterns used in ICT methodology.
// Bullish FVG: bar[2].low < bar[0].high (gap between bar[2] high and bar[0] low)
// Wait for price to return to fill the gap.
// Score: 4 sub-conditions, 25% each (0.0 – 1.0)
//
#pragma once
#include "BaseStrategy.mqh"

//+------------------------------------------------------------------+
//| Input parameters for Fair Value Gap strategy                      |
//+------------------------------------------------------------------+
input double FVG_MinGapATR  = 0.5;  // Minimum gap size in ATR units
input int    FVG_Lookback   = 30;   // Bars to scan for active FVG
input int    FVG_EMA_Slow   = 200;  // Slow EMA period for trend filter
input int    FVG_ATR_Period = 14;   // ATR period for FVG strategy

//+------------------------------------------------------------------+
//| CStratFVG                                                         |
//+------------------------------------------------------------------+
class CStratFVG : public CBaseStrategy
{
private:
    int      m_ema200_handle;   // iMA handle for EMA200 trend filter
    double   m_ema200_buffer[]; // EMA200 values

public:
    CStratFVG()
    {
        m_name          = "FairValueGap";
        m_magic_offset  = 3;
        m_ema200_handle = INVALID_HANDLE;
    }

    //------------------------------------------------------------------
    // Init — create EMA200 and ATR handles
    //------------------------------------------------------------------
    virtual void Init(int atr_period, ENUM_TIMEFRAMES tf) override
    {
        m_ema200_handle = iMA(_Symbol, tf, FVG_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
        if(m_ema200_handle == INVALID_HANDLE)
            PrintFormat("[FairValueGap] EMA200 handle error %d", GetLastError());

        ArraySetAsSeries(m_ema200_buffer, true);
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
    // Evaluate — score 4 sub-conditions (25% each)
    //   1. FVG identified within lookback (3-candle pattern)
    //   2. Gap size >= FVG_MinGapATR × ATR
    //   3. FVG direction aligned with EMA200 slope
    //   4. Strong impulse candle at FVG (body > 70% of total range)
    //------------------------------------------------------------------
    virtual StrategyScore Evaluate() override
    {
        StrategyScore result;
        result.name   = m_name;
        result.score  = 0.0;
        result.bias   = 0;
        result.reason = "";

        const int NEEDED = FVG_Lookback + 4;

        if(CopyBuffer(m_ema200_handle, 0, 0, 4, m_ema200_buffer) < 4)
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

        // EMA200 slope for trend direction
        double ema_now  = m_ema200_buffer[1];
        double ema_prev = m_ema200_buffer[3];
        bool   ema_bull = (ema_now > ema_prev);

        // Scan for FVG pattern in lookback
        bool   fvg_found    = false;
        bool   fvg_bull     = false;
        double fvg_gap_size = 0.0;
        bool   strong_impulse = false;

        int bars_avail = (int)Bars(_Symbol, PERIOD_M15);
        int scan_end   = MathMin(FVG_Lookback + 2, bars_avail - 3);

        for(int i = 1; i <= scan_end; i++)
        {
            double h0 = iHigh (_Symbol, PERIOD_M15, i);
            double l0 = iLow  (_Symbol, PERIOD_M15, i);
            double h2 = iHigh (_Symbol, PERIOD_M15, i + 2);
            double l2 = iLow  (_Symbol, PERIOD_M15, i + 2);

            // Bullish FVG: bar[i+2].high < bar[i].low → gap up
            if(l0 > h2)
            {
                fvg_gap_size = l0 - h2;
                fvg_bull     = true;
                fvg_found    = true;

                // Check impulse candle at bar[i+1]
                double ob = iOpen (_Symbol, PERIOD_M15, i + 1);
                double cb = iClose(_Symbol, PERIOD_M15, i + 1);
                double hb = iHigh (_Symbol, PERIOD_M15, i + 1);
                double lb = iLow  (_Symbol, PERIOD_M15, i + 1);
                double range = hb - lb;
                double body  = MathAbs(cb - ob);
                strong_impulse = (range > 0 && body / range >= 0.70);
                break;
            }

            // Bearish FVG: bar[i+2].low > bar[i].high → gap down
            if(h0 < l2)
            {
                fvg_gap_size = l2 - h0;
                fvg_bull     = false;
                fvg_found    = true;

                double ob = iOpen (_Symbol, PERIOD_M15, i + 1);
                double cb = iClose(_Symbol, PERIOD_M15, i + 1);
                double hb = iHigh (_Symbol, PERIOD_M15, i + 1);
                double lb = iLow  (_Symbol, PERIOD_M15, i + 1);
                double range = hb - lb;
                double body  = MathAbs(cb - ob);
                strong_impulse = (range > 0 && body / range >= 0.70);
                break;
            }
        }

        if(!fvg_found)
        {
            result.reason = "No FVG pattern found";
            return result;
        }

        result.bias = fvg_bull ? 1 : -1;
        int conditions_met = 0;

        // Sub-condition 1: FVG found
        conditions_met++;

        // Sub-condition 2: Gap size sufficient
        if(fvg_gap_size >= FVG_MinGapATR * atr)
            conditions_met++;

        // Sub-condition 3: Trend aligned with EMA200
        if((fvg_bull && ema_bull) || (!fvg_bull && !ema_bull))
            conditions_met++;

        // Sub-condition 4: Strong impulse candle
        if(strong_impulse)
            conditions_met++;

        result.score  = conditions_met / 4.0;
        result.reason = StringFormat("fvg=%s gap=%.4f(%.2fATR) ema_dir=%s cond=%d/4",
                                     fvg_bull ? "bull" : "bear",
                                     fvg_gap_size, fvg_gap_size / atr,
                                     ema_bull ? "bull" : "bear",
                                     conditions_met);
        return result;
    }
};
