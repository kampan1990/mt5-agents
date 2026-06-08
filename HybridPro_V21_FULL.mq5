//+------------------------------------------------------------------+
//| HybridPro_V21_FULL.mq5                                          |
//| M1=BUY grid (bidirectional) | M2=ADX/Trigger | M3=SELL grid     |
//| PATCH v21:                                                       |
//|   [1] GridLot() — แยก multiplier Up/Down ต่างกันสำหรับ M1, M3  |
//|   [2] Smart Recovery Engine — budget-based, smallest-loss-first  |
//|       แทนที่ AbsorbN/AbsorbMinNet/AbsorbRatio                   |
//+------------------------------------------------------------------+
#property copyright "HybridPro"
#property version   "21.00"
#property strict
#include <Trade\Trade.mqh>

#define EA_VER     "21.00"
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
#define STAT_H    36

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
};

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Enable ==="
input bool   En1          = true;
input bool   En2          = true;
input bool   En3          = true;

input group "=== Lot ==="
input double Lot1         = 0.01;
input double Lot2         = 0.01;
input double Lot3         = 0.01;
input double LotMult2     = 1.0;   // M2 ยังใช้ตัวคูณเดียว (ไม่มีทิศ)

// ── [PATCH] Directional Multiplier M1 (BUY grid) ─────────────────
input group "=== M1 Directional Lot Multiplier ==="
// กราฟลง  = BUY ต้านเทรน → aggressive (คูณมาก)
// กราฟขึ้น = BUY ตามเทรน  → conservative (คูณน้อย)
input double LotMultDown1 = 2.0;   // M1: กราฟลง (ต้านเทรน)
input double LotMultUp1   = 1.1;   // M1: กราฟขึ้น (ตามเทรน)

// ── [PATCH] Directional Multiplier M3 (SELL grid) ────────────────
input group "=== M3 Directional Lot Multiplier ==="
// กราฟขึ้น = SELL ต้านเทรน → aggressive (คูณมาก)
// กราฟลง  = SELL ตามเทรน  → conservative (คูณน้อย)
input double LotMultUp3   = 2.0;   // M3: กราฟขึ้น (ต้านเทรน)
input double LotMultDown3 = 1.1;   // M3: กราฟลง (ตามเทรน)

input group "=== Grid Spacing (points) ==="
input int    GS1          = 100;
input int    GS2          = 100;
input int    GS3          = 100;

input group "=== Grid Limits ==="
input int    MaxGrid1     = 20;
input int    MaxGrid2     = 10;
input int    MaxGrid3     = 20;

input group "=== Loss Trigger ==="
input double LossTrig1    = 200.0;
input double LossTrig3    = 200.0;
input int    TrigCoolSec  = 300;

input group "=== ADX ==="
input bool            UseADX  = true;
input ENUM_TIMEFRAMES ADXTF   = PERIOD_H1;
input int             ADXPer  = 14;
input double          ADXMin  = 20.0;

input group "=== Take Profit ==="
input bool   UseSepTP     = true;
input double TP1          = 5.0;
input double TP2          = 5.0;
input double TP3          = 5.0;
input bool   UsePairTP    = true;
input double TPPair       = 10.0;
input bool   UseTotTP     = true;
input double TPTot        = 15.0;
input group "=== Smart Recovery Engine ==="
// RecoveryRatio: % ของกำไร TP ที่จัดสรรไว้ล้างไม้เสีย
// ตัวอย่าง: TP = $10, RecoveryRatio = 70% → RecoveryBudget = $7
// ระบบจะเลือกไม้เสียที่ขาดทุน "น้อยที่สุด" ออกก่อนจนเต็ม budget
// เงื่อนไข: Net หลังหักไม้เสีย >= 0 เท่านั้นจึงจะปิด
input double RecoveryRatio = 70.0;  // % ของ winSum (0=ปิดใช้งาน)

input group "=== Best Side Pool ==="
// ปิดทั้ง pool เมื่อกำไรรวมถึงเป้า — ไม่ปิดแยกรายไม้ ไม่แยก magic
input int    BestBuyN     = 2;     // จำนวนไม้ BUY กำไรสูงสุด (M1+M2 BUY รวมกัน)
input double TPBestBuy    = 20.0;  // เป้ากำไรรวม BUY pool (USD)
input int    BestSellN    = 2;     // จำนวนไม้ SELL กำไรสูงสุด (M3+M2 SELL รวมกัน)
input double TPBestSell   = 20.0;  // เป้ากำไรรวม SELL pool (USD)

input group "=== Spread ==="
input int    MaxSpread    = 50;

input group "=== Daily Lot Limit ==="
input double MaxDailyLot  = 0.0;

input group "=== Panel ==="
input bool   ShowPanel    = true;
input int    PanelX       = 10;
input int    PanelY       = 20;

input group "=== Calendar Panel ==="
input bool   ShowCal      = true;

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade T1, T2, T3;
int      hADX         = INVALID_HANDLE;
int      gADXDir      = 0;
datetime gTrigCoolEnd = 0;

TriggerState gTrig;

double gLastBuy  = 0.0;
double gLastSell = 0.0;

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

double gPeakEquity = 0.0;
double gMaxDDPct   = 0.0;
bool   gNormalTPFired = false;

double   gCalPnl[31];
double   gCalLot[31];
datetime gCalBuildTime = 0;
bool     gCalDirty     = true;

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
   double bestPf = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double pp = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pp > bestPf) { bestPf = pp; bestTk = t; }
   }
   return bestTk;
}

int GetWorstLoss(int m, int maxN, ulong &outTk[], double &outPf[], ulong skipTk=0) {
   int total = PositionsTotal();
   ulong  tk[]; ArrayResize(tk, total);
   double pf[]; ArrayResize(pf, total);
   int c = 0;
   for(int i = total - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != m) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(skipTk > 0 && t == skipTk) continue;
      double pp = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pp >= 0) continue;
      tk[c] = t; pf[c] = pp; c++;
   }
   SortPairsByPnl(tk, pf, c, true);
   int n = MathMin(c, maxN);
   ArrayResize(outTk, n); ArrayResize(outPf, n);
   for(int i = 0; i < n; i++) { outTk[i] = tk[i]; outPf[i] = pf[i]; }
   return n;
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

//+------------------------------------------------------------------+
//| Daily lot tracking                                               |
//+------------------------------------------------------------------+
void ChkDayRollover() {
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart != gTodayStart) {
      gTodayStart = dayStart;
      gDailyLot1 = gDailyLot2 = gDailyLot3 = 0.0;
      gCalDirty = true;
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
   bool ok = (dir == 1) ? tr.Buy(lot,  _Symbol, 0, 0, 0, "M" + IntegerToString(m))
                        : tr.Sell(lot, _Symbol, 0, 0, 0, "M" + IntegerToString(m));
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
//| เลือกไม้เสียที่ "ขาดทุนน้อยที่สุด" ออกก่อนจนเต็ม RecoveryBudget|
//| criteria: smallest |loss| first → คุ้มค่าต่อพอร์ตที่สุด        |
//| return: จำนวนไม้ที่เลือก, fill outTk[] outPf[] outNet           |
//|         (outNet = winSum - |loserSum| ที่เลือก)                 |
//+------------------------------------------------------------------+
int SelectRecoveryLosers(int &mgs[], double winSum,
                         ulong &outTk[], double &outPf[], double &outNet) {
   ArrayResize(outTk, 0);
   ArrayResize(outPf, 0);
   outNet = winSum;

   if(RecoveryRatio <= 0.0) return 0;

   double budget = winSum * RecoveryRatio / 100.0;  // งบล้างไม้เสีย

   int    totalPos = PositionsTotal();
   ulong  lTk[];  ArrayResize(lTk, totalPos);
   double lPf[];  ArrayResize(lPf, totalPos);
   int    lCnt = 0;

   int nm = ArraySize(mgs);
   for(int i = totalPos - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(IsInBestPool(t)) continue;  // ห้ามแตะ BestPool
      int m = (int)PositionGetInteger(POSITION_MAGIC);
      bool inMgs = false;
      for(int mi = 0; mi < nm; mi++) if(mgs[mi] == m) { inMgs = true; break; }
      if(!inMgs) continue;
      double pp = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pp >= 0) continue;  // เอาเฉพาะไม้เสีย
      lTk[lCnt] = t;
      lPf[lCnt] = pp;
      lCnt++;
   }

   if(lCnt == 0) return 0;

   // เรียงจากขาดทุน "น้อยที่สุด" ก่อน (least negative first = descending by pnl)
   if(lCnt > 1) SortPairsByPnl(lTk, lPf, lCnt, false);  // least negative first

   int    cnt = 0;
   double used = 0;
   for(int i = 0; i < lCnt; i++) {
      double loss = MathAbs(lPf[i]);
      if(used + loss > budget) break;  // เต็ม budget แล้ว
      used += loss;
      ArrayResize(outTk, cnt + 1);
      ArrayResize(outPf, cnt + 1);
      outTk[cnt] = lTk[i];
      outPf[cnt] = lPf[i];
      cnt++;
   }

   outNet = winSum - used;  // net หลังหักไม้เสีย
   return cnt;
}

//+------------------------------------------------------------------+
//| BuildTPGroup — Smart Recovery Engine (budget-based, least-loss)  |
//+------------------------------------------------------------------+
int BuildTPGroup(int &mgs[], ulong &groupTk[], double &groupNet, double &winSum) {
   int nm = ArraySize(mgs);
   ArrayResize(groupTk, 0);
   groupNet = 0;
   winSum   = 0;
   if(nm == 0) return 0;

   // ── ขั้น 1: เก็บ BestTk ของแต่ละ magic (ห้ามแตะ) ──────────────
   ulong bestTk[]; ArrayResize(bestTk, nm);
   for(int mi = 0; mi < nm; mi++) bestTk[mi] = GetBestTk(mgs[mi]);

   // ── ขั้น 2: รวม Winners เข้า Group ────────────────────────────
   int gCnt = 0;
   for(int mi = 0; mi < nm; mi++) {
      ulong wTk[];
      int nW = GetWinnersToClose(mgs[mi], bestTk[mi], wTk);
      for(int i = 0; i < nW; i++) {
         ArrayResize(groupTk, gCnt + 1);
         groupTk[gCnt++] = wTk[i];
         if(PositionSelectByTicket(wTk[i]))
            winSum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }

   // ── ขั้น 3: Smart Recovery — เลือกไม้เสียขาดทุนน้อยสุดที่เข้า budget
   ulong  recTk[]; double recPf[]; double recNet;
   int recN = SelectRecoveryLosers(mgs, winSum, recTk, recPf, recNet);
   double loserSum = recNet - winSum;  // เป็นลบ

   // เงื่อนไข: net >= 0 (ไม่ปิดขาดทุนสุทธิ)
   if(recN > 0 && recNet >= 0) {
      for(int i = 0; i < recN; i++) {
         ArrayResize(groupTk, gCnt + 1);
         groupTk[gCnt++] = recTk[i];
         PrintFormat("[Recovery] ดึงไม้เสีย tk=%I64u pnl=%.2f budget_used=%.2f",
                     recTk[i], recPf[i], MathAbs(recPf[i]));
      }
   }

   groupNet = (recN > 0 && recNet >= 0) ? recNet : winSum;
   PrintFormat("[BuildTPGroup] winners=%.2f recovery=%d net=%.2f pos=%d",
               winSum, recN, groupNet, gCnt);
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
   double winSum;    // กำไร winners ก่อนหักไม้เสีย
   int n = BuildTPGroup(mgs, groupTk, groupNet, winSum);
   if(n == 0) return false;

   if(winSum < target)    return false;  // winners ยังไม่ถึงเป้า
   if(groupNet < 0)       return false;  // net ติดลบ → ไม่ fire

   FireTPGroup(groupTk);
   gNormalTPFired = true;
   PrintFormat("[%s] winners=%.2f net=%.2f target=%.2f closed=%d",
               tag, winSum, groupNet, target, n);
   return true;
}

//+------------------------------------------------------------------+
//| UpdateBestSide — อัปเดต gBestBuyTk / gBestSellTk ทุก tick      |
//+------------------------------------------------------------------+
void UpdateBestSide() {
   int total = PositionsTotal();
   ulong  tk[]; ArrayResize(tk, total);
   double pf[]; ArrayResize(pf, total);

   // BUY pool
   int cnt = 0;
   for(int i = total-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;
      double pp = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pp <= 0) continue;
      tk[cnt]=t; pf[cnt]=pp; cnt++;
   }
   if(cnt > 1) SortPairsByPnl(tk, pf, cnt, false);
   int nB = MathMin(BestBuyN, cnt);
   ArrayResize(gBestBuyTk, nB);
   for(int i=0; i<nB; i++) gBestBuyTk[i] = tk[i];

   // SELL pool
   cnt = 0;
   for(int i = total-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;
      double pp = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pp <= 0) continue;
      tk[cnt]=t; pf[cnt]=pp; cnt++;
   }
   if(cnt > 1) SortPairsByPnl(tk, pf, cnt, false);
   int nS = MathMin(BestSellN, cnt);
   ArrayResize(gBestSellTk, nS);
   for(int i=0; i<nS; i++) gBestSellTk[i] = tk[i];
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
   if(alive == 0 || winSum < target) return;

   // Smart Recovery: เลือกไม้เสียขาดทุนน้อยสุดในทิศเดียวกัน
   int    mgsBoth[] = {MAGIC_1, MAGIC_2, MAGIC_3};  // BestSide ดู cross-magic
   ulong  recTk[]; double recPf[]; double recNet;
   int recN = SelectRecoveryLosers(mgsBoth, winSum, recTk, recPf, recNet);

   if(recNet < 0) {
      PrintFormat("[%s] skip net=%.2f < 0", tag, recNet);
      return;
   }

   PrintFormat("[%s] winSum=%.2f net=%.2f target=%.2f winners=%d recovery=%d",
               tag, winSum, recNet, target, alive, recN);

   for(int i=0; i<recN; i++)  CloseByTicket(recTk[i]);
   for(int i=0; i<n; i++)     CloseByTicket(poolTk[i]);
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
      if(bestIdx >= 0) {
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
            // M2 assist M1(BUY stopped): winners=M2, absorb losers จาก M1+M2
            int mgs[] = {MAGIC_2, MAGIC_1};
            if(TryTP(mgs, TP2, "SepTP[M2+M1assist]")) return;
         } else if(gTrig.active && gTrig.stoppedMagic == MAGIC_3) {
            // M2 assist M3(SELL stopped): winners=M2, absorb losers จาก M3+M2
            int mgs[] = {MAGIC_2, MAGIC_3};
            if(TryTP(mgs, TP2, "SepTP[M2+M3assist]")) return;
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
//|   priceDir: +1 = กราฟขึ้น, -1 = กราฟลง                        |
//|   level   = จำนวนไม้ที่เปิดในทิศนั้นแล้ว (ก่อนเปิดไม้ใหม่)    |
//+------------------------------------------------------------------+
double GridLot(int m, int level, int priceDir) {
   double base = (m == MAGIC_1) ? Lot1 : (m == MAGIC_2) ? Lot2 : Lot3;
   double mult;
   if(m == MAGIC_1) {
      // M1 BUY: ลง=ต้านเทรน=aggressive, ขึ้น=ตามเทรน=conservative
      mult = (priceDir == -1) ? LotMultDown1 : LotMultUp1;
   } else if(m == MAGIC_3) {
      // M3 SELL: ขึ้น=ต้านเทรน=aggressive, ลง=ตามเทรน=conservative
      mult = (priceDir == +1) ? LotMultUp3 : LotMultDown3;
   } else {
      mult = LotMult2;  // M2 ใช้ multiplier เดียว
   }
   return NLot(base * MathPow(mult, (double)level));
}

//+------------------------------------------------------------------+
//| [PATCH] ChkGrid1 — BUY grid พร้อม directional lot               |
//+------------------------------------------------------------------+
void ChkGrid1() {
   if(!En1) return;
   if(gTrig.active && gTrig.stoppedMagic == MAGIC_1) return;

   int    cnt = Count(MAGIC_1);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // ── ไม้แรก: reset ตัวนับ แล้วเปิด BUY ────────────────────────
   if(cnt == 0) {
      gCntDown1 = 0;
      gCntUp1   = 0;
      if(OO(MAGIC_1, 1, NLot(Lot1))) {
         gLastBuy = ask;
         gCntUp1  = 1;  // ไม้แรกนับเป็น Up (neutral ใช้ multiplier ต่ำ)
      }
      return;
   }
   if(cnt >= MaxGrid1) return;

   // ── ยังไม่ถึงระยะ grid ────────────────────────────────────────
   if(gLastBuy <= 0 || MathAbs(ask - gLastBuy) < GS1 * _Point) return;

   // ── ตรวจทิศทางและเลือก level ─────────────────────────────────
   int priceDir = (ask > gLastBuy) ? +1 : -1;
   int level    = (priceDir == -1) ? gCntDown1 : gCntUp1;
   double lot   = GridLot(MAGIC_1, level, priceDir);

   if(OO(MAGIC_1, 1, lot)) {
      gLastBuy = ask;
      if(priceDir == -1) gCntDown1++;
      else               gCntUp1++;
   }
}

//+------------------------------------------------------------------+
//| [PATCH] ChkGrid3 — SELL grid พร้อม directional lot              |
//+------------------------------------------------------------------+
void ChkGrid3() {
   if(!En3) return;
   if(gTrig.active && gTrig.stoppedMagic == MAGIC_3) return;

   int    cnt = Count(MAGIC_3);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ── ไม้แรก: reset ตัวนับ แล้วเปิด SELL ───────────────────────
   if(cnt == 0) {
      gCntDown3 = 0;
      gCntUp3   = 0;
      if(OO(MAGIC_3, -1, NLot(Lot3))) {
         gLastSell = bid;
         gCntDown3 = 1;  // ไม้แรกนับเป็น Down (neutral ใช้ multiplier ต่ำ)
      }
      return;
   }
   if(cnt >= MaxGrid3) return;

   // ── ยังไม่ถึงระยะ grid ────────────────────────────────────────
   if(gLastSell <= 0 || MathAbs(bid - gLastSell) < GS3 * _Point) return;

   // ── ตรวจทิศทางและเลือก level ─────────────────────────────────
   int priceDir = (bid > gLastSell) ? +1 : -1;
   int level    = (priceDir == +1) ? gCntUp3 : gCntDown3;
   double lot   = GridLot(MAGIC_3, level, priceDir);

   if(OO(MAGIC_3, -1, lot)) {
      gLastSell = bid;
      if(priceDir == +1) gCntUp3++;
      else               gCntDown3++;
   }
}

//+------------------------------------------------------------------+
//| ChkM2                                                            |
//+------------------------------------------------------------------+
void ChkM2() {
   if(!En2) return;
   if(gTrigJustFired) return;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int dir = 0;
   if(gTrig.active) {
      dir = (gTrig.stoppedMagic == MAGIC_1) ? -1 : 1;
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
         if(pd != dir) { CM(MAGIC_2); return; }
      }
   }
   int cnt = Count(MAGIC_2);
   if(cnt >= MaxGrid2) return;
   // M2 ใช้ GridLot แบบ neutral (priceDir=0 → ใช้ LotMult2)
   OO(MAGIC_2, dir, GridLot(MAGIC_2, cnt, 0));
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
         gTrig.trigPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         PrintFormat("[Trigger] M1 PNL=%.2f  trig=%.5f", worst, gTrig.trigPrice);
         gTrigJustFired = true; CM(MAGIC_2);
      } else if(worstM == MAGIC_3) {
         gTrig.active = true; gTrig.stoppedMagic = MAGIC_3;
         gTrig.trigPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         PrintFormat("[Trigger] M3 PNL=%.2f  trig=%.5f", worst, gTrig.trigPrice);
         gTrigJustFired = true; CM(MAGIC_2);
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
         gTrig.trigPrice    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         gTrigJustFired     = true;
         CM(MAGIC_2);
         return;
      }
      int    lCount = CountLosers(gTrig.stoppedMagic);
      double pnl    = PNL(gTrig.stoppedMagic);
      if(lCount == 0 && pnl >= 0) {
         PrintFormat("[Trigger] M%d RECOVERED — unlocking", gTrig.stoppedMagic == MAGIC_1 ? 1 : 3);
         if(gTrig.stoppedMagic == MAGIC_1) gLastBuy  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         else                              gLastSell = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         gTrig.active = false; gTrig.stoppedMagic = 0; gTrig.trigPrice = 0.0;
         gTrigCoolEnd = TimeCurrent() + TrigCoolSec;
         GlobalVariableSet("HP_TrigCoolEnd_" + _Symbol, (double)gTrigCoolEnd);
         gTrigJustFired = true;
         CM(MAGIC_2);
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
      gCalPnl[idx] += HistoryDealGetDouble(deal, DEAL_COMMISSION);
      int entry = (int)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
         gCalPnl[idx] += HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP);
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
   string m1sta=m1stopped?"⛔ STOP":"↕ BUY";
   color  m1clr=m1stopped?CL_NEG:C'140,205,255';
   bool   m3stopped=(gTrig.active && gTrig.stoppedMagic==MAGIC_3);
   string m3sta=m3stopped?"⛔ STOP":"↕ SELL";
   color  m3clr=m3stopped?CL_NEG:C'255,195,130';
   string m2mod; color m2mClr;
   if(gTrig.active) {
      if(gTrig.stoppedMagic==MAGIC_1){m2mod="▼ SELL  ← assist M1";m2mClr=C'255,130,130';}
      else                            {m2mod="▲ BUY   ← assist M3";m2mClr=C'130,200,255';}
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
   int sr=stY+12;
   Lbl(PFX+"ADX_V",xi+13, sr,adxTxt,adxClr,FN);
   Lbl(PFX+"SP_L", xi+110,sr,"Spread",CL_INFO,FS,"Arial");
   Lbl(PFX+"SP_V", xi+158,sr,StringFormat("%d pt",spd),spdClr,FN);
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
   gLastBuy=0.0; gLastSell=0.0;
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
      if(m==MAGIC_1 && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
         { if(ot>latestBuyTime){latestBuyTime=ot; gLastBuy=op;} }
      if(m==MAGIC_3 && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL)
         { if(ot>latestSellTime){latestSellTime=ot; gLastSell=op;} }
   }

   // ── [PATCH] Restore directional counters จาก positions ที่มีอยู่ ─
   // approximate: ราคา >= lastBuy = Up, ราคา < lastBuy = Down
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int    m  = (int)PositionGetInteger(POSITION_MAGIC);
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      if(m==MAGIC_1 && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) {
         if(op >= gLastBuy) gCntUp1++; else gCntDown1++;
      }
      if(m==MAGIC_3 && PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL) {
         if(op <= gLastSell) gCntDown3++; else gCntUp3++;
      }
   }

   gTrig.active=false; gTrig.stoppedMagic=0; gTrig.trigPrice=0.0;
   string gvKey="HP_TrigCoolEnd_"+_Symbol;
   gTrigCoolEnd=GlobalVariableCheck(gvKey)?(datetime)GlobalVariableGet(gvKey):0;
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
   if(hADX != INVALID_HANDLE) { IndicatorRelease(hADX); hADX=INVALID_HANDLE; }
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
   ChkDayRollover();
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