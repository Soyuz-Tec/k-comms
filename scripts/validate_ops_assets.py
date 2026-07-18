#!/usr/bin/env python3
"""Validate K-Comms alert, dashboard, and executable runbook contracts."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

import yaml


ROOT = Path(__file__).resolve().parents[1]
MAX_ASSET_BYTES = 2 * 1024 * 1024
ALERT_RULES = Path("ops/alerts/k-comms.rules.yml")
DASHBOARD = Path("ops/dashboards/service-overview.json")
RUNBOOK_DIR = Path("docs/08-reliability/runbooks")
EXPECTED_RUNBOOKS = {
    "database-failover.md",
    "object-storage-failure.md",
    "queue-backlog.md",
    "service-degradation.md",
    "websocket-saturation.md",
}
REQUIRED_LABELS = {"severity", "owner", "service", "component"}
REQUIRED_ANNOTATIONS = {
    "summary",
    "user_impact",
    "current_value",
    "environment",
    "release_revision",
    "dashboard_url",
    "runbook_url",
    "diagnostic_query",
    "safe_mitigation",
    "stop_condition",
    "validation",
    "escalation",
}
REQUIRED_RUNBOOK_METADATA = (
    "**Owner:**",
    "**Alerts/triggers:**",
    "**Default severity:**",
    "**Dashboard:**",
    "**Required context:**",
)
REQUIRED_RUNBOOK_SECTIONS = (
    "## User impact",
    "## Preconditions and safety warnings",
    "## Initial diagnosis",
    "## Stabilization actions",
    "## Stop conditions",
    "## Escalation",
    "## Recovery validation",
    "## Rollback and removal of temporary controls",
    "## Evidence to capture",
    "## Follow-up",
)
FORBIDDEN_GENERIC_RUNBOOK_TEXT = (
    "Apply the documented safe degradation control.",
    "Reduce load or concurrency without dropping durable work.",
    "Escalate to the owning team, SRE, security if data exposure is possible",
)
OWNER_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{2,63}$")
RUNBOOK_URL_PATH = re.compile(r"/(docs/08-reliability/runbooks/[^/]+\.md)$")


class AssetReadError(ValueError):
    """An operations asset could not be read safely."""


def read_regular_text(path: Path) -> str:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise AssetReadError(f"{path} is missing or unreadable") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise AssetReadError(f"{path} must be a regular file, not a symlink")
    if metadata.st_size > MAX_ASSET_BYTES:
        raise AssetReadError(f"{path} exceeds {MAX_ASSET_BYTES} bytes")
    try:
        content = path.read_bytes()
    except OSError as error:
        raise AssetReadError(f"{path} is missing or unreadable") from error
    if len(content) != metadata.st_size:
        raise AssetReadError(f"{path} changed while it was being read")
    try:
        return content.decode("utf-8")
    except UnicodeDecodeError as error:
        raise AssetReadError(f"{path} is not valid UTF-8") from error


def validate_alert_document(document: Any, root: Path) -> list[str]:
    errors: list[str] = []
    if not isinstance(document, dict) or set(document) != {"groups"}:
        return ["alert rules must be an object containing only groups"]
    groups = document.get("groups")
    if not isinstance(groups, list) or not groups:
        return ["alert rules groups must be a non-empty array"]

    group_names: set[str] = set()
    alert_names: set[str] = set()
    for group_index, group in enumerate(groups):
        prefix = f"groups[{group_index}]"
        if not isinstance(group, dict):
            errors.append(f"{prefix} must be an object")
            continue
        name = group.get("name")
        rules = group.get("rules")
        if not isinstance(name, str) or not name:
            errors.append(f"{prefix}.name is required")
        elif name in group_names:
            errors.append(f"duplicate alert group name {name}")
        else:
            group_names.add(name)
        if not isinstance(rules, list) or not rules:
            errors.append(f"{prefix}.rules must be a non-empty array")
            continue

        for rule_index, rule in enumerate(rules):
            rule_prefix = f"{prefix}.rules[{rule_index}]"
            if not isinstance(rule, dict):
                errors.append(f"{rule_prefix} must be an object")
                continue
            alert = rule.get("alert")
            if not isinstance(alert, str) or not re.fullmatch(r"KComms[A-Za-z0-9]+", alert):
                errors.append(f"{rule_prefix}.alert must be a stable KComms alert name")
                continue
            if alert in alert_names:
                errors.append(f"duplicate alert name {alert}")
            alert_names.add(alert)
            expression = rule.get("expr")
            if not isinstance(expression, str) or not expression.strip():
                errors.append(f"{alert}.expr must be non-empty")
            if not isinstance(rule.get("for"), str) or not rule["for"].strip():
                errors.append(f"{alert}.for must define a sustained interval")

            labels = rule.get("labels")
            annotations = rule.get("annotations")
            if not isinstance(labels, dict):
                errors.append(f"{alert}.labels must be an object")
                continue
            if not isinstance(annotations, dict):
                errors.append(f"{alert}.annotations must be an object")
                continue
            missing_labels = sorted(REQUIRED_LABELS - set(labels))
            missing_annotations = sorted(REQUIRED_ANNOTATIONS - set(annotations))
            if missing_labels:
                errors.append(f"{alert} is missing labels: {', '.join(missing_labels)}")
            if missing_annotations:
                errors.append(
                    f"{alert} is missing annotations: {', '.join(missing_annotations)}"
                )
            if missing_labels or missing_annotations:
                continue
            if labels["severity"] not in {"info", "warning", "critical"}:
                errors.append(f"{alert}.labels.severity is unsupported")
            if labels["service"] != "k-comms":
                errors.append(f"{alert}.labels.service must be k-comms")
            if not isinstance(labels["owner"], str) or not OWNER_PATTERN.fullmatch(
                labels["owner"]
            ):
                errors.append(f"{alert}.labels.owner must be a stable role slug")
            for field in REQUIRED_ANNOTATIONS:
                value = annotations[field]
                if not isinstance(value, str) or not value.strip():
                    errors.append(f"{alert}.annotations.{field} must be non-empty text")
            if annotations["environment"] != "{{ $externalLabels.environment }}":
                errors.append(
                    f"{alert}.annotations.environment must use the external environment label"
                )
            if annotations["release_revision"] != (
                "{{ $externalLabels.release_revision }}"
            ):
                errors.append(
                    f"{alert}.annotations.release_revision must use the external release label"
                )
            if annotations["current_value"] != "{{ $value }}":
                errors.append(f"{alert}.annotations.current_value must render $value")
            release_placeholder = "{{ $externalLabels.release_revision }}"
            if release_placeholder not in annotations["runbook_url"]:
                errors.append(f"{alert}.annotations.runbook_url must be release-versioned")
            if release_placeholder not in annotations["dashboard_url"]:
                errors.append(f"{alert}.annotations.dashboard_url must be release-versioned")
            if not annotations["dashboard_url"].endswith(
                "/ops/dashboards/service-overview.json"
            ):
                errors.append(f"{alert}.annotations.dashboard_url targets an unknown dashboard")
            match = RUNBOOK_URL_PATH.search(annotations["runbook_url"])
            if not match:
                errors.append(f"{alert}.annotations.runbook_url targets an unknown path")
            else:
                runbook_path = root / Path(match.group(1))
                if not runbook_path.is_file():
                    errors.append(f"{alert} references missing runbook {match.group(1)}")
                else:
                    try:
                        runbook_text = read_regular_text(runbook_path)
                    except AssetReadError as error:
                        errors.append(str(error))
                    else:
                        if alert not in runbook_text:
                            errors.append(
                                f"{alert} is not named by its referenced runbook {match.group(1)}"
                            )
            for field in (
                "user_impact",
                "diagnostic_query",
                "safe_mitigation",
                "stop_condition",
                "validation",
                "escalation",
            ):
                value = annotations[field]
                if isinstance(value, str) and len(value.strip()) < 20:
                    errors.append(f"{alert}.annotations.{field} is not actionable")
    return errors


def validate_dashboard_document(document: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(document, dict):
        return ["dashboard must be a JSON object"]
    if document.get("title") != "K-Comms Service Overview":
        errors.append("dashboard title must be K-Comms Service Overview")
    if not isinstance(document.get("uid"), str) or not document["uid"].strip():
        errors.append("dashboard uid is required")
    panels = document.get("panels")
    if not isinstance(panels, list) or not panels:
        return errors + ["dashboard panels must be a non-empty array"]
    ids: set[int] = set()
    titles: set[str] = set()
    for index, panel in enumerate(panels):
        prefix = f"dashboard.panels[{index}]"
        if not isinstance(panel, dict):
            errors.append(f"{prefix} must be an object")
            continue
        panel_id = panel.get("id")
        title = panel.get("title")
        if not isinstance(panel_id, int) or isinstance(panel_id, bool):
            errors.append(f"{prefix}.id must be an integer")
        elif panel_id in ids:
            errors.append(f"duplicate dashboard panel id {panel_id}")
        else:
            ids.add(panel_id)
        if not isinstance(title, str) or not title.strip():
            errors.append(f"{prefix}.title is required")
        elif title in titles:
            errors.append(f"duplicate dashboard panel title {title}")
        else:
            titles.add(title)
        targets = panel.get("targets")
        if not isinstance(targets, list) or not targets:
            errors.append(f"{prefix}.targets must be a non-empty array")
            continue
        ref_ids: set[str] = set()
        for target_index, target in enumerate(targets):
            target_prefix = f"{prefix}.targets[{target_index}]"
            if not isinstance(target, dict):
                errors.append(f"{target_prefix} must be an object")
                continue
            expression = target.get("expr")
            ref_id = target.get("refId")
            if not isinstance(expression, str) or not expression.strip():
                errors.append(f"{target_prefix}.expr must be non-empty")
            if not isinstance(ref_id, str) or not ref_id.strip():
                errors.append(f"{target_prefix}.refId is required")
            elif ref_id in ref_ids:
                errors.append(f"{prefix} has duplicate refId {ref_id}")
            else:
                ref_ids.add(ref_id)
    return errors


def validate_runbook_text(name: str, text: str) -> list[str]:
    errors: list[str] = []
    if not text.startswith("# Runbook:"):
        errors.append(f"{name} must begin with a Runbook title")
    for marker in REQUIRED_RUNBOOK_METADATA:
        if marker not in text:
            errors.append(f"{name} is missing metadata {marker}")
    positions: list[int] = []
    for section in REQUIRED_RUNBOOK_SECTIONS:
        position = text.find(section)
        if position < 0:
            errors.append(f"{name} is missing section {section}")
        else:
            positions.append(position)
    if positions and positions != sorted(positions):
        errors.append(f"{name} runbook sections are out of contract order")
    if "```bash" not in text:
        errors.append(f"{name} must include bounded executable diagnostic commands")
    if len(text.splitlines()) < 80:
        errors.append(f"{name} is too short to be an executable operational procedure")
    for forbidden in FORBIDDEN_GENERIC_RUNBOOK_TEXT:
        if forbidden in text:
            errors.append(f"{name} still contains generic placeholder procedure text")
    if not re.search(r"\bstop\b", text, re.I):
        errors.append(f"{name} does not define a stop condition")
    if not re.search(r"\b(release revision|release/environment|release and environment)\b", text, re.I):
        errors.append(f"{name} does not require immutable release context")
    return errors


def validate_ops_assets(root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    try:
        alert_text = read_regular_text(root / ALERT_RULES)
        alert_document = yaml.safe_load(alert_text)
    except (AssetReadError, yaml.YAMLError) as error:
        errors.append(f"alert rules could not be loaded: {error}")
    else:
        errors.extend(validate_alert_document(alert_document, root))

    try:
        dashboard_text = read_regular_text(root / DASHBOARD)
        dashboard_document = json.loads(dashboard_text)
    except (AssetReadError, json.JSONDecodeError) as error:
        errors.append(f"dashboard could not be loaded: {error}")
    else:
        errors.extend(validate_dashboard_document(dashboard_document))

    runbook_dir = root / RUNBOOK_DIR
    actual_runbooks = (
        {path.name for path in runbook_dir.glob("*.md") if path.is_file()}
        if runbook_dir.is_dir()
        else set()
    )
    missing_runbooks = sorted(EXPECTED_RUNBOOKS - actual_runbooks)
    unexpected_runbooks = sorted(actual_runbooks - EXPECTED_RUNBOOKS)
    if missing_runbooks:
        errors.append(f"missing runbooks: {', '.join(missing_runbooks)}")
    if unexpected_runbooks:
        errors.append(f"unclassified runbooks: {', '.join(unexpected_runbooks)}")

    fingerprints: dict[str, str] = {}
    for name in sorted(EXPECTED_RUNBOOKS & actual_runbooks):
        try:
            text = read_regular_text(runbook_dir / name)
        except AssetReadError as error:
            errors.append(str(error))
            continue
        errors.extend(validate_runbook_text(name, text))
        normalized = re.sub(r"\s+", " ", text).strip().encode("utf-8")
        digest = hashlib.sha256(normalized).hexdigest()
        if digest in fingerprints:
            errors.append(f"{name} duplicates runbook {fingerprints[digest]}")
        else:
            fingerprints[digest] = name
    return errors


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate K-Comms alert, dashboard, and runbook assets."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=ROOT,
        help=f"repository root (default: {ROOT})",
    )
    return parser


def main(arguments: Sequence[str] | None = None) -> int:
    options = build_parser().parse_args(arguments)
    errors = validate_ops_assets(options.root.resolve())
    if errors:
        print("operations asset validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("Operations alert, dashboard, and runbook assets are valid.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
