//+------------------------------------------------------------------+
//| RSIDivergence.mqh                                                 |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Strategy index 2 — RSI Divergence
// Detects classic RSI divergence at extreme zones.
// Bull divergence: price makes lower low, RSI makes higher low.
// Bear divergence: price makes higher high, RSI makes lower high.
// Score: 4 sub-conditions, 25% each (0.0 – 1.0)
//
#pragma once
#include "BaseStrategy.mqh"

//+------------------------------------------------------------------+
//| Input parameters for RSI Divergence strategy                      |
//+------------------------------------------------------------------+
input int    RSI_Period        = 14;   // RSI period
input double RSI_Extreme_High  = 75.0; // Overbought threshold for divergence
input double RSI_Extreme_Low   = 25.0; // Oversold threshold for divergence
input int    RSI_DivLookback   = 20;   // Bars to scan for divergence pivot
input int    RSI_ATR_Period    = 14;   // ATR period for RSI divergence strategy

//+------------------------------------------------------------------+
//| CStratRSIDivergence                                               |
//+------------------------------------------------------------------+
class CStratRSIDivergence : public CBaseStrategy
{
private:
    int      m_rsi_handle;    // iRSI indicator handle
    double   m_rsi_buffer[];  // RSI values (series order)

public:
    CStratRSIDivergence()
    {
        m_name         = "RSIDivergence";
        m_magic_offset = 2;
        m_rsi_handle   = INVALID_HANDLE;
    }

    //------------------------------------------------------------------
    // Init — create RSI and ATR handles
    //------------------------------------------------------------------
    virtual void Init(int atr_period, ENUM_TIMEFRAMES tf) override
    {
        m_rsi_handle = iRSI(_Symbol, tf, RSI_Period, PRICE_CLOSE);
        if(m_rsi_handle == INVALID_HANDLE)
            PrintFormat("[RSIDivergence] RSI handle error %d", GetLastError());

        ArraySetAsSeries(m_rsi_buffer, true);
        m_atr.Init(atr_period, tf);
    }

    //------------------------------------------------------------------
    // Deinit — release handles
    //------------------------------------------------------------------
    virtual void Deinit() override
    {
        if(m_rsi_handle != INVALID_HANDLE)
        {
            IndicatorRelease(m_rsi_handle);
            m_rsi_handle = INVALID_HANDLE;
        }
        m_atr.Deinit();
    }

    //------------------------------------------------------------------
    // Evaluate — score 4 sub-conditions (25% each)
    //   1. RSI in extreme zone (< RSI_Extreme_Low or > RSI_Extreme_High)
    //   2. Price at multi-bar extreme (new high or low within lookback)
    //   3. Divergence confirmed (price new extreme, RSI is not)
    //   4. ATR expanding (current ATR > average)
    //------------------------------------------------------------------
    virtual StrategyScore Evaluate() override
    {
        StrategyScore result;
        result.name   = m_name;
        result.score  = 0.0;
        result.bias   = 0;
        result.reason = "";

        const int LOOKBACK = RSI_DivLookback;
        const int NEEDED   = LOOKBACK + 2;

        if(CopyBuffer(m_rsi_handle, 0, 0, NEEDED, m_rsi_buffer) < NEEDED)
        {
            result.reason = "RSI buffer not ready";
            return result;
        }

        double atr     = m_atr.GetATR(1);
        double atr_avg = m_atr.GetATRAverage(14);
        if(atr <= 0.0)
        {
            result.reason = "ATR not ready";
            return result;
        }

        double rsi_now   = m_rsi_buffer[1];  // last closed bar RSI
        double price_now = iClose(_Symbol, PERIOD_M15, 1);

        // Determine whether we are looking for bull or bear divergence
        bool check_bull = (rsi_now < RSI_Extreme_Low);
        bool check_bear = (rsi_now > RSI_Extreme_High);

        if(!check_bull && !check_bear)
        {
            result.reason = StringFormat("RSI=%.1f not in extreme zone", rsi_now);
            return result;
        }

        result.bias = check_bull ? 1 : -1;
        int conditions_met = 0;

        // Sub-condition 1: RSI in extreme zone
        conditions_met++;

        // Sub-condition 2: Price at multi-bar extreme
        int extreme_bar;
        double price_extreme;
        double rsi_at_extreme;

        if(check_bull)
        {
            // Looking for price to be at or near the lowest low in lookback
            extreme_bar    = iLowest(_Symbol, PERIOD_M15, MODE_LOW, LOOKBACK, 1);
            price_extreme  = iLow(_Symbol, PERIOD_M15, extreme_bar);
            bool at_extreme = (iLow(_Symbol, PERIOD_M15, 1) <= price_extreme * 1.001);
            if(at_extreme)
                conditions_met++;

            // Sub-condition 3: Bullish divergence — find prior RSI low that is lower
            // than current RSI while price made lower low
            rsi_at_extreme = m_rsi_buffer[extreme_bar];
            double rsi_pivot = rsi_at_extreme;
            // Scan lookback for a prior swing low in RSI that was lower
            for(int i = 2; i < NEEDED - 1; i++)
            {
                if(m_rsi_buffer[i] < m_rsi_buffer[i-1] &&
                   m_rsi_buffer[i] < m_rsi_buffer[i+1])
                {
                    // Found a prior RSI trough
                    if(m_rsi_buffer[i] < rsi_now &&
                       iLow(_Symbol, PERIOD_M15, i) < iLow(_Symbol, PERIOD_M15, 1))
                    {
                        // Price lower, RSI higher → bullish divergence
                        if(rsi_now > m_rsi_buffer[i])
                        {
                            conditions_met++;
                            break;
                        }
                    }
                }
            }
        }
        else
        {
            // Looking for price at the highest high in lookback
            extreme_bar   = iHighest(_Symbol, PERIOD_M15, MODE_HIGH, LOOKBACK, 1);
            price_extreme = iHigh(_Symbol, PERIOD_M15, extreme_bar);
            bool at_extreme = (iHigh(_Symbol, PERIOD_M15, 1) >= price_extreme * 0.999);
            if(at_extreme)
                conditions_met++;

            // Sub-condition 3: Bearish divergence — prior RSI peak was higher
            rsi_at_extreme = m_rsi_buffer[extreme_bar];
            for(int i = 2; i < NEEDED - 1; i++)
            {
                if(m_rsi_buffer[i] > m_rsi_buffer[i-1] &&
                   m_rsi_buffer[i] > m_rsi_buffer[i+1])
                {
                    if(m_rsi_buffer[i] > rsi_now &&
                       iHigh(_Symbol, PERIOD_M15, i) < iHigh(_Symbol, PERIOD_M15, 1))
                    {
                        // Price higher, RSI lower → bearish divergence
                        if(rsi_now < m_rsi_buffer[i])
                        {
                            conditions_met++;
                            break;
                        }
                    }
                }
            }
        }

        // Sub-condition 4: ATR expanding
        if(atr_avg > 0.0 && atr > atr_avg)
            conditions_met++;

        result.score  = conditions_met / 4.0;
        result.reason = StringFormat("rsi=%.1f bias=%s atr=%.4f avg=%.4f cond=%d/4",
                                     rsi_now, check_bull ? "bull" : "bear",
                                     atr, atr_avg, conditions_met);
        return result;
    }
};
