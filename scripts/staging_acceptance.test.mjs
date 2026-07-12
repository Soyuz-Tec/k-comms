import assert from "node:assert/strict";
import { resolve } from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";

import {
  AcceptanceError,
  assertSignedTarget,
  buildSocketUrl,
  isDirectInvocation,
  readConfiguration,
  redactText
} from "./staging_acceptance.mjs";

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

test("readConfiguration rejects missing credentials and malformed conversation ids", () => {
  assert.throws(() => readConfiguration({}), /K_COMMS_BASE_URL/);
  assert.throws(
    () =>
      readConfiguration({
        K_COMMS_BASE_URL: "https://comms.example.test",
        K_COMMS_OBJECT_URL: "https://objects.example.test",
        K_COMMS_TENANT_SLUG: "staging",
        K_COMMS_OWNER_EMAIL: "owner@example.test",
        K_COMMS_OWNER_PASSWORD: "not-printed",
        K_COMMS_CONVERSATION_ID: "invalid"
      }),
    /must be a UUID/
  );

  const valid = {
    K_COMMS_BASE_URL: "https://comms.example.test",
    K_COMMS_OBJECT_URL: "https://objects.example.test",
    K_COMMS_TENANT_SLUG: "staging",
    K_COMMS_OWNER_EMAIL: "owner@example.test",
    K_COMMS_OWNER_PASSWORD: "not-printed"
  };
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
