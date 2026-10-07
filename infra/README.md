# Reader infrastructure

Terraform is the source of truth for the Firebase and Google Cloud resources.
Four independently stateful stacks share one environment project and database:

- `bootstrap` protects the dedicated state project and versioned GCS bucket.
- `foundation` is core: project/billing, shared APIs, Firebase Apple app, App Check,
  Apple authentication, Firestore database/rules, budget, and notification channel.
  Its directory, state prefix, and existing resource addresses remain unchanged.
- `illustrations` owns feature APIs, indexes/TTL, private asset bucket and Storage
  rules, queue, service identities/IAM, container registry, and secrets.
- `runtime` owns the existing public API, private worker, service IAM, and alerts.
  Both services use one immutable image; Firebase Auth handles accounts directly.

Core owns shared APIs; illustrations owns feature-specific APIs. Neither stack
creates another project, database, auth service, or notification channel. This
reorganization preserves Apple-only sign-in; Google sign-in is a separate change.

All stacks require Terraform 1.14 or newer, Python 3, gcloud, and jq. Provider
versions and root lock files are pinned. Use the repository commands for writes:

```sh
# Authentication/shared data only: no OpenAI key, npm, image, or Cloud Run required.
tool/deploy_backend dev --scope core

# Existing core required: feature infrastructure, one image build, and runtime.
tool/deploy_backend dev --scope illustrations

# Both paths in dependency order; this remains the default for compatibility.
tool/deploy_backend dev
```

The core path bootstraps state when necessary and requires Apple credentials.
Supply `TF_VAR_apple_client_id` and `TF_VAR_apple_client_secret`, or enter them at
its prompts. The illustration path never requests Apple credentials; it requests
an OpenAI key only when the secret has no enabled version. It additionally needs
npm and curl, runs backend build/tests/production audit, builds through Cloud
Build, resolves an immutable digest, deploys runtime, and smoke-tests endpoints.

Every deployment generates `.dart-defines/dev.json` atomically with private file
permissions. A fresh core-only installation omits the illustration API URL. Later
core deployments read an existing runtime URL when available, or preserve the
previous local URL. Deploying core never deletes an existing illustration stack.
`--scope` chooses deployment work; `illustrations_enabled` independently controls
feature rollout and remains false until explicitly changed.

Use `tool/plan_infra dev --scope core|illustrations|all` for drift review (omit the
option for all). Plans never apply cloud changes. Core plans need no image; when
runtime has not been deployed, full/illustration plans review infrastructure and
skip runtime. An existing runtime reuses its digest unless `IMAGE` overrides it.
A first all-scope plan needs core to exist before dependent stacks can be planned.

All stacks use `reader-iac-35ca1-tfstate`, with prefixes `reader/bootstrap`,
`reader/dev/foundation`, `reader/dev/illustrations`, and `reader/dev/runtime`.

## Migrating an existing foundation state

Before using the split deployment with existing infrastructure:

```sh
tool/migrate_backend_state dev             # preview ownership moves only
tool/migrate_backend_state dev --apply     # explicitly transfer state ownership
tool/plan_infra dev --scope core
tool/deploy_backend dev --scope core       # refresh core outputs
tool/plan_infra dev --scope illustrations
```

Stop all concurrent Terraform/deployment operations during migration. Terraform
cannot atomically lock two state backends; the migration checks for concurrent
changes and retains normal lineage/serial safeguards, but a maintenance window is
required. Preview and migration do not provision, modify, or delete cloud resources.
Initialization may update local Terraform backend metadata.

The checked-in ownership manifest moves only managed illustration instances,
including their generated fingerprint password and secret version. Complete
records are preserved; IDs alone are insufficient for conflict checking. Missing
resources from a partial deployment are skipped. Destination conflicts abort.
Local edits run in a backend-free temporary directory, so Terraform's legacy
local-state flags cannot accidentally edit a remote backend.

The destination state is pushed and verified before removing source ownership.
If the second push fails, do not deploy either stack: rerun the migration. Matching
duplicate ownership is safely removed on retry; differing records require manual
investigation. The command retains durable prior snapshots through the versioned
remote bucket and removes private local working files/backups on exit. Never copy
or log state contents: they contain secrets.

Deployment and planning refuse legacy illustration ownership. Review the first
plans after migration: they must not delete or replace migrated resources. The
bootstrap/core/illustration deployment guards reject deletion or replacement of
protected projects, databases, buckets, and secrets. Cloud Run remains protected
by its existing deletion protection. No `-target` workflow or forced state pushes
are used.

## Existing development project

`reader-35ca1` predates Terraform. The conditional imports in
`foundation/imports.tf` adopt the project, Firebase activation, default
Firestore database, and current Firestore rules release. `illustrations/imports.tf`
adopts the three pre-existing illustration indexes. The first saved plans must
not replace the project/database or delete a bucket; `tool/deploy_backend` rejects such plans before applying them. Once both
infrastructure applies succeed, set `enable_existing_imports = false` in `dev.tfvars`.
Imported resources remain in state.

The existing `reader-35ca1.firebasestorage.app` default bucket is intentionally
unmanaged and unused legacy infrastructure. Terraform neither imports nor
deletes it. Generated assets use `reader-35ca1-illustrations` exclusively.

Do not run `firebase deploy` for Firestore indexes or Security Rules. Terraform
reads `backend/firestore.indexes.json`, `backend/firestore.rules`, and
`backend/storage.rules` and owns their active cloud configuration.

## Secrets and deletion safety

The Sign in with Apple secret is necessarily retained in encrypted remote state
and must be rotated by supplying a new `TF_VAR_apple_client_secret`. Restrict
access to the state project and bucket accordingly. The OpenAI key is never a
Terraform input: the deploy command writes it straight to Secret Manager and
Cloud Run references the secret rather than receiving plaintext environment
data. The fingerprint secret is generated once and retained in protected state.

The environment project, Firestore database, illustration bucket, Secret
Manager containers, and state project/bucket are protected against ordinary
Terraform destruction. Removing them requires an explicit configuration/state
change, not merely `terraform destroy`.

Google Cloud budget notifications are informational and do not cap spending.
The development threshold is $25 USD per month at 50%, 80%, and 100%. OpenAI
usage is outside Google Cloud Billing, so configure a separate OpenAI project
budget and usage notification in the OpenAI platform.

## Adding an environment

Copy `environments/dev.tfvars`, choose a globally unique project ID and bucket,
and update the environment-specific values. Set
`enable_existing_imports = false`; project creation, billing attachment, and
Firebase activation are automatic. Then provide Apple credentials and run the
same deploy command. The OpenAI key is requested only when the new project's
secret has no enabled version.

Keep `illustrations_enabled = false` until an authenticated mobile request has
completed successfully. Enabling it is an explicit tfvars change followed by a
normal deployment.

## Manual validation

The deployment workflow runs backend build, tests, and production audit. The
infrastructure itself can be checked without cloud changes:

```sh
terraform fmt -check -recursive infra
terraform -chdir=infra/foundation init -backend=false
terraform -chdir=infra/foundation validate
terraform -chdir=infra/illustrations init -backend=false
terraform -chdir=infra/illustrations validate
terraform -chdir=infra/runtime init -backend=false
terraform -chdir=infra/runtime validate
terraform -chdir=infra/modules/foundation init -backend=false
terraform -chdir=infra/modules/foundation test
terraform -chdir=infra/modules/illustrations init -backend=false
terraform -chdir=infra/modules/illustrations test
terraform -chdir=infra/modules/runtime init -backend=false
terraform -chdir=infra/modules/runtime test
terraform -chdir=infra/runtime test
shellcheck tool/deploy_backend tool/plan_infra tool/infra_common.sh tool/migrate_backend_state
python3 -m unittest discover -s tool/tests -v
```

