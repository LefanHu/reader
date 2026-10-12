import { createHmac } from "node:crypto";
import express, { type RequestHandler } from "express";
import type { Firestore } from "firebase-admin/firestore";
import { asyncRoute, HttpError, routeParam } from "./http.js";
import { registerOwnedBook } from "./book-registration.js";
import { getIllustrationConfiguration } from "./illustration-configuration.js";
import { AnalysisSourceValidationError } from "./book-analysis-source.js";
import { BookAnalysisStore } from "./book-analysis-store.js";
import { ANALYSIS_MODEL, type AnalysisProgress } from "./book-analysis-types.js";

/** Account identity never exposes UID and never initializes an account/credit record. */
export function bookAnalysisAccountKey(uid: string, fingerprintSecret: string) {
  if (!fingerprintSecret) throw new HttpError(503, "Book preprocessing identity is not configured.");
  return createHmac("sha256", fingerprintSecret).update(`book-analysis-owner:${uid}`).digest("hex");
}
function ordinal(value: string) {
  if (!/^(0|[1-9][0-9]*)$/.test(value) || !Number.isSafeInteger(Number(value))) {
    throw new HttpError(400, "Analysis ordinal is invalid.");
  }
  return Number(value);
}

export function bookAnalysisApiRouter(deps: {
  db: Firestore;
  requireFeature: RequestHandler;
  enqueue: (path: string, payload: Record<string, unknown>, taskId: string) => Promise<void>;
  fingerprintSecret: string;
}): express.Router {
  const { db, requireFeature, enqueue, fingerprintSecret } = deps;
  const store = new BookAnalysisStore(db);
  const router = express.Router();
  router.get("/config", asyncRoute(async (req, res) => {
    res.json({ schemaVersion: 1, analysisVersion: 1, enabled: getIllustrationConfiguration().enabled,
      model: ANALYSIS_MODEL, accountKey: bookAnalysisAccountKey(req.uid!, fingerprintSecret) });
  }));
  router.post("/books", requireFeature, asyncRoute(async (req, res) => {
    const accountKey = bookAnalysisAccountKey(req.uid!, fingerprintSecret);
    const { bookId } = await registerOwnedBook({ db, uid: req.uid!, metadata: req.body });
    res.json({ bookId, accountKey });
  }));
  router.post("/books/:bookId/generations", requireFeature, asyncRoute(async (req, res) => {
    res.json(await store.admit(req.uid!, routeParam(req, "bookId"), req.body));
  }));
  router.put("/generations/:generationId/manifest-pages/:pageOrdinal", requireFeature, asyncRoute(async (req, res) => {
    await store.putManifestPage(req.uid!, routeParam(req, "generationId"), ordinal(routeParam(req, "pageOrdinal")), req.body);
    res.status(204).end();
  }));
  router.post("/generations/:generationId/chunks/:chunkOrdinal", requireFeature, asyncRoute(async (req, res) => {
    const result = await store.submitChunk(req.uid!, routeParam(req, "generationId"), ordinal(routeParam(req, "chunkOrdinal")), req.body);
    if (result.enqueue) await enqueue(`/internal/book-analysis/extract/${result.receipt.jobId!}`,
      { jobId: result.receipt.jobId! }, `analysis-extract-${result.receipt.jobId!}`);
    res.json(result.receipt);
  }));
  router.get("/generations/:generationId", asyncRoute(async (req, res) => {
    const g = await store.readGeneration(req.uid!, routeParam(req, "generationId"));
    const progress: AnalysisProgress = {
      generationId: g.generationId, bookId: g.bookId, accountKey: bookAnalysisAccountKey(req.uid!, fingerprintSecret),
      documentVersion: g.admission.documentVersion, documentDigest: g.admission.documentDigest,
      status: g.status, stage: g.cursor.stage, processedChunks: g.processedChunks,
      requiredChunks: g.admission.chunkCount, processedUnits: g.processedUnits, requiredUnits: g.requiredUnits,
      nextCursor: g.status === "complete" || g.status === "failed" ? null : g.cursor,
      error: g.error, finalizedRevision: g.finalizedRevision, resultPages: g.resultPages,
    };
    res.json(progress);
  }));
  router.post("/generations/:generationId/finalize", requireFeature, asyncRoute(async (req, res) => {
    const result = await store.admitFinalize(req.uid!, routeParam(req, "generationId"));
    if (result.enqueue) await enqueue(`/internal/book-analysis/finalize/${result.receipt.jobId!}`,
      { jobId: result.receipt.jobId! }, `analysis-finalize-${result.receipt.jobId!}`);
    res.json(result.receipt);
  }));
  router.get("/generations/:generationId/pages/:pageId", asyncRoute(async (req, res) => {
    res.json(await store.readPublishedPage(req.uid!, routeParam(req, "generationId"), routeParam(req, "pageId")));
  }));
  router.use((error: unknown, _req: express.Request, _res: express.Response, next: express.NextFunction) => {
    next(error instanceof AnalysisSourceValidationError ? new HttpError(400, error.message) : error);
  });
  return router;
}
