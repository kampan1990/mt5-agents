//+------------------------------------------------------------------+
//| QTheory.mq5                                                       |
//| QTheory EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026.11.03                                               |
//|                                                                   |
//| Raw/Hidden base + Q ladder (pending limit) + shared basket SL     |
//| + Runner 1 ไม้ต่อฝั่ง พร้อม breakeven (ดู DESIGN.md)              |
//+------------------------------------------------------------------+
#property copyright "mt5-agents"
#property version   "1.00"
#property strict

#include "Utils.mqh"
#include "Logger.mqh"
#include "RiskManager.mqh"
#include "Strategy.mqh"

//--- Q ladder (หน่วย $ = ระยะราคา x InpPriceUnit)
input group "=== Q Ladder ($) ==="
input string   InpSellOffsets      = "5,10,15,18,21";  // Sell offsets (+ จาก P0)
input string   InpBuyOffsets       = "4,10,15,18,21";  // Buy offsets (- จาก P0)
input double   InpPriceUnit        = 1.0;              // ราคากี่หน่วยต่อ $1 (XAUUSD = 1.0)

//--- Base
input group "=== Base / Signal ==="
input bool     InpUseRaw           = true;             // ใช้ชุด Raw
input bool     InpUseHidden        = true;             // ใช้ชุด Hidden
input bool     InpRequireBothSets  = true;             // Raw+Hidden ต้องทิศตรงกัน
input double   InpBlockSize        = 100.0;            // ขนาด block (เลข 00-100)
input double   InpHiddenShift      = 20.0;             // Hidden = Raw - shift
input double   InpMidTolerance     = 12.0;             // ระยะจาก mid ที่ยอมรับ ($)
input bool     InpUseDayRange      = true;             // ราคาต้องอยู่ใน H/L ของวัน
input double   InpDayEdgeBuffer    = 0.0;              // กันขอบ H/L ($)
input int      InpSignalIntervalSec= 10;               // ตรวจสัญญาณทุก N วินาที

//--- Exit
input group "=== Exit ==="
input ENUM_QT_TPMODE InpTPMode     = QT_TP_BACK_TO_P0; // 0 = กลับ P0, 1 = fixed, 2 = base ถัดไป
input double   InpTPFixedDist      = 5.0;              // TP fixed ($) สำหรับ mode 1
input double   InpTPMinDist        = 1.0;              // ระยะ TP ขั้นต่ำ ($) สำหรับ mode 2
input double   InpSLBufferBeyondQ  = 10.0;             // SL ร่วม = Q ไกลสุด + buffer ($)
input int      InpPendingExpireMin = 240;              // pending หมดอายุ (นาที, 0 = ไม่หมด)
input int      InpMaxHoldMin       = 0;                // ปิดไม้ non-runner ของรอบหลัง N นาที (0 = ปิดใช้)
input int      InpCooldownMin      = 15;               // พักหลังจบรอบ (นาที)

//--- Runner
input group "=== Runner / Breakeven ==="
input bool     InpKeepRunner       = true;             // เก็บ Runner 1 ไม้ต่อฝั่ง
input double   InpRunnerTPDist      = 30.0;            // TP ไกลของ Runner ($)
input bool     InpRunnerUseNextBase = false;           // true = TP Runner ที่ base ถัดไป (ไกลกว่า BEActivation)
input double   InpBEActivation     = 8.0;              // กำไร Runner >= นี้ ($) -> ตั้ง BE
input double   InpBELockBuffer     = 0.3;              // BE = entry +/- buffer ($)

//--- Risk
input group "=== Risk ==="
input double   InpRiskPercent      = 1.0;              // Risk % ต่อรอบ (ถ้าเต็มทุกไม้แล้วชน SL)
input double   InpMaxDDPercent     = 10.0;             // Max drawdown % (ปิดทั้งหมด + หยุด)
input double   InpDailyLossPercent = 3.0;              // ขาดทุนรายวัน % -> หยุดถึงวันถัดไป
input bool     InpDailyCloseAll    = true;             // ชนลิมิตรายวันแล้วปิดทุกไม้
input double   InpMaxSpread        = 0.5;              // Spread สูงสุด ($)
input double   InpMaxLot           = 5.0;              // lot สูงสุดต่อไม้
input bool     InpAllowMinLot      = false;            // lot คำนวณต่ำกว่า min -> ใช้ min lot (เสี่ยงเกิน)
input int      InpMaxOpenPositions = 8;                // positions+pendings สูงสุด (รวม Runner)
input double   InpMaxMarginUsePct  = 50.0;             // margin ที่ใช้ได้ไม่เกิน % ของ free margin

//--- Misc
input group "=== Misc ==="
input long     InpMagic            = 20261103;         // Magic number
input int      InpDeviation        = 30;               // slippage (points) สำหรับ market close
input bool     InpUseSession       = true;             // จำกัดเวลาเปิดรอบใหม่
input int      InpSessionStartHour = 7;                // เริ่ม (server hour)
input int      InpSessionEndHour   = 20;               // สิ้นสุด (server hour)
input bool     InpLogToFile        = true;             // เขียน log ลงไฟล์
input bool     InpDebug            = false;            // Debug log
input bool     InpRunSelfTest      = true;             // รัน self-check ตัวอย่าง 4460 ตอน OnInit
input bool     InpResetHalt        = false;            // ล้างสถานะหยุดเทรด/peak ที่ค้าง

#define QT_TAG              "QT"
#define QT_EA_NAME          "QTheory"
#define QT_MAX_TP_ROUNDS    50
#define QT_SELFTEST_EPS     0.0001
#define QT_BE_RETRY_SEC     1

//--- Global state
double      g_sellOff[];
double      g_buyOff[];
long        g_round        = 0;            // 0 = ไม่มีรอบ (IDLE)
long        g_lastRoundId  = 0;
ENUM_SIGNAL g_roundSide    = SIGNAL_NONE;
double      g_roundP0      = 0.0;
double      g_roundBlock   = 0.0;
datetime    g_roundTime    = 0;
bool        g_roundFilled  = false;
datetime    g_cooldownUntil= 0;
datetime    g_lastSignalChk= 0;
datetime    g_lastBETry    = 0;
long        g_tpRounds[];                  // รอบที่มีไม้ non-runner ชน TP แล้ว
bool        g_ready        = false;

//+------------------------------------------------------------------+
//| helpers                                                           |
//+------------------------------------------------------------------+
//--- $ -> ระยะราคา (digits-safe)
double D(const double dollars)
{
   return Utils::DollarsToPrice(dollars, InpPriceUnit);
}

//--- สร้าง comment: QT<round>_<idx>[R]  | R = Runner
string BuildComment(const long round, const int idx, const bool runner)
{
   return StringFormat("%s%I64d_%d%s", QT_TAG, round, idx, runner ? "R" : "");
}

//--- แยก comment | คืน: true ถ้าเป็น comment ของ EA นี้
bool ParseComment(const string c, long &round, int &idx, bool &runner)
{
   round = 0; idx = -1; runner = false;
   int tagLen = StringLen(QT_TAG);
   if(StringSubstr(c, 0, tagLen) != QT_TAG) return false;
   int us = StringFind(c, "_", tagLen);
   if(us < 0) return false;
   round = StringToInteger(StringSubstr(c, tagLen, us - tagLen));
   idx   = (int)StringToInteger(StringSubstr(c, us + 1));
   int len = StringLen(c);
   runner = (len > 0 && StringGetCharacter(c, len - 1) == 'R');
   return (round > 0);
}

//--- ส่ง request พร้อมตรวจ retcode + GetLastError + log | คืน: true ถ้าสำเร็จ
bool SendRequest(MqlTradeRequest &req, MqlTradeResult &res, const string what)
{
   ZeroMemory(res);
   ResetLastError();
   bool sent = OrderSend(req, res);
   int  err  = GetLastError();
   bool ok   = sent && (res.retcode == TRADE_RETCODE_DONE ||
                        res.retcode == TRADE_RETCODE_PLACED ||
                        res.retcode == TRADE_RETCODE_DONE_PARTIAL);
   if(!ok)
   {
      Logger::Error(StringFormat("%s FAILED: sent=%d retcode=%u (%s) GetLastError=%d",
                                 what, (int)sent, res.retcode, res.comment, err));
      return false;
   }
   Logger::Trade(StringFormat("%s OK: retcode=%u order=%I64u deal=%I64u", what,
                              res.retcode, res.order, res.deal));
   return true;
}

//--- วาง pending limit (บังคับ SL/TP และตรวจทิศก่อนส่งเสมอ)
bool PlacePending(const ENUM_ORDER_TYPE type, const double price, const double vol,
                  const double sl, const double tp, const string comment)
{
   if(sl <= 0.0 || tp <= 0.0)
   {
      Logger::Error("PlacePending: invalid SL/TP (must be > 0)");
      return false;
   }
   bool isBuy = (type == ORDER_TYPE_BUY_LIMIT);
   bool isSell = (type == ORDER_TYPE_SELL_LIMIT);
   if(!isBuy && !isSell) { Logger::Error("PlacePending: unsupported order type"); return false; }
   if(isBuy && !(sl < price && price < tp))
   { Logger::Error(StringFormat("PlacePending: bad BUY geometry sl=%.5f price=%.5f tp=%.5f", sl, price, tp)); return false; }
   if(isSell && !(tp < price && price < sl))
   { Logger::Error(StringFormat("PlacePending: bad SELL geometry sl=%.5f price=%.5f tp=%.5f", sl, price, tp)); return false; }

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   req.action       = TRADE_ACTION_PENDING;
   req.symbol       = _Symbol;
   req.volume       = vol;
   req.type         = type;
   req.price        = price;
   req.sl           = sl;
   req.tp           = tp;
   req.magic        = InpMagic;
   req.comment      = comment;
   req.type_time    = ORDER_TIME_GTC;
   req.type_filling = ORDER_FILLING_RETURN;

   string what = StringFormat("PLACE %s vol=%.2f price=%.5f sl=%.5f tp=%.5f [%s]",
                              EnumToString(type), vol, price, sl, tp, comment);
   return SendRequest(req, res, what);
}

//--- แก้ SL/TP ของ position (ต้อง > 0 ทั้งคู่)
bool ModifySLTP(const ulong ticket, const double sl, const double tp, const string why)
{
   if(sl <= 0.0 || tp <= 0.0)
   {
      Logger::Error("ModifySLTP: invalid SL/TP (must be > 0)");
      return false;
   }
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   req.action   = TRADE_ACTION_SLTP;
   req.symbol   = _Symbol;
   req.position = ticket;
   req.sl       = sl;
   req.tp       = tp;
   req.magic    = InpMagic;
   return SendRequest(req, res, StringFormat("MODIFY #%I64u sl=%.5f tp=%.5f (%s)", ticket, sl, tp, why));
}

//--- ปิด position ด้วย market
bool ClosePosition(const ulong ticket, const string why)
{
   if(!PositionSelectByTicket(ticket)) return false;
   long   type = PositionGetInteger(POSITION_TYPE);
   double vol  = PositionGetDouble(POSITION_VOLUME);
   bool   isBuy = (type == POSITION_TYPE_BUY);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   req.action       = TRADE_ACTION_DEAL;
   req.position     = ticket;
   req.symbol       = _Symbol;
   req.volume       = vol;
   req.type         = isBuy ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price        = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   req.deviation    = InpDeviation;
   req.magic        = InpMagic;
   req.type_filling = Utils::MarketFilling(_Symbol);
   req.comment      = "QT_close";
   return SendRequest(req, res, StringFormat("CLOSE #%I64u vol=%.2f (%s)", ticket, vol, why));
}

//--- ลบ pending ทั้งหมดของ EA
void DeleteAllPendings(const string why)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      req.action = TRADE_ACTION_REMOVE;
      req.order  = t;
      SendRequest(req, res, StringFormat("DELETE pending #%I64u (%s)", t, why));
   }
}

//--- มี position/pending ของ EA ค้างไหม
bool HasExposure()
{
   return (RiskManager::CountOpenTrades() + RiskManager::CountPendingOrders()) > 0;
}

//--- ปิดทุกอย่าง (pending + position ทั้งหมดรวม Runner)
void CloseAll(const string why)
{
   Logger::Warn("CLOSE ALL: " + why);
   DeleteAllPendings(why);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      ClosePosition(t, why);
   }
}

//--- นับ position ของรอบ round (non-runner / runner)
void CountRoundPositions(const long round, int &nonRunner, int &runners)
{
   nonRunner = 0; runners = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long r; int idx; bool isRunner;
      if(!ParseComment(PositionGetString(POSITION_COMMENT), r, idx, isRunner)) continue;
      if(r != round) continue;
      if(isRunner) runners++; else nonRunner++;
   }
}

//--- ฝั่งนี้มี Runner อยู่แล้วไหม (กฎ: 1 Runner ต่อฝั่ง)
bool HasRunnerOnSide(const ENUM_SIGNAL side)
{
   long wantType = (side == SIGNAL_SELL) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE) != wantType) continue;
      long r; int idx; bool isRunner;
      if(ParseComment(PositionGetString(POSITION_COMMENT), r, idx, isRunner) && isRunner) return true;
   }
   return false;
}

//--- บันทึกว่ารอบนี้มีไม้ non-runner ชน TP
void MarkTPRound(const long round)
{
   int n = ArraySize(g_tpRounds);
   for(int i = 0; i < n; i++)
      if(g_tpRounds[i] == round) return;
   if(n >= QT_MAX_TP_ROUNDS)
   {
      for(int i = 1; i < n; i++) g_tpRounds[i - 1] = g_tpRounds[i];
      n--;
   }
   ArrayResize(g_tpRounds, n + 1);
   g_tpRounds[n] = round;
   Logger::Info(StringFormat("Round %I64d: non-runner TP hit -> runner BE armed", round));
}

bool IsTPRound(const long round)
{
   for(int i = ArraySize(g_tpRounds) - 1; i >= 0; i--)
      if(g_tpRounds[i] == round) return true;
   return false;
}

//--- หา round จาก deal เข้า (IN) ของ position id | runner = out flag
long RoundOfPosition(const ulong positionId, bool &runner)
{
   runner = false;
   if(!HistorySelectByPosition(positionId)) return 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      long r; int idx; bool isRunner;
      if(ParseComment(HistoryDealGetString(d, DEAL_COMMENT), r, idx, isRunner))
      {
         runner = isRunner;
         return r;
      }
   }
   return 0;
}

//--- จบรอบ | cooldown = true จะพักตาม InpCooldownMin
void EndRound(const string why, const bool cooldown)
{
   if(g_round == 0) return;
   Logger::Info(StringFormat("ROUND %I64d END: %s", g_round, why));
   g_round = 0;
   g_roundSide = SIGNAL_NONE;
   g_roundFilled = false;
   if(cooldown)
      g_cooldownUntil = TimeCurrent() + InpCooldownMin * QT_SECONDS_PER_MINUTE;
}

//+------------------------------------------------------------------+
//| Runner TP ไกล (ไม่ปล่อยให้ไม่มี TP)                                |
//+------------------------------------------------------------------+
double RunnerTP(const ENUM_SIGNAL side, const double entry)
{
   if(InpRunnerUseNextBase)
   {
      double origin = InpUseRaw ? 0.0 : -InpHiddenShift;
      return Strategy::NextBase(entry, side, D(InpBEActivation) + D(InpBELockBuffer),
                                InpBlockSize, origin);
   }
   double d = D(InpRunnerTPDist);
   return Utils::NormalizePrice(side == SIGNAL_SELL ? entry - d : entry + d);
}

//+------------------------------------------------------------------+
//| วาง ladder ทั้งรอบ | คืน: true ถ้าวางได้อย่างน้อย 1 ไม้                |
//+------------------------------------------------------------------+
bool PlaceRound(const ENUM_SIGNAL side, const double p0Raw)
{
   bool   isSell = (side == SIGNAL_SELL);
   double p0     = Utils::NormalizePrice(p0Raw);
   double offs[];
   if(isSell) ArrayCopy(offs, g_sellOff); else ArrayCopy(offs, g_buyOff);

   double levels[];
   Strategy::BuildLadder(side, p0, offs, InpPriceUnit, levels);
   double sl = Strategy::SharedSL(side, p0, offs, InpPriceUnit, D(InpSLBufferBeyondQ));
   if(sl <= 0.0) { Logger::Error("PlaceRound: SL invalid"); return false; }

   double stops = Utils::StopsDistance(_Symbol);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mkt = isSell ? bid : ask;
   bool   wantRunner = InpKeepRunner && !HasRunnerOnSide(side);
   bool   runnerAssigned = false;

   double entries[]; double tps[]; int idxs[]; bool runFlags[];
   int nValid = 0;
   for(int i = 0; i < ArraySize(levels); i++)
   {
      double e = levels[i];
      double distMkt = isSell ? (e - mkt) : (mkt - e);
      if(distMkt < stops)
      {
         Logger::Warn(StringFormat("Level %d (%.5f) skipped: too close to market (stops=%.5f)", i, e, stops));
         continue;
      }
      bool asRunner = (wantRunner && !runnerAssigned);
      double tp;
      if(asRunner)
         tp = RunnerTP(side, e);
      else
         tp = Strategy::LevelTP(InpTPMode, side, p0, e, D(InpTPFixedDist), D(InpTPMinDist),
                                InpBlockSize, InpUseRaw ? 0.0 : -InpHiddenShift);
      bool tpSideOK = isSell ? (tp < e) : (tp > e);
      if(tp <= 0.0 || !tpSideOK || MathAbs(tp - e) < stops)
      {
         Logger::Warn(StringFormat("Level %d (%.5f) skipped: TP %.5f invalid/too close", i, e, tp));
         continue;
      }
      ArrayResize(entries, nValid + 1);
      ArrayResize(tps, nValid + 1);
      ArrayResize(idxs, nValid + 1);
      ArrayResize(runFlags, nValid + 1);
      entries[nValid] = e; tps[nValid] = tp; idxs[nValid] = i; runFlags[nValid] = asRunner;
      if(asRunner) runnerAssigned = true;
      nValid++;
   }
   if(nValid == 0) { Logger::Warn("PlaceRound: no valid level"); return false; }

   if(!RiskManager::CanOpenNewTrade(InpMaxOpenPositions, nValid))
   {
      Logger::Warn("PlaceRound: max open positions/pendings would be exceeded");
      return false;
   }

   double lot = RiskManager::CalculateLot(entries, sl, InpRiskPercent, InpMaxLot, InpAllowMinLot);
   if(lot <= 0.0)
   {
      Logger::Warn("PlaceRound: lot = 0 (risk too small for min lot or bad symbol data)");
      return false;
   }
   ENUM_ORDER_TYPE otype = isSell ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   if(!RiskManager::MarginOK(otype, lot, entries, InpMaxMarginUsePct))
   {
      Logger::Warn("PlaceRound: margin check failed");
      return false;
   }

   long id = (long)TimeCurrent();
   if(id <= g_lastRoundId) id = g_lastRoundId + 1;
   g_lastRoundId = id;

   ENUM_ORDER_TYPE ptype = isSell ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_BUY_LIMIT;
   int placed = 0;
   for(int k = 0; k < nValid; k++)
   {
      if(PlacePending(ptype, entries[k], lot, sl, tps[k], BuildComment(id, idxs[k], runFlags[k])))
         placed++;
   }
   if(placed == 0) { Logger::Error("PlaceRound: no pending placed"); return false; }

   g_round       = id;
   g_roundSide   = side;
   g_roundP0     = p0;
   g_roundBlock  = Strategy::BlockStart(p0, InpBlockSize);
   g_roundTime   = TimeCurrent();
   g_roundFilled = false;
   Logger::Trade(StringFormat("ROUND %I64d ARMED: %s P0=%.5f sharedSL=%.5f lot=%.2f placed=%d/%d runner=%s",
                              id, isSell ? "SELL" : "BUY", p0, sl, lot, placed, nValid,
                              runnerAssigned ? "yes" : "no"));
   return true;
}

//+------------------------------------------------------------------+
//| ประเมินสัญญาณและเปิดรอบใหม่ (เรียกเมื่อ IDLE)                       |
//+------------------------------------------------------------------+
void TryNewRound()
{
   datetime now = TimeCurrent();
   if(now < g_cooldownUntil) return;
   if(g_lastSignalChk != 0 && (now - g_lastSignalChk) < InpSignalIntervalSec) return;
   g_lastSignalChk = now;

   if(InpUseSession && !Utils::InSession(InpSessionStartHour, InpSessionEndHour)) return;
   if(!Utils::IsSpreadAcceptable(D(InpMaxSpread))) { Logger::Debug("Spread too wide"); return; }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0) return;

   double dayLow = 0.0, dayHigh = 0.0;
   if(InpUseDayRange && !Utils::GetDayHighLow(dayLow, dayHigh)) return;

   SSignalParams sp;
   sp.blockSize    = InpBlockSize;
   sp.hiddenShift  = InpHiddenShift;
   sp.midTolerance = D(InpMidTolerance);
   sp.dayEdge      = D(InpDayEdgeBuffer);
   sp.useRaw       = InpUseRaw;
   sp.useHidden    = InpUseHidden;
   sp.requireBoth  = InpRequireBothSets;
   sp.useDayRange  = InpUseDayRange;

   ENUM_SIGNAL sig = Strategy::Evaluate(bid, dayLow, dayHigh, sp);
   if(sig == SIGNAL_NONE) return;

   double p0 = (sig == SIGNAL_SELL) ? bid : ask;
   Logger::Trade(StringFormat("SIGNAL %s bid=%.5f ask=%.5f rawMid=%.2f hidMid=%.2f dayL=%.5f dayH=%.5f",
                              sig == SIGNAL_SELL ? "SELL" : "BUY", bid, ask,
                              Strategy::RawMid(bid, InpBlockSize),
                              Strategy::HiddenMid(bid, InpBlockSize, InpHiddenShift), dayLow, dayHigh));
   if(!PlaceRound(sig, p0))
      g_cooldownUntil = now + InpCooldownMin * QT_SECONDS_PER_MINUTE;
}

//+------------------------------------------------------------------+
//| ดูแลรอบปัจจุบัน: ARMED -> ACTIVE -> CLOSED                         |
//+------------------------------------------------------------------+
void ManageRound()
{
   if(g_round == 0) return;

   int pend = RiskManager::CountPendingOrders();
   int nonRunner, runners;
   CountRoundPositions(g_round, nonRunner, runners);
   int posTotal = nonRunner + runners;
   datetime now = TimeCurrent();
   bool expired = (InpPendingExpireMin > 0 &&
                   (now - g_roundTime) >= InpPendingExpireMin * QT_SECONDS_PER_MINUTE);

   if(posTotal > 0 && !g_roundFilled)
   {
      g_roundFilled = true;
      Logger::Trade(StringFormat("ROUND %I64d ACTIVE: first fill (non-runner=%d runner=%d)", g_round, nonRunner, runners));
   }

   if(!g_roundFilled)
   {
      // ARMED: ยังไม่มีไม้ถูกเติม
      if(pend == 0) { EndRound("no pending left", true); return; }
      if(expired)
      {
         DeleteAllPendings("expired");
         EndRound("expired without fill", true);
         return;
      }
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(Strategy::BlockStart(bid, InpBlockSize) != g_roundBlock)
      {
         DeleteAllPendings("block changed");
         EndRound("price crossed block", true);
      }
      return;
   }

   // ACTIVE
   if(IsTPRound(g_round))
   {
      DeleteAllPendings("basket TP hit");
      EndRound("basket TP (runner kept if any)", true);
      return;
   }
   if(posTotal == 0)
   {
      DeleteAllPendings("basket closed (SL)");
      EndRound("all positions closed", true);
      return;
   }
   if(expired && pend > 0)
      DeleteAllPendings("expired");
   if(InpMaxHoldMin > 0 && (now - g_roundTime) >= InpMaxHoldMin * QT_SECONDS_PER_MINUTE)
   {
      DeleteAllPendings("max hold");
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         long r; int idx; bool isRunner;
         if(!ParseComment(PositionGetString(POSITION_COMMENT), r, idx, isRunner)) continue;
         if(r == g_round && !isRunner) ClosePosition(t, "max hold");
      }
      EndRound("max hold reached", true);
      return;
   }
   if(RiskManager::CountPendingOrders() == 0 && nonRunner == 0)
      EndRound("only runner left", true);
}

//+------------------------------------------------------------------+
//| Runner: ย้าย SL ไป breakeven เมื่อไม้อื่นชน TP หรือกำไร >= BEActivation|
//+------------------------------------------------------------------+
void ManageRunners()
{
   if(!InpKeepRunner) return;
   datetime now = TimeCurrent();
   if(g_lastBETry != 0 && (now - g_lastBETry) < QT_BE_RETRY_SEC) return;

   double lock  = D(InpBELockBuffer);
   double act   = D(InpBEActivation);
   double stops = Utils::StopsDistance(_Symbol);
   double tick  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long round; int idx; bool runner;
      if(!ParseComment(PositionGetString(POSITION_COMMENT), round, idx, runner) || !runner) continue;

      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);

      double profitDist = isBuy ? (bid - open) : (open - ask);
      bool armed = IsTPRound(round) || profitDist >= act - QT_EPS;
      if(!armed) continue;

      double target = Utils::NormalizePrice(isBuy ? open + lock : open - lock);
      bool improves = isBuy ? (sl <= 0.0 || target > sl + tick * 0.5)
                            : (sl <= 0.0 || target < sl - tick * 0.5);
      if(!improves) continue;
      bool valid = isBuy ? (target <= bid - stops) : (target >= ask + stops);
      if(!valid) continue;   // ราคายังไม่ถึงจุดที่ตั้ง BE ได้ ลองใหม่ tick ถัดไป

      if(tp <= 0.0)
         tp = RunnerTP(isBuy ? SIGNAL_BUY : SIGNAL_SELL, open);   // กันกรณี Runner ไม่มี TP
      g_lastBETry = now;
      ModifySLTP(t, target, tp, "runner breakeven");
   }
}

//+------------------------------------------------------------------+
//| กู้ state หลัง restart: หา round ล่าสุดจาก pending/position          |
//+------------------------------------------------------------------+
void RecoverState()
{
   long bestRound = 0;
   ENUM_SIGNAL side = SIGNAL_NONE;
   double lastPrice = 0.0;
   datetime firstTime = 0;
   bool filled = false;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      long r; int idx; bool rn;
      if(!ParseComment(OrderGetString(ORDER_COMMENT), r, idx, rn)) continue;
      if(r >= bestRound)
      {
         bestRound = r;
         side = (OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_SELL_LIMIT) ? SIGNAL_SELL : SIGNAL_BUY;
         lastPrice = OrderGetDouble(ORDER_PRICE_OPEN);
         firstTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      }
   }
   // runner ที่ค้างอยู่ -> กู้ flag TP จากประวัติ
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long r; int idx; bool rn;
      if(!ParseComment(PositionGetString(POSITION_COMMENT), r, idx, rn)) continue;
      if(r >= bestRound)
      {
         bestRound = r;
         side = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) ? SIGNAL_SELL : SIGNAL_BUY;
         lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         firstTime = (datetime)PositionGetInteger(POSITION_TIME);
      }
   }
   if(bestRound == 0) return;
   int nrPos, rnPos;
   CountRoundPositions(bestRound, nrPos, rnPos);
   filled = (nrPos + rnPos) > 0;

   // กู้ TP flag: ดู deal ปิดด้วย TP ใน 7 วันล่าสุด
   const int RECOVER_DAYS = 7;
   const int SECONDS_PER_DAY = 86400;
   ulong closedIds[];
   if(HistorySelect(TimeCurrent() - RECOVER_DAYS * SECONDS_PER_DAY, TimeCurrent() + QT_SECONDS_PER_MINUTE))
   {
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0) continue;
         if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
         if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
         if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         if(HistoryDealGetInteger(d, DEAL_REASON) != DEAL_REASON_TP) continue;
         int k = ArraySize(closedIds);
         ArrayResize(closedIds, k + 1);
         closedIds[k] = (ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID);
      }
   }
   for(int k = 0; k < ArraySize(closedIds); k++)
   {
      bool rn;
      long r = RoundOfPosition(closedIds[k], rn);
      if(r > 0 && !rn) MarkTPRound(r);
   }

   g_lastRoundId = bestRound;
   if(IsTPRound(bestRound)) return;     // รอบนั้นจบแล้ว เหลือแต่ Runner/ไม้ที่มี TP ของตัวเอง
   g_round       = bestRound;
   g_roundSide   = side;
   g_roundP0     = lastPrice;
   g_roundBlock  = Strategy::BlockStart(lastPrice, InpBlockSize);
   g_roundTime   = (firstTime > 0) ? firstTime : TimeCurrent();
   g_roundFilled = filled;
   Logger::Warn(StringFormat("RECOVERED round %I64d side=%s filled=%s", bestRound,
                             side == SIGNAL_SELL ? "SELL" : "BUY", filled ? "yes" : "no"));
}

//+------------------------------------------------------------------+
//| Self-check: ตัวอย่าง 4460 จาก DESIGN.md                             |
//+------------------------------------------------------------------+
bool SelfCheck()
{
   bool ok = true;
   double so[], bo[], lv[];
   Utils::ParseDoubleList("5,10,15,18,21", so);
   Utils::ParseDoubleList("4,10,15,18,21", bo);
   double expSell[5] = {4465.0, 4470.0, 4475.0, 4478.0, 4481.0};
   double expBuy[5]  = {4456.0, 4450.0, 4445.0, 4442.0, 4439.0};
   const double P0 = 4460.0;
   const double UNIT = 1.0;

   int n = Strategy::BuildLadder(SIGNAL_SELL, P0, so, UNIT, lv);
   if(n != 5) { Logger::Error("SelfCheck: sell level count != 5"); ok = false; }
   for(int i = 0; i < n && i < 5; i++)
      if(MathAbs(lv[i] - expSell[i]) > QT_SELFTEST_EPS)
      { Logger::Error(StringFormat("SelfCheck: sell[%d]=%.5f expected %.5f", i, lv[i], expSell[i])); ok = false; }

   n = Strategy::BuildLadder(SIGNAL_BUY, P0, bo, UNIT, lv);
   if(n != 5) { Logger::Error("SelfCheck: buy level count != 5"); ok = false; }
   for(int i = 0; i < n && i < 5; i++)
      if(MathAbs(lv[i] - expBuy[i]) > QT_SELFTEST_EPS)
      { Logger::Error(StringFormat("SelfCheck: buy[%d]=%.5f expected %.5f", i, lv[i], expBuy[i])); ok = false; }

   double rawMid = Strategy::RawMid(P0, 100.0);
   double hidMid = Strategy::HiddenMid(P0, 100.0, 20.0);
   if(MathAbs(rawMid - 4450.0) > QT_SELFTEST_EPS) { Logger::Error("SelfCheck: rawMid != 4450"); ok = false; }
   if(MathAbs(hidMid - 4430.0) > QT_SELFTEST_EPS) { Logger::Error("SelfCheck: hiddenMid != 4430"); ok = false; }

   SSignalParams sp;
   sp.blockSize = 100.0; sp.hiddenShift = 20.0; sp.midTolerance = 12.0; sp.dayEdge = 0.0;
   sp.useRaw = true; sp.useHidden = true; sp.requireBoth = true; sp.useDayRange = true;
   if(Strategy::Evaluate(P0, 4440.0, 4495.0, sp) != SIGNAL_SELL)
   { Logger::Error("SelfCheck: 4460 (L=4440,H=4495) should be SELL"); ok = false; }

   double sl = Strategy::SharedSL(SIGNAL_SELL, P0, so, UNIT, 10.0);
   if(MathAbs(sl - 4491.0) > QT_SELFTEST_EPS) { Logger::Error("SelfCheck: sell sharedSL != 4491"); ok = false; }

   Logger::Info(ok ? "SelfCheck PASSED (4460 example)" : "SelfCheck FAILED");
   return ok;
}

//+------------------------------------------------------------------+
//| Expert events                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   Logger::Init(QT_EA_NAME, InpLogToFile, InpDebug);
   Logger::Info("EA initializing");

   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Logger::Error("Hedging account required (multiple same-direction positions + runner)");
      return INIT_FAILED;
   }
   if(InpRunSelfTest && !SelfCheck()) return INIT_FAILED;

   if(Utils::ParseDoubleList(InpSellOffsets, g_sellOff) == 0 ||
      Utils::ParseDoubleList(InpBuyOffsets, g_buyOff) == 0)
   {
      Logger::Error("Invalid Sell/Buy offsets");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpRiskPercent <= 0.0 || InpPriceUnit <= 0.0 || InpBlockSize <= 0.0 ||
      InpSLBufferBeyondQ < 0.0 || InpMidTolerance <= 0.0)
   {
      Logger::Error("Invalid risk/unit/block/SL buffer/tolerance parameters");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!InpUseRaw && !InpUseHidden)
   {
      Logger::Error("Enable at least one of Raw/Hidden");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpBEActivation <= InpBELockBuffer)
      Logger::Warn("InpBEActivation <= InpBELockBuffer: breakeven lock may be unreachable");
   if(InpUseRaw && InpUseHidden && InpRequireBothSets && InpMidTolerance <= InpHiddenShift)
      Logger::Warn("Raw+Hidden must agree and MidTolerance <= HiddenShift: BUY signals can never occur (need tolerance > shift)");

   RiskManager::Init(_Symbol, InpMagic, InpResetHalt);
   if(RiskManager::IsHalted())
      Logger::Warn("Trading HALTED by previous max-DD event. Set InpResetHalt=true to resume.");

   RecoverState();
   g_ready = true;
   Logger::Info(StringFormat("Initialized. symbol=%s magic=%I64d", _Symbol, InpMagic));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   RiskManager::Save();
   Logger::Info(StringFormat("EA deinitialized, reason: %d", reason));
}

void OnTick()
{
   if(!g_ready) return;

   // 1) risk ก่อนเสมอ
   RiskManager::UpdatePeak();
   if(RiskManager::IsHalted())
   {
      if(HasExposure()) CloseAll("halted (max DD)");
      return;
   }
   if(RiskManager::IsDrawdownExceeded(InpMaxDDPercent))
   {
      Logger::Error(StringFormat("MAX DRAWDOWN exceeded: %.2f%% >= %.2f%% -> close all and halt",
                                 RiskManager::GetCurrentDrawdown(), InpMaxDDPercent));
      CloseAll("max drawdown");
      RiskManager::SetHalted(true);
      EndRound("max drawdown", false);
      return;
   }
   if(RiskManager::IsDailyLossLimitExceeded(InpDailyLossPercent))
   {
      if(HasExposure() && InpDailyCloseAll)
      {
         Logger::Error(StringFormat("DAILY LOSS limit hit (pnl=%.2f) -> close all", RiskManager::GetDailyPnL()));
         CloseAll("daily loss");
         if(g_round != 0) EndRound("daily loss", false);
      }
      else if(g_round != 0 && !InpDailyCloseAll)
      {
         DeleteAllPendings("daily loss");
         EndRound("daily loss (pendings removed)", false);
      }
      return;   // ไม่เปิดรอบใหม่จนกว่าจะถึงวันถัดไป
   }

   // 2) จัดการ Runner / รอบปัจจุบัน
   ManageRunners();
   ManageRound();

   // 3) หาสัญญาณใหม่เมื่อ IDLE
   if(g_round == 0)
      TryNewRound();
}

//--- log ทุก deal; ถ้าไม้ non-runner ชน TP ให้ mark รอบเพื่อ arm breakeven ของ Runner
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   long   entry  = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   long   reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
   long   dtype  = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   double vol    = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   double price  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   string cmt    = HistoryDealGetString(trans.deal, DEAL_COMMENT);
   ulong  posId  = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);

   Logger::Trade(StringFormat("DEAL %s %s vol=%.2f price=%.5f profit=%.2f reason=%s pos=%I64u [%s]",
                              EnumToString((ENUM_DEAL_ENTRY)entry), EnumToString((ENUM_DEAL_TYPE)dtype),
                              vol, price, profit, EnumToString((ENUM_DEAL_REASON)reason), posId, cmt));

   if(entry == DEAL_ENTRY_OUT && reason == DEAL_REASON_TP)
   {
      bool rn;
      long r = RoundOfPosition(posId, rn);
      if(r > 0 && !rn) MarkTPRound(r);
   }
}
//+------------------------------------------------------------------+
