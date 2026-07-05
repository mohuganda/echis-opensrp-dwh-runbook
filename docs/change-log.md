# Change Log

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
