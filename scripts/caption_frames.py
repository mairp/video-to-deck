#!/usr/bin/env python3
"""
caption_frames.py <kept_frames.tsv> <out_dir>

OPTIONAL vision pass. For each kept keyframe, ask a Qwen-VL (or any OpenAI-compatible
vision) model to describe what's on screen — charts, diagrams, UI, body language, things
OCR can't capture. Writes:
  <out_dir>/captions.tsv     timestamp<TAB>frame_path<TAB>caption

Input TSV lines: "<seconds>\t<frame_path>" (frame_path relative to out_dir).

Enable + configure via env (this script is only called when VISION is on):
  VISION_MODEL     model id to use (default: qwen2.5-vl). Setting this is what turns vision on.
  VISION_ENDPOINT  OpenAI-compatible chat URL (default: http://127.0.0.1:8081/v1/chat/completions).
                   Works with llama.cpp/llama-swap, Ollama, vLLM, LM Studio, or a hosted API —
                   see references/vision-qwen-vl.md.
  VISION_API_KEY   bearer token if the endpoint needs one (default: none / "dummy").
  VISION_PROMPT    override the per-frame instruction.
  VISION_MAX       cap number of frames to caption (default: 40) to bound cost/time. When
                   there are more kept frames than this, they are sampled EVENLY across the
                   whole timeline (not truncated to the first N), so a long video still gets
                   visual coverage end-to-end. 0 = no cap.
  VISION_TIMEOUT   per-request seconds (default: 120).

Uses only the Python stdlib (urllib) — no extra deps. Best-effort: a frame that fails is
skipped with a warning; if the endpoint is unreachable at all, exits non-zero so the caller
can note that vision was unavailable and fall back to OCR.
"""
import base64
import json
import os
import sys
import urllib.request
import urllib.error

DEFAULT_PROMPT = (
    "This is a single frame from a presentation/screen-recording video. In 1-3 sentences, "
    "describe what it SHOWS that plain text can't convey: diagrams, charts (and their trend), "
    "UI layout, code, or a speaker's gesture. Be concrete and factual; do not guess beyond "
    "what is visible. If it is just plain text on a slide, say 'plain text slide'."
)


def die(msg, code=1):
    print(f"caption_frames.py: {msg}", file=sys.stderr)
    sys.exit(code)


def caption_one(url, model, key, prompt, timeout, img_path):
    with open(img_path, "rb") as fh:
        b64 = base64.b64encode(fh.read()).decode("ascii")
    payload = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url",
                 "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
            ],
        }],
        "max_tokens": 300,
        "temperature": 0.2,
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", f"Bearer {key or 'dummy'}")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    return body["choices"][0]["message"]["content"].strip()


def main():
    if len(sys.argv) < 3:
        die("usage: caption_frames.py <kept_frames.tsv> <out_dir>")
    tsv, out_dir = sys.argv[1], sys.argv[2]
    if not os.path.isfile(tsv):
        die(f"no such file: {tsv}")

    model = os.environ.get("VISION_MODEL", "qwen2.5-vl")
    url = os.environ.get("VISION_ENDPOINT",
                         "http://127.0.0.1:8081/v1/chat/completions")
    key = os.environ.get("VISION_API_KEY", "")
    prompt = os.environ.get("VISION_PROMPT", DEFAULT_PROMPT)
    max_n = int(os.environ.get("VISION_MAX", "40"))
    timeout = float(os.environ.get("VISION_TIMEOUT", "120"))

    frames = []
    with open(tsv, encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[1]:
                frames.append((parts[0], parts[1]))
    total_kept = len(frames)
    if 0 < max_n < total_kept:
        # Sample evenly across the timeline instead of taking the first max_n: a 40-minute
        # talk must not end up with visual coverage of only its first 13 minutes.
        step = total_kept / float(max_n)
        frames = [frames[min(int(i * step), total_kept - 1)] for i in range(max_n)]
        print(f"caption_frames.py: {total_kept} kept frames > VISION_MAX={max_n} — "
              f"sampling {len(frames)} evenly across the video "
              f"(raise VISION_MAX for full coverage)", file=sys.stderr)
    if not frames:
        die("no frames to caption", code=0)

    print(f"caption_frames.py: model={model} endpoint={url} frames={len(frames)}",
          file=sys.stderr)

    out_path = os.path.join(out_dir, "captions.tsv")
    ok = 0
    missing = 0
    first_error = None
    n = len(frames)
    with open(out_path, "w", encoding="utf-8") as out:
        for i, (ts, rel) in enumerate(frames, 1):
            img = rel if os.path.isabs(rel) else os.path.join(out_dir, rel)
            if not os.path.isfile(img):
                missing += 1
                print(f"caption_frames.py: [{i}/{n}] missing frame file: {img}",
                      file=sys.stderr)
                continue
            try:
                cap = caption_one(url, model, key, prompt, timeout, img)
                cap = " ".join(cap.split())  # single line for TSV
                out.write(f"{ts}\t{rel}\t{cap}\n")
                out.flush()
                ok += 1
            except (urllib.error.URLError, urllib.error.HTTPError, OSError) as e:
                if first_error is None:
                    first_error = e
                print(f"caption_frames.py: frame {rel} failed: {e}", file=sys.stderr)
            # Heartbeat: this loop is minutes long on a local VLM. Silence here is what
            # makes callers (and agent harnesses) think the whole skill has hung.
            if i == 1 or i % 5 == 0 or i == n:
                print(f"caption_frames.py: captioned {ok}/{i} of {n} frames",
                      file=sys.stderr)

    if ok == 0:
        if missing == n:
            die(f"none of the {n} frame files exist (paths in the TSV are relative to "
                f"out_dir '{out_dir}') — the vision endpoint was never contacted.", code=2)
        die(f"vision endpoint produced no captions "
            f"(first error: {first_error}). Check VISION_ENDPOINT/VISION_MODEL.", code=2)
    print(f"caption_frames.py: wrote {out_path} ({ok} captions"
          + (f", {missing} frames missing" if missing else "") + ")", file=sys.stderr)


if __name__ == "__main__":
    main()
