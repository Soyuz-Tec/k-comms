"""Synthetic protocol cases; these do not establish speech-engine qualification."""
import unittest
from protocol import normalized_result

class RecognitionProtocolTest(unittest.TestCase):
    def test_real_source_digest_and_explicit_post_recording_mode(self):
        import hashlib
        result = normalized_result(b"synthetic media", "a" * 64, "en",
                                   [{"start": 0, "end": 1, "text": "A quote"}], "operation")
        self.assertEqual(result["source_sha256"], hashlib.sha256(b"synthetic media").hexdigest())
        self.assertEqual(result["mode"], "post_recording")

    def test_malformed_results_and_resource_bounds_fail_closed(self):
        for row in [{"start": 1, "end": 0, "text": "reversed"},
                    {"start": float("nan"), "end": 1, "text": "bad"},
                    {"start": 0, "end": 301, "text": "too long"},
                    {"start": True, "end": 1, "text": "not numeric"},
                    {"start": 0, "end": 1, "text": "unsafe\x00"},
                    {"start": 0, "end": 1, "text": " "}]:
            with self.subTest(row=row), self.assertRaises(ValueError):
                normalized_result(b"media", "a" * 64, "en", [row], "operation")
        with self.assertRaises(ValueError):
            normalized_result(b"media", "a" * 64, "en", [], "operation")
        with self.assertRaises(ValueError):
            normalized_result(b"media", "a" * 64, "en", [{"start": 2, "end": 3, "text": "A"}, {"start": 1, "end": 2, "text": "B"}], "operation")

if __name__ == "__main__":
    unittest.main()
