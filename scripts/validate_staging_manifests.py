#!/usr/bin/env python3
"""Validate staging-only Kubernetes capacity contracts."""

from __future__ import annotations

import argparse
import re
import stat
import sys
from pathlib import Path
from typing import Any, Sequence

import yaml


ROOT = Path(__file__).resolve().parents[1]
STAGING_MINIO_MANIFEST = Path(
    "deploy/k8s/overlays/staging/minio-statefulset.yaml"
)
MIN_MINIO_TMP_BYTES = 2 * 1024**3
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
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
    statefulsets = [
        document
        for document in documents
        if isinstance(document, dict)
        and document.get("kind") == "StatefulSet"
        and document.get("metadata", {}).get("name") == "minio"
    ]
    if len(statefulsets) != 1:
        return ["staging bundle must contain exactly one StatefulSet named minio"]

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


def validate(path: Path = ROOT / STAGING_MINIO_MANIFEST) -> list[str]:
    try:
        documents = read_documents(path)
    except ValueError as error:
        return [str(error)]
    return validate_documents(documents)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate the staging MinIO temporary-storage contract."
    )
    parser.add_argument(
        "manifest",
        nargs="?",
        type=Path,
        default=ROOT / STAGING_MINIO_MANIFEST,
        help="MinIO StatefulSet or rendered staging bundle",
    )
    return parser


def main(arguments: Sequence[str] | None = None) -> int:
    options = build_parser().parse_args(arguments)
    errors = validate(options.manifest.resolve())
    if errors:
        print("staging manifest validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("Staging manifest capacity contracts are valid.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
