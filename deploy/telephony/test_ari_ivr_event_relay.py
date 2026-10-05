import importlib.util
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("ivr_relay", Path(__file__).with_name("ari_ivr_event_relay.py"))
relay = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(relay)


class IvrRelayTest(unittest.TestCase):
    now = datetime(2026, 10, 5, 1, 0, tzinfo=timezone.utc)
    identity = "4acf5490-60ba-439d-8a74-84960a9a1e4d"

    def digit(self):
        return {"type": "ChannelDtmfReceived", "timestamp": self.now.isoformat(),
                "digit": "1", "duration_ms": 100,
                "channel": {"id": "caller", "caller": {"number": "private-phone"},
                            "channelvars": {"KC_TENANT_ID": self.identity,
                                            "KC_CALL_ID": self.identity,
                                            "KC_LIVEKIT_ROOM": "kc_room",
                                            "KC_SIP_IDENTITY": "kc_sip",
                                            "KC_ROLE": "external",
                                            "KC_IVR_RUN_ID": self.identity,
                                            "KC_IVR_STEP": "1",
                                            "OTHER_SECRET": "not-forwarded"}}}

    def playback(self):
        return {"type": "PlaybackFinished", "timestamp": self.now.isoformat(),
                "playback": {"id": "kc_ivr_" + "a" * 32 + "_1", "state": "done",
                             "target_uri": "channel:caller", "media_uri": "sound:custom/menu"}}

    def test_only_current_external_caller_bindings_are_forwarded(self):
        body = relay.ivr_event(json.dumps(self.digit()).encode(), self.now)
        value = json.loads(body)
        self.assertEqual(set(value), {"type", "timestamp", "event_id", "digit", "channel"})
        self.assertEqual(set(value["channel"]), {"id", "channelvars"})
        self.assertEqual(set(value["channel"]["channelvars"]), set(relay.BINDINGS))
        self.assertNotIn(b"private-phone", body)
        self.assertNotIn(b"not-forwarded", body)
        self.assertRegex(value["event_id"], r"^[0-9a-f]{64}$")

    def test_app_and_consult_digits_are_excluded(self):
        for role in ("app", "consult", "unknown", None):
            value = self.digit()
            value["channel"]["channelvars"]["KC_ROLE"] = role
            self.assertIsNone(relay.ivr_event(json.dumps(value).encode(), self.now))

    def test_missing_or_substituted_namespace_is_rejected(self):
        for key, replacement in (("KC_TENANT_ID", "foreign"), ("KC_IVR_RUN_ID", "bad"),
                                 ("KC_IVR_STEP", "4"), ("KC_SIP_IDENTITY", "")):
            value = self.digit()
            value["channel"]["channelvars"][key] = replacement
            self.assertIsNone(relay.ivr_event(json.dumps(value).encode(), self.now))

    def test_a_new_received_event_has_an_independent_non_enumerable_receipt(self):
        raw = json.dumps(self.digit()).encode()
        first = json.loads(relay.ivr_event(raw, self.now))
        second = json.loads(relay.ivr_event(raw, self.now))
        self.assertNotEqual(first["event_id"], second["event_id"])

    def test_stale_future_naive_and_oversized_inputs_are_rejected(self):
        for timestamp in ((self.now - timedelta(seconds=181)).isoformat(),
                          (self.now + timedelta(seconds=6)).isoformat(),
                          "2026-10-05T01:00:00", None, "invalid"):
            value = self.digit()
            value["timestamp"] = timestamp
            self.assertIsNone(relay.ivr_event(json.dumps(value).encode(), self.now))
        with self.assertRaises(ValueError):
            relay.ivr_event(b"x" * (relay.MAX_BODY + 1), self.now)

    def test_only_exact_completed_ivr_channel_playbacks_are_forwarded(self):
        self.assertIsNotNone(relay.ivr_event(json.dumps(self.playback()).encode(), self.now))
        for key, value in (("id", "kc_notice_" + "a" * 32), ("state", "playing"),
                           ("target_uri", "bridge:caller"), ("media_uri", "https://foreign.test/sound")):
            event = self.playback()
            event["playback"][key] = value
            self.assertIsNone(relay.ivr_event(json.dumps(event).encode(), self.now))

    def test_expiration_is_bounded_to_owned_spool_events(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            current = relay.ivr_event(json.dumps(self.digit()).encode(), self.now)
            stale = json.loads(current)
            stale["timestamp"] = (self.now - timedelta(seconds=181)).isoformat()
            (directory / "current.json").write_bytes(current)
            (directory / "stale.json").write_text(json.dumps(stale))
            (directory / "unrelated.txt").write_text("retained")
            self.assertEqual(relay.expire_spool(directory, self.now), 1)
            self.assertTrue((directory / "current.json").exists())
            self.assertTrue((directory / "unrelated.txt").exists())

    def test_malformed_provider_shapes_never_become_events(self):
        for channel in (None, {}, "caller", [], {"id": 5, "channelvars": {}}):
            value = self.digit()
            value["channel"] = channel
            self.assertIsNone(relay.ivr_event(json.dumps(value).encode(), self.now))


if __name__ == "__main__":
    unittest.main()
