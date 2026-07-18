#!/usr/bin/env python3
"""Validate the release-bound internal-production readiness ledger.

The validator checks structure, exact gate coverage, evidence metadata, expiry,
and decision consistency. It never creates approvals or treats a template as
production-ready.
"""

from __future__ import annotations

import argparse
import json
import re
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence
from urllib.parse import urlsplit

from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SCHEMA = (
    ROOT
    / "docs"
    / "13-delivery-plan"
    / "internal-production-readiness-ledger.schema.json"
)
MAX_DOCUMENT_BYTES = 1024 * 1024
TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

EXPECTED_GATE_IDS = (
    "application.code_quality",
    "application.security",
    "application.browser_usability",
    "application.delivery_correctness",
    "application.data_change",
    "application.runtime_resilience",
    "application.recovery",
    "application.release_safety",
    "environment.infrastructure",
    "environment.postgresql",
    "environment.object_storage",
    "environment.providers",
    "environment.secrets",
    "environment.network_and_observability",
    "environment.corporate_authentication",
    "environment.performance_and_resilience",
    "environment.alerting",
    "environment.operating_authority",
    "environment.data_policy",
    "environment.budget",
    "people.representative_study",
    "people.usability_score",
    "people.manual_accessibility",
    "people.role_exercises",
    "people.internal_pilot",
    "people.release_signoff",
)
EXPECTED_SIGNOFF_ROLES = (
    "product",
    "accessibility",
    "security",
    "operations",
    "business",
)
PLACEHOLDER = re.compile(r"(?:replace|example|placeholder|todo|tbd)", re.I)


class LedgerReadError(ValueError):
    """The ledger or schema could not be read safely."""


def parse_timestamp(value: str, field: str, errors: list[str]) -> datetime | None:
    try:
        return datetime.strptime(value, TIMESTAMP_FORMAT).replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        errors.append(f"{field} must be a UTC timestamp formatted YYYY-MM-DDTHH:MM:SSZ")
        return None


def json_path(parts: Sequence[Any]) -> str:
    path = "$"
    for part in parts:
        path += f"[{part}]" if isinstance(part, int) else f".{part}"
    return path


def validate_evidence_uri(value: str | None, field: str, errors: list[str]) -> None:
    if value is None:
        return
    parsed = urlsplit(value)
    if not parsed.scheme or not parsed.netloc:
        errors.append(f"{field} must be an absolute evidence URI")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        errors.append(
            f"{field} must not contain embedded credentials, a query, or a fragment"
        )
    if PLACEHOLDER.search(value):
        errors.append(f"{field} contains a placeholder instead of retained evidence")


def validate_actor(value: str | None, field: str, errors: list[str]) -> None:
    if value is not None and PLACEHOLDER.search(value):
        errors.append(f"{field} contains a placeholder instead of an accountable role")


def normalize_actor(value: str) -> str:
    """Normalize an actor identifier for separation-of-duties comparisons."""

    return " ".join(value.split()).casefold()


def validate_document(
    document: Mapping[str, Any],
    schema: Mapping[str, Any],
    *,
    as_of: datetime | None = None,
) -> list[str]:
    """Return every validation error; an empty list means structurally valid."""

    errors: list[str] = []
    as_of = as_of or datetime.now(timezone.utc)
    if as_of.tzinfo is None:
        as_of = as_of.replace(tzinfo=timezone.utc)
    else:
        as_of = as_of.astimezone(timezone.utc)

    schema_validator = Draft202012Validator(schema)
    for error in sorted(
        schema_validator.iter_errors(document),
        key=lambda item: tuple(str(part) for part in item.absolute_path),
    ):
        errors.append(f"{json_path(list(error.absolute_path))}: {error.message}")
    required_top_level = {
        "template",
        "generated_at",
        "release",
        "production_ready",
        "decision",
        "gates",
        "signoffs",
    }
    gate_fields = {
        "id",
        "category",
        "status",
        "owner",
        "approver",
        "assessed_at",
        "review_due_at",
        "evidence_uri",
    }
    signoff_fields = {"role", "status", "signer", "signed_at", "evidence_uri"}
    release_fields = {"git_revision", "image_digest", "bundle_sha256", "environment_id"}
    decision_fields = {
        "status",
        "decided_at",
        "expires_at",
        "approver",
        "evidence_uri",
    }
    if not required_top_level.issubset(document):
        return errors
    gates = document["gates"]
    signoffs = document["signoffs"]
    if (
        not isinstance(gates, list)
        or not isinstance(signoffs, list)
        or not isinstance(document["release"], dict)
        or not isinstance(document["decision"], dict)
        or not release_fields.issubset(document["release"])
        or not decision_fields.issubset(document["decision"])
        or any(not isinstance(gate, dict) or not gate_fields.issubset(gate) for gate in gates)
        or any(
            not isinstance(signoff, dict) or not signoff_fields.issubset(signoff)
            for signoff in signoffs
        )
    ):
        return errors

    gate_ids = [gate["id"] for gate in gates]
    duplicate_gate_ids = sorted({gate_id for gate_id in gate_ids if gate_ids.count(gate_id) > 1})
    if duplicate_gate_ids:
        errors.append(f"duplicate gate ids: {', '.join(duplicate_gate_ids)}")
    missing_gate_ids = sorted(set(EXPECTED_GATE_IDS) - set(gate_ids))
    extra_gate_ids = sorted(set(gate_ids) - set(EXPECTED_GATE_IDS))
    if missing_gate_ids:
        errors.append(f"missing required gate ids: {', '.join(missing_gate_ids)}")
    if extra_gate_ids:
        errors.append(f"unsupported gate ids: {', '.join(extra_gate_ids)}")

    signoff_roles = [signoff["role"] for signoff in signoffs]
    duplicate_roles = sorted(
        {role for role in signoff_roles if signoff_roles.count(role) > 1}
    )
    if duplicate_roles:
        errors.append(f"duplicate signoff roles: {', '.join(duplicate_roles)}")
    missing_roles = sorted(set(EXPECTED_SIGNOFF_ROLES) - set(signoff_roles))
    extra_roles = sorted(set(signoff_roles) - set(EXPECTED_SIGNOFF_ROLES))
    if missing_roles:
        errors.append(f"missing required signoff roles: {', '.join(missing_roles)}")
    if extra_roles:
        errors.append(f"unsupported signoff roles: {', '.join(extra_roles)}")

    generated_at = document["generated_at"]
    parsed_generated_at = None
    if generated_at is not None:
        parsed_generated_at = parse_timestamp(generated_at, "generated_at", errors)
        if parsed_generated_at and parsed_generated_at > as_of:
            errors.append("generated_at must not be in the future")

    passed_gate_assessments: list[tuple[str, datetime]] = []
    for index, gate in enumerate(gates):
        prefix = f"gates[{index}] ({gate['id']})"
        expected_category = gate["id"].split(".", 1)[0]
        if gate["category"] != expected_category:
            errors.append(
                f"{prefix}.category must be {expected_category!r} to match its id"
            )
        validate_actor(gate["owner"], f"{prefix}.owner", errors)
        validate_actor(gate["approver"], f"{prefix}.approver", errors)
        validate_evidence_uri(gate["evidence_uri"], f"{prefix}.evidence_uri", errors)

        if gate["status"] == "passed":
            required_evidence = (
                "owner",
                "approver",
                "assessed_at",
                "review_due_at",
                "evidence_uri",
            )
            for field in required_evidence:
                if gate[field] is None:
                    errors.append(f"{prefix}.{field} is required when status is passed")
            if (
                isinstance(gate["owner"], str)
                and isinstance(gate["approver"], str)
                and normalize_actor(gate["owner"])
                == normalize_actor(gate["approver"])
            ):
                errors.append(
                    f"{prefix}.approver must be separate from the gate owner"
                )
            assessed_at = (
                parse_timestamp(gate["assessed_at"], f"{prefix}.assessed_at", errors)
                if gate["assessed_at"] is not None
                else None
            )
            review_due_at = (
                parse_timestamp(gate["review_due_at"], f"{prefix}.review_due_at", errors)
                if gate["review_due_at"] is not None
                else None
            )
            if assessed_at and assessed_at > as_of:
                errors.append(f"{prefix}.assessed_at must not be in the future")
            if assessed_at:
                passed_gate_assessments.append((prefix, assessed_at))
            if assessed_at and review_due_at and review_due_at <= assessed_at:
                errors.append(f"{prefix}.review_due_at must be later than assessed_at")
            if review_due_at and review_due_at <= as_of:
                errors.append(
                    f"{prefix} is expired as of {as_of.strftime(TIMESTAMP_FORMAT)}; mark it expired and re-run the gate"
                )

    passed_signoff_times: list[tuple[str, datetime]] = []
    for index, signoff in enumerate(signoffs):
        prefix = f"signoffs[{index}] ({signoff['role']})"
        validate_actor(signoff["signer"], f"{prefix}.signer", errors)
        validate_evidence_uri(
            signoff["evidence_uri"], f"{prefix}.evidence_uri", errors
        )
        if signoff["status"] in {"passed", "rejected"}:
            for field in ("signer", "signed_at", "evidence_uri"):
                if signoff[field] is None:
                    errors.append(
                        f"{prefix}.{field} is required when status is {signoff['status']}"
                    )
            if signoff["signed_at"] is not None:
                signed_at = parse_timestamp(
                    signoff["signed_at"], f"{prefix}.signed_at", errors
                )
                if signed_at and signed_at > as_of:
                    errors.append(f"{prefix}.signed_at must not be in the future")
                if signed_at and signoff["status"] == "passed":
                    passed_signoff_times.append((prefix, signed_at))

    signoffs_pass = all(signoff["status"] == "passed" for signoff in signoffs)
    release_signoff = next(
        (gate for gate in gates if gate["id"] == "people.release_signoff"), None
    )
    if signoffs_pass and release_signoff and release_signoff["status"] != "passed":
        errors.append(
            "people.release_signoff must be passed when all required signoffs pass"
        )
    if release_signoff and release_signoff["status"] == "passed" and not signoffs_pass:
        errors.append(
            "people.release_signoff cannot pass before every required signoff passes"
        )

    is_template = document["template"]
    if is_template:
        if generated_at is not None:
            errors.append("a template must keep generated_at null")
        if any(value is not None for value in document["release"].values()):
            errors.append("a template must keep every immutable release field null")
        if document["production_ready"]:
            errors.append("a template must never set production_ready to true")
        if document["decision"]["status"] != "pending":
            errors.append("a template decision must remain pending")
        for field in ("decided_at", "expires_at", "approver", "evidence_uri"):
            if document["decision"][field] is not None:
                errors.append(f"a template decision must keep {field} null")
        if any(gate["status"] != "pending" for gate in gates):
            errors.append("every template gate must remain pending")
        if any(signoff["status"] != "pending" for signoff in signoffs):
            errors.append("every template signoff must remain pending")
        return errors

    for field, value in document["release"].items():
        if value is None or PLACEHOLDER.search(str(value)):
            errors.append(f"release.{field} must bind a real immutable release value")

    decision = document["decision"]
    validate_actor(decision["approver"], "decision.approver", errors)
    validate_evidence_uri(decision["evidence_uri"], "decision.evidence_uri", errors)
    decision_status = decision["status"]
    gates_pass = all(gate["status"] == "passed" for gate in gates)

    if decision_status == "approved":
        if not document["production_ready"]:
            errors.append("an approved decision must set production_ready to true")
        if not gates_pass:
            errors.append("an approved decision requires every gate to be passed")
        if not signoffs_pass:
            errors.append("an approved decision requires every signoff to be passed")
        for field in ("decided_at", "expires_at", "approver", "evidence_uri"):
            if decision[field] is None:
                errors.append(f"decision.{field} is required for approval")
        decided_at = (
            parse_timestamp(decision["decided_at"], "decision.decided_at", errors)
            if decision["decided_at"] is not None
            else None
        )
        expires_at = (
            parse_timestamp(decision["expires_at"], "decision.expires_at", errors)
            if decision["expires_at"] is not None
            else None
        )
        if decided_at and decided_at > as_of:
            errors.append("decision.decided_at must not be in the future")
        if decided_at:
            for prefix, assessed_at in passed_gate_assessments:
                if decided_at < assessed_at:
                    errors.append(
                        f"decision.decided_at must be at or after {prefix}.assessed_at"
                    )
            for prefix, signed_at in passed_signoff_times:
                if decided_at < signed_at:
                    errors.append(
                        f"decision.decided_at must be at or after {prefix}.signed_at"
                    )
            if parsed_generated_at and parsed_generated_at < decided_at:
                errors.append("generated_at must be at or after decision.decided_at")
        if decided_at and expires_at and expires_at <= decided_at:
            errors.append("decision.expires_at must be later than decided_at")
        if expires_at and expires_at <= as_of:
            errors.append("the production approval has expired")
    else:
        if document["production_ready"]:
            errors.append(
                "production_ready must be false unless the decision is approved"
            )
        if decision_status == "rejected":
            for field in ("decided_at", "approver", "evidence_uri"):
                if decision[field] is None:
                    errors.append(f"decision.{field} is required for rejection")

    return errors


def read_regular_json(path: Path) -> Mapping[str, Any]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise LedgerReadError(f"{path} is missing or unreadable") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise LedgerReadError(f"{path} must be a regular file, not a symlink")
    if metadata.st_size > MAX_DOCUMENT_BYTES:
        raise LedgerReadError(f"{path} exceeds {MAX_DOCUMENT_BYTES} bytes")
    try:
        content = path.read_bytes()
    except OSError as error:
        raise LedgerReadError(f"{path} is missing or unreadable") from error
    if len(content) != metadata.st_size:
        raise LedgerReadError(f"{path} changed while it was being read")
    try:
        document = json.loads(content.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LedgerReadError(f"{path} is not valid UTF-8 JSON: {error}") from error
    if not isinstance(document, dict):
        raise LedgerReadError(f"{path} must contain a JSON object")
    return document


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate a K-Comms internal-production readiness ledger."
    )
    parser.add_argument("ledger", type=Path, help="ledger JSON to validate")
    parser.add_argument(
        "--schema",
        type=Path,
        default=DEFAULT_SCHEMA,
        help=f"JSON Schema path (default: {DEFAULT_SCHEMA})",
    )
    parser.add_argument(
        "--as-of",
        help="UTC expiry evaluation time in YYYY-MM-DDTHH:MM:SSZ format",
    )
    return parser


def main(arguments: Sequence[str] | None = None) -> int:
    options = build_parser().parse_args(arguments)
    try:
        document = read_regular_json(options.ledger)
        schema = read_regular_json(options.schema)
    except LedgerReadError as error:
        print(f"readiness ledger validation failed: {error}", file=sys.stderr)
        return 2

    as_of = datetime.now(timezone.utc)
    if options.as_of:
        parse_errors: list[str] = []
        parsed = parse_timestamp(options.as_of, "--as-of", parse_errors)
        if parse_errors or parsed is None:
            print(f"readiness ledger validation failed: {parse_errors[0]}", file=sys.stderr)
            return 2
        as_of = parsed

    errors = validate_document(document, schema, as_of=as_of)
    if errors:
        print("readiness ledger validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    if document["template"]:
        print("Readiness ledger template is valid and remains pending; it is not production evidence.")
    elif document["production_ready"]:
        print("Readiness ledger is valid and records a non-expired approved decision.")
    else:
        print("Readiness ledger is valid but not approved for production.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
