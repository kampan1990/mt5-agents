//+------------------------------------------------------------------+
//| RecoveryManager.mqh                                               |
//| Gridindy EA                                                       |
//| Version: 1.1.0                                                    |
//+------------------------------------------------------------------+
#ifndef RECOVERYMANAGER_MQH
#define RECOVERYMANAGER_MQH

#include "GridManager.mqh"

//+------------------------------------------------------------------+
//| CRecoveryManager — hedge-based martingale recovery               |
//|                                                                    |
//| When the grid is losing (price moves against it by               |
//| recovery_distance), opens orders in the OPPOSITE direction        |
//| with multiplied lot — profiting from the continued adverse move   |
//| to offset grid losses.                                            |
//|                                                                    |
//| Continuation: each time price moves another recovery_distance     |
//| further in the SAME adverse direction, adds another recovery layer|
//+------------------------------------------------------------------+
class CRecoveryManager
{
private:
   double          m_recovery_distance;
   double          m_multiplier;
   int             m_max_recovery_orders;
   int             m_recovery_count;
   double          m_last_recovery_price;
   ENUM_ORDER_TYPE m_last_recovery_type;
   long            m_magic;
   string          m_symbol;
   CGridManager*   m_grid_mgr;

   CTrade          m_trade;

   // FIX: query broker-supported filling mode
   ENUM_ORDER_TYPE_FILLING GetFillingMode()
   {
      int filling = (int)SymbolInfoInteger(m_symbol, SYMBOL_FILLING_MODE);
      if((filling & 1) != 0) return ORDER_FILLING_FOK;
      if((filling & 2) != 0) return ORDER_FILLING_IOC;
      return ORDER_FILLING_RETURN;
   }

public:
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
      m_trade.SetTypeFilling(GetFillingMode());  // FIX: query broker mode

      return true;
   }

   void SetRecoveryDistance(double dist_points) { m_recovery_distance = dist_points; }
   double GetRecoveryDistance()                 { return m_recovery_distance; }

   //--- Trigger: price has moved recovery_distance against the grid direction
   bool IsRecoveryNeeded()
   {
      if(m_grid_mgr == NULL)            return false;
      if(!m_grid_mgr.HasActiveOrders()) return false;

      double avg = m_grid_mgr.GetAveragePriceWeighted();
      if(avg <= 0.0) return false;

      ENUM_ORDER_TYPE dir = m_grid_mgr.GetGridDirection();

      if(dir == ORDER_TYPE_BUY)
      {
         // BUY grid losing when price falls below weighted avg
         double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         return (bid < avg - m_recovery_distance * _Point);
      }
      else
      {
         // SELL grid losing when price rises above weighted avg
         double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         return (ask > avg + m_recovery_distance * _Point);
      }
   }

   bool OpenRecoveryOrder(double base_lot, double sl_points)
   {
      if(m_grid_mgr == NULL) return false;
      if(!CanRecover())      return false;

      // ไม้แรก: ตรงข้าม grid เสมอ / ไม้ถัดไป: สลับจากทิศก่อนหน้า
      ENUM_ORDER_TYPE recovery_dir;
      if(m_recovery_count == 0)
         recovery_dir = (m_grid_mgr.GetGridDirection() == ORDER_TYPE_BUY)
                        ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      else
         recovery_dir = (m_last_recovery_type == ORDER_TYPE_SELL)
                        ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

      // Lot คูณตั้งแต่ไม้แรก: recovery 1 = base×multi, recovery 2 = base×multi², ...
      double lot = base_lot;
      for(int i = 0; i <= m_recovery_count; i++)
         lot *= m_multiplier;

      // Normalise lot
      double step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      double vmin = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double vmax = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      if(step > 0.0) lot = MathFloor(lot / step) * step;
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

      int    digits     = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      sl = NormalizeDouble(sl, digits);

      if(sl <= 0.0)
      {
         Print("RecoveryManager.OpenRecoveryOrder: invalid SL — rejected");
         return false;
      }

      // FIX: validate SL distance against broker stop level
      long   stop_level = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double min_dist   = (stop_level + 1) * _Point;
      double sl_dist    = (recovery_dir == ORDER_TYPE_BUY) ? (price - sl) : (sl - price);
      if(sl_dist < min_dist)
      {
         Print("RecoveryManager.OpenRecoveryOrder: SL too close — ",
               sl_dist / _Point, " pts < stop_level=", stop_level, " pts, rejected");
         return false;
      }

      string comment = StringFormat("GINDY_REC_%d", m_recovery_count);

      bool ok;
      if(recovery_dir == ORDER_TYPE_BUY)
         ok = m_trade.Buy(lot, m_symbol, 0, sl, 0, comment);
      else
         ok = m_trade.Sell(lot, m_symbol, 0, sl, 0, comment);

      if(!ok)
      {
         Print("RecoveryManager.OpenRecoveryOrder: CTrade failed, retcode=",
               m_trade.ResultRetcode(), "  comment=", m_trade.ResultComment());
         return false;
      }

      // FIX: ResultOrder() = position ticket; ResultDeal() = deal ticket
      ulong ticket = m_trade.ResultOrder();

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
            "  layer=", m_recovery_count);

      return true;
   }

   //--- เปิด recovery ไม้ถัดไปเมื่อราคา "กลับทิศ" ผ่าน recovery_distance จากไม้ล่าสุด
   //
   //   ไม้ล่าสุดเป็น SELL (BUY grid + ราคาลง):
   //     ถ้าราคากลับขึ้น ask > last_recovery_price + distance → เปิด BUY ต่อไป
   //
   //   ไม้ล่าสุดเป็น BUY (SELL grid + ราคาขึ้น):
   //     ถ้าราคากลับลง bid < last_recovery_price - distance → เปิด SELL ต่อไป
   bool ShouldContinueRecovery()
   {
      if(m_recovery_count == 0)        return false;
      if(m_last_recovery_price <= 0.0) return false;

      if(m_last_recovery_type == ORDER_TYPE_SELL)
      {
         // ไม้ล่าสุด SELL → ราคากลับขึ้นเกิน rec_dist → เปิด BUY
         double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         return (ask > m_last_recovery_price + m_recovery_distance * _Point);
      }
      else
      {
         // ไม้ล่าสุด BUY → ราคากลับลงเกิน rec_dist → เปิด SELL
         double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         return (bid < m_last_recovery_price - m_recovery_distance * _Point);
      }
   }

   bool CanRecover()        { return (m_recovery_count < m_max_recovery_orders); }
   int  GetRecoveryCount()  { return m_recovery_count; }

   void Reset()
   {
      m_recovery_count      = 0;
      m_last_recovery_price = 0.0;
   }
};

#endif // RECOVERYMANAGER_MQH
