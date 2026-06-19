//+------------------------------------------------------------------+
//| LondonBreakout.mqh                                                |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Strategy index 5 — London Breakout
// Detects tight Asian session range then prices breaking out at
// London open (07:00-10:00 UTC). Requires ATR expansion on breakout.
// Score: 4 sub-conditions, 25% each (0.0 – 1.0)
//
#pragma once
#include "BaseStrategy.mqh"

//+------------------------------------------------------------------+
//| Input parameters for London Breakout strategy                     |
//+------------------------------------------------------------------+
input int    LB_AsianStartHour  = 2;    // Asian session start hour UTC
input int    LB_AsianEndHour    = 7;    // Asian session end hour UTC
input int    LB_LondonStartHour = 7;    // London session open hour UTC
input int    LB_LondonEndHour   = 10;   // London session close (breakout window) UTC
input double LB_RangeATRMin     = 0.5;  // Min range vs ATR for breakout (price must break by this)
input int    LB_ATR_Period      = 14;   // ATR period for London Breakout

//+------------------------------------------------------------------+
//| CStratLondonBreakout                                              |
//+------------------------------------------------------------------+
class CStratLondonBreakout : public CBaseStrategy
{
private:
    // Cached Asian range
    double   m_asian_high;
    double   m_asian_low;
    bool     m_asian_range_set;
    datetime m_asian_range_date; // Date the Asian range was calculated for

    //------------------------------------------------------------------
    // UpdateAsianRange
    // Recalculates the Asian session high/low for today.
    // Iterates through closed M15 bars in the Asian session window.
    //------------------------------------------------------------------
    void UpdateAsianRange()
    {
        MqlDateTime dt;
        TimeToStruct(TimeCurrent(), dt);

        // Reset range for today
        m_asian_high = -DBL_MAX;
        m_asian_low  =  DBL_MAX;
        m_asian_range_set = false;

        int bars = (int)Bars(_Symbol, PERIOD_M15);
        for(int i = 1; i < bars; i++)
        {
            datetime bar_time = iTime(_Symbol, PERIOD_M15, i);
            MqlDateTime bt;
            TimeToStruct(bar_time, bt);

            // Only bars from today's Asian session window
            if(bt.year != dt.year || bt.mon != dt.mon || bt.day != dt.day) break;
            if(bt.hour < LB_AsianStartHour || bt.hour >= LB_AsianEndHour)  continue;

            double h = iHigh(_Symbol, PERIOD_M15, i);
            double l = iLow (_Symbol, PERIOD_M15, i);
            if(h > m_asian_high) m_asian_high = h;
            if(l < m_asian_low)  m_asian_low  = l;
            m_asian_range_set = true;
        }

        if(m_asian_range_set)
            m_asian_range_date = iTime(_Symbol, PERIOD_M15, 0);
    }

public:
    CStratLondonBreakout()
    {
        m_name             = "LondonBreakout";
        m_magic_offset     = 5;
        m_asian_high       = 0.0;
        m_asian_low        = 0.0;
        m_asian_range_set  = false;
        m_asian_range_date = 0;
    }

    //------------------------------------------------------------------
    // Init — only ATR needed for this strategy
    //------------------------------------------------------------------
    virtual void Init(int atr_period, ENUM_TIMEFRAMES tf) override
    {
        m_atr.Init(atr_period, tf);
    }

    //------------------------------------------------------------------
    // Deinit — release ATR handle
    //------------------------------------------------------------------
    virtual void Deinit() override
    {
        m_atr.Deinit();
    }

    //------------------------------------------------------------------
    // Evaluate — score 4 sub-conditions (25% each)
    //   1. London session active (07:00-10:00 UTC)
    //   2. Asian range established (high and low found for today)
    //   3. Price breaks Asian range by >= LB_RangeATRMin × ATR
    //   4. ATR expanding vs previous bar ATR
    //------------------------------------------------------------------
    virtual StrategyScore Evaluate() override
    {
        StrategyScore result;
        result.name   = m_name;
        result.score  = 0.0;
        result.bias   = 0;
        result.reason = "";

        MqlDateTime now_dt;
        TimeToStruct(TimeCurrent(), now_dt);
        int current_hour = now_dt.hour;

        // Sub-condition 1: London session active
        bool london_active = (current_hour >= LB_LondonStartHour &&
                              current_hour <  LB_LondonEndHour);
        if(!london_active)
        {
            result.reason = StringFormat("London not active (UTC %02d:00)", current_hour);
            return result;
        }

        // Update Asian range once per day
        MqlDateTime range_dt;
        TimeToStruct(m_asian_range_date, range_dt);
        if(range_dt.day != now_dt.day)
            UpdateAsianRange();

        double atr      = m_atr.GetATR(1);
        double atr_prev = m_atr.GetATR(2);
        if(atr <= 0.0)
        {
            result.reason = "ATR not ready";
            return result;
        }

        double price_now = iClose(_Symbol, PERIOD_M15, 1);
        int conditions_met = 0;

        // Sub-condition 1 (confirmed above)
        conditions_met++;

        // Sub-condition 2: Asian range established
        if(m_asian_range_set && m_asian_high > m_asian_low)
            conditions_met++;
        else
        {
            result.reason = "Asian range not set";
            result.score  = conditions_met / 4.0;
            return result;
        }

        // Sub-condition 3: Price breaks Asian range
        bool bull_break = (price_now > m_asian_high + LB_RangeATRMin * atr);
        bool bear_break = (price_now < m_asian_low  - LB_RangeATRMin * atr);

        if(bull_break || bear_break)
        {
            conditions_met++;
            result.bias = bull_break ? 1 : -1;
        }
        else
        {
            result.reason = StringFormat("No breakout: price=%.2f range=[%.2f,%.2f]",
                                         price_now, m_asian_low, m_asian_high);
            result.score  = conditions_met / 4.0;
            return result;
        }

        // Sub-condition 4: ATR expanding
        if(atr_prev > 0.0 && atr > atr_prev)
            conditions_met++;

        result.score  = conditions_met / 4.0;
        result.reason = StringFormat("hr=%d break=%s range=[%.2f,%.2f] price=%.2f atr=%.4f cond=%d/4",
                                     current_hour, bull_break ? "bull" : "bear",
                                     m_asian_low, m_asian_high, price_now, atr,
                                     conditions_met);
        return result;
    }
};
