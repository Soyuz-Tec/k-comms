#!/usr/bin/env python3
"""Fail-closed GitHub CI and same-run staging evidence checks before host access."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import os
import re
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener
import zipfile


CI_JOBS = {
    "backend", "web", "validation", "qualification-scripts", "manifests",
    "security", "codeql", "windows-local-release",
}
STAGING_JOB = "Qualify the immutable release in staging / deploy"
MAX_RESPONSE = 2 * 1024 * 1024
MAX_EVIDENCE = 256 * 1024
MAX_STAGING_AGE = timedelta(hours=24)


class GateError(Exception):
    """A safe, non-secret explanation of a failed release gate."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise GateError(message)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHub:
    def __init__(self, repository: str, token: str):
        require(repository.lower() == "soyuz-tec/k-comms", "Unexpected release repository")
        require(bool(token), "GH_TOKEN is required for read-only release verification")
        self.repository = repository
        self.base = f"https://api.github.com/repos/{repository}/"
        self.token = token
        self.opener = build_opener(NoRedirect())

    def request(self, path: str) -> Request:
        return Request(self.base + path, headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {self.token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "k-comms-release-gate",
        })

    @staticmethod
    def bounded_read(response) -> bytes:
        data = response.read(MAX_RESPONSE + 1)
        require(len(data) <= MAX_RESPONSE, "GitHub evidence response exceeds its size limit")
        return data

    def get(self, path: str) -> dict:
        try:
            with self.opener.open(self.request(path), timeout=30) as response:
                document = json.loads(self.bounded_read(response))
            require(isinstance(document, dict), "GitHub returned an invalid evidence object")
            return document
        except (HTTPError, URLError, TimeoutError, ValueError) as error:
            # HTTP errors/redirect URLs may carry credentials; never print them.
            raise GateError("GitHub evidence lookup failed; no host access is permitted") from error

    def artifact(self, artifact_id: int) -> bytes:
        try:
            try:
                self.opener.open(self.request(f"actions/artifacts/{artifact_id}/zip"), timeout=30)
            except HTTPError as redirect:
                try:
                    require(redirect.code == 302, "GitHub did not provide an artifact download redirect")
                    location = redirect.headers.get("Location", "")
                finally:
                    redirect.close()
            else:
                raise GateError("GitHub artifact download did not use the expected redirect")
            parsed = urlparse(location)
            require(parsed.scheme == "https" and bool(parsed.hostname) and not parsed.username
                    and not parsed.password and not parsed.fragment,
                    "GitHub artifact download location is invalid")
            # The signed artifact URL receives NO GitHub Authorization header.
            # Redirects are disabled here as well; a new unexpected hop fails closed.
            with self.opener.open(Request(location), timeout=30) as response:
                return self.bounded_read(response)
        except (HTTPError, URLError, TimeoutError, ValueError) as error:
            raise GateError("GitHub artifact download failed; no host access is permitted") from error


def timestamp(value: object) -> datetime:
    require(isinstance(value, str), "Evidence timestamp is missing")
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise GateError("Evidence timestamp is invalid") from error
    require(result.tzinfo is not None, "Evidence timestamp must include a time zone")
    return result


def page(document: dict, key: str) -> list[dict]:
    items = document.get(key)
    require(isinstance(items, list) and all(isinstance(item, dict) for item in items),
            "GitHub evidence list is invalid")
    # These workflows have fewer than 100 jobs/artifacts. Never silently accept
    # truncated evidence; a future expansion must deliberately add pagination.
    require(document.get("total_count") == len(items) and len(items) <= 100,
            "GitHub evidence is incomplete or exceeds the bounded release contract")
    return items


def run_identity(run: dict, repository: str, revision: str, workflow: str) -> bool:
    return (
        run.get("head_sha") == revision and run.get("head_branch") == "main"
        and run.get("path") == f".github/workflows/{workflow}"
        and run.get("head_repository", {}).get("full_name", "").lower() == repository.lower()
    )


def successful_jobs(client: GitHub, run_id: int, attempt: int, required: set[str]) -> None:
    jobs = page(client.get(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100"), "jobs")
    for name in required:
        matching = [job for job in jobs if job.get("name") == name]
        require(len(matching) == 1 and matching[0].get("status") == "completed"
                and matching[0].get("conclusion") == "success",
                f"Required release job has not succeeded: {name}")


def verify_ci(client: GitHub, revision: str, wait_seconds: int,
              clock=time.monotonic, sleep=time.sleep) -> dict:
    deadline = clock() + wait_seconds
    query = urlencode({"branch": "main", "event": "push", "head_sha": revision, "per_page": 100})
    while True:
        runs = page(client.get(f"actions/workflows/ci.yml/runs?{query}"), "workflow_runs")
        matching = [run for run in runs if run_identity(run, client.repository, revision, "ci.yml")
                    and run.get("event") == "push"]
        if matching:
            require(all(isinstance(run.get("id"), int) for run in matching), "CI run ID is invalid")
            latest = max(matching, key=lambda run: run["id"])
            if latest.get("status") == "completed":
                require(latest.get("conclusion") == "success", "Latest exact-revision main CI did not pass")
                attempt = latest.get("run_attempt")
                require(isinstance(attempt, int) and attempt > 0, "CI attempt is invalid")
                successful_jobs(client, latest["id"], attempt, CI_JOBS)
                return {"run_id": latest["id"], "attempt": attempt}
        remaining = deadline - clock()
        require(remaining > 0, "Exact-revision main CI is missing or incomplete")
        sleep(min(15, remaining))


def staging_document(data: bytes, artifact: dict, revision: str) -> dict:
    digest = "sha256:" + hashlib.sha256(data).hexdigest()
    require(artifact.get("digest") == digest, "Staging artifact digest verification failed")
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            entries = archive.infolist()
            require(len(entries) == 1 and entries[0].filename == f"k-comms-staging-{revision}.json"
                    and entries[0].file_size <= MAX_EVIDENCE,
                    "Staging artifact must contain exactly one bounded release evidence file")
            # Read the exact entry in memory. Never extract archive paths.
            document = json.loads(archive.read(entries[0]))
        require(isinstance(document, dict), "Staging evidence must be an object")
        return document
    except (zipfile.BadZipFile, ValueError, RuntimeError) as error:
        raise GateError("Staging artifact is unreadable") from error


def verify_staging(client: GitHub, revision: str, image: str, run_id: int, attempt: int,
                   now: datetime) -> dict:
    run = client.get(f"actions/runs/{run_id}")
    require(run_identity(run, client.repository, revision, "container.yml")
            and run.get("event") in {"push", "workflow_dispatch"}
            and run.get("run_attempt") == attempt,
            "Production requires the current main Container run; start the complete Container chain")
    successful_jobs(client, run_id, attempt, {STAGING_JOB})
    name = f"k-comms-staging-{revision}-attempt-{attempt}"
    artifacts = page(client.get(f"actions/runs/{run_id}/artifacts?per_page=100"), "artifacts")
    matching = [artifact for artifact in artifacts if artifact.get("name") == name]
    require(len(matching) == 1, "Current-attempt staging artifact is missing or ambiguous")
    artifact = matching[0]
    source = artifact.get("workflow_run", {})
    require(artifact.get("expired") is False and source.get("id") == run_id
            and source.get("head_sha") == revision and source.get("head_branch") == "main"
            and isinstance(artifact.get("id"), int), "Staging artifact provenance is invalid")
    require(timestamp(artifact.get("expires_at")) > now, "Staging artifact has expired")
    require(timestamp(artifact.get("created_at")) >= timestamp(run.get("run_started_at")),
            "Staging artifact predates the current Container attempt")
    document = staging_document(client.artifact(artifact["id"]), artifact, revision)
    require(document.get("schema") == "k-comms-workflow-evidence-v1"
            and document.get("environment") == "staging", "Staging evidence schema/environment is invalid")
    deployment = document.get("deployment", {})
    qualification = document.get("staging_qualification", {})
    backup = document.get("backup", {})
    require(deployment.get("schema") == "k-comms-deployment-receipt-v1"
            and deployment.get("environment") == "staging"
            and deployment.get("revision") == revision and deployment.get("image") == image,
            "Staging deployment does not match the production SHA and digest")
    require(qualification.get("schema") == "k-comms-staging-qualification-receipt-v1"
            and qualification.get("environment") == "staging"
            and qualification.get("revision") == revision and qualification.get("image") == image,
            "Staging qualification does not match the production SHA and digest")
    require(backup.get("complete") is True
            and re.fullmatch(r"[0-9a-f]{64}", str(backup.get("manifest_sha256", ""))) is not None,
            "Staging backup evidence is incomplete")
    for key in ("candidate_deployment_receipt", "final_deployment_receipt", "initial_backup",
                "rollback_receipt", "restore_rehearsal_receipt"):
        require(isinstance(qualification.get(key), str) and bool(qualification[key]),
                f"Staging qualification is missing {key}")
    captured = timestamp(document.get("captured_at"))
    require(now - MAX_STAGING_AGE <= captured <= now + timedelta(minutes=5)
            and captured >= timestamp(run.get("run_started_at")),
            "Staging evidence is stale or outside the current run")
    require(now - MAX_STAGING_AGE <= timestamp(qualification.get("qualified_at"))
            <= min(captured, now) + timedelta(minutes=5),
            "Staging qualification is stale or its timestamp is invalid")
    return {"run_id": run_id, "attempt": attempt, "artifact_id": artifact["id"],
            "artifact_digest": artifact["digest"]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", choices=("staging", "production"), required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--wait-seconds", type=int, default=0)
    args = parser.parse_args()
    try:
        require(re.fullmatch(r"[0-9a-f]{40}", args.revision) is not None, "Invalid release revision")
        require(re.fullmatch(r"ghcr\.io/soyuz-tec/k-comms@sha256:[0-9a-f]{64}", args.image)
                is not None, "Invalid immutable release image")
        require(0 <= args.wait_seconds <= 2100, "CI wait must be between 0 and 2100 seconds")
        client = GitHub(os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GH_TOKEN", ""))
        evidence = {"revision": args.revision, "image": args.image,
                    "ci": verify_ci(client, args.revision, args.wait_seconds)}
        if args.environment == "production":
            evidence["staging"] = verify_staging(
                client, args.revision, args.image, int(os.environ["GITHUB_RUN_ID"]),
                int(os.environ["GITHUB_RUN_ATTEMPT"]), datetime.now(timezone.utc),
            )
        print("Release gates passed: " + json.dumps(evidence, sort_keys=True))
    except (GateError, KeyError, ValueError, TypeError, AttributeError) as error:
        message = str(error) if isinstance(error, GateError) else "Malformed release gate context/evidence"
        raise SystemExit("Release gate rejected: " + message) from None


if __name__ == "__main__":
    main()
