import { MatrixClient, type ICreateClientOpts, type IMatrixClientCreateOpts } from "matrix-js-sdk/lib/client";
import { MemoryStore } from "matrix-js-sdk/lib/store/memory";
import { MatrixScheduler } from "matrix-js-sdk/lib/scheduler";
import { MemoryCryptoStore } from "matrix-js-sdk/lib/crypto/store/memory-crypto-store";
import { IndexedDBCryptoStore } from "matrix-js-sdk/lib/crypto/store/indexeddb-crypto-store";

export { ClientEvent, type MatrixClient } from "matrix-js-sdk/lib/client";
export { MatrixEventEvent } from "matrix-js-sdk/lib/models/event";
export { RoomEvent } from "matrix-js-sdk/lib/models/room";

// Preserve SDK43's browser bootstrap while importing its maintained modules
// directly. The lib/matrix barrel also evaluates unused widget entry points.
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

/** SDK43 lib/matrix.amendClientOpts defaults, using the official constructors.
 * Stores remain lazy; explicit caller options and the SDK's option mutation
 * behavior are preserved. Crypto implementation and migration stay in the SDK.
 */
export function createClient(options: ICreateClientOpts): MatrixClient {
  options.store = options.store ?? new MemoryStore({ localStorage: globalThis.localStorage });
  options.scheduler = options.scheduler ?? new MatrixScheduler();
  options.cryptoStore = options.cryptoStore ?? (database
    ? new IndexedDBCryptoStore(database, "matrix-js-sdk:crypto")
    : new MemoryCryptoStore());
  return new MatrixClient(options as IMatrixClientCreateOpts);
}
