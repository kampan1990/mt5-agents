//+------------------------------------------------------------------+
//| EMAcross.mqh                                                      |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Strategy index 0 — EMA Cross
// Evaluates EMA50/EMA200 trend alignment plus ATR momentum.
// Score: 4 sub-conditions, 25% each (0.0 – 1.0)
// Bias: EMA50 > EMA200 → bullish (+1), EMA50 < EMA200 → bearish (-1)
//
#pragma once
#include "BaseStrategy.mqh"

//+------------------------------------------------------------------+
//| Input parameters for EMA Cross strategy                           |
//+------------------------------------------------------------------+
input int    EMAFast           = 50;   // Fast EMA period
input int    EMASlow           = 200;  // Slow EMA period
input double EMAProximityATR   = 0.5;  // Max price-to-EMA50 distance in ATR units
input int    EMA_ATR_Period    = 14;   // ATR period for EMA Cross

//+------------------------------------------------------------------+
//| CStratEMAcross                                                    |
//+------------------------------------------------------------------+
class CStratEMAcross : public CBaseStrategy
{
private:
    int      m_ema_fast_handle;  // iMA handle for EMA50
    int      m_ema_slow_handle;  // iMA handle for EMA200
    double   m_ema_fast[];       // EMA50 buffer
    double   m_ema_slow[];       // EMA200 buffer

public:
    CStratEMAcross()
    {
        m_name          = "EMAcross";
        m_magic_offset  = 0;
        m_ema_fast_handle = INVALID_HANDLE;
        m_ema_slow_handle = INVALID_HANDLE;
    }

    //------------------------------------------------------------------
    // Init — create iMA handles for fast and slow EMA, plus ATR
    //------------------------------------------------------------------
    virtual void Init(int atr_period, ENUM_TIMEFRAMES tf) override
    {
        m_ema_fast_handle = iMA(_Symbol, tf, EMAFast, 0, MODE_EMA, PRICE_CLOSE);
        m_ema_slow_handle = iMA(_Symbol, tf, EMASlow, 0, MODE_EMA, PRICE_CLOSE);

        if(m_ema_fast_handle == INVALID_HANDLE || m_ema_slow_handle == INVALID_HANDLE)
            PrintFormat("[EMAcross] Init error: fast=%d slow=%d err=%d",
                        m_ema_fast_handle, m_ema_slow_handle, GetLastError());

        ArraySetAsSeries(m_ema_fast, true);
        ArraySetAsSeries(m_ema_slow, true);

        m_atr.Init(atr_period, tf);
    }

    //------------------------------------------------------------------
    // Deinit — release all indicator handles
    //------------------------------------------------------------------
    virtual void Deinit() override
    {
        if(m_ema_fast_handle != INVALID_HANDLE)
        {
            IndicatorRelease(m_ema_fast_handle);
            m_ema_fast_handle = INVALID_HANDLE;
        }
        if(m_ema_slow_handle != INVALID_HANDLE)
        {
            IndicatorRelease(m_ema_slow_handle);
            m_ema_slow_handle = INVALID_HANDLE;
        }
        m_atr.Deinit();
    }

    //------------------------------------------------------------------
    // Evaluate — score 4 sub-conditions (25% each)
    //   1. EMA50 above/below EMA200 (trend direction)
    //   2. Price within EMAProximityATR × ATR of EMA50
    //   3. ATR > ATR 14-bar average (ATR active)
    //   4. EMA50/EMA200 crossover within last 5 bars
    //------------------------------------------------------------------
    virtual StrategyScore Evaluate() override
    {
        StrategyScore result;
        result.name  = m_name;
        result.score = 0.0;
        result.bias  = 0;
        result.reason = "";

        // Require 10 bars of EMA data and ATR
        const int REQUIRED = 10;

        if(CopyBuffer(m_ema_fast_handle, 0, 0, REQUIRED, m_ema_fast) < REQUIRED ||
           CopyBuffer(m_ema_slow_handle, 0, 0, REQUIRED, m_ema_slow) < REQUIRED)
        {
            result.reason = "Buffer not ready";
            return result;
        }

        double atr     = m_atr.GetATR(1);
        double atr_avg = m_atr.GetATRAverage(14);
        if(atr <= 0.0)
        {
            result.reason = "ATR not ready";
            return result;
        }

        double fast1   = m_ema_fast[1];  // previous closed bar EMA50
        double slow1   = m_ema_slow[1];  // previous closed bar EMA200
        double price1  = iClose(_Symbol, PERIOD_M15, 1);

        // Determine structural bias from EMA relationship
        bool is_bull = (fast1 > slow1);
        result.bias  = is_bull ? 1 : -1;

        int conditions_met = 0;

        // Sub-condition 1: EMA50 direction vs EMA200
        // Bull: EMA50 > EMA200, Bear: EMA50 < EMA200
        conditions_met++; // always true by definition of bias above

        // Sub-condition 2: Price within proximity of EMA50
        double dist_to_ema50 = MathAbs(price1 - fast1);
        if(dist_to_ema50 <= EMAProximityATR * atr)
            conditions_met++;

        // Sub-condition 3: ATR active (above its own average)
        if(atr_avg > 0.0 && atr > atr_avg)
            conditions_met++;

        // Sub-condition 4: Crossover within last 5 bars
        bool cross_found = false;
        for(int i = 1; i <= 5; i++)
        {
            bool bull_now  = (m_ema_fast[i]   > m_ema_slow[i]);
            bool bull_prev = (m_ema_fast[i+1] > m_ema_slow[i+1]);
            if(bull_now != bull_prev)
            {
                cross_found = true;
                break;
            }
        }
        if(cross_found)
            conditions_met++;

        result.score  = conditions_met / 4.0;
        result.reason = StringFormat("fast=%.2f slow=%.2f price=%.2f atr=%.4f cond=%d/4",
                                     fast1, slow1, price1, atr, conditions_met);
        return result;
    }
};
