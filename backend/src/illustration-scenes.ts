import { randomUUID } from "node:crypto";
import express, { type RequestHandler } from "express";
import { FieldValue, type Firestore, type Timestamp, type Transaction, type DocumentReference } from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import { asyncRoute, HttpError, routeParam } from "./illustration-http.js";

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
    const [book, account] = await Promise.all([
      transaction.get(db.collection("users").doc(uid).collection("books").doc(data.bookId)),
      transaction.get(db.collection("narrationAccountTombstones").doc(uid)),
    ]);
    if (!book.exists || book.data()?.deleted || account.exists) throw new HttpError(410, "Scene was deleted.");
    return data;
  }

  /** The durable task identity and billing intent are reused on every enqueue retry. */
  async function requestRegeneration(reference: DocumentReference, uid: string, refresh: boolean) {
    const request = await db.runTransaction(async (transaction) => {
      const data = await ownedScene(transaction, reference, uid);
      if (data.status === "regenerating") {
        return { target: Number(data.regenerationTarget), refresh: data.regenerationRefresh === true,
          taskId: String(data.regenerationTaskId) };
      }
      if (!["ready_locked", "unlocked"].includes(data.status)) throw new HttpError(409, "Scene is not ready.");
      const target = Number(data.generationVersion ?? 1) + 1;
      const taskId = `${refresh ? "refresh" : "regen"}-${reference.id}-${target}-${randomUUID()}`;
      transaction.update(reference, { status: "regenerating", regenerationTarget: target,
        regenerationRefresh: refresh, regenerationTaskId: taskId, updatedAt: FieldValue.serverTimestamp() });
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
    const scene = await db.runTransaction((transaction) => ownedScene(transaction, reference, req.uid!));
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
    const expires = Date.now() + 10 * 60 * 1000;
    const [imageUrl, thumbnailUrl] = await Promise.all([
      storage.bucket(bucket).file(scene.imageObject).getSignedUrl({ action: "read", expires }).then(([url]) => url),
      storage.bucket(bucket).file(scene.thumbnailObject).getSignedUrl({ action: "read", expires }).then(([url]) => url),
    ]);
    await db.runTransaction(async (transaction) => {
      const current = await ownedScene(transaction, reference, req.uid!);
      if (current.generationVersion !== scene.generationVersion || !["ready_locked", "unlocked"].includes(current.status)) {
        throw new HttpError(409, "Scene changed while unlocking.");
      }
      transaction.update(reference, { status: "unlocked", unlockedAt: FieldValue.serverTimestamp() });
    });
    res.json({ imageUrl, thumbnailUrl, altText: scene.altText, caption: scene.caption, generationVersion: scene.generationVersion ?? 1 });
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
      transaction.update(reference, { deleted: true, status: "deleted", regenerationToken: FieldValue.delete(),
        regenerationLeaseUntil: FieldValue.delete(), updatedAt: FieldValue.serverTimestamp() });
      transaction.delete(db.collection("worldReferences").doc(reference.id));
      return value;
    });
    const reservations = await db.collection("creditReservations").where("uid", "==", req.uid)
      .where("sceneId", "==", reference.id).get();
    for (const reservation of reservations.docs) await db.runTransaction(async (transaction) => {
      const userRef = db.collection("users").doc(req.uid!);
      const [current, user, account] = await Promise.all([
        transaction.get(reservation.ref), transaction.get(userRef),
        transaction.get(db.collection("narrationAccountTombstones").doc(req.uid!)),
      ]);
      if (current.data()?.state !== "reserved") return;
      if (user.exists && !account.exists) transaction.update(userRef, { creditsReserved: FieldValue.increment(-1), updatedAt: FieldValue.serverTimestamp() });
      transaction.update(reservation.ref, { state: "refunded", updatedAt: FieldValue.serverTimestamp() });
    });
    await Promise.all([data.imageObject, data.thumbnailObject].filter((object): object is string => typeof object === "string")
      .map((object) => storage.bucket(bucket).file(object).delete({ ignoreNotFound: true })));
    await db.runTransaction(async (transaction) => {
      const scene = await transaction.get(reference);
      if (!scene.exists || !scene.data()?.deleted) return;
      // A minimal, non-TTL tombstone prevents deterministic scene IDs from resurrecting.
      transaction.set(reference, { uid: req.uid, bookId: data.bookId, deleted: true, status: "deleted", deletedAt: FieldValue.serverTimestamp() });
    });
    res.status(204).end();
  }));
  return router;
}
