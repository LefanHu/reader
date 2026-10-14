import { createHmac } from "node:crypto";
import express, { type NextFunction, type Request, type Response } from "express";
import { CloudTasksClient } from "@google-cloud/tasks";
import { Storage } from "@google-cloud/storage";
import { applicationDefault, getApps, initializeApp } from "firebase-admin/app";
import { getAppCheck } from "firebase-admin/app-check";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import {
  composeImagePrompt,
  moderateImage,
  moderateText,
} from "./openai.js";
import { selectScenes } from "./scene-selection.js";
import { NarrationBackend } from "./narration.js";
import { RealtimeNarrationProvider } from "./narration-provider.js";
import { workerTaskRequest } from "./task-request.js";
import { accountDeletionRouter, accountUsageRouter, authenticateAccount } from "./account.js";
import { asyncRoute, HttpError, httpErrorHandler } from "./http.js";
import { openAIApiKey } from "./openai-client.js";
import { illustrationWorkerRouter } from "./illustration-worker.js";
import { illustrationBookDeletion, illustrationBookRegistration } from "./illustration-books.js";
import { illustrationSceneRouter } from "./illustration-scenes.js";
import { illustrationJobRouter } from "./illustration-jobs.js";
import { illustrationConfiguration } from "./illustration-configuration.js";
import { createImageProviderRegistry } from "./image-provider-registry.js";
import { bookAnalysisApiRouter } from "./book-analysis-api.js";
import { bookAnalysisWorkerRouter } from "./book-analysis-worker.js";
import { ResponsesBookAnalysisProvider } from "./book-analysis-provider.js";
import { ASSET_RETENTION_MILLISECONDS } from "./durations.js";
import { worksApiRouter } from "./works-api.js";

if (getApps().length === 0) initializeApp({ credential: applicationDefault() });
const db = getFirestore();
const storage = new Storage();
const tasks = new CloudTasksClient();
const app = express();
app.use(express.json({ limit: "5mb" }));

const projectId = process.env.GOOGLE_CLOUD_PROJECT ?? "";
const bucketName = process.env.ILLUSTRATION_BUCKET ?? "";
const taskLocation = process.env.TASK_LOCATION ?? "us-central1";
const taskQueue = process.env.TASK_QUEUE ?? "reader-illustrations";
const workerUrl = process.env.WORKER_URL ?? "";
const taskServiceAccount = process.env.TASK_SERVICE_ACCOUNT ?? "";
const fingerprintSecret = process.env.FINGERPRINT_SECRET ?? "";
const pilotCredits = Number.parseInt(process.env.PILOT_CREDITS ?? "100", 10);
const illustrationsEnabled = process.env.ILLUSTRATIONS_ENABLED === "true";
const serviceRole = process.env.SERVICE_ROLE ?? "api";
const narrationEnabled = process.env.NARRATION_ENABLED === "true";


const authenticate = authenticateAccount(
  (token) => getAuth().verifyIdToken(token),
  (token) => getAppCheck().verifyToken(token),
);

async function enqueue(path: string, payload: Record<string, unknown>, taskId: string, queue = taskQueue) {
  if (!projectId || !workerUrl || !taskServiceAccount) {
    throw new HttpError(503, "The illustration worker is not configured.");
  }
  try {
    await tasks.createTask(workerTaskRequest(tasks, {
      project: projectId, location: taskLocation, queue, taskId,
      workerUrl, serviceAccount: taskServiceAccount, path, payload,
    }));
  } catch (error) {
    // ALREADY_EXISTS makes retries idempotent.
    if ((error as { code?: number }).code !== 6) throw error;
  }
}

// Cloud Run reserves some paths ending in "z"; health must reach this container.
app.get("/health", (_req, res) => res.json({ ok: true }));
app.use("/api", authenticate);
app.use("/api/account", accountUsageRouter({
  db, narrationEnabled, illustrationsEnabled,
}));
const narration = new NarrationBackend({ db, storage, bucket: bucketName,
  provider: new RealtimeNarrationProvider(), enabled: narrationEnabled,
  enqueue: (path, payload, id) => enqueue(path, payload, id, process.env.NARRATION_TASK_QUEUE ?? "reader-narration"),
});
app.use("/api/account", accountDeletionRouter({ db, storage, bucket: bucketName, narration }));
app.use("/api/narration", narration.api());
function requireFeature(_req: Request, _res: Response, next: NextFunction) {
  next(illustrationsEnabled ? undefined : new HttpError(503, "Illustrations are temporarily unavailable."));
}

// Preprocessing shares Auth/App Check and rollout, but never image credits or availability.
app.use("/api/book-analysis", bookAnalysisApiRouter({
  db, requireFeature, fingerprintSecret,
  // Library-wide preprocessing must not queue ahead of requested illustrations.
  enqueue: (path, payload, id) => enqueue(path, payload, id, process.env.BOOK_ANALYSIS_TASK_QUEUE ?? "reader-book-analysis"),
}));

app.use("/api", worksApiRouter({ db, storage, bucket: bucketName, requireFeature }));

app.get("/api/fingerprint-key", asyncRoute(async (req, res) => {
  if (!fingerprintSecret) throw new HttpError(503, "Fingerprinting is not configured.");
  const key = createHmac("sha256", fingerprintSecret)
    .update(req.uid!)
    .digest("base64");
  res.json({ key });
}));

app.get("/api/illustrations/config", illustrationConfiguration);
app.post("/api/books", requireFeature, illustrationBookRegistration({ db, pilotCredits }));

app.use("/api", illustrationJobRouter({ db, requireFeature, enqueue }));

app.use("/api", illustrationSceneRouter({
  db, storage, bucket: bucketName, requireFeature, enqueue,
}));
app.delete("/api/books/:bookId", illustrationBookDeletion({ db, storage, bucket: bucketName }));

function requireTask(req: Request, res: Response, next: NextFunction) {
  if (serviceRole !== "worker") {
    res.status(404).end();
    return;
  }
  next(req.header("x-cloudtasks-taskname") ? undefined : new HttpError(403, "Cloud Tasks invocation required."));
}
app.use("/internal", requireTask);
app.use("/internal/narration", narration.worker());
app.use("/internal/book-analysis", requireFeature, (_req, _res, next) => {
  // API instances have no provider secret; workers wait without consuming paid intent.
  next(openAIApiKey() ? undefined : new HttpError(503, "Book preprocessing is temporarily unavailable."));
}, bookAnalysisWorkerRouter({
  db, provider: new ResponsesBookAnalysisProvider(),
}));
app.use("/internal", (_req, _res, next) => {
  next(illustrationsEnabled ? undefined : new HttpError(503, "Illustration generation is disabled."));
});

app.use("/internal", illustrationWorkerRouter({
  db, storage, bucket: bucketName, assetRetentionMilliseconds: ASSET_RETENTION_MILLISECONDS,
  selectScenes, composeImagePrompt, imageGenerationProvider: createImageProviderRegistry(), moderateImage, moderateText,
}));

app.use(httpErrorHandler());

const port = Number(process.env.PORT ?? 8080);
app.listen(port, () => console.log(JSON.stringify({ event: "listening", port })));
