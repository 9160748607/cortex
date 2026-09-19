/* ===========================================================================
   REFERENCE ONLY - NOT EXECUTED BY SCHEMACHANGE

   Filename deliberately starts with an underscore. schemachange only picks up
   files prefixed V (versioned), R (repeatable) or A (always), so this file is
   ignored by `schemachange deploy` and can never be run against Snowflake.

   Why it exists: staging source files is a CLIENT-SIDE operation. PUT and
   `snow stage copy` run from a workstation or CI runner, not inside Snowflake,
   so they cannot live in a migration script. They are recorded here so the
   initial load is reproducible and reviewable alongside the DDL.

   Executed against: SALES_DEV (dev context), 2026-09-19
   Connection:       ysirciu-vg28332   (NAGUR / ACCOUNTADMIN / COMPUTE_WH)
   Stage:            SALES_DEV.BRONZE.sales_csv_stg  (see V4.1.1)

   Result: 47 files, 12.27 MB compressed.
   =========================================================================== */


/* ---------------------------------------------------------------------------
   0. Source tree
   ---------------------------------------------------------------------------
   __initial_load/
     country-master/                 4 flat CSVs
     product-master/                 5 flat CSVs
     store-master/                   1 flat CSV
     customer-master/<year>/<CC>/     245 CSVs  (7 years x 35 countries)
     sales-transaction/<year>/        2 CSVs per year (header + item)

   Only 2019 was staged for customer-master and sales-transaction. Years
   2020-2025 are intentionally NOT loaded yet.
   --------------------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
   1. Country master - 4 files
   ---------------------------------------------------------------------------
   cd __initial_load/country-master

   snow stage copy region_master.csv   '@SALES_DEV.BRONZE.sales_csv_stg/initial-load/country-master/' --parallel 12 --auto-compress -c ysirciu-vg28332
   snow stage copy country_master.csv  '@SALES_DEV.BRONZE.sales_csv_stg/initial-load/country-master/' --parallel 12 --auto-compress -c ysirciu-vg28332
   snow stage copy currency_master.csv '@SALES_DEV.BRONZE.sales_csv_stg/initial-load/country-master/' --parallel 12 --auto-compress -c ysirciu-vg28332
   snow stage copy tax_master.csv      '@SALES_DEV.BRONZE.sales_csv_stg/initial-load/country-master/' --parallel 12 --auto-compress -c ysirciu-vg28332
   --------------------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
   2. Product master - 5 files
   ---------------------------------------------------------------------------
   cd __initial_load/product-master

   snow stage copy product_category_master.csv      '@SALES_DEV.BRONZE.sales_csv_stg/initial-load/product-master/' --parallel 12 --auto-compress -c ysirciu-vg28332
   snow stage copy product_family_master.csv        '@SALES_DEV.BRONZE.sales_csv_stg/initial-load/product-master/' --parallel 12 --auto-compress -c ysirciu-vg28332
   snow stage copy product_model_master.csv         '@SALES_DEV.BRONZE.sales_csv_stg/initial-load/product-master/' --parallel 12 --auto-compress -c ysirciu-vg28332
   snow stage copy product_sku_master.csv           '@SALES_DEV.BRONZE.sales_csv_stg/initial-load/product-master/' --parallel 12 --auto-compress -c ysirciu-vg28332
   snow stage copy product_country_availability.csv '@SALES_DEV.BRONZE.sales_csv_stg/initial-load/product-master/' --parallel 12 --auto-compress -c ysirciu-vg28332
   --------------------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
   3. Store master - 1 file
   ---------------------------------------------------------------------------
   cd __initial_load/store-master

   snow stage copy store_master.csv '@SALES_DEV.BRONZE.sales_csv_stg/initial-load/store-master/' --parallel 12 --auto-compress -c ysirciu-vg28332
   --------------------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
   4. Customer master - 2019 only, 35 files, recursive
   ---------------------------------------------------------------------------
   cd __initial_load/customer-master

   snow stage copy 2019 '@SALES_DEV.BRONZE.sales_csv_stg/initial-load/customer-master/2019/' --recursive --parallel 15 --auto-compress -c ysirciu-vg28332

   IMPORTANT - destination must end in 2019/ .
   `--recursive` strips the SOURCE directory name and appends only the path
   BELOW it. Passing destination '.../customer-master/' therefore produced
   '.../customer-master/AE/...' with the year silently dropped, which would
   collide with 2020 because every year reuses the same 35 country codes.
   Naming the year in the destination gives '.../customer-master/2019/AE/...'.

   Recursive copy skips .DS_Store automatically - only the 35 CSVs uploaded.

   To load a later year, repeat with that year in BOTH places:
     snow stage copy 2020 '@SALES_DEV.BRONZE.sales_csv_stg/initial-load/customer-master/2020/' --recursive --parallel 15 --auto-compress -c ysirciu-vg28332
   --------------------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
   5. Sales transaction - 2019 only, 2 files
   ---------------------------------------------------------------------------
   cd __initial_load/sales-transaction/2019

   snow stage copy sales_header_2019.csv '@SALES_DEV.BRONZE.sales_csv_stg/initial-load/sales-transaction/2019/' --parallel 15 --auto-compress -c ysirciu-vg28332
   snow stage copy sales_item_2019.csv   '@SALES_DEV.BRONZE.sales_csv_stg/initial-load/sales-transaction/2019/' --parallel 15 --auto-compress -c ysirciu-vg28332
   --------------------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
   6. Register files in the directory table

   This DOES run in Snowflake. It is required after every upload: the delta
   ingest task in 07_orchestration reads the directory table to find files
   that arrived since the last COPY.
   --------------------------------------------------------------------------- */

-- ALTER STAGE SALES_DEV.BRONZE.sales_csv_stg REFRESH;


/* ---------------------------------------------------------------------------
   7. Verification
   --------------------------------------------------------------------------- */

-- LIST @SALES_DEV.BRONZE.sales_csv_stg;
--
-- SELECT SPLIT_PART(SPLIT_PART(RELATIVE_PATH, 'initial-load/', 2), '/', 1) AS folder,
--        COUNT(*) AS files,
--        ROUND(SUM(SIZE)/1024/1024, 2) AS total_mb
-- FROM   DIRECTORY(@SALES_DEV.BRONZE.sales_csv_stg)
-- GROUP  BY 1
-- ORDER  BY 1;


/* ---------------------------------------------------------------------------
   8. Recovering from a mis-pathed upload

   Used once, to delete the 35 customer files uploaded without the year level.
   PATTERN is a full-path regex, so it can target one bad level precisely.
   --------------------------------------------------------------------------- */

-- REMOVE @SALES_DEV.BRONZE.sales_csv_stg/initial-load/customer-master/
--   PATTERN='.*/customer-master/[A-Z]{2}/.*';


/* ---------------------------------------------------------------------------
   9. Windows PowerShell gotchas

   a) Wildcards do not survive. `snow stage copy *.csv ...` is expanded by
      PowerShell into separate argv entries and snow rejects them as
      "unexpected extra arguments". Quoting and the --% stop-parsing operator
      both failed. Upload per file, or use --recursive on a directory.

   b) snow writes a Python UserWarning about encoding to stderr. PowerShell
      escalates that to NativeCommandError, which looks like a failed upload
      even when the exit code is 0. Do not diagnose from a filtered pipeline -
      redirect the streams and read the exit code:

        snow stage copy <file> <dest> ... > out.txt 2> err.txt
        echo $LASTEXITCODE

      Never discard stderr with 2>$null: the result table (including the
      UPLOADED status) is written there, so failures become silent.
   --------------------------------------------------------------------------- */


/* ---------------------------------------------------------------------------
   10. Not done here - deliberately

   No COPY INTO. Bronze tables do not exist yet; they are built by the V4.2.x
   scripts using INFER_SCHEMA against COMMON.ff_csv_infer, and loaded by
   V4.3.1. These files are staged only.
   --------------------------------------------------------------------------- */
