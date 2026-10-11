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

/** Applies the existing bounded, non-empty string contract without normalization. */
export function requireString(value: unknown, label: string, maxLength = 500): string {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) {
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
