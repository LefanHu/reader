import { createHash } from "node:crypto";
import { FieldValue, type Firestore, type Transaction, type DocumentData } from "firebase-admin/firestore";
import { bookReference, readBookFence } from "./fences.js";
import { HttpError, requireString } from "./http.js";

/** A tombstone without `purgedAt` blocks re-registration only this long (covers a crashed purge). */
const PURGE_GRACE_MILLIS = 15 * 60_000;

/** Deterministic server ID of a user's book; every cloud feature shares it. */
export function ownedBookId(uid: string, fingerprint: string): string {
  return createHash("sha256").update(`${uid}:${fingerprint}:illustrations`).digest("hex").slice(0, 40);
}

/** Metadata registration; no profile, provider or credit coupling. */
export async function registerOwnedBook<T = undefined>(args: {
  db: Firestore;
  uid: string;
  metadata: Record<string, unknown>;
  extendTransaction?: (transaction: Transaction, existingBook: DocumentData | undefined) => Promise<T>;
}): Promise<{ bookId: string; chapterCount: number; extension: T | undefined }> {
  const { db, uid, metadata } = args;
  const fingerprint = requireString(metadata.fingerprint, "fingerprint", 128);
  const title = requireString(metadata.title, "title", 500);
  const chapterCount = Math.max(1, Math.min(10000, Number(metadata.chapterCount) || 1));
  const bookId = ownedBookId(uid, fingerprint);
  const extension = await db.runTransaction(async transaction => {
    const fence = await readBookFence(transaction, db, "books", uid, bookId);
    if (fence.accountDeleted) throw new HttpError(410, "Account was deleted.");
    const existing = fence.book.data();
    const tombstone = existing?.deleted ? existing : undefined;
    if (tombstone && !tombstone.purgedAt) {
      const deletedMillis = tombstone.deletedAt?.toMillis?.() ?? 0;
      if (Date.now() - deletedMillis < PURGE_GRACE_MILLIS) throw new HttpError(409, "Book deletion is still in progress.");
    }
    // A revived book starts fresh: profile and analysis pointers belonged to the purged incarnation.
    const result = await args.extendTransaction?.(transaction, tombstone ? undefined : existing);
    // Extension must finish all reads before its writes; metadata writes follow it.
    const fields = {
      uid, fingerprint, title,
      authors: Array.isArray(metadata.authors) ? metadata.authors.slice(0, 20) : [],
      language: typeof metadata.language === "string" ? metadata.language : null,
      chapterCount,
      updatedAt: FieldValue.serverTimestamp(),
    };
    const ref = bookReference(db, "books", uid, bookId);
    if (tombstone) {
      // No merge: deleted/deletedAt/purgedAt and every old pointer are dropped.
      transaction.set(ref, { ...fields, createdAt: FieldValue.serverTimestamp() });
    } else {
      transaction.set(ref, { ...fields, ...(!fence.book.exists ? { createdAt: FieldValue.serverTimestamp() } : {}) }, { merge: true });
    }
    return result;
  });
  return { bookId, chapterCount, extension };
}
