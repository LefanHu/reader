# Reader infrastructure

Terraform is the source of truth for the Firebase and Google Cloud resources
used by the illustration backend. It has three independently stateful stacks:

- `bootstrap` protects the dedicated state project and versioned GCS bucket.
- `foundation` owns the environment project, Firebase, data, identity, queue,
  registry, secrets, budget, and notification resources.
- `runtime` deploys one immutable image digest as a public API and private
  worker and owns service IAM and operational alerts.

All stacks require Terraform 1.14 or newer. Provider versions are pinned so a
provider release cannot silently change a deployment. The only supported write
workflow is:

```sh
tool/deploy_backend dev
```

The command bootstraps state when necessary, plans and applies the foundation,
adds an OpenAI secret version without putting it in Terraform state, validates
the backend, builds through Cloud Build, resolves the immutable image digest,
applies the runtime, creates `.dart-defines/dev.json`, and runs basic endpoint
smoke tests. It prompts without echo for missing secret values. Apple values can
instead be supplied for the process:

```sh
TF_VAR_apple_client_id=... TF_VAR_apple_client_secret=... tool/deploy_backend dev
```

Use `tool/plan_infra dev` for drift review. That command never applies cloud
changes. Both commands use the dedicated `reader-iac-35ca1-tfstate` bucket and
the `reader/dev/foundation` and `reader/dev/runtime` state prefixes.

## Existing development project

`reader-35ca1` predates Terraform. The conditional imports in
`foundation/imports.tf` adopt the project, Firebase activation, default
Firestore database, current Firestore rules release, and its three existing
indexes. The first saved plan must not replace the project/database or delete a
bucket; `tool/deploy_backend` rejects such a plan before applying it. Once the
first apply succeeds, set `enable_existing_imports = false` in `dev.tfvars`.
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
terraform -chdir=infra/runtime init -backend=false
terraform -chdir=infra/runtime validate
terraform -chdir=infra/modules/foundation test
terraform -chdir=infra/modules/runtime test
shellcheck tool/deploy_backend tool/plan_infra tool/infra_common.sh
```

