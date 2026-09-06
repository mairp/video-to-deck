#!/usr/bin/env bash
# render_diagrams.sh <deck.md>
#
# Pre-render fenced ```mermaid / ```plantuml blocks in a Marp deck to images so they
# survive the Marp -> PPTX/PDF render (Marp does not execute Mermaid natively).
#
# For each block it:
#   - writes diagrams/dNN.(mmd|puml)
#   - renders diagrams/dNN.svg via mmdc (mermaid) or plantuml
#   - replaces the fenced block in the deck with  ![](diagrams/dNN.svg)
#
# If the renderer is missing, the fenced block is left untouched (it still renders in
# GitHub/VS Code Markdown preview). Idempotent-ish: writes deck.md in place, backup at
# deck.md.bak.
set -uo pipefail

deck="${1:?usage: render_diagrams.sh <deck.md>}"
[[ -f "$deck" ]] || { echo "render_diagrams.sh: no such file: $deck" >&2; exit 1; }
dir="$(cd "$(dirname "$deck")" && pwd)"
mkdir -p "$dir/diagrams"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared Midnight-dark Mermaid theme (see assets/design-tokens.md). Passed to `mmdc -c`.
theme="$SCRIPT_DIR/../assets/mermaid-theme.json"
[[ -f "$theme" ]] || theme=""

have_mmdc=0; command -v mmdc >/dev/null && have_mmdc=1
have_puml=0; command -v plantuml >/dev/null && have_puml=1

# mmdc drives headless Chrome; as root it needs --no-sandbox. Prefer a system browser
# (puppeteer's bundled download is version-pinned and flaky) via executablePath.
chrome_bin=""
for b in "${PUPPETEER_EXECUTABLE_PATH:-}" chromium chromium-browser google-chrome google-chrome-stable; do
  [[ -z "$b" ]] && continue
  p="$(command -v "$b" 2>/dev/null || true)"; [[ -x "${p:-$b}" ]] && { chrome_bin="${p:-$b}"; break; }
done
pconf="$dir/diagrams/.puppeteer.json"
if [[ -n "$chrome_bin" ]]; then
  printf '{"executablePath":"%s","args":["--no-sandbox","--disable-setuid-sandbox"]}' "$chrome_bin" > "$pconf"
else
  printf '{"args":["--no-sandbox","--disable-setuid-sandbox"]}' > "$pconf"
fi

DECK="$deck" DIR="$dir" PCONF="$pconf" THEME="$theme" HAVE_MMDC="$have_mmdc" HAVE_PUML="$have_puml" python3 - <<'PY'
import os, re, subprocess, sys

deck = os.environ["DECK"]; ddir = os.environ["DIR"]; pconf = os.environ["PCONF"]
theme = os.environ.get("THEME", "")
have_mmdc = os.environ["HAVE_MMDC"] == "1"
have_puml = os.environ["HAVE_PUML"] == "1"
src = open(deck, encoding="utf-8").read()

def diagram_type(body):
    for line in body.splitlines():
        s = line.strip()
        if s:
            return s.split()[0].lower()   # flowchart / statediagram-v2 / sequencediagram / ...
    return ""

def sanitize_mermaid(body):
    dtype = diagram_type(body)
    # The local model over-quotes state/sequence diagrams: quoted state IDs are a hard parse
    # error, quoted labels render as literal "…". Strip stray quotes for THOSE types only —
    # flowchart/graph quotes (A["x<br/>y"]) are structural and must stay.
    if dtype.startswith("statediagram") or dtype.startswith("sequencediagram"):
        body = body.replace('"', "")
    # `C{ "label" }` is a parse error but `C{"label"}` is fine: collapse whitespace directly
    # between a node bracket and its opening/closing quote (structural-safe for all types).
    body = re.sub(r'([\{\[\(])[ \t]+"', r'\1"', body)
    body = re.sub(r'"[ \t]+([\}\]\)])', r'"\1', body)
    return body

# Match fenced blocks: ```mermaid ... ``` or ```plantuml ... ```
pat = re.compile(r"```(mermaid|plantuml)[^\n]*\n(.*?)```", re.DOTALL)
n = 0
def render(m):
    global n
    lang, body = m.group(1), m.group(2)
    n += 1
    tag = f"d{n:02d}"
    if lang == "mermaid":
        body = sanitize_mermaid(body)
        srcfile = os.path.join(ddir, "diagrams", tag + ".mmd")
        out = os.path.join(ddir, "diagrams", tag + ".svg")
        open(srcfile, "w", encoding="utf-8").write(body)
        if have_mmdc:
            try:
                cmd = ["mmdc", "-i", srcfile, "-o", out, "-b", "transparent", "-p", pconf]
                if theme:
                    cmd += ["-c", theme]   # Midnight-dark palette (assets/mermaid-theme.json)
                subprocess.run(cmd, check=True, capture_output=True)
                print(f"render_diagrams: mermaid -> diagrams/{tag}.svg", file=sys.stderr)
                return f"![](diagrams/{tag}.svg)"   # width via injected fit CSS, not fixed
            except Exception as e:
                print(f"render_diagrams: mmdc failed for {tag}: {e}", file=sys.stderr)
        return m.group(0)  # leave fenced block as-is
    else:  # plantuml
        srcfile = os.path.join(ddir, "diagrams", tag + ".puml")
        body2 = body if "@startuml" in body else f"@startuml\n{body}\n@enduml\n"
        open(srcfile, "w", encoding="utf-8").write(body2)
        out = os.path.join(ddir, "diagrams", tag + ".svg")
        if have_puml:
            try:
                subprocess.run(["plantuml", "-tsvg", srcfile], check=True, capture_output=True)
                print(f"render_diagrams: plantuml -> diagrams/{tag}.svg", file=sys.stderr)
                return f"![](diagrams/{tag}.svg)"   # width via injected fit CSS, not fixed
            except Exception as e:
                print(f"render_diagrams: plantuml failed for {tag}: {e}", file=sys.stderr)
        return m.group(0)

new = pat.sub(render, src)
if new != src:
    # Diagram fences were swapped for images. The fit-to-slide <style> is injected by
    # render.sh (so it also covers decks with no diagrams) — not here, to avoid two blocks.
    open(deck + ".bak", "w", encoding="utf-8").write(src)
    open(deck, "w", encoding="utf-8").write(new)
    print(f"render_diagrams: rewrote {deck} ({n} diagram block(s)); backup at {deck}.bak", file=sys.stderr)
else:
    print("render_diagrams: no diagram blocks rendered (none found or renderer missing)", file=sys.stderr)
PY
