//+------------------------------------------------------------------+
//| Logger.mqh - log ทุก event (Experts tab + ไฟล์)                    |
//+------------------------------------------------------------------+
#property strict

string g_logFile   = "GinzaJo_log.txt";
bool   g_logToFile = true;

void LogInit(const bool toFile) { g_logToFile = toFile; }

void Log(const string msg)
{
   Print("[GinzaJo] ", msg);
   if(!g_logToFile) return;
   int h = FileOpen(g_logFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + " | " + msg + "\r\n");
   FileClose(h);
}

void LogError(const string where)
{
   int e = GetLastError();
   Log("ERROR in " + where + " | GetLastError=" + IntegerToString(e));
   ResetLastError();
}
