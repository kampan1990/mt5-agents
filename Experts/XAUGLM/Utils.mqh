//+------------------------------------------------------------------+
//| Utils.mqh                                                        |
//| XAUGLM EA — Shared primitives (no internal dependency)           |
//| Version: 1.0.0                                                   |
//| Created: 2026-08-16                                              |
//+------------------------------------------------------------------+
#pragma once

//--- Trading mode: controls how aggressively the EA is allowed to size/send real orders.
//--- DEFAULT MUST STAY DEMO_PAPER on first deploy — do not change the default value here.
enum ENUM_TRADING_MODE
  {
   DEMO_PAPER,    // Demo/paper only — sizing computed normally but intended for demo accounts
   LIVE_MIN_LOT,  // Live account, lot size forced to InpMinLotOverride regardless of risk calc
   LIVE_FULL      // Live account, full risk-based position sizing
  };

//--- Parsed GLM signal action. INVALID_ACTION means the raw JSON action string did not
//--- match BUY/SELL/HOLD and must be treated as HOLD by the caller (never traded).
enum ENUM_SIGNAL_ACTION
  {
   ACTION_HOLD = 0,
   ACTION_BUY  = 1,
   ACTION_SELL = 2,
   ACTION_INVALID = 3
  };

namespace Utils
  {
   //--- Internal: is character whitespace (space/tab/CR/LF)?
   bool IsWhitespaceChar(const ushort ch)
     {
      return(ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n');
     }

   //--- Trim leading/trailing whitespace from a string. Purpose: normalize tokens pulled
   //--- out of raw JSON text before comparison/conversion. Returns trimmed copy.
   string TrimString(const string s)
     {
      string r = s;
      StringTrimLeft(r);
      StringTrimRight(r);
      return r;
     }

   //--- Return true if symbol param is empty/NULL, meaning "use current chart symbol".
   //--- Purpose: every symbol-info helper below accepts an optional symbol override so
   //--- broker-suffixed symbols (XAUUSD., XAUUSDm, ...) are always resolved dynamically
   //--- via _Symbol / input, never hardcoded.
   string ResolveSymbol(const string symbol)
     {
      if(symbol == NULL || symbol == "")
         return _Symbol;
      return symbol;
     }

   //--- Get SYMBOL_POINT for a symbol (defaults to current chart symbol).
   double GetPoint(const string symbol = NULL)
     {
      return SymbolInfoDouble(ResolveSymbol(symbol), SYMBOL_POINT);
     }

   //--- Get price digits for a symbol.
   int GetDigits(const string symbol = NULL)
     {
      return (int)SymbolInfoInteger(ResolveSymbol(symbol), SYMBOL_DIGITS);
     }

   //--- Get tick value (account currency profit per 1.0 lot per tick move) for a symbol.
   double GetTickValue(const string symbol = NULL)
     {
      return SymbolInfoDouble(ResolveSymbol(symbol), SYMBOL_TRADE_TICK_VALUE);
     }

   //--- Get tick size (minimal price increment that changes value) for a symbol.
   double GetTickSize(const string symbol = NULL)
     {
      return SymbolInfoDouble(ResolveSymbol(symbol), SYMBOL_TRADE_TICK_SIZE);
     }

   //--- Monetary value of a 1-point move for 1.0 lot, derived from real tick value/size —
   //--- never hardcoded, since gold's point value differs per broker/contract spec.
   double GetPointValuePerLot(const string symbol = NULL)
     {
      string sym       = ResolveSymbol(symbol);
      double tickValue = GetTickValue(sym);
      double tickSize  = GetTickSize(sym);
      double point     = GetPoint(sym);
      if(tickSize <= 0.0)
         return 0.0;
      return tickValue * (point / tickSize);
     }

   double GetVolumeStep(const string symbol = NULL)
     {
      return SymbolInfoDouble(ResolveSymbol(symbol), SYMBOL_VOLUME_STEP);
     }

   double GetVolumeMin(const string symbol = NULL)
     {
      return SymbolInfoDouble(ResolveSymbol(symbol), SYMBOL_VOLUME_MIN);
     }

   double GetVolumeMax(const string symbol = NULL)
     {
      return SymbolInfoDouble(ResolveSymbol(symbol), SYMBOL_VOLUME_MAX);
     }

   //--- Round a raw lot size to the broker's volume step and clamp to [min,max].
   //--- Purpose: every lot value that could reach OrderSend must pass through here.
   double NormalizeVolume(double volume, const string symbol = NULL)
     {
      string sym  = ResolveSymbol(symbol);
      double step = GetVolumeStep(sym);
      double vmin = GetVolumeMin(sym);
      double vmax = GetVolumeMax(sym);

      if(step <= 0.0)
         step = 0.01;

      double steps   = MathRound(volume / step);
      double rounded = steps * step;

      if(rounded < vmin)
         rounded = vmin;
      if(rounded > vmax)
         rounded = vmax;

      // Decimal places implied by the step (e.g. step=0.01 -> 2 digits), used to clean up
      // floating-point noise after rounding/clamping. Capped at 8 digits defensively.
      int stepDigits = 0;
      double s = step;
      while(s < 1.0 && stepDigits < 8)
        {
         s *= 10.0;
         stepDigits++;
        }
      return NormalizeDouble(rounded, stepDigits);
     }

   //--- Round a price to the symbol's tick size / digits. Purpose: any SL/TP/entry price
   //--- computed by risk logic must be normalized before it is placed in a trade request.
   double NormalizePrice(double price, const string symbol = NULL)
     {
      string sym      = ResolveSymbol(symbol);
      double tickSize = GetTickSize(sym);
      int    digits   = GetDigits(sym);

      if(tickSize > 0.0)
        {
         double steps = MathRound(price / tickSize);
         price = steps * tickSize;
        }
      return NormalizeDouble(price, digits);
     }

   //--- Current spread in points (integer broker points, not pips — correct for XAU where
   //--- 1 point != 1 pip).
   long GetSpreadPoints(const string symbol = NULL)
     {
      return SymbolInfoInteger(ResolveSymbol(symbol), SYMBOL_SPREAD);
     }

   //--- Pick an order-filling mode the broker/symbol actually supports, preferring FOK,
   //--- then IOC, then RETURN. Purpose: hardcoding a single filling mode (e.g. always FOK)
   //--- silently breaks on brokers/symbols that don't support it — this must be resolved
   //--- dynamically from SYMBOL_FILLING_MODE for every order request.
   ENUM_ORDER_TYPE_FILLING GetSupportedFillingMode(const string symbol = NULL)
     {
      string sym  = ResolveSymbol(symbol);
      int    mask = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

      if((mask & SYMBOL_FILLING_FOK) != 0)
         return ORDER_FILLING_FOK;
      if((mask & SYMBOL_FILLING_IOC) != 0)
         return ORDER_FILLING_IOC;
      return ORDER_FILLING_RETURN;
     }

   //==================================================================
   // Minimal hand-rolled JSON helpers.
   // These purposefully do NOT implement a general JSON parser — only enough
   // to pull named scalar fields (string/number/bool) out of the flat, fixed
   // top-level JSON objects defined by the GLM signal / heartbeat schema.
   // No nested objects/arrays are expected in that schema.
   //==================================================================

   //--- Internal: locate the position right after "key": in json, searching from `from`.
   //--- Returns -1 if the key is not found as a quoted JSON key.
   int FindKeyValueStart(const string json, const string key, int from = 0)
     {
      string needle = "\"" + key + "\"";
      int pos = StringFind(json, needle, from);
      if(pos < 0)
         return -1;

      int cursor = pos + StringLen(needle);
      int colon  = StringFind(json, ":", cursor);
      if(colon < 0)
         return -1;

      int valueStart = colon + 1;
      // skip whitespace after colon
      while(valueStart < StringLen(json) && IsWhitespaceChar(StringGetCharacter(json, valueStart)))
         valueStart++;

      return valueStart;
     }

   //--- Extract a raw (untyped) token starting at `start`: either a quoted string
   //--- (returns the content without quotes, `isString`=true) or a bare token up to the
   //--- next ',' '}' ']' or whitespace (numbers/true/false/null, `isString`=false).
   string ExtractRawToken(const string json, int start, bool &isString)
     {
      isString = false;
      if(start < 0 || start >= StringLen(json))
         return "";

      ushort firstCh = StringGetCharacter(json, start);
      if(firstCh == '"')
        {
         isString = true;
         int i = start + 1;
         string result = "";
         while(i < StringLen(json))
           {
            ushort ch = StringGetCharacter(json, i);
            if(ch == '\\' && i + 1 < StringLen(json))
              {
               // basic escape handling: skip escape char, take next literally
               ushort next = StringGetCharacter(json, i + 1);
               result += ShortToString(next);
               i += 2;
               continue;
              }
            if(ch == '"')
               break;
            result += ShortToString(ch);
            i++;
           }
         return result;
        }

      // bare token (number / true / false / null)
      int i = start;
      string result = "";
      while(i < StringLen(json))
        {
         ushort ch = StringGetCharacter(json, i);
         if(ch == ',' || ch == '}' || ch == ']' || IsWhitespaceChar(ch))
            break;
         result += ShortToString(ch);
         i++;
        }
      return result;
     }

   //--- Get a string field's value. Returns false (outVal untouched) if the key is
   //--- missing or malformed — callers must apply their own EA-side default.
   bool JsonGetString(const string json, const string key, string &outVal)
     {
      int start = FindKeyValueStart(json, key);
      if(start < 0)
         return false;
      bool isString = false;
      string raw = ExtractRawToken(json, start, isString);
      if(!isString)
         return false;
      outVal = raw;
      return true;
     }

   //--- Get a numeric (double) field's value.
   bool JsonGetDouble(const string json, const string key, double &outVal)
     {
      int start = FindKeyValueStart(json, key);
      if(start < 0)
         return false;
      bool isString = false;
      string raw = TrimString(ExtractRawToken(json, start, isString));
      if(isString || raw == "")
         return false;
      if(!IsNumericToken(raw))
         return false;
      outVal = StringToDouble(raw);
      return true;
     }

   //--- Get an integer field's value.
   bool JsonGetInt(const string json, const string key, int &outVal)
     {
      double d;
      if(!JsonGetDouble(json, key, d))
         return false;
      outVal = (int)MathRound(d);
      return true;
     }

   //--- Get a boolean field's value ("true"/"false" literal tokens only).
   bool JsonGetBool(const string json, const string key, bool &outVal)
     {
      int start = FindKeyValueStart(json, key);
      if(start < 0)
         return false;
      bool isString = false;
      string raw = TrimString(ExtractRawToken(json, start, isString));
      if(isString)
         return false;
      if(raw == "true")
        {
         outVal = true;
         return true;
        }
      if(raw == "false")
        {
         outVal = false;
         return true;
        }
      return false;
     }

   //--- Internal: does token look like a valid numeric literal (optional -, digits, one '.')
   bool IsNumericToken(const string token)
     {
      int len = StringLen(token);
      if(len == 0)
         return false;
      bool dotSeen = false;
      for(int i = 0; i < len; i++)
        {
         ushort ch = StringGetCharacter(token, i);
         if(ch == '-' && i == 0)
            continue;
         if(ch == '.')
           {
            if(dotSeen)
               return false;
            dotSeen = true;
            continue;
           }
         if(ch < '0' || ch > '9')
            return false;
        }
      return true;
     }

   //--- Parse an ISO-8601 UTC timestamp of the form "YYYY-MM-DDTHH:MM:SSZ" (as used by the
   //--- GLM bridge) into a datetime comparable with TimeGMT(). Returns false if the string
   //--- does not look like a well-formed timestamp — caller must treat that as "unknown /
   //--- stale", never crash.
   bool ParseIso8601Utc(const string iso, datetime &outUtc)
     {
      string s = TrimString(iso);
      if(StringLen(s) < 19)
         return false;

      // Expected shape: 2026-08-16T07:32:10Z (trailing Z optional)
      string normalized = s;
      StringReplace(normalized, "T", " ");
      StringReplace(normalized, "Z", "");
      StringReplace(normalized, "-", ".");

      datetime parsed = StringToTime(normalized);
      if(parsed <= 0)
         return false;

      outUtc = parsed;
      return true;
     }

   //--- Convenience: seconds elapsed between a UTC timestamp and "now" (TimeGMT()).
   //--- Negative values (timestamp in the future, e.g. clock skew) are clamped to 0.
   int SecondsSinceUtc(const datetime utcTime)
     {
      long diff = (long)TimeGMT() - (long)utcTime;
      if(diff < 0)
         diff = 0;
      return (int)diff;
     }
  }
