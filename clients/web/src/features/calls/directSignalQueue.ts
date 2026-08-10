interface QueuedSignal<T> {
  value: T;
  queuedAt: number;
  bytes: number;
}

export class DirectSignalQueue<T> {
  private readonly entries: QueuedSignal<T>[] = [];
  private totalBytes = 0;

  constructor(
    private readonly maxEntries = 32,
    private readonly maxBytes = 65_536,
    private readonly maxAgeMs = 15_000
  ) {}

  enqueue(value: T, now = Date.now()): boolean {
    this.pruneExpired(now);
    const bytes = new TextEncoder().encode(JSON.stringify(value)).byteLength;
    if (
      bytes <= 0 ||
      bytes > this.maxBytes ||
      this.entries.length >= this.maxEntries ||
      this.totalBytes + bytes > this.maxBytes
    ) {
      return false;
    }

    this.entries.push({ value, queuedAt: now, bytes });
    this.totalBytes += bytes;
    return true;
  }

  drain(now = Date.now()): T[] {
    this.pruneExpired(now);
    const values = this.entries.map(({ value }) => value);
    this.clear();
    return values;
  }

  clear(): void {
    this.entries.splice(0);
    this.totalBytes = 0;
  }

  get size(): number {
    return this.entries.length;
  }

  get bytes(): number {
    return this.totalBytes;
  }

  private pruneExpired(now: number): void {
    while (this.entries[0] && now - this.entries[0].queuedAt > this.maxAgeMs) {
      const expired = this.entries.shift();
      if (expired) this.totalBytes -= expired.bytes;
    }
  }
}
