//+------------------------------------------------------------------+
//| GridManager.mqh                                                   |
//| GridADXEMARSI EA                                                  |
//| Version: 1.0.0                                                    |
//| Created: 2026-06-14                                               |
//+------------------------------------------------------------------+
#ifndef GRIDMANAGER_MQH
#define GRIDMANAGER_MQH

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| SOrderRecord — lightweight record kept for every managed position |
//+------------------------------------------------------------------+
struct SOrderRecord
{
   ulong           ticket;
   ENUM_ORDER_TYPE type;
   double          lot;
   double          open_price;
   bool            is_recovery;
   int             sequence;     // 0-based index within the grid
};

//+------------------------------------------------------------------+
//| CGridManager — opens, tracks and closes the grid of positions    |
//+------------------------------------------------------------------+
class CGridManager
{
private:
   SOrderRecord    m_orders[];       // in-memory order register
   int             m_order_count;    // current used slots in m_orders[]
   double          m_grid_distance;  // distance between grid levels (points)
   int             m_max_grid_orders;
   double          m_base_lot;
   long            m_magic;
   string          m_symbol;
   double          m_last_grid_price;    // price at which last grid order was opened
   ENUM_ORDER_TYPE m_grid_direction;     // direction of the base order
   bool            m_opening_order;      // reentrancy guard

   CTrade          m_trade;             // MQL5 trade helper

public:
   //--- Constructor
   CGridManager()
   {
      m_order_count     = 0;
      m_grid_distance   = 100.0;
      m_max_grid_orders = 5;
      m_base_lot        = 0.01;
      m_magic           = 0;
      m_last_grid_price = 0.0;
      m_grid_direction  = ORDER_TYPE_BUY;
      m_opening_order   = false;
      ArrayResize(m_orders, 0);
   }

   //--- Initialise the grid manager.
   //  @param grid_distance    distance in points between grid levels
   //  @param max_grid_orders  hard cap on the number of grid (non-recovery) layers
   //  @param base_lot         lot for the first order (subsequent ones match)
   //  @param magic            EA magic number
   //  @param symbol           trading symbol
   //  @return true always
   bool Init(double grid_distance,
             int    max_grid_orders,
             double base_lot,
             long   magic,
             string symbol)
   {
      m_grid_distance   = grid_distance;
      m_max_grid_orders = max_grid_orders;
      m_base_lot        = base_lot;
      m_magic           = magic;
      m_symbol          = symbol;

      m_trade.SetExpertMagicNumber(m_magic);
      m_trade.SetDeviationInPoints(10);
      m_trade.SetTypeFilling(ORDER_FILLING_FOK);

      return true;
   }

   //--- Open the first order of a new grid sequence.
   //  @param type       ORDER_TYPE_BUY or ORDER_TYPE_SELL
   //  @param lot        volume to open
   //  @param sl_points  stop-loss distance from open price in points
   //  @return true if the order was accepted by the server
   bool OpenBaseOrder(ENUM_ORDER_TYPE type, double lot, double sl_points)
   {
      if(m_opening_order) return false;
      m_opening_order = true;

      double price, sl;
      if(type == ORDER_TYPE_BUY)
      {
         price = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         sl    = price - sl_points * _Point;
      }
      else
      {
         price = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         sl    = price + sl_points * _Point;
      }

      sl = NormalizeDouble(sl, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS));

      string comment = StringFormat("GADX_GRID_%d", m_order_count);
      ulong ticket = SendOrder(type, lot, sl, comment);

      m_opening_order = false;

      if(ticket == 0) return false;

      m_grid_direction  = type;
      m_last_grid_price = price;

      SOrderRecord rec;
      rec.ticket      = ticket;
      rec.type        = type;
      rec.lot         = lot;
      rec.open_price  = price;
      rec.is_recovery = false;
      rec.sequence    = m_order_count;
      AddOrderRecord(rec);

      return true;
   }

   //--- Decide whether a new grid layer should be opened.
   //  Condition: price has moved at least grid_distance points away from
   //  the last opened grid price, in the direction of the grid.
   //  @return true when another layer is warranted
   bool ShouldExpandGrid()
   {
      if(m_order_count == 0)          return false;
      if(m_last_grid_price <= 0.0)    return false;

      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);

      if(m_grid_direction == ORDER_TYPE_BUY)
         return (ask >= m_last_grid_price + m_grid_distance * _Point);
      else
         return (bid <= m_last_grid_price - m_grid_distance * _Point);
   }

   //--- Open an additional grid layer at the next level.
   //  @param sl_points  stop-loss in points from execution price
   //  @return true on success
   bool ExpandGrid(double sl_points)
   {
      if(m_opening_order) return false;
      if(IsGridFull())    return false;

      m_opening_order = true;

      double price, sl;
      if(m_grid_direction == ORDER_TYPE_BUY)
      {
         price = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         sl    = price - sl_points * _Point;
      }
      else
      {
         price = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         sl    = price + sl_points * _Point;
      }

      sl = NormalizeDouble(sl, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS));

      // Count only non-recovery orders for the sequence label
      int grid_seq = 0;
      for(int i = 0; i < m_order_count; i++)
         if(!m_orders[i].is_recovery) grid_seq++;

      string comment = StringFormat("GADX_GRID_%d", grid_seq);
      ulong ticket = SendOrder(m_grid_direction, m_base_lot, sl, comment);

      m_opening_order = false;

      if(ticket == 0) return false;

      m_last_grid_price = price;

      SOrderRecord rec;
      rec.ticket      = ticket;
      rec.type        = m_grid_direction;
      rec.lot         = m_base_lot;
      rec.open_price  = price;
      rec.is_recovery = false;
      rec.sequence    = grid_seq;
      AddOrderRecord(rec);

      return true;
   }

   //--- Returns true when the grid cannot accept any more layers.
   bool IsGridFull()
   {
      int count = 0;
      for(int i = 0; i < m_order_count; i++)
         if(!m_orders[i].is_recovery) count++;
      return (count >= m_max_grid_orders);
   }

   //--- Returns true when at least one managed position is still open.
   bool HasActiveOrders()
   {
      return (m_order_count > 0);
   }

   //--- Total P&L (profit + swap) of all positions whose magic matches.
   double GetTotalProfit()
   {
      double total = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC)        != m_magic)  continue;
         if(PositionGetString(POSITION_SYMBOL)        != m_symbol) continue;
         total += PositionGetDouble(POSITION_PROFIT) +
                  PositionGetDouble(POSITION_SWAP);
      }
      return total;
   }

   //--- Volume-weighted average entry price of all positions in m_orders[].
   double GetAveragePriceWeighted()
   {
      double sum_price_lot = 0.0;
      double sum_lot       = 0.0;
      for(int i = 0; i < m_order_count; i++)
      {
         sum_price_lot += m_orders[i].open_price * m_orders[i].lot;
         sum_lot       += m_orders[i].lot;
      }
      if(sum_lot <= 0.0) return 0.0;
      return sum_price_lot / sum_lot;
   }

   //--- Accessors
   int             GetOrderCount()     { return m_order_count; }
   ENUM_ORDER_TYPE GetGridDirection()  { return m_grid_direction; }
   double          GetLastGridPrice()  { return m_last_grid_price; }

   //--- Copy current order records into caller-provided array.
   //  @param out    destination array (will be resized)
   //  @param count  receives the number of records copied
   void GetOrders(SOrderRecord &out[], int &count)
   {
      count = m_order_count;
      ArrayResize(out, m_order_count);
      for(int i = 0; i < m_order_count; i++)
         out[i] = m_orders[i];
   }

   //--- Append an order record to the internal register.
   void AddOrderRecord(SOrderRecord &rec)
   {
      ArrayResize(m_orders, m_order_count + 1);
      m_orders[m_order_count] = rec;
      m_order_count++;
   }

   //--- Remove a record by ticket (linear scan, order is not preserved).
   //  @return true if the ticket was found and removed
   bool RemoveOrderRecord(ulong ticket)
   {
      for(int i = 0; i < m_order_count; i++)
      {
         if(m_orders[i].ticket == ticket)
         {
            // Overwrite with last element and shrink
            m_orders[i] = m_orders[m_order_count - 1];
            m_order_count--;
            ArrayResize(m_orders, m_order_count);
            return true;
         }
      }
      return false;
   }

   //--- Reconcile in-memory records with live server positions.
   //  Removes records for positions that are no longer open.
   void SyncWithServer()
   {
      for(int i = m_order_count - 1; i >= 0; i--)
      {
         if(!PositionSelectByTicket(m_orders[i].ticket))
         {
            // Position closed externally; remove local record
            m_orders[i] = m_orders[m_order_count - 1];
            m_order_count--;
            ArrayResize(m_orders, m_order_count);
         }
      }
   }

   //--- Close every managed position at market.
   //  @param reason  logged as comment
   void CloseAll(string reason)
   {
      for(int i = m_order_count - 1; i >= 0; i--)
      {
         ulong ticket = m_orders[i].ticket;
         if(PositionSelectByTicket(ticket))
         {
            double profit = PositionGetDouble(POSITION_PROFIT) +
                            PositionGetDouble(POSITION_SWAP);
            if(!m_trade.PositionClose(ticket))
            {
               Print("GridManager.CloseAll: failed to close #", ticket,
                     "  error=", GetLastError());
            }
            else
            {
               Print("GridManager.CloseAll: closed #", ticket,
                     "  profit=", profit, "  reason=", reason);
            }
         }
      }
      Reset();
   }

   //--- Reset all internal state (call after CloseAll or when returning to IDLE).
   void Reset()
   {
      m_order_count     = 0;
      m_last_grid_price = 0.0;
      m_opening_order   = false;
      ArrayResize(m_orders, 0);
   }

private:
   //--- Send a market order using CTrade and return the position ticket.
   //  Returns 0 on failure.
   //  @param type     ORDER_TYPE_BUY or ORDER_TYPE_SELL
   //  @param lot      volume
   //  @param sl       absolute stop-loss price
   //  @param comment  order comment (max 31 chars)
   ulong SendOrder(ENUM_ORDER_TYPE type, double lot, double sl, string comment)
   {
      // Validate SL
      if(sl <= 0.0)
      {
         Print("GridManager.SendOrder: invalid SL (", sl, ") — order rejected");
         return 0;
      }

      bool ok;
      if(type == ORDER_TYPE_BUY)
         ok = m_trade.Buy(lot, m_symbol, 0, sl, 0, comment);
      else
         ok = m_trade.Sell(lot, m_symbol, 0, sl, 0, comment);

      if(!ok)
      {
         Print("GridManager.SendOrder: CTrade failed, retcode=",
               m_trade.ResultRetcode(),
               "  comment=", m_trade.ResultComment());
         return 0;
      }

      return m_trade.ResultDeal();
   }
};

#endif // GRIDMANAGER_MQH
