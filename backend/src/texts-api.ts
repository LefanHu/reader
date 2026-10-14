import { createHash, randomBytes } from "node:crypto";
import express, { type RequestHandler } from "express";
import { FieldValue, type Firestore } from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import { alignParagraphs, flattenRuns, LINK_THRESHOLD, MAX_ALIGNMENT_RUNS } from "./alignment.js";
import { registerOwnedBook } from "./book-registration.js";
import { bookReference, readBookFence } from "./fences.js";
import { asyncRoute, HttpError, requireString } from "./http.js";
import { FINGERPRINT_BYTES, fingerprintList, MAX_PARAGRAPHS, sketchOf } from "./paragraph-fingerprints.js";

/** Shared texts whose sketch overlaps a copy's that are aligned in full. */
const MAX_CANDIDATES = 5;
/** Firestore's gRPC ALREADY_EXISTS. */
const ALREADY_EXISTS = 6;

type TextDoc = { reference: string; sketch: string[] };

/** Rejects before any write what `registerOwnedBook` would reject after it. */
function requireBookMetadata(value: unknown) {
  const book = value as { fingerprint?: unknown; title?: unknown } | null;
  requireString(book?.fingerprint, "fingerprint", 128);
  requireString(book?.title, "title", 500);
}

/**
 * Content identity for books: each copy is matched to a shared text by its
 * paragraph fingerprints alone, so every copy of one text can share one
 * analysis regardless of file, title or metadata.
 *
 * A shared text stores only the fingerprints of the first copy seen (its
 * reference) and a bottom-k sketch of them, never book text. A copy's sketch
 * finds candidate texts through one indexed query; the best candidate aligning
 * at `LINK_THRESHOLD` or better is the copy's text, otherwise the copy becomes
 * a new one. Shared texts are not user data: deleting a book or account
 * removes only the user's book document.
 */
export function textsApiRouter(dependencies: {
  db: Firestore; storage: Storage; bucket: string; requireFeature: RequestHandler;
}) {
  const { db, storage, bucket, requireFeature } = dependencies;
  const router = express.Router();
  const texts = db.collection("texts");

  async function reference(text: TextDoc) {
    const [bytes] = await storage.bucket(bucket).file(text.reference).download();
    return fingerprintList(bytes);
  }

  /** The best-aligning shared text at or above the threshold, if any. */
  async function bestMatch(user: string[], candidates: { id: string; data: TextDoc }[]) {
    let best: { textId: string; score: number; runs: number[] } | undefined;
    for (const candidate of candidates) {
      const alignment = alignParagraphs(user, await reference(candidate.data));
      if (alignment.score < LINK_THRESHOLD || alignment.runs.length > MAX_ALIGNMENT_RUNS) continue;
      if (!best || alignment.score > best.score) {
        best = { textId: candidate.id, score: alignment.score, runs: flattenRuns(alignment.runs) };
      }
    }
    return best;
  }

  /**
   * Creates a shared text from this copy. Identical copies derive the same ID
   * from their sketch, so of two concurrent first copies one `create` wins and
   * the other gets the winner's document back to align against. `unique`
   * skips that derivation for copies with no sketch or whose sketch is taken
   * by a text they do not align with.
   */
  async function createText(uid: string, sketch: string[], fingerprints: Buffer, unique = sketch.length === 0) {
    const textId = unique
      ? randomBytes(10).toString("hex")
      : createHash("sha256").update(sketch.join(","), "utf8").digest("hex").slice(0, 20);
    const object = `texts/${textId}/${randomBytes(8).toString("hex")}.bin`;
    const file = storage.bucket(bucket).file(object);
    // Object first: a text document never names a missing reference.
    await file.save(fingerprints, { contentType: "application/octet-stream" });
    try {
      await texts.doc(textId).create({
        reference: object, sketch, paragraphCount: fingerprints.length / FINGERPRINT_BYTES,
        createdBy: uid, createdAt: FieldValue.serverTimestamp(),
      });
      return { textId };
    } catch (error) {
      if ((error as { code?: unknown }).code !== ALREADY_EXISTS) throw error;
      await file.delete({ ignoreNotFound: true });
      return { textId, existing: (await texts.doc(textId).get()).data() as TextDoc };
    }
  }

  router.post("/texts/identify", requireFeature, asyncRoute(async (req, res) => {
    requireBookMetadata(req.body?.book);
    const encoded = requireString(req.body?.fingerprints, "fingerprints", Math.ceil(MAX_PARAGRAPHS * FINGERPRINT_BYTES / 3) * 4);
    const fingerprints = Buffer.from(encoded, "base64");
    const user = fingerprintList(fingerprints);
    const sketch = sketchOf(user);
    const candidates = sketch.length === 0 ? [] :
      (await texts.where("sketch", "array-contains-any", sketch).limit(MAX_CANDIDATES).get())
        .docs.map(doc => ({ id: doc.id, data: doc.data() as TextDoc }));
    let match = await bestMatch(user, candidates);
    let created = false;
    if (!match) {
      const result = await createText(req.uid!, sketch, fingerprints);
      if (result.existing) match = await bestMatch(user, [{ id: result.textId, data: result.existing }]);
      if (!match) {
        const { textId } = result.existing ? await createText(req.uid!, sketch, fingerprints, true) : result;
        // The first copy is the reference, so it aligns with itself.
        match = { textId, score: 1, runs: flattenRuns([[0, 0, user.length]]) };
        created = true;
      }
    }
    const { bookId } = await registerOwnedBook({ db, uid: req.uid!, metadata: req.body.book as Record<string, unknown> });
    await db.runTransaction(async (transaction) => {
      const fence = await readBookFence(transaction, db, "books", req.uid!, bookId);
      if (!fence.live) throw new HttpError(410, "Book was deleted.");
      transaction.update(bookReference(db, "books", req.uid!, bookId), {
        text: { textId: match.textId, score: match.score, runs: match.runs }, updatedAt: FieldValue.serverTimestamp(),
      });
    });
    res.status(created ? 201 : 200).json({ bookId, textId: match.textId, score: match.score, created });
  }));

  return router;
}
