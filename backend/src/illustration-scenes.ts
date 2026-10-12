import { randomUUID } from "node:crypto";
import express, { type RequestHandler } from "express";
import { FieldValue, type Firestore, type Timestamp, type Transaction, type DocumentReference } from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import { asyncRoute, HttpError, routeParam } from "./http.js";
import { readBookFence } from "./fences.js";
import { refundReservation } from "./illustration-credits.js";
import {
  requireAvailableImageProvider, requireImageGenerationConfig,
  requireIllustrationProfile, snapshotImageGenerationConfig,
} from "./illustration-configuration.js";
import type { SceneGenerationSpec } from "./types.js";

const imageMimeTypes: Record<string, true> = { "image/png": true, "image/jpeg": true, "image/webp": true };

/** Public illustration mutations share the worker's durable book/account fences. */
export function illustrationSceneRouter(dependencies: {
  db: Firestore;
  storage: Storage;
  bucket: string;
  requireFeature: RequestHandler;
  enqueue: (path: string, payload: Record<string, unknown>, taskId: string) => Promise<void>;
}) {
  const { db, storage, bucket, requireFeature, enqueue } = dependencies;
  const router = express.Router();

  async function ownedScene(transaction: Transaction, reference: DocumentReference, uid: string) {
    const scene = await transaction.get(reference);
    const data = scene.data();
    if (!data || data.uid !== uid || data.deleted) throw new HttpError(404, "Scene not found.");
    const fence = await readBookFence(transaction, db, "books", uid, data.bookId);
    if (!fence.live) throw new HttpError(410, "Scene was deleted.");
    return { data, book: fence.book.data()! };
  }

  /**
   * Pending recipe/target/refresh/task identity are written before enqueue and
   * reused unchanged on retries. Previous status restores the committed scene
   * on failure; all pending fields are deleted after settlement or deletion.
   */
  async function requestRegeneration(reference: DocumentReference, uid: string, refresh: boolean) {
    const request = await db.runTransaction(async (transaction) => {
      const { data, book } = await ownedScene(transaction, reference, uid);
      if (data.status === "regenerating") {
        return { target: Number(data.regenerationTarget), refresh: data.regenerationRefresh === true,
          taskId: String(data.regenerationTaskId) };
      }
      if (!["ready_locked", "unlocked"].includes(data.status)) throw new HttpError(409, "Scene is not ready.");
      const publishedSpec = data.generationSpec as SceneGenerationSpec;
      requireImageGenerationConfig(publishedSpec?.imageConfig);
      let generationSpec = publishedSpec;
      if (!refresh) {
        // Paid replacement adopts current preferences, but never new story facts.
        const profile = requireIllustrationProfile(book.profile);
        requireAvailableImageProvider(profile.providerId);
        generationSpec = { ...publishedSpec, style: profile.style,
          imageConfig: snapshotImageGenerationConfig(profile.providerId) };
      }
      const target = Number(data.generation) + 1;
      const taskId = `${refresh ? "refresh" : "regen"}-${reference.id}-${target}-${randomUUID()}`;
      transaction.update(reference, { status: "regenerating", regenerationTarget: target,
        regenerationRefresh: refresh, regenerationTaskId: taskId,
        regenerationGenerationSpec: generationSpec, regenerationPreviousStatus: data.status,
        failureCategory: FieldValue.delete(), updatedAt: FieldValue.serverTimestamp() });
      return { target, refresh, taskId };
    });
    // A transient createTask failure deliberately leaves this intent pending.
    // The caller's retry submits the same task rather than silently returning 202.
    await enqueue(`/internal/scenes/${reference.id}/regenerate`, {
      sceneId: reference.id, targetGeneration: request.target, refresh: request.refresh, taskId: request.taskId,
    }, request.taskId);
  }

  router.post("/scenes/:sceneId/unlock", requireFeature, asyncRoute(async (req, res) => {
    const reference = db.collection("illustrationScenes").doc(routeParam(req, "sceneId"));
    const { data: scene } = await db.runTransaction((transaction) => ownedScene(transaction, reference, req.uid!));
    if (scene.status === "regenerating") {
      await requestRegeneration(reference, req.uid!, true);
      throw new HttpError(409, "Scene asset is being refreshed.");
    }
    if (!["ready_locked", "unlocked"].includes(scene.status)) throw new HttpError(409, "Scene is not ready.");
    const assetExpiresAt = scene.assetExpiresAt as Timestamp | undefined;
    if (!assetExpiresAt || assetExpiresAt.toMillis() < Date.now() + 24 * 60 * 60 * 1000) {
      await requestRegeneration(reference, req.uid!, true);
      throw new HttpError(409, "Scene asset is being refreshed.");
    }
    const thumbnailUsesOriginal = scene.thumbnailObject === scene.imageObject;
    if (typeof scene.imageObject !== "string" || typeof scene.thumbnailObject !== "string" ||
        typeof scene.imageMimeType !== "string" || !Object.hasOwn(imageMimeTypes, scene.imageMimeType) ||
        typeof scene.thumbnailMimeType !== "string" || !Object.hasOwn(imageMimeTypes, scene.thumbnailMimeType) ||
        (thumbnailUsesOriginal && scene.imageMimeType !== scene.thumbnailMimeType)) {
      throw new HttpError(409, "Scene asset is unavailable.");
    }
    const expires = Date.now() + 10 * 60 * 1000;
    const imageUrlPromise = storage.bucket(bucket).file(scene.imageObject)
      .getSignedUrl({ action: "read", expires }).then(([url]) => url);
    // One owned FLUX object receives one signature and one client download.
    const [imageUrl, thumbnailUrl] = await Promise.all([
      imageUrlPromise,
      thumbnailUsesOriginal ? imageUrlPromise : storage.bucket(bucket).file(scene.thumbnailObject)
        .getSignedUrl({ action: "read", expires }).then(([url]) => url),
    ]);
    await db.runTransaction(async (transaction) => {
      const { data: current } = await ownedScene(transaction, reference, req.uid!);
      if (current.generation !== scene.generation || !["ready_locked", "unlocked"].includes(current.status)) {
        throw new HttpError(409, "Scene changed while unlocking.");
      }
      transaction.update(reference, { status: "unlocked", unlockedAt: FieldValue.serverTimestamp() });
    });
    res.json({ imageUrl, thumbnailUrl, imageMimeType: scene.imageMimeType,
      thumbnailMimeType: scene.thumbnailMimeType, thumbnailUsesOriginal,
      altText: scene.altText, caption: scene.caption, generation: scene.generation });
  }));

  router.post("/scenes/:sceneId/regenerate", requireFeature, asyncRoute(async (req, res) => {
    const reference = db.collection("illustrationScenes").doc(routeParam(req, "sceneId"));
    await requestRegeneration(reference, req.uid!, false);
    res.status(202).end();
  }));

  router.delete("/scenes/:sceneId", asyncRoute(async (req, res) => {
    const reference = db.collection("illustrationScenes").doc(routeParam(req, "sceneId"));
    const data = await db.runTransaction(async (transaction) => {
      const scene = await transaction.get(reference);
      const value = scene.data();
      if (!value || value.uid !== req.uid) throw new HttpError(404, "Scene not found.");
      // Keep the old object names until cleanup succeeds, so failed deletion is retryable.
      transaction.update(reference, { deleted: true, status: "deleted",
        regenerationGenerationSpec: FieldValue.delete(), regenerationPreviousStatus: FieldValue.delete(),
        regenerationTarget: FieldValue.delete(), regenerationRefresh: FieldValue.delete(), regenerationTaskId: FieldValue.delete(),
        regenerationToken: FieldValue.delete(), regenerationLeaseUntil: FieldValue.delete(), updatedAt: FieldValue.serverTimestamp() });
      return value;
    });
    const reservations = await db.collection("creditReservations").where("uid", "==", req.uid)
      .where("sceneId", "==", reference.id).get();
    for (const reservation of reservations.docs) await refundReservation(db, req.uid!, reservation.ref);
    const objects = [...new Set([data.imageObject, data.thumbnailObject]
      .filter((object): object is string => typeof object === "string" && Boolean(object)))];
    await Promise.all(objects.map((object) => storage.bucket(bucket).file(object).delete({ ignoreNotFound: true })));
    await db.runTransaction(async (transaction) => {
      const scene = await transaction.get(reference);
      if (!scene.exists || !scene.data()?.deleted) return;
      // A minimal, non-TTL tombstone prevents deterministic scene IDs from resurrecting.
      transaction.set(reference, { uid: req.uid, bookId: data.bookId,
        deleted: true, status: "deleted", deletedAt: FieldValue.serverTimestamp() });
    });
    res.status(204).end();
  }));
  return router;
}
