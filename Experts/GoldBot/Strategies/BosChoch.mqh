//+------------------------------------------------------------------+
//| BosChoch.mqh                                                      |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Strategy index 11 — BOS / CHoCH (Break of Structure / Change of Character)
// Confirms market structure breaks. BOS continues trend; CHoCH signals reversal.
// Requires pre-break consolidation for quality setup.
// Score: 5 sub-conditions, 20% each (0.0 – 1.0)
//
#pragma once
#include "BaseStrategy.mqh"

//+------------------------------------------------------------------+
//| Input parameters for BOS/CHoCH strategy                          |
//+------------------------------------------------------------------+
input int    BOS_StructureLookback   = 50;  // Bars to scan for structure
input int    BOS_ConsolidationBars   = 5;   // Min bars of tight range pre-break
input double BOS_ConsolidationATR    = 0.5; // Max range of consolidation in ATR
input int    BOS_ATR_Period          = 14;  // ATR period for BOS/CHoCH

//+------------------------------------------------------------------+
//| CStratBosChoch                                                    |
//+------------------------------------------------------------------+
class CStratBosChoch : public CBaseStrategy
{
private:
    //------------------------------------------------------------------
    // HasConsolidation
    // Returns true if the BOS_ConsolidationBars bars before break_bar
    // have a range <= BOS_ConsolidationATR × ATR.
    //------------------------------------------------------------------
    bool HasConsolidation(int break_bar, double atr)
    {
        if(break_bar + BOS_ConsolidationBars >= (int)Bars(_Symbol, PERIOD_M15))
            return false;

        double consol_high = -DBL_MAX;
        double consol_low  =  DBL_MAX;

        for(int i = break_bar + 1; i <= break_bar + BOS_ConsolidationBars; i++)
        {
            double h = iHigh(_Symbol, PERIOD_M15, i);
            double l = iLow (_Symbol, PERIOD_M15, i);
            if(h > consol_high) consol_high = h;
            if(l < consol_low)  consol_low  = l;
        }

        double range = consol_high - consol_low;
        return (range <= BOS_ConsolidationATR * atr);
    }

    //------------------------------------------------------------------
    // FindStructureLevels
    // Returns the previous swing high and swing low within the lookback.
    //------------------------------------------------------------------
    void FindStructureLevels(double &out_prev_high, double &out_prev_low,
                             int &out_bar_high,     int &out_bar_low)
    {
        out_prev_high = -DBL_MAX;
        out_prev_low  =  DBL_MAX;
        out_bar_high  = -1;
        out_bar_low   = -1;

        int bars_avail = (int)Bars(_Symbol, PERIOD_M15);
        int scan_end   = MathMin(BOS_StructureLookback, bars_avail - 3);

        for(int i = 2; i <= scan_end; i++)
        {
            double h = iHigh(_Symbol, PERIOD_M15, i);
            double l = iLow (_Symbol, PERIOD_M15, i);

            // Fractal high
            if(h > iHigh(_Symbol, PERIOD_M15, i-1) &&
               h > iHigh(_Symbol, PERIOD_M15, i+1) &&
               h > out_prev_high)
            {
                out_prev_high = h;
                out_bar_high  = i;
            }

            // Fractal low
            if(l < iLow(_Symbol, PERIOD_M15, i-1) &&
               l < iLow(_Symbol, PERIOD_M15, i+1) &&
               l < out_prev_low)
            {
                out_prev_low = l;
                out_bar_low  = i;
            }
        }
    }

public:
    CStratBosChoch()
    {
        m_name         = "BosChoch";
        m_magic_offset = 11;
    }

    //------------------------------------------------------------------
    // Init — only ATR needed
    //------------------------------------------------------------------
    virtual void Init(int atr_period, ENUM_TIMEFRAMES tf) override
    {
        m_atr.Init(atr_period, tf);
    }

    //------------------------------------------------------------------
    // Deinit — release ATR
    //------------------------------------------------------------------
    virtual void Deinit() override
    {
        m_atr.Deinit();
    }

    //------------------------------------------------------------------
    // Evaluate — score 5 sub-conditions (20% each)
    //   1. Structure break confirmed (close beyond previous fractal high/low)
    //   2. CHoCH confirmed (first opposing break after prior trend)
    //   3. Pre-break consolidation (BOS_ConsolidationBars tight range)
    //   4. ATR momentum at break (ATR > ATR average)
    //   5. Break direction is clear (break candle body > 50% of range)
    //------------------------------------------------------------------
    virtual StrategyScore Evaluate() override
    {
        StrategyScore result;
        result.name   = m_name;
        result.score  = 0.0;
        result.bias   = 0;
        result.reason = "";

        double atr     = m_atr.GetATR(1);
        double atr_avg = m_atr.GetATRAverage(14);
        if(atr <= 0.0)
        {
            result.reason = "ATR not ready";
            return result;
        }

        double prev_high, prev_low;
        int    bar_high, bar_low;
        FindStructureLevels(prev_high, prev_low, bar_high, bar_low);

        if(bar_high < 0 || bar_low < 0)
        {
            result.reason = "No structure levels found";
            return result;
        }

        double close1 = iClose(_Symbol, PERIOD_M15, 1);
        double open1  = iOpen (_Symbol, PERIOD_M15, 1);
        double high1  = iHigh (_Symbol, PERIOD_M15, 1);
        double low1   = iLow  (_Symbol, PERIOD_M15, 1);

        // Detect current break
        bool bull_break = (close1 > prev_high); // BOS to upside
        bool bear_break = (close1 < prev_low);  // BOS to downside

        if(!bull_break && !bear_break)
        {
            result.reason = StringFormat("No BOS: close=%.2f struct=[%.2f,%.2f]",
                                         close1, prev_low, prev_high);
            return result;
        }

        result.bias = bull_break ? 1 : -1;
        int conditions_met = 0;

        // Sub-condition 1: Structure break confirmed
        conditions_met++;

        // Sub-condition 2: CHoCH (reversal break — prior bias opposite)
        // If bull_break but recent bars were predominantly bearish → CHoCH
        double close5 = iClose(_Symbol, PERIOD_M15, 5);
        bool prior_bear = (close5 > close1); // Price came from above (was in downtrend)
        bool prior_bull = (close5 < close1); // Price came from below (was in uptrend)

        bool is_choch = (bull_break && prior_bear) || (bear_break && prior_bull);
        if(is_choch)
            conditions_met++;

        // Sub-condition 3: Pre-break consolidation
        int break_bar = 1; // The break just happened at bar[1]
        if(HasConsolidation(break_bar, atr))
            conditions_met++;

        // Sub-condition 4: ATR momentum at break
        if(atr_avg > 0.0 && atr > atr_avg)
            conditions_met++;

        // Sub-condition 5: Break candle body > 50% of range
        double range = high1 - low1;
        double body  = MathAbs(close1 - open1);
        if(range > 0.0 && body / range >= 0.50)
            conditions_met++;

        result.score  = conditions_met / 5.0;
        result.reason = StringFormat("break=%s prev=[%.2f,%.2f] choch=%s consol=%s atr=%.4f cond=%d/5",
                                     bull_break ? "bull" : "bear",
                                     prev_low, prev_high,
                                     is_choch ? "Y" : "N",
                                     HasConsolidation(1, atr) ? "Y" : "N",
                                     atr, conditions_met);
        return result;
    }
};
