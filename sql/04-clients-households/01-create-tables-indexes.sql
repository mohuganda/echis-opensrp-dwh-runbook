CREATE TABLE IF NOT EXISTS dwh.stg_patients (
    patient_id text PRIMARY KEY,
    full_name text,
    family_name text,
    given_name text,
    gender text,
    birth_date date,
    deceased_boolean boolean,
    deceased_datetime timestamptz,
    active boolean,
    telecom_system text,
    phone_number text,
    official_identifier_value text,
    secondary_identifier_value text,
    practitioner_tag_id text,
    care_team_tag_id text,
    organization_tag_id text,
    location_tag_id text,
    app_version text,
    version_id text,
    last_updated timestamptz,
    airbyte_extracted_at timestamptz,
    dwh_updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS dwh.stg_households (
    household_id text PRIMARY KEY,
    household_name text,
    group_type text,
    active boolean,
    actual boolean,
    household_code_system text,
    household_code text,
    household_code_display text,
    household_code_text text,
    location_id text,
    practitioner_tag_id text,
    care_team_tag_id text,
    organization_tag_id text,
    location_tag_id text,
    app_version text,
    version_id text,
    last_updated timestamptz,
    airbyte_extracted_at timestamptz,
    dwh_updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS dwh.stg_related_persons (
    related_person_id text PRIMARY KEY,
    patient_id text,
    relationship_code text,
    relationship_display text,
    relationship_text text,
    active boolean,
    version_id text,
    last_updated timestamptz,
    airbyte_extracted_at timestamptz,
    dwh_updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS dwh.bridge_household_members (
    household_id text,
    patient_id text,
    member_reference text,
    member_entity_type text,
    inactive boolean,
    dwh_updated_at timestamptz DEFAULT now(),
    PRIMARY KEY (household_id, patient_id)
);

CREATE TABLE IF NOT EXISTS dwh.dim_patients (
    patient_id text PRIMARY KEY,
    full_name text,
    family_name text,
    given_name text,
    gender text,
    birth_date date,
    phone_number text,
    active boolean,
    deceased_boolean boolean,
    deceased_datetime timestamptz,
    is_deceased boolean,
    age_years_today integer,
    age_group_today text,
    is_woman_of_reproductive_age_today boolean,
    household_id text,
    household_name text,
    location_id text,
    reporting_facility_name text,
    reporting_dhis2_orgunit_uid text,
    practitioner_tag_id text,
    care_team_tag_id text,
    organization_tag_id text,
    location_tag_id text,
    app_version text,
    version_id text,
    last_updated timestamptz,
    airbyte_extracted_at timestamptz,
    dwh_updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS dwh.dim_households (
    household_id text PRIMARY KEY,
    household_name text,
    active boolean,
    location_id text,
    reporting_facility_name text,
    reporting_dhis2_orgunit_uid text,
    member_count integer,
    practitioner_tag_id text,
    care_team_tag_id text,
    organization_tag_id text,
    location_tag_id text,
    app_version text,
    version_id text,
    last_updated timestamptz,
    airbyte_extracted_at timestamptz,
    dwh_updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dim_patients_phone_number ON dwh.dim_patients(phone_number);
CREATE INDEX IF NOT EXISTS idx_dim_patients_household_id ON dwh.dim_patients(household_id);
CREATE INDEX IF NOT EXISTS idx_dim_patients_location_id ON dwh.dim_patients(location_id);
CREATE INDEX IF NOT EXISTS idx_bridge_household_members_patient ON dwh.bridge_household_members(patient_id);
CREATE INDEX IF NOT EXISTS idx_bridge_household_members_household ON dwh.bridge_household_members(household_id);
CREATE INDEX IF NOT EXISTS idx_dim_households_location_id ON dwh.dim_households(location_id);
