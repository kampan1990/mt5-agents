//+------------------------------------------------------------------+
//| AIBridgeEA.mq5                                                   |
//| รับคำสั่งจาก AI Trading Bot (web) แล้วเปิด order บน MT5            |
//| - SL/TP บังคับทุก order (คำนวณจากราคา fill จริงของ broker)          |
//| - Lot คำนวณจาก % balance ด้วย tick value จริงของ broker             |
//| - Max Drawdown ฝั่ง EA เอง (ชั้นป้องกันที่ 2 แยกจาก server)          |
//| ต้องเพิ่ม URL ของ server ใน Tools > Options > Expert Advisors >     |
//| "Allow WebRequest for listed URL"                                 |
//+------------------------------------------------------------------+
#property copyright "mt5-agents"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input string InpServerURL      = "https://your-app.up.railway.app"; // URL ของ server (ไม่มี / ท้าย)
input string InpEAToken        = "";       // EA_TOKEN (ต้องตรงกับ server)
input int    InpPollSeconds    = 10;       // ดึงคำสั่งทุกกี่วินาที
input string InpSymbolSuffix   = "";       // suffix ของ broker เช่น ".m" หรือ "pro"
input double InpMaxRiskPct     = 2.0;      // เพดาน risk% ต่อ order (ไม่สนค่าจาก server ถ้าเกิน)
input double InpMaxLot         = 5.0;      // เพดาน lot ต่อ order
input double InpMaxDrawdownPct = 15.0;     // หยุดเปิด order ใหม่เมื่อ DD เกิน %
input int    InpMaxPositions   = 3;        // จำนวน position สูงสุดของ EA นี้
input int    InpSlippagePoints = 30;       // slippage ที่ยอมรับ (points)
input long   InpMagic          = 20261016; // magic number

CTrade trade;
double g_peakEquity = 0;
string g_gvPeak;

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(InpEAToken) == 0) { Print("[AIBridge] ต้องตั้ง InpEAToken"); return INIT_PARAMETERS_INCORRECT; }
   if(InpPollSeconds < 3) { Print("[AIBridge] InpPollSeconds ต้อง >= 3"); return INIT_PARAMETERS_INCORRECT; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   g_gvPeak = StringFormat("AIBridge_peak_%I64d", InpMagic);
   g_peakEquity = GlobalVariableCheck(g_gvPeak) ? GlobalVariableGet(g_gvPeak) : AccountInfoDouble(ACCOUNT_EQUITY);

   EventSetTimer(InpPollSeconds);
   PrintFormat("[AIBridge] เริ่มทำงาน server=%s poll=%ds", InpServerURL, InpPollSeconds);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }

//+------------------------------------------------------------------+
void OnTimer()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity) { g_peakEquity = equity; GlobalVariableSet(g_gvPeak, g_peakEquity); }

   bool serverAllows = SendHeartbeat();

   double dd = g_peakEquity > 0 ? (g_peakEquity - equity) / g_peakEquity * 100.0 : 0;
   if(dd >= InpMaxDrawdownPct) { PrintFormat("[AIBridge] DD %.2f%% >= %.2f%% — ไม่เปิด order ใหม่", dd, InpMaxDrawdownPct); return; }
   if(!serverAllows) return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) { Print("[AIBridge] AutoTrading ปิดอยู่"); return; }

   string body;
   if(!HttpRequest("GET", "/api/ea/orders", "", body)) return;
   ProcessOrders(body);
}

//+------------------------------------------------------------------+
//| HTTP                                                             |
//+------------------------------------------------------------------+
bool HttpRequest(const string method, const string path, const string payload, string &response)
{
   char data[], result[];
   string resHeaders;
   string headers = "Content-Type: application/json\r\nAuthorization: Bearer " + InpEAToken + "\r\n";
   if(StringLen(payload) > 0) StringToCharArray(payload, data, 0, StringLen(payload), CP_UTF8);

   ResetLastError();
   int code = WebRequest(method, InpServerURL + path, headers, 10000, data, result, resHeaders);
   if(code == -1)
   {
      int err = GetLastError();
      PrintFormat("[AIBridge] WebRequest %s ล้มเหลว error=%d%s", path, err,
                  err == 4014 ? " (ยังไม่ได้อนุญาต URL ใน Options > Expert Advisors)" : "");
      return false;
   }
   response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(code != 200) { PrintFormat("[AIBridge] %s HTTP %d: %s", path, code, response); return false; }
   return true;
}

bool SendHeartbeat()
{
   string positions = "";
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      positions += StringFormat("%s{\"symbol\":\"%s\",\"side\":\"%s\",\"lot\":%.2f,\"profit\":%.2f}",
                                n++ > 0 ? "," : "", BaseSymbol(sym),
                                PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL",
                                PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PROFIT));
   }
   string payload = StringFormat("{\"balance\":%.2f,\"equity\":%.2f,\"positions\":[%s]}",
                                 AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY), positions);
   string resp;
   if(!HttpRequest("POST", "/api/ea/heartbeat", payload, resp)) return false;
   return StringFind(resp, "\"tradingEnabled\":true") >= 0;
}

void Report(const long id, const bool ok, const ulong ticket, const double price, const string error)
{
   string err = error;
   StringReplace(err, "\"", "'");
   string payload = StringFormat("{\"id\":%I64d,\"status\":\"%s\",\"ticket\":%I64u,\"price\":%s,\"error\":\"%s\"}",
                                 id, ok ? "filled" : "failed", ticket, DoubleToString(price, 8), err);
   string resp;
   HttpRequest("POST", "/api/ea/report", payload, resp);
}

//+------------------------------------------------------------------+
//| JSON helpers (สำหรับ object แบบแบนที่ server ส่งมาเท่านั้น)          |
//+------------------------------------------------------------------+
string JsonRaw(const string obj, const string key)
{
   string pat = "\"" + key + "\":";
   int p = StringFind(obj, pat);
   if(p < 0) return "";
   p += StringLen(pat);
   if(StringGetCharacter(obj, p) == '"')
   {
      int e = StringFind(obj, "\"", p + 1);
      return e < 0 ? "" : StringSubstr(obj, p + 1, e - p - 1);
   }
   int e = p;
   while(e < StringLen(obj) && StringGetCharacter(obj, e) != ',' && StringGetCharacter(obj, e) != '}') e++;
   return StringSubstr(obj, p, e - p);
}

void ProcessOrders(const string body)
{
   int pos = StringFind(body, "[");
   while(pos >= 0)
   {
      int s = StringFind(body, "{", pos);
      if(s < 0) break;
      int e = StringFind(body, "}", s);
      if(e < 0) break;
      ExecuteOrder(StringSubstr(body, s, e - s + 1));
      pos = e + 1;
   }
}

//+------------------------------------------------------------------+
//| Order execution                                                  |
//+------------------------------------------------------------------+
string BaseSymbol(const string sym)
{
   if(StringLen(InpSymbolSuffix) > 0 && StringFind(sym, InpSymbolSuffix) == StringLen(sym) - StringLen(InpSymbolSuffix))
      return StringSubstr(sym, 0, StringLen(sym) - StringLen(InpSymbolSuffix));
   return sym;
}

int CountMyPositions(const string symbol)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(symbol == "" || PositionGetString(POSITION_SYMBOL) == symbol) count++;
   }
   return count;
}

double CalcLot(const string symbol, const double slDistance, const double riskPct)
{
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0) tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double step     = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double minLot   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot   = MathMin(SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX), InpMaxLot);
   if(tickValue <= 0 || tickSize <= 0 || step <= 0 || slDistance <= 0) return 0;

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * MathMin(riskPct, InpMaxRiskPct) / 100.0;
   double lossPerLot = slDistance / tickSize * tickValue;
   double lot = MathFloor(riskMoney / lossPerLot / step + 1e-9) * step;
   if(lot < minLot) return 0; // ไม่ปัดขึ้น — ความเสี่ยงจริงจะเกินที่ตั้งไว้
   return NormalizeDouble(MathMin(lot, maxLot), 2);
}

void ExecuteOrder(const string obj)
{
   long   id     = StringToInteger(JsonRaw(obj, "id"));
   string base   = JsonRaw(obj, "symbol");
   string side   = JsonRaw(obj, "side");
   double slDist = StringToDouble(JsonRaw(obj, "sl_distance"));
   double tpDist = StringToDouble(JsonRaw(obj, "tp_distance"));
   double risk   = StringToDouble(JsonRaw(obj, "risk_pct"));
   string cmt    = JsonRaw(obj, "comment");
   string symbol = base + InpSymbolSuffix;

   if(id <= 0) { Print("[AIBridge] order ไม่มี id: ", obj); return; }
   if(side != "BUY" && side != "SELL") { Report(id, false, 0, 0, "side ไม่ถูกต้อง"); return; }
   if(slDist <= 0 || tpDist <= 0) { Report(id, false, 0, 0, "ไม่มี SL/TP — ปฏิเสธ"); return; }
   if(!SymbolSelect(symbol, true)) { Report(id, false, 0, 0, "ไม่พบ symbol " + symbol); return; }
   if(CountMyPositions("") >= InpMaxPositions) { Report(id, false, 0, 0, "position เต็มแล้ว"); return; }
   if(CountMyPositions(symbol) > 0) { Report(id, false, 0, 0, "มี position " + symbol + " อยู่แล้ว"); return; }

   double lot = CalcLot(symbol, slDist, risk);
   if(lot <= 0) { Report(id, false, 0, 0, "lot ต่ำกว่าขั้นต่ำของ broker (SL กว้างเกินไป)"); return; }

   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double minStop = (SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) + 1) * point;
   if(slDist < minStop || tpDist < minStop) { Report(id, false, 0, 0, "SL/TP ใกล้กว่า stops level ของ broker"); return; }

   bool isBuy = side == "BUY";
   double price = isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
   double sl = NormalizeDouble(isBuy ? price - slDist : price + slDist, digits);
   double tp = NormalizeDouble(isBuy ? price + tpDist : price - tpDist, digits);

   ResetLastError();
   bool sent = isBuy ? trade.Buy(lot, symbol, price, sl, tp, cmt) : trade.Sell(lot, symbol, price, sl, tp, cmt);
   uint retcode = trade.ResultRetcode();
   if(!sent || (retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_PLACED))
   {
      string err = StringFormat("retcode=%u %s, GetLastError=%d", retcode, trade.ResultRetcodeDescription(), GetLastError());
      PrintFormat("[AIBridge] เปิด %s %s ล้มเหลว: %s", side, symbol, err);
      Report(id, false, 0, 0, err);
      return;
   }

   ulong ticket = trade.ResultOrder();
   double fill = trade.ResultPrice() > 0 ? trade.ResultPrice() : price;
   PrintFormat("[AIBridge] เปิด %s %s %.2f lot @ %s SL %s TP %s ticket %I64u (AI#%I64d)",
               side, symbol, lot, DoubleToString(fill, digits), DoubleToString(sl, digits), DoubleToString(tp, digits), ticket, id);
   Report(id, true, ticket, fill, "");
}
//+------------------------------------------------------------------+
