import assert from "node:assert/strict";
import test from "node:test";

import {
  SOCKET_STORM_SIZE,
  assertBoundedAuditCsv,
  assertSafeProjection,
  exactById,
  fakePushSubscription,
  parseBoundedInteger,
  readProductConfiguration,
  syntheticResources
} from "./staging_product_acceptance.mjs";

const required = {
  K_COMMS_BASE_URL: "https://comms.example.test",
  K_COMMS_OBJECT_URL: "https://objects.example.test/storage",
  K_COMMS_TENANT_SLUG: "staging",
  K_COMMS_OWNER_EMAIL: "owner@example.test",
  K_COMMS_OWNER_PASSWORD: "correct horse battery staple"
};

const runId = "018f1010-7b3a-7d90-a283-9f31f65f6a10";

test("readProductConfiguration forces run-scoped conversations and bounded defaults", () => {
  const config = readProductConfiguration({
    ...required,
    K_COMMS_CONVERSATION_ID: "this-must-never-be-reused",
    K_COMMS_ATTACHMENT_BYTES: "25000000"
  });

  assert.equal(config.conversationId, null);
  assert.equal(config.workerTimeoutMs, 60_000);
  assert.equal(config.socketStormSize, 12);
  assert.equal(config.socketStormSize, SOCKET_STORM_SIZE);
  assert.equal(config.attachmentByteSize, 25_000_000);

  assert.equal(
    readProductConfiguration({
      ...required,
      K_COMMS_PRODUCT_WORKER_TIMEOUT_MS: "180000"
    }).workerTimeoutMs,
    180_000
  );
  assert.throws(
    () =>
      readProductConfiguration({
        ...required,
        K_COMMS_PRODUCT_WORKER_TIMEOUT_MS: "4999"
      }),
    /K_COMMS_PRODUCT_WORKER_TIMEOUT_MS/
  );
  assert.throws(
    () =>
      readProductConfiguration({
        ...required,
        K_COMMS_PRODUCT_WORKER_TIMEOUT_MS: "180001"
      }),
    /K_COMMS_PRODUCT_WORKER_TIMEOUT_MS/
  );
});

test("syntheticResources scopes every mutable value to the qualification run", () => {
  const resources = syntheticResources(runId);

  for (const [name, value] of Object.entries(resources)) {
    assert.equal(typeof value, "string", `${name} must be a string`);
    assert(value.includes(runId), `${name} must include the qualification run id`);
  }
  assert(resources.memberEmail.endsWith("@example.test"));
  assert(resources.memberPassword.length >= 16);
});

test("fakePushSubscription produces structurally valid synthetic browser keys", () => {
  const subscription = fakePushSubscription(runId, (length) => Buffer.alloc(length, 0xab));
  const publicKey = Buffer.from(subscription.keys.p256dh, "base64url");
  const authSecret = Buffer.from(subscription.keys.auth, "base64url");

  assert.equal(subscription.endpoint, `https://push.invalid/k-comms/${runId}`);
  assert.equal(subscription.expiration_time, null);
  assert.equal(publicKey.length, 65);
  assert.equal(publicKey[0], 4);
  assert(publicKey.subarray(1).equals(Buffer.alloc(64, 0xab)));
  assert(authSecret.equals(Buffer.alloc(16, 0xab)));
  assert(!subscription.keys.p256dh.includes("="));
  assert(!subscription.keys.auth.includes("="));
});

test("assertSafeProjection rejects secret fields and protected values recursively", () => {
  const safe = [{ id: runId, destination_hint: null, nested: { status: "delivered" } }];
  assert.equal(assertSafeProjection(safe, "safe projection", ["never-show-this"]), safe);

  assert.throws(
    () => assertSafeProjection({ nested: { credential: "redacted" } }, "credential projection"),
    /forbidden field credential/
  );
  assert.throws(
    () =>
      assertSafeProjection(
        { nested: { display_name: "prefix never-show-this suffix" } },
        "value projection",
        ["never-show-this"]
      ),
    /protected value/
  );
});

test("exactById requires one and only one exact synthetic record", () => {
  const values = [{ id: runId }, { id: "018f1010-7b3a-7d90-a283-9f31f65f6a11" }];
  assert.equal(exactById(values, runId, "records"), values[0]);
  assert.throws(() => exactById([], runId, "records"), /exactly one expected id/);
  assert.throws(
    () => exactById([{ id: runId }, { id: runId }], runId, "records"),
    /exactly one expected id/
  );
});

test("assertBoundedAuditCsv enforces format, row, size, identity, and redaction bounds", () => {
  const csv = `id,resource_id,action\r\naudit-1,${runId},service_account.create\r\n`;
  const response = {
    payload: csv,
    response: {
      headers: new Headers({
        "content-type": "text/csv; charset=utf-8",
        "x-export-row-count": "1",
        "x-export-truncated": "false"
      })
    }
  };

  assert.equal(assertBoundedAuditCsv(response, runId, ["never-show-this"], 10), csv);

  const truncated = {
    ...response,
    response: { headers: new Headers(response.response.headers) }
  };
  truncated.response.headers.set("x-export-truncated", "true");
  assert.throws(() => assertBoundedAuditCsv(truncated, runId, [], 10), /unexpectedly truncated/);

  assert.throws(
    () =>
      assertBoundedAuditCsv(
        { ...response, payload: `${csv}audit-2,${runId},never-show-this\r\n` },
        runId,
        ["never-show-this"],
        10
      ),
    /protected value/
  );
});

test("parseBoundedInteger accepts only whole values inside the declared interval", () => {
  assert.equal(parseBoundedInteger(undefined, "BOUND", 7, 5, 10), 7);
  assert.equal(parseBoundedInteger("10", "BOUND", 7, 5, 10), 10);
  assert.throws(() => parseBoundedInteger("4", "BOUND", 7, 5, 10), /BOUND/);
  assert.throws(() => parseBoundedInteger("10.5", "BOUND", 7, 5, 10), /BOUND/);
});
