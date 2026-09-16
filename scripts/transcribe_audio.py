#!/usr/bin/env python3
"""Transcribe an audio file with the local whisper.cpp Turbo model.

Usage:
    python3 transcribe_audio.py AUDIO OUTDIR

The transcription path is intentionally local-only. Audio is converted to
16 kHz mono PCM, split into temporary ten-minute chunks when needed, and
processed by whisper.cpp. No API key, network request, or remote fallback is
used.

Outputs written to OUTDIR:
    transcript.txt           one line per segment with timestamps
    transcript.json          machine-readable segments
    transcription_meta.json  backend, model, language, and duration metadata
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

WHISPER_CLI = os.environ.get("WHISPER_CLI", "/opt/homebrew/bin/whisper-cli")
WHISPER_MODEL = os.path.expanduser(os.environ.get(
    "WHISPER_MODEL", "~/.cache/whisper-cpp/ggml-large-v3-turbo-q5_0.bin"))
CHUNK_SECONDS = 600
SINGLE_FILE_LIMIT = 570


def fmt_ts(sec: float) -> str:
    sec = int(sec)
    hours, rem = divmod(sec, 3600)
    minutes, seconds = divmod(rem, 60)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}"
    return f"{minutes:02d}:{seconds:02d}"


def probe_duration(path: str) -> float:
    out = subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", path],
        text=True,
    ).strip()
    return float(out)


def parse_whisper_timestamp(value: str) -> float:
    """Parse whisper.cpp's ``HH:MM:SS,mmm`` timestamp."""
    hours, minutes, rest = value.replace(",", ".").split(":")
    return int(hours) * 3600 + int(minutes) * 60 + float(rest)


def transcribe_local_file(path: str, language: str | None, outbase: str) -> dict:
    if not shutil.which(WHISPER_CLI):
        raise RuntimeError(f"local whisper-cli not found: {WHISPER_CLI}")
    if not os.path.isfile(WHISPER_MODEL):
        raise RuntimeError(
            f"local Whisper model not found: {WHISPER_MODEL}. "
            "Download ggml-large-v3-turbo-q5_0.bin or set WHISPER_MODEL."
        )

    json_path = f"{outbase}.json"
    cmd = [
        WHISPER_CLI, "-m", WHISPER_MODEL, "-f", path,
        "-oj", "-of", outbase,
        "-t", os.environ.get("WHISPER_THREADS", "8"),
        "-nth", os.environ.get("WHISPER_NO_SPEECH_THRESHOLD", "0.60"),
        "-np",
    ]
    # Omitting -l lets whisper.cpp auto-detect multilingual speech. An
    # explicit zh/en value can still be supplied through TRANSCRIBE_LANGUAGE.
    if language and language.lower() != "auto":
        cmd.extend(["-l", language])

    result = subprocess.run(
        cmd, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )
    if result.returncode != 0:
        raise RuntimeError(f"local whisper-cli failed: {result.stderr[-800:]}")
    try:
        with open(json_path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"local whisper output missing or invalid: {json_path}") from exc
    finally:
        # The session only needs the normalized transcript and metadata.
        try:
            os.unlink(json_path)
        except FileNotFoundError:
            pass


def extract_local_segments(result: dict, offset: float) -> list[dict]:
    segments = []
    for item in result.get("transcription", []):
        timestamps = item.get("timestamps", {})
        text = item.get("text", "").strip()
        start = timestamps.get("from")
        end = timestamps.get("to")
        if not text or not start or not end:
            continue
        segments.append({
            "start": offset + parse_whisper_timestamp(start),
            "end": offset + parse_whisper_timestamp(end),
            "text": text,
        })
    return segments


def audio_channels(source: str) -> int:
    out = subprocess.check_output(
        ["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
         "stream=channels", "-of", "default=noprint_wrappers=1:nokey=1", source],
        text=True,
    ).strip()
    return int(out)


def conversion_filter(channels: int) -> str:
    # New pipeline recordings are stereo: left = native system audio,
    # right = microphone. Blend the sources only for transcription,
    # after retaining the raw channels for diagnostics.
    source_mix = "pan=mono|c0=0.707*c0+0.707*c1" if channels >= 2 else "acopy"
    return f"{source_mix},highpass=f=70,dynaudnorm=f=150:g=15:p=0.95"


def convert_to_mono_pcm(source: str, destination: str, channels: int) -> None:
    subprocess.run([
        "ffmpeg", "-nostdin", "-y", "-v", "error", "-i", source,
        "-af", conversion_filter(channels), "-ac", "1", "-ar", "16000",
        "-c:a", "pcm_s16le", destination,
    ], check=True)


def transcribe_chunks(audio: str, outdir: str, duration: float, channels: int,
                      language: str | None) -> list[dict]:
    segments: list[dict] = []
    with tempfile.TemporaryDirectory(prefix="physics-transcribe-") as tmp:
        if duration <= SINGLE_FILE_LIMIT:
            chunk_paths = [os.path.join(tmp, "chunk_000.wav")]
            convert_to_mono_pcm(audio, chunk_paths[0], channels)
        else:
            pattern = os.path.join(tmp, "chunk_%03d.wav")
            subprocess.run([
                "ffmpeg", "-nostdin", "-y", "-v", "error", "-i", audio,
                "-af", conversion_filter(channels), "-ac", "1", "-ar", "16000",
                "-c:a", "pcm_s16le",
                "-f", "segment", "-segment_time", str(CHUNK_SECONDS),
                "-reset_timestamps", "1", pattern,
            ], check=True)
            chunk_paths = sorted(str(p) for p in Path(tmp).glob("chunk_*.wav"))

        for index, chunk in enumerate(chunk_paths):
            offset = index * CHUNK_SECONDS
            print(
                f"Transcribing chunk {index + 1}/{len(chunk_paths)} "
                f"(from {fmt_ts(offset)})...", file=sys.stderr,
            )
            base = os.path.join(tmp, f"local_{index:03d}")
            result = transcribe_local_file(chunk, language, base)
            segments.extend(extract_local_segments(result, offset))
    return segments


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(f"Usage: {sys.argv[0]} AUDIO OUTDIR")

    audio, outdir = sys.argv[1], sys.argv[2]
    if not os.path.isfile(audio):
        sys.exit(f"ERROR: audio file not found: {audio}")
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        sys.exit("ERROR: ffmpeg/ffprobe not found (brew install ffmpeg)")

    language = os.environ.get("TRANSCRIBE_LANGUAGE", "auto")
    os.makedirs(outdir, exist_ok=True)
    duration = probe_duration(audio)
    channels = audio_channels(audio)
    print(f"Backend: local whisper.cpp", file=sys.stderr)
    print(f"Model: {WHISPER_MODEL}", file=sys.stderr)
    print(f"Audio duration: {fmt_ts(duration)}", file=sys.stderr)

    segments = transcribe_chunks(audio, outdir, duration, channels, language)
    with open(os.path.join(outdir, "transcript.txt"), "w", encoding="utf-8") as f:
        for segment in segments:
            f.write(
                f"[{fmt_ts(segment['start'])} - {fmt_ts(segment['end'])}] "
                f"{segment['text']}\n"
            )
    with open(os.path.join(outdir, "transcript.json"), "w", encoding="utf-8") as f:
        json.dump(segments, f, ensure_ascii=False, indent=2)
    with open(os.path.join(outdir, "transcription_meta.json"), "w", encoding="utf-8") as f:
        json.dump({
            "backend": "local-whisper.cpp",
            "model": WHISPER_MODEL,
            "language": language,
            "duration_seconds": duration,
            "source_channels": channels,
            "segment_count": len(segments),
        }, f, ensure_ascii=False, indent=2)
    print(f"Done: {len(segments)} segments -> {outdir}/transcript.txt")


if __name__ == "__main__":
    main()
