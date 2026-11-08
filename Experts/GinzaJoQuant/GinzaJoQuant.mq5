//+------------------------------------------------------------------+
//| GinzaJoQuant.mq5 - Multi-layer AI trading system for XAUUSD       |
//|                                                                   |
//| L1-2 Features.mqh   : แท่ง M5 -> 14 features                      |
//| L3   research/      : ทดสอบ pattern นอก EA (Python)               |
//| L4-5 Signal.mqh     : LightGBM (ONNX) + เกณฑ์ prob/margin          |
//| L6   RiskManager.mqh: lot%, SL/TP ATR, spread, DD, circuit breaker |
//| L7   Journal.mqh    : บันทึกออเดอร์ -> analyze_journal.py          |
//+------------------------------------------------------------------+
#property copyright "mt5-agents"
#property version   "1.00"
#property strict
#property tester_file "ginza_model.onnx"   // ให้ Strategy Tester คัดลอกโมเดลจาก MQL5\Files

#include <Trade\Trade.mqh>
#include "Logger.mqh"
#include "Utils.mqh"
#include "Features.mqh"
#include "Signal.mqh"
#include "RiskManager.mqh"
#include "Journal.mqh"

input group "=== Model (ค่าจาก model_meta.json ที่ train.py สร้าง) ==="
input string InpModelFile    = "ginza_model.onnx"; // ไฟล์ใน MQL5\Files
input double InpThreshold    = 0.60;   // prob ขั้นต่ำ
input double InpMargin       = 0.10;   // prob ทิศที่เลือก ต้องมากกว่าทิศตรงข้ามอย่างน้อย
input double InpTpAtr        = 1.5;    // ต้องเท่ากับ TP_ATR ตอนเทรน
input double InpSlAtr        = 1.0;    // ต้องเท่ากับ SL_ATR ตอนเทรน
input int    InpHorizonBars  = 24;     // ปิดไม้ถ้าถือเกินกี่แท่ง M5 (= HORIZON ตอนเทรน)

input group "=== Risk ==="
input double InpRiskPercent  = 0.5;    // % ของ balance ที่เสี่ยงต่อไม้
input double InpMaxDDPercent = 15.0;   // drawdown สูงสุดจาก equity peak -> หยุดเปิดใหม่
input double InpDailyLossPct = 3.0;    // ขาดทุนรายวันสูงสุด %
input int    InpMaxLosses    = 4;      // แพ้ติดกันกี่ไม้ -> พัก
input int    InpCooldownMin  = 120;    // เวลาพัก (นาที)
input int    InpMaxOrders    = 1;      // ออเดอร์พร้อมกันสูงสุด
input double InpMaxSpread    = 40;     // spread สูงสุด (points)
input double InpMinAtr       = 0.3;    // ATR M5 ต่ำสุด (หน่วยราคา) กันตลาดนิ่งเกิน
input bool   InpResetHalt    = false;  // true = ปลด halt จาก max drawdown (แล้วตั้งกลับเป็น false)

input group "=== Trading hours (server time) ==="
input int    InpStartHour    = 7;
input int    InpEndHour      = 21;

input group "=== General ==="
input long   InpMagic        = 20261108;
input int    InpDeviation    = 30;
input bool   InpLogToFile    = true;

CTrade       trade;
CRiskManager risk;
CFeatures    feat;
CSignal      sig;
datetime     g_lastBar = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   LogInit(InpLogToFile);
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_NETTING)
      Log("เตือน: บัญชี netting — ใช้ได้เมื่อ InpMaxOrders=1");
   if(_Period != PERIOD_M5) { Log("ต้องรันบนกราฟ M5 (โมเดลเทรนด้วย M5)"); return INIT_FAILED; }
   if(InpTpAtr <= 0 || InpSlAtr <= 0) { Log("TP/SL ATR ต้อง > 0"); return INIT_PARAMETERS_INCORRECT; }

   feat.Init(_Symbol, PERIOD_M5);
   if(!sig.Init(InpModelFile, InpThreshold, InpMargin)) return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   risk.Init(_Symbol, InpMagic, InpRiskPercent, InpMaxDDPercent, InpDailyLossPct,
             InpMaxLosses, InpCooldownMin, InpMaxOrders, InpMaxSpread);
   if(InpResetHalt) { risk.ResetHalt(); Log("ปลด halt แล้ว (อย่าลืมตั้ง InpResetHalt=false)"); }

   Log(StringFormat("INIT %s M5 | thr=%.2f margin=%.2f risk=%.2f%% maxDD=%.1f%% feature_v=%d",
                    _Symbol, InpThreshold, InpMargin, InpRiskPercent, InpMaxDDPercent, FEATURE_VERSION));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { Log("DEINIT reason=" + IntegerToString(reason)); }

//+------------------------------------------------------------------+
void OnTick()
{
   datetime bar = iTime(_Symbol, PERIOD_M5, 0);
   if(bar == g_lastBar) return;          // ทำงานครั้งเดียวต่อแท่ง M5 ใหม่
   g_lastBar = bar;

   CloseExpired();

   string why;
   if(!risk.TradingAllowed(why)) { return; }

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return;
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return;

   SFeatureSet f;
   if(!feat.Compute(f)) return;
   if(f.atr < InpMinAtr) return;

   double pb, ps;
   int s = sig.Evaluate(f, pb, ps);
   if(s == SIG_NONE) return;
   OpenTrade(s, f, pb, ps);
}

//+------------------------------------------------------------------+
void OpenTrade(const int dir, const SFeatureSet &f, const double pb, const double ps)
{
   double price = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDist = InpSlAtr * f.atr, tpDist = InpTpAtr * f.atr;
   double sl = (dir > 0) ? price - slDist : price + slDist;
   double tp = (dir > 0) ? price + tpDist : price - tpDist;
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   // กฎบังคับ: ต้องมี SL และ TP ที่ถูกต้องเสมอ
   if(sl <= 0 || tp <= 0) { Log("ปฏิเสธ: SL/TP ไม่ถูกต้อง"); return; }
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(slDist < minDist || tpDist < minDist) { Log("ปฏิเสธ: SL/TP ใกล้กว่า stops level"); return; }

   double lot = risk.LotForRisk(slDist);
   if(lot <= 0 || !risk.RiskWithinTolerance(lot, slDist))
   { Log(StringFormat("ปฏิเสธ: lot=%.2f เสี่ยงเกินที่ตั้ง (บัญชีเล็กเกินไป?)", lot)); return; }

   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double margin;
   if(!OrderCalcMargin(ot, _Symbol, lot, price, margin) || margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.5)
   { Log("ปฏิเสธ: margin ไม่พอ"); return; }

   ResetLastError();
   bool ok = (dir > 0) ? trade.Buy(lot, _Symbol, 0, sl, tp, "GinzaJo")
                       : trade.Sell(lot, _Symbol, 0, sl, tp, "GinzaJo");
   if(!ok)
   {
      Log(StringFormat("ORDER FAILED dir=%d lot=%.2f retcode=%u %s", dir, lot,
                       trade.ResultRetcode(), trade.ResultRetcodeDescription()));
      LogError("OpenTrade");
      return;
   }
   Log(StringFormat("OPEN dir=%d lot=%.2f price=%.*f sl=%.*f tp=%.*f pBuy=%.3f pSell=%.3f atr=%.3f spread=%.0f",
                    dir, lot, _Digits, trade.ResultPrice(), _Digits, sl, _Digits, tp, pb, ps, f.atr, f.spreadPts));
   JournalOpen(trade.ResultOrder(), dir, lot, trade.ResultPrice(), sl, tp, pb, ps, f.hour, f.spreadPts, f.atr);
}

// ปิดไม้ที่ถือนานเกิน horizon (ให้ตรงกับ label ที่โมเดลเรียนรู้)
void CloseExpired()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(TimeCurrent() - opened < InpHorizonBars * 300) continue;
      ResetLastError();
      if(!trade.PositionClose(t))
         Log(StringFormat("CLOSE FAILED #%I64u retcode=%u %s err=%d", t, trade.ResultRetcode(),
                          trade.ResultRetcodeDescription(), GetLastError()));
      else Log(StringFormat("CLOSE (horizon) #%I64u", t));
   }
}

// บันทึกผลเมื่อปิดไม้ (SL/TP/ปิดเอง)
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong deal = trans.deal;
   if(!HistoryDealSelect(deal)) return;
   if(HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic) return;
   if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;
   double p = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP)
            + HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
   ulong pos = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   Log(StringFormat("CLOSED position #%I64u profit=%.2f", pos, p));
   JournalClose(pos, p);
}
