#!/usr/bin/env python3
"""Enforce the K-Comms umbrella and persistence architecture boundaries."""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# These are allowed edges, not required edges. Adding an umbrella application or
# a new edge is an architecture decision and must update this policy and its docs.
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

# Direct Repo access outside comms_core is denied unless the exact source is
# non-release test infrastructure with a deliberately narrow reason.
REPO_ACCESS_ALLOWLIST: dict[str, str] = {
    "apps/comms_test_support/lib/comms_test_support/fixtures.ex": (
        "non-release test fixture setup"
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


def relative(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def production_sources(app_dir: Path) -> list[Path]:
    source_root = app_dir / "lib"
    if not source_root.is_dir():
        return []
    return sorted((*source_root.rglob("*.ex"), *source_root.rglob("*.exs")))


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
        forbidden = dependencies - ALLOWED_UMBRELLA_DEPENDENCIES[app]
        for dependency in sorted(forbidden):
            errors.append(
                f"{relative(mix_path, root)}: forbidden umbrella dependency "
                f"{app} -> {dependency}"
            )

    return errors


def validate_core_adapter_references(root: Path) -> list[str]:
    errors: list[str] = []
    core_dir = root / "apps" / "comms_core"
    for path in production_sources(core_dir):
        text = path.read_text(encoding="utf-8")
        for line_number, line in enumerate(text.splitlines(), start=1):
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

    missing_allowlist_entries = sorted(
        path for path in REPO_ACCESS_ALLOWLIST if not (root / path).is_file()
    )
    for path in missing_allowlist_entries:
        errors.append(f"{path}: Repo-access allowlist entry does not exist")

    unused_allowlist_entries = sorted(
        set(REPO_ACCESS_ALLOWLIST)
        - set(missing_allowlist_entries)
        - observed_allowlist_entries
    )
    for path in unused_allowlist_entries:
        errors.append(f"{path}: Repo-access allowlist entry is no longer used")

    return errors


def validate(root: Path = ROOT) -> list[str]:
    root = root.resolve()
    errors = [
        *validate_umbrella_dependencies(root),
        *validate_core_adapter_references(root),
        *validate_repo_access(root),
    ]
    return sorted(errors)


def main() -> None:
    errors = validate()
    if errors:
        raise SystemExit("Architecture validation failed:\n" + "\n".join(errors))

    print(
        "Architecture validation passed: "
        f"{len(ALLOWED_UMBRELLA_DEPENDENCIES)} classified apps, "
        f"{len(REPO_ACCESS_ALLOWLIST)} explicit Repo exceptions"
    )


if __name__ == "__main__":
    main()
