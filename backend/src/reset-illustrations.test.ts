import assert from "node:assert/strict";
import test from "node:test";
import { Timestamp } from "firebase-admin/firestore";
import { MemoryFirestore } from "./test-support/firestore.js";
import { resetIllustrations } from "./reset-illustrations.js";

function storageDouble() {
  const prefixes: string[] = [];
  const storage = { bucket: () => ({ deleteFiles: async ({ prefix }: { prefix: string }) => { prefixes.push(prefix); } }) };
  return { prefixes, storage: storage as unknown as Parameters<typeof resetIllustrations>[0]["storage"] };
}

function seedLegacy(memory: MemoryFirestore) {
  const v = memory.values;
  v.set("users/u", { creditsRemaining: 5, creditsReserved: 1 });
  v.set("users/u/books/old", { uid: "u", title: "Old", profile: { style: "Ink" } });
  v.set("users/u/books/tomb", { uid: "u", deleted: true });
  v.set("illustrationJobs/j", { uid: "u", bookId: "old", status: "analyzing", claimToken: "t", leaseUntil: Timestamp.fromMillis(1) });
  v.set("illustrationJobInputs/j", { uid: "u", bookId: "old" });
  v.set("illustrationScenes/s", { uid: "u", bookId: "old", status: "regenerating", regenerationToken: "r", regenerationTarget: 2 });
  v.set("creditReservations/r1", { uid: "u", bookId: "old", state: "reserved" });
  v.set("creditReservations/r2", { uid: "u", bookId: "old", state: "committed" });
  v.set("worldRevisions/w", { uid: "u", bookId: "old" });
  v.set("worldReferences/w", { uid: "u", bookId: "old" });
  v.set("narrationBooks/n", { uid: "u" });
  v.set("narrationAccountTombstones/other", { deleted: true });
}

test("dry run reports obsolete state and changes nothing", async () => {
  const memory = new MemoryFirestore();
  seedLegacy(memory);
  const before = new Map(memory.values);
  const { storage, prefixes } = storageDouble();
  const report = await resetIllustrations({ db: memory.firestore, storage, bucket: "b" });
  assert.equal(report.applied, false);
  assert.equal(report.obsolete.illustrationJobs, 1);
  assert.equal(report.obsolete.books, 1);
  assert.deepEqual(memory.values, before);
  assert.deepEqual(prefixes, []);
});

test("apply requires maintenance and refuses schema-2 admissions or live leases", async () => {
  const memory = new MemoryFirestore();
  seedLegacy(memory);
  const { storage } = storageDouble();
  assert((await resetIllustrations({ db: memory.firestore, storage, bucket: "b", apply: true })).blockers.includes("--apply requires --maintenance"));
  memory.values.set("illustrationJobs/new", { schemaVersion: 2, uid: "u", status: "queued" });
  const blocked = await resetIllustrations({ db: memory.firestore, storage, bucket: "b", apply: true, maintenance: true });
  assert.equal(blocked.applied, false);
  assert(blocked.blockers.some(item => item.includes("schema-2 illustrationJobs")));
  memory.values.delete("illustrationJobs/new");
  const live = await resetIllustrations({ db: memory.firestore, storage, bucket: "b", apply: true, maintenance: true, now: 0 });
  assert(live.blockers.some(item => item.includes("unexpired leases")));
  assert(memory.values.has("illustrationJobs/j"));
});

test("apply purges illustration state, refunds once, preserves narration and tombstones, and restarts", async () => {
  const memory = new MemoryFirestore();
  seedLegacy(memory);
  const { storage, prefixes } = storageDouble();
  const options = { db: memory.firestore, storage, bucket: "b", apply: true, maintenance: true, now: 10 };
  const report = await resetIllustrations(options);
  assert.equal(report.applied, true);
  assert.equal(report.refundedReservations, 1);
  for (const path of ["illustrationJobs/j", "illustrationJobInputs/j", "illustrationScenes/s", "creditReservations/r1",
    "creditReservations/r2", "worldRevisions/w", "worldReferences/w", "users/u/books/old"]) assert(!memory.values.has(path), path);
  for (const path of ["users/u", "users/u/books/tomb", "narrationBooks/n", "narrationAccountTombstones/other"]) assert(memory.values.has(path), path);
  assert.equal(memory.values.get("users/u")!.creditsReserved, 0);
  assert.equal(memory.values.get("users/u")!.creditsRemaining, 5);
  assert.deepEqual([...new Set(prefixes)], ["users/u/books/old/"]);
  assert(prefixes.every(prefix => !prefix.includes("narration")));
  // A rerun after completion is a no-op and never refunds again.
  const again = await resetIllustrations(options);
  assert.equal(again.refundedReservations, 0);
  assert.equal(memory.values.get("users/u")!.creditsReserved, 0);
});
