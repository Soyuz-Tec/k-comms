#!/usr/bin/env python3
"""Validate staging capacity, migration, and public-ingress contracts."""

from __future__ import annotations

import argparse
import ipaddress
import re
import stat
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
STAGING_MINIO_MANIFEST = Path(
    "deploy/k8s/overlays/staging/minio-statefulset.yaml"
)
STAGING_MIGRATION_MANIFEST = Path(
    "deploy/k8s/overlays/staging/migration-job.yaml"
)
STAGING_CONFIG_PATCH = Path(
    "deploy/k8s/overlays/staging/configmap-patch.yaml"
)
MIN_MINIO_TMP_BYTES = 2 * 1024**3
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
STAGING_INSTANT_ROOM_TENANT = "k-comms-staging"
_BINARY_QUANTITY = re.compile(r"^(?P<value>[1-9][0-9]*)(?P<unit>Ki|Mi|Gi|Ti)?$")
_BINARY_FACTORS = {
    None: 1,
    "Ki": 1024,
    "Mi": 1024**2,
    "Gi": 1024**3,
    "Ti": 1024**4,
}


def parse_binary_quantity(value: Any) -> int | None:
    """Return bytes for the integer Kubernetes quantities used by this contract."""

    if isinstance(value, int) and not isinstance(value, bool):
        return value if value > 0 else None
    if not isinstance(value, str):
        return None
    match = _BINARY_QUANTITY.fullmatch(value)
    if match is None:
        return None
    return int(match.group("value")) * _BINARY_FACTORS[match.group("unit")]


def _named_items(value: Any, name: str) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return []
    return [
        item
        for item in value
        if isinstance(item, dict) and item.get("name") == name
    ]


def validate_documents(documents: Sequence[Any]) -> list[str]:
    errors: list[str] = []
    errors.extend(validate_instant_room_gate(documents))

    migration_jobs = [
        document
        for document in documents
        if isinstance(document, dict)
        and document.get("kind") == "Job"
        and document.get("metadata", {}).get("name") == "k-comms-migrate"
    ]
    if len(migration_jobs) != 1:
        errors.append("staging bundle must contain exactly one Job named k-comms-migrate")
    else:
        errors.extend(validate_migration_job(migration_jobs[0]))

    statefulsets = [
        document
        for document in documents
        if isinstance(document, dict)
        and document.get("kind") == "StatefulSet"
        and document.get("metadata", {}).get("name") == "minio"
    ]
    if len(statefulsets) != 1:
        errors.append("staging bundle must contain exactly one StatefulSet named minio")
        return errors

    pod_spec = (
        statefulsets[0]
        .get("spec", {})
        .get("template", {})
        .get("spec", {})
    )
    if not isinstance(pod_spec, dict):
        return ["StatefulSet minio must define a pod spec"]

    containers = _named_items(pod_spec.get("containers"), "minio")
    if len(containers) != 1:
        errors.append("StatefulSet minio must contain exactly one minio container")
    else:
        mounts = _named_items(containers[0].get("volumeMounts"), "tmp")
        if len(mounts) != 1 or mounts[0].get("mountPath") != "/tmp":
            errors.append("minio container must mount volume tmp exactly once at /tmp")
        elif mounts[0].get("readOnly") is True:
            errors.append("minio /tmp mount must be writable")

    volumes = _named_items(pod_spec.get("volumes"), "tmp")
    if len(volumes) != 1:
        errors.append("StatefulSet minio must define exactly one tmp volume")
        return errors

    empty_dir = volumes[0].get("emptyDir")
    if not isinstance(empty_dir, dict):
        errors.append("StatefulSet minio tmp volume must be an emptyDir")
        return errors
    if empty_dir.get("medium") not in (None, ""):
        errors.append("StatefulSet minio tmp emptyDir must use node storage, not memory")

    size_limit = empty_dir.get("sizeLimit")
    size_bytes = parse_binary_quantity(size_limit)
    if size_bytes is None:
        errors.append("StatefulSet minio tmp emptyDir must define a valid sizeLimit")
    elif size_bytes < MIN_MINIO_TMP_BYTES:
        errors.append(
            "StatefulSet minio tmp emptyDir sizeLimit must be at least 2Gi "
            "to cover the 1Gi tenant attachment ceiling plus temporary overhead"
        )
    return errors


def validate_instant_room_gate(documents: Sequence[Any]) -> list[str]:
    """Validate the portable-off and provider-composed staging contracts."""

    errors: list[str] = []
    config_maps = [
        document
        for document in documents
        if isinstance(document, dict)
        and document.get("kind") == "ConfigMap"
        and document.get("metadata", {}).get("name") == "k-comms-config"
    ]
    if len(config_maps) != 1:
        return [
            "staging bundle must contain exactly one ConfigMap named k-comms-config"
        ]

    data = config_maps[0].get("data")
    if not isinstance(data, dict):
        return ["ConfigMap k-comms-config must define data"]

    enabled = str(data.get("INSTANT_ROOMS_ENABLED", "")).strip().lower()
    tenant_slug = str(data.get("INSTANT_ROOM_TENANT_SLUG", "")).strip()
    raw_trusted_cidrs = str(data.get("TRUSTED_PROXY_CIDRS", "")).strip()

    if enabled == "false":
        if tenant_slug:
            errors.append(
                "ConfigMap k-comms-config: INSTANT_ROOM_TENANT_SLUG must be "
                "empty while portable staging instant rooms are disabled"
            )
        if raw_trusted_cidrs:
            errors.append(
                "ConfigMap k-comms-config: TRUSTED_PROXY_CIDRS must be empty "
                "in the fail-closed portable staging overlay"
            )
        return errors

    if enabled != "true":
        return [
            (
                "ConfigMap k-comms-config: INSTANT_ROOMS_ENABLED must be "
                "explicitly true or false"
            )
        ]

    if tenant_slug != STAGING_INSTANT_ROOM_TENANT:
        errors.append(
            "ConfigMap k-comms-config: enabled staging instant rooms must use "
            f"the provisioned tenant {STAGING_INSTANT_ROOM_TENANT}"
        )

    trusted_cidrs, cidr_errors = _trusted_proxy_networks(raw_trusted_cidrs)
    errors.extend(cidr_errors)
    errors.extend(_validate_staging_edge_ingress(documents, trusted_cidrs))
    return errors


def _trusted_proxy_networks(
    raw_value: str,
) -> tuple[set[ipaddress._BaseNetwork], list[str]]:
    raw_cidrs = [item.strip() for item in raw_value.split(",") if item.strip()]
    if not raw_cidrs:
        return set(), [
            (
                "ConfigMap k-comms-config: enabled staging instant rooms "
                "require provider-specific TRUSTED_PROXY_CIDRS"
            )
        ]

    forbidden_defaults = {
        ipaddress.ip_network("10.0.0.0/8"),
        ipaddress.ip_network("172.16.0.0/12"),
        ipaddress.ip_network("192.168.0.0/16"),
        ipaddress.ip_network("fc00::/7"),
    }
    networks: set[ipaddress._BaseNetwork] = set()
    errors: list[str] = []
    unsafe = False

    for raw_cidr in raw_cidrs:
        try:
            network = ipaddress.ip_network(raw_cidr, strict=True)
        except ValueError:
            errors.append(
                "ConfigMap k-comms-config: TRUSTED_PROXY_CIDRS contains an "
                "invalid or placeholder network"
            )
            continue

        if (
            network.prefixlen == 0
            or network.is_loopback
            or network.is_link_local
            or network.is_multicast
            or any(
                network == default or network.supernet_of(default)
                for default in forbidden_defaults
                if network.version == default.version
            )
        ):
            unsafe = True
        networks.add(network)

    if unsafe:
        errors.append(
            "ConfigMap k-comms-config: TRUSTED_PROXY_CIDRS must use exact "
            "provider ingress ranges, not generic or unsafe networks"
        )
    return networks, errors


def _validate_staging_edge_ingress(
    documents: Sequence[Any],
    trusted_cidrs: set[ipaddress._BaseNetwork],
) -> list[str]:
    errors: list[str] = []
    policies = [
        document
        for document in documents
        if isinstance(document, dict)
        and document.get("kind") == "NetworkPolicy"
        and document.get("metadata", {}).get("name") == "k-comms-edge-ingress"
    ]
    if len(policies) != 1:
        return [
            (
                "enabled staging instant rooms require exactly one "
                "NetworkPolicy named k-comms-edge-ingress"
            )
        ]

    ingress_rules = policies[0].get("spec", {}).get("ingress")
    if not isinstance(ingress_rules, list) or not ingress_rules:
        return [
            (
                "NetworkPolicy k-comms-edge-ingress: provider ingress sources "
                "must be explicit when staging instant rooms are enabled"
            )
        ]

    policy_cidrs: set[ipaddress._BaseNetwork] = set()
    invalid_source = False
    invalid_ports = False
    for rule in ingress_rules:
        if not isinstance(rule, dict):
            invalid_source = True
            invalid_ports = True
            continue

        ports = rule.get("ports")
        if (
            not isinstance(ports, list)
            or len(ports) != 1
            or not isinstance(ports[0], dict)
            or ports[0].get("protocol") != "TCP"
            or ports[0].get("port") != 4000
            or set(ports[0]) != {"protocol", "port"}
        ):
            invalid_ports = True

        sources = rule.get("from")
        if not isinstance(sources, list) or not sources:
            invalid_source = True
            continue
        for source in sources:
            if not isinstance(source, dict) or set(source) != {"ipBlock"}:
                invalid_source = True
                continue
            ip_block = source.get("ipBlock")
            if not isinstance(ip_block, dict) or set(ip_block) != {"cidr"}:
                invalid_source = True
                continue
            try:
                policy_cidrs.add(
                    ipaddress.ip_network(ip_block.get("cidr"), strict=True)
                )
            except (TypeError, ValueError):
                invalid_source = True

    if invalid_source:
        errors.append(
            "NetworkPolicy k-comms-edge-ingress: every source must be an "
            "explicit valid ipBlock CIDR"
        )
    if invalid_ports:
        errors.append(
            "NetworkPolicy k-comms-edge-ingress: every ingress rule must expose "
            "only TCP port 4000"
        )
    if policy_cidrs != trusted_cidrs:
        errors.append(
            "NetworkPolicy k-comms-edge-ingress: source CIDRs must exactly "
            "match TRUSTED_PROXY_CIDRS"
        )
    return errors


def validate_migration_job(document: dict[str, Any]) -> list[str]:
    """Validate the fail-closed, bounded staging migration contract."""

    errors: list[str] = []
    spec = document.get("spec")
    if not isinstance(spec, dict):
        return ["Job k-comms-migrate must define a spec"]
    if spec.get("backoffLimit") != 0:
        errors.append("Job k-comms-migrate backoffLimit must be 0")

    deadline = spec.get("activeDeadlineSeconds")
    if not isinstance(deadline, int) or isinstance(deadline, bool) or deadline <= 0:
        errors.append("Job k-comms-migrate activeDeadlineSeconds must be positive")
        deadline = None

    pod_spec = spec.get("template", {}).get("spec", {})
    if not isinstance(pod_spec, dict):
        return errors + ["Job k-comms-migrate must define a pod spec"]
    if pod_spec.get("restartPolicy") != "Never":
        errors.append("Job k-comms-migrate restartPolicy must be Never")

    containers = _named_items(pod_spec.get("containers"), "migrate")
    if len(containers) != 1:
        return errors + ["Job k-comms-migrate must contain exactly one migrate container"]
    container = containers[0]
    if container.get("command") != ["/app/bin/k_comms"] or container.get("args") != [
        "eval",
        "CommsCore.Release.migrate()",
    ]:
        errors.append(
            "Job k-comms-migrate must use the reviewed CommsCore.Release.migrate() runner"
        )

    environment = {
        item.get("name"): item.get("value")
        for item in container.get("env", [])
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }
    if environment.get("K_COMMS_MIGRATION_REQUIRE_QUIESCENCE") != "true":
        errors.append(
            "Job k-comms-migrate K_COMMS_MIGRATION_REQUIRE_QUIESCENCE must be true"
        )

    lock_timeout = _positive_decimal(
        environment.get("K_COMMS_MIGRATION_LOCK_TIMEOUT_MS")
    )
    if lock_timeout is None or lock_timeout > 30_000:
        errors.append(
            "Job k-comms-migrate K_COMMS_MIGRATION_LOCK_TIMEOUT_MS must be 1..30000"
        )
    statement_timeout = _positive_decimal(
        environment.get("K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS")
    )
    if statement_timeout is None:
        errors.append(
            "Job k-comms-migrate K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS must be positive"
        )
    elif deadline is not None and statement_timeout > (deadline - 30) * 1000:
        errors.append(
            "Job k-comms-migrate statement timeout must leave at least 30 seconds "
            "before activeDeadlineSeconds"
        )
    return errors


def _positive_decimal(value: Any) -> int | None:
    if not isinstance(value, str) or re.fullmatch(r"[1-9][0-9]*", value) is None:
        return None
    return int(value)


def read_documents(path: Path) -> list[Any]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ValueError(f"{path} is missing or unreadable") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"{path} must be a regular file, not a symlink")
    if metadata.st_size > MAX_MANIFEST_BYTES:
        raise ValueError(f"{path} exceeds {MAX_MANIFEST_BYTES} bytes")
    try:
        content = path.read_bytes()
    except OSError as error:
        raise ValueError(f"{path} is missing or unreadable") from error
    if len(content) != metadata.st_size:
        raise ValueError(f"{path} changed while it was being read")
    try:
        return list(yaml.safe_load_all(content.decode("utf-8")))
    except (UnicodeDecodeError, yaml.YAMLError) as error:
        raise ValueError(f"{path} is not valid UTF-8 YAML") from error


def validate(path: Path | None = None) -> list[str]:
    documents: list[Any] = []
    paths = (
        [path]
        if path is not None
        else [
            ROOT / STAGING_CONFIG_PATCH,
            ROOT / STAGING_MINIO_MANIFEST,
            ROOT / STAGING_MIGRATION_MANIFEST,
        ]
    )
    try:
        for manifest_path in paths:
            documents.extend(read_documents(manifest_path))
    except ValueError as error:
        return [str(error)]
    return validate_documents(documents)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Validate staging capacity, migration, and instant-room ingress "
            "contracts."
        )
    )
    parser.add_argument(
        "manifest",
        nargs="?",
        type=Path,
        default=None,
        help=(
            "rendered staging bundle; when omitted, validates the repository "
            "MinIO StatefulSet and migration Job"
        ),
    )
    return parser


def main(arguments: Sequence[str] | None = None) -> int:
    options = build_parser().parse_args(arguments)
    errors = validate(options.manifest.resolve() if options.manifest else None)
    if errors:
        print("staging manifest validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(
        "Staging capacity, migration, and instant-room ingress contracts are valid."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
