//+------------------------------------------------------------------+
//|                                      EngulfingGridHedgeEA.mq5     |
//|            Engulfing Entry + Grid + Hedge (ไม่ปิด Buy) + Breakeven |
//+------------------------------------------------------------------+
#property copyright "AI Assistant"
#property link      ""
#property version   "3.00"
#property strict

//--- Input Parameters -------------------------------------------------
input ENUM_TIMEFRAMES InpTimeframe          = PERIOD_H1;   // Timeframe ที่ใช้หา Engulfing
input bool            InpBullishEngulfing   = true;        // เปิดใช้ Bullish Engulfing
input bool            InpBearishEngulfing   = true;        // เปิดใช้ Bearish Engulfing
input double          InpLotSize            = 0.01;        // ล็อตฐาน (สำหรับ Buy Grid)
input int             InpGridLevels         = 5;            // จำนวนไม้กริดต่อฝั่ง
input int             InpGridStep           = 50;           // ระยะห่างกริด (points)
input int             InpTakeProfit         = 100;          // TP ต่อไม้ (points)
input double          InpLotMultiplier      = 1.5;          // ตัวคูณล็อตภายในกริดเดียวกัน (Martingale)
input double          InpHedgeLotMultiplier = 1.0;          // ตัวคูณล็อตไม้เฮจ เทียบกับยอด Buy รวมที่เปิดอยู่
input double          InpSellLotMultiplier  = 1.5;          // ตัวคูณล็อตของ Sell Grid ใหม่ เทียบกับ InpLotSize
input int             InpBreakevenBuffer    = 20;           // buffer กันสเปรดตอนตั้งกันทุน (points) ตั้ง 0 ได้ถ้าไม่ต้องการ
input int             InpMagicNumber        = 20260814;     // Magic Number

//--- Globals ------------------------------------------------------------
string   g_symbol;
double   g_point;
double   g_gridStepPrice;
double   g_tpPrice;
double   g_beBuffer;
long     g_magicNumber;
datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   g_symbol        = _Symbol;
   g_point         = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   g_magicNumber   = InpMagicNumber;
   g_gridStepPrice = InpGridStep * g_point;
   g_tpPrice       = InpTakeProfit * g_point;
   g_beBuffer      = InpBreakevenBuffer * g_point;

   if(InpGridLevels <= 0 || InpGridStep <= 0 || InpTakeProfit <= 0)
   {
      Print("Error: grid parameters ต้องมากกว่า 0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   Print("EA เริ่มทำงานบน ", g_symbol);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { Print("EA หยุดทำงาน เหตุผล: ", reason); }

//+------------------------------------------------------------------+
//| ตรวจแท่งใหม่                                                       |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(g_symbol, InpTimeframe, 0);
   if(t != g_lastBarTime) { g_lastBarTime = t; return true; }
   return false;
}

//+------------------------------------------------------------------+
//| Main                                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1) จัดการไม้ที่เปิดอยู่ทุก tick (ให้ล็อกกันทุนไว หลังกำไรเกิดขึ้น)
   ManagePositions(POSITION_TYPE_BUY);
   ManagePositions(POSITION_TYPE_SELL);

   if(!IsNewBar()) return;

   // 2) หา Engulfing บนแท่งที่ "ปิดแล้ว" เท่านั้น (ไม่ใช่แท่งที่กำลังวิ่ง)
   bool isBull=false, isBear=false;
   if(!CheckEngulfing(isBull, isBear)) return;

   // 3) มีสัญญาณใหม่ -> ยกเลิก pending order เดิมทั้งหมดก่อนเสมอ
   CancelAllPendingOrders();

   if(isBull)
   {
      Print("พบ Bullish Engulfing -> เปิด Buy Grid");
      OpenBuyGrid(InpLotSize);
   }
   else if(isBear)
   {
      Print("พบ Bearish Engulfing -> เฮจ Buy เดิมทั้งหมด แล้วเปิด Sell Grid");
      double buyVolume = GetTotalVolume(POSITION_TYPE_BUY);
      if(buyVolume > 0)
         OpenHedgeSell(buyVolume * InpHedgeLotMultiplier);
      OpenSellGrid(InpLotSize * InpSellLotMultiplier);
   }
}

//+------------------------------------------------------------------+
//| ตรวจ Engulfing บนแท่งที่ปิดสมบูรณ์แล้ว (index 1 กับ 2)              |
//| rates[0] = แท่งที่กำลังวิ่งอยู่ (ยังไม่ปิด) -> ห้ามใช้ตรวจ pattern    |
//+------------------------------------------------------------------+
bool CheckEngulfing(bool &isBullish, bool &isBearish)
{
   MqlRates rates[3];
   if(CopyRates(g_symbol, InpTimeframe, 0, 3, rates) < 3)
   {
      Print("ดึงข้อมูลแท่งเทียนไม่สำเร็จ");
      return false;
   }
   double currOpen  = rates[1].open;   // แท่งสัญญาณ (ปิดแล้ว)
   double currClose = rates[1].close;
   double prevOpen  = rates[2].open;   // แท่งก่อนหน้า
   double prevClose = rates[2].close;

   isBullish = false;
   isBearish = false;

   if(InpBullishEngulfing &&
      prevClose < prevOpen && currClose > currOpen &&
      currOpen <= prevClose && currClose > prevOpen)
   {
      isBullish = true;
      return true;
   }
   if(InpBearishEngulfing &&
      prevClose > prevOpen && currClose < currOpen &&
      currOpen >= prevClose && currClose < prevOpen)
   {
      isBearish = true;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| ยกเลิก pending order เดิมทั้งหมดของ EA นี้ (เมื่อมีสัญญาณใหม่)        |
//+------------------------------------------------------------------+
void CancelAllPendingOrders()
{
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);   // เลือก order นี้ให้พร้อมใช้ OrderGetXXX ต่อ
      if(ticket == 0) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != g_magicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;

      MqlTradeRequest req = {}; MqlTradeResult res = {};
      req.action = TRADE_ACTION_REMOVE;
      req.order  = ticket;
      if(!OrderSend(req, res))
         PrintFormat("ยกเลิก order %I64u ไม่สำเร็จ: %d %s", ticket, res.retcode, res.comment);
   }
}

//+------------------------------------------------------------------+
//| เปิด Buy Grid: BUY_LIMIT ด้านล่าง + BUY_STOP ด้านบน ฝั่งละ N ไม้    |
//+------------------------------------------------------------------+
void OpenBuyGrid(double baseLot)
{
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double mid = (ask + bid) / 2.0;

   for(int i = 1; i <= InpGridLevels; i++)
   {
      double lot       = NormalizeLot(baseLot * MathPow(InpLotMultiplier, i-1));
      double priceDown = mid - i * g_gridStepPrice;
      double priceUp   = mid + i * g_gridStepPrice;
      if(priceDown > 0) PlacePendingOrder(ORDER_TYPE_BUY_LIMIT, lot, priceDown);
      PlacePendingOrder(ORDER_TYPE_BUY_STOP, lot, priceUp);
   }
}

//+------------------------------------------------------------------+
//| เปิด Sell Grid: SELL_LIMIT ด้านบน + SELL_STOP ด้านล่าง ฝั่งละ N ไม้ |
//+------------------------------------------------------------------+
void OpenSellGrid(double baseLot)
{
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double mid = (ask + bid) / 2.0;

   for(int i = 1; i <= InpGridLevels; i++)
   {
      double lot       = NormalizeLot(baseLot * MathPow(InpLotMultiplier, i-1));
      double priceUp   = mid + i * g_gridStepPrice;
      double priceDown = mid - i * g_gridStepPrice;
      PlacePendingOrder(ORDER_TYPE_SELL_LIMIT, lot, priceUp);
      if(priceDown > 0) PlacePendingOrder(ORDER_TYPE_SELL_STOP, lot, priceDown);
   }
}

//+------------------------------------------------------------------+
//| วาง pending order พร้อม TP ตามทิศทาง                               |
//+------------------------------------------------------------------+
bool PlacePendingOrder(ENUM_ORDER_TYPE type, double lot, double price)
{
   price = NormalizePrice(price);
   lot   = NormalizeLot(lot);
   bool isBuySide = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP);
   double tp = isBuySide ? price + g_tpPrice : price - g_tpPrice;

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action       = TRADE_ACTION_PENDING;
   req.symbol       = g_symbol;
   req.volume       = lot;
   req.type         = type;
   req.price        = price;
   req.tp           = NormalizePrice(tp);
   req.deviation    = 10;
   req.magic        = (ulong)g_magicNumber;
   req.type_filling = ORDER_FILLING_RETURN;
   req.type_time    = ORDER_TIME_GTC;

   if(!OrderSend(req, res))
   {
      PrintFormat("วาง %s ไม่สำเร็จ ที่ %.5f: %d %s", EnumToString(type), price, res.retcode, res.comment);
      return false;
   }
   PrintFormat("วาง %s สำเร็จ ที่ %.5f ล็อต %.2f TP %.5f", EnumToString(type), price, lot, tp);
   return true;
}

//+------------------------------------------------------------------+
//| เฮจ Buy ทั้งหมดด้วย Sell ตลาด (ไม่ปิด Buy)                          |
//+------------------------------------------------------------------+
void OpenHedgeSell(double volume)
{
   volume = NormalizeLot(volume);
   if(volume <= 0) return;

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = g_symbol;
   req.volume       = volume;
   req.type         = ORDER_TYPE_SELL;
   req.price        = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   req.deviation    = 10;
   req.magic        = (ulong)g_magicNumber;
   req.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(req, res))
      PrintFormat("เปิด Hedge Sell ไม่สำเร็จ: %d %s", res.retcode, res.comment);
   else
      PrintFormat("เปิด Hedge Sell สำเร็จ %.2f ล็อต ที่ %.5f", volume, req.price);
}

//+------------------------------------------------------------------+
//| รวมล็อตของ position ฝั่งที่กำหนด (magic + symbol ตรงกัน)            |
//+------------------------------------------------------------------+
double GetTotalVolume(ENUM_POSITION_TYPE side)
{
   double total = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != g_magicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
      total += PositionGetDouble(POSITION_VOLUME);
   }
   return total;
}

//+------------------------------------------------------------------+
//| จัดการไม้ฝั่งที่กำหนด: เก็บไม้ที่ดีที่สุดไว้ + ตั้งกันทุนทันที         |
//| ไม้ที่เหลือปล่อยให้ชน TP ของตัวเอง (ฝังไว้ตั้งแต่ตอนวาง order แล้ว)   |
//+------------------------------------------------------------------+
void ManagePositions(ENUM_POSITION_TYPE side)
{
   ulong  bestTicket = 0;
   double bestProfit = -DBL_MAX;
   int    count = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != g_magicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;

      count++;
      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit > bestProfit) { bestProfit = profit; bestTicket = ticket; }
   }

   // ต้องมีมากกว่า 1 ไม้ และไม้ที่ดีที่สุดต้องเป็นบวกแล้วเท่านั้น ถึงจะล็อกกำไร
   if(count > 1 && bestTicket > 0 && bestProfit > 0)
      LockBestPosition(bestTicket, side);
}

void LockBestPosition(ulong ticket, ENUM_POSITION_TYPE side)
{
   if(!PositionSelectByTicket(ticket)) return;
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL  = PositionGetDouble(POSITION_SL);
   double beLevel = (side == POSITION_TYPE_BUY) ? openPrice + g_beBuffer
                                                 : openPrice - g_beBuffer;
   beLevel = NormalizePrice(beLevel);

   // ถ้าตั้งกันทุนไว้แล้ว (SL ผ่านจุดกันทุนไปแล้ว) ไม่ต้องยิงซ้ำ
   bool alreadyLocked = (side == POSITION_TYPE_BUY) ? (currentSL != 0 && currentSL >= beLevel - g_point)
                                                     : (currentSL != 0 && currentSL <= beLevel + g_point);
   if(alreadyLocked) return;

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action   = TRADE_ACTION_SLTP;
   req.symbol   = g_symbol;
   req.position = ticket;
   req.sl       = beLevel;
   req.tp       = 0;   // ถอด TP เดิมออก -> "เก็บ" ไม้นี้ไว้ให้วิ่งต่อ มีแค่กันทุนคุ้ม
   req.magic    = (ulong)g_magicNumber;

   if(!OrderSend(req, res))
      PrintFormat("ตั้งกันทุนไม่สำเร็จ Ticket=%I64u: %d %s", ticket, res.retcode, res.comment);
   else
      PrintFormat("ตั้งกันทุน + เก็บไม้ที่ดีที่สุดไว้ Ticket=%I64u SL=%.5f", ticket, beLevel);
}

//+------------------------------------------------------------------+
//| Helper: normalize                                                  |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   if(stepLot > 0) lot = MathRound(lot/stepLot) * stepLot;
   return NormalizeDouble(lot, 2);
}
//+------------------------------------------------------------------+
