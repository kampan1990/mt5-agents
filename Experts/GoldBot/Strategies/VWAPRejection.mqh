//+------------------------------------------------------------------+
//| VWAPRejection.mqh                                                 |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Strategy index 6 — VWAP Rejection
// Computes intraday VWAP from session start, then detects price
// rejection (long wick) at the VWAP band extremes with RSI confirmation.
// VWAP is reset at SessionStartHour (07:00 UTC) each day.
// Score: 4 sub-conditions, 25% each (0.0 – 1.0)
//
#pragma once
#include "BaseStrategy.mqh"

//+------------------------------------------------------------------+
//| Input parameters for VWAP Rejection strategy                      |
//+------------------------------------------------------------------+
input int    VWAP_SessionStart  = 7;    // Session start hour (UTC) for VWAP reset
input int    VWAP_SessionEnd    = 20;   // Session end hour (UTC)
input double VWAP_BandWidth     = 1.5;  // Band width multiplier (× ATR from VWAP)
input double VWAP_RSIExtreme    = 65.0; // RSI extreme for upper band; (100-this) for lower
input int    VWAP_RSIPeriod     = 14;   // RSI period
input int    VWAP_ATR_Period    = 14;   // ATR period for VWAP strategy

//+------------------------------------------------------------------+
//| CStratVWAPRejection                                               |
//+------------------------------------------------------------------+
class CStratVWAPRejection : public CBaseStrategy
{
private:
    int      m_rsi_handle;   // iRSI indicator handle
    double   m_rsi_buffer[]; // RSI values

    // VWAP state — resets each session
    double   m_vwap_sum_tp_vol;  // Running sum of (typical_price × volume)
    double   m_vwap_sum_vol;     // Running sum of volumes
    double   m_vwap;             // Current VWAP value
    datetime m_last_bar_time;    // Track bar time to avoid double-counting
    int      m_session_day;      // Day the session VWAP was started

    //------------------------------------------------------------------
    // UpdateVWAP
    // Iterates M15 bars from session start up to current bar and
    // accumulates volume × typical_price to compute VWAP.
    //------------------------------------------------------------------
    void RebuildVWAP(MqlDateTime &now_dt)
    {
        m_vwap_sum_tp_vol = 0.0;
        m_vwap_sum_vol    = 0.0;
        m_session_day     = now_dt.day;

        int bars = (int)Bars(_Symbol, PERIOD_M15);
        for(int i = bars - 1; i >= 1; i--)
        {
            datetime bar_time = iTime(_Symbol, PERIOD_M15, i);
            MqlDateTime bt;
            TimeToStruct(bar_time, bt);

            if(bt.day != now_dt.day) continue;
            if(bt.hour < VWAP_SessionStart) continue;

            double typical = (iHigh(_Symbol, PERIOD_M15, i) +
                              iLow (_Symbol, PERIOD_M15, i) +
                              iClose(_Symbol, PERIOD_M15, i)) / 3.0;
            double vol = (double)iVolume(_Symbol, PERIOD_M15, i);

            m_vwap_sum_tp_vol += typical * vol;
            m_vwap_sum_vol    += vol;
        }

        m_vwap = (m_vwap_sum_vol > 0.0) ? m_vwap_sum_tp_vol / m_vwap_sum_vol : 0.0;
    }

public:
    CStratVWAPRejection()
    {
        m_name              = "VWAPRejection";
        m_magic_offset      = 6;
        m_rsi_handle        = INVALID_HANDLE;
        m_vwap_sum_tp_vol   = 0.0;
        m_vwap_sum_vol      = 0.0;
        m_vwap              = 0.0;
        m_last_bar_time     = 0;
        m_session_day       = -1;
    }

    //------------------------------------------------------------------
    // Init — create RSI handle and ATR
    //------------------------------------------------------------------
    virtual void Init(int atr_period, ENUM_TIMEFRAMES tf) override
    {
        m_rsi_handle = iRSI(_Symbol, tf, VWAP_RSIPeriod, PRICE_CLOSE);
        if(m_rsi_handle == INVALID_HANDLE)
            PrintFormat("[VWAPRejection] RSI handle error %d", GetLastError());

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
    //   1. Session active (VWAP_SessionStart to VWAP_SessionEnd UTC)
    //   2. Price touched VWAP band (within VWAP ± VWAP_BandWidth × ATR)
    //   3. Rejection candle (wick > 60% of bar range toward VWAP)
    //   4. RSI at extreme (> VWAP_RSIExtreme for upper, < (100-RSIExtreme) for lower)
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

        // Sub-condition 1: Session active
        bool session_active = (current_hour >= VWAP_SessionStart &&
                               current_hour <  VWAP_SessionEnd);
        if(!session_active)
        {
            result.reason = StringFormat("Session not active UTC %02d:00", current_hour);
            return result;
        }

        // Rebuild VWAP on new day
        if(now_dt.day != m_session_day)
            RebuildVWAP(now_dt);

        if(CopyBuffer(m_rsi_handle, 0, 0, 3, m_rsi_buffer) < 3)
        {
            result.reason = "RSI buffer not ready";
            return result;
        }

        double atr = m_atr.GetATR(1);
        if(atr <= 0.0 || m_vwap <= 0.0)
        {
            result.reason = StringFormat("ATR=%.4f or VWAP=%.2f not ready", atr, m_vwap);
            return result;
        }

        double upper_band = m_vwap + VWAP_BandWidth * atr;
        double lower_band = m_vwap - VWAP_BandWidth * atr;

        double h1 = iHigh (_Symbol, PERIOD_M15, 1);
        double l1 = iLow  (_Symbol, PERIOD_M15, 1);
        double o1 = iOpen (_Symbol, PERIOD_M15, 1);
        double c1 = iClose(_Symbol, PERIOD_M15, 1);
        double rsi1 = m_rsi_buffer[1];

        bool touched_upper = (h1 >= upper_band);
        bool touched_lower = (l1 <= lower_band);

        int conditions_met = 0;

        // Sub-condition 1 confirmed
        conditions_met++;

        // Sub-condition 2: Price touched band
        if(!touched_upper && !touched_lower)
        {
            result.reason = StringFormat("No band touch: price=[%.2f,%.2f] bands=[%.2f,%.2f]",
                                         l1, h1, lower_band, upper_band);
            result.score  = conditions_met / 4.0;
            return result;
        }
        conditions_met++;
        result.bias = touched_upper ? -1 : 1; // Upper = bearish rejection; Lower = bullish

        // Sub-condition 3: Rejection candle (wick > 60% of range)
        double range = h1 - l1;
        if(range > 0.0)
        {
            double upper_wick = h1 - MathMax(o1, c1);
            double lower_wick = MathMin(o1, c1) - l1;

            if(touched_upper && upper_wick / range >= 0.60) conditions_met++;
            if(touched_lower && lower_wick / range >= 0.60) conditions_met++;
        }

        // Sub-condition 4: RSI at extreme
        if(touched_upper && rsi1 > VWAP_RSIExtreme)          conditions_met++;
        if(touched_lower && rsi1 < (100.0 - VWAP_RSIExtreme)) conditions_met++;

        result.score  = conditions_met / 4.0;
        result.reason = StringFormat("vwap=%.2f band=[%.2f,%.2f] rsi=%.1f bias=%s cond=%d/4",
                                     m_vwap, lower_band, upper_band, rsi1,
                                     result.bias > 0 ? "bull" : "bear", conditions_met);
        return result;
    }
};
