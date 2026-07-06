# eCHIS Immunization DWH Handover Guide

This guide documents the immunization reporting layer added to the `dwh` schema. It covers routine child immunization, malaria vaccine doses, and HPV vaccination.

## Purpose

The immunization DWH layer supports:

- Monthly immunization coverage reporting.
- Zero-dose child identification.
- Under-immunized child line lists.
- Missed antigen/dose reporting.
- Recovery reporting for children who were zero-dose or under-immunized in a previous period and later received vaccination.
- HPV eligibility and coverage for girls aged 9-19 years.
- Malaria vaccine reporting for under-5 children.

## Reporting Model

The model uses two main fact tables, one aggregate table, and one reference table:

| Table | Purpose |
|---|---|
| `dwh.ref_immunization_vaccine_map` | Reference schedule and normalized antigen/dose mapping. |
| `dwh.fact_immunizations` | One row per vaccine dose actually administered. Kept permanently. |
| `dwh.fact_immunization_status` | One row per patient × expected dose × reporting period. Rolling 3-month window. Used for operational line lists and follow-up. |
| `dwh.agg_immunization_monthly` | Pre-aggregated monthly coverage — one row per month × location level × programme × antigen × dose. Kept permanently from September 2023. Used for trend reporting and DHIS2 submissions. |

### Two-tier storage design

The immunization module keeps two storage tiers so that the database stays manageable as the programme runs for years.

**Tier 1 — `dwh.fact_immunization_status` (rolling window)**

Row-level data used for operational follow-up: who is zero-dose right now, which children need a visit this month, which VHT should act. The daily wrapper keeps only the current month, previous month, and one prior month (3 months). Older rows are deleted automatically. Historical patient-level data is available in `fact_immunizations` which is kept permanently.

**Tier 2 — `dwh.agg_immunization_monthly` (permanent history)**

Aggregated coverage data kept for all months from September 2023. Supports national, district, subcounty, parish, health facility, and village levels in one table via the `location_level` column. Use for Section 6 MCH Indicators, trend charts, and DHIS2 submissions. Query antigen-specific rows for due/received counts; query `antigen_group = 'ALL'` rows for patient-level KPIs (zero-dose count, FIC count).

## Key Definitions

### Administered Immunization

An administered immunization is a vaccine dose recorded through one of the immunization QuestionnaireResponses:

- `Questionnaire/child-immunization-record-all`
- `Questionnaire/malaria-vaccine-record`
- `Questionnaire/hpv-vaccine-record`
- legacy single child immunization questionnaire records where applicable

### Zero-Dose

The current implementation marks a child as zero-dose if:

```text
child is under 5
AND no qualifying child or malaria vaccine dose has been received before the reporting period end
```

For formal EPI reporting, a stricter Penta/DPT1-based definition may also be added:

```text
child is under 5
AND DPT-HepB-Hib Dose 1 is due
AND DPT-HepB-Hib Dose 1 has not been received before the reporting period end
```

### Under-Immunized

A child is under-immunized if:

```text
at least one expected dose is due before the reporting period end
AND that dose has not been received
```

Because `fact_immunization_status` has one row per patient per expected dose, use `DISTINCT patient_id` when counting children.

## Routine Child Immunization Schedule

| Stage | Schedule Group | Due Age | Antigen / Dose | Max Window |
|---|---|---:|---|---:|
| At Birth | `immunization_at_birth` | Day 0 | BCG at Birth | +7 days |
| At Birth | `immunization_at_birth` | Day 0 | HepB 0 at Birth | +7 days |
| At Birth | `immunization_at_birth` | Day 0 | Polio 0 at Birth | +14 days |
| 6 Weeks | `immunization_at_6_weeks` | Day 42 | Polio 1 | +14 days |
| 6 Weeks | `immunization_at_6_weeks` | Day 42 | Rota 1 | +14 days |
| 6 Weeks | `immunization_at_6_weeks` | Day 42 | PCV 1 | +14 days |
| 6 Weeks | `immunization_at_6_weeks` | Day 42 | IPV 1 | +14 days |
| 6 Weeks | `immunization_at_6_weeks` | Day 42 | DPT-HepB-Hib 1 | +14 days |
| 10 Weeks | `immunization_at_10_weeks` | Day 70 | Polio 2 | +14 days |
| 10 Weeks | `immunization_at_10_weeks` | Day 70 | Rota 2 | +14 days |
| 10 Weeks | `immunization_at_10_weeks` | Day 70 | PCV 2 | +14 days |
| 10 Weeks | `immunization_at_10_weeks` | Day 70 | DPT-HepB-Hib 2 | +14 days |
| 14 Weeks | `immunization_at_14_weeks` | Day 98 | Polio 3 | +14 days |
| 14 Weeks | `immunization_at_14_weeks` | Day 98 | PCV 3 | +14 days |
| 14 Weeks | `immunization_at_14_weeks` | Day 98 | IPV 2 | +14 days |
| 14 Weeks | `immunization_at_14_weeks` | Day 98 | DPT-HepB-Hib 3 | +14 days |
| 9 Months | `immunization_at_9_months` | Day 270 | Measles-Rubella 1 | +14 days |
| 9 Months | `immunization_at_9_months` | Day 270 | Yellow Fever | +14 days |
| 18 Months | `immunization_at_18_months` | Day 540 | Measles-Rubella 2 | +14 days |

Malaria vaccine doses:

| Dose | Due Age | Max Window |
|---|---:|---:|
| Malaria Vaccine Dose 1 | Day 180 | Day 194 |
| Malaria Vaccine Dose 2 | Day 210 | Day 224 |
| Malaria Vaccine Dose 3 | Day 240 | Day 254 |
| Malaria Vaccine Dose 4 | Day 540 | Day 554 |

HPV:

```text
Eligible group: girls aged 9-19 years
Dose: HPV Vaccine Dose 1
```

## Create Tables

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS dwh.ref_immunization_vaccine_map (
    programme text NOT NULL,
    vaccine_name text NOT NULL,
    antigen_group text NOT NULL,
    dose_label text NOT NULL DEFAULT '',
    dose_number integer,
    schedule_group text,
    due_age_days integer,
    max_age_days integer,
    eligibility_sex text,
    min_age_years integer,
    max_age_years integer,
    include_in_under5_reports boolean DEFAULT false,
    include_in_child_immunization_reports boolean DEFAULT false,
    include_in_malaria_reports boolean DEFAULT false,
    include_in_hpv_reports boolean DEFAULT false,
    is_fic_required boolean DEFAULT false,
    dwh_created_at timestamptz DEFAULT clock_timestamp(),
    dwh_updated_at timestamptz DEFAULT clock_timestamp(),
    PRIMARY KEY (programme, vaccine_name, dose_label)
);

CREATE TABLE IF NOT EXISTS dwh.fact_immunizations (
    immunization_fact_id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    questionnaire_response_id text NOT NULL,
    source_form text NOT NULL,
    questionnaire text,
    patient_id text NOT NULL,
    encounter_id text,
    administered_date date NOT NULL,
    recorded_at timestamptz,
    vaccine_name text NOT NULL,
    programme text NOT NULL DEFAULT 'unknown',
    antigen_group text,
    dose_label text NOT NULL DEFAULT '',
    dose_number integer,
    schedule_group text,
    source_link_id text NOT NULL,
    source_task_id text,
    immunization_resource_id text,
    practitioner_id text,
    care_team_id text,
    location_id text,
    organization_id text,
    patient_age_days_at_admin integer,
    patient_age_months_at_admin integer,
    patient_age_years_at_admin integer,
    is_under_5_at_admin boolean,
    _airbyte_extracted_at timestamptz,
    dwh_created_at timestamptz DEFAULT clock_timestamp(),
    dwh_updated_at timestamptz DEFAULT clock_timestamp(),
    UNIQUE (questionnaire_response_id, source_link_id, vaccine_name, dose_label)
);

CREATE TABLE IF NOT EXISTS dwh.fact_immunization_status (
    reporting_period_start date NOT NULL,
    reporting_period_end date NOT NULL,
    patient_id text NOT NULL,
    patient_name text,
    gender text,
    birth_date date,
    age_months_at_period_end integer,
    age_years_at_period_end integer,
    caregiver_name text,
    caregiver_phone text,
    household_id text,
    village_id text,
    village_name text,
    parish_id text,
    parish_name text,
    health_facility_id text,
    health_facility_name text,
    subcounty_id text,
    subcounty_name text,
    district_id text,
    district_name text,
    county_id text,
    county_name text,
    region_id text,
    region_name text,
    country_name text,
    reporting_facility_name text,
    reporting_dhis2_orgunit_uid text,
    patient_practitioner_id text,
    patient_care_team_id text,
    patient_organization_id text,
    assigned_practitioner_id text,
    assigned_vht_name text,
    assigned_vht_phone text,
    programme text NOT NULL,
    vaccine_name text NOT NULL,
    antigen_group text NOT NULL,
    dose_label text NOT NULL DEFAULT '',
    dose_number integer,
    schedule_group text,
    due_date date,
    max_due_date date,
    days_overdue integer,
    is_eligible boolean DEFAULT false,
    is_due boolean DEFAULT false,
    is_received boolean DEFAULT false,
    received_date date,
    is_late_received boolean DEFAULT false,
    is_zero_dose boolean DEFAULT false,
    is_under_immunised boolean DEFAULT false,
    is_fully_immunised_child boolean DEFAULT false,
    is_recovered_this_period boolean DEFAULT false,
    follow_up_status text,
    barrier_reason text,
    dwh_created_at timestamptz DEFAULT clock_timestamp(),
    dwh_updated_at timestamptz DEFAULT clock_timestamp(),
    PRIMARY KEY (reporting_period_start, reporting_period_end, patient_id, programme, vaccine_name, dose_label)
);
```

## Indexes

```sql
CREATE INDEX IF NOT EXISTS idx_ref_imm_map_programme
ON dwh.ref_immunization_vaccine_map (programme);

CREATE INDEX IF NOT EXISTS idx_ref_imm_map_antigen
ON dwh.ref_immunization_vaccine_map (programme, antigen_group, dose_number);

CREATE INDEX IF NOT EXISTS idx_ref_imm_map_flags
ON dwh.ref_immunization_vaccine_map (
    include_in_child_immunization_reports,
    include_in_malaria_reports,
    include_in_hpv_reports
);

CREATE INDEX IF NOT EXISTS idx_fact_imm_patient_programme_vaccine
ON dwh.fact_immunizations (
    patient_id,
    programme,
    vaccine_name,
    dose_label,
    administered_date
);

CREATE INDEX IF NOT EXISTS idx_fact_imm_programme_date
ON dwh.fact_immunizations (programme, administered_date);

CREATE INDEX IF NOT EXISTS idx_fact_imm_airbyte
ON dwh.fact_immunizations (_airbyte_extracted_at);

CREATE INDEX IF NOT EXISTS idx_fact_imm_qr
ON dwh.fact_immunizations (questionnaire_response_id);

CREATE INDEX IF NOT EXISTS idx_dim_patients_birth_active_deceased
ON dwh.dim_patients (birth_date, active, is_deceased);

CREATE INDEX IF NOT EXISTS idx_dim_patients_gender_birth
ON dwh.dim_patients (gender, birth_date);

CREATE INDEX IF NOT EXISTS idx_fact_imm_status_period
ON dwh.fact_immunization_status (reporting_period_start, reporting_period_end);

CREATE INDEX IF NOT EXISTS idx_fact_imm_status_patient
ON dwh.fact_immunization_status (patient_id);

CREATE INDEX IF NOT EXISTS idx_fact_imm_status_due_missing
ON dwh.fact_immunization_status (
    reporting_period_start,
    reporting_period_end,
    programme,
    is_due,
    is_received
);

CREATE INDEX IF NOT EXISTS idx_fact_imm_status_location
ON dwh.fact_immunization_status (
    district_id,
    subcounty_id,
    health_facility_id,
    village_id
);

CREATE INDEX IF NOT EXISTS idx_fact_imm_status_zd
ON dwh.fact_immunization_status (
    reporting_period_start,
    reporting_period_end,
    is_zero_dose
);

CREATE INDEX IF NOT EXISTS idx_fact_imm_status_ui
ON dwh.fact_immunization_status (
    reporting_period_start,
    reporting_period_end,
    is_under_immunised
);
```

## Seed Vaccine Reference Map

```sql
INSERT INTO dwh.ref_immunization_vaccine_map
(
    programme,
    vaccine_name,
    antigen_group,
    dose_label,
    dose_number,
    schedule_group,
    due_age_days,
    max_age_days,
    eligibility_sex,
    min_age_years,
    max_age_years,
    include_in_under5_reports,
    include_in_child_immunization_reports,
    include_in_malaria_reports,
    include_in_hpv_reports,
    is_fic_required
)
VALUES
('child_immunization','BCG at Birth Vaccine','BCG','Birth',0,'immunization_at_birth',0,7,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','HepB 0 at Birth Vaccine','HepB','Dose 0',0,'immunization_at_birth',0,7,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','Polio 0 at Birth Vaccine','Polio','Dose 0',0,'immunization_at_birth',0,14,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','Polio 1 at 6 weeks Vaccine','Polio','Dose 1',1,'immunization_at_6_weeks',42,56,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','Rota 1 at 6 weeks Vaccine','Rota','Dose 1',1,'immunization_at_6_weeks',42,56,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','PCV 1 at 6 weeks Vaccine','PCV','Dose 1',1,'immunization_at_6_weeks',42,56,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','IPV 1 at 6 weeks Vaccine','IPV','Dose 1',1,'immunization_at_6_weeks',42,56,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','DPT-HepB Hib 1 at 6 weeks Vaccine','DPT-HepB-Hib','Dose 1',1,'immunization_at_6_weeks',42,56,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','Polio 2 at 10 weeks Vaccine','Polio','Dose 2',2,'immunization_at_10_weeks',70,84,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','Rota 2 at 10 weeks Vaccine','Rota','Dose 2',2,'immunization_at_10_weeks',70,84,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','PCV 2 at 10 weeks Vaccine','PCV','Dose 2',2,'immunization_at_10_weeks',70,84,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','DPT-HepB Hib 2 at 10 weeks Vaccine','DPT-HepB-Hib','Dose 2',2,'immunization_at_10_weeks',70,84,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','Polio 3 at 14 weeks Vaccine','Polio','Dose 3',3,'immunization_at_14_weeks',98,112,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','PCV 3 at 14 weeks Vaccine','PCV','Dose 3',3,'immunization_at_14_weeks',98,112,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','IPV 2 at 14 weeks Vaccine','IPV','Dose 2',2,'immunization_at_14_weeks',98,112,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','DPT-HepB Hib 3 at 14 weeks Vaccine','DPT-HepB-Hib','Dose 3',3,'immunization_at_14_weeks',98,112,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','Measles Rubella 1 at 9 months Vaccine','Measles-Rubella','Dose 1',1,'immunization_at_9_months',270,284,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','Yellow Fever at 9 months Vaccine','Yellow Fever','Dose 1',1,'immunization_at_9_months',270,284,NULL,NULL,NULL,true,true,false,false,true),
('child_immunization','Measles Rubella 2 at 18 months Vaccine','Measles-Rubella','Dose 2',2,'immunization_at_18_months',540,554,NULL,NULL,NULL,true,true,false,false,true),
('malaria_vaccine','Malaria Vaccine Dose 1','Malaria','Dose 1',1,'malaria_dose_1',180,194,NULL,NULL,NULL,true,false,true,false,false),
('malaria_vaccine','Malaria Vaccine Dose 2','Malaria','Dose 2',2,'malaria_dose_2',210,224,NULL,NULL,NULL,true,false,true,false,false),
('malaria_vaccine','Malaria Vaccine Dose 3','Malaria','Dose 3',3,'malaria_dose_3',240,254,NULL,NULL,NULL,true,false,true,false,false),
('malaria_vaccine','Malaria Vaccine Dose 4','Malaria','Dose 4',4,'malaria_dose_4',540,554,NULL,NULL,NULL,true,false,true,false,false),
('hpv_vaccine','HPV Vaccine','HPV','Dose 1',1,'hpv_dose_1',NULL,NULL,'female',9,19,false,false,false,true,false)
ON CONFLICT (programme, vaccine_name, dose_label)
DO UPDATE SET
    antigen_group = EXCLUDED.antigen_group,
    dose_number = EXCLUDED.dose_number,
    schedule_group = EXCLUDED.schedule_group,
    due_age_days = EXCLUDED.due_age_days,
    max_age_days = EXCLUDED.max_age_days,
    eligibility_sex = EXCLUDED.eligibility_sex,
    min_age_years = EXCLUDED.min_age_years,
    max_age_years = EXCLUDED.max_age_years,
    include_in_under5_reports = EXCLUDED.include_in_under5_reports,
    include_in_child_immunization_reports = EXCLUDED.include_in_child_immunization_reports,
    include_in_malaria_reports = EXCLUDED.include_in_malaria_reports,
    include_in_hpv_reports = EXCLUDED.include_in_hpv_reports,
    is_fic_required = EXCLUDED.is_fic_required,
    dwh_updated_at = clock_timestamp();
```

## Procedure: Refresh Administered Immunization Facts

This procedure extracts administered vaccine events from QuestionnaireResponse resources.

```sql
CREATE OR REPLACE PROCEDURE dwh.refresh_immunization_facts()
LANGUAGE plpgsql
AS $$
DECLARE
    v_table_name text := 'dwh.immunization_facts';
    v_started_at timestamptz := clock_timestamp();
    v_previous_watermark timestamptz;
    v_refresh_from timestamptz;
    v_new_watermark timestamptz;
    v_rows_processed integer := 0;
BEGIN
    SELECT last_successful_airbyte_extracted_at
    INTO v_previous_watermark
    FROM dwh.refresh_state
    WHERE table_name = v_table_name;

    v_refresh_from := COALESCE(v_previous_watermark - INTERVAL '1 day', TIMESTAMPTZ '1900-01-01');

    INSERT INTO dwh.refresh_state (table_name, last_run_started_at, status, error_message)
    VALUES (v_table_name, v_started_at, 'running', NULL)
    ON CONFLICT (table_name)
    DO UPDATE SET last_run_started_at = EXCLUDED.last_run_started_at, status = 'running', error_message = NULL;

    WITH RECURSIVE changed_qrs AS (
        SELECT resource, _airbyte_extracted_at
        FROM airbyte.questionnaire_response
        WHERE _airbyte_extracted_at >= v_refresh_from
          AND resource ->> 'resourceType' = 'QuestionnaireResponse'
          AND (
              resource ->> 'questionnaire' IN (
                  'Questionnaire/child-immunization-record-all',
                  'Questionnaire/malaria-vaccine-record',
                  'Questionnaire/hpv-vaccine-record',
                  'Questionnaire/6965f0fc-e0e9-449e-941a-c6e708cc9dd6'
              )
              OR resource::text ILIKE '%vaccine%'
          )
    ),
    deleted_old AS (
        DELETE FROM dwh.fact_immunizations fi
        USING changed_qrs q
        WHERE fi.questionnaire_response_id = q.resource ->> 'id'
        RETURNING fi.questionnaire_response_id
    ),
    qr_items AS (
        SELECT q.resource ->> 'id' AS questionnaire_response_id, q.resource, q._airbyte_extracted_at, item
        FROM changed_qrs q
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(q.resource -> 'item', '[]'::jsonb)) item
        UNION ALL
        SELECT qi.questionnaire_response_id, qi.resource, qi._airbyte_extracted_at, child_item
        FROM qr_items qi
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(qi.item -> 'item', '[]'::jsonb)) child_item
    ),
    qr_base AS (
        SELECT
            q.resource ->> 'id' AS questionnaire_response_id,
            q.resource,
            q._airbyte_extracted_at,
            q.resource ->> 'questionnaire' AS questionnaire,
            regexp_replace(q.resource #>> '{subject,reference}', '^Patient/', '') AS subject_patient_id,
            regexp_replace(q.resource #>> '{encounter,reference}', '^Encounter/', '') AS encounter_id,
            regexp_replace(q.resource #>> '{author,reference}', '^Practitioner/', '') AS author_practitioner_id,
            q.resource ->> 'authored' AS authored_text,
            (SELECT tag ->> 'code' FROM jsonb_array_elements(COALESCE(q.resource #> '{meta,tag}', '[]'::jsonb)) tag WHERE tag ->> 'system' = 'https://smartregister.org/care-team-tag-id' LIMIT 1) AS care_team_id,
            (SELECT tag ->> 'code' FROM jsonb_array_elements(COALESCE(q.resource #> '{meta,tag}', '[]'::jsonb)) tag WHERE tag ->> 'system' = 'https://smartregister.org/location-tag-id' LIMIT 1) AS location_id,
            (SELECT tag ->> 'code' FROM jsonb_array_elements(COALESCE(q.resource #> '{meta,tag}', '[]'::jsonb)) tag WHERE tag ->> 'system' = 'https://smartregister.org/organisation-tag-id' LIMIT 1) AS organization_id,
            (SELECT tag ->> 'code' FROM jsonb_array_elements(COALESCE(q.resource #> '{meta,tag}', '[]'::jsonb)) tag WHERE tag ->> 'system' = 'https://smartregister.org/practitioner-tag-id' LIMIT 1) AS practitioner_id
        FROM changed_qrs q
    ),
    item_values AS (
        SELECT
            questionnaire_response_id,
            MAX(item #>> '{answer,0,valueString}') FILTER (WHERE item ->> 'linkId' IN ('patient-id', 'patient-id-hidden')) AS patient_id_answer,
            MAX(item #>> '{answer,0,valueDate}') FILTER (WHERE item ->> 'linkId' = 'vaccines-date') AS vaccines_date,
            MAX(item #>> '{answer,0,valueDate}') FILTER (WHERE item ->> 'linkId' = '1e1f0f3b-58de-41b4-8db0-6c4b033cce57') AS single_immunization_date,
            MAX(item #>> '{answer,0,valueString}') FILTER (WHERE item ->> 'linkId' = 'vaccine-name') AS single_vaccine_name,
            MAX(item #>> '{answer,0,valueCoding,code}') FILTER (WHERE item ->> 'linkId' = 'received-malaria-vaccine') AS received_malaria_code,
            MAX(item #>> '{answer,0,valueBoolean}') FILTER (WHERE item ->> 'linkId' = 'hpv-vaccine-received') AS hpv_received,
            MAX(item #>> '{answer,0,valueDate}') FILTER (WHERE item ->> 'linkId' = 'hpv-vaccine-date') AS hpv_date,
            MAX(item #>> '{answer,0,valueBoolean}') FILTER (WHERE item ->> 'linkId' = 'dose-1-received') AS dose_1_received,
            MAX(item #>> '{answer,0,valueDate}') FILTER (WHERE item ->> 'linkId' = 'dose-1-date') AS dose_1_date,
            MAX(item #>> '{answer,0,valueBoolean}') FILTER (WHERE item ->> 'linkId' = 'dose-2-received') AS dose_2_received,
            MAX(item #>> '{answer,0,valueDate}') FILTER (WHERE item ->> 'linkId' = 'dose-2-date') AS dose_2_date,
            MAX(item #>> '{answer,0,valueBoolean}') FILTER (WHERE item ->> 'linkId' = 'dose-3-received') AS dose_3_received,
            MAX(item #>> '{answer,0,valueDate}') FILTER (WHERE item ->> 'linkId' = 'dose-3-date') AS dose_3_date,
            MAX(item #>> '{answer,0,valueBoolean}') FILTER (WHERE item ->> 'linkId' = 'dose-4-received') AS dose_4_received,
            MAX(item #>> '{answer,0,valueDate}') FILTER (WHERE item ->> 'linkId' = 'dose-4-date') AS dose_4_date
        FROM qr_items
        GROUP BY questionnaire_response_id
    ),
    record_all_rows AS (
        SELECT b.questionnaire_response_id, 'child_immunization_record_all' AS source_form, b.questionnaire,
               COALESCE(b.subject_patient_id, iv.patient_id_answer) AS patient_id, b.encounter_id,
               iv.vaccines_date::date AS administered_date, b.authored_text::timestamptz AS recorded_at,
               ans #>> '{valueReference,display}' AS vaccine_name, qi.item ->> 'linkId' AS source_link_id,
               ans #>> '{valueReference,reference}' AS source_task_id, b.practitioner_id, b.author_practitioner_id,
               b.care_team_id, b.location_id, b.organization_id, b._airbyte_extracted_at
        FROM qr_items qi
        JOIN qr_base b ON b.questionnaire_response_id = qi.questionnaire_response_id
        JOIN item_values iv ON iv.questionnaire_response_id = b.questionnaire_response_id
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(qi.item -> 'answer', '[]'::jsonb)) ans
        WHERE b.questionnaire = 'Questionnaire/child-immunization-record-all'
          AND qi.item ->> 'linkId' LIKE 'selected-vaccines-%'
          AND ans #>> '{valueReference,display}' IS NOT NULL
          AND iv.vaccines_date IS NOT NULL
    ),
    single_rows AS (
        SELECT b.questionnaire_response_id, 'child_immunization_single' AS source_form, b.questionnaire,
               COALESCE(b.subject_patient_id, iv.patient_id_answer) AS patient_id, b.encounter_id,
               iv.single_immunization_date::date AS administered_date, b.authored_text::timestamptz AS recorded_at,
               iv.single_vaccine_name AS vaccine_name, 'vaccine-name' AS source_link_id,
               NULL::text AS source_task_id, b.practitioner_id, b.author_practitioner_id,
               b.care_team_id, b.location_id, b.organization_id, b._airbyte_extracted_at
        FROM qr_base b
        JOIN item_values iv ON iv.questionnaire_response_id = b.questionnaire_response_id
        WHERE iv.single_vaccine_name IS NOT NULL
          AND iv.single_immunization_date IS NOT NULL
          AND b.questionnaire <> 'Questionnaire/child-immunization-record-all'
    ),
    malaria_rows AS (
        SELECT b.questionnaire_response_id, 'malaria_vaccine_record' AS source_form, b.questionnaire,
               COALESCE(b.subject_patient_id, iv.patient_id_answer) AS patient_id, b.encounter_id,
               d.administered_date, b.authored_text::timestamptz AS recorded_at, d.vaccine_name,
               d.source_link_id, NULL::text AS source_task_id, b.practitioner_id, b.author_practitioner_id,
               b.care_team_id, b.location_id, b.organization_id, b._airbyte_extracted_at
        FROM qr_base b
        JOIN item_values iv ON iv.questionnaire_response_id = b.questionnaire_response_id
        CROSS JOIN LATERAL (
            VALUES
                ('dose-1-date', 'Malaria Vaccine Dose 1', iv.dose_1_received, iv.dose_1_date::date),
                ('dose-2-date', 'Malaria Vaccine Dose 2', iv.dose_2_received, iv.dose_2_date::date),
                ('dose-3-date', 'Malaria Vaccine Dose 3', iv.dose_3_received, iv.dose_3_date::date),
                ('dose-4-date', 'Malaria Vaccine Dose 4', iv.dose_4_received, iv.dose_4_date::date)
        ) d(source_link_id, vaccine_name, received, administered_date)
        WHERE b.questionnaire = 'Questionnaire/malaria-vaccine-record'
          AND iv.received_malaria_code = 'yes'
          AND d.received = 'true'
          AND d.administered_date IS NOT NULL
    ),
    hpv_rows AS (
        SELECT b.questionnaire_response_id, 'hpv_vaccine_record' AS source_form, b.questionnaire,
               COALESCE(b.subject_patient_id, iv.patient_id_answer) AS patient_id, b.encounter_id,
               iv.hpv_date::date AS administered_date, b.authored_text::timestamptz AS recorded_at,
               'HPV Vaccine' AS vaccine_name, 'hpv-vaccine-date' AS source_link_id,
               NULL::text AS source_task_id, b.practitioner_id, b.author_practitioner_id,
               b.care_team_id, b.location_id, b.organization_id, b._airbyte_extracted_at
        FROM qr_base b
        JOIN item_values iv ON iv.questionnaire_response_id = b.questionnaire_response_id
        WHERE b.questionnaire = 'Questionnaire/hpv-vaccine-record'
          AND iv.hpv_received = 'true'
          AND iv.hpv_date IS NOT NULL
    ),
    all_rows AS (
        SELECT * FROM record_all_rows
        UNION ALL SELECT * FROM single_rows
        UNION ALL SELECT * FROM malaria_rows
        UNION ALL SELECT * FROM hpv_rows
    )
    INSERT INTO dwh.fact_immunizations (
        questionnaire_response_id, source_form, questionnaire, patient_id, encounter_id,
        administered_date, recorded_at, vaccine_name, programme, antigen_group, dose_label,
        dose_number, schedule_group, source_link_id, source_task_id, practitioner_id,
        care_team_id, location_id, organization_id, patient_age_days_at_admin,
        patient_age_months_at_admin, patient_age_years_at_admin, is_under_5_at_admin,
        _airbyte_extracted_at, dwh_updated_at
    )
    SELECT
        r.questionnaire_response_id, r.source_form, r.questionnaire, r.patient_id, r.encounter_id,
        r.administered_date, r.recorded_at, r.vaccine_name,
        COALESCE(m.programme, 'unknown'), m.antigen_group, COALESCE(m.dose_label, ''),
        m.dose_number, m.schedule_group, r.source_link_id, r.source_task_id,
        COALESCE(r.practitioner_id, r.author_practitioner_id), r.care_team_id, r.location_id, r.organization_id,
        CASE WHEN p.birth_date IS NOT NULL THEN r.administered_date - p.birth_date END,
        CASE WHEN p.birth_date IS NOT NULL THEN dwh.age_in_months(p.birth_date, r.administered_date) END,
        CASE WHEN p.birth_date IS NOT NULL THEN dwh.age_in_years(p.birth_date, r.administered_date) END,
        CASE WHEN p.birth_date IS NOT NULL THEN r.administered_date < p.birth_date + INTERVAL '5 years' END,
        r._airbyte_extracted_at, clock_timestamp()
    FROM all_rows r
    LEFT JOIN dwh.ref_immunization_vaccine_map m ON m.vaccine_name = r.vaccine_name
    LEFT JOIN dwh.dim_patients p ON p.patient_id = r.patient_id
    WHERE r.patient_id IS NOT NULL AND r.administered_date IS NOT NULL AND r.vaccine_name IS NOT NULL
    ON CONFLICT (questionnaire_response_id, source_link_id, vaccine_name, dose_label)
    DO UPDATE SET
        patient_id = EXCLUDED.patient_id,
        encounter_id = EXCLUDED.encounter_id,
        administered_date = EXCLUDED.administered_date,
        recorded_at = EXCLUDED.recorded_at,
        programme = EXCLUDED.programme,
        antigen_group = EXCLUDED.antigen_group,
        dose_number = EXCLUDED.dose_number,
        schedule_group = EXCLUDED.schedule_group,
        source_task_id = EXCLUDED.source_task_id,
        practitioner_id = EXCLUDED.practitioner_id,
        care_team_id = EXCLUDED.care_team_id,
        location_id = EXCLUDED.location_id,
        organization_id = EXCLUDED.organization_id,
        patient_age_days_at_admin = EXCLUDED.patient_age_days_at_admin,
        patient_age_months_at_admin = EXCLUDED.patient_age_months_at_admin,
        patient_age_years_at_admin = EXCLUDED.patient_age_years_at_admin,
        is_under_5_at_admin = EXCLUDED.is_under_5_at_admin,
        _airbyte_extracted_at = EXCLUDED._airbyte_extracted_at,
        dwh_updated_at = clock_timestamp();

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;

    SELECT MAX(_airbyte_extracted_at)
    INTO v_new_watermark
    FROM airbyte.questionnaire_response
    WHERE _airbyte_extracted_at >= v_refresh_from
      AND resource ->> 'resourceType' = 'QuestionnaireResponse';

    UPDATE dwh.refresh_state
    SET status = 'success',
        rows_processed = v_rows_processed,
        last_successful_airbyte_extracted_at = COALESCE(v_new_watermark, v_previous_watermark),
        last_run_completed_at = clock_timestamp(),
        error_message = NULL
    WHERE table_name = v_table_name;

EXCEPTION WHEN OTHERS THEN
    UPDATE dwh.refresh_state
    SET status = 'failed',
        last_run_completed_at = clock_timestamp(),
        error_message = SQLERRM
    WHERE table_name = v_table_name;
    RAISE;
END;
$$;
```

## Procedure: Refresh Immunization Status

This procedure builds the per-patient per-dose status table for a given reporting period.

VHT name is now resolved via a `vht_lookup` CTE that reads from `dwh.dim_practitioner_assignments`. `assigned_vht_phone` remains NULL — phone numbers are not available for practitioners in the current DWH.

```sql
CREATE OR REPLACE PROCEDURE dwh.refresh_immunization_status(
    p_period_start date,
    p_period_end date
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_table_name text := 'dwh.immunization_status:' || p_period_start::text;
    v_rows_processed integer := 0;
BEGIN
    INSERT INTO dwh.refresh_state (table_name, last_run_started_at, status, error_message)
    VALUES (v_table_name, clock_timestamp(), 'running', NULL)
    ON CONFLICT (table_name)
    DO UPDATE SET
        last_run_started_at = EXCLUDED.last_run_started_at,
        status = 'running',
        error_message = NULL;

    DELETE FROM dwh.fact_immunization_status
    WHERE reporting_period_start = p_period_start
      AND reporting_period_end = p_period_end;

    WITH vht_lookup AS (
        -- Deduplicated VHT name lookup — one row per practitioner.
        SELECT DISTINCT ON (practitioner_id)
            practitioner_id,
            practitioner_name AS vht_name
        FROM dwh.dim_practitioner_assignments
        WHERE is_vht = true
          AND COALESCE(active, true) = true
        ORDER BY practitioner_id
    ),
    eligible_schedule AS (
        SELECT
            p.patient_id,
            p.patient_name,
            p.gender,
            p.birth_date,
            dwh.age_in_months(p.birth_date, p_period_end) AS age_months_at_period_end,
            dwh.age_in_years(p.birth_date, p_period_end) AS age_years_at_period_end,
            p.phone_number AS caregiver_phone,
            p.household_id,
            p.practitioner_id AS patient_practitioner_id,
            p.care_team_id AS patient_care_team_id,
            p.organization_id AS patient_organization_id,
            p.country_name,
            p.region_id,
            p.region_name,
            p.district_id,
            p.district_name,
            p.county_id,
            p.county_name,
            p.subcounty_id,
            p.subcounty_name,
            p.parish_id,
            p.parish_name,
            p.health_facility_id,
            p.health_facility_name,
            p.village_id,
            p.village_name,
            p.reporting_facility_name,
            p.reporting_dhis2_orgunit_uid,
            vht.vht_name,
            m.*,
            CASE WHEN m.due_age_days IS NOT NULL THEN (p.birth_date + (m.due_age_days || ' days')::interval)::date END AS due_date,
            CASE WHEN m.max_age_days IS NOT NULL THEN (p.birth_date + (m.max_age_days || ' days')::interval)::date END AS max_due_date
        FROM dwh.dim_patients p
        JOIN dwh.ref_immunization_vaccine_map m ON true
        LEFT JOIN vht_lookup vht ON vht.practitioner_id = p.practitioner_id
        WHERE p.birth_date IS NOT NULL
          AND COALESCE(p.active, true) = true
          AND COALESCE(p.is_deceased, false) = false
          AND (
              ((m.include_in_child_immunization_reports OR m.include_in_malaria_reports)
                AND p.birth_date > p_period_end - INTERVAL '5 years')
              OR
              (m.include_in_hpv_reports
                AND lower(COALESCE(p.gender, '')) IN ('female', 'f')
                AND dwh.age_in_years(p.birth_date, p_period_end) BETWEEN 9 AND 19)
          )
    ),
    received AS (
        SELECT DISTINCT ON (patient_id, programme, vaccine_name, dose_label)
            patient_id,
            programme,
            vaccine_name,
            dose_label,
            administered_date AS received_date
        FROM dwh.fact_immunizations
        WHERE administered_date < p_period_end
        ORDER BY patient_id, programme, vaccine_name, dose_label, administered_date
    ),
    received_summary AS (
        SELECT
            patient_id,
            COUNT(*) FILTER (
                WHERE administered_date < p_period_end
                  AND programme IN ('child_immunization', 'malaria_vaccine')
            ) AS under5_received_count
        FROM dwh.fact_immunizations
        GROUP BY patient_id
    ),
    status_rows AS (
        SELECT
            p_period_start AS reporting_period_start,
            p_period_end AS reporting_period_end,
            es.patient_id,
            es.patient_name,
            es.gender,
            es.birth_date,
            es.age_months_at_period_end,
            es.age_years_at_period_end,
            NULL::text AS caregiver_name,
            es.caregiver_phone,
            es.household_id,
            es.country_name,
            es.region_id,
            es.region_name,
            es.district_id,
            es.district_name,
            es.county_id,
            es.county_name,
            es.subcounty_id,
            es.subcounty_name,
            es.parish_id,
            es.parish_name,
            es.health_facility_id,
            es.health_facility_name,
            es.village_id,
            es.village_name,
            es.reporting_facility_name,
            es.reporting_dhis2_orgunit_uid,
            es.patient_practitioner_id,
            es.patient_care_team_id,
            es.patient_organization_id,
            es.patient_practitioner_id AS assigned_practitioner_id,
            es.vht_name AS assigned_vht_name,
            NULL::text AS assigned_vht_phone,  -- not available in dim_practitioner_assignments
            es.programme,
            es.vaccine_name,
            es.antigen_group,
            es.dose_label,
            es.dose_number,
            es.schedule_group,
            es.due_date,
            es.max_due_date,
            CASE WHEN es.due_date < p_period_end AND r.received_date IS NULL THEN p_period_end - es.due_date END AS days_overdue,
            true AS is_eligible,
            COALESCE(es.due_date < p_period_end, false) AS is_due,
            r.received_date IS NOT NULL AS is_received,
            r.received_date,
            CASE WHEN r.received_date IS NOT NULL AND es.max_due_date IS NOT NULL AND r.received_date > es.max_due_date THEN true ELSE false END AS is_late_received,
            CASE WHEN es.include_in_under5_reports AND COALESCE(rs.under5_received_count, 0) = 0 THEN true ELSE false END AS is_zero_dose,
            CASE WHEN es.due_date < p_period_end AND r.received_date IS NULL THEN true ELSE false END AS is_under_immunised,
            CASE WHEN r.received_date >= p_period_start AND r.received_date < p_period_end THEN true ELSE false END AS is_recovered_this_period,
            CASE
                WHEN es.due_date IS NULL THEN 'eligible'
                WHEN es.due_date >= p_period_end THEN 'not_due'
                WHEN r.received_date IS NOT NULL THEN 'received'
                ELSE 'due_missing'
            END AS follow_up_status,
            es.is_fic_required
        FROM eligible_schedule es
        LEFT JOIN received r
          ON r.patient_id = es.patient_id
         AND r.programme = es.programme
         AND r.vaccine_name = es.vaccine_name
         AND r.dose_label = es.dose_label
        LEFT JOIN received_summary rs
          ON rs.patient_id = es.patient_id
    ),
    fic AS (
        SELECT
            patient_id,
            COALESCE(bool_and(is_received) FILTER (
                WHERE programme = 'child_immunization'
                  AND is_fic_required
                  AND is_due
            ), false) AS is_fully_immunised_child
        FROM status_rows
        GROUP BY patient_id
    )
    INSERT INTO dwh.fact_immunization_status (
        reporting_period_start,
        reporting_period_end,
        patient_id,
        patient_name,
        gender,
        birth_date,
        age_months_at_period_end,
        age_years_at_period_end,
        caregiver_name,
        caregiver_phone,
        household_id,
        village_id,
        parish_id,
        health_facility_id,
        subcounty_id,
        district_id,
        assigned_practitioner_id,
        assigned_vht_name,
        assigned_vht_phone,
        programme,
        vaccine_name,
        antigen_group,
        dose_label,
        dose_number,
        schedule_group,
        due_date,
        max_due_date,
        days_overdue,
        is_eligible,
        is_due,
        is_received,
        received_date,
        is_late_received,
        is_zero_dose,
        is_under_immunised,
        is_fully_immunised_child,
        is_recovered_this_period,
        follow_up_status,
        barrier_reason,
        dwh_updated_at,
        country_name,
        region_id,
        region_name,
        district_name,
        county_id,
        county_name,
        subcounty_name,
        parish_name,
        health_facility_name,
        village_name,
        reporting_facility_name,
        reporting_dhis2_orgunit_uid,
        patient_practitioner_id,
        patient_care_team_id,
        patient_organization_id
    )
    SELECT
        s.reporting_period_start,
        s.reporting_period_end,
        s.patient_id,
        s.patient_name,
        s.gender,
        s.birth_date,
        s.age_months_at_period_end,
        s.age_years_at_period_end,
        s.caregiver_name,
        s.caregiver_phone,
        s.household_id,
        s.village_id,
        s.parish_id,
        s.health_facility_id,
        s.subcounty_id,
        s.district_id,
        s.assigned_practitioner_id,
        s.assigned_vht_name,
        s.assigned_vht_phone,
        s.programme,
        s.vaccine_name,
        s.antigen_group,
        s.dose_label,
        s.dose_number,
        s.schedule_group,
        s.due_date,
        s.max_due_date,
        s.days_overdue,
        s.is_eligible,
        s.is_due,
        s.is_received,
        s.received_date,
        s.is_late_received,
        s.is_zero_dose,
        s.is_under_immunised,
        COALESCE(f.is_fully_immunised_child, false),
        s.is_recovered_this_period,
        s.follow_up_status,
        NULL::text,
        clock_timestamp(),
        s.country_name,
        s.region_id,
        s.region_name,
        s.district_name,
        s.county_id,
        s.county_name,
        s.subcounty_name,
        s.parish_name,
        s.health_facility_name,
        s.village_name,
        s.reporting_facility_name,
        s.reporting_dhis2_orgunit_uid,
        s.patient_practitioner_id,
        s.patient_care_team_id,
        s.patient_organization_id
    FROM status_rows s
    LEFT JOIN fic f
      ON f.patient_id = s.patient_id;

    GET DIAGNOSTICS v_rows_processed = ROW_COUNT;

    UPDATE dwh.refresh_state
    SET
        status = 'success',
        rows_processed = v_rows_processed,
        last_run_completed_at = clock_timestamp(),
        error_message = NULL
    WHERE table_name = v_table_name;

EXCEPTION WHEN OTHERS THEN
    UPDATE dwh.refresh_state
    SET
        status = 'failed',
        last_run_completed_at = clock_timestamp(),
        error_message = SQLERRM
    WHERE table_name = v_table_name;

    RAISE;
END;
$$;
```

## Monthly Aggregate Table

The `agg_immunization_monthly` table stores pre-aggregated coverage metrics for all months from programme start. It supports multiple geographic levels (national, district, subcounty, parish, health_facility, village) in a single table.

Use `antigen_group = 'ALL'` rows for patient-level KPIs (zero_dose_count, fic_count). Use antigen-specific rows for coverage (due_count, received_count).

```sql
CREATE TABLE IF NOT EXISTS dwh.agg_immunization_monthly (
    reporting_month             date        NOT NULL,
    location_level              text        NOT NULL,
    location_id                 text        NOT NULL,
    location_name               text,
    district_id                 text,
    district_name               text,
    subcounty_id                text,
    subcounty_name              text,
    parish_id                   text,
    parish_name                 text,
    health_facility_id          text,
    health_facility_name        text,
    village_id                  text,
    village_name                text,
    reporting_dhis2_orgunit_uid text,
    programme                   text        NOT NULL,
    antigen_group               text        NOT NULL,
    vaccine_name                text        NOT NULL,
    dose_label                  text        NOT NULL DEFAULT '',
    dose_number                 integer,
    due_count                   integer     NOT NULL DEFAULT 0,
    received_count              integer     NOT NULL DEFAULT 0,
    missed_count                integer     NOT NULL DEFAULT 0,
    late_received_count         integer     NOT NULL DEFAULT 0,
    zero_dose_count             integer     NOT NULL DEFAULT 0,
    under_immunised_count       integer     NOT NULL DEFAULT 0,
    fully_immunised_count       integer     NOT NULL DEFAULT 0,
    fic_eligible_count          integer     NOT NULL DEFAULT 0,
    dwh_updated_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (reporting_month, location_level, location_id, programme, antigen_group, dose_label)
);
```

### Aggregate refresh procedure

```sql
CREATE OR REPLACE PROCEDURE dwh.refresh_immunization_monthly_aggregate(
    p_period_start date,
    p_period_end   date
)
LANGUAGE plpgsql AS $$
BEGIN
    -- Full rebuild for the given period.
    -- Reads from fact_immunizations + dim_patients + ref_immunization_vaccine_map.
    -- Does NOT depend on fact_immunization_status.
    -- See sql/10-immunization/05-create-aggregate-table.sql for the full procedure.
END;
$$;
```

The full procedure is in [sql/10-immunization/05-create-aggregate-table.sql](sql/10-immunization/05-create-aggregate-table.sql).

### Daily aggregate wrapper

```sql
CREATE OR REPLACE PROCEDURE dwh.refresh_immunization_monthly_aggregate_current_and_previous_month()
LANGUAGE plpgsql AS $$
BEGIN
    CALL dwh.refresh_immunization_monthly_aggregate(
        (date_trunc('month', current_date) - INTERVAL '1 month')::date,
        date_trunc('month', current_date)::date
    );
    CALL dwh.refresh_immunization_monthly_aggregate(
        date_trunc('month', current_date)::date,
        (date_trunc('month', current_date) + INTERVAL '1 month')::date
    );
END;
$$;
```

### Historical backfill (run once after initial setup)

```sql
CREATE OR REPLACE PROCEDURE dwh.refresh_immunization_monthly_aggregate_backfill(
    p_from_date date DEFAULT '2023-09-01'::date
)
LANGUAGE plpgsql AS $$
DECLARE
    v_period_start date;
    v_period_end   date;
BEGIN
    v_period_start := date_trunc('month', p_from_date)::date;
    WHILE v_period_start <= date_trunc('month', current_date)::date LOOP
        v_period_end := (v_period_start + INTERVAL '1 month')::date;
        RAISE NOTICE 'Refreshing %', v_period_start;
        CALL dwh.refresh_immunization_monthly_aggregate(v_period_start, v_period_end);
        v_period_start := v_period_end;
    END LOOP;
END;
$$;
```

Run the backfill once:
```sql
CALL dwh.refresh_immunization_monthly_aggregate_backfill('2023-09-01');
```

## Wrapper Procedure

The daily wrapper refreshes the row-level status table and the monthly aggregate for the previous and current month, then cleans up status rows older than 3 months. The aggregate rows are NOT deleted — they accumulate permanently.

```sql
CREATE OR REPLACE PROCEDURE dwh.refresh_immunization_status_current_and_previous_month()
LANGUAGE plpgsql AS $$
DECLARE
    v_current_start date := date_trunc('month', current_date)::date;
    v_current_end   date := (date_trunc('month', current_date) + INTERVAL '1 month')::date;
    v_prev_start    date := (date_trunc('month', current_date) - INTERVAL '1 month')::date;
    v_prev_end      date := date_trunc('month', current_date)::date;
    v_cutoff        date := (date_trunc('month', current_date) - INTERVAL '2 months')::date;
BEGIN
    -- Row-level status: previous month then current month
    CALL dwh.refresh_immunization_status(v_prev_start, v_prev_end);
    CALL dwh.refresh_immunization_status(v_current_start, v_current_end);

    -- Monthly aggregate: same two months
    CALL dwh.refresh_immunization_monthly_aggregate(v_prev_start, v_prev_end);
    CALL dwh.refresh_immunization_monthly_aggregate(v_current_start, v_current_end);

    -- Rolling window cleanup: remove status rows older than 3 months
    DELETE FROM dwh.fact_immunization_status
    WHERE reporting_period_start < v_cutoff;
END;
$$;
```

## Daily Refresh Order

Add the immunization calls to `dwh.refresh_all_daily()` after program facts.

```sql
CALL dwh.refresh_program_facts_base();

CALL dwh.refresh_immunization_facts();
CALL dwh.refresh_immunization_status_current_and_previous_month();

CALL dwh.refresh_patient_program_status();
CALL dwh.refresh_supply_cebs_reporting();
```

`refresh_immunization_status_current_and_previous_month()` internally handles both the status table, the monthly aggregate refresh, and the rolling window cleanup.

## Manual Refresh

Refresh administered facts (incremental):

```sql
CALL dwh.refresh_immunization_facts();
```

Refresh row-level status for the current month:

```sql
CALL dwh.refresh_immunization_status(
    date_trunc('month', current_date)::date,
    (date_trunc('month', current_date) + INTERVAL '1 month')::date
);
```

Refresh row-level status for the previous month:

```sql
CALL dwh.refresh_immunization_status(
    (date_trunc('month', current_date) - INTERVAL '1 month')::date,
    date_trunc('month', current_date)::date
);
```

Refresh the monthly aggregate for a specific month:

```sql
CALL dwh.refresh_immunization_monthly_aggregate(
    '2026-05-01'::date,
    '2026-06-01'::date
);
```

## Validation Queries

Check refresh state:

```sql
SELECT *
FROM dwh.refresh_state
WHERE table_name LIKE 'dwh.immunization%'
ORDER BY last_run_started_at DESC;
```

Check facts:

```sql
SELECT source_form, programme, antigen_group, dose_label, COUNT(*)
FROM dwh.fact_immunizations
GROUP BY source_form, programme, antigen_group, dose_label
ORDER BY source_form, programme, antigen_group, dose_label;
```

Check status rows:

```sql
SELECT
    reporting_period_start,
    reporting_period_end,
    programme,
    COUNT(*) AS rows
FROM dwh.fact_immunization_status
GROUP BY reporting_period_start, reporting_period_end, programme
ORDER BY reporting_period_start DESC, programme;
```

## Monthly Overview

```sql
SELECT
    programme,
    antigen_group,
    dose_label,
    COUNT(*) FILTER (WHERE is_due) AS due,
    COUNT(*) FILTER (WHERE is_due AND is_received) AS received,
    COUNT(*) FILTER (WHERE is_due AND NOT is_received) AS missing,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_due AND is_received)
        / NULLIF(COUNT(*) FILTER (WHERE is_due), 0),
        1
    ) AS coverage_pct
FROM dwh.fact_immunization_status
WHERE reporting_period_start = date_trunc('month', current_date)::date
GROUP BY programme, antigen_group, dose_label, dose_number
ORDER BY programme, antigen_group, dose_number;
```

## Missing Dose Line List

```sql
SELECT
    patient_id,
    patient_name,
    gender,
    age_months_at_period_end,
    village_name,
    health_facility_name,
    assigned_vht_name,
    programme,
    antigen_group,
    dose_label,
    due_date,
    days_overdue,
    caregiver_phone
FROM dwh.fact_immunization_status
WHERE reporting_period_start = date_trunc('month', current_date)::date
  AND is_due = true
  AND is_received = false
ORDER BY days_overdue DESC;
```

## Zero-Dose Children

Because `is_zero_dose` is repeated across vaccine rows, use `DISTINCT`.

```sql
SELECT DISTINCT
    patient_id,
    patient_name,
    gender,
    age_months_at_period_end,
    village_name,
    health_facility_name,
    assigned_vht_name,
    caregiver_phone
FROM dwh.fact_immunization_status
WHERE reporting_period_start = date_trunc('month', current_date)::date
  AND is_zero_dose = true
ORDER BY health_facility_name, village_name, patient_name;
```

## Under-Immunized Children

```sql
SELECT DISTINCT
    patient_id,
    patient_name,
    gender,
    age_months_at_period_end,
    village_name,
    health_facility_name,
    assigned_vht_name,
    caregiver_phone
FROM dwh.fact_immunization_status
WHERE reporting_period_start = date_trunc('month', current_date)::date
  AND is_under_immunised = true
ORDER BY health_facility_name, village_name, patient_name;
```

## Under-Immunized Missing Antigens

```sql
SELECT
    patient_id,
    patient_name,
    age_months_at_period_end,
    village_name,
    health_facility_name,
    STRING_AGG(antigen_group || ' ' || dose_label, ', ' ORDER BY programme, antigen_group, dose_number) AS missing_antigens,
    MAX(days_overdue) AS max_days_overdue
FROM dwh.fact_immunization_status
WHERE reporting_period_start = date_trunc('month', current_date)::date
  AND is_due = true
  AND is_received = false
GROUP BY
    patient_id,
    patient_name,
    age_months_at_period_end,
    village_name,
    health_facility_name
ORDER BY max_days_overdue DESC;
```

## Zero-Dose Last Month, Immunized This Month

```sql
WITH last_month_zero_dose AS (
    SELECT DISTINCT patient_id
    FROM dwh.fact_immunization_status
    WHERE reporting_period_start = (date_trunc('month', current_date) - INTERVAL '1 month')::date
      AND is_zero_dose = true
),
this_month_immunized AS (
    SELECT DISTINCT
        patient_id,
        MIN(administered_date) AS first_immunization_this_month
    FROM dwh.fact_immunizations
    WHERE administered_date >= date_trunc('month', current_date)::date
      AND administered_date < (date_trunc('month', current_date) + INTERVAL '1 month')::date
      AND programme IN ('child_immunization', 'malaria_vaccine')
    GROUP BY patient_id
)
SELECT
    p.patient_id,
    p.patient_name,
    p.gender,
    p.birth_date,
    dwh.age_in_months(p.birth_date, current_date) AS age_months_today,
    p.village_name,
    p.health_facility_name,
    p.phone_number AS caregiver_phone,
    i.first_immunization_this_month
FROM last_month_zero_dose z
JOIN this_month_immunized i
  ON i.patient_id = z.patient_id
JOIN dwh.dim_patients p
  ON p.patient_id = z.patient_id
ORDER BY i.first_immunization_this_month, p.health_facility_name, p.village_name;
```

## Vaccine That Recovered A Zero-Dose Child

```sql
WITH last_month_zero_dose AS (
    SELECT DISTINCT patient_id
    FROM dwh.fact_immunization_status
    WHERE reporting_period_start = (date_trunc('month', current_date) - INTERVAL '1 month')::date
      AND is_zero_dose = true
)
SELECT
    fi.patient_id,
    p.patient_name,
    p.gender,
    p.village_name,
    p.health_facility_name,
    p.phone_number AS caregiver_phone,
    fi.administered_date,
    fi.programme,
    fi.antigen_group,
    fi.dose_label,
    fi.vaccine_name
FROM last_month_zero_dose z
JOIN dwh.fact_immunizations fi
  ON fi.patient_id = z.patient_id
JOIN dwh.dim_patients p
  ON p.patient_id = z.patient_id
WHERE fi.administered_date >= date_trunc('month', current_date)::date
  AND fi.administered_date < (date_trunc('month', current_date) + INTERVAL '1 month')::date
  AND fi.programme IN ('child_immunization', 'malaria_vaccine')
ORDER BY fi.administered_date, p.health_facility_name, p.village_name, p.patient_name;
```

## Facility Monthly Coverage Summary

```sql
SELECT
    health_facility_id,
    health_facility_name,
    programme,
    antigen_group,
    dose_label,
    COUNT(*) FILTER (WHERE is_due) AS due,
    COUNT(*) FILTER (WHERE is_due AND is_received) AS received,
    COUNT(*) FILTER (WHERE is_due AND NOT is_received) AS missing,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_due AND is_received)
        / NULLIF(COUNT(*) FILTER (WHERE is_due), 0),
        1
    ) AS coverage_pct
FROM dwh.fact_immunization_status
WHERE reporting_period_start = date_trunc('month', current_date)::date
GROUP BY
    health_facility_id,
    health_facility_name,
    programme,
    antigen_group,
    dose_label,
    dose_number
ORDER BY health_facility_name, programme, antigen_group, dose_number;
```

## District Monthly Coverage Summary

```sql
SELECT
    district_id,
    district_name,
    programme,
    antigen_group,
    dose_label,
    COUNT(*) FILTER (WHERE is_due) AS due,
    COUNT(*) FILTER (WHERE is_due AND is_received) AS received,
    COUNT(*) FILTER (WHERE is_due AND NOT is_received) AS missing,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_due AND is_received)
        / NULLIF(COUNT(*) FILTER (WHERE is_due), 0),
        1
    ) AS coverage_pct
FROM dwh.fact_immunization_status
WHERE reporting_period_start = date_trunc('month', current_date)::date
GROUP BY
    district_id,
    district_name,
    programme,
    antigen_group,
    dose_label,
    dose_number
ORDER BY district_name, programme, antigen_group, dose_number;
```

## Notes For Future Improvement

- **VHT name** — `assigned_vht_name` is now populated from `dim_practitioner_assignments` in the status refresh procedure. `assigned_vht_phone` remains NULL — phone numbers are not stored in the DWH for practitioners.
- **Historical backfill** — After initial setup, run `CALL dwh.refresh_immunization_monthly_aggregate_backfill('2023-09-01')` once to populate all history. Expect 5–15 minutes.
- **Rolling window cleanup** — `fact_immunization_status` is automatically trimmed to 3 months by the daily wrapper. The aggregate table is never deleted; it grows by one month per cycle.
- **Backdated corrections** — The daily wrapper refreshes only current + previous month. For corrections to older periods, manually call both `CALL dwh.refresh_immunization_status(start, end)` and `CALL dwh.refresh_immunization_monthly_aggregate(start, end)`.
- **Zero-dose Penta1 proxy** — Add `is_zero_dose_penta1` if MoH wants zero-dose to follow the standard EPI DPT/Penta1 proxy definition rather than the current any-dose definition.
- **Materialized views** — Add materialized views for common indicator sets if BI tool queries against `agg_immunization_monthly` become slow under multi-user load.
