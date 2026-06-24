CALL dwh.refresh_locations();

SELECT *
FROM dwh.refresh_state
WHERE table_name = 'dwh.dim_locations';

SELECT
    COUNT(*) AS total_seed_rows,
    COUNT(reporting_dhis2_orgunit_uid) AS seed_rows_with_dhis2_uid,
    COUNT(*) - COUNT(reporting_dhis2_orgunit_uid) AS seed_rows_missing_dhis2_uid
FROM dwh.seed_locations_with_dhis2_mapping;

SELECT mapping_level, COUNT(*) AS total
FROM dwh.dim_locations
WHERE has_dhis2_mapping = true
GROUP BY mapping_level
ORDER BY mapping_level;

SELECT
    mapping_level,
    has_organization_affiliation,
    COUNT(*) AS total
FROM dwh.dim_locations
WHERE has_dhis2_mapping = true
GROUP BY mapping_level, has_organization_affiliation
ORDER BY mapping_level, has_organization_affiliation;

SELECT
    location_id,
    location_name,
    region_name,
    district_name,
    county_name,
    subcounty_name,
    parish_name,
    health_facility_name,
    village_name,
    mapping_level,
    reporting_facility_name,
    reporting_dhis2_orgunit_uid,
    has_organization_affiliation,
    organization_affiliation_count
FROM dwh.dim_locations
WHERE has_dhis2_mapping = true
  AND has_organization_affiliation = false
ORDER BY region_name, district_name, county_name, subcounty_name, parish_name, health_facility_name, village_name;
