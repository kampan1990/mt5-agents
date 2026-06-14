//+------------------------------------------------------------------+
//| TrailingManager.mqh                                               |
//| Gridindy EA                                                  |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-14                                               |
//+------------------------------------------------------------------+
#ifndef TRAILINGMANAGER_MQH
#define TRAILINGMANAGER_MQH

#include "GridManager.mqh"

//+------------------------------------------------------------------+
//| CTrailingManager — moves stop-loss of all managed positions      |
//|                                                                    |
//| BUY  trail: new_sl = Bid - trail_distance * _Point               |
//|             update only if new_sl > current_sl + trail_step * _Point |
//| SELL trail: new_sl = Ask + trail_distance * _Point               |
//|             update only if new_sl < current_sl - trail_step * _Point |
//+------------------------------------------------------------------+
class CTrailingManager
{
private:
   double  m_trail_distance;   // distance from current price to the trailing SL (points)
   double  m_trail_step;       // minimum SL movement required before updating (points)
   long    m_magic;
   string  m_symbol;
   bool    m_trailing_active;

   CTrade  m_trade;

public:
   //--- Constructor
   CTrailingManager()
   {
      m_trail_distance  = 50.0;
      m_trail_step      = 10.0;
      m_magic           = 0;
      m_trailing_active = false;
   }

   //--- Initialise the trailing manager.
   //  @param trail_distance  distance behind price for the trailing SL (points)
   //  @param trail_step      minimum improvement before modifying SL (points)
   //  @param magic           EA magic number
   //  @param symbol          trading symbol
   //  @return true always
   bool Init(double trail_distance, double trail_step, long magic, string symbol)
   {
      m_trail_distance  = trail_distance;
      m_trail_step      = trail_step;
      m_magic           = magic;
      m_symbol          = symbol;
      m_trailing_active = false;

      m_trade.SetExpertMagicNumber(m_magic);
      m_trade.SetDeviationInPoints(10);
      // FIX: query broker-supported filling mode
      int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
      ENUM_ORDER_TYPE_FILLING fill_mode = ORDER_FILLING_RETURN;
      if((filling & 1) != 0)      fill_mode = ORDER_FILLING_FOK;
      else if((filling & 2) != 0) fill_mode = ORDER_FILLING_IOC;
      m_trade.SetTypeFilling(fill_mode);

      return true;
   }

   //--- Activate trailing (called when profit target is reached).
   void Activate()
   {
      m_trailing_active = true;
   }

   //--- Deactivate trailing (called on reset).
   void Deactivate()
   {
      m_trailing_active = false;
   }

   //--- Returns true when trailing is active.
   bool IsActive() { return m_trailing_active; }

   //--- Apply trailing stop logic to every position registered in grid_mgr.
   //  Must be called every tick while in STATE_TRAILING.
   //  @param grid_mgr  pointer to the CGridManager that owns the positions
   void UpdateTrails(CGridManager* grid_mgr)
   {
      if(!m_trailing_active) return;
      if(grid_mgr == NULL)   return;

      int    count = 0;
      SOrderRecord orders[];
      grid_mgr.GetOrders(orders, count);

      int    digits   = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      double bid      = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask      = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double dist_pts = m_trail_distance * _Point;
      double step_pts = m_trail_step     * _Point;

      for(int i = 0; i < count; i++)
      {
         ulong ticket = orders[i].ticket;
         if(!PositionSelectByTicket(ticket)) continue;

         ENUM_POSITION_TYPE pos_type  = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double             current_sl = PositionGetDouble(POSITION_SL);
         double             new_sl     = 0.0;

         if(pos_type == POSITION_TYPE_BUY)
         {
            new_sl = NormalizeDouble(bid - dist_pts, digits);
            // Only update if improvement exceeds trail_step
            if(new_sl <= current_sl + step_pts) continue;
         }
         else // POSITION_TYPE_SELL
         {
            new_sl = NormalizeDouble(ask + dist_pts, digits);
            // Only update if improvement exceeds trail_step
            if(new_sl >= current_sl - step_pts) continue;
         }

         // Retrieve current TP (unchanged)
         double current_tp = PositionGetDouble(POSITION_TP);

         if(!m_trade.PositionModify(ticket, new_sl, current_tp))
         {
            Print("TrailingManager.UpdateTrails: PositionModify failed for #", ticket,
                  "  retcode=", m_trade.ResultRetcode(),
                  "  new_sl=",  new_sl);
         }
      }
   }

   //--- Reset trailing state for a new cycle.
   void Reset()
   {
      m_trailing_active = false;
   }
};

#endif // TRAILINGMANAGER_MQH
