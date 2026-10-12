import { randomUUID } from "node:crypto";
import { isDeepStrictEqual } from "node:util";
import { Timestamp, type Firestore, type Transaction } from "firebase-admin/firestore";
import { bookReference, readBookFence } from "./fences.js";
import { HttpError } from "./http.js";
import {
  analysisJsonHash, validateAnalysisAdmission, validateAnalysisChunkInput,
  validateAnalysisDescriptorPage, validateAnalysisPageSize, validateAnalysisSourceManifest,
} from "./book-analysis-source.js";
import type {
  AnalysisChunkDescriptor, AnalysisChunkInput, AnalysisDescriptorPage, AnalysisGenerationAdmission,
  AnalysisGenerationStatus, AnalysisOperationCursor, AnalysisReceipt, AnalysisResultPage,
  AnalysisResultPageDescriptor,
} from "./book-analysis-types.js";

export const ANALYSIS_COLLECTIONS = { jobs: "bookAnalysisJobs", records: "bookAnalysisRecords", inputs: "bookAnalysisInputs" } as const;
const INPUT_TTL = 24 * 60 * 60 * 1000;
const LEASE = 10 * 60 * 1000;
const id = (...parts: unknown[]) => analysisJsonHash(parts);
const same = (a: unknown, b: unknown) => isDeepStrictEqual(a, b);
function conflict(message = "Book analysis intent conflicts."): never { throw new HttpError(409, message); }
function bounded<T>(value: T): T { validateAnalysisPageSize(value); return value; }

/** All records are top-level, server-owned, and independently purgeable by uid/bookId. */
export type AnalysisOwner = { uid: string; bookId: string; generationId: string };
export type StoredAnalysisGeneration = AnalysisOwner & {
  schemaVersion: 1; recordType: "generation"; admission: AnalysisGenerationAdmission;
  status: AnalysisGenerationStatus; manifestReady: boolean; processedChunks: number;
  processedUnits: number; requiredUnits: number; cursor: AnalysisOperationCursor;
  error: { category: string } | null; finalizedRevision: string | null;
  resultPages: AnalysisResultPageDescriptor[];
  /** Monotonic verification coverage bound to the exact ordered immutable descriptor list. */
  publicationVerifiedCount?: number;
  publicationDescriptorDigest?: string;
};
export type StoredAnalysisJob = AnalysisOwner & {
  schemaVersion: 1; jobId: string; operation: "extract" | "finalize";
  cursor: AnalysisOperationCursor; status: "pending" | "running" | "complete" | "failed";
  providerSubmitted: boolean; claimToken?: string; leaseUntil?: Timestamp;
  inputHash?: string; resultPages?: AnalysisResultPageDescriptor[];
};
export type AnalysisClaim = AnalysisOwner & { jobId: string; token: string };
/** Worker translates this cancellation into 204; an owned expired claim instead throws HTTP 409. */
export class CancelledAnalysisClaim extends Error {}
export type AnalysisWorkRecord = { key: string; data: Record<string, unknown> };

/** Storage only: authenticated API is the sole task dispatcher. No provider/credit/profile dependencies. */
export class BookAnalysisStore {
  constructor(readonly db: Firestore) {}
  generationReference(generationId: string) { return this.db.collection(ANALYSIS_COLLECTIONS.records).doc(generationId); }
  jobReference(jobId: string) { return this.db.collection(ANALYSIS_COLLECTIONS.jobs).doc(jobId); }
  inputReference(jobId: string) { return this.db.collection(ANALYSIS_COLLECTIONS.inputs).doc(jobId); }
  recordReference(generationId: string, type: string, key: string | number) {
    return this.db.collection(ANALYSIS_COLLECTIONS.records).doc(id(generationId, type, key));
  }
  private async owned(transaction: Transaction, uid: string, generationId: string): Promise<StoredAnalysisGeneration> {
    const data = (await transaction.get(this.generationReference(generationId))).data() as StoredAnalysisGeneration | undefined;
    if (!data || data.uid !== uid || data.recordType !== "generation") throw new HttpError(404, "Book analysis not found.");
    await this.bookFence(transaction, uid, data.bookId);
    return data;
  }
  private async bookFence(transaction: Transaction, uid: string, bookId: string) {
    const fence = await readBookFence(transaction, this.db, "books", uid, bookId);
    if (fence.accountDeleted) throw new HttpError(410, "Account was deleted.");
    if (fence.book.data()?.deleted) throw new HttpError(410, "Book was deleted.");
    if (!fence.live || fence.book.data()?.schemaVersion !== 2 || fence.book.data()?.uid !== uid) {
      throw new HttpError(404, "Book not found.");
    }
    return fence;
  }
  async readGeneration(uid: string, generationId: string) {
    return this.db.runTransaction(transaction => this.owned(transaction, uid, generationId));
  }
  private receipt(g: StoredAnalysisGeneration, job?: StoredAnalysisJob): AnalysisReceipt {
    return { generationId: g.generationId, status: g.status, ...(job ? { jobId: job.jobId, cursor: job.cursor } : {}) };
  }
  async admit(uid: string, bookId: string, admission: AnalysisGenerationAdmission): Promise<AnalysisReceipt> {
    validateAnalysisAdmission(admission);
    const generationId = id(uid, bookId, admission.documentDigest, admission.documentVersion,
      admission.schemaVersion, admission.analysisVersion, admission.promptVersion, admission.model);
    if (admission.chunkCount === 0) validateAnalysisSourceManifest({ ...admission, chunks: [] });
    return this.db.runTransaction(async transaction => {
      await this.bookFence(transaction, uid, bookId);
      const ref = this.generationReference(generationId);
      const existing = (await transaction.get(ref)).data() as StoredAnalysisGeneration | undefined;
      if (existing) {
        if (existing.uid !== uid || existing.bookId !== bookId || !same(existing.admission, admission)) conflict();
        return this.receipt(existing);
      }
      const ready = admission.pageCount === 0;
      const generation: StoredAnalysisGeneration = { schemaVersion: 1, recordType: "generation", uid, bookId, generationId,
        admission, status: ready ? "finalizing" : "manifest", manifestReady: ready, processedChunks: 0,
        processedUnits: 0, requiredUnits: 0, cursor: { stage: ready ? "reconcile" : "manifest", ordinal: 0 },
        error: null, finalizedRevision: null, resultPages: [] };
      transaction.create(ref, bounded(generation));
      transaction.update(bookReference(this.db, "books", uid, bookId), { activeAnalysisGenerationId: generationId });
      return this.receipt(generation);
    });
  }
  async putManifestPage(uid: string, generationId: string, ordinal: number, page: AnalysisDescriptorPage) {
    validateAnalysisDescriptorPage(page);
    await this.db.runTransaction(async transaction => {
      const g = await this.owned(transaction, uid, generationId);
      if (ordinal < 0 || ordinal >= g.admission.pageCount) throw new HttpError(400, "Analysis page ordinal is invalid.");
      const refs = Array.from({ length: g.admission.pageCount }, (_, n) => this.recordReference(generationId, "descriptor", n));
      const snapshots = await Promise.all(refs.map(ref => transaction.get(ref)));
      const existing = snapshots[ordinal]!.data();
      if (existing) { if (!same(existing.page, page)) conflict(); return; }
      if (g.manifestReady || g.status !== "manifest") conflict();
      const pages = snapshots.map((s, n) => n === ordinal ? page : s.data()?.page as AnalysisDescriptorPage | undefined);
      let requiredUnits = 0;
      if (pages.every((p): p is AnalysisDescriptorPage => p !== undefined)) {
        const chunks = pages.flatMap(p => p.chunks);
        validateAnalysisSourceManifest({ ...g.admission, chunks });
        requiredUnits = chunks.reduce((n, c) => n + c.primary.reduce((sum, s) => sum + s.endOffset - s.startOffset, 0), 0);
      }
      const chunkRefs = page.chunks.map(chunk => this.recordReference(generationId, "chunk", chunk.ordinal));
      const chunkSnapshots = await Promise.all(chunkRefs.map(ref => transaction.get(ref)));
      page.chunks.forEach((chunk, n) => {
        if (chunkSnapshots[n]!.exists) conflict("Analysis descriptor order conflicts.");
      });
      transaction.create(refs[ordinal]!, bounded({ schemaVersion: 1, recordType: "descriptor", uid, bookId: g.bookId,
        generationId, pageOrdinal: ordinal, page, checksum: analysisJsonHash(page) }));
      page.chunks.forEach((chunk, n) => transaction.create(chunkRefs[n]!, bounded({
        schemaVersion: 1, recordType: "chunk", uid, bookId: g.bookId, generationId, descriptor: chunk,
      })));
      if (pages.every(p => p !== undefined)) transaction.set(this.generationReference(generationId), bounded({ ...g,
        manifestReady: true, status: "extracting", requiredUnits, cursor: { stage: "extract", ordinal: 0 },
      }));
      else transaction.set(this.generationReference(generationId), bounded({ ...g,
        cursor: { stage: "manifest", ordinal: pages.findIndex(p => p === undefined) },
      }));
    });
  }
  /** Direct chunk lookup keeps extraction independent of total book descriptor size. */
  async readChunkDescriptor(generationId: string, ordinal: number): Promise<AnalysisChunkDescriptor | null> {
    const record = (await this.recordReference(generationId, "chunk", ordinal).get()).data();
    return record?.generationId === generationId ? record.descriptor as AnalysisChunkDescriptor : null;
  }
  async submitChunk(uid: string, generationId: string, ordinal: number, input: AnalysisChunkInput) {
    const initial = await this.readGeneration(uid, generationId);
    if (!initial.manifestReady) conflict("Analysis manifest is incomplete.");
    const descriptor = await this.readChunkDescriptor(generationId, ordinal);
    if (!descriptor) throw new HttpError(400, "Analysis chunk ordinal is invalid.");
    validateAnalysisChunkInput(input, descriptor);
    const jobId = id(generationId, "extract", ordinal);
    return this.db.runTransaction(async transaction => {
      const g = await this.owned(transaction, uid, generationId);
      const fence = await this.bookFence(transaction, uid, g.bookId);
      const jobRef = this.jobReference(jobId), inputRef = this.inputReference(jobId);
      const [jobSnapshot, raw] = await Promise.all([transaction.get(jobRef), transaction.get(inputRef)]);
      const existing = jobSnapshot.data() as StoredAnalysisJob | undefined;
      const inputHash = analysisJsonHash([input.ordinal, input.hash, input.overlapHash,
        input.primary.map(s => s.text), input.overlap.map(s => s.text)]);
      if (existing) {
        if (existing.inputHash !== inputHash) conflict();
        if (existing.status === "complete" || existing.status === "failed") return { receipt: this.receipt(g, existing), enqueue: false };
      }
      if (fence.book.data()?.activeAnalysisGenerationId !== generationId) conflict("Analysis generation was superseded.");
      if (g.processedChunks !== ordinal) conflict("Earlier analysis window is incomplete.");
      if (g.status === "failed" || g.status === "complete") return { receipt: this.receipt(g, existing), enqueue: false };
      const job: StoredAnalysisJob = existing ?? { schemaVersion: 1, uid, bookId: g.bookId, generationId,
        jobId, operation: "extract", cursor: { stage: "extract", ordinal }, status: "pending", providerSubmitted: false, inputHash };
      const rawData = raw.data();
      if ((!rawData || (rawData.expiresAt as Timestamp).toMillis() <= Date.now()) && !job.providerSubmitted) {
        transaction.set(inputRef, bounded({ schemaVersion: 1, uid, bookId: g.bookId, generationId,
          input, expiresAt: Timestamp.fromMillis(Date.now() + INPUT_TTL) }));
      }
      if (!existing) transaction.create(jobRef, bounded(job));
      return { receipt: this.receipt(g, job), enqueue: job.status === "pending" };
    });
  }
  async admitFinalize(uid: string, generationId: string) {
    return this.db.runTransaction(async transaction => {
      const g = await this.owned(transaction, uid, generationId);
      if (g.status === "complete" || g.status === "failed") return { receipt: this.receipt(g), enqueue: false };
      const fence = await this.bookFence(transaction, uid, g.bookId);
      if (fence.book.data()?.activeAnalysisGenerationId !== generationId) conflict("Analysis generation was superseded.");
      if (!g.manifestReady || g.processedChunks !== g.admission.chunkCount) conflict("Book analysis extraction is incomplete.");
      const jobId = id(generationId, "finalize", g.cursor.stage, g.cursor.ordinal);
      const ref = this.jobReference(jobId);
      const existing = (await transaction.get(ref)).data() as StoredAnalysisJob | undefined;
      const job: StoredAnalysisJob = existing ?? { schemaVersion: 1, uid, bookId: g.bookId, generationId, jobId,
        operation: "finalize", cursor: g.cursor, status: "pending", providerSubmitted: false };
      if (!existing) transaction.create(ref, bounded(job));
      return { receipt: this.receipt(g, job), enqueue: job.status === "pending" };
    });
  }
  /** Active duplicates/terminal/deleted/superseded intents adopt 204 without a provider call. */
  async claim(jobId: string): Promise<{ claim: AnalysisClaim; job: StoredAnalysisJob; generation: StoredAnalysisGeneration } | null> {
    return this.db.runTransaction(async transaction => {
      const ref = this.jobReference(jobId), job = (await transaction.get(ref)).data() as StoredAnalysisJob | undefined;
      if (!job || job.schemaVersion !== 1 || job.status === "complete" || job.status === "failed" ||
        (job.leaseUntil?.toMillis() ?? 0) > Date.now()) return null;
      const [fence, snapshot] = await Promise.all([readBookFence(transaction, this.db, "books", job.uid, job.bookId),
        transaction.get(this.generationReference(job.generationId))]);
      const generation = snapshot.data() as StoredAnalysisGeneration | undefined;
      if (!generation || generation.schemaVersion !== 1 || generation.uid !== job.uid || generation.bookId !== job.bookId ||
        !fence.live || fence.book.data()?.schemaVersion !== 2 || fence.book.data()?.uid !== job.uid ||
        fence.book.data()?.activeAnalysisGenerationId !== job.generationId || generation.status === "failed" ||
        !same(generation.cursor, job.cursor)) return null;
      const token = randomUUID();
      transaction.update(ref, { status: "running", claimToken: token, leaseUntil: Timestamp.fromMillis(Date.now() + LEASE) });
      return { claim: { uid: job.uid, bookId: job.bookId, generationId: job.generationId, jobId, token }, job, generation };
    });
  }
  /** Call before any staging, cursor, failure or publication write; reads precede writes. */
  async liveClaim(transaction: Transaction, claim: AnalysisClaim) {
    const [jobSnapshot, generationSnapshot, fence] = await Promise.all([
      transaction.get(this.jobReference(claim.jobId)), transaction.get(this.generationReference(claim.generationId)),
      readBookFence(transaction, this.db, "books", claim.uid, claim.bookId),
    ]);
    const job = jobSnapshot.data() as StoredAnalysisJob | undefined;
    const generation = generationSnapshot.data() as StoredAnalysisGeneration | undefined;
    if (!job || !generation || job.schemaVersion !== 1 || generation.schemaVersion !== 1 ||
      job.claimToken !== claim.token || job.status !== "running" ||
      job.uid !== claim.uid || job.bookId !== claim.bookId || job.generationId !== claim.generationId ||
      generation.uid !== claim.uid || generation.bookId !== claim.bookId || !fence.live ||
      fence.book.data()?.uid !== claim.uid || fence.book.data()?.schemaVersion !== 2 ||
      fence.book.data()?.activeAnalysisGenerationId !== claim.generationId ||
      !same(generation.cursor, job.cursor)) throw new CancelledAnalysisClaim();
    if ((job.leaseUntil?.toMillis() ?? 0) <= Date.now()) throw new HttpError(409, "Book analysis claim expired.");
    return { job, generation };
  }
  /** TTL disappearance before submission is recoverable only by the exact authenticated chunk POST. */
  async readInput(claim: AnalysisClaim): Promise<AnalysisChunkInput | null> {
    return this.db.runTransaction(async transaction => {
      await this.liveClaim(transaction, claim);
      const input = (await transaction.get(this.inputReference(claim.jobId))).data();
      if (!input || input.uid !== claim.uid || input.bookId !== claim.bookId || input.generationId !== claim.generationId ||
        (input.expiresAt as Timestamp).toMillis() <= Date.now()) return null;
      return input.input as AnalysisChunkInput;
    });
  }
  /** Mark immediately before a paid call. An expired task must not silently repeat it. */
  async beginProviderSubmission(claim: AnalysisClaim): Promise<boolean> {
    return this.db.runTransaction(async transaction => {
      const { job } = await this.liveClaim(transaction, claim);
      if (job.providerSubmitted) conflict("Book analysis provider operation is incomplete.");
      if (job.operation === "extract") {
        const input = (await transaction.get(this.inputReference(claim.jobId))).data();
        if (!input || input.uid !== claim.uid || input.bookId !== claim.bookId ||
          input.generationId !== claim.generationId || (input.expiresAt as Timestamp).toMillis() <= Date.now()) {
          transaction.update(this.jobReference(claim.jobId), { status: "pending", leaseUntil: Timestamp.fromMillis(0) });
          return false;
        }
      }
      transaction.update(this.jobReference(claim.jobId), { providerSubmitted: true });
      return true;
    });
  }
  /** Missing-input wait releases the claim without terminal failure or automatic provider retry. */
  async releaseMissingInput(claim: AnalysisClaim) {
    await this.db.runTransaction(async transaction => {
      const { job } = await this.liveClaim(transaction, claim);
      if (job.providerSubmitted) conflict();
      transaction.update(this.jobReference(claim.jobId), { status: "pending", leaseUntil: Timestamp.fromMillis(0) });
    });
  }
  pageDescriptor(page: AnalysisResultPage): AnalysisResultPageDescriptor {
    return { pageId: page.pageId, kind: page.kind, ordinal: page.ordinal,
      checksum: analysisJsonHash(page), byteLength: validateAnalysisPageSize(page) };
  }
  /** Immutable pages become durable under the live claim, but remain private until publication. */
  async writeStagingPages(claim: AnalysisClaim, pages: AnalysisResultPage[], extraction = false) {
    if (pages.length >= 399 || new Set(pages.map(p => p.pageId)).size !== pages.length) {
      throw new HttpError(400, "Invalid analysis page batch.");
    }
    const type = extraction ? "extraction" : "result";
    const records = pages.map(page => {
      if (page.generationId !== claim.generationId || page.schemaVersion !== 1 || !page.pageId || !Number.isSafeInteger(page.ordinal) || page.ordinal < 0) {
        throw new HttpError(400, "Invalid analysis result page.");
      }
      const descriptor = this.pageDescriptor(page);
      return { ref: this.recordReference(claim.generationId, type, page.pageId), record: bounded({ schemaVersion: 1,
        recordType: type, uid: claim.uid, bookId: claim.bookId, generationId: claim.generationId,
        jobId: claim.jobId, pageId: page.pageId, descriptor, pageJson: JSON.stringify(page) }) };
    });
    await this.db.runTransaction(async transaction => {
      await this.liveClaim(transaction, claim);
      const existing = await Promise.all(records.map(r => transaction.get(r.ref)));
      records.forEach((r, n) => {
        if (existing[n]!.exists) { if (!same(existing[n]!.data(), r.record)) conflict(); }
        else transaction.create(r.ref, r.record);
      });
    });
    return pages.map(page => this.pageDescriptor(page));
  }
  async readPages(generationId: string, type: "extraction" | "result") {
    const snapshot = await this.db.collection(ANALYSIS_COLLECTIONS.records).where("generationId", "==", generationId).where("recordType", "==", type).get();
    return snapshot.docs.map(d => JSON.parse(d.data().pageJson as string) as AnalysisResultPage)
      .sort((a, b) => a.kind.localeCompare(b.kind) || a.ordinal - b.ordinal || a.pageId.localeCompare(b.pageId));
  }
  /** Direct bounded worker reads avoid loading the whole accumulated analysis for a work unit. */
  async readExtractionJob(generationId: string, chunkOrdinal: number): Promise<StoredAnalysisJob | null> {
    const data = (await this.jobReference(id(generationId, "extract", chunkOrdinal)).get()).data();
    return data?.generationId === generationId ? data as StoredAnalysisJob : null;
  }
  async readStagingPage(generationId: string, type: "extraction" | "result", pageId: string): Promise<AnalysisResultPage | null> {
    const data = (await this.recordReference(generationId, type, pageId).get()).data();
    return data?.generationId === generationId ? JSON.parse(data.pageJson as string) as AnalysisResultPage : null;
  }
  async readWorkRecord(generationId: string, key: string): Promise<AnalysisWorkRecord | null> {
    const data = (await this.recordReference(generationId, "work", key).get()).data();
    return data?.generationId === generationId ? { key, data: data.data as Record<string, unknown> } : null;
  }
  /** Derived bounded reconciliation state; keys and data must contain no chapter prose/quotations. */
  async writeWorkRecords(claim: AnalysisClaim, records: AnalysisWorkRecord[]) {
    if (records.length >= 399 || new Set(records.map(r => r.key)).size !== records.length) throw new HttpError(400, "Invalid analysis work batch.");
    const values = records.map(r => ({ ref: this.recordReference(claim.generationId, "work", r.key),
      value: bounded({ schemaVersion: 1, recordType: "work", uid: claim.uid, bookId: claim.bookId,
        generationId: claim.generationId, key: r.key, data: r.data }) }));
    await this.db.runTransaction(async transaction => {
      await this.liveClaim(transaction, claim);
      const existing = await Promise.all(values.map(v => transaction.get(v.ref)));
      values.forEach((v, n) => {
        if (existing[n]!.exists) { if (!same(existing[n]!.data(), v.value)) conflict(); }
        else transaction.create(v.ref, v.value);
      });
    });
  }
  async readWorkRecords(generationId: string): Promise<AnalysisWorkRecord[]> {
    const snapshot = await this.db.collection(ANALYSIS_COLLECTIONS.records).where("generationId", "==", generationId).where("recordType", "==", "work").get();
    return snapshot.docs.map(d => ({ key: d.data().key as string, data: d.data().data as Record<string, unknown> }))
      .sort((a, b) => a.key.localeCompare(b.key));
  }
  private async verifyPages(transaction: Transaction, claim: AnalysisClaim, pages: AnalysisResultPageDescriptor[], type: "extraction" | "result") {
    if (new Set(pages.map(p => p.pageId)).size !== pages.length) conflict();
    const snapshots = await Promise.all(pages.map(p => transaction.get(this.recordReference(claim.generationId, type, p.pageId))));
    snapshots.forEach((s, n) => {
      const r = s.data();
      if (!r || r.uid !== claim.uid || r.bookId !== claim.bookId || r.generationId !== claim.generationId ||
        (type === "extraction" && r.jobId !== claim.jobId) || !same(r.descriptor, pages[n]) ||
        !same(this.pageDescriptor(JSON.parse(r.pageJson as string) as AnalysisResultPage), pages[n])) conflict("Analysis pages are incomplete.");
    });
  }
  /** All validated extraction pages must already be durable; raw input deletion and coverage commit are atomic. */
  async commitExtraction(claim: AnalysisClaim, pages: AnalysisResultPageDescriptor[]) {
    await this.db.runTransaction(async transaction => {
      const { job, generation: g } = await this.liveClaim(transaction, claim);
      if (job.operation !== "extract" || g.processedChunks !== job.cursor.ordinal) conflict();
      await this.verifyPages(transaction, claim, pages, "extraction");
      const descriptor = await transaction.get(this.recordReference(g.generationId, "chunk", job.cursor.ordinal));
      const chunk = descriptor.data()?.descriptor as AnalysisChunkDescriptor | undefined;
      if (!chunk || descriptor.data()?.uid !== claim.uid || descriptor.data()?.bookId !== claim.bookId) {
        conflict("Analysis descriptor is incomplete.");
      }
      const processedChunks = g.processedChunks + 1;
      const done = processedChunks === g.admission.chunkCount;
      transaction.set(this.jobReference(claim.jobId), bounded({ ...job, status: "complete", resultPages: pages }));
      transaction.set(this.generationReference(claim.generationId), bounded({ ...g, processedChunks,
        processedUnits: g.processedUnits + chunk.primary.reduce((n, s) => n + s.endOffset - s.startOffset, 0),
        status: done ? "finalizing" : "extracting", cursor: { stage: done ? "reconcile" : "extract", ordinal: done ? 0 : processedChunks } }));
      transaction.delete(this.inputReference(claim.jobId));
    });
  }
  /** One bounded restartable finalization unit. The worker chooses the next cursor after durable work. */
  async commitFinalization(claim: AnalysisClaim, next: AnalysisOperationCursor, pages: AnalysisResultPageDescriptor[] = []) {
    await this.db.runTransaction(async transaction => {
      const { job, generation: g } = await this.liveClaim(transaction, claim);
      const stages = ["reconcile", "materialize", "index", "publish"];
      const current = stages.indexOf(g.cursor.stage), target = stages.indexOf(next.stage);
      if (job.operation !== "finalize" || current < 0 || !Number.isSafeInteger(next.ordinal) ||
        !((target === current && next.ordinal === g.cursor.ordinal + 1) || (target === current + 1 && next.ordinal === 0))) conflict("Invalid analysis cursor transition.");
      await this.verifyPages(transaction, claim, pages, "result");
      transaction.set(this.jobReference(claim.jobId), bounded({ ...job, status: "complete", resultPages: pages }));
      transaction.set(this.generationReference(claim.generationId), bounded({ ...g, cursor: next }));
    });
  }
  /** Verifies at most 32 durable pages per invocation; purge is tombstone-first. */
  async verifyPublicationBatch(claim: AnalysisClaim, pages: AnalysisResultPageDescriptor[], start: number): Promise<number> {
    bounded(pages);
    if (!Number.isSafeInteger(start) || start < 0 || start > pages.length ||
        new Set(pages.map(page => page.pageId)).size !== pages.length) conflict();
    const digest = analysisJsonHash(pages);
    const end = Math.min(pages.length, start + 32);
    for (const descriptor of pages.slice(start, end)) {
      const record = (await this.recordReference(claim.generationId, "result", descriptor.pageId).get()).data();
      if (!record || record.uid !== claim.uid || record.bookId !== claim.bookId || record.generationId !== claim.generationId ||
          !same(record.descriptor, descriptor) ||
          !same(this.pageDescriptor(JSON.parse(record.pageJson as string) as AnalysisResultPage), descriptor)) {
        conflict("Analysis pages are incomplete.");
      }
    }
    return this.db.runTransaction(async transaction => {
      const { job, generation } = await this.liveClaim(transaction, claim);
      if (job.operation !== "finalize" || generation.cursor.stage !== "publish" ||
          (generation.publicationVerifiedCount ?? 0) !== start ||
          (generation.publicationDescriptorDigest && generation.publicationDescriptorDigest !== digest)) conflict();
      transaction.update(this.generationReference(claim.generationId), {
        publicationVerifiedCount: end, publicationDescriptorDigest: digest,
      });
      return end;
    });
  }
  /** One pointer switch after cursor-bounded checksum verification of every immutable page. */
  async publish(claim: AnalysisClaim, pages: AnalysisResultPageDescriptor[]) {
    bounded(pages);
    if (new Set(pages.map(p => p.pageId)).size !== pages.length) conflict();
    await this.db.runTransaction(async transaction => {
      const { job, generation: g } = await this.liveClaim(transaction, claim);
      if (job.operation !== "finalize" || g.cursor.stage !== "publish" || !g.manifestReady || g.processedChunks !== g.admission.chunkCount) conflict();
      if (g.publicationVerifiedCount !== pages.length || g.publicationDescriptorDigest !== analysisJsonHash(pages)) {
        conflict("Analysis pages are incomplete.");
      }
      const finalizedRevision = id(claim.generationId, pages.map(p => [p.pageId, p.checksum]));
      const complete = bounded({ ...g, status: "complete" as const, finalizedRevision, resultPages: pages });
      transaction.set(this.generationReference(claim.generationId), complete);
      transaction.update(this.jobReference(claim.jobId), { status: "complete" });
      transaction.update(bookReference(this.db, "books", claim.uid, claim.bookId), {
        latestAnalysisGenerationId: claim.generationId, analysisRevision: finalizedRevision,
      });
    });
  }
  async fail(claim: AnalysisClaim, category: string) {
    if (!/^[a-z][a-z0-9_]{0,63}$/.test(category)) throw new HttpError(400, "Invalid analysis failure category.");
    await this.db.runTransaction(async transaction => {
      const { generation } = await this.liveClaim(transaction, claim);
      transaction.update(this.jobReference(claim.jobId), { status: "failed" });
      transaction.set(this.generationReference(claim.generationId), bounded({ ...generation, status: "failed", error: { category } }));
      transaction.delete(this.inputReference(claim.jobId));
    });
  }
  async readPublishedPage(uid: string, generationId: string, pageId: string) {
    return this.db.runTransaction(async transaction => {
      const g = await this.owned(transaction, uid, generationId);
      const descriptor = g.status === "complete" ? g.resultPages.find(p => p.pageId === pageId) : undefined;
      if (!descriptor) throw new HttpError(404, "Analysis result page not found.");
      const page = (await transaction.get(this.recordReference(generationId, "result", pageId))).data();
      if (!page || page.uid !== uid || page.bookId !== g.bookId || !same(this.pageDescriptor(JSON.parse(page.pageJson as string) as AnalysisResultPage), descriptor)) {
        throw new HttpError(404, "Analysis result page not found.");
      }
      return JSON.parse(page.pageJson as string) as AnalysisResultPage;
    });
  }
}
