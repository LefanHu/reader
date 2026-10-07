#!/bin/sh

# Shared deployment helpers intentionally avoid evaluating tfvars as shell so
# configuration cannot execute arbitrary commands on a developer workstation.
READER_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
INFRA_DIR="$READER_ROOT/infra"
STATE_VARS="$INFRA_DIR/environments/state.tfvars"

die() {
  printf '%s\n' "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' is not installed"
}

tfvar_string() {
  key=$1
  file=$2
  value=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -n 1)
  [ -n "$value" ] || die "missing string variable '$key' in $file"
  printf '%s\n' "$value"
}

check_tools() {
  require_command terraform
  require_command gcloud
  require_command jq
  require_command python3

  terraform_version=$(terraform version -json | jq -r '.terraform_version')
  terraform_major=$(printf '%s' "$terraform_version" | cut -d. -f1)
  terraform_minor=$(printf '%s' "$terraform_version" | cut -d. -f2)
  if [ "$terraform_major" -lt 1 ] || { [ "$terraform_major" -eq 1 ] && [ "$terraform_minor" -lt 14 ]; }; then
    die "Terraform >= 1.14.0 is required (found $terraform_version)"
  fi
}

load_environment() {
  [ "$#" -ge 1 ] || die "usage: $0 <environment> [--scope core|illustrations|all]"
  ENVIRONMENT=$1
  shift
  SCOPE=all
  if [ "$#" -gt 0 ]; then
    [ "$#" -eq 2 ] && [ "$1" = "--scope" ] || die "usage: $0 <environment> [--scope core|illustrations|all]"
    SCOPE=$2
  fi
  case "$SCOPE" in core|illustrations|all) ;; *) die "unknown scope: $SCOPE" ;; esac
  case "$ENVIRONMENT" in ''|*[!a-zA-Z0-9_-]*) die "invalid environment name" ;; esac
  ENV_VARS="$INFRA_DIR/environments/$ENVIRONMENT.tfvars"
  [ -f "$ENV_VARS" ] || die "environment file not found: $ENV_VARS"

  PROJECT_ID=$(tfvar_string project_id "$ENV_VARS")
  REGION=$(tfvar_string runtime_region "$ENV_VARS")
  STATE_BUCKET=$(tfvar_string state_bucket "$ENV_VARS")
  STATE_PROJECT=$(tfvar_string state_project_id "$STATE_VARS")
  BILLING_ACCOUNT=$(tfvar_string billing_account "$STATE_VARS")
  STATE_LOCATION=$(tfvar_string state_location "$STATE_VARS")
  export ENVIRONMENT ENV_VARS PROJECT_ID REGION STATE_BUCKET STATE_PROJECT BILLING_ACCOUNT STATE_LOCATION
}

# Routine plans/deployments use checked-in provider locks; upgrades are explicit.
terraform_init() {
  stack=$1
  prefix=$2
  terraform -chdir="$INFRA_DIR/$stack" init \
    -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="prefix=$prefix"
}

require_apple_credentials() {
  if [ -z "${TF_VAR_apple_client_id:-}" ]; then
    printf 'Sign in with Apple client ID: ' >&2
    IFS= read -r TF_VAR_apple_client_id
    export TF_VAR_apple_client_id
  fi
  if [ -z "${TF_VAR_apple_client_secret:-}" ]; then
    printf 'Sign in with Apple client secret: ' >&2
    stty -echo
    IFS= read -r TF_VAR_apple_client_secret
    stty echo
    printf '\n' >&2
    export TF_VAR_apple_client_secret
  fi
  [ -n "$TF_VAR_apple_client_id" ] || die "Apple client ID cannot be empty"
  [ -n "$TF_VAR_apple_client_secret" ] || die "Apple client secret cannot be empty"
}

# Reject destructive changes to durable data in every infrastructure stack.
assert_safe_plan() {
  stack=$1
  plan_file=$2
  plan_json="$WORK_DIR/plan.json"
  terraform -chdir="$INFRA_DIR/$stack" show -json "$plan_file" >"$plan_json"

  destructive=$(jq -r '
    [.resource_changes[]?
      | select(.type == "google_project" or .type == "google_firestore_database"
          or .type == "google_storage_bucket" or .type == "google_secret_manager_secret"
          or .type == "google_secret_manager_secret_version")
      | select((.change.actions | index("delete")) != null)
      | .address] | unique | join(", ")' "$plan_json")
  rm -f "$plan_json"
  [ -z "$destructive" ] || die "infrastructure plan would delete or replace protected resources: $destructive"
}

ensure_openai_secret() {
  secret_id=$(terraform -chdir="$INFRA_DIR/illustrations" output -raw openai_secret_id)
  enabled_version=$(gcloud secrets versions list "$secret_id" \
    --project="$PROJECT_ID" --filter='state=ENABLED' --limit=1 --format='value(name)')
  [ -z "$enabled_version" ] || return 0

  printf 'OpenAI API key (stored directly in Secret Manager): ' >&2
  stty -echo
  IFS= read -r openai_key
  stty echo
  printf '\n' >&2
  [ -n "$openai_key" ] || die "OpenAI API key cannot be empty"
  printf '%s' "$openai_key" | gcloud secrets versions add "$secret_id" \
    --project="$PROJECT_ID" --data-file=- >/dev/null
  unset openai_key
}

# Core configuration generation works before an illustration endpoint exists.
generate_dart_defines() {
  api_url=${1:-}
  config_file="$WORK_DIR/firebase-config"
  terraform -chdir="$INFRA_DIR/foundation" output -raw firebase_config | base64 --decode >"$config_file"

  macos_config_file="$WORK_DIR/firebase-macos-config"
  terraform -chdir="$INFRA_DIR/foundation" output -raw firebase_macos_config | base64 --decode >"$macos_config_file"
  python3 "$READER_ROOT/tool/write_firebase_defines.py" "$config_file" \
    "$READER_ROOT/.dart-defines/$ENVIRONMENT.json" "$api_url" "$macos_config_file"
  rm -f "$config_file" "$macos_config_file"
}

# All callers share cleanup for saved plans/config; none are left in the checkout.
prepare_workspace() {
  umask 077
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/reader-infra.XXXXXX")
  export WORK_DIR
  trap 'rm -rf "$WORK_DIR"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# Never apply the split configuration while feature resources still belong to core.
assert_migrated() {
  python3 "$READER_ROOT/tool/migrate_illustration_state.py" --check-state "$INFRA_DIR" || \
    die "run tool/migrate_backend_state $ENVIRONMENT before deploying or planning"
}

require_core() {
  terraform -chdir="$INFRA_DIR/foundation" output -raw project_id >/dev/null || \
    die "core is not initialized; run tool/deploy_backend $ENVIRONMENT --scope core"
}

plan_apply_infrastructure() {
  stack=$1
  plan="$WORK_DIR/$stack.tfplan"
  terraform -chdir="$INFRA_DIR/$stack" plan -var-file="$ENV_VARS" -out="$plan"
  assert_safe_plan "$stack" "$plan"
  terraform -chdir="$INFRA_DIR/$stack" apply "$plan"
}
