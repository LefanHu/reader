/**
 * Shared OpenAI service boundary: credential lookup, the REST base URL and a
 * bounded JSON POST. Image generation and book analysis keep their own bounded
 * transport (`image-provider-http.ts`) and only share the key and base URL; the
 * Realtime narration websocket shares only the key.
 */

/** Base URL of every OpenAI REST endpoint used by the backend. */
export const OPENAI_API_BASE_URL = "https://api.openai.com/v1";

/**
 * Deadline for one plain JSON REST call (moderation, Decisions), covering the
 * response body as well as the headers. These calls return small JSON results
 * in seconds; a minute bounds a stalled connection well inside the worker
 * request timeout without cutting off slow but healthy responses.
 */
export const OPENAI_JSON_TIMEOUT_MILLISECONDS = 60_000;

/**
 * The worker's OpenAI secret, or "" when this instance has none (API instances
 * never receive it). Read at call time so tests and deployments can set it late.
 */
export function openAIApiKey(env: NodeJS.ProcessEnv = process.env): string {
  return env.OPENAI_API_KEY ?? "";
}

/**
 * POSTs `body` as JSON to `path` under the base URL with the configured key and
 * a {@link OPENAI_JSON_TIMEOUT_MILLISECONDS} deadline. Throws before any
 * network use when the key is missing. Callers check the status and must never
 * log the response body, which can echo prompt text.
 */
export async function postOpenAIJson(path: string, body: unknown): Promise<Response> {
  const apiKey = openAIApiKey();
  if (!apiKey) throw new Error("OPENAI_API_KEY is not configured");
  return fetch(`${OPENAI_API_BASE_URL}${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(OPENAI_JSON_TIMEOUT_MILLISECONDS),
  });
}
