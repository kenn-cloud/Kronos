//+------------------------------------------------------------------+
//|                     Aggressive Multi-Trade Gold Scalper          |
//|                     High frequency basket style                  |
//+------------------------------------------------------------------+
#property copyright "Educational - High Risk"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//=== INPUTS ========================================================
input group "=== Money & Risk ==="
input double   LotSize                 = 0.01;      // Lot size per trade
input double   BasketProfitTarget      = 5.0;       // Close ALL trades when total profit reaches this $ amount
input int      MaxOpenTrades           = 8;         // Maximum number of open trades
input int      MinDistancePoints       = 80;        // Minimum distance between new trades (points)
input int      MagicNumber             = 20251030;  // Magic Number

input group "=== Indicators ==="
input int      FastEMA_Period          = 5;         // Fast EMA
input int      SlowEMA_Period          = 13;        // Slow EMA
input int      RSI_Period              = 7;         // RSI period (faster = more aggressive)
input int      RSI_Level               = 50;        // RSI filter level

input group "=== Filters ==="
input int      MaxSpreadPoints         = 40;        // Max allowed spread
input bool     TradeOnlyNewBar         = false;     // false = more aggressive (every tick)

input group "=== Optional Protection ==="
input bool     UseIndividualSL         = false;     // Individual Stop Loss per trade
input int      IndividualSLPoints      = 300;       // SL in points (only if enabled)
input bool     UseTrailingOnBasket     = false;     // Simple trailing on basket profit

//=== Global ========================================================
int handleFastEMA, handleSlowEMA, handleRSI;
datetime lastBarTime = 0;
string symbol;

//+------------------------------------------------------------------+
int OnInit()
{
   symbol = _Symbol;
   
   handleFastEMA = iMA(symbol, PERIOD_CURRENT, FastEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA = iMA(symbol, PERIOD_CURRENT, SlowEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI     = iRSI(symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);

   if(handleFastEMA == INVALID_HANDLE || handleSlowEMA == INVALID_HANDLE || handleRSI == INVALID_HANDLE)
   {
      Print("Failed to create indicators");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   Print("Aggressive Multi-Trade Scalper started on ", symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleFastEMA);
   IndicatorRelease(handleSlowEMA);
   IndicatorRelease(handleRSI);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // New bar filter (optional)
   if(TradeOnlyNewBar)
   {
      datetime currentBar = iTime(symbol, PERIOD_CURRENT, 0);
      if(currentBar == lastBarTime) return;
      lastBarTime = currentBar;
   }

   // Spread filter
   if(SymbolInfoInteger(symbol, SYMBOL_SPREAD) > MaxSpreadPoints) return;

   //=== 1. Check Basket Profit and Close All if target reached ===
   double totalProfit = GetTotalProfit();
   
   if(totalProfit >= BasketProfitTarget)
   {
      CloseAllPositions();
      Print("Basket closed in profit: $", DoubleToString(totalProfit, 2));
      return;
   }

   //=== 2. Get direction ===
   double fastEMA[], slowEMA[], rsi[];
   ArraySetAsSeries(fastEMA, true);
   ArraySetAsSeries(slowEMA, true);
   ArraySetAsSeries(rsi, true);

   if(CopyBuffer(handleFastEMA, 0, 0, 3, fastEMA) < 3) return;
   if(CopyBuffer(handleSlowEMA, 0, 0, 3, slowEMA) < 3) return;
   if(CopyBuffer(handleRSI, 0, 0, 3, rsi) < 3) return;

   bool bullish = (fastEMA[0] > slowEMA[0]) && (rsi[0] > RSI_Level);
   bool bearish = (fastEMA[0] < slowEMA[0]) && (rsi[0] < RSI_Level);

   int openTrades = CountOpenTrades();

   //=== 3. Open new trades if conditions met ===
   if(openTrades < MaxOpenTrades)
   {
      if(bullish && CanOpenNewTrade(ORDER_TYPE_BUY))
      {
         OpenBuy();
      }
      else if(bearish && CanOpenNewTrade(ORDER_TYPE_SELL))
      {
         OpenSell();
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate total floating profit of all our trades                |
//+------------------------------------------------------------------+
double GetTotalProfit()
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }
   return profit;
}

//+------------------------------------------------------------------+
//| Count our open trades                                            |
//+------------------------------------------------------------------+
int CountOpenTrades()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check minimum distance from last trade                           |
//+------------------------------------------------------------------+
bool CanOpenNewTrade(ENUM_ORDER_TYPE type)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double lastPrice = 0;
   datetime lastTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         if(PositionGetInteger(POSITION_TYPE) == type)
         {
            datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
            if(posTime > lastTime)
            {
               lastTime = posTime;
               lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            }
         }
      }
   }

   if(lastPrice == 0) return true; // no previous trade

   double currentPrice = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK) 
                                                  : SymbolInfoDouble(symbol, SYMBOL_BID);

   double distance = MathAbs(currentPrice - lastPrice) / point;
   return distance >= MinDistancePoints;
}

//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   double sl = 0;
   if(UseIndividualSL)
      sl = NormalizeDouble(ask - IndividualSLPoints * point, digits);

   if(trade.Buy(LotSize, symbol, ask, sl, 0, "Multi Buy"))
      Print("BUY opened | Total trades: ", CountOpenTrades());
}

//+------------------------------------------------------------------+
void OpenSell()
{
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   double sl = 0;
   if(UseIndividualSL)
      sl = NormalizeDouble(bid + IndividualSLPoints * point, digits);

   if(trade.Sell(LotSize, symbol, bid, sl, 0, "Multi Sell"))
      Print("SELL opened | Total trades: ", CountOpenTrades());
}

//+------------------------------------------------------------------+
//| Close all positions with our magic number                        |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         trade.PositionClose(ticket);
      }
   }
}
//+------------------------------------------------------------------+