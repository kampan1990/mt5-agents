//+------------------------------------------------------------------+
//| M2Controller.mqh                                                 |
//| TriMagicGrid EA                                                  |
//| Version: 1.0.0                                                   |
//| Created: 2026.06.07                                              |
//+------------------------------------------------------------------+
#pragma once
#include "Defines.mqh"
#include "Logger.mqh"
#include "PositionTracker.mqh"

//+------------------------------------------------------------------+
//| CM2Controller — state machine that decides when M2 should assist |
//| the losing side, locking one magic while the other recovers.     |
//+------------------------------------------------------------------+
class CM2Controller
{
private:
   //--- State machine data
   ENUM_M2_STATE  m_state;            // Current state (NORMAL / LOCKED_BUY / LOCKED_SELL)
   int            m_m2Direction;      // Active direction: POSITION_TYPE_BUY/SELL or -1
   double         m_lockThreshold;    // Profit level that triggers a lock (negative number)

   //--- ADX trend filter
   int            m_adxHandle;        // iADX indicator handle
   int            m_adxPeriod;        // ADX period
   ENUM_TIMEFRAMES m_adxTf;           // Timeframe for ADX
   double         m_adxThreshold;     // Minimum ADX value to confirm trend
   string         m_symbol;           // Symbol the ADX is computed on

   //--- Dependencies
   CPositionTracker* m_tracker;       // Shared position tracker (not owned)
   CLogger*          m_logger;        // Shared logger (not owned)

   //--- Transition helpers -----------------------------------------------

   //--- Move to LOCKED_BUY: M2 helps buy side (M1 is suffering)
   void LockBuy()
   {
      m_state        = M2_STATE_LOCKED_BUY;
      m_m2Direction  = (int)POSITION_TYPE_BUY;
      m_tracker.SetLocked(MAGIC_M1, true);
      m_tracker.SetLocked(MAGIC_M3, false);

      if(m_logger != NULL)
         m_logger.LogState("M2Controller",
            StringFormat("LOCKED_BUY — lockThreshold=%.2f", m_lockThreshold));
   }

   //--- Move to LOCKED_SELL: M2 helps sell side (M3 is suffering)
   void LockSell()
   {
      m_state        = M2_STATE_LOCKED_SELL;
      m_m2Direction  = (int)POSITION_TYPE_SELL;
      m_tracker.SetLocked(MAGIC_M3, true);
      m_tracker.SetLocked(MAGIC_M1, false);

      if(m_logger != NULL)
         m_logger.LogState("M2Controller",
            StringFormat("LOCKED_SELL — lockThreshold=%.2f", m_lockThreshold));
   }

   //--- Return to NORMAL state
   void Unlock()
   {
      m_state       = M2_STATE_NORMAL;
      m_m2Direction = -1;
      m_tracker.SetLocked(MAGIC_M1, false);
      m_tracker.SetLocked(MAGIC_M3, false);

      if(m_logger != NULL)
         m_logger.LogState("M2Controller", "NORMAL — all locks released");
   }

   //--- Read ADX and return the trend direction using DI lines
   //    Returns POSITION_TYPE_BUY, POSITION_TYPE_SELL, or -1 when undecided
   int GetADXDirection()
   {
      if(m_adxHandle == INVALID_HANDLE) return -1;

      double adxBuf[1], plusDI[1], minusDI[1];

      if(CopyBuffer(m_adxHandle, 0, 1, 1, adxBuf)  < 1) return -1;
      if(CopyBuffer(m_adxHandle, 1, 1, 1, plusDI)   < 1) return -1;
      if(CopyBuffer(m_adxHandle, 2, 1, 1, minusDI)  < 1) return -1;

      if(adxBuf[0] < m_adxThreshold) return -1;  // No strong trend

      return (plusDI[0] > minusDI[0])
             ? (int)POSITION_TYPE_BUY
             : (int)POSITION_TYPE_SELL;
   }

public:
   //+----------------------------------------------------------------+
   //| Constructor — safe defaults                                     |
   //+----------------------------------------------------------------+
   CM2Controller()
      : m_state(M2_STATE_NORMAL), m_m2Direction(-1),
        m_lockThreshold(-500.0), m_adxHandle(INVALID_HANDLE),
        m_adxPeriod(14), m_adxTf(PERIOD_H1), m_adxThreshold(25.0),
        m_symbol(""), m_tracker(NULL), m_logger(NULL) {}

   //+----------------------------------------------------------------+
   //| Init — configure parameters and inject dependencies            |
   //| Parameters:                                                     |
   //|   lockThreshold — profit level (negative) that triggers lock   |
   //|   adxPeriod     — ADX indicator period                         |
   //|   adxTf         — timeframe for ADX calculation                |
   //|   adxThreshold  — minimum ADX value to identify a trend        |
   //|   tracker       — shared position tracker                      |
   //|   logger        — shared logger                                |
   //+----------------------------------------------------------------+
   void Init(double lockThreshold, int adxPeriod, ENUM_TIMEFRAMES adxTf,
             double adxThreshold, CPositionTracker* tracker, CLogger* logger)
   {
      m_lockThreshold = lockThreshold;
      m_adxPeriod     = adxPeriod;
      m_adxTf         = adxTf;
      m_adxThreshold  = adxThreshold;
      m_tracker       = tracker;
      m_logger        = logger;

      if(m_logger != NULL)
         m_logger.LogInfo(StringFormat(
            "CM2Controller::Init — lockThreshold=%.2f adxPeriod=%d adxTf=%s adxThreshold=%.1f",
            m_lockThreshold, m_adxPeriod, EnumToString(m_adxTf), m_adxThreshold));
   }

   //+----------------------------------------------------------------+
   //| CreateIndicators — build iADX handle; call from OnInit()       |
   //| Parameters: symbol — trading symbol                            |
   //| Returns: true on success                                       |
   //+----------------------------------------------------------------+
   bool CreateIndicators(string symbol)
   {
      m_symbol    = symbol;
      m_adxHandle = iADX(symbol, m_adxTf, m_adxPeriod);

      if(m_adxHandle == INVALID_HANDLE)
      {
         if(m_logger != NULL)
            m_logger.LogError("CM2Controller::CreateIndicators",
                              GetLastError(), "iADX creation failed");
         return false;
      }

      if(m_logger != NULL)
         m_logger.LogInfo(StringFormat(
            "CM2Controller::CreateIndicators — ADX handle=%d symbol=%s tf=%s",
            m_adxHandle, symbol, EnumToString(m_adxTf)));
      return true;
   }

   //+----------------------------------------------------------------+
   //| ReleaseIndicators — free indicator handle; call from OnDeinit()|
   //+----------------------------------------------------------------+
   void ReleaseIndicators()
   {
      if(m_adxHandle != INVALID_HANDLE)
      {
         IndicatorRelease(m_adxHandle);
         m_adxHandle = INVALID_HANDLE;
         if(m_logger != NULL)
            m_logger.LogInfo("CM2Controller::ReleaseIndicators — ADX handle released");
      }
   }

   //+----------------------------------------------------------------+
   //| Update — run state machine logic; call once per OnTick()       |
   //+------------------------------------------------------------------
   //| State transitions:
   //|
   //|  NORMAL:
   //|    If M1 totalProfit <= lockThreshold AND M1 worse than M3
   //|       → LOCKED_BUY (M2 assists buy side, M1 grid locked)
   //|    If M3 totalProfit <= lockThreshold AND M3 worse than M1
   //|       → LOCKED_SELL (M2 assists sell side, M3 grid locked)
   //|    Otherwise direction follows ADX
   //|
   //|  LOCKED_BUY:
   //|    If M1 positions == 0    → NORMAL (M1 cleared, unlock)
   //|    If M3 totalProfit <= lockThreshold → LOCKED_SELL (flip)
   //|    M2 direction = BUY
   //|
   //|  LOCKED_SELL:
   //|    If M3 positions == 0    → NORMAL (M3 cleared, unlock)
   //|    If M1 totalProfit <= lockThreshold → LOCKED_BUY (flip)
   //|    M2 direction = SELL
   //+----------------------------------------------------------------+
   void Update()
   {
      MagicState stM1 = m_tracker.GetMagicState(MAGIC_M1);
      MagicState stM3 = m_tracker.GetMagicState(MAGIC_M3);

      switch(m_state)
      {
         //------------------------------------------------------------
         case M2_STATE_NORMAL:
         {
            // Check whether M1 needs help (buy side losing)
            bool m1Suffering = (stM1.totalPositions > 0 &&
                                stM1.totalProfit <= m_lockThreshold &&
                                stM1.totalProfit < stM3.totalProfit);

            // Check whether M3 needs help (sell side losing)
            bool m3Suffering = (stM3.totalPositions > 0 &&
                                stM3.totalProfit <= m_lockThreshold &&
                                stM3.totalProfit < stM1.totalProfit);

            if(m1Suffering)
            {
               LockBuy();
               break;
            }
            if(m3Suffering)
            {
               LockSell();
               break;
            }

            // No lock active — direction follows ADX trend filter
            m_m2Direction = GetADXDirection();
            break;
         }

         //------------------------------------------------------------
         case M2_STATE_LOCKED_BUY:
         {
            // M1 has fully closed — crisis resolved
            if(stM1.totalPositions == 0)
            {
               Unlock();
               break;
            }

            // M3 has now deteriorated worse — flip the helping side
            if(stM3.totalPositions > 0 && stM3.totalProfit <= m_lockThreshold)
            {
               LockSell();
               break;
            }

            // Continue assisting buy side
            m_m2Direction = (int)POSITION_TYPE_BUY;
            break;
         }

         //------------------------------------------------------------
         case M2_STATE_LOCKED_SELL:
         {
            // M3 has fully closed — crisis resolved
            if(stM3.totalPositions == 0)
            {
               Unlock();
               break;
            }

            // M1 has now deteriorated worse — flip the helping side
            if(stM1.totalPositions > 0 && stM1.totalProfit <= m_lockThreshold)
            {
               LockBuy();
               break;
            }

            // Continue assisting sell side
            m_m2Direction = (int)POSITION_TYPE_SELL;
            break;
         }
      }
   }

   //+----------------------------------------------------------------+
   //| GetM2Direction — direction M2 should trade this tick           |
   //| Returns: POSITION_TYPE_BUY (0), POSITION_TYPE_SELL (1), or -1  |
   //+----------------------------------------------------------------+
   int GetM2Direction()
   {
      return m_m2Direction;
   }

   //+----------------------------------------------------------------+
   //| GetState — return current state snapshot                       |
   //+----------------------------------------------------------------+
   M2StateInfo GetState()
   {
      M2StateInfo info;
      info.state          = m_state;
      info.helpingSide    = m_m2Direction;
      info.lockThreshold  = m_lockThreshold;
      info.waitingClear   = (m_state == M2_STATE_LOCKED_BUY ||
                             m_state == M2_STATE_LOCKED_SELL);
      return info;
   }
};
