#!/usr/bin/env python3
"""Reject a rendered production bundle that still contains fail-closed defaults."""

from __future__ import annotations

import base64
import binascii
import ipaddress
import re
import ssl
import sys
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit

import yaml


IMAGE_DIGEST = re.compile(r"^.+@sha256:[a-f0-9]{64}$")
PLACEHOLDER = re.compile(r"(?:\.invalid\b|CHANGE_ME|REPLACE_WITH)", re.IGNORECASE)
PRODUCTION_NAMESPACE = "k-comms-production"
DATA_PLANE_MARKER = re.compile(
    r"(?:^|[^a-z0-9])(?:postgres(?:ql)?|minio)(?:$|[^a-z0-9])",
    re.IGNORECASE,
)
MEDIA_PLANE_MARKER = re.compile(
    r"(?:^|[^a-z0-9])(?:livekit|coturn|turnserver)(?:$|[^a-z0-9])",
    re.IGNORECASE,
)
DNS_HOSTNAME = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$",
    re.IGNORECASE,
)
LONG_LIVED_WORKLOAD_KINDS = {
    "Deployment",
    "StatefulSet",
    "DaemonSet",
    "ReplicaSet",
    "ReplicationController",
    "Pod",
}
WORKLOAD_OR_SERVICE_KINDS = LONG_LIVED_WORKLOAD_KINDS | {
    "Job",
    "CronJob",
    "Service",
}
CLUSTER_SCOPED_RESOURCES = frozenset(
    {
        ("", "ComponentStatus"),
        ("", "Namespace"),
        ("", "Node"),
        ("", "PersistentVolume"),
        ("admissionregistration.k8s.io", "MutatingWebhookConfiguration"),
        ("admissionregistration.k8s.io", "ValidatingAdmissionPolicy"),
        ("admissionregistration.k8s.io", "ValidatingAdmissionPolicyBinding"),
        ("admissionregistration.k8s.io", "ValidatingWebhookConfiguration"),
        ("apiextensions.k8s.io", "CustomResourceDefinition"),
        ("apiregistration.k8s.io", "APIService"),
        ("authentication.k8s.io", "SelfSubjectReview"),
        ("authentication.k8s.io", "TokenReview"),
        ("authorization.k8s.io", "SelfSubjectAccessReview"),
        ("authorization.k8s.io", "SelfSubjectRulesReview"),
        ("authorization.k8s.io", "SubjectAccessReview"),
        ("certificates.k8s.io", "CertificateSigningRequest"),
        ("certificates.k8s.io", "ClusterTrustBundle"),
        ("flowcontrol.apiserver.k8s.io", "FlowSchema"),
        ("flowcontrol.apiserver.k8s.io", "PriorityLevelConfiguration"),
        ("gateway.networking.k8s.io", "GatewayClass"),
        ("networking.k8s.io", "IngressClass"),
        ("networking.k8s.io", "IPAddress"),
        ("networking.k8s.io", "ServiceCIDR"),
        ("node.k8s.io", "RuntimeClass"),
        ("policy", "PodSecurityPolicy"),
        ("rbac.authorization.k8s.io", "ClusterRole"),
        ("rbac.authorization.k8s.io", "ClusterRoleBinding"),
        ("resource.k8s.io", "DeviceClass"),
        ("resource.k8s.io", "ResourceSlice"),
        ("scheduling.k8s.io", "PriorityClass"),
        ("storage.k8s.io", "CSIDriver"),
        ("storage.k8s.io", "CSINode"),
        ("storage.k8s.io", "StorageClass"),
        ("storage.k8s.io", "VolumeAttachment"),
        ("storage.k8s.io", "VolumeAttributesClass"),
    }
)
WORKER_RELEASE_RPC_COMMAND = [
    "/bin/sh",
    "-ec",
    "ERL_AFLAGS= /app/bin/k_comms rpc 'System.schedulers_online() > 0'",
]
APPLICATION_WORKLOADS = (
    ("Deployment", "k-comms-edge", "edge", True),
    ("Deployment", "k-comms-worker", "worker", True),
    ("Job", "k-comms-migrate", "migrate", False),
)
OPERATION_WORKLOADS = (
    ("Job", "k-comms-platform-role", "platform-role", False),
    (
        "Job",
        "k-comms-attachment-restore-remap",
        "restore-remap",
        False,
    ),
)


def validate(path: Path) -> list[str]:
    return validate_paths([path])


def validate_paths(paths: list[Path]) -> list[str]:
    documents: list[dict] = []
    errors: list[str] = []

    for path in paths:
        if not path.is_file():
            errors.append(f"{path}: file does not exist")
            continue

        try:
            loaded = [
                document
                for document in yaml.safe_load_all(path.read_text(encoding="utf-8"))
                if document
            ]
        except (OSError, UnicodeError, yaml.YAMLError):
            errors.append(f"{path}: rendered bundle is not valid UTF-8 YAML")
            continue
        documents.extend(loaded)

    if errors:
        return errors
    return validate_documents(documents)


def validate_documents(documents: list[dict]) -> list[str]:
    errors: list[str] = []
    if not documents or not all(isinstance(document, dict) for document in documents):
        return ["rendered bundle: every YAML document must be a Kubernetes object"]

    validate_unique_resource_identities(documents, errors)
    validate_resource_namespaces(documents, errors)
    config = named_document(documents, "ConfigMap", "k-comms-config")

    if not config:
        return ["rendered bundle: missing ConfigMap k-comms-config"]

    data = config.get("data") or {}
    required_values = {
        "ALLOW_BOOTSTRAP": "false",
        "ALLOW_DEVELOPMENT_ADAPTERS": "false",
        "ALLOW_DEVELOPMENT_IDENTITY_MODES": "false",
        "AUDIO_PROVIDER_MODE": "livekit",
        "DATABASE_SSL": "true",
        "IDENTITY_PROVIDER_MODE": "oidc",
        "DIRECTORY_PROVISIONING_MODE": "scim",
        "HSTS_ENABLED": "true",
        "NOTIFICATION_PROVIDER_MODE": "http",
        "ATTACHMENT_SCANNER_MODE": "http",
        "WEBHOOK_PROVIDER_MODE": "http",
    }
    for key, expected in required_values.items():
        if str(data.get(key, "")).lower() != expected:
            errors.append(
                f"ConfigMap k-comms-config: {key} must be {expected} for promotion"
            )

    for key in (
        "PHX_HOST",
        "PUBLIC_APP_URL",
        "CORS_ORIGINS",
        "S3_PUBLIC_ENDPOINT",
        "S3_INTERNAL_ENDPOINT",
        "S3_BUCKET",
        "NOTIFICATION_PROVIDER_ENDPOINT",
        "NOTIFICATION_PROVIDER_NAME",
        "NOTIFICATION_PROVIDER_ALLOWED_HOSTS",
        "ATTACHMENT_SCANNER_ENDPOINT",
        "ATTACHMENT_SCANNER_PROVIDER_NAME",
        "ATTACHMENT_SCANNER_ALLOWED_HOSTS",
        "WEBHOOK_ALLOWED_HOSTS",
        "WEB_PUSH_VAPID_PUBLIC_KEY",
        "OIDC_ISSUER",
        "OIDC_CLIENT_ID",
        "OIDC_PROVIDER_NAME",
        "OIDC_REQUIRED_ACR_VALUES",
        "SCIM_PROVIDER_NAME",
        "LIVEKIT_SERVER_URL",
        "LIVEKIT_API_URL",
        "AUDIO_TOKEN_TTL_SECONDS",
        "AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS",
        "CSP_CONNECT_SOURCES",
    ):
        value = str(data.get(key, ""))
        if not value or PLACEHOLDER.search(value):
            errors.append(
                f"ConfigMap k-comms-config: {key} is missing or still a placeholder"
            )

    public_origin = validate_https_origin(data, "PUBLIC_APP_URL", errors)
    validate_https_origin(data, "S3_PUBLIC_ENDPOINT", errors)
    validate_https_origin(data, "S3_INTERNAL_ENDPOINT", errors)
    validate_provider(data, "NOTIFICATION_PROVIDER", errors)
    validate_provider(data, "ATTACHMENT_SCANNER", errors)
    validate_hosts(data.get("WEBHOOK_ALLOWED_HOSTS"), "WEBHOOK_ALLOWED_HOSTS", errors)
    validate_vapid(data.get("WEB_PUSH_VAPID_PUBLIC_KEY"), errors)
    validate_oidc_issuer(data.get("OIDC_ISSUER"), errors)
    validate_livekit(data, errors)
    validate_database_tls(data, documents, errors)

    if public_origin:
        if data.get("PHX_HOST") != public_origin.hostname:
            errors.append(
                "ConfigMap k-comms-config: PHX_HOST must match PUBLIC_APP_URL"
            )
        cors_origins = [
            item.strip() for item in str(data.get("CORS_ORIGINS", "")).split(",")
        ]
        if public_origin.geturl().rstrip("/") not in cors_origins:
            errors.append(
                "ConfigMap k-comms-config: CORS_ORIGINS must include PUBLIC_APP_URL"
            )

    validate_images(documents, errors)
    validate_runtime_purposes(documents, errors)
    validate_workload_contracts(documents, errors)
    validate_provider_secret_refs(documents, errors)
    validate_external_data_plane(documents, errors)
    validate_capacity_controls(documents, errors)
    validate_database_egress(documents, errors)
    validate_trusted_proxy_ingress(data, documents, errors)
    return errors


def validate_unique_resource_identities(
    documents: list[dict], errors: list[str]
) -> None:
    identities: set[tuple[str, str, str, str]] = set()
    for document in documents:
        api_version = document.get("apiVersion")
        kind = document.get("kind")
        metadata = document.get("metadata")
        if (
            not isinstance(api_version, str)
            or not isinstance(kind, str)
            or not isinstance(metadata, dict)
            or not isinstance(metadata.get("name"), str)
        ):
            errors.append(
                "rendered bundle: every resource must have apiVersion, kind, and metadata.name"
            )
            continue

        group = api_version.split("/", 1)[0] if "/" in api_version else ""
        namespace = metadata.get("namespace", "")
        if not isinstance(namespace, str):
            errors.append(f"{kind} {metadata['name']}: metadata.namespace must be text")
            continue
        identity = (group, kind, namespace, metadata["name"])
        if identity in identities:
            errors.append(
                f"{kind} {metadata['name']}: duplicate resource identity in namespace {namespace or '<cluster>'}"
            )
        identities.add(identity)


def validate_resource_namespaces(documents: list[dict], errors: list[str]) -> None:
    for document in documents:
        api_version = document.get("apiVersion")
        kind = document.get("kind")
        metadata = document.get("metadata")
        if (
            not isinstance(api_version, str)
            or not isinstance(kind, str)
            or not isinstance(metadata, dict)
            or not isinstance(metadata.get("name"), str)
        ):
            continue

        group = api_version.split("/", 1)[0] if "/" in api_version else ""
        if (group, kind) in CLUSTER_SCOPED_RESOURCES:
            continue
        if metadata.get("namespace") != PRODUCTION_NAMESPACE:
            errors.append(
                f"{kind} {metadata['name']}: namespace must match the production application namespace {PRODUCTION_NAMESPACE}"
            )


def validate_https_origin(data: dict, key: str, errors: list[str]):
    value = data.get(key)
    try:
        parsed = urlsplit(str(value or ""))
        hostname = parsed.hostname
    except ValueError:
        errors.append(
            f"ConfigMap k-comms-config: {key} must be an absolute HTTPS origin"
        )
        return None
    if (
        parsed.scheme != "https"
        or not hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        errors.append(
            f"ConfigMap k-comms-config: {key} must be an absolute HTTPS origin"
        )
        return None
    return parsed


def validate_oidc_issuer(value, errors: list[str]) -> None:
    try:
        issuer = urlsplit(str(value or ""))
        hostname = issuer.hostname
        port = issuer.port
    except ValueError:
        hostname = None
        port = None
        issuer = None

    if (
        issuer is None
        or issuer.scheme != "https"
        or not hostname
        or not DNS_HOSTNAME.fullmatch(hostname)
        or issuer.username
        or issuer.password
        or issuer.query
        or issuer.fragment
        or port not in {None, 443}
    ):
        errors.append(
            "ConfigMap k-comms-config: OIDC_ISSUER must be an exact HTTPS "
            "issuer URL on port 443 with a DNS hostname"
        )


def validate_livekit(data: dict, errors: list[str]) -> None:
    value = str(data.get("LIVEKIT_SERVER_URL", ""))
    api_value = str(data.get("LIVEKIT_API_URL", ""))
    try:
        endpoint = urlsplit(value)
        hostname = endpoint.hostname
        port = endpoint.port
    except ValueError:
        endpoint = None
        hostname = None
        port = None

    if (
        endpoint is None
        or endpoint.scheme != "wss"
        or not hostname
        or not DNS_HOSTNAME.fullmatch(hostname)
        or endpoint.username
        or endpoint.password
        or endpoint.path not in {"", "/"}
        or endpoint.query
        or endpoint.fragment
        or port not in {None, 443}
    ):
        errors.append(
            "ConfigMap k-comms-config: LIVEKIT_SERVER_URL must be an exact "
            "WSS origin on port 443 with a DNS hostname"
        )

    try:
        api_endpoint = urlsplit(api_value)
        api_hostname = api_endpoint.hostname
        api_port = api_endpoint.port
    except ValueError:
        api_endpoint = None
        api_hostname = None
        api_port = None

    if (
        api_endpoint is None
        or api_endpoint.scheme != "https"
        or not api_hostname
        or not DNS_HOSTNAME.fullmatch(api_hostname)
        or api_endpoint.username
        or api_endpoint.password
        or api_endpoint.path not in {"", "/"}
        or api_endpoint.query
        or api_endpoint.fragment
        or api_port not in {None, 443}
    ):
        errors.append(
            "ConfigMap k-comms-config: LIVEKIT_API_URL must be an exact "
            "HTTPS origin on port 443 with a DNS hostname"
        )

    try:
        token_ttl = int(str(data.get("AUDIO_TOKEN_TTL_SECONDS", "")))
    except ValueError:
        token_ttl = 0
    if not 60 <= token_ttl <= 300:
        errors.append(
            "ConfigMap k-comms-config: AUDIO_TOKEN_TTL_SECONDS must be between 60 and 300"
        )

    try:
        eviction_enforcement = int(
            str(data.get("AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS", ""))
        )
    except ValueError:
        eviction_enforcement = 0
    if not 660 <= eviction_enforcement <= 1_800:
        errors.append(
            "ConfigMap k-comms-config: "
            "AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS must be between 660 and 1800"
        )
    elif eviction_enforcement < token_ttl:
        errors.append(
            "ConfigMap k-comms-config: "
            "AUDIO_PARTICIPANT_EVICTION_ENFORCEMENT_SECONDS must not be shorter than "
            "AUDIO_TOKEN_TTL_SECONDS"
        )

    csp_sources = {
        item.strip()
        for item in str(data.get("CSP_CONNECT_SOURCES", "")).split()
        if item.strip()
    }
    if value not in csp_sources:
        errors.append(
            "ConfigMap k-comms-config: CSP_CONNECT_SOURCES must contain the exact "
            "LIVEKIT_SERVER_URL origin"
        )


def validate_provider(data: dict, prefix: str, errors: list[str]) -> None:
    endpoint_key = f"{prefix}_ENDPOINT"
    hosts_key = f"{prefix}_ALLOWED_HOSTS"
    hosts = validate_hosts(data.get(hosts_key), hosts_key, errors)

    try:
        endpoint = urlsplit(str(data.get(endpoint_key, "")))
        hostname = endpoint.hostname
        port = endpoint.port
    except ValueError:
        errors.append(
            f"ConfigMap k-comms-config: {endpoint_key} must be an HTTPS port-443 URL"
        )
        return

    if (
        endpoint.scheme != "https"
        or not hostname
        or endpoint.username
        or endpoint.password
        or endpoint.fragment
        or port not in {None, 443}
    ):
        errors.append(
            f"ConfigMap k-comms-config: {endpoint_key} must be an HTTPS port-443 URL"
        )
    elif hostname.lower() not in hosts:
        errors.append(
            f"ConfigMap k-comms-config: {endpoint_key} host must be present in {hosts_key}"
        )


def validate_hosts(value, key: str, errors: list[str]) -> set[str]:
    hosts = {
        item.strip().lower().rstrip(".")
        for item in str(value or "").split(",")
        if item.strip()
    }
    if not hosts:
        errors.append(
            f"ConfigMap k-comms-config: {key} must contain explicit hostnames"
        )
    return hosts


def validate_vapid(value, errors: list[str]) -> None:
    try:
        encoded = str(value or "")
        decoded = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
    except (ValueError, binascii.Error):
        decoded = b""
    if len(decoded) != 65 or not decoded.startswith(b"\x04"):
        errors.append(
            "ConfigMap k-comms-config: WEB_PUSH_VAPID_PUBLIC_KEY must encode an uncompressed P-256 public key"
        )


def validate_database_tls(
    data: dict, documents: list[dict], errors: list[str]
) -> None:
    server_name = str(data.get("DATABASE_SSL_SERVER_NAME", "")).strip()
    if (
        not server_name
        or PLACEHOLDER.search(server_name)
        or not DNS_HOSTNAME.fullmatch(server_name)
    ):
        errors.append(
            "ConfigMap k-comms-config: DATABASE_SSL_SERVER_NAME must be a non-placeholder DNS hostname"
        )

    ca_file = str(data.get("DATABASE_SSL_CA_FILE", "")).strip()
    ca_path = PurePosixPath(ca_file)
    if (
        not ca_file.startswith("/")
        or ca_file == "/"
        or ".." in ca_path.parts
        or str(ca_path) != ca_file
    ):
        errors.append(
            "ConfigMap k-comms-config: DATABASE_SSL_CA_FILE must be a normalized absolute path"
        )
        return

    ca_config = named_document(documents, "ConfigMap", "k-comms-database-ca")
    ca_value = (ca_config or {}).get("data", {}).get("ca.crt")
    if (
        not ca_config
        or not isinstance(ca_value, str)
        or not ca_value.strip()
        or PLACEHOLDER.search(ca_value)
        or not _valid_pem_certificate_bundle(ca_value)
    ):
        errors.append(
            "rendered bundle: ConfigMap k-comms-database-ca must contain ca.crt with a syntactically valid non-placeholder PEM certificate bundle"
        )

    tls_workloads = [
        ("Deployment", "k-comms-edge"),
        ("Deployment", "k-comms-worker"),
        ("Job", "k-comms-migrate"),
    ]
    tls_workloads.extend(
        (kind, name)
        for kind, name, _container_name, _requires_probes in OPERATION_WORKLOADS
        if named_document(documents, kind, name)
    )
    for kind, name in tls_workloads:
        document = named_document(documents, kind, name)
        if not document:
            continue
        pod_spec = _pod_spec(document)
        volumes = pod_spec.get("volumes", [])
        ca_volumes = {
            volume.get("name"): volume
            for volume in volumes
            if isinstance(volume, dict)
            and volume.get("name")
            and isinstance(volume.get("configMap"), dict)
            and volume.get("configMap", {}).get("name") == "k-comms-database-ca"
            and _config_map_volume_exposes_ca(volume.get("configMap", {}))
        }
        containers = pod_spec.get("containers", [])
        mounts = containers[0].get("volumeMounts", []) if containers else []
        matching_mount = any(
            isinstance(mount, dict)
            and mount.get("name") in ca_volumes
            and mount.get("readOnly") is True
            and _mount_exposes_ca_file(mount, ca_file)
            for mount in mounts
        )
        if not ca_volumes or not matching_mount:
            errors.append(
                f"{kind} {name}: must mount k-comms-database-ca ca.crt read-only at DATABASE_SSL_CA_FILE"
            )


def _valid_pem_certificate_bundle(value: str) -> bool:
    try:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_verify_locations(cadata=value)
        return context.cert_store_stats().get("x509", 0) > 0
    except (ssl.SSLError, ValueError):
        return False


def _config_map_volume_exposes_ca(config_map: dict) -> bool:
    if config_map.get("optional") is True:
        return False
    items = config_map.get("items")
    if items is None:
        return True
    return (
        isinstance(items, list)
        and len(items) == 1
        and isinstance(items[0], dict)
        and items[0].get("key") == "ca.crt"
        and items[0].get("path") == "ca.crt"
    )


def _mount_exposes_ca_file(mount: dict, ca_file: str) -> bool:
    mount_path = str(mount.get("mountPath", ""))
    sub_path = mount.get("subPath")
    if sub_path is not None:
        return sub_path == "ca.crt" and mount_path == ca_file
    return str(PurePosixPath(mount_path) / "ca.crt") == ca_file


def validate_images(documents: list[dict], errors: list[str]) -> None:
    expected = (
        ("Deployment", "k-comms-edge"),
        ("Deployment", "k-comms-worker"),
        ("Job", "k-comms-migrate"),
    )
    immutable_images: set[str] = set()
    for kind, name in expected:
        document = named_document(documents, kind, name)
        if not document:
            errors.append(f"rendered bundle: missing {kind} {name}")
            continue
        containers = (
            document.get("spec", {})
            .get("template", {})
            .get("spec", {})
            .get("containers", [])
        )
        image = str(containers[0].get("image", "")) if containers else ""
        if not IMAGE_DIGEST.fullmatch(image):
            errors.append(f"{kind} {name}: image must use an immutable sha256 digest")
        else:
            immutable_images.add(image)

    if len(immutable_images) > 1:
        errors.append(
            "Deployment edge/worker and migration Job must use the same exact immutable image reference and sha256 digest"
        )

    approved_image = next(iter(immutable_images)) if len(immutable_images) == 1 else None
    for kind, name, _container_name, _requires_probes in OPERATION_WORKLOADS:
        document = named_document(documents, kind, name)
        if not document:
            continue
        containers = _pod_spec(document).get("containers", [])
        image = str(containers[0].get("image", "")) if containers else ""
        if not IMAGE_DIGEST.fullmatch(image):
            errors.append(f"{kind} {name}: image must use an immutable sha256 digest")
        elif approved_image is None or image != approved_image:
            errors.append(
                f"{kind} {name}: operation image must exactly match the approved application image"
            )


def validate_runtime_purposes(documents: list[dict], errors: list[str]) -> None:
    for kind, name in (
        ("Deployment", "k-comms-edge"),
        ("Deployment", "k-comms-worker"),
        ("Job", "k-comms-migrate"),
    ):
        document = named_document(documents, kind, name)
        if not document:
            continue
        containers = (
            document.get("spec", {})
            .get("template", {})
            .get("spec", {})
            .get("containers", [])
        )
        environment = {
            item.get("name"): item.get("value")
            for item in (containers[0].get("env", []) if containers else [])
        }
        purpose = environment.get("K_COMMS_RUNTIME_PURPOSE", "application")
        expected = "one_shot" if kind == "Job" else "application"
        if purpose != expected:
            errors.append(f"{kind} {name}: K_COMMS_RUNTIME_PURPOSE must be {expected}")

    for document in documents:
        kind = document.get("kind")
        name = document.get("metadata", {}).get("name", "<unnamed>")
        if kind not in LONG_LIVED_WORKLOAD_KINDS:
            continue

        pod_spec = _pod_spec(document)
        containers = list(pod_spec.get("containers", [])) + list(
            pod_spec.get("initContainers", [])
        )
        has_one_shot = any(
            any(
                item.get("name") == "K_COMMS_RUNTIME_PURPOSE"
                and item.get("value") == "one_shot"
                for item in container.get("env", [])
            )
            for container in containers
        )
        if has_one_shot:
            errors.append(
                f"{kind} {name}: long-lived workload must not use K_COMMS_RUNTIME_PURPOSE=one_shot"
            )


def validate_workload_contracts(documents: list[dict], errors: list[str]) -> None:
    edge = named_document(documents, "Deployment", "k-comms-edge")
    production_namespace = (
        edge.get("metadata", {}).get("namespace") if edge else None
    )
    if not isinstance(production_namespace, str) or not production_namespace:
        errors.append(
            "Deployment k-comms-edge: rendered production workload must have an explicit namespace"
        )
        production_namespace = None

    for kind, name, container_name, requires_probes in (
        APPLICATION_WORKLOADS + OPERATION_WORKLOADS
    ):
        document = named_document(documents, kind, name)
        if not document:
            continue
        pod_spec = _pod_spec(document)
        containers = pod_spec.get("containers")
        if (
            not isinstance(containers, list)
            or len(containers) != 1
            or not isinstance(containers[0], dict)
            or containers[0].get("name") != container_name
        ):
            errors.append(
                f"{kind} {name}: must contain exactly the intended {container_name} container"
            )
            continue

        for extra_kind in ("initContainers", "ephemeralContainers"):
            extras = pod_spec.get(extra_kind, [])
            if not isinstance(extras, list) or extras:
                errors.append(
                    f"{kind} {name}: production workload must not contain {extra_kind}"
                )

        _validate_pod_security(kind, name, pod_spec, errors)
        _validate_container_security(kind, name, containers[0], errors)
        if requires_probes:
            _validate_application_probes(kind, name, container_name, containers[0], errors)
        elif kind == "Job" and pod_spec.get("restartPolicy") != "Never":
            errors.append(f"Job {name}: restartPolicy must be Never")


def validate_provider_secret_refs(documents: list[dict], errors: list[str]) -> None:
    for name in ("k-comms-edge", "k-comms-worker"):
        document = named_document(documents, "Deployment", name)
        if not document:
            continue
        containers = _pod_spec(document).get("containers", [])
        env_from = containers[0].get("envFrom", []) if containers else []
        provider_ref = next(
            (
                item.get("secretRef")
                for item in env_from
                if isinstance(item, dict)
                and isinstance(item.get("secretRef"), dict)
                and item["secretRef"].get("name") == "k-comms-provider-secrets"
            ),
            None,
        )
        if not isinstance(provider_ref, dict) or provider_ref.get("optional") is not False:
            errors.append(
                f"Deployment {name}: k-comms-provider-secrets must be an explicit non-optional envFrom reference"
            )


def _validate_pod_security(
    kind: str, name: str, pod_spec: dict, errors: list[str]
) -> None:
    security = pod_spec.get("securityContext")
    expected_security = {
        "runAsNonRoot": True,
        "runAsUser": 10001,
        "runAsGroup": 10001,
        "fsGroup": 10001,
    }
    if (
        pod_spec.get("serviceAccountName") != "k-comms"
        or pod_spec.get("automountServiceAccountToken") is not False
    ):
        errors.append(
            f"{kind} {name}: must use service account k-comms with token automount disabled"
        )
    if any(pod_spec.get(field) is True for field in ("hostNetwork", "hostPID", "hostIPC")):
        errors.append(f"{kind} {name}: host namespace sharing is forbidden")
    if (
        not isinstance(security, dict)
        or any(security.get(key) != value for key, value in expected_security.items())
        or security.get("seccompProfile") != {"type": "RuntimeDefault"}
    ):
        errors.append(
            f"{kind} {name}: pod security context must enforce non-root UID/GID 10001 and RuntimeDefault seccomp"
        )


def _validate_container_security(
    kind: str, name: str, container: dict, errors: list[str]
) -> None:
    security = container.get("securityContext")
    capabilities = security.get("capabilities") if isinstance(security, dict) else None
    if (
        not isinstance(security, dict)
        or security.get("privileged") is True
        or security.get("allowPrivilegeEscalation") is not False
        or security.get("readOnlyRootFilesystem") is not True
        or not isinstance(capabilities, dict)
        or capabilities.get("drop") != ["ALL"]
        or bool(capabilities.get("add"))
    ):
        errors.append(
            f"{kind} {name}: container must be non-privileged, read-only, and drop all capabilities"
        )


def _validate_application_probes(
    kind: str,
    name: str,
    container_name: str,
    container: dict,
    errors: list[str],
) -> None:
    probes = {
        probe_name: container.get(probe_name)
        for probe_name in ("startupProbe", "readinessProbe", "livenessProbe")
    }
    if not all(isinstance(probe, dict) and probe for probe in probes.values()):
        errors.append(
            f"{kind} {name}: startup, readiness, and liveness probes are required"
        )
        return

    if container_name == "edge":
        expected = {
            "startupProbe": {"path": "/health/live", "port": "http"},
            "readinessProbe": {"path": "/health/ready", "port": "http"},
            "livenessProbe": {"path": "/health/live", "port": "http"},
        }
        if any(probes[key].get("httpGet") != value for key, value in expected.items()):
            errors.append(
                "Deployment k-comms-edge: probes must use the retained live/ready HTTP endpoints"
            )
    elif any(
        not isinstance(probe.get("exec"), dict)
        or probe["exec"].get("command") != WORKER_RELEASE_RPC_COMMAND
        for probe in probes.values()
    ):
        errors.append(
            "Deployment k-comms-worker: probes must use the exact retained release RPC health-check command"
        )


def validate_external_data_plane(documents: list[dict], errors: list[str]) -> None:
    for document in documents:
        kind = document.get("kind")
        name = str(document.get("metadata", {}).get("name", "<unnamed>"))

        if kind in {"StatefulSet", "PersistentVolumeClaim"}:
            errors.append(
                f"{kind} {name}: production bundle must not contain StatefulSets or PersistentVolumeClaims"
            )

        if kind in WORKLOAD_OR_SERVICE_KINDS and _has_data_plane_marker(document):
            errors.append(
                f"{kind} {name}: production bundle must not deploy in-namespace PostgreSQL or MinIO workloads/services"
            )
        if kind in WORKLOAD_OR_SERVICE_KINDS and _has_media_plane_marker(document):
            errors.append(
                f"{kind} {name}: production application bundle must reference an external media provider, not deploy LiveKit or TURN"
            )


def validate_capacity_controls(documents: list[dict], errors: list[str]) -> None:
    required_replicas = {"k-comms-edge": 3, "k-comms-worker": 2}

    for name, minimum in required_replicas.items():
        deployment = named_document(documents, "Deployment", name)
        if not deployment:
            continue

        replicas = deployment.get("spec", {}).get("replicas")
        if (
            isinstance(replicas, bool)
            or not isinstance(replicas, int)
            or replicas < minimum
        ):
            errors.append(
                f"Deployment {name}: replicas must be at least {minimum} for production"
            )

        hpa = named_document(documents, "HorizontalPodAutoscaler", name)
        if not hpa:
            errors.append(f"rendered bundle: missing HorizontalPodAutoscaler {name}")
        else:
            hpa_spec = hpa.get("spec", {})
            expected_target = {
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "name": name,
            }
            if hpa_spec.get("scaleTargetRef") != expected_target:
                errors.append(
                    f"HorizontalPodAutoscaler {name}: scaleTargetRef must match Deployment {name}"
                )
            min_replicas = hpa_spec.get("minReplicas")
            if (
                isinstance(min_replicas, bool)
                or not isinstance(min_replicas, int)
                or min_replicas < minimum
            ):
                errors.append(
                    f"HorizontalPodAutoscaler {name}: minReplicas must be at least {minimum}"
                )
            max_replicas = hpa_spec.get("maxReplicas")
            if (
                isinstance(max_replicas, bool)
                or not isinstance(max_replicas, int)
                or not isinstance(min_replicas, int)
                or max_replicas < min_replicas
                or not isinstance(hpa_spec.get("metrics"), list)
                or not hpa_spec.get("metrics")
            ):
                errors.append(
                    f"HorizontalPodAutoscaler {name}: maxReplicas and metrics must define effective autoscaling"
                )

        pdb = named_document(documents, "PodDisruptionBudget", name)
        if not pdb:
            errors.append(f"rendered bundle: missing PodDisruptionBudget {name}")
        else:
            deployment_selector = deployment.get("spec", {}).get("selector")
            pdb_spec = pdb.get("spec", {})
            pdb_selector = pdb_spec.get("selector")
            if (
                not isinstance(deployment_selector, dict)
                or not deployment_selector
                or pdb_selector != deployment_selector
            ):
                errors.append(
                    f"PodDisruptionBudget {name}: selector must exactly match Deployment {name}"
                )
            availability_keys = {"minAvailable", "maxUnavailable"} & set(pdb_spec)
            if len(availability_keys) != 1:
                errors.append(
                    f"PodDisruptionBudget {name}: must define exactly one of minAvailable or maxUnavailable"
                )
            elif "minAvailable" in availability_keys:
                available = _effective_int_or_percent(
                    pdb_spec.get("minAvailable"), minimum
                )
                if available is None or available < minimum - 1:
                    errors.append(
                        f"PodDisruptionBudget {name}: must keep at least {minimum - 1} replicas available"
                    )
            else:
                unavailable = _effective_int_or_percent(
                    pdb_spec.get("maxUnavailable"), minimum
                )
                if unavailable is None or unavailable > 1:
                    errors.append(
                        f"PodDisruptionBudget {name}: must allow at most one unavailable replica"
                    )


def _effective_int_or_percent(value, total: int) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int) and value >= 0:
        return value
    if isinstance(value, str) and re.fullmatch(r"(?:0|[1-9][0-9]?|100)%", value):
        percentage = int(value[:-1])
        return (percentage * total + 99) // 100
    return None


def validate_database_egress(documents: list[dict], errors: list[str]) -> None:
    policy = named_document(
        documents, "NetworkPolicy", "k-comms-managed-postgres-egress"
    )
    if not policy:
        errors.append(
            "rendered bundle: missing narrowed managed PostgreSQL egress policy"
        )
        return

    spec = policy.get("spec", {})
    expected_selector = {
        "matchLabels": {"app.kubernetes.io/name": "k-comms"}
    }
    if spec.get("podSelector") != expected_selector:
        errors.append(
            "NetworkPolicy k-comms-managed-postgres-egress: podSelector must exactly match k-comms application pods"
        )

    if spec.get("policyTypes") != ["Egress"]:
        errors.append(
            "NetworkPolicy k-comms-managed-postgres-egress: policyTypes must contain only Egress"
        )

    egress_rules = spec.get("egress")
    if not isinstance(egress_rules, list) or not egress_rules:
        errors.append(
            "NetworkPolicy k-comms-managed-postgres-egress: every database destination must be an explicit valid ipBlock"
        )
        return

    networks: set[ipaddress._BaseNetwork] = set()
    invalid_destination = False
    invalid_ports = False
    unsafe_network = False
    forbidden_broad_private = {
        ipaddress.ip_network("10.0.0.0/8"),
        ipaddress.ip_network("172.16.0.0/12"),
        ipaddress.ip_network("192.168.0.0/16"),
        ipaddress.ip_network("fc00::/7"),
    }

    for rule in egress_rules:
        if not isinstance(rule, dict):
            invalid_destination = True
            invalid_ports = True
            continue
        ports = rule.get("ports")
        if (
            not isinstance(ports, list)
            or len(ports) != 1
            or not isinstance(ports[0], dict)
            or ports[0].get("protocol") != "TCP"
            or ports[0].get("port") != 5432
            or set(ports[0]) != {"protocol", "port"}
        ):
            invalid_ports = True

        destinations = rule.get("to")
        if not isinstance(destinations, list) or not destinations:
            invalid_destination = True
            continue

        for destination in destinations:
            if (
                not isinstance(destination, dict)
                or set(destination) != {"ipBlock"}
                or not isinstance(destination.get("ipBlock"), dict)
                or set(destination["ipBlock"]) != {"cidr"}
                or not isinstance(destination["ipBlock"].get("cidr"), str)
            ):
                invalid_destination = True
                continue

            try:
                network = ipaddress.ip_network(
                    destination["ipBlock"]["cidr"], strict=True
                )
            except (TypeError, ValueError):
                invalid_destination = True
                continue

            networks.add(network)
            if (
                network.prefixlen == 0
                or network.is_global
                or network.is_loopback
                or network.is_link_local
                or network.is_multicast
                or network.is_unspecified
                or network.is_reserved
                or not network.is_private
                or network.prefixlen < (16 if network.version == 4 else 48)
                or any(
                    network == forbidden or network.supernet_of(forbidden)
                    for forbidden in forbidden_broad_private
                    if network.version == forbidden.version
                )
            ):
                unsafe_network = True

    if invalid_destination:
        errors.append(
            "NetworkPolicy k-comms-managed-postgres-egress: every database destination must be an explicit valid ipBlock"
        )
    if invalid_ports:
        errors.append(
            "NetworkPolicy k-comms-managed-postgres-egress: every egress rule must expose only TCP port 5432"
        )

    if _covers_forbidden_network(networks, forbidden_broad_private):
        unsafe_network = True
    if unsafe_network:
        errors.append(
            "NetworkPolicy k-comms-managed-postgres-egress: database CIDR must be narrowed and must not include unsafe or globally routable networks"
        )

    if _covers_address_family(networks):
        errors.append(
            "NetworkPolicy k-comms-managed-postgres-egress: database CIDRs must not collectively cover an address family"
        )


def validate_trusted_proxy_ingress(
    data: dict, documents: list[dict], errors: list[str]
) -> None:
    raw_cidrs = [
        item.strip()
        for item in str(data.get("TRUSTED_PROXY_CIDRS", "")).split(",")
        if item.strip()
    ]
    trusted_cidrs: set[ipaddress._BaseNetwork] = set()

    if not raw_cidrs:
        errors.append(
            "ConfigMap k-comms-config: TRUSTED_PROXY_CIDRS must contain provider-specific ingress ranges"
        )

    forbidden_private_defaults = {
        ipaddress.ip_network("10.0.0.0/8"),
        ipaddress.ip_network("172.16.0.0/12"),
        ipaddress.ip_network("192.168.0.0/16"),
    }
    unsafe_trusted_range = False

    for raw_cidr in raw_cidrs:
        try:
            network = ipaddress.ip_network(raw_cidr, strict=True)
        except ValueError:
            errors.append(
                "ConfigMap k-comms-config: TRUSTED_PROXY_CIDRS contains an invalid network"
            )
            continue

        if (
            network.prefixlen == 0
            or network.is_loopback
            or network.is_link_local
            or network.is_multicast
            or any(
                network == private_default or network.supernet_of(private_default)
                for private_default in forbidden_private_defaults
                if network.version == private_default.version
            )
        ):
            unsafe_trusted_range = True
        trusted_cidrs.add(network)

    if _covers_forbidden_network(trusted_cidrs, forbidden_private_defaults):
        unsafe_trusted_range = True
    if unsafe_trusted_range:
        errors.append(
            "ConfigMap k-comms-config: TRUSTED_PROXY_CIDRS must not trust generic or unsafe ranges"
        )

    policy = named_document(documents, "NetworkPolicy", "k-comms-edge-ingress")
    if not policy:
        errors.append("rendered bundle: missing NetworkPolicy k-comms-edge-ingress")
        return

    ingress_rules = policy.get("spec", {}).get("ingress", [])
    if not ingress_rules:
        errors.append(
            "NetworkPolicy k-comms-edge-ingress: provider ingress sources must be explicit"
        )
        return

    policy_cidrs: set[ipaddress._BaseNetwork] = set()
    unrestricted_rule = False
    invalid_policy_cidr = False
    invalid_policy_ports = False
    for rule in ingress_rules:
        ports = rule.get("ports")
        if (
            not isinstance(ports, list)
            or len(ports) != 1
            or not isinstance(ports[0], dict)
            or ports[0].get("protocol") != "TCP"
            or ports[0].get("port") != 4000
            or set(ports[0]) != {"protocol", "port"}
        ):
            invalid_policy_ports = True

        sources = rule.get("from")
        if not sources:
            unrestricted_rule = True
            continue
        for source in sources:
            raw_policy_cidr = source.get("ipBlock", {}).get("cidr")
            if not raw_policy_cidr:
                unrestricted_rule = True
                continue
            try:
                policy_cidrs.add(ipaddress.ip_network(raw_policy_cidr, strict=True))
            except ValueError:
                invalid_policy_cidr = True

    if unrestricted_rule or invalid_policy_cidr:
        errors.append(
            "NetworkPolicy k-comms-edge-ingress: every source must be an explicit valid ipBlock"
        )
    if invalid_policy_ports:
        errors.append(
            "NetworkPolicy k-comms-edge-ingress: every ingress rule must expose only TCP port 4000"
        )
    if policy_cidrs != trusted_cidrs:
        errors.append(
            "NetworkPolicy k-comms-edge-ingress: source CIDRs must exactly match TRUSTED_PROXY_CIDRS"
        )


def _pod_spec(document: dict) -> dict:
    kind = document.get("kind")
    spec = document.get("spec", {})
    if not isinstance(spec, dict):
        return {}
    if kind == "Pod":
        return spec
    if kind == "CronJob":
        pod_spec = (
            spec.get("jobTemplate", {})
            .get("spec", {})
            .get("template", {})
            .get("spec", {})
        )
    else:
        pod_spec = spec.get("template", {}).get("spec", {})
    return pod_spec if isinstance(pod_spec, dict) else {}


def _has_data_plane_marker(document: dict) -> bool:
    return _has_plane_marker(document, DATA_PLANE_MARKER)


def _has_media_plane_marker(document: dict) -> bool:
    return _has_plane_marker(document, MEDIA_PLANE_MARKER)


def _has_plane_marker(document: dict, marker: re.Pattern) -> bool:
    metadata = document.get("metadata", {})
    spec = document.get("spec", {})
    if not isinstance(metadata, dict) or not isinstance(spec, dict):
        return False

    signals = [str(metadata.get("name", ""))]
    labels = metadata.get("labels", {})
    if isinstance(labels, dict):
        signals.extend(str(value) for value in labels.values())

    selector = spec.get("selector", {})
    if isinstance(selector, dict):
        match_labels = selector.get("matchLabels")
        if isinstance(match_labels, dict):
            signals.extend(str(value) for value in match_labels.values())
        else:
            signals.extend(str(value) for value in selector.values())

    if document.get("kind") == "Service":
        signals.append(str(spec.get("externalName", "")))
        for port in spec.get("ports", []):
            if isinstance(port, dict):
                signals.extend(
                    (str(port.get("name", "")), str(port.get("appProtocol", "")))
                )

    template_labels = spec.get("template", {}).get("metadata", {}).get("labels", {})
    if isinstance(template_labels, dict):
        signals.extend(str(value) for value in template_labels.values())

    pod_spec = _pod_spec(document)
    for key in ("containers", "initContainers"):
        for container in pod_spec.get(key, []):
            if isinstance(container, dict):
                signals.extend(
                    (str(container.get("name", "")), str(container.get("image", "")))
                )

    return any(marker.search(signal) for signal in signals)


def _covers_address_family(networks: set[ipaddress._BaseNetwork]) -> bool:
    for version in (4, 6):
        collapsed = ipaddress.collapse_addresses(
            network for network in networks if network.version == version
        )
        if any(network.prefixlen == 0 for network in collapsed):
            return True
    return False


def _covers_forbidden_network(
    configured: set[ipaddress._BaseNetwork],
    forbidden: set[ipaddress._BaseNetwork],
) -> bool:
    for forbidden_network in forbidden:
        collapsed = ipaddress.collapse_addresses(
            network
            for network in configured
            if network.version == forbidden_network.version
        )
        if any(
            network == forbidden_network or network.supernet_of(forbidden_network)
            for network in collapsed
        ):
            return True
    return False


def named_document(documents: list[dict], kind: str, name: str) -> dict | None:
    return next(
        (
            document
            for document in documents
            if document.get("kind") == kind
            and document.get("metadata", {}).get("name") == name
        ),
        None,
    )


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(
            "usage: validate_production_bundle.py RENDERED_BUNDLE.yaml [RENDERED_OPERATION_BUNDLE.yaml ...]"
        )

    errors = validate_paths([Path(argument) for argument in sys.argv[1:]])
    if errors:
        raise SystemExit("Production promotion preflight failed:\n" + "\n".join(errors))

    print("Production promotion preflight passed")


if __name__ == "__main__":
    main()
