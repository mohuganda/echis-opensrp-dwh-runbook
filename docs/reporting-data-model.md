# Reporting Data Model Guide

This document explains the main `dwh` tables that MoH administrators, analysts, and BI teams should use when building reports.

The DWH layer has two main types of tables:

- **Dimensions (`dim_*`)**: descriptive tables used for names, locations, patient details, household details, user assignments, and current status.
- **Facts (`fact_*`)**: event tables used for counts, trends, service records, observations, stock movements, CEBS signals, conditions, encounters, and flags.

BI reports should normally query the `dwh` layer and avoid reading raw FHIR JSON directly from `airbyte`.

---

## 1. How to think about facts and dimensions

Use this pattern when building most reports:

```sql
SELECT
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    COUNT(*) AS total_records
FROM dwh.fact_observations fo
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(fo.location_id, fo.location_tag_id)
WHERE fo.effective_datetime >= DATE '2026-06-01'
  AND fo.effective_datetime < DATE '2026-07-01'
GROUP BY
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid;
```

The basic rule is:

```text
facts = what happened
dimensions = who, where, what group, current assignment, and reporting labels
```

---

## 2. Key dimensions

## 2.1 `dwh.dim_locations`

### Purpose

`dim_locations` is the main reporting location table. It flattens the OpenSRP/FHIR Location hierarchy and adds DHIS2 reporting mapping.

Use this table whenever a report needs:

- region;
- district;
- county;
- subcounty;
- parish;
- health facility;
- village / zone;
- DHIS2 organisation unit UID;
- DHIS2 reporting facility name;
- whether a location has assigned organisations/users/care teams.

### Grain

One row per OpenSRP/FHIR Location.

### Key columns

| Column | Meaning |
|---|---|
| `location_id` | OpenSRP/FHIR Location ID. Primary key. |
| `location_name` | Name of the location in OpenSRP. |
| `parent_location_id` | Parent Location ID from the FHIR hierarchy. |
| `region_id`, `region_name` | Region level. |
| `district_id`, `district_name` | District or city level. |
| `county_id`, `county_name` | County / municipality level where applicable. |
| `subcounty_id`, `subcounty_name` | Subcounty, town council, or division. |
| `parish_id`, `parish_name` | Parish or ward. |
| `health_facility_id`, `health_facility_name` | Health facility level where present in the hierarchy. |
| `village_id`, `village_name` | Village, zone, or cell level. |
| `reporting_facility_name` | Facility name used for reporting. Usually comes from the seed mapping. |
| `reporting_dhis2_orgunit_uid` | DHIS2 organisation unit UID for reporting. |
| `has_dhis2_mapping` | True when a DHIS2 mapping exists. |
| `has_organization_affiliation` | True when at least one organisation/user/care team is assigned to this location. |
| `organization_affiliation_count` | Number of organisation affiliations linked to the location. |
| `mapping_level` | Shows whether the mapping is at facility, village/zone, or another assigned location level. |
| `latitude`, `longitude` | Coordinates where available. |

### Common joins

Join facts to location using the fact's direct location if available, otherwise the historical location tag:

```sql
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(f.location_id, f.location_tag_id)
```

For stockout flags, use the location tag:

```sql
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = s.location_tag_id
```

### Example

```sql
SELECT
    district_name,
    reporting_facility_name,
    reporting_dhis2_orgunit_uid,
    COUNT(*) AS mapped_locations
FROM dwh.dim_locations
WHERE has_dhis2_mapping = true
GROUP BY
    district_name,
    reporting_facility_name,
    reporting_dhis2_orgunit_uid
ORDER BY district_name, reporting_facility_name;
```

---

## 2.2 `dwh.dim_practitioner_assignments`

### Purpose

`dim_practitioner_assignments` shows the current configured assignment of a practitioner/user to a care team, organisation, and reporting location.

Use this table when a report needs to know:

- the current assigned location for a VHT or supervisor;
- the organisation/care team a practitioner belongs to;
- whether the user is a VHT, supervisor, or admin;
- practitioner assignment coverage.

### Grain

One row per PractitionerRole / assignment.

### Key columns

| Column | Meaning |
|---|---|
| `practitioner_role_id` | PractitionerRole ID. Primary key. |
| `practitioner_id` | Practitioner/user ID. |
| `practitioner_name` | User name. |
| `user_type` | User classification such as VHT, supervisor, or admin. |
| `is_vht`, `is_supervisor`, `is_web_admin` | Boolean helper flags. |
| `role_code`, `role_display` | Role from PractitionerRole. |
| `specialty_code`, `specialty_display` | Specialty from PractitionerRole. |
| `care_team_id`, `care_team_name` | Care team assignment. |
| `organization_id`, `organization_name` | Organisation linked to the assignment. |
| `assigned_location_id`, `assigned_location_name` | Location linked through organisation affiliation. |
| `assignment_level` | Level of assignment, e.g. facility, village, zone, or other. |
| `region_name`, `district_name`, `subcounty_name`, `parish_name`, `village_name` | Flattened location labels for the assigned location. |
| `reporting_facility_name`, `reporting_dhis2_orgunit_uid` | DHIS2 reporting mapping for the assigned location. |
| `active` | Whether the assignment is active. |

### Important reporting note

Use this table for **current configured assignment**. For historical service facts, do not overwrite the fact's historical location tag with the user's current assignment. Use the location tags on the fact first.

### Example

```sql
SELECT
    user_type,
    assignment_level,
    district_name,
    reporting_facility_name,
    COUNT(*) AS users
FROM dwh.dim_practitioner_assignments
GROUP BY
    user_type,
    assignment_level,
    district_name,
    reporting_facility_name
ORDER BY user_type, district_name, reporting_facility_name;
```

---

## 2.3 `dwh.dim_patients`

### Purpose

`dim_patients` is the main patient/client dimension. It contains one row per patient and includes demographics and useful reporting fields.

### Grain

One row per Patient.

### Key columns

| Column | Meaning |
|---|---|
| `patient_id` | FHIR Patient ID. Primary key. |
| `full_name` | Patient/client name. |
| `gender` | Patient gender. |
| `birth_date` | Date of birth. |
| `phone_number` | Patient phone number extracted from `Patient.telecom` where available. |
| `deceased_boolean`, `deceased_datetime` | Deceased status where available. |
| `active` | Patient active status. |
| `household_id` | Household/group link where available. |
| `location_id`, `location_tag_id` | Patient location links/tags where available. |
| `practitioner_tag_id`, `care_team_tag_id`, `organization_tag_id` | Historical tags from the resource metadata. |
| `last_updated`, `airbyte_extracted_at`, `dwh_updated_at` | Source and DWH update tracking. |

### Age reporting

Do not store one permanent age group for long-term reporting. Age changes over time. Use helper functions with a report date:

```sql
SELECT
    dwh.reporting_age_group(birth_date, DATE '2026-06-30') AS age_group,
    COUNT(*) AS patients
FROM dwh.dim_patients
GROUP BY dwh.reporting_age_group(birth_date, DATE '2026-06-30')
ORDER BY age_group;
```

---

## 2.4 `dwh.dim_patient_program_status`

### Purpose

`dim_patient_program_status` is a current-status table that shows whether a patient is currently associated with selected programme/status flags.

Use it for simple patient programme counts without having to re-interpret Conditions and Flags every time.

### Grain

One row per patient.

### Key columns

| Column | Meaning |
|---|---|
| `patient_id` | Patient ID. Primary key. |
| `is_current_visitor` | True when the patient currently has an active visitor flag. |
| `has_hiv_condition` | True when an active HIV condition exists. |
| `has_tb_condition` | True when an active TB condition exists. |
| `is_under_fp` | True when an active family planning condition exists. |
| `is_anc_client` | True when an active ANC/pregnancy condition exists. |
| `is_pnc_client` | True when an active PNC condition exists. |
| `is_sick_child` | True when an active sick child condition exists. |
| `last_*_recorded_date` | Last recorded date for the relevant programme/status. |
| `dwh_updated_at` | Last time the status row was rebuilt. |

### Example

```sql
SELECT
    COUNT(*) AS total_patients,
    COUNT(*) FILTER (WHERE is_current_visitor) AS visitors,
    COUNT(*) FILTER (WHERE has_hiv_condition) AS hiv_clients,
    COUNT(*) FILTER (WHERE has_tb_condition) AS tb_clients,
    COUNT(*) FILTER (WHERE is_under_fp) AS fp_clients,
    COUNT(*) FILTER (WHERE is_anc_client) AS anc_clients,
    COUNT(*) FILTER (WHERE is_pnc_client) AS pnc_clients,
    COUNT(*) FILTER (WHERE is_sick_child) AS sick_child_clients
FROM dwh.dim_patient_program_status;
```

---

## 2.5 `dwh.dim_households`

### Purpose

`dim_households` contains household records extracted from FHIR Group resources where the group represents a household.

### Grain

One row per household Group.

### Key columns

| Column | Meaning |
|---|---|
| `household_id` | FHIR Group ID. Primary key. |
| `household_name` | Household name or generated label. |
| `group_type` | Group type. |
| `group_actual` | FHIR Group actual flag. |
| `group_active` | FHIR Group active flag. |
| `household_code`, `household_code_system`, `household_code_display` | Household group coding. |
| `managing_entity_id` | Managing entity where present. |
| `location_id`, `location_tag_id` | Household location links/tags. |
| `practitioner_tag_id`, `care_team_tag_id`, `organization_tag_id` | Historical meta tags. |
| `last_updated`, `airbyte_extracted_at`, `dwh_updated_at` | Source and DWH tracking. |

### Related table

Use `dwh.bridge_household_members` when counting members per household.

### Example

```sql
SELECT
    h.household_id,
    h.household_name,
    COUNT(m.patient_id) AS household_members
FROM dwh.dim_households h
LEFT JOIN dwh.bridge_household_members m
    ON m.household_id = h.household_id
GROUP BY h.household_id, h.household_name
ORDER BY household_members DESC;
```

---

## 2.6 `dwh.dim_commodities`

### Purpose

`dim_commodities` contains commodity/item definitions extracted from FHIR Group resources where `Group.code = 386452003`.

Use it for commodity names, units, identifiers, and item metadata.

### Grain

One row per commodity Group.

### Key columns

| Column | Meaning |
|---|---|
| `commodity_id` | FHIR Group ID. Primary key. |
| `commodity_name` | Commodity/item name. |
| `group_type`, `group_actual`, `group_active` | FHIR Group fields. |
| `commodity_code_system`, `commodity_code`, `commodity_code_display`, `commodity_code_text` | Commodity group coding. |
| `unit_system`, `unit_code`, `unit_display`, `unit_text` | Default commodity unit, e.g. pieces, cycles, ampoules. |
| `official_identifier`, `secondary_identifier` | Commodity identifiers where available. |
| `last_updated`, `airbyte_extracted_at`, `dwh_updated_at` | Source and DWH tracking. |

---

## 3. Key facts

## 3.1 `dwh.fact_observations`

### Purpose

`fact_observations` is the main flattened Observation fact table. It stores service observations, commodity stock movement observations, CEBS observations, and other observation-based data.

### Grain

One row per FHIR Observation.

### Main date column

Use `effective_datetime` for most period reporting. If missing, use `issued_datetime`, `last_updated`, or `airbyte_extracted_at` depending on the report definition.

### Key columns

| Column | Meaning |
|---|---|
| `observation_id` | FHIR Observation ID. Primary key. |
| `patient_id` | Patient subject ID when subject is Patient. |
| `group_id` | Group subject ID when subject is Group. Used for commodities and some group-based observations. |
| `location_id` | Location subject ID or extracted location tag. |
| `encounter_id` | Linked Encounter ID. |
| `performer_practitioner_id` | Practitioner performer ID. |
| `observation_status` | FHIR Observation status. |
| `observation_code`, `observation_system`, `observation_display`, `observation_text` | Main Observation code. |
| `category_1_code`, `category_1_system`, `category_1_display` | First Observation category. Used heavily for classification. |
| `category_2_code`, `category_2_system`, `category_2_display` | Second Observation category where available. |
| `effective_datetime`, `issued_datetime` | Observation date/time fields. |
| `value_string`, `value_boolean`, `value_quantity`, `value_codeable_concept_*` | Flattened Observation value. |
| `practitioner_tag_id`, `care_team_tag_id`, `organization_tag_id`, `location_tag_id` | Historical metadata tags. |
| `last_updated`, `airbyte_extracted_at`, `dwh_updated_at` | Source and DWH tracking. |

### Components

Observation components are stored separately in `dwh.fact_observation_components`.

Use components when an Observation has multiple sub-values, such as CEBS form fields or commodity running balance.

---

## 3.2 `dwh.fact_commodity_stock_movements`

### Purpose

`fact_commodity_stock_movements` contains one row per commodity stock movement Observation.

Use it for consumption, restock, physical count, adjustments, and movement history.

### Grain

One row per commodity stock movement Observation.

### Main date column

Use `effective_datetime` for period reporting.

### Key columns

| Column | Meaning |
|---|---|
| `observation_id` | Observation ID. Primary key. |
| `commodity_id` | Commodity Group ID. |
| `commodity_name` | Commodity name from `dim_commodities`. |
| `commodity_default_unit` | Default reporting unit. |
| `observation_status` | Observation status. Current stock usually comes from preliminary observations. |
| `event_code`, `event_label` | Movement event code/label, e.g. consumption, restocked. |
| `movement_code`, `movement_display` | Movement category such as addition/subtraction. |
| `movement_type` | Reporting-friendly movement type such as consumption, restock, snapshot, negative_adjustment. |
| `event_quantity` | Quantity added, removed, counted, or consumed. |
| `running_balance` | Stock balance after the movement. |
| `location_id`, `location_tag_id` | Location links/tags. |
| `practitioner_tag_id`, `care_team_tag_id`, `organization_tag_id` | Historical metadata tags. |
| `last_updated`, `airbyte_extracted_at`, `dwh_updated_at` | Source and DWH tracking. |

### Example

```sql
SELECT
    DATE_TRUNC('month', effective_datetime)::date AS report_month,
    commodity_name,
    SUM(COALESCE(event_quantity, 0)) AS quantity_consumed
FROM dwh.fact_commodity_stock_movements
WHERE movement_type = 'consumption'
GROUP BY DATE_TRUNC('month', effective_datetime)::date, commodity_name
ORDER BY report_month, commodity_name;
```

---

## 3.3 `dwh.fact_cebs_observations`

### Purpose

`fact_cebs_observations` is the wide CEBS reporting table. It turns CEBS Observation components into simple reporting columns.

Use it for CEBS signal reports, no-signal reports, supervisor verification status, signal type summaries, and facility-level CEBS reporting.

### Grain

One row per CEBS Observation.

### Main date column

Use `effective_datetime` for signal/report period reporting.

### Key columns

| Column | Meaning |
|---|---|
| `observation_id` | CEBS Observation ID. Primary key. |
| `observation_status` | FHIR Observation status. |
| `cebs_status_label` | Reporting status: awaiting_verification, verified_threat, no_signal, dismissed. |
| `has_signal` | True for signal reports, false for no-signal reports. |
| `location_id`, `location_tag_id` | Location links/tags. |
| `signal_code`, `signal_label`, `reviewed_signal_label` | CEBS signal type. |
| `signal_description` | Main VHT/signal description. |
| `vht_name`, `vht_phone`, `vht_village` | Reporter details from components. |
| `reporter_practitioner_id` | Reporter/VHT ID. |
| `latitude`, `longitude` | Reported coordinates where available. |
| `verification_method` | Supervisor verification method. |
| `supervisor_signal_description`, `vht_signal_description` | Verification descriptions. |
| `chew_people_ill`, `chew_people_dead`, `chew_animals_*` | Verification counts/details. |
| `facility_informed_date`, `animal_health_referral`, `additional_information` | Verification follow-up fields. |
| `chew_name`, `chew_phone`, `verifier_practitioner_id` | Supervisor/verifier details. |
| `last_updated`, `airbyte_extracted_at`, `dwh_updated_at` | Source and DWH tracking. |

### Example

```sql
SELECT
    cebs_status_label,
    reviewed_signal_label,
    COUNT(*) AS total
FROM dwh.fact_cebs_observations
GROUP BY cebs_status_label, reviewed_signal_label
ORDER BY total DESC;
```

---

## 3.4 `dwh.fact_encounters`

### Purpose

`fact_encounters` contains one row per FHIR Encounter. Encounters usually represent form/service interactions.

### Grain

One row per Encounter.

### Main date columns

Use `period_start` and `period_end` for encounter period reporting.

### Key columns

| Column | Meaning |
|---|---|
| `encounter_id` | FHIR Encounter ID. Primary key. |
| `patient_id` | Linked patient. |
| `practitioner_id` | Encounter participant practitioner. |
| `organization_id` | Encounter service provider organisation. |
| `location_id` | Encounter location. |
| `encounter_status` | FHIR Encounter status. |
| `class_code`, `class_system`, `class_display` | Encounter class. |
| `type_code`, `type_system`, `type_display`, `type_text` | Encounter type. |
| `service_type_code`, `service_type_text` | Service type. |
| `reason_code`, `reason_text` | Reason for encounter. |
| `period_start`, `period_end` | Encounter period. |
| `practitioner_tag_id`, `care_team_tag_id`, `organization_tag_id`, `location_tag_id` | Historical metadata tags. |
| `last_updated`, `airbyte_extracted_at`, `dwh_updated_at` | Source and DWH tracking. |

---

## 3.5 `dwh.fact_flags`

### Purpose

`fact_flags` contains one row per FHIR Flag. It is used for visitor flags, commodity stockout flags, and other flags.

### Grain

One row per Flag.

### Main date columns

Use `period_start` and `period_end` for flag period reporting.

### Key columns

| Column | Meaning |
|---|---|
| `flag_id` | FHIR Flag ID. Primary key. |
| `patient_id` | Patient subject ID when the flag is about a patient. |
| `group_id` | Group subject ID when the flag is about a commodity or other group. |
| `encounter_id` | Linked Encounter ID where available. |
| `author_practitioner_id` | Flag author practitioner. |
| `flag_status` | active, inactive, etc. |
| `flag_code`, `flag_system`, `flag_display`, `flag_text` | Main flag code. |
| `category_code`, `category_system`, `category_display`, `category_text` | Flag category. |
| `period_start`, `period_end` | Flag start/end period. |
| `practitioner_tag_id`, `care_team_tag_id`, `organization_tag_id`, `location_tag_id` | Historical metadata tags. |
| `last_updated`, `airbyte_extracted_at`, `dwh_updated_at` | Source and DWH tracking. |

### Example

```sql
SELECT
    flag_status,
    flag_code,
    flag_text,
    COUNT(*) AS total_flags
FROM dwh.fact_flags
GROUP BY flag_status, flag_code, flag_text
ORDER BY total_flags DESC;
```

---

## 3.6 `dwh.fact_conditions`

### Purpose

`fact_conditions` contains one row per FHIR Condition. It is used for programme/status tracking such as ANC, PNC, FP, HIV, TB, and sick child conditions.

### Grain

One row per Condition.

### Main date columns

Use `recorded_date`, `onset_datetime`, or `condition_start_date` depending on report definition.

### Key columns

| Column | Meaning |
|---|---|
| `condition_id` | FHIR Condition ID. Primary key. |
| `patient_id` | Patient/client ID. |
| `encounter_id` | Linked Encounter ID where available. |
| `condition_code`, `condition_system`, `condition_display`, `condition_text` | Main condition code. |
| `clinical_status_code` | active, inactive, resolved, etc. |
| `verification_status_code` | Verification status. |
| `category_code`, `category_text` | Condition category. |
| `severity_code`, `severity_text` | Severity where available. |
| `recorded_date`, `onset_datetime`, `abatement_datetime` | Condition date fields. |
| `condition_start_date`, `condition_end_date` | Reporting-friendly date range. |
| `is_active_condition` | True when condition is treated as active. |
| `practitioner_tag_id`, `care_team_tag_id`, `organization_tag_id`, `location_tag_id` | Historical metadata tags. |
| `last_updated`, `airbyte_extracted_at`, `dwh_updated_at` | Source and DWH tracking. |

### Example

```sql
SELECT
    condition_code,
    condition_text,
    COUNT(*) AS total_conditions,
    COUNT(*) FILTER (WHERE is_active_condition = true) AS active_conditions
FROM dwh.fact_conditions
GROUP BY condition_code, condition_text
ORDER BY total_conditions DESC;
```

---

## 4. Recommended reporting joins

## 4.1 Fact to location

```sql
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(f.location_id, f.location_tag_id)
```

## 4.2 Fact to patient

```sql
LEFT JOIN dwh.dim_patients p
    ON p.patient_id = f.patient_id
```

## 4.3 Fact to current practitioner assignment

Use this only when the report needs current user assignment context:

```sql
LEFT JOIN dwh.dim_practitioner_assignments pa
    ON pa.practitioner_id = COALESCE(f.performer_practitioner_id, f.practitioner_tag_id)
```

For historical location reporting, prefer the location tags on the fact.

## 4.4 Commodity movement to commodity

`fact_commodity_stock_movements` already includes commodity name and unit, but it can also join to `dim_commodities`:

```sql
LEFT JOIN dwh.dim_commodities dc
    ON dc.commodity_id = m.commodity_id
```

## 4.5 CEBS to location

```sql
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(c.location_id, c.location_tag_id)
```

---

## 5. Which date column should reports use?

| Table | Recommended date column |
|---|---|
| `fact_observations` | `effective_datetime` |
| `fact_commodity_stock_movements` | `effective_datetime` |
| `fact_cebs_observations` | `effective_datetime` |
| `fact_encounters` | `period_start` |
| `fact_flags` | `period_start`, `period_end` |
| `fact_conditions` | `recorded_date`, `onset_datetime`, or `condition_start_date` |

For monthly reporting:

```sql
DATE_TRUNC('month', effective_datetime)::date AS report_month
```

For a closed date range:

```sql
WHERE effective_datetime >= DATE '2026-06-01'
  AND effective_datetime < DATE '2026-07-01'
```

Use `< next_period_start` rather than `<= period_end` to avoid missing records with time values.

---

## 6. Materialized views for BI tools

For BI dashboards, create reporting materialized views in a separate `reporting` schema:

```sql
CREATE SCHEMA IF NOT EXISTS reporting;
```

Example:

```sql
CREATE MATERIALIZED VIEW IF NOT EXISTS reporting.mv_monthly_observation_summary AS
SELECT
    DATE_TRUNC('month', fo.effective_datetime)::date AS report_month,
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    fo.category_1_code,
    fo.observation_code,
    COUNT(*) AS total_observations
FROM dwh.fact_observations fo
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(fo.location_id, fo.location_tag_id)
GROUP BY
    DATE_TRUNC('month', fo.effective_datetime)::date,
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    fo.category_1_code,
    fo.observation_code;
```

Refresh BI materialized views after the DWH daily refresh:

```sql
REFRESH MATERIALIZED VIEW reporting.mv_monthly_observation_summary;
```

If there are many BI views, create a procedure such as:

```sql
CREATE OR REPLACE PROCEDURE reporting.refresh_bi_materialized_views()
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW reporting.mv_monthly_observation_summary;
    REFRESH MATERIALIZED VIEW reporting.mv_monthly_cebs_summary;
    REFRESH MATERIALIZED VIEW reporting.mv_monthly_commodity_consumption;
END;
$$;
```

Then call this after `dwh.refresh_all_daily()`.

---

## 7. Quick table selection guide

| Reporting question | Start with this table |
|---|---|
| DHIS2 location mapping coverage | `dwh.dim_locations` |
| Current user assignments | `dwh.dim_practitioner_assignments` |
| Patient demographics | `dwh.dim_patients` |
| Patient programme/current status | `dwh.dim_patient_program_status` |
| Household counts and membership | `dwh.dim_households`, `dwh.bridge_household_members` |
| Commodity list and units | `dwh.dim_commodities` |
| General observation/service indicators | `dwh.fact_observations` |
| Commodity consumption/restocks/current balance | `dwh.fact_commodity_stock_movements`, `dwh.dim_current_commodity_stock` |
| CEBS signal/no-signal/verification reporting | `dwh.fact_cebs_observations` |
| Service/form encounter counts | `dwh.fact_encounters` |
| Visitor and stockout flags | `dwh.fact_flags`, `dwh.fact_commodity_stockout_periods` |
| ANC/PNC/FP/HIV/TB/sick child conditions | `dwh.fact_conditions`, `dwh.dim_patient_program_status` |
