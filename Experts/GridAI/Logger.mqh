//+------------------------------------------------------------------+
//| Logger.mqh - บันทึก log ทุก trade event (Experts tab + ไฟล์)       |
//+------------------------------------------------------------------+
#property strict

string g_logFile = "GridAI_log.txt";
bool   g_logToFile = true;

void LogInit(const bool toFile)
{
   g_logToFile = toFile;
}

void Log(const string msg)
{
   string line = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + " | " + msg;
   Print("[GridAI] ", msg);
   if(!g_logToFile) return;
   int h = FileOpen(g_logFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, line + "\r\n");
   FileClose(h);
}

void LogError(const string where)
{
   Log("ERROR in " + where + " | GetLastError=" + IntegerToString(GetLastError()));
   ResetLastError();
}
