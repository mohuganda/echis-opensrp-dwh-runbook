# eCHIS OpenSRP Data Warehouse Setup and Reporting Guide

This repository is a step-by-step runbook for creating and maintaining the eCHIS/OpenSRP reporting data warehouse layer.

The goal is to make raw FHIR data easier to use for reporting by creating simple `dwh` tables from the replicated `airbyte` schema.

The intended readers are MoH warehouse administrators, analysts, and BI support teams. The guide assumes basic SQL skills, but it does not assume deep FHIR knowledge.

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

Run: [`sql/00-check-airbyte-source.sql`](sql/00-check-airbyte-source.sql)

This confirms that the required raw tables and columns exist.

### Step 1: Create core schema and helper functions

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

Run the files in [`sql/02-location-dhis2-mapping/`](sql/02-location-dhis2-mapping/):

1. [`01-create-tables-views-indexes.sql`](sql/02-location-dhis2-mapping/01-create-tables-views-indexes.sql)
2. [`02-import-seed-template.sql`](sql/02-location-dhis2-mapping/02-import-seed-template.sql)
3. [`03-create-refresh-procedure.sql`](sql/02-location-dhis2-mapping/03-create-refresh-procedure.sql)
4. [`04-run-and-validate.sql`](sql/02-location-dhis2-mapping/04-run-and-validate.sql)

The seed file maps OpenSRP location IDs to DHIS2 reporting facility names and DHIS2 org unit UIDs.

### Step 3: Set up admin dimensions

Run the files in [`sql/03-admin-practitioners-organizations/`](sql/03-admin-practitioners-organizations/):

1. [`01-create-tables-indexes.sql`](sql/03-admin-practitioners-organizations/01-create-tables-indexes.sql)
2. [`02-create-refresh-procedure.sql`](sql/03-admin-practitioners-organizations/02-create-refresh-procedure.sql)
3. [`03-run-and-validate.sql`](sql/03-admin-practitioners-organizations/03-run-and-validate.sql)

This creates practitioner, organization, care team, organization affiliation, and practitioner assignment tables.

### Step 4: Set up clients and households

Run the files in [`sql/04-clients-households/`](sql/04-clients-households/):

1. [`01-create-tables-indexes.sql`](sql/04-clients-households/01-create-tables-indexes.sql)
2. [`02-create-refresh-procedure.sql`](sql/04-clients-households/02-create-refresh-procedure.sql)
3. [`03-run-and-validate.sql`](sql/04-clients-households/03-run-and-validate.sql)

This creates patients, households, related persons, and household membership tables.

### Step 5: Set up program fact tables

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

Run the files in [`sql/06-reference-codes/`](sql/06-reference-codes/):

1. [`01-create-reference-tables.sql`](sql/06-reference-codes/01-create-reference-tables.sql)
2. [`02-create-refresh-procedure.sql`](sql/06-reference-codes/02-create-refresh-procedure.sql)
3. [`03-run-and-validate.sql`](sql/06-reference-codes/03-run-and-validate.sql)

These tables simply pull out distinct code/category combinations and usage counts. MoH analysts can review and classify codes later.

### Step 7: Set up patient programme status

Run the files in [`sql/07-patient-program-status/`](sql/07-patient-program-status/):

1. [`01-create-tables-codes-procedure.sql`](sql/07-patient-program-status/01-create-tables-codes-procedure.sql)
2. [`02-run-and-validate.sql`](sql/07-patient-program-status/02-run-and-validate.sql)

This creates one current-status row per patient for visitor, HIV, TB, FP, ANC, PNC, and sick child reporting.

### Step 8: Set up commodity / supply / CEBS reporting

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

Run: [`sql/09-daily-refresh/01-create-refresh-all-daily.sql`](sql/09-daily-refresh/01-create-refresh-all-daily.sql)

Then validate manually:

```sql
CALL dwh.refresh_all_daily();
```

### Step 10: Configure scheduling

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
