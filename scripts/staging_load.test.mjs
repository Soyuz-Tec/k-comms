import assert from "node:assert/strict";
import test from "node:test";

import {
  evaluateThresholds,
  percentile,
  readLoadConfiguration,
  redactLoadText
} from "./staging_load.mjs";

const required = {
  K_COMMS_BASE_URL: "https://comms.example.test",
  K_COMMS_TENANT_SLUG: "staging",
  K_COMMS_OWNER_EMAIL: "owner@example.test",
  K_COMMS_OWNER_PASSWORD: "correct horse battery staple"
};

test("readLoadConfiguration applies conservative bounded defaults", () => {
  const config = readLoadConfiguration(required);
  assert.equal(config.baseUrl.href, "https://comms.example.test/");
  assert.equal(config.messageCount, 30);
  assert.equal(config.concurrency, 3);
  assert.equal(config.durationSeconds, 10);
  assert.equal(config.duplicateProbes, 3);
  assert.equal(config.maximumP95Ms, null);
  assert.equal(config.requireZeroLoss, false);
  assert(config.worstCaseMs <= config.maxRunSeconds * 1_000);

  const single = readLoadConfiguration({ ...required, K_COMMS_LOAD_MESSAGES: "1" });
  assert.equal(single.concurrency, 1);
  assert.equal(single.duplicateProbes, 1);
});

test("readLoadConfiguration validates explicit thresholds and the total safety bound", () => {
  const config = readLoadConfiguration({
    ...required,
    K_COMMS_LOAD_MESSAGES: "300",
    K_COMMS_LOAD_CONCURRENCY: "6",
    K_COMMS_LOAD_DURATION_SECONDS: "60",
    K_COMMS_LOAD_DUPLICATE_PROBES: "10",
    K_COMMS_LOAD_MAX_RUN_SECONDS: "1800",
    K_COMMS_LOAD_MAX_P95_MS: "750",
    K_COMMS_LOAD_REQUIRE_ZERO_LOSS: "true"
  });
  assert.equal(config.maximumP95Ms, 750);
  assert.equal(config.requireZeroLoss, true);

  assert.throws(
    () => readLoadConfiguration({ ...required, K_COMMS_LOAD_CONCURRENCY: "31" }),
    /cannot exceed K_COMMS_LOAD_MESSAGES/
  );
  assert.throws(
    () => readLoadConfiguration({ ...required, K_COMMS_LOAD_REQUIRE_ZERO_LOSS: "yes" }),
    /must be true or false/
  );
  assert.throws(
    () => readLoadConfiguration({
      ...required,
      K_COMMS_LOAD_MESSAGES: "10000",
      K_COMMS_LOAD_CONCURRENCY: "1",
      K_COMMS_TIMEOUT_MS: "120000",
      K_COMMS_LOAD_MAX_RUN_SECONDS: "30"
    }),
    /exceed K_COMMS_LOAD_MAX_RUN_SECONDS/
  );
});

test("percentile uses deterministic nearest-rank calculations", () => {
  const values = [100, 20, 40, 60, 80];
  assert.equal(percentile(values, 50), 60);
  assert.equal(percentile(values, 95), 100);
  assert.equal(percentile(values, 99), 100);
  assert.equal(percentile([], 95), null);
  assert.throws(() => percentile(values, 101), /between 0 and 100/);
});

test("redactLoadText removes credentials, bearer tokens, signed query values, and bodies", () => {
  const password = "correct horse battery staple";
  const token = "header.payload.signature";
  const body = "K-Comms staging load private message";
  const redacted = redactLoadText(
    `Bearer ${token} {"password":"${password}","body":"${body}"} ` +
      "https://objects.example.test/key?X-Amz-Signature=signed-secret",
    [password, token, body]
  );
  assert(!redacted.includes(password));
  assert(!redacted.includes(token));
  assert(!redacted.includes(body));
  assert(!redacted.includes("signed-secret"));
  assert(redacted.includes("[REDACTED]"));
});

test("evaluateThresholds fails explicit p95 and zero-loss gates", () => {
  const summary = {
    failed: 1,
    latency_ms: { p95: 800 },
    idempotency: { failures: 0, not_probed: 0 },
    reconciliation: { ordered: true, unexpected: 0, duplicate_history_ids: 0, lost: 1 }
  };
  const thresholds = evaluateThresholds(summary, {
    maximumP95Ms: 750,
    requireZeroLoss: true
  });
  assert.equal(thresholds.passed, false);
  assert.deepEqual(thresholds.failures, ["p95_threshold_exceeded", "zero_loss_threshold_failed"]);
});
