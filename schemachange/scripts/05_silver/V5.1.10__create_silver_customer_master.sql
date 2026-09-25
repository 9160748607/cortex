/* ---------------------------------------------------------------------------
   V5.1.10 - Silver customer master (dynamic table)

   Tenth bronze -> silver transformation, and the first one carrying PERSONAL
   DATA. Reuses the pattern from V5.1.1 - see that header for de-duplication,
   deterministic survivor ordering, why QUALIFY ROW_NUMBER rather than DISTINCT,
   and why there is no is_current or silver load-timestamp column. See V5.1.7 for
   the rule that row-level flags describe only their own row.

   This script DIVERGES from the established pattern in four places, each
   justified below: the business key is not upper-cased, two source columns are
   dropped, one column's value is rewritten, and the survivor ordering gains a
   new leading term.

   ENTITY DOMAIN
   --------------------------------------------------------------------
     Grain         one row per customer_id
     Business key  customer_id - a lowercase UUID
     Alternate key customer_number - CUST-<year>-<CC>-<seq>, also unique
     Volume        31,350 rows, 26 source columns - the widest table in the
                   layer, loaded from 35 per-country files
     Foreign keys  country_code -> sv_country_master   ZERO orphans
     Referenced by br_sales_header (19,877 of 31,350 customers have sales, 63.4%)

     gender             Male 15,707 / Female 15,643
     customer_segment   Consumer 23,495 / Business 4,648 / Education 3,207
     loyalty_tier       'None' 15,641 / Silver 7,946 / Gold 4,582 / Platinum 3,181
     customer_type      NEW on all 31,350 rows
     is_active          28,823 true / 2,527 false
     registration_date  entirely within 2019
     date_of_birth      1950-04-18 to 2008-04-16

   DIVERGENCE 1: customer_id IS *NOT* UPPER-CASED
   --------------------------------------------------------------------
   Every other table in this layer normalises its business key with
   UPPER(TRIM(...)). Here that would be ACTIVELY WRONG, and it would break the
   fact join.

   customer_id is a 36-character UUID in canonical lowercase form
   (0000b158-784e-441f-86c2-6eee1d908ec8). Verified: all 31,350 values are
   already LOWER(TRIM(...))-identical, and all 36 characters long. The reason the
   generic rule does not apply:
     - Lowercase IS the canonical representation for a UUID (RFC 4122), so
       upper-casing does not normalise the value, it MUTATES it - all 31,350 rows
       would change.
     - br_sales_header.customer_id is ALSO entirely lowercase, and it joins to
       bronze with ZERO orphans. Upper-casing only this side would silently
       produce a total join failure - 77,131 sales rows losing their customer.

   So the treatment is TRIM ONLY. The intent behind the original rule was
   "collapse casing drift so joins cannot silently break"; here the data has no
   casing drift and applying the rule mechanically would CREATE the exact failure
   it exists to prevent. customer_number, by contrast, IS upper-cased - it is a
   structured business code, already uppercase, so the rule applies unchanged.

   DIVERGENCE 2: country_name AND region ARE DROPPED
   --------------------------------------------------------------------
   Bronze carries country_name and region denormalised onto every customer row.
   Both are PROVABLY redundant against the conformed dimension - tested, not
   assumed:
       country_name vs sv_country_master.country_name   0 mismatches / 31,350
       region       vs sv_country_master.region_code    0 mismatches / 31,350
   region's five values (AMER, EMEA, APAC, JAPAN, GREATER_CHINA) are exactly
   sv_region_master's five region codes.

   They are therefore NOT carried into silver. Keeping them would store the same
   fact in two places with no way to enforce agreement: the day a country is
   renamed or moves region, 31,350 customer rows would silently disagree with the
   dimension, and any report would give a different answer depending on which
   table it happened to read. country_code is retained and is sufficient - it
   reaches both attributes through sv_country_master in one join.

   This does not lose data: BRONZE remains the faithful record of what the source
   sent, which is precisely the division of labour between the two layers. Silver
   is where redundancy that cannot be kept consistent gets removed.

   preferred_language is KEPT even though it currently matches
   sv_country_master.primary_language on all 31,350 rows. The distinction is
   semantic, not statistical: a country HAS one primary language, but a customer
   CHOOSES a language, and those legitimately diverge (a French speaker in
   Belgium). Today it carries no independent signal - noted explicitly so nobody
   mistakes it for evidence of real per-customer preference - but the column is a
   genuine customer attribute, so dropping it would discard a real slot rather
   than a duplicated lookup. full_name is kept on the same basis below.

   DIVERGENCE 3: loyalty_tier 'None' IS REWRITTEN TO NULL
   --------------------------------------------------------------------
   15,641 rows (49.9%) hold the four-character STRING 'None', not a NULL. This is
   a loader artefact: a Python None serialised into CSV as text and then read back
   as data.

   It is CLEANSED, not flagged: NULLIF(TRIM(loyalty_tier),'None'). Leaving it
   would mean every downstream consumer must know to write
   `WHERE loyalty_tier <> 'None'`, and the first one that writes `IS NOT NULL`
   instead gets a silently wrong answer - exactly the class of trap silver exists
   to remove. Type-correcting a known sentinel is a cleansing job, which is this
   layer's remit.

   And it is NOT ALSO FLAGGED, because a flag on 49.9% of rows tells nobody
   anything - the same 100%-rule reasoning applied to discontinue_date in V5.1.7.
   The rewrite is recorded here and asserted in validation instead. Note that
   'None' is a legitimate absence of a tier, so NULL is the correct result, not a
   defect: these customers simply are not enrolled.

   DIVERGENCE 4: SURVIVOR ORDERING NOW LEADS WITH updated_at
   --------------------------------------------------------------------
   This is the first table in the layer with an updated_at column, and it differs
   from created_at on ALL 31,350 rows (and is never earlier than it). It is
   therefore the correct primary recency signal and leads the ORDER BY, with
   created_at demoted to a tie-break. Using created_at first would pick the
   oldest-edited version of a re-delivered customer. The deterministic
   (__file_name, __row_number) tail is unchanged.

   ==========================================================================
   PERSONAL DATA - MASKING IS REQUIRED AND IS *NOT* DONE HERE
   ==========================================================================
   NINE columns are personal data, and all nine are 100% populated (no nulls):

       first_name  last_name  full_name  date_of_birth  email
       phone_number  street_address  city  postal_code

   Directly identifying: email, phone_number, full_name, street_address.
   Quasi-identifying: date_of_birth + postal_code + gender, which in combination
   re-identify an individual even with names removed - so postal_code and gender
   must be treated as in-scope, not waved through as harmless geography.

   NO MASKING POLICY IS APPLIED IN THIS SCRIPT, deliberately. Per the
   architectural rule that governance objects live only in GOVERNANCE, masking
   policies belong in GOVERNANCE (V1.x) and are ATTACHED here. This script must
   not create a policy in SALES_DEV. The policies do not exist yet, so this is
   recorded as the layer's outstanding governance gap rather than quietly
   half-solved.

   Two things worth stating for whoever writes those policies:
     - full_name MUST be masked consistently with first_name and last_name. It is
       exactly TRIM(first_name)||' '||TRIM(last_name) on all 31,350 rows
       (verified), so masking the parts while leaving the whole exposed would
       defeat both. It is kept rather than dropped because it is the display field
       and because a masking policy needs a single column to govern.
     - date_of_birth generally wants a generalising policy (year, or an age band)
       rather than a full redaction, since age is analytically useful while an
       exact birth date is not.

   1,051 of these customers are in GDPR countries per
   sv_country_master.gdpr_applicable, which makes this a legal requirement rather
   than a preference - see the minor-registration finding below, which compounds
   it.

   QUALITY CHECKS
   --------------------------------------------------------------------
   Record-level HARD REJECT: null or blank customer_id (per V5.1.2 - reject only
   what is unusable as a key). None exist today.

   THE SERIOUS FINDING - MINORS AT REGISTRATION:
       MINOR_AT_REGISTRATION    under 18 when registered   3,515 rows (11.2%)
       UNDER_13_AT_REGISTRATION under 13 when registered     698 rows
   Minimum age at registration is ELEVEN. 2,360 were under 16 and 1,051 of the
   under-18s are in GDPR countries.

   This is flagged at two thresholds because the thresholds carry different legal
   weight: 13 is the COPPA line in the US, 16 is the GDPR Article 8 default for
   a child's own consent (member states may lower it to 13), and 18 is the
   general contractual-capacity line. A single "is a minor" flag would collapse
   three different obligations into one. Only 360 of the 3,515 are in the
   Education segment, so this is not explained away as school accounts.

   Both are FLAGGED, NOT REJECTED. Deleting the rows would destroy the evidence
   that the account exists, orphan the sales attached to it, and make the
   compliance position harder to establish rather than easier. The correct
   response is a governance decision - consent verification, deletion under
   right-to-erasure, or age-gating at the source - and it needs these rows
   visible to make it. This is the same flag-don't-reject judgement as 'UK' in
   V5.1.4, but here the reason is legal rather than referential.

   Age is computed AT REGISTRATION, not today. That is not a simplification: a
   current-age calculation needs CURRENT_DATE(), and a non-deterministic function
   anywhere in a dynamic table's definition - including inside an IFF - forces
   REFRESH_MODE to FULL (the rule established in V5.1.6). Age at registration is
   the compliance-relevant figure anyway, since consent is given at sign-up.

   PHONE_NOT_E164 - 23,874 rows (76.2%). phone_number is not normalised in any
   consistent way; four distinct shapes coexist:
       digits/spaces/dots  15,924   e.g. '0 2061 8330'
       with letters         6,660   e.g. '(010)034-9469x052'  (extensions)
       leading '+'          6,177   e.g. '+04(4)9130337535'
       leading '('          2,589   e.g. '(+358) 131281138'
   Lengths run 7 to 22 characters.

   NO NORMALISED PHONE COLUMN IS DERIVED, and that is a deliberate refusal. The
   obvious move is REGEXP_REPLACE(phone_number,'[^0-9]','') to get digits - it is
   deterministic and incremental-safe, so it would work mechanically. But 6,660
   of these values carry an EXTENSION ('...9469x052'), and stripping non-digits
   silently concatenates the extension onto the subscriber number, producing a
   plausible-looking phone number that dials the wrong place. A value that is
   visibly messy is safer than one that is invisibly wrong. Correct E.164
   normalisation needs the country dialling code and extension parsing, which is
   a gold-layer or dedicated-utility job, not a REGEXP in a dimension. Flag it,
   surface the shapes, and leave the source value intact.

   Also flagged: INVALID_EMAIL_FORMAT (no '@' - none today), IMPLAUSIBLE_DOB
   (before 1900-01-01, static literal for the same FULL-refresh reason),
   REG_BEFORE_DOB, ACQ_YEAR_MISMATCH (acquisition_year <> YEAR(registration_date)
   - zero today, so the column is pure redundancy and the flag guards it),
   NULL_COUNTRY_CODE (flagged not rejected - a customer with no country still has
   sales), and the usual null checks.

   NO ALLOW-LIST FLAGS on gender, customer_segment or loyalty_tier, per the
   convention set in V5.1.5/V5.1.6: a new segment or tier is a business change,
   not a defect. Nor any flag on customer_type, which is 'NEW' on 100% of rows -
   a uniform value cannot be a defect signal, and the 100% rule from V5.1.7
   applies. Its uniformity is asserted in validation.

   SHARED EMAIL IS A SET-LEVEL ASSERTION, NOT A ROW FLAG
   --------------------------------------------------------------------
   Email is NOT unique: 31,350 rows hold only 30,106 distinct addresses. 1,056
   addresses are shared across 2,300 rows, up to 5 rows each.

   Investigated before deciding, and the result inverts the obvious conclusion:
   1,006 of the 1,056 shared addresses belong to DIFFERENT PEOPLE (different
   first/last name), and 756 span different countries. Testing for genuine
   duplicate persons - same first name, last name AND date of birth - returns
   ZERO groups. So these are NOT duplicate customer records; they are distinct
   individuals colliding on a generated address.

   Two consequences. First, EMAIL MUST NEVER BE USED AS AN IDENTITY KEY or as a
   de-duplication criterion for this table - customer_id and customer_number are
   both unique and are the only safe keys. Second, no row-level flag is raised:
   sharing is a property of a GROUP of rows, not of any single row, and per the
   rule from V5.1.7 anything requiring comparison across rows is asserted in
   validation SQL. Flagging all 2,300 would also imply each is defective, which
   the name evidence contradicts.

   NORMALISATION SUMMARY
   --------------------------------------------------------------------
     customer_id       TRIM only - lowercase UUID, see Divergence 1
     customer_number   UPPER+TRIM - structured business code
     country_code      UPPER+TRIM - join key to sv_country_master
     email             LOWER+TRIM - already all lowercase; LOWER makes the
                       case-insensitivity of email addresses explicit
     names, address, city, state, postal_code, language, segment, tier, gender
                       TRIM only - display values; upper-casing would corrupt
                       them ("McDonald" -> "MCDONALD")
     postal_code       TRIM only, NOT upper-cased. It is tempting to upper-case
                       it as a code, but formats are national and mixed-case
                       matters in some (Dutch '1234 AB'); it is also not a join
                       key here, so there is nothing to protect.

   CONFIGURATION - identical to V5.1.1, mandated by the architecture
   --------------------------------------------------------------------
     TARGET_LAG = DOWNSTREAM, REFRESH_MODE = INCREMENTAL (explicit),
     TRANSIENT, INITIALIZE = ON_CREATE

   Verified after creation: refresh_mode INCREMENTAL, refresh_action INCREMENTAL,
   SUCCEEDED in 1,737 ms, ZERO recommendations, 31,350 rows / 31,350 distinct
   customer_id / 31,350 distinct customer_number, all __bronze_row_count = 1,
   zero orphans against sv_country_master, and 24,713 dq-flagged rows.

   Those 24,713 decompose into EXACTLY three flags and nothing else:
       PHONE_NOT_E164            23,874
       MINOR_AT_REGISTRATION      3,515
       UNDER_13_AT_REGISTRATION     698   (a strict subset of the above)
   in five combinations. Every one is a real finding, not a loading artefact -
   which is why none of the twenty-odd other flags defined below fired.

   Depends on: V2.1.2 (SILVER schema), V4.3.1/V4.3.2 (bronze customer master),
               V5.1.4 (sv_country_master - validation joins only),
               V1.1.4 (MEDALLION_LAYER tag).
   Outstanding: masking policies in GOVERNANCE, to be attached to the nine
               personal-data columns listed above.
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.SILVER.sv_customer_master
  TARGET_LAG   = DOWNSTREAM
  WAREHOUSE    = {{ warehouse }}
  REFRESH_MODE = INCREMENTAL
  INITIALIZE   = ON_CREATE
  COMMENT = 'Silver customer master: de-duplicated on customer_id (lowercase UUID, NOT upper-cased). Contains personal data - masking policies from GOVERNANCE must be attached. Denormalised country_name/region dropped; loyalty_tier sentinel None rewritten to NULL.'
AS
SELECT
    -- Business key. TRIM ONLY - a lowercase UUID is already canonical, and
    -- upper-casing it would mutate all 31,350 values and break the join from
    -- br_sales_header, which is also lowercase. See Divergence 1.
    TRIM(b.customer_id)                                     AS customer_id,
    -- Alternate key. A structured business code, so the usual UPPER+TRIM applies.
    UPPER(TRIM(b.customer_number))                          AS customer_number,
    -- PERSONAL DATA (9 columns, from here to postal_code plus date_of_birth).
    -- Masking policies live in GOVERNANCE and are attached separately.
    TRIM(b.first_name)                                      AS first_name,
    TRIM(b.last_name)                                       AS last_name,
    -- Exactly first||' '||last on all rows. Kept as the display field and as a
    -- single column for a policy to govern - but it MUST be masked in step with
    -- the two parts, or masking either is pointless.
    TRIM(b.full_name)                                       AS full_name,
    TRIM(b.gender)                                          AS gender,
    b.date_of_birth,
    -- Email addresses are case-insensitive; LOWER makes that explicit. Already
    -- all lowercase today. NOT unique - never use as an identity key.
    LOWER(TRIM(b.email))                                    AS email,
    -- Left exactly as sourced. See header: deriving a digits-only variant would
    -- silently fuse extensions onto subscriber numbers.
    TRIM(b.phone_number)                                    AS phone_number,
    TRIM(b.street_address)                                  AS street_address,
    TRIM(b.city)                                            AS city,
    TRIM(b.state_province)                                  AS state_province,
    -- TRIM only: national formats vary and mixed case is meaningful in some.
    TRIM(b.postal_code)                                     AS postal_code,
    -- FK retained; country_name and region are NOT - both are provably redundant
    -- against sv_country_master. See Divergence 2.
    UPPER(TRIM(b.country_code))                             AS country_code,
    TRIM(b.preferred_language)                              AS preferred_language,
    TRIM(b.customer_segment)                                AS customer_segment,
    -- CLEANSED: the literal string 'None' is a loader artefact for absent, so it
    -- becomes a real NULL. See Divergence 3.
    NULLIF(TRIM(b.loyalty_tier), 'None')                    AS loyalty_tier,
    b.registration_date,
    b.acquisition_year,
    TRIM(b.customer_type)                                   AS customer_type,
    b.is_active,
    b.created_at                                            AS source_created_at,
    b.updated_at                                            AS source_updated_at,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.customer_number) IS NULL OR TRIM(b.customer_number)='','MISSING_CUSTOMER_NUMBER',NULL),
        IFF(TRIM(b.first_name) IS NULL OR TRIM(b.first_name)='','MISSING_FIRST_NAME',   NULL),
        IFF(TRIM(b.last_name)  IS NULL OR TRIM(b.last_name)='', 'MISSING_LAST_NAME',    NULL),
        -- Flagged, not rejected: a customer with no country still has sales.
        IFF(b.country_code IS NULL OR TRIM(b.country_code)='',  'NULL_COUNTRY_CODE',    NULL),
        IFF(TRIM(b.email) IS NULL OR TRIM(b.email)='',          'MISSING_EMAIL',        NULL),
        IFF(TRIM(b.email) IS NOT NULL AND TRIM(b.email) NOT LIKE '%@%','INVALID_EMAIL_FORMAT',NULL),
        -- 79.3% of rows. Four incompatible shapes coexist; see header for why no
        -- normalised variant is derived here.
        IFF(TRIM(b.phone_number) IS NOT NULL
            AND TRIM(b.phone_number) NOT LIKE '+%',             'PHONE_NOT_E164',       NULL),
        IFF(TRIM(b.phone_number) IS NULL OR TRIM(b.phone_number)='','MISSING_PHONE',    NULL),
        IFF(b.date_of_birth IS NULL,                            'NULL_DATE_OF_BIRTH',   NULL),
        -- STATIC literal: CURRENT_DATE() would force FULL refresh (V5.1.6).
        IFF(b.date_of_birth < '1900-01-01'::DATE,               'IMPLAUSIBLE_DOB',      NULL),
        IFF(b.registration_date IS NULL,                        'NULL_REGISTRATION_DATE',NULL),
        IFF(b.registration_date < b.date_of_birth,              'REG_BEFORE_DOB',       NULL),
        -- THE COMPLIANCE FINDINGS. Two thresholds because 13 (COPPA) and 18
        -- (contractual capacity) carry different obligations - see header.
        -- Age AT REGISTRATION, deliberately: a current-age calculation needs
        -- CURRENT_DATE() and would force FULL refresh.
        IFF(b.date_of_birth IS NOT NULL AND b.registration_date IS NOT NULL
            AND DATEDIFF('year',b.date_of_birth,b.registration_date) < 18,'MINOR_AT_REGISTRATION',NULL),
        IFF(b.date_of_birth IS NOT NULL AND b.registration_date IS NOT NULL
            AND DATEDIFF('year',b.date_of_birth,b.registration_date) < 13,'UNDER_13_AT_REGISTRATION',NULL),
        -- acquisition_year duplicates YEAR(registration_date); zero mismatches
        -- today, so this flag is what keeps the redundancy honest.
        IFF(b.acquisition_year IS NOT NULL AND b.registration_date IS NOT NULL
            AND b.acquisition_year <> YEAR(b.registration_date),'ACQ_YEAR_MISMATCH',    NULL),
        IFF(TRIM(b.gender) IS NULL OR TRIM(b.gender)='',        'NULL_GENDER',          NULL),
        IFF(TRIM(b.customer_segment) IS NULL OR TRIM(b.customer_segment)='','NULL_CUSTOMER_SEGMENT',NULL),
        IFF(TRIM(b.street_address) IS NULL OR TRIM(b.street_address)='','MISSING_STREET_ADDRESS',NULL),
        IFF(TRIM(b.city) IS NULL OR TRIM(b.city)='',            'MISSING_CITY',         NULL),
        IFF(TRIM(b.postal_code) IS NULL OR TRIM(b.postal_code)='','MISSING_POSTAL_CODE',NULL),
        IFF(b.is_active IS NULL,                                'NULL_IS_ACTIVE',       NULL),
        IFF(b.source_system IS NULL,                            'NULL_SOURCE_SYSTEM',   NULL)
        -- Deliberately absent: no allow-lists on gender/segment/loyalty_tier, no
        -- flag on customer_type (100% 'NEW'), no SHARED_EMAIL flag (a group
        -- property, asserted in validation instead).
    )),','),'')                                             AS dq_issue_flags,
    b.source_system,
    COUNT(*) OVER (PARTITION BY TRIM(b.customer_id))         AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_customer_master b
WHERE b.customer_id IS NOT NULL
  AND TRIM(b.customer_id) <> ''
QUALIFY ROW_NUMBER() OVER (
          -- Must match the projection's TRIM-only treatment exactly.
          PARTITION BY TRIM(b.customer_id)
          -- updated_at leads: it is populated on every row and differs from
          -- created_at on every row, so it is the true recency signal.
          -- See Divergence 4.
          ORDER BY b.updated_at DESC NULLS LAST,
                   b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;

/* Architectural note 6: data-storing objects carry a chargeback tag. */
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_customer_master
  SET TAG {{ governance_database }}.TAGS.MEDALLION_LAYER = 'SILVER';

/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

SHOW DYNAMIC TABLES LIKE 'SV_CUSTOMER_MASTER' IN SCHEMA {{ database }}.SILVER;
-- Expect INCREMENTAL, empty refresh_mode_reason, DOWNSTREAM, ACTIVE.

USE DATABASE {{ database }};
SELECT dt.name, rec.value:"code"::STRING AS rec_code, rec.value:"info"::STRING AS rec_info
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(NAME => '{{ database }}.SILVER.SV_CUSTOMER_MASTER')) dt,
     LATERAL FLATTEN(INPUT => dt.recommendations:recommendations) rec;
-- Expect ZERO rows.

-- Reconciliation, de-dup guarantee on BOTH unique keys, and FK integrity.
SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_customer_master)                          AS bronze_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master)                          AS silver_rows,
       (SELECT COUNT(DISTINCT customer_id) FROM {{ database }}.SILVER.sv_customer_master)       AS silver_ids,
       (SELECT COUNT(DISTINCT customer_number) FROM {{ database }}.SILVER.sv_customer_master)   AS silver_numbers,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master WHERE __bronze_row_count > 1) AS keys_with_dupes,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master WHERE dq_issue_flags IS NOT NULL) AS dq_flagged,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master c
          LEFT JOIN {{ database }}.SILVER.sv_country_master s ON c.country_code=s.country_code
          WHERE s.country_code IS NULL)                                                         AS orphan_country;
-- Recorded: 31350, 31350, 31350, 31350, 0, 24713, 0
-- silver_rows must equal BOTH silver_ids and silver_numbers.

-- DIVERGENCE 1 PROOF: customer_id must remain lowercase, and must still join to
-- the sales fact. If not_lowercase is ever non-zero the UUID has been mutated.
SELECT (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master
          WHERE customer_id <> LOWER(customer_id))                                              AS not_lowercase,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master WHERE LENGTH(customer_id) <> 36) AS not_uuid_length,
       (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_header h
          LEFT JOIN {{ database }}.SILVER.sv_customer_master c ON h.customer_id = c.customer_id
          WHERE c.customer_id IS NULL)                                                          AS sales_rows_orphaned;
-- Recorded: 0, 0, 0. sales_rows_orphaned = 0 is the check that would have caught
-- an UPPER() on the key - it would have returned all 77,131 sales rows.

-- DIVERGENCE 2 PROOF: the dropped columns were fully recoverable from the
-- dimension, which is why dropping them lost nothing.
SELECT COUNT(*)                                   AS customers_resolved,
       COUNT(DISTINCT s.country_name)              AS country_names_recovered,
       COUNT(DISTINCT s.region_code)               AS regions_recovered
FROM {{ database }}.SILVER.sv_customer_master c
JOIN {{ database }}.SILVER.sv_country_master s ON c.country_code = s.country_code;
-- Recorded: 31350, 35, 5 - every customer still reaches its country name and
-- region through one join, with no per-row copy to drift out of date.

-- DIVERGENCE 3 PROOF: no 'None' string survives, and the NULLs are the expected
-- count. loyalty_tier NULL means "not enrolled", not "missing data".
SELECT COUNT(*)                                            AS silver_rows,
       SUM(IFF(loyalty_tier = 'None',1,0))                 AS literal_none_remaining,
       COUNT(*) - COUNT(loyalty_tier)                      AS loyalty_null,
       COUNT(DISTINCT loyalty_tier)                        AS real_tiers
FROM {{ database }}.SILVER.sv_customer_master;
-- Recorded: 31350, 0, 15641, 3 (Silver / Gold / Platinum)

-- THE COMPLIANCE FINDING, broken out by legal threshold. These are the rows that
-- need a governance decision, not a data fix.
SELECT COUNT(*)                                                             AS total,
       SUM(IFF(DATEDIFF('year',date_of_birth,registration_date) < 18,1,0))   AS under_18,
       SUM(IFF(DATEDIFF('year',date_of_birth,registration_date) < 16,1,0))   AS under_16_gdpr_art8,
       SUM(IFF(DATEDIFF('year',date_of_birth,registration_date) < 13,1,0))   AS under_13_coppa,
       MIN(DATEDIFF('year',date_of_birth,registration_date))                 AS youngest_at_registration
FROM {{ database }}.SILVER.sv_customer_master;
-- Recorded: 31350, 3515, 2360, 698, 11

-- The subset that is both a minor AND in a GDPR country - the highest-priority
-- group, since GDPR Article 8 requires parental consent below the member-state
-- age of consent.
SELECT COUNT(*) AS minors_in_gdpr_countries
FROM {{ database }}.SILVER.sv_customer_master c
JOIN {{ database }}.SILVER.sv_country_master s ON c.country_code = s.country_code
WHERE s.gdpr_applicable
  AND DATEDIFF('year',c.date_of_birth,c.registration_date) < 18;
-- Recorded: 1051

-- SHARED EMAIL - the set-level assertion, and the evidence that these are
-- distinct people rather than duplicate records.
WITH shared AS (
  SELECT email,
         COUNT(*)                                                    AS rows_used,
         COUNT(DISTINCT LOWER(first_name || '|' || last_name))        AS distinct_names,
         COUNT(DISTINCT country_code)                                AS distinct_countries
  FROM {{ database }}.SILVER.sv_customer_master
  GROUP BY 1 HAVING COUNT(*) > 1)
SELECT (SELECT COUNT(DISTINCT email) FROM {{ database }}.SILVER.sv_customer_master) AS distinct_emails,
       COUNT(*)                            AS shared_addresses,
       SUM(rows_used)                      AS rows_affected,
       MAX(rows_used)                      AS max_sharing,
       SUM(IFF(distinct_names > 1,1,0))    AS shared_by_different_people,
       SUM(IFF(distinct_countries > 1,1,0)) AS shared_across_countries
FROM shared;
-- Recorded: 30106, 1056, 2300, 5, 1006, 756
-- shared_by_different_people = 1006 of 1056 is why no row is flagged defective.

-- And the decisive test: ZERO genuine duplicate persons. If this is ever
-- non-zero, the de-duplication key needs revisiting - email still would not.
SELECT COUNT(*) AS duplicate_person_groups
FROM (SELECT LOWER(first_name), LOWER(last_name), date_of_birth
      FROM {{ database }}.SILVER.sv_customer_master
      GROUP BY 1,2,3 HAVING COUNT(*) > 1);
-- Recorded: 0

-- Phone-format spread, and confirmation that customer_type is uniform (which is
-- why it carries no flag).
SELECT CASE WHEN phone_number RLIKE '.*[A-Za-z].*' THEN 'has_letters_extension'
            WHEN phone_number LIKE '+%'            THEN 'e164_plus_prefix'
            WHEN phone_number LIKE '(%'            THEN 'parenthesised'
            ELSE 'digits_separators_only' END      AS phone_shape,
       COUNT(*) AS customers
FROM {{ database }}.SILVER.sv_customer_master
GROUP BY 1 ORDER BY 2 DESC;
-- Recorded: digits_separators_only 15924 | has_letters_extension 6660 |
--           e164_plus_prefix 6177 | parenthesised 2589

SELECT customer_type, COUNT(*) AS customers
FROM {{ database }}.SILVER.sv_customer_master GROUP BY 1;
-- Recorded: NEW 31350 - a single value, hence no allow-list flag.

-- Flag distribution: what actually needs attention, and in what volume.
SELECT dq_issue_flags, COUNT(*) AS customers
FROM {{ database }}.SILVER.sv_customer_master
WHERE dq_issue_flags IS NOT NULL
GROUP BY 1 ORDER BY 2 DESC;
-- Recorded, and it is exactly five combinations totalling 24,713:
--   PHONE_NOT_E164                                              21198
--   PHONE_NOT_E164,MINOR_AT_REGISTRATION                         2155
--   MINOR_AT_REGISTRATION                                         662
--   PHONE_NOT_E164,MINOR_AT_REGISTRATION,UNDER_13_AT_REGISTRATION 521
--   MINOR_AT_REGISTRATION,UNDER_13_AT_REGISTRATION                177
-- Note UNDER_13 never appears without MINOR_AT_REGISTRATION, as it must not.
-- Any other flag appearing here is new and needs investigating.

-- Duplicate-key monitoring hook (expect ZERO rows).
SELECT customer_id, customer_number, __bronze_row_count, __file_name, __row_number
FROM {{ database }}.SILVER.sv_customer_master
WHERE __bronze_row_count > 1
ORDER BY customer_id;
