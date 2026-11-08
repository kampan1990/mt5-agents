//+------------------------------------------------------------------+
//| Journal.mqh - Layer 7: บันทึกทุกออเดอร์ (CSV) ให้ analyze_journal.py |
//+------------------------------------------------------------------+
#property strict
#include "Logger.mqh"

string g_journalFile = "GinzaJo_journal.csv";

void JournalWrite(const string line)
{
   bool isNew = !FileIsExist(g_journalFile);
   int h = FileOpen(g_journalFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h == INVALID_HANDLE) { LogError("Journal FileOpen"); return; }
   FileSeek(h, 0, SEEK_END);
   if(isNew)
      FileWriteString(h, "time,event,ticket,dir,lot,price,sl,tp,prob_buy,prob_sell,score,hour,spread,atr,profit\r\n");
   FileWriteString(h, line + "\r\n");
   FileClose(h);
}

void JournalOpen(const ulong ticket, const int dir, const double lot, const double price, const double sl,
                 const double tp, const double pb, const double ps, const int hour,
                 const double spread, const double atr)
{
   JournalWrite(StringFormat("%s,OPEN,%I64u,%d,%.2f,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f,%d,%.0f,%.5f,",
                TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), ticket, dir, lot, price, sl, tp,
                pb, ps, (dir > 0 ? pb : ps), hour, spread, atr));
}

void JournalClose(const ulong ticket, const double profit)
{
   JournalWrite(StringFormat("%s,CLOSE,%I64u,,,,,,,,,,,,%.2f",
                TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), ticket, profit));
}
