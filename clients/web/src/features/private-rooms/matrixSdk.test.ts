// @vitest-environment node
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ICreateClientOpts } from "matrix-js-sdk/lib/client";

const sdk = vi.hoisted(() => ({
  MatrixClient: vi.fn(class { constructor(readonly options: Record<string, unknown>) {} }),
  MemoryStore: vi.fn(class { constructor(readonly options: Record<string, unknown>) {} }),
  MatrixScheduler: vi.fn(class {}),
  MemoryCryptoStore: vi.fn(class {}),
  IndexedDBCryptoStore: vi.fn(class {
    constructor(readonly database: IDBFactory, readonly name: string) {}
  }),
  ClientEvent: { Sync: "sync" },
  MatrixEventEvent: { Decrypted: "Event.decrypted" },
  RoomEvent: { Timeline: "Room.timeline" }
}));
vi.mock("matrix-js-sdk/lib/crypto/store/indexeddb-crypto-store", () => ({ IndexedDBCryptoStore: sdk.IndexedDBCryptoStore }));
vi.mock("matrix-js-sdk/lib/crypto/store/memory-crypto-store", () => ({ MemoryCryptoStore: sdk.MemoryCryptoStore }));
vi.mock("matrix-js-sdk/lib/store/memory", () => ({ MemoryStore: sdk.MemoryStore }));
vi.mock("matrix-js-sdk/lib/scheduler", () => ({ MatrixScheduler: sdk.MatrixScheduler }));
vi.mock("matrix-js-sdk/lib/client", () => ({ MatrixClient: sdk.MatrixClient, ClientEvent: sdk.ClientEvent }));
vi.mock("matrix-js-sdk/lib/models/event", () => ({ MatrixEventEvent: sdk.MatrixEventEvent }));
vi.mock("matrix-js-sdk/lib/models/room", () => ({ RoomEvent: sdk.RoomEvent }));

const properties = ["__js_sdk_entrypoint", "indexedDB", "localStorage", "matrixcs"] as const;
const originals = new Map(properties.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
function define(key: typeof properties[number], descriptor: PropertyDescriptor) {
  Object.defineProperty(globalThis, key, { configurable: true, ...descriptor });
}
beforeEach(() => {
  vi.resetModules();
  vi.clearAllMocks();
  for (const property of properties) define(property, { value: undefined, writable: true });
});
afterEach(() => {
  for (const key of properties) {
    const descriptor = originals.get(key);
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else Reflect.deleteProperty(globalThis, key);
  }
});

function input(): ICreateClientOpts {
  return { baseUrl: "https://matrix.example.test", userId: "@ada:example.test", deviceId: "SYNTHETIC", accessToken: "synthetic-token" };
}

describe("maintained Matrix browser bootstrap", () => {
  it("uses the official client, memory timeline, scheduler and crypto fallback with SDK option mutation", async () => {
    const localStorage = { synthetic: "browser storage" };
    define("localStorage", { value: localStorage });
    const module = await import("./matrixSdk");
    const options = input();
    const result = module.createClient(options);
    expect(result).toBeInstanceOf(sdk.MatrixClient);
    expect(sdk.MatrixClient).toHaveBeenCalledExactlyOnceWith(options);
    expect(options.store).toBeInstanceOf(sdk.MemoryStore);
    expect(options.scheduler).toBeInstanceOf(sdk.MatrixScheduler);
    expect(options.cryptoStore).toBeInstanceOf(sdk.MemoryCryptoStore);
    expect(sdk.MemoryStore).toHaveBeenCalledExactlyOnceWith({ localStorage });
    expect(options).toMatchObject(input());
    expect(module.ClientEvent).toBe(sdk.ClientEvent);
    expect(module.MatrixEventEvent).toBe(sdk.MatrixEventEvent);
    expect(module.RoomEvent).toBe(sdk.RoomEvent);
    expect(Reflect.get(globalThis, "__js_sdk_entrypoint")).toBe(true);
    expect(Reflect.get(globalThis, "matrixcs")).toBeUndefined();
    expect(sdk.IndexedDBCryptoStore).not.toHaveBeenCalled();
  });

  it("creates the official IndexedDB crypto store lazily with the same database name", async () => {
    const database = {} as IDBFactory;
    define("indexedDB", { value: database });
    const { createClient } = await import("./matrixSdk");
    expect(sdk.IndexedDBCryptoStore).not.toHaveBeenCalled();
    expect(sdk.MemoryStore).not.toHaveBeenCalled();
    const first = input(), second = input();
    createClient(first); createClient(second);
    expect(sdk.IndexedDBCryptoStore).toHaveBeenCalledTimes(2);
    expect(sdk.IndexedDBCryptoStore).toHaveBeenNthCalledWith(1, database, "matrix-js-sdk:crypto");
    expect(sdk.IndexedDBCryptoStore).toHaveBeenNthCalledWith(2, database, "matrix-js-sdk:crypto");
    expect(first.cryptoStore).not.toBe(second.cryptoStore);
    expect(first.store).not.toBe(second.store);
    expect(sdk.MemoryCryptoStore).not.toHaveBeenCalled();
  });

  it("preserves caller stores, scheduler, fetch and crypto callbacks without touching local storage", async () => {
    define("localStorage", { get() { throw new Error("Caller provided its own timeline store"); } });
    const { createClient } = await import("./matrixSdk");
    const store = new sdk.MemoryStore({ custom: true });
    const scheduler = new sdk.MatrixScheduler();
    const cryptoStore = new sdk.MemoryCryptoStore();
    const fetchFn = vi.fn();
    const cryptoCallbacks = {};
    const options = { ...input(), store, scheduler, cryptoStore, fetchFn, cryptoCallbacks } as unknown as ICreateClientOpts;
    vi.clearAllMocks();
    createClient(options);
    expect(sdk.MatrixClient).toHaveBeenCalledExactlyOnceWith(options);
    expect(options.store).toBe(store);
    expect(options.scheduler).toBe(scheduler);
    expect(options.cryptoStore).toBe(cryptoStore);
    expect(options.fetchFn).toBe(fetchFn);
    expect(options.cryptoCallbacks).toBe(cryptoCallbacks);
    expect(sdk.MemoryStore).not.toHaveBeenCalled();
    expect(sdk.MatrixScheduler).not.toHaveBeenCalled();
    expect(sdk.MemoryCryptoStore).not.toHaveBeenCalled();
    expect(sdk.IndexedDBCryptoStore).not.toHaveBeenCalled();
  });

  it("keeps the SDK memory fallback when accessing disabled browser storage throws", async () => {
    define("indexedDB", { get() { throw new Error("Browser storage disabled"); } });
    const { createClient } = await import("./matrixSdk");
    const options = input();
    createClient(options);
    expect(options.cryptoStore).toBeInstanceOf(sdk.MemoryCryptoStore);
    expect(sdk.IndexedDBCryptoStore).not.toHaveBeenCalled();
    expect(Reflect.get(globalThis, "__js_sdk_entrypoint")).toBe(true);
  });

  it("does not silently suppress the SDK local-storage failure when its default timeline store is requested", async () => {
    define("localStorage", { get() { throw new Error("Browser storage disabled"); } });
    const { createClient } = await import("./matrixSdk");
    expect(() => createClient(input())).toThrow("Browser storage disabled");
    expect(sdk.MatrixClient).not.toHaveBeenCalled();
  });

  it("rejects a second SDK entrypoint before reading browser storage or constructing a client", async () => {
    define("__js_sdk_entrypoint", { value: true });
    const readDatabase = vi.fn(() => ({} as IDBFactory));
    define("indexedDB", { get: readDatabase });
    await expect(import("./matrixSdk")).rejects.toThrow("Multiple matrix-js-sdk entrypoints detected!");
    expect(readDatabase).not.toHaveBeenCalled();
    expect(sdk.IndexedDBCryptoStore).not.toHaveBeenCalled();
    expect(sdk.MatrixClient).not.toHaveBeenCalled();
  });
});
