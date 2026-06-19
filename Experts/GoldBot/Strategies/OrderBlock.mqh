//+------------------------------------------------------------------+
//| OrderBlock.mqh                                                    |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Strategy index 4 — ICT Order Block
// Identifies the last opposing candle before a strong impulsive move,
// then waits for price to return to that zone (the order block).
// Score: 4 sub-conditions, 25% each (0.0 – 1.0)
//
#pragma once
#include "BaseStrategy.mqh"

//+------------------------------------------------------------------+
//| Input parameters for Order Block strategy                         |
//+------------------------------------------------------------------+
input int    OB_Lookback      = 50;   // Bars to scan for OB candle
input double OB_ATRThreshold  = 1.0;  // Minimum ATR in USD to trade
input int    OB_EMA_Fast      = 50;   // EMA50 for trend filter
input int    OB_EMA_Slow      = 200;  // EMA200 for trend filter
input int    OB_ATR_Period    = 14;   // ATR period for OB strategy

//+------------------------------------------------------------------+
//| CStratOrderBlock                                                  |
//+------------------------------------------------------------------+
class CStratOrderBlock : public CBaseStrategy
{
private:
    int      m_ema50_handle;    // iMA handle for EMA50
    int      m_ema200_handle;   // iMA handle for EMA200
    double   m_ema50[];
    double   m_ema200[];

    // Stored order block zone
    double   m_ob_high;         // High of identified OB candle
    double   m_ob_low;          // Low of identified OB candle
    bool     m_ob_bull;         // true = bullish OB, false = bearish OB
    bool     m_ob_valid;        // true if OB currently active

public:
    CStratOrderBlock()
    {
        m_name          = "OrderBlock";
        m_magic_offset  = 4;
        m_ema50_handle  = INVALID_HANDLE;
        m_ema200_handle = INVALID_HANDLE;
        m_ob_high       = 0.0;
        m_ob_low        = 0.0;
        m_ob_bull       = false;
        m_ob_valid      = false;
    }

    //------------------------------------------------------------------
    // Init — create EMA handles and ATR
    //------------------------------------------------------------------
    virtual void Init(int atr_period, ENUM_TIMEFRAMES tf) override
    {
        m_ema50_handle  = iMA(_Symbol, tf, OB_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
        m_ema200_handle = iMA(_Symbol, tf, OB_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

        if(m_ema50_handle  == INVALID_HANDLE ||
           m_ema200_handle == INVALID_HANDLE)
            PrintFormat("[OrderBlock] EMA handle error %d", GetLastError());

        ArraySetAsSeries(m_ema50,  true);
        ArraySetAsSeries(m_ema200, true);
        m_atr.Init(atr_period, tf);
    }

    //------------------------------------------------------------------
    // Deinit — release handles
    //------------------------------------------------------------------
    virtual void Deinit() override
    {
        if(m_ema50_handle  != INVALID_HANDLE) { IndicatorRelease(m_ema50_handle);  m_ema50_handle  = INVALID_HANDLE; }
        if(m_ema200_handle != INVALID_HANDLE) { IndicatorRelease(m_ema200_handle); m_ema200_handle = INVALID_HANDLE; }
        m_atr.Deinit();
    }

    //------------------------------------------------------------------
    // Evaluate — score 4 sub-conditions (25% each)
    //   1. OB candle present (last opposing candle before strong move)
    //   2. Price returned to OB zone
    //   3. ATR > OB_ATRThreshold (market not dead)
    //   4. EMA50 and EMA200 align with OB direction
    //------------------------------------------------------------------
    virtual StrategyScore Evaluate() override
    {
        StrategyScore result;
        result.name   = m_name;
        result.score  = 0.0;
        result.bias   = 0;
        result.reason = "";

        const int NEEDED = OB_Lookback + 4;
        int bars_avail = (int)Bars(_Symbol, PERIOD_M15);

        if(CopyBuffer(m_ema50_handle,  0, 0, 4, m_ema50)  < 4 ||
           CopyBuffer(m_ema200_handle, 0, 0, 4, m_ema200) < 4)
        {
            result.reason = "EMA buffer not ready";
            return result;
        }

        double atr     = m_atr.GetATR(1);
        double atr_usd = m_atr.ToUSD(atr);
        if(atr <= 0.0)
        {
            result.reason = "ATR not ready";
            return result;
        }

        // EMA trend
        bool ema_bull = (m_ema50[1] > m_ema200[1]);

        double price_now = iClose(_Symbol, PERIOD_M15, 1);

        // Scan for OB: last opposing candle before a 2-candle strong move
        m_ob_valid = false;
        int scan_end = MathMin(OB_Lookback, bars_avail - 4);

        for(int i = 2; i <= scan_end; i++)
        {
            double o_i  = iOpen (_Symbol, PERIOD_M15, i);
            double c_i  = iClose(_Symbol, PERIOD_M15, i);
            double o_i1 = iOpen (_Symbol, PERIOD_M15, i - 1);
            double c_i1 = iClose(_Symbol, PERIOD_M15, i - 1);

            bool bar_i_bear  = (c_i  < o_i);
            bool bar_i1_bull = (c_i1 > o_i1);

            // Bullish OB: bearish candle followed by strong bullish move
            if(bar_i_bear && bar_i1_bull)
            {
                double move = MathAbs(c_i1 - o_i1);
                if(move >= 1.5 * atr)
                {
                    m_ob_high  = iHigh(_Symbol, PERIOD_M15, i);
                    m_ob_low   = iLow (_Symbol, PERIOD_M15, i);
                    m_ob_bull  = true;
                    m_ob_valid = true;
                    break;
                }
            }

            bool bar_i_bull  = (c_i  > o_i);
            bool bar_i1_bear = (c_i1 < o_i1);

            // Bearish OB: bullish candle followed by strong bearish move
            if(bar_i_bull && bar_i1_bear)
            {
                double move = MathAbs(c_i1 - o_i1);
                if(move >= 1.5 * atr)
                {
                    m_ob_high  = iHigh(_Symbol, PERIOD_M15, i);
                    m_ob_low   = iLow (_Symbol, PERIOD_M15, i);
                    m_ob_bull  = false;
                    m_ob_valid = true;
                    break;
                }
            }
        }

        if(!m_ob_valid)
        {
            result.reason = "No valid order block found";
            return result;
        }

        result.bias = m_ob_bull ? 1 : -1;
        int conditions_met = 0;

        // Sub-condition 1: OB candle found
        conditions_met++;

        // Sub-condition 2: Price is back in OB zone
        bool price_in_ob = (price_now >= m_ob_low && price_now <= m_ob_high);
        if(price_in_ob)
            conditions_met++;

        // Sub-condition 3: ATR active enough
        if(atr_usd >= OB_ATRThreshold)
            conditions_met++;

        // Sub-condition 4: EMA trend aligned with OB
        if((m_ob_bull && ema_bull) || (!m_ob_bull && !ema_bull))
            conditions_met++;

        result.score  = conditions_met / 4.0;
        result.reason = StringFormat("ob=%s zone=[%.2f,%.2f] price=%.2f ema_bull=%s cond=%d/4",
                                     m_ob_bull ? "bull" : "bear",
                                     m_ob_low, m_ob_high, price_now,
                                     ema_bull ? "Y" : "N", conditions_met);
        return result;
    }
};
