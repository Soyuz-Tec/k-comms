#!/usr/bin/env python3
"""Enforce umbrella and baseline-controlled business-context boundaries."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Iterable

import yaml
from yaml.constructor import ConstructorError


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = Path("docs/02-architecture/context-boundaries.yaml")
BASELINE_PATH = Path("docs/02-architecture/context-boundary-baseline.yaml")
REPORT_PATH = Path("docs/02-architecture/context-boundary-violations.md")
BASELINE_POLICY = (
    "Relative to the checked-in baseline, new, changed, or resolved "
    "fingerprints fail CI; baseline edits require architecture review."
)
TEMPORARY_EXACT_MAPPING_POLICY = {
    "activation_mode": "strict_with_explicit_deferrals",
    "cardinality": "one_baseline_fingerprint_to_one_declaration",
    "required_fields": [
        "id",
        "fingerprint",
        "rule",
        "path",
        "detail",
        "adr",
        "removal_condition",
    ],
    "group_required_fields": [
        "id",
        "fingerprints",
        "rule",
        "adr",
        "removal_condition",
    ],
    "reject_unmapped_baseline_fingerprints": True,
    "reject_stale_declarations": True,
    "reject_duplicate_fingerprints": True,
    "group_policy": (
        "A group is valid only when it contains an exact fingerprints list and "
        "expands to declarations that satisfy the same one-to-one rule, path, "
        "detail, ADR, and removal-condition checks."
    ),
}
TEMPORARY_ADR_RE = re.compile(
    r"^docs/02-architecture/adr/[0-9]{4}-[A-Za-z0-9][A-Za-z0-9._-]*\.md$"
)
ACCEPTED_ADR_STATUS_RE = re.compile(
    r"(?mi)^\s*(?:-\s*)?(?:\*\*)?Status:(?:\*\*)?\s*Accepted\s*$"
)
REVIEWED_BASELINE_TRANSITION_FIELDS = frozenset(
    {
        "id",
        "previous_baseline_sha256",
        "added_fingerprints",
        "removed_fingerprints",
        "adr",
        "removal_condition",
    }
)
REVIEWED_MANIFEST_TRANSITION_FIELDS = frozenset(
    {
        "id",
        "previous_manifest_sha256",
        "approved_changes",
        "adr",
        "removal_condition",
    }
)
NON_BASELINABLE_BOUNDARY_RULES = frozenset(
    {
        "ambiguous_context_owner",
        "direct_foreign_write",
        "duplicate_table_mapping",
        "invalid_context_declaration",
        "invalid_dependency_graph_declaration",
        "invalid_migration_exception",
        "invalid_read_model_exception",
        "invalid_runtime_collaboration",
        "invalid_table_declaration",
        "invalid_technical_interface",
        "invalid_temporary_violation",
        "multiple_context_modules_file",
        "public_contract_is_schema",
        "public_contract_missing",
        "public_ecto_contract",
        "public_facade_is_schema",
        "public_facade_missing",
        "public_operation_missing_spec",
        "read_model_scope_violation",
        "read_model_write",
        "read_model_reverse_dependency",
        "retired_runtime_binding",
        "undeclared_migration_reference",
        "undeclared_migration_table",
        "unowned_persistence_write",
        "unresolved_migration_target",
        "unresolved_persistence_write",
        "unclassified_core_module",
        "undeclared_runtime_binding",
    }
)
NO_NEW_DEFERRAL_RULES = frozenset(
    {
        "adapter_internal_module_import",
        "adapter_schema_import",
    }
)
SUPPORTED_ENFORCEMENT_MODES = frozenset(
    {"baseline", "strict", "strict_with_explicit_deferrals"}
)
ENFORCEMENT_MODE_RANK = {
    "baseline": 0,
    "strict_with_explicit_deferrals": 1,
    "strict": 2,
}
ENFORCED_TARGET_MODES = frozenset({"strict_with_explicit_deferrals", "strict"})

ALLOWED_UMBRELLA_DEPENDENCIES: dict[str, frozenset[str]] = {
    "comms_core": frozenset(),
    "comms_integrations": frozenset({"comms_observability"}),
    "comms_observability": frozenset(),
    "comms_test_support": frozenset({"comms_core"}),
    "comms_web": frozenset({"comms_core", "comms_integrations", "comms_observability"}),
    "comms_workers": frozenset({"comms_core", "comms_integrations"}),
}

REPO_ACCESS_ALLOWLIST: dict[str, str] = {
    "apps/comms_test_support/lib/comms_test_support/fixtures.ex": (
        "non-release test fixture setup"
    ),
}

OWNER_LIFECYCLE_CALL_ALLOWLIST: dict[str, frozenset[str]] = {
    "CommsCore.Accounts.apply_user_lifecycle_change": frozenset(
        {"CommsCore.Governance"}
    ),
    "CommsCore.Accounts.preflight_user_lifecycle_change": frozenset(
        {"CommsCore.Governance"}
    ),
}

INTERNAL_DEPENDENCY_RE = re.compile(r"\{\s*:(comms_[a-z0-9_]+)\s*,")
CORE_ADAPTER_REFERENCE_RE = re.compile(
    r"\bComms(?:Web|Workers|Integrations|Observability)(?:\b|\.)"
    r"|(?<![A-Za-z0-9_]):comms_(?:web|workers|integrations|observability)\b"
)
GROUPED_REPO_ALIAS_RE = re.compile(
    r"\balias\s+CommsCore\.\{[^}]*\bRepo\b[^}]*\}", re.DOTALL
)
MODULE_RE = re.compile(
    r"^[ \t]*defmodule\s*(?:\(\s*)?(?:Elixir\.)?"
    r"(CommsCore(?:\.[A-Z][A-Za-z0-9_]*)+)\s*\)?",
    re.MULTILINE,
)
RELEASED_MODULE_RE = re.compile(
    r"^[ \t]*defmodule\s*(?:\(\s*)?(?:Elixir\.)?"
    r"((?:CommsCore|CommsWeb|CommsWorkers|CommsIntegrations|CommsObservability)"
    r"(?:\.[A-Z][A-Za-z0-9_]*)+)\s*\)?",
    re.MULTILINE,
)
CORE_MODULE_REFERENCE_RE = re.compile(r"\b(CommsCore(?:\.[A-Z][A-Za-z0-9_]*)+)\b")
GROUPED_CORE_ALIAS_RE = re.compile(
    r"\balias\s+(CommsCore(?:\.[A-Z][A-Za-z0-9_]*)*)\.\{([^}]+)\}",
    re.DOTALL,
)
SIMPLE_CORE_ALIAS_RE = re.compile(
    r"^\s*alias\s+(CommsCore(?:\.[A-Z][A-Za-z0-9_]*)+)"
    r"(?:\s*,\s*as:\s*([A-Z][A-Za-z0-9_]*))?\s*$",
    re.MULTILINE,
)
PUBLIC_QUERY_RE = re.compile(
    r"^(CommsCore(?:\.[A-Z][A-Za-z0-9_]*)+)\."
    r"([a-z_][A-Za-z0-9_]*[!?]?)/([0-9]+)$"
)
GENERIC_MODULE_NAME = r"[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*"
GENERIC_SIMPLE_ALIAS_RE = re.compile(
    rf"^\s*alias\s+({GENERIC_MODULE_NAME})"
    r"(?:\s*,\s*as:\s*([A-Z][A-Za-z0-9_]*))?\s*$",
    re.MULTILINE,
)
GENERIC_GROUPED_ALIAS_RE = re.compile(
    rf"\balias\s+({GENERIC_MODULE_NAME})\.\{{" r"([^}]+)\}",
    re.DOTALL,
)
PARENTHESIZED_GROUPED_ALIAS_RE = re.compile(
    rf"\balias\s*\(\s*({GENERIC_MODULE_NAME})\.\{{"
    r"([^}]+)\}"
    r"\s*(?:,[^)]*)?\)",
    re.DOTALL,
)
GENERIC_IMPORT_RE = re.compile(
    rf"^\s*import\s+({GENERIC_MODULE_NAME})\b",
    re.MULTILINE,
)
QUALIFIED_CALL_RE = re.compile(
    rf"\b({GENERIC_MODULE_NAME})\."
    r"([a-z_][A-Za-z0-9_]*[!?]?)\s*\("
)
QUALIFIED_FUNCTION_REFERENCE_RE = re.compile(
    rf"\b({GENERIC_MODULE_NAME})\."
    r"([a-z_][A-Za-z0-9_]*[!?]?)"
)
CALLBACK_RE = re.compile(r"(?m)^\s*@callback\s+([a-z_][A-Za-z0-9_]*[!?]?)\s*\(")
BEHAVIOUR_RE = re.compile(rf"(?m)^\s*@behaviou?r\s+({GENERIC_MODULE_NAME})\s*$")


def canonical_text_sha256(path: Path) -> str:
    """Hash text with platform-independent LF line endings."""
    content = path.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    return hashlib.sha256(content).hexdigest()


def accepted_architecture_adr(root: Path, adr: object) -> bool:
    """Return whether an ADR reference exists and records an accepted decision."""

    if not isinstance(adr, str) or not TEMPORARY_ADR_RE.fullmatch(adr):
        return False
    path = root / adr
    return path.is_file() and ACCEPTED_ADR_STATUS_RE.search(
        path.read_text(encoding="utf-8")
    ) is not None


@dataclass(frozen=True, order=True)
class Violation:
    rule: str
    path: str
    detail: str

    @property
    def fingerprint(self) -> str:
        value = f"{self.rule}|{self.path}|{self.detail}".encode()
        return hashlib.sha256(value).hexdigest()[:16]

    def render(self) -> str:
        return f"{self.path}: [{self.rule}] {self.detail} ({self.fingerprint})"


@dataclass(frozen=True)
class ContextGraphs:
    compiled: dict[str, frozenset[str]]
    runtime: dict[str, frozenset[str]]
    combined: dict[str, frozenset[str]]

    def named(self) -> tuple[tuple[str, dict[str, frozenset[str]]], ...]:
        return (
            ("compiled", self.compiled),
            ("runtime", self.runtime),
            ("combined", self.combined),
        )


@dataclass(frozen=True)
class PersistenceMutationTargets:
    """Statically attributable persistence targets and fail-closed evidence."""

    schemas: frozenset[str]
    tables: frozenset[str]
    unresolved: frozenset[str]


@dataclass(frozen=True)
class MigrationTargets:
    """Tables mutated or referenced by one migration."""

    mutated: frozenset[str]
    referenced: frozenset[str]
    unresolved: frozenset[str]


class UniqueKeySafeLoader(yaml.SafeLoader):
    """Safe YAML loader that refuses ambiguous duplicate mapping keys."""

    def construct_mapping(self, node: yaml.MappingNode, deep: bool = False) -> dict:
        if not isinstance(node, yaml.MappingNode):
            raise ConstructorError(
                None,
                None,
                f"expected a mapping node, but found {node.id}",
                node.start_mark,
            )
        self.flatten_mapping(node)
        mapping: dict = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            try:
                duplicate = key in mapping
            except TypeError as error:
                raise ConstructorError(
                    "while constructing a mapping",
                    node.start_mark,
                    "found an unhashable key",
                    key_node.start_mark,
                ) from error
            if duplicate:
                raise ConstructorError(
                    "while constructing a mapping",
                    node.start_mark,
                    f"found duplicate mapping key {key!r}",
                    key_node.start_mark,
                )
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping


def relative(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def production_sources(app_dir: Path) -> list[Path]:
    source_root = app_dir / "lib"
    if not source_root.is_dir():
        return []
    return sorted((*source_root.rglob("*.ex"), *source_root.rglob("*.exs")))


def read_yaml(path: Path) -> dict:
    document = yaml.load(
        path.read_text(encoding="utf-8"),
        Loader=UniqueKeySafeLoader,
    )
    if not isinstance(document, dict):
        raise ValueError(f"{path}: YAML root must be a mapping")
    return document


def _blank_elixir_non_code(output: list[str], start: int, end: int) -> None:
    """Blank a lexical non-code span without changing offsets or line numbers."""

    for index in range(start, end):
        if output[index] not in {"\r", "\n"}:
            output[index] = " "


def _elixir_literal_span(
    text: str, start: int
) -> tuple[int, tuple[tuple[int, int], ...]] | None:
    """Return a string/charlist/sigil span and its interpolated code ranges."""

    length = len(text)
    interpolates = True
    paired_closer: str | None = None
    opening: str
    closing: str
    content_start: int

    if text.startswith('"""', start) or text.startswith("'''", start):
        opening = text[start : start + 3]
        closing = opening
        content_start = start + 3
    elif text[start : start + 1] in {'"', "'"}:
        opening = text[start]
        closing = opening
        content_start = start + 1
    elif (
        text[start : start + 1] == "~"
        and start + 2 < length
        and text[start + 1].isalpha()
    ):
        sigil_name = text[start + 1]
        interpolates = sigil_name.islower()
        delimiter_start = start + 2
        if text.startswith('"""', delimiter_start) or text.startswith(
            "'''", delimiter_start
        ):
            opening = text[delimiter_start : delimiter_start + 3]
            closing = opening
            content_start = delimiter_start + 3
        else:
            opening = text[delimiter_start]
            paired_closer = {"(": ")", "[": "]", "{": "}", "<": ">"}.get(opening)
            closing = paired_closer or opening
            content_start = delimiter_start + 1
    else:
        return None

    interpolation_ranges: list[tuple[int, int]] = []
    cursor = content_start
    paired_depth = 1 if paired_closer else 0
    while cursor < length:
        if text[cursor] == "\\":
            cursor = min(cursor + 2, length)
            continue
        if interpolates and text.startswith("#{", cursor):
            interpolation_end = _elixir_interpolation_end(text, cursor + 2)
            if interpolation_end is None:
                cursor = length
                break
            interpolation_ranges.append((cursor + 2, interpolation_end))
            cursor = interpolation_end + 1
            continue
        if paired_closer:
            if text[cursor] == opening:
                paired_depth += 1
            elif text[cursor] == closing:
                paired_depth -= 1
                if paired_depth == 0:
                    cursor += 1
                    break
            cursor += 1
            continue
        if text.startswith(closing, cursor):
            cursor += len(closing)
            break
        cursor += 1

    if start < length and text[start] == "~":
        while cursor < length and text[cursor].isalpha():
            cursor += 1
    return cursor, tuple(interpolation_ranges)


def _elixir_interpolation_end(text: str, start: int) -> int | None:
    """Find the closing brace of an interpolated Elixir expression."""

    depth = 1
    cursor = start
    length = len(text)
    while cursor < length:
        character = text[cursor]
        if character == "#" and not (cursor > start and text[cursor - 1] == "?"):
            newline = text.find("\n", cursor)
            cursor = length if newline == -1 else newline + 1
            continue
        if character == "?" and cursor + 1 < length:
            cursor += 2
            if text[cursor - 1] == "\\" and cursor < length:
                cursor += 1
            continue
        literal = _elixir_literal_span(text, cursor)
        if literal:
            cursor = literal[0]
            continue
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return cursor
        cursor += 1
    return None


@lru_cache(maxsize=4096)
def elixir_code_only(text: str) -> str:
    """Return an offset-preserving view containing only executable Elixir code.

    Comments and literal prose are blanked so architecture edges cannot be
    invented by documentation, examples, regexes, or data strings. Elixir
    expressions inside interpolating literals remain code because they are
    compiled and can contain real module dependencies.
    """

    output = list(text)
    cursor = 0
    length = len(text)
    while cursor < length:
        character = text[cursor]
        if character == "#" and not (cursor > 0 and text[cursor - 1] == "?"):
            newline = text.find("\n", cursor)
            end = length if newline == -1 else newline
            _blank_elixir_non_code(output, cursor, end)
            cursor = end
            continue
        if character == "?" and cursor + 1 < length:
            cursor += 2
            if text[cursor - 1] == "\\" and cursor < length:
                cursor += 1
            continue
        literal = _elixir_literal_span(text, cursor)
        if literal:
            end, interpolation_ranges = literal
            _blank_elixir_non_code(output, cursor, end)
            # Keep one inert token so argument counting does not turn a literal
            # into an empty final argument after its contents are blanked.
            output[cursor] = "0"
            for interpolation_start, interpolation_end in interpolation_ranges:
                output[interpolation_start:interpolation_end] = elixir_code_only(
                    text[interpolation_start:interpolation_end]
                )
            cursor = end
            continue
        cursor += 1
    return "".join(output)


def core_module_declarations(text: str) -> list[str]:
    """Return real CommsCore defmodule declarations, excluding literal prose."""

    return MODULE_RE.findall(elixir_code_only(text))


def released_module_declarations(text: str) -> list[str]:
    """Return production umbrella module declarations, excluding literal prose."""

    return RELEASED_MODULE_RE.findall(elixir_code_only(text))


def validate_umbrella_dependencies(root: Path) -> list[str]:
    errors: list[str] = []
    apps_dir = root / "apps"
    discovered = {
        path.parent.name: path
        for path in sorted(apps_dir.glob("*/mix.exs"))
        if path.is_file()
    }

    for app in sorted(set(discovered) - set(ALLOWED_UMBRELLA_DEPENDENCIES)):
        errors.append(
            f"apps/{app}/mix.exs: umbrella app is not classified in the architecture policy"
        )

    for app in sorted(set(ALLOWED_UMBRELLA_DEPENDENCIES) - set(discovered)):
        errors.append(f"apps/{app}/mix.exs: classified umbrella app is missing")

    for app, mix_path in sorted(discovered.items()):
        if app not in ALLOWED_UMBRELLA_DEPENDENCIES:
            continue
        text = mix_path.read_text(encoding="utf-8")
        dependencies = set(INTERNAL_DEPENDENCY_RE.findall(text)) & set(discovered)
        for dependency in sorted(dependencies - ALLOWED_UMBRELLA_DEPENDENCIES[app]):
            errors.append(
                f"{relative(mix_path, root)}: forbidden umbrella dependency "
                f"{app} -> {dependency}"
            )
    return errors


def validate_core_adapter_references(root: Path) -> list[str]:
    errors: list[str] = []
    for path in production_sources(root / "apps/comms_core"):
        for line_number, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            if CORE_ADAPTER_REFERENCE_RE.search(line):
                errors.append(
                    f"{relative(path, root)}:{line_number}: comms_core references an "
                    "adapter application"
                )
    return errors


def validate_repo_access(root: Path) -> list[str]:
    errors: list[str] = []
    observed_allowlist_entries: set[str] = set()
    apps_dir = root / "apps"
    if not apps_dir.is_dir():
        return ["apps: umbrella applications directory is missing"]

    for app_dir in sorted(path for path in apps_dir.iterdir() if path.is_dir()):
        if app_dir.name == "comms_core":
            continue
        for path in production_sources(app_dir):
            text = path.read_text(encoding="utf-8")
            if "CommsCore.Repo" not in core_module_references(text):
                continue
            path_key = relative(path, root)
            if path_key in REPO_ACCESS_ALLOWLIST:
                observed_allowlist_entries.add(path_key)
            else:
                errors.append(
                    f"{path_key}: direct CommsCore.Repo access is not allowlisted"
                )

    missing = sorted(
        path for path in REPO_ACCESS_ALLOWLIST if not (root / path).is_file()
    )
    for path in missing:
        errors.append(f"{path}: Repo-access allowlist entry does not exist")
    for path in sorted(
        set(REPO_ACCESS_ALLOWLIST) - set(missing) - observed_allowlist_entries
    ):
        errors.append(f"{path}: Repo-access allowlist entry is no longer used")
    return errors


def validate_owner_lifecycle_call_sites(root: Path) -> list[str]:
    errors: list[str] = []
    protected_calls = set(OWNER_LIFECYCLE_CALL_ALLOWLIST)
    apps_dir = root / "apps"
    if not apps_dir.is_dir():
        return []

    for app_dir in sorted(path for path in apps_dir.iterdir() if path.is_dir()):
        for path in production_sources(app_dir):
            text = path.read_text(encoding="utf-8")
            path_key = relative(path, root)
            caller_modules = set(core_module_declarations(text))
            for module, function in sorted(core_function_calls(text)):
                call = f"{module}.{function}"
                if call in protected_calls and caller_modules != set(
                    OWNER_LIFECYCLE_CALL_ALLOWLIST[call]
                ):
                    errors.append(
                        f"{path_key}: {call} is an owner-internal lifecycle command; "
                        "only CommsCore.Governance may call it"
                    )
            protected_accounts_functions = {
                call.rsplit(".", 1)[-1]
                for call in protected_calls
                if call.startswith("CommsCore.Accounts.")
            }
            evasions = module_function_evasions(
                text,
                {"CommsCore.Accounts": protected_accounts_functions},
            )
            if evasions and caller_modules != set(
                OWNER_LIFECYCLE_CALL_ALLOWLIST[
                    "CommsCore.Accounts.apply_user_lifecycle_change"
                ]
            ):
                errors.append(
                    f"{path_key}: owner-internal lifecycle command evasion is "
                    f"forbidden ({', '.join(sorted(evasions))})"
                )
    return errors


def module_owner_candidates(module: str, contexts: dict) -> set[str]:
    exact_matches = {
        context_name
        for context_name, context in contexts.items()
        if isinstance(context, dict) and module in context.get("owned_modules", [])
    }
    if exact_matches:
        return exact_matches

    matches: list[tuple[int, str]] = []
    for context_name, context in contexts.items():
        if not isinstance(context, dict):
            continue
        prefixes = [
            *context.get("public_facades", []),
            *context.get("public_contracts", []),
            *context.get("internal_namespaces", []),
        ]
        for prefix in prefixes:
            if module == prefix or module.startswith(f"{prefix}."):
                matches.append((len(prefix), context_name))
    if not matches:
        return set()
    longest = max(length for length, _context_name in matches)
    return {context_name for length, context_name in matches if length == longest}


def module_owner(module: str, contexts: dict) -> str | None:
    candidates = module_owner_candidates(module, contexts)
    return next(iter(candidates)) if len(candidates) == 1 else None


def declared_module_owner(
    module: str, contexts: dict, schema_owners: dict[str, str]
) -> str | None:
    """Prefer explicit table ownership over namespace-based attribution."""

    return schema_owners.get(module) or module_owner(module, contexts)


def declared_module_owner_candidates(
    module: str, contexts: dict, schema_owners: dict[str, str]
) -> set[str]:
    """Return the authoritative owner candidates for a production module."""

    schema_owner = schema_owners.get(module)
    exact_matches = {
        context_name
        for context_name, context in contexts.items()
        if isinstance(context, dict) and module in context.get("owned_modules", [])
    }
    if schema_owner:
        conflicts = exact_matches - {schema_owner}
        return {schema_owner, *conflicts}
    if exact_matches:
        return exact_matches
    return module_owner_candidates(module, contexts)


def graph_contexts(contexts: dict) -> set[str]:
    return {
        context_name
        for context_name, context in contexts.items()
        if isinstance(context, dict)
        and context.get("graph_scope", "included") != "excluded"
    }


def module_in_namespace(module: str, namespace: str) -> bool:
    return module == namespace or module.startswith(f"{namespace}.")


def exact_module_reference(text: str, module: str) -> bool:
    code = elixir_code_only(text)
    return bool(
        re.search(
            rf"(?<![A-Za-z0-9_.]){re.escape(module)}(?=(?:\.t\(\))|[^A-Za-z0-9_.]|$)",
            code,
        )
    )


def normalize_module_name(module: str) -> str:
    """Normalize an Elixir module atom rendered with an optional Elixir prefix."""

    while module.startswith("Elixir."):
        module = module[len("Elixir.") :]
    return module


def resolve_module_reference(module: str, aliases: dict[str, str]) -> str:
    """Expand the first alias segment and normalize the resulting module."""

    resolved = normalize_module_name(module)
    seen: set[str] = set()
    while resolved not in seen:
        seen.add(resolved)
        root, separator, suffix = resolved.partition(".")
        expanded_root = aliases.get(root)
        if not expanded_root:
            break
        resolved = normalize_module_name(
            f"{expanded_root}.{suffix}" if separator else expanded_root
        )
    return resolved


def ecto_schema_source(text: str) -> tuple[str | None, bool]:
    """Resolve a literal or module-attribute Ecto schema source."""

    literal = re.search(
        r'(?m)^[ \t]*schema\s*(?:\(\s*)?"(?P<table>[a-z0-9_]+)"',
        text,
    )
    if literal:
        return literal.group("table"), False

    attribute_schema = re.search(
        r"(?m)^[ \t]*schema\s*(?:\(\s*)?"
        r"@(?P<attribute>[a-z_][A-Za-z0-9_]*)\b",
        text,
    )
    if attribute_schema:
        attribute = attribute_schema.group("attribute")
        declaration = re.search(
            rf'(?m)^[ \t]*@{re.escape(attribute)}\s+"'
            r'(?P<table>[a-z0-9_]+)"\s*$',
            text,
        )
        if declaration:
            return declaration.group("table"), False
        return None, True

    has_schema_macro = re.search(
        r"(?m)^[ \t]*schema"
        r"(?:\s*\([^)\n]*\)|[ \t]+[^\n]+?)"
        r"[ \t]+do\b",
        elixir_code_only(text),
    )
    return None, has_schema_macro is not None


def discover_schemas(root: Path) -> dict[str, list[tuple[str, str]]]:
    schemas: dict[str, list[tuple[str, str]]] = {}
    apps_root = root / "apps"
    for app_dir in sorted(path for path in apps_root.iterdir() if path.is_dir()):
        for path in production_sources(app_dir):
            text = path.read_text(encoding="utf-8")
            module_match = RELEASED_MODULE_RE.search(elixir_code_only(text))
            schema_source, _unresolved = ecto_schema_source(text)
            if module_match and schema_source:
                schemas.setdefault(schema_source, []).append(
                    (module_match.group(1), relative(path, root))
                )
    return schemas


def discover_embedded_schemas(root: Path) -> dict[str, str]:
    """Return Ecto embedded-schema modules, which are not stable public DTOs."""

    embedded: dict[str, str] = {}
    apps_root = root / "apps"
    for app_dir in sorted(path for path in apps_root.iterdir() if path.is_dir()):
        for path in production_sources(app_dir):
            text = path.read_text(encoding="utf-8")
            module_match = RELEASED_MODULE_RE.search(elixir_code_only(text))
            if module_match and re.search(
                r"(?m)^[ \t]*embedded_schema(?:\s*\(\s*\))?[ \t]+do\b",
                elixir_code_only(text),
            ):
                embedded[module_match.group(1)] = relative(path, root)
    return embedded


@lru_cache(maxsize=4096)
def core_module_references(text: str) -> set[str]:
    code = elixir_code_only(text)
    aliases = module_aliases(code)
    references = {
        normalize_module_name(module)
        for module in CORE_MODULE_REFERENCE_RE.findall(code)
    }
    for prefix, members in GROUPED_CORE_ALIAS_RE.findall(code):
        for member in members.split(","):
            cleaned = member.strip()
            if re.fullmatch(GENERIC_MODULE_NAME, cleaned):
                references.add(resolve_module_reference(f"{prefix}.{cleaned}", aliases))
    for token in re.findall(rf"(?<![A-Za-z0-9_])({GENERIC_MODULE_NAME})", code):
        resolved = resolve_module_reference(token, aliases)
        if resolved.startswith("CommsCore."):
            references.add(resolved)
    references.update(
        normalize_module_name(module) for module in core_aliases(code).values()
    )
    return references


@lru_cache(maxsize=4096)
def simple_module_alias_declarations(text: str) -> list[tuple[str, str]]:
    """Return simple alias names and targets across directive syntaxes."""

    text = elixir_code_only(text)
    declarations: list[tuple[str, str]] = []
    for declaration in re.finditer(
        rf"(?m)^\s*alias\s+(?P<module>{GENERIC_MODULE_NAME})"
        r"(?P<options>[^\n]*)",
        text,
    ):
        options = declaration.group("options")
        if options.lstrip().startswith(".{"):
            continue
        cursor = declaration.end()
        while options.rstrip().endswith(",") and cursor < len(text):
            line_end = text.find("\n", cursor + 1)
            line_end = len(text) if line_end == -1 else line_end
            options += text[cursor:line_end]
            cursor = line_end
        explicit = re.search(
            r"(?:^|,)\s*as:\s*([A-Z][A-Za-z0-9_]*)",
            options,
        )
        module = declaration.group("module")
        declarations.append(
            (
                explicit.group(1) if explicit else module.rsplit(".", 1)[-1],
                module,
            )
        )
    for declaration in re.finditer(
        rf"\balias\s*\(\s*(?P<module>{GENERIC_MODULE_NAME})"
        r"(?P<options>[^)]*)\)",
        text,
    ):
        if declaration.group("options").lstrip().startswith(".{"):
            continue
        explicit = re.search(
            r"(?:^|,)\s*as:\s*([A-Z][A-Za-z0-9_]*)",
            declaration.group("options"),
        )
        module = declaration.group("module")
        declarations.append(
            (
                explicit.group(1) if explicit else module.rsplit(".", 1)[-1],
                module,
            )
        )
    return declarations


@lru_cache(maxsize=4096)
def module_aliases(text: str) -> dict[str, str]:
    text = elixir_code_only(text)
    aliases: dict[str, str] = {}
    for name, module in simple_module_alias_declarations(text):
        aliases[name] = module
    for grouped_pattern in (
        GENERIC_GROUPED_ALIAS_RE,
        PARENTHESIZED_GROUPED_ALIAS_RE,
    ):
        for prefix, members in grouped_pattern.findall(text):
            for member in members.split(","):
                cleaned = member.strip()
                if re.fullmatch(GENERIC_MODULE_NAME, cleaned):
                    aliases[cleaned.rsplit(".", 1)[-1]] = f"{prefix}.{cleaned}"

    for _iteration in range(len(aliases) + 1):
        changed = False
        for name, module in tuple(aliases.items()):
            root, separator, suffix = module.partition(".")
            expanded_root = aliases.get(root)
            if not expanded_root or expanded_root == module:
                continue
            expanded = f"{expanded_root}.{suffix}" if separator else expanded_root
            if expanded != module:
                aliases[name] = expanded
                changed = True
        if not changed:
            break
    return {name: normalize_module_name(module) for name, module in aliases.items()}


def core_aliases(text: str) -> dict[str, str]:
    return {
        name: module
        for name, module in module_aliases(text).items()
        if module.startswith("CommsCore.")
    }


@lru_cache(maxsize=4096)
def imported_modules(text: str) -> set[str]:
    code = elixir_code_only(text)
    aliases = module_aliases(code)
    modules = {
        resolve_module_reference(module, aliases)
        for module in GENERIC_IMPORT_RE.findall(code)
    }
    modules.update(
        resolve_module_reference(module, aliases)
        for module in re.findall(
            rf"\bimport\s*\(\s*({GENERIC_MODULE_NAME})",
            code,
        )
    )
    return modules


@lru_cache(maxsize=4096)
def qualified_function_calls(text: str) -> set[tuple[str, str, int]]:
    """Return statically visible qualified calls with their effective arity."""

    text = elixir_code_only(text)
    calls: set[tuple[str, str, int]] = set()
    aliases = module_aliases(text)
    for call in QUALIFIED_CALL_RE.finditer(text):
        receiver, function = call.groups()
        module = resolve_module_reference(receiver, aliases)
        parsed = balanced_call_arguments(text, call.end() - 1)
        if not parsed:
            continue
        arguments_text, _ = parsed
        arguments = split_top_level_args(arguments_text)
        arity = len(arguments)
        if pipeline_input_before(text, call.start()) is not None:
            arity += 1
        calls.add((module, function, arity))
    return calls


def core_function_calls(text: str) -> set[tuple[str, str]]:
    """Return statically visible calls to qualified or aliased CommsCore modules."""

    return {
        (module, function)
        for module, function, _arity in resolved_function_calls(text)
        if module.startswith("CommsCore.")
    }


@lru_cache(maxsize=4096)
def static_module_bindings(text: str) -> dict[str, str]:
    """Resolve simple variable and module-attribute assignments to modules."""

    code = elixir_code_only(text)
    aliases = module_aliases(code)
    bindings: dict[str, str] = {}
    patterns = (
        re.compile(
            rf"(?m)^\s*(?P<binding>[a-z_][A-Za-z0-9_]*)\s*=\s*"
            rf"(?P<module>{GENERIC_MODULE_NAME})\s*$"
        ),
        re.compile(
            rf"(?m)^\s*(?P<binding>@[a-z_][A-Za-z0-9_]*)\s+"
            rf"(?P<module>{GENERIC_MODULE_NAME})\s*$"
        ),
    )
    for pattern in patterns:
        for assignment in pattern.finditer(code):
            bindings[assignment.group("binding")] = resolve_module_reference(
                assignment.group("module"),
                aliases,
            )
    return bindings


@lru_cache(maxsize=4096)
def statically_bound_function_calls(text: str) -> set[tuple[str, str, int]]:
    """Return calls through variables or attributes bound to static modules."""

    code = elixir_code_only(text)
    bindings = static_module_bindings(code)
    calls: set[tuple[str, str, int]] = set()
    pattern = re.compile(
        r"(?<![A-Za-z0-9_])(?P<receiver>@?[a-z_][A-Za-z0-9_]*)\."
        r"(?P<function>[a-z_][A-Za-z0-9_]*[!?]?)\s*\("
    )
    for call in pattern.finditer(code):
        module = bindings.get(call.group("receiver"))
        if module is None:
            continue
        parsed = balanced_call_arguments(code, call.end() - 1)
        if not parsed:
            continue
        arguments_text, _ = parsed
        arity = len(split_top_level_args(arguments_text))
        if pipeline_input_before(code, call.start()) is not None:
            arity += 1
        calls.add((module, call.group("function"), arity))
    return calls


@lru_cache(maxsize=4096)
def delegated_function_calls(text: str) -> set[tuple[str, str, int]]:
    """Return statically resolvable defdelegate target operations."""

    code = elixir_code_only(text)
    aliases = module_aliases(code)
    bindings = static_module_bindings(code)
    calls: set[tuple[str, str, int]] = set()
    for declaration in re.finditer(
        r"(?m)^\s*defdelegate\s+"
        r"(?P<function>[a-z_][A-Za-z0-9_]*[!?]?)\s*\(",
        code,
    ):
        parsed = balanced_call_arguments(code, declaration.end() - 1)
        if not parsed:
            continue
        arguments_text, end_index = parsed
        tail = code[end_index:]
        boundary = re.search(
            r"(?m)^\s*(?:def(?:p|delegate)?\b|@[a-z_]|end\b)",
            tail,
        )
        options = tail[: boundary.start()] if boundary else tail
        target_match = re.search(
            rf"\bto:\s*(?P<target>{GENERIC_MODULE_NAME}|"
            r"@[a-z_][A-Za-z0-9_]*|[a-z_][A-Za-z0-9_]*)",
            options,
        )
        if target_match is None:
            continue
        target_expression = target_match.group("target")
        target = bindings.get(target_expression)
        if target is None and re.fullmatch(GENERIC_MODULE_NAME, target_expression):
            target = resolve_module_reference(target_expression, aliases)
        if target is None:
            continue
        delegated_function = declaration.group("function")
        as_match = re.search(
            r"\bas:\s*:(?P<function>[a-z_][A-Za-z0-9_]*[!?]?)",
            options,
        )
        target_function = as_match.group("function") if as_match else delegated_function
        arguments = split_top_level_args(arguments_text)
        defaults = sum("\\\\" in argument for argument in arguments)
        for arity in range(len(arguments) - defaults, len(arguments) + 1):
            calls.add((target, target_function, arity))
    return calls


@lru_cache(maxsize=4096)
def resolved_function_calls(text: str) -> set[tuple[str, str, int]]:
    """Return all statically attributable direct and delegated calls."""

    return (
        qualified_function_calls(text)
        | statically_bound_function_calls(text)
        | delegated_function_calls(text)
    )


def runtime_function_calls(text: str) -> set[tuple[str, str, int]]:
    """Return function calls while excluding compile-time typespec references."""

    code = elixir_code_only(text)
    typespec_re = re.compile(
        r"(?ms)^[ \t]*@(?:spec|callback|macrocallback|typep?|opaque)\b"
        r".*?(?=^[ \t]*(?:@[a-z_]|def(?:p|macro|macrop|delegate|struct|exception)?\b"
        r"|end\b)|\Z)"
    )

    def mask(match: re.Match[str]) -> str:
        return "".join("\n" if character == "\n" else " " for character in match.group(0))

    return resolved_function_calls(typespec_re.sub(mask, code))


def parenless_call_arguments(text: str, start: int) -> str:
    """Read a same-line or comma-continued parenless call argument list."""

    index = start
    while index < len(text) and text[index].isspace():
        index += 1
    argument_start = index
    depths = {"(": 0, "[": 0, "{": 0}
    closing = {")": "(", "]": "[", "}": "{"}
    while index < len(text):
        character = text[index]
        if character in depths:
            depths[character] += 1
        elif character in closing:
            opener = closing[character]
            depths[opener] = max(0, depths[opener] - 1)
        elif character == ";" and not any(depths.values()):
            return text[argument_start:index]
        elif character == "\n" and not any(depths.values()):
            captured = text[argument_start:index].rstrip()
            if not captured.endswith(","):
                return captured
        index += 1
    return text[argument_start:index].rstrip()


@lru_cache(maxsize=4096)
def application_binding_references(
    text: str,
) -> tuple[set[tuple[str, str]], set[str]]:
    """Return literal Application env bindings and unsupported dynamic forms."""

    code = elixir_code_only(text)
    bindings: set[tuple[str, str]] = set()
    unresolved: set[str] = set()
    literal_attributes: dict[str, set[str]] = {}
    for assignment in re.finditer(
        r"(?m)^\s*(?P<attribute>@[a-z_][A-Za-z0-9_]*)\s+"
        r":(?P<value>[a-z][a-z0-9_]*)\s*$",
        code,
    ):
        literal_attributes.setdefault(assignment.group("attribute"), set()).add(
            assignment.group("value")
        )

    def literal_binding_value(expression: str) -> str | None:
        expression = expression.strip()
        atom = re.fullmatch(r":(?P<value>[a-z][a-z0-9_]*)", expression)
        if atom:
            return atom.group("value")
        attribute_values = literal_attributes.get(expression, set())
        if len(attribute_values) == 1:
            return next(iter(attribute_values))
        if re.fullmatch(GENERIC_MODULE_NAME, expression):
            return normalize_module_name(expression)
        return None

    def record(function: str, arguments_text: str, call_start: int) -> None:
        arguments = split_top_level_args(arguments_text)
        pipeline_input = pipeline_input_before(code, call_start)
        if pipeline_input is not None:
            arguments.insert(0, pipeline_input)
        if len(arguments) < 2:
            unresolved.add(f"Application.{function} has fewer than two arguments")
            return
        application = literal_binding_value(arguments[0])
        key = literal_binding_value(arguments[1])
        if application is None or key is None:
            unresolved.add(
                f"Application.{function} uses a non-literal application or key"
            )
            return
        bindings.add((application, key))

    parenthesized = re.compile(
        r"\bApplication\."
        r"(?P<function>(?:fetch|get|compile)_env!?)\s*\("
    )
    for call in parenthesized.finditer(code):
        parsed = balanced_call_arguments(code, call.end() - 1)
        if parsed:
            record(call.group("function"), parsed[0], call.start())

    parenless = re.compile(
        r"\bApplication\."
        r"(?P<function>(?:fetch|get|compile)_env!?)"
        r"(?!\s*\()(?=\s)"
    )
    for call in parenless.finditer(code):
        record(
            call.group("function"),
            parenless_call_arguments(code, call.end()),
            call.start(),
        )

    return bindings, unresolved


def module_function_evasions(
    text: str,
    protected_modules: dict[str, set[str] | None],
    *,
    reject_unknown_dynamic_target: bool = False,
) -> set[str]:
    """Find invocation forms intentionally excluded from stable facade contracts."""

    text = elixir_code_only(text)
    evidence: set[str] = set()
    aliases = module_aliases(text)
    protected_bindings = {
        binding: module
        for binding, module in static_module_bindings(text).items()
        if module in protected_modules
    }
    static_targets: dict[str, set[str]] = {}
    assignment_patterns = (
        re.compile(
            rf"(?m)^\s*(?P<binding>[a-z_][A-Za-z0-9_]*)\s*=\s*"
            rf"(?P<module>{GENERIC_MODULE_NAME})\s*$"
        ),
        re.compile(
            rf"(?m)^\s*(?P<binding>@[a-z_][A-Za-z0-9_]*)\s+"
            rf"(?P<module>{GENERIC_MODULE_NAME})\s*$"
        ),
    )
    for assignment_pattern in assignment_patterns:
        for assignment in assignment_pattern.finditer(text):
            static_targets.setdefault(assignment.group("binding"), set()).add(
                resolve_module_reference(assignment.group("module"), aliases)
            )
    for binding, targets in static_targets.items():
        if len(targets) > 1 and targets.intersection(protected_modules):
            evidence.add(
                f"ambiguously binds {binding} to " + ", ".join(sorted(targets))
            )
    alias_targets: dict[str, set[str]] = {}
    for alias_name, module in simple_module_alias_declarations(text):
        alias_targets.setdefault(alias_name, set()).add(
            resolve_module_reference(module, aliases)
        )
    for alias_name, targets in alias_targets.items():
        if len(targets) > 1 and targets.intersection(protected_modules):
            evidence.add(
                f"ambiguously aliases {alias_name} to " + ", ".join(sorted(targets))
            )
    referenced_protected_modules = {
        module
        for module in (
            set(module_aliases(text).values()) | core_module_references(text)
        )
        if module in protected_modules
    }

    for module in imported_modules(text):
        if module in protected_modules:
            evidence.add(f"imports {module}")

    for reference in QUALIFIED_FUNCTION_REFERENCE_RE.finditer(text):
        receiver, function = reference.groups()
        module = resolve_module_reference(receiver, aliases)
        protected_functions = protected_modules.get(module)
        if module not in protected_modules or (
            protected_functions is not None and function not in protected_functions
        ):
            continue
        suffix = text[reference.end() :]
        if suffix.lstrip().startswith("("):
            continue
        prefix = text[max(0, reference.start() - 2) : reference.start()]
        if "&" in prefix or suffix.lstrip().startswith("/"):
            evidence.add(f"captures {module}.{function}")
        else:
            evidence.add(f"uses parenless {module}.{function}")

    bound_reference_pattern = re.compile(
        r"(?<![A-Za-z0-9_])(?P<receiver>@?[a-z_][A-Za-z0-9_]*)\."
        r"(?P<function>[a-z_][A-Za-z0-9_]*[!?]?)"
    )
    for reference in bound_reference_pattern.finditer(text):
        module = protected_bindings.get(reference.group("receiver"))
        function = reference.group("function")
        protected_functions = protected_modules.get(module) if module else None
        if module is None or (
            protected_functions is not None and function not in protected_functions
        ):
            continue
        suffix = text[reference.end() :]
        if suffix.lstrip().startswith("("):
            continue
        prefix = text[max(0, reference.start() - 2) : reference.start()]
        if "&" in prefix or suffix.lstrip().startswith("/"):
            evidence.add(f"captures {module}.{function}")
        else:
            evidence.add(f"uses parenless {module}.{function}")

    def record_dynamic_invocation(arguments: list[str]) -> None:
        if len(arguments) < 2:
            return
        operation_expression = arguments[1].strip()
        literal_operation = re.fullmatch(
            r":(?P<function>[a-z_][A-Za-z0-9_]*[!?]?)",
            operation_expression,
        )
        module_expression = arguments[0].strip()
        if re.fullmatch(GENERIC_MODULE_NAME, module_expression):
            module = resolve_module_reference(module_expression, aliases)
        else:
            module = protected_bindings.get(module_expression)
        if module is None:
            if reject_unknown_dynamic_target:
                for protected_module in sorted(referenced_protected_modules):
                    protected_functions = protected_modules[protected_module]
                    if (
                        literal_operation is not None
                        and protected_functions is not None
                        and literal_operation.group("function")
                        not in protected_functions
                    ):
                        continue
                    evidence.add(
                        f"uses dynamic {protected_module}.<unknown module target>"
                    )
            return
        if module not in protected_modules:
            return

        if literal_operation is None:
            evidence.add(f"uses dynamic {module}.<non-literal operation>")
            return

        function = literal_operation.group("function")
        protected_functions = protected_modules.get(module)
        if protected_functions is None or function in protected_functions:
            evidence.add(f"uses dynamic {module}.{function}")

    parenthesized_dynamic_invocations = (
        re.compile(r"\b(?:Kernel\.)?apply\s*\("),
        re.compile(r":erlang\.apply\s*\("),
        re.compile(r"\bFunction\.capture\s*\("),
    )
    for pattern in parenthesized_dynamic_invocations:
        for dynamic in pattern.finditer(text):
            parsed = balanced_call_arguments(text, dynamic.end() - 1)
            if not parsed:
                continue
            arguments_text, _ = parsed
            record_dynamic_invocation(split_top_level_args(arguments_text))

    parenless_dynamic_invocations = (
        re.compile(r"(?m)(?<![A-Za-z0-9_.])(?:Kernel\.)?apply(?!\s*\()(?=\s)"),
        re.compile(r"(?m)(?<![A-Za-z0-9_.]):erlang\.apply(?!\s*\()(?=\s)"),
        re.compile(r"(?m)(?<![A-Za-z0-9_.])Function\.capture(?!\s*\()(?=\s)"),
    )
    for pattern in parenless_dynamic_invocations:
        for dynamic in pattern.finditer(text):
            record_dynamic_invocation(
                split_top_level_args(parenless_call_arguments(text, dynamic.end()))
            )

    return evidence


def module_defines_function(path: Path, function: str, arity: int) -> bool:
    text = path.read_text(encoding="utf-8")
    for definition in re.finditer(rf"(?m)^\s*def\s+{re.escape(function)}\s*\(", text):
        parsed = balanced_call_arguments(text, definition.end() - 1)
        if not parsed:
            continue
        arguments_text, _ = parsed
        arguments = split_top_level_args(arguments_text)
        defaults = sum("\\\\" in argument for argument in arguments)
        if len(arguments) - defaults <= arity <= len(arguments):
            return True
    return False


def _masked_elixir_code(text: str) -> str:
    """Mask comments and quoted strings while preserving source offsets."""

    masked = list(text)
    index = 0
    while index < len(text):
        if text[index] == "#":
            end = text.find("\n", index)
            end = len(text) if end == -1 else end
            for offset in range(index, end):
                masked[offset] = " "
            index = end
            continue

        delimiter = None
        if text.startswith('"""', index):
            delimiter = '"""'
        elif text.startswith("'''", index):
            delimiter = "'''"
        elif text[index] in {'"', "'"}:
            delimiter = text[index]
        if delimiter is None:
            index += 1
            continue

        end = index + len(delimiter)
        escaped = False
        while end < len(text):
            if len(delimiter) == 1 and escaped:
                escaped = False
                end += 1
                continue
            if len(delimiter) == 1 and text[end] == "\\":
                escaped = True
                end += 1
                continue
            if text.startswith(delimiter, end):
                end += len(delimiter)
                break
            end += 1
        for offset in range(index, min(end, len(text))):
            if text[offset] != "\n":
                masked[offset] = " "
        index = end
    return "".join(masked)


ELIXIR_BLOCK_TOKEN_RE = re.compile(r"\b(do|fn|end)\b(?![ \t]*:)")


def _matching_elixir_block_end(
    masked_text: str, opening_do: re.Match[str]
) -> int | None:
    """Return the start offset of the end matching a block-opening ``do``."""

    depth = 1
    for token in ELIXIR_BLOCK_TOKEN_RE.finditer(masked_text, opening_do.end()):
        if token.group(1) in {"do", "fn"}:
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                return token.start()
    return None


def _public_operation_clauses(
    text: str, function: str, arity: int
) -> list[tuple[str, str]]:
    """Return block/inline bodies for public clauses matching ``function/arity``."""

    masked = _masked_elixir_code(text)
    definitions = list(re.finditer(r"(?m)^\s*def\s+[a-z_][A-Za-z0-9_!?]*\s*\(", masked))
    clauses: list[tuple[str, str]] = []
    expected = re.compile(rf"(?m)^\s*def\s+{re.escape(function)}\s*\(")

    for index, definition in enumerate(definitions):
        if expected.match(masked, definition.start()) is None:
            continue
        parsed = balanced_call_arguments(text, definition.end() - 1)
        if not parsed:
            continue
        arguments_text, close_index = parsed
        arguments = split_top_level_args(arguments_text)
        defaults = sum("\\\\" in argument for argument in arguments)
        if not (len(arguments) - defaults <= arity <= len(arguments)):
            continue

        next_definition = (
            definitions[index + 1].start()
            if index + 1 < len(definitions)
            else len(text)
        )
        header = masked[close_index:next_definition]
        inline_do = re.search(r"\bdo[ \t]*:", header)
        block_do = re.search(r"\bdo\b(?![ \t]*:)", header)
        if inline_do and (not block_do or inline_do.start() < block_do.start()):
            body_start = close_index + inline_do.end()
            body_end = text.find("\n", body_start, next_definition)
            body_end = next_definition if body_end == -1 else body_end
            clauses.append(("inline", text[body_start:body_end]))
            continue
        if not block_do:
            clauses.append(("unparsed", text[definition.start() : next_definition]))
            continue

        absolute_do_start = close_index + block_do.start()
        opening_do = ELIXIR_BLOCK_TOKEN_RE.search(masked, absolute_do_start)
        if opening_do is None:
            clauses.append(("unparsed", text[definition.start() : next_definition]))
            continue
        matching_end = _matching_elixir_block_end(masked, opening_do)
        if matching_end is None:
            clauses.append(("unparsed", text[definition.start() : next_definition]))
            continue
        clauses.append(("block", text[opening_do.end() : matching_end]))

    return clauses


def _transaction_guarded_block(body: str, aliases: dict[str, str]) -> bool:
    """Recognize the transaction guard shape used by runtime collaboration ports."""

    masked = _masked_elixir_code(body)
    guard = re.match(
        rf"\s*if\s+(?P<repo>{GENERIC_MODULE_NAME})"
        r"\.in_transaction\?\(\)\s+do\b",
        masked,
    )
    if (
        guard is None
        or resolve_module_reference(guard.group("repo"), aliases) != "CommsCore.Repo"
    ):
        return False

    opening_do = ELIXIR_BLOCK_TOKEN_RE.search(masked, guard.start())
    if opening_do is None:
        return False
    matching_end = _matching_elixir_block_end(masked, opening_do)
    if matching_end is None or masked[matching_end + len("end") :].strip():
        return False

    depth = 1
    else_start = None
    block_tokens = re.compile(r"\b(do|fn|else|end)\b(?![ \t]*:)")
    for token in block_tokens.finditer(masked, opening_do.end()):
        kind = token.group(1)
        if kind in {"do", "fn"}:
            depth += 1
        elif kind == "end":
            depth -= 1
            if depth == 0:
                break
        elif kind == "else" and depth == 1:
            else_start = token.end()
    if else_start is None:
        return False

    failure_branch = masked[else_start:matching_end]
    return (
        re.fullmatch(
            r"\s*\{\s*:error\s*,\s*:transaction_required\s*\}\s*",
            failure_branch,
        )
        is not None
    )


def _literal_error_clause(body: str) -> bool:
    """Allow non-dispatching validation clauses without a transaction check."""

    return (
        re.fullmatch(
            r"\s*\{\s*:error\s*,\s*:[a-z_][A-Za-z0-9_!?]*\s*\}\s*",
            _masked_elixir_code(body),
        )
        is not None
    )


def transaction_guard_errors(
    port_text: str, operations: set[tuple[str, int]]
) -> list[str]:
    """Require every declared operation clause to use a non-spoofable guard."""

    errors: list[str] = []
    aliases = module_aliases(port_text)
    for name, arity in sorted(operations):
        clauses = _public_operation_clauses(port_text, name, arity)
        if not clauses:
            errors.append(f"{name}/{arity} has no statically inspectable public clause")
            continue
        for clause_index, (style, body) in enumerate(clauses, start=1):
            guarded = style == "block" and _transaction_guarded_block(
                body,
                aliases,
            )
            terminal_error = style == "inline" and _literal_error_clause(body)
            if not guarded and not terminal_error:
                errors.append(
                    f"{name}/{arity} clause {clause_index} is not wrapped by the "
                    "required Repo.in_transaction? guard"
                )
    return errors


def declared_callbacks(text: str) -> set[tuple[str, int]]:
    callbacks: set[tuple[str, int]] = set()
    for declaration in CALLBACK_RE.finditer(text):
        parsed = balanced_call_arguments(text, declaration.end() - 1)
        if not parsed:
            continue
        arguments_text, _ = parsed
        callbacks.add((declaration.group(1), len(split_top_level_args(arguments_text))))
    return callbacks


def declared_behaviours(text: str) -> set[str]:
    aliases = module_aliases(text)
    return {
        resolve_module_reference(module, aliases)
        for module in BEHAVIOUR_RE.findall(text)
    }


def configured_module_bindings(
    root: Path,
) -> dict[tuple[str, str], set[str]]:
    """Discover statically declared module bindings in supported Config forms."""

    bindings: dict[tuple[str, str], set[str]] = {}
    config_root = root / "config"
    if not config_root.is_dir():
        return bindings

    config_block = re.compile(
        r"(?ms)^\s*config\s+:([a-z][a-z0-9_]*)\s*,"
        r"(.*?)(?=^\s*config\s+|\Z)"
    )
    key_module = re.compile(
        rf"(?m)^\s*([a-z][a-z0-9_]*):\s*({GENERIC_MODULE_NAME})\s*,?\s*$"
    )
    three_argument_binding = re.compile(
        rf"(?m)^\s*config\s+:([a-z][a-z0-9_]*)\s*,\s*"
        rf":([a-z][a-z0-9_]*)\s*,\s*({GENERIC_MODULE_NAME})\s*$"
    )
    parenthesized_three_argument_binding = re.compile(
        rf"\bconfig\s*\(\s*:([a-z][a-z0-9_]*)\s*,\s*"
        rf":([a-z][a-z0-9_]*)\s*,\s*({GENERIC_MODULE_NAME})\s*\)"
    )
    for path in sorted((*config_root.rglob("*.ex"), *config_root.rglob("*.exs"))):
        text = path.read_text(encoding="utf-8")
        aliases = module_aliases(text)
        for block in config_block.finditer(text):
            application, body = block.groups()
            for key, module in key_module.findall(body):
                bindings.setdefault((application, key), set()).add(
                    resolve_module_reference(module, aliases)
                )
        for application, key, module in three_argument_binding.findall(text):
            bindings.setdefault((application, key), set()).add(
                resolve_module_reference(module, aliases)
            )
        for application, key, module in parenthesized_three_argument_binding.findall(
            text
        ):
            bindings.setdefault((application, key), set()).add(
                resolve_module_reference(module, aliases)
            )
    return bindings


def configured_binding_key_paths(
    root: Path,
) -> dict[tuple[str, str], set[str]]:
    """Discover literal Config binding keys regardless of their configured value."""

    bindings: dict[tuple[str, str], set[str]] = {}
    config_root = root / "config"
    if not config_root.is_dir():
        return bindings

    config_block = re.compile(
        r"(?ms)^\s*config\s+:([a-z][a-z0-9_]*)\s*,"
        r"(.*?)(?=^\s*config\s+|\Z)"
    )
    key = re.compile(r"(?m)^\s*([a-z][a-z0-9_]*):")
    three_argument_binding = re.compile(
        r"(?m)^\s*config\s+:([a-z][a-z0-9_]*)\s*,\s*"
        r":([a-z][a-z0-9_]*)\s*,"
    )
    parenthesized_three_argument_binding = re.compile(
        r"\bconfig\s*\(\s*:([a-z][a-z0-9_]*)\s*,\s*"
        r":([a-z][a-z0-9_]*)\s*,"
    )
    for path in sorted((*config_root.rglob("*.ex"), *config_root.rglob("*.exs"))):
        text = elixir_code_only(path.read_text(encoding="utf-8"))
        path_key = relative(path, root)
        for block in config_block.finditer(text):
            application, body = block.groups()
            for binding_key in key.findall(body):
                bindings.setdefault((application, binding_key), set()).add(path_key)
        for application, binding_key in three_argument_binding.findall(text):
            bindings.setdefault((application, binding_key), set()).add(path_key)
        for application, binding_key in parenthesized_three_argument_binding.findall(
            text
        ):
            bindings.setdefault((application, binding_key), set()).add(path_key)
    return bindings


def _runtime_collaboration_violations(
    root: Path,
    manifest: dict,
    contexts: dict,
    schema_owners: dict[str, str],
    schema_modules: set[str],
    module_sources: dict[str, Path],
) -> tuple[set[Violation], dict[str, set[str]]]:
    violations: set[Violation] = set()
    runtime_graph: dict[str, set[str]] = {
        context_name: set() for context_name in graph_contexts(contexts)
    }
    declarations = manifest.get("runtime_collaborations", [])
    if not isinstance(declarations, list):
        return {
            Violation(
                "invalid_runtime_collaboration",
                MANIFEST_PATH.as_posix(),
                "runtime_collaborations must be a list",
            )
        }, runtime_graph

    bindings = configured_module_bindings(root)
    released_sources = released_module_sources(root)
    released_texts = {
        module: path.read_text(encoding="utf-8")
        for module, path in released_sources.items()
    }
    released_references = {
        module: core_module_references(text) for module, text in released_texts.items()
    }
    released_calls = {
        module: resolved_function_calls(text) for module, text in released_texts.items()
    }
    seen_ids: set[str] = set()
    seen_binding_keys: set[tuple[str, str]] = set()
    declared_binding_keys: set[tuple[str, str]] = set()
    declared_cross_owner_ports: set[tuple[str, str]] = set()
    graph_members = graph_contexts(contexts)

    def invalid(label: str, detail: str) -> None:
        violations.add(
            Violation(
                "invalid_runtime_collaboration",
                MANIFEST_PATH.as_posix(),
                f"{label} {detail}",
            )
        )

    for index, declaration in enumerate(declarations):
        label = f"runtime_collaborations[{index}]"
        if not isinstance(declaration, dict):
            invalid(label, "must be a mapping")
            continue

        collaboration_id = declaration.get("id")
        if not isinstance(collaboration_id, str) or not collaboration_id.strip():
            invalid(label, "must declare a non-empty id")
        elif collaboration_id in seen_ids:
            invalid(label, f"duplicates id {collaboration_id}")
        else:
            seen_ids.add(collaboration_id)
            label = collaboration_id

        consumer = declaration.get("consumer")
        provider = declaration.get("provider")
        if consumer not in contexts:
            invalid(label, f"declares unknown consumer {consumer}")
        if provider not in contexts:
            invalid(label, f"declares unknown provider {provider}")
        if consumer == provider and consumer in contexts:
            invalid(label, "consumer and provider must be different contexts")

        port = declaration.get("port")
        result_contract = declaration.get("result_contract")
        implementation = declaration.get("implementation")
        for field_name, value in (
            ("port", port),
            ("result_contract", result_contract),
            ("implementation", implementation),
        ):
            if not isinstance(value, str) or not value.startswith("CommsCore."):
                invalid(label, f"has invalid {field_name} {value!r}")

        consumer_contracts = (
            set(contexts[consumer].get("public_contracts", []))
            if consumer in contexts and isinstance(contexts[consumer], dict)
            else set()
        )
        provider_facades = (
            set(contexts[provider].get("public_facades", []))
            if provider in contexts and isinstance(contexts[provider], dict)
            else set()
        )
        if isinstance(port, str) and port not in consumer_contracts:
            invalid(label, f"port {port} is not a public contract of {consumer}")
        if isinstance(port, str):
            port_owner = declared_module_owner(port, contexts, schema_owners)
            if port_owner != consumer:
                invalid(
                    label,
                    f"port {port} belongs to {port_owner}, not consumer {consumer}",
                )
        if (
            isinstance(result_contract, str)
            and result_contract not in consumer_contracts
        ):
            invalid(
                label,
                f"result contract {result_contract} is not published by {consumer}",
            )
        if isinstance(result_contract, str):
            result_owner = declared_module_owner(
                result_contract,
                contexts,
                schema_owners,
            )
            if result_owner != consumer:
                invalid(
                    label,
                    f"result contract {result_contract} belongs to "
                    f"{result_owner}, not consumer {consumer}",
                )
        if isinstance(result_contract, str) and result_contract in schema_modules:
            invalid(label, f"result contract {result_contract} is an Ecto schema")
        if isinstance(implementation, str) and implementation not in provider_facades:
            invalid(
                label,
                f"implementation {implementation} is not a public facade of {provider}",
            )
        if isinstance(implementation, str):
            implementation_owner = declared_module_owner(
                implementation,
                contexts,
                schema_owners,
            )
            if implementation_owner != provider:
                invalid(
                    label,
                    f"implementation {implementation} belongs to "
                    f"{implementation_owner}, not provider {provider}",
                )

        port_source = module_sources.get(port) if isinstance(port, str) else None
        result_source = (
            module_sources.get(result_contract)
            if isinstance(result_contract, str)
            else None
        )
        implementation_source = (
            module_sources.get(implementation)
            if isinstance(implementation, str)
            else None
        )
        if isinstance(port, str) and port_source is None:
            invalid(label, f"declares missing port module {port}")
        if isinstance(result_contract, str) and result_source is None:
            invalid(label, f"declares missing result contract {result_contract}")
        if isinstance(implementation, str) and implementation_source is None:
            invalid(label, f"declares missing implementation {implementation}")

        operations = declaration.get("operations")
        parsed_operations: set[tuple[str, int]] = set()
        if not isinstance(operations, list) or not operations:
            invalid(label, "operations must be a non-empty list")
        else:
            for operation_index, operation in enumerate(operations):
                operation_label = f"{label}.operations[{operation_index}]"
                if not isinstance(operation, dict):
                    invalid(operation_label, "must be a mapping")
                    continue
                name = operation.get("name")
                arity = operation.get("arity")
                if (
                    not isinstance(name, str)
                    or not re.fullmatch(r"[a-z_][A-Za-z0-9_]*[!?]?", name)
                    or not isinstance(arity, int)
                    or isinstance(arity, bool)
                    or arity < 0
                ):
                    invalid(operation_label, "must declare a valid name and arity")
                    continue
                operation_key = (name, arity)
                if operation_key in parsed_operations:
                    invalid(operation_label, f"duplicates {name}/{arity}")
                parsed_operations.add(operation_key)

        if port_source:
            port_text = port_source.read_text(encoding="utf-8")
            callbacks = declared_callbacks(port_text)
            missing_callbacks = sorted(parsed_operations - callbacks)
            extra_callbacks = sorted(callbacks - parsed_operations)
            if missing_callbacks:
                invalid(
                    label,
                    "declares operations missing from the port callbacks: "
                    + ", ".join(f"{name}/{arity}" for name, arity in missing_callbacks),
                )
            if extra_callbacks:
                invalid(
                    label,
                    "port exposes undeclared callbacks: "
                    + ", ".join(f"{name}/{arity}" for name, arity in extra_callbacks),
                )
            if isinstance(
                result_contract, str
            ) and result_contract not in core_module_references(port_text):
                invalid(
                    label,
                    f"port {port} does not reference result contract {result_contract}",
                )

        if implementation_source and isinstance(port, str):
            implementation_text = implementation_source.read_text(encoding="utf-8")
            if port not in declared_behaviours(implementation_text):
                invalid(
                    label,
                    f"implementation {implementation} does not declare @behaviour {port}",
                )
            for operation_name, operation_arity in sorted(parsed_operations):
                if not module_defines_function(
                    implementation_source, operation_name, operation_arity
                ):
                    invalid(
                        label,
                        f"implementation {implementation} does not define "
                        f"{operation_name}/{operation_arity}",
                    )

        callers = declaration.get("callers")
        declared_callers: set[str] = set()
        if (
            not isinstance(callers, list)
            or not callers
            or not all(isinstance(caller, str) for caller in callers)
        ):
            invalid(label, "callers must be a non-empty list of module names")
        else:
            declared_callers = set(callers)
            if len(declared_callers) != len(callers):
                invalid(label, "callers must be unique")
            for caller in sorted(declared_callers):
                caller_source = module_sources.get(caller)
                caller_owner = declared_module_owner(caller, contexts, schema_owners)
                if caller_source is None:
                    invalid(label, f"declares missing caller module {caller}")
                if caller_owner != consumer:
                    invalid(
                        label,
                        f"caller {caller} belongs to {caller_owner}, not {consumer}",
                    )

        actual_callers: set[str] = set()
        if isinstance(port, str):
            protected_operation_names = {name for name, _arity in parsed_operations}
            for source_module, _source_path in released_sources.items():
                if source_module in {port, implementation}:
                    continue
                source_text = released_texts[source_module]
                source_references = released_references[source_module]
                source_calls = released_calls[source_module]
                evasions = (
                    module_function_evasions(
                        source_text,
                        {port: protected_operation_names},
                    )
                    if port in source_references
                    else set()
                )
                if evasions:
                    actual_callers.add(source_module)
                    invalid(
                        label,
                        f"caller {source_module} uses an unenforceable port "
                        f"invocation ({', '.join(sorted(evasions))})",
                    )
                calls = {
                    (function, arity)
                    for module, function, arity in source_calls
                    if module == port
                }
                if calls.intersection(parsed_operations):
                    actual_callers.add(source_module)

                if isinstance(implementation, str):
                    implementation_calls = {
                        (function, arity)
                        for module, function, arity in source_calls
                        if module == implementation
                    }.intersection(parsed_operations)
                    implementation_evasions = (
                        module_function_evasions(
                            source_text,
                            {implementation: protected_operation_names},
                        )
                        if implementation in source_references
                        else set()
                    )
                    if implementation_calls or implementation_evasions:
                        evidence = [
                            *(
                                f"calls {implementation}.{function}/{arity}"
                                for function, arity in sorted(implementation_calls)
                            ),
                            *sorted(implementation_evasions),
                        ]
                        invalid(
                            label,
                            f"caller {source_module} bypasses port {port} by "
                            f"invoking implementation callbacks "
                            f"({', '.join(evidence)})",
                        )
            if actual_callers != declared_callers:
                invalid(
                    label,
                    "caller set differs from source; declared "
                    f"{', '.join(sorted(declared_callers)) or '(none)'}, observed "
                    f"{', '.join(sorted(actual_callers)) or '(none)'}",
                )

        binding = declaration.get("binding")
        application = key = binding_module = None
        if not isinstance(binding, dict):
            invalid(label, "binding must be a mapping")
        else:
            application = binding.get("application")
            key = binding.get("key")
            binding_module = binding.get("module")
            if not isinstance(application, str) or not application:
                invalid(label, "binding.application must be a non-empty string")
            if not isinstance(key, str) or not key:
                invalid(label, "binding.key must be a non-empty string")
            if binding_module != implementation:
                invalid(
                    label,
                    f"binding module {binding_module} must equal implementation "
                    f"{implementation}",
                )
            if isinstance(application, str) and isinstance(key, str):
                binding_key = (application, key)
                declared_binding_keys.add(binding_key)
                if binding_key in seen_binding_keys:
                    invalid(
                        label,
                        f"binding {application}.{key} is declared more than once",
                    )
                seen_binding_keys.add(binding_key)
                configured = bindings.get(binding_key, set())
                if configured != {binding_module}:
                    invalid(
                        label,
                        f"binding {application}.{key} resolves to "
                        f"{', '.join(sorted(configured)) or '(missing)'}, expected "
                        f"{binding_module}",
                    )
                if port_source:
                    port_bindings, unresolved_port_bindings = (
                        application_binding_references(
                            port_source.read_text(encoding="utf-8")
                        )
                    )
                    for unresolved in sorted(unresolved_port_bindings):
                        invalid(label, f"port {port} {unresolved}")
                    if binding_key not in port_bindings:
                        invalid(
                            label,
                            f"port {port} does not dispatch through "
                            f"{application}.{key}",
                        )

        transaction = declaration.get("transaction")
        if transaction not in {"required", "independent"}:
            invalid(label, "transaction must be required or independent")
        elif transaction == "required" and port_source:
            port_text = port_source.read_text(encoding="utf-8")
            guard_errors = transaction_guard_errors(port_text, parsed_operations)
            for guard_error in guard_errors:
                invalid(
                    label,
                    f"transaction-required port {port}: {guard_error}",
                )

        graph_semantics = declaration.get("graph_semantics")
        expected_graph_semantics = {
            "control_flow": f"{consumer}_to_{provider}",
            "compile_dependency": f"{provider}_to_{consumer}",
            "static_cycle_policy": "dependency_inversion",
        }
        if graph_semantics != expected_graph_semantics:
            invalid(
                label,
                f"graph_semantics must exactly equal {expected_graph_semantics!r}",
            )
        if (
            not isinstance(declaration.get("condition"), str)
            or not declaration["condition"].strip()
        ):
            invalid(label, "must declare a non-empty condition")

        if (
            consumer in graph_members
            and provider in graph_members
            and consumer != provider
        ):
            runtime_graph.setdefault(consumer, set()).add(provider)
        if (
            isinstance(port, str)
            and isinstance(application, str)
            and isinstance(key, str)
        ):
            declared_cross_owner_ports.add((application, key))

    # Discover cross-owner callback adapters even when the manifest omits them.
    for port, port_source in sorted(module_sources.items()):
        port_text = port_source.read_text(encoding="utf-8")
        if not declared_callbacks(port_text):
            continue
        port_owner = declared_module_owner(port, contexts, schema_owners)
        if not port_owner:
            continue
        port_bindings, unresolved_port_bindings = application_binding_references(
            port_text
        )
        for unresolved in sorted(unresolved_port_bindings):
            violations.add(
                Violation(
                    "undeclared_runtime_binding",
                    relative(port_source, root),
                    f"{port} has an unenforceable configured binding ({unresolved})",
                )
            )
        for application, key in port_bindings:
            configured = bindings.get((application, key), set())
            provider_owners = {
                declared_module_owner(module, contexts, schema_owners)
                for module in configured
            } - {None, port_owner}
            if provider_owners and (application, key) not in declared_cross_owner_ports:
                violations.add(
                    Violation(
                        "undeclared_runtime_binding",
                        relative(port_source, root),
                        f"{port} dispatches cross-owner binding "
                        f"{application}.{key} to {', '.join(sorted(configured))} "
                        "without a runtime_collaborations declaration",
                    )
                )

    return violations, runtime_graph


def released_module_sources(root: Path) -> dict[str, Path]:
    """Index released umbrella modules from production sources only."""

    sources: dict[str, Path] = {}
    apps_root = root / "apps"
    if not apps_root.is_dir():
        return sources
    for app in sorted(ALLOWED_UMBRELLA_DEPENDENCIES):
        for path in production_sources(apps_root / app):
            text = path.read_text(encoding="utf-8")
            for module in released_module_declarations(text):
                sources[module] = path
    return sources


def _technical_interface_violations(
    root: Path,
    manifest: dict,
    contexts: dict,
    schema_owners: dict[str, str],
    schema_modules: set[str],
    all_module_sources: dict[str, Path],
) -> tuple[set[Violation], set[str]]:
    """Validate exact released adapter-facing technical interfaces."""

    violations: set[Violation] = set()
    if "technical_interfaces" not in manifest:
        return {
            Violation(
                "invalid_technical_interface",
                MANIFEST_PATH.as_posix(),
                "technical_interfaces is required",
            )
        }, set()
    declarations = manifest.get("technical_interfaces")
    approved_interfaces: set[str] = set()
    if not isinstance(declarations, list):
        return {
            Violation(
                "invalid_technical_interface",
                MANIFEST_PATH.as_posix(),
                "technical_interfaces must be a list",
            )
        }, approved_interfaces

    bindings = configured_module_bindings(root)
    public_contracts = {
        contract
        for context in contexts.values()
        if isinstance(context, dict)
        for contract in context.get("public_contracts", [])
    }
    published_public_interfaces = public_contracts | {
        facade
        for context in contexts.values()
        if isinstance(context, dict)
        for facade in context.get("public_facades", [])
    }
    source_texts = {
        module: path.read_text(encoding="utf-8")
        for module, path in all_module_sources.items()
    }
    source_references = {
        module: core_module_references(text) for module, text in source_texts.items()
    }
    source_calls = {
        module: runtime_function_calls(text) for module, text in source_texts.items()
    }
    seen_ids: set[str] = set()
    seen_bindings: set[tuple[str, str]] = set()
    allowed_fields = {
        "id",
        "owner",
        "interface",
        "callers",
        "operations",
        "dispatch",
        "contracts",
        "behaviour",
        "implementation",
        "binding",
        "transaction",
        "condition",
    }

    def invalid(label: str, detail: str) -> None:
        violations.add(
            Violation(
                "invalid_technical_interface",
                MANIFEST_PATH.as_posix(),
                f"{label} {detail}",
            )
        )

    for index, declaration in enumerate(declarations):
        label = f"technical_interfaces[{index}]"
        if not isinstance(declaration, dict):
            invalid(label, "must be a mapping")
            continue
        unsupported = sorted(set(declaration) - allowed_fields)
        if unsupported:
            invalid(label, f"has unsupported fields {', '.join(unsupported)}")

        interface_id = declaration.get("id")
        if not isinstance(interface_id, str) or not interface_id.strip():
            invalid(label, "must declare a non-empty id")
        elif interface_id in seen_ids:
            invalid(label, f"duplicates id {interface_id}")
        else:
            seen_ids.add(interface_id)
            label = interface_id

        owner = declaration.get("owner")
        if owner not in contexts:
            invalid(label, f"declares unknown owner {owner}")

        interface = declaration.get("interface")
        interface_source = (
            all_module_sources.get(interface) if isinstance(interface, str) else None
        )
        if not isinstance(interface, str) or not interface.startswith("CommsCore."):
            invalid(label, f"has invalid interface {interface!r}")
        elif interface_source is None:
            invalid(label, f"declares missing interface module {interface}")
        else:
            approved_interfaces.add(interface)
            interface_owner = declared_module_owner(
                interface,
                contexts,
                schema_owners,
            )
            if interface_owner != owner:
                invalid(
                    label,
                    f"interface {interface} belongs to {interface_owner}, not {owner}",
                )
            if interface in schema_modules:
                invalid(label, f"interface {interface} is an Ecto schema")

        operations = declaration.get("operations")
        parsed_operations: set[tuple[str, int]] = set()
        if not isinstance(operations, list) or not operations:
            invalid(label, "operations must be a non-empty list")
        else:
            for operation_index, operation in enumerate(operations):
                operation_label = f"{label}.operations[{operation_index}]"
                if not isinstance(operation, dict) or set(operation) != {
                    "name",
                    "arity",
                }:
                    invalid(
                        operation_label,
                        "must contain exactly name and arity",
                    )
                    continue
                name = operation.get("name")
                arity = operation.get("arity")
                if (
                    not isinstance(name, str)
                    or not re.fullmatch(r"[a-z_][A-Za-z0-9_]*[!?]?", name)
                    or not isinstance(arity, int)
                    or isinstance(arity, bool)
                    or arity < 0
                ):
                    invalid(operation_label, "must declare a valid name and arity")
                    continue
                operation_key = (name, arity)
                if operation_key in parsed_operations:
                    invalid(operation_label, f"duplicates {name}/{arity}")
                parsed_operations.add(operation_key)

        dispatch = declaration.get("dispatch")
        if dispatch not in {"direct", "configured"}:
            invalid(label, "dispatch must be direct or configured")
        if interface_source:
            for operation_name, operation_arity in sorted(parsed_operations):
                if not module_defines_function(
                    interface_source,
                    operation_name,
                    operation_arity,
                ):
                    invalid(
                        label,
                        f"interface {interface} does not define "
                        f"{operation_name}/{operation_arity}",
                    )
            callbacks = declared_callbacks(interface_source.read_text(encoding="utf-8"))
            if dispatch == "configured" and callbacks:
                invalid(
                    label,
                    f"configured dispatcher {interface} must not also own "
                    "behaviour callbacks",
                )

        callers = declaration.get("callers")
        declared_callers: set[str] = set()
        if (
            not isinstance(callers, list)
            or not callers
            or not all(isinstance(caller, str) and caller for caller in callers)
        ):
            invalid(label, "callers must be a non-empty list of module names")
        else:
            declared_callers = set(callers)
            if len(declared_callers) != len(callers):
                invalid(label, "callers must be unique")
            missing_callers = sorted(declared_callers - set(all_module_sources))
            if missing_callers:
                invalid(
                    label,
                    f"declares missing callers {', '.join(missing_callers)}",
                )

        behaviour = declaration.get("behaviour")
        behaviour_source = (
            all_module_sources.get(behaviour) if isinstance(behaviour, str) else None
        )
        implementation = declaration.get("implementation")
        implementation_source = (
            all_module_sources.get(implementation)
            if isinstance(implementation, str)
            else None
        )
        binding = declaration.get("binding")
        if dispatch == "direct":
            if behaviour is not None:
                invalid(label, "direct dispatch may not declare a behaviour")
            if implementation is not None:
                invalid(label, "direct dispatch may not declare an implementation")
            if binding is not None:
                invalid(label, "direct dispatch may not declare a binding")
        elif dispatch == "configured":
            if (
                not isinstance(behaviour, str)
                or not behaviour.startswith("CommsCore.")
                or behaviour_source is None
            ):
                invalid(label, f"declares missing behaviour module {behaviour}")
            else:
                approved_interfaces.add(behaviour)
                behaviour_owner = declared_module_owner(
                    behaviour,
                    contexts,
                    schema_owners,
                )
                if behaviour_owner != owner:
                    invalid(
                        label,
                        f"behaviour {behaviour} belongs to {behaviour_owner}, "
                        f"not {owner}",
                    )
                callbacks = declared_callbacks(
                    behaviour_source.read_text(encoding="utf-8")
                )
                if callbacks != parsed_operations:
                    invalid(
                        label,
                        "behaviour callbacks differ from operations; "
                        f"declared {sorted(parsed_operations)!r}, "
                        f"observed {sorted(callbacks)!r}",
                    )
            if not isinstance(implementation, str) or implementation_source is None:
                invalid(
                    label,
                    f"declares missing implementation module {implementation}",
                )
            elif isinstance(behaviour, str):
                implementation_text = implementation_source.read_text(encoding="utf-8")
                if behaviour not in declared_behaviours(implementation_text):
                    invalid(
                        label,
                        f"implementation {implementation} does not declare "
                        f"@behaviour {behaviour}",
                    )
                for operation_name, operation_arity in sorted(parsed_operations):
                    if not module_defines_function(
                        implementation_source,
                        operation_name,
                        operation_arity,
                    ):
                        invalid(
                            label,
                            f"implementation {implementation} does not define "
                            f"{operation_name}/{operation_arity}",
                        )
            if not isinstance(binding, dict) or set(binding) != {
                "application",
                "key",
                "module",
            }:
                invalid(
                    label,
                    "configured binding must contain exactly application, key, and module",
                )
            else:
                application = binding.get("application")
                key = binding.get("key")
                binding_module = binding.get("module")
                if (
                    not isinstance(application, str)
                    or not application
                    or not isinstance(key, str)
                    or not key
                ):
                    invalid(
                        label,
                        "binding application and key must be non-empty strings",
                    )
                elif binding_module != implementation:
                    invalid(
                        label,
                        f"binding module {binding_module} must equal "
                        f"implementation {implementation}",
                    )
                else:
                    binding_key = (application, key)
                    if binding_key in seen_bindings:
                        invalid(
                            label,
                            f"binding {application}.{key} is declared more than once",
                        )
                    seen_bindings.add(binding_key)
                    configured = bindings.get(binding_key, set())
                    if configured != {binding_module}:
                        invalid(
                            label,
                            f"binding {application}.{key} resolves to "
                            f"{', '.join(sorted(configured)) or '(missing)'}, "
                            f"expected {binding_module}",
                        )
                    if interface_source:
                        observed_bindings, unresolved_bindings = (
                            application_binding_references(
                                interface_source.read_text(encoding="utf-8")
                            )
                        )
                        for unresolved in sorted(unresolved_bindings):
                            invalid(label, f"interface {interface} {unresolved}")
                        if binding_key not in observed_bindings:
                            invalid(
                                label,
                                f"interface {interface} does not dispatch through "
                                f"{application}.{key}",
                            )

        actual_callers: set[str] = set()
        observed_operations: set[tuple[str, int]] = set()
        if isinstance(interface, str):
            for source_module, _source_path in all_module_sources.items():
                if source_module in {interface, implementation}:
                    continue
                is_released_adapter = source_module.startswith(
                    (
                        "CommsWeb.",
                        "CommsWorkers.",
                        "CommsIntegrations.",
                        "CommsObservability.",
                    )
                )
                source_text = source_texts[source_module]
                calls = {
                    (function, arity)
                    for module, function, arity in source_calls[source_module]
                    if module == interface
                }
                evasions = (
                    module_function_evasions(
                        source_text,
                        {interface: None},
                        reject_unknown_dynamic_target=(
                            source_module in declared_callers
                        ),
                    )
                    if interface in source_references[source_module]
                    else set()
                )
                if evasions:
                    actual_callers.add(source_module)
                    invalid(
                        label,
                        f"caller {source_module} uses an unenforceable interface "
                        f"invocation ({', '.join(sorted(evasions))})",
                    )
                declared_calls = calls.intersection(parsed_operations)
                undeclared_calls = calls - parsed_operations
                if declared_calls:
                    actual_callers.add(source_module)
                if source_module in declared_callers:
                    observed_operations.update(declared_calls)
                prohibited_undeclared_calls = (
                    undeclared_calls
                    if (
                        source_module in declared_callers
                        or is_released_adapter
                        or interface not in published_public_interfaces
                    )
                    else set()
                )
                if prohibited_undeclared_calls:
                    actual_callers.add(source_module)
                    rendered_calls = ", ".join(
                        f"{function}/{arity}"
                        for function, arity in sorted(prohibited_undeclared_calls)
                    )
                    invalid(
                        label,
                        f"caller {source_module} invokes undeclared operations "
                        f"on {interface}: {rendered_calls}",
                    )
            if actual_callers != declared_callers:
                invalid(
                    label,
                    "caller set differs from source; declared "
                    f"{', '.join(sorted(declared_callers)) or '(none)'}, observed "
                    f"{', '.join(sorted(actual_callers)) or '(none)'}",
                )
            unobserved_operations = parsed_operations - observed_operations
            if unobserved_operations:
                invalid(
                    label,
                    "declared operations are not used by a declared caller: "
                    + ", ".join(
                        f"{function}/{arity}"
                        for function, arity in sorted(unobserved_operations)
                    ),
                )

        contracts = declaration.get("contracts", [])
        if (
            not isinstance(contracts, list)
            or not contracts
            or not all(isinstance(contract, str) and contract for contract in contracts)
            or len(set(contracts)) != len(contracts)
        ):
            invalid(
                label,
                "contracts must be a non-empty list of unique module names",
            )
            contracts = []
        referenced_text = "\n".join(
            source.read_text(encoding="utf-8")
            for module, source in all_module_sources.items()
            if module in declared_callers | {interface, behaviour, implementation}
            and source is not None
        )
        referenced_contracts = core_module_references(referenced_text)
        for contract in contracts:
            if contract not in public_contracts:
                invalid(label, f"contract {contract} is not a published contract")
            if contract in schema_modules:
                invalid(label, f"contract {contract} is an Ecto schema")
            if contract not in all_module_sources:
                invalid(label, f"declares missing contract module {contract}")
            if contract != interface and contract not in referenced_contracts:
                invalid(
                    label,
                    f"contract {contract} is not referenced by the interface boundary",
                )

        transaction = declaration.get("transaction")
        if transaction not in {"required", "independent"}:
            invalid(label, "transaction must be required or independent")
        elif transaction == "required" and interface_source:
            for guard_error in transaction_guard_errors(
                interface_source.read_text(encoding="utf-8"),
                parsed_operations,
            ):
                invalid(
                    label,
                    f"transaction-required interface {interface}: {guard_error}",
                )
        condition = declaration.get("condition")
        if not isinstance(condition, str) or not condition.strip():
            invalid(label, "must declare a non-empty condition")

    adapter_prefixes = (
        "CommsWeb.",
        "CommsWorkers.",
        "CommsIntegrations.",
        "CommsObservability.",
    )
    for source_module, _source_path in all_module_sources.items():
        source_text = source_texts[source_module]
        if source_module.startswith(adapter_prefixes):
            for target_module in sorted(core_module_references(source_text)):
                if target_module in schema_modules:
                    continue
                target_owner = declared_module_owner(
                    target_module,
                    contexts,
                    schema_owners,
                )
                target_kind = (
                    contexts.get(target_owner, {}).get("kind") if target_owner else None
                )
                if (
                    target_kind == "technical"
                    and target_module not in approved_interfaces
                ):
                    invalid(
                        source_module,
                        f"uses undeclared technical interface {target_module}",
                    )
        elif source_module.startswith("CommsCore."):
            source_bindings, unresolved_bindings = application_binding_references(
                source_text
            )
            for unresolved in sorted(unresolved_bindings):
                invalid(
                    source_module,
                    f"uses an unenforceable configured binding ({unresolved})",
                )
            for application, key in source_bindings:
                configured = bindings.get((application, key), set())
                if (
                    any(module.startswith(adapter_prefixes) for module in configured)
                    and (application, key) not in seen_bindings
                ):
                    invalid(
                        source_module,
                        f"dispatches undeclared adapter binding {application}.{key}",
                    )

    return violations, approved_interfaces


def schema_owner_map(tables: dict) -> dict[str, str]:
    return {
        declaration["canonical_schema"]: declaration["owner"]
        for declaration in tables.values()
        if declaration.get("canonical_schema") and declaration.get("owner")
    }


WRITE_CALL_RE = re.compile(
    rf"\b(?P<receiver>{GENERIC_MODULE_NAME})\."
    r"(?P<operation>insert!?|insert_or_update!?|insert_all|"
    r"update!?|update_all|delete!?|delete_all)\s*\("
)
BOUND_WRITE_CALL_RE = re.compile(
    r"(?<![A-Za-z0-9_])"
    r"(?P<receiver>@?[a-z_][A-Za-z0-9_]*)\."
    r"(?P<operation>insert!?|insert_or_update!?|insert_all|"
    r"update!?|update_all|delete!?|delete_all)\s*\("
)
REPO_MUTATION_FUNCTIONS = frozenset(
    {
        "delete",
        "delete!",
        "delete_all",
        "insert",
        "insert!",
        "insert_all",
        "insert_or_update",
        "insert_or_update!",
        "update",
        "update!",
        "update_all",
    }
)
ECTO_MULTI_MUTATION_FUNCTIONS = frozenset(
    {
        "delete",
        "delete_all",
        "insert",
        "insert_all",
        "insert_or_update",
        "merge",
        "run",
        "update",
        "update_all",
    }
)
OBAN_MUTATION_FUNCTIONS = frozenset(
    {
        "cancel_all_jobs",
        "cancel_job",
        "delete_all_jobs",
        "delete_job",
        "drain_queue",
        "insert",
        "insert!",
        "insert_all",
        "insert_all!",
        "pause_queue",
        "resume_queue",
        "retry_all_jobs",
        "retry_job",
        "scale_queue",
        "snooze_job",
        "start_queue",
        "stop_queue",
    }
)
RAW_SQL_DML_RE = re.compile(
    r"\b(?:INSERT|UPDATE|DELETE|MERGE|CREATE|DROP|ALTER|TRUNCATE|GRANT|"
    r"REVOKE|VACUUM|ANALYZE|REINDEX|CLUSTER|REFRESH|COMMENT|COPY|CALL|DO|"
    r"SET|RESET|LOCK|DISCARD|CHECKPOINT)\b",
    re.IGNORECASE,
)
RAW_SQL_TABLE_TARGET_RES = (
    re.compile(
        r"\b(?:INSERT\s+INTO|MERGE\s+INTO|UPDATE|DELETE\s+FROM|"
        r"ALTER\s+TABLE|CREATE\s+TABLE|DROP\s+TABLE|TRUNCATE(?:\s+TABLE)?|COPY)"
        r"\s+(?:IF\s+(?:NOT\s+)?EXISTS\s+)?(?:ONLY\s+)?"
        r'(?:(?:"?[A-Za-z_][A-Za-z0-9_]*"?)[.])?'
        r'"?(?P<table>[A-Za-z_][A-Za-z0-9_]*)"?',
        re.IGNORECASE,
    ),
    re.compile(
        r"\bCREATE\s+(?:UNIQUE\s+)?INDEX(?:\s+CONCURRENTLY)?"
        r"(?:\s+IF\s+NOT\s+EXISTS)?\s+[^\s;]+\s+ON\s+"
        r'(?:(?:"?[A-Za-z_][A-Za-z0-9_]*"?)[.])?'
        r'"?(?P<table>[A-Za-z_][A-Za-z0-9_]*)"?',
        re.IGNORECASE,
    ),
    re.compile(
        r"\b(?:CREATE|DROP)\s+TRIGGER\b[\s\S]*?\bON\s+"
        r'(?:(?:"?[A-Za-z_][A-Za-z0-9_]*"?)[.])?'
        r'"?(?P<table>[A-Za-z_][A-Za-z0-9_]*)"?',
        re.IGNORECASE,
    ),
)
RAW_SQL_TABLE_MUTATION_RE = re.compile(
    r"\b(?:INSERT\s+INTO|MERGE\s+INTO|UPDATE|DELETE\s+FROM|"
    r"ALTER\s+TABLE|CREATE\s+TABLE|DROP\s+TABLE|TRUNCATE(?:\s+TABLE)?|"
    r"COPY|CREATE\s+(?:UNIQUE\s+)?INDEX|CREATE\s+TRIGGER|DROP\s+TRIGGER)\b",
    re.IGNORECASE,
)


def balanced_call_arguments(text: str, open_index: int) -> tuple[str, int] | None:
    """Return a call's argument text and the index after its closing parenthesis."""

    depth = 0
    quote: str | None = None
    escaped = False
    for index in range(open_index, len(text)):
        character = text[index]
        if quote:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
            continue
        if character in {'"', "'"}:
            quote = character
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return text[open_index + 1 : index], index + 1
    return None


def _module_attribute_value(text: str, attribute: str) -> str | None:
    declaration = re.search(
        rf"(?ms)^\s*@{re.escape(attribute)}\s+"
        rf"(?P<value>.*?)(?=^\s*(?:@[a-z_]|defp?\s|defmodule\s)|\Z)",
        text,
    )
    return declaration.group("value").strip() if declaration else None


def _static_sql_expression(text: str, expression: str) -> str | None:
    expression = expression.strip()
    attribute = re.fullmatch(r"@([a-z_][A-Za-z0-9_]*)", expression)
    if attribute:
        expression = _module_attribute_value(text, attribute.group(1)) or ""
    if not expression or "#{" in expression or "<>" in expression:
        return None
    if not (
        expression.startswith('"')
        or expression.startswith("~s")
        or expression.startswith("~S")
    ):
        return None
    return expression


def _literal_table_name(text: str, expression: str) -> str | None:
    """Resolve a literal table atom/string or a literal module attribute."""

    expression = expression.strip()
    attribute = re.fullmatch(r"@([a-z_][A-Za-z0-9_]*)", expression)
    if attribute:
        value = _module_attribute_value(text, attribute.group(1))
        return _literal_table_name(text, value) if value else None
    literal = re.fullmatch(r':([a-z_][A-Za-z0-9_]*)', expression)
    if literal:
        return literal.group(1)
    literal = re.fullmatch(r'"([a-z_][A-Za-z0-9_]*)"', expression)
    return literal.group(1) if literal else None


def _raw_sql_targets(sql: str) -> tuple[set[str], bool]:
    """Return statically named SQL mutation targets and unresolved mutation state."""

    if not RAW_SQL_DML_RE.search(sql):
        return set(), False
    targets = {
        match.group("table")
        for pattern in RAW_SQL_TABLE_TARGET_RES
        for match in pattern.finditer(sql)
        if match.group("table").upper()
        not in {"OF", "SET", "IF", "ONLY", "WHERE", "ON"}
    }
    return targets, not targets


def _raw_sql_query_calls(text: str) -> tuple[list[re.Match[str]], set[str]]:
    """Locate statically callable Ecto SQL queries and dynamic evasions."""

    code = elixir_code_only(text)
    aliases = module_aliases(code)
    bindings = static_module_bindings(code)
    calls: list[re.Match[str]] = []
    for call in QUALIFIED_CALL_RE.finditer(code):
        receiver, function = call.groups()
        module = resolve_module_reference(receiver, aliases)
        if module == "Ecto.Adapters.SQL" and function in {"query", "query!"}:
            calls.append(call)
    bound_call_re = re.compile(
        r"(?<![A-Za-z0-9_])(?P<receiver>@?[a-z_][A-Za-z0-9_]*)\."
        r"(?P<function>query!?)\s*\("
    )
    for call in bound_call_re.finditer(code):
        if bindings.get(call.group("receiver")) == "Ecto.Adapters.SQL":
            calls.append(call)
    if "Ecto.Adapters.SQL" in imported_modules(code):
        calls.extend(re.finditer(r"(?<![A-Za-z0-9_.])query!?\s*\(", code))
    evasions = module_function_evasions(
        text,
        {"Ecto.Adapters.SQL": {"query", "query!"}},
    )
    if any(
        module == "Ecto.Adapters.SQL" and function in {"query", "query!"}
        for module, function, _arity in delegated_function_calls(text)
    ):
        evasions.add("delegates an Ecto.Adapters.SQL query")
    return calls, evasions


def raw_sql_mutation_targets(text: str) -> tuple[set[str], set[str]]:
    """Return raw-SQL mutation tables and fail-closed unresolved evidence."""

    tables: set[str] = set()
    unresolved: set[str] = set()
    query_calls, evasions = _raw_sql_query_calls(text)
    unresolved.update(evasions)
    for call in query_calls:
        parsed = balanced_call_arguments(text, call.end() - 1)
        if not parsed:
            unresolved.add("cannot parse Ecto.Adapters.SQL query arguments")
            continue
        arguments = split_top_level_args(parsed[0])
        if len(arguments) < 2:
            unresolved.add("Ecto.Adapters.SQL query has no SQL argument")
            continue
        sql = _static_sql_expression(text, arguments[1])
        if sql is None:
            unresolved.add("Ecto.Adapters.SQL query uses dynamic SQL")
            continue
        targets, target_unresolved = _raw_sql_targets(sql)
        tables.update(targets)
        if target_unresolved:
            unresolved.add("raw SQL mutation target cannot be attributed")
    return tables, unresolved


def raw_sql_write_or_unresolved(text: str) -> bool:
    """Reject mutating SQL and SQL whose statement cannot be statically reviewed."""

    tables, unresolved = raw_sql_mutation_targets(text)
    return bool(tables or unresolved)


def read_model_mutation_references(text: str) -> set[str]:
    protected_modules: dict[str, set[str] | None] = {
        "CommsCore.Repo": set(REPO_MUTATION_FUNCTIONS),
        "Ecto.Multi": set(ECTO_MULTI_MUTATION_FUNCTIONS),
        "Oban": set(OBAN_MUTATION_FUNCTIONS),
    }
    evidence = {
        f"calls {module}.{function}/{arity}"
        for module, function, arity in resolved_function_calls(text)
        if module in protected_modules
        and function in (protected_modules[module] or set())
    }
    evidence.update(
        module_function_evasions(
            text,
            protected_modules,
        )
    )
    return evidence


def split_top_level_args(arguments: str) -> list[str]:
    parts: list[str] = []
    start = 0
    depth = 0
    quote: str | None = None
    escaped = False
    matching = {")": "(", "]": "[", "}": "{"}
    stack: list[str] = []
    for index, character in enumerate(arguments):
        if quote:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
            continue
        if character in {'"', "'"}:
            quote = character
        elif character in "([{":
            stack.append(character)
            depth += 1
        elif character in ")]}":
            if stack and stack[-1] == matching[character]:
                stack.pop()
                depth -= 1
        elif character == "," and depth == 0:
            parts.append(arguments[start:index].strip())
            start = index + 1
    tail = arguments[start:].strip()
    if tail:
        parts.append(tail)
    return parts


def pipeline_input_before(text: str, call_start: int) -> str | None:
    pipe = text.rfind("|>", 0, call_start)
    if pipe < 0 or text[pipe + 2 : call_start].strip():
        return None

    line_start = text.rfind("\n", 0, pipe) + 1
    prefix = text[line_start:pipe]
    if prefix.strip():
        return prefix.strip()

    start = line_start
    delimiter_balance = 0
    while start > 0:
        previous_end = start - 1
        previous_start = text.rfind("\n", 0, previous_end) + 1
        previous_line = text[previous_start:previous_end]
        start = previous_start
        delimiter_balance += sum(previous_line.count(item) for item in ")]}")
        delimiter_balance -= sum(previous_line.count(item) for item in "([{")
        if delimiter_balance <= 0 and not previous_line.lstrip().startswith("|>"):
            break
    return text[start:pipe].strip()


def _schema_token_map(
    aliases: dict[str, str], schema_modules: set[str]
) -> dict[str, str]:
    tokens = {module: module for module in schema_modules}
    tokens.update({f"Elixir.{module}": module for module in schema_modules})
    for alias, module in aliases.items():
        for schema_module in schema_modules:
            if schema_module == module:
                tokens[alias] = schema_module
            elif schema_module.startswith(f"{module}."):
                tokens[f"{alias}{schema_module[len(module) :]}"] = schema_module
    return tokens


def _binding_expression(
    text: str, variable: str, before: int
) -> tuple[str, int] | None:
    assignments = list(
        re.finditer(rf"(?m)^\s*{re.escape(variable)}\s*=\s*", text[:before])
    )
    if not assignments:
        return None
    assignment = assignments[-1]
    return text[assignment.end() : before], assignment.start()


def _resolve_schema_expression(
    expression: str,
    *,
    aliases: dict[str, str],
    schema_modules: set[str],
    source: str,
    before: int,
    depth: int = 0,
) -> str | None:
    if depth > 3:
        return None
    tokens = _schema_token_map(aliases, schema_modules)
    token_pattern = "|".join(
        sorted((re.escape(token) for token in tokens), key=len, reverse=True)
    )
    if not token_pattern:
        return None

    root = re.search(
        rf"\bfrom\s*(?:\(\s*)?[a-z_][A-Za-z0-9_]*\s+in\s+"
        rf"(?P<schema>{token_pattern})\b",
        expression,
    )
    if root:
        return tokens[root.group("schema")]

    schema_mentions = list(
        re.finditer(
            rf"(?:%(?P<struct>{token_pattern})\s*\{{|"
            rf"(?P<changeset>{token_pattern})\."
            rf"[a-zA-Z0-9_]*changeset\s*\()",
            expression,
        )
    )
    if schema_mentions:
        mention = schema_mentions[-1]
        return tokens[mention.group("struct") or mention.group("changeset")]

    leading = re.match(rf"\s*(?P<schema>{token_pattern})\b", expression)
    if leading:
        return tokens[leading.group("schema")]

    pipeline_root = re.search(
        rf"(?:\bcase\s+|(?:^|\n)\s*)(?P<schema>{token_pattern})\s*"
        r"(?:\|>|$)",
        expression,
    )
    if pipeline_root:
        return tokens[pipeline_root.group("schema")]

    variable = re.match(r"\s*([a-z_][A-Za-z0-9_]*)\b", expression)
    if variable:
        typed_bindings = list(
            re.finditer(
                rf"%(?P<schema>{token_pattern})\s*\{{[^}}]*\}}\s*=\s*"
                rf"{re.escape(variable.group(1))}\b",
                source[:before],
            )
        )
        if typed_bindings:
            return tokens[typed_bindings[-1].group("schema")]
        binding = _binding_expression(source, variable.group(1), before)
        if binding:
            bound_expression, bound_at = binding
            return _resolve_schema_expression(
                bound_expression,
                aliases=aliases,
                schema_modules=schema_modules,
                source=source,
                before=bound_at,
                depth=depth + 1,
            )
    for variable_name in re.findall(r"\b([a-z_][A-Za-z0-9_]*)\b", expression):
        binding = _binding_expression(source, variable_name, before)
        if not binding:
            continue
        bound_expression, bound_at = binding
        resolved = _resolve_schema_expression(
            bound_expression,
            aliases=aliases,
            schema_modules=schema_modules,
            source=source,
            before=bound_at,
            depth=depth + 1,
        )
        if resolved:
            return resolved

    for function_name in re.findall(
        r"(?<![A-Za-z0-9_.])([a-z_][A-Za-z0-9_]*)\s*\(",
        expression,
    ):
        definition = re.search(
            rf"(?m)^\s*defp?\s+{re.escape(function_name)}\s*\([^)]*\)\s+do\b",
            source,
        )
        if not definition:
            continue
        following = re.search(
            r"(?m)^\s*defp?\s+[a-z_][A-Za-z0-9_!?]*\s*\(",
            source[definition.end() :],
        )
        body_end = (
            definition.end() + following.start()
            if following
            else len(source)
        )
        resolved = _resolve_schema_expression(
            source[definition.end() : body_end],
            aliases=aliases,
            schema_modules=schema_modules,
            source=source,
            before=definition.start(),
            depth=depth + 1,
        )
        if resolved:
            return resolved
    return None


def _write_target_expression(
    receiver: str,
    operation: str,
    arguments: list[str],
    pipeline_input: str | None,
) -> str | None:
    if receiver == "Repo":
        if pipeline_input is not None:
            return pipeline_input
        if arguments:
            return arguments[0]
        return None

    piped = pipeline_input is not None
    if operation in {"insert_all", "update_all", "delete_all"}:
        target_index = 1 if piped else 2
    else:
        target_index = 1 if piped else 2
    if len(arguments) > target_index:
        return arguments[target_index]
    return None


def _local_write_wrappers(text: str) -> dict[str, tuple[int, str]]:
    definitions = list(
        re.finditer(
            r"(?m)^\s*defp\s+([a-z_][A-Za-z0-9_!?]*)\s*\(([^)]*)\)",
            text,
        )
    )
    wrappers: dict[str, tuple[int, str]] = {}
    aliases = module_aliases(text)
    for index, definition in enumerate(definitions):
        block_end = (
            definitions[index + 1].start()
            if index + 1 < len(definitions)
            else len(text)
        )
        block = text[definition.end() : block_end]
        parameters = [
            re.sub(r"\s*\\\\.*$", "", item).strip()
            for item in split_top_level_args(definition.group(2))
        ]
        bindings = {
            binding: resolve_module_reference(module, aliases)
            for binding, module in static_module_bindings(block).items()
        }
        write_calls = [
            *(
                (
                    call,
                    resolve_module_reference(call.group("receiver"), aliases),
                )
                for call in WRITE_CALL_RE.finditer(block)
            ),
            *(
                (call, bindings.get(call.group("receiver")))
                for call in BOUND_WRITE_CALL_RE.finditer(block)
            ),
        ]
        for parameter_index, parameter in enumerate(parameters):
            if not re.fullmatch(r"[a-z_][A-Za-z0-9_]*", parameter):
                continue
            for call, receiver in write_calls:
                if receiver not in {"CommsCore.Repo", "Ecto.Multi"}:
                    continue
                parsed = balanced_call_arguments(block, call.end() - 1)
                if not parsed:
                    continue
                arguments_text, _ = parsed
                target = _write_target_expression(
                    "Repo" if receiver == "CommsCore.Repo" else "Ecto.Multi",
                    call.group("operation"),
                    split_top_level_args(arguments_text),
                    pipeline_input_before(block, call.start()),
                )
                if target and re.fullmatch(
                    rf"\s*{re.escape(parameter)}\s*",
                    target,
                ):
                    wrappers[definition.group(1)] = (
                        parameter_index,
                        call.group("operation"),
                    )

    aliases = module_aliases(text)
    for declaration in re.finditer(
        r"(?m)^\s*defdelegate\s+"
        r"(?P<function>[a-z_][A-Za-z0-9_]*[!?]?)\s*\(",
        elixir_code_only(text),
    ):
        parsed = balanced_call_arguments(text, declaration.end() - 1)
        if not parsed:
            continue
        arguments_text, end_index = parsed
        tail = text[end_index:]
        boundary = re.search(
            r"(?m)^\s*(?:def(?:p|delegate)?\b|@[a-z_]|end\b)",
            tail,
        )
        options = tail[: boundary.start()] if boundary else tail
        target = re.search(
            rf"\bto:\s*(?P<module>{GENERIC_MODULE_NAME})",
            options,
        )
        operation = re.search(
            r"\bas:\s*:(?P<function>[a-z_][A-Za-z0-9_]*[!?]?)",
            options,
        )
        if target is None:
            continue
        target_module = resolve_module_reference(target.group("module"), aliases)
        target_function = (
            operation.group("function") if operation else declaration.group("function")
        )
        arguments = split_top_level_args(arguments_text)
        if (
            target_module == "CommsCore.Repo"
            and target_function in REPO_MUTATION_FUNCTIONS
            and arguments
        ):
            wrappers[declaration.group("function")] = (0, target_function)
        elif (
            target_module == "Ecto.Multi"
            and target_function in ECTO_MULTI_MUTATION_FUNCTIONS
            and arguments
        ):
            wrappers[declaration.group("function")] = (
                min(2, len(arguments) - 1),
                target_function,
            )
    return wrappers


def _resolve_persistence_target(
    expression: str,
    *,
    aliases: dict[str, str],
    schema_modules: set[str],
    schema_tables: dict[str, str],
    source: str,
    before: int,
    depth: int = 0,
) -> tuple[str, str] | None:
    """Resolve a schema or literal table used as an Ecto persistence target."""

    if depth > 3:
        return None
    schema = _resolve_schema_expression(
        expression,
        aliases=aliases,
        schema_modules=schema_modules,
        source=source,
        before=before,
        depth=depth,
    )
    if schema:
        return "schema", schema

    stripped = expression.strip()
    attribute = re.fullmatch(r"@([a-z_][A-Za-z0-9_]*)", stripped)
    if attribute:
        value = _module_attribute_value(source, attribute.group(1))
        if value:
            return _resolve_persistence_target(
                value,
                aliases=aliases,
                schema_modules=schema_modules,
                schema_tables=schema_tables,
                source=source,
                before=before,
                depth=depth + 1,
            )
        return None

    literal_table = _literal_table_name(source, stripped)
    if literal_table:
        return "table", literal_table

    query_literal = re.search(
        r"\bfrom\s*(?:\(\s*)?(?:[a-z_][A-Za-z0-9_]*\s+in\s+)?"
        r'(?P<table>:[a-z_][A-Za-z0-9_]*|"[a-z_][A-Za-z0-9_]*")',
        stripped,
    )
    if query_literal:
        table = _literal_table_name(source, query_literal.group("table"))
        if table:
            return "table", table

    variable = re.match(r"\s*([a-z_][A-Za-z0-9_]*)\b", stripped)
    if variable:
        binding = _binding_expression(source, variable.group(1), before)
        if binding:
            bound_expression, bound_at = binding
            return _resolve_persistence_target(
                bound_expression,
                aliases=aliases,
                schema_modules=schema_modules,
                schema_tables=schema_tables,
                source=source,
                before=bound_at,
                depth=depth + 1,
            )
    return None


def _wrapper_target_parameter(
    text: str,
    call_start: int,
    target_expression: str,
    wrappers: dict[str, tuple[int, str]],
) -> bool:
    """Whether an unresolved call is the generic body of a reviewed local wrapper."""

    definitions = list(
        re.finditer(
            r"(?m)^\s*defp?\s+([a-z_][A-Za-z0-9_!?]*)\s*\(([^)]*)\)",
            text[:call_start],
        )
    )
    if not definitions:
        return False
    definition = definitions[-1]
    wrapper = definition.group(1)
    wrapper_declaration = wrappers.get(wrapper)
    if wrapper_declaration is None:
        return False
    parameter_index, _operation = wrapper_declaration
    parameters = [
        re.sub(r"\s*\\\\.*$", "", item).strip()
        for item in split_top_level_args(definition.group(2))
    ]
    return (
        parameter_index < len(parameters)
        and target_expression.strip() == parameters[parameter_index]
    )


def persistence_mutation_targets(
    text: str,
    schema_modules: set[str],
    schema_tables: dict[str, str],
) -> PersistenceMutationTargets:
    """Return all statically attributable Ecto/SQL writes, failing closed."""

    aliases = module_aliases(text)
    bindings = static_module_bindings(text)
    code = elixir_code_only(text)
    schemas: set[str] = set()
    tables: set[str] = set()
    unresolved: set[str] = set()
    wrappers = _local_write_wrappers(text)

    calls = [
        *(
            (
                call,
                resolve_module_reference(call.group("receiver"), aliases),
            )
            for call in WRITE_CALL_RE.finditer(code)
        ),
        *(
            (
                call,
                bindings.get(call.group("receiver"))
                or (
                    "CommsCore.Repo"
                    if call.group("receiver").lstrip("@") == "repo"
                    else None
                ),
            )
            for call in BOUND_WRITE_CALL_RE.finditer(code)
        ),
    ]
    for call, resolved_receiver in calls:
        if resolved_receiver not in {"CommsCore.Repo", "Ecto.Multi"}:
            continue
        parsed = balanced_call_arguments(text, call.end() - 1)
        if not parsed:
            continue
        arguments_text, _ = parsed
        arguments = split_top_level_args(arguments_text)
        pipeline_input = pipeline_input_before(text, call.start())
        target_expression = _write_target_expression(
            "Repo" if resolved_receiver == "CommsCore.Repo" else "Ecto.Multi",
            call.group("operation"),
            arguments,
            pipeline_input,
        )
        if not target_expression:
            unresolved.add(
                f"{resolved_receiver}.{call.group('operation')} has no write target"
            )
            continue
        target = _resolve_persistence_target(
            target_expression,
            aliases=aliases,
            schema_modules=schema_modules,
            schema_tables=schema_tables,
            source=text,
            before=call.start(),
        )
        if target:
            kind, name = target
            (schemas if kind == "schema" else tables).add(name)
        elif not _wrapper_target_parameter(
                text,
                call.start(),
                target_expression,
                wrappers,
            ):
            unresolved.add(
                f"{resolved_receiver}.{call.group('operation')} target "
                f"{target_expression.strip()[:80]!r} cannot be attributed"
            )

    for wrapper, (parameter_index, wrapper_operation) in wrappers.items():
        for call in re.finditer(rf"\b{re.escape(wrapper)}\s*\(", code):
            line_start = text.rfind("\n", 0, call.start()) + 1
            declaration_prefix = text[line_start : call.start()]
            if re.match(
                r"\s*(?:defp?|defdelegate)\s*$",
                declaration_prefix,
            ):
                continue
            parsed = balanced_call_arguments(text, call.end() - 1)
            if not parsed:
                continue
            arguments_text, _ = parsed
            arguments = split_top_level_args(arguments_text)
            pipeline_input = pipeline_input_before(text, call.start())
            if pipeline_input is not None and parameter_index == 0:
                target_expression = pipeline_input
            elif (
                pipeline_input is not None
                and len(arguments) > parameter_index - 1
            ):
                target_expression = arguments[parameter_index - 1]
            elif pipeline_input is None and len(arguments) > parameter_index:
                target_expression = arguments[parameter_index]
            else:
                target_expression = None
            if not target_expression:
                continue
            target = _resolve_persistence_target(
                target_expression,
                aliases=aliases,
                schema_modules=schema_modules,
                schema_tables=schema_tables,
                source=text,
                before=call.start(),
            )
            if target:
                kind, name = target
                (schemas if kind == "schema" else tables).add(name)
            else:
                unresolved.add(
                    f"local write wrapper {wrapper} target "
                    f"{target_expression.strip()[:80]!r} cannot be attributed"
                )

    protected_write_modules = {
        "CommsCore.Repo": set(REPO_MUTATION_FUNCTIONS),
        "Ecto.Multi": set(ECTO_MULTI_MUTATION_FUNCTIONS),
    }
    unresolved.update(
        module_function_evasions(
            text,
            protected_write_modules,
            reject_unknown_dynamic_target=False,
        )
    )
    unresolved.update(
        f"delegates {module}.{operation}/{arity} without an attributable write target"
        for module, operation, arity in delegated_function_calls(text)
        if module in protected_write_modules
        and operation in protected_write_modules[module]
    )

    raw_tables, raw_unresolved = raw_sql_mutation_targets(text)
    tables.update(raw_tables)
    unresolved.update(raw_unresolved)
    return PersistenceMutationTargets(
        frozenset(schemas),
        frozenset(tables),
        frozenset(unresolved),
    )


def schema_write_references(text: str, schema_modules: set[str]) -> set[str]:
    """Backward-compatible schema-only view used by focused unit tests."""

    return set(
        persistence_mutation_targets(text, schema_modules, {}).schemas
    )


MIGRATION_TARGET_CALL_RE = re.compile(
    r"\b(?P<kind>table|index|unique_index|constraint|references)\s*\("
)
MIGRATION_EXECUTE_RE = re.compile(r"\bexecute\s*\(")
MIGRATION_PARENLESS_EXECUTE_RE = re.compile(
    r"(?m)(?<![A-Za-z0-9_.])execute(?!\s*\()(?=\s)"
)
SQL_REFERENCE_RE = re.compile(
    r"\bREFERENCES\s+"
    r'(?:(?:"?[A-Za-z_][A-Za-z0-9_]*"?)[.])?'
    r'"?(?P<table>[A-Za-z_][A-Za-z0-9_]*)"?',
    re.IGNORECASE,
)
SQL_DROP_INDEX_RE = re.compile(
    r"\bDROP\s+INDEX(?:\s+CONCURRENTLY)?(?:\s+IF\s+EXISTS)?\s+"
    r'(?:(?:"?[A-Za-z_][A-Za-z0-9_]*"?)[.])?'
    r'"?(?P<index>[A-Za-z_][A-Za-z0-9_]*)"?',
    re.IGNORECASE,
)
SQL_LOCK_TABLE_RE = re.compile(
    r"\bLOCK\s+TABLE\s+(?P<tables>[\s\S]*?)\s+IN\s+"
    r"(?:ACCESS\s+SHARE|ROW\s+SHARE|ROW\s+EXCLUSIVE|SHARE\s+UPDATE\s+EXCLUSIVE|"
    r"SHARE|SHARE\s+ROW\s+EXCLUSIVE|EXCLUSIVE|ACCESS\s+EXCLUSIVE)\s+MODE\b",
    re.IGNORECASE,
)
MIGRATION_EXCEPTION_RULES = frozenset(
    {"mixed_owner_migration", "unresolved_migration_target"}
)


def _migration_sql_targets(
    sql: str,
    known_tables: set[str],
) -> tuple[set[str], set[str], bool]:
    mutated, _raw_unresolved = _raw_sql_targets(sql)
    unresolved = False
    referenced = {
        match.group("table") for match in SQL_REFERENCE_RE.finditer(sql)
    }
    for match in SQL_DROP_INDEX_RE.finditer(sql):
        index = match.group("index")
        candidates = [
            table
            for table in known_tables
            if index == table or index.startswith(f"{table}_")
        ]
        if candidates:
            mutated.add(max(candidates, key=len))
        else:
            unresolved = True
    for lock in SQL_LOCK_TABLE_RE.finditer(sql):
        lock_targets = {
            token.strip().strip('"')
            for token in lock.group("tables").split(",")
            if re.fullmatch(
                r'\s*"?[A-Za-z_][A-Za-z0-9_]*"?\s*',
                token,
            )
        }
        if lock_targets:
            mutated.update(lock_targets)
        else:
            unresolved = True
    if RAW_SQL_TABLE_MUTATION_RE.search(sql) and not mutated:
        unresolved = True
    return mutated, referenced, unresolved


def _parenless_migration_execute_arguments(
    text: str,
    start: int,
) -> list[str]:
    """Read execute/1 or execute/2 arguments, including heredoc literals."""

    index = start
    while index < len(text) and text[index].isspace():
        index += 1
    if text.startswith('"""', index):
        end = text.find('"""', index + 3)
        if end == -1:
            return [text[index:]]
        expressions = [text[index : end + 3]]
        next_index = end + 3
        while next_index < len(text) and text[next_index].isspace():
            next_index += 1
        if next_index < len(text) and text[next_index] == ",":
            expressions.extend(
                _parenless_migration_execute_arguments(text, next_index + 1)
            )
        return expressions[:2]
    arguments = parenless_call_arguments(text, start)
    return split_top_level_args(arguments)


def migration_targets(text: str, known_tables: set[str]) -> MigrationTargets:
    """Attribute Ecto and static-SQL migration operations to declared tables."""

    code = elixir_code_only(text)
    mutated: set[str] = set()
    referenced: set[str] = set()
    unresolved: set[str] = set()
    for call in MIGRATION_TARGET_CALL_RE.finditer(code):
        parsed = balanced_call_arguments(text, call.end() - 1)
        if not parsed:
            unresolved.add(f"cannot parse {call.group('kind')} migration operation")
            continue
        arguments = split_top_level_args(parsed[0])
        target = _literal_table_name(text, arguments[0]) if arguments else None
        if not target:
            unresolved.add(
                f"{call.group('kind')} migration target cannot be attributed"
            )
            continue
        if call.group("kind") == "references":
            referenced.add(target)
        else:
            mutated.add(target)

    for call in MIGRATION_EXECUTE_RE.finditer(code):
        parsed = balanced_call_arguments(text, call.end() - 1)
        if not parsed:
            unresolved.add("cannot parse execute migration operation")
            continue
        arguments = split_top_level_args(parsed[0])
        if not arguments:
            unresolved.add("execute migration operation has no SQL argument")
            continue
        for expression in arguments[:2]:
            sql = _static_sql_expression(text, expression)
            if sql is None:
                unresolved.add("execute migration operation uses dynamic SQL")
                continue
            sql_mutated, sql_referenced, sql_unresolved = _migration_sql_targets(
                sql,
                known_tables,
            )
            mutated.update(sql_mutated)
            referenced.update(sql_referenced)
            if sql_unresolved:
                unresolved.add("static SQL migration target cannot be attributed")

    for call in MIGRATION_PARENLESS_EXECUTE_RE.finditer(code):
        line_start = text.rfind("\n", 0, call.start()) + 1
        if re.search(r"\bdef(?:p|macro|macrop)?\s*$", text[line_start : call.start()]):
            continue
        arguments = _parenless_migration_execute_arguments(text, call.end())
        if not arguments:
            unresolved.add("parenless execute migration operation has no SQL argument")
            continue
        for expression in arguments[:2]:
            sql = _static_sql_expression(text, expression)
            if sql is None:
                unresolved.add("parenless execute migration operation uses dynamic SQL")
                continue
            sql_mutated, sql_referenced, sql_unresolved = _migration_sql_targets(
                sql,
                known_tables,
            )
            mutated.update(sql_mutated)
            referenced.update(sql_referenced)
            if sql_unresolved:
                unresolved.add(
                    "parenless static SQL migration target cannot be attributed"
                )

    return MigrationTargets(
        frozenset(mutated),
        frozenset(referenced),
        frozenset(unresolved),
    )


def public_typespec_blocks(text: str) -> list[str]:
    """Return only typespecs that form part of a module's public API."""

    code = elixir_code_only(text)
    blocks: list[str] = []
    public_type_re = re.compile(
        r"(?m)^[ \t]*@(?:callback|macrocallback|type|opaque)\b"
        r"[\s\S]*?(?=^[ \t]*(?:@|def|defp)\b|\Z)"
    )
    blocks.extend(match.group(0) for match in public_type_re.finditer(code))

    spec_re = re.compile(
        r"(?m)^[ \t]*@spec\s+(?P<function>[a-z_][A-Za-z0-9_!?]*)\b"
        r"[\s\S]*?(?=^[ \t]*(?:@|def|defp)\b|\Z)"
    )
    for match in spec_re.finditer(code):
        following_definition = re.search(
            rf"(?m)^[ \t]*(?P<kind>defp?)\s+"
            rf"{re.escape(match.group('function'))}\b",
            code[match.end() :],
        )
        if following_definition and following_definition.group("kind") == "def":
            blocks.append(match.group(0))
    return blocks


def public_spec_operations(text: str) -> set[tuple[str, int]]:
    """Return public function name/arities that have explicit specs."""

    code = elixir_code_only(text)
    operations: set[tuple[str, int]] = set()
    for spec in re.finditer(
        r"(?m)^[ \t]*@spec\s+(?P<function>[a-z_][A-Za-z0-9_!?]*)\s*\(",
        code,
    ):
        parsed = balanced_call_arguments(text, spec.end() - 1)
        if not parsed:
            continue
        following_definition = re.search(
            rf"(?m)^[ \t]*(?P<kind>defp?)\s+"
            rf"{re.escape(spec.group('function'))}\b",
            code[parsed[1] :],
        )
        if following_definition and following_definition.group("kind") == "def":
            operations.add(
                (
                    spec.group("function"),
                    len(split_top_level_args(parsed[0])),
                )
            )
    return operations


def strongly_connected_components(graph: dict[str, set[str]]) -> list[list[str]]:
    index = 0
    stack: list[str] = []
    indices: dict[str, int] = {}
    lowlinks: dict[str, int] = {}
    on_stack: set[str] = set()
    components: list[list[str]] = []

    def visit(node: str) -> None:
        nonlocal index
        indices[node] = lowlinks[node] = index
        index += 1
        stack.append(node)
        on_stack.add(node)
        for target in graph.get(node, set()):
            if target not in indices:
                visit(target)
                lowlinks[node] = min(lowlinks[node], lowlinks[target])
            elif target in on_stack:
                lowlinks[node] = min(lowlinks[node], indices[target])
        if lowlinks[node] == indices[node]:
            component: list[str] = []
            while True:
                member = stack.pop()
                on_stack.remove(member)
                component.append(member)
                if member == node:
                    break
            if len(component) > 1:
                components.append(sorted(component))

    for node in sorted(graph):
        if node not in indices:
            visit(node)
    return sorted(components)


def context_cycle_violations(
    graph: dict[str, Iterable[str]],
    rule: str,
) -> list[Violation]:
    normalized = {source: set(targets) for source, targets in graph.items()}
    violations: list[Violation] = []
    for component in strongly_connected_components(normalized):
        members = set(component)
        internal_edges = sorted(
            f"{source}->{target}"
            for source in component
            for target in normalized.get(source, set())
            if target in members
        )
        violations.append(
            Violation(
                rule,
                MANIFEST_PATH.as_posix(),
                f"members: {', '.join(component)}; edges: {', '.join(internal_edges)}",
            )
        )
    return violations


def analyze_context_boundaries(root: Path, manifest: dict) -> list[Violation]:
    violations: set[Violation] = set()
    contexts = manifest.get("contexts", {})
    tables = manifest.get("tables", {})
    if not isinstance(contexts, dict):
        return [
            Violation(
                "invalid_context_declaration",
                MANIFEST_PATH.as_posix(),
                "contexts must be a mapping",
            )
        ]
    if not isinstance(tables, dict):
        return [
            Violation(
                "invalid_table_declaration",
                MANIFEST_PATH.as_posix(),
                "tables must be a mapping",
            )
        ]

    for context_name, context in sorted(contexts.items()):
        if not isinstance(context, dict):
            violations.add(
                Violation(
                    "invalid_context_declaration",
                    MANIFEST_PATH.as_posix(),
                    f"context {context_name} must be a mapping",
                )
            )
            continue
        for field_name in (
            "public_facades",
            "public_contracts",
            "owned_modules",
            "internal_namespaces",
            "allowed_dependencies",
        ):
            values = context.get(field_name, [])
            if (
                not isinstance(values, list)
                or not all(isinstance(value, str) and value for value in values)
                or len(values) != len(set(values))
            ):
                violations.add(
                    Violation(
                        "invalid_context_declaration",
                        MANIFEST_PATH.as_posix(),
                        f"context {context_name} {field_name} must be a list "
                        "of unique non-empty strings",
                    )
                )
        unknown_dependencies = sorted(
            set(context.get("allowed_dependencies", [])) - set(contexts)
        )
        if unknown_dependencies:
            violations.add(
                Violation(
                    "invalid_context_declaration",
                    MANIFEST_PATH.as_posix(),
                    f"context {context_name} declares unknown dependencies "
                    f"{', '.join(unknown_dependencies)}",
                )
            )
        if context.get("graph_scope", "included") not in {"included", "excluded"}:
            violations.add(
                Violation(
                    "invalid_context_declaration",
                    MANIFEST_PATH.as_posix(),
                    f"context {context_name} graph_scope must be included or excluded",
                )
            )

    dependency_graphs = manifest.get("dependency_graphs")
    if dependency_graphs is not None:
        if not isinstance(dependency_graphs, dict):
            violations.add(
                Violation(
                    "invalid_dependency_graph_declaration",
                    MANIFEST_PATH.as_posix(),
                    "dependency_graphs must be a mapping",
                )
            )
        else:
            required_graph_fields = {
                "compiled": {
                    "source",
                    "edge_direction",
                    "includes",
                    "excludes",
                    "cycle_policy",
                },
                "runtime": {"source", "edge_direction", "includes", "cycle_policy"},
                "combined": {"source", "edge_direction", "includes", "cycle_policy"},
            }
            for graph_name, required_fields in required_graph_fields.items():
                graph_declaration = dependency_graphs.get(graph_name)
                if not isinstance(graph_declaration, dict):
                    violations.add(
                        Violation(
                            "invalid_dependency_graph_declaration",
                            MANIFEST_PATH.as_posix(),
                            f"dependency_graphs.{graph_name} must be a mapping",
                        )
                    )
                    continue
                missing_or_empty = sorted(
                    field
                    for field in required_fields
                    if not isinstance(graph_declaration.get(field), str)
                    or not graph_declaration[field].strip()
                )
                if missing_or_empty:
                    violations.add(
                        Violation(
                            "invalid_dependency_graph_declaration",
                            MANIFEST_PATH.as_posix(),
                            f"dependency_graphs.{graph_name} has missing or empty "
                            f"fields {', '.join(missing_or_empty)}",
                        )
                    )

    schemas = discover_schemas(root)
    schema_owners = schema_owner_map(tables)
    schema_tables = {
        declaration.get("canonical_schema"): table
        for table, declaration in tables.items()
        if declaration.get("canonical_schema")
        and not declaration.get("external_schema")
    }

    for path in production_sources(root / "apps/comms_core"):
        text = path.read_text(encoding="utf-8")
        declared_modules = core_module_declarations(text)
        schema_source, unresolved_schema_source = ecto_schema_source(text)
        if unresolved_schema_source:
            violations.add(
                Violation(
                    "invalid_table_declaration",
                    relative(path, root),
                    "Ecto schema source must resolve to a literal table or "
                    "a literal module attribute",
                )
            )
        if len(declared_modules) > 1:
            declared_tables = [schema_source] if schema_source else []
            schema_detail = (
                f"; schema tables: {', '.join(declared_tables)}"
                if declared_tables
                else ""
            )
            violations.add(
                Violation(
                    "multiple_context_modules_file",
                    relative(path, root),
                    "production comms_core files must declare exactly one "
                    f"CommsCore module; modules: {', '.join(declared_modules)}"
                    f"{schema_detail}",
                )
            )

    raw_retired_modules = manifest.get("retired_modules", [])
    if (
        not isinstance(raw_retired_modules, list)
        or not all(
            isinstance(module, str)
            and re.fullmatch(r"CommsCore(?:\.[A-Z][A-Za-z0-9_]*)+", module)
            for module in raw_retired_modules
        )
        or raw_retired_modules != sorted(set(raw_retired_modules))
    ):
        violations.add(
            Violation(
                "invalid_context_declaration",
                MANIFEST_PATH.as_posix(),
                "retired_modules must be a sorted list of unique CommsCore "
                "module namespace names",
            )
        )
    retired_modules = {
        module
        for module in raw_retired_modules
        if isinstance(module, str)
        and re.fullmatch(r"CommsCore(?:\.[A-Z][A-Za-z0-9_]*)+", module)
    }
    for app_dir in sorted((root / "apps").iterdir()):
        if not app_dir.is_dir():
            continue
        for path in production_sources(app_dir):
            text = path.read_text(encoding="utf-8")
            declared_modules = core_module_declarations(text)
            references = core_module_references(text)
            observed_modules = set(references) | set(declared_modules)
            used = {
                retired
                for retired in retired_modules
                if any(
                    module_in_namespace(observed, retired)
                    for observed in observed_modules
                )
            }
            for retired in sorted(used):
                violations.add(
                    Violation(
                        "retired_context_module",
                        relative(path, root),
                        f"production code references retired context namespace {retired}",
                    )
                )
    config_root = root / "config"
    if config_root.is_dir():
        for path in sorted((*config_root.rglob("*.ex"), *config_root.rglob("*.exs"))):
            references = core_module_references(path.read_text(encoding="utf-8"))
            used = {
                retired
                for retired in retired_modules
                if any(
                    module_in_namespace(reference, retired) for reference in references
                )
            }
            for retired in sorted(used):
                violations.add(
                    Violation(
                        "retired_context_module",
                        relative(path, root),
                        f"configuration references retired context namespace {retired}",
                    )
                )

    raw_retired_bindings = manifest.get("retired_runtime_bindings", [])
    retired_bindings: set[tuple[str, str]] = set()
    valid_retired_binding_shape = isinstance(raw_retired_bindings, list)
    normalized_retired_bindings: list[tuple[str, str]] = []
    if valid_retired_binding_shape:
        for declaration in raw_retired_bindings:
            if (
                not isinstance(declaration, dict)
                or set(declaration) != {"application", "key"}
                or not isinstance(declaration.get("application"), str)
                or not re.fullmatch(r"[a-z][a-z0-9_]*", declaration["application"])
                or not isinstance(declaration.get("key"), str)
                or not re.fullmatch(r"[a-z][a-z0-9_]*", declaration["key"])
            ):
                valid_retired_binding_shape = False
                continue
            normalized_retired_bindings.append(
                (declaration["application"], declaration["key"])
            )
    if not valid_retired_binding_shape or normalized_retired_bindings != sorted(
        set(normalized_retired_bindings)
    ):
        violations.add(
            Violation(
                "invalid_context_declaration",
                MANIFEST_PATH.as_posix(),
                "retired_runtime_bindings must be a sorted list of unique "
                "{application, key} mappings",
            )
        )
    retired_bindings.update(normalized_retired_bindings)

    configured_binding_paths = configured_binding_key_paths(root)
    for binding in sorted(retired_bindings):
        application, key = binding
        for path_key in sorted(configured_binding_paths.get(binding, set())):
            violations.add(
                Violation(
                    "retired_runtime_binding",
                    path_key,
                    f"configuration defines retired runtime binding "
                    f"{application}.{key}",
                )
            )
    for source_module, source_path in released_module_sources(root).items():
        source_bindings, _unresolved = application_binding_references(
            source_path.read_text(encoding="utf-8")
        )
        for application, key in sorted(retired_bindings.intersection(source_bindings)):
            violations.add(
                Violation(
                    "retired_runtime_binding",
                    relative(source_path, root),
                    f"{source_module} references retired runtime binding "
                    f"{application}.{key}",
                )
            )

    for table, declarations in sorted(schemas.items()):
        if table not in tables:
            for module, path in declarations:
                violations.add(
                    Violation(
                        "unowned_table", path, f"{module} maps undeclared table {table}"
                    )
                )
            continue
        if tables[table].get("external_schema"):
            violations.add(
                Violation(
                    "invalid_table_declaration",
                    declarations[0][1],
                    f"external table {table} must not have a local Ecto schema mapping",
                )
            )
            continue
        canonical = tables[table].get("canonical_schema")
        modules = sorted(module for module, _ in declarations)
        if len(modules) > 1:
            violations.add(
                Violation(
                    "duplicate_table_mapping",
                    declarations[0][1],
                    f"table {table} is mapped by {', '.join(modules)}; canonical is {canonical}",
                )
            )
        if canonical not in modules:
            violations.add(
                Violation(
                    "canonical_schema_missing",
                    MANIFEST_PATH.as_posix(),
                    f"table {table} declares missing canonical schema {canonical}",
                )
            )

    for table, declaration in sorted(tables.items()):
        external = declaration.get("external_schema") is True
        canonical_schema = declaration.get("canonical_schema")
        canonical_accessor = declaration.get("canonical_accessor")
        if external:
            declarations = sum(
                bool(value) for value in (canonical_schema, canonical_accessor)
            )
            if declarations != 1:
                violations.add(
                    Violation(
                        "invalid_table_declaration",
                        MANIFEST_PATH.as_posix(),
                        f"external table {table} must declare exactly one of "
                        "canonical_schema or canonical_accessor",
                    )
                )
            for field_name, value in (
                ("canonical_schema", canonical_schema),
                ("canonical_accessor", canonical_accessor),
            ):
                if value is not None and (
                    not isinstance(value, str) or not value.strip()
                ):
                    violations.add(
                        Violation(
                            "invalid_table_declaration",
                            MANIFEST_PATH.as_posix(),
                            f"external table {table} has invalid {field_name}",
                        )
                    )
        elif canonical_accessor is not None:
            violations.add(
                Violation(
                    "invalid_table_declaration",
                    MANIFEST_PATH.as_posix(),
                    f"owned table {table} may not declare canonical_accessor",
                )
            )
        if table not in schemas and not external:
            violations.add(
                Violation(
                    "declared_table_missing",
                    MANIFEST_PATH.as_posix(),
                    f"table {table} has no discovered Ecto schema",
                )
            )
        if declaration.get("owner") not in contexts:
            violations.add(
                Violation(
                    "unknown_table_owner",
                    MANIFEST_PATH.as_posix(),
                    f"table {table} has unknown owner {declaration.get('owner')}",
                )
            )

    schema_modules = {
        module for declarations in schemas.values() for module, _ in declarations
    }
    embedded_schema_modules = set(discover_embedded_schemas(root))
    ecto_contract_modules = schema_modules | embedded_schema_modules
    module_sources: dict[str, Path] = {}
    for path in production_sources(root / "apps/comms_core"):
        text = path.read_text(encoding="utf-8")
        for module in core_module_declarations(text):
            module_sources[module] = path

    for module, path in sorted(module_sources.items()):
        candidates = declared_module_owner_candidates(module, contexts, schema_owners)
        if not candidates:
            violations.add(
                Violation(
                    "unclassified_core_module",
                    relative(path, root),
                    f"production module {module} has no declared context owner",
                )
            )
        elif len(candidates) > 1:
            violations.add(
                Violation(
                    "ambiguous_context_owner",
                    relative(path, root),
                    f"production module {module} resolves to multiple context owners "
                    f"{', '.join(sorted(candidates))}",
                )
            )

    runtime_violations, runtime_graph = _runtime_collaboration_violations(
        root,
        manifest,
        contexts,
        schema_owners,
        ecto_contract_modules,
        module_sources,
    )
    violations.update(runtime_violations)
    all_module_sources = released_module_sources(root)
    technical_violations, approved_technical_interfaces = (
        _technical_interface_violations(
            root,
            manifest,
            contexts,
            schema_owners,
            ecto_contract_modules,
            all_module_sources,
        )
    )
    violations.update(technical_violations)

    read_model_policies: dict[str, dict[str, set[str] | str]] = {}
    read_model_contexts: set[str] = {
        context_name
        for context_name, context in contexts.items()
        if context.get("kind") == "business_read_model"
    }
    seen_read_model_ids: set[str] = set()
    seen_read_model_modules: set[str] = set()
    read_model_exceptions = manifest.get("read_model_exceptions", [])
    if not isinstance(read_model_exceptions, list):
        violations.add(
            Violation(
                "invalid_read_model_exception",
                MANIFEST_PATH.as_posix(),
                "read_model_exceptions must be a list",
            )
        )
        read_model_exceptions = []

    for index, exception in enumerate(read_model_exceptions):
        label = f"read_model_exceptions[{index}]"
        if not isinstance(exception, dict):
            violations.add(
                Violation(
                    "invalid_read_model_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label} must be a mapping",
                )
            )
            continue

        exception_id = exception.get("id")
        module = exception.get("module")
        mode = exception.get("mode")
        owners = exception.get("owners")
        access = exception.get("access")
        condition = exception.get("condition")
        valid = True

        if not isinstance(exception_id, str) or not exception_id.strip():
            violations.add(
                Violation(
                    "invalid_read_model_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label} must declare a non-empty id",
                )
            )
            valid = False
        elif exception_id in seen_read_model_ids:
            violations.add(
                Violation(
                    "invalid_read_model_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label} duplicates id {exception_id}",
                )
            )
            valid = False
        else:
            seen_read_model_ids.add(exception_id)

        if not isinstance(module, str) or not module.strip():
            violations.add(
                Violation(
                    "invalid_read_model_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label} must declare one explicit module",
                )
            )
            valid = False
        elif module in seen_read_model_modules:
            violations.add(
                Violation(
                    "invalid_read_model_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label} duplicates module {module}",
                )
            )
            valid = False
        else:
            seen_read_model_modules.add(module)

        if mode != "read_only":
            violations.add(
                Violation(
                    "invalid_read_model_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label} mode must be read_only",
                )
            )
            valid = False

        if not isinstance(condition, str) or not condition.strip():
            violations.add(
                Violation(
                    "invalid_read_model_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label} must declare a non-empty condition",
                )
            )
            valid = False

        if (
            not isinstance(owners, list)
            or not owners
            or not all(isinstance(owner, str) and owner for owner in owners)
            or len(set(owners)) != len(owners)
        ):
            violations.add(
                Violation(
                    "invalid_read_model_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label} owners must be a non-empty list of unique context names",
                )
            )
            owners = []
            valid = False

        if not isinstance(access, dict) or set(access) != {
            "public_contracts",
            "public_queries",
            "source_tables",
        }:
            violations.add(
                Violation(
                    "invalid_read_model_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label} access must contain exactly public_contracts, "
                    "public_queries, and source_tables",
                )
            )
            access = {
                "public_contracts": [],
                "public_queries": [],
                "source_tables": [],
            }
            valid = False

        public_contracts = access.get("public_contracts", [])
        public_queries = access.get("public_queries", [])
        source_tables = access.get("source_tables", [])
        for access_name, values in (
            ("public_contracts", public_contracts),
            ("public_queries", public_queries),
            ("source_tables", source_tables),
        ):
            if (
                not isinstance(values, list)
                or not all(isinstance(value, str) and value for value in values)
                or len(set(values)) != len(values)
            ):
                violations.add(
                    Violation(
                        "invalid_read_model_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{label} access.{access_name} must be a list of unique names",
                    )
                )
                valid = False
                if access_name == "public_contracts":
                    public_contracts = []
                elif access_name == "public_queries":
                    public_queries = []
                else:
                    source_tables = []

        if not public_contracts and not public_queries and not source_tables:
            violations.add(
                Violation(
                    "invalid_read_model_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label} must grant at least one public contract, public query, "
                    "or source table",
                )
            )
            valid = False

        if not isinstance(module, str):
            continue
        source_owner = declared_module_owner(module, contexts, schema_owners)
        if module not in module_sources:
            violations.add(
                Violation(
                    "invalid_read_model_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label} references missing module {module}",
                )
            )
            valid = False
        source_kind = (
            contexts.get(source_owner, {}).get("kind") if source_owner else None
        )
        if not source_owner or source_kind not in {"business", "business_read_model"}:
            violations.add(
                Violation(
                    "invalid_read_model_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label} module {module} must belong to a business or business_read_model context",
                )
            )
            valid = False
        else:
            allowed = set(contexts[source_owner].get("allowed_dependencies", []))
            unknown_owners = sorted(set(owners) - set(contexts))
            undeclared_owners = sorted(set(owners) - allowed)
            if unknown_owners:
                violations.add(
                    Violation(
                        "invalid_read_model_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{label} references unknown owners {', '.join(unknown_owners)}",
                    )
                )
                valid = False
            if source_kind != "business_read_model" and source_tables:
                violations.add(
                    Violation(
                        "invalid_read_model_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{label} business-context exceptions may use public contracts "
                        "and public queries only",
                    )
                )
                valid = False
            if undeclared_owners:
                violations.add(
                    Violation(
                        "invalid_read_model_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{label} owners are not allowed dependencies: {', '.join(undeclared_owners)}",
                    )
                )
                valid = False

        declared_contract_owners = {
            contract: context_name
            for context_name, context in contexts.items()
            for contract in context.get("public_contracts", [])
        }
        for contract in public_contracts:
            contract_owner = declared_contract_owners.get(contract)
            if contract_owner not in set(owners):
                violations.add(
                    Violation(
                        "invalid_read_model_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{label} contract {contract} is not published by an allowed owner",
                    )
                )
                valid = False
        parsed_public_queries: set[tuple[str, str, int]] = set()
        for query in public_queries:
            match = PUBLIC_QUERY_RE.fullmatch(query)
            if not match:
                violations.add(
                    Violation(
                        "invalid_read_model_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{label} public query {query} must name "
                        "CommsCore.OwnerFacade.function/arity",
                    )
                )
                valid = False
                continue
            query_module, query_function, query_arity_text = match.groups()
            query_arity = int(query_arity_text)
            query_owner = module_owner(query_module, contexts)
            declared_facades = (
                set(contexts[query_owner].get("public_facades", []))
                if query_owner in contexts
                else set()
            )
            if query_owner not in set(owners) or query_module not in declared_facades:
                violations.add(
                    Violation(
                        "invalid_read_model_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{label} public query {query} is not on a facade "
                        "published by an allowed owner",
                    )
                )
                valid = False
                continue
            query_source = module_sources.get(query_module)
            if query_source is None or not module_defines_function(
                query_source, query_function, query_arity
            ):
                violations.add(
                    Violation(
                        "invalid_read_model_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{label} public query {query} is not defined by its facade",
                    )
                )
                valid = False
                continue
            parsed_public_queries.add((query_module, query_function, query_arity))
        for table in source_tables:
            declaration = tables.get(table)
            if not declaration or declaration.get("owner") not in set(owners):
                violations.add(
                    Violation(
                        "invalid_read_model_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{label} table {table} is not owned by an allowed owner",
                    )
                )
                valid = False

        if valid:
            read_model_policies[module] = {
                "owner": source_owner,
                "owners": set(owners),
                "public_contracts": set(public_contracts),
                "public_queries": {
                    f"{query_module}.{query_function}/{query_arity}"
                    for query_module, query_function, query_arity in parsed_public_queries
                },
                "public_facades": {
                    query_module
                    for query_module, _query_function, _query_arity in parsed_public_queries
                },
                "owner_facades": {
                    facade
                    for owner in owners
                    for facade in contexts[owner].get("public_facades", [])
                },
                "source_tables": set(source_tables),
                "source_schemas": {
                    tables[table]["canonical_schema"]
                    for table in source_tables
                    if tables[table].get("canonical_schema")
                },
            }

    required_public_specs: dict[str, set[tuple[str, int]]] = {}
    for declaration in manifest.get("technical_interfaces", []):
        if not isinstance(declaration, dict):
            continue
        interface = declaration.get("interface")
        if not isinstance(interface, str):
            continue
        for operation in declaration.get("operations", []):
            if (
                isinstance(operation, dict)
                and isinstance(operation.get("name"), str)
                and isinstance(operation.get("arity"), int)
            ):
                required_public_specs.setdefault(interface, set()).add(
                    (operation["name"], operation["arity"])
                )
    for policy in read_model_policies.values():
        for query in policy["public_queries"]:
            match = PUBLIC_QUERY_RE.fullmatch(query)
            if match:
                required_public_specs.setdefault(match.group(1), set()).add(
                    (match.group(2), int(match.group(3)))
                )
    for module, required_operations in sorted(required_public_specs.items()):
        source = module_sources.get(module)
        if source is None:
            continue
        declared_specs = public_spec_operations(source.read_text(encoding="utf-8"))
        for function, arity in sorted(required_operations - declared_specs):
            violations.add(
                Violation(
                    "public_operation_missing_spec",
                    relative(source, root),
                    f"declared public operation {module}.{function}/{arity} "
                    "must have an explicit public Ecto-free @spec",
                )
            )

    for context_name, context in sorted(contexts.items()):
        for facade in context.get("public_facades", []):
            source = module_sources.get(facade)
            if source is None:
                violations.add(
                    Violation(
                        "public_facade_missing",
                        MANIFEST_PATH.as_posix(),
                        f"{context_name} declares missing public facade {facade}",
                    )
                )
            elif facade in ecto_contract_modules:
                violations.add(
                    Violation(
                        "public_facade_is_schema",
                        relative(source, root),
                        f"declared public facade {facade} is an Ecto schema",
                    )
                )
        for contract in context.get("public_contracts", []):
            source = module_sources.get(contract)
            if source is None:
                violations.add(
                    Violation(
                        "public_contract_missing",
                        MANIFEST_PATH.as_posix(),
                        f"{context_name} declares missing public contract {contract}",
                    )
                )
            elif contract in ecto_contract_modules:
                violations.add(
                    Violation(
                        "public_contract_is_schema",
                        relative(source, root),
                        f"declared public contract {contract} is an Ecto schema",
                    )
                )

    schema_access_policies = {}
    for declaration in tables.values():
        canonical_schema = declaration.get("canonical_schema")
        owner = declaration.get("owner")
        if (
            canonical_schema not in schema_modules
            or not canonical_schema.startswith("CommsCore.")
            or owner not in contexts
        ):
            continue
        explicit_namespaces = declaration.get("access_namespaces")
        namespaces = (
            explicit_namespaces
            if isinstance(explicit_namespaces, list)
            else contexts[owner].get("internal_namespaces", [])
        )
        schema_access_policies[canonical_schema] = {
            "owner": owner,
            "namespaces": namespaces,
            "modules": {canonical_schema},
        }
    public_core_modules = {
        module
        for context in contexts.values()
        if isinstance(context, dict)
        for field in ("public_facades", "public_contracts")
        for module in context.get(field, [])
    }
    approved_adapter_modules = public_core_modules | approved_technical_interfaces
    for app in ("comms_web", "comms_workers", "comms_integrations"):
        for path in production_sources(root / f"apps/{app}"):
            text = path.read_text(encoding="utf-8")
            references = core_module_references(text)
            resolved_references = {
                resolve_module_reference(token, module_aliases(text))
                for token in re.findall(
                    rf"(?<![A-Za-z0-9_])({GENERIC_MODULE_NAME})",
                    elixir_code_only(text),
                )
            }
            if "Ecto.Changeset" in resolved_references:
                violations.add(
                    Violation(
                        "adapter_changeset_import",
                        relative(path, root),
                        "adapter references Ecto.Changeset instead of a stable validation contract",
                    )
                )
            for schema_module in sorted(
                ecto_contract_modules.intersection(references)
            ):
                violations.add(
                    Violation(
                        "adapter_schema_import",
                        relative(path, root),
                        f"adapter references internal Ecto schema {schema_module}",
                    )
                )
            for internal_module in sorted(
                references.intersection(module_sources)
                - ecto_contract_modules
                - approved_adapter_modules
            ):
                violations.add(
                    Violation(
                        "adapter_internal_module_import",
                        relative(path, root),
                        f"adapter references owner-internal module {internal_module}",
                    )
                )

    scoped_read_policies: dict[str, list[dict[str, set[str] | str]]] = {}
    for policy in read_model_policies.values():
        scoped_read_policies.setdefault(policy["owner"], []).append(policy)

    included_graph_contexts = graph_contexts(contexts)
    graph: dict[str, set[str]] = {name: set() for name in included_graph_contexts}
    namespace_rules = manifest.get("namespace_dependency_rules", [])
    for path in production_sources(root / "apps/comms_core"):
        text = path.read_text(encoding="utf-8")
        source_modules = core_module_declarations(text)
        if not source_modules:
            continue
        if len(source_modules) > 1:
            continue
        source_module = source_modules[0]
        source_owner = declared_module_owner(source_module, contexts, schema_owners)
        if not source_owner:
            continue
        references = core_module_references(text)
        read_model_policy = read_model_policies.get(source_module)
        owner_scoped_policies = scoped_read_policies.get(source_owner, [])
        for target_module in sorted(references):
            target_owner = declared_module_owner(target_module, contexts, schema_owners)
            for scoped_policy in owner_scoped_policies:
                scoped_resources = (
                    scoped_policy["owner_facades"] | scoped_policy["source_schemas"]
                )
                if (
                    target_owner in scoped_policy["owners"]
                    and target_owner != source_owner
                    and target_module in scoped_resources
                    and read_model_policy is not scoped_policy
                ):
                    violations.add(
                        Violation(
                            "read_model_scope_violation",
                            relative(path, root),
                            f"{source_module} bypasses the scoped read-model "
                            f"module to reference {target_module}",
                        )
                    )
        for scoped_policy in owner_scoped_policies:
            if read_model_policy is scoped_policy:
                continue
            for table in scoped_policy["source_tables"]:
                if re.search(rf"\b{re.escape(table)}\b", text):
                    violations.add(
                        Violation(
                            "read_model_scope_violation",
                            relative(path, root),
                            f"{source_module} bypasses the scoped read-model "
                            f"module to access source table {table}",
                        )
                    )
        if read_model_policy:
            allowed_contracts = read_model_policy["public_contracts"]
            allowed_queries = read_model_policy["public_queries"]
            allowed_facades = read_model_policy["public_facades"]
            owner_facades = read_model_policy["owner_facades"]
            allowed_schemas = read_model_policy["source_schemas"]
            allowed_tables = read_model_policy["source_tables"]
            allowed_owners = read_model_policy["owners"]
            for target_module in sorted(references):
                target_owner = declared_module_owner(
                    target_module, contexts, schema_owners
                )
                if (
                    not target_owner
                    or target_owner == source_owner
                    or target_owner not in allowed_owners
                    or contexts[target_owner].get("graph_scope") == "excluded"
                ):
                    continue
                target_table = schema_tables.get(target_module)
                if (
                    target_module not in allowed_contracts
                    and target_module not in allowed_facades
                    and target_module not in allowed_schemas
                ):
                    violations.add(
                        Violation(
                            "read_model_scope_violation",
                            relative(path, root),
                            f"{source_module} references undeclared read target {target_module}",
                        )
                    )
                elif target_table and target_table not in allowed_tables:
                    violations.add(
                        Violation(
                            "read_model_scope_violation",
                            relative(path, root),
                            f"{source_module} reads undeclared source table {target_table}",
                        )
                    )
            for table, declaration in tables.items():
                if (
                    declaration.get("owner") in allowed_owners
                    and re.search(rf"\b{re.escape(table)}\b", text)
                    and table not in allowed_tables
                ):
                    violations.add(
                        Violation(
                            "read_model_scope_violation",
                            relative(path, root),
                            f"{source_module} reads undeclared source table {table}",
                        )
                    )
            for query_module, query_function, query_arity in sorted(
                resolved_function_calls(text)
            ):
                if not query_module.startswith("CommsCore."):
                    continue
                target_owner = declared_module_owner(
                    query_module, contexts, schema_owners
                )
                if (
                    target_owner in allowed_owners
                    and target_owner != source_owner
                    and query_module in owner_facades
                    and f"{query_module}.{query_function}/{query_arity}"
                    not in allowed_queries
                ):
                    violations.add(
                        Violation(
                            "read_model_scope_violation",
                            relative(path, root),
                            f"{source_module} calls undeclared public query "
                            f"{query_module}.{query_function}/{query_arity}",
                        )
                    )
            query_evasions = module_function_evasions(
                text,
                {facade: None for facade in owner_facades},
            )
            if query_evasions:
                violations.add(
                    Violation(
                        "read_model_scope_violation",
                        relative(path, root),
                        f"{source_module} uses a non-contract facade invocation "
                        f"({', '.join(sorted(query_evasions))})",
                    )
                )
        for rule in namespace_rules:
            source_namespace = rule.get("from")
            forbidden_namespaces = rule.get("forbidden", [])
            if not source_namespace or not module_in_namespace(
                source_module, source_namespace
            ):
                continue
            forbidden_references = sorted(
                target_module
                for target_module in references
                if any(
                    module_in_namespace(target_module, forbidden)
                    for forbidden in forbidden_namespaces
                )
            )
            if forbidden_references:
                violations.add(
                    Violation(
                        "forbidden_namespace_dependency",
                        relative(path, root),
                        f"{source_namespace} references forbidden namespaces through "
                        f"{', '.join(forbidden_references)}",
                    )
                )
        allowed = set(contexts[source_owner].get("allowed_dependencies", []))
        referenced_owners: dict[str, set[str]] = {}
        for target_module in references:
            target_owner = declared_module_owner(target_module, contexts, schema_owners)
            access_policy = schema_access_policies.get(target_module)
            read_model_schema_grant = (
                read_model_policy
                and target_module in read_model_policy["source_schemas"]
            )
            allowed_schema_access = access_policy and (
                source_module in access_policy["modules"]
                or any(
                    source_module == namespace
                    or source_module.startswith(f"{namespace}.")
                    for namespace in access_policy["namespaces"]
                )
            )
            if (
                access_policy
                and not read_model_schema_grant
                and not allowed_schema_access
            ):
                rule = (
                    "foreign_schema_import"
                    if source_owner != access_policy["owner"]
                    else "internal_schema_access"
                )
                violations.add(
                    Violation(
                        rule,
                        relative(path, root),
                        f"{source_module} references owner-internal schema {target_module}",
                    )
                )
            if target_owner and target_owner != source_owner:
                referenced_owners.setdefault(target_owner, set()).add(target_module)
        for target_owner, modules in sorted(referenced_owners.items()):
            if (
                source_owner not in included_graph_contexts
                or target_owner not in included_graph_contexts
            ):
                continue
            graph[source_owner].add(target_owner)
            if target_owner not in allowed:
                violations.add(
                    Violation(
                        "undeclared_context_edge",
                        relative(path, root),
                        f"{source_owner} -> {target_owner} through {', '.join(sorted(modules))}",
                    )
                )

        mutation_targets = persistence_mutation_targets(
            text,
            schema_modules,
            schema_tables,
        )
        foreign_write_targets: dict[str, set[str]] = {}
        for schema_module in mutation_targets.schemas:
            target_owner = schema_owners.get(schema_module)
            if target_owner and target_owner != source_owner:
                foreign_write_targets.setdefault(target_owner, set()).add(schema_module)
        for table in mutation_targets.tables:
            declaration = tables.get(table)
            if not isinstance(declaration, dict) or not declaration.get("owner"):
                violations.add(
                    Violation(
                        "unowned_persistence_write",
                        relative(path, root),
                        f"{source_module} writes undeclared table {table}",
                    )
                )
                continue
            target_owner = declaration["owner"]
            if target_owner != source_owner:
                foreign_write_targets.setdefault(target_owner, set()).add(
                    f"table:{table}"
                )
        if mutation_targets.unresolved:
            violations.add(
                Violation(
                    "unresolved_persistence_write",
                    relative(path, root),
                    f"{source_module} has persistence mutations whose targets "
                    "cannot be attributed ("
                    + "; ".join(sorted(mutation_targets.unresolved))
                    + ")",
                )
            )
        for target_owner, modules in sorted(foreign_write_targets.items()):
            violations.add(
                Violation(
                    "direct_foreign_write",
                    relative(path, root),
                    f"{source_owner} writes foreign-owned schemas "
                    f"{', '.join(sorted(modules))} owned by {target_owner}",
                )
            )
        source_is_read_only = (
            read_model_policy is not None
            or contexts[source_owner].get("kind") == "business_read_model"
        )
        mutation_evidence = (
            read_model_mutation_references(text) if source_is_read_only else set()
        )
        if source_is_read_only and (
            mutation_targets.schemas
            or mutation_targets.tables
            or mutation_targets.unresolved
        ):
            mutation_evidence.add("uses mutating or unresolved raw SQL")
        if source_is_read_only and mutation_evidence:
            violations.add(
                Violation(
                    "read_model_write",
                    relative(path, root),
                    f"{source_module} performs a persistence write despite a "
                    f"read-only boundary ({', '.join(sorted(mutation_evidence))})",
                )
            )

        public_facades = set(contexts[source_owner].get("public_facades", []))
        public_contracts = set(contexts[source_owner].get("public_contracts", []))
        if source_module in public_facades | public_contracts:
            aliases = module_aliases(text)
            contract_code = "\n".join(public_typespec_blocks(text))
            referenced_contract_modules = {
                resolve_module_reference(token, aliases)
                for token in re.findall(
                    rf"(?<![A-Za-z0-9_])({GENERIC_MODULE_NAME})",
                    contract_code,
                )
            }
            for schema_module in sorted(
                ecto_contract_modules.intersection(referenced_contract_modules)
            ):
                surface = (
                    "public facade"
                    if source_module in public_facades
                    else "public contract"
                )
                violations.add(
                    Violation(
                        "public_ecto_contract",
                        relative(path, root),
                        f"{surface} type contract exposes {schema_module}",
                    )
                )
            if "Ecto.Changeset" in referenced_contract_modules:
                surface = (
                    "public facade"
                    if source_module in public_facades
                    else "public contract"
                )
                violations.add(
                    Violation(
                        "public_ecto_contract",
                        relative(path, root),
                        f"{surface} type contract exposes Ecto.Changeset",
                    )
                )

    for source_owner, targets in sorted(graph.items()):
        for read_model_owner in sorted(read_model_contexts.intersection(targets)):
            if source_owner != read_model_owner:
                violations.add(
                    Violation(
                        "read_model_reverse_dependency",
                        MANIFEST_PATH.as_posix(),
                        f"{source_owner} depends on read-model context {read_model_owner}",
                    )
                )

    violations.update(context_cycle_violations(graph, "business_context_cycle"))
    runtime_graph = context_graphs(root, manifest).runtime
    violations.update(context_cycle_violations(runtime_graph, "runtime_context_cycle"))

    migration_root = root / "apps/comms_core/priv/repo/migrations"
    migration_scans: dict[str, MigrationTargets] = {}
    for path in sorted(migration_root.glob("*.exs")):
        path_key = relative(path, root)
        migration_scans[path_key] = migration_targets(
            path.read_text(encoding="utf-8"),
            set(tables),
        )

    required_migration_rules: dict[str, set[str]] = {}
    for path_key, scan in migration_scans.items():
        owners = {
            tables[table]["owner"]
            for table in scan.mutated
            if table in tables and isinstance(tables[table], dict)
        }
        if len(owners) > 1:
            required_migration_rules.setdefault(path_key, set()).add(
                "mixed_owner_migration"
            )
        if scan.unresolved:
            required_migration_rules.setdefault(path_key, set()).add(
                "unresolved_migration_target"
            )
        for table in sorted(scan.mutated - set(tables)):
            violations.add(
                Violation(
                    "undeclared_migration_table",
                    path_key,
                    f"migration mutates undeclared table {table}",
                )
            )
        for table in sorted(scan.referenced - set(tables)):
            violations.add(
                Violation(
                    "undeclared_migration_reference",
                    path_key,
                    f"migration references undeclared table {table}",
                )
            )

    valid_migration_exceptions: dict[str, set[str]] = {}
    raw_migration_exceptions = manifest.get("migration_exceptions", [])
    seen_exception_ids: set[str] = set()
    seen_exception_paths: set[str] = set()
    if not isinstance(raw_migration_exceptions, list):
        violations.add(
            Violation(
                "invalid_migration_exception",
                MANIFEST_PATH.as_posix(),
                "migration_exceptions must be a list",
            )
        )
        raw_migration_exceptions = []
    for index, exception in enumerate(raw_migration_exceptions):
        label = f"migration_exceptions[{index}]"
        group_valid = True
        if not isinstance(exception, dict):
            violations.add(
                Violation(
                    "invalid_migration_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label} must be a mapping",
                )
            )
            continue
        expected_fields = {"id", "adr", "condition", "paths"}
        if set(exception) != expected_fields:
            group_valid = False
            violations.add(
                Violation(
                    "invalid_migration_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label} must contain exactly "
                    + ", ".join(sorted(expected_fields)),
                )
            )
        exception_id = exception.get("id")
        if (
            not isinstance(exception_id, str)
            or not exception_id.strip()
            or exception_id in seen_exception_ids
        ):
            group_valid = False
            violations.add(
                Violation(
                    "invalid_migration_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label}.id must be non-empty and unique",
                )
            )
        else:
            seen_exception_ids.add(exception_id)
        condition = exception.get("condition")
        if not isinstance(condition, str) or not condition.strip():
            group_valid = False
            violations.add(
                Violation(
                    "invalid_migration_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label}.condition must be non-empty",
                )
            )
        adr = exception.get("adr")
        if not accepted_architecture_adr(root, adr):
            group_valid = False
            violations.add(
                Violation(
                    "invalid_migration_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label}.adr must reference an accepted architecture ADR",
                )
            )
        entries = exception.get("paths")
        if not isinstance(entries, list) or not entries:
            group_valid = False
            violations.add(
                Violation(
                    "invalid_migration_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label}.paths must be a non-empty list",
                )
            )
            entries = []
        rendered_paths = [
            entry.get("path")
            for entry in entries
            if isinstance(entry, dict) and isinstance(entry.get("path"), str)
        ]
        if rendered_paths != sorted(rendered_paths):
            group_valid = False
            violations.add(
                Violation(
                    "invalid_migration_exception",
                    MANIFEST_PATH.as_posix(),
                    f"{label}.paths must be sorted by path",
                )
            )
        candidate_entries: list[tuple[str, set[str]]] = []
        for path_index, entry in enumerate(entries):
            entry_label = f"{label}.paths[{path_index}]"
            entry_valid = group_valid
            if not isinstance(entry, dict) or set(entry) != {
                "path",
                "sha256",
                "rules",
            }:
                violations.add(
                    Violation(
                        "invalid_migration_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{entry_label} must contain exactly path, rules, sha256",
                    )
                )
                continue
            path_key = entry.get("path")
            expected_prefix = "apps/comms_core/priv/repo/migrations/"
            if (
                not isinstance(path_key, str)
                or not path_key.startswith(expected_prefix)
                or "/" in path_key[len(expected_prefix) :]
                or not path_key.endswith(".exs")
                or path_key in seen_exception_paths
            ):
                entry_valid = False
                violations.add(
                    Violation(
                        "invalid_migration_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{entry_label}.path must be a unique migration path",
                    )
                )
            else:
                seen_exception_paths.add(path_key)
            candidate = root / path_key if isinstance(path_key, str) else root
            if not candidate.is_file():
                entry_valid = False
                violations.add(
                    Violation(
                        "invalid_migration_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{entry_label}.path references a missing migration",
                    )
                )
            expected_hash = entry.get("sha256")
            if (
                not isinstance(expected_hash, str)
                or not re.fullmatch(r"[0-9a-f]{64}", expected_hash)
                or not candidate.is_file()
                or canonical_text_sha256(candidate) != expected_hash
            ):
                entry_valid = False
                violations.add(
                    Violation(
                        "invalid_migration_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{entry_label}.sha256 must match the migration content",
                    )
                )
            rules = entry.get("rules")
            if (
                not isinstance(rules, list)
                or not rules
                or rules != sorted(set(rules))
                or not set(rules).issubset(MIGRATION_EXCEPTION_RULES)
            ):
                entry_valid = False
                violations.add(
                    Violation(
                        "invalid_migration_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{entry_label}.rules must be a sorted unique subset of "
                        f"{', '.join(sorted(MIGRATION_EXCEPTION_RULES))}",
                    )
                )
                rules = []
            actual_rules = required_migration_rules.get(path_key, set())
            if set(rules) != actual_rules:
                entry_valid = False
                violations.add(
                    Violation(
                        "invalid_migration_exception",
                        MANIFEST_PATH.as_posix(),
                        f"{entry_label} is stale or incomplete: declares "
                        f"{', '.join(rules) or '(none)'}, currently requires "
                        f"{', '.join(sorted(actual_rules)) or '(none)'}",
                    )
                )
            if entry_valid:
                candidate_entries.append((path_key, set(rules)))
        if group_valid:
            for path_key, rules in candidate_entries:
                valid_migration_exceptions[path_key] = rules

    for path_key, rules in sorted(required_migration_rules.items()):
        allowed_rules = valid_migration_exceptions.get(path_key, set())
        scan = migration_scans[path_key]
        owners = {
            tables[table]["owner"]
            for table in scan.mutated
            if table in tables and isinstance(tables[table], dict)
        }
        if "mixed_owner_migration" in rules - allowed_rules:
            violations.add(
                Violation(
                    "mixed_owner_migration",
                    path_key,
                    f"migration touches owners {', '.join(sorted(owners))}",
                )
            )
        if "unresolved_migration_target" in rules - allowed_rules:
            violations.add(
                Violation(
                    "unresolved_migration_target",
                    path_key,
                    "migration has mutating targets that cannot be attributed ("
                    + "; ".join(sorted(scan.unresolved))
                    + ")",
                )
            )

    return sorted(violations)


def context_graphs(root: Path, manifest: dict) -> ContextGraphs:
    contexts = manifest.get("contexts", {})
    tables = manifest.get("tables", {})
    if not isinstance(contexts, dict) or not isinstance(tables, dict):
        return ContextGraphs({}, {}, {})

    included = graph_contexts(contexts)
    compiled: dict[str, set[str]] = {context: set() for context in included}
    runtime: dict[str, set[str]] = {context: set() for context in included}
    schema_owners = schema_owner_map(tables)

    for path in production_sources(root / "apps/comms_core"):
        text = path.read_text(encoding="utf-8")
        source_modules = core_module_declarations(text)
        if len(source_modules) != 1:
            continue
        source_module = source_modules[0]
        source_owner = declared_module_owner(source_module, contexts, schema_owners)
        if source_owner not in included:
            continue
        for target_module in core_module_references(text):
            target_owner = declared_module_owner(target_module, contexts, schema_owners)
            if target_owner in included and target_owner != source_owner:
                compiled[source_owner].add(target_owner)

    collaborations = manifest.get("runtime_collaborations", [])
    if isinstance(collaborations, list):
        for declaration in collaborations:
            if not isinstance(declaration, dict):
                continue
            consumer = declaration.get("consumer")
            provider = declaration.get("provider")
            if consumer in included and provider in included and consumer != provider:
                runtime[consumer].add(provider)

    combined = {
        context: set(compiled[context]) | set(runtime[context]) for context in included
    }
    return ContextGraphs(
        compiled={
            context: frozenset(targets) for context, targets in sorted(compiled.items())
        },
        runtime={
            context: frozenset(targets) for context, targets in sorted(runtime.items())
        },
        combined={
            context: frozenset(targets) for context, targets in sorted(combined.items())
        },
    )


def graph_edge_count(graph: dict[str, Iterable[str]]) -> int:
    return sum(len(tuple(targets)) for targets in graph.values())


def render_context_graphs(graphs: ContextGraphs) -> str:
    lines = ["## Context dependency graphs", ""]
    descriptions = {
        "compiled": "Static production module references (source owner -> referenced owner).",
        "runtime": "Declared runtime control flow (consumer -> provider).",
        "combined": "Union of compiled references and runtime control flow.",
    }
    for graph_name, graph in graphs.named():
        lines.extend(
            [
                f"### {graph_name.capitalize()} graph",
                "",
                descriptions[graph_name],
                "",
                "| Source | Targets |",
                "|---|---|",
            ]
        )
        edges_rendered = False
        for source, targets in sorted(graph.items()):
            if not targets:
                continue
            edges_rendered = True
            lines.append(
                f"| `{source}` | "
                + ", ".join(f"`{target}`" for target in sorted(targets))
                + " |"
            )
        if not edges_rendered:
            lines.append("| _none_ | _none_ |")
        components = strongly_connected_components(
            {source: set(targets) for source, targets in graph.items()}
        )
        lines.extend(
            [
                "",
                f"Edges: **{graph_edge_count(graph)}**. "
                f"Strongly connected components: **{len(components)}**.",
                "",
            ]
        )
        for component in components:
            lines.append("- `" + "`, `".join(component) + "`")
        if components:
            lines.append("")
    return "\n".join(lines).rstrip()


def _baseline_entries_from_document(
    document: dict,
    *,
    source: str,
) -> tuple[list[Violation], list[str]]:
    errors: list[str] = []
    if document.get("version") != 1:
        errors.append(f"{source}: baseline version must be 1")
    if document.get("policy") != BASELINE_POLICY:
        errors.append(f"{source}: baseline policy must be exactly {BASELINE_POLICY!r}")
    raw_entries = document.get("violations")
    if not isinstance(raw_entries, list):
        return [], [*errors, f"{source}: violations must be a list"]

    entries: list[Violation] = []
    seen_fingerprints: set[str] = set()
    for index, raw_entry in enumerate(raw_entries):
        label = f"{source}: violations[{index}]"
        if not isinstance(raw_entry, dict):
            errors.append(f"{label} must be a mapping")
            continue
        required_fields = {"fingerprint", "rule", "path", "detail"}
        missing = sorted(required_fields - set(raw_entry))
        extra = sorted(set(raw_entry) - required_fields)
        if missing:
            errors.append(f"{label} is missing fields {', '.join(missing)}")
            continue
        if extra:
            errors.append(f"{label} has unsupported fields {', '.join(extra)}")
        fingerprint = raw_entry.get("fingerprint")
        rule = raw_entry.get("rule")
        path = raw_entry.get("path")
        detail = raw_entry.get("detail")
        if not all(
            isinstance(value, str) and value
            for value in (fingerprint, rule, path, detail)
        ):
            errors.append(f"{label} fields must be non-empty strings")
            continue
        entry = Violation(rule, path, detail)
        if fingerprint != entry.fingerprint:
            errors.append(
                f"{label} fingerprint {fingerprint} does not match "
                f"{entry.fingerprint} for rule/path/detail"
            )
        if fingerprint in seen_fingerprints:
            errors.append(f"{label} duplicates fingerprint {fingerprint}")
        seen_fingerprints.add(fingerprint)
        entries.append(entry)

    if entries != sorted(entries):
        errors.append(f"{source}: violations must be sorted by rule, path, and detail")
    return entries, errors


def load_baseline(
    path: Path,
    *,
    display_path: str | None = None,
) -> tuple[list[Violation], list[str]]:
    source = display_path or path.as_posix()
    if not path.is_file():
        return [], []
    try:
        document = read_yaml(path)
    except (OSError, ValueError, yaml.YAMLError) as error:
        return [], [f"{source}: cannot load boundary baseline: {error}"]
    return _baseline_entries_from_document(document, source=source)


def baseline_fingerprints(root: Path) -> set[str]:
    entries, _errors = load_baseline(
        root / BASELINE_PATH,
        display_path=BASELINE_PATH.as_posix(),
    )
    return {item.fingerprint for item in entries}


def _configured_rule_policy(manifest: dict) -> tuple[set[str], set[str]]:
    strict_policy = manifest.get("enforcement", {}).get(
        "strict_with_explicit_deferrals", {}
    )
    if not isinstance(strict_policy, dict):
        strict_policy = {}
    absolute = set(NON_BASELINABLE_BOUNDARY_RULES)
    conditional = set(NO_NEW_DEFERRAL_RULES)
    configured_absolute = strict_policy.get("non_baselinable_rules", [])
    configured_conditional = strict_policy.get("no_new_deferrals_for_rules", [])
    if isinstance(configured_absolute, list):
        absolute.update(
            value for value in configured_absolute if isinstance(value, str)
        )
    if isinstance(configured_conditional, list):
        conditional.update(
            value for value in configured_conditional if isinstance(value, str)
        )
    return absolute, conditional


def _expanded_temporary_declarations(
    root: Path,
    manifest: dict,
    baseline_entries: list[Violation],
) -> tuple[dict[str, list[dict]], list[str]]:
    temporary = manifest.get("temporary_violations")
    if temporary is None:
        return {}, []
    if not isinstance(temporary, dict):
        return {}, [
            f"{MANIFEST_PATH.as_posix()}: temporary_violations must be a mapping"
        ]

    errors: list[str] = []
    source = temporary.get("source")
    if source != BASELINE_PATH.as_posix():
        errors.append(
            f"{MANIFEST_PATH.as_posix()}: temporary_violations.source must be "
            f"{BASELINE_PATH.as_posix()}"
        )
    exact_mapping = temporary.get("exact_mapping")
    if exact_mapping != TEMPORARY_EXACT_MAPPING_POLICY:
        errors.append(
            f"{MANIFEST_PATH.as_posix()}: temporary_violations.exact_mapping "
            "must exactly match the enforced one-to-one mapping policy"
        )

    raw_explicit = temporary.get("explicit", [])
    raw_groups = temporary.get("groups", [])
    if not isinstance(raw_explicit, list):
        return {}, [
            *errors,
            f"{MANIFEST_PATH.as_posix()}: temporary_violations.explicit must be a list",
        ]
    if not isinstance(raw_groups, list):
        return {}, [
            *errors,
            f"{MANIFEST_PATH.as_posix()}: temporary_violations.groups must be a list",
        ]
    raw_declarations = [
        *(
            (f"explicit[{index}]", declaration)
            for index, declaration in enumerate(raw_explicit)
        ),
        *(
            (f"groups[{index}]", declaration)
            for index, declaration in enumerate(raw_groups)
        ),
    ]
    seen_top_level_ids: dict[str, str] = {}
    for declaration_label, declaration in raw_declarations:
        if not isinstance(declaration, dict):
            continue
        declaration_id = declaration.get("id")
        if not isinstance(declaration_id, str) or not declaration_id.strip():
            continue
        previous_label = seen_top_level_ids.get(declaration_id)
        if previous_label is not None:
            errors.append(
                f"{MANIFEST_PATH.as_posix()}: temporary_violations."
                f"{declaration_label} duplicates top-level id "
                f"{declaration_id} from {previous_label}"
            )
        else:
            seen_top_level_ids[declaration_id] = declaration_label

    baseline_by_fingerprint = {entry.fingerprint: entry for entry in baseline_entries}
    expanded: dict[str, list[dict]] = {}

    def append_declaration(declaration: dict, label: str) -> None:
        fingerprint = declaration.get("fingerprint")
        if not isinstance(fingerprint, str) or not fingerprint:
            errors.append(f"{label} must declare a non-empty fingerprint")
            return
        expanded.setdefault(fingerprint, []).append(declaration)

    for declaration_label, declaration in raw_declarations:
        label = f"{MANIFEST_PATH.as_posix()}: temporary_violations.{declaration_label}"
        if not isinstance(declaration, dict):
            errors.append(f"{label} must be a mapping")
            continue
        declaration_id = declaration.get("id")
        if not isinstance(declaration_id, str) or not declaration_id.strip():
            errors.append(f"{label} must declare a non-empty id")
        fingerprints = declaration.get("fingerprints")
        nested = declaration.get("violations")
        if fingerprints is not None and nested is not None:
            errors.append(f"{label} may not declare both fingerprints and violations")
            continue
        if fingerprints is not None:
            if (
                not isinstance(fingerprints, list)
                or not fingerprints
                or not all(
                    isinstance(fingerprint, str) and fingerprint
                    for fingerprint in fingerprints
                )
            ):
                errors.append(
                    f"{label}.fingerprints must be a non-empty list of strings"
                )
                continue
            if len(fingerprints) != len(set(fingerprints)):
                errors.append(f"{label}.fingerprints must be unique")
            for fingerprint in fingerprints:
                baseline_entry = baseline_by_fingerprint.get(fingerprint)
                append_declaration(
                    {
                        "id": declaration_id,
                        "fingerprint": fingerprint,
                        "rule": declaration.get("rule"),
                        "path": (baseline_entry.path if baseline_entry else None),
                        "detail": (baseline_entry.detail if baseline_entry else None),
                        "adr": declaration.get("adr"),
                        "removal_condition": declaration.get("removal_condition"),
                    },
                    f"{label}.fingerprints",
                )
            continue
        if nested is not None:
            if not isinstance(nested, list) or not nested:
                errors.append(f"{label}.violations must be a non-empty list")
                continue
            for nested_index, item in enumerate(nested):
                nested_label = f"{label}.violations[{nested_index}]"
                if not isinstance(item, dict):
                    errors.append(f"{nested_label} must be a mapping")
                    continue
                append_declaration(
                    {
                        **item,
                        "id": item.get("id", declaration_id),
                        "adr": item.get("adr", declaration.get("adr")),
                        "removal_condition": item.get(
                            "removal_condition",
                            declaration.get("removal_condition"),
                        ),
                    },
                    nested_label,
                )
            continue
        append_declaration(declaration, label)

    seen_ids: dict[str, str] = {}
    for fingerprint, declarations in sorted(expanded.items()):
        for declaration in declarations:
            declaration_id = declaration.get("id")
            label = (
                f"{MANIFEST_PATH.as_posix()}: temporary violation "
                f"{declaration_id or fingerprint}"
            )
            if isinstance(declaration_id, str) and declaration_id:
                previous = seen_ids.get(declaration_id)
                if previous and previous != fingerprint:
                    # A group intentionally reuses one id for its exact members.
                    pass
                else:
                    seen_ids[declaration_id] = fingerprint
            for field_name in (
                "id",
                "fingerprint",
                "rule",
                "path",
                "detail",
                "adr",
                "removal_condition",
            ):
                value = declaration.get(field_name)
                if not isinstance(value, str) or not value.strip():
                    errors.append(f"{label} has invalid or missing {field_name}")
            adr = declaration.get("adr")
            if isinstance(adr, str) and adr:
                adr_path = Path(adr)
                adr_root = (root / "docs/02-architecture/adr").resolve()
                candidate = (root / adr_path).resolve()
                try:
                    candidate.relative_to(adr_root)
                    inside_adr_root = True
                except ValueError:
                    inside_adr_root = False
                if (
                    adr_path.is_absolute()
                    or not TEMPORARY_ADR_RE.fullmatch(adr)
                    or not inside_adr_root
                ):
                    errors.append(
                        f"{label} ADR must be a relative path within "
                        "docs/02-architecture/adr matching NNNN-*.md"
                    )
                elif not candidate.is_file():
                    errors.append(f"{label} references missing ADR {adr}")

    return expanded, errors


def violation_contexts(
    root: Path,
    manifest: dict,
    violation: Violation,
) -> set[str]:
    """Resolve the declared contexts materially involved in one finding."""

    contexts = manifest.get("contexts", {})
    if not isinstance(contexts, dict):
        return set()
    schema_owners = schema_owner_map(manifest.get("tables", {}))
    involved = {
        context_name
        for context_name in contexts
        if re.search(
            rf"(?<![A-Za-z0-9_]){re.escape(context_name)}(?![A-Za-z0-9_])",
            violation.detail,
        )
    }
    source = root / violation.path
    if source.is_file() and source.suffix in {".ex", ".exs"}:
        text = source.read_text(encoding="utf-8")
        modules = set(core_module_declarations(text)) | set(
            CORE_MODULE_REFERENCE_RE.findall(violation.detail)
        )
        involved.update(
            owner
            for module in modules
            if (owner := declared_module_owner(module, contexts, schema_owners))
        )
    return involved


def strict_deferral_rejection_reason(
    root: Path,
    manifest: dict,
    violation: Violation,
    allowed_deferral_contexts: set[str],
) -> str | None:
    """Explain why a retained finding is outside the strict deferral scope."""

    involved = violation_contexts(root, manifest, violation)
    if not involved.intersection(allowed_deferral_contexts):
        return (
            f"involves {', '.join(sorted(involved)) or '(no declared context)'}; "
            "it is outside allowed_deferral_contexts"
        )

    if violation.rule not in {
        "business_context_cycle",
        "runtime_context_cycle",
    }:
        return None

    contexts = manifest.get("contexts", {})
    known_contexts = set(contexts) if isinstance(contexts, dict) else set()
    edge_pattern = re.compile(
        r"(?<![A-Za-z0-9_-])"
        r"(?P<source>[A-Za-z][A-Za-z0-9_-]*)"
        r"->"
        r"(?P<target>[A-Za-z][A-Za-z0-9_-]*)"
        r"(?![A-Za-z0-9_-])"
    )
    residual_graph: dict[str, set[str]] = {}
    for match in edge_pattern.finditer(violation.detail):
        source = match.group("source")
        target = match.group("target")
        if source not in known_contexts or target not in known_contexts:
            continue
        if source in allowed_deferral_contexts or target in allowed_deferral_contexts:
            continue
        residual_graph.setdefault(source, set()).add(target)
        residual_graph.setdefault(target, set())

    self_cycles = sorted(
        source for source, targets in residual_graph.items() if source in targets
    )
    residual_components = strongly_connected_components(residual_graph)
    if self_cycles or residual_components:
        rendered_cycles = [
            *(f"{context}->{context}" for context in self_cycles),
            *(" <-> ".join(component) for component in residual_components),
        ]
        return (
            "contains an independent residual cycle outside "
            f"allowed_deferral_contexts: {', '.join(rendered_cycles)}"
        )
    return None


def _temporary_violation_errors(
    root: Path,
    manifest: dict,
    baseline_entries: list[Violation],
) -> list[str]:
    temporary = manifest.get("temporary_violations")
    if temporary is None:
        if baseline_entries:
            return [
                f"{MANIFEST_PATH.as_posix()}: temporary_violations is required "
                "while the boundary baseline contains retained fingerprints"
            ]
        return []

    declarations, errors = _expanded_temporary_declarations(
        root, manifest, baseline_entries
    )
    baseline_by_fingerprint = {entry.fingerprint: entry for entry in baseline_entries}
    absolute_rules, _conditional_rules = _configured_rule_policy(manifest)
    enforcement = manifest.get("enforcement", {})
    mode = enforcement.get("mode") if isinstance(enforcement, dict) else None
    strict_policy = (
        enforcement.get("strict_with_explicit_deferrals", {})
        if isinstance(enforcement, dict)
        else {}
    )
    allowed_deferral_contexts = (
        set(strict_policy.get("allowed_deferral_contexts", []))
        if isinstance(strict_policy, dict)
        and isinstance(strict_policy.get("allowed_deferral_contexts", []), list)
        else set()
    )

    for fingerprint, entry in sorted(baseline_by_fingerprint.items()):
        matches = declarations.get(fingerprint, [])
        if len(matches) != 1:
            errors.append(
                f"{MANIFEST_PATH.as_posix()}: baseline fingerprint {fingerprint} "
                f"must map to exactly one temporary violation; observed {len(matches)}"
            )
            continue
        declaration = matches[0]
        for field_name, expected in (
            ("rule", entry.rule),
            ("path", entry.path),
            ("detail", entry.detail),
        ):
            if declaration.get(field_name) != expected:
                errors.append(
                    f"{MANIFEST_PATH.as_posix()}: temporary violation "
                    f"{fingerprint} {field_name} does not match the baseline"
                )
        if entry.rule in absolute_rules:
            errors.append(
                f"{MANIFEST_PATH.as_posix()}: non-baselinable rule "
                f"{entry.rule} may not be retained as {fingerprint}"
            )
        if mode == "strict_with_explicit_deferrals":
            rejection_reason = strict_deferral_rejection_reason(
                root,
                manifest,
                entry,
                allowed_deferral_contexts,
            )
            if rejection_reason:
                errors.append(
                    f"{MANIFEST_PATH.as_posix()}: strict temporary violation "
                    f"{fingerprint} {rejection_reason}"
                )

    for fingerprint, matches in sorted(declarations.items()):
        if fingerprint not in baseline_by_fingerprint:
            errors.append(
                f"{MANIFEST_PATH.as_posix()}: temporary violation fingerprint "
                f"{fingerprint} is stale or absent from the baseline"
            )
        if len(matches) > 1:
            errors.append(
                f"{MANIFEST_PATH.as_posix()}: temporary violation fingerprint "
                f"{fingerprint} is declared {len(matches)} times"
            )

    removal_conditions = (
        temporary.get("removal_conditions", {}) if isinstance(temporary, dict) else {}
    )
    if not isinstance(removal_conditions, dict):
        errors.append(
            f"{MANIFEST_PATH.as_posix()}: "
            "temporary_violations.removal_conditions must be a mapping"
        )
    else:
        missing_rules = sorted(
            {entry.rule for entry in baseline_entries}
            - {
                rule
                for rule, condition in removal_conditions.items()
                if isinstance(rule, str)
                and isinstance(condition, str)
                and condition.strip()
            }
        )
        if missing_rules:
            errors.append(
                f"{MANIFEST_PATH.as_posix()}: temporary removal conditions are "
                f"missing for {', '.join(missing_rules)}"
            )
    return errors


def _reviewed_baseline_transition_errors(root: Path, enforcement: dict) -> list[str]:
    transitions = enforcement.get("reviewed_baseline_transitions")
    if transitions is None:
        return []
    if not isinstance(transitions, list):
        return [
            f"{MANIFEST_PATH.as_posix()}: "
            "enforcement.reviewed_baseline_transitions must be a list"
        ]

    errors: list[str] = []
    seen_ids: set[str] = set()
    seen_hashes: set[str] = set()
    adoption = enforcement.get("baseline_adoption")
    adoption_hash = (
        adoption.get("previous_baseline_sha256") if isinstance(adoption, dict) else None
    )

    for index, transition in enumerate(transitions):
        label = (
            f"{MANIFEST_PATH.as_posix()}: "
            f"enforcement.reviewed_baseline_transitions[{index}]"
        )
        if not isinstance(transition, dict):
            errors.append(f"{label} must be a mapping")
            continue

        unsupported = sorted(set(transition) - REVIEWED_BASELINE_TRANSITION_FIELDS)
        missing = sorted(REVIEWED_BASELINE_TRANSITION_FIELDS - set(transition))
        if unsupported:
            errors.append(f"{label} has unsupported fields {', '.join(unsupported)}")
        if missing:
            errors.append(f"{label} is missing required fields {', '.join(missing)}")

        transition_id = transition.get("id")
        if not isinstance(transition_id, str) or not transition_id.strip():
            errors.append(f"{label}.id must be a non-empty string")
        elif transition_id in seen_ids:
            errors.append(f"{label}.id duplicates {transition_id}")
        else:
            seen_ids.add(transition_id)

        previous_hash = transition.get("previous_baseline_sha256")
        if not isinstance(previous_hash, str) or not re.fullmatch(
            r"[0-9a-f]{64}", previous_hash
        ):
            errors.append(
                f"{label}.previous_baseline_sha256 must be a lowercase SHA-256"
            )
        elif previous_hash in seen_hashes:
            errors.append(
                f"{label}.previous_baseline_sha256 duplicates {previous_hash}"
            )
        else:
            seen_hashes.add(previous_hash)
            if previous_hash == adoption_hash:
                errors.append(
                    f"{label}.previous_baseline_sha256 is also declared by "
                    "enforcement.baseline_adoption"
                )

        parsed_fingerprints: dict[str, set[str]] = {}
        for field_name in ("added_fingerprints", "removed_fingerprints"):
            fingerprints = transition.get(field_name)
            if not isinstance(fingerprints, list) or not all(
                isinstance(fingerprint, str)
                and re.fullmatch(r"[0-9a-f]{16}", fingerprint)
                for fingerprint in fingerprints
            ):
                errors.append(
                    f"{label}.{field_name} must be a list of 16-character "
                    "lowercase hexadecimal fingerprints"
                )
                continue
            if fingerprints != sorted(set(fingerprints)):
                errors.append(f"{label}.{field_name} must be unique and sorted")
            parsed_fingerprints[field_name] = set(fingerprints)

        added = parsed_fingerprints.get("added_fingerprints", set())
        removed = parsed_fingerprints.get("removed_fingerprints", set())
        if not added and not removed:
            errors.append(
                f"{label} must declare at least one added or removed fingerprint"
            )
        overlap = sorted(added & removed)
        if overlap:
            errors.append(
                f"{label} declares fingerprints as both added and removed: "
                f"{', '.join(overlap)}"
            )

        adr = transition.get("adr")
        if not isinstance(adr, str) or not adr.strip():
            errors.append(f"{label}.adr must be a non-empty string")
        else:
            adr_path = Path(adr)
            adr_root = (root / "docs/02-architecture/adr").resolve()
            candidate = (root / adr_path).resolve()
            try:
                candidate.relative_to(adr_root)
                inside_adr_root = True
            except ValueError:
                inside_adr_root = False
            if (
                adr_path.is_absolute()
                or not TEMPORARY_ADR_RE.fullmatch(adr)
                or not inside_adr_root
            ):
                errors.append(
                    f"{label}.adr must be a relative path within "
                    "docs/02-architecture/adr matching NNNN-*.md"
                )
            elif not candidate.is_file():
                errors.append(f"{label}.adr references missing ADR {adr}")

        removal_condition = transition.get("removal_condition")
        if not isinstance(removal_condition, str) or not removal_condition.strip():
            errors.append(f"{label}.removal_condition must be a non-empty string")

    return errors


def _activation_lock_errors(manifest: dict) -> list[str]:
    """Prevent an activated strict gate from being downgraded in-manifest."""

    enforcement = manifest.get("enforcement", {})
    if not isinstance(enforcement, dict):
        return [f"{MANIFEST_PATH.as_posix()}: enforcement must be a mapping"]

    mode = enforcement.get("mode", "baseline")
    target_mode = enforcement.get("target_mode")
    strict_policy = enforcement.get("strict_with_explicit_deferrals")
    strict_active = (
        isinstance(strict_policy, dict) and strict_policy.get("active") is True
    )
    activation_declared = (
        manifest.get("status") == "enforced"
        or target_mode is not None
        or mode in {"strict", "strict_with_explicit_deferrals"}
        or strict_active
    )

    errors: list[str] = []
    if target_mode is not None and target_mode not in SUPPORTED_ENFORCEMENT_MODES:
        errors.append(
            f"{MANIFEST_PATH.as_posix()}: unsupported enforcement target_mode "
            f"{target_mode!r}"
        )
    if not activation_declared:
        return errors
    if target_mode not in ENFORCED_TARGET_MODES:
        errors.append(
            f"{MANIFEST_PATH.as_posix()}: activated enforcement target_mode is "
            "locked to 'strict_with_explicit_deferrals' or its one-way "
            "stronger successor 'strict'"
        )
    if mode != target_mode:
        errors.append(
            f"{MANIFEST_PATH.as_posix()}: activated enforcement mode {mode!r} "
            f"must equal target_mode {target_mode!r}"
        )
    return errors


def _enforcement_mode_errors(
    root: Path,
    manifest: dict,
    violations: list[Violation],
) -> list[str]:
    enforcement = manifest.get("enforcement", {})
    if not isinstance(enforcement, dict):
        return [f"{MANIFEST_PATH.as_posix()}: enforcement must be a mapping"]
    mode = enforcement.get("mode", "baseline")
    if mode not in SUPPORTED_ENFORCEMENT_MODES:
        return [f"{MANIFEST_PATH.as_posix()}: unsupported enforcement mode {mode!r}"]
    errors = _activation_lock_errors(manifest)
    if enforcement.get("reject_new_violations", True) is not True:
        errors.append(
            f"{MANIFEST_PATH.as_posix()}: reject_new_violations must remain true"
        )
    strict_policy = enforcement.get("strict_with_explicit_deferrals")
    if strict_policy is not None and not isinstance(strict_policy, dict):
        errors.append(
            f"{MANIFEST_PATH.as_posix()}: "
            "enforcement.strict_with_explicit_deferrals must be a mapping"
        )
    if mode == "strict" and violations:
        errors.append(
            f"{MANIFEST_PATH.as_posix()}: strict mode permits no boundary violations"
        )
    if mode == "strict":
        baseline_entries, _baseline_errors = load_baseline(
            root / BASELINE_PATH,
            display_path=BASELINE_PATH.as_posix(),
        )
        if baseline_entries:
            errors.append(
                f"{MANIFEST_PATH.as_posix()}: strict mode requires an empty "
                "boundary baseline"
            )
        if manifest.get("temporary_violations") is not None:
            errors.append(
                f"{MANIFEST_PATH.as_posix()}: strict mode requires "
                "temporary_violations to be removed"
            )
        if enforcement.get("baseline_adoption") is not None:
            errors.append(
                f"{MANIFEST_PATH.as_posix()}: strict mode requires the "
                "transitional baseline_adoption declaration to be removed"
            )
        if strict_policy is not None:
            errors.append(
                f"{MANIFEST_PATH.as_posix()}: strict mode requires the "
                "strict_with_explicit_deferrals policy to be removed"
            )
    if (
        mode == "strict_with_explicit_deferrals"
        and isinstance(strict_policy, dict)
        and strict_policy.get("active") is not True
    ):
        errors.append(
            f"{MANIFEST_PATH.as_posix()}: strict_with_explicit_deferrals mode "
            "requires its policy to be active"
        )
    if mode == "strict_with_explicit_deferrals" and isinstance(strict_policy, dict):
        for field_name in (
            "exact_mapping",
            "reject_missing_declarations",
            "reject_stale_declarations",
            "reject_duplicate_fingerprints",
            "require_base_branch_no_growth",
            "require_deterministic_report",
        ):
            if strict_policy.get(field_name) is not True:
                errors.append(
                    f"{MANIFEST_PATH.as_posix()}: strict_with_explicit_deferrals."
                    f"{field_name} must be true"
                )
        allowed_contexts = strict_policy.get("allowed_deferral_contexts")
        contexts = manifest.get("contexts", {})
        if (
            not isinstance(allowed_contexts, list)
            or not allowed_contexts
            or not all(
                isinstance(context, str) and context for context in allowed_contexts
            )
            or allowed_contexts != sorted(set(allowed_contexts))
        ):
            errors.append(
                f"{MANIFEST_PATH.as_posix()}: strict_with_explicit_deferrals."
                "allowed_deferral_contexts must be a non-empty sorted unique list"
            )
        elif isinstance(contexts, dict):
            unknown = sorted(set(allowed_contexts) - set(contexts))
            if unknown:
                errors.append(
                    f"{MANIFEST_PATH.as_posix()}: strict_with_explicit_deferrals."
                    "allowed_deferral_contexts references unknown contexts "
                    f"{', '.join(unknown)}"
                )
    adoption = enforcement.get("baseline_adoption")
    if adoption is not None:
        if not isinstance(adoption, dict):
            errors.append(
                f"{MANIFEST_PATH.as_posix()}: "
                "enforcement.baseline_adoption must be a mapping"
            )
        else:
            previous_hash = adoption.get("previous_baseline_sha256")
            fingerprints = adoption.get("allowed_discovery_fingerprints")
            removal_condition = adoption.get("removal_condition")
            if not isinstance(previous_hash, str) or not re.fullmatch(
                r"[0-9a-f]{64}",
                previous_hash,
            ):
                errors.append(
                    f"{MANIFEST_PATH.as_posix()}: baseline adoption must declare "
                    "a lowercase SHA-256 previous_baseline_sha256"
                )
            if (
                not isinstance(fingerprints, list)
                or not fingerprints
                or not all(
                    isinstance(fingerprint, str)
                    and re.fullmatch(r"[0-9a-f]{16}", fingerprint)
                    for fingerprint in fingerprints
                )
            ):
                errors.append(
                    f"{MANIFEST_PATH.as_posix()}: baseline adoption must declare "
                    "a non-empty allowed_discovery_fingerprints list"
                )
            elif fingerprints != sorted(set(fingerprints)):
                errors.append(
                    f"{MANIFEST_PATH.as_posix()}: baseline adoption fingerprints "
                    "must be unique and sorted"
                )
            if not isinstance(removal_condition, str) or not removal_condition.strip():
                errors.append(
                    f"{MANIFEST_PATH.as_posix()}: baseline adoption must declare "
                    "a non-empty removal_condition"
                )
    errors.extend(_reviewed_baseline_transition_errors(root, enforcement))
    return errors


def _is_transitional_discovery(
    root: Path,
    manifest: dict,
    violation: Violation,
) -> bool:
    contexts = manifest.get("contexts", {})
    if not isinstance(contexts, dict):
        return False
    transitional = {
        name
        for name, context in contexts.items()
        if isinstance(context, dict)
        and str(context.get("kind", "")).startswith("transitional_")
    }
    if not transitional:
        return False
    if any(context in violation.detail for context in transitional):
        return True

    source_path = root / violation.path
    if source_path.is_file() and source_path.suffix in {".ex", ".exs"}:
        declared_modules = core_module_declarations(
            source_path.read_text(encoding="utf-8")
        )
        if len(declared_modules) == 1:
            owner = declared_module_owner(
                declared_modules[0],
                contexts,
                schema_owner_map(manifest.get("tables", {})),
            )
            return owner in transitional
    return False


def boundary_errors(root: Path) -> tuple[list[str], list[Violation]]:
    manifest_path = root / MANIFEST_PATH
    if not manifest_path.is_file():
        return [
            f"{MANIFEST_PATH.as_posix()}: required boundary manifest is missing"
        ], []
    try:
        manifest = read_yaml(manifest_path)
    except (OSError, ValueError, yaml.YAMLError) as error:
        return [
            f"{MANIFEST_PATH.as_posix()}: cannot load boundary manifest: {error}"
        ], []
    violations = analyze_context_boundaries(root, manifest)
    baseline_path = root / BASELINE_PATH
    if not baseline_path.is_file():
        return [
            f"{BASELINE_PATH.as_posix()}: required boundary baseline is missing"
        ], violations
    baseline_entries, baseline_errors = load_baseline(
        baseline_path,
        display_path=BASELINE_PATH.as_posix(),
    )
    known = {entry.fingerprint for entry in baseline_entries}
    absolute_rules, _conditional_rules = _configured_rule_policy(manifest)
    integrity_errors = [
        violation for violation in violations if violation.rule in absolute_rules
    ]
    new = [
        violation
        for violation in violations
        if violation.rule not in absolute_rules and violation.fingerprint not in known
    ]
    discovered = [
        violation
        for violation in new
        if _is_transitional_discovery(root, manifest, violation)
    ]
    regressions = [violation for violation in new if violation not in discovered]
    current = {violation.fingerprint for violation in violations}
    resolved = sorted(known - current)
    errors = [
        (
            "READ-MODEL control violation: "
            if violation.rule
            in {
                "invalid_read_model_exception",
                "read_model_scope_violation",
                "read_model_write",
                "read_model_reverse_dependency",
            }
            else "NON-BASELINABLE architecture violation: "
        )
        + violation.render()
        for violation in integrity_errors
    ]
    errors.extend(f"BASELINE integrity violation: {error}" for error in baseline_errors)
    errors.extend(
        f"TEMPORARY-VIOLATION integrity violation: {error}"
        for error in _temporary_violation_errors(root, manifest, baseline_entries)
    )
    errors.extend(
        f"ENFORCEMENT mode violation: {error}"
        for error in _enforcement_mode_errors(root, manifest, violations)
    )
    errors.extend(
        f"DISCOVERED context-boundary debt: {violation.render()}"
        for violation in discovered
    )
    errors.extend(
        f"NEW context-boundary violation: {violation.render()}"
        for violation in regressions
    )
    errors.extend(
        f"RESOLVED context-boundary baseline fingerprint must be removed: {fingerprint}"
        for fingerprint in resolved
    )
    return errors, violations


def render_baseline_report(
    violations: list[Violation],
    graphs: ContextGraphs,
) -> str:
    categories: dict[str, list[Violation]] = {}
    for item in sorted(violations):
        categories.setdefault(item.rule, []).append(item)
    lines = [
        "# Context-boundary violation baseline",
        "",
        "Generated from `scripts/validate_architecture.py --write-boundary-baseline`.",
        "Existing fingerprints are migration debt. Relative to the checked-in baseline,",
        "new, changed, or resolved fingerprints fail CI; baseline edits require architecture review.",
        "",
        f"Total tracked violations: **{len(violations)}**.",
        "",
    ]
    for rule, items in sorted(categories.items()):
        lines.extend(
            [
                f"## {rule} ({len(items)})",
                "",
                "| Fingerprint | Location | Evidence |",
                "|---|---|---|",
            ]
        )
        lines.extend(
            f"| `{item.fingerprint}` | `{item.path}` | "
            f"{item.detail.replace('|', '/')} |"
            for item in items
        )
        lines.append("")
    lines.extend([render_context_graphs(graphs), ""])
    return "\n".join(lines).rstrip()


def generated_report_errors(root: Path) -> list[str]:
    if not (root / BASELINE_PATH).is_file():
        return [f"{BASELINE_PATH.as_posix()}: required boundary baseline is missing"]
    baseline_entries, baseline_errors = load_baseline(
        root / BASELINE_PATH,
        display_path=BASELINE_PATH.as_posix(),
    )
    if baseline_errors:
        return [
            f"cannot verify generated report while baseline is invalid: {error}"
            for error in baseline_errors
        ]
    manifest_path = root / MANIFEST_PATH
    if not manifest_path.is_file():
        return [f"{MANIFEST_PATH.as_posix()}: required boundary manifest is missing"]
    try:
        manifest = read_yaml(manifest_path)
    except (OSError, ValueError, yaml.YAMLError) as error:
        return [f"{MANIFEST_PATH.as_posix()}: cannot load boundary manifest: {error}"]
    expected = render_baseline_report(baseline_entries, context_graphs(root, manifest))
    report_path = root / REPORT_PATH
    if not report_path.is_file():
        return [f"{REPORT_PATH.as_posix()}: generated report is missing"]
    actual = report_path.read_text(encoding="utf-8").rstrip()
    if actual != expected:
        return [
            f"{REPORT_PATH.as_posix()}: generated report drifted from the "
            "validated baseline and context graphs; run "
            "scripts/validate_architecture.py --write-boundary-baseline "
            "after architecture review"
        ]
    return []


def _stable_value(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _string_set(value: object) -> set[str]:
    if not isinstance(value, list):
        return set()
    return {item for item in value if isinstance(item, str)}


def _declarations_by(
    value: object,
    key: str,
) -> dict[str, dict]:
    if not isinstance(value, list):
        return {}
    return {
        declaration[key]: declaration
        for declaration in value
        if isinstance(declaration, dict)
        and isinstance(declaration.get(key), str)
    }


def _added_tokens(
    tokens: set[str],
    prefix: str,
    base: object,
    current: object,
) -> None:
    for item in sorted(_string_set(current) - _string_set(base)):
        tokens.add(f"{prefix}:add:{item}")


def _manifest_semantic_widenings(base: dict, current: dict) -> set[str]:
    """Return exact review tokens for ownership or permission growth."""

    tokens: set[str] = set()
    base_contexts = base.get("contexts", {})
    current_contexts = current.get("contexts", {})
    if not isinstance(base_contexts, dict):
        base_contexts = {}
    if not isinstance(current_contexts, dict):
        current_contexts = {}
    for name, context in current_contexts.items():
        if not isinstance(context, dict):
            continue
        previous = base_contexts.get(name)
        if not isinstance(previous, dict):
            tokens.add(f"context:{name}:add:{_stable_value(context)}")
            continue
        for field in (
            "allowed_dependencies",
            "public_facades",
            "public_contracts",
            "internal_namespaces",
            "owned_modules",
            "publishes",
            "consumes",
        ):
            _added_tokens(
                tokens,
                f"context:{name}:{field}",
                previous.get(field),
                context.get(field),
            )
        if (
            previous.get("kind") != context.get("kind")
            and context.get("kind") is not None
        ):
            tokens.add(
                f"context:{name}:kind:"
                f"{previous.get('kind')}->{context.get('kind')}"
            )
        if (
            previous.get("graph_scope", "included") == "included"
            and context.get("graph_scope", "included") == "excluded"
        ):
            tokens.add(f"context:{name}:graph_scope:included->excluded")

    base_tables = base.get("tables", {})
    current_tables = current.get("tables", {})
    if not isinstance(base_tables, dict):
        base_tables = {}
    if not isinstance(current_tables, dict):
        current_tables = {}
    ownership_fields = (
        "owner",
        "canonical_schema",
        "canonical_accessor",
        "role",
        "external_schema",
        "access",
    )
    for table, declaration in current_tables.items():
        if not isinstance(declaration, dict):
            continue
        previous = base_tables.get(table)
        if not isinstance(previous, dict):
            tokens.add(f"table:{table}:add:{_stable_value(declaration)}")
            continue
        for field in ownership_fields:
            if previous.get(field) != declaration.get(field):
                tokens.add(
                    f"table:{table}:{field}:"
                    f"{_stable_value(previous.get(field))}->"
                    f"{_stable_value(declaration.get(field))}"
                )
        previous_owner = previous.get("owner")
        current_owner = declaration.get("owner")
        previous_context = (
            base_contexts.get(previous_owner, {})
            if isinstance(previous_owner, str)
            else {}
        )
        current_context = (
            current_contexts.get(current_owner, {})
            if isinstance(current_owner, str)
            else {}
        )
        previous_access = previous.get(
            "access_namespaces",
            previous_context.get("internal_namespaces", [])
            if isinstance(previous_context, dict)
            else [],
        )
        current_access = declaration.get(
            "access_namespaces",
            current_context.get("internal_namespaces", [])
            if isinstance(current_context, dict)
            else [],
        )
        _added_tokens(
            tokens,
            f"table:{table}:access_namespaces",
            previous_access,
            current_access,
        )

    base_read_models = _declarations_by(
        base.get("read_model_exceptions"),
        "module",
    )
    current_read_models = _declarations_by(
        current.get("read_model_exceptions"),
        "module",
    )
    for module, declaration in current_read_models.items():
        previous = base_read_models.get(module)
        if previous is None:
            tokens.add(
                f"read_model:{module}:add:{_stable_value(declaration)}"
            )
            continue
        if previous.get("mode") != declaration.get("mode"):
            tokens.add(
                f"read_model:{module}:mode:"
                f"{previous.get('mode')}->{declaration.get('mode')}"
            )
        _added_tokens(
            tokens,
            f"read_model:{module}:owners",
            previous.get("owners"),
            declaration.get("owners"),
        )
        previous_access = previous.get("access", {})
        current_access = declaration.get("access", {})
        if not isinstance(previous_access, dict):
            previous_access = {}
        if not isinstance(current_access, dict):
            current_access = {}
        for field in ("public_contracts", "public_queries", "source_tables"):
            _added_tokens(
                tokens,
                f"read_model:{module}:{field}",
                previous_access.get(field),
                current_access.get(field),
            )

    def migration_entries(document: dict) -> dict[str, dict[str, object]]:
        entries: dict[str, dict[str, object]] = {}
        declarations = document.get("migration_exceptions", [])
        if not isinstance(declarations, list):
            return entries
        for declaration in declarations:
            if not isinstance(declaration, dict):
                continue
            for entry in declaration.get("paths", []):
                if not isinstance(entry, dict) or not isinstance(
                    entry.get("path"),
                    str,
                ):
                    continue
                entries[entry["path"]] = {
                    "rules": entry.get("rules"),
                    "sha256": entry.get("sha256"),
                }
        return entries

    base_migrations = migration_entries(base)
    current_migrations = migration_entries(current)
    for path, declaration in current_migrations.items():
        previous = base_migrations.get(path)
        if previous is None:
            tokens.add(
                f"migration_exception:{path}:add:{_stable_value(declaration)}"
            )
            continue
        for field in ("rules", "sha256"):
            if previous.get(field) != declaration.get(field):
                tokens.add(
                    f"migration_exception:{path}:{field}:"
                    f"{_stable_value(previous.get(field))}->"
                    f"{_stable_value(declaration.get(field))}"
                )

    def collaboration_tokens(
        section: str,
        scalar_fields: tuple[str, ...],
        list_fields: tuple[str, ...],
    ) -> None:
        previous_by_id = _declarations_by(base.get(section), "id")
        current_by_id = _declarations_by(current.get(section), "id")
        for declaration_id, declaration in current_by_id.items():
            previous = previous_by_id.get(declaration_id)
            prefix = f"{section}:{declaration_id}"
            if previous is None:
                tokens.add(f"{prefix}:add:{_stable_value(declaration)}")
                continue
            for field in scalar_fields:
                if previous.get(field) != declaration.get(field):
                    if (
                        field == "transaction"
                        and previous.get(field) == "independent"
                        and declaration.get(field) == "required"
                    ):
                        continue
                    tokens.add(
                        f"{prefix}:{field}:"
                        f"{_stable_value(previous.get(field))}->"
                        f"{_stable_value(declaration.get(field))}"
                    )
            for field in list_fields:
                previous_items = {
                    _stable_value(item)
                    for item in previous.get(field, [])
                } if isinstance(previous.get(field), list) else set()
                current_items = {
                    _stable_value(item)
                    for item in declaration.get(field, [])
                } if isinstance(declaration.get(field), list) else set()
                for item in sorted(current_items - previous_items):
                    tokens.add(f"{prefix}:{field}:add:{item}")

    collaboration_tokens(
        "runtime_collaborations",
        (
            "consumer",
            "provider",
            "port",
            "result_contract",
            "implementation",
            "binding",
            "graph_semantics",
            "transaction",
        ),
        ("callers", "operations"),
    )
    collaboration_tokens(
        "technical_interfaces",
        (
            "owner",
            "interface",
            "dispatch",
            "behaviour",
            "implementation",
            "binding",
            "transaction",
        ),
        ("callers", "operations", "contracts"),
    )

    base_namespace_rules = _declarations_by(
        base.get("namespace_dependency_rules"),
        "id",
    )
    current_namespace_rules = _declarations_by(
        current.get("namespace_dependency_rules"),
        "id",
    )
    for rule_id, previous in base_namespace_rules.items():
        declaration = current_namespace_rules.get(rule_id)
        if declaration is None:
            tokens.add(f"namespace_rule:{rule_id}:removed")
            continue
        if previous.get("from") != declaration.get("from"):
            tokens.add(
                f"namespace_rule:{rule_id}:from:"
                f"{previous.get('from')}->{declaration.get('from')}"
            )
        for forbidden in sorted(
            _string_set(previous.get("forbidden"))
            - _string_set(declaration.get("forbidden"))
        ):
            tokens.add(f"namespace_rule:{rule_id}:forbidden:remove:{forbidden}")
    return tokens


def _reviewed_manifest_transition_errors(
    root: Path,
    base_path: Path,
    base: dict,
    current: dict,
) -> list[str]:
    """Require an exact ADR-backed declaration for every semantic widening."""

    enforcement = current.get("enforcement", {})
    if not isinstance(enforcement, dict):
        return ["current boundary manifest enforcement must be a mapping"]
    raw_transitions = enforcement.get("reviewed_manifest_transitions", [])
    if not isinstance(raw_transitions, list):
        return [
            "enforcement.reviewed_manifest_transitions must be a list"
        ]
    errors: list[str] = []
    transitions: list[dict] = []
    seen_ids: set[str] = set()
    seen_hashes: set[str] = set()
    for index, transition in enumerate(raw_transitions):
        label = f"enforcement.reviewed_manifest_transitions[{index}]"
        if not isinstance(transition, dict):
            errors.append(f"{label} must be a mapping")
            continue
        if set(transition) != REVIEWED_MANIFEST_TRANSITION_FIELDS:
            errors.append(
                f"{label} must contain exactly "
                + ", ".join(sorted(REVIEWED_MANIFEST_TRANSITION_FIELDS))
            )
            continue
        transition_id = transition.get("id")
        previous_hash = transition.get("previous_manifest_sha256")
        changes = transition.get("approved_changes")
        adr = transition.get("adr")
        removal = transition.get("removal_condition")
        valid = True
        if (
            not isinstance(transition_id, str)
            or not transition_id.strip()
            or transition_id in seen_ids
        ):
            errors.append(f"{label}.id must be non-empty and unique")
            valid = False
        else:
            seen_ids.add(transition_id)
        if (
            not isinstance(previous_hash, str)
            or not re.fullmatch(r"[0-9a-f]{64}", previous_hash)
            or previous_hash in seen_hashes
        ):
            errors.append(
                f"{label}.previous_manifest_sha256 must be a unique lowercase SHA-256"
            )
            valid = False
        else:
            seen_hashes.add(previous_hash)
        if (
            not isinstance(changes, list)
            or not changes
            or not all(isinstance(change, str) and change for change in changes)
            or changes != sorted(set(changes))
        ):
            errors.append(
                f"{label}.approved_changes must be a non-empty sorted unique list"
            )
            valid = False
        if not accepted_architecture_adr(root, adr):
            errors.append(f"{label}.adr must reference an accepted architecture ADR")
            valid = False
        if not isinstance(removal, str) or not removal.strip():
            errors.append(f"{label}.removal_condition must be non-empty")
            valid = False
        if valid:
            transitions.append(transition)

    actual_hash = canonical_text_sha256(base_path)
    for transition in transitions:
        if transition["previous_manifest_sha256"] != actual_hash:
            errors.append(
                "reviewed manifest transition is stale for the current immutable "
                f"base: {transition['id']}"
            )
    matching = [
        transition
        for transition in transitions
        if transition["previous_manifest_sha256"] == actual_hash
    ]
    actual_changes = _manifest_semantic_widenings(base, current)
    if actual_changes and not matching:
        errors.extend(
            f"boundary manifest has unreviewed semantic widening: {change}"
            for change in sorted(actual_changes)
        )
    elif matching:
        declared = set(matching[0]["approved_changes"])
        errors.extend(
            f"reviewed manifest transition has undeclared change: {change}"
            for change in sorted(actual_changes - declared)
        )
        errors.extend(
            f"reviewed manifest transition has stale approved change: {change}"
            for change in sorted(declared - actual_changes)
        )
    return errors


def compare_boundary_manifests(
    root: Path,
    base_path: Path,
) -> list[str]:
    """Reject weakening an enforcement state already present on the PR base."""

    current_path = root / MANIFEST_PATH
    errors: list[str] = []
    if not current_path.is_file():
        errors.append(f"current boundary manifest does not exist: {current_path}")
    if not base_path.is_file():
        errors.append(f"base boundary manifest does not exist: {base_path}")
    if errors:
        return errors

    try:
        current = read_yaml(current_path)
    except (OSError, ValueError, yaml.YAMLError) as error:
        errors.append(f"current boundary manifest is invalid: {error}")
        current = {}
    try:
        base = read_yaml(base_path)
    except (OSError, ValueError, yaml.YAMLError) as error:
        errors.append(f"base boundary manifest is invalid: {error}")
        base = {}
    if errors:
        return errors

    errors.extend(
        _reviewed_manifest_transition_errors(
            root,
            base_path,
            base,
            current,
        )
    )

    current_enforcement = current.get("enforcement", {})
    base_enforcement = base.get("enforcement", {})
    if not isinstance(current_enforcement, dict):
        errors.append("current boundary manifest enforcement must be a mapping")
        return errors
    if not isinstance(base_enforcement, dict):
        errors.append("base boundary manifest enforcement must be a mapping")
        return errors

    if base.get("status") == "enforced" and current.get("status") != "enforced":
        errors.append(
            "boundary manifest weakened immutable base status: "
            "enforced may not be removed or changed"
        )

    base_retired = base.get("retired_modules", [])
    current_retired = current.get("retired_modules", [])
    if isinstance(base_retired, list) and isinstance(current_retired, list):
        removed_retired = sorted(set(base_retired) - set(current_retired))
        if removed_retired:
            errors.append(
                "boundary manifest removed immutable retired module namespace "
                f"tombstones: {', '.join(removed_retired)}"
            )

    def retired_binding_keys(manifest: dict) -> set[tuple[str, str]]:
        declarations = manifest.get("retired_runtime_bindings", [])
        if not isinstance(declarations, list):
            return set()
        return {
            (declaration["application"], declaration["key"])
            for declaration in declarations
            if isinstance(declaration, dict)
            and isinstance(declaration.get("application"), str)
            and isinstance(declaration.get("key"), str)
        }

    removed_retired_bindings = sorted(
        retired_binding_keys(base) - retired_binding_keys(current)
    )
    if removed_retired_bindings:
        rendered = ", ".join(
            f"{application}.{key}" for application, key in removed_retired_bindings
        )
        errors.append(
            "boundary manifest removed immutable retired runtime binding "
            f"tombstones: {rendered}"
        )

    base_target = base_enforcement.get("target_mode")
    current_target = current_enforcement.get("target_mode")
    base_target_rank = ENFORCEMENT_MODE_RANK.get(base_target, -1)
    current_target_rank = ENFORCEMENT_MODE_RANK.get(current_target, -1)
    if base_target in ENFORCED_TARGET_MODES and current_target_rank < base_target_rank:
        errors.append(
            "boundary manifest weakened immutable base target_mode: "
            f"{base_target!r} may not be downgraded to {current_target!r}"
        )

    base_mode = base_enforcement.get("mode", "baseline")
    current_mode = current_enforcement.get("mode", "baseline")
    if base_mode == "strict" and current_mode != "strict":
        errors.append(
            "boundary manifest downgraded immutable base mode from strict "
            f"to {current_mode!r}"
        )
    elif base_mode == "strict_with_explicit_deferrals" and current_mode not in {
        "strict",
        "strict_with_explicit_deferrals",
    }:
        errors.append(
            "boundary manifest downgraded immutable base mode from "
            f"strict_with_explicit_deferrals to {current_mode!r}"
        )

    base_strict_policy = base_enforcement.get(
        "strict_with_explicit_deferrals",
        {},
    )
    current_strict_policy = current_enforcement.get(
        "strict_with_explicit_deferrals",
        {},
    )
    base_active = (
        isinstance(base_strict_policy, dict)
        and base_strict_policy.get("active") is True
    )
    current_active = (
        isinstance(current_strict_policy, dict)
        and current_strict_policy.get("active") is True
    )
    if base_active and not current_active and current_mode != "strict":
        errors.append(
            "boundary manifest weakened immutable base strict activation: "
            "strict_with_explicit_deferrals.active=true may not be removed "
            "or disabled except by promotion to strict"
        )

    return errors


def compare_boundary_baselines(
    root: Path,
    base_path: Path,
) -> list[str]:
    current_entries, current_errors = load_baseline(
        root / BASELINE_PATH,
        display_path=BASELINE_PATH.as_posix(),
    )
    base_entries, base_errors = load_baseline(
        base_path,
        display_path=base_path.as_posix(),
    )
    errors = [
        *(f"current baseline is invalid: {error}" for error in current_errors),
        *(f"base baseline is invalid: {error}" for error in base_errors),
    ]
    if not (root / BASELINE_PATH).is_file():
        errors.append(
            f"current boundary baseline does not exist: {root / BASELINE_PATH}"
        )
    if not base_path.is_file():
        errors.append(f"base boundary baseline does not exist: {base_path}")
    if errors:
        return errors
    base_fingerprints = {entry.fingerprint for entry in base_entries}
    current_fingerprints = {entry.fingerprint for entry in current_entries}
    actual_added = current_fingerprints - base_fingerprints
    adopted_fingerprints: set[str] = set()
    manifest_path = root / MANIFEST_PATH
    manifest = read_yaml(manifest_path) if manifest_path.is_file() else {}
    enforcement = manifest.get("enforcement", {})
    if not isinstance(enforcement, dict):
        return [f"{MANIFEST_PATH.as_posix()}: enforcement must be a mapping"]

    activation_errors = _activation_lock_errors(manifest)
    if activation_errors:
        return activation_errors

    transition_errors = _reviewed_baseline_transition_errors(root, enforcement)
    if transition_errors:
        return transition_errors

    _absolute_rules, no_new_rules = _configured_rule_policy(manifest)
    current_by_fingerprint = {entry.fingerprint: entry for entry in current_entries}
    protected_growth = sorted(
        (
            current_by_fingerprint[fingerprint]
            for fingerprint in actual_added
            if current_by_fingerprint[fingerprint].rule in no_new_rules
        ),
        key=lambda entry: entry.fingerprint,
    )
    errors.extend(
        "boundary baseline added a protected no-new-deferral fingerprint: "
        + entry.render()
        for entry in protected_growth
    )

    if enforcement.get("mode") in {"strict", "strict_with_explicit_deferrals"}:
        strict_growth = sorted(
            (
                current_by_fingerprint[fingerprint]
                for fingerprint in actual_added
                if current_by_fingerprint[fingerprint] not in protected_growth
            ),
            key=lambda entry: entry.fingerprint,
        )
        errors.extend(
            "strict boundary baseline may only shrink; added fingerprint: "
            + entry.render()
            for entry in strict_growth
        )

    if errors:
        return errors

    actual_hash = canonical_text_sha256(base_path)
    transitions = enforcement.get("reviewed_baseline_transitions", [])
    matching_transitions = [
        transition
        for transition in transitions
        if transition.get("previous_baseline_sha256") == actual_hash
    ]

    if matching_transitions:
        transition = matching_transitions[0]
        transition_id = transition["id"]
        declared_added = set(transition["added_fingerprints"])
        declared_removed = set(transition["removed_fingerprints"])
        actual_removed = base_fingerprints - current_fingerprints

        def append_delta_errors(
            field_name: str,
            actual: set[str],
            declared: set[str],
        ) -> None:
            undeclared = sorted(actual - declared)
            stale = sorted(declared - actual)
            if undeclared:
                errors.append(
                    f"reviewed baseline transition {transition_id} has "
                    f"undeclared {field_name}: {', '.join(undeclared)}"
                )
            if stale:
                errors.append(
                    f"reviewed baseline transition {transition_id} has stale "
                    f"declared {field_name}: {', '.join(stale)}"
                )

        append_delta_errors("added fingerprints", actual_added, declared_added)
        append_delta_errors(
            "removed fingerprints",
            actual_removed,
            declared_removed,
        )
        if errors:
            return errors
        adopted_fingerprints = declared_added
    else:
        adoption = enforcement.get("baseline_adoption")
        if isinstance(adoption, dict):
            expected_hash = adoption.get("previous_baseline_sha256")
            if actual_hash == expected_hash:
                configured = adoption.get("allowed_discovery_fingerprints", [])
                if isinstance(configured, list):
                    adopted_fingerprints = {
                        fingerprint
                        for fingerprint in configured
                        if isinstance(fingerprint, str)
                    }
                    stale = sorted(adopted_fingerprints - actual_added)
                    if stale:
                        errors.append(
                            "baseline adoption has stale allowed discovery "
                            f"fingerprints: {', '.join(stale)}"
                        )
    growth = sorted(
        (
            entry
            for entry in current_entries
            if entry.fingerprint not in base_fingerprints
            and entry.fingerprint not in adopted_fingerprints
        ),
        key=lambda entry: entry.fingerprint,
    )
    errors.extend(
        "boundary baseline grew relative to the base branch: " + entry.render()
        for entry in growth
    )
    return errors


def validate(
    root: Path = ROOT,
    *,
    check_generated_report: bool = False,
) -> list[str]:
    root = root.resolve()
    context_errors, _ = boundary_errors(root)
    report_errors = generated_report_errors(root) if check_generated_report else []
    return sorted(
        [
            *validate_umbrella_dependencies(root),
            *validate_core_adapter_references(root),
            *validate_repo_access(root),
            *validate_owner_lifecycle_call_sites(root),
            *context_errors,
            *report_errors,
        ]
    )


def write_baseline(root: Path, violations: list[Violation]) -> None:
    manifest_path = root / MANIFEST_PATH
    manifest = read_yaml(manifest_path) if manifest_path.is_file() else {}
    absolute_rules, no_new_rules = _configured_rule_policy(manifest)
    integrity_violations = [item for item in violations if item.rule in absolute_rules]
    if integrity_violations:
        rendered = "\n".join(item.render() for item in integrity_violations)
        raise ValueError(
            f"refusing to baseline non-baselinable architecture violations:\n{rendered}"
        )

    previous_entries, previous_errors = load_baseline(
        root / BASELINE_PATH,
        display_path=BASELINE_PATH.as_posix(),
    )
    if previous_errors:
        raise ValueError(
            "refusing to replace an invalid boundary baseline:\n"
            + "\n".join(previous_errors)
        )
    previous_fingerprints = {entry.fingerprint for entry in previous_entries}
    prohibited_growth = [
        item
        for item in violations
        if item.rule in no_new_rules and item.fingerprint not in previous_fingerprints
    ]
    if prohibited_growth:
        rendered = "\n".join(item.render() for item in prohibited_growth)
        raise ValueError(
            "refusing to add new deferrals for protected architecture rules:\n"
            f"{rendered}"
        )

    violations = sorted(set(violations))
    payload = {
        "version": 1,
        "policy": BASELINE_POLICY,
        "violations": [
            {
                "fingerprint": item.fingerprint,
                "rule": item.rule,
                "path": item.path,
                "detail": item.detail,
            }
            for item in violations
        ],
    }
    (root / BASELINE_PATH).write_text(
        yaml.safe_dump(payload, sort_keys=False, width=120), encoding="utf-8"
    )
    graphs = context_graphs(root, manifest)
    (root / REPORT_PATH).write_text(
        render_baseline_report(violations, graphs),
        encoding="utf-8",
    )


def write_current_baseline(root: Path) -> list[Violation]:
    manifest_path = root / MANIFEST_PATH
    if not manifest_path.is_file():
        raise ValueError(
            "refusing to write boundary baseline because the manifest is "
            f"missing or invalid:\n{MANIFEST_PATH.as_posix()}: required "
            "boundary manifest is missing"
        )
    try:
        manifest = read_yaml(manifest_path)
    except (OSError, ValueError, yaml.YAMLError) as error:
        raise ValueError(
            "refusing to write boundary baseline because the manifest is "
            f"missing or invalid:\n{MANIFEST_PATH.as_posix()}: cannot load "
            f"boundary manifest: {error}"
        ) from error
    violations = analyze_context_boundaries(root, manifest)
    write_baseline(root, violations)
    return violations


def main(
    argv: list[str] | None = None,
    *,
    root: Path = ROOT,
) -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write-boundary-baseline", action="store_true")
    parser.add_argument("--check-generated-report", action="store_true")
    parser.add_argument(
        "--compare-boundary-baseline",
        type=Path,
        metavar="PATH",
        help="reject fingerprints not present in the supplied base-branch baseline",
    )
    parser.add_argument(
        "--compare-boundary-manifest",
        type=Path,
        metavar="PATH",
        help="reject enforcement weaker than the supplied base-branch manifest",
    )
    parser.add_argument("--show-context-graphs", action="store_true")
    args = parser.parse_args(argv)
    root = root.resolve()
    if args.write_boundary_baseline:
        if (
            args.check_generated_report
            or args.compare_boundary_baseline
            or args.compare_boundary_manifest
            or args.show_context_graphs
        ):
            raise SystemExit(
                "--write-boundary-baseline may not be combined with check or "
                "reporting options"
            )
        try:
            violations = write_current_baseline(root)
        except ValueError as error:
            raise SystemExit(str(error)) from error
        print(
            f"Wrote {len(violations)} boundary violations to {BASELINE_PATH} and {REPORT_PATH}"
        )
        return
    context_errors, violations = boundary_errors(root)
    errors = sorted(
        [
            *validate_umbrella_dependencies(root),
            *validate_core_adapter_references(root),
            *validate_repo_access(root),
            *validate_owner_lifecycle_call_sites(root),
            *context_errors,
        ]
    )
    if args.check_generated_report:
        errors.extend(generated_report_errors(root))
    if bool(args.compare_boundary_baseline) != bool(args.compare_boundary_manifest):
        errors.append(
            "--compare-boundary-baseline and --compare-boundary-manifest "
            "must be supplied together"
        )
    if args.compare_boundary_baseline:
        base_path = args.compare_boundary_baseline
        if not base_path.is_absolute():
            base_path = (Path.cwd() / base_path).resolve()
        errors.extend(compare_boundary_baselines(root, base_path))
    if args.compare_boundary_manifest:
        base_manifest_path = args.compare_boundary_manifest
        if not base_manifest_path.is_absolute():
            base_manifest_path = (Path.cwd() / base_manifest_path).resolve()
        errors.extend(compare_boundary_manifests(root, base_manifest_path))
    errors = sorted(errors)
    if errors:
        raise SystemExit("Architecture validation failed:\n" + "\n".join(errors))
    manifest = read_yaml(root / MANIFEST_PATH)
    graphs = context_graphs(root, manifest)
    if args.show_context_graphs:
        print(render_context_graphs(graphs))
    print(
        "Architecture validation passed: "
        f"{len(ALLOWED_UMBRELLA_DEPENDENCIES)} classified apps, "
        f"{len(REPO_ACCESS_ALLOWLIST)} explicit Repo exceptions, "
        f"{len(violations)} tracked context-boundary violations, "
        f"{graph_edge_count(graphs.compiled)} compiled edges, "
        f"{graph_edge_count(graphs.runtime)} runtime edges, "
        f"{graph_edge_count(graphs.combined)} combined edges"
    )


if __name__ == "__main__":
    main()
