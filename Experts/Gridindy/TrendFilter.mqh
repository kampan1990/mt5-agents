//+------------------------------------------------------------------+
//| TrendFilter.mqh                                                   |
//| Gridindy EA                                                       |
//| Version: 1.1.0                                                    |
//+------------------------------------------------------------------+
#ifndef TRENDFILTER_MQH
#define TRENDFILTER_MQH

//+------------------------------------------------------------------+
//| CTrendFilter — ADX + EMA + RSI composite trend detector          |
//|                                                                    |
//| Trend direction is evaluated ONCE per tick in Update() using      |
//| mid-price to avoid Ask/Bid dead-zone where both sides can be true |
//| simultaneously when spread is wide.                               |
//+------------------------------------------------------------------+
class CTrendFilter
{
private:
   int             m_adx_handle;
   int             m_ema_handle;
   int             m_rsi_handle;
   int             m_atr_handle;

   int             m_adx_period;
   double          m_adx_threshold;
   int             m_ema_period;
   int             m_rsi_period;
   int             m_atr_period;

   double          m_adx_value;
   double          m_ema_value;
   double          m_rsi_value;
   double          m_atr_value;

   // FIX: cache direction once per tick — prevents Ask/Bid dead-zone inconsistency
   bool            m_has_trend;
   ENUM_ORDER_TYPE m_trend_dir;

   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;

public:
   CTrendFilter()
   {
      m_adx_handle    = INVALID_HANDLE;
      m_ema_handle    = INVALID_HANDLE;
      m_rsi_handle    = INVALID_HANDLE;
      m_atr_handle    = INVALID_HANDLE;
      m_adx_value     = 0.0;
      m_ema_value     = 0.0;
      m_rsi_value     = 0.0;
      m_atr_value     = 0.0;
      m_has_trend     = false;
      m_trend_dir     = ORDER_TYPE_BUY;
      m_adx_period    = 14;
      m_adx_threshold = 25.0;
      m_ema_period    = 200;
      m_rsi_period    = 14;
      m_atr_period    = 14;
   }

   bool Init(int             adx_period,
             double          adx_threshold,
             int             ema_period,
             int             rsi_period,
             int             atr_period,
             string          symbol,
             ENUM_TIMEFRAMES tf)
   {
      m_adx_period    = adx_period;
      m_adx_threshold = adx_threshold;
      m_ema_period    = ema_period;
      m_rsi_period    = rsi_period;
      m_atr_period    = atr_period;
      m_symbol        = symbol;
      m_tf            = tf;

      m_adx_handle = iADX(m_symbol, m_tf, m_adx_period);
      if(m_adx_handle == INVALID_HANDLE)
      {
         Print("TrendFilter: iADX handle creation failed, error=", GetLastError());
         return false;
      }

      m_ema_handle = iMA(m_symbol, m_tf, m_ema_period, 0, MODE_EMA, PRICE_CLOSE);
      if(m_ema_handle == INVALID_HANDLE)
      {
         Print("TrendFilter: iMA (EMA) handle creation failed, error=", GetLastError());
         return false;
      }

      m_rsi_handle = iRSI(m_symbol, m_tf, m_rsi_period, PRICE_CLOSE);
      if(m_rsi_handle == INVALID_HANDLE)
      {
         Print("TrendFilter: iRSI handle creation failed, error=", GetLastError());
         return false;
      }

      m_atr_handle = iATR(m_symbol, m_tf, m_atr_period);
      if(m_atr_handle == INVALID_HANDLE)
      {
         Print("TrendFilter: iATR handle creation failed, error=", GetLastError());
         return false;
      }

      return true;
   }

   void Deinit()
   {
      if(m_adx_handle != INVALID_HANDLE) { IndicatorRelease(m_adx_handle); m_adx_handle = INVALID_HANDLE; }
      if(m_ema_handle != INVALID_HANDLE) { IndicatorRelease(m_ema_handle); m_ema_handle = INVALID_HANDLE; }
      if(m_rsi_handle != INVALID_HANDLE) { IndicatorRelease(m_rsi_handle); m_rsi_handle = INVALID_HANDLE; }
      if(m_atr_handle != INVALID_HANDLE) { IndicatorRelease(m_atr_handle); m_atr_handle = INVALID_HANDLE; }
   }

   //--- Refresh indicator values and evaluate trend direction ONCE per tick.
   //    FIX: uses mid-price for EMA comparison to eliminate Ask/Bid dead-zone.
   bool Update()
   {
      double adx_buf[1], ema_buf[1], rsi_buf[1], atr_buf[1];

      if(CopyBuffer(m_adx_handle, 0, 0, 1, adx_buf) != 1) return false;
      if(CopyBuffer(m_ema_handle, 0, 0, 1, ema_buf) != 1) return false;
      if(CopyBuffer(m_rsi_handle, 0, 0, 1, rsi_buf) != 1) return false;
      if(CopyBuffer(m_atr_handle, 0, 0, 1, atr_buf) != 1) return false;

      m_adx_value = adx_buf[0];
      m_ema_value = ema_buf[0];
      m_rsi_value = rsi_buf[0];
      m_atr_value = atr_buf[0];

      // Use mid-price — single reference point, no dead-zone between Ask and Bid
      double mid = (SymbolInfoDouble(m_symbol, SYMBOL_ASK) +
                    SymbolInfoDouble(m_symbol, SYMBOL_BID)) / 2.0;

      bool adx_ok = (m_adx_value > m_adx_threshold);

      m_has_trend = false;
      if(adx_ok && mid > m_ema_value && m_rsi_value > 50.0)
      {
         m_has_trend = true;
         m_trend_dir = ORDER_TYPE_BUY;
      }
      else if(adx_ok && mid < m_ema_value && m_rsi_value < 50.0)
      {
         m_has_trend = true;
         m_trend_dir = ORDER_TYPE_SELL;
      }

      return true;
   }

   //--- Returns true only when ADX confirms a clear directional trend
   bool HasTrend() { return m_has_trend; }

   //--- Returns the cached direction from the last Update() call.
   //    Always check HasTrend() before relying on this value.
   ENUM_ORDER_TYPE GetTrendDirection() { return m_trend_dir; }

   bool IsTrendUp()   { return m_has_trend && m_trend_dir == ORDER_TYPE_BUY; }
   bool IsTrendDown() { return m_has_trend && m_trend_dir == ORDER_TYPE_SELL; }

   double GetADX() { return m_adx_value; }
   double GetEMA() { return m_ema_value; }
   double GetRSI() { return m_rsi_value; }
   double GetATR() { return m_atr_value; }
};

#endif // TRENDFILTER_MQH
