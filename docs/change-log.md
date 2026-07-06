# Change Log

## Immunization module — monthly aggregate and BI view

- Added `dwh.agg_immunization_monthly` — permanent monthly aggregate history (September 2023 onwards). One row per month × location level × indicator. Covers six location levels (national through village) in a single table using an indicator-code design. Built directly from `fact_immunizations + dim_patients + ref_immunization_vaccine_map` — no dependency on `fact_immunization_status`.
- Added `dwh.mv_immunization_monthly_report` — materialized view over the aggregate, intended as the primary BI query target.
- Added `dwh.refresh_immunization_monthly_aggregate(p_reporting_month)` — single-month refresh procedure.
- Added `dwh.refresh_immunization_monthly_aggregates()` — daily no-argument wrapper (refreshes previous month + current month).
- Added `dwh.refresh_immunization_monthly_aggregate_backfill(p_from_date)` — one-time historical backfill from September 2023.
- Added `dwh.refresh_immunization_monthly_report_mv()` — refreshes the materialized view concurrently.
- Added `dwh.purge_old_immunization_status(p_keep_from)` — trims `fact_immunization_status` rows older than the current quarter.
- Updated `dwh.refresh_all_daily()` — added immunization calls in correct dependency order after `refresh_supply_cebs_reporting()`.
- Updated `examples/immunization-reports.sql` — added Section C with 15 BI widget queries against `mv_immunization_monthly_report`.
- Updated `docs/reporting-data-model.md` — documented `agg_immunization_monthly` and `mv_immunization_monthly_report`.

## Immunization reporting module

- Added `dwh.ref_immunization_vaccine_map` — vaccine schedule reference table covering child immunization, malaria vaccine, and HPV.
- Added `dwh.fact_immunizations` — administered dose facts extracted from `airbyte.questionnaire_response` (not from `airbyte.immunization` or `airbyte.observation` due to extraction errors in those resources).
- Added `dwh.fact_immunization_status` — per-patient per-dose per-period coverage, zero-dose, under-immunized, FIC, and recovery tracking.
- Added `dwh.refresh_immunization_facts()` — incremental procedure reading from QuestionnaireResponse.
- Added `dwh.refresh_immunization_status()` — period-based rebuild procedure.
- Added `dwh.refresh_immunization_status_current_and_previous_month()` — daily wrapper.
- Added `sql/10-immunization/` setup scripts.
- Added `docs/immunization-module-reporting-guide.md`.
- Added `examples/immunization-reports.sql`.
- Updated daily refresh order to include immunization calls after `refresh_program_facts_base()`.

## Initial package

- Added core DWH schema and helper functions.
- Added location and DHIS2 mapping setup.
- Added admin/practitioner/organization setup.
- Added client/household setup.
- Added program fact tables and incremental refresh procedure.
- Added generic reference code extraction.
- Added patient programme status.
- Added commodity, inventory, and CEBS reporting tables.
- Added daily refresh scheduling files.
- Added reporting examples and materialized view guidance.
