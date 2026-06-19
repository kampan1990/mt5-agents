//+------------------------------------------------------------------+
//| NewsFade.mqh                                                      |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Strategy index 7 — News Fade
// Detects post-news price spikes and fades the move once liquidity
// returns to the pre-spike level. Uses hardcoded UTC news times for
// major gold-impacting events (no live news feed in MQL5).
// Score: 3 sub-conditions, ~33% each (0.0 – 1.0)
//
// Hardcoded major news windows (UTC):
//   08:30 — US CPI / PPI / NFP / GDP releases
//   14:30 — US economic data afternoon releases
//   19:00 — FOMC minutes (approximate)
//
#pragma once
#include "BaseStrategy.mqh"

//+------------------------------------------------------------------+
//| Input parameters for News Fade strategy                           |
//+------------------------------------------------------------------+
input double NF_SpikeATR    = 1.5;  // Spike size threshold in ATR units
input int    NF_FadeWindow  = 3;    // Bars after spike to look for fade
input int    NF_NewsWindow  = 30;   // Minutes around news time to consider active
input int    NF_ATR_Period  = 14;   // ATR period for News Fade

// Hardcoded news hours (UTC) — covers major XAUUSD catalysts
static const int NEWS_HOURS[] = {8, 13, 14, 18}; // 08:30, 13:30, 14:30, 18:00 UTC
static const int NEWS_MINS[]  = {30, 30, 30, 0};
static const int NUM_NEWS_TIMES = 4;

//+------------------------------------------------------------------+
//| CStratNewsFade                                                    |
//+------------------------------------------------------------------+
class CStratNewsFade : public CBaseStrategy
{
private:
    //------------------------------------------------------------------
    // IsNewsWindowActive
    // Returns true if the current time falls within NF_NewsWindow minutes
    // of any pre-configured news time.
    //------------------------------------------------------------------
    bool IsNewsWindowActive()
    {
        MqlDateTime dt;
        TimeToStruct(TimeCurrent(), dt);
        int current_minutes = dt.hour * 60 + dt.min;

        for(int n = 0; n < NUM_NEWS_TIMES; n++)
        {
            int news_minutes = NEWS_HOURS[n] * 60 + NEWS_MINS[n];
            if(MathAbs(current_minutes - news_minutes) <= NF_NewsWindow)
                return true;
        }
        return false;
    }

public:
    CStratNewsFade()
    {
        m_name         = "NewsFade";
        m_magic_offset = 7;
    }

    //------------------------------------------------------------------
    // Init — ATR only
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
    // Evaluate — score 3 sub-conditions (~33% each)
    //   1. News window active (within NF_NewsWindow min of news times)
    //   2. Spike detected (last NF_FadeWindow bars had bar with range > NF_SpikeATR × ATR)
    //   3. Liquidity return (price has partially retraced spike)
    //------------------------------------------------------------------
    virtual StrategyScore Evaluate() override
    {
        StrategyScore result;
        result.name   = m_name;
        result.score  = 0.0;
        result.bias   = 0;
        result.reason = "";

        double atr = m_atr.GetATR(1);
        if(atr <= 0.0)
        {
            result.reason = "ATR not ready";
            return result;
        }

        int conditions_met = 0;

        // Sub-condition 1: News window active
        bool news_active = IsNewsWindowActive();
        if(news_active)
            conditions_met++;
        else
        {
            result.reason = "No active news window";
            return result;
        }

        // Sub-condition 2: Detect spike candle within NF_FadeWindow bars
        bool  spike_found = false;
        bool  spike_bull  = false;
        double spike_open  = 0.0;
        double spike_close = 0.0;
        int bars_avail = (int)Bars(_Symbol, PERIOD_M15);
        int scan_end   = MathMin(NF_FadeWindow + 1, bars_avail - 1);

        for(int i = 1; i <= scan_end; i++)
        {
            double h = iHigh (_Symbol, PERIOD_M15, i);
            double l = iLow  (_Symbol, PERIOD_M15, i);
            double o = iOpen (_Symbol, PERIOD_M15, i);
            double c = iClose(_Symbol, PERIOD_M15, i);
            double range = h - l;

            if(range >= NF_SpikeATR * atr)
            {
                spike_found = true;
                spike_open  = o;
                spike_close = c;
                spike_bull  = (c > o); // Direction of the spike candle
                break;
            }
        }

        if(spike_found)
            conditions_met++;

        // Sub-condition 3: Liquidity return — price retracing toward pre-spike open
        if(spike_found)
        {
            double price_now   = iClose(_Symbol, PERIOD_M15, 1);
            // Price should be returning toward where the spike originated
            bool bull_fade = spike_bull  && (price_now < spike_close); // spike was up, now fading down
            bool bear_fade = !spike_bull && (price_now > spike_close); // spike was down, now fading up

            if(bull_fade || bear_fade)
            {
                conditions_met++;
                // Fade bias is opposite to the spike direction
                result.bias = spike_bull ? -1 : 1;
            }
            else
            {
                result.bias = spike_bull ? -1 : 1; // Still set bias for partial score
            }
        }

        result.score  = conditions_met / 3.0;
        result.reason = StringFormat("news=%s spike=%s fade_cond=%d/3",
                                     news_active ? "Y" : "N",
                                     spike_found  ? (spike_bull ? "bull" : "bear") : "none",
                                     conditions_met);
        return result;
    }
};
