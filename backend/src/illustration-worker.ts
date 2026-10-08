import { createHash } from "node:crypto";
import express from "express";
import { FieldValue, Timestamp, type Firestore } from "firebase-admin/firestore";
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
  pilotCredits: number;
  assetRetentionMilliseconds: number;
  analyzeNarrative: typeof analyzeNarrative;
  composeImagePrompt: typeof composeImagePrompt;
  moderateText: typeof moderateText;
  moderateImage: typeof moderateImage;
  imageGenerationProvider: ImageGenerationProvider;
}

class SafetyError extends Error {}

/**
 * Owns illustration execution: leases, append-only history, credit reservations,
 * moderation and asset publication/cleanup. Authorization and rollout gating
 * remain at the mount; route failures retain their shared HttpError identity.
 */
export function illustrationWorkerRouter(dependencies: IllustrationWorkerDependencies) {
  const {
    db, storage, bucket: bucketName, pilotCredits, assetRetentionMilliseconds,
    analyzeNarrative, composeImagePrompt, moderateText, moderateImage,
    imageGenerationProvider,
  } = dependencies;
  const router = express.Router();

  async function loadReferenceImages(entries: WorldSnapshot[]): Promise<Buffer[]> {
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

  /** Loads the append-only world history and resolves only facts available at an anchor. */
  async function loadWorldSnapshot(
    uid: string,
    bookId: string,
    chapterOrdinal: number,
    paragraphOrdinal: number,
  ): Promise<{ revisions: WorldRevision[]; snapshot: WorldSnapshot[] }> {
    const [revisionDocuments, referenceDocuments] = await Promise.all([
      db.collection("worldRevisions").where("uid", "==", uid).where("bookId", "==", bookId).get(),
      db.collection("worldReferences").where("uid", "==", uid).where("bookId", "==", bookId).get(),
    ]);
    const revisions = revisionDocuments.docs.map((document) => document.data() as WorldRevision);
    const snapshot = resolveWorldSnapshot(revisions, chapterOrdinal, paragraphOrdinal);
    const references = referenceDocuments.docs
      .map((document) => document.data() as WorldReference)
      .filter((reference) => reference.chapterOrdinal < chapterOrdinal ||
        (reference.chapterOrdinal === chapterOrdinal && reference.paragraphOrdinal <= paragraphOrdinal))
      .sort((left, right) => left.chapterOrdinal - right.chapterOrdinal ||
        left.paragraphOrdinal - right.paragraphOrdinal);
    for (const reference of references) {
      for (const entityId of reference.entityIds) {
        const entity = snapshot.find((candidate) => candidate.entityId === entityId);
        if (entity) entity.referenceObject = reference.referenceObject;
      }
    }
    return { revisions, snapshot };
  }

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

  router.post("/jobs/:jobId", asyncRoute(async (req, res) => {
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
      const bookRef = db.collection("users").doc(uid).collection("books").doc(bookId);
      const book = await bookRef.get();
      const profile = book.data()?.profile as { style?: string } | undefined;
      if (!profile?.style) throw new Error("Book profile is incomplete");

      // Prefer earlier submitted chapters so adjacent resources observe a stable
      // world history even when Cloud Tasks invokes their workers concurrently.
      const siblingJobs = await db.collection("illustrationJobs")
        .where("uid", "==", uid).where("bookId", "==", bookId).get();
      const unfinishedPredecessor = siblingJobs.docs.some((document) =>
        Number(document.data().chapterOrdinal) < chapterOrdinal &&
        !["complete", "failed", "insufficient_credits"].includes(document.data().status)
      );
      if (unfinishedPredecessor) {
        await jobRef.set({
          status: "queued",
          leaseUntil: FieldValue.delete(),
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
        throw new HttpError(409, "An earlier chapter is still being analyzed.");
      }

      const priorWorld = await loadWorldSnapshot(uid, bookId, chapterOrdinal, -1);
      const analysis = await analyzeNarrative(input, priorWorld.snapshot);
      const entityIds = new Map(priorWorld.snapshot.map((entity) => [entity.entityId, entity.entityId]));
      for (const delta of analysis.entityDeltas) {
        if (!entityIds.has(delta.entityRef)) {
          entityIds.set(delta.entityRef, createHash("sha256")
            .update(`${bookId}:${jobId}:${delta.entityRef}`)
            .digest("hex").slice(0, 40));
        }
      }
      const newRevisions: WorldRevision[] = analysis.entityDeltas.map((delta) => {
        const paragraph = input.paragraphs.find((item) => item.id === delta.anchorParagraphId)!;
        return {
          uid,
          bookId,
          entityId: entityIds.get(delta.entityRef)!,
          kind: delta.kind,
          chapterOrdinal,
          paragraphOrdinal: paragraph.ordinal,
          paragraphId: paragraph.id,
          name: delta.name,
          aliases: delta.aliases,
          summary: delta.summary,
          visualDescription: delta.visualDescription,
          stateFacts: delta.stateFacts,
          analysisVersion: input.analysisVersion,
        };
      });
      const revisionWriter = db.bulkWriter();
      for (const revision of newRevisions) {
        const revisionId = createHash("sha256")
          .update(`${jobId}:${revision.entityId}:${revision.paragraphId}`)
          .digest("hex");
        revisionWriter.set(db.collection("worldRevisions").doc(revisionId), {
          ...revision,
          createdAt: FieldValue.serverTimestamp(),
        });
      }
      await revisionWriter.close();
      await inputRef.delete();

      const allRevisions = [...priorWorld.revisions, ...newRevisions];
      const generatedReferences: WorldReference[] = [];
      let committed = 0;
      let finalStatus = "complete";
      for (const candidate of analysis.scenes) {
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
        const referencedIds = new Set(candidate.entityRefs
          .map((reference) => entityIds.get(reference))
          .filter((value): value is string => Boolean(value)));
        const worldAtScene = resolveWorldSnapshot(allRevisions, chapterOrdinal, start)
          .filter((entity) => referencedIds.has(entity.entityId));
        for (const entity of worldAtScene) {
          entity.referenceObject = priorWorld.snapshot
            .find((known) => known.entityId === entity.entityId)?.referenceObject;
          const inChapterReference = generatedReferences
            .filter((reference) => reference.paragraphOrdinal <= start &&
              reference.entityIds.includes(entity.entityId))
            .sort((left, right) => right.paragraphOrdinal - left.paragraphOrdinal)[0];
          if (inChapterReference) entity.referenceObject = inChapterReference.referenceObject;
        }
        const prompt = composeImagePrompt({
          style: profile.style,
          sceneText,
          facts: candidate.facts,
          world: worldAtScene,
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
            await loadReferenceImages(worldAtScene),
          );
          if (await moderateImage(image)) throw new SafetyError("image blocked");
          const thumbnail = await sharp(image).resize({ width: 640, withoutEnlargement: true }).webp({ quality: 78 }).toBuffer();
          const bucket = storage.bucket(bucketName);
          await Promise.all([
            bucket.file(imageObject).save(image, { contentType: "image/webp", resumable: false }),
            bucket.file(thumbnailObject).save(thumbnail, { contentType: "image/webp", resumable: false }),
          ]);
          const endParagraph = input.paragraphs[end]!;
          const sceneBatch = db.batch();
          sceneBatch.create(sceneRef, {
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
            generationSpec: {
              style: profile.style,
              facts: candidate.facts,
              world: worldAtScene,
            } satisfies SceneGenerationSpec,
            entityIds: [...referencedIds],
            imageObject, thumbnailObject, generationVersion: 1,
            assetExpiresAt: Timestamp.fromMillis(Date.now() + assetRetentionMilliseconds),
            createdAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp(),
          });
          let generatedReference: (WorldReference & { uid: string; bookId: string }) | undefined;
          if (referencedIds.size > 0) {
            generatedReference = {
              uid,
              bookId,
              entityIds: [...referencedIds],
              chapterOrdinal,
              paragraphOrdinal: end,
              referenceObject: imageObject,
            };
            sceneBatch.set(db.collection("worldReferences").doc(sceneId), {
              ...generatedReference,
              createdAt: FieldValue.serverTimestamp(),
            });
          }
          await sceneBatch.commit();
          if (generatedReference) generatedReferences.push(generatedReference);
          await commitCredit(uid, sceneId);
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
      await bookRef.set({
        worldVersion: FieldValue.increment(newRevisions.length),
        visualBibleVersion: FieldValue.increment(newRevisions.length),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      await jobRef.set({
        status: finalStatus,
        leaseUntil: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      res.status(204).end();
    } catch (error) {
      if (error instanceof HttpError && error.status === 409) throw error;
      await inputRef.delete().catch(() => undefined);
      await jobRef.set({
        status: "failed", failureCategory: "worker_failed",
        leaseUntil: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      throw error;
    }
  }));

  router.post("/scenes/:sceneId/regenerate", asyncRoute(async (req, res) => {
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
    const spec = data.generationSpec as Partial<SceneGenerationSpec> & {
      style: string;
      facts: string[];
    };
    const world = Array.isArray(spec.world) ? spec.world : [];
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
        // Raw prose is deleted after planning; regeneration uses the validated
        // paraphrased facts and the original time-bounded world snapshot.
        sceneText: spec.facts.join("; "),
        facts: spec.facts,
        world,
      });
      if (await moderateText(prompt)) throw new SafetyError("text blocked");
      const image = await imageGenerationProvider.generate(
        prompt,
        await loadReferenceImages(world),
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
      const worldReference = db.collection("worldReferences").doc(reference.id);
      if ((await worldReference.get()).exists) {
        await worldReference.update({
          referenceObject: imageObject,
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
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

  return router;
}
