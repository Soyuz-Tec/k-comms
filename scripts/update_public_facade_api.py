#!/usr/bin/env python3
"""Regenerate the reviewed public-facade API inventory."""

from __future__ import annotations

from pathlib import Path

import yaml

from validate_architecture import (
    FACADE_API_PATH,
    MANIFEST_PATH,
    ROOT,
    core_module_declarations,
    module_owner,
    production_sources,
    public_definition_operations,
    read_yaml,
    released_module_sources,
    runtime_function_calls,
)


# These operations are invoked as release-console entry points from deployment
# manifests and scripts, rather than from another compiled Elixir module.
RELEASE_CONSOLE_OPERATIONS = {
    ("assert_communication_rollback_compatible!", 0),
    ("assert_guest_rollback_compatible!", 0),
    ("bootstrap", 0),
    ("instant_room_tenant_fingerprint", 0),
    ("migrate", 0),
    ("qualification_tenant", 0),
    ("remap_restored_attachment_versions", 1),
    ("rollback", 2),
    ("set_platform_role", 2),
    ("set_platform_role", 5),
    ("set_platform_role", 6),
}


def operation_token(operation: tuple[str, int]) -> str:
    return f"{operation[0]}/{operation[1]}"


def build_snapshot(root: Path) -> dict:
    manifest = read_yaml(root / MANIFEST_PATH)
    contexts = manifest["contexts"]
    module_sources = {}
    for path in production_sources(root / "apps/comms_core"):
        text = path.read_text(encoding="utf-8")
        for module in core_module_declarations(text):
            module_sources[module] = path

    facade_owners = {
        facade: context_name
        for context_name, context in contexts.items()
        for facade in context.get("public_facades", [])
    }
    public_operations = {facade: set() for facade in facade_owners}
    collaboration_operations = {facade: set() for facade in facade_owners}
    for source_module, path in released_module_sources(root).items():
        source_owner = module_owner(source_module, contexts)
        for target, function, arity in runtime_function_calls(
            path.read_text(encoding="utf-8")
        ):
            if target not in facade_owners or source_owner == facade_owners[target]:
                continue
            definitions = public_definition_operations(
                module_sources[target].read_text(encoding="utf-8")
            )
            if (function, arity) in definitions:
                target_set = (
                    collaboration_operations
                    if path.is_relative_to(root / "apps/comms_core")
                    else public_operations
                )
                target_set[target].add((function, arity))

    for declaration in manifest.get("technical_interfaces", []):
        facade = declaration.get("interface")
        if facade in public_operations:
            public_operations[facade].update(
                (operation["name"], operation["arity"])
                for operation in declaration.get("operations", [])
                if isinstance(operation, dict)
            )
    for exception in manifest.get("read_model_exceptions", []):
        for query in exception.get("access", {}).get("public_queries", []):
            facade, operation = query.rsplit(".", 1)
            function, arity = operation.rsplit("/", 1)
            if facade in collaboration_operations:
                collaboration_operations[facade].add((function, int(arity)))
    public_operations["CommsCore.Release"].update(RELEASE_CONSOLE_OPERATIONS)

    snapshot_contexts = {}
    for context_name in sorted(set(facade_owners.values())):
        facades = {}
        for facade in sorted(
            facade for facade, owner in facade_owners.items() if owner == context_name
        ):
            definitions = public_definition_operations(
                module_sources[facade].read_text(encoding="utf-8")
            )
            facades[facade] = {
                "public_operations": [
                    operation_token(operation)
                    for operation in sorted(public_operations[facade])
                ],
                "collaboration_operations": [
                    operation_token(operation)
                    for operation in sorted(
                        collaboration_operations[facade] - public_operations[facade]
                    )
                ],
                "owner_internal_operations": [
                    operation_token(operation)
                    for operation in sorted(
                        definitions
                        - public_operations[facade]
                        - collaboration_operations[facade]
                    )
                ],
            }
        snapshot_contexts[context_name] = facades
    return {"version": 1, "contexts": snapshot_contexts}


def main() -> None:
    destination = ROOT / FACADE_API_PATH
    destination.write_text(
        yaml.safe_dump(build_snapshot(ROOT), sort_keys=False, width=100),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
