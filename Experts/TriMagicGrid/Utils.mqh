//+------------------------------------------------------------------+
//| Utils.mqh                                                        |
//| TriMagicGrid EA                                                  |
//| Version: 1.0.0                                                   |
//| Created: 2026.06.07                                              |
//+------------------------------------------------------------------+
#pragma once

//+------------------------------------------------------------------+
//| Convert a points value to a price difference for the symbol      |
//| Parameters: symbol — trading symbol; points — number of points   |
//| Returns: price difference (points * point size)                  |
//+------------------------------------------------------------------+
double PointsToPrice(string symbol, double points)
{
   double pointSize = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(pointSize <= 0.0)
   {
      Print("Utils::PointsToPrice — invalid point size for ", symbol);
      return 0.0;
   }
   return points * pointSize;
}

//+------------------------------------------------------------------+
//| Convert a price difference to points for the symbol             |
//| Parameters: symbol — trading symbol; priceDiff — price distance  |
//| Returns: number of points                                        |
//+------------------------------------------------------------------+
double PriceToPoints(string symbol, double priceDiff)
{
   double pointSize = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(pointSize <= 0.0)
   {
      Print("Utils::PriceToPoints — invalid point size for ", symbol);
      return 0.0;
   }
   return priceDiff / pointSize;
}

//+------------------------------------------------------------------+
//| Normalize lot size to the symbol's volume step and limits        |
//| Parameters: symbol — trading symbol; lot — raw lot value         |
//| Returns: normalized lot size clamped to broker limits            |
//+------------------------------------------------------------------+
double NormalizeLot(string symbol, double lot)
{
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0.0) lotStep = 0.01;

   // Round to nearest step
   lot = MathRound(lot / lotStep) * lotStep;

   // Clamp to broker limits
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);

   return lot;
}

//+------------------------------------------------------------------+
//| Check whether current server time is within trading hours        |
//| Parameters: startHour — hour to start (0-23);                    |
//|             endHour   — hour to end (0-23, exclusive)            |
//| Returns: true if server hour is within [startHour, endHour)      |
//+------------------------------------------------------------------+
bool IsWithinTradingHours(int startHour, int endHour)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;

   if(startHour <= endHour)
      return (hour >= startHour && hour < endHour);
   else
      // Overnight session, e.g. 22 to 6
      return (hour >= startHour || hour < endHour);
}

//+------------------------------------------------------------------+
//| Convert a magic-id index to a human-readable string             |
//| Parameters: magicId — 0=M1, 1=M3, 2=M2                          |
//| Returns: "M1", "M3", "M2", or "UNKNOWN"                         |
//+------------------------------------------------------------------+
string MagicIdToString(int magicId)
{
   switch(magicId)
   {
      case 0:  return "M1";
      case 1:  return "M3";
      case 2:  return "M2";
      default: return "UNKNOWN";
   }
}
