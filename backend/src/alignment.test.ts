import assert from "node:assert/strict";
import test from "node:test";
import { alignParagraphs, flattenRuns, mapOrdinal, unflattenRuns } from "./alignment.js";

const book = Array.from({ length: 200 }, (_, index) => `p${index}`);

test("an identical copy scores 100% as one run", () => {
  const { score, runs } = alignParagraphs(book, book);
  assert.equal(score, 1);
  assert.deepEqual(runs, [[0, 0, 200]]);
});

test("a watermark paragraph and extra front matter still link", () => {
  const user = ["copyright", "licensed to reader@example.com", ...book.slice(0, 100), "p100 edited", ...book.slice(101)];
  const { score, runs } = alignParagraphs(user, book);
  assert.ok(score >= 0.95, `score ${score}`);
  assert.deepEqual(runs, [[2, 0, 100], [103, 101, 99]]);
});

test("a different text scores zero", () => {
  assert.equal(alignParagraphs(book.map(value => `${value} translated`), book).score, 0);
});

test("an abridged copy links to the full work", () => {
  const abridged = book.filter((_, index) => index % 4 !== 0);
  assert.equal(alignParagraphs(abridged, book).score, 1);
  assert.ok(alignParagraphs(book, abridged).score < 0.9);
});

test("skipped paragraphs neither match nor count", () => {
  const user = book.flatMap(value => [value, ""]);
  const work = book.flatMap(value => ["", value]);
  const { score, runs } = alignParagraphs(user, work);
  assert.equal(score, 1);
  assert.equal(runs.length, 200);
});

test("repeated paragraphs between anchors extend the matched runs", () => {
  const user = ["a", "dup", "dup", "b"], work = ["a", "dup", "dup", "b"];
  assert.deepEqual(alignParagraphs(user, work).runs, [[0, 0, 4]]);
});

test("moved chapters keep only an order-preserving alignment", () => {
  const moved = [...book.slice(100), ...book.slice(0, 100)];
  const { runs } = alignParagraphs(moved, book);
  for (let index = 1; index < runs.length; index++) {
    assert.ok(runs[index]![0] >= runs[index - 1]![0] + runs[index - 1]![2]);
    assert.ok(runs[index]![1] >= runs[index - 1]![1] + runs[index - 1]![2]);
  }
});

test("mapOrdinal returns the nearest earlier matched work paragraph and is monotonic", () => {
  const runs: [number, number, number][] = [[2, 0, 3], [6, 10, 2]];
  assert.deepEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 50].map(ordinal => mapOrdinal(runs, ordinal)), [0, 0, 0, 1, 2, 2, 10, 11, 11, 11]);
});

test("runs round-trip through their flat stored form and malformed values read as absent", () => {
  const runs: [number, number, number][] = [[0, 0, 3], [5, 4, 1]];
  assert.deepEqual(unflattenRuns(flattenRuns(runs)), runs);
  assert.equal(unflattenRuns([1, 2]), null);
  assert.equal(unflattenRuns("x"), null);
});
