import { createHash } from "node:crypto";
import { FieldValue, type DocumentReference, type Firestore, type Transaction } from "firebase-admin/firestore";
import { accountTombstoneReference } from "./fences.js";

/** A worker claim was superseded or fenced; the work is acknowledged, not retried. */
export class CancelledClaim extends Error {}

/** The claim identity that owns a credit reservation. */
export type CreditOwner = { uid: string; bookId: string; token: string };

/** Deterministic reservation document for one billable operation. */
export function creditReservation(db: Firestore, uid: string, operationId: string) {
  return db.collection("creditReservations").doc(createHash("sha256").update(`${uid}:${operationId}`).digest("hex"));
}

/**
 * Reserves one credit for `operationId` inside the caller's transaction, after
 * the caller has fenced its claim. Returns false when already committed or out of credits.
 */
export async function reserveCredit(transaction: Transaction, db: Firestore, owner: CreditOwner, operationId: string) {
  const userRef = db.collection("users").doc(owner.uid);
  const reservationRef = creditReservation(db, owner.uid, operationId);
  const [user, reservation] = await Promise.all([transaction.get(userRef), transaction.get(reservationRef)]);
  if (!user.exists) throw new CancelledClaim();
  if (reservation.data()?.state === "committed") return false;
  const alreadyReserved = reservation.data()?.state === "reserved";
  const remaining = Number(user.data()?.creditsRemaining ?? 0);
  const reserved = Number(user.data()?.creditsReserved ?? 0);
  if (!alreadyReserved && remaining - reserved < 1) return false;
  if (!alreadyReserved) transaction.update(userRef, {
    creditsReserved: reserved + 1, updatedAt: FieldValue.serverTimestamp(),
  });
  // An expired lease transfers its existing reservation, never charging twice.
  transaction.set(reservationRef, {
    uid: owner.uid, bookId: owner.bookId, operationId, claimToken: owner.token,
    sceneId: operationId.split(":generation:")[0], state: "reserved",
    updatedAt: FieldValue.serverTimestamp(),
  });
  return true;
}

/** Call only after liveClaim, before any writes, so settlement is atomic with publication. */
export async function settleCredit(
  transaction: Transaction, db: Firestore, owner: CreditOwner, operationId: string, commit: boolean,
) {
  const userRef = db.collection("users").doc(owner.uid);
  const reservationRef = creditReservation(db, owner.uid, operationId);
  const [user, reservation] = await Promise.all([transaction.get(userRef), transaction.get(reservationRef)]);
  if (!user.exists || reservation.data()?.state !== "reserved" || reservation.data()?.claimToken !== owner.token) {
    throw new CancelledClaim();
  }
  transaction.update(userRef, {
    ...(commit ? { creditsRemaining: FieldValue.increment(-1) } : {}),
    creditsReserved: FieldValue.increment(-1), updatedAt: FieldValue.serverTimestamp(),
  });
  transaction.update(reservationRef, {
    state: commit ? "committed" : "refunded", updatedAt: FieldValue.serverTimestamp(),
  });
}

/**
 * Refunds a still-reserved credit in its own transaction. Deletion owns this
 * release; the user's balance is untouched once the account is tombstoned.
 */
export async function refundReservation(db: Firestore, uid: string, reservation: DocumentReference) {
  await db.runTransaction(async (transaction) => {
    const userRef = db.collection("users").doc(uid);
    const [current, user, account] = await Promise.all([
      transaction.get(reservation), transaction.get(userRef),
      transaction.get(accountTombstoneReference(db, uid)),
    ]);
    if (current.data()?.state !== "reserved") return;
    if (user.exists && !account.exists) transaction.update(userRef, {
      creditsReserved: FieldValue.increment(-1), updatedAt: FieldValue.serverTimestamp(),
    });
    transaction.update(reservation, { state: "refunded", updatedAt: FieldValue.serverTimestamp() });
  });
}
