import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from workspace_preflight import beam_versions, duplicate_candidates, inspect_workspace, normalized_mount


class WorkspacePreflightTest(unittest.TestCase):
    def test_windows_mount_equivalence_does_not_hide_a_different_checkout(self):
        self.assertEqual(normalized_mount("/mnt/c/dev/project"), normalized_mount("C:\\dev\\project"))
        self.assertNotEqual(normalized_mount("/mnt/c/dev/project"), normalized_mount("C:\\dev\\other"))

    def test_versions_are_extracted_without_exposing_command_output(self):
        self.assertEqual(beam_versions("Erlang/OTP 29 [erts-17]\nElixir 1.20.1 (compiled with Erlang/OTP 29)"), {"otp": "29", "elixir": "1.20.1"})

    def test_sync_copy_candidates_do_not_match_ordinary_source_names(self):
        self.assertEqual(duplicate_candidates(["src/Desktop.tsx", "mix-DESKTOP-ABC123.lock", "src/Page-LAPTOP-123.tsx"]), ["mix-DESKTOP-ABC123.lock", "src/Page-LAPTOP-123.tsx"])

    def test_reports_untracked_and_modified_work_without_changing_index(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root).decode().strip()
            git("init", "-q")
            git("config", "user.email", "synthetic@example.test")
            git("config", "user.name", "Synthetic fixture")
            (root / ".tool-versions").write_text("erlang 29.0\nelixir 1.20.1-otp-29\n")
            git("add", ".tool-versions")
            git("commit", "-qm", "fixture")
            git("branch", "baseline")
            (root / "mix-DESKTOP-ABC.lock").write_text("synthetic")
            (root / ".tool-versions").write_text("erlang 29.0\nelixir 1.20.1-otp-29\n\n")
            git("add", ".tool-versions")
            # The working copy now equals HEAD, but the index has unique work.
            (root / ".tool-versions").write_text("erlang 29.0\nelixir 1.20.1-otp-29\n")
            before = git("status", "--porcelain")
            with patch("workspace_preflight.shutil.which", return_value=None):
                report = inspect_workspace(root, "baseline")
            self.assertEqual(report["changed_paths"], [".tool-versions", "mix-DESKTOP-ABC.lock"])
            self.assertEqual(report["possible_duplicate_paths"], ["mix-DESKTOP-ABC.lock"])
            self.assertEqual(git("status", "--porcelain"), before)


if __name__ == "__main__":
    unittest.main()
