//+------------------------------------------------------------------+
//| GridAI.mq5 - AI-signal ATR Grid + VWAP basket TP                  |
//|                                                                   |
//| 1) ทุก 5 นาที ส่งแท่ง M5 20 แท่ง + ATR ให้ AI -> BUY/SELL         |
//| 2) ผ่านตัวกรอง 4 ข้อ -> เปิดไม้แรก 0.01 lot ตามทิศ AI              |
//| 3) ราคาสวนทาง 1 ระยะ ATR -> เปิดไม้ถัดไปตามลำดับ lot               |
//| 4) TP = VWAP ของทุกไม้ +/- 100 จุด -> ปิดทุกไม้พร้อมกัน            |
//| 5) เป้ากำไร/ลิมิตขาดทุนรายวัน -> ปิดทุกไม้ทันที แล้วหยุดทั้งวัน       |
//+------------------------------------------------------------------+
#property copyright "mt5-agents"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include "Logger.mqh"
#include "Utils.mqh"
#include "RiskManager.mqh"
#include "Strategy.mqh"

//--- AI
input group "=== AI ==="
input bool   InpUseAI            = true;              // ใช้ AI (false = สัญญาณสำรอง สำหรับ Tester)
input string InpApiKey           = "";                // Anthropic API key
input string InpModel            = "claude-haiku-5-5";// โมเดล
input int    InpSignalSeconds    = 300;               // รอบตรวจสัญญาณ (วินาที)
input int    InpCandles          = 20;                // จำนวนแท่ง M5 ที่ส่งให้ AI
input double InpMinConfidence    = 70;                // ความมั่นใจ AI ขั้นต่ำ (%)
input int    InpAITimeoutMs      = 15000;             // timeout เรียก AI

//--- เวลา (เวลาเซิร์ฟเวอร์)
input group "=== Trading Hours (server time) ==="
input int    InpStartHour        = 0;                 // เริ่มเทรด
input int    InpEndHour          = 21;                // หยุดเปิดกริดใหม่
input int    InpFridayCutHour    = 16;                // วันศุกร์หยุดเปิดกริดใหม่ตั้งแต่
input bool   InpAddOutsideHours  = true;               // กริดที่ค้างอยู่ ยังเพิ่มไม้ได้นอกเวลา

//--- ลิมิตรายวัน
input group "=== Daily Limits (account currency) ==="
input double InpDailyProfitTarget= 20000;             // เป้ากำไร/วัน
input double InpDailyLossLimit   = 10000;             // ลิมิตขาดทุน/วัน
input double InpLossBuffer       = 5;                 // สั่งปิดก่อนถึงลิมิต (slippage)

//--- กริด
input group "=== Grid ==="
input long   InpMagic            = 20260501;          // Magic number
input string InpLotSequence      = "0.01,0.01,0.01,0.02"; // lot ไม้ที่ 1,2,3,4...
input double InpLotMultiplier    = 1.5;               // ไม้เกินลำดับข้างบน: lot ล่าสุด x ค่านี้ ต่อไม้
input double InpMaxLot           = 1.0;               // lot สูงสุดต่อไม้
input int    InpMaxGridOrders    = 0;                 // 0 = ไม่จำกัด
input int    InpATRPeriod        = 14;                // ATR period (M5)
input double InpATRMultiplier    = 1.0;               // ระยะกริด = ATR x ค่านี้
input int    InpTPPoints         = 100;               // TP = VWAP +/- กี่ point
input double InpMinMarginLevel   = 200;               // margin level % ขั้นต่ำก่อนเพิ่มไม้
input int    InpEmergencySLPoints= 0;                 // SL ฉุกเฉินใต้ไม้ล่าสุด (0 = ไม่ใช้)
input int    InpDeviation        = 50;                // slippage (points)
input bool   InpLogToFile        = true;

CTrade       trade;
CRiskManager risk;
double       g_lots[];
int          g_atrHandle = INVALID_HANDLE;
datetime     g_lastSignal = 0;
string       g_stepKey;

struct SGrid { int count; int dir; double lots; double vwap; double extreme; };

//+------------------------------------------------------------------+
int OnInit()
{
   LogInit(InpLogToFile);
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Log("ต้องใช้บัญชี Hedging เท่านั้น (กริดหลายไม้ทิศเดียวกัน) - netting ไม่รองรับ");
      return INIT_FAILED;
   }
   if(InpUseAI && StringLen(InpApiKey) == 0 && !MQLInfoInteger(MQL_TESTER))
   {
      Log("ยังไม่ได้ใส่ API key");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(ParseLotSequence(InpLotSequence, g_lots) == 0)
   {
      Log("InpLotSequence ไม่ถูกต้อง");
      return INIT_PARAMETERS_INCORRECT;
   }
   g_atrHandle = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE) { LogError("iATR"); return INIT_FAILED; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   risk.Init(_Symbol, InpMagic, InpDailyProfitTarget, InpDailyLossLimit, InpLossBuffer);
   g_stepKey = "GridAI_step_" + IntegerToString(InpMagic) + "_" + _Symbol;

   EventSetTimer(2);
   Log("Started. symbol=" + _Symbol + " magic=" + IntegerToString(InpMagic));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
}

void OnTick()  { Process(); }
void OnTimer() { Process(); }

//+------------------------------------------------------------------+
//| ลำดับงานหลัก                                                       |
//+------------------------------------------------------------------+
void Process()
{
   // 1) ลิมิตรายวัน (ตรวจทุก tick/timer ก่อนอย่างอื่น)
   double pnl;
   int lim = risk.CheckDailyLimit(pnl);
   SGrid g;
   bool hasGrid = ScanGrid(g);

   if(lim != 0)
   {
      if(hasGrid)
      {
         Log(StringFormat("Daily %s hit: pnl=%.2f -> close all, stop for the day",
                          lim > 0 ? "PROFIT TARGET" : "LOSS LIMIT", pnl));
         CloseAll();
      }
      return; // หยุดทั้งวัน (คำนวณจาก P/L ของวัน จึงคงอยู่แม้รีสตาร์ท EA)
   }

   // 2) มีกริดค้าง -> จัดการกริด (ข้ามสัญญาณ AI)
   if(hasGrid)
   {
      ManageGrid(g);
      return;
   }

   // 3) ไม่มีกริด -> ตรวจสัญญาณทุก InpSignalSeconds
   if(TimeCurrent() - g_lastSignal < InpSignalSeconds) return;
   if(!risk.NewGridTimeAllowed(InpStartHour, InpEndHour, InpFridayCutHour)) return;
   g_lastSignal = TimeCurrent();
   TrySignalAndOpen();
}

//+------------------------------------------------------------------+
double CurrentATR()
{
   double b[1];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, b) != 1) return 0;
   return b[0];
}

bool ScanGrid(SGrid &g)
{
   g.count = 0; g.dir = 0; g.lots = 0; g.vwap = 0; g.extreme = 0;
   double pv = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      bool buy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double p = PositionGetDouble(POSITION_PRICE_OPEN);
      double v = PositionGetDouble(POSITION_VOLUME);
      g.dir = buy ? 1 : -1;
      g.count++;
      g.lots += v;
      pv += p * v;
      if(g.count == 1) g.extreme = p;
      else g.extreme = buy ? MathMin(g.extreme, p) : MathMax(g.extreme, p);
   }
   if(g.count > 0) g.vwap = pv / g.lots;
   return g.count > 0;
}

double LotForLevel(const int idx)
{
   int n = ArraySize(g_lots);
   double l = (idx < n) ? g_lots[idx] : g_lots[n - 1] * MathPow(InpLotMultiplier, idx - n + 1);
   return NormalizeVolume(_Symbol, MathMin(l, InpMaxLot));
}

double GridStep()
{
   double step = 0;
   if(GlobalVariableCheck(g_stepKey)) step = GlobalVariableGet(g_stepKey);
   if(step <= 0) step = CurrentATR() * InpATRMultiplier;
   double minStep = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point * 2;
   return MathMax(step, MathMax(minStep, _Point * 10));
}

//+------------------------------------------------------------------+
//| ไม้แรก                                                             |
//+------------------------------------------------------------------+
void TrySignalAndOpen()
{
   double atr = CurrentATR();
   if(atr <= 0) { Log("ATR not ready"); return; }

   SAISignal sig;
   bool ok;
   if(InpUseAI && !MQLInfoInteger(MQL_TESTER))
   {
      string prompt = BuildMarketPrompt(_Symbol, InpCandles, atr);
      if(prompt == "") { Log("not enough M5 bars"); return; }
      ok = AskClaude(InpApiKey, InpModel, prompt, InpAITimeoutMs, sig);
   }
   else
      ok = FallbackSignal(_Symbol, InpCandles, sig);

   if(!ok) return;
   Log(StringFormat("Signal: %s conf=%.0f%%", sig.dir > 0 ? "BUY" : "SELL", sig.confidence));
   if(sig.confidence < InpMinConfidence)
   {
      Log("Skip: confidence below threshold");
      return;
   }

   double lot = LotForLevel(0);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ENUM_ORDER_TYPE type = sig.dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = sig.dir > 0 ? ask : bid;
   if(!risk.MarginOK(type, lot, price, InpMinMarginLevel)) { Log("Skip: margin"); return; }

   GlobalVariableSet(g_stepKey, atr * InpATRMultiplier);
   double tp = NormalizeDouble(price + sig.dir * InpTPPoints * _Point, _Digits);
   double sl = EmergencySL(sig.dir, price);
   OpenOrder(sig.dir, lot, sl, tp, 1);
}

//+------------------------------------------------------------------+
//| จัดการกริด: เพิ่มไม้เมื่อราคาลงถึงระยะ + ซิงก์ TP                     |
//+------------------------------------------------------------------+
void ManageGrid(const SGrid &g)
{
   bool allowed = InpAddOutsideHours ||
                  risk.NewGridTimeAllowed(InpStartHour, InpEndHour, InpFridayCutHour);
   if(allowed && (InpMaxGridOrders == 0 || g.count < InpMaxGridOrders))
   {
      double step = GridStep();
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      bool trigger = (g.dir > 0) ? (ask <= g.extreme - step) : (bid >= g.extreme + step);
      if(trigger)
      {
         double lot = LotForLevel(g.count);
         double price = g.dir > 0 ? ask : bid;
         ENUM_ORDER_TYPE type = g.dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         if(!risk.MarginOK(type, lot, price, InpMinMarginLevel))
            Log("Grid add skipped: margin too low");
         else
         {
            // ตั้ง TP ชั่วคราวที่ราคาเฉลี่ยใหม่ของกริด (รวมไม้ที่กำลังเปิด) แล้วซิงก์ให้ทุกไม้ต่อ
            double newVwap = (g.vwap * g.lots + price * lot) / (g.lots + lot);
            double tp = NormalizeDouble(newVwap + g.dir * InpTPPoints * _Point, _Digits);
            double sl = EmergencySL(g.dir, price);
            if(OpenOrder(g.dir, lot, sl, tp, g.count + 1))
            {
               SGrid g2;
               if(ScanGrid(g2)) SyncBasket(g2);
               return;
            }
         }
      }
   }
   SyncBasket(g);
}

double EmergencySL(const int dir, const double price)
{
   if(InpEmergencySLPoints <= 0) return 0;
   return NormalizeDouble(price - dir * InpEmergencySLPoints * _Point, _Digits);
}

// ให้ทุกไม้มี TP เดียวกัน = VWAP +/- InpTPPoints (ปิดพร้อมกันที่ฝั่งโบรกเกอร์)
void SyncBasket(const SGrid &g)
{
   double tp = NormalizeDouble(g.vwap + g.dir * InpTPPoints * _Point, _Digits);
   double sl = EmergencySL(g.dir, g.extreme);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      double curTP = PositionGetDouble(POSITION_TP);
      double curSL = PositionGetDouble(POSITION_SL);
      if(MathAbs(curTP - tp) < _Point / 2 && MathAbs(curSL - sl) < _Point / 2) continue;
      ResetLastError();
      if(!trade.PositionModify(t, sl, tp))
         Log(StringFormat("Modify #%I64u failed: retcode=%u %s err=%d",
                          t, trade.ResultRetcode(), trade.ResultRetcodeDescription(), GetLastError()));
   }
}

bool OpenOrder(const int dir, const double lot, const double sl, const double tp, const int level)
{
   string cmt = "GridAI L" + IntegerToString(level);
   ResetLastError();
   bool ok = (dir > 0) ? trade.Buy(lot, _Symbol, 0, sl, tp, cmt)
                       : trade.Sell(lot, _Symbol, 0, sl, tp, cmt);
   if(!ok)
   {
      Log(StringFormat("Open %s L%d lot=%.2f FAILED retcode=%u %s err=%d", dir > 0 ? "BUY" : "SELL",
                       level, lot, trade.ResultRetcode(), trade.ResultRetcodeDescription(), GetLastError()));
      return false;
   }
   Log(StringFormat("Open %s L%d lot=%.2f price=%.*f tp=%.*f sl=%.*f", dir > 0 ? "BUY" : "SELL", level,
                    lot, _Digits, trade.ResultPrice(), _Digits, tp, _Digits, sl));
   return true;
}

void CloseAll()
{
   for(int attempt = 0; attempt < 5; attempt++)
   {
      bool left = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         ResetLastError();
         if(!trade.PositionClose(t))
         {
            left = true;
            Log(StringFormat("Close #%I64u failed: retcode=%u %s err=%d", t, trade.ResultRetcode(),
                             trade.ResultRetcodeDescription(), GetLastError()));
         }
      }
      if(!left) return;
      Sleep(300);
   }
}
//+------------------------------------------------------------------+
