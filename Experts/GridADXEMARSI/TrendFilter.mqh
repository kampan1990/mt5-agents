//+------------------------------------------------------------------+
//| TrendFilter.mqh                                                   |
//| GridADXEMARSI EA                                                  |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-14                                               |
//+------------------------------------------------------------------+
#ifndef TRENDFILTER_MQH
#define TRENDFILTER_MQH

#property strict

//+------------------------------------------------------------------+
//| CTrendFilter                                                      |
//| Combines ADX (trend strength), EMA (trend direction), and RSI    |
//| (momentum confirmation) to decide whether to enter a grid.       |
//|                                                                   |
//| Usage:                                                            |
//|   1. Call Init() in OnInit.                                       |
//|   2. Call Update() at the start of each OnTick.                  |
//|   3. Query IsTrendUp() / IsTrendDown() / GetTrendDirection().    |
//|   4. Call Deinit() in OnDeinit to release indicator handles.     |
//+------------------------------------------------------------------+
class CTrendFilter
{
private:
    int    m_adx_handle;      // iADX indicator handle
    int    m_ema_handle;      // iMA  indicator handle
    int    m_rsi_handle;      // iRSI indicator handle

    int    m_adx_period;
    double m_adx_threshold;   // minimum ADX value to consider trend valid
    int    m_ema_period;
    int    m_rsi_period;

    double m_adx_value;       // most-recent ADX main line value
    double m_ema_value;       // most-recent EMA value
    double m_rsi_value;       // most-recent RSI value

    string          m_symbol;
    ENUM_TIMEFRAMES m_tf;

public:
    //+------------------------------------------------------------------+
    //| Constructor — zero-initialise all handles so Deinit is safe     |
    //+------------------------------------------------------------------+
    CTrendFilter()
    {
        m_adx_handle   = INVALID_HANDLE;
        m_ema_handle   = INVALID_HANDLE;
        m_rsi_handle   = INVALID_HANDLE;
        m_adx_value    = 0.0;
        m_ema_value    = 0.0;
        m_rsi_value    = 0.0;
        m_adx_period   = 14;
        m_adx_threshold= 25.0;
        m_ema_period   = 200;
        m_rsi_period   = 14;
        m_symbol       = "";
        m_tf           = PERIOD_CURRENT;
    }

    //+------------------------------------------------------------------+
    //| Init — create indicator handles; returns false on failure        |
    //| adx_period    : lookback for iADX                               |
    //| adx_threshold : ADX must exceed this value for trend to be valid|
    //| ema_period    : lookback for iMA (MODE_EMA, PRICE_CLOSE)        |
    //| rsi_period    : lookback for iRSI (PRICE_CLOSE)                 |
    //| symbol        : trading symbol (usually _Symbol)                |
    //| tf            : timeframe (usually PERIOD_CURRENT)              |
    //+------------------------------------------------------------------+
    bool Init(int adx_period, double adx_threshold,
              int ema_period, int rsi_period,
              string symbol, ENUM_TIMEFRAMES tf)
    {
        m_adx_period    = adx_period;
        m_adx_threshold = adx_threshold;
        m_ema_period    = ema_period;
        m_rsi_period    = rsi_period;
        m_symbol        = symbol;
        m_tf            = tf;

        m_adx_handle = iADX(m_symbol, m_tf, m_adx_period);
        if(m_adx_handle == INVALID_HANDLE)
        {
            Print("CTrendFilter::Init — iADX creation failed, error=", GetLastError());
            return false;
        }

        m_ema_handle = iMA(m_symbol, m_tf, m_ema_period, 0, MODE_EMA, PRICE_CLOSE);
        if(m_ema_handle == INVALID_HANDLE)
        {
            Print("CTrendFilter::Init — iMA creation failed, error=", GetLastError());
            return false;
        }

        m_rsi_handle = iRSI(m_symbol, m_tf, m_rsi_period, PRICE_CLOSE);
        if(m_rsi_handle == INVALID_HANDLE)
        {
            Print("CTrendFilter::Init — iRSI creation failed, error=", GetLastError());
            return false;
        }

        return true;
    }

    //+------------------------------------------------------------------+
    //| Deinit — release all indicator handles                          |
    //+------------------------------------------------------------------+
    void Deinit()
    {
        if(m_adx_handle != INVALID_HANDLE)
        {
            IndicatorRelease(m_adx_handle);
            m_adx_handle = INVALID_HANDLE;
        }
        if(m_ema_handle != INVALID_HANDLE)
        {
            IndicatorRelease(m_ema_handle);
            m_ema_handle = INVALID_HANDLE;
        }
        if(m_rsi_handle != INVALID_HANDLE)
        {
            IndicatorRelease(m_rsi_handle);
            m_rsi_handle = INVALID_HANDLE;
        }
    }

    //+------------------------------------------------------------------+
    //| Update — refresh cached ADX / EMA / RSI values from the server  |
    //| Must be called once at the start of each OnTick before queries. |
    //| Returns false if any CopyBuffer call fails (data not ready yet). |
    //+------------------------------------------------------------------+
    bool Update()
    {
        double adx_buf[1], ema_buf[1], rsi_buf[1];

        // ADX main line is buffer index 0
        if(CopyBuffer(m_adx_handle, 0, 0, 1, adx_buf) <= 0)
            return false;

        if(CopyBuffer(m_ema_handle, 0, 0, 1, ema_buf) <= 0)
            return false;

        if(CopyBuffer(m_rsi_handle, 0, 0, 1, rsi_buf) <= 0)
            return false;

        m_adx_value = adx_buf[0];
        m_ema_value = ema_buf[0];
        m_rsi_value = rsi_buf[0];

        return true;
    }

    //+------------------------------------------------------------------+
    //| IsTrendUp                                                        |
    //| Returns true when all three conditions are met:                  |
    //|   ADX > threshold  (trend is strong enough)                     |
    //|   Ask  > EMA       (price is above moving average)              |
    //|   RSI  > 50        (momentum is bullish)                        |
    //+------------------------------------------------------------------+
    bool IsTrendUp()
    {
        double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
        return (m_adx_value > m_adx_threshold) &&
               (ask > m_ema_value) &&
               (m_rsi_value > 50.0);
    }

    //+------------------------------------------------------------------+
    //| IsTrendDown                                                      |
    //| Returns true when all three conditions are met:                  |
    //|   ADX > threshold  (trend is strong enough)                     |
    //|   Bid  < EMA       (price is below moving average)              |
    //|   RSI  < 50        (momentum is bearish)                        |
    //+------------------------------------------------------------------+
    bool IsTrendDown()
    {
        double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
        return (m_adx_value > m_adx_threshold) &&
               (bid < m_ema_value) &&
               (m_rsi_value < 50.0);
    }

    //+------------------------------------------------------------------+
    //| HasTrend — true when either IsTrendUp or IsTrendDown is met     |
    //+------------------------------------------------------------------+
    bool HasTrend()
    {
        return IsTrendUp() || IsTrendDown();
    }

    //+------------------------------------------------------------------+
    //| GetTrendDirection                                                |
    //| Returns ORDER_TYPE_BUY for uptrend, ORDER_TYPE_SELL for down.   |
    //| Always call HasTrend() first; behaviour is undefined when flat. |
    //+------------------------------------------------------------------+
    ENUM_ORDER_TYPE GetTrendDirection()
    {
        return IsTrendUp() ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    }

    // --- Accessors for dashboard / debugging ---
    double GetADX() { return m_adx_value; }
    double GetEMA() { return m_ema_value; }
    double GetRSI() { return m_rsi_value; }
};

#endif // TRENDFILTER_MQH
