import assert from "node:assert/strict";
import { FieldValue, Timestamp, type Firestore } from "firebase-admin/firestore";

/** Stored document fields. */
export type MemoryData = Record<string, unknown>;

/** Snapshot shape returned by references, queries and transactions. */
export interface MemorySnapshot {
  exists: boolean;
  id: string;
  ref: MemoryReference;
  data(): MemoryData | undefined;
}

/** Transaction operations; writes are deferred until the action resolves. */
export interface MemoryTransaction {
  get(reference: MemoryReference): Promise<MemorySnapshot>;
  set(reference: MemoryReference, data: MemoryData, options?: { merge?: boolean }): void;
  create(reference: MemoryReference, data: MemoryData): void;
  update(reference: MemoryReference, data: MemoryData): void;
  delete(reference: MemoryReference): void;
}

/** Match Firestore's default rejection of undefined, including nested values. */
function assertFirestoreData(value: unknown): void {
  assert.notEqual(value, undefined, "Firestore cannot store undefined fields");
  if (value && typeof value === "object" && !(value instanceof FieldValue) && !(value instanceof Timestamp)) {
    for (const field of Object.values(value)) assertFirestoreData(field);
  }
}

/**
 * In-memory Firestore double: transactions are serialized with deferred writes,
 * `create`/`update` enforce existence like Firestore, every write rejects
 * undefined fields, and unsupported field transforms throw. No cloud clients are used.
 */
export class MemoryFirestore {
  values = new Map<string, MemoryData>();
  /** `write:<path>:<state ?? status>` and `delete:<path>` in commit order. */
  events: string[] = [];
  /** Every document path read through `get()`. */
  reads: string[] = [];
  private tail: Promise<void> = Promise.resolve();

  /** This double typed as the production Firestore dependency. */
  get firestore(): Firestore {
    return this as unknown as Firestore;
  }

  collection(path: string) {
    return new MemoryCollection(this, path);
  }

  async runTransaction<T>(action: (transaction: MemoryTransaction) => Promise<T>): Promise<T> {
    const result = this.tail.then(async () => {
      const pending: Array<() => void> = [];
      const value = await action({
        get: (reference) => reference.get(),
        set: (reference, data, options) => { pending.push(() => reference.write(data, options?.merge)); },
        create: (reference, data) => {
          pending.push(() => {
            assert(!this.values.has(reference.path), `create of existing ${reference.path}`);
            reference.write(data);
          });
        },
        update: (reference, data) => {
          pending.push(() => {
            assert(this.values.has(reference.path), `update of missing ${reference.path}`);
            reference.write(data, true);
          });
        },
        delete: (reference) => { pending.push(() => reference.remove()); },
      });
      for (const operation of pending) operation();
      return value;
    });
    this.tail = result.then(() => {}, () => {});
    return result;
  }

  /** Queues writes until close so purge tests require awaited completion. */
  bulkWriter() {
    const pending: Array<() => void> = [];
    return {
      set: (reference: MemoryReference, data: MemoryData, options?: { merge?: boolean }) => {
        pending.push(() => reference.write(data, options?.merge));
        return Promise.resolve();
      },
      delete: (reference: MemoryReference) => {
        pending.push(() => reference.remove());
        return Promise.resolve();
      },
      close: async () => { for (const operation of pending) operation(); },
    };
  }

  /** Removes the document and every nested descendant. */
  async recursiveDelete(reference: MemoryReference) {
    for (const path of [...this.values.keys()]) {
      if (path === reference.path || path.startsWith(`${reference.path}/`)) this.values.delete(path);
    }
  }
}

/** A document path inside a {@link MemoryFirestore}. */
export class MemoryReference {
  constructor(readonly db: MemoryFirestore, readonly path: string) {}

  get id() { return this.path.split("/").at(-1)!; }

  collection(path: string) { return this.db.collection(`${this.path}/${path}`); }

  async get(): Promise<MemorySnapshot> {
    this.db.reads.push(this.path);
    return this.snapshot();
  }

  /** Snapshot without recording a read; used by queries. */
  snapshot(): MemorySnapshot {
    const data = this.db.values.get(this.path);
    return { exists: data !== undefined, id: this.id, ref: this, data: () => data && { ...data } };
  }

  /** Applies a write immediately; transactions and bulk writers call this on commit. */
  write(data: MemoryData, merge = false) {
    assertFirestoreData(data);
    const value: MemoryData = merge ? { ...this.db.values.get(this.path) } : {};
    for (const [key, field] of Object.entries(data)) {
      if (field instanceof FieldValue) {
        if (field.isEqual(FieldValue.delete())) delete value[key];
        else if (field.isEqual(FieldValue.serverTimestamp())) value[key] = Timestamp.now();
        else if (field.constructor.name === "NumericIncrementTransform" && "operand" in field &&
          typeof field.operand === "number") {
          value[key] = Number(value[key] ?? 0) + field.operand;
        } else throw new Error("Unsupported field transform in Firestore double");
      } else value[key] = field;
    }
    this.db.values.set(this.path, value);
    this.db.events.push(`write:${this.path}:${String(value.state ?? value.status ?? "")}`);
  }

  /** Deletes immediately and records the event. */
  remove() {
    this.db.values.delete(this.path);
    this.db.events.push(`delete:${this.path}`);
  }

  async set(data: MemoryData, options?: { merge?: boolean }) { this.write(data, options?.merge); }

  async update(data: MemoryData) {
    assert(this.db.values.has(this.path), `update of missing ${this.path}`);
    this.write(data, true);
  }

  async delete() { this.remove(); }
}

/** A collection query supporting `==` and Timestamp `<` filters plus `limit`. */
export class MemoryCollection {
  constructor(
    readonly db: MemoryFirestore,
    readonly path: string,
    readonly filters: Array<[string, "==" | "<", unknown]> = [],
    readonly max = Infinity,
  ) {}

  doc(id: string) { return new MemoryReference(this.db, `${this.path}/${id}`); }

  where(key: string, operation: string, value: unknown) {
    assert(operation === "==" || operation === "<", `unsupported operator ${operation}`);
    return new MemoryCollection(this.db, this.path, [...this.filters, [key, operation, value]], this.max);
  }

  limit(value: number) { return new MemoryCollection(this.db, this.path, this.filters, value); }
  /** Field projection only shrinks production payloads; the double returns whole documents. */
  select(..._fields: string[]) { return this; }

  async get() {
    const docs: MemorySnapshot[] = [];
    for (const [path, data] of this.db.values) {
      if (!path.startsWith(`${this.path}/`) || path.slice(this.path.length + 1).includes("/")) continue;
      const matches = this.filters.every(([key, operation, value]) => {
        if (operation === "==") return data[key] === value;
        const field = data[key];
        return field instanceof Timestamp && field.toMillis() < (value as Timestamp).toMillis();
      });
      if (matches) docs.push(new MemoryReference(this.db, path).snapshot());
    }
    return { docs: docs.slice(0, this.max) };
  }
}
