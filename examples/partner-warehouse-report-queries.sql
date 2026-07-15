-- ============================================================
-- eCHIS Immunization Report Queries — Partner Warehouse
-- ============================================================
-- Sources:
--   dwh.fact_imm_patient_monthly   One row per child × reporting month.
--                                  Use for patient-level line lists and
--                                  custom aggregations.
--   dwh.v_imm_location_monthly     Pre-aggregated by location × month.
--                                  Use for summary KPI tables.
--
-- HOW TO FILTER BY MONTH:
--   Add: WHERE reporting_month = '2025-06-01'   (first day of the month)
--   Available months: 2023-09-01 → current month
--
-- HOW TO FILTER BY LOCATION:
--   National        — remove location filter entirely
--   District        — AND district_name         = 'Kampala'
--   Subcounty       — AND subcounty_name        = 'Kawempe Division'
--   Health Facility — AND health_facility_name  = 'Kawempe HC IV'
--   Village         — AND village_name          = 'Bwaise I'
--
-- ZERO-DOSE DEFINITION:
--   Child aged 0–24 months with no child immunization doses recorded
--   as of end of the reporting month. Malaria and HPV do NOT count.
--
-- FIC DEFINITION:
--   All 19 Uganda EPI doses received by end of the reporting month
--   (BCG, HepB0, OPV0-3, DPT1-3, PCV1-3, Rota1-2, IPV1-2, MR1, YF, MR2).
--
-- HOUSEHOLD REPORTING:
--   household_id is in dwh.dim_patients. Join when needed:
--   JOIN dwh.dim_patients p ON p.patient_id = f.patient_id
--
-- NOTE FOR DEV TEAM — ETL mapping gap:
--   Most immunization records in fact_opensrp_immunizations currently
--   land with programme = 'unknown' and antigen_group = NULL because
--   the ETL questionnaire mapping is incomplete. Queries derive doses
--   directly from vaccine_name to work around this. The following
--   questionnaire IDs should be added to the ETL mapping:
--     Questionnaire/child-immunization-record-all
--     Questionnaire/malaria-vaccine-record
--     Questionnaire/hpv-vaccine-record
--     Questionnaire/6965f0fc-e0e9-449e-941a-c6e708cc9dd6  (legacy)
-- ============================================================


-- ============================================================
-- 1. KPI SUMMARY
-- ============================================================
-- Returns one row with all headline indicators for a given month.
-- Change the reporting_month value and location filter as needed.
-- ============================================================

SELECT
    reporting_month                                                            AS as_of_month,

    COUNT(*)                                                                   AS registered_children,

    COUNT(*) FILTER (WHERE age_days_at_period BETWEEN 0 AND 730)              AS eligible_0_24m,

    COUNT(*) FILTER (WHERE age_days_at_period BETWEEN 0 AND 1825)             AS eligible_under5,

    COUNT(*) FILTER (WHERE is_zero_dose)                                       AS zero_dose_count,

    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_zero_dose)
        / NULLIF(COUNT(*) FILTER (WHERE age_days_at_period BETWEEN 0 AND 730), 0), 1
    )                                                                          AS zero_dose_pct,

    COUNT(*) FILTER (WHERE is_under_immunised)                                AS under_immunised_count,

    COUNT(*) FILTER (WHERE is_fic)                                             AS fic_count,

    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_fic)
        / NULLIF(COUNT(*) FILTER (WHERE age_days_at_period >= 540), 0), 1
    )                                                                          AS fic_coverage_pct

FROM dwh.fact_imm_patient_monthly
WHERE reporting_month = '2025-06-01'              -- replace with target month
-- AND district_name    = 'Kampala'
-- AND subcounty_name   = 'Kawempe Division'
GROUP BY reporting_month;


-- ============================================================
-- 2. ANTIGEN COVERAGE TABLE
-- ============================================================
-- One row per vaccine dose. Location filter goes in the CTE.
-- Denominator uses age-appropriate eligibility per dose.
-- ============================================================

WITH cohort AS (
    SELECT *
    FROM dwh.fact_imm_patient_monthly
    WHERE reporting_month = '2025-06-01'          -- replace with target month
    -- AND district_name        = 'Kampala'
    -- AND subcounty_name       = 'Kawempe Division'
),
counts AS (
    SELECT
        COUNT(*)                                              AS all_children,
        COUNT(*) FILTER (WHERE age_days_at_period >= 42)     AS age_6w_plus,
        COUNT(*) FILTER (WHERE age_days_at_period >= 70)     AS age_10w_plus,
        COUNT(*) FILTER (WHERE age_days_at_period >= 98)     AS age_14w_plus,
        COUNT(*) FILTER (WHERE age_days_at_period >= 270)    AS age_9m_plus,
        COUNT(*) FILTER (WHERE age_days_at_period >= 540)    AS age_18m_plus,
        COUNT(*) FILTER (WHERE bcg_date    IS NOT NULL)      AS bcg,
        COUNT(*) FILTER (WHERE hepb0_date  IS NOT NULL)      AS hepb0,
        COUNT(*) FILTER (WHERE opv0_date   IS NOT NULL)      AS opv0,
        COUNT(*) FILTER (WHERE opv1_date   IS NOT NULL)      AS opv1,
        COUNT(*) FILTER (WHERE dpt1_date   IS NOT NULL)      AS dpt1,
        COUNT(*) FILTER (WHERE pcv1_date   IS NOT NULL)      AS pcv1,
        COUNT(*) FILTER (WHERE rota1_date  IS NOT NULL)      AS rota1,
        COUNT(*) FILTER (WHERE ipv1_date   IS NOT NULL)      AS ipv1,
        COUNT(*) FILTER (WHERE opv2_date   IS NOT NULL)      AS opv2,
        COUNT(*) FILTER (WHERE dpt2_date   IS NOT NULL)      AS dpt2,
        COUNT(*) FILTER (WHERE pcv2_date   IS NOT NULL)      AS pcv2,
        COUNT(*) FILTER (WHERE rota2_date  IS NOT NULL)      AS rota2,
        COUNT(*) FILTER (WHERE opv3_date   IS NOT NULL)      AS opv3,
        COUNT(*) FILTER (WHERE dpt3_date   IS NOT NULL)      AS dpt3,
        COUNT(*) FILTER (WHERE pcv3_date   IS NOT NULL)      AS pcv3,
        COUNT(*) FILTER (WHERE ipv2_date   IS NOT NULL)      AS ipv2,
        COUNT(*) FILTER (WHERE mr1_date    IS NOT NULL)      AS mr1,
        COUNT(*) FILTER (WHERE yf_date     IS NOT NULL)      AS yf,
        COUNT(*) FILTER (WHERE mr2_date    IS NOT NULL)      AS mr2
    FROM cohort
)
SELECT ord, vaccine, dose_label, due_age, eligible, received,
       ROUND(100.0 * received / NULLIF(eligible, 0), 1)      AS coverage_pct
FROM counts,
LATERAL (VALUES
    (1,  'BCG',              'Birth',    '0 days',   all_children,  bcg),
    (2,  'HepB 0',           'Birth',    '0 days',   all_children,  hepb0),
    (3,  'OPV 0',            'Birth',    '0 days',   all_children,  opv0),
    (4,  'OPV 1',            'Dose 1',   '6 weeks',  age_6w_plus,   opv1),
    (5,  'DPT-HepB-Hib 1',  'Dose 1',   '6 weeks',  age_6w_plus,   dpt1),
    (6,  'PCV 1',            'Dose 1',   '6 weeks',  age_6w_plus,   pcv1),
    (7,  'Rota 1',           'Dose 1',   '6 weeks',  age_6w_plus,   rota1),
    (8,  'IPV 1',            'Dose 1',   '6 weeks',  age_6w_plus,   ipv1),
    (9,  'OPV 2',            'Dose 2',   '10 weeks', age_10w_plus,  opv2),
    (10, 'DPT-HepB-Hib 2',  'Dose 2',   '10 weeks', age_10w_plus,  dpt2),
    (11, 'PCV 2',            'Dose 2',   '10 weeks', age_10w_plus,  pcv2),
    (12, 'Rota 2',           'Dose 2',   '10 weeks', age_10w_plus,  rota2),
    (13, 'OPV 3',            'Dose 3',   '14 weeks', age_14w_plus,  opv3),
    (14, 'DPT-HepB-Hib 3',  'Dose 3',   '14 weeks', age_14w_plus,  dpt3),
    (15, 'PCV 3',            'Dose 3',   '14 weeks', age_14w_plus,  pcv3),
    (16, 'IPV 2',            'Dose 2',   '14 weeks', age_14w_plus,  ipv2),
    (17, 'Measles-Rubella 1','Dose 1',   '9 months', age_9m_plus,   mr1),
    (18, 'Yellow Fever',     'Dose 1',   '9 months', age_9m_plus,   yf),
    (19, 'Measles-Rubella 2','Dose 2',   '18 months',age_18m_plus,  mr2)
) AS v(ord, vaccine, dose_label, due_age, eligible, received)
ORDER BY ord;


-- ============================================================
-- 3. ZERO-DOSE CHILDREN LINE LIST
-- ============================================================
-- One row per zero-dose child (aged 0–24 months, no doses).
-- Includes VHT name and caregiver phone for follow-up.
-- ============================================================

SELECT
    patient_id,
    patient_name,
    gender,
    date_of_birth,
    age_months_at_period                                                       AS age_months,
    caregiver_phone,
    vht_name,
    village_name,
    parish_name,
    subcounty_name,
    health_facility_name,
    reporting_month

FROM dwh.fact_imm_patient_monthly
WHERE reporting_month = '2025-06-01'              -- replace with target month
  AND is_zero_dose    = true
  -- AND district_name    = 'Kampala'
  -- AND subcounty_name   = 'Kawempe Division'
ORDER BY age_months_at_period DESC, village_name, patient_name;


-- ============================================================
-- 4. UNDER-IMMUNISED CHILDREN LINE LIST
-- ============================================================
-- One row per under-immunised child (≥1 dose, not FIC, under 5).
-- The missing_doses column shows exactly which doses are outstanding.
-- ============================================================

SELECT
    patient_id,
    patient_name,
    gender,
    date_of_birth,
    age_months_at_period                                                       AS age_months,
    caregiver_phone,
    vht_name,
    village_name,
    parish_name,
    subcounty_name,
    health_facility_name,
    child_doses_received,
    CONCAT_WS(', ',
        CASE WHEN bcg_date    IS NULL                                THEN 'BCG'   END,
        CASE WHEN hepb0_date  IS NULL                                THEN 'HepB0' END,
        CASE WHEN opv0_date   IS NULL                                THEN 'OPV0'  END,
        CASE WHEN opv1_date   IS NULL AND age_days_at_period >= 42   THEN 'OPV1'  END,
        CASE WHEN dpt1_date   IS NULL AND age_days_at_period >= 42   THEN 'DPT1'  END,
        CASE WHEN pcv1_date   IS NULL AND age_days_at_period >= 42   THEN 'PCV1'  END,
        CASE WHEN rota1_date  IS NULL AND age_days_at_period >= 42   THEN 'Rota1' END,
        CASE WHEN ipv1_date   IS NULL AND age_days_at_period >= 42   THEN 'IPV1'  END,
        CASE WHEN opv2_date   IS NULL AND age_days_at_period >= 70   THEN 'OPV2'  END,
        CASE WHEN dpt2_date   IS NULL AND age_days_at_period >= 70   THEN 'DPT2'  END,
        CASE WHEN pcv2_date   IS NULL AND age_days_at_period >= 70   THEN 'PCV2'  END,
        CASE WHEN rota2_date  IS NULL AND age_days_at_period >= 70   THEN 'Rota2' END,
        CASE WHEN opv3_date   IS NULL AND age_days_at_period >= 98   THEN 'OPV3'  END,
        CASE WHEN dpt3_date   IS NULL AND age_days_at_period >= 98   THEN 'DPT3'  END,
        CASE WHEN pcv3_date   IS NULL AND age_days_at_period >= 98   THEN 'PCV3'  END,
        CASE WHEN ipv2_date   IS NULL AND age_days_at_period >= 98   THEN 'IPV2'  END,
        CASE WHEN mr1_date    IS NULL AND age_days_at_period >= 270  THEN 'MR1'   END,
        CASE WHEN yf_date     IS NULL AND age_days_at_period >= 270  THEN 'YF'    END,
        CASE WHEN mr2_date    IS NULL AND age_days_at_period >= 540  THEN 'MR2'   END
    )                                                                          AS missing_doses,
    reporting_month

FROM dwh.fact_imm_patient_monthly
WHERE reporting_month    = '2025-06-01'           -- replace with target month
  AND is_under_immunised = true
  -- AND district_name    = 'Kampala'
  -- AND subcounty_name   = 'Kawempe Division'
ORDER BY age_months_at_period DESC, village_name, patient_name;


-- ============================================================
-- 5. VHT CASELOAD SUMMARY
-- ============================================================
-- One row per VHT showing eligible, zero-dose,
-- under-immunised, and FIC counts for the month.
-- ============================================================

SELECT
    vht_name,
    village_name,
    parish_name,
    subcounty_name,

    COUNT(*)                                                                   AS eligible_children,

    COUNT(*) FILTER (WHERE age_days_at_period BETWEEN 0 AND 730)              AS eligible_0_24m,

    COUNT(*) FILTER (WHERE is_zero_dose)                                       AS zero_dose_count,

    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_zero_dose)
        / NULLIF(COUNT(*) FILTER (WHERE age_days_at_period BETWEEN 0 AND 730), 0), 1
    )                                                                          AS zero_dose_pct,

    COUNT(*) FILTER (WHERE is_under_immunised)                                AS under_immunised_count,

    COUNT(*) FILTER (WHERE is_fic)                                             AS fic_count

FROM dwh.fact_imm_patient_monthly
WHERE reporting_month = '2025-06-01'              -- replace with target month
-- AND subcounty_name  = 'Kawempe Division'
GROUP BY vht_name, village_name, parish_name, subcounty_name
ORDER BY zero_dose_count DESC;


-- ============================================================
-- 6. VILLAGE BURDEN TABLE
-- ============================================================
-- Zero-dose and under-immunised count per village for a month.
-- ============================================================

SELECT
    district_name,
    subcounty_name,
    parish_name,
    health_facility_name,
    village_name,

    eligible_0_24m,
    zero_dose_count,
    zero_dose_pct,
    under_immunised_count,
    fic_count

FROM dwh.v_imm_location_monthly
WHERE reporting_month = '2025-06-01'              -- replace with target month
  AND village_name    IS NOT NULL
  -- AND district_name  = 'Kampala'
ORDER BY zero_dose_count DESC;


-- ============================================================
-- 7. SUBCOUNTY COMPARISON
-- ============================================================
-- All subcounties ranked by zero-dose burden for a given month.
-- ============================================================

SELECT
    district_name,
    subcounty_name,
    eligible_0_24m,
    zero_dose_count,
    zero_dose_pct,
    under_immunised_count,
    fic_count,
    fic_coverage_pct,
    dpt1_coverage_pct,
    mr1_coverage_pct

FROM dwh.v_imm_location_monthly
WHERE reporting_month = '2025-06-01'              -- replace with target month
  AND subcounty_name  IS NOT NULL
  AND parish_name     IS NULL
  -- AND district_name = 'Kampala'
ORDER BY zero_dose_count DESC;


-- ============================================================
-- 8. MONTHLY TREND — zero-dose by district across all months
-- ============================================================
-- Shows how zero-dose burden has changed month by month.
-- Filter to one district or remove the filter for national.
-- ============================================================

SELECT
    reporting_month,
    district_name,
    eligible_0_24m,
    zero_dose_count,
    zero_dose_pct,
    fic_count,
    fic_coverage_pct

FROM dwh.v_imm_location_monthly
WHERE subcounty_name IS NULL
  AND parish_name    IS NULL
  -- AND district_name = 'Kampala'       -- remove for all districts
ORDER BY district_name, reporting_month;


-- ============================================================
-- 9. HOUSEHOLD REPORTING
-- ============================================================
-- How many unique households have zero-dose children.
-- household_id and household_name are included directly in the table.
-- ============================================================

-- Summary: households with zero-dose children by location
SELECT
    district_name,
    subcounty_name,
    COUNT(DISTINCT household_id)                                               AS households_with_zero_dose,
    COUNT(*)                                                                   AS zero_dose_children

FROM dwh.fact_imm_patient_monthly
WHERE reporting_month = '2025-06-01'              -- replace with target month
  AND is_zero_dose    = true
  -- AND district_name = 'Kampala'
GROUP BY district_name, subcounty_name
ORDER BY households_with_zero_dose DESC;


-- Line list: zero-dose children with their household
SELECT
    patient_name,
    gender,
    date_of_birth,
    age_months_at_period                                                       AS age_months,
    household_id,
    household_name,
    caregiver_phone,
    vht_name,
    village_name,
    subcounty_name,
    district_name

FROM dwh.fact_imm_patient_monthly
WHERE reporting_month = '2025-06-01'              -- replace with target month
  AND is_zero_dose    = true
  -- AND district_name = 'Kampala'
ORDER BY household_id, age_months_at_period DESC;


-- ============================================================
-- 10. MALARIA VACCINE SUMMARY
-- ============================================================

SELECT
    reporting_month,
    SUM(malaria_dose1_count)    AS malaria_dose1,
    SUM(malaria_complete_count) AS malaria_complete,
    SUM(hpv_dose1_count)        AS hpv_dose1,
    SUM(hpv_dose2_count)        AS hpv_dose2

FROM dwh.v_imm_location_monthly
WHERE reporting_month = '2025-06-01'              -- replace with target month
  -- AND district_name = 'Kampala'
GROUP BY reporting_month;


-- ============================================================
-- 11. FIC CHILDREN LINE LIST
-- ============================================================
-- One row per fully immunized child as of the reporting month.
-- ============================================================

SELECT
    patient_id,
    patient_name,
    gender,
    date_of_birth,
    age_months_at_period                                                       AS age_months,
    vht_name,
    village_name,
    parish_name,
    subcounty_name,
    health_facility_name,
    district_name,
    mr2_date                                                                   AS fic_completion_date,
    reporting_month

FROM dwh.fact_imm_patient_monthly
WHERE reporting_month = '2025-06-01'              -- replace with target month
  AND is_fic          = true
  -- AND district_name        = 'Kampala'
  -- AND subcounty_name       = 'Kawempe Division'
ORDER BY mr2_date DESC, village_name, patient_name;


-- ============================================================
-- 12. FULL PATIENT STATUS EXPORT
-- ============================================================
-- All registered children with every dose date for a given month.
-- Export to CSV from pgAdmin: right-click result → Copy All Rows.
-- ============================================================

SELECT
    reporting_month,
    patient_id,
    patient_name,
    gender,
    date_of_birth,
    age_days_at_period                                                         AS age_days,
    age_months_at_period                                                       AS age_months,
    is_zero_dose,
    is_under_immunised,
    is_fic,
    child_doses_received,
    bcg_date, hepb0_date, opv0_date,
    opv1_date, dpt1_date, pcv1_date, rota1_date, ipv1_date,
    opv2_date, dpt2_date, pcv2_date, rota2_date,
    opv3_date, dpt3_date, pcv3_date, ipv2_date,
    mr1_date, yf_date, mr2_date,
    malaria1_date, malaria2_date, malaria3_date, malaria_booster_date,
    malaria_doses_received,
    hpv1_date, hpv2_date, hpv_doses_received,
    vht_name,
    caregiver_phone,
    village_name, parish_name, health_facility_name,
    subcounty_name, county_name, district_name, region_name

FROM dwh.fact_imm_patient_monthly
WHERE reporting_month = '2025-06-01'              -- replace with target month
  -- AND district_name        = 'Kampala'
  -- AND subcounty_name       = 'Kawempe Division'
ORDER BY district_name, subcounty_name, village_name, patient_name;


-- ============================================================
-- 13. VHT ACTIVITY SUMMARY REPORT
-- ============================================================
-- One row per VHT. ALL active VHTs are included, even those
-- with zero registered patients (true non-reporters).
--
-- Driven by dim_opensrp_practitioner_assignments (is_vht = 'true')
-- so no VHT is silently excluded. Location comes from the
-- assignments table — present even for VHTs with no patients.
--
-- Immunization KPIs, patient counts, and encounter counts are
-- LEFT JOINed — they show 0 when no data exists.
--
-- Encounters = immunization doses administered (best available
-- proxy for VHT activity on the partner warehouse).
--
-- Patient/household time windows use last_updated from dim_patients
-- as registration date proxy (FHIR meta.lastUpdated).
--
-- Location filter: uncomment WHERE at the bottom.
-- ============================================================

WITH

-- All VHTs from the assignments table — one row per VHT (DISTINCT ON).
-- Provides the full location hierarchy from current assignment, so VHTs
-- with zero registered patients still appear with a district and village.
-- is_vht = 'true' excludes supervisors and web admins.
all_vhts AS (
    SELECT DISTINCT ON (practitioner_id)
        practitioner_id,
        practitioner_name,
        district_name,
        subcounty_name,
        parish_name,
        health_facility_name,
        village_name
    FROM dwh.dim_opensrp_practitioner_assignments
    WHERE is_vht = 'true'
      AND practitioner_active = 'true'
    ORDER BY practitioner_id, village_name NULLS LAST
),

latest_month AS (
    SELECT MAX(reporting_month) AS m FROM dwh.fact_imm_patient_monthly
),

-- Current immunization KPIs per VHT (latest month only).
-- Groups by vht_id only — location comes from all_vhts above.
-- VHTs with no patients in the latest month produce no rows here;
-- they still appear via the LEFT JOIN from all_vhts.
current_state AS (
    SELECT
        f.vht_id,
        COUNT(DISTINCT f.patient_id)                                            AS patients_all_time,
        COUNT(DISTINCT f.household_id)                                          AS hh_all_time,
        COUNT(*) FILTER (WHERE f.age_days_at_period BETWEEN 0 AND 730)         AS imm_eligible_0_24m,
        COUNT(*) FILTER (WHERE f.is_zero_dose)                                  AS imm_zero_dose,
        COUNT(*) FILTER (WHERE f.is_under_immunised)                            AS imm_under_immunised,
        COUNT(*) FILTER (WHERE f.is_fic)                                        AS imm_fic
    FROM dwh.fact_imm_patient_monthly f
    CROSS JOIN latest_month lm
    WHERE f.reporting_month = lm.m
    GROUP BY f.vht_id
),

-- Time-windowed patient and household counts.
-- Uses dim_patients.last_updated as registration date proxy (FHIR meta.lastUpdated).
patient_time AS (
    SELECT
        p.practitioner_id                                                       AS vht_id,
        COUNT(DISTINCT p.patient_id) FILTER (
            WHERE p.last_updated >= DATE_TRUNC('year', CURRENT_DATE)
        )                                                                       AS patients_this_year,
        COUNT(DISTINCT p.patient_id) FILTER (
            WHERE p.last_updated >= CURRENT_DATE - INTERVAL '3 months'
        )                                                                       AS patients_last_3mo,
        COUNT(DISTINCT p.household_id) FILTER (
            WHERE p.last_updated >= DATE_TRUNC('year', CURRENT_DATE)
        )                                                                       AS hh_this_year,
        COUNT(DISTINCT p.household_id) FILTER (
            WHERE p.last_updated >= CURRENT_DATE - INTERVAL '3 months'
        )                                                                       AS hh_last_3mo
    FROM dwh.dim_patients p
    WHERE p.birth_date IS NOT NULL
      AND p.birth_date >= CURRENT_DATE - INTERVAL '5 years'
      AND (p.is_deceased IS NULL OR p.is_deceased = false)
    GROUP BY p.practitioner_id
),

-- Encounter counts (immunization doses administered), joined through
-- dim_patients for a consistent practitioner link.
encounters AS (
    SELECT
        p.practitioner_id                                                       AS vht_id,
        COUNT(*)                                                                AS encounters_all_time,
        COUNT(*) FILTER (
            WHERE fi.administered_date::date >= DATE_TRUNC('year', CURRENT_DATE)::date
        )                                                                       AS encounters_this_year,
        COUNT(*) FILTER (
            WHERE fi.administered_date::date >= CURRENT_DATE - INTERVAL '3 months'
        )                                                                       AS encounters_last_3mo,
        MAX(fi.administered_date::date)                                         AS last_encounter_date
    FROM dwh.fact_opensrp_immunizations fi
    JOIN dwh.dim_patients p ON p.patient_id = fi.patient_id
    WHERE fi.administered_date IS NOT NULL
      AND fi.administered_date <> ''
      AND fi.administered_date::date BETWEEN '2018-01-01' AND CURRENT_DATE
    GROUP BY p.practitioner_id
)

SELECT
    CURRENT_DATE                                                                AS report_date,
    v.district_name,
    v.subcounty_name,
    v.parish_name,
    v.health_facility_name,
    v.village_name,
    v.practitioner_id,
    v.practitioner_name,

    -- ── Patients ────────────────────────────────────────────────────────────
    COALESCE(cs.patients_all_time,    0)                                        AS patients_all_time,
    COALESCE(pt.patients_this_year,   0)                                        AS patients_this_year,
    COALESCE(pt.patients_last_3mo,    0)                                        AS patients_last_3mo,

    -- ── Households ──────────────────────────────────────────────────────────
    COALESCE(cs.hh_all_time,          0)                                        AS hh_all_time,
    COALESCE(pt.hh_this_year,         0)                                        AS hh_this_year,
    COALESCE(pt.hh_last_3mo,          0)                                        AS hh_last_3mo,

    -- ── Encounters (immunization doses as proxy) ─────────────────────────────
    COALESCE(e.encounters_all_time,   0)                                        AS encounters_all_time,
    COALESCE(e.encounters_this_year,  0)                                        AS encounters_this_year,
    COALESCE(e.encounters_last_3mo,   0)                                        AS encounters_last_3mo,
    e.last_encounter_date,
    CASE
        WHEN e.last_encounter_date IS NOT NULL
        THEN (CURRENT_DATE - e.last_encounter_date)::integer
    END                                                                         AS days_since_last_encounter,

    -- ── Immunization status (imm_ prefix) ────────────────────────────────────
    COALESCE(cs.imm_eligible_0_24m,   0)                                        AS imm_eligible_0_24m,
    COALESCE(cs.imm_zero_dose,        0)                                        AS imm_zero_dose,
    COALESCE(cs.imm_under_immunised,  0)                                        AS imm_under_immunised,
    COALESCE(cs.imm_fic,              0)                                        AS imm_fic,

    -- ── Activity flags ───────────────────────────────────────────────────────
    (COALESCE(e.encounters_all_time,  0) > 0)                                   AS has_activity_all_time,
    (COALESCE(e.encounters_this_year, 0) > 0)                                   AS has_activity_this_year,
    (COALESCE(e.encounters_last_3mo,  0) > 0)                                   AS has_activity_last_3mo,

    -- ── Non-reporting flags (TRUE = no encounters in that window) ─────────────
    (COALESCE(e.encounters_all_time,  0) = 0)                                   AS non_reporting_all_time,
    (COALESCE(e.encounters_this_year, 0) = 0)                                   AS non_reporting_this_year,
    (COALESCE(e.encounters_last_3mo,  0) = 0)                                   AS non_reporting_last_3mo

FROM all_vhts v
LEFT JOIN current_state cs ON cs.vht_id = v.practitioner_id
LEFT JOIN patient_time  pt ON pt.vht_id = v.practitioner_id
LEFT JOIN encounters    e  ON e.vht_id  = v.practitioner_id
-- WHERE v.district_name  = 'Kampala'
-- WHERE v.subcounty_name = 'Kawempe Division'
ORDER BY v.district_name, v.subcounty_name, v.health_facility_name, v.village_name, v.practitioner_name;
