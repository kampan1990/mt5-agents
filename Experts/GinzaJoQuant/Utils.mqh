//+------------------------------------------------------------------+
//| Utils.mqh - helper                                                |
//+------------------------------------------------------------------+
#property strict

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

datetime DayStart()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}
