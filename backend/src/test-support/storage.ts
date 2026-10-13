import type { Storage } from "@google-cloud/storage";

/**
 * In-memory Cloud Storage double covering the calls the backend makes: object
 * save/delete, V4 read signing and prefix deletion. All buckets share one
 * object map because each test uses a single private bucket.
 */
export class MemoryStorage {
  readonly objects = new Map<string, Buffer>();
  readonly contentTypes = new Map<string, string>();
  /** Every `deleteFiles` prefix, in call order. */
  readonly deletedPrefixes: string[] = [];
  /** Runs before a save is recorded; a test can block or fail publication here. */
  beforeSave: (path: string) => Promise<void> = async () => {};
  /** Runs before a prefix deletion; tests assert fences that must precede purges. */
  beforeDeleteFiles: (prefix: string) => void | Promise<void> = () => {};

  /**
   * `events`, when given (usually `MemoryFirestore.events`), receives
   * `save:`, `delete-object:` and `sign:` entries so tests can order storage
   * effects against Firestore writes.
   */
  constructor(private readonly events?: string[]) {}

  /** Signed URLs are recognizable fakes that embed the object path. */
  static signedUrl(path: string): string {
    return `https://private.invalid/${path}`;
  }

  get storage(): Storage {
    const file = (path: string) => ({
      save: async (bytes: Buffer, options?: { contentType?: string }) => {
        await this.beforeSave(path);
        this.objects.set(path, bytes);
        if (options?.contentType) this.contentTypes.set(path, options.contentType);
        this.events?.push(`save:${path}`);
      },
      delete: async () => {
        this.objects.delete(path);
        this.contentTypes.delete(path);
        this.events?.push(`delete-object:${path}`);
      },
      getSignedUrl: async () => {
        this.events?.push(`sign:${path}`);
        return [MemoryStorage.signedUrl(path)];
      },
    });
    const deleteFiles = async ({ prefix }: { prefix: string }) => {
      this.deletedPrefixes.push(prefix);
      await this.beforeDeleteFiles(prefix);
      for (const path of [...this.objects.keys()]) {
        if (path.startsWith(prefix)) { this.objects.delete(path); this.contentTypes.delete(path); }
      }
    };
    return { bucket: () => ({ file, deleteFiles }) } as unknown as Storage;
  }
}
