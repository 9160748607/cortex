/* ---------------------------------------------------------------------------
   V6.1.7 - Gold conformed date dimension

   1950-01-01 to 2035-12-31, 31,411 rows.

   ==========================================================================
   THIS IS A REGULAR TABLE, NOT A DYNAMIC TABLE - AND NOT BY PREFERENCE
   ==========================================================================
   Everything else in silver and gold is a dynamic table. This is the one
   exception, and it is forced. Measured:

       CREATE DYNAMIC TABLE ... AS SELECT DATEADD(day, SEQ4(), ...)
                                  FROM TABLE(GENERATOR(ROWCOUNT => 100))
       -> SQL compilation error:
          Dynamic Tables must have at least one base table.

   A date spine is pure arithmetic over a row generator. It has no base table,
   so Snowflake rejects it outright. There is no workaround that is also honest:
   the only way to give it a base table is to derive the bounds from
   sv_sales_header, and that has two independent problems, either of which is
   disqualifying on its own. See the next two sections.

   ==========================================================================
   WHY THE RANGE IS NOT TAKEN FROM THE SALES MIN/MAX
   ==========================================================================
   The instinct is to bound the calendar by the fact. Measured, the fact spans
   ONE YEAR - 2019-01-01 to 2020-01-01, 366 distinct dates (the upper bound
   being the 24 timezone-spillover rows). A sales-bounded calendar would be 366
   rows and would serve the transaction date and NOTHING ELSE.

   The model has NINE other business date columns, spanning 1950 to 2026:

       customer.date_of_birth            1950-04-18 .. 2008-04-16   16,422 distinct
       category.effective_start_date     1984-01-24 .. 2024-02-02       10
       country.effective_start_date      1997-11-10 .. 2014-05-06       21
       store.store_open_date             2016-04-29 .. 2026-04-10      119
       sales.transaction_timestamp       2019-01-01 .. 2020-01-01      366
       customer.registration_date        2019-01-01 .. 2019-12-31      365
       availability.local_launch_date    2019-02-09 .. 2024-12-06      853
       sku.global_launch_date            2019-02-09 .. 2024-11-08       47
       model.launch_date                 2019-02-09 .. 2024-11-08       47

   A 366-row calendar fails every one of them. The first "store openings per
   quarter" or "launches per fiscal year" question would either return nothing
   or silently drop rows. That is not a conformed dimension, it is a
   transaction-date lookup table.

   The chosen range covers all nine, verified below with a zero-miss check per
   column.

   ==========================================================================
   HOW THE LINEAGE LINK ACTUALLY WORKS - THIS IS THE PART THAT MISLEADS
   ==========================================================================
   The requirement was to see dim_date linked to the facts in the dynamic-table
   lineage graph. The edge that delivers that is:

       dim_date  ->  fact_sales          (dimension feeds fact)

   and it comes from FACT_SALES JOINING DIM_DATE. It does NOT come from
   dim_date reading the sales table. Those are opposite directions.

   This works with a regular table. The proof is already in this repo: every
   silver dynamic table sits on a REGULAR BRONZE TABLE, and that lineage renders
   correctly. dim_date (table) -> fact_sales (DT) is the identical pattern.

   Deriving the range from sales would produce a WORSE graph, not a better one -
   sv_sales_header would appear upstream of BOTH dim_date and fact_sales, a
   diamond that asserts the calendar changes when sales data changes. January
   1950 does not depend on our sales feed.

   So V6.2.1 must join this table rather than computing the key arithmetically.
   TO_NUMBER(TO_CHAR(transaction_timestamp,'YYYYMMDD')) would produce the correct
   date_key with no join - and no lineage edge, and no integrity guarantee. The
   join is the point.

   *** USE A LEFT JOIN, NOT AN INNER JOIN. *** An inner join silently drops any
   fact whose date falls outside the calendar. LEFT JOIN plus an assertion that
   date_key IS NOT NULL turns the join into a coverage guard, which is exactly
   what this repo keeps needing - see the 24 rows on 2020-01-01.

   ==========================================================================
   *** THIS TABLE DOES NOT COVER 9999-12-31. NEVER JOIN valid_to TO IT. ***
   ==========================================================================
   dim_country.valid_to carries 9999-12-31 as the open-ended sentinel for the
   current version (V6.1.1 / V6.1.2). No calendar can contain that date. Joining
   dim_country.valid_to to dim_date would drop EVERY CURRENT ROW - the single
   most damaging thing that could be done with this table, and it would look like
   a clean result. Only ever join valid_from.

   NO RELATIVE FLAGS, BY DESIGN
   --------------------------------------------------------------------
   There is deliberately no is_current_month / is_ytd / days_ago column. In a
   statically populated table those would be evaluated ONCE at load time and then
   be silently, permanently wrong. Consumers must compare against CURRENT_DATE at
   query time. (This is the same non-determinism that forces FULL refresh in a
   dynamic table - see AGENT.md section 5 - showing up in a different guise.)

   ISO DATE PARTS, NOT THE PLAIN ONES
   --------------------------------------------------------------------
   day_of_week_iso / iso_week / iso_year use DAYOFWEEKISO, WEEKISO and
   YEAROFWEEKISO. The plain DAYOFWEEK / WEEK / YEAROFWEEK depend on the session
   parameters WEEK_START and WEEK_OF_YEAR_POLICY, so two users could read
   different values from the same row. The ISO variants are parameter-independent.

   Note the consequence, verified below: 2019-12-30 has year_num = 2019 but
   iso_year = 2020, iso_week = 1. NEVER group by iso_week without also grouping
   by iso_year.

   THE FISCAL COLUMNS ARE AN APPROXIMATION - DO NOT RECONCILE THEM
   --------------------------------------------------------------------
   fiscal_year / fiscal_quarter / fiscal_month_of_year use a simple
   OCTOBER-SEPTEMBER month boundary. Apple's real fiscal calendar is a 52/53-week
   calendar ending the last Saturday of September - FY2019 ran 2018-09-30 to
   2019-09-28. This does not reproduce it.

   The divergence is real and measurable: 2019-09-30 is FY2019 Q4 here, but
   FY2020 Q1 on Apple's actual calendar. Safe for internal period grouping;
   NEVER reconcile against published Apple financials. Building the true calendar
   is a separate piece of work and needs the anchor dates as an input, not a guess.

   Also unrelated to dim_country.apple_fiscal_segment, which is GEOGRAPHIC
   (5 values) despite the similar name - see section 7.

   THE ONLY GOLD OBJECT WITH A DECLARED PRIMARY KEY
   --------------------------------------------------------------------
   Because this is a regular table, it can carry real CONSTRAINT clauses -
   PRIMARY KEY (date_key) RELY and UNIQUE (full_date) RELY. Every other gold
   object is a dynamic table, which accepts no constraint clause at all and can
   only obtain a SYS_CONSTRAINT_DERIVED_PK via QUALIFY. Worth knowing when
   comparing SHOW PRIMARY KEYS output across the schema.

   TRANSIENT: consistent with the rest of SALES_DEV, and harmless here - the
   contents are fully deterministic, so the table is regenerable by re-running
   this script. No Fail-safe is needed for arithmetic.

   IDEMPOTENT: CREATE TABLE IF NOT EXISTS, and the INSERT is guarded by a
   NOT EXISTS anti-join on date_key. Re-running inserts 0 rows (verified).
   To EXTEND the range later, raise the upper bound and re-run - it tops up
   rather than duplicating. Extending BACKWARDS also works.
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} TABLE IF NOT EXISTS {{ database }}.GOLD.dim_date (
  date_key              NUMBER(8,0)  NOT NULL COMMENT 'PRIMARY KEY. YYYYMMDD smart key, e.g. 20190101. Safe as a stored surrogate in a way dim_country.country_key is NOT: a calendar is SCD-0, so this value can never go stale or pin a version. Facts store this.',
  full_date             DATE         NOT NULL COMMENT 'The calendar date itself. Unique, 1:1 with date_key. Join on this when the fact carries a DATE rather than a date_key.',
  year_num              NUMBER(4,0)  NOT NULL COMMENT 'Calendar year.',
  quarter_num           NUMBER(1,0)  NOT NULL COMMENT 'Calendar quarter 1-4.',
  month_num             NUMBER(2,0)  NOT NULL COMMENT 'Calendar month 1-12.',
  day_num               NUMBER(2,0)  NOT NULL COMMENT 'Day of month 1-31.',
  month_name            VARCHAR(9)   NOT NULL COMMENT 'Full month name, e.g. January.',
  month_abbr            VARCHAR(3)   NOT NULL COMMENT 'Three-letter month, e.g. Jan.',
  year_month            VARCHAR(7)   NOT NULL COMMENT 'YYYY-MM. Sorts correctly as a string - use this for month grouping rather than concatenating year and month yourself.',
  year_quarter          VARCHAR(7)   NOT NULL COMMENT 'YYYY-Qn, e.g. 2019-Q1.',
  day_of_year           NUMBER(3,0)  NOT NULL COMMENT 'Day of year 1-366.',
  day_of_week_iso       NUMBER(1,0)  NOT NULL COMMENT 'ISO day of week, 1=Monday to 7=Sunday. Deliberately ISO: plain DAYOFWEEK depends on the session WEEK_START parameter and would differ between users. Never mix the two.',
  day_name              VARCHAR(9)   NOT NULL COMMENT 'Full day name, e.g. Monday.',
  day_abbr              VARCHAR(3)   NOT NULL COMMENT 'Three-letter day, e.g. Mon.',
  is_weekend            BOOLEAN      NOT NULL COMMENT 'TRUE for Saturday and Sunday (ISO 6 and 7). Retail-relevant: store traffic and channel mix differ.',
  iso_year              NUMBER(4,0)  NOT NULL COMMENT 'ISO week-numbering year. DIFFERS from year_num at year boundaries - 2019-12-30 is ISO year 2020. Never group by iso_week without also grouping by iso_year.',
  iso_week              NUMBER(2,0)  NOT NULL COMMENT 'ISO week 1-53. Parameter-independent, unlike WEEK().',
  first_day_of_month    DATE         NOT NULL COMMENT 'First day of this month. Precomputed so consumers do not need DATE_TRUNC.',
  last_day_of_month     DATE         NOT NULL COMMENT 'Last day of this month.',
  first_day_of_quarter  DATE         NOT NULL COMMENT 'First day of this quarter.',
  first_day_of_year     DATE         NOT NULL COMMENT 'First day of this year.',
  days_in_month         NUMBER(2,0)  NOT NULL COMMENT 'Length of this month, 28-31. Useful for normalising per-day rates.',
  is_leap_year          BOOLEAN      NOT NULL COMMENT 'TRUE if year_num is a leap year.',
  fiscal_year           NUMBER(4,0)  NOT NULL COMMENT '*** APPROXIMATION - READ THIS. *** Apple fiscal year on a simple OCTOBER-SEPTEMBER month boundary, so Oct 2018 falls in FY2019. Apple actually uses a 52/53-week calendar ending the last Saturday of September (FY2019 was 2018-09-30 to 2019-09-28), which this does NOT reproduce - 2019-09-30 is FY2019 Q4 here but FY2020 Q1 on the real calendar. Safe for internal period grouping; do NOT reconcile against published Apple financials.',
  fiscal_quarter        NUMBER(1,0)  NOT NULL COMMENT 'Fiscal quarter 1-4 on the same Oct-Sep approximation. Oct-Dec=Q1. Same caveat as fiscal_year.',
  fiscal_month_of_year  NUMBER(2,0)  NOT NULL COMMENT 'Fiscal month 1-12 where October=1. Same caveat as fiscal_year.',
  /* Only possible because this is a regular table - see header. */
  CONSTRAINT pk_dim_date            PRIMARY KEY (date_key) RELY,
  CONSTRAINT uk_dim_date_full_date  UNIQUE      (full_date) RELY
)
COMMENT = 'Gold conformed date dimension, 1950-01-01 to 2035-12-31 (31,411 rows). A REGULAR TABLE, NOT a dynamic table - measured: "Dynamic Tables must have at least one base table", and a calendar has no base table. Making it a DT would require deriving bounds from sv_sales_header, which would both limit it to the 366 sales days and falsely assert that the calendar depends on sales data. Lineage to fact_sales comes from the FACT JOINING THIS TABLE (dim_date -> fact_sales), the same DT-on-regular-table pattern as bronze -> silver. *** DOES NOT COVER 9999-12-31: never join dim_country.valid_to to this table - it would drop every current row. *** Contains NO relative flags (is_current_month etc) by design; in a static table those freeze at load time and are silently wrong forever.';


/* ---------------------------------------------------------------------------
   POPULATE - idempotent via the NOT EXISTS anti-join on date_key.
   Re-running inserts 0 rows. Raising the upper bound and re-running tops up.
   --------------------------------------------------------------------------- */

INSERT INTO {{ database }}.GOLD.dim_date (
  date_key, full_date, year_num, quarter_num, month_num, day_num,
  month_name, month_abbr, year_month, year_quarter,
  day_of_year, day_of_week_iso, day_name, day_abbr, is_weekend,
  iso_year, iso_week,
  first_day_of_month, last_day_of_month, first_day_of_quarter, first_day_of_year,
  days_in_month, is_leap_year,
  fiscal_year, fiscal_quarter, fiscal_month_of_year
)
SELECT
  YEAR(s.d)*10000 + MONTH(s.d)*100 + DAY(s.d)          AS date_key,
  s.d                                                  AS full_date,
  YEAR(s.d), QUARTER(s.d), MONTH(s.d), DAY(s.d),
  DECODE(MONTH(s.d),1,'January',2,'February',3,'March',4,'April',5,'May',6,'June',
                    7,'July',8,'August',9,'September',10,'October',11,'November',12,'December'),
  MONTHNAME(s.d),
  TO_CHAR(s.d,'YYYY-MM'),
  YEAR(s.d)::VARCHAR || '-Q' || QUARTER(s.d)::VARCHAR,
  DAYOFYEAR(s.d),
  /* ISO variants deliberately - parameter-independent. See header. */
  DAYOFWEEKISO(s.d),
  DECODE(DAYOFWEEKISO(s.d),1,'Monday',2,'Tuesday',3,'Wednesday',4,'Thursday',
                           5,'Friday',6,'Saturday',7,'Sunday'),
  DECODE(DAYOFWEEKISO(s.d),1,'Mon',2,'Tue',3,'Wed',4,'Thu',5,'Fri',6,'Sat',7,'Sun'),
  DAYOFWEEKISO(s.d) IN (6,7),
  YEAROFWEEKISO(s.d),
  WEEKISO(s.d),
  DATE_TRUNC('month',   s.d),
  LAST_DAY(s.d),
  DATE_TRUNC('quarter', s.d),
  DATE_TRUNC('year',    s.d),
  DAY(LAST_DAY(s.d)),
  /* Leap year by construction rather than by divisibility rules - correct for
     1900 and 2100 style century cases without special-casing. */
  DAY(LAST_DAY(DATE_FROM_PARTS(YEAR(s.d),2,1))) = 29,
  /* Oct-Sep approximation. See the caveat in the header and column comment. */
  YEAR(s.d) + IFF(MONTH(s.d) >= 10, 1, 0)              AS fiscal_year,
  CEIL((MOD(MONTH(s.d) + 2, 12) + 1) / 3.0)            AS fiscal_quarter,
  MOD(MONTH(s.d) + 2, 12) + 1                          AS fiscal_month_of_year
FROM (
  SELECT DATEADD(day, SEQ4(), '1950-01-01'::DATE) AS d
  FROM   TABLE(GENERATOR(ROWCOUNT => 32000))
) s
WHERE s.d <= '2035-12-31'::DATE
  AND NOT EXISTS (
        SELECT 1 FROM {{ database }}.GOLD.dim_date x
        WHERE  x.date_key = YEAR(s.d)*10000 + MONTH(s.d)*100 + DAY(s.d));
-- Recorded: 31411 rows inserted on first run, 0 on the second (idempotency verified).


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- The only gold object with a DECLARED primary key.
SHOW PRIMARY KEYS IN {{ database }}.GOLD.dim_date;
-- Recorded: DATE_KEY seq 1, PK_DIM_DATE, rely = true

-- Grain, bounds, and a gap check that does not rely on the expected row count
-- being hard-coded.
SELECT COUNT(*)                     AS rows_,
       COUNT(DISTINCT date_key)     AS distinct_keys,
       COUNT(DISTINCT full_date)    AS distinct_dates,
       MIN(full_date)               AS lo,
       MAX(full_date)               AS hi,
       DATEDIFF(day, MIN(full_date), MAX(full_date)) + 1 AS expected_rows,
       IFF(COUNT(*) = DATEDIFF(day, MIN(full_date), MAX(full_date)) + 1,
           'NO GAPS', 'GAP DETECTED')                    AS gap_check
FROM   {{ database }}.GOLD.dim_date;
-- Recorded: 31411, 31411, 31411, 1950-01-01, 2035-12-31, 31411, NO GAPS

-- ** THE CHECK THAT JUSTIFIES THE RANGE. ** Every business date column in the
-- model must resolve. All nine MUST be 0 - a non-zero value means the calendar
-- is too narrow and some other object will silently lose rows.
SELECT
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h WHERE h.__is_current_version
     AND NOT EXISTS (SELECT 1 FROM {{ database }}.GOLD.dim_date x WHERE x.full_date = h.transaction_timestamp::DATE)) AS miss_sales,
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master c WHERE c.date_of_birth IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM {{ database }}.GOLD.dim_date x WHERE x.full_date = c.date_of_birth))              AS miss_dob,
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master c WHERE c.registration_date IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM {{ database }}.GOLD.dim_date x WHERE x.full_date = c.registration_date))           AS miss_reg,
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_store_master s WHERE s.store_open_date IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM {{ database }}.GOLD.dim_date x WHERE x.full_date = s.store_open_date))             AS miss_store_open,
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_sku_master p WHERE p.__is_current_version AND p.global_launch_date IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM {{ database }}.GOLD.dim_date x WHERE x.full_date = p.global_launch_date))          AS miss_sku_launch,
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_model_master m WHERE m.__is_current_version AND m.launch_date IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM {{ database }}.GOLD.dim_date x WHERE x.full_date = m.launch_date))                 AS miss_model_launch,
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_country_availability a WHERE a.__is_current_version AND a.local_launch_date IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM {{ database }}.GOLD.dim_date x WHERE x.full_date = a.local_launch_date))           AS miss_local_launch,
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_category_master g
     WHERE NOT EXISTS (SELECT 1 FROM {{ database }}.GOLD.dim_date x WHERE x.full_date = g.effective_start_date))      AS miss_cat_eff,
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_country_master n
     WHERE NOT EXISTS (SELECT 1 FROM {{ database }}.GOLD.dim_date x WHERE x.full_date = n.effective_start_date))      AS miss_country_eff;
-- Recorded: 0, 0, 0, 0, 0, 0, 0, 0, 0

-- ** THE SENTINEL MUST NOT BE PRESENT. ** This is the guard on the most
-- damaging possible misuse - joining dim_country.valid_to to this table.
SELECT COUNT(*) AS sentinel_present
FROM   {{ database }}.GOLD.dim_date
WHERE  full_date = '9999-12-31';
-- Recorded: 0  (by design - see header)

-- Boundary logic: ISO year rollover, leap years, and the fiscal approximation.
SELECT full_date, date_key, year_num, iso_year, iso_week, day_name, is_weekend,
       fiscal_year, fiscal_quarter, fiscal_month_of_year, days_in_month, is_leap_year
FROM   {{ database }}.GOLD.dim_date
WHERE  full_date IN ('1950-01-01','2018-10-01','2019-01-01','2019-09-30','2019-12-30',
                     '2020-01-01','2020-02-29','2021-02-28','2026-04-17','2035-12-31')
ORDER  BY full_date;
-- Recorded (the rows that matter):
--   1950-01-01  iso_year 1949 wk 52  Sunday    weekend  FY1950 Q2 m4
--   2018-10-01  iso_year 2018 wk 40  Monday             FY2019 Q1 m1   <- fiscal start
--   2019-09-30  iso_year 2019 wk 40  Monday             FY2019 Q4 m12  <- Apple says FY2020 Q1
--   2019-12-30  iso_year 2020 wk 1   Monday             FY2020 Q1 m3   <- ISO ROLLOVER
--   2020-01-01  iso_year 2020 wk 1   Wednesday          leap, 31 days
--   2020-02-29  iso_year 2020 wk 9   Saturday  weekend  leap, 29 days
--   2021-02-28  iso_year 2021 wk 8   Sunday    weekend  not leap, 28 days
--   2035-12-31  iso_year 2036 wk 1   Monday             <- ISO ROLLOVER at the top bound
-- 2019-12-30 and 2035-12-31 are why iso_week must never be grouped without iso_year.
