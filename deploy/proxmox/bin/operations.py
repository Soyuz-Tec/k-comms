#!/usr/bin/env python3
"""Non-secret operational receipts and optional host monitoring (ADR-0084)."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import uuid


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def epoch(value: str) -> float:
    stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if stamp.tzinfo is None:
        raise ValueError("timestamp must be timezone-aware")
    return stamp.timestamp()


def secure(path: Path, directory: bool = False, owner: int = 0) -> None:
    info = path.lstat()
    if (info.st_uid != owner or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600)
            or not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))):
        raise ValueError("operational file has unsafe ownership, type, or permissions")


def write_json(path: Path, value: dict) -> None:
    temporary = path.parent / (".pending-" + uuid.uuid4().hex)
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def read_json(path: Path, owner: int = 0) -> dict:
    secure(path, owner=owner)
    if path.stat().st_size > 64 * 1024:
        raise ValueError("operational receipt exceeds its size bound")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("operational receipt must be an object")
    return value


def record(args, now: str, finished_ns: int) -> dict:
    started_ns = args.started_ns
    if started_ns < 0 or finished_ns < started_ns:
        raise ValueError("invalid monotonic operation interval")
    epoch(args.started_at)
    durations = {}
    for item in args.duration:
        phase, raw = item.split("=", 1)
        if phase not in {"postgres", "minio", "configuration", "manifest", "retention",
                         "stop", "backup", "recovery", "finalization"}:
            raise ValueError("invalid operation phase")
        duration = int(raw)
        if duration < 0 or duration > finished_ns - started_ns:
            raise ValueError("invalid operation phase duration")
        durations[phase] = durations.get(phase, 0) + duration / 1_000_000_000
    if sum(durations.values()) > (finished_ns - started_ns) / 1_000_000_000:
        raise ValueError("operation phases exceed the measured interval")
    durations = {phase: round(duration, 6) for phase, duration in durations.items()}
    receipt = {
        "schema": "k-comms-operation-v1", "kind": args.kind, "status": args.status,
        "started_at": args.started_at, "finished_at": now,
        "duration_seconds": round((finished_ns - started_ns) / 1_000_000_000, 6),
        "phases_seconds": durations, "failed_phase": args.failed_phase,
        "backup_path": args.backup_path or None,
    }
    if args.kind == "maintenance":
        receipt["application_was_active"] = args.was_active
        receipt["application_stop_confirmed"] = args.writers_stopped
        receipt["health_restored"] = args.health_restored
        receipt["outage_interval_closed"] = not args.was_active or args.health_restored
        ended = args.outage_end_ns if args.health_restored else finished_ns
        if args.was_active and (ended is None or not started_ns <= ended <= finished_ns):
            raise ValueError("invalid application outage interval")
        receipt["outage_observed_seconds"] = round((ended - started_ns) / 1_000_000_000, 6) if args.was_active else 0
        if args.was_active and not args.writers_stopped:
            receipt["outage_observed_seconds"] = None
    return receipt


DEFAULT_CONFIG = {
    "backup_max_age_seconds": 28 * 60 * 60,
    "health_max_age_seconds": 180,
    "min_free_bytes": 5 * 1024**3,
    "min_free_inode_percent": 5,
    "alerts_enabled": False, "deadman_enabled": False, "hook_path": None,
}


def configuration(path: Path, owner: int = 0) -> dict:
    value = DEFAULT_CONFIG.copy()
    if path.exists() or path.is_symlink():
        supplied = read_json(path, owner)
        if set(supplied) - set(value):
            raise ValueError("unknown monitoring setting")
        value.update(supplied)
    for name, minimum, maximum in (("backup_max_age_seconds", 60, 7 * 86400),
                                   ("health_max_age_seconds", 60, 3600),
                                   ("min_free_bytes", 1024**2, 1024**5),
                                   ("min_free_inode_percent", 1, 99)):
        setting = value[name]
        if type(setting) is not int or not minimum <= setting <= maximum:
            raise ValueError("invalid monitoring threshold")
    if any(type(value[name]) is not bool for name in ("alerts_enabled", "deadman_enabled")):
        raise ValueError("invalid monitoring enable flag")
    hook = value["hook_path"]
    if hook is not None and (not isinstance(hook, str) or not Path(hook).is_absolute()):
        raise ValueError("monitoring hook must be an absolute executable path")
    if (value["alerts_enabled"] or value["deadman_enabled"]) and hook is None:
        raise ValueError("enabled monitoring delivery requires an explicit hook")
    return value


def backup_issues(receipt_path: Path, backup_root: Path, maximum: int, now: float, owner: int = 0) -> list[str]:
    try:
        receipt = read_json(receipt_path, owner)
        if receipt.get("schema") != "k-comms-operation-v1" or receipt.get("kind") != "backup":
            return ["backup_evidence_invalid"]
        if receipt.get("status") != "success":
            return ["backup_failed"]
        age = now - epoch(receipt["finished_at"])
        if age < -300:
            return ["backup_timestamp_invalid"]
        path = Path(receipt["backup_path"])
        if path.parent.resolve() != backup_root.resolve() or path.is_symlink():
            return ["backup_evidence_invalid"]
        secure(path, directory=True, owner=owner)
        secure(path / "COMPLETE", owner=owner)
        if (path / "COMPLETE").read_text().strip() != "k-comms-application-backup-v1":
            return ["backup_incomplete"]
        secure(path / "SHA256SUMS", owner=owner)
        if not (path / "SHA256SUMS").stat().st_size:
            return ["backup_incomplete"]
        return ["backup_stale"] if age > maximum else []
    except FileNotFoundError:
        return ["backup_missing"]
    except (OSError, ValueError, KeyError, TypeError):
        return ["backup_evidence_invalid"]


def storage_issues(paths: list[Path], config: dict, statvfs=None) -> list[str]:
    statvfs = statvfs or os.statvfs
    issues = []
    for index, path in enumerate(paths):
        try:
            stats = statvfs(path)
            if stats.f_bavail * stats.f_frsize < config["min_free_bytes"]:
                issues.append(f"storage_{index}_bytes_low")
            if stats.f_files and stats.f_favail * 100 / stats.f_files < config["min_free_inode_percent"]:
                issues.append(f"storage_{index}_inodes_low")
        except OSError:
            issues.append(f"storage_{index}_unavailable")
    return issues


def deliver(config: dict, event: dict, owner: int = 0, runner=subprocess.run) -> str:
    path = Path(config["hook_path"])
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != owner
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise ValueError("monitoring hook must be an owner-only executable")
    # Every parent is a directory trusted against substitution by other users.
    for parent in path.parents:
        metadata = parent.lstat()
        if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != owner
                or stat.S_IMODE(metadata.st_mode) & 0o022):
            raise ValueError("monitoring hook directory is not trusted")
    try:
        result = runner([str(path)], input=json.dumps(event), text=True, timeout=10,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"}, check=False)
        return "succeeded" if result.returncode == 0 else "failed"
    except subprocess.TimeoutExpired:
        return "timeout"


def monitor(args, now: float, owner: int = 0, statvfs=None, delivery=deliver) -> dict:
    config = configuration(args.config, owner)
    if not args.state_dir.exists() and not args.state_dir.is_symlink():
        args.state_dir.mkdir(mode=0o700)
    secure(args.state_dir, directory=True, owner=owner)
    state_path = args.state_dir / "monitor.json"
    previous = read_json(state_path, owner) if state_path.exists() else {}
    issues = [] if args.healthy else ["application_health_failed"]
    last_healthy = previous.get("last_healthy_at")
    if last_healthy is not None and now - epoch(last_healthy) > config["health_max_age_seconds"]:
        issues.append("health_evidence_stale")
    issues.extend(backup_issues(args.receipts / "backup-latest.json", args.backup_root,
                                config["backup_max_age_seconds"], now, owner))
    maintenance_path = args.receipts / "maintenance-latest.json"
    if maintenance_path.exists():
        maintenance = read_json(maintenance_path, owner)
        if maintenance.get("schema") != "k-comms-operation-v1" or maintenance.get("kind") != "maintenance":
            issues.append("maintenance_evidence_invalid")
        elif maintenance.get("status") != "success":
            issues.append("maintenance_failed")
    issues.extend(storage_issues(args.storage_path, config, statvfs))
    issues = sorted(issues)
    stamp = datetime.fromtimestamp(now, timezone.utc).isoformat()
    event = {"schema": "k-comms-monitor-event-v1", "observed_at": stamp, "issues": sorted(issues)}
    prior_issues = previous.get("issues", [])
    delivered_issues = previous.get("last_delivered_issues")
    retry_recovery = (previous.get("event") == "recovery"
                      and previous.get("delivery") in {"failed", "timeout"})
    if issues and (issues != prior_issues
                   or (config["alerts_enabled"] and issues != delivered_issues)):
        event["event"] = "alert"
    elif not issues and (prior_issues or retry_recovery
                        or (config["alerts_enabled"] and delivered_issues)):
        event["event"] = "recovery"
    else:
        event["event"] = "heartbeat" if not issues else "unchanged"
    enabled = ((event["event"] in {"alert", "recovery"} and config["alerts_enabled"])
               or (event["event"] == "heartbeat" and config["deadman_enabled"]))
    event["delivery"] = delivery(config, event, owner) if enabled else "disabled_or_not_needed"
    event["last_delivered_issues"] = (issues if event["delivery"] == "succeeded"
                                    and event["event"] in {"alert", "recovery"} else delivered_issues)
    event["last_healthy_at"] = stamp if args.healthy else last_healthy
    write_json(state_path, event)
    return event


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    recording = commands.add_parser("record")
    recording.add_argument("--kind", required=True, choices=("backup", "maintenance"))
    recording.add_argument("--status", required=True, choices=("success", "failed"))
    recording.add_argument("--started-at", required=True)
    recording.add_argument("--started-ns", type=int, required=True)
    recording.add_argument("--duration", action="append", default=[])
    recording.add_argument("--failed-phase", default=None)
    recording.add_argument("--backup-path", default="")
    recording.add_argument("--was-active", action="store_true")
    recording.add_argument("--writers-stopped", action="store_true")
    recording.add_argument("--health-restored", action="store_true")
    recording.add_argument("--outage-end-ns", type=int)
    recording.add_argument("--receipts", type=Path, required=True)
    monitoring = commands.add_parser("monitor")
    monitoring.add_argument("--config", type=Path, required=True)
    monitoring.add_argument("--state-dir", type=Path, required=True)
    monitoring.add_argument("--receipts", type=Path, required=True)
    monitoring.add_argument("--backup-root", type=Path, required=True)
    monitoring.add_argument("--storage-path", type=Path, action="append", required=True)
    monitoring.add_argument("--healthy", action="store_true")
    commands.add_parser("monotonic")
    args = parser.parse_args()
    try:
        if os.geteuid() != 0:
            raise ValueError("operational recording requires root")
        if args.command == "monotonic":
            print(time.monotonic_ns())
        elif args.command == "record":
            info = args.receipts.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o022:
                raise ValueError("receipt directory is not trusted")
            receipt = record(args, utc_now(), time.monotonic_ns())
            identifier = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex
            write_json(args.receipts / f"{args.kind}-{identifier}.json", receipt)
            write_json(args.receipts / f"{args.kind}-latest.json", receipt)
        else:
            event = monitor(args, time.time())
            print(json.dumps({"issues": event["issues"], "delivery": event["delivery"]}))
            if event["issues"] or event["delivery"] in {"failed", "timeout"}:
                raise SystemExit(1)
    except (OSError, ValueError, KeyError, TypeError):
        raise SystemExit("Operational evidence or monitoring failed; inspect protected host configuration") from None


if __name__ == "__main__":
    main()
