from __future__ import annotations

import copy
import hashlib
import json
import os
import stat
import subprocess
import tempfile
import unittest
from collections.abc import Sequence
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import yaml

from collect_release_evidence import (
    CollectorError,
    PRODUCTION_CONTROL_RESOURCE_TYPES,
    PROMOTION_RECEIPT_MAX_BYTES,
    PROMOTION_RECEIPT_MAX_AGE_SECONDS,
    REQUIRED_PROMOTION_RECEIPTS,
    _expected_production_controls,
    _load_production_bundle,
    _read_promotion_receipt,
    build_argument_parser,
    collect_release_evidence,
    hash_evidence_files,
    run_command,
    write_json_atomic,
)
from test_validate_production_bundle import find_document, valid_documents


HEAD = "1" * 40
IMAGE_ID = "sha256:" + "2" * 64
MANIFEST_DIGEST = "sha256:" + "3" * 64
REPOSITORY_DIGEST = "registry.example.com/k-comms@" + MANIFEST_DIGEST
IMAGE = "registry.example.com/k-comms:release"
PRODUCTION_IMAGE = REPOSITORY_DIGEST
NAMESPACE = "k-comms-production"
ENVIRONMENT_ID = "production-us-east-1"
CLUSTER_UID = "cluster-uid-sentinel"
NAMESPACE_UID = "namespace-uid-sentinel"
EXPECTED_ENVIRONMENT = {
    "cluster_uid_sha256": hashlib.sha256(CLUSTER_UID.encode()).hexdigest(),
    "id": ENVIRONMENT_ID,
    "namespace": NAMESPACE,
    "namespace_uid_sha256": hashlib.sha256(NAMESPACE_UID.encode()).hexdigest(),
}
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

    def test_rejects_deployment_sidecars_init_and_ephemeral_containers(self) -> None:
        cases = (
            ("containers", "sidecar", "exactly one role container"),
            ("initContainers", "init", "init or ephemeral container"),
            (
                "ephemeralContainers",
                "debugger",
                "init or ephemeral container",
            ),
        )
        for field, name, expected_error in cases:
            with self.subTest(field=field):
                deployments = deployment_document()
                deployments["items"][0]["spec"]["template"]["spec"].setdefault(
                    field, []
                ).append(
                    {
                        "image": "registry.example.com/diagnostics:immutable",
                        "name": name,
                    }
                )

                with self.assertRaisesRegex(CollectorError, expected_error):
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

    def test_rejects_pod_sidecars_init_and_ephemeral_containers(self) -> None:
        cases = (
            ("containers", "sidecar", "exactly one role container"),
            ("initContainers", "init", "init or ephemeral container"),
            (
                "ephemeralContainers",
                "debugger",
                "init or ephemeral container",
            ),
        )
        for field, name, expected_error in cases:
            with self.subTest(field=field):
                pods = pod_document()
                pods["items"][0]["spec"].setdefault(field, []).append(
                    {
                        "image": "registry.example.com/diagnostics:immutable",
                        "name": name,
                    }
                )

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

    def test_production_profile_collects_bound_promotion_receipts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, binding = prepare_production_inputs(directory)
            document = collect_release_evidence(
                image=PRODUCTION_IMAGE,
                namespace=NAMESPACE,
                profile="production",
                environment_id=ENVIRONMENT_ID,
                production_bundle=bundle,
                receipt_specs=receipt_specs,
                command_runner=production_runner(),
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

        promotion = document["promotion"]
        self.assertEqual(promotion["profile"], "production")
        self.assertEqual(promotion["mode"], "final")
        self.assertTrue(promotion["promotion_ready"])
        self.assertEqual(promotion["environment"], EXPECTED_ENVIRONMENT)
        self.assertEqual(promotion["bundle"], binding["promotion"]["bundle"])
        self.assertEqual(promotion["controls"], binding["promotion"]["controls"])
        self.assertEqual(
            promotion["required_receipts"], list(REQUIRED_PROMOTION_RECEIPTS)
        )
        self.assertEqual(
            [receipt["receipt_type"] for receipt in promotion["receipts"]],
            list(REQUIRED_PROMOTION_RECEIPTS),
        )
        for receipt in promotion["receipts"]:
            self.assertEqual(receipt["status"], "passed")
            self.assertEqual(receipt["git_revision"], HEAD)
            self.assertEqual(receipt["image_digest"], MANIFEST_DIGEST)
            self.assertEqual(receipt["bundle_sha256"], promotion["bundle"]["sha256"])
            self.assertEqual(
                receipt["live_controls_sha256"], promotion["controls"]["live_sha256"]
            )
            self.assertRegex(receipt["sha256"], r"^[0-9a-f]{64}$")
            self.assertGreater(receipt["size_bytes"], 0)
        serialized = json.dumps(document)
        self.assertNotIn(directory, serialized)

    def test_production_binding_only_emits_non_promotable_exact_bindings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle = write_production_bundle(directory)
            document = collect_release_evidence(
                image=PRODUCTION_IMAGE,
                namespace=NAMESPACE,
                profile="production",
                environment_id=ENVIRONMENT_ID,
                production_bundle=bundle,
                binding_only=True,
                command_runner=production_runner(),
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

        promotion = document["promotion"]
        self.assertEqual(promotion["mode"], "binding")
        self.assertFalse(promotion["promotion_ready"])
        self.assertEqual(promotion["receipts"], [])
        self.assertRegex(promotion["bundle"]["sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(promotion["controls"]["live_sha256"], r"^[0-9a-f]{64}$")

    def test_production_profile_requires_an_exact_reviewed_bundle_before_commands(
        self,
    ) -> None:
        runner = production_runner()
        with self.assertRaisesRegex(CollectorError, "requires --production-bundle"):
            collect_release_evidence(
                image=PRODUCTION_IMAGE,
                namespace=NAMESPACE,
                profile="production",
                environment_id=ENVIRONMENT_ID,
                binding_only=True,
                command_runner=runner,
            )
        self.assertEqual(runner.calls, [])

    def test_production_profile_runs_bundle_semantic_preflight_before_commands(
        self,
    ) -> None:
        documents = production_bundle_documents()
        find_document(documents, "ConfigMap", "k-comms-config")["data"][
            "ALLOW_BOOTSTRAP"
        ] = "true"
        with tempfile.TemporaryDirectory() as directory:
            bundle = write_production_bundle(directory, documents)
            runner = production_runner()
            with self.assertRaisesRegex(CollectorError, "semantic preflight failed"):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    binding_only=True,
                    command_runner=runner,
                )
        self.assertEqual(runner.calls, [])

    def test_production_profile_allows_hpa_replica_and_resource_version_churn(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, binding = prepare_production_inputs(directory)
            documents = production_bundle_documents()
            first = live_control_documents(documents, resource_version="100")
            ending = live_control_documents(documents, resource_version="999")
            for name in ("k-comms-edge", "k-comms-worker"):
                ending[("Deployment", name)]["spec"]["replicas"] += 4

            document = collect_release_evidence(
                image=PRODUCTION_IMAGE,
                namespace=NAMESPACE,
                profile="production",
                environment_id=ENVIRONMENT_ID,
                production_bundle=bundle,
                receipt_specs=receipt_specs,
                command_runner=production_runner(
                    live_controls=first,
                    ending_live_controls=ending,
                ),
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

        self.assertTrue(document["promotion"]["promotion_ready"])
        self.assertEqual(
            document["promotion"]["controls"]["live_sha256"],
            binding["promotion"]["controls"]["live_sha256"],
        )

    def test_production_profile_rejects_live_deployment_security_spec_drift(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(directory)
            documents = production_bundle_documents()
            controls = live_control_documents(documents)
            controls[("Deployment", "k-comms-edge")]["spec"]["template"]["spec"][
                "containers"
            ][0]["securityContext"]["readOnlyRootFilesystem"] = False

            with self.assertRaisesRegex(
                CollectorError,
                "live Deployment k-comms-edge does not match the reviewed",
            ):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(live_controls=controls),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

    def test_production_profile_rejects_additive_live_privileged_container(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(directory)
            documents = production_bundle_documents()
            controls = live_control_documents(documents)
            controls[("Deployment", "k-comms-edge")]["spec"]["template"]["spec"][
                "containers"
            ][0]["securityContext"]["privileged"] = True

            with self.assertRaisesRegex(
                CollectorError,
                "live Deployment k-comms-edge does not match the reviewed",
            ):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(live_controls=controls),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

    def test_production_profile_rejects_additive_live_host_network(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(directory)
            documents = production_bundle_documents()
            controls = live_control_documents(documents)
            controls[("Deployment", "k-comms-edge")]["spec"]["template"]["spec"][
                "hostNetwork"
            ] = True

            with self.assertRaisesRegex(
                CollectorError,
                "live Deployment k-comms-edge does not match the reviewed",
            ):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(live_controls=controls),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

    def test_production_profile_rejects_additive_live_command_override(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(directory)
            documents = production_bundle_documents()
            controls = live_control_documents(documents)
            controls[("Deployment", "k-comms-edge")]["spec"]["template"]["spec"][
                "containers"
            ][0]["command"] = ["/bin/true"]

            with self.assertRaisesRegex(
                CollectorError,
                "live Deployment k-comms-edge does not match the reviewed",
            ):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(live_controls=controls),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

    def test_production_profile_accepts_known_kubernetes_workload_defaults(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(directory)
            documents = production_bundle_documents()
            controls = live_control_documents(documents)

            edge = controls[("Deployment", "k-comms-edge")]
            edge["spec"]["progressDeadlineSeconds"] = 600
            edge["spec"]["template"]["metadata"]["creationTimestamp"] = None
            pod_spec = edge["spec"]["template"]["spec"]
            pod_spec.update(
                {
                    "dnsPolicy": "ClusterFirst",
                    "enableServiceLinks": True,
                    "restartPolicy": "Always",
                    "schedulerName": "default-scheduler",
                    "serviceAccount": "k-comms",
                    "terminationGracePeriodSeconds": 30,
                }
            )
            container = pod_spec["containers"][0]
            container.update(
                {
                    "imagePullPolicy": "IfNotPresent",
                    "terminationMessagePath": "/dev/termination-log",
                    "terminationMessagePolicy": "File",
                }
            )
            for probe_name in ("startupProbe", "readinessProbe", "livenessProbe"):
                container[probe_name]["successThreshold"] = 1
                container[probe_name]["httpGet"]["scheme"] = "HTTP"
            next(
                item
                for item in container["env"]
                if item["name"] == "POD_NAMESPACE"
            )["valueFrom"]["fieldRef"]["apiVersion"] = "v1"

            migration = controls[("Job", "k-comms-migrate")]
            migration["spec"].update(
                {
                    "completionMode": "NonIndexed",
                    "completions": 1,
                    "manualSelector": False,
                    "parallelism": 1,
                    "podReplacementPolicy": "TerminatingOrFailed",
                    "selector": {
                        "matchLabels": {
                            "batch.kubernetes.io/controller-uid": "job-controller-uid"
                        }
                    },
                    "suspend": False,
                }
            )
            migration["spec"]["template"]["metadata"]["labels"].update(
                {
                    "batch.kubernetes.io/controller-uid": "job-controller-uid",
                    "batch.kubernetes.io/job-name": "k-comms-migrate",
                }
            )

            edge_service = controls[("Service", "k-comms-edge")]["spec"]
            edge_service.update(
                {
                    "clusterIP": "10.96.0.42",
                    "clusterIPs": ["10.96.0.42"],
                    "internalTrafficPolicy": "Cluster",
                    "ipFamilies": ["IPv4"],
                    "ipFamilyPolicy": "SingleStack",
                    "sessionAffinity": "None",
                    "type": "ClusterIP",
                }
            )
            edge_service["ports"][0]["protocol"] = "TCP"

            cluster_service = controls[("Service", "k-comms-cluster")]["spec"]
            cluster_service.update(
                {
                    "clusterIPs": ["None"],
                    "internalTrafficPolicy": "Cluster",
                    "ipFamilies": ["IPv4"],
                    "ipFamilyPolicy": "SingleStack",
                    "sessionAffinity": "None",
                    "type": "ClusterIP",
                }
            )
            for port in cluster_service["ports"]:
                port["protocol"] = "TCP"

            for hpa_name in ("k-comms-edge", "k-comms-worker"):
                behavior = controls[("HorizontalPodAutoscaler", hpa_name)]["spec"][
                    "behavior"
                ]
                behavior["scaleUp"].update(
                    {
                        "policies": [
                            {"periodSeconds": 15, "type": "Pods", "value": 4},
                            {
                                "periodSeconds": 15,
                                "type": "Percent",
                                "value": 100,
                            },
                        ],
                        "selectPolicy": "Max",
                    }
                )
                behavior["scaleDown"].update(
                    {
                        "policies": [
                            {
                                "periodSeconds": 15,
                                "type": "Percent",
                                "value": 100,
                            }
                        ],
                        "selectPolicy": "Max",
                    }
                )

            evidence = collect_release_evidence(
                image=PRODUCTION_IMAGE,
                namespace=NAMESPACE,
                profile="production",
                environment_id=ENVIRONMENT_ID,
                production_bundle=bundle,
                receipt_specs=receipt_specs,
                command_runner=production_runner(live_controls=controls),
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

        self.assertTrue(evidence["promotion"]["promotion_ready"])

    def test_production_profile_rejects_additive_live_service_external_ips(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(directory)
            documents = production_bundle_documents()
            controls = live_control_documents(documents)
            controls[("Service", "k-comms-edge")]["spec"]["externalIPs"] = [
                "203.0.113.10"
            ]

            with self.assertRaisesRegex(
                CollectorError,
                "live Service k-comms-edge does not match the reviewed",
            ):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(live_controls=controls),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

    def test_production_profile_binds_every_reviewed_safe_resource(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            documents = production_bundle_documents()
            bundle = write_production_bundle(directory, documents)
            runner = production_runner(bundle_documents=documents)

            evidence = collect_release_evidence(
                image=PRODUCTION_IMAGE,
                namespace=NAMESPACE,
                profile="production",
                environment_id=ENVIRONMENT_ID,
                production_bundle=bundle,
                binding_only=True,
                command_runner=runner,
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

        expected = _expected_production_controls(documents, NAMESPACE)
        self.assertEqual(
            evidence["promotion"]["controls"]["resource_count"], len(expected)
        )
        for control in expected:
            kind = control["kind"]
            name = control["metadata"]["name"]
            command = [
                "kubectl",
                "get",
                PRODUCTION_CONTROL_RESOURCE_TYPES[kind],
                name,
            ]
            if control["metadata"].get("namespace"):
                command.extend(("--namespace", NAMESPACE))
            command.extend(("-o", "json"))
            self.assertIn(tuple(command), runner.calls)

    def test_production_profile_rejects_live_database_ca_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(directory)
            documents = production_bundle_documents()
            controls = live_control_documents(documents)
            controls[("ConfigMap", "k-comms-database-ca")]["data"]["ca.crt"] += (
                "\nUNREVIEWED"
            )

            with self.assertRaisesRegex(
                CollectorError,
                "live ConfigMap k-comms-database-ca does not match the reviewed",
            ):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(live_controls=controls),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

    def test_production_profile_rejects_live_ingress_annotation_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(directory)
            documents = production_bundle_documents()
            controls = live_control_documents(documents)
            controls[("Ingress", "k-comms-auth-rate-limit")]["metadata"][
                "annotations"
            ]["nginx.ingress.kubernetes.io/ssl-redirect"] = "false"

            with self.assertRaisesRegex(
                CollectorError,
                "live Ingress k-comms-auth-rate-limit does not match the reviewed",
            ):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(live_controls=controls),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

    def test_production_profile_rejects_live_network_policy_allow_rule(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(directory)
            documents = production_bundle_documents()
            controls = live_control_documents(documents)
            controls[("NetworkPolicy", "k-comms-default-deny")]["spec"][
                "ingress"
            ] = [{}]

            with self.assertRaisesRegex(
                CollectorError,
                "live NetworkPolicy k-comms-default-deny does not match the reviewed",
            ):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(live_controls=controls),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

    def test_production_profile_rejects_live_control_namespace_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(directory)
            documents = production_bundle_documents()
            controls = live_control_documents(documents)
            controls[("Service", "k-comms-edge")]["metadata"][
                "namespace"
            ] = "wrong-namespace"

            with self.assertRaisesRegex(
                CollectorError,
                "live Service k-comms-edge does not match the reviewed",
            ):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(live_controls=controls),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

    def test_production_profile_rejects_live_namespace_policy_label_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(directory)
            documents = production_bundle_documents()
            controls = live_control_documents(documents)
            namespace = controls[("Namespace", NAMESPACE)]
            namespace["metadata"]["labels"][
                "pod-security.kubernetes.io/enforce-version"
            ] = "v1.25"

            with self.assertRaisesRegex(
                CollectorError,
                f"live Namespace {NAMESPACE} does not match the reviewed",
            ):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(live_controls=controls),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

    def test_production_profile_accepts_known_namespace_server_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            documents = production_bundle_documents()
            bundle = write_production_bundle(directory, documents)
            controls = live_control_documents(documents)
            namespace = controls[("Namespace", NAMESPACE)]
            namespace["metadata"]["labels"][
                "kubernetes.io/metadata.name"
            ] = NAMESPACE
            namespace["spec"] = {"finalizers": ["kubernetes"]}
            namespace["status"] = {"phase": "Active"}

            evidence = collect_release_evidence(
                image=PRODUCTION_IMAGE,
                namespace=NAMESPACE,
                profile="production",
                environment_id=ENVIRONMENT_ID,
                production_bundle=bundle,
                binding_only=True,
                command_runner=production_runner(live_controls=controls),
                clock=lambda: FIXED_TIME,
                host_provider=fixed_host_summary,
            )

        self.assertFalse(evidence["promotion"]["promotion_ready"])

    def test_production_profile_rejects_an_incomplete_live_migration_job(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(directory)
            documents = production_bundle_documents()
            controls = live_control_documents(documents)
            controls[("Job", "k-comms-migrate")]["status"] = {
                "active": 1,
                "conditions": [],
                "succeeded": 0,
            }

            with self.assertRaisesRegex(CollectorError, "migration Job is not complete"):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(live_controls=controls),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

    def test_production_profile_requires_a_digest_pinned_image(self) -> None:
        with self.assertRaisesRegex(CollectorError, "digest-pinned image reference"):
            collect_release_evidence(
                image=IMAGE,
                namespace=NAMESPACE,
                profile="production",
                environment_id=ENVIRONMENT_ID,
            )

    def test_production_profile_requires_three_edge_and_two_worker_replicas(
        self,
    ) -> None:
        cases = ((2, 2, "edge", 3), (3, 1, "worker", 2))
        for edge_replicas, worker_replicas, role, minimum in cases:
            with self.subTest(role=role):
                with tempfile.TemporaryDirectory() as directory:
                    bundle, receipt_specs, _binding = prepare_production_inputs(directory)
                    deployments = deployment_document(
                        image=PRODUCTION_IMAGE,
                        edge_replicas=edge_replicas,
                        worker_replicas=worker_replicas,
                    )
                    pods = pod_document(
                        image=PRODUCTION_IMAGE,
                        edge_replicas=edge_replicas,
                        worker_replicas=worker_replicas,
                    )
                    with self.assertRaisesRegex(
                        CollectorError, f"at least {minimum} ready {role} replicas"
                    ):
                        collect_release_evidence(
                            image=PRODUCTION_IMAGE,
                            namespace=NAMESPACE,
                            profile="production",
                            environment_id=ENVIRONMENT_ID,
                            production_bundle=bundle,
                            receipt_specs=receipt_specs,
                            command_runner=FakeRunner(
                                image=PRODUCTION_IMAGE,
                                deployments=deployments,
                                pods=pods,
                            ),
                            clock=lambda: FIXED_TIME,
                            host_provider=fixed_host_summary,
                        )

    def test_production_profile_rejects_a_missing_receipt_before_commands(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(
                directory, omitted={"security"}
            )
            runner = production_runner()
            with self.assertRaisesRegex(
                CollectorError, "missing required promotion receipts: security"
            ):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=runner,
                )
        self.assertEqual(runner.calls, [])

    def test_production_profile_rejects_a_failed_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(
                directory,
                receipt_overrides={"staging_load": {"status": "failed"}},
            )
            with self.assertRaisesRegex(
                CollectorError, "promotion receipt staging_load did not pass"
            ):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

    def test_production_profile_rejects_mismatched_receipt_bindings(self) -> None:
        cases = (
            ({"git_revision": "4" * 40}, "does not match Git HEAD"),
            ({"image_digest": "sha256:" + "5" * 64}, "image digest"),
            (
                {
                    "environment": {
                        **EXPECTED_ENVIRONMENT,
                        "id": "production-us-west-2",
                    }
                },
                "environment identity",
            ),
            (
                {
                    "environment": {
                        **EXPECTED_ENVIRONMENT,
                        "namespace": "other-namespace",
                    }
                },
                "environment identity",
            ),
        )
        for override, expected_error in cases:
            with self.subTest(expected_error=expected_error):
                with tempfile.TemporaryDirectory() as directory:
                    bundle, receipt_specs, _binding = prepare_production_inputs(
                        directory, receipt_overrides={"security": override}
                    )
                    with self.assertRaisesRegex(CollectorError, expected_error):
                        collect_release_evidence(
                            image=PRODUCTION_IMAGE,
                            namespace=NAMESPACE,
                            profile="production",
                            environment_id=ENVIRONMENT_ID,
                            production_bundle=bundle,
                            receipt_specs=receipt_specs,
                            command_runner=production_runner(),
                            clock=lambda: FIXED_TIME,
                            host_provider=fixed_host_summary,
                        )

    def test_production_profile_rejects_a_stale_receipt(self) -> None:
        stale_completed_at = FIXED_TIME - timedelta(
            seconds=PROMOTION_RECEIPT_MAX_AGE_SECONDS + 1
        )
        stale_started_at = stale_completed_at - timedelta(minutes=5)
        overrides = {
            "backup_restore": {
                "completed_at": stale_completed_at.isoformat(
                    timespec="seconds"
                ).replace("+00:00", "Z"),
                "started_at": stale_started_at.isoformat(timespec="seconds").replace(
                    "+00:00", "Z"
                ),
            }
        }
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(
                directory, receipt_overrides=overrides
            )
            with self.assertRaisesRegex(
                CollectorError, "promotion receipt backup_restore is stale"
            ):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

    def test_production_profile_rejects_future_and_oversized_receipts(self) -> None:
        future = (FIXED_TIME + timedelta(seconds=1)).isoformat(
            timespec="seconds"
        ).replace("+00:00", "Z")
        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(
                directory,
                receipt_overrides={"security": {"completed_at": future}},
            )
            with self.assertRaisesRegex(CollectorError, "future completion timestamp"):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

        with tempfile.TemporaryDirectory() as directory:
            bundle, receipt_specs, _binding = prepare_production_inputs(directory)
            security_spec = next(
                specification
                for specification in receipt_specs
                if specification.startswith("security=")
            )
            Path(security_spec.partition("=")[2]).write_bytes(
                b"x" * (PROMOTION_RECEIPT_MAX_BYTES + 1)
            )
            with self.assertRaisesRegex(CollectorError, "receipt security is too large"):
                collect_release_evidence(
                    image=PRODUCTION_IMAGE,
                    namespace=NAMESPACE,
                    profile="production",
                    environment_id=ENVIRONMENT_ID,
                    production_bundle=bundle,
                    receipt_specs=receipt_specs,
                    command_runner=production_runner(),
                    clock=lambda: FIXED_TIME,
                    host_provider=fixed_host_summary,
                )

    def test_rejects_linked_bundle_and_receipt_files(self) -> None:
        symbolic_link_metadata = os.stat_result(
            (stat.S_IFLNK | 0o777, 0, 0, 1, 0, 0, 1, 0, 0, 0)
        )
        with mock.patch(
            "collect_release_evidence.Path.lstat",
            return_value=symbolic_link_metadata,
        ):
            with self.assertRaisesRegex(CollectorError, "stable regular file"):
                _load_production_bundle(Path("linked-production-bundle.yaml"))
            with self.assertRaisesRegex(CollectorError, "must be a regular file"):
                _read_promotion_receipt("security", Path("linked-security.json"))

    def test_rejects_a_receipt_that_changes_during_validation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "security.json"
            receipt.write_text("{}", encoding="utf-8")
            metadata = receipt.stat()
            changed_metadata = SimpleNamespace(
                st_dev=metadata.st_dev,
                st_ino=metadata.st_ino,
                st_mode=metadata.st_mode,
                st_size=metadata.st_size + 1,
                st_mtime_ns=metadata.st_mtime_ns,
            )
            with mock.patch(
                "collect_release_evidence.os.fstat",
                side_effect=[metadata, changed_metadata],
            ):
                with self.assertRaisesRegex(CollectorError, "changed or exceeded"):
                    _read_promotion_receipt("security", receipt)

    def test_cli_tool_defaults_are_explicit(self) -> None:
        options = build_argument_parser().parse_args(
            ["--image", IMAGE, "--namespace", NAMESPACE, "--output", "evidence.json"]
        )

        self.assertEqual(options.git_tool, "git")
        self.assertEqual(options.image_tool, "podman")
        self.assertEqual(options.kubectl_tool, "kubectl")
        self.assertEqual(options.profile, "diagnostic")
        self.assertIsNone(options.environment_id)
        self.assertIsNone(options.production_bundle)
        self.assertFalse(options.binding_only)
        self.assertEqual(options.receipt, [])


class FakeRunner:
    def __init__(
        self,
        *,
        image: str = IMAGE,
        git_status: str = "",
        image_revision: str = HEAD,
        inspected_image_id: object = IMAGE_ID,
        extra_image_labels: dict[str, str] | None = None,
        ending_revision: str = HEAD,
        ending_status: str | None = None,
        deployments: dict | None = None,
        pods: dict | None = None,
        bundle_documents: list[dict] | None = None,
        live_controls: dict[tuple[str, str], dict] | None = None,
        ending_live_controls: dict[tuple[str, str], dict] | None = None,
        cluster_uid: str = CLUSTER_UID,
        namespace_uid: str = NAMESPACE_UID,
        ending_cluster_uid: str | None = None,
        ending_namespace_uid: str | None = None,
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
        bundle_documents = bundle_documents or production_bundle_documents()
        first_controls = live_controls or live_control_documents(bundle_documents)
        last_controls = ending_live_controls or first_controls
        self.namespace_responses = {
            "kube-system": [
                namespace_document("kube-system", cluster_uid),
                namespace_document(
                    "kube-system", ending_cluster_uid or cluster_uid
                ),
            ],
            NAMESPACE: [
                namespace_document(NAMESPACE, namespace_uid),
                namespace_document(
                    NAMESPACE, ending_namespace_uid or namespace_uid
                ),
            ],
        }
        self.control_responses: dict[tuple[str, ...], list[str]] = {}
        for expected in _expected_production_controls(bundle_documents, NAMESPACE):
            kind = expected["kind"]
            name = expected["metadata"]["name"]
            resource_type = PRODUCTION_CONTROL_RESOURCE_TYPES[kind]
            key = (kind, name)
            command_parts = [
                "kubectl",
                "get",
                resource_type,
                name,
            ]
            if expected["metadata"].get("namespace"):
                command_parts.extend(("--namespace", NAMESPACE))
            command_parts.extend(("-o", "json"))
            command = tuple(command_parts)
            self.control_responses[command] = [
                json.dumps(first_controls[key]),
                json.dumps(last_controls[key]),
            ]
        self.responses = {
            ("podman", "image", "inspect", image): json.dumps(
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
        if command[:3] == ("kubectl", "get", "namespace") and command[-2:] == (
            "-o",
            "json",
        ):
            namespace = command[3]
            if namespace not in self.namespace_responses:
                raise AssertionError(f"unexpected namespace identity: {namespace!r}")
            return json.dumps(self.namespace_responses[namespace].pop(0))
        if command in self.control_responses:
            return self.control_responses[command].pop(0)
        if command not in self.responses:
            raise AssertionError(f"unexpected command shape: {command!r}")
        return self.responses[command]


def deployment_document(
    *, image: str = IMAGE, edge_replicas: int = 1, worker_replicas: int = 1
) -> dict:
    return {
        "apiVersion": "v1",
        "items": [
            application_deployment("edge", image=image, replicas=edge_replicas),
            application_deployment("worker", image=image, replicas=worker_replicas),
        ],
    }


def application_deployment(
    role: str, *, image: str = IMAGE, replicas: int = 1
) -> dict:
    generation = 7 if role == "edge" else 3
    container = {"name": role, "image": image}
    if role == "edge":
        container["env"] = [{"name": "PASSWORD", "value": "do-not-retain"}]
    return {
        "metadata": {
            "name": f"k-comms-{role}",
            "uid": f"deployment-{role}-uid-sentinel",
            "generation": generation,
        },
        "spec": {
            "replicas": replicas,
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
            "replicas": replicas,
            "updatedReplicas": replicas,
            "readyReplicas": replicas,
            "availableReplicas": replicas,
        },
    }


def pod_document(
    *, image: str = IMAGE, edge_replicas: int = 1, worker_replicas: int = 1
) -> dict:
    return {
        "apiVersion": "v1",
        "items": [
            *[
                application_pod("edge", image=image, ordinal=ordinal)
                for ordinal in range(edge_replicas)
            ],
            *[
                application_pod("worker", image=image, ordinal=ordinal)
                for ordinal in range(worker_replicas)
            ],
        ],
    }


def application_pod(
    role: str,
    *,
    image: str = IMAGE,
    image_id: str = "docker-pullable://" + REPOSITORY_DIGEST,
    phase: str = "Running",
    container_ready: bool = True,
    pod_ready: bool = True,
    ordinal: int = 0,
) -> dict:
    container = {"name": role, "image": image}
    if role == "edge":
        container["envFrom"] = [
            {"secretRef": {"name": "do-not-retain"}},
            {"configMapRef": {"name": "do-not-retain"}},
        ]
    identity_suffix = "" if ordinal == 0 else f"-{ordinal}"
    return {
        "metadata": {
            "name": f"k-comms-{role}-abc{identity_suffix}",
            "uid": f"pod-{role}-uid-sentinel{identity_suffix}",
            "labels": {"app.kubernetes.io/component": role},
            "ownerReferences": [
                {
                    "controller": True,
                    "kind": "ReplicaSet",
                    "name": f"k-comms-{role}-abc{identity_suffix}",
                    "uid": f"owner-{role}-uid-sentinel{identity_suffix}",
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


def production_bundle_documents() -> list[dict]:
    documents = valid_documents()
    for kind, name in (
        ("Deployment", "k-comms-edge"),
        ("Deployment", "k-comms-worker"),
        ("Job", "k-comms-migrate"),
    ):
        find_document(documents, kind, name)["spec"]["template"]["spec"][
            "containers"
        ][0]["image"] = PRODUCTION_IMAGE
    for name in ("k-comms-edge", "k-comms-worker"):
        container = find_document(documents, "Deployment", name)["spec"]["template"][
            "spec"
        ]["containers"][0]
        container.setdefault("env", []).append(
            {
                "name": "POD_NAMESPACE",
                "valueFrom": {"fieldRef": {"fieldPath": "metadata.namespace"}},
            }
        )
    find_document(documents, "HorizontalPodAutoscaler", "k-comms-edge")["spec"][
        "behavior"
    ] = {
        "scaleDown": {"stabilizationWindowSeconds": 300},
        "scaleUp": {"stabilizationWindowSeconds": 30},
    }
    find_document(documents, "HorizontalPodAutoscaler", "k-comms-worker")["spec"][
        "behavior"
    ] = {
        "scaleDown": {"stabilizationWindowSeconds": 600},
        "scaleUp": {"stabilizationWindowSeconds": 60},
    }
    documents.extend(additional_safe_production_controls())
    return documents


def additional_safe_production_controls() -> list[dict]:
    controls: list[dict] = [
        {
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": {"name": NAMESPACE, "labels": {"environment": "production"}},
        },
        {
            "apiVersion": "v1",
            "kind": "ServiceAccount",
            "metadata": {"name": "k-comms", "namespace": NAMESPACE},
            "automountServiceAccountToken": False,
        },
        {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {"name": "k-comms-edge", "namespace": NAMESPACE},
            "spec": {
                "selector": {"app.kubernetes.io/component": "edge"},
                "ports": [{"name": "http", "port": 4000, "targetPort": "http"}],
            },
        },
        {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {"name": "k-comms-cluster", "namespace": NAMESPACE},
            "spec": {
                "clusterIP": "None",
                "publishNotReadyAddresses": True,
                "selector": {"app.kubernetes.io/name": "k-comms"},
                "ports": [
                    {"name": "epmd", "port": 4369, "targetPort": "epmd"},
                    {
                        "name": "distribution",
                        "port": 9100,
                        "targetPort": "distribution",
                    },
                ],
            },
        },
    ]
    for name in (
        "k-comms",
        "k-comms-auth-rate-limit",
        "k-comms-service-auth-rate-limit",
        "k-comms-socket-rate-limit",
    ):
        controls.append(
            {
                "apiVersion": "networking.k8s.io/v1",
                "kind": "Ingress",
                "metadata": {
                    "name": name,
                    "namespace": NAMESPACE,
                    "annotations": {
                        "nginx.ingress.kubernetes.io/ssl-redirect": "true"
                    },
                },
                "spec": {
                    "ingressClassName": "nginx",
                    "tls": [
                        {
                            "hosts": ["comms.example.com"],
                            "secretName": "k-comms-production-tls",
                        }
                    ],
                    "rules": [{"host": "comms.example.com"}],
                },
            }
        )
    for name in (
        "k-comms-default-deny",
        "k-comms-dns-egress",
        "k-comms-cluster-traffic",
        "k-comms-data-egress",
        "k-comms-external-https-egress",
    ):
        controls.append(
            {
                "apiVersion": "networking.k8s.io/v1",
                "kind": "NetworkPolicy",
                "metadata": {"name": name, "namespace": NAMESPACE},
                "spec": {
                    "podSelector": {
                        "matchLabels": {"app.kubernetes.io/part-of": "k-comms"}
                    },
                    "policyTypes": ["Ingress", "Egress"],
                },
            }
        )
    return controls


def write_production_bundle(directory: str, documents: list[dict] | None = None) -> Path:
    path = Path(directory) / "production-bundle.yaml"
    path.write_text(
        yaml.safe_dump_all(documents or production_bundle_documents(), sort_keys=True),
        encoding="utf-8",
    )
    return path


def namespace_document(name: str, uid: str) -> dict:
    return {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {"name": name, "uid": uid},
    }


def live_control_documents(
    bundle_documents: list[dict], *, resource_version: str = "100"
) -> dict[tuple[str, str], dict]:
    controls: dict[tuple[str, str], dict] = {}
    for expected in _expected_production_controls(bundle_documents, NAMESPACE):
        kind = expected["kind"]
        name = expected["metadata"]["name"]
        document = copy.deepcopy(find_document(bundle_documents, kind, name))
        document.setdefault("metadata", {}).update(
            {
                "generation": 1,
                "resourceVersion": resource_version,
                "uid": f"{kind.lower()}-{name}-uid",
            }
        )
        if kind == "Job" and name == "k-comms-migrate":
            document["status"] = {
                "completionTime": "2026-07-13T03:55:00Z",
                "conditions": [{"type": "Complete", "status": "True"}],
                "succeeded": 1,
            }
        controls[(kind, name)] = document
    return controls


def production_runner(**overrides) -> FakeRunner:
    return FakeRunner(
        image=PRODUCTION_IMAGE,
        deployments=deployment_document(
            image=PRODUCTION_IMAGE, edge_replicas=3, worker_replicas=2
        ),
        pods=pod_document(
            image=PRODUCTION_IMAGE, edge_replicas=3, worker_replicas=2
        ),
        **overrides,
    )


def prepare_production_inputs(
    directory: str,
    *,
    receipt_overrides: dict[str, dict] | None = None,
    omitted: set[str] | None = None,
) -> tuple[Path, list[str], dict]:
    bundle = write_production_bundle(directory)
    binding = collect_release_evidence(
        image=PRODUCTION_IMAGE,
        namespace=NAMESPACE,
        profile="production",
        environment_id=ENVIRONMENT_ID,
        production_bundle=bundle,
        binding_only=True,
        command_runner=production_runner(),
        clock=lambda: FIXED_TIME,
        host_provider=fixed_host_summary,
    )
    receipts = write_promotion_receipts(
        directory,
        binding=binding,
        overrides=receipt_overrides,
        omitted=omitted,
    )
    return bundle, receipts, binding


def write_promotion_receipts(
    directory: str,
    *,
    binding: dict,
    overrides: dict[str, dict] | None = None,
    omitted: set[str] | None = None,
) -> list[str]:
    promotion = binding["promotion"]
    receipt_specs: list[str] = []
    for receipt_type in REQUIRED_PROMOTION_RECEIPTS:
        if receipt_type in (omitted or set()):
            continue
        document = {
            "bundle_sha256": promotion["bundle"]["sha256"],
            "completed_at": (FIXED_TIME - timedelta(minutes=1))
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z"),
            "environment": promotion["environment"],
            "git_revision": HEAD,
            "image_digest": MANIFEST_DIGEST,
            "live_controls_sha256": promotion["controls"]["live_sha256"],
            "receipt_type": receipt_type,
            "schema_version": 1,
            "started_at": (FIXED_TIME - timedelta(minutes=10))
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z"),
            "status": "passed",
        }
        document.update((overrides or {}).get(receipt_type, {}))
        path = Path(directory) / f"{receipt_type}.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        receipt_specs.append(f"{receipt_type}={path}")
    return receipt_specs


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
