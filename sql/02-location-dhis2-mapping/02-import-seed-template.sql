-- 02-location-dhis2-mapping/02-import-seed-template.sql
-- Use DBeaver/pgAdmin Import CSV into dwh.import_seed_locations_with_dhis2_mapping.
-- Then run the upsert below.

INSERT INTO dwh.seed_locations_with_dhis2_mapping (
    location_id,
    location_name,
    region_name,
    district_name,
    county_name,
    subcounty_name,
    parish_name,
    health_facility_name,
    village_name,
    reporting_facility_name,
    reporting_dhis2_orgunit_uid,
    is_active,
    notes,
    loaded_at,
    updated_at
)
SELECT
    NULLIF(trim(location_id), ''),
    NULLIF(trim(location_name), ''),
    NULLIF(trim(region_name), ''),
    NULLIF(trim(district_name), ''),
    NULLIF(trim(county_name), ''),
    NULLIF(trim(subcounty_name), ''),
    NULLIF(trim(parish_name), ''),
    NULLIF(trim(health_facility_name), ''),
    NULLIF(trim(village_name), ''),
    NULLIF(trim(reporting_facility_name), ''),
    NULLIF(trim(reporting_dhis2_orgunit_uid), ''),
    COALESCE(NULLIF(lower(trim(is_active)), ''), 'active'),
    NULLIF(trim(notes), ''),
    now(),
    now()
FROM dwh.import_seed_locations_with_dhis2_mapping
WHERE NULLIF(trim(location_id), '') IS NOT NULL
ON CONFLICT (location_id)
DO UPDATE SET
    location_name = EXCLUDED.location_name,
    region_name = EXCLUDED.region_name,
    district_name = EXCLUDED.district_name,
    county_name = EXCLUDED.county_name,
    subcounty_name = EXCLUDED.subcounty_name,
    parish_name = EXCLUDED.parish_name,
    health_facility_name = EXCLUDED.health_facility_name,
    village_name = EXCLUDED.village_name,
    reporting_facility_name = EXCLUDED.reporting_facility_name,
    reporting_dhis2_orgunit_uid = EXCLUDED.reporting_dhis2_orgunit_uid,
    is_active = EXCLUDED.is_active,
    notes = EXCLUDED.notes,
    updated_at = now();

SELECT
    COUNT(*) AS total_seed_rows,
    COUNT(reporting_dhis2_orgunit_uid) AS rows_with_dhis2_uid,
    COUNT(*) - COUNT(reporting_dhis2_orgunit_uid) AS rows_missing_dhis2_uid
FROM dwh.seed_locations_with_dhis2_mapping;
