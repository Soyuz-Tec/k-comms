#!/usr/bin/env python3
"""Exercise production Config.Reader against actual private secret-file fixtures."""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", choices=["podman", "docker"])
    args = parser.parse_args()
    runtime = args.runtime or next((name for name in ("podman", "docker") if shutil.which(name)), None)
    if not runtime:
        parser.error("Podman or Docker is required for this isolated configuration qualification")
    repo = Path(__file__).resolve().parent.parent
    match = re.search(r"^ARG ELIXIR_IMAGE=(\S+@sha256:[0-9a-f]{64})$", (repo / "Dockerfile").read_text(), re.M)
    if not match:
        raise RuntimeError("Dockerfile must declare its immutable Elixir image")
    if not (repo / "_build/test/lib/comms_integrations/ebin").is_dir():
        raise RuntimeError("Compile the test application before file-backed runtime qualification")
    image = match.group(1)
    reused = "h" * 32
    independent = "p" * 32
    encode = lambda value: base64.b64encode(value.encode()).decode()
    formats = [lambda value: value, lambda value: value, encode,
               lambda value: "primary:" + encode(value),
               lambda value: json.dumps({"primary": encode(value)}, separators=(",", ":")),
               lambda value: value, lambda value: value, encode]
    with tempfile.TemporaryDirectory(prefix="k-comms-history-private-files-") as directory:
        root = Path(directory)
        root.chmod(0o700)
        for index, formatter in enumerate(formats, 1):
            for prefix, value in (("reused", reused), ("independent", independent)):
                path = root / f"{prefix}-{index}"
                descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, "w") as handle:
                    handle.write(formatter(value))
        command = [runtime, "run", "--rm", "--network", "none", "--read-only",
                   "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                   "--user", f"{os.getuid()}:{os.getgid()}", "--env", "ERL_FLAGS=+S 1:1",
                   "--mount", f"type=bind,src={repo},dst=/source,readonly",
                   "--mount", f"type=bind,src={root},dst=/run/secrets,readonly",
                   image, "elixir", "/source/scripts/qualify_history_secret_files.exs"]
        subprocess.run(command, check=True, timeout=180)


if __name__ == "__main__":
    main()
