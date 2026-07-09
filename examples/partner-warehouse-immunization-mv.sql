-- Partner Warehouse Immunization Materialized Views
-- ===================================================
-- Builds from native partner warehouse tables. Does NOT depend on
-- fact_immunization_status or agg_immunization_monthly.
--
-- Tables used:
--   dwh.dim_opensrp_patient               Patient demographics (Type 2 SCD — filter is_current_flag = 'true')
--   dwh.fact_opensrp_immunizations        Dose records
--   dwh.dim_opensrp_locations_mapping     Location hierarchy (join: location_id = community_location_uuid)
--   dwh.dim_opensrp_practitioner          VHT name (join: practitioner_id = patient.practitioner)
--
-- Outputs:
--   dwh.mv_imm_patient_status       One row per registered child. Wide format — one column per dose date.
--   dwh.v_imm_location_summary      View: aggregates mv_imm_patient_status by location level.
--
-- Zero-dose definition:
--   No child_immunization doses received AND age at snapshot ≤ 24 months (730 days).
--   Last scheduled dose is MR2 at 18 months (540 days); 24 months gives a 6-month catch-up buffer.
--   Malaria and HPV doses do NOT count toward zero-dose status.
--
-- FIC (Fully Immunised Child) definition — Uganda EPI schedule (19 doses):
--   BCG, HepB0, OPV0-3, DPT1-3, PCV1-3, Rota1-2, IPV1, IPV2, MR1, Yellow Fever, MR2
--   A child is FIC only when all 18 columns are non-null.
--
-- Refresh command:
--   REFRESH MATERIALIZED VIEW CONCURRENTLY dwh.mv_imm_patient_status;
--
-- Recommended pg_cron schedule (run at 03:00 daily):
--   SELECT cron.schedule('refresh-mv-imm', '0 3 * * *',
--     'REFRESH MATERIALIZED VIEW CONCURRENTLY dwh.mv_imm_patient_status');


-- ============================================================================
-- 1. mv_imm_patient_status
-- ============================================================================

DROP MATERIALIZED VIEW IF EXISTS dwh.mv_imm_patient_status;

CREATE MATERIALIZED VIEW dwh.mv_imm_patient_status AS

-- NOTE: fact_opensrp_immunizations has two populations of records:
--   1. Correctly ETL-mapped rows: programme = 'child_immunization' / 'malaria_vaccine' / 'hpv_vaccine',
--      antigen_group populated.
--   2. programme = 'unknown', antigen_group = NULL — valid doses where the ETL mapping failed.
--      These account for roughly half the records and must be included.
-- Solution: match entirely on REPLACE(vaccine_name, '_', '-') ILIKE patterns so both
-- populations are captured regardless of programme or antigen_group classification.
-- MIN() naturally resolves duplicates (same child, same dose in both populations).

WITH doses AS (

    SELECT
        patient_id,

        -- ── Birth doses ───────────────────────────────────────────────────
        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'BCG%'
        )                                                       AS bcg_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'HepB 0%'
        )                                                       AS hepb0_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'Polio 0%'
        )                                                       AS opv0_date,

        -- ── 6-week doses ──────────────────────────────────────────────────
        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'Polio 1%'
        )                                                       AS opv1_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'DPT-HepB Hib 1%'
        )                                                       AS dpt1_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'PCV 1%'
        )                                                       AS pcv1_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'Rota 1%'
        )                                                       AS rota1_date,

        -- ── 10-week doses ─────────────────────────────────────────────────
        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'Polio 2%'
        )                                                       AS opv2_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'DPT-HepB Hib 2%'
        )                                                       AS dpt2_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'PCV 2%'
        )                                                       AS pcv2_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'Rota 2%'
        )                                                       AS rota2_date,

        -- ── 14-week doses ─────────────────────────────────────────────────
        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'Polio 3%'
        )                                                       AS opv3_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'DPT-HepB Hib 3%'
        )                                                       AS dpt3_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'PCV 3%'
        )                                                       AS pcv3_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'IPV 1%'
        )                                                       AS ipv1_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'IPV 2%'
        )                                                       AS ipv2_date,

        -- ── 9-month doses ─────────────────────────────────────────────────
        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'Measles%Rubella 1%'
               OR n_vaccine_name ILIKE 'Measles-Rubella%1%'
        )                                                       AS mr1_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'Yellow Fever%'
        )                                                       AS yf_date,

        -- ── 15-month dose ─────────────────────────────────────────────────
        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'Measles%Rubella 2%'
               OR n_vaccine_name ILIKE 'Measles-Rubella%2%'
        )                                                       AS mr2_date,

        -- ── Malaria vaccine ───────────────────────────────────────────────
        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'Malaria%Dose 1%'
               OR n_vaccine_name ILIKE 'Malaria%1%'
        )                                                       AS malaria1_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'Malaria%Dose 2%'
               OR n_vaccine_name ILIKE 'Malaria%2%'
        )                                                       AS malaria2_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'Malaria%Dose 3%'
               OR n_vaccine_name ILIKE 'Malaria%3%'
        )                                                       AS malaria3_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'Malaria%Dose 4%'
               OR n_vaccine_name ILIKE 'Malaria%4%'
        )                                                       AS malaria_booster_date,

        -- ── HPV vaccine ───────────────────────────────────────────────────
        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'HPV%1%'
        )                                                       AS hpv1_date,

        MIN(administered_date::date) FILTER (
            WHERE n_vaccine_name ILIKE 'HPV%2%'
        )                                                       AS hpv2_date,

        -- ── Dose counts (based on vaccine name, not programme) ─────────────
        COUNT(*) FILTER (
            WHERE n_vaccine_name ILIKE ANY(ARRAY[
                'BCG%','HepB 0%','Polio%','DPT-HepB Hib%',
                'PCV%','Rota%','IPV%','Measles%Rubella%',
                'Yellow Fever%'
            ])
        )                                                       AS child_doses_received,

        COUNT(*) FILTER (
            WHERE n_vaccine_name ILIKE 'Malaria%'
        )                                                       AS malaria_doses_received,

        COUNT(*) FILTER (
            WHERE n_vaccine_name ILIKE 'HPV%'
        )                                                       AS hpv_doses_received

    FROM (
        SELECT
            patient_id,
            administered_date,
            REPLACE(vaccine_name, '_', '-') AS n_vaccine_name
        FROM dwh.fact_opensrp_immunizations
        WHERE administered_date IS NOT NULL
          AND administered_date <> ''
          AND vaccine_name      IS NOT NULL
          AND vaccine_name      <> ''
    ) src
    GROUP BY patient_id
)

SELECT

    -- ── Patient identity ──────────────────────────────────────────────────
    p.patient_id,
    p.patient_name,
    p.sex                                                       AS gender,
    p.date_of_birth,

    (CURRENT_DATE - p.date_of_birth::date)                     AS age_days,

    (EXTRACT(YEAR  FROM AGE(CURRENT_DATE, p.date_of_birth::date)) * 12
     + EXTRACT(MONTH FROM AGE(CURRENT_DATE, p.date_of_birth::date))
    )::int                                                      AS age_months,

    EXTRACT(YEAR FROM AGE(CURRENT_DATE, p.date_of_birth::date))::int
                                                                AS age_years,

    -- ── Contact ───────────────────────────────────────────────────────────
    p.phone_number                                              AS caregiver_phone,
    p.is_active,

    -- ── VHT info ─────────────────────────────────────────────────────────
    pr.practitioner_id                                          AS vht_id,
    pr.practitioner_name                                        AS vht_name,
    NULL::text                                                  AS vht_phone,

    -- ── Location hierarchy ────────────────────────────────────────────────
    -- Joined via community_location_uuid → dim_opensrp_locations_mapping.location_id
    lm.village_name,
    lm.parish_name,
    lm.health_facility_name,
    lm.subcounty_name,
    lm.county_name,
    lm.district_name,
    lm.region_name,
    lm.reporting_facility_name,
    lm.reporting_dhis2_orgunit_uid,

    -- ── Child immunization dose dates (NULL = not yet received) ───────────
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

    -- ── Malaria vaccine dose dates ────────────────────────────────────────
    d.malaria1_date,
    d.malaria2_date,
    d.malaria3_date,
    d.malaria_booster_date,

    -- ── HPV vaccine dose dates ────────────────────────────────────────────
    d.hpv1_date,
    d.hpv2_date,

    -- ── Programme dose counts ─────────────────────────────────────────────
    COALESCE(d.child_doses_received,   0)                       AS child_doses_received,
    COALESCE(d.malaria_doses_received, 0)                       AS malaria_doses_received,
    COALESCE(d.hpv_doses_received,     0)                       AS hpv_doses_received,

    -- ── Status flags ──────────────────────────────────────────────────────
    --
    -- is_zero_dose: no child_immunization doses AND age ≤ 24 months (730 days)
    (   COALESCE(d.child_doses_received, 0) = 0
    AND (CURRENT_DATE - p.date_of_birth::date) <= 730
    )                                                           AS is_zero_dose,

    -- is_fic: all 18 Uganda EPI schedule doses received
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
    )                                                           AS is_fic,

    -- is_under_immunised: ≥1 child dose but not FIC, age ≤ 60 months
    (   COALESCE(d.child_doses_received, 0) > 0
    AND NOT (
            d.bcg_date IS NOT NULL AND d.hepb0_date IS NOT NULL
        AND d.opv0_date IS NOT NULL AND d.opv1_date IS NOT NULL
        AND d.opv2_date IS NOT NULL AND d.opv3_date IS NOT NULL
        AND d.dpt1_date IS NOT NULL AND d.dpt2_date IS NOT NULL
        AND d.dpt3_date IS NOT NULL AND d.pcv1_date IS NOT NULL
        AND d.pcv2_date IS NOT NULL AND d.pcv3_date IS NOT NULL
        AND d.rota1_date IS NOT NULL AND d.rota2_date IS NOT NULL
        AND d.ipv1_date IS NOT NULL AND d.mr1_date IS NOT NULL
        AND d.yf_date IS NOT NULL AND d.mr2_date IS NOT NULL
    )
    AND (CURRENT_DATE - p.date_of_birth::date) <= 1825         -- ≤ 60 months
    )                                                           AS is_under_immunised,

    -- ── Metadata ──────────────────────────────────────────────────────────
    CURRENT_DATE                                                AS snapshot_date

FROM dwh.dim_opensrp_patient p

LEFT JOIN doses d
       ON d.patient_id = p.patient_id

LEFT JOIN dwh.dim_opensrp_locations_mapping lm
       ON lm.location_id = p.community_location_uuid

LEFT JOIN dwh.dim_opensrp_practitioner pr
       ON pr.practitioner_id = p.practitioner
      AND pr.is_current_flag = 'true'

WHERE p.date_of_birth IS NOT NULL
  AND p.date_of_birth <> ''
  AND p.date_of_birth::date BETWEEN CURRENT_DATE - INTERVAL '5 years' AND CURRENT_DATE
  AND (p.deceased IS NULL OR p.deceased = 'false')
  AND p.is_current_flag = 'true'
;

-- Indexes
CREATE UNIQUE INDEX ON dwh.mv_imm_patient_status (patient_id);
CREATE INDEX ON dwh.mv_imm_patient_status (district_name, subcounty_name);
CREATE INDEX ON dwh.mv_imm_patient_status (is_zero_dose)       WHERE is_zero_dose = true;
CREATE INDEX ON dwh.mv_imm_patient_status (is_under_immunised) WHERE is_under_immunised = true;
CREATE INDEX ON dwh.mv_imm_patient_status (is_fic)             WHERE is_fic = true;


-- ============================================================================
-- 2. v_imm_location_summary
-- ============================================================================
-- Plain view — aggregates mv_imm_patient_status by location.
-- Automatically reflects the latest MV refresh.
-- Filter by district_name, subcounty_name, parish_name, or village_name in queries.
-- For national level: remove all location filters.

CREATE OR REPLACE VIEW dwh.v_imm_location_summary AS
SELECT

    snapshot_date,
    district_name,
    subcounty_name,
    parish_name,
    health_facility_name,
    village_name,

    -- ── Registered children ───────────────────────────────────────────────
    COUNT(*)                                                                    AS registered_children,

    -- ── Eligible cohorts ──────────────────────────────────────────────────
    COUNT(*) FILTER (WHERE age_days BETWEEN 0 AND 730)                         AS eligible_0_24m,
    COUNT(*) FILTER (WHERE age_days BETWEEN 0 AND 1825)                        AS eligible_under5,

    -- ── Zero-dose (0–24 months, child_immunization only) ─────────────────
    COUNT(*) FILTER (WHERE is_zero_dose)                                        AS zero_dose_count,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_zero_dose)
        / NULLIF(COUNT(*) FILTER (WHERE age_days BETWEEN 0 AND 730), 0), 1
    )                                                                           AS zero_dose_pct,

    -- ── Under-immunised (0–60 months, has ≥1 dose but not FIC) ───────────
    COUNT(*) FILTER (WHERE is_under_immunised)                                  AS under_immunised_count,

    -- ── Fully immunised (FIC) ─────────────────────────────────────────────
    COUNT(*) FILTER (WHERE is_fic)                                              AS fic_count,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_fic)
        / NULLIF(COUNT(*) FILTER (WHERE age_days >= 456), 0), 1                -- ≥15 months
    )                                                                           AS fic_coverage_pct,

    -- ── Antigen coverage (% of all registered under-5 who received dose) ──
    ROUND(100.0 * COUNT(*) FILTER (WHERE dpt1_date IS NOT NULL)
        / NULLIF(COUNT(*), 0), 1)                                               AS dpt1_coverage_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE dpt3_date IS NOT NULL)
        / NULLIF(COUNT(*), 0), 1)                                               AS dpt3_coverage_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE mr1_date IS NOT NULL)
        / NULLIF(COUNT(*) FILTER (WHERE age_days >= 270), 0), 1)               AS mr1_coverage_pct,  -- ≥9 months
    ROUND(100.0 * COUNT(*) FILTER (WHERE mr2_date IS NOT NULL)
        / NULLIF(COUNT(*) FILTER (WHERE age_days >= 456), 0), 1)               AS mr2_coverage_pct,  -- ≥15 months

    -- ── Malaria vaccine ───────────────────────────────────────────────────
    COUNT(*) FILTER (WHERE malaria1_date IS NOT NULL)                           AS malaria_dose1_count,
    COUNT(*) FILTER (WHERE malaria_booster_date IS NOT NULL)                    AS malaria_complete_count,

    -- ── HPV vaccine ───────────────────────────────────────────────────────
    COUNT(*) FILTER (WHERE hpv1_date IS NOT NULL)                               AS hpv_dose1_count,
    COUNT(*) FILTER (WHERE hpv2_date IS NOT NULL)                               AS hpv_dose2_count

FROM dwh.mv_imm_patient_status
GROUP BY snapshot_date, district_name, subcounty_name, parish_name, health_facility_name, village_name
;


-- ============================================================================
-- 3. Example report queries against the materialized view
-- ============================================================================


-- Zero-dose line list — current snapshot, one location
SELECT
    patient_name,
    gender,
    date_of_birth,
    age_months,
    caregiver_phone,
    vht_name,
    village_name,
    parish_name
FROM dwh.mv_imm_patient_status
WHERE is_zero_dose    = true
  AND subcounty_name  = 'Kawempe Division'    -- replace with target location
ORDER BY age_months DESC;


-- Under-immunised line list with missing doses summary
SELECT
    patient_name,
    gender,
    age_months,
    caregiver_phone,
    vht_name,
    village_name,
    -- Which doses are still missing
    CONCAT_WS(', ',
        CASE WHEN bcg_date   IS NULL THEN 'BCG'         END,
        CASE WHEN hepb0_date IS NULL THEN 'HepB Birth'  END,
        CASE WHEN opv0_date  IS NULL THEN 'OPV0'        END,
        CASE WHEN dpt1_date  IS NULL THEN 'DPT1'        END,
        CASE WHEN dpt2_date  IS NULL THEN 'DPT2'        END,
        CASE WHEN dpt3_date  IS NULL THEN 'DPT3'        END,
        CASE WHEN pcv1_date  IS NULL THEN 'PCV1'        END,
        CASE WHEN pcv2_date  IS NULL THEN 'PCV2'        END,
        CASE WHEN pcv3_date  IS NULL THEN 'PCV3'        END,
        CASE WHEN rota1_date IS NULL THEN 'Rota1'       END,
        CASE WHEN rota2_date IS NULL THEN 'Rota2'       END,
        CASE WHEN ipv1_date  IS NULL THEN 'IPV'          END,
        CASE WHEN mr1_date   IS NULL AND age_months >= 9  THEN 'MR1' END,
        CASE WHEN yf_date    IS NULL AND age_months >= 9  THEN 'YF'  END,
        CASE WHEN mr2_date   IS NULL AND age_months >= 15 THEN 'MR2' END
    )                                                       AS missing_doses
FROM dwh.mv_imm_patient_status
WHERE is_under_immunised = true
  AND district_name      = 'Kampala'          -- replace with target location
ORDER BY age_months DESC;


-- VHT caseload — zero-dose and under-immunised per VHT
SELECT
    vht_name,
    village_name,
    COUNT(*)                                   AS eligible_children,
    COUNT(*) FILTER (WHERE is_zero_dose)       AS zero_dose_count,
    COUNT(*) FILTER (WHERE is_under_immunised) AS under_immunised_count,
    COUNT(*) FILTER (WHERE is_fic)             AS fic_count
FROM dwh.mv_imm_patient_status
WHERE subcounty_name = 'Kawempe Division'      -- replace with target location
GROUP BY vht_name, village_name
ORDER BY zero_dose_count DESC;


-- Location summary — district level KPIs
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
FROM dwh.v_imm_location_summary
WHERE subcounty_name IS NULL    -- district-level rows have no subcounty drill-down
GROUP BY district_name, registered_children, eligible_0_24m, zero_dose_count,
         zero_dose_pct, under_immunised_count, fic_count, fic_coverage_pct,
         dpt1_coverage_pct, mr1_coverage_pct
ORDER BY zero_dose_count DESC;
