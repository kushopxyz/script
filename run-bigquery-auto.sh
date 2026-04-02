
#!/usr/bin/env bash
set -e

echo "==> Get current project"
PROJECT_ID=$(gcloud config get-value project)

echo "==> Project: $PROJECT_ID"

DATASET_ID="auto_dataset"
TABLE_ID="auto_table"

echo "==> Enable BigQuery API"
gcloud services enable bigquery.googleapis.com

echo "==> Create dataset"
bq mk -d --force \
  --location=US \
  "$PROJECT_ID:$DATASET_ID" 2>/dev/null || true

echo "==> Create table"
bq mk -t --force \
  "$PROJECT_ID:$DATASET_ID.$TABLE_ID" \
  id:INT64,name:STRING,created_at:TIMESTAMP 2>/dev/null || true

echo "==> Insert data"
bq query --use_legacy_sql=false <<EOF
INSERT INTO \`$PROJECT_ID.$DATASET_ID.$TABLE_ID\`
VALUES
  (1, 'CloudShell', CURRENT_TIMESTAMP()),
  (2, 'BigQuery', CURRENT_TIMESTAMP());
EOF

echo "==> Query result"
bq query --use_legacy_sql=false <<EOF
SELECT * FROM \`$PROJECT_ID.$DATASET_ID.$TABLE_ID\`
ORDER BY created_at DESC
LIMIT 5;
EOF

echo
echo "====================================="
echo "✅ DONE - BigQuery chạy OK"
echo "👉 Dataset: $DATASET_ID"
echo "👉 Table: $TABLE_ID"
echo "====================================="
