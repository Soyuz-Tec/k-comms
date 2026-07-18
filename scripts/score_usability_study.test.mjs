import assert from "node:assert/strict";
import test from "node:test";
import { scoreStudy } from "./score_usability_study.mjs";

const cohortTasks = {
  member: [
    ["invite-first-message", "invite", true],
    ["channel-collaboration", "routine", true],
    ["attachment-safety", "routine", true],
    ["history-search", "routine", true],
    ["send-recovery", "routine", true],
    ["notification-control", "other", false],
    ["device-revocation", "other", true]
  ],
  admin: [["admin-access", "admin_safety", true]],
  moderator: [["moderation-review", "admin_safety", true]],
  compliance: [["audit-evidence", "admin_safety", false]],
  operator: [["ops-triage", "ops_safety", true]]
};

test("passes a complete v2 study that satisfies quantitative and human evidence gates", () => {
  const result = scoreStudy(passingStudy());
  assert.equal(result.pass, true);
  assert.equal(result.quantitative_pass, true);
  assert.equal(result.metrics.participant_count, 12);
  assert.equal(result.metrics.mean_sus, 100);
  assert.equal(result.metrics.keyboard_critical_completion_percent, 100);
  assert.equal(result.metrics.unresolved_wcag_2_2_a_aa_findings, 0);
});

test("fails a quantitative gate without discarding otherwise valid evidence", () => {
  const study = passingStudy();
  study.sessions[0].tasks[0].outcome = "failed";
  study.sessions[1].tasks[0].outcome = "failed";
  const result = scoreStudy(study);
  assert.equal(result.pass, false);
  assert.equal(result.quantitative_pass, false);
  assert.equal(result.gates.find(({ name }) => name.startsWith("Invite-to-first-message completed"))?.pass, false);
});

test("requires the exact role-specific task and criticality matrix", () => {
  const missingTask = passingStudy();
  missingTask.sessions[0].tasks.pop();
  assert.throws(() => scoreStudy(missingTask), /exactly the 7 tasks assigned to cohort member/);

  const wrongRole = passingStudy();
  wrongRole.sessions[6].tasks[0].id = "ops-triage";
  assert.throws(() => scoreStudy(wrongRole), /not assigned to cohort admin/);

  const wrongCriticality = passingStudy();
  wrongCriticality.sessions[0].tasks[5].critical = true;
  assert.throws(() => scoreStudy(wrongCriticality), /critical must be false for notification-control/);
});

test("rejects false unassisted and assisted claims that contradict error or facilitator receipts", () => {
  const unassistedWithCriticalError = passingStudy();
  unassistedWithCriticalError.sessions[0].tasks[0].critical_errors = 1;
  assert.throws(
    () => scoreStudy(unassistedWithCriticalError),
    /critical_errors must be 0 when outcome is unassisted/
  );

  const unassistedWithHelp = passingStudy();
  unassistedWithHelp.sessions[0].tasks[0].facilitator_interventions = 1;
  assert.throws(
    () => scoreStudy(unassistedWithHelp),
    /facilitator_interventions must be 0 when outcome is unassisted/
  );

  const assistedWithoutHelp = passingStudy();
  assistedWithoutHelp.sessions[0].tasks[0].outcome = "assisted";
  assert.throws(
    () => scoreStudy(assistedWithoutHelp),
    /facilitator_interventions must be at least 1 when outcome is assisted/
  );

  const assistedWithReceipt = passingStudy();
  assistedWithReceipt.sessions[0].tasks[0].outcome = "assisted";
  assistedWithReceipt.sessions[0].tasks[0].facilitator_interventions = 1;
  const result = scoreStudy(assistedWithReceipt);
  assert.equal(result.quantitative_pass, false);
  assert.equal(result.pass, false);
});

test("requires unique participant codes and complete browser, viewport, and access metadata", () => {
  const duplicate = passingStudy();
  duplicate.sessions[1].participant_id = duplicate.sessions[0].participant_id;
  assert.throws(() => scoreStudy(duplicate), /participant_id must be unique/);

  const missingBrowser = passingStudy();
  missingBrowser.sessions[0].browser_name = "";
  assert.throws(() => scoreStudy(missingBrowser), /browser_name is required/);

  const invalidViewport = passingStudy();
  invalidViewport.sessions[0].viewport_width_css_px = 0;
  assert.throws(() => scoreStudy(invalidViewport), /viewport_width_css_px must be an integer/);

  const missingAuthorizationStatus = passingStudy();
  delete missingAuthorizationStatus.authorization_regression;
  assert.throws(() => scoreStudy(missingAuthorizationStatus), /authorization_regression must be boolean/);

  const invalidConfidence = passingStudy();
  invalidConfidence.sessions[0].sensitive_action_confidence = 0;
  assert.throws(() => scoreStudy(invalidConfidence), /sensitive_action_confidence must be an integer/);
});

test("requires valid study dates, explicit manual accessibility evidence, and approval", () => {
  const invalidDate = passingStudy();
  invalidDate.study_completed_on = "2026-02-30";
  assert.throws(() => scoreStudy(invalidDate), /valid calendar date/);

  const humanGateOpen = passingStudy();
  humanGateOpen.manual_accessibility = {
    wcag_2_2_a_aa_status: "not_completed",
    assistive_technology_matrix_status: "not_completed",
    open_a_aa_failures: 0,
    completed_on: null
  };
  humanGateOpen.approver_receipt = {
    status: "not_approved",
    approver_role: "release_approver",
    approved_on: null,
    evidence_reference: null
  };
  const result = scoreStudy(humanGateOpen);
  assert.equal(result.quantitative_pass, true);
  assert.equal(result.pass, false);
  assert.equal(result.gates.find(({ name }) => name === "Manual WCAG 2.2 A/AA audit passed")?.pass, false);
  assert.equal(result.gates.find(({ name }) => name === "Release approver receipt retained")?.pass, false);
});

test("rejects future-dated study completion and release approval using the UTC date boundary", () => {
  const futureCompletion = passingStudy();
  futureCompletion.study_completed_on = utcDateOffset(1);
  assert.throws(
    () => scoreStudy(futureCompletion),
    /study_completed_on must not be in the future relative to the current UTC date/
  );

  const futureApproval = passingStudy();
  futureApproval.approver_receipt.approved_on = utcDateOffset(1);
  assert.throws(
    () => scoreStudy(futureApproval),
    /approver_receipt.approved_on must not be in the future relative to the current UTC date/
  );
});

test("blocks every unresolved WCAG A/AA finding, not only severe findings", () => {
  const study = passingStudy();
  study.accessibility_findings.push({ finding_id: "A11Y-001", standard: "WCAG 2.2 AA", severity: "minor", status: "open" });
  const result = scoreStudy(study);
  assert.equal(result.pass, false);
  assert.equal(result.metrics.open_critical_or_serious_accessibility_findings, 0);
  assert.equal(result.metrics.unresolved_wcag_2_2_a_aa_findings, 1);
});

test("rejects privacy-sensitive and unknown fields", () => {
  const sensitive = passingStudy();
  sensitive.sessions[0].email = "participant@example.test";
  assert.throws(() => scoreStudy(sensitive), /Sensitive field/);

  const unknown = passingStudy();
  unknown.sessions[0].freeform_notes = "not part of the scorecard";
  assert.throws(() => scoreStudy(unknown), /not allowed by usability evidence schema v2/);
});

function passingStudy() {
  const cohorts = ["member", "member", "member", "member", "member", "member", "admin", "moderator", "compliance", "operator", "operator", "operator"];
  const accessMethods = ["keyboard", "screen_reader", "zoom_high_contrast", "voice_touch", "standard", "standard", "standard", "standard", "standard", "standard", "standard", "standard"];
  return {
    schema_version: 2,
    release_revision: "a".repeat(40),
    environment: "internal-staging",
    study_started_on: "2020-01-14",
    study_completed_on: "2020-01-15",
    security_regression: false,
    authorization_regression: false,
    tenant_isolation_regression: false,
    durability_regression: false,
    staging_gates_pass: true,
    manual_accessibility: {
      wcag_2_2_a_aa_status: "passed",
      assistive_technology_matrix_status: "passed",
      open_a_aa_failures: 0,
      completed_on: "2020-01-15"
    },
    accessibility_findings: [],
    approver_receipt: {
      status: "approved",
      approver_role: "release_approver",
      approved_on: "2020-01-15",
      evidence_reference: "APPROVAL-TEST-001"
    },
    sessions: cohorts.map((cohort, index) => ({
      participant_id: `P${String(index + 1).padStart(2, "0")}`,
      cohort,
      access_method: accessMethods[index],
      mobile_first: index < 2,
      browser_name: index % 2 === 0 ? "Edge" : "Firefox",
      browser_version: "test-current",
      viewport_width_css_px: index < 2 ? 390 : 1440,
      viewport_height_css_px: index < 2 ? 844 : 900,
      sus_responses: [5, 1, 5, 1, 5, 1, 5, 1, 5, 1],
      sensitive_action_confidence: 5,
      tasks: cohortTasks[cohort].map(([id, category, critical]) => task(id, category, critical))
    }))
  };
}

function task(id, category, critical) {
  return {
    id,
    category,
    critical,
    outcome: "unassisted",
    duration_seconds: id === "invite-first-message" ? 180 : 60,
    critical_errors: 0,
    backtracks: 0,
    facilitator_interventions: 0,
    seq: 7,
    unintended_destructive_action: false
  };
}

function utcDateOffset(days) {
  const now = new Date();
  const value = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + days));
  return value.toISOString().slice(0, 10);
}
