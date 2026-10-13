import type { Firestore, Query } from "firebase-admin/firestore";
import { ANALYSIS_COLLECTIONS } from "./book-analysis-store.js";

/** Top-level illustration and book-analysis collections whose records carry `uid` and `bookId`. */
export const OWNED_COLLECTIONS = [
  "illustrationScenes", "illustrationJobs", "illustrationJobInputs", "creditReservations",
  ANALYSIS_COLLECTIONS.jobs, ANALYSIS_COLLECTIONS.records, ANALYSIS_COLLECTIONS.inputs,
] as const;

const PAGE = 500;

/** One owner's records in a collection: a whole account, or one of its books. */
export function ownedQuery(db: Firestore, collection: string, owner: { uid: string; bookId?: string }): Query {
  const byUser = db.collection(collection).where("uid", "==", owner.uid);
  return owner.bookId === undefined ? byUser : byUser.where("bookId", "==", owner.bookId);
}

/**
 * Deletes every owned record, page by page, fetching document references only. Analysis
 * records can number in the tens of thousands per book and carry page JSON, so they are never
 * loaded whole. Callers tombstone first (so workers cannot recreate data) and release credit
 * reservations before calling this.
 */
export async function purgeOwnedRecords(db: Firestore, owner: { uid: string; bookId?: string }): Promise<void> {
  await Promise.all(OWNED_COLLECTIONS.map(async collection => {
    const query = ownedQuery(db, collection, owner).select().limit(PAGE);
    for (;;) {
      const { docs } = await query.get();
      if (docs.length === 0) return;
      const writer = db.bulkWriter();
      for (const document of docs) writer.delete(document.ref);
      await writer.close();
      if (docs.length < PAGE) return;
    }
  }));
}
