#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import { resolve } from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const DEFAULT_TIMEOUT_MS = 15_000;
const MAX_TIMEOUT_MS = 120_000;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

class AcceptanceError extends Error {
  constructor(message) {
    super(message);
    this.name = "AcceptanceError";
  }
}

function assert(condition, message) {
  if (!condition) throw new AcceptanceError(message);
}

function assertRecord(value, label) {
  assert(value !== null && typeof value === "object" && !Array.isArray(value), `${label} must be an object`);
  return value;
}

function assertString(value, label) {
  assert(typeof value === "string" && value.length > 0, `${label} must be a non-empty string`);
  return value;
}

function assertUuid(value, label) {
  assertString(value, label);
  assert(UUID_PATTERN.test(value), `${label} must be a UUID`);
  return value;
}

function requiredEnv(env, name) {
  const value = env[name]?.trim();
  if (!value) throw new AcceptanceError(`Missing required environment variable ${name}`);
  return value;
}

function parseHttpUrl(value, name) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new AcceptanceError(`${name} must be an absolute HTTP(S) URL`);
  }
  assert(["http:", "https:"].includes(url.protocol), `${name} must use HTTP or HTTPS`);
  url.hash = "";
  url.search = "";
  return url;
}

function parseTimeout(value) {
  if (!value) return DEFAULT_TIMEOUT_MS;
  const parsed = Number.parseInt(value, 10);
  assert(
    Number.isInteger(parsed) && parsed >= 1_000 && parsed <= MAX_TIMEOUT_MS,
    `K_COMMS_TIMEOUT_MS must be between 1000 and ${MAX_TIMEOUT_MS}`
  );
  return parsed;
}

function readConfiguration(env = process.env) {
  const baseUrl = parseHttpUrl(requiredEnv(env, "K_COMMS_BASE_URL"), "K_COMMS_BASE_URL");
  const objectUrl = parseHttpUrl(requiredEnv(env, "K_COMMS_OBJECT_URL"), "K_COMMS_OBJECT_URL");
  const tenantSlug = requiredEnv(env, "K_COMMS_TENANT_SLUG");
  const ownerEmail = requiredEnv(env, "K_COMMS_OWNER_EMAIL");
  const ownerPassword = requiredEnv(env, "K_COMMS_OWNER_PASSWORD");
  const conversationId = env.K_COMMS_CONVERSATION_ID?.trim() || null;
  if (conversationId) assertUuid(conversationId, "K_COMMS_CONVERSATION_ID");

  return {
    baseUrl,
    objectUrl,
    socketUrl: buildSocketUrl(baseUrl, env.K_COMMS_SOCKET_URL?.trim()),
    tenantSlug,
    ownerEmail,
    ownerPassword,
    conversationId,
    timeoutMs: parseTimeout(env.K_COMMS_TIMEOUT_MS)
  };
}

function buildSocketUrl(baseUrl, configuredUrl) {
  let socketUrl;
  try {
    socketUrl = configuredUrl ? new URL(configuredUrl) : new URL("/socket/websocket", baseUrl);
  } catch {
    throw new AcceptanceError("K_COMMS_SOCKET_URL must be an absolute WebSocket or HTTP(S) URL");
  }

  if (socketUrl.protocol === "http:") socketUrl.protocol = "ws:";
  if (socketUrl.protocol === "https:") socketUrl.protocol = "wss:";
  assert(["ws:", "wss:"].includes(socketUrl.protocol), "K_COMMS_SOCKET_URL must use WS, WSS, HTTP, or HTTPS");

  socketUrl.hash = "";
  socketUrl.search = "";
  socketUrl.pathname = socketUrl.pathname.replace(/\/$/, "");
  if (socketUrl.pathname.endsWith("/socket")) socketUrl.pathname += "/websocket";
  if (!socketUrl.pathname.endsWith("/socket/websocket")) {
    throw new AcceptanceError("K_COMMS_SOCKET_URL must end in /socket or /socket/websocket");
  }
  return socketUrl;
}

function assertSignedTarget(rawUrl, objectBaseUrl, label) {
  let signedUrl;
  try {
    signedUrl = new URL(rawUrl);
  } catch {
    throw new AcceptanceError(`${label} URL must be absolute`);
  }
  assert(["http:", "https:"].includes(signedUrl.protocol), `${label} URL must use HTTP or HTTPS`);
  assert(signedUrl.origin === objectBaseUrl.origin, `${label} URL origin does not match K_COMMS_OBJECT_URL`);

  const expectedPath = objectBaseUrl.pathname.replace(/\/$/, "");
  if (expectedPath) {
    assert(
      signedUrl.pathname === expectedPath || signedUrl.pathname.startsWith(`${expectedPath}/`),
      `${label} URL path is outside K_COMMS_OBJECT_URL`
    );
  }
  return signedUrl;
}

function redactText(value, secrets = []) {
  let output = value instanceof Error ? value.message : String(value);
  for (const secret of secrets) {
    if (typeof secret === "string" && secret.length > 0) output = output.split(secret).join("[REDACTED]");
  }
  output = output.replace(
    /([?&](?:X-Amz-[^=&\s]+|access_token|refresh_token|password|token)=)[^&\s]+/gi,
    "$1[REDACTED]"
  );
  return output.slice(0, 1_000);
}

class ApiClient {
  constructor(baseUrl, timeoutMs) {
    this.baseUrl = baseUrl;
    this.timeoutMs = timeoutMs;
  }

  async request(path, { method = "GET", token, body, headers = {}, expected = 200 } = {}) {
    const expectedStatuses = Array.isArray(expected) ? expected : [expected];
    const requestHeaders = new Headers(headers);
    requestHeaders.set("accept", "application/json");
    if (token) requestHeaders.set("authorization", `Bearer ${token}`);

    let requestBody;
    if (body !== undefined) {
      requestHeaders.set("content-type", "application/json");
      requestBody = JSON.stringify(body);
    }

    const url = new URL(path, this.baseUrl);
    let response;
    try {
      response = await fetch(url, {
        method,
        headers: requestHeaders,
        body: requestBody,
        signal: AbortSignal.timeout(this.timeoutMs)
      });
    } catch {
      throw new AcceptanceError(`${method} ${url.pathname} did not complete`);
    }

    const contentType = response.headers.get("content-type") || "";
    let payload = null;
    if (response.status !== 204) {
      try {
        payload = contentType.includes("application/json") ? await response.json() : await response.text();
      } catch {
        throw new AcceptanceError(`${method} ${url.pathname} returned an unreadable response`);
      }
    }

    if (!expectedStatuses.includes(response.status)) {
      const errorCode = payload && typeof payload === "object" ? payload.error?.code : null;
      const suffix = typeof errorCode === "string" ? ` (${errorCode})` : "";
      throw new AcceptanceError(
        `${method} ${url.pathname} expected HTTP ${expectedStatuses.join(" or ")} but received ${response.status}${suffix}`
      );
    }
    return { response, payload };
  }
}

class PhoenixChannel {
  constructor(socketUrl, accessToken, timeoutMs) {
    this.timeoutMs = timeoutMs;
    this.ref = 0;
    this.pending = new Map();
    this.events = [];
    this.eventWaiters = [];
    this.closed = false;
    this.topic = null;
    this.joinRef = null;

    const authenticatedUrl = new URL(socketUrl);
    authenticatedUrl.searchParams.set("vsn", "2.0.0");
    authenticatedUrl.searchParams.set("access_token", accessToken);
    this.socket = new WebSocket(authenticatedUrl);

    this.closedPromise = new Promise((resolveClose) => {
      this.resolveClose = resolveClose;
    });
    this.socket.addEventListener("message", (event) => {
      void this.handleMessage(event.data).catch(() => this.failProtocol("Phoenix transport frame could not be read"));
    });
    this.socket.addEventListener("close", () => this.handleClose());
  }

  async connect() {
    if (this.socket.readyState === 1) return;
    await new Promise((resolveOpen, rejectOpen) => {
      const timer = setTimeout(() => rejectOpen(new AcceptanceError("WebSocket connection timed out")), this.timeoutMs);
      const opened = () => {
        clearTimeout(timer);
        this.socket.removeEventListener("error", failed);
        resolveOpen();
      };
      const failed = () => {
        clearTimeout(timer);
        this.socket.removeEventListener("open", opened);
        rejectOpen(new AcceptanceError("WebSocket connection failed"));
      };
      this.socket.addEventListener("open", opened, { once: true });
      this.socket.addEventListener("error", failed, { once: true });
    });

    this.heartbeat = setInterval(() => {
      if (this.socket.readyState === 1) {
        this.socket.send(JSON.stringify([null, this.nextRef(), "phoenix", "heartbeat", {}]));
      }
    }, 20_000);
  }

  async join(topic, payload) {
    assert(this.socket.readyState === 1, "WebSocket must be open before joining");
    const ref = this.nextRef();
    const response = await this.sendForReply(ref, ref, topic, "phx_join", payload);
    this.topic = topic;
    this.joinRef = ref;
    return assertRecord(response, "Phoenix join response");
  }

  push(event, payload) {
    assert(this.topic && this.joinRef, "Phoenix channel must be joined before sending commands");
    const ref = this.nextRef();
    return this.sendForReply(this.joinRef, ref, this.topic, event, payload);
  }

  waitForEvent(eventName, predicate = () => true) {
    const existing = this.events.find((entry) => entry.event === eventName && predicate(entry.payload));
    if (existing) return Promise.resolve(existing.payload);

    return new Promise((resolveEvent, rejectEvent) => {
      const waiter = { eventName, predicate, resolveEvent, rejectEvent };
      waiter.timer = setTimeout(() => {
        this.eventWaiters = this.eventWaiters.filter((candidate) => candidate !== waiter);
        rejectEvent(new AcceptanceError(`Timed out waiting for Phoenix event ${eventName}`));
      }, this.timeoutMs);
      this.eventWaiters.push(waiter);
    });
  }

  eventCount(eventName, predicate = () => true) {
    return this.events.filter((entry) => entry.event === eventName && predicate(entry.payload)).length;
  }

  isOpen() {
    return this.socket.readyState === 1;
  }

  async waitForClose() {
    if (this.closed) return Promise.resolve();
    let timer;
    try {
      await Promise.race([
        this.closedPromise,
        new Promise((_, rejectClose) => {
          timer = setTimeout(
            () => rejectClose(new AcceptanceError("WebSocket did not close after session revocation")),
            this.timeoutMs
          );
        })
      ]);
    } finally {
      clearTimeout(timer);
    }
  }

  async close() {
    if (this.closed) return;
    if (this.socket.readyState === 0 || this.socket.readyState === 1) this.socket.close(1000, "acceptance complete");
    let timer;
    try {
      await Promise.race([
        this.closedPromise,
        new Promise((resolveClose) => {
          timer = setTimeout(resolveClose, Math.min(this.timeoutMs, 2_000));
        })
      ]);
    } finally {
      clearTimeout(timer);
    }
  }

  sendForReply(joinRef, ref, topic, event, payload) {
    return new Promise((resolveReply, rejectReply) => {
      const timer = setTimeout(() => {
        this.pending.delete(ref);
        rejectReply(new AcceptanceError(`Phoenix ${event} timed out`));
      }, this.timeoutMs);
      this.pending.set(ref, { resolveReply, rejectReply, timer, event });
      this.socket.send(JSON.stringify([joinRef, ref, topic, event, payload]));
    });
  }

  async handleMessage(data) {
    let text;
    if (typeof data === "string") text = data;
    else if (data instanceof Blob) text = await data.text();
    else text = Buffer.from(data).toString("utf8");

    let message;
    try {
      message = JSON.parse(text);
    } catch {
      this.failProtocol("Phoenix transport returned invalid JSON");
      return;
    }
    if (!Array.isArray(message) || message.length !== 5) {
      this.failProtocol("Phoenix transport returned an invalid frame");
      return;
    }

    const [, ref, , event, payload] = message;
    if (event === "phx_reply" && this.pending.has(ref)) {
      const pending = this.pending.get(ref);
      this.pending.delete(ref);
      clearTimeout(pending.timer);
      if (payload?.status === "ok") pending.resolveReply(payload.response);
      else {
        const reason = typeof payload?.response?.reason === "string" ? payload.response.reason : "rejected";
        pending.rejectReply(new AcceptanceError(`Phoenix ${pending.event} was rejected: ${reason}`));
      }
      return;
    }

    const entry = { event, payload };
    this.events.push(entry);
    for (const waiter of [...this.eventWaiters]) {
      if (waiter.eventName === event && waiter.predicate(payload)) {
        clearTimeout(waiter.timer);
        this.eventWaiters = this.eventWaiters.filter((candidate) => candidate !== waiter);
        waiter.resolveEvent(payload);
      }
    }
  }

  failProtocol(message) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.rejectReply(new AcceptanceError(message));
    }
    this.pending.clear();
  }

  handleClose() {
    if (this.closed) return;
    this.closed = true;
    if (this.heartbeat) clearInterval(this.heartbeat);
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.rejectReply(new AcceptanceError("WebSocket closed before a Phoenix reply"));
    }
    this.pending.clear();
    for (const waiter of this.eventWaiters) {
      clearTimeout(waiter.timer);
      waiter.rejectEvent(new AcceptanceError("WebSocket closed before the expected Phoenix event"));
    }
    this.eventWaiters = [];
    this.resolveClose();
  }

  nextRef() {
    this.ref += 1;
    return String(this.ref);
  }
}

function commandEnvelope(commandId, type, payload) {
  return { command_id: commandId, type, payload, client_time: new Date().toISOString() };
}

function assertMessage(value, label) {
  const message = assertRecord(value, label);
  assertUuid(message.id, `${label}.id`);
  assertUuid(message.conversation_id, `${label}.conversation_id`);
  assert(
    Number.isInteger(message.conversation_sequence) && message.conversation_sequence > 0,
    `${label}.conversation_sequence must be positive`
  );
  return message;
}

async function fetchSigned(descriptor, bytes, objectBaseUrl, timeoutMs, label, fileName) {
  const target = assertRecord(descriptor, `${label} descriptor`);
  const rawUrl = target.url || target.upload_url || target.href;
  assertString(rawUrl, `${label} URL`);
  const signedUrl = assertSignedTarget(rawUrl, objectBaseUrl, label);
  const headers = new Headers(assertRecord(target.headers || {}, `${label} headers`));
  let body = bytes;
  let method = target.method || (bytes === undefined ? "GET" : "PUT");

  if (bytes !== undefined && target.fields && Object.keys(target.fields).length > 0) {
    const form = new FormData();
    for (const [key, value] of Object.entries(target.fields)) form.append(key, String(value));
    form.append("file", new Blob([bytes], { type: headers.get("content-type") || "text/plain" }), fileName);
    body = form;
    method = target.method || "POST";
  }

  let response;
  try {
    response = await fetch(signedUrl, { method, headers, body, signal: AbortSignal.timeout(timeoutMs) });
  } catch {
    throw new AcceptanceError(`${label} request did not complete`);
  }
  assert(response.ok, `${label} expected HTTP success but received ${response.status}`);
  return response;
}

async function selectConversation(api, config, token, runId) {
  if (config.conversationId) {
    const { payload } = await api.request(`/api/v1/conversations/${config.conversationId}`, { token });
    return assertRecord(assertRecord(payload, "conversation response").data, "conversation");
  }

  const { payload } = await api.request("/api/v1/conversations", { token });
  const conversations = assertRecord(payload, "conversation list").data;
  assert(Array.isArray(conversations), "conversation list data must be an array");
  if (conversations.length > 0) return assertRecord(conversations[0], "conversation");

  const created = await api.request("/api/v1/conversations", {
    method: "POST",
    token,
    expected: 201,
    body: {
      title: `Staging acceptance ${runId}`,
      kind: "group",
      visibility: "private",
      member_ids: []
    }
  });
  return assertRecord(assertRecord(created.payload, "created conversation response").data, "created conversation");
}

async function runAcceptance(env = process.env) {
  const config = readConfiguration(env);
  const sensitiveValues = new Set([config.ownerPassword]);
  const api = new ApiClient(config.baseUrl, config.timeoutMs);
  const runId = randomUUID();
  let channel;

  try {
    await api.request("/health/ready");
    console.log("ok - readiness");

    const login = await api.request("/api/v1/sessions", {
      method: "POST",
      body: {
        tenant_slug: config.tenantSlug,
        email: config.ownerEmail,
        password: config.ownerPassword,
        device: { name: `staging-acceptance-${runId.slice(0, 8)}`, platform: "web" }
      }
    });
    const session = assertRecord(login.payload, "login response");
    const accessToken = assertString(session.access_token, "login response access token");
    const refreshToken = assertString(session.refresh_token, "login response refresh token");
    sensitiveValues.add(accessToken);
    sensitiveValues.add(refreshToken);
    const loginUser = assertRecord(session.user, "login user");
    assertUuid(loginUser.id, "login user id");
    assert(["owner", "admin"].includes(loginUser.role), "staging acceptance credentials must belong to an owner or admin");
    console.log("ok - owner login");

    const meResponse = await api.request("/api/v1/me", { token: accessToken });
    const me = assertRecord(meResponse.payload, "me response");
    assert(assertRecord(me.tenant, "me tenant").slug === config.tenantSlug, "me tenant slug does not match login input");
    assert(
      assertString(assertRecord(me.user, "me user").email, "me user email").toLowerCase() ===
        config.ownerEmail.toLowerCase(),
      "me user email does not match login input"
    );
    assert(me.user.id === session.user.id, "me user id does not match the login session");
    console.log("ok - authenticated identity");

    const conversation = await selectConversation(api, config, accessToken, runId);
    const conversationId = assertUuid(conversation.id, "conversation id");
    const latestSequence = Number.isInteger(conversation.latest_sequence) ? conversation.latest_sequence : 0;

    channel = new PhoenixChannel(config.socketUrl, accessToken, config.timeoutMs);
    await channel.connect();
    const join = await channel.join(`conversation:${conversationId}`, {
      protocol_version: 1,
      after_sequence: latestSequence,
      client_capabilities: ["message_revisions", "attachment_v2"]
    });
    assert(Array.isArray(join.messages), "Phoenix join response messages must be an array");
    assert(typeof join.has_more === "boolean", "Phoenix join response has_more must be boolean");
    console.log("ok - Phoenix WebSocket join");

    const commandId = `accept-${randomUUID()}`;
    const messageBody = `K-Comms staging acceptance ${runId}`;
    const envelope = commandEnvelope(commandId, "message.send.v1", {
      body: messageBody,
      attachment_ids: []
    });
    const firstMessage = assertMessage(await channel.push("command", envelope), "first message reply");
    const secondMessage = assertMessage(await channel.push("command", envelope), "duplicate message reply");
    assert(firstMessage.id === secondMessage.id, "duplicate command returned a different message id");
    assert(
      firstMessage.conversation_sequence === secondMessage.conversation_sequence,
      "duplicate command returned a different conversation sequence"
    );
    assert(firstMessage.client_message_id === commandId, "message did not retain the command id");
    assert(firstMessage.body === messageBody, "message body does not match the command");
    await channel.waitForEvent("message.created.v1", (payload) => payload?.id === firstMessage.id);
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 250));
    assert(
      channel.eventCount("message.created.v1", (payload) => payload?.id === firstMessage.id) === 1,
      "idempotent duplicate emitted more than one creation event"
    );
    console.log("ok - idempotent realtime send");

    const replayAfter = Math.max(firstMessage.conversation_sequence - 1, 0);
    const replayResponse = await api.request(
      `/api/v1/conversations/${conversationId}/messages?after_sequence=${replayAfter}&limit=200`,
      { token: accessToken }
    );
    const replay = assertRecord(replayResponse.payload, "REST replay");
    assert(Array.isArray(replay.data), "REST replay data must be an array");
    assert(
      replay.data.filter((message) => message?.id === firstMessage.id).length === 1,
      "REST replay did not contain exactly one canonical message"
    );

    await channel.close();
    channel = new PhoenixChannel(config.socketUrl, accessToken, config.timeoutMs);
    await channel.connect();
    const replayJoin = await channel.join(`conversation:${conversationId}`, {
      protocol_version: 1,
      after_sequence: replayAfter,
      client_capabilities: ["message_revisions", "attachment_v2"]
    });
    assert(Array.isArray(replayJoin.messages), "Phoenix replay messages must be an array");
    assert(
      replayJoin.messages.filter((message) => message?.id === firstMessage.id).length === 1,
      "Phoenix replay did not contain exactly one canonical message"
    );
    console.log("ok - durable REST and Phoenix replay");

    const attachmentBytes = Buffer.from(`K-Comms staging attachment ${runId}\n`, "utf8");
    const checksum = createHash("sha256").update(attachmentBytes).digest("hex");
    const fileName = `staging-acceptance-${runId}.txt`;
    const attachmentIntent = await api.request("/api/v1/attachments", {
      method: "POST",
      token: accessToken,
      expected: 201,
      body: {
        file_name: fileName,
        content_type: "text/plain",
        byte_size: attachmentBytes.length,
        checksum_sha256: checksum
      }
    });
    const intent = assertRecord(attachmentIntent.payload, "attachment intent");
    const attachmentId = assertUuid(assertRecord(intent.data, "attachment intent data").id, "attachment id");
    await fetchSigned(intent.upload, attachmentBytes, config.objectUrl, config.timeoutMs, "signed upload", fileName);

    const completedResponse = await api.request(`/api/v1/attachments/${attachmentId}/complete`, {
      method: "POST",
      token: accessToken,
      body: { checksum_sha256: checksum }
    });
    const completed = assertRecord(
      assertRecord(completedResponse.payload, "attachment completion").data,
      "completed attachment"
    );
    assert(completed.id === attachmentId, "completed attachment id changed");
    assert(completed.status === "ready", "completed attachment is not ready");
    assert(completed.checksum_sha256 === checksum, "completed attachment checksum changed");

    const downloadResponse = await api.request(`/api/v1/attachments/${attachmentId}`, { token: accessToken });
    const download = assertRecord(downloadResponse.payload, "attachment download response");
    assert(assertRecord(download.data, "download attachment").id === attachmentId, "download attachment id changed");
    const objectResponse = await fetchSigned(
      download.download,
      undefined,
      config.objectUrl,
      config.timeoutMs,
      "signed download",
      fileName
    );
    const downloadedBytes = Buffer.from(await objectResponse.arrayBuffer());
    assert(downloadedBytes.equals(attachmentBytes), "downloaded attachment bytes do not match the uploaded bytes");
    console.log("ok - signed attachment upload, verification, and download");

    assert(channel.isOpen(), "WebSocket closed before logout");
    const socketRevoked = channel.waitForClose();
    await api.request("/api/v1/sessions/current", { method: "DELETE", token: accessToken, expected: 204 });
    await socketRevoked;

    await api.request("/api/v1/me", { token: accessToken, expected: 401 });
    await api.request("/api/v1/sessions/refresh", {
      method: "POST",
      expected: 401,
      body: { refresh_token: refreshToken }
    });
    console.log("ok - logout and session revocation");
    console.log("PASS - K-Comms staging acceptance completed");
  } catch (error) {
    throw new AcceptanceError(redactText(error, [...sensitiveValues]));
  } finally {
    if (channel) await channel.close().catch(() => {});
  }
}

function printHelp() {
  console.log(`K-Comms staging acceptance (Node.js 22+, no package install required)

Required environment variables:
  K_COMMS_BASE_URL         Public application origin, for example https://comms.example.test
  K_COMMS_OBJECT_URL       Expected public object-storage origin
  K_COMMS_TENANT_SLUG      Existing staging tenant slug
  K_COMMS_OWNER_EMAIL      Existing staging owner email
  K_COMMS_OWNER_PASSWORD   Existing staging owner password

Optional environment variables:
  K_COMMS_CONVERSATION_ID  Existing conversation UUID; otherwise the first is used or one is created
  K_COMMS_SOCKET_URL       WebSocket endpoint ending in /socket or /socket/websocket
  K_COMMS_TIMEOUT_MS       Per-operation timeout, 1000-120000 (default 15000)

For private certificate authorities, use NODE_EXTRA_CA_CERTS rather than disabling TLS verification.
The runner never prints credentials, bearer tokens, refresh tokens, or signed object URLs.`);
}

const directlyInvoked = process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (directlyInvoked) {
  if (process.argv.includes("--help") || process.argv.includes("-h")) {
    printHelp();
  } else {
    runAcceptance().catch((error) => {
      console.error(`FAIL - ${redactText(error, [process.env.K_COMMS_OWNER_PASSWORD])}`);
      process.exitCode = 1;
    });
  }
}

export {
  AcceptanceError,
  assertSignedTarget,
  buildSocketUrl,
  readConfiguration,
  redactText,
  runAcceptance
};
