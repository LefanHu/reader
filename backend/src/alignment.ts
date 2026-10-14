/**
 * Order-preserving paragraph alignment between a user's copy and a catalog work.
 *
 * Inputs are per-paragraph fingerprints ("" = skipped). Paragraphs whose
 * fingerprint is unique on both sides anchor the alignment (patience diff): the
 * longest increasing chain of anchors is kept, then each anchor extends over
 * neighbouring equal paragraphs so repeated text between anchors still matches.
 * The result is monotonic, which later lets analysis map a user position to the
 * work without ever reading past it.
 */

/** Matched paragraph runs: `[userOrdinal, workOrdinal, length]` per run. */
export type AlignmentRun = [number, number, number];

/** Minimum share of the user's identifiable paragraphs that must match the work. */
export const LINK_THRESHOLD = 0.9;

/** Bounds the stored link; fragmented alignments are refused instead. */
export const MAX_ALIGNMENT_RUNS = 10_000;

export type Alignment = { score: number; runs: AlignmentRun[] };

function uniquePositions(values: string[]): Map<string, number> {
  const positions = new Map<string, number>();
  const repeated = new Set<string>();
  values.forEach((value, index) => {
    if (!value || repeated.has(value)) return;
    if (positions.has(value)) { positions.delete(value); repeated.add(value); } else positions.set(value, index);
  });
  return positions;
}

/** Indices of the longest strictly increasing subsequence of `values` (patience sorting). */
function longestIncreasing(values: number[]): number[] {
  const tails: number[] = [], previous = new Array<number>(values.length).fill(-1);
  values.forEach((value, index) => {
    let low = 0, high = tails.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (values[tails[middle]!]! < value) low = middle + 1; else high = middle;
    }
    if (low > 0) previous[index] = tails[low - 1]!;
    tails[low] = index;
  });
  const chain: number[] = [];
  for (let index = tails.at(-1) ?? -1; index >= 0; index = previous[index]!) chain.push(index);
  return chain.reverse();
}

/** Aligns `user` against `work`; the score is matched ÷ the user's non-skipped paragraphs. */
export function alignParagraphs(user: string[], work: string[]): Alignment {
  const workUnique = uniquePositions(work);
  const anchors: [number, number][] = [];
  for (const [value, userIndex] of uniquePositions(user)) {
    const workIndex = workUnique.get(value);
    if (workIndex !== undefined) anchors.push([userIndex, workIndex]);
  }
  anchors.sort((a, b) => a[0] - b[0]);
  const chain = longestIncreasing(anchors.map(anchor => anchor[1])).map(index => anchors[index]!);

  const matched = new Map<number, number>();
  const equal = (u: number, w: number) => u >= 0 && w >= 0 && u < user.length && w < work.length &&
    user[u] !== "" && user[u] === work[w] && !matched.has(u);
  let floorUser = -1, floorWork = -1;
  chain.forEach(([userIndex, workIndex], position) => {
    const next = chain[position + 1] ?? [user.length, work.length];
    matched.set(userIndex, workIndex);
    // Extend backwards to the previous match and forwards to the next anchor.
    for (let u = userIndex - 1, w = workIndex - 1; u > floorUser && w > floorWork && equal(u, w); u--, w--) matched.set(u, w);
    let u = userIndex + 1, w = workIndex + 1;
    for (; u < next[0] && w < next[1] && equal(u, w); u++, w++) matched.set(u, w);
    floorUser = u - 1; floorWork = w - 1;
  });

  const identifiable = user.filter(Boolean).length;
  const runs: AlignmentRun[] = [];
  for (const [u, w] of [...matched].sort((a, b) => a[0] - b[0])) {
    const last = runs.at(-1);
    if (last && last[0] + last[2] === u && last[1] + last[2] === w) last[2]++;
    else runs.push([u, w, 1]);
  }
  return { score: identifiable === 0 ? 0 : matched.size / identifiable, runs };
}

/**
 * Work ordinal for a user paragraph: its own match, else the nearest earlier
 * matched work paragraph, else 0. Never later than the true position.
 */
export function mapOrdinal(runs: AlignmentRun[], userOrdinal: number): number {
  let low = 0, high = runs.length - 1, found = -1;
  while (low <= high) {
    const middle = (low + high) >> 1;
    if (runs[middle]![0] <= userOrdinal) { found = middle; low = middle + 1; } else high = middle - 1;
  }
  if (found < 0) return 0;
  const [userStart, workStart, length] = runs[found]!;
  return workStart + Math.min(userOrdinal - userStart, length - 1);
}

/** Firestore stores no nested arrays, so runs persist as a flat integer list. */
export function flattenRuns(runs: AlignmentRun[]): number[] {
  return runs.flat();
}

/** Inverse of {@link flattenRuns}; malformed stored links read as absent. */
export function unflattenRuns(value: unknown): AlignmentRun[] | null {
  if (!Array.isArray(value) || value.length % 3 !== 0 || !value.every(Number.isSafeInteger)) return null;
  const runs: AlignmentRun[] = [];
  for (let index = 0; index < value.length; index += 3) runs.push([value[index], value[index + 1], value[index + 2]]);
  return runs;
}
