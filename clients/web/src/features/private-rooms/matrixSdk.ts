import { createClient, setCryptoStoreFactory } from "matrix-js-sdk/lib/matrix";
import { IndexedDBCryptoStore } from "matrix-js-sdk/lib/crypto/store/indexeddb-crypto-store";

export { createClient };
export { ClientEvent, type MatrixClient } from "matrix-js-sdk/lib/client";
export { MatrixEventEvent } from "matrix-js-sdk/lib/models/event";
export { RoomEvent } from "matrix-js-sdk/lib/models/room";

// Preserve SDK43's browser bootstrap using its maintained modules. Its unused
// global matrixcs namespace retains every barrel export, including widget APIs.
const sdkGlobal = globalThis as typeof globalThis & { __js_sdk_entrypoint?: boolean };
if (sdkGlobal.__js_sdk_entrypoint) {
  throw new Error("Multiple matrix-js-sdk entrypoints detected!");
}
sdkGlobal.__js_sdk_entrypoint = true;

// Merely accessing indexedDB can throw when Firefox storage is disabled.
let database: IDBFactory | undefined;
try {
  database = globalThis.indexedDB;
} catch {
  // Keep the SDK's default memory factory when browser storage is unavailable.
}
if (database) {
  const indexedDB = database;
  setCryptoStoreFactory(() => new IndexedDBCryptoStore(indexedDB, "matrix-js-sdk:crypto"));
}
