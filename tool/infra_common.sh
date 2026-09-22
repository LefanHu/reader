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
  require_command npm
  require_command curl

  terraform_version=$(terraform version -json | jq -r '.terraform_version')
  terraform_major=$(printf '%s' "$terraform_version" | cut -d. -f1)
  terraform_minor=$(printf '%s' "$terraform_version" | cut -d. -f2)
  if [ "$terraform_major" -lt 1 ] || { [ "$terraform_major" -eq 1 ] && [ "$terraform_minor" -lt 14 ]; }; then
    die "Terraform >= 1.14.0 is required (found $terraform_version)"
  fi
}

load_environment() {
  [ "$#" -eq 1 ] || die "usage: $0 <environment>"
  ENVIRONMENT=$1
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

terraform_init() {
  stack=$1
  prefix=$2
  terraform -chdir="$INFRA_DIR/$stack" init -upgrade \
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

assert_safe_foundation_plan() {
  plan_file=$1
  plan_json=$(mktemp "${TMPDIR:-/tmp}/reader-foundation-plan.XXXXXX")
  terraform -chdir="$INFRA_DIR/foundation" show -json "$plan_file" >"$plan_json"

  destructive=$(jq -r '
    [.resource_changes[]?
      | select(.address == "module.foundation.google_project.environment"
          or .address == "module.foundation.google_firestore_database.default"
          or .type == "google_storage_bucket")
      | select((.change.actions | index("delete")) != null)
      | .address] | unique | join(", ")' "$plan_json")
  rm -f "$plan_json"
  [ -z "$destructive" ] || die "foundation plan would delete or replace protected infrastructure: $destructive"
}

ensure_openai_secret() {
  secret_id=$(terraform -chdir="$INFRA_DIR/foundation" output -raw openai_secret_id)
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

generate_dart_defines() {
  api_url=$1
  config_file=$(mktemp "${TMPDIR:-/tmp}/reader-firebase-config.XXXXXX")
  terraform -chdir="$INFRA_DIR/foundation" output -raw firebase_config | base64 --decode >"$config_file"

  api_key=$(/usr/libexec/PlistBuddy -c 'Print :API_KEY' "$config_file")
  app_id=$(/usr/libexec/PlistBuddy -c 'Print :GOOGLE_APP_ID' "$config_file")
  sender_id=$(/usr/libexec/PlistBuddy -c 'Print :GCM_SENDER_ID' "$config_file")
  firebase_project=$(/usr/libexec/PlistBuddy -c 'Print :PROJECT_ID' "$config_file")
  storage_bucket=$(/usr/libexec/PlistBuddy -c 'Print :STORAGE_BUCKET' "$config_file")
  rm -f "$config_file"

  mkdir -p "$READER_ROOT/.dart-defines"
  jq -n \
    --arg apiKey "$api_key" \
    --arg appId "$app_id" \
    --arg senderId "$sender_id" \
    --arg projectId "$firebase_project" \
    --arg storageBucket "$storage_bucket" \
    --arg apiUrl "$api_url" \
    '{FIREBASE_API_KEY:$apiKey,FIREBASE_APP_ID:$appId,FIREBASE_MESSAGING_SENDER_ID:$senderId,FIREBASE_PROJECT_ID:$projectId,FIREBASE_STORAGE_BUCKET:$storageBucket,ILLUSTRATION_API_BASE_URL:$apiUrl}' \
    >"$READER_ROOT/.dart-defines/$ENVIRONMENT.json"
  chmod 600 "$READER_ROOT/.dart-defines/$ENVIRONMENT.json"
}
