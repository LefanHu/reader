import { createHash } from "node:crypto";
import { FieldValue, type Firestore, type Transaction, type DocumentData } from "firebase-admin/firestore";
import { bookReference, readBookFence } from "./fences.js";
import { HttpError, requireString } from "./http.js";
import { requireIllustrationSchema } from "./illustration-configuration.js";

/** Schema-2 metadata registration; no profile, provider or credit coupling. */
export async function registerOwnedBook<T = undefined>(args: {
  db: Firestore;
  uid: string;
  metadata: Record<string, unknown>;
  extendTransaction?: (transaction: Transaction, existingBook: DocumentData | undefined) => Promise<T>;
}): Promise<{ bookId: string; chapterCount: number; extension: T | undefined }> {
  const { db, uid, metadata } = args;
  requireIllustrationSchema(metadata.schemaVersion);
  const fingerprint = requireString(metadata.fingerprint, "fingerprint", 128);
  const title = requireString(metadata.title, "title", 500);
  const chapterCount = Math.max(1, Math.min(10000, Number(metadata.chapterCount) || 1));
  const bookId = createHash("sha256").update(`${uid}:${fingerprint}:illustrations-v2`).digest("hex").slice(0, 40);
  const extension = await db.runTransaction(async transaction => {
    const fence = await readBookFence(transaction, db, "books", uid, bookId);
    if (fence.accountDeleted) throw new HttpError(410, "Account was deleted.");
    if (fence.book.data()?.deleted) throw new HttpError(410, "Book was deleted.");
    // Extension must finish all reads before its writes; metadata writes follow it.
    const result = await args.extendTransaction?.(transaction, fence.book.data());
    transaction.set(bookReference(db, "books", uid, bookId), {
      schemaVersion: 2, uid, fingerprint, title,
      authors: Array.isArray(metadata.authors) ? metadata.authors.slice(0, 20) : [],
      language: typeof metadata.language === "string" ? metadata.language : null,
      chapterCount,
      ...(!fence.book.exists ? { createdAt: FieldValue.serverTimestamp() } : {}),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return result;
  });
  return { bookId, chapterCount, extension };
}
