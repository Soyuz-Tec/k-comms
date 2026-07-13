from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

import yaml

from validate_production_bundle import validate, validate_documents, validate_paths


VAPID_PUBLIC_KEY = "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo"
DIGEST_IMAGE = "ghcr.io/soyuz-tec/k-comms@sha256:" + "a" * 64
PRODUCTION_NAMESPACE = "k-comms-production"
CA_PEM = (
    Path(__file__).resolve().parents[1]
    / "apps"
    / "comms_core"
    / "test"
    / "fixtures"
    / "database-ca.crt"
).read_text(encoding="utf-8")


class ValidateProductionBundleTest(unittest.TestCase):
    def test_accepts_a_fully_composed_provider_bundle(self) -> None:
        self.assertEqual(validate_documents(valid_documents()), [])

    def test_rejects_fail_closed_defaults_placeholders_and_mutable_images(self) -> None:
        documents = valid_documents()
        config = documents[0]["data"]
        config.update(
            {
                "PHX_HOST": "comms.example.invalid",
                "PUBLIC_APP_URL": "https://comms.example.invalid",
                "NOTIFICATION_PROVIDER_MODE": "disabled",
                "ATTACHMENT_SCANNER_MODE": "disabled",
                "WEBHOOK_PROVIDER_MODE": "disabled",
                "WEB_PUSH_VAPID_PUBLIC_KEY": "",
            }
        )
        documents[1]["spec"]["template"]["spec"]["containers"][0]["image"] = (
            "ghcr.io/soyuz-tec/k-comms:production-candidate"
        )
        documents[4]["spec"]["egress"][0]["to"][0]["ipBlock"]["cidr"] = "0.0.0.0/0"

        errors = validate_documents(documents)
        self.assertTrue(
            any("NOTIFICATION_PROVIDER_MODE must be http" in error for error in errors)
        )
        self.assertTrue(
            any(
                "PHX_HOST is missing or still a placeholder" in error
                for error in errors
            )
        )
        self.assertTrue(any("immutable sha256 digest" in error for error in errors))
        self.assertTrue(
            any("database CIDR must be narrowed" in error for error in errors)
        )

    def test_rejects_provider_endpoint_not_present_in_the_allowlist(self) -> None:
        documents = valid_documents()
        documents[0]["data"]["NOTIFICATION_PROVIDER_ENDPOINT"] = (
            "https://unapproved.example.com/v1/deliver"
        )

        errors = validate_documents(documents)
        self.assertTrue(
            any(
                "NOTIFICATION_PROVIDER_ENDPOINT host must be present" in error
                for error in errors
            )
        )

    def test_rejects_provider_preflight_bypass_on_long_lived_workloads(self) -> None:
        documents = valid_documents()
        documents[1]["spec"]["template"]["spec"]["containers"][0]["env"] = [
            {"name": "K_COMMS_RUNTIME_PURPOSE", "value": "one_shot"}
        ]

        errors = validate_documents(documents)
        self.assertTrue(
            any(
                "Deployment k-comms-edge: K_COMMS_RUNTIME_PURPOSE must be application"
                in error
                for error in errors
            )
        )

    def test_rejects_one_shot_bypass_on_any_long_lived_workload(self) -> None:
        documents = valid_documents()
        extra_workload = workload("Deployment", "k-comms-reporting")
        extra_workload["spec"]["template"]["spec"]["containers"][0]["env"] = [
            {"name": "K_COMMS_RUNTIME_PURPOSE", "value": "one_shot"}
        ]
        documents.append(extra_workload)

        errors = validate_documents(documents)

        self.assertTrue(
            any(
                "long-lived workload must not use K_COMMS_RUNTIME_PURPOSE=one_shot"
                in error
                for error in errors
            )
        )

        documents = valid_documents()
        edge = find_document(documents, "Deployment", "k-comms-edge")
        edge["spec"]["template"]["spec"]["initContainers"] = [
            {
                "name": "preflight-bypass",
                "image": DIGEST_IMAGE,
                "env": [
                    {"name": "K_COMMS_RUNTIME_PURPOSE", "value": "one_shot"}
                ],
            }
        ]
        self.assertTrue(
            any(
                "long-lived workload must not use K_COMMS_RUNTIME_PURPOSE=one_shot"
                in error
                for error in validate_documents(documents)
            )
        )

    def test_rejects_mismatched_application_image_digests(self) -> None:
        documents = valid_documents()
        documents[2]["spec"]["template"]["spec"]["containers"][0]["image"] = (
            "ghcr.io/soyuz-tec/k-comms@sha256:" + "b" * 64
        )

        errors = validate_documents(documents)

        self.assertTrue(any("same exact immutable image" in error for error in errors))

    def test_rejects_duplicate_resource_identities_before_apply_order_can_win(self) -> None:
        documents = valid_documents()
        documents.append(
            copy.deepcopy(find_document(documents, "Deployment", "k-comms-edge"))
        )

        errors = validate_documents(documents)

        self.assertTrue(any("duplicate resource identity" in error for error in errors))

    def test_rejects_extra_mutable_or_privileged_application_containers(self) -> None:
        documents = valid_documents()
        edge = find_document(documents, "Deployment", "k-comms-edge")
        edge["spec"]["template"]["spec"]["containers"].append(
            {
                "name": "injected-sidecar",
                "image": "evil.example/agent:latest",
                "securityContext": {"privileged": True},
            }
        )

        errors = validate_documents(documents)

        self.assertTrue(
            any("must contain exactly the intended edge container" in error for error in errors)
        )

    def test_rejects_unsafe_workload_security_or_missing_probes(self) -> None:
        mutations = (
            (
                lambda spec, container: spec.update(
                    {"automountServiceAccountToken": True}
                ),
                "token automount disabled",
            ),
            (
                lambda spec, container: container["securityContext"].update(
                    {"privileged": True}
                ),
                "container must be non-privileged",
            ),
            (
                lambda spec, container: container.pop("readinessProbe"),
                "startup, readiness, and liveness probes",
            ),
        )
        for mutate, expected in mutations:
            with self.subTest(expected=expected):
                documents = valid_documents()
                edge = find_document(documents, "Deployment", "k-comms-edge")
                spec = edge["spec"]["template"]["spec"]
                mutate(spec, spec["containers"][0])
                self.assertTrue(
                    any(expected in error for error in validate_documents(documents))
                )

    def test_rejects_ineffective_disruption_budgets(self) -> None:
        cases = (("k-comms-edge", 1, "at least 2"), ("k-comms-worker", 0, "at least 1"))
        for name, min_available, expected in cases:
            with self.subTest(name=name):
                documents = valid_documents()
                find_document(documents, "PodDisruptionBudget", name)["spec"][
                    "minAvailable"
                ] = min_available
                self.assertTrue(
                    any(expected in error for error in validate_documents(documents))
                )

    def test_rejects_a_non_certificate_database_ca(self) -> None:
        documents = valid_documents()
        find_document(documents, "ConfigMap", "k-comms-database-ca")["data"][
            "ca.crt"
        ] = "-----BEGIN CERTIFICATE-----\nnot-a-certificate\n-----END CERTIFICATE-----\n"

        self.assertTrue(
            any(
                "syntactically valid" in error
                for error in validate_documents(documents)
            )
        )

    def test_validates_privileged_operation_jobs_against_the_approved_image(self) -> None:
        documents = valid_documents()
        operation = workload("Job", "k-comms-platform-role")
        operation["spec"]["template"]["spec"]["containers"][0]["name"] = (
            "platform-role"
        )
        documents.append(operation)
        self.assertEqual(validate_documents(documents), [])

        operation["spec"]["template"]["spec"]["containers"][0]["image"] = (
            "ghcr.io/soyuz-tec/k-comms:staging"
        )
        self.assertTrue(
            any(
                "image must use an immutable sha256 digest" in error
                for error in validate_documents(documents)
            )
        )

        operation["spec"]["template"]["spec"]["containers"][0]["image"] = DIGEST_IMAGE
        operation["spec"]["template"]["spec"]["volumes"][0]["configMap"][
            "optional"
        ] = True
        self.assertTrue(
            any(
                "must mount k-comms-database-ca" in error
                for error in validate_documents(documents)
            )
        )

        operation["spec"]["template"]["spec"]["volumes"][0]["configMap"].pop(
            "optional"
        )
        operation["metadata"]["namespace"] = "other-namespace"
        self.assertTrue(
            any(
                "namespace must match" in error
                for error in validate_documents(documents)
            )
        )

    def test_rejects_in_namespace_stateful_and_data_plane_resources(self) -> None:
        resources = (
            {
                "apiVersion": "apps/v1",
                "kind": "StatefulSet",
                "metadata": {"name": "cache"},
                "spec": {},
            },
            {
                "apiVersion": "v1",
                "kind": "PersistentVolumeClaim",
                "metadata": {"name": "uploads"},
                "spec": {},
            },
            {
                "apiVersion": "v1",
                "kind": "Service",
                "metadata": {"name": "database"},
                "spec": {"selector": {"app.kubernetes.io/component": "postgres"}},
            },
            {
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "metadata": {"name": "object-store"},
                "spec": {
                    "template": {
                        "spec": {
                            "containers": [
                                {"name": "server", "image": "quay.io/minio/minio:latest"}
                            ]
                        }
                    }
                },
            },
        )

        for resource in resources:
            with self.subTest(kind=resource["kind"]):
                errors = validate_documents(valid_documents() + [resource])
                self.assertTrue(
                    any(
                        "must not contain StatefulSets or PersistentVolumeClaims"
                        in error
                        or "must not deploy in-namespace PostgreSQL or MinIO"
                        in error
                        for error in errors
                    )
                )

    def test_rejects_under_replicated_or_unmatched_capacity_controls(self) -> None:
        mutations = (
            (
                lambda documents: find_document(
                    documents, "Deployment", "k-comms-edge"
                )["spec"].update({"replicas": 2}),
                "Deployment k-comms-edge: replicas must be at least 3",
            ),
            (
                lambda documents: documents.remove(
                    find_document(
                        documents, "HorizontalPodAutoscaler", "k-comms-worker"
                    )
                ),
                "missing HorizontalPodAutoscaler k-comms-worker",
            ),
            (
                lambda documents: find_document(
                    documents, "HorizontalPodAutoscaler", "k-comms-edge"
                )["spec"]["scaleTargetRef"].update({"name": "other"}),
                "scaleTargetRef must match Deployment k-comms-edge",
            ),
            (
                lambda documents: find_document(
                    documents, "PodDisruptionBudget", "k-comms-worker"
                )["spec"]["selector"]["matchLabels"].update(
                    {"app.kubernetes.io/component": "edge"}
                ),
                "selector must exactly match Deployment k-comms-worker",
            ),
        )

        for mutate, expected in mutations:
            with self.subTest(expected=expected):
                documents = valid_documents()
                mutate(documents)
                self.assertTrue(
                    any(expected in error for error in validate_documents(documents))
                )

    def test_rejects_invalid_database_tls_identity_or_ca_mounts(self) -> None:
        mutations = (
            (
                lambda documents: documents[0]["data"].update(
                    {"DATABASE_SSL_SERVER_NAME": "postgres.example.invalid"}
                ),
                "DATABASE_SSL_SERVER_NAME must be a non-placeholder DNS hostname",
            ),
            (
                lambda documents: documents[0]["data"].update(
                    {"DATABASE_SSL_CA_FILE": "database-ca/ca.crt"}
                ),
                "DATABASE_SSL_CA_FILE must be a normalized absolute path",
            ),
            (
                lambda documents: find_document(
                    documents, "Deployment", "k-comms-worker"
                )["spec"]["template"]["spec"]["containers"][0][
                    "volumeMounts"
                ][0].update({"readOnly": False}),
                "must mount k-comms-database-ca ca.crt read-only",
            ),
            (
                lambda documents: find_document(
                    documents, "ConfigMap", "k-comms-database-ca"
                )["data"].pop("ca.crt"),
                "ConfigMap k-comms-database-ca must contain ca.crt",
            ),
        )

        for mutate, expected in mutations:
            with self.subTest(expected=expected):
                documents = valid_documents()
                mutate(documents)
                self.assertTrue(
                    any(expected in error for error in validate_documents(documents))
                )

    def test_rejects_inexact_managed_database_egress(self) -> None:
        mutations = (
            (
                lambda policy: policy["spec"].update({"podSelector": {}}),
                "podSelector must exactly match k-comms application pods",
            ),
            (
                lambda policy: policy["spec"].update(
                    {"policyTypes": ["Ingress", "Egress"]}
                ),
                "policyTypes must contain only Egress",
            ),
            (
                lambda policy: policy["spec"]["egress"][0].update(
                    {"ports": [{"protocol": "UDP", "port": 5432}]}
                ),
                "every egress rule must expose only TCP port 5432",
            ),
            (
                lambda policy: policy["spec"]["egress"][0].update(
                    {"ports": [{"protocol": "TCP", "port": 5432, "endPort": 5433}]}
                ),
                "every egress rule must expose only TCP port 5432",
            ),
            (
                lambda policy: policy["spec"]["egress"][0].update(
                    {"to": [{"namespaceSelector": {}}]}
                ),
                "every database destination must be an explicit valid ipBlock",
            ),
            (
                lambda policy: policy["spec"]["egress"][0].update(
                    {
                        "to": [
                            {
                                "ipBlock": {
                                    "cidr": "10.42.0.0/24",
                                    "except": ["10.42.0.1/32"],
                                }
                            }
                        ]
                    }
                ),
                "every database destination must be an explicit valid ipBlock",
            ),
            (
                lambda policy: policy["spec"]["egress"][0].update(
                    {"to": [{"ipBlock": {"cidr": "10.42.0.1/24"}}]}
                ),
                "every database destination must be an explicit valid ipBlock",
            ),
        )

        for mutate, expected in mutations:
            with self.subTest(expected=expected):
                documents = valid_documents()
                policy = find_document(
                    documents, "NetworkPolicy", "k-comms-managed-postgres-egress"
                )
                mutate(policy)
                self.assertTrue(
                    any(expected in error for error in validate_documents(documents))
                )

    def test_rejects_unsafe_or_globally_routable_database_ranges(self) -> None:
        unsafe_cidrs = (
            "0.0.0.0/0",
            "8.8.8.8/32",
            "127.0.0.1/32",
            "169.254.1.0/24",
            "224.0.0.0/4",
            "10.0.0.0/8",
            "10.0.0.0/9",
            "100.64.0.0/10",
            "::1/128",
            "fe80::/64",
            "ff00::/8",
            "2001:4860::/32",
        )

        for cidr in unsafe_cidrs:
            with self.subTest(cidr=cidr):
                documents = valid_documents()
                policy = find_document(
                    documents, "NetworkPolicy", "k-comms-managed-postgres-egress"
                )
                policy["spec"]["egress"][0]["to"] = [
                    {"ipBlock": {"cidr": cidr}}
                ]
                self.assertTrue(
                    any(
                        "database CIDR must be narrowed" in error
                        for error in validate_documents(documents)
                    )
                )

    def test_rejects_database_ranges_that_collectively_cover_ipv4(self) -> None:
        documents = valid_documents()
        policy = find_document(
            documents, "NetworkPolicy", "k-comms-managed-postgres-egress"
        )
        policy["spec"]["egress"][0]["to"] = [
            {"ipBlock": {"cidr": "0.0.0.0/1"}},
            {"ipBlock": {"cidr": "128.0.0.0/1"}},
        ]

        errors = validate_documents(documents)

        self.assertTrue(
            any("must not collectively cover an address family" in error for error in errors)
        )

    def test_accepts_multiple_narrow_private_database_ranges(self) -> None:
        documents = valid_documents()
        policy = find_document(
            documents, "NetworkPolicy", "k-comms-managed-postgres-egress"
        )
        policy["spec"]["egress"][0]["to"] = [
            {"ipBlock": {"cidr": "10.42.0.0/24"}},
            {"ipBlock": {"cidr": "172.20.4.0/24"}},
            {"ipBlock": {"cidr": "fd12:3456:789a::/64"}},
        ]

        self.assertEqual(validate_documents(documents), [])

    def test_rejects_broad_or_mismatched_trusted_proxy_ingress(self) -> None:
        documents = valid_documents()
        documents[0]["data"]["TRUSTED_PROXY_CIDRS"] = "10.0.0.0/8"

        errors = validate_documents(documents)
        self.assertTrue(
            any("must not trust generic or unsafe ranges" in error for error in errors)
        )
        self.assertTrue(
            any("must exactly match TRUSTED_PROXY_CIDRS" in error for error in errors)
        )

        documents = valid_documents()
        edge_policy = next(
            document
            for document in documents
            if document.get("kind") == "NetworkPolicy"
            and document.get("metadata", {}).get("name") == "k-comms-edge-ingress"
        )
        edge_policy["spec"]["ingress"] = [{"ports": [{"port": 4000}]}]

        errors = validate_documents(documents)
        self.assertTrue(
            any(
                "every source must be an explicit valid ipBlock" in error
                for error in errors
            )
        )

    def test_rejects_split_ranges_that_collectively_cover_private_defaults(
        self,
    ) -> None:
        split_private_defaults = (
            ("10.0.0.0/9", "10.128.0.0/9"),
            ("172.16.0.0/13", "172.24.0.0/13"),
            ("192.168.0.0/17", "192.168.128.0/17"),
        )

        for cidrs in split_private_defaults:
            with self.subTest(cidrs=cidrs):
                documents = valid_documents()
                set_trusted_proxy_cidrs(documents, cidrs)

                errors = validate_documents(documents)

                self.assertTrue(
                    any(
                        "must not trust generic or unsafe ranges" in error
                        for error in errors
                    )
                )
                self.assertFalse(
                    any(
                        "must exactly match TRUSTED_PROXY_CIDRS" in error
                        for error in errors
                    )
                )

    def test_accepts_adjacent_narrow_provider_specific_proxy_ranges(self) -> None:
        documents = valid_documents()
        set_trusted_proxy_cidrs(documents, ("10.42.6.0/24", "10.42.7.0/24"))

        self.assertEqual(validate_documents(documents), [])

    def test_rejects_missing_or_inexact_edge_ingress_ports(self) -> None:
        invalid_ports = (
            None,
            ["TCP/4000"],
            [{"protocol": "UDP", "port": 4000}],
            [{"protocol": "TCP", "port": 9090}],
            [{"protocol": "TCP", "port": 4000, "endPort": 4001}],
        )

        for ports in invalid_ports:
            with self.subTest(ports=ports):
                documents = valid_documents()
                edge_policy = next(
                    document
                    for document in documents
                    if document.get("kind") == "NetworkPolicy"
                    and document.get("metadata", {}).get("name")
                    == "k-comms-edge-ingress"
                )
                if ports is None:
                    edge_policy["spec"]["ingress"][0].pop("ports")
                else:
                    edge_policy["spec"]["ingress"][0]["ports"] = ports

                errors = validate_documents(documents)

                self.assertTrue(
                    any(
                        "every ingress rule must expose only TCP port 4000" in error
                        for error in errors
                    )
                )

    def test_reads_multi_document_yaml_without_exposing_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "production.yaml"
            documents = valid_documents()
            documents[0]["data"]["ATTACHMENT_SCANNER_ENDPOINT"] = "private-sentinel"
            path.write_text(
                "---\n".join(yaml.safe_dump(document) for document in documents),
                encoding="utf-8",
            )

            errors = validate(path)
            self.assertTrue(errors)
            self.assertNotIn("private-sentinel", "\n".join(errors))

    def test_validates_a_separately_rendered_operation_with_the_main_bundle(self) -> None:
        operation = workload("Job", "k-comms-platform-role")
        operation["spec"]["template"]["spec"]["containers"][0]["name"] = (
            "platform-role"
        )
        with tempfile.TemporaryDirectory() as directory:
            main_path = Path(directory) / "production.yaml"
            operation_path = Path(directory) / "platform-role.yaml"
            main_path.write_text(
                yaml.safe_dump_all(valid_documents()), encoding="utf-8"
            )
            operation_path.write_text(yaml.safe_dump(operation), encoding="utf-8")

            self.assertEqual(validate_paths([main_path, operation_path]), [])


def valid_documents() -> list[dict]:
    config = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": "k-comms-config", "namespace": PRODUCTION_NAMESPACE},
        "data": {
            "ALLOW_BOOTSTRAP": "false",
            "ALLOW_DEVELOPMENT_ADAPTERS": "false",
            "DATABASE_SSL": "true",
            "DATABASE_SSL_CA_FILE": "/etc/k-comms/database-ca/ca.crt",
            "DATABASE_SSL_SERVER_NAME": "postgres.internal.example.com",
            "HSTS_ENABLED": "true",
            "PHX_HOST": "comms.example.com",
            "PUBLIC_APP_URL": "https://comms.example.com",
            "CORS_ORIGINS": "https://comms.example.com",
            "S3_PUBLIC_ENDPOINT": "https://objects.example.com",
            "S3_INTERNAL_ENDPOINT": "https://objects.example.com",
            "S3_BUCKET": "k-comms-production",
            "NOTIFICATION_PROVIDER_MODE": "http",
            "NOTIFICATION_PROVIDER_ENDPOINT": "https://notifications.example.com/v1/deliver",
            "NOTIFICATION_PROVIDER_NAME": "approved-notifications",
            "NOTIFICATION_PROVIDER_ALLOWED_HOSTS": "notifications.example.com",
            "ATTACHMENT_SCANNER_MODE": "http",
            "ATTACHMENT_SCANNER_ENDPOINT": "https://scanner.example.com/v1/scan",
            "ATTACHMENT_SCANNER_PROVIDER_NAME": "approved-scanner",
            "ATTACHMENT_SCANNER_ALLOWED_HOSTS": "scanner.example.com",
            "WEBHOOK_PROVIDER_MODE": "http",
            "WEBHOOK_ALLOWED_HOSTS": "hooks.customer.example.com",
            "WEB_PUSH_VAPID_PUBLIC_KEY": VAPID_PUBLIC_KEY,
            "TRUSTED_PROXY_CIDRS": "10.42.7.0/24",
        },
    }
    return [
        config,
        workload("Deployment", "k-comms-edge"),
        workload("Deployment", "k-comms-worker"),
        workload("Job", "k-comms-migrate"),
        {
            "apiVersion": "networking.k8s.io/v1",
            "kind": "NetworkPolicy",
            "metadata": {
                "name": "k-comms-managed-postgres-egress",
                "namespace": PRODUCTION_NAMESPACE,
            },
            "spec": {
                "podSelector": {
                    "matchLabels": {"app.kubernetes.io/name": "k-comms"}
                },
                "policyTypes": ["Egress"],
                "egress": [
                    {
                        "to": [{"ipBlock": {"cidr": "10.42.0.0/24"}}],
                        "ports": [{"protocol": "TCP", "port": 5432}],
                    }
                ]
            },
        },
        {
            "apiVersion": "networking.k8s.io/v1",
            "kind": "NetworkPolicy",
            "metadata": {
                "name": "k-comms-edge-ingress",
                "namespace": PRODUCTION_NAMESPACE,
            },
            "spec": {
                "ingress": [
                    {
                        "from": [{"ipBlock": {"cidr": "10.42.7.0/24"}}],
                        "ports": [{"protocol": "TCP", "port": 4000}],
                    }
                ]
            },
        },
        autoscaler("k-comms-edge", 3),
        autoscaler("k-comms-worker", 2),
        disruption_budget("k-comms-edge", "edge"),
        disruption_budget("k-comms-worker", "worker"),
        {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": "k-comms-database-ca",
                "namespace": PRODUCTION_NAMESPACE,
            },
            "data": {"ca.crt": CA_PEM},
        },
    ]


def workload(kind: str, name: str) -> dict:
    environment = []
    container_name = name.removeprefix("k-comms-")
    if kind == "Job":
        environment.append({"name": "K_COMMS_RUNTIME_PURPOSE", "value": "one_shot"})

    document = {
        "apiVersion": "apps/v1" if kind == "Deployment" else "batch/v1",
        "kind": kind,
        "metadata": {
            "name": name,
            "namespace": PRODUCTION_NAMESPACE,
            "labels": {"app.kubernetes.io/name": "k-comms"},
        },
        "spec": {
            "template": {
                "metadata": {
                    "labels": {"app.kubernetes.io/name": "k-comms"}
                },
                "spec": {
                    "serviceAccountName": "k-comms",
                    "automountServiceAccountToken": False,
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": 10001,
                        "runAsGroup": 10001,
                        "fsGroup": 10001,
                        "seccompProfile": {"type": "RuntimeDefault"},
                    },
                    "containers": [
                        {
                            "name": container_name,
                            "image": DIGEST_IMAGE,
                            "env": environment,
                            "securityContext": {
                                "allowPrivilegeEscalation": False,
                                "readOnlyRootFilesystem": True,
                                "capabilities": {"drop": ["ALL"]},
                            },
                            "volumeMounts": [
                                {
                                    "name": "database-ca",
                                    "mountPath": "/etc/k-comms/database-ca",
                                    "readOnly": True,
                                }
                            ],
                        }
                    ],
                    "volumes": [
                        {
                            "name": "database-ca",
                            "configMap": {
                                "name": "k-comms-database-ca",
                                "items": [{"key": "ca.crt", "path": "ca.crt"}],
                            },
                        }
                    ],
                }
            }
        },
    }
    if kind == "Deployment":
        component = name.removeprefix("k-comms-")
        selector = {"app.kubernetes.io/component": component}
        document["spec"]["replicas"] = 3 if component == "edge" else 2
        document["spec"]["selector"] = {"matchLabels": selector}
        document["spec"]["template"]["metadata"]["labels"].update(selector)
        container = document["spec"]["template"]["spec"]["containers"][0]
        if component == "edge":
            container.update(
                {
                    "startupProbe": {
                        "httpGet": {"path": "/health/live", "port": "http"}
                    },
                    "readinessProbe": {
                        "httpGet": {"path": "/health/ready", "port": "http"}
                    },
                    "livenessProbe": {
                        "httpGet": {"path": "/health/live", "port": "http"}
                    },
                }
            )
        else:
            for probe in ("startupProbe", "readinessProbe", "livenessProbe"):
                container[probe] = {"exec": {"command": ["/app/bin/k_comms", "rpc"]}}
    else:
        document["spec"]["template"]["spec"]["restartPolicy"] = "Never"
    return document


def autoscaler(name: str, minimum: int) -> dict:
    return {
        "apiVersion": "autoscaling/v2",
        "kind": "HorizontalPodAutoscaler",
        "metadata": {"name": name, "namespace": PRODUCTION_NAMESPACE},
        "spec": {
            "scaleTargetRef": {
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "name": name,
            },
            "minReplicas": minimum,
            "maxReplicas": minimum * 2,
            "metrics": [
                {
                    "type": "Resource",
                    "resource": {
                        "name": "cpu",
                        "target": {"type": "Utilization", "averageUtilization": 65},
                    },
                }
            ],
        },
    }


def disruption_budget(name: str, component: str) -> dict:
    return {
        "apiVersion": "policy/v1",
        "kind": "PodDisruptionBudget",
        "metadata": {"name": name, "namespace": PRODUCTION_NAMESPACE},
        "spec": {
            "minAvailable": 2 if component == "edge" else 1,
            "selector": {
                "matchLabels": {"app.kubernetes.io/component": component}
            },
        },
    }


def set_trusted_proxy_cidrs(documents: list[dict], cidrs: tuple[str, ...]) -> None:
    documents[0]["data"]["TRUSTED_PROXY_CIDRS"] = ",".join(cidrs)
    edge_policy = next(
        document
        for document in documents
        if document.get("kind") == "NetworkPolicy"
        and document.get("metadata", {}).get("name") == "k-comms-edge-ingress"
    )
    edge_policy["spec"]["ingress"] = [
        {
            "from": [{"ipBlock": {"cidr": cidr}} for cidr in cidrs],
            "ports": [{"protocol": "TCP", "port": 4000}],
        }
    ]


def find_document(documents: list[dict], kind: str, name: str) -> dict:
    return next(
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    )


if __name__ == "__main__":
    unittest.main()
