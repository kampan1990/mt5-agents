//+------------------------------------------------------------------+
//| Utils.mqh - Helper functions                                      |
//+------------------------------------------------------------------+
#property strict

// ปัดขนาด lot ให้ตรง step/min/max ของโบรกเกอร์
double NormalizeVolume(const string sym, double vol)
{
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   vol = MathFloor(vol / step + 1e-9) * step;
   vol = MathMax(vmin, MathMin(vmax, vol));
   int digits = (int)MathMax(0, MathRound(-MathLog10(step)));
   return NormalizeDouble(vol, digits);
}

// แปลง "0.01,0.01,0.01,0.02" -> array ของ lot
int ParseLotSequence(const string s, double &out[])
{
   string parts[];
   int n = StringSplit(s, ',', parts);
   ArrayResize(out, 0);
   for(int i = 0; i < n; i++)
   {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      double v = StringToDouble(parts[i]);
      if(v > 0)
      {
         int k = ArraySize(out);
         ArrayResize(out, k + 1);
         out[k] = v;
      }
   }
   return ArraySize(out);
}

// หยิบข้อความหลัง "key" จนถึงตัวคั่น (; , " \ ช่องว่าง)
string TokenAfter(const string text, const string key)
{
   int p = StringFind(text, key);
   if(p < 0) return "";
   p += StringLen(key);
   string res = "";
   for(int i = p; i < StringLen(text); i++)
   {
      ushort c = StringGetCharacter(text, i);
      if(c == ';' || c == ',' || c == '"' || c == '\\' || c == ' ' || c == '}' || c == '\n' || c == '\r')
         break;
      res += ShortToString(c);
   }
   return res;
}

string JsonEscape(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\r", "");
   StringReplace(s, "\n", "\\n");
   return s;
}
