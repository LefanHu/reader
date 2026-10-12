import { createHash, randomUUID } from "node:crypto";
import express from "express";
import { FieldValue, Timestamp, type DocumentReference, type Firestore, type Transaction } from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import sharp from "sharp";
import { resolveWorldSnapshot } from "./openai.js";
import type {
  analyzeNarrative, composeImagePrompt, moderateImage, moderateText,
} from "./openai.js";
import {
  MAX_REFERENCE_BYTES, validateReferenceImage,
  type GeneratedImage, type ImageGenerationProvider, type ImageMimeType, type ReferenceImage,
} from "./image-generation.js";
import { requireImageGenerationConfig, requireIllustrationProfile } from "./illustration-configuration.js";
import { asyncRoute, HttpError, routeParam } from "./http.js";
import { bookReference, readBookFence } from "./fences.js";
import { CancelledClaim, reserveCredit, settleCredit } from "./illustration-credits.js";
import type {
  ChapterInput, ImageGenerationConfig, SceneGenerationSpec, WorldReference, WorldRevision, WorldSnapshot,
} from "./types.js";

/** Worker dispatch includes credential/config validation before any credit reservation. */
export interface IllustrationWorkerDependencies {
  db: Firestore;
  storage: Storage;
  bucket: string;
  assetRetentionMilliseconds: number;
  analyzeNarrative: typeof analyzeNarrative;
  composeImagePrompt: typeof composeImagePrompt;
  moderateText: typeof moderateText;
  moderateImage: typeof moderateImage;
  imageGenerationProvider: ImageGenerationProvider & {
    validateCredentials(config: ImageGenerationConfig): void | Promise<void>;
  };
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
    cssSelector: string;
    fallbackProgression: number;
  };
  altText: string;
  caption: string;
  generationSpec: SceneGenerationSpec;
  entityIds: string[];
};
/** Only paraphrased facts/recipes survive prose deletion, allowing a new lease to resume. */
type JobPlan = { density: number; scenes: ScenePlan[] };

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
    analyzeNarrative, composeImagePrompt, moderateText, moderateImage,
    imageGenerationProvider,
  } = dependencies;
  const router = express.Router();

  async function liveClaim(transaction: Transaction, claim: Claim) {
    const [record, fence] = await Promise.all([
      transaction.get(claim.reference),
      readBookFence(transaction, db, "books", claim.uid, claim.bookId),
    ]);
    const data = record.data();
    if (!data || data.schemaVersion !== 2 || fence.book.data()?.schemaVersion !== 2 ||
      data.deleted || data[claim.tokenField] !== claim.token || !fence.live) throw new CancelledClaim();
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

  async function loadReferenceImages(entries: WorldSnapshot[]): Promise<ReferenceImage[]> {
    const objects = [...new Set(entries.map((entry) => entry.referenceObject)
      .filter((value): value is string => Boolean(value)))].slice(-2);
    const images: ReferenceImage[] = [];
    for (const object of objects) {
      const stream = storage.bucket(bucketName).file(object).createReadStream();
      try {
        const chunks: Buffer[] = [];
        let length = 0;
        // Bound the stream before concat: download() would allocate an entire
        // oversized cloud object before a post-download check could reject it.
        for await (const chunk of stream) {
          const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
          length += bytes.length;
          if (length > MAX_REFERENCE_BYTES) throw new Error("Reference image is too large");
          chunks.push(bytes);
        }
        images.push(await validateReferenceImage(chunks.length === 1 ? chunks[0]! : Buffer.concat(chunks, length)));
      } catch {
        // Missing, oversized or corrupt artwork never removes text continuity.
      } finally { stream.destroy(); }
    }
    return images;
  }

  async function loadWorldSnapshot(uid: string, bookId: string, chapterOrdinal: number, paragraphOrdinal: number) {
    const [revisionDocuments, referenceDocuments] = await Promise.all([
      db.collection("worldRevisions").where("uid", "==", uid).where("bookId", "==", bookId).get(),
      db.collection("worldReferences").where("uid", "==", uid).where("bookId", "==", bookId).get(),
    ]);
    const revisions = revisionDocuments.docs.filter((document) => document.data().schemaVersion === 2)
      .map((document) => document.data() as WorldRevision);
    const snapshot = resolveWorldSnapshot(revisions, chapterOrdinal, paragraphOrdinal);
    const references = referenceDocuments.docs.filter((document) => document.data().schemaVersion === 2)
      .map((document) => document.data() as WorldReference)
      .filter((reference) => reference.chapterOrdinal < chapterOrdinal ||
        (reference.chapterOrdinal === chapterOrdinal && reference.paragraphOrdinal <= paragraphOrdinal))
      .sort((left, right) => left.chapterOrdinal - right.chapterOrdinal || left.paragraphOrdinal - right.paragraphOrdinal);
    for (const reference of references) for (const entityId of reference.entityIds) {
      const entity = snapshot.find((candidate) => candidate.entityId === entityId);
      if (entity) entity.referenceObject = reference.referenceObject;
    }
    return { revisions, snapshot };
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
      if (!data || data.schemaVersion !== 2 || data.deleted) return null;
      if (["complete", "failed", "insufficient_credits"].includes(data.status)) return null;
      if ((data.leaseUntil?.toMillis() ?? 0) > Date.now()) return null;
      const fence = await readBookFence(transaction, db, "books", data.uid, data.bookId);
      if (!fence.live || fence.book.data()?.schemaVersion !== 2) return null;
      transaction.update(jobRef, {
        status: "analyzing", claimToken: token,
        leaseUntil: Timestamp.fromMillis(Date.now() + 10 * 60 * 1000), updatedAt: FieldValue.serverTimestamp(),
      });
      return data;
    });
    if (!jobData) { res.status(204).end(); return; }
    const uid = jobData.uid as string, bookId = jobData.bookId as string, chapterOrdinal = jobData.chapterOrdinal as number;
    const claim: Claim = { reference: jobRef, uid, bookId, token, tokenField: "claimToken", leaseField: "leaseUntil" };
    let failureCategory = "worker_failed";
    try {
      const profile = requireIllustrationProfile(jobData.profile);
      const imageConfig = requireImageGenerationConfig(jobData.imageConfig);
      let plan = jobData.plan as JobPlan | undefined;
      const sceneText = new Map<string, string>();
      if (!plan) {
        const inputSnapshot = await inputRef.get();
        if (!inputSnapshot.exists || inputSnapshot.data()?.schemaVersion !== 2) {
          failureCategory = "missing_input"; throw new HttpError(404, "Job input not found.");
        }
        const input = inputSnapshot.data()?.input as ChapterInput;
        if (input.profileRevision !== profile.revision || input.analysisVersion !== profile.analysisVersion) {
          throw new Error("Operation snapshot is incomplete");
        }
        const siblingJobs = await db.collection("illustrationJobs").where("uid", "==", uid).where("bookId", "==", bookId).get();
        if (siblingJobs.docs.some((document) => Number(document.data().chapterOrdinal) < chapterOrdinal &&
          !["complete", "failed", "insufficient_credits"].includes(document.data().status))) {
          await db.runTransaction(async (transaction) => {
            await liveClaim(transaction, claim);
            transaction.update(jobRef, { status: "queued", claimToken: FieldValue.delete(), leaseUntil: FieldValue.delete(), updatedAt: FieldValue.serverTimestamp() });
          });
          throw new HttpError(409, "An earlier chapter is still being analyzed.");
        }
        const priorWorld = await loadWorldSnapshot(uid, bookId, chapterOrdinal, -1);
        const analysis = await analyzeNarrative(input, priorWorld.snapshot);
        const entityIds = new Map(priorWorld.snapshot.map((entity) => [entity.entityId, entity.entityId]));
        for (const delta of analysis.entityDeltas) if (!entityIds.has(delta.entityRef)) {
          entityIds.set(delta.entityRef, createHash("sha256").update(`${bookId}:${jobId}:${delta.entityRef}`).digest("hex").slice(0, 40));
        }
        const revisions: WorldRevision[] = analysis.entityDeltas.map((delta) => {
          const paragraph = input.paragraphs.find((item) => item.id === delta.anchorParagraphId)!;
          return { schemaVersion: 2, uid, bookId, entityId: entityIds.get(delta.entityRef)!, kind: delta.kind,
            chapterOrdinal, paragraphOrdinal: paragraph.ordinal, paragraphId: paragraph.id,
            name: delta.name, aliases: delta.aliases, summary: delta.summary,
            visualDescription: delta.visualDescription, stateFacts: delta.stateFacts, analysisVersion: input.analysisVersion };
        });
        const allRevisions = [...priorWorld.revisions, ...revisions];
        plan = { density: profile.density, scenes: analysis.scenes.map((candidate) => {
          const id = createHash("sha256").update(`${jobId}:${candidate.startParagraphId}:${candidate.endParagraphId}`).digest("hex").slice(0, 40);
          const start = input.paragraphs.findIndex((paragraph) => paragraph.id === candidate.startParagraphId);
          const end = input.paragraphs.findIndex((paragraph) => paragraph.id === candidate.endParagraphId);
          sceneText.set(id, input.paragraphs.slice(start, end + 1).map((paragraph) => paragraph.text).join("\n"));
          const entityIdsForScene = [...new Set(candidate.entityRefs.map((reference) => entityIds.get(reference)).filter((value): value is string => Boolean(value)))];
          const world = resolveWorldSnapshot(allRevisions, chapterOrdinal, start).filter((entity) => entityIdsForScene.includes(entity.entityId));
          for (const entity of world) {
            const object = priorWorld.snapshot.find((known) => known.entityId === entity.entityId)?.referenceObject;
            if (object) entity.referenceObject = object;
          }
          const paragraph = input.paragraphs[end]!;
          return { id, paragraphOrdinal: end,
            anchor: { href: input.href, spineOrdinal: chapterOrdinal, paragraphId: paragraph.id,
              cssSelector: paragraph.cssSelector, fallbackProgression: paragraph.progression },
            altText: candidate.altText, caption: candidate.caption, entityIds: entityIdsForScene,
            generationSpec: { imageConfig, style: profile.style, facts: candidate.facts, world } };
        }) };
        await db.runTransaction(async (transaction) => {
          await liveClaim(transaction, claim);
          for (const revision of revisions) {
            const id = createHash("sha256").update(`${jobId}:${revision.entityId}:${revision.paragraphId}`).digest("hex");
            transaction.set(db.collection("worldRevisions").doc(id), { ...revision, createdAt: FieldValue.serverTimestamp() });
          }
          transaction.update(bookReference(db, "books", uid, bookId), {
            worldVersion: FieldValue.increment(revisions.length), visualBibleVersion: FieldValue.increment(revisions.length), updatedAt: FieldValue.serverTimestamp(),
          });
          transaction.update(jobRef, { plan, updatedAt: FieldValue.serverTimestamp() });
          transaction.delete(inputRef);
        });
      }
      const generatedReferences: WorldReference[] = [];
      let committed = 0, finalStatus = "complete";
      for (const candidate of plan.scenes) {
        if (committed >= plan.density) break;
        const sceneRef = db.collection("illustrationScenes").doc(candidate.id);
        const existing = await db.runTransaction(async (transaction) => {
          await liveClaim(transaction, claim);
          return transaction.get(sceneRef);
        });
        if (existing.exists) {
          if (existing.data()?.schemaVersion === 2 && !existing.data()?.deleted &&
              ["ready_locked", "unlocked", "regenerating"].includes(existing.data()?.status)) {
            committed++;
            if (candidate.entityIds.length) generatedReferences.push({ schemaVersion: 2, entityIds: candidate.entityIds,
              chapterOrdinal, paragraphOrdinal: candidate.paragraphOrdinal, referenceObject: existing.data()!.imageObject });
          }
          continue;
        }
        const world = candidate.generationSpec.world.map((entity) => ({ ...entity }));
        for (const entity of world) {
          const reference = generatedReferences.filter((item) => item.paragraphOrdinal <= candidate.paragraphOrdinal && item.entityIds.includes(entity.entityId))
            .sort((left, right) => right.paragraphOrdinal - left.paragraphOrdinal)[0];
          if (reference) entity.referenceObject = reference.referenceObject;
        }
        const spec = { ...candidate.generationSpec, imageConfig: requireImageGenerationConfig(candidate.generationSpec.imageConfig), world };
        const prompt = composeImagePrompt({ ...spec, sceneText: sceneText.get(candidate.id) ?? spec.facts.join("; ") });
        if (await moderateText(prompt)) { console.info(JSON.stringify({ category: "safety", outcome: "text_blocked" })); continue; }
        await imageGenerationProvider.validateCredentials(spec.imageConfig);
        if (!(await reserveClaimCredit(claim, candidate.id))) { finalStatus = "insufficient_credits"; break; }
        const prefix = `users/${uid}/books/${bookId}/scenes/${candidate.id}.claim-${token}`;
        let assets: PublishedAssets | undefined;
        let published = false;
        try {
          const image = await imageGenerationProvider.generate(spec.imageConfig, prompt, await loadReferenceImages(world));
          if (await moderateImage(image.bytes, image.mimeType)) throw new SafetyError("image blocked");
          assets = publishedAssets(prefix, image, spec.imageConfig);
          const publication = assets;
          await db.runTransaction(async (transaction) => { await liveClaim(transaction, claim); });
          await saveImages(image, publication);
          await db.runTransaction(async (transaction) => {
            await liveClaim(transaction, claim);
            const scene = await transaction.get(sceneRef);
            if (scene.exists) throw new CancelledClaim();
            await settleCredit(transaction, db, claim, candidate.id, true);
            transaction.create(sceneRef, { schemaVersion: 2, uid, bookId, jobId, chapterOrdinal,
              paragraphOrdinal: candidate.paragraphOrdinal, status: "ready_locked",
              anchor: candidate.anchor, altText: candidate.altText, caption: candidate.caption,
              // Native MIME/object ownership and recipe commit together with the credit.
              generationSpec: spec, entityIds: candidate.entityIds, ...publication, generationVersion: 1,
              assetExpiresAt: Timestamp.fromMillis(Date.now() + assetRetentionMilliseconds),
              createdAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp() });
            if (candidate.entityIds.length) transaction.set(db.collection("worldReferences").doc(candidate.id), {
              schemaVersion: 2, uid, bookId, entityIds: candidate.entityIds, chapterOrdinal, paragraphOrdinal: candidate.paragraphOrdinal,
              referenceObject: publication.imageObject, createdAt: FieldValue.serverTimestamp(),
            });
          });
          published = true;
          committed++;
          if (candidate.entityIds.length) generatedReferences.push({ schemaVersion: 2, entityIds: candidate.entityIds,
            chapterOrdinal, paragraphOrdinal: candidate.paragraphOrdinal, referenceObject: publication.imageObject });
        } catch (error) {
          if (error instanceof CancelledClaim) throw error;
          await db.runTransaction(async (transaction) => {
            await liveClaim(transaction, claim);
            await settleCredit(transaction, db, claim, candidate.id, false);
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
      if (!value || value.schemaVersion !== 2) return null;
      if (value.deleted || Number(value.generationVersion ?? 1) >= targetGeneration) return null;
      const fence = await readBookFence(transaction, db, "books", value.uid, value.bookId);
      if (!fence.live || fence.book.data()?.schemaVersion !== 2) return null;
      if (value.regenerationTarget !== targetGeneration || value.status !== "regenerating" ||
        value.regenerationTaskId !== req.body.taskId) return null;
      if ((value.regenerationLeaseUntil?.toMillis() ?? 0) > Date.now()) throw new HttpError(409, "Regeneration is already running.");
      transaction.update(reference, { regenerationToken: token,
        regenerationLeaseUntil: Timestamp.fromMillis(Date.now() + 10 * 60 * 1000), updatedAt: FieldValue.serverTimestamp() });
      return value;
    });
    if (!data) { res.status(204).end(); return; }
    const claim: Claim = { reference, uid: data.uid, bookId: data.bookId, token, tokenField: "regenerationToken", leaseField: "regenerationLeaseUntil" };
    const spec = data.regenerationGenerationSpec as SceneGenerationSpec;
    const operationId = `${reference.id}:generation:${targetGeneration}`;
    // Refresh/paid intent is persisted by the API; task payload cannot change accounting.
    const refresh = data.regenerationRefresh === true;
    const prefix = `users/${data.uid}/books/${data.bookId}/scenes/${reference.id}.v${targetGeneration}.claim-${token}`;
    let assets: PublishedAssets | undefined;
    let reserved = false, published = false;
    try {
      const config = requireImageGenerationConfig(spec?.imageConfig);
      await imageGenerationProvider.validateCredentials(config);
      if (!refresh) {
        reserved = await reserveClaimCredit(claim, operationId);
        if (!reserved) throw new HttpError(402, "Insufficient credits.");
      }
      const world = spec.world;
      const prompt = composeImagePrompt({ style: spec.style, sceneText: spec.facts.join("; "), facts: spec.facts, world });
      if (await moderateText(prompt)) throw new SafetyError("text blocked");
      const image = await imageGenerationProvider.generate(config, prompt, await loadReferenceImages(world));
      if (await moderateImage(image.bytes, image.mimeType)) throw new SafetyError("image blocked");
      assets = publishedAssets(prefix, image, config);
      const publication = assets;
      await db.runTransaction(async (transaction) => { await liveClaim(transaction, claim); });
      await saveImages(image, publication);
      await db.runTransaction(async (transaction) => {
        await liveClaim(transaction, claim);
        const worldReference = db.collection("worldReferences").doc(reference.id);
        const existingReference = await transaction.get(worldReference);
        if (!refresh) await settleCredit(transaction, db, claim, operationId, true);
        transaction.update(reference, { status: "ready_locked", ...publication,
          generationSpec: spec, generationVersion: targetGeneration,
          assetExpiresAt: Timestamp.fromMillis(Date.now() + assetRetentionMilliseconds),
          regenerationGenerationSpec: FieldValue.delete(), regenerationPreviousStatus: FieldValue.delete(),
          regenerationTarget: FieldValue.delete(), regenerationRefresh: FieldValue.delete(), regenerationTaskId: FieldValue.delete(),
          regenerationToken: FieldValue.delete(), regenerationLeaseUntil: FieldValue.delete(), failureCategory: FieldValue.delete(), updatedAt: FieldValue.serverTimestamp() });
        if (existingReference.exists) transaction.update(worldReference, { referenceObject: publication.imageObject, updatedAt: FieldValue.serverTimestamp() });
        else if (Array.isArray(data.entityIds) && data.entityIds.length) transaction.set(worldReference, {
          schemaVersion: 2, uid: data.uid, bookId: data.bookId, entityIds: data.entityIds,
          chapterOrdinal: data.chapterOrdinal, paragraphOrdinal: data.paragraphOrdinal,
          referenceObject: publication.imageObject, createdAt: FieldValue.serverTimestamp(),
        });
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
