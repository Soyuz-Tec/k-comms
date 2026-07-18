#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const millisecondsPerDay = 24 * 60 * 60 * 1000;
const millisecondsPerWeek = 7 * millisecondsPerDay;
const requiredSignoffRoles = ["product", "accessibility", "security", "operations"];
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
  "ticket_body",
  "support_request_text",
  "qualitative_notes"
]);
const topLevelKeys = new Set([
  "schema_version",
  "release_revision",
  "environment",
  "pilot_started_on",
  "pilot_completed_on",
  "formal_study_passed",
  "formal_study_receipt_reference",
  "staging_gates_pass",
  "invited_user_count",
  "activated_user_count",
  "active_user_count",
  "tenant_admin_count",
  "trained_operator_count",
  "weekly_activity",
  "usability_support_request_count",
  "accessibility_blocker_count",
  "sev1_incident_count",
  "sev2_incident_count",
  "acknowledged_message_loss_count",
  "tenant_boundary_failure_count",
  "signoffs"
]);
const weeklyActivityKeys = new Set(["week_started_on", "active_user_count"]);
const signoffKeys = new Set(["status", "approved_on", "evidence_reference"]);

export function scorePilot(pilot) {
  const validated = validatePilot(pilot);
  const elapsedDays = (validated.completedOn - validated.startedOn) / millisecondsPerDay;
  const activationPercent = pilot.invited_user_count === 0
    ? null
    : percent(pilot.activated_user_count / pilot.invited_user_count);
  const weeklyActivityPercent = pilot.weekly_activity.map(({ week_started_on: weekStartedOn, active_user_count: activeUsers }) => ({
    week_started_on: weekStartedOn,
    active_user_count: activeUsers,
    invited_user_percent: pilot.invited_user_count === 0 ? null : percent(activeUsers / pilot.invited_user_count)
  }));
  const weeklyPercentages = weeklyActivityPercent.map(({ invited_user_percent: value }) => value).filter((value) => value !== null);
  const minimumWeeklyActivePercent = weeklyPercentages.length === weeklyActivityPercent.length
    ? Math.min(...weeklyPercentages)
    : null;
  const supportRequestsPerActiveUser = pilot.active_user_count === 0
    ? null
    : round(pilot.usability_support_request_count / pilot.active_user_count);
  const approvedSignoffs = requiredSignoffRoles.filter((role) => pilot.signoffs[role].status === "approved");

  const metrics = {
    elapsed_days: elapsedDays,
    invited_user_count: pilot.invited_user_count,
    activated_user_count: pilot.activated_user_count,
    activation_percent: activationPercent,
    active_user_count: pilot.active_user_count,
    weekly_activity: weeklyActivityPercent,
    minimum_weekly_active_percent: minimumWeeklyActivePercent,
    usability_support_request_count: pilot.usability_support_request_count,
    usability_support_requests_per_active_user: supportRequestsPerActiveUser,
    tenant_admin_count: pilot.tenant_admin_count,
    trained_operator_count: pilot.trained_operator_count,
    approved_signoff_roles: approvedSignoffs
  };

  const gates = [
    gate("Pilot elapsed time", elapsedDays >= 14, elapsedDays, ">= 14 days"),
    gate("Pilot cohort size", pilot.invited_user_count >= 20 && pilot.invited_user_count <= 30, pilot.invited_user_count, "20-30 invited users"),
    gate("Tenant administrator representation", pilot.tenant_admin_count >= 2, pilot.tenant_admin_count, ">= 2"),
    gate("Trained operator representation", pilot.trained_operator_count >= 2, pilot.trained_operator_count, ">= 2"),
    gate("Invited-user activation", activationPercent !== null && activationPercent >= 80, activationPercent, ">= 80%"),
    gate("Weekly active usage", minimumWeeklyActivePercent !== null && minimumWeeklyActivePercent >= 60, minimumWeeklyActivePercent, ">= 60% of invited users in every reported week"),
    gate("Usability support requests per active user", supportRequestsPerActiveUser !== null && supportRequestsPerActiveUser < 0.2, supportRequestsPerActiveUser, "< 0.2"),
    gate("No accessibility blocker", pilot.accessibility_blocker_count === 0, pilot.accessibility_blocker_count, "0"),
    gate("No Sev-1 incident", pilot.sev1_incident_count === 0, pilot.sev1_incident_count, "0"),
    gate("No Sev-2 incident", pilot.sev2_incident_count === 0, pilot.sev2_incident_count, "0"),
    gate("No acknowledged-message loss", pilot.acknowledged_message_loss_count === 0, pilot.acknowledged_message_loss_count, "0"),
    gate("No tenant-boundary failure", pilot.tenant_boundary_failure_count === 0, pilot.tenant_boundary_failure_count, "0"),
    gate("Formal usability study passed", pilot.formal_study_passed === true, pilot.formal_study_passed, "true"),
    gate("Staging qualification passes", pilot.staging_gates_pass === true, pilot.staging_gates_pass, "true"),
    ...requiredSignoffRoles.map((role) => gate(`${titleCase(role)} sign-off retained`, pilot.signoffs[role].status === "approved", pilot.signoffs[role].status, "approved"))
  ];

  return {
    schema_version: 1,
    release_revision: pilot.release_revision,
    environment: pilot.environment,
    pilot_started_on: pilot.pilot_started_on,
    pilot_completed_on: pilot.pilot_completed_on,
    pass: gates.every(({ pass }) => pass),
    metrics,
    gates
  };
}

function validatePilot(pilot) {
  assertRecord(pilot, "Pilot evidence");
  rejectSensitiveEvidence(pilot);
  assertAllowedKeys(pilot, topLevelKeys, "pilot");
  if (pilot.schema_version !== 1) throw new Error("schema_version must be 1.");
  if (!/^[0-9a-f]{40}$/i.test(pilot.release_revision || "")) throw new Error("release_revision must be a full 40-character Git SHA.");
  requireNonEmptyString(pilot.environment, "environment");
  const startedOn = parseIsoDate(pilot.pilot_started_on, "pilot_started_on");
  const completedOn = parseIsoDate(pilot.pilot_completed_on, "pilot_completed_on");
  const currentUtcDate = currentUtcDateTimestamp();
  if (completedOn < startedOn) throw new Error("pilot_completed_on must be on or after pilot_started_on.");
  if (completedOn > currentUtcDate) throw new Error("pilot_completed_on must not be in the future.");
  if (typeof pilot.formal_study_passed !== "boolean") throw new Error("formal_study_passed must be boolean.");
  if (typeof pilot.staging_gates_pass !== "boolean") throw new Error("staging_gates_pass must be boolean.");
  if (pilot.formal_study_passed) {
    requireNonEmptyString(pilot.formal_study_receipt_reference, "formal_study_receipt_reference");
  } else if (pilot.formal_study_receipt_reference !== null) {
    throw new Error("formal_study_receipt_reference must be null until the formal study passes.");
  }

  for (const field of [
    "invited_user_count",
    "activated_user_count",
    "active_user_count",
    "tenant_admin_count",
    "trained_operator_count",
    "usability_support_request_count",
    "accessibility_blocker_count",
    "sev1_incident_count",
    "sev2_incident_count",
    "acknowledged_message_loss_count",
    "tenant_boundary_failure_count"
  ]) {
    nonNegativeInteger(pilot[field], field);
  }
  if (pilot.activated_user_count > pilot.invited_user_count) throw new Error("activated_user_count cannot exceed invited_user_count.");
  if (pilot.active_user_count > pilot.activated_user_count) throw new Error("active_user_count cannot exceed activated_user_count.");
  if (pilot.tenant_admin_count > pilot.invited_user_count) throw new Error("tenant_admin_count cannot exceed invited_user_count.");
  if (pilot.trained_operator_count > pilot.invited_user_count) throw new Error("trained_operator_count cannot exceed invited_user_count.");

  if (!Array.isArray(pilot.weekly_activity) || pilot.weekly_activity.length < 2) throw new Error("weekly_activity must contain at least two weekly receipts.");
  const expectedWeeklyReceiptCount = Math.ceil((completedOn - startedOn) / millisecondsPerWeek);
  if (pilot.weekly_activity.length !== expectedWeeklyReceiptCount) {
    throw new Error(`weekly_activity must contain exactly ${expectedWeeklyReceiptCount} contiguous receipts at seven-day offsets from pilot_started_on through pilot_completed_on.`);
  }
  const weekStarts = new Set();
  pilot.weekly_activity.forEach((week, index) => {
    const path = `weekly_activity[${index}]`;
    assertRecord(week, path);
    assertAllowedKeys(week, weeklyActivityKeys, path);
    const weekStartedOn = parseIsoDate(week.week_started_on, `${path}.week_started_on`);
    if (weekStartedOn < startedOn || weekStartedOn > completedOn) throw new Error(`${path}.week_started_on must fall within the pilot dates.`);
    if (weekStarts.has(week.week_started_on)) throw new Error(`${path}.week_started_on must be unique.`);
    const expectedWeekStartedOn = startedOn + index * millisecondsPerWeek;
    if (weekStartedOn !== expectedWeekStartedOn) {
      throw new Error(`${path}.week_started_on must be ${formatIsoDate(expectedWeekStartedOn)} to cover contiguous seven-day intervals from pilot_started_on.`);
    }
    weekStarts.add(week.week_started_on);
    nonNegativeInteger(week.active_user_count, `${path}.active_user_count`);
    if (week.active_user_count > pilot.active_user_count) throw new Error(`${path}.active_user_count cannot exceed active_user_count.`);
  });

  assertRecord(pilot.signoffs, "signoffs");
  assertAllowedKeys(pilot.signoffs, new Set(requiredSignoffRoles), "signoffs");
  for (const role of requiredSignoffRoles) {
    if (!Object.hasOwn(pilot.signoffs, role)) throw new Error(`signoffs.${role} is required.`);
    validateSignoff(pilot.signoffs[role], role, completedOn, currentUtcDate);
  }
  return { startedOn, completedOn };
}

function validateSignoff(signoff, role, completedOn, currentUtcDate) {
  const path = `signoffs.${role}`;
  assertRecord(signoff, path);
  assertAllowedKeys(signoff, signoffKeys, path);
  if (!["not_approved", "approved"].includes(signoff.status)) throw new Error(`${path}.status is invalid.`);
  if (signoff.status === "approved") {
    const approvedOn = parseIsoDate(signoff.approved_on, `${path}.approved_on`);
    if (approvedOn < completedOn) throw new Error(`${path}.approved_on must be on or after pilot_completed_on.`);
    if (approvedOn > currentUtcDate) throw new Error(`${path}.approved_on must not be in the future.`);
    requireNonEmptyString(signoff.evidence_reference, `${path}.evidence_reference`);
  } else if (signoff.approved_on !== null || signoff.evidence_reference !== null) {
    throw new Error(`${path} must not claim an approval date or reference while not approved.`);
  }
}

function rejectSensitiveEvidence(value, path = "pilot") {
  if (!value || typeof value !== "object") return;
  if (Array.isArray(value)) {
    value.forEach((entry, index) => rejectSensitiveEvidence(entry, `${path}[${index}]`));
    return;
  }
  for (const [key, entry] of Object.entries(value)) {
    if (forbiddenEvidenceKeys.has(key.toLowerCase())) throw new Error(`Sensitive field ${path}.${key} is not allowed in pilot evidence.`);
    rejectSensitiveEvidence(entry, `${path}.${key}`);
  }
}

function assertRecord(value, path) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${path} must be a JSON object.`);
}

function assertAllowedKeys(value, allowed, path) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) throw new Error(`${path}.${key} is not allowed by pilot evidence schema v1.`);
  }
}

function requireNonEmptyString(value, path) {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${path} is required.`);
}

function nonNegativeInteger(value, path) {
  if (!Number.isInteger(value) || value < 0) throw new Error(`${path} must be a non-negative integer.`);
}

function parseIsoDate(value, path) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error(`${path} must use YYYY-MM-DD.`);
  const [year, month, day] = value.split("-").map(Number);
  const timestamp = Date.UTC(year, month - 1, day);
  const parsed = new Date(timestamp);
  if (parsed.getUTCFullYear() !== year || parsed.getUTCMonth() !== month - 1 || parsed.getUTCDate() !== day) throw new Error(`${path} must be a valid calendar date.`);
  return timestamp;
}

function formatIsoDate(timestamp) {
  return new Date(timestamp).toISOString().slice(0, 10);
}

function currentUtcDateTimestamp() {
  const now = new Date();
  return Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
}

function percent(value) {
  return round(value * 100);
}

function round(value) {
  return Math.round(value * 100) / 100;
}

function titleCase(value) {
  return `${value.charAt(0).toUpperCase()}${value.slice(1)}`;
}

function gate(name, pass, actual, target) {
  return { name, pass, actual, target };
}

async function main() {
  const inputPath = process.argv[2];
  if (!inputPath) throw new Error("Usage: node scripts/score_usability_pilot.mjs <pilot.json>");
  const pilot = JSON.parse(await readFile(inputPath, "utf8"));
  const result = scorePilot(pilot);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (!result.pass) process.exitCode = 1;
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch((reason) => {
    process.stderr.write(`${reason instanceof Error ? reason.message : String(reason)}\n`);
    process.exitCode = 2;
  });
}
