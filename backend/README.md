# Reader illustration backend

One container image contains the authenticated mobile API and Cloud Tasks worker
routes. Deploy it as two Cloud Run services: a public API service and a private
worker service. Set `WORKER_URL` to the worker and require Cloud Run IAM
authentication for that service.

## Runtime ownership

- `src/index.ts` composes deployments, public book/profile/job routes, verified
  identity, task authorization, feature rollout gates, and shared error translation.
- `src/illustration-worker.ts` owns illustration claims, world-history planning,
  credit settlement, moderation, and guarded asset publication/cleanup. Its
  injected resources/provider boundary allows local execution without cloud calls.
- `src/illustration-scenes.ts` owns public scene delivery, durable regeneration
  task submission, and scene tombstone/asset cleanup.
- `src/illustration-http.ts` shares bounded request validation and expected HTTP
  errors between public routes and the worker, preserving status translation.
- `src/illustration-books.ts` owns transactional illustration book registration
  and tombstoned deletion. The first registration initializes pilot credits;
  retries/additional books retain spent/reserved balances. Deleted account/book
  fences reject registration with HTTP 410 instead of recreating deleted data.
- `src/openai.ts`, `src/narration.ts`, and `src/account.ts` retain provider,
  narration lifecycle, and account responsibilities respectively.

Illustration lifecycle regressions run in `src/illustration-worker.test.ts` through
local HTTP with isolated storage, deterministic provider barriers, real deletion
handlers and transient enqueue failures. Run `npm run build` and `npm test`;
these commands never apply cloud changes.

Illustration chapter inputs omit absent optional `title`/`language` fields rather
than writing `undefined`. Historical `WorldSnapshot.referenceObject` is likewise
absent until an earlier usable illustration provides a reference. This preserves
Firestore's default strict field validation without disabling it globally.

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

The OpenAI API organization behind the key must have funded API usage; a ChatGPT
subscription does not fund these direct API calls. Successful model discovery or
moderation does not prove generation allowance. Realtime
`credit_balance_exhausted` / `insufficient_quota` indicates provider billing, not
Google IAM permissions. Fund the existing API organization before replacing a
working key or changing cloud permissions.

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
before committing an asset. Credits are reserved transactionally, then charged
in the same transaction that publishes a usable scene and its world reference
after both private objects save. A live lease's unique token is checked against
the current job/scene, book tombstone and shared `narrationAccountTombstones`
record before history, status, accounting or publication writes. Stale claims
cannot refund newer reservations or overwrite/delete newer objects; each attempt
uses unique, immutable `.claim-<token>` object names and removes its own objects
when publication is cancelled, including saves that finish after deletion.
An expired, still-owned lease returns HTTP 409 for task retry rather than leaving
its reservation stranded; the next claim transfers that reservation exactly once.

Job documents temporarily retain a `plan` containing only bounded scene anchors,
paraphrased facts and generation specs/world snapshots; raw chapter text remains
solely in the 24-hour-TTL input until the guarded analysis commit deletes it.
The plan lets a replacement lease resume without another prose copy or repeated
history/counter increments. Terminal completion/failure removes the plan; book/
account deletion purges jobs and plans. Job `claimToken`, scene
`regenerationToken` and reservation `claimToken` fence lease ownership. Reservation
`sceneId` links deletion refunds to the owning scene.

Regeneration records persist `regenerationTarget`, `regenerationRefresh` and
`regenerationTaskId` before enqueue. A caller retry (including `/unlock` for
expired assets) resubmits that same identity after a transient enqueue failure;
it cannot switch paid/free billing intent or double-charge. Completed targets
are no-ops, and old task identities cannot claim a newer request. A new request
after provider failure gets a new task identity and can reserve a previously
refunded credit. Publication/failure removes this temporary submission metadata.

Scene deletion first fences the scene, refunds reserved work, removes its world
reference and objects, then leaves a minimal `deleted` tombstone. Book deletion
first replaces the book with a minimal durable `deleted` tombstone, releases its
reserved credits and purges owned jobs, inputs, scenes, reservations, revisions,
references and objects. These fences are not TTL records: deleted scene delivery
returns 404, and deleted book profile/jobs/registration return 410. Account
deletion removes those book/scene tombstones too, retaining only the shared
account fence. `DELETE /v1/account` purges temporary prose, jobs/plans, scene
metadata, temporal history, reservations, user records and the storage prefix.
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

## Approved dev live smoke

Use a disposable, authenticated dev account only, after deployment/provider-spend
approval. Never run account deletion against a restored user's real identity.
Every `/v1` request requires both `Authorization: Bearer <Firebase ID token>` and
`X-Firebase-AppCheck: <App Check token>`; do not log those headers, provider keys,
passage bodies or signed URLs. No public test bypass is available. Both rollout
flags must be enabled for the full recipe. Native macOS dev credentials have
passed Firebase ID-token and registered-debug App Check signature verification;
this does not substitute for the deferred native production listening checks.

Local checks (no provider calls or cloud changes), from the repository root:

```sh
npm --prefix backend ci
npm --prefix backend run build
npm --prefix backend test
docker build --platform linux/amd64 -t reader-backend-dev backend
```

Public API recipe (JSON request bodies shown below; empty-body calls need no JSON):

| Request | Body / assertion |
| --- | --- |
| `GET /health` | HTTP 200, `{"ok":true}`; no auth required. Cloud Run reserves some paths ending in `z`, so health uses a non-reserved path. |
| `GET /v1/account/usage` | HTTP 200, `Cache-Control: no-store`; independent flags true, UTC timestamps, nonnegative narration allowance; fresh illustration credits null. Retain baseline. |
| `GET /v1/fingerprint-key` | HTTP 200, nonempty base64 `key`. Derive account-scoped HMAC-SHA256 fingerprint for a disposable book identifier with the decoded key. |
| `POST /v1/books` | `{"fingerprint":"<64-hex fingerprint>","title":"The Lantern Courtyard","authors":["Dev smoke"],"language":"en","chapterCount":1}` → HTTP 200, 40-hex `id`, suggested style, two alternatives, `estimatedCredits:3`. |
| `PUT /v1/books/:bookId/profile` | `{"style":"<suggestedStyle>","density":1,"styleVersion":1,"analysisVersion":2}` → HTTP 204. |
| `POST /v1/books/:bookId/chapters/0/jobs` | Chapter payload below → HTTP 202, 40-hex job `id`. Repeat exactly: same ID, no duplicate charge. |
| `GET /v1/jobs/:jobId` | Poll up to the configured task deadline/retry window: `queued`/`analyzing` → `complete`; require at least one `ready_locked` scene (a scene-less `complete` is not a successful provider smoke). Assert anchor `href`, paragraph ID, selector and progression correspond to submitted paragraphs. |
| `POST /v1/scenes/:sceneId/unlock` | HTTP 200, image/thumbnail signed URLs, nonempty alt text, caption and `generationVersion:1`. Fetch URLs privately: valid nonempty WebP, landscape original, thumbnail width at most 640. Signed URLs use a ten-minute lifetime; bare object URLs must remain inaccessible. |
| `POST /v1/scenes/:sceneId/regenerate` | HTTP 202. Poll original job's scenes until `ready_locked`; unlock again → HTTP 200 and `generationVersion:2`, valid replacement WebP. |
| `GET /v1/account/usage` | Initial density-one success plus paid regeneration spend exactly two credits; reserved credits return to zero. Repeat illustration book registration and register another fingerprint: no credit reset or extra grant. |
| `GET /v1/narration/config` | HTTP 200, `enabled:true`, model `gpt-realtime-2.1-mini`, voices Marin/Cedar (`marin`, `cedar`), limits and remaining allowance. |
| `POST /v1/narration/books` | `{"fingerprint":"<64-hex account-scoped fingerprint>","consentVersion":1}` → HTTP 200, 64-hex `id`, matching authenticated `account`, remaining allowance; illustration balances unchanged. |
| `POST /v1/narration/books/:bookId/jobs` | Narration payload below → HTTP 200, 64-hex `id`. Repeat exactly: same ID, no duplicate reservation. |
| `GET /v1/narration/jobs/:jobId` | Poll `queued`/`generating` → `ready` with ten-minute signed `url`; privately fetch nonempty RIFF/WAVE, 24 kHz mono 16-bit PCM, then listen for exact passage and no introduction. Repeat using `voice:"cedar"` and a distinct chunk ID. |
| `GET /v1/account/usage` | For two successful voice jobs, remaining narration units decrease by twice the passage's UTF-16 length; illustration credits unchanged. GET configuration should agree. |
| `DELETE /v1/scenes/:sceneId` | HTTP 204; unlock afterward → 404; associated reference/private objects removed. |
| `DELETE /v1/books/:bookId` | HTTP 204; subsequent profile/job submission or same-fingerprint registration → 410; minimal book fence remains, while owned illustration jobs, inputs, scenes, revisions, references and assets are removed. Delete the second registration too. |
| `DELETE /v1/narration/books/:bookId` | HTTP 204; old ready job delivery → 410; new submission → 410; book audio removed, submitted allowance remains charged. |
| `DELETE /v1/account` | HTTP 204; inspect dev-owned Firestore/bucket records privately for full purge except account tombstone and shared submitted daily usage. Delete Firebase identity only after this succeeds. Old job delivery → 404; fresh illustration/narration registration with the still-valid old token → 410. |

Minimal chapter body deliberately omits optional metadata to exercise strict
Firestore serialization:

```json
{
  "href": "smoke.xhtml",
  "styleVersion": 1,
  "analysisVersion": 2,
  "density": 1,
  "paragraphs": [
    {
      "id": "p0",
      "text": "Mira, wearing a blue coat, stepped into a quiet stone courtyard at dusk. A brass lantern glowed beside the arched gate.",
      "cssSelector": "#p0",
      "ordinal": 0,
      "progression": 0
    },
    {
      "id": "p1",
      "text": "She set the lantern on a wooden table beneath the flowering tree. Golden light fell across the stone walls and the silver leaves.",
      "cssSelector": "#p1",
      "ordinal": 1,
      "progression": 1
    }
  ]
}
```

Narration body (`digest` = lowercase SHA-256 of exact UTF-8 `text`; `chunkId` =
lowercase SHA-256 of a stable disposable anchor; `.length` = UTF-16 units):

```json
{
  "text": "The lantern glowed beside the quiet courtyard gate.",
  "digest": "<64-hex SHA-256>",
  "chunkId": "<64-hex SHA-256>",
  "voice": "marin",
  "documentVersion": 1,
  "chunkVersion": 1
}
```

Additional checks with the same disposable records:

- Missing either authentication header → 401; a second dev account cannot read
  another account's jobs/scenes (404). Invalid narration digest/version → 400
  with no usage increase. Never send a fabricated App Check token.
- API-service `/internal/*` → 404, and private worker anonymous invocation must
  be rejected by Cloud Run IAM. Task delivery must use the configured OIDC identity.
- Narration `failed` is a failed live smoke, not successful asynchronous handling.
  An explicit retry may create a second provider attempt/reservation; after two
  provider attempts another retry returns 409. Submitted failures stay charged.
- To exercise uncharged illustration refresh without waiting 29 days, use a
  parent-approved dev-only fixture on a separate disposable scene, setting its
  `assetExpiresAt` within 24 hours. Unlock → 409 while refresh is queued; poll
  ready and unlock → a newer generation, valid private assets and no credit loss.
- A controlled dev rollout-off check must still allow usage, narration config
  and privacy deletion while generation endpoints return 503; do not mutate
  shared rollout settings without approval.
- Inspect terminal jobs for deleted temporary prose; narration may retain failed
  submitted usage, and account deletion must not refund shared daily charges.
