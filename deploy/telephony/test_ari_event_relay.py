import importlib.util
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("relay", Path(__file__).with_name("ari_event_relay.py"))
relay = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(relay)


class RelayTest(unittest.TestCase):
    def event(self):
        return {"type": "PlaybackFinished", "playback": {
            "id": "kc_notice_" + "a" * 32, "state": "done",
            "target_uri": "channel:trusted-external", "media_uri": "sound:custom/notice"},
            "caller": {"phone": "excluded-from-spool"}}

    def test_receipt_contains_only_notice_evidence_and_stable_event_id(self):
        raw = json.dumps(self.event()).encode()
        body = relay.notice_event(raw)
        self.assertEqual(body, relay.notice_event(raw))
        data = json.loads(body)
        self.assertEqual(set(data), {"type", "event_id", "playback"})
        self.assertNotIn(b"excluded-from-spool", body)

    def test_recording_finished_cannot_substitute_for_notice_completion(self):
        value = self.event()
        value["type"] = "RecordingFinished"
        self.assertIsNone(relay.notice_event(json.dumps(value).encode()))

    def test_wrong_prefix_pending_notice_and_oversize_are_rejected(self):
        value = self.event()
        value["playback"]["id"] = "another-notice"
        self.assertIsNone(relay.notice_event(json.dumps(value).encode()))
        value = self.event()
        value["playback"]["state"] = "playing"
        self.assertIsNone(relay.notice_event(json.dumps(value).encode()))
        with self.assertRaises(ValueError):
            relay.notice_event(b"x" * (relay.MAX_BODY + 1))

    def test_non_text_notice_identity_is_rejected_without_crashing_consumer(self):
        for identity in (None, 3, {}, []):
            value = self.event()
            value["playback"]["id"] = identity
            self.assertIsNone(relay.notice_event(json.dumps(value).encode()))

    def test_spool_is_durable_bounded_idempotent_and_private(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event = relay.notice_event(json.dumps(self.event()).encode())
            first = relay.spool_event(root, event)
            self.assertEqual(first, relay.spool_event(root, event))
            self.assertEqual(first.read_bytes(), event)
            self.assertEqual(first.stat().st_mode & 0o777, 0o600)
            with patch.object(relay, "MAX_SPOOL", 1), self.assertRaises(OSError):
                relay.spool_event(root, b'{"another":"event"}')

    def test_unsafe_origins_paths_and_private_dns_never_connect(self):
        for origin in ("http://pbx.example.test", "https://127.0.0.1", "https://x:y@pbx.example.test", "https://pbx.example.test/ari"):
            with self.assertRaises(ValueError):
                relay.configured_url(origin)
        with self.assertRaises(ValueError):
            relay.configured_url("https://app.example.test/wrong", "/api/v1/telephony/pbx/webhook")
        with patch.object(relay.socket, "getaddrinfo", return_value=[(2, 1, 6, "", ("127.0.0.1", 443))]), patch.object(relay.socket, "socket") as connect:
            with self.assertRaises(OSError):
                relay.pinned_tls("pbx.example.test")
            connect.assert_not_called()

    def ivr(self, event_type="ChannelDtmfReceived", age=0):
        identifier = "4acf5490-60ba-439d-8a74-84960a9a1e4d"
        return {"type": event_type, "digit": "1",
                "timestamp": (datetime.now(timezone.utc) - timedelta(seconds=age)).isoformat(),
                "channel": {"id": "external", "channelvars": {
                    "KC_TENANT_ID": identifier, "KC_CALL_ID": identifier,
                    "KC_LIVEKIT_ROOM": "room", "KC_SIP_IDENTITY": "sip",
                    "KC_ROLE": "external", "KC_IVR_RUN_ID": identifier,
                    "KC_IVR_STEP": "1"}}}

    def test_combined_stream_normalizes_only_caller_disconnects(self):
        raw = self.ivr("ChannelDestroyed")
        event = json.loads(relay._ivr.ivr_event(json.dumps(raw).encode()))
        self.assertEqual(event["type"], "ChannelDestroyed")
        self.assertNotIn("digit", event)
        raw["channel"]["channelvars"]["KC_ROLE"] = "app"
        self.assertIsNone(relay._ivr.ivr_event(json.dumps(raw).encode()))

    def test_shared_spool_delivers_notice_and_ivr_to_exact_distinct_owner_paths(self):
        deliveries = []
        class Connection:
            def __init__(self, *_args, **_kwargs): pass
            def request(self, method, path, body, headers): deliveries.append((path, body))
            def getresponse(self): return self
            status = 200
            def read(self, _limit): return b"{}"
            def close(self): pass
        with tempfile.TemporaryDirectory() as directory, patch.object(relay, "PinnedHTTPS", Connection):
            root = Path(directory)
            notice = relay.notice_event(json.dumps(self.event()).encode())
            ivr = relay._ivr.ivr_event(json.dumps(self.ivr()).encode())
            relay.spool_event(root, notice)
            relay.spool_event(root, ivr)
            relay.deliver(root, "app.example.test", "/api/v1/telephony/pbx/webhook", "s" * 32)
            self.assertEqual(set(path for path, _ in deliveries), {
                "/api/v1/telephony/pbx/webhook", "/api/v1/telephony/ivr/webhook"})
            self.assertEqual(set(body for _, body in deliveries), {notice, ivr})
            self.assertEqual(list(root.glob("*.json")), [])

    def test_ivr_expiry_does_not_drop_retained_voicemail_notice(self):
        deliveries = []
        class Connection:
            def __init__(self, *_args, **_kwargs): pass
            def request(self, method, path, body, headers): deliveries.append(path)
            def getresponse(self): return self
            status = 500
            def read(self, _limit): return b"{}"
            def close(self): pass
        with tempfile.TemporaryDirectory() as directory, patch.object(relay, "PinnedHTTPS", Connection):
            root = Path(directory)
            event = self.ivr(age=181)
            event["event_id"] = "a" * 64
            relay.spool_event(root, json.dumps(event).encode())
            relay.deliver(root, "app.example.test", "/api/v1/telephony/pbx/webhook", "s" * 32)
            self.assertEqual(deliveries, [])
            notice = relay.spool_event(root, relay.notice_event(json.dumps(self.event()).encode()))
            relay.deliver(root, "app.example.test", "/api/v1/telephony/pbx/webhook", "s" * 32)
            self.assertTrue(notice.exists())
            self.assertEqual(deliveries, ["/api/v1/telephony/pbx/webhook"])


if __name__ == "__main__":
    unittest.main()
