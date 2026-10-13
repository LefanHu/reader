import { createHash, randomUUID } from "node:crypto";
import express from "express";
import { FieldValue, Timestamp, type DocumentReference, type Firestore, type Transaction } from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import sharp from "sharp";
import type { composeImagePrompt, moderateImage, moderateText } from "./openai.js";
import type { selectScenes } from "./scene-selection.js";
import type { GeneratedImage, ImageGenerationProvider, ImageMimeType } from "./image-generation.js";
import { requireImageGenerationConfig, requireIllustrationProfile } from "./illustration-configuration.js";
import { asyncRoute, HttpError, routeParam } from "./http.js";
import { assertLeaseFree, readBookFence, WORKER_LEASE_MS } from "./fences.js";
import { CancelledClaim, reserveCredit, settleCredit } from "./illustration-credits.js";
import type { ChapterInput, IllustrationContext, ImageGenerationConfig, SceneGenerationSpec } from "./types.js";
import type { AnalysisPosition } from "./book-analysis-types.js";
import { loadIllustrationContext, type IllustrationContextResolver } from "./book-analysis-context.js";

/** Worker dispatch includes credential/config validation before any credit reservation. */
export interface IllustrationWorkerDependencies {
  db: Firestore;
  storage: Storage;
  bucket: string;
  assetRetentionMilliseconds: number;
  selectScenes: typeof selectScenes;
  composeImagePrompt: typeof composeImagePrompt;
  moderateText: typeof moderateText;
  moderateImage: typeof moderateImage;
  imageGenerationProvider: ImageGenerationProvider & {
    validateCredentials(config: ImageGenerationConfig): void | Promise<void>;
  };
  /** Test seam; production loads the latest finalized preprocessing generation once per job. */
  loadContext?: typeof loadIllustrationContext;
}

class SafetyError extends Error {}

type Claim = {
  reference: DocumentReference;
  uid: string;
  bookId: string;
  token: string;
  tokenField: "claimToken" | "regenerationToken";
  leaseField: "leaseUntil" | "regenerationLeaseUntil";
};
type ScenePlan = {
  id: string;
  paragraphOrdinal: number;
  anchor: {
    href: string;
    spineOrdinal: number;
    paragraphId: string;
    fallbackProgression: number;
  };
  altText: string;
  caption: string;
  /** Selected paragraphs, so a new lease can resume after the chapter input is deleted. */
  sceneText: string;
  /** Complete source range and admitted temporal context (absent for pre-preprocessing plans). */
  sceneStart?: AnalysisPosition;
  sceneEnd?: AnalysisPosition;
  context?: IllustrationContext;
};
type JobPlan = { scenes: ScenePlan[] };

/** Each original is immutable; FLUX's preview owns that same object, not a transformed copy. */
type PublishedAssets = {
  imageObject: string;
  thumbnailObject: string;
  /** Verified native original MIME, published with a matching object extension. */
  imageMimeType: ImageMimeType;
  /** Native MIME when aliased; otherwise the derived WebP preview MIME. */
  thumbnailMimeType: ImageMimeType;
  /** True means both names own one original; saves/signatures/deletes de-duplicate it. */
  thumbnailUsesOriginal: boolean;
};
function publishedAssets(prefix: string, image: GeneratedImage, config: ImageGenerationConfig): PublishedAssets {
  const extension = { "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp" }[image.mimeType];
  const imageObject = `${prefix}.${extension}`;
  const thumbnailUsesOriginal = config.providerId === "flux";
  return { imageObject, thumbnailObject: thumbnailUsesOriginal ? imageObject : `${prefix}.thumb.webp`,
    imageMimeType: image.mimeType, thumbnailMimeType: thumbnailUsesOriginal ? image.mimeType : "image/webp",
    thumbnailUsesOriginal };
}

/** Illustration-specific claims fence every history, accounting and publication transaction. */
export function illustrationWorkerRouter(dependencies: IllustrationWorkerDependencies) {
  const {
    db, storage, bucket: bucketName, assetRetentionMilliseconds,
    selectScenes, composeImagePrompt, moderateText, moderateImage,
    imageGenerationProvider,
  } = dependencies;
  const loadContext = dependencies.loadContext ?? loadIllustrationContext;
  const router = express.Router();

  async function liveClaim(transaction: Transaction, claim: Claim) {
    const [record, fence] = await Promise.all([
      transaction.get(claim.reference),
      readBookFence(transaction, db, "books", claim.uid, claim.bookId),
    ]);
    const data = record.data();
    if (!data || data.deleted || data[claim.tokenField] !== claim.token || !fence.live) throw new CancelledClaim();
    // A still-owned but expired lease must be retried, not acknowledged and stranded.
    if ((data[claim.leaseField]?.toMillis() ?? 0) <= Date.now()) {
      throw new HttpError(409, "Illustration claim expired.");
    }
    return data;
  }

  /** Fences the claim and reserves its credit in one transaction. */
  async function reserveClaimCredit(claim: Claim, operationId: string) {
    return db.runTransaction(async (transaction) => {
      await liveClaim(transaction, claim);
      return reserveCredit(transaction, db, claim, operationId);
    });
  }

  async function deleteObjects(...objects: Array<string | undefined>) {
    await Promise.all([...new Set(objects.filter((object): object is string => Boolean(object)))]
      .map((object) => storage.bucket(bucketName).file(object).delete({ ignoreNotFound: true })));
  }

  async function saveImages(image: GeneratedImage, assets: PublishedAssets) {
    const options = { resumable: false, preconditionOpts: { ifGenerationMatch: 0 } };
    if (assets.thumbnailUsesOriginal) {
      // Preserve FLUX Content Credentials in both full-size art and preview.
      await storage.bucket(bucketName).file(assets.imageObject).save(image.bytes, {
        ...options, contentType: assets.imageMimeType,
      });
      return;
    }
    const thumbnail = await sharp(image.bytes).rotate().resize({ width: 640, withoutEnlargement: true })
      .webp({ quality: 78 }).toBuffer();
    // Wait for both saves even when one fails: cleanup must not race a late sibling save.
    const results = await Promise.allSettled([
      storage.bucket(bucketName).file(assets.imageObject).save(image.bytes, { ...options, contentType: assets.imageMimeType }),
      storage.bucket(bucketName).file(assets.thumbnailObject).save(thumbnail, { ...options, contentType: assets.thumbnailMimeType }),
    ]);
    for (const result of results) if (result.status === "rejected") throw result.reason;
  }

  router.post("/jobs/:jobId", asyncRoute(async (req, res) => {
    const jobId = routeParam(req, "jobId");
    const jobRef = db.collection("illustrationJobs").doc(jobId);
    const inputRef = db.collection("illustrationJobInputs").doc(jobId);
    const token = randomUUID();
    const jobData = await db.runTransaction(async (transaction) => {
      const job = await transaction.get(jobRef);
      const data = job.data();
      if (!data || data.deleted) return null;
      if (["complete", "failed", "insufficient_credits"].includes(data.status)) return null;
      const fence = await readBookFence(transaction, db, "books", data.uid, data.bookId);
      if (!fence.live) return null;
      // Deleted books end above; only a still-wanted job waits out a live lease.
      assertLeaseFree(data.leaseUntil, "Illustration job is already running.");
      transaction.update(jobRef, {
        status: "analyzing", claimToken: token,
        leaseUntil: Timestamp.fromMillis(Date.now() + WORKER_LEASE_MS), updatedAt: FieldValue.serverTimestamp(),
      });
      return data;
    });
    if (!jobData) { res.status(204).end(); return; }
    const uid = jobData.uid as string, bookId = jobData.bookId as string, chapterOrdinal = jobData.chapterOrdinal as number;
    const claim: Claim = { reference: jobRef, uid, bookId, token, tokenField: "claimToken", leaseField: "leaseUntil" };
    let failureCategory = "worker_failed";
    try {
      const profile = requireIllustrationProfile(jobData.profile);
      let plan = jobData.plan as JobPlan | undefined;
      if (!plan) {
        const inputSnapshot = await inputRef.get();
        if (!inputSnapshot.exists) {
          failureCategory = "missing_input"; throw new HttpError(404, "Job input not found.");
        }
        const input = inputSnapshot.data()?.input as ChapterInput;
        if (input.profileRevision !== profile.revision) {
          throw new Error("Operation snapshot is incomplete");
        }
        const selected = await selectScenes(input, profile.density);
        // Every scene of this job reads the same finalized generation.
        let resolveScene: IllustrationContextResolver | null | undefined;
        const scenes: ScenePlan[] = [];
        for (const scene of selected) {
          const id = createHash("sha256").update(`${jobId}:${scene.startParagraphId}:${scene.endParagraphId}`).digest("hex").slice(0, 40);
          const start = input.paragraphs.findIndex((paragraph) => paragraph.id === scene.startParagraphId);
          const end = input.paragraphs.findIndex((paragraph) => paragraph.id === scene.endParagraphId);
          const paragraph = input.paragraphs[end]!;
          const opening = input.paragraphs[start]!.text.trim();
          const excerpt = opening.length > 120 ? `${opening.slice(0, 117)}…` : opening;
          // Paragraph IDs are normalized block IDs, so source positions map from unchanged selected text.
          const sceneStart: AnalysisPosition = { sectionId: input.href, blockId: input.paragraphs[start]!.id, offset: 0 };
          const sceneEnd: AnalysisPosition = { sectionId: input.href, blockId: paragraph.id, offset: paragraph.text.length };
          // Snapshotted once here so retries, regeneration and refresh reuse the same admitted truth.
          if (resolveScene === undefined) resolveScene = await loadContext(db, { uid, bookId });
          const context = resolveScene?.({ anchor: sceneEnd, sceneStart, sceneEnd }) ?? null;
          scenes.push({ id, paragraphOrdinal: end,
            anchor: { href: input.href, spineOrdinal: chapterOrdinal, paragraphId: paragraph.id,
              fallbackProgression: paragraph.progression },
            altText: `Illustration of the passage beginning “${excerpt}”`, caption: "",
            sceneText: input.paragraphs.slice(start, end + 1).map((item) => item.text).join("\n\n").slice(0, 6000),
            sceneStart, sceneEnd, ...(context ? { context } : {}) });
        }
        plan = { scenes };
        const planned = plan;
        await db.runTransaction(async (transaction) => {
          await liveClaim(transaction, claim);
          transaction.update(jobRef, { plan: planned, updatedAt: FieldValue.serverTimestamp() });
          transaction.delete(inputRef);
        });
      }
      let finalStatus = "complete";
      for (const candidate of plan.scenes) {
        const sceneRef = db.collection("illustrationScenes").doc(candidate.id);
        const existing = await db.runTransaction(async (transaction) => {
          await liveClaim(transaction, claim);
          return transaction.get(sceneRef);
        });
        // Published, failed or deleted scenes are final; only our own "generating" record resumes.
        if (existing.exists && existing.data()?.status !== "generating") continue;
        const spec: SceneGenerationSpec = {
          imageConfig: requireImageGenerationConfig(jobData.imageConfig),
          style: profile.style, sceneText: candidate.sceneText,
          ...(candidate.sceneStart ? { sceneStart: candidate.sceneStart } : {}),
          ...(candidate.sceneEnd ? { sceneEnd: candidate.sceneEnd } : {}),
          ...(candidate.context ? { context: candidate.context } : {}),
        };
        const prompt = composeImagePrompt(spec);
        // No scene record exists yet, so a blocked prompt never shows a placeholder.
        if (await moderateText(prompt)) { console.info(JSON.stringify({ category: "safety", outcome: "text_blocked" })); continue; }
        await imageGenerationProvider.validateCredentials(spec.imageConfig);
        // The generating record is created with the credit so a placeholder only shows for paid, confirmed work.
        const confirmation = await db.runTransaction(async (transaction) => {
          await liveClaim(transaction, claim);
          const scene = await transaction.get(sceneRef);
          if (scene.exists && scene.data()?.status !== "generating") return "skip" as const;
          if (!(await reserveCredit(transaction, db, claim, candidate.id))) return "insufficient" as const;
          if (!scene.exists) transaction.create(sceneRef, { uid, bookId, jobId, chapterOrdinal,
            paragraphOrdinal: candidate.paragraphOrdinal, status: "generating",
            anchor: candidate.anchor, altText: candidate.altText, caption: candidate.caption,
            generation: 0, createdAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp() });
          return "go" as const;
        });
        if (confirmation === "insufficient") { finalStatus = "insufficient_credits"; break; }
        if (confirmation === "skip") continue;
        const prefix = `users/${uid}/books/${bookId}/scenes/${candidate.id}.claim-${token}`;
        let assets: PublishedAssets | undefined;
        let published = false;
        try {
          const image = await imageGenerationProvider.generate(spec.imageConfig, prompt);
          if (await moderateImage(image.bytes, image.mimeType)) throw new SafetyError("image blocked");
          assets = publishedAssets(prefix, image, spec.imageConfig);
          const publication = assets;
          await db.runTransaction(async (transaction) => { await liveClaim(transaction, claim); });
          await saveImages(image, publication);
          await db.runTransaction(async (transaction) => {
            await liveClaim(transaction, claim);
            const scene = await transaction.get(sceneRef);
            if (scene.data()?.status !== "generating") throw new CancelledClaim();
            await settleCredit(transaction, db, claim, candidate.id, true);
            // Native MIME/object ownership and recipe commit together with the credit.
            transaction.update(sceneRef, { status: "ready_locked", ...publication,
              generationSpec: spec, generation: 1,
              assetExpiresAt: Timestamp.fromMillis(Date.now() + assetRetentionMilliseconds),
              updatedAt: FieldValue.serverTimestamp() });
          });
          published = true;
        } catch (error) {
          if (error instanceof CancelledClaim) throw error;
          await db.runTransaction(async (transaction) => {
            await liveClaim(transaction, claim);
            const scene = await transaction.get(sceneRef);
            await settleCredit(transaction, db, claim, candidate.id, false);
            if (scene.data()?.status === "generating") transaction.update(sceneRef, { status: "failed",
              failureCategory: error instanceof SafetyError ? "safety_blocked" : "generation_failed",
              updatedAt: FieldValue.serverTimestamp() });
          });
          console.info(JSON.stringify({ category: "candidate", outcome: error instanceof SafetyError ? "image_blocked" : "generation_failed" }));
        } finally { if (!published && assets) await deleteObjects(assets.imageObject, assets.thumbnailObject); }
      }
      await db.runTransaction(async (transaction) => {
        await liveClaim(transaction, claim);
        transaction.update(jobRef, { status: finalStatus, plan: FieldValue.delete(), claimToken: FieldValue.delete(), leaseUntil: FieldValue.delete(), updatedAt: FieldValue.serverTimestamp() });
      });
      res.status(204).end();
    } catch (error) {
      if (error instanceof CancelledClaim) { res.status(204).end(); return; }
      if (error instanceof HttpError && error.status === 409) throw error;
      await db.runTransaction(async (transaction) => {
        try { await liveClaim(transaction, claim); } catch (failure) { if (failure instanceof CancelledClaim) return; throw failure; }
        transaction.update(jobRef, { status: "failed", failureCategory, plan: FieldValue.delete(), claimToken: FieldValue.delete(), leaseUntil: FieldValue.delete(), updatedAt: FieldValue.serverTimestamp() });
        transaction.delete(inputRef);
      });
      throw error;
    }
  }));

  router.post("/scenes/:sceneId/regenerate", asyncRoute(async (req, res) => {
    const reference = db.collection("illustrationScenes").doc(routeParam(req, "sceneId"));
    const targetGeneration = Math.max(2, Number(req.body.targetGeneration) || 0);
    const token = randomUUID();
    const data = await db.runTransaction(async (transaction) => {
      const scene = await transaction.get(reference);
      const value = scene.data();
      if (!value) return null;
      if (value.deleted || (value.generation as number) >= targetGeneration) return null;
      const fence = await readBookFence(transaction, db, "books", value.uid, value.bookId);
      if (!fence.live) return null;
      if (value.regenerationTarget !== targetGeneration || value.status !== "regenerating" ||
        value.regenerationTaskId !== req.body.taskId) return null;
      assertLeaseFree(value.regenerationLeaseUntil, "Regeneration is already running.");
      transaction.update(reference, { regenerationToken: token,
        regenerationLeaseUntil: Timestamp.fromMillis(Date.now() + WORKER_LEASE_MS), updatedAt: FieldValue.serverTimestamp() });
      return value;
    });
    if (!data) { res.status(204).end(); return; }
    const claim: Claim = { reference, uid: data.uid, bookId: data.bookId, token, tokenField: "regenerationToken", leaseField: "regenerationLeaseUntil" };
    const spec = data.regenerationGenerationSpec as SceneGenerationSpec;
    const operationId = `${reference.id}:generation:${targetGeneration}`;
    // Refresh/paid intent is persisted by the API; task payload cannot change accounting.
    const refresh = data.regenerationRefresh === true;
    const prefix = `users/${data.uid}/books/${data.bookId}/scenes/${reference.id}.${targetGeneration}.claim-${token}`;
    let assets: PublishedAssets | undefined;
    let reserved = false, published = false;
    try {
      const config = requireImageGenerationConfig(spec?.imageConfig);
      await imageGenerationProvider.validateCredentials(config);
      if (!refresh) {
        reserved = await reserveClaimCredit(claim, operationId);
        if (!reserved) throw new HttpError(402, "Insufficient credits.");
      }
      if (typeof spec?.sceneText !== "string") throw new Error("Scene recipe has no selected passage");
      const prompt = composeImagePrompt({ style: spec.style, sceneText: spec.sceneText, ...(spec.context ? { context: spec.context } : {}) });
      if (await moderateText(prompt)) throw new SafetyError("text blocked");
      const image = await imageGenerationProvider.generate(config, prompt);
      if (await moderateImage(image.bytes, image.mimeType)) throw new SafetyError("image blocked");
      assets = publishedAssets(prefix, image, config);
      const publication = assets;
      await db.runTransaction(async (transaction) => { await liveClaim(transaction, claim); });
      await saveImages(image, publication);
      await db.runTransaction(async (transaction) => {
        await liveClaim(transaction, claim);
        if (!refresh) await settleCredit(transaction, db, claim, operationId, true);
        transaction.update(reference, { status: "ready_locked", ...publication,
          generationSpec: spec, generation: targetGeneration,
          assetExpiresAt: Timestamp.fromMillis(Date.now() + assetRetentionMilliseconds),
          regenerationGenerationSpec: FieldValue.delete(), regenerationPreviousStatus: FieldValue.delete(),
          regenerationTarget: FieldValue.delete(), regenerationRefresh: FieldValue.delete(), regenerationTaskId: FieldValue.delete(),
          regenerationToken: FieldValue.delete(), regenerationLeaseUntil: FieldValue.delete(), failureCategory: FieldValue.delete(), updatedAt: FieldValue.serverTimestamp() });
      });
      published = true;
      await deleteObjects(data.imageObject, data.thumbnailObject);
      res.status(204).end();
    } catch (error) {
      if (!published) await db.runTransaction(async (transaction) => {
        try { await liveClaim(transaction, claim); } catch (failure) { if (failure instanceof CancelledClaim) return; throw failure; }
        if (reserved) await settleCredit(transaction, db, claim, operationId, false);
        // The old committed recipe/assets remain untouched on failure.
        transaction.update(reference, { status: data.regenerationPreviousStatus === "unlocked" ? "unlocked" : "ready_locked",
          regenerationGenerationSpec: FieldValue.delete(), regenerationPreviousStatus: FieldValue.delete(),
          regenerationTarget: FieldValue.delete(), regenerationRefresh: FieldValue.delete(),
          regenerationTaskId: FieldValue.delete(), regenerationToken: FieldValue.delete(), regenerationLeaseUntil: FieldValue.delete(),
          failureCategory: error instanceof HttpError && error.status === 402 ? "insufficient_credits" : error instanceof SafetyError ? "safety_blocked" : "regeneration_failed",
          updatedAt: FieldValue.serverTimestamp() });
      });
      if (error instanceof CancelledClaim) { res.status(204).end(); return; }
      throw error;
    } finally { if (!published && assets) await deleteObjects(assets.imageObject, assets.thumbnailObject); }
  }));
  return router;
}
