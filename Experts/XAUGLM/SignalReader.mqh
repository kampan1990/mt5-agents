//+------------------------------------------------------------------+
//| SignalReader.mqh                                                 |
//| XAUGLM EA — reads GLM bridge files (depends on: Utils, Logger)   |
//| Version: 1.0.0                                                   |
//| Created: 2026-08-16                                              |
//+------------------------------------------------------------------+
#pragma once
#include "Utils.mqh"
#include "Logger.mqh"

//--- Expected schema_version of signal.json / heartbeat.json. Bump together with the
//--- bridge when the on-disk contract changes; a mismatch is treated as WARN + HOLD.
#define XAUGLM_EXPECTED_SCHEMA_VERSION 1

//--- Parsed heartbeat.json state.
struct SHeartbeatInfo
  {
   bool     fileFound;      // heartbeat.json existed and opened
   bool     parseOk;        // required timestamp field parsed successfully
   datetime generatedAtUtc; // heartbeat's own "generated_at_utc"
   int      ageSeconds;     // seconds since generatedAtUtc (only valid if parseOk)
   bool     fresh;          // ageSeconds <= heartbeatTimeoutSeconds
  };

//--- Parsed signal.json state. Every optional field carries an EA-side default per the
//--- contract's parsing rules — nothing here ever throws, missing data just degrades to
//--- a safe default (and ultimately to HOLD if the essentials are missing/stale/invalid).
struct SSignalData
  {
   bool               fileFound;
   bool               parseOk;          // minimally parseable JSON object
   string             signalId;         // default ""
   datetime           generatedAtUtc;   // default 0 (=> always stale)
   string             symbol;           // default ""
   ENUM_SIGNAL_ACTION action;           // default ACTION_HOLD; invalid string => ACTION_INVALID
   double             confidence;       // default 0.0
   double             slAtrMultiplier;  // default -1.0 (sentinel: "not provided")
   double             tpAtrMultiplier;  // default -1.0 (sentinel: "not provided")
   string             reason;           // default ""
   string             glmModel;         // default ""
   int                schemaVersion;    // default 0 (=> mismatch vs expected)
   int                ageSeconds;
   bool               fresh;
   bool               schemaOk;
  };

//--- Combined read result for one polling cycle. tradingAllowed is the single boolean the
//--- rest of the EA should check before doing anything signal-driven; blockReason explains
//--- why when it is false (used for logging only).
struct SSignalReadResult
  {
   bool           killSwitchActive;
   SHeartbeatInfo heartbeat;
   SSignalData    signal;
   bool           tradingAllowed;
   string         blockReason;
  };

namespace SignalReader
  {
   //--- Internal: read an entire Common\Files text file into a string.
   //--- Returns false (found=false) if the file does not exist or cannot be opened —
   //--- this is the expected transient state while the bridge is mid-write; caller must
   //--- retry next poll, never crash.
   bool ReadCommonFile(const string relativePath, string &outContent)
     {
      if(!FileIsExist(relativePath, FILE_COMMON))
         return false;

      // REVIEW FIX (mt5-reviewer, medium): the bridge writes JSON with json.dumps(...,
      // ensure_ascii=False) — i.e. raw UTF-8 bytes, not \uXXXX escapes — so a Thai "reason"
      // string appears as multi-byte UTF-8 in the file. Opening with FILE_ANSI and the default
      // codepage (system ANSI code page) decoded those bytes one-at-a-time under the wrong
      // codepage, mangling any non-ASCII text (JSON structural characters are unaffected since
      // UTF-8 continuation/lead bytes are always >= 0x80 and never collide with '{','}','"',',',
      // ':', so parsing itself did not break — only the extracted string content did). Explicit
      // codepage=CP_UTF8 makes FILE_ANSI decode the bytes correctly as UTF-8.
      int handle = FileOpen(relativePath,
                             FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON |
                             FILE_SHARE_READ | FILE_SHARE_WRITE,
                             0, CP_UTF8);
      if(handle == INVALID_HANDLE)
         return false;

      ulong size = FileSize(handle);
      outContent = (size > 0) ? FileReadString(handle, (int)size) : "";
      FileClose(handle);
      return true;
     }

   //--- Map the raw "action" string from JSON to ENUM_SIGNAL_ACTION. Anything other than
   //--- exactly "BUY"/"SELL"/"HOLD" is ACTION_INVALID (caller must fold that into HOLD).
   ENUM_SIGNAL_ACTION ParseAction(const string raw)
     {
      string a = Utils::TrimString(raw);
      if(a == "BUY")
         return ACTION_BUY;
      if(a == "SELL")
         return ACTION_SELL;
      if(a == "HOLD")
         return ACTION_HOLD;
      return ACTION_INVALID;
     }

   //--- Step (2): read + validate heartbeat.json. A missing file, unparsable timestamp,
   //--- or timestamp older than heartbeatTimeoutSeconds all mean "bridge is not verifiably
   //--- alive" — treated the same way (fresh=false) by the caller.
   void ReadHeartbeat(const string heartbeatPath, const int heartbeatTimeoutSeconds, SHeartbeatInfo &hb)
     {
      hb.fileFound      = false;
      hb.parseOk        = false;
      hb.generatedAtUtc = 0;
      hb.ageSeconds      = INT_MAX;
      hb.fresh           = false;

      string content;
      if(!ReadCommonFile(heartbeatPath, content))
        {
         Logger::Warn("SignalReader: heartbeat.json not found/unreadable.");
         return;
        }
      hb.fileFound = true;

      string tsRaw;
      if(!Utils::JsonGetString(content, "generated_at_utc", tsRaw))
        {
         Logger::Warn("SignalReader: heartbeat.json missing/malformed 'generated_at_utc'.");
         return;
        }

      datetime parsed;
      if(!Utils::ParseIso8601Utc(tsRaw, parsed))
        {
         Logger::Warn("SignalReader: heartbeat.json 'generated_at_utc' failed to parse: " + tsRaw);
         return;
        }

      hb.parseOk        = true;
      hb.generatedAtUtc = parsed;
      hb.ageSeconds      = Utils::SecondsSinceUtc(parsed);
      hb.fresh           = (hb.ageSeconds <= heartbeatTimeoutSeconds);

      if(!hb.fresh)
         Logger::Warn(StringFormat("SignalReader: heartbeat.json stale, age=%ds (limit=%ds).",
                                    hb.ageSeconds, heartbeatTimeoutSeconds));
     }

   //--- Step (3): read + validate signal.json against the fixed GLM contract. Every
   //--- optional field falls back to a safe EA-side default; a completely unparsable file
   //--- (bridge mid-write) yields parseOk=false so the caller retries next cycle.
   void ReadSignal(const string signalPath, const int signalTimeoutSeconds, SSignalData &sig)
     {
      sig.fileFound       = false;
      sig.parseOk         = false;
      sig.signalId        = "";
      sig.generatedAtUtc  = 0;
      sig.symbol          = "";
      sig.action          = ACTION_HOLD;
      sig.confidence      = 0.0;
      sig.slAtrMultiplier = -1.0;
      sig.tpAtrMultiplier = -1.0;
      sig.reason          = "";
      sig.glmModel        = "";
      sig.schemaVersion   = 0;
      sig.ageSeconds      = INT_MAX;
      sig.fresh           = false;
      sig.schemaOk        = false;

      string content;
      if(!ReadCommonFile(signalPath, content))
        {
         Logger::Debug("SignalReader: signal.json not found/unreadable (retry next poll).");
         return;
        }
      sig.fileFound = true;

      // Minimal sanity check that this looks like a JSON object at all before we bother
      // extracting fields — protects against reading a half-written file mid-rename.
      if(StringFind(content, "{") < 0 || StringFind(content, "}") < 0)
        {
         Logger::Warn("SignalReader: signal.json does not look like a complete JSON object, will retry.");
         return;
        }

      string idVal;
      if(Utils::JsonGetString(content, "signal_id", idVal))
         sig.signalId = idVal;

      string tsRaw;
      if(Utils::JsonGetString(content, "generated_at_utc", tsRaw))
        {
         datetime parsed;
         if(Utils::ParseIso8601Utc(tsRaw, parsed))
            sig.generatedAtUtc = parsed;
         else
            Logger::Warn("SignalReader: signal.json 'generated_at_utc' failed to parse: " + tsRaw, sig.signalId);
        }

      string symVal;
      if(Utils::JsonGetString(content, "symbol", symVal))
         sig.symbol = symVal;

      string actionRaw;
      if(Utils::JsonGetString(content, "action", actionRaw))
        {
         sig.action = ParseAction(actionRaw);
         if(sig.action == ACTION_INVALID)
            Logger::Warn("SignalReader: signal.json has invalid 'action' value: " + actionRaw, sig.signalId);
        }
      else
        {
         Logger::Warn("SignalReader: signal.json missing 'action' field, defaulting to HOLD.", sig.signalId);
         sig.action = ACTION_HOLD;
        }

      double confVal;
      if(Utils::JsonGetDouble(content, "confidence", confVal))
         sig.confidence = confVal;

      double slVal;
      if(Utils::JsonGetDouble(content, "sl_atr_multiplier", slVal))
         sig.slAtrMultiplier = slVal;

      double tpVal;
      if(Utils::JsonGetDouble(content, "tp_atr_multiplier", tpVal))
         sig.tpAtrMultiplier = tpVal;

      string reasonVal;
      if(Utils::JsonGetString(content, "reason", reasonVal))
         sig.reason = reasonVal;

      string modelVal;
      if(Utils::JsonGetString(content, "glm_model", modelVal))
         sig.glmModel = modelVal;

      int schemaVal;
      if(Utils::JsonGetInt(content, "schema_version", schemaVal))
         sig.schemaVersion = schemaVal;

      sig.parseOk  = true; // we successfully read a JSON-ish object; field defaults cover the rest
      sig.schemaOk = (sig.schemaVersion == XAUGLM_EXPECTED_SCHEMA_VERSION);
      if(!sig.schemaOk)
         Logger::Warn(StringFormat("SignalReader: signal.json schema_version=%d, expected=%d.",
                                    sig.schemaVersion, XAUGLM_EXPECTED_SCHEMA_VERSION), sig.signalId);

      if(sig.generatedAtUtc <= 0)
        {
         sig.ageSeconds = INT_MAX;
         sig.fresh      = false;
         Logger::Warn("SignalReader: signal.json has no usable timestamp, treated as stale.", sig.signalId);
        }
      else
        {
         sig.ageSeconds = Utils::SecondsSinceUtc(sig.generatedAtUtc);
         sig.fresh      = (sig.ageSeconds <= signalTimeoutSeconds);
         if(!sig.fresh)
            Logger::Warn(StringFormat("SignalReader: signal.json stale, age=%ds (limit=%ds).",
                                       sig.ageSeconds, signalTimeoutSeconds), sig.signalId);
        }
     }

   //--- Master entry point. Checks, in the mandated order: (1) kill_switch.flag existence
   //--- — if present, everything else is skipped and trading is blocked immediately;
   //--- (2) heartbeat.json freshness; (3) signal.json parse/schema/freshness. Returns a
   //--- fully-populated SSignalReadResult with tradingAllowed as the single source of
   //--- truth for "is it safe to even consider this signal".
   void ReadAll(const string signalPath, const string heartbeatPath, const string killSwitchPath,
                const int signalTimeoutSeconds, const int heartbeatTimeoutSeconds,
                SSignalReadResult &out)
     {
      out.killSwitchActive = false;
      out.tradingAllowed   = false;
      out.blockReason      = "";

      // (1) kill switch — highest priority, short-circuits everything else.
      if(FileIsExist(killSwitchPath, FILE_COMMON))
        {
         out.killSwitchActive = true;
         out.blockReason      = "kill_switch.flag present";
         Logger::Warn("SignalReader: kill_switch.flag present — trading blocked, skipping heartbeat/signal read.");
         return;
        }

      // (2) heartbeat
      ReadHeartbeat(heartbeatPath, heartbeatTimeoutSeconds, out.heartbeat);
      if(!out.heartbeat.fileFound || !out.heartbeat.parseOk || !out.heartbeat.fresh)
        {
         out.blockReason = "heartbeat not fresh/unavailable";
         return;
        }

      // (3) signal
      ReadSignal(signalPath, signalTimeoutSeconds, out.signal);

      if(!out.signal.fileFound || !out.signal.parseOk)
        {
         out.blockReason = "signal.json unavailable/unparsable";
         return;
        }
      if(!out.signal.schemaOk)
        {
         out.blockReason = "signal.json schema_version mismatch";
         return;
        }
      if(!out.signal.fresh)
        {
         out.blockReason = "signal.json stale";
         return;
        }
      if(out.signal.action == ACTION_INVALID)
        {
         out.blockReason = "signal.json action invalid";
         return;
        }

      out.tradingAllowed = true;
     }
  }
