import assert from "node:assert/strict";
import test from "node:test";
import express from "express";
import type { Firestore } from "firebase-admin/firestore";
import { accountUsageRouter, authenticateAccount } from "./account.js";
import { narrationMonthCounterId } from "./narration.js";

/** Read-only double deliberately has no mutation or generation methods. */
class Database {
  values = new Map<string, Record<string, unknown>>();
  reads: string[] = [];
  collection(collection: string) {
    return { doc: (id: string) => ({ get: async () => {
      const path = `${collection}/${id}`;
      this.reads.push(path);
      return { data: () => this.values.get(path) };
    } }) };
  }
}
async function fixture(action: (url: string, db: Database) => Promise<void>, enabled = false) {
  const db = new Database();
  const app = express();
  app.use("/v1", authenticateAccount(async token => {
    if (token !== "valid") throw new Error("invalid identity");
    return { uid: "owner" };
  }, async token => { if (token !== "valid") throw new Error("invalid attestation"); }));
  app.use("/v1/account", accountUsageRouter({ db: db as unknown as Firestore,
    now: () => new Date("2026-12-31T23:59:59.999Z"), narrationEnabled: enabled,
    illustrationsEnabled: enabled, env: { NARRATION_MONTHLY_CHARACTERS: "500" } }));
  app.use((_error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => res.status(500).end());
  const server = app.listen(0, "127.0.0.1");
  await new Promise<void>(resolve => server.on("listening", resolve));
  try { await action(`http://127.0.0.1:${(server.address() as { port: number }).port}/v1/account/usage`, db); }
  finally { await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())); }
}
const headers = { authorization: "Bearer valid", "x-firebase-appcheck": "valid" };
const monthPath = `narrationUsage/${narrationMonthCounterId("owner", new Date("2026-12-01T00:00:00Z"))}`;

test("usage rejects invalid identity and attestation before database reads", async () => {
  await fixture(async (url, db) => {
    const credentials: Record<string, string>[] = [{}, { authorization: "Bearer valid" },
      { ...headers, authorization: "Bearer invalid" }, { ...headers, "x-firebase-appcheck": "invalid" }];
    for (const credential of credentials) assert.equal((await fetch(url, { headers: credential })).status, 401);
    assert.equal(db.reads.length, 0);
  });
});
test("usage reads token owner, includes reservations, and resets at next UTC year", async () => {
  await fixture(async (url, db) => {
    db.values.set(monthPath, { used: 150 });
    db.values.set("users/owner", { creditsRemaining: 20, creditsReserved: 3 });
    db.values.set("users/other", { creditsRemaining: 1000 });
    const before = [...db.values];
    const response = await fetch(`${url}?uid=other`, { headers });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.deepEqual(await response.json(), { asOf: "2026-12-31T23:59:59.999Z", narrationEnabled: true,
      narrationMonthlyLimit: 500, narrationRemaining: 350, narrationResetAt: "2027-01-01T00:00:00.000Z",
      illustrationsEnabled: true, illustrationCreditsRemaining: 20, illustrationCreditsReserved: 3 });
    assert.deepEqual([...db.values], before);
    assert(!db.reads.includes("users/other"));
  }, true);
});
test("disabled features report unactivated credits without initializing records", async () => {
  await fixture(async (url, db) => {
    const body = await (await fetch(url, { headers })).json() as Record<string, unknown>;
    assert.equal(body.narrationEnabled, false);
    assert.equal(body.illustrationsEnabled, false);
    assert.equal(body.narrationRemaining, 500);
    assert.equal(body.illustrationCreditsRemaining, null);
    assert.equal(body.illustrationCreditsReserved, null);
    assert.equal(db.values.size, 0);
  });
});
test("over-limit balances clamp to zero and corrupt counters fail closed", async () => {
  await fixture(async (url, db) => {
    db.values.set(monthPath, { used: 1000 });
    assert.equal((await (await fetch(url, { headers })).json() as Record<string, unknown>).narrationRemaining, 0);
    db.values.set(monthPath, { used: -1 });
    assert.equal((await fetch(url, { headers })).status, 500);
  });
});
