//+------------------------------------------------------------------+
//| Utils.mqh                                                         |
//| QTheory EA                                                        |
//| Version: 1.0.0                                                    |
//| Created: 2026.11.03                                               |
//+------------------------------------------------------------------+
#ifndef QT_UTILS_MQH
#define QT_UTILS_MQH

#define QT_SECONDS_PER_MINUTE   60
#define QT_EPS                  1e-9
#define QT_DEFAULT_VOL_STEP     0.01
#define QT_SUNDAY               0
#define QT_SATURDAY             6

namespace Utils
{
   //--- คืนชื่อ symbol ที่ใช้จริง (ว่าง = _Symbol)
   string Sym(const string symbol)
   {
      if(StringLen(symbol) == 0) return _Symbol;
      return symbol;
   }

   //--- ปัดราคาให้ตรง tick size และ digits ของ symbol
   //    price = ราคาดิบ | symbol = ชื่อ symbol (ว่าง = _Symbol) | คืน: ราคาที่ปัดแล้ว
   double NormalizePrice(const double price, const string symbol = "")
   {
      string s     = Sym(symbol);
      int    digits = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
      double tick  = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
      double p     = price;
      if(tick > 0.0)
         p = MathRound(p / tick) * tick;
      return NormalizeDouble(p, digits);
   }

   //--- แปลง "$" (หน่วยราคา x unitSize) เป็นระยะราคาที่ปัดตาม digits
   //    dollars = ระยะเป็น $ | unitSize = ราคากี่หน่วยต่อ $1 (XAUUSD = 1.0) | คืน: ระยะราคา
   double DollarsToPrice(const double dollars, const double unitSize)
   {
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      return NormalizeDouble(dollars * unitSize, digits);
   }

   //--- ระยะขั้นต่ำที่โบรกเกอร์ยอมรับสำหรับ SL/TP/pending (max ของ stops level และ freeze level)
   //    คืน: ระยะเป็นหน่วยราคา
   double StopsDistance(const string symbol = "")
   {
      string s = Sym(symbol);
      long stops  = SymbolInfoInteger(s, SYMBOL_TRADE_STOPS_LEVEL);
      long freeze = SymbolInfoInteger(s, SYMBOL_TRADE_FREEZE_LEVEL);
      double pt   = SymbolInfoDouble(s, SYMBOL_POINT);
      return (double)MathMax(stops, freeze) * pt;
   }

   //--- ปัดขนาด lot ลงตาม step และจำกัด min/max ของโบรกเกอร์
   //    vol = lot ดิบ | คืน: lot ที่ใช้ได้
   double NormalizeVolume(const string symbol, const double vol)
   {
      string s = Sym(symbol);
      double step = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP);
      double vmin = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
      double vmax = SymbolInfoDouble(s, SYMBOL_VOLUME_MAX);
      if(step <= 0.0) step = QT_DEFAULT_VOL_STEP;
      double v = MathFloor(vol / step + QT_EPS) * step;
      v = MathMax(vmin, MathMin(vmax, v));
      int digits = (int)MathMax(0.0, MathRound(-MathLog10(step)));
      return NormalizeDouble(v, digits);
   }

   //--- แปลง "5,10,15" เป็น array ของ double (เฉพาะค่า > 0) เรียงจากน้อยไปมาก
   //    คืน: จำนวนค่าที่ได้
   int ParseDoubleList(const string text, double &out[])
   {
      string parts[];
      int n = StringSplit(text, ',', parts);
      ArrayResize(out, 0);
      for(int i = 0; i < n; i++)
      {
         StringTrimLeft(parts[i]);
         StringTrimRight(parts[i]);
         double v = StringToDouble(parts[i]);
         if(v > 0.0)
         {
            int k = ArraySize(out);
            ArrayResize(out, k + 1);
            out[k] = v;
         }
      }
      if(ArraySize(out) > 1) ArraySort(out);
      return ArraySize(out);
   }

   //--- High/Low ของวันปัจจุบัน (D1 แท่ง 0) | คืน: true ถ้าได้ค่าถูกต้อง
   bool GetDayHighLow(double &low, double &high)
   {
      high = iHigh(_Symbol, PERIOD_D1, 0);
      low  = iLow(_Symbol, PERIOD_D1, 0);
      return (high > 0.0 && low > 0.0 && high >= low);
   }

   //--- Spread ปัจจุบันเป็นหน่วยราคา
   double SpreadPrice(const string symbol = "")
   {
      string s = Sym(symbol);
      return SymbolInfoDouble(s, SYMBOL_ASK) - SymbolInfoDouble(s, SYMBOL_BID);
   }

   //--- Spread ไม่เกินที่กำหนดไหม (maxSpreadPrice เป็นหน่วยราคา, <=0 = ไม่ตรวจ)
   bool IsSpreadAcceptable(const double maxSpreadPrice)
   {
      if(maxSpreadPrice <= 0.0) return true;
      return SpreadPrice() <= maxSpreadPrice + QT_EPS;
   }

   //--- เวลาเซิร์ฟเวอร์อยู่ในช่วงเทรดไหม (ไม่รวมเสาร์-อาทิตย์; start>end = ข้ามเที่ยงคืน)
   bool InSession(const int startHour, const int endHour)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.day_of_week == QT_SUNDAY || dt.day_of_week == QT_SATURDAY) return false;
      if(startHour == endHour) return true;
      if(startHour < endHour) return (dt.hour >= startHour && dt.hour < endHour);
      return (dt.hour >= startHour || dt.hour < endHour);
   }

   //--- 00:00 ของวันนี้ตามเวลาเซิร์ฟเวอร์
   datetime DayStart()
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      return StructToTime(dt);
   }

   //--- filling mode สำหรับ market order ตามที่ symbol รองรับ
   ENUM_ORDER_TYPE_FILLING MarketFilling(const string symbol = "")
   {
      long mode = SymbolInfoInteger(Sym(symbol), SYMBOL_FILLING_MODE);
      if((mode & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
      if((mode & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
      return ORDER_FILLING_RETURN;
   }
}

#endif
