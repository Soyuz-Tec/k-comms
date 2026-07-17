#!/usr/bin/env python3
"""Enforce umbrella and baseline-controlled business-context boundaries."""

from __future__ import annotations

import argparse
import hashlib
import re
from dataclasses import dataclass
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
NON_BASELINABLE_BOUNDARY_RULES = frozenset(
    {
        "ambiguous_context_owner",
        "direct_foreign_write",
        "duplicate_table_mapping",
        "invalid_context_declaration",
        "invalid_dependency_graph_declaration",
        "invalid_read_model_exception",
        "invalid_runtime_collaboration",
        "invalid_table_declaration",
        "invalid_temporary_violation",
        "multiple_context_modules_file",
        "public_ecto_contract",
        "read_model_scope_violation",
        "read_model_write",
        "read_model_reverse_dependency",
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
    r"^defmodule\s+(CommsCore(?:\.[A-Z][A-Za-z0-9_]*)+)", re.MULTILINE
)
SCHEMA_RE = re.compile(r'^\s*schema\s+"([a-z0-9_]+)"', re.MULTILINE)
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
MIGRATION_TABLE_RE = re.compile(r"\btable\(:(\w+)")
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
APPLICATION_BINDING_RE = re.compile(
    r"Application\.(?:fetch_env!?|get_env)\s*\(\s*"
    r":([a-z][a-z0-9_]*)\s*,\s*:([a-z][a-z0-9_]*)"
)


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
            if "CommsCore.Repo" not in text and not GROUPED_REPO_ALIAS_RE.search(text):
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
            caller_modules = set(MODULE_RE.findall(text))
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
    return bool(
        re.search(
            rf"(?<![A-Za-z0-9_.]){re.escape(module)}(?=(?:\.t\(\))|[^A-Za-z0-9_.]|$)",
            text,
        )
    )


def discover_schemas(root: Path) -> dict[str, list[tuple[str, str]]]:
    schemas: dict[str, list[tuple[str, str]]] = {}
    for path in production_sources(root / "apps/comms_core"):
        text = path.read_text(encoding="utf-8")
        module_match = MODULE_RE.search(text)
        schema_match = SCHEMA_RE.search(text)
        if module_match and schema_match:
            schemas.setdefault(schema_match.group(1), []).append(
                (module_match.group(1), relative(path, root))
            )
    return schemas


def core_module_references(text: str) -> set[str]:
    references = set(CORE_MODULE_REFERENCE_RE.findall(text))
    for prefix, members in GROUPED_CORE_ALIAS_RE.findall(text):
        for member in members.split(","):
            cleaned = member.strip()
            if re.fullmatch(GENERIC_MODULE_NAME, cleaned):
                references.add(f"{prefix}.{cleaned}")
    references.update(core_aliases(text).values())
    return references


def module_aliases(text: str) -> dict[str, str]:
    aliases: dict[str, str] = {}
    for module, explicit_name in GENERIC_SIMPLE_ALIAS_RE.findall(text):
        aliases[explicit_name or module.rsplit(".", 1)[-1]] = module
    for prefix, members in GENERIC_GROUPED_ALIAS_RE.findall(text):
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
    return aliases


def core_aliases(text: str) -> dict[str, str]:
    return {
        name: module
        for name, module in module_aliases(text).items()
        if module.startswith("CommsCore.")
    }


def imported_modules(text: str) -> set[str]:
    aliases = module_aliases(text)
    return {aliases.get(module, module) for module in GENERIC_IMPORT_RE.findall(text)}


def qualified_function_calls(text: str) -> set[tuple[str, str, int]]:
    """Return statically visible qualified calls with their effective arity."""

    calls: set[tuple[str, str, int]] = set()
    aliases = module_aliases(text)
    for call in QUALIFIED_CALL_RE.finditer(text):
        receiver, function = call.groups()
        module = aliases.get(receiver, receiver)
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
        for module, function, _arity in qualified_function_calls(text)
        if module.startswith("CommsCore.")
    }


def module_function_evasions(
    text: str, protected_modules: dict[str, set[str] | None]
) -> set[str]:
    """Find invocation forms intentionally excluded from stable facade contracts."""

    evidence: set[str] = set()
    aliases = module_aliases(text)

    for module in imported_modules(text):
        if module in protected_modules:
            evidence.add(f"imports {module}")

    for reference in QUALIFIED_FUNCTION_REFERENCE_RE.finditer(text):
        receiver, function = reference.groups()
        module = aliases.get(receiver, receiver)
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

    module_token = rf"(?P<module>{GENERIC_MODULE_NAME})"
    dynamic_patterns = (
        re.compile(
            rf"\b(?:Kernel\.)?apply\s*\(\s*{module_token}\s*,\s*"
            r":(?P<function>[a-z_][A-Za-z0-9_]*[!?]?)\b"
        ),
        re.compile(
            rf":erlang\.apply\s*\(\s*{module_token}\s*,\s*"
            r":(?P<function>[a-z_][A-Za-z0-9_]*[!?]?)\b"
        ),
        re.compile(
            rf"\bFunction\.capture\s*\(\s*{module_token}\s*,\s*"
            r":(?P<function>[a-z_][A-Za-z0-9_]*[!?]?)\b"
        ),
    )
    for pattern in dynamic_patterns:
        for dynamic in pattern.finditer(text):
            module = aliases.get(dynamic.group("module"), dynamic.group("module"))
            function = dynamic.group("function")
            protected_functions = protected_modules.get(module)
            if module in protected_modules and (
                protected_functions is None or function in protected_functions
            ):
                evidence.add(f"uses dynamic {module}.{function}")

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


def _matching_elixir_block_end(masked_text: str, opening_do: re.Match[str]) -> int | None:
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
    definitions = list(
        re.finditer(r"(?m)^\s*def\s+[a-z_][A-Za-z0-9_!?]*\s*\(", masked)
    )
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
            clauses.append(("unparsed", text[definition.start():next_definition]))
            continue

        absolute_do_start = close_index + block_do.start()
        opening_do = ELIXIR_BLOCK_TOKEN_RE.search(masked, absolute_do_start)
        if opening_do is None:
            clauses.append(("unparsed", text[definition.start():next_definition]))
            continue
        matching_end = _matching_elixir_block_end(masked, opening_do)
        if matching_end is None:
            clauses.append(("unparsed", text[definition.start():next_definition]))
            continue
        clauses.append(("block", text[opening_do.end():matching_end]))

    return clauses


def _transaction_guarded_block(body: str) -> bool:
    """Recognize the transaction guard shape used by runtime collaboration ports."""

    masked = _masked_elixir_code(body)
    guard = re.match(
        r"\s*if\s+Repo\.in_transaction\?\(\)\s+do\b",
        masked,
    )
    if guard is None:
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
    for name, arity in sorted(operations):
        clauses = _public_operation_clauses(port_text, name, arity)
        if not clauses:
            errors.append(f"{name}/{arity} has no statically inspectable public clause")
            continue
        for clause_index, (style, body) in enumerate(clauses, start=1):
            guarded = style == "block" and _transaction_guarded_block(body)
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
    return {aliases.get(module, module) for module in BEHAVIOUR_RE.findall(text)}


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
    for path in sorted((*config_root.rglob("*.ex"), *config_root.rglob("*.exs"))):
        text = path.read_text(encoding="utf-8")
        for block in config_block.finditer(text):
            application, body = block.groups()
            for key, module in key_module.findall(body):
                bindings.setdefault((application, key), set()).add(module)
        for application, key, module in three_argument_binding.findall(text):
            bindings.setdefault((application, key), set()).add(module)
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
            for source_module, source_path in module_sources.items():
                if source_module in {port, implementation}:
                    continue
                source_text = source_path.read_text(encoding="utf-8")
                evasions = module_function_evasions(
                    source_text,
                    {port: {name for name, _arity in parsed_operations}},
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
                    for module, function, arity in qualified_function_calls(source_text)
                    if module == port
                }
                if calls.intersection(parsed_operations):
                    actual_callers.add(source_module)
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
                    port_bindings = set(
                        APPLICATION_BINDING_RE.findall(
                            port_source.read_text(encoding="utf-8")
                        )
                    )
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
                "graph_semantics must exactly equal "
                f"{expected_graph_semantics!r}",
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
        for application, key in APPLICATION_BINDING_RE.findall(port_text):
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


def schema_owner_map(tables: dict) -> dict[str, str]:
    return {
        declaration["canonical_schema"]: declaration["owner"]
        for declaration in tables.values()
        if declaration.get("canonical_schema") and declaration.get("owner")
    }


WRITE_CALL_RE = re.compile(
    r"\b(?P<receiver>Repo|Ecto\.Multi|Multi)\."
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


def raw_sql_write_or_unresolved(text: str) -> bool:
    """Reject mutating SQL and SQL whose statement cannot be statically reviewed."""

    if module_function_evasions(
        text,
        {"Ecto.Adapters.SQL": {"query", "query!"}},
    ):
        return True

    aliases = module_aliases(text)
    query_calls: list[re.Match[str]] = []
    for call in QUALIFIED_CALL_RE.finditer(text):
        receiver, function = call.groups()
        module = aliases.get(receiver, receiver)
        if module == "Ecto.Adapters.SQL" and function in {"query", "query!"}:
            query_calls.append(call)

    if "Ecto.Adapters.SQL" in imported_modules(text):
        query_calls.extend(re.finditer(r"(?<![A-Za-z0-9_.])query!?\s*\(", text))

    for call in query_calls:
        parsed = balanced_call_arguments(text, call.end() - 1)
        if not parsed:
            return True
        arguments_text, _ = parsed
        arguments = split_top_level_args(arguments_text)
        if len(arguments) < 2:
            return True
        sql = _static_sql_expression(text, arguments[1])
        if sql is None or RAW_SQL_DML_RE.search(sql):
            return True
    return False


def read_model_mutation_references(text: str) -> set[str]:
    protected_modules: dict[str, set[str] | None] = {
        "CommsCore.Repo": set(REPO_MUTATION_FUNCTIONS),
        "Ecto.Multi": set(ECTO_MULTI_MUTATION_FUNCTIONS),
        "Oban": set(OBAN_MUTATION_FUNCTIONS),
    }
    evidence = {
        f"calls {module}.{function}/{arity}"
        for module, function, arity in qualified_function_calls(text)
        if module in protected_modules
        and function in (protected_modules[module] or set())
    }
    evidence.update(module_function_evasions(text, protected_modules))
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
    tokens.update(
        {alias: module for alias, module in aliases.items() if module in schema_modules}
    )
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

    variable = re.match(r"\s*([a-z_][A-Za-z0-9_]*)\b", expression)
    if variable:
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
    return None


def _write_target_expression(
    receiver: str,
    operation: str,
    arguments: list[str],
    pipeline_input: str | None,
) -> str | None:
    if receiver == "Repo":
        if arguments:
            return arguments[0]
        return pipeline_input

    piped = pipeline_input is not None
    if operation in {"insert_all", "update_all", "delete_all"}:
        target_index = 1 if piped else 2
    else:
        target_index = 1 if piped else 2
    if len(arguments) > target_index:
        return arguments[target_index]
    return None


def _local_write_wrappers(text: str) -> dict[str, int]:
    definitions = list(
        re.finditer(
            r"(?m)^\s*defp?\s+([a-z_][A-Za-z0-9_!?]*)\s*\(([^)]*)\)",
            text,
        )
    )
    wrappers: dict[str, int] = {}
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
        for parameter_index, parameter in enumerate(parameters):
            if not re.fullmatch(r"[a-z_][A-Za-z0-9_]*", parameter):
                continue
            if re.search(
                rf"(?:\bRepo\.(?:insert!?|insert_or_update!?|update!?|delete!?)"
                rf"\s*\(\s*{re.escape(parameter)}\b|"
                rf"\b{re.escape(parameter)}\s*\|>\s*"
                rf"Repo\.(?:insert!?|insert_or_update!?|update!?|delete!?)\s*\()",
                block,
            ):
                wrappers[definition.group(1)] = parameter_index
    return wrappers


def schema_write_references(text: str, schema_modules: set[str]) -> set[str]:
    """Return canonical schemas that production code demonstrably persists."""

    aliases = core_aliases(text)
    write_targets: set[str] = set()

    for call in WRITE_CALL_RE.finditer(text):
        parsed = balanced_call_arguments(text, call.end() - 1)
        if not parsed:
            continue
        arguments_text, _ = parsed
        arguments = split_top_level_args(arguments_text)
        pipeline_input = pipeline_input_before(text, call.start())
        target_expression = _write_target_expression(
            call.group("receiver"),
            call.group("operation"),
            arguments,
            pipeline_input,
        )
        if not target_expression:
            continue
        schema = _resolve_schema_expression(
            target_expression,
            aliases=aliases,
            schema_modules=schema_modules,
            source=text,
            before=call.start(),
        )
        if schema:
            write_targets.add(schema)

    for wrapper, parameter_index in _local_write_wrappers(text).items():
        for call in re.finditer(rf"\b{re.escape(wrapper)}\s*\(", text):
            line_start = text.rfind("\n", 0, call.start()) + 1
            if re.match(r"\s*defp?\s+", text[line_start : call.start()]):
                continue
            parsed = balanced_call_arguments(text, call.end() - 1)
            if not parsed:
                continue
            arguments_text, _ = parsed
            arguments = split_top_level_args(arguments_text)
            pipeline_input = pipeline_input_before(text, call.start())
            if len(arguments) > parameter_index:
                target_expression = arguments[parameter_index]
            elif parameter_index == 0:
                target_expression = pipeline_input
            else:
                target_expression = None
            if not target_expression:
                continue
            schema = _resolve_schema_expression(
                target_expression,
                aliases=aliases,
                schema_modules=schema_modules,
                source=text,
                before=call.start(),
            )
            if schema:
                write_targets.add(schema)

    return write_targets


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
                f"members: {', '.join(component)}; "
                f"edges: {', '.join(internal_edges)}",
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
        declared_modules = MODULE_RE.findall(text)
        if len(declared_modules) > 1:
            declared_tables = SCHEMA_RE.findall(text)
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

    retired_modules = set(manifest.get("retired_modules", []))
    for app_dir in sorted((root / "apps").iterdir()):
        if not app_dir.is_dir():
            continue
        for path in production_sources(app_dir):
            text = path.read_text(encoding="utf-8")
            module_match = MODULE_RE.search(text)
            references = core_module_references(text)
            used = set(references).intersection(retired_modules)
            if module_match and module_match.group(1) in retired_modules:
                used.add(module_match.group(1))
            for retired in sorted(used):
                violations.add(
                    Violation(
                        "retired_context_module",
                        relative(path, root),
                        f"production code references retired context module {retired}",
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
    module_sources: dict[str, Path] = {}
    for path in production_sources(root / "apps/comms_core"):
        text = path.read_text(encoding="utf-8")
        for module_match in MODULE_RE.finditer(text):
            module_sources[module_match.group(1)] = path

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
        schema_modules,
        module_sources,
    )
    violations.update(runtime_violations)

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

    for context_name, context in sorted(contexts.items()):
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
            elif contract in schema_modules:
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
    for app in ("comms_web", "comms_workers", "comms_integrations"):
        for path in production_sources(root / f"apps/{app}"):
            text = path.read_text(encoding="utf-8")
            references = core_module_references(text)
            if re.search(r"\bEcto\.Changeset\b", text):
                violations.add(
                    Violation(
                        "adapter_changeset_import",
                        relative(path, root),
                        "adapter references Ecto.Changeset instead of a stable validation contract",
                    )
                )
            for schema_module in sorted(schema_modules.intersection(references)):
                violations.add(
                    Violation(
                        "adapter_schema_import",
                        relative(path, root),
                        f"adapter references internal Ecto schema {schema_module}",
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
        source_modules = MODULE_RE.findall(text)
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
                qualified_function_calls(text)
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

        foreign_write_targets: dict[str, set[str]] = {}
        for schema_module in schema_write_references(text, schema_modules):
            target_owner = schema_owners.get(schema_module)
            if target_owner and target_owner != source_owner:
                foreign_write_targets.setdefault(target_owner, set()).add(schema_module)
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
        if source_is_read_only and raw_sql_write_or_unresolved(text):
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

        if source_module in contexts[source_owner].get("public_facades", []):
            spec_blocks = re.findall(r"@spec[\s\S]*?(?=\n\s*(?:@|def|defp)\b)", text)
            for schema_module in sorted(schema_modules):
                if any(
                    exact_module_reference(block, schema_module)
                    for block in spec_blocks
                ):
                    violations.add(
                        Violation(
                            "public_ecto_contract",
                            relative(path, root),
                            f"public facade specification exposes {schema_module}",
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

    migration_exceptions = {
        path
        for exception in manifest.get("migration_exceptions", [])
        for path in exception.get("paths", [])
    }
    migration_root = root / "apps/comms_core/priv/repo/migrations"
    for path in sorted(migration_root.glob("*.exs")):
        touched = set(MIGRATION_TABLE_RE.findall(path.read_text(encoding="utf-8")))
        owners = {tables[table]["owner"] for table in touched if table in tables}
        path_key = relative(path, root)
        if len(owners) > 1 and path_key not in migration_exceptions:
            violations.add(
                Violation(
                    "mixed_owner_migration",
                    path_key,
                    f"migration touches owners {', '.join(sorted(owners))}",
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
        source_modules = MODULE_RE.findall(text)
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
        errors.append(
            f"{source}: baseline policy must be exactly {BASELINE_POLICY!r}"
        )
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


def _enforcement_mode_errors(
    manifest: dict,
    violations: list[Violation],
) -> list[str]:
    enforcement = manifest.get("enforcement", {})
    if not isinstance(enforcement, dict):
        return [f"{MANIFEST_PATH.as_posix()}: enforcement must be a mapping"]
    mode = enforcement.get("mode", "baseline")
    if mode not in SUPPORTED_ENFORCEMENT_MODES:
        return [f"{MANIFEST_PATH.as_posix()}: unsupported enforcement mode {mode!r}"]
    errors: list[str] = []
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
    if (
        mode == "strict_with_explicit_deferrals"
        and isinstance(strict_policy, dict)
        and strict_policy.get("active") is not True
    ):
        errors.append(
            f"{MANIFEST_PATH.as_posix()}: strict_with_explicit_deferrals mode "
            "requires its policy to be active"
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
            if (
                not isinstance(removal_condition, str)
                or not removal_condition.strip()
            ):
                errors.append(
                    f"{MANIFEST_PATH.as_posix()}: baseline adoption must declare "
                    "a non-empty removal_condition"
                )
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
        module_match = MODULE_RE.search(source_path.read_text(encoding="utf-8"))
        if module_match:
            owner = declared_module_owner(
                module_match.group(1),
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
        for error in _enforcement_mode_errors(manifest, violations)
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
    adopted_fingerprints: set[str] = set()
    manifest_path = root / MANIFEST_PATH
    manifest = read_yaml(manifest_path) if manifest_path.is_file() else {}
    adoption = (
        manifest.get("enforcement", {}).get("baseline_adoption")
        if isinstance(manifest.get("enforcement"), dict)
        else None
    )
    if isinstance(adoption, dict):
        expected_hash = adoption.get("previous_baseline_sha256")
        actual_hash = hashlib.sha256(base_path.read_bytes()).hexdigest()
        if actual_hash == expected_hash:
            configured = adoption.get("allowed_discovery_fingerprints", [])
            if isinstance(configured, list):
                adopted_fingerprints = {
                    fingerprint
                    for fingerprint in configured
                    if isinstance(fingerprint, str)
                }
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
            "refusing to baseline non-baselinable architecture violations:\n"
            f"{rendered}"
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
    parser.add_argument("--show-context-graphs", action="store_true")
    args = parser.parse_args(argv)
    root = root.resolve()
    if args.write_boundary_baseline:
        if (
            args.check_generated_report
            or args.compare_boundary_baseline
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
    if args.compare_boundary_baseline:
        base_path = args.compare_boundary_baseline
        if not base_path.is_absolute():
            base_path = (Path.cwd() / base_path).resolve()
        errors.extend(compare_boundary_baselines(root, base_path))
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
