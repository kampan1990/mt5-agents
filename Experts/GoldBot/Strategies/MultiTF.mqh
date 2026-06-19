//+------------------------------------------------------------------+
//| MultiTF.mqh                                                       |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Strategy index 8 — Multi-Timeframe Alignment
// Uses H1 trend (EMA21 vs EMA50) and checks whether M15 price has
// pulled back to the H1 EMA21 area with a reversal candle.
// Score: 3 sub-conditions, ~33% each (0.0 – 1.0)
//
#pragma once
#include "BaseStrategy.mqh"

//+------------------------------------------------------------------+
//| Input parameters for Multi-TF strategy                            |
//+------------------------------------------------------------------+
input ENUM_TIMEFRAMES MTF_TrendTF      = PERIOD_H1;  // Trend timeframe
input int             MTF_EMA21Period  = 21;          // EMA period for H1 pullback
input int             MTF_EMA50Period  = 50;          // EMA period for H1 trend
input double          MTF_PullbackATR  = 0.3;         // Max distance from EMA21 in H1-ATR
input int             MTF_ATR_Period   = 14;          // ATR period for Multi-TF

//+------------------------------------------------------------------+
//| CStratMultiTF                                                     |
//+------------------------------------------------------------------+
class CStratMultiTF : public CBaseStrategy
{
private:
    int      m_h1_ema21_handle;   // iMA handle on H1 for EMA21
    int      m_h1_ema50_handle;   // iMA handle on H1 for EMA50
    int      m_h1_atr_handle;     // iATR handle on H1
    double   m_h1_ema21[];
    double   m_h1_ema50[];
    double   m_h1_atr[];

    //------------------------------------------------------------------
    // IsEngulfingOrInsideBreak
    // Detects bullish/bearish engulfing or inside bar breakout at shift=1.
    // is_bull: true to check for bullish reversal, false for bearish.
    //------------------------------------------------------------------
    bool IsEngulfingOrInsideBreak(int shift, bool is_bull)
    {
        double o0 = iOpen (_Symbol, PERIOD_M15, shift);
        double c0 = iClose(_Symbol, PERIOD_M15, shift);
        double o1 = iOpen (_Symbol, PERIOD_M15, shift + 1);
        double c1 = iClose(_Symbol, PERIOD_M15, shift + 1);

        if(is_bull)
        {
            // Bullish engulfing: current green candle body > previous red body
            bool bull_engulf = (c0 > o0) && (c1 < o1) &&
                               (c0 > o1) && (o0 < c1);
            return bull_engulf;
        }
        else
        {
            // Bearish engulfing
            bool bear_engulf = (c0 < o0) && (c1 > o1) &&
                               (c0 < o1) && (o0 > c1);
            return bear_engulf;
        }
    }

public:
    CStratMultiTF()
    {
        m_name             = "MultiTF";
        m_magic_offset     = 8;
        m_h1_ema21_handle  = INVALID_HANDLE;
        m_h1_ema50_handle  = INVALID_HANDLE;
        m_h1_atr_handle    = INVALID_HANDLE;
    }

    //------------------------------------------------------------------
    // Init — create H1 EMA handles and M15 ATR
    //------------------------------------------------------------------
    virtual void Init(int atr_period, ENUM_TIMEFRAMES tf) override
    {
        m_h1_ema21_handle = iMA(_Symbol, MTF_TrendTF, MTF_EMA21Period, 0, MODE_EMA, PRICE_CLOSE);
        m_h1_ema50_handle = iMA(_Symbol, MTF_TrendTF, MTF_EMA50Period, 0, MODE_EMA, PRICE_CLOSE);
        m_h1_atr_handle   = iATR(_Symbol, MTF_TrendTF, atr_period);

        if(m_h1_ema21_handle == INVALID_HANDLE ||
           m_h1_ema50_handle == INVALID_HANDLE ||
           m_h1_atr_handle   == INVALID_HANDLE)
            PrintFormat("[MultiTF] Handle creation error %d", GetLastError());

        ArraySetAsSeries(m_h1_ema21, true);
        ArraySetAsSeries(m_h1_ema50, true);
        ArraySetAsSeries(m_h1_atr,   true);

        m_atr.Init(atr_period, tf); // M15 ATR for reference
    }

    //------------------------------------------------------------------
    // Deinit — release all handles
    //------------------------------------------------------------------
    virtual void Deinit() override
    {
        if(m_h1_ema21_handle != INVALID_HANDLE) { IndicatorRelease(m_h1_ema21_handle); m_h1_ema21_handle = INVALID_HANDLE; }
        if(m_h1_ema50_handle != INVALID_HANDLE) { IndicatorRelease(m_h1_ema50_handle); m_h1_ema50_handle = INVALID_HANDLE; }
        if(m_h1_atr_handle   != INVALID_HANDLE) { IndicatorRelease(m_h1_atr_handle);   m_h1_atr_handle   = INVALID_HANDLE; }
        m_atr.Deinit();
    }

    //------------------------------------------------------------------
    // Evaluate — score 3 sub-conditions (~33% each)
    //   1. H1 trend bullish/bearish (EMA21 vs EMA50 on H1)
    //   2. M15 price pulled back to H1 EMA21 area (within MTF_PullbackATR × H1 ATR)
    //   3. Reversal candle present at pullback zone (engulfing or inside bar break)
    //------------------------------------------------------------------
    virtual StrategyScore Evaluate() override
    {
        StrategyScore result;
        result.name   = m_name;
        result.score  = 0.0;
        result.bias   = 0;
        result.reason = "";

        if(CopyBuffer(m_h1_ema21_handle, 0, 0, 3, m_h1_ema21) < 3 ||
           CopyBuffer(m_h1_ema50_handle, 0, 0, 3, m_h1_ema50) < 3 ||
           CopyBuffer(m_h1_atr_handle,   0, 0, 3, m_h1_atr)   < 3)
        {
            result.reason = "H1 buffer not ready";
            return result;
        }

        double h1_ema21 = m_h1_ema21[1];
        double h1_ema50 = m_h1_ema50[1];
        double h1_atr   = m_h1_atr[1];
        double price_now = iClose(_Symbol, PERIOD_M15, 1);

        bool h1_bull = (h1_ema21 > h1_ema50);
        result.bias  = h1_bull ? 1 : -1;

        int conditions_met = 0;

        // Sub-condition 1: H1 trend direction
        conditions_met++;

        // Sub-condition 2: M15 price near H1 EMA21
        double dist = MathAbs(price_now - h1_ema21);
        bool at_pullback = (h1_atr > 0.0 && dist <= MTF_PullbackATR * h1_atr);
        if(at_pullback)
            conditions_met++;

        // Sub-condition 3: Reversal candle at pullback
        if(at_pullback && IsEngulfingOrInsideBreak(1, h1_bull))
            conditions_met++;

        result.score  = conditions_met / 3.0;
        result.reason = StringFormat("h1_bull=%s ema21=%.2f ema50=%.2f dist=%.4f atr=%.4f cond=%d/3",
                                     h1_bull ? "Y" : "N",
                                     h1_ema21, h1_ema50, dist, h1_atr, conditions_met);
        return result;
    }
};
