//+------------------------------------------------------------------+
//| RiskManager.mqh                                                   |
//| QTheory EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026.11.03                                               |
//+------------------------------------------------------------------+
#ifndef QT_RISKMANAGER_MQH
#define QT_RISKMANAGER_MQH

#include "Utils.mqh"
#include "Logger.mqh"

#define QT_PERCENT_DIV   100.0

namespace RiskManager
{
   long     s_magic     = 0;
   string   s_symbol    = "";
   double   s_peak      = 0.0;
   bool     s_halted    = false;
   string   s_gvPeak    = "";
   string   s_gvHalt    = "";
   datetime s_lastCalc  = 0;
   double   s_closedToday = 0.0;
   double   s_dailyPnL  = 0.0;

   //--- เริ่มระบบ risk | symbol, magic | resetHalt = ล้างสถานะหยุดเทรดที่ค้างจาก DD
   //    peak equity และ halt flag เก็บใน GlobalVariable (ไม่ใช้ใน Tester)
   void Init(const string symbol, const long magic, const bool resetHalt)
   {
      s_symbol = symbol;
      s_magic  = magic;
      s_gvPeak = "QT_PEAK_" + IntegerToString(magic) + "_" + symbol;
      s_gvHalt = "QT_HALT_" + IntegerToString(magic) + "_" + symbol;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      s_peak   = eq;
      s_halted = false;
      if(MQLInfoInteger(MQL_TESTER)) return;
      if(resetHalt)
      {
         GlobalVariableDel(s_gvPeak);
         GlobalVariableDel(s_gvHalt);
         return;
      }
      if(GlobalVariableCheck(s_gvPeak))
         s_peak = MathMax(eq, GlobalVariableGet(s_gvPeak));
      if(GlobalVariableCheck(s_gvHalt))
         s_halted = (GlobalVariableGet(s_gvHalt) > 0.5);
   }

   //--- บันทึก peak ลง GlobalVariable (เรียกตอน deinit / ตอน halt)
   void Save()
   {
      if(MQLInfoInteger(MQL_TESTER)) return;
      GlobalVariableSet(s_gvPeak, s_peak);
      GlobalVariableSet(s_gvHalt, s_halted ? 1.0 : 0.0);
   }

   //--- อัปเดต peak equity (เรียกทุก tick)
   void UpdatePeak()
   {
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq > s_peak) s_peak = eq;
   }

   //--- Drawdown ปัจจุบันจาก peak เป็น % | คืน: 0..100
   double GetCurrentDrawdown()
   {
      if(s_peak <= 0.0) return 0.0;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      return MathMax(0.0, (s_peak - eq) / s_peak * QT_PERCENT_DIV);
   }

   //--- DD เกิน threshold ไหม (maxDDPercent <= 0 = ปิดการตรวจ)
   bool IsDrawdownExceeded(const double maxDDPercent)
   {
      if(maxDDPercent <= 0.0) return false;
      UpdatePeak();
      return GetCurrentDrawdown() >= maxDDPercent;
   }

   bool IsHalted()            { return s_halted; }
   void SetHalted(const bool v) { s_halted = v; Save(); }

   //--- นับ position ของ EA นี้ (magic + symbol)
   int CountOpenTrades()
   {
      int n = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != s_magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != s_symbol) continue;
         n++;
      }
      return n;
   }

   //--- นับ pending order ของ EA นี้
   int CountPendingOrders()
   {
      int n = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong t = OrderGetTicket(i);
         if(t == 0) continue;
         if(OrderGetInteger(ORDER_MAGIC) != s_magic) continue;
         if(OrderGetString(ORDER_SYMBOL) != s_symbol) continue;
         n++;
      }
      return n;
   }

   //--- เปิดไม้ใหม่ได้ไหม: positions + pendings + additional <= maxTrades
   //    additional = จำนวน pending ที่กำลังจะวาง
   bool CanOpenNewTrade(const int maxTrades, const int additional)
   {
      if(maxTrades <= 0) return true;
      return (CountOpenTrades() + CountPendingOrders() + additional) <= maxTrades;
   }

   //--- คำนวณ P/L วันนี้ (ปิดแล้ว + floating) cache 1 วินาที
   void RefreshDaily()
   {
      datetime now = TimeCurrent();
      if(s_lastCalc != 0 && now == s_lastCalc) return;
      s_lastCalc = now;

      double closed = 0.0;
      if(HistorySelect(Utils::DayStart(), now + QT_SECONDS_PER_MINUTE))
      {
         for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
         {
            ulong t = HistoryDealGetTicket(i);
            if(t == 0) continue;
            if(HistoryDealGetInteger(t, DEAL_MAGIC) != s_magic) continue;
            if(HistoryDealGetString(t, DEAL_SYMBOL) != s_symbol) continue;
            long type = HistoryDealGetInteger(t, DEAL_TYPE);
            if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
            closed += HistoryDealGetDouble(t, DEAL_PROFIT)
                    + HistoryDealGetDouble(t, DEAL_SWAP)
                    + HistoryDealGetDouble(t, DEAL_COMMISSION)
                    + HistoryDealGetDouble(t, DEAL_FEE);
         }
      }
      double floating = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != s_magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != s_symbol) continue;
         floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
      s_closedToday = closed;
      s_dailyPnL    = closed + floating;
   }

   //--- P/L วันนี้ (หน่วยเงินบัญชี)
   double GetDailyPnL()
   {
      RefreshDaily();
      return s_dailyPnL;
   }

   //--- ขาดทุนวันนี้ถึง dailyLossPercent ของ balance ต้นวันไหม (<=0 = ปิดการตรวจ)
   //    balance ต้นวัน ~= balance ปัจจุบัน - กำไรที่ปิดแล้ววันนี้
   bool IsDailyLossLimitExceeded(const double dailyLossPercent)
   {
      if(dailyLossPercent <= 0.0) return false;
      RefreshDaily();
      double startBal = AccountInfoDouble(ACCOUNT_BALANCE) - s_closedToday;
      if(startBal <= 0.0) return true;
      double limit = startBal * dailyLossPercent / QT_PERCENT_DIV;
      return s_dailyPnL <= -limit;
   }

   //--- คำนวณ lot ต่อ level ให้ "ถ้าทุก level ถูกเติมแล้วชน SL ร่วม = riskPercent ของ balance"
   //    entries = ราคาเข้าของแต่ละ level | stopLossPrice = SL ร่วม
   //    maxLot = เพดาน lot (<=0 ไม่จำกัด) | allowMinLot = ถ้าคำนวณต่ำกว่า min lot ให้ใช้ min lot
   //    คืน: lot (0 = ไม่ควรเทรด)
   double CalculateLot(const double &entries[], const double stopLossPrice,
                       const double riskPercent, const double maxLot, const bool allowMinLot)
   {
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * riskPercent / QT_PERCENT_DIV;
      double tickSize  = SymbolInfoDouble(s_symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickVal   = SymbolInfoDouble(s_symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickVal <= 0.0) tickVal = SymbolInfoDouble(s_symbol, SYMBOL_TRADE_TICK_VALUE);
      if(riskMoney <= 0.0 || tickSize <= 0.0 || tickVal <= 0.0) return 0.0;

      double lossPerLot = 0.0;
      int n = ArraySize(entries);
      for(int i = 0; i < n; i++)
         lossPerLot += MathAbs(stopLossPrice - entries[i]) / tickSize * tickVal;
      if(lossPerLot <= 0.0) return 0.0;

      double raw = riskMoney / lossPerLot;
      if(maxLot > 0.0) raw = MathMin(raw, maxLot);
      double vmin = SymbolInfoDouble(s_symbol, SYMBOL_VOLUME_MIN);
      if(raw < vmin)
      {
         if(!allowMinLot) return 0.0;
         return vmin;
      }
      return Utils::NormalizeVolume(s_symbol, raw);
   }

   //--- margin พอสำหรับทุก level ไหม: Σ margin <= free margin x maxUsePercent
   bool MarginOK(const ENUM_ORDER_TYPE type, const double lot,
                 const double &entries[], const double maxUsePercent)
   {
      double need = 0.0;
      int n = ArraySize(entries);
      for(int i = 0; i < n; i++)
      {
         double m = 0.0;
         if(!OrderCalcMargin(type, s_symbol, lot, entries[i], m)) return false;
         need += m;
      }
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      return need <= freeMargin * maxUsePercent / QT_PERCENT_DIV;
   }
}

#endif
