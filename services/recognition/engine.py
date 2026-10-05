"""Actual CPU inference child. No model lookup, downloads, remote code, or live stream."""
import hashlib
import json
import os
from pathlib import Path
import resource
import sys

from protocol import MAX_MEDIA_BYTES, MAX_SECONDS, normalized_result

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"


def verify_model(directory, manifest):
    root = Path(directory).resolve(strict=True)
    for name, proof in manifest["files"].items():
        path = root / name
        if path.is_symlink() or path.stat().st_size != proof["bytes"]:
            raise ValueError("model artifact mismatch")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1_048_576), b""):
                digest.update(block)
        if digest.hexdigest() != proof["sha256"]:
            raise ValueError("model artifact mismatch")
    return root


def recognize(media_path, directory, manifest, language, threads, operation_id):
    import av
    import numpy as np
    from faster_whisper import WhisperModel

    root = verify_model(directory, manifest)
    media = Path(media_path).read_bytes()
    if not 1 <= len(media) <= MAX_MEDIA_BYTES:
        raise ValueError("media too large")
    samples, count = [], 0
    # Decode incrementally and stop at the accepted duration before allocation
    # can grow with a compressed multi-hour recording. PyAV is engine-pinned.
    with av.open(media_path, mode="r", format="flac" if Path(media_path).suffix == ".flac" else "mov",
                 options={"protocol_whitelist": "file", "enable_drefs": "0", "use_absolute_path": "0"}) as container:
        if not container.streams.audio:
            raise ValueError("audio missing")
        resampler = av.AudioResampler(format="s16", layout="mono", rate=16_000)
        for frame in container.decode(audio=0):
            for converted in resampler.resample(frame):
                count += converted.samples
                if count > 16_000 * MAX_SECONDS:
                    raise ValueError("recording exceeds approved duration")
                samples.append(converted.to_ndarray().reshape(-1))
        for converted in resampler.resample(None):
            count += converted.samples
            if count > 16_000 * MAX_SECONDS:
                raise ValueError("recording exceeds approved duration")
            samples.append(converted.to_ndarray().reshape(-1))
    if not samples:
        raise ValueError("audio missing")
    waveform = np.concatenate(samples).astype(np.float32) / 32768.0
    model = WhisperModel(str(root), device="cpu", compute_type="int8", cpu_threads=threads,
                         num_workers=1, local_files_only=True)
    verify_model(directory, manifest)
    segments, info = model.transcribe(waveform, language=language, beam_size=1,
                                      vad_filter=False, condition_on_previous_text=False)
    return normalized_result(media, manifest["files"]["model.bin"]["sha256"], info.language,
                             ({"start": row.start, "end": row.end, "text": row.text} for row in segments),
                             operation_id)


if __name__ == "__main__":
    # Entire decode/load/inference runs in a killable child with an OS CPU bound.
    resource.setrlimit(resource.RLIMIT_CPU, (55, 56))
    resource.setrlimit(resource.RLIMIT_FSIZE, (1_048_576, 1_048_576))
    media_path, output_path, language, operation_id = sys.argv[1:]
    manifest = json.loads(Path(__file__).with_name("model-manifest.json").read_text())
    threads = int(os.environ.get("RECOGNITION_CPU_THREADS", "1"))
    if threads not in range(1, 5):
        raise ValueError("invalid CPU bound")
    result = recognize(media_path, os.environ["RECOGNITION_MODEL_DIR"], manifest,
                       language or None, threads, operation_id)
    Path(output_path).write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
