//+------------------------------------------------------------------+
//| RecoveryManager.mqh                                               |
//| GridADXEMARSI EA                                                  |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-14                                               |
//+------------------------------------------------------------------+
#ifndef RECOVERYMANAGER_MQH
#define RECOVERYMANAGER_MQH

#include "GridManager.mqh"

//+------------------------------------------------------------------+
//| CRecoveryManager — martingale-style counter-trend recovery       |
//|                                                                    |
//| When the grid is losing, opens orders in the opposite direction   |
//| with a multiplied lot size to reduce the weighted average entry   |
//| price and allow the combined position to break even sooner.       |
//+------------------------------------------------------------------+
class CRecoveryManager
{
private:
   double          m_recovery_distance;      // points from weighted avg before triggering
   double          m_multiplier;             // lot multiplier per recovery layer
   int             m_max_recovery_orders;    // hard cap on recovery layers
   int             m_recovery_count;         // number of recovery orders placed so far
   double          m_last_recovery_price;    // execution price of the most recent recovery order
   ENUM_ORDER_TYPE m_last_recovery_type;     // type of the most recent recovery order
   long            m_magic;
   string          m_symbol;
   CGridManager*   m_grid_mgr;              // shared pointer — not owned

   CTrade          m_trade;

public:
   //--- Constructor
   CRecoveryManager()
   {
      m_recovery_distance   = 100.0;
      m_multiplier          = 2.0;
      m_max_recovery_orders = 5;
      m_recovery_count      = 0;
      m_last_recovery_price = 0.0;
      m_last_recovery_type  = ORDER_TYPE_BUY;
      m_magic               = 0;
      m_grid_mgr            = NULL;
   }

   //--- Initialise the recovery manager.
   //  @param recovery_distance    points from weighted average price that triggers recovery
   //  @param multiplier           lot multiplier applied each recovery layer
   //  @param max_recovery_orders  maximum number of recovery layers before giving up
   //  @param magic                EA magic number
   //  @param symbol               trading symbol
   //  @param grid_mgr             pointer to the shared CGridManager instance
   //  @return true always
   bool Init(double        recovery_distance,
             double        multiplier,
             int           max_recovery_orders,
             long          magic,
             string        symbol,
             CGridManager* grid_mgr)
   {
      m_recovery_distance   = recovery_distance;
      m_multiplier          = multiplier;
      m_max_recovery_orders = max_recovery_orders;
      m_magic               = magic;
      m_symbol              = symbol;
      m_grid_mgr            = grid_mgr;

      m_trade.SetExpertMagicNumber(m_magic);
      m_trade.SetDeviationInPoints(10);
      m_trade.SetTypeFilling(ORDER_FILLING_FOK);

      return true;
   }

   //--- Check whether market has moved far enough from the weighted average
   //  to justify opening a recovery order.
   //
   //  BUY grid:  Bid < weighted_avg - recovery_distance * _Point
   //  SELL grid: Ask > weighted_avg + recovery_distance * _Point
   //
   //  @return true when a recovery order should be opened
   bool IsRecoveryNeeded()
   {
      if(m_grid_mgr == NULL)             return false;
      if(!m_grid_mgr.HasActiveOrders())  return false;

      double avg = m_grid_mgr.GetAveragePriceWeighted();
      if(avg <= 0.0) return false;

      ENUM_ORDER_TYPE dir = m_grid_mgr.GetGridDirection();

      if(dir == ORDER_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         return (bid < avg - m_recovery_distance * _Point);
      }
      else
      {
         double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         return (ask > avg + m_recovery_distance * _Point);
      }
   }

   //--- Open one recovery order.
   //  The lot is base_lot * multiplier^current_count (before incrementing).
   //  The direction is opposite to the main grid direction.
   //  @param base_lot   the base lot of the main grid
   //  @param sl_points  stop-loss in points from execution price
   //  @return true on success
   bool OpenRecoveryOrder(double base_lot, double sl_points)
   {
      if(m_grid_mgr == NULL) return false;
      if(!CanRecover())      return false;

      // Recovery direction is opposite to the grid direction
      ENUM_ORDER_TYPE grid_dir     = m_grid_mgr.GetGridDirection();
      ENUM_ORDER_TYPE recovery_dir = (grid_dir == ORDER_TYPE_BUY)
                                     ? ORDER_TYPE_SELL
                                     : ORDER_TYPE_BUY;

      // lot = base_lot * multiplier^count  (exponential scaling)
      double lot = base_lot;
      for(int i = 0; i < m_recovery_count; i++)
         lot *= m_multiplier;

      // Normalise lot
      double step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      double vmin = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double vmax = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      if(step > 0.0)
         lot = MathFloor(lot / step) * step;
      if(lot < vmin) lot = vmin;
      if(lot > vmax) lot = vmax;
      lot = NormalizeDouble(lot, 2);

      // Price and SL
      double price, sl;
      if(recovery_dir == ORDER_TYPE_BUY)
      {
         price = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         sl    = price - sl_points * _Point;
      }
      else
      {
         price = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         sl    = price + sl_points * _Point;
      }

      if(sl <= 0.0)
      {
         Print("RecoveryManager.OpenRecoveryOrder: invalid SL — order rejected");
         return false;
      }

      sl = NormalizeDouble(sl, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS));

      string comment = StringFormat("GADX_REC_%d", m_recovery_count);

      bool ok;
      if(recovery_dir == ORDER_TYPE_BUY)
         ok = m_trade.Buy(lot, m_symbol, 0, sl, 0, comment);
      else
         ok = m_trade.Sell(lot, m_symbol, 0, sl, 0, comment);

      if(!ok)
      {
         Print("RecoveryManager.OpenRecoveryOrder: CTrade failed, retcode=",
               m_trade.ResultRetcode(),
               "  comment=", m_trade.ResultComment());
         return false;
      }

      ulong ticket = m_trade.ResultDeal();

      // Register in the shared grid manager so profit totals include it
      SOrderRecord rec;
      rec.ticket      = ticket;
      rec.type        = recovery_dir;
      rec.lot         = lot;
      rec.open_price  = price;
      rec.is_recovery = true;
      rec.sequence    = m_recovery_count;
      m_grid_mgr.AddOrderRecord(rec);

      m_last_recovery_price = price;
      m_last_recovery_type  = recovery_dir;
      m_recovery_count++;

      Print("RecoveryManager: opened #", ticket,
            "  ", EnumToString(recovery_dir),
            "  lot=", lot,
            "  recovery_count=", m_recovery_count);

      return true;
   }

   //--- Check whether the price has moved far enough from the last recovery
   //  entry to warrant opening another recovery layer.
   //
   //  If last recovery was SELL: Ask > last_price + recovery_distance * _Point
   //  If last recovery was BUY:  Bid < last_price - recovery_distance * _Point
   //
   //  @return true when another layer should be opened
   bool ShouldContinueRecovery()
   {
      if(m_recovery_count == 0)        return false;
      if(m_last_recovery_price <= 0.0) return false;

      if(m_last_recovery_type == ORDER_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         return (ask > m_last_recovery_price + m_recovery_distance * _Point);
      }
      else
      {
         double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         return (bid < m_last_recovery_price - m_recovery_distance * _Point);
      }
   }

   //--- Returns true when more recovery orders can still be opened.
   bool CanRecover() { return (m_recovery_count < m_max_recovery_orders); }

   //--- Returns the number of recovery orders placed in this cycle.
   int GetRecoveryCount() { return m_recovery_count; }

   //--- Reset recovery state for a new cycle.
   void Reset()
   {
      m_recovery_count      = 0;
      m_last_recovery_price = 0.0;
   }
};

#endif // RECOVERYMANAGER_MQH
