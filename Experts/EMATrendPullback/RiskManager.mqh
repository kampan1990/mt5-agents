//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|  SL/TP construction, % risk lot sizing, max drawdown & daily     |
//|  loss guards. Every order must have SL and TP (project rule).    |
//+------------------------------------------------------------------+
#ifndef EMATP_RISKMANAGER_MQH
#define EMATP_RISKMANAGER_MQH

#include "Logger.mqh"
#include "Utils.mqh"

enum ENUM_SL_MODE
  {
   SL_ATR   = 0,   // ATR x multiplier
   SL_SWING = 1,   // Swing high/low + buffer
   SL_WIDER = 2    // Wider of ATR / Swing
  };

struct SRiskParams
  {
   double            riskPct;        // % of balance risked per trade
   ENUM_SL_MODE      slMode;
   double            slAtr;          // SL = x ATR
   double            swingBufAtr;    // buffer beyond swing (x ATR)
   double            rr;             // TP = rr x SL distance
   double            minSlPts;       // 0 = off
   double            maxSlPts;       // 0 = off (trade skipped if SL wider)
   double            maxLot;         // 0 = broker max
   double            maxDDPct;       // equity drawdown from peak -> halt EA (0 = off)
   double            dailyLossPct;   // loss from day-start balance -> stop for the day (0 = off)
   bool              resetOnStart;   // clear stored peak / halt flag on init
  };

class CRiskManager
  {
private:
   string            m_sym;
   long              m_magic;
   SRiskParams       m_p;
   CLogger          *m_log;
   double            m_peak;
   double            m_dayStart;
   int               m_dayKey;
   bool              m_halted;
   bool              m_dailyBlocked;
   string            m_gvPeak, m_gvHalt;

   void              LogMsg(const ENUM_LOGLV lv, const string msg)
     {
      if(CheckPointer(m_log) != POINTER_INVALID)
         m_log.Write(lv, msg);
      else
         Print(msg);
     }

public:
                     CRiskManager() : m_sym(""), m_magic(0), m_log(NULL), m_peak(0), m_dayStart(0),
                     m_dayKey(-1), m_halted(false), m_dailyBlocked(false) {}

   bool              Init(const string sym, const long magic, const SRiskParams &p, CLogger *log, string &err);
   void              Update();
   bool              CanOpen(string &why) const;
   bool              IsHalted() const          { return m_halted; }
   double            CurrentDDPct() const;
   double            DailyLossPct() const;
   bool              BuildStops(const int dir, const double entry, const double atr,
                                const double swingLow, const double swingHigh,
                                double &sl, double &tp, string &why) const;
   double            CalcLot(const int dir, const double entry, const double sl, string &why) const;
  };

//+------------------------------------------------------------------+
bool CRiskManager::Init(const string sym, const long magic, const SRiskParams &p, CLogger *log, string &err)
  {
   m_sym   = sym;
   m_magic = magic;
   m_p     = p;
   m_log   = log;

   if(p.riskPct <= 0 || p.riskPct > 10)  { err = "Risk % must be in (0, 10]"; return false; }
   if(p.slAtr <= 0)                       { err = "SL ATR multiplier must be > 0"; return false; }
   if(p.rr <= 0)                          { err = "Risk:Reward must be > 0"; return false; }
   if(p.maxDDPct < 0 || p.dailyLossPct < 0) { err = "Drawdown limits must be >= 0"; return false; }

   string base = "ETP_" + sym + "_" + IntegerToString(magic);
   m_gvPeak = base + "_peak";
   m_gvHalt = base + "_halt";
   if(p.resetOnStart)
     {
      GlobalVariableDel(m_gvPeak);
      GlobalVariableDel(m_gvHalt);
     }

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   m_peak   = GlobalVariableCheck(m_gvPeak) ? MathMax(GlobalVariableGet(m_gvPeak), eq) : eq;
   m_halted = GlobalVariableCheck(m_gvHalt) && GlobalVariableGet(m_gvHalt) > 0.5;
   GlobalVariableSet(m_gvPeak, m_peak);
   if(m_halted)
      LogMsg(LOGLV_WARN, "EA is HALTED by a previous max-drawdown breach. Set 'Reset DD state on start' = true to resume.");
   Update();
   return true;
  }

//+------------------------------------------------------------------+
//| Call on every tick: tracks equity peak, day roll, DD guards      |
//+------------------------------------------------------------------+
void CRiskManager::Update()
  {
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);

   if(eq > m_peak)
     {
      m_peak = eq;
      GlobalVariableSet(m_gvPeak, m_peak);
     }

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int key = dt.year * 1000 + dt.day_of_year;
   if(key != m_dayKey)
     {
      m_dayKey       = key;
      m_dayStart     = bal;
      m_dailyBlocked = false;
      LogMsg(LOGLV_INFO, StringFormat("New trading day, start balance %.2f", m_dayStart));
     }

   if(!m_halted && m_p.maxDDPct > 0)
     {
      double dd = CurrentDDPct();
      if(dd >= m_p.maxDDPct)
        {
         m_halted = true;
         GlobalVariableSet(m_gvHalt, 1.0);
         LogMsg(LOGLV_ERROR, StringFormat("MAX DRAWDOWN reached: %.2f%% >= %.2f%% (peak %.2f, equity %.2f). EA halted.",
                                          dd, m_p.maxDDPct, m_peak, eq));
        }
     }

   if(!m_dailyBlocked && m_p.dailyLossPct > 0)
     {
      double dl = DailyLossPct();
      if(dl >= m_p.dailyLossPct)
        {
         m_dailyBlocked = true;
         LogMsg(LOGLV_WARN, StringFormat("Daily loss limit reached: %.2f%% >= %.2f%%. No new trades today.",
                                         dl, m_p.dailyLossPct));
        }
     }
  }

//+------------------------------------------------------------------+
double CRiskManager::CurrentDDPct() const
  {
   if(m_peak <= 0)
      return 0.0;
   return MathMax(0.0, (m_peak - AccountInfoDouble(ACCOUNT_EQUITY)) / m_peak * 100.0);
  }

double CRiskManager::DailyLossPct() const
  {
   if(m_dayStart <= 0)
      return 0.0;
   return MathMax(0.0, (m_dayStart - AccountInfoDouble(ACCOUNT_EQUITY)) / m_dayStart * 100.0);
  }

bool CRiskManager::CanOpen(string &why) const
  {
   if(m_halted)       { why = "max drawdown halt"; return false; }
   if(m_dailyBlocked) { why = "daily loss limit"; return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| Build SL/TP for a market order at 'entry'. Returns false (skip)  |
//| when a valid SL cannot be placed. TP = rr x final SL distance.   |
//+------------------------------------------------------------------+
bool CRiskManager::BuildStops(const int dir, const double entry, const double atr,
                              const double swingLow, const double swingHigh,
                              double &sl, double &tp, string &why) const
  {
   sl = 0.0;
   tp = 0.0;
   if(dir != 1 && dir != -1) { why = "invalid direction"; return false; }
   if(atr <= 0 || entry <= 0) { why = "invalid ATR/entry"; return false; }

   const double point = SymbolInfoDouble(m_sym, SYMBOL_POINT);
   const double slAtrPrice = entry - dir * m_p.slAtr * atr;
   const double buf        = m_p.swingBufAtr * atr;
   double       slSwing    = (dir == 1) ? swingLow - buf : swingHigh + buf;
   bool         swingValid = (dir == 1) ? slSwing < entry : slSwing > entry;

   switch(m_p.slMode)
     {
      case SL_SWING:
         sl = swingValid ? slSwing : slAtrPrice;
         break;
      case SL_WIDER:
         sl = !swingValid ? slAtrPrice : (dir == 1 ? MathMin(slAtrPrice, slSwing) : MathMax(slAtrPrice, slSwing));
         break;
      default:
         sl = slAtrPrice;
     }

   double dist = MathAbs(entry - sl);

   //--- min / max SL in points
   if(m_p.minSlPts > 0 && dist < m_p.minSlPts * point)
      dist = m_p.minSlPts * point;
   if(m_p.maxSlPts > 0 && dist > m_p.maxSlPts * point)
     {
      why = StringFormat("SL %.0f pts > max %.0f pts", dist / point, m_p.maxSlPts);
      return false;
     }

   //--- broker stops level (+1 point safety)
   double stopLvl = (double)SymbolInfoInteger(m_sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
   if(dist <= stopLvl)
      dist = stopLvl + point;
   if(m_p.rr * dist <= stopLvl)
     {
      why = "TP distance below broker stops level";
      return false;
     }

   sl = NormalizeToTick(m_sym, entry - dir * dist);
   tp = NormalizeToTick(m_sym, entry + dir * m_p.rr * dist);
   if(sl <= 0 || tp <= 0)
     {
      why = "computed SL/TP <= 0";
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Lot size so that hitting SL loses riskPct of balance.            |
//| Returns 0 (skip trade) instead of over-risking with min lot.     |
//+------------------------------------------------------------------+
double CRiskManager::CalcLot(const int dir, const double entry, const double sl, string &why) const
  {
   const double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   const double riskMoney = balance * m_p.riskPct / 100.0;
   const ENUM_ORDER_TYPE ot = (dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   //--- loss of 1.0 lot from entry to SL in account currency
   double lossPerLot = 0.0;
   double profit     = 0.0;
   if(OrderCalcProfit(ot, m_sym, 1.0, entry, sl, profit) && profit < 0)
      lossPerLot = -profit;
   else
     {
      double tickVal  = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
      double tickSize = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_SIZE);
      if(tickVal <= 0)
         tickVal = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_VALUE);
      if(tickVal > 0 && tickSize > 0)
         lossPerLot = MathAbs(entry - sl) / tickSize * tickVal;
     }
   if(lossPerLot <= 0)
     {
      why = "cannot compute loss per lot";
      return 0.0;
     }

   const double minVol  = SymbolInfoDouble(m_sym, SYMBOL_VOLUME_MIN);
   const double maxVol  = SymbolInfoDouble(m_sym, SYMBOL_VOLUME_MAX);
   const double step    = SymbolInfoDouble(m_sym, SYMBOL_VOLUME_STEP);
   if(step <= 0)
     {
      why = "invalid volume step";
      return 0.0;
     }

   double lot = riskMoney / lossPerLot;
   lot = MathFloor(lot / step + 1e-9) * step;
   lot = MathMin(lot, maxVol);
   if(m_p.maxLot > 0)
      lot = MathMin(lot, m_p.maxLot);
   lot = NormalizeDouble(lot, VolumeDigits(step));

   if(lot < minVol)
     {
      why = StringFormat("lot %.4f < min %.2f (risk %.2f, loss/lot %.2f) - increase risk or balance",
                         riskMoney / lossPerLot, minVol, riskMoney, lossPerLot);
      return 0.0;
     }

   //--- margin check
   double margin = 0.0;
   if(OrderCalcMargin(ot, m_sym, lot, entry, margin) &&
      margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      why = StringFormat("not enough free margin (need %.2f)", margin);
      return 0.0;
     }
   return lot;
  }

#endif
//+------------------------------------------------------------------+
