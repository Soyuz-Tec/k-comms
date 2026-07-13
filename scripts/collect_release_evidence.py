#!/usr/bin/env python3
"""Collect a bounded, revision-bound release evidence artifact.

The collector intentionally selects a small set of non-secret fields from the
container and Kubernetes APIs. It never serializes command diagnostics,
environment variables, Kubernetes Secret/ConfigMap data, or evidence contents.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import platform
import re
import stat
import subprocess
import sys
import tempfile
from collections.abc import Callable, Mapping, Sequence
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


SCHEMA_VERSION = 1
COMMAND_TIMEOUT_SECONDS = 60
GIT_REVISION = re.compile(r"^[0-9a-f]{40,64}$")
IMAGE_ID = re.compile(r"^sha256:[0-9a-f]{64}$")
REPOSITORY_DIGEST = re.compile(r"^[^\s@]+@sha256:[0-9a-f]{64}$")
EVIDENCE_LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
IMAGE_LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$")
NAMESPACE = re.compile(r"^[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?$")
CONTROL_CHARACTER = re.compile(r"[\x00-\x1f\x7f]")
IMAGE_VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")
VERSION_FIELDS = ("gitVersion", "gitCommit", "platform", "goVersion", "major", "minor")
PERSISTED_IMAGE_LABELS = {
    "org.opencontainers.image.revision",
    "org.opencontainers.image.source",
    "org.opencontainers.image.version",
}
APPLICATION_DEPLOYMENTS = {
    "k-comms-edge": "edge",
    "k-comms-worker": "worker",
}

CommandRunner = Callable[[Sequence[str], str], str]
Clock = Callable[[], datetime]
HostProvider = Callable[[], dict[str, Any]]


class CollectorError(RuntimeError):
    """A safe-to-display, deliberately redacted collection failure."""


def run_command(arguments: Sequence[str], operation: str) -> str:
    """Run one required command without propagating its output in failures."""

    try:
        completed = subprocess.run(
            list(arguments),
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        raise CollectorError(f"required command failed during {operation}") from None

    return completed.stdout


def collect_release_evidence(
    *,
    image: str,
    namespace: str,
    evidence_specs: Sequence[str] = (),
    allow_dirty: bool = False,
    git_tool: str = "git",
    image_tool: str = "podman",
    kubectl_tool: str = "kubectl",
    command_runner: CommandRunner = run_command,
    clock: Clock | None = None,
    host_provider: HostProvider | None = None,
) -> dict[str, Any]:
    """Collect evidence into a deterministic, JSON-serializable structure."""

    _validate_reference(image)
    _validate_namespace(namespace)
    for tool in (git_tool, image_tool, kubectl_tool):
        _validate_tool(tool)

    # Validate and hash local inputs before invoking external tools. This keeps
    # malformed or secret-like evidence labels out of command diagnostics.
    evidence_files = hash_evidence_files(evidence_specs)

    revision, status = _git_snapshot(git_tool, command_runner)
    dirty = bool(status.strip())
    if dirty and not allow_dirty:
        raise CollectorError(
            "Git working tree is dirty; use --allow-dirty only for diagnostics"
        )

    image_record = _collect_image(image_tool, image, revision, command_runner)
    kubernetes_record = _collect_kubernetes(
        kubectl_tool,
        namespace,
        image,
        image_record,
        command_runner,
    )

    ending_revision, ending_status = _git_snapshot(git_tool, command_runner)
    if ending_revision != revision or ending_status != status:
        raise CollectorError(
            "Git state changed while release evidence was being collected"
        )

    now = (clock or (lambda: datetime.now(timezone.utc)))()
    collected_at = _utc_timestamp(now)
    host_record = (host_provider or host_summary)()
    _validate_host_summary(host_record)

    return {
        "collected_at": collected_at,
        "evidence_files": evidence_files,
        "host": host_record,
        "image": image_record,
        "kubernetes": kubernetes_record,
        "schema_version": SCHEMA_VERSION,
        "source": {
            "git": {
                "allow_dirty": bool(allow_dirty),
                "dirty": dirty,
                "dirty_override_used": dirty and bool(allow_dirty),
                "revision": revision,
            }
        },
    }


def hash_evidence_files(specifications: Sequence[str]) -> list[dict[str, Any]]:
    """Validate LABEL=PATH inputs and retain only label, size, and SHA-256."""

    parsed: list[tuple[str, Path]] = []
    labels: set[str] = set()
    for specification in specifications:
        label, separator, raw_path = specification.partition("=")
        if not separator or not EVIDENCE_LABEL.fullmatch(label) or not raw_path:
            raise CollectorError("evidence must use a well-formed LABEL=PATH value")
        if _is_secret_like(label):
            raise CollectorError("secret-like evidence labels are not permitted")
        if label in labels:
            raise CollectorError("evidence labels must be unique")
        if CONTROL_CHARACTER.search(raw_path):
            raise CollectorError("evidence paths must not contain control characters")
        labels.add(label)
        parsed.append((label, Path(raw_path).expanduser()))

    records = [_hash_evidence_file(label, path) for label, path in parsed]
    return sorted(records, key=lambda record: record["label"])


def _hash_evidence_file(label: str, path: Path) -> dict[str, Any]:
    try:
        path_metadata = path.lstat()
        if not stat.S_ISREG(path_metadata.st_mode):
            raise CollectorError(
                "evidence paths must identify regular files, not links or directories"
            )
        resolved_path = path.resolve(strict=True)
        resolved_metadata = resolved_path.lstat()
    except OSError:
        raise CollectorError("an evidence file is missing or unreadable") from None
    if _file_fingerprint(path_metadata) != _file_fingerprint(resolved_metadata):
        raise CollectorError("an evidence file changed before it could be hashed")

    digest = hashlib.sha256()
    size = 0
    try:
        open_flags = (
            os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_CLOEXEC", 0)
        )
        open_flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(resolved_path, open_flags)
        with os.fdopen(descriptor, "rb") as evidence_file:
            before = os.fstat(evidence_file.fileno())
            if _file_fingerprint(resolved_metadata) != _file_fingerprint(before):
                raise CollectorError(
                    "an evidence file changed before it could be hashed"
                )
            for chunk in iter(lambda: evidence_file.read(1024 * 1024), b""):
                digest.update(chunk)
                size += len(chunk)
            after = os.fstat(evidence_file.fileno())
            final_metadata = resolved_path.lstat()
    except CollectorError:
        raise
    except OSError:
        raise CollectorError("an evidence file is missing or unreadable") from None

    fingerprint = _file_fingerprint(before)
    if (
        fingerprint != _file_fingerprint(after)
        or fingerprint != _file_fingerprint(final_metadata)
        or size != after.st_size
    ):
        raise CollectorError("an evidence file changed while it was being hashed")

    return {
        "label": label,
        "sha256": digest.hexdigest(),
        "size_bytes": size,
    }


def _file_fingerprint(metadata: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IFMT(metadata.st_mode),
        metadata.st_size,
        metadata.st_mtime_ns,
    )


def _git_snapshot(git_tool: str, command_runner: CommandRunner) -> tuple[str, str]:
    revision = command_runner((git_tool, "rev-parse", "HEAD"), "Git revision").strip()
    if not GIT_REVISION.fullmatch(revision):
        raise CollectorError("Git returned an invalid HEAD revision")
    status = command_runner(
        (git_tool, "status", "--porcelain=v1", "--untracked-files=normal"),
        "Git working-tree status",
    )
    return revision, status


def _collect_image(
    image_tool: str,
    image: str,
    revision: str,
    command_runner: CommandRunner,
) -> dict[str, Any]:
    document = _load_json(
        command_runner((image_tool, "image", "inspect", image), "image inspection"),
        "image inspection",
    )
    if (
        not isinstance(document, list)
        or len(document) != 1
        or not isinstance(document[0], dict)
    ):
        raise CollectorError("image inspection returned a malformed document")

    inspected = document[0]
    image_id = inspected.get("Id")
    if not isinstance(image_id, str) or not IMAGE_ID.fullmatch(image_id):
        raise CollectorError(
            "image inspection did not return an immutable sha256 image ID"
        )

    config = inspected.get("Config")
    labels_value = config.get("Labels") if isinstance(config, dict) else None
    if labels_value is None:
        labels_value = inspected.get("Labels")
    labels = _validate_image_labels(labels_value)
    if labels.get("org.opencontainers.image.revision") != revision:
        raise CollectorError("image revision label does not exactly match Git HEAD")

    manifest_digest = inspected.get("Digest")
    if manifest_digest in (None, ""):
        manifest_digest = None
    elif not isinstance(manifest_digest, str) or not IMAGE_ID.fullmatch(
        manifest_digest
    ):
        raise CollectorError("image inspection returned a malformed manifest digest")

    repo_digests_value = inspected.get("RepoDigests") or []
    if not isinstance(repo_digests_value, list):
        raise CollectorError("image inspection returned malformed repository digests")
    repo_digests: list[str] = []
    for digest in repo_digests_value:
        if not isinstance(digest, str) or not REPOSITORY_DIGEST.fullmatch(digest):
            raise CollectorError(
                "image inspection returned malformed repository digests"
            )
        repo_digests.append(digest)

    return {
        "id": image_id,
        "labels": labels,
        "manifest_digest": manifest_digest,
        "reference": image,
        "repository_digests": sorted(set(repo_digests)),
    }


def _validate_image_labels(value: Any) -> dict[str, str]:
    if not isinstance(value, dict):
        raise CollectorError("image inspection did not return an image label map")

    labels: dict[str, str] = {}
    for key, label_value in value.items():
        if (
            not isinstance(key, str)
            or not IMAGE_LABEL.fullmatch(key)
            or _is_secret_like(key)
            or not isinstance(label_value, str)
            or len(label_value) > 4096
            or CONTROL_CHARACTER.search(label_value)
        ):
            raise CollectorError(
                "image inspection returned a malformed or secret-like label"
            )
        # Custom labels are not evidence inputs. Ignore their values entirely so
        # an innocuous-looking key cannot smuggle a credential into the artifact.
        if key not in PERSISTED_IMAGE_LABELS:
            continue
        _validate_persisted_image_label(key, label_value)
        labels[key] = label_value

    if "org.opencontainers.image.revision" not in labels:
        raise CollectorError("image revision label is missing")
    return dict(sorted(labels.items()))


def _validate_persisted_image_label(key: str, value: str) -> None:
    if key == "org.opencontainers.image.revision":
        if not GIT_REVISION.fullmatch(value):
            raise CollectorError("image inspection returned a malformed revision label")
        return
    if key == "org.opencontainers.image.version":
        if not IMAGE_VERSION.fullmatch(value) or _is_secret_like(value):
            raise CollectorError("image inspection returned a malformed version label")
        return
    if key == "org.opencontainers.image.source":
        try:
            parsed = urlsplit(value)
            parsed_port = parsed.port
        except ValueError:
            raise CollectorError(
                "image inspection returned a malformed source label"
            ) from None
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed_port not in (None, 443)
            or parsed.query
            or parsed.fragment
        ):
            raise CollectorError("image inspection returned a malformed source label")


def _is_secret_like(label: str) -> bool:
    separated = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "-", label)
    compact = re.sub(r"[^a-z0-9]", "", separated.lower())
    return any(
        term in compact
        for term in (
            "secret",
            "password",
            "passwd",
            "passphrase",
            "token",
            "apikey",
            "credential",
            "privatekey",
            "authorization",
            "cookie",
        )
    )


def _collect_kubernetes(
    kubectl_tool: str,
    namespace: str,
    image: str,
    image_record: Mapping[str, Any],
    command_runner: CommandRunner,
) -> dict[str, Any]:
    version_document = _load_json(
        command_runner((kubectl_tool, "version", "-o", "json"), "Kubernetes version"),
        "Kubernetes version",
    )
    deployments_document = _load_json(
        command_runner(
            (
                kubectl_tool,
                "get",
                "deployments",
                "--namespace",
                namespace,
                "-o",
                "json",
            ),
            "Kubernetes deployment topology",
        ),
        "Kubernetes deployment topology",
    )
    pods_document = _load_json(
        command_runner(
            (kubectl_tool, "get", "pods", "--namespace", namespace, "-o", "json"),
            "Kubernetes pod topology",
        ),
        "Kubernetes pod topology",
    )

    deployments = _select_deployments(deployments_document)
    pods = _select_pods(pods_document)
    claimed_pod_uids = _validate_application_topology(
        deployments_document,
        pods_document,
        deployments,
        pods,
        image,
        image_record,
    )

    return {
        "deployments": _application_deployment_evidence(deployments),
        "namespace": namespace,
        "pods": _application_pod_evidence(pods, claimed_pod_uids),
        "version": _select_kubernetes_version(version_document),
    }


def _select_kubernetes_version(document: Any) -> dict[str, Any]:
    if not isinstance(document, dict):
        raise CollectorError("Kubernetes version response is malformed")
    return {
        "client": _select_version_fields(document.get("clientVersion")),
        "server": _select_version_fields(document.get("serverVersion")),
    }


def _select_version_fields(value: Any) -> dict[str, str]:
    if not isinstance(value, dict) or not isinstance(value.get("gitVersion"), str):
        raise CollectorError("Kubernetes version response is malformed")
    selected: dict[str, str] = {}
    for field in VERSION_FIELDS:
        if field not in value:
            continue
        selected[field] = _bounded_text(value[field], "Kubernetes version response")
    return selected


def _select_deployments(document: Any) -> list[dict[str, Any]]:
    items = _resource_items(document, "Kubernetes deployment topology")
    deployments: list[dict[str, Any]] = []
    for item in items:
        metadata = _required_mapping(
            item.get("metadata"), "Kubernetes deployment topology"
        )
        spec = _required_mapping(item.get("spec"), "Kubernetes deployment topology")
        status_value = item.get("status") or {}
        status_record = _required_mapping(
            status_value, "Kubernetes deployment topology"
        )
        template = _required_mapping(
            spec.get("template"), "Kubernetes deployment topology"
        )
        pod_spec = _required_mapping(
            template.get("spec"), "Kubernetes deployment topology"
        )

        deployments.append(
            {
                "containers": _select_container_specs(
                    pod_spec.get("containers"), "Kubernetes deployment topology"
                ),
                "generation": _optional_integer(
                    metadata.get("generation"), "Kubernetes deployment topology"
                ),
                "init_containers": _select_container_specs(
                    pod_spec.get("initContainers") or [],
                    "Kubernetes deployment topology",
                ),
                "name": _required_name(
                    metadata.get("name"), "Kubernetes deployment topology"
                ),
                "replicas": _optional_integer(
                    spec.get("replicas", 1), "Kubernetes deployment topology"
                ),
                "status": _select_integer_fields(
                    status_record,
                    (
                        "observedGeneration",
                        "replicas",
                        "updatedReplicas",
                        "readyReplicas",
                        "availableReplicas",
                        "unavailableReplicas",
                    ),
                    "Kubernetes deployment topology",
                ),
                "uid": _required_name(
                    metadata.get("uid"), "Kubernetes deployment topology"
                ),
            }
        )

    return sorted(
        deployments, key=lambda deployment: (deployment["name"], deployment["uid"])
    )


def _select_pods(document: Any) -> list[dict[str, Any]]:
    items = _resource_items(document, "Kubernetes pod topology")
    pods: list[dict[str, Any]] = []
    for item in items:
        metadata = _required_mapping(item.get("metadata"), "Kubernetes pod topology")
        spec = _required_mapping(item.get("spec"), "Kubernetes pod topology")
        status_value = item.get("status") or {}
        status_record = _required_mapping(status_value, "Kubernetes pod topology")

        pods.append(
            {
                "containers": _select_pod_containers(
                    spec.get("containers"),
                    status_record.get("containerStatuses") or [],
                    "Kubernetes pod topology",
                ),
                "ephemeral_containers": _select_pod_containers(
                    spec.get("ephemeralContainers") or [],
                    status_record.get("ephemeralContainerStatuses") or [],
                    "Kubernetes pod topology",
                ),
                "host_ip": _optional_text(
                    status_record.get("hostIP"), "Kubernetes pod topology"
                ),
                "init_containers": _select_pod_containers(
                    spec.get("initContainers") or [],
                    status_record.get("initContainerStatuses") or [],
                    "Kubernetes pod topology",
                ),
                "name": _required_name(metadata.get("name"), "Kubernetes pod topology"),
                "node_name": _optional_text(
                    spec.get("nodeName"), "Kubernetes pod topology"
                ),
                "owners": _select_owner_references(
                    metadata.get("ownerReferences") or []
                ),
                "phase": _optional_text(
                    status_record.get("phase"), "Kubernetes pod topology"
                ),
                "pod_ip": _optional_text(
                    status_record.get("podIP"), "Kubernetes pod topology"
                ),
                "qos_class": _optional_text(
                    status_record.get("qosClass"), "Kubernetes pod topology"
                ),
                "uid": _required_name(metadata.get("uid"), "Kubernetes pod topology"),
            }
        )

    return sorted(pods, key=lambda pod: (pod["name"], pod["uid"]))


def _validate_application_topology(
    deployments_document: Any,
    pods_document: Any,
    deployments: Sequence[Mapping[str, Any]],
    pods: Sequence[Mapping[str, Any]],
    image: str,
    image_record: Mapping[str, Any],
) -> set[str]:
    context = "Kubernetes application topology"
    raw_deployments = _resource_items(deployments_document, context)
    raw_pods = _resource_items(pods_document, context)
    accepted_image_ids = _accepted_image_identities(image_record)

    deployment_records = _unique_records_by_key(deployments, "name", context)
    raw_deployment_records = _unique_records_by_nested_key(
        raw_deployments, ("metadata", "name"), context
    )
    pod_records = _unique_records_by_key(pods, "uid", context)
    claimed_pods: dict[str, str] = {}

    for deployment_name, role in APPLICATION_DEPLOYMENTS.items():
        deployment = deployment_records.get(deployment_name)
        raw_deployment = raw_deployment_records.get(deployment_name)
        if deployment is None or raw_deployment is None:
            raise CollectorError("a required application deployment is missing")

        desired_replicas = _validate_application_deployment(deployment, role, image)
        selector = _deployment_selector(raw_deployment, context)
        matching_raw_pods = [
            raw_pod
            for raw_pod in raw_pods
            if _pod_matches_selector(raw_pod, selector, context)
        ]
        if len(matching_raw_pods) != desired_replicas:
            raise CollectorError(
                "application pods do not exactly match the converged deployment replica count"
            )

        for raw_pod in matching_raw_pods:
            metadata = _required_mapping(raw_pod.get("metadata"), context)
            pod_uid = _required_name(metadata.get("uid"), context)
            if pod_uid in claimed_pods:
                raise CollectorError(
                    "application pod selectors overlap or contain mixed workloads"
                )
            pod = pod_records.get(pod_uid)
            if pod is None:
                raise CollectorError("a required application pod is missing")
            _validate_application_pod(raw_pod, pod, role, image, accepted_image_ids)
            claimed_pods[pod_uid] = role

    application_roles = set(APPLICATION_DEPLOYMENTS.values())
    for pod in pods:
        container_roles = {
            container.get("name")
            for container in pod.get("containers", [])
            if isinstance(container, dict)
        } & application_roles
        if container_roles and pod.get("uid") not in claimed_pods:
            raise CollectorError("stale or mixed application pods are present")
    return set(claimed_pods)


def _application_deployment_evidence(
    deployments: Sequence[Mapping[str, Any]],
) -> list[dict[str, Any]]:
    indexed = {deployment["name"]: deployment for deployment in deployments}
    evidence: list[dict[str, Any]] = []
    for deployment_name, role in APPLICATION_DEPLOYMENTS.items():
        deployment = indexed[deployment_name]
        status = deployment["status"]
        role_container = next(
            container
            for container in deployment["containers"]
            if container["name"] == role
        )
        evidence.append(
            {
                "containers": [
                    {"image": role_container["image"], "name": role_container["name"]}
                ],
                "desired_replicas": deployment["replicas"],
                "generation": deployment["generation"],
                "name": deployment_name,
                "status": {
                    "available_replicas": status["availableReplicas"],
                    "observed_generation": status["observedGeneration"],
                    "ready_replicas": status["readyReplicas"],
                    "replicas": status["replicas"],
                    "unavailable_replicas": status.get("unavailableReplicas", 0),
                    "updated_replicas": status["updatedReplicas"],
                },
            }
        )
    return sorted(evidence, key=lambda deployment: deployment["name"])


def _application_pod_evidence(
    pods: Sequence[Mapping[str, Any]], claimed_pod_uids: set[str]
) -> list[dict[str, Any]]:
    application_roles = set(APPLICATION_DEPLOYMENTS.values())
    evidence: list[dict[str, Any]] = []
    for pod in pods:
        if pod["uid"] not in claimed_pod_uids:
            continue
        role_container = next(
            container
            for container in pod["containers"]
            if container["name"] in application_roles
        )
        evidence.append(
            {
                "containers": [
                    {
                        "image": role_container["image"],
                        "image_id": role_container["image_id"],
                        "name": role_container["name"],
                        "ready": role_container["ready"],
                        "restart_count": role_container["restart_count"],
                        "state": role_container["state"],
                    }
                ],
                "name": pod["name"],
                "phase": pod["phase"],
                "ready": True,
            }
        )
    return sorted(evidence, key=lambda pod: pod["name"])


def _validate_application_deployment(
    deployment: Mapping[str, Any], role: str, image: str
) -> int:
    desired_replicas = deployment.get("replicas")
    generation = deployment.get("generation")
    status = deployment.get("status")
    containers = deployment.get("containers")
    if (
        isinstance(desired_replicas, bool)
        or not isinstance(desired_replicas, int)
        or desired_replicas < 1
        or isinstance(generation, bool)
        or not isinstance(generation, int)
        or not isinstance(status, dict)
        or not isinstance(containers, list)
    ):
        raise CollectorError("application deployment topology is malformed")

    role_containers = [
        container for container in containers if container.get("name") == role
    ]
    if len(role_containers) != 1 or role_containers[0].get("image") != image:
        raise CollectorError(
            "an application deployment does not use the requested image"
        )

    if (
        status.get("observedGeneration") != generation
        or status.get("replicas") != desired_replicas
        or status.get("updatedReplicas") != desired_replicas
        or status.get("readyReplicas") != desired_replicas
        or status.get("availableReplicas") != desired_replicas
        or status.get("unavailableReplicas", 0) != 0
    ):
        raise CollectorError(
            "an application deployment is not fully observed and available"
        )
    return desired_replicas


def _validate_application_pod(
    raw_pod: Mapping[str, Any],
    pod: Mapping[str, Any],
    role: str,
    image: str,
    accepted_image_ids: set[str],
) -> None:
    metadata = _required_mapping(
        raw_pod.get("metadata"), "Kubernetes application topology"
    )
    if metadata.get("deletionTimestamp") is not None:
        raise CollectorError("a stale or terminating application pod is present")
    containers = pod.get("containers")
    if not isinstance(containers, list):
        raise CollectorError("application pod topology is malformed")
    application_roles = set(APPLICATION_DEPLOYMENTS.values())
    application_containers = [
        container
        for container in containers
        if container.get("name") in application_roles
    ]
    role_containers = [
        container
        for container in application_containers
        if container.get("name") == role
    ]
    if len(application_containers) != 1 or len(role_containers) != 1:
        raise CollectorError(
            "an application pod contains a missing or mixed role container"
        )

    container = role_containers[0]
    if container.get("image") != image:
        raise CollectorError("an application pod does not use the requested image")
    if (
        pod.get("phase") != "Running"
        or container.get("ready") is not True
        or container.get("state") != "running"
        or not _raw_pod_ready(raw_pod)
    ):
        raise CollectorError("an application pod is not Running and ready")

    image_id = _normalize_image_identity(container.get("image_id"))
    if image_id is None or image_id not in accepted_image_ids:
        raise CollectorError(
            "an application pod imageID does not match the inspected image"
        )


def _raw_pod_ready(raw_pod: Mapping[str, Any]) -> bool:
    context = "Kubernetes application topology"
    status = _required_mapping(raw_pod.get("status") or {}, context)
    conditions = status.get("conditions") or []
    if not isinstance(conditions, list):
        raise CollectorError(f"{context} response is malformed")
    ready_conditions = []
    for condition in conditions:
        condition_record = _required_mapping(condition, context)
        if condition_record.get("type") == "Ready":
            ready_conditions.append(condition_record)
    return len(ready_conditions) == 1 and ready_conditions[0].get("status") == "True"


def _accepted_image_identities(image_record: Mapping[str, Any]) -> set[str]:
    candidates = [image_record.get("id"), image_record.get("manifest_digest")]
    repository_digests = image_record.get("repository_digests") or []
    if not isinstance(repository_digests, list):
        raise CollectorError("inspected image identity is malformed")
    candidates.extend(repository_digests)
    identities = {
        normalized
        for candidate in candidates
        if (normalized := _normalize_image_identity(candidate)) is not None
    }
    if not identities:
        raise CollectorError("inspected image does not have an immutable identity")
    return identities


def _normalize_image_identity(value: Any) -> str | None:
    if not isinstance(value, str) or CONTROL_CHARACTER.search(value):
        return None
    candidate = value
    if "://" in candidate:
        scheme, candidate = candidate.split("://", 1)
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9+.-]*", scheme):
            return None
    if IMAGE_ID.fullmatch(candidate):
        return candidate
    if REPOSITORY_DIGEST.fullmatch(candidate):
        return candidate.rsplit("@", 1)[1]
    return None


def _deployment_selector(
    raw_deployment: Mapping[str, Any], context: str
) -> Mapping[str, Any]:
    spec = _required_mapping(raw_deployment.get("spec"), context)
    selector = _required_mapping(spec.get("selector"), context)
    match_labels = selector.get("matchLabels") or {}
    match_expressions = selector.get("matchExpressions") or []
    if not isinstance(match_labels, dict) or not isinstance(match_expressions, list):
        raise CollectorError(f"{context} response is malformed")
    if not match_labels and not match_expressions:
        raise CollectorError("application deployment selector must not be empty")
    return selector


def _pod_matches_selector(
    raw_pod: Mapping[str, Any], selector: Mapping[str, Any], context: str
) -> bool:
    metadata = _required_mapping(raw_pod.get("metadata"), context)
    labels_value = metadata.get("labels") or {}
    if not isinstance(labels_value, dict) or not all(
        isinstance(key, str) and isinstance(value, str)
        for key, value in labels_value.items()
    ):
        raise CollectorError(f"{context} response is malformed")

    match_labels = selector.get("matchLabels") or {}
    if not all(
        isinstance(key, str)
        and isinstance(value, str)
        and labels_value.get(key) == value
        for key, value in match_labels.items()
    ):
        return False

    for expression in selector.get("matchExpressions") or []:
        expression_record = _required_mapping(expression, context)
        key = expression_record.get("key")
        operator = expression_record.get("operator")
        values = expression_record.get("values") or []
        if (
            not isinstance(key, str)
            or not isinstance(operator, str)
            or not isinstance(values, list)
        ):
            raise CollectorError(f"{context} response is malformed")
        if not all(isinstance(value, str) for value in values):
            raise CollectorError(f"{context} response is malformed")
        if operator == "In" and labels_value.get(key) not in values:
            return False
        if operator == "NotIn" and (
            key not in labels_value or labels_value.get(key) in values
        ):
            return False
        if operator == "Exists" and key not in labels_value:
            return False
        if operator == "DoesNotExist" and key in labels_value:
            return False
        if operator not in {"In", "NotIn", "Exists", "DoesNotExist"}:
            raise CollectorError(f"{context} response is malformed")
    return True


def _unique_records_by_key(
    records: Sequence[Mapping[str, Any]], key: str, context: str
) -> dict[str, Mapping[str, Any]]:
    indexed: dict[str, Mapping[str, Any]] = {}
    for record in records:
        value = record.get(key)
        if not isinstance(value, str) or value in indexed:
            raise CollectorError(f"{context} response is malformed")
        indexed[value] = record
    return indexed


def _unique_records_by_nested_key(
    records: Sequence[Mapping[str, Any]], path: tuple[str, str], context: str
) -> dict[str, Mapping[str, Any]]:
    indexed: dict[str, Mapping[str, Any]] = {}
    for record in records:
        parent = _required_mapping(record.get(path[0]), context)
        value = parent.get(path[1])
        if not isinstance(value, str) or value in indexed:
            raise CollectorError(f"{context} response is malformed")
        indexed[value] = record
    return indexed


def _select_container_specs(value: Any, context: str) -> list[dict[str, str]]:
    if not isinstance(value, list):
        raise CollectorError(f"{context} response is malformed")
    containers = []
    for container in value:
        mapping = _required_mapping(container, context)
        containers.append(
            {
                "image": _bounded_text(mapping.get("image"), context),
                "name": _required_name(mapping.get("name"), context),
            }
        )
    return sorted(containers, key=lambda container: container["name"])


def _select_pod_containers(
    spec_value: Any, status_value: Any, context: str
) -> list[dict[str, Any]]:
    specs = _select_container_specs(spec_value, context)
    if not isinstance(status_value, list):
        raise CollectorError(f"{context} response is malformed")

    statuses: dict[str, Mapping[str, Any]] = {}
    for status_item in status_value:
        mapping = _required_mapping(status_item, context)
        name = _required_name(mapping.get("name"), context)
        if name in statuses:
            raise CollectorError(f"{context} response is malformed")
        statuses[name] = mapping

    containers: list[dict[str, Any]] = []
    for container_spec in specs:
        status_record = statuses.get(container_spec["name"], {})
        ready = status_record.get("ready")
        if ready is not None and not isinstance(ready, bool):
            raise CollectorError(f"{context} response is malformed")
        containers.append(
            {
                "image": container_spec["image"],
                "image_id": _optional_text(status_record.get("imageID"), context),
                "name": container_spec["name"],
                "ready": ready,
                "restart_count": _optional_integer(
                    status_record.get("restartCount"), context
                ),
                "state": _select_container_state(status_record.get("state"), context),
            }
        )
    return containers


def _select_container_state(value: Any, context: str) -> str | None:
    if value in (None, {}):
        return None
    mapping = _required_mapping(value, context)
    phases = [
        phase
        for phase in ("running", "waiting", "terminated")
        if mapping.get(phase) is not None
    ]
    if len(phases) != 1:
        raise CollectorError(f"{context} response is malformed")
    return phases[0]


def _select_owner_references(value: Any) -> list[dict[str, Any]]:
    context = "Kubernetes pod topology"
    if not isinstance(value, list):
        raise CollectorError(f"{context} response is malformed")
    owners: list[dict[str, Any]] = []
    for owner in value:
        mapping = _required_mapping(owner, context)
        controller = mapping.get("controller")
        if controller is not None and not isinstance(controller, bool):
            raise CollectorError(f"{context} response is malformed")
        owners.append(
            {
                "controller": controller,
                "kind": _required_name(mapping.get("kind"), context),
                "name": _required_name(mapping.get("name"), context),
                "uid": _required_name(mapping.get("uid"), context),
            }
        )
    return sorted(
        owners, key=lambda owner: (owner["kind"], owner["name"], owner["uid"])
    )


def _resource_items(document: Any, context: str) -> list[Mapping[str, Any]]:
    if not isinstance(document, dict) or not isinstance(document.get("items"), list):
        raise CollectorError(f"{context} response is malformed")
    return [_required_mapping(item, context) for item in document["items"]]


def _required_mapping(value: Any, context: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise CollectorError(f"{context} response is malformed")
    return value


def _required_name(value: Any, context: str) -> str:
    text = _bounded_text(value, context)
    if len(text) > 253:
        raise CollectorError(f"{context} response is malformed")
    return text


def _bounded_text(value: Any, context: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > 4096
        or CONTROL_CHARACTER.search(value)
    ):
        raise CollectorError(f"{context} response is malformed")
    return value


def _optional_text(value: Any, context: str) -> str | None:
    if value in (None, ""):
        return None
    return _bounded_text(value, context)


def _optional_integer(value: Any, context: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise CollectorError(f"{context} response is malformed")
    return value


def _select_integer_fields(
    value: Mapping[str, Any], fields: Sequence[str], context: str
) -> dict[str, int]:
    selected: dict[str, int] = {}
    for field in fields:
        if field not in value:
            continue
        selected_value = _optional_integer(value[field], context)
        if selected_value is not None:
            selected[field] = selected_value
    return selected


def _load_json(raw_document: str, context: str) -> Any:
    try:
        return json.loads(raw_document)
    except (TypeError, json.JSONDecodeError):
        raise CollectorError(f"{context} returned invalid JSON") from None


def _validate_reference(image: str) -> None:
    if not image or len(image) > 2048 or CONTROL_CHARACTER.search(image):
        raise CollectorError("image reference is malformed")


def _validate_namespace(namespace: str) -> None:
    if not NAMESPACE.fullmatch(namespace):
        raise CollectorError("namespace must be a valid Kubernetes namespace name")


def _validate_tool(tool: str) -> None:
    if not tool or len(tool) > 1024 or CONTROL_CHARACTER.search(tool):
        raise CollectorError("tool executable name is malformed")


def _utc_timestamp(value: datetime) -> str:
    if not isinstance(value, datetime) or value.tzinfo is None:
        raise CollectorError(
            "collection clock did not return a timezone-aware timestamp"
        )
    return (
        value.astimezone(timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )


def host_summary() -> dict[str, Any]:
    """Return host capacity without hostname, user, environment, or process data."""

    return {
        "cpu_count": os.cpu_count(),
        "machine": platform.machine() or None,
        "os_release": platform.release() or None,
        "os_system": platform.system() or None,
        "os_version": platform.version() or None,
        "processor": platform.processor() or None,
        "total_memory_bytes": _total_memory_bytes(),
    }


def _total_memory_bytes() -> int | None:
    try:
        if platform.system() == "Windows":

            class MemoryStatusEx(ctypes.Structure):
                _fields_ = [
                    ("length", ctypes.c_ulong),
                    ("memory_load", ctypes.c_ulong),
                    ("total_physical", ctypes.c_ulonglong),
                    ("available_physical", ctypes.c_ulonglong),
                    ("total_page_file", ctypes.c_ulonglong),
                    ("available_page_file", ctypes.c_ulonglong),
                    ("total_virtual", ctypes.c_ulonglong),
                    ("available_virtual", ctypes.c_ulonglong),
                    ("available_extended_virtual", ctypes.c_ulonglong),
                ]

            status = MemoryStatusEx()
            status.length = ctypes.sizeof(MemoryStatusEx)
            if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
                return None
            return int(status.total_physical)

        page_size = os.sysconf("SC_PAGE_SIZE")
        page_count = os.sysconf("SC_PHYS_PAGES")
        if isinstance(page_size, int) and isinstance(page_count, int):
            return page_size * page_count
    except (AttributeError, OSError, ValueError):
        return None
    return None


def _validate_host_summary(value: Any) -> None:
    if not isinstance(value, dict):
        raise CollectorError("host summary is malformed")
    expected = {
        "cpu_count",
        "machine",
        "os_release",
        "os_system",
        "os_version",
        "processor",
        "total_memory_bytes",
    }
    if set(value) != expected:
        raise CollectorError("host summary is malformed")
    for key in ("cpu_count", "total_memory_bytes"):
        if value[key] is not None and (
            isinstance(value[key], bool)
            or not isinstance(value[key], int)
            or value[key] < 0
        ):
            raise CollectorError("host summary is malformed")
    for key in ("machine", "os_release", "os_system", "os_version", "processor"):
        if value[key] is not None:
            _bounded_text(value[key], "host summary")


def write_json_atomic(
    document: Mapping[str, Any],
    output: Path,
    *,
    replace_fn: Callable[[str, str], None] | None = None,
) -> None:
    """Write stable JSON through a same-directory temporary file and replace."""

    try:
        serialized = (
            json.dumps(
                document,
                allow_nan=False,
                ensure_ascii=True,
                indent=2,
                sort_keys=True,
            )
            + "\n"
        )
    except (TypeError, ValueError):
        raise CollectorError("evidence document is not JSON serializable") from None

    output = output.expanduser()
    replace = replace_fn or os.replace
    temporary_path: str | None = None
    descriptor: int | None = None
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_path = tempfile.mkstemp(
            dir=str(output.parent),
            prefix=f".{output.name}.",
            suffix=".tmp",
            text=True,
        )
        with os.fdopen(
            descriptor, "w", encoding="utf-8", newline="\n"
        ) as temporary_file:
            descriptor = None
            temporary_file.write(serialized)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        replace(temporary_path, str(output))
        temporary_path = None
    except OSError:
        raise CollectorError(
            "could not atomically write the release evidence output"
        ) from None
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Collect revision-bound, non-secret release evidence as deterministic JSON."
    )
    parser.add_argument("--image", required=True, help="OCI image reference to inspect")
    parser.add_argument(
        "--namespace", required=True, help="Kubernetes namespace to inspect"
    )
    parser.add_argument(
        "--output", required=True, type=Path, help="JSON artifact destination"
    )
    parser.add_argument(
        "--evidence",
        action="append",
        default=[],
        metavar="LABEL=PATH",
        help="hash one regular evidence file; repeat for multiple files",
    )
    parser.add_argument(
        "--allow-dirty",
        action="store_true",
        help="allow a dirty Git tree for diagnostics and mark the override in the artifact",
    )
    parser.add_argument(
        "--git-tool", default="git", help="Git executable (default: git)"
    )
    parser.add_argument(
        "--image-tool",
        default="podman",
        help="OCI inspection executable (default: podman)",
    )
    parser.add_argument(
        "--kubectl-tool",
        default="kubectl",
        help="Kubernetes CLI executable (default: kubectl)",
    )
    return parser


def main(arguments: Sequence[str] | None = None) -> int:
    options = build_argument_parser().parse_args(arguments)
    try:
        document = collect_release_evidence(
            image=options.image,
            namespace=options.namespace,
            evidence_specs=options.evidence,
            allow_dirty=options.allow_dirty,
            git_tool=options.git_tool,
            image_tool=options.image_tool,
            kubectl_tool=options.kubectl_tool,
        )
        write_json_atomic(document, options.output)
    except CollectorError as error:
        print(f"release evidence collection failed: {error}", file=sys.stderr)
        return 2

    print(f"Release evidence written to {options.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
