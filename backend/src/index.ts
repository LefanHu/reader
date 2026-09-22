import { createHash, createHmac } from "node:crypto";
import express, { type NextFunction, type Request, type Response } from "express";
import { CloudTasksClient } from "@google-cloud/tasks";
import { Storage } from "@google-cloud/storage";
import { applicationDefault, getApps, initializeApp } from "firebase-admin/app";
import { getAppCheck } from "firebase-admin/app-check";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, Timestamp, getFirestore } from "firebase-admin/firestore";
import sharp from "sharp";
import {
  composeImagePrompt,
  imageGenerationProvider,
  moderateImage,
  moderateText,
  planScenes,
} from "./openai.js";
import type { ChapterInput, Paragraph, VisualBibleEntry } from "./types.js";

if (getApps().length === 0) initializeApp({ credential: applicationDefault() });
const db = getFirestore();
const storage = new Storage();
const tasks = new CloudTasksClient();
const app = express();
app.use(express.json({ limit: "5mb" }));

type AuthedRequest = Request & { uid?: string };
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

function asyncRoute(
  handler: (req: AuthedRequest, res: Response) => Promise<void>,
) {
  return (req: AuthedRequest, res: Response, next: NextFunction) => {
    handler(req, res).catch(next);
  };
}

async function authenticate(req: AuthedRequest, res: Response, next: NextFunction) {
  try {
    const bearer = req.header("authorization")?.replace(/^Bearer\s+/i, "");
    const appCheck = req.header("x-firebase-appcheck");
    if (!bearer || !appCheck) throw new Error("missing credentials");
    const [decoded] = await Promise.all([
      getAuth().verifyIdToken(bearer),
      getAppCheck().verifyToken(appCheck),
    ]);
    req.uid = decoded.uid;
    next();
  } catch {
    res.status(401).json({ error: "Authentication and App Check are required." });
  }
}

function userBook(uid: string, bookId: string) {
  return db.collection("users").doc(uid).collection("books").doc(bookId);
}

function requireString(value: unknown, label: string, maxLength = 500): string {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) {
    throw new HttpError(400, `${label} is invalid.`);
  }
  return value;
}

function routeParam(req: Request, name: string): string {
  return requireString(req.params[name], `${name} route parameter`, 200);
}

class HttpError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

class SafetyError extends Error {}

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

async function loadReferenceImages(entries: VisualBibleEntry[]): Promise<Buffer[]> {
  const objects = [...new Set(
    entries.map((entry) => entry.referenceObject).filter((value): value is string => Boolean(value)),
  )].slice(-2);
  const images: Buffer[] = [];
  for (const object of objects) {
    try {
      const [image] = await storage.bucket(bucketName).file(object).download();
      images.push(image);
    } catch {
      // A lifecycle cleanup or replacement can remove an old reference; text
      // continuity remains sufficient and generation should continue.
    }
  }
  return images;
}

async function enqueue(path: string, payload: Record<string, unknown>, taskId: string) {
  if (!projectId || !workerUrl || !taskServiceAccount) {
    throw new HttpError(503, "The illustration worker is not configured.");
  }
  const parent = tasks.queuePath(projectId, taskLocation, taskQueue);
  try {
    await tasks.createTask({
      parent,
      task: {
        name: tasks.taskPath(projectId, taskLocation, taskQueue, taskId),
        httpRequest: {
          httpMethod: "POST",
          url: `${workerUrl}${path}`,
          headers: { "content-type": "application/json" },
          body: Buffer.from(JSON.stringify(payload)).toString("base64"),
          oidcToken: { serviceAccountEmail: taskServiceAccount },
        },
      },
    });
  } catch (error) {
    // ALREADY_EXISTS makes retries idempotent.
    if ((error as { code?: number }).code !== 6) throw error;
  }
}

app.get("/healthz", (_req, res) => res.json({ ok: true }));
app.use("/v1", authenticate);
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
    profile: { style, density, styleVersion: Number(req.body.styleVersion) || 1 },
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
    density: Math.max(1, Math.min(3, Number(req.body.density) || 3)),
    paragraphs,
  };
  const idempotency = createHash("sha256")
    .update(`${uid}:${bookId}:${ordinal}:${input.styleVersion}:prompt-v1`)
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
  await reference.delete();
  res.status(204).end();
}));

app.delete("/v1/books/:bookId", asyncRoute(async (req, res) => {
  const bookId = routeParam(req, "bookId");
  const reference = userBook(req.uid!, bookId);
  if (!(await reference.get()).exists) throw new HttpError(404, "Book not found.");
  const [scenes, jobs, reservations] = await Promise.all([
    db.collection("illustrationScenes")
      .where("uid", "==", req.uid).where("bookId", "==", bookId).get(),
    db.collection("illustrationJobs")
      .where("uid", "==", req.uid).where("bookId", "==", bookId).get(),
    db.collection("creditReservations")
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
  writer.delete(reference);
  await writer.close();
  res.status(204).end();
}));

app.delete("/v1/account", asyncRoute(async (req, res) => {
  const uid = req.uid!;
  const [scenes, jobs, inputs, reservations] = await Promise.all([
    db.collection("illustrationScenes").where("uid", "==", uid).get(),
    db.collection("illustrationJobs").where("uid", "==", uid).get(),
    db.collection("illustrationJobInputs").where("uid", "==", uid).get(),
    db.collection("creditReservations").where("uid", "==", uid).get(),
  ]);
  await storage.bucket(bucketName).deleteFiles({
    prefix: `users/${uid}/`,
    force: true,
  });
  const writer = db.bulkWriter();
  for (const snapshot of [scenes, jobs, inputs, reservations]) {
    for (const document of snapshot.docs) writer.delete(document.ref);
  }
  await writer.close();
  await db.recursiveDelete(db.collection("users").doc(uid));
  res.status(204).end();
}));

function requireTask(req: Request, res: Response, next: NextFunction) {
  if (serviceRole !== "worker") {
    res.status(404).end();
    return;
  }
  if (!req.header("x-cloudtasks-taskname") && req.header("x-worker-token") !== process.env.WORKER_TOKEN) {
    res.status(403).json({ error: "Cloud Tasks invocation required." });
    return;
  }
  next();
}
app.use("/internal", requireTask);
app.use("/internal", (_req, res, next) => {
  if (!illustrationsEnabled) {
    res.status(503).json({ error: "Illustration generation is disabled." });
    return;
  }
  next();
});

function creditReservation(uid: string, operationId: string) {
  const id = createHash("sha256").update(`${uid}:${operationId}`).digest("hex");
  return db.collection("creditReservations").doc(id);
}

async function reserveCredit(
  uid: string,
  operationId: string,
  bookId: string,
): Promise<boolean> {
  const userRef = db.collection("users").doc(uid);
  const reservationRef = creditReservation(uid, operationId);
  return db.runTransaction(async (transaction) => {
    const [user, reservation] = await Promise.all([
      transaction.get(userRef),
      transaction.get(reservationRef),
    ]);
    if (reservation.exists) return reservation.data()?.state === "reserved";
    const remaining = Number(user.data()?.creditsRemaining ?? pilotCredits);
    const reserved = Number(user.data()?.creditsReserved ?? 0);
    if (remaining - reserved < 1) return false;
    transaction.set(userRef, {
      creditsReserved: reserved + 1,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    transaction.create(reservationRef, {
      uid,
      bookId,
      operationId,
      state: "reserved",
      createdAt: FieldValue.serverTimestamp(),
    });
    return true;
  });
}

async function commitCredit(uid: string, operationId: string) {
  const userRef = db.collection("users").doc(uid);
  const reservationRef = creditReservation(uid, operationId);
  await db.runTransaction(async (transaction) => {
    const reservation = await transaction.get(reservationRef);
    if (!reservation.exists || reservation.data()?.state !== "reserved") return;
    transaction.set(userRef, {
      creditsRemaining: FieldValue.increment(-1),
      creditsReserved: FieldValue.increment(-1),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    transaction.update(reservationRef, {
      state: "committed",
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

async function refundCredit(uid: string, operationId: string) {
  const userRef = db.collection("users").doc(uid);
  const reservationRef = creditReservation(uid, operationId);
  await db.runTransaction(async (transaction) => {
    const reservation = await transaction.get(reservationRef);
    if (!reservation.exists || reservation.data()?.state !== "reserved") return;
    transaction.set(userRef, {
      creditsReserved: FieldValue.increment(-1),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    transaction.update(reservationRef, {
      state: "refunded",
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

app.post("/internal/jobs/:jobId", asyncRoute(async (req, res) => {
  const jobId = routeParam(req, "jobId");
  const jobRef = db.collection("illustrationJobs").doc(jobId);
  const inputRef = db.collection("illustrationJobInputs").doc(jobId);
  const jobData = await db.runTransaction(async (transaction) => {
    const job = await transaction.get(jobRef);
    if (!job.exists) throw new HttpError(404, "Job not found.");
    if (job.data()?.status === "complete") return null;
    const leaseUntil = job.data()?.leaseUntil as Timestamp | undefined;
    if (
      job.data()?.status === "analyzing" &&
      (leaseUntil?.toMillis() ?? 0) > Date.now()
    ) {
      return null;
    }
    transaction.set(jobRef, {
      status: "analyzing",
      leaseUntil: Timestamp.fromMillis(Date.now() + 10 * 60 * 1000),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return job.data()!;
  });
  if (jobData == null) {
    res.status(204).end();
    return;
  }
  const inputSnapshot = await inputRef.get();
  if (!inputSnapshot.exists) {
    await jobRef.set({
      status: "failed",
      failureCategory: "missing_input",
      leaseUntil: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    throw new HttpError(404, "Job input not found.");
  }
  const uid = jobData.uid as string;
  const bookId = jobData.bookId as string;
  const chapterOrdinal = jobData.chapterOrdinal as number;
  const input = inputSnapshot.data()?.input as ChapterInput;
  try {
    const bookRef = userBook(uid, bookId);
    const book = await bookRef.get();
    const profile = book.data()?.profile as { style?: string } | undefined;
    if (!profile?.style) throw new Error("Book profile is incomplete");
    const bible = (book.data()?.visualBible ?? []) as VisualBibleEntry[];
    const newBibleEntries: VisualBibleEntry[] = [];
    const candidates = await planScenes(input);
    await inputRef.delete();
    let committed = 0;
    let finalStatus = "complete";
    for (const candidate of candidates) {
      if (committed >= input.density) break;
      const sceneId = createHash("sha256")
        .update(`${jobId}:${candidate.startParagraphId}:${candidate.endParagraphId}`)
        .digest("hex").slice(0, 40);
      const sceneRef = db.collection("illustrationScenes").doc(sceneId);
      const existing = await sceneRef.get();
      if (existing.exists) {
        if (["ready_locked", "unlocked"].includes(existing.data()?.status)) {
          await commitCredit(uid, sceneId);
          committed++;
        }
        continue;
      }
      const start = input.paragraphs.findIndex((p) => p.id === candidate.startParagraphId);
      const end = input.paragraphs.findIndex((p) => p.id === candidate.endParagraphId);
      const sceneText = input.paragraphs.slice(start, end + 1).map((p) => p.text).join("\n");
      const continuitySnapshot = bible.filter((entry) =>
        entry.chapterOrdinal < chapterOrdinal ||
        (entry.chapterOrdinal === chapterOrdinal && entry.paragraphOrdinal <= start)
      );
      const prompt = composeImagePrompt({
        style: profile.style,
        sceneText,
        facts: candidate.facts,
        visualBible: continuitySnapshot,
      });
      if (await moderateText(prompt)) {
        console.info(JSON.stringify({ category: "safety", outcome: "text_blocked" }));
        continue;
      }
      if (!(await reserveCredit(uid, sceneId, bookId))) {
        finalStatus = "insufficient_credits";
        break;
      }
      const prefix = `users/${uid}/books/${bookId}/scenes/${sceneId}`;
      const imageObject = `${prefix}.webp`;
      const thumbnailObject = `${prefix}.thumb.webp`;
      try {
        const image = await imageGenerationProvider.generate(
          prompt,
          await loadReferenceImages(continuitySnapshot),
        );
        if (await moderateImage(image)) throw new SafetyError("image blocked");
        const thumbnail = await sharp(image).resize({ width: 640, withoutEnlargement: true }).webp({ quality: 78 }).toBuffer();
        const bucket = storage.bucket(bucketName);
        await Promise.all([
          bucket.file(imageObject).save(image, { contentType: "image/webp", resumable: false }),
          bucket.file(thumbnailObject).save(thumbnail, { contentType: "image/webp", resumable: false }),
        ]);
        const endParagraph = input.paragraphs[end]!;
        await sceneRef.create({
          uid, bookId, jobId, chapterOrdinal,
          status: "ready_locked",
          anchor: {
            href: input.href,
            spineOrdinal: chapterOrdinal,
            paragraphId: endParagraph.id,
            cssSelector: endParagraph.cssSelector,
            fallbackProgression: endParagraph.progression,
          },
          altText: candidate.altText,
          caption: candidate.caption,
          generationSpec: { style: profile.style, facts: candidate.facts, visualBible: continuitySnapshot },
          imageObject, thumbnailObject, generationVersion: 1,
          assetExpiresAt: Timestamp.fromMillis(Date.now() + assetRetentionMilliseconds),
          createdAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp(),
        });
        await commitCredit(uid, sceneId);
        const deltas = candidate.continuityDeltas.map((fact) => ({
          chapterOrdinal,
          paragraphOrdinal: end,
          fact,
          referenceObject: imageObject,
        }));
        bible.push(...deltas);
        newBibleEntries.push(...deltas);
        committed++;
      } catch (error) {
        await refundCredit(uid, sceneId);
        const bucket = storage.bucket(bucketName);
        await Promise.all([
          bucket.file(imageObject).delete({ ignoreNotFound: true }),
          bucket.file(thumbnailObject).delete({ ignoreNotFound: true }),
        ]).catch(() => undefined);
        console.info(JSON.stringify({
          category: "candidate",
          outcome: error instanceof SafetyError ? "image_blocked" : "generation_failed",
        }));
      }
    }
    await db.runTransaction(async (transaction) => {
      const latest = await transaction.get(bookRef);
      const combined = [
        ...((latest.data()?.visualBible ?? []) as VisualBibleEntry[]),
        ...newBibleEntries,
      ];
      const unique = new Map(
        combined.map((entry) => [
          `${entry.chapterOrdinal}:${entry.paragraphOrdinal}:${entry.fact}`,
          entry,
        ]),
      );
      const ordered = [...unique.values()].sort((left, right) =>
        left.chapterOrdinal - right.chapterOrdinal ||
        left.paragraphOrdinal - right.paragraphOrdinal
      );
      transaction.set(bookRef, {
        visualBible: ordered.slice(-500),
        visualBibleVersion: FieldValue.increment(committed),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    });
    await jobRef.set({
      status: finalStatus,
      leaseUntil: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    res.status(204).end();
  } catch (error) {
    await inputRef.delete().catch(() => undefined);
    await jobRef.set({
      status: "failed", failureCategory: "worker_failed",
      leaseUntil: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    throw error;
  }
}));

app.post("/internal/scenes/:sceneId/regenerate", asyncRoute(async (req, res) => {
  const reference = db.collection("illustrationScenes").doc(routeParam(req, "sceneId"));
  const targetGeneration = Math.max(2, Number(req.body.targetGeneration) || 0);
  const data = await db.runTransaction(async (transaction) => {
    const scene = await transaction.get(reference);
    if (!scene.exists) throw new HttpError(404, "Scene not found.");
    if (Number(scene.data()?.generationVersion ?? 1) >= targetGeneration) return null;
    const leaseUntil = scene.data()?.regenerationLeaseUntil as Timestamp | undefined;
    if ((leaseUntil?.toMillis() ?? 0) > Date.now()) {
      throw new HttpError(409, "Regeneration is already running.");
    }
    transaction.set(reference, {
      regenerationLeaseUntil: Timestamp.fromMillis(Date.now() + 10 * 60 * 1000),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return scene.data()!;
  });
  if (data == null) {
    res.status(204).end();
    return;
  }
  const spec = data.generationSpec as { style: string; facts: string[]; visualBible: VisualBibleEntry[] };
  const operationId = `${reference.id}:generation:${targetGeneration}`;
  const refresh = req.body.refresh === true;
  if (!refresh && !(await reserveCredit(data.uid, operationId, data.bookId))) {
    await reference.set({
      status: "unlocked",
      failureCategory: "insufficient_credits",
      regenerationTarget: FieldValue.delete(),
      regenerationLeaseUntil: FieldValue.delete(),
    }, { merge: true });
    throw new HttpError(402, "Insufficient credits.");
  }
  const oldImageObject = data.imageObject as string;
  const oldThumbnailObject = data.thumbnailObject as string;
  const prefix = `users/${data.uid}/books/${data.bookId}/scenes/${reference.id}.v${targetGeneration}`;
  const imageObject = `${prefix}.webp`;
  const thumbnailObject = `${prefix}.thumb.webp`;
  try {
    const prompt = composeImagePrompt({
      style: spec.style,
      sceneText: spec.facts.join("; "),
      facts: spec.facts,
      visualBible: spec.visualBible,
    });
    if (await moderateText(prompt)) throw new SafetyError("text blocked");
    const image = await imageGenerationProvider.generate(
      prompt,
      await loadReferenceImages(spec.visualBible),
    );
    if (await moderateImage(image)) throw new SafetyError("image blocked");
    const thumbnail = await sharp(image).resize({ width: 640, withoutEnlargement: true }).webp({ quality: 78 }).toBuffer();
    const bucket = storage.bucket(bucketName);
    await Promise.all([
      bucket.file(imageObject).save(image, { contentType: "image/webp", resumable: false }),
      bucket.file(thumbnailObject).save(thumbnail, { contentType: "image/webp", resumable: false }),
    ]);
    await reference.set({
      status: "ready_locked",
      imageObject,
      thumbnailObject,
      generationVersion: targetGeneration,
      assetExpiresAt: Timestamp.fromMillis(Date.now() + assetRetentionMilliseconds),
      regenerationTarget: FieldValue.delete(),
      regenerationLeaseUntil: FieldValue.delete(),
      failureCategory: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    if (!refresh) await commitCredit(data.uid, operationId);
    await Promise.all([
      storage.bucket(bucketName).file(oldImageObject).delete({ ignoreNotFound: true }),
      storage.bucket(bucketName).file(oldThumbnailObject).delete({ ignoreNotFound: true }),
    ]).catch(() => undefined);
    res.status(204).end();
  } catch (error) {
    if (!refresh) await refundCredit(data.uid, operationId);
    await Promise.all([
      storage.bucket(bucketName).file(imageObject).delete({ ignoreNotFound: true }),
      storage.bucket(bucketName).file(thumbnailObject).delete({ ignoreNotFound: true }),
    ]).catch(() => undefined);
    await reference.set({
      status: "unlocked",
      regenerationTarget: FieldValue.delete(),
      regenerationLeaseUntil: FieldValue.delete(),
      failureCategory: error instanceof SafetyError ? "safety_blocked" : "regeneration_failed",
    }, { merge: true });
    throw error;
  }
}));

app.use((error: unknown, _req: Request, res: Response, _next: NextFunction) => {
  const status = error instanceof HttpError ? error.status : 500;
  const message = error instanceof HttpError ? error.message : "Illustration service failed.";
  // Log only category and stack; request bodies and provider responses are excluded.
  console.error(JSON.stringify({ category: error instanceof HttpError ? "http" : "internal", status }));
  res.status(status).json({ error: message });
});

const port = Number(process.env.PORT ?? 8080);
app.listen(port, () => console.log(JSON.stringify({ event: "listening", port })));
