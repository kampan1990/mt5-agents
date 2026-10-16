//+------------------------------------------------------------------+
//|                                                     Strategy.mqh |
//|  EMA 20/50/200 trend + pullback / crossover signal logic         |
//|  Port of EMA_Trend_Pullback_Dashboard indicator.                 |
//|  Evaluated on the last CLOSED bar (shift 1) -> no repaint.       |
//+------------------------------------------------------------------+
#ifndef EMATP_STRATEGY_MQH
#define EMATP_STRATEGY_MQH

enum ENUM_SIG_MODE   { SIG_PULLBACK = 0, SIG_CROSS = 1, SIG_BOTH = 2 };
enum ENUM_ENTRY_MODE { ENTRY_RECLAIM = 0, ENTRY_BREAK_PREV = 1 };

struct SStrategyParams
  {
   int               emaFast, emaMid, emaSlow;
   int               atrPeriod, adxPeriod;
   ENUM_SIG_MODE     sigMode;
   ENUM_ENTRY_MODE   entryMode;
   int               pullbackBars;
   double            maxDist;        // x ATR
   double            crossGap;       // x ATR
   bool              crossNeedDist;  // apply maxDist to CROSS signals too
   bool              useHtf;
   ENUM_TIMEFRAMES   htf;
   int               htfFast, htfSlow;
   bool              useSlope;
   int               slopeBars;
   double            slopeMult;      // x ATR
   bool              useAdx;
   double            adxMin;
   bool              useCross;
   int               crossLookback;
   int               maxCrosses;
   int               swingBars;      // swing high/low look-back for SL
  };

//--- result of evaluating the last closed bar
struct SSignal
  {
   datetime          barTime;        // open time of the evaluated (closed) bar
   int               dir;            // final signal +1 / -1 / 0
   int               type;           // 1 PB, 2 CROSS, 3 both
   int               trend;          // bias +1 / -1 / 0
   int               htf;            // HTF bias +1 / -1 / 0
   double            atr, adx, slope, dist;
   int               crosses;
   int               crossSig;
   bool              htfOk, slopeOk, adxOk, crossOk, distOk;
   bool              touch, pbTrig;
   double            close1, emaF1, emaM1, emaS1;
   double            swingLow, swingHigh;
  };

class CStrategy
  {
private:
   string            m_sym;
   ENUM_TIMEFRAMES   m_tf;
   SStrategyParams   m_p;
   int               m_hF, m_hM, m_hS, m_hAtr, m_hAdx, m_hHF, m_hHS;
   int               m_need;          // bars copied per evaluation
   MqlRates          m_rates[];
   double            m_f[], m_m[], m_s[], m_atr[], m_adx[];

public:
                     CStrategy();
                    ~CStrategy() { Release(); }
   bool              Init(const string sym, const ENUM_TIMEFRAMES tf, const SStrategyParams &p, string &err);
   void              Release();
   bool              Evaluate(SSignal &r);
   static string     TypeText(const int t);
  };

//+------------------------------------------------------------------+
CStrategy::CStrategy() : m_sym(""), m_tf(PERIOD_CURRENT),
   m_hF(INVALID_HANDLE), m_hM(INVALID_HANDLE), m_hS(INVALID_HANDLE),
   m_hAtr(INVALID_HANDLE), m_hAdx(INVALID_HANDLE), m_hHF(INVALID_HANDLE), m_hHS(INVALID_HANDLE),
   m_need(0)
  {
  }

//+------------------------------------------------------------------+
bool CStrategy::Init(const string sym, const ENUM_TIMEFRAMES tf, const SStrategyParams &p, string &err)
  {
   m_sym = sym;
   m_tf  = tf;
   m_p   = p;

   if(p.emaFast <= 0 || p.emaMid <= 0 || p.emaSlow <= 0 || p.atrPeriod <= 0 || p.adxPeriod <= 0)
     { err = "EMA/ATR/ADX periods must be > 0"; return false; }
   if(!(p.emaFast < p.emaMid && p.emaMid < p.emaSlow))
     { err = "EMA periods must satisfy Fast < Mid < Slow"; return false; }
   if(p.pullbackBars < 1 || p.slopeBars < 1 || p.crossLookback < 1 || p.swingBars < 1)
     { err = "Look-back bars must be >= 1"; return false; }
   if(p.useHtf && PeriodSeconds(p.htf) <= PeriodSeconds(tf))
     { err = "HTF must be higher than the chart timeframe"; return false; }

   m_hF   = iMA(sym, tf, p.emaFast, 0, MODE_EMA, PRICE_CLOSE);
   m_hM   = iMA(sym, tf, p.emaMid,  0, MODE_EMA, PRICE_CLOSE);
   m_hS   = iMA(sym, tf, p.emaSlow, 0, MODE_EMA, PRICE_CLOSE);
   m_hAtr = iATR(sym, tf, p.atrPeriod);
   m_hAdx = iADX(sym, tf, p.adxPeriod);
   if(m_hF == INVALID_HANDLE || m_hM == INVALID_HANDLE || m_hS == INVALID_HANDLE ||
      m_hAtr == INVALID_HANDLE || m_hAdx == INVALID_HANDLE)
     { err = StringFormat("cannot create indicator handles, error %d", GetLastError()); return false; }
   if(p.useHtf)
     {
      m_hHF = iMA(sym, p.htf, p.htfFast, 0, MODE_EMA, PRICE_CLOSE);
      m_hHS = iMA(sym, p.htf, p.htfSlow, 0, MODE_EMA, PRICE_CLOSE);
      if(m_hHF == INVALID_HANDLE || m_hHS == INVALID_HANDLE)
        { err = StringFormat("cannot create HTF handles, error %d", GetLastError()); return false; }
     }

   //--- highest index used in Evaluate() is 1 + max(look-backs) + 1
   m_need = MathMax(MathMax(p.crossLookback, p.pullbackBars), MathMax(MathMax(p.slopeBars, p.swingBars), 2)) + 3;

   ArraySetAsSeries(m_rates, true);
   ArraySetAsSeries(m_f, true);
   ArraySetAsSeries(m_m, true);
   ArraySetAsSeries(m_s, true);
   ArraySetAsSeries(m_atr, true);
   ArraySetAsSeries(m_adx, true);
   return true;
  }

//+------------------------------------------------------------------+
void CStrategy::Release()
  {
   int hs[7];
   hs[0] = m_hF; hs[1] = m_hM; hs[2] = m_hS; hs[3] = m_hAtr; hs[4] = m_hAdx; hs[5] = m_hHF; hs[6] = m_hHS;
   for(int k = 0; k < 7; k++)
      if(hs[k] != INVALID_HANDLE)
         IndicatorRelease(hs[k]);
   m_hF = m_hM = m_hS = m_hAtr = m_hAdx = m_hHF = m_hHS = INVALID_HANDLE;
  }

//+------------------------------------------------------------------+
//| Evaluate every condition on the last closed bar (series index 1).|
//| Returns false when data is not ready (caller must not trade).    |
//+------------------------------------------------------------------+
bool CStrategy::Evaluate(SSignal &r)
  {
   ZeroMemory(r);
   if(m_hF == INVALID_HANDLE)
      return false;
   if(Bars(m_sym, m_tf) < m_p.emaSlow + m_need + 10)
      return false;
   if(CopyRates(m_sym, m_tf, 0, m_need, m_rates) < m_need)        return false;
   if(CopyBuffer(m_hF,   0, 0, m_need, m_f)   < m_need)           return false;
   if(CopyBuffer(m_hM,   0, 0, m_need, m_m)   < m_need)           return false;
   if(CopyBuffer(m_hS,   0, 0, m_need, m_s)   < m_need)           return false;
   if(CopyBuffer(m_hAtr, 0, 0, m_need, m_atr) < m_need)           return false;
   if(CopyBuffer(m_hAdx, 0, 0, m_need, m_adx) < m_need)           return false;   // buffer 0 = MAIN_LINE

   const int    s = 1;              // last closed bar
   const double c = m_rates[s].close;
   r.barTime = m_rates[s].time;
   r.close1  = c;
   r.emaF1   = m_f[s];
   r.emaM1   = m_m[s];
   r.emaS1   = m_s[s];
   r.atr     = m_atr[s];
   r.adx     = m_adx[s];
   if(r.atr <= 0.0)
      return false;

   //--- trend bias (EMA200 + EMA50 vs EMA200)
   if(c > m_s[s] && m_m[s] > m_s[s])
      r.trend = 1;
   else
      if(c < m_s[s] && m_m[s] < m_s[s])
         r.trend = -1;

   //--- HTF bias from the last CLOSED higher-TF bar (no look-ahead)
   if(m_p.useHtf)
     {
      int    sh = iBarShift(m_sym, m_p.htf, r.barTime, false);
      double hf[1], hs[1];
      if(sh < 0 || CopyBuffer(m_hHF, 0, sh + 1, 1, hf) != 1 || CopyBuffer(m_hHS, 0, sh + 1, 1, hs) != 1 ||
         hf[0] == EMPTY_VALUE || hs[0] == EMPTY_VALUE || hf[0] == 0.0 || hs[0] == 0.0)
         return false;
      r.htf = (hf[0] > hs[0]) ? 1 : (hf[0] < hs[0] ? -1 : 0);
     }

   //--- EMA50 slope over N bars in ATR units
   r.slope = (m_m[s] - m_m[s + m_p.slopeBars]) / r.atr;

   //--- sideways: count close crossing EMA50 in the look-back window
   int cnt = 0;
   for(int j = s; j < s + m_p.crossLookback; j++)
     {
      double a = m_rates[j + 1].close - m_m[j + 1];
      double b = m_rates[j].close     - m_m[j];
      if(a * b < 0)
         cnt++;
     }
   r.crosses = cnt;

   //--- distance from EMA20 (signed, in ATR)
   r.dist = (c - m_f[s]) / r.atr;

   //--- EMA20/EMA50 crossover: cross on bar s+1, confirmed on bar s, gap >= x ATR
   bool up = m_f[s + 2] <= m_m[s + 2] && m_f[s + 1] > m_m[s + 1] && m_f[s] > m_m[s];
   bool dn = m_f[s + 2] >= m_m[s + 2] && m_f[s + 1] < m_m[s + 1] && m_f[s] < m_m[s];
   if(MathAbs(m_f[s] - m_m[s]) >= m_p.crossGap * r.atr)
      r.crossSig = up ? 1 : (dn ? -1 : 0);

   //--- swing extremes for SL (last N closed bars)
   r.swingLow  = m_rates[s].low;
   r.swingHigh = m_rates[s].high;
   for(int k = s; k < s + m_p.swingBars; k++)
     {
      r.swingLow  = MathMin(r.swingLow,  m_rates[k].low);
      r.swingHigh = MathMax(r.swingHigh, m_rates[k].high);
     }

   //--- direction dependent checks
   const int d = r.trend;
   if(d == 0)
      return true;

   r.htfOk   = !m_p.useHtf   || r.htf == d;
   r.slopeOk = !m_p.useSlope || (d == 1 ? r.slope >= m_p.slopeMult : r.slope <= -m_p.slopeMult);
   r.adxOk   = !m_p.useAdx   || r.adx >= m_p.adxMin;
   r.crossOk = !m_p.useCross || r.crosses < m_p.maxCrosses;
   r.distOk  = d * r.dist <= m_p.maxDist;

   //--- pullback touch of EMA20 within the previous N bars
   for(int j = s + 1; j <= s + m_p.pullbackBars; j++)
     {
      if(d == 1 ? m_rates[j].low <= m_f[j] : m_rates[j].high >= m_f[j])
        {
         r.touch = true;
         break;
        }
     }

   //--- pullback trigger
   bool holdZone = (d == 1) ? c > m_m[s] : c < m_m[s];   // pullback must hold above/below EMA50
   bool trig;
   if(m_p.entryMode == ENTRY_RECLAIM)
      trig = (d == 1) ? (m_rates[s + 1].close <= m_f[s + 1] && c > m_f[s])
             : (m_rates[s + 1].close >= m_f[s + 1] && c < m_f[s]);
   else
      trig = (d == 1) ? (c > m_rates[s + 1].high && c > m_f[s])
             : (c < m_rates[s + 1].low  && c < m_f[s]);
   r.pbTrig = r.touch && holdZone && trig;

   //--- final signal (market filters: session/spread/ATR are applied by the EA at entry)
   bool base = r.htfOk && r.slopeOk && r.adxOk && r.crossOk;
   bool pb   = (m_p.sigMode != SIG_CROSS)    && r.pbTrig && r.distOk;
   bool cx   = (m_p.sigMode != SIG_PULLBACK) && r.crossSig == d && (!m_p.crossNeedDist || r.distOk);
   if(base && (pb || cx))
     {
      r.dir  = d;
      r.type = (pb ? 1 : 0) + (cx ? 2 : 0);
     }
   return true;
  }

//+------------------------------------------------------------------+
string CStrategy::TypeText(const int t)
  {
   if(t == 1) return "PB";
   if(t == 2) return "CROSS";
   if(t == 3) return "PB+CROSS";
   return "-";
  }

#endif
//+------------------------------------------------------------------+
