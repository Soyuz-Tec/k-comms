// @vitest-environment node
// Synthetic native HTTP with actual maintained SDK/Rust encryption.
// Intended sibling: clients/web/src/features/private-rooms/MatrixPrivateClient.epoch.crypto.test.ts
// Add this exact filename to standalone vitest.private-crypto.config.ts when integrating.
// Node environment loads maintained Rust18 node.mjs; no browser WASM fetch/store fixture.
// Real SDK43 createClient/initRustCrypto/encryptEvent are used. K API/native HTTP are
// synthetic fixtures. This is not owner HTTP/concurrency, live provider, peer SAS,
// or all-device/key-backup erasure qualification.
import { afterEach, describe, expect, it, vi } from "vitest";
import { createClient, MatrixEvent, Room, type MatrixClient } from "matrix-js-sdk";
import { OnlySignedDevicesIsolationMode, type CryptoApi } from "matrix-js-sdk/lib/crypto-api";
import { MatrixPrivateClient } from "./MatrixPrivateClient";
import type { MatrixClientSession, PrivateRoom, PrivateRoomApi } from "./types";

interface RealRustBackend extends CryptoApi {
  onCryptoEvent(room: Room, event: MatrixEvent): Promise<void>;
  encryptEvent(event: MatrixEvent, room: Room): Promise<void>;
}
interface RuntimeHarness {
  client: MatrixClient | null;
  credentials: MatrixClientSession | null;
  alive: boolean;
  selected: PrivateRoom | null;
  authorizedFetch: typeof fetch;
}
const actualClients: MatrixClient[] = [];
afterEach(() => { for (const client of actualClients.splice(0)) client.stopClient(); vi.unstubAllGlobals(); });

describe("real Rust-encrypted first envelope during K membership withdrawal", () => {
  it("refuses dispatch without relabelling already encrypted old-generation bytes", async () => {
    const principal = "@owner:example.test", control = "@control:example.test", nativeRoom = "!room:example.test";
    const deviceKeys: Record<string, Record<string, unknown>> = { [control]: {} }, masterKeys: Record<string, unknown> = {};
    const selfKeys: Record<string, unknown> = {}, signingKeys: Record<string, unknown> = {};
    let directNativeSends = 0;
    const nativeFetch: typeof fetch = async (input, init) => {
      const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
      const body = typeof init?.body === "string" ? JSON.parse(init.body) as Record<string, unknown> : {};
      if (url.pathname.endsWith("/keys/upload")) {
        const keys = body.device_keys as { user_id: string; device_id: string } | undefined;
        if (keys) (deviceKeys[keys.user_id] ||= {})[keys.device_id] = keys;
        return Response.json({ one_time_key_counts: { signed_curve25519: 50 } });
      }
      if (url.pathname.endsWith("/keys/device_signing/upload")) {
        for (const [key, destination] of [["master_key", masterKeys], ["self_signing_key", selfKeys], ["user_signing_key", signingKeys]] as const) {
          const value = body[key] as { user_id: string } | undefined; if (value) destination[value.user_id] = value;
        }
        return Response.json({});
      }
      if (url.pathname.endsWith("/keys/query")) return Response.json({ device_keys: deviceKeys, master_keys: masterKeys, self_signing_keys: selfKeys, user_signing_keys: signingKeys, failures: {} });
      if (url.pathname.endsWith("/keys/signatures/upload")) return Response.json({ failures: {} });
      if (url.pathname.endsWith("/keys/claim")) return Response.json({ one_time_keys: {}, failures: {} });
      if (url.pathname.includes("/account_data/") || url.pathname.endsWith("/room_keys/version")) return Response.json({ errcode: "M_NOT_FOUND", error: "No secret storage/backup in this isolated fixture" }, { status: 404 });
      if (url.pathname.includes("/send/m.room.encrypted/")) { directNativeSends++; return Response.json({ event_id: "$unexpected-native:example.test" }); }
      throw new Error(`Unexpected native request ${url.pathname}`);
    };
    vi.stubGlobal("fetch", nativeFetch);
    const credentials: MatrixClientSession = { homeserver_url: "https://matrix.example.test", matrix_user_id: principal, matrix_device_id: "OWNER", access_token: "synthetic-auth", expires_at: new Date(Date.now() + 180_000).toISOString(), k_session_id: "synthetic-current-K-session", control_matrix_user_id: control };
    // One verified current identity isolates the encryption/withdrawal seam.
    // This does not test the owner command's real minimum-two initial roster.
    let current: PrivateRoom = { id: "synthetic-K-room", tenant_id: "synthetic-tenant", title: "Synthetic crypto race", matrix_room_id: nativeRoom, control_matrix_user_id: control, state: "active", membership_epoch: 1, generation: 1, role: "owner", members: [{ tenant_id: "synthetic-tenant", user_id: "synthetic-owner", issuer: credentials.homeserver_url, matrix_user_id: principal, provisioning_state: "ready" }] };
    const bridgeAttempts: Array<{ epoch: number; generation: number }> = [];
    const unused = async (): Promise<never> => { throw new Error("Unexpected K API in encryption seam fixture"); };
    const api: PrivateRoomApi = {
      matrixClientSession: async () => credentials,
      matrixUploadPublicSigningKeys: async (keys) => { await nativeFetch(new URL("/_matrix/client/v3/keys/device_signing/upload", credentials.homeserver_url), { method: "POST", body: JSON.stringify(keys) }); },
      privateRoom: async () => current,
      privateRooms: unused, createPrivateRoom: unused, removePrivateMember: unused, replayPrivateEvents: unused,
      sendPrivateEvent: async (_id, _txn, _content, epoch, generation) => { bridgeAttempts.push({ epoch, generation }); throw new Error("Encrypted old-generation effect was admitted"); },
    };
    const runtime = new MatrixPrivateClient(api, current.tenant_id, "synthetic-owner", { messages: () => {}, blocked: () => {}, verification: () => {}, sas: () => {} });
    const harness = runtime as unknown as RuntimeHarness;
    harness.credentials = credentials; harness.alive = true; harness.selected = current;
    const client = createClient({ baseUrl: credentials.homeserver_url, userId: principal, deviceId: credentials.matrix_device_id, accessToken: credentials.access_token, fetchFn: harness.authorizedFetch });
    actualClients.push(client); harness.client = client;
    await client.initRustCrypto({ useIndexedDB: false });
    const crypto = client.getCrypto() as RealRustBackend;
    await crypto.bootstrapCrossSigning({ setupNewCrossSigning: false, authUploadDeviceSigningKeys: (request) => request(null) });
    crypto.setDeviceIsolationMode(new OnlySignedDevicesIsolationMode());
    expect(await crypto.isCrossSigningReady()).toBe(true);
    const room = new Room(nativeRoom, client, principal);
    const state = (type: string, key: string, content: Record<string, unknown>) => new MatrixEvent({ event_id: `$${type}-${key}:example.test`, room_id: nativeRoom, type, state_key: key, sender: control, content });
    const encryption = state("m.room.encryption", "", { algorithm: "m.megolm.v1.aes-sha2", rotation_period_msgs: 100, rotation_period_ms: 3_600_000 });
    room.currentState.setStateEvents([state("m.room.member", principal, { membership: "join" }), state("m.room.member", control, { membership: "join" }), encryption]);
    client.store.storeRoom(room); await crypto.onCryptoEvent(room, encryption);
    let entered!: () => void, release!: () => void;
    const encrypted = new Promise<void>((resolve) => { entered = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const realEncrypt = crypto.encryptEvent.bind(crypto);
    let ciphertext: Record<string, unknown> | undefined;
    // Call THROUGH the actual maintained cipher; the only instrumentation is a
    // promise gate after real SDK encryption and before its HTTP dispatch.
    crypto.encryptEvent = async (event, activeRoom) => { await realEncrypt(event, activeRoom); ciphertext = event.getWireContent(); entered(); await gate; };
    const sending = runtime.send("Synthetic content must stay out of every K wire body", "epoch-race-1");
    const refused = expect(sending).rejects.toThrow();
    try {
      await encrypted;
      expect(ciphertext?.algorithm).toBe("m.megolm.v1.aes-sha2");
      expect(typeof ciphertext?.ciphertext).toBe("string"); expect(ciphertext?.body).toBeUndefined();
      current = { ...current, membership_epoch: 2, generation: 2 };
      release(); await refused;
      expect(bridgeAttempts).toEqual([]); expect(directNativeSends).toBe(0);
    } finally { release(); crypto.encryptEvent = realEncrypt; await runtime.close(false); }
  }, 20_000);
});
