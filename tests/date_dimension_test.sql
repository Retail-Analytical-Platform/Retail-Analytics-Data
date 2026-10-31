DO $$
DECLARE
    n bigint;
BEGIN
    -- One row per calendar day, 2024-01-01 .. 2025-12-31 (731 days), date only.
    SELECT count(*) INTO n FROM clean.dim_date;
    IF n <> 731 THEN RAISE EXCEPTION 'clean.dim_date: expected 731 rows, got %', n; END IF;

    SELECT count(*) INTO n FROM clean.dim_date
    WHERE full_date <> full_date::date;
    IF n > 0 THEN RAISE EXCEPTION 'clean.dim_date: % rows have a time component', n; END IF;

    SELECT 731 - count(DISTINCT full_date) INTO n FROM clean.dim_date;
    IF n > 0 THEN RAISE EXCEPTION 'clean.dim_date: % duplicate or missing days', n; END IF;

    -- Every derived label must agree with full_date.
    SELECT count(*) INTO n FROM clean.dim_date
    WHERE day_of_week IS DISTINCT FROM trim(to_char(full_date, 'Day'))
       OR month_name  IS DISTINCT FROM trim(to_char(full_date, 'Month'))
       OR quarter     IS DISTINCT FROM 'Q' || extract(quarter FROM full_date)::int
       OR is_weekend  IS DISTINCT FROM (extract(isodow FROM full_date) IN (6, 7));
    IF n > 0 THEN RAISE EXCEPTION 'clean.dim_date: % rows have labels that disagree with full_date', n; END IF;

    -- date_key must point at the same day as sold_at.
    SELECT count(*) INTO n
    FROM clean.fact_sales f JOIN clean.dim_date d USING (date_key)
    WHERE f.sold_at::date <> d.full_date;
    IF n > 0 THEN RAISE EXCEPTION 'clean.fact_sales: % rows where date_key and sold_at are different days', n; END IF;
END $$;