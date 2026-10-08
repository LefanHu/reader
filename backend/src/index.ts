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


function stylesFor(title: string): string[] {
  const normalized = title.toLowerCase();
  if (/cultivat|xianxia|wuxia|immortal|dao/.test(normalized)) {
    return ["Cinematic mythic ink fantasy", "Luminous eastern epic", "Painterly martial fantasy"];
  }
  if (/diary|school|kid|comic/.test(normalized)) {
    return ["Expressive monochrome diary sketch", "Loose graphic novel ink", "Playful editorial cartoon"];
  }
  if (/space|star|planet|sci-fi|science fiction/.test(normalized)) {
    return ["Cinematic science-fiction concept art", "Retro-futurist painted illustration", "Graphic cosmic noir"];
  }
  return ["Cinematic painterly book illustration", "Atmospheric graphic novel", "Textured monochrome ink"];
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

app.get("/healthz", (_req, res) => res.json({ ok: true }));
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

app.post("/v1/books", requireFeature, asyncRoute(async (req, res) => {
  const uid = req.uid!;
  const fingerprint = requireString(req.body.fingerprint, "fingerprint", 128);
  const title = requireString(req.body.title, "title", 500);
  const chapterCount = Math.max(1, Math.min(10000, Number(req.body.chapterCount) || 1));
  const bookId = createHash("sha256").update(`${uid}:${fingerprint}`).digest("hex").slice(0, 40);
  const styles = stylesFor(title);
  await userBook(uid, bookId).set({
    uid,
    fingerprint,
    title,
    authors: Array.isArray(req.body.authors) ? req.body.authors.slice(0, 20) : [],
    language: typeof req.body.language === "string" ? req.body.language : null,
    chapterCount,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });
  await db.collection("users").doc(uid).set({
    creditsRemaining: pilotCredits,
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });
  res.json({
    id: bookId,
    suggestedStyle: styles[0],
    alternativeStyles: styles.slice(1),
    estimatedCredits: chapterCount * 3,
  });
}));

app.put("/v1/books/:bookId/profile", requireFeature, asyncRoute(async (req, res) => {
  const reference = userBook(req.uid!, routeParam(req, "bookId"));
  if (!(await reference.get()).exists) throw new HttpError(404, "Book not found.");
  const style = requireString(req.body.style, "style", 300);
  const density = Math.max(1, Math.min(3, Number(req.body.density) || 3));
  await reference.set({
    profile: {
      style,
      density,
      styleVersion: Number(req.body.styleVersion) || 1,
      analysisVersion: Math.max(1, Number(req.body.analysisVersion) || 2),
    },
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });
  res.status(204).end();
}));

app.post("/v1/books/:bookId/chapters/:ordinal/jobs", requireFeature, asyncRoute(async (req, res) => {
  const uid = req.uid!;
  const bookId = routeParam(req, "bookId");
  const book = await userBook(uid, bookId).get();
  if (!book.exists) throw new HttpError(404, "Book not found.");
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
    title: typeof req.body.title === "string" ? req.body.title.slice(0, 500) : undefined,
    language: typeof req.body.language === "string" ? req.body.language.slice(0, 100) : undefined,
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
    if ((await transaction.get(jobRef)).exists) return;
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
    scenes: scenes.docs.map((scene) => ({
      id: scene.id,
      status: scene.data().status,
      anchor: scene.data().anchor,
      failureCategory: scene.data().failureCategory,
    })),
  });
}));

app.post("/v1/scenes/:sceneId/unlock", requireFeature, asyncRoute(async (req, res) => {
  const reference = db.collection("illustrationScenes").doc(routeParam(req, "sceneId"));
  const scene = await reference.get();
  if (!scene.exists || scene.data()?.uid !== req.uid) throw new HttpError(404, "Scene not found.");
  if (!["ready_locked", "unlocked"].includes(scene.data()?.status)) {
    throw new HttpError(409, "Scene is not ready.");
  }
  const assetExpiresAt = scene.data()?.assetExpiresAt as Timestamp | undefined;
  if (!assetExpiresAt || assetExpiresAt.toMillis() < Date.now() + 24 * 60 * 60 * 1000) {
    const targetGeneration = Number(scene.data()?.generationVersion ?? 1) + 1;
    await reference.set({
      status: "regenerating",
      regenerationTarget: targetGeneration,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    await enqueue(
      `/internal/scenes/${scene.id}/regenerate`,
      { sceneId: scene.id, targetGeneration, refresh: true },
      `refresh-${scene.id}-${targetGeneration}`,
    );
    throw new HttpError(409, "Scene asset is being refreshed.");
  }
  const bucket = storage.bucket(bucketName);
  const expires = Date.now() + 10 * 60 * 1000;
  const [imageUrl] = await bucket.file(scene.data()?.imageObject).getSignedUrl({ action: "read", expires });
  const [thumbnailUrl] = await bucket.file(scene.data()?.thumbnailObject).getSignedUrl({ action: "read", expires });
  await reference.set({ status: "unlocked", unlockedAt: FieldValue.serverTimestamp() }, { merge: true });
  res.json({
    imageUrl, thumbnailUrl,
    altText: scene.data()?.altText,
    caption: scene.data()?.caption,
    generationVersion: scene.data()?.generationVersion ?? 1,
  });
}));

app.post("/v1/scenes/:sceneId/regenerate", requireFeature, asyncRoute(async (req, res) => {
  const reference = db.collection("illustrationScenes").doc(routeParam(req, "sceneId"));
  const targetGeneration = await db.runTransaction(async (transaction) => {
    const scene = await transaction.get(reference);
    if (!scene.exists || scene.data()?.uid !== req.uid) {
      throw new HttpError(404, "Scene not found.");
    }
    if (scene.data()?.status === "regenerating") return null;
    const target = Number(scene.data()?.generationVersion ?? 1) + 1;
    transaction.set(reference, {
      status: "regenerating",
      regenerationTarget: target,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return target;
  });
  if (targetGeneration != null) {
    await enqueue(
      `/internal/scenes/${reference.id}/regenerate`,
      { sceneId: reference.id, targetGeneration },
      `regen-${reference.id}-${targetGeneration}`,
    );
  }
  res.status(202).end();
}));

app.delete("/v1/scenes/:sceneId", asyncRoute(async (req, res) => {
  const reference = db.collection("illustrationScenes").doc(routeParam(req, "sceneId"));
  const scene = await reference.get();
  if (!scene.exists || scene.data()?.uid !== req.uid) throw new HttpError(404, "Scene not found.");
  const bucket = storage.bucket(bucketName);
  await Promise.all([
    bucket.file(scene.data()?.imageObject).delete({ ignoreNotFound: true }),
    bucket.file(scene.data()?.thumbnailObject).delete({ ignoreNotFound: true }),
  ]);
  await Promise.all([
    reference.delete(),
    db.collection("worldReferences").doc(reference.id).delete(),
  ]);
  res.status(204).end();
}));

app.delete("/v1/books/:bookId", asyncRoute(async (req, res) => {
  const bookId = routeParam(req, "bookId");
  const reference = userBook(req.uid!, bookId);
  if (!(await reference.get()).exists) throw new HttpError(404, "Book not found.");
  const [scenes, jobs, reservations, revisions, references] = await Promise.all([
    db.collection("illustrationScenes")
      .where("uid", "==", req.uid).where("bookId", "==", bookId).get(),
    db.collection("illustrationJobs")
      .where("uid", "==", req.uid).where("bookId", "==", bookId).get(),
    db.collection("creditReservations")
      .where("uid", "==", req.uid).where("bookId", "==", bookId).get(),
    db.collection("worldRevisions")
      .where("uid", "==", req.uid).where("bookId", "==", bookId).get(),
    db.collection("worldReferences")
      .where("uid", "==", req.uid).where("bookId", "==", bookId).get(),
  ]);
  await storage.bucket(bucketName).deleteFiles({
    prefix: `users/${req.uid}/books/${bookId}/`,
    force: true,
  });
  const writer = db.bulkWriter();
  for (const scene of scenes.docs) writer.delete(scene.ref);
  for (const job of jobs.docs) {
    writer.delete(job.ref);
    writer.delete(db.collection("illustrationJobInputs").doc(job.id));
  }
  for (const reservation of reservations.docs) writer.delete(reservation.ref);
  for (const revision of revisions.docs) writer.delete(revision.ref);
  for (const worldReference of references.docs) writer.delete(worldReference.ref);
  writer.delete(reference);
  await writer.close();
  res.status(204).end();
}));

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
  db, storage, bucket: bucketName, pilotCredits, assetRetentionMilliseconds,
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
