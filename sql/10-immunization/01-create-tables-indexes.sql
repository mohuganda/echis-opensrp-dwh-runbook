-- Immunization reporting tables and indexes.
--
-- Source note: immunization data is extracted from airbyte.questionnaire_response,
-- NOT from airbyte.immunization or airbyte.observation. Those resources had extraction
-- errors during the Airbyte replication setup. QuestionnaireResponse forms carry the
-- full vaccination record including vaccine names, dates, and patient ID.
--
-- Run this file before 02-seed-vaccine-reference-map.sql and 03-create-refresh-procedures.sql.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ----------------------------------------------------------------------------
-- Reference table: vaccine schedule and normalized antigen/dose mapping
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS dwh.ref_immunization_vaccine_map (
    programme                           text        NOT NULL,
    vaccine_name                        text        NOT NULL,
    antigen_group                       text        NOT NULL,
    dose_label                          text        NOT NULL DEFAULT '',
    dose_number                         integer,
    schedule_group                      text,
    due_age_days                        integer,
    max_age_days                        integer,
    eligibility_sex                     text,
    min_age_years                       integer,
    max_age_years                       integer,
    include_in_under5_reports           boolean     DEFAULT false,
    include_in_child_immunization_reports boolean   DEFAULT false,
    include_in_malaria_reports          boolean     DEFAULT false,
    include_in_hpv_reports              boolean     DEFAULT false,
    is_fic_required                     boolean     DEFAULT false,
    dwh_created_at                      timestamptz DEFAULT clock_timestamp(),
    dwh_updated_at                      timestamptz DEFAULT clock_timestamp(),
    PRIMARY KEY (programme, vaccine_name, dose_label)
);

-- ----------------------------------------------------------------------------
-- Fact table: one row per administered vaccine dose
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS dwh.fact_immunizations (
    immunization_fact_id        uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
    questionnaire_response_id   text        NOT NULL,
    source_form                 text        NOT NULL,
    questionnaire               text,
    patient_id                  text        NOT NULL,
    encounter_id                text,
    administered_date           date        NOT NULL,
    recorded_at                 timestamptz,
    vaccine_name                text        NOT NULL,
    programme                   text        NOT NULL DEFAULT 'unknown',
    antigen_group               text,
    dose_label                  text        NOT NULL DEFAULT '',
    dose_number                 integer,
    schedule_group              text,
    source_link_id              text        NOT NULL,
    source_task_id              text,
    immunization_resource_id    text,
    practitioner_id             text,
    care_team_id                text,
    location_id                 text,
    organization_id             text,
    patient_age_days_at_admin   integer,
    patient_age_months_at_admin integer,
    patient_age_years_at_admin  integer,
    is_under_5_at_admin         boolean,
    _airbyte_extracted_at       timestamptz,
    dwh_created_at              timestamptz DEFAULT clock_timestamp(),
    dwh_updated_at              timestamptz DEFAULT clock_timestamp(),
    UNIQUE (questionnaire_response_id, source_link_id, vaccine_name, dose_label)
);

-- ----------------------------------------------------------------------------
-- Fact table: one row per patient + expected dose + reporting period
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS dwh.fact_immunization_status (
    reporting_period_start          date        NOT NULL,
    reporting_period_end            date        NOT NULL,
    patient_id                      text        NOT NULL,
    patient_name                    text,
    gender                          text,
    birth_date                      date,
    age_months_at_period_end        integer,
    age_years_at_period_end         integer,
    caregiver_name                  text,
    caregiver_phone                 text,
    household_id                    text,
    village_id                      text,
    village_name                    text,
    parish_id                       text,
    parish_name                     text,
    health_facility_id              text,
    health_facility_name            text,
    subcounty_id                    text,
    subcounty_name                  text,
    district_id                     text,
    district_name                   text,
    county_id                       text,
    county_name                     text,
    region_id                       text,
    region_name                     text,
    country_name                    text,
    reporting_facility_name         text,
    reporting_dhis2_orgunit_uid     text,
    patient_practitioner_id         text,
    patient_care_team_id            text,
    patient_organization_id         text,
    assigned_practitioner_id        text,
    assigned_vht_name               text,
    assigned_vht_phone              text,
    programme                       text        NOT NULL,
    vaccine_name                    text        NOT NULL,
    antigen_group                   text        NOT NULL,
    dose_label                      text        NOT NULL DEFAULT '',
    dose_number                     integer,
    schedule_group                  text,
    due_date                        date,
    max_due_date                    date,
    days_overdue                    integer,
    is_eligible                     boolean     DEFAULT false,
    is_due                          boolean     DEFAULT false,
    is_received                     boolean     DEFAULT false,
    received_date                   date,
    is_late_received                boolean     DEFAULT false,
    is_zero_dose                    boolean     DEFAULT false,
    is_under_immunised              boolean     DEFAULT false,
    is_fully_immunised_child        boolean     DEFAULT false,
    is_recovered_this_period        boolean     DEFAULT false,
    follow_up_status                text,
    barrier_reason                  text,
    dwh_created_at                  timestamptz DEFAULT clock_timestamp(),
    dwh_updated_at                  timestamptz DEFAULT clock_timestamp(),
    PRIMARY KEY (reporting_period_start, reporting_period_end, patient_id, programme, vaccine_name, dose_label)
);

-- ----------------------------------------------------------------------------
-- Indexes: ref_immunization_vaccine_map
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- Indexes: fact_immunizations
-- ----------------------------------------------------------------------------

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

-- ----------------------------------------------------------------------------
-- Indexes: dim_patients (supporting immunization queries)
-- ----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_dim_patients_birth_active_deceased
ON dwh.dim_patients (birth_date, active, is_deceased);

CREATE INDEX IF NOT EXISTS idx_dim_patients_gender_birth
ON dwh.dim_patients (gender, birth_date);

-- ----------------------------------------------------------------------------
-- Indexes: fact_immunization_status
-- ----------------------------------------------------------------------------

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
