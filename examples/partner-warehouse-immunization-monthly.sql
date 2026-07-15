-- Partner Warehouse Immunization Monthly Reporting
-- =================================================
-- Builds a month-by-month patient status table so BI tools can filter
-- by reporting month and produce trend reports.
--
-- This complements mv_imm_patient_status (current state) with historical data:
--
--   dwh.mv_imm_patient_status       Current-state snapshot — for today's dashboards
--   dwh.fact_imm_patient_monthly    Monthly snapshots — for month-by-month reporting
--
-- Status flags (is_zero_dose, is_fic, is_under_immunised) are calculated AS OF
-- the last day of each reporting month, using each child's age and doses received
-- up to that date. This means a child who was zero-dose in Oct 2023 but later
-- received doses will correctly show as zero-dose in October and vaccinated after.
--
-- Setup (run once):
--   1. Run this file to create the table, procedures, and view.
--   2. Run the initial backfill (see Section 4 below).
--
-- Daily refresh (current month only):
--   CALL dwh.refresh_imm_patient_monthly();
--
-- pg_cron schedule (run at 04:00 daily, after MV refresh):
--   SELECT cron.schedule('refresh-imm-monthly', '0 4 * * *',
--     'CALL dwh.refresh_imm_patient_monthly()');


-- ============================================================================
-- 1. Table
-- ============================================================================

CREATE TABLE IF NOT EXISTS dwh.fact_imm_patient_monthly (
    reporting_month               date        NOT NULL,   -- first day of month
    patient_id                    text        NOT NULL,
    patient_name                  text,
    gender                        text,
    date_of_birth                 date,
    age_days_at_period            integer,               -- age in days at month-end
    age_months_at_period          integer,               -- age in months at month-end
    age_years_at_period           integer,               -- age in full years at month-end
    caregiver_phone               text,
    household_id                  text,
    household_name                text,
    vht_id                        text,
    vht_name                      text,
    -- Location hierarchy (from dim_patients)
    village_name                  text,
    parish_name                   text,
    health_facility_name          text,
    subcounty_name                text,
    county_name                   text,
    district_name                 text,
    region_name                   text,
    reporting_facility_name       text,
    reporting_dhis2_orgunit_uid   text,
    -- Dose dates as of end of reporting month (NULL = not yet received)
    bcg_date                      date,
    hepb0_date                    date,
    opv0_date                     date,
    opv1_date                     date,
    dpt1_date                     date,
    pcv1_date                     date,
    rota1_date                    date,
    opv2_date                     date,
    dpt2_date                     date,
    pcv2_date                     date,
    rota2_date                    date,
    opv3_date                     date,
    dpt3_date                     date,
    pcv3_date                     date,
    ipv1_date                     date,
    ipv2_date                     date,
    mr1_date                      date,
    yf_date                       date,
    mr2_date                      date,
    malaria1_date                 date,
    malaria2_date                 date,
    malaria3_date                 date,
    malaria_booster_date          date,
    hpv1_date                     date,
    hpv2_date                     date,
    -- Dose counts as of end of reporting month
    child_doses_received          integer,
    malaria_doses_received        integer,
    hpv_doses_received            integer,
    -- Status flags as of end of reporting month
    is_zero_dose                  boolean,
    is_fic                        boolean,
    is_under_immunised            boolean,
    PRIMARY KEY (reporting_month, patient_id)
);

CREATE INDEX IF NOT EXISTS idx_fact_imm_monthly_location   ON dwh.fact_imm_patient_monthly (reporting_month, district_name, subcounty_name);
CREATE INDEX IF NOT EXISTS idx_fact_imm_monthly_zero_dose  ON dwh.fact_imm_patient_monthly (reporting_month) WHERE is_zero_dose = true;
CREATE INDEX IF NOT EXISTS idx_fact_imm_monthly_fic        ON dwh.fact_imm_patient_monthly (reporting_month) WHERE is_fic = true;
CREATE INDEX IF NOT EXISTS idx_fact_imm_monthly_under_imm  ON dwh.fact_imm_patient_monthly (reporting_month) WHERE is_under_immunised = true;


-- ============================================================================
-- 2. Rebuild procedure — processes one month at a time from p_from_month
-- ============================================================================
-- Called by both the full backfill and the daily incremental refresh.
-- For each month it DELETEs existing rows then INSERTs fresh ones, so it is
-- safe to re-run for any month at any time.

CREATE OR REPLACE PROCEDURE dwh.rebuild_imm_patient_monthly(
    p_from_month date DEFAULT '2023-09-01'
)
LANGUAGE plpgsql AS $$
DECLARE
    v_month     date;
    v_month_end date;
    v_rows      integer;
BEGIN
    FOR v_month IN
        SELECT m::date
        FROM generate_series(
                 p_from_month,
                 date_trunc('month', CURRENT_DATE)::date,
                 '1 month'::interval
             ) m
    LOOP
        v_month_end := (v_month + INTERVAL '1 month' - INTERVAL '1 day')::date;

        -- Skip months that are already populated (allows safe resume after cancel)
        IF EXISTS (SELECT 1 FROM dwh.fact_imm_patient_monthly WHERE reporting_month = v_month LIMIT 1)
           AND v_month < date_trunc('month', CURRENT_DATE)::date THEN
            RAISE NOTICE 'Skipping % (already populated)', v_month;
            CONTINUE;
        END IF;

        RAISE NOTICE 'Processing % (month-end: %)', v_month, v_month_end;

        DELETE FROM dwh.fact_imm_patient_monthly WHERE reporting_month = v_month;

        WITH dose_src AS (
            -- Pre-cast and filter doses up to month-end once; reused for all antigens
            SELECT
                patient_id,
                administered_date::date                  AS dose_date,
                REPLACE(vaccine_name, '_', '-')          AS n_vaccine_name
            FROM dwh.fact_opensrp_immunizations
            WHERE administered_date IS NOT NULL
              AND administered_date <> ''
              AND vaccine_name      IS NOT NULL
              AND vaccine_name      <> ''
              AND administered_date::date <= v_month_end
        ),
        pr AS (
            -- Deduplicate practitioners — dim_opensrp_practitioner has multiple rows per ID
            SELECT DISTINCT ON (practitioner_id)
                practitioner_id,
                practitioner_name
            FROM dwh.dim_opensrp_practitioner
            ORDER BY practitioner_id
        ),
        doses AS (
            SELECT
                patient_id,

                -- Birth doses
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'BCG%')                                                    AS bcg_date,
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'HepB 0%')                                                 AS hepb0_date,
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'Polio 0%')                                                AS opv0_date,
                -- 6-week doses
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'Polio 1%')                                                AS opv1_date,
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'DPT-HepB Hib 1%')                                        AS dpt1_date,
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'PCV 1%')                                                  AS pcv1_date,
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'Rota 1%')                                                 AS rota1_date,
                -- 10-week doses
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'Polio 2%')                                                AS opv2_date,
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'DPT-HepB Hib 2%')                                        AS dpt2_date,
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'PCV 2%')                                                  AS pcv2_date,
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'Rota 2%')                                                 AS rota2_date,
                -- 14-week doses
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'Polio 3%')                                                AS opv3_date,
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'DPT-HepB Hib 3%')                                        AS dpt3_date,
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'PCV 3%')                                                  AS pcv3_date,
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'IPV 1%')                                                  AS ipv1_date,
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'IPV 2%')                                                  AS ipv2_date,
                -- 9-month doses
                MIN(dose_date) FILTER (WHERE (n_vaccine_name ILIKE 'Measles%Rubella 1%'
                                           OR n_vaccine_name ILIKE 'Measles-Rubella%1%'))                                    AS mr1_date,
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'Yellow Fever%')                                           AS yf_date,
                -- 15-month dose
                MIN(dose_date) FILTER (WHERE (n_vaccine_name ILIKE 'Measles%Rubella 2%'
                                           OR n_vaccine_name ILIKE 'Measles-Rubella%2%'))                                    AS mr2_date,
                -- Malaria vaccine
                MIN(dose_date) FILTER (WHERE (n_vaccine_name ILIKE 'Malaria%Dose 1%'
                                           OR n_vaccine_name ILIKE 'Malaria%1%'))                                            AS malaria1_date,
                MIN(dose_date) FILTER (WHERE (n_vaccine_name ILIKE 'Malaria%Dose 2%'
                                           OR n_vaccine_name ILIKE 'Malaria%2%'))                                            AS malaria2_date,
                MIN(dose_date) FILTER (WHERE (n_vaccine_name ILIKE 'Malaria%Dose 3%'
                                           OR n_vaccine_name ILIKE 'Malaria%3%'))                                            AS malaria3_date,
                MIN(dose_date) FILTER (WHERE (n_vaccine_name ILIKE 'Malaria%Dose 4%'
                                           OR n_vaccine_name ILIKE 'Malaria%4%'))                                            AS malaria_booster_date,
                -- HPV vaccine
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'HPV%1%')                                                  AS hpv1_date,
                MIN(dose_date) FILTER (WHERE n_vaccine_name ILIKE 'HPV%2%')                                                  AS hpv2_date,

                -- Dose counts
                COUNT(*) FILTER (WHERE n_vaccine_name ILIKE ANY(ARRAY[
                    'BCG%','HepB 0%','Polio%','DPT-HepB Hib%',
                    'PCV%','Rota%','IPV%','Measles%Rubella%','Yellow Fever%'
                ]))                                                                                                           AS child_doses_received,
                COUNT(*) FILTER (WHERE n_vaccine_name ILIKE 'Malaria%')                                                      AS malaria_doses_received,
                COUNT(*) FILTER (WHERE n_vaccine_name ILIKE 'HPV%')                                                          AS hpv_doses_received

            FROM dose_src
            GROUP BY patient_id
        )
        INSERT INTO dwh.fact_imm_patient_monthly
        SELECT
            v_month                                                                             AS reporting_month,
            p.patient_id,
            p.patient_name,
            p.gender,
            p.birth_date                                                                        AS date_of_birth,
            (v_month_end - p.birth_date)::integer                                               AS age_days_at_period,
            (EXTRACT(YEAR  FROM AGE(v_month_end, p.birth_date)) * 12
             + EXTRACT(MONTH FROM AGE(v_month_end, p.birth_date)))::integer                     AS age_months_at_period,
            EXTRACT(YEAR FROM AGE(v_month_end, p.birth_date))::integer                          AS age_years_at_period,
            p.phone_number                                                                      AS caregiver_phone,
            p.household_id,
            p.household_name,
            pr.practitioner_id                                                                  AS vht_id,
            pr.practitioner_name                                                                AS vht_name,
            -- Location
            p.village_name,
            p.parish_name,
            p.health_facility_name,
            p.subcounty_name,
            p.county_name,
            p.district_name,
            p.region_name,
            p.reporting_facility_name,
            p.reporting_dhis2_orgunit_uid,
            -- Dose dates (NULL if not received by month-end)
            d.bcg_date,
            d.hepb0_date,
            d.opv0_date,
            d.opv1_date,
            d.dpt1_date,
            d.pcv1_date,
            d.rota1_date,
            d.opv2_date,
            d.dpt2_date,
            d.pcv2_date,
            d.rota2_date,
            d.opv3_date,
            d.dpt3_date,
            d.pcv3_date,
            d.ipv1_date,
            d.ipv2_date,
            d.mr1_date,
            d.yf_date,
            d.mr2_date,
            d.malaria1_date,
            d.malaria2_date,
            d.malaria3_date,
            d.malaria_booster_date,
            d.hpv1_date,
            d.hpv2_date,
            -- Dose counts
            COALESCE(d.child_doses_received,   0)                                               AS child_doses_received,
            COALESCE(d.malaria_doses_received, 0)                                               AS malaria_doses_received,
            COALESCE(d.hpv_doses_received,     0)                                               AS hpv_doses_received,
            -- Status flags calculated as of v_month_end
            (   COALESCE(d.child_doses_received, 0) = 0
            AND (v_month_end - p.birth_date) <= 730
            )                                                                                   AS is_zero_dose,

            (   d.bcg_date   IS NOT NULL
            AND d.hepb0_date IS NOT NULL
            AND d.opv0_date  IS NOT NULL
            AND d.opv1_date  IS NOT NULL
            AND d.opv2_date  IS NOT NULL
            AND d.opv3_date  IS NOT NULL
            AND d.dpt1_date  IS NOT NULL
            AND d.dpt2_date  IS NOT NULL
            AND d.dpt3_date  IS NOT NULL
            AND d.pcv1_date  IS NOT NULL
            AND d.pcv2_date  IS NOT NULL
            AND d.pcv3_date  IS NOT NULL
            AND d.rota1_date IS NOT NULL
            AND d.rota2_date IS NOT NULL
            AND d.ipv1_date  IS NOT NULL
            AND d.mr1_date   IS NOT NULL
            AND d.yf_date    IS NOT NULL
            AND d.mr2_date   IS NOT NULL
            )                                                                                   AS is_fic,

            (   COALESCE(d.child_doses_received, 0) > 0
            AND NOT (
                    d.bcg_date   IS NOT NULL AND d.hepb0_date IS NOT NULL
                AND d.opv0_date  IS NOT NULL AND d.opv1_date  IS NOT NULL
                AND d.opv2_date  IS NOT NULL AND d.opv3_date  IS NOT NULL
                AND d.dpt1_date  IS NOT NULL AND d.dpt2_date  IS NOT NULL
                AND d.dpt3_date  IS NOT NULL AND d.pcv1_date  IS NOT NULL
                AND d.pcv2_date  IS NOT NULL AND d.pcv3_date  IS NOT NULL
                AND d.rota1_date IS NOT NULL AND d.rota2_date IS NOT NULL
                AND d.ipv1_date  IS NOT NULL AND d.mr1_date   IS NOT NULL
                AND d.yf_date    IS NOT NULL AND d.mr2_date   IS NOT NULL
            )
            AND (v_month_end - p.birth_date) <= 1825
            )                                                                                   AS is_under_immunised

        FROM dwh.dim_patients p
        LEFT JOIN doses d  ON d.patient_id       = p.patient_id
        LEFT JOIN pr       ON pr.practitioner_id = p.practitioner_id
        WHERE p.birth_date IS NOT NULL
          AND p.birth_date <= v_month_end
          AND p.birth_date >= v_month_end - INTERVAL '5 years'
          AND (p.is_deceased IS NULL OR p.is_deceased = false);

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        RAISE NOTICE '  → % rows', v_rows;

        COMMIT;  -- commit each month independently so progress is preserved on cancel

    END LOOP;

    RAISE NOTICE 'rebuild_imm_patient_monthly complete.';
END; $$;


-- ============================================================================
-- 3. Daily refresh procedure (current month only)
-- ============================================================================

CREATE OR REPLACE PROCEDURE dwh.refresh_imm_patient_monthly()
LANGUAGE plpgsql AS $$
BEGIN
    CALL dwh.rebuild_imm_patient_monthly(date_trunc('month', CURRENT_DATE)::date);
END; $$;


-- ============================================================================
-- 4. Initial backfill — run ONCE after creating the table
-- ============================================================================
-- Processes every month from 2023-09-01 to the current month.
-- Expect 15-30 minutes depending on server performance (progress shown via NOTICE).
-- Run from psql in a terminal, not pgAdmin, to keep the connection alive:
--
--   psql "host=109.123.243.162 dbname=opensrp user=opensrp" \
--     -c "CALL dwh.rebuild_imm_patient_monthly();"
--
-- To rebuild a specific range (e.g. re-run from Jan 2025 only):
--   CALL dwh.rebuild_imm_patient_monthly('2025-01-01');

-- CALL dwh.rebuild_imm_patient_monthly();   -- uncomment to run


-- ============================================================================
-- 5. v_imm_location_monthly — location summary by month
-- ============================================================================

CREATE OR REPLACE VIEW dwh.v_imm_location_monthly AS
SELECT
    reporting_month,
    district_name,
    subcounty_name,
    parish_name,
    health_facility_name,
    village_name,

    COUNT(*)                                                                      AS registered_children,
    COUNT(*) FILTER (WHERE age_days_at_period BETWEEN 0 AND 730)                  AS eligible_0_24m,
    COUNT(*) FILTER (WHERE age_days_at_period BETWEEN 0 AND 1825)                 AS eligible_under5,

    COUNT(*) FILTER (WHERE is_zero_dose)                                           AS zero_dose_count,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_zero_dose)
        / NULLIF(COUNT(*) FILTER (WHERE age_days_at_period BETWEEN 0 AND 730), 0), 1
    )                                                                              AS zero_dose_pct,

    COUNT(*) FILTER (WHERE is_under_immunised)                                     AS under_immunised_count,

    COUNT(*) FILTER (WHERE is_fic)                                                 AS fic_count,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_fic)
        / NULLIF(COUNT(*) FILTER (WHERE age_days_at_period >= 456), 0), 1
    )                                                                              AS fic_coverage_pct,

    ROUND(100.0 * COUNT(*) FILTER (WHERE dpt1_date IS NOT NULL)
        / NULLIF(COUNT(*), 0), 1)                                                 AS dpt1_coverage_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE dpt3_date IS NOT NULL)
        / NULLIF(COUNT(*), 0), 1)                                                 AS dpt3_coverage_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE mr1_date IS NOT NULL)
        / NULLIF(COUNT(*) FILTER (WHERE age_days_at_period >= 270), 0), 1)        AS mr1_coverage_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE mr2_date IS NOT NULL)
        / NULLIF(COUNT(*) FILTER (WHERE age_days_at_period >= 456), 0), 1)        AS mr2_coverage_pct,

    COUNT(*) FILTER (WHERE malaria1_date IS NOT NULL)                              AS malaria_dose1_count,
    COUNT(*) FILTER (WHERE malaria_booster_date IS NOT NULL)                       AS malaria_complete_count,

    COUNT(*) FILTER (WHERE hpv1_date IS NOT NULL)                                  AS hpv_dose1_count,
    COUNT(*) FILTER (WHERE hpv2_date IS NOT NULL)                                  AS hpv_dose2_count

FROM dwh.fact_imm_patient_monthly
GROUP BY reporting_month, district_name, subcounty_name, parish_name, health_facility_name, village_name;


-- ============================================================================
-- 6. Example queries — copy and run individually in your BI tool or psql
--    (commented out so re-running this file does not dump output)
-- ============================================================================

/*

-- District-level summary for a single month
SELECT
    district_name,
    registered_children,
    eligible_0_24m,
    zero_dose_count,
    zero_dose_pct,
    under_immunised_count,
    fic_count,
    fic_coverage_pct,
    dpt1_coverage_pct,
    mr1_coverage_pct
FROM dwh.v_imm_location_monthly
WHERE reporting_month  = '2025-06-01'   -- replace with target month
  AND subcounty_name   IS NULL
  AND parish_name      IS NULL          -- district-level rows only
ORDER BY zero_dose_count DESC;


-- Monthly zero-dose trend for one district (all months)
SELECT
    reporting_month,
    eligible_0_24m,
    zero_dose_count,
    zero_dose_pct
FROM dwh.v_imm_location_monthly
WHERE district_name  = 'Kampala'
  AND subcounty_name IS NULL
  AND parish_name    IS NULL
ORDER BY reporting_month;


-- Subcounty breakdown for a given month and district
SELECT
    subcounty_name,
    registered_children,
    zero_dose_count,
    zero_dose_pct,
    fic_count,
    fic_coverage_pct
FROM dwh.v_imm_location_monthly
WHERE reporting_month = '2025-06-01'   -- replace with target month
  AND district_name   = 'Mukono District'
  AND parish_name     IS NULL
ORDER BY zero_dose_count DESC;


-- Patient line list for a specific month and location
SELECT
    patient_name,
    gender,
    date_of_birth,
    age_months_at_period,
    caregiver_phone,
    vht_name,
    village_name,
    district_name
FROM dwh.fact_imm_patient_monthly
WHERE reporting_month    = '2025-06-01'   -- replace with target month
  AND is_zero_dose       = true
  AND district_name      = 'Kampala'
ORDER BY age_months_at_period DESC;


-- How many months of data are loaded
SELECT
    reporting_month,
    COUNT(*) AS patient_rows
FROM dwh.fact_imm_patient_monthly
GROUP BY reporting_month
ORDER BY reporting_month;

*/
