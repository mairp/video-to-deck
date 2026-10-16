# Changelog

## 1.1.0 — 2026-10-17

### Added
- **Local vision model presets** (`scripts/vision_presets.py`, `references/vision-models.json`,
  `references/vision-runtimes.json`, guide in `references/vision-local-models.md`). 16 current
  local vision models on 10 runtimes, selected with `--vision-model` / `--vision-runtime`
  (or `VISION_PRESET` / `VISION_RUNTIME`).
  - Models: Qwen3-VL, Qwen3.5/3.6/3.8, Qwen2.5-VL, Gemma 3/4, Ministral 3, MiniCPM-V 4.7,
    GLM-4.6V-Flash and Muse Glimmer.
  - Runtimes: llama.cpp, llama-swap, Ollama, vLLM, SGLang, LM Studio, MLX-VLM, LocalAI, Jan and
    KoboldCpp.
  - Each preset sets the served model id, endpoint, sampling, caption budget, frame size and
    image order, plus the per-runtime switch that turns off a thinking model's reasoning.
- Thinking-model hygiene. Captions are stripped of `<think>`, Gemma's thought channel and GLM's box
  tokens, and are never taken from reasoning fields. A reply that spent its whole budget thinking
  is retried once with a larger budget. A server that rejects the extra fields is retried once
  without them.
- `setup.sh --check` checks that the resolved model is actually served by the endpoint.

### Changed
- With no preset set, the request is byte-identical to 1.0.0.
- A vision reply with empty or list content no longer crashes the pass; empty replies now count
  as failed frames, so the circuit breaker sees them.

## 1.0.0 — 2026-10-17

### Added
- `setup.sh --check`: a read-only doctor. Setup now installs through Homebrew (macOS), apt or
  dnf, and logs to `.setup.log`.
- `--vision` flag. Vision is opt-in in `drive_decks.sh`.
- Circuit breaker on the vision pass (`VISION_MAX_FAILS`, default 3): a dead endpoint costs a
  few requests instead of a timeout on every frame.
- Offline test suite and CI on Ubuntu and macOS.
- `SECURITY.md`, `VERSION`, this changelog.

### Changed
- `--no-vision` always wins, even when `VISION_MODEL` is set in the environment or `local.env`.
- Background runs start in their own process group; the printed stop command kills children too.

### Fixed
- macOS: removed bash 4-only constructs (`mapfile`, associative arrays) and GNU-only `stat`.
- The batch authoring prompt and deck template now follow the density rules in SKILL.md.
- Re-runs no longer treat the pipeline's own working files under `decks/` as new inputs.
- Chromium's sandbox is disabled only when running as root.
- Export refuses absolute, `../` and `file://` image paths.
- Inline secrets in `--agent-cmd` are masked in the banner and kept out of log filenames.
- The deterministic fallback no longer hides its errors.
