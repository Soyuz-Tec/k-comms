#!/usr/bin/env python3
"""Enforce umbrella and baseline-controlled business-context boundaries."""

from __future__ import annotations

import argparse
import hashlib
import re
from dataclasses import dataclass
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = Path("docs/02-architecture/context-boundaries.yaml")
BASELINE_PATH = Path("docs/02-architecture/context-boundary-baseline.yaml")
REPORT_PATH = Path("docs/02-architecture/context-boundary-violations.md")
NON_BASELINABLE_BOUNDARY_RULES = frozenset(
    {
        "invalid_read_model_exception",
        "invalid_table_declaration",
        "multiple_context_modules_file",
        "read_model_scope_violation",
        "read_model_write",
        "read_model_reverse_dependency",
    }
)

ALLOWED_UMBRELLA_DEPENDENCIES: dict[str, frozenset[str]] = {
    "comms_core": frozenset(),
    "comms_integrations": frozenset({"comms_observability"}),
    "comms_observability": frozenset(),
    "comms_test_support": frozenset({"comms_core"}),
    "comms_web": frozenset(
        {"comms_core", "comms_integrations", "comms_observability"}
    ),
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
MODULE_RE = re.compile(r"^defmodule\s+(CommsCore(?:\.[A-Z][A-Za-z0-9_]*)+)", re.MULTILINE)
SCHEMA_RE = re.compile(r'^\s*schema\s+"([a-z0-9_]+)"', re.MULTILINE)
CORE_MODULE_REFERENCE_RE = re.compile(
    r"\b(CommsCore(?:\.[A-Z][A-Za-z0-9_]*)+)\b"
)
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


def relative(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def production_sources(app_dir: Path) -> list[Path]:
    source_root = app_dir / "lib"
    if not source_root.is_dir():
        return []
    return sorted((*source_root.rglob("*.ex"), *source_root.rglob("*.exs")))


def read_yaml(path: Path) -> dict:
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
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
        for dependency in sorted(
            dependencies - ALLOWED_UMBRELLA_DEPENDENCIES[app]
        ):
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

    missing = sorted(path for path in REPO_ACCESS_ALLOWLIST if not (root / path).is_file())
    for path in missing:
        errors.append(f"{path}: Repo-access allowlist entry does not exist")
    for path in sorted(set(REPO_ACCESS_ALLOWLIST) - set(missing) - observed_allowlist_entries):
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
                if (
                    call in protected_calls
                    and caller_modules != set(OWNER_LIFECYCLE_CALL_ALLOWLIST[call])
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
            if (
                evasions
                and caller_modules
                != set(
                    OWNER_LIFECYCLE_CALL_ALLOWLIST[
                        "CommsCore.Accounts.apply_user_lifecycle_change"
                    ]
                )
            ):
                errors.append(
                    f"{path_key}: owner-internal lifecycle command evasion is "
                    f"forbidden ({', '.join(sorted(evasions))})"
                )
    return errors


def module_owner(module: str, contexts: dict) -> str | None:
    matches: list[tuple[int, str]] = []
    for context_name, context in contexts.items():
        prefixes = [
            *context.get("public_facades", []),
            *context.get("public_contracts", []),
            *context.get("internal_namespaces", []),
        ]
        for prefix in prefixes:
            if module == prefix or module.startswith(f"{prefix}."):
                matches.append((len(prefix), context_name))
    return max(matches)[1] if matches else None


def declared_module_owner(
    module: str, contexts: dict, schema_owners: dict[str, str]
) -> str | None:
    """Prefer explicit table ownership over namespace-based attribution."""

    return schema_owners.get(module) or module_owner(module, contexts)


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
            expanded = (
                f"{expanded_root}.{suffix}" if separator else expanded_root
            )
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
    return {
        aliases.get(module, module)
        for module in GENERIC_IMPORT_RE.findall(text)
    }


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
    for definition in re.finditer(
        rf"(?m)^\s*def\s+{re.escape(function)}\s*\(", text
    ):
        parsed = balanced_call_arguments(text, definition.end() - 1)
        if not parsed:
            continue
        arguments_text, _ = parsed
        arguments = split_top_level_args(arguments_text)
        defaults = sum("\\\\" in argument for argument in arguments)
        if len(arguments) - defaults <= arity <= len(arguments):
            return True
    return False


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
        query_calls.extend(
            re.finditer(r"(?<![A-Za-z0-9_.])query!?\s*\(", text)
        )

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
        if (
            delimiter_balance <= 0
            and not previous_line.lstrip().startswith("|>")
        ):
            break
    return text[start:pipe].strip()


def _schema_token_map(
    aliases: dict[str, str], schema_modules: set[str]
) -> dict[str, str]:
    tokens = {module: module for module in schema_modules}
    tokens.update(
        {
            alias: module
            for alias, module in aliases.items()
            if module in schema_modules
        }
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
            if re.match(r"\s*defp?\s+", text[line_start:call.start()]):
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


def analyze_context_boundaries(root: Path, manifest: dict) -> list[Violation]:
    violations: set[Violation] = set()
    contexts = manifest.get("contexts", {})
    tables = manifest.get("tables", {})
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
                violations.add(Violation("unowned_table", path, f"{module} maps undeclared table {table}"))
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
            violations.add(Violation("duplicate_table_mapping", declarations[0][1], f"table {table} is mapped by {', '.join(modules)}; canonical is {canonical}"))
        if canonical not in modules:
            violations.add(Violation("canonical_schema_missing", MANIFEST_PATH.as_posix(), f"table {table} declares missing canonical schema {canonical}"))

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
            violations.add(Violation("declared_table_missing", MANIFEST_PATH.as_posix(), f"table {table} has no discovered Ecto schema"))
        if declaration.get("owner") not in contexts:
            violations.add(Violation("unknown_table_owner", MANIFEST_PATH.as_posix(), f"table {table} has unknown owner {declaration.get('owner')}"))

    schema_modules = {module for declarations in schemas.values() for module, _ in declarations}
    module_sources: dict[str, Path] = {}
    for path in production_sources(root / "apps/comms_core"):
        text = path.read_text(encoding="utf-8")
        for module_match in MODULE_RE.finditer(text):
            module_sources[module_match.group(1)] = path

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
        source_kind = contexts.get(source_owner, {}).get("kind") if source_owner else None
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
            parsed_public_queries.add(
                (query_module, query_function, query_arity)
            )
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
                    for query_module, query_function, query_arity
                    in parsed_public_queries
                },
                "public_facades": {
                    query_module
                    for query_module, _query_function, _query_arity
                    in parsed_public_queries
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
                    violations.add(Violation("adapter_schema_import", relative(path, root), f"adapter references internal Ecto schema {schema_module}"))

    scoped_read_policies: dict[str, list[dict[str, set[str] | str]]] = {}
    for policy in read_model_policies.values():
        scoped_read_policies.setdefault(policy["owner"], []).append(policy)

    graph: dict[str, set[str]] = {name: set() for name in contexts}
    namespace_rules = manifest.get("namespace_dependency_rules", [])
    for path in production_sources(root / "apps/comms_core"):
        text = path.read_text(encoding="utf-8")
        source_modules = MODULE_RE.findall(text)
        if not source_modules:
            continue
        if len(source_modules) > 1:
            continue
        source_module = source_modules[0]
        source_owner = declared_module_owner(
            source_module, contexts, schema_owners
        )
        if not source_owner:
            continue
        references = core_module_references(text)
        read_model_policy = read_model_policies.get(source_module)
        owner_scoped_policies = scoped_read_policies.get(source_owner, [])
        for target_module in sorted(references):
            target_owner = declared_module_owner(
                target_module, contexts, schema_owners
            )
            for scoped_policy in owner_scoped_policies:
                scoped_resources = (
                    scoped_policy["owner_facades"]
                    | scoped_policy["source_schemas"]
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
            if not source_namespace or not module_in_namespace(source_module, source_namespace):
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
            target_owner = declared_module_owner(
                target_module, contexts, schema_owners
            )
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
            graph[source_owner].add(target_owner)
            if target_owner not in allowed:
                violations.add(Violation("undeclared_context_edge", relative(path, root), f"{source_owner} -> {target_owner} through {', '.join(sorted(modules))}"))

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
                if any(exact_module_reference(block, schema_module) for block in spec_blocks):
                    violations.add(Violation("public_ecto_contract", relative(path, root), f"public facade specification exposes {schema_module}"))

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

    for component in strongly_connected_components(graph):
        members = set(component)
        internal_edges = sorted(
            f"{source}->{target}"
            for source in component
            for target in graph.get(source, set())
            if target in members
        )
        violations.add(
            Violation(
                "business_context_cycle",
                MANIFEST_PATH.as_posix(),
                f"members: {', '.join(component)}; "
                f"edges: {', '.join(internal_edges)}",
            )
        )

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
            violations.add(Violation("mixed_owner_migration", path_key, f"migration touches owners {', '.join(sorted(owners))}"))

    return sorted(violations)


def baseline_fingerprints(root: Path) -> set[str]:
    path = root / BASELINE_PATH
    if not path.is_file():
        return set()
    return {item["fingerprint"] for item in read_yaml(path).get("violations", [])}


def boundary_errors(root: Path) -> tuple[list[str], list[Violation]]:
    manifest_path = root / MANIFEST_PATH
    if not manifest_path.is_file():
        return [
            f"{MANIFEST_PATH.as_posix()}: required boundary manifest is missing"
        ], []
    try:
        manifest = read_yaml(manifest_path)
    except (OSError, ValueError, yaml.YAMLError) as error:
        return [f"{MANIFEST_PATH.as_posix()}: cannot load boundary manifest: {error}"], []
    violations = analyze_context_boundaries(root, manifest)
    known = baseline_fingerprints(root)
    integrity_errors = [
        violation
        for violation in violations
        if violation.rule in NON_BASELINABLE_BOUNDARY_RULES
    ]
    new = [
        violation
        for violation in violations
        if violation.rule not in NON_BASELINABLE_BOUNDARY_RULES
        and violation.fingerprint not in known
    ]
    current = {violation.fingerprint for violation in violations}
    resolved = sorted(known - current)
    errors = [
        f"READ-MODEL control violation: {violation.render()}"
        for violation in integrity_errors
    ]
    errors.extend(
        f"NEW context-boundary violation: {violation.render()}" for violation in new
    )
    errors.extend(
        f"RESOLVED context-boundary baseline fingerprint must be removed: {fingerprint}"
        for fingerprint in resolved
    )
    return errors, violations


def validate(root: Path = ROOT) -> list[str]:
    root = root.resolve()
    context_errors, _ = boundary_errors(root)
    return sorted([
        *validate_umbrella_dependencies(root),
        *validate_core_adapter_references(root),
        *validate_repo_access(root),
        *validate_owner_lifecycle_call_sites(root),
        *context_errors,
    ])


def write_baseline(root: Path, violations: list[Violation]) -> None:
    integrity_violations = [
        item
        for item in violations
        if item.rule in NON_BASELINABLE_BOUNDARY_RULES
    ]
    if integrity_violations:
        rendered = "\n".join(item.render() for item in integrity_violations)
        raise ValueError(
            "refusing to baseline non-baselinable read-model control violations:\n"
            f"{rendered}"
        )

    payload = {
        "version": 1,
        "policy": (
            "Relative to the checked-in baseline, new, changed, or resolved "
            "fingerprints fail CI; baseline edits require architecture review."
        ),
        "violations": [
            {"fingerprint": item.fingerprint, "rule": item.rule, "path": item.path, "detail": item.detail}
            for item in violations
        ],
    }
    (root / BASELINE_PATH).write_text(yaml.safe_dump(payload, sort_keys=False, width=120), encoding="utf-8")
    categories: dict[str, list[Violation]] = {}
    for item in violations:
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
        lines.extend([f"## {rule} ({len(items)})", "", "| Fingerprint | Location | Evidence |", "|---|---|---|"])
        lines.extend(f"| `{item.fingerprint}` | `{item.path}` | {item.detail.replace('|', '/')} |" for item in items)
        lines.append("")
    (root / REPORT_PATH).write_text("\n".join(lines), encoding="utf-8")


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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write-boundary-baseline", action="store_true")
    args = parser.parse_args()
    root = ROOT.resolve()
    if args.write_boundary_baseline:
        try:
            violations = write_current_baseline(root)
        except ValueError as error:
            raise SystemExit(str(error)) from error
        print(f"Wrote {len(violations)} boundary violations to {BASELINE_PATH} and {REPORT_PATH}")
        return
    context_errors, violations = boundary_errors(root)
    errors = sorted([
        *validate_umbrella_dependencies(root),
        *validate_core_adapter_references(root),
        *validate_repo_access(root),
        *validate_owner_lifecycle_call_sites(root),
        *context_errors,
    ])
    if errors:
        raise SystemExit("Architecture validation failed:\n" + "\n".join(errors))
    print(
        "Architecture validation passed: "
        f"{len(ALLOWED_UMBRELLA_DEPENDENCIES)} classified apps, "
        f"{len(REPO_ACCESS_ALLOWLIST)} explicit Repo exceptions, "
        f"{len(violations)} tracked context-boundary violations"
    )


if __name__ == "__main__":
    main()
