//+------------------------------------------------------------------+
//|  MTF_GMMA.mq5                                                    |
//|  MTF GMMA（複合型移動平均線）+ アラート                          |
//|   - 短期群 EMA 3,5,8,10,12,15 / 長期群 EMA 30,35,40,45,50,60     |
//|   - 2系統（時間足を個別指定 = MTF）                              |
//|   - 線の色: 上向き = 同色系グラデーション / 横ばい = 黄色 /      |
//|             下向き = 同色系グラデーション                        |
//|   - アラート: 群へのタッチ / 群の上抜け・下抜け / GC・DC         |
//+------------------------------------------------------------------+
#property copyright   "MTF GMMA"
#property version     "1.00"
#property description "MTF GMMA + タッチ / 上抜け・下抜け / ゴールデンクロス・デッドクロス アラート"
#property indicator_chart_window
#property indicator_buffers 52
#property indicator_plots   28

enum ENUM_CROSS_MODE
  {
   CROSS_AVG = 0, // 平均線（短期群平均 × 長期群平均）
   CROSS_ALL = 1  // 群全体（短期群すべてが長期群すべてを抜ける）
  };

//--- 入力
input group "■ GMMA 設定"
input int             InpS1 = 3;                     // 短期1
input int             InpS2 = 5;                     // 短期2
input int             InpS3 = 8;                     // 短期3
input int             InpS4 = 10;                    // 短期4
input int             InpS5 = 12;                    // 短期5
input int             InpS6 = 15;                    // 短期6
input int             InpL1 = 30;                    // 長期1
input int             InpL2 = 35;                    // 長期2
input int             InpL3 = 40;                    // 長期3
input int             InpL4 = 45;                    // 長期4
input int             InpL5 = 50;                    // 長期5
input int             InpL6 = 60;                    // 長期6
input int             InpSlopeLen  = 1;              // 傾き判定の本数
input double          InpFlatThr   = 0.05;           // 横ばい判定（ATR(14)倍率）
input bool            InpNoRepaint = true;           // 上位足はリペイント防止（確定値を使用）
input int             InpMaxBars   = 5000;           // 計算する最大バー数（0 = 全て）

input group "■ GMMA 1"
input bool            InpShow1 = true;               // GMMA1 表示
input ENUM_TIMEFRAMES InpTF1   = PERIOD_CURRENT;     // GMMA1 時間足

input group "■ GMMA 2（上位足）"
input bool            InpShow2 = true;               // GMMA2 表示
input ENUM_TIMEFRAMES InpTF2   = PERIOD_H4;          // GMMA2 時間足

input group "■ 色（上向き/下向きは同色系グラデーション）"
input color           InpUpLight = C'185,246,202';   // 上向き 短期側
input color           InpUpDark  = C'27,94,32';      // 上向き 長期側
input color           InpDnLight = C'255,138,128';   // 下向き 短期側
input color           InpDnDark  = C'127,0,0';       // 下向き 長期側
input color           InpFlat    = clrYellow;        // 横ばい
input int             InpWidth2  = 2;                // GMMA2 線の太さ
input bool            InpShowX   = true;             // GC / DC 矢印表示

input group "■ アラート"
input bool            InpAlSet1   = true;            // GMMA1 を対象
input bool            InpAlSet2   = true;            // GMMA2 を対象
input bool            InpAlTouch  = true;            // タッチ（群の帯に触れた最初の足）
input bool            InpAlBreak  = true;            // 上抜け / 下抜け（終値で群を抜けた足）
input bool            InpGrpShort = true;            // 対象: 短期群
input bool            InpGrpLong  = true;            // 対象: 長期群
input bool            InpAlCross  = true;            // ゴールデンクロス / デッドクロス
input ENUM_CROSS_MODE InpCrossMode = CROSS_AVG;      // クロス判定
input bool            InpConfOnly = true;            // 確定足のみで発報（チャート足）
input bool            InpPopup    = true;            // ポップアップ
input bool            InpPush     = false;           // プッシュ通知（スマホ）
input bool            InpMail     = false;           // メール

//--- バッファ
struct SBuf { double v[]; };
SBuf g_buf[52];   // 0..47: (値, 色index) × 24本 / 48..51: GC1, DC1, GC2, DC2

//--- 状態
ENUM_TIMEFRAMES g_tf[2];
bool            g_higher[2];
bool            g_alert[2];
int             g_h[2][12];
int             g_hATR[2];
int             g_per[12];
datetime        g_lastBarTime = 0;
string          g_sentThisBar = "";
bool            g_needRefresh = false;

//+------------------------------------------------------------------+
//| ヘルパー                                                         |
//+------------------------------------------------------------------+
int    ValBuf(const int s, const int k) { return (s * 12 + k) * 2; }
double Val(const int s, const int k, const int i) { return g_buf[ValBuf(s, k)].v[i]; }

string TFName(const ENUM_TIMEFRAMES tf) { return StringSubstr(EnumToString(tf), 7); }

color Grad(const color c1, const color c2, const int idx)
  {
   double t = idx / 11.0;
   int r = (int)MathRound(((c1)       & 0xFF) * (1 - t) + ((c2)       & 0xFF) * t);
   int g = (int)MathRound(((c1 >> 8)  & 0xFF) * (1 - t) + ((c2 >> 8)  & 0xFF) * t);
   int b = (int)MathRound(((c1 >> 16) & 0xFF) * (1 - t) + ((c2 >> 16) & 0xFF) * t);
   return (color)(r | (g << 8) | (b << 16));
  }

//--- 群の最上 / 最下 / 平均（grp 0 = 短期, 1 = 長期）
bool Zone(const int s, const int grp, const int i, double &hi, double &lo, double &avg)
  {
   hi = -DBL_MAX; lo = DBL_MAX; avg = 0;
   for(int k = grp * 6; k < grp * 6 + 6; k++)
     {
      double v = Val(s, k, i);
      if(v == EMPTY_VALUE)
         return false;
      hi = MathMax(hi, v);
      lo = MathMin(lo, v);
      avg += v;
     }
   avg /= 6.0;
   return true;
  }

//--- バー i のクロス判定: 1 = GC, -1 = DC, 0 = なし
int CrossAt(const int s, const int i, const int rates_total)
  {
   if(i + 1 >= rates_total)
      return 0;
   double sH, sL, sA, lH, lL, lA, sHp, sLp, sAp, lHp, lLp, lAp;
   if(!Zone(s, 0, i, sH, sL, sA) || !Zone(s, 1, i, lH, lL, lA))         return 0;
   if(!Zone(s, 0, i + 1, sHp, sLp, sAp) || !Zone(s, 1, i + 1, lHp, lLp, lAp)) return 0;
   if(InpCrossMode == CROSS_AVG)
     {
      if(sA > lA && sAp <= lAp) return 1;
      if(sA < lA && sAp >= lAp) return -1;
     }
   else
     {
      if(sL > lH && !(sLp > lHp)) return 1;
      if(sH < lL && !(sHp < lLp)) return -1;
     }
   return 0;
  }

void AddLine(string &out, const string line)
  {
   if(StringFind(g_sentThisBar, line + "|") >= 0)
      return;
   g_sentThisBar += line + "|";
   out += line + "\n";
  }

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   for(int s = 0; s < 2; s++)
     {
      g_hATR[s] = INVALID_HANDLE;
      for(int k = 0; k < 12; k++)
         g_h[s][k] = INVALID_HANDLE;
     }
   g_per[0] = InpS1; g_per[1] = InpS2; g_per[2]  = InpS3; g_per[3]  = InpS4; g_per[4]  = InpS5; g_per[5]  = InpS6;
   g_per[6] = InpL1; g_per[7] = InpL2; g_per[8]  = InpL3; g_per[9]  = InpL4; g_per[10] = InpL5; g_per[11] = InpL6;
   for(int k = 0; k < 12; k++)
      if(g_per[k] < 1)
         return INIT_PARAMETERS_INCORRECT;
   if(InpSlopeLen < 1)
      return INIT_PARAMETERS_INCORRECT;

   g_tf[0] = (InpTF1 == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTF1;
   g_tf[1] = (InpTF2 == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTF2;
   g_alert[0] = InpAlSet1;
   g_alert[1] = InpAlSet2;
   bool show[2];
   show[0] = InpShow1;
   show[1] = InpShow2;

   for(int b = 0; b < 52; b++)
     {
      bool isColor = (b < 48) && (b % 2 == 1);
      SetIndexBuffer(b, g_buf[b].v, isColor ? INDICATOR_COLOR_INDEX : INDICATOR_DATA);
      ArraySetAsSeries(g_buf[b].v, true);
     }

   //--- GMMA ライン（DRAW_COLOR_LINE: 0 = 上向き, 1 = 横ばい, 2 = 下向き）
   for(int s = 0; s < 2; s++)
     {
      string pre = "G" + (string)(s + 1) + "[" + TFName(g_tf[s]) + "] ";
      for(int k = 0; k < 12; k++)
        {
         int p = s * 12 + k;
         PlotIndexSetInteger(p, PLOT_DRAW_TYPE, show[s] ? DRAW_COLOR_LINE : DRAW_NONE);
         PlotIndexSetInteger(p, PLOT_COLOR_INDEXES, 3);
         PlotIndexSetInteger(p, PLOT_LINE_COLOR, 0, Grad(InpUpLight, InpUpDark, k));
         PlotIndexSetInteger(p, PLOT_LINE_COLOR, 1, InpFlat);
         PlotIndexSetInteger(p, PLOT_LINE_COLOR, 2, Grad(InpDnLight, InpDnDark, k));
         int w = (s == 0) ? (k < 6 ? 1 : 2) : (k < 6 ? InpWidth2 : InpWidth2 + 1);
         PlotIndexSetInteger(p, PLOT_LINE_WIDTH, w);
         PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
         PlotIndexSetString(p, PLOT_LABEL, pre + (k < 6 ? "短期" : "長期") + "EMA" + (string)g_per[k]);
        }
     }

   //--- GC / DC 矢印
   for(int a = 0; a < 4; a++)
     {
      int  p    = 24 + a;
      int  s    = a / 2;
      bool isGC = (a % 2 == 0);
      PlotIndexSetInteger(p, PLOT_DRAW_TYPE, (InpShowX && show[s]) ? DRAW_ARROW : DRAW_NONE);
      PlotIndexSetInteger(p, PLOT_ARROW, isGC ? 233 : 234);
      PlotIndexSetInteger(p, PLOT_ARROW_SHIFT, isGC ? 15 + s * 15 : -15 - s * 15);
      PlotIndexSetInteger(p, PLOT_LINE_COLOR, isGC ? InpUpDark : InpDnDark);
      PlotIndexSetInteger(p, PLOT_LINE_WIDTH, s == 0 ? 1 : 2);
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
      PlotIndexSetString(p, PLOT_LABEL, "G" + (string)(s + 1) + (isGC ? " GC" : " DC"));
     }

   //--- ハンドル
   for(int s = 0; s < 2; s++)
     {
      g_higher[s] = PeriodSeconds(g_tf[s]) > PeriodSeconds((ENUM_TIMEFRAMES)_Period);
      for(int k = 0; k < 12; k++)
        {
         g_h[s][k] = iMA(_Symbol, g_tf[s], g_per[k], 0, MODE_EMA, PRICE_CLOSE);
         if(g_h[s][k] == INVALID_HANDLE)
            return INIT_FAILED;
        }
      g_hATR[s] = iATR(_Symbol, g_tf[s], 14);
      if(g_hATR[s] == INVALID_HANDLE)
         return INIT_FAILED;
     }

   IndicatorSetString(INDICATOR_SHORTNAME, "MTF GMMA " + TFName(g_tf[0]) + "/" + TFName(g_tf[1]));
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   g_lastBarTime = 0;
   g_sentThisBar = "";
   EventSetTimer(2);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int s = 0; s < 2; s++)
     {
      for(int k = 0; k < 12; k++)
         if(g_h[s][k] != INVALID_HANDLE) IndicatorRelease(g_h[s][k]);
      if(g_hATR[s] != INVALID_HANDLE) IndicatorRelease(g_hATR[s]);
     }
  }

void OnTimer()
  {
   if(g_needRefresh)
     {
      g_needRefresh = false;
      ChartSetSymbolPeriod(0, _Symbol, _Period);
     }
  }

//+------------------------------------------------------------------+
//| 1系統の GMMA を計算                                              |
//+------------------------------------------------------------------+
bool CalcSet(const int s, const int limit, const int rates_total, const datetime &time[])
  {
   ENUM_TIMEFRAMES tf = g_tf[s];
   int off = (InpNoRepaint && g_higher[s]) ? 1 : 0;
   int lim = limit;
   if(g_higher[s] && off == 0)
     {
      int sh0 = iBarShift(_Symbol, _Period, iTime(_Symbol, tf, 0), false);
      if(sh0 > lim) lim = sh0;
     }
   if(lim > rates_total - 2) lim = rates_total - 2;

   int htfBars = Bars(_Symbol, tf);
   int maxSh   = iBarShift(_Symbol, tf, time[lim], false);
   if(maxSh < 0) maxSh = htfBars - 1;
   int need = MathMin(maxSh + off + InpSlopeLen + 1, htfBars);
   if(need <= 0)
      return false;

   SBuf ma[12];
   for(int k = 0; k < 12; k++)
     {
      if(BarsCalculated(g_h[s][k]) < need)
         return false;
      ArraySetAsSeries(ma[k].v, true);
      if(CopyBuffer(g_h[s][k], 0, 0, need, ma[k].v) < need)
         return false;
     }
   double atr[];
   ArraySetAsSeries(atr, true);
   if(BarsCalculated(g_hATR[s]) < need || CopyBuffer(g_hATR[s], 0, 0, need, atr) < need)
      return false;

   for(int i = lim; i >= 0; i--)
     {
      int sh = iBarShift(_Symbol, tf, time[i], false);
      if(sh >= 0) sh += off;
      for(int k = 0; k < 12; k++)
        {
         double v = EMPTY_VALUE, c = 1;
         if(sh >= 0 && sh + InpSlopeLen < need && sh <= htfBars - g_per[k] - 1 && ma[k].v[sh] != EMPTY_VALUE)
           {
            v = ma[k].v[sh];
            double prev = ma[k].v[sh + InpSlopeLen];
            double thr  = (atr[sh] != EMPTY_VALUE) ? atr[sh] * InpFlatThr : 0.0;
            double d    = v - prev;
            c = (d > thr) ? 0 : (d < -thr) ? 2 : 1;
           }
         g_buf[ValBuf(s, k)].v[i]     = v;
         g_buf[ValBuf(s, k) + 1].v[i] = c;
        }
     }
   return true;
  }

//--- GC / DC 矢印
void CalcArrows(const int s, const int limit, const int rates_total, const double &high[], const double &low[])
  {
   for(int i = limit; i >= 0; i--)
     {
      int x = CrossAt(s, i, rates_total);
      g_buf[48 + s * 2].v[i]     = (x == 1)  ? low[i]  : EMPTY_VALUE;
      g_buf[48 + s * 2 + 1].v[i] = (x == -1) ? high[i] : EMPTY_VALUE;
     }
  }

//+------------------------------------------------------------------+
//| アラート判定（チャート足 j）                                     |
//+------------------------------------------------------------------+
void CheckZone(const int s, const int grp, const int j, string &out,
               const double &high[], const double &low[], const double &close[])
  {
   double hi, lo, avg, hiP, loP, avgP;
   if(!Zone(s, grp, j, hi, lo, avg) || !Zone(s, grp, j + 1, hiP, loP, avgP))
      return;
   string lbl = "[" + TFName(g_tf[s]) + "] " + (grp == 0 ? "短期群" : "長期群");

   bool inZ  = high[j] >= lo && low[j] <= hi;
   bool inZP = high[j + 1] >= loP && low[j + 1] <= hiP;
   if(InpAlTouch && inZ && !inZP)
     {
      string dir = (close[j + 1] > hiP) ? "（上から）" : (close[j + 1] < loP) ? "（下から）" : "";
      AddLine(out, lbl + " タッチ" + dir);
     }
   if(InpAlBreak)
     {
      if(close[j] > hi && close[j + 1] <= hiP) AddLine(out, lbl + " 上抜け");
      if(close[j] < lo && close[j + 1] >= loP) AddLine(out, lbl + " 下抜け");
     }
  }

void Notify(const string body, const double price)
  {
   string head = _Symbol + " (" + TFName((ENUM_TIMEFRAMES)_Period) + ") 価格 " + DoubleToString(price, _Digits);
   string lines[];
   int n = StringSplit(body, '\n', lines);
   string joined = "";
   for(int i = 0; i < n; i++)
     {
      if(lines[i] == "")
         continue;
      if(InpPopup)
         Alert(head + " " + lines[i]);
      joined += (joined == "" ? "" : " / ") + lines[i];
     }
   if(InpPush)
      SendNotification(StringSubstr(head + " " + joined, 0, 255));
   if(InpMail)
      SendMail("MTF GMMA " + _Symbol, head + "\n" + body);
  }

//+------------------------------------------------------------------+
//| メイン                                                           |
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
   ArraySetAsSeries(time, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   if(rates_total < 10)
      return 0;

   int limit;
   if(prev_calculated <= 0)
     {
      limit = rates_total - 2;
      if(InpMaxBars > 0 && limit > InpMaxBars - 1)
         limit = InpMaxBars - 1;
      for(int b = 0; b < 52; b++)
         ArrayInitialize(g_buf[b].v, (b < 48 && b % 2 == 1) ? 1.0 : EMPTY_VALUE);
     }
   else
     {
      limit = rates_total - prev_calculated;
      if(limit < 1) limit = 1;
     }

   for(int s = 0; s < 2; s++)
     {
      if(!CalcSet(s, limit, rates_total, time))
        {
         g_needRefresh = true; // 上位足のデータ準備待ち
         return 0;
        }
     }
   for(int s = 0; s < 2; s++)
     {
      int lim = limit;
      if(g_higher[s] && !InpNoRepaint)
        {
         int sh0 = iBarShift(_Symbol, _Period, iTime(_Symbol, g_tf[s], 0), false);
         if(sh0 > lim) lim = sh0;
        }
      if(lim > rates_total - 2) lim = rates_total - 2;
      CalcArrows(s, lim, rates_total, high, low);
     }

   //--- アラート
   bool newBar = (time[0] != g_lastBarTime);
   if(prev_calculated <= 0 || g_lastBarTime == 0)
     {
      g_lastBarTime = time[0]; // 初回は過去分を通知しない
      return rates_total;
     }
   if(newBar)
     {
      g_lastBarTime = time[0];
      g_sentThisBar = "";
     }
   if(InpConfOnly && !newBar)
      return rates_total;

   int j = InpConfOnly ? 1 : 0;
   string msg = "";
   for(int s = 0; s < 2; s++)
     {
      if(!g_alert[s])
         continue;
      if(InpAlTouch || InpAlBreak)
        {
         if(InpGrpShort) CheckZone(s, 0, j, msg, high, low, close);
         if(InpGrpLong)  CheckZone(s, 1, j, msg, high, low, close);
        }
      if(InpAlCross)
        {
         int x = CrossAt(s, j, rates_total);
         if(x == 1)  AddLine(msg, "[" + TFName(g_tf[s]) + "] ゴールデンクロス");
         if(x == -1) AddLine(msg, "[" + TFName(g_tf[s]) + "] デッドクロス");
        }
     }
   if(msg != "")
      Notify(msg, close[0]);

   return rates_total;
  }
//+------------------------------------------------------------------+
