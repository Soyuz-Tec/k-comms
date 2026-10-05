import importlib.util
import json
import tempfile
import unittest
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


if __name__ == "__main__":
    unittest.main()
