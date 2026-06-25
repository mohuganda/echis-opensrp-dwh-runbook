# Location Hierarchy and DHIS2 Mapping Setup Guide

This document explains how the eCHIS/OpenSRP location hierarchy works and how the DHIS2 mapping seed is set up and maintained.

The final output of this process is `dwh.dim_locations` — the main reporting location table used by all DWH fact-to-location joins.

---

## 1. Why location is the foundation of all reporting

Every MoH report needs to answer: **where did this happen?**

In OpenSRP, location is stored as a tree of FHIR `Location` resources. Each location points to its parent via `Location.partOf`. Service records (Observations, Encounters, Flags, Conditions) carry location tags in their FHIR metadata that identify where the service was delivered.

For DHIS2 reporting, however, OpenSRP location IDs are not enough. DHIS2 needs an organisation unit UID, and the mapping between OpenSRP locations and DHIS2 org units cannot always be derived automatically from the hierarchy because:

- The hierarchy depth varies by district.
- Some facilities exist at different levels in different areas.
- New locations may be added that have not yet been mapped.

This is why a manually maintained **seed mapping file** is used. The seed is the bridge between the OpenSRP hierarchy and DHIS2 reporting.

---

## 2. How the FHIR Location hierarchy works

Each OpenSRP location is a FHIR `Location` resource. The hierarchy is built by following the `Location.partOf` chain upward from a village or zone to a region.

The DWH setup walks this tree recursively using a SQL recursive CTE to flatten each location into a single row that includes all ancestor levels.

The result is `dwh.dim_locations`, where every row has columns for region, district, county, subcounty, parish, health facility, and village — even if some of those levels are NULL for a given location.

---

## 3. The hierarchy depth problem

The OpenSRP hierarchy does not have a fixed number of levels across all districts. This creates a challenge when trying to assign consistent reporting columns like `region_name`, `district_name`, and `subcounty_name`.

### Kampala pattern (5 levels)

Kampala does not use a county level. The hierarchy is shallower:

```text
Level 1  Region
Level 2  Kampala (city / district)
Level 3  Division
Level 4  Parish / Ward
Level 5  Zone / Cell
```

Column mapping:

```text
region_name   = Level 1
district_name = Level 2
county_name   = NULL
subcounty_name = Level 3
parish_name   = Level 4
village_name  = Level 5
```

### Mukono and Kamwenge pattern (7 levels)

Districts outside Kampala often include a county level and a health facility level inside the hierarchy:

```text
Level 1  Region
Level 2  District
Level 3  County
Level 4  Subcounty / Town Council
Level 5  Parish / Ward
Level 6  Health Facility
Level 7  Village / Zone
```

Column mapping:

```text
region_name          = Level 1
district_name        = Level 2
county_name          = Level 3
subcounty_name       = Level 4
parish_name          = Level 5
health_facility_name = Level 6
village_name         = Level 7
```

The refresh procedure handles both patterns. The depth differences mean the hierarchy walker must identify the administrative start position before assigning level labels.

---

## 4. The seed mapping concept

The seed mapping file is a CSV or Excel file that lists OpenSRP location IDs and their corresponding DHIS2 reporting facility name and DHIS2 org unit UID.

This file is the **only table that needs manual maintenance**. Everything else in `dim_locations` is rebuilt automatically from the FHIR source on each refresh.

### Why the seed is needed

- The FHIR hierarchy does not contain DHIS2 org unit UIDs.
- Some service delivery happens at village/zone level, but reporting must roll up to a facility.
- Some users are assigned at facility level, not village level.
- The seed allows flexible mapping regardless of where in the hierarchy a service was recorded.

### What the seed covers

The seed may include mappings at multiple levels:

- **Village / Zone level** — when CHWs are assigned at village/zone and service records carry village-level location tags.
- **Health Facility level** — when care teams or users are assigned directly to a facility location.
- **Other operational locations** — where applicable.

This flexibility is intentional. The `mapping_level` column in `dim_locations` shows which level the mapping was made at for each location.

---

## 5. Generated tables vs the editable seed

Understanding which tables are auto-generated and which require manual input prevents accidental data loss.

### Auto-generated (do not edit manually)

These tables are rebuilt from source data on each refresh:

| Table | What it contains |
|---|---|
| `dwh.stg_locations` | Flattened raw FHIR Location fields, one row per Location. |
| `dwh.dim_organization_affiliations` | OrganizationAffiliation records linking organizations to locations. |
| `dwh.dim_locations` | Final reporting location dimension with hierarchy, DHIS2 mapping, and affiliation flags. |

If you edit these tables directly, the changes will be overwritten on the next refresh.

### Editable seed (maintain this)

| Table | What it contains |
|---|---|
| `dwh.seed_locations_with_dhis2_mapping` | Manual mapping of OpenSRP location IDs to DHIS2 reporting names and org unit UIDs. |

This table persists across refreshes. The refresh procedure reads from it but never overwrites it.

There is also an intermediate import table used only during the CSV load process:

| Table | What it contains |
|---|---|
| `dwh.import_seed_locations_with_dhis2_mapping` | Temporary staging table for loading the seed CSV before upserting. |

---

## 6. Seed file structure

The seed file should have these columns:

| Column | Description |
|---|---|
| `location_id` | OpenSRP/FHIR Location ID. **Do not edit this value.** It is the primary key used to join to the hierarchy. |
| `location_name` | OpenSRP location name. For reference only. |
| `region_name` | Programme region name. |
| `district_name` | District or city name. |
| `county_name` | County or municipality name where applicable. Leave blank if not applicable. |
| `subcounty_name` | Subcounty, town council, or division. |
| `parish_name` | Parish or ward. |
| `health_facility_name` | Health facility level from the OpenSRP hierarchy where available. |
| `village_name` | Village, zone, or cell where available. |
| `reporting_facility_name` | DHIS2 reporting facility name. This is what appears in DHIS2 reports. |
| `reporting_dhis2_orgunit_uid` | DHIS2 organisation unit UID used for reporting. |
| `is_active` | Use `active` for rows that should be included. Use any other value to exclude a row without deleting it. |
| `notes` | Optional maintenance notes. |

### Key rules for maintaining the seed file

1. Never change the `location_id` value. It must match the OpenSRP/FHIR Location ID exactly.
2. When a facility is renamed in DHIS2, update `reporting_facility_name` and confirm the `reporting_dhis2_orgunit_uid` is still correct.
3. When a new village or zone is added in OpenSRP, add a new row with its location ID and the correct DHIS2 mapping.
4. Use `is_active = inactive` to temporarily exclude a mapping without deleting the row.
5. After updating the seed file, re-import the CSV and run `CALL dwh.refresh_locations();` to apply the changes.

---

## 7. How to load or update the seed

The seed is loaded from a CSV using either pgAdmin or psql. See [`sql/02-location-dhis2-mapping/02-import-seed-template.sql`](../sql/02-location-dhis2-mapping/02-import-seed-template.sql) for the import commands.

**Using pgAdmin:**

1. Right-click `dwh.import_seed_locations_with_dhis2_mapping`.
2. Select Import/Export Data → Import.
3. Select the CSV file.
4. Set Format: CSV, Header: Yes, Delimiter: comma, Encoding: UTF-8.
5. Confirm columns match and click OK.

**Using psql:**

Use `\copy` (not `COPY`) because `\copy` reads from the client machine, not the server:

```sql
\copy dwh.import_seed_locations_with_dhis2_mapping (
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
    notes
)
FROM '<path_to_seed_file>/location_mapping_with_dhis2_orgunitid.csv'
WITH CSV HEADER;
```

Do not hard-code a personal local file path in shared scripts.

After loading the import table, upsert into the master seed using the SQL in the import template, then run the location refresh procedure.

---

## 8. How `dim_locations` gets its DHIS2 mapping

The refresh procedure joins each location in the hierarchy to the seed using `location_id`. If a matching seed row is found with a non-null `reporting_dhis2_orgunit_uid` and `is_active = 'active'`, the location gets:

- `has_dhis2_mapping = true`
- `reporting_facility_name` from the seed
- `reporting_dhis2_orgunit_uid` from the seed
- `mapping_level` set to the level at which the mapping was applied (facility, village, zone, or other)

If no matching seed row exists, the location gets `has_dhis2_mapping = false` and NULL reporting columns.

The `has_organization_affiliation` and `organization_affiliation_count` columns are populated from `OrganizationAffiliation` records. A location that has no organisations, care teams, or practitioners assigned to it will show `has_organization_affiliation = false`.

---

## 9. Validation checklist after setup or seed update

Run these queries after loading a new seed or after a location refresh to confirm the results look correct.

**Seed row count:**

```sql
SELECT
    COUNT(*) AS total_seed_rows,
    COUNT(reporting_dhis2_orgunit_uid) AS rows_with_dhis2_uid,
    COUNT(*) - COUNT(reporting_dhis2_orgunit_uid) AS rows_missing_dhis2_uid
FROM dwh.seed_locations_with_dhis2_mapping;
```

**Mapped locations by level:**

```sql
SELECT
    mapping_level,
    COUNT(*) AS total
FROM dwh.dim_locations
WHERE has_dhis2_mapping = true
GROUP BY mapping_level
ORDER BY mapping_level;
```

**Mapped locations that also have organisation affiliations:**

```sql
SELECT
    mapping_level,
    has_organization_affiliation,
    COUNT(*) AS total
FROM dwh.dim_locations
WHERE has_dhis2_mapping = true
GROUP BY mapping_level, has_organization_affiliation
ORDER BY mapping_level, has_organization_affiliation;
```

**Active seed rows that did not match any location in the hierarchy** (these may indicate a stale or incorrect location ID in the seed):

```sql
SELECT
    seed.location_id,
    seed.location_name,
    seed.district_name,
    seed.reporting_facility_name,
    seed.reporting_dhis2_orgunit_uid
FROM dwh.seed_locations_with_dhis2_mapping seed
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = seed.location_id
WHERE lower(COALESCE(seed.is_active, 'active')) = 'active'
  AND seed.reporting_dhis2_orgunit_uid IS NOT NULL
  AND dl.location_id IS NULL
ORDER BY seed.region_name, seed.district_name, seed.village_name;
```

**Mapped locations with no organisation affiliation** (useful to identify where user/care team assignment may be missing):

```sql
SELECT
    location_id,
    location_name,
    district_name,
    mapping_level,
    reporting_facility_name
FROM dwh.dim_locations
WHERE has_dhis2_mapping = true
  AND has_organization_affiliation = false
ORDER BY district_name, location_name;
```

---

## 10. How location joins work in reporting

Facts carry location information in two ways:

1. **`location_id`** — a direct FHIR Location reference on the resource.
2. **`location_tag_id`** — a location extracted from the FHIR resource metadata tags.

When joining to `dim_locations`, prefer the direct location but fall back to the tag:

```sql
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(f.location_id, f.location_tag_id)
```

For stockout flags specifically, the location tag is the reliable join column:

```sql
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = f.location_tag_id
```

Do not replace the fact's historical location tag with the practitioner's current assigned location from `dim_practitioner_assignments`. The location tag on the fact reflects where the service was recorded at the time it was submitted.
