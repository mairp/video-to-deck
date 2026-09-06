#!/usr/bin/env python3
"""
dedupe_slides.py <out_dir>

Collapse the per-frame OCR in <out_dir>/frames_ocr.tsv into one block per SLIDE and write:
  <out_dir>/ocr.txt          one block per slide run: time span + union of its OCR lines
  <out_dir>/kept_frames.tsv  ts<TAB>frames/kf_####.jpg — ONE representative frame per run

Why this exists
---------------
The original dedup compared consecutive frames for an EXACT OCR match. That never fires on a
screen recording: burned-in subtitles and a moving player timecode change every frame, so a
38-minute talk kept all 115 frames — 115 near-identical blocks that bury the ~50 real slides,
and 115 vision-model calls instead of ~50.

Two changes fix it:
  1. Compare word SETS (Jaccard), not strings. Tesseract garbles the same slide differently on
     every frame ("vLLM Semantic Router" / "vL-LM Semantic Router" / "vi Semantic Router"), so
     string similarity stays low even for an identical slide. A set of >=4-letter words is
     robust to that and to the changing subtitle line.
  2. Emit the UNION of every frame's OCR lines across the run, not one frame's text. Each frame
     garbles a different subset of the slide, so the union recovers more of the real slide text
     than any single frame does. This is what makes the evidence bundle denser, not thinner.

Env:
  OCR_DEDUP   Jaccard threshold in [0,1]. Default 0.55. Frames scoring >= this against the
              running slide are folded into it. 0 disables dedup (one block per frame).

Cheap and idempotent: re-run it to re-tune the threshold without re-running tesseract.
"""
import os
import re
import sys

CHROME = re.compile(r"(prev\s*=?\s*auto\s*next|youtube|full screen|watch later|"
                    r"is now full screen|exit full screen)", re.I)
WORD = re.compile(r"[a-z]{4,}")


def unescape(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            nxt = s[i + 1]
            if nxt == "n":
                out.append("\n"); i += 2; continue
            if nxt == "\\":
                out.append("\\"); i += 2; continue
        out.append(s[i]); i += 1
    return "".join(out)


def hhmmss(sec):
    sec = int(sec)
    return f"{sec // 3600:02d}:{(sec % 3600) // 60:02d}:{sec % 60:02d}"


def words(text):
    """Word set used only for comparison — player chrome dropped, digits ignored."""
    s = set()
    for ln in text.splitlines():
        if CHROME.search(ln):
            continue
        s.update(WORD.findall(ln.lower()))
    return s


def jaccard(a, b):
    return len(a & b) / len(a | b) if a and b else 0.0


def norm_line(ln):
    """Key for line-level dedup within a run: case/space/punctuation-insensitive."""
    return re.sub(r"[^a-z0-9]+", "", ln.lower())


def main():
    if len(sys.argv) < 2:
        print("usage: dedupe_slides.py <out_dir>", file=sys.stderr)
        sys.exit(1)
    out_dir = sys.argv[1]
    raw_path = os.path.join(out_dir, "frames_ocr.tsv")
    if not os.path.isfile(raw_path):
        print(f"dedupe_slides.py: no {raw_path} — nothing to do", file=sys.stderr)
        sys.exit(0)

    try:
        thr = float(os.environ.get("OCR_DEDUP", "0.55"))
    except ValueError:
        thr = 0.55
    thr = max(0.0, min(1.0, thr))

    frames = []
    with open(raw_path, encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 4:
                continue
            _idx, ts, rel, text = parts[0], parts[1], parts[2], unescape(parts[3])
            if not text.strip():
                continue                       # blank frame
            frames.append((int(ts), rel, text))

    if not frames:
        open(os.path.join(out_dir, "ocr.txt"), "w").close()
        open(os.path.join(out_dir, "kept_frames.tsv"), "w").close()
        print("dedupe_slides.py: no non-blank frames", file=sys.stderr)
        return

    # --- group consecutive frames into slide runs -------------------------------
    runs = []          # each: {"frames": [(ts, rel, text)], "wordset": set}
    for ts, rel, text in frames:
        w = words(text)
        if thr > 0 and runs and jaccard(runs[-1]["wordset"], w) >= thr:
            runs[-1]["frames"].append((ts, rel, text))
            runs[-1]["wordset"] |= w           # accumulate: a slide read twice is still one slide
        else:
            runs.append({"frames": [(ts, rel, text)], "wordset": w})

    # --- emit ------------------------------------------------------------------
    ocr_path = os.path.join(out_dir, "ocr.txt")
    kept_path = os.path.join(out_dir, "kept_frames.tsv")
    with open(ocr_path, "w", encoding="utf-8") as ocr, \
            open(kept_path, "w", encoding="utf-8") as kept:
        for run in runs:
            fr = run["frames"]
            start, end = fr[0][0], fr[-1][0]
            # Representative = the frame whose OCR captured the most text; that is also the
            # frame worth spending a vision-model call on.
            rep_ts, rep_rel, _ = max(fr, key=lambda x: len(x[2]))

            # Union of lines across the run, first-seen order, chrome dropped.
            seen, lines = set(), []
            for _ts, _rel, text in fr:
                for ln in text.splitlines():
                    ln = ln.rstrip()
                    if not ln.strip() or CHROME.search(ln):
                        continue
                    key = norm_line(ln)
                    if len(key) < 3 or key in seen:
                        continue
                    seen.add(key)
                    lines.append(ln)
            if not lines:
                continue

            span = hhmmss(start) if start == end else f"{hhmmss(start)}-{hhmmss(end)}"
            ocr.write(f"### [{span}] {rep_rel} ({len(fr)} frame"
                      f"{'s' if len(fr) != 1 else ''})\n")
            ocr.write("\n".join(lines) + "\n\n")
            kept.write(f"{rep_ts}\t{rep_rel}\n")

    print(f"dedupe_slides.py: {len(frames)} frames -> {len(runs)} slide runs "
          f"(OCR_DEDUP={thr}); wrote ocr.txt + kept_frames.tsv", file=sys.stderr)


if __name__ == "__main__":
    main()
