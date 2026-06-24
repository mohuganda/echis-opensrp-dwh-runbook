#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/echis-dwh/dwh.env}"

if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

export PGPASSWORD="${DWH_PASSWORD}"

psql \
  --host="${DWH_HOST}" \
  --port="${DWH_PORT:-5432}" \
  --dbname="${DWH_DB}" \
  --username="${DWH_USER}" \
  --set=ON_ERROR_STOP=1 \
  --command="CALL dwh.refresh_all_daily();"
