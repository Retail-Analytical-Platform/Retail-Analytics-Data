# Insight Bisnis untuk Stakeholder — Retail Sales

Dokumen ini berisi kumpulan **query siap pakai untuk laporan/presentasi ke stakeholder**
(bukan tim teknis) — fokusnya bukan validasi data, tapi jawaban atas pertanyaan bisnis:
seberapa besar bisnis ini, ke mana arah tren-nya, siapa/apa yang paling berkontribusi, dan
di mana peluang/risikonya. Setiap bagian berisi: **insight untuk siapa & kenapa penting**,
**sql syntax**-nya, lalu **hasil ringkas & rekomendasi aksi**.

Basis data: `fact_sales` (60.000 transaksi) + 4 tabel dimensi (`dim_customer`, `dim_date`,
`dim_product`, `dim_store`). Lihat `readmechat.md` untuk detail teknis skema & kualitas
data.

---

## 1. Ringkasan Eksekutif (KPI Utama)

**Untuk siapa:** manajemen/eksekutif yang butuh gambaran bisnis dalam satu layar.
**Kenapa penting:** ini angka pembuka standar di setiap laporan bisnis — total transaksi,
jumlah pelanggan aktif, total pendapatan, dan nilai rata-rata per transaksi.

```sql
SELECT
    COUNT(DISTINCT sale_id)     AS total_transaksi,
    COUNT(DISTINCT customer_key) AS total_pelanggan,
    ROUND(SUM(revenue), 2)      AS total_revenue,
    ROUND(AVG(revenue), 2)      AS rata_rata_nilai_transaksi
FROM fact_sales;
```
- `COUNT(DISTINCT ...)` menghitung jumlah unik (transaksi & pelanggan), bukan sekadar
  jumlah baris.
- `SUM(revenue)` menjumlahkan seluruh pendapatan; `AVG(revenue)` = nilai rata-rata per
  transaksi (mirip konsep *Average Order Value*).

**Hasil:**

| total_transaksi | total_pelanggan | total_revenue | rata_rata_nilai_transaksi |
|---|---|---|---|
| 60.000 | 2.000 | **Rp/​$ 3.450.000** | $ 57,50 |

**Insight:** rata-rata satu pelanggan bertransaksi ±30 kali, dengan nilai rata-rata per
transaksi $57,50.

---

## 2. Tren Revenue Bulanan & Pertumbuhan (Month-over-Month)

**Untuk siapa:** tim manajemen/finance yang memantau momentum bisnis.
**Kenapa penting:** total revenue saja tidak cukup — stakeholder butuh tahu **arah
tren**: naik, turun, atau musiman. Kolom pertumbuhan (%) langsung menjawab "bulan ini
lebih baik dari bulan lalu atau tidak?".

```sql
WITH monthly AS (
    SELECT DATE_TRUNC('month', d.full_date) AS bulan,
           SUM(f.revenue) AS total_revenue
    FROM fact_sales f
    JOIN dim_date d ON f.date_key = d.date_key
    GROUP BY DATE_TRUNC('month', d.full_date)
)
SELECT
    TO_CHAR(bulan, 'YYYY-MM') AS bulan,
    total_revenue,
    ROUND(
        100.0 * (total_revenue - LAG(total_revenue) OVER (ORDER BY bulan))
        / NULLIF(LAG(total_revenue) OVER (ORDER BY bulan), 0)
    , 2) AS growth_pct
FROM monthly
ORDER BY bulan;
```
- `DATE_TRUNC('month', full_date)` membulatkan tanggal ke awal bulan — dipakai sebagai
  sumber waktu yang andal (bukan `month_name`/`quarter` mentah dari `dim_date`, yang
  menurut audit teknis punya inkonsistensi — lihat `readmechat.md`).
- `LAG(total_revenue) OVER (ORDER BY bulan)` mengambil nilai revenue **bulan sebelumnya**
  untuk baris yang sedang diproses — inilah kunci menghitung pertumbuhan MoM.
- `NULLIF(..., 0)` mencegah error pembagian dengan nol.

**Hasil (24 bulan, Jan 2024 – Des 2025), cuplikan:**

| bulan | total_revenue | growth_pct |
|---|---|---|
| 2024-03 | 209.782,56 | **+57,19%** |
| 2024-04 | 116.971,26 | -44,24% |
| 2025-10 | 169.054,39 | **+55,23%** |
| 2025-11 | 117.660,79 | -30,40% |

**Insight:** revenue berfluktuasi tajam bulan-ke-bulan (naik-turun >40–55% berulang kali)
tanpa pola musiman yang jelas (bandingkan Maret naik tajam di 2024 tapi tidak konsisten
di bulan yang sama tahun berikutnya). Ini pola yang **tidak lazim** untuk data ritel nyata
(biasanya ada musiman seperti liburan/akhir tahun) — kemungkinan besar karena dataset ini
sintetis/acak. **Rekomendasi:** jangan pakai tren bulanan di dataset ini untuk keputusan
perencanaan stok/kampanye musiman sampai divalidasi dengan data produksi asli.

---

## 3. Kontribusi Revenue per Kategori Produk

**Untuk siapa:** tim merchandising/product & marketing.
**Kenapa penting:** menunjukkan kategori mana yang jadi "mesin utama" pendapatan, dasar
untuk alokasi anggaran promosi dan keputusan stok.

```sql
SELECT
    category,
    SUM(revenue) AS total_revenue,
    ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 2) AS pct_of_total
FROM fact_sales_clean
GROUP BY category
ORDER BY total_revenue DESC;
```
- Memakai `fact_sales_clean` (view yang kategorinya sudah bersih, sinkron dengan
  `dim_product`) — bukan `fact_sales.category` mentah, yang menurut audit teknis 72,5%
  datanya tidak sinkron.
- `SUM(SUM(revenue)) OVER ()` adalah **window function di atas hasil GROUP BY** — trik
  untuk menjumlahkan total keseluruhan tanpa query terpisah, dipakai sebagai pembagi
  supaya dapat persentase kontribusi.

**Hasil:**

| category | total_revenue | pct_of_total |
|---|---|---|
| Electronics | 1.252.525,97 | **36,31%** |
| Home | 947.668,83 | 27,47% |
| Grocery | 858.074,81 | 24,87% |
| Apparel | 391.730,39 | 11,35% |

**Insight:** Electronics adalah kategori terbesar (>1/3 revenue), Apparel paling kecil.
**Rekomendasi:** prioritaskan ketersediaan stok & anggaran iklan ke Electronics, sekaligus
evaluasi apakah Apparel perlu strategi bundling/diskon untuk mendongkrak kontribusinya.

---

## 4. Performa Regional

**Untuk siapa:** tim regional sales/operasional.
**Kenapa penting:** menunjukkan wilayah mana yang menyumbang pendapatan terbesar — dasar
untuk keputusan ekspansi, penempatan tim sales, atau investigasi wilayah yang lemah.

```sql
SELECT
    s.region,
    COUNT(*)               AS jumlah_transaksi,
    SUM(f.revenue)          AS total_revenue,
    ROUND(AVG(f.revenue),2) AS rata_rata_transaksi
FROM fact_sales f
JOIN dim_store s ON f.store_key = s.store_key
GROUP BY s.region
ORDER BY total_revenue DESC;
```
- `JOIN` dengan `dim_store` untuk mengetahui `region` setiap transaksi (info ini tidak
  ada langsung di `fact_sales`).
- `GROUP BY s.region` meringkas 60.000 transaksi menjadi 4 baris (satu per wilayah).

**Hasil:**

| region | jumlah_transaksi | total_revenue | rata_rata_transaksi |
|---|---|---|---|
| East | 25.390 | **1.457.512,42** | 57,40 |
| West | 14.852 | 852.170,33 | 57,38 |
| South | 10.610 | 613.301,16 | 57,80 |
| North | 9.148 | 527.016,09 | 57,61 |

**Insight:** East mendominasi (42% dari total transaksi), tapi rata-rata nilai transaksi
antar wilayah **nyaris sama** (~$57,4–57,8) — artinya East unggul karena **volume**
transaksi, bukan karena pelanggan di sana belanja lebih besar per transaksi.
**Rekomendasi:** North & South adalah kandidat untuk program akuisisi pelanggan/ekspansi
toko baru karena volumenya jauh lebih kecil meski nilai transaksinya setara.

---

## 5. Toko dengan Kinerja Tertinggi & Terendah

**Untuk siapa:** manajer operasional toko/retail ops.
**Kenapa penting:** mengidentifikasi toko yang berprestasi (untuk dipelajari & direplikasi
praktiknya) dan toko yang tertinggal (untuk diaudit/dibenahi).

```sql
WITH store_rev AS (
    SELECT s.store_key, s.store_name, s.region, s.store_type,
           SUM(f.revenue) AS total_revenue
    FROM fact_sales f
    JOIN dim_store s ON f.store_key = s.store_key
    GROUP BY s.store_key, s.store_name, s.region, s.store_type
)
(SELECT * FROM store_rev ORDER BY total_revenue DESC LIMIT 5)
UNION ALL
(SELECT * FROM store_rev ORDER BY total_revenue ASC LIMIT 5);
```
- `WITH store_rev AS (...)` adalah **CTE** (Common Table Expression) — menghitung total
  revenue per toko sekali saja, lalu dipakai dua kali (untuk ambil 5 teratas dan 5
  terbawah) tanpa menulis ulang logika `JOIN`/`GROUP BY`.
- `UNION ALL` menggabungkan dua hasil (top 5 dan bottom 5) jadi satu tabel untuk
  perbandingan langsung.

**Hasil (cuplikan):**

| Peringkat | store_name | region | total_revenue |
|---|---|---|---|
| #1 tertinggi | Silver Cloud Inc | North | 91.347,49 |
| #2 tertinggi | Summit Works Collective | South | 90.342,51 |
| ... | ... | ... | ... |
| #5 terendah | Ever Systems Solutions | South | 80.662,18 |

**Insight:** kesenjangan antara toko terbaik dan terlemah relatif kecil (±12%), tidak ada
toko yang sangat tertinggal — performa toko relatif merata secara nasional.
**Rekomendasi:** karena gap kecil, fokuskan evaluasi pada *store_type* (Flagship/Standard/
Outlet) dan region, bukan mengejar satu toko spesifik yang bermasalah.

---

## 6. Top 10 Pelanggan Bernilai Tinggi (Kandidat VIP/Loyalty)

**Untuk siapa:** tim CRM/customer success & marketing loyalitas.
**Kenapa penting:** pelanggan bernilai tinggi adalah aset yang paling penting untuk
dipertahankan — daftar ini jadi dasar program VIP, retensi, atau personal outreach.

```sql
SELECT c.customer_key, c.customer_name, c.segment, c.country,
       COUNT(*) AS jumlah_order,
       ROUND(SUM(f.revenue), 2) AS total_revenue
FROM fact_sales f
JOIN dim_customer c ON f.customer_key = c.customer_key
GROUP BY c.customer_key, c.customer_name, c.segment, c.country
ORDER BY total_revenue DESC
LIMIT 10;
```
- `JOIN` ke `dim_customer` untuk mendapat nama/segmen/negara pelanggan (identitas bisnis,
  bukan cuma ID angka).
- `ORDER BY total_revenue DESC LIMIT 10` — pola standar untuk "top-N" di SQL.

**Hasil (3 teratas):**

| customer_name | segment | country | jumlah_order | total_revenue |
|---|---|---|---|---|
| Andreas Meyer | Corporate | BR | 46 | 3.481,83 |
| Ming Luo | Consumer | US | 40 | 3.196,01 |
| Sandra Lewis | Home Office | BR | 46 | 2.999,56 |

**Insight:** pelanggan top berasal dari segmen berbeda-beda (Corporate, Consumer, Home
Office) dan negara berbeda — tidak terkonsentrasi di satu tipe pelanggan tertentu.
**Rekomendasi:** gunakan daftar ini sebagai starting point program loyalitas/diskon
eksklusif, tapi personalisasi per segmen karena profil mereka beragam.

---

## 7. Konsentrasi Revenue Pelanggan (Analisis Risiko "Telur dalam Satu Keranjang")

**Untuk siapa:** manajemen senior/finance untuk menilai risiko ketergantungan pendapatan.
**Kenapa penting:** kalau mayoritas revenue berasal dari segelintir pelanggan, bisnis
berisiko besar jika mereka pergi (biasa disebut pola 80/20 atau *revenue concentration
risk*). Ini mengelompokkan pelanggan menjadi 10 kelompok (desil) berdasar kontribusi
revenue.

```sql
WITH cust AS (
    SELECT customer_key, SUM(revenue) AS rev
    FROM fact_sales
    GROUP BY customer_key
),
ranked AS (
    SELECT customer_key, rev,
           NTILE(10) OVER (ORDER BY rev DESC) AS decile
    FROM cust
)
SELECT decile,
       COUNT(*) AS jumlah_pelanggan,
       ROUND(SUM(rev), 2) AS total_revenue,
       ROUND(100.0 * SUM(rev) / SUM(SUM(rev)) OVER (), 2) AS pct_revenue
FROM ranked
GROUP BY decile
ORDER BY decile;
```
- `NTILE(10) OVER (ORDER BY rev DESC)` membagi seluruh pelanggan (yang sudah diurutkan
  dari revenue tertinggi) menjadi **10 kelompok berukuran sama** (masing-masing 200
  pelanggan) — desil 1 = 10% pelanggan ber-revenue tertinggi.
- Query luar meringkas tiap desil menjadi total & persentase kontribusinya.

**Hasil:**

| decile (10% teratas → terbawah) | jumlah_pelanggan | pct_revenue |
|---|---|---|
| 1 (tertinggi) | 200 | 14,23% |
| 2 | 200 | 12,36% |
| 5 (tengah) | 200 | 10,22% |
| 9 | 200 | 7,63% |
| 10 (terendah) | 200 | 6,23% |

**Insight:** 10% pelanggan teratas hanya menyumbang **14,23%** dari total revenue (bukan
~50-80% seperti pola Pareto klasik di ritel nyata) — distribusi revenue antar pelanggan
**relatif merata**, sehingga risiko kehilangan satu/beberapa pelanggan besar terhadap
total bisnis **rendah**. **Rekomendasi:** strategi retensi bisa difokuskan secara merata
ke seluruh basis pelanggan, bukan hanya segelintir "whale customer".

---

## 8. Perilaku Belanja per Segmen Pelanggan

**Untuk siapa:** tim marketing segmentasi.
**Kenapa penting:** menjawab "segmen pelanggan mana (Consumer/Corporate/Home Office) yang
paling menguntungkan per kepala?" — dasar prioritas kampanye per segmen.

```sql
SELECT c.segment,
       COUNT(DISTINCT c.customer_key) AS jumlah_pelanggan,
       COUNT(*)                       AS jumlah_order,
       ROUND(AVG(f.revenue), 2)       AS rata_rata_nilai_order,
       ROUND(SUM(f.revenue) / COUNT(DISTINCT c.customer_key), 2) AS revenue_per_pelanggan
FROM fact_sales f
JOIN dim_customer c ON f.customer_key = c.customer_key
GROUP BY c.segment
ORDER BY revenue_per_pelanggan DESC;
```
- `COUNT(DISTINCT c.customer_key)` vs `COUNT(*)` — yang pertama menghitung **jumlah
  pelanggan unik**, yang kedua menghitung **jumlah order** (satu pelanggan bisa order
  berkali-kali), keduanya perlu dibedakan supaya metrik "per pelanggan" akurat.

**Hasil:**

| segment | jumlah_pelanggan | rata_rata_nilai_order | revenue_per_pelanggan |
|---|---|---|---|
| Home Office | 336 | 57,33 | **1.733,46** |
| Consumer | 1.065 | 57,48 | 1.730,54 |
| Corporate | 599 | 57,63 | 1.710,40 |

**Insight:** ketiga segmen nyaris identik nilainya (selisih <1,5%) — tidak ada segmen yang
jauh lebih menguntungkan per pelanggan. **Rekomendasi:** karena tidak ada perbedaan
signifikan, keputusan alokasi anggaran marketing sebaiknya didasarkan pada **ukuran
segmen** (Consumer paling besar, 1.065 pelanggan) untuk jangkauan maksimal, bukan pada
asumsi satu segmen "lebih premium".

---

## 9. Pola Weekday vs Weekend

**Untuk siapa:** tim operasional (jadwal staf) & marketing (waktu promo).
**Kenapa penting:** menentukan kapan sebaiknya menambah tenaga kerja toko atau menjadwalkan
kampanye promosi.

```sql
SELECT d.is_weekend,
       COUNT(*)                AS jumlah_transaksi,
       SUM(f.revenue)           AS total_revenue,
       ROUND(AVG(f.revenue), 2) AS rata_rata_transaksi
FROM fact_sales f
JOIN dim_date d ON f.date_key = d.date_key
GROUP BY d.is_weekend;
```

**Hasil:**

| is_weekend | jumlah_transaksi | total_revenue | rata_rata_transaksi |
|---|---|---|---|
| False (weekday) | 39.974 | 2.299.238,37 | 57,52 |
| True (weekend) | 20.026 | 1.150.761,63 | 57,46 |

**Insight:** volume transaksi weekday ±2x lipat weekend (konsisten dengan 5 hari kerja vs
2 hari akhir pekan), tapi nilai rata-rata per transaksi sama saja. **Rekomendasi:** tidak
perlu strategi harga khusus akhir pekan; fokus operasional (staf/stok) tetap proporsional
5:2 sesuai jumlah hari.

---

## 10. Produk Terlaris (Top 20 berdasarkan Revenue)

**Untuk siapa:** tim merchandising & manajemen stok/inventory.
**Kenapa penting:** mengetahui produk mana yang paling menyumbang pendapatan penting untuk
memastikan ketersediaan stok dan menentukan produk unggulan di materi promosi.

```sql
SELECT p.product_name, p.category,
       SUM(f.quantity)        AS unit_terjual,
       ROUND(SUM(f.revenue),2) AS total_revenue
FROM fact_sales f
JOIN dim_product p ON f.product_key = p.product_key
GROUP BY p.product_name, p.category
ORDER BY total_revenue DESC
LIMIT 20;
```
> **Catatan:** sengaja **tidak** menyertakan kolom margin (`list_price - unit_cost`) di
> sini seperti versi teknis di `readmechat.md` — audit data menemukan banyak produk top
> justru bermargin negatif, indikasi `dim_product.unit_cost`/`list_price` bermasalah.
> Jangan sampaikan angka margin ke stakeholder sebelum tim data memverifikasi sumbernya.

**Insight:** kategori Electronics & Home mendominasi daftar 20 produk terlaris (selaras
dengan temuan §3). **Rekomendasi:** jadikan daftar ini acuan utama untuk perencanaan stok
musim depan dan materi katalog/promosi.

---

## 11. Catatan Keterbatasan Data (Wajib Dibaca Sebelum Presentasi)

Beberapa metrik **tidak boleh** disampaikan ke stakeholder sebagai fakta bisnis karena
terbukti bermasalah secara data (detail lengkap ada di `readmechat.md`):

| Jangan gunakan | Alasan |
|---|---|
| `discount_pct` sebagai insight diskon | Nilainya konstan 35% di seluruh 60.000 baris — tidak ada variasi nyata. |
| Rumus manual `revenue = qty × harga × (1-diskon)` | 99,9% data tidak cocok dengan rumus ini — `revenue` adalah angka independen. |
| Margin produk (`list_price - unit_cost`) | Banyak produk top-seller punya margin negatif — indikasi data `dim_product` tidak realistis. |
| Nama pelanggan sebagai identitas unik | 15 email dipakai oleh lebih dari satu `customer_key` (kemungkinan duplikat pelanggan yang sama). |
| Tren bulanan (§2) sebagai pola musiman | Fluktuasi >40-55% MoM tanpa pola berulang antar tahun — kemungkinan data acak/sintetis. |

---

## 12. Kesimpulan untuk Stakeholder

1. **Skala bisnis:** 60.000 transaksi dari 2.000 pelanggan, total revenue $3.450.000,
   rata-rata $57,50/transaksi.
2. **Electronics adalah kategori andalan** (36% dari total revenue) — prioritas stok &
   promosi.
3. **East adalah wilayah dengan volume tertinggi**, tapi nilai transaksi rata-rata di
   semua wilayah setara — peluang pertumbuhan ada di **volume** North/South, bukan di
   menaikkan nilai transaksi.
4. **Risiko konsentrasi pelanggan rendah** — revenue tersebar cukup merata (10% pelanggan
   teratas hanya menyumbang 14% revenue), jadi bisnis tidak terlalu bergantung pada
   segelintir pelanggan besar.
5. **Tidak ada perbedaan berarti antar segmen pelanggan** (Consumer/Corporate/Home
   Office) maupun antar weekday/weekend dalam hal nilai transaksi — keputusan alokasi
   sumber daya sebaiknya berdasarkan **volume/ukuran kelompok**, bukan asumsi kelompok
   mana yang "lebih bernilai".
6. **Sebelum keputusan strategis (pricing, margin, target diskon)** diambil dari dataset
   ini, tim data perlu memvalidasi ulang kualitas kolom `discount_pct`, `revenue`, dan
   `unit_cost`/`list_price` — lihat §11.

**Rekomendasi aksi utama:** (a) perkuat stok & marketing Electronics, (b) jalankan program
akuisisi pelanggan di region North/South, (c) mulai program retensi merata ke seluruh
basis pelanggan (bukan hanya top spender), (d) tahan dulu keputusan berbasis
margin/diskon sampai data tersebut divalidasi ulang oleh tim data.
