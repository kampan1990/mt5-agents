//+------------------------------------------------------------------+
//| SessionFilter.mqh                                                 |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Controls when the EA is permitted to open new positions.
// Checks London+NY session window, daily profit/loss targets,
// floating profit target, and daily loss limit.
// Does NOT close positions — only gates new order entry.
//
#pragma once
#include "Logger.mqh"

//+------------------------------------------------------------------+
//| CSessionFilter                                                    |
//+------------------------------------------------------------------+
class CSessionFilter
{
private:
    CLogger*  m_logger;

    // Session window (UTC hours)
    int      m_start_hour;
    int      m_end_hour;

    // Daily limits
    double   m_daily_profit_pct;    // Stop after +N% gain
    double   m_daily_profit_usd;    // Stop after +$N gain
    double   m_daily_float_usd;     // Stop when floating profit >= $N
    double   m_daily_loss_pct;      // Stop after -N% loss

    // Baseline for daily calculations (set at day open)
    double   m_day_start_balance;
    double   m_day_start_equity;

    // State flags
    bool     m_daily_target_hit;
    int      m_current_day;         // Track day changes (mday 1-31)

public:
    CSessionFilter()
    {
        m_logger              = NULL;
        m_start_hour          = 7;
        m_end_hour            = 20;
        m_daily_profit_pct    = 3.0;
        m_daily_profit_usd    = 300.0;
        m_daily_float_usd     = 200.0;
        m_daily_loss_pct      = 2.0;
        m_day_start_balance   = 0.0;
        m_day_start_equity    = 0.0;
        m_daily_target_hit    = false;
        m_current_day         = -1;
    }

    //------------------------------------------------------------------
    // Init — store logger reference and all session parameters
    //------------------------------------------------------------------
    void Init(CLogger*  logger,
              int       start_hour,
              int       end_hour,
              double    daily_profit_pct,
              double    daily_profit_usd,
              double    daily_float_usd,
              double    daily_loss_pct)
    {
        m_logger           = logger;
        m_start_hour       = start_hour;
        m_end_hour         = end_hour;
        m_daily_profit_pct = daily_profit_pct;
        m_daily_profit_usd = daily_profit_usd;
        m_daily_float_usd  = daily_float_usd;
        m_daily_loss_pct   = daily_loss_pct;

        // Initialize day baseline with current account state
        double bal = AccountInfoDouble(ACCOUNT_BALANCE);
        double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
        OnNewDay(bal, eq);
    }

    //------------------------------------------------------------------
    // OnNewDay
    // Resets daily counters to current balance/equity.
    // Must be called when the trading date changes (checked in OnTick).
    //------------------------------------------------------------------
    void OnNewDay(double balance, double equity)
    {
        m_day_start_balance = balance;
        m_day_start_equity  = equity;
        m_daily_target_hit  = false;

        MqlDateTime dt;
        TimeToStruct(TimeCurrent(), dt);
        m_current_day = dt.day;

        if(m_logger != NULL)
            m_logger.LogInfo(StringFormat("New trading day: balance=%.2f equity=%.2f",
                                          balance, equity));
    }

    //------------------------------------------------------------------
    // CheckNewDay
    // Should be called at the start of each OnTick.
    // Detects if the calendar day has changed and resets counters.
    //------------------------------------------------------------------
    void CheckNewDay()
    {
        MqlDateTime dt;
        TimeToStruct(TimeCurrent(), dt);

        if(dt.day != m_current_day)
        {
            double bal = AccountInfoDouble(ACCOUNT_BALANCE);
            double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
            OnNewDay(bal, eq);
        }
    }

    //------------------------------------------------------------------
    // IsSessionActive
    // Returns true if current UTC time is within the London+NY window.
    // Returns false outside trading hours.
    //------------------------------------------------------------------
    bool IsSessionActive()
    {
        MqlDateTime dt;
        TimeToStruct(TimeCurrent(), dt);

        // Block weekends (Saturday=6, Sunday=0 in MQL5 day_of_week)
        if(dt.day_of_week == 0 || dt.day_of_week == 6)
            return false;

        return (dt.hour >= m_start_hour && dt.hour < m_end_hour);
    }

    //------------------------------------------------------------------
    // IsDailyLimitHit
    // Returns true if any daily limit has been reached.
    // current_equity: real-time account equity.
    // floating_profit: sum of all open position profits.
    //------------------------------------------------------------------
    bool IsDailyLimitHit(double current_equity, double floating_profit)
    {
        if(m_daily_target_hit) return true;
        if(m_day_start_balance <= 0.0) return false;

        // Realized P&L
        double daily_pnl_usd = current_equity - m_day_start_equity
                               - floating_profit; // Exclude open trades
        double daily_pnl_pct = (m_day_start_balance > 0.0)
                               ? daily_pnl_usd / m_day_start_balance * 100.0
                               : 0.0;

        // Check profit targets
        if(daily_pnl_pct >= m_daily_profit_pct)
        {
            m_daily_target_hit = true;
            if(m_logger != NULL)
                m_logger.LogDailyLimit("DailyProfitPct", daily_pnl_pct);
            return true;
        }
        if(daily_pnl_usd >= m_daily_profit_usd)
        {
            m_daily_target_hit = true;
            if(m_logger != NULL)
                m_logger.LogDailyLimit("DailyProfitUSD", daily_pnl_usd);
            return true;
        }

        // Floating profit target
        if(floating_profit >= m_daily_float_usd)
        {
            m_daily_target_hit = true;
            if(m_logger != NULL)
                m_logger.LogDailyLimit("FloatingTargetUSD", floating_profit);
            return true;
        }

        // Daily loss limit
        if(daily_pnl_pct <= -m_daily_loss_pct)
        {
            m_daily_target_hit = true;
            if(m_logger != NULL)
                m_logger.LogDailyLimit("DailyLossLimitPct", daily_pnl_pct);
            return true;
        }

        return false;
    }

    //------------------------------------------------------------------
    // ResetDailyFlags — force-reset the daily target flag
    // Useful for testing or manual override.
    //------------------------------------------------------------------
    void ResetDailyFlags()
    {
        m_daily_target_hit = false;
    }

    //------------------------------------------------------------------
    // GetDayStartBalance — accessor for RiskManager day-start equity sync
    //------------------------------------------------------------------
    double GetDayStartBalance() { return m_day_start_balance; }
    double GetDayStartEquity()  { return m_day_start_equity; }
    int    GetCurrentDay()      { return m_current_day; }
};
