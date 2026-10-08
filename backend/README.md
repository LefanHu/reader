# Reader illustration backend

One container image contains the authenticated mobile API and Cloud Tasks worker
routes. Deploy it as two Cloud Run services: a public API service and a private
worker service. Set `WORKER_URL` to the worker and require Cloud Run IAM
authentication for that service.

## Runtime ownership

- `src/index.ts` composes deployments, public illustration routes, verified identity,
  task authorization, feature rollout gates, and shared error translation.
- `src/illustration-worker.ts` owns illustration execution: job/regeneration leases,
  world-history reads, credit settlement, moderation, and asset publication/cleanup.
  Its injected resources and provider boundary allow local execution without cloud calls.
- `src/illustration-http.ts` shares bounded request validation and expected HTTP
  errors between public routes and the worker, preserving status translation.
- `src/openai.ts`, `src/narration.ts`, and `src/account.ts` retain provider,
  narration lifecycle, and account responsibilities respectively.

Worker lifecycle regressions run in `src/illustration-worker.test.ts` through local
HTTP with isolated in-memory storage and deterministic image generation. Run
`npm run build` and `npm test`; these commands never apply cloud changes.

## Configuration

Required configuration:

- `OPENAI_API_KEY`, `FINGERPRINT_SECRET`
- `GOOGLE_CLOUD_PROJECT`, `ILLUSTRATION_BUCKET`
- `TASK_LOCATION`, `TASK_QUEUE`, `TASK_SERVICE_ACCOUNT`, `WORKER_URL`
- `ILLUSTRATIONS_ENABLED=true` to open the remote feature flag (it defaults off)
- `SERVICE_ROLE=api` on the public mobile service and `SERVICE_ROLE=worker` on
  the private, Cloud Tasks/IAM-only worker service
- optional `OPENAI_SCENE_MODEL`, `OPENAI_IMAGE_MODEL`,
  `OPENAI_IMAGE_ORCHESTRATOR_MODEL`, `PILOT_CREDITS`, and `WORKER_TOKEN` for
  local worker calls

Create Firestore TTL on `illustrationJobInputs.expiresAt`, deny all direct client
access to Firestore and Storage, and grant the API/worker service accounts only
the collections, bucket prefix, Secret Manager secret, and task permissions they
need. The mobile build supplies Firebase and API values with `--dart-define`.

Configure the bucket lifecycle to delete `users/**/scenes/**` after 30 days.
Scene documents also carry `assetExpiresAt`; `/unlock` queues an uncharged
refresh when an asset is within 24 hours of expiry. Cloud Storage must remain
private—clients receive only ten-minute signed URLs after their local locator
gate opens. Use Firestore CMEK if the deployment requires customer-managed
encryption for temporary chapter jobs; Firestore encryption at rest is always
required.

The API never accepts an EPUB. It accepts one normalized chapter at a time and
analyzes it once into append-only, paragraph-anchored entity revisions plus
scene candidates. The prose is deleted immediately after that analysis. Image
generation receives only the selected scene range and the compact world state
that was established before the scene, never the whole chapter or future
revisions. OpenAI Responses API storage is disabled.

The service runs text moderation before image generation and image moderation
before committing an asset. Credits are transactionally reserved and charged
only after a usable scene record and both private objects commit; retries reuse
the same reservation. `DELETE /v1/account` purges global jobs, temporary prose,
scene metadata, temporal world revisions and references, reservations, user
records, and the user's storage prefix.
Narration purge also removes UID-owned jobs, orphan inputs, and all monthly usage
records. It releases unsubmitted reservations before deleting counters and awaits
bulk writes before responding. Minimal account tombstones remain to fence delayed
workers; shared daily usage retains submitted charges and other users' allowance.
Firebase identity deletion belongs to the native client after HTTP success, not
this route. Privacy deletion remains available while generation rollout is off.

Terraform owns the deployed indexes, TTL policy, Security Rules, service
identities, and Cloud Run services. Do not run `firebase deploy`; use the
repository-root deployment entry point so these resources retain one source of
truth:

```sh
tool/deploy_backend dev
```

Accounts/shared infrastructure can be deployed separately with
`tool/deploy_backend dev --scope core`. The illustration path uses
`--scope illustrations` after core exists; omitting scope preserves the full
workflow. Existing foundation state must migrate before either path is applied.
This split does not add Google sign-in or change backend routes.

See [`../infra/README.md`](../infra/README.md) for state bootstrapping,
migration safeguards, secrets, drift review, and new-environment setup.

## AI narration (disabled by default)

Narration uses the same API and private worker deployments, Firebase Auth, App Check,
Firestore database, Secret Manager key and private asset bucket as the existing
feature stack. It does not initialize or spend illustration credits.

Set `narration_enabled`, `narration_monthly_characters` and
`narration_daily_characters` in the environment Terraform configuration. Runtime
injects `NARRATION_ENABLED` (default false), `NARRATION_MONTHLY_CHARACTERS`
(default 500000), `NARRATION_DAILY_CHARACTERS` (default 200000) and
`NARRATION_TASK_QUEUE` (`reader-narration`). Foundation owns both Apple Firebase
registrations; the feature stack owns the dedicated queue, input TTL and job
indexes. Existing deployment scopes remain `core|illustrations|all`.

Authenticated routes:

- `GET /v1/narration/config`: rollout, model/voices and remaining UTC-month allowance.
- `POST /v1/narration/books`: explicit consent version and account-scoped fingerprint.
- `POST /v1/narration/books/:bookId/jobs`: exact prose, SHA-256 digest, chunk ID,
  document/chunk versions and Marin/Cedar voice. Requests are idempotent.
- `GET /v1/narration/jobs/:jobId`: status and a ten-minute private download URL
  only for live, unexpired audio owned by the caller.
- `DELETE /v1/narration/books/:bookId`: tombstone and purge; usable with rollout off.
- `DELETE /v1/account`: tombstones and purges narration before the native client deletes identity.

The private `/internal/narration/:jobId` worker transaction claims each job with a
four-minute lease and unique claim token. Its OpenAI Realtime response uses
`gpt-realtime-2.1-mini`, fixed narration instructions, no tools, isolated input,
24 kHz mono PCM and a three-minute timeout. Refusal, incomplete output, invalid
PCM and transcript mismatch produce no published asset. Transcript comparison
removes punctuation and collapses whitespace while retaining word boundaries,
case and order. This safeguard cannot establish the accuracy of the audio itself.
See [Realtime conversations](https://developers.openai.com/api/docs/guides/realtime-conversations)
and [the TTS migration notice](https://developers.openai.com/api/docs/deprecations).

Quota transactions reserve UTF-16 input characters against both the user's UTC
month and the environment's UTC day. Submission is durably recorded before the
provider request. Pre-submission failures release the reservation; submitted
failures remain charged. A user retry gets a new reservation and task identity,
with at most two provider attempts. Crash recovery cannot publish for a stale
claim, deleted book or deleted account. Cached local replay is free. Audio expires
after 30 days through bucket lifecycle plus checked delivery expiration. Raw
prose is removed at terminal completion; abandoned inputs have a 24-hour Firestore
TTL policy. Firestore cleanup is asynchronous. Allowance reads reclaim expired
unsubmitted reservations in batches of up to 100.

Do not enable rollout until signed iOS and macOS authentication/App Check,
background playback, media controls and listening quality are verified. No live
provider calls or cloud applies are part of the automated tests.

## Account usage

`GET /v1/account/usage` requires the same verified Firebase ID token and App Check
token as generation. It remains readable with both feature rollout flags disabled.
The authenticated token determines ownership; query parameters cannot select an
account. Responses are marked `Cache-Control: no-store` and contain:

- `asOf`: server UTC ISO timestamp.
- `narrationEnabled`, `illustrationsEnabled`: independent rollout flags.
- `narrationMonthlyLimit`, `narrationRemaining`: UTF-16 monthly allowance and
  remaining units, including outstanding reservations in the charged usage.
- `narrationResetAt`: first instant of the next UTC month.
- `illustrationCreditsRemaining`, `illustrationCreditsReserved`: total unspent
  credits and those held by jobs. Both are null when credits are not activated.

This endpoint performs only reads. It never initializes illustration credits,
registers books, grants consent, enqueues generation, or reclaims reservations.
Existing narration configuration/generation cleanup owns reservation recovery;
the Settings snapshot can conservatively include expired reservations until that
cleanup runs. Missing monthly usage means the full configured monthly allowance.
