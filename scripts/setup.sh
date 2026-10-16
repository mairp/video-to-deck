#!/usr/bin/env bash
# setup.sh [--check] — idempotent bootstrap of the tools video-to-deck needs.
#
#   (no flag)  install what is missing: system packages via the OS package manager
#              (Homebrew on macOS, apt / dnf on Linux), faster-whisper into ./.venv,
#              marp-cli + mermaid-cli via npm. Prints what it did vs. what was present.
#   --check    read-only doctor: report every tool + the provider config, change nothing.
#
# Safe to run repeatedly. Install output goes to .setup.log so failures can be diagnosed.
set -uo pipefail

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
miss() { printf '  \033[33m…\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILED=1; }

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$SKILL_ROOT/.venv"
LOG="$SKILL_ROOT/.setup.log"
CHECK=0; FAILED=0
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "setup.sh: unknown option $a (try --help)" >&2; exit 2 ;;
  esac
done
# shellcheck disable=SC1091
[[ -f "$SKILL_ROOT/local.env" && -z "${V2D_NO_LOCAL_ENV:-}" ]] && { set -a; source "$SKILL_ROOT/local.env"; set +a; }
[[ "$CHECK" -eq 1 ]] || : > "$LOG"

OS="$(uname -s)"
SUDO=""; [[ "$(id -u)" != 0 ]] && command -v sudo >/dev/null && SUDO="sudo"
pm=""
if [[ "$OS" == Darwin ]]; then command -v brew >/dev/null && pm=brew
elif command -v apt-get >/dev/null; then pm=apt
elif command -v dnf >/dev/null; then pm=dnf
fi

# pkg_install <label> <apt-name> <brew-name> <dnf-name>
pkg_install() {
  local label="$1" apt="$2" brew="$3" dnf="$4" hint
  case "$pm" in
    brew) hint="brew install $brew" ;;
    apt)  hint="sudo apt-get install -y $apt" ;;
    dnf)  hint="sudo dnf install -y $dnf" ;;
    *)    hint="install '$label' with your package manager" ;;
  esac
  if [[ "$CHECK" -eq 1 || -z "$pm" ]]; then
    miss "$label missing — $hint"; return 1
  fi
  miss "installing $label ($hint)…"
  case "$pm" in
    brew) brew install $brew >>"$LOG" 2>&1 ;;   # unquoted: may be "--cask NAME"
    apt)  $SUDO apt-get install -y -q "$apt" >>"$LOG" 2>&1 ;;
    dnf)  $SUDO dnf install -y -q "$dnf" >>"$LOG" 2>&1 ;;
  esac || { fail "$label install failed — run: $hint   (details: $LOG)"; return 1; }
  ok "$label installed"
}

echo "video-to-deck setup ($OS, bash ${BASH_VERSION%%(*}$([[ "$CHECK" -eq 1 ]] && echo ', check only')):"

# 1. ffmpeg/ffprobe — REQUIRED (audio extraction, keyframes).
if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null; then
  ok "ffmpeg/ffprobe present"
else
  pkg_install ffmpeg ffmpeg ffmpeg ffmpeg || fail "ffmpeg is required"
fi

# 2. python3 >= 3.8 — REQUIRED (all helpers are stdlib-only, except transcription).
if python3 -c 'import sys, ssl; sys.exit(sys.version_info < (3, 8))' 2>/dev/null; then
  ok "python3 $(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])') with ssl"
else
  fail "python3 >= 3.8 with the ssl module is required"
fi

# 3. faster-whisper — local transcription. Lives in a dedicated venv (no fight with PEP-668
#    externally-managed system Python).
if [[ -x "$VENV/bin/python" ]] && "$VENV/bin/python" -c "import faster_whisper" 2>/dev/null; then
  ok "faster-whisper present (venv)"
elif [[ "$CHECK" -eq 1 ]]; then
  miss "faster-whisper missing — run scripts/setup.sh"
else
  miss "creating venv + installing faster-whisper (first run downloads ~200 MB)…"
  [[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV" >>"$LOG" 2>&1
  if [[ -x "$VENV/bin/pip" ]] && "$VENV/bin/pip" install --quiet --upgrade pip >>"$LOG" 2>&1 \
     && "$VENV/bin/pip" install --quiet faster-whisper >>"$LOG" 2>&1; then
    ok "faster-whisper installed (venv: .venv)"
  else
    fail "faster-whisper install failed (details: $LOG). On Debian/Ubuntu: sudo apt-get install -y python3-venv"
  fi
fi

# 3b. CUDA runtime libs for CTranslate2 — the difference between GPU and CPU transcription.
#     CTranslate2 dlopen()s libcublas.so.12 + libcudnn.so.9; installed as pip wheels (no system
#     CUDA needed) and put on the loader path by transcribe.py. NVIDIA hosts only.
if [[ -x "$VENV/bin/python" ]] && command -v nvidia-smi >/dev/null 2>&1; then
  if "$VENV/bin/python" -c "import nvidia.cublas, nvidia.cudnn" 2>/dev/null; then
    ok "CUDA libs for CTranslate2 present (GPU transcription)"
  elif [[ "$CHECK" -eq 1 ]]; then
    miss "CUDA libs missing — transcription will use CPU (~4x slower). Run setup.sh to add them."
  elif "$VENV/bin/pip" install --quiet nvidia-cublas-cu12 nvidia-cudnn-cu12 >>"$LOG" 2>&1; then
    ok "CUDA libs installed — transcription will use the GPU"
  else
    fail "CUDA lib install failed — transcription will run on CPU (~4x slower, still correct)"
  fi
fi

# 4. tesseract — RECOMMENDED (OCR of on-screen text). The skill degrades gracefully without it.
if command -v tesseract >/dev/null; then
  ok "tesseract present"
else
  pkg_install tesseract tesseract-ocr tesseract tesseract || miss "without tesseract, OCR is skipped"
fi

# 5. marp-cli + mermaid-cli — OPTIONAL (export to PPTX/PDF/HTML, diagrams to images).
for tool in marp:@marp-team/marp-cli mmdc:@mermaid-js/mermaid-cli; do
  bin="${tool%%:*}"; npmpkg="${tool#*:}"
  if command -v "$bin" >/dev/null; then
    ok "$bin present"
  elif ! command -v npm >/dev/null; then
    miss "$bin skipped (no npm) — decks stay valid Markdown. Install Node.js, then: npm i -g $npmpkg"
  elif [[ "$CHECK" -eq 1 ]]; then
    miss "$bin missing — npm i -g $npmpkg"
  elif npm install -g "$npmpkg" >>"$LOG" 2>&1; then
    ok "$bin installed"
  else
    fail "$bin install failed — try: npm i -g $npmpkg  (details: $LOG)"
  fi
done

# 5b. A Chrome/Chromium for marp + mmdc (both drive a headless browser).
if command -v marp >/dev/null || command -v mmdc >/dev/null; then
  browser=""
  for b in "${CHROME_PATH:-}" chromium chromium-browser google-chrome google-chrome-stable \
           "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
    [[ -z "$b" ]] && continue
    if command -v "$b" >/dev/null 2>&1 || [[ -x "$b" ]]; then browser="$b"; break; fi
  done
  if [[ -n "$browser" ]]; then
    ok "browser for export present ($browser)"
  elif [[ "$pm" == brew ]]; then
    pkg_install chromium chromium "--cask chromium" chromium || true
  else
    pkg_install chromium chromium chromium chromium \
      || miss "or: npx -y puppeteer browsers install chrome   (then set CHROME_PATH)"
  fi
fi

# 6. Optional vision pass: no install needed, it calls an OpenAI-compatible endpoint. Report
#    whether the configured one answers.
if [[ "${VISION:-0}" == "1" || -n "${VISION_MODEL:-}${VISION_PRESET:-}" ]]; then
  if ! vdesc="$(python3 "$SKILL_ROOT/scripts/vision_presets.py" describe 2>&1)"; then
    fail "vision preset: $vdesc"
  else
    vmodel="$(printf '%s' "$vdesc" | python3 -c 'import json,sys; print(json.load(sys.stdin)["model"])')"
    vmodels="$(printf '%s' "$vdesc" | python3 -c 'import json,sys; print(json.load(sys.stdin)["models_url"])')"
    if listing="$(curl -s --max-time 4 "$vmodels" 2>/dev/null)" && [[ -n "$listing" ]]; then
      if printf '%s' "$listing" | grep -qF "\"$vmodel\""; then
        ok "vision endpoint up and serving $vmodel ($vmodels)"
      else
        miss "vision endpoint up, but '$vmodel' is not in $vmodels — pull/load it or set VISION_MODEL to the served id"
      fi
    else
      miss "vision endpoint $vmodels not reachable — start the server; see references/vision-local-models.md"
    fi
  fi
else
  ok "vision pass off (default). Enable with --vision-model <preset> — see references/vision-local-models.md"
fi

if [[ "$FAILED" -eq 1 ]]; then
  echo "setup finished with problems (see ✗ lines above)."; exit 1
fi
echo "setup done. Next: scripts/drive_decks.sh <video-or-folder> --dry-run"
