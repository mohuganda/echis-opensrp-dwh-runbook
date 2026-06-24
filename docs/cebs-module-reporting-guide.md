# CEBS Module Reporting Guide

## 1. Purpose

This document explains how CEBS data is represented in OpenSRP/eCHIS FHIR resources and how the DWH reporting layer turns that data into tables that are easier to use in dashboards and reports.

It is intended for MoH administrators, database administrators, analytics users, and dashboard developers who need to understand where CEBS reporting data comes from and how to query it safely.

The main DWH tables used for CEBS reporting are:

```text

dwh.fact_cebs_observation_components
dwh.fact_cebs_observations
dwh.ref_cebs_signal_types
```

The most commonly used table for reporting is:

```text

dwh.fact_cebs_observations
```

Use the component table only when you need to inspect the original detailed component values.

---

## 2. Plain-language overview

CEBS reports are stored mainly as FHIR `Observation` resources.

A VHT submits a CEBS signal report from the app. The app creates one CEBS Observation. The Observation can represent either:

1. A no-signal report; or
2. A detected signal that needs supervisor verification.

If a VHT reports that there was no signal, the Observation is created as final and no supervisor verification Task is created.

If a VHT reports a signal, the Observation is created as preliminary. A verification Task is also created for a supervisor or CHEW to review the signal.

When the supervisor verifies the signal, the same Observation is updated. A new CEBS Observation is not created for the verification outcome. This is important for reporting because the same `observation_id` changes status over time.

---

## 3. CEBS workflow summary

| Stage | FHIR resource behavior | Reporting meaning |
| --- | --- | --- |
| VHT reports no signal | Creates an Observation with `status = final` and category `surveillance-no-signal` | The location submitted a no-signal report |
| VHT reports a signal | Creates an Observation with `status = preliminary` and category `surveillance` | A signal is awaiting supervisor verification |
| Supervisor confirms the threat | Updates the same Observation to `status = final` | The signal became a verified threat |
| Supervisor dismisses the threat | Updates the same Observation to `status = cancelled` | The signal was reviewed and ruled out |

In the DWH, this is simplified into `cebs_status_label`:

| Observation status/category | DWH status label |
| --- | --- |
| `preliminary` | `awaiting_verification` |
| `final` + `surveillance` | `verified_threat` |
| `final` + `surveillance-no-signal` | `no_signal` |
| `cancelled` | `dismissed` |

---

## 4. Raw FHIR pattern

### 4.1 No-signal report

When the VHT answers that there was no signal:

```text
Observation.status = final
Observation.category = http://moh.go.ug/CodeSystem/cebs-category | surveillance-no-signal
Observation.code = http://moh.go.ug/CodeSystem/cebs-signal-type | no-signal
Observation.value = No signal
Observation.subject = Location/<VHT location id>
```

The Observation contains components for VHT identity:

| Component code | Component system | Meaning |
| --- | --- | --- |
| `vht-name` | `http://moh.go.ug/CodeSystem/cebs-data` | VHT full name |
| `vht-phone` | `http://moh.go.ug/CodeSystem/cebs-data` | VHT phone number |
| `vht-village` | `http://moh.go.ug/CodeSystem/cebs-data` | VHT village |
| `reporter-id` | `http://moh.go.ug/CodeSystem/cebs-data` | VHT practitioner ID |

No verification Task is created for a no-signal report.

### 4.2 Signal detected report

When the VHT reports that a signal was detected:

```text
Observation.status = preliminary
Observation.category = http://moh.go.ug/CodeSystem/cebs-category | surveillance
Observation.code = selected signal type
Observation.value = free-text signal description entered by the VHT
Observation.subject = Location/<VHT location id>
Observation.performer = Practitioner/<VHT practitioner id>
```

The Observation contains VHT identity and GPS components:

| Component code | Component system | Meaning |
| --- | --- | --- |
| `vht-name` | `http://moh.go.ug/CodeSystem/cebs-data` | VHT full name |
| `vht-phone` | `http://moh.go.ug/CodeSystem/cebs-data` | VHT phone number |
| `vht-village` | `http://moh.go.ug/CodeSystem/cebs-data` | VHT village |
| `reporter-id` | `http://moh.go.ug/CodeSystem/cebs-data` | VHT practitioner ID |
| `latitude` | `http://moh.go.ug/CodeSystem/cebs-location` | GPS latitude |
| `longitude` | `http://moh.go.ug/CodeSystem/cebs-location` | GPS longitude |

A Task is also created:

```text
Task.code = cebs-task | verify-signal
Task.status = requested
Task.focus = Observation/<CEBS observation id>
```

The supervisor works from this Task.

### 4.3 Supervisor verification

The supervisor does not create a new Observation. Instead, the supervisor form updates the same Observation.

The Task is also updated:

```text
Task.status = completed
Task.output = reference to the supervisor QuestionnaireResponse
```

The Observation is updated as follows:

| Field | Value |
| --- | --- |
| `status` | `final` if the threat is confirmed, `cancelled` if the threat is dismissed |
| `value` | Overwritten with the supervisor's signal description |
| `performer[0]` | VHT practitioner reference |
| `performer[1]` | Supervisor practitioner reference |

The supervisor update replaces the component list. The original VHT details are re-added from hidden fields, and new verification fields are added.

Important reporting note:

```text
The VHT's original free-text description is moved into the vht-signal-description component.
The top-level Observation value becomes the supervisor's description after verification.
```

---

## 5. CEBS signal type reference

The DWH uses `dwh.ref_cebs_signal_types` to provide readable labels for known CEBS signal codes.

Recommended signal codes include:

| Signal code | Label |
| --- | --- |
| `no-signal` | No Signal Reported |
| `fever-with-bleeding-or-yellow-or-red-eyes` | Any person with fever and signs of bleeding, red or yellow eyes |
| `unexplained-rash-with-fever-and-weakness` | Any person with unexplained rash plus fever and body weakness |
| `animal-sudden-death-or-strange-behavior` | Any sudden or unexplained death or strange behaviour in animals |
| `dog-or-wild-animal-bite` | Any person bitten by a dog or wild animal |
| `abnormal-change-in-water` | Any abnormal change in drinking water color, smell, or taste |
| `abrupt-climate-event` | Any abrupt climate-related event like heatwaves, floods, or droughts |
| `other-public-health-threat` | Any other public health threat |

If a new CEBS signal code is added to the app, add it to:

```text

dwh.ref_cebs_signal_types
```

Then refresh CEBS reporting:

```sql
CALL dwh.refresh_supply_cebs_reporting();
```

---

## 6. DWH reporting tables

### 6.1 `dwh.fact_cebs_observation_components`

This table has one row per CEBS Observation component.

Use it when you need to inspect detailed component values such as:

```text
vht-name
vht-phone
vht-village
reporter-id
latitude
longitude
verification-method
supervisor-signal-description
chew-people-ill
chew-people-dead
facility-informed-date
additional-information
chew-name
chew-phone
verifier-id
```

Typical use:

```sql
SELECT
    observation_id,
    component_code,
    component_label,
    component_value_text
FROM dwh.fact_cebs_observation_components
WHERE observation_id = '<observation-id>'
ORDER BY component_index;
```

### 6.2 `dwh.fact_cebs_observations`

This is the main reporting table.

It has one row per CEBS Observation and exposes the useful components as normal columns.

Use this table for dashboards and summary reports.

Important columns:

| Column | Meaning |
| --- | --- |
| `observation_id` | CEBS Observation ID |
| `effective_datetime` | Date/time of the CEBS report |
| `observation_status` | Raw FHIR Observation status |
| `cebs_status_label` | Reporting-friendly status |
| `has_signal` | True for signal reports, false for no-signal reports |
| `location_id` | Location from the Observation subject or tag |
| `signal_code` | CEBS signal code |
| `reviewed_signal_label` | Human-readable signal label |
| `signal_description` | Current top-level signal description |
| `vht_name` | VHT name captured in the component |
| `vht_phone` | VHT phone captured in the component |
| `vht_village` | VHT village captured in the component |
| `reporter_practitioner_id` | VHT practitioner ID |
| `latitude`, `longitude` | GPS coordinates |
| `verification_method` | How the supervisor verified the signal |
| `supervisor_signal_description` | Supervisor's description |
| `vht_signal_description` | Original VHT description after verification |
| `chew_people_ill` | Number of people ill |
| `chew_people_dead` | Number of people dead |
| `animal_health_referral` | Animal health referral field |
| `additional_information` | Additional notes |
| `chew_name`, `chew_phone` | Supervisor/CHEW details |
| `verifier_practitioner_id` | Supervisor practitioner ID |
| `location_tag_id` | Historical practitioner location tag |
| `organization_tag_id` | Historical organization tag |
| `care_team_tag_id` | Historical care team tag |
| `app_version` | App version that generated the resource |

---

## 7. Recommended reporting joins

### 7.1 Join CEBS to reporting location

Use this pattern:

```sql
SELECT
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    c.cebs_status_label,
    c.reviewed_signal_label,
    COUNT(*) AS total
FROM dwh.fact_cebs_observations c
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(c.location_id, c.location_tag_id)
GROUP BY
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    c.cebs_status_label,
    c.reviewed_signal_label
ORDER BY
    dl.reporting_facility_name,
    c.cebs_status_label,
    c.reviewed_signal_label;
```

### 7.2 Join CEBS to VHT assignment

```sql
SELECT
    c.observation_id,
    c.effective_datetime,
    c.reviewed_signal_label,
    c.cebs_status_label,
    c.vht_name,
    pa.practitioner_name AS assignment_practitioner_name,
    pa.assigned_location_name
FROM dwh.fact_cebs_observations c
LEFT JOIN dwh.dim_practitioner_assignments pa
    ON pa.practitioner_id = c.reporter_practitioner_id;
```

Use practitioner assignment for current configured assignment. Do not use it to overwrite historical CEBS location tags.

---

## 8. Example reports

### 8.1 CEBS summary by status

```sql
SELECT
    cebs_status_label,
    COUNT(*) AS total
FROM dwh.fact_cebs_observations
GROUP BY cebs_status_label
ORDER BY total DESC;
```

### 8.2 CEBS summary by signal type

```sql
SELECT
    reviewed_signal_label,
    COUNT(*) AS total
FROM dwh.fact_cebs_observations
GROUP BY reviewed_signal_label
ORDER BY total DESC;
```

### 8.3 CEBS monthly report

```sql
SELECT
    DATE_TRUNC('month', effective_datetime)::date AS report_month,
    cebs_status_label,
    reviewed_signal_label,
    COUNT(*) AS total
FROM dwh.fact_cebs_observations
WHERE effective_datetime >= DATE '2026-06-01'
  AND effective_datetime < DATE '2026-07-01'
GROUP BY
    DATE_TRUNC('month', effective_datetime)::date,
    cebs_status_label,
    reviewed_signal_label
ORDER BY report_month, cebs_status_label, reviewed_signal_label;
```

### 8.4 Pending CEBS verification

```sql
SELECT
    observation_id,
    effective_datetime,
    reviewed_signal_label,
    signal_description,
    vht_name,
    vht_phone,
    vht_village,
    location_id
FROM dwh.fact_cebs_observations
WHERE cebs_status_label = 'awaiting_verification'
ORDER BY effective_datetime DESC;
```

### 8.5 Verified threats by facility

```sql
SELECT
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    c.reviewed_signal_label,
    COUNT(*) AS total
FROM dwh.fact_cebs_observations c
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(c.location_id, c.location_tag_id)
WHERE c.cebs_status_label = 'verified_threat'
GROUP BY
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    c.reviewed_signal_label
ORDER BY total DESC;
```

---

## 9. Materialized view example

If the BI tool prefers materialized views, create a summary view like this:

```sql
CREATE MATERIALIZED VIEW IF NOT EXISTS dwh.mv_cebs_monthly_summary AS
SELECT
    DATE_TRUNC('month', c.effective_datetime)::date AS report_month,
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    c.cebs_status_label,
    c.reviewed_signal_label,
    COUNT(*) AS total_reports
FROM dwh.fact_cebs_observations c
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(c.location_id, c.location_tag_id)
GROUP BY
    DATE_TRUNC('month', c.effective_datetime)::date,
    dl.reporting_facility_name,
    dl.reporting_dhis2_orgunit_uid,
    c.cebs_status_label,
    c.reviewed_signal_label;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_cebs_monthly_summary_unique
ON dwh.mv_cebs_monthly_summary (
    report_month,
    COALESCE(reporting_dhis2_orgunit_uid, ''),
    cebs_status_label,
    reviewed_signal_label
);
```

Refresh it after the daily DWH refresh:

```sql
REFRESH MATERIALIZED VIEW dwh.mv_cebs_monthly_summary;
```

If the unique index works in your PostgreSQL version and all grouped fields are suitable, you may use:

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY dwh.mv_cebs_monthly_summary;
```

---

## 10. Validation checks

### 10.1 Check CEBS status counts

```sql
SELECT
    cebs_status_label,
    COUNT(*) AS total
FROM dwh.fact_cebs_observations
GROUP BY cebs_status_label
ORDER BY total DESC;
```

### 10.2 Check CEBS signal labels

```sql
SELECT
    signal_code,
    reviewed_signal_label,
    COUNT(*) AS total
FROM dwh.fact_cebs_observations
GROUP BY signal_code, reviewed_signal_label
ORDER BY total DESC;
```

### 10.3 Check CEBS records without reporting location

```sql
SELECT
    c.location_id,
    c.location_tag_id,
    COUNT(*) AS records
FROM dwh.fact_cebs_observations c
LEFT JOIN dwh.dim_locations dl
    ON dl.location_id = COALESCE(c.location_id, c.location_tag_id)
WHERE dl.location_id IS NULL
GROUP BY c.location_id, c.location_tag_id
ORDER BY records DESC;
```

### 10.4 Check duplicate CEBS component rows

```sql
SELECT
    observation_id,
    component_index,
    COUNT(*) AS total
FROM dwh.fact_cebs_observation_components
GROUP BY observation_id, component_index
HAVING COUNT(*) > 1;
```

### 10.5 Check duplicate CEBS wide rows

```sql
SELECT
    observation_id,
    COUNT(*) AS total
FROM dwh.fact_cebs_observations
GROUP BY observation_id
HAVING COUNT(*) > 1;
```

---

## 11. Maintenance notes

1. `dwh.fact_cebs_observations` is the main table for reporting.
2. `dwh.fact_cebs_observation_components` is mainly for debugging and detailed inspection.
3. CEBS signal reports can change status because supervisor verification updates the same Observation.
4. Do not assume every CEBS record is final. Always check `cebs_status_label`.
5. If new signal codes are introduced in the app, update `dwh.ref_cebs_signal_types`.
6. If a CEBS record is missing location mapping, review `dwh.dim_locations` and the location/DHIS2 seed.
7. Refresh CEBS outputs through:

```sql
CALL dwh.refresh_supply_cebs_reporting();
```

8. If a materialized view is used for dashboards, refresh the materialized view after the DWH refresh.
