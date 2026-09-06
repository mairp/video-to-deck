#!/usr/bin/env bash
# drive_decks.sh <folder | video-file> [options]
#
# Robust, hierarchy-aware driver for turning videos into decks with the agent of your choice.
# THE batch driver for this skill. The SHELL owns the loop and spawns a FRESH agent per video,
# so each agent only ever sees one evidence.md — it never overflows a local model's context
# (~64k), can't "forget to iterate" or background-and-quit the batch, is crash-isolated, and is
# resumable (a plain deck.md file-test). Contrast: a model-orchestrated loop reliably quits after
# ~1 video, which is why that approach was removed.
#
# INPUT can be:
#   - a single video file        -> one deck at <out>/<stem>/
#   - a folder (recursed)        -> one deck per video, MIRRORING the source subfolders:
#                                     <src>/CourseA/Unit 4.mkv -> <out>/CourseA/Unit 4/deck.md
#
# Options:
#   --agent-cmd "CMD"          command that authors one deck (default: "claude -p", or
#                                $V2D_AGENT_CMD). The prompt is appended as the final
#                                argument, unless CMD contains the literal {prompt}, which
#                                is substituted instead. Examples:
#                                  --agent-cmd "claude -p"
#                                  --agent-cmd "ollama run qwen3"
#                                  --agent-cmd "llm -m gpt-4o-mini"
#                                Any CLI that reads a prompt and writes files works.
#   --out DIR                  output root (default: <input-dir>/decks)
#   --no-vision                skip the vision caption pass (OCR only)
#   --no-finalize              skip the trailing mermaid-sanitize + topic-rename
#   --pdf                      after authoring, export every deck.md to PDF (mermaid
#                                pre-rendered to images). Collapses the leaf folder so each
#                                PDF lands in its PARENT: <out>/CourseA/lesson/deck.md ->
#                                <out>/CourseA/lesson.pdf (no subfolder just to hold one PDF)
#   --background               detach; print pid + logfile, then return
#   --dry-run                  print the resolved per-video plan; run nothing
#   -h|--help                  this help
#
# Every run writes a TIMESTAMPED log under <out>/logs/<UTC-YYYYMMDD-HHMMSS>-drive-<agent>.log.
# Resumable + idempotent: re-run any time — done videos print "skip", process_video.sh reuses
# an existing evidence.md. Transcription, OCR and rendering are always local; whether the
# authoring step leaves the machine is entirely up to the --agent-cmd you choose.
set -uo pipefail   # NOTE: no -e; a single bad video must not abort the whole batch.

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCR="$SKILL_DIR/scripts"
PY="$SKILL_DIR/.venv/bin/python"; [[ -x "$PY" ]] || PY=python3
# Optional machine-local overrides (agent command, endpoints, model pins). Gitignored.
# shellcheck disable=SC1091
[[ -f "$SKILL_DIR/local.env" ]] && source "$SKILL_DIR/local.env"
# evidence.md above this many bytes won't fit a ~65k-context model once the system prompt +
# template + diagram cheatsheet are added, so we skip the model and use the deterministic
# evidence_to_deck.py directly. (OCR-heavy screencasts blow past this easily.) Raise it via env
# if your model has a bigger window.
EVIDENCE_MAX_BYTES="${EVIDENCE_MAX_BYTES:-100000}"

AGENT_CMD="${V2D_AGENT_CMD:-claude -p}"
OUT=""; VISION=1; FINALIZE=1; BACKGROUND=0; DRY=0; PDF=0; INPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent-cmd)   AGENT_CMD="${2:?}"; shift 2 ;;
    --out)         OUT="${2:?}"; shift 2 ;;
    --no-vision)   VISION=0; shift ;;
    --no-finalize) FINALIZE=0; shift ;;
    --pdf)         PDF=1; shift ;;
    --background)  BACKGROUND=1; shift ;;
    --dry-run)     DRY=1; shift ;;
    -h|--help)     sed -n '2,38p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             [[ -z "$INPUT" ]] && INPUT="$1" || echo "drive_decks.sh: ignoring extra arg $1" >&2; shift ;;
  esac
done
[[ -n "$INPUT" ]] || { echo "drive_decks.sh: need a <folder|video-file>. Try --help." >&2; exit 2; }
[[ -n "${AGENT_CMD// }" ]] || { echo "drive_decks.sh: --agent-cmd must not be empty" >&2; exit 2; }
# Short tag for the log filename: the command's basename, sanitized.
AGENT_TAG="$(printf '%s' "$(basename "${AGENT_CMD%% *}")" | tr -c 'A-Za-z0-9_.-' '-')"

# ---- resolve input: single file vs folder, and the mirror ROOT --------------
if [[ -f "$INPUT" ]]; then
  SINGLE=1; ROOT="$(cd "$(dirname "$INPUT")" && pwd)"; INPUT="$ROOT/$(basename "$INPUT")"
elif [[ -d "$INPUT" ]]; then
  SINGLE=0; ROOT="$(cd "$INPUT" && pwd)"
else
  echo "drive_decks.sh: not a file or directory: $INPUT" >&2; exit 2
fi
OUT="${OUT:-$ROOT/decks}"; mkdir -p "$OUT/logs"
TS="$(date -u +%Y%m%d-%H%M%S)"
LOG="$OUT/logs/${TS}-drive-${AGENT_TAG}.log"

# ---- gather videos ----------------------------------------------------------
if [[ "$SINGLE" -eq 1 ]]; then VIDEOS=("$INPUT"); else mapfile -t VIDEOS < <(bash "$SCR/find_videos.sh" "$ROOT"); fi
[[ "${#VIDEOS[@]}" -gt 0 ]] || { echo "drive_decks.sh: no videos under $ROOT" >&2; exit 1; }

# map a video path -> its mirrored output dir (<out>/<reldir>/<stem>)
outdir_for() {
  local v="$1" rel reldir stem
  rel="${v#$ROOT/}"; reldir="$(dirname "$rel")"; stem="$(basename "$v")"; stem="${stem%.*}"
  [[ "$reldir" == "." ]] && printf '%s/%s' "$OUT" "$stem" || printf '%s/%s/%s' "$OUT" "$reldir" "$stem"
}

author() {  # $1 = prompt ; a FRESH agent process (fresh context) per call
  local P="$1"
  if [[ "$AGENT_CMD" == *"{prompt}"* ]]; then
    # Placeholder form: the caller decides where the prompt goes.
    env PROMPT="$P" bash -lc "${AGENT_CMD//\{prompt\}/\"\$PROMPT\"}"
  else
    # Default form: append the prompt as the final argument.
    env PROMPT="$P" bash -lc "$AGENT_CMD \"\$PROMPT\""
  fi
}

run_all() {
  if [[ "$VISION" -eq 1 ]]; then
    export VISION_MODEL="${VISION_MODEL:-qwen2.5-vl}"
    export VISION_ENDPOINT="${VISION_ENDPOINT:-http://127.0.0.1:8081/v1/chat/completions}"
  fi
  local i=0 total="${#VIDEOS[@]}" out rel P ev_bytes
  for v in "${VIDEOS[@]}"; do
    i=$((i+1)); out="$(outdir_for "$v")"; rel="${v#$ROOT/}"
    if [[ -s "$out/deck.md" ]]; then echo "[$i/$total] skip: $rel"; continue; fi
    echo "[$i/$total] process: $rel"
    bash "$SCR/process_video.sh" "$v" "$out" || { echo "[$i/$total] PROCESS FAILED: $rel"; continue; }
    P="Read $out/evidence.md and write a Marp slide deck to $out/deck.md, following the structure of $SKILL_DIR/templates/deck.marp.md and the diagram rules in $SKILL_DIR/references/diagrams-cheatsheet.md. Terse bullets; cite [HH:MM:SS]; use the 'Visual descriptions' section for diagram/chart slides; NEVER put ';' inside a mermaid label; only include what the evidence supports. Write ONLY the file $out/deck.md, then stop."
    ev_bytes=$(stat -c%s "$out/evidence.md" 2>/dev/null || echo 0)
    if [[ "$ev_bytes" -gt "$EVIDENCE_MAX_BYTES" ]]; then
      # too big for a local model's context — go straight to the deterministic generator
      echo "[$i/$total] author (deterministic — evidence ${ev_bytes}B > ${EVIDENCE_MAX_BYTES}B, won't fit context): $rel"
      "$PY" "$SCR/evidence_to_deck.py" "$out/evidence.md" "$out" >/dev/null 2>&1 || true
    else
      echo "[$i/$total] author (model): $rel"
      author "$P"
      [[ -s "$out/deck.md" ]] || { echo "[$i/$total] retry: $rel"; author "$P"; }
      if [[ ! -s "$out/deck.md" ]]; then
        # model failed anyway (context/other) — never leave a video deckless: deterministic fallback
        echo "[$i/$total] model author failed — deterministic fallback: $rel"
        "$PY" "$SCR/evidence_to_deck.py" "$out/evidence.md" "$out" >/dev/null 2>&1 || true
      fi
    fi
    [[ -s "$out/deck.md" ]] && echo "[$i/$total] deck: wrote $rel" || echo "[$i/$total] NO DECK (rerun to retry): $rel"
  done
  if [[ "$FINALIZE" -eq 1 ]]; then
    echo "-- finalize: mermaid sanitize + topic rename (recursive) --"
    bash "$SCR/fix_mermaid_labels.sh" "$OUT" || true
    bash "$SCR/rename_by_topic.sh" "$OUT" || true
  fi
  [[ "$PDF" -eq 1 ]] && export_pdfs
  echo "-- done: $total video(s) -> $OUT --"
}

# Export every deck under $OUT to PDF via render.sh (which pre-renders Mermaid to images
# so it survives Marp). COLLAPSES the leaf folder: the PDF is named after the deck's folder
# and written to its PARENT, so we don't create a subfolder just to hold one PDF:
#   <out>/CourseA/lesson/<deck>.md  ->  <out>/CourseA/lesson.pdf
#   <out>/lesson/<deck>.md          ->  <out>/lesson.pdf
# The deck markdown is deck.md before finalize, or <folder>.md after rename_by_topic.sh;
# we handle both. Best-effort: a deck that fails to render logs and the batch continues.
export_pdfs() {
  local made=0 failed=0 dir leaf parent deck stem dest
  echo "-- pdf: exporting decks -> collapsed PDFs under $OUT --"
  while IFS= read -r -d '' dir; do
    dir="$(cd "$dir" && pwd)"
    leaf="$(basename "$dir")"                 # lesson
    parent="$(dirname "$dir")"                # <out>/CourseA  (== $OUT if flat)
    # Locate the deck markdown: renamed (<leaf>.md) or original (deck.md).
    if   [[ -f "$dir/$leaf.md" ]]; then deck="$dir/$leaf.md"
    elif [[ -f "$dir/deck.md"  ]]; then deck="$dir/deck.md"
    else continue   # not a deck dir (e.g. logs/, frames/)
    fi
    stem="$(basename "${deck%.md}")"
    dest="$parent/$leaf.pdf"
    # render.sh writes <stem>.pdf next to the deck; produce it, then move to the parent.
    if bash "$SCR/render.sh" "$deck" pdf >/dev/null 2>&1 </dev/null && [[ -f "$dir/$stem.pdf" ]]; then
      mv -f "$dir/$stem.pdf" "$dest"
      echo "  pdf: ${dest#$OUT/}"
      made=$((made+1))
    else
      echo "  PDF FAILED: ${deck#$OUT/}" >&2
      failed=$((failed+1))
    fi
  done < <(find "$OUT" -mindepth 1 -type d -not -name frames -not -name logs -not -name diagrams -print0)
  echo "-- pdf: $made written, $failed failed --"
}

# ---- report -----------------------------------------------------------------
cat >&2 <<EOF
video-to-deck  ▶  drive_decks ($([[ "$SINGLE" -eq 1 ]] && echo 'single file' || echo 'folder, mirrored'))
  input  : $INPUT
  videos : ${#VIDEOS[@]}
  out    : $OUT   (mirrors source subfolders)
  agent  : $AGENT_CMD
  vision : $([[ "$VISION" -eq 1 ]] && echo 'on (qwen2.5-vl)' || echo 'off')
  pdf    : $([[ "$PDF" -eq 1 ]] && echo 'on (collapsed -> parent folder)' || echo 'off')
  log    : $LOG
EOF

if [[ "$DRY" -eq 1 ]]; then
  echo >&2 "  (dry run — resolved output dirs:)"
  for v in "${VIDEOS[@]}"; do printf '    %s\n' "$(outdir_for "$v")/deck.md"; done
  [[ "$PDF" -eq 1 ]] && for v in "${VIDEOS[@]}"; do d="$(outdir_for "$v")"; printf '    %s.pdf\n' "$(dirname "$d")/$(basename "$d")"; done
  exit 0
fi

if [[ "$BACKGROUND" -eq 1 ]]; then
  run_all >"$LOG" 2>&1 &
  pid=$!; disown
  echo >&2 "started in background — pid $pid"
  echo >&2 "  follow : tail -f \"$LOG\""
  echo >&2 "  stop   : kill $pid"
  exit 0
fi
run_all 2>&1 | tee "$LOG"
