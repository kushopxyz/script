#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ID="${PROJECT_ID:-}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

ensure_project() {
  need_cmd gcloud

  if [ -n "$PROJECT_ID" ]; then
    return
  fi

  PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
  if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
    read -r -p "Enter PROJECT_ID: " PROJECT_ID
    gcloud config set project "$PROJECT_ID" >/dev/null
  fi

  echo "Using project: $PROJECT_ID"
}

run_nginx() {
  local app_dir="$SCRIPT_DIR/nginx-demo"

  echo "==> Starting nginx setup"
  need_cmd docker

  mkdir -p "$app_dir/html"

  cat > "$app_dir/html/index.html" <<'EOF'
<!DOCTYPE html>
<html>
<head>
  <title>Hello Nginx</title>
</head>
<body style="background:#111;color:#0f0;font-family:monospace;text-align:center;margin-top:20%;">
  <h1>Hello World from Nginx (Docker)</h1>
</body>
</html>
EOF

  cat > "$app_dir/docker-compose.yml" <<'EOF'
services:
  nginx:
    image: nginx:alpine
    container_name: nginx-demo
    ports:
      - "8080:80"
    volumes:
      - ./html:/usr/share/nginx/html:ro
    restart: unless-stopped
EOF

  pushd "$app_dir" >/dev/null
  docker compose up -d
  popd >/dev/null

  echo "Nginx is available at http://localhost:8080"
}

run_firebase() {
  local app_dir="$SCRIPT_DIR/firebase-auto-app"

  echo "==> Starting Firebase setup"
  need_cmd firebase
  ensure_project

  echo "==> Enable Firebase Management API"
  gcloud services enable firebase.googleapis.com --project "$PROJECT_ID"

  echo "==> Enable Firebase Hosting API"
  gcloud services enable firebasehosting.googleapis.com --project "$PROJECT_ID" || true

  echo "==> Waiting for API propagation"
  sleep 20

  echo "==> Add Firebase to project"
  firebase projects:addfirebase "$PROJECT_ID" || true

  mkdir -p "$app_dir/public"

  cat > "$app_dir/public/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1.0">
  <title>Hello Firebase</title>
  <style>
    body {
      margin: 0;
      background: #0f172a;
      color: #e5e7eb;
      font-family: Arial, sans-serif;
      display: grid;
      place-items: center;
      height: 100vh;
    }
    .card {
      background: #111827;
      padding: 32px;
      border-radius: 16px;
      box-shadow: 0 10px 30px rgba(0,0,0,.35);
      text-align: center;
    }
  </style>
</head>
<body>
  <div class="card">
    <h1>Hello World from Firebase Hosting</h1>
    <p>Project: $PROJECT_ID</p>
  </div>
</body>
</html>
EOF

  cat > "$app_dir/firebase.json" <<'EOF'
{
  "hosting": {
    "public": "public",
    "ignore": [
      "firebase.json",
      "**/.*",
      "**/node_modules/**"
    ],
    "cleanUrls": true
  }
}
EOF

  pushd "$app_dir" >/dev/null
  echo "==> Deploy Hosting"
  firebase deploy --only hosting --project "$PROJECT_ID" --non-interactive
  popd >/dev/null

  echo "Firebase URL: https://$PROJECT_ID.web.app"
  echo "Firebase backup URL: https://$PROJECT_ID.firebaseapp.com"
}

run_bigquery() {
  local dataset_id="auto_dataset"
  local table_id="auto_table"
  local location="US"

  echo "==> Starting BigQuery setup"
  need_cmd bq
  ensure_project

  echo "==> Enable BigQuery API"
  gcloud services enable bigquery.googleapis.com --project "$PROJECT_ID" >/dev/null 2>&1 || true

  echo "==> Create dataset"
  bq mk -d --force --location="$location" "$PROJECT_ID:$dataset_id" >/dev/null 2>&1 || true

  echo "==> Create table"
  bq query --use_legacy_sql=false <<EOF
CREATE OR REPLACE TABLE \`$PROJECT_ID.$dataset_id.$table_id\` AS
SELECT 1 AS id, 'CloudShell' AS name, CURRENT_TIMESTAMP() AS created_at
UNION ALL
SELECT 2 AS id, 'BigQuery' AS name, CURRENT_TIMESTAMP() AS created_at
UNION ALL
SELECT 3 AS id, 'Sandbox' AS name, CURRENT_TIMESTAMP() AS created_at;
EOF

  echo "==> Query result"
  bq query --use_legacy_sql=false <<EOF
SELECT *
FROM \`$PROJECT_ID.$dataset_id.$table_id\`
ORDER BY created_at DESC
LIMIT 10;
EOF

  echo "BigQuery dataset: $dataset_id"
  echo "BigQuery table: $table_id"
}

main() {
  run_nginx
  run_firebase
  run_bigquery

  echo
  echo "All steps completed."
}

main "$@"
