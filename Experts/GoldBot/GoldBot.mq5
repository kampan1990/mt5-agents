//+------------------------------------------------------------------+
//| GoldBot.mq5                                                       |
//| GoldBot EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-19                                               |
//+------------------------------------------------------------------+
//
// Multi-strategy Expert Advisor for XAUUSD M15.
// Aggregates 12 independent strategy scores through a weighted
// ScoreEngine. Opens positions only when composite score >= threshold
// AND at least MinStrategiesActive confirm the direction.
//
// Execution order per OnTick():
//   1. Check EmergencyStop flag
//   2. Run position management (breakeven, profit lock, drawdown) EVERY tick
//   3. Check for new M15 bar
//   4. Session and daily limit gates
//   5. Evaluate all 12 strategies
//   6. Aggregate via ScoreEngine
//   7. Build and send orders via RiskManager
//   8. Update on-chart dashboard panel
//
#property strict
#property description "GoldBot — 12-Strategy XAUUSD Scoring EA"
#property version     "1.00"

#include <Trade\Trade.mqh>
#include "Utils/ATRUtils.mqh"
#include "Core/Logger.mqh"
#include "Core/RiskManager.mqh"
#include "Core/SessionFilter.mqh"
#include "Core/ScoreEngine.mqh"
#include "Strategies/BaseStrategy.mqh"
#include "Strategies/EMAcross.mqh"
#include "Strategies/SupplyDemand.mqh"
#include "Strategies/RSIDivergence.mqh"
#include "Strategies/FairValueGap.mqh"
#include "Strategies/OrderBlock.mqh"
#include "Strategies/LondonBreakout.mqh"
#include "Strategies/VWAPRejection.mqh"
#include "Strategies/NewsFade.mqh"
#include "Strategies/MultiTF.mqh"
#include "Strategies/Fibonacci.mqh"
#include "Strategies/LiquiditySweep.mqh"
#include "Strategies/BosChoch.mqh"

//+------------------------------------------------------------------+
//| General Settings                                                  |
//+------------------------------------------------------------------+
input int    MagicBase        = 202601;   // Base magic number (strategies add 0-11)
input string TradeComment     = "GoldBot"; // Order comment prefix
input bool   EmergencyStop    = false;    // True: block all new orders
input int    MaxOpenTrades    = 3;        // Maximum simultaneous positions
input bool   AllowLong        = true;     // Permit buy orders
input bool   AllowShort       = true;     // Permit sell orders

//+------------------------------------------------------------------+
//| Score Engine Settings                                             |
//+------------------------------------------------------------------+
input double ScoreThreshold         = 65.0;  // Minimum composite score (%) to trade
input int    MinStrategiesActive    = 3;     // Min strategies with score > 0
input double WeightEMAcross         = 1.0;   // EMA Cross weight
input double WeightSupplyDemand     = 1.2;   // Supply & Demand weight
input double WeightRSIDivergence    = 1.0;   // RSI Divergence weight
input double WeightFVG              = 1.0;   // Fair Value Gap weight
input double WeightOrderBlock       = 1.2;   // Order Block weight
input double WeightLondonBreakout   = 1.1;   // London Breakout weight
input double WeightVWAPRejection    = 1.0;   // VWAP Rejection weight
input double WeightNewsFade         = 0.8;   // News Fade weight
input double WeightMultiTF          = 1.3;   // Multi-TF Alignment weight
input double WeightFibonacci        = 1.0;   // Fibonacci weight
input double WeightLiquiditySweep   = 1.1;   // Liquidity Sweep weight
input double WeightBosChoch         = 1.2;   // BOS/CHoCH weight

//+------------------------------------------------------------------+
//| Risk Manager — SL/TP                                              |
//+------------------------------------------------------------------+
input ENUM_SL_METHOD SLMethod         = SL_SWING; // SL calculation method
input int            SwingLookback    = 10;        // Bars for swing SL
input double         ATRMultiplierSL  = 1.0;       // ATR multiplier for SL_ATR mode
input ENUM_TP_METHOD TPMethod         = TP_RR;     // TP calculation method
input double         TP1_RR           = 2.0;       // Take Profit 1 R:R ratio
input double         TP2_RR           = 3.5;       // Take Profit 2 R:R ratio
input double         TP1_VolumePct    = 60.0;      // % of position closed at TP1
input int            ATRPeriod        = 14;        // ATR calculation period
input ENUM_TIMEFRAMES ATRTimeframe    = PERIOD_M15; // ATR timeframe

//+------------------------------------------------------------------+
//| Risk Manager — Lot Sizing                                         |
//+------------------------------------------------------------------+
input double RiskPercent   = 1.0;    // Risk per trade as % of balance
input double LotMin        = 0.01;   // Minimum lot size
input double LotMax        = 1.0;    // Maximum lot size
input bool   CentAccount   = false;  // True for cent accounts

//+------------------------------------------------------------------+
//| Risk Manager — Breakeven                                          |
//+------------------------------------------------------------------+
input bool   EnableBreakeven       = true;  // Activate breakeven system
input double BreakevenTriggerUSD   = 50.0;  // Move SL to entry when profit >= $50
input double BreakevenOffsetPts    = 0.5;   // SL offset above/below entry in points

//+------------------------------------------------------------------+
//| Risk Manager — Profit Lock                                        |
//+------------------------------------------------------------------+
input bool   EnableProfitLock         = true;  // Activate equity-based trailing SL
input double ProfitLockTriggerPct     = 1.5;   // Trigger when equity rises 1.5%
input double ProfitLockTrailPct       = 0.5;   // Trail 0.5% below equity peak

//+------------------------------------------------------------------+
//| Session Filter                                                    |
//+------------------------------------------------------------------+
input bool   EnableSessionFilter       = true;  // Restrict to London+NY window
input int    SessionStartHour          = 7;     // Session open hour (UTC)
input int    SessionEndHour            = 20;    // Session close hour (UTC)
input double DailyProfitTargetPct      = 3.0;   // Stop after % daily gain
input double DailyProfitTargetUSD      = 300.0; // Stop after $ daily gain
input double DailyFloatingTargetUSD    = 200.0; // Stop when floating >= $200
input double DailyLossLimitPct         = 2.0;   // Stop after % daily loss
input double MaxDrawdownPct            = 20.0;  // Emergency stop: drawdown % limit

//+------------------------------------------------------------------+
//| Global EA State                                                   |
//+------------------------------------------------------------------+

// Core objects
CTrade           g_trade;
CLogger          g_logger;
CATRUtils        g_atr;
CRiskManager     g_risk;
CSessionFilter   g_session;
CScoreEngine     g_engine;

// Strategy instances (12 total)
CStratEMAcross        g_strat0;
CStratSupplyDemand    g_strat1;
CStratRSIDivergence   g_strat2;
CStratFVG             g_strat3;
CStratOrderBlock      g_strat4;
CStratLondonBreakout  g_strat5;
CStratVWAPRejection   g_strat6;
CStratNewsFade        g_strat7;
CStratMultiTF         g_strat8;
CStratFibonacci       g_strat9;
CStratLiquiditySweep  g_strat10;
CStratBosChoch        g_strat11;

// Emergency stop state (can be set at runtime via GlobalVariable)
bool g_emergency_stop = false;

// New-bar detection
datetime g_last_bar_time = 0;

// Dashboard throttle
datetime g_last_panel_update = 0;

// Cached last composite result for dashboard
CompositeResult g_last_result;

//+------------------------------------------------------------------+
//| Helper: count open positions belonging to this EA                 |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
    int count = 0;
    int total = PositionsTotal();
    for(int i = 0; i < total; i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        long magic = PositionGetInteger(POSITION_MAGIC);
        if(magic >= MagicBase && magic <= MagicBase + 11)
            count++;
    }
    return count;
}

//+------------------------------------------------------------------+
//| Helper: sum floating profit of all EA positions                   |
//+------------------------------------------------------------------+
double GetFloatingProfit()
{
    double total_profit = 0.0;
    int total = PositionsTotal();
    for(int i = 0; i < total; i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        long magic = PositionGetInteger(POSITION_MAGIC);
        if(magic >= MagicBase && magic <= MagicBase + 11)
            total_profit += PositionGetDouble(POSITION_PROFIT);
    }
    return total_profit;
}

//+------------------------------------------------------------------+
//| Helper: check for new M15 bar                                     |
//+------------------------------------------------------------------+
bool IsNewBar()
{
    datetime current_bar = iTime(_Symbol, PERIOD_M15, 0);
    if(current_bar != g_last_bar_time)
    {
        g_last_bar_time = current_bar;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| PlaceOrders — sends both TP1 and TP2 positions for a setup       |
//+------------------------------------------------------------------+
bool PlaceOrders(TradeSetup &setup, int bias)
{
    bool success = false;

    // Verify terminal connection before sending
    if(!TerminalInfoInteger(TERMINAL_CONNECTED))
    {
        g_logger.LogError("PlaceOrders: Terminal not connected", 0);
        return false;
    }

    // Validate SL and TP before every send
    if(setup.sl_price <= 0.0 || setup.tp1_price <= 0.0 || setup.tp2_price <= 0.0)
    {
        g_logger.LogError("PlaceOrders: Invalid SL/TP values, order aborted", 0);
        return false;
    }

    g_trade.SetExpertMagicNumber(setup.magic);
    g_trade.SetDeviationInPoints(10);

    // --- Position 1: closes at TP1 ---
    bool sent1 = false;
    if(bias > 0)
        sent1 = g_trade.Buy(setup.lot1, _Symbol, 0.0, setup.sl_price, setup.tp1_price,
                            setup.comment + "_TP1");
    else
        sent1 = g_trade.Sell(setup.lot1, _Symbol, 0.0, setup.sl_price, setup.tp1_price,
                             setup.comment + "_TP1");

    if(sent1)
    {
        uint retcode = g_trade.ResultRetcode();
        if(retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED)
        {
            ulong ticket1 = g_trade.ResultOrder();
            g_logger.LogOrderOpen(ticket1, bias, setup.lot1,
                                  setup.entry_price, setup.sl_price,
                                  setup.tp1_price, setup.tp2_price);
            success = true;
        }
        else
        {
            g_logger.LogError(StringFormat("PlaceOrders TP1 retcode=%d", retcode),
                              GetLastError());

            // Retry once on REQUOTE
            if(retcode == TRADE_RETCODE_REQUOTE || retcode == TRADE_RETCODE_PRICE_OFF)
            {
                g_logger.LogInfo("PlaceOrders TP1: retrying after requote");
                if(bias > 0)
                    sent1 = g_trade.Buy(setup.lot1, _Symbol, 0.0,
                                        setup.sl_price, setup.tp1_price,
                                        setup.comment + "_TP1");
                else
                    sent1 = g_trade.Sell(setup.lot1, _Symbol, 0.0,
                                         setup.sl_price, setup.tp1_price,
                                         setup.comment + "_TP1");

                if(sent1 && (g_trade.ResultRetcode() == TRADE_RETCODE_DONE ||
                             g_trade.ResultRetcode() == TRADE_RETCODE_PLACED))
                {
                    g_logger.LogOrderOpen(g_trade.ResultOrder(), bias, setup.lot1,
                                          setup.entry_price, setup.sl_price,
                                          setup.tp1_price, setup.tp2_price);
                    success = true;
                }
                else
                {
                    g_logger.LogError("PlaceOrders TP1 retry also failed",
                                      GetLastError());
                }
            }
        }
    }
    else
    {
        g_logger.LogError("PlaceOrders TP1 send failed", GetLastError());
    }

    if(!success) return false;

    // --- Position 2: closes at TP2 ---
    bool sent2 = false;
    if(bias > 0)
        sent2 = g_trade.Buy(setup.lot2, _Symbol, 0.0, setup.sl_price, setup.tp2_price,
                            setup.comment + "_TP2");
    else
        sent2 = g_trade.Sell(setup.lot2, _Symbol, 0.0, setup.sl_price, setup.tp2_price,
                             setup.comment + "_TP2");

    if(sent2)
    {
        uint retcode = g_trade.ResultRetcode();
        if(retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED)
        {
            ulong ticket2 = g_trade.ResultOrder();
            g_logger.LogOrderOpen(ticket2, bias, setup.lot2,
                                  setup.entry_price, setup.sl_price,
                                  setup.tp1_price, setup.tp2_price);
        }
        else
        {
            g_logger.LogError(StringFormat("PlaceOrders TP2 retcode=%d", retcode),
                              GetLastError());
        }
    }
    else
    {
        g_logger.LogError("PlaceOrders TP2 send failed", GetLastError());
    }

    return success;
}

//+------------------------------------------------------------------+
//| Dashboard Panel                                                   |
//+------------------------------------------------------------------+

// Panel object name prefix — all objects share this prefix for cleanup
static const string PANEL_PREFIX = "GoldBot_Panel_";

//------------------------------------------------------------------
// DeletePanelObjects — removes all panel chart objects
//------------------------------------------------------------------
void DeletePanelObjects()
{
    ObjectsDeleteAll(0, PANEL_PREFIX);
}

//------------------------------------------------------------------
// CreateLabel — creates or updates a text label object on the chart
//------------------------------------------------------------------
void CreateLabel(string name, int x, int y, string text,
                 color clr = clrWhite, int font_size = 9)
{
    string full_name = PANEL_PREFIX + name;
    if(ObjectFind(0, full_name) < 0)
    {
        ObjectCreate(0, full_name, OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, full_name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
        ObjectSetInteger(0, full_name, OBJPROP_XDISTANCE, x);
        ObjectSetInteger(0, full_name, OBJPROP_YDISTANCE, y);
        ObjectSetInteger(0, full_name, OBJPROP_FONTSIZE,  font_size);
        ObjectSetString (0, full_name, OBJPROP_FONT,      "Courier New");
        ObjectSetInteger(0, full_name, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, full_name, OBJPROP_HIDDEN,    true);
    }
    ObjectSetString (0, full_name, OBJPROP_TEXT,      text);
    ObjectSetInteger(0, full_name, OBJPROP_COLOR,     clr);
}

//------------------------------------------------------------------
// DrawPanel — updates the on-chart dashboard
// Throttled to once per second to avoid flicker.
//------------------------------------------------------------------
void DrawPanel(const CompositeResult &res)
{
    datetime now = TimeCurrent();
    if(now - g_last_panel_update < 1) return;
    g_last_panel_update = now;

    double current_equity   = AccountInfoDouble(ACCOUNT_EQUITY);
    double day_start_bal    = g_session.GetDayStartBalance();
    double daily_pnl_usd    = current_equity - day_start_bal;
    double daily_pnl_pct    = (day_start_bal > 0.0)
                              ? daily_pnl_usd / day_start_bal * 100.0 : 0.0;
    double drawdown_pct     = (g_risk.GetEquityPeak() > 0.0)
                              ? (g_risk.GetEquityPeak() - current_equity) /
                                g_risk.GetEquityPeak() * 100.0 : 0.0;
    int    open_pos         = CountOpenPositions();

    string session_str  = g_session.IsSessionActive() ? "ACTIVE" : "CLOSED";
    string bias_str     = (res.bias > 0) ? "LONG" : (res.bias < 0) ? "SHORT" : "NEUTRAL";
    color  bias_clr     = (res.bias > 0) ? clrLime : (res.bias < 0) ? clrRed : clrYellow;
    color  session_clr  = g_session.IsSessionActive() ? clrLime : clrGray;

    int x = 10;
    int y = 20;
    int row_h = 15; // Row height in pixels

    // Header
    CreateLabel("hdr",   x, y,      "+----- GoldBot | XAUUSD | M15 -----+", clrCyan, 9);
    CreateLabel("sess",  x, y += row_h, StringFormat("|  Session: %-26s|", session_str), session_clr);
    CreateLabel("score", x, y += row_h,
                StringFormat("|  Score: BULL %5.1f%%  |  BEAR %5.1f%%  |",
                             res.bull_score, res.bear_score), clrWhite);
    CreateLabel("thr",   x, y += row_h,
                StringFormat("|  Threshold: %.0f%%       Bias: %-8s|",
                             ScoreThreshold, bias_str), bias_clr);
    CreateLabel("pos",   x, y += row_h,
                StringFormat("|  Open: %d / %d                         |",
                             open_pos, MaxOpenTrades), clrWhite);
    CreateLabel("pnl",   x, y += row_h,
                StringFormat("|  Today P/L: %+.2f / %+.2f%%           |",
                             daily_pnl_usd, daily_pnl_pct), daily_pnl_usd >= 0 ? clrLime : clrRed);
    CreateLabel("dd",    x, y += row_h,
                StringFormat("|  Drawdown: %.2f%%                       |", drawdown_pct),
                drawdown_pct > MaxDrawdownPct * 0.75 ? clrRed : clrWhite);
    CreateLabel("sep1",  x, y += row_h, "+------------------------------------+", clrCyan);

    // Strategy rows
    string strat_names[12] = {
        "EMA Cross    ", "Supply&Demand", "RSI Diverge  ", "Fair Val Gap ",
        "Order Block  ", "Lon Breakout ", "VWAP Reject  ", "News Fade    ",
        "Multi-TF     ", "Fibonacci    ", "Liq. Sweep   ", "BOS/CHoCH    "
    };

    for(int i = 0; i < 12; i++)
    {
        double sc  = res.scores[i].score * 100.0;
        int    brs = (int)MathRound(sc / 10.0); // bars out of 10
        string bar_str = "";
        for(int b = 0; b < 10; b++)
            bar_str += (b < brs) ? "=" : " ";

        color strat_clr = (sc >= 75.0) ? clrLime :
                          (sc >= 50.0) ? clrYellow : clrGray;

        CreateLabel(StringFormat("strat%d", i), x, y += row_h,
                    StringFormat("|  %s [%s] %3.0f%% |",
                                 strat_names[i], bar_str, sc), strat_clr);
    }

    CreateLabel("sep2", x, y += row_h, "+------------------------------------+", clrCyan);

    // Emergency stop indicator
    color  emg_clr = g_emergency_stop ? clrRed : clrGray;
    string emg_str = g_emergency_stop ? "| *** EMERGENCY STOP ACTIVE ***     |"
                                      : "|  [Emergency Stop: OFF]             |";
    CreateLabel("emg", x, y += row_h, emg_str, emg_clr);
    CreateLabel("sep3", x, y += row_h, "+------------------------------------+", clrCyan);

    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
    // Initialize logger first so all subsequent Init calls can log
    g_logger.Init("GoldBot");
    g_logger.LogInfo(StringFormat("GoldBot v1.0 OnInit: symbol=%s tf=M15", _Symbol));

    // Validate symbol
    if(StringFind(_Symbol, "XAUUSD") < 0 && StringFind(_Symbol, "GOLD") < 0)
        g_logger.LogWarning(StringFormat("EA designed for XAUUSD, running on %s", _Symbol));

    // Initialize shared ATR
    if(!g_atr.Init(ATRPeriod, ATRTimeframe))
    {
        g_logger.LogError("OnInit: ATR initialization failed", GetLastError());
        return INIT_FAILED;
    }

    // Initialize all 12 strategies
    g_strat0.Init(ATRPeriod, ATRTimeframe);
    g_strat1.Init(ATRPeriod, ATRTimeframe);
    g_strat2.Init(ATRPeriod, ATRTimeframe);
    g_strat3.Init(ATRPeriod, ATRTimeframe);
    g_strat4.Init(ATRPeriod, ATRTimeframe);
    g_strat5.Init(ATRPeriod, ATRTimeframe);
    g_strat6.Init(ATRPeriod, ATRTimeframe);
    g_strat7.Init(ATRPeriod, ATRTimeframe);
    g_strat8.Init(ATRPeriod, ATRTimeframe);
    g_strat9.Init(ATRPeriod, ATRTimeframe);
    g_strat10.Init(ATRPeriod, ATRTimeframe);
    g_strat11.Init(ATRPeriod, ATRTimeframe);

    // Build strategy pointer array and weight array for ScoreEngine
    CBaseStrategy* strats[12];
    strats[0]  = &g_strat0;
    strats[1]  = &g_strat1;
    strats[2]  = &g_strat2;
    strats[3]  = &g_strat3;
    strats[4]  = &g_strat4;
    strats[5]  = &g_strat5;
    strats[6]  = &g_strat6;
    strats[7]  = &g_strat7;
    strats[8]  = &g_strat8;
    strats[9]  = &g_strat9;
    strats[10] = &g_strat10;
    strats[11] = &g_strat11;

    double weights[12];
    weights[0]  = WeightEMAcross;
    weights[1]  = WeightSupplyDemand;
    weights[2]  = WeightRSIDivergence;
    weights[3]  = WeightFVG;
    weights[4]  = WeightOrderBlock;
    weights[5]  = WeightLondonBreakout;
    weights[6]  = WeightVWAPRejection;
    weights[7]  = WeightNewsFade;
    weights[8]  = WeightMultiTF;
    weights[9]  = WeightFibonacci;
    weights[10] = WeightLiquiditySweep;
    weights[11] = WeightBosChoch;

    g_engine.Init(strats, weights, ScoreThreshold, MinStrategiesActive);

    // Initialize SessionFilter
    g_session.Init(&g_logger,
                   SessionStartHour, SessionEndHour,
                   DailyProfitTargetPct, DailyProfitTargetUSD,
                   DailyFloatingTargetUSD, DailyLossLimitPct);

    // Initialize RiskManager
    g_risk.Init(&g_trade, &g_logger, &g_atr,
                MagicBase,
                RiskPercent, LotMin, LotMax, CentAccount,
                SLMethod, SwingLookback, ATRMultiplierSL,
                TPMethod, TP1_RR, TP2_RR, TP1_VolumePct,
                EnableBreakeven, BreakevenTriggerUSD, BreakevenOffsetPts,
                EnableProfitLock, ProfitLockTriggerPct, ProfitLockTrailPct);

    // Apply input EmergencyStop flag
    g_emergency_stop = EmergencyStop;

    // Initialize composite result for dashboard
    g_last_result.bull_score     = 0.0;
    g_last_result.bear_score     = 0.0;
    g_last_result.bias           = 0;
    g_last_result.active_count   = 0;
    g_last_result.top_contributors = "";
    for(int i = 0; i < 12; i++)
    {
        g_last_result.scores[i].score = 0.0;
        g_last_result.scores[i].bias  = 0;
        g_last_result.scores[i].name  = "";
    }

    g_logger.LogInfo("GoldBot OnInit complete — all modules initialized");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // Release all strategy indicator handles
    g_strat0.Deinit();
    g_strat1.Deinit();
    g_strat2.Deinit();
    g_strat3.Deinit();
    g_strat4.Deinit();
    g_strat5.Deinit();
    g_strat6.Deinit();
    g_strat7.Deinit();
    g_strat8.Deinit();
    g_strat9.Deinit();
    g_strat10.Deinit();
    g_strat11.Deinit();

    // Release shared ATR
    g_atr.Deinit();

    // Remove dashboard objects
    DeletePanelObjects();

    g_logger.LogInfo(StringFormat("GoldBot OnDeinit reason=%d", reason));
    g_logger.Deinit();
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
    // ----------------------------------------------------------------
    // Gate 1: Check EmergencyStop (runtime GlobalVariable override)
    // ----------------------------------------------------------------
    if(GlobalVariableCheck("GoldBot_EmergencyStop") &&
       GlobalVariableGet("GoldBot_EmergencyStop") >= 1.0)
    {
        g_emergency_stop = true;
    }

    if(g_emergency_stop)
    {
        DrawPanel(g_last_result);
        return;
    }

    // ----------------------------------------------------------------
    // Gate 2: Position Management — runs EVERY tick regardless of bar
    // ----------------------------------------------------------------
    g_risk.ManageBreakeven();
    g_risk.ManageProfitLock();

    double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double equity_peak    = g_risk.GetEquityPeak();
    if(g_risk.CheckMaxDrawdown(current_equity, equity_peak, MaxDrawdownPct))
    {
        g_emergency_stop = true;
        g_logger.LogError("Max drawdown hit — EmergencyStop activated", 0);
        DrawPanel(g_last_result);
        return;
    }

    // ----------------------------------------------------------------
    // Gate 3: New M15 bar check
    // ----------------------------------------------------------------
    bool new_bar = IsNewBar();

    // Refresh ATR on new bar
    if(new_bar && !g_atr.IsReady())
    {
        g_logger.LogWarning("OnTick: ATR not ready, skipping bar");
        DrawPanel(g_last_result);
        return;
    }

    // ----------------------------------------------------------------
    // Gate 4: Day change detection
    // ----------------------------------------------------------------
    if(new_bar)
    {
        g_session.CheckNewDay();
        g_risk.SetDayStartEquity(g_session.GetDayStartEquity());
    }

    // ----------------------------------------------------------------
    // Update dashboard every tick (throttled inside DrawPanel)
    // ----------------------------------------------------------------
    DrawPanel(g_last_result);

    // ----------------------------------------------------------------
    // Below this point — only runs on new M15 bars
    // ----------------------------------------------------------------
    if(!new_bar) return;

    // ----------------------------------------------------------------
    // Gate 5: Session filter
    // ----------------------------------------------------------------
    if(EnableSessionFilter && !g_session.IsSessionActive())
        return;

    // ----------------------------------------------------------------
    // Gate 6: Daily limit check
    // ----------------------------------------------------------------
    double floating_profit = GetFloatingProfit();
    if(g_session.IsDailyLimitHit(current_equity, floating_profit))
        return;

    // ----------------------------------------------------------------
    // Gate 7: Max open trades
    // ----------------------------------------------------------------
    if(CountOpenPositions() >= MaxOpenTrades)
        return;

    // ----------------------------------------------------------------
    // Signal Phase: evaluate all 12 strategies
    // ----------------------------------------------------------------
    CompositeResult result = g_engine.Calculate();
    g_last_result = result; // Cache for dashboard

    // Log the composite result
    g_logger.LogSignal(iTime(_Symbol, PERIOD_M15, 1),
                       result.top_contributors,
                       result.bull_score,
                       result.bear_score,
                       result.bias);

    // ----------------------------------------------------------------
    // Decision Phase: check if score meets trade criteria
    // ----------------------------------------------------------------
    int trade_bias = 0;
    if(!g_engine.ShouldTrade(result, trade_bias))
        return;

    // Check directional permission
    if(trade_bias > 0 && !AllowLong)  return;
    if(trade_bias < 0 && !AllowShort) return;

    // ----------------------------------------------------------------
    // Build trade setup
    // ----------------------------------------------------------------
    int    strategy_magic = MagicBase + result.bias; // Assign to strongest side's magic
    string order_comment  = StringFormat("%s_%s", TradeComment,
                                         trade_bias > 0 ? "BUY" : "SELL");

    TradeSetup setup;
    if(!g_risk.BuildTradeSetup(trade_bias, strategy_magic, order_comment, setup))
    {
        g_logger.LogError("OnTick: BuildTradeSetup failed", 0);
        return;
    }

    if(!setup.valid)
    {
        g_logger.LogError("OnTick: TradeSetup marked invalid", 0);
        return;
    }

    // ----------------------------------------------------------------
    // Place orders (two positions: TP1 and TP2)
    // ----------------------------------------------------------------
    PlaceOrders(setup, trade_bias);
}

//+------------------------------------------------------------------+
//| OnChartEvent — handle Emergency Stop button click                 |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
    if(id == CHARTEVENT_OBJECT_CLICK)
    {
        if(StringFind(sparam, "emg") >= 0)
        {
            g_emergency_stop = !g_emergency_stop;
            GlobalVariableSet("GoldBot_EmergencyStop", g_emergency_stop ? 1.0 : 0.0);
            g_logger.LogInfo(StringFormat("EmergencyStop toggled: %s",
                                          g_emergency_stop ? "ON" : "OFF"));
        }
    }
}
