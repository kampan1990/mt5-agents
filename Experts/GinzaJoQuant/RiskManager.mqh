//+------------------------------------------------------------------+
//| RiskManager.mqh - Layer 6: lot, SL/TP ตาม ATR, spread filter,      |
//| max orders, drawdown control, circuit breaker                     |
//+------------------------------------------------------------------+
#property strict
#include "Logger.mqh"
#include "Utils.mqh"

class CRiskManager
{
private:
   string   m_sym;
   long     m_magic;
   double   m_riskPct;        // % ของ balance ที่ยอมเสียต่อไม้
   double   m_maxDDPct;       // drawdown จาก equity สูงสุด -> หยุดถาวรจนกว่าจะรีเซ็ต
   double   m_dailyLossPct;   // ขาดทุนรายวัน % ของ balance ต้นวัน
   int      m_maxLosses;      // แพ้ติดกันกี่ไม้ -> พัก
   int      m_cooldownMin;    // พักกี่นาที
   int      m_maxOrders;
   double   m_maxSpread;      // points
   string   m_gvPeak, m_gvHalt;
   datetime m_pauseUntil;

public:
   void Init(const string sym, const long magic, const double riskPct, const double maxDD,
             const double dailyLoss, const int maxLosses, const int cooldownMin,
             const int maxOrders, const double maxSpread)
   {
      m_sym = sym; m_magic = magic; m_riskPct = riskPct; m_maxDDPct = maxDD;
      m_dailyLossPct = dailyLoss; m_maxLosses = maxLosses; m_cooldownMin = cooldownMin;
      m_maxOrders = maxOrders; m_maxSpread = maxSpread; m_pauseUntil = 0;
      m_gvPeak = "GinzaJo_peak_" + IntegerToString(magic);
      m_gvHalt = "GinzaJo_halt_" + IntegerToString(magic);
      if(!GlobalVariableCheck(m_gvPeak)) GlobalVariableSet(m_gvPeak, AccountInfoDouble(ACCOUNT_EQUITY));
   }

   int OpenCount()
   {
      int n = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) == m_magic && PositionGetString(POSITION_SYMBOL) == m_sym) n++;
      }
      return n;
   }

   bool SpreadOK() { return (double)SymbolInfoInteger(m_sym, SYMBOL_SPREAD) <= m_maxSpread; }

   // lot จาก % เสี่ยงของ balance และระยะ SL (หน่วยราคา)
   double LotForRisk(const double slDistance)
   {
      double tickVal = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickVal <= 0) tickVal = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_SIZE);
      if(slDistance <= 0 || tickVal <= 0 || tickSize <= 0) return 0;
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * m_riskPct / 100.0;
      double lossPerLot = slDistance / tickSize * tickVal;
      return NormalizeVolume(m_sym, riskMoney / lossPerLot);
   }

   // เสี่ยงจริงของ lot ที่ปัดแล้ว เกิน 1.5 เท่าของที่ตั้งไว้ (lot min ใหญ่เกินบัญชี) -> ไม่เทรด
   bool RiskWithinTolerance(const double lot, const double slDistance)
   {
      double tickVal = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickVal <= 0) tickVal = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_SIZE);
      double actual = lot * slDistance / tickSize * tickVal;
      double allowed = AccountInfoDouble(ACCOUNT_BALANCE) * m_riskPct / 100.0 * 1.5;
      return actual <= allowed;
   }

   double DailyPnL()
   {
      double sum = 0;
      if(HistorySelect(DayStart(), TimeCurrent() + 60))
         for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
         {
            ulong t = HistoryDealGetTicket(i);
            if(t == 0 || HistoryDealGetInteger(t, DEAL_MAGIC) != m_magic) continue;
            if(HistoryDealGetString(t, DEAL_SYMBOL) != m_sym) continue;
            sum += HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP)
                 + HistoryDealGetDouble(t, DEAL_COMMISSION) + HistoryDealGetDouble(t, DEAL_FEE);
         }
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0 || PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
      return sum;
   }

   int ConsecutiveLosses()
   {
      if(!HistorySelect(TimeCurrent() - 7 * 86400, TimeCurrent() + 60)) return 0;
      int n = 0;
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         ulong t = HistoryDealGetTicket(i);
         if(t == 0 || HistoryDealGetInteger(t, DEAL_MAGIC) != m_magic) continue;
         if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         double p = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP)
                  + HistoryDealGetDouble(t, DEAL_COMMISSION);
         if(p < 0) n++; else break;
      }
      return n;
   }

   bool Halted() { return GlobalVariableCheck(m_gvHalt) && GlobalVariableGet(m_gvHalt) > 0; }
   void ResetHalt() { GlobalVariableDel(m_gvHalt); GlobalVariableSet(m_gvPeak, AccountInfoDouble(ACCOUNT_EQUITY)); }

   // Circuit breaker: คืน true = เทรดได้ ; reason บอกสาเหตุเมื่อห้าม
   bool TradingAllowed(string &reason)
   {
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      double peak = GlobalVariableGet(m_gvPeak);
      if(eq > peak) { peak = eq; GlobalVariableSet(m_gvPeak, peak); }

      if(Halted()) { reason = "HALTED (max drawdown) - รีเซ็ตด้วย input InpResetHalt"; return false; }
      if(m_maxDDPct > 0 && peak > 0 && (peak - eq) / peak * 100.0 >= m_maxDDPct)
      {
         GlobalVariableSet(m_gvHalt, 1);
         Log(StringFormat("CIRCUIT BREAKER: drawdown %.2f%% >= %.2f%% -> หยุดเปิดออเดอร์ใหม่",
                          (peak - eq) / peak * 100.0, m_maxDDPct));
         reason = "max drawdown"; return false;
      }
      double dayLimit = AccountInfoDouble(ACCOUNT_BALANCE) * m_dailyLossPct / 100.0;
      if(m_dailyLossPct > 0 && DailyPnL() <= -dayLimit) { reason = "daily loss limit"; return false; }
      if(TimeCurrent() < m_pauseUntil) { reason = "cooldown after losses"; return false; }
      if(m_maxLosses > 0 && ConsecutiveLosses() >= m_maxLosses)
      {
         m_pauseUntil = TimeCurrent() + m_cooldownMin * 60;
         Log(StringFormat("CIRCUIT BREAKER: แพ้ติด %d ไม้ -> พัก %d นาที", m_maxLosses, m_cooldownMin));
         reason = "consecutive losses"; return false;
      }
      if(OpenCount() >= m_maxOrders) { reason = "max concurrent orders"; return false; }
      if(!SpreadOK()) { reason = "spread too wide"; return false; }
      return true;
   }
};
