"""Opt-in actual waveform qualification; requires separately provisioned CPU model."""
import argparse
import hashlib
import json
from pathlib import Path
import uuid
import resource
import signal
from engine import recognize

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).parent
    fixture = json.loads((root / "speech-fixture.json").read_text())
    media = args.fixture.read_bytes()
    assert len(media) == fixture["bytes"] and hashlib.sha256(media).hexdigest() == fixture["sha256"]
    model = json.loads((root / "model-manifest.json").read_text())
    resource.setrlimit(resource.RLIMIT_CPU, (55, 56))
    signal.alarm(60)
    result = recognize(str(args.fixture), args.model_dir, model, "en", 1, str(uuid.uuid4()))
    signal.alarm(0)
    text = " ".join(row["text"] for row in result["segments"]).lower()
    assert fixture["expected_phrase"] in text, "actual recognition did not recover expected licensed speech"
    assert result["source_sha256"] == fixture["sha256"]
    print(json.dumps({"mode": result["mode"], "fixture_sha256": fixture["sha256"],
                      "model_sha256": result["model_sha256"], "segments": len(result["segments"]),
                      "expected_phrase_recognized": True}))
