# Troubleshooting

## Check failed refreshes

```sql
SELECT *
FROM dwh.refresh_state
WHERE status = 'failed';
```

## Check running queries

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

## Cancel a query

```sql
SELECT pg_cancel_backend(<pid>);
```

## Terminate a query if cancel does not work

```sql
SELECT pg_terminate_backend(<pid>);
```

## Check DWH table sizes

```sql
SELECT
    schemaname,
    relname,
    pg_size_pretty(pg_total_relation_size(format('%I.%I', schemaname, relname))) AS total_size
FROM pg_stat_user_tables
WHERE schemaname = 'dwh'
ORDER BY pg_total_relation_size(format('%I.%I', schemaname, relname)) DESC;
```
