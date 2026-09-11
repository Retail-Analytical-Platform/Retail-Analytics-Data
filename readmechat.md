# Penjelasan Analisis SQL — Retail Sales Star Schema

Dokumen ini menjelaskan **korelasi antar data** (bagaimana tabel-tabel saling terhubung)
dan **setiap sintaks SQL** yang dijalankan di `src/main.ipynb`, secara berurutan — setiap
query dijelaskan kaitannya dengan query sebelum dan sesudahnya, ditutup dengan kesimpulan.

> cell koneksi memakai password database dalam bentuk plaintext
> (`postgresql://postgres:@localhost:5432/postgres`) dan file ini sudah masuk
> git history. Sebaiknya password dipindah ke environment variable dan di-rotate.

---

## 1. Korelasi Data — Bagaimana Semua Tabel Saling Berhubungan

Dataset ini berbentuk **star schema**: satu tabel fakta (`fact_sales`, 60.000 baris) di
tengah, dikelilingi empat tabel dimensi yang masing-masing terhubung lewat *foreign key*
(surrogate key):

```
dim_customer(customer_key) ─┐
dim_date(date_key)         ─┼─< fact_sales >─── dim_product(product_key)
dim_store(store_key)       ─┘
```

| Tabel | Baris | Primary Key | Peran |
|---|---|---|---|
| `dim_customer` | 2.000 | `customer_key` | siapa yang membeli |
| `dim_date` | 730 | `date_key` | kapan transaksi terjadi |
| `dim_product` | ~400 | `product_key` | apa yang dibeli |
| `dim_store` | 40 | `store_key` | di toko/region mana |
| `fact_sales` | 60.000 | `sale_id` | transaksinya sendiri (qty, harga, diskon, revenue) |

Korelasi antar data di sini ada dua level:

1. **Korelasi struktural (relational)** — tiap baris `fact_sales` "berkorelasi" ke tepat
   satu baris di masing-masing dimensi lewat FK. Ini yang membuat *join* bisa dilakukan
   dan agregasi (total revenue per region, per kategori, per bulan, dsb.) jadi valid.
2. **Korelasi statistik (numerik)** — hubungan antar dua variabel numerik, misalnya
   apakah `unit_price` yang lebih tinggi cenderung dibeli dalam `quantity` yang lebih
   besar atau lebih kecil. Ini yang diukur lewat fungsi `CORR()` di bagian akhir notebook
   (lihat §2.24) — hasilnya mendekati nol, artinya **tidak ada hubungan** antara harga
   satuan dan jumlah unit yang dibeli.

Kedua jenis korelasi ini yang jadi dasar seluruh query di notebook: query awal memvalidasi
korelasi struktural (integritas FK), query tengah membersihkan data, query akhir
menganalisis korelasi statistik/bisnis (revenue per segmen, per waktu, per toko, dst.).

---

## 2. Alur Sintaks SQL — Berurutan

### 2.1 Koneksi
```sql
%load_ext sql
%sql postgresql://postgres:***@localhost:5432/postgres
```
Membuka koneksi ke database Postgres. Ini fondasi — semua query `%%sql` berikutnya jalan
lewat koneksi ini.

### 2.2 Melihat semua tabel yang ada
```sql
SELECT * FROM information_schema.tables WHERE table_schema = 'public';
```
Setelah konek (2.1), langkah pertama adalah **memastikan skema sudah ter-load** dengan
membaca katalog sistem `information_schema.tables`. Hasil: 5 tabel dasar + 1 view
(`fact_sales_clean`, dibuat nanti di 2.7) — artinya notebook ini sudah pernah dijalankan
sebelumnya karena view tersebut sudah ada.

### 2.3 Eksplorasi `dim_date`
```sql
SELECT * FROM dim_date;                                    -- 730 baris
SELECT DISTINCT(date_key) FROM dim_date ORDER BY date_key ASC;  -- 730 baris
```
Dua query ini **saling mengonfirmasi**: jumlah baris (730) sama dengan jumlah `date_key`
unik (730) → tidak ada duplikat primary key. `date_key` sendiri cuma angka acak (bukan
representasi tanggal asli), tanggal sesungguhnya ada di kolom `full_date`.

### 2.4 Cek integritas referensial (anti-join, 4 kali)
```sql
SELECT f.sale_id FROM fact_sales f
LEFT JOIN dim_customer c ON f.customer_key = c.customer_key
WHERE c.customer_key IS NULL;
-- pola yang sama diulang untuk dim_date, dim_product, dim_store
```
Ini melanjutkan langsung dari eksplorasi FK di 2.3: memakai `LEFT JOIN` + `WHERE ... IS
NULL` (pola *anti-join*) untuk mencari baris `fact_sales` yang FK-nya **tidak punya
pasangan** di tabel dimensi. Hasil: **0 baris di keempat cek** → korelasi struktural
antar tabel valid 100%, aman untuk semua `JOIN` di query-query berikutnya.

### 2.5 Membuat view gabungan
```sql
CREATE OR REPLACE VIEW fact_sales_clean AS
SELECT f.sale_id, ..., p.category, p.subcategory
FROM fact_sales f
JOIN dim_product p ON f.product_key = p.product_key;
```
Karena integritas FK sudah terbukti aman (2.4), sekarang aman untuk membuat *view* yang
menempelkan `category`/`subcategory` dari `dim_product` ke setiap baris fakta — supaya
query analisis berikutnya tidak perlu `JOIN` berulang-ulang.

### 2.6 Uji view baru
```sql
SELECT * FROM fact_sales_clean;   -- 60.000 baris
```
Baris yang dihasilkan (60.000) sama persis dengan jumlah baris `fact_sales` asli →
membuktikan relasi `fact_sales` ↔ `dim_product` bersifat *many-to-one* murni, tidak ada
duplikasi akibat join (fan-out).

### 2.7 Memperbaiki `category` di tabel fakta
```sql
UPDATE fact_sales f
SET category = p.category
FROM dim_product p
WHERE f.product_key = p.product_key
  AND f.category IS DISTINCT FROM p.category;
```
Kalau di view (2.5) kolom `category` diambil dari `dim_product`, di sini kolom `category`
milik `fact_sales` sendiri **ditulis ulang** supaya sama dengan `dim_product` — hanya pada
baris yang nilainya beda (`IS DISTINCT FROM` = versi `<>` yang aman terhadap `NULL`).

### 2.8 Memperbaiki `quarter`
```sql
UPDATE dim_date
SET quarter = 'Q' || CEIL(EXTRACT(MONTH FROM full_date) / 3.0)::INT
WHERE quarter <> 'Q' || CEIL(EXTRACT(MONTH FROM full_date) / 3.0)::INT;
```
Beralih ke tabel `dim_date` yang tadinya sudah dieksplorasi di 2.3. `EXTRACT(MONTH ...)`
mengambil angka bulan (1–12), dibagi 3 lalu dibulatkan ke atas (`CEIL`) untuk memetakan ke
kuartal (Jan–Mar→Q1, dst.), lalu hanya menimpa baris yang kuartalnya salah dibanding
`full_date`.

### 2.9 Memperbaiki `is_weekend`
```sql
UPDATE dim_date
SET is_weekend = (day_of_week IN ('Saturday', 'Sunday'))
WHERE is_weekend <> (day_of_week IN ('Saturday', 'Sunday'));
```
Pola identik dengan 2.8, tapi untuk kolom `is_weekend`, diturunkan dari `day_of_week`.
Kedua UPDATE ini (2.8–2.9) sama-sama membersihkan `dim_date` sebelum dipakai untuk agregasi
waktu di bagian akhir (2.21, 2.22).

### 2.10 Menguji rumus `revenue`
```sql
SELECT sale_id, quantity, unit_price, discount_pct, revenue,
       ROUND(quantity * unit_price * (1 - discount_pct), 2) AS expected_revenue,
       ROUND(revenue - quantity * unit_price * (1 - discount_pct), 2) AS diff
FROM fact_sales
WHERE ABS(revenue - quantity * unit_price * (1 - discount_pct)) > 0.05
ORDER BY ABS(...) DESC;
```
Ini menguji **korelasi matematis** antara `revenue` dan kombinasi `quantity × unit_price ×
(1 − discount_pct)`. Hasil: 59.947 dari 60.000 baris (99,9%) tidak cocok — artinya
`revenue` di dataset ini **tidak** dihitung dari rumus itu, jadi tidak boleh dipakai
sebagai validasi silang untuk `revenue`.

### 2.11 Cek variasi `discount_pct`
```sql
SELECT COUNT(DISTINCT discount_pct) AS distinct_discounts, MIN(discount_pct), MAX(discount_pct)
FROM fact_sales;
```
Menindaklanjuti kecurigaan dari 2.10: kalau rumus revenue tidak cocok, mungkin karena
diskon bervariasi tak terduga? Ternyata tidak — hasilnya `1 | 0.35 | 0.35`, artinya semua
60.000 baris punya diskon yang **sama persis** (35%), jadi kolom ini tidak punya nilai
analitis.

### 2.12 Mencari email duplikat
```sql
SELECT email, COUNT(*) AS n, STRING_AGG(customer_key::TEXT, ', ') AS customer_keys
FROM dim_customer
GROUP BY email
HAVING COUNT(*) > 1
ORDER BY n DESC;
```
Berpindah ke `dim_customer`. `GROUP BY email HAVING COUNT(*) > 1` menemukan email yang
dipakai oleh lebih dari satu `customer_key` — ditemukan 15 email terduplikasi (kemungkinan
pelanggan yang sama tercatat dua kali).

### 2.13 Standardisasi teks pelanggan
```sql
UPDATE dim_customer SET
    customer_name = TRIM(customer_name),
    email = LOWER(TRIM(email)),
    city = TRIM(city),
    country = UPPER(TRIM(country));
```
Setelah menemukan duplikat (2.12), dilakukan pembersihan format teks (hapus spasi,
seragamkan huruf besar/kecil) di seluruh 2.000 baris. **Catatan:** langkah ini merapikan
format tapi **belum menggabungkan** 15 pasangan duplikat yang ditemukan di 2.12.

### 2.14 Validasi rentang nilai `fact_sales`
```sql
SELECT * FROM fact_sales
WHERE quantity <= 0 OR unit_price <= 0 OR revenue <= 0 OR discount_pct NOT BETWEEN 0 AND 1;
```
Kembali ke `fact_sales` untuk cek terakhir sebelum masuk ke analisis statistik: memastikan
tidak ada nilai negatif/nol/di luar batas wajar. Hasil: 0 baris — data numerik aman dipakai
untuk perhitungan statistik berikutnya.

### 2.15 Statistik deskriptif gabungan
```sql
SELECT 'quantity' AS metric, MIN(...), MAX(...), ROUND(AVG(...),4) AS mean,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY quantity) AS median,
       MODE() WITHIN GROUP (ORDER BY quantity) AS mode,
       ROUND(STDDEV(...),4), ROUND(VARIANCE(...),4)
FROM fact_sales
UNION ALL
SELECT 'unit_price', ... FROM fact_sales
UNION ALL
SELECT 'revenue', ... FROM fact_sales
UNION ALL
SELECT 'discount_pct', ... FROM fact_sales;
```
Karena data sudah divalidasi bersih (2.14), sekarang dihitung statistik lengkap (min, max,
mean, median, mode, stddev, variance) untuk 4 kolom numerik sekaligus, digabung jadi satu
tabel rapi lewat `UNION ALL`. Hasil `discount_pct` stddev/variance = 0 **mengonfirmasi
ulang** temuan 2.11.

### 2.16 Kategori terlaris (window function)
```sql
SELECT category, cnt FROM (
    SELECT p.category, COUNT(*) AS cnt,
           RANK() OVER (ORDER BY COUNT(*) DESC) AS rnk
    FROM fact_sales f JOIN dim_product p ON f.product_key = p.product_key
    GROUP BY p.category
) t WHERE rnk = 1;
```
Melanjutkan dari statistik umum (2.15) ke pertanyaan bisnis pertama: kategori mana yang
paling sering terjual? `RANK() OVER (...)` dipakai di subquery untuk mengurutkan lalu
`WHERE rnk = 1` mengambil hanya juaranya. Hasil: **Electronics**, 21.813 transaksi.

### 2.17 Kuartil revenue
```sql
SELECT
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY revenue) AS q1,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY revenue) AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY revenue) AS q3
FROM fact_sales;
```
Memperdalam statistik `revenue` dari 2.15 dengan kuartil penuh (Q1/median/Q3) — berguna
untuk mendeteksi outlier lewat IQR. Hasil: 27,53 / 47,90 / 77,30.

### 2.18 Revenue per region × kategori × kuartal
```sql
SELECT s.region, p.category, d.quarter,
       COUNT(*) AS num_sales, SUM(f.revenue) AS total_revenue,
       ROUND(AVG(f.revenue), 2) AS avg_revenue,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.revenue) AS median_revenue
FROM fact_sales f
JOIN dim_store   s ON f.store_key = s.store_key
JOIN dim_product p ON f.product_key = p.product_key
JOIN dim_date    d ON f.date_key = d.date_key
GROUP BY s.region, p.category, d.quarter
ORDER BY total_revenue DESC;
```
Di sinilah **korelasi struktural** (2.4) dan hasil pembersihan `dim_date` (2.8–2.9) mulai
dipakai bersamaan: tiga tabel dimensi (`dim_store`, `dim_product`, `dim_date`) di-`JOIN`
sekaligus ke `fact_sales` untuk memecah revenue per kombinasi region/kategori/kuartal.

### 2.19 Top 10 pelanggan
```sql
SELECT c.customer_key, c.customer_name, c.segment, c.country,
       COUNT(*) AS orders, SUM(f.revenue) AS lifetime_revenue,
       ROUND(AVG(f.revenue), 2) AS avg_order_value
FROM fact_sales f
JOIN dim_customer c ON f.customer_key = c.customer_key
GROUP BY c.customer_key, c.customer_name, c.segment, c.country
ORDER BY lifetime_revenue DESC
LIMIT 10;
```
Sudut pandang bergeser dari "produk/wilayah" (2.18) ke "pelanggan" — memakai
`dim_customer` yang sudah dibersihkan di 2.13. `GROUP BY` per pelanggan lalu diurutkan
turun berdasarkan total revenue seumur hidup.

### 2.20 Produk terlaris + margin
```sql
SELECT p.product_key, p.product_name, p.category,
       SUM(f.quantity) AS units_sold, SUM(f.revenue) AS total_revenue,
       ROUND(AVG(f.revenue / NULLIF(f.quantity,0)), 2) AS avg_revenue_per_unit,
       p.unit_cost, p.list_price,
       ROUND(p.list_price - p.unit_cost, 2) AS unit_margin
FROM fact_sales f
JOIN dim_product p ON f.product_key = p.product_key
GROUP BY p.product_key, p.product_name, p.category, p.unit_cost, p.list_price
ORDER BY total_revenue DESC
LIMIT 20;
```
Melanjutkan dari "kategori terlaris" (2.16) ke level yang lebih detail: produk individual,
lengkap dengan estimasi margin (`list_price - unit_cost`). Temuan penting: banyak produk
top-seller punya margin **negatif** — indikasi data `dim_product` bermasalah (mirip temuan
2.10 soal `revenue`).

### 2.21 Weekday vs weekend
```sql
SELECT d.is_weekend, COUNT(*) AS num_sales, SUM(f.revenue) AS total_revenue,
       ROUND(AVG(f.revenue), 2) AS avg_revenue
FROM fact_sales f
JOIN dim_date d ON f.date_key = d.date_key
GROUP BY d.is_weekend;
```
Memanfaatkan langsung hasil perbaikan `is_weekend` dari 2.9. Hasil: rata-rata revenue
hampir identik (weekday $57.52 vs weekend $57.46) — tidak ada pola musiman mingguan yang
kuat, volume saja yang beda (weekday ~2× lebih banyak transaksi).

### 2.22 Tren bulanan
```sql
SELECT d.month_name, d.quarter, COUNT(*) AS num_sales, SUM(f.revenue) AS total_revenue
FROM fact_sales f
JOIN dim_date d ON f.date_key = d.date_key
GROUP BY d.month_name, d.quarter
ORDER BY MIN(d.full_date);
```
Melanjutkan analisis waktu dari 2.21, tapi granularitasnya bulanan, dan diurutkan
berdasarkan `MIN(full_date)` (bukan alfabet) supaya kronologis. Catatan: `month_name`
sendiri tidak pernah diperbaiki (beda dengan `quarter` di 2.8), jadi urutan/pengelompokan
bulan di sini masih bisa mengandung inkonsistensi bawaan data.

### 2.23 Peringkat toko per region
```sql
SELECT s.region, s.store_name, s.store_type,
       SUM(f.revenue) AS total_revenue,
       RANK() OVER (PARTITION BY s.region ORDER BY SUM(f.revenue) DESC) AS rank_in_region
FROM fact_sales f
JOIN dim_store s ON f.store_key = s.store_key
GROUP BY s.region, s.store_name, s.store_type;
```
Menggabungkan teknik `RANK()` dari 2.16 dengan `PARTITION BY` — supaya peringkat dihitung
**ulang per region**, bukan peringkat global. Hasil: 40 toko, masing-masing punya
peringkat sendiri di dalam regionnya.

### 2.24 Perilaku per segmen pelanggan
```sql
SELECT c.segment,
       COUNT(DISTINCT c.customer_key) AS num_customers,
       COUNT(*) AS num_orders,
       ROUND(AVG(f.revenue), 2) AS avg_order_value,
       ROUND(SUM(f.revenue) / COUNT(DISTINCT c.customer_key), 2) AS revenue_per_customer
FROM fact_sales f
JOIN dim_customer c ON f.customer_key = c.customer_key
GROUP BY c.segment
ORDER BY revenue_per_customer DESC;
```
Memperluas analisis pelanggan (2.19) ke level segmen (`Consumer`/`Corporate`/`Home
Office`). `COUNT(DISTINCT ...)` dipakai supaya pelanggan dengan banyak transaksi tidak
dihitung berkali-kali saat menghitung jumlah pelanggan. Hasil: ketiga segmen nyaris sama
persis nilainya (~$1.710–$1.733 per pelanggan) — tidak ada segmen yang menonjol.

### 2.25 Korelasi statistik harga vs kuantitas
```sql
SELECT CORR(unit_price, quantity) AS price_qty_correlation FROM fact_sales;
```
Query penutup, dan ini yang secara eksplisit mengukur **korelasi statistik** yang
disinggung di §1: `CORR()` menghitung koefisien korelasi Pearson antara `unit_price` dan
`quantity`. Hasilnya **0,0077** — nyaris nol, artinya harga satuan **tidak memengaruhi**
jumlah unit yang dibeli pelanggan pada dataset ini (tidak ada elastisitas harga yang
terdeteksi).

---

## 3. Kesimpulan

1. **Korelasi struktural antar tabel valid 100%** — semua foreign key di `fact_sales`
   (`customer_key`, `date_key`, `product_key`, `store_key`) punya pasangan yang sah di
   tabel dimensi masing-masing, tanpa baris yatim (*orphan*).
2. **Korelasi statistik antara harga dan kuantitas nyaris tidak ada** (`CORR` ≈ 0,0077) —
   pelanggan tidak membeli lebih sedikit saat harga naik atau lebih banyak saat harga
   turun. Ini sinyal kuat bahwa dataset bersifat sintetis/acak, bukan data transaksi nyata
   yang biasanya menunjukkan elastisitas harga.
3. **Kolom turunan di `dim_date` awalnya tidak konsisten** — `quarter` dan `is_weekend`
   sudah diperbaiki dari `full_date`/`day_of_week`, tapi **`month_name` masih belum
   diperbaiki** sehingga analisis bulanan (2.22) berpotensi bias.
4. **`revenue` tidak mengikuti rumus `quantity × unit_price × (1 − discount_pct)`**
   (99,9% baris berbeda) dan **`discount_pct` konstan 0,35 di seluruh data** — kedua
   kolom ini tidak bisa saling memvalidasi, jadi `revenue` harus diperlakukan sebagai
   angka independen (ground truth), bukan hasil kalkulasi.
5. **15 email pelanggan terduplikasi** di `dim_customer` — sudah dirapikan formatnya
   (trim/lower/upper) tapi **belum digabung** (merge) menjadi satu `customer_key`.
6. **Margin produk banyak yang negatif** (`list_price` < `unit_cost`) pada produk-produk
   dengan revenue tertinggi — kemungkinan data `dim_product` juga bermasalah/sintetis,
   jadi metrik margin tidak boleh dipakai untuk keputusan bisnis nyata tanpa verifikasi
   ulang sumber datanya.
7. **Temuan bisnis yang tetap valid untuk dilaporkan:** kategori terlaris adalah
   Electronics (21.813 transaksi), region East + Electronics + Q3 adalah kombinasi
   revenue tertinggi, dan revenue per pelanggan relatif merata di ketiga segmen
   (Consumer/Corporate/Home Office) — tidak ada segmen yang jauh lebih menguntungkan.

**Rekomendasi tindak lanjut:** jangan gunakan `discount_pct`, rumus revenue manual, atau
margin produk sebagai dasar keputusan sebelum sumber data divalidasi ulang; perbaiki
`month_name`; gabungkan (merge) 15 pasangan pelanggan duplikat; dan segera pindahkan
kredensial database dari notebook ke environment variable.
