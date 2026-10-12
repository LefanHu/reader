import { lookup } from "node:dns/promises";
import type { LookupAddress } from "node:dns";
import { BlockList, isIP, type LookupFunction } from "node:net";
import { Agent } from "undici";
import { MAX_IMAGE_BYTES, type ReferenceImage } from "./image-generation.js";

export const MAX_PROVIDER_JSON_BYTES = 32 * 1024 * 1024;
/** Injection is server/test-owned; clients cannot choose transports or URLs. */
export interface ImageHttpOptions {
  fetch?: typeof fetch;
  lookup?: typeof lookup;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  timeoutMs?: number;
}

const nonpublic = new BlockList();
for (const [address, prefix] of [
  ["0.0.0.0", 8], ["10.0.0.0", 8], ["100.64.0.0", 10], ["127.0.0.0", 8],
  ["169.254.0.0", 16], ["172.16.0.0", 12], ["192.0.0.0", 24], ["192.0.2.0", 24],
  ["192.88.99.0", 24], ["192.168.0.0", 16], ["198.18.0.0", 15], ["198.51.100.0", 24],
  ["203.0.113.0", 24], ["224.0.0.0", 4], ["240.0.0.0", 4],
] as const) nonpublic.addSubnet(address, prefix, "ipv4");
const globalV6 = new BlockList();
globalV6.addSubnet("2000::", 3, "ipv6");
for (const [address, prefix] of [
  ["2001::", 23], ["2001:db8::", 32], ["2002::", 16], ["3fff::", 20],
] as const) nonpublic.addSubnet(address, prefix, "ipv6");

/** Fail closed on reserved, local, mapped and mixed-public/private DNS answers. */
export function isPublicImageAddress(address: string): boolean {
  const family = isIP(address);
  if (family === 4) return !nonpublic.check(address, "ipv4");
  return family === 6 && globalV6.check(address, "ipv6") && !nonpublic.check(address, "ipv6");
}

/** Connector-only lookup: checked destinations are pinned; DNS is never repeated. */
export function pinnedImageLookup(hostname: string, addresses: LookupAddress[]): LookupFunction {
  if (addresses.length === 0 || addresses.some(result => !isPublicImageAddress(result.address))) {
    throw new Error("Provider DNS is not public");
  }
  return (requestedHost, options, callback) => {
    if (requestedHost !== hostname) { callback(new Error("Provider hostname changed"), "", 4); return; }
    if (options.all) callback(null, addresses);
    else callback(null, addresses[0]!.address, addresses[0]!.family);
  };
}

export type ProviderUrlKind = "flux-poll" | "flux" | "qwen";
/** Validate exact provider-host label boundaries before any DNS/network work. */
export function requireProviderUrl(value: unknown, kind: ProviderUrlKind): URL {
  try {
    if (typeof value !== "string" || value.length > 8192 || value !== value.trim() || /[\u0000-\u0020]/.test(value)) throw new Error();
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password || url.port ||
        value.includes("#") || /^https:\/\/[^/?#]*@/i.test(value) ||
        isIP(url.hostname) || url.hostname.endsWith(".")) throw new Error();
    const host = url.hostname;
    const label = "[a-z0-9](?:[a-z0-9-]*[a-z0-9])?";
    const valid = kind === "flux-poll"
      ? host === "api.bfl.ai" || new RegExp(`^api\\.${label}\\.bfl\\.ai$`).test(host)
      : kind === "flux"
        ? new RegExp(`^delivery\\.${label}\\.bfl\\.ai$`).test(host)
        : new RegExp(`^dashscope-result-${label}\\.oss-${label}\\.aliyuncs\\.com$`).test(host);
    if (!valid || host.length > 253 || host.split(".").some(part => part.length > 63)) throw new Error();
    return url;
  } catch {
    throw new Error("Provider URL is not permitted");
  }
}

/** Strict canonical base64: bound size and check syntax before allocating. */
export function decodeImageBase64(value: unknown): Buffer {
  if (typeof value !== "string" || value.length === 0 || value.length % 4 !== 0 ||
      value.length > 4 * Math.ceil(MAX_IMAGE_BYTES / 3) ||
      !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) {
    throw new Error("Provider image encoding is invalid");
  }
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  const length = value.length / 4 * 3 - padding;
  if (length > MAX_IMAGE_BYTES) throw new Error("Provider image exceeds byte limit");
  // Reject nonzero unused bits without allocating/re-encoding a second string.
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  if ((padding === 2 && (alphabet.indexOf(value[value.length - 3]!) & 15) !== 0) ||
      (padding === 1 && (alphabet.indexOf(value[value.length - 2]!) & 3) !== 0)) {
    throw new Error("Provider image encoding is invalid");
  }
  return Buffer.from(value, "base64");
}

/** MIME has already been established by the central reference decoder. */
export function referenceDataUri(reference: ReferenceImage): string {
  return `data:${reference.mimeType};base64,${reference.bytes.toString("base64")}`;
}

/** One 120-second operation, no POST retries, bounded incremental response reads. */
export class ImageOperation {
  private readonly now: () => number;
  private readonly deadline: number;
  private readonly controller = new AbortController();
  private readonly timer: NodeJS.Timeout;
  private readonly dispatchers: Agent[] = [];
  constructor(private readonly options: ImageHttpOptions = {}) {
    this.now = options.now ?? Date.now;
    const duration = Math.min(120_000, Math.max(1, options.timeoutMs ?? 120_000));
    this.deadline = this.now() + duration;
    this.timer = setTimeout(() => this.controller.abort(), duration);
    this.timer.unref();
  }

  remainingMs(): number {
    const remaining = this.deadline - this.now();
    if (remaining <= 0 || this.controller.signal.aborted) throw new Error("Image operation timed out");
    return remaining;
  }

  /** Bound ADC token acquisition and other non-fetch work to this operation. */
  async bounded<T>(work: Promise<T>, signal: AbortSignal = this.controller.signal): Promise<T> {
    this.remainingMs();
    if (signal.aborted) throw new Error("Image operation timed out");
    return new Promise<T>((resolve, reject) => {
      const onAbort = () => reject(new Error("Image operation timed out"));
      signal.addEventListener("abort", onAbort, { once: true });
      work.then(value => {
        signal.removeEventListener("abort", onAbort);
        try { this.remainingMs(); resolve(value); } catch { reject(new Error("Image operation timed out")); }
      }, () => {
        signal.removeEventListener("abort", onAbort);
        reject(new Error("Image provider operation failed"));
      });
    });
  }

  async sleep(ms: number): Promise<void> {
    const duration = Math.min(ms, this.remainingMs());
    if (this.options.sleep) await this.bounded(this.options.sleep(duration));
    else await new Promise<void>((resolve, reject) => {
      const signal = this.controller.signal;
      const onAbort = () => { clearTimeout(timer); reject(new Error("Image operation timed out")); };
      const timer = setTimeout(() => { signal.removeEventListener("abort", onAbort); resolve(); }, duration);
      signal.addEventListener("abort", onAbort, { once: true });
    });
    this.remainingMs();
  }

  close(): void {
    clearTimeout(this.timer);
    this.controller.abort();
    for (const dispatcher of this.dispatchers) void dispatcher.destroy().catch(() => {});
  }

  private async request(url: string, init: RequestInit, cap: number, maxMs?: number,
    pinnedKind?: ProviderUrlKind): Promise<Buffer> {
    const timeout = AbortSignal.timeout(Math.max(1, Math.min(this.remainingMs(), maxMs ?? this.remainingMs())));
    const signal = AbortSignal.any([timeout, this.controller.signal]);
    let dispatcher: Agent;
    try {
      if (pinnedKind) {
        const validated = requireProviderUrl(url, pinnedKind);
        // Native DNS has no cancellation API; abort the wait, and never connect
        // if DNS finishes after the call/operation deadline.
        const addresses = await new Promise<LookupAddress[]>((resolve, reject) => {
          const onAbort = () => reject(new Error("Image operation timed out"));
          signal.addEventListener("abort", onAbort, { once: true });
          (this.options.lookup ?? lookup)(validated.hostname, { all: true, verbatim: true })
            .then(result => { signal.removeEventListener("abort", onAbort); resolve(result); },
              () => { signal.removeEventListener("abort", onAbort); reject(new Error("Provider DNS failed")); });
        });
        const pinnedLookup = pinnedImageLookup(validated.hostname, addresses);
        this.remainingMs();
        if (signal.aborted) throw new Error("Image operation timed out");
        dispatcher = new Agent({ connect: {
          timeout: 10_000,
          lookup: pinnedLookup,
        } });
      } else dispatcher = new Agent({ connect: { timeout: 10_000 } });
      this.dispatchers.push(dispatcher);
      const response = await this.bounded((this.options.fetch ?? fetch)(url, {
        ...init, redirect: "error", signal, dispatcher,
      } as RequestInit & { dispatcher: Agent }), signal);
      if (!response.ok) {
        await response.body?.cancel();
        throw new Error("Provider request rejected");
      }
      const declaredLength = response.headers.get("content-length");
      if (declaredLength !== null && (!/^\d+$/.test(declaredLength) || Number(declaredLength) > cap)) {
        await response.body?.cancel();
        throw new Error("Provider response exceeds byte limit");
      }
      if (!response.body) throw new Error("Provider response body is missing");
      const reader = response.body.getReader();
      const chunks: Buffer[] = [];
      let size = 0;
      try {
        while (true) {
          this.remainingMs();
          if (signal.aborted) throw new Error("Image operation timed out");
          const { done, value } = await this.bounded(reader.read(), signal);
          if (done) break;
          size += value.byteLength;
          if (size > cap) throw new Error("Provider response exceeds byte limit");
          chunks.push(Buffer.from(value.buffer, value.byteOffset, value.byteLength));
        }
      } catch {
        await reader.cancel().catch(() => {});
        throw new Error("Provider response could not be read safely");
      } finally { reader.releaseLock(); }
      this.remainingMs();
      return Buffer.concat(chunks, size);
    } catch {
      // Fetch/URL/DNS errors may contain signed URLs or private request details.
      throw new Error("Image provider transport failed");
    }
  }

  private parseJson(bytes: Buffer): Record<string, unknown> {
    try {
      const value: unknown = JSON.parse(bytes.toString("utf8"));
      if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
      return value as Record<string, unknown>;
    } catch { throw new Error("Provider returned invalid JSON"); }
  }

  /** Synchronous synthesis gets the remaining operation deadline, not 30s. */
  async postJson(url: string, headers: Record<string, string>, body: Record<string, unknown>): Promise<Record<string, unknown>> {
    const bytes = await this.request(url, {
      method: "POST", headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify(body),
    }, MAX_PROVIDER_JSON_BYTES);
    return this.parseJson(bytes);
  }

  /** BFL returned polling URL only; never reconstruct a task endpoint. */
  async pollJson(url: string, headers: Record<string, string> = {}): Promise<Record<string, unknown>> {
    const bytes = await this.request(url, { method: "GET", headers }, MAX_PROVIDER_JSON_BYTES, 30_000, "flux-poll");
    return this.parseJson(bytes);
  }

  /** Private returned asset URL; provider credentials are never forwarded. */
  downloadImage(url: string, family: "qwen" | "flux"): Promise<Buffer> {
    return this.request(url, { method: "GET" }, MAX_IMAGE_BYTES, 30_000, family);
  }
}

/** A fresh deadline belongs to each attempt; there is no automatic retry. */
export function createImageOperation(options: ImageHttpOptions = {}): ImageOperation {
  return new ImageOperation(options);
}
