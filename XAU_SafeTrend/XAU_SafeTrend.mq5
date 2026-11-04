//+------------------------------------------------------------------+
//|                                               XAU_SafeTrend.mq5  |
//|  EA trend-following XAUUSD dengan pengaman risiko berlapis.       |
//|                                                                  |
//|  PRINSIP:                                                        |
//|   - Setiap order WAJIB punya Stop Loss & Take Profit di server.   |
//|   - Maksimal 1 posisi. TANPA martingale, TANPA grid, TANPA         |
//|     averaging.                                                   |
//|   - Lot dihitung dari % risiko modal. Jika lot minimum pun sudah  |
//|     melebihi batas risiko, trade DILEWATI (tidak dipaksa).         |
//|   - Batas rugi harian, mingguan, dan drawdown total (kill switch).|
//|   - Filter spread, jam trading, berita USD high-impact, dan        |
//|     penutupan posisi sebelum akhir pekan.                         |
//|                                                                  |
//|  Tidak ada jaminan profit. Uji dulu di Strategy Tester & demo.    |
//+------------------------------------------------------------------+
#property copyright "XAU SafeTrend"
#property version   "1.00"
#property description "Trend-following XAUUSD (EMA + ATR) dengan manajemen risiko ketat."

#include <Trade\Trade.mqh>

//============================== INPUT ===============================
input group "=== Umum ==="
input long             InpMagic            = 20261104;   // Magic number
input ENUM_TIMEFRAMES  InpTF               = PERIOD_M15; // Timeframe sinyal
input string           InpComment          = "XAU_SafeTrend";

input group "=== Risiko ==="
input double InpRiskPercent      = 0.5;   // Risiko per trade (% balance)
input double InpMaxRiskPercent   = 1.0;   // Batas keras risiko per trade (%), jika lot minimum melebihi ini -> skip
input double InpDailyLossPct     = 1.0;   // Batas rugi harian (%) -> berhenti s/d besok
input double InpWeeklyLossPct    = 3.0;   // Batas rugi mingguan (%) -> berhenti s/d Senin
input double InpMaxDrawdownPct   = 8.0;   // Drawdown dari puncak equity (%) -> EA berhenti total
input int    InpMaxTradesPerDay  = 2;     // Maksimal entry per hari
input bool   InpResetHalt        = false; // true = reset status "berhenti total" (lalu set false lagi)

input group "=== Strategi (EMA + ATR) ==="
input int    InpFastEMA          = 50;    // EMA cepat
input int    InpSlowEMA          = 200;   // EMA lambat (filter tren)
input int    InpATRPeriod        = 14;    // Periode ATR
input double InpSL_ATR           = 1.5;   // Stop Loss = ATR x nilai ini
input double InpRR               = 2.0;   // Take Profit = SL x nilai ini (reward:risk)
input double InpPullbackATR      = 0.3;   // Toleransi pullback ke EMA cepat (x ATR)
input double InpMinSL_USD        = 3.0;   // Jarak SL minimum (USD harga emas)
input double InpMaxSL_USD        = 20.0;  // Jarak SL maksimum (USD), lebih lebar -> skip
input double InpBreakevenR       = 1.0;   // Geser SL ke harga entry saat profit >= R x ini (0 = mati)

input group "=== Filter ==="
input double InpMaxSpreadUSD     = 0.50;  // Spread maksimum (USD). Lebih lebar -> tidak entry
input double InpMaxSlippageUSD   = 0.30;  // Slippage maksimum saat eksekusi (USD)
input int    InpStartHour        = 7;     // Jam mulai entry (jam SERVER broker)
input int    InpEndHour          = 20;    // Jam akhir entry (jam SERVER broker)
input int    InpFridayStopHour   = 17;    // Jumat: tidak entry baru setelah jam ini
input int    InpFridayCloseHour  = 20;    // Jumat: tutup semua posisi pada jam ini
input bool   InpUseNewsFilter    = true;  // Filter berita USD high-impact (kalender MT5)
input int    InpNewsBeforeMin    = 60;    // Tidak entry X menit sebelum berita
input int    InpNewsAfterMin     = 30;    // Tidak entry X menit sesudah berita
input bool   InpCloseBeforeNews  = true;  // Tutup posisi terbuka menjelang berita high-impact

//============================== GLOBAL ==============================
CTrade   trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hATR = INVALID_HANDLE;
datetime gLastBar = 0;
string   gPrefix;
string   gStatus = "";

datetime gNewsTimes[];
datetime gNewsLastRefresh = 0;
bool     gNewsWarned = false;

//============================== UTIL ================================
string GV(const string key) { return gPrefix + key; }

double GVGet(const string key, const double def)
{
   if(GlobalVariableCheck(GV(key))) return GlobalVariableGet(GV(key));
   return def;
}

void GVSet(const string key, const double val) { GlobalVariableSet(GV(key), val); }

datetime DayStart(const datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

datetime WeekStart(const datetime t)
{
   MqlDateTime dt; TimeToStruct(t, dt);
   int back = (dt.day_of_week == 0) ? 6 : dt.day_of_week - 1; // Senin = awal minggu
   return DayStart(t) - back * 86400;
}

bool IsTester() { return (bool)MQLInfoInteger(MQL_TESTER); }

//====================== POSISI MILIK EA INI =========================
int CountMyPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic) n++;
   }
   return n;
}

void CloseMyPositions(const string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(trade.PositionClose(tk))
         PrintFormat("Posisi #%I64u ditutup: %s", tk, reason);
      else
         PrintFormat("GAGAL menutup posisi #%I64u (%s): %d %s", tk, reason,
                     trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

int TradesOpenedToday()
{
   datetime from = DayStart(TimeCurrent());
   if(!HistorySelect(from, TimeCurrent() + 60)) return 0;
   int n = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN) n++;
   }
   return n;
}

//====================== STATUS RISIKO AKUN ==========================
// return true jika boleh membuka trade baru
bool UpdateRiskState()
{
   datetime now     = TimeCurrent();
   double   balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double   equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   // --- pergantian hari / minggu: simpan balance awal periode
   datetime ds = DayStart(now), ws = WeekStart(now);
   if((datetime)GVGet("DayStart", 0) != ds)  { GVSet("DayStart", (double)ds);  GVSet("DayBal", balance); }
   if((datetime)GVGet("WeekStart", 0) != ws) { GVSet("WeekStart", (double)ws); GVSet("WeekBal", balance); }

   double dayBal  = GVGet("DayBal", balance);
   double weekBal = GVGet("WeekBal", balance);

   // --- puncak equity untuk drawdown total
   double peak = GVGet("Peak", equity);
   if(equity > peak) { peak = equity; }
   GVSet("Peak", peak);

   // --- kill switch drawdown total
   if(GVGet("Halt", 0) > 0.5)
   {
      gStatus = "BERHENTI TOTAL (drawdown maks tercapai). Cek manual, lalu set InpResetHalt=true.";
      if(CountMyPositions() > 0) CloseMyPositions("halt");
      return false;
   }
   if(peak > 0 && equity <= peak * (1.0 - InpMaxDrawdownPct / 100.0))
   {
      GVSet("Halt", 1);
      CloseMyPositions("drawdown maksimum");
      string msg = StringFormat("XAU_SafeTrend BERHENTI: drawdown %.2f%% dari puncak %.2f",
                                (peak - equity) / peak * 100.0, peak);
      Print(msg);
      if(!IsTester()) Alert(msg);
      gStatus = msg;
      return false;
   }

   // --- batas rugi harian (termasuk floating)
   if(dayBal > 0 && (equity - dayBal) / dayBal * 100.0 <= -InpDailyLossPct)
   {
      if(CountMyPositions() > 0) CloseMyPositions("batas rugi harian");
      gStatus = "Batas rugi HARIAN tercapai, lanjut besok.";
      return false;
   }

   // --- batas rugi mingguan
   if(weekBal > 0 && (equity - weekBal) / weekBal * 100.0 <= -InpWeeklyLossPct)
   {
      if(CountMyPositions() > 0) CloseMyPositions("batas rugi mingguan");
      gStatus = "Batas rugi MINGGUAN tercapai, lanjut Senin.";
      return false;
   }

   return true;
}

//============================ BERITA ================================
void RefreshNews()
{
   datetime now = TimeCurrent();
   if(now - gNewsLastRefresh < 3600 && gNewsLastRefresh != 0) return;
   gNewsLastRefresh = now;
   ArrayResize(gNewsTimes, 0);

   MqlCalendarValue vals[];
   int n = CalendarValueHistory(vals, now - 86400, now + 2 * 86400, NULL, "USD");
   if(n <= 0)
   {
      if(!gNewsWarned)
      {
         Print("Peringatan: kalender ekonomi tidak tersedia (normal di Strategy Tester). Filter berita tidak aktif.");
         gNewsWarned = true;
      }
      return;
   }
   for(int i = 0; i < n; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(vals[i].event_id, ev)) continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;
      int k = ArraySize(gNewsTimes);
      ArrayResize(gNewsTimes, k + 1);
      gNewsTimes[k] = vals[i].time;   // waktu server broker
   }
}

// mode 0 = jendela entry (sebelum+sesudah), mode 1 = hanya sebelum berita (untuk tutup posisi)
bool InNewsWindow(const int mode)
{
   if(!InpUseNewsFilter) return false;
   RefreshNews();
   datetime now = TimeCurrent();
   for(int i = 0; i < ArraySize(gNewsTimes); i++)
   {
      datetime t = gNewsTimes[i];
      if(mode == 0 && now >= t - InpNewsBeforeMin * 60 && now <= t + InpNewsAfterMin * 60) return true;
      if(mode == 1 && now >= t - 15 * 60 && now < t) return true;   // 15 menit sebelum rilis
   }
   return false;
}

//========================= FILTER WAKTU =============================
bool EntryTimeAllowed()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   if(dt.day_of_week == 5 && dt.hour >= InpFridayStopHour) return false;
   if(dt.day_of_week == 1 && dt.hour < InpStartHour + 1) return false; // hindari gap pembukaan Senin
   return (dt.hour >= InpStartHour && dt.hour < InpEndHour);
}

bool FridayCloseTime()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return (dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour);
}

//========================= PERHITUNGAN LOT ==========================
double LotStepDigits(const double step)
{
   int d = 0; double s = step;
   while(s < 1.0 && d < 8) { s *= 10.0; d++; }
   return d;
}

// return 0 jika trade harus dilewati
double CalcLots(const ENUM_ORDER_TYPE type, const double price, const double slPrice)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double pl = 0.0;
   if(!OrderCalcProfit(type, _Symbol, 1.0, price, slPrice, pl) || pl >= 0)
   {
      Print("OrderCalcProfit gagal, trade dilewati.");
      return 0;
   }
   double lossPerLot = -pl;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = minLot;

   double riskMoney = balance * InpRiskPercent / 100.0;
   double capMoney  = balance * InpMaxRiskPercent / 100.0;

   double lots = MathFloor((riskMoney / lossPerLot) / step) * step;
   if(lots < minLot)
   {
      double minRisk = lossPerLot * minLot;
      if(minRisk <= capMoney)
         lots = minLot;
      else
      {
         PrintFormat("Trade DILEWATI: lot minimum %.2f berisiko %.2f %s (%.2f%%) > batas %.2f%%.",
                     minLot, minRisk, AccountInfoString(ACCOUNT_CURRENCY),
                     minRisk / balance * 100.0, InpMaxRiskPercent);
         return 0;
      }
   }
   lots = MathMin(lots, maxLot);
   lots = NormalizeDouble(lots, (int)LotStepDigits(step));

   // cek margin: sisakan ruang yang lega
   double margin = 0.0;
   if(OrderCalcMargin(type, _Symbol, lots, price, margin))
   {
      if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.5)
      {
         Print("Trade DILEWATI: margin terlalu besar dibanding free margin.");
         return 0;
      }
   }
   return lots;
}

//=========================== MANAJEMEN ==============================
void ManageBreakeven()
{
   if(InpBreakevenR <= 0) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double stopsLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double buffer = MathMax(ask - bid, _Point * 10);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      if(tp <= 0 || InpRR <= 0) continue;
      double riskDist = MathAbs(tp - open) / InpRR;   // jarak SL awal
      long   ptype    = PositionGetInteger(POSITION_TYPE);

      if(ptype == POSITION_TYPE_BUY)
      {
         double newSL = NormalizeDouble(open + buffer, _Digits);
         if(bid - open >= riskDist * InpBreakevenR && (sl < newSL) && (bid - newSL > stopsLvl))
            trade.PositionModify(tk, newSL, tp);
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         double newSL = NormalizeDouble(open - buffer, _Digits);
         if(open - ask >= riskDist * InpBreakevenR && (sl == 0 || sl > newSL) && (newSL - ask > stopsLvl))
            trade.PositionModify(tk, newSL, tp);
      }
   }
}

//============================ SINYAL ================================
// return +1 buy, -1 sell, 0 tidak ada
int GetSignal(double &atrOut)
{
   double f[], s[], a[];
   ArraySetAsSeries(f, true); ArraySetAsSeries(s, true); ArraySetAsSeries(a, true);
   if(CopyBuffer(hFast, 0, 0, 5, f) < 5) return 0;
   if(CopyBuffer(hSlow, 0, 0, 5, s) < 5) return 0;
   if(CopyBuffer(hATR,  0, 0, 5, a) < 5) return 0;

   double o1 = iOpen(_Symbol, InpTF, 1);
   double h1 = iHigh(_Symbol, InpTF, 1);
   double l1 = iLow(_Symbol, InpTF, 1);
   double c1 = iClose(_Symbol, InpTF, 1);
   double atr = a[1];
   atrOut = atr;
   if(atr <= 0 || c1 <= 0) return 0;

   bool upTrend   = f[1] > s[1] && f[1] > f[4] && s[1] >= s[4];
   bool downTrend = f[1] < s[1] && f[1] < f[4] && s[1] <= s[4];

   // BUY: tren naik, candle terakhir menyentuh area EMA cepat lalu ditutup bullish di atasnya
   if(upTrend && l1 <= f[1] + InpPullbackATR * atr && c1 > f[1] && c1 > o1 && c1 > s[1])
      return 1;

   // SELL: tren turun, candle terakhir menyentuh area EMA cepat lalu ditutup bearish di bawahnya
   if(downTrend && h1 >= f[1] - InpPullbackATR * atr && c1 < f[1] && c1 < o1 && c1 < s[1])
      return -1;

   return 0;
}

void TryEntry()
{
   if(CountMyPositions() > 0)                     { gStatus = "Ada posisi terbuka."; return; }
   if(!EntryTimeAllowed())                        { gStatus = "Di luar jam trading."; return; }
   if(TradesOpenedToday() >= InpMaxTradesPerDay)  { gStatus = "Kuota trade hari ini habis."; return; }
   if(InNewsWindow(0))                            { gStatus = "Jendela berita high-impact, tidak entry."; return; }

   if(!IsTester())
   {
      if(!TerminalInfoInteger(TERMINAL_CONNECTED))     { gStatus = "Terminal tidak terkoneksi."; return; }
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { gStatus = "Tombol Algo Trading mati."; return; }
      if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           { gStatus = "EA tidak diizinkan trading."; return; }
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask - bid > InpMaxSpreadUSD) { gStatus = StringFormat("Spread lebar (%.2f), tidak entry.", ask - bid); return; }

   double atr = 0;
   int sig = GetSignal(atr);
   if(sig == 0) { gStatus = "Menunggu sinyal."; return; }

   double slDist = MathMax(InpSL_ATR * atr, InpMinSL_USD);
   double stopsLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   slDist = MathMax(slDist, stopsLvl + (ask - bid));
   if(slDist > InpMaxSL_USD)
   {
      PrintFormat("Sinyal dilewati: jarak SL %.2f > maksimum %.2f (pasar terlalu liar).", slDist, InpMaxSL_USD);
      gStatus = "Volatilitas terlalu tinggi, sinyal dilewati.";
      return;
   }
   double tpDist = slDist * InpRR;

   ENUM_ORDER_TYPE type = (sig > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = (sig > 0) ? ask : bid;
   double sl = NormalizeDouble((sig > 0) ? price - slDist : price + slDist, _Digits);
   double tp = NormalizeDouble((sig > 0) ? price + tpDist : price - tpDist, _Digits);

   double lots = CalcLots(type, price, sl);
   if(lots <= 0) { gStatus = "Lot minimum melebihi batas risiko, sinyal dilewati."; return; }

   bool ok = (sig > 0) ? trade.Buy(lots, _Symbol, price, sl, tp, InpComment)
                       : trade.Sell(lots, _Symbol, price, sl, tp, InpComment);
   if(ok && (trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_PLACED))
   {
      PrintFormat("%s %.2f lot @ %.2f | SL %.2f | TP %.2f | ATR %.2f",
                  (sig > 0 ? "BUY" : "SELL"), lots, price, sl, tp, atr);
      gStatus = "Posisi dibuka.";
   }
   else
   {
      PrintFormat("Order GAGAL: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      gStatus = "Order gagal, lihat tab Experts.";
   }
}

//============================ EVENT =================================
int OnInit()
{
   gPrefix = StringFormat("XSTF_%I64d_%s_", InpMagic, _Symbol);
   if(IsTester()) gPrefix = "T_" + gPrefix;

   if(StringFind(_Symbol, "XAU") < 0)
      PrintFormat("Peringatan: EA ini dirancang untuk XAUUSD, sekarang dipasang di %s.", _Symbol);

   if(InpRiskPercent <= 0 || InpRiskPercent > InpMaxRiskPercent || InpMaxRiskPercent > 2.0)
   {
      Print("Input risiko tidak valid: 0 < Risk <= MaxRisk <= 2%.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpFastEMA >= InpSlowEMA || InpSL_ATR <= 0 || InpRR <= 0)
   {
      Print("Input strategi tidak valid.");
      return INIT_PARAMETERS_INCORRECT;
   }

   hFast = iMA(_Symbol, InpTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, InpTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR  = iATR(_Symbol, InpTF, InpATRPeriod);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Print("Gagal membuat indikator.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints((ulong)MathMax(1, MathRound(InpMaxSlippageUSD / _Point)));

   if(InpResetHalt)
   {
      GlobalVariableDel(GV("Halt"));
      GVSet("Peak", AccountInfoDouble(ACCOUNT_EQUITY));
      Print("Status berhenti total di-reset. Kembalikan InpResetHalt ke false.");
   }

   PrintFormat("XAU_SafeTrend aktif di %s %s | risiko %.2f%% (maks %.2f%%) | digits %d",
               _Symbol, EnumToString(InpTF), InpRiskPercent, InpMaxRiskPercent, _Digits);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
   Comment("");
}

void OnTick()
{
   bool allowed = UpdateRiskState();

   // Penutupan wajib: akhir pekan & menjelang berita besar
   if(CountMyPositions() > 0)
   {
      if(FridayCloseTime()) CloseMyPositions("penutupan akhir pekan");
      else if(InpCloseBeforeNews && InNewsWindow(1)) CloseMyPositions("menjelang berita high-impact");
      else ManageBreakeven();
   }

   // Sinyal hanya dievaluasi sekali per candle baru
   datetime bar = iTime(_Symbol, InpTF, 0);
   if(bar != gLastBar)
   {
      gLastBar = bar;
      if(allowed) TryEntry();
   }

   if(!IsTester() || MQLInfoInteger(MQL_VISUAL_MODE))
   {
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      double dayBal = GVGet("DayBal", eq);
      Comment(StringFormat("XAU_SafeTrend\nStatus: %s\nEquity: %.2f | P/L hari ini: %.2f%%\nPuncak equity: %.2f\nTrade hari ini: %d / %d",
                           gStatus, eq, dayBal > 0 ? (eq - dayBal) / dayBal * 100.0 : 0.0,
                           GVGet("Peak", eq), TradesOpenedToday(), InpMaxTradesPerDay));
   }
}

// Kriteria optimasi custom: utamakan kurva stabil (profit / drawdown), tolak sampel kecil
double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   double dd     = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double profit = TesterStatistics(STAT_PROFIT);
   if(trades < 50 || dd <= 0) return 0;
   return profit / dd;
}
//+------------------------------------------------------------------+
