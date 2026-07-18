import assert from "node:assert/strict";
import test from "node:test";
import { scorePilot } from "./score_usability_pilot.mjs";

test("passes a complete two-week pilot receipt", () => {
  const result = scorePilot(passingPilot());
  assert.equal(result.pass, true);
  assert.equal(result.metrics.elapsed_days, 14);
  assert.equal(result.metrics.activation_percent, 88);
  assert.equal(result.metrics.minimum_weekly_active_percent, 60);
  assert.equal(result.metrics.usability_support_requests_per_active_user, 0.15);
  assert.deepEqual(result.metrics.approved_signoff_roles, ["product", "accessibility", "security", "operations"]);
});

test("passes contiguous weekly coverage with a partial trailing interval", () => {
  const pilot = passingPilot();
  pilot.pilot_completed_on = "2025-07-16";
  pilot.weekly_activity.push({ week_started_on: "2025-07-15", active_user_count: 15 });
  for (const receipt of Object.values(pilot.signoffs)) receipt.approved_on = "2025-07-16";
  const result = scorePilot(pilot);
  assert.equal(result.pass, true);
  assert.equal(result.metrics.elapsed_days, 15);
  assert.deepEqual(
    result.metrics.weekly_activity.map(({ week_started_on: weekStartedOn }) => weekStartedOn),
    ["2025-07-01", "2025-07-08", "2025-07-15"]
  );
});

test("rejects an omitted trailing weekly receipt", () => {
  const pilot = passingPilot();
  pilot.pilot_completed_on = "2025-07-22";
  for (const receipt of Object.values(pilot.signoffs)) receipt.approved_on = "2025-07-22";
  assert.throws(() => scorePilot(pilot), /must contain exactly 3 contiguous receipts/);
});

test("rejects gaps and cherry-picked weekly receipt dates", () => {
  const pilot = passingPilot();
  pilot.weekly_activity[1].week_started_on = "2025-07-15";
  assert.throws(() => scorePilot(pilot), /weekly_activity\[1\]\.week_started_on must be 2025-07-08/);
});

test("rejects a pilot completion date in the future", () => {
  const pilot = passingPilot();
  pilot.pilot_completed_on = "2999-01-01";
  assert.throws(() => scorePilot(pilot), /pilot_completed_on must not be in the future/);
});

test("rejects an approved sign-off date in the future", () => {
  const pilot = passingPilot();
  pilot.signoffs.product.approved_on = "2999-01-01";
  assert.throws(() => scorePilot(pilot), /signoffs\.product\.approved_on must not be in the future/);
});

test("fails pilots shorter than 14 elapsed days", () => {
  const pilot = passingPilot();
  pilot.pilot_completed_on = "2025-07-14";
  for (const receipt of Object.values(pilot.signoffs)) receipt.approved_on = "2025-07-14";
  const result = scorePilot(pilot);
  assert.equal(result.pass, false);
  assert.equal(result.gates.find(({ name }) => name === "Pilot elapsed time")?.pass, false);
});

test("enforces activation, every-week activity, and support-rate thresholds", () => {
  const pilot = passingPilot();
  pilot.activated_user_count = 19;
  pilot.active_user_count = 19;
  pilot.weekly_activity[1].active_user_count = 14;
  pilot.usability_support_request_count = 4;
  const result = scorePilot(pilot);
  assert.equal(result.pass, false);
  assert.equal(result.gates.find(({ name }) => name === "Invited-user activation")?.pass, false);
  assert.equal(result.gates.find(({ name }) => name === "Weekly active usage")?.pass, false);
  assert.equal(result.gates.find(({ name }) => name === "Usability support requests per active user")?.pass, false);
});

test("enforces representation, zero-harm outcomes, formal-study linkage, and every sign-off", () => {
  const pilot = passingPilot();
  pilot.tenant_admin_count = 1;
  pilot.trained_operator_count = 1;
  pilot.accessibility_blocker_count = 1;
  pilot.sev1_incident_count = 1;
  pilot.sev2_incident_count = 1;
  pilot.acknowledged_message_loss_count = 1;
  pilot.tenant_boundary_failure_count = 1;
  pilot.formal_study_passed = false;
  pilot.formal_study_receipt_reference = null;
  pilot.signoffs.security = { status: "not_approved", approved_on: null, evidence_reference: null };
  const result = scorePilot(pilot);
  assert.equal(result.pass, false);
  for (const gateName of [
    "Tenant administrator representation",
    "Trained operator representation",
    "No accessibility blocker",
    "No Sev-1 incident",
    "No Sev-2 incident",
    "No acknowledged-message loss",
    "No tenant-boundary failure",
    "Formal usability study passed",
    "Security sign-off retained"
  ]) assert.equal(result.gates.find(({ name }) => name === gateName)?.pass, false, gateName);
});

test("rejects impossible counts, duplicate weekly receipts, and premature approval metadata", () => {
  const impossible = passingPilot();
  impossible.activated_user_count = 26;
  assert.throws(() => scorePilot(impossible), /cannot exceed invited_user_count/);

  const duplicateWeek = passingPilot();
  duplicateWeek.weekly_activity[1].week_started_on = duplicateWeek.weekly_activity[0].week_started_on;
  assert.throws(() => scorePilot(duplicateWeek), /week_started_on must be unique/);

  const prematureApproval = passingPilot();
  prematureApproval.signoffs.product.approved_on = "2025-07-14";
  assert.throws(() => scorePilot(prematureApproval), /must be on or after pilot_completed_on/);
});

test("rejects privacy-sensitive and unknown pilot evidence", () => {
  const sensitive = passingPilot();
  sensitive.email_address = "person@example.test";
  assert.throws(() => scorePilot(sensitive), /Sensitive field/);

  const unknown = passingPilot();
  unknown.user_identifiers = ["not-allowed"];
  assert.throws(() => scorePilot(unknown), /not allowed by pilot evidence schema v1/);
});

test("reports empty aggregate denominators as failed gates without non-JSON numbers", () => {
  const pilot = passingPilot();
  pilot.invited_user_count = 0;
  pilot.activated_user_count = 0;
  pilot.active_user_count = 0;
  pilot.tenant_admin_count = 0;
  pilot.trained_operator_count = 0;
  pilot.weekly_activity.forEach((week) => { week.active_user_count = 0; });
  pilot.usability_support_request_count = 0;
  const result = scorePilot(pilot);
  assert.equal(result.pass, false);
  assert.equal(result.metrics.activation_percent, null);
  assert.equal(result.metrics.minimum_weekly_active_percent, null);
  assert.equal(result.metrics.usability_support_requests_per_active_user, null);
  assert.doesNotThrow(() => JSON.stringify(result));
});

function passingPilot() {
  return {
    schema_version: 1,
    release_revision: "b".repeat(40),
    environment: "internal-staging",
    pilot_started_on: "2025-07-01",
    pilot_completed_on: "2025-07-15",
    formal_study_passed: true,
    formal_study_receipt_reference: "USABILITY-STUDY-TEST-001",
    staging_gates_pass: true,
    invited_user_count: 25,
    activated_user_count: 22,
    active_user_count: 20,
    tenant_admin_count: 2,
    trained_operator_count: 2,
    weekly_activity: [
      { week_started_on: "2025-07-01", active_user_count: 16 },
      { week_started_on: "2025-07-08", active_user_count: 15 }
    ],
    usability_support_request_count: 3,
    accessibility_blocker_count: 0,
    sev1_incident_count: 0,
    sev2_incident_count: 0,
    acknowledged_message_loss_count: 0,
    tenant_boundary_failure_count: 0,
    signoffs: Object.fromEntries(["product", "accessibility", "security", "operations"].map((role) => [role, {
      status: "approved",
      approved_on: "2025-07-15",
      evidence_reference: `${role.toUpperCase()}-APPROVAL-TEST-001`
    }]))
  };
}
