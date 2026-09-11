# Fondasi Pikiran — Dari Data Mentah ke Insight Stakeholder

Dokumen ini adalah **pintu masuk** sebelum membaca `readmechat.md` dan
`readmechat2stakeholder.md`. Isinya bukan SQL, tapi **alur berpikir**: kenapa saya
mengerjakan analisis ini dengan urutan seperti itu, apa yang saya khawatirkan di setiap
tahap, dan bagaimana satu tahap membenarkan tahap berikutnya. Kalau dua dokumen lain
menjawab "apa" dan "bagaimana", dokumen ini menjawab **"kenapa urutannya begini"**.

---

## 1. Titik Berangkat: Pertanyaan yang Ingin Dijawab

Saya punya 5 file data (`dim_customer`, `dim_date`, `dim_product`, `dim_store`,
`fact_sales`) yang membentuk *star schema* di Postgres. Tujuan akhirnya sederhana:
**hasilkan insight yang bisa dipercaya untuk pengambilan keputusan bisnis.**

Tapi ada satu prinsip yang saya pegang dari awal:

> **Data mentah tidak otomatis bisa dipercaya — apalagi kalau belum pernah divalidasi.**

Prinsip ini yang menentukan seluruh urutan kerja di bawah, dan kenapa saya tidak langsung
lompat ke "bikin dashboard revenue per region" di awal.

---

## 2. Kerangka Berpikir — 4 Tahap Berurutan

Saya membagi proses berpikir jadi 4 tahap besar. Tiap tahap **tidak boleh dilompati**,
karena tahap berikutnya bergantung pada kepercayaan yang dibangun di tahap sebelumnya.

```
Tahap 1          Tahap 2              Tahap 3               Tahap 4
Kenali struktur → Audit kepercayaan → Bersihkan/tandai   → Insight bisnis
data & relasi     data (jangan asal    apa yang bisa/tidak   untuk stakeholder
                  percaya)             bisa dipercaya
     │                  │                    │                    │
     ▼                  ▼                    ▼                    ▼
 star schema,     anti-join FK,        UPDATE dim_date,      readmechat2
 5 tabel,         cek rumus revenue,    UPDATE fact_sales,    stakeholder.md
 primary key      cek diskon konstan,   CREATE VIEW           (bahasa bisnis,
                  cek email duplikat    fact_sales_clean      angka aman dipakai)
     └──────────────────────┬──────────────────────┘
                    readmechat.md
                (fondasi teknis & audit)
```

### Tahap 1 — Kenali struktur data & relasinya
Sebelum menulis satu query analisis pun, saya perlu tahu: tabel apa saja yang ada, apa
primary key-nya, dan bagaimana mereka saling terhubung (`fact_sales` sebagai tabel fakta,
4 tabel dimensi di sekelilingnya). Ini murni pemetaan — belum ada penilaian benar/salah.

**Kenapa ini duluan?** Karena semua tahap setelahnya (audit, cleaning, insight) memakai
`JOIN` antar tabel. Kalau saya tidak paham relasinya dulu, saya bisa salah `JOIN`
(misalnya `JOIN` yang diam-diam membuang atau menggandakan baris) tanpa sadar.

### Tahap 2 — Audit kepercayaan data ("jangan asal percaya")
Di sinilah pola pikir utamanya: **setiap kolom yang akan dipakai untuk keputusan bisnis,
harus diuji dulu apakah dia konsisten secara internal.** Contoh pertanyaan yang saya
ajukan ke data di tahap ini:
- Apakah semua foreign key di `fact_sales` benar-benar punya pasangan di tabel dimensi?
  (kalau tidak → `JOIN` bisa diam-diam kehilangan data)
- Apakah `revenue` benar-benar hasil dari `quantity × harga × (1-diskon)`? (kalau tidak
  cocok → berarti ada kolom yang tidak bisa dipakai untuk memvalidasi kolom lain)
- Apakah `discount_pct` benar-benar bervariasi, atau cuma angka konstan yang tidak
  berguna secara analitis?
- Apakah `quarter`/`is_weekend` di `dim_date` benar-benar konsisten dengan tanggal
  aslinya (`full_date`/`day_of_week`)?
- Apakah ada pelanggan yang tercatat dobel (email sama, `customer_key` beda)?

**Kenapa tahap ini sebelum insight bisnis?** Karena kalau saya langsung bikin "Top 10
produk paling untung" tanpa audit dulu, saya baru sadar belakangan bahwa margin produk di
data ini banyak yang negatif (harga jual < harga modal) — dan itu bisa keburu dipresentasikan
sebagai fakta ke stakeholder padahal itu cacat data.

### Tahap 3 — Bersihkan yang bisa, tandai yang tidak bisa
Hasil audit di Tahap 2 tidak selalu berujung "perbaiki". Ada tiga jenis tindak lanjut yang
saya pakai, tergantung sifat masalahnya:

| Jenis masalah | Tindakan | Contoh |
|---|---|---|
| Bisa dihitung ulang dari sumber yang benar | **Perbaiki langsung** (`UPDATE`) | `quarter` dan `is_weekend` bisa dihitung ulang dari `full_date`/`day_of_week`, jadi langsung diperbaiki. |
| Sumber kebenarannya jelas, tapi ada di kolom lain | **Buat view / sinkronkan** | `fact_sales.category` tidak dipercaya sendirian → dibuat `fact_sales_clean` yang menarik `category` dari `dim_product`. |
| Tidak ada sumber kebenaran yang jelas | **Jangan diperbaiki, cukup ditandai** | `revenue` tidak cocok rumus manual — saya tidak tahu rumus aslinya, jadi saya **tidak menimpa** `revenue`, cukup mendokumentasikan bahwa dia tidak bisa divalidasi silang. Sama untuk margin produk yang negatif — bukan sesuatu yang saya "perbaiki", tapi saya tandai sebagai tidak layak dipakai. |

Prinsipnya: **jangan pernah menimpa data kalau saya tidak yakin apa nilai yang benar.**
Lebih aman menandainya sebagai "tidak bisa dipercaya" daripada memaksa memperbaikinya
dengan asumsi yang belum tentu benar.

Ketiga sub-tahap di atas (2 dan 3) itulah isi `readmechat.md` — dokumen itu adalah
**catatan proses berpikir teknis**, ditulis berurutan supaya siapa pun (termasuk saya
sendiri nanti) bisa mengikuti kenapa satu query dijalankan sebelum query lain.

### Tahap 4 — Insight bisnis, tapi hanya di atas fondasi yang sudah aman
Baru setelah Tahap 2–3 selesai, saya boleh menjawab pertanyaan bisnis: kategori mana yang
paling laku, region mana paling untung, pelanggan mana paling bernilai, dst. Tapi ada satu
aturan tambahan di tahap ini: **setiap insight yang dibangun harus secara sadar
menghindari kolom yang sudah ditandai bermasalah di Tahap 2**, atau menjelaskan
keterbatasannya kalau tetap dipakai.

Inilah isi `readmechat2stakeholder.md` — bukan cuma "query bisnis", tapi query bisnis yang
**sudah difilter** lewat pengetahuan dari Tahap 2–3. Contoh konkret:
- Saya pakai `fact_sales_clean` (bukan `fact_sales.category` mentah) karena Tahap 2/3
  sudah membuktikan kolom mentahnya tidak sinkron.
- Saya hitung tren bulanan dari `full_date` langsung, **bukan** dari `month_name`, karena
  Tahap 2 menemukan `month_name` tidak pernah diperbaiki dan masih tidak konsisten.
- Saya sengaja **tidak** menampilkan kolom margin produk ke stakeholder, karena Tahap 2
  menemukan margin banyak yang negatif dan sumbernya diragukan.
- Saya menambahkan bagian "Catatan Keterbatasan Data" secara eksplisit supaya siapa pun
  yang membaca dokumen bisnis tahu batasan angka yang mereka lihat — ini terjemahan
  langsung dari temuan audit di Tahap 2, hanya beda bahasa (dari bahasa teknis ke bahasa
  bisnis).

---

## 3. Peta Hubungan Tiga Dokumen

```
readmechatpenjelasanawal.md   ← Anda di sini: PETA & ALASAN urutan berpikir
        │
        │  menjelaskan kenapa urutannya begini
        ▼
readmechat.md                 ← FONDASI: audit struktur + kualitas data,
                                 dijelaskan sintaks per sintaks, berurutan,
                                 setiap query dikaitkan ke query sebelum/sesudahnya
        │
        │  hasil validasi & pembersihannya jadi "aturan main"
        ▼
readmechat2stakeholder.md     ← APLIKASI: query insight bisnis yang dibangun
                                 di atas tabel/kolom yang sudah "lolos" audit,
                                 dengan bahasa & framing untuk non-teknis
```

Bacaan yang disarankan: **dokumen ini dulu** (untuk paham kerangka berpikirnya) → lalu
`readmechat.md` (untuk paham detail teknis & kenapa data perlu dibersihkan) → baru
`readmechat2stakeholder.md` (untuk paham bagaimana hasil itu diterjemahkan jadi keputusan
bisnis). Membaca dengan urutan terbalik tetap bisa, tapi risikonya: insight bisnis di
dokumen ketiga bisa terasa "kok tiba-tiba menghindari kolom ini/itu" tanpa tahu alasannya
— alasan itu ada di dokumen kedua, dan dasar pemikirannya ada di sini.

---

## 4. Prinsip yang Saya Pegang dari Awal sampai Akhir

1. **Struktur dulu, baru makna.** Pahami relasi antar tabel sebelum menilai isi datanya.
2. **Audit sebelum analisis.** Jangan pernah membangun insight bisnis di atas kolom yang
   belum diuji konsistensinya.
3. **Perbaiki hanya kalau sumber kebenarannya jelas.** Kalau tidak yakin nilai yang benar
   itu apa, jangan menimpa data — cukup tandai sebagai tidak bisa dipercaya.
4. **Insight bisnis harus mewarisi kehati-hatian dari tahap audit.** Setiap angka yang
   sampai ke stakeholder harus bisa ditelusuri balik: kenapa kolom ini dipakai, kenapa
   kolom itu dihindari.
5. **Pisahkan bahasa teknis dan bahasa bisnis, tapi jangan pisahkan kejujurannya.**
   `readmechat2stakeholder.md` ditulis dengan bahasa non-teknis, tapi keterbatasan data
   tetap disampaikan (bagian "Catatan Keterbatasan Data"), bukan disembunyikan demi
   presentasi yang terlihat rapi.

Singkatnya: **saya tidak pernah melompat langsung dari data mentah ke kesimpulan bisnis.**
Selalu ada jembatan audit-dan-pembersihan di tengah, dan jembatan itu yang membuat saya
(dan siapa pun yang membaca ketiga dokumen ini) bisa mempercayai — atau tahu persis kapan
harus curiga pada — angka yang akhirnya dipresentasikan.
