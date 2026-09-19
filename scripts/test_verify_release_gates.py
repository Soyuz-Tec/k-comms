#!/usr/bin/env python3
"""Behavior tests for the exact-revision CI and staging artifact trust boundary."""

from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
from io import BytesIO
import json
import unittest
from urllib.error import HTTPError
from unittest.mock import Mock
import zipfile

from verify_release_gates import (
    CI_JOBS, GateError, GitHub, STAGING_JOB, page, verify_ci, verify_staging,
)


REPOSITORY = "Soyuz-Tec/k-comms"
REVISION = "a" * 40
IMAGE = "ghcr.io/soyuz-tec/k-comms@sha256:" + "b" * 64
NOW = datetime(2026, 9, 19, 12, tzinfo=timezone.utc)


def stamp(value):
    return value.isoformat().replace("+00:00", "Z")


def workflow(workflow_file="ci.yml", run_id=100):
    return {
        "id": run_id, "run_attempt": 1, "head_sha": REVISION, "head_branch": "main",
        "path": ".github/workflows/" + workflow_file, "event": "push",
        "head_repository": {"full_name": REPOSITORY}, "status": "completed",
        "conclusion": "success", "run_started_at": stamp(NOW - timedelta(hours=1)),
    }


def jobs(names):
    result = [{"name": name, "status": "completed", "conclusion": "success"} for name in names]
    return {"total_count": len(result), "jobs": result}


class FakeGitHub:
    repository = REPOSITORY

    def __init__(self):
        self.ci_runs = [workflow()]
        self.ci_jobs = jobs(CI_JOBS)
        self.container = workflow("container.yml", 200)
        self.staging_jobs = jobs({STAGING_JOB})
        self.document = {
            "schema": "k-comms-workflow-evidence-v1", "environment": "staging",
            "captured_at": stamp(NOW - timedelta(minutes=10)),
            "deployment": {"schema": "k-comms-deployment-receipt-v1", "environment": "staging",
                           "revision": REVISION, "image": IMAGE},
            "backup": {"complete": True, "manifest_sha256": "c" * 64},
            "staging_qualification": {
                "schema": "k-comms-staging-qualification-receipt-v1", "environment": "staging",
                "revision": REVISION, "image": IMAGE, "qualified_at": stamp(NOW - timedelta(minutes=15)),
                "candidate_deployment_receipt": "/synthetic/candidate.json",
                "final_deployment_receipt": "/synthetic/final.json", "initial_backup": "/synthetic/backup",
                "rollback_receipt": "/synthetic/rollback.json", "restore_rehearsal_receipt": "/synthetic/restore.json",
            },
            "staging_reboot": {
                "schema": "k-comms-staging-reboot-receipt-v1", "environment": "staging",
                "revision": REVISION, "image": IMAGE, "request_id": "11111111-1111-1111-1111-111111111111",
                "previous_boot_id": "22222222-2222-2222-2222-222222222222",
                "boot_id": "33333333-3333-3333-3333-333333333333",
                "verified_at": stamp(NOW - timedelta(minutes=12)), "readiness_verified": True,
                "timers_verified": True, "service_environments_verified": True,
            },
        }
        self.artifacts = [{
            "id": 300, "name": f"k-comms-staging-{REVISION}-attempt-1", "expired": False,
            "created_at": stamp(NOW - timedelta(minutes=5)), "expires_at": stamp(NOW + timedelta(days=1)),
            "workflow_run": {"id": 200, "head_sha": REVISION, "head_branch": "main"},
        }]
        self.repack()

    def repack(self, filename=None):
        stream = BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            archive.writestr(filename or f"k-comms-staging-{REVISION}.json", json.dumps(self.document))
        self.archive = stream.getvalue()
        self.artifacts[0]["digest"] = "sha256:" + hashlib.sha256(self.archive).hexdigest()

    def get(self, path):
        if path.startswith("actions/workflows/ci.yml/runs?"):
            return {"total_count": len(self.ci_runs), "workflow_runs": deepcopy(self.ci_runs)}
        if path == "actions/runs/100/attempts/1/jobs?per_page=100":
            return deepcopy(self.ci_jobs)
        if path == "actions/runs/200":
            return deepcopy(self.container)
        if path == "actions/runs/200/attempts/1/jobs?per_page=100":
            return deepcopy(self.staging_jobs)
        if path == "actions/runs/200/artifacts?per_page=100":
            return {"total_count": len(self.artifacts), "artifacts": deepcopy(self.artifacts)}
        raise AssertionError("Unexpected API request: " + path)

    def artifact(self, artifact_id):
        assert artifact_id == 300
        return self.archive


class CIGateTest(unittest.TestCase):
    def test_exact_main_push_ci_and_every_required_job_must_pass(self):
        self.assertEqual(verify_ci(FakeGitHub(), REVISION, 0), {"run_id": 100, "attempt": 1})

    def test_wrong_sha_branch_repository_workflow_or_event_cannot_satisfy_ci(self):
        for key, value in (("head_sha", "c" * 40), ("head_branch", "feature"),
                           ("path", ".github/workflows/other.yml"), ("event", "pull_request"),
                           ("head_repository", {"full_name": "other/repo"})):
            with self.subTest(key=key):
                client = FakeGitHub()
                client.ci_runs[0][key] = value
                with self.assertRaises(GateError):
                    verify_ci(client, REVISION, 0)

    def test_latest_failure_or_cancel_cannot_reuse_an_earlier_success(self):
        for conclusion in ("failure", "cancelled", "skipped", "neutral", "timed_out"):
            with self.subTest(conclusion=conclusion):
                client = FakeGitHub()
                newer = {**workflow(run_id=101), "conclusion": conclusion}
                client.ci_runs.append(newer)
                with self.assertRaisesRegex(GateError, "did not pass"):
                    verify_ci(client, REVISION, 0)

    def test_missing_or_skipped_required_job_blocks_successful_workflow(self):
        for status in ("skipped", "failure", "cancelled"):
            client = FakeGitHub()
            client.ci_jobs["jobs"][0]["conclusion"] = status
            with self.assertRaises(GateError):
                verify_ci(client, REVISION, 0)
        client.ci_jobs = jobs(CI_JOBS - {"web"})
        with self.assertRaises(GateError):
            verify_ci(client, REVISION, 0)

    def test_pending_ci_waits_until_success(self):
        client = FakeGitHub()
        client.ci_runs[0]["status"] = "in_progress"
        slept = []

        def finish(seconds):
            slept.append(seconds)
            client.ci_runs[0]["status"] = "completed"

        self.assertEqual(verify_ci(client, REVISION, 30, clock=lambda: 0, sleep=finish)["run_id"], 100)
        self.assertEqual(slept, [15])

    def test_absent_ci_times_out_and_truncated_evidence_is_rejected(self):
        client = FakeGitHub()
        client.ci_runs = []
        with self.assertRaises(GateError):
            verify_ci(client, REVISION, 0)
        with self.assertRaises(GateError):
            page({"total_count": 101, "jobs": []}, "jobs")


class StagingGateTest(unittest.TestCase):
    def verify(self, client):
        return verify_staging(client, REVISION, IMAGE, 200, 1, NOW)

    def test_same_run_attempt_qualified_sha_digest_passes(self):
        self.assertEqual(self.verify(FakeGitHub())["artifact_id"], 300)

    def test_direct_or_foreign_or_previous_attempt_production_entrypoint_is_rejected(self):
        for key, value in (("path", ".github/workflows/deploy-proxmox.yml"),
                           ("head_sha", "c" * 40), ("head_branch", "feature"),
                           ("run_attempt", 2), ("event", "pull_request")):
            with self.subTest(key=key):
                client = FakeGitHub()
                client.container[key] = value
                with self.assertRaisesRegex(GateError, "complete Container chain"):
                    self.verify(client)

    def test_staging_job_must_have_succeeded_in_current_attempt(self):
        client = FakeGitHub()
        client.staging_jobs["jobs"][0]["conclusion"] = "failure"
        with self.assertRaises(GateError):
            self.verify(client)

    def test_missing_duplicate_old_attempt_or_foreign_artifact_fails(self):
        for change in ("missing", "duplicate", "attempt", "run", "sha", "expired"):
            with self.subTest(change=change):
                client = FakeGitHub()
                if change == "missing":
                    client.artifacts = []
                elif change == "duplicate":
                    client.artifacts *= 2
                elif change == "attempt":
                    client.artifacts[0]["name"] = f"k-comms-staging-{REVISION}-attempt-2"
                elif change == "run":
                    client.artifacts[0]["workflow_run"]["id"] = 199
                elif change == "sha":
                    client.artifacts[0]["workflow_run"]["head_sha"] = "c" * 40
                else:
                    client.artifacts[0]["expired"] = True
                with self.assertRaises(GateError):
                    self.verify(client)

    def test_digest_tampering_and_unexpected_archive_path_fail(self):
        client = FakeGitHub()
        client.archive += b"tampered"
        with self.assertRaisesRegex(GateError, "digest"):
            self.verify(client)
        client.repack("../../unexpected.json")
        with self.assertRaisesRegex(GateError, "exactly one"):
            self.verify(client)

    def test_deployment_and_qualification_must_both_match_image_and_revision(self):
        for section in ("deployment", "staging_qualification"):
            for key, value in (("revision", "c" * 40), ("image", IMAGE[:-1] + "c"), ("environment", "production")):
                with self.subTest(section=section, key=key):
                    client = FakeGitHub()
                    client.document[section][key] = value
                    client.repack()
                    with self.assertRaises(GateError):
                        self.verify(client)

    def test_backup_restore_and_rollback_evidence_are_mandatory(self):
        for change in ("backup", "manifest", "restore_rehearsal_receipt", "rollback_receipt"):
            client = FakeGitHub()
            if change == "backup":
                client.document["backup"]["complete"] = False
            elif change == "manifest":
                client.document["backup"]["manifest_sha256"] = "invalid"
            else:
                client.document["staging_qualification"].pop(change)
            client.repack()
            with self.assertRaises(GateError):
                self.verify(client)

    def test_stale_future_or_previous_run_capture_fails(self):
        for offset in (timedelta(days=-2), timedelta(minutes=10), timedelta(hours=-2)):
            client = FakeGitHub()
            client.document["captured_at"] = stamp(NOW + offset)
            client.repack()
            with self.assertRaises(GateError):
                self.verify(client)

    def test_new_capture_cannot_refresh_old_or_future_qualification(self):
        for offset in (timedelta(days=-2), timedelta(minutes=10)):
            client = FakeGitHub()
            client.document["staging_qualification"]["qualified_at"] = stamp(NOW + offset)
            client.repack()
            with self.assertRaises(GateError):
                self.verify(client)

    def test_reboot_evidence_requires_identity_readiness_and_current_attempt(self):
        for key, value in (("revision", "d" * 40), ("image", IMAGE + "wrong"),
                           ("environment", "production"), ("readiness_verified", False),
                           ("timers_verified", False), ("service_environments_verified", False),
                           ("request_id", "invalid"),
                           ("boot_id", "22222222-2222-2222-2222-222222222222"),
                           ("verified_at", stamp(NOW - timedelta(hours=2)))):
            client = FakeGitHub()
            client.document["staging_reboot"][key] = value
            client.repack()
            with self.assertRaises(GateError):
                self.verify(client)
        client = FakeGitHub()
        client.document.pop("staging_reboot")
        client.repack()
        with self.assertRaises(GateError):
            self.verify(client)


class CredentialBoundaryTest(unittest.TestCase):
    def test_artifact_redirect_never_receives_github_authorization(self):
        client = GitHub(REPOSITORY, "test-token-never-log")
        signed_url = "https://example.blob.core.windows.net/artifact?signature=synthetic"
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = b"synthetic zip"
        client.opener = Mock()
        client.opener.open.side_effect = [
            HTTPError(client.base + "actions/artifacts/300/zip", 302, "redirect", {"Location": signed_url}, None),
            response,
        ]
        self.assertEqual(client.artifact(300), b"synthetic zip")
        first, second = [call.args[0] for call in client.opener.open.call_args_list]
        self.assertEqual(first.get_header("Authorization"), "Bearer test-token-never-log")
        self.assertIsNone(second.get_header("Authorization"))

    def test_unavailable_api_errors_are_redacted(self):
        client = GitHub(REPOSITORY, "test-token-never-log")
        client.opener = Mock()
        client.opener.open.side_effect = HTTPError("https://host/?secret=synthetic", 403, "sensitive", {}, None)
        with self.assertRaises(GateError) as failure:
            client.get("actions/runs/100")
        self.assertNotIn("secret", str(failure.exception))
        self.assertNotIn("sensitive", str(failure.exception))


if __name__ == "__main__":
    unittest.main()
