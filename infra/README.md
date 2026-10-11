# Reader infrastructure

Terraform is the source of truth for the Firebase and Google Cloud resources.
Four independently stateful stacks share one environment project and database:

- `bootstrap`: dedicated state project and versioned GCS bucket.
- `foundation` (core): project/billing, shared APIs, Firebase Apple app, App Check,
  Google authentication, Firestore database/rules, budget, notification channel.
- `illustrations`: feature APIs (illustrations and narration modules), indexes/TTL,
  private asset bucket and Storage rules, queue, service identities/IAM, container
  registry, secrets.
- `runtime`: public API, private worker, service IAM, alerts. Both services use one
  immutable image, request-based billing (`cpu_idle = true`) and zero minimum
  instances; task workers finish generation inside their HTTP request.

Core owns shared APIs; illustrations owns feature APIs. Neither creates another
project, database, auth service, or notification channel. Google is the only
sign-in provider; native Firebase Apple registrations remain necessary on
iOS/macOS. Protected feature requests also require App Check; validate attestation
on the intended macOS distribution before rollout.

Core client-based APIs (Firebase Auth, App Check, budgets) charge quota to the
environment project through dedicated provider aliases, so user ADC needs
`serviceusage.services.use` there. Default providers stay separate so new projects
can bootstrap before their client APIs exist.

Requires Terraform 1.14+, Python 3, gcloud, and jq. Provider versions and lock files
are pinned. Use the repository commands for writes:

```sh
tool/deploy_backend dev --scope core           # auth/shared data only; no OpenAI key, npm, image, or Cloud Run
tool/deploy_backend dev --scope illustrations  # existing core required: feature infra, one image build, runtime
tool/deploy_backend dev                        # both, in dependency order (default)
```

Core bootstraps state when necessary and needs a Google web OAuth client. Supply
`TF_VAR_google_client_id` and `TF_VAR_google_client_secret` privately or at the
interactive prompts. Downloaded OAuth JSON belongs in Git-ignored `.credentials/`
with owner-only permissions; never put the secret in Flutter defines. The web client
needs redirect URI `https://reader-35ca1.firebaseapp.com/__/auth/handler`; configure
branding as Reader Development, External/Testing audience, basic identity scopes.
Native OAuth clients must match the existing iOS/macOS bundle IDs; adopt matching
clients instead of duplicating them.

Feature deployments (`illustrations` or `all`) also need npm and curl and run local
`npm ci`, backend build, tests, and production audit before any bootstrap, apply,
secret creation, or image build; a failed preflight leaves cloud unchanged.
Core-only deployments skip it. Ownership/migration guards always run before apply.

An OpenAI key is needed only when Secret Manager has no enabled version (an existing
enabled version is reused). Supply `OPENAI_API_KEY` privately in the process
environment, or use the hidden prompt. It goes to Secret Manager over stdin, never as
a command argument, Terraform input, Flutter define, tfvars entry, or shell history.
Deployment then builds via Cloud Build, resolves an immutable digest, deploys
runtime, and smoke-tests endpoints.

Cloud Build owns its default `${project_id}_cloudbuild` staging bucket; the feature
stack grants the dedicated builder read-only access to that bucket's `source/`
objects only. `backend/.gcloudignore` excludes dependencies and build output;
Docker installs from the lockfile.

Every deployment atomically writes `.dart-defines/dev.json` with private permissions.
A fresh core-only install omits the illustration API URL; later core deployments
reuse an existing runtime URL or the previous local one. Deploying core never deletes
an existing illustration stack. `--scope` chooses deployment work;
`illustrations_enabled` independently controls feature rollout. Narration is gated
server-side by `narration_enabled` and serves every client platform (macOS and, by
default, iOS); generation is refused while it is false.

`tool/plan_infra dev --scope core|illustrations|all` reviews drift (default all) and
never applies. Core plans need no image; without a deployed runtime, other plans skip
runtime. An existing runtime reuses its digest unless `IMAGE` overrides it. A first
all-scope plan needs core to exist first.

State bucket `reader-iac-35ca1-tfstate`, prefixes `reader/bootstrap`,
`reader/dev/foundation`, `reader/dev/illustrations`, `reader/dev/runtime`.

## Migrating an existing foundation state

Before using the split deployment with existing infrastructure:

```sh
tool/migrate_backend_state dev             # preview ownership moves only
tool/migrate_backend_state dev --apply     # explicitly transfer state ownership
tool/plan_infra dev --scope core
tool/deploy_backend dev --scope core       # refresh core outputs
tool/plan_infra dev --scope illustrations
```

Stop all concurrent Terraform/deployment operations first: Terraform cannot
atomically lock two backends, so a maintenance window is required. Preview and
migration do not change cloud resources (init may update local backend metadata).

The checked-in manifest moves only managed illustration instances, including the
generated fingerprint password and secret version, as complete records. Missing
resources are skipped; destination conflicts abort. Edits run in a backend-free
temporary directory so legacy local-state flags cannot touch a remote backend.

The destination state is pushed and verified before source ownership is removed. If
the second push fails, do not deploy either stack: rerun the migration. Matching
duplicate ownership is removed on retry; differing records need manual
investigation. Prior snapshots survive in the versioned bucket; local working files
are removed on exit. Never copy or log state contents: they contain secrets.

Deployment and planning refuse legacy illustration ownership. Review the first plans
after migration: they must not delete or replace migrated resources. Deploy guards
reject deletion or replacement of protected projects, databases, buckets, and
secrets; Cloud Run keeps its deletion protection. No `-target` workflow or forced
state pushes are used.

## Existing development project

`reader-35ca1` predates Terraform. Conditional imports in `foundation/imports.tf`
adopt the project, Firebase activation, default Firestore database, and current
rules release; `illustrations/imports.tf` adopts the three existing illustration
indexes. The first saved plans must not replace the project/database or delete a
bucket (`tool/deploy_backend` rejects such plans). After both applies succeed, set
`enable_existing_imports = false` in `dev.tfvars` (currently `true`); imported
resources stay in state.

The default `reader-35ca1.firebasestorage.app` bucket is unmanaged, unused legacy
infrastructure; Terraform neither imports nor deletes it. Generated assets use
`reader-35ca1-illustrations` exclusively.

Do not run `firebase deploy` for Firestore indexes or Security Rules. Terraform reads
`backend/firestore.indexes.json`, `backend/firestore.rules`, and
`backend/storage.rules` and owns their active configuration.

## Secrets and deletion safety

The Google OAuth client secret is retained in protected remote state; rotate it with
`TF_VAR_google_client_secret` and restrict access to the state project and bucket.
Neither it nor Apple retirement credentials enter generated app configuration.
Existing protected Apple provider state is retired in two applies: recover its
credentials privately from state, disable the provider and persist deletion policy
DELETE, then remove only that provider. Interrupted transitions are restartable;
Firebase users and data are preserved. `tool/plan_infra` shows the transition first
when needed. Historical versioned state can still contain retired Apple secrets and
must remain private. The OpenAI key is never a Terraform input; Cloud Run references
the secret rather than receiving plaintext. The fingerprint secret is generated once
and retained in protected state.

The environment project, Firestore database, illustration bucket, Secret Manager
containers, and state project/bucket are protected against ordinary destruction.
Removing them requires an explicit configuration/state change, not `terraform destroy`.

Budget notifications are informational and do not cap spending. Dev threshold:
$25 CAD per month at 50%, 80%, 100%. Set `budget_currency` to the billing account's
currency (`budget_amount_usd` is in that currency despite its name); Google rejects
mismatches. OpenAI usage is outside Google billing: configure a separate budget and
notification in the OpenAI platform.

## Adding an environment

Copy `environments/dev.tfvars`, choose a globally unique project ID and bucket, update
environment-specific values, and set `enable_existing_imports = false` (project
creation, billing, and Firebase activation are automatic). Configure Google OAuth and
provide its credentials, then run the same deploy command. The OpenAI key is
requested only when the new project's secret has no enabled version.

Keep `illustrations_enabled = false` until an authenticated mobile request has
succeeded; enabling is an explicit tfvars change plus a normal deployment.

Checked-in `dev` enables both `illustrations_enabled` and `narration_enabled` as an
explicit dev-only exception for authenticated backend smoke testing, not production
approval: signed-device attestation, playback/media behavior and listening-quality
checks remain required. Copying dev settings to another environment must reset both
to false.

## Manual validation

Deployment runs backend build, tests, and audit. Infrastructure can be checked
without cloud changes:

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
terraform -chdir=infra/modules/narration init -backend=false
terraform -chdir=infra/modules/narration test
terraform -chdir=infra/modules/runtime init -backend=false
terraform -chdir=infra/modules/runtime test
terraform -chdir=infra/runtime test
shellcheck tool/deploy_backend tool/plan_infra tool/infra_common.sh tool/migrate_backend_state
python3 -m unittest discover -s tool/tests -v
```
