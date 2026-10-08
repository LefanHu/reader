import { createHash } from "node:crypto";
import { FieldValue, type Firestore } from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import { asyncRoute, HttpError, requireString, routeParam } from "./illustration-http.js";

function stylesFor(title: string): string[] {
  const normalized = title.toLowerCase();
  if (/cultivat|xianxia|wuxia|immortal|dao/.test(normalized)) {
    return ["Cinematic mythic ink fantasy", "Luminous eastern epic", "Painterly martial fantasy"];
  }
  if (/diary|school|kid|comic/.test(normalized)) {
    return ["Expressive monochrome diary sketch", "Loose graphic novel ink", "Playful editorial cartoon"];
  }
  if (/space|star|planet|sci-fi|science fiction/.test(normalized)) {
    return ["Cinematic science-fiction concept art", "Retro-futurist painted illustration", "Graphic cosmic noir"];
  }
  return ["Cinematic painterly book illustration", "Atmospheric graphic novel", "Textured monochrome ink"];
}

/** Book registration initializes pilot credit once without replacing live balances. */
export function illustrationBookRegistration(dependencies: { db: Firestore; pilotCredits: number }) {
  const { db, pilotCredits } = dependencies;
  return asyncRoute(async (req, res) => {
    const uid = req.uid!;
    const fingerprint = requireString(req.body.fingerprint, "fingerprint", 128);
    const title = requireString(req.body.title, "title", 500);
    const chapterCount = Math.max(1, Math.min(10000, Number(req.body.chapterCount) || 1));
    const bookId = createHash("sha256").update(`${uid}:${fingerprint}`).digest("hex").slice(0, 40);
    const styles = stylesFor(title);
    await db.runTransaction(async (transaction) => {
      const userRef = db.collection("users").doc(uid);
      const bookRef = userRef.collection("books").doc(bookId);
      const [user, tombstone, book] = await Promise.all([
        transaction.get(userRef),
        transaction.get(db.collection("narrationAccountTombstones").doc(uid)),
        transaction.get(bookRef),
      ]);
      if (tombstone.exists) throw new HttpError(410, "Account was deleted.");
      if (book.data()?.deleted) throw new HttpError(410, "Book was deleted.");
      transaction.set(bookRef, {
        uid,
        fingerprint,
        title,
        authors: Array.isArray(req.body.authors) ? req.body.authors.slice(0, 20) : [],
        language: typeof req.body.language === "string" ? req.body.language : null,
        chapterCount,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      if (user.data()?.creditsRemaining === undefined) {
        transaction.set(userRef, {
          creditsRemaining: pilotCredits,
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    });
    res.json({
      id: bookId,
      suggestedStyle: styles[0],
      alternativeStyles: styles.slice(1),
      estimatedCredits: chapterCount * 3,
    });
  });
}

/** Tombstone before querying/purging so delayed providers cannot recreate book data. */
export function illustrationBookDeletion(dependencies: { db: Firestore; storage: Storage; bucket: string }) {
  const { db, storage, bucket } = dependencies;
  return asyncRoute(async (req, res) => {
    const uid = req.uid!, bookId = routeParam(req, "bookId");
    const bookRef = db.collection("users").doc(uid).collection("books").doc(bookId);
    await db.runTransaction(async (transaction) => {
      const book = await transaction.get(bookRef);
      if (!book.exists) throw new HttpError(404, "Book not found.");
      transaction.set(bookRef, { uid, deleted: true, deletedAt: FieldValue.serverTimestamp() });
    });
    const records = await Promise.all([
      db.collection("illustrationScenes").where("uid", "==", uid).where("bookId", "==", bookId).get(),
      db.collection("illustrationJobs").where("uid", "==", uid).where("bookId", "==", bookId).get(),
      db.collection("illustrationJobInputs").where("uid", "==", uid).where("bookId", "==", bookId).get(),
      db.collection("creditReservations").where("uid", "==", uid).where("bookId", "==", bookId).get(),
      db.collection("worldRevisions").where("uid", "==", uid).where("bookId", "==", bookId).get(),
      db.collection("worldReferences").where("uid", "==", uid).where("bookId", "==", bookId).get(),
    ]);
    // Deletion owns releasing reservations; a fenced late worker cannot refund.
    for (const reservation of records[3]!.docs) await db.runTransaction(async (transaction) => {
      const userRef = db.collection("users").doc(uid);
      const [current, user, account] = await Promise.all([
        transaction.get(reservation.ref), transaction.get(userRef),
        transaction.get(db.collection("narrationAccountTombstones").doc(uid)),
      ]);
      if (current.data()?.state !== "reserved") return;
      if (user.exists && !account.exists) transaction.update(userRef, {
        creditsReserved: FieldValue.increment(-1), updatedAt: FieldValue.serverTimestamp(),
      });
      transaction.update(reservation.ref, { state: "refunded", updatedAt: FieldValue.serverTimestamp() });
    });
    await storage.bucket(bucket).deleteFiles({ prefix: `users/${uid}/books/${bookId}/`, force: true });
    const writer = db.bulkWriter();
    for (const snapshot of records) for (const document of snapshot.docs) writer.delete(document.ref);
    await writer.close();
    res.status(204).end();
  });
}
