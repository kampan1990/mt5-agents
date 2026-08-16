//+------------------------------------------------------------------+
//| Strategy.mqh                                                     |
//| XAUGLM EA — combines GLM signal + light technical confirmation   |
//| depends on: Utils.mqh, Logger.mqh, SignalReader.mqh, RiskManager.mqh |
//| Version: 1.0.0                                                   |
//| Created: 2026-08-16                                              |
//+------------------------------------------------------------------+
#pragma once
#include "Utils.mqh"
#include "Logger.mqh"
#include "SignalReader.mqh"
#include "RiskManager.mqh"

//--- Final, fully-priced trade intent. Everything in here has already passed the GLM
//--- signal gate, the technical confirmation filter and RiskManager's final gate — the
//--- only thing left for the caller to do is OrderSend() it (and re-check the gate once
//--- more immediately before doing so, per RiskManager's documented defense-in-depth use).
struct STradeIntent
  {
   bool             valid;
   ENUM_ORDER_TYPE  orderType;
   double           lot;
   double           sl;
   double           tp;
   double           slDistancePrice; // kept for the final RiskManager re-check before OrderSend
   string           signalId;
   string           reason;
  };

//--- Extra tunables Strategy.mqh needs beyond what's already in SRiskGateParams.
struct SStrategyParams
  {
   double minConfidenceThreshold;
   bool   allowSignalReversal;
   double slAtrMultiplierDefault;
   double tpAtrMultiplierDefault;
   double slAtrMultiplierMin;
   double slAtrMultiplierMax;
   double tpAtrMultiplierMin;
   double tpAtrMultiplierMax;
  };

namespace Strategy
  {
   int  g_atrHandle     = INVALID_HANDLE;
   int  g_emaFastHandle = INVALID_HANDLE;
   int  g_emaSlowHandle = INVALID_HANDLE;
   bool g_ready          = false;

   //--- Light trend-confirmation EMA periods. Intentionally short/simple — this is only a
   //--- sanity filter on top of the GLM signal, not a standalone strategy.
   #define XAUGLM_EMA_FAST_PERIOD 20
   #define XAUGLM_EMA_SLOW_PERIOD 50

   //--- Create the ATR + EMA indicator handles used for SL/TP sizing and the trend filter.
   //--- Must be called once from OnInit; returns false if any handle fails to create.
   bool Init(const int atrPeriod, const string symbol = NULL, const ENUM_TIMEFRAMES tf = PERIOD_CURRENT)
     {
      string sym = Utils::ResolveSymbol(symbol);

      g_atrHandle     = iATR(sym, tf, atrPeriod);
      g_emaFastHandle = iMA(sym, tf, XAUGLM_EMA_FAST_PERIOD, 0, MODE_EMA, PRICE_CLOSE);
      g_emaSlowHandle = iMA(sym, tf, XAUGLM_EMA_SLOW_PERIOD, 0, MODE_EMA, PRICE_CLOSE);

      if(g_atrHandle == INVALID_HANDLE || g_emaFastHandle == INVALID_HANDLE || g_emaSlowHandle == INVALID_HANDLE)
        {
         Logger::Error("Strategy::Init failed to create one or more indicator handles.");
         g_ready = false;
         return false;
        }

      g_ready = true;
      Logger::Info(StringFormat("Strategy initialized. ATR(%d) EMA(%d,%d) on %s.",
                                 atrPeriod, XAUGLM_EMA_FAST_PERIOD, XAUGLM_EMA_SLOW_PERIOD, sym));
      return true;
     }

   //--- Release indicator handles. Must be called from OnDeinit to avoid handle leaks.
   void Deinit()
     {
      if(g_atrHandle != INVALID_HANDLE)
        {
         IndicatorRelease(g_atrHandle);
         g_atrHandle = INVALID_HANDLE;
        }
      if(g_emaFastHandle != INVALID_HANDLE)
        {
         IndicatorRelease(g_emaFastHandle);
         g_emaFastHandle = INVALID_HANDLE;
        }
      if(g_emaSlowHandle != INVALID_HANDLE)
        {
         IndicatorRelease(g_emaSlowHandle);
         g_emaSlowHandle = INVALID_HANDLE;
        }
      g_ready = false;
     }

   //--- Current ATR value (shift 0 — live/forming bar, needed for responsive SL/TP sizing).
   //--- Returns 0.0 if the buffer isn't ready yet (e.g. right after OnInit).
   double GetCurrentAtr()
     {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(g_atrHandle, 0, 0, 1, buf) < 1)
         return 0.0;
      return buf[0];
     }

   //--- Fast/slow EMA values on the last FULLY CLOSED bar (shift 1) — deliberately not the
   //--- forming bar, so the trend filter isn't jittery tick-to-tick.
   bool GetTrendEmas(double &fastEma, double &slowEma)
     {
      double fastBuf[], slowBuf[];
      ArraySetAsSeries(fastBuf, true);
      ArraySetAsSeries(slowBuf, true);
      if(CopyBuffer(g_emaFastHandle, 0, 1, 1, fastBuf) < 1)
         return false;
      if(CopyBuffer(g_emaSlowHandle, 0, 1, 1, slowBuf) < 1)
         return false;
      fastEma = fastBuf[0];
      slowEma = slowBuf[0];
      return true;
     }

   //--- Count currently open positions on `symbol`+`magic` whose direction is opposite to
   //--- `intendedType`. Used to honor InpAllowSignalReversal=false (never auto-reverse).
   int CountOppositePositions(const ENUM_ORDER_TYPE intendedType, const int magicNumber,
                               const string symbol = NULL)
     {
      string sym = Utils::ResolveSymbol(symbol);
      ENUM_POSITION_TYPE oppositeType =
         (intendedType == ORDER_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;

      int count = 0;
      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != sym)
            continue;
         if((int)PositionGetInteger(POSITION_MAGIC) != magicNumber)
            continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == oppositeType)
            count++;
        }
      return count;
     }

   //--- Master strategy evaluation: signal validity -> confidence -> reversal policy ->
   //--- light technical confirmation -> SL/TP sizing -> RiskManager final gate. Returns
   //--- true only when `out` is a fully-formed, risk-approved trade intent ready to send.
   bool Evaluate(const SSignalReadResult &signalResult, const SStrategyParams &sp,
                 const SRiskGateParams &rp, STradeIntent &out)
     {
      out.valid           = false;
      out.orderType        = ORDER_TYPE_BUY;
      out.lot              = 0.0;
      out.sl               = 0.0;
      out.tp               = 0.0;
      out.slDistancePrice  = 0.0;
      out.signalId         = signalResult.signal.signalId;
      out.reason           = "";

      if(!signalResult.tradingAllowed)
        {
         out.reason = "signal not tradable: " + signalResult.blockReason;
         return false;
        }

      const SSignalData sig = signalResult.signal;

      if(sig.action == ACTION_HOLD)
        {
         out.reason = "signal action is HOLD";
         return false;
        }

      // Confidence gate — deliberately ">=" so a confidence exactly equal to the threshold
      // is ACCEPTED, per the documented parsing rule.
      if(sig.confidence < sp.minConfidenceThreshold)
        {
         out.reason = StringFormat("confidence %.1f below threshold %.1f", sig.confidence, sp.minConfidenceThreshold);
         Logger::Info(out.reason, sig.signalId);
         return false;
        }

      ENUM_ORDER_TYPE intendedType = (sig.action == ACTION_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

      if(!sp.allowSignalReversal)
        {
         int opposite = CountOppositePositions(intendedType, rp.magicNumber);
         if(opposite > 0)
           {
            out.reason = "opposite-direction position open and InpAllowSignalReversal=false";
            Logger::Info(out.reason, sig.signalId);
            return false;
           }
        }

      if(!g_ready)
        {
         out.reason = "Strategy indicators not ready";
         Logger::Error(out.reason, sig.signalId);
         return false;
        }

      double atrValue = GetCurrentAtr();
      if(atrValue <= 0.0)
        {
         out.reason = "ATR not ready/zero";
         Logger::Warn(out.reason, sig.signalId);
         return false;
        }

      double fastEma, slowEma;
      if(!GetTrendEmas(fastEma, slowEma))
        {
         out.reason = "EMA buffers not ready";
         Logger::Warn(out.reason, sig.signalId);
         return false;
        }

      // Light technical confirmation: reject only when the signal fights a *strong* short
      // EMA trend (more than half an ATR apart) — not meant to be a standalone filter, just
      // a sanity check against obviously counter-trend entries.
      double trendTolerance = atrValue * 0.5;
      if(intendedType == ORDER_TYPE_BUY && fastEma < slowEma - trendTolerance)
        {
         out.reason = "counter-trend filter: BUY signal against strong bearish EMA trend";
         Logger::Info(out.reason, sig.signalId);
         return false;
        }
      if(intendedType == ORDER_TYPE_SELL && fastEma > slowEma + trendTolerance)
        {
         out.reason = "counter-trend filter: SELL signal against strong bullish EMA trend";
         Logger::Info(out.reason, sig.signalId);
         return false;
        }

      double slMult = RiskManager::ClampAtrMultiplier(sig.slAtrMultiplier, sp.slAtrMultiplierDefault,
                                                        sp.slAtrMultiplierMin, sp.slAtrMultiplierMax, "SL");
      double tpMult = RiskManager::ClampAtrMultiplier(sig.tpAtrMultiplier, sp.tpAtrMultiplierDefault,
                                                        sp.tpAtrMultiplierMin, sp.tpAtrMultiplierMax, "TP");

      double slDistance = atrValue * slMult;
      double tpDistance = atrValue * tpMult;

      double entryPrice = (intendedType == ORDER_TYPE_BUY)
                              ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                              : SymbolInfoDouble(_Symbol, SYMBOL_BID);

      double slPrice = (intendedType == ORDER_TYPE_BUY) ? entryPrice - slDistance : entryPrice + slDistance;
      double tpPrice = (intendedType == ORDER_TYPE_BUY) ? entryPrice + tpDistance : entryPrice - tpDistance;

      slPrice = Utils::NormalizePrice(slPrice);
      tpPrice = Utils::NormalizePrice(tpPrice);

      // Mandatory project rule: never allow an order without a valid SL/TP.
      if(slPrice <= 0.0 || tpPrice <= 0.0)
        {
         out.reason = "computed SL/TP invalid (<=0)";
         Logger::Error(out.reason, sig.signalId);
         return false;
        }

      SRiskGateResult gateResult;
      RiskManager::EvaluateGate(rp, sig.action, slDistance, gateResult);
      if(!gateResult.allowed)
        {
         out.reason = "RiskManager gate rejected: " + gateResult.reason;
         Logger::Info(out.reason, sig.signalId);
         return false;
        }

      out.valid           = true;
      out.orderType        = intendedType;
      out.lot              = gateResult.lot;
      out.sl               = slPrice;
      out.tp               = tpPrice;
      out.slDistancePrice  = slDistance;
      out.reason           = "ok";
      return true;
     }
  }
