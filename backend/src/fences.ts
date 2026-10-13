import type { DocumentSnapshot, Firestore, Timestamp, Transaction } from "firebase-admin/firestore";
import { HttpError } from "./http.js";

/** Per-user book collections: illustration books and narration books. */
export type BookCollection = "books" | "narrationBooks";

/** The user-owned book document fenced by deletion tombstones. */
export function bookReference(db: Firestore, collection: BookCollection, uid: string, bookId: string) {
  return db.collection("users").doc(uid).collection(collection).doc(bookId);
}

/** The durable account-deletion tombstone shared by every cloud feature. */
export function accountTombstoneReference(db: Firestore, uid: string) {
  return db.collection("narrationAccountTombstones").doc(uid);
}

/** Book and account fence state read inside one transaction. */
export interface BookFence {
  book: DocumentSnapshot;
  accountDeleted: boolean;
  /** The book exists, is not tombstoned, and the account was not deleted. */
  live: boolean;
}

/**
 * Reads the book and account tombstone inside the caller's transaction. Only
 * reads and never throws; callers map the result to their own statuses.
 */
export async function readBookFence(
  transaction: Transaction, db: Firestore, collection: BookCollection, uid: string, bookId: string,
): Promise<BookFence> {
  const [book, account] = await Promise.all([
    transaction.get(bookReference(db, collection, uid, bookId)),
    transaction.get(accountTombstoneReference(db, uid)),
  ]);
  return { book, accountDeleted: account.exists, live: book.exists && !book.data()?.deleted && !account.exists };
}

/**
 * Cloud Run's worker request timeout (`timeout = "900s"` in infra/modules/runtime).
 * Task dispatch deadlines match it, so Cloud Tasks never retries a healthy
 * request while it is still running.
 */
export const WORKER_REQUEST_TIMEOUT_SECONDS = 900;

/**
 * Claim lease for illustration and book-analysis workers. It outlasts the
 * longest possible worker request, so a live worker never loses its claim. A
 * crashed worker's lease lapses about a minute after its request deadline, and
 * queue retry backoff (60 s doubling to 600 s) keeps retrying past that point.
 */
export const WORKER_LEASE_MS = (WORKER_REQUEST_TIMEOUT_SECONDS + 60) * 1000;

/**
 * Rejects a claim attempt while another lease is live. A busy lease may belong
 * to a crashed worker, so the task must be retried (409), never acknowledged:
 * acknowledging would drop the only task able to resume the job.
 */
export function assertLeaseFree(leaseUntil: Timestamp | undefined, message: string): void {
  if ((leaseUntil?.toMillis() ?? 0) > Date.now()) throw new HttpError(409, message);
}
