-- ============================================================
-- eCHIS Immunization Report Queries — Partner Warehouse
-- ============================================================
-- Source: dwh.mv_imm_patient_status
--
-- This view is a snapshot of all registered children (under 5)
-- with their immunization status as of the last refresh date.
--
-- HOW TO REFRESH (run daily, or on demand before reporting):
--   REFRESH MATERIALIZED VIEW CONCURRENTLY dwh.mv_imm_patient_status;
--
-- WHEN WAS IT LAST REFRESHED?
--   SELECT MAX(snapshot_date) FROM dwh.mv_imm_patient_status;
--
-- HOW TO FILTER BY LOCATION:
--   National      — remove the location filter entirely
--   District      — AND district_name    = 'Kampala'
--   Subcounty     — AND subcounty_name   = 'Kawempe Division'
--   Health Facility — AND health_facility_name = 'Kawempe HC IV'
--   Village       — AND village_name     = 'Bwaise I'
--
-- ZERO-DOSE DEFINITION:
--   Child aged 0–24 months with no child immunization doses recorded.
--   Malaria and HPV doses do NOT count.
--
-- FIC DEFINITION:
--   All 19 Uganda EPI doses received (BCG, HepB0, OPV0-3,
--   DPT1-3, PCV1-3, Rota1-2, IPV1-2, MR1, YF, MR2).
--
-- NOTE FOR DEV TEAM — ETL mapping gap:
--   Most immunization records in fact_opensrp_immunizations currently
--   land with programme = 'unknown' and antigen_group = NULL because
--   the ETL questionnaire mapping is incomplete. The MV bypasses this
--   entirely and derives all doses directly from the vaccine_name field.
--   The dev team should add the following questionnaire IDs to the ETL
--   mapping to correct the upstream data:
--     Questionnaire/child-immunization-record-all
--     Questionnaire/malaria-vaccine-record
--     Questionnaire/hpv-vaccine-record
--     Questionnaire/6965f0fc-e0e9-449e-941a-c6e708cc9dd6  (legacy)
--
-- NOTE: caregiver_phone is NULL in all current records.
--   The source data does not yet carry phone numbers through to this table.
-- ============================================================


-- ============================================================
-- 1. KPI SUMMARY
-- ============================================================
-- Returns one row with all headline indicators.
-- Adjust the location filter for the level you need.
-- ============================================================

SELECT
    MAX(snapshot_date)                                                      AS as_of_date,

    COUNT(*)                                                                AS registered_children,

    COUNT(*) FILTER (WHERE age_days BETWEEN 0 AND 730)                     AS eligible_0_24m,

    COUNT(*) FILTER (WHERE age_days BETWEEN 0 AND 1825)                    AS eligible_under5,

    COUNT(*) FILTER (WHERE is_zero_dose)                                    AS zero_dose_count,

    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_zero_dose)
        / NULLIF(COUNT(*) FILTER (WHERE age_days BETWEEN 0 AND 730), 0), 1
    )                                                                       AS zero_dose_pct,

    COUNT(*) FILTER (WHERE is_under_immunised)                             AS under_immunised_count,

    COUNT(*) FILTER (WHERE is_fic)                                          AS fic_count,

    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_fic)
        / NULLIF(COUNT(*) FILTER (WHERE age_days >= 540), 0), 1            -- ≥18 months
    )                                                                       AS fic_coverage_pct

FROM dwh.mv_imm_patient_status
-- WHERE district_name    = 'Kampala'        -- district level
-- WHERE subcounty_name   = 'Kawempe Division' -- subcounty level
-- WHERE health_facility_name = 'Kawempe HC IV' -- facility level
;


-- ============================================================
-- 2. ANTIGEN COVERAGE TABLE
-- ============================================================
-- One row per vaccine dose. Location filter goes in the CTE.
-- Denominator uses age-appropriate eligibility per dose.
-- ============================================================

WITH cohort AS (
    SELECT *
    FROM dwh.mv_imm_patient_status
    -- WHERE district_name        = 'Kampala'
    -- WHERE subcounty_name       = 'Kawempe Division'
    -- WHERE health_facility_name = 'Kawempe HC IV'
),
counts AS (
    SELECT
        COUNT(*)                                  AS all_children,
        COUNT(*) FILTER (WHERE age_days >= 42)    AS age_6w_plus,
        COUNT(*) FILTER (WHERE age_days >= 70)    AS age_10w_plus,
        COUNT(*) FILTER (WHERE age_days >= 98)    AS age_14w_plus,
        COUNT(*) FILTER (WHERE age_days >= 270)   AS age_9m_plus,
        COUNT(*) FILTER (WHERE age_days >= 540)   AS age_18m_plus,
        COUNT(*) FILTER (WHERE bcg_date    IS NOT NULL) AS bcg,
        COUNT(*) FILTER (WHERE hepb0_date  IS NOT NULL) AS hepb0,
        COUNT(*) FILTER (WHERE opv0_date   IS NOT NULL) AS opv0,
        COUNT(*) FILTER (WHERE opv1_date   IS NOT NULL) AS opv1,
        COUNT(*) FILTER (WHERE dpt1_date   IS NOT NULL) AS dpt1,
        COUNT(*) FILTER (WHERE pcv1_date   IS NOT NULL) AS pcv1,
        COUNT(*) FILTER (WHERE rota1_date  IS NOT NULL) AS rota1,
        COUNT(*) FILTER (WHERE ipv1_date   IS NOT NULL) AS ipv1,
        COUNT(*) FILTER (WHERE opv2_date   IS NOT NULL) AS opv2,
        COUNT(*) FILTER (WHERE dpt2_date   IS NOT NULL) AS dpt2,
        COUNT(*) FILTER (WHERE pcv2_date   IS NOT NULL) AS pcv2,
        COUNT(*) FILTER (WHERE rota2_date  IS NOT NULL) AS rota2,
        COUNT(*) FILTER (WHERE opv3_date   IS NOT NULL) AS opv3,
        COUNT(*) FILTER (WHERE dpt3_date   IS NOT NULL) AS dpt3,
        COUNT(*) FILTER (WHERE pcv3_date   IS NOT NULL) AS pcv3,
        COUNT(*) FILTER (WHERE ipv2_date   IS NOT NULL) AS ipv2,
        COUNT(*) FILTER (WHERE mr1_date    IS NOT NULL) AS mr1,
        COUNT(*) FILTER (WHERE yf_date     IS NOT NULL) AS yf,
        COUNT(*) FILTER (WHERE mr2_date    IS NOT NULL) AS mr2
    FROM cohort
)
SELECT ord, vaccine, dose_label, due_age, eligible, received,
       ROUND(100.0 * received / NULLIF(eligible, 0), 1) AS coverage_pct
FROM counts,
LATERAL (VALUES
    (1,  'BCG',              'Birth',   '0 days',    all_children,  bcg),
    (2,  'HepB 0',           'Birth',   '0 days',    all_children,  hepb0),
    (3,  'OPV 0',            'Birth',   '0 days',    all_children,  opv0),
    (4,  'OPV 1',            'Dose 1',  '6 weeks',   age_6w_plus,   opv1),
    (5,  'DPT-HepB-Hib 1',  'Dose 1',  '6 weeks',   age_6w_plus,   dpt1),
    (6,  'PCV 1',            'Dose 1',  '6 weeks',   age_6w_plus,   pcv1),
    (7,  'Rota 1',           'Dose 1',  '6 weeks',   age_6w_plus,   rota1),
    (8,  'IPV 1',            'Dose 1',  '6 weeks',   age_6w_plus,   ipv1),
    (9,  'OPV 2',            'Dose 2',  '10 weeks',  age_10w_plus,  opv2),
    (10, 'DPT-HepB-Hib 2',  'Dose 2',  '10 weeks',  age_10w_plus,  dpt2),
    (11, 'PCV 2',            'Dose 2',  '10 weeks',  age_10w_plus,  pcv2),
    (12, 'Rota 2',           'Dose 2',  '10 weeks',  age_10w_plus,  rota2),
    (13, 'OPV 3',            'Dose 3',  '14 weeks',  age_14w_plus,  opv3),
    (14, 'DPT-HepB-Hib 3',  'Dose 3',  '14 weeks',  age_14w_plus,  dpt3),
    (15, 'PCV 3',            'Dose 3',  '14 weeks',  age_14w_plus,  pcv3),
    (16, 'IPV 2',            'Dose 2',  '14 weeks',  age_14w_plus,  ipv2),
    (17, 'Measles-Rubella 1','Dose 1',  '9 months',  age_9m_plus,   mr1),
    (18, 'Yellow Fever',     'Dose 1',  '9 months',  age_9m_plus,   yf),
    (19, 'Measles-Rubella 2','Dose 2',  '18 months', age_18m_plus,  mr2)
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
    age_months,
    caregiver_phone,
    vht_name,
    village_name,
    parish_name,
    subcounty_name,
    health_facility_name,
    snapshot_date

FROM dwh.mv_imm_patient_status
WHERE is_zero_dose = true
  -- AND district_name    = 'Kampala'
  -- AND subcounty_name   = 'Kawempe Division'
  -- AND health_facility_name = 'Kawempe HC IV'
ORDER BY age_months DESC, village_name, patient_name;


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
    age_months,
    caregiver_phone,
    vht_name,
    village_name,
    parish_name,
    subcounty_name,
    health_facility_name,
    child_doses_received,
    CONCAT_WS(', ',
        CASE WHEN bcg_date    IS NULL                        THEN 'BCG'    END,
        CASE WHEN hepb0_date  IS NULL                        THEN 'HepB0'  END,
        CASE WHEN opv0_date   IS NULL                        THEN 'OPV0'   END,
        CASE WHEN opv1_date   IS NULL AND age_days >= 42     THEN 'OPV1'   END,
        CASE WHEN dpt1_date   IS NULL AND age_days >= 42     THEN 'DPT1'   END,
        CASE WHEN pcv1_date   IS NULL AND age_days >= 42     THEN 'PCV1'   END,
        CASE WHEN rota1_date  IS NULL AND age_days >= 42     THEN 'Rota1'  END,
        CASE WHEN ipv1_date   IS NULL AND age_days >= 42     THEN 'IPV1'   END,
        CASE WHEN opv2_date   IS NULL AND age_days >= 70     THEN 'OPV2'   END,
        CASE WHEN dpt2_date   IS NULL AND age_days >= 70     THEN 'DPT2'   END,
        CASE WHEN pcv2_date   IS NULL AND age_days >= 70     THEN 'PCV2'   END,
        CASE WHEN rota2_date  IS NULL AND age_days >= 70     THEN 'Rota2'  END,
        CASE WHEN opv3_date   IS NULL AND age_days >= 98     THEN 'OPV3'   END,
        CASE WHEN dpt3_date   IS NULL AND age_days >= 98     THEN 'DPT3'   END,
        CASE WHEN pcv3_date   IS NULL AND age_days >= 98     THEN 'PCV3'   END,
        CASE WHEN ipv2_date   IS NULL AND age_days >= 98     THEN 'IPV2'   END,
        CASE WHEN mr1_date    IS NULL AND age_days >= 270    THEN 'MR1'    END,
        CASE WHEN yf_date     IS NULL AND age_days >= 270    THEN 'YF'     END,
        CASE WHEN mr2_date    IS NULL AND age_days >= 540    THEN 'MR2'    END
    )                                                                       AS missing_doses,
    snapshot_date

FROM dwh.mv_imm_patient_status
WHERE is_under_immunised = true
  -- AND district_name    = 'Kampala'
  -- AND subcounty_name   = 'Kawempe Division'
  -- AND health_facility_name = 'Kawempe HC IV'
ORDER BY age_months DESC, village_name, patient_name;


-- ============================================================
-- 5. VHT CASELOAD SUMMARY
-- ============================================================
-- One row per VHT showing their eligible, zero-dose,
-- under-immunised, and FIC counts.
-- ============================================================

SELECT
    vht_name,
    village_name,
    parish_name,
    subcounty_name,

    COUNT(*)                                                                AS eligible_children,

    COUNT(*) FILTER (WHERE age_days BETWEEN 0 AND 730)                     AS eligible_0_24m,

    COUNT(*) FILTER (WHERE is_zero_dose)                                    AS zero_dose_count,

    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_zero_dose)
        / NULLIF(COUNT(*) FILTER (WHERE age_days BETWEEN 0 AND 730), 0), 1
    )                                                                       AS zero_dose_pct,

    COUNT(*) FILTER (WHERE is_under_immunised)                             AS under_immunised_count,

    COUNT(*) FILTER (WHERE is_fic)                                          AS fic_count

FROM dwh.mv_imm_patient_status
-- WHERE subcounty_name = 'Kawempe Division'
-- WHERE health_facility_name = 'Kawempe HC IV'
GROUP BY vht_name, village_name, parish_name, subcounty_name
ORDER BY zero_dose_count DESC;


-- ============================================================
-- 6. VILLAGE BURDEN TABLE
-- ============================================================
-- Zero-dose and under-immunised count per village.
-- Useful for planning outreach and prioritizing follow-up.
-- ============================================================

SELECT
    district_name,
    subcounty_name,
    parish_name,
    health_facility_name,
    village_name,

    COUNT(*) FILTER (WHERE age_days BETWEEN 0 AND 730)                     AS eligible_0_24m,
    COUNT(*) FILTER (WHERE is_zero_dose)                                    AS zero_dose_count,
    COUNT(*) FILTER (WHERE is_under_immunised)                             AS under_immunised_count,
    COUNT(*) FILTER (WHERE is_fic)                                          AS fic_count,

    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_zero_dose)
        / NULLIF(COUNT(*) FILTER (WHERE age_days BETWEEN 0 AND 730), 0), 1
    )                                                                       AS zero_dose_pct

FROM dwh.mv_imm_patient_status
-- WHERE district_name  = 'Kampala'
-- WHERE subcounty_name = 'Kawempe Division'
GROUP BY district_name, subcounty_name, parish_name, health_facility_name, village_name
ORDER BY zero_dose_count DESC;


-- ============================================================
-- 7. SUBCOUNTY COMPARISON
-- ============================================================
-- All subcounties ranked by zero-dose burden.
-- For district monthly report.
-- ============================================================

SELECT
    district_name,
    subcounty_name,
    COUNT(*) FILTER (WHERE age_days BETWEEN 0 AND 730)                     AS eligible_0_24m,
    COUNT(*) FILTER (WHERE is_zero_dose)                                    AS zero_dose_count,
    COUNT(*) FILTER (WHERE is_under_immunised)                             AS under_immunised_count,
    COUNT(*) FILTER (WHERE is_fic)                                          AS fic_count,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_zero_dose)
        / NULLIF(COUNT(*) FILTER (WHERE age_days BETWEEN 0 AND 730), 0), 1
    )                                                                       AS zero_dose_pct,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_fic)
        / NULLIF(COUNT(*) FILTER (WHERE age_days >= 540), 0), 1
    )                                                                       AS fic_coverage_pct

FROM dwh.mv_imm_patient_status
-- WHERE district_name = 'Kampala'
GROUP BY district_name, subcounty_name
ORDER BY zero_dose_count DESC;


-- ============================================================
-- 8. MALARIA VACCINE SUMMARY
-- ============================================================

SELECT
    COUNT(*) FILTER (WHERE malaria1_date IS NOT NULL)                       AS malaria_dose1,
    COUNT(*) FILTER (WHERE malaria2_date IS NOT NULL)                       AS malaria_dose2,
    COUNT(*) FILTER (WHERE malaria3_date IS NOT NULL)                       AS malaria_dose3,
    COUNT(*) FILTER (WHERE malaria_booster_date IS NOT NULL)                AS malaria_booster,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE malaria_booster_date IS NOT NULL)
        / NULLIF(COUNT(*) FILTER (WHERE malaria1_date IS NOT NULL), 0), 1
    )                                                                       AS series_completion_pct
FROM dwh.mv_imm_patient_status
-- WHERE district_name = 'Kampala'
;


-- ============================================================
-- 9. FIC CHILDREN LINE LIST
-- ============================================================
-- One row per fully immunized child (all 19 EPI doses received).
-- Useful for verification, community recognition, and reporting
-- to the district health office.
-- Only children aged ≥18 months (540 days) are eligible for FIC
-- since MR2 is the last dose and is due at 18 months.
-- ============================================================

SELECT
    patient_id,
    patient_name,
    gender,
    date_of_birth,
    age_months,
    vht_name,
    village_name,
    parish_name,
    subcounty_name,
    health_facility_name,
    district_name,

    -- Date each dose was received
    bcg_date,
    hepb0_date,
    opv0_date,
    opv1_date,
    dpt1_date,
    pcv1_date,
    rota1_date,
    ipv1_date,
    opv2_date,
    dpt2_date,
    pcv2_date,
    rota2_date,
    opv3_date,
    dpt3_date,
    pcv3_date,
    ipv2_date,
    mr1_date,
    yf_date,
    mr2_date,

    -- Date the last required dose (MR2) was received — effectively the FIC completion date
    mr2_date                                                                AS fic_completion_date,

    snapshot_date

FROM dwh.mv_imm_patient_status
WHERE is_fic = true
  -- AND district_name        = 'Kampala'
  -- AND subcounty_name       = 'Kawempe Division'
  -- AND health_facility_name = 'Kawempe HC IV'
ORDER BY mr2_date DESC, village_name, patient_name;


-- ============================================================
-- 10. FULL PATIENT STATUS EXPORT
-- ============================================================
-- All registered children with every dose date column.
-- Use this when you need to export the full dataset to Excel
-- or another tool for custom analysis.
-- Tip: in pgAdmin, run the query then right-click the result
-- grid → "Copy All Rows" or use File → Export to CSV.
-- ============================================================

SELECT
    -- Identity
    patient_id,
    patient_name,
    gender,
    date_of_birth,
    age_days,
    age_months,

    -- Status flags
    is_zero_dose,
    is_under_immunised,
    is_fic,
    child_doses_received,

    -- Child EPI dose dates (NULL = not yet received)
    bcg_date,
    hepb0_date,
    opv0_date,
    opv1_date,
    dpt1_date,
    pcv1_date,
    rota1_date,
    ipv1_date,
    opv2_date,
    dpt2_date,
    pcv2_date,
    rota2_date,
    opv3_date,
    dpt3_date,
    pcv3_date,
    ipv2_date,
    mr1_date,
    yf_date,
    mr2_date,

    -- Malaria dose dates
    malaria1_date,
    malaria2_date,
    malaria3_date,
    malaria_booster_date,
    malaria_doses_received,

    -- HPV dose dates
    hpv1_date,
    hpv2_date,
    hpv_doses_received,

    -- VHT and location
    vht_name,
    caregiver_phone,
    village_name,
    parish_name,
    health_facility_name,
    subcounty_name,
    county_name,
    district_name,
    region_name,

    snapshot_date

FROM dwh.mv_imm_patient_status
-- WHERE district_name        = 'Kampala'
-- WHERE subcounty_name       = 'Kawempe Division'
-- WHERE health_facility_name = 'Kawempe HC IV'
ORDER BY district_name, subcounty_name, village_name, patient_name;
