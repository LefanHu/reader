import express, { type NextFunction, type Request, type Response } from "express";
import sharp from "sharp";

/**
 * Pipeline-test image service. It returns a landscape PNG that lists the exact
 * prompt the worker sent, so a developer can see end to end that generation,
 * validation, moderation, storage, download and the gallery all work without a
 * paid provider. Deployed privately (dev only); Cloud Run IAM is the only gate.
 */
const WIDTH = 1536;
const HEIGHT = 1024;
const COLUMNS = 108;
const MAX_LINES = 36;
const MAX_PROMPT_CHARACTERS = 50_000;

/** Replace lone surrogates, which XML cannot carry. */
function wellFormed(text: string): string {
  return text.replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, "\uFFFD");
}

/** Neutralize characters that are invalid or collapse in XML 1.0 text. */
function sanitize(text: string): string {
  return wellFormed(text)
    .replace(/\t/g, " ")
    .replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, "\uFFFD");
}

function escapeXml(text: string): string {
  return text.replace(/[&<>"']/g, (character) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" }[character]!
  ));
}

/**
 * Preserves the prompt's own newlines, hard-wraps each at 108 code points and
 * caps output at 36 lines; the last line reports how many characters are not
 * shown. Exported so the truncation arithmetic is testable without rasterizing.
 */
export function layoutPrompt(prompt: string): string[] {
  const wrapped: string[] = [];
  for (const logical of sanitize(prompt).split("\n")) {
    const points = Array.from(logical);
    if (points.length === 0) wrapped.push("");
    for (let start = 0; start < points.length; start += COLUMNS) {
      wrapped.push(points.slice(start, start + COLUMNS).join(""));
    }
  }
  if (wrapped.length <= MAX_LINES) return wrapped;
  const hidden = wrapped.slice(MAX_LINES - 1).reduce((sum, line) => sum + Array.from(line).length, 0);
  return [...wrapped.slice(0, MAX_LINES - 1), `… [truncated ${hidden} more characters]`];
}

/** Deterministic for a given input: no timestamps or randomness. */
export async function renderPromptImage(prompt: string, referenceCount: number): Promise<Buffer> {
  const lines = layoutPrompt(prompt);
  const body = lines.map((line, index) =>
    `<text x="40" y="${80 + index * 26}" xml:space="preserve" font-size="22">${escapeXml(line)}</text>`).join("");
  const footer = `references: ${referenceCount} · prompt characters: ${Array.from(wellFormed(prompt)).length}`;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}" viewBox="0 0 ${WIDTH} ${HEIGHT}">` +
    `<rect width="${WIDTH}" height="${HEIGHT}" fill="#ffffff"/>` +
    `<rect x="1" y="1" width="${WIDTH - 2}" height="${HEIGHT - 2}" fill="none" stroke="#222222" stroke-width="2"/>` +
    `<g font-family="DejaVu Sans Mono, monospace" fill="#111111">` +
    `<text x="40" y="40" font-size="26" font-weight="bold">Reader illustration pipeline test</text>` +
    `${body}<text x="40" y="1010" font-size="16" fill="#444444">${escapeXml(footer)}</text></g></svg>`;
  return sharp(Buffer.from(svg)).png().toBuffer();
}

/** Body validation is explicit: this service accepts only the documented render request. */
function parseRequest(body: unknown): { prompt: string; referenceCount: number } | undefined {
  if (!body || typeof body !== "object") return undefined;
  const { prompt, referenceCount } = body as Record<string, unknown>;
  if (typeof prompt !== "string" || prompt.length < 1 || prompt.length > MAX_PROMPT_CHARACTERS) return undefined;
  if (!Number.isInteger(referenceCount) || (referenceCount as number) < 0 || (referenceCount as number) > 2) return undefined;
  return { prompt, referenceCount: referenceCount as number };
}

export function createImageTestProviderApp(): express.Express {
  const app = express();
  app.use(express.json({ limit: "256kb" }));
  app.get("/health", (_req, res) => { res.json({ ok: true }); });
  app.post("/v1/render", async (req: Request, res: Response) => {
    const request = parseRequest(req.body);
    if (!request) {
      res.status(400).json({ error: "Invalid render request." });
      return;
    }
    try {
      const png = await renderPromptImage(request.prompt, request.referenceCount);
      res.json({ mimeType: "image/png", data: png.toString("base64") });
    } catch {
      // The prompt is never logged: it contains private novel text.
      res.status(500).json({ error: "Render failed." });
    }
  });
  app.use((_error: unknown, _req: Request, res: Response, _next: NextFunction) => {
    res.status(400).json({ error: "Invalid render request." });
  });
  return app;
}
