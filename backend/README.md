# Reader illustration backend

One container image contains the authenticated mobile API and Cloud Tasks worker
routes. Deploy it as two Cloud Run services: a public API service and a private
worker service. Set `WORKER_URL` to the worker and require Cloud Run IAM
authentication for that service.

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

The API never accepts an EPUB. It accepts one normalized chapter at a time,
deletes that prose immediately after scene planning, and calls the OpenAI
Responses API with response storage disabled.

The service runs text moderation before image generation and image moderation
before committing an asset. Credits are transactionally reserved and charged
only after a usable scene record and both private objects commit; retries reuse
the same reservation. `DELETE /v1/account` purges global jobs, temporary prose,
scene metadata, reservations, user records, and the user's storage prefix.

Before deployment:

```sh
npm install
npm run build
npm test
npm audit --omit=dev
```
