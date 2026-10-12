import { FieldValue, type Firestore } from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import { asyncRoute, HttpError, routeParam } from "./http.js";
import { bookReference } from "./fences.js";
import { registerOwnedBook } from "./book-registration.js";
import { refundReservation } from "./illustration-credits.js";
import { getIllustrationConfiguration, requireIllustrationProfile, requireIllustrationSchema } from "./illustration-configuration.js";

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
    requireIllustrationSchema(req.body.schemaVersion);
    const configuration = getIllustrationConfiguration();
    if (!configuration.enabled || !configuration.providers.some(provider => provider.available)) {
      throw new HttpError(503, "Illustrations are currently unavailable.");
    }
    const { bookId, chapterCount, extension: profile } = await registerOwnedBook({
      db, uid, metadata: req.body,
      extendTransaction: async (transaction, existingBook) => {
        const userRef = db.collection("users").doc(uid);
        const user = await transaction.get(userRef);
        const profile = existingBook?.profile ? requireIllustrationProfile(existingBook.profile) : undefined;
        if (user.data()?.creditsRemaining === undefined) {
          transaction.set(userRef, {
            creditsRemaining: pilotCredits,
            updatedAt: FieldValue.serverTimestamp(),
          }, { merge: true });
        }
        return profile;
      },
    });
    const styles = stylesFor(req.body.title);
    res.json({
      id: bookId,
      schemaVersion: 2,
      configuration,
      ...(profile ? { currentProfile: profile } : {}),
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
    const bookRef = bookReference(db, "books", uid, bookId);
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
      db.collection("bookAnalysisJobs").where("uid", "==", uid).where("bookId", "==", bookId).get(),
      db.collection("bookAnalysisRecords").where("uid", "==", uid).where("bookId", "==", bookId).get(),
      db.collection("bookAnalysisInputs").where("uid", "==", uid).where("bookId", "==", bookId).get(),
    ]);
    // Deletion owns releasing reservations; a fenced late worker cannot refund.
    for (const reservation of records[3]!.docs) await refundReservation(db, uid, reservation.ref);
    await storage.bucket(bucket).deleteFiles({ prefix: `users/${uid}/books/${bookId}/`, force: true });
    const writer = db.bulkWriter();
    for (const snapshot of records) for (const document of snapshot.docs) writer.delete(document.ref);
    await writer.close();
    res.status(204).end();
  });
}
