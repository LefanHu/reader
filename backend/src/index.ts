import { createHmac } from "node:crypto";
import express, { type NextFunction, type Request, type Response } from "express";
import { CloudTasksClient } from "@google-cloud/tasks";
import { Storage } from "@google-cloud/storage";
import { applicationDefault, getApps, initializeApp } from "firebase-admin/app";
import { getAppCheck } from "firebase-admin/app-check";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import {
  analyzeNarrative,
  composeImagePrompt,
  imageGenerationProvider,
  moderateImage,
  moderateText,
} from "./openai.js";
import { NarrationBackend } from "./narration.js";
import { RealtimeNarrationProvider } from "./narration-provider.js";
import { workerTaskRequest } from "./task-request.js";
import { accountDeletionRouter, accountUsageRouter, authenticateAccount } from "./account.js";
import { asyncRoute, HttpError } from "./http.js";
import { illustrationWorkerRouter } from "./illustration-worker.js";
import { illustrationBookDeletion, illustrationBookRegistration } from "./illustration-books.js";
import { illustrationSceneRouter } from "./illustration-scenes.js";
import { illustrationJobRouter } from "./illustration-jobs.js";

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
const assetRetentionMilliseconds = 30 * 24 * 60 * 60 * 1000;
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
app.use("/v1", authenticate);
app.use("/v1/account", accountUsageRouter({
  db, narrationEnabled, illustrationsEnabled,
}));
const narration = new NarrationBackend({ db, storage, bucket: bucketName,
  provider: new RealtimeNarrationProvider(), enabled: narrationEnabled,
  enqueue: (path, payload, id) => enqueue(path, payload, id, process.env.NARRATION_TASK_QUEUE ?? "reader-narration"),
});
app.use("/v1/account", accountDeletionRouter({ db, storage, bucket: bucketName, narration }));
app.use("/v1/narration", narration.api());
function requireFeature(_req: Request, res: Response, next: NextFunction) {
  if (!illustrationsEnabled) {
    res.status(503).json({ error: "Illustrations are temporarily unavailable." });
    return;
  }
  next();
}

app.get("/v1/fingerprint-key", asyncRoute(async (req, res) => {
  if (!fingerprintSecret) throw new HttpError(503, "Fingerprinting is not configured.");
  const key = createHmac("sha256", fingerprintSecret)
    .update(req.uid!)
    .digest("base64");
  res.json({ key });
}));

app.post("/v1/books", requireFeature, illustrationBookRegistration({ db, pilotCredits }));

app.use("/v1", illustrationJobRouter({ db, requireFeature, enqueue }));

app.use("/v1", illustrationSceneRouter({
  db, storage, bucket: bucketName, requireFeature, enqueue,
}));
app.delete("/v1/books/:bookId", illustrationBookDeletion({ db, storage, bucket: bucketName }));

function requireTask(req: Request, res: Response, next: NextFunction) {
  if (serviceRole !== "worker") {
    res.status(404).end();
    return;
  }
  if (!req.header("x-cloudtasks-taskname")) {
    res.status(403).json({ error: "Cloud Tasks invocation required." });
    return;
  }
  next();
}
app.use("/internal", requireTask);
app.use("/internal/narration", narration.worker());
app.use("/internal", (_req, res, next) => {
  if (!illustrationsEnabled) {
    res.status(503).json({ error: "Illustration generation is disabled." });
    return;
  }
  next();
});

app.use("/internal", illustrationWorkerRouter({
  db, storage, bucket: bucketName, assetRetentionMilliseconds,
  analyzeNarrative, composeImagePrompt, imageGenerationProvider, moderateImage, moderateText,
}));

app.use((error: unknown, _req: Request, res: Response, _next: NextFunction) => {
  const status = error instanceof HttpError ? error.status : 500;
  const message = error instanceof HttpError ? error.message : "Request failed.";
  // Log only category and stack; request bodies and provider responses are excluded.
  console.error(JSON.stringify({ category: error instanceof HttpError ? "http" : "internal", status }));
  res.status(status).json({ error: message });
});

const port = Number(process.env.PORT ?? 8080);
app.listen(port, () => console.log(JSON.stringify({ event: "listening", port })));
