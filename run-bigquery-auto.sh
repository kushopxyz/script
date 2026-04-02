#!/usr/bin/env bash
set -e

echo "==> Get current project"
PROJECT_ID="$(gcloud config get-value project)"

if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
  echo "❌ No active project found"
  echo "Run: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi

echo "==> Project: $PROJECT_ID"

DATASET_ID="auto_dataset"
TABLE_ID="auto_table"
LOCATION="US"

echo "==> Enable BigQuery API"
gcloud services enable bigquery.googleapis.com >/dev/null 2>&1 || true

echo "==> Create dataset"
bq mk -d --force \
  --location="$LOCATION" \
  "$PROJECT_ID:$DATASET_ID" >/dev/null 2>&1 || true

echo "==> Create table with free-tier friendly query"
bq query --use_legacy_sql=false <<EOF
CREATE OR REPLACE TABLE \`$PROJECT_ID.$DATASET_ID.$TABLE_ID\` AS
SELECT 1 AS id, 'CloudShell' AS name, CURRENT_TIMESTAMP() AS created_at
UNION ALL
SELECT 2 AS id, 'BigQuery' AS name, CURRENT_TIMESTAMP() AS created_at
UNION ALL
SELECT 3 AS id, 'Sandbox' AS name, CURRENT_TIMESTAMP() AS created_at;
EOF

echo "==> Query result"
bq query --use_legacy_sql=false <<EOF
SELECT *
FROM \`$PROJECT_ID.$DATASET_ID.$TABLE_ID\`
ORDER BY created_at DESC
LIMIT 10;
EOF

echo
echo "====================================="
echo "✅ DONE - BigQuery free tier OK"
echo "Project : $PROJECT_ID"
echo "Dataset : $DATASET_ID"
echo "Table   : $TABLE_ID"
echo "====================================="
