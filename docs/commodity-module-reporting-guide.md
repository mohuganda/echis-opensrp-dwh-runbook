# Commodity, Supply, and Inventory Reporting Guide

## 1. Purpose

This document explains how commodity, supply, and inventory data is represented in OpenSRP/eCHIS FHIR resources and how the DWH reporting layer turns that data into tables that are easier to use in dashboards and reports.

It is intended for MoH administrators, database administrators, analytics users, and dashboard developers.

The main DWH tables used for commodity reporting are:

```text

dwh.dim_commodities
dwh.fact_commodity_stock_movements
dwh.dim_current_commodity_stock
dwh.fact_commodity_stockout_periods
```

The most commonly used tables are:

```text

dwh.dim_current_commodity_stock
dwh.fact_commodity_stock_movements
dwh.fact_commodity_stockout_periods
```

---

## 2. Plain-language overview

The commodity module uses FHIR resources in a specific way:

| FHIR resource | Meaning in commodity reporting |
| --- | --- |
| `Group` | The commodity item, for example Male Condoms, Female Condoms, Microlut, Microgynon, Sayana Press/Depo |
| `Observation` | A stock movement or stock balance event |
| `Observation.component` | Holds the running balance after the event |
| `Flag` | Represents a stockout period |

A commodity item is not a Patient. It is represented as a FHIR `Group` resource with the supply-chain code:

```text
SNOMED code: 386452003
Meaning: Supply management
```

Every stock movement is represented as an Observation whose subject points to the commodity Group.

---

## 3. Commodity item model

Commodity items are stored as FHIR `Group` resources.

The DWH extracts them into:

```text

dwh.dim_commodities
```

Common commodity items include:

| Commodity | Unit | Notes |
| --- | --- | --- |
| Male Condoms | Pieces | Entered by VHT |
| Female Condoms | Pieces | Entered by VHT |
| Microlut | Cycles | Entered by VHT |
| Microgynon | Cycles | Entered by VHT |
| Sayana Press / Depo | Ampoules | Usually recorded as 1 when administered |

Important columns in `dwh.dim_commodities`:

| Column | Meaning |
| --- | --- |
| `commodity_id` | FHIR Group ID |
| `commodity_name` | Commodity name |
| `commodity_code_system` | Code system for the Group code |
| `commodity_code` | Commodity Group code, usually `386452003` |
| `unit_text` | Default reporting unit |
| `unit_display` | Unit display from the Group characteristic |
| `official_identifier` | Official identifier if present |
| `secondary_identifier` | Secondary identifier if present |

---

## 4. Commodity Observation pattern

All commodity Observations share a common structure.

### 4.1 Category

`category[0]` marks the Observation as a supply-chain Observation:

```text
system: http://snomed.info/sct
code: 386452003
display: Supply management
```

This is the primary filter used by the DWH to identify supply Observations.

`category[1]` describes the movement type. Examples include:

```text
snapshot
addition
subtraction
```

### 4.2 Code

The Observation code identifies the specific event, for example:

```text
consumption
restocked
physical-count-soh
balance-before-restock
balance-after-restock
expiry
damage
donation
over-reporting
under-reporting
```

### 4.3 Subject

The Observation subject points to the commodity Group:

```text
Observation.subject = Group/<commodity-id>
```

### 4.4 Value quantity

The top-level Observation value is the quantity for that event.

Examples:

```text
quantity consumed
quantity restocked
quantity damaged
quantity expired
quantity counted
```

### 4.5 Running balance component

The running stock balance is stored in an Observation component.

The component code is:

```text
system: http://snomed.info/sct
code: 255619001
display: Total
text: Running total/Cumulative sum
```

The component value is the stock balance after the event.

This is the value used for current stock and stock history reconstruction.

---

## 5. Physical count and restock events

Physical count and restock forms can create several Observations linked to the same Encounter.

| Observation code | Category/movement | What it means |
| --- | --- | --- |
| `balance-before-restock` | snapshot | System balance before the restock was applied |
| `physical-count-soh` | snapshot | Actual stock counted by the VHT |
| `restocked` | addition | Quantity received or restocked |
| `expiry` | subtraction | Expired stock removed |
| `damage` | subtraction | Damaged stock removed |
| `donation` | addition | Donated stock added |
| `over-reporting` | subtraction | Adjustment where stock was over-reported |
| `under-reporting` | addition | Adjustment where stock was under-reported |
| `balance-after-restock` | snapshot | Balance after restock and adjustments |

The DWH turns these into rows in:

```text

dwh.fact_commodity_stock_movements
```

---

## 6. Consumption events

Consumption Observations are created when commodities are dispensed or administered during service delivery, for example FP services.

Typical pattern:

```text
Observation.category[0] = Supply management
Observation.category[1] = subtraction
Observation.code = consumption
Observation.valueQuantity = quantity distributed or administered
Observation.component[Total] = running balance after consumption
```

For period reporting, consumption is usually summed from `event_quantity` where:

```text
movement_type = consumption
```

---

## 7. Preliminary and final pattern

The commodity module uses a preliminary/final pattern to track current stock.

At any time:

```text
Exactly one Observation per commodity should be preliminary.
That preliminary Observation holds the latest/current stock balance.
Older Observations should be final.
```

When a new event is submitted:

1. The form identifies the existing preliminary Observation.
2. A new Observation is created with `status = preliminary`.
3. The old preliminary Observation is updated to `status = final`.

For current stock:

```text
Use the latest preliminary Observation per commodity.
```

For period reporting:

```text
Use final Observations filtered by event code or movement type.
```

The DWH handles this using:

```text

dwh.dim_current_commodity_stock
```

This table is rebuilt as a current-state snapshot from the latest preliminary commodity movement.

---

## 8. Stockout flags

Stockouts are represented as FHIR `Flag` resources.

The stockout flag code is:

```text
system: http://snomed.info/sct
code: 419182006
```

The flag subject points to the commodity Group.

In reporting:

| Flag status | Meaning |
| --- | --- |
| `active` | The commodity is currently stocked out |
| `inactive` | The stockout ended or the commodity was restocked |

The DWH extracts stockout periods into:

```text

dwh.fact_commodity_stockout_periods
```

Important columns:

| Column | Meaning |
| --- | --- |
| `flag_id` | FHIR Flag ID |
| `commodity_id` | Commodity Group ID |
| `commodity_name` | Commodity name |
| `flag_status` | Raw FHIR Flag status |
| `is_current_stockout` | True if currently stocked out |
| `stockout_started_at` | Stockout start date/time |
| `stockout_ended_at` | Stockout end date/time |
| `stockout_duration` | Calculated duration |
| `location_tag_id` | Historical location tag |

---

## 9. DWH reporting tables

### 9.1 `dwh.dim_commodities`

One row per commodity item.

Use this table to list commodities and their default units.

```sql
SELECT
    commodity_id,
    commodity_name,
    unit_text,
    unit_display
FROM dwh.dim_commodities
ORDER BY commodity_name;
```

### 9.2 `dwh.fact_commodity_stock_movements`

One row per commodity Observation.

Important columns:

| Column | Meaning |
| --- | --- |
| `observation_id` | FHIR Observation ID |
| `effective_datetime` | Event date/time |
| `observation_status` | Raw Observation status |
| `commodity_id` | Commodity Group ID |
| `commodity_name` | Commodity name |
| `event_code` | Raw event code |
| `event_label` | Human-readable event label |
| `movement_type` | Normalized movement type |
| `event_quantity` | Quantity for this event |
| `running_balance` | Balance after this event |
| `location_id` | Location from subject/tag where available |
| `location_tag_id` | Historical practitioner location tag |
| `organization_tag_id` | Historical organization tag |
| `care_team_tag_id` | Historical care team tag |
| `app_version` | App version |

### 9.3 `dwh.dim_current_commodity_stock`

One row per commodity with the latest current stock.

Use this for current stock dashboards.

### 9.4 `dwh.fact_commodity_stockout_periods`

One row per stockout Flag.

Use this for current stockout and stockout duration reports.

---

## 10. Recommended reporting joins

### 10.1 Join commodity stock to reporting location

```sql
SELECT
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    cs.commodity_name,
    cs.running_balance,
    cs.running_balance_unit,
    cs.last_updated
FROM dwh.dim_current_commodity_stock cs
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(cs.location_id, cs.location_tag_id)
ORDER BY dl.reporting_facility_name, cs.commodity_name;
```

### 10.2 Join commodity movements to reporting location

```sql
SELECT
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    m.commodity_name,
    m.movement_type,
    SUM(COALESCE(m.event_quantity, 0)) AS total_quantity
FROM dwh.fact_commodity_stock_movements m
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(m.location_id, m.location_tag_id)
GROUP BY
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    m.commodity_name,
    m.movement_type
ORDER BY dl.reporting_facility_name, m.commodity_name, m.movement_type;
```

---

## 11. Example reports

### 11.1 Current stock by commodity

```sql
SELECT
    commodity_name,
    running_balance,
    running_balance_unit,
    location_id,
    location_tag_id,
    last_updated
FROM dwh.dim_current_commodity_stock
ORDER BY commodity_name;
```

### 11.2 Current stock by reporting facility

```sql
SELECT
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    cs.commodity_name,
    cs.running_balance,
    cs.running_balance_unit,
    cs.last_updated
FROM dwh.dim_current_commodity_stock cs
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(cs.location_id, cs.location_tag_id)
ORDER BY dl.reporting_facility_name, cs.commodity_name;
```

### 11.3 Monthly consumption by commodity

```sql
SELECT
    DATE_TRUNC('month', m.effective_datetime)::date AS report_month,
    m.commodity_name,
    SUM(COALESCE(m.event_quantity, 0)) AS quantity_consumed
FROM dwh.fact_commodity_stock_movements m
WHERE m.movement_type = 'consumption'
  AND m.effective_datetime >= DATE '2026-06-01'
  AND m.effective_datetime < DATE '2026-07-01'
GROUP BY
    DATE_TRUNC('month', m.effective_datetime)::date,
    m.commodity_name
ORDER BY report_month, m.commodity_name;
```

### 11.4 Monthly restocks by commodity

```sql
SELECT
    DATE_TRUNC('month', m.effective_datetime)::date AS report_month,
    m.commodity_name,
    SUM(COALESCE(m.event_quantity, 0)) AS quantity_restocked
FROM dwh.fact_commodity_stock_movements m
WHERE m.movement_type = 'restock'
GROUP BY
    DATE_TRUNC('month', m.effective_datetime)::date,
    m.commodity_name
ORDER BY report_month, m.commodity_name;
```

### 11.5 Current stockouts

```sql
SELECT
    s.commodity_name,
    s.stockout_started_at,
    s.stockout_duration,
    s.location_tag_id
FROM dwh.fact_commodity_stockout_periods s
WHERE s.is_current_stockout = true
ORDER BY s.stockout_started_at DESC;
```

### 11.6 Stockouts by reporting facility

```sql
SELECT
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    s.commodity_name,
    COUNT(*) AS stockout_events,
    COUNT(*) FILTER (WHERE s.is_current_stockout = true) AS current_stockouts
FROM dwh.fact_commodity_stockout_periods s
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = s.location_tag_id
GROUP BY
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    s.commodity_name
ORDER BY dl.reporting_facility_name, s.commodity_name;
```

---

## 12. Materialized view examples

### 12.1 Monthly commodity movement summary

```sql
CREATE MATERIALIZED VIEW IF NOT EXISTS dwh.mv_commodity_monthly_movements AS
SELECT
    DATE_TRUNC('month', m.effective_datetime)::date AS report_month,
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    m.commodity_name,
    m.movement_type,
    SUM(COALESCE(m.event_quantity, 0)) AS total_quantity,
    COUNT(*) AS movement_records
FROM dwh.fact_commodity_stock_movements m
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(m.location_id, m.location_tag_id)
GROUP BY
    DATE_TRUNC('month', m.effective_datetime)::date,
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    m.commodity_name,
    m.movement_type;
```

Refresh after daily DWH refresh:

```sql
REFRESH MATERIALIZED VIEW dwh.mv_commodity_monthly_movements;
```

### 12.2 Current stock materialized view

This is optional because `dwh.dim_current_commodity_stock` is already a current-state table. Create a materialized view only if the BI tool needs a special flattened output.

```sql
CREATE MATERIALIZED VIEW IF NOT EXISTS dwh.mv_commodity_current_stock_by_facility AS
SELECT
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    cs.commodity_name,
    cs.running_balance,
    cs.running_balance_unit,
    cs.last_updated
FROM dwh.dim_current_commodity_stock cs
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(cs.location_id, cs.location_tag_id);
```

---

## 13. Validation checks

### 13.1 Check commodity list

```sql
SELECT
    commodity_name,
    unit_text,
    unit_display,
    COUNT(*) AS records
FROM dwh.dim_commodities
GROUP BY commodity_name, unit_text, unit_display
ORDER BY commodity_name;
```

### 13.2 Check movement types

```sql
SELECT
    movement_type,
    COUNT(*) AS records
FROM dwh.fact_commodity_stock_movements
GROUP BY movement_type
ORDER BY records DESC;
```

### 13.3 Check current stock records

```sql
SELECT
    commodity_name,
    COUNT(*) AS records,
    COUNT(running_balance) AS records_with_balance
FROM dwh.dim_current_commodity_stock
GROUP BY commodity_name
ORDER BY commodity_name;
```

### 13.4 Check movements missing commodity details

```sql
SELECT
    commodity_id,
    COUNT(*) AS records
FROM dwh.fact_commodity_stock_movements
WHERE commodity_name IS NULL
GROUP BY commodity_id
ORDER BY records DESC;
```

### 13.5 Check stockout counts

```sql
SELECT
    commodity_name,
    is_current_stockout,
    COUNT(*) AS records
FROM dwh.fact_commodity_stockout_periods
GROUP BY commodity_name, is_current_stockout
ORDER BY commodity_name, is_current_stockout;
```

### 13.6 Check duplicate movement rows

```sql
SELECT
    observation_id,
    COUNT(*) AS total
FROM dwh.fact_commodity_stock_movements
GROUP BY observation_id
HAVING COUNT(*) > 1;
```

### 13.7 Check duplicate stockout rows

```sql
SELECT
    flag_id,
    COUNT(*) AS total
FROM dwh.fact_commodity_stockout_periods
GROUP BY flag_id
HAVING COUNT(*) > 1;
```

---

## 14. Maintenance notes

1. Use `dwh.dim_current_commodity_stock` for current stock dashboards.
2. Use `dwh.fact_commodity_stock_movements` for period movement reports.
3. Use `dwh.fact_commodity_stockout_periods` for stockout dashboards.
4. Current stock is based on the latest preliminary Observation per commodity.
5. Period reporting should normally use final Observations, depending on the indicator definition.
6. If a commodity is missing a name or unit, check `dwh.dim_commodities` and the raw FHIR Group resource.
7. If stock movement rows are missing location mapping, check `location_id`, `location_tag_id`, and `dwh.dim_locations`.
8. Refresh commodity outputs through:

```sql
CALL dwh.refresh_supply_cebs_reporting();
```

9. If materialized views are used by BI tools, refresh them after the DWH refresh.

---

## 15. Common interpretation notes

### Current stock

Current stock should come from:

```text

dwh.dim_current_commodity_stock.running_balance
```

Do not calculate current stock by summing all historical movements unless you have a clear reconciliation requirement.

### Period consumption

Period consumption should come from:

```text

dwh.fact_commodity_stock_movements
WHERE movement_type = 'consumption'
```

Then sum `event_quantity` for the reporting period.

### Stockout duration

Stockout duration should come from:

```text

dwh.fact_commodity_stockout_periods.stockout_duration
```

For active stockouts, the duration is calculated from the start date to the current refresh time.

### Location reporting

Always join to `dwh.dim_locations` when reporting by facility, district, subcounty, parish, village, or DHIS2 organisation unit.

Recommended join:

```sql
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(x.location_id, x.location_tag_id)
```

For stockout flags, location is usually from `location_tag_id`:

```sql
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = s.location_tag_id
```
