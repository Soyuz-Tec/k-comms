#!/usr/bin/env node

import { randomUUID } from "node:crypto";
import process from "node:process";

import {
  AcceptanceError,
  ApiClient,
  assertMessage,
  assertNoSensitiveValues,
  assertRecord,
  assertString,
  assertUuid,
  isDirectInvocation,
  redactText
} from "./staging_acceptance.mjs";

const DEFAULT_MESSAGES = 30;
const DEFAULT_CONCURRENCY = 3;
const DEFAULT_DURATION_SECONDS = 10;
const DEFAULT_TIMEOUT_MS = 15_000;
const DEFAULT_MAX_RUN_SECONDS = 600;
const HISTORY_PAGE_SIZE = 200;

function assert(condition, message) {
  if (!condition) throw new AcceptanceError(message);
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

function boundedInteger(value, name, defaultValue, minimum, maximum) {
  if (value === undefined || value === null || String(value).trim() === "") return defaultValue;
  const parsed = Number(value);
  assert(
    Number.isInteger(parsed) && parsed >= minimum && parsed <= maximum,
    `${name} must be an integer between ${minimum} and ${maximum}`
  );
  return parsed;
}

function optionalInteger(value, name, minimum, maximum) {
  if (value === undefined || value === null || String(value).trim() === "") return null;
  return boundedInteger(value, name, null, minimum, maximum);
}

function booleanValue(value, name, defaultValue) {
  if (value === undefined || value === null || String(value).trim() === "") return defaultValue;
  const normalized = String(value).trim().toLowerCase();
  assert(["true", "false"].includes(normalized), `${name} must be true or false`);
  return normalized === "true";
}

function readLoadConfiguration(env = process.env) {
  const messageCount = boundedInteger(
    env.K_COMMS_LOAD_MESSAGES,
    "K_COMMS_LOAD_MESSAGES",
    DEFAULT_MESSAGES,
    1,
    10_000
  );
  const concurrency = boundedInteger(
    env.K_COMMS_LOAD_CONCURRENCY,
    "K_COMMS_LOAD_CONCURRENCY",
    Math.min(DEFAULT_CONCURRENCY, messageCount),
    1,
    64
  );
  assert(concurrency <= messageCount, "K_COMMS_LOAD_CONCURRENCY cannot exceed K_COMMS_LOAD_MESSAGES");

  const configuredDuplicateProbes = env.K_COMMS_LOAD_DUPLICATE_PROBES;
  const duplicateProbes = boundedInteger(
    configuredDuplicateProbes,
    "K_COMMS_LOAD_DUPLICATE_PROBES",
    Math.min(3, messageCount),
    0,
    100
  );
  assert(duplicateProbes <= messageCount, "K_COMMS_LOAD_DUPLICATE_PROBES cannot exceed K_COMMS_LOAD_MESSAGES");

  const durationSeconds = boundedInteger(
    env.K_COMMS_LOAD_DURATION_SECONDS,
    "K_COMMS_LOAD_DURATION_SECONDS",
    DEFAULT_DURATION_SECONDS,
    0,
    3_600
  );
  const timeoutMs = boundedInteger(
    env.K_COMMS_TIMEOUT_MS,
    "K_COMMS_TIMEOUT_MS",
    DEFAULT_TIMEOUT_MS,
    1_000,
    120_000
  );
  const maxRunSeconds = boundedInteger(
    env.K_COMMS_LOAD_MAX_RUN_SECONDS,
    "K_COMMS_LOAD_MAX_RUN_SECONDS",
    DEFAULT_MAX_RUN_SECONDS,
    30,
    21_600
  );
  const maximumP95Ms = optionalInteger(
    env.K_COMMS_LOAD_MAX_P95_MS,
    "K_COMMS_LOAD_MAX_P95_MS",
    1,
    120_000
  );
  const requireZeroLoss = booleanValue(
    env.K_COMMS_LOAD_REQUIRE_ZERO_LOSS,
    "K_COMMS_LOAD_REQUIRE_ZERO_LOSS",
    false
  );

  const sequentialRequestRounds =
    Math.ceil(messageCount / concurrency) +
    duplicateProbes +
    Math.ceil(messageCount / HISTORY_PAGE_SIZE) +
    12;
  const worstCaseMs = durationSeconds * 1_000 + sequentialRequestRounds * timeoutMs;
  assert(
    worstCaseMs <= maxRunSeconds * 1_000,
    "Configured message count, concurrency, duration, and timeout exceed K_COMMS_LOAD_MAX_RUN_SECONDS"
  );

  return {
    baseUrl: parseHttpUrl(requiredEnv(env, "K_COMMS_BASE_URL"), "K_COMMS_BASE_URL"),
    tenantSlug: requiredEnv(env, "K_COMMS_TENANT_SLUG"),
    ownerEmail: requiredEnv(env, "K_COMMS_OWNER_EMAIL"),
    ownerPassword: requiredEnv(env, "K_COMMS_OWNER_PASSWORD"),
    messageCount,
    concurrency,
    duplicateProbes,
    durationSeconds,
    timeoutMs,
    maxRunSeconds,
    maximumP95Ms,
    requireZeroLoss,
    worstCaseMs
  };
}

function percentile(values, percentage) {
  assert(Number.isFinite(percentage) && percentage >= 0 && percentage <= 100, "percentile must be between 0 and 100");
  const sorted = values.filter((value) => Number.isFinite(value) && value >= 0).sort((left, right) => left - right);
  if (sorted.length === 0) return null;
  const rank = Math.max(0, Math.ceil((percentage / 100) * sorted.length) - 1);
  return sorted[rank];
}

function redactLoadText(value, secrets = []) {
  return redactText(value, secrets)
    .replace(/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/gi, "Bearer [REDACTED]")
    .replace(/("(?:body|password|access_token|refresh_token|socket_ticket)"\s*:\s*)"[^"]*"/gi, '$1"[REDACTED]"')
    .replace(/((?:password|access_token|refresh_token|socket_ticket)\s*=\s*)[^\s&,}]+/gi, "$1[REDACTED]")
    .slice(0, 1_000);
}

function round(value, digits = 2) {
  if (value === null || !Number.isFinite(value)) return null;
  const scale = 10 ** digits;
  return Math.round(value * scale) / scale;
}

function delay(milliseconds) {
  if (milliseconds <= 0) return Promise.resolve();
  return new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));
}

async function createRunConversation(api, token, runId) {
  const response = await api.request("/api/v1/conversations", {
    method: "POST",
    token,
    expected: 201,
    body: {
      title: `Staging load ${runId}`,
      kind: "group",
      visibility: "private",
      member_ids: []
    }
  });
  const conversation = assertRecord(assertRecord(response.payload, "conversation response").data, "conversation");
  assertUuid(conversation.id, "conversation id");
  assert(Number.isInteger(conversation.version) && conversation.version > 0, "conversation version must be positive");
  return conversation;
}

async function sendMessages(api, token, conversationId, runId, config, sensitiveValues) {
  const results = new Array(config.messageCount);
  const startedAt = performance.now();
  let nextIndex = 0;

  async function worker() {
    while (true) {
      const index = nextIndex;
      nextIndex += 1;
      if (index >= config.messageCount) return;

      if (config.durationSeconds > 0 && config.messageCount > 1) {
        const scheduledAt = startedAt + (config.durationSeconds * 1_000 * index) / (config.messageCount - 1);
        await delay(scheduledAt - performance.now());
      }

      const idempotencyKey = `load-${runId}-${String(index + 1).padStart(5, "0")}`;
      const body = `K-Comms staging load ${runId} message ${index + 1}`;
      sensitiveValues.add(body);
      const requestStartedAt = performance.now();

      try {
        const response = await api.request(`/api/v1/conversations/${conversationId}/messages`, {
          method: "POST",
          token,
          expected: 201,
          headers: { "Idempotency-Key": idempotencyKey },
          body: { body, attachment_ids: [] }
        });
        const message = assertMessage(
          assertRecord(assertRecord(response.payload, "message response").data, "message"),
          "message"
        );
        assert(message.client_message_id === idempotencyKey, "message response changed the idempotency key");
        assert(message.conversation_id === conversationId, "message response changed the conversation id");
        results[index] = {
          ok: true,
          index,
          idempotencyKey,
          body,
          message,
          latencyMs: performance.now() - requestStartedAt
        };
      } catch {
        results[index] = {
          ok: false,
          index,
          idempotencyKey,
          body,
          latencyMs: performance.now() - requestStartedAt
        };
      }
    }
  }

  await Promise.all(Array.from({ length: config.concurrency }, () => worker()));
  return { results, elapsedMs: performance.now() - startedAt };
}

async function probeDuplicates(api, token, conversationId, successful, requestedProbeCount) {
  let matches = 0;
  let failures = 0;
  const probes = successful.slice(0, requestedProbeCount);

  for (const original of probes) {
    try {
      const response = await api.request(`/api/v1/conversations/${conversationId}/messages`, {
        method: "POST",
        token,
        expected: [200, 201],
        headers: { "Idempotency-Key": original.idempotencyKey },
        body: { body: original.body, attachment_ids: [] }
      });
      const duplicate = assertMessage(
        assertRecord(assertRecord(response.payload, "duplicate response").data, "duplicate message"),
        "duplicate message"
      );
      if (
        duplicate.id === original.message.id &&
        duplicate.conversation_sequence === original.message.conversation_sequence
      ) {
        matches += 1;
      } else {
        failures += 1;
      }
    } catch {
      failures += 1;
    }
  }

  return {
    requested: requestedProbeCount,
    attempted: probes.length,
    matches,
    failures,
    not_probed: requestedProbeCount - probes.length
  };
}

async function reconcileHistory(api, token, conversationId, afterSequence, maximumExpected) {
  const messages = [];
  let cursor = afterSequence;
  let ordered = true;
  let previousSequence = afterSequence;
  const maximumPages = Math.ceil(maximumExpected / HISTORY_PAGE_SIZE) + 2;

  for (let pageNumber = 0; pageNumber < maximumPages; pageNumber += 1) {
    const response = await api.request(
      `/api/v1/conversations/${conversationId}/messages?after_sequence=${cursor}&limit=${HISTORY_PAGE_SIZE}`,
      { token }
    );
    const payload = assertRecord(response.payload, "history response");
    assert(Array.isArray(payload.data), "history response data must be an array");
    const page = payload.data.map((message, index) => assertMessage(message, `history message ${index}`));

    for (const message of page) {
      if (message.conversation_sequence <= previousSequence) ordered = false;
      previousSequence = message.conversation_sequence;
      messages.push(message);
    }

    const pageInfo = assertRecord(payload.page, "history page");
    if (pageInfo.has_more !== true) return { messages, ordered };
    assert(
      Number.isInteger(pageInfo.next_after_sequence) && pageInfo.next_after_sequence > cursor,
      "history cursor did not advance"
    );
    cursor = pageInfo.next_after_sequence;
  }

  throw new AcceptanceError("history reconciliation exceeded its bounded page count");
}

function summarize(config, sendResult, idempotency, historyResult) {
  const successful = sendResult.results.filter((result) => result?.ok === true);
  const failed = config.messageCount - successful.length;
  const latencies = successful.map((result) => result.latencyMs);
  const expectedIds = new Set(successful.map((result) => result.message.id));
  const historyIds = historyResult.messages.map((message) => message.id);
  const uniqueHistoryIds = new Set(historyIds);
  const foundIds = new Set(historyIds.filter((id) => expectedIds.has(id)));
  const lost = [...expectedIds].filter((id) => !foundIds.has(id)).length;
  const unexpected = [...uniqueHistoryIds].filter((id) => !expectedIds.has(id)).length;

  return {
    profile: {
      messages: config.messageCount,
      concurrency: config.concurrency,
      duration_seconds: config.durationSeconds,
      duplicate_probes: config.duplicateProbes,
      timeout_ms: config.timeoutMs,
      max_run_seconds: config.maxRunSeconds
    },
    attempts: config.messageCount,
    successful: successful.length,
    failed,
    error_rate_percent: round((failed / config.messageCount) * 100, 4),
    elapsed_ms: round(sendResult.elapsedMs),
    throughput_messages_per_second: round(successful.length / Math.max(sendResult.elapsedMs / 1_000, 0.001)),
    latency_ms: {
      p50: round(percentile(latencies, 50)),
      p95: round(percentile(latencies, 95)),
      p99: round(percentile(latencies, 99)),
      minimum: round(latencies.length > 0 ? Math.min(...latencies) : null),
      maximum: round(latencies.length > 0 ? Math.max(...latencies) : null)
    },
    idempotency,
    reconciliation: {
      expected: expectedIds.size,
      found: foundIds.size,
      lost,
      unexpected,
      duplicate_history_ids: historyIds.length - uniqueHistoryIds.size,
      ordered: historyResult.ordered
    }
  };
}

function evaluateThresholds(summary, config) {
  const failures = [];
  if (!summary.reconciliation.ordered) failures.push("history_not_ordered");
  if (summary.reconciliation.unexpected > 0) failures.push("unexpected_history_records");
  if (summary.reconciliation.duplicate_history_ids > 0) failures.push("duplicate_history_records");
  if (summary.idempotency.failures > 0 || summary.idempotency.not_probed > 0) {
    failures.push("idempotency_probe_failed");
  }
  if (
    config.maximumP95Ms !== null &&
    (summary.latency_ms.p95 === null || summary.latency_ms.p95 > config.maximumP95Ms)
  ) {
    failures.push("p95_threshold_exceeded");
  }
  if (
    config.requireZeroLoss &&
    (summary.failed > 0 || summary.reconciliation.lost > 0)
  ) {
    failures.push("zero_loss_threshold_failed");
  }

  return {
    maximum_p95_ms: config.maximumP95Ms,
    require_zero_loss: config.requireZeroLoss,
    passed: failures.length === 0,
    failures
  };
}

async function cleanupResources(api, state) {
  const cleanup = {
    conversation_archived: false,
    device_revoked: false,
    session_logged_out: false,
    warnings: [],
    issues: []
  };
  if (!state.token) return cleanup;

  if (state.conversationId) {
    try {
      const response = await api.request(`/api/v1/conversations/${state.conversationId}`, {
        token: state.token
      });
      const conversation = assertRecord(
        assertRecord(response.payload, "cleanup conversation response").data,
        "cleanup conversation"
      );
      if (conversation.archived_at) {
        cleanup.conversation_archived = true;
      } else {
        await api.request(`/api/v1/conversations/${state.conversationId}/archive`, {
          method: "POST",
          token: state.token,
          body: { version: conversation.version }
        });
        cleanup.conversation_archived = true;
      }
    } catch {
      cleanup.issues.push("conversation_archive_failed");
    }
  }

  if (state.deviceId) {
    try {
      await api.request(`/api/v1/me/devices/${state.deviceId}`, {
        method: "DELETE",
        token: state.token,
        expected: 204
      });
      cleanup.device_revoked = true;
      return cleanup;
    } catch {
      cleanup.warnings.push("device_revoke_failed_using_logout_fallback");
    }
  }

  try {
    await api.request("/api/v1/sessions/current", {
      method: "DELETE",
      token: state.token,
      expected: 204
    });
    cleanup.session_logged_out = true;
  } catch {
    cleanup.issues.push("authentication_cleanup_failed");
  }
  return cleanup;
}

async function runStagingLoad(env = process.env, logger = console) {
  const config = readLoadConfiguration(env);
  const sensitiveValues = new Set([config.ownerPassword]);
  const api = new ApiClient(config.baseUrl, config.timeoutMs);
  const state = { token: null, deviceId: null, conversationId: null };
  const runId = randomUUID();
  let summary = null;
  let primaryError = null;
  let cleanup;

  logger.log(
    `START - staging load messages=${config.messageCount} concurrency=${config.concurrency} duration_seconds=${config.durationSeconds}`
  );

  try {
    await api.request("/health/ready");
    const login = await api.request("/api/v1/sessions", {
      method: "POST",
      body: {
        tenant_slug: config.tenantSlug,
        email: config.ownerEmail,
        password: config.ownerPassword,
        device: { name: `staging-load-${runId.slice(0, 8)}`, platform: "web" }
      }
    });
    const session = assertRecord(login.payload, "login response");
    state.token = assertString(session.access_token, "access token");
    sensitiveValues.add(state.token);
    if (typeof session.refresh_token === "string") sensitiveValues.add(session.refresh_token);
    const user = assertRecord(session.user, "login user");
    assert(["owner", "admin"].includes(user.role), "load credentials must belong to an owner or admin");
    state.deviceId = assertUuid(assertRecord(session.device, "login device").id, "login device id");

    const conversation = await createRunConversation(api, state.token, runId);
    state.conversationId = conversation.id;
    const baselineSequence = Number.isInteger(conversation.latest_sequence)
      ? conversation.latest_sequence
      : 0;

    const sendResult = await sendMessages(
      api,
      state.token,
      state.conversationId,
      runId,
      config,
      sensitiveValues
    );
    const successful = sendResult.results.filter((result) => result?.ok === true);
    const idempotency = await probeDuplicates(
      api,
      state.token,
      state.conversationId,
      successful,
      config.duplicateProbes
    );
    const historyResult = await reconcileHistory(
      api,
      state.token,
      state.conversationId,
      baselineSequence,
      config.messageCount
    );
    summary = summarize(config, sendResult, idempotency, historyResult);
    summary.thresholds = evaluateThresholds(summary, config);
  } catch (error) {
    primaryError = error;
  } finally {
    cleanup = await cleanupResources(api, state);
  }

  if (summary) {
    summary.cleanup = cleanup;
    assertNoSensitiveValues(summary, sensitiveValues, "load qualification summary");
    logger.log(`RESULT ${JSON.stringify(summary)}`);
  } else {
    assertNoSensitiveValues(cleanup, sensitiveValues, "load qualification cleanup");
    logger.log(`CLEANUP ${JSON.stringify(cleanup)}`);
  }

  if (primaryError) {
    throw new AcceptanceError(redactLoadText(primaryError, [...sensitiveValues]));
  }
  if (!summary.thresholds.passed) {
    throw new AcceptanceError(`qualification gate failed: ${summary.thresholds.failures.join(", ")}`);
  }
  if (cleanup.issues.length > 0) {
    throw new AcceptanceError(`qualification cleanup failed: ${cleanup.issues.join(", ")}`);
  }

  logger.log("PASS - K-Comms staging load qualification completed");
  return summary;
}

function printHelp() {
  console.log(`K-Comms staging load and soak qualification (Node.js 22+, no package install required)

Required environment variables:
  K_COMMS_BASE_URL                 Public staging application origin
  K_COMMS_TENANT_SLUG              Existing staging tenant slug
  K_COMMS_OWNER_EMAIL              Existing staging owner or admin email
  K_COMMS_OWNER_PASSWORD           Existing staging password

Optional workload variables:
  K_COMMS_LOAD_MESSAGES            Total canonical messages, 1-10000 (default ${DEFAULT_MESSAGES})
  K_COMMS_LOAD_CONCURRENCY         Maximum in-flight sends, 1-64 (default ${DEFAULT_CONCURRENCY})
  K_COMMS_LOAD_DURATION_SECONDS    Spread sends across this window, 0-3600 (default ${DEFAULT_DURATION_SECONDS})
  K_COMMS_LOAD_DUPLICATE_PROBES    Idempotency replays, 0-100 (default min(3, messages))
  K_COMMS_TIMEOUT_MS               Per-request timeout, 1000-120000 (default ${DEFAULT_TIMEOUT_MS})
  K_COMMS_LOAD_MAX_RUN_SECONDS     Configuration safety bound, 30-21600 (default ${DEFAULT_MAX_RUN_SECONDS})

Optional qualification thresholds:
  K_COMMS_LOAD_MAX_P95_MS          Fail when message-acceptance p95 exceeds this value
  K_COMMS_LOAD_REQUIRE_ZERO_LOSS   true or false (default false)

The runner always creates a private run-scoped conversation, archives it, and
revokes its run-scoped device (or logs out as a fallback). It never deletes an
existing conversation. Output contains aggregate latency/reconciliation data,
not credentials, tokens, signed URLs, message bodies, or response bodies.`);
}

if (isDirectInvocation(import.meta.url, process.argv[1])) {
  if (process.argv.includes("--help") || process.argv.includes("-h")) {
    printHelp();
  } else {
    runStagingLoad().catch((error) => {
      console.error(
        `FAIL - ${redactLoadText(error, [process.env.K_COMMS_OWNER_PASSWORD])}`
      );
      process.exitCode = 1;
    });
  }
}

export {
  evaluateThresholds,
  percentile,
  readLoadConfiguration,
  redactLoadText,
  runStagingLoad
};
