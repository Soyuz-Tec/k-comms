"""Explicit, opt-in immutable model/fixture fetch; never called by production HTTP."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request


def fetch(url, destination, expected):
    digest, count = hashlib.sha256(), 0
    temporary = destination.with_suffix(destination.suffix + ".partial")
    try:
        with urllib.request.urlopen(url, timeout=60) as source, temporary.open("wb") as output:
            while block := source.read(1_048_576):
                count += len(block)
                if count > expected["bytes"]:
                    raise ValueError("artifact exceeds pinned size")
                digest.update(block)
                output.write(block)
        if count != expected["bytes"] or digest.hexdigest() != expected["sha256"]:
            raise ValueError("artifact does not match immutable manifest")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--fixture", type=Path)
    args = parser.parse_args()
    args.model_dir.mkdir(parents=True, exist_ok=True)
    root = Path(__file__).parent
    model = json.loads((root / "model-manifest.json").read_text())
    for filename, proof in model["files"].items():
        url = f'https://huggingface.co/{model["repository"]}/resolve/{model["revision"]}/{filename}'
        fetch(url, args.model_dir / filename, proof)
    if args.fixture:
        fixture = json.loads((root / "speech-fixture.json").read_text())
        fetch(fixture["url"], args.fixture, fixture)
