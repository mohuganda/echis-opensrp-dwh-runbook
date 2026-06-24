# Repository Maintenance Guide

Use this guide when adding new DWH tables, procedures, materialized views, or reports.

## Add a new DWH component

1. Create a numbered SQL file under the correct `sql/` folder.
2. Add table DDL and indexes in the same setup section.
3. Add or update the refresh procedure.
4. Add a run-and-validation SQL file.
5. Add at least one reporting example under `examples/` if the output is reportable.
6. Update `README.md` with the new step and link to the SQL file.
7. Update `docs/change-log.md`.
8. Test in staging before running in production.

## Naming rules

- `stg_*` for staging tables flattened from FHIR resources.
- `dim_*` for reporting dimensions.
- `fact_*` for event/fact tables.
- `ref_*` for reference/code review tables.
- `bridge_*` for many-to-many relationships.
- `reporting.mv_*` for materialized BI views.

## SQL style

- Use `CREATE TABLE IF NOT EXISTS` for setup scripts.
- Use `CREATE INDEX IF NOT EXISTS` for indexes.
- Use `CREATE OR REPLACE PROCEDURE` for refresh procedures.
- Use `ON CONFLICT DO UPDATE` for idempotent upserts.
- Use `dwh.refresh_state` for automated refresh status and watermark tracking.

## Commit example

```bash
git checkout -b add-new-reporting-layer
git add .
git commit -m "Add new reporting layer for <topic>"
git push origin add-new-reporting-layer
```
