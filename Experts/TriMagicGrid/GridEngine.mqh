//+------------------------------------------------------------------+
//| GridEngine.mqh                                                   |
//| TriMagicGrid EA                                                  |
//| Version: 1.0.0                                                   |
//| Created: 2026.06.07                                              |
//+------------------------------------------------------------------+
#pragma once
#include "Defines.mqh"
#include "Logger.mqh"
#include "Utils.mqh"
#include "PositionTracker.mqh"
#include "RiskManager.mqh"

//+------------------------------------------------------------------+
//| CGridEngine — determines when to add a new grid level and        |
//| how many lots to trade for M1 (buy), M3 (sell), and M2 (assist).|
//+------------------------------------------------------------------+
class CGridEngine
{
private:
   double             m_gridPoints;      // Distance between grid levels in points
   double             m_buyDownMult;     // Lot multiplier when buy price moves down (martingale)
   double             m_buyUpMult;       // Lot multiplier when buy price moves up (scale-in)
   double             m_sellUpMult;      // Lot multiplier when sell price moves up (martingale)
   double             m_sellDownMult;    // Lot multiplier when sell price moves down (scale-in)

   CPositionTracker*  m_tracker;         // Shared position tracker (not owned)
   CRiskManager*      m_risk;            // Shared risk manager (not owned)
   CLogger*           m_logger;          // Shared logger (not owned)

   string             m_symbol;          // Trading symbol

   //--- Compute the next lot for a buy grid addition
   //    If the new price is below the last price (adverse move) use buyDownMult,
   //    otherwise use buyUpMult relative to the last lots.
   double CalcNextBuyLot(double askPrice)
   {
      if(!m_tracker.HasPositions(MAGIC_M1))
         return m_risk.CalcBaseLot(m_symbol);

      double lastPrice = m_tracker.GetLastGridPrice(MAGIC_M1);
      double baseLot   = m_risk.CalcBaseLot(m_symbol);
      MagicState st    = m_tracker.GetMagicState(MAGIC_M1);

      // Use average lots as reference for multiplier
      double avgLot = (st.totalPositions > 0)
                      ? st.totalLots / st.totalPositions
                      : baseLot;

      double mult = (askPrice < lastPrice) ? m_buyDownMult : m_buyUpMult;
      double raw  = avgLot * mult;
      return m_risk.ClampLot(raw, m_symbol);
   }

   //--- Compute the next lot for a sell grid addition
   double CalcNextSellLot(double bidPrice)
   {
      if(!m_tracker.HasPositions(MAGIC_M3))
         return m_risk.CalcBaseLot(m_symbol);

      double lastPrice = m_tracker.GetLastGridPrice(MAGIC_M3);
      double baseLot   = m_risk.CalcBaseLot(m_symbol);
      MagicState st    = m_tracker.GetMagicState(MAGIC_M3);

      double avgLot = (st.totalPositions > 0)
                      ? st.totalLots / st.totalPositions
                      : baseLot;

      double mult = (bidPrice > lastPrice) ? m_sellUpMult : m_sellDownMult;
      double raw  = avgLot * mult;
      return m_risk.ClampLot(raw, m_symbol);
   }

   //--- True when adding the next lot would not exceed the total lots ceiling
   bool TotalLotsAllowed(double nextLot)
   {
      double totalNow = 0.0;
      for(int id = 0; id < 3; id++)
      {
         MagicState st = m_tracker.GetMagicState((ENUM_MAGIC_ID)id);
         totalNow += st.totalLots;
      }
      return (totalNow + nextLot) <= m_risk.GetMaxTotalLots();
   }

public:
   //+----------------------------------------------------------------+
   //| Constructor — zero-initialise all members                      |
   //+----------------------------------------------------------------+
   CGridEngine()
      : m_gridPoints(100.0), m_buyDownMult(2.0), m_buyUpMult(1.1),
        m_sellUpMult(2.0), m_sellDownMult(1.1),
        m_tracker(NULL), m_risk(NULL), m_logger(NULL), m_symbol("") {}

   //+----------------------------------------------------------------+
   //| Init — configure grid parameters and inject dependencies       |
   //| Parameters:                                                     |
   //|   gridPoints    — gap between levels in symbol points           |
   //|   buyDownMult   — lot multiplier on adverse buy move            |
   //|   buyUpMult     — lot multiplier on favourable buy move         |
   //|   sellUpMult    — lot multiplier on adverse sell move           |
   //|   sellDownMult  — lot multiplier on favourable sell move        |
   //|   symbol        — trading symbol                               |
   //|   tracker       — pointer to shared position tracker           |
   //|   risk          — pointer to shared risk manager               |
   //|   logger        — pointer to shared logger                     |
   //+----------------------------------------------------------------+
   void Init(double gridPoints, double buyDownMult, double buyUpMult,
             double sellUpMult, double sellDownMult,
             string symbol,
             CPositionTracker* tracker, CRiskManager* risk, CLogger* logger)
   {
      m_gridPoints   = gridPoints;
      m_buyDownMult  = buyDownMult;
      m_buyUpMult    = buyUpMult;
      m_sellUpMult   = sellUpMult;
      m_sellDownMult = sellDownMult;
      m_symbol       = symbol;
      m_tracker      = tracker;
      m_risk         = risk;
      m_logger       = logger;

      if(m_logger != NULL)
         m_logger.LogInfo(StringFormat(
            "CGridEngine::Init — gridPoints=%.1f buyDown=%.2f buyUp=%.2f "
            "sellUp=%.2f sellDown=%.2f symbol=%s",
            m_gridPoints, m_buyDownMult, m_buyUpMult,
            m_sellUpMult, m_sellDownMult, m_symbol));
   }

   //+----------------------------------------------------------------+
   //| ShouldAddBuy — decide whether to open a new M1 buy level      |
   //| Parameters:                                                     |
   //|   askPrice — current ASK price                                 |
   //|   nextLot  — [out] lot size to use if returning true           |
   //| Returns: true when a new buy grid level should be opened       |
   //+----------------------------------------------------------------+
   bool ShouldAddBuy(double askPrice, double &nextLot)
   {
      nextLot = 0.0;

      // No positions yet — trigger on first call (initial entry)
      if(!m_tracker.HasPositions(MAGIC_M1))
      {
         nextLot = m_risk.CalcBaseLot(m_symbol);
         if(!TotalLotsAllowed(nextLot)) return false;
         return true;
      }

      double lastPrice = m_tracker.GetLastGridPrice(MAGIC_M1);
      double gridDist  = PointsToPrice(m_symbol, m_gridPoints);

      // Open next level only when price has moved at least gridDist below last entry
      if(askPrice > lastPrice - gridDist) return false;

      nextLot = CalcNextBuyLot(askPrice);
      if(!TotalLotsAllowed(nextLot))
      {
         if(m_logger != NULL)
            m_logger.LogWarn("CGridEngine::ShouldAddBuy — total lots ceiling reached");
         return false;
      }
      return true;
   }

   //+----------------------------------------------------------------+
   //| ShouldAddSell — decide whether to open a new M3 sell level    |
   //| Parameters:                                                     |
   //|   bidPrice — current BID price                                 |
   //|   nextLot  — [out] lot size to use if returning true           |
   //| Returns: true when a new sell grid level should be opened      |
   //+----------------------------------------------------------------+
   bool ShouldAddSell(double bidPrice, double &nextLot)
   {
      nextLot = 0.0;

      if(!m_tracker.HasPositions(MAGIC_M3))
      {
         nextLot = m_risk.CalcBaseLot(m_symbol);
         if(!TotalLotsAllowed(nextLot)) return false;
         return true;
      }

      double lastPrice = m_tracker.GetLastGridPrice(MAGIC_M3);
      double gridDist  = PointsToPrice(m_symbol, m_gridPoints);

      // Open next level only when price has moved at least gridDist above last entry
      if(bidPrice < lastPrice + gridDist) return false;

      nextLot = CalcNextSellLot(bidPrice);
      if(!TotalLotsAllowed(nextLot))
      {
         if(m_logger != NULL)
            m_logger.LogWarn("CGridEngine::ShouldAddSell — total lots ceiling reached");
         return false;
      }
      return true;
   }

   //+----------------------------------------------------------------+
   //| ShouldAddM2 — decide whether to open a new M2 assist level    |
   //| Parameters:                                                     |
   //|   direction — POSITION_TYPE_BUY or POSITION_TYPE_SELL          |
   //|   price     — current ASK (buy) or BID (sell) price            |
   //|   nextLot   — [out] lot size to use if returning true          |
   //| Returns: true when a new M2 level should be opened             |
   //+----------------------------------------------------------------+
   bool ShouldAddM2(ENUM_POSITION_TYPE direction, double price, double &nextLot)
   {
      nextLot = 0.0;

      if(!m_tracker.HasPositions(MAGIC_M2))
      {
         nextLot = m_risk.CalcBaseLot(m_symbol);
         if(!TotalLotsAllowed(nextLot)) return false;
         return true;
      }

      double lastPrice = m_tracker.GetLastGridPrice(MAGIC_M2);
      double gridDist  = PointsToPrice(m_symbol, m_gridPoints);

      bool distanceMet = false;
      if(direction == POSITION_TYPE_BUY)
         distanceMet = (price <= lastPrice - gridDist);
      else
         distanceMet = (price >= lastPrice + gridDist);

      if(!distanceMet) return false;

      // M2 always uses base lot (it follows the direction from M2Controller)
      nextLot = m_risk.CalcBaseLot(m_symbol);
      if(!TotalLotsAllowed(nextLot))
      {
         if(m_logger != NULL)
            m_logger.LogWarn("CGridEngine::ShouldAddM2 — total lots ceiling reached");
         return false;
      }
      return true;
   }

   //+----------------------------------------------------------------+
   //| CalcBaseLot — delegate to RiskManager                         |
   //| Parameters: symbol — trading symbol                            |
   //| Returns: base lot size from RiskManager                        |
   //+----------------------------------------------------------------+
   double CalcBaseLot(string symbol)
   {
      return m_risk.CalcBaseLot(symbol);
   }
};
