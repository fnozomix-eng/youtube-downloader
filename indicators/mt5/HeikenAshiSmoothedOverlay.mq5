//+------------------------------------------------------------------+
//|                                  HeikenAshiSmoothedOverlay.mq5    |
//|  平均足スムーズド (Heiken Ashi Smoothed) をローソク足チャートに   |
//|  重ねて表示するインジケーター                                     |
//|                                                                  |
//|  計算手順                                                         |
//|   1) 価格の O/H/L/C を 1段目の移動平均で平滑化                    |
//|   2) 平滑化した O/H/L/C から平均足を計算                          |
//|   3) 平均足の O/H/L/C を 2段目の移動平均でさらに平滑化            |
//+------------------------------------------------------------------+
#property copyright   "HeikenAshiSmoothedOverlay"
#property version     "1.00"
#property description "Heiken Ashi Smoothed overlay on the price chart"
#property indicator_chart_window
#property indicator_buffers 16
#property indicator_plots   2

//--- プロット0: ヒゲ (高値〜安値)
#property indicator_label1  "HAS High;HAS Low"
#property indicator_type1   DRAW_COLOR_HISTOGRAM2
#property indicator_color1  clrDodgerBlue,clrTomato
#property indicator_style1  STYLE_SOLID
#property indicator_width1  1

//--- プロット1: 実体 (始値〜終値)
#property indicator_label2  "HAS Open;HAS Close"
#property indicator_type2   DRAW_COLOR_HISTOGRAM2
#property indicator_color2  clrDodgerBlue,clrTomato
#property indicator_style2  STYLE_SOLID
#property indicator_width2  3

//--- 入力パラメーター
input group "平滑化設定"
input ENUM_MA_METHOD InpMaMethod1 = MODE_SMMA;   // 1段目 MA 種類 (価格の平滑化)
input int            InpMaPeriod1 = 6;           // 1段目 MA 期間
input ENUM_MA_METHOD InpMaMethod2 = MODE_LWMA;   // 2段目 MA 種類 (平均足の平滑化)
input int            InpMaPeriod2 = 2;           // 2段目 MA 期間

input group "表示設定"
input color InpBullColor       = clrDodgerBlue; // 陽線の色
input color InpBearColor       = clrTomato;     // 陰線の色
input int   InpBodyWidth       = 3;             // 実体の太さ (1-5)
input int   InpWickWidth       = 1;             // ヒゲの太さ (1-5)
input bool  InpShowWick        = true;          // ヒゲを表示する
input bool  InpPriceForeground = true;          // 通常ローソク足を前面に表示 (HASを背面へ)

input group "アラート"
input bool  InpAlert           = false;         // 色が変わったらアラート
input bool  InpAlertPush       = false;         // プッシュ通知も送る

//--- 表示用バッファ
double WickHighBuf[];
double WickLowBuf[];
double WickColorBuf[];
double BodyOpenBuf[];   // 平滑化後の始値 (2段目MAの再帰状態も兼ねる)
double BodyCloseBuf[];  // 平滑化後の終値
double BodyColorBuf[];

//--- 計算用バッファ
double MaO[], MaH[], MaL[], MaC[];   // 1段目MA
double HaO[], HaH[], HaL[], HaC[];   // 平均足
double SmH[], SmL[];                 // 2段目MA (高値・安値)

int      g_drawBegin   = 0;
bool     g_fgChanged   = false;
bool     g_fgOriginal  = false;
datetime g_lastAlertAt = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpMaPeriod1 < 1 || InpMaPeriod2 < 1)
     {
      Print("MA期間は1以上を指定してください");
      return(INIT_PARAMETERS_INCORRECT);
     }

   SetIndexBuffer(0,  WickHighBuf,  INDICATOR_DATA);
   SetIndexBuffer(1,  WickLowBuf,   INDICATOR_DATA);
   SetIndexBuffer(2,  WickColorBuf, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(3,  BodyOpenBuf,  INDICATOR_DATA);
   SetIndexBuffer(4,  BodyCloseBuf, INDICATOR_DATA);
   SetIndexBuffer(5,  BodyColorBuf, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(6,  MaO, INDICATOR_CALCULATIONS);
   SetIndexBuffer(7,  MaH, INDICATOR_CALCULATIONS);
   SetIndexBuffer(8,  MaL, INDICATOR_CALCULATIONS);
   SetIndexBuffer(9,  MaC, INDICATOR_CALCULATIONS);
   SetIndexBuffer(10, HaO, INDICATOR_CALCULATIONS);
   SetIndexBuffer(11, HaH, INDICATOR_CALCULATIONS);
   SetIndexBuffer(12, HaL, INDICATOR_CALCULATIONS);
   SetIndexBuffer(13, HaC, INDICATOR_CALCULATIONS);
   SetIndexBuffer(14, SmH, INDICATOR_CALCULATIONS);
   SetIndexBuffer(15, SmL, INDICATOR_CALCULATIONS);

   //--- 色・太さ
   for(int p = 0; p < 2; p++)
     {
      PlotIndexSetInteger(p, PLOT_COLOR_INDEXES, 2);
      PlotIndexSetInteger(p, PLOT_LINE_COLOR, 0, InpBullColor);
      PlotIndexSetInteger(p, PLOT_LINE_COLOR, 1, InpBearColor);
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
     }
   PlotIndexSetInteger(0, PLOT_LINE_WIDTH, MathMax(1, MathMin(5, InpWickWidth)));
   PlotIndexSetInteger(1, PLOT_LINE_WIDTH, MathMax(1, MathMin(5, InpBodyWidth)));

   //--- 2段階の平滑化が落ち着くまで描画しない (EMA/SMMA の初期ブレ対策で余裕を持たせる)
   g_drawBegin = InpMaPeriod1 + InpMaPeriod2;
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, g_drawBegin);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, g_drawBegin);

   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("HAS(%s %d, %s %d)",
                                   MaName(InpMaMethod1), InpMaPeriod1,
                                   MaName(InpMaMethod2), InpMaPeriod2));

   //--- 通常ローソク足を前面に (インジケーター描画が足の背面に回る)
   if(InpPriceForeground)
     {
      g_fgOriginal = (bool)ChartGetInteger(0, CHART_FOREGROUND);
      if(!g_fgOriginal)
        {
         ChartSetInteger(0, CHART_FOREGROUND, true);
         g_fgChanged = true;
        }
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   //--- 変更したチャート設定を元に戻す
   if(g_fgChanged)
      ChartSetInteger(0, CHART_FOREGROUND, g_fgOriginal);
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total <= g_drawBegin)
      return(0);

   //--- 古い足 = index 0 の並びで計算する
   ArraySetAsSeries(time,  false);
   ArraySetAsSeries(open,  false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);

   //--- 確定足は再計算しない。形成中の足 (最新足) だけ毎ティック更新
   int start = (prev_calculated > 0) ? prev_calculated - 1 : 0;

   for(int i = start; i < rates_total && !IsStopped(); i++)
     {
      //--- 1) 価格を平滑化
      MaO[i] = CalcMA(InpMaMethod1, InpMaPeriod1, i, open,  MaO);
      MaH[i] = CalcMA(InpMaMethod1, InpMaPeriod1, i, high,  MaH);
      MaL[i] = CalcMA(InpMaMethod1, InpMaPeriod1, i, low,   MaL);
      MaC[i] = CalcMA(InpMaMethod1, InpMaPeriod1, i, close, MaC);

      //--- 2) 平均足
      HaC[i] = (MaO[i] + MaH[i] + MaL[i] + MaC[i]) / 4.0;
      HaO[i] = (i == 0) ? (MaO[i] + MaC[i]) / 2.0
                        : (HaO[i - 1] + HaC[i - 1]) / 2.0;
      HaH[i] = MathMax(MaH[i], MathMax(HaO[i], HaC[i]));
      HaL[i] = MathMin(MaL[i], MathMin(HaO[i], HaC[i]));

      //--- 3) 平均足をさらに平滑化
      BodyOpenBuf[i]  = CalcMA(InpMaMethod2, InpMaPeriod2, i, HaO, BodyOpenBuf);
      BodyCloseBuf[i] = CalcMA(InpMaMethod2, InpMaPeriod2, i, HaC, BodyCloseBuf);
      SmH[i]          = CalcMA(InpMaMethod2, InpMaPeriod2, i, HaH, SmH);
      SmL[i]          = CalcMA(InpMaMethod2, InpMaPeriod2, i, HaL, SmL);

      //--- 色: 0=陽線, 1=陰線 (同値なら直前の色を維持)
      double clr;
      if(BodyOpenBuf[i] < BodyCloseBuf[i])
         clr = 0.0;
      else if(BodyOpenBuf[i] > BodyCloseBuf[i])
         clr = 1.0;
      else
         clr = (i > 0) ? BodyColorBuf[i - 1] : 0.0;
      BodyColorBuf[i] = clr;

      //--- ヒゲ: 平滑化後に実体がはみ出さないよう補正
      if(InpShowWick)
        {
         WickHighBuf[i]  = MathMax(SmH[i], MathMax(BodyOpenBuf[i], BodyCloseBuf[i]));
         WickLowBuf[i]   = MathMin(SmL[i], MathMin(BodyOpenBuf[i], BodyCloseBuf[i]));
         WickColorBuf[i] = clr;
        }
      else
        {
         WickHighBuf[i]  = EMPTY_VALUE;
         WickLowBuf[i]   = EMPTY_VALUE;
         WickColorBuf[i] = clr;
        }
     }

   //--- 確定足で色が変わったらアラート (ロード直後は鳴らさない)
   if(InpAlert && prev_calculated > 0 && rates_total > g_drawBegin + 2)
     {
      int last = rates_total - 2;   // 直近の確定足
      if(BodyColorBuf[last] != BodyColorBuf[last - 1] && time[rates_total - 1] != g_lastAlertAt)
        {
         g_lastAlertAt = time[rates_total - 1];
         string msg = StringFormat("%s %s: 平均足スムーズドが%sに転換",
                                   _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
                                   (BodyColorBuf[last] == 0.0) ? "陽線" : "陰線");
         Alert(msg);
         if(InpAlertPush)
            SendNotification(msg);
        }
     }

   return(rates_total);
  }

//+------------------------------------------------------------------+
//| 移動平均 (index 0 = 最古の足)                                     |
//|  src: 元データ / dst: この MA 自身の出力 (EMA・SMMA の再帰用)       |
//+------------------------------------------------------------------+
double CalcMA(const ENUM_MA_METHOD method, const int period, const int i,
              const double &src[], const double &dst[])
  {
   if(period <= 1 || i < period - 1)
      return(src[i]);

   switch(method)
     {
      case MODE_EMA:
        {
         if(i == period - 1)
            return(SimpleAverage(src, i, period));
         double k = 2.0 / (period + 1.0);
         return(dst[i - 1] + k * (src[i] - dst[i - 1]));
        }
      case MODE_SMMA:
        {
         if(i == period - 1)
            return(SimpleAverage(src, i, period));
         return((dst[i - 1] * (period - 1) + src[i]) / period);
        }
      case MODE_LWMA:
        {
         double sum = 0.0, wsum = 0.0;
         for(int k = 0; k < period; k++)
           {
            double w = period - k;
            sum  += src[i - k] * w;
            wsum += w;
           }
         return(sum / wsum);
        }
      default: // MODE_SMA
         return(SimpleAverage(src, i, period));
     }
  }

//+------------------------------------------------------------------+
double SimpleAverage(const double &src[], const int i, const int period)
  {
   double sum = 0.0;
   for(int k = 0; k < period; k++)
      sum += src[i - k];
   return(sum / period);
  }

//+------------------------------------------------------------------+
string MaName(const ENUM_MA_METHOD m)
  {
   switch(m)
     {
      case MODE_EMA:  return("EMA");
      case MODE_SMMA: return("SMMA");
      case MODE_LWMA: return("LWMA");
      default:        return("SMA");
     }
  }
//+------------------------------------------------------------------+
