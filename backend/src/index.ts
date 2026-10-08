import { createHash, createHmac } from "node:crypto";
import express, { type NextFunction, type Request, type Response } from "express";
import { CloudTasksClient } from "@google-cloud/tasks";
import { Storage } from "@google-cloud/storage";
import { applicationDefault, getApps, initializeApp } from "firebase-admin/app";
import { getAppCheck } from "firebase-admin/app-check";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, Timestamp, getFirestore } from "firebase-admin/firestore";
import {
  analyzeNarrative,
  composeImagePrompt,
  imageGenerationProvider,
  moderateImage,
  moderateText,
} from "./openai.js";
import { NarrationBackend, NarrationError } from "./narration.js";
import { RealtimeNarrationProvider } from "./narration-provider.js";
import { workerTaskRequest } from "./task-request.js";
import { accountDeletionRouter, accountUsageRouter, authenticateAccount } from "./account.js";
import { asyncRoute, HttpError, requireString, routeParam } from "./illustration-http.js";
import { illustrationWorkerRouter } from "./illustration-worker.js";
import { illustrationBookDeletion, illustrationBookRegistration } from "./illustration-books.js";
import { illustrationSceneRouter } from "./illustration-scenes.js";
import type { ChapterInput, Paragraph } from "./types.js";

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


const authenticate = authenticateAccount(
  (token) => getAuth().verifyIdToken(token),
  (token) => getAppCheck().verifyToken(token),
);

function userBook(uid: string, bookId: string) {
  return db.collection("users").doc(uid).collection("books").doc(bookId);
}




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
  db, narrationEnabled: process.env.NARRATION_ENABLED === "true", illustrationsEnabled,
}));
const narration = new NarrationBackend({ db, storage, bucket: bucketName,
  provider: new RealtimeNarrationProvider(), enabled: process.env.NARRATION_ENABLED === "true",
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

app.put("/v1/books/:bookId/profile", requireFeature, asyncRoute(async (req, res) => {
  const reference = userBook(req.uid!, routeParam(req, "bookId"));
  const style = requireString(req.body.style, "style", 300);
  const density = Math.max(1, Math.min(3, Number(req.body.density) || 3));
  await db.runTransaction(async (transaction) => {
    const [book, account] = await Promise.all([
      transaction.get(reference),
      transaction.get(db.collection("narrationAccountTombstones").doc(req.uid!)),
    ]);
    if (!book.exists) throw new HttpError(404, "Book not found.");
    if (book.data()?.deleted || account.exists) throw new HttpError(410, "Book was deleted.");
    transaction.update(reference, {
      profile: {
        style, density, styleVersion: Number(req.body.styleVersion) || 1,
        analysisVersion: Math.max(1, Number(req.body.analysisVersion) || 2),
      },
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
  res.status(204).end();
}));

app.post("/v1/books/:bookId/chapters/:ordinal/jobs", requireFeature, asyncRoute(async (req, res) => {
  const uid = req.uid!;
  const bookId = routeParam(req, "bookId");
  const book = await userBook(uid, bookId).get();
  if (!book.exists) throw new HttpError(404, "Book not found.");
  if (book.data()?.deleted) throw new HttpError(410, "Book was deleted.");
  const ordinal = Number.parseInt(routeParam(req, "ordinal"), 10);
  if (!Number.isInteger(ordinal) || ordinal < 0 || ordinal >= 10000) {
    throw new HttpError(400, "Chapter ordinal is invalid.");
  }
  const rawParagraphs = Array.isArray(req.body.paragraphs) ? req.body.paragraphs : [];
  if (rawParagraphs.length === 0 || rawParagraphs.length > 2000) {
    throw new HttpError(400, "Chapter paragraph count is invalid.");
  }
  let totalCharacters = 0;
  const paragraphIds = new Set<string>();
  const paragraphs: Paragraph[] = rawParagraphs.map((raw: unknown, index: number) => {
    if (!raw || typeof raw !== "object") throw new HttpError(400, "Paragraph is invalid.");
    const item = raw as Record<string, unknown>;
    const text = requireString(item.text, "paragraph text", 20000);
    totalCharacters += text.length;
    const id = requireString(item.id, "paragraph id", 100);
    if (paragraphIds.has(id)) throw new HttpError(400, "Paragraph IDs must be unique.");
    paragraphIds.add(id);
    const ordinal = Number(item.ordinal);
    const progression = Number(item.progression);
    if (ordinal !== index || !Number.isFinite(progression) || progression < 0 || progression > 1) {
      throw new HttpError(400, "Paragraph ordering is invalid.");
    }
    return {
      id,
      text,
      cssSelector: requireString(item.cssSelector, "CSS selector", 1000),
      ordinal,
      progression,
    };
  });
  if (totalCharacters > 400000) throw new HttpError(413, "Chapter text is too large.");
  const input: ChapterInput = {
    href: requireString(req.body.href, "href", 2000),
    ...(typeof req.body.title === "string" ? { title: req.body.title.slice(0, 500) } : {}),
    ...(typeof req.body.language === "string" ? { language: req.body.language.slice(0, 100) } : {}),
    styleVersion: Number(req.body.styleVersion) || 1,
    analysisVersion: Math.max(1, Number(req.body.analysisVersion) || 2),
    density: Math.max(1, Math.min(3, Number(req.body.density) || 3)),
    paragraphs,
  };
  const idempotency = createHash("sha256")
    .update(`${uid}:${bookId}:${ordinal}:${input.styleVersion}:${input.analysisVersion}:prompt-v2`)
    .digest("hex");
  const jobId = idempotency.slice(0, 40);
  const jobRef = db.collection("illustrationJobs").doc(jobId);
  const inputRef = db.collection("illustrationJobInputs").doc(jobId);
  await db.runTransaction(async (transaction) => {
    const [existing, currentBook, account] = await Promise.all([
      transaction.get(jobRef), transaction.get(userBook(uid, bookId)),
      transaction.get(db.collection("narrationAccountTombstones").doc(uid)),
    ]);
    if (!currentBook.exists) throw new HttpError(404, "Book not found.");
    if (currentBook.data()?.deleted || account.exists) throw new HttpError(410, "Book was deleted.");
    if (existing.exists) return;
    transaction.create(jobRef, {
      uid, bookId, chapterOrdinal: ordinal, status: "queued",
      createdAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp(),
    });
    transaction.create(inputRef, {
      uid, bookId, chapterOrdinal: ordinal, input,
      expiresAt: Timestamp.fromMillis(Date.now() + 24 * 60 * 60 * 1000),
    });
  });
  await enqueue(`/internal/jobs/${jobId}`, { jobId }, `job-${jobId}`);
  res.status(202).json({ id: jobId });
}));

app.get("/v1/jobs/:jobId", asyncRoute(async (req, res) => {
  const job = await db.collection("illustrationJobs").doc(routeParam(req, "jobId")).get();
  if (!job.exists || job.data()?.uid !== req.uid) throw new HttpError(404, "Job not found.");
  const scenes = await db.collection("illustrationScenes")
    .where("jobId", "==", job.id).get();
  res.json({
    id: job.id,
    status: job.data()?.status,
    failureCategory: job.data()?.failureCategory,
    scenes: scenes.docs.filter((scene) => !scene.data().deleted).map((scene) => ({
      id: scene.id,
      status: scene.data().status,
      anchor: scene.data().anchor,
      failureCategory: scene.data().failureCategory,
    })),
  });
}));

app.use("/v1", illustrationSceneRouter({
  db, storage, bucket: bucketName, requireFeature, enqueue,
}));
app.delete("/v1/books/:bookId", illustrationBookDeletion({ db, storage, bucket: bucketName }));

function requireTask(req: Request, res: Response, next: NextFunction) {
  if (serviceRole !== "worker") {
    res.status(404).end();
    return;
  }
  if (!req.header("x-cloudtasks-taskname") && (!process.env.WORKER_TOKEN || req.header("x-worker-token") !== process.env.WORKER_TOKEN)) {
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
  const status = (error instanceof HttpError || error instanceof NarrationError) ? error.status : 500;
  const message = (error instanceof HttpError || error instanceof NarrationError) ? error.message : "Illustration service failed.";
  // Log only category and stack; request bodies and provider responses are excluded.
  console.error(JSON.stringify({ category: error instanceof HttpError ? "http" : "internal", status }));
  res.status(status).json({ error: message });
});

const port = Number(process.env.PORT ?? 8080);
app.listen(port, () => console.log(JSON.stringify({ event: "listening", port })));
