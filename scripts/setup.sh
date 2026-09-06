#!/usr/bin/env bash
# setup.sh — idempotent bootstrap of the tools video-to-deck needs.
# Safe to run repeatedly. Prints what it installed vs. what was already present.
set -uo pipefail

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
miss() { printf '  \033[33m…\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; }

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$SKILL_ROOT/.venv"

echo "video-to-deck setup:"

# 1. ffmpeg/ffprobe — REQUIRED (media extraction). We don't auto-install to avoid
#    surprising apt changes on a working host; just report clearly.
if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null; then
  ok "ffmpeg/ffprobe present"
else
  fail "ffmpeg/ffprobe MISSING — install: sudo apt-get install -y ffmpeg"
fi

# 2. faster-whisper — REQUIRED (transcription). Installed into a dedicated venv so we
#    don't fight PEP-668 externally-managed system Python. transcribe.py uses this venv.
if [[ -x "$VENV/bin/python" ]] && "$VENV/bin/python" -c "import faster_whisper" 2>/dev/null; then
  ok "faster-whisper present (venv)"
else
  miss "creating venv + installing faster-whisper…"
  if [[ ! -x "$VENV/bin/python" ]]; then
    python3 -m venv "$VENV" 2>/dev/null || python3 -m venv --system-site-packages "$VENV" 2>/dev/null
  fi
  if [[ -x "$VENV/bin/pip" ]] && "$VENV/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1 \
     && "$VENV/bin/pip" install --quiet faster-whisper >/dev/null 2>&1; then
    ok "faster-whisper installed (venv: .venv)"
  elif pip install --quiet --break-system-packages faster-whisper >/dev/null 2>&1; then
    ok "faster-whisper installed (system, --break-system-packages)"
  else
    fail "faster-whisper install failed — try: python3 -m venv .venv && .venv/bin/pip install faster-whisper"
  fi
fi

# 2b. CUDA runtime libs for CTranslate2 — the difference between GPU and CPU transcription.
#     CTranslate2 dlopen()s libcublas.so.12 + libcudnn.so.9. Without them it still reports a
#     CUDA device, then fails building the model and transcribe.py falls back to cpu/int8 —
#     4x slower on a machine with a perfectly good GPU. Install as pip wheels (no system CUDA
#     needed); transcribe.py puts site-packages/nvidia/*/lib on the loader path itself.
#     Skipped entirely on hosts with no NVIDIA driver.
if [[ -x "$VENV/bin/python" ]] && command -v nvidia-smi >/dev/null 2>&1; then
  if "$VENV/bin/python" -c "import nvidia.cublas, nvidia.cudnn" 2>/dev/null; then
    ok "CUDA libs for CTranslate2 present (GPU transcription)"
  else
    miss "installing nvidia-cublas-cu12 + nvidia-cudnn-cu12 (GPU transcription)…"
    if "$VENV/bin/pip" install --quiet nvidia-cublas-cu12 nvidia-cudnn-cu12 >/dev/null 2>&1; then
      ok "CUDA libs installed — transcription will use the GPU"
    else
      fail "CUDA lib install failed — transcription will run on CPU (~4x slower, still correct)"
    fi
  fi
fi

# 3. tesseract — RECOMMENDED (OCR of on-screen text). Skill degrades gracefully without it.
if command -v tesseract >/dev/null; then
  ok "tesseract present"
else
  miss "installing tesseract-ocr (apt)…"
  if sudo apt-get install -y -q tesseract-ocr >/dev/null 2>&1 || apt-get install -y -q tesseract-ocr >/dev/null 2>&1; then
    ok "tesseract installed"
  else
    fail "tesseract install failed (OCR will be skipped) — try: sudo apt-get install -y tesseract-ocr"
  fi
fi

# 4. marp-cli — OPTIONAL (render deck.md -> pptx/pdf/html). Only needed for the deck export.
if command -v marp >/dev/null; then
  ok "marp-cli present"
elif command -v npm >/dev/null; then
  miss "installing @marp-team/marp-cli (npm -g)…"
  if npm install -g @marp-team/marp-cli >/dev/null 2>&1; then
    ok "marp-cli installed"
  else
    fail "marp-cli install failed — deck stays as .md (still fine). Try: npm i -g @marp-team/marp-cli"
  fi
else
  miss "npm not found — skipping marp-cli. deck.md still renders in any Markdown viewer."
fi

# 5. mermaid-cli (mmdc) — OPTIONAL (pre-render diagram blocks to images for the deck).
#    mmdc drives headless Chrome via puppeteer, so we also need a Chrome binary.
if command -v mmdc >/dev/null; then
  ok "mermaid-cli (mmdc) present"
elif command -v npm >/dev/null; then
  miss "installing @mermaid-js/mermaid-cli (npm -g)…"
  if npm install -g @mermaid-js/mermaid-cli >/dev/null 2>&1; then
    ok "mermaid-cli installed"
  else
    fail "mermaid-cli install failed — diagrams stay as fenced blocks (render in .md viewers)."
  fi
else
  miss "npm not found — skipping mermaid-cli. Mermaid blocks still render in GitHub/VS Code."
fi
# 5b. A Chrome/Chromium binary for mmdc (puppeteer). render_diagrams.sh points puppeteer
#     at a SYSTEM browser via executablePath (more reliable than puppeteer's pinned download).
if command -v mmdc >/dev/null; then
  browser=""
  for b in chromium chromium-browser google-chrome google-chrome-stable; do
    command -v "$b" >/dev/null && { browser="$b"; break; }
  done
  if [[ -n "$browser" ]]; then
    ok "browser for mmdc present ($browser)"
  else
    miss "installing chromium (apt) for mmdc…"
    if sudo apt-get install -y -q chromium >/dev/null 2>&1 || apt-get install -y -q chromium >/dev/null 2>&1 \
       || npx -y puppeteer browsers install chrome >/dev/null 2>&1; then
      ok "browser for mmdc installed"
    else
      fail "no browser for mmdc — diagrams stay as fenced blocks (still render in .md viewers)."
    fi
  fi
fi

# 6. Optional vision pass (Qwen-VL). No install needed — it calls a remote OpenAI-compatible
#    endpoint. Just report whether one looks configured/reachable.
if [[ "${VISION:-0}" == "1" || -n "${VISION_MODEL:-}" ]]; then
  vurl="${VISION_ENDPOINT:-http://127.0.0.1:8081/v1/chat/completions}"
  base="${vurl%/chat/completions}"
  if curl -s --max-time 4 "${base}/models" >/dev/null 2>&1; then
    ok "vision endpoint reachable (${VISION_MODEL:-qwen2.5-vl} @ $vurl)"
  else
    miss "vision requested but $vurl not reachable — see references/vision-qwen-vl.md to serve Qwen-VL."
  fi
else
  miss "vision pass OFF (default). Enable with VISION_MODEL=… — see references/vision-qwen-vl.md."
fi

echo "setup done. (PlantUML users: install 'plantuml' via apt/brew for optional PlantUML diagrams.)"
