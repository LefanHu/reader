import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { once } from "node:events";
import { crc32 } from "node:zlib";
import test from "node:test";
import sharp from "sharp";
import { Agent } from "undici";
import { ImageProviderRegistry } from "./image-provider-registry.js";
import { OpenAIImageProvider } from "./image-providers/openai-image-provider.js";
import { GoogleImageProvider } from "./image-providers/google-image-provider.js";
import { snapshotImageGenerationConfig } from "./illustration-configuration.js";
import { MAX_IMAGE_BYTES, MAX_REFERENCE_BYTES, validateGeneratedImage, validateReferenceImage, validateReferenceImages } from "./image-generation.js";
import { createImageOperation, decodeImageBase64, isPublicImageAddress, MAX_PROVIDER_JSON_BYTES, pinnedImageLookup, requireProviderUrl, type ImageHttpOptions } from "./image-provider-http.js";
import { moderateImage } from "./openai.js";

/** Real local streamed HTTP bodies; the production endpoint is asserted first. */
async function protocolFixture(handler: (request: IncomingMessage, response: ServerResponse) => void,
  inspect: (url: string, init: RequestInit & { dispatcher?: Agent }) => void = () => {}) {
  const server = createServer(handler);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  assert(address && typeof address === "object");
  const local = `http://127.0.0.1:${address.port}/`;
  const nativeFetch = fetch;
  const options: ImageHttpOptions = {
    fetch: async (url, init) => {
      inspect(String(url), init as RequestInit & { dispatcher?: Agent });
      // Network test seam is private and ignores only the remote routing. Native
      // fetch still enforces redirects, aborts and incremental response streams.
      const { dispatcher: _dispatcher, ...request } = init as RequestInit & { dispatcher?: Agent };
      return nativeFetch(local, request);
    },
  };
  return { options, close: async () => { server.closeAllConnections(); await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())); } };
}

async function image(format: "png" | "jpeg" | "webp" = "png", width = 30, height = 20): Promise<Buffer> {
  return sharp({ create: { width, height, channels: 3, background: "#4283aa" } }).toFormat(format).toBuffer();
}

const publicLookup = (async () => [{ address: "8.8.8.8", family: 4 }]) as unknown as NonNullable<ImageHttpOptions["lookup"]>;

test("native validation preserves PNG/JPEG/WebP originals and determines reference MIME", async () => {
  for (const format of ["png", "jpeg", "webp"] as const) {
    const bytes = await image(format);
    const validated = await validateGeneratedImage(bytes);
    assert.strictEqual(validated.bytes, bytes);
    assert.equal(validated.mimeType, `image/${format}`);
    const [reference] = await validateReferenceImages([{ bytes, mimeType: "image/webp" }]);
    assert.equal(reference?.mimeType, `image/${format}`);
  }
  const oriented = await sharp(await image("jpeg", 20, 30)).withMetadata({ orientation: 6 }).jpeg().toBuffer();
  assert.equal((await validateGeneratedImage(oriented)).mimeType, "image/jpeg");
  const portrait = await image("png", 20, 30);
  await assert.rejects(validateGeneratedImage(portrait));
  await assert.rejects(validateGeneratedImage(await image(), "image/webp"));
  await assert.rejects(validateGeneratedImage(Buffer.from("not an image")));
  await assert.rejects(validateGeneratedImage((await image()).subarray(0, 40)));
  await assert.rejects(validateGeneratedImage(Buffer.alloc(MAX_IMAGE_BYTES + 1)));
  await assert.rejects(validateReferenceImage(Buffer.alloc(MAX_REFERENCE_BYTES + 1)));
  await assert.rejects(validateReferenceImages(Array.from({ length: 3 }, () => ({ bytes: Buffer.alloc(1), mimeType: "image/png" as const }))));
  const excessivePixels = await image("png", 6000, 3000);
  await assert.rejects(validateGeneratedImage(excessivePixels));
  // Identical frames are coalesced by libwebp; use distinct pixels to retain two.
  const animated = await sharp(Buffer.concat([Buffer.alloc(30 * 20 * 3, 100), Buffer.alloc(30 * 20 * 3, 200)]), {
    raw: { width: 30, height: 40, channels: 3, pageHeight: 20 },
  }).webp({ loop: 0, delay: [100, 100] }).toBuffer();
  await assert.rejects(validateGeneratedImage(animated));
  const png = await image();
  const animationChunk = Buffer.alloc(20);
  animationChunk.writeUInt32BE(8, 0);
  animationChunk.write("acTL", 4, "ascii");
  animationChunk.writeUInt32BE(2, 8);
  animationChunk.writeUInt32BE(crc32(animationChunk.subarray(4, 16)), 16);
  await assert.rejects(validateGeneratedImage(Buffer.concat([png.subarray(0, 33), animationChunk, png.subarray(33)])));
  const jpeg = await image("jpeg");
  const mpfMarker = Buffer.from([255, 226, 0, 6, 77, 80, 70, 0]);
  await assert.rejects(validateGeneratedImage(Buffer.concat([jpeg.subarray(0, 2), mpfMarker, jpeg.subarray(2)])));
});

test("base64 rejects malformed, noncanonical and oversized inputs before decode", () => {
  for (const value of [null, "", "a", "AAAA\n", "AA=A", "AB==", "AAB=", "====", "A".repeat(4 * Math.ceil(MAX_IMAGE_BYTES / 3) + 4)]) {
    assert.throws(() => decodeImageBase64(value));
  }
  assert.deepEqual(decodeImageBase64("AQI="), Buffer.from([1, 2]));
});

test("OpenAI snapshot transport keeps models, private references, store:false and native MIME", async () => {
  const original = await image("webp");
  const reference = await image("jpeg");
  let calls = 0;
  const fixture = await protocolFixture((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", chunk => chunks.push(chunk));
    req.on("end", () => {
      const body = JSON.parse(Buffer.concat(chunks).toString());
      assert.equal(body.model, "frozen-orchestrator");
      assert.equal(body.tools[0].model, "frozen-image");
      assert.equal(body.store, false);
      assert.equal(body.tools[0].moderation, "auto");
      assert.equal(body.tools[0].size, "1536x1024");
      assert.equal(body.tools[0].action, calls === 1 ? "generate" : "auto");
      assert.equal(body.input[0].content.length, calls);
      if (calls > 1) assert.match(body.input[0].content[1].image_url, /^data:image\/jpeg;base64,/);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ output: [{ type: "image_generation_call", status: "completed", result: original.toString("base64") }] }));
    });
  }, (url, init) => {
    calls++;
    assert.equal(url, "https://api.openai.com/v1/responses");
    assert.equal(init.redirect, "error");
    assert(init.dispatcher instanceof Agent);
    assert.equal((init.headers as Record<string, string>).authorization, "Bearer private-key");
  });
  try {
    const registry = new ImageProviderRegistry({ openai: new OpenAIImageProvider("private-key", fixture.options) });
    const config = snapshotImageGenerationConfig("openai", { OPENAI_IMAGE_MODEL: "frozen-image", OPENAI_IMAGE_ORCHESTRATOR_MODEL: "frozen-orchestrator" });
    await registry.validateCredentials(config);
    for (const refs of [[], [{ bytes: reference, mimeType: "image/webp" as const }], [{ bytes: reference, mimeType: "image/webp" as const }, { bytes: reference, mimeType: "image/webp" as const }]]) {
      const result = await registry.generate(config, "private scene", refs);
      assert.deepEqual(result.bytes, original);
      assert.equal(result.mimeType, "image/webp");
    }
    assert.equal(calls, 3);
  } finally { await fixture.close(); }
});

test("OpenAI refusals/errors/multiple images fail with no POST retry or fallback", async () => {
  const bytes = await image("webp");
  const cases = [
    { output: [{ type: "message", content: [{ type: "refusal", refusal: "private refusal" }] }] },
    { error: { message: "private prompt" } },
    { output: [{ type: "image_generation_call", result: bytes.toString("base64") }, { type: "image_generation_call", result: bytes.toString("base64") }] },
    { output: [{ type: "image_generation_call", result: "AB==" }] },
  ];
  for (const body of cases) {
    let calls = 0;
    const fixture = await protocolFixture((_req, res) => { calls++; res.end(JSON.stringify(body)); });
    try {
      const registry = new ImageProviderRegistry({ openai: new OpenAIImageProvider("key", fixture.options) });
      await assert.rejects(registry.generate(snapshotImageGenerationConfig("openai"), "private scene"), error => error instanceof Error && !error.message.includes("private"));
      assert.equal(calls, 1);
    } finally { await fixture.close(); }
  }
  await assert.rejects(new ImageProviderRegistry({ openai: new OpenAIImageProvider("") }).validateCredentials(snapshotImageGenerationConfig("openai")));
});

test("Google ADC Cloud protocol embeds actual references and rejects safety/text/thought-only responses", async () => {
  const bytes = await image();
  let calls = 0;
  let response: unknown = { candidates: [{ finishReason: "STOP", content: { parts: [{ text: "description" }, { inlineData: { mimeType: "image/png", data: bytes.toString("base64") } }] } }] };
  const fixture = await protocolFixture((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", chunk => chunks.push(chunk));
    req.on("end", () => {
      const body = JSON.parse(Buffer.concat(chunks).toString());
      assert.deepEqual(body.generationConfig, { candidateCount: 1, responseModalities: ["TEXT", "IMAGE"], imageConfig: { aspectRatio: "3:2", imageSize: "2K" } });
      assert.equal(body.tools, undefined);
      assert.equal(body.safetySettings, undefined);
      for (const part of body.contents[0].parts.slice(1)) assert.equal(part.inlineData.mimeType, "image/png");
      res.end(JSON.stringify(response));
    });
  }, (url, init) => {
    calls++;
    assert.equal(url, "https://aiplatform.googleapis.com/v1/projects/fixture-project/locations/global/publishers/google/models/gemini-nano-banana-2.1:generateContent");
    assert.equal((init.headers as Record<string, string>).authorization, "Bearer adc-token");
  });
  try {
    const provider = new GoogleImageProvider({ ...fixture.options, project: "fixture-project", accessToken: async () => "adc-token" });
    const registry = new ImageProviderRegistry({ google: provider });
    const config = snapshotImageGenerationConfig("google");
    await registry.validateCredentials(config);
    for (const count of [0, 1, 2]) {
      assert.deepEqual((await registry.generate(config, "scene", Array.from({ length: count }, () => ({ bytes, mimeType: "image/webp" as const })))).bytes, bytes);
    }
    for (const invalid of [
      { promptFeedback: { blockReason: "SAFETY" } },
      { candidates: [{ finishReason: "SAFETY" }] },
      { candidates: [{ content: { parts: [{ text: "no image" }] } }] },
      { candidates: [{ content: { parts: [{ thought: true, inlineData: { mimeType: "image/png", data: bytes.toString("base64") } }] } }] },
      { candidates: [{ content: { parts: [{ inlineData: { mimeType: "image/webp", data: bytes.toString("base64") } }] } }] },
    ]) {
      response = invalid;
      await assert.rejects(registry.generate(config, "scene"));
    }
    assert.equal(calls, 8);
    await assert.rejects(new GoogleImageProvider({ project: "fixture-project", accessToken: async () => null }).validateCredentials());
  } finally { await fixture.close(); }
});

test("URL and public DNS boundaries reject SSRF before fetch", async () => {
  for (const url of [
    "http://delivery.eu.bfl.ai/image", "https://user:pass@delivery.eu.bfl.ai/image", "https://delivery.eu.bfl.ai:444/image",
    "https://delivery.eu.bfl.ai/image#fragment", "https://127.0.0.1/image", "https://[::1]/image",
    "https://delivery.eu.bfl.ai.evil.test/image", "https://evil-delivery.eu.bfl.ai/image", "https://delivery.eu.bfl.ai./image",
  ]) assert.throws(() => requireProviderUrl(url, "flux"));
  assert.equal(requireProviderUrl("https://api.eu.bfl.ai/poll?id=opaque", "flux-poll").hostname, "api.eu.bfl.ai");
  assert.equal(requireProviderUrl("https://dashscope-result-sg.oss-ap-southeast-1.aliyuncs.com/image", "qwen").hostname, "dashscope-result-sg.oss-ap-southeast-1.aliyuncs.com");
  assert.throws(() => requireProviderUrl("https://dashscope-result-sg.oss-ap-southeast-1.aliyuncs.com.evil.test/image", "qwen"));
  for (const address of ["127.0.0.1", "10.0.0.1", "169.254.169.254", "100.64.0.1", "192.0.2.1", "0.0.0.0", "::1", "::ffff:8.8.8.8", "fe80::1", "fc00::1", "2001:db8::1"]) assert.equal(isPublicImageAddress(address), false);
  for (const address of ["8.8.8.8", "2606:4700:4700::1111"]) assert.equal(isPublicImageAddress(address), true);
  let called = false;
  const operation = createImageOperation({ lookup: (async () => [{ address: "8.8.8.8", family: 4 }, { address: "127.0.0.1", family: 4 }]) as unknown as ImageHttpOptions["lookup"], fetch: async () => { called = true; return new Response(); } });
  try { await assert.rejects(operation.downloadImage("https://delivery.eu.bfl.ai/image", "flux")); assert.equal(called, false); }
  finally { operation.close(); }
});

test("pinned connector returns only checked addresses and fences hostname changes", () => {
  const addresses = [{ address: "8.8.8.8", family: 4 }, { address: "2606:4700:4700::1111", family: 6 }];
  const pinned = pinnedImageLookup("delivery.eu.bfl.ai", addresses);
  pinned("delivery.eu.bfl.ai", { all: true }, (error, result) => { assert.equal(error, null); assert.deepEqual(result, addresses); });
  pinned("delivery.eu.bfl.ai", {}, (error, result, family) => { assert.equal(error, null); assert.equal(result, "8.8.8.8"); assert.equal(family, 4); });
  pinned("changed.example", {}, error => { assert(error instanceof Error); });
  assert.throws(() => pinnedImageLookup("delivery.eu.bfl.ai", [{ address: "127.0.0.1", family: 4 }]));
});

test("bounded downloads never forward keys; redirects, JSON/image excess and deadlines fail closed", async () => {
  let fetches = 0;
  const fixture = await protocolFixture((_req, res) => { res.end("asset"); }, (_url, init) => {
    fetches++;
    assert.equal(init.headers, undefined);
    assert.equal(init.redirect, "error");
    assert(init.dispatcher instanceof Agent);
  });
  const operation = createImageOperation({ ...fixture.options, lookup: publicLookup });
  try { assert.equal((await operation.downloadImage("https://delivery.eu.bfl.ai/image?signed=private", "flux")).toString(), "asset"); assert.equal(fetches, 1); }
  finally { operation.close(); await fixture.close(); }

  const redirected = await protocolFixture((_req, res) => { res.writeHead(302, { location: "http://169.254.169.254/" }); res.end(); });
  const redirectOperation = createImageOperation(redirected.options);
  try { await assert.rejects(redirectOperation.postJson("https://api.openai.com/v1/responses", {}, {})); }
  finally { redirectOperation.close(); await redirected.close(); }

  const stalled = await protocolFixture((_req, res) => { res.writeHead(200); res.flushHeaders(); });
  const stalledOperation = createImageOperation({ ...stalled.options, timeoutMs: 25 });
  try { await assert.rejects(stalledOperation.postJson("https://api.openai.com/v1/responses", {}, {})); }
  finally { stalledOperation.close(); await stalled.close(); }

  for (const kind of ["json", "image"] as const) {
    const limit = kind === "json" ? MAX_PROVIDER_JSON_BYTES : MAX_IMAGE_BYTES;
    let cancelled = false;
    const oversized = createImageOperation({ lookup: publicLookup, fetch: async () => new Response(new ReadableStream({
      start(controller) { controller.enqueue(new Uint8Array(limit)); controller.enqueue(new Uint8Array(1)); },
      cancel() { cancelled = true; },
    })) });
    try {
      await assert.rejects(kind === "json" ? oversized.postJson("https://api.openai.com/v1/responses", {}, {}) : oversized.downloadImage("https://delivery.eu.bfl.ai/image", "flux"));
      assert.equal(cancelled, true);
    } finally { oversized.close(); }
  }
  let time = 0;
  const timed = createImageOperation({ now: () => time, sleep: async ms => { time += ms; }, timeoutMs: 10 });
  try { await assert.rejects(timed.sleep(20)); assert.throws(() => timed.remainingMs()); }
  finally { timed.close(); }
  const synchronous = createImageOperation({ now: () => time, fetch: async () => { time += 31_000; return new Response("{}"); } });
  try { assert.deepEqual(await synchronous.postJson("https://api.openai.com/v1/responses", {}, {}), {}); }
  finally { synchronous.close(); }
});

test("OpenAI moderation embeds verified native MIME for every generator", async t => {
  const previousKey = process.env.OPENAI_API_KEY;
  process.env.OPENAI_API_KEY = "moderation-only-key";
  let expectedMime = "";
  const fixture = await protocolFixture((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", chunk => chunks.push(chunk));
    req.on("end", () => {
      const body = JSON.parse(Buffer.concat(chunks).toString());
      assert.equal(body.model, "omni-moderation-latest");
      assert(body.input[0].image_url.url.startsWith(`data:${expectedMime};base64,`));
      res.end(JSON.stringify({ results: [{ flagged: false }] }));
    });
  }, (url, init) => {
    assert.equal(url, "https://api.openai.com/v1/moderations");
    assert.equal((init.headers as Record<string, string>).authorization, "Bearer moderation-only-key");
  });
  t.mock.method(globalThis, "fetch", fixture.options.fetch!);
  try {
    for (const format of ["png", "jpeg", "webp"] as const) {
      expectedMime = `image/${format}`;
      assert.equal(await moderateImage(await image(format), `image/${format}`), false);
    }
  } finally {
    t.mock.restoreAll();
    if (previousKey === undefined) delete process.env.OPENAI_API_KEY;
    else process.env.OPENAI_API_KEY = previousKey;
    await fixture.close();
  }
});
