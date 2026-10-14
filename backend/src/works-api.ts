import { randomBytes } from "node:crypto";
import express, { type RequestHandler } from "express";
import { FieldValue, type Firestore } from "firebase-admin/firestore";
import type { Storage } from "@google-cloud/storage";
import { alignParagraphs, flattenRuns, LINK_THRESHOLD, MAX_ALIGNMENT_RUNS, unflattenRuns } from "./alignment.js";
import { ownedBookId, registerOwnedBook } from "./book-registration.js";
import { bookReference, readBookFence } from "./fences.js";
import { asyncRoute, HttpError, requireString, routeParam } from "./http.js";
import { FINGERPRINT_BYTES, fingerprintList, MAX_PARAGRAPHS, requireWorkMetadata, searchTokens, workIdFor } from "./work-text.js";

/** Search returns at most this many works. */
const SEARCH_RESULTS = 20;
const MAX_KEYWORDS = 30;
const OPEN_LIBRARY_TIMEOUT_MS = 5_000;
const OPEN_LIBRARY_MAX_BYTES = 1024 * 1024;
/** Account-scoped HMAC of the client's import hash (`cloud_book_fingerprint.dart`). */
const BOOK_FINGERPRINT = /^[0-9a-f]{64}$/;
/** Firestore's gRPC ALREADY_EXISTS. */
const ALREADY_EXISTS = 6;

/** Rejects before any upload what `registerOwnedBook` would reject after it. */
function requireBookMetadata(value: unknown) {
  const book = value as { fingerprint?: unknown; title?: unknown } | null;
  requireString(book?.fingerprint, "fingerprint", 128);
  requireString(book?.title, "title", 500);
}

type WorkMetadata = { title: string; author: string; firstPublishYear: number | null };
type WorkDoc = WorkMetadata & { reference: string };

function workRow(id: string, data: WorkMetadata) {
  return { id, title: data.title, author: data.author, firstPublishYear: data.firstPublishYear, linked: true };
}

function requireYear(value: unknown): number | null {
  return Number.isInteger(value) && Math.abs(value as number) <= 9999 ? value as number : null;
}

/** Title, first author and year of Open Library's best matches; throws on any failure. */
async function searchOpenLibrary(fetcher: typeof fetch, query: string): Promise<WorkMetadata[]> {
  const url = new URL("https://openlibrary.org/search.json");
  url.search = new URLSearchParams({
    q: query, fields: "title,author_name,first_publish_year", limit: String(SEARCH_RESULTS),
  }).toString();
  const response = await fetcher(url, {
    headers: { "User-Agent": "Reader (personal development project)" },
    signal: AbortSignal.timeout(OPEN_LIBRARY_TIMEOUT_MS),
  });
  if (!response.ok) throw new Error(`Open Library answered ${response.status}`);
  const body = await response.text();
  if (body.length > OPEN_LIBRARY_MAX_BYTES) throw new Error("Open Library answer is too large");
  const docs = (JSON.parse(body) as { docs?: unknown }).docs;
  if (!Array.isArray(docs)) throw new Error("Open Library answer has no docs");
  return docs.flatMap((doc: { title?: unknown; author_name?: unknown; first_publish_year?: unknown }) => {
    if (typeof doc?.title !== "string" || doc.title.trim() === "") return [];
    const author = Array.isArray(doc.author_name) && typeof doc.author_name[0] === "string" ? doc.author_name[0] : "";
    return [{ ...requireWorkMetadata({ title: doc.title, author }), firstPublishYear: requireYear(doc.first_publish_year) }];
  });
}

/**
 * The global catalog: a text-free index of works (title + first author) that
 * users link their own copies to, so one analysis can serve every copy.
 *
 * Open Library supplies the candidates, so nobody has to add works by hand. A
 * work's ID is derived from its title and author (`workIdFor`) and its document
 * is created by the first link, whose paragraph fingerprints become the work's
 * reference. Later copies link only when they align with that reference
 * (`alignment.ts`). No book text is ever stored. Works are shared, not user
 * data: deleting a book or account removes only the user's link.
 */
export function worksApiRouter(dependencies: {
  db: Firestore; storage: Storage; bucket: string; requireFeature: RequestHandler; fetch?: typeof fetch;
}) {
  const { db, storage, bucket, requireFeature } = dependencies;
  const fetcher = dependencies.fetch ?? fetch;
  const router = express.Router();
  const works = db.collection("works");

  /** Registers the caller's book and records its alignment, fenced against a concurrent deletion. */
  async function link(uid: string, metadata: unknown, workId: string, score: number, runs: number[]) {
    const { bookId } = await registerOwnedBook({ db, uid, metadata: metadata as Record<string, unknown> });
    await db.runTransaction(async (transaction) => {
      const fence = await readBookFence(transaction, db, "books", uid, bookId);
      if (!fence.live) throw new HttpError(410, "Book was deleted.");
      transaction.update(bookReference(db, "books", uid, bookId), {
        work: { workId, score, runs }, updatedAt: FieldValue.serverTimestamp(),
      });
    });
    return bookId;
  }

  /** Makes `fingerprints` the new work's reference, or returns the reference a concurrent first link won with. */
  async function claimReference(uid: string, workId: string, work: WorkMetadata, fingerprints: Buffer) {
    const reference = `works/${workId}/${randomBytes(8).toString("hex")}.bin`;
    const file = storage.bucket(bucket).file(reference);
    // Object first: a work document never names a missing reference.
    await file.save(fingerprints, { contentType: "application/octet-stream" });
    try {
      await works.doc(workId).create({
        ...work, reference, paragraphCount: fingerprints.length / FINGERPRINT_BYTES,
        keywords: searchTokens(`${work.title} ${work.author}`).slice(0, MAX_KEYWORDS),
        createdBy: uid, createdAt: FieldValue.serverTimestamp(),
      });
      return undefined;
    } catch (error) {
      if ((error as { code?: unknown }).code !== ALREADY_EXISTS) throw error;
      await file.delete({ ignoreNotFound: true });
      return (await works.doc(workId).get()).data() as WorkDoc;
    }
  }

  // Open Library first; if it fails, works already in the catalog still answer.
  router.get("/works", requireFeature, asyncRoute(async (req, res) => {
    const query = requireString(req.query.q, "q", 500).trim();
    const tokens = searchTokens(query);
    if (tokens.length === 0) { res.json({ works: [], degraded: false }); return; }
    let candidates: WorkMetadata[];
    let degraded = false;
    try {
      candidates = await searchOpenLibrary(fetcher, query);
    } catch (error) {
      console.warn(`Open Library search failed: ${(error as Error).message}`);
      const longest = tokens.reduce((best, token) => token.length > best.length ? token : best);
      const local = await works.where("keywords", "array-contains", longest).limit(SEARCH_RESULTS).get();
      candidates = local.docs.map(doc => doc.data() as WorkDoc);
      degraded = true;
    }
    const rows = new Map<string, WorkMetadata & { id: string }>();
    for (const candidate of candidates) {
      const id = workIdFor(candidate.title, candidate.author);
      // Explicit fields: a fallback candidate is a whole work document.
      const { title, author, firstPublishYear } = candidate;
      if (!rows.has(id)) rows.set(id, { id, title, author, firstPublishYear });
    }
    const docs = await Promise.all([...rows.keys()].map(id => works.doc(id).get()));
    res.json({ works: [...rows.values()].map((row, index) => ({ ...row, linked: docs[index]!.exists })), degraded });
  }));

  router.post("/works/links", requireFeature, asyncRoute(async (req, res) => {
    const { title, author } = requireWorkMetadata(req.body);
    requireBookMetadata(req.body?.book);
    const encoded = requireString(req.body?.fingerprints, "fingerprints", Math.ceil(MAX_PARAGRAPHS * FINGERPRINT_BYTES / 3) * 4);
    const fingerprints = Buffer.from(encoded, "base64");
    const user = fingerprintList(fingerprints);
    const workId = workIdFor(title, author);
    let work = (await works.doc(workId).get()).data() as WorkDoc | undefined;
    if (work === undefined) {
      const claimed = { title, author, firstPublishYear: requireYear(req.body?.firstPublishYear) };
      work = await claimReference(req.uid!, workId, claimed, fingerprints);
      if (work === undefined) {
        // The first copy is the reference, so it aligns with itself.
        const bookId = await link(req.uid!, req.body.book, workId, 1, flattenRuns([[0, 0, user.length]]));
        res.status(201).json({ bookId, score: 1, work: workRow(workId, claimed) });
        return;
      }
    }
    const [stored] = await storage.bucket(bucket).file(work.reference).download();
    const alignment = alignParagraphs(user, fingerprintList(stored));
    if (alignment.score < LINK_THRESHOLD || alignment.runs.length > MAX_ALIGNMENT_RUNS) {
      const percent = Math.floor(alignment.score * 100);
      res.status(422).json({ error: `This doesn't match the catalog's copy (${percent}% of paragraphs match).`, score: alignment.score });
      return;
    }
    const bookId = await link(req.uid!, req.body.book, workId, alignment.score, flattenRuns(alignment.runs));
    res.json({ bookId, score: alignment.score, work: workRow(workId, work) });
  }));

  // Keyed by fingerprint: a client learns its server book ID only from a link response.
  router.get("/works/links/:fingerprint", requireFeature, asyncRoute(async (req, res) => {
    const bookId = ownedBookId(req.uid!, routeParam(req, "fingerprint", BOOK_FINGERPRINT));
    const book = (await bookReference(db, "books", req.uid!, bookId).get()).data();
    const stored = book?.work as { workId?: unknown; score?: unknown; runs?: unknown } | undefined;
    if (book?.deleted || typeof stored?.workId !== "string" || !unflattenRuns(stored.runs)) {
      throw new HttpError(404, "Book is not linked.");
    }
    const work = await works.doc(stored.workId).get();
    if (!work.exists) throw new HttpError(404, "Book is not linked.");
    res.json({ bookId, score: stored.score, work: workRow(work.id, work.data() as WorkDoc) });
  }));

  router.delete("/works/links/:fingerprint", requireFeature, asyncRoute(async (req, res) => {
    const bookId = ownedBookId(req.uid!, routeParam(req, "fingerprint", BOOK_FINGERPRINT));
    const ref = bookReference(db, "books", req.uid!, bookId);
    await db.runTransaction(async (transaction) => {
      const book = await transaction.get(ref);
      if (book.exists && book.data()?.work !== undefined) {
        transaction.update(ref, { work: FieldValue.delete(), updatedAt: FieldValue.serverTimestamp() });
      }
    });
    res.status(204).end();
  }));

  return router;
}
