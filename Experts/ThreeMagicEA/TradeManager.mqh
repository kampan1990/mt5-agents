//+------------------------------------------------------------------+
//|                                                 TradeManager.mqh |
//|     ThreeMagicEA - Order execution wrappers with error handling  |
//+------------------------------------------------------------------+
#ifndef THREEMAGIC_TRADEMANAGER_MQH
#define THREEMAGIC_TRADEMANAGER_MQH
#property strict

#include "Utils.mqh"
#include "Logger.mqh"
#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/OrderInfo.mqh>

//+------------------------------------------------------------------+
//| Lightweight record describing one open position                 |
//+------------------------------------------------------------------+
struct PositionRec
  {
   ulong             ticket;
   double            openPrice;
   double            volume;
   long              type;      // POSITION_TYPE_BUY / SELL
   double            profit;
  };

//+------------------------------------------------------------------+
//| CTradeManager                                                   |
//+------------------------------------------------------------------+
class CTradeManager
  {
private:
   CUtils           *m_utils;
   CLogger          *m_log;
   CTrade            m_trade;
   CPositionInfo     m_pos;
   COrderInfo        m_ord;
   int               m_slippage;

   void              Configure(long magic)
     {
      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints(m_slippage);
      m_trade.SetTypeFillingBySymbol(m_utils.Symbol());
      m_trade.SetAsyncMode(false);
     }

   bool              LogResult(const string ctx,bool ok)
     {
      uint rc=m_trade.ResultRetcode();
      if(!ok || (rc!=TRADE_RETCODE_DONE && rc!=TRADE_RETCODE_PLACED && rc!=TRADE_RETCODE_DONE_PARTIAL))
        {
         if(m_log!=NULL)
            m_log.Error("TRADE",StringFormat("%s FAILED: %s (retcode=%u, lastError=%d)",
                        ctx,m_trade.ResultRetcodeDescription(),rc,GetLastError()));
         return false;
        }
      if(m_log!=NULL)
         m_log.Info("TRADE",StringFormat("%s OK (retcode=%u, deal=%I64u, order=%I64u)",
                    ctx,rc,m_trade.ResultDeal(),m_trade.ResultOrder()));
      return true;
     }

public:
                     CTradeManager(void){ m_utils=NULL; m_log=NULL; m_slippage=30; }

   void              Init(CUtils *utils,CLogger *log,int slippagePoints)
     {
      m_utils=utils;
      m_log=log;
      m_slippage=slippagePoints;
     }

   //--------------------------------------------------------------------
   //  Market entries
   //--------------------------------------------------------------------
   bool              OpenMarket(long magic,ENUM_SIDE side,double lots,
                                double sl,double tp,const string comment)
     {
      Configure(magic);
      bool ok;
      if(side==SIDE_BUY)
         ok=m_trade.Buy(lots,m_utils.Symbol(),0.0,sl,tp,comment);
      else
         ok=m_trade.Sell(lots,m_utils.Symbol(),0.0,sl,tp,comment);
      return LogResult(StringFormat("OpenMarket %s %.2f",(side==SIDE_BUY?"BUY":"SELL"),lots),ok);
     }

   //--------------------------------------------------------------------
   //  Pending orders
   //--------------------------------------------------------------------
   bool              PlacePending(long magic,ENUM_ORDER_TYPE type,double price,double lots,
                                  double sl,double tp,const string comment)
     {
      Configure(magic);
      price=m_utils.Normalize(price);
      bool ok=false;
      switch(type)
        {
         case ORDER_TYPE_BUY_LIMIT:  ok=m_trade.BuyLimit (lots,price,m_utils.Symbol(),sl,tp,ORDER_TIME_GTC,0,comment); break;
         case ORDER_TYPE_SELL_LIMIT: ok=m_trade.SellLimit(lots,price,m_utils.Symbol(),sl,tp,ORDER_TIME_GTC,0,comment); break;
         case ORDER_TYPE_BUY_STOP:   ok=m_trade.BuyStop  (lots,price,m_utils.Symbol(),sl,tp,ORDER_TIME_GTC,0,comment); break;
         case ORDER_TYPE_SELL_STOP:  ok=m_trade.SellStop (lots,price,m_utils.Symbol(),sl,tp,ORDER_TIME_GTC,0,comment); break;
         default:
            if(m_log!=NULL) m_log.Error("TRADE","PlacePending: unsupported order type");
            return false;
        }
      return LogResult(StringFormat("PlacePending type=%d @ %.5f x%.2f",type,price,lots),ok);
     }

   //--------------------------------------------------------------------
   //  Modify SL/TP of a position
   //--------------------------------------------------------------------
   bool              ModifyPosition(ulong ticket,double sl,double tp)
     {
      if(!m_pos.SelectByTicket(ticket))
         return false;
      Configure(m_pos.Magic());
      bool ok=m_trade.PositionModify(ticket,sl,tp);
      return LogResult(StringFormat("ModifyPosition #%I64u sl=%.5f tp=%.5f",ticket,sl,tp),ok);
     }

   //--------------------------------------------------------------------
   //  Closing helpers
   //--------------------------------------------------------------------
   bool              CloseByTicket(ulong ticket)
     {
      if(!m_pos.SelectByTicket(ticket))
         return false;
      Configure(m_pos.Magic());
      bool ok=m_trade.PositionClose(ticket);
      return LogResult(StringFormat("ClosePosition #%I64u",ticket),ok);
     }

   //--- partial close of a position
   bool              ClosePartial(ulong ticket,double volume)
     {
      if(!m_pos.SelectByTicket(ticket))
         return false;
      Configure(m_pos.Magic());
      bool ok=m_trade.PositionClosePartial(ticket,volume);
      return LogResult(StringFormat("ClosePartial #%I64u vol=%.2f",ticket,volume),ok);
     }

   int               CloseAllPositions(long magic)
     {
      int closed=0;
      // iterate backwards because closing changes the list
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         if(!m_pos.SelectByIndex(i)) continue;
         if(m_pos.Symbol()!=m_utils.Symbol()) continue;
         if(m_pos.Magic()!=magic) continue;
         if(CloseByTicket(m_pos.Ticket()))
            closed++;
        }
      return closed;
     }

   int               DeleteAllPending(long magic)
     {
      int deleted=0;
      for(int i=OrdersTotal()-1;i>=0;i--)
        {
         ulong tk=OrderGetTicket(i);
         if(tk==0) continue;
         if(!m_ord.Select(tk)) continue;
         if(m_ord.Symbol()!=m_utils.Symbol()) continue;
         if(m_ord.Magic()!=magic) continue;
         Configure(magic);
         if(m_trade.OrderDelete(tk))
            deleted++;
        }
      return deleted;
     }

   //--- close everything (positions + pendings) that belongs to a magic
   void              CloseGroup(long magic)
     {
      CloseAllPositions(magic);
      DeleteAllPending(magic);
     }

   //--------------------------------------------------------------------
   //  Counting / inspection
   //--------------------------------------------------------------------
   int               CountPositions(long magic,int typeFilter=-1)
     {
      int c=0;
      for(int i=0;i<PositionsTotal();i++)
        {
         if(!m_pos.SelectByIndex(i)) continue;
         if(m_pos.Symbol()!=m_utils.Symbol()) continue;
         if(m_pos.Magic()!=magic) continue;
         if(typeFilter>=0 && (int)m_pos.PositionType()!=typeFilter) continue;
         c++;
        }
      return c;
     }

   int               CountPending(long magic)
     {
      int c=0;
      for(int i=0;i<OrdersTotal();i++)
        {
         ulong tk=OrderGetTicket(i);
         if(tk==0) continue;
         if(!m_ord.Select(tk)) continue;
         if(m_ord.Symbol()!=m_utils.Symbol()) continue;
         if(m_ord.Magic()!=magic) continue;
         c++;
        }
      return c;
     }

   //--- fill an array with all open positions for a magic; returns count
   int               GetPositions(long magic,PositionRec &arr[])
     {
      ArrayResize(arr,0);
      int c=0;
      for(int i=0;i<PositionsTotal();i++)
        {
         if(!m_pos.SelectByIndex(i)) continue;
         if(m_pos.Symbol()!=m_utils.Symbol()) continue;
         if(m_pos.Magic()!=magic) continue;
         ArrayResize(arr,c+1);
         arr[c].ticket   =m_pos.Ticket();
         arr[c].openPrice=m_pos.PriceOpen();
         arr[c].volume   =m_pos.Volume();
         arr[c].type     =m_pos.PositionType();
         arr[c].profit   =m_pos.Profit()+m_pos.Swap()+m_pos.Commission();
         c++;
        }
      return c;
     }

   //--- dominant side currently held by a magic (net by volume)
   ENUM_SIDE         NetSide(long magic)
     {
      double buyVol=0.0,sellVol=0.0;
      for(int i=0;i<PositionsTotal();i++)
        {
         if(!m_pos.SelectByIndex(i)) continue;
         if(m_pos.Symbol()!=m_utils.Symbol()) continue;
         if(m_pos.Magic()!=magic) continue;
         if(m_pos.PositionType()==POSITION_TYPE_BUY) buyVol+=m_pos.Volume();
         else                                        sellVol+=m_pos.Volume();
        }
      if(buyVol==0.0 && sellVol==0.0) return SIDE_NONE;
      return (buyVol>=sellVol ? SIDE_BUY : SIDE_SELL);
     }
  };
//+------------------------------------------------------------------+
#endif // THREEMAGIC_TRADEMANAGER_MQH
