//+------------------------------------------------------------------+
//| SignalEngine.mqh — HybridPro V21                                 |
//| Entry indicator logic แยกออกจาก EA หลัก                         |
//|                                                                  |
//| M1 (BUY):  RSI(14, H1) < RSI1Lvl  → gRSI1Ok = true            |
//| M2 (ADX):  ADX(14, H1) > ADXMin   → gADXDir = ±1              |
//| M3 (SELL): price < EMA(50, H1)    → gEMA3Ok = true             |
//|                                                                  |
//| Usage:                                                           |
//|   #include "SignalEngine.mqh"                                    |
//|   CSignalEngine signals;                                         |
//|   int OnInit() { return signals.Init(); }                        |
//|   void OnDeinit(int r) { signals.Deinit(); }                    |
//|   void OnTick() { signals.Calc(); ... }                          |
//|   // ใช้: signals.RSI1Ok(), signals.EMA3Ok(), signals.ADXDir()  |
//+------------------------------------------------------------------+
#pragma once

//+------------------------------------------------------------------+
class CSignalEngine {
private:
   int   m_hADX;
   int   m_hRSI1;
   int   m_hEMA3;

   // ── cached results (อัพเดตทุก Calc()) ──────────────────────────
   int   m_ADXDir;    // +1 = uptrend, -1 = downtrend, 0 = flat/weak
   bool  m_RSI1Ok;    // true = RSI < RSI1Lvl (oversold → M1 may open)
   bool  m_EMA3Ok;    // true = price < EMA    (downtrend → M3 may open)

   // ── indicator parameters (set in Init) ──────────────────────────
   bool            m_useADX,  m_useRSI1,  m_useEMA3;
   ENUM_TIMEFRAMES m_tfADX,   m_tfRSI1,   m_tfEMA3;
   int             m_perADX,  m_perRSI1,  m_perEMA3;
   double          m_minADX,  m_lvlRSI1;

public:
   CSignalEngine() :
      m_hADX(INVALID_HANDLE), m_hRSI1(INVALID_HANDLE), m_hEMA3(INVALID_HANDLE),
      m_ADXDir(0), m_RSI1Ok(false), m_EMA3Ok(false),
      m_useADX(true),  m_tfADX(PERIOD_H1),  m_perADX(14),  m_minADX(20.0),
      m_useRSI1(true), m_tfRSI1(PERIOD_H1), m_perRSI1(14), m_lvlRSI1(40.0),
      m_useEMA3(true), m_tfEMA3(PERIOD_H1), m_perEMA3(50) {}

   // ── Config setters (เรียกก่อน Init ถ้าต้องการเปลี่ยนค่า default) ──
   void SetADX (bool use, ENUM_TIMEFRAMES tf, int per, double minVal)
      { m_useADX =use; m_tfADX =tf; m_perADX =per; m_minADX =minVal; }
   void SetRSI1(bool use, ENUM_TIMEFRAMES tf, int per, double lvl)
      { m_useRSI1=use; m_tfRSI1=tf; m_perRSI1=per; m_lvlRSI1=lvl; }
   void SetEMA3(bool use, ENUM_TIMEFRAMES tf, int per)
      { m_useEMA3=use; m_tfEMA3=tf; m_perEMA3=per; }

   // ── Init: สร้าง indicator handles ─────────────────────────────
   int Init() {
      if(m_useADX) {
         m_hADX = iADX(_Symbol, m_tfADX, m_perADX);
         if(m_hADX == INVALID_HANDLE) { Print("[SignalEngine] ADX handle fail"); return INIT_FAILED; }
      }
      if(m_useRSI1) {
         m_hRSI1 = iRSI(_Symbol, m_tfRSI1, m_perRSI1, PRICE_CLOSE);
         if(m_hRSI1 == INVALID_HANDLE) { Print("[SignalEngine] RSI1 handle fail"); return INIT_FAILED; }
      }
      if(m_useEMA3) {
         m_hEMA3 = iMA(_Symbol, m_tfEMA3, m_perEMA3, 0, MODE_EMA, PRICE_CLOSE);
         if(m_hEMA3 == INVALID_HANDLE) { Print("[SignalEngine] EMA3 handle fail"); return INIT_FAILED; }
      }
      PrintFormat("[SignalEngine] Init OK  ADX=%s RSI1=%s EMA3=%s",
                  m_useADX?"on":"off", m_useRSI1?"on":"off", m_useEMA3?"on":"off");
      return INIT_SUCCEEDED;
   }

   // ── Deinit: คืน handles ────────────────────────────────────────
   void Deinit() {
      if(m_hADX  != INVALID_HANDLE) { IndicatorRelease(m_hADX);  m_hADX =INVALID_HANDLE; }
      if(m_hRSI1 != INVALID_HANDLE) { IndicatorRelease(m_hRSI1); m_hRSI1=INVALID_HANDLE; }
      if(m_hEMA3 != INVALID_HANDLE) { IndicatorRelease(m_hEMA3); m_hEMA3=INVALID_HANDLE; }
   }

   // ── Calc: อัพเดต signals ทุก tick ─────────────────────────────
   void Calc() {
      _CalcADX();
      _CalcRSI1();
      _CalcEMA3();
   }

   // ── Accessors ──────────────────────────────────────────────────
   int  ADXDir()  const { return m_ADXDir; }
   bool RSI1Ok()  const { return m_RSI1Ok; }
   bool EMA3Ok()  const { return m_EMA3Ok; }

   // ── Debug: แสดงค่าปัจจุบันทั้งหมด ─────────────────────────────
   string Status() const {
      double rsiVal = _GetRSIVal();
      double emaVal = _GetEMAVal();
      double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      return StringFormat(
         "ADX:%s  RSI1:%.1f(%s%.0f)  EMA3:%.2f vs %.2f(%s)",
         m_ADXDir==1?"▲UP":m_ADXDir==-1?"▼DN":"--",
         rsiVal, m_RSI1Ok?"<":">=", m_lvlRSI1,
         bid, emaVal, m_EMA3Ok?"SELL":"WAIT"
      );
   }

private:
   // ── Internal calculators ────────────────────────────────────────
   void _CalcADX() {
      m_ADXDir = 0;
      if(!m_useADX || m_hADX == INVALID_HANDLE) return;
      double adx[], pdi[], mdi[];
      ArraySetAsSeries(adx,true); ArraySetAsSeries(pdi,true); ArraySetAsSeries(mdi,true);
      if(CopyBuffer(m_hADX,0,0,2,adx)<2) return;
      if(CopyBuffer(m_hADX,1,0,2,pdi)<2) return;
      if(CopyBuffer(m_hADX,2,0,2,mdi)<2) return;
      if(adx[1] < m_minADX) return;
      m_ADXDir = (pdi[1] > mdi[1]) ? 1 : -1;
   }

   void _CalcRSI1() {
      if(!m_useRSI1 || m_hRSI1 == INVALID_HANDLE) { m_RSI1Ok = true; return; }
      double rsi[]; ArraySetAsSeries(rsi,true);
      if(CopyBuffer(m_hRSI1,0,1,1,rsi)<1) { m_RSI1Ok = false; return; }
      m_RSI1Ok = (rsi[0] < m_lvlRSI1);
   }

   void _CalcEMA3() {
      if(!m_useEMA3 || m_hEMA3 == INVALID_HANDLE) { m_EMA3Ok = true; return; }
      double ema[]; ArraySetAsSeries(ema,true);
      if(CopyBuffer(m_hEMA3,0,1,1,ema)<1) { m_EMA3Ok = false; return; }
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      m_EMA3Ok = (bid < ema[0]);
   }

   double _GetRSIVal() const {
      if(m_hRSI1 == INVALID_HANDLE) return 0;
      double rsi[]; ArraySetAsSeries(rsi,true);
      if(CopyBuffer(m_hRSI1,0,1,1,rsi)<1) return 0;
      return rsi[0];
   }

   double _GetEMAVal() const {
      if(m_hEMA3 == INVALID_HANDLE) return 0;
      double ema[]; ArraySetAsSeries(ema,true);
      if(CopyBuffer(m_hEMA3,0,1,1,ema)<1) return 0;
      return ema[0];
   }
};
