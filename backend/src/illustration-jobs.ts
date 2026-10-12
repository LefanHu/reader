import { createHash } from "node:crypto";
import express, { type RequestHandler } from "express";
import { FieldValue, Timestamp, type Firestore } from "firebase-admin/firestore";
import { asyncRoute, HttpError, requireString, routeParam } from "./http.js";
import { bookReference, readBookFence } from "./fences.js";
import type { ChapterInput, Paragraph } from "./types.js";
import { requireAvailableImageProvider, requireIllustrationProfile, snapshotImageGenerationConfig } from "./illustration-configuration.js";
import type { IllustrationBookProfile } from "./types.js";

function requireInteger(value: unknown, name: string, minimum: number, maximum = Number.MAX_SAFE_INTEGER): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new HttpError(400, `${name} is invalid.`);
  }
  return value;
}

/**
 * Book profile, chapter job creation and job polling, mounted under `/api`.
 * Job polling stays readable while the illustration feature flag is off.
 */
export function illustrationJobRouter(deps: {
  db: Firestore;
  requireFeature: RequestHandler;
  enqueue: (path: string, payload: Record<string, unknown>, taskId: string) => Promise<void>;
}): express.Router {
  const { db, requireFeature, enqueue } = deps;
  const router = express.Router();

  router.put("/books/:bookId/profile", requireFeature, asyncRoute(async (req, res) => {
    const uid = req.uid!;
    const bookId = routeParam(req, "bookId");
    const reference = bookReference(db, "books", uid, bookId);
    const providerId = requireAvailableImageProvider(req.body.providerId);
    const style = requireString(req.body.style, "style", 300);
    const density = requireInteger(req.body.density, "density", 1, 3);
    const expectedRevision = requireInteger(req.body.expectedRevision, "expectedRevision", 0);
    const profile = await db.runTransaction(async (transaction) => {
      const fence = await readBookFence(transaction, db, "books", uid, bookId);
      if (!fence.book.exists) throw new HttpError(404, "Book not found.");
      if (!fence.live) throw new HttpError(410, "Book was deleted.");
      const current = fence.book.data()?.profile ? requireIllustrationProfile(fence.book.data()?.profile) : undefined;
      if (current && current.providerId === providerId && current.style === style &&
          current.density === density) return current;
      if ((current?.revision ?? 0) !== expectedRevision) throw new HttpError(409, "Illustration settings have changed. Reopen settings.");
      const saved: IllustrationBookProfile = { providerId, style, density, revision: (current?.revision ?? 0) + 1 };
      transaction.update(reference, { profile: saved, updatedAt: FieldValue.serverTimestamp() });
      return saved;
    });
    res.json(profile);
  }));

  router.post("/books/:bookId/chapters/:ordinal/jobs", requireFeature, asyncRoute(async (req, res) => {
    const uid = req.uid!;
    const bookId = routeParam(req, "bookId");
    const profileRevision = requireInteger(req.body.profileRevision, "profileRevision", 1);
    const ordinal = Number(routeParam(req, "ordinal"));
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
        ordinal,
        progression,
      };
    });
    if (totalCharacters > 400000) throw new HttpError(413, "Chapter text is too large.");
    const inputMetadata = {
      href: requireString(req.body.href, "href", 2000),
      ...(typeof req.body.title === "string" ? { title: req.body.title.slice(0, 500) } : {}),
      ...(typeof req.body.language === "string" ? { language: req.body.language.slice(0, 100) } : {}),
      profileRevision, paragraphs,
    };
    const idempotency = createHash("sha256")
      .update(`${uid}:${bookId}:${ordinal}:${profileRevision}:illustrations`)
      .digest("hex");
    const jobId = idempotency.slice(0, 40);
    const jobRef = db.collection("illustrationJobs").doc(jobId);
    const inputRef = db.collection("illustrationJobInputs").doc(jobId);
    await db.runTransaction(async (transaction) => {
      const [existing, fence] = await Promise.all([
        transaction.get(jobRef), readBookFence(transaction, db, "books", uid, bookId),
      ]);
      if (!fence.book.exists) throw new HttpError(404, "Book not found.");
      if (!fence.live) throw new HttpError(410, "Book was deleted.");
      // Retry admitted intent before consulting changed preferences or model environment.
      if (existing.exists) {
        if (existing.data()?.uid !== uid || existing.data()?.bookId !== bookId) {
          throw new HttpError(409, "Illustration operation is invalid.");
        }
        return;
      }
      // Image intents wait for finalized, matching preprocessing; no scene-only fallback or credit use.
      const analysisId = fence.book.data()?.latestAnalysisGenerationId;
      const analysis = typeof analysisId === "string"
        ? (await transaction.get(db.collection("bookAnalysisRecords").doc(analysisId))).data() : undefined;
      if (!analysis || analysis.uid !== uid || analysis.bookId !== bookId || analysis.status !== "complete") {
        throw new HttpError(409, "Book preprocessing is not complete.");
      }
      const profile = requireIllustrationProfile(fence.book.data()?.profile);
      if (profile.revision !== profileRevision) {
        throw new HttpError(409, "Illustration settings have changed. Reopen settings.");
      }
      requireAvailableImageProvider(profile.providerId);
      const imageConfig = snapshotImageGenerationConfig(profile.providerId);
      const input: ChapterInput = { ...inputMetadata, density: profile.density };
      // Durable prose-free intent survives expiring input and worker lease recovery.
      transaction.create(jobRef, {
        uid, bookId, chapterOrdinal: ordinal, status: "queued",
        profile, imageConfig,
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

  router.get("/jobs/:jobId", asyncRoute(async (req, res) => {
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
        generation: scene.data().generation,
        regenerating: scene.data().status === "regenerating",
        pendingGeneration: scene.data().regenerationTarget ?? null,
      })),
    });
  }));
  return router;
}
