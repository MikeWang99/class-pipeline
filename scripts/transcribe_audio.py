#!/usr/bin/env python3
"""Transcribe audio with Groq Whisper or the local whisper.cpp fallback.

Usage:
    python3 transcribe_audio.py AUDIO OUTDIR

Groq is preferred in ``auto`` mode when available. If it returns a permission,
network, or authentication error, ``auto`` falls back to local whisper.cpp.
Long audio is auto-chunked with ffmpeg
(10-minute WAV pieces, ~19MB each) so the 25MB API upload limit is never hit.

Outputs written to OUTDIR:
    transcript.txt   one line per segment:  [HH:MM:SS - HH:MM:SS] text
    transcript.json  machine-readable segments {start, end, text}
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
import sys
import tempfile

GROQ_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
GROQ_MODEL = "whisper-large-v3-turbo"
WHISPER_CLI = os.environ.get("WHISPER_CLI", "/opt/homebrew/bin/whisper-cli")
WHISPER_MODEL = os.path.expanduser(os.environ.get(
    "WHISPER_MODEL", "~/.cache/whisper-cpp/ggml-small.bin"))
CHUNK_SECONDS = 600          # 10-minute chunks (~19MB WAV, under 25MB API limit)
SINGLE_FILE_LIMIT = 570      # under ~9.5 min -> upload directly


def fmt_ts(sec: float) -> str:
    sec = int(sec)
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h:02d}:{m:02d}:{s:02d}"
    return f"{m:02d}:{s:02d}"


def probe_duration(path: str) -> float:
    out = subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", path],
        text=True).strip()
    return float(out)


def detect_proxy() -> str | None:
    """HTTP proxy usable by this process.

    Uses $https_proxy if set, else falls back to the macOS system proxy
    (e.g. Clash Verge) which terminal/launchd processes do not inherit.
    Needed where Groq blocks direct egress (HTTP 403 from CN networks).
    """
    for var in ("https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY", "all_proxy"):
        if os.environ.get(var):
            return os.environ[var]
    try:
        out = subprocess.run(["scutil", "--proxy"], capture_output=True, text=True,
                             timeout=5).stdout
        enabled = "HTTPSEnable : 1" in out or "HTTPEnable : 1" in out
        host = port = None
        for line in out.splitlines():
            key, _, val = line.partition(":")
            key, val = key.strip(), val.strip()
            if key == "HTTPSProxy" or (host is None and key == "HTTPProxy"):
                host = val
            if key == "HTTPSPort" or (port is None and key == "HTTPPort"):
                port = val
        if enabled and host and port:
            return f"http://{host}:{port}"
    except Exception:
        pass
    return None


def transcribe_file(path: str, api_key: str, language: str | None,
                    max_attempts: int = 3) -> dict:
    cmd = ["curl", "-s", "--max-time", "900", GROQ_URL,
           "-H", f"Authorization: Bearer {api_key}",
           "-F", f"file=@{path};type=audio/wav",
           "-F", f"model={GROQ_MODEL}",
           "-F", "response_format=verbose_json"]
    proxy = detect_proxy()
    if proxy:
        cmd += ["-x", proxy]
    if language:
        cmd += ["-F", f"language={language}"]
    last_err = ""
    for attempt in range(1, max_attempts + 1):
        # curl responses can contain non-UTF-8 diagnostics; keep decoding
        # resilient so the fallback path can handle the actual API failure.
        result = subprocess.run(
            cmd, capture_output=True, text=True, encoding="utf-8", errors="replace"
        )
        if result.returncode != 0:
            last_err = f"curl failed: {result.stderr}"
        else:
            try:
                data = json.loads(result.stdout)
            except json.JSONDecodeError:
                last_err = f"Unexpected response from Groq: {result.stdout[:300]}"
            else:
                if "error" not in data:
                    return data
                last_err = f"Groq API error: {data['error']}"
                # A 403 is deterministic for this key/project/region. Retrying
                # it only delays the local fallback and never changes the result.
                error_text = json.dumps(data.get("error"), ensure_ascii=False).lower()
                if ("403" in error_text or "401" in error_text or
                        "forbidden" in error_text or "permission" in error_text or
                        "invalid_api_key" in error_text or "unauthorized" in error_text):
                    raise RuntimeError(last_err)
        # 524/超时多为代理侧瞬时故障，退避后重试
        if attempt < max_attempts:
            wait = 20 * attempt
            print(f"[retry] attempt {attempt} failed ({last_err[:120]}), "
                  f"retry in {wait}s...", flush=True)
            time.sleep(wait)
    raise RuntimeError(last_err)


def extract_segments(result: dict, offset: float) -> list:
    segs = result.get("segments") or []
    return [{"start": offset + s["start"], "end": offset + s["end"],
             "text": s["text"].strip()} for s in segs if s["text"].strip()]


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
            "Run setup.sh or download a multilingual ggml model first."
        )
    json_path = f"{outbase}.json"
    cmd = [WHISPER_CLI, "-m", WHISPER_MODEL, "-f", path,
           "-l", language or "auto", "-oj", "-of", outbase,
           "-t", os.environ.get("WHISPER_THREADS", "8"), "-np"]
    # whisper-cli can emit locale-dependent bytes in diagnostic output even
    # when its JSON file is valid UTF-8. Do not let that output prevent us
    # from reading the JSON result and completing the transcription.
    result = subprocess.run(
        cmd, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )
    if result.returncode != 0:
        raise RuntimeError(f"local whisper-cli failed: {result.stderr[-500:]}")
    try:
        with open(json_path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"local whisper output missing or invalid: {json_path}") from exc
    return data


def extract_local_segments(result: dict, offset: float) -> list:
    segments = []
    for item in result.get("transcription", []):
        timestamps = item.get("timestamps", {})
        text = item.get("text", "").strip()
        if not text or not timestamps.get("from") or not timestamps.get("to"):
            continue
        segments.append({
            "start": offset + parse_whisper_timestamp(timestamps["from"]),
            "end": offset + parse_whisper_timestamp(timestamps["to"]),
            "text": text,
        })
    return segments


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(f"Usage: {sys.argv[0]} AUDIO OUTDIR")
    audio, outdir = sys.argv[1], sys.argv[2]
    api_key = os.environ.get("GROQ_API_KEY")
    backend = os.environ.get("TRANSCRIBE_BACKEND", "auto").lower()
    if backend not in {"auto", "groq", "local"}:
        sys.exit("ERROR: TRANSCRIBE_BACKEND must be auto, groq, or local")
    if backend == "groq" and not api_key:
        sys.exit("ERROR: TRANSCRIBE_BACKEND=groq requires GROQ_API_KEY")
    if not os.path.isfile(audio):
        sys.exit(f"ERROR: audio file not found: {audio}")
    if not shutil.which("ffmpeg"):
        sys.exit("ERROR: ffmpeg not found (brew install ffmpeg)")
    language = os.environ.get("TRANSCRIBE_LANGUAGE")  # optional: zh / en
    active_backend = backend

    os.makedirs(outdir, exist_ok=True)
    duration = probe_duration(audio)
    print(f"Audio duration: {fmt_ts(duration)}", file=sys.stderr)

    if duration <= SINGLE_FILE_LIMIT:
        wav = os.path.join(outdir, "_full.wav")
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", audio,
                        "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav], check=True)
        try:
            if active_backend == "local" or (active_backend == "auto" and not api_key):
                local_base = os.path.join(outdir, "_local_full")
                segments = extract_local_segments(
                    transcribe_local_file(wav, language, local_base), 0.0)
            else:
                try:
                    segments = extract_segments(transcribe_file(wav, api_key, language), 0.0)
                except RuntimeError as exc:
                    if active_backend == "groq":
                        raise
                    print(f"[fallback] Groq unavailable: {exc}; using local Whisper", file=sys.stderr)
                    active_backend = "local"
                    local_base = os.path.join(outdir, "_local_full")
                    segments = extract_local_segments(
                        transcribe_local_file(wav, language, local_base), 0.0)
        finally:
            if os.path.exists(wav):
                os.unlink(wav)
    else:
        segments = []
        with tempfile.TemporaryDirectory() as tmp:
            pattern = os.path.join(tmp, "chunk_%03d.wav")
            subprocess.run(
                ["ffmpeg", "-nostdin", "-y", "-v", "error", "-i", audio, "-ac", "1", "-ar", "16000",
                 "-c:a", "pcm_s16le", "-f", "segment", "-segment_time", str(CHUNK_SECONDS),
                 "-reset_timestamps", "1", pattern], check=True)
            chunks = sorted(os.path.join(tmp, f) for f in os.listdir(tmp))
            for i, chunk in enumerate(chunks):
                offset = i * CHUNK_SECONDS
                print(f"Transcribing chunk {i + 1}/{len(chunks)} "
                      f"(from {fmt_ts(offset)})...", file=sys.stderr)
                if active_backend == "local" or (active_backend == "auto" and not api_key):
                    local_base = os.path.join(tmp, f"local_{i:03d}")
                    result = transcribe_local_file(chunk, language, local_base)
                    segments.extend(extract_local_segments(result, offset))
                else:
                    try:
                        result = transcribe_file(chunk, api_key, language)
                        segments.extend(extract_segments(result, offset))
                    except RuntimeError as exc:
                        if active_backend == "groq":
                            raise
                        print(f"[fallback] Groq unavailable: {exc}; using local Whisper", file=sys.stderr)
                        active_backend = "local"
                        local_base = os.path.join(tmp, f"local_{i:03d}")
                        result = transcribe_local_file(chunk, language, local_base)
                        segments.extend(extract_local_segments(result, offset))

    with open(os.path.join(outdir, "transcript.txt"), "w", encoding="utf-8") as f:
        for s in segments:
            f.write(f"[{fmt_ts(s['start'])} - {fmt_ts(s['end'])}] {s['text']}\n")
    with open(os.path.join(outdir, "transcript.json"), "w", encoding="utf-8") as f:
        json.dump(segments, f, ensure_ascii=False, indent=2)
    print(f"Done: {len(segments)} segments -> {outdir}/transcript.txt")


if __name__ == "__main__":
    main()
