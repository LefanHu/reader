import { createHash, randomUUID } from "node:crypto";
import express from "express";
import { FieldValue, Timestamp, type DocumentReference, type Firestore, type Transaction } from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import sharp from "sharp";
import { resolveWorldSnapshot } from "./openai.js";
import type {
  analyzeNarrative, composeImagePrompt, moderateImage, moderateText,
  ImageGenerationProvider,
} from "./openai.js";
import { asyncRoute, HttpError, routeParam } from "./illustration-http.js";
import type {
  ChapterInput, SceneGenerationSpec, WorldReference, WorldRevision, WorldSnapshot,
} from "./types.js";

/** Runtime resources and the existing provider boundary, supplied by the composition root. */
export interface IllustrationWorkerDependencies {
  db: Firestore;
  storage: Storage;
  bucket: string;
  assetRetentionMilliseconds: number;
  analyzeNarrative: typeof analyzeNarrative;
  composeImagePrompt: typeof composeImagePrompt;
  moderateText: typeof moderateText;
  moderateImage: typeof moderateImage;
  imageGenerationProvider: ImageGenerationProvider;
}

class SafetyError extends Error {}
class CancelledClaim extends Error {}

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

/** Illustration-specific claims fence every history, accounting and publication transaction. */
export function illustrationWorkerRouter(dependencies: IllustrationWorkerDependencies) {
  const {
    db, storage, bucket: bucketName, assetRetentionMilliseconds,
    analyzeNarrative, composeImagePrompt, moderateText, moderateImage,
    imageGenerationProvider,
  } = dependencies;
  const router = express.Router();
  const bookReference = (uid: string, bookId: string) => db.collection("users").doc(uid).collection("books").doc(bookId);
  const accountReference = (uid: string) => db.collection("narrationAccountTombstones").doc(uid);

  async function liveClaim(transaction: Transaction, claim: Claim) {
    const [record, book, account] = await Promise.all([
      transaction.get(claim.reference),
      transaction.get(bookReference(claim.uid, claim.bookId)),
      transaction.get(accountReference(claim.uid)),
    ]);
    const data = record.data();
    if (!data || data.deleted || data[claim.tokenField] !== claim.token ||
      !book.exists || book.data()?.deleted || account.exists) throw new CancelledClaim();
    // A still-owned but expired lease must be retried, not acknowledged and stranded.
    if ((data[claim.leaseField]?.toMillis() ?? 0) <= Date.now()) {
      throw new HttpError(409, "Illustration claim expired.");
    }
    return data;
  }

  function creditReservation(uid: string, operationId: string) {
    return db.collection("creditReservations").doc(createHash("sha256").update(`${uid}:${operationId}`).digest("hex"));
  }

  async function reserveCredit(claim: Claim, operationId: string) {
    return db.runTransaction(async (transaction) => {
      await liveClaim(transaction, claim);
      const userRef = db.collection("users").doc(claim.uid);
      const reservationRef = creditReservation(claim.uid, operationId);
      const [user, reservation] = await Promise.all([transaction.get(userRef), transaction.get(reservationRef)]);
      if (!user.exists) throw new CancelledClaim();
      if (reservation.data()?.state === "committed") return false;
      const alreadyReserved = reservation.data()?.state === "reserved";
      const remaining = Number(user.data()?.creditsRemaining ?? 0);
      const reserved = Number(user.data()?.creditsReserved ?? 0);
      if (!alreadyReserved && remaining - reserved < 1) return false;
      if (!alreadyReserved) transaction.update(userRef, {
        creditsReserved: reserved + 1, updatedAt: FieldValue.serverTimestamp(),
      });
      // An expired lease transfers its existing reservation, never charging twice.
      transaction.set(reservationRef, {
        uid: claim.uid, bookId: claim.bookId, operationId, claimToken: claim.token,
        sceneId: operationId.split(":generation:")[0], state: "reserved",
        updatedAt: FieldValue.serverTimestamp(),
      });
      return true;
    });
  }

  /** Call only after liveClaim, before any writes, so settlement is atomic with publication. */
  async function settleCredit(transaction: Transaction, claim: Claim, operationId: string, commit: boolean) {
    const userRef = db.collection("users").doc(claim.uid);
    const reservationRef = creditReservation(claim.uid, operationId);
    const [user, reservation] = await Promise.all([transaction.get(userRef), transaction.get(reservationRef)]);
    if (!user.exists || reservation.data()?.state !== "reserved" || reservation.data()?.claimToken !== claim.token) {
      throw new CancelledClaim();
    }
    transaction.update(userRef, {
      ...(commit ? { creditsRemaining: FieldValue.increment(-1) } : {}),
      creditsReserved: FieldValue.increment(-1), updatedAt: FieldValue.serverTimestamp(),
    });
    transaction.update(reservationRef, {
      state: commit ? "committed" : "refunded", updatedAt: FieldValue.serverTimestamp(),
    });
  }

  async function loadReferenceImages(entries: WorldSnapshot[]): Promise<Buffer[]> {
    const objects = [...new Set(entries.map((entry) => entry.referenceObject)
      .filter((value): value is string => Boolean(value)))].slice(-2);
    const images: Buffer[] = [];
    for (const object of objects) {
      try { const [image] = await storage.bucket(bucketName).file(object).download(); images.push(image); }
      catch { /* Deleted/expired references do not remove text continuity. */ }
    }
    return images;
  }

  async function loadWorldSnapshot(uid: string, bookId: string, chapterOrdinal: number, paragraphOrdinal: number) {
    const [revisionDocuments, referenceDocuments] = await Promise.all([
      db.collection("worldRevisions").where("uid", "==", uid).where("bookId", "==", bookId).get(),
      db.collection("worldReferences").where("uid", "==", uid).where("bookId", "==", bookId).get(),
    ]);
    const revisions = revisionDocuments.docs.map((document) => document.data() as WorldRevision);
    const snapshot = resolveWorldSnapshot(revisions, chapterOrdinal, paragraphOrdinal);
    const references = referenceDocuments.docs.map((document) => document.data() as WorldReference)
      .filter((reference) => reference.chapterOrdinal < chapterOrdinal ||
        (reference.chapterOrdinal === chapterOrdinal && reference.paragraphOrdinal <= paragraphOrdinal))
      .sort((left, right) => left.chapterOrdinal - right.chapterOrdinal || left.paragraphOrdinal - right.paragraphOrdinal);
    for (const reference of references) for (const entityId of reference.entityIds) {
      const entity = snapshot.find((candidate) => candidate.entityId === entityId);
      if (entity) entity.referenceObject = reference.referenceObject;
    }
    return { revisions, snapshot };
  }

  async function deleteObjects(...objects: string[]) {
    await Promise.all(objects.filter(Boolean).map((object) => storage.bucket(bucketName).file(object).delete({ ignoreNotFound: true })));
  }

  async function saveImages(image: Buffer, imageObject: string, thumbnailObject: string) {
    const thumbnail = await sharp(image).resize({ width: 640, withoutEnlargement: true }).webp({ quality: 78 }).toBuffer();
    // Wait for both saves even when one fails: cleanup must not race a late sibling save.
    const results = await Promise.allSettled([
      storage.bucket(bucketName).file(imageObject).save(image, { contentType: "image/webp", resumable: false, preconditionOpts: { ifGenerationMatch: 0 } }),
      storage.bucket(bucketName).file(thumbnailObject).save(thumbnail, { contentType: "image/webp", resumable: false, preconditionOpts: { ifGenerationMatch: 0 } }),
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
      if (!data) throw new HttpError(404, "Job not found.");
      if (["complete", "failed", "insufficient_credits"].includes(data.status)) return null;
      if ((data.leaseUntil?.toMillis() ?? 0) > Date.now()) return null;
      const [book, account] = await Promise.all([
        transaction.get(bookReference(data.uid, data.bookId)), transaction.get(accountReference(data.uid)),
      ]);
      if (!book.exists || book.data()?.deleted || account.exists) return null;
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
      let plan = jobData.plan as JobPlan | undefined;
      const sceneText = new Map<string, string>();
      if (!plan) {
        const inputSnapshot = await inputRef.get();
        if (!inputSnapshot.exists) { failureCategory = "missing_input"; throw new HttpError(404, "Job input not found."); }
        const input = inputSnapshot.data()?.input as ChapterInput;
        const book = await bookReference(uid, bookId).get();
        const profile = book.data()?.profile as { style?: string } | undefined;
        if (!profile?.style) throw new Error("Book profile is incomplete");
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
          return { uid, bookId, entityId: entityIds.get(delta.entityRef)!, kind: delta.kind,
            chapterOrdinal, paragraphOrdinal: paragraph.ordinal, paragraphId: paragraph.id,
            name: delta.name, aliases: delta.aliases, summary: delta.summary,
            visualDescription: delta.visualDescription, stateFacts: delta.stateFacts, analysisVersion: input.analysisVersion };
        });
        const allRevisions = [...priorWorld.revisions, ...revisions];
        plan = { density: input.density, scenes: analysis.scenes.map((candidate) => {
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
            generationSpec: { style: profile.style!, facts: candidate.facts, world } };
        }) };
        await db.runTransaction(async (transaction) => {
          await liveClaim(transaction, claim);
          for (const revision of revisions) {
            const id = createHash("sha256").update(`${jobId}:${revision.entityId}:${revision.paragraphId}`).digest("hex");
            transaction.set(db.collection("worldRevisions").doc(id), { ...revision, createdAt: FieldValue.serverTimestamp() });
          }
          transaction.update(bookReference(uid, bookId), {
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
          if (["ready_locked", "unlocked", "regenerating"].includes(existing.data()?.status)) {
            committed++;
            if (candidate.entityIds.length) generatedReferences.push({ entityIds: candidate.entityIds,
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
        const spec = { ...candidate.generationSpec, world };
        const prompt = composeImagePrompt({ ...spec, sceneText: sceneText.get(candidate.id) ?? spec.facts.join("; ") });
        if (await moderateText(prompt)) { console.info(JSON.stringify({ category: "safety", outcome: "text_blocked" })); continue; }
        if (!(await reserveCredit(claim, candidate.id))) { finalStatus = "insufficient_credits"; break; }
        const prefix = `users/${uid}/books/${bookId}/scenes/${candidate.id}.claim-${token}`;
        const imageObject = `${prefix}.webp`, thumbnailObject = `${prefix}.thumb.webp`;
        let published = false;
        try {
          const image = await imageGenerationProvider.generate(prompt, await loadReferenceImages(world));
          if (await moderateImage(image)) throw new SafetyError("image blocked");
          await db.runTransaction(async (transaction) => { await liveClaim(transaction, claim); });
          await saveImages(image, imageObject, thumbnailObject);
          await db.runTransaction(async (transaction) => {
            await liveClaim(transaction, claim);
            const scene = await transaction.get(sceneRef);
            if (scene.exists) throw new CancelledClaim();
            await settleCredit(transaction, claim, candidate.id, true);
            transaction.create(sceneRef, { uid, bookId, jobId, chapterOrdinal, status: "ready_locked",
              anchor: candidate.anchor, altText: candidate.altText, caption: candidate.caption,
              generationSpec: spec, entityIds: candidate.entityIds, imageObject, thumbnailObject, generationVersion: 1,
              assetExpiresAt: Timestamp.fromMillis(Date.now() + assetRetentionMilliseconds),
              createdAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp() });
            if (candidate.entityIds.length) transaction.set(db.collection("worldReferences").doc(candidate.id), {
              uid, bookId, entityIds: candidate.entityIds, chapterOrdinal, paragraphOrdinal: candidate.paragraphOrdinal,
              referenceObject: imageObject, createdAt: FieldValue.serverTimestamp(),
            });
          });
          published = true;
          committed++;
          if (candidate.entityIds.length) generatedReferences.push({ entityIds: candidate.entityIds,
            chapterOrdinal, paragraphOrdinal: candidate.paragraphOrdinal, referenceObject: imageObject });
        } catch (error) {
          if (error instanceof CancelledClaim) throw error;
          await db.runTransaction(async (transaction) => {
            await liveClaim(transaction, claim);
            await settleCredit(transaction, claim, candidate.id, false);
          });
          console.info(JSON.stringify({ category: "candidate", outcome: error instanceof SafetyError ? "image_blocked" : "generation_failed" }));
        } finally { if (!published) await deleteObjects(imageObject, thumbnailObject); }
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
      if (!value) throw new HttpError(404, "Scene not found.");
      if (value.deleted || Number(value.generationVersion ?? 1) >= targetGeneration) return null;
      const [book, account] = await Promise.all([
        transaction.get(bookReference(value.uid, value.bookId)), transaction.get(accountReference(value.uid)),
      ]);
      if (!book.exists || book.data()?.deleted || account.exists) return null;
      if (value.regenerationTarget !== targetGeneration || value.status !== "regenerating" ||
        value.regenerationTaskId !== req.body.taskId) return null;
      if ((value.regenerationLeaseUntil?.toMillis() ?? 0) > Date.now()) throw new HttpError(409, "Regeneration is already running.");
      transaction.update(reference, { regenerationToken: token,
        regenerationLeaseUntil: Timestamp.fromMillis(Date.now() + 10 * 60 * 1000), updatedAt: FieldValue.serverTimestamp() });
      return value;
    });
    if (!data) { res.status(204).end(); return; }
    const claim: Claim = { reference, uid: data.uid, bookId: data.bookId, token, tokenField: "regenerationToken", leaseField: "regenerationLeaseUntil" };
    const spec = data.generationSpec as SceneGenerationSpec;
    const world = Array.isArray(spec.world) ? spec.world : [];
    const operationId = `${reference.id}:generation:${targetGeneration}`;
    // Refresh/paid intent is persisted by the API; task payload cannot change accounting.
    const refresh = data.regenerationRefresh === true;
    const prefix = `users/${data.uid}/books/${data.bookId}/scenes/${reference.id}.v${targetGeneration}.claim-${token}`;
    const imageObject = `${prefix}.webp`, thumbnailObject = `${prefix}.thumb.webp`;
    let reserved = false, published = false;
    try {
      if (!refresh) {
        reserved = await reserveCredit(claim, operationId);
        if (!reserved) throw new HttpError(402, "Insufficient credits.");
      }
      const prompt = composeImagePrompt({ style: spec.style, sceneText: spec.facts.join("; "), facts: spec.facts, world });
      if (await moderateText(prompt)) throw new SafetyError("text blocked");
      const image = await imageGenerationProvider.generate(prompt, await loadReferenceImages(world));
      if (await moderateImage(image)) throw new SafetyError("image blocked");
      await db.runTransaction(async (transaction) => { await liveClaim(transaction, claim); });
      await saveImages(image, imageObject, thumbnailObject);
      await db.runTransaction(async (transaction) => {
        await liveClaim(transaction, claim);
        const worldReference = db.collection("worldReferences").doc(reference.id);
        const existingReference = await transaction.get(worldReference);
        if (!refresh) await settleCredit(transaction, claim, operationId, true);
        transaction.update(reference, { status: "ready_locked", imageObject, thumbnailObject, generationVersion: targetGeneration,
          assetExpiresAt: Timestamp.fromMillis(Date.now() + assetRetentionMilliseconds),
          regenerationTarget: FieldValue.delete(), regenerationRefresh: FieldValue.delete(), regenerationTaskId: FieldValue.delete(),
          regenerationToken: FieldValue.delete(), regenerationLeaseUntil: FieldValue.delete(), failureCategory: FieldValue.delete(), updatedAt: FieldValue.serverTimestamp() });
        if (existingReference.exists) transaction.update(worldReference, { referenceObject: imageObject, updatedAt: FieldValue.serverTimestamp() });
      });
      published = true;
      await deleteObjects(data.imageObject, data.thumbnailObject);
      res.status(204).end();
    } catch (error) {
      if (!published) await db.runTransaction(async (transaction) => {
        try { await liveClaim(transaction, claim); } catch (failure) { if (failure instanceof CancelledClaim) return; throw failure; }
        if (reserved) await settleCredit(transaction, claim, operationId, false);
        transaction.update(reference, { status: "unlocked", regenerationTarget: FieldValue.delete(), regenerationRefresh: FieldValue.delete(),
          regenerationTaskId: FieldValue.delete(), regenerationToken: FieldValue.delete(), regenerationLeaseUntil: FieldValue.delete(),
          failureCategory: error instanceof HttpError && error.status === 402 ? "insufficient_credits" : error instanceof SafetyError ? "safety_blocked" : "regeneration_failed",
          updatedAt: FieldValue.serverTimestamp() });
      });
      if (error instanceof CancelledClaim) { res.status(204).end(); return; }
      throw error;
    } finally { if (!published) await deleteObjects(imageObject, thumbnailObject); }
  }));
  return router;
}
