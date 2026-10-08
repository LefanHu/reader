import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { EventEmitter } from "node:events";
import express from "express";
import type { Firestore } from "firebase-admin/firestore";
import { Timestamp } from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import {
  NarrationBackend,
  NarrationError,
  narrationLimits,
  validateNarrationInput,
  narrationMonthCounterId,
} from "./narration.js";
import {
  RealtimeNarrationProvider,
  narrationTranscript,
  narrationWav,
} from "./narration-provider.js";
import {
  accountDeletionRouter,
  authenticateAccount,
  type AccountRequest,
} from "./account.js";

const hash = (value: string) =>
  createHash("sha256").update(value).digest("hex");
const input = (text = "Hello 👩🏽‍🚀.") => ({
  text,
  digest: hash(text),
  chunkId: hash("anchor"),
  voice: "marin",
  documentVersion: 1,
  chunkVersion: 1,
});

/** Transactional in-memory Firestore double exercises worker claims without cloud writes. */
class Database {
  values = new Map<string, Record<string, any>>();
  private tail = Promise.resolve();
  collection(path: string) {
    return new Collection(this, path);
  }
  async runTransaction<T>(action: (tx: any) => Promise<T>): Promise<T> {
    const pending: Array<() => void> = [];
    const result = this.tail.then(async () => {
      const value = await action({
        get: (ref: Reference) => ref.get(),
        set: (ref: Reference, data: any, options?: any) =>
          pending.push(() => ref.write(data, options?.merge)),
        create: (ref: Reference, data: any) =>
          pending.push(() => {
            assert(!this.values.has(ref.path));
            ref.write(data);
          }),
        update: (ref: Reference, data: any) =>
          pending.push(() => ref.write(data, true)),
        delete: (ref: Reference) =>
          pending.push(() => this.values.delete(ref.path)),
      });
      pending.forEach((operation) => operation());
      return value;
    });
    this.tail = result.then(
      () => {},
      () => {},
    );
    return result;
  }
  /** Queue deletes until close so purge tests require awaited durable completion. */
  bulkWriter() {
    const pending: Reference[] = [];
    return {
      delete: (ref: Reference) => {
        pending.push(ref);
        return Promise.resolve();
      },
      close: async () => {
        for (const ref of pending) await ref.delete();
      },
    };
  }
  /** Account deletion removes the user document and all nested book tombstones. */
  async recursiveDelete(ref: Reference) {
    for (const path of this.values.keys())
      if (path === ref.path || path.startsWith(`${ref.path}/`))
        this.values.delete(path);
  }
}
class Reference {
  constructor(
    readonly db: Database,
    readonly path: string,
  ) {}
  get id() {
    return this.path.split("/").at(-1)!;
  }
  collection(path: string) {
    return this.db.collection(`${this.path}/${path}`);
  }
  async get() {
    const data = this.db.values.get(this.path);
    return {
      exists: Boolean(data),
      id: this.id,
      ref: this,
      data: () => data && { ...data },
    };
  }
  write(data: Record<string, any>, merge = false) {
    const value = merge ? { ...this.db.values.get(this.path) } : {};
    for (const [key, field] of Object.entries(data)) {
      if (field?.constructor?.name === "DeleteTransform") delete value[key];
      else if (field?.constructor?.name === "NumericIncrementTransform")
        value[key] = Number(value[key] ?? 0) + field.operand;
      else if (field?.constructor?.name === "ServerTimestampTransform")
        value[key] = Timestamp.now();
      else value[key] = field;
    }
    this.db.values.set(this.path, value);
  }
  async set(data: any, options?: any) {
    this.write(data, options?.merge);
  }
  async delete() {
    this.db.values.delete(this.path);
  }
}
class Collection {
  constructor(
    readonly db: Database,
    readonly path: string,
    readonly filters: Array<[string, string, unknown]> = [],
    readonly max = Infinity,
  ) {}
  doc(id: string) {
    return new Reference(this.db, `${this.path}/${id}`);
  }
  where(key: string, op: string, value: unknown) {
    return new Collection(
      this.db,
      this.path,
      [...this.filters, [key, op, value]],
      this.max,
    );
  }
  limit(value: number) {
    return new Collection(this.db, this.path, this.filters, value);
  }
  async get() {
    const docs = [];
    for (const [path, data] of this.db.values) {
      if (
        path.startsWith(`${this.path}/`) &&
        !path.slice(this.path.length + 1).includes("/") &&
        this.filters.every(([key, op, value]) =>
          op === "<"
            ? data[key].toMillis() < (value as Timestamp).toMillis()
            : data[key] === value,
        )
      )
        docs.push(await new Reference(this.db, path).get());
    }
    return { docs: docs.slice(0, this.max) };
  }
}

async function harness(enabled = true) {
  const db = new Database(),
    objects = new Set<string>(),
    tasks: string[] = [];
  let providerCalls = 0;
  let generate = async (
    _text: string,
    _voice: string,
    submitted: () => Promise<void>,
  ) => {
    await submitted();
    return narrationWav(Buffer.alloc(100));
  };
  const backend = new NarrationBackend({
    db: db as unknown as Firestore,
    bucket: "private",
    enabled,
    enqueue: async (_path, _payload, id) => {
      tasks.push(id);
    },
    provider: {
      generate: async (...args) => {
        providerCalls++;
        return generate(...args);
      },
    },
    storage: {
      bucket: () => ({
        file: (path: string) => ({
          save: async () => {
            objects.add(path);
          },
          delete: async () => {
            objects.delete(path);
          },
          getSignedUrl: async () => [`https://private.test/${path}`],
        }),
        deleteFiles: async ({ prefix }: { prefix: string }) => {
          for (const key of objects)
            if (key.startsWith(prefix)) objects.delete(key);
        },
      }),
    } as unknown as Storage,
  });
  const app = express();
  app.use(express.json());
  app.use("/v1/narration", (req: AccountRequest, res, next) => {
    if (!req.header("authorization") || !req.header("x-firebase-appcheck")) {
      res.status(401).end();
      return;
    }
    req.uid = req.header("authorization");
    next();
  });
  app.use("/v1/narration", backend.api());
  app.use(
    "/v1/account",
    authenticateAccount(
      async (token) => {
        if (token === "verified-user") return { uid: "user" };
        if (token === "verified-other") return { uid: "other" };
        throw new Error("Invalid identity token");
      },
      async (token) => {
        if (token !== "verified-app") throw new Error("Invalid App Check token");
      },
    ),
    accountDeletionRouter({
      db: db as unknown as Firestore,
      storage: backend.dependencies.storage,
      bucket: "private",
      narration: backend,
    }),
  );
  app.use((error: any, _req: any, res: any, _next: any) =>
    res
      .status(error instanceof NarrationError ? error.status : 500)
      .json({ error: error.message }),
  );
  const server = app.listen(0, "127.0.0.1");
  await new Promise<void>((resolve) => server.on("listening", resolve));
  const address = server.address() as { port: number };
  const request = async (
    path: string,
    method = "GET",
    body?: any,
    uid = "user",
  ) => {
    const response = await fetch(
      `http://127.0.0.1:${address.port}/v1/narration${path}`,
      {
        method,
        headers: {
          authorization: uid,
          "x-firebase-appcheck": "verified",
          "content-type": "application/json",
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      },
    );
    return {
      status: response.status,
      body: response.status === 204 ? {} : ((await response.json()) as any),
    };
  };
  /** Exercise the common HTTP route with identity supplied only by verified tokens. */
  const accountRequest = async (options: {
    token?: string | null;
    appCheck?: string | null;
    query?: string;
    body?: unknown;
  } = {}) => {
    const headers: Record<string, string> = { "content-type": "application/json" };
    const token = options.token === undefined ? "verified-user" : options.token;
    const appCheck = options.appCheck === undefined ? "verified-app" : options.appCheck;
    if (token !== null) headers.authorization = `Bearer ${token}`;
    if (appCheck !== null) headers["x-firebase-appcheck"] = appCheck;
    const response = await fetch(
      `http://127.0.0.1:${address.port}/v1/account${options.query ?? ""}`,
      {
        method: "DELETE",
        headers,
        body: options.body === undefined ? undefined : JSON.stringify(options.body),
      },
    );
    const body: unknown = response.status === 204 ? {} : await response.json();
    return {
      status: response.status,
      body,
    };
  };
  const book = async () =>
    (
      await request("/books", "POST", {
        fingerprint: hash("book"),
        consentVersion: 1,
      })
    ).body.id as string;
  return {
    db,
    backend,
    objects,
    tasks,
    request,
    accountRequest,
    book,
    calls: () => providerCalls,
    provider: (callback: typeof generate) => {
      generate = callback;
    },
    close: () =>
      new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      ),
  };
}

/** Stable identities used to check complete purge and retained shared accounting. */
interface AccountPurgeFixture {
  book: string;
  queued: string;
  submitted: string;
  other: string;
  day: string;
  month: string;
  otherMonth: string;
}

/** Owner reservations share daily accounting with a user whose data must survive. */
function accountPurgeFixture(db: Database, objects: Set<string>): AccountPurgeFixture {
  const book = hash("purged book"),
    queued = hash("orphan queued job"),
    submitted = hash("submitted job"),
    other = hash("other job"),
    day = new Date().toISOString().slice(0, 10),
    month = narrationMonthCounterId("user", new Date()),
    otherMonth = narrationMonthCounterId("other", new Date());
  db.values.set(`users/user/narrationBooks/${book}`, { uid: "user" });
  db.values.set("users/user", { creditsRemaining: 20 });
  db.values.set("users/other", { creditsRemaining: 30 });
  db.values.set(`narrationUsage/${month}`, { uid: "user", used: 12 });
  db.values.set(
    `narrationUsage/${narrationMonthCounterId("user", new Date("2025-01-01T00:00:00Z"))}`,
    { uid: "user", used: 17 },
  );
  db.values.set(`narrationUsage/${otherMonth}`, { uid: "other", used: 11 });
  db.values.set(`narrationDailyUsage/${day}`, { used: 23 });
  for (const [id, uid, bookId, characters, wasSubmitted] of [
    [queued, "user", hash("missing book"), 5, false],
    [submitted, "user", book, 7, true],
    [other, "other", hash("other book"), 11, true],
  ] as const) {
    db.values.set(`narrationJobs/${id}`, {
      uid,
      bookId,
      characters,
      reserved: true,
      submitted: wasSubmitted,
      status: wasSubmitted ? "generating" : "queued",
      monthCounter: uid === "user" ? month : otherMonth,
      dayCounter: day,
      voice: "marin",
      attempts: 0,
    });
    db.values.set(`narrationInputs/${id}`, {
      uid,
      text: "x".repeat(characters),
      expiresAt: Timestamp.fromMillis(Date.now() + 86400000),
    });
  }
  db.values.set("narrationInputs/orphan-without-job", { uid: "user" });
  objects.add(`users/user/narration/${book}/cached.wav`);
  objects.add("users/other/narration/cached.wav");
  return { book, queued, submitted, other, day, month, otherMonth };
}

function assertAccountNarrationPurged(
  db: Database,
  objects: Set<string>,
  fixture: AccountPurgeFixture,
) {
  for (const [path, value] of db.values)
    if (/^(narrationJobs|narrationInputs|narrationUsage)\//.test(path))
      assert.notEqual(value.uid, "user", `owner record retained: ${path}`);
  assert(db.values.has("narrationAccountTombstones/user"));
  assert.equal(db.values.get(`narrationDailyUsage/${fixture.day}`)?.used, 18);
  assert.equal(db.values.get(`narrationUsage/${fixture.otherMonth}`)?.used, 11);
  assert(db.values.has(`narrationJobs/${fixture.other}`));
  assert(db.values.has(`narrationInputs/${fixture.other}`));
  assert(objects.has("users/other/narration/cached.wav"));
  assert(!objects.has(`users/user/narration/${fixture.book}/cached.wav`));
}

test("account deletion purges narration state without refunding submitted units", async () => {
  const app = await harness();
  try {
    const fixture = accountPurgeFixture(app.db, app.objects);
    await app.backend.deleteAccount("user");
    assertAccountNarrationPurged(app.db, app.objects, fixture);
  } finally {
    await app.close();
  }
});

test("account HTTP deletion stays available with rollout disabled and ignores spoofed UIDs", async () => {
  const app = await harness(false);
  try {
    const fixture = accountPurgeFixture(app.db, app.objects);
    const collections = [
      "illustrationScenes",
      "illustrationJobs",
      "illustrationJobInputs",
      "creditReservations",
      "worldRevisions",
      "worldReferences",
    ];
    for (const collection of collections) {
      app.db.values.set(`${collection}/owner`, { uid: "user" });
      app.db.values.set(`${collection}/other`, { uid: "other" });
    }
    app.db.values.set("users/user/nested/private", { private: true });
    app.db.values.set("users/other/nested/private", { private: true });
    app.objects.add("users/user/narration/orphan/cached.wav");
    app.objects.add("users/user/illustrations/image.png");
    app.objects.add("users/other/illustrations/image.png");

    assert.equal(
      (await app.accountRequest({ query: "?uid=other", body: { uid: "other" } })).status,
      204,
    );
    assertAccountNarrationPurged(app.db, app.objects, fixture);
    for (const collection of collections) {
      assert(!app.db.values.has(`${collection}/owner`));
      assert.deepEqual(app.db.values.get(`${collection}/other`), { uid: "other" });
    }
    assert(![...app.db.values.keys()].some((path) =>
      path === "users/user" || path.startsWith("users/user/")));
    assert.deepEqual(app.db.values.get("users/other"), { creditsRemaining: 30 });
    assert(app.db.values.has("users/other/nested/private"));
    assert(![...app.objects].some((path) => path.startsWith("users/user/")));
    assert(app.objects.has("users/other/illustrations/image.png"));
    assert.equal(app.calls(), 0);

    const remaining = JSON.stringify([...app.db.values].filter(([path]) =>
      path !== "narrationAccountTombstones/user"));
    assert.equal((await app.accountRequest()).status, 204);
    assert.equal(JSON.stringify([...app.db.values].filter(([path]) =>
      path !== "narrationAccountTombstones/user")), remaining);
    assertAccountNarrationPurged(app.db, app.objects, fixture);
  } finally {
    await app.close();
  }
});

test("account HTTP deletion rejects missing or invalid credentials without mutations", async () => {
  const app = await harness();
  try {
    accountPurgeFixture(app.db, app.objects);
    const records = JSON.stringify([...app.db.values]),
      objects = [...app.objects];
    for (const credentials of [
      { token: null },
      { token: "" },
      { token: "unverified-user" },
      { appCheck: null },
      { appCheck: "invalid-app" },
    ]) {
      const response = await app.accountRequest({
        ...credentials,
        query: "?uid=user",
        body: { uid: "user" },
      });
      assert.equal(response.status, 401);
      assert.deepEqual(response.body, {
        error: "Authentication and App Check are required.",
      });
      assert.equal(JSON.stringify([...app.db.values]), records);
      assert.deepEqual([...app.objects], objects);
    }
    assert.equal(app.calls(), 0);
  } finally {
    await app.close();
  }
});

test("account HTTP deletion preserves accounting on release failure for a safe retry", async () => {
  const app = await harness();
  const transact = app.db.runTransaction.bind(app.db);
  try {
    const fixture = accountPurgeFixture(app.db, app.objects);
    // Without a book record, both jobs are discovered only by the UID purge.
    app.db.values.delete(`users/user/narrationBooks/${fixture.book}`);
    app.db.runTransaction = async () => {
      throw new Error("reservation release failed");
    };
    const response = await app.accountRequest();
    assert.equal(response.status, 500);
    assert.deepEqual(response.body, { error: "reservation release failed" });
    assert(app.db.values.has("narrationAccountTombstones/user"));
    assert.equal(app.db.values.get(`narrationUsage/${fixture.month}`)?.used, 12);
    assert.equal(app.db.values.get(`narrationDailyUsage/${fixture.day}`)?.used, 23);
    assert.equal(app.db.values.get(`narrationJobs/${fixture.queued}`)?.reserved, true);
    assert(app.db.values.has(`narrationInputs/${fixture.queued}`));
    assert(app.objects.has(`users/user/narration/${fixture.book}/cached.wav`));

    app.db.runTransaction = transact;
    assert.equal((await app.accountRequest()).status, 204);
    assertAccountNarrationPurged(app.db, app.objects, fixture);
    assert(![...app.objects].some((path) => path.startsWith("users/user/")));
  } finally {
    app.db.runTransaction = transact;
    await app.close();
  }
});

test("account HTTP deletion fences a submitted provider completion released after purge", async () => {
  const app = await harness();
  let release!: () => void;
  let running: Promise<void> | undefined;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  try {
    const fixture = accountPurgeFixture(app.db, app.objects);
    // The existing seven-unit reservation is submitted by the real worker.
    const job = app.db.values.get(`narrationJobs/${fixture.submitted}`)!;
    job.submitted = false;
    job.status = "queued";
    let started!: () => void;
    const starting = new Promise<void>((resolve) => { started = resolve; });
    app.provider(async (_text, _voice, submit) => {
      await submit();
      started();
      await gate;
      return narrationWav(Buffer.alloc(100));
    });
    running = app.backend.run(fixture.submitted);
    await starting;
    assert.equal(app.db.values.get(`narrationDailyUsage/${fixture.day}`)?.used, 23);
    assert.equal((await app.accountRequest()).status, 204);
    assertAccountNarrationPurged(app.db, app.objects, fixture);
    release();
    await running;
    assertAccountNarrationPurged(app.db, app.objects, fixture);
    assert(![...app.objects].some((path) => path.startsWith("users/user/")));
    assert(![...app.db.values.keys()].some((path) =>
      path === "users/user" || path.startsWith("users/user/")));
    assert.equal(app.calls(), 1);
    assert.equal((await app.accountRequest()).status, 204);
    assertAccountNarrationPurged(app.db, app.objects, fixture);
  } finally {
    release();
    await running;
    await app.close();
  }
});

test("bounded Unicode input validates UTF-16 counts and exact text digests", () => {
  assert.equal(validateNarrationInput(input()).text.length, 14);
  for (const value of [
    {},
    input("x".repeat(3001)),
    input("\uD800"),
    { ...input(), digest: hash("wrong") },
    { ...input(), voice: "unknown" },
    { ...input(), documentVersion: 2 },
    input("\0"),
  ])
    assert.throws(() => validateNarrationInput(value));
  assert.equal(narrationTranscript("Hello,\nworld!"), "Hello world");
  assert.notEqual(
    narrationTranscript("Hello world"),
    narrationTranscript("world Hello"),
  );
  assert.notEqual(
    narrationTranscript("Hello"),
    narrationTranscript("Hello added"),
  );
  assert.equal(narrationLimits({}).monthly, 500000);
  assert.equal(narrationLimits({}).daily, 200000);
  assert.throws(() => narrationLimits({ NARRATION_DAILY_CHARACTERS: "NaN" }));
});

test("WAV output is 24 kHz mono and rejects empty or malformed PCM", () => {
  const wav = narrationWav(Buffer.alloc(100));
  assert.equal(wav.readUInt32LE(24), 24000);
  assert.equal(wav.readUInt16LE(22), 1);
  assert.equal(wav.readUInt32LE(40), 100);
  assert.throws(() => narrationWav(Buffer.alloc(0)));
  assert.throws(() => narrationWav(Buffer.alloc(1)));
});

test("narration rollout is independent; deletion stays available when disabled", async () => {
  const app = await harness(false);
  try {
    assert.equal((await app.request("/config")).body.enabled, false);
    assert.equal(
      (
        await app.request("/books", "POST", {
          fingerprint: hash("book"),
          consentVersion: 1,
        })
      ).status,
      503,
    );
    assert.equal(
      (await app.request(`/books/${hash("deleted")}`, "DELETE")).status,
      204,
    );
    assert.equal(app.calls(), 0);
  } finally {
    await app.close();
  }
});

test("registration requires consent and does not create illustration credit records", async () => {
  const app = await harness();
  try {
    assert.equal(
      (await app.request("/books", "POST", { fingerprint: hash("book") }))
        .status,
      400,
    );
    await app.book();
    assert(!app.db.values.has("users/user"));
  } finally {
    await app.close();
  }
});

test("jobs require ownership and validate input; duplicate creation reserves allowance once", async () => {
  const app = await harness();
  try {
    const id = await app.book();
    assert.equal(
      (await app.request(`/books/${id}/jobs`, "POST", input(), "other")).status,
      410,
    );
    assert.equal(
      (await app.request(`/books/${id}/jobs`, "POST", {})).status,
      400,
    );
    const first = await app.request(`/books/${id}/jobs`, "POST", input());
    const second = await app.request(`/books/${id}/jobs`, "POST", input());
    assert.equal(first.body.id, second.body.id);
    assert.equal(
      (await app.request("/config")).body.remaining,
      500000 - input().text.length,
    );
    assert.equal(
      (await app.request(`/jobs/${first.body.id}`, "GET", undefined, "other"))
        .status,
      404,
    );
    await app.backend.run(first.body.id);
    await app.backend.run(first.body.id);
    assert.equal(app.calls(), 1);
    assert.equal(
      (await app.request(`/jobs/${first.body.id}`)).body.status,
      "ready",
    );
    assert.equal(app.db.values.has(`narrationInputs/${first.body.id}`), false);
  } finally {
    await app.close();
  }
});

test("failure before submission releases allowance; submitted failures retain consumed units", async () => {
  for (const submitted of [false, true]) {
    const app = await harness();
    try {
      const id = await app.book(),
        job = (await app.request(`/books/${id}/jobs`, "POST", input())).body.id;
      app.provider(async (_text, _voice, submit) => {
        if (submitted) await submit();
        throw new Error("provider failure");
      });
      await app.backend.run(job);
      assert.equal(
        (await app.request("/config")).body.remaining,
        500000 - (submitted ? input().text.length : 0),
      );
      assert.equal(app.db.values.get(`narrationJobs/${job}`)?.status, "failed");
      assert(!app.db.values.has(`narrationInputs/${job}`));
    } finally {
      await app.close();
    }
  }
});

test("worker claims reject duplicate concurrent tasks and deletion fences late publication", async () => {
  const app = await harness();
  try {
    const id = await app.book(),
      job = (await app.request(`/books/${id}/jobs`, "POST", input())).body.id;
    let release!: () => void, started!: () => void;
    const starting = new Promise<void>((resolve) => {
      started = resolve;
    });
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    app.provider(async (_text, _voice, submit) => {
      await submit();
      started();
      await gate;
      return narrationWav(Buffer.alloc(100));
    });
    const running = app.backend.run(job);
    await starting;
    await assert.rejects(
      app.backend.run(job),
      (error: any) => error.status === 409,
    );
    await app.backend.deleteBook("user", id);
    release();
    await running;
    assert.equal(app.objects.size, 0);
    assert.equal(app.db.values.get(`narrationJobs/${job}`)?.status, "deleted");
    assert.equal(
      (await app.request(`/books/${id}/jobs`, "POST", input())).status,
      410,
    );
  } finally {
    await app.close();
  }
});

test("expired cloud audio is never delivered and abandoned input releases unsubmitted allowance", async () => {
  const app = await harness();
  try {
    const id = await app.book(),
      job = (await app.request(`/books/${id}/jobs`, "POST", input())).body.id;
    app.db.values.get(`narrationInputs/${job}`)!.expiresAt =
      Timestamp.fromMillis(0);
    await app.backend.run(job);
    assert.equal(app.calls(), 0);
    assert.equal((await app.request("/config")).body.remaining, 500000);
    const other = (
      await app.request(`/books/${id}/jobs`, "POST", input("Second."))
    ).body.id;
    await app.backend.run(other);
    app.db.values.get(`narrationJobs/${other}`)!.expiresAt =
      Timestamp.fromMillis(0);
    assert.equal((await app.request(`/jobs/${other}`)).body.status, "expired");
    await app.backend.deleteAccount("user");
    assert.equal(app.objects.size, 0);
    assert.equal(
      (
        await app.request("/books", "POST", {
          fingerprint: hash("new"),
          consentVersion: 1,
        })
      ).status,
      410,
    );
  } finally {
    await app.close();
  }
});

/** Fake provider socket inspects the isolated response contract and injects events. */
class ProviderSocket extends EventEmitter {
  requests: any[] = [];
  closed = false;
  send(value: string) {
    this.requests.push(JSON.parse(value));
  }
  close() {
    this.closed = true;
  }
  event(value: any) {
    this.emit("message", Buffer.from(JSON.stringify(value)));
  }
}

test("provider publishes only matching, successfully completed narration and uses no tools", async () => {
  process.env.OPENAI_API_KEY = "test-only";
  try {
    for (const transcript of [
      "Hello world.",
      "world Hello",
      "Hello",
      "Hello world added",
      "Helloworld",
    ]) {
      const socket = new ProviderSocket();
      let submitted = 0;
      const provider = new RealtimeNarrationProvider(() => socket as any);
      const generated = provider.generate("Hello world.", "marin", async () => {
        submitted++;
      });
      socket.emit("open");
      socket.event({ type: "session.updated" });
      await new Promise((resolve) => setImmediate(resolve));
      assert.equal(socket.requests[1].response.conversation, "none");
      assert.equal(socket.requests[1].response.tool_choice, "none");
      assert.deepEqual(socket.requests[1].response.tools, []);
      assert.equal(
        socket.requests[1].response.input[0].content[0].text,
        "Hello world.",
      );
      socket.event({
        type: "response.output_audio.delta",
        delta: Buffer.alloc(100).toString("base64"),
      });
      socket.event({
        type: "response.output_audio_transcript.delta",
        delta: transcript,
      });
      socket.event({
        type: "response.done",
        response: { status: "completed" },
      });
      if (transcript === "Hello world.")
        assert.equal((await generated).readUInt32LE(24), 24000);
      else await assert.rejects(generated);
      assert.equal(submitted, 1);
      assert(socket.closed);
    }
    for (const status of ["failed", "incomplete", "cancelled"]) {
      const socket = new ProviderSocket();
      const generated = new RealtimeNarrationProvider(
        () => socket as any,
      ).generate("Hello", "cedar", async () => {});
      socket.event({
        type: "response.output_audio.delta",
        delta: Buffer.alloc(100).toString("base64"),
      });
      socket.event({
        type: "response.output_audio_transcript.delta",
        delta: "Hello",
      });
      socket.event({ type: "response.done", response: { status } });
      await assert.rejects(generated);
    }
    const socket = new ProviderSocket();
    await assert.rejects(
      new RealtimeNarrationProvider(() => socket as any, 5).generate(
        "Hello",
        "marin",
        async () => {},
      ),
    );
    assert(socket.closed);
  } finally {
    delete process.env.OPENAI_API_KEY;
  }
});

test("failed provider retries consume new allowance and are bounded", async () => {
  const app = await harness();
  try {
    const id = await app.book();
    app.provider(async (_text, _voice, submit) => {
      await submit();
      throw new Error("transcript mismatch");
    });
    for (let attempt = 0; attempt < 2; attempt++) {
      const job = (await app.request(`/books/${id}/jobs`, "POST", input())).body
        .id;
      await app.backend.run(job);
    }
    assert.equal(app.calls(), 2);
    assert.equal(
      (await app.request("/config")).body.remaining,
      500000 - input().text.length * 2,
    );
    assert.equal(
      (await app.request(`/books/${id}/jobs`, "POST", input())).status,
      409,
    );
    assert.equal(new Set(app.tasks).size, 2);
  } finally {
    await app.close();
  }
});

test("UTC quota caps count supplementary characters atomically across users", async () => {
  process.env.NARRATION_DAILY_CHARACTERS = "14";
  process.env.NARRATION_MONTHLY_CHARACTERS = "14";
  const app = await harness();
  try {
    const id = await app.book();
    const responses = await Promise.all([
      app.request(`/books/${id}/jobs`, "POST", input()),
      app.request(`/books/${id}/jobs`, "POST", {
        ...input(),
        chunkId: hash("another"),
      }),
    ]);
    assert.deepEqual(
      responses.map((result) => result.status).sort(),
      [200, 429],
    );
    assert.equal((await app.request("/config")).body.remaining, 0);
    const other = (
      await app.request(
        "/books",
        "POST",
        { fingerprint: hash("other"), consentVersion: 1 },
        "other",
      )
    ).body.id;
    assert.equal(
      (await app.request(`/books/${other}/jobs`, "POST", input(), "other"))
        .status,
      429,
    );
  } finally {
    await app.close();
    delete process.env.NARRATION_DAILY_CHARACTERS;
    delete process.env.NARRATION_MONTHLY_CHARACTERS;
  }
});

test("abandoned reservations are reclaimed after temporary input expires", async () => {
  const app = await harness();
  try {
    const id = await app.book(),
      job = (await app.request(`/books/${id}/jobs`, "POST", input())).body.id;
    app.db.values.get(`narrationJobs/${job}`)!.createdAt = Timestamp.fromMillis(
      Date.now() - 86400001,
    );
    app.db.values.delete(`narrationInputs/${job}`);
    assert.equal((await app.request("/config")).body.remaining, 500000);
    assert.equal(app.db.values.get(`narrationJobs/${job}`)!.reserved, false);
    assert.equal((await app.request("/config")).body.remaining, 500000);
  } finally {
    await app.close();
  }
});

test("a stale failed worker cannot refund the newer claim's reservation", async () => {
  const app = await harness();
  try {
    const book = await app.book();
    const id = (await app.request(`/books/${book}/jobs`, "POST", input())).body
      .id;
    let releaseFirst!: () => void, releaseSecond!: () => void;
    let firstStarted!: () => void, secondStarted!: () => void;
    const firstReady = new Promise<void>((resolve) => {
      firstStarted = resolve;
    });
    const secondReady = new Promise<void>((resolve) => {
      secondStarted = resolve;
    });
    const firstGate = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    const secondGate = new Promise<void>((resolve) => {
      releaseSecond = resolve;
    });
    app.provider(async (_text, _voice, submit) => {
      if (app.calls() === 1) {
        await submit();
        firstStarted();
        await firstGate;
        throw new Error("late failure");
      }
      secondStarted();
      await secondGate;
      await submit();
      return narrationWav(Buffer.alloc(100));
    });
    const first = app.backend.run(id);
    await firstReady;
    app.db.values.get(`narrationJobs/${id}`)!.leaseUntil =
      Timestamp.fromMillis(0);
    const second = app.backend.run(id);
    await secondReady;
    releaseFirst();
    await first;
    assert.equal(
      (await app.request("/config")).body.remaining,
      500000 - 2 * input().text.length,
    );
    assert.equal(app.db.values.get(`narrationJobs/${id}`)!.reserved, true);
    releaseSecond();
    await second;
    assert.equal(app.db.values.get(`narrationJobs/${id}`)!.status, "ready");
  } finally {
    await app.close();
  }
});
