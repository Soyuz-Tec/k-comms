import assert from "node:assert/strict";
import test from "node:test";
import { scoreStudy } from "./score_usability_study.mjs";

test("passes a complete study that satisfies every release gate", () => {
  const result = scoreStudy(passingStudy());
  assert.equal(result.pass, true);
  assert.equal(result.metrics.participant_count, 12);
  assert.equal(result.metrics.mean_sus, 100);
  assert.equal(result.metrics.keyboard_critical_completion_percent, 100);
});

test("fails the score without discarding valid evidence", () => {
  const study = passingStudy();
  study.sessions[0].tasks[0].outcome = "failed";
  study.sessions[1].tasks[0].outcome = "failed";
  const result = scoreStudy(study);
  assert.equal(result.pass, false);
  assert.equal(result.gates.find(({ name }) => name.startsWith("Invite-to-first-message completed"))?.pass, false);
});

test("rejects privacy-sensitive fields", () => {
  const study = passingStudy();
  study.sessions[0].email = "participant@example.test";
  assert.throws(() => scoreStudy(study), /Sensitive field/);
});

function passingStudy() {
  const cohorts = ["member", "member", "member", "member", "member", "member", "admin", "moderator", "compliance", "operator", "operator", "operator"];
  const accessMethods = ["keyboard", "screen_reader", "zoom_high_contrast", "voice_touch", "standard", "standard", "standard", "standard", "standard", "standard", "standard", "standard"];
  return {
    schema_version: 1,
    release_revision: "a".repeat(40),
    environment: "internal-staging",
    study_started_on: "2026-07-14",
    study_completed_on: "2026-07-15",
    security_regression: false,
    durability_regression: false,
    staging_gates_pass: true,
    accessibility_findings: [],
    sessions: cohorts.map((cohort, index) => ({
      participant_id: `P${String(index + 1).padStart(2, "0")}`,
      cohort,
      access_method: accessMethods[index],
      mobile_first: index < 2,
      sus_responses: [5, 1, 5, 1, 5, 1, 5, 1, 5, 1],
      tasks: [
        task("invite-first-message", "invite", 180),
        task("history-search", "routine", 45),
        task("admin-access", "admin_safety", 90)
      ]
    }))
  };
}

function task(id, category, durationSeconds) {
  return {
    id,
    category,
    critical: true,
    outcome: "unassisted",
    duration_seconds: durationSeconds,
    seq: 7,
    unintended_destructive_action: false
  };
}
