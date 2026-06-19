//+------------------------------------------------------------------+
//| SupplyDemand.mqh                                                  |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Strategy index 1 — Supply & Demand Zones
// Identifies S/D zones from price extremes, checks RSI alignment,
// ATR momentum, and candle pattern at the zone.
// Score: 5 sub-conditions, 20% each (0.0 – 1.0)
//
#pragma once
#include "BaseStrategy.mqh"

//+------------------------------------------------------------------+
//| Input parameters for Supply & Demand strategy                     |
//+------------------------------------------------------------------+
input int    SD_ZoneLookback   = 50;   // Bars to scan for S/D zones
input int    SD_ZoneStrength   = 2;    // Min candles to confirm zone
input int    SD_RSIPeriod      = 14;   // RSI period
input double SD_RSIOverbought  = 70.0; // RSI overbought level
input double SD_RSIOversold    = 30.0; // RSI oversold level
input int    SD_ATR_Period     = 14;   // ATR period for S/D strategy

//+------------------------------------------------------------------+
//| CStratSupplyDemand                                                |
//+------------------------------------------------------------------+
class CStratSupplyDemand : public CBaseStrategy
{
private:
    int      m_rsi_handle;   // iRSI indicator handle
    double   m_rsi_buffer[]; // RSI values buffer

    //------------------------------------------------------------------
    // IsPinBar — returns true if bar[shift] is a pin bar
    // Pin bar: wick > 60% of total range, small body
    //------------------------------------------------------------------
    bool IsPinBar(int shift)
    {
        double o = iOpen (_Symbol, PERIOD_M15, shift);
        double h = iHigh (_Symbol, PERIOD_M15, shift);
        double l = iLow  (_Symbol, PERIOD_M15, shift);
        double c = iClose(_Symbol, PERIOD_M15, shift);

        double range = h - l;
        if(range < DBL_EPSILON) return false;

        double body       = MathAbs(c - o);
        double upper_wick = h - MathMax(o, c);
        double lower_wick = MathMin(o, c) - l;
        double wick       = MathMax(upper_wick, lower_wick);

        return (wick / range >= 0.6 && body / range <= 0.35);
    }

    //------------------------------------------------------------------
    // IsEngulfing — returns true if bar[shift] engulfs bar[shift+1]
    //------------------------------------------------------------------
    bool IsEngulfing(int shift)
    {
        double o0 = iOpen (_Symbol, PERIOD_M15, shift);
        double c0 = iClose(_Symbol, PERIOD_M15, shift);
        double o1 = iOpen (_Symbol, PERIOD_M15, shift + 1);
        double c1 = iClose(_Symbol, PERIOD_M15, shift + 1);

        double body0 = MathAbs(c0 - o0);
        double body1 = MathAbs(c1 - o1);

        if(body1 < DBL_EPSILON) return false;
        return body0 > body1;
    }

public:
    CStratSupplyDemand()
    {
        m_name         = "SupplyDemand";
        m_magic_offset = 1;
        m_rsi_handle   = INVALID_HANDLE;
    }

    //------------------------------------------------------------------
    // Init — create RSI handle and ATR
    //------------------------------------------------------------------
    virtual void Init(int atr_period, ENUM_TIMEFRAMES tf) override
    {
        m_rsi_handle = iRSI(_Symbol, tf, SD_RSIPeriod, PRICE_CLOSE);
        if(m_rsi_handle == INVALID_HANDLE)
            PrintFormat("[SupplyDemand] RSI handle error %d", GetLastError());

        ArraySetAsSeries(m_rsi_buffer, true);
        m_atr.Init(atr_period, tf);
    }

    //------------------------------------------------------------------
    // Deinit — release all indicator handles
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
    // Evaluate — score 5 sub-conditions (20% each)
    //   1. Price near S/D zone (within 0.3 × ATR of recent high/low)
    //   2. Zone breakout confirmed (price previously closed beyond zone)
    //   3. RSI aligned (RSI < 50 at demand, RSI > 50 at supply)
    //   4. ATR momentum (current ATR > 1.2 × ATR average)
    //   5. Candle pattern (pin bar or engulfing at zone)
    //------------------------------------------------------------------
    virtual StrategyScore Evaluate() override
    {
        StrategyScore result;
        result.name  = m_name;
        result.score = 0.0;
        result.bias  = 0;
        result.reason = "";

        const int LOOKBACK = SD_ZoneLookback;
        const int REQUIRED = LOOKBACK + 2;

        if(CopyBuffer(m_rsi_handle, 0, 0, 3, m_rsi_buffer) < 3)
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

        // Find recent high/low as proxy for S/D zones
        int    highest_bar = iHighest(_Symbol, PERIOD_M15, MODE_HIGH, LOOKBACK, 2);
        int    lowest_bar  = iLowest (_Symbol, PERIOD_M15, MODE_LOW,  LOOKBACK, 2);
        double zone_high   = iHigh(_Symbol, PERIOD_M15, highest_bar);
        double zone_low    = iLow (_Symbol, PERIOD_M15, lowest_bar);
        double price_now   = iClose(_Symbol, PERIOD_M15, 1);
        double rsi_now     = m_rsi_buffer[1];

        // Determine bias: are we near demand (low) or supply (high)?
        bool near_demand = (MathAbs(price_now - zone_low)  <= 0.3 * atr);
        bool near_supply = (MathAbs(price_now - zone_high) <= 0.3 * atr);

        if(!near_demand && !near_supply)
        {
            result.reason = "Not near any zone";
            return result;
        }

        bool is_demand = near_demand; // demand → buy bias
        result.bias    = is_demand ? 1 : -1;

        int conditions_met = 0;

        // Sub-condition 1: Price near zone
        conditions_met++; // already confirmed above

        // Sub-condition 2: Zone breakout (price was outside zone before, now back)
        bool breakout_confirmed = false;
        for(int i = 2; i < MathMin(REQUIRED, Bars(_Symbol, PERIOD_M15) - 1); i++)
        {
            double c = iClose(_Symbol, PERIOD_M15, i);
            if(is_demand && c < zone_low)  { breakout_confirmed = true; break; }
            if(!is_demand && c > zone_high) { breakout_confirmed = true; break; }
        }
        if(breakout_confirmed)
            conditions_met++;

        // Sub-condition 3: RSI aligned
        if(is_demand && rsi_now < 50.0)  conditions_met++;
        if(!is_demand && rsi_now > 50.0) conditions_met++;

        // Sub-condition 4: ATR momentum (current ATR > 1.2 × average)
        if(atr_avg > 0.0 && atr > 1.2 * atr_avg)
            conditions_met++;

        // Sub-condition 5: Candle pattern at zone (pin bar or engulfing)
        if(IsPinBar(1) || IsEngulfing(1))
            conditions_met++;

        result.score  = conditions_met / 5.0;
        result.reason = StringFormat("near=%s rsi=%.1f atr=%.4f avg=%.4f cond=%d/5",
                                     is_demand ? "demand" : "supply",
                                     rsi_now, atr, atr_avg, conditions_met);
        return result;
    }
};
