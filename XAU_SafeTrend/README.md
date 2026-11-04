# XAU_SafeTrend: EA MQL5 untuk XAUUSD (Exness, modal $1000)

EA *trend-following* dengan **manajemen risiko ketat**. Tujuannya menjaga kerugian
tetap kecil dan terkendali, bukan mengejar profit besar.

> ⚠️ **Tidak ada jaminan profit.** Wajib backtest dan forward test di akun
> **demo** minimal 1–3 bulan sebelum memakai uang sungguhan.

## Cara kerja

**Sinyal** (dicek sekali di setiap candle baru, default M15):

- **BUY**: EMA 50 di atas EMA 200 dan keduanya naik (tren naik). Candle terakhir
  turun menyentuh area EMA 50, lalu ditutup **bullish** di atasnya.
- **SELL**: kebalikannya.
- **Stop Loss** = 1,5 × ATR(14), minimal $3 dan maksimal $20. Kalau lebih lebar
  dari $20, sinyal dilewati karena pasar terlalu liar.
- **Take Profit** = 2 × jarak SL (reward:risk 1:2).
- **Breakeven**: saat profit sudah 1R, SL digeser ke harga entry.

**Pengaman** (semuanya bisa diatur di tab *Inputs*):

| Pengaman | Default |
|---|---|
| Risiko per trade | 0,5% balance |
| Batas keras per trade | 1%. Kalau lot minimum (0,01) pun melebihi ini, trade **dilewati** |
| Batas rugi harian | 1% (termasuk floating) → posisi ditutup, berhenti sampai besok |
| Batas rugi mingguan | 3% → berhenti sampai Senin |
| Drawdown dari puncak equity | 8% → **EA berhenti total**, wajib dicek manual |
| Posisi terbuka | Maksimal 1. Tanpa martingale, grid, atau averaging |
| Entry per hari | Maksimal 2 |
| Spread | Tidak entry kalau spread > $0,50 |
| Jam entry | 07:00–20:00 jam server (Exness = GMT+0 = 14:00–03:00 WIB) |
| Senin | Tidak entry di jam pertama (menghindari gap) |
| Jumat | Tidak ada entry baru setelah 17:00, semua posisi ditutup pukul 20:00 |
| Berita USD high-impact | Tidak entry 60 menit sebelum s/d 30 menit sesudah rilis. Posisi ditutup 15 menit sebelum rilis |
| SL/TP | Selalu dikirim bersama order, tersimpan di server broker |

## Catatan khusus modal $1000 di Exness

- Lot minimum XAUUSD adalah **0,01 lot = 1 oz**, jadi setiap gerak harga $1 ≈ **$1**.
- Risiko 0,5% dari $1000 = **$5**. Stop di XAUUSD biasanya $5–15, sehingga EA
  **sering memakai 0,01 lot** dengan risiko riil sekitar 0,5–1% per trade.
  Sinyal dengan stop > $10 (risiko > 1%) **otomatis dilewati**. Ini disengaja.
- Karena itu, dengan $1000 di akun Standard, EA akan cukup sering *skip* sinyal.
  Pilihannya:
  1. Biarkan saja: lebih sedikit trade, tapi risiko tetap terjaga.
  2. Pakai **akun Standard Cent** (kalau tersedia untuk MT5 di Personal Area
     Exness Anda). Di akun cent, lot bisa jauh lebih kecil sehingga risiko 0,5%
     selalu bisa dipenuhi. EA menghitung lot otomatis lewat `OrderCalcProfit`,
     jadi tetap bekerja di akun cent.
  3. **Jangan** menaikkan `InpMaxRiskPercent` di atas 1% hanya supaya lebih
     sering trading. EA menolak nilai di atas 2%.
- Nama simbol di Exness berbeda per tipe akun: **Standard = `XAUUSDm`**,
  Pro/Raw Spread/Zero = `XAUUSD`, Cent = `XAUUSDc`. Pasang EA di chart simbol
  yang sesuai.
- **Leverage tinggi tidak mengubah risiko EA ini** (risiko diatur dari jarak SL
  dan lot). Tetap saja, hindari leverage *unlimited*. 1:100–1:500 sudah cukup.

## Instalasi

1. Buka **MetaTrader 5** yang sudah login ke akun Exness (mulai dari **akun demo**).
2. Menu **File → Open Data Folder** → buka `MQL5\Experts\`.
3. Salin `XAU_SafeTrend.mq5` ke folder itu.
4. Buka **MetaEditor** (F4), buka file tersebut, lalu tekan **Compile** (F7).
   Pastikan hasilnya `0 errors`. Kalau ada error, kirimkan pesannya untuk diperbaiki.
5. Di MT5: buka chart **XAUUSDm** (atau sesuai akun), timeframe bebas (EA memakai `InpTF`).
6. Seret **XAU_SafeTrend** dari Navigator ke chart, centang *Allow Algo Trading*.
7. Aktifkan tombol **Algo Trading** di toolbar.
8. Untuk filter berita: **Tools → Options → Expert Advisors** tidak perlu diubah.
   Kalender ekonomi bawaan MT5 dipakai otomatis (pastikan tab *Calendar* di
   Toolbox terisi).

Agar berjalan 24 jam, pakai **VPS** (Exness menyediakan VPS gratis dengan syarat
saldo tertentu) atau PC yang selalu menyala.

## Backtest (wajib)

1. **View → Strategy Tester** (Ctrl+R).
2. Expert: `XAU_SafeTrend`, Symbol: `XAUUSDm`, Timeframe: M15.
3. Modelling: **Every tick based on real ticks**. Ini paling akurat untuk emas.
4. Periode: **minimal 3 tahun** (misalnya 2022 sampai sekarang), deposit 1000 USD.
5. Jalankan, lalu cek tab *Backtest*:
   - **Equity Drawdown Relative**: idealnya < 10%.
   - **Profit Factor**: > 1,3 sudah bagus, < 1,1 berarti tidak layak.
   - **Total Trades**: minimal 100 supaya hasilnya bisa dipercaya.
6. Catatan: **filter berita tidak aktif di Strategy Tester** (kalender ekonomi
   tidak tersedia di tester). Hasil live bisa sedikit berbeda.
7. Kalau mau optimasi, pilih *Custom max* sebagai kriteria. EA menilai
   profit ÷ drawdown dan mengabaikan hasil dengan < 50 trade. Jangan
   mengoptimasi terlalu banyak parameter sekaligus, karena hasilnya akan cocok
   ke masa lalu saja (*overfitting*).

## Tahapan aman

1. Backtest 3–5 tahun → 2. Demo 1–3 bulan → 3. Live dengan modal kecil →
4. Bandingkan hasil live dengan demo/backtest sebelum menambah modal.

## Hal yang perlu diingat

- Setelah **withdraw** dari akun, equity turun dan bisa dianggap drawdown.
  Set `InpResetHalt = true` sekali, lalu kembalikan ke `false`.
- Kalau EA "berhenti total" (drawdown 8%), jangan langsung reset. Evaluasi dulu
  apakah kondisi pasar atau strateginya yang bermasalah.
- Jangan menjalankan EA lain atau trading manual di akun yang sama tanpa
  memahami efeknya ke batas rugi harian (batas dihitung dari equity akun).
- Profit realistis untuk sistem seperti ini, kalau memang punya *edge*, sekitar
  **1–3% per bulan**, dengan bulan-bulan rugi di antaranya.
