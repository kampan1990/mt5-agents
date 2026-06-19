//+------------------------------------------------------------------+
//| RiskManager.mqh                                                   |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Handles all position sizing, SL/TP calculation, breakeven management,
// equity-peak trailing stop (profit lock), and max drawdown emergency stop.
// Integrates with CTrade for order modification.
//
#pragma once
#include <Trade\Trade.mqh>
#include "../Utils/ATRUtils.mqh"
#include "Logger.mqh"

//+------------------------------------------------------------------+
//| SL calculation method enum                                        |
//+------------------------------------------------------------------+
enum ENUM_SL_METHOD
{
    SL_SWING = 0,  // Stop at swing high/low + ATR buffer
    SL_ATR   = 1   // Stop at ATR multiplier from entry
};

//+------------------------------------------------------------------+
//| TP calculation method enum                                        |
//+------------------------------------------------------------------+
enum ENUM_TP_METHOD
{
    TP_RR    = 0,  // R:R ratio from SL distance
    TP_ATR   = 1,  // ATR multiplier from entry
    TP_FIXED = 2   // Fixed points distance
};

//+------------------------------------------------------------------+
//| TradeSetup — describes a complete order before placement          |
//+------------------------------------------------------------------+
struct TradeSetup
{
    double   entry_price;  // Order fill price (ask for buy, bid for sell)
    double   sl_price;     // Stop loss price (mandatory — never 0)
    double   tp1_price;    // Take profit 1 price
    double   tp2_price;    // Take profit 2 price
    double   lot1;         // Lot for position 1 (closed at TP1)
    double   lot2;         // Lot for position 2 (closed at TP2)
    int      magic;        // Magic number for this order
    string   comment;      // Order comment
    bool     valid;        // false if SL/TP validation failed
};

//+------------------------------------------------------------------+
//| CRiskManager                                                      |
//+------------------------------------------------------------------+
class CRiskManager
{
private:
    // --- Core references ---
    CTrade*      m_trade;
    CLogger*     m_logger;
    CATRUtils*   m_atr;

    // --- Risk parameters ---
    double   m_risk_pct;
    double   m_lot_min;
    double   m_lot_max;
    bool     m_cent_account;

    // --- SL parameters ---
    ENUM_SL_METHOD  m_sl_method;
    int      m_swing_lookback;
    double   m_atr_mult_sl;

    // --- TP parameters ---
    ENUM_TP_METHOD  m_tp_method;
    double   m_tp1_rr;
    double   m_tp2_rr;
    double   m_tp1_vol_pct;    // Percentage of total lot for position 1 (TP1)

    // --- Breakeven parameters ---
    bool     m_be_enabled;
    double   m_be_trigger_usd;
    double   m_be_offset_pts;

    // --- Profit lock parameters ---
    bool     m_pl_enabled;
    double   m_pl_trigger_pct;
    double   m_pl_trail_pct;
    double   m_day_start_equity;
    double   m_equity_peak;

    // --- Magic base for position filtering ---
    int      m_magic_base;

    //------------------------------------------------------------------
    // GetLotDigits
    // Returns the number of decimal places for lot normalization.
    //------------------------------------------------------------------
    int GetLotDigits()
    {
        double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
        if(lot_step >= 0.1) return 1;
        if(lot_step >= 0.01) return 2;
        return 2;
    }

    //------------------------------------------------------------------
    // CloseAllByMagic
    // Closes all positions owned by this EA (MagicBase to MagicBase+11).
    // reason: string logged with each closure.
    //------------------------------------------------------------------
    void CloseAllByMagic(string reason)
    {
        int total = PositionsTotal();
        for(int i = total - 1; i >= 0; i--)
        {
            ulong ticket = PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket)) continue;

            long magic = PositionGetInteger(POSITION_MAGIC);
            if(magic < m_magic_base || magic > m_magic_base + 11) continue;

            double profit = PositionGetDouble(POSITION_PROFIT);
            if(m_trade.PositionClose(ticket))
            {
                if(m_logger != NULL)
                    m_logger.LogOrderClose(ticket, profit, reason);
            }
            else
            {
                int err = GetLastError();
                if(m_logger != NULL)
                    m_logger.LogError(StringFormat("CloseAllByMagic ticket=%llu", ticket), err);
            }
        }
    }

public:
    CRiskManager()
    {
        m_trade           = NULL;
        m_logger          = NULL;
        m_atr             = NULL;
        m_risk_pct        = 1.0;
        m_lot_min         = 0.01;
        m_lot_max         = 1.0;
        m_cent_account    = false;
        m_sl_method       = SL_SWING;
        m_swing_lookback  = 10;
        m_atr_mult_sl     = 1.0;
        m_tp_method       = TP_RR;
        m_tp1_rr          = 2.0;
        m_tp2_rr          = 3.5;
        m_tp1_vol_pct     = 60.0;
        m_be_enabled      = true;
        m_be_trigger_usd  = 50.0;
        m_be_offset_pts   = 0.5;
        m_pl_enabled      = true;
        m_pl_trigger_pct  = 1.5;
        m_pl_trail_pct    = 0.5;
        m_day_start_equity = 0.0;
        m_equity_peak      = 0.0;
        m_magic_base       = 202601;
    }

    //------------------------------------------------------------------
    // Init — store references and parameters
    //------------------------------------------------------------------
    void Init(CTrade*      trade,
              CLogger*     logger,
              CATRUtils*   atr,
              int          magic_base,
              double       risk_pct,
              double       lot_min,
              double       lot_max,
              bool         cent_account,
              ENUM_SL_METHOD sl_method,
              int          swing_lookback,
              double       atr_mult_sl,
              ENUM_TP_METHOD tp_method,
              double       tp1_rr,
              double       tp2_rr,
              double       tp1_vol_pct,
              bool         be_enabled,
              double       be_trigger_usd,
              double       be_offset_pts,
              bool         pl_enabled,
              double       pl_trigger_pct,
              double       pl_trail_pct)
    {
        m_trade           = trade;
        m_logger          = logger;
        m_atr             = atr;
        m_magic_base      = magic_base;
        m_risk_pct        = risk_pct;
        m_lot_min         = lot_min;
        m_lot_max         = lot_max;
        m_cent_account    = cent_account;
        m_sl_method       = sl_method;
        m_swing_lookback  = swing_lookback;
        m_atr_mult_sl     = atr_mult_sl;
        m_tp_method       = tp_method;
        m_tp1_rr          = tp1_rr;
        m_tp2_rr          = tp2_rr;
        m_tp1_vol_pct     = tp1_vol_pct;
        m_be_enabled      = be_enabled;
        m_be_trigger_usd  = be_trigger_usd;
        m_be_offset_pts   = be_offset_pts;
        m_pl_enabled      = pl_enabled;
        m_pl_trigger_pct  = pl_trigger_pct;
        m_pl_trail_pct    = pl_trail_pct;

        double equity = AccountInfoDouble(ACCOUNT_EQUITY);
        m_day_start_equity = equity;
        m_equity_peak      = equity;
    }

    //------------------------------------------------------------------
    // SetDayStartEquity — called each new trading day
    //------------------------------------------------------------------
    void SetDayStartEquity(double equity)
    {
        m_day_start_equity = equity;
        if(equity > m_equity_peak)
            m_equity_peak = equity;
    }

    //------------------------------------------------------------------
    // CalcSwingSL
    // Returns SL price based on swing high/low.
    // bias +1 (buy): SL below recent swing low - 0.5 ATR buffer
    // bias -1 (sell): SL above recent swing high + 0.5 ATR buffer
    //------------------------------------------------------------------
    double CalcSwingSL(int bias)
    {
        double atr  = (m_atr != NULL) ? m_atr.GetATR(1) : 0.0;
        double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

        if(bias > 0)
        {
            int    bar_low = iLowest(_Symbol, PERIOD_M15, MODE_LOW, m_swing_lookback, 1);
            double low     = iLow(_Symbol, PERIOD_M15, bar_low);
            return NormalizeDouble(low - 0.5 * atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
        }
        else
        {
            int    bar_high = iHighest(_Symbol, PERIOD_M15, MODE_HIGH, m_swing_lookback, 1);
            double high     = iHigh(_Symbol, PERIOD_M15, bar_high);
            return NormalizeDouble(high + 0.5 * atr, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
        }
    }

    //------------------------------------------------------------------
    // CalcATRSL
    // Returns SL price at m_atr_mult_sl × ATR from entry.
    //------------------------------------------------------------------
    double CalcATRSL(int bias, double entry)
    {
        double atr = (m_atr != NULL) ? m_atr.GetATR(1) : 0.0;
        int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

        if(bias > 0)
            return NormalizeDouble(entry - m_atr_mult_sl * atr, digits);
        else
            return NormalizeDouble(entry + m_atr_mult_sl * atr, digits);
    }

    //------------------------------------------------------------------
    // CalcLotSize
    // Computes position size from risk % and SL distance in price points.
    // Clamps between LotMin and LotMax.
    //------------------------------------------------------------------
    double CalcLotSize(double sl_distance_price)
    {
        double balance      = AccountInfoDouble(ACCOUNT_BALANCE);
        double dollar_risk  = balance * (m_risk_pct / 100.0);

        double point        = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
        double tick_value   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

        if(point <= 0.0 || tick_size <= 0.0 || tick_value <= 0.0 || sl_distance_price <= 0.0)
        {
            if(m_logger != NULL)
                m_logger.LogWarning(StringFormat("CalcLotSize: invalid params point=%.8f tick_val=%.4f tick_sz=%.8f sl_dist=%.4f",
                                                 point, tick_value, tick_size, sl_distance_price));
            return m_lot_min;
        }

        double sl_in_points     = sl_distance_price / point;
        double value_per_point  = tick_value / tick_size;
        double lot_raw          = dollar_risk / (sl_in_points * value_per_point);

        int lot_digits = GetLotDigits();
        double lot     = NormalizeDouble(MathMax(m_lot_min, MathMin(m_lot_max, lot_raw)), lot_digits);

        // Warn if actual risk differs significantly (e.g. lot was clamped)
        if(lot == m_lot_min && lot_raw < m_lot_min && m_logger != NULL)
            m_logger.LogWarning(StringFormat("CalcLotSize clamped to LotMin=%.2f (raw=%.4f, risk_pct=%.2f%%)",
                                             m_lot_min, lot_raw, m_risk_pct));

        return lot;
    }

    //------------------------------------------------------------------
    // BuildTradeSetup
    // Calculates entry, SL, TP1, TP2, and lot sizes for a given bias.
    // Validates that SL distance exceeds the broker's minimum stop level.
    // Sets setup.valid = false on failure.
    //------------------------------------------------------------------
    bool BuildTradeSetup(int bias, int magic, string comment, TradeSetup &setup)
    {
        setup.valid = false;

        double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
        int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

        setup.entry_price = (bias > 0) ? ask : bid;
        setup.magic       = magic;
        setup.comment     = comment;

        // Calculate SL
        double sl;
        if(m_sl_method == SL_SWING)
            sl = CalcSwingSL(bias);
        else
            sl = CalcATRSL(bias, setup.entry_price);

        // Validate SL distance against broker minimum
        long min_stop_pts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
        double sl_distance = MathAbs(setup.entry_price - sl);

        double min_stop_price = min_stop_pts * point;
        if(sl_distance < min_stop_price)
        {
            // Expand SL to meet minimum
            sl_distance = min_stop_price + point; // Add 1 point buffer
            sl = (bias > 0)
                 ? NormalizeDouble(setup.entry_price - sl_distance, digits)
                 : NormalizeDouble(setup.entry_price + sl_distance, digits);

            if(m_logger != NULL)
                m_logger.LogWarning(StringFormat("BuildTradeSetup: SL expanded to meet MIN_STOP_LEVEL=%d pts, new_sl=%.5f",
                                                 (int)min_stop_pts, sl));
        }

        setup.sl_price = sl;

        // Calculate TP1 and TP2
        double sl_dist = MathAbs(setup.entry_price - sl);
        if(m_tp_method == TP_RR)
        {
            if(bias > 0)
            {
                setup.tp1_price = NormalizeDouble(setup.entry_price + sl_dist * m_tp1_rr, digits);
                setup.tp2_price = NormalizeDouble(setup.entry_price + sl_dist * m_tp2_rr, digits);
            }
            else
            {
                setup.tp1_price = NormalizeDouble(setup.entry_price - sl_dist * m_tp1_rr, digits);
                setup.tp2_price = NormalizeDouble(setup.entry_price - sl_dist * m_tp2_rr, digits);
            }
        }
        else if(m_tp_method == TP_ATR)
        {
            double atr = (m_atr != NULL) ? m_atr.GetATR(1) : sl_dist;
            if(bias > 0)
            {
                setup.tp1_price = NormalizeDouble(setup.entry_price + m_tp1_rr * atr, digits);
                setup.tp2_price = NormalizeDouble(setup.entry_price + m_tp2_rr * atr, digits);
            }
            else
            {
                setup.tp1_price = NormalizeDouble(setup.entry_price - m_tp1_rr * atr, digits);
                setup.tp2_price = NormalizeDouble(setup.entry_price - m_tp2_rr * atr, digits);
            }
        }

        // Validate SL and TP are non-zero and logical
        if(setup.sl_price <= 0.0 || setup.tp1_price <= 0.0 || setup.tp2_price <= 0.0)
        {
            if(m_logger != NULL)
                m_logger.LogError("BuildTradeSetup: Invalid SL/TP values", 0);
            return false;
        }
        if(bias > 0 && (setup.sl_price >= setup.entry_price || setup.tp1_price <= setup.entry_price))
        {
            if(m_logger != NULL)
                m_logger.LogError(StringFormat("BuildTradeSetup: BUY price logic error entry=%.5f sl=%.5f tp1=%.5f",
                                               setup.entry_price, setup.sl_price, setup.tp1_price), 0);
            return false;
        }
        if(bias < 0 && (setup.sl_price <= setup.entry_price || setup.tp1_price >= setup.entry_price))
        {
            if(m_logger != NULL)
                m_logger.LogError(StringFormat("BuildTradeSetup: SELL price logic error entry=%.5f sl=%.5f tp1=%.5f",
                                               setup.entry_price, setup.sl_price, setup.tp1_price), 0);
            return false;
        }

        // Calculate lot sizes (split between two positions)
        double total_lot = CalcLotSize(sl_distance);
        double lot1_frac = m_tp1_vol_pct / 100.0;
        double lot2_frac = 1.0 - lot1_frac;
        int lot_digits   = GetLotDigits();

        setup.lot1 = NormalizeDouble(MathMax(m_lot_min, total_lot * lot1_frac), lot_digits);
        setup.lot2 = NormalizeDouble(MathMax(m_lot_min, total_lot * lot2_frac), lot_digits);

        setup.valid = true;
        return true;
    }

    //------------------------------------------------------------------
    // ManageBreakeven
    // Scans all open positions. If profit >= BreakevenTriggerUSD,
    // moves SL to entry + BreakevenOffsetPts to lock entry cost.
    // Called every tick.
    //------------------------------------------------------------------
    void ManageBreakeven()
    {
        if(!m_be_enabled || m_trade == NULL) return;

        double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
        int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
        int    total  = PositionsTotal();

        for(int i = total - 1; i >= 0; i--)
        {
            ulong ticket = PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket)) continue;

            long magic = PositionGetInteger(POSITION_MAGIC);
            if(magic < m_magic_base || magic > m_magic_base + 11) continue;

            double profit  = PositionGetDouble(POSITION_PROFIT);
            double entry   = PositionGetDouble(POSITION_PRICE_OPEN);
            double cur_sl  = PositionGetDouble(POSITION_SL);
            double cur_tp  = PositionGetDouble(POSITION_TP);
            long   pos_type = PositionGetInteger(POSITION_TYPE);

            if(profit < m_be_trigger_usd) continue;

            double new_sl;
            if(pos_type == POSITION_TYPE_BUY)
            {
                new_sl = NormalizeDouble(entry + m_be_offset_pts * point, digits);
                if(new_sl <= cur_sl) continue; // Already at or above breakeven
            }
            else
            {
                new_sl = NormalizeDouble(entry - m_be_offset_pts * point, digits);
                if(new_sl >= cur_sl && cur_sl > 0.0) continue; // Already at or below breakeven
            }

            if(m_trade.PositionModify(ticket, new_sl, cur_tp))
            {
                if(m_logger != NULL)
                    m_logger.LogBreakeven(ticket, new_sl);
            }
            else
            {
                int err = GetLastError();
                if(m_logger != NULL)
                    m_logger.LogError(StringFormat("ManageBreakeven modify ticket=%llu", ticket), err);
            }
        }
    }

    //------------------------------------------------------------------
    // ManageProfitLock
    // Tracks equity peak each tick. If equity has risen ProfitLockTriggerPct%
    // from day start, and then drops ProfitLockTrailPct% below peak,
    // closes all positions.
    // Called every tick.
    //------------------------------------------------------------------
    void ManageProfitLock()
    {
        if(!m_pl_enabled) return;

        double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);

        // Update equity peak
        if(current_equity > m_equity_peak)
            m_equity_peak = current_equity;

        if(m_day_start_equity <= 0.0) return;

        double rise_pct = (m_equity_peak - m_day_start_equity) / m_day_start_equity * 100.0;
        if(rise_pct < m_pl_trigger_pct) return;

        // Check if current equity fell below lock level
        double lock_level = m_equity_peak * (1.0 - m_pl_trail_pct / 100.0);
        if(current_equity < lock_level)
        {
            if(m_logger != NULL)
                m_logger.LogInfo(StringFormat("ProfitLock triggered: peak=%.2f lock_level=%.2f current=%.2f",
                                              m_equity_peak, lock_level, current_equity));
            CloseAllByMagic("ProfitLock trailing hit");
        }
    }

    //------------------------------------------------------------------
    // CheckMaxDrawdown
    // Returns true if (peak_equity - current_equity) / peak_equity >= threshold.
    // Caller should set EmergencyStop = true and call CloseAll if this returns true.
    //------------------------------------------------------------------
    bool CheckMaxDrawdown(double current_equity, double peak_equity, double max_drawdown_pct)
    {
        if(peak_equity <= 0.0) return false;
        double drawdown_pct = (peak_equity - current_equity) / peak_equity * 100.0;
        if(drawdown_pct >= max_drawdown_pct)
        {
            if(m_logger != NULL)
                m_logger.LogError(StringFormat("MAX DRAWDOWN HIT: drawdown=%.2f%% >= limit=%.2f%%",
                                               drawdown_pct, max_drawdown_pct), 0);
            CloseAllByMagic("MaxDrawdown emergency stop");
            return true;
        }
        return false;
    }

    //------------------------------------------------------------------
    // GetEquityPeak — returns current tracked equity peak
    //------------------------------------------------------------------
    double GetEquityPeak() { return m_equity_peak; }
};
