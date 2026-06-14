//+------------------------------------------------------------------+
//| GridManager.mqh                                                   |
//| Gridindy EA                                                       |
//| Version: 1.1.0                                                    |
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
   SOrderRecord    m_orders[];
   int             m_order_count;
   double          m_grid_distance;
   int             m_max_grid_orders;
   double          m_base_lot;
   long            m_magic;
   string          m_symbol;
   double          m_last_grid_price;
   ENUM_ORDER_TYPE m_grid_direction;
   bool            m_opening_order;

   CTrade          m_trade;

   // Query broker-supported filling mode instead of assuming FOK
   ENUM_ORDER_TYPE_FILLING GetFillingMode()
   {
      int filling = (int)SymbolInfoInteger(m_symbol, SYMBOL_FILLING_MODE);
      if((filling & 1) != 0) return ORDER_FILLING_FOK;
      if((filling & 2) != 0) return ORDER_FILLING_IOC;
      return ORDER_FILLING_RETURN;
   }

public:
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
      m_trade.SetTypeFilling(GetFillingMode());  // FIX: query broker mode

      return true;
   }

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

      string comment = StringFormat("GINDY_GRID_%d", m_order_count);
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

   void SetGridDistance(double dist_points) { m_grid_distance = dist_points; }
   double GetGridDistance()                 { return m_grid_distance; }

   bool ShouldExpandGrid()
   {
      if(m_order_count == 0)       return false;
      if(m_last_grid_price <= 0.0) return false;

      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);

      if(m_grid_direction == ORDER_TYPE_BUY)
         return (ask >= m_last_grid_price + m_grid_distance * _Point);
      else
         return (bid <= m_last_grid_price - m_grid_distance * _Point);
   }

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

      int grid_seq = 0;
      for(int i = 0; i < m_order_count; i++)
         if(!m_orders[i].is_recovery) grid_seq++;

      string comment = StringFormat("GINDY_GRID_%d", grid_seq);
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

   bool IsGridFull()
   {
      int count = 0;
      for(int i = 0; i < m_order_count; i++)
         if(!m_orders[i].is_recovery) count++;
      return (count >= m_max_grid_orders);
   }

   bool HasActiveOrders()   { return (m_order_count > 0); }

   double GetTotalProfit()
   {
      double total = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic)  continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;
         total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
      return total;
   }

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

   int             GetOrderCount()    { return m_order_count; }
   ENUM_ORDER_TYPE GetGridDirection() { return m_grid_direction; }
   double          GetLastGridPrice() { return m_last_grid_price; }

   void GetOrders(SOrderRecord &out[], int &count)
   {
      count = m_order_count;
      ArrayResize(out, m_order_count);
      for(int i = 0; i < m_order_count; i++)
         out[i] = m_orders[i];
   }

   void AddOrderRecord(SOrderRecord &rec)
   {
      ArrayResize(m_orders, m_order_count + 1);
      m_orders[m_order_count] = rec;
      m_order_count++;
   }

   bool RemoveOrderRecord(ulong ticket)
   {
      for(int i = 0; i < m_order_count; i++)
      {
         if(m_orders[i].ticket == ticket)
         {
            m_orders[i] = m_orders[m_order_count - 1];
            m_order_count--;
            ArrayResize(m_orders, m_order_count);
            return true;
         }
      }
      return false;
   }

   // FIX: log when positions are removed (SL hit, manual close, etc.)
   void SyncWithServer()
   {
      for(int i = m_order_count - 1; i >= 0; i--)
      {
         if(!PositionSelectByTicket(m_orders[i].ticket))
         {
            Print("GridManager.SyncWithServer: position #", m_orders[i].ticket,
                  " (", EnumToString(m_orders[i].type), " lot=", m_orders[i].lot,
                  ") no longer open — removed from register");
            m_orders[i] = m_orders[m_order_count - 1];
            m_order_count--;
            ArrayResize(m_orders, m_order_count);
         }
      }
   }

   void CloseAll(string reason)
   {
      for(int i = m_order_count - 1; i >= 0; i--)
      {
         ulong ticket = m_orders[i].ticket;
         if(PositionSelectByTicket(ticket))
         {
            double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            if(!m_trade.PositionClose(ticket))
               Print("GridManager.CloseAll: failed to close #", ticket, "  error=", GetLastError());
            else
               Print("GridManager.CloseAll: closed #", ticket, "  profit=", profit, "  reason=", reason);
         }
      }
      Reset();
   }

   void Reset()
   {
      m_order_count     = 0;
      m_last_grid_price = 0.0;
      m_opening_order   = false;
      ArrayResize(m_orders, 0);
   }

private:
   ulong SendOrder(ENUM_ORDER_TYPE type, double lot, double sl, string comment)
   {
      if(sl <= 0.0)
      {
         Print("GridManager.SendOrder: invalid SL (", sl, ") — order rejected");
         return 0;
      }

      // FIX: validate SL distance against broker stop level
      double price_now = (type == ORDER_TYPE_BUY)
                         ? SymbolInfoDouble(m_symbol, SYMBOL_ASK)
                         : SymbolInfoDouble(m_symbol, SYMBOL_BID);
      long   stop_level = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double min_dist   = (stop_level + 1) * _Point;
      double sl_dist    = (type == ORDER_TYPE_BUY) ? (price_now - sl) : (sl - price_now);
      if(sl_dist < min_dist)
      {
         Print("GridManager.SendOrder: SL too close — ", sl_dist / _Point,
               " pts < stop_level=", stop_level, " pts, order rejected");
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
               m_trade.ResultRetcode(), "  comment=", m_trade.ResultComment());
         return 0;
      }

      // FIX: ResultOrder() returns position ticket; ResultDeal() returns deal ticket
      return m_trade.ResultOrder();
   }
};

#endif // GRIDMANAGER_MQH
