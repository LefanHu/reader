import { createHash, randomUUID } from "node:crypto";
import express from "express";
import {
  FieldValue,
  Timestamp,
  type DocumentData,
  type Firestore,
  type Transaction,
} from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import type { NarrationProvider } from "./narration-provider.js";
import { asyncRoute, HttpError, routeParam } from "./http.js";
import {
  accountTombstoneReference,
  assertLeaseFree,
  bookReference,
  readBookFence,
} from "./fences.js";

/** Bounded public input; UTF-16 lengths match the native normalized chunker. */
export interface NarrationInput {
  text: string;
  digest: string;
  chunkId: string;
  voice: "marin" | "cedar";
}

/** Reject malformed Unicode, unsupported settings, unbounded IDs and digest lies. */
export function validateNarrationInput(body: unknown): NarrationInput {
  const value = body as Partial<NarrationInput> | null;
  if (
    typeof body !== "object" ||
    Array.isArray(body) ||
    !value ||
    Object.keys(value).some(
      (key) =>
        ![
          "text",
          "digest",
          "chunkId",
          "voice",
        ].includes(key),
    )
  )
    throw new HttpError(400, "Invalid narration schema.");
  if (
    !value ||
    typeof value.text !== "string" ||
    !value.text.trim() ||
    value.text.length > 3000 ||
    /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(
      value.text,
    ) ||
    /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/u.test(value.text) ||
    !/^[a-f0-9]{64}$/.test(value.digest ?? "") ||
    !/^[a-f0-9]{64}$/.test(value.chunkId ?? "") ||
    !["marin", "cedar"].includes(value.voice ?? "")
  )
    throw new HttpError(400, "Invalid narration chunk.");
  if (createHash("sha256").update(value.text).digest("hex") !== value.digest)
    throw new HttpError(400, "Narration digest mismatch.");
  return value as NarrationInput;
}

/** UTC counters and configurable caps; invalid configuration fails closed. */
export function narrationLimits(env: NodeJS.ProcessEnv = process.env) {
  const monthly = Number(env.NARRATION_MONTHLY_CHARACTERS ?? 500000);
  const daily = Number(env.NARRATION_DAILY_CHARACTERS ?? 200000);
  if (
    ![monthly, daily].every(
      (limit) => Number.isSafeInteger(limit) && limit >= 0,
    )
  )
    throw new Error("Invalid narration quota configuration");
  return { monthly, daily };
}

/** Stable UTC-month identity shared by generation reservations and account reads. */
export function narrationMonthCounterId(uid: string, now: Date): string {
  return hash(`${uid}:${now.toISOString().slice(0, 7)}`);
}

/** Independent rollout; privacy deletes remain usable while generation is gated. */
export interface NarrationDependencies {
  db: Firestore;
  storage: Storage;
  bucket: string;
  provider: NarrationProvider;
  enabled: boolean;
  enqueue: (
    path: string,
    payload: Record<string, unknown>,
    id: string,
  ) => Promise<void>;
}

const retention = 30 * 86400000;
const lease = 240000;
const hash = (text: string) => createHash("sha256").update(text).digest("hex");
const narrationId = /^[a-f0-9]{64}$/;

/** Owns jobs, allowance reservations, leases and tombstones behind shared auth. */
export class NarrationBackend {
  constructor(readonly dependencies: NarrationDependencies) {}
  private counters(uid: string, now: Date) {
    const db = this.dependencies.db;
    const day = now.toISOString().slice(0, 10);
    return {
      month: db
        .collection("narrationUsage")
        .doc(narrationMonthCounterId(uid, now)),
      day: db.collection("narrationDailyUsage").doc(day),
    };
  }

  /** Reserves `characters` against both UTC counters, or returns null when exhausted. */
  private async reserveAllowance(
    tx: Transaction,
    uid: string,
    characters: number,
  ): Promise<{ monthCounter: string; dayCounter: string } | null> {
    const counters = this.counters(uid, new Date()),
      limits = narrationLimits();
    const [month, day] = await Promise.all([
      tx.get(counters.month),
      tx.get(counters.day),
    ]);
    const monthUsed = Number(month.data()?.used ?? 0),
      dayUsed = Number(day.data()?.used ?? 0);
    if (
      monthUsed + characters > limits.monthly ||
      dayUsed + characters > limits.daily
    )
      return null;
    tx.set(counters.month, { uid, used: monthUsed + characters });
    tx.set(counters.day, { used: dayUsed + characters });
    return { monthCounter: counters.month.id, dayCounter: counters.day.id };
  }

  /** Returns a job's reserved characters to the counters it was charged against. */
  private refundAllowance(tx: Transaction, data: DocumentData): void {
    const { db } = this.dependencies;
    tx.update(db.collection("narrationUsage").doc(data.monthCounter), {
      used: FieldValue.increment(-data.characters),
    });
    tx.update(db.collection("narrationDailyUsage").doc(data.dayCounter), {
      used: FieldValue.increment(-data.characters),
    });
  }

  /** Durable tombstones fence claims and publishing, including late worker writes. */
  async deleteBook(uid: string, id: string): Promise<void> {
    const { db, storage, bucket } = this.dependencies;
    await bookReference(db, "narrationBooks", uid, id).set(
      { uid, deleted: true, updatedAt: FieldValue.serverTimestamp() },
      { merge: true },
    );
    const jobs = await db
      .collection("narrationJobs")
      .where("uid", "==", uid)
      .where("bookId", "==", id)
      .get();
    for (const job of jobs.docs) {
      // Release and tombstone each job in one transaction.
      await db.runTransaction(async (tx) => {
        const current = await tx.get(job.ref);
        const data = current.data();
        if (!data) return;
        const release = data.reserved && !data.submitted;
        if (release) this.refundAllowance(tx, data);
        tx.update(job.ref, {
          status: "deleted",
          ...(release ? { reserved: false } : {}),
          token: FieldValue.delete(),
          leaseUntil: FieldValue.delete(),
        });
        tx.delete(db.collection("narrationInputs").doc(job.id));
      });
    }
    await storage
      .bucket(bucket)
      .deleteFiles({ prefix: `users/${uid}/narration/${id}/`, force: true });
  }

  /** Account tombstones precede purging so delayed workers cannot recreate data. */
  async deleteAccount(uid: string): Promise<void> {
    const { db } = this.dependencies;
    await accountTombstoneReference(db, uid).set({
      deletedAt: FieldValue.serverTimestamp(),
    });
    const books = await db
      .collection("users")
      .doc(uid)
      .collection("narrationBooks")
      .get();
    for (const book of books.docs) await this.deleteBook(uid, book.id);
    const owned = await Promise.all([
      db.collection("narrationJobs").where("uid", "==", uid).get(),
      db.collection("narrationInputs").where("uid", "==", uid).get(),
      db.collection("narrationUsage").where("uid", "==", uid).get(),
    ]);
    // Orphan jobs still own reservations. Release them before removing monthly
    // counters so a failed release leaves accounting available for a safe retry.
    // Jobs of listed books were released above; only still-reserved orphans need it.
    for (const job of owned[0].docs) if (job.data().reserved) await this.release(job.id);
    const writer = db.bulkWriter();
    for (const records of owned)
      for (const record of records.docs) writer.delete(record.ref);
    await writer.close();
    // Keep the account tombstone as a delayed-worker fence. Daily usage is shared:
    // only unsubmitted reservations are refunded; submitted attempts stay charged.
  }

  /** Releases only reservations that never reached provider submission. */
  private async release(id: string, expectedToken?: string): Promise<void> {
    const { db } = this.dependencies;
    const ref = db.collection("narrationJobs").doc(id);
    await db.runTransaction(async (tx) => {
      const job = await tx.get(ref);
      const data = job.data();
      if (
        !data?.reserved ||
        data.submitted ||
        (expectedToken != null && data.token !== expectedToken)
      )
        return;
      this.refundAllowance(tx, data);
      tx.update(ref, { reserved: false });
    });
  }

  /** Reclaims abandoned, unsubmitted reservations after the input TTL window.
   * This runs on allowance reads even when rollout is off, so a disabled queue
   * cannot indefinitely consume a user's monthly allowance. */
  private async reclaim(uid: string): Promise<void> {
    const { db } = this.dependencies;
    const jobs = await db
      .collection("narrationJobs")
      .where("uid", "==", uid)
      .where("reserved", "==", true)
      .where("submitted", "==", false)
      .where("createdAt", "<", Timestamp.fromMillis(Date.now() - 86400000))
      .limit(100)
      .get();
    for (const entry of jobs.docs) {
      await db.runTransaction(async (tx) => {
        const inputRef = db.collection("narrationInputs").doc(entry.id);
        const [job, input] = await Promise.all([
          tx.get(entry.ref),
          tx.get(inputRef),
        ]);
        const data = job.data();
        if (
          !data?.reserved ||
          data.submitted ||
          ["ready", "deleted"].includes(data.status) ||
          (data.leaseUntil?.toMillis() ?? 0) > Date.now() ||
          (input.data()?.expiresAt?.toMillis() ?? 0) > Date.now()
        )
          return;
        this.refundAllowance(tx, data);
        tx.update(entry.ref, {
          status: "failed",
          reserved: false,
          token: FieldValue.delete(),
          leaseUntil: FieldValue.delete(),
        });
        tx.delete(inputRef);
      });
    }
  }

  /** Authenticated API router; registration never initializes illustration credits. */
  api() {
    const router = express.Router();
    const { db, enabled } = this.dependencies;
    router.delete(
      "/books/:bookId",
      asyncRoute(async (req, res) => {
        await this.deleteBook(req.uid!, routeParam(req, "bookId", narrationId));
        res.status(204).end();
      }),
    );
    router.get(
      "/config",
      asyncRoute(async (req, res) => {
        await this.reclaim(req.uid!);
        const limits = narrationLimits();
        const counter = await this.counters(req.uid!, new Date()).month.get();
        res.json({
          enabled,
          model: "gpt-realtime-2.1-mini",
          voices: ["marin", "cedar"],
          monthly: limits.monthly,
          daily: limits.daily,
          remaining: Math.max(
            0,
            limits.monthly - Number(counter.data()?.used ?? 0),
          ),
          audioRetentionDays: 30,
        });
      }),
    );
    router.use((_req, res, next) => {
      if (!enabled) {
        res
          .status(503)
          .json({ error: "Narration is temporarily unavailable." });
        return;
      }
      next();
    });
    router.post(
      "/books",
      asyncRoute(async (req, res) => {
        if (
          typeof req.body?.fingerprint !== "string" ||
          !/^[a-f0-9]{64}$/.test(req.body.fingerprint)
        )
          throw new HttpError(400, "Valid fingerprint required.");
        const uid = req.uid!;
        const id = hash(`${uid}:${req.body.fingerprint}:${randomUUID()}`);
        await db.runTransaction(async (tx) => {
          if ((await tx.get(accountTombstoneReference(db, uid))).exists)
            throw new HttpError(410, "Account was deleted.");
          tx.create(bookReference(db, "narrationBooks", uid, id), {
            uid,
            fingerprint: req.body.fingerprint,
            deleted: false,
            createdAt: FieldValue.serverTimestamp(),
          });
        });
        const used =
          (await this.counters(uid, new Date()).month.get()).data()?.used ?? 0;
        res.json({
          id,
          account: uid,
          remaining: Math.max(0, narrationLimits().monthly - used),
        });
      }),
    );
    router.post(
      "/books/:bookId/jobs",
      asyncRoute(async (req, res) => {
        const uid = req.uid!,
          bookId = routeParam(req, "bookId", narrationId),
          input = validateNarrationInput(req.body);
        const id = hash(
          JSON.stringify({
            uid,
            bookId,
            digest: input.digest,
            chunkId: input.chunkId,
            voice: input.voice,
            model: "gpt-realtime-2.1-mini",
            format: "pcm-24000-mono",
          }),
        );
        const ref = db.collection("narrationJobs").doc(id);
        const attempt = await db.runTransaction(async (tx) => {
          const [fence, job] = await Promise.all([
            readBookFence(tx, db, "narrationBooks", uid, bookId),
            tx.get(ref),
          ]);
          if (!fence.live)
            throw new HttpError(410, "Narration book was deleted.");
          const existing = job.data();
          const expired =
            existing?.status === "ready" &&
            existing.expiresAt.toMillis() <= Date.now();
          if (job.exists && !expired && existing?.status !== "failed")
            return Math.max(
              0,
              Number(existing?.attempts ?? 0) -
                (["generating", "ready"].includes(existing?.status) ? 1 : 0),
            );
          if (!expired && Number(existing?.attempts ?? 0) >= 2)
            throw new HttpError(409, "Narration retry limit reached.");
          const reservation = await this.reserveAllowance(
            tx,
            uid,
            input.text.length,
          );
          if (!reservation)
            throw new HttpError(429, "Narration allowance exhausted.");
          // Counters include both reserved and submitted units. Each retry receives
          // a new reservation; only pre-submission failures release its units.
          tx.set(ref, {
            uid,
            bookId,
            status: "queued",
            voice: input.voice,
            characters: input.text.length,
            digest: input.digest,
            ...reservation,
            reserved: true,
            submitted: false,
            attempts: expired ? 0 : Number(existing?.attempts ?? 0),
            createdAt: FieldValue.serverTimestamp(),
          });
          tx.set(db.collection("narrationInputs").doc(id), {
            uid,
            bookId,
            text: input.text,
            expiresAt: Timestamp.fromMillis(Date.now() + 86400000),
          });
          return expired ? 0 : Number(existing?.attempts ?? 0);
        });
        // Re-enqueue idempotently after commit, repairing a crash between commit
        // and task creation without reserving or charging again.
        await this.dependencies.enqueue(
          `/internal/narration/${id}`,
          {},
          `narration-${id}-${attempt}`,
        );
        res.json({ id });
      }),
    );
    router.get(
      "/jobs/:jobId",
      asyncRoute(async (req, res) => {
        const id = routeParam(req, "jobId", narrationId),
          job = await db.collection("narrationJobs").doc(id).get();
        const data = job.data();
        if (!data || data.uid !== req.uid)
          throw new HttpError(404, "Narration job not found.");
        const book = await bookReference(
          db,
          "narrationBooks",
          req.uid!,
          data.bookId,
        ).get();
        if (book.data()?.deleted)
          throw new HttpError(410, "Narration book was deleted.");
        if (data.status !== "ready") {
          res.json({ status: data.status });
          return;
        }
        if (data.expiresAt.toMillis() <= Date.now()) {
          res.json({ status: "expired" });
          return;
        }
        const [url] = await this.dependencies.storage
          .bucket(this.dependencies.bucket)
          .file(data.object)
          .getSignedUrl({
            version: "v4",
            action: "read",
            expires: Date.now() + 600000,
          });
        res.json({ status: "ready", url });
      }),
    );
    return router;
  }

  /** Private worker router mounted before the independent illustration gate. */
  worker() {
    const router = express.Router();
    router.post(
      "/:jobId",
      asyncRoute(async (req, res) => {
        if (!this.dependencies.enabled)
          throw new HttpError(503, "Narration generation is disabled.");
        await this.run(routeParam(req, "jobId", narrationId));
        res.status(204).end();
      }),
    );
    return router;
  }

  /** Transactional claims bound retries and publish only for the live claim/book. */
  async run(id: string): Promise<void> {
    const { db, provider, storage, bucket } = this.dependencies;
    const ref = db.collection("narrationJobs").doc(id),
      inputRef = db.collection("narrationInputs").doc(id);
    const token = randomUUID();
    const data = await db.runTransaction(async (tx) => {
      const job = await tx.get(ref);
      const value = job.data();
      if (!value || ["ready", "failed", "deleted"].includes(value.status))
        return null;
      assertLeaseFree(value.leaseUntil, "Narration claim is busy.");
      if (
        !(await readBookFence(tx, db, "narrationBooks", value.uid, value.bookId))
          .live
      )
        return null;
      if (value.attempts >= 2) {
        tx.update(ref, { status: "failed" });
        return null;
      }
      if (value.submitted) {
        const reservation = await this.reserveAllowance(
          tx,
          value.uid,
          value.characters,
        );
        if (!reservation) {
          tx.update(ref, { status: "failed" });
          return null;
        }
        tx.update(ref, reservation);
      }
      tx.update(ref, {
        status: "generating",
        token,
        reserved: true,
        submitted: false,
        attempts: value.attempts + 1,
        leaseUntil: Timestamp.fromMillis(Date.now() + lease),
      });
      return value;
    });
    if (!data) {
      await this.release(id);
      await inputRef.delete();
      return;
    }
    const object = `users/${data.uid}/narration/${data.bookId}/${id}.${token}.wav`;
    let published = false;
    try {
      const input = await inputRef.get();
      if (!input.exists || input.data()!.expiresAt.toMillis() <= Date.now())
        throw new Error("Narration input expired");
      const audio = await provider.generate(
        input.data()!.text,
        data.voice,
        async () => {
          await db.runTransaction(async (tx) => {
            const [job, fence] = await Promise.all([
              tx.get(ref),
              readBookFence(tx, db, "narrationBooks", data.uid, data.bookId),
            ]);
            if (job.data()?.token !== token || !fence.live)
              throw new Error("Narration claim was cancelled");
            tx.update(ref, { submitted: true });
          });
        },
      );
      await storage
        .bucket(bucket)
        .file(object)
        .save(audio, {
          contentType: "audio/wav",
          resumable: false,
          preconditionOpts: { ifGenerationMatch: 0 },
        });
      await db.runTransaction(async (tx) => {
        const [job, fence] = await Promise.all([
          tx.get(ref),
          readBookFence(tx, db, "narrationBooks", data.uid, data.bookId),
        ]);
        if (job.data()?.token !== token || !fence.live)
          throw new Error("Narration publication was cancelled");
        tx.update(ref, {
          status: "ready",
          object,
          expiresAt: Timestamp.fromMillis(Date.now() + retention),
          token: FieldValue.delete(),
          leaseUntil: FieldValue.delete(),
        });
        tx.delete(inputRef);
      });
      published = true;
    } catch {
      // A stale worker may not refund a newer claim's reservation.
      await this.release(id, token);
      await db.runTransaction(async (tx) => {
        const job = await tx.get(ref);
        if (job.data()?.token !== token) return;
        tx.update(ref, {
          status: "failed",
          token: FieldValue.delete(),
          leaseUntil: FieldValue.delete(),
        });
        tx.delete(inputRef);
      });
    } finally {
      if (!published)
        await storage
          .bucket(bucket)
          .file(object)
          .delete({ ignoreNotFound: true })
          .catch(() => undefined);
    }
  }
}
