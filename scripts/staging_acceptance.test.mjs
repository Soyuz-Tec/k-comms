import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";

import {
  AcceptanceError,
  assertSignedTarget,
  attachmentEnteredSafetyWorkflow,
  buildSocketUrl,
  cleanupSyntheticResources,
  createSyntheticConversation,
  createSafeLogger,
  isDirectInvocation,
  pollUntil,
  readConfiguration,
  redactText
} from "./staging_acceptance.mjs";

test("attachment completion accepts every safe asynchronous pipeline state", () => {
  assert.equal(attachmentEnteredSafetyWorkflow("uploaded"), true);
  assert.equal(attachmentEnteredSafetyWorkflow("quarantined"), true);
  assert.equal(attachmentEnteredSafetyWorkflow("ready"), true);
  assert.equal(attachmentEnteredSafetyWorkflow("pending"), false);
  assert.equal(attachmentEnteredSafetyWorkflow("deleted"), false);
});

test("isDirectInvocation resolves Kubernetes ConfigMap symlinks", () => {
  const targetPath = resolve("mounted", "..data", "staging_acceptance.mjs");
  const linkPath = resolve("mounted", "staging_acceptance.mjs");
  const realpath = (path) => (path === linkPath ? targetPath : path);

  assert.equal(isDirectInvocation(pathToFileURL(targetPath).href, linkPath, realpath), true);
  assert.equal(isDirectInvocation(pathToFileURL(targetPath).href, undefined, realpath), false);
});

test("buildSocketUrl derives the Phoenix V2 WebSocket endpoint", () => {
  assert.equal(
    buildSocketUrl(new URL("https://comms.example.test"), undefined).href,
    "wss://comms.example.test/socket/websocket"
  );
  assert.equal(
    buildSocketUrl(new URL("http://comms.example.test"), "http://socket.example.test/socket").href,
    "ws://socket.example.test/socket/websocket"
  );
});

test("assertSignedTarget accepts only the configured object origin and path", () => {
  const objectUrl = new URL("https://objects.example.test/storage");
  assert.equal(
    assertSignedTarget(
      "https://objects.example.test/storage/bucket/key?X-Amz-Signature=secret",
      objectUrl,
      "upload"
    ).pathname,
    "/storage/bucket/key"
  );
  assert.throws(
    () => assertSignedTarget("https://attacker.example.test/storage/key", objectUrl, "upload"),
    AcceptanceError
  );
  assert.throws(
    () => assertSignedTarget("https://objects.example.test/outside/key", objectUrl, "upload"),
    AcceptanceError
  );
});

test("readConfiguration rejects missing credentials and never accepts an existing conversation", () => {
  assert.throws(() => readConfiguration({}), /K_COMMS_BASE_URL/);

  const valid = {
    K_COMMS_BASE_URL: "https://comms.example.test",
    K_COMMS_OBJECT_URL: "https://objects.example.test",
    K_COMMS_TENANT_SLUG: "staging",
    K_COMMS_OWNER_EMAIL: "owner@example.test",
    K_COMMS_OWNER_PASSWORD: "not-printed"
  };
  assert.equal(
    readConfiguration({
      ...valid,
      K_COMMS_CONVERSATION_ID: "018f1010-7b3a-7d90-a283-9f31f65f6a10"
    }).conversationId,
    null
  );
  assert.equal(readConfiguration({ ...valid, K_COMMS_ATTACHMENT_BYTES: "25000000" }).attachmentByteSize, 25_000_000);
  assert.throws(
    () => readConfiguration({ ...valid, K_COMMS_ATTACHMENT_BYTES: "25000001" }),
    /K_COMMS_ATTACHMENT_BYTES/
  );
  assert.throws(
    () => readConfiguration({ ...valid, K_COMMS_ATTACHMENT_BYTES: "25MB" }),
    /K_COMMS_ATTACHMENT_BYTES/
  );
  assert.throws(
    () => readConfiguration({ ...valid, K_COMMS_ATTACHMENT_BYTES: "1.5" }),
    /K_COMMS_ATTACHMENT_BYTES/
  );
});

test("redactText removes credentials and signed query values", () => {
  const redacted = redactText(
    "password=top-secret https://objects.example.test/key?X-Amz-Signature=signed-secret&token=access-secret",
    ["top-secret", "access-secret"]
  );
  assert(!redacted.includes("top-secret"));
  assert(!redacted.includes("signed-secret"));
  assert(!redacted.includes("access-secret"));
  assert(redacted.includes("[REDACTED]"));
});

test("pollUntil is bounded and returns only after the durable predicate matches", async () => {
  let attempts = 0;
  const value = await pollUntil(
    "durable test state",
    async () => {
      attempts += 1;
      return attempts;
    },
    (candidate) => candidate === 3,
    { timeoutMs: 100, intervalMs: 1 }
  );

  assert.equal(value, 3);
  assert.equal(attempts, 3);
  await assert.rejects(
    pollUntil("missing durable state", async () => false, Boolean, {
      timeoutMs: 5,
      intervalMs: 1
    }),
    /before timeout/
  );
});

test("createSafeLogger redacts credentials and signed query values before writing", () => {
  const lines = [];
  const sink = {
    log(value) {
      lines.push(value);
    },
    error(value) {
      lines.push(value);
    }
  };
  const logger = createSafeLogger(["never-show-this"], sink);

  logger.ok("password=never-show-this");
  logger.info("https://objects.example.test/key?X-Amz-Signature=signed-secret");
  logger.fail(new Error("Bearer never-show-this"));

  assert.equal(lines.length, 3);
  assert(!lines.join("\n").includes("never-show-this"));
  assert(!lines.join("\n").includes("signed-secret"));
  assert(lines.join("\n").includes("[REDACTED]"));
});

test("createSyntheticConversation only creates a UUID-scoped private conversation", async () => {
  const runId = "018f1010-7b3a-7d90-a283-9f31f65f6a10";
  const conversationId = "018f1010-7b3a-7d90-a283-9f31f65f6a11";
  const calls = [];
  const api = {
    async request(path, options) {
      calls.push({ path, options });
      assert.equal(path, "/api/v1/conversations");
      assert.equal(options.method, "POST");
      assert.equal(options.body.title, `Staging acceptance ${runId}`);
      assert.equal(options.body.kind, "group");
      assert.equal(options.body.visibility, "private");
      assert.deepEqual(options.body.member_ids, []);
      return { payload: { data: { id: conversationId, version: 1, latest_sequence: 0 } } };
    }
  };

  const conversation = await createSyntheticConversation(api, "access-token", runId);
  assert.equal(conversation.id, conversationId);
  assert.equal(calls.length, 1);
  assert(!calls.some((call) => call.options?.method === undefined), "existing conversations must never be listed");
});

test("cleanup archives and deletes only the tracked conversation before revoking the tracked device", async () => {
  const runId = "018f1010-7b3a-7d90-a283-9f31f65f6a10";
  const conversationId = "018f1010-7b3a-7d90-a283-9f31f65f6a11";
  const deviceId = "018f1010-7b3a-7d90-a283-9f31f65f6a12";
  const requestId = "018f1010-7b3a-7d90-a283-9f31f65f6a13";
  const calls = [];
  let channelClosed = false;
  const api = {
    async request(path, options = {}) {
      calls.push({ path, options });
      if (path === `/api/v1/conversations/${conversationId}/archive`) return { payload: { data: {} } };
      if (path === "/api/v1/me/step-up") return { payload: { data: { step_up_at: new Date().toISOString() } } };
      if (path === "/api/v1/admin/deletion-requests" && options.method === "POST") {
        assert.equal(options.body.conversation_id, conversationId);
        return { payload: { data: { id: requestId, version: 1 } } };
      }
      if (path === `/api/v1/admin/deletion-requests/${requestId}`) return { payload: { data: {} } };
      if (path.startsWith("/api/v1/admin/deletion-requests?")) {
        return { payload: { data: [{ id: requestId, status: "completed" }] } };
      }
      if (path === `/api/v1/me/devices/${deviceId}`) return { payload: null };
      throw new Error(`unexpected request ${path}`);
    }
  };
  const state = {
    accessToken: "access-token",
    deviceId,
    conversation: { id: conversationId, version: 1 },
    channel: {
      isOpen: () => true,
      waitForClose: async () => {},
      close: async () => {
        channelClosed = true;
      }
    }
  };

  const result = await cleanupSyntheticResources(
    api,
    { ownerPassword: "not-printed", timeoutMs: 50 },
    state,
    runId
  );

  assert.deepEqual(result.errors, []);
  assert.equal(result.conversationArchived, true);
  assert.equal(result.conversationDeleted, true);
  assert.equal(result.deviceRevoked, true);
  assert.equal(result.socketRevoked, true);
  assert.equal(channelClosed, true);
  assert(!calls.some((call) => call.path === "/api/v1/conversations"));
  assert(!calls.some((call) => call.path === "/api/v1/sessions/current"));
});

test("cleanup continues deletion and device revocation after an archive failure", async () => {
  const runId = "018f1010-7b3a-7d90-a283-9f31f65f6a10";
  const conversationId = "018f1010-7b3a-7d90-a283-9f31f65f6a11";
  const deviceId = "018f1010-7b3a-7d90-a283-9f31f65f6a12";
  const requestId = "018f1010-7b3a-7d90-a283-9f31f65f6a13";
  const calls = [];
  const api = {
    async request(path, options = {}) {
      calls.push(path);
      if (path === `/api/v1/conversations/${conversationId}/archive`) throw new Error("archive unavailable");
      if (path === "/api/v1/me/step-up") return { payload: { data: { step_up_at: new Date().toISOString() } } };
      if (path === "/api/v1/admin/deletion-requests" && options.method === "POST") {
        return { payload: { data: { id: requestId, version: 1 } } };
      }
      if (path === `/api/v1/admin/deletion-requests/${requestId}`) return { payload: { data: {} } };
      if (path.startsWith("/api/v1/admin/deletion-requests?")) {
        return { payload: { data: [{ id: requestId, status: "completed" }] } };
      }
      if (path === `/api/v1/me/devices/${deviceId}`) return { payload: null };
      throw new Error(`unexpected request ${path}`);
    }
  };

  const result = await cleanupSyntheticResources(
    api,
    { ownerPassword: "not-printed", timeoutMs: 50 },
    {
      accessToken: "access-token",
      deviceId,
      conversation: { id: conversationId, version: 1 },
      channel: null
    },
    runId
  );

  assert.deepEqual(result.errors, ["conversation archive"]);
  assert.equal(result.conversationDeleted, true);
  assert.equal(result.deviceRevoked, true);
  assert(calls.includes(`/api/v1/me/devices/${deviceId}`));
});

test("cleanup logs out the run session when exact device revocation fails", async () => {
  const runId = "018f1010-7b3a-7d90-a283-9f31f65f6a10";
  const deviceId = "018f1010-7b3a-7d90-a283-9f31f65f6a12";
  const calls = [];
  const api = {
    async request(path) {
      calls.push(path);
      if (path === `/api/v1/me/devices/${deviceId}`) throw new Error("device endpoint unavailable");
      if (path === "/api/v1/sessions/current") return { payload: null };
      throw new Error(`unexpected request ${path}`);
    }
  };

  const result = await cleanupSyntheticResources(
    api,
    { ownerPassword: "not-printed", timeoutMs: 50 },
    { accessToken: "access-token", deviceId, conversation: null, channel: null },
    runId
  );

  assert.deepEqual(result.errors, ["run device revocation"]);
  assert.equal(result.deviceRevoked, false);
  assert.equal(result.sessionLoggedOut, true);
  assert.deepEqual(calls, [`/api/v1/me/devices/${deviceId}`, "/api/v1/sessions/current"]);
});
