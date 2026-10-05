// @vitest-environment node
import { afterEach, describe, expect, it } from "vitest";
import { createClient, type MatrixClient } from "./matrixSdk";
import { UserId, type OlmMachine } from "@matrix-org/matrix-sdk-crypto-wasm";
import type { CryptoApi } from "matrix-js-sdk/lib/crypto-api";
import { assertControlKeyAbsence, assertVerifiedParticipants } from "./MatrixPrivateClient";
import type { MatrixIdentity } from "./types";

const owner = "@owner:example.test", peer = "@peer:example.test", control = "@control:example.test";
const clients: MatrixClient[] = [];
interface RealRustCrypto extends CryptoApi { getOlmMachineOrThrow(): OlmMachine }
class NativeMatrixFixture {
  devices: Record<string, Record<string, unknown>> = {};
  master: Record<string, unknown> = {};
  self: Record<string, unknown> = {};
  signing: Record<string, unknown> = {};
  query() { return { device_keys: this.devices, master_keys: this.master, self_signing_keys: this.self, user_signing_keys: this.signing, failures: {} }; }
  uploadSignatures(body: Record<string, unknown>): void {
    // Standard public signature publication: preserve native-generated keys and
    // merge signatures, then return them through the actual /keys/query shape.
    for (const [user, values] of Object.entries(body)) {
      for (const [id, signed] of Object.entries(values as Record<string, Record<string, unknown>>)) {
        const master = this.master[user] as Record<string, unknown> | undefined;
        const target = this.devices[user]?.[id] as Record<string, unknown> | undefined
          ?? (master && Object.values(master.keys as Record<string, string>).includes(id) ? master : undefined);
        if (!target) throw new Error(`Unknown native signature target ${user}/${id}`);
        const existing = target.signatures as Record<string, Record<string, string>> | undefined;
        const signatures = signed.signatures as Record<string, Record<string, string>>;
        target.signatures = { ...existing };
        for (const [signer, keys] of Object.entries(signatures)) {
          (target.signatures as Record<string, Record<string, string>>)[signer] = { ...existing?.[signer], ...keys };
        }
      }
    }
  }
  fetch: typeof fetch = async (input, init) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    const body = typeof init?.body === "string" ? JSON.parse(init.body) as Record<string, unknown> : {};
    if (url.pathname.endsWith("/keys/upload")) {
      const key = body.device_keys as { user_id: string; device_id: string } | undefined;
      if (key) (this.devices[key.user_id] ||= {})[key.device_id] = key;
      return Response.json({ one_time_key_counts: { signed_curve25519: 50 } });
    }
    if (url.pathname.endsWith("/keys/device_signing/upload")) {
      for (const [field, destination] of [["master_key", this.master], ["self_signing_key", this.self], ["user_signing_key", this.signing]] as const) {
        const key = body[field] as { user_id: string } | undefined; if (key) destination[key.user_id] = key;
      }
      return Response.json({});
    }
    if (url.pathname.endsWith("/keys/query")) return Response.json(this.query());
    if (url.pathname.endsWith("/keys/signatures/upload")) { this.uploadSignatures(body); return Response.json({ failures: {} }); }
    if (url.pathname.includes("/account_data/")) return Response.json({ errcode: "M_NOT_FOUND", error: "No secret storage in this in-memory protocol fixture" }, { status: 404 });
    throw new Error(`Unexpected native protocol request: ${url.pathname}`);
  };
  async client(user: string): Promise<RealRustCrypto> {
    const client = createClient({ baseUrl: "https://matrix.example.test", userId: user, deviceId: user === owner ? "OWNER" : "PEER", accessToken: "synthetic-native-auth", fetchFn: this.fetch });
    clients.push(client); await client.initRustCrypto({ useIndexedDB: false });
    const crypto = client.getCrypto() as RealRustCrypto;
    await crypto.bootstrapCrossSigning({ setupNewCrossSigning: true });
    return crypto;
  }
  async importIdentity(crypto: RealRustCrypto, user: string): Promise<void> {
    const machine = crypto.getOlmMachineOrThrow(); const query = machine.queryKeysForUsers([new UserId(user)]);
    await machine.markRequestAsSent(query.id, query.type, JSON.stringify(this.query()));
  }
}
afterEach(async () => { for (const client of clients.splice(0)) { client.stopClient(); await client.store.deleteAllData(); } });
const participant: MatrixIdentity = { tenant_id: "synthetic", user_id: "synthetic-peer", issuer: "https://matrix.example.test", matrix_user_id: peer, provisioning_state: "ready" };

describe("actual maintained Matrix43/Rust18 authorization seam", () => {
  it("uses real Rust identity verification state and refuses an identity replacement", async () => {
    const native = new NativeMatrixFixture(); const alice = await native.client(owner); const bob = await native.client(peer);
    await native.importIdentity(alice, peer);
    await expect(assertVerifiedParticipants(alice, [participant])).rejects.toThrow(/unverified/);
    const identity = await alice.getOlmMachineOrThrow().getIdentity(new UserId(peer));
    expect(identity).toBeDefined();
    // Explicit maintained-Rust identity verification validates this trust gate;
    // it does NOT qualify SAS interoperability. The separate live browser gate
    // must complete real participant SAS before provider/security acceptance.
    const signature = await identity!.verify(); identity!.free();
    native.uploadSignatures(JSON.parse(signature.body));
    await native.importIdentity(alice, peer);
    expect((await alice.getUserVerificationStatus(peer)).isCrossSigningVerified()).toBe(true);
    await expect(assertVerifiedParticipants(alice, [participant])).resolves.toBeUndefined();
    await bob.bootstrapCrossSigning({ setupNewCrossSigning: true }); await native.importIdentity(alice, peer);
    await expect(assertVerifiedParticipants(alice, [participant])).rejects.toThrow(/Changed or unverified/);
  }, 20_000);

  it("requires a fresh exact zero-key control response and rejects real published Rust signing/device keys", async () => {
    const native = new NativeMatrixFixture(); const alice = await native.client(owner);
    assertControlKeyAbsence(native.query(), control);
    expect((await alice.getUserDeviceInfo([control], true)).get(control)?.size || 0).toBe(0);
    const realMaster = native.master[owner]; const realDevice = native.devices[owner];
    expect(() => assertControlKeyAbsence({ device_keys: { [control]: realDevice } }, control)).toThrow(/control/);
    expect(() => assertControlKeyAbsence({ device_keys: {}, master_keys: { [control]: realMaster } }, control)).toThrow(/signing/);
    for (const malformed of [null, false, 0, 42, "", [], [realDevice]]) {
      expect(() => assertControlKeyAbsence({ device_keys: { [control]: malformed } }, control)).toThrow();
      expect(() => assertControlKeyAbsence({ device_keys: {}, failures: malformed }, control)).toThrow();
      expect(() => assertControlKeyAbsence({ device_keys: {}, master_keys: { [control]: malformed } }, control)).toThrow();
    }
    expect(() => assertControlKeyAbsence({ device_keys: {}, failures: {} }, control)).not.toThrow();
  }, 20_000);
});
