#!/usr/bin/env python3
"""Read-only checkout/runtime identity check. Never reads environment secrets."""

import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path


def run(args, cwd=None):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError(f"{args[0]} command failed (exit {result.returncode})")
    return result.stdout.strip()


def duplicate_candidates(paths):
    # Report suspected sync copies for review, never infer which file is correct.
    return sorted(path for path in paths if re.search(r"-(?:DESKTOP|LAPTOP)-[A-Z0-9]+(?:\.|$)", path, re.I))


def beam_versions(output):
    otp = re.search(r"Erlang/OTP (\d+)", output)
    elixir = re.search(r"Elixir ([\d.]+)", output)
    return {"otp": otp[1] if otp else None, "elixir": elixir[1] if elixir else None}


def expected_versions(root):
    versions = dict(line.split(maxsplit=1) for line in (root / ".tool-versions").read_text().splitlines() if line.strip())
    return {"otp": versions["erlang"].split(".")[0], "elixir": versions["elixir"].split("-")[0]}


def normalized_mount(path):
    value = str(path or "").replace("\\", "/").rstrip("/")
    value = re.sub(r"^/(?:mnt|run/desktop/mnt/host)/([a-zA-Z])/", r"\1:/", value)
    return value.casefold() if re.match(r"^[a-zA-Z]:/", value) else value


def inspect_workspace(path, base, container=None, engine="podman"):
    root = Path(run(["git", "rev-parse", "--show-toplevel"], path)).resolve()
    git = lambda *args: run(["git", *args], root)
    changed = sorted(set(git("diff", "--name-only").splitlines() + git("diff", "--cached", "--name-only").splitlines() + git("ls-files", "--others", "--exclude-standard").splitlines()))
    all_paths = git("ls-files", "--cached", "--others", "--exclude-standard").splitlines()
    duplicates = duplicate_candidates(all_paths)
    ahead, behind = map(int, git("rev-list", "--left-right", "--count", f"HEAD...{base}").split())
    expected = expected_versions(root)
    report = {
        "root": str(root), "branch": git("branch", "--show-current") or "DETACHED",
        "revision": git("rev-parse", "HEAD"), "base": base,
        "base_revision": git("rev-parse", base), "ahead": ahead, "behind": behind,
        "changed_paths": changed, "possible_duplicate_paths": duplicates,
        "expected_beam": expected, "runtime": None, "findings": [],
    }
    findings = report["findings"]
    if changed:
        findings.append("Preserve and reconcile local changes before updating this checkout.")
    if duplicates:
        findings.append("Review possible duplicate source files; their names do not establish their origin or authority.")
    if behind:
        findings.append(f"Checkout is {behind} commits behind the selected base; no fetch was performed.")
    command = [engine, "exec", container, "elixir", "--version"] if container else ["elixir", "--version"]
    if not shutil.which(command[0]):
        findings.append("Selected runtime executable is unavailable.")
    else:
        actual = beam_versions(run(command, root))
        report["runtime"] = {"kind": "container" if container else "host", "name": container, "beam": actual}
        if actual != expected:
            findings.append("Selected BEAM runtime differs from .tool-versions; use the pinned development container.")
        if container:
            mounts = json.loads(run([engine, "inspect", "--format", "{{json .Mounts}}", container]))
            workspace = next((mount.get("Source") for mount in mounts if mount.get("Destination") == "/workspace"), None)
            report["runtime"]["workspace_mount"] = workspace
            if normalized_mount(workspace) != normalized_mount(root):
                findings.append("Container workspace mount does not match this checkout; select the intended runtime.")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--container")
    parser.add_argument("--engine", default="podman")
    args = parser.parse_args()
    try:
        report = inspect_workspace(args.repo, args.base, args.container, args.engine)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"error": str(error)}, indent=2))
        return 2
    print(json.dumps(report, indent=2))
    return 1 if report["findings"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
