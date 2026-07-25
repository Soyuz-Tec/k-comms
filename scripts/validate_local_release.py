#!/usr/bin/env python3
"""Validate the immutable, loopback-only local release composition."""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_COMPOSE = ROOT / "deploy" / "compose.local-release.yaml"
DEFAULT_RUNNER = ROOT / "scripts" / "manage_local_release.ps1"
REQUIRED_SERVICES = {"postgres", "minio", "minio-init", "livekit", "migrate", "app"}
IMMUTABLE_IMAGES = {"postgres", "minio", "minio-init", "livekit"}
EXPECTED_PORTS = {
    "minio": [
        "127.0.0.1:${K_COMMS_RELEASE_MINIO_PORT:-5900}:9000",
        "127.0.0.1:${K_COMMS_RELEASE_MINIO_CONSOLE_PORT:-5901}:9001",
    ],
    "livekit": [
        "127.0.0.1:${K_COMMS_RELEASE_LIVEKIT_SIGNAL_PORT:-7980}:7880/tcp",
        "127.0.0.1:${K_COMMS_RELEASE_LIVEKIT_TCP_PORT:-7981}:${K_COMMS_RELEASE_LIVEKIT_TCP_PORT:-7981}/tcp",
        "127.0.0.1:${K_COMMS_RELEASE_LIVEKIT_UDP_PORT:-7982}:${K_COMMS_RELEASE_LIVEKIT_UDP_PORT:-7982}/udp",
    ],
    "app": ["127.0.0.1:${K_COMMS_RELEASE_APP_PORT:-4188}:4000"],
}


def _mapping(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _function_body(document: str, name: str) -> str:
    match = re.search(
        rf"^function\s+{re.escape(name)}\s*\{{(?P<body>.*?)(?=^function\s+|\Z)",
        document,
        flags=re.IGNORECASE | re.MULTILINE | re.DOTALL,
    )
    return match.group("body") if match else ""


def _compact(document: str) -> str:
    return re.sub(r"\s+", " ", document.casefold()).strip()


def validate_local_release(
    compose_document: dict[str, Any], runner_document: str
) -> list[str]:
    errors: list[str] = []
    services = _mapping(compose_document.get("services"))
    observed = set(services)

    if observed != REQUIRED_SERVICES:
        errors.append(
            "local release services must be exactly "
            f"{sorted(REQUIRED_SERVICES)!r}; observed {sorted(observed)!r}"
        )

    if "web" in services:
        errors.append("local release must serve packaged assets from Phoenix, not Vite")

    for name in IMMUTABLE_IMAGES:
        image = str(_mapping(services.get(name)).get("image", ""))
        if "@sha256:" not in image:
            errors.append(f"service {name!r} image must be pinned by sha256 digest")

    app = _mapping(services.get("app"))
    build = _mapping(app.get("build"))
    if build.get("target") != "runtime":
        errors.append("service 'app' must build the Dockerfile runtime target")
    if build.get("dockerfile") != "Dockerfile":
        errors.append("service 'app' must build the repository Dockerfile")
    if (
        app.get("image")
        != "${K_COMMS_RELEASE_IMAGE:?K_COMMS_RELEASE_IMAGE is required}"
    ):
        errors.append("service 'app' must use the exact release image variable")
    if app.get("volumes"):
        errors.append("service 'app' must not use source or host bind mounts")
    if app.get("read_only") is not True:
        errors.append("service 'app' root filesystem must be read-only")

    app_environment = _mapping(app.get("environment"))
    if app_environment.get("K_COMMS_RUNTIME_PURPOSE") != "application":
        errors.append("service 'app' must declare the application runtime purpose")
    if app_environment.get("K_COMMS_LOCAL_RELEASE") != "true":
        errors.append(
            "service 'app' must explicitly enable the guarded local-release mode"
        )
    if app_environment.get("ALLOW_DEVELOPMENT_ADAPTERS") != "true":
        errors.append(
            "service 'app' must explicitly pair local-release mode with the "
            "development-adapter gate"
        )
    if app_environment.get("AUDIO_PROVIDER_MODE") != "livekit":
        errors.append("service 'app' must use the local LiveKit media plane")
    if app_environment.get("LIVEKIT_API_URL") != "http://livekit:7880":
        errors.append(
            "service 'app' must use only the internal livekit:7880 API origin"
        )

    livekit = _mapping(services.get("livekit"))
    livekit_command = [str(value) for value in _list(livekit.get("command"))]
    for required in (
        "--node-ip",
        "127.0.0.1",
        "--rtc.tcp_port",
        "${K_COMMS_RELEASE_LIVEKIT_TCP_PORT:-7981}",
        "--udp-port",
        "${K_COMMS_RELEASE_LIVEKIT_UDP_PORT:-7982}",
    ):
        if required not in livekit_command:
            errors.append(
                "service 'livekit' command must include local media setting "
                f"{required!r}"
            )
    if "--rtc.enable_loopback_candidate" in livekit_command:
        errors.append(
            "service 'livekit' must not enable the explicit loopback candidate "
            "flag because it prevents Podman Desktop TCP media negotiation"
        )

    migrate = _mapping(services.get("migrate"))
    migrate_environment = _mapping(migrate.get("environment"))
    if migrate.get("image") != app.get("image"):
        errors.append(
            "migration and application services must use the same exact image"
        )
    if migrate.get("command") != ["eval", "CommsCore.Release.migrate()"]:
        errors.append("migration service must run only CommsCore.Release.migrate()")
    if migrate_environment.get("K_COMMS_RUNTIME_PURPOSE") != "one_shot":
        errors.append("migration service must use the one-shot runtime purpose")
    if migrate_environment.get("K_COMMS_LOCAL_RELEASE") != "false":
        errors.append("migration service must not enable the application exception")
    required_migration_environment = {
        "K_COMMS_MIGRATION_LOCK_TIMEOUT_MS": "5000",
        "K_COMMS_MIGRATION_STATEMENT_TIMEOUT_MS": "480000",
        "K_COMMS_MIGRATION_REQUIRE_QUIESCENCE": "true",
    }
    for name, expected in required_migration_environment.items():
        if str(migrate_environment.get(name, "")) != expected:
            errors.append(
                f"migration service must set {name}={expected} for bounded, "
                "quiesced migrations"
            )

    for name, expected in EXPECTED_PORTS.items():
        observed_ports = [
            str(value) for value in _list(_mapping(services.get(name)).get("ports"))
        ]
        if observed_ports != expected:
            errors.append(
                f"service {name!r} ports must be {expected!r}; "
                f"observed {observed_ports!r}"
            )

    for name in ("postgres", "minio-init", "migrate"):
        if _mapping(services.get(name)).get("ports"):
            errors.append(f"service {name!r} must not publish a host port")

    lowered_runner = runner_document.casefold()
    if (
        "mix ecto.rollback" in lowered_runner
        or "commscore.release.rollback" in lowered_runner
        or "ecto.migrator.run" in lowered_runner
    ):
        errors.append("local release orchestration must never run down migrations")
    if 'compose", "down' in lowered_runner or "down --volumes" in lowered_runner:
        errors.append(
            "local release orchestration must retain stateful services and volumes"
        )
    for required_marker in (
        "--target",
        "runtime",
        "org.opencontainers.image.revision",
        "compose.rendered.yaml",
        "previousreceiptpath",
        "/health/ready",
    ):
        if required_marker.casefold() not in lowered_runner:
            errors.append(
                f"local release orchestrator is missing required marker {required_marker!r}"
            )

    hardening_markers = {
        ".k-comms-local-release-state-v1.json": (
            "local release orchestrator must require a tool-owned state marker"
        ),
        "assert-safestaterootpath": (
            "local release orchestrator must reject dangerous state roots before ACL changes"
        ),
        "assert-noreparsepointancestors": (
            "custom state roots must reject every existing reparse-point ancestor"
        ),
        "reparsepoint": (
            "local release orchestrator must reject reparse-point state roots and markers"
        ),
        "[io.fileshare]::none": (
            "local release orchestrator must hold an exclusive state operation lock"
        ),
        "local\\kcomms.localrelease.": (
            "local release orchestrator must hold a Compose-project operation mutex"
        ),
        "compose.source.yaml": (
            "local release orchestrator must retain the candidate Compose source"
        ),
        "environmentsha256": (
            "local release orchestrator must hash the retained release environment"
        ),
        "composesourcesha256": (
            "local release orchestrator must hash the retained Compose source"
        ),
        "$candidatenonce": (
            "release image tags must include a unique candidate attempt identifier"
        ),
        "remove-failedcandidateruntime": (
            "a failed first deployment must clean up its complete candidate runtime"
        ),
        "observed application state": (
            "status must distinguish recorded release evidence from observed runtime state"
        ),
        "assert-livekitimageflags": (
            "local release validation must check flags against the exact pinned LiveKit image"
        ),
        "help-verbose": (
            "local release validation must inspect the exact pinned LiveKit flag surface"
        ),
        "assert-candidateports": (
            "deploy and start must preflight unique, available loopback ports"
        ),
        "invoke-portpreflightselftest": (
            "local release validation must execute port preflight self-tests"
        ),
    }
    for marker, error in hardening_markers.items():
        if marker not in lowered_runner:
            errors.append(error)

    restore_start = lowered_runner.find("function restore-release")
    restore_end = lowered_runner.find("\nfunction ", restore_start + 1)
    restore_body = (
        lowered_runner[restore_start:restore_end]
        if restore_start >= 0 and restore_end > restore_start
        else ""
    )
    if "-composepath $receipt.composesourcepath" not in restore_body:
        errors.append(
            "restore and lifecycle operations must use the retained Compose source"
        )

    if 'localhost/k-comms:sha-$revision"' in lowered_runner:
        errors.append(
            "release image tags must be unique per candidate so a repeated revision "
            "cannot invalidate predecessor rollback"
        )

    source_body = _compact(
        _function_body(runner_document, "New-ImmutableSourceContext")
    )
    if not source_body:
        errors.append(
            "release builds must capture an immutable Git source context"
        )
    else:
        if '"archive", "--format=tar"' not in source_body:
            errors.append(
                "immutable release source must be created with git archive"
            )
        if '-filepath "tar"' not in source_body or '"-xf"' not in source_body:
            errors.append(
                "immutable release source archive must be extracted into an isolated context"
            )
        if "source.archive.tar" not in source_body or "archivesha256" not in source_body:
            errors.append(
                "immutable release source archive must be retained and hashed"
            )
        if source_body.count("assert-repositoryhead") < 2:
            errors.append(
                "immutable source capture must verify repository HEAD before and after archiving"
            )

    deploy_body = _compact(_function_body(runner_document, "Invoke-DeployLocked"))
    wait_application_body = _compact(
        _function_body(runner_document, "Wait-Application")
    )
    application_capabilities_body = _compact(
        _function_body(runner_document, "Assert-ApplicationCapabilities")
    )
    capability_self_test_body = _compact(
        _function_body(runner_document, "Invoke-CapabilityCompatibilitySelfTest")
    )
    guest_rollback_probe_body = _compact(
        _function_body(runner_document, "Get-GuestRollbackHazards")
    )
    guest_rollback_quiesce_body = _compact(
        _function_body(runner_document, "Stop-ApplicationForGuestRollbackProbe")
    )
    guest_rollback_safe_body = _compact(
        _function_body(runner_document, "Assert-GuestRollbackSafe")
    )
    guest_rollback_self_test_body = _compact(
        _function_body(runner_document, "Invoke-GuestRollbackCompatibilitySelfTest")
    )
    rollback_restore_body = _compact(
        _function_body(runner_document, "Restore-RollbackTargetOrCurrent")
    )
    migration_quiesce_body = _compact(
        _function_body(runner_document, "Stop-ApplicationForMigration")
    )
    start_release_body = _compact(
        _function_body(runner_document, "Start-ReleaseServices")
    )
    validate_body = _compact(_function_body(runner_document, "Invoke-Validate"))
    restore_body = _compact(_function_body(runner_document, "Restore-Release"))
    rollback_body = _compact(_function_body(runner_document, "Invoke-RollbackLocked"))
    if (
        "[switch]$requireguestlinks" not in wait_application_body
        or "assert-applicationcapabilities" not in wait_application_body
        or "[switch]$requireguestlinks" not in application_capabilities_body
        or '$capabilities.psobject.properties["guest_links"]'
        not in application_capabilities_body
    ):
        errors.append(
            "candidate health checks must support explicit guest-links capability enforcement"
        )
    if (
        "invoke-capabilitycompatibilityselftest" not in validate_body
        or "assert-applicationcapabilities -status $predecessor"
        not in capability_self_test_body
        or "-status $predecessor ` -requireguestlinks"
        not in capability_self_test_body
        or "assert-applicationcapabilities -status $candidate -requireguestlinks"
        not in capability_self_test_body
    ):
        errors.append(
            "release validation must execute predecessor and candidate capability self-tests"
        )
    migration_quiesce_position = start_release_body.find(
        "stop-applicationformigration"
    )
    migration_run_position = start_release_body.find(
        '@("run", "--rm", "--no-deps", "migrate")'
    )
    if (
        '-arguments @("stop", "app")' not in migration_quiesce_body
        or '"ps", "--services", "--status", "running"'
        not in migration_quiesce_body
        or '$runningservices -contains "app"' not in migration_quiesce_body
        or migration_quiesce_position < 0
        or migration_run_position < 0
        or migration_quiesce_position > migration_run_position
    ):
        errors.append(
            "forward migrations must stop and verify the application before "
            "the bounded migration runner starts"
        )
    if "-requireguestlinks" not in deploy_body:
        errors.append(
            "candidate deployment must require the guest-links capability before sealing"
        )
    if "-requireguestlinks" in restore_body:
        errors.append(
            "predecessor restore must not require capabilities introduced by the candidate"
        )
    if (
        "rollbackcapabilities = @(" not in deploy_body
        or '"guest_identity_v1"' not in deploy_body
        or '"guest_admission_expiry_worker_v1"' not in deploy_body
    ):
        errors.append(
            "release receipts must declare guest identity and expiry-worker rollback compatibility"
        )
    if (
        '-arguments @("stop", "app")' not in guest_rollback_quiesce_body
        or '"ps", "--services", "--status", "running"'
        not in guest_rollback_quiesce_body
        or '$runningservices -contains "app"' not in guest_rollback_quiesce_body
    ):
        errors.append(
            "legacy guest rollback preflight must quiesce and verify the current application"
        )
    if (
        "account_type = 'guest'" not in guest_rollback_probe_body
        or "commsworkers.guestadmissionexpiryworker" not in guest_rollback_probe_body
        or "('available', 'scheduled', 'executing', 'retryable')"
        not in guest_rollback_probe_body
        or '"psql"' not in guest_rollback_probe_body
    ):
        errors.append(
            "guest rollback preflight must query persisted guest identities and active expiry jobs"
        )
    if (
        "test-receiptsupportsguestrollback" not in guest_rollback_safe_body
        or "stop-applicationforguestrollbackprobe" not in guest_rollback_safe_body
        or "get-guestrollbackhazards" not in guest_rollback_safe_body
        or "assert-guestrollbackcompatibility" not in guest_rollback_safe_body
        or "restore-release -receipt $currentreceipt -updatepointer"
        not in guest_rollback_safe_body
        or "[switch]$restorecurrentonfailure" not in guest_rollback_safe_body
        or "currentcompatible" not in guest_rollback_safe_body
        or "recorded current receipt also lacks" not in guest_rollback_safe_body
        or "remains quiesced" not in guest_rollback_safe_body
    ):
        errors.append(
            "guest rollback preflight must quiesce legacy writes, evaluate hazards, and restore the current receipt on a manual block"
        )
    rollback_guard_position = rollback_body.find("assert-guestrollbacksafe")
    rollback_restore_position = rollback_body.find(
        "restore-rollbacktargetorcurrent"
    )
    if (
        rollback_guard_position < 0
        or rollback_restore_position < 0
        or rollback_guard_position > rollback_restore_position
        or "assert-retainedreleaseassets -receipt $current" not in rollback_body
        or "-restorecurrentonfailure" not in rollback_body
        or "assert-guestrollbacksafe" not in deploy_body
        or "$migrationsucceeded" not in deploy_body
    ):
        errors.append(
            "manual and post-migration automatic rollback must guard legacy predecessors before restore"
        )
    if (
        "restore-release -receipt $targetreceipt -updatepointer"
        not in rollback_restore_body
        or "restore-release -receipt $currentreceipt -updatepointer"
        not in rollback_restore_body
        or "target restore failed" not in rollback_restore_body
        or "restored and passed health checks" not in rollback_restore_body
    ):
        errors.append(
            "manual rollback must recover the exact current receipt when target restore fails"
        )
    if (
        "invoke-guestrollbackcompatibilityselftest" not in validate_body
        or "assert-guestrollbackcompatibility" not in guest_rollback_self_test_body
        or "legacyhazardrejected" not in guest_rollback_self_test_body
        or "synthetic guest rollback probe failure" not in guest_rollback_self_test_body
        or "synthetic current release restart failure"
        not in guest_rollback_self_test_body
        or "synthetic target restore failure" not in guest_rollback_self_test_body
        or "synthetic current recovery failure" not in guest_rollback_self_test_body
        or "stalelegacyremainedquiesced" not in guest_rollback_self_test_body
        or "stalelegacyrestorestate.restores -ne 0"
        not in guest_rollback_self_test_body
    ):
        errors.append(
            "release validation must exercise guest rollback compatibility self-tests"
        )
    if "-workingdirectory $source.contextpath" not in deploy_body:
        errors.append(
            "release image build must use the isolated immutable source context"
        )
    if (
        "$snapshotcomposepath" not in deploy_body
        or 'join-path $source.contextpath "deploy\\compose.local-release.yaml"'
        not in deploy_body
    ):
        errors.append(
            "retained candidate Compose source must come from the immutable Git snapshot"
        )
    build_position = deploy_body.find('"build",')
    post_build_head_position = deploy_body.find(
        "assert-repositoryhead", build_position + 1
    )
    if build_position < 0 or post_build_head_position < 0:
        errors.append(
            "release image build must verify repository HEAD after the immutable build"
        )
    if "sourcearchivesha256" not in deploy_body:
        errors.append(
            "release receipt must bind the image to the retained source archive hash"
        )
    port_preflight_position = deploy_body.find("assert-candidateports")
    if (
        port_preflight_position < 0
        or build_position < 0
        or port_preflight_position > build_position
    ):
        errors.append(
            "candidate port uniqueness and availability must be checked before image build"
        )

    cleanup_body = _compact(
        _function_body(runner_document, "Remove-FailedCandidateRuntime")
    )
    if not cleanup_body:
        errors.append(
            "a failed first deployment must define complete candidate-runtime cleanup"
        )
    else:
        for service in (
            "app",
            "migrate",
            "minio-init",
            "livekit",
            "minio",
            "postgres",
        ):
            if f'"{service}"' not in cleanup_body:
                errors.append(
                    f"first-candidate failure cleanup must include service {service!r}"
                )
        if '-arguments @("stop", $service)' not in cleanup_body:
            errors.append(
                "first-candidate failure cleanup must stop every candidate service"
            )
        if '-arguments @("rm", "--force", $service)' not in cleanup_body:
            errors.append(
                "first-candidate failure cleanup must remove every candidate service"
            )
        if '-arguments @("ps", "--all", "--quiet")' not in cleanup_body:
            errors.append(
                "first-candidate failure cleanup must verify that no candidate containers remain"
            )
        if "$remaining.output.trim()" not in cleanup_body:
            errors.append(
                "first-candidate failure cleanup must fail when candidate containers remain"
            )

    if "remove-failedcandidateruntime" not in deploy_body:
        errors.append(
            "first-candidate deployment failure must invoke complete runtime cleanup"
        )

    if '$env:podman_compose_warning_logs = "false"' not in lowered_runner:
        errors.append(
            "Podman Compose provider warnings must be suppressed before parsing "
            "machine-readable command output"
        )

    environment_reader = _compact(
        _function_body(runner_document, "Read-EnvironmentFile")
    )
    if (
        '$line.indexof("=")' not in environment_reader
        or "$line.substring(0, $separatorindex)" not in environment_reader
        or "$line.substring($separatorindex + 1)" not in environment_reader
    ):
        errors.append(
            "environment-file parsing must use PowerShell 5.1-compatible index and "
            "substring operations"
        )

    safe_state_body = _compact(
        _function_body(runner_document, "Assert-SafeStateRootPath")
    )
    ancestor_body = _compact(
        _function_body(runner_document, "Assert-NoReparsePointAncestors")
    )
    if (
        "$customstaterootrequested" not in safe_state_body
        or "assert-noreparsepointancestors" not in safe_state_body
    ):
        errors.append(
            "custom state-root validation must inspect all existing ancestors"
        )
    if (
        not ancestor_body
        or "[io.directoryinfo]::new" not in ancestor_body
        or ".parent" not in ancestor_body
        or "[io.file]::getattributes" not in ancestor_body
        or ".innerexception" not in ancestor_body
        or "[io.filenotfoundexception]" not in ancestor_body
        or "[io.fileattributes]::reparsepoint" not in ancestor_body
    ):
        errors.append(
            "custom state-root ancestor validation must inspect path entries through "
            "the filesystem root and reject reparse points"
        )
    protect_state_body = _compact(
        _function_body(runner_document, "Protect-StateDirectory")
    )
    initialize_state_body = _compact(
        _function_body(runner_document, "Initialize-OwnedStateDirectory")
    )
    state_self_test_body = _compact(
        _function_body(runner_document, "Invoke-StateRootSafetySelfTest")
    )
    create_position = initialize_state_body.find(
        "new-item -itemtype directory -path $path"
    )
    post_create_position = initialize_state_body.find(
        "assert-safestaterootpath -path $path", create_position + 1
    )
    marker_position = initialize_state_body.find(
        "$markerpath = get-stateownershipmarkerpath", create_position + 1
    )
    if (
        create_position < 0
        or post_create_position < 0
        or marker_position < 0
        or post_create_position > marker_position
        or "assert-safestaterootpath -path $path" not in protect_state_body
    ):
        errors.append(
            "state-root paths must be revalidated after creation and immediately "
            "before ACL mutation"
        )
    if (
        "initialize-ownedstatedirectory" not in state_self_test_body
        or "-path $nestedunderjunction" not in state_self_test_body
        or "$script:customstaterootrequested = $true" not in state_self_test_body
        or "-path $safecustompath" not in state_self_test_body
    ):
        errors.append(
            "state-root self-test must exercise rejected junction traversal and "
            "accepted non-existent custom-path initialization"
        )

    cleanup_self_test_body = _compact(
        _function_body(runner_document, "Invoke-FailedCandidateCleanupSelfTest")
    )
    if "invoke-failedcandidatecleanupselftest" not in validate_body:
        errors.append(
            "local release validation must execute first-candidate cleanup self-tests"
        )
    if (
        "invoke-failedcandidatecleanupselftest" not in validate_body
        or "remove-failedcandidateruntime" not in cleanup_self_test_body
        or "-composeinvoker $successfulinvoker" not in cleanup_self_test_body
        or "unexpected-candidate-container" not in cleanup_self_test_body
    ):
        errors.append(
            "first-candidate cleanup must have an executable self-test for complete "
            "service removal and remaining-container rejection"
        )

    port_body = _compact(_function_body(runner_document, "Assert-CandidatePorts"))
    if (
        "group-object -property port" not in port_body
        or "test-loopbackportavailable" not in port_body
    ):
        errors.append(
            "candidate port preflight must enforce uniqueness and loopback availability"
        )
    if (
        "get-runningretainedservices" not in port_body
        or "ownedbyretainedrelease" not in port_body
        or "test-retainedserviceownsport" not in port_body
    ):
        errors.append(
            "candidate port preflight must only exempt verified port mappings owned by "
            "the retained release"
        )

    start_entry = _compact(_function_body(runner_document, "Invoke-Start"))
    start_body = _compact(_function_body(runner_document, "Invoke-StartLocked"))
    compact_runner = _compact(runner_document)
    if (
        '"start"' not in compact_runner.split("[validateset(", 1)[-1].split(")]", 1)[0]
        or '"start" { invoke-start }' not in compact_runner
    ):
        errors.append(
            "local release actions must expose the supported Start lifecycle action"
        )
    if (
        "enter-releaseoperationlock" not in start_entry
        or "invoke-startlocked" not in start_entry
    ):
        errors.append(
            "Start must hold the same exclusive release-operation lock as other mutations"
        )
    if (
        "get-currentreceipt" not in start_body
        or "assert-immutablerestartreceipt" not in start_body
        or "assert-candidateports" not in start_body
        or "restore-release" not in start_body
        or "-runmigration" not in start_body
        or "-updatepointer" not in start_body
    ):
        errors.append(
            "Start must restart the current retained receipt with forward migration and health checks"
        )
    start_guard_position = start_body.find("assert-guestrollbacksafe")
    start_restore_position = start_body.find("restore-release")
    if (
        start_guard_position < 0
        or start_restore_position < 0
        or start_guard_position > start_restore_position
        or "-currentreceipt $current" not in start_body
        or "-targetreceipt $current" not in start_body
    ):
        errors.append(
            "Start must fail closed before activating a guest-incompatible retained receipt"
        )
    if (
        '"build",' in start_entry
        or '"build",' in start_body
        or "$composefile" in start_entry
        or "$composefile" in start_body
        or "assert-cleanrevision" in start_entry
        or "assert-cleanrevision" in start_body
    ):
        errors.append(
            "Start must never rebuild or depend on mutable checkout source"
        )
    if (
        "assert-retainedreleaseassets -receipt $receipt" not in restore_body
        or "-composepath $receipt.composesourcepath" not in restore_body
        or "-expectedrevision $receipt.revision" not in restore_body
        or "$receipt.imageid" not in restore_body
        or "$receipt.imagedigest" not in restore_body
        or "-runmigration:$runmigration" not in restore_body
    ):
        errors.append(
            "retained release startup must validate assets, image identity, digest, and use its retained migration path"
        )

    return errors


def validate_paths(compose_path: Path, runner_path: Path) -> list[str]:
    compose_document = yaml.safe_load(compose_path.read_text(encoding="utf-8"))
    if not isinstance(compose_document, dict):
        return [f"{compose_path}: Compose document must be a mapping"]
    return validate_local_release(
        compose_document, runner_path.read_text(encoding="utf-8")
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate the immutable local release composition and runner."
    )
    parser.add_argument("--compose", type=Path, default=DEFAULT_COMPOSE)
    parser.add_argument("--runner", type=Path, default=DEFAULT_RUNNER)
    arguments = parser.parse_args()

    errors = validate_paths(arguments.compose, arguments.runner)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(
        "Immutable local release policy passed: "
        f"{arguments.compose} + {arguments.runner}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
