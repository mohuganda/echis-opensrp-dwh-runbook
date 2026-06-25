# eCHIS OpenSRP Data Warehouse Setup and Reporting Guide

This repository is a step-by-step runbook for creating and maintaining the eCHIS/OpenSRP reporting data warehouse layer.

The goal is to make raw FHIR data easier to use for reporting by creating simple `dwh` tables from the replicated `airbyte` schema.

The intended readers are MoH warehouse administrators, analysts, and BI support teams. The guide assumes basic SQL skills, but it does not assume deep FHIR knowledge.

---

## Background: how the source data is structured

OpenSRP stores all clinical and operational data as FHIR resources. Airbyte replicates these resources into the analytics database under the `airbyte` schema. Each Airbyte table corresponds to one FHIR resource type, for example `airbyte.patient`, `airbyte.observation`, `airbyte.location`.

Every Airbyte table has this common structure:

```text
id                        FHIR resource ID
resource                  Full FHIR resource as JSONB
_airbyte_extracted_at     When Airbyte last synced this row
_airbyte_raw_id           Airbyte internal row identifier
_airbyte_meta             Airbyte metadata
```

The `resource` column contains the entire FHIR resource as a JSON object. Querying it directly requires understanding FHIR structure and writing complex JSON path expressions. That is not practical for routine MoH reporting.

The DWH layer solves this by flattening the FHIR JSON into simple relational tables with human-readable column names. A BI tool or analyst can then query `dwh.dim_patients` or `dwh.fact_observations` directly without needing to understand FHIR.

One important pattern in the source data is **resource meta tags**. When a VHT submits a service record, OpenSRP stamps the FHIR resource with metadata tags identifying the practitioner, care team, organisation, and location at the time of submission. The DWH extracts these tags as `practitioner_tag_id`, `care_team_tag_id`, `organization_tag_id`, and `location_tag_id` on fact tables. These tags are the historical truth for where and by whom a service was delivered — even if the user's current assignment later changes.

---

## 1. What this setup creates

The setup creates a reporting layer like this:

```text
Raw replicated FHIR data
  airbyte.patient
  airbyte.group
  airbyte.location
  airbyte.organization
  airbyte.organization_affiliation
  airbyte.practitioner
  airbyte.practitioner_role
  airbyte.care_team
  airbyte.encounter
  airbyte.condition
  airbyte.flag
  airbyte.observation

Reporting warehouse layer
  dwh.stg_*      staging/flattened source tables
  dwh.dim_*      reporting dimensions
  dwh.fact_*     reporting facts/events
  dwh.ref_*      reference/code review tables
  dwh.bridge_*   many-to-many bridge tables
```

MoH BI tools should query the `dwh` layer, not raw FHIR JSON directly.


### Key reporting tables

The main tables used for reporting are explained in detail in:

- [`docs/reporting-data-model.md`](docs/reporting-data-model.md)
- [`docs/commodity-module-reporting-guide.md`](docs/commodity-module-reporting-guide.md)
- [`docs/cebs-module-reporting-guide.md`](docs/cebs-module-reporting-guide.md)

The most important dimensions are:

```text
dwh.dim_locations                  DHIS2-mapped reporting location hierarchy
dwh.dim_practitioner_assignments  current practitioner/user assignments
dwh.dim_patients                   patient/client demographics
dwh.dim_patient_program_status    current patient programme/status flags
dwh.dim_households                 household records
dwh.dim_commodities                commodity/item definitions
```

The most important facts are:

```text
dwh.fact_observations                  general Observation facts
dwh.fact_commodity_stock_movements     commodity stock movements
dwh.fact_cebs_observations             CEBS signal/no-signal reports
dwh.fact_encounters                    service/form encounters
dwh.fact_flags                         visitor, stockout, and other flags
dwh.fact_conditions                    patient conditions and programme states
```

---

## 2. Recommended production architecture

### Option A: Same database setup

Use this for pilots or early handover:

```text
OpenSRP analytics database
├── airbyte schema
└── dwh schema
```

This is the simplest option because all procedures read from local `airbyte` tables and write into local `dwh` tables.

### Option B: MoH warehouse with replicated Airbyte schema

Use this for long-term production:

```text
OpenSRP analytics database
└── airbyte schema

MoH national warehouse database
├── airbyte schema  <-- replicated from OpenSRP analytics DB
└── dwh schema      <-- created by this repository
```

In this model, MoH first replicates the OpenSRP `airbyte` schema into the MoH warehouse. The DWH setup is then run inside the MoH warehouse.

The replicated `airbyte` tables must preserve these columns:

```text
resource
_airbyte_extracted_at
_airbyte_raw_id
_airbyte_meta
```

The incremental refresh procedures use `_airbyte_extracted_at` as the watermark.

### Option C: Foreign tables / FDW

This can be used for testing, but it is not the preferred production option because it depends on network connectivity and can be harder to troubleshoot.

---

## 3. Database tool instructions

The SQL files are standard PostgreSQL SQL. They can be run from DBeaver, pgAdmin, DataGrip, psql, or another SQL client.

### If using DBeaver

1. Connect to the target PostgreSQL database.
2. Open a SQL Editor.
3. Open each numbered SQL file.
4. Run the files one at a time, in order.
5. Check the validation output before moving to the next section.

### If using pgAdmin

1. Connect to the target database.
2. Open Query Tool.
3. Paste or open each SQL file.
4. Run one file at a time.

Do not paste full `CREATE OR REPLACE PROCEDURE...` scripts inside the pgAdmin procedure body editor. Use Query Tool.

### If using psql

You may run files manually:

```bash
psql -h <host> -U <user> -d <database> -f sql/00-check-airbyte-source.sql
```

The convenience file [`sql/99-run-all-setup.sql`](sql/99-run-all-setup.sql) uses `\i` commands. This works in `psql`, not in most GUI tools.

---

## 4. One-time setup order

Run these in order.

### Step 0: Check the Airbyte source schema

Before setting up anything, confirm that Airbyte has replicated the required FHIR tables into the `airbyte` schema and that the expected columns are present. All DWH refresh procedures read FHIR data from the `resource` JSONB column — if that column is missing or the table does not exist, the procedures will fail. This check also confirms that `_airbyte_extracted_at` is present, because it is used as the watermark for incremental refreshes.

Run: [`sql/00-check-airbyte-source.sql`](sql/00-check-airbyte-source.sql)

This confirms that the required raw tables and columns exist.

### Step 1: Create core schema and helper functions

The `dwh` schema is the container for all reporting tables, procedures, and functions. The helper functions created here handle the repetitive work of reading FHIR JSON safely and consistently:

- `fhir_ref_id()` extracts the resource ID from a FHIR reference string like `Patient/abc123`, returning just `abc123`.
- `safe_timestamptz()` and `safe_numeric()` prevent procedures from crashing when the source data contains malformed or empty values.
- `fhir_human_name()` and `fhir_meta_tag_code()` extract structured fields from FHIR JSON.
- `age_in_days()`, `age_in_months()`, `age_in_years()`, and `reporting_age_group()` calculate ages relative to a given report date, so that age groupings stay correct over time as patients age.

The `refresh_state` table tracks the last successful watermark and run status for each refresh procedure. Incremental procedures use this to know where to start, and it also surfaces any failures so they are visible without reading logs.

Run: [`sql/01-core-schema-functions.sql`](sql/01-core-schema-functions.sql)

This creates:

```text
dwh schema
dwh.refresh_state
dwh.fhir_ref_id()
dwh.safe_timestamptz()
dwh.safe_numeric()
dwh.fhir_human_name()
dwh.fhir_meta_tag_code()
dwh.age_in_days()
dwh.age_in_months()
dwh.age_in_years()
dwh.reporting_age_group()
dwh.is_woman_of_reproductive_age()
```

### Step 2: Set up location and DHIS2 mapping

Location setup is the most complex part of the DWH because the OpenSRP location hierarchy is not uniform across districts. The hierarchy is a tree of FHIR `Location` resources linked by `Location.partOf`. The depth varies — Kampala uses 5 levels (region → division → parish → zone), while Mukono and Kamwenge use 7 levels with a county and health facility in the middle.

Because OpenSRP location IDs have no built-in DHIS2 org unit mapping, a manually maintained **seed file** is used as the bridge. The seed maps each OpenSRP location ID to a DHIS2 reporting facility name and org unit UID. This is the only table that needs human maintenance — everything else is rebuilt automatically from the FHIR source on each refresh.

The final output is `dwh.dim_locations`, which flattens the full hierarchy into one row per location and adds the DHIS2 mapping, organization affiliation flags, and leaf-node indicators that reports need.

See [`docs/location-hierarchy-dhis2-mapping-guide.md`](docs/location-hierarchy-dhis2-mapping-guide.md) for a full explanation of the hierarchy patterns, seed file structure, and how to update the mapping when new locations are added.

Run the files in [`sql/02-location-dhis2-mapping/`](sql/02-location-dhis2-mapping/):

1. [`01-create-tables-views-indexes.sql`](sql/02-location-dhis2-mapping/01-create-tables-views-indexes.sql)
2. [`02-import-seed-template.sql`](sql/02-location-dhis2-mapping/02-import-seed-template.sql)
3. [`03-create-refresh-procedure.sql`](sql/02-location-dhis2-mapping/03-create-refresh-procedure.sql)
4. [`04-run-and-validate.sql`](sql/02-location-dhis2-mapping/04-run-and-validate.sql)

The seed file maps OpenSRP location IDs to DHIS2 reporting facility names and DHIS2 org unit UIDs.

### Step 3: Set up admin dimensions

In OpenSRP, the chain from a user to their reporting location runs through several linked FHIR resources: `PractitionerRole` → `CareTeam` participant → `CareTeam.managingOrganization` → `Organization` → `OrganizationAffiliation` → `Location`. Each link is a separate resource with its own Airbyte table.

This step creates staging tables that unwrap each link in that chain and then flattens the entire chain into `dwh.dim_practitioner_assignments` — one row per practitioner role, with the assigned location, care team, and organisation in a single queryable row.

Use `dim_practitioner_assignments` when a report needs to show current configured user assignments, headcounts by assignment level, or which locations have active practitioners assigned. For historical service records, use the location tags on the fact table rather than the practitioner's current assignment, because a user may have moved since the service was delivered.

Run the files in [`sql/03-admin-practitioners-organizations/`](sql/03-admin-practitioners-organizations/):

1. [`01-create-tables-indexes.sql`](sql/03-admin-practitioners-organizations/01-create-tables-indexes.sql)
2. [`02-create-refresh-procedure.sql`](sql/03-admin-practitioners-organizations/02-create-refresh-procedure.sql)
3. [`03-run-and-validate.sql`](sql/03-admin-practitioners-organizations/03-run-and-validate.sql)

This creates practitioner, organization, care team, organization affiliation, and practitioner assignment tables.

### Step 4: Set up clients and households

FHIR uses the `Group` resource for both household groups and commodity groups, distinguished by `Group.code`: `35359004` means household, `386452003` means commodity. This step handles household groups and patient records only — commodities are covered in step 8.

`dwh.dim_patients` stores one row per `Patient` resource with flattened demographics and location/practitioner tags. `dwh.dim_households` stores one row per household `Group`. Because the household membership relationship is stored as a list of `Group.member` references inside the group resource, a separate bridge table (`dwh.bridge_household_members`) is needed to query which patients belong to which household.

Use `dim_patients` for patient demographics, age calculations, and joining to service facts. Use `dim_households` with the bridge for household-level reporting and coverage counts.

Run the files in [`sql/04-clients-households/`](sql/04-clients-households/):

1. [`01-create-tables-indexes.sql`](sql/04-clients-households/01-create-tables-indexes.sql)
2. [`02-create-refresh-procedure.sql`](sql/04-clients-households/02-create-refresh-procedure.sql)
3. [`03-run-and-validate.sql`](sql/04-clients-households/03-run-and-validate.sql)

This creates patients, households, related persons, and household membership tables.

### Step 5: Set up program fact tables

This step creates the core service fact tables from five FHIR resource types:

- **Encounter** — a form or service interaction submitted through the app. Each Encounter has a type, class, linked patient, and time period.
- **Condition** — a programme enrolment or clinical problem such as ANC, PNC, HIV, TB, or sick child. Conditions have a clinical status (active, resolved, etc.) and are used to determine programme membership.
- **Flag** — a marker placed on a patient or commodity, such as a visitor flag or a stockout flag. Flags have a start and end period.
- **Observation** — any measured value or questionnaire response, including service delivery observations, CEBS surveillance signals, and commodity stock movements. Observations are the most flexible FHIR resource and carry the most data.
- **ObservationComponent** — sub-values within a single Observation, stored separately because one Observation can have many components (for example, all the individual fields in a CEBS report form).

The refresh procedure is incremental. After the initial run, it uses the `_airbyte_extracted_at` watermark from `dwh.refresh_state` and re-processes a one-day overlap window to catch any records that arrived slightly late. A full table rebuild is not needed on subsequent runs.

Run the files in [`sql/05-program-facts/`](sql/05-program-facts/):

1. [`01-create-fact-tables.sql`](sql/05-program-facts/01-create-fact-tables.sql)
2. [`02-create-fact-indexes.sql`](sql/05-program-facts/02-create-fact-indexes.sql)
3. [`03-create-incremental-refresh-procedure.sql`](sql/05-program-facts/03-create-incremental-refresh-procedure.sql)
4. [`04-run-and-validate.sql`](sql/05-program-facts/04-run-and-validate.sql)

This creates the core facts:

```text
dwh.fact_encounters
dwh.fact_conditions
dwh.fact_flags
dwh.fact_observations
dwh.fact_observation_components
```

The refresh procedure is incremental. It uses `_airbyte_extracted_at` with a one-day overlap window.

### Step 6: Set up reference code tables

Before building reports, analysts often need to discover what observation codes, condition codes, flag codes, and categories are actually present in the data. Without this, it is hard to know which codes to filter on or which categories represent which services.

Reference code tables solve this by pulling out all distinct code and category combinations from the fact tables and counting how many times each appears. This gives analysts a browseable catalogue of what is in the data, which codes are in active use, and which are rare or legacy.

These tables are not used in fact-to-dimension joins. They are a discovery and classification tool. MoH analysts can review them and use the results to build correct code-based filters in their report queries.

Run the files in [`sql/06-reference-codes/`](sql/06-reference-codes/):

1. [`01-create-reference-tables.sql`](sql/06-reference-codes/01-create-reference-tables.sql)
2. [`02-create-refresh-procedure.sql`](sql/06-reference-codes/02-create-refresh-procedure.sql)
3. [`03-run-and-validate.sql`](sql/06-reference-codes/03-run-and-validate.sql)

These tables simply pull out distinct code/category combinations and usage counts. MoH analysts can review and classify codes later.

### Step 7: Set up patient programme status

Programme headcount questions — "how many patients are currently on ANC?", "how many active HIV clients are there?" — can be answered by filtering the `fact_conditions` table. But this requires the report writer to know the specific FHIR condition codes for each programme, and it means re-scanning the full conditions table every time.

`dwh.dim_patient_program_status` solves this by pre-computing the answer. It maintains one current-status row per patient, rebuilt daily from the fact tables. Each row has simple boolean flags like `is_anc_client`, `has_hiv_condition`, and `is_current_visitor` that a report can filter directly without needing to know FHIR codes.

This table is for **current status** only. For historical programme trend reporting — for example, how many new ANC enrolments happened in June — use `fact_conditions` directly.

Run the files in [`sql/07-patient-program-status/`](sql/07-patient-program-status/):

1. [`01-create-tables-codes-procedure.sql`](sql/07-patient-program-status/01-create-tables-codes-procedure.sql)
2. [`02-run-and-validate.sql`](sql/07-patient-program-status/02-run-and-validate.sql)

This creates one current-status row per patient for visitor, HIV, TB, FP, ANC, PNC, and sick child reporting.

### Step 8: Set up commodity / supply / CEBS reporting

Both commodity stock movements and CEBS surveillance signals are stored as FHIR `Observation` resources, but they use different categories and have very different reporting requirements, so they get their own dedicated tables.

**Commodity stock movements:** Each stock movement (consumption, restock, physical count, adjustment) is an Observation where the subject is a commodity `Group` resource. The observation code encodes the movement type, and components carry the quantity and running balance. The `dim_commodities` table provides the commodity name and unit. `fact_commodity_stock_movements` gives one row per movement with all the fields needed for consumption and stock reporting.

**CEBS surveillance:** CEBS reports are Observations with a CEBS-specific category. Each report is a VHT-submitted signal (or no-signal), with supervisor verification details stored as Observation components. Because CEBS reports have many fields spread across components, `fact_cebs_observations` is a wide denormalized table that turns those components into named columns for easy reporting.

The refresh for this step is semi-incremental — it processes new records using the watermark but also rebuilds some running totals and stockout periods that span multiple time periods.

Run the files in [`sql/08-commodity-cebs/`](sql/08-commodity-cebs/):

1. [`01-create-tables-indexes.sql`](sql/08-commodity-cebs/01-create-tables-indexes.sql)
2. [`02-create-semi-incremental-refresh-procedure.sql`](sql/08-commodity-cebs/02-create-semi-incremental-refresh-procedure.sql)
3. [`03-run-and-validate.sql`](sql/08-commodity-cebs/03-run-and-validate.sql)

This creates:

```text
dwh.dim_commodities
dwh.fact_commodity_stock_movements
dwh.dim_current_commodity_stock
dwh.fact_commodity_stockout_periods
dwh.ref_cebs_signal_types
dwh.fact_cebs_observation_components
dwh.fact_cebs_observations
```

### Step 9: Create daily refresh procedure

This creates the master orchestration procedure `dwh.refresh_all_daily()`, which calls each individual refresh procedure in the correct dependency order. Location must run before admin dimensions (because assignments join to locations), admin must run before facts (because facts join to practitioners and organizations), and so on.

The procedure is designed to run once per day after the Airbyte sync has completed. If any individual refresh fails, the error is logged in `dwh.refresh_state` and the exception is re-raised, so the failure surfaces rather than being silently skipped.

Before scheduling this procedure, validate it manually at least once to confirm all the individual procedures have been created and the data looks correct.

Run: [`sql/09-daily-refresh/01-create-refresh-all-daily.sql`](sql/09-daily-refresh/01-create-refresh-all-daily.sql)

Then validate manually:

```sql
CALL dwh.refresh_all_daily();
```

### Step 10: Configure scheduling

The daily refresh should be scheduled to run automatically after the Airbyte sync completes each day. The timing matters: if the refresh runs before Airbyte has finished, it will pick up an incomplete watermark and miss records from that sync cycle.

The ops files provide a systemd-based scheduling setup for Linux servers. The `.service` file defines the job that calls `dwh.refresh_all_daily()` via psql. The `.timer` file defines when it runs. The `.env.example` shows which database connection variables need to be set. The refresh script reads these variables and calls the procedure.

Adjust the timer schedule to match when your Airbyte sync typically finishes. If Airbyte runs at midnight and takes 60–90 minutes, schedule the DWH refresh for 02:30 AM or later to be safe.

Use files in [`ops/`](ops/):

```text
ops/dwh.env.example
ops/run_daily_refresh.sh
ops/echis-dwh-refresh.service
ops/echis-dwh-refresh.timer
```

The daily refresh should run after Airbyte replication has completed.

---

## 5. Daily refresh order

The daily order is:

```sql
CALL dwh.refresh_locations();
CALL dwh.refresh_admin_dimensions();
CALL dwh.refresh_client_dimensions();
CALL dwh.refresh_program_facts_base();
CALL dwh.refresh_patient_program_status();
CALL dwh.refresh_supply_cebs_reporting();
```

Reference code refresh is not required daily. Run it weekly or after app/config changes:

```sql
CALL dwh.refresh_code_reference_tables();
```

---

## 6. Refresh strategy

### Controlled rebuild

Used for small dimensions and current snapshots:

```text
dwh.dim_locations
dwh.dim_practitioner_assignments
dwh.dim_patients / dim_households for now
dwh.dim_patient_program_status
dwh.dim_commodities
dwh.dim_current_commodity_stock
```

### Incremental upsert

Used for larger fact tables:

```text
dwh.fact_encounters
dwh.fact_conditions
dwh.fact_flags
dwh.fact_observations
dwh.fact_observation_components
dwh.fact_commodity_stock_movements
dwh.fact_commodity_stockout_periods
dwh.fact_cebs_observation_components
dwh.fact_cebs_observations
```

The incremental procedures use `dwh.refresh_state.last_successful_airbyte_extracted_at` and reprocess a one-day overlap window.

---

## 7. How to use facts and dimensions for reports

A simple reporting query usually follows this pattern:

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

Use facts for events. Use dimensions for names, locations, assignments, patient details, and groupings.

---

## 8. Materialized views for BI tools

For BI tools, create reporting marts or materialized views on top of facts and dimensions.

Recommended schema:

```sql
CREATE SCHEMA IF NOT EXISTS reporting;
```

Example materialized view:

```sql
CREATE MATERIALIZED VIEW IF NOT EXISTS reporting.mv_monthly_cebs_summary AS
SELECT
    DATE_TRUNC('month', c.effective_datetime)::date AS report_month,
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    c.cebs_status_label,
    c.reviewed_signal_label,
    COUNT(*) AS total_records
FROM dwh.fact_cebs_observations c
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(c.location_id, c.location_tag_id)
GROUP BY
    DATE_TRUNC('month', c.effective_datetime)::date,
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    c.cebs_status_label,
    c.reviewed_signal_label;
```

Refresh materialized views after the DWH refresh:

```sql
REFRESH MATERIALIZED VIEW reporting.mv_monthly_cebs_summary;
```

For multiple BI views, create a procedure:

```sql
CREATE OR REPLACE PROCEDURE reporting.refresh_bi_materialized_views()
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW reporting.mv_monthly_cebs_summary;
    REFRESH MATERIALIZED VIEW reporting.mv_commodity_monthly_consumption;
END;
$$;
```

Then call this at the end of the daily schedule after `dwh.refresh_all_daily()`.

---

## 9. Why functions and procedures are used

Functions are used for reusable logic inside SQL:

```text
FHIR reference extraction
safe timestamp parsing
safe numeric parsing
human name extraction
meta tag extraction
age calculations
period grouping
```

Procedures are used for automation:

```text
refresh one DWH layer
track status
track watermarks
handle failures
prevent duplicate runs
schedule nightly processing
```

In short:

```text
Function = reusable calculation
Procedure = repeatable automated job
```

---

## 10. How to update this repository

When a new DWH piece is added:

1. Add the SQL file in the correct numbered folder.
2. Add a validation query.
3. Add at least one example report query.
4. Update this README with the new step.
5. Update [`docs/change-log.md`](docs/change-log.md).
6. If it must run daily, add it to [`sql/09-daily-refresh/01-create-refresh-all-daily.sql`](sql/09-daily-refresh/01-create-refresh-all-daily.sql).
7. If it feeds BI materialized views, update [`examples/materialized-view-examples.sql`](examples/materialized-view-examples.sql).

Suggested commit style:

```bash
git add .
git commit -m "Add <feature> DWH reporting layer"
git push
```

---

## 11. Troubleshooting

See: [`docs/troubleshooting.md`](docs/troubleshooting.md)

Common checks:

```sql
SELECT *
FROM dwh.refresh_state
ORDER BY last_run_started_at DESC NULLS LAST;
```

```sql
SELECT
    pid,
    now() - query_start AS duration,
    state,
    query
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY query_start;
```
