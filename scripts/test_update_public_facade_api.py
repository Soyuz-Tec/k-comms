from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import yaml

from update_public_facade_api import build_snapshot


class UpdatePublicFacadeApiTest(unittest.TestCase):
    def test_configured_collaboration_classifies_only_real_provider_operations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            sources = {
                "apps/comms_core/lib/comms_core/provider.ex": """
                defmodule CommsCore.Provider do
                  def revoke(id), do: {:ok, id}
                  def status(id), do: {:ok, id}
                  def helper(id), do: id
                end
                """,
                "apps/comms_core/lib/comms_core/consumer.ex": """
                defmodule CommsCore.Consumer do
                  def revoke(id), do: CommsCore.Consumer.Port.revoke(id)
                end
                """,
                "apps/comms_core/lib/comms_core/release.ex": """
                defmodule CommsCore.Release do
                  def migrate(), do: :ok
                end
                """,
                "apps/comms_web/lib/comms_web/provider_controller.ex": """
                defmodule CommsWeb.ProviderController do
                  def show(id), do: CommsCore.Provider.status(id)
                end
                """,
            }
            for relative_path, source in sources.items():
                path = root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source, encoding="utf-8")

            manifest = {
                "contexts": {
                    "consumer": {
                        "public_facades": ["CommsCore.Consumer"],
                        "internal_namespaces": ["CommsCore.Consumer"],
                    },
                    "provider": {
                        "public_facades": ["CommsCore.Provider"],
                        "internal_namespaces": ["CommsCore.Provider"],
                    },
                    "platform_runtime": {
                        "public_facades": ["CommsCore.Release"],
                        "owned_modules": ["CommsCore.Release"],
                    },
                },
                "runtime_collaborations": [
                    {
                        "implementation": "CommsCore.Provider",
                        "operations": [
                            {"name": "revoke", "arity": 1},
                            {"name": "status", "arity": 1},
                            {"name": "missing", "arity": 1},
                            {"name": "revoke", "arity": 2},
                        ],
                    },
                    {
                        "implementation": "CommsCore.NotPublished",
                        "operations": [{"name": "missing", "arity": 1}],
                    },
                ],
            }
            manifest_path = root / "docs/02-architecture/context-boundaries.yaml"
            manifest_path.parent.mkdir(parents=True, exist_ok=True)
            manifest_path.write_text(yaml.safe_dump(manifest), encoding="utf-8")

            facade = build_snapshot(root)["contexts"]["provider"]["CommsCore.Provider"]
            self.assertEqual(facade["public_operations"], ["status/1"])
            self.assertEqual(facade["collaboration_operations"], ["revoke/1"])
            self.assertEqual(facade["owner_internal_operations"], ["helper/1"])


if __name__ == "__main__":
    unittest.main()
