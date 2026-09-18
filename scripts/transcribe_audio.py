#!/usr/bin/env python3
"""Transcribe an audio file with the local whisper.cpp Turbo model.

Usage:
    python3 transcribe_audio.py AUDIO OUTDIR

The transcription path is intentionally local-only. Audio is converted to
16 kHz mono PCM, split into temporary ten-minute chunks when needed, and
processed by whisper.cpp. No API key, network request, or remote fallback is
used.

Reliability rule: an empty first-pass transcript is not treated as proof that
there was no voice.  Stereo native captures are retried channel-by-channel
with a relaxed no-speech threshold before the session is declared empty.

Outputs written to OUTDIR:
    transcript.txt           one line per segment with timestamps
    transcript.json          machine-readable segments
    transcription_meta.json  backend, model, language, duration, retry metadata
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
from collections import defaultdict, deque
from pathlib import Path

WHISPER_CLI = os.environ.get("WHISPER_CLI", "/opt/homebrew/bin/whisper-cli")
WHISPER_MODEL = os.path.expanduser(os.environ.get(
    "WHISPER_MODEL", "~/.cache/whisper-cpp/ggml-large-v3-turbo-q5_0.bin"))
CHUNK_SECONDS = 600
SINGLE_FILE_LIMIT = 570
DEFAULT_NO_SPEECH_THRESHOLD = os.environ.get("WHISPER_NO_SPEECH_THRESHOLD", "0.60")
RETRY_NO_SPEECH_THRESHOLD = os.environ.get("WHISPER_RETRY_NO_SPEECH_THRESHOLD", "1.00")
REPETITION_WINDOW_SECONDS = float(os.environ.get("WHISPER_REPETITION_WINDOW_SECONDS", "45"))


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


def transcribe_local_file(
    path: str,
    language: str | None,
    outbase: str,
    *,
    no_speech_threshold: str | None = None,
) -> dict:
    if not shutil.which(WHISPER_CLI):
        raise RuntimeError(f"local whisper-cli not found: {WHISPER_CLI}")
    if not os.path.isfile(WHISPER_MODEL):
        raise RuntimeError(
            f"local Whisper model not found: {WHISPER_MODEL}. "
            "Download ggml-large-v3-turbo-q5_0.bin or set WHISPER_MODEL."
        )

    json_path = f"{outbase}.json"
    threshold = no_speech_threshold or DEFAULT_NO_SPEECH_THRESHOLD
    cmd = [
        WHISPER_CLI, "-m", WHISPER_MODEL, "-f", path,
        "-oj", "-of", outbase,
        "-t", os.environ.get("WHISPER_THREADS", "8"),
        "-nth", str(threshold),
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
        try:
            os.unlink(json_path)
        except FileNotFoundError:
            pass


def extract_local_segments(
    result: dict,
    offset: float,
    *,
    source_channel: str | None = None,
) -> list[dict]:
    segments = []
    for item in result.get("transcription", []):
        timestamps = item.get("timestamps", {})
        text = item.get("text", "").strip()
        start = timestamps.get("from")
        end = timestamps.get("to")
        if not text or not start or not end:
            continue
        segment = {
            "start": offset + parse_whisper_timestamp(start),
            "end": offset + parse_whisper_timestamp(end),
            "text": text,
        }
        if source_channel:
            segment["source_channel"] = source_channel
        segments.append(segment)
    return segments


def audio_channels(source: str) -> int:
    out = subprocess.check_output(
        ["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
         "stream=channels", "-of", "default=noprint_wrappers=1:nokey=1", source],
        text=True,
    ).strip()
    return int(out)


def conversion_filter(channels: int, channel: int | None = None) -> str:
    if channel is not None:
        source_mix = f"pan=mono|c0=c{channel}"
    elif channels >= 2:
        # Normal first pass.  Raw channels are retained separately so a failed
        # mixed pass can be recovered channel-by-channel without losing source
        # information or confusing "no speech" with "no capture".
        source_mix = "pan=mono|c0=0.707*c0+0.707*c1"
    else:
        source_mix = "acopy"
    return f"{source_mix},highpass=f=70,dynaudnorm=f=150:g=15:p=0.95"


def convert_to_mono_pcm(
    source: str,
    destination: str,
    channels: int,
    *,
    channel: int | None = None,
) -> None:
    subprocess.run([
        "ffmpeg", "-nostdin", "-y", "-v", "error", "-i", source,
        "-af", conversion_filter(channels, channel), "-ac", "1", "-ar", "16000",
        "-c:a", "pcm_s16le", destination,
    ], check=True)


def transcribe_chunks(
    audio: str,
    outdir: str,
    duration: float,
    channels: int,
    language: str | None,
    *,
    channel: int | None = None,
    source_channel: str | None = None,
    no_speech_threshold: str | None = None,
) -> list[dict]:
    del outdir  # kept in the signature for compatibility with older callers
    segments: list[dict] = []
    with tempfile.TemporaryDirectory(prefix="physics-transcribe-") as tmp:
        if duration <= SINGLE_FILE_LIMIT:
            chunk_paths = [os.path.join(tmp, "chunk_000.wav")]
            convert_to_mono_pcm(audio, chunk_paths[0], channels, channel=channel)
        else:
            pattern = os.path.join(tmp, "chunk_%03d.wav")
            subprocess.run([
                "ffmpeg", "-nostdin", "-y", "-v", "error", "-i", audio,
                "-af", conversion_filter(channels, channel), "-ac", "1", "-ar", "16000",
                "-c:a", "pcm_s16le",
                "-f", "segment", "-segment_time", str(CHUNK_SECONDS),
                "-reset_timestamps", "1", pattern,
            ], check=True)
            chunk_paths = sorted(str(p) for p in Path(tmp).glob("chunk_*.wav"))

        for index, chunk in enumerate(chunk_paths):
            offset = index * CHUNK_SECONDS
            print(
                f"Transcribing chunk {index + 1}/{len(chunk_paths)} "
                f"(from {fmt_ts(offset)})...",
                file=sys.stderr,
            )
            base = os.path.join(tmp, f"local_{index:03d}")
            result = transcribe_local_file(
                chunk,
                language,
                base,
                no_speech_threshold=no_speech_threshold,
            )
            segments.extend(
                extract_local_segments(
                    result,
                    offset,
                    source_channel=source_channel,
                )
            )
    return segments


def retry_plan(channels: int) -> list[tuple[int | None, str | None, str]]:
    """Return recovery passes used only after a zero-segment first pass."""
    if channels >= 2:
        return [
            (0, "system_audio", "system_channel_relaxed"),
            (1, "microphone", "microphone_channel_relaxed"),
        ]
    return [(None, None, "mono_relaxed")]


def recover_empty_transcript(
    audio: str,
    outdir: str,
    duration: float,
    channels: int,
    language: str | None,
) -> tuple[list[dict], list[str]]:
    recovered: list[dict] = []
    attempts: list[str] = []
    for channel, source_channel, label in retry_plan(channels):
        attempts.append(label)
        recovered.extend(
            transcribe_chunks(
                audio,
                outdir,
                duration,
                channels,
                language,
                channel=channel,
                source_channel=source_channel,
                no_speech_threshold=RETRY_NO_SPEECH_THRESHOLD,
            )
        )
    recovered.sort(key=lambda item: (float(item["start"]), float(item["end"])))
    return recovered, attempts


def transcript_key(text: str) -> str:
    """Normalize text for detecting short-window Whisper decoding loops."""
    return re.sub(r"\W+", "", unicodedata.normalize("NFKC", text).lower())


def collapse_repeated_segments(
    segments: list[dict],
    *,
    window_seconds: float = REPETITION_WINDOW_SECONDS,
) -> tuple[list[dict], int]:
    """Drop exact repeated loops while preserving the first occurrence.

    Long recordings can make Whisper repeat one phrase every second during a
    quiet or noisy interval. A phrase repeated after a long interval may be a
    legitimate teaching example, so only collapse duplicates inside a short
    time window. The original unfiltered output is preserved separately by
    ``main`` whenever anything is removed.
    """
    recent: dict[str, deque[float]] = defaultdict(deque)
    cleaned: list[dict] = []
    dropped = 0
    for segment in segments:
        text = str(segment.get("text", "")).strip()
        source_channel = str(segment.get("source_channel", ""))
        key = f"{source_channel}:{transcript_key(text)}" if source_channel else transcript_key(text)
        if not key or len(key) < 4:
            cleaned.append(segment)
            continue
        start = float(segment.get("start", 0.0))
        timestamps = recent[key]
        while timestamps and start - timestamps[0] > window_seconds:
            timestamps.popleft()
        if timestamps:
            dropped += 1
            continue
        cleaned.append(segment)
        timestamps.append(start)
    return cleaned, dropped


def write_outputs(
    outdir: str,
    segments: list[dict],
    metadata: dict[str, object],
) -> None:
    with open(os.path.join(outdir, "transcript.txt"), "w", encoding="utf-8") as f:
        for segment in segments:
            source = segment.get("source_channel")
            source_label = f"[{source}] " if source else ""
            f.write(
                f"[{fmt_ts(segment['start'])} - {fmt_ts(segment['end'])}] "
                f"{source_label}{segment['text']}\n"
            )
    with open(os.path.join(outdir, "transcript.json"), "w", encoding="utf-8") as f:
        json.dump(segments, f, ensure_ascii=False, indent=2)
    with open(os.path.join(outdir, "transcription_meta.json"), "w", encoding="utf-8") as f:
        json.dump(metadata, f, ensure_ascii=False, indent=2)


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
    print("Backend: local whisper.cpp", file=sys.stderr)
    print(f"Model: {WHISPER_MODEL}", file=sys.stderr)
    print(f"Audio duration: {fmt_ts(duration)}", file=sys.stderr)

    attempts = ["mixed_default"]
    segments = transcribe_chunks(
        audio,
        outdir,
        duration,
        channels,
        language,
        no_speech_threshold=DEFAULT_NO_SPEECH_THRESHOLD,
    )
    fallback_used = False
    if not segments:
        fallback_used = True
        print(
            "Primary Whisper pass returned zero segments; retrying recoverable "
            "source channel(s) with a relaxed no-speech threshold.",
            file=sys.stderr,
        )
        segments, recovery_attempts = recover_empty_transcript(
            audio, outdir, duration, channels, language
        )
        attempts.extend(recovery_attempts)

    raw_segments = list(segments)
    raw_segment_count = len(raw_segments)
    segments, repetition_filter_dropped = collapse_repeated_segments(segments)
    if repetition_filter_dropped:
        raw_json_path = os.path.join(outdir, "transcript_raw.json")
        with open(raw_json_path, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "segments": raw_segments,
                    "raw_segment_count": raw_segment_count,
                    "note": "Unfiltered Whisper output retained for diagnosis; transcript.json/txt contain the cleaned output.",
                },
                f,
                ensure_ascii=False,
                indent=2,
            )

    metadata: dict[str, object] = {
        "backend": "local-whisper.cpp",
        "model": WHISPER_MODEL,
        "language": language,
        "duration_seconds": duration,
        "source_channels": channels,
        "segment_count": len(segments),
        "raw_segment_count": raw_segment_count,
        "repetition_filter_dropped": repetition_filter_dropped,
        "transcript_cleaned": bool(repetition_filter_dropped),
        "no_speech_threshold_primary": DEFAULT_NO_SPEECH_THRESHOLD,
        "no_speech_threshold_retry": RETRY_NO_SPEECH_THRESHOLD,
        "fallback_used": fallback_used,
        "attempts": attempts,
        "status": "ok" if segments else "no_speech_after_retries",
    }
    write_outputs(outdir, segments, metadata)

    if not segments:
        raise RuntimeError(
            "Whisper produced no speech segments after mixed and recovery passes; "
            "audio was preserved for diagnosis."
        )

    print(f"Done: {len(segments)} segments -> {outdir}/transcript.txt")


if __name__ == "__main__":
    main()
