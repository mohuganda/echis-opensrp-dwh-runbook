-- 99-run-all-setup.sql
-- Convenience script for psql only. GUI tools like DBeaver/pgAdmin should run files one by one.

\i sql/00-check-airbyte-source.sql
\i sql/01-core-schema-functions.sql
\i sql/02-location-dhis2-mapping/01-create-tables-views-indexes.sql
\i sql/02-location-dhis2-mapping/02-import-seed-template.sql
\i sql/02-location-dhis2-mapping/03-create-refresh-procedure.sql
\i sql/03-admin-practitioners-organizations/01-create-tables-indexes.sql
\i sql/03-admin-practitioners-organizations/02-create-refresh-procedure.sql
\i sql/04-clients-households/01-create-tables-indexes.sql
\i sql/04-clients-households/02-create-refresh-procedure.sql
\i sql/05-program-facts/01-create-fact-tables.sql
\i sql/05-program-facts/02-create-fact-indexes.sql
\i sql/05-program-facts/03-create-incremental-refresh-procedure.sql
\i sql/06-reference-codes/01-create-reference-tables.sql
\i sql/06-reference-codes/02-create-refresh-procedure.sql
\i sql/07-patient-program-status/01-create-tables-codes-procedure.sql
\i sql/08-commodity-cebs/01-create-tables-indexes.sql
\i sql/08-commodity-cebs/02-create-semi-incremental-refresh-procedure.sql
\i sql/09-daily-refresh/01-create-refresh-all-daily.sql
