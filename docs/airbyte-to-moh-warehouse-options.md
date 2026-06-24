# Airbyte Schema and MoH Warehouse Options

## Recommended production option

Replicate the OpenSRP `airbyte` schema into the MoH warehouse, then run the DWH setup inside the MoH warehouse.

The replicated tables must preserve:

```text
resource
_airbyte_extracted_at
_airbyte_raw_id
_airbyte_meta
```

The DWH procedures read from the local `airbyte` schema and write into the local `dwh` schema.

## Why this is preferred

- MoH owns the warehouse tables.
- Reporting jobs do not depend on cross-database network access.
- Incremental procedures can use local indexes and local watermarks.
- BI tools query the MoH warehouse only.

## Alternative options

- Keep `dwh` in the OpenSRP analytics database for a pilot.
- Use PostgreSQL FDW for testing only.
