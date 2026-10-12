import { createServer, type IncomingMessage } from "node:http";
import type { AddressInfo } from "node:net";
import { lookup } from "node:dns/promises";
import sharp from "sharp";
import type { ImageHttpOptions } from "../image-provider-http.js";

export type RecordedImageRequest = {
  url: string;
  method: string;
  headers: Headers;
  body: Record<string, unknown> | undefined;
  redirect: RequestRedirect | undefined;
  dispatcher: unknown;
};
export type FixtureReply = { status?: number; body: unknown; headers?: Record<string, string> };

/** Real loopback HTTP responses behind injected fetch; production URL checks remain active. */
export async function imageProviderFixture(
  respond: (request: RecordedImageRequest, index: number) => FixtureReply,
  options: { dnsAddress?: string; timeoutMs?: number } = {},
) {
  const requests: RecordedImageRequest[] = [];
  const waits: number[] = [];
  let now = 0;
  const pending: RecordedImageRequest[] = [];
  const server = createServer(async (req: IncomingMessage, res) => {
    // Read the actual POST so protocol fixtures do not merely echo adapter arguments.
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(Buffer.from(chunk));
    const encoded = Buffer.concat(chunks).toString("utf8");
    const recorded = pending.shift()!;
    recorded.body = encoded ? JSON.parse(encoded) as Record<string, unknown> : undefined;
    requests.push(recorded);
    const reply = respond(recorded, requests.length - 1);
    const body = Buffer.isBuffer(reply.body) ? reply.body : Buffer.from(JSON.stringify(reply.body));
    res.writeHead(reply.status ?? 200, {
      "content-type": Buffer.isBuffer(reply.body) ? "image/png" : "application/json",
      ...reply.headers,
    });
    res.end(body);
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  const nativeFetch = globalThis.fetch;
  const fetchFixture: typeof fetch = async (input, init) => {
    const url = input instanceof Request ? input.url : String(input);
    const target = new URL(url);
    const recorded: RecordedImageRequest = {
      url, method: init?.method ?? "GET", headers: new Headers(init?.headers), body: undefined,
      redirect: init?.redirect,
      dispatcher: (init as RequestInit & { dispatcher?: unknown } | undefined)?.dispatcher,
    };
    pending.push(recorded);
    return await nativeFetch(`http://127.0.0.1:${port}${target.pathname}${target.search}`, {
      method: recorded.method, headers: recorded.headers, body: init?.body,
      signal: init?.signal, redirect: "manual",
    });
  };
  const httpOptions: ImageHttpOptions = {
    fetch: fetchFixture,
    lookup: (async () => [{ address: options.dnsAddress ?? "93.184.216.34", family: 4 }]) as unknown as typeof lookup,
    now: () => now,
    sleep: async milliseconds => { waits.push(milliseconds); now += milliseconds; },
    ...(options.timeoutMs == null ? {} : { timeoutMs: options.timeoutMs }),
  };
  return {
    requests, waits, httpOptions,
    advance: (milliseconds: number) => { now += milliseconds; },
    close: async () => {
      server.closeAllConnections();
      await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    },
  };
}

export async function tinyLandscapeImages() {
  const image = () => sharp({ create: { width: 6, height: 4, channels: 3, background: "#36749b" } });
  const png = await image().png().toBuffer();
  const jpeg = await image().jpeg().toBuffer();
  const webp = await image().webp().toBuffer();
  // An APP11 marker stands in for opaque provenance payload bytes; no authenticity claim.
  const marker = Buffer.from("Content Credentials: opaque fixture payload");
  const segment = Buffer.alloc(4);
  segment[0] = 0xff;
  segment[1] = 0xeb;
  segment.writeUInt16BE(marker.length + 2, 2);
  const provenanceJpeg = Buffer.concat([jpeg.subarray(0, 2), segment, marker, jpeg.subarray(2)]);
  return { png, jpeg, webp, provenanceJpeg };
}
