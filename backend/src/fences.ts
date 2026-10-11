import type { DocumentSnapshot, Firestore, Transaction } from "firebase-admin/firestore";

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
