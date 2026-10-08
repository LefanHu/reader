import { createHash, randomUUID } from "node:crypto";
import express, {
  type Request,
  type Response,
  type NextFunction,
} from "express";
import {
  FieldValue,
  Timestamp,
  type Firestore,
} from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import type { NarrationProvider } from "./narration-provider.js";

/** Bounded public input; UTF-16 lengths match the native normalized chunker. */
export interface NarrationInput {
  text: string;
  digest: string;
  chunkId: string;
  voice: "marin" | "cedar";
  documentVersion: number;
  chunkVersion: number;
}

/** Safe HTTP failures expose categories, never prose or provider responses. */
export class NarrationError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
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
          "documentVersion",
          "chunkVersion",
        ].includes(key),
    )
  )
    throw new NarrationError(400, "Invalid narration schema.");
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
    !["marin", "cedar"].includes(value.voice ?? "") ||
    value.documentVersion !== 1 ||
    value.chunkVersion !== 1
  )
    throw new NarrationError(400, "Invalid narration chunk.");
  if (createHash("sha256").update(value.text).digest("hex") !== value.digest)
    throw new NarrationError(400, "Narration digest mismatch.");
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

type Authed = Request & { uid?: string };
const retention = 30 * 86400000;
const lease = 240000;
const hash = (text: string) => createHash("sha256").update(text).digest("hex");
const routeId = (req: Request, name: string) => {
  const value = req.params[name];
  if (typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value))
    throw new NarrationError(400, "Invalid narration identifier.");
  return value;
};
const route =
  (action: (req: Authed, res: Response) => Promise<void>) =>
  (req: Authed, res: Response, next: NextFunction) => {
    action(req, res).catch(next);
  };

/** Owns jobs, allowance reservations, leases and tombstones behind shared auth. */
export class NarrationBackend {
  constructor(readonly dependencies: NarrationDependencies) {}
  private book(uid: string, id: string) {
    return this.dependencies.db
      .collection("users")
      .doc(uid)
      .collection("narrationBooks")
      .doc(id);
  }
  private account(uid: string) {
    return this.dependencies.db
      .collection("narrationAccountTombstones")
      .doc(uid);
  }
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

  /** Durable tombstones fence claims and publishing, including late worker writes. */
  async deleteBook(uid: string, id: string): Promise<void> {
    const { db, storage, bucket } = this.dependencies;
    await this.book(uid, id).set(
      { uid, deleted: true, updatedAt: FieldValue.serverTimestamp() },
      { merge: true },
    );
    const jobs = await db
      .collection("narrationJobs")
      .where("uid", "==", uid)
      .where("bookId", "==", id)
      .get();
    for (const job of jobs.docs) {
      await this.release(job.id);
      await db.runTransaction(async (tx) => {
        const current = await tx.get(job.ref);
        if (!current.exists) return;
        tx.update(job.ref, {
          status: "deleted",
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
    await this.account(uid).set({ deletedAt: FieldValue.serverTimestamp() });
    const { db } = this.dependencies;
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
    for (const job of owned[0].docs) await this.release(job.id);
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
      tx.update(db.collection("narrationUsage").doc(data.monthCounter), {
        used: FieldValue.increment(-data.characters),
      });
      tx.update(db.collection("narrationDailyUsage").doc(data.dayCounter), {
        used: FieldValue.increment(-data.characters),
      });
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
        tx.update(db.collection("narrationUsage").doc(data.monthCounter), {
          used: FieldValue.increment(-data.characters),
        });
        tx.update(db.collection("narrationDailyUsage").doc(data.dayCounter), {
          used: FieldValue.increment(-data.characters),
        });
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
      route(async (req, res) => {
        await this.deleteBook(req.uid!, routeId(req, "bookId"));
        res.status(204).end();
      }),
    );
    router.get(
      "/config",
      route(async (req, res) => {
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
      route(async (req, res) => {
        if (
          req.body?.consentVersion !== 1 ||
          typeof req.body?.fingerprint !== "string" ||
          !/^[a-f0-9]{64}$/.test(req.body.fingerprint)
        )
          throw new NarrationError(
            400,
            "Narration consent and fingerprint required.",
          );
        const uid = req.uid!;
        const id = hash(`${uid}:${req.body.fingerprint}:${randomUUID()}`);
        await db.runTransaction(async (tx) => {
          if ((await tx.get(this.account(uid))).exists)
            throw new NarrationError(410, "Account was deleted.");
          tx.create(this.book(uid, id), {
            uid,
            fingerprint: req.body.fingerprint,
            consentVersion: 1,
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
      route(async (req, res) => {
        const uid = req.uid!,
          bookId = routeId(req, "bookId"),
          input = validateNarrationInput(req.body);
        const id = hash(
          JSON.stringify({
            uid,
            bookId,
            digest: input.digest,
            chunkId: input.chunkId,
            documentVersion: input.documentVersion,
            chunkVersion: input.chunkVersion,
            voice: input.voice,
            model: "gpt-realtime-2.1-mini",
            format: "pcm-24000-mono-v1",
          }),
        );
        const ref = db.collection("narrationJobs").doc(id),
          counters = this.counters(uid, new Date());
        const attempt = await db.runTransaction(async (tx) => {
          const [book, account, job, month, day] = await Promise.all([
            tx.get(this.book(uid, bookId)),
            tx.get(this.account(uid)),
            tx.get(ref),
            tx.get(counters.month),
            tx.get(counters.day),
          ]);
          if (!book.exists || book.data()?.deleted || account.exists)
            throw new NarrationError(410, "Narration book was deleted.");
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
            throw new NarrationError(409, "Narration retry limit reached.");
          const limits = narrationLimits();
          const monthUsed = Number(month.data()?.used ?? 0),
            dayUsed = Number(day.data()?.used ?? 0);
          if (
            monthUsed + input.text.length > limits.monthly ||
            dayUsed + input.text.length > limits.daily
          )
            throw new NarrationError(429, "Narration allowance exhausted.");
          tx.set(counters.month, { uid, used: monthUsed + input.text.length });
          tx.set(counters.day, { used: dayUsed + input.text.length });
          // Counters include both reserved and submitted units. Each retry receives
          // a new reservation; only pre-submission failures release its units.
          tx.set(ref, {
            uid,
            bookId,
            status: "queued",
            voice: input.voice,
            characters: input.text.length,
            digest: input.digest,
            monthCounter: counters.month.id,
            dayCounter: counters.day.id,
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
      route(async (req, res) => {
        const id = routeId(req, "jobId"),
          job = await db.collection("narrationJobs").doc(id).get();
        const data = job.data();
        if (!data || data.uid !== req.uid)
          throw new NarrationError(404, "Narration job not found.");
        const book = await this.book(req.uid!, data.bookId).get();
        if (book.data()?.deleted)
          throw new NarrationError(410, "Narration book was deleted.");
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
      route(async (req, res) => {
        if (!this.dependencies.enabled)
          throw new NarrationError(503, "Narration generation is disabled.");
        await this.run(routeId(req, "jobId"));
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
      if ((value.leaseUntil?.toMillis() ?? 0) > Date.now())
        throw new NarrationError(409, "Narration claim is busy.");
      const [book, account] = await Promise.all([
        tx.get(this.book(value.uid, value.bookId)),
        tx.get(this.account(value.uid)),
      ]);
      if (!book.exists || book.data()?.deleted || account.exists) return null;
      if (value.attempts >= 2) {
        tx.update(ref, { status: "failed" });
        return null;
      }
      if (value.submitted) {
        const counters = this.counters(value.uid, new Date()),
          limits = narrationLimits();
        const [month, day] = await Promise.all([
          tx.get(counters.month),
          tx.get(counters.day),
        ]);
        const monthUsed = Number(month.data()?.used ?? 0),
          dayUsed = Number(day.data()?.used ?? 0);
        if (
          monthUsed + value.characters > limits.monthly ||
          dayUsed + value.characters > limits.daily
        ) {
          tx.update(ref, { status: "failed" });
          return null;
        }
        tx.set(counters.month, {
          uid: value.uid,
          used: monthUsed + value.characters,
        });
        tx.set(counters.day, { used: dayUsed + value.characters });
        tx.update(ref, {
          monthCounter: counters.month.id,
          dayCounter: counters.day.id,
        });
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
            const [job, book, account] = await Promise.all([
              tx.get(ref),
              tx.get(this.book(data.uid, data.bookId)),
              tx.get(this.account(data.uid)),
            ]);
            if (
              job.data()?.token !== token ||
              book.data()?.deleted ||
              !book.exists ||
              account.exists
            )
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
        const [job, book, account] = await Promise.all([
          tx.get(ref),
          tx.get(this.book(data.uid, data.bookId)),
          tx.get(this.account(data.uid)),
        ]);
        if (
          job.data()?.token !== token ||
          book.data()?.deleted ||
          !book.exists ||
          account.exists
        )
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
