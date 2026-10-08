import express, { type NextFunction, type Request, type Response } from "express";
import type { Firestore } from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import { narrationLimits, narrationMonthCounterId, type NarrationBackend } from "./narration.js";

/** Shared authenticated identity is supplied only by verified Firebase tokens. */
export type AccountRequest = Request & { uid?: string };

/** Injectable verification keeps authentication tests independent of Firebase. */
export function authenticateAccount(
  verifyIdentity: (token: string) => Promise<{ uid: string }>,
  verifyApp: (token: string) => Promise<unknown>,
) {
  return async (req: AccountRequest, res: Response, next: NextFunction) => {
    try {
      const bearer = req.header("authorization")?.match(/^Bearer\s+(\S+)$/i)?.[1];
      const appCheck = req.header("x-firebase-appcheck");
      if (!bearer || !appCheck) throw new Error("missing credentials");
      const [identity] = await Promise.all([verifyIdentity(bearer), verifyApp(appCheck)]);
      if (!identity.uid) throw new Error("missing identity");
      req.uid = identity.uid;
      next();
    } catch {
      res.status(401).json({ error: "Authentication and App Check are required." });
    }
  };
}

/** Read-only account summary; observing usage never activates generation. */
export function accountUsageRouter(dependencies: {
  db: Firestore;
  narrationEnabled: boolean;
  illustrationsEnabled: boolean;
  now?: () => Date;
  env?: NodeJS.ProcessEnv;
}) {
  const router = express.Router();
  router.get("/usage", (req: AccountRequest, res, next) => {
    const read = async () => {
      if (!req.uid) {
        res.status(401).json({ error: "Authentication and App Check are required." });
        return;
      }
      const now = dependencies.now?.() ?? new Date();
      const limit = narrationLimits(dependencies.env).monthly;
      const [usage, user] = await Promise.all([
        dependencies.db.collection("narrationUsage").doc(narrationMonthCounterId(req.uid, now)).get(),
        dependencies.db.collection("users").doc(req.uid).get(),
      ]);
      const counter = (value: unknown) => {
        if (!Number.isSafeInteger(value) || (value as number) < 0) throw new Error("Invalid usage counter");
        return value as number;
      };
      const used = counter(usage.data()?.used ?? 0);
      const credits = user.data()?.creditsRemaining;
      const activated = credits !== undefined;
      // Reserved narration units remain charged until normal quota cleanup releases
      // them. This endpoint intentionally does not reclaim or mutate reservations.
      res.set("Cache-Control", "no-store").json({
        asOf: now.toISOString(),
        narrationEnabled: dependencies.narrationEnabled,
        narrationMonthlyLimit: limit,
        narrationRemaining: Math.max(0, limit - used),
        narrationResetAt: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)).toISOString(),
        illustrationsEnabled: dependencies.illustrationsEnabled,
        illustrationCreditsRemaining: activated ? counter(credits) : null,
        illustrationCreditsReserved: activated ? counter(user.data()?.creditsReserved ?? 0) : null,
      });
    };
    read().catch(next);
  });
  return router;
}

/**
 * Purges verified account-owned cloud data even when generation is disabled.
 * Firebase identity deletion remains the client's responsibility after success.
 */
export function accountDeletionRouter(dependencies: {
  db: Firestore;
  storage: Storage;
  bucket: string;
  narration: Pick<NarrationBackend, "deleteAccount">;
}): express.Router {
  const router = express.Router();
  router.delete("/", (req: AccountRequest, res, next) => {
    const purge = async () => {
      if (!req.uid) {
        res.status(401).json({ error: "Authentication and App Check are required." });
        return;
      }
      const uid = req.uid;
      const { db, storage, bucket, narration } = dependencies;
      // Fence delayed narration workers before removing shared account assets.
      await narration.deleteAccount(uid);
      const [scenes, jobs, inputs, reservations, revisions, references] = await Promise.all([
        db.collection("illustrationScenes").where("uid", "==", uid).get(),
        db.collection("illustrationJobs").where("uid", "==", uid).get(),
        db.collection("illustrationJobInputs").where("uid", "==", uid).get(),
        db.collection("creditReservations").where("uid", "==", uid).get(),
        db.collection("worldRevisions").where("uid", "==", uid).get(),
        db.collection("worldReferences").where("uid", "==", uid).get(),
      ]);
      await storage.bucket(bucket).deleteFiles({
        prefix: `users/${uid}/`,
        force: true,
      });
      const writer = db.bulkWriter();
      for (const snapshot of [scenes, jobs, inputs, reservations, revisions, references]) {
        for (const document of snapshot.docs) writer.delete(document.ref);
      }
      await writer.close();
      await db.recursiveDelete(db.collection("users").doc(uid));
      res.status(204).end();
    };
    purge().catch(next);
  });
  return router;
}
