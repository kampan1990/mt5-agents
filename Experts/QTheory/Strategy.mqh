//+------------------------------------------------------------------+
//| Strategy.mqh                                                      |
//| QTheory EA - Raw/Hidden base, Q ladder, TP/SL level builders      |
//| Version: 1.0.0                                                    |
//| Created: 2026.11.03                                               |
//+------------------------------------------------------------------+
#ifndef QT_STRATEGY_MQH
#define QT_STRATEGY_MQH

#include "Utils.mqh"

enum ENUM_SIGNAL { SIGNAL_NONE, SIGNAL_BUY, SIGNAL_SELL };

enum ENUM_QT_TPMODE
{
   QT_TP_BACK_TO_P0 = 0,   // 0: TP ทุกไม้กลับมาที่ P0
   QT_TP_FIXED      = 1,   // 1: TP = entry +/- fixed $
   QT_TP_NEXT_BASE  = 2    // 2: TP = base ถัดไปในทิศกำไร
};

#define QT_MID_DIVISOR      2.0    // mid = block / 2
#define QT_BASE_DIVISOR     4.0    // lattice step = block / 4 (00,25,50,75)

//--- พารามิเตอร์ของตัวสร้างสัญญาณ (หน่วยเป็นหน่วยราคาแล้ว)
struct SSignalParams
{
   double blockSize;      // ขนาด block (100)
   double hiddenShift;    // Hidden = Raw - shift (20)
   double midTolerance;   // ระยะจาก mid ที่ยอมรับ
   double dayEdge;        // กันขอบ H/L ของวัน (0 = แค่อยู่ในช่วง)
   bool   useRaw;
   bool   useHidden;
   bool   requireBoth;    // ทั้งสองชุดต้องชี้ทิศเดียวกัน
   bool   useDayRange;
};

namespace Strategy
{
   //--- เริ่มต้นของ block 100 ที่ครอบราคา: floor(price/block)*block
   double BlockStart(const double price, const double blockSize)
   {
      return MathFloor(price / blockSize + QT_EPS) * blockSize;
   }

   //--- เส้นกลาง Raw (block+50)
   double RawMid(const double price, const double blockSize)
   {
      return BlockStart(price, blockSize) + blockSize / QT_MID_DIVISOR;
   }

   //--- เส้นกลาง Hidden = Raw - shift โดยปรับ block ให้ครอบราคาที่เลื่อนแล้ว
   //    ตัวอย่าง 4460, shift 20 -> block เริ่ม 4380, mid 4430
   double HiddenMid(const double price, const double blockSize, const double shift)
   {
      return BlockStart(price + shift, blockSize) + blockSize / QT_MID_DIVISOR - shift;
   }

   //--- ทิศจากราคาเทียบ mid: เหนือ mid = SELL, นอกนั้น BUY
   ENUM_SIGNAL SideOf(const double price, const double mid)
   {
      return (price > mid) ? SIGNAL_SELL : SIGNAL_BUY;
   }

   //--- ประเมินสัญญาณจากราคาล้วน ๆ (ไม่แตะ global)
   //    price = ราคา | dayLow/dayHigh = L/H ของวัน | p = พารามิเตอร์ | คืน: SIGNAL_*
   ENUM_SIGNAL Evaluate(const double price, const double dayLow, const double dayHigh,
                        const SSignalParams &p)
   {
      if(!p.useRaw && !p.useHidden) return SIGNAL_NONE;
      if(p.blockSize <= 0.0) return SIGNAL_NONE;

      if(p.useDayRange)
      {
         if(dayLow <= 0.0 || dayHigh <= 0.0) return SIGNAL_NONE;
         if(price < dayLow + p.dayEdge - QT_EPS) return SIGNAL_NONE;
         if(price > dayHigh - p.dayEdge + QT_EPS) return SIGNAL_NONE;
      }

      double rawMid = RawMid(price, p.blockSize);
      double hidMid = HiddenMid(price, p.blockSize, p.hiddenShift);
      ENUM_SIGNAL rawSide = SideOf(price, rawMid);
      ENUM_SIGNAL hidSide = SideOf(price, hidMid);
      bool nearRaw = (MathAbs(price - rawMid) <= p.midTolerance + QT_EPS);
      bool nearHid = (MathAbs(price - hidMid) <= p.midTolerance + QT_EPS);

      if(p.useRaw && p.useHidden)
      {
         if(p.requireBoth)
            return (rawSide == hidSide && nearRaw) ? rawSide : SIGNAL_NONE;
         if(nearRaw) return rawSide;
         if(nearHid) return hidSide;
         return SIGNAL_NONE;
      }
      if(p.useRaw)    return nearRaw ? rawSide : SIGNAL_NONE;
      return nearHid ? hidSide : SIGNAL_NONE;
   }

   //--- สร้างราคา ladder: Sell = P0 + off, Buy = P0 - off (off x unit)
   //    คืน: จำนวน level
   int BuildLadder(const ENUM_SIGNAL side, const double p0, const double &offsets[],
                   const double unit, double &levels[])
   {
      int n = ArraySize(offsets);
      ArrayResize(levels, n);
      for(int i = 0; i < n; i++)
      {
         double d = offsets[i] * unit;
         levels[i] = Utils::NormalizePrice((side == SIGNAL_SELL) ? p0 + d : p0 - d);
      }
      return n;
   }

   //--- SL ร่วม = P0 +/- (offset ไกลสุด x unit + buffer) | buffer เป็นหน่วยราคาแล้ว
   double SharedSL(const ENUM_SIGNAL side, const double p0, const double &offsets[],
                   const double unit, const double buffer)
   {
      int n = ArraySize(offsets);
      if(n <= 0) return 0.0;
      double farOff = offsets[n - 1] * unit;
      for(int i = 0; i < n; i++)
         if(offsets[i] * unit > farOff) farOff = offsets[i] * unit;
      return Utils::NormalizePrice((side == SIGNAL_SELL) ? p0 + farOff + buffer : p0 - farOff - buffer);
   }

   //--- base ถัดไปในทิศกำไรที่ห่างจาก entry อย่างน้อย minDist
   //    lattice step = block/4 ; origin 0 = Raw, -shift = Hidden
   double NextBase(const double entry, const ENUM_SIGNAL side, const double minDist,
                   const double blockSize, const double origin)
   {
      double step = blockSize / QT_BASE_DIVISOR;
      if(side == SIGNAL_SELL)
      {
         double k = MathFloor((entry - minDist - origin) / step + QT_EPS);
         return Utils::NormalizePrice(origin + k * step);
      }
      double k2 = MathCeil((entry + minDist - origin) / step - QT_EPS);
      return Utils::NormalizePrice(origin + k2 * step);
   }

   //--- TP ปกติของแต่ละ level ตาม mode (fixedDist/minDist เป็นหน่วยราคาแล้ว)
   double LevelTP(const ENUM_QT_TPMODE mode, const ENUM_SIGNAL side, const double p0,
                  const double entry, const double fixedDist, const double minDist,
                  const double blockSize, const double origin)
   {
      switch(mode)
      {
         case QT_TP_FIXED:
            return Utils::NormalizePrice((side == SIGNAL_SELL) ? entry - fixedDist : entry + fixedDist);
         case QT_TP_NEXT_BASE:
            return NextBase(entry, side, minDist, blockSize, origin);
         case QT_TP_BACK_TO_P0:
         default:
            return Utils::NormalizePrice(p0);
      }
      return Utils::NormalizePrice(p0);
   }
}

#endif
