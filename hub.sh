
#!/usr/bin/env bash
set -Eeuo pipefail

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Missing command: $1"
    exit 1
  }
}

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

safe_add_iam() {
  local member="$1"
  local role="$2"

  if gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
      --member="${member}" \
      --role="${role}" \
      --quiet >/dev/null 2>&1; then
    ok "Granted ${role} to ${member}"
  else
    warn "Could not grant ${role} to ${member}. Continuing."
  fi
}

need_cmd gcloud
need_cmd sed
need_cmd tr
need_cmd date

PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  err "No active project in gcloud."
  err "Run: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi

if [[ -z "${ACCOUNT}" || "${ACCOUNT}" == "(unset)" ]]; then
  err "No active account in gcloud."
  err "Run: gcloud auth login"
  exit 1
fi

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
MEMBER="user:${ACCOUNT}"

BASE_APP_ID="$(slugify "app-${PROJECT_ID}")"
APP_ID="${BASE_APP_ID:0:62}"
APP_DISPLAY_NAME="App ${PROJECT_ID}"
APP_DESCRIPTION="Auto-created by Cloud Shell on $(date -u +%F)"

info "Project ID      : ${PROJECT_ID}"
info "Project Number  : ${PROJECT_NUMBER}"
info "Account         : ${ACCOUNT}"
info "Application ID  : ${APP_ID}"

info "Updating gcloud components (best effort)..."
gcloud components update --quiet || warn "gcloud components update skipped or failed."

info "Setting default project..."
gcloud config set project "${PROJECT_ID}" >/dev/null
ok "Default project set"

info "Enabling App Hub API..."
gcloud services enable apphub.googleapis.com \
  --project "${PROJECT_ID}"
ok "App Hub API enabled"

info "Ensuring project is attached to itself as a single-project boundary..."
if gcloud apphub boundary describe \
    --project="${PROJECT_ID}" \
    --location=global >/dev/null 2>&1; then
  ok "Boundary already exists"
else
  gcloud apphub boundary update \
    --crm-node="projects/${PROJECT_ID}" \
    --project="${PROJECT_ID}" \
    --location=global
  ok "Boundary created"
fi

info "Verifying boundary..."
gcloud apphub boundary describe \
  --project="${PROJECT_ID}" \
  --location=global

info "Granting App Hub Admin to current account (best effort)..."
safe_add_iam "${MEMBER}" "roles/apphub.admin"

info "Checking whether application already exists..."
if gcloud apphub applications describe "${APP_ID}" \
    --location=global \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
  ok "Application already exists: ${APP_ID}"
else
  info "Creating global application..."
  gcloud apphub applications create "${APP_ID}" \
    --location=global \
    --display-name="${APP_DISPLAY_NAME}" \
    --description="${APP_DESCRIPTION}" \
    --project="${PROJECT_ID}"
  ok "Application created: ${APP_ID}"
fi

echo
ok "App Hub single-project setup is complete."
echo
echo "Summary:"
echo "  Project      : ${PROJECT_ID}"
echo "  Account      : ${ACCOUNT}"
echo "  Boundary     : projects/${PROJECT_ID}/locations/global/boundary"
echo "  Application  : ${APP_ID}"
echo

info "Listing applications..."
gcloud apphub applications list \
  --location=global \
  --project="${PROJECT_ID}" || true

echo
info "Discovered services in global:"
gcloud apphub discovered-services list \
  --location=global \
  --project="${PROJECT_ID}" || true

echo
info "Discovered workloads in global:"
gcloud apphub discovered-workloads list \
  --location=global \
  --project="${PROJECT_ID}" || true

echo
ok "Done."
