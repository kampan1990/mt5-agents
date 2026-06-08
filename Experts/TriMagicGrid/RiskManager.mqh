//+------------------------------------------------------------------+
//| RiskManager.mqh                                                  |
//| TriMagicGrid EA                                                  |
//| Version: 1.0.0                                                   |
//| Created: 2026.06.07                                              |
//+------------------------------------------------------------------+
#pragma once
#include "Defines.mqh"
#include "Logger.mqh"
#include "Utils.mqh"

//+------------------------------------------------------------------+
//| CRiskManager — lot sizing, drawdown guard, and kill switch       |
//+------------------------------------------------------------------+
class CRiskManager
{
private:
   double   m_maxDDPct;          // Maximum allowed drawdown as % of balance
   double   m_dailyLossLimit;    // Maximum allowed daily loss in account currency
   double   m_baseLotPct;        // Base lot as % of balance (e.g. 0.5 = 0.5%)
   double   m_maxLotPerOrder;    // Hard cap on a single order lot
   double   m_maxTotalLots;      // Hard cap on total open lots across all magics

   double   m_initialEquity;     // Equity snapshot at session start (for DD calc)
   double   m_dailyStartEquity;  // Equity snapshot at start of trading day
   datetime m_lastDayDate;       // Date of last OnNewDay() call (day portion only)

   bool     m_killSwitch;        // Manual emergency stop flag

   CLogger* m_logger;            // Shared logger (not owned)

   //--- Return true when a valid broker account is available
   bool IsAccountReady() const
   {
      return AccountInfoDouble(ACCOUNT_BALANCE) > 0.0;
   }

public:
   //+----------------------------------------------------------------+
   //| Constructor — safe defaults                                     |
   //+----------------------------------------------------------------+
   CRiskManager()
      : m_maxDDPct(20.0), m_dailyLossLimit(300.0),
        m_baseLotPct(0.5), m_maxLotPerOrder(10.0), m_maxTotalLots(50.0),
        m_initialEquity(0.0), m_dailyStartEquity(0.0),
        m_lastDayDate(0), m_killSwitch(false), m_logger(NULL) {}

   //+----------------------------------------------------------------+
   //| Init — configure all risk parameters                           |
   //| Parameters:                                                     |
   //|   maxDDPct       — max drawdown % before trading halts         |
   //|   dailyLossLimit — max daily loss in account currency          |
   //|   baseLotPct     — base lot as % of current balance            |
   //|   maxLotPerOrder — per-order lot ceiling                        |
   //|   maxTotalLots   — total open lot ceiling across all magics     |
   //|   logger         — shared logger instance (not owned)           |
   //+----------------------------------------------------------------+
   void Init(double maxDDPct, double dailyLossLimit, double baseLotPct,
             double maxLotPerOrder, double maxTotalLots, CLogger* logger)
   {
      m_maxDDPct       = maxDDPct;
      m_dailyLossLimit = dailyLossLimit;
      m_baseLotPct     = baseLotPct;
      m_maxLotPerOrder = maxLotPerOrder;
      m_maxTotalLots   = maxTotalLots;
      m_logger         = logger;

      m_initialEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
      m_dailyStartEquity  = m_initialEquity;
      m_killSwitch        = false;

      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      m_lastDayDate = StructToTime(dt);

      if(m_logger != NULL)
         m_logger.LogInfo(StringFormat(
            "CRiskManager::Init — maxDD=%.1f%% dailyLoss=%.2f baseLotPct=%.3f "
            "maxLotPerOrder=%.2f maxTotalLots=%.2f initialEquity=%.2f",
            m_maxDDPct, m_dailyLossLimit, m_baseLotPct,
            m_maxLotPerOrder, m_maxTotalLots, m_initialEquity));
   }

   //+----------------------------------------------------------------+
   //| OnNewDay — reset daily loss tracker; call at session start     |
   //+----------------------------------------------------------------+
   void OnNewDay()
   {
      m_dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);

      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      m_lastDayDate = StructToTime(dt);

      if(m_logger != NULL)
         m_logger.LogInfo(StringFormat(
            "CRiskManager::OnNewDay — dailyStartEquity reset to %.2f",
            m_dailyStartEquity));
   }

   //+----------------------------------------------------------------+
   //| SetKillSwitch — manually halt all trading                      |
   //| Parameters: val — true to engage kill switch                   |
   //+----------------------------------------------------------------+
   void SetKillSwitch(bool val)
   {
      m_killSwitch = val;
      if(m_logger != NULL)
         m_logger.LogWarn(StringFormat(
            "CRiskManager::SetKillSwitch — killSwitch=%s",
            val ? "ON" : "OFF"));
   }

   //+----------------------------------------------------------------+
   //| GetCurrentDrawdownPct — % drop from initial equity             |
   //| Returns: positive number representing drawdown percentage      |
   //+----------------------------------------------------------------+
   double GetCurrentDrawdownPct()
   {
      if(m_initialEquity <= 0.0) return 0.0;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double dd     = (m_initialEquity - equity) / m_initialEquity * 100.0;
      return MathMax(dd, 0.0);
   }

   //+----------------------------------------------------------------+
   //| IsDrawdownExceeded — true when current DD exceeds threshold    |
   //+----------------------------------------------------------------+
   bool IsDrawdownExceeded()
   {
      double dd = GetCurrentDrawdownPct();
      if(dd >= m_maxDDPct)
      {
         if(m_logger != NULL)
            m_logger.LogWarn(StringFormat(
               "CRiskManager — drawdown %.2f%% >= limit %.2f%%; trading halted",
               dd, m_maxDDPct));
         return true;
      }
      return false;
   }

   //+----------------------------------------------------------------+
   //| IsDailyLossLimitExceeded — true when day loss >= limit         |
   //+----------------------------------------------------------------+
   bool IsDailyLossLimitExceeded()
   {
      double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
      double dailyLoss  = m_dailyStartEquity - equity;   // Positive = loss
      if(dailyLoss >= m_dailyLossLimit)
      {
         if(m_logger != NULL)
            m_logger.LogWarn(StringFormat(
               "CRiskManager — daily loss %.2f >= limit %.2f; trading halted",
               dailyLoss, m_dailyLossLimit));
         return true;
      }
      return false;
   }

   //+----------------------------------------------------------------+
   //| IsTradingAllowed — master gate check before any order          |
   //| Returns: false when kill switch, drawdown, or daily loss fires |
   //+----------------------------------------------------------------+
   bool IsTradingAllowed()
   {
      if(m_killSwitch)
      {
         if(m_logger != NULL)
            m_logger.LogWarn("CRiskManager::IsTradingAllowed — kill switch active");
         return false;
      }
      if(IsDrawdownExceeded())    return false;
      if(IsDailyLossLimitExceeded()) return false;
      return true;
   }

   //+----------------------------------------------------------------+
   //| CalcBaseLot — compute lot from balance * baseLotPct / 100      |
   //| Parameters: symbol — trading symbol for normalization          |
   //| Returns: normalized lot clamped to maxLotPerOrder              |
   //+----------------------------------------------------------------+
   double CalcBaseLot(string symbol)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(balance <= 0.0) return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

      double raw = balance * m_baseLotPct / 100.0;
      return ClampLot(raw, symbol);
   }

   //+----------------------------------------------------------------+
   //| ClampLot — normalize lot to symbol step and apply all limits   |
   //| Parameters:                                                     |
   //|   raw    — unclamped lot value                                 |
   //|   symbol — trading symbol                                      |
   //| Returns: valid lot size within broker + EA limits              |
   //+----------------------------------------------------------------+
   double ClampLot(double raw, string symbol)
   {
      // Apply per-order ceiling first
      double lot = MathMin(raw, m_maxLotPerOrder);

      // Normalise to broker volume step / min / max
      lot = NormalizeLot(symbol, lot);

      return lot;
   }

   //+----------------------------------------------------------------+
   //| GetMaxTotalLots — return the total lots ceiling                |
   //+----------------------------------------------------------------+
   double GetMaxTotalLots() const { return m_maxTotalLots; }
};
