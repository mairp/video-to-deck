# video-to-deck

Turn a video — or a whole folder of them (`.mkv .mp4 .mov .webm .avi …`, recursed) — into a
**Marp slide deck** you can read as Markdown and export to **PPTX / PDF / HTML**.

The pipeline does the seeing and hearing, so the model doesn't have to: it transcribes the
audio, samples and OCRs keyframes, optionally captions them with a vision model, and hands the
authoring agent one plain-text **evidence bundle** per video. The agent's only job is synthesis.

Structural content (architecture, call flows, state machines, data models) is drawn as a
**Mermaid diagram** instead of being flattened into bullets.

```
video ──▶ ffmpeg ──▶ whisper ──▶ transcript.txt + segments.tsv ─┐
      └─▶ keyframes ──▶ tesseract OCR ──▶ ocr.txt ──────────────┼──▶ evidence.md ──▶ agent ──▶ deck.md ──▶ PDF/PPTX
                    └─▶ vision captions (optional) ────────────┘
```

## Why the shell owns the loop

`drive_decks.sh` is the batch driver, and **the shell drives it, not the model**. It spawns a
**fresh agent process per video**, so each agent only ever sees one `evidence.md`. That means it
can't overflow a small context window, can't "forget to iterate", can't background-and-quit the
batch, and a single bad video can't kill the run. Resumption is a plain file test on `deck.md`.

A model-orchestrated loop reliably quits after about one video. This is why that approach isn't
used here.

## Install

```bash
git clone https://github.com/mairp/video-to-deck
cd video-to-deck
bash scripts/setup.sh          # whisper venv, tesseract, marp-cli, mermaid-cli
```

`ffmpeg` must already be on the system. `setup.sh` is idempotent — re-run it any time. If `npm`
is missing it skips marp/mermaid and decks simply stay as valid Markdown.

## Quick start

```bash
# one video
scripts/drive_decks.sh talk.mkv --agent-cmd "claude -p"

# a whole tree, detached and logged
scripts/drive_decks.sh /path/to/videos --agent-cmd "claude -p" --background
```

Decks land at `<folder>/decks/<video-stem>/deck.md`, mirroring the source subfolders. Launching
prints the **pid**, the **logfile**, and a ready-to-paste `tail -f`. Preview without running
anything with `--dry-run`.

## Choosing an agent

Any CLI that accepts a prompt and can write files works. The prompt is appended as the final
argument, unless the command contains the literal `{prompt}`, which is substituted instead.

```bash
--agent-cmd "claude -p"                  # default
--agent-cmd "ollama run qwen3"           # fully local
--agent-cmd "llm -m gpt-4o-mini"         # simonw/llm
--agent-cmd "my-agent --input {prompt}"  # explicit placement
```

Set it once in `local.env` (gitignored — copy `local.env.example`) or export `V2D_AGENT_CMD`.

If an `evidence.md` is larger than `EVIDENCE_MAX_BYTES` (default 100000) the model is skipped
entirely and the deterministic `evidence_to_deck.py` writes the deck instead, so OCR-heavy
screencasts degrade gracefully rather than blowing a context window.

## Hardware

Everything runs on CPU. **CUDA is the accelerated path** and is used automatically when present:
`setup.sh` installs the CTranslate2 CUDA wheels when it finds a driver, and `transcribe.py`
auto-detects and falls back cleanly. Measured on one box: a 38-minute audio track with the
`base` model takes ~3 min on CPU versus ~49 s on CUDA.

faster-whisper runs on CTranslate2, whose only backends are CPU and CUDA — there is no ROCm or
Metal build — so AMD and Apple-silicon hosts use the CPU path automatically. Tune with
`WHISPER_DEVICE` (`auto|cuda|cpu`), `WHISPER_MODEL`, and `WHISPER_COMPUTE_TYPE`
(`int8_float16` is useful on low-VRAM GPUs).

Transcription dominates wall-clock on CPU. Large batches take hours — that's throughput, not a
hang.

## Optional vision pass

OCR only reads *text*. A vision model also captures what text can't: a chart's trend, a diagram's
shape, UI layout, a speaker's gesture. Point it at any OpenAI-compatible endpoint:

```bash
VISION_MODEL=qwen2.5-vl \
VISION_ENDPOINT=http://127.0.0.1:8081/v1/chat/completions \
  scripts/drive_decks.sh /path/to/videos --agent-cmd "claude -p"
```

`evidence.md` then gains a **"Visual descriptions"** section. Set `VISION_API_KEY` if the
endpoint needs a bearer token. If the endpoint is unreachable the run continues with OCR only —
nothing breaks. Disable with `--no-vision`.

## Output layout, finalize, regroup

Source subfolders are mirrored during the run. When the batch finishes, `drive_decks.sh`
finalizes by default: sanitize Mermaid labels (`fix_mermaid_labels.sh`) and rename each **leaf**
to its topic slug (`rename_by_topic.sh`). Pass `--no-finalize` to keep the original video-stem
folder names.

If output is already flat and you want the hierarchy back, rebuild it without re-processing —
each `evidence.md` records its exact source path, so the parent is read from evidence rather than
guessed. Duplicates are quarantined to `<decks>/_duplicates/`, never deleted.

```bash
scripts/regroup_by_source.sh /path/to/decks --dry-run
scripts/regroup_by_source.sh /path/to/decks
scripts/rename_by_topic.sh   /path/to/decks
```

## Export

```bash
scripts/render.sh <out>/<stem>/deck.md pptx      # or: pdf | html | all
```

Mermaid blocks are pre-rendered to SVG first, then marp-cli exports. `render.sh` also injects
fit-to-slide CSS so images share the space the text leaves instead of overflowing the slide
edge. Add `--pdf` to `drive_decks.sh` to batch-export after authoring; the leaf folder is
collapsed so each PDF lands in its parent (`<out>/CourseA/lesson.pdf`).

Diagram sizing is normalized at render time by `scripts/normalize_svg.py`. mermaid emits
`width="100%"` with no height, so inside an `<img>` a diagram has no intrinsic size and the
browser stretches it until some CSS constraint binds — a wide `flowchart LR` stops at the slide
width and looks compact, while a tall `flowchart TB` stops at the slide *height* and swells to
dominate the slide. Writing an explicit size from the viewBox at `min(MAX_W/w, MAX_H/h, 1)`
means nothing is ever upscaled past its natural size and tall diagrams are capped, so vertical
and horizontal diagrams carry comparable visual weight. Tune with `DIAGRAM_MAX_W` (default
1180) and `DIAGRAM_MAX_H` (default 400), in slide px of a 1280x720 slide.

To retrofit decks rendered before this existed, run it over their SVGs and re-export:

```bash
python3 scripts/normalize_svg.py <deck-dir>/diagrams/*.svg
scripts/render.sh <deck-dir>/deck.md pdf
```

Slides use the `midnight-dark` theme (`assets/theme-midnight-dark.css`) with a matching Mermaid
theme and matplotlib style — one palette across slides, diagrams, and plots. See
`assets/design-tokens.md`.

## Flags

```
drive_decks.sh <folder | video-file> [options]

  --agent-cmd "CMD"   command that authors one deck   (default: "claude -p", or $V2D_AGENT_CMD)
  --out DIR           output root                     (default: <input>/decks)
  --no-vision         OCR only, skip the caption pass
  --no-finalize       skip Mermaid-sanitize + topic-rename (keeps stem folder names)
  --pdf               export every deck to PDF after authoring
  --background        detach; print pid + logfile + tail -f line
  --dry-run           print the resolved per-video plan; launch nothing
  -h | --help
```

Every run writes `<out>/logs/<UTC>-drive-<agent>.log`. Re-running the same command is safe:
finished videos print `skip` and a completed media pass is reused.

> **One driver per folder.** Two drivers against the same folder share `<out>/<stem>/` and will
> clobber each other's `frames/`, `ocr.txt`, and `evidence.md`.

## Using it as a Claude Code skill

`SKILL.md` makes this directory usable as a [Claude Code](https://claude.com/claude-code) skill —
drop it in `~/.claude/skills/video-to-deck/` and ask Claude to "make a deck from this video".
The scripts are plain bash/Python and work standalone without it.

## License

Apache-2.0 — see [LICENSE](LICENSE).
