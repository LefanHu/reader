import assert from "node:assert/strict";
import test from "node:test";
import { MemoryFirestore } from "./test-support/firestore.js";
import { purgeOwnedRecords } from "./owned-data.js";

test("purging pages through every owned record of one book and leaves other books and users", async () => {
  const memory = new MemoryFirestore();
  for (let n = 0; n < 1201; n++) memory.values.set(`bookAnalysisRecords/r${n}`, { uid: "owner", bookId: "book", recordType: "work" });
  memory.values.set("illustrationScenes/s", { uid: "owner", bookId: "book" });
  memory.values.set("illustrationScenes/other-book", { uid: "owner", bookId: "other" });
  memory.values.set("illustrationJobs/other-user", { uid: "someone", bookId: "book" });
  await purgeOwnedRecords(memory.firestore, { uid: "owner", bookId: "book" });
  assert.deepEqual([...memory.values.keys()].sort(), ["illustrationJobs/other-user", "illustrationScenes/other-book"]);
  await purgeOwnedRecords(memory.firestore, { uid: "owner" });
  assert.deepEqual([...memory.values.keys()], ["illustrationJobs/other-user"]);
});
