#!/usr/bin/env python3
"""
normalize_svg.py <file.svg> [file.svg ...]

Give a rendered diagram an explicit pixel size so it can only ever be scaled DOWN.

Why this exists
---------------
mermaid-cli emits `width="100%"` and no height, so inside an `<img>` the file has no
intrinsic size and the browser stretches it to whichever CSS constraint binds first.
A wide `flowchart LR` therefore hits max-width and lands in a compact band, while a tall
`flowchart TB` hits max-height and swells to fill most of the slide. The same deck ends up
with diagrams at wildly different visual weights — vertical ones look enormous next to
horizontal ones that look fine.

Setting width/height from the viewBox at

    scale = min(MAX_W / w, MAX_H / h, 1.0)

fixes both ends: nothing is ever upscaled past its natural size (so a small diagram stays
small instead of being blown up), and a tall diagram is capped by MAX_H rather than by the
slide height. Horizontal diagrams, already bounded by width, are left as they were.

The fit-to-slide CSS injected by render.sh still shrinks the image further when a
text-heavy slide leaves less room, so this never reintroduces overflow clipping.

Env:
  DIAGRAM_MAX_W   max rendered width in slide px  (default 1180; a 16:9 Marp slide is 1280 wide)
  DIAGRAM_MAX_H   max rendered height in slide px (default 400 of 720)

Idempotent: re-running on an already-normalized file is a no-op beyond rounding.
"""
import os
import re
import sys

SVG_TAG = re.compile(r"<svg\b[^>]*>", re.IGNORECASE)
VIEWBOX = re.compile(
    r'viewBox\s*=\s*"([-\d.eE]+)[ ,]+([-\d.eE]+)[ ,]+([\d.eE]+)[ ,]+([\d.eE]+)"',
    re.IGNORECASE,
)


def normalize(path, max_w=None, max_h=None, quiet=False):
    """Rewrite <svg>'s width/height from its viewBox. Returns True if it changed."""
    max_w = float(os.environ.get("DIAGRAM_MAX_W", "1180")) if max_w is None else max_w
    max_h = float(os.environ.get("DIAGRAM_MAX_H", "400")) if max_h is None else max_h
    try:
        svg = open(path, encoding="utf-8").read()
    except Exception as e:
        print(f"normalize_svg: cannot read {path}: {e}", file=sys.stderr)
        return False

    m = SVG_TAG.search(svg)
    if not m:
        return False
    tag = m.group(0)
    vb = VIEWBOX.search(tag)
    if not vb:
        # No viewBox means no reliable aspect ratio to scale from; leave it alone.
        return False
    w, h = float(vb.group(3)), float(vb.group(4))
    if w <= 0 or h <= 0:
        return False

    scale = min(max_w / w, max_h / h, 1.0)
    nw, nh = round(w * scale, 2), round(h * scale, 2)

    new = re.sub(r'\s(width|height)\s*=\s*"[^"]*"', "", tag, flags=re.IGNORECASE)
    # mermaid also sets an inline max-width at the natural width, which would fight the
    # size we just picked.
    new = re.sub(r'max-width\s*:\s*[^;"]+;?', "", new, flags=re.IGNORECASE)
    new = new[:-1].rstrip() + f' width="{nw}px" height="{nh}px">'

    if new == tag:
        return False
    open(path, "w", encoding="utf-8").write(svg.replace(tag, new, 1))
    if not quiet:
        print(f"normalize_svg: {os.path.basename(path)} {w:.0f}x{h:.0f} -> "
              f"{nw:.0f}x{nh:.0f} (scale {scale:.2f})", file=sys.stderr)
    return True


def main(argv):
    if not argv:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    for p in argv:
        normalize(p)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
