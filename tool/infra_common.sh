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

# Terraform needs user ADC; gcloud's own login alone is not enough.
require_application_default_credentials() {
  gcloud auth application-default print-access-token >/dev/null 2>&1 || \
    die "Terraform needs Application Default Credentials; run gcloud auth application-default login"
}

# Runtime state exists only after the first feature deployment built an image.
runtime_deployed() {
  gcloud storage ls "gs://$STATE_BUCKET/reader/$ENVIRONMENT/runtime/default.tfstate" >/dev/null 2>&1
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

# Reads one line into the variable named $1 without echoing it. Echo is restored
# by an EXIT trap that exists only for the duration of the read, so Ctrl-C,
# TERM or a failed read never leaves the terminal silent; the workspace traps
# are reinstated afterwards.
read_secret() {
  trap 'stty echo; cleanup_workspace' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  stty -echo
  IFS= read -r "$1"
  stty echo
  install_workspace_traps
  printf '\n' >&2
}

require_google_credentials() {
  if [ -z "${TF_VAR_google_client_id:-}" ] || [ -z "${TF_VAR_google_client_secret:-}" ]; then
    [ -t 0 ] || die "configure a Google web OAuth client and supply TF_VAR_google_client_id and TF_VAR_google_client_secret privately"
  fi
  if [ -z "${TF_VAR_google_client_id:-}" ]; then
    printf 'Google web OAuth client ID: ' >&2
    IFS= read -r TF_VAR_google_client_id
    export TF_VAR_google_client_id
  fi
  if [ -z "${TF_VAR_google_client_secret:-}" ]; then
    printf 'Google web OAuth client secret: ' >&2
    read_secret TF_VAR_google_client_secret
    export TF_VAR_google_client_secret
  fi
  [ -n "$TF_VAR_google_client_id" ] || die "Google client ID cannot be empty"
  [ -n "$TF_VAR_google_client_secret" ] || die "Google client secret cannot be empty"
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

  if [ -n "${OPENAI_API_KEY:-}" ]; then
    openai_key=$OPENAI_API_KEY
  else
    printf 'OpenAI API key (stored directly in Secret Manager): ' >&2
    read_secret openai_key
  fi
  [ -n "$openai_key" ] || die "OpenAI API key cannot be empty"
  printf '%s' "$openai_key" | gcloud secrets versions add "$secret_id" \
    --project="$PROJECT_ID" --data-file=- >/dev/null
  unset openai_key
}

# Operator environment variable holding each direct image provider's key. Google
# uses the worker identity, so it has no key. Values never appear in argv, tfvars,
# state, plans or output.
image_provider_key_variable() {
  case "$1" in
    seedream) printf '%s\n' BYTEPLUS_API_KEY ;;
    qwen) printf '%s\n' QWEN_API_KEY ;;
    xai) printf '%s\n' XAI_API_KEY ;;
    flux) printf '%s\n' BFL_API_KEY ;;
    *) die "image provider '$1' has no key environment variable" ;;
  esac
}

# Container IDs have one owner: the illustrations stack's image_provider_secret_ids
# output (infra/modules/illustrations). Writes "provider container" lines to
# $IMAGE_PROVIDER_CONTAINERS; requires an initialized, applied illustrations stack.
read_image_provider_containers() {
  IMAGE_PROVIDER_CONTAINERS="$WORK_DIR/image-provider-containers"
  terraform -chdir="$INFRA_DIR/illustrations" output -json image_provider_secret_ids >"$IMAGE_PROVIDER_CONTAINERS.json"
  jq -r 'to_entries[] | "\(.key) \(.value)"' "$IMAGE_PROVIDER_CONTAINERS.json" >"$IMAGE_PROVIDER_CONTAINERS"
  [ -s "$IMAGE_PROVIDER_CONTAINERS" ] || die "the illustrations stack reports no image provider containers"
}

# Read-only. Writes $WORK_DIR/image-providers.tfvars.json naming only providers
# whose container has an ENABLED version (an existing version always wins). A
# container that does not exist yet is simply absent; permission, API and other
# failures stop the run rather than silently dropping a configured provider.
discover_image_provider_secrets() {
  read_image_provider_containers
  providers_file="$WORK_DIR/image-providers.tfvars.json"
  printf '{"image_provider_secret_ids":{}}\n' >"$providers_file"
  # gcloud reads from /dev/null so it can never consume the container list.
  while read -r provider container; do
    if ! enabled=$(gcloud secrets versions list "$container" \
      --project="$PROJECT_ID" --filter='state=ENABLED' --limit=1 --format='value(name)' \
      </dev/null 2>"$WORK_DIR/secret-error"); then
      if grep -Eqi 'NOT_FOUND|was not found|not found' "$WORK_DIR/secret-error"; then
        continue
      fi
      cat "$WORK_DIR/secret-error" >&2
      die "cannot inspect Secret Manager container $container"
    fi
    [ -n "$enabled" ] || continue
    jq -c --arg provider "$provider" --arg container "$container" \
      '.image_provider_secret_ids[$provider] = $container' "$providers_file" >"$providers_file.next"
    mv "$providers_file.next" "$providers_file"
  done <"$IMAGE_PROVIDER_CONTAINERS"
  export IMAGE_PROVIDER_VARS="$providers_file"
}

# Deploy only, after the illustrations stack created the containers. Each key is
# optional: an absent variable is omitted without prompting or failing, and an
# existing enabled version is never replaced.
provision_image_provider_secrets() {
  read_image_provider_containers
  while read -r provider container; do
    variable=$(image_provider_key_variable "$provider")
    value=$(printenv "$variable" || true)
    [ -n "$value" ] || continue
    enabled=$(gcloud secrets versions list "$container" \
      --project="$PROJECT_ID" --filter='state=ENABLED' --limit=1 --format='value(name)' </dev/null)
    if [ -z "$enabled" ]; then
      printf '%s' "$value" | gcloud secrets versions add "$container" \
        --project="$PROJECT_ID" --data-file=- >/dev/null
    fi
    unset value
  done <"$IMAGE_PROVIDER_CONTAINERS"
}

# Core configuration generation works before an illustration endpoint exists.
generate_dart_defines() {
  api_url=${1:-}
  config_file="$WORK_DIR/firebase-config"
  terraform -chdir="$INFRA_DIR/foundation" output -raw firebase_config | base64 --decode >"$config_file"

  macos_config_file="$WORK_DIR/firebase-macos-config"
  terraform -chdir="$INFRA_DIR/foundation" output -raw firebase_macos_config | base64 --decode >"$macos_config_file"
  google_server_client_id=$(terraform -chdir="$INFRA_DIR/foundation" output -raw google_client_id)
  python3 "$READER_ROOT/tool/write_firebase_defines.py" "$config_file" \
    "$READER_ROOT/.dart-defines/$ENVIRONMENT.json" "$api_url" "$macos_config_file" "$google_server_client_id"
  rm -f "$config_file" "$macos_config_file"
}

# All callers share cleanup for saved plans/config; none are left in the checkout.
prepare_workspace() {
  umask 077
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/reader-infra.XXXXXX")
  export WORK_DIR
  install_workspace_traps
}

cleanup_workspace() {
  [ -z "${WORK_DIR:-}" ] || rm -rf "$WORK_DIR"
}

# Interrupts exit through the EXIT trap so cleanup runs exactly once.
install_workspace_traps() {
  trap cleanup_workspace EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# Sets STACK_VARS to a private copy of the environment tfvars holding only the
# values <stack> declares (tool/stack_tfvars.py), so no stack declares unused
# variables and Terraform never warns about undeclared ones.
write_stack_vars() {
  STACK_VARS="$WORK_DIR/$1.tfvars"
  python3 "$READER_ROOT/tool/stack_tfvars.py" "$INFRA_DIR" "$1" "$ENV_VARS" "$STACK_VARS"
}

require_core() {
  terraform -chdir="$INFRA_DIR/foundation" output -raw project_id >/dev/null || \
    die "core is not initialized; run tool/deploy_backend $ENVIRONMENT --scope core"
}

# Plans one stack into $WORK_DIR/<stack>.tfplan and rejects unsafe changes.
plan_infrastructure() {
  stack=$1
  shift
  plan="$WORK_DIR/$stack.tfplan"
  write_stack_vars "$stack"
  terraform -chdir="$INFRA_DIR/$stack" plan -var-file="$STACK_VARS" "$@" -out="$plan"
  assert_safe_plan "$stack" "$plan"
}

plan_apply_infrastructure() {
  plan_infrastructure "$@"
  terraform -chdir="$INFRA_DIR/$stack" apply "$plan"
}
