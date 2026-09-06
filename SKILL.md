---
name: video-to-deck
description: >
  Turn a video (or a whole folder of videos: .mkv .mp4 .mov .webm .avi …) into a
  presentation. Transcribes the audio and reads on-screen text, then writes a Marp
  slide deck as Markdown (deck.md) that also exports to PPTX/PDF. Detects structural
  content (architecture, call flows, state machines, data models) and draws it as a
  Mermaid/UML diagram instead of bullets. Use when asked to "make a presentation/slides
  from a video", "summarize/transcribe a recording into a deck", or "turn these videos
  into slides".
---

# video-to-deck

Make a presentation from video. You (the model) are **text-only** — you cannot hear audio
or see frames. So this skill's **scripts do the seeing and hearing** and hand you a text
**evidence bundle** (`evidence.md`). Your job is **synthesis only**: read the evidence and
write a good deck. Do not invent anything the evidence doesn't support.

Output is **Marp markdown** (`deck.md`): a normal `.md` you can read now, and a real slide
deck (PPTX/PDF/HTML) via one `render.sh` command later.

`$SKILL` below = this skill's directory (the folder containing this file).

## Procedure

### 1. One-time setup (idempotent)
```bash
bash "$SKILL/scripts/setup.sh"
```
Installs faster-whisper (transcription), tesseract (OCR), and — if `npm` is present —
marp-cli and mermaid-cli. Safe to re-run. ffmpeg must already be installed.

### 2. Find the videos
```bash
bash "$SKILL/scripts/find_videos.sh" "<folder>"        # one path per line, recursive
```
For a single named file, skip this and use the path directly.

### 3. Build the evidence bundle for each video (one at a time)
```bash
bash "$SKILL/scripts/process_video.sh" "<video>" "<out_dir>/<video-stem>"
```
This extracts audio → transcribes it, samples keyframes → OCRs on-screen text, and writes
`<out_dir>/<video-stem>/evidence.md` (plus `transcript.txt`, `segments.tsv`, `frames/`,
`ocr.txt`). Long videos on CPU are slow; set `WHISPER_MODEL=small` for quality, or use a CUDA GPU for
speed (auto-detected; see `WHISPER_DEVICE` in `scripts/transcribe.py`). Process videos
sequentially, not in parallel.

**Optional vision pass (Qwen-VL).** OCR only reads *text*. To also capture what text can't —
charts and their trend, diagrams, UI layout, a speaker's gesture — enable a vision model that
captions each kept keyframe. It's **off by default**; turn it on by setting `VISION_MODEL`
(and, if needed, `VISION_ENDPOINT`) in the environment of the same command:
```bash
VISION_MODEL=qwen2.5-vl \
VISION_ENDPOINT=http://127.0.0.1:8081/v1/chat/completions \
  bash "$SKILL/scripts/process_video.sh" "<video>" "<out_dir>/<video-stem>"
```
When on, `evidence.md` gains a **"## Visual descriptions"** section alongside the OCR — use it
for chart/diagram slides. Any OpenAI-compatible vision endpoint works (llama-swap once a
local server such as llama.cpp/llama-swap or Ollama, or a hosted API; `VISION_API_KEY` if it
needs a token). If the endpoint is unreachable the run continues with OCR only — nothing breaks.

### 4. Write the deck
Read the whole `evidence.md`. Copy `"$SKILL/templates/deck.marp.md"` to `<out_dir>/<video-stem>/deck.md`
and fill it in. Rules:
- **Keep the `marp: true` frontmatter** — that's what makes it a slide deck.
- Use the **transcript** for what was said; use the **OCR / on-screen text** for exact
  labels, numbers, titles, and code shown on slides; if a **"Visual descriptions"** section is
  present (vision pass was enabled), use it for charts/diagrams/UI that OCR can't convey.
- Tag a claim with its moment when useful: `[00:04:12]`.
- **Put the slide's keyframe on the slide — this is the DEFAULT, not an optional garnish.**
  Every `### [timespan] frames/kf_####.jpg` block in `ocr.txt` names the representative frame
  for that slide; carry it onto the deck slide it became: `![](frames/kf_0007.jpg)`. The
  keyframe is the evidence for the slide, it shows the diagram/chart/UI that bullets can only
  describe, and it makes the deck mirror the source presentation. Omit it only when the slide
  is a pure diagram slide you redrew in Mermaid, or when the frame carries no visual signal
  (a talking head, a blank transition). When two deck slides come from one source slide, use
  two different frames from that slide's run rather than repeating one.
- Only include what the evidence supports. If transcript **and** OCR are empty, say the
  video had no extractable content rather than inventing a deck.

**Density — the deck must CONSOLIDATE the evidence, not summarize it away.** The most common
failure is a thin deck: 20 slides of four-word bullets that throw away most of what the video
actually contained. The evidence bundle is expensive to build; the deck is what people read.
- **One deck slide per source slide.** Each `### [timespan] frames/…` block in the OCR section
  is one real slide from the video — that list is your checklist and roughly your slide count.
  Do not merge three source slides into one bullet. A 40-minute talk is normally 30-45 slides.
- **Carry the specifics onto the slide.** Every number, metric, threshold, percentage, product
  name, CRD, config key, and label present in the evidence belongs on the slide itself. If the
  source slide had six bullets and four statistics, your slide has six bullets and four
  statistics — not "improved accuracy".
- **Bullets are a full line (~15-20 words), not four words.** 5-8 per slide is normal. Terse
  is only correct when the source was terse.
- **Use a table whenever the source is tabular** — routing matrices, benchmark grids, level
  definitions, priority rules. Reproduce every row and column, not a sample.
- **Speaker notes are additive**, for what was *said* that is not on the slide: caveats, war
  stories, the "why", Q&A detail. They are not the place to hide content that belongs on the
  slide.
- **Coverage check before you finish.** Walk the `### [..]` blocks in `ocr.txt` in order and
  confirm each one is represented. If you skipped a block, either it was a duplicate/animation
  of the previous slide or a demo frame — be able to say which.

### 5. Diagram pass (the "can this be a diagram?" check)
For each topic, ask: is this **structural** (components + connections, actor interactions,
a process/flow, states + transitions, entities + relations)? If yes, draw it as a **Mermaid**
(default) or **PlantUML** diagram on its own slide **instead of** bullets. Consult
`"$SKILL/references/diagrams-cheatsheet.md"` for the content→type decision table and
copy-paste skeletons. **Do not force a diagram** where the content is just narrative.

### 6. (Optional) Export the real slide deck
```bash
bash "$SKILL/scripts/render.sh" "<out_dir>/<video-stem>/deck.md" pptx   # or pdf | html | all
```
This pre-renders diagram blocks to images, then produces the PPTX/PDF. If marp/mermaid
aren't installed the deck simply stays as `.md` (still valid and viewable).

For a whole tree at once, add `--pdf` to the batch driver (below) instead of calling
`render.sh` per deck.

## Batch / nested folders
For a whole folder — especially a **nested course tree** — prefer `scripts/drive_decks.sh <root>`:
it loops in bash and spawns a fresh agent per video (never overflows the model's context) and
**mirrors the source subfolders** into the output, so the parent→child hierarchy is preserved.
`scripts/rename_by_topic.sh <decks>` then slugifies each leaf by its topic *within its course
folder*. Add **`--pdf`** to export every deck to PDF once authoring finishes — Mermaid is
pre-rendered to images, and the **leaf folder is collapsed** so each PDF lands in its *parent*
(`<out>/CourseA/lesson/deck.md → <out>/CourseA/lesson.pdf`), avoiding a subfolder per PDF.
To rebuild the hierarchy of decks that were produced **flat** by an older run, use
`scripts/regroup_by_source.sh <decks>` — it reads each `evidence.md`'s `Source:` line to place
every deck under its course parent (dupes quarantined to `_duplicates/`), then run the rename.
See `README.md` for the full batch guide.

## References
- `references/marp-cheatsheet.md` — Marp slide syntax (separators, images, notes, columns).
- `references/diagrams-cheatsheet.md` — when to draw a diagram and the syntax for each type.

## Notes
- OCR captures on-screen text well for screencasts/slide videos. For live-action footage the
  transcript carries most of the signal — lean on it and don't over-claim about visuals.
- Transcription, OCR and rendering are always local. Whether the authoring step leaves the
  machine is entirely up to the agent you point `--agent-cmd` at.
- The design is model-agnostic: any text agent that can run bash and read files can use this
  skill.
