import assert from "node:assert/strict";
import test from "node:test";
import sharp from "sharp";
import { ImageProviderRegistry } from "../image-provider-registry.js";
import { snapshotImageGenerationConfig } from "../illustration-configuration.js";
import { MAX_IMAGE_BYTES, MAX_REFERENCE_BYTES, type ReferenceImage } from "../image-generation.js";
import type { ImageHttpOptions } from "../image-provider-http.js";
import { imageProviderFixture, tinyLandscapeImages, type FixtureReply } from "../test-support/image-provider-fixture.js";
import { SeedreamImageProvider } from "./seedream-image-provider.js";
import { QwenImageProvider } from "./qwen-image-provider.js";
import { XaiImageProvider } from "./xai-image-provider.js";
import { FluxImageProvider } from "./flux-image-provider.js";

const prompt = "A traveler approaches a quiet stone bridge.";
const taskId = "11111111-2222-4333-8444-555555555555";
const pollUrl = `https://api.eu1.bfl.ai/v1/get_result?id=${taskId}&token=fixture`;
const fluxAsset = "https://delivery.eu1.bfl.ai/private/original.jpg?signature=fixture";
const qwenAsset = "https://dashscope-result-sg.oss-ap-southeast-1.aliyuncs.com/private/result.png?signature=fixture";
const factories = {
  seedream: (key: string, options?: ImageHttpOptions) => new SeedreamImageProvider(key, options),
  qwen: (key: string, options?: ImageHttpOptions) => new QwenImageProvider(key, options),
  xai: (key: string, options?: ImageHttpOptions) => new XaiImageProvider(key, options),
  flux: (key: string, options?: ImageHttpOptions) => new FluxImageProvider(key, options),
};
type DirectId = keyof typeof factories;

function registry(id: DirectId, options: ImageHttpOptions, key = "fixture-key") {
  return new ImageProviderRegistry({ [id]: factories[id](key, options) });
}

function uri(reference: ReferenceImage): string {
  return `data:${reference.mimeType};base64,${reference.bytes.toString("base64")}`;
}

for (const referenceCount of [0, 1, 2]) {
  test(`Seedream emits exact fixed request and preserves native bytes with ${referenceCount} references`, async t => {
    const images = await tinyLandscapeImages();
    const outputs = [images.png, images.jpeg, images.webp];
    const mimeTypes = ["image/png", "image/jpeg", "image/webp"];
    const output = outputs[referenceCount]!;
    const references: ReferenceImage[] = [
      { bytes: images.png, mimeType: "image/png" }, { bytes: images.jpeg, mimeType: "image/jpeg" },
    ].slice(0, referenceCount) as ReferenceImage[];
    const fixture = await imageProviderFixture(() => ({ body: { data: [{ b64_json: output.toString("base64") }] } }));
    t.after(fixture.close);
    const result = await registry("seedream", fixture.httpOptions).generate(snapshotImageGenerationConfig("seedream"), prompt, references);
    assert.equal(result.mimeType, mimeTypes[referenceCount]);
    assert.deepEqual(result.bytes, output);
    assert.equal(fixture.requests.length, 1);
    const request = fixture.requests[0]!;
    assert.equal(request.url, "https://ark.ap-southeast.bytepluses.com/api/v3/images/generations");
    assert.equal(request.method, "POST");
    assert.equal(request.headers.get("authorization"), "Bearer fixture-key");
    assert.equal(request.redirect, "error");
    assert.deepEqual(request.body, {
      model: "seedream-4-0-250828", prompt, size: "1536x1024", response_format: "b64_json", stream: false,
      watermark: false, sequential_image_generation: "disabled",
      ...(references.length ? { image: references.map(uri) } : {}),
    });
  });

  test(`Qwen downloads exactly one private PNG with ${referenceCount} inline references`, async t => {
    const images = await tinyLandscapeImages();
    const references: ReferenceImage[] = [
      { bytes: images.png, mimeType: "image/png" }, { bytes: images.webp, mimeType: "image/webp" },
    ].slice(0, referenceCount) as ReferenceImage[];
    const fixture = await imageProviderFixture((_request, index) => index === 0
      ? { body: { data: [{ url: qwenAsset }] } } : { body: images.png });
    t.after(fixture.close);
    const result = await registry("qwen", fixture.httpOptions).generate(snapshotImageGenerationConfig("qwen"), prompt, references);
    assert.deepEqual(result, { bytes: images.png, mimeType: "image/png" });
    assert.equal(fixture.requests.length, 2);
    assert.equal(fixture.requests[0]!.url, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/images/generations");
    assert.equal(fixture.requests[0]!.headers.get("authorization"), "Bearer fixture-key");
    assert.deepEqual(fixture.requests[0]!.body, {
      model: "qwen-image-3.0", prompt, size: "1536x1024", n: 1, watermark: false, prompt_extend: false,
      ...(references.length ? { image: references.map(uri) } : {}),
    });
    const download = fixture.requests[1]!;
    assert.equal(download.url, qwenAsset);
    assert.equal(download.method, "GET");
    assert.equal(download.headers.get("authorization"), null);
    assert.equal(download.headers.get("x-key"), null);
    assert.equal(download.redirect, "error");
    assert.ok(download.dispatcher, "provider assets use the public-DNS pinned dispatcher");
  });

  test(`xAI selects generation versus multi-reference edit for ${referenceCount} references`, async t => {
    const images = await tinyLandscapeImages();
    const references: ReferenceImage[] = [
      { bytes: images.jpeg, mimeType: "image/jpeg" }, { bytes: images.webp, mimeType: "image/webp" },
    ].slice(0, referenceCount) as ReferenceImage[];
    const fixture = await imageProviderFixture(() => ({ body: {
      data: [{ b64_json: images.jpeg.toString("base64"), mime_type: "image/jpeg" }],
    } }));
    t.after(fixture.close);
    const result = await registry("xai", fixture.httpOptions).generate(snapshotImageGenerationConfig("xai"), prompt, references);
    assert.deepEqual(result, { bytes: images.jpeg, mimeType: "image/jpeg" });
    assert.equal(fixture.requests.length, 1);
    const request = fixture.requests[0]!;
    assert.equal(request.url, `https://api.x.ai/v1/images/${referenceCount ? "edits" : "generations"}`);
    assert.equal(request.headers.get("authorization"), "Bearer fixture-key");
    assert.deepEqual(request.body, {
      model: "grok-imagine-image-2.0", prompt, n: 1, aspect_ratio: "3:2", resolution: "1.5k", response_format: "b64_json",
      ...(references.length ? { images: references.map(reference => ({ url: uri(reference) })) } : {}),
    });
  });

  test(`FLUX polls returned regional URL and preserves opaque provenance with ${referenceCount} references`, async t => {
    const images = await tinyLandscapeImages();
    const references: ReferenceImage[] = [
      { bytes: images.png, mimeType: "image/png" }, { bytes: images.webp, mimeType: "image/webp" },
    ].slice(0, referenceCount) as ReferenceImage[];
    const replies: FixtureReply[] = [
      { body: { id: taskId, polling_url: pollUrl } },
      { body: { id: taskId, status: "Pending" } },
      { body: { id: taskId, status: "Reasoning" } },
      { body: { id: taskId, status: "Generating" } },
      { body: { id: taskId, status: "Ready", result: { sample: fluxAsset } } },
      { body: images.provenanceJpeg },
    ];
    const fixture = await imageProviderFixture((_request, index) => replies[index]!);
    t.after(fixture.close);
    const result = await registry("flux", fixture.httpOptions).generate(snapshotImageGenerationConfig("flux"), prompt, references);
    assert.equal(result.mimeType, "image/jpeg");
    assert.deepEqual(result.bytes, images.provenanceJpeg);
    assert.ok(result.bytes.includes(Buffer.from("Content Credentials: opaque fixture payload")));
    assert.deepEqual(fixture.waits, [2_000, 2_000, 2_000]);
    assert.equal(fixture.requests.length, 6);
    const submission = fixture.requests[0]!;
    assert.equal(submission.url, "https://api.bfl.ai/v1/flux-3-image");
    assert.equal(submission.headers.get("x-key"), "fixture-key");
    assert.deepEqual(submission.body, {
      prompt, aspect_ratio: "3:2", resolution: "1.5k", grounding: false, safety_tolerance: 2,
      ...(references.length ? { images: references.map(reference => reference.bytes.toString("base64")) } : {}),
    });
    for (const poll of fixture.requests.slice(1, 5)) {
      assert.equal(poll.url, pollUrl);
      assert.equal(poll.headers.get("x-key"), "fixture-key");
      assert.equal(poll.headers.get("authorization"), null);
      assert.ok(poll.dispatcher);
      assert.equal(poll.redirect, "error");
    }
    const download = fixture.requests[5]!;
    assert.equal(download.url, fluxAsset);
    assert.equal(download.headers.get("x-key"), null);
    assert.equal(download.headers.get("authorization"), null);
    assert.equal(download.redirect, "error");
    assert.ok(download.dispatcher);
  });
}

for (const id of Object.keys(factories) as DirectId[]) {
  test(`${id} fails before generation for missing credentials or invalid reference boundaries`, async t => {
    const images = await tinyLandscapeImages();
    const fixture = await imageProviderFixture(() => ({ body: {} }));
    t.after(fixture.close);
    await assert.rejects(registry(id, fixture.httpOptions, "").generate(snapshotImageGenerationConfig(id), prompt));
    const valid: ReferenceImage = { bytes: images.png, mimeType: "image/png" };
    for (const references of [
      [valid, valid, valid],
      [{ bytes: Buffer.alloc(MAX_REFERENCE_BYTES + 1), mimeType: "image/png" } as ReferenceImage],
      [{ bytes: Buffer.from("corrupt private reference"), mimeType: "image/webp" } as ReferenceImage],
    ]) {
      await assert.rejects(registry(id, fixture.httpOptions).generate(snapshotImageGenerationConfig(id), prompt, references));
    }
    const adapter = factories[id]("fixture-key", fixture.httpOptions);
    await assert.rejects(adapter.generate(snapshotImageGenerationConfig(id === "flux" ? "xai" : "flux"), prompt));
    assert.equal(fixture.requests.length, 0);
  });

  test(`${id} never retries a rejected POST or leaks upstream error contents`, async t => {
    const fixture = await imageProviderFixture(() => ({ status: 429, body: { error: "private prompt signed-url fixture-key" } }));
    t.after(fixture.close);
    await assert.rejects(registry(id, fixture.httpOptions).generate(snapshotImageGenerationConfig(id), prompt), error => {
      assert.doesNotMatch(String(error), /private prompt|signed-url|fixture-key/);
      return true;
    });
    assert.equal(fixture.requests.length, 1);
  });
}

for (const id of ["seedream", "xai", "qwen"] as const) {
  test(`${id} rejects top-level and per-image errors, missing, empty and multiple images`, async t => {
    const images = await tinyLandscapeImages();
    const successful = id === "qwen" ? { url: qwenAsset } : { b64_json: images.png.toString("base64") };
    const malformed = [
      {}, { data: [] }, { data: [successful, successful] }, { data: [null] }, { data: [{}] },
      { error: { message: "private upstream details" }, data: [successful] },
      { data: [{ ...successful, error: { code: "safety_rejected" } }] },
    ];
    for (const body of malformed) {
      const fixture = await imageProviderFixture(() => ({ body }));
      t.after(fixture.close);
      await assert.rejects(registry(id, fixture.httpOptions).generate(snapshotImageGenerationConfig(id), prompt));
      assert.equal(fixture.requests.length, 1);
    }
  });
}

test("base64 transports reject malformed, oversized, corrupt, wrong-aspect and over-pixel images", async t => {
  const images = await tinyLandscapeImages();
  const square = await sharp({ create: { width: 4, height: 4, channels: 3, background: "white" } }).png().toBuffer();
  const tooManyPixels = await sharp({ create: { width: 6147, height: 4098, channels: 3, background: "white" } }).png().toBuffer();
  const encodings = [
    "", "%%%=", "AB==", "data:image/png;base64,AAAA", "AAAA\n", "A".repeat(4 * Math.ceil(MAX_IMAGE_BYTES / 3) + 4),
    Buffer.from("not an image").toString("base64"), images.png.subarray(0, 24).toString("base64"),
    square.toString("base64"), tooManyPixels.toString("base64"),
  ];
  for (const id of ["seedream", "xai"] as const) {
    for (const b64_json of encodings) {
      const fixture = await imageProviderFixture(() => ({ body: { data: [{ b64_json }] } }));
      t.after(fixture.close);
      await assert.rejects(registry(id, fixture.httpOptions).generate(snapshotImageGenerationConfig(id), prompt));
      assert.equal(fixture.requests.length, 1);
    }
  }
});

test("xAI refusal and false MIME cannot be accepted as generated artwork", async t => {
  const images = await tinyLandscapeImages();
  for (const body of [
    { refusal: "blocked", data: [{ b64_json: images.png.toString("base64") }] },
    { data: [{ refusal: "blocked", b64_json: images.png.toString("base64") }] },
    { data: [{ mime_type: "image/jpeg", b64_json: images.png.toString("base64") }] },
  ]) {
    const fixture = await imageProviderFixture(() => ({ body }));
    t.after(fixture.close);
    await assert.rejects(registry("xai", fixture.httpOptions).generate(snapshotImageGenerationConfig("xai"), prompt));
  }
});

test("registry establishes reference MIME from bytes instead of caller filenames", async t => {
  const images = await tinyLandscapeImages();
  const fixture = await imageProviderFixture(() => ({ body: { data: [{ b64_json: images.png.toString("base64") }] } }));
  t.after(fixture.close);
  await registry("seedream", fixture.httpOptions).generate(snapshotImageGenerationConfig("seedream"), prompt,
    [{ bytes: images.jpeg, mimeType: "image/webp" }]);
  assert.deepEqual(fixture.requests[0]!.body!.image, [`data:image/jpeg;base64,${images.jpeg.toString("base64")}`]);
});

for (const status of ["Request Moderated", "Content Moderated", "Error", "Failed", "Task not found", "Unknown", null]) {
  test(`FLUX terminates safely on ${String(status)} without downloading`, async t => {
    const fixture = await imageProviderFixture((_request, index) => index === 0
      ? { body: { id: taskId, polling_url: pollUrl } } : { body: { status, result: { sample: fluxAsset } } });
    t.after(fixture.close);
    await assert.rejects(registry("flux", fixture.httpOptions).generate(snapshotImageGenerationConfig("flux"), prompt));
    assert.equal(fixture.requests.length, 2);
    assert.deepEqual(fixture.waits, []);
  });
}

test("FLUX rejects invalid task identities, missing result and mismatched poll identity", async t => {
  for (const submission of [{}, { id: "../private", polling_url: pollUrl }, { id: taskId }, { id: taskId, polling_url: null }]) {
    const fixture = await imageProviderFixture(() => ({ body: submission }));
    t.after(fixture.close);
    await assert.rejects(registry("flux", fixture.httpOptions).generate(snapshotImageGenerationConfig("flux"), prompt));
    assert.equal(fixture.requests.length, 1);
  }
  for (const result of [
    { status: "Ready" }, { status: "Ready", result: {} },
    { id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", status: "Ready", result: { sample: fluxAsset } },
  ]) {
    const fixture = await imageProviderFixture((_request, index) => index === 0
      ? { body: { id: taskId, polling_url: pollUrl } } : { body: result });
    t.after(fixture.close);
    await assert.rejects(registry("flux", fixture.httpOptions).generate(snapshotImageGenerationConfig("flux"), prompt));
    assert.equal(fixture.requests.length, 2);
  }
});

test("FLUX polling and completed-asset download share one operation deadline", async t => {
  const fixture = await imageProviderFixture((_request, index) => index === 0
    ? { body: { id: taskId, polling_url: pollUrl } } : { body: { status: "Pending" } }, { timeoutMs: 5_000 });
  t.after(fixture.close);
  await assert.rejects(registry("flux", fixture.httpOptions).generate(snapshotImageGenerationConfig("flux"), prompt), /timed out/i);
  assert.ok(fixture.requests.length <= 4);
  assert.deepEqual(fixture.waits, [2_000, 2_000, 1_000]);

  const late = await imageProviderFixture((_request, index) => {
    if (index === 0) return { body: { id: taskId, polling_url: pollUrl } };
    late.advance(120_001);
    return { body: { status: "Ready", result: { sample: fluxAsset } } };
  });
  t.after(late.close);
  await assert.rejects(registry("flux", late.httpOptions).generate(snapshotImageGenerationConfig("flux"), prompt));
  assert.equal(late.requests.length, 2);
});

const badUrls = [
  "http://delivery.eu1.bfl.ai/image", "https://user:password@delivery.eu1.bfl.ai/image",
  "https://delivery.eu1.bfl.ai:8443/image", "https://delivery.eu1.bfl.ai/image#fragment",
  "https://127.0.0.1/image", "https://[::1]/image", "https://delivery.eu1.bfl.ai.evil.test/image",
  "https://evildelivery.eu1.bfl.ai/image", "https://delivery.eu1.bfl.ai./image",
  "https://delivery.eu1.bfl.ai@evil.test/image", "https://unknown.example/image",
];

test("Qwen and FLUX reject malicious returned assets before any asset request", async t => {
  for (const id of ["qwen", "flux"] as const) {
    for (const url of badUrls) {
      const fixture = await imageProviderFixture((_request, index) => id === "qwen"
        ? { body: { data: [{ url }] } }
        : index === 0 ? { body: { id: taskId, polling_url: pollUrl } }
          : { body: { status: "Ready", result: { sample: url } } });
      t.after(fixture.close);
      await assert.rejects(registry(id, fixture.httpOptions).generate(snapshotImageGenerationConfig(id), prompt));
      assert.equal(fixture.requests.length, id === "qwen" ? 1 : 2);
    }
  }
  for (const url of [
    "https://dashscope-result-sg.oss-ap-southeast-1.aliyuncs.com.evil.test/image",
    "https://dashscope-result-sg.oss-ap-southeast-1.aliyuncs.com:8443/image",
    "https://dashscope-result-sg.oss-ap-southeast-1.aliyuncs.com/image#fragment",
    "https://user@dashscope-result-sg.oss-ap-southeast-1.aliyuncs.com/image",
    "https://dashscope-result-sg.evil.oss-ap-southeast-1.aliyuncs.com/image",
  ]) {
    const fixture = await imageProviderFixture(() => ({ body: { data: [{ url }] } }));
    t.after(fixture.close);
    await assert.rejects(registry("qwen", fixture.httpOptions).generate(snapshotImageGenerationConfig("qwen"), prompt));
    assert.equal(fixture.requests.length, 1);
  }
});

test("FLUX rejects malicious returned polling URLs before forwarding its key", async t => {
  for (const url of [...badUrls, "https://api.eu1.bfl.ai.evil.test/v1/get_result", "https://api.eu1.bfl.ai:8443/v1/get_result"]) {
    const fixture = await imageProviderFixture(() => ({ body: { id: taskId, polling_url: url } }));
    t.after(fixture.close);
    await assert.rejects(registry("flux", fixture.httpOptions).generate(snapshotImageGenerationConfig("flux"), prompt));
    assert.equal(fixture.requests.length, 1);
  }
});

for (const dnsAddress of ["127.0.0.1", "10.0.0.1", "169.254.169.254", "::1", "::ffff:127.0.0.1"]) {
  test(`provider-returned hosts resolving to ${dnsAddress} are blocked before fetch`, async t => {
    for (const id of ["qwen", "flux"] as const) {
      const fixture = await imageProviderFixture(() => id === "qwen"
        ? { body: { data: [{ url: qwenAsset }] } } : { body: { id: taskId, polling_url: pollUrl } }, { dnsAddress });
      t.after(fixture.close);
      await assert.rejects(registry(id, fixture.httpOptions).generate(snapshotImageGenerationConfig(id), prompt));
      assert.equal(fixture.requests.length, 1);
    }
  });
}

test("Qwen and FLUX never follow redirects from returned polling or asset URLs", async t => {
  for (const id of ["qwen", "flux"] as const) {
    for (const redirectPoll of id === "flux" ? [false, true] : [false]) {
      const fixture = await imageProviderFixture((_request, index) => {
        if (index === 0) return id === "qwen" ? { body: { data: [{ url: qwenAsset }] } } : { body: { id: taskId, polling_url: pollUrl } };
        if (id === "flux" && !redirectPoll && index === 1) return { body: { status: "Ready", result: { sample: fluxAsset } } };
        return { status: 302, headers: { location: "https://attacker.test/private" }, body: {} };
      });
      t.after(fixture.close);
      await assert.rejects(registry(id, fixture.httpOptions).generate(snapshotImageGenerationConfig(id), prompt));
      assert.equal(fixture.requests.length, id === "flux" && !redirectPoll ? 3 : 2);
      assert.ok(fixture.requests.every(request => !request.url.includes("attacker.test")));
    }
  }
});

test("downloaded bodies stay bounded and Qwen cannot mislabel JPEG as PNG", async t => {
  const images = await tinyLandscapeImages();
  for (const body of [images.jpeg, Buffer.alloc(MAX_IMAGE_BYTES + 1)]) {
    const fixture = await imageProviderFixture((_request, index) => index === 0
      ? { body: { data: [{ url: qwenAsset }] } } : { body });
    t.after(fixture.close);
    await assert.rejects(registry("qwen", fixture.httpOptions).generate(snapshotImageGenerationConfig("qwen"), prompt));
    assert.equal(fixture.requests.length, 2);
  }
});

test("synchronous providers may synthesize beyond 30 seconds within the operation deadline", async t => {
  const images = await tinyLandscapeImages();
  for (const id of ["seedream", "qwen", "xai"] as const) {
    const fixture = await imageProviderFixture((_request, index) => {
      if (index === 0) {
        fixture.advance(31_000);
        return { body: { data: [id === "qwen" ? { url: qwenAsset } : { b64_json: images.png.toString("base64") }] } };
      }
      return { body: images.png };
    });
    t.after(fixture.close);
    const result = await registry(id, fixture.httpOptions).generate(snapshotImageGenerationConfig(id), prompt);
    assert.deepEqual(result, { bytes: images.png, mimeType: "image/png" });
    assert.equal(fixture.requests.filter(request => request.method === "POST").length, 1);
  }
});

test("a synchronous response arriving after the operation deadline is never published or retried", async t => {
  const images = await tinyLandscapeImages();
  const fixture = await imageProviderFixture(() => {
    fixture.advance(120_001);
    return { body: { data: [{ b64_json: images.png.toString("base64") }] } };
  });
  t.after(fixture.close);
  await assert.rejects(registry("seedream", fixture.httpOptions).generate(snapshotImageGenerationConfig("seedream"), prompt));
  assert.equal(fixture.requests.length, 1);
});
