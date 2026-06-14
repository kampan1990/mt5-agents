//+------------------------------------------------------------------+
//| HybridPro_V21_FULL.mq5                                          |
//| M1=BUY grid (bidirectional) | M2=ADX/Trigger | M3=SELL grid     |
//| PATCH v21:                                                       |
//|   [1] GridLot() — แยก multiplier Up/Down ต่างกันสำหรับ M1, M3  |
//|   [2] Smart Recovery Engine — budget-based, smallest-loss-first  |
//|       แทนที่ AbsorbN/AbsorbMinNet/AbsorbRatio                   |
//+------------------------------------------------------------------+
#property copyright "HybridPro"
#property version   "21.01"
#property strict
#include <Trade\Trade.mqh>

#define EA_VER     "21.01"
#define EXPIRY_STR "2026.12.31 23:59"
#define MAGIC_1    1111
#define MAGIC_2    2222
#define MAGIC_3    3333
#define PFX        "HP_"

// ── Panel layout ─────────────────────────────────────────────────────
#define PW_OUT   316
#define PW_IN    310
#define HDR_H     30
#define ACCT_H    48
#define DD_H      26
#define TRIG_H    30

// ── Calendar panel ───────────────────────────────────────────────────
#define PFX2      "HP2_"
#define CDAY_W    52
#define CDAY_H    36
#define PW_CAL    (CDAY_W*7+6)
#define PW_TOTAL  (PW_OUT+PW_CAL)
#define CHDR_H    28
#define CDOW_H    18
#define CFTR_H    22
#define MSEC_H    64
#define M2R_H     42
#define TPST_H    44
#define STAT_H    68

// ── Color palette ────────────────────────────────────────────────────
#define CB_BORDER  C'42,55,95'
#define CB_BG      C'10,12,20'
#define CB_HDR     C'16,22,46'
#define CB_HDR_LN  C'48,92,210'
#define CB_M1      C'10,15,30'
#define CB_M2      C'13,10,26'
#define CB_M3      C'20,12,5'
#define CB_STAT    C'12,15,26'
#define CB_SEP     C'20,26,48'
#define CB_SEP_HI  C'35,46,80'
#define CB_BAR_BG  C'30,40,65'
#define CA_M1      C'38,128,255'
#define CA_M2      C'162,78,222'
#define CA_M3      C'232,122,12'
#define CL_GOLD    C'255,200,50'
#define CL_POS     C'48,212,98'
#define CL_NEG     C'232,62,62'
#define CL_NEU     C'125,138,162'
#define CL_INFO    C'105,120,150'
#define CL_BRIGHT  C'180,200,228'
#define CL_CYAN    C'0,198,218'
#define CL_WHITE   C'220,228,240'
#define CL_TIME    C'80,95,125'

// ── Font sizes ───────────────────────────────────────────────────────
#define FH  10
#define FN   9
#define FS   8
#define FXS  7

//+------------------------------------------------------------------+
//| Structs                                                          |
//+------------------------------------------------------------------+
struct TriggerState {
   bool   active;
   int    stoppedMagic;
   double trigPrice;
   int    stoppedDir;   // direction of stopped magic at trigger time: +1=BUY, -1=SELL
};

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Enable ==="
input bool   En1          = true;
input bool   En2          = true;
input bool   En3          = true;

input group "=== Lot ==="
input double Lot1         = 0.02;
input double Lot2         = 0.01;
input double Lot3         = 0.02;
input double LotMult2     = 1.0;   // M2 ยังใช้ตัวคูณเดียว (ไม่มีทิศ)

// ── [PATCH] Directional Multiplier M1 (BUY grid) ─────────────────
input group "=== M1 Directional Lot Multiplier ==="
// กราฟลง  = BUY ต้านเทรน → aggressive (คูณมาก)
// กราฟขึ้น = BUY ตามเทรน  → conservative (คูณน้อย)
input double LotMultDown1 = 1.5;   // M1: กราฟลง (ต้านเทรน)
input double LotMultUp1   = 1.1;   // M1: กราฟขึ้น (ตามเทรน)

// ── [PATCH] Directional Multiplier M3 (SELL grid) ────────────────
input group "=== M3 Directional Lot Multiplier ==="
// กราฟขึ้น = SELL ต้านเทรน → aggressive (คูณมาก)
// กราฟลง  = SELL ตามเทรน  → conservative (คูณน้อย)
input double LotMultUp3   = 1.5;   // M3: กราฟขึ้น (ต้านเทรน)
input double LotMultDown3 = 1.1;   // M3: กราฟลง (ตามเทรน)

input group "=== Lot Multiplier Start ==="
// จำนวนไม้ขั้นต่ำที่ต้องมีก่อน ตัวคูณถึงจะเริ่มทำงาน (0 = ใช้ตัวคูณทันทีแบบเดิม)
input int    MultStart1   = 0;   // M1: รอกี่ไม้ก่อนคูณ
input int    MultStart2   = 0;   // M2: รอกี่ไม้ก่อนคูณ
input int    MultStart3   = 0;   // M3: รอกี่ไม้ก่อนคูณ

input group "=== Grid Spacing (points) ==="
input int    GS1          = 75;
input int    GS2          = 75;
input int    GS3          = 75;

input group "=== Grid Limits ==="
input int    MaxGrid1     = 5;
input int    MaxGrid2     = 3;
input int    MaxGrid3     = 5;

input group "=== Loss Trigger ==="
input double LossTrig1    = 400.0;
input double LossTrig2    = 400.0;   // M2: หยุดเปิดใหม่เมื่อ PNL <= -LossTrig2 (0=ปิด)
input double LossTrig3    = 400.0;
input int    TrigCoolSec  = 300;

input group "=== ADX (M2 Direction) ==="
input bool            UseADX  = true;
input ENUM_TIMEFRAMES ADXTF   = PERIOD_H1;
input int             ADXPer  = 14;
input double          ADXMin  = 20.0;

input group "=== M1 Entry Filter (RSI) ==="
input bool            UseRSI1  = true;
input ENUM_TIMEFRAMES RSI1TF   = PERIOD_H1;
input int             RSI1Per  = 14;
input double          RSI1Lvl     = 40.0;  // เปิด BUY แรกเมื่อ RSI < ค่านี้ (oversold)
input double          RSI1SellLvl = 60.0;  // เปิด SELL แรกเมื่อ RSI > ค่านี้ (overbought)

input group "=== M3 Entry Filter (EMA) ==="
input bool            UseEMA3  = true;
input ENUM_TIMEFRAMES EMA3TF   = PERIOD_H1;
input int             EMA3Per  = 50;    // เปิด SELL แรกเมื่อ price < EMA(N) (downtrend)

input group "=== Take Profit ==="
input bool   UseSepTP     = true;
input double TP1          = 10.0;
input double TP2          = 5.0;
input double TP3          = 10.0;
input bool   UsePairTP    = true;
input double TPPair       = 20.0;
input bool   UseTotTP     = true;
input double TPTot        = 30.0;
input group "=== Smart Recovery Engine ==="
// RecoveryRatio: % ของกำไร TP ที่จัดสรรไว้ล้างไม้เสีย
// ตัวอย่าง: TP = $10, RecoveryRatio = 70% → RecoveryBudget = $7
// ระบบจะเลือกไม้เสียที่ขาดทุน "น้อยที่สุด" ออกก่อนจนเต็ม budget
// เงื่อนไข: Net หลังหักไม้เสีย >= 0 เท่านั้นจึงจะปิด
input double RecoveryRatio = 70.0;  // % ของ winSum (0=ปิดใช้งาน)

input group "=== Hard Recovery ==="
input double TP2Assist          = 0.0;    // M2 TP target ตอน assist mode (0=fire ทันทีที่ net ≥ 0)
input double HardRecovery       = 1000.0; // ไม้เสีย ≥ ค่านี้ → จัดการก่อน ข้าม RecoveryRatio (0=ปิด)
input double HeavyLossThreshold = 100.0;  // ไม้เสีย ≥ ค่านี้ = "heavy" → บังคับ TP รอสะสม (0=ปิด)

input group "=== Best Side Pool ==="
// ปิดทั้ง pool เมื่อกำไรรวมถึงเป้า — ไม่ปิดแยกรายไม้ ไม่แยก magic
input int    BestBuyN     = 2;     // จำนวนไม้ BUY กำไรสูงสุด (M1+M2 BUY รวมกัน)
input double TPBestBuy    = 40.0;  // เป้ากำไรรวม BUY pool (USD)
input int    BestSellN    = 2;     // จำนวนไม้ SELL กำไรสูงสุด (M3+M2 SELL รวมกัน)
input double TPBestSell   = 40.0;  // เป้ากำไรรวม SELL pool (USD)

input group "=== Spread ==="
input int    MaxSpread    = 50;

input group "=== Daily Lot Limit ==="
input double MaxDailyLot  = 0.0;   // Per-magic limit (M1/M2/M3 แยกกัน, 0=ปิด)

input group "=== Panel ==="
input bool   ShowPanel    = true;
input int    PanelX       = 10;
input int    PanelY       = 20;

input group "=== Calendar Panel ==="
input bool   ShowCal      = true;

input group "=== Daily Cash Flow ==="
input double DailyProfitTarget = 0.0;   // Daily profit target USD (0=disabled)
input bool   CloseAllAtTarget  = false;  // Close all positions when target hit

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade T1, T2, T3;
int      hADX         = INVALID_HANDLE;
int      hRSI1        = INVALID_HANDLE;
int      hEMA3        = INVALID_HANDLE;
int      gADXDir      = 0;
int      gRSI1Dir     = 0;     // RSI signal: +1=oversold(BUY), -1=overbought(SELL), 0=neutral
int      gEMA3Dir     = 0;     // EMA signal: +1=price>EMA(BUY), -1=price<EMA(SELL)
datetime gTrigCoolEnd = 0;

TriggerState gTrig;

double gLastM1   = 0.0;   // last open price for M1 (BUY or SELL grid)
double gLastM3   = 0.0;   // last open price for M3 (BUY or SELL grid)
int    gM1Dir    = 0;     // current M1 direction: +1=BUY, -1=SELL, 0=none
int    gM3Dir    = 0;     // current M3 direction: +1=BUY, -1=SELL, 0=none

// ── [PATCH] ตัวนับไม้แยกทิศทาง ───────────────────────────────────
// M1 BUY: นับแยกว่าเปิดตอนกราฟลง (Down) หรือกราฟขึ้น (Up)
int gCntDown1 = 0;   // M1: ไม้ที่เปิดตอนกราฟลง (ต้านเทรน)
int gCntUp1   = 0;   // M1: ไม้ที่เปิดตอนกราฟขึ้น (ตามเทรน)
// M3 SELL: นับแยกว่าเปิดตอนกราฟขึ้น (Up=ต้านเทรน) หรือกราฟลง (Down=ตามเทรน)
int gCntUp3   = 0;   // M3: ไม้ที่เปิดตอนกราฟขึ้น (ต้านเทรน)
int gCntDown3 = 0;   // M3: ไม้ที่เปิดตอนกราฟลง (ตามเทรน)

// BestSidePool trackers
ulong gBestBuyTk[];
ulong gBestSellTk[];

// ตรวจว่า ticket อยู่ใน BestSidePool หรือไม่ — ป้องกัน grid TP แตะไม้ pool
bool IsInBestPool(ulong tk) {
   for(int i=0; i<ArraySize(gBestBuyTk);  i++) if(gBestBuyTk[i]  == tk) return true;
   for(int i=0; i<ArraySize(gBestSellTk); i++) if(gBestSellTk[i] == tk) return true;
   return false;
}

double   gDailyLot1  = 0.0;
double   gDailyLot2  = 0.0;
double   gDailyLot3  = 0.0;
datetime gTodayStart = 0;

bool   gTrigJustFired = false;
bool     gM2Locked  = false;   // M2 loss lock — หยุดเปิดใหม่เมื่อ PNL โดนลากถึง LossTrig2
datetime gM2CoolEnd = 0;

double gPeakEquity = 0.0;
double gMaxDDPct   = 0.0;
bool   gNormalTPFired = false;

double   gCalPnl[31];
double   gCalLot[31];
datetime gCalBuildTime = 0;
bool     gCalDirty     = true;

double gTodayProfit       = 0.0;
bool   gDailyTargetHit   = false;
double gTodayRealized     = 0.0;  // cached realized-only (refreshed on deal count change)
int    gLastDealCount     = 0;

//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+
double NLot(double v) {
   double s  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   v = MathFloor(v / s) * s;
   if(v < mn) v = mn;
   if(v > mx) v = mx;
   int dp = (s >= 1.0) ? 0 : (int)MathRound(-MathLog10(s));
   return NormalizeDouble(v, dp);
}

CTrade* TR(int m) {
   if(m == MAGIC_1) return &T1;
   if(m == MAGIC_2) return &T2;
   return &T3;
}

bool SpreadOK() {
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= MaxSpread;
}

int Count(int m) {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      c++;
   }
   return c;
}

int CountLosers(int m) {
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double pp = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pp < 0) n++;
   }
   return n;
}

// นับไม้เสียที่อยู่ใน mgs[] (ข้าม BestPool) — ใช้ตรวจ mandatory loser gate
int CountLosersInGroup(int &mgs[], int dirFilter=0) {
   int total = 0;
   int nm = ArraySize(mgs);
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(IsInBestPool(tk)) continue;
      int m = (int)PositionGetInteger(POSITION_MAGIC);
      bool inMgs = false;
      for(int mi = 0; mi < nm; mi++) if(mgs[mi] == m) { inMgs = true; break; }
      if(!inMgs) continue;
      if(dirFilter != 0) {
         int posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         if(posDir != dirFilter) continue;
      }
      double pp = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pp < 0) total++;
   }
   return total;
}

// รวม |loss| ของไม้เสียหนัก (|pp| >= HeavyLossThreshold) ในกลุ่ม — ไม่นับ BestPool
double CalcHeavyDebt(int &mgs[]) {
   if(HeavyLossThreshold <= 0) return 0.0;
   double debt = 0;
   int nm = ArraySize(mgs);
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int m = (int)PositionGetInteger(POSITION_MAGIC);
      bool inMgs = false;
      for(int mi = 0; mi < nm; mi++) if(mgs[mi] == m) { inMgs = true; break; }
      if(!inMgs) continue;
      double pp = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pp >= 0) continue;
      double loss = MathAbs(pp);
      if(loss >= HeavyLossThreshold) debt += loss;
   }
   return debt;
}

double PNL(int m) {
   double p = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      p += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return p;
}

void SortPairsByPnl(ulong &tk[], double &pf[], int c, bool ascending) {
   if(c <= 1 || c > ArraySize(tk) || c > ArraySize(pf)) return;
   for(int i = 0; i < c - 1; i++)
      for(int j = i + 1; j < c; j++) {
         bool sw = ascending ? (pf[j] < pf[i]) : (pf[j] > pf[i]);
         if(sw) {
            ulong  tu = tk[i]; tk[i] = tk[j]; tk[j] = tu;
            double pu = pf[i]; pf[i] = pf[j]; pf[j] = pu;
         }
      }
}

ulong GetBestTk(int m) {
   ulong  bestTk = 0;
   double bestPf = -DBL_MAX;  // ใช้ -DBL_MAX เพื่อให้ pp=0 ก็ถูก protect ได้
   bool   found  = false;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double pp = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(!found || pp > bestPf) { bestPf = pp; bestTk = t; found = true; }
   }
   return found ? bestTk : 0;
}


int GetBestProfit(int m, int maxN, ulong &outTk[], double &outPf[]) {
   int total = PositionsTotal();
   ulong  tk[]; ArrayResize(tk, total);
   double pf[]; ArrayResize(pf, total);
   int c = 0;
   for(int i = total - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double pp = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pp <= 0) continue;
      tk[c] = t; pf[c] = pp; c++;
   }
   SortPairsByPnl(tk, pf, c, false);
   int n = MathMin(c, maxN);
   ArrayResize(outTk, n); ArrayResize(outPf, n);
   for(int i = 0; i < n; i++) { outTk[i] = tk[i]; outPf[i] = pf[i]; }
   return n;
}

bool CloseByTicket(ulong tk) {
   if(!PositionSelectByTicket(tk)) return false;
   int m = (int)PositionGetInteger(POSITION_MAGIC);
   return TR(m).PositionClose(tk, -1);
}

void CM(int m) {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      TR(m).PositionClose(tk, -1);
   }
}

// ปิดเฉพาะไม้กำไรของ magic m — ไม้เสียปล่อยทิ้งไว้ให้ TP Recovery จัดการ
void CMWinners(int m) {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double pp = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pp > 0) TR(m).PositionClose(tk, -1);
   }
}

bool HasPositionNearPrice(int m, int dir, double price, int gsPts) {
   double zone = gsPts * _Point;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int pd = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(pd != dir) continue;
      if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - price) < zone) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| ADX                                                              |
//+------------------------------------------------------------------+
int ADXDir() {
   if(!UseADX || hADX == INVALID_HANDLE) return 0;
   double adx[], pdi[], mdi[];
   ArraySetAsSeries(adx, true); ArraySetAsSeries(pdi, true); ArraySetAsSeries(mdi, true);
   if(CopyBuffer(hADX, 0, 0, 2, adx) < 2) return 0;
   if(CopyBuffer(hADX, 1, 0, 2, pdi) < 2) return 0;
   if(CopyBuffer(hADX, 2, 0, 2, mdi) < 2) return 0;
   if(adx[1] < ADXMin) return 0;
   return (pdi[1] > mdi[1]) ? 1 : -1;
}

void CalcM1Signal() {
   gRSI1Dir = 0;
   if(!UseRSI1 || hRSI1 == INVALID_HANDLE) return;  // disabled → neutral (no new grid)
   double rsi[]; ArraySetAsSeries(rsi, true);
   if(CopyBuffer(hRSI1, 0, 1, 1, rsi) < 1) return;
   if(rsi[0] < RSI1Lvl)          gRSI1Dir = +1;  // oversold → BUY
   else if(rsi[0] > RSI1SellLvl) gRSI1Dir = -1;  // overbought → SELL
   // RSI1Lvl..RSI1SellLvl = neutral zone → gRSI1Dir stays 0
}

void CalcM3Signal() {
   gEMA3Dir = 0;
   if(!UseEMA3 || hEMA3 == INVALID_HANDLE) return;  // disabled → neutral
   double ema[]; ArraySetAsSeries(ema, true);
   if(CopyBuffer(hEMA3, 0, 1, 1, ema) < 1) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   gEMA3Dir = (bid < ema[0]) ? -1 : +1;  // below EMA = SELL, above EMA = BUY
}

//+------------------------------------------------------------------+
//| Daily lot tracking                                               |
//+------------------------------------------------------------------+
void ChkDayRollover() {
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart != gTodayStart) {
      gTodayStart = dayStart;
      gDailyLot1 = gDailyLot2 = gDailyLot3 = 0.0;
      gCalDirty = true;
      gTodayProfit    = 0.0;
      gTodayRealized  = 0.0;
      gLastDealCount  = 0;
      gDailyTargetHit = false;
   }
}

double CalcTodayRealizedProfit() {
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(!HistorySelect(dayStart, TimeCurrent())) return 0;
   double profit = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_BALANCE) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN) continue;
      profit += HistoryDealGetDouble(ticket, DEAL_PROFIT)
              + HistoryDealGetDouble(ticket, DEAL_SWAP)
              + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return profit;
}

void CloseAllPositions() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int m = (int)PositionGetInteger(POSITION_MAGIC);
      TR(m).PositionClose(ticket);
   }
}

void CheckDailyTarget() {
   if(DailyProfitTarget <= 0) return;
   // refresh realized cache only when a new deal closes (avoids HistorySelect every tick)
   int dealCount = HistoryDealsTotal();
   if(dealCount != gLastDealCount) {
      gTodayRealized  = CalcTodayRealizedProfit();
      gLastDealCount  = dealCount;
   }
   double floating = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   gTodayProfit = gTodayRealized + floating;
   if(!gDailyTargetHit && gTodayProfit >= DailyProfitTarget) {
      gDailyTargetHit = true;
      Print("[DailyTarget] Hit: ", DoubleToString(gTodayProfit,2), " >= ", DoubleToString(DailyProfitTarget,2));
      if(CloseAllAtTarget) CloseAllPositions();
   }
}

void RestoreDailyLots() {
   gTodayStart = iTime(_Symbol, PERIOD_D1, 0);
   gDailyLot1 = gDailyLot2 = gDailyLot3 = 0.0;
   if(!HistorySelect(gTodayStart, TimeCurrent())) return;
   for(int i = 0; i < HistoryDealsTotal(); i++) {
      ulong deal = HistoryDealGetTicket(i);
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if((int)HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      int    m   = (int)HistoryDealGetInteger(deal, DEAL_MAGIC);
      double vol = HistoryDealGetDouble(deal, DEAL_VOLUME);
      if(m == MAGIC_1)      gDailyLot1 += vol;
      else if(m == MAGIC_2) gDailyLot2 += vol;
      else if(m == MAGIC_3) gDailyLot3 += vol;
   }
}

//+------------------------------------------------------------------+
//| Open Order                                                       |
//+------------------------------------------------------------------+
bool OO(int m, int dir, double lot) {
   if(!SpreadOK()) return false;
   if(MaxDailyLot > 0) {
      double used = (m == MAGIC_1) ? gDailyLot1 : (m == MAGIC_2) ? gDailyLot2 : gDailyLot3;
      if(used + lot > MaxDailyLot) return false;
   }
   double price = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                              : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int gs = (m == MAGIC_1) ? GS1 : (m == MAGIC_2) ? GS2 : GS3;
   if(HasPositionNearPrice(m, dir, price, gs)) return false;
   CTrade* tr = TR(m);
   int mNum = (m == MAGIC_1) ? 1 : (m == MAGIC_2) ? 2 : 3;
   bool ok = (dir == 1) ? tr.Buy(lot,  _Symbol, 0, 0, 0, "M" + IntegerToString(mNum))
                        : tr.Sell(lot, _Symbol, 0, 0, 0, "M" + IntegerToString(mNum));
   if(ok) {
      if(m == MAGIC_1)      gDailyLot1 += lot;
      else if(m == MAGIC_2) gDailyLot2 += lot;
      else                  gDailyLot3 += lot;
   } else {
      PrintFormat("[OO] FAIL M%d dir=%d err=%d", m, dir, GetLastError());
   }
   return ok;
}

//+------------------------------------------------------------------+
//| TP CORE                                                          |
//+------------------------------------------------------------------+
double GetWinnerSum(int m, ulong bestTk) {
   ulong pTk[]; double pPf[];
   int n = GetBestProfit(m, 999, pTk, pPf);
   double s = 0;
   for(int i = 0; i < n; i++) {
      if(bestTk > 0 && pTk[i] == bestTk) continue;
      if(IsInBestPool(pTk[i])) continue;  // ไม้ BestPool ไม่นับในกำไร grid
      s += pPf[i];
   }
   return s;
}

int GetWinnersToClose(int m, ulong bestTk, ulong &outTk[]) {
   ulong pTk[]; double pPf[];
   int n = GetBestProfit(m, 999, pTk, pPf);
   ArrayResize(outTk, 0);
   int cnt = 0;
   for(int i = 0; i < n; i++) {
      if(bestTk > 0 && pTk[i] == bestTk) continue;
      if(IsInBestPool(pTk[i])) continue;  // ไม้ BestPool ห้ามถูก grid TP แตะ
      ArrayResize(outTk, cnt+1);
      outTk[cnt++] = pTk[i];
   }
   return cnt;
}

double GetCloseableGP(int m, ulong skipTk=0) {
   return GetWinnerSum(m, skipTk);
}

//+------------------------------------------------------------------+
//| SelectRecoveryLosers                                             |
//| เลือกไม้เสียออกพร้อม TP — เรียงจากขาดทุนหนักสุดก่อนเสมอ        |
//| gate: outNet - |loss| >= minNet → ดูดไม้นั้น, ไม่ถึงให้ข้ามต่อ  |
//| return: จำนวนไม้ที่เลือก, fill outTk[] outPf[] outNet           |
//+------------------------------------------------------------------+
int SelectRecoveryLosers(int &mgs[], double winSum,
                         ulong &outTk[], double &outPf[], double &outNet,
                         int dirFilter = 0, double minNet = 0.0) {
   ArrayResize(outTk, 0);
   ArrayResize(outPf, 0);
   outNet = winSum;

   int    totalPos = PositionsTotal();
   ulong  lTk[];  ArrayResize(lTk, totalPos);
   double lPf[];  ArrayResize(lPf, totalPos);
   int    lCnt = 0;

   int nm = ArraySize(mgs);
   for(int i = totalPos - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(IsInBestPool(t)) continue;
      if(dirFilter != 0) {
         int posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         if(posDir != dirFilter) continue;
      }
      int m = (int)PositionGetInteger(POSITION_MAGIC);
      bool inMgs = false;
      for(int mi = 0; mi < nm; mi++) if(mgs[mi] == m) { inMgs = true; break; }
      if(!inMgs) continue;
      double pp = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pp >= 0) continue;
      lTk[lCnt] = t;
      lPf[lCnt] = pp;
      lCnt++;
   }

   if(lCnt == 0) return 0;

   // เรียงจากขาดทุนหนักสุดก่อน (most negative first)
   if(lCnt > 1) SortPairsByPnl(lTk, lPf, lCnt, true);

   // ดูดไม้เสียเข้า group ถ้า net ยังไม่ต่ำกว่า minNet
   int cnt = 0;
   for(int i = 0; i < lCnt; i++) {
      double loss = MathAbs(lPf[i]);
      if(outNet - loss < minNet) continue;  // ไม้นี้ใหญ่เกินไป → ข้าม ลองไม้ถัดไป
      outNet -= loss;
      ArrayResize(outTk, cnt + 1);
      ArrayResize(outPf, cnt + 1);
      outTk[cnt] = lTk[i];
      outPf[cnt] = lPf[i];
      cnt++;
   }
   return cnt;
}

//+------------------------------------------------------------------+
//| BuildTPGroup — Smart Recovery Engine (heaviest-loss-first)       |
//+------------------------------------------------------------------+
int BuildTPGroup(int &mgs[], ulong &groupTk[], double &groupNet, double &winSum, double minNet = 0.0) {
   int nm = ArraySize(mgs);
   ArrayResize(groupTk, 0);
   groupNet = 0;
   winSum   = 0;
   if(nm == 0) return 0;

   // ── รวม Winners เข้า Group (ปิดทุกไม้กำไร ยกเว้น BestPool ที่มี TP แยก) ─
   int gCnt = 0;
   for(int mi = 0; mi < nm; mi++) {
      ulong wTk[];
      int nW = GetWinnersToClose(mgs[mi], 0, wTk);  // 0 = ไม่ยกเว้น per-magic best
      for(int i = 0; i < nW; i++) {
         ArrayResize(groupTk, gCnt + 1);
         groupTk[gCnt++] = wTk[i];
         if(PositionSelectByTicket(wTk[i]))
            winSum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }

   // ── ขั้น 3: Recovery — ดูดไม้เสียหนักสุดก่อน, gate: net >= minNet
   ulong  recTk[]; double recPf[]; double recNet;
   int recN = SelectRecoveryLosers(mgs, winSum, recTk, recPf, recNet, 0, minNet);

   if(recN > 0) {
      for(int i = 0; i < recN; i++) {
         ArrayResize(groupTk, gCnt + 1);
         groupTk[gCnt++] = recTk[i];
      }
   }

   groupNet = (recN > 0) ? recNet : winSum;
   return gCnt;
}

//+------------------------------------------------------------------+
//| FireTPGroup                                                      |
//+------------------------------------------------------------------+
void FireTPGroup(ulong &groupTk[]) {
   int n = ArraySize(groupTk);
   ulong  ordTk[]; double ordPf[];
   ArrayResize(ordTk, n); ArrayResize(ordPf, n);
   for(int i = 0; i < n; i++) {
      ordTk[i] = groupTk[i];
      ordPf[i] = 0;
      if(PositionSelectByTicket(groupTk[i]))
         ordPf[i] = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   SortPairsByPnl(ordTk, ordPf, n, true);  // loser ก่อน
   for(int i = 0; i < n; i++) CloseByTicket(ordTk[i]);
}

//+------------------------------------------------------------------+
//| TryTP                                                            |
//+------------------------------------------------------------------+
bool TryTP(int &mgs[], double target, string tag) {
   ulong  groupTk[];
   double groupNet;
   double winSum;
   int n = BuildTPGroup(mgs, groupTk, groupNet, winSum, target);  // ดูดไม้เสีย heaviest-first, net >= target
   if(n == 0) return false;
   if(groupNet < target) return false;  // net หลังดูดไม้เสียต้อง >= target

   int gn = ArraySize(groupTk);

   // Gate 1: ถ้ามีไม้เสีย ต้องดูดออกอย่างน้อย 1 ไม้
   int totalLosers = CountLosersInGroup(mgs);
   if(totalLosers > 0) {
      int absorbed = 0;
      for(int i = 0; i < gn; i++) {
         if(PositionSelectByTicket(groupTk[i])) {
            if(PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP) < 0) absorbed++;
         }
      }
      if(absorbed == 0) return false;
   }

   // Gate 2: ถ้ามี heavy loser (|loss| >= HeavyLossThreshold) → ต้องดูดออกอย่างน้อย 1 ตัว
   // รอจน winners โตพอให้ SelectRecoveryLosers absorb heavy loser ได้ (net ยังคง >= target)
   if(HeavyLossThreshold > 0 && CalcHeavyDebt(mgs) > 0) {
      bool absorbedHeavy = false;
      for(int i = 0; i < gn; i++) {
         if(PositionSelectByTicket(groupTk[i])) {
            double pp = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
            if(pp < -HeavyLossThreshold) { absorbedHeavy = true; break; }
         }
      }
      if(!absorbedHeavy) return false;  // heavy loser ยังดูดออกไม่ได้ — รอ
   }

   FireTPGroup(groupTk);
   gNormalTPFired = true;
   PrintFormat("[%s] winners=%.2f net=%.2f target=%.2f closed=%d",
               tag, winSum, groupNet, target, n);
   return true;
}

//+------------------------------------------------------------------+
//| UpdatePool — Stable pool helper                                  |
//| Pool ไม่ rebuild ทุก tick — positions ค้างอยู่จนกว่าจะถูกแทนที่  |
//| Eviction: เมื่อมี candidate ดีกว่า pool worst → สลับออก 1 ตัว   |
//| Evicted position กลายเป็น grid position ปกติ (รอ grid TP ถัดไป) |
//+------------------------------------------------------------------+
void UpdatePool(ulong &pool[], ENUM_POSITION_TYPE posType, int maxN) {
   if(maxN <= 0) { ArrayResize(pool, 0); return; }

   // ── Step 1: นำ dead/loser members ออก ──────────────────────────
   for(int i = ArraySize(pool)-1; i >= 0; i--) {
      bool keep = false;
      if(PositionSelectByTicket(pool[i])) {
         double pp = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
         if(pp > 0) keep = true;
      }
      if(!keep) {
         int n = ArraySize(pool);
         for(int j = i; j < n-1; j++) pool[j] = pool[j+1];
         ArrayResize(pool, n-1);
      }
   }
   int nPool = ArraySize(pool);

   // ── Step 2: รวม candidates (ไม่อยู่ใน pool, profitable, ทิศถูก) ─
   int total = PositionsTotal();
   ulong  cTk[]; ArrayResize(cTk, total);
   double cPf[]; ArrayResize(cPf, total);
   int cnt = 0;
   for(int i = total-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;
      double pp = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pp <= 0) continue;
      bool inPool = false;
      for(int pi = 0; pi < nPool; pi++) if(pool[pi] == t) { inPool = true; break; }
      if(inPool) continue;
      cTk[cnt] = t; cPf[cnt] = pp; cnt++;
   }
   if(cnt > 1) SortPairsByPnl(cTk, cPf, cnt, false); // best first

   // ── Step 3: เติม slot ว่าง ────────────────────────────────────
   int ci = 0;
   while(nPool < maxN && ci < cnt) {
      ArrayResize(pool, nPool+1);
      pool[nPool] = cTk[ci];
      nPool++; ci++;
   }

   // ── Step 4: สลับ worst pool ← best candidate (ถ้าดีกว่า) ──────
   // ทำครั้งละ 1 ตัวเท่านั้น — pool เสถียร ไม่ swap หลายตัวต่อ tick
   if(nPool >= maxN && ci < cnt) {
      double worstPf = DBL_MAX; int worstI = -1;
      for(int pi = 0; pi < nPool; pi++) {
         if(!PositionSelectByTicket(pool[pi])) continue;
         double pp = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
         if(pp < worstPf) { worstPf = pp; worstI = pi; }
      }
      if(worstI >= 0 && cPf[ci] > worstPf) {
         pool[worstI] = cTk[ci]; // evicted → กลับสู่ grid TP ถัดไป
      }
   }
}

//+------------------------------------------------------------------+
//| UpdateBestSide — อัปเดต pool ทั้ง 2 ฝั่งทุก tick               |
//+------------------------------------------------------------------+
void UpdateBestSide() {
   UpdatePool(gBestBuyTk,  POSITION_TYPE_BUY,  BestBuyN);
   UpdatePool(gBestSellTk, POSITION_TYPE_SELL, BestSellN);
}

//+------------------------------------------------------------------+
//| ChkBestSideTP — BUY pool (ไม้ BUY กำไรสูงสุด N ไม้ข้ามทุก magic)|
//|                 SELL pool (ไม้ SELL กำไรสูงสุด N ไม้ข้ามทุก magic)|
//| ปิดทั้ง pool เมื่อกำไรรวมถึงเป้า — ไม่ปิดแยกรายไม้              |
//+------------------------------------------------------------------+
void FireBestSidePool(ulong &poolTk[], ENUM_POSITION_TYPE dir, double target, int requiredN, string tag) {
   int n = ArraySize(poolTk);
   if(n == 0 || target <= 0.0) return;

   // pool ต้องครบ requiredN ไม้ก่อนจึงจะ TP ได้
   if(n < requiredN) {
      // log ครั้งแรกเท่านั้นเพื่อไม่ spam
      // PrintFormat("[%s] pool %d/%d — รอให้ครบก่อน", tag, n, requiredN);
      return;
   }

   double winSum = 0;
   int alive = 0;
   for(int i = 0; i < n; i++) {
      if(!PositionSelectByTicket(poolTk[i])) continue;
      winSum += PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      alive++;
   }
   if(alive == 0) return;

   int    mgsBoth[] = {MAGIC_1, MAGIC_2, MAGIC_3};

   // ดูดไม้เสีย heaviest-first gate: net >= target
   ulong  recTk[]; double recPf[]; double recNet;
   int recN = SelectRecoveryLosers(mgsBoth, winSum, recTk, recPf, recNet, 0, target);

   if(recNet < target) return;

   // Gate 1: ถ้ามีไม้เสียแต่ดูดไม่ได้เลย → hold
   int totalLosersAll = CountLosersInGroup(mgsBoth);
   if(totalLosersAll > 0 && recN == 0) return;

   // Gate 2: ถ้ามี heavy loser → ต้องดูดออกอย่างน้อย 1 ตัว
   if(HeavyLossThreshold > 0 && CalcHeavyDebt(mgsBoth) > 0) {
      bool absorbedHeavy = false;
      for(int i = 0; i < recN; i++) {
         if(PositionSelectByTicket(recTk[i])) {
            double pp = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
            if(pp < -HeavyLossThreshold) { absorbedHeavy = true; break; }
         }
      }
      if(!absorbedHeavy) return;  // heavy loser ยังดูดออกไม่ได้ — รอ
   }

   PrintFormat("[%s] winSum=%.2f net=%.2f target=%.2f winners=%d recovery=%d",
               tag, winSum, recNet, target, alive, recN);

   // ตรวจว่า recovery positions ยังมีอยู่ทุกตัว ก่อน close ใดๆ (ป้องกัน partial orphan)
   for(int i=0; i<recN; i++) {
      if(!PositionSelectByTicket(recTk[i])) {
         PrintFormat("[%s] recovery pos %I64u vanished — abort", tag, recTk[i]);
         return;
      }
   }
   bool allRecClosed = true;
   for(int i=0; i<recN; i++) {
      if(!CloseByTicket(recTk[i])) { allRecClosed = false; break; }
   }
   if(!allRecClosed) {
      PrintFormat("[%s] recovery close failed — abort pool close", tag);
      return;
   }
   for(int i=0; i<n; i++) CloseByTicket(poolTk[i]);
}

void ChkBestSideTP() {
   FireBestSidePool(gBestBuyTk,  POSITION_TYPE_BUY,  TPBestBuy,  BestBuyN,  "BestBuyTP");
   FireBestSidePool(gBestSellTk, POSITION_TYPE_SELL, TPBestSell, BestSellN, "BestSellTP");
}

//+------------------------------------------------------------------+
//| ChkAllTP — Priority: P1 TotTP → P2 PairTP → P3 SepTP           |
//+------------------------------------------------------------------+
void ChkAllTP() {
   if(UseTotTP) {
      int mgs[] = {MAGIC_1, MAGIC_2, MAGIC_3};
      if(TryTP(mgs, TPTot, "TotTP")) return;
   }
   if(UsePairTP) {
      int pA[3], pB[3];
      pA[0]=MAGIC_1; pB[0]=MAGIC_2;
      pA[1]=MAGIC_1; pB[1]=MAGIC_3;
      pA[2]=MAGIC_2; pB[2]=MAGIC_3;
      int bestIdx=-1; double bestWin=-1e9;
      for(int i = 0; i < 3; i++) {
         ulong bkA = GetBestTk(pA[i]);
         ulong bkB = GetBestTk(pB[i]);
         double w = GetWinnerSum(pA[i], bkA) + GetWinnerSum(pB[i], bkB);
         if(w > bestWin) { bestWin = w; bestIdx = i; }
      }
      if(bestIdx >= 0 && bestWin > 0) {
         int mgs[2]; mgs[0]=pA[bestIdx]; mgs[1]=pB[bestIdx];
         string tag = StringFormat("PairTP[M%d+M%d]",
                         mgs[0]==MAGIC_1?1:(mgs[0]==MAGIC_2?2:3),
                         mgs[1]==MAGIC_1?1:(mgs[1]==MAGIC_2?2:3));
         if(TryTP(mgs, TPPair, tag)) return;
      }
   }
   if(UseSepTP) {
      bool m1stop = gTrig.active && gTrig.stoppedMagic == MAGIC_1;
      bool m3stop = gTrig.active && gTrig.stoppedMagic == MAGIC_3;
      if(En1 && !m1stop && Count(MAGIC_1) > 0) {
         int mgs[] = {MAGIC_1};
         if(TryTP(mgs, TP1, "SepTP[M1]")) return;
      }
      if(En2 && Count(MAGIC_2) > 0) {
         // ── M2 TP: รวม magic ที่ M2 กำลัง assist เข้า group ─────────
         // เพื่อให้ Smart Recovery ดึงไม้เสียของฝั่งที่ M2 ช่วยอยู่ออกด้วย
         // Trigger active → รวม magic ที่ถูกล็อก / Normal → M2 เดี่ยว
         if(gTrig.active && gTrig.stoppedMagic == MAGIC_1) {
            int mgs[] = {MAGIC_2, MAGIC_1};
            if(TryTP(mgs, MathMax(0.001, TP2Assist), "SepTP[M2+M1assist]")) return;
         } else if(gTrig.active && gTrig.stoppedMagic == MAGIC_3) {
            int mgs[] = {MAGIC_2, MAGIC_3};
            if(TryTP(mgs, MathMax(0.001, TP2Assist), "SepTP[M2+M3assist]")) return;
         } else {
            // Normal mode: M2 TP แยกเดี่ยว ไม่ดึง loser ฝั่งอื่น
            int mgs[] = {MAGIC_2};
            if(TryTP(mgs, TP2, "SepTP[M2]")) return;
         }
      }
      if(En3 && !m3stop && Count(MAGIC_3) > 0) {
         int mgs[] = {MAGIC_3};
         if(TryTP(mgs, TP3, "SepTP[M3]")) return;
      }
   }
}


//+------------------------------------------------------------------+
//| [PATCH] GridLot — แยก multiplier ตามทิศทางกราฟ                  |
//|   priceDir : +1 = กราฟขึ้น, -1 = กราฟลง                       |
//|   level    : จำนวนไม้ที่เปิดในทิศนั้นแล้ว (ก่อนเปิดไม้ใหม่)   |
//|   totalCnt : จำนวนไม้ทั้งหมดของ magic นั้น (ก่อนเปิดไม้ใหม่)  |
//|   MultStart: ต้องมีไม้ครบ MultStartN ก่อน ตัวคูณถึงเริ่มทำงาน  |
//+------------------------------------------------------------------+
double GridLot(int m, int level, int priceDir, int totalCnt=0) {
   double base = (m == MAGIC_1) ? Lot1 : (m == MAGIC_2) ? Lot2 : Lot3;

   // ── MultStart gate: ถ้ายังไม่ถึง threshold → base lot ──────────
   int multStart = (m == MAGIC_1) ? MultStart1 : (m == MAGIC_2) ? MultStart2 : MultStart3;
   if(multStart > 0 && totalCnt < multStart) return NLot(base);

   double mult;
   if(m == MAGIC_1) {
      // aggressive เมื่อ price เคลื่อนสวนทาง M1 position (-gM1Dir)
      bool against1 = (gM1Dir != 0) ? (priceDir == -gM1Dir) : (priceDir == -1);
      mult = against1 ? LotMultDown1 : LotMultUp1;
   } else if(m == MAGIC_3) {
      // aggressive เมื่อ price เคลื่อนสวนทาง M3 position (-gM3Dir)
      bool against3 = (gM3Dir != 0) ? (priceDir == -gM3Dir) : (priceDir == +1);
      mult = against3 ? LotMultUp3 : LotMultDown3;
   } else {
      mult = LotMult2;  // M2 ใช้ multiplier เดียว
   }
   return NLot(base * MathPow(mult, (double)level));
}

//+------------------------------------------------------------------+
//| ChkGrid1 — Bidirectional RSI-directed grid (M1)                 |
//+------------------------------------------------------------------+
void ChkGrid1() {
   if(!En1) return;
   if(gTrig.active && gTrig.stoppedMagic == MAGIC_1) return;
   if(gDailyTargetHit) return;

   int cnt = Count(MAGIC_1);
   int dir = gRSI1Dir;  // +1=BUY, -1=SELL, 0=neutral zone

   // ── Direction switch: ปิดไม้ผิดทิศแล้วรอ TP ดึงไม้เสีย ─────────
   if(!gTrig.active && cnt > 0 && gM1Dir != 0 && dir != 0 && dir != gM1Dir) {
      for(int i = PositionsTotal()-1; i >= 0; i--) {
         ulong tk = PositionGetTicket(i);
         if(!PositionSelectByTicket(tk)) continue;
         if((int)PositionGetInteger(POSITION_MAGIC) != MAGIC_1) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         int pd = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         if(pd != dir) { CMWinners(MAGIC_1); return; }  // ปิดไม้กำไร, ปล่อยไม้เสียให้ TP Recovery
      }
   }

   if(dir == 0) return;  // RSI neutral zone — ไม่เปิดใหม่

   double price = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                              : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ── ไม้แรก: RSI gate ผ่านแล้ว → เริ่ม grid ───────────────────
   if(cnt == 0) {
      gCntDown1 = 0; gCntUp1 = 0;
      gM1Dir = dir;
      if(OO(MAGIC_1, dir, NLot(Lot1))) gLastM1 = price;
      return;
   }
   if(cnt >= MaxGrid1) return;
   if(gLastM1 <= 0 || MathAbs(price - gLastM1) < GS1 * _Point) return;

   // ── ไม้ต่อๆ ไป: เปิดในทิศเดิม (gM1Dir) ────────────────────────
   int priceDir = (price > gLastM1) ? +1 : -1;
   int level    = (priceDir == -1) ? gCntDown1 : gCntUp1;
   double lot   = GridLot(MAGIC_1, level, priceDir, cnt);

   if(OO(MAGIC_1, gM1Dir, lot)) {
      gLastM1 = price;
      if(priceDir == -1) gCntDown1++;
      else               gCntUp1++;
   }
}

//+------------------------------------------------------------------+
//| ChkGrid3 — Bidirectional EMA-directed grid (M3)                 |
//+------------------------------------------------------------------+
void ChkGrid3() {
   if(!En3) return;
   if(gTrig.active && gTrig.stoppedMagic == MAGIC_3) return;
   if(gDailyTargetHit) return;

   int cnt = Count(MAGIC_3);
   int dir = gEMA3Dir;  // +1=BUY (price>EMA), -1=SELL (price<EMA)

   // ── Direction switch: ปิดไม้ผิดทิศ ─────────────────────────────
   if(!gTrig.active && cnt > 0 && gM3Dir != 0 && dir != 0 && dir != gM3Dir) {
      for(int i = PositionsTotal()-1; i >= 0; i--) {
         ulong tk = PositionGetTicket(i);
         if(!PositionSelectByTicket(tk)) continue;
         if((int)PositionGetInteger(POSITION_MAGIC) != MAGIC_3) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         int pd = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         if(pd != dir) { CMWinners(MAGIC_3); return; }  // ปิดไม้กำไร, ปล่อยไม้เสียให้ TP Recovery
      }
   }

   if(dir == 0) return;  // ไม่มี signal

   double price = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                              : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ── ไม้แรก: EMA gate ผ่านแล้ว → เริ่ม grid ───────────────────
   if(cnt == 0) {
      gCntDown3 = 0; gCntUp3 = 0;
      gM3Dir = dir;
      if(OO(MAGIC_3, dir, NLot(Lot3))) gLastM3 = price;
      return;
   }
   if(cnt >= MaxGrid3) return;
   if(gLastM3 <= 0 || MathAbs(price - gLastM3) < GS3 * _Point) return;

   // ── ไม้ต่อๆ ไป: เปิดในทิศเดิม (gM3Dir) ────────────────────────
   int priceDir = (price > gLastM3) ? +1 : -1;
   int level    = (priceDir == -1) ? gCntDown3 : gCntUp3;
   double lot   = GridLot(MAGIC_3, level, priceDir, cnt);

   if(OO(MAGIC_3, gM3Dir, lot)) {
      gLastM3 = price;
      if(priceDir == -1) gCntDown3++;
      else               gCntUp3++;
   }
}

//+------------------------------------------------------------------+
//| ChkM2                                                            |
//+------------------------------------------------------------------+
void ChkM2() {
   if(!En2) return;
   if(gDailyTargetHit && !gTrig.active) return;  // allow assist mode even after daily target
   if(gTrigJustFired) return;
   // M2 lock: หยุดเปิดใหม่เมื่อ PNL โดนลาก — ยกเว้นตอน assist mode (M2 ยังช่วย M1/M3 ได้)
   if(gM2Locked && !gTrig.active) return;
   int dir = 0;
   if(gTrig.active) {
      // ช่วย magic ที่หยุดอยู่: เปิดในทิศตรงข้ามกับทิศที่ magic นั้นเปิดตอน trigger
      dir = (gTrig.stoppedDir != 0) ? -gTrig.stoppedDir
          : (gTrig.stoppedMagic == MAGIC_1) ? -1 : 1;  // fallback ถ้าไม่มี stoppedDir
   } else {
      dir = gADXDir;
   }
   if(dir == 0) return;
   // Normal mode: ปิด M2 ถ้าทิศผิด (ADX เปลี่ยน)
   // Assist mode: ห้ามปิด — M2 ออกตาม TP ของ magic ที่ช่วยเท่านั้น
   if(!gTrig.active) {
      for(int i = PositionsTotal()-1; i >= 0; i--) {
         ulong tk = PositionGetTicket(i);
         if(!PositionSelectByTicket(tk)) continue;
         if((int)PositionGetInteger(POSITION_MAGIC) != MAGIC_2) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         int pd = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         if(pd != dir) { CMWinners(MAGIC_2); return; }  // ไม้เสียปล่อยไว้ให้ TP Recovery
      }
   }
   int cnt = Count(MAGIC_2);
   if(cnt >= MaxGrid2) return;
   // M2 ใช้ GridLot แบบ neutral (priceDir=0 → ใช้ LotMult2)
   OO(MAGIC_2, dir, GridLot(MAGIC_2, cnt, 0 /*M2: no directional bias*/, cnt));
}

//+------------------------------------------------------------------+
//| Loss Trigger                                                     |
//+------------------------------------------------------------------+
void ChkTrigger() {
   if(!gTrig.active) {
      if(TimeCurrent() < gTrigCoolEnd) return;
      double worst = 0;
      int    worstM = 0;
      if(En1 && Count(MAGIC_1) > 0) {
         double p = PNL(MAGIC_1);
         if(p <= -LossTrig1 && p < worst) { worst = p; worstM = MAGIC_1; }
      }
      if(En3 && Count(MAGIC_3) > 0) {
         double p = PNL(MAGIC_3);
         if(p <= -LossTrig3 && p < worst) { worst = p; worstM = MAGIC_3; }
      }
      if(worstM == MAGIC_1) {
         gTrig.active = true; gTrig.stoppedMagic = MAGIC_1;
         gTrig.stoppedDir = gM1Dir;  // บันทึกทิศทางของ M1 ตอน trigger
         gTrig.trigPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         PrintFormat("[Trigger] M1 PNL=%.2f dir=%+d trig=%.5f", worst, gM1Dir, gTrig.trigPrice);
         GlobalVariableSet("HP_TrigActive_"  + _Symbol, 1.0);
         GlobalVariableSet("HP_TrigMagic_"   + _Symbol, (double)gTrig.stoppedMagic);
         GlobalVariableSet("HP_TrigPrice_"   + _Symbol, gTrig.trigPrice);
         gTrigJustFired = true;
      } else if(worstM == MAGIC_3) {
         gTrig.active = true; gTrig.stoppedMagic = MAGIC_3;
         gTrig.stoppedDir = gM3Dir;  // บันทึกทิศทางของ M3 ตอน trigger
         gTrig.trigPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         PrintFormat("[Trigger] M3 PNL=%.2f dir=%+d trig=%.5f", worst, gM3Dir, gTrig.trigPrice);
         GlobalVariableSet("HP_TrigActive_"  + _Symbol, 1.0);
         GlobalVariableSet("HP_TrigMagic_"   + _Symbol, (double)gTrig.stoppedMagic);
         GlobalVariableSet("HP_TrigPrice_"   + _Symbol, gTrig.trigPrice);
         gTrigJustFired = true;
      }
   } else {
      double curPnl  = PNL(gTrig.stoppedMagic);
      int    switchM = 0;
      double switchP = curPnl;
      if(En1 && gTrig.stoppedMagic != MAGIC_1 && Count(MAGIC_1) > 0) {
         double p = PNL(MAGIC_1);
         if(p < switchP) { switchP = p; switchM = MAGIC_1; }
      }
      if(En3 && gTrig.stoppedMagic != MAGIC_3 && Count(MAGIC_3) > 0) {
         double p = PNL(MAGIC_3);
         if(p < switchP) { switchP = p; switchM = MAGIC_3; }
      }
      if(switchM != 0) {
         PrintFormat("[Trigger] Switch → M%d(%.2f)", switchM == MAGIC_1 ? 1 : 3, switchP);
         gTrig.stoppedMagic = switchM;
         gTrig.trigPrice    = (switchM == MAGIC_1)
             ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
             : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         GlobalVariableSet("HP_TrigActive_"  + _Symbol, 1.0);
         GlobalVariableSet("HP_TrigMagic_"   + _Symbol, (double)gTrig.stoppedMagic);
         GlobalVariableSet("HP_TrigPrice_"   + _Symbol, gTrig.trigPrice);
         gTrigJustFired     = true;
         return;
      }
      int    lCount = CountLosers(gTrig.stoppedMagic);
      double pnl    = PNL(gTrig.stoppedMagic);
      if(lCount == 0 && pnl >= 0) {
         PrintFormat("[Trigger] M%d RECOVERED — unlocking", gTrig.stoppedMagic == MAGIC_1 ? 1 : 3);
         if(gTrig.stoppedMagic == MAGIC_1) { gLastM1 = SymbolInfoDouble(_Symbol, SYMBOL_ASK); gM1Dir = 0; }
         else                              { gLastM3 = SymbolInfoDouble(_Symbol, SYMBOL_BID); gM3Dir = 0; }
         // reset directional counters เพื่อหลีกเลี่ยง lot sizing ผิดพลาดหลัง recovery
         gCntDown1 = 0; gCntUp1 = 0; gCntDown3 = 0; gCntUp3 = 0;
         gTrig.active = false; gTrig.stoppedMagic = 0; gTrig.trigPrice = 0.0;
         GlobalVariableSet("HP_TrigActive_"  + _Symbol, 0.0);
         GlobalVariableSet("HP_TrigMagic_"   + _Symbol, 0.0);
         GlobalVariableSet("HP_TrigPrice_"   + _Symbol, 0.0);
         gTrigCoolEnd = TimeCurrent() + TrigCoolSec;
         GlobalVariableSet("HP_TrigCoolEnd_" + _Symbol, (double)gTrigCoolEnd);
         // ไม่ set gTrigJustFired ตอน deactivate — M2 ควรเปิดได้ทันทีหลัง recovery
      }
   }

   // ── M2 Loss Lock — ป้องกัน M2 โดนลากเมื่อ PNL ติดลบถึงกำหนด ──────
   if(LossTrig2 > 0 && En2) {
      if(!gM2Locked) {
         if(TimeCurrent() >= gM2CoolEnd && Count(MAGIC_2) > 0) {
            if(PNL(MAGIC_2) <= -LossTrig2) {
               gM2Locked = true;
               PrintFormat("[Trigger] M2 LOCKED PNL=%.2f (trig=%.2f)", PNL(MAGIC_2), LossTrig2);
               GlobalVariableSet("HP_M2Locked_" + _Symbol, 1.0);
            }
         }
      } else {
         // Unlock: ไม่มีไม้เสีย AND pnl กลับมา >= 0
         if(CountLosers(MAGIC_2) == 0 && PNL(MAGIC_2) >= 0) {
            gM2Locked  = false;
            gM2CoolEnd = TimeCurrent() + TrigCoolSec;
            PrintFormat("[Trigger] M2 UNLOCKED — cooldown %ds", TrigCoolSec);
            GlobalVariableSet("HP_M2Locked_"  + _Symbol, 0.0);
            GlobalVariableSet("HP_M2CoolEnd_" + _Symbol, (double)gM2CoolEnd);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Panel helpers                                                    |
//+------------------------------------------------------------------+
int GetPanelX() {
   int cw     = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int totalW = ShowCal ? PW_TOTAL : PW_OUT;
   return MathMax(5, cw - PanelX - totalW);
}

double TotalLot(int m) {
   double v = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      v += PositionGetDouble(POSITION_VOLUME);
   }
   return v;
}

//+------------------------------------------------------------------+
//| Panel primitives                                                 |
//+------------------------------------------------------------------+
void Rect(string n, int x, int y, int w, int h, color bg, color brd) {
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);        ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);     ObjectSetInteger(0, n, OBJPROP_COLOR, brd);
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, n, OBJPROP_BACK, false);     ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void Lbl(string n, int x, int y, string t, color c, int fs, string font="Arial Bold") {
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetString (0, n, OBJPROP_TEXT, t);         ObjectSetString (0, n, OBJPROP_FONT, font);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, fs);    ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_BACK, false);     ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void DeletePanel() { ObjectsDeleteAll(0, PFX); }

color PnlClr(double v) {
   if(v >  0.005) return CL_POS;
   if(v < -0.005) return CL_NEG;
   return CL_NEU;
}

string TFStr(ENUM_TIMEFRAMES tf) {
   switch(tf) {
      case PERIOD_M1:  return "M1";  case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15"; case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";  case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";  case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";  default:          return "";
   }
}

void Bar(string id, int x, int y, int totalW, int h, int cnt, int maxCnt, color acClr) {
   Rect(PFX+id+"_BG", x, y, totalW, h, CB_BAR_BG, CB_BAR_BG);
   int fw = (maxCnt > 0 && cnt > 0)
            ? MathMax(2, MathMin(totalW, (int)MathRound((double)cnt/maxCnt*totalW))) : 0;
   Rect(PFX+id+"_FG", x, y, (fw>0?fw:1), h, (fw>0?acClr:CB_BAR_BG), (fw>0?acClr:CB_BAR_BG));
}

void DrawMagicSec(string id, int xi, int sy,
                  color acClr, color bgClr,
                  string tag, string statusTxt, color statusClr,
                  int cnt, int maxCnt,
                  int runCnt, int runMax,
                  double pnl, double openLot,
                  double cgp, int losers, double sepTarget) {
   Rect(PFX+id+"_BG",  xi,   sy, PW_IN,   MSEC_H, bgClr, bgClr);
   Rect(PFX+id+"_ACC", xi,   sy, 5,       MSEC_H, acClr, acClr);
   Rect(PFX+id+"_HI",  xi+5, sy, PW_IN-5, 1,      C'20,28,52', C'20,28,52');
   int r1 = sy+8;
   Lbl(PFX+id+"_TAG", xi+13,  r1, tag,       acClr,     FN);
   Lbl(PFX+id+"_STA", xi+37,  r1, statusTxt, statusClr, FN);
   string runTxt = StringFormat("★%d/%d", runCnt, runMax);
   color  runClr = (runCnt >= runMax) ? CL_GOLD : (runCnt > 0 ? C'200,170,60' : CL_INFO);
   Lbl(PFX+id+"_RUN", xi+128, r1, runTxt, runClr, FS, "Arial");
   Bar(id, xi+172, r1+1, 96, 8, cnt, maxCnt, acClr);
   Lbl(PFX+id+"_CNT", xi+274, r1, StringFormat("%d/%d", cnt, maxCnt), CL_INFO, FS, "Courier New");
   int r2 = sy+28;
   Lbl(PFX+id+"_PL",  xi+13,  r2, "PNL",                            CL_INFO,     FS,  "Arial");
   Lbl(PFX+id+"_PV",  xi+37,  r2, StringFormat("%+.2f $", pnl),      PnlClr(pnl), FN);
   Lbl(PFX+id+"_LL",  xi+160, r2, "Open",                           CL_INFO,     FXS, "Arial");
   Lbl(PFX+id+"_LV",  xi+193, r2, StringFormat("%.2f lot", openLot), CL_CYAN,     FN);
   int r3 = sy+47;
   double tgt    = (sepTarget > 0) ? sepTarget : 1.0;
   double ratio  = cgp / tgt;
   color cgpClr  = (cgp >= tgt) ? CL_POS : (ratio >= 0.7) ? C'220,185,40' : (cgp > 0) ? CL_NEU : CL_INFO;
   color lsClr   = (losers > 5) ? CL_NEG : (losers > 0) ? C'220,100,100' : CL_NEU;
   Lbl(PFX+id+"_GL",  xi+13,  r3, "CGP",                            CL_INFO,  FXS, "Arial");
   Lbl(PFX+id+"_GV",  xi+37,  r3, StringFormat("%+.2f", cgp),        cgpClr,   FN);
   Lbl(PFX+id+"_LsL", xi+160, r3, "Lose",                           CL_INFO,  FXS, "Arial");
   Lbl(PFX+id+"_LsV", xi+193, r3, StringFormat("%d pos", losers),    lsClr,    FN);
}

void DrawM2Row(int xi, int sy, string modeTxt, color modeClr,
               int cnt, int maxCnt, double pnl, double cgp) {
   Rect(PFX+"M2_BG",  xi,   sy, PW_IN,   M2R_H, CB_M2, CB_M2);
   Rect(PFX+"M2_ACC", xi,   sy, 5,       M2R_H, CA_M2, CA_M2);
   Rect(PFX+"M2_HI",  xi+5, sy, PW_IN-5, 1,     C'20,28,52', C'20,28,52');
   int r1 = sy+8;
   Lbl(PFX+"M2_TAG", xi+13,  r1, "M2",                               CA_M2,       FN);
   Lbl(PFX+"M2_MOD", xi+37,  r1, modeTxt,                            modeClr,     FN);
   Lbl(PFX+"M2_CNT", xi+243, r1, StringFormat("%d/%d", cnt, maxCnt), CL_INFO,     FS, "Courier New");
   int r2 = sy+24;
   Lbl(PFX+"M2_PL",  xi+13,  r2, "PNL",                             CL_INFO,     FXS, "Arial");
   Lbl(PFX+"M2_PV",  xi+37,  r2, StringFormat("%+.2f $", pnl),       PnlClr(pnl), FN);
   double tgt2 = (TP2 > 0) ? TP2 : 1.0;
   color cgp2Cl = (cgp >= tgt2) ? CL_POS : (cgp >= tgt2*0.7) ? C'220,185,40' : (cgp > 0) ? CL_NEU : CL_INFO;
   Lbl(PFX+"M2_GL",  xi+160, r2, "CGP",                             CL_INFO,     FXS, "Arial");
   Lbl(PFX+"M2_GV",  xi+193, r2, StringFormat("%+.2f", cgp),         cgp2Cl,      FN);
}

void DrawTrigBanner(int xi, int sy, int bw) {
   string line1, line2;
   color  bgClr, txtClr1, txtClr2;
   if(gTrig.active) {
      int stoppedNum = (gTrig.stoppedMagic == MAGIC_1) ? 1 : 3;
      string helpDir = (gTrig.stoppedMagic == MAGIC_1) ? "SELL" : "BUY";
      line1  = StringFormat("⛔  M%d STOPPED  |  M2 → %s assist", stoppedNum, helpDir);
      line2  = StringFormat("Trigger price: %s",
                  DoubleToString(gTrig.trigPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
      bgClr = C'40,10,12'; txtClr1 = CL_NEG; txtClr2 = C'200,120,120';
   } else if(TimeCurrent() < gTrigCoolEnd) {
      int sec = (int)(gTrigCoolEnd - TimeCurrent());
      line1  = StringFormat("◷  COOLDOWN  %d sec", sec);
      line2  = "Monitoring for re-arm...";
      bgClr = C'38,30,8'; txtClr1 = C'255,185,50'; txtClr2 = C'180,140,60';
   } else {
      line1  = "✔   NORMAL MODE  —  ALL RUNNING";
      line2  = "M1 ↕ BUY grid  |  M3 ↕ SELL grid  |  M2 ADX";
      bgClr = C'8,28,18'; txtClr1 = CL_POS; txtClr2 = C'60,140,90';
   }
   color lbClr = gTrig.active ? CL_NEG : (TimeCurrent()<gTrigCoolEnd) ? C'255,185,50' : CL_POS;
   Rect(PFX+"TRIG_BG", xi, sy, bw, TRIG_H, bgClr, bgClr);
   Rect(PFX+"TRIG_LB", xi, sy, 4,  TRIG_H, lbClr, lbClr);
   Lbl(PFX+"TRIG_L1", xi+10, sy+5,  line1, txtClr1, FN);
   Lbl(PFX+"TRIG_L2", xi+10, sy+20, line2, txtClr2, FXS, "Arial");
}

void DrawAcctSection(int xi, int sy, double bal, double equity, double pnl, double lday) {
   Rect(PFX+"ACC_BG",  xi,   sy, PW_IN,   ACCT_H, C'10,13,26', C'10,13,26');
   Rect(PFX+"ACC_TOP", xi,   sy, PW_IN,   2,      C'35,60,150', C'35,60,150');
   Rect(PFX+"ACC_LB",  xi,   sy, 5,       ACCT_H, C'35,60,150', C'35,60,150');
   Rect(PFX+"ACC_DIV", xi+156, sy+4, 1, ACCT_H-8, C'22,30,56', C'22,30,56');
   int cl = xi+13, cr = xi+165;
   int r1 = sy+9, r2 = sy+26;
   Lbl(PFX+"BAL_L",  cl,    r1, "BAL",   CL_INFO,   FS, "Arial");
   Lbl(PFX+"BAL_V",  cl+30, r1, StringFormat("$%.2f", bal),    CL_BRIGHT, FN);
   Lbl(PFX+"EQA_L",  cr,    r1, "EQ",    CL_INFO,   FS, "Arial");
   Lbl(PFX+"EQA_V",  cr+22, r1, StringFormat("$%.2f", equity), CL_BRIGHT, FN);
   Lbl(PFX+"PLA_L",  cl,    r2, "P&L",   CL_INFO,      FS, "Arial");
   Lbl(PFX+"PLA_V",  cl+30, r2, StringFormat("%+.2f $", pnl), PnlClr(pnl), FN);
   Lbl(PFX+"LDA_L",  cr,    r2, "Lot/D", CL_INFO,   FS, "Arial");
   Lbl(PFX+"LDA_V",  cr+40, r2, StringFormat("%.2f", lday), CL_CYAN, FN);
}

void DrawDDSection(int xi, int sy, double ddPct, double maxDDPct) {
   Rect(PFX+"DD_BG",  xi, sy, PW_IN, DD_H, C'9,11,23',   C'9,11,23');
   Rect(PFX+"DD_TOP", xi, sy, PW_IN, 1,    CB_SEP,        CB_SEP);
   Rect(PFX+"DD_LB",  xi, sy, 5,    DD_H,  C'120,40,40',  C'120,40,40');
   color ddClr  = (ddPct  >= 10.0) ? CL_NEG : (ddPct  >= 5.0) ? C'220,160,40' : CL_NEU;
   color maxClr = (maxDDPct >= 15.0) ? CL_NEG : (maxDDPct >= 8.0) ? C'220,160,40' : CL_NEU;
   int cl = xi+13, cr = xi+165;
   int ry = sy + 9;
   Lbl(PFX+"DD_L",  cl,    ry, "DD",    CL_INFO, FS, "Arial");
   Lbl(PFX+"DD_V",  cl+25, ry, StringFormat("-%.2f%%", ddPct),    ddClr,  FN);
   Lbl(PFX+"MDD_L", cr,    ry, "MaxDD", CL_INFO, FS, "Arial");
   Lbl(PFX+"MDD_V", cr+40, ry, StringFormat("-%.2f%%", maxDDPct), maxClr, FN);
}

void DrawTPStatus(int xi, int sy,
                  bool useTot,  double totCGP,  double totTgt,
                  bool usePair, string pairLbl, double pairCGP, double pairTgt) {
   Rect(PFX+"TP_BG",  xi, sy, PW_IN, TPST_H, C'8,10,20', C'8,10,20');
   Rect(PFX+"TP_TOP", xi, sy, PW_IN, 1,      CB_SEP_HI, CB_SEP_HI);
   Rect(PFX+"TP_LB",  xi, sy, 5, TPST_H,    C'45,75,165', C'45,75,165');
   int cl = xi+13, bx = xi+75, bw = 122, vx = xi+206;
   int r1 = sy+10, r2 = sy+28;
   if(useTot) {
      double pct  = (totTgt > 0) ? MathMin(1.0, MathMax(0.0, totCGP/totTgt)) : 0;
      color  vClr = (totCGP >= totTgt) ? CL_POS : (pct >= 0.7) ? C'220,190,40' : CL_NEU;
      Lbl(PFX+"TP1_L", cl, r1, "TOT", CL_INFO, FS, "Arial");
      Bar("TP_TOT", bx, r1+1, bw, 7, (int)MathRound(pct*100), 100, CA_M1);
      Lbl(PFX+"TP1_V", vx, r1, StringFormat("%.2f / %.2f", totCGP, totTgt), vClr, FS, "Courier New");
   } else {
      Lbl(PFX+"TP1_L", cl, r1, "TOT  ──  OFF", C'45,55,82', FS, "Arial");
      Bar("TP_TOT", bx, r1+1, bw, 7, 0, 100, CA_M1);
      Lbl(PFX+"TP1_V", vx, r1, "──", C'45,55,82', FS, "Courier New");
   }
   if(usePair) {
      double pct  = (pairTgt > 0) ? MathMin(1.0, MathMax(0.0, pairCGP/pairTgt)) : 0;
      color  vClr = (pairCGP >= pairTgt) ? CL_POS : (pct >= 0.7) ? C'220,190,40' : CL_NEU;
      Lbl(PFX+"TP2_L", cl, r2, pairLbl, CL_INFO, FS, "Arial");
      Bar("TP_PAIR", bx, r2+1, bw, 7, (int)MathRound(pct*100), 100, CA_M2);
      Lbl(PFX+"TP2_V", vx, r2, StringFormat("%.2f / %.2f", pairCGP, pairTgt), vClr, FS, "Courier New");
   } else {
      Lbl(PFX+"TP2_L", cl, r2, "PAIR  ──  OFF", C'45,55,82', FS, "Arial");
      Bar("TP_PAIR", bx, r2+1, bw, 7, 0, 100, CA_M2);
      Lbl(PFX+"TP2_V", vx, r2, "──", C'45,55,82', FS, "Courier New");
   }
}

//+------------------------------------------------------------------+
//| Calendar panel                                                   |
//+------------------------------------------------------------------+
void BuildCalendarData() {
   MqlDateTime mdt; TimeToStruct(TimeCurrent(), mdt);
   int curYear=mdt.year, curMon=mdt.mon, curDay=mdt.day;
   MqlDateTime m1; m1.year=curYear; m1.mon=curMon; m1.day=1;
   m1.hour=0; m1.min=0; m1.sec=0; m1.day_of_week=0; m1.day_of_year=0;
   datetime monthStart = StructToTime(m1);
   int ny=curYear, nm=curMon+1; if(nm>12){nm=1;ny++;}
   MqlDateTime m2; m2.year=ny; m2.mon=nm; m2.day=1;
   m2.hour=0; m2.min=0; m2.sec=0; m2.day_of_week=0; m2.day_of_year=0;
   datetime monthEnd = StructToTime(m2);
   ArrayInitialize(gCalPnl, 0.0); ArrayInitialize(gCalLot, 0.0);
   if(!HistorySelect(monthStart, monthEnd)) { gCalBuildTime=TimeCurrent(); gCalDirty=false; return; }
   for(int i = 0; i < HistoryDealsTotal(); i++) {
      ulong deal = HistoryDealGetTicket(i);
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      datetime dt_d = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      MqlDateTime dd; TimeToStruct(dt_d, dd);
      int idx = dd.day - 1;
      if(idx < 0 || idx > 30) continue;
      int entry = (int)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
         gCalPnl[idx] += HistoryDealGetDouble(deal, DEAL_PROFIT)
                       + HistoryDealGetDouble(deal, DEAL_SWAP)
                       + HistoryDealGetDouble(deal, DEAL_COMMISSION);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
         if(dd.day != curDay) gCalLot[idx] += HistoryDealGetDouble(deal, DEAL_VOLUME);
   }
   gCalBuildTime = TimeCurrent(); gCalDirty = false;
}

void DeleteCalendar() { ObjectsDeleteAll(0, PFX2); }

void ShowCalPanel() {
   static bool wasCal = false;
   if(!ShowCal) { if(wasCal) { DeleteCalendar(); wasCal=false; } return; }
   static bool cleanedUp = false;
   if(!cleanedUp) { ObjectDelete(0, PFX2+"BDR"); ObjectDelete(0, PFX2+"BG"); cleanedUp=true; }
   wasCal = true;
   if(gCalDirty || (TimeCurrent() - gCalBuildTime > 30)) BuildCalendarData();
   int px = GetPanelX();
   int py = PanelY;
   int xi = px + PW_OUT + 3;
   int iw = PW_CAL - 6;
   MqlDateTime mdt; TimeToStruct(TimeCurrent(), mdt);
   int curYear=mdt.year, curMon=mdt.mon, curDay=mdt.day;
   int ny=curYear, nm=curMon+1; if(nm>12){nm=1;ny++;}
   MqlDateTime m1,m2;
   m1.year=curYear;m1.mon=curMon;m1.day=1;m1.hour=0;m1.min=0;m1.sec=0;m1.day_of_week=0;m1.day_of_year=0;
   m2.year=ny;m2.mon=nm;m2.day=1;m2.hour=0;m2.min=0;m2.sec=0;m2.day_of_week=0;m2.day_of_year=0;
   int daysInMonth = (int)((StructToTime(m2) - StructToTime(m1)) / 86400);
   MqlDateTime fdow; TimeToStruct(StructToTime(m1), fdow);
   int dow1 = (fdow.day_of_week == 0) ? 6 : fdow.day_of_week - 1;
   int hy = py+3;
   Rect(PFX2+"H_BG",  xi, hy, iw, CHDR_H, CB_HDR, CB_HDR);
   Rect(PFX2+"H_TOP", xi, hy, iw, 2, C'60,100,200', C'60,100,200');
   Rect(PFX2+"H_LN",  xi, hy+CHDR_H, iw, 2, CB_HDR_LN, CB_HDR_LN);
   string mNames[]={"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"};
   Lbl(PFX2+"H_TXT", xi+10, hy+8, StringFormat("MONTHLY P&L   %s %d", mNames[curMon-1], curYear), CL_GOLD, FH);
   int dowy = hy + CHDR_H + 2;
   Rect(PFX2+"DOW_BG", xi, dowy, iw, CDOW_H, C'14,18,38', C'14,18,38');
   string dowLbls[]={"Mon","Tue","Wed","Thu","Fri","Sat","Sun"};
   for(int c=0; c<7; c++) {
      color dc = (c>=5) ? C'90,65,120' : C'60,80,120';
      Lbl(PFX2+"DW"+IntegerToString(c), xi+c*CDAY_W+18, dowy+4, dowLbls[c], dc, FS, "Arial");
   }
   int gridH = CDOW_H + 6*CDAY_H;
   for(int c=1; c<7; c++)
      Rect(PFX2+"VL"+IntegerToString(c), xi+c*CDAY_W, dowy, 1, gridH, C'18,24,44', C'18,24,44');
   int cellY0 = dowy + CDOW_H;
   for(int row=0; row<6; row++) {
      int cy0 = cellY0 + row*CDAY_H;
      Rect(PFX2+"HL"+IntegerToString(row), xi, cy0, iw, 1, C'18,24,44', C'18,24,44');
      for(int col=0; col<7; col++) {
         int day = row*7 + col - dow1 + 1;
         string cid = IntegerToString(row)+"_"+IntegerToString(col);
         int cx = xi + col*CDAY_W + 1;
         int cy = cy0 + 1;
         int cw2 = CDAY_W - 1, ch = CDAY_H - 1;
         if(day < 1 || day > daysInMonth) {
            Rect(PFX2+"CB"+cid, cx, cy, cw2, ch, C'7,9,18', C'7,9,18');
            Lbl(PFX2+"CD"+cid, cx, cy, " ", C'7,9,18', FXS);
            Lbl(PFX2+"CP"+cid, cx, cy, " ", C'7,9,18', FS);
            Lbl(PFX2+"CL"+cid, cx, cy, " ", C'7,9,18', FXS);
            continue;
         }
         bool isToday   = (day == curDay);
         bool isWeekend = (col >= 5);
         double dpnl = gCalPnl[day-1];
         double dlot = gCalLot[day-1];
         if(isToday) { dpnl += PNL(MAGIC_1)+PNL(MAGIC_2)+PNL(MAGIC_3); dlot = gDailyLot1+gDailyLot2+gDailyLot3; }
         bool hasData = (dlot > 0.0 || MathAbs(dpnl) > 0.001);
         color cbg = isToday ? C'18,25,52' : (isWeekend ? C'10,10,22' : C'10,13,26');
         Rect(PFX2+"CB"+cid, cx, cy, cw2, ch, cbg, cbg);
         if(isToday) Rect(PFX2+"CTD"+cid, cx, cy, cw2, 2, C'55,95,200', C'55,95,200');
         color dnClr = isToday ? CL_BRIGHT : (isWeekend ? C'75,60,105' : C'50,65,95');
         Lbl(PFX2+"CD"+cid, cx+3, cy+2, IntegerToString(day), dnClr, FXS, "Arial");
         string pTxt; color pClr;
         if(!hasData) { pTxt="--"; pClr=C'28,36,60'; }
         else { pTxt=StringFormat("%+.2f",dpnl); pClr=(dpnl>0.01)?CL_POS:(dpnl<-0.01)?CL_NEG:CL_NEU; }
         Lbl(PFX2+"CP"+cid, cx+3, cy+14, pTxt, pClr, FS);
         string lTxt = (dlot > 0.0) ? StringFormat("%.2fL", dlot) : "";
         Lbl(PFX2+"CL"+cid, cx+3, cy+26, lTxt, CL_CYAN, FXS, "Arial");
      }
   }
   int ftY = cellY0 + 6*CDAY_H + 1;
   Rect(PFX2+"FT_BG", xi, ftY, iw, CFTR_H, C'12,15,30', C'12,15,30');
   Rect(PFX2+"FT_LN", xi, ftY, iw, 1,      CB_SEP_HI,   CB_SEP_HI);
   double mthPnl=0, mthLot=0;
   for(int d=0;d<daysInMonth;d++) mthPnl+=gCalPnl[d];
   for(int d=0;d<daysInMonth;d++) mthLot+=gCalLot[d];
   mthPnl += PNL(MAGIC_1)+PNL(MAGIC_2)+PNL(MAGIC_3);
   mthLot += gDailyLot1+gDailyLot2+gDailyLot3;
   color mClr = (mthPnl>0.01)?CL_POS:(mthPnl<-0.01)?CL_NEG:CL_NEU;
   Lbl(PFX2+"FT_L",  xi+10,  ftY+6, "MTH",                       CL_INFO, FS, "Arial");
   Lbl(PFX2+"FT_P",  xi+45,  ftY+6, StringFormat("%+.2f",mthPnl), mClr,   FN);
   Lbl(PFX2+"FT_LL", xi+210, ftY+6, "Lot",                        CL_INFO, FS, "Arial");
   Lbl(PFX2+"FT_LV", xi+240, ftY+6, StringFormat("%.2f",mthLot),  CL_CYAN, FN);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void ShowDashboard() {
   if(!ShowPanel) return;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) return;
   int px = GetPanelX();
   int py = PanelY;
   int xi = px + 3;
   double p1=PNL(MAGIC_1), p2=PNL(MAGIC_2), p3=PNL(MAGIC_3);
   int    c1=Count(MAGIC_1), c2=Count(MAGIC_2), c3=Count(MAGIC_3);
   double l1=TotalLot(MAGIC_1), l2=TotalLot(MAGIC_2), l3=TotalLot(MAGIC_3);
   double cgp1=GetCloseableGP(MAGIC_1,GetBestTk(MAGIC_1));
   double cgp2=GetCloseableGP(MAGIC_2,GetBestTk(MAGIC_2));
   double cgp3=GetCloseableGP(MAGIC_3,GetBestTk(MAGIC_3));
   int    los1=CountLosers(MAGIC_1), los2=CountLosers(MAGIC_2), los3=CountLosers(MAGIC_3);
   double lDay=gDailyLot1+gDailyLot2+gDailyLot3;
   double tot=p1+p2+p3;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   int    spd=(int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   bool   m1stopped=(gTrig.active && gTrig.stoppedMagic==MAGIC_1);
   string m1sta; color m1clr;
   if(m1stopped)       { m1sta="⛔ STOP";                  m1clr=CL_NEG; }
   else if(gM1Dir==+1) { m1sta="▲ BUY  (RSI<"+IntegerToString((int)RSI1Lvl)+")"; m1clr=CL_POS; }
   else if(gM1Dir==-1) { m1sta="▼ SELL (RSI>"+IntegerToString((int)RSI1SellLvl)+")"; m1clr=CL_NEG; }
   else                { m1sta="■ WAIT (RSI neutral)";     m1clr=CL_NEU; }
   bool   m3stopped=(gTrig.active && gTrig.stoppedMagic==MAGIC_3);
   string m3sta; color m3clr;
   if(m3stopped)       { m3sta="⛔ STOP";                  m3clr=CL_NEG; }
   else if(gM3Dir==+1) { m3sta="▲ BUY  (>EMA"+IntegerToString(EMA3Per)+")"; m3clr=CL_POS; }
   else if(gM3Dir==-1) { m3sta="▼ SELL (<EMA"+IntegerToString(EMA3Per)+")"; m3clr=CL_NEG; }
   else                { m3sta="■ WAIT (no EMA signal)";   m3clr=CL_NEU; }
   string m2mod; color m2mClr;
   if(gTrig.active) {
      if(gTrig.stoppedMagic==MAGIC_1){m2mod="▼ SELL  ← assist M1";m2mClr=C'255,130,130';}
      else                            {m2mod="▲ BUY   ← assist M3";m2mClr=C'130,200,255';}
   } else if(gM2Locked) {
      m2mod="⛔ LOCKED (loss trig)"; m2mClr=CL_NEG;
   } else if(TimeCurrent() < gM2CoolEnd) {
      m2mod=StringFormat("◷ COOL %ds",(int)(gM2CoolEnd-TimeCurrent())); m2mClr=C'255,185,50';
   } else if(gADXDir== 1){m2mod="▲ BUY   (ADX trend)";m2mClr=C'130,200,255';}
   else if(gADXDir==-1)  {m2mod="▼ SELL  (ADX trend)";m2mClr=C'255,130,130';}
   else                  {m2mod="■ IDLE  (ADX flat)"; m2mClr=CL_NEU;}
   double pCGP[3];
   pCGP[0]=cgp1+cgp2; pCGP[1]=cgp1+cgp3; pCGP[2]=cgp2+cgp3;
   string pLbl[3]; pLbl[0]="M1+M2"; pLbl[1]="M1+M3"; pLbl[2]="M2+M3";
   int bestPi=0;
   if(pCGP[1]>pCGP[bestPi]) bestPi=1;
   if(pCGP[2]>pCGP[bestPi]) bestPi=2;
   string bestPairLbl="PAIR "+pLbl[bestPi];
   double bestPairCGP=pCGP[bestPi];
   double totCGP=cgp1+cgp2+cgp3;
   int PH=3+HDR_H+2+ACCT_H+1+DD_H+1+TRIG_H+1+MSEC_H+1+M2R_H+1+MSEC_H+2+TPST_H+2+STAT_H+3;
   int totalPW=ShowCal?PW_TOTAL:PW_OUT;
   Rect(PFX+"BORDER",px,py,totalPW,PH,CB_BORDER,CB_BORDER);
   Rect(PFX+"BG",xi,py+3,PW_IN,PH-6,CB_BG,CB_BG);
   if(ShowCal) {
      int xr=px+PW_OUT+3; int iwr=PW_CAL-6;
      Rect(PFX+"RBDR",px+PW_OUT-1,py+3,2,PH-6,C'35,46,80',C'35,46,80');
      Rect(PFX+"RBG",xr,py+3,iwr,PH-6,CB_BG,CB_BG);
   }
   int hy=py+3;
   Rect(PFX+"H_BG",  xi,    hy,      PW_IN,HDR_H,CB_HDR,CB_HDR);
   Rect(PFX+"H_TOP", xi,    hy,      PW_IN,2,C'60,100,200',C'60,100,200');
   Rect(PFX+"H_LINE",xi,    hy+HDR_H,PW_IN,2,CB_HDR_LN,CB_HDR_LN);
   Lbl(PFX+"H_TXT",  xi+12, hy+8, "⚡  HYBRID PRO  V"+EA_VER, CL_GOLD, FH);
   Lbl(PFX+"H_STF",  xi+235,hy+10,_Symbol+" · "+TFStr(_Period),C'100,125,170',FS,"Arial");
   int aY=hy+HDR_H+2;
   DrawAcctSection(xi,aY,bal,equity,tot,lDay);
   Rect(PFX+"SEP_A",xi,aY+ACCT_H,PW_IN,1,CB_SEP,CB_SEP);
   double ddPct=(gPeakEquity>0)?(gPeakEquity-equity)/gPeakEquity*100.0:0.0;
   int ddY=aY+ACCT_H+1;
   DrawDDSection(xi,ddY,ddPct,gMaxDDPct);
   Rect(PFX+"SEP_DD",xi,ddY+DD_H,PW_IN,1,CB_SEP,CB_SEP);
   int ty=ddY+DD_H+1;
   DrawTrigBanner(xi,ty,PW_IN);
   int sep01=ty+TRIG_H;
   Rect(PFX+"SEP01",xi,sep01,PW_IN,1,CB_SEP,CB_SEP);
   int sy1=sep01+1;
   DrawMagicSec("M1",xi,sy1,CA_M1,CB_M1,"M1",m1sta,m1clr,c1,MaxGrid1,ArraySize(gBestBuyTk),BestBuyN,p1,l1,cgp1,los1,TP1);
   int s12=sy1+MSEC_H;
   Rect(PFX+"SEP12",xi,s12,PW_IN,1,CB_SEP,CB_SEP);
   int sy2=s12+1;
   DrawM2Row(xi,sy2,m2mod,m2mClr,c2,MaxGrid2,p2,cgp2);
   int s23=sy2+M2R_H;
   Rect(PFX+"SEP23",xi,s23,PW_IN,1,CB_SEP,CB_SEP);
   int sy3=s23+1;
   DrawMagicSec("M3",xi,sy3,CA_M3,CB_M3,"M3",m3sta,m3clr,c3,MaxGrid3,ArraySize(gBestSellTk),BestSellN,p3,l3,cgp3,los3,TP3);
   int sBri=sy3+MSEC_H;
   Rect(PFX+"SEPBRI",xi,sBri,PW_IN,2,CB_SEP_HI,CB_SEP_HI);
   int tpY=sBri+2;
   DrawTPStatus(xi,tpY,UseTotTP,totCGP,TPTot,UsePairTP,bestPairLbl,bestPairCGP,TPPair);
   int sBri2=tpY+TPST_H;
   Rect(PFX+"SEPBR2",xi,sBri2,PW_IN,2,CB_SEP_HI,CB_SEP_HI);
   int stY=sBri2+2;
   Rect(PFX+"ST_BG",xi,stY,PW_IN,STAT_H,CB_STAT,CB_STAT);
   Rect(PFX+"ST_HI",xi,stY,PW_IN,1,CB_SEP_HI,CB_SEP_HI);
   string adxTxt; color adxClr;
   if(!UseADX||hADX==INVALID_HANDLE){adxTxt="ADX  OFF";adxClr=C'70,80,110';}
   else if(gADXDir== 1){adxTxt="ADX  ▲ UP";adxClr=CL_POS;}
   else if(gADXDir==-1){adxTxt="ADX  ▼ DN";adxClr=CL_NEG;}
   else                {adxTxt="ADX  ▬ --";adxClr=CL_NEU;}
   color spdClr=(spd>MaxSpread)?CL_NEG:CL_NEU;
   int sr=stY+9;
   Lbl(PFX+"ADX_V",xi+13, sr,adxTxt,adxClr,FN);
   Lbl(PFX+"SP_L", xi+110,sr,"Spread",CL_INFO,FS,"Arial");
   Lbl(PFX+"SP_V", xi+158,sr,StringFormat("%d pt",spd),spdClr,FN);
   int dr=stY+27;
   if(DailyProfitTarget > 0) {
      string dayTxt;
      color  dayClr;
      if(gDailyTargetHit) {
         dayTxt = StringFormat("Daily P&L  %+.2f / %.2f  [TARGET HIT]", gTodayProfit, DailyProfitTarget);
         dayClr = CL_POS;
      } else {
         dayTxt = StringFormat("Daily P&L  %+.2f / %.2f", gTodayProfit, DailyProfitTarget);
         dayClr = (gTodayProfit < 0) ? CL_NEG : CL_NEU;
      }
      Lbl(PFX+"DAY_V",xi+13,dr,dayTxt,dayClr,FN);
   }
   // ── Row 3: M1 RSI + M3 EMA status ──────────────────────────────
   int ir = stY + 45;
   if(UseRSI1 && hRSI1 != INVALID_HANDLE) {
      double rBuf[]; ArraySetAsSeries(rBuf,true);
      string rsiTxt; color rsiClr;
      if(CopyBuffer(hRSI1,0,1,1,rBuf)>0) {
         if(gRSI1Dir==+1) { rsiTxt=StringFormat("RSI1:%.1f ▲BUY", rBuf[0]); rsiClr=CL_POS; }
         else if(gRSI1Dir==-1){ rsiTxt=StringFormat("RSI1:%.1f ▼SELL",rBuf[0]); rsiClr=CL_NEG; }
         else              { rsiTxt=StringFormat("RSI1:%.1f ⊘",   rBuf[0]); rsiClr=CL_NEU; }
      } else { rsiTxt="RSI1 --"; rsiClr=CL_NEU; }
      Lbl(PFX+"RSI1_V",xi+13, ir,rsiTxt,rsiClr,FN);
   }
   if(UseEMA3 && hEMA3 != INVALID_HANDLE) {
      string emaTxt; color emaClr;
      if(gEMA3Dir==+1)      { emaTxt="EMA3 ▲BUY";  emaClr=CL_POS; }
      else if(gEMA3Dir==-1) { emaTxt="EMA3 ▼SELL"; emaClr=CL_NEG; }
      else                  { emaTxt="EMA3 ⊘WAIT";  emaClr=CL_NEU; }
      Lbl(PFX+"EMA3_V",xi+120,ir,emaTxt,emaClr,FN);
   }
   Lbl(PFX+"TIME", xi+224,stY+STAT_H-11,TimeToString(TimeCurrent(),TIME_MINUTES),CL_TIME,FXS,"Arial");
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit() {
   if(!MQLInfoInteger(MQL_TESTER)) {
      datetime now = TimeCurrent();
      if(now > 0 && now >= StringToTime(EXPIRY_STR)) { Print("[Init] expired"); return INIT_FAILED; }
   }
   T1.SetExpertMagicNumber(MAGIC_1); T1.SetDeviationInPoints(30);
   T2.SetExpertMagicNumber(MAGIC_2); T2.SetDeviationInPoints(30);
   T3.SetExpertMagicNumber(MAGIC_3); T3.SetDeviationInPoints(30);
   if(UseADX) {
      hADX = iADX(_Symbol, ADXTF, ADXPer);
      if(hADX == INVALID_HANDLE) Print("[Init] ADX handle fail");
   }
   if(UseRSI1) {
      hRSI1 = iRSI(_Symbol, RSI1TF, RSI1Per, PRICE_CLOSE);
      if(hRSI1 == INVALID_HANDLE) Print("[Init] RSI1 handle fail");
   }
   if(UseEMA3) {
      hEMA3 = iMA(_Symbol, EMA3TF, EMA3Per, 0, MODE_EMA, PRICE_CLOSE);
      if(hEMA3 == INVALID_HANDLE) Print("[Init] EMA3 handle fail");
   }
   gLastM1=0.0; gLastM3=0.0; gM1Dir=0; gM3Dir=0;
   // ── [PATCH] reset ตัวนับทิศทาง ───────────────────────────────
   gCntDown1=0; gCntUp1=0;
   gCntDown3=0; gCntUp3=0;

   datetime latestBuyTime=0, latestSellTime=0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int      m  = (int)PositionGetInteger(POSITION_MAGIC);
      double   op = PositionGetDouble(POSITION_PRICE_OPEN);
      datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      if(m==MAGIC_1)
         { if(ot>latestBuyTime) { latestBuyTime=ot; gLastM1=op;
              gM1Dir=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?+1:-1; } }
      if(m==MAGIC_3)
         { if(ot>latestSellTime) { latestSellTime=ot; gLastM3=op;
              gM3Dir=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?+1:-1; } }
   }

   // ── [PATCH] Restore directional counters จาก positions ที่มีอยู่ ─
   // approximate: ราคา >= lastBuy = Up, ราคา < lastBuy = Down
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int    m  = (int)PositionGetInteger(POSITION_MAGIC);
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      if(m==MAGIC_1) {
         if(op != gLastM1) {  // ข้าม anchor (ไม้ล่าสุด) ไม่นับซ้ำ
            if(op > gLastM1) gCntUp1++; else gCntDown1++;
         }
      }
      if(m==MAGIC_3) {
         if(op != gLastM3) {  // ข้าม anchor (ไม้ล่าสุด) ไม่นับซ้ำ
            if(op > gLastM3) gCntUp3++; else gCntDown3++;
         }
      }
   }

   string gvTrigActiveKey = "HP_TrigActive_"  + _Symbol;
   string gvTrigMagicKey  = "HP_TrigMagic_"   + _Symbol;
   string gvTrigPriceKey  = "HP_TrigPrice_"   + _Symbol;
   if(GlobalVariableCheck(gvTrigActiveKey) && (bool)GlobalVariableGet(gvTrigActiveKey)) {
      gTrig.active       = true;
      gTrig.stoppedMagic = (int)GlobalVariableGet(gvTrigMagicKey);
      gTrig.trigPrice    = GlobalVariableGet(gvTrigPriceKey);
      PrintFormat("[Init] Restored trigger: M%d trigPrice=%.5f",
                  gTrig.stoppedMagic==MAGIC_1?1:3, gTrig.trigPrice);
   } else {
      gTrig.active=false; gTrig.stoppedMagic=0; gTrig.trigPrice=0.0;
   }
   string gvKey="HP_TrigCoolEnd_"+_Symbol;
   gTrigCoolEnd=GlobalVariableCheck(gvKey)?(datetime)GlobalVariableGet(gvKey):0;
   string gvM2LockedKey="HP_M2Locked_"+_Symbol;
   if(GlobalVariableCheck(gvM2LockedKey)) gM2Locked=(bool)GlobalVariableGet(gvM2LockedKey);
   string gvM2CoolKey="HP_M2CoolEnd_"+_Symbol;
   if(GlobalVariableCheck(gvM2CoolKey))   gM2CoolEnd=(datetime)GlobalVariableGet(gvM2CoolKey);
   if(gM2Locked) PrintFormat("[Init] M2 lock restored");
   gADXDir=0;
   gPeakEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   gMaxDDPct=0.0;
   RestoreDailyLots();
   ArrayInitialize(gCalPnl,0.0); ArrayInitialize(gCalLot,0.0);
   gCalDirty=true;
   PrintFormat("[Init] HybridPro V%s  M1=%d M2=%d M3=%d  CntD1=%d CntU1=%d CntD3=%d CntU3=%d",
               EA_VER, Count(MAGIC_1), Count(MAGIC_2), Count(MAGIC_3),
               gCntDown1, gCntUp1, gCntDown3, gCntUp3);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   if(hADX  != INVALID_HANDLE) { IndicatorRelease(hADX);  hADX =INVALID_HANDLE; }
   if(hRSI1 != INVALID_HANDLE) { IndicatorRelease(hRSI1); hRSI1=INVALID_HANDLE; }
   if(hEMA3 != INVALID_HANDLE) { IndicatorRelease(hEMA3); hEMA3=INVALID_HANDLE; }
   DeletePanel();
   DeleteCalendar();
   Comment("");
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick() {
   gTrigJustFired = false;
   gNormalTPFired = false;
   gADXDir = ADXDir();
   CalcM1Signal();
   CalcM3Signal();
   ChkDayRollover();
   CheckDailyTarget();
   UpdateBestSide();
   ChkTrigger();
   ChkGrid1();
   ChkGrid3();
   ChkM2();
   ChkAllTP();
   ChkBestSideTP();
   double _eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(_eq > gPeakEquity) gPeakEquity = _eq;
   double _dd = (gPeakEquity > 0) ? (gPeakEquity - _eq) / gPeakEquity * 100.0 : 0.0;
   if(_dd > gMaxDDPct) gMaxDDPct = _dd;
   ShowDashboard();
   ShowCalPanel();
}
//+------------------------------------------------------------------+