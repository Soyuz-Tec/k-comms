#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const allowedOutcomes = new Set(["unassisted", "assisted", "failed"]);
const allowedAccessMethods = new Set(["standard", "keyboard", "screen_reader", "zoom_high_contrast", "voice_touch"]);
const assistiveMethods = new Set(["keyboard", "screen_reader", "zoom_high_contrast", "voice_touch"]);
const findingStandards = new Set(["WCAG 2.2 A", "WCAG 2.2 AA", "advisory"]);
const findingSeverities = new Set(["critical", "serious", "moderate", "minor"]);
const findingStatuses = new Set(["open", "resolved"]);
const completionStatuses = new Set(["not_completed", "passed", "failed"]);
const forbiddenEvidenceKeys = new Set([
  "message_body",
  "message_content",
  "search_term",
  "email",
  "email_address",
  "tenant_slug",
  "invitation_token",
  "access_token",
  "refresh_token",
  "raw_user_id",
  "user_id",
  "participant_name",
  "approver_name",
  "full_name",
  "contact",
  "contact_details",
  "ip_address",
  "recording_url",
  "qualitative_notes"
]);

const taskMatrix = Object.freeze({
  member: Object.freeze([
    taskDefinition("invite-first-message", "invite", true),
    taskDefinition("channel-collaboration", "routine", true),
    taskDefinition("attachment-safety", "routine", true),
    taskDefinition("history-search", "routine", true),
    taskDefinition("send-recovery", "routine", true),
    taskDefinition("notification-control", "other", false),
    taskDefinition("device-revocation", "other", true)
  ]),
  admin: Object.freeze([taskDefinition("admin-access", "admin_safety", true)]),
  moderator: Object.freeze([taskDefinition("moderation-review", "admin_safety", true)]),
  compliance: Object.freeze([taskDefinition("audit-evidence", "admin_safety", false)]),
  operator: Object.freeze([taskDefinition("ops-triage", "ops_safety", true)])
});

const taskCatalog = new Map(
  Object.entries(taskMatrix).flatMap(([cohort, definitions]) =>
    definitions.map((definition) => [definition.id, { ...definition, cohort }])
  )
);

const topLevelKeys = new Set([
  "schema_version",
  "release_revision",
  "environment",
  "study_started_on",
  "study_completed_on",
  "security_regression",
  "authorization_regression",
  "tenant_isolation_regression",
  "durability_regression",
  "staging_gates_pass",
  "manual_accessibility",
  "accessibility_findings",
  "approver_receipt",
  "sessions"
]);
const sessionKeys = new Set([
  "participant_id",
  "cohort",
  "access_method",
  "mobile_first",
  "browser_name",
  "browser_version",
  "viewport_width_css_px",
  "viewport_height_css_px",
  "sus_responses",
  "sensitive_action_confidence",
  "tasks"
]);
const taskKeys = new Set([
  "id",
  "category",
  "critical",
  "outcome",
  "duration_seconds",
  "critical_errors",
  "backtracks",
  "facilitator_interventions",
  "seq",
  "unintended_destructive_action"
]);
const findingKeys = new Set(["finding_id", "standard", "severity", "status"]);
const manualAccessibilityKeys = new Set([
  "wcag_2_2_a_aa_status",
  "assistive_technology_matrix_status",
  "open_a_aa_failures",
  "completed_on"
]);
const approverReceiptKeys = new Set(["status", "approver_role", "approved_on", "evidence_reference"]);

export function scoreStudy(study) {
  validateStudy(study);

  const sessions = study.sessions;
  const tasks = sessions.flatMap((session) => session.tasks.map((task) => ({ ...task, session })));
  const critical = tasks.filter(({ critical: value }) => value);
  const invite = tasks.filter(({ category }) => category === "invite");
  const routine = tasks.filter(({ category }) => category === "routine");
  const adminSafety = tasks.filter(({ category }) => category === "admin_safety");
  const keyboardCritical = critical.filter(({ session }) => ["keyboard", "screen_reader"].includes(session.access_method));
  const successfulInviteDurations = invite
    .filter(({ outcome }) => outcome === "unassisted")
    .map(({ duration_seconds: value }) => value);
  const susScores = sessions.map(({ sus_responses: responses }) => susScore(responses));
  const cohorts = [...new Set(sessions.map(({ cohort }) => cohort))];
  const cohortSus = Object.fromEntries(cohorts.map((cohort) => [
    cohort,
    mean(sessions.filter((session) => session.cohort === cohort).map(({ sus_responses: responses }) => susScore(responses)))
  ]));
  const openSevereAccessibility = study.accessibility_findings.filter((finding) =>
    ["critical", "serious"].includes(finding.severity) && finding.status !== "resolved"
  );
  const unresolvedWcag = study.accessibility_findings.filter((finding) =>
    ["WCAG 2.2 A", "WCAG 2.2 AA"].includes(finding.standard) && finding.status !== "resolved"
  );
  const unintendedDestructiveActions = adminSafety.filter(({ unintended_destructive_action: value }) => value).length;

  const metrics = {
    participant_count: sessions.length,
    participant_mix: participantMix(sessions),
    critical_unassisted_percent: percent(unassistedRate(critical)),
    invite_unassisted_percent: percent(unassistedRate(invite)),
    invite_median_seconds: median(successfulInviteDurations),
    routine_unassisted_percent: percent(unassistedRate(routine)),
    admin_safety_unassisted_percent: percent(unassistedRate(adminSafety)),
    unintended_destructive_actions: unintendedDestructiveActions,
    median_seq: median(tasks.map(({ seq }) => seq)),
    median_sensitive_action_confidence: median(sessions.map(({ sensitive_action_confidence: value }) => value)),
    mean_sus: mean(susScores),
    cohort_mean_sus: cohortSus,
    keyboard_critical_completion_percent: percent(completionRate(keyboardCritical)),
    open_critical_or_serious_accessibility_findings: openSevereAccessibility.length,
    unresolved_wcag_2_2_a_aa_findings: unresolvedWcag.length
  };

  const quantitativeGates = [
    gate("Critical tasks completed unassisted", metrics.critical_unassisted_percent >= 90, metrics.critical_unassisted_percent, ">= 90%"),
    gate("Invite-to-first-message completed unassisted", metrics.invite_unassisted_percent >= 90, metrics.invite_unassisted_percent, ">= 90%"),
    gate("Invite-to-first-message median time", metrics.invite_median_seconds <= 300, metrics.invite_median_seconds, "<= 300 seconds"),
    gate("Routine messaging/search completed unassisted", metrics.routine_unassisted_percent >= 95, metrics.routine_unassisted_percent, ">= 95%"),
    gate("Admin safety tasks completed unassisted", metrics.admin_safety_unassisted_percent >= 90, metrics.admin_safety_unassisted_percent, ">= 90%"),
    gate("No unintended destructive action", unintendedDestructiveActions === 0, unintendedDestructiveActions, "0"),
    gate("Median Single Ease Question", metrics.median_seq >= 5.5, metrics.median_seq, ">= 5.5/7"),
    gate("Mean System Usability Scale", metrics.mean_sus >= 80, metrics.mean_sus, ">= 80"),
    gate("Every role cohort System Usability Scale", Object.values(cohortSus).every((value) => value >= 75), cohortSus, ">= 75 each"),
    gate("Keyboard and screen-reader critical-task completion", metrics.keyboard_critical_completion_percent === 100, metrics.keyboard_critical_completion_percent, "100%")
  ];
  const evidenceGates = [
    gate("No open critical/serious accessibility finding", openSevereAccessibility.length === 0, openSevereAccessibility.length, "0"),
    gate("No unresolved WCAG 2.2 A/AA finding", unresolvedWcag.length === 0, unresolvedWcag.length, "0"),
    gate("Manual WCAG 2.2 A/AA audit passed", study.manual_accessibility.wcag_2_2_a_aa_status === "passed" && study.manual_accessibility.open_a_aa_failures === 0, study.manual_accessibility.wcag_2_2_a_aa_status, "passed with 0 open failures"),
    gate("Assistive-technology matrix passed", study.manual_accessibility.assistive_technology_matrix_status === "passed", study.manual_accessibility.assistive_technology_matrix_status, "passed"),
    gate("No security regression", study.security_regression === false, study.security_regression, "false"),
    gate("No authorization regression", study.authorization_regression === false, study.authorization_regression, "false"),
    gate("No tenant-isolation regression", study.tenant_isolation_regression === false, study.tenant_isolation_regression, "false"),
    gate("No durability regression", study.durability_regression === false, study.durability_regression, "false"),
    gate("Staging qualification passes", study.staging_gates_pass === true, study.staging_gates_pass, "true"),
    gate("Release approver receipt retained", study.approver_receipt.status === "approved", study.approver_receipt.status, "approved")
  ];
  const gates = [...quantitativeGates, ...evidenceGates];

  return {
    schema_version: 2,
    release_revision: study.release_revision,
    environment: study.environment,
    study_started_on: study.study_started_on,
    study_completed_on: study.study_completed_on,
    quantitative_pass: quantitativeGates.every(({ pass }) => pass),
    pass: gates.every(({ pass }) => pass),
    metrics,
    gates
  };
}

function validateStudy(study) {
  assertRecord(study, "Study evidence");
  rejectSensitiveEvidence(study);
  assertAllowedKeys(study, topLevelKeys, "study");
  if (study.schema_version !== 2) throw new Error("schema_version must be 2.");
  if (!/^[0-9a-f]{40}$/i.test(study.release_revision || "")) throw new Error("release_revision must be a full 40-character Git SHA.");
  requireNonEmptyString(study.environment, "environment");
  const startedOn = parseIsoDate(study.study_started_on, "study_started_on");
  const completedOn = parseIsoDate(study.study_completed_on, "study_completed_on");
  if (completedOn < startedOn) throw new Error("study_completed_on must be on or after study_started_on.");
  if (completedOn > currentUtcDate()) throw new Error("study_completed_on must not be in the future relative to the current UTC date.");
  for (const field of ["security_regression", "authorization_regression", "tenant_isolation_regression", "durability_regression", "staging_gates_pass"]) {
    if (typeof study[field] !== "boolean") throw new Error(`${field} must be boolean.`);
  }

  validateManualAccessibility(study.manual_accessibility, startedOn, completedOn);
  validateApproverReceipt(study.approver_receipt, completedOn);
  if (!Array.isArray(study.accessibility_findings)) throw new Error("accessibility_findings must be an array.");
  study.accessibility_findings.forEach(validateAccessibilityFinding);
  if (!Array.isArray(study.sessions) || study.sessions.length !== 12) throw new Error("The formal validation study requires exactly 12 sessions.");

  const participantIds = new Set();
  study.sessions.forEach((session, sessionIndex) => {
    assertRecord(session, `sessions[${sessionIndex}]`);
    assertAllowedKeys(session, sessionKeys, `sessions[${sessionIndex}]`);
    if (!/^P[0-9A-Za-z_-]+$/.test(session.participant_id || "")) throw new Error(`sessions[${sessionIndex}].participant_id must be a synthetic code beginning with P.`);
    if (participantIds.has(session.participant_id)) throw new Error(`sessions[${sessionIndex}].participant_id must be unique.`);
    participantIds.add(session.participant_id);
    if (!Object.hasOwn(taskMatrix, session.cohort)) throw new Error(`sessions[${sessionIndex}].cohort is invalid.`);
    if (!allowedAccessMethods.has(session.access_method)) throw new Error(`sessions[${sessionIndex}].access_method is invalid.`);
    if (typeof session.mobile_first !== "boolean") throw new Error(`sessions[${sessionIndex}].mobile_first must be boolean.`);
    requireNonEmptyString(session.browser_name, `sessions[${sessionIndex}].browser_name`);
    requireNonEmptyString(session.browser_version, `sessions[${sessionIndex}].browser_version`);
    boundedInteger(session.viewport_width_css_px, 240, 10_000, `sessions[${sessionIndex}].viewport_width_css_px`);
    boundedInteger(session.viewport_height_css_px, 240, 10_000, `sessions[${sessionIndex}].viewport_height_css_px`);
    boundedInteger(session.sensitive_action_confidence, 1, 5, `sessions[${sessionIndex}].sensitive_action_confidence`);
    if (!Array.isArray(session.sus_responses) || session.sus_responses.length !== 10 || session.sus_responses.some((value) => !Number.isInteger(value) || value < 1 || value > 5)) {
      throw new Error(`sessions[${sessionIndex}].sus_responses must contain ten integers from 1 to 5.`);
    }
    validateSessionTasks(session, sessionIndex);
  });

  const mix = participantMix(study.sessions);
  if (mix.member < 6 || mix.admin_safety < 3 || mix.operator < 3) {
    throw new Error("Participant mix requires at least 6 members, 3 admin/moderation/compliance users, and 3 operators.");
  }
  if (mix.assistive < 4) throw new Error("Participant mix requires at least 4 assistive-technology users.");
  if (mix.mobile_first < 2) throw new Error("Participant mix requires at least 2 mobile-first users.");

  const observedTaskIds = new Set(study.sessions.flatMap(({ tasks }) => tasks.map(({ id }) => id)));
  for (const taskId of taskCatalog.keys()) {
    if (!observedTaskIds.has(taskId)) throw new Error(`Study evidence has no ${taskId} task receipts.`);
  }
}

function validateSessionTasks(session, sessionIndex) {
  const expected = taskMatrix[session.cohort];
  if (!Array.isArray(session.tasks) || session.tasks.length !== expected.length) {
    throw new Error(`sessions[${sessionIndex}].tasks must contain exactly the ${expected.length} tasks assigned to cohort ${session.cohort}.`);
  }
  const expectedById = new Map(expected.map((definition) => [definition.id, definition]));
  const taskIds = new Set();
  session.tasks.forEach((task, taskIndex) => {
    const path = `sessions[${sessionIndex}].tasks[${taskIndex}]`;
    assertRecord(task, path);
    assertAllowedKeys(task, taskKeys, path);
    if (taskIds.has(task.id)) throw new Error(`${path}.id must be unique within the session.`);
    taskIds.add(task.id);
    const definition = expectedById.get(task.id);
    if (!definition) throw new Error(`${path}.id is not assigned to cohort ${session.cohort}.`);
    if (task.category !== definition.category) throw new Error(`${path}.category must be ${definition.category} for ${task.id}.`);
    if (task.critical !== definition.critical) throw new Error(`${path}.critical must be ${definition.critical} for ${task.id}.`);
    if (!allowedOutcomes.has(task.outcome)) throw new Error(`${path}.outcome is invalid.`);
    if (typeof task.duration_seconds !== "number" || !Number.isFinite(task.duration_seconds) || task.duration_seconds < 0) throw new Error(`${path}.duration_seconds must be non-negative.`);
    boundedInteger(task.critical_errors, 0, Number.MAX_SAFE_INTEGER, `${path}.critical_errors`);
    boundedInteger(task.backtracks, 0, Number.MAX_SAFE_INTEGER, `${path}.backtracks`);
    boundedInteger(task.facilitator_interventions, 0, Number.MAX_SAFE_INTEGER, `${path}.facilitator_interventions`);
    if (task.outcome === "unassisted" && task.critical_errors !== 0) {
      throw new Error(`${path}.critical_errors must be 0 when outcome is unassisted.`);
    }
    if (task.outcome === "unassisted" && task.facilitator_interventions !== 0) {
      throw new Error(`${path}.facilitator_interventions must be 0 when outcome is unassisted.`);
    }
    if (task.outcome === "assisted" && task.facilitator_interventions < 1) {
      throw new Error(`${path}.facilitator_interventions must be at least 1 when outcome is assisted.`);
    }
    if (typeof task.seq !== "number" || !Number.isFinite(task.seq) || task.seq < 1 || task.seq > 7) throw new Error(`${path}.seq must be from 1 to 7.`);
    if (typeof task.unintended_destructive_action !== "boolean") throw new Error(`${path}.unintended_destructive_action must be boolean.`);
  });
  for (const definition of expected) {
    if (!taskIds.has(definition.id)) throw new Error(`sessions[${sessionIndex}].tasks is missing required task ${definition.id}.`);
  }
}

function validateAccessibilityFinding(finding, index) {
  const path = `accessibility_findings[${index}]`;
  assertRecord(finding, path);
  assertAllowedKeys(finding, findingKeys, path);
  if (!/^[A-Z0-9][A-Z0-9_-]*$/i.test(finding.finding_id || "")) throw new Error(`${path}.finding_id must be a non-identifying evidence code.`);
  if (!findingStandards.has(finding.standard)) throw new Error(`${path}.standard is invalid.`);
  if (!findingSeverities.has(finding.severity)) throw new Error(`${path}.severity is invalid.`);
  if (!findingStatuses.has(finding.status)) throw new Error(`${path}.status is invalid.`);
}

function validateManualAccessibility(value, startedOn, completedOn) {
  assertRecord(value, "manual_accessibility");
  assertAllowedKeys(value, manualAccessibilityKeys, "manual_accessibility");
  if (!completionStatuses.has(value.wcag_2_2_a_aa_status)) throw new Error("manual_accessibility.wcag_2_2_a_aa_status is invalid.");
  if (!completionStatuses.has(value.assistive_technology_matrix_status)) throw new Error("manual_accessibility.assistive_technology_matrix_status is invalid.");
  boundedInteger(value.open_a_aa_failures, 0, Number.MAX_SAFE_INTEGER, "manual_accessibility.open_a_aa_failures");
  const bothNotCompleted = value.wcag_2_2_a_aa_status === "not_completed" && value.assistive_technology_matrix_status === "not_completed";
  if (bothNotCompleted) {
    if (value.completed_on !== null) throw new Error("manual_accessibility.completed_on must be null while both manual activities are not completed.");
  } else {
    const manualDate = parseIsoDate(value.completed_on, "manual_accessibility.completed_on");
    if (manualDate < startedOn || manualDate > completedOn) throw new Error("manual_accessibility.completed_on must fall within the study dates.");
  }
  if (value.wcag_2_2_a_aa_status === "passed" && value.open_a_aa_failures !== 0) {
    throw new Error("manual_accessibility.open_a_aa_failures must be 0 when the WCAG audit passed.");
  }
}

function validateApproverReceipt(value, studyCompletedOn) {
  assertRecord(value, "approver_receipt");
  assertAllowedKeys(value, approverReceiptKeys, "approver_receipt");
  if (!["not_approved", "approved"].includes(value.status)) throw new Error("approver_receipt.status is invalid.");
  if (value.approver_role !== "release_approver") throw new Error("approver_receipt.approver_role must be release_approver.");
  if (value.status === "approved") {
    const approvedOn = parseIsoDate(value.approved_on, "approver_receipt.approved_on");
    if (approvedOn < studyCompletedOn) throw new Error("approver_receipt.approved_on must be on or after study_completed_on.");
    if (approvedOn > currentUtcDate()) throw new Error("approver_receipt.approved_on must not be in the future relative to the current UTC date.");
    requireNonEmptyString(value.evidence_reference, "approver_receipt.evidence_reference");
  } else if (value.approved_on !== null || value.evidence_reference !== null) {
    throw new Error("Unapproved evidence must not claim an approval date or reference.");
  }
}

function participantMix(sessions) {
  return {
    member: sessions.filter(({ cohort }) => cohort === "member").length,
    admin_safety: sessions.filter(({ cohort }) => ["admin", "moderator", "compliance"].includes(cohort)).length,
    operator: sessions.filter(({ cohort }) => cohort === "operator").length,
    assistive: sessions.filter(({ access_method: method }) => assistiveMethods.has(method)).length,
    mobile_first: sessions.filter(({ mobile_first: value }) => value === true).length
  };
}

function rejectSensitiveEvidence(value, path = "study") {
  if (!value || typeof value !== "object") return;
  if (Array.isArray(value)) {
    value.forEach((entry, index) => rejectSensitiveEvidence(entry, `${path}[${index}]`));
    return;
  }
  for (const [key, entry] of Object.entries(value)) {
    if (forbiddenEvidenceKeys.has(key.toLowerCase())) throw new Error(`Sensitive field ${path}.${key} is not allowed in usability evidence.`);
    rejectSensitiveEvidence(entry, `${path}.${key}`);
  }
}

function taskDefinition(id, category, critical) {
  return Object.freeze({ id, category, critical });
}

function assertRecord(value, path) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${path} must be a JSON object.`);
}

function assertAllowedKeys(value, allowed, path) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) throw new Error(`${path}.${key} is not allowed by usability evidence schema v2.`);
  }
}

function requireNonEmptyString(value, path) {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${path} is required.`);
}

function boundedInteger(value, minimum, maximum, path) {
  if (!Number.isInteger(value) || value < minimum || value > maximum) throw new Error(`${path} must be an integer from ${minimum} to ${maximum}.`);
}

function parseIsoDate(value, path) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error(`${path} must use YYYY-MM-DD.`);
  const [year, month, day] = value.split("-").map(Number);
  const timestamp = Date.UTC(year, month - 1, day);
  const parsed = new Date(timestamp);
  if (parsed.getUTCFullYear() !== year || parsed.getUTCMonth() !== month - 1 || parsed.getUTCDate() !== day) throw new Error(`${path} must be a valid calendar date.`);
  return timestamp;
}

function currentUtcDate() {
  const now = new Date();
  return Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
}

function susScore(responses) {
  return responses.reduce((sum, value, index) => sum + (index % 2 === 0 ? value - 1 : 5 - value), 0) * 2.5;
}

function unassistedRate(values) {
  return values.length === 0 ? 0 : values.filter(({ outcome }) => outcome === "unassisted").length / values.length;
}

function completionRate(values) {
  return values.length === 0 ? 0 : values.filter(({ outcome }) => outcome !== "failed").length / values.length;
}

function mean(values) {
  return values.length === 0 ? 0 : round(values.reduce((sum, value) => sum + value, 0) / values.length);
}

function median(values) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return round(sorted.length % 2 === 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]);
}

function percent(value) {
  return round(value * 100);
}

function round(value) {
  return Math.round(value * 100) / 100;
}

function gate(name, pass, actual, target) {
  return { name, pass, actual, target };
}

async function main() {
  const inputPath = process.argv[2];
  if (!inputPath) throw new Error("Usage: node scripts/score_usability_study.mjs <study.json>");
  const study = JSON.parse(await readFile(inputPath, "utf8"));
  const result = scoreStudy(study);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (!result.pass) process.exitCode = 1;
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch((reason) => {
    process.stderr.write(`${reason instanceof Error ? reason.message : String(reason)}\n`);
    process.exitCode = 2;
  });
}
