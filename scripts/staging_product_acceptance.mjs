#!/usr/bin/env node

import { randomBytes, randomUUID } from "node:crypto";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  AcceptanceError,
  ApiClient,
  PhoenixChannel,
  assert,
  assertMessage,
  assertNoSensitiveValues,
  assertRecord,
  assertString,
  assertUuid,
  commandEnvelope,
  createSafeLogger,
  issueSocketTicket,
  pollUntil,
  readConfiguration,
  redactText,
  runAttachmentAcceptance
} from "./staging_acceptance.mjs";

const DEFAULT_WORKER_TIMEOUT_MS = 60_000;
const MAX_WORKER_TIMEOUT_MS = 180_000;
const SOCKET_STORM_SIZE = 12;
const FORBIDDEN_SAFE_KEYS = new Set([
  "access_token",
  "refresh_token",
  "invitation_token",
  "credential",
  "secret_hash",
  "private_key",
  "p256dh",
  "auth",
  "endpoint"
]);

function readProductConfiguration(env = process.env) {
  const baseline = readConfiguration({ ...env, K_COMMS_CONVERSATION_ID: "" });
  return {
    ...baseline,
    conversationId: null,
    workerTimeoutMs: parseBoundedInteger(
      env.K_COMMS_PRODUCT_WORKER_TIMEOUT_MS,
      "K_COMMS_PRODUCT_WORKER_TIMEOUT_MS",
      DEFAULT_WORKER_TIMEOUT_MS,
      5_000,
      MAX_WORKER_TIMEOUT_MS
    ),
    socketStormSize: SOCKET_STORM_SIZE
  };
}

function parseBoundedInteger(value, name, fallback, minimum, maximum) {
  if (value === undefined || value === null || String(value).trim() === "") return fallback;
  const parsed = Number(value);
  assert(
    Number.isInteger(parsed) && parsed >= minimum && parsed <= maximum,
    `${name} must be between ${minimum} and ${maximum}`
  );
  return parsed;
}

function onceAsync(operation) {
  assert(typeof operation === "function", "onceAsync operation must be a function");
  let result;
  return () => {
    result ??= Promise.resolve().then(operation);
    return result;
  };
}

function syntheticResources(runId) {
  assertUuid(runId, "qualification run id");
  const marker = `product-${runId}`;
  return {
    marker,
    memberEmail: `k-comms-${marker}@example.test`,
    memberName: `Qualification member ${runId}`,
    memberPassword: `Kc!${runId}aA9`,
    publicTitle: `Qualification public ${runId}`,
    inactiveTitle: `Qualification inactive ${runId}`,
    serviceName: `Qualification service ${runId}`,
    messageBody: `Qualification disconnected replay ${runId}`,
    inactiveBody: `Qualification inactive inbox ${runId}`,
    mentionBody: `Qualification mention ${runId}`,
    threadRootBody: `Qualification thread root ${runId}`,
    threadReplyBody: `Qualification thread reply ${runId}`,
    threadNestedBody: `Qualification thread nested ${runId}`,
    serviceBody: `Qualification service message ${runId}`
  };
}

function fakePushSubscription(runId, random = randomBytes) {
  assertUuid(runId, "push run id");
  return {
    endpoint: `https://push.invalid/k-comms/${runId}`,
    expiration_time: null,
    keys: {
      p256dh: Buffer.concat([Buffer.from([4]), random(64)]).toString("base64url"),
      auth: random(16).toString("base64url")
    }
  };
}

function assertSafeProjection(value, label, secrets = []) {
  assertNoSensitiveValues(value, secrets, label);
  walk(value, (key) => {
    assert(!FORBIDDEN_SAFE_KEYS.has(key), `${label} exposed forbidden field ${key}`);
  });
  return value;
}

function walk(value, visitKey) {
  if (Array.isArray(value)) {
    for (const item of value) walk(item, visitKey);
    return;
  }
  if (value === null || typeof value !== "object") return;
  for (const [key, nested] of Object.entries(value)) {
    visitKey(key);
    walk(nested, visitKey);
  }
}

function exactById(values, id, label) {
  assert(Array.isArray(values), `${label} must be an array`);
  const matches = values.filter((value) => value?.id === id);
  assert(matches.length === 1, `${label} did not contain exactly one expected id`);
  return assertRecord(matches[0], `${label} exact record`);
}

function assertBoundedAuditCsv(response, expectedResourceId, secrets, limit) {
  assert(
    response.response.headers.get("content-type")?.startsWith("text/csv"),
    "audit export did not return CSV"
  );
  assert(response.response.headers.get("x-export-truncated") === "false", "audit export was unexpectedly truncated");
  const rowCount = Number(response.response.headers.get("x-export-row-count"));
  assert(Number.isInteger(rowCount) && rowCount >= 1 && rowCount <= limit, "audit export row count is outside its bound");
  const csv = assertString(response.payload, "audit CSV");
  assert(Buffer.byteLength(csv) <= 1_000_000, "audit CSV exceeded the acceptance byte bound");
  assert(csv.includes(expectedResourceId), "audit CSV omitted the exact synthetic resource id");
  assertNoSensitiveValues(csv, secrets, "audit CSV");
  assert(csv.split("\r\n").filter(Boolean).length <= limit + 1, "audit CSV exceeded its row bound");
  return csv;
}

async function runProductAcceptance(env = process.env) {
  const config = readProductConfiguration(env);
  const runId = randomUUID();
  const names = syntheticResources(runId);
  const sensitive = new Set([config.ownerPassword, names.memberPassword]);
  const logger = createSafeLogger(sensitive);
  const api = new ApiClient(config.baseUrl, config.timeoutMs);
  const state = {
    channels: new Set(),
    conversations: [],
    ownerToken: null,
    ownerRefreshToken: null,
    ownerDeviceId: null,
    memberToken: null,
    memberRefreshToken: null,
    memberDeviceId: null,
    memberUserId: null,
    pushSubscriptionId: null,
    serviceAccount: null,
    serviceCredential: null,
    success: false
  };
  let failure = null;

  try {
    await api.request("/health/ready");
    const status = assertRecord((await api.request("/api/v1/status")).payload, "status response");
    assert(status.status === "operational", "service status is not operational");
    logger.ok("readiness and public status");

    const ownerSession = assertRecord(
      (
        await api.request("/api/v1/sessions", {
          method: "POST",
          body: {
            tenant_slug: config.tenantSlug,
            email: config.ownerEmail,
            password: config.ownerPassword,
            device: { name: `qualification-owner-${runId}`, platform: "web" }
          }
        })
      ).payload,
      "owner session"
    );
    state.ownerToken = assertString(ownerSession.access_token, "owner access token");
    state.ownerRefreshToken = assertString(ownerSession.refresh_token, "owner refresh token");
    sensitive.add(state.ownerToken);
    sensitive.add(state.ownerRefreshToken);
    const owner = assertRecord(ownerSession.user, "owner user");
    assertUuid(owner.id, "owner id");
    assert(owner.role === "owner", "qualification credential must belong to the tenant owner");
    state.ownerDeviceId = assertUuid(assertRecord(ownerSession.device, "owner device").id, "owner device id");
    await stepUp(api, state.ownerToken, config.ownerPassword);
    logger.ok("owner login and step-up");

    const platformOps = data(
      await api.request("/api/v1/platform/ops", { token: state.ownerToken }),
      "platform operations"
    );
    const providers = assertRecord(platformOps.providers, "platform providers");
    const browserPush = assertRecord(providers.browser_push, "browser push provider status");
    const notificationProvider = assertRecord(providers.notifications, "notification provider status");
    assert(browserPush.status === "available", "browser push is not available in platform operations");
    assert(notificationProvider.adapter === "log", "staging notification provider is not the log adapter");
    logger.ok("platform operations browser-push and log-adapter status");

    const invitationResponse = await api.request("/api/v1/admin/invitations", {
      method: "POST",
      token: state.ownerToken,
      expected: 201,
      headers: { "Idempotency-Key": `qualification-invite-${runId}` },
      body: { email: names.memberEmail, role: "member" }
    });
    const invitationEnvelope = assertRecord(invitationResponse.payload, "invitation response");
    const invitation = assertRecord(invitationEnvelope.data, "invitation");
    const invitationId = assertUuid(invitation.id, "invitation id");
    const invitationToken = assertString(invitationEnvelope.invitation_token, "invitation token");
    sensitive.add(invitationToken);

    const accepted = data(
      await api.request("/api/v1/invitations/accept", {
        method: "POST",
        expected: 201,
        body: {
          token: invitationToken,
          display_name: names.memberName,
          password: names.memberPassword
        }
      }),
      "accepted invitation"
    );
    state.memberUserId = assertUuid(accepted.id, "member user id");
    assert(accepted.email === names.memberEmail, "accepted invitation email changed");

    const memberSession = assertRecord(
      (
        await api.request("/api/v1/sessions", {
          method: "POST",
          body: {
            tenant_slug: config.tenantSlug,
            email: names.memberEmail,
            password: names.memberPassword,
            device: { name: `qualification-member-${runId}`, platform: "web" }
          }
        })
      ).payload,
      "member session"
    );
    state.memberToken = assertString(memberSession.access_token, "member access token");
    state.memberRefreshToken = assertString(memberSession.refresh_token, "member refresh token");
    state.memberDeviceId = assertUuid(assertRecord(memberSession.device, "member device").id, "member device id");
    sensitive.add(state.memberToken);
    sensitive.add(state.memberRefreshToken);

    const invitationList = data(
      await api.request("/api/v1/admin/invitations?status=accepted", { token: state.ownerToken }),
      "invitation list"
    );
    const listedInvitation = exactById(invitationList, invitationId, "accepted invitations");
    assert(listedInvitation.accepted_user_id === state.memberUserId, "invitation accepted user id changed");
    assertSafeProjection(invitationList, "invitation list", sensitive);
    logger.ok("invitation, second human identity, and session");

    await api.request("/api/v1/notification-preferences", {
      method: "PUT",
      token: state.memberToken,
      body: {
        email_enabled: false,
        push_enabled: false,
        in_app_enabled: true,
        muted_event_types: []
      }
    });

    const publicConversation = await createConversation(api, state.ownerToken, {
      title: names.publicTitle,
      kind: "channel",
      visibility: "tenant"
    });
    state.conversations.push(publicConversation);
    const publicId = publicConversation.id;

    const discovery = assertRecord(
      (
        await api.request(
          `/api/v1/channels/discover?q=${encodeURIComponent(names.publicTitle)}&limit=10`,
          { token: state.memberToken }
        )
      ).payload,
      "public discovery"
    );
    exactById(discovery.data, publicId, "public discovery");

    const firstJoin = await api.request(`/api/v1/channels/${publicId}/join`, {
      method: "POST",
      token: state.memberToken,
      expected: 201
    });
    const firstJoinEnvelope = assertRecord(firstJoin.payload, "first public join");
    assert(firstJoinEnvelope.replayed === false, "first public join was reported as replayed");
    const membership = assertRecord(assertRecord(firstJoinEnvelope.data, "first join data").membership, "public membership");
    const membershipId = assertUuid(membership.id, "public membership id");
    const membershipVersion = positiveInteger(membership.version, "public membership version");

    const replayedJoin = assertRecord(
      (
        await api.request(`/api/v1/channels/${publicId}/join`, {
          method: "POST",
          token: state.memberToken
        })
      ).payload,
      "replayed public join"
    );
    assert(replayedJoin.replayed === true, "repeated public join was not idempotent");
    assert(replayedJoin.data.membership.id === membershipId, "replayed join changed membership id");

    const firstLeave = assertRecord(
      (
        await api.request(`/api/v1/channels/${publicId}/membership`, {
          method: "DELETE",
          token: state.memberToken,
          body: { version: membershipVersion }
        })
      ).payload,
      "first public leave"
    );
    assert(firstLeave.replayed === false, "first public leave was reported as replayed");
    const replayedLeave = assertRecord(
      (
        await api.request(`/api/v1/channels/${publicId}/membership`, {
          method: "DELETE",
          token: state.memberToken,
          body: { version: membershipVersion }
        })
      ).payload,
      "replayed public leave"
    );
    assert(replayedLeave.replayed === true, "repeated public leave was not idempotent");
    const rejoin = await api.request(`/api/v1/channels/${publicId}/join`, {
      method: "POST",
      token: state.memberToken,
      expected: 201
    });
    assert(assertRecord(rejoin.payload, "public rejoin").replayed === false, "public rejoin did not reactivate membership");
    logger.ok("public-channel discovery, join, idempotent leave, and rejoin");

    const ownerConversation = await openChannel(
      api,
      config,
      state.ownerToken,
      `conversation:${publicId}`,
      { protocol_version: 1, after_sequence: 0, client_capabilities: ["message_revisions", "attachment_v2"] },
      state,
      sensitive
    );
    const disconnectedMember = await openChannel(
      api,
      config,
      state.memberToken,
      `conversation:${publicId}`,
      { protocol_version: 1, after_sequence: 0, client_capabilities: ["message_revisions", "attachment_v2"] },
      state,
      sensitive
    );
    await closeTracked(disconnectedMember.channel, state);

    const disconnectedCommandId = `qualification-disconnect-${runId}`;
    const disconnectedMessage = assertMessage(
      await ownerConversation.channel.push(
        "command",
        commandEnvelope(disconnectedCommandId, "message.send.v1", {
          body: names.messageBody,
          attachment_ids: [],
          mentioned_user_ids: []
        })
      ),
      "disconnected-client message"
    );
    assert(disconnectedMessage.conversation_id === publicId, "disconnected-client message changed conversation id");

    const replayedMember = await openChannel(
      api,
      config,
      state.memberToken,
      `conversation:${publicId}`,
      {
        protocol_version: 1,
        after_sequence: Math.max(0, disconnectedMessage.conversation_sequence - 1),
        client_capabilities: ["message_revisions", "attachment_v2"]
      },
      state,
      sensitive
    );
    exactById(replayedMember.join.messages, disconnectedMessage.id, "member reconnect replay");
    await closeTracked(replayedMember.channel, state);
    logger.ok("two-client send during disconnect and durable replay");

    const inactiveConversation = await createConversation(api, state.ownerToken, {
      title: names.inactiveTitle,
      kind: "group",
      visibility: "private",
      member_ids: [state.memberUserId]
    });
    state.conversations.push(inactiveConversation);
    const userInbox = await openChannel(
      api,
      config,
      state.memberToken,
      `user:${state.memberUserId}`,
      { protocol_version: 1 },
      state,
      sensitive
    );
    const inactiveMessage = await sendMessage(
      api,
      state.ownerToken,
      inactiveConversation.id,
      names.inactiveBody,
      { idempotencyKey: `qualification-inactive-${runId}` }
    );
    const activity = await userInbox.channel.waitForEvent(
      "conversation.activity.v1",
      (payload) => payload?.conversation_id === inactiveConversation.id && payload?.latest_sequence === inactiveMessage.conversation_sequence
    );
    assert(activity.event_type === "message.created.v1", "inactive inbox activity event type changed");
    logger.ok("content-free activity for a non-joined conversation");

    await pollForInApp(api, state.memberToken, inactiveMessage.id, config.workerTimeoutMs);
    await api.request("/api/v1/in-app-notifications/read-all", {
      method: "POST",
      token: state.memberToken
    });
    assert((await unreadCount(api, state.memberToken)) === 0, "pre-mention unread notifications were not cleared");

    const pushConfig = data(
      await api.request("/api/v1/me/push-subscriptions/config", { token: state.memberToken }),
      "push configuration"
    );
    assert(pushConfig.available === true, "browser push registration is unavailable");
    assertString(pushConfig.vapid_public_key, "VAPID public key");
    const pushInput = fakePushSubscription(runId);
    sensitive.add(pushInput.endpoint);
    sensitive.add(pushInput.keys.p256dh);
    sensitive.add(pushInput.keys.auth);
    const pushRegistration = assertRecord(
      (
        await api.request("/api/v1/me/push-subscriptions", {
          method: "POST",
          token: state.memberToken,
          expected: 201,
          body: pushInput
        })
      ).payload,
      "push registration"
    );
    state.pushSubscriptionId = assertUuid(pushRegistration.data.id, "push subscription id");
    const pushList = data(
      await api.request("/api/v1/me/push-subscriptions", { token: state.memberToken }),
      "push subscription list"
    );
    exactById(pushList, state.pushSubscriptionId, "push subscription list");
    assertSafeProjection(pushList, "push subscription list", sensitive);
    await api.request("/api/v1/notification-preferences", {
      method: "PUT",
      token: state.memberToken,
      body: {
        email_enabled: false,
        push_enabled: true,
        in_app_enabled: true,
        muted_event_types: []
      }
    });

    const mentionMessage = await sendMessage(
      api,
      state.ownerToken,
      publicId,
      names.mentionBody,
      {
        idempotencyKey: `qualification-mention-${runId}`,
        mentionedUserIds: [state.memberUserId]
      }
    );
    const inApp = await pollForInApp(api, state.memberToken, mentionMessage.id, config.workerTimeoutMs, "mention.created.v1");
    assert(inApp.conversation_id === publicId, "mention notification changed conversation id");
    assert((await unreadCount(api, state.memberToken)) === 1, "mention did not produce exactly one unread notification");
    await api.request(`/api/v1/in-app-notifications/${inApp.id}/read`, {
      method: "PATCH",
      token: state.memberToken
    });
    assert((await unreadCount(api, state.memberToken)) === 0, "read mention did not decrement unread count");
    await api.request(`/api/v1/in-app-notifications/${inApp.id}`, {
      method: "DELETE",
      token: state.memberToken
    });
    const afterDismiss = data(
      await api.request("/api/v1/in-app-notifications?limit=100", { token: state.memberToken }),
      "in-app notifications after dismiss"
    );
    assert(!afterDismiss.some((notification) => notification.id === inApp.id), "dismissed mention remained visible");

    const pushIntent = assertRecord(
      await pollUntil(
        "push intent delivery",
        async () => data(await api.request("/api/v1/notifications?limit=100", { token: state.memberToken }), "notification intents"),
        (intents) =>
          intents.some(
            (intent) =>
              intent.channel === "push" &&
              intent.event_type === "mention.created.v1" &&
              intent.payload?.message_id === mentionMessage.id &&
              intent.status === "delivered"
          ),
        { timeoutMs: config.workerTimeoutMs, intervalMs: 500 }
      ).then((intents) =>
        intents.find(
          (intent) =>
            intent.channel === "push" &&
            intent.event_type === "mention.created.v1" &&
            intent.payload?.message_id === mentionMessage.id
        )
      ),
      "exact push intent"
    );
    assertSafeProjection(pushIntent, "push intent", sensitive);
    assert(pushIntent.destination_hint === null, "push intent exposed a destination hint");
    const logAttempt = assertRecord(
      await pollUntil(
        "log-adapter push attempt",
        async () => data(await api.request("/api/v1/notification-attempts?limit=100", { token: state.memberToken }), "notification attempts"),
        (attempts) => attempts.some((attempt) => attempt.intent_id === pushIntent.id && attempt.status === "delivered"),
        { timeoutMs: config.workerTimeoutMs, intervalMs: 500 }
      ).then((attempts) => attempts.find((attempt) => attempt.intent_id === pushIntent.id)),
      "exact log-adapter attempt"
    );
    assert(logAttempt.provider === "log", "push delivery was not accepted by the log adapter");
    logger.ok("mention, actionable in-app state, and redacted log-adapter push intent");

    const threadRoot = await sendMessage(api, state.ownerToken, publicId, names.threadRootBody, {
      idempotencyKey: `qualification-thread-root-${runId}`
    });
    const threadReply = await sendMessage(api, state.ownerToken, publicId, names.threadReplyBody, {
      idempotencyKey: `qualification-thread-reply-${runId}`,
      replyToMessageId: threadRoot.id
    });
    const nestedReply = await sendMessage(api, state.ownerToken, publicId, names.threadNestedBody, {
      idempotencyKey: `qualification-thread-nested-${runId}`,
      replyToMessageId: threadReply.id
    });
    assert(threadReply.thread_root_message_id === threadRoot.id, "thread reply root changed");
    assert(nestedReply.reply_to_message_id === threadReply.id, "nested reply lost its immediate parent");
    assert(nestedReply.thread_root_message_id === threadRoot.id, "nested reply did not retain canonical root");
    const thread = data(
      await api.request(`/api/v1/conversations/${publicId}/messages/${nestedReply.id}/thread?limit=50`, {
        token: state.memberToken
      }),
      "canonical thread"
    );
    assert(thread.root.id === threadRoot.id, "thread endpoint returned a different root");
    assert(thread.reply_count === 2, "thread endpoint returned an incorrect reply count");
    assert(thread.replies.map((reply) => reply.id).join(",") === [threadReply.id, nestedReply.id].join(","), "thread replies are not canonical ascending order");
    logger.ok("canonical root, immediate parent, and nested thread read");

    const attachment = await runAttachmentAcceptance(api, {
      token: state.ownerToken,
      objectUrl: config.objectUrl,
      timeoutMs: config.workerTimeoutMs,
      attachmentByteSize: config.attachmentByteSize,
      runId,
      namePrefix: "staging-product-acceptance"
    });
    const attachmentMessage = await sendMessage(
      api,
      state.ownerToken,
      publicId,
      `Qualification attachment ${runId}`,
      {
        idempotencyKey: `qualification-attachment-${runId}`,
        attachmentIds: [attachment.attachmentId]
      }
    );
    assert(
      attachmentMessage.attachments?.some((value) => value.id === attachment.attachmentId),
      "ready baseline attachment was not linked to its synthetic message"
    );
    logger.ok(`baseline signed attachment path (${attachment.byteSize} bytes)`);

    await refreshTrackedSession(api, state, "owner", sensitive);
    await stepUp(api, state.ownerToken, config.ownerPassword);
    const serviceCreate = assertRecord(
      (
        await api.request("/api/v1/admin/service-accounts", {
          method: "POST",
          token: state.ownerToken,
          expected: 201,
          body: {
            name: names.serviceName,
            scopes: ["conversations:read", "messages:read", "messages:write", "search:read"],
            reason: `qualification ${runId}`
          }
        })
      ).payload,
      "service account creation"
    );
    state.serviceAccount = assertRecord(serviceCreate.data, "service account");
    assertUuid(state.serviceAccount.id, "service account id");
    state.serviceCredential = assertString(serviceCreate.credential, "service credential");
    sensitive.add(state.serviceCredential);
    await api.request(`/api/v1/conversations/${publicId}/members`, {
      method: "POST",
      token: state.ownerToken,
      expected: 201,
      body: { user_id: state.serviceAccount.user_id, role: "member" }
    });

    const listedServiceAccounts = data(
      await api.request("/api/v1/admin/service-accounts", { token: state.ownerToken }),
      "service account list"
    );
    exactById(listedServiceAccounts, state.serviceAccount.id, "service account list");
    assertSafeProjection(listedServiceAccounts, "service account list", sensitive);
    const serviceConversations = data(
      await api.request("/api/v1/service/conversations", { token: state.serviceCredential }),
      "service conversations"
    );
    exactById(serviceConversations, publicId, "service conversations");
    const serviceHistory = assertRecord(
      (
        await api.request(`/api/v1/service/conversations/${publicId}/messages?after_sequence=0&limit=200`, {
          token: state.serviceCredential
        })
      ).payload,
      "service history"
    );
    exactById(serviceHistory.data, mentionMessage.id, "service history messages");
    const serviceIdempotencyKey = `qualification-service-${runId}`;
    const firstServiceSend = await api.request(`/api/v1/service/conversations/${publicId}/messages`, {
      method: "POST",
      token: state.serviceCredential,
      expected: 201,
      headers: { "Idempotency-Key": serviceIdempotencyKey },
      body: { body: names.serviceBody, attachment_ids: [] }
    });
    const firstServiceEnvelope = assertRecord(firstServiceSend.payload, "first service send");
    const serviceMessage = assertMessage(firstServiceEnvelope.data, "service message");
    assert(firstServiceEnvelope.replayed === false, "first service send was replayed");
    const replayedServiceSend = assertRecord(
      (
        await api.request(`/api/v1/service/conversations/${publicId}/messages`, {
          method: "POST",
          token: state.serviceCredential,
          expected: 200,
          headers: { "Idempotency-Key": serviceIdempotencyKey },
          body: { body: names.serviceBody, attachment_ids: [] }
        })
      ).payload,
      "replayed service send"
    );
    assert(replayedServiceSend.replayed === true, "service retry was not idempotent");
    assert(replayedServiceSend.data.id === serviceMessage.id, "service retry changed message id");
    const serviceSearch = data(
      await api.request(`/api/v1/service/search?q=${encodeURIComponent(names.serviceBody)}&limit=20`, {
        token: state.serviceCredential
      }),
      "service search"
    );
    exactById(serviceSearch, serviceMessage.id, "service search results");
    await api.request("/api/v1/me", { token: state.serviceCredential, expected: 401 });
    logger.ok("scoped service list, history, idempotent send, search, and human-route denial");

    await stepUp(api, state.ownerToken, config.ownerPassword);
    const exportResponse = await api.request("/api/v1/admin/audit-events/export", {
      method: "POST",
      token: state.ownerToken,
      body: {
        action: "service_account.create",
        q: state.serviceAccount.id,
        after: new Date(Date.now() - config.workerTimeoutMs).toISOString(),
        limit: 10
      }
    });
    assertBoundedAuditCsv(exportResponse, state.serviceAccount.id, sensitive, 10);
    logger.ok("bounded, redacted audit CSV export with exact synthetic resource id");

    await runSocketStorm(api, config, state.ownerToken, publicId, state, sensitive);
    logger.ok("12-client reconnect and join storm");

    state.success = true;
  } catch (error) {
    failure = new AcceptanceError(redactText(error, [...sensitive]));
  }

  const cleanupErrors = await cleanup(api, config, state, runId, sensitive);
  if (failure && cleanupErrors.length > 0) {
    throw new AcceptanceError(`${failure.message}; cleanup failed for ${cleanupErrors.join(", ")}`);
  }
  if (failure) throw failure;
  if (cleanupErrors.length > 0) {
    throw new AcceptanceError(`qualification cleanup failed for ${cleanupErrors.join(", ")}`);
  }
  logger.info("PASS - K-Comms full staging product qualification completed");
}

async function stepUp(api, token, password) {
  const result = data(
    await api.request("/api/v1/me/step-up", {
      method: "POST",
      token,
      body: { current_password: password }
    }),
    "step-up response"
  );
  assertString(result.step_up_at, "step-up timestamp");
}

async function createConversation(api, token, attrs) {
  const conversation = data(
    await api.request("/api/v1/conversations", {
      method: "POST",
      token,
      expected: 201,
      body: attrs
    }),
    "created conversation"
  );
  assertUuid(conversation.id, "created conversation id");
  positiveInteger(conversation.version, "created conversation version");
  return conversation;
}

async function sendMessage(
  api,
  token,
  conversationId,
  body,
  {
    idempotencyKey = `qualification-${randomUUID()}`,
    mentionedUserIds = [],
    replyToMessageId = null,
    attachmentIds = []
  } = {}
) {
  const response = await api.request(`/api/v1/conversations/${conversationId}/messages`, {
    method: "POST",
    token,
    expected: [200, 201],
    headers: { "Idempotency-Key": idempotencyKey },
    body: {
      body,
      attachment_ids: attachmentIds,
      mentioned_user_ids: mentionedUserIds,
      reply_to_message_id: replyToMessageId
    }
  });
  const message = assertMessage(data(response, "created message"), "created message");
  assert(message.conversation_id === conversationId, "message changed conversation id");
  assert(message.body === body, "message body changed");
  return message;
}

async function openChannel(api, config, token, topic, payload, state, sensitive) {
  const ticket = await issueSocketTicket(api, token);
  sensitive.add(ticket);
  const channel = new PhoenixChannel(config.socketUrl, ticket, config.timeoutMs);
  state.channels.add(channel);
  await channel.connect();
  const join = await channel.join(topic, payload);
  return { channel, join };
}

async function closeTracked(channel, state) {
  await channel.close();
  state.channels.delete(channel);
}

async function runSocketStorm(api, config, token, conversationId, state, sensitive) {
  for (let wave = 0; wave < 2; wave += 1) {
    const tickets = await Promise.all(
      Array.from({ length: config.socketStormSize }, () => issueSocketTicket(api, token))
    );
    tickets.forEach((ticket) => sensitive.add(ticket));
    const channels = tickets.map((ticket) => new PhoenixChannel(config.socketUrl, ticket, config.timeoutMs));
    channels.forEach((channel) => state.channels.add(channel));
    try {
      await Promise.all(channels.map((channel) => channel.connect()));
      const joins = await Promise.all(
        channels.map((channel) =>
          channel.join(`conversation:${conversationId}`, {
            protocol_version: 1,
            after_sequence: 0,
            client_capabilities: ["message_revisions", "attachment_v2"]
          })
        )
      );
      assert(joins.length === config.socketStormSize, "socket storm join count changed");
      joins.forEach((join) => assert(Array.isArray(join.messages), "socket storm join omitted messages"));
    } finally {
      await Promise.all(channels.map((channel) => closeTracked(channel, state)));
    }
  }
}

async function pollForInApp(api, token, messageId, timeoutMs, eventType = "message.created.v1") {
  const notifications = await pollUntil(
    `in-app ${eventType}`,
    async () => data(await api.request("/api/v1/in-app-notifications?limit=100", { token }), "in-app notifications"),
    (values) =>
      values.some(
        (notification) => notification.message_id === messageId && notification.event_type === eventType
      ),
    { timeoutMs, intervalMs: 500 }
  );
  return notifications.find(
    (notification) => notification.message_id === messageId && notification.event_type === eventType
  );
}

async function unreadCount(api, token) {
  const result = data(
    await api.request("/api/v1/in-app-notifications/unread-count", { token }),
    "in-app unread count"
  );
  assert(Number.isInteger(result.unread_count) && result.unread_count >= 0, "unread count is invalid");
  return result.unread_count;
}

async function refreshTrackedSession(api, state, actor, sensitive) {
  const refreshKey = `${actor}RefreshToken`;
  const tokenKey = `${actor}Token`;
  const deviceKey = `${actor}DeviceId`;
  const currentRefreshToken = state[refreshKey];
  assertString(currentRefreshToken, `${actor} refresh token`);

  const session = assertRecord(
    (
      await api.request("/api/v1/sessions/refresh", {
        method: "POST",
        body: { refresh_token: currentRefreshToken }
      })
    ).payload,
    `${actor} refreshed session`
  );

  state[tokenKey] = assertString(session.access_token, `${actor} refreshed access token`);
  state[refreshKey] = assertString(session.refresh_token, `${actor} rotated refresh token`);
  state[deviceKey] = assertUuid(assertRecord(session.device, `${actor} refreshed device`).id, `${actor} refreshed device id`);
  sensitive.add(state[tokenKey]);
  sensitive.add(state[refreshKey]);
  return session;
}

async function cleanup(api, config, state, runId, sensitive) {
  const errors = [];
  const attempt = async (label, operation) => {
    try {
      await operation();
    } catch {
      errors.push(label);
    }
  };

  await Promise.all([...state.channels].map((channel) => closeTracked(channel, state).catch(() => {})));

  if (state.ownerRefreshToken) {
    await attempt("owner session refresh", () => refreshTrackedSession(api, state, "owner", sensitive));
  }
  if (state.memberRefreshToken) {
    await attempt("member session refresh", () => refreshTrackedSession(api, state, "member", sensitive));
  }

  const ensureOwnerStepUp = onceAsync(() =>
    stepUp(api, assertString(state.ownerToken, "cleanup owner token"), config.ownerPassword)
  );

  if (state.memberToken && state.pushSubscriptionId) {
    await attempt("push subscription", () =>
      api.request(`/api/v1/me/push-subscriptions/${state.pushSubscriptionId}`, {
        method: "DELETE",
        token: state.memberToken,
        expected: [200, 404]
      })
    );
  }

  if (state.ownerToken && state.serviceAccount) {
    await attempt("service account", async () => {
      await ensureOwnerStepUp();
      await api.request(`/api/v1/admin/service-accounts/${state.serviceAccount.id}/revoke`, {
        method: "POST",
        token: state.ownerToken,
        expected: [200, 409],
        body: {
          version: state.serviceAccount.version,
          reason: `qualification cleanup ${runId}`
        }
      });
      if (state.serviceCredential) {
        await api.request("/api/v1/service/conversations", {
          token: state.serviceCredential,
          expected: 401
        });
      }
    });
  }

  if (state.ownerToken) {
    for (const conversation of state.conversations) {
      await attempt(`conversation ${conversation.id}`, () =>
        api.request(`/api/v1/conversations/${conversation.id}/archive`, {
          method: "POST",
          token: state.ownerToken,
          expected: [200, 409, 404],
          body: { version: conversation.version }
        })
      );
    }

    await attempt("conversation deletion step-up", ensureOwnerStepUp);
    for (const conversation of state.conversations) {
      await attempt(`conversation deletion ${conversation.id}`, () =>
        deleteSyntheticTarget(
          api,
          state.ownerToken,
          {
            target_type: "conversation",
            conversation_id: conversation.id,
            reason: `qualification cleanup ${runId}`
          },
          `qualification-delete-conversation-${conversation.id}`,
          config.workerTimeoutMs
        )
      );
    }
  }

  if (state.memberToken) {
    await attempt("member session", () =>
      api.request("/api/v1/sessions/current", {
        method: "DELETE",
        token: state.memberToken,
        expected: [204, 401]
      })
    );
  }

  if (state.ownerToken && state.memberUserId) {
    await attempt("member deletion", async () => {
      await ensureOwnerStepUp();
      const created = assertRecord(
        (
          await api.request("/api/v1/admin/deletion-requests", {
            method: "POST",
            token: state.ownerToken,
            expected: [200, 201],
            headers: { "Idempotency-Key": `qualification-delete-user-${runId}` },
            body: {
              target_type: "user",
              subject_user_id: state.memberUserId,
              reason: `qualification cleanup ${runId}`
            }
          })
        ).payload,
        "member deletion request"
      );
      const request = assertRecord(created.data, "member deletion request data");
      await api.request(`/api/v1/admin/deletion-requests/${request.id}`, {
        method: "PATCH",
        token: state.ownerToken,
        body: {
          status: "approved",
          version: request.version,
          transition_reason: `qualification cleanup ${runId}`
        }
      });
      await pollUntil(
        "synthetic member deletion",
        async () =>
          data(
            await api.request("/api/v1/admin/deletion-requests?target_type=user&limit=100", {
              token: state.ownerToken
            }),
            "deletion request list"
          ),
        (requests) => requests.some((value) => value.id === request.id && value.status === "completed"),
        { timeoutMs: config.workerTimeoutMs, intervalMs: 500 }
      );
    });
  }

  if (state.ownerToken && state.ownerDeviceId) {
    await attempt("owner run device", () =>
      api.request(`/api/v1/me/devices/${state.ownerDeviceId}`, {
        method: "DELETE",
        token: state.ownerToken,
        expected: 204
      })
    );
  } else if (state.ownerToken) {
    await attempt("owner session", () =>
      api.request("/api/v1/sessions/current", {
        method: "DELETE",
        token: state.ownerToken,
        expected: [204, 401]
      })
    );
  }

  assertNoSensitiveValues(errors, sensitive, "cleanup result");
  return errors;
}

async function deleteSyntheticTarget(api, token, target, idempotencyKey, timeoutMs) {
  const created = assertRecord(
    (
      await api.request("/api/v1/admin/deletion-requests", {
        method: "POST",
        token,
        expected: [200, 201],
        headers: { "Idempotency-Key": idempotencyKey },
        body: target
      })
    ).payload,
    "synthetic deletion request"
  );
  const request = assertRecord(created.data, "synthetic deletion request data");
  await api.request(`/api/v1/admin/deletion-requests/${request.id}`, {
    method: "PATCH",
    token,
    body: {
      status: "approved",
      version: request.version,
      transition_reason: target.reason
    }
  });
  await pollUntil(
    "synthetic target deletion",
    async () =>
      data(
        await api.request("/api/v1/admin/deletion-requests?limit=100", { token }),
        "synthetic deletion list"
      ),
    (requests) => requests.some((value) => value.id === request.id && value.status === "completed"),
    { timeoutMs, intervalMs: 500 }
  );
}

function data(response, label) {
  const envelope = assertRecord(response.payload, `${label} response`);
  return envelope.data;
}

function positiveInteger(value, label) {
  assert(Number.isInteger(value) && value > 0, `${label} must be a positive integer`);
  return value;
}

function printHelp() {
  console.log(`K-Comms full staging product qualification (Node.js 22+, no package install required)

Required environment variables:
  K_COMMS_BASE_URL         Public application origin
  K_COMMS_OBJECT_URL       Expected public object-storage origin
  K_COMMS_TENANT_SLUG      Existing staging tenant slug
  K_COMMS_OWNER_EMAIL      Existing staging owner/platform-operator email
  K_COMMS_OWNER_PASSWORD   Existing staging owner password

Optional environment variables:
  K_COMMS_SOCKET_URL                 Phoenix endpoint ending in /socket or /socket/websocket
  K_COMMS_TIMEOUT_MS                 Per-operation timeout, 1000-120000
  K_COMMS_PRODUCT_WORKER_TIMEOUT_MS  Durable-worker timeout, 5000-180000 (default 60000)
  K_COMMS_ATTACHMENT_BYTES           Baseline attachment size, 1-25000000 (default small probe)

The runner creates only UUID-scoped synthetic data, uses 12 reconnecting socket clients,
and performs bounded cleanup. It never prints credentials, bearer/refresh/socket tickets,
invitation tokens, service credentials, push keys/endpoints, or signed object URLs.`);
}

function isDirectInvocation(moduleUrl, argvPath, realpath = realpathSync) {
  if (!argvPath) return false;
  try {
    return realpath(fileURLToPath(moduleUrl)) === realpath(resolve(argvPath));
  } catch {
    return moduleUrl === pathToFileURL(resolve(argvPath)).href;
  }
}

if (isDirectInvocation(import.meta.url, process.argv[1])) {
  if (process.argv.includes("--help") || process.argv.includes("-h")) {
    printHelp();
  } else {
    runProductAcceptance().catch((error) => {
      console.error(`FAIL - ${redactText(error, [process.env.K_COMMS_OWNER_PASSWORD])}`);
      process.exitCode = 1;
    });
  }
}

export {
  SOCKET_STORM_SIZE,
  assertBoundedAuditCsv,
  assertSafeProjection,
  exactById,
  fakePushSubscription,
  isDirectInvocation,
  onceAsync,
  parseBoundedInteger,
  readProductConfiguration,
  runProductAcceptance,
  syntheticResources
};
