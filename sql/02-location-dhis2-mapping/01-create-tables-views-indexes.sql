-- 02-location-dhis2-mapping/01-create-tables-views-indexes.sql

CREATE SCHEMA IF NOT EXISTS dwh;

CREATE TABLE IF NOT EXISTS dwh.seed_locations_with_dhis2_mapping (
    location_id text PRIMARY KEY,
    location_name text,
    region_name text,
    district_name text,
    county_name text,
    subcounty_name text,
    parish_name text,
    health_facility_name text,
    village_name text,
    reporting_facility_name text,
    reporting_dhis2_orgunit_uid text,
    is_active text DEFAULT 'active',
    notes text,
    loaded_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

DROP TABLE IF EXISTS dwh.import_seed_locations_with_dhis2_mapping;
CREATE TABLE dwh.import_seed_locations_with_dhis2_mapping (
    location_id text,
    location_name text,
    region_name text,
    district_name text,
    county_name text,
    subcounty_name text,
    parish_name text,
    health_facility_name text,
    village_name text,
    reporting_facility_name text,
    reporting_dhis2_orgunit_uid text,
    is_active text,
    notes text
);

CREATE TABLE IF NOT EXISTS dwh.stg_locations (
    location_id text PRIMARY KEY,
    location_name text,
    location_status text,
    location_type_code text,
    location_type_display text,
    parent_location_id text,
    is_jurisdiction_location boolean,
    is_household_location boolean,
    latitude numeric,
    longitude numeric,
    last_updated timestamptz,
    airbyte_extracted_at timestamptz,
    dwh_updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS dwh.dim_organization_affiliations (
    organization_affiliation_id text,
    location_id text,
    organization_id text,
    organization_name text,
    participating_organization_id text,
    participating_organization_name text,
    location_name text,
    active boolean,
    role_code text,
    role_display text,
    last_updated timestamptz,
    airbyte_extracted_at timestamptz,
    dwh_updated_at timestamptz DEFAULT now(),
    PRIMARY KEY (organization_affiliation_id, location_id)
);

CREATE TABLE IF NOT EXISTS dwh.dim_locations (
    location_id text PRIMARY KEY,
    location_name text,
    location_status text,
    location_type_code text,
    location_type_display text,
    parent_location_id text,
    country_id text,
    country_name text,
    region_id text,
    region_name text,
    district_id text,
    district_name text,
    county_id text,
    county_name text,
    subcounty_id text,
    subcounty_name text,
    parish_id text,
    parish_name text,
    health_facility_id text,
    health_facility_name text,
    village_id text,
    village_name text,
    is_leaf_location boolean,
    has_dhis2_mapping boolean,
    has_organization_affiliation boolean DEFAULT false,
    organization_affiliation_count integer DEFAULT 0,
    mapping_level text,
    raw_hierarchy_depth integer,
    admin_path_depth integer,
    reporting_facility_name text,
    reporting_dhis2_orgunit_uid text,
    latitude numeric,
    longitude numeric,
    last_updated timestamptz,
    airbyte_extracted_at timestamptz,
    dwh_updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_stg_locations_parent_location_id ON dwh.stg_locations(parent_location_id);
CREATE INDEX IF NOT EXISTS idx_stg_locations_is_jurisdiction_location ON dwh.stg_locations(is_jurisdiction_location);
CREATE INDEX IF NOT EXISTS idx_dim_org_affiliations_location_id ON dwh.dim_organization_affiliations(location_id);
CREATE INDEX IF NOT EXISTS idx_dim_org_affiliations_organization_id ON dwh.dim_organization_affiliations(organization_id);
CREATE INDEX IF NOT EXISTS idx_dim_locations_district_name ON dwh.dim_locations(district_name);
CREATE INDEX IF NOT EXISTS idx_dim_locations_reporting_dhis2_orgunit_uid ON dwh.dim_locations(reporting_dhis2_orgunit_uid);
CREATE INDEX IF NOT EXISTS idx_dim_locations_mapping_level ON dwh.dim_locations(mapping_level);
CREATE INDEX IF NOT EXISTS idx_dim_locations_has_organization_affiliation ON dwh.dim_locations(has_organization_affiliation);

DROP VIEW IF EXISTS dwh.v_location_tree_clean;
DROP VIEW IF EXISTS dwh.v_location_tree;

CREATE OR REPLACE VIEW dwh.v_location_tree AS
WITH RECURSIVE location_tree AS (
    SELECT
        l.location_id,
        l.location_name,
        l.location_status,
        l.location_type_code,
        l.location_type_display,
        l.parent_location_id,
        l.latitude,
        l.longitude,
        l.last_updated,
        l.airbyte_extracted_at,
        ARRAY[l.location_id] AS path_ids,
        ARRAY[l.location_name] AS path_names,
        1 AS hierarchy_depth
    FROM dwh.stg_locations l
    WHERE l.is_jurisdiction_location = true
      AND l.parent_location_id IS NULL

    UNION ALL

    SELECT
        child.location_id,
        child.location_name,
        child.location_status,
        child.location_type_code,
        child.location_type_display,
        child.parent_location_id,
        child.latitude,
        child.longitude,
        child.last_updated,
        child.airbyte_extracted_at,
        parent.path_ids || child.location_id,
        parent.path_names || child.location_name,
        parent.hierarchy_depth + 1
    FROM dwh.stg_locations child
    JOIN location_tree parent
        ON child.parent_location_id = parent.location_id
    WHERE child.is_jurisdiction_location = true
      AND NOT child.location_id = ANY(parent.path_ids)
)
SELECT
    lt.*,
    NOT EXISTS (
        SELECT 1
        FROM dwh.stg_locations c
        WHERE c.parent_location_id = lt.location_id
          AND c.is_jurisdiction_location = true
    ) AS is_leaf_location,
    seed.reporting_facility_name,
    seed.reporting_dhis2_orgunit_uid,
    CASE
        WHEN seed.location_id IS NOT NULL
         AND seed.reporting_dhis2_orgunit_uid IS NOT NULL THEN true
        ELSE false
    END AS has_dhis2_mapping
FROM location_tree lt
LEFT JOIN dwh.seed_locations_with_dhis2_mapping seed
    ON seed.location_id = lt.location_id
   AND lower(COALESCE(seed.is_active, 'active')) = 'active'
   AND NULLIF(trim(seed.reporting_dhis2_orgunit_uid), '') IS NOT NULL;

CREATE OR REPLACE VIEW dwh.v_location_tree_clean AS
WITH base AS (
    SELECT
        lt.*,
        ARRAY_POSITION(ARRAY(SELECT lower(trim(x)) FROM unnest(lt.path_names) AS x), 'tooro region') AS tooro_region_pos,
        ARRAY_POSITION(ARRAY(SELECT lower(trim(x)) FROM unnest(lt.path_names) AS x), 'north central region') AS north_central_region_pos,
        ARRAY_POSITION(ARRAY(SELECT lower(trim(x)) FROM unnest(lt.path_names) AS x), 'central region') AS central_region_pos,
        ARRAY_POSITION(ARRAY(SELECT lower(trim(x)) FROM unnest(lt.path_names) AS x), 'qa district') AS qa_district_pos
    FROM dwh.v_location_tree lt
),
admin_start AS (
    SELECT
        b.*,
        LEAST(
            COALESCE(tooro_region_pos, 999),
            COALESCE(north_central_region_pos, 999),
            COALESCE(central_region_pos, 999),
            COALESCE(qa_district_pos, 999)
        ) AS admin_start_pos
    FROM base b
)
SELECT
    a.*,
    CASE WHEN admin_start_pos = 999 THEN NULL ELSE path_ids[admin_start_pos:array_length(path_ids, 1)] END AS admin_path_ids,
    CASE WHEN admin_start_pos = 999 THEN NULL ELSE path_names[admin_start_pos:array_length(path_names, 1)] END AS admin_path_names,
    CASE WHEN admin_start_pos = 999 THEN NULL ELSE array_length(path_names[admin_start_pos:array_length(path_names, 1)], 1) END AS admin_path_depth
FROM admin_start a;
