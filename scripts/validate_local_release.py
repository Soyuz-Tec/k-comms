#!/usr/bin/env python3
"""Validate the immutable local or explicit-private-LAN release composition."""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_COMPOSE = ROOT / "deploy" / "compose.local-release.yaml"
DEFAULT_RUNNER = ROOT / "scripts" / "manage_local_release.ps1"
REQUIRED_SERVICES = {
    "postgres",
    "minio",
    "minio-init",
    "livekit",
    "migrate",
    "bootstrap",
    "qualification",
    "app",
}
IMMUTABLE_IMAGES = {"postgres", "minio", "minio-init", "livekit"}
EXPECTED_PORTS = {
    "minio": [
        "${K_COMMS_PODMAN_BIND_ADDRESS:-127.0.0.1}:${K_COMMS_RELEASE_MINIO_PORT:-5900}:9000",
        "127.0.0.1:${K_COMMS_RELEASE_MINIO_CONSOLE_PORT:-5901}:9001",
    ],
    "livekit": [
        "${K_COMMS_PODMAN_BIND_ADDRESS:-127.0.0.1}:${K_COMMS_RELEASE_LIVEKIT_SIGNAL_PORT:-7980}:7880/tcp",
        "${K_COMMS_PODMAN_BIND_ADDRESS:-127.0.0.1}:${K_COMMS_RELEASE_LIVEKIT_TCP_PORT:-7981}:${K_COMMS_RELEASE_LIVEKIT_TCP_PORT:-7981}/tcp",
        "${K_COMMS_PODMAN_BIND_ADDRESS:-127.0.0.1}:${K_COMMS_RELEASE_LIVEKIT_UDP_PORT:-7982}:${K_COMMS_RELEASE_LIVEKIT_UDP_PORT:-7982}/udp",
    ],
    "app": [
        "${K_COMMS_PODMAN_BIND_ADDRESS:-127.0.0.1}:${K_COMMS_RELEASE_APP_PORT:-4188}:4000"
    ],
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


def _compact_powershell(document: str) -> str:
    """Compact PowerShell while ignoring line-continuation backticks."""

    return _compact(document.replace("`", ""))


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
    if app_environment.get("ALLOW_BOOTSTRAP") != "${ALLOW_BOOTSTRAP:-false}":
        errors.append(
            "service 'app' must default the public bootstrap endpoint to disabled"
        )
    required_network_environment = {
        "K_COMMS_PODMAN_BIND_ADDRESS": (
            "${K_COMMS_PODMAN_BIND_ADDRESS:-127.0.0.1}"
        ),
        "K_COMMS_RELEASE_HOST": "${K_COMMS_RELEASE_HOST:-127.0.0.1}",
        "K_COMMS_LIVEKIT_NODE_IP": "${K_COMMS_LIVEKIT_NODE_IP:-127.0.0.1}",
        "K_COMMS_LOCAL_RELEASE_HOST": "${K_COMMS_LOCAL_RELEASE_HOST:-}",
        "K_COMMS_RELEASE_EXPOSURE_MODE": (
            "${K_COMMS_RELEASE_EXPOSURE_MODE:-}"
        ),
        "K_COMMS_TRUSTED_EDGE_CONFIRMATION": (
            "${K_COMMS_TRUSTED_EDGE_CONFIRMATION:-}"
        ),
        "PHX_HOST": "${K_COMMS_RELEASE_HOST:-127.0.0.1}",
        "HSTS_ENABLED": "${HSTS_ENABLED:-false}",
        "TRUSTED_PROXY_CIDRS": "${TRUSTED_PROXY_CIDRS:-}",
    }
    for name, expected in required_network_environment.items():
        if str(app_environment.get(name, "")) != expected:
            errors.append(
                f"service 'app' must pass exact selected release topology "
                f"{name}={expected}"
            )
    if "K_COMMS_RELEASE_BIND_ADDRESS" in app_environment:
        errors.append(
            "service 'app' must not receive the legacy direct-bind variable "
            "K_COMMS_RELEASE_BIND_ADDRESS"
        )
    required_instant_room_environment = {
        "INSTANT_ROOMS_ENABLED": "${INSTANT_ROOMS_ENABLED:-true}",
        "INSTANT_ROOM_TENANT_SLUG": (
            "${INSTANT_ROOM_TENANT_SLUG:-k-comms-development}"
        ),
        "INSTANT_ROOM_GUEST_IDLE_TTL_SECONDS": (
            "${INSTANT_ROOM_GUEST_IDLE_TTL_SECONDS:-3600}"
        ),
        "INSTANT_ROOM_REGISTERED_IDLE_TTL_SECONDS": (
            "${INSTANT_ROOM_REGISTERED_IDLE_TTL_SECONDS:-86400}"
        ),
        "INSTANT_ROOM_PRESENCE_HEARTBEAT_SECONDS": (
            "${INSTANT_ROOM_PRESENCE_HEARTBEAT_SECONDS:-30}"
        ),
        "INSTANT_ROOM_PRESENCE_LEASE_SECONDS": (
            "${INSTANT_ROOM_PRESENCE_LEASE_SECONDS:-90}"
        ),
        "INSTANT_ROOM_RECONNECT_GRACE_SECONDS": (
            "${INSTANT_ROOM_RECONNECT_GRACE_SECONDS:-90}"
        ),
        "INSTANT_ROOM_MAX_PARTICIPANTS": (
            "${INSTANT_ROOM_MAX_PARTICIPANTS:-25}"
        ),
    }
    for name, expected in required_instant_room_environment.items():
        if str(app_environment.get(name, "")) != expected:
            errors.append(
                f"service 'app' must set {name}={expected} for bounded "
                "instant-room qualification"
            )

    livekit = _mapping(services.get("livekit"))
    livekit_command = [str(value) for value in _list(livekit.get("command"))]
    for required in (
        "--node-ip",
        "${K_COMMS_LIVEKIT_NODE_IP:-127.0.0.1}",
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
        "K_COMMS_RELEASE_EXPOSURE_MODE": "",
        "K_COMMS_TRUSTED_EDGE_CONFIRMATION": "",
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

    bootstrap = _mapping(services.get("bootstrap"))
    bootstrap_environment = _mapping(bootstrap.get("environment"))
    if bootstrap.get("image") != app.get("image"):
        errors.append(
            "bootstrap and application services must use the same exact image"
        )
    if bootstrap.get("command") != ["eval", "CommsCore.Release.bootstrap()"]:
        errors.append(
            "bootstrap service must run only CommsCore.Release.bootstrap()"
        )
    if bootstrap.get("read_only") is not True:
        errors.append("bootstrap service root filesystem must be read-only")
    expected_bootstrap_environment = {
        "K_COMMS_ROLE": "worker",
        "K_COMMS_RUNTIME_PURPOSE": "one_shot",
        "K_COMMS_LOCAL_RELEASE": "false",
        "K_COMMS_RELEASE_EXPOSURE_MODE": "",
        "K_COMMS_TRUSTED_EDGE_CONFIRMATION": "",
        "ALLOW_BOOTSTRAP": "false",
        "BOOTSTRAP_TENANT_NAME": (
            "${BOOTSTRAP_TENANT_NAME:?BOOTSTRAP_TENANT_NAME is required}"
        ),
        "BOOTSTRAP_TENANT_SLUG": (
            "${BOOTSTRAP_TENANT_SLUG:?BOOTSTRAP_TENANT_SLUG is required}"
        ),
        "BOOTSTRAP_OWNER_DISPLAY_NAME": (
            "${BOOTSTRAP_OWNER_DISPLAY_NAME:"
            "?BOOTSTRAP_OWNER_DISPLAY_NAME is required}"
        ),
        "BOOTSTRAP_OWNER_EMAIL": (
            "${BOOTSTRAP_OWNER_EMAIL:?BOOTSTRAP_OWNER_EMAIL is required}"
        ),
        "BOOTSTRAP_OWNER_PASSWORD": (
            "${BOOTSTRAP_OWNER_PASSWORD:?BOOTSTRAP_OWNER_PASSWORD is required}"
        ),
    }
    for name, expected in expected_bootstrap_environment.items():
        if str(bootstrap_environment.get(name, "")) != expected:
            errors.append(
                f"bootstrap service must set {name}={expected} for sealed "
                "one-shot tenant provisioning"
            )

    qualification = _mapping(services.get("qualification"))
    qualification_environment = _mapping(qualification.get("environment"))
    if qualification.get("image") != app.get("image"):
        errors.append(
            "qualification and application services must use the same exact image"
        )
    if qualification.get("command") != [
        "eval",
        "CommsCore.Release.qualification_tenant()",
    ]:
        errors.append(
            "qualification service must run only "
            "CommsCore.Release.qualification_tenant()"
        )
    if qualification.get("read_only") is not True:
        errors.append("qualification service root filesystem must be read-only")
    expected_qualification_environment = {
        "K_COMMS_ROLE": "worker",
        "K_COMMS_RUNTIME_PURPOSE": "one_shot",
        "K_COMMS_LOCAL_RELEASE": "false",
        "K_COMMS_RELEASE_EXPOSURE_MODE": "",
        "K_COMMS_TRUSTED_EDGE_CONFIRMATION": "",
        "ALLOW_BOOTSTRAP": "false",
        "K_COMMS_QUALIFICATION_ACTION": "${K_COMMS_QUALIFICATION_ACTION:-}",
        "K_COMMS_QUALIFICATION_ID": "${K_COMMS_QUALIFICATION_ID:-}",
        "K_COMMS_QUALIFICATION_PASSWORD": (
            "${K_COMMS_QUALIFICATION_PASSWORD:-}"
        ),
        "K_COMMS_QUALIFICATION_CONFIRMATION": (
            "${K_COMMS_QUALIFICATION_CONFIRMATION:-}"
        ),
        "K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION": (
            "${K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION:-}"
        ),
    }
    for name, expected in expected_qualification_environment.items():
        if str(qualification_environment.get(name, "")) != expected:
            errors.append(
                f"qualification service must set {name}={expected} for "
                "bounded isolated qualification-tenant lifecycle"
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

    podman_bind_prefix = "${K_COMMS_PODMAN_BIND_ADDRESS:-127.0.0.1}:"
    minio_console_mapping = (
        "127.0.0.1:${K_COMMS_RELEASE_MINIO_CONSOLE_PORT:-5901}:9001"
    )
    unsafe_published_ports = []
    for service_name in ("app", "minio", "livekit"):
        for port_mapping in _list(
            _mapping(services.get(service_name)).get("ports")
        ):
            rendered_mapping = str(port_mapping)
            if (
                rendered_mapping != minio_console_mapping
                and not rendered_mapping.startswith(podman_bind_prefix)
            ):
                unsafe_published_ports.append(
                    f"{service_name}:{rendered_mapping}"
                )
    if unsafe_published_ports:
        errors.append(
            "all Podman-published application, object, and media ports must use "
            "only K_COMMS_PODMAN_BIND_ADDRESS with a 127.0.0.1 default; wildcard "
            "and direct RFC1918 binds are forbidden; observed "
            f"{unsafe_published_ports!r}"
        )

    for name in (
        "postgres",
        "minio-init",
        "migrate",
        "bootstrap",
        "qualification",
    ):
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
            "deploy and start must preflight unique ports on the selected bind address"
        ),
        "resolve-releasebindaddress": (
            "local release orchestration must validate an explicit safe bind address"
        ),
        "invoke-bindaddressselftest": (
            "local release validation must execute bind-address policy self-tests"
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

    compose_interpolation_names_body = _compact_powershell(
        _function_body(runner_document, "Get-ComposeInterpolationNames")
    )
    sealed_compose_environment_body = _compact_powershell(
        _function_body(runner_document, "Invoke-WithSealedComposeEnvironment")
    )
    invoke_compose_body = _compact_powershell(
        _function_body(runner_document, "Invoke-Compose")
    )
    start_sealed_application_body = _compact_powershell(
        _function_body(runner_document, "Start-SealedApplication")
    )
    prepare_trusted_application_body = _compact_powershell(
        _function_body(
            runner_document,
            "Prepare-SealedTrustedEdgeApplication",
        )
    )
    start_release_services_body = _compact_powershell(
        _function_body(runner_document, "Start-ReleaseServices")
    )
    if (
        "[collections.generic.hashset[string]]::new("
        not in compose_interpolation_names_body
        or "[stringcomparer]::ordinalignorecase"
        not in compose_interpolation_names_body
        or "[regex]::matches(" not in compose_interpolation_names_body
        or r"\$\{(?<name>[a-za-z_][a-za-z0-9_]*)[^}]*\}"
        not in compose_interpolation_names_body
        or "read-environmentfile -path $environmentfile"
        not in sealed_compose_environment_body
        or "get-composeinterpolationnames -composepath $composepath"
        not in sealed_compose_environment_body
        or "foreach ($name in $retainedenvironment.keys)"
        not in sealed_compose_environment_body
        or '$null = $names.add("k_comms_podman_bind_address")'
        not in sealed_compose_environment_body
        or '$null = $names.add("allow_bootstrap")'
        not in sealed_compose_environment_body
        or "[environment]::getenvironmentvariables("
        not in sealed_compose_environment_body
        or "[environmentvariabletarget]::process"
        not in sealed_compose_environment_body
        or "$processenvironmentnames = "
        "[collections.generic.dictionary[string, string]]::new("
        not in sealed_compose_environment_body
        or "[stringcomparer]::ordinalignorecase"
        not in sealed_compose_environment_body
        or "foreach ($existingname in $processenvironment.keys)"
        not in sealed_compose_environment_body
        or "$processenvironmentnames[[string]$existingname] = "
        "[string]$existingname"
        not in sealed_compose_environment_body
        or "exists = $processenvironmentnames.containskey($name)"
        not in sealed_compose_environment_body
        or "name = $originalname"
        not in sealed_compose_environment_body
        or "$(if ($prior.exists) { [string]$prior.name } else { $name })"
        not in sealed_compose_environment_body
        or "[environment]::getenvironmentvariable("
        not in sealed_compose_environment_body
        or "if ($retainedenvironment.contains($name))"
        not in sealed_compose_environment_body
        or "[environment]::setenvironmentvariable("
        not in sealed_compose_environment_body
        or '"k_comms_podman_bind_address", $podmanbindaddress,'
        not in sealed_compose_environment_body
        or '"allow_bootstrap", "false",'
        not in sealed_compose_environment_body
        or "if ($sealpublicbootstrap)"
        not in sealed_compose_environment_body
        or "& $action" not in sealed_compose_environment_body
        or "finally { foreach ($name in $names)"
        not in sealed_compose_environment_body
        or "$(if ($prior.exists) { [string]$prior.value } else { $null })"
        not in sealed_compose_environment_body
        or "invoke-withsealedcomposeenvironment"
        not in invoke_compose_body
        or "-environmentfile $environmentfile"
        not in invoke_compose_body
        or "-composepath $composepath"
        not in invoke_compose_body
        or "-sealpublicbootstrap:$sealpublicbootstrap"
        not in invoke_compose_body
        or "invoke-nativecommand" not in invoke_compose_body
    ):
        errors.append(
            "every Compose call must seal all retained and referenced "
            "interpolation variables against ambient process overrides, force "
            "the Podman bind to loopback, and restore the caller environment"
        )
    if (
        '@("up", "-d", "--no-build", "--force-recreate", "app")'
        not in start_sealed_application_body
        or "if (-not $trustedproxytopology)"
        not in start_sealed_application_body
        or "assert-composeapplicationtrustedproxypeercurrent"
        not in start_sealed_application_body
        or '@("start", "app")' not in start_sealed_application_body
        or "compose recreated the application after its trusted proxy address"
        not in start_sealed_application_body
        or (
            '"up", "--no-start", "--no-deps", "--no-build", '
            '"--force-recreate", "app"'
        )
        not in prepare_trusted_application_body
        or "set-composeapplicationtrustedproxyreservation"
        not in prepare_trusted_application_body
        or "prepare-sealedtrustededgeapplication"
        not in start_release_services_body
        or start_release_services_body.find(
            "prepare-sealedtrustededgeapplication"
        )
        > start_release_services_body.find(
            '@("run", "--rm", "--no-deps", "minio-init")'
        )
        or start_release_services_body.find(
            "prepare-sealedtrustededgeapplication"
        )
        > start_release_services_body.find(
            '@("run", "--rm", "--no-deps", "migrate")'
        )
        or "-sealpublicbootstrap" not in start_sealed_application_body
        or "start-sealedapplication" not in restore_body
    ):
        errors.append(
            "every application activation must force ALLOW_BOOTSTRAP=false, "
            "including legacy retained-release restart and rollback"
        )

    deploy_body = _compact(_function_body(runner_document, "Invoke-DeployLocked"))
    deploy_entry = _compact(_function_body(runner_document, "Invoke-Deploy"))
    if "start-sealedapplication" not in deploy_body:
        errors.append(
            "candidate deployment must activate the application through the "
            "sealed public-bootstrap helper"
        )
    wait_application_body = _compact(
        _function_body(runner_document, "Wait-Application")
    )
    application_capabilities_body = _compact(
        _function_body(runner_document, "Assert-ApplicationCapabilities")
    )
    capability_self_test_body = _compact(
        _function_body(runner_document, "Invoke-CapabilityCompatibilitySelfTest")
    )
    new_stable_environment_body = _compact(
        _function_body(runner_document, "New-StableEnvironment")
    )
    new_encryption_key_body = _compact(
        _function_body(runner_document, "New-EncryptionKey")
    )
    test_encryption_key_body = _compact(
        _function_body(runner_document, "Test-EncryptionKey")
    )
    resolve_stable_encryption_key_body = _compact(
        _function_body(runner_document, "Resolve-StableEncryptionKey")
    )
    stable_encryption_self_test_body = _compact(
        _function_body(runner_document, "Invoke-StableEncryptionKeySelfTest")
    )
    get_stable_environment_body = _compact(
        _function_body(runner_document, "Get-StableEnvironment")
    )
    new_release_environment_body = _compact_powershell(
        _function_body(runner_document, "New-ReleaseEnvironment")
    )
    release_environment_topology_body = _compact_powershell(
        _function_body(runner_document, "Assert-ReleaseEnvironmentTopology")
    )
    resolve_bind_address_body = _compact(
        _function_body(runner_document, "Resolve-ReleaseBindAddress")
    )
    network_category_body = _compact(
        _function_body(runner_document, "Assert-ReleaseNetworkCategory")
    )
    network_observation_body = _compact(
        _function_body(runner_document, "Resolve-ReleaseNetworkObservation")
    )
    current_network_observation_body = _compact(
        _function_body(
            runner_document,
            "Assert-ReleaseNetworkObservationCurrent",
        )
    )
    local_address_body = _compact(
        _function_body(runner_document, "Test-IPv4AssignedLocally")
    )
    preferred_address_record_body = _compact(
        _function_body(
            runner_document,
            "Test-PreferredReleaseIPAddressRecord",
        )
    )
    network_observation_match_body = _compact(
        _function_body(
            runner_document,
            "Assert-ReleaseNetworkObservationMatches",
        )
    )
    bind_address_self_test_body = _compact(
        _function_body(runner_document, "Invoke-BindAddressSelfTest")
    )
    receipt_topology_body = _compact(
        _function_body(runner_document, "Resolve-ReceiptNetworkTopology")
    )
    receipt_network_record_body = _compact(
        _function_body(runner_document, "New-ReceiptNetworkRecord")
    )
    receipt_public_origins_body = _compact_powershell(
        _function_body(runner_document, "New-ReceiptPublicOriginsRecord")
    )
    requested_topology_body = _compact_powershell(
        _function_body(runner_document, "Resolve-RequestedReleaseTopology")
    )
    canonical_hostname_body = _compact_powershell(
        _function_body(runner_document, "Resolve-CanonicalDnsHostname")
    )
    exact_trusted_proxy_body = _compact_powershell(
        _function_body(runner_document, "Assert-ExactTrustedProxyCidr")
    )
    trusted_proxy_selection_body = _compact_powershell(
        _function_body(
            runner_document,
            "Select-ComposeApplicationTrustedProxyReservation",
        )
    )
    trusted_proxy_network_body = _compact_powershell(
        _function_body(
            runner_document,
            "Get-PodmanApplicationNetworkContract",
        )
    )
    trusted_proxy_prepare_body = _compact_powershell(
        _function_body(
            runner_document,
            "Set-ComposeApplicationTrustedProxyReservation",
        )
    )
    trusted_proxy_current_body = _compact_powershell(
        _function_body(
            runner_document,
            "Assert-ComposeApplicationTrustedProxyPeerCurrent",
        )
    )
    trusted_proxy_ownership_body = _compact_powershell(
        _function_body(
            runner_document,
            "Assert-PodmanApplicationContainerOwnership",
        )
    )
    receipt_trusted_proxy_body = _compact_powershell(
        _function_body(
            runner_document,
            "Assert-ReceiptTrustedProxyPeerCurrent",
        )
    )
    trusted_proxy_recovery_body = _compact_powershell(
        _function_body(
            runner_document,
            "Assert-ReceiptTrustedProxyReservationRecoverable",
        )
    )
    trusted_proxy_occupancy_body = _compact_powershell(
        _function_body(
            runner_document,
            "Assert-TrustedProxyRecoveryOccupancy",
        )
    )
    trusted_proxy_self_test_body = _compact_powershell(
        _function_body(
            runner_document,
            "Invoke-TrustedProxyReservationSelfTest",
        )
    )
    wait_trusted_edge_body = _compact_powershell(
        _function_body(runner_document, "Wait-TrustedEdgeApplication")
    )
    rollback_exposure_body = _compact_powershell(
        _function_body(
            runner_document,
            "Assert-RollbackExposureTopologyCompatible",
        )
    )
    receipt_profile_record_body = _compact(
        _function_body(runner_document, "Get-ReceiptNetworkProfileRecord")
    )
    ensure_instant_room_tenant_body = _compact(
        _function_body(runner_document, "Ensure-InstantRoomTenant")
    )
    guest_rollback_probe_body = _compact(
        _function_body(runner_document, "Get-GuestRollbackHazards")
    )
    rollback_receipt_support_body = _compact(
        _function_body(runner_document, "Test-ReceiptSupportsGuestRollback")
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
    retained_assets_body = _compact(
        _function_body(runner_document, "Assert-RetainedReleaseAssets")
    )
    forwarder_listeners_body = _compact_powershell(
        _function_body(runner_document, "New-LanForwarderListeners")
    )
    forwarder_limits_body = _compact_powershell(
        _function_body(runner_document, "New-LanForwarderLimits")
    )
    new_forwarder_record_body = _compact_powershell(
        _function_body(runner_document, "New-LanForwarderReceiptRecord")
    )
    forwarder_record_assets_body = _compact_powershell(
        _function_body(runner_document, "Assert-LanForwarderRecordAssets")
    )
    forwarder_assets_body = _compact_powershell(
        _function_body(runner_document, "Assert-LanForwarderAssets")
    )
    forwarder_observation_body = _compact_powershell(
        _function_body(runner_document, "Get-LanForwarderObservation")
    )
    forwarder_command_pattern_body = _compact_powershell(
        _function_body(runner_document, "Get-ExactCommandLineValuePattern")
    )
    forwarder_command_line_body = _compact_powershell(
        _function_body(runner_document, "Test-LanForwarderCommandLine")
    )
    forwarder_ready_body = _compact_powershell(
        _function_body(runner_document, "Assert-LanForwarderReady")
    )
    verified_forwarder_process_body = _compact_powershell(
        _function_body(runner_document, "Get-VerifiedLanForwarderCommandProcess")
    )
    forwarder_owned_endpoints_body = _compact_powershell(
        _function_body(runner_document, "Get-LanForwarderOwnedEndpoints")
    )
    forwarder_ports_released_body = _compact_powershell(
        _function_body(runner_document, "Assert-LanForwarderPortsReleased")
    )
    stop_forwarder_body = _compact_powershell(
        _function_body(runner_document, "Stop-LanForwarder")
    )
    start_forwarder_body = _compact_powershell(
        _function_body(runner_document, "Start-LanForwarder")
    )
    forwarder_self_test_body = _compact_powershell(
        _function_body(runner_document, "Invoke-LanForwarderSelfTest")
    )
    forwarder_supervision_self_test_body = _compact_powershell(
        _function_body(runner_document, "Invoke-LanForwarderSupervisionSelfTest")
    )
    supervisor_record_body = _compact_powershell(
        _function_body(runner_document, "New-LanForwarderSupervisorRecord")
    )
    supervisor_schedule_record_body = _compact_powershell(
        _function_body(
            runner_document,
            "New-LanForwarderSupervisorScheduleRecord",
        )
    )
    supervisor_schedule_setter_body = _compact_powershell(
        _function_body(
            runner_document,
            "Set-LanForwarderSupervisorScheduleRecord",
        )
    )
    supervisor_register_body = _compact_powershell(
        _function_body(runner_document, "Register-LanForwarderSupervisor")
    )
    supervisor_unregister_body = _compact_powershell(
        _function_body(runner_document, "Unregister-LanForwarderSupervisor")
    )
    supervisor_task_contract_body = _compact_powershell(
        _function_body(
            runner_document,
            "Get-LanForwarderSupervisorTaskContractObservation",
        )
    )
    supervisor_datetime_body = _compact_powershell(
        _function_body(
            runner_document,
            "ConvertTo-ScheduledTaskUtcDateTimeOffset",
        )
    )
    supervisor_task_observation_body = _compact_powershell(
        _function_body(
            runner_document,
            "Get-LanForwarderSupervisorTaskObservation",
        )
    )
    supervisor_bootstrap_ownership_body = _compact_powershell(
        _function_body(runner_document, "Assert-SupervisorOwnedStateDirectory")
    )
    supervisor_bootstrap_lock_body = _compact_powershell(
        _function_body(runner_document, "Enter-SupervisorOperationLock")
    )
    supervisor_bootstrap_receipt_body = _compact_powershell(
        _function_body(runner_document, "Get-SupervisorCurrentReceipt")
    )
    supervise_body = _compact_powershell(
        _function_body(runner_document, "Invoke-Supervise")
    )
    health_check_body = _compact_powershell(
        _function_body(runner_document, "Invoke-HealthCheck")
    )
    start_supervision_body = _compact_powershell(
        _function_body(runner_document, "Invoke-StartLocked")
    )
    rollback_supervision_body = _compact_powershell(
        _function_body(runner_document, "Invoke-RollbackLocked")
    )
    stop_supervision_body = _compact_powershell(
        _function_body(runner_document, "Invoke-StopLocked")
    )
    validate_supervision_body = _compact_powershell(
        _function_body(runner_document, "Invoke-Validate")
    )
    supported_schema_body = _compact_powershell(
        _function_body(runner_document, "Assert-SupportedReceiptSchemaVersion")
    )
    status_body = _compact(_function_body(runner_document, "Invoke-Status"))
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
        "[switch]$requireinstantrooms" not in wait_application_body
        or "-requireinstantrooms:$requireinstantrooms"
        not in wait_application_body
        or "[switch]$requireinstantrooms" not in application_capabilities_body
        or '$capabilities.psobject.properties["instant_rooms"]'
        not in application_capabilities_body
    ):
        errors.append(
            "candidate health checks must support explicit instant-rooms capability enforcement"
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
    if (
        "-status $predecessor ` -requireguestlinks ` -requireinstantrooms"
        not in capability_self_test_body
        or "instant_rooms = $true" not in capability_self_test_body
        or "-status $candidate ` -requireguestlinks ` -requireinstantrooms"
        not in capability_self_test_body
    ):
        errors.append(
            "release validation must exercise candidate instant-rooms capability enforcement"
        )
    if (
        '$capabilities.psobject.properties["bootstrap"]'
        not in application_capabilities_body
        or "$bootstrap.value -ne $false" not in application_capabilities_body
        or "public bootstrap endpoint as disabled"
        not in application_capabilities_body
        or "bootstrap = $false" not in capability_self_test_body
        or "bootstrap = $true" not in capability_self_test_body
        or "accepted an application with public bootstrap enabled"
        not in capability_self_test_body
    ):
        errors.append(
            "release health and self-tests must require the public bootstrap "
            "endpoint to remain disabled"
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
    if "-requireinstantrooms" not in deploy_body:
        errors.append(
            "candidate deployment must require the instant-rooms capability before sealing"
        )
    if "-requireguestlinks" in restore_body:
        errors.append(
            "predecessor restore must not require capabilities introduced by the candidate"
        )
    if "-requireinstantrooms" in restore_body:
        errors.append(
            "predecessor restore must not require instant rooms introduced by the candidate"
        )
    if (
        "[net.ipaddress]::tryparse" not in resolve_bind_address_body
        or "[net.sockets.addressfamily]::internetwork"
        not in resolve_bind_address_body
        or "$value -cne $canonical" not in resolve_bind_address_body
        or '$canonical -eq "0.0.0.0"' not in resolve_bind_address_body
        or '$canonical -cne "127.0.0.1"' not in resolve_bind_address_body
        or "test-rfc1918ipv4" not in resolve_bind_address_body
        or "test-ipv4assignedlocally" not in resolve_bind_address_body
        or "[net.networkinformation.networkinterface]::getallnetworkinterfaces()"
        not in local_address_body
        or "[net.networkinformation.operationalstatus]::up"
        not in local_address_body
        or "$unicast.address.equals($address)" not in local_address_body
    ):
        errors.append(
            "BindAddress must be canonical IPv4, never wildcard, loopback or "
            "RFC1918 only, and an RFC1918 address must be assigned to an active "
            "local interface"
        )
    if (
        "invoke-bindaddressselftest" not in validate_body
        or "resolve-releasebindaddress" not in bind_address_self_test_body
        or '"0.0.0.0"' not in bind_address_self_test_body
        or '"127.0.0.2"' not in bind_address_self_test_body
        or '"127.1"' not in bind_address_self_test_body
        or '"127.000.000.001"' not in bind_address_self_test_body
        or '"3232235953"' not in bind_address_self_test_body
        or '"0xc0.0xa8.0x01.0xb1"' not in bind_address_self_test_body
        or '"203.0.113.10"' not in bind_address_self_test_body
        or '"::1"' not in bind_address_self_test_body
    ):
        errors.append(
            "local release validation must exercise alternate numeric forms, "
            "wildcard, public, IPv6, and loopback bind-address policy"
        )
    if (
        "[switch]$allowpublicnetworkprofile" not in runner_document.lower()
        or '$networkcategory -ceq "private"' not in network_category_body
        or "if (-not $allowpublicnetworkprofile)" not in network_category_body
        or "get-netipaddress" not in network_observation_body
        or "get-netconnectionprofile" not in network_observation_body
        or "assert-releasenetworkcategory" not in network_observation_body
        or "publicnetworkprofileoverrideused" not in network_observation_body
        or "test-preferredreleaseipaddressrecord" not in network_observation_body
        or '$addressrecord.addressstate -ceq "preferred"'
        not in preferred_address_record_body
        or "$addressrecord.ipaddress -ceq $expectedaddress"
        not in preferred_address_record_body
        or "-allowpublicnetworkprofile:$allowpublicnetworkprofile"
        not in network_observation_body
        or 'assert-releasenetworkcategory -networkcategory "public"'
        not in bind_address_self_test_body
        or "-allowpublicnetworkprofile" not in bind_address_self_test_body
        or '"tentative"' not in bind_address_self_test_body
        or '"duplicate"' not in bind_address_self_test_body
        or '"deprecated"' not in bind_address_self_test_body
        or '"invalid"' not in bind_address_self_test_body
    ):
        errors.append(
            "LAN release selection must require one exact Preferred Windows IPv4 "
            "address, and non-Private network profiles must fail closed unless an "
            "explicit audited AllowPublicNetworkProfile override is supplied"
        )
    forbidden_host_network_mutations = (
        "new-netfirewallrule",
        "set-netfirewallrule",
        "remove-netfirewallrule",
        "set-netconnectionprofile",
        "netsh advfirewall",
        "portproxy",
    )
    if any(
        mutation in _compact(runner_document)
        for mutation in forbidden_host_network_mutations
    ):
        errors.append(
            "local release orchestration must never mutate Windows Firewall, "
            "network profiles, or port-proxy state"
        )
    if (
        "resolve-releasenetworkobservation" not in current_network_observation_body
        or "assert-releasenetworkobservationmatches"
        not in current_network_observation_body
        or "assert-releasenetworkobservationmatches" not in receipt_topology_body
        or '"bindaddress"' not in network_observation_match_body
        or '"interfaceindex"' not in network_observation_match_body
        or '"interfacealias"' not in network_observation_match_body
        or '"networkname"' not in network_observation_match_body
        or '"networkcategory"' not in network_observation_match_body
        or "network-profile self-test accepted drift"
        not in bind_address_self_test_body
        or "assert-releasenetworkobservationcurrent" not in deploy_body
        or deploy_body.count("assert-releasenetworkobservationcurrent") < 3
    ):
        errors.append(
            "LAN deployment must revalidate the selected interface and network "
            "profile before activation and before sealing its receipt"
        )
    if (
        '$podmanbindaddress = "127.0.0.1"' not in _compact(runner_document)
        or '$values["k_comms_podman_bind_address"] = $podmanbindaddress'
        not in new_release_environment_body
        or '$values["k_comms_release_host"] = if ($istrustededge)'
        not in new_release_environment_body
        or "[string]$topology.publichost" not in new_release_environment_body
        or '$values["k_comms_livekit_node_ip"] = if ($istrustededge)'
        not in new_release_environment_body
        or "[string]$topology.medianodeaddress" not in new_release_environment_body
        or '$values["k_comms_local_release_host"] ='
        not in new_release_environment_body
        or '$values["k_comms_release_exposure_mode"] = if ($istrustededge)'
        not in new_release_environment_body
        or '$values["k_comms_trusted_edge_confirmation"] ='
        not in new_release_environment_body
        or '$values["phx_host"] = [string]$topology.publichost'
        not in new_release_environment_body
        or '$values["public_app_url"] = [string]$topology.publicappurl'
        not in new_release_environment_body
        or '$values["livekit_server_url"] = [string]$topology.livekitorigin'
        not in new_release_environment_body
        or '$values["s3_public_endpoint"] = [string]$topology.objectorigin'
        not in new_release_environment_body
        or '$values["trusted_proxy_cidrs"] = [string]$topology.trustedproxycidr'
        not in new_release_environment_body
        or '$values["public_app_url"] = "http://$bindaddress:$appport"'
        not in new_release_environment_body
        or '$values["livekit_server_url"] = "ws://$bindaddress:$livekitsignalport"'
        not in new_release_environment_body
        or '$values["s3_public_endpoint"] = "http://$bindaddress:$minioport"'
        not in new_release_environment_body
        or '$values["csp_connect_sources"] =' not in new_release_environment_body
    ):
        errors.append(
            "release environment must keep Podman on exact loopback while "
            "deriving exact direct-release or trusted-edge Phoenix, browser, "
            "media, object, proxy, CORS, HSTS, and CSP settings"
        )
    if (
        "assert-releaseenvironmenttopology" not in deploy_body
        or "assert-releaseenvironmenttopology" not in validate_body
        or "k_comms_podman_bind_address = $podmanbindaddress"
        not in release_environment_topology_body
        or "k_comms_local_release_host = $expectedruntimehost"
        not in release_environment_topology_body
        or "cors_origins = $expectedbrowserorigins"
        not in release_environment_topology_body
        or "minio_api_cors_allow_origin = $expectedbrowserorigins"
        not in release_environment_topology_body
        or "csp_connect_sources =" not in release_environment_topology_body
        or "k_comms_release_exposure_mode = $cloudflaretrustededgeprofile"
        not in release_environment_topology_body
        or "k_comms_trusted_edge_confirmation = $cloudflaretrustededgeconfirmation"
        not in release_environment_topology_body
        or "hsts_enabled = \"true\"" not in release_environment_topology_body
        or "trusted_proxy_cidrs = assert-exacttrustedproxycidr"
        not in release_environment_topology_body
        or "trusted-edge release environment topology is inconsistent"
        not in release_environment_topology_body
    ):
        errors.append(
            "deploy and validation must assert the complete loopback or LAN "
            "release-environment topology before Compose rendering"
        )
    deploy_flow_body = _compact_powershell(
        _function_body(runner_document, "Invoke-DeployLocked")
    )
    restore_flow_body = _compact_powershell(
        _function_body(runner_document, "Restore-Release")
    )
    deploy_local_bootstrap_position = deploy_flow_body.find(
        "ensure-instantroomtenant "
        "-environmentfile $environmentfile "
        "-composeproject $projectname "
        "-composepath $composesourcepath "
        "-expectedbindaddress $podmanbindaddress"
    )
    deploy_local_health_position = deploy_flow_body.find(
        "wait-application -expectedbindaddress $podmanbindaddress"
    )
    deploy_forwarder_start_position = deploy_flow_body.find(
        "start-lanforwarder -receipt $candidateforwarderreceipt"
    )
    deploy_forwarder_ready_position = deploy_flow_body.find(
        "assert-lanforwarderready -receipt $candidateforwarderreceipt"
    )
    deploy_public_health_position = deploy_flow_body.find(
        "wait-application -expectedbindaddress $bindaddress"
    )
    restore_local_bootstrap_position = restore_flow_body.find(
        "ensure-instantroomtenant "
        "-environmentfile $receipt.environmentfile "
        "-composeproject $receipt.projectname "
        "-composepath $receipt.composesourcepath "
        "-expectedbindaddress $topology.podmanbindaddress"
    )
    restore_local_health_position = restore_flow_body.find(
        "wait-application -expectedbindaddress $topology.podmanbindaddress"
    )
    restore_forwarder_start_position = restore_flow_body.find(
        "start-lanforwarder -receipt $receipt"
    )
    restore_forwarder_ready_position = restore_flow_body.find(
        "assert-lanforwarderready -receipt $receipt"
    )
    restore_public_health_position = restore_flow_body.find(
        "wait-application -expectedbindaddress $topology.bindaddress"
    )
    if (
        "[parameter(mandatory)][string]$expectedbindaddress"
        not in wait_application_body
        or wait_application_body.count("$expectedbindaddress") < 4
        or "[parameter(mandatory)][string]$expectedbindaddress"
        not in ensure_instant_room_tenant_body
        or (
            "$releasenetworkobservation.exposureprofile -ceq "
            "$cloudflaretrustededgeprofile -or $bindaddress -cne "
            "$podmanbindaddress"
        )
        not in deploy_flow_body
        or "if (test-receiptrequireslanforwarder -receipt $receipt)"
        not in restore_body
        or min(
            deploy_local_bootstrap_position,
            deploy_local_health_position,
            deploy_forwarder_start_position,
            deploy_forwarder_ready_position,
            deploy_public_health_position,
            restore_local_bootstrap_position,
            restore_local_health_position,
            restore_forwarder_start_position,
            restore_forwarder_ready_position,
            restore_public_health_position,
        )
        < 0
        or not (
            deploy_local_bootstrap_position
            < deploy_local_health_position
            < deploy_forwarder_start_position
            < deploy_forwarder_ready_position
            < deploy_public_health_position
        )
        or not (
            restore_local_bootstrap_position
            < restore_local_health_position
            < restore_forwarder_start_position
            < restore_forwarder_ready_position
            < restore_public_health_position
        )
    ):
        errors.append(
            "deployment and restore must prove loopback Podman bootstrap and "
            "health before activating, identity-checking, and publicly probing "
            "a required LAN forwarder"
        )
    if (
        "network = new-receiptnetworkrecord" not in deploy_body
        or "bindaddress = $observation.bindaddress"
        not in receipt_network_record_body
        or "publichost =" not in receipt_network_record_body
        or "[string]$observation.publichost"
        not in receipt_network_record_body
        or "[string]$observation.bindaddress"
        not in receipt_network_record_body
        or "publicappurl = $publicappurl" not in receipt_network_record_body
        or 'exposureprofile = $profile' not in receipt_network_record_body
        or '$record["medianodeaddress"]' not in receipt_network_record_body
        or '$record["trustedproxycidr"]' not in receipt_network_record_body
        or '$record["trustededgeconfirmation"]'
        not in receipt_network_record_body
        or "resolve-releasenetworkobservation" not in receipt_topology_body
        or "public host must match" not in receipt_topology_body
        or "public application url does not match" not in receipt_topology_body
    ):
        errors.append(
            "release receipts must persist and revalidate the exact bind address, "
            "public host, and public application origin"
        )
    if (
        "$script:releasenetworkobservation = resolve-requestedreleasetopology"
        not in deploy_entry
        or "$script:releasenetworkobservation = resolve-requestedreleasetopology"
        not in validate_body
        or "$script:bindaddress = $script:releasenetworkobservation.bindaddress"
        not in deploy_entry
        or "$script:bindaddress = $script:releasenetworkobservation.bindaddress"
        not in validate_body
        or "k_comms_podman_bind_address" not in retained_assets_body
        or "schema-v5 release environment must not retain the legacy direct-bind"
        not in retained_assets_body
        or "expectedtopologyenvironment" not in retained_assets_body
        or "public_app_url = $apporigin" not in retained_assets_body
        or "livekit_server_url =" not in retained_assets_body
        or "s3_public_endpoint =" not in retained_assets_body
        or "k_comms_local_release_host" not in retained_assets_body
        or "retained schema-v5 release environment topology does not"
        not in retained_assets_body
        or "retained schema-v7 trusted-edge environment topology does"
        not in retained_assets_body
        or "k_comms_release_exposure_mode = $cloudflaretrustededgeprofile"
        not in retained_assets_body
        or "trusted_proxy_cidrs = $topology.trustedproxycidr"
        not in retained_assets_body
    ):
        errors.append(
            "deploy/validate must normalize the requested address and retained "
            "receipts must match the hash-bound network environment"
        )
    required_listener_markers = (
        'name = "app"',
        'name = "minio"',
        'name = "livekitsignal"',
        'name = "livekittcp"',
        'name = "livekitudp"',
        'protocol = "udp"',
        "publicport = $expectedappport",
        "publicport = $expectedminioport",
        "publicport = $expectedlivekitsignalport",
        "publicport = $expectedlivekittcpport",
        "publicport = $expectedlivekitudpport",
        "targethost = $podmanbindaddress",
        "targetport = $expectedappport",
        "targetport = $expectedminioport",
        "targetport = $expectedlivekitsignalport",
        "targetport = $expectedlivekittcpport",
        "targetport = $expectedlivekitudpport",
    )
    required_limit_markers = (
        "maxtcpconnections",
        "tcpconnecttimeoutms",
        "tcpidletimeoutms",
        "tcpshutdowngracems",
        "tcpbacklog",
        "sockethighwatermarkbytes",
        "maxudpmappings",
        "udpmappingidletimeoutms",
        "maxudppendingdatagramspermapping",
        "maxudppendingpublicdatagrams",
    )
    if (
        any(
            marker not in forwarder_listeners_body
            for marker in required_listener_markers
        )
        or forwarder_listeners_body.count("targethost = $podmanbindaddress") != 7
        or 'if ($profile -ceq "media-only")' not in forwarder_listeners_body
        or any(
            marker not in forwarder_limits_body
            for marker in required_limit_markers
        )
        or not any(
            marker in _compact(runner_document)
            for marker in (
                (
                    '$lanforwardersourcerelativepath = '
                    '"scripts/lan_release_forwarder.mjs"'
                ),
                (
                    '$lanforwardersourcerelativepath = '
                    '"scripts\\lan_release_forwarder.mjs"'
                ),
            )
        )
        or "[io.file]::copy($sourcepath, $scriptpath, $false)"
        not in new_forwarder_record_body
        or "if ($sourcesha256 -cne $scriptsha256)"
        not in new_forwarder_record_body
        or "schemaversion = 1" not in new_forwarder_record_body
        or "schemaversion = 2" not in new_forwarder_record_body
        or 'profile = "media-only"' not in new_forwarder_record_body
        or "bindaddress = $expectedbindaddress" not in new_forwarder_record_body
        or "readinesstoken = $readinesstoken" not in new_forwarder_record_body
        or "readyfile = $statuspath" not in new_forwarder_record_body
        or "limits = new-lanforwarderlimits" not in new_forwarder_record_body
        or "sourcesha256 = $sourcesha256" not in new_forwarder_record_body
        or "scriptsha256 = $scriptsha256" not in new_forwarder_record_body
        or "configsha256 = $configsha256" not in new_forwarder_record_body
        or "assert-pathequals" not in forwarder_record_assets_body
        or "get-filehash -literalpath $scriptpath -algorithm sha256"
        not in forwarder_record_assets_body
        or "get-filehash -literalpath $configpath -algorithm sha256"
        not in forwarder_record_assets_body
        or '-name "schemaversion" -expected $(if ($profile -ceq "media-only")'
        not in forwarder_record_assets_body
        or '-name "profile" -expected "media-only"'
        not in forwarder_record_assets_body
        or '-name "bindaddress" -expected $expectedbindaddress'
        not in forwarder_record_assets_body
        or '-name "readinesstoken" -expected $forwarder.readinesstoken'
        not in forwarder_record_assets_body
        or "lan forwarder configuration readyfile"
        not in forwarder_record_assets_body
        or forwarder_record_assets_body.count("assert-lanforwarderlisteners") < 2
        or "foreach ($entry in $expectedlimits.getenumerator())"
        not in forwarder_record_assets_body
        or "pre-schema-v5 receipts cannot authorize lan forwarding"
        not in forwarder_assets_body
        or "schema-v5 retained release is missing its forwarder record"
        not in forwarder_assets_body
        or '-name "required" -expected $false'
        not in forwarder_assets_body
        or "assert-lanforwarderrecordassets" not in forwarder_assets_body
        or "schemaversion = 7" not in deploy_body
        or "forwarder = $forwarderrecord" not in deploy_body
        or "new-lanforwarderreceiptrecord" not in deploy_body
        or '$forwarderrecord = [ordered]@{ required = $false '
        'kind = "not-required" }'
        not in deploy_flow_body
    ):
        errors.append(
            "schema-v5 LAN receipts must seal an immutable, hash-bound "
            "forwarder configuration with exact loopback-targeted TCP/UDP "
            "listeners and bounded resource limits"
        )
    if (
        'status = "not-required"' not in forwarder_observation_body
        or "get-filehash -literalpath ([string]$forwarder.configpath)"
        not in forwarder_observation_body
        or '-name "processstarttimeutc"'
        not in forwarder_observation_body
        or "$readyprocessstartvalue -is [datetime]"
        not in forwarder_observation_body
        or "$readyprocessstartvalue.touniversaltime()"
        not in forwarder_observation_body
        or "[datetimeoffset]::parse("
        not in forwarder_observation_body
        or "$process.starttime.touniversaltime()"
        not in forwarder_observation_body
        or ").totalseconds ) -le 5" not in forwarder_observation_body
        or "-classname win32_process" not in forwarder_observation_body
        or "test-lanforwardercommandline"
        not in forwarder_observation_body
        or '[string]$ready.event -ceq "lan_release_forwarder_ready"'
        not in forwarder_observation_body
        or "$expectedreadyschemaversion = if "
        "($forwarderprofile -ceq \"media-only\") { 2 } else { 1 }"
        not in forwarder_observation_body
        or "[int]$ready.schemaversion -eq $expectedreadyschemaversion"
        not in forwarder_observation_body
        or "$readyprofilematches" not in forwarder_observation_body
        or "[string]$ready.configsha256 -ceq"
        not in forwarder_observation_body
        or "[string]$ready.readinesstoken -ceq"
        not in forwarder_observation_body
        or "assert-lanforwarderlisteners" not in forwarder_observation_body
        or "get-nettcpconnection" not in forwarder_observation_body
        or "get-netudpendpoint" not in forwarder_observation_body
        or "where-object { [int]$_.owningprocess -eq $pidvalue }"
        not in forwarder_observation_body
        or "$endpoint.count -ne 1" not in forwarder_observation_body
        or "$processmatchesreceipt -and $configurationhashmatches -and"
        not in forwarder_observation_body
        or "assert-lanforwarderassets -receipt $receipt"
        not in forwarder_ready_body
        or "-not $observation.processmatchesreceipt"
        not in forwarder_ready_body
        or "-not $observation.confighashmatchesreceipt"
        not in forwarder_ready_body
        or "-not $observation.listenersmatchreceipt"
        not in forwarder_ready_body
        or "-filter \"processid = $processid\""
        not in verified_forwarder_process_body
        or "command identity changed" not in verified_forwarder_process_body
        or "$process.starttime.touniversaltime()"
        not in verified_forwarder_process_body
        or "start identity changed" not in verified_forwarder_process_body
    ):
        errors.append(
            "forwarder readiness must prove receipt-bound process identity, "
            "configuration hash, token, start time, and exact TCP/UDP listener "
            "ownership"
        )
    if (
        "[regex]::escape($value)" not in forwarder_command_pattern_body
        or 'if ($value -match "\\s")'
        not in forwarder_command_pattern_body
        or 'return ""$escaped""'
        not in forwarder_command_pattern_body
        or 'return "(?:"$escaped"|$escaped)"'
        not in forwarder_command_pattern_body
        or "get-exactcommandlinevaluepattern"
        not in forwarder_command_line_body
        or forwarder_command_line_body.count(
            "get-exactcommandlinevaluepattern"
        )
        != 3
        or '"^\\s*" +' not in forwarder_command_line_body
        or '"\\s+" + $scriptpattern' not in forwarder_command_line_body
        or '"\\s+--config(?:\\s+|=)" +' not in forwarder_command_line_body
        or '"\\s*$"' not in forwarder_command_line_body
        or "[regex]::ismatch(" not in forwarder_command_line_body
        or "[text.regularexpressions.regexoptions]::ignorecase"
        not in forwarder_command_line_body
        or "[text.regularexpressions.regexoptions]::cultureinvariant"
        not in forwarder_command_line_body
        or "test-lanforwardercommandline"
        not in verified_forwarder_process_body
        or "rejected a canonical exact command line"
        not in forwarder_self_test_body
        or "accepted a decoy command line" not in forwarder_self_test_body
    ):
        errors.append(
            "forwarder process identity must use one anchored, ordered "
            "executable/script/--config command line with no decoy arguments"
        )
    if (
        "get-lanforwarderownedendpoints -receipt $receipt"
        not in forwarder_ports_released_body
        or "lan forwarder public listeners remain after stop"
        not in forwarder_ports_released_body
        or "stop-lanforwarder -receipt $receipt -allownotrunning"
        not in start_forwarder_body
        or "-windowstyle hidden" not in start_forwarder_body
        or "-redirectstandardoutput ([string]$forwarder.stdoutlogpath)"
        not in start_forwarder_body
        or "-redirectstandarderror ([string]$forwarder.stderrlogpath)"
        not in start_forwarder_body
        or "get-lanforwarderobservation -receipt $receipt"
        not in start_forwarder_body
        or "stop-ownedlanforwarderprocess" not in start_forwarder_body
        or "$startedprocesstimeutc = $process.starttime.touniversaltime()"
        not in start_forwarder_body
        or "-expectedstarttimeutc $startedprocesstimeutc"
        not in start_forwarder_body
        or "assert-lanforwarderportsreleased -receipt $receipt"
        not in start_forwarder_body
        or "cleanup could not prove every" not in start_forwarder_body
        or "public listener closed" not in start_forwarder_body
        or "get-verifiedlanforwardercommandprocess"
        not in stop_forwarder_body
        or "$commandprocesses = @(get-lanforwardercommandprocesses -forwarder $forwarder)"
        not in stop_forwarder_body
        or "multiple exact-command lan forwarder processes were found"
        not in stop_forwarder_body
        or "$receiptboundprocess = (" not in stop_forwarder_body
        or "fresh exact-command discovery does not match ready evidence"
        not in stop_forwarder_body
        or "elseif ($commandprocesses.count -eq 1)"
        not in stop_forwarder_body
        or "$foreignendpoints = @("
        not in stop_forwarder_body
        or "[int]$_.owningprocess -ne $exactprocessid"
        not in stop_forwarder_body
        or "refusing to replace stale lan forwarder readiness"
        not in stop_forwarder_body
        or '"stale-evidence lan forwarder process $exactprocessid"'
        not in stop_forwarder_body
        or "readiness evidence is missing or stale while"
        not in stop_forwarder_body
        or "listener ports remain occupied"
        not in stop_forwarder_body
        or "refusing to stop process" not in stop_forwarder_body
        or "start identity changed after readiness verification"
        not in stop_forwarder_body
        or "assert-lanforwarderportsreleased -receipt $receipt"
        not in stop_forwarder_body
        or "get-nettcpconnection" not in forwarder_owned_endpoints_body
        or "get-netudpendpoint" not in forwarder_owned_endpoints_body
    ):
        errors.append(
            "forwarder lifecycle must replace only receipt-owned processes, "
            "retain hidden-process logs, and prove failed-start and stop cleanup "
            "released every public listener"
        )
    if (
        "invoke-lanforwarderselftest -temporarydirectory $temporarydirectory"
        not in validate_body
        or "a tampered immutable script" not in forwarder_self_test_body
        or "a tampered hash-bound configuration" not in forwarder_self_test_body
        or "a tampered ready token" not in forwarder_self_test_body
        or "ready process-start drift" not in forwarder_self_test_body
        or "ready listener drift" not in forwarder_self_test_body
        or "did not replace the retained process" not in forwarder_self_test_body
        or "left an exact-command orphan process" not in forwarder_self_test_body
        or "an unowned public listener during start"
        not in forwarder_self_test_body
        or forwarder_self_test_body.count(
            "assert-lanforwarderportsreleased -receipt $receipt"
        )
        < 3
    ):
        errors.append(
            "local release validation must exercise forwarder asset, READY, "
            "process-replacement, orphan-cleanup, occupied-port, and "
            "listener-release controls"
        )
    if (
        "$supportedreceiptschemaversion = 7" not in _compact(runner_document)
        or "$value -isnot [int] -and $value -isnot [long]"
        not in _compact_powershell(runner_document)
        or "$schemaversion -gt $supportedreceiptschemaversion"
        not in supported_schema_body
        or "new-lanforwardersupervisorrecord" not in new_forwarder_record_body
        or "manage_local_release.supervisor.ps1"
        not in _compact(runner_document)
        or "[io.file]::copy(" not in supervisor_record_body
        or "retainedmanagerhash -cne $sourcemanagerhash"
        not in supervisor_record_body
        or "managerscriptsha256" not in supervisor_record_body
        or "expectedreceiptpath" not in supervisor_record_body
        or "expectedcandidateid" not in supervisor_record_body
        or "expectedforwarderconfigsha256" not in supervisor_record_body
        or "register-scheduledtask" not in supervisor_register_body
        or "new-scheduledtasktrigger -once" not in supervisor_register_body
        or "-repetitioninterval" not in supervisor_register_body
        or "new-timespan -seconds ([int]$supervisor.intervalseconds)"
        not in supervisor_register_body
        or "-multipleinstances ignorenew" not in supervisor_register_body
        or "-restartcount 3" not in supervisor_register_body
        or "-executiontimelimit (new-timespan -minutes 2)"
        not in supervisor_register_body
        or "unregister-scheduledtask" not in supervisor_unregister_body
        or "refusing to remove a lan forwarder supervisor task"
        not in supervisor_unregister_body
        or "assert-lanforwardersupervisorinvocation" not in supervise_body
        or "assert-lanforwardersupervisortaskready" not in supervise_body
        or "repair-lanforwarderifneeded" not in supervise_body
        or "supervisor will not start media forwarding" not in supervise_body
        or "assert-receiptruntimehealthy" not in health_check_body
        or '"healthcheck" { invoke-healthcheck }'
        not in _compact_powershell(runner_document)
        or '"supervise" { invoke-supervise }'
        not in _compact_powershell(runner_document)
        or (
            "invoke-lanforwardersupervisionselftest "
            "-temporarydirectory $temporarydirectory"
        )
        not in validate_supervision_body
        or '-profile "media-only"' not in forwarder_supervision_self_test_body
        or "unexpectedly exited media-only process"
        not in forwarder_supervision_self_test_body
        or 'recovery exposed a " + "non-media listener'
        not in forwarder_supervision_self_test_body
        or "unregister-lanforwardersupervisor" not in deploy_body
        or "register-lanforwardersupervisor" not in deploy_body
        or "unregister-lanforwardersupervisor" not in restore_body
        or "register-lanforwardersupervisor" not in restore_body
        or "unregister-lanforwardersupervisor" not in start_supervision_body
        or "unregister-lanforwardersupervisor"
        not in rollback_supervision_body
        or "unregister-lanforwardersupervisor" not in stop_supervision_body
    ):
        errors.append(
            "trusted-edge media forwarding must use receipt-bound scheduled "
            "supervision, exact crash recovery, strict health checks, and "
            "fail-closed receipt schema compatibility"
        )
    supervisor_deploy_receipt_index = deploy_flow_body.find(
        "write-jsonatomic -path $receiptpath -value $receipt"
    )
    supervisor_deploy_schedule_index = deploy_flow_body.find(
        "set-lanforwardersupervisorschedulerecord "
        "-forwarder $forwarderrecord"
    )
    supervisor_deploy_register_index = deploy_flow_body.find(
        "register-lanforwardersupervisor -receipt $receipt"
    )
    supervisor_deploy_pointer_index = deploy_flow_body.find(
        "write-jsonatomic -path $currentpointerpath",
        supervisor_deploy_register_index,
    )
    supervisor_restore_register_index = restore_flow_body.find(
        "register-lanforwardersupervisor -receipt $receipt"
    )
    supervisor_restore_pointer_index = restore_flow_body.find(
        "write-jsonatomic -path $currentpointerpath",
        supervisor_restore_register_index,
    )
    if (
        "[parameter(mandatory)][string]$immutablesourceroot"
        not in supervisor_record_body
        or (
            "$sourcemanagerscriptpath = join-path $immutablesourceroot "
            '"scripts\\manage_local_release.ps1"'
        )
        not in supervisor_record_body
        or "get-filehash -literalpath $sourcemanagerscriptpath"
        not in supervisor_record_body
        or "[io.file]::copy( $sourcemanagerscriptpath,"
        not in supervisor_record_body
        or "powershellexecutablepath = get-currentpowershellexecutablepath"
        not in supervisor_record_body
        or "schedulesealedatutc = $schedule.schedulesealedatutc"
        not in supervisor_record_body
        or "taskstartboundaryutc = $schedule.taskstartboundaryutc"
        not in supervisor_record_body
        or "startdelayseconds = $schedule.startdelayseconds"
        not in supervisor_record_body
        or "repetitiondurationdays = $schedule.repetitiondurationdays"
        not in supervisor_record_body
        or "nextrungraceseconds = $schedule.nextrungraceseconds"
        not in supervisor_record_body
        or "addseconds($lanforwardersupervisorstartdelayseconds)"
        not in supervisor_schedule_record_body
        or "set-lanforwardersupervisorschedulerecord"
        not in deploy_flow_body
        or "get-lanforwardersupervisor -forwarder $forwarder"
        not in supervisor_schedule_setter_body
        or "[string]$supervisor.powershellexecutablepath"
        not in supervisor_register_body
        or "$pshome" in supervisor_register_body
        or "$pshome" in supervisor_task_observation_body
        or "$trigger.repetition.stopatdurationend = $true"
        not in supervisor_register_body
        or "-at $taskstartboundary.localdatetime"
        not in supervisor_register_body
        or (
            "new-timespan -days "
            "([int]$supervisor.repetitiondurationdays)"
        )
        not in supervisor_register_body
        or 'register-scheduledtask -taskpath "\\"'
        not in supervisor_register_body
        or "identitymatchesreceipt" not in supervisor_task_contract_body
        or "schedulematchesreceipt" not in supervisor_task_contract_body
        or "operationalstateready" not in supervisor_task_contract_body
        or '"ready"' not in supervisor_task_contract_body
        or '"running"' not in supervisor_task_contract_body
        or '"msft_tasktimetrigger"' not in supervisor_task_contract_body
        or "test-scheduledtaskdurationequals"
        not in supervisor_task_contract_body
        or "repetition.interval" not in supervisor_task_contract_body
        or "repetition.duration" not in supervisor_task_contract_body
        or "repetition.stopatdurationend" not in supervisor_task_contract_body
        or "$trigger.startboundary" not in supervisor_task_contract_body
        or "$supervisor.taskstartboundaryutc"
        not in supervisor_task_contract_body
        or "$supervisor.schedulesealedatutc"
        not in supervisor_task_contract_body
        or "$supervisor.startdelayseconds"
        not in supervisor_task_contract_body
        or "$supervisor.repetitiondurationdays"
        not in supervisor_task_contract_body
        or "$taskinfo.psobject.properties[\"nextruntime\"]"
        not in supervisor_task_contract_body
        or "$taskinfo.nextruntime" not in supervisor_task_contract_body
        or "$supervisor.nextrungraceseconds"
        not in supervisor_task_contract_body
        or "$now.addseconds(-[int]$supervisor.nextrungraceseconds)"
        not in supervisor_task_contract_body
        or (
            "$now.addseconds( [int]$supervisor.intervalseconds + "
            "[int]$supervisor.nextrungraceseconds )"
        )
        not in supervisor_task_contract_body
        or "[datetimeoffset]$nowutc = [datetimeoffset]::utcnow"
        not in supervisor_task_contract_body
        or "[allownull()]$taskinfo" not in supervisor_task_contract_body
        or "get-scheduledtaskinfo" not in supervisor_task_observation_body
        or "-taskinfo $taskinfo" not in supervisor_task_observation_body
        or "-nowutc ([datetimeoffset]::utcnow)"
        not in supervisor_task_observation_body
        or "$value -is [datetimeoffset]" not in supervisor_datetime_body
        or "$value -is [datetime]" not in supervisor_datetime_body
        or "[datetimekind]::unspecified" not in supervisor_datetime_body
        or "[datetimeoffset]::tryparse(" not in supervisor_datetime_body
        or "$observed.year -le 1900" not in supervisor_datetime_body
        or "$settings.enabled" not in supervisor_task_contract_body
        or "$settings.multipleinstances" not in supervisor_task_contract_body
        or "$settings.restartcount" not in supervisor_task_contract_body
        or "$settings.restartinterval" not in supervisor_task_contract_body
        or "$settings.executiontimelimit" not in supervisor_task_contract_body
        or "$settings.startwhenavailable" not in supervisor_task_contract_body
        or "$settings.allowdemandstart" not in supervisor_task_contract_body
        or "$settings.disallowstartifonbatteries"
        not in supervisor_task_contract_body
        or "$settings.stopifgoingonbatteries"
        not in supervisor_task_contract_body
        or "-not $observation.identitymatchesreceipt"
        not in supervisor_register_body
        or "-not $observation.identitymatchesreceipt"
        not in supervisor_unregister_body
        or "assert-noreparsepointancestors -path $canonicalpath"
        not in supervisor_bootstrap_ownership_body
        or "$stateownershipmarkername"
        not in supervisor_bootstrap_ownership_body
        or "assert-supervisorownedstatedirectory"
        not in supervisor_bootstrap_lock_body
        or "operation.lock" not in supervisor_bootstrap_lock_body
        or "join-path $canonicalstateroot \"history\""
        not in supervisor_bootstrap_receipt_body
        or "join-path $historypath $candidateid"
        not in supervisor_bootstrap_receipt_body
        or "join-path $candidatepath \"deployment.json\""
        not in supervisor_bootstrap_receipt_body
        or "join-path $canonicalstateroot \"current.json\""
        not in supervisor_bootstrap_receipt_body
        or "enter-supervisoroperationlock" not in supervise_body
        or "get-supervisorcurrentreceipt" not in supervise_body
        or "assert-requiredtools" in supervise_body
        or "initialize-ownedstatedirectory" in supervise_body
        or "enter-releaseoperationlock" in supervise_body
        or "get-currentreceipt" in supervise_body
        or min(
            supervise_body.find("get-supervisorcurrentreceipt"),
            supervise_body.find("assert-lanforwardersupervisorinvocation"),
            supervise_body.find(
                "test-receiptiscloudflaretrustededge -receipt $current"
            ),
            supervise_body.find("assert-retainedreleaseassets -receipt $current"),
        )
        < 0
        or not (
            supervise_body.find("get-supervisorcurrentreceipt")
            < supervise_body.find("assert-lanforwardersupervisorinvocation")
            < supervise_body.find(
                "test-receiptiscloudflaretrustededge -receipt $current"
            )
            < supervise_body.find("assert-retainedreleaseassets -receipt $current")
        )
        or min(
            supervisor_deploy_receipt_index,
            supervisor_deploy_schedule_index,
            supervisor_deploy_register_index,
            supervisor_deploy_pointer_index,
            supervisor_restore_register_index,
            supervisor_restore_pointer_index,
        )
        < 0
        or not (
            supervisor_deploy_schedule_index
            < supervisor_deploy_receipt_index
            < supervisor_deploy_register_index
            < supervisor_deploy_pointer_index
        )
        or not (
            supervisor_restore_register_index
            < supervisor_restore_pointer_index
        )
    ):
        errors.append(
            "trusted-edge supervisor must bootstrap from receipt-only state, "
            "seal immutable manager and PowerShell assets, enforce exact task "
            "identity/schedule/readiness, and publish current only after "
            "registration"
        )
    if (
        "interfaceindex = $observation.interfaceindex"
        not in receipt_network_record_body
        or "interfacealias = $observation.interfacealias"
        not in receipt_network_record_body
        or "networkname = $observation.networkname"
        not in receipt_network_record_body
        or "networkcategory = $observation.networkcategory"
        not in receipt_network_record_body
        or "allowpublicnetworkprofile = $observation.allowpublicnetworkprofile"
        not in receipt_network_record_body
        or "publicnetworkprofileoverrideused =" not in receipt_network_record_body
        or "allowpublicnetworkprofile" not in receipt_profile_record_body
        or "publicnetworkprofileoverrideused" not in receipt_profile_record_body
        or "bindaddress = $bindaddress" not in receipt_profile_record_body
        or "interfaceindex" not in receipt_topology_body
        or "networkcategory" not in receipt_topology_body
    ):
        errors.append(
            "release receipts must persist the observed Windows interface and "
            "network profile plus the audited non-Private-profile override"
        )
    if (
        "get-receiptbindaddress" not in status_body
        or "get-receiptpublichost" not in status_body
        or "get-receiptpublicappurl" not in status_body
        or '"bind address: $recordedbindaddress"' not in status_body
        or '"public host: $recordedpublichost"' not in status_body
        or '"application: $recordedpublicappurl/app/"' not in status_body
        or "recorded network interface:" not in status_body
        or "recorded network profile:" not in status_body
        or "public network profile override authorized:" not in status_body
        or "public network profile override used:" not in status_body
        or "resolve-receiptnetworktopology -receipt $current" not in status_body
        or "observed network topology matches receipt:" not in status_body
        or "$networktopologymatchesreceipt = $false" not in status_body
        or "$networktopologymatchesreceipt = $true" not in status_body
        or "-not $networktopologymatchesreceipt" not in status_body
        or "resolve-receiptnetworktopology -receipt $current" not in rollback_body
        or "resolve-receiptnetworktopology -receipt $target" not in rollback_body
    ):
        errors.append(
            "Status must re-observe and expose an explicit receipt-network match, "
            "and Rollback must revalidate both retained network topologies"
        )
    if (
        "get-lanforwarderobservation -receipt $current" not in status_body
        or '"forwarder: $($forwarderobservation.status)"' not in status_body
        or "if ($forwarderobservation.required)" not in status_body
        or '"observed forwarder matches receipt: "' not in status_body
        or "$($forwarderobservation.processmatchesreceipt)"
        not in status_body
        or '"observed forwarder configuration hash matches receipt: "'
        not in status_body
        or "$($forwarderobservation.confighashmatchesreceipt)"
        not in status_body
        or '"observed forwarder listeners match receipt: "'
        not in status_body
        or "$($forwarderobservation.listenersmatchreceipt)"
        not in status_body
        or '$forwarderobservation.status -notin @("ready", "not-required")'
        not in status_body
    ):
        errors.append(
            "Status must report the exact forwarder readiness, receipt-identity, "
            "configuration-hash, and listener-ownership evidence consumed by "
            "qualification"
        )
    deploy_bootstrap_position = deploy_body.find("ensure-instantroomtenant")
    deploy_capability_position = deploy_body.find("wait-application")
    restore_bootstrap_position = restore_body.find("ensure-instantroomtenant")
    restore_capability_position = restore_body.find("wait-application")
    if (
        "[convert]::tobase64string($bytes)" not in new_encryption_key_body
        or "$decoded.length -eq 32" not in test_encryption_key_body
        or "webhook_secret_encryption_key = new-encryptionkey"
        not in new_stable_environment_body
        or "push_subscription_encryption_key = new-encryptionkey"
        not in new_stable_environment_body
        or "resolve-stableencryptionkey" not in get_stable_environment_body
        or "^[a-za-z0-9_-]{64}$" not in resolve_stable_encryption_key_body
        or "restore the correct 32-byte key before deployment"
        not in resolve_stable_encryption_key_body
        or "resolve-stableencryptionkey" not in stable_encryption_self_test_body
        or "invoke-stableencryptionkeyselftest" not in validate_body
    ):
        errors.append(
            "local release must generate valid AES-256 keys, repair only the "
            "known never-valid legacy format, reject unknown retained corruption, "
            "and exercise that policy during validation"
        )
    if (
        "bootstrap_owner_password = new-urlsafesecret 48"
        not in new_stable_environment_body
        or '$values["bootstrap_owner_password"] = new-urlsafesecret 48'
        not in get_stable_environment_body
        or '$values["instant_rooms_enabled"] = "true"'
        not in new_release_environment_body
        or '$values["instant_room_tenant_slug"] = "k-comms-development"'
        not in new_release_environment_body
        or '$values["allow_bootstrap"] = "false"'
        not in new_release_environment_body
        or "allow_bootstrap = \"false\""
        not in release_environment_topology_body
        or ensure_instant_room_tenant_body.count(
            "test-instantroomtenantexists"
        )
        < 2
        or '@("run", "--rm", "--no-deps", "bootstrap")'
        not in ensure_instant_room_tenant_body
        or "-sealpublicbootstrap" not in ensure_instant_room_tenant_body
        or "public http bootstrap will not be used"
        not in ensure_instant_room_tenant_body
        or "/api/v1/bootstrap" in ensure_instant_room_tenant_body
        or "no active tenant was persisted" not in ensure_instant_room_tenant_body
        or deploy_bootstrap_position < 0
        or deploy_capability_position < 0
        or deploy_bootstrap_position > deploy_capability_position
        or restore_bootstrap_position < 0
        or restore_capability_position < 0
        or restore_bootstrap_position > restore_capability_position
    ):
        errors.append(
            "local release must provision and verify the fixed instant-room tenant "
            "through the sealed one-shot release command before candidate or "
            "restored-release capability checks"
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
        '"instant_room_lifecycle_v1"' not in deploy_body
        or '"instant_room_presence_lease_v1"' not in deploy_body
        or '"instant_room_expiry_worker_v1"' not in deploy_body
        or '"conversation_only_human_v1"' not in deploy_body
        or '"instant_room_lifecycle_v1"' not in rollback_receipt_support_body
        or '"instant_room_presence_lease_v1"'
        not in rollback_receipt_support_body
        or '"instant_room_expiry_worker_v1"'
        not in rollback_receipt_support_body
        or '"conversation_only_human_v1"' not in rollback_receipt_support_body
    ):
        errors.append(
            "release receipts and rollback guard must declare every instant-room "
            "persistence and worker compatibility capability"
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
        "conversation_ephemeral_rooms" not in guest_rollback_probe_body
        or "conversation_ephemeral_join_receipts"
        not in guest_rollback_probe_body
        or "conversation_ephemeral_presence_leases"
        not in guest_rollback_probe_body
        or "access_scope = ''conversation_only''"
        not in guest_rollback_probe_body
        or "commsworkers.ephemeralroomlifecycleworker"
        not in guest_rollback_probe_body
        or "commsworkers.ephemeralroomreconcilerworker"
        not in guest_rollback_probe_body
        or "to_regclass('public.conversation_ephemeral_rooms')"
        not in guest_rollback_probe_body
        or "to_regclass('public.conversation_ephemeral_join_receipts')"
        not in guest_rollback_probe_body
        or "information_schema.columns" not in guest_rollback_probe_body
        or "ephemeralrooms" not in guest_rollback_safe_body
        or "ephemeraljoinreceipts" not in guest_rollback_safe_body
        or "ephemeralpresenceleases" not in guest_rollback_safe_body
        or "conversationonlyhumans" not in guest_rollback_safe_body
        or "activeephemeralroomjobs" not in guest_rollback_safe_body
    ):
        errors.append(
            "communication rollback preflight must fail-safely query instant rooms, "
            "join receipts, presence leases, conversation-only humans, and active "
            "lifecycle jobs"
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

    port_body = _compact_powershell(
        _function_body(runner_document, "Assert-CandidatePorts")
    )
    retained_forwarder_port_body = _compact_powershell(
        _function_body(runner_document, "Test-RetainedForwarderOwnsPort")
    )
    declared_port_specifications = port_body.split("$duplicates =", 1)[0]
    if (
        "group-object -property port" not in port_body
        or "[parameter(mandatory)][string]$candidatebindaddress" not in port_body
        or "test-bindaddressportavailable" not in port_body
        or "-address ([net.ipaddress]::parse($specification.bindaddress))"
        not in port_body
        or declared_port_specifications.count(
            "bindaddress = $podmanbindaddress"
        )
        != 5
        or 'bindaddress = "127.0.0.1"' not in port_body
        or "if ($candidatebindaddress -ceq $podmanbindaddress) { return }"
        not in port_body
        or port_body.count("forwarder\" protocol = \"tcp\"") != 5
        or 'name = "livekit media udp forwarder" protocol = "udp"'
        not in port_body
        or '[validateset("full", "media-only")]'
        not in port_body
        or 'if ($forwarderprofile -ceq "media-only")'
        not in port_body
        or "-address ([net.ipaddress]::parse($candidatebindaddress))"
        not in port_body
    ):
        errors.append(
            "candidate port preflight must enforce uniqueness, loopback-only "
            "Podman and MinIO-console availability, and exact selected-address "
            "TCP/UDP forwarder availability"
        )
    if (
        "get-runningretainedservices" not in port_body
        or "ownedbyretainedrelease" not in port_body
        or "test-retainedserviceownsport" not in port_body
        or "test-retainedforwarderownsport" not in port_body
        or "assert-lanforwarderready -receipt $receipt"
        not in retained_forwarder_port_body
        or "[string]$listener.protocol -ceq $protocol"
        not in retained_forwarder_port_body
        or "[int]$listener.publicport -eq $expectedport"
        not in retained_forwarder_port_body
    ):
        errors.append(
            "candidate port preflight must only exempt verified Podman mappings "
            "or ready receipt-bound forwarder listeners owned by the retained release"
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
        or "resolve-receiptnetworktopology -receipt $current" not in start_body
        or "assert-candidateports" not in start_body
        or "-candidatebindaddress $topology.bindaddress" not in start_body
        or "restore-release" not in start_body
        or "-runmigration" not in start_body
        or "-updatepointer" not in start_body
    ):
        errors.append(
            "Start must restart the current retained receipt with forward migration and health checks"
        )
    start_guard_position = start_body.find("assert-guestrollbacksafe")
    start_restore_position = start_body.find("restore-release")
    start_topology_position = start_body.find(
        "resolve-receiptnetworktopology -receipt $current"
    )
    start_port_position = start_body.find("assert-candidateports")
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
        start_topology_position < 0
        or start_port_position < 0
        or start_topology_position > start_port_position
        or start_topology_position > start_guard_position
        or start_topology_position > start_restore_position
    ):
        errors.append(
            "Start must reject retained network drift before any Compose-capable "
            "port, rollback-safety, or restore action"
        )
    start_order_body = _compact_powershell(
        _function_body(runner_document, "Invoke-StartLocked")
    )
    start_image_evidence_position = start_order_body.find(
        "get-imageevidence -imagereference $current.imagereference "
        "-expectedrevision $current.revision"
    )
    start_image_id_position = start_order_body.find(
        "if ($retainedimage.imageid -ne $current.imageid)"
    )
    start_image_digest_position = start_order_body.find(
        "$retainedimage.imagedigest -ne [string]$current.imagedigest"
    )
    start_forwarder_stop_position = start_order_body.find(
        "stop-lanforwarder -receipt $current -allownotrunning"
    )
    start_port_preflight_position = start_order_body.find(
        "assert-candidateports"
    )
    if (
        min(
            start_image_evidence_position,
            start_image_id_position,
            start_image_digest_position,
            start_forwarder_stop_position,
            start_port_preflight_position,
        )
        < 0
        or not (
            start_image_evidence_position
            < start_image_id_position
            < start_forwarder_stop_position
            < start_port_preflight_position
        )
        or start_image_digest_position > start_forwarder_stop_position
    ):
        errors.append(
            "Start must validate the retained image revision, ID, and digest, "
            "then stale-safely stop its forwarder before candidate port preflight"
        )
    rollback_current_topology_position = rollback_body.find(
        "resolve-receiptnetworktopology -receipt $current"
    )
    rollback_target_topology_position = rollback_body.find(
        "resolve-receiptnetworktopology -receipt $target"
    )
    rollback_guard_position = rollback_body.find("assert-guestrollbacksafe")
    rollback_restore_position = rollback_body.find(
        "restore-rollbacktargetorcurrent"
    )
    if (
        rollback_current_topology_position < 0
        or rollback_target_topology_position < 0
        or rollback_guard_position < 0
        or rollback_restore_position < 0
        or rollback_current_topology_position > rollback_guard_position
        or rollback_target_topology_position > rollback_guard_position
        or rollback_current_topology_position > rollback_restore_position
        or rollback_target_topology_position > rollback_restore_position
    ):
        errors.append(
            "Rollback must reject current or target network drift before any "
            "Compose-capable rollback-safety or restore action"
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
    restore_image_evidence_position = restore_flow_body.find(
        "get-imageevidence -imagereference $receipt.imagereference "
        "-expectedrevision $receipt.revision"
    )
    restore_image_id_position = restore_flow_body.find(
        "if ($image.imageid -ne $receipt.imageid)"
    )
    restore_image_digest_position = restore_flow_body.find(
        "$image.imagedigest -ne [string]$receipt.imagedigest"
    )
    restore_active_forwarder_stop_position = restore_flow_body.find(
        "stop-lanforwarder -receipt $activereceipt -allownotrunning"
    )
    if (
        min(
            restore_image_evidence_position,
            restore_image_id_position,
            restore_image_digest_position,
            restore_active_forwarder_stop_position,
        )
        < 0
        or not (
            restore_image_evidence_position
            < restore_image_id_position
            < restore_active_forwarder_stop_position
        )
        or restore_image_digest_position > restore_active_forwarder_stop_position
    ):
        errors.append(
            "Restore must validate the target image revision, ID, and digest "
            "before stopping the active receipt's forwarder"
        )
    deploy_entry_flow_body = _compact_powershell(
        _function_body(runner_document, "Invoke-Deploy")
    )
    start_flow_body = _compact_powershell(
        _function_body(runner_document, "Invoke-StartLocked")
    )
    rollback_flow_body = _compact_powershell(
        _function_body(runner_document, "Invoke-RollbackLocked")
    )
    stop_flow_body = _compact_powershell(
        _function_body(runner_document, "Invoke-StopLocked")
    )
    deploy_previous_stop_position = deploy_flow_body.find(
        "stop-lanforwarder -receipt $previousreceipt -allownotrunning"
    )
    deploy_service_start_position = deploy_flow_body.find(
        "start-releaseservices"
    )
    restore_active_stop_position = restore_flow_body.find(
        "stop-lanforwarder -receipt $activereceipt -allownotrunning"
    )
    restore_service_start_position = restore_flow_body.find(
        "start-releaseservices"
    )
    rollback_stop_position = rollback_flow_body.find(
        "stop-lanforwarder -receipt $current -allownotrunning"
    )
    rollback_restore_position = rollback_flow_body.find(
        "restore-rollbacktargetorcurrent"
    )
    stop_forwarder_position = stop_flow_body.find(
        "stop-lanforwarder -receipt $current -allownotrunning"
    )
    stop_compose_position = stop_flow_body.find("invoke-compose")
    if (
        'if ($script:bindaddress -cne $podmanbindaddress) { '
        '$requiredcommands += "node" }'
        not in deploy_entry_flow_body
        or "if (test-receiptrequireslanforwarder -receipt $current) { "
        'assert-requiredtools -commands @("node") }'
        not in start_flow_body
        or "if ( (test-receiptrequireslanforwarder -receipt $current) -or "
        "(test-receiptrequireslanforwarder -receipt $target) ) { "
        'assert-requiredtools -commands @("node") }'
        not in rollback_flow_body
        or min(
            deploy_previous_stop_position,
            deploy_service_start_position,
            restore_active_stop_position,
            restore_service_start_position,
            rollback_stop_position,
            rollback_restore_position,
            stop_forwarder_position,
            stop_compose_position,
        )
        < 0
        or deploy_previous_stop_position > deploy_service_start_position
        or restore_active_stop_position > restore_service_start_position
        or rollback_stop_position > rollback_restore_position
        or stop_forwarder_position > stop_compose_position
        or "if ($candidateforwarderreceipt -and $candidateforwarderstarted)"
        not in deploy_flow_body
        or "stop-lanforwarder -receipt $candidateforwarderreceipt"
        not in deploy_flow_body
        or "if ($targetforwarderstarted)" not in restore_flow_body
        or "stop-lanforwarder -receipt $receipt -allownotrunning"
        not in restore_flow_body
        or '"node"' in status_body
        or '"node"' in stop_flow_body
    ):
        errors.append(
            "Deploy, Restore, Start, Rollback, and Stop must manage the "
            "receipt-bound forwarder, including failure cleanup, with Node "
            "required only for LAN mode"
        )

    trusted_edge_cli_markers = (
        '[validateset("auto", "cloudflare_trusted_edge")]',
        '[string]$exposureprofile = "auto"',
        '[string]$apphostname = ""',
        '[string]$mediahostname = ""',
        '[string]$objecthostname = ""',
        '[string]$medianodeaddress = ""',
        '[string]$trustededgeconfirmation = ""',
        '$cloudflaretrustededgeconfirmation = "cloudflare-tunnel-v1"',
    )
    trusted_edge_topology_markers = (
        'if ($requestedbindaddress -cne $podmanbindaddress)',
        "if ($trustededgeconfirmation -cne "
        "$cloudflaretrustededgeconfirmation)",
        "resolve-canonicaldnshostname -value $apphostname",
        "resolve-canonicaldnshostname -value $mediahostname",
        "resolve-canonicaldnshostname -value $objecthostname",
        "cloudflare application, media, and object hostnames must be distinct",
        "resolve-releasenetworkobservation -value $medianodeaddress",
        "if ($observation.bindaddress -ceq $podmanbindaddress)",
        'publicappurl = "https://$resolvedapphostname"',
        'appwebsocketorigin = "wss://$resolvedapphostname"',
        'livekitorigin = "wss://$resolvedmediahostname"',
        'objectorigin = "https://$resolvedobjecthostname"',
        "trustededgeconfirmation = $cloudflaretrustededgeconfirmation",
    )
    trusted_edge_receipt_markers = (
        "schema-v6 trusted-edge receipts trusted the podman gateway",
        "cloudflare trusted-edge releases require a schema-v7 receipt",
        "if ($recordedexposuremode -cne $cloudflaretrustededgeprofile)",
        "retained trusted-edge application, media, and object",
        "hostnames must remain distinct",
        "assert-exacttrustedproxycidr",
        "$recordedtrustedproxysourcekind -cne $trustedproxysourcekind",
        "applicationnetworkname",
        "applicationnetworkid",
        "applicationnetworksubnet",
        "applicationnetworkgateway",
        "applicationnetworkprefixlength",
        "applicationcontaineripv4",
        "applicationcontaineripv4cidr",
        "schema-v7 trusted-edge receipt is missing sealed public origins",
        "retained trusted-edge public origin",
        "retained release public application url does not match",
    )
    trusted_edge_rollback_markers = (
        "rollback cannot change between the cloudflare trusted-edge profile",
        "public application origin",
        "application websocket origin",
        "media origin",
        "object-storage origin",
        "media node address",
        "trusted proxy cidr",
        "trusted proxy source kind",
        "application network name",
        "application network id",
        "application network subnet",
        "application network gateway",
        "application network prefix length",
        "application container ipv4",
        "application container ipv4 cidr",
        "trusted-edge confirmation",
        '"app", "minio", "livekitsignal", "livekittcp", "livekitudp"',
        '"media-only"',
    )
    if (
        any(marker not in compact_runner for marker in trusted_edge_cli_markers)
        or any(
            marker not in requested_topology_body
            for marker in trusted_edge_topology_markers
        )
        or "$value -cne $value.tolowerinvariant()"
        not in canonical_hostname_body
        or '$value -notmatch "\\."' not in canonical_hostname_body
        or "$label.length -gt 63" not in canonical_hostname_body
        or "test-rfc1918ipv4 -address $parsed"
        not in exact_trusted_proxy_body
        or '/32$"' not in exact_trusted_proxy_body
        or '$trustedproxysourcekind = "podman-app-self-v1"'
        not in compact_runner
        or (
            '"up", "--no-start", "--no-deps", "--no-build", '
            '"--force-recreate", "app"'
        )
        not in prepare_trusted_application_body
        or "get-composeapplicationnetworkcontract"
        not in trusted_proxy_selection_body
        or "select-freeprivateipv4cidr"
        not in trusted_proxy_selection_body
        or "trustedproxysourcekind = $trustedproxysourcekind"
        not in trusted_proxy_selection_body
        or '@("network", "inspect", $networkname)'
        not in trusted_proxy_network_body
        or "$parsednetworkrecords = $inspection.output | convertfrom-json"
        not in trusted_proxy_network_body
        or "$networkrecords = @($parsednetworkrecords)"
        not in trusted_proxy_network_body
        or "@($inspection.output | convertfrom-json)"
        in trusted_proxy_network_body
        or "$networkrecords.count -ne 1"
        not in trusted_proxy_network_body
        or '$networkid -notmatch "^[0-9a-f]{64}$"'
        not in trusted_proxy_network_body
        or "$subnets.count -ne 1" not in trusted_proxy_network_body
        or '$network.psobject.properties["containers"]'
        not in trusted_proxy_network_body
        or '"com.docker.compose.project"'
        not in trusted_proxy_network_body
        or '"com.docker.compose.network"'
        not in trusted_proxy_network_body
        or "$projectlabelproperty.value -cne $expectedcomposeproject"
        not in trusted_proxy_network_body
        or '$networklabelproperty.value -cne "default"'
        not in trusted_proxy_network_body
        or "assert-trustedproxyrecoveryoccupancy"
        not in trusted_proxy_prepare_body
        or '"network", "disconnect"' not in trusted_proxy_prepare_body
        or '"network", "connect", "--ip"'
        not in trusted_proxy_prepare_body
        or "foreach ($networkalias in @($original.aliases))"
        not in trusted_proxy_prepare_body
        or "assert-composeapplicationtrustedproxypeercurrent"
        not in trusted_proxy_prepare_body
        or "$attachment.networkname -cne $contract.network.networkname"
        not in trusted_proxy_current_body
        or "$attachment.networkid -cne $contract.network.networkid"
        not in trusted_proxy_current_body
        or "$attachment.prefixlength -ne $contract.network.prefixlength"
        not in trusted_proxy_current_body
        or "$attachment.ipaddress -cne $contract.applicationcontaineripv4"
        not in trusted_proxy_current_body
        or '"com.docker.compose.project"'
        not in trusted_proxy_ownership_body
        or '"com.docker.compose.service"'
        not in trusted_proxy_ownership_body
        or '"com.docker.compose.container-number"'
        not in trusted_proxy_ownership_body
        or "$parsedcontainerrecords = $inspection.output | convertfrom-json"
        not in trusted_proxy_ownership_body
        or "$records = @($parsedcontainerrecords)"
        not in trusted_proxy_ownership_body
        or "@($inspection.output | convertfrom-json)"
        in trusted_proxy_ownership_body
        or "$record.image -cne $expectedimageid"
        not in trusted_proxy_ownership_body
        or "$record.state.running -ne $expectedrunning"
        not in trusted_proxy_ownership_body
        or "resolve-receiptnetworktopology -receipt $receipt"
        not in receipt_trusted_proxy_body
        or "assert-composeapplicationtrustedproxypeercurrent"
        not in receipt_trusted_proxy_body
        or "get-composeservicecontainerid"
        not in trusted_proxy_recovery_body
        or "-allownotfound" not in trusted_proxy_recovery_body
        or "-allowanyrunningstate" not in trusted_proxy_recovery_body
        or "assert-trustedproxyrecoveryoccupancy"
        not in trusted_proxy_recovery_body
        or "a foreign container occupies the sealed application ipv4"
        not in trusted_proxy_occupancy_body
        or "app-stopped-rebindable" not in trusted_proxy_occupancy_body
        or "app-absent-recoverable" not in trusted_proxy_occupancy_body
        or "stopped application was not accepted for exact-ip recovery"
        not in trusted_proxy_self_test_body
        or "deleted application was not accepted for exact-ip recovery"
        not in trusted_proxy_self_test_body
        or "foreign trusted proxy ip occupant unexpectedly succeeded"
        not in trusted_proxy_self_test_body
        or "invoke-trustedproxyreservationselftest"
        not in _compact_powershell(
            _function_body(runner_document, "Invoke-Validate")
        )
        or "assert-receipttrustedproxypeercurrent -receipt $receipt"
        not in restore_flow_body
        or "assert-receipttrustedproxypeercurrent -receipt $current"
        not in status_body
        or any(
            marker not in receipt_topology_body
            for marker in trusted_edge_receipt_markers
        )
        or "application = [string]$topology.publicappurl"
        not in receipt_public_origins_body
        or "applicationwebsocket = [string]$topology.appwebsocketorigin"
        not in receipt_public_origins_body
        or "media = [string]$topology.livekitorigin"
        not in receipt_public_origins_body
        or "objectstorage = [string]$topology.objectorigin"
        not in receipt_public_origins_body
        or '$record["apphostname"] = [string]$observation.publichost'
        not in receipt_network_record_body
        or '$record["mediahostname"] =' not in receipt_network_record_body
        or '$record["objecthostname"] =' not in receipt_network_record_body
        or '$record["trustedproxysourcekind"]'
        not in receipt_network_record_body
        or '$record["applicationnetworkname"]'
        not in receipt_network_record_body
        or '$record["applicationnetworkid"]'
        not in receipt_network_record_body
        or '$record["applicationnetworksubnet"]'
        not in receipt_network_record_body
        or '$record["applicationnetworkgateway"]'
        not in receipt_network_record_body
        or '$record["applicationnetworkprefixlength"]'
        not in receipt_network_record_body
        or '$record["applicationcontaineripv4"]'
        not in receipt_network_record_body
        or '$record["applicationcontaineripv4cidr"]'
        not in receipt_network_record_body
        or deploy_flow_body.count("schemaversion = 7") != 2
        or "publicorigins = new-receiptpublicoriginsrecord"
        not in deploy_flow_body
        or "select-composeapplicationtrustedproxyreservation"
        not in deploy_flow_body
        or "$previoustrustedschemaversion -eq 7"
        not in deploy_flow_body
        or "$previoustrustedschemaversion -eq 6"
        not in deploy_flow_body
        or "prepare-sealedtrustededgeapplication"
        not in start_release_services_body
        or "wait-trustededgeapplication" not in deploy_flow_body
        or "$($topology.publicappurl)/health/ready"
        not in wait_trusted_edge_body
        or "$($topology.publicappurl)/app/" not in wait_trusted_edge_body
        or "$($topology.objectorigin)/minio/health/ready"
        not in wait_trusted_edge_body
        or "$($topology.livekitorigin.replace('wss://', 'https://'))/"
        not in wait_trusted_edge_body
        or "-requiresecureactions" not in wait_trusted_edge_body
        or (
            'if (test-receiptiscloudflaretrustededge -receipt $receipt) '
            '{ "media-only" } else { "full" }'
        )
        not in forwarder_assets_body
        or "-profile $profile" not in new_forwarder_record_body
        or "-profile $profile" not in forwarder_record_assets_body
        or '"media-only"' not in deploy_flow_body
        or any(
            marker not in rollback_exposure_body
            for marker in trusted_edge_rollback_markers
        )
        or "if ($comparison[1] -cne $comparison[2])"
        not in rollback_exposure_body
        or "assert-rollbackexposuretopologycompatible"
        not in rollback_flow_body
        or rollback_flow_body.find(
            "assert-rollbackexposuretopologycompatible"
        )
        > rollback_flow_body.find(
            "stop-lanforwarder -receipt $current -allownotrunning"
        )
        or min(
            deploy_flow_body.find(
                "select-composeapplicationtrustedproxyreservation"
            ),
            deploy_flow_body.find(
                "assert-releaseenvironmenttopology "
                "-values $releaseenvironment"
            ),
            deploy_flow_body.find("start-sealedapplication"),
            deploy_flow_body.find(
                "assert-lanforwarderready -receipt $candidateforwarderreceipt"
            ),
            deploy_flow_body.find("wait-trustededgeapplication"),
        )
        < 0
        or not (
            deploy_flow_body.find(
                "select-composeapplicationtrustedproxyreservation"
            )
            < deploy_flow_body.find("start-releaseservices")
            < deploy_flow_body.find("start-sealedapplication")
            < deploy_flow_body.find(
                "assert-lanforwarderready -receipt $candidateforwarderreceipt"
            )
            < deploy_flow_body.find("wait-trustededgeapplication")
        )
        or not (
            restore_flow_body.find("start-releaseservices")
            < restore_flow_body.find("start-sealedapplication")
            < restore_flow_body.find(
                "assert-receipttrustedproxypeercurrent -receipt $receipt"
            )
            < restore_flow_body.find(
                "assert-lanforwarderready -receipt $receipt"
            )
            < restore_flow_body.find("wait-trustededgeapplication")
        )
        or trusted_proxy_prepare_body.count(
            '"network", "connect", "--ip"'
        )
        != 1
        or "select-composeapplicationtrustedproxyreservation"
        in trusted_proxy_prepare_body
        or "select-composeapplicationtrustedproxyreservation"
        in restore_flow_body
        or not (
            _compact_powershell(
                _function_body(runner_document, "Invoke-StartLocked")
            ).find(
                "assert-receipttrustedproxyreservationrecoverable "
                "-receipt $current"
            )
            < _compact_powershell(
                _function_body(runner_document, "Invoke-StartLocked")
            ).find("unregister-lanforwardersupervisor -receipt $current")
        )
        or not (
            rollback_flow_body.find(
                "assert-receipttrustedproxyreservationrecoverable "
                "-receipt $current"
            )
            < rollback_flow_body.find(
                "unregister-lanforwardersupervisor -receipt $current"
            )
        )
    ):
        errors.append(
            "Cloudflare trusted-edge releases must seal canonical HTTPS/WSS "
            "origins, one schema-v7 RFC1918 Podman app-self /32, exact network "
            "and ownership evidence, stopped reservation before one-shots, "
            "media-only forwarding, public health probes, and fail-closed "
            "restart/rollback topology"
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
