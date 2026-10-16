#!/usr/bin/env bash
# restyle_diagrams.sh <root> [--dry-run]
#
# Re-render every already-generated Mermaid source (diagrams/*.mmd) under <root> with the
# current Midnight-dark theme (assets/mermaid-theme.json). Use this to restyle existing decks
# after a theme change — the deck .md files already reference diagrams/dNN.svg, so only the
# SVGs need regenerating; the decks are untouched.
#
# Idempotent: overwrites each dNN.svg in place. Logs a summary and any render failures.
set -uo pipefail

root="${1:?usage: restyle_diagrams.sh <root> [--dry-run]}"
dry=0; [[ "${2:-}" == "--dry-run" ]] && dry=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
theme="$SCRIPT_DIR/../assets/mermaid-theme.json"
[[ -f "$theme" ]] || { echo "restyle: missing theme $theme" >&2; exit 1; }
command -v mmdc >/dev/null || { echo "restyle: mmdc not installed" >&2; exit 1; }

# Prefer a system Chrome/Chromium for mmdc's headless render (bundled download is flaky).
chrome_bin=""
for b in "${PUPPETEER_EXECUTABLE_PATH:-}" chromium chromium-browser google-chrome google-chrome-stable "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
  [[ -z "$b" ]] && continue
  p="$(command -v "$b" 2>/dev/null || true)"; [[ -x "${p:-$b}" ]] && { chrome_bin="${p:-$b}"; break; }
done

ok=0; fail=0; total=0
while IFS= read -r -d '' mmd; do
  total=$((total+1))
  dir="$(dirname "$mmd")"
  out="${mmd%.mmd}.svg"
  # Chrome refuses to start sandboxed as root; only then (or V2D_NO_SANDBOX=1) drop the sandbox.
  sandbox_args=""; [[ "$(id -u)" == 0 || "${V2D_NO_SANDBOX:-0}" == 1 ]] && sandbox_args='"--no-sandbox","--disable-setuid-sandbox"'
  pconf="$dir/.puppeteer.json"
  if [[ ! -f "$pconf" ]]; then
    if [[ -n "$chrome_bin" ]]; then
      printf '{"executablePath":"%s","args":[%s]}' "$chrome_bin" "$sandbox_args" > "$pconf"
    else
      printf '{"args":[%s]}' "$sandbox_args" > "$pconf"
    fi
  fi
  if [[ $dry -eq 1 ]]; then
    echo "would restyle: $out"
    continue
  fi
  if mmdc -i "$mmd" -o "$out" -b transparent -c "$theme" -p "$pconf" >/dev/null 2>/tmp/restyle_err; then
    ok=$((ok+1))
  else
    fail=$((fail+1))
    echo "restyle: FAILED $mmd" >&2
    sed 's/^/    /' /tmp/restyle_err >&2
  fi
done < <(find "$root" -type f -name '*.mmd' -print0)

echo "restyle: $ok/$total re-rendered, $fail failed."
[[ $fail -eq 0 ]]
