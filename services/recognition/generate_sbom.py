"""Generate deterministic CycloneDX package provenance from the exact hashed lock.

Use qualified CPython 3.12/Linux x86_64 and --require-hashes downloaded wheels.
Wheel-bundled native libraries are not separately inventoried or audited here.
"""
import argparse
from email.parser import BytesParser
import hashlib
import json
from pathlib import Path
import platform
import re
import sys
import urllib.request
import uuid
import zipfile

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name
from packaging.version import Version


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1_048_576), b""):
            value.update(block)
    return value.hexdigest()


def locked_packages(path):
    packages, current = {}, None
    for line in path.read_text().splitlines():
        text = line.strip().removesuffix("\\").strip()
        if not text or text.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([^\s]+)", text)
        if match:
            current = canonicalize_name(match[1])
            if current in packages:
                raise ValueError("duplicate locked package")
            packages[current] = {"version": match[2], "hashes": set()}
        elif current and re.fullmatch(r"--hash=sha256:[a-f0-9]{64}", text):
            packages[current]["hashes"].add(text.removeprefix("--hash=sha256:"))
        else:
            raise ValueError("unsupported lock declaration")
    if not packages or any(not row["hashes"] for row in packages.values()):
        raise ValueError("all locked packages require hashes")
    return packages


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wheel-dir", type=Path, required=True)
    parser.add_argument("--metadata-dir", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if sys.version_info[:2] != (3, 12) or sys.platform != "linux" or platform.machine() != "x86_64":
        raise ValueError("SBOM target is qualified CPython3.12/Linux x86_64")
    root = Path(__file__).resolve().parent
    lock = root / "requirements.lock"
    packages = locked_packages(lock)
    components, requirements = [], {}
    seen = set()
    for wheel in sorted(args.wheel_dir.glob("*.whl")):
        with zipfile.ZipFile(wheel) as archive:
            entries = [name for name in archive.namelist() if name.endswith(".dist-info/METADATA")]
            if len(entries) != 1:
                raise ValueError("wheel metadata is ambiguous")
            info = BytesParser().parsebytes(archive.read(entries[0]))
        name, version = canonicalize_name(info["Name"]), info["Version"]
        if name in seen or name not in packages or packages[name]["version"] != version:
            raise ValueError("wheel set differs from lock")
        seen.add(name)
        checksum = digest(wheel)
        if checksum not in packages[name]["hashes"]:
            raise ValueError("wheel does not match locked hash")
        cached = args.metadata_dir / f"{name}-{version}.json" if args.metadata_dir else None
        if cached and cached.is_file():
            official = json.loads(cached.read_text())
        else:
            with urllib.request.urlopen(f"https://pypi.org/pypi/{name}/{version}/json", timeout=25) as response:
                payload = response.read(2_000_001)
            if len(payload) > 2_000_000:
                raise ValueError("release metadata exceeds bound")
            official = json.loads(payload)
        if official["info"]["version"] != version:
            raise ValueError("release metadata version mismatch")
        releases = [entry for entry in official["urls"] if entry["filename"] == wheel.name]
        if len(releases) != 1:
            raise ValueError("wheel missing from official release")
        release = releases[0]
        if release["yanked"] or release["size"] != wheel.stat().st_size or release["digests"]["sha256"] != checksum:
            raise ValueError("wheel official provenance mismatch")
        reference = f"pkg:pypi/{name}@{version}"
        component = {"type": "library", "bom-ref": reference, "name": name, "version": version,
                     "purl": reference, "hashes": [{"alg": "SHA-256", "content": checksum}],
                     "externalReferences": [{"type": "distribution", "url": release["url"]}],
                     "properties": [{"name": "kcomms:wheel", "value": wheel.name},
                                    {"name": "kcomms:artifact-bytes", "value": str(wheel.stat().st_size)}]}
        expression = info["License-Expression"] or official["info"].get("license_expression")
        license_name = info["License"] or official["info"].get("license") or "; ".join(
            item.rsplit(" :: ", 1)[-1] for item in official["info"].get("classifiers", [])
            if item.startswith("License :: ") and item != "License :: OSI Approved")
        if expression:
            component["licenses"] = [{"expression": expression}]
        elif license_name:
            component["licenses"] = [{"license": {"name": license_name.splitlines()[0][:200]}}]
        components.append(component)
        requirements[name] = info.get_all("Requires-Dist", [])
    if seen != set(packages):
        raise ValueError("wheel set is incomplete")
    refs = {name: f'pkg:pypi/{name}@{row["version"]}' for name, row in packages.items()}
    dependencies = []
    for name, entries in sorted(requirements.items()):
        depends = set()
        for entry in entries:
            requirement = Requirement(entry)
            if requirement.marker is None or requirement.marker.evaluate({"extra": ""}):
                dependency = canonicalize_name(requirement.name)
                if dependency not in refs:
                    raise ValueError("locked dependency is missing")
                if Version(packages[dependency]["version"]) not in requirement.specifier:
                    raise ValueError("locked dependency violates its declared version")
                depends.add(refs[dependency])
        dependencies.append({"ref": refs[name], "dependsOn": sorted(depends)})
    direct = []
    for line in (root / "requirements.txt").read_text().splitlines():
        if not line.strip():
            continue
        name, version = line.strip().split("==")
        name = canonicalize_name(name)
        if name in direct or name not in packages or packages[name]["version"] != version:
            raise ValueError("direct requirements differ from the lock")
        direct.append(name)
    engine_hash = digest(root / "engine.py")
    application = f"kcomms:recognition-engine:sha256:{engine_hash}"
    dependencies.append({"ref": application, "dependsOn": sorted(refs[name] for name in direct)})
    lock_hash = digest(lock)
    result = {"bomFormat": "CycloneDX", "specVersion": "1.6", "version": 1,
              "serialNumber": "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_URL, lock_hash)),
              "metadata": {"component": {"type": "application", "bom-ref": application,
                            "name": "k-comms-recognition-runtime", "version": "sha256:" + engine_hash,
                            "properties": [{"name": "kcomms:requirements-lock-sha256", "value": lock_hash},
                                           {"name": "kcomms:target", "value": "CPython3.12/Linux x86_64"},
                                           {"name": "kcomms:scope", "value": "Python wheel packages; bundled native libraries require separate inventory and audit"}]}},
              "components": sorted(components, key=lambda row: row["name"]), "dependencies": dependencies}
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"packages": len(components), "engine_sha256": engine_hash, "lock_sha256": lock_hash}))


if __name__ == "__main__":
    main()
