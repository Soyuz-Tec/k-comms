// @vitest-environment node
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const sdk = vi.hoisted(() => ({
  createClient: vi.fn(),
  setCryptoStoreFactory: vi.fn(),
  IndexedDBCryptoStore: vi.fn(class {
    constructor(readonly database: IDBFactory, readonly name: string) {}
  }),
  ClientEvent: { Sync: "sync" },
  MatrixEventEvent: { Decrypted: "Event.decrypted" },
  RoomEvent: { Timeline: "Room.timeline" }
}));
vi.mock("matrix-js-sdk/lib/matrix", () => ({ createClient: sdk.createClient, setCryptoStoreFactory: sdk.setCryptoStoreFactory }));
vi.mock("matrix-js-sdk/lib/crypto/store/indexeddb-crypto-store", () => ({ IndexedDBCryptoStore: sdk.IndexedDBCryptoStore }));
vi.mock("matrix-js-sdk/lib/client", () => ({ ClientEvent: sdk.ClientEvent }));
vi.mock("matrix-js-sdk/lib/models/event", () => ({ MatrixEventEvent: sdk.MatrixEventEvent }));
vi.mock("matrix-js-sdk/lib/models/room", () => ({ RoomEvent: sdk.RoomEvent }));

const properties = ["__js_sdk_entrypoint", "indexedDB", "matrixcs"] as const;
const originals = new Map(properties.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
function define(key: typeof properties[number], descriptor: PropertyDescriptor) {
  Object.defineProperty(globalThis, key, { configurable: true, ...descriptor });
}
beforeEach(() => {
  vi.resetModules();
  vi.clearAllMocks();
  define("__js_sdk_entrypoint", { value: undefined, writable: true });
  define("indexedDB", { value: undefined, writable: true });
  define("matrixcs", { value: undefined, writable: true });
});
afterEach(() => {
  for (const key of properties) {
    const descriptor = originals.get(key);
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else Reflect.deleteProperty(globalThis, key);
  }
});

describe("maintained Matrix browser bootstrap", () => {
  it("retains named SDK identities and memory fallback without exposing the entire SDK", async () => {
    const module = await import("./matrixSdk");
    expect(module.createClient).toBe(sdk.createClient);
    expect(module.ClientEvent).toBe(sdk.ClientEvent);
    expect(module.MatrixEventEvent).toBe(sdk.MatrixEventEvent);
    expect(module.RoomEvent).toBe(sdk.RoomEvent);
    expect(Reflect.get(globalThis, "__js_sdk_entrypoint")).toBe(true);
    expect(Reflect.get(globalThis, "matrixcs")).toBeUndefined();
    expect(sdk.setCryptoStoreFactory).not.toHaveBeenCalled();
  });

  it("installs the same lazy official IndexedDB crypto-store factory and database name", async () => {
    const database = {} as IDBFactory;
    define("indexedDB", { value: database });
    await import("./matrixSdk");
    expect(sdk.setCryptoStoreFactory).toHaveBeenCalledExactlyOnceWith(expect.any(Function));
    expect(sdk.IndexedDBCryptoStore).not.toHaveBeenCalled();
    const factory = sdk.setCryptoStoreFactory.mock.calls[0]![0] as () => unknown;
    factory();
    expect(sdk.IndexedDBCryptoStore).toHaveBeenCalledExactlyOnceWith(database, "matrix-js-sdk:crypto");
  });

  it("keeps the SDK memory fallback when accessing disabled browser storage throws", async () => {
    define("indexedDB", { get() { throw new Error("Browser storage disabled"); } });
    await expect(import("./matrixSdk")).resolves.toHaveProperty("createClient", sdk.createClient);
    expect(sdk.setCryptoStoreFactory).not.toHaveBeenCalled();
    expect(Reflect.get(globalThis, "__js_sdk_entrypoint")).toBe(true);
  });

  it("rejects a second SDK entrypoint before reading or changing its storage factory", async () => {
    define("__js_sdk_entrypoint", { value: true });
    const readDatabase = vi.fn(() => ({} as IDBFactory));
    define("indexedDB", { get: readDatabase });
    await expect(import("./matrixSdk")).rejects.toThrow("Multiple matrix-js-sdk entrypoints detected!");
    expect(readDatabase).not.toHaveBeenCalled();
    expect(sdk.setCryptoStoreFactory).not.toHaveBeenCalled();
  });
});
