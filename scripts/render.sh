#!/usr/bin/env bash
# render.sh <deck.md> [pptx|pdf|html|all]
#
# Turn a Marp markdown deck into a real slide deck. Pre-renders diagram blocks first
# (so Mermaid/PlantUML show up as images), then invokes marp-cli.
#
# Default format: pptx. Use "all" for pptx+pdf+html.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deck="${1:?usage: render.sh <deck.md> [pptx|pdf|html|all]}"
fmt="${2:-pptx}"
[[ -f "$deck" ]] || { echo "render.sh: no such file: $deck" >&2; exit 1; }

# 1. Pre-render diagrams (best-effort; no-op if none / renderer missing).
bash "$SCRIPT_DIR/render_diagrams.sh" "$deck" || true

# 1b. Inject fit-to-slide CSS so nothing is clipped on the fixed, non-scrolling slide:
# images share the vertical space LEFT OVER by the text rather than claiming a fixed
# fraction of the slide, 2 stacked images split that leftover, inline ![w:NNN] widths are
# neutralized, 2 side-by-side images stay on one row, and the body font shrinks a touch.
# IMAGE_MAX_VH is only an upper bound -- the binding constraint is the remaining space, so a
# text-heavy slide can no longer push its image off the bottom of the page. Versioned via the
# /* diagram-fit vN */ marker: an older block is REPLACED, so re-rendering an existing deck
# picks up this fix (render_diagrams.sh no longer injects its own). Applies to EVERY deck,
# including plain keyframe decks with no diagrams.
IMAGE_MAX_VH="${IMAGE_MAX_VH:-40}" SLIDE_FONT_PX="${SLIDE_FONT_PX:-20}" \
DECK="$deck" python3 - <<'PY' || true
import os, re, sys
MARKER = "/* diagram-fit v2 */"
deck = os.environ["DECK"]
imgvh = os.environ.get("IMAGE_MAX_VH", "40")
fontpx = os.environ.get("SLIDE_FONT_PX", "20")
src = open(deck, encoding="utf-8").read()
if MARKER not in src:
    font_size = ("font-size: %spx; " % fontpx) if fontpx.strip() else ""
    fit_css = ("\n<style>\n" + MARKER + "\n"
               "section { %sdisplay: flex; flex-direction: column; justify-content: flex-start; gap: 1px; }\n"
               "section > * { flex: 0 0 auto; }\n"
               "section p:has(img) { flex: 1 1 0; min-height: 0; text-align: center; margin: 2px 0; }\n"
               "section img { width: auto !important; max-width: 100%%; max-height: min(%svh, 100%%);"
               " height: auto; object-fit: contain; min-height: 0; vertical-align: top; }\n"
               "section p img ~ img { max-width: 47%%; }\n"
               "section ul, section ol { margin: 1px 0; }\n"
               "section li { margin: 1px 0; }\n"
               "section p { margin: 3px 0; }\n"
               "</style>\n" % (font_size, imgvh))
    # Drop a previous-generation block so the fix also lands on already-rendered decks.
    old = re.compile(r"\n?<style>\s*\n/\* diagram-fit.*?</style>\n?", re.DOTALL)
    upgraded = bool(old.search(src))
    src = old.sub("\n", src, count=1)
    fm = re.match(r"^(---\n.*?\n---\n)", src, re.DOTALL)
    src = (src[:fm.end()] + fit_css + src[fm.end():]) if fm else (fit_css + src)
    open(deck, "w", encoding="utf-8").write(src)
    sys.stderr.write("render.sh: %s fit-to-slide CSS\n" % ("upgraded" if upgraded else "injected"))
PY

# 2. marp-cli must be present for the deck export.
if ! command -v marp >/dev/null; then
  echo "render.sh: marp-cli not installed — deck stays as Markdown ($deck)." >&2
  echo "           Install: npm i -g @marp-team/marp-cli   (then re-run)." >&2
  exit 2
fi

# marp's PPTX/PDF export drives a browser too. Point it at a system browser. marp-cli
# auto-disables the Chrome sandbox when it detects it runs as root.
bpath=""
for b in "${CHROME_PATH:-}" chromium chromium-browser google-chrome google-chrome-stable; do
  [[ -z "$b" ]] && continue
  p="$(command -v "$b" 2>/dev/null || true)"; [[ -n "${p:-}" ]] && { bpath="$p"; break; }
  [[ -x "$b" ]] && { bpath="$b"; break; }
done
bpath_args=(); [[ -n "$bpath" ]] && bpath_args=(--browser-path "$bpath")

# Midnight-dark Marp theme (assets/theme-midnight-dark.css). Use single-valued --theme (which
# accepts a CSS file path and applies it to every slide) — NOT --theme-set, whose [array]
# value greedily swallows the deck path and breaks the invocation.
theme_css="$SCRIPT_DIR/../assets/theme-midnight-dark.css"
theme_args=(); [[ -f "$theme_css" ]] && theme_args=(--theme "$theme_css")

stem="${deck%.md}"
run() {
  echo "render.sh: marp -> $1 (browser=${bpath:-auto})" >&2
  marp --allow-local-files --browser-timeout 60 "${bpath_args[@]}" "${theme_args[@]}" "$deck" -o "$1" </dev/null
}

case "$fmt" in
  pptx) run "$stem.pptx" ;;
  pdf)  run "$stem.pdf" ;;
  html) run "$stem.html" ;;
  all)  run "$stem.pptx"; run "$stem.pdf"; run "$stem.html" ;;
  *) echo "render.sh: unknown format '$fmt' (use pptx|pdf|html|all)" >&2; exit 1 ;;
esac
echo "render.sh: done." >&2
