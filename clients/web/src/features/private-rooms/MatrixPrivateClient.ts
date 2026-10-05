import { createClient, ClientEvent, MatrixEventEvent, RoomEvent, type MatrixClient } from "matrix-js-sdk";
import { CryptoEvent, EventShieldColour, OnlySignedDevicesIsolationMode, VerifierEvent, VerificationPhase, VerificationRequestEvent, decodeRecoveryKey, type CryptoApi, type GeneratedSecretStorageKey, type ShowSasCallbacks, type VerificationRequest } from "matrix-js-sdk/lib/crypto-api";
import type { MatrixClientSession, OpaqueContent, PrivateRoom, PrivateRoomApi, MatrixIdentity } from "./types";

export interface PrivatePlaintext { id: string; sender: string; body: string }
export interface PrivateClientCallbacks {
  messages(messages: PrivatePlaintext[]): void;
  blocked(message: string): void;
  verification(request: VerificationRequest): void;
  sas(callbacks: ShowSasCallbacks): void;
}

function record(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
export function assertControlKeyAbsence(value: unknown, control: string): void {
  if (!record(value) || !record(value.device_keys)) throw new Error("Native device-key proof is malformed.");
  if (Object.hasOwn(value, "failures") && (!record(value.failures) || Object.keys(value.failures).length !== 0)) throw new Error("Native device-key proof has unresolved failures.");
  if (Object.hasOwn(value.device_keys, control) && (!record(value.device_keys[control]) || Object.keys(value.device_keys[control]).length !== 0)) throw new Error("Server control crypto device appeared or its proof is malformed.");
  for (const section of ["master_keys", "self_signing_keys", "user_signing_keys"]) {
    if (Object.hasOwn(value, section) && (!record(value[section]) || Object.hasOwn(value[section], control))) throw new Error("Server control signing identity appeared or its proof is malformed.");
  }
}

export async function assertVerifiedParticipants(crypto: CryptoApi, participants: readonly MatrixIdentity[]): Promise<void> {
  for (const member of participants) {
    const verification = await crypto.getUserVerificationStatus(member.matrix_user_id);
    if (!verification.isCrossSigningVerified() || verification.needsUserApproval) throw new Error("Verify every participant with matching SAS. Changed or unverified identities block sending.");
  }
}

const retainedClients = new Map<string, MatrixPrivateClient>();
export async function clearPrivateCryptoForIdentity(tenant: string, user: string): Promise<void> {
  await Promise.all([...retainedClients.values()].filter((runtime) => runtime.identity === `${tenant}:${user}`).map((runtime) => runtime.close(true)));
}

/** Maintained Matrix Rust crypto with application authorization and trust gates.
 * This class implements no cipher, key derivation or verification protocol. */
export class MatrixPrivateClient {
  readonly identity: string;
  private client: MatrixClient | null = null;
  private credentials: MatrixClientSession | null = null;
  private releaseStore: (() => void) | null = null;
  private storePrefix = "";
  private alive = false;
  private selected: PrivateRoom | null = null;
  private timer: ReturnType<typeof setInterval> | null = null;
  private recoveryKey: Uint8Array<ArrayBuffer> | null = null;
  private generatedRecovery: GeneratedSecretStorageKey | null = null;
  private authorizedEvents = new Set<string>();
  private generation = 0;
  private busyRefresh = false;
  private sendScopes = new Map<string, { room: string; nativeRoom: string; epoch: number; generation: number }>();
  private wireOutbox = new Map<string, { content: OpaqueContent; room: string; epoch: number; generation: number }>();

  constructor(private readonly api: PrivateRoomApi, tenant: string, user: string, private readonly callbacks: PrivateClientCallbacks) { this.identity = `${tenant}:${user}`; }
  async unlock(storagePassword: string): Promise<void> {
    if (!globalThis.isSecureContext || !navigator.locks || storagePassword.length < 12) throw new Error("Use HTTPS, a browser with Web Locks, and a local store password of at least 12 characters.");
    if (this.alive) throw new Error("This encrypted device is already unlocked.");
    this.credentials = await this.api.matrixClientSession();
    const credentials = this.credentials;
    this.storePrefix = `kc-matrix-${this.identity}-${credentials.matrix_device_id}`;
    const previous = retainedClients.get(this.storePrefix);
    if (previous && previous !== this) await previous.close(false);
    await new Promise<void>((resolve, reject) => {
      void navigator.locks.request(this.storePrefix, { mode: "exclusive", ifAvailable: true }, async (lock) => {
        if (!lock) { reject(new Error("This encrypted device is open in another tab. Lock that tab first.")); return; }
        const lifetime = new Promise<void>((release) => { this.releaseStore = release; });
        resolve();
        await lifetime;
      }).catch(reject);
    });
    this.alive = true;
    const client = createClient({ baseUrl: credentials.homeserver_url, userId: credentials.matrix_user_id, deviceId: credentials.matrix_device_id, accessToken: credentials.access_token, verificationMethods: ["m.sas.v1"], fetchFn: this.authorizedFetch, cryptoCallbacks: {
      getSecretStorageKey: async ({ keys }) => { const keyId = Object.keys(keys)[0]; return keyId && this.recoveryKey ? [keyId, this.recoveryKey] : null; },
      cacheSecretStorageKey: (_id, _info, key) => { this.recoveryKey?.fill(0); this.recoveryKey = new Uint8Array(key); }
    } });
    this.client = client;
    retainedClients.set(this.storePrefix, this);
    try {
      // SDK performs store encryption/key derivation. Timeline remains in the
      // default MemoryStore; plaintext messages and outbox are never persisted.
      await client.initRustCrypto({ useIndexedDB: true, cryptoDatabasePrefix: this.storePrefix, storagePassword });
      this.crypto().setDeviceIsolationMode(new OnlySignedDevicesIsolationMode());
      client.on(CryptoEvent.VerificationRequestReceived, (request) => {
        const peers = new Set([this.credentials!.matrix_user_id, ...(this.selected?.members.map((member) => member.matrix_user_id) || [])]);
        if (this.alive && peers.has(request.otherUserId)) this.callbacks.verification(request);
        else void request.cancel();
      });
      client.on(RoomEvent.Timeline, () => { void this.refresh().catch((error: unknown) => this.fail(error)); });
      client.on(MatrixEventEvent.Decrypted, () => { void this.refresh().catch((error: unknown) => this.fail(error)); });
      const prepared = new Promise<void>((resolve, reject) => {
        const deadline = setTimeout(() => reject(new Error("Encrypted sync did not become ready.")), 20_000);
        client.on(ClientEvent.Sync, (state) => { if (state === "PREPARED" || state === "SYNCING") { clearTimeout(deadline); resolve(); } });
      });
      await client.startClient({ initialSyncLimit: 50 });
      await prepared;
      this.timer = setInterval(() => { void this.refresh().catch((error: unknown) => this.fail(error)); }, 10_000);
    } catch (error) { await this.close(false); throw error; }
  }
  private crypto(): CryptoApi { const crypto = this.client?.getCrypto(); if (!crypto) throw new Error("Rust encryption is unavailable."); return crypto; }
  async prepareRecovery(): Promise<string> {
    const crypto = this.crypto();
    await crypto.getUserDeviceInfo([this.credentials!.matrix_user_id], true);
    if (await crypto.getCrossSigningKeyId()) throw new Error("This identity already exists. Recover it or verify this device; it will not be reset.");
    if (await this.client!.secretStorage.hasKey()) throw new Error("Existing secret storage requires recovery.");
    this.generatedRecovery = await crypto.createRecoveryKeyFromPassphrase();
    if (!this.generatedRecovery.encodedPrivateKey) throw new Error("SDK did not generate a recovery key.");
    return this.generatedRecovery.encodedPrivateKey;
  }
  async confirmRecoverySaved(): Promise<void> {
    const generated = this.generatedRecovery;
    if (!generated) throw new Error("Generate and save a recovery key first.");
    const crypto = this.crypto();
    if (await crypto.getCrossSigningKeyId() || await this.client!.secretStorage.hasKey()) throw new Error("Identity changed during setup; use recovery.");
    this.recoveryKey = new Uint8Array(generated.privateKey);
    await crypto.bootstrapCrossSigning({ setupNewCrossSigning: false, authUploadDeviceSigningKeys: (makeRequest) => makeRequest(null) });
    await crypto.bootstrapSecretStorage({ setupNewSecretStorage: false, setupNewKeyBackup: true, createSecretStorageKey: async () => generated });
    if (!await crypto.isCrossSigningReady()) throw new Error("Cross-signing setup is incomplete; keys were not reset.");
    generated.privateKey.fill(0); this.generatedRecovery = null;
    await this.refresh();
  }
  async recover(encoded: string): Promise<void> {
    this.recoveryKey?.fill(0); this.recoveryKey = decodeRecoveryKey(encoded);
    const crypto = this.crypto();
    await crypto.getUserDeviceInfo([this.credentials!.matrix_user_id], true);
    const status = await crypto.getCrossSigningStatus();
    if (!await crypto.getCrossSigningKeyId() || !status.privateKeysInSecretStorage) throw new Error("Existing identity recovery secrets are unavailable. Verify another device; reset is refused.");
    await crypto.bootstrapCrossSigning({ setupNewCrossSigning: false, authUploadDeviceSigningKeys: (makeRequest) => makeRequest(null) });
    if (!await crypto.isCrossSigningReady()) throw new Error("Recovery did not verify this device.");
    await crypto.loadSessionBackupPrivateKeyFromSecretStorage();
    await crypto.checkKeyBackupAndEnable();
    await crypto.restoreKeyBackup();
    await this.refresh();
  }
  async verify(userId: string, deviceId: string): Promise<void> { const request = await this.crypto().requestDeviceVerification(userId, deviceId); this.callbacks.verification(request); }
  async acceptVerification(request: VerificationRequest): Promise<void> {
    if (!request.initiatedByMe && request.phase === VerificationPhase.Requested) await request.accept();
    if (request.phase === VerificationPhase.Requested) await new Promise<void>((resolve, reject) => {
      const changed = () => {
        if (request.phase === VerificationPhase.Ready || request.phase === VerificationPhase.Started) { cleanup(); resolve(); }
        else if (!request.pending) { cleanup(); reject(new Error("Peer cancelled verification.")); }
      };
      const deadline = setTimeout(() => { cleanup(); reject(new Error("Wait for the peer to accept verification, then try again.")); }, 30_000);
      const cleanup = () => { clearTimeout(deadline); request.off(VerificationRequestEvent.Change, changed); };
      request.on(VerificationRequestEvent.Change, changed); changed();
    });
    const verifier = request.verifier || await request.startVerification("m.sas.v1");
    verifier.on(VerifierEvent.ShowSas, (callbacks) => { if (this.alive) this.callbacks.sas(callbacks); });
    await verifier.verify();
    await this.refresh();
  }
  async devices(userId: string): Promise<string[]> { const devices = await this.crypto().getUserDeviceInfo([userId], true); return [...(devices.get(userId)?.keys() || [])]; }
  publicDevice(): { userId: string; deviceId: string } | null { return this.credentials ? { userId: this.credentials.matrix_user_id, deviceId: this.credentials.matrix_device_id } : null; }
  async select(room: PrivateRoom): Promise<void> {
    if (!this.client || !room.matrix_room_id) throw new Error("Unlock the device and finish room provisioning first.");
    this.selected = await this.api.privateRoom(room.id); this.authorizedEvents.clear(); this.callbacks.messages([]);
    await this.client.joinRoom(room.matrix_room_id);
    await this.refresh();
  }
  async loadEarlier(): Promise<void> {
    const room = await this.authorizeSelected();
    const sdkRoom = this.client!.getRoom(room.matrix_room_id!);
    if (!sdkRoom || sdkRoom.getLiveTimeline().getEvents().length >= 10_000) throw new Error("Bounded encrypted history limit reached.");
    await this.client!.scrollback(sdkRoom, 50); await this.refresh();
  }
  async send(body: string, transactionId: string): Promise<void> {
    if (!body.trim() || [...body].length > 8000 || new TextEncoder().encode(body).length > 32000) throw new Error("Use 1–8,000 text characters.");
    const room = await this.authorizeSelected();
    await this.validateTrust(room);
    // SDK encrypts m.room.message. The fetch adapter sees ONLY its encrypted
    // wire envelope and routes it through current K authority/idempotency.
    const pending = this.wireOutbox.get(transactionId);
    const scope = this.sendScopes.get(transactionId) || { room: room.id, nativeRoom: room.matrix_room_id!, epoch: room.membership_epoch, generation: room.generation };
    if (scope.room !== room.id || scope.nativeRoom !== room.matrix_room_id || scope.epoch !== room.membership_epoch || scope.generation !== room.generation || (pending && (pending.epoch !== scope.epoch || pending.generation !== scope.generation))) throw new Error("The original encrypted send belongs to a withdrawn generation.");
    this.sendScopes.set(transactionId, scope);
    await this.client!.sendTextMessage(scope.nativeRoom, body, transactionId);
    await this.refresh();
  }
  private async authorizeSelected(): Promise<PrivateRoom> {
    if (!this.alive || !this.selected) throw new Error("Select an unlocked encrypted room.");
    const room = await this.api.privateRoom(this.selected.id);
    if (room.state !== "active" || room.matrix_room_id !== this.selected.matrix_room_id) throw new Error("Room is fenced while membership or erasure is pending.");
    if (room.membership_epoch !== this.selected.membership_epoch || room.generation !== this.selected.generation) {
      await this.crypto().forceDiscardSession(room.matrix_room_id!);
      this.authorizedEvents.clear(); this.callbacks.messages([]);
    }
    this.selected = room; return room;
  }
  private async validateTrust(room: PrivateRoom): Promise<void> {
    const crypto = this.crypto();
    if (!await crypto.isCrossSigningReady() || !await crypto.isEncryptionEnabledInRoom(room.matrix_room_id!)) throw new Error("Verify/recover this device and confirm room encryption before sending.");
    const sdkRoom = this.client!.getRoom(room.matrix_room_id!);
    if (!sdkRoom || sdkRoom.currentState.getStateEvents("m.room.encryption", "")?.getContent().algorithm !== "m.megolm.v1.aes-sha2") throw new Error("Encryption state changed; sending is blocked.");
    await this.validateControl(room);
    const expected = new Set([room.control_matrix_user_id, ...room.members.map((member) => member.matrix_user_id)]);
    const actual = sdkRoom.getMembers().filter((member) => member.membership === "join" || member.membership === "invite");
    if (actual.some((member) => !expected.has(member.userId)) || room.members.some((member) => sdkRoom.getMember(member.matrix_user_id)?.membership !== "join")) throw new Error("All exact participants must accept; unknown room members block encryption.");
    const devices = await crypto.getUserDeviceInfo([...expected], true);
    if (devices.get(room.control_matrix_user_id)?.size) throw new Error("Server control published a crypto device; private sending is blocked.");
    await assertVerifiedParticipants(crypto, room.members);
  }
  private async validateControl(room: PrivateRoom): Promise<void> {
    // downloadUncached may use SDK tracked keys, so control absence requires
    // a fresh native query before each send and plaintext projection.
    const response = await this.authorizedFetch(new URL("/_matrix/client/v3/keys/query", this.credentials!.homeserver_url), { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ device_keys: { [room.control_matrix_user_id]: [] } }) });
    if (!response.ok) throw new Error("Current server-control key absence could not be confirmed.");
    if ((await this.crypto().getUserDeviceInfo([room.control_matrix_user_id], true)).get(room.control_matrix_user_id)?.size) { const error = new Error("Cached server-control crypto device appeared; private projection is blocked."); this.fail(error); throw error; }
  }
  private async refresh(): Promise<void> {
    if (!this.alive || !this.selected || this.busyRefresh) return;
    this.busyRefresh = true;
    const generation = this.generation;
    try {
      const room = await this.authorizeSelected();
      let cursor = 0; let pages = 0; const allowed = new Set<string>();
      do {
        const page = await this.api.replayPrivateEvents(room.id, cursor, room.membership_epoch, room.generation);
        for (const intent of page.pending_intents) {
          const resumed = await this.api.sendPrivateEvent(room.id, intent.transaction_id, intent.content, intent.membership_epoch, intent.generation);
          if (resumed.event.matrix_event_id) allowed.add(resumed.event.matrix_event_id);
        }
        for (const event of page.events) { if (event.matrix_event_id) allowed.add(event.matrix_event_id); cursor = event.sequence; }
        if (!page.has_more) break;
        if (++pages >= 100) throw new Error("Opaque replay limit reached.");
      } while (pages < 100);
      this.authorizedEvents = allowed;
      const sdkRoom = this.client!.getRoom(room.matrix_room_id!); const output: PrivatePlaintext[] = [];
      for (const event of sdkRoom?.getLiveTimeline().getEvents() || []) {
        const id = event.getId(); if (!id || !allowed.has(id) || !event.isEncrypted()) continue;
        await this.client!.decryptEventIfNeeded(event);
        const info = await this.crypto().getEncryptionInfoForEvent(event);
        if (!info || info.shieldColour !== EventShieldColour.NONE || event.isDecryptionFailure()) continue;
        const content = event.getContent();
        if (content.msgtype === "m.text" && typeof content.body === "string" && content.body.length <= 32000) output.push({ id, sender: event.getSender() || "", body: content.body });
      }
      await this.api.privateRoom(room.id);
      await this.validateControl(room);
      if (this.alive && generation === this.generation) this.callbacks.messages(output);
    } finally { this.busyRefresh = false; }
  }
  private authorizedFetch: typeof fetch = async (input, init) => {
    if (!this.alive || !this.credentials) throw new Error("Encrypted client is locked.");
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    if (url.origin !== new URL(this.credentials.homeserver_url).origin) throw new Error("Unexpected crypto provider origin.");
    const credential = await this.api.matrixClientSession();
    if (credential.k_session_id !== this.credentials.k_session_id || credential.matrix_device_id !== this.credentials.matrix_device_id || credential.matrix_user_id !== this.credentials.matrix_user_id) throw new Error("Current device identity changed.");
    this.credentials = credential; this.client?.setAccessToken(credential.access_token);
    const method = (init?.method || "GET").toUpperCase();
    const encryptedSend = url.pathname.match(/^\/_matrix\/client\/v3\/rooms\/([^/]+)\/send\/m\.room\.encrypted\/([^/]+)$/);
    if (encryptedSend && method === "PUT") {
      const room = await this.authorizeSelected();
      if (decodeURIComponent(encryptedSend[1] || "") !== room.matrix_room_id || typeof init?.body !== "string") throw new Error("Encrypted envelope binding failed.");
      const txn = decodeURIComponent(encryptedSend[2] || "");
      const scope = this.sendScopes.get(txn);
      if (!scope || scope.room !== room.id || scope.nativeRoom !== room.matrix_room_id || scope.epoch !== room.membership_epoch || scope.generation !== room.generation) throw new Error("Membership changed during SDK encryption; this ciphertext cannot be relabelled or sent.");
      const pending = this.wireOutbox.get(txn);
      if (pending && (pending.room !== room.id || pending.epoch !== room.membership_epoch || pending.generation !== room.generation)) throw new Error("Unknown-ACK intent belongs to an older membership generation; it cannot be silently resent.");
      if (!pending && this.wireOutbox.size >= 32) throw new Error("Resolve pending encrypted sends first.");
      const intent = pending || { content: JSON.parse(init.body) as OpaqueContent, room: scope.room, epoch: scope.epoch, generation: scope.generation };
      this.wireOutbox.set(txn, intent);
      const result = await this.api.sendPrivateEvent(room.id, txn, intent.content, intent.epoch, intent.generation);
      this.wireOutbox.delete(txn); this.sendScopes.delete(txn);
      return new Response(JSON.stringify({ event_id: result.event.matrix_event_id }), { status: 200, headers: { "Content-Type": "application/json" } });
    }
    if (/\/send\//.test(url.pathname)) throw new Error("Private clients cannot send plaintext/custom room events.");
    if (/\/sendToDevice\/m\.room\.encrypted\//.test(url.pathname) && method === "PUT") {
      if (typeof init?.body !== "string") throw new Error("Encrypted device recipients are missing.");
      const payload = JSON.parse(init.body) as { messages?: Record<string, Record<string, unknown>> };
      const currentRoom = this.selected ? await this.authorizeSelected() : null;
      const allowed = new Set([credential.matrix_user_id, ...(currentRoom?.members.map((member) => member.matrix_user_id) || [])]);
      for (const [user, deviceMessages] of Object.entries(payload.messages || {})) {
        if (!allowed.has(user) || user === credential.control_matrix_user_id) throw new Error("Room keys cannot be shared with unknown, removed or server-control identities.");
        const trust = await this.crypto().getUserVerificationStatus(user);
        if (!trust.isCrossSigningVerified() || trust.needsUserApproval) throw new Error("Room-key recipient identity is not SAS verified.");
        for (const device of Object.keys(deviceMessages)) {
          const trustDevice = await this.crypto().getDeviceVerificationStatus(user, device);
          if (!trustDevice?.isVerified()) throw new Error("Room keys cannot be sent to an unverified device.");
        }
      }
    }
    if (url.pathname.endsWith("/keys/device_signing/upload") && method === "POST") {
      if (typeof init?.body !== "string") throw new Error("Invalid public signing keys.");
      const publicKeys = JSON.parse(init.body) as Record<string, unknown>; if (publicKeys.auth != null) throw new Error("Client authentication secrets are refused."); delete publicKeys.auth;
      await this.api.matrixUploadPublicSigningKeys(publicKeys);
      return new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
    }
    const headers = new Headers(init?.headers); headers.set("Authorization", `Bearer ${credential.access_token}`);
    const native = await fetch(input, { ...init, headers });
    const reader = native.body?.getReader(); const chunks: Uint8Array[] = []; let size = 0;
    if (reader) {
      try { while (true) { const part = await reader.read(); if (part.done) break; size += part.value.byteLength; if (size > 8_388_608) throw new Error("Native encrypted response exceeds its bounded limit."); chunks.push(part.value); } }
      catch (error) { await reader.cancel(); throw error; }
      finally { reader.releaseLock(); }
    }
    const bytes = new Uint8Array(size); let offset = 0; for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    const response = new Response(native.status === 204 || native.status === 205 || native.status === 304 ? null : bytes, { status: native.status, statusText: native.statusText, headers: native.headers });
    if (url.pathname.endsWith("/keys/query") && response.ok) {
      try { assertControlKeyAbsence(await response.clone().json(), this.credentials.control_matrix_user_id); }
      catch (error) { this.fail(error); throw error; }
    }
    await this.api.matrixClientSession();
    return response;
  };
  private fail(error: unknown): void { if (!this.alive) return; this.callbacks.messages([]); this.callbacks.blocked(error instanceof Error ? error.message : "Private authorization failed."); void this.close(false); }
  async close(clearStores: boolean): Promise<void> {
    this.alive = false; this.generation++; this.selected = null; this.authorizedEvents.clear(); this.wireOutbox.clear(); this.sendScopes.clear(); this.callbacks.messages([]);
    if (this.timer) clearInterval(this.timer); this.timer = null;
    this.client?.stopClient();
    this.recoveryKey?.fill(0); this.generatedRecovery?.privateKey.fill(0); this.recoveryKey = null; this.generatedRecovery = null;
    const client = this.client; this.client = null;
    try {
      if (client) await client.store.deleteAllData();
      if (clearStores && this.credentials) {
        // clearStores needs no network or active token. Drop the old SDK
        // instance so it cannot retain decrypted room timelines in memory.
        const cleaner = createClient({ baseUrl: this.credentials.homeserver_url, userId: this.credentials.matrix_user_id, deviceId: this.credentials.matrix_device_id });
        await cleaner.clearStores({ cryptoDatabasePrefix: this.storePrefix }); retainedClients.delete(this.storePrefix);
      }
    }
    finally { this.releaseStore?.(); this.releaseStore = null; }
  }
}
