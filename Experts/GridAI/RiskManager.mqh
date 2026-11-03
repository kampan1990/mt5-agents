//+------------------------------------------------------------------+
//| RiskManager.mqh - ลิมิตรายวัน, ช่วงเวลาเทรด, ตรวจ margin           |
//+------------------------------------------------------------------+
#property strict

class CRiskManager
{
private:
   string m_symbol;
   long   m_magic;
   double m_profitTarget;   // เป้ากำไร/วัน (หน่วยเงินบัญชี)
   double m_lossLimit;      // ลิมิตขาดทุน/วัน
   double m_lossBuffer;     // สั่งปิดก่อนถึงลิมิต (เผื่อ slippage)

public:
   void Init(const string sym, const long magic, const double target,
             const double lossLimit, const double buffer)
   {
      m_symbol = sym; m_magic = magic;
      m_profitTarget = target; m_lossLimit = lossLimit; m_lossBuffer = buffer;
   }

   // 00:00 ของวันนี้ ตามเวลาเซิร์ฟเวอร์
   datetime DayStart()
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      return StructToTime(dt);
   }

   // P/L วันนี้ = ปิดแล้ว (profit+swap+commission) + floating ของไม้ที่ค้าง
   double DailyPnL()
   {
      double sum = 0;
      if(HistorySelect(DayStart(), TimeCurrent() + 60))
      {
         for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
         {
            ulong t = HistoryDealGetTicket(i);
            if(t == 0) continue;
            if(HistoryDealGetInteger(t, DEAL_MAGIC) != m_magic) continue;
            if(HistoryDealGetString(t, DEAL_SYMBOL) != m_symbol) continue;
            long type = HistoryDealGetInteger(t, DEAL_TYPE);
            if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
            sum += HistoryDealGetDouble(t, DEAL_PROFIT)
                 + HistoryDealGetDouble(t, DEAL_SWAP)
                 + HistoryDealGetDouble(t, DEAL_COMMISSION)
                 + HistoryDealGetDouble(t, DEAL_FEE);
         }
      }
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;
         sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
      return sum;
   }

   // 1 = ถึงเป้ากำไร, -1 = ถึงลิมิตขาดทุน, 0 = ปกติ  (ไม่ใช้ flag จึงไม่หายเมื่อรีสตาร์ท EA)
   int CheckDailyLimit(double &pnl)
   {
      pnl = DailyPnL();
      if(m_profitTarget > 0 && pnl >= m_profitTarget) return 1;
      if(m_lossLimit > 0 && pnl <= -(m_lossLimit - m_lossBuffer)) return -1;
      return 0;
   }

   // อนุญาตเปิดกริดใหม่ไหม (เวลาเซิร์ฟเวอร์)
   // จ-พฤ: startHour..endHour | ศ: ถึง fridayCutHour | ส-อา: ไม่เปิด
   bool NewGridTimeAllowed(const int startHour, const int endHour, const int fridayCutHour)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
      if(dt.hour < startHour || dt.hour >= endHour) return false;
      if(dt.day_of_week == 5 && dt.hour >= fridayCutHour) return false;
      return true;
   }

   // margin พอสำหรับไม้ถัดไปไหม
   bool MarginOK(const ENUM_ORDER_TYPE type, const double lot, const double price,
                 const double minMarginLevel)
   {
      double need = 0;
      if(!OrderCalcMargin(type, m_symbol, lot, price, need)) return false;
      if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < need * 2.0) return false;
      double used = AccountInfoDouble(ACCOUNT_MARGIN);
      if(used > 0 && AccountInfoDouble(ACCOUNT_MARGIN_LEVEL) < minMarginLevel) return false;
      return true;
   }
};
