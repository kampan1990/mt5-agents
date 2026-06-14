//+------------------------------------------------------------------+
//| TrendFilter.mqh                                                   |
//| GridADXEMARSI EA                                                  |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-14                                               |
//+------------------------------------------------------------------+
#ifndef TRENDFILTER_MQH
#define TRENDFILTER_MQH

//+------------------------------------------------------------------+
//| CTrendFilter — ADX + EMA + RSI composite trend detector          |
//|                                                                    |
//| Rules:                                                             |
//|   IsTrendUp()   = ADX > threshold  AND  Ask > EMA  AND  RSI > 50 |
//|   IsTrendDown() = ADX > threshold  AND  Bid < EMA  AND  RSI < 50 |
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

   double          m_adx_value;   // latest main ADX line value
   double          m_ema_value;   // latest EMA value
   double          m_rsi_value;   // latest RSI value
   double          m_atr_value;   // latest ATR value (price units)

   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;

public:
   //--- Constructor: zero-initialise handles so Deinit is safe before Init
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
      m_adx_period    = 14;
      m_adx_threshold = 25.0;
      m_ema_period    = 200;
      m_rsi_period    = 14;
      m_atr_period    = 14;
   }

   //--- Initialise indicator handles
   //  @param adx_period      ADX smoothing period
   //  @param adx_threshold   minimum ADX value to classify as trending
   //  @param ema_period      EMA period for price vs. average filter
   //  @param rsi_period      RSI period for momentum confirmation
   //  @param symbol          symbol to attach indicators to
   //  @param tf              timeframe to attach indicators to
   //  @return true on success, false if any handle is invalid
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

   //--- Release indicator handles
   void Deinit()
   {
      if(m_adx_handle != INVALID_HANDLE) { IndicatorRelease(m_adx_handle); m_adx_handle = INVALID_HANDLE; }
      if(m_ema_handle != INVALID_HANDLE) { IndicatorRelease(m_ema_handle); m_ema_handle = INVALID_HANDLE; }
      if(m_rsi_handle != INVALID_HANDLE) { IndicatorRelease(m_rsi_handle); m_rsi_handle = INVALID_HANDLE; }
      if(m_atr_handle != INVALID_HANDLE) { IndicatorRelease(m_atr_handle); m_atr_handle = INVALID_HANDLE; }
   }

   //--- Refresh cached indicator values from the terminal buffer
   //  Must be called once per tick before any IsTrendUp/IsTrendDown check.
   //  @return true if all three values were read successfully
   bool Update()
   {
      double adx_buf[1];
      double ema_buf[1];
      double rsi_buf[1];
      double atr_buf[1];

      if(CopyBuffer(m_adx_handle, 0, 0, 1, adx_buf) != 1) return false;
      if(CopyBuffer(m_ema_handle, 0, 0, 1, ema_buf) != 1) return false;
      if(CopyBuffer(m_rsi_handle, 0, 0, 1, rsi_buf) != 1) return false;
      if(CopyBuffer(m_atr_handle, 0, 0, 1, atr_buf) != 1) return false;

      m_adx_value = adx_buf[0];
      m_ema_value = ema_buf[0];
      m_rsi_value = rsi_buf[0];
      m_atr_value = atr_buf[0];

      return true;
   }

   //--- True when ADX shows a trend AND price is above EMA AND RSI > 50
   bool IsTrendUp()
   {
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      return (m_adx_value > m_adx_threshold) &&
             (ask         > m_ema_value)     &&
             (m_rsi_value > 50.0);
   }

   //--- True when ADX shows a trend AND price is below EMA AND RSI < 50
   bool IsTrendDown()
   {
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      return (m_adx_value > m_adx_threshold) &&
             (bid         < m_ema_value)     &&
             (m_rsi_value < 50.0);
   }

   //--- True when any directional trend is detected
   bool HasTrend()
   {
      return IsTrendUp() || IsTrendDown();
   }

   //--- Returns ORDER_TYPE_BUY when uptrend, ORDER_TYPE_SELL otherwise.
   //  Caller should check HasTrend() before relying on this value.
   ENUM_ORDER_TYPE GetTrendDirection()
   {
      return IsTrendUp() ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   }

   //--- Accessors for the last cached indicator values
   double GetADX() { return m_adx_value; }
   double GetEMA() { return m_ema_value; }
   double GetRSI() { return m_rsi_value; }
   double GetATR() { return m_atr_value; }  // ATR in price units (e.g. 1.5 USD for XAUUSD)
};

#endif // TRENDFILTER_MQH
