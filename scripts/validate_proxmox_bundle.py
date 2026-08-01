#!/usr/bin/env python3
"""Validate the dedicated Proxmox deployment and promotion contract."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


REQUIRED_FILES = (
    "AGENTS.md",
    "Dockerfile",
    ".github/workflows/container.yml",
    ".github/workflows/deploy-proxmox.yml",
    "deploy/proxmox/README.md",
    "deploy/proxmox/inventory.json",
    "deploy/proxmox/runtime.env.example",
    "deploy/proxmox/nftables.conf.in",
    "deploy/proxmox/sysctl/99-k-comms-livekit.conf",
    "deploy/proxmox/quadlet/k-comms.network.in",
    "deploy/proxmox/quadlet/k-comms-postgres-data.volume.in",
    "deploy/proxmox/quadlet/k-comms-minio-data.volume.in",
    "deploy/proxmox/quadlet/k-comms-postgres.container",
    "deploy/proxmox/quadlet/k-comms-minio.container.in",
    "deploy/proxmox/quadlet/k-comms-livekit.container.in",
    "deploy/proxmox/quadlet/k-comms-app.container.in",
    "deploy/proxmox/bin/common.sh",
    "deploy/proxmox/bin/adopt-legacy-production.sh",
    "deploy/proxmox/bin/generate-runtime-env.sh",
    "deploy/proxmox/bin/install.sh",
    "deploy/proxmox/bin/sync-assets.sh",
    "deploy/proxmox/bin/deploy.sh",
    "deploy/proxmox/bin/verify.sh",
    "deploy/proxmox/bin/backup.sh",
    "deploy/proxmox/bin/quiesced-backup.sh",
    "deploy/proxmox/bin/qualify-staging.sh",
    "deploy/proxmox/bin/rollback.sh",
    "deploy/proxmox/bin/restore.sh",
    "deploy/proxmox/bin/restore-rehearsal.sh",
    "deploy/proxmox/systemd/k-comms-health.service",
    "deploy/proxmox/systemd/k-comms-health.timer",
    "deploy/proxmox/systemd/k-comms-backup.service",
    "deploy/proxmox/systemd/k-comms-backup.timer",
    "deploy/proxmox/systemd/cloudflared-kcomms.service",
    "scripts/proxmox/deploy-remote.ps1",
    "scripts/proxmox/export-deployment-evidence.ps1",
    "scripts/proxmox/native-command.ps1",
    "scripts/proxmox/qualify-staging-remote.ps1",
    "scripts/test_proxmox_native_commands.ps1",
    "scripts/test_proxmox_livekit_runtime.sh",
    "docs/02-architecture/adr/0055-proxmox-vm-release-operations.md",
    "docs/02-architecture/adr/0057-managed-livekit-cloud-internet-media.md",
    "docs/02-architecture/adr/0058-automatic-merge-to-production-promotion.md",
    "docs/02-architecture/adr/0064-portable-protected-deployment-runner.md",
    "docs/10-infrastructure-and-deployment/environments/development.md",
    "docs/14-operations/development-to-production-completion-standard.md",
)

PINNED_INFRA_IMAGES = {
    "postgres": (
        "docker.io/library/postgres:17.10-alpine@sha256:"
        "742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193"
    ),
    "minio": (
        "docker.io/minio/minio:RELEASE.2025-09-07T16-13-09Z@sha256:"
        "a1a8bd4ac40ad7881a245bab97323e18f971e4d4cba2c2007ec1bedd21cbaba2"
    ),
    "minio-client": (
        "docker.io/minio/mc:RELEASE.2025-08-13T08-35-41Z@sha256:"
        "eb4ea9884b77704230e2423e9004d2fa738dc272876b9cc41a297d29443b8780"
    ),
    "livekit": (
        "docker.io/livekit/livekit-server:v1.12.0@sha256:"
        "b1281e66e35e8f9749ffbcf0fe6ab4d40d1438aa00f36c2ea7e6975e5e261e2e"
    ),
}

PLACEHOLDER_SECRET_KEYS = (
    "POSTGRES_PASSWORD",
    "SECRET_KEY_BASE",
    "PASSWORD_RECOVERY_SIGNING_KEY",
    "WEBHOOK_SECRET_ENCRYPTION_KEY",
    "PUSH_SUBSCRIPTION_ENCRYPTION_KEY",
    "METRICS_BEARER_TOKEN",
    "LIVEKIT_API_KEY",
    "LIVEKIT_API_SECRET",
    "MINIO_ROOT_PASSWORD",
    "S3_SECRET_ACCESS_KEY",
    "BOOTSTRAP_OWNER_PASSWORD",
)


def read(root: Path, relative: str) -> str:
    return (root / relative).read_text(encoding="utf-8")


def parse_env(document: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in document.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def validate(root: Path) -> list[str]:
    errors: list[str] = []
    missing = [relative for relative in REQUIRED_FILES if not (root / relative).is_file()]
    errors.extend(f"missing required Proxmox asset: {relative}" for relative in missing)
    if missing:
        return errors

    agents = read(root, "AGENTS.md")
    completion_standard = read(
        root,
        "docs/14-operations/development-to-production-completion-standard.md",
    )
    development_environment = read(
        root,
        "docs/10-infrastructure-and-deployment/environments/development.md",
    )
    for required in (
        r"`C:\Users\vasan\OneDrive\Documents\k-comms`",
        "without waiting for another instruction",
        "protected staging",
        "production approval",
        "deployment of the same digest",
        "Do not create independent duplicate clones",
    ):
        if required not in agents:
            errors.append(f"AGENTS.md is missing completion control: {required}")
    for required in (
        "Once acceptance criteria are met",
        "Same immutable digest qualified in staging and production",
        "Never bypass branch protection",
        "If a critical check fails, roll back first and investigate second",
        "Completion evidence template",
    ):
        if required not in completion_standard:
            errors.append(
                "development-to-production completion standard is missing "
                f"control: {required}"
            )
    for required in (
        r"`C:\Users\vasan\OneDrive\Documents\k-comms`",
        "There is no separate Proxmox development VM",
        "git worktree remove",
        "Do not create independent duplicate clones",
    ):
        if required not in development_environment:
            errors.append(
                "development environment standard is missing control: "
                f"{required}"
            )

    bundle_root = root / "deploy/proxmox"
    all_documents = {
        path.relative_to(root).as_posix(): path.read_text(encoding="utf-8")
        for path in bundle_root.rglob("*")
        if path.is_file()
    }

    for relative, document in all_documents.items():
        if ":latest" in document:
            errors.append(f"{relative}: mutable latest tag is forbidden")
        if re.search(r"(?i)(tunnel[_ -]?token|api[_ -]?token)\s*[:=]\s*\S+", document):
            errors.append(f"{relative}: possible populated provider credential")

    image_locations = {
        "postgres": "deploy/proxmox/quadlet/k-comms-postgres.container",
        "minio": "deploy/proxmox/quadlet/k-comms-minio.container.in",
        "minio-client": "deploy/proxmox/bin/common.sh",
        "livekit": "deploy/proxmox/quadlet/k-comms-livekit.container.in",
    }
    for name, expected in PINNED_INFRA_IMAGES.items():
        location = image_locations[name]
        if expected not in read(root, location):
            errors.append(f"{location}: expected pinned {name} image is missing")

    postgres_quadlet = read(
        root, "deploy/proxmox/quadlet/k-comms-postgres.container"
    )
    if "NoNewPrivileges=true" in postgres_quadlet:
        errors.append(
            "PostgreSQL Quadlet must permit its pinned entrypoint to drop from root"
        )

    app = read(root, "deploy/proxmox/quadlet/k-comms-app.container.in")
    for required in (
        "Image=@@IMAGE_REF@@",
        "PublishPort=@@BIND_ADDRESS@@:4188:4000/tcp",
        "ReadOnly=true",
        "DropCapability=all",
        "NoNewPrivileges=true",
        "Notify=healthy",
        "io.k-comms.rollback-capabilities=",
    ):
        if required not in app:
            errors.append(f"application Quadlet is missing: {required}")

    runtime_values = parse_env(read(root, "deploy/proxmox/runtime.env.example"))
    for name in PLACEHOLDER_SECRET_KEYS:
        value = runtime_values.get(name)
        if value is None:
            errors.append(f"runtime.env.example is missing {name}")
        elif "CHANGE_ME" not in value:
            errors.append(f"runtime.env.example must leave {name} as a placeholder")
    if runtime_values.get("S3_ACCESS_KEY_ID") != runtime_values.get("MINIO_ROOT_USER"):
        errors.append("S3_ACCESS_KEY_ID must match MINIO_ROOT_USER")
    if "CHANGE_ME" not in runtime_values.get("LIVEKIT_KEYS", ""):
        errors.append("runtime.env.example must leave LIVEKIT_KEYS as a placeholder")
    if runtime_values.get("K_COMMS_LIVEKIT_TOPOLOGY") != "local_sidecar":
        errors.append("runtime.env.example must default to the local LiveKit standby")
    if runtime_values.get("K_COMMS_MANAGED_LIVEKIT_CONFIRMATION") != "":
        errors.append("runtime.env.example must not pre-confirm managed LiveKit")

    inventory = json.loads(read(root, "deploy/proxmox/inventory.json"))
    environments = inventory.get("environments", {})
    expected_inventory = {
        "staging": (101, "192.168.1.23", "synthetic-only"),
        "production": (100, "192.168.1.22", "authoritative"),
    }
    seen_vmids: set[int] = set()
    seen_addresses: set[str] = set()
    for name, (vmid, address, data_policy) in expected_inventory.items():
        actual = environments.get(name, {})
        if actual.get("vm_id") != vmid:
            errors.append(f"inventory {name} VMID must be {vmid}")
        if actual.get("address") != address:
            errors.append(f"inventory {name} address must be {address}")
        if actual.get("data_policy") != data_policy:
            errors.append(f"inventory {name} data policy must be {data_policy}")
        seen_vmids.add(actual.get("vm_id"))
        seen_addresses.add(actual.get("address"))
    if len(seen_vmids) != 2 or len(seen_addresses) != 2:
        errors.append("staging and production must have distinct VMIDs and addresses")

    firewall = read(root, "deploy/proxmox/nftables.conf.in")
    for required in (
        "policy drop",
        "ip saddr 192.168.1.0/24 tcp dport 22 accept",
        "ip saddr @@PODMAN_SUBNET@@ ip daddr @@PODMAN_GATEWAY@@",
        "th dport 53 accept",
        "tcp dport 7981 accept",
        "udp dport 7982 accept",
        "@@STAGING_LAN_RULES@@",
    ):
        if required not in firewall:
            errors.append(f"nftables template is missing: {required}")
    if "tcp dport 5432" in firewall or "tcp dport 5901" in firewall:
        errors.append("nftables must not expose PostgreSQL or the MinIO console")

    shell_scripts = list((root / "deploy/proxmox/bin").glob("*.sh"))
    for path in shell_scripts:
        document = path.read_text(encoding="utf-8")
        relative = path.relative_to(root).as_posix()
        if not document.startswith("#!/usr/bin/env bash\nset -Eeuo pipefail\n"):
            errors.append(f"{relative}: strict Bash preamble is required")
        if re.search(r"(?:source|\.)\s+[\"']?/etc/k-comms/runtime\.env", document):
            errors.append(f"{relative}: runtime secrets must not be sourced as shell code")
    if "printf '[k-comms] %s\\n' \"$*\" >&2" not in read(
        root, "deploy/proxmox/bin/common.sh"
    ):
        errors.append("common.sh logs must use stderr so command substitutions stay clean")

    dockerfile = read(root, "Dockerfile")
    runtime_dockerfile = dockerfile.partition(
        "FROM ${RUNTIME_IMAGE} AS runtime"
    )[2]
    if 'io.k-comms.pwa="1"' not in runtime_dockerfile:
        errors.append("Dockerfile runtime image is missing io.k-comms.pwa=1")

    deploy = read(root, "deploy/proxmox/bin/deploy.sh")
    for required in (
        "validate_image_ref",
        "org.opencontainers.image.source",
        "org.opencontainers.image.revision",
        "CommsCore.Release.migrate()",
        'case "$version_info" in',
        "backup.sh",
        "verify.sh",
        "k-comms-deployment-receipt-v1",
        "--livekit-credential",
        "write_managed_livekit_runtime_env",
        'install -m 0600 "${rollback_dir}/runtime.env" "$K_COMMS_RUNTIME_ENV"',
        "--arg media_topology",
        "--require-pwa; then",
    ):
        if required not in deploy:
            errors.append(f"deploy.sh is missing control: {required}")
    if "enable --now k-comms-app.service" in deploy:
        errors.append("deploy.sh must not try to enable a generated Quadlet unit")

    generator = read(root, "deploy/proxmox/bin/generate-runtime-env.sh")
    if "CSP_CONNECT_SOURCES='self' %s %s %s %s" not in generator:
        errors.append(
            "staging CSP must use the runtime's space-delimited exact-origin contract"
        )

    installer = read(root, "deploy/proxmox/bin/install.sh")
    for required in (
        "aardvark-dns",
        "qemu-guest-agent",
        "start qemu-guest-agent.service",
        "--prepare-only",
        "--storage-mode",
        "--network-subnet",
        "--network-gateway",
        "this production VM must explicitly adopt its authoritative volumes",
    ):
        if required not in installer:
            errors.append(f"install.sh is missing Proxmox guest integration: {required}")
    for location in (
        "deploy/proxmox/bin/install.sh",
        "deploy/proxmox/bin/sync-assets.sh",
    ):
        if "systemd/cloudflared-kcomms.service" not in read(root, location):
            errors.append(f"{location} must install the Cloudflare connector unit")

    common = read(root, "deploy/proxmox/bin/common.sh")
    for required in (
        "configured_postgres_volume",
        "configured_minio_volume",
        "assert_adopted_storage_ready_for_activation",
        "assert_no_foreign_running_mount",
        "adopted-local",
        "configured_network_subnet",
        "configured_network_gateway",
        "validate_managed_livekit_url",
        "write_managed_livekit_runtime_env",
        "K_COMMS_MANAGED_LIVEKIT_CONFIRMATION=livekit-cloud-v1",
        "managed LiveKit credential must have mode 0600",
    ):
        if required not in common:
            errors.append(f"common.sh is missing storage adoption control: {required}")
    if (
        '[[ -n "$line" ]] && printf \'%s\' "${line#*=}"\n  return 0'
        not in common
    ):
        errors.append("read_optional_env_value must succeed when an optional key is absent")

    volume_templates = {
        "deploy/proxmox/quadlet/k-comms-postgres-data.volume.in": (
            "VolumeName=@@POSTGRES_VOLUME@@"
        ),
        "deploy/proxmox/quadlet/k-comms-minio-data.volume.in": (
            "VolumeName=@@MINIO_VOLUME@@"
        ),
    }
    for location, required in volume_templates.items():
        if required not in read(root, location):
            errors.append(f"{location}: configurable volume identity is missing")

    network_template = read(root, "deploy/proxmox/quadlet/k-comms.network.in")
    for required in ("Subnet=@@PODMAN_SUBNET@@", "Gateway=@@PODMAN_GATEWAY@@"):
        if required not in network_template:
            errors.append(
                "deploy/proxmox/quadlet/k-comms.network.in: "
                f"configurable network identity is missing: {required}"
            )

    adoption = read(root, "deploy/proxmox/bin/adopt-legacy-production.sh")
    for required in (
        "adopt-k-comms-production-v1",
        "k-comms-release_postgres-data",
        "k-comms-release_minio-data",
        "pg_dump --format=custom",
        "k-comms-legacy-adoption-receipt-v1",
        "adoption failed; restoring the retained legacy service",
        'bash "${SCRIPT_DIR}/install.sh"',
        'bash "${SCRIPT_DIR}/sync-assets.sh"',
        "10.90.0.0/24",
        "dedicated production Podman subnet",
        'normalize_runtime_csp "$K_COMMS_RUNTIME_ENV"',
        "legacy CSP does not exactly match the trusted-edge media and object endpoints",
        "start_tunnel_if_installed",
        'podman update --restart=no "$container"',
        'podman update --restart="$original_restart_policy" "$container"',
        'systemctl disable --now "${legacy_auxiliary_units[@]}"',
        'systemctl enable --now "${legacy_auxiliary_units[@]}"',
        "--preflight-only",
        "--prepare-only",
        "--skip-host-tuning",
        "verify.sh",
    ):
        if required not in adoption:
            errors.append(f"legacy production adoption is missing control: {required}")
    if adoption.count("start_tunnel_if_installed") < 3:
        errors.append(
            "legacy production adoption must start the tunnel after activation "
            "and fallback"
        )
    if "--require-pwa" in adoption:
        errors.append(
            "legacy production adoption must permit verification of a pre-PWA image"
        )

    deploy = read(root, "deploy/proxmox/bin/deploy.sh")
    if "assert_adopted_storage_ready_for_activation" not in deploy:
        errors.append("deploy.sh must reject unprepared adopted storage")

    verifier = read(root, "deploy/proxmox/bin/verify.sh")
    for required in (
        "release_image_class",
        "an adopted local image is accepted only in production",
        "an adopted local image requires the adopted storage identity",
        "adopted local image source label does not match",
        "adopted local image revision label does not match",
        "LiveKit UDP receive-buffer ceiling is below 5000000 bytes",
        "assert_managed_livekit_runtime",
        "managed LiveKit Cloud endpoint is not reachable",
    ):
        if required not in verifier:
            errors.append(f"verify.sh is missing adopted-image control: {required}")
    for required in (
        "--require-pwa) require_pwa=true; shift ;;",
        'podman image inspect "$actual_image"',
        'io.k-comms.pwa"}}',
        '"$require_pwa" == true && "$pwa_capability" != 1',
        '"$pwa_capability" == 1',
        "PWA verification was required but the running image lacks io.k-comms.pwa=1",
        'worker_url="${pwa_origin}/k-comms-sw.js?revision=${release_revision}"',
        "PWA application index has no revisioned JavaScript bundle",
        "cache-control: public, max-age=31536000, immutable",
        "PWA hashed asset content type is invalid",
        "PWA missing hash-shaped asset did not return HTTP 404",
        "PWA missing hash-shaped asset cache policy is unsafe",
        "PWA missing hash-shaped asset content type is invalid",
    ):
        if required not in verifier:
            errors.append(f"verify.sh is missing PWA control: {required}")

    livekit_sysctl = read(root, "deploy/proxmox/sysctl/99-k-comms-livekit.conf")
    if "net.core.rmem_max = 5000000" not in livekit_sysctl:
        errors.append("LiveKit UDP receive-buffer tuning is missing")
    for location in (
        "deploy/proxmox/bin/install.sh",
        "deploy/proxmox/bin/sync-assets.sh",
    ):
        document = read(root, location)
        for required in (
            "99-k-comms-livekit.conf",
            "sysctl --load /etc/sysctl.d/99-k-comms-livekit.conf",
        ):
            if required not in document:
                errors.append(f"{location} is missing LiveKit host tuning: {required}")

    tunnel_unit = read(
        root, "deploy/proxmox/systemd/cloudflared-kcomms.service"
    )
    for required in (
        "After=network-online.target",
        "Restart=always",
        "--token-file /etc/cloudflared/token",
    ):
        if required not in tunnel_unit:
            errors.append(f"Cloudflare connector unit is missing: {required}")
    if "Requires=k-comms-app.service" in tunnel_unit or (
        "After=network-online.target k-comms-app.service" in tunnel_unit
    ):
        errors.append(
            "Cloudflare connector must remain lifecycle-independent from the app"
        )

    rollback = read(root, "deploy/proxmox/bin/rollback.sh")
    for required in (
        "CommsCore.Release.assert_communication_rollback_compatible!()",
        "K_COMMS_ROLLBACK_WRITES_QUIESCED=true",
        "backup.sh",
    ):
        if required not in rollback:
            errors.append(f"rollback.sh is missing control: {required}")
    if "--require-pwa" in rollback:
        errors.append(
            "rollback.sh must permit feature-aware verification of a pre-PWA image"
        )

    restore = read(root, "deploy/proxmox/bin/restore.sh")
    for required in (
        "restore-k-comms-backup-v1",
        "sha256sum --check --strict",
        "realpath -e",
        "assert_minio_volume_path",
    ):
        if required not in restore:
            errors.append(f"restore.sh is missing control: {required}")

    restore_rehearsal = read(
        root, "deploy/proxmox/bin/restore-rehearsal.sh"
    )
    for required in (
        "isolated restore rehearsal is permitted only in staging",
        "sha256sum --check --strict SHA256SUMS) >&2",
        "k_comms_restore_",
        "pg_restore",
        "restore-rehearsal.",
        ".minio.sys/format.json",
        "k-comms-restore-rehearsal-receipt-v1",
    ):
        if required not in restore_rehearsal:
            errors.append(
                f"restore-rehearsal.sh is missing control: {required}"
            )

    staging_qualification = read(
        root, "deploy/proxmox/bin/qualify-staging.sh"
    )
    for required in (
        "staging qualification is permitted only on the staging VM",
        "rollback.sh",
        "restore-rehearsal.sh",
        "deploy.sh",
        "k-comms-staging-qualification-receipt-v1",
        "staging-qualification.json",
        "a distinct previous release is required for rollback rehearsal",
    ):
        if required not in staging_qualification:
            errors.append(
                f"qualify-staging.sh is missing control: {required}"
            )
    if (
        staging_qualification.count(
            '"${SCRIPT_DIR}/verify.sh" --environment staging --require-pwa'
        )
        != 3
    ):
        errors.append(
            "qualify-staging.sh must require PWA verification for retained, "
            "reactivated, and post-restore candidates"
        )
    if (
        '"${SCRIPT_DIR}/rollback.sh" --receipt "$candidate_receipt"\n'
        '"${SCRIPT_DIR}/verify.sh" --environment staging\n'
        not in staging_qualification
    ):
        errors.append(
            "qualify-staging.sh must verify the rollback target without "
            "requiring a PWA capability"
        )

    workflow = read(root, ".github/workflows/deploy-proxmox.yml")
    for required in (
        "workflow_call:",
        "workflow_dispatch:",
        "cancel-in-progress: false",
        "--source-ref refs/heads/main",
        "--predicate-type https://cyclonedx.org/bom",
        "--deny-self-hosted-runners",
        "runs-on: [self-hosted, x64, k-comms-deploy]",
        "shell: pwsh",
        "chmod 0600 -- $path",
        "[Security.Principal.WindowsIdentity]::GetCurrent().Name",
        "scripts/test_proxmox_native_commands.ps1",
        "name: ${{ inputs.environment }}",
        "secrets.K_COMMS_DEPLOY_SSH_KEY",
        "secrets.K_COMMS_DEPLOY_HOST_KEY",
        "secrets.K_COMMS_LIVEKIT_CLOUD_CREDENTIAL",
        "LIVEKIT_CREDENTIAL_PATH",
        "bash scripts/test_proxmox_livekit_runtime.sh",
        "Reconfirm the approved revision is still protected main",
        "qualify-staging-remote.ps1",
        "export-deployment-evidence.ps1",
        "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
        "StrictHostKeyChecking=yes",
    ):
        if required not in workflow and required not in read(
            root, "scripts/proxmox/deploy-remote.ps1"
        ):
            errors.append(f"deployment workflow is missing: {required}")
    if "pull_request:" in workflow or "\n  push:" in workflow:
        errors.append(
            "deployment workflow must be invoked only by workflow_call or "
            "workflow_dispatch"
        )

    remote = read(root, "scripts/proxmox/deploy-remote.ps1")
    for required in (
        'ValidateSet("staging", "production")',
        "UserKnownHostsFile=",
        "StrictHostKeyChecking=yes",
        "sync-assets.sh",
        "deploy.sh",
        "LiveKitCredentialPath",
        "--livekit-credential",
        "chmod 0600",
        "ToBase64String",
        "base64 -d | bash",
        "verify.sh",
        "Resolve-KCommsNativeCommand",
    ):
        if required not in remote:
            errors.append(f"remote deployment wrapper is missing: {required}")

    staging_remote = read(
        root, "scripts/proxmox/qualify-staging-remote.ps1"
    )
    for required in (
        "StrictHostKeyChecking=yes",
        "ServerAliveInterval=15",
        "qualify-staging.sh",
        "ToBase64String",
        "base64 -d | bash",
        "Resolve-KCommsNativeCommand",
    ):
        if required not in staging_remote:
            errors.append(
                f"remote staging qualification wrapper is missing: {required}"
            )

    evidence_remote = read(
        root, "scripts/proxmox/export-deployment-evidence.ps1"
    )
    for required in (
        'ValidateSet("staging", "production")',
        "StrictHostKeyChecking=yes",
        "k-comms-workflow-evidence-v1",
        "sha256sum --check --strict",
        "staging-qualification.json",
        "ConvertFrom-Json",
        "ToBase64String",
        "base64 -d | sudo bash",
        "Resolve-KCommsNativeCommand",
    ):
        if required not in evidence_remote:
            errors.append(
                f"deployment evidence exporter is missing: {required}"
            )

    native_command = read(root, "scripts/proxmox/native-command.ps1")
    for required in (
        "function Resolve-KCommsNativeCommand",
        "$IsWindows",
        '"$Name.exe"',
        "-CommandType Application",
        "Required native command is missing",
    ):
        if required not in native_command:
            errors.append(
                f"native command resolver is missing control: {required}"
            )

    container_workflow = read(root, ".github/workflows/container.yml")
    for required in (
        "cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
        "deploy/proxmox/**",
        "scripts/proxmox/**",
        "Record the only promotable release candidate",
        "needs: [publish, staging]",
        "environment: staging",
        "environment: production",
        "image: ${{ needs.publish.outputs.image }}",
        "uses: ./.github/workflows/deploy-proxmox.yml",
        "Verify public production and finalize release evidence",
        "https://comms.avayaworks.com/api/v1/status",
        "https://kcomms-files.avayaworks.com/minio/health/ready",
        "https://comms.avayaworks.com/app/k-comms-sw.js?revision=${REVISION}",
        "--max-redirs 0",
        'test "$pwa_worker_status" = "200"',
        '""|bypass|dynamic) ;;',
        "service worker was eligible for or served from edge cache",
        "cache-control: public, max-age=31536000, immutable",
        "https://comms.avayaworks.com/app/assets/missing-A1b2C3d4.js",
    ):
        if required not in container_workflow:
            errors.append(
                f"automatic release workflow is missing control: {required}"
            )
    if container_workflow.count(
        "uses: ./.github/workflows/deploy-proxmox.yml"
    ) != 2:
        errors.append(
            "automatic release workflow must call the protected deployment "
            "workflow exactly once for staging and once for production"
        )

    readme = read(root, "deploy/proxmox/README.md")
    for required in (
        "synthetic data only",
        "authoritative data",
        "It does not make",
        "same digest",
        "restore-k-comms-backup-v1",
        "K_COMMS_LIVEKIT_CLOUD_CREDENTIAL",
        "managed_cloud",
        "automatically queues",
        "required reviewer approves",
        "isolated restore rehearsal",
        "Windows or Linux",
        "PowerShell 7",
    ):
        if required not in readme:
            errors.append(f"Proxmox runbook is missing boundary text: {required}")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root",
    )
    args = parser.parse_args()
    errors = validate(args.root.resolve())
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print("Proxmox deployment contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
