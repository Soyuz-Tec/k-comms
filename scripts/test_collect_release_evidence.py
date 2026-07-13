from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import tempfile
import unittest
from collections.abc import Sequence
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from collect_release_evidence import (
    CollectorError,
    build_argument_parser,
    collect_release_evidence,
    hash_evidence_files,
    run_command,
    write_json_atomic,
)


HEAD = "1" * 40
IMAGE_ID = "sha256:" + "2" * 64
MANIFEST_DIGEST = "sha256:" + "3" * 64
REPOSITORY_DIGEST = "registry.example.com/k-comms@" + MANIFEST_DIGEST
IMAGE = "registry.example.com/k-comms:release"
NAMESPACE = "k-comms-staging"
FIXED_TIME = datetime(2026, 7, 13, 4, 5, 6, tzinfo=timezone.utc)


class CollectReleaseEvidenceTest(unittest.TestCase):
    def test_collects_revision_bound_non_secret_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            evidence_path = Path(directory) / "qualification.log"
            evidence_path.write_bytes(b"release evidence\n")
            runner = FakeRunner()

            document = collect_release_evidence(
                image=IMAGE,
                namespace=NAMESPACE,
                evidence_specs=[f"qualification={evidence_path}"],
                command_runner=runner,
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

        self.assertEqual(document["schema_version"], 1)
        self.assertEqual(document["collected_at"], "2026-07-13T04:05:06Z")
        self.assertEqual(document["source"]["git"]["revision"], HEAD)
        self.assertFalse(document["source"]["git"]["dirty"])
        self.assertEqual(document["image"]["id"], IMAGE_ID)
        self.assertEqual(document["image"]["manifest_digest"], MANIFEST_DIGEST)
        self.assertEqual(document["image"]["repository_digests"], [REPOSITORY_DIGEST])
        self.assertEqual(
            document["kubernetes"]["deployments"][0]["containers"],
            [{"image": IMAGE, "name": "edge"}],
        )
        self.assertEqual(
            document["kubernetes"]["pods"][0]["containers"][0]["image_id"],
            "docker-pullable://" + REPOSITORY_DIGEST,
        )
        serialized = json.dumps(document, sort_keys=True)
        self.assertNotIn("do-not-retain", serialized)
        self.assertNotIn("PASSWORD", serialized)
        self.assertNotIn("ConfigMap", serialized)
        self.assertNotIn("qualification.log", serialized)
        self.assertEqual(
            set(document["evidence_files"][0]), {"label", "sha256", "size_bytes"}
        )
        self.assertEqual(
            runner.calls,
            [
                ("git", "rev-parse", "HEAD"),
                ("git", "status", "--porcelain=v1", "--untracked-files=normal"),
                ("podman", "image", "inspect", IMAGE),
                ("kubectl", "version", "-o", "json"),
                (
                    "kubectl",
                    "get",
                    "deployments",
                    "--namespace",
                    NAMESPACE,
                    "-o",
                    "json",
                ),
                ("kubectl", "get", "pods", "--namespace", NAMESPACE, "-o", "json"),
                ("git", "rev-parse", "HEAD"),
                ("git", "status", "--porcelain=v1", "--untracked-files=normal"),
            ],
        )

    def test_serialization_omits_network_node_uid_and_owner_identity(self) -> None:
        deployments = deployment_document()
        unrelated_deployment = application_deployment("edge")
        unrelated_deployment["metadata"].update(
            {"name": "unrelated-deployment-sentinel", "uid": "unrelated-deployment-uid"}
        )
        unrelated_deployment["spec"]["selector"]["matchLabels"] = {
            "app.kubernetes.io/component": "telemetry"
        }
        unrelated_deployment["spec"]["template"]["spec"]["containers"] = [
            {"name": "telemetry", "image": "registry.example.com/telemetry:latest"}
        ]
        deployments["items"].append(unrelated_deployment)

        pods = pod_document()
        unrelated_pod = application_pod("edge")
        unrelated_pod["metadata"].update(
            {
                "name": "unrelated-pod-sentinel",
                "uid": "unrelated-pod-uid",
                "labels": {"app.kubernetes.io/component": "telemetry"},
            }
        )
        unrelated_pod["spec"]["containers"] = [
            {"name": "telemetry", "image": "registry.example.com/telemetry:latest"}
        ]
        unrelated_pod["status"]["containerStatuses"] = [
            {
                "name": "telemetry",
                "imageID": "sha256:" + "8" * 64,
                "ready": True,
                "restartCount": 0,
                "state": {"running": {}},
            }
        ]
        pods["items"].append(unrelated_pod)

        document = collect_release_evidence(
            image=IMAGE,
            namespace=NAMESPACE,
            command_runner=FakeRunner(deployments=deployments, pods=pods),
            clock=lambda: FIXED_TIME,
            host_provider=fixed_host_summary,
        )

        serialized = json.dumps(document, sort_keys=True)
        for sentinel in (
            "host-network-sentinel",
            "pod-network-sentinel",
            "node-placement-sentinel",
            "deployment-edge-uid-sentinel",
            "deployment-worker-uid-sentinel",
            "pod-edge-uid-sentinel",
            "pod-worker-uid-sentinel",
            "owner-edge-uid-sentinel",
            "owner-worker-uid-sentinel",
            "unrelated-deployment-sentinel",
            "unrelated-pod-sentinel",
            "unrelated-deployment-uid",
            "unrelated-pod-uid",
        ):
            self.assertNotIn(sentinel, serialized)

        self.assertEqual(len(document["kubernetes"]["deployments"]), 2)
        self.assertEqual(len(document["kubernetes"]["pods"]), 2)
        self.assertEqual(
            set(document["kubernetes"]["deployments"][0]),
            {"containers", "desired_replicas", "generation", "name", "status"},
        )
        self.assertEqual(
            set(document["kubernetes"]["pods"][0]),
            {"containers", "name", "phase", "ready"},
        )
        self.assertEqual(
            set(document["kubernetes"]["pods"][0]["containers"][0]),
            {"image", "image_id", "name", "ready", "restart_count", "state"},
        )

    def test_accepts_local_and_runtime_prefixed_image_ids(self) -> None:
        for runtime_image_id in (IMAGE_ID, "containerd://" + IMAGE_ID):
            with self.subTest(image_id=runtime_image_id):
                pods = pod_document()
                for pod in pods["items"]:
                    pod["status"]["containerStatuses"][0]["imageID"] = runtime_image_id

                document = collect_release_evidence(
                    image=IMAGE,
                    namespace=NAMESPACE,
                    command_runner=FakeRunner(pods=pods),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

                self.assertEqual(
                    document["kubernetes"]["pods"][0]["containers"][0]["image_id"],
                    runtime_image_id,
                )

    def test_normalizes_a_bare_windows_podman_image_id(self) -> None:
        bare_image_id = IMAGE_ID.removeprefix("sha256:")
        pods = pod_document()
        for pod in pods["items"]:
            pod["status"]["containerStatuses"][0]["imageID"] = IMAGE_ID

        document = collect_release_evidence(
            image=IMAGE,
            namespace=NAMESPACE,
            command_runner=FakeRunner(
                inspected_image_id=bare_image_id,
                pods=pods,
            ),
            clock=lambda: FIXED_TIME,
            host_provider=fixed_host_summary,
        )

        self.assertEqual(document["image"]["id"], IMAGE_ID)

    def test_rejects_malformed_or_nonlocal_inspected_image_ids(self) -> None:
        bare_image_id = IMAGE_ID.removeprefix("sha256:")
        invalid_ids = (
            "2" * 63,
            "2" * 65,
            "A" * 64,
            f" {bare_image_id}",
            f"{bare_image_id}\n",
            "sha512:" + "2" * 64,
            "containerd://" + IMAGE_ID,
            REPOSITORY_DIGEST,
            42,
        )

        for invalid_id in invalid_ids:
            with self.subTest(image_id=invalid_id):
                with self.assertRaisesRegex(
                    CollectorError, "immutable sha256 image ID"
                ):
                    collect_release_evidence(
                        image=IMAGE,
                        namespace=NAMESPACE,
                        command_runner=FakeRunner(inspected_image_id=invalid_id),
                        clock=lambda: FIXED_TIME,
                        host_provider=fixed_host_summary,
                    )

    def test_rejects_a_bare_kubernetes_runtime_image_id(self) -> None:
        pods = pod_document()
        for pod in pods["items"]:
            pod["status"]["containerStatuses"][0]["imageID"] = (
                IMAGE_ID.removeprefix("sha256:")
            )

        with self.assertRaisesRegex(CollectorError, "imageID does not match"):
            collect_release_evidence(
                image=IMAGE,
                namespace=NAMESPACE,
                command_runner=FakeRunner(pods=pods),
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

    def test_rejects_a_deployment_image_mismatch(self) -> None:
        deployments = deployment_document()
        deployments["items"][1]["spec"]["template"]["spec"]["containers"][0][
            "image"
        ] = "registry.example.com/k-comms:stale"

        with self.assertRaisesRegex(CollectorError, "does not use the requested image"):
            collect_release_evidence(
                image=IMAGE,
                namespace=NAMESPACE,
                command_runner=FakeRunner(deployments=deployments),
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

    def test_rejects_an_unready_or_unobserved_application_deployment(self) -> None:
        deployments = deployment_document()
        deployments["items"][0]["status"]["readyReplicas"] = 0

        with self.assertRaisesRegex(CollectorError, "not fully observed and available"):
            collect_release_evidence(
                image=IMAGE,
                namespace=NAMESPACE,
                command_runner=FakeRunner(deployments=deployments),
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

    def test_rejects_a_missing_application_deployment(self) -> None:
        deployments = deployment_document()
        deployments["items"] = [deployments["items"][0]]

        with self.assertRaisesRegex(
            CollectorError, "required application deployment is missing"
        ):
            collect_release_evidence(
                image=IMAGE,
                namespace=NAMESPACE,
                command_runner=FakeRunner(deployments=deployments),
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

    def test_rejects_missing_and_stale_application_pods(self) -> None:
        missing = pod_document()
        missing["items"] = [missing["items"][0]]
        stale = pod_document()
        stale_edge = application_pod(
            "edge",
            image="registry.example.com/k-comms:stale",
            image_id="sha256:" + "9" * 64,
        )
        stale_edge["metadata"]["name"] = "k-comms-edge-stale"
        stale_edge["metadata"]["uid"] = "pod-edge-stale-uid"
        stale["items"].append(stale_edge)

        for pods in (missing, stale):
            with self.subTest(pod_count=len(pods["items"])):
                with self.assertRaisesRegex(CollectorError, "replica count"):
                    collect_release_evidence(
                        image=IMAGE,
                        namespace=NAMESPACE,
                        command_runner=FakeRunner(pods=pods),
                        clock=lambda: FIXED_TIME,
                        host_provider=fixed_host_summary,
                    )

    def test_rejects_unclaimed_or_terminating_application_pods(self) -> None:
        unclaimed = pod_document()
        unclaimed_edge = application_pod("edge")
        unclaimed_edge["metadata"].update(
            {
                "name": "unclaimed-edge",
                "uid": "unclaimed-edge-uid",
                "labels": {"app.kubernetes.io/component": "unrelated"},
            }
        )
        unclaimed["items"].append(unclaimed_edge)

        terminating = pod_document()
        terminating["items"][0]["metadata"]["deletionTimestamp"] = (
            "2026-07-13T04:04:00Z"
        )

        cases = (
            (unclaimed, "stale or mixed application pods"),
            (terminating, "stale or terminating application pod"),
        )
        for pods, expected_error in cases:
            with self.subTest(expected_error=expected_error):
                with self.assertRaisesRegex(CollectorError, expected_error):
                    collect_release_evidence(
                        image=IMAGE,
                        namespace=NAMESPACE,
                        command_runner=FakeRunner(pods=pods),
                        clock=lambda: FIXED_TIME,
                        host_provider=fixed_host_summary,
                    )

    def test_rejects_an_unready_or_mismatched_application_pod(self) -> None:
        unready = pod_document()
        unready["items"][0]["status"]["conditions"][0]["status"] = "False"
        mismatched_image = pod_document()
        mismatched_image["items"][1]["spec"]["containers"][0]["image"] = (
            "registry.example.com/k-comms:stale"
        )

        cases = (
            (unready, "not Running and ready"),
            (mismatched_image, "does not use the requested image"),
        )
        for pods, expected_error in cases:
            with self.subTest(expected_error=expected_error):
                with self.assertRaisesRegex(CollectorError, expected_error):
                    collect_release_evidence(
                        image=IMAGE,
                        namespace=NAMESPACE,
                        command_runner=FakeRunner(pods=pods),
                        clock=lambda: FIXED_TIME,
                        host_provider=fixed_host_summary,
                    )

    def test_rejects_a_missing_or_mismatched_pod_image_id(self) -> None:
        mismatched = pod_document()
        mismatched["items"][1]["status"]["containerStatuses"][0]["imageID"] = (
            "sha256:" + "9" * 64
        )
        missing = pod_document()
        del missing["items"][1]["status"]["containerStatuses"][0]["imageID"]

        for pods in (mismatched, missing):
            worker_status = pods["items"][1]["status"]["containerStatuses"][0]
            with self.subTest(image_id_present="imageID" in worker_status):
                with self.assertRaisesRegex(CollectorError, "imageID does not match"):
                    collect_release_evidence(
                        image=IMAGE,
                        namespace=NAMESPACE,
                        command_runner=FakeRunner(pods=pods),
                        clock=lambda: FIXED_TIME,
                        host_provider=fixed_host_summary,
                    )

    def test_rejects_an_image_revision_mismatch(self) -> None:
        runner = FakeRunner(image_revision="4" * 40)

        with self.assertRaisesRegex(CollectorError, "does not exactly match Git HEAD"):
            collect_release_evidence(
                image=IMAGE,
                namespace=NAMESPACE,
                command_runner=runner,
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

        self.assertNotIn(("kubectl", "version", "-o", "json"), runner.calls)

    def test_refuses_a_dirty_tree_without_running_image_or_cluster_inspection(
        self,
    ) -> None:
        runner = FakeRunner(git_status=" M private.env\n")

        with self.assertRaisesRegex(CollectorError, "Git working tree is dirty"):
            collect_release_evidence(
                image=IMAGE,
                namespace=NAMESPACE,
                command_runner=runner,
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

        self.assertEqual(
            runner.calls,
            [
                ("git", "rev-parse", "HEAD"),
                ("git", "status", "--porcelain=v1", "--untracked-files=normal"),
            ],
        )

    def test_allow_dirty_marks_the_diagnostic_override_without_file_names(self) -> None:
        runner = FakeRunner(git_status=" M private.env\n")

        document = collect_release_evidence(
            image=IMAGE,
            namespace=NAMESPACE,
            allow_dirty=True,
            command_runner=runner,
            clock=lambda: FIXED_TIME,
            host_provider=fixed_host_summary,
        )

        self.assertEqual(
            document["source"]["git"],
            {
                "allow_dirty": True,
                "dirty": True,
                "dirty_override_used": True,
                "revision": HEAD,
            },
        )
        self.assertNotIn("private.env", json.dumps(document))

    def test_rejects_secret_like_evidence_labels_before_commands_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            evidence_path = Path(directory) / "value.txt"
            evidence_path.write_text("not retained", encoding="utf-8")
            runner = FakeRunner()

            with self.assertRaisesRegex(CollectorError, "secret-like evidence labels"):
                collect_release_evidence(
                    image=IMAGE,
                    namespace=NAMESPACE,
                    evidence_specs=[f"deployment-token={evidence_path}"],
                    command_runner=runner,
                )

        self.assertEqual(runner.calls, [])

    def test_rejects_concatenated_and_camel_case_secret_like_evidence_labels(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            evidence_path = Path(directory) / "value.txt"
            evidence_path.write_text("not retained", encoding="utf-8")

            for label in ("clientSecret", "dbPassword", "oauthToken", "releaseAPIKey"):
                with self.subTest(label=label):
                    with self.assertRaisesRegex(
                        CollectorError, "secret-like evidence labels"
                    ):
                        hash_evidence_files([f"{label}={evidence_path}"])

    def test_hashes_regular_files_without_retaining_contents(self) -> None:
        content = b"sensitive diagnostic body\n"
        with tempfile.TemporaryDirectory() as directory:
            evidence_path = Path(directory) / "diagnostic.txt"
            evidence_path.write_bytes(content)

            records = hash_evidence_files([f"diagnostic={evidence_path}"])

        self.assertEqual(
            records,
            [
                {
                    "label": "diagnostic",
                    "sha256": hashlib.sha256(content).hexdigest(),
                    "size_bytes": len(content),
                }
            ],
        )
        serialized = json.dumps(records)
        self.assertNotIn(content.decode().strip(), serialized)
        self.assertNotIn("diagnostic.txt", serialized)
        self.assertNotIn(str(Path(directory).resolve()), serialized)

    def test_rejects_missing_evidence_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            missing_path = Path(directory) / "missing.log"
            with self.assertRaisesRegex(CollectorError, "missing or unreadable"):
                hash_evidence_files([f"qualification={missing_path}"])

    def test_rejects_symbolic_link_evidence_files(self) -> None:
        symbolic_link_metadata = os.stat_result(
            (stat.S_IFLNK, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
        with mock.patch(
            "collect_release_evidence.Path.lstat", return_value=symbolic_link_metadata
        ):
            with self.assertRaisesRegex(CollectorError, "regular files"):
                hash_evidence_files(["qualification=link.log"])

    def test_writes_sorted_json_with_a_same_directory_atomic_replace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "nested" / "release-evidence.json"
            replacements: list[tuple[str, str]] = []

            def replace(source: str, destination: str) -> None:
                self.assertTrue(Path(source).is_file())
                self.assertEqual(Path(source).parent, output.parent)
                self.assertFalse(output.exists())
                replacements.append((source, destination))
                os.replace(source, destination)

            write_json_atomic({"z": 1, "a": 2}, output, replace_fn=replace)

            self.assertEqual(len(replacements), 1)
            self.assertEqual(Path(replacements[0][1]), output)
            self.assertEqual(
                output.read_text(encoding="utf-8"), '{\n  "a": 2,\n  "z": 1\n}\n'
            )
            self.assertEqual(list(output.parent.glob("*.tmp")), [])

    def test_rejects_secret_like_image_labels(self) -> None:
        runner = FakeRunner(extra_image_labels={"release.token": "do-not-retain"})

        with self.assertRaisesRegex(CollectorError, "malformed or secret-like label"):
            collect_release_evidence(
                image=IMAGE,
                namespace=NAMESPACE,
                command_runner=runner,
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

    def test_omits_unrelated_image_label_values_even_when_the_key_looks_safe(
        self,
    ) -> None:
        runner = FakeRunner(
            extra_image_labels={
                "com.example.build-note": "credential-that-must-not-appear"
            }
        )

        document = collect_release_evidence(
            image=IMAGE,
            namespace=NAMESPACE,
            command_runner=runner,
            clock=lambda: FIXED_TIME,
            host_provider=fixed_host_summary,
        )

        self.assertNotIn("com.example.build-note", document["image"]["labels"])
        self.assertNotIn("credential-that-must-not-appear", json.dumps(document))

    def test_rejects_credentials_in_an_allowlisted_source_label(self) -> None:
        runner = FakeRunner(
            extra_image_labels={
                "org.opencontainers.image.source": (
                    "https://user:password@github.com/Soyuz-Tec/k-comms"
                )
            }
        )

        with self.assertRaisesRegex(CollectorError, "malformed source label") as raised:
            collect_release_evidence(
                image=IMAGE,
                namespace=NAMESPACE,
                command_runner=runner,
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

        self.assertNotIn("password", str(raised.exception))

    def test_rejects_a_git_state_change_during_collection(self) -> None:
        runner = FakeRunner(ending_revision="5" * 40)

        with self.assertRaisesRegex(CollectorError, "Git state changed"):
            collect_release_evidence(
                image=IMAGE,
                namespace=NAMESPACE,
                command_runner=runner,
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

    def test_redacts_subprocess_stdout_and_stderr_from_command_errors(self) -> None:
        failure = subprocess.CalledProcessError(
            1,
            ["tool"],
            output="stdout-secret-value",
            stderr="stderr-secret-value",
        )
        with mock.patch("subprocess.run", side_effect=failure):
            with self.assertRaises(CollectorError) as raised:
                run_command(("tool", "operation"), "test operation")

        message = str(raised.exception)
        self.assertEqual(message, "required command failed during test operation")
        self.assertNotIn("secret-value", message)

    def test_cli_tool_defaults_are_explicit(self) -> None:
        options = build_argument_parser().parse_args(
            ["--image", IMAGE, "--namespace", NAMESPACE, "--output", "evidence.json"]
        )

        self.assertEqual(options.git_tool, "git")
        self.assertEqual(options.image_tool, "podman")
        self.assertEqual(options.kubectl_tool, "kubectl")


class FakeRunner:
    def __init__(
        self,
        *,
        git_status: str = "",
        image_revision: str = HEAD,
        inspected_image_id: object = IMAGE_ID,
        extra_image_labels: dict[str, str] | None = None,
        ending_revision: str = HEAD,
        ending_status: str | None = None,
        deployments: dict | None = None,
        pods: dict | None = None,
    ) -> None:
        labels = {
            "org.opencontainers.image.revision": image_revision,
            "org.opencontainers.image.source": "https://github.com/Soyuz-Tec/k-comms",
            "org.opencontainers.image.version": "0.3.0",
        }
        labels.update(extra_image_labels or {})
        self.git_revisions = [HEAD + "\n", ending_revision + "\n"]
        self.git_statuses = [
            git_status,
            git_status if ending_status is None else ending_status,
        ]
        self.responses = {
            ("podman", "image", "inspect", IMAGE): json.dumps(
                [
                    {
                        "Config": {"Labels": labels},
                        "Digest": MANIFEST_DIGEST,
                        "Id": inspected_image_id,
                        "RepoDigests": [REPOSITORY_DIGEST],
                    }
                ]
            ),
            ("kubectl", "version", "-o", "json"): json.dumps(
                {
                    "clientVersion": {
                        "gitVersion": "v1.34.3",
                        "gitCommit": "client-commit",
                        "platform": "windows/amd64",
                        "major": "1",
                        "minor": "34",
                    },
                    "serverVersion": {
                        "gitVersion": "v1.34.3+k3s1",
                        "gitCommit": "server-commit",
                        "platform": "linux/amd64",
                        "major": "1",
                        "minor": "34",
                    },
                }
            ),
            (
                "kubectl",
                "get",
                "deployments",
                "--namespace",
                NAMESPACE,
                "-o",
                "json",
            ): json.dumps(
                deployment_document() if deployments is None else deployments
            ),
            (
                "kubectl",
                "get",
                "pods",
                "--namespace",
                NAMESPACE,
                "-o",
                "json",
            ): json.dumps(pod_document() if pods is None else pods),
        }
        self.calls: list[tuple[str, ...]] = []

    def __call__(self, arguments: Sequence[str], operation: str) -> str:
        del operation
        command = tuple(arguments)
        self.calls.append(command)
        if command == ("git", "rev-parse", "HEAD"):
            return self.git_revisions.pop(0)
        if command == (
            "git",
            "status",
            "--porcelain=v1",
            "--untracked-files=normal",
        ):
            return self.git_statuses.pop(0)
        if command not in self.responses:
            raise AssertionError(f"unexpected command shape: {command!r}")
        return self.responses[command]


def deployment_document() -> dict:
    return {
        "apiVersion": "v1",
        "items": [application_deployment("edge"), application_deployment("worker")],
    }


def application_deployment(role: str) -> dict:
    generation = 7 if role == "edge" else 3
    container = {"name": role, "image": IMAGE}
    if role == "edge":
        container["env"] = [{"name": "PASSWORD", "value": "do-not-retain"}]
    return {
        "metadata": {
            "name": f"k-comms-{role}",
            "uid": f"deployment-{role}-uid-sentinel",
            "generation": generation,
        },
        "spec": {
            "replicas": 1,
            "selector": {"matchLabels": {"app.kubernetes.io/component": role}},
            "template": {
                "metadata": {"labels": {"app.kubernetes.io/component": role}},
                "spec": {
                    "containers": [container],
                    "volumes": [
                        {
                            "secret": {"secretName": "do-not-retain"},
                            "name": "credentials",
                        }
                    ],
                },
            },
        },
        "status": {
            "observedGeneration": generation,
            "replicas": 1,
            "updatedReplicas": 1,
            "readyReplicas": 1,
            "availableReplicas": 1,
        },
    }


def pod_document() -> dict:
    return {
        "apiVersion": "v1",
        "items": [application_pod("edge"), application_pod("worker")],
    }


def application_pod(
    role: str,
    *,
    image: str = IMAGE,
    image_id: str = "docker-pullable://" + REPOSITORY_DIGEST,
    phase: str = "Running",
    container_ready: bool = True,
    pod_ready: bool = True,
) -> dict:
    container = {"name": role, "image": image}
    if role == "edge":
        container["envFrom"] = [
            {"secretRef": {"name": "do-not-retain"}},
            {"configMapRef": {"name": "do-not-retain"}},
        ]
    return {
        "metadata": {
            "name": f"k-comms-{role}-abc",
            "uid": f"pod-{role}-uid-sentinel",
            "labels": {"app.kubernetes.io/component": role},
            "ownerReferences": [
                {
                    "controller": True,
                    "kind": "ReplicaSet",
                    "name": f"k-comms-{role}-abc",
                    "uid": f"owner-{role}-uid-sentinel",
                },
            ],
        },
        "spec": {
            "nodeName": "node-placement-sentinel",
            "containers": [container],
        },
        "status": {
            "phase": phase,
            "hostIP": "host-network-sentinel",
            "podIP": "pod-network-sentinel",
            "qosClass": "Burstable",
            "conditions": [
                {"type": "Ready", "status": "True" if pod_ready else "False"}
            ],
            "containerStatuses": [
                {
                    "name": role,
                    "imageID": image_id,
                    "ready": container_ready,
                    "restartCount": 0,
                    "state": {"running": {"startedAt": "2026-07-13T04:00:00Z"}},
                }
            ],
        },
    }


def fixed_host_summary() -> dict:
    return {
        "cpu_count": 8,
        "machine": "AMD64",
        "os_release": "test-release",
        "os_system": "TestOS",
        "os_version": "test-version",
        "processor": "test-processor",
        "total_memory_bytes": 16 * 1024 * 1024 * 1024,
    }


if __name__ == "__main__":
    unittest.main()
