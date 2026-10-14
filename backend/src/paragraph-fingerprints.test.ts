import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { HttpError } from "./http.js";
import { fingerprintList, normalizeParagraph, paragraphFingerprint, SKETCH_SIZE, sketchOf } from "./paragraph-fingerprints.js";

const golden = JSON.parse(readFileSync(new URL("../test-fixtures/fingerprints.json", import.meta.url), "utf8")) as {
  cases: { text: string; normalized: string; fingerprint: string }[];
};

test("normalization and fingerprints match the golden shared with the Dart client", () => {
  for (const item of golden.cases) {
    assert.equal(normalizeParagraph(item.text), item.normalized);
    assert.equal(paragraphFingerprint(item.text).toString("hex"), item.fingerprint);
  }
});

test("fingerprints ignore punctuation, case and spacing, and skip short paragraphs", () => {
  const paragraphs = ["Chapter 1", "A long enough paragraph of real prose.", "A LONG enough—paragraph, of real prose!"];
  const values = fingerprintList(Buffer.concat(paragraphs.map(paragraphFingerprint)));
  assert.equal(values[0], "");
  assert.equal(values[1], values[2]);
  assert.match(values[1]!, /^[0-9a-f]{16}$/);
});

test("fingerprint lists must be whole, non-empty 8-byte values", () => {
  assert.throws(() => fingerprintList(Buffer.alloc(7)), HttpError);
  assert.throws(() => fingerprintList(Buffer.alloc(0)), HttpError);
});

test("the sketch is the smallest distinct identifiable fingerprints in numeric order", () => {
  const values = Array.from({ length: 100 }, (_, index) => (1000 - index).toString(16).padStart(16, "0"));
  const sketch = sketchOf(["", ...values, values[0]!, ""]);
  assert.equal(sketch.length, SKETCH_SIZE);
  assert.deepEqual(sketch, values.slice(-SKETCH_SIZE).reverse());
  assert.deepEqual(sketchOf(["", ""]), []);
});
