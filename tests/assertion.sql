DO $$
DECLARE
  n bigint;
BEGIN
  SELECT count(*) INTO n FROM clean.fact_sales;
  IF n <> 60000 THEN
    RAISE EXCEPTION 'clean.fact_sales: expected 60000 rows, got %', n;
  END IF;

  SELECT count(*) INTO n FROM clean.dim_customer;
  IF n <> 1995 THEN
    RAISE EXCEPTION 'clean.dim_customer: expected 1995 rows, got %', n;
  END IF;

  SELECT count(*) INTO n FROM clean.dim_product WHERE unit_cost > list_price;
  IF n > 0 THEN
    RAISE EXCEPTION '% products have unit_cost > list_price', n;
  END IF;
END $$;