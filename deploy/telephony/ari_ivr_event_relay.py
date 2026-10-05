#!/usr/bin/env python3
"""Caller-only IVR event relay using the existing pinned ARI WSS transport.

The channelvars list in ari.conf must expose the exact KC bindings below. SIP
input supplies a menu choice; it never supplies application identity or consent.
The separately configured voicemail relay remains responsible for notice proof.
"""
from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import re
import secrets
MAX_BODY = 262_144
MAX_EVENT_AGE = 180
MAX_FRAGMENTS = 128
BINDINGS = (
    "KC_TENANT_ID", "KC_CALL_ID", "KC_LIVEKIT_ROOM", "KC_SIP_IDENTITY",
    "KC_ROLE", "KC_IVR_RUN_ID", "KC_IVR_STEP",
)
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
HANDLE = re.compile(r"^[A-Za-z0-9_.:-]{1,200}$")
PLAYBACK = re.compile(r"^kc_ivr_[0-9a-f]{32}_[1-3]$")
PROMPT = re.compile(r"^sound:[A-Za-z0-9_/-]{1,150}$")


def event_timestamp(value: str) -> datetime:
    if not isinstance(value, str) or len(value) > 40:
        raise ValueError("invalid ARI event timestamp")
    stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if stamp.tzinfo is None:
        raise ValueError("ARI timestamp must include an offset")
    return stamp.astimezone(timezone.utc)


def ivr_event(raw: bytes, now: datetime | None = None) -> bytes | None:
    if len(raw) > MAX_BODY:
        raise ValueError("event exceeds bound")
    value = json.loads(raw)
    if not isinstance(value, dict) or value.get("type") not in (
        "ChannelDtmfReceived", "PlaybackFinished"
    ):
        return None
    try:
        stamp = event_timestamp(value.get("timestamp"))
    except (ValueError, TypeError):
        return None
    now = now or datetime.now(timezone.utc)
    age = (now - stamp).total_seconds()
    if age < -5 or age > MAX_EVENT_AGE:
        return None
    event = {
        "type": value["type"], "timestamp": stamp.isoformat(),
        # The once-received random receipt persists unchanged across delivery
        # retries. No received digit or enumerable digit hash is an event ID.
        "event_id": secrets.token_hex(32),
    }
    if value["type"] == "ChannelDtmfReceived":
        channel = value.get("channel")
        variables = channel.get("channelvars") if isinstance(channel, dict) else None
        if not isinstance(variables, dict) or variables.get("KC_ROLE") != "external":
            return None
        if not isinstance(channel.get("id"), str) or not HANDLE.fullmatch(channel["id"]):
            return None
        if any(not isinstance(variables.get(name), str) for name in BINDINGS):
            return None
        if any(not UUID.fullmatch(variables[name]) for name in (
            "KC_TENANT_ID", "KC_CALL_ID", "KC_IVR_RUN_ID"
        )):
            return None
        if variables["KC_IVR_STEP"] not in ("1", "2", "3"):
            return None
        if any(not 1 <= len(variables[name]) <= 200 for name in (
            "KC_LIVEKIT_ROOM", "KC_SIP_IDENTITY"
        )):
            return None
        if value.get("digit") not in tuple("0123456789*#ABCD"):
            return None
        event["digit"] = value["digit"]
        event["channel"] = {
            "id": channel["id"],
            "channelvars": {name: variables[name] for name in BINDINGS},
        }
    else:
        playback = value.get("playback")
        if not isinstance(playback, dict) or playback.get("state") != "done":
            return None
        identifier = playback.get("id")
        target = playback.get("target_uri")
        media = playback.get("media_uri")
        if not isinstance(identifier, str) or not PLAYBACK.fullmatch(identifier):
            return None
        if (not isinstance(target, str) or not target.startswith("channel:")
                or not HANDLE.fullmatch(target.removeprefix("channel:"))):
            return None
        if not isinstance(media, str) or not PROMPT.fullmatch(media):
            return None
        event["playback"] = {
            name: playback[name] for name in ("id", "state", "target_uri", "media_uri")
        }
    return json.dumps(event, separators=(",", ":"), sort_keys=True).encode()


def expire_spool(directory: Path, now: datetime | None = None) -> int:
    now = now or datetime.now(timezone.utc)
    expired = 0
    for filename in directory.glob("*.json"):
        body = filename.read_bytes()
        if len(body) > MAX_BODY:
            raise OSError("relay spool record exceeds bound")
        value = json.loads(body)
        stamp = event_timestamp(value["timestamp"])
        if (now - stamp).total_seconds() > MAX_EVENT_AGE:
            filename.unlink()
            expired += 1
    return expired


if __name__ == "__main__":
    raise SystemExit("Use the combined ari_event_relay.py; a second ARI application stream is prohibited.")
