//+------------------------------------------------------------------+
//| ExportData.mq5 - Layer 1: export แท่ง M5 (รวม spread) เป็น CSV     |
//| วางบนกราฟ XAUUSD แล้วรัน -> ไฟล์อยู่ที่ MQL5\Files\XAUUSD_M5.csv    |
//| (เปิด Tools > Options > Charts: Max bars in chart ให้สูงพอ)         |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

input int    InpBars = 200000;               // จำนวนแท่ง M5 ย้อนหลัง
input string InpFile = "XAUUSD_M5.csv";

void OnStart()
{
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(_Symbol, PERIOD_M5, 1, InpBars, r);   // ข้ามแท่งที่ยังไม่ปิด
   if(n <= 0) { Print("CopyRates failed: ", GetLastError()); return; }
   int h = FileOpen(InpFile, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) { Print("FileOpen failed: ", GetLastError()); return; }
   FileWriteString(h, "time,open,high,low,close,tick_volume,spread\n");
   for(int i = 0; i < n; i++)
      FileWriteString(h, StringFormat("%s,%.*f,%.*f,%.*f,%.*f,%I64d,%d\n",
         TimeToString(r[i].time, TIME_DATE | TIME_MINUTES), _Digits, r[i].open, _Digits, r[i].high,
         _Digits, r[i].low, _Digits, r[i].close, r[i].tick_volume, r[i].spread));
   FileClose(h);
   PrintFormat("Exported %d bars to MQL5\\Files\\%s", n, InpFile);
}
