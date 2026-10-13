import type { Storage } from "@google-cloud/storage";

/**
 * How long a client may download a private object after it was signed. The
 * bucket stays private; these short-lived URLs are the only client read path.
 */
export const SIGNED_READ_URL_MILLISECONDS = 10 * 60_000;

/**
 * Signs one private object for a client GET. Every caller uses V4 signing so
 * illustration images and narration audio share one URL format and expiry.
 */
export async function signedReadUrl(storage: Storage, bucket: string, path: string): Promise<string> {
  const [url] = await storage.bucket(bucket).file(path).getSignedUrl({
    version: "v4",
    action: "read",
    expires: Date.now() + SIGNED_READ_URL_MILLISECONDS,
  });
  return url;
}
