/**
 * Durations shared by more than one feature. Values used by a single call site
 * stay next to that use (for example the narration claim lease and the book
 * re-registration purge grace). Worker request timeout and claim lease live in
 * `fences.ts` with the lease checks they bound.
 */

const DAY_MILLISECONDS = 24 * 60 * 60_000;

/**
 * Lifetime of published generated assets (illustration images and cloud
 * narration audio). Clients are told the narration value in days, so both
 * forms come from one number.
 */
export const ASSET_RETENTION_DAYS = 30;
export const ASSET_RETENTION_MILLISECONDS = ASSET_RETENTION_DAYS * DAY_MILLISECONDS;

/**
 * Lifetime of temporary prose inputs (illustration job inputs, narration
 * inputs, book-analysis inputs). The `expiresAt` field written with this value
 * drives the Firestore TTL policies; narration also treats unsubmitted
 * reservations older than it as abandoned.
 */
export const PROSE_INPUT_TTL_MILLISECONDS = DAY_MILLISECONDS;
