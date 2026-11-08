//+------------------------------------------------------------------+
//| Features.mqh - Layer 1-2: ดึงแท่ง M5 แล้วคำนวณ feature            |
//| ต้องตรงกับ research/features.py และ research/config.py เป๊ะ        |
//| ลำดับ: ema_fast_dist, ema_slow_dist, ema_slope, body_ratio,        |
//|  upper_wick, lower_wick, consec, range_pos, pullback_depth,       |
//|  vol_regime, momentum, hour_sin, hour_cos, spread_atr             |
//+------------------------------------------------------------------+
#property strict

#define FEATURE_COUNT   14
#define FEATURE_VERSION 1
#define F_EMA_FAST 20
#define F_EMA_SLOW 50
#define F_ATR_FAST 14
#define F_ATR_SLOW 50
#define F_RANGE_N  20
#define F_SLOPE_N  5
#define F_MOM_N    10
#define F_CONSEC   6
#define F_BARS     400      // แท่งที่ดึง (ใหม่สุด = แท่งที่ปิดล่าสุด shift 1)

struct SFeatureSet
{
   float  v[FEATURE_COUNT];
   double atr;        // ATR14 (หน่วยราคา)
   double spreadPts;  // spread ของแท่งตัดสินใจ (points)
   int    hour;       // ชั่วโมงเวลาเซิร์ฟเวอร์ของแท่ง
};

class CFeatures
{
private:
   string          m_sym;
   ENUM_TIMEFRAMES m_tf;

   double TrueRange(const MqlRates &r[], const int i)
   {
      if(i == 0) return r[0].high - r[0].low;
      double pc = r[i - 1].close;
      return MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - pc), MathAbs(r[i].low - pc)));
   }
   double AtrSMA(const MqlRates &r[], const int last, const int n)
   {
      double s = 0;
      for(int i = last - n + 1; i <= last; i++) s += TrueRange(r, i);
      return s / n;
   }

public:
   void Init(const string sym, const ENUM_TIMEFRAMES tf) { m_sym = sym; m_tf = tf; }

   bool Compute(SFeatureSet &out)
   {
      MqlRates r[];
      ArraySetAsSeries(r, false);                       // index 0 = เก่าสุด
      if(CopyRates(m_sym, m_tf, 1, F_BARS, r) != F_BARS) { LogError("CopyRates"); return false; }
      int L = F_BARS - 1;

      // EMA แบบ ewm(adjust=False) เริ่มจาก close แท่งแรก
      double kf = 2.0 / (F_EMA_FAST + 1), ks = 2.0 / (F_EMA_SLOW + 1);
      double ef = r[0].close, es = r[0].close, ef_prev = 0;
      for(int i = 1; i <= L; i++)
      {
         ef = kf * r[i].close + (1 - kf) * ef;
         es = ks * r[i].close + (1 - ks) * es;
         if(i == L - F_SLOPE_N) ef_prev = ef;
      }
      double atr = AtrSMA(r, L, F_ATR_FAST), atrS = AtrSMA(r, L, F_ATR_SLOW);
      if(atr <= 0 || atrS <= 0) return false;

      double o = r[L].open, h = r[L].high, l = r[L].low, c = r[L].close;
      double rng = h - l;
      double body = 0, up = 0, lo = 0;
      if(rng > 0)
      {
         body = (c - o) / rng;
         up   = (h - MathMax(o, c)) / rng;
         lo   = (MathMin(o, c) - l) / rng;
      }
      int consec = 0;
      if(c != o)
      {
         bool green = (c > o);
         for(int i = L; i >= 0 && MathAbs(consec) < F_CONSEC; i--)
         {
            if((r[i].close > r[i].open) == green && r[i].close != r[i].open) consec += green ? 1 : -1;
            else break;
         }
      }
      double hh = -DBL_MAX, ll = DBL_MAX;
      for(int i = L - F_RANGE_N + 1; i <= L; i++) { hh = MathMax(hh, r[i].high); ll = MathMin(ll, r[i].low); }
      double rpos = (hh > ll) ? (c - ll) / (hh - ll) : 0.5;

      MqlDateTime dt;
      TimeToStruct(r[L].time, dt);
      double hr = dt.hour + dt.min / 60.0;

      out.v[0]  = (float)((c - ef) / atr);
      out.v[1]  = (float)((c - es) / atr);
      out.v[2]  = (float)((ef - ef_prev) / atr);
      out.v[3]  = (float)body;
      out.v[4]  = (float)up;
      out.v[5]  = (float)lo;
      out.v[6]  = (float)consec;
      out.v[7]  = (float)rpos;
      out.v[8]  = (float)((hh - c) / atr);
      out.v[9]  = (float)(atr / atrS);
      out.v[10] = (float)((c - r[L - F_MOM_N].close) / atr);
      out.v[11] = (float)MathSin(2 * M_PI * hr / 24.0);
      out.v[12] = (float)MathCos(2 * M_PI * hr / 24.0);
      out.v[13] = (float)(r[L].spread * _Point / atr);
      out.atr = atr;
      out.spreadPts = (double)r[L].spread;
      out.hour = dt.hour;
      return true;
   }
};
