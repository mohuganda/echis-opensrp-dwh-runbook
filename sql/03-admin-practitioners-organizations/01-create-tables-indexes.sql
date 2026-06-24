CREATE TABLE IF NOT EXISTS dwh.stg_practitioners (
    practitioner_id text PRIMARY KEY,
    practitioner_name text,
    family_name text,
    given_name text,
    gender text,
    active boolean,
    telecom_system text,
    phone_number text,
    official_identifier_value text,
    secondary_identifier_value text,
    version_id text,
    last_updated timestamptz,
    airbyte_extracted_at timestamptz,
    dwh_updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS dwh.stg_organizations (
    organization_id text PRIMARY KEY,
    organization_name text,
    active boolean,
    type_code text,
    type_display text,
    parent_organization_id text,
    version_id text,
    last_updated timestamptz,
    airbyte_extracted_at timestamptz,
    dwh_updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS dwh.stg_practitioner_roles (
    practitioner_role_id text PRIMARY KEY,
    practitioner_id text,
    organization_id text,
    active boolean,
    role_code text,
    role_display text,
    specialty_code text,
    specialty_display text,
    version_id text,
    last_updated timestamptz,
    airbyte_extracted_at timestamptz,
    dwh_updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS dwh.stg_care_teams (
    care_team_id text PRIMARY KEY,
    care_team_name text,
    care_team_status text,
    managing_organization_id text,
    version_id text,
    last_updated timestamptz,
    airbyte_extracted_at timestamptz,
    dwh_updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS dwh.bridge_care_team_members (
    care_team_id text,
    member_reference text,
    member_resource_type text,
    member_id text,
    role_code text,
    role_display text,
    dwh_updated_at timestamptz DEFAULT now(),
    PRIMARY KEY (care_team_id, member_reference)
);

CREATE TABLE IF NOT EXISTS dwh.dim_practitioner_assignments (
    practitioner_role_id text PRIMARY KEY,
    practitioner_id text,
    practitioner_name text,
    user_type text,
    is_vht boolean DEFAULT false,
    is_supervisor boolean DEFAULT false,
    is_web_admin boolean DEFAULT false,
    role_code text,
    role_display text,
    specialty_code text,
    specialty_display text,
    care_team_id text,
    care_team_name text,
    organization_id text,
    organization_name text,
    assigned_location_id text,
    assigned_location_name text,
    assignment_level text,
    region_name text,
    district_name text,
    county_name text,
    subcounty_name text,
    parish_name text,
    health_facility_id text,
    health_facility_name text,
    village_id text,
    village_name text,
    reporting_facility_name text,
    reporting_dhis2_orgunit_uid text,
    active boolean,
    last_updated timestamptz,
    airbyte_extracted_at timestamptz,
    dwh_updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_stg_practitioners_phone ON dwh.stg_practitioners(phone_number);
CREATE INDEX IF NOT EXISTS idx_stg_practitioner_roles_practitioner_id ON dwh.stg_practitioner_roles(practitioner_id);
CREATE INDEX IF NOT EXISTS idx_stg_practitioner_roles_organization_id ON dwh.stg_practitioner_roles(organization_id);
CREATE INDEX IF NOT EXISTS idx_bridge_care_team_members_member_id ON dwh.bridge_care_team_members(member_id);
CREATE INDEX IF NOT EXISTS idx_dim_practitioner_assignments_practitioner_id ON dwh.dim_practitioner_assignments(practitioner_id);
CREATE INDEX IF NOT EXISTS idx_dim_practitioner_assignments_location ON dwh.dim_practitioner_assignments(assigned_location_id);
CREATE INDEX IF NOT EXISTS idx_dim_practitioner_assignments_dhis2 ON dwh.dim_practitioner_assignments(reporting_dhis2_orgunit_uid);
