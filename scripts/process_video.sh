#!/usr/bin/env bash
# process_video.sh <video> <out_dir>
#
# Deterministic media pass for ONE video. Produces a text "evidence bundle" that a
# text-only model can synthesize a presentation from. Does the seeing/hearing so the
# LLM doesn't have to.
#
# Outputs in <out_dir>:
#   audio.wav            16kHz mono audio (intermediate)
#   transcript.txt       full transcript (from transcribe.py / faster-whisper)
#   segments.tsv         start<TAB>end<TAB>text
#   frames/kf_####.jpg   sampled keyframes
#   frames_ocr.tsv       RAW per-frame OCR (idx, ts, relpath, escaped text) — dedup input
#   ocr.txt              on-screen text, ONE block per slide (union of that slide's frames)
#   evidence.md          <-- THE FILE THE MODEL READS
#
# Env:
#   KEYFRAME_INTERVAL    seconds between sampled frames (default 20)
#   WHISPER_MODEL        passed through to transcribe.py (default base)
#   OCR_DEDUP            slide-grouping threshold, default 0.55; 0 = one block per frame.
#                        Re-tune without re-OCR: `OCR_DEDUP=0.45 dedupe_slides.py <out_dir>`
#   FORCE=1              redo every step even if its outputs already exist
#
# Resumability: each step below skips itself when its outputs are already on disk, and the
# OCR loop resumes at the frame it left off. A run that is interrupted part-way (agent
# harness timeout, Ctrl-C) can simply be re-invoked — it will not re-transcribe or re-OCR
# what it already did.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Prefer the skill's venv (created by setup.sh); fall back to system python3.
if [[ -x "$SKILL_ROOT/.venv/bin/python" ]]; then PY="$SKILL_ROOT/.venv/bin/python"; else PY="python3"; fi
video="${1:?usage: process_video.sh <video> <out_dir>}"
out_dir="${2:?usage: process_video.sh <video> <out_dir>}"
interval="${KEYFRAME_INTERVAL:-20}"

[[ -f "$video" ]] || { echo "process_video.sh: no such file: $video" >&2; exit 1; }
command -v ffmpeg  >/dev/null || { echo "process_video.sh: ffmpeg not found" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "process_video.sh: ffprobe not found" >&2; exit 1; }

mkdir -p "$out_dir/frames"
base="$(basename "$video")"

# ---- resume guard: skip the whole media pass if it already completed ----------
# evidence.md is written only after every step below, so its presence == done.
ev="$out_dir/evidence.md"
if [[ -s "$ev" && -z "${FORCE:-}" ]]; then
  echo "process_video.sh: [$base] evidence.md already present — skipping media pass (FORCE=1 to redo)" >&2
  printf '%s\n' "$ev"
  exit 0
fi

hhmmss() { # seconds(float) -> HH:MM:SS
  local s="${1%.*}"
  printf '%02d:%02d:%02d' $((s/3600)) $(((s%3600)/60)) $((s%60))
}

echo "process_video.sh: [$base] probing" >&2
duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video" 2>/dev/null || echo 0)"
resolution="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$video" 2>/dev/null || echo '?')"
has_audio="$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$video" 2>/dev/null | head -n1 || true)"

# ---- 1. Audio -> transcript ------------------------------------------------
if [[ -s "$out_dir/segments.tsv" && -z "${FORCE:-}" ]]; then
  echo "process_video.sh: [$base] transcript already present ($(wc -l < "$out_dir/segments.tsv") segments) — skipping audio+ASR" >&2
elif [[ -n "$has_audio" ]]; then
  echo "process_video.sh: [$base] extracting audio" >&2
  ffmpeg -y -loglevel error -i "$video" -vn -ac 1 -ar 16000 "$out_dir/audio.wav"
  echo "process_video.sh: [$base] transcribing (may take a while on CPU)" >&2
  "$PY" "$SCRIPT_DIR/transcribe.py" "$out_dir/audio.wav" "$out_dir" || {
    echo "process_video.sh: transcription failed; continuing without transcript" >&2
    : > "$out_dir/transcript.txt"; : > "$out_dir/segments.tsv"
  }
else
  echo "process_video.sh: [$base] no audio stream" >&2
  : > "$out_dir/transcript.txt"; : > "$out_dir/segments.tsv"
fi

# ---- 2. Keyframes -> OCR ----------------------------------------------------
n_existing=$(find "$out_dir/frames" -maxdepth 1 -name 'kf_*.jpg' | wc -l)
if [[ "$n_existing" -gt 0 && -z "${FORCE:-}" ]]; then
  echo "process_video.sh: [$base] $n_existing keyframes already sampled — skipping extraction" >&2
else
  echo "process_video.sh: [$base] sampling keyframes every ${interval}s" >&2
  ffmpeg -y -loglevel error -i "$video" -vf "fps=1/${interval}" -q:v 3 \
    "$out_dir/frames/kf_%04d.jpg" || echo "process_video.sh: frame sampling failed" >&2
fi

# OCR is the longest silent stretch in this script (seconds per frame, hundreds of frames).
# It checkpoints after every frame so an interrupted run resumes instead of restarting, and
# it reports progress so callers can tell "slow" apart from "hung".
ocr_ckpt="$out_dir/.ocr_last_idx"
raw_ocr="$out_dir/frames_ocr.tsv"                       # idx<TAB>ts<TAB>relpath<TAB>escaped text
start_idx=0
if [[ -z "${FORCE:-}" && -s "$ocr_ckpt" && -s "$raw_ocr" ]]; then
  start_idx="$(cat "$ocr_ckpt")"
  echo "process_video.sh: [$base] resuming OCR after frame $start_idx" >&2
else
  : > "$raw_ocr"
  : > "$ocr_ckpt"
fi

n_frames="$(find "$out_dir/frames" -maxdepth 1 -name 'kf_*.jpg' | wc -l)"
if command -v tesseract >/dev/null; then
  echo "process_video.sh: [$base] OCR on $n_frames keyframes (from $((start_idx+1)))" >&2
  idx=0
  for f in "$out_dir"/frames/kf_*.jpg; do
    [[ -e "$f" ]] || break
    idx=$((idx+1))
    (( idx <= start_idx )) && continue                  # already done in an earlier run
    ts=$(( (idx-1) * interval ))                      # deterministic timestamp
    # NOTE: `set -o pipefail` makes a non-zero tesseract kill the whole script silently
    # (its stderr is discarded). Run it under `if` so errexit is suppressed and a bad
    # frame costs one frame, not the run.
    if ! text="$(tesseract "$f" stdout --psm 3 2>/dev/null | tr -s ' \n' ' \n' | sed '/^[[:space:]]*$/d')"; then
      echo "process_video.sh: OCR failed on $(basename "$f") — skipping frame" >&2
      text=""
    fi
    # Raw, one row per frame — dedup happens later so it can be re-tuned without re-OCR.
    printf '%s\t%s\tframes/%s\t%s\n' "$idx" "$ts" "$(basename "$f")" \
      "$(printf '%s' "$text" | sed -e 's/\\/\\\\/g' -e 's/\t/ /g' | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}')" \
      >> "$raw_ocr"
    echo "$idx" > "$ocr_ckpt"
    if (( idx == 1 || idx % 10 == 0 || idx == n_frames )); then
      echo "process_video.sh: [$base] OCR $idx/$n_frames frames" >&2
    fi
  done
  # Collapse per-frame OCR into one block per SLIDE (union of each run's lines) and pick one
  # representative frame per slide for the vision pass. See dedupe_slides.py for why exact
  # consecutive-match dedup never fires on screen recordings. OCR_DEDUP tunes the threshold.
  "$PY" "$SCRIPT_DIR/dedupe_slides.py" "$out_dir" || {
    echo "process_video.sh: dedupe_slides.py failed — falling back to one block per frame" >&2
    : > "$out_dir/ocr.txt"; : > "$out_dir/kept_frames.tsv"
    while IFS=$'\t' read -r i ts rel txt; do
      [[ -z "${txt// }" ]] && continue
      printf '### [%s] %s\n%b\n\n' "$(hhmmss "$ts")" "$rel" "$txt" >> "$out_dir/ocr.txt"
      printf '%s\t%s\n' "$ts" "$rel" >> "$out_dir/kept_frames.tsv"
    done < "$raw_ocr"
  }
  echo "process_video.sh: [$base] OCR done — $(wc -l < "$out_dir/kept_frames.tsv") slides from $n_frames frames" >&2
else
  echo "process_video.sh: tesseract not installed; skipping OCR (run setup.sh)" >&2
  : > "$out_dir/ocr.txt"; : > "$out_dir/kept_frames.tsv"
  echo "_(OCR unavailable — tesseract not installed)_" >> "$out_dir/ocr.txt"
  # No OCR to dedup on — keep every sampled frame so an optional vision pass still has input.
  idx=0
  for f in "$out_dir"/frames/kf_*.jpg; do
    [[ -e "$f" ]] || break
    idx=$((idx+1)); ts=$(( (idx-1) * interval ))
    printf '%s\tframes/%s\n' "$ts" "$(basename "$f")" >> "$out_dir/kept_frames.tsv"
  done
fi

# ---- 2b. OPTIONAL vision pass (Qwen-VL / any OpenAI-compatible vision model) ------
# Off by default. Enabled when VISION=1 or VISION_MODEL is set. Describes what OCR can't
# (charts/diagrams/UI/gestures). Degrades to OCR-only if disabled or the endpoint fails.
[[ -s "$out_dir/captions.tsv" && -z "${FORCE:-}" ]] || : > "$out_dir/captions.tsv"
if [[ -s "$out_dir/captions.tsv" && -z "${FORCE:-}" ]]; then
  echo "process_video.sh: [$base] captions.tsv already present ($(wc -l < "$out_dir/captions.tsv") captions) — skipping vision pass" >&2
elif [[ "${VISION:-0}" == "1" || -n "${VISION_MODEL:-}" ]]; then
  echo "process_video.sh: [$base] vision captioning (model=${VISION_MODEL:-qwen2.5-vl}); ~10s/frame on a local VLM — see caption_frames.py progress below" >&2
  if "$PY" "$SCRIPT_DIR/caption_frames.py" "$out_dir/kept_frames.tsv" "$out_dir"; then
    :
  else
    echo "process_video.sh: vision pass failed/unavailable; continuing with OCR only" >&2
    : > "$out_dir/captions.tsv"
  fi
fi

# ---- 3. Assemble evidence.md -----------------------------------------------
echo "process_video.sh: [$base] writing evidence.md" >&2
{
  printf '# Evidence: %s\n\n' "$base"
  printf -- '- **Source:** `%s`\n' "$video"
  printf -- '- **Duration:** %s (%.0fs)\n' "$(hhmmss "$duration")" "$duration"
  printf -- '- **Resolution:** %s\n' "$resolution"
  printf -- '- **Keyframe interval:** %ss\n\n' "$interval"

  printf '## Full transcript\n\n'
  if [[ -n "$(tr -d '[:space:]' < "$out_dir/transcript.txt" 2>/dev/null)" ]]; then
    cat "$out_dir/transcript.txt"
  else
    printf '_(no transcript — video had no/undetectable speech)_\n'
  fi
  printf '\n'

  printf '## Timestamped transcript segments\n\n'
  if [[ -s "$out_dir/segments.tsv" ]]; then
    while IFS=$'\t' read -r start end text; do
      printf -- '- [%s] %s\n' "$(hhmmss "$start")" "$text"
    done < "$out_dir/segments.tsv"
  else
    printf '_(none)_\n'
  fi
  printf '\n'

  printf '## On-screen text (OCR of keyframes)\n\n'
  if [[ -s "$out_dir/ocr.txt" ]]; then
    cat "$out_dir/ocr.txt"
  else
    printf '_(no on-screen text detected)_\n'
  fi
  printf '\n'

  # Only emitted when the optional vision pass ran and produced captions.
  if [[ -s "$out_dir/captions.tsv" ]]; then
    printf '## Visual descriptions (vision model: %s)\n\n' "${VISION_MODEL:-qwen2.5-vl}"
    while IFS=$'\t' read -r ts rel cap; do
      [[ -z "$cap" ]] && continue
      printf '### [%s] %s\n%s\n\n' "$(hhmmss "$ts")" "$rel" "$cap"
    done < "$out_dir/captions.tsv"
  fi
} > "$ev"

echo "process_video.sh: [$base] done -> $ev" >&2
printf '%s\n' "$ev"
