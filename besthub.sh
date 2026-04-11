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

app_exists() {
  gcloud apphub applications describe "${APP_ID}" \
    --location=global \
    --project="${PROJECT_ID}" >/dev/null 2>&1
}

workload_exists() {
  local workload_id="$1"
  gcloud apphub applications workloads describe "${workload_id}" \
    --application="${APP_ID}" \
    --location=global \
    --project="${PROJECT_ID}" >/dev/null 2>&1
}

service_exists() {
  local service_id="$1"
  gcloud apphub applications services describe "${service_id}" \
    --application="${APP_ID}" \
    --location=global \
    --project="${PROJECT_ID}" >/dev/null 2>&1
}

register_discovered_workloads() {
  local any_registered="false"
  local locations
  locations="$(gcloud apphub locations list --project="${PROJECT_ID}" --format='value(locationId)' 2>/dev/null || true)"

  {
    printf '%s\n' "global"
    printf '%s\n' "${locations}"
  } | awk 'NF' | sort -u | while read -r loc; do
    info "Checking discovered workloads in location: ${loc}"

    local names
    names="$(gcloud apphub discovered-workloads list \
      --location="${loc}" \
      --project="${PROJECT_ID}" \
      --format='value(name.basename())' 2>/dev/null || true)"

    if [[ -z "${names}" ]]; then
      continue
    fi

    while read -r discovered_name; do
      [[ -z "${discovered_name}" ]] && continue

      local workload_id
      workload_id="$(slugify "wl-${discovered_name}")"
      workload_id="${workload_id:0:62}"

      if workload_exists "${workload_id}"; then
        warn "Workload already registered: ${workload_id}"
        continue
      fi

      info "Registering discovered workload: ${discovered_name}"
      if gcloud apphub applications workloads create "${workload_id}" \
          --application="${APP_ID}" \
          --location=global \
          --project="${PROJECT_ID}" \
          --discovered-workload="projects/${PROJECT_ID}/locations/${loc}/discoveredWorkloads/${discovered_name}" \
          --display-name="${discovered_name}" \
          --description="Auto-registered discovered workload ${discovered_name}" \
          --criticality-type=MISSION_CRITICAL \
          --environment-type=PRODUCTION >/dev/null 2>&1; then
        ok "Registered workload: ${workload_id}"
        any_registered="true"
      else
        warn "Could not register workload: ${discovered_name}"
      fi
    done <<< "${names}"
  done
}

register_discovered_services() {
  local any_registered="false"
  local locations
  locations="$(gcloud apphub locations list --project="${PROJECT_ID}" --format='value(locationId)' 2>/dev/null || true)"

  {
    printf '%s\n' "global"
    printf '%s\n' "${locations}"
  } | awk 'NF' | sort -u | while read -r loc; do
    info "Checking discovered services in location: ${loc}"

    local names
    names="$(gcloud apphub discovered-services list \
      --location="${loc}" \
      --project="${PROJECT_ID}" \
      --format='value(name.basename())' 2>/dev/null || true)"

    if [[ -z "${names}" ]]; then
      continue
    fi

    while read -r discovered_name; do
      [[ -z "${discovered_name}" ]] && continue

      local service_id
      service_id="$(slugify "svc-${discovered_name}")"
      service_id="${service_id:0:62}"

      if service_exists "${service_id}"; then
        warn "Service already registered: ${service_id}"
        continue
      fi

      info "Registering discovered service: ${discovered_name}"
      if gcloud apphub applications services create "${service_id}" \
          --application="${APP_ID}" \
          --location=global \
          --project="${PROJECT_ID}" \
          --discovered-service="projects/${PROJECT_ID}/locations/${loc}/discoveredServices/${discovered_name}" \
          --display-name="${discovered_name}" \
          --description="Auto-registered discovered service ${discovered_name}" \
          --criticality-type=MISSION_CRITICAL \
          --environment-type=PRODUCTION >/dev/null 2>&1; then
        ok "Registered service: ${service_id}"
        any_registered="true"
      else
        warn "Could not register service: ${discovered_name}"
      fi
    done <<< "${names}"
  done
}

need_cmd gcloud
need_cmd sed
need_cmd tr
need_cmd awk
need_cmd sort
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
  --location=global >/dev/null
ok "Boundary verified"

info "Granting App Hub roles to current account (best effort)..."
safe_add_iam "${MEMBER}" "roles/apphub.admin"
safe_add_iam "${MEMBER}" "roles/cloudhub.operator"

info "Checking whether application already exists..."
if app_exists; then
  ok "Application already exists: ${APP_ID}"
else
  info "Creating global application..."
  gcloud apphub applications create "${APP_ID}" \
    --location=global \
    --scope-type=GLOBAL \
    --display-name="${APP_DISPLAY_NAME}" \
    --description="${APP_DESCRIPTION}" \
    --criticality-type=MISSION_CRITICAL \
    --environment-type=PRODUCTION \
    --project="${PROJECT_ID}"
  ok "Application created: ${APP_ID}"
fi

info "Trying to auto-register discovered workloads..."
register_discovered_workloads || true

info "Trying to auto-register discovered services..."
register_discovered_services || true

echo
ok "App Hub single-project setup is complete."
echo
echo "Summary:"
echo "  Project      : ${PROJECT_ID}"
echo "  Account      : ${ACCOUNT}"
echo "  Boundary     : projects/${PROJECT_ID}/locations/global/boundary"
echo "  Application  : ${APP_ID}"
echo

info "Applications:"
gcloud apphub applications list \
  --location=global \
  --project="${PROJECT_ID}" || true

echo
info "Registered services:"
gcloud apphub applications services list \
  --application="${APP_ID}" \
  --location=global \
  --project="${PROJECT_ID}" || true

echo
info "Registered workloads:"
gcloud apphub applications workloads list \
  --application="${APP_ID}" \
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
