import type { NextFunction, Request, Response } from "express";

/** Expected illustration failures retain identity through the final HTTP translator. */
export class HttpError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

/** Forwards rejected API and worker operations to the shared error middleware. */
export function asyncRoute(
  handler: (req: Request & { uid?: string }, res: Response) => Promise<void>,
) {
  return (req: Request & { uid?: string }, res: Response, next: NextFunction) => {
    handler(req, res).catch(next);
  };
}

/**
 * The single translation from failures to client-visible `{error}` bodies.
 * Only `HttpError` messages reach clients; anything else is an internal 500
 * with a fixed message so provider or storage details never leak. Production
 * logs only category and status; request bodies and provider responses are
 * excluded. Tests pass a silent `log` while keeping identical responses.
 */
export function httpErrorHandler(log: (line: string) => void = console.error) {
  return (error: unknown, _req: Request, res: Response, _next: NextFunction) => {
    const status = error instanceof HttpError ? error.status : 500;
    const message = error instanceof HttpError ? error.message : "Request failed.";
    log(JSON.stringify({ category: error instanceof HttpError ? "http" : "internal", status }));
    res.status(status).json({ error: message });
  };
}

/** Applies the existing bounded, non-empty string contract without normalization. */
export function requireString(value: unknown, label: string, maxLength = 500): string {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) {
    throw new HttpError(400, `${label} is invalid.`);
  }
  return value;
}

/** Applies the bounded safe-integer body contract; rejects numeric strings and fractions. */
export function requireInteger(value: unknown, label: string, minimum: number, maximum = Number.MAX_SAFE_INTEGER): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new HttpError(400, `${label} is invalid.`);
  }
  return value;
}

/**
 * Validates route identifiers with the existing 200-character bound and, when
 * given, a non-global `pattern` the whole value must match.
 */
export function routeParam(req: Request, name: string, pattern?: RegExp): string {
  const value = requireString(req.params[name], `${name} route parameter`, 200);
  if (pattern && !pattern.test(value)) throw new HttpError(400, `${name} route parameter is invalid.`);
  return value;
}
