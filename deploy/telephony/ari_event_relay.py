#!/usr/bin/env python3
"""Authenticated ARI WSS consent-notice event relay with a durable bounded spool.

Only PlaybackFinished for K-Comms voicemail notices is forwarded. The application
reconciles recording completion separately through the exact ARI stored recording.
No SIP caller input becomes an authenticated application identity.
"""
from __future__ import annotations

import base64
import hashlib
import fcntl
import hmac
import http.client
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import struct
import time
from urllib.parse import urlencode, urlsplit

MAX_BODY = 262_144
MAX_SPOOL = 1_000


def configured_url(value: str, path: str | None = None) -> tuple[str, str]:
    url = urlsplit(value)
    if (url.scheme != "https" or not url.hostname or url.port not in (None, 443)
            or url.username or url.password or url.query or url.fragment
            or (path is None and url.path not in ("", "/"))
            or (path is not None and url.path != path)):
        raise ValueError("invalid relay HTTPS configuration")
    try:
        ipaddress.ip_address(url.hostname)
    except ValueError:
        return url.hostname, url.path or "/"
    raise ValueError("a validated DNS hostname is required")


def secret(name: str, minimum: int) -> str:
    filename = os.environ.get(name + "_FILE")
    value = Path(filename).read_text().strip() if filename else os.environ.get(name, "")
    if len(value) < minimum or "\r" in value or "\n" in value:
        raise ValueError("required relay secret unavailable")
    return value


def pinned_tls(host: str, timeout: int = 20) -> ssl.SSLSocket:
    """Validate resolution, connect to that exact public address, then verify TLS."""
    addresses = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
    if not addresses or len(addresses) > 32:
        raise OSError("relay DNS resolution unavailable")
    if any(not ipaddress.ip_address(item[4][0]).is_global for item in addresses):
        raise OSError("relay origin resolved to an excluded address")
    last_error = None
    for family, socktype, proto, _, address in addresses:
        raw = socket.socket(family, socktype, proto)
        raw.settimeout(timeout)
        try:
            raw.connect(address)
            return ssl.create_default_context().wrap_socket(raw, server_hostname=host)
        except (OSError, ssl.SSLError) as error:
            raw.close()
            last_error = error
    raise OSError("relay origin unavailable") from last_error


class PinnedHTTPS(http.client.HTTPSConnection):
    def connect(self):
        self.sock = pinned_tls(self.host, self.timeout)


def read_exact(stream, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        value = stream.recv(size - len(chunks))
        if not value:
            raise OSError("ARI event stream closed")
        chunks.extend(value)
    return bytes(chunks)


def client_frame(opcode: int, data: bytes) -> bytes:
    mask = secrets.token_bytes(4)
    length = len(data)
    prefix = bytes([0x80 | opcode])
    if length < 126:
        prefix += bytes([0x80 | length])
    elif length <= 65535:
        prefix += bytes([0x80 | 126]) + struct.pack("!H", length)
    else:
        prefix += bytes([0x80 | 127]) + struct.pack("!Q", length)
    return prefix + mask + bytes(value ^ mask[index % 4] for index, value in enumerate(data))


def receive_frame(stream) -> tuple[bool, int, bytes]:
    first, second = read_exact(stream, 2)
    if first & 0x70 or second & 0x80:
        raise OSError("unsupported ARI websocket frame")
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(stream, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(stream, 8))[0]
    opcode = first & 0x0F
    if length > MAX_BODY or (opcode >= 8 and (length > 125 or not first & 0x80)):
        raise OSError("ARI websocket frame exceeds bounds")
    return bool(first & 0x80), opcode, read_exact(stream, length)


def websocket(host: str, username: str, password: str, application: str):
    connection = pinned_tls(host)
    nonce = base64.b64encode(secrets.token_bytes(16)).decode()
    token = base64.b64encode((username + ":" + password).encode()).decode()
    path = "/ari/events?" + urlencode({"app": application, "subscribeAll": "false"})
    request = (f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
               f"Sec-WebSocket-Key: {nonce}\r\nAuthorization: Basic {token}\r\n\r\n")
    connection.sendall(request.encode("ascii"))
    response = bytearray()
    while not response.endswith(b"\r\n\r\n"):
        if len(response) >= 8192:
            connection.close()
            raise OSError("ARI websocket handshake exceeds bounds")
        response.extend(read_exact(connection, 1))
    lines = response.decode("ascii").split("\r\n")
    headers = {key.lower(): value.strip() for key, value in (line.split(":", 1) for line in lines[1:] if ":" in line)}
    expected = base64.b64encode(hashlib.sha1((nonce + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    if (not lines[0].startswith("HTTP/1.1 101 ") or headers.get("upgrade", "").lower() != "websocket"
            or "upgrade" not in headers.get("connection", "").lower()
            or not hmac.compare_digest(headers.get("sec-websocket-accept", ""), expected)):
        connection.close()
        raise OSError("ARI websocket handshake rejected")
    return connection


def notice_event(raw: bytes) -> bytes | None:
    if len(raw) > MAX_BODY:
        raise ValueError("event exceeds bound")
    value = json.loads(raw)
    if not isinstance(value, dict) or value.get("type") != "PlaybackFinished":
        return None
    playback = value.get("playback")
    if not isinstance(playback, dict) or playback.get("state") != "done":
        return None
    identifier = playback.get("id", "")
    compact = identifier.removeprefix("kc_notice_") if isinstance(identifier, str) else ""
    if not isinstance(identifier, str) or not identifier.startswith("kc_notice_") or len(compact) != 32 or any(c not in "0123456789abcdef" for c in compact):
        return None
    target = playback.get("target_uri", "")
    media = playback.get("media_uri", "")
    if not isinstance(target, str) or not target.startswith("channel:") or len(target) > 208:
        return None
    if not isinstance(media, str) or not media.startswith("sound:") or len(media) > 156:
        return None
    event = {"type": "PlaybackFinished", "event_id": hashlib.sha256(raw).hexdigest(),
             "playback": {key: playback[key] for key in ("id", "state", "target_uri", "media_uri")}}
    return json.dumps(event, separators=(",", ":"), sort_keys=True).encode()


def spool_event(directory: Path, event: bytes) -> Path:
    name = hashlib.sha256(event).hexdigest()
    path = directory / (name + ".json")
    if path.exists():
        return path
    if len(list(directory.glob("*.json"))) >= MAX_SPOOL:
        raise OSError("relay durable spool full")
    temporary = directory / (name + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(event)
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(path)
        dfd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        temporary.unlink(missing_ok=True)
    return path


def deliver(directory: Path, host: str, path: str, signing_secret: str):
    for filename in sorted(directory.glob("*.json"))[:MAX_SPOOL]:
        body = filename.read_bytes()
        if len(body) > MAX_BODY:
            raise OSError("relay spool record exceeds bound")
        timestamp = str(int(time.time()))
        signature = hmac.new(signing_secret.encode(), timestamp.encode() + b"." + body, hashlib.sha256).hexdigest()
        connection = PinnedHTTPS(host, timeout=10)
        try:
            connection.request("POST", path, body, {"authorization": "v1:" + timestamp + ":" + signature,
                                                   "content-type": "application/json"})
            response = connection.getresponse()
            response.read(MAX_BODY + 1)
            if response.status == 200:
                filename.unlink()
            elif response.status in (401, 403):
                raise OSError("relay webhook authentication rejected")
            else:
                return
        finally:
            connection.close()


def run():
    ari_host, _ = configured_url(os.environ["ARI_ORIGIN"])
    webhook_host, webhook_path = configured_url(os.environ["KCOMMS_WEBHOOK_URL"], "/api/v1/telephony/pbx/webhook")
    username = secret("ARI_USERNAME", 1)
    password = secret("ARI_PASSWORD", 24)
    signing_secret = secret("KCOMMS_PBX_WEBHOOK_SECRET", 32)
    application = os.environ.get("ARI_APPLICATION", "k-comms")
    if not application or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in application):
        raise ValueError("invalid ARI application")
    directory = Path(os.environ["ARI_RELAY_SPOOL"])
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if directory.is_symlink() or directory.stat().st_mode & 0o077:
        raise ValueError("relay spool must be a private directory")
    # One process owns recovery and delivery for a spool. A crashed pre-rename
    # temporary never blocks the provider's retried deterministic receipt.
    lock = os.open(directory / ".relay.lock", os.O_WRONLY | os.O_CREAT, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    for temporary in directory.glob("*.tmp"):
        temporary.unlink()
    delay = 1
    while True:
        connection = None
        try:
            deliver(directory, webhook_host, webhook_path, signing_secret)
            connection = websocket(ari_host, username, password, application)
            delay = 1
            fragments = bytearray()
            message_open = False
            while True:
                try:
                    complete, opcode, payload = receive_frame(connection)
                except socket.timeout:
                    deliver(directory, webhook_host, webhook_path, signing_secret)
                    # A timeout may occur mid-frame; reconnect rather than
                    # parsing a truncated frame as a new message.
                    raise OSError("ARI event stream idle")
                if opcode == 8:
                    raise OSError("ARI event stream closed")
                if opcode == 9:
                    connection.sendall(client_frame(10, payload))
                    continue
                if opcode == 10:
                    deliver(directory, webhook_host, webhook_path, signing_secret)
                    continue
                if opcode == 1:
                    if message_open:
                        raise OSError("ARI fragmented message overlap")
                    fragments = bytearray(payload)
                    message_open = not complete
                elif opcode == 0 and message_open:
                    fragments.extend(payload)
                    message_open = not complete
                else:
                    raise OSError("unsupported ARI event message")
                if len(fragments) > MAX_BODY:
                    raise OSError("ARI event exceeds bound")
                if complete:
                    event = notice_event(bytes(fragments))
                    fragments.clear()
                    if event:
                        spool_event(directory, event)
                        deliver(directory, webhook_host, webhook_path, signing_secret)
        except (OSError, ValueError, json.JSONDecodeError):
            # No URLs, provider frames or credential-bearing exceptions are logged.
            print("ARI relay unavailable; durable notices remain fail closed.", flush=True)
            time.sleep(delay)
            delay = min(delay * 2, 30)
        finally:
            if connection:
                connection.close()


if __name__ == "__main__":
    run()
