//+------------------------------------------------------------------+
//| Strategy.mqh - ขอสัญญาณ BUY/SELL จาก AI (Claude API)              |
//+------------------------------------------------------------------+
#property strict

struct SAISignal
{
   int    dir;          // +1 BUY, -1 SELL, 0 = ใช้ไม่ได้
   double confidence;   // 0-100
   string raw;
};

// สร้างข้อความตลาด: แท่ง M5 ล่าสุด (ปิดแล้ว) + ATR
string BuildMarketPrompt(const string sym, const int bars, const double atr)
{
   MqlRates r[];
   ArraySetAsSeries(r, false);
   if(CopyRates(sym, PERIOD_M5, 1, bars, r) < bars) return "";
   int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   string s = "Symbol " + sym + ". Last " + IntegerToString(bars) +
              " closed M5 candles, oldest first (time,O,H,L,C):\n";
   for(int i = 0; i < bars; i++)
      s += TimeToString(r[i].time, TIME_MINUTES) + "," + DoubleToString(r[i].open, dg) + "," +
           DoubleToString(r[i].high, dg) + "," + DoubleToString(r[i].low, dg) + "," +
           DoubleToString(r[i].close, dg) + "\n";
   s += "ATR(M5)=" + DoubleToString(atr, dg) + "\n";
   s += "Predict the likely short-term direction. HOLD is NOT allowed, you must choose. "
        "Reply with exactly: DIRECTION=BUY;CONFIDENCE=NN or DIRECTION=SELL;CONFIDENCE=NN "
        "(NN = integer 0-100). No other text.";
   return s;
}

// เรียก Claude API ผ่าน WebRequest (ต้องเพิ่ม https://api.anthropic.com ใน Tools>Options>Expert Advisors)
bool AskClaude(const string apiKey, const string model, const string userPrompt,
               const int timeoutMs, SAISignal &sig)
{
   sig.dir = 0; sig.confidence = 0; sig.raw = "";

   string body = "{\"model\":\"" + model + "\",\"max_tokens\":40,"
                 "\"system\":\"You are a short-term price direction classifier for trading. Output only the requested format.\","
                 "\"messages\":[{\"role\":\"user\",\"content\":\"" + JsonEscape(userPrompt) + "\"}]}";
   char data[], result[];
   int len = StringToCharArray(body, data, 0, StringLen(body), CP_UTF8);
   ArrayResize(data, len);

   string headers = "Content-Type: application/json\r\n"
                    "x-api-key: " + apiKey + "\r\n"
                    "anthropic-version: 2023-06-01\r\n";
   string respHeaders;
   ResetLastError();
   int code = WebRequest("POST", "https://api.anthropic.com/v1/messages", headers,
                         timeoutMs, data, result, respHeaders);
   if(code == -1)
   {
      Log("AI WebRequest failed. GetLastError=" + IntegerToString(GetLastError()) +
          " (4060 = ยังไม่ได้ allow URL ใน Options > Expert Advisors)");
      return false;
   }
   string resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(code != 200)
   {
      Log("AI HTTP " + IntegerToString(code) + ": " + StringSubstr(resp, 0, 200));
      return false;
   }
   sig.raw = StringSubstr(resp, 0, 300);

   string d = TokenAfter(resp, "DIRECTION=");
   StringToUpper(d);
   if(d == "BUY")       sig.dir = 1;
   else if(d == "SELL") sig.dir = -1;
   sig.confidence = StringToDouble(TokenAfter(resp, "CONFIDENCE="));
   if(sig.dir == 0)
   {
      Log("AI reply unparsable: " + sig.raw);
      return false;
   }
   return true;
}

// สัญญาณสำรองสำหรับ Strategy Tester (WebRequest ใช้ไม่ได้ใน tester):
// ตามทิศทางของแท่ง M5 ย้อนหลัง N แท่ง, confidence = 100
bool FallbackSignal(const string sym, const int bars, SAISignal &sig)
{
   MqlRates r[];
   ArraySetAsSeries(r, false);
   if(CopyRates(sym, PERIOD_M5, 1, bars, r) < bars) return false;
   sig.dir = (r[bars - 1].close >= r[0].close) ? 1 : -1;
   sig.confidence = 100;
   sig.raw = "fallback-momentum";
   return true;
}
