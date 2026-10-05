"""Bounded, dependency-free recognition protocol; synthetic engines only in tests."""
import hashlib
import json
import math
import re

MAX_MEDIA_BYTES = 26_214_400
MAX_RESPONSE_BYTES = 1_048_576
MAX_SECONDS = 300
MAX_SEGMENTS = 10_000
CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def normalized_result(media, model_sha256, language, segments, operation_id):
    if not media or len(media) > MAX_MEDIA_BYTES or not re.fullmatch(r"[a-f0-9]{64}", model_sha256):
        raise ValueError("invalid source or model proof")
    rows, previous = [], 0.0
    for segment in segments:
        start, end, text = segment["start"], segment["end"], segment["text"].strip()
        if (isinstance(start, bool) or isinstance(end, bool) or
                not isinstance(start, (float, int)) or not isinstance(end, (float, int)) or
                not math.isfinite(start) or not math.isfinite(end) or
                not 0 <= previous <= start <= end <= MAX_SECONDS or
                not 1 <= len(text.encode("utf-8")) <= 8_000 or CONTROL.search(text)):
            raise ValueError("invalid recognition segment")
        rows.append({"start": start, "end": end, "text": text})
        previous = start
        if len(rows) > MAX_SEGMENTS:
            raise ValueError("too many segments")
    if not rows or not re.fullmatch(r"[a-z]{2,3}", language):
        raise ValueError("empty or invalid recognition")
    result = {"id": operation_id, "mode": "post_recording", "language": language,
              "source_sha256": hashlib.sha256(media).hexdigest(),
              "model_sha256": model_sha256, "segments": rows}
    if len(json.dumps(result, ensure_ascii=False).encode()) > MAX_RESPONSE_BYTES:
        raise ValueError("result too large")
    return result
