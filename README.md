# Retail Analytics Platform


## Tim & Role

Project ini dikerjakan secara kolaboratif dengan pembagian tanggung jawab sebagai berikut:

### Data Analyst
- Analisis model bisnis
- Membuat dashboard
- Menentukan definisi KPI
- Menyusun business insight & rekomendasi

### Data Engineer
- Setup GitHub & Docker
- Membangun ETL pipeline
- Data cleaning & transformation
- Pengelolaan database


  ## 📚 Dokumentasi

  Panduan penggunaan lebih detail ada di folder [`docs/`](./docs):

  - [`docs/data-integration-docker.md`](./docs/Data-Integration-Docker.md) —
  cara integrasi data menggunakan Docker
  - [`docs/docker.md`](./docs/Docker.md) — cara setup & menjalankan environment
  Docker project
  - [`docs/supabase-migration.md`](./docs/Supabase-Migration.md) — cara migrasi
  database dengan Supabase
## Struktur Repository

```
.
├── data/               # Raw & processed data
├── notebooks/          # Notebook eksplorasi & analisis
├── etl/                # Script ETL pipeline (Data Engineer)
├── dashboard/          # Source dashboard (Data Analyst)
├── docker/             # Konfigurasi Docker
├── docs/               # Dokumentasi, definisi KPI, insight report
└── README.md
```

## Cara Menjalankan

1. Clone repository
   ```bash
   git clone https://github.com/<org-atau-username>/<repo>.git
   cd <repo>
   ```
2. (Data Engineer) Jalankan environment via Docker
   ```bash
   docker compose up -d
   ```
3. (Data Analyst) Buka dashboard / notebook sesuai instruksi di folder masing-masing.

## Alur Kerja (Workflow)

1. **Data Engineer** menyiapkan data mentah → ETL → data bersih di database.
2. **Data Analyst** mengambil data bersih → analisis → dashboard & insight.
3. Perubahan dikerjakan di branch masing-masing, lalu diajukan lewat Pull Request untuk direview sebelum merge ke `main`.

## Tech Stack

| Kategori | Tools |
|---|---|
| ETL / Data Engineering | _(isi: Python, Airflow, dbt, dll)_ |
| Database | _(isi: PostgreSQL, MySQL, dll)_ |
| Dashboard / BI | _(isi: Looker Studio, Power BI, Tableau, Metabase, dll)_ |
| Infrastruktur | Docker, GitHub |