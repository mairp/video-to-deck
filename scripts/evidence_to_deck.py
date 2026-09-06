#!/usr/bin/env python3
"""
evidence_to_deck.py <evidence.md> <out_dir> [--template <path>]

Generate a Marp deck (deck.md) from an evidence.md bundle produced by process_video.sh.
Rules:
- Do not invent facts; only use content present in evidence.md.
- Title slide uses the source filename and a one-line summary from the transcript's start.
- Topic slides are derived primarily from OCR keyframe blocks; each block becomes a slide:
  heading = first line of the OCR text, bullets = next few lines (<= 10 words each),
  and include the frame image.
- If no OCR, fall back to timestamped transcript segments to create a few slides.
- If a Visual descriptions section exists, add slides summarizing those captions with the image.
- Summary slide lists the first few topic headings (no extra conclusions).

Conservative by design — avoids speculative diagrams. If a caption strongly indicates a chart
or diagram, we still keep it as bullets + image to avoid fabrication.
"""
import os
import re
import sys
from typing import List, Tuple, Optional

MAX_BULLETS = 4
MAX_WORDS_PER_BULLET = 10


def read_text(path: str) -> str:
    with open(path, 'r', encoding='utf-8') as f:
        return f.read()


def trim_words(s: str, max_words: int) -> str:
    words = s.strip().split()
    if len(words) <= max_words:
        return s.strip()
    return ' '.join(words[:max_words]) + '…'


def parse_sections(evidence: str):
    # Find top-level sections by '## '
    sections = {}
    current = None
    lines = evidence.splitlines()
    header_title = None
    meta = {}
    for i, line in enumerate(lines):
        if i == 0 and line.startswith('# Evidence:'):
            header_title = line[len('# Evidence:'):].strip()
            continue
        if line.startswith('- **Source:**'):
            meta['source'] = re.sub(r'^- \*\*Source:\*\*\s*', '', line).strip('` ')
        elif line.startswith('- **Duration:**'):
            meta['duration'] = re.sub(r'^- \*\*Duration:\*\*\s*', '', line).strip()
        elif line.startswith('- **Resolution:**'):
            meta['resolution'] = re.sub(r'^- \*\*Resolution:\*\*\s*', '', line).strip()
        elif line.startswith('## '):
            current = line[3:].strip()
            sections[current] = []
        elif current is not None:
            sections[current].append(line)
    # Join section bodies
    for k in list(sections.keys()):
        sections[k] = '\n'.join(sections[k]).strip('\n')
    return header_title, meta, sections


def extract_transcript_snippet(sections: dict, max_chars: int = 140) -> str:
    txt = (sections.get('Full transcript') or '').strip()
    if not txt:
        return ''
    snippet = ' '.join(txt.split())
    if len(snippet) <= max_chars:
        return snippet
    return snippet[:max_chars].rsplit(' ', 1)[0] + '…'


def parse_ocr_blocks(ocr_md: str) -> List[Tuple[str, str, List[str]]]:
    """Return list of (hhmmss, frame_rel, lines[]) for each OCR block."""
    if not ocr_md:
        return []
    blocks = []
    cur_ts: Optional[str] = None
    cur_frame: Optional[str] = None
    cur_lines: List[str] = []
    # Split by headings that look like '### [HH:MM:SS] frames/kf_0001.jpg'
    for line in ocr_md.splitlines():
        m = re.match(r'^### \[(\d{2}:\d{2}:\d{2})\]\s+(.+)$', line.strip())
        if m:
            # flush previous
            if cur_ts is not None:
                blocks.append((cur_ts, cur_frame or '', [l for l in cur_lines if l.strip()]))
            cur_ts = m.group(1)
            # Remaining part often begins with 'frames/…'
            rest = m.group(2).strip()
            cur_frame = rest.split()[0] if rest else ''
            cur_lines = []
        else:
            if cur_ts is not None:
                cur_lines.append(line)
    if cur_ts is not None:
        blocks.append((cur_ts, cur_frame or '', [l for l in cur_lines if l.strip()]))
    return blocks


def parse_visual_captions(captions_md: str) -> List[Tuple[str, str, str]]:
    """Return list of (hhmmss, frame_rel, caption_text)."""
    if not captions_md:
        return []
    items = []
    cur_ts = None
    cur_frame = None
    cur_lines: List[str] = []
    for line in captions_md.splitlines():
        m = re.match(r'^### \[(\d{2}:\d{2}:\d{2})\]\s+([^\s]+)\s*$', line.strip())
        if m:
            if cur_ts is not None:
                items.append((cur_ts, cur_frame or '', ' '.join(' '.join(cur_lines).split())))
            cur_ts = m.group(1)
            cur_frame = m.group(2)
            cur_lines = []
        else:
            if cur_ts is not None:
                cur_lines.append(line.strip())
    if cur_ts is not None:
        items.append((cur_ts, cur_frame or '', ' '.join(' '.join(cur_lines).split())))
    return items


def bullets_from_lines(lines: List[str], max_bullets: int = MAX_BULLETS) -> List[str]:
    bullets = []
    for l in lines:
        t = l.strip()
        if not t:
            continue
        t = re.sub(r'\s+', ' ', t)
        bullets.append(trim_words(t, MAX_WORDS_PER_BULLET))
        if len(bullets) >= max_bullets:
            break
    return bullets


def build_deck(title: str, subtitle: str, meta: dict,
               ocr_blocks: List[Tuple[str, str, List[str]]],
               captions: List[Tuple[str, str, str]],
               segments_md: str,
               out_dir: str) -> str:
    slides: List[str] = []
    # Frontmatter + title slide
    fm = """---
marp: true
theme: midnight-dark
paginate: true
size: 16:9
---
"""
    slides.append(f"# {title}\n\n{subtitle}\n\n<!-- Source: {meta.get('source','?')} | Duration: {meta.get('duration','?')} -->")

    # Topic slides from OCR
    for ts, frame, lines in ocr_blocks:
        if not lines:
            continue
        heading = trim_words(lines[0], 16)
        bullets = bullets_from_lines(lines[1:])
        body = []
        body.append(f"## {heading}")
        for b in bullets:
            body.append(f"- {b}  <!-- [{ts}] -->")
        # Include image if exists
        if frame:
            # Use relative path from the deck location (same out_dir)
            body.append(f"\n![w:600]({frame})")
        slides.append('\n'.join(body))

    # Visual captions slides — add slides for any frames not already covered by OCR or to augment
    ocr_frames = {f for (_, f, _) in ocr_blocks if f}
    for ts, frame, cap in captions:
        # Skip if caption empty and also no OCR
        if not cap:
            continue
        # If OCR had a slide for this frame, add a separate slide to avoid merging heuristics
        heading = trim_words(cap, 12)
        bullets = bullets_from_lines([cap])
        body = []
        body.append(f"## Visual: {heading}")
        for b in bullets:
            body.append(f"- {b}  <!-- [{ts}] -->")
        if frame:
            body.append(f"\n![w:600]({frame})")
        slides.append('\n'.join(body))

    # Fallback: if no OCR-derived slides, use transcript segments to craft a few
    if not ocr_blocks:
        seg_lines = [l.strip() for l in (segments_md or '').splitlines() if l.strip().startswith('- [')]
        # Take up to 5 segments spaced evenly from the first 20
        chosen = seg_lines[:5]
        for ln in chosen:
            m = re.match(r'^- \[(\d{2}:\d{2}:\d{2})\] (.+)$', ln)
            if not m:
                continue
            ts, text = m.group(1), m.group(2)
            heading = trim_words(text, 12)
            bullets = [trim_words(text, MAX_WORDS_PER_BULLET)]
            body = []
            body.append(f"## {heading}")
            for b in bullets:
                body.append(f"- {b}  <!-- [{ts}] -->")
            slides.append('\n'.join(body))

    # Summary slide — list first few headings from OCR or segments
    summary_items: List[str] = []
    for ts, frame, lines in ocr_blocks[:3]:
        if lines:
            summary_items.append(trim_words(lines[0], 12))
    if not summary_items:
        # derive from segments
        seg_lines = [l.strip() for l in (segments_md or '').splitlines() if l.strip().startswith('- [')]
        for ln in seg_lines[:3]:
            m = re.match(r'^- \[(\d{2}:\d{2}:\d{2})\] (.+)$', ln)
            if m:
                summary_items.append(trim_words(m.group(2), 12))
    if not summary_items:
        summary_items = ['Auto-generated from transcript/OCR']
    sum_slide = ['## Summary'] + [f"- {it}" for it in summary_items]
    slides.append('\n'.join(sum_slide))

    # Join with slide separators
    deck = fm + '\n\n---\n\n'.join(slides) + '\n'
    return deck


def main():
    if len(sys.argv) < 3:
        print('usage: evidence_to_deck.py <evidence.md> <out_dir> [--template <path>]', file=sys.stderr)
        sys.exit(2)
    ev_path = sys.argv[1]
    out_dir = sys.argv[2]
    if not os.path.isfile(ev_path):
        print(f'evidence_to_deck.py: no such file: {ev_path}', file=sys.stderr)
        sys.exit(1)
    os.makedirs(out_dir, exist_ok=True)

    ev = read_text(ev_path)
    title_file, meta, sections = parse_sections(ev)
    title = os.path.splitext(os.path.basename(meta.get('source', title_file or 'Presentation')))[0]
    subtitle = extract_transcript_snippet(sections) or 'Auto-generated deck from transcript/OCR'

    ocr_blocks = parse_ocr_blocks(sections.get('On-screen text (OCR of keyframes)', ''))
    captions = parse_visual_captions(sections.get('Visual descriptions (vision model: qwen2.5-vl)', '') or sections.get('Visual descriptions', ''))
    segments_md = sections.get('Timestamped transcript segments', '')

    deck = build_deck(title, subtitle, meta, ocr_blocks, captions, segments_md, out_dir)
    out_path = os.path.join(out_dir, 'deck.md')
    with open(out_path, 'w', encoding='utf-8') as f:
        f.write(deck)
    print(f'deck: wrote {out_path}')


if __name__ == '__main__':
    main()
