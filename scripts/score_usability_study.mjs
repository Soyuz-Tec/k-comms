#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const allowedOutcomes = new Set(["unassisted", "assisted", "failed"]);
const assistiveMethods = new Set(["keyboard", "screen_reader", "zoom_high_contrast", "voice_touch"]);
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
  "user_id"
]);

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
  const unintendedDestructiveActions = adminSafety.filter(({ unintended_destructive_action: value }) => value).length;

  const metrics = {
    participant_count: sessions.length,
    critical_unassisted_percent: percent(unassistedRate(critical)),
    invite_unassisted_percent: percent(unassistedRate(invite)),
    invite_median_seconds: median(successfulInviteDurations),
    routine_unassisted_percent: percent(unassistedRate(routine)),
    admin_safety_unassisted_percent: percent(unassistedRate(adminSafety)),
    unintended_destructive_actions: unintendedDestructiveActions,
    median_seq: median(tasks.map(({ seq }) => seq)),
    mean_sus: mean(susScores),
    cohort_mean_sus: cohortSus,
    keyboard_critical_completion_percent: percent(completionRate(keyboardCritical)),
    open_critical_or_serious_accessibility_findings: openSevereAccessibility.length
  };

  const gates = [
    gate("Critical tasks completed unassisted", metrics.critical_unassisted_percent >= 90, metrics.critical_unassisted_percent, ">= 90%"),
    gate("Invite-to-first-message completed unassisted", metrics.invite_unassisted_percent >= 90, metrics.invite_unassisted_percent, ">= 90%"),
    gate("Invite-to-first-message median time", metrics.invite_median_seconds <= 300, metrics.invite_median_seconds, "<= 300 seconds"),
    gate("Routine messaging/search completed unassisted", metrics.routine_unassisted_percent >= 95, metrics.routine_unassisted_percent, ">= 95%"),
    gate("Admin safety tasks completed unassisted", metrics.admin_safety_unassisted_percent >= 90, metrics.admin_safety_unassisted_percent, ">= 90%"),
    gate("No unintended destructive action", unintendedDestructiveActions === 0, unintendedDestructiveActions, "0"),
    gate("Median Single Ease Question", metrics.median_seq >= 5.5, metrics.median_seq, ">= 5.5/7"),
    gate("Mean System Usability Scale", metrics.mean_sus >= 80, metrics.mean_sus, ">= 80"),
    gate("Every role cohort System Usability Scale", Object.values(cohortSus).every((value) => value >= 75), cohortSus, ">= 75 each"),
    gate("Keyboard and screen-reader critical-task completion", metrics.keyboard_critical_completion_percent === 100, metrics.keyboard_critical_completion_percent, "100%"),
    gate("No open critical/serious accessibility finding", openSevereAccessibility.length === 0, openSevereAccessibility.length, "0"),
    gate("No security regression", study.security_regression === false, study.security_regression, "false"),
    gate("No durability regression", study.durability_regression === false, study.durability_regression, "false"),
    gate("Staging qualification passes", study.staging_gates_pass === true, study.staging_gates_pass, "true")
  ];

  return {
    schema_version: 1,
    release_revision: study.release_revision,
    environment: study.environment,
    pass: gates.every(({ pass }) => pass),
    metrics,
    gates
  };
}
function validateStudy(study) {
  if (!study || typeof study !== "object" || Array.isArray(study)) throw new Error("Study evidence must be a JSON object.");
  rejectSensitiveEvidence(study);
  if (study.schema_version !== 1) throw new Error("schema_version must be 1.");
  if (!/^[0-9a-f]{40}$/i.test(study.release_revision || "")) throw new Error("release_revision must be a full 40-character Git SHA.");
  if (typeof study.environment !== "string" || !study.environment.trim()) throw new Error("environment is required.");
  if (!Array.isArray(study.sessions) || study.sessions.length < 12) throw new Error("The validation study requires at least 12 sessions.");
  if (!Array.isArray(study.accessibility_findings)) throw new Error("accessibility_findings must be an array.");

  const memberCount = study.sessions.filter(({ cohort }) => cohort === "member").length;
  const adminCount = study.sessions.filter(({ cohort }) => ["admin", "moderator", "compliance"].includes(cohort)).length;
  const operatorCount = study.sessions.filter(({ cohort }) => cohort === "operator").length;
  const assistiveCount = study.sessions.filter(({ access_method: method }) => assistiveMethods.has(method)).length;
  const mobileFirstCount = study.sessions.filter(({ mobile_first: value }) => value === true).length;
  if (memberCount < 6 || adminCount < 3 || operatorCount < 3) throw new Error("Participant mix requires at least 6 members, 3 admin/moderation/compliance users, and 3 operators.");
  if (assistiveCount < 4) throw new Error("Participant mix requires at least 4 assistive-technology users.");
  if (mobileFirstCount < 2) throw new Error("Participant mix requires at least 2 mobile-first users.");

  study.sessions.forEach((session, sessionIndex) => {
    if (!/^P[0-9A-Za-z_-]+$/.test(session.participant_id || "")) throw new Error(`sessions[${sessionIndex}].participant_id must be a synthetic code beginning with P.`);
    if (!Array.isArray(session.sus_responses) || session.sus_responses.length !== 10 || session.sus_responses.some((value) => !Number.isInteger(value) || value < 1 || value > 5)) {
      throw new Error(`sessions[${sessionIndex}].sus_responses must contain ten integers from 1 to 5.`);
    }
    if (!Array.isArray(session.tasks) || session.tasks.length === 0) throw new Error(`sessions[${sessionIndex}].tasks must not be empty.`);
    session.tasks.forEach((task, taskIndex) => {
      if (typeof task.id !== "string" || !task.id) throw new Error(`sessions[${sessionIndex}].tasks[${taskIndex}].id is required.`);
      if (!["invite", "routine", "admin_safety", "other"].includes(task.category)) throw new Error(`sessions[${sessionIndex}].tasks[${taskIndex}].category is invalid.`);
      if (!allowedOutcomes.has(task.outcome)) throw new Error(`sessions[${sessionIndex}].tasks[${taskIndex}].outcome is invalid.`);
      if (typeof task.duration_seconds !== "number" || task.duration_seconds < 0) throw new Error(`sessions[${sessionIndex}].tasks[${taskIndex}].duration_seconds must be non-negative.`);
      if (typeof task.seq !== "number" || task.seq < 1 || task.seq > 7) throw new Error(`sessions[${sessionIndex}].tasks[${taskIndex}].seq must be from 1 to 7.`);
      if (typeof task.critical !== "boolean" || typeof task.unintended_destructive_action !== "boolean") throw new Error(`sessions[${sessionIndex}].tasks[${taskIndex}] is missing boolean fields.`);
    });
  });

  const categories = new Set(study.sessions.flatMap(({ tasks }) => tasks.map(({ category }) => category)));
  for (const required of ["invite", "routine", "admin_safety"]) {
    if (!categories.has(required)) throw new Error(`Study evidence has no ${required} task receipts.`);
  }
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
