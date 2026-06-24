# Refresh Strategy

The DWH uses two refresh patterns.

## Controlled rebuild

Used for small dimensions and snapshots:

- `dwh.dim_locations`
- `dwh.dim_practitioner_assignments`
- `dwh.dim_patients`
- `dwh.dim_households`
- `dwh.dim_patient_program_status`
- `dwh.dim_commodities`
- `dwh.dim_current_commodity_stock`

## Incremental upsert

Used for large facts:

- `dwh.fact_encounters`
- `dwh.fact_conditions`
- `dwh.fact_flags`
- `dwh.fact_observations`
- `dwh.fact_observation_components`
- `dwh.fact_commodity_stock_movements`
- `dwh.fact_commodity_stockout_periods`
- `dwh.fact_cebs_observation_components`
- `dwh.fact_cebs_observations`

Incremental refreshes use `dwh.refresh_state.last_successful_airbyte_extracted_at` with a one-day overlap.
