# Changelog

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
