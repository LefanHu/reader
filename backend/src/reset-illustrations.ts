import { FieldValue, Timestamp, type Firestore, type QueryDocumentSnapshot } from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import { refundReservation } from "./illustration-credits.js";

/**
 * Illustration-only schema-2 cutover. Removes every pre-schema-2 illustration
 * record and the owned `users/{uid}/books/{bookId}/` objects, never touching
 * users, tombstones, narration records (`narrationBooks`,
 * `narrationAccountTombstones`) or `users/{uid}/narration/` objects.
 *
 * Operator contract: apply only with illustration traffic stopped (maintenance)
 * and no schema-2 admissions yet. Every step is idempotent and classification is
 * re-read on each run, so an interrupted apply is finished by running it again.
 */
const COLLECTIONS = [
  "illustrationJobs", "illustrationJobInputs", "illustrationScenes",
  "creditReservations", "worldRevisions", "worldReferences",
] as const;

export interface ResetOptions {
  db: Firestore;
  storage: Pick<Storage, "bucket">;
  bucket: string;
  /** Destructive only when true; default is a read-only report. */
  apply?: boolean;
  /** Operator attestation that illustration traffic is stopped; required to apply. */
  maintenance?: boolean;
  now?: number;
}

export interface ResetReport {
  applied: boolean;
  /** Obsolete records per collection (`books` is live legacy registrations). */
  obsolete: Record<string, number>;
  /** Reasons apply was refused; non-empty means nothing was changed. */
  blockers: string[];
  refundedReservations: number;
  deletedObjectPrefixes: number;
}

const isCurrent = (snapshot: QueryDocumentSnapshot) => snapshot.data().schemaVersion === 2;
const leaseLive = (value: unknown, now: number) => value instanceof Timestamp && value.toMillis() > now;

export async function resetIllustrations(options: ResetOptions): Promise<ResetReport> {
  const { db, storage, bucket } = options;
  const now = options.now ?? Date.now();
  const snapshots = await Promise.all(COLLECTIONS.map(async name => [name, (await db.collection(name).get()).docs] as const));
  const obsolete: Record<string, QueryDocumentSnapshot[]> = {};
  const blockers: string[] = [];
  for (const [name, docs] of snapshots) {
    obsolete[name] = docs.filter(doc => !isCurrent(doc));
    // Admissions or reservations already in schema 2 mean the cutover has begun.
    if (name !== "worldRevisions" && name !== "worldReferences" && docs.some(isCurrent)) {
      blockers.push(`schema-2 ${name} exist; the reset must run before admissions`);
    }
    if (docs.some(doc => leaseLive(doc.data().leaseUntil, now) || leaseLive(doc.data().regenerationLeaseUntil, now))) {
      blockers.push(`${name} hold unexpired leases; wait for workers to drain`);
    }
  }
  const users = (await db.collection("users").get()).docs;
  const books: QueryDocumentSnapshot[] = [];
  for (const user of users) {
    for (const book of (await user.ref.collection("books").get()).docs) {
      // Tombstones carry no schema version and must survive.
      if (!isCurrent(book) && book.data().deleted !== true) books.push(book);
    }
  }
  obsolete.books = books;
  const report: ResetReport = {
    applied: false,
    obsolete: Object.fromEntries(Object.entries(obsolete).map(([name, docs]) => [name, docs.length])),
    blockers, refundedReservations: 0, deletedObjectPrefixes: 0,
  };
  if (!options.apply) return report;
  if (!options.maintenance) {
    report.blockers.push("--apply requires --maintenance");
    return report;
  }
  if (blockers.length) return report;

  // 1. Revoke claim tokens and regeneration intent so a late worker cannot publish.
  const revoked = db.bulkWriter();
  for (const doc of [...obsolete.illustrationJobs!, ...obsolete.illustrationScenes!]) {
    revoked.set(doc.ref, {
      claimToken: FieldValue.delete(), leaseUntil: FieldValue.delete(),
      regenerationToken: FieldValue.delete(), regenerationLeaseUntil: FieldValue.delete(),
      regenerationTarget: FieldValue.delete(), regenerationGenerationSpec: FieldValue.delete(),
    }, { merge: true });
  }
  await revoked.close();

  // 2. Refund each still-reserved hold exactly once (refundReservation is state-fenced).
  for (const reservation of obsolete.creditReservations!) {
    if (reservation.data().state !== "reserved") continue;
    await refundReservation(db, reservation.data().uid as string, reservation.ref);
    report.refundedReservations++;
  }

  // 3. Purge owned objects before records so an interrupted run still knows what to retry.
  const prefixes = new Set<string>();
  for (const doc of [...books, ...obsolete.illustrationJobs!, ...obsolete.illustrationScenes!, ...obsolete.worldReferences!]) {
    const uid = doc.data().uid ?? doc.ref.parent?.parent?.id;
    const bookId = doc.data().bookId ?? doc.id;
    if (typeof uid === "string" && typeof bookId === "string" && uid && bookId && !/[/]/.test(uid + bookId)) {
      prefixes.add(`users/${uid}/books/${bookId}/`);
    }
  }
  for (const prefix of prefixes) {
    await storage.bucket(bucket).deleteFiles({ prefix, force: true });
    report.deletedObjectPrefixes++;
  }

  // 4. Delete obsolete records, including legacy live registrations.
  const writer = db.bulkWriter();
  for (const docs of Object.values(obsolete)) for (const doc of docs) writer.delete(doc.ref);
  await writer.close();
  report.applied = true;
  return report;
}

/** CLI: `npm run reset:illustrations -- --project P --bucket B [--apply --maintenance]`. */
async function main() {
  const args = process.argv.slice(2);
  const value = (flag: string) => {
    const index = args.indexOf(flag);
    return index < 0 ? undefined : args[index + 1];
  };
  const project = value("--project"), bucket = value("--bucket");
  if (!project || !bucket) throw new Error("--project and --bucket are required.");
  const [{ initializeApp }, { getFirestore }, { Storage }] = await Promise.all([
    import("firebase-admin/app"), import("firebase-admin/firestore"), import("@google-cloud/storage"),
  ]);
  initializeApp({ projectId: project });
  const report = await resetIllustrations({
    db: getFirestore(), storage: new Storage({ projectId: project }), bucket,
    apply: args.includes("--apply"), maintenance: args.includes("--maintenance"),
  });
  console.log(JSON.stringify(report, null, 2));
  if (report.blockers.length) process.exitCode = 1;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(error => {
    console.error(error instanceof Error ? error.message : "Reset failed.");
    process.exitCode = 1;
  });
}
