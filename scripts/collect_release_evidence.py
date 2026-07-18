#!/usr/bin/env python3
"""Collect a bounded, revision-bound release evidence artifact.

The collector intentionally selects a small set of non-secret fields from the
container and Kubernetes APIs. It never serializes command diagnostics,
environment variables, Kubernetes Secret/ConfigMap data, or opaque evidence
contents. The production profile additionally normalizes an exact allow-list of
non-secret promotion receipt fields and retains each receipt's digest.
"""

from __future__ import annotations

import argparse
import copy
import ctypes
import hashlib
import ipaddress
import json
import os
import platform
import re
import stat
import subprocess
import sys
import tempfile
from collections.abc import Callable, Mapping, Sequence
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

import yaml

from validate_production_bundle import validate_documents as validate_production_documents


SCHEMA_VERSION = 1
COMMAND_TIMEOUT_SECONDS = 60
GIT_REVISION = re.compile(r"^[0-9a-f]{40,64}$")
IMAGE_ID = re.compile(r"^sha256:[0-9a-f]{64}$")
BARE_IMAGE_ID = re.compile(r"^[0-9a-f]{64}$")
REPOSITORY_DIGEST = re.compile(r"^[^\s@]+@sha256:[0-9a-f]{64}$")
EVIDENCE_LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
IMAGE_LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$")
NAMESPACE = re.compile(r"^[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?$")
CONTROL_CHARACTER = re.compile(r"[\x00-\x1f\x7f]")
IMAGE_VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")
ENVIRONMENT_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$")
KUBERNETES_STABLE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$")
UTC_TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
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
PRODUCTION_MINIMUM_REPLICAS = {"edge": 3, "worker": 2}
PROMOTION_RECEIPT_SCHEMA_VERSION = 1
PROMOTION_RECEIPT_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
PROMOTION_RECEIPT_MAX_BYTES = 64 * 1024
PRODUCTION_BUNDLE_MAX_BYTES = 16 * 1024 * 1024
REQUIRED_PROMOTION_RECEIPTS = (
    "backup_restore",
    "failover",
    "migration",
    "production_preflight",
    "security",
    "staging_acceptance",
    "staging_load",
    "staging_product_acceptance",
)
PRODUCTION_CONTROL_RESOURCE_TYPES = {
    "ConfigMap": "configmap",
    "Deployment": "deployment",
    "HorizontalPodAutoscaler": "horizontalpodautoscaler",
    "Ingress": "ingress",
    "Job": "job",
    "Namespace": "namespaces",
    "NetworkPolicy": "networkpolicy",
    "PodDisruptionBudget": "poddisruptionbudget",
    "Service": "service",
    "ServiceAccount": "serviceaccount",
}
PRODUCTION_CLUSTER_SCOPED_CONTROL_KINDS = {"Namespace"}
PRODUCTION_SECRET_CONTROL_KINDS = {"Secret"}
SERVER_MANAGED_METADATA_FIELDS = {
    "creationTimestamp",
    "deletionGracePeriodSeconds",
    "deletionTimestamp",
    "generation",
    "managedFields",
    "resourceVersion",
    "selfLink",
    "uid",
}
IGNORED_LIVE_CONTROL_ANNOTATIONS = {
    "kubectl.kubernetes.io/last-applied-configuration",
}
STRICT_SPEC_CONTROL_KINDS = {"Ingress", "NetworkPolicy"}
STRICT_WORKLOAD_CONTROL_KINDS = {"Deployment", "Job"}
STRICT_NORMALIZED_CONTROL_KINDS = {
    "HorizontalPodAutoscaler",
    "Namespace",
    "PodDisruptionBudget",
    "Service",
    "ServiceAccount",
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
    receipt_specs: Sequence[str] = (),
    profile: str = "diagnostic",
    environment_id: str | None = None,
    production_bundle: Path | str | None = None,
    binding_only: bool = False,
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
    receipt_paths, bundle_path = _validate_profile_inputs(
        profile=profile,
        image=image,
        environment_id=environment_id,
        receipt_specs=receipt_specs,
        production_bundle=production_bundle,
        binding_only=binding_only,
        allow_dirty=allow_dirty,
    )
    for tool in (git_tool, image_tool, kubectl_tool):
        _validate_tool(tool)

    # Validate and hash local inputs before invoking external tools. This keeps
    # malformed or secret-like evidence labels out of command diagnostics.
    evidence_files = hash_evidence_files(evidence_specs)
    bundle_record: dict[str, Any] | None = None
    bundle_documents: list[dict[str, Any]] | None = None
    if bundle_path is not None:
        bundle_record, bundle_documents = _load_production_bundle(bundle_path)

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

    promotion_record: dict[str, Any] | None = None
    if profile == "production":
        if (
            environment_id is None
            or bundle_path is None
            or bundle_record is None
            or bundle_documents is None
        ):
            raise CollectorError("production promotion inputs are incomplete")
        now = (clock or (lambda: datetime.now(timezone.utc)))()
        collected_at = _utc_timestamp(now)
        _validate_production_image(image, image_record)
        _validate_production_topology(kubernetes_record)
        environment_record = _collect_production_environment_identity(
            kubectl_tool,
            namespace,
            environment_id,
            command_runner,
        )
        controls_record = _collect_live_production_controls(
            kubectl_tool,
            namespace,
            bundle_documents,
            command_runner,
        )

        if binding_only:
            receipts: list[dict[str, Any]] = []
        else:
            receipts = _collect_promotion_receipts(
                receipt_paths,
                revision=revision,
                image_digest=image_record["manifest_digest"],
                bundle_sha256=bundle_record["sha256"],
                live_controls_sha256=controls_record["live_sha256"],
                environment=environment_record,
                collected_at=now,
            )

        ending_environment = _collect_production_environment_identity(
            kubectl_tool,
            namespace,
            environment_id,
            command_runner,
        )
        ending_controls = _collect_live_production_controls(
            kubectl_tool,
            namespace,
            bundle_documents,
            command_runner,
        )
        if ending_environment != environment_record or ending_controls != controls_record:
            raise CollectorError(
                "production environment identity or live controls changed during collection"
            )

        ending_bundle, _ending_documents = _load_production_bundle(bundle_path)
        if ending_bundle != bundle_record:
            raise CollectorError("production bundle changed during collection")

        promotion_record = {
            "bundle": bundle_record,
            "controls": controls_record,
            "environment": environment_record,
            "mode": "binding" if binding_only else "final",
            "profile": "production",
            "promotion_ready": not binding_only,
            "receipt_max_age_seconds": PROMOTION_RECEIPT_MAX_AGE_SECONDS,
            "receipts": receipts,
            "required_receipts": list(REQUIRED_PROMOTION_RECEIPTS),
        }

    ending_revision, ending_status = _git_snapshot(git_tool, command_runner)
    if ending_revision != revision or ending_status != status:
        raise CollectorError(
            "Git state changed while release evidence was being collected"
        )

    if profile != "production":
        now = (clock or (lambda: datetime.now(timezone.utc)))()
        collected_at = _utc_timestamp(now)
    host_record = (host_provider or host_summary)()
    _validate_host_summary(host_record)

    document = {
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
    if promotion_record is not None:
        document["promotion"] = promotion_record
    return document


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


def _validate_profile_inputs(
    *,
    profile: str,
    image: str,
    environment_id: str | None,
    receipt_specs: Sequence[str],
    production_bundle: Path | str | None,
    binding_only: bool,
    allow_dirty: bool,
) -> tuple[dict[str, Path], Path | None]:
    if profile not in ("diagnostic", "production"):
        raise CollectorError(
            "release evidence profile must be diagnostic or production"
        )
    if profile == "diagnostic":
        if (
            receipt_specs
            or environment_id is not None
            or production_bundle is not None
            or binding_only
        ):
            raise CollectorError(
                "promotion inputs require "
                "--profile production"
            )
        return {}, None

    if allow_dirty:
        raise CollectorError("the production profile does not permit --allow-dirty")
    if not REPOSITORY_DIGEST.fullmatch(image):
        raise CollectorError(
            "the production profile requires a digest-pinned image reference"
        )
    if environment_id is None or not ENVIRONMENT_ID.fullmatch(environment_id):
        raise CollectorError(
            "the production profile requires a well-formed environment identity"
        )
    if production_bundle is None:
        raise CollectorError(
            "the production profile requires --production-bundle"
        )
    raw_bundle_path = os.fspath(production_bundle)
    if not raw_bundle_path or CONTROL_CHARACTER.search(raw_bundle_path):
        raise CollectorError("the production bundle path is malformed")
    bundle_path = Path(raw_bundle_path).expanduser()
    if binding_only and receipt_specs:
        raise CollectorError("--binding-only does not accept promotion receipts")

    paths: dict[str, Path] = {}
    required = set(REQUIRED_PROMOTION_RECEIPTS)
    for specification in receipt_specs:
        label, separator, raw_path = specification.partition("=")
        if (
            not separator
            or label not in required
            or not raw_path
            or CONTROL_CHARACTER.search(raw_path)
        ):
            raise CollectorError(
                "promotion receipts must use a required TYPE=PATH value"
            )
        if label in paths:
            raise CollectorError("promotion receipt types must be unique")
        paths[label] = Path(raw_path).expanduser()

    missing = sorted(required - set(paths))
    if missing and not binding_only:
        raise CollectorError(
            "the production profile is missing required promotion receipts: "
            + ", ".join(missing)
        )
    return paths, bundle_path


def _load_production_bundle(
    path: Path,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    content = _read_bounded_regular_file(
        path,
        maximum_bytes=PRODUCTION_BUNDLE_MAX_BYTES,
        missing_message="production bundle is missing or unreadable",
        invalid_message="production bundle must be a stable regular file",
    )
    try:
        text = content.decode("utf-8")
        documents = [document for document in yaml.safe_load_all(text) if document]
    except (UnicodeDecodeError, yaml.YAMLError):
        raise CollectorError("production bundle is not valid UTF-8 YAML") from None
    if not documents or any(not isinstance(document, dict) for document in documents):
        raise CollectorError("production bundle must contain Kubernetes objects")

    errors = validate_production_documents(documents)
    if errors:
        raise CollectorError(
            "production bundle semantic preflight failed:\n" + "\n".join(errors)
        )
    return (
        {
            "sha256": hashlib.sha256(content).hexdigest(),
            "size_bytes": len(content),
        },
        documents,
    )


def _read_bounded_regular_file(
    path: Path,
    *,
    maximum_bytes: int,
    missing_message: str,
    invalid_message: str,
) -> bytes:
    try:
        path_metadata = path.lstat()
        if not stat.S_ISREG(path_metadata.st_mode):
            raise CollectorError(invalid_message)
        if path_metadata.st_size > maximum_bytes:
            raise CollectorError(invalid_message)
        resolved_path = path.resolve(strict=True)
        resolved_metadata = resolved_path.lstat()
    except CollectorError:
        raise
    except OSError:
        raise CollectorError(missing_message) from None
    if _file_fingerprint(path_metadata) != _file_fingerprint(resolved_metadata):
        raise CollectorError(invalid_message)

    try:
        open_flags = (
            os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_CLOEXEC", 0)
        )
        open_flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(resolved_path, open_flags)
        with os.fdopen(descriptor, "rb") as source:
            before = os.fstat(source.fileno())
            if _file_fingerprint(resolved_metadata) != _file_fingerprint(before):
                raise CollectorError(invalid_message)
            content = source.read(maximum_bytes + 1)
            after = os.fstat(source.fileno())
            final_metadata = resolved_path.lstat()
    except CollectorError:
        raise
    except OSError:
        raise CollectorError(missing_message) from None

    fingerprint = _file_fingerprint(before)
    if (
        len(content) > maximum_bytes
        or fingerprint != _file_fingerprint(after)
        or fingerprint != _file_fingerprint(final_metadata)
        or len(content) != after.st_size
    ):
        raise CollectorError(invalid_message)
    return content


def _collect_production_environment_identity(
    kubectl_tool: str,
    namespace: str,
    environment_id: str,
    command_runner: CommandRunner,
) -> dict[str, str]:
    cluster_namespace = _load_json(
        command_runner(
            (kubectl_tool, "get", "namespace", "kube-system", "-o", "json"),
            "Kubernetes cluster identity",
        ),
        "Kubernetes cluster identity",
    )
    target_namespace = _load_json(
        command_runner(
            (kubectl_tool, "get", "namespace", namespace, "-o", "json"),
            "Kubernetes namespace identity",
        ),
        "Kubernetes namespace identity",
    )
    cluster_uid = _namespace_uid(cluster_namespace, "kube-system")
    namespace_uid = _namespace_uid(target_namespace, namespace)
    return {
        "cluster_uid_sha256": hashlib.sha256(cluster_uid.encode("utf-8")).hexdigest(),
        "id": environment_id,
        "namespace": namespace,
        "namespace_uid_sha256": hashlib.sha256(
            namespace_uid.encode("utf-8")
        ).hexdigest(),
    }


def _namespace_uid(document: Any, expected_name: str) -> str:
    if not isinstance(document, dict) or document.get("kind") != "Namespace":
        raise CollectorError("Kubernetes namespace identity response is malformed")
    metadata = document.get("metadata")
    if not isinstance(metadata, dict) or metadata.get("name") != expected_name:
        raise CollectorError("Kubernetes namespace identity response is malformed")
    return _stable_kubernetes_id(
        metadata.get("uid"), "Kubernetes namespace identity response"
    )


def _collect_live_production_controls(
    kubectl_tool: str,
    namespace: str,
    bundle_documents: Sequence[Mapping[str, Any]],
    command_runner: CommandRunner,
) -> dict[str, Any]:
    expected_controls = _expected_production_controls(bundle_documents, namespace)
    revisions: list[dict[str, Any]] = []
    live_controls: list[dict[str, Any]] = []
    migration_completed = False

    for expected in expected_controls:
        kind = expected["kind"]
        name = expected["metadata"]["name"]
        resource_type = PRODUCTION_CONTROL_RESOURCE_TYPES[kind]
        command = [kubectl_tool, "get", resource_type, name]
        expected_namespace = expected["metadata"].get("namespace")
        if expected_namespace:
            command.extend(("--namespace", expected_namespace))
        command.extend(("-o", "json"))
        live = _load_json(
            command_runner(
                tuple(command),
                f"live production control {kind} {name}",
            ),
            f"live production control {kind} {name}",
        )
        live_for_projection = live
        if kind == "ConfigMap" and isinstance(live, dict):
            live_for_projection = dict(live)
            live_for_projection.setdefault("binaryData", {})
            live_for_projection.setdefault("data", {})
        if not _live_control_matches_expected(expected, live_for_projection):
            raise CollectorError(
                f"live {kind} {name} does not match the reviewed production bundle"
            )
        if not isinstance(live, dict):
            raise CollectorError("live production control response is malformed")
        live_controls.append(_live_control_for_semantic_validation(expected, live))

        metadata = live.get("metadata") if isinstance(live, dict) else None
        if not isinstance(metadata, dict):
            raise CollectorError("live production control metadata is malformed")
        generation = metadata.get("generation")
        if generation is not None and (
            isinstance(generation, bool)
            or not isinstance(generation, int)
            or generation < 1
        ):
            raise CollectorError("live production control metadata is malformed")
        revision = {
            "desired_sha256": _canonical_json_sha256(expected),
            "generation": generation,
            "kind": kind,
            "name": name,
            "namespace": expected_namespace,
            "uid": _stable_kubernetes_id(
                metadata.get("uid"), "live production control metadata"
            ),
        }
        if kind == "Job" and name == "k-comms-migrate":
            revision["migration_completion"] = _migration_completion(live)
            migration_completed = True
        revisions.append(revision)

    if validate_production_documents(live_controls):
        raise CollectorError("live production controls failed semantic validation")

    return {
        "bundle_sha256": _canonical_json_sha256(expected_controls),
        "live_sha256": _canonical_json_sha256(revisions),
        "migration_completed": migration_completed,
        "resource_count": len(expected_controls),
    }


def _expected_production_controls(
    bundle_documents: Sequence[Mapping[str, Any]],
    namespace: str,
) -> list[dict[str, Any]]:
    controls: list[dict[str, Any]] = []
    identities: set[tuple[str, str]] = set()

    for document in bundle_documents:
        kind = document.get("kind")
        if kind in PRODUCTION_SECRET_CONTROL_KINDS:
            continue
        if kind not in PRODUCTION_CONTROL_RESOURCE_TYPES:
            raise CollectorError(
                "reviewed production bundle contains an unsupported non-secret resource kind"
            )

        metadata = document.get("metadata")
        if not isinstance(metadata, dict):
            raise CollectorError("reviewed production bundle control metadata is malformed")
        name = metadata.get("name")
        if not isinstance(name, str) or not KUBERNETES_STABLE_ID.fullmatch(name):
            raise CollectorError("reviewed production bundle control metadata is malformed")

        if kind in PRODUCTION_CLUSTER_SCOPED_CONTROL_KINDS:
            if name != namespace or metadata.get("namespace") not in (None, ""):
                raise CollectorError(
                    "reviewed production bundle cluster-scoped control does not match the target namespace"
                )
        else:
            if metadata.get("namespace") != namespace:
                raise CollectorError(
                    f"reviewed production bundle {kind} {name} does not target the production namespace"
                )

        identity = (kind, name)
        if identity in identities:
            raise CollectorError(
                f"reviewed production bundle must contain exactly one {kind} {name}"
            )
        identities.add(identity)

        control = {
            key: value
            for key, value in document.items()
            if key not in ("metadata", "status")
        }
        control["metadata"] = {
            key: value
            for key, value in metadata.items()
            if key not in SERVER_MANAGED_METADATA_FIELDS
        }
        if kind == "Deployment":
            desired = control.get("spec")
            if not isinstance(desired, dict):
                raise CollectorError(
                    f"reviewed production bundle {kind} {name} is malformed"
                )
            # HPA legitimately changes this one field. Its own desired state is
            # bound separately, and the observed topology enforces role minima.
            control["spec"] = {
                key: value for key, value in desired.items() if key != "replicas"
            }
        controls.append(control)
    return sorted(
        controls,
        key=lambda control: (
            control["kind"],
            control["metadata"].get("namespace") or "",
            control["metadata"]["name"],
        ),
    )


def _live_control_matches_expected(
    expected: Mapping[str, Any], live: Mapping[str, Any]
) -> bool:
    if _project_like_expected(expected, live) != expected:
        return False

    kind = expected.get("kind")
    if kind == "ConfigMap":
        if (live.get("data") or {}) != (expected.get("data") or {}):
            return False
        if (live.get("binaryData") or {}) != (expected.get("binaryData") or {}):
            return False

    if kind in STRICT_SPEC_CONTROL_KINDS and live.get("spec") != expected.get("spec"):
        return False

    if kind in STRICT_WORKLOAD_CONTROL_KINDS:
        expected_spec = expected.get("spec")
        live_spec = live.get("spec")
        if not isinstance(expected_spec, dict) or not isinstance(live_spec, dict):
            return False
        if _normalized_live_workload_spec(kind, expected_spec, live_spec) != expected_spec:
            return False

    if kind in STRICT_NORMALIZED_CONTROL_KINDS:
        if _normalized_live_control(expected, live) != expected:
            return False

    if kind == "Ingress":
        expected_metadata = expected.get("metadata") or {}
        live_metadata = live.get("metadata") or {}
        if _control_annotations(live_metadata) != _control_annotations(expected_metadata):
            return False

    return True


def _live_control_for_semantic_validation(
    expected: Mapping[str, Any], live: Mapping[str, Any]
) -> dict[str, Any]:
    kind = expected.get("kind")
    if kind in STRICT_WORKLOAD_CONTROL_KINDS:
        document = copy.deepcopy(dict(live))
        expected_spec = expected.get("spec")
        live_spec = live.get("spec")
        if isinstance(expected_spec, dict) and isinstance(live_spec, dict):
            normalized_spec = _normalized_live_workload_spec(
                str(kind), expected_spec, live_spec
            )
            if kind == "Deployment" and "replicas" in live_spec:
                normalized_spec["replicas"] = live_spec["replicas"]
            document["spec"] = normalized_spec
        return document
    if kind in STRICT_NORMALIZED_CONTROL_KINDS:
        return _normalized_live_control(expected, live)
    return copy.deepcopy(dict(live))


def _control_annotations(metadata: Mapping[str, Any]) -> dict[str, Any]:
    annotations = metadata.get("annotations") or {}
    if not isinstance(annotations, dict):
        return {}
    return {
        key: value
        for key, value in annotations.items()
        if key not in IGNORED_LIVE_CONTROL_ANNOTATIONS
    }


def _normalized_live_control(
    expected: Mapping[str, Any], live: Mapping[str, Any]
) -> dict[str, Any]:
    normalized = copy.deepcopy(dict(live))
    normalized.pop("status", None)
    live_metadata = normalized.get("metadata")
    expected_metadata = expected.get("metadata")
    if isinstance(live_metadata, dict) and isinstance(expected_metadata, dict):
        for field in SERVER_MANAGED_METADATA_FIELDS:
            live_metadata.pop(field, None)
        annotations = live_metadata.get("annotations")
        if isinstance(annotations, dict):
            for annotation in IGNORED_LIVE_CONTROL_ANNOTATIONS:
                annotations.pop(annotation, None)
            if not annotations and "annotations" not in expected_metadata:
                live_metadata.pop("annotations", None)

        if expected.get("kind") == "Namespace":
            expected_labels = expected_metadata.get("labels") or {}
            live_labels = live_metadata.get("labels")
            if isinstance(expected_labels, dict) and isinstance(live_labels, dict):
                metadata_name = live_metadata.get("name")
                if (
                    "kubernetes.io/metadata.name" not in expected_labels
                    and live_labels.get("kubernetes.io/metadata.name") == metadata_name
                ):
                    live_labels.pop("kubernetes.io/metadata.name", None)

    if (
        expected.get("kind") == "Namespace"
        and "spec" not in expected
        and normalized.get("spec") == {"finalizers": ["kubernetes"]}
    ):
        normalized.pop("spec", None)

    if expected.get("kind") == "Service":
        expected_spec = expected.get("spec")
        live_spec = normalized.get("spec")
        if isinstance(expected_spec, dict) and isinstance(live_spec, dict):
            _normalize_live_service_spec(expected_spec, live_spec)
    elif expected.get("kind") == "HorizontalPodAutoscaler":
        expected_spec = expected.get("spec")
        live_spec = normalized.get("spec")
        if isinstance(expected_spec, dict) and isinstance(live_spec, dict):
            _normalize_live_hpa_spec(expected_spec, live_spec)
    return normalized


def _normalize_live_service_spec(
    expected_spec: Mapping[str, Any], live_spec: dict[str, Any]
) -> None:
    live_cluster_ip = live_spec.get("clusterIP")
    expected_cluster_ip = expected_spec.get("clusterIP")
    if "clusterIP" not in expected_spec and _is_allocated_service_ip(live_cluster_ip):
        live_spec.pop("clusterIP", None)

    if "clusterIPs" not in expected_spec:
        live_cluster_ips = live_spec.get("clusterIPs")
        if live_cluster_ips == [live_cluster_ip] and (
            live_cluster_ip == expected_cluster_ip
            or _is_allocated_service_ip(live_cluster_ip)
        ):
            live_spec.pop("clusterIPs", None)

    if "ipFamilies" not in expected_spec and _valid_default_ip_families(
        live_spec.get("ipFamilies"), live_cluster_ip
    ):
        live_spec.pop("ipFamilies", None)

    for key, default in (
        ("ipFamilyPolicy", "SingleStack"),
        ("internalTrafficPolicy", "Cluster"),
        ("sessionAffinity", "None"),
        ("type", "ClusterIP"),
    ):
        _drop_known_live_default(live_spec, expected_spec, key, default)

    _normalize_parallel_mapping_lists(
        expected_spec, live_spec, "ports", _normalize_live_service_port
    )


def _normalize_live_service_port(
    expected_port: Mapping[str, Any], live_port: dict[str, Any]
) -> None:
    _drop_known_live_default(live_port, expected_port, "protocol", "TCP")


def _normalize_live_hpa_spec(
    expected_spec: Mapping[str, Any], live_spec: dict[str, Any]
) -> None:
    expected_behavior = expected_spec.get("behavior")
    live_behavior = live_spec.get("behavior")
    if not isinstance(expected_behavior, dict) or not isinstance(live_behavior, dict):
        return
    defaults = {
        "scaleUp": {
            "policies": [
                {"periodSeconds": 15, "type": "Pods", "value": 4},
                {"periodSeconds": 15, "type": "Percent", "value": 100},
            ],
            "selectPolicy": "Max",
        },
        "scaleDown": {
            "policies": [
                {"periodSeconds": 15, "type": "Percent", "value": 100},
            ],
            "selectPolicy": "Max",
        },
    }
    for direction, direction_defaults in defaults.items():
        expected_direction = expected_behavior.get(direction)
        live_direction = live_behavior.get(direction)
        if not isinstance(expected_direction, dict) or not isinstance(
            live_direction, dict
        ):
            continue
        for key, default in direction_defaults.items():
            _drop_known_live_default(live_direction, expected_direction, key, default)


def _is_allocated_service_ip(value: Any) -> bool:
    if not isinstance(value, str) or value == "None":
        return False
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return False
    return True


def _valid_default_ip_families(value: Any, cluster_ip: Any) -> bool:
    if value not in (["IPv4"], ["IPv6"]):
        return False
    if cluster_ip == "None":
        return True
    if not _is_allocated_service_ip(cluster_ip):
        return False
    version = ipaddress.ip_address(cluster_ip).version
    return value == (["IPv4"] if version == 4 else ["IPv6"])


def _normalized_live_workload_spec(
    kind: str,
    expected_spec: Mapping[str, Any],
    live_spec: Mapping[str, Any],
) -> dict[str, Any]:
    normalized = copy.deepcopy(dict(live_spec))

    if kind == "Deployment":
        normalized.pop("replicas", None)
        for key, default in (
            ("minReadySeconds", 0),
            ("paused", False),
            ("progressDeadlineSeconds", 600),
            ("revisionHistoryLimit", 10),
            (
                "strategy",
                {
                    "rollingUpdate": {
                        "maxSurge": "25%",
                        "maxUnavailable": "25%",
                    },
                    "type": "RollingUpdate",
                },
            ),
        ):
            _drop_known_live_default(normalized, expected_spec, key, default)
    elif kind == "Job":
        for key, default in (
            ("parallelism", 1),
            ("completions", 1),
            ("backoffLimit", 6),
            ("completionMode", "NonIndexed"),
            ("manualSelector", False),
            ("podReplacementPolicy", "TerminatingOrFailed"),
            ("suspend", False),
        ):
            _drop_known_live_default(normalized, expected_spec, key, default)
        if "selector" not in expected_spec and _is_job_controller_selector(
            normalized.get("selector")
        ):
            normalized.pop("selector", None)

    expected_template = expected_spec.get("template")
    live_template = normalized.get("template")
    if isinstance(expected_template, dict) and isinstance(live_template, dict):
        _normalize_live_template(kind, expected_template, live_template)

    return normalized


def _normalize_live_template(
    kind: str,
    expected_template: Mapping[str, Any],
    live_template: dict[str, Any],
) -> None:
    expected_metadata = expected_template.get("metadata")
    live_metadata = live_template.get("metadata")
    if isinstance(expected_metadata, dict) and isinstance(live_metadata, dict):
        _drop_known_live_default(
            live_metadata, expected_metadata, "creationTimestamp", None
        )
        if kind == "Job":
            expected_labels = expected_metadata.get("labels") or {}
            live_labels = live_metadata.get("labels")
            if isinstance(expected_labels, dict) and isinstance(live_labels, dict):
                for label in (
                    "batch.kubernetes.io/controller-uid",
                    "batch.kubernetes.io/job-name",
                    "controller-uid",
                    "job-name",
                ):
                    if label not in expected_labels:
                        live_labels.pop(label, None)

    expected_pod_spec = expected_template.get("spec")
    live_pod_spec = live_template.get("spec")
    if isinstance(expected_pod_spec, dict) and isinstance(live_pod_spec, dict):
        _normalize_live_pod_spec(expected_pod_spec, live_pod_spec)


def _normalize_live_pod_spec(
    expected_pod_spec: Mapping[str, Any], live_pod_spec: dict[str, Any]
) -> None:
    for key, default in (
        ("dnsPolicy", "ClusterFirst"),
        ("enableServiceLinks", True),
        ("preemptionPolicy", "PreemptLowerPriority"),
        ("restartPolicy", "Always"),
        ("schedulerName", "default-scheduler"),
        ("terminationGracePeriodSeconds", 30),
        ("hostNetwork", False),
        ("hostPID", False),
        ("hostIPC", False),
        ("shareProcessNamespace", False),
        ("setHostnameAsFQDN", False),
    ):
        _drop_known_live_default(live_pod_spec, expected_pod_spec, key, default)

    if "serviceAccount" not in expected_pod_spec:
        expected_service_account = expected_pod_spec.get("serviceAccountName")
        if live_pod_spec.get("serviceAccount") == expected_service_account:
            live_pod_spec.pop("serviceAccount", None)

    for key in ("initContainers", "ephemeralContainers"):
        _drop_known_live_default(live_pod_spec, expected_pod_spec, key, [])

    expected_security = expected_pod_spec.get("securityContext")
    live_security = live_pod_spec.get("securityContext")
    if isinstance(expected_security, dict) and isinstance(live_security, dict):
        _drop_known_live_default(
            live_security, expected_security, "fsGroupChangePolicy", "Always"
        )
        _drop_known_live_default(
            live_security, expected_security, "supplementalGroupsPolicy", "Merge"
        )

    _normalize_parallel_mapping_lists(
        expected_pod_spec, live_pod_spec, "containers", _normalize_live_container
    )
    _normalize_parallel_mapping_lists(
        expected_pod_spec, live_pod_spec, "volumes", _normalize_live_volume
    )
    _normalize_parallel_mapping_lists(
        expected_pod_spec,
        live_pod_spec,
        "topologySpreadConstraints",
        _normalize_live_topology_spread_constraint,
    )


def _normalize_parallel_mapping_lists(
    expected_parent: Mapping[str, Any],
    live_parent: dict[str, Any],
    key: str,
    normalizer: Callable[[Mapping[str, Any], dict[str, Any]], None],
) -> None:
    expected_items = expected_parent.get(key)
    live_items = live_parent.get(key)
    if (
        not isinstance(expected_items, list)
        or not isinstance(live_items, list)
        or len(expected_items) != len(live_items)
    ):
        return
    for expected_item, live_item in zip(expected_items, live_items, strict=True):
        if isinstance(expected_item, dict) and isinstance(live_item, dict):
            normalizer(expected_item, live_item)


def _normalize_live_container(
    expected_container: Mapping[str, Any], live_container: dict[str, Any]
) -> None:
    for key, default in (
        ("imagePullPolicy", "IfNotPresent"),
        ("terminationMessagePath", "/dev/termination-log"),
        ("terminationMessagePolicy", "File"),
        ("stdin", False),
        ("stdinOnce", False),
        ("tty", False),
    ):
        _drop_known_live_default(live_container, expected_container, key, default)

    expected_security = expected_container.get("securityContext")
    live_security = live_container.get("securityContext")
    if isinstance(expected_security, dict) and isinstance(live_security, dict):
        for key, default in (
            ("privileged", False),
            ("procMount", "Default"),
        ):
            _drop_known_live_default(live_security, expected_security, key, default)
        expected_capabilities = expected_security.get("capabilities")
        live_capabilities = live_security.get("capabilities")
        if isinstance(expected_capabilities, dict) and isinstance(
            live_capabilities, dict
        ):
            _drop_known_live_default(
                live_capabilities, expected_capabilities, "add", []
            )

    for probe_name in ("startupProbe", "readinessProbe", "livenessProbe"):
        expected_probe = expected_container.get(probe_name)
        live_probe = live_container.get(probe_name)
        if isinstance(expected_probe, dict) and isinstance(live_probe, dict):
            for key, default in (
                ("initialDelaySeconds", 0),
                ("periodSeconds", 10),
                ("timeoutSeconds", 1),
                ("successThreshold", 1),
                ("failureThreshold", 3),
            ):
                _drop_known_live_default(live_probe, expected_probe, key, default)
            expected_http_get = expected_probe.get("httpGet")
            live_http_get = live_probe.get("httpGet")
            if isinstance(expected_http_get, dict) and isinstance(live_http_get, dict):
                _drop_known_live_default(
                    live_http_get, expected_http_get, "scheme", "HTTP"
                )

    _normalize_parallel_mapping_lists(
        expected_container, live_container, "ports", _normalize_live_container_port
    )
    _normalize_parallel_mapping_lists(
        expected_container,
        live_container,
        "volumeMounts",
        _normalize_live_volume_mount,
    )
    _normalize_parallel_mapping_lists(
        expected_container, live_container, "env", _normalize_live_env_var
    )


def _normalize_live_env_var(
    expected_env: Mapping[str, Any], live_env: dict[str, Any]
) -> None:
    expected_value_from = expected_env.get("valueFrom")
    live_value_from = live_env.get("valueFrom")
    if not isinstance(expected_value_from, dict) or not isinstance(
        live_value_from, dict
    ):
        return
    expected_field_ref = expected_value_from.get("fieldRef")
    live_field_ref = live_value_from.get("fieldRef")
    if isinstance(expected_field_ref, dict) and isinstance(live_field_ref, dict):
        _drop_known_live_default(
            live_field_ref, expected_field_ref, "apiVersion", "v1"
        )


def _normalize_live_container_port(
    expected_port: Mapping[str, Any], live_port: dict[str, Any]
) -> None:
    _drop_known_live_default(live_port, expected_port, "protocol", "TCP")


def _normalize_live_volume_mount(
    expected_mount: Mapping[str, Any], live_mount: dict[str, Any]
) -> None:
    _drop_known_live_default(live_mount, expected_mount, "readOnly", False)


def _normalize_live_volume(
    expected_volume: Mapping[str, Any], live_volume: dict[str, Any]
) -> None:
    for source_key in ("configMap", "secret", "projected", "downwardAPI"):
        expected_source = expected_volume.get(source_key)
        live_source = live_volume.get(source_key)
        if isinstance(expected_source, dict) and isinstance(live_source, dict):
            _drop_known_live_default(live_source, expected_source, "defaultMode", 420)


def _normalize_live_topology_spread_constraint(
    expected_constraint: Mapping[str, Any], live_constraint: dict[str, Any]
) -> None:
    for key, default in (
        ("minDomains", 1),
        ("nodeAffinityPolicy", "Honor"),
        ("nodeTaintsPolicy", "Ignore"),
    ):
        _drop_known_live_default(live_constraint, expected_constraint, key, default)


def _drop_known_live_default(
    live: dict[str, Any],
    expected: Mapping[str, Any],
    key: str,
    default: Any,
) -> None:
    if key not in expected and live.get(key) == default:
        live.pop(key, None)


def _is_job_controller_selector(value: Any) -> bool:
    if not isinstance(value, dict) or set(value) != {"matchLabels"}:
        return False
    labels = value.get("matchLabels")
    if not isinstance(labels, dict) or not labels:
        return False
    allowed = {"batch.kubernetes.io/controller-uid", "controller-uid"}
    return set(labels).issubset(allowed) and all(
        isinstance(label_value, str) and label_value for label_value in labels.values()
    )


def _project_like_expected(expected: Any, live: Any) -> Any:
    if isinstance(expected, dict):
        if not isinstance(live, dict) or any(key not in live for key in expected):
            return None
        return {
            key: _project_like_expected(expected[key], live[key]) for key in expected
        }
    if isinstance(expected, list):
        if not isinstance(live, list) or len(live) != len(expected):
            return None
        return [
            _project_like_expected(expected_item, live_item)
            for expected_item, live_item in zip(expected, live, strict=True)
        ]
    return live


def _migration_completion(document: Mapping[str, Any]) -> dict[str, Any]:
    status = document.get("status")
    if not isinstance(status, dict):
        raise CollectorError("production migration Job is not complete")
    succeeded = status.get("succeeded")
    failed = status.get("failed", 0)
    active = status.get("active", 0)
    conditions = status.get("conditions")
    complete = (
        isinstance(conditions, list)
        and len(
            [
                condition
                for condition in conditions
                if isinstance(condition, dict)
                and condition.get("type") == "Complete"
                and condition.get("status") == "True"
            ]
        )
        == 1
    )
    completion_time = status.get("completionTime")
    if (
        isinstance(succeeded, bool)
        or not isinstance(succeeded, int)
        or succeeded < 1
        or isinstance(failed, bool)
        or not isinstance(failed, int)
        or failed != 0
        or isinstance(active, bool)
        or not isinstance(active, int)
        or active != 0
        or not complete
        or not isinstance(completion_time, str)
        or not completion_time
        or CONTROL_CHARACTER.search(completion_time)
    ):
        raise CollectorError("production migration Job is not complete")
    return {"completed_at": completion_time, "succeeded": succeeded}


def _stable_kubernetes_id(value: Any, context: str) -> str:
    if not isinstance(value, str) or not KUBERNETES_STABLE_ID.fullmatch(value):
        raise CollectorError(f"{context} is malformed")
    return value


def _canonical_json_sha256(value: Any) -> str:
    try:
        encoded = json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    except (TypeError, ValueError):
        raise CollectorError("production control state is not serializable") from None
    return hashlib.sha256(encoded).hexdigest()


def _validate_production_image(
    image: str, image_record: Mapping[str, Any]
) -> None:
    requested_digest = image.rsplit("@", 1)[1]
    if image_record.get("manifest_digest") != requested_digest:
        raise CollectorError(
            "the inspected image manifest digest does not match the requested digest"
        )
    repository_digests = image_record.get("repository_digests")
    if not isinstance(repository_digests, list) or image not in repository_digests:
        raise CollectorError(
            "image inspection did not confirm the requested repository digest"
        )


def _validate_production_topology(kubernetes_record: Mapping[str, Any]) -> None:
    deployments = kubernetes_record.get("deployments")
    pods = kubernetes_record.get("pods")
    if not isinstance(deployments, list) or not isinstance(pods, list):
        raise CollectorError("production application topology is malformed")

    deployments_by_name = {
        deployment.get("name"): deployment
        for deployment in deployments
        if isinstance(deployment, dict)
    }
    pod_counts = {role: 0 for role in PRODUCTION_MINIMUM_REPLICAS}
    for pod in pods:
        if not isinstance(pod, dict):
            raise CollectorError("production application topology is malformed")
        containers = pod.get("containers")
        if not isinstance(containers, list) or len(containers) != 1:
            raise CollectorError("production application topology is malformed")
        container = containers[0]
        if not isinstance(container, dict):
            raise CollectorError("production application topology is malformed")
        role = container.get("name")
        if role in pod_counts and pod.get("ready") is True:
            pod_counts[role] += 1

    for deployment_name, role in APPLICATION_DEPLOYMENTS.items():
        minimum = PRODUCTION_MINIMUM_REPLICAS[role]
        deployment = deployments_by_name.get(deployment_name)
        desired = (
            deployment.get("desired_replicas")
            if isinstance(deployment, dict)
            else None
        )
        if (
            isinstance(desired, bool)
            or not isinstance(desired, int)
            or desired < minimum
            or pod_counts[role] < minimum
        ):
            raise CollectorError(
                "the production profile requires at least "
                f"{minimum} ready {role} replicas"
            )


def _collect_promotion_receipts(
    receipt_paths: Mapping[str, Path],
    *,
    revision: str,
    image_digest: str,
    bundle_sha256: str,
    live_controls_sha256: str,
    environment: Mapping[str, str],
    collected_at: datetime,
) -> list[dict[str, Any]]:
    return [
        _validate_promotion_receipt(
            receipt_type,
            receipt_paths[receipt_type],
            revision=revision,
            image_digest=image_digest,
            bundle_sha256=bundle_sha256,
            live_controls_sha256=live_controls_sha256,
            environment=environment,
            collected_at=collected_at,
        )
        for receipt_type in REQUIRED_PROMOTION_RECEIPTS
    ]


def _validate_promotion_receipt(
    receipt_type: str,
    path: Path,
    *,
    revision: str,
    image_digest: str,
    bundle_sha256: str,
    live_controls_sha256: str,
    environment: Mapping[str, str],
    collected_at: datetime,
) -> dict[str, Any]:
    expected_environment = dict(environment)
    document, digest, size = _read_promotion_receipt(receipt_type, path)
    required_fields = {
        "bundle_sha256",
        "completed_at",
        "environment",
        "git_revision",
        "image_digest",
        "live_controls_sha256",
        "receipt_type",
        "schema_version",
        "started_at",
        "status",
    }
    if not isinstance(document, dict) or set(document) != required_fields:
        raise CollectorError(
            f"promotion receipt {receipt_type} does not match the required schema"
        )
    receipt_environment = document.get("environment")
    if not isinstance(receipt_environment, dict) or set(receipt_environment) != {
        "cluster_uid_sha256",
        "id",
        "namespace",
        "namespace_uid_sha256",
    }:
        raise CollectorError(
            f"promotion receipt {receipt_type} does not match the required schema"
        )
    schema_version = document.get("schema_version")
    if (
        not isinstance(schema_version, int)
        or isinstance(schema_version, bool)
        or schema_version != PROMOTION_RECEIPT_SCHEMA_VERSION
        or document.get("receipt_type") != receipt_type
    ):
        raise CollectorError(
            f"promotion receipt {receipt_type} has the wrong type or schema version"
        )
    if document.get("status") != "passed":
        raise CollectorError(f"promotion receipt {receipt_type} did not pass")
    if document.get("git_revision") != revision:
        raise CollectorError(
            f"promotion receipt {receipt_type} does not match Git HEAD"
        )
    if document.get("image_digest") != image_digest:
        raise CollectorError(
            f"promotion receipt {receipt_type} does not match the image digest"
        )
    if document.get("bundle_sha256") != bundle_sha256:
        raise CollectorError(
            f"promotion receipt {receipt_type} does not match the reviewed bundle"
        )
    if document.get("live_controls_sha256") != live_controls_sha256:
        raise CollectorError(
            f"promotion receipt {receipt_type} does not match live production controls"
        )
    if receipt_environment != expected_environment:
        raise CollectorError(
            f"promotion receipt {receipt_type} does not match the environment identity"
        )

    started_at = _parse_receipt_timestamp(document.get("started_at"), receipt_type)
    completed_at = _parse_receipt_timestamp(
        document.get("completed_at"), receipt_type
    )
    if completed_at < started_at:
        raise CollectorError(
            f"promotion receipt {receipt_type} completed before it started"
        )
    if completed_at > collected_at:
        raise CollectorError(
            f"promotion receipt {receipt_type} has a future completion timestamp"
        )
    if collected_at - completed_at > timedelta(
        seconds=PROMOTION_RECEIPT_MAX_AGE_SECONDS
    ):
        raise CollectorError(f"promotion receipt {receipt_type} is stale")

    return {
        "bundle_sha256": bundle_sha256,
        "completed_at": document["completed_at"],
        "environment": expected_environment,
        "git_revision": revision,
        "image_digest": image_digest,
        "live_controls_sha256": live_controls_sha256,
        "receipt_type": receipt_type,
        "schema_version": PROMOTION_RECEIPT_SCHEMA_VERSION,
        "sha256": digest,
        "size_bytes": size,
        "started_at": document["started_at"],
        "status": "passed",
    }


def _parse_receipt_timestamp(value: Any, receipt_type: str) -> datetime:
    if not isinstance(value, str) or not UTC_TIMESTAMP.fullmatch(value):
        raise CollectorError(
            f"promotion receipt {receipt_type} has a malformed UTC timestamp"
        )
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError:
        raise CollectorError(
            f"promotion receipt {receipt_type} has a malformed UTC timestamp"
        ) from None


def _read_promotion_receipt(
    receipt_type: str, path: Path
) -> tuple[Any, str, int]:
    try:
        path_metadata = path.lstat()
        if not stat.S_ISREG(path_metadata.st_mode):
            raise CollectorError(
                f"promotion receipt {receipt_type} must be a regular file"
            )
        if path_metadata.st_size > PROMOTION_RECEIPT_MAX_BYTES:
            raise CollectorError(f"promotion receipt {receipt_type} is too large")
        resolved_path = path.resolve(strict=True)
        resolved_metadata = resolved_path.lstat()
    except CollectorError:
        raise
    except OSError:
        raise CollectorError(
            f"promotion receipt {receipt_type} is missing or unreadable"
        ) from None
    if _file_fingerprint(path_metadata) != _file_fingerprint(resolved_metadata):
        raise CollectorError(
            f"promotion receipt {receipt_type} changed before validation"
        )

    try:
        open_flags = (
            os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_CLOEXEC", 0)
        )
        open_flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(resolved_path, open_flags)
        with os.fdopen(descriptor, "rb") as receipt_file:
            before = os.fstat(receipt_file.fileno())
            if _file_fingerprint(resolved_metadata) != _file_fingerprint(before):
                raise CollectorError(
                    f"promotion receipt {receipt_type} changed before validation"
                )
            content = receipt_file.read(PROMOTION_RECEIPT_MAX_BYTES + 1)
            after = os.fstat(receipt_file.fileno())
            final_metadata = resolved_path.lstat()
    except CollectorError:
        raise
    except OSError:
        raise CollectorError(
            f"promotion receipt {receipt_type} is missing or unreadable"
        ) from None

    fingerprint = _file_fingerprint(before)
    if (
        len(content) > PROMOTION_RECEIPT_MAX_BYTES
        or fingerprint != _file_fingerprint(after)
        or fingerprint != _file_fingerprint(final_metadata)
        or len(content) != after.st_size
    ):
        raise CollectorError(
            f"promotion receipt {receipt_type} changed or exceeded its size limit"
        )
    try:
        document = json.loads(content.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise CollectorError(
            f"promotion receipt {receipt_type} is not valid UTF-8 JSON"
        ) from None
    return document, hashlib.sha256(content).hexdigest(), len(content)


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
    image_id = _normalize_inspected_image_id(inspected.get("Id"))
    if image_id is None:
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
                "ephemeral_containers": _select_container_specs(
                    pod_spec.get("ephemeralContainers") or [],
                    "Kubernetes deployment topology",
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
    init_containers = deployment.get("init_containers")
    ephemeral_containers = deployment.get("ephemeral_containers")
    if (
        isinstance(desired_replicas, bool)
        or not isinstance(desired_replicas, int)
        or desired_replicas < 1
        or isinstance(generation, bool)
        or not isinstance(generation, int)
        or not isinstance(status, dict)
        or not isinstance(containers, list)
        or not isinstance(init_containers, list)
        or not isinstance(ephemeral_containers, list)
    ):
        raise CollectorError("application deployment topology is malformed")

    if init_containers or ephemeral_containers:
        raise CollectorError(
            "an application deployment contains an init or ephemeral container"
        )
    if len(containers) != 1 or containers[0].get("name") != role:
        raise CollectorError(
            "an application deployment must contain exactly one role container"
        )
    if containers[0].get("image") != image:
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
    init_containers = pod.get("init_containers")
    ephemeral_containers = pod.get("ephemeral_containers")
    if (
        not isinstance(containers, list)
        or not isinstance(init_containers, list)
        or not isinstance(ephemeral_containers, list)
    ):
        raise CollectorError("application pod topology is malformed")
    if init_containers or ephemeral_containers:
        raise CollectorError("an application pod contains an init or ephemeral container")
    if len(containers) != 1 or containers[0].get("name") != role:
        raise CollectorError(
            "an application pod must contain exactly one role container"
        )

    container = containers[0]
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


def _normalize_inspected_image_id(value: Any) -> str | None:
    """Normalize Docker- and Podman-shaped immutable image IDs."""

    if not isinstance(value, str) or CONTROL_CHARACTER.search(value):
        return None
    if IMAGE_ID.fullmatch(value):
        return value
    if BARE_IMAGE_ID.fullmatch(value):
        return f"sha256:{value}"
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
        "--profile",
        choices=("diagnostic", "production"),
        default="diagnostic",
        help="evidence policy profile (default: diagnostic)",
    )
    parser.add_argument(
        "--environment-id",
        help=(
            "stable non-secret deployment environment identity; "
            "required for production"
        ),
    )
    parser.add_argument(
        "--production-bundle",
        type=Path,
        help="exact reviewed provider-composed bundle; required for production",
    )
    parser.add_argument(
        "--binding-only",
        action="store_true",
        help=(
            "write a non-promotable production binding artifact before authoring "
            "receipts"
        ),
    )
    parser.add_argument(
        "--receipt",
        action="append",
        default=[],
        metavar="TYPE=PATH",
        help="validate one required production promotion receipt; repeat for each type",
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
            receipt_specs=options.receipt,
            profile=options.profile,
            environment_id=options.environment_id,
            production_bundle=options.production_bundle,
            binding_only=options.binding_only,
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
