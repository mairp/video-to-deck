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
bash scripts/setup.sh --check  # read-only: what's present and what's missing
bash scripts/setup.sh          # install what's missing
```

| OS | Notes |
|---|---|
| macOS | Needs [Homebrew](https://brew.sh). Works with the stock bash 3.2. |
| Ubuntu / Debian | Uses apt; asks for sudo. |
| Fedora / RHEL | Uses dnf. |
| Windows | Use WSL2 (Ubuntu), then follow the Ubuntu path. |

`setup.sh` installs ffmpeg, tesseract and a Chromium browser through the OS package manager,
faster-whisper into `./.venv`, and marp-cli + mermaid-cli via npm. It is idempotent; install
output goes to `.setup.log`. If `npm` is missing it skips marp/mermaid and decks simply stay as
valid Markdown.

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
shape, UI layout, a speaker's gesture. It is off by default; pass `--vision` or set
`VISION_MODEL`, and point it at any OpenAI-compatible endpoint:

```bash
VISION_MODEL=qwen2.5-vl \
VISION_ENDPOINT=http://127.0.0.1:8081/v1/chat/completions \
  scripts/drive_decks.sh /path/to/videos --agent-cmd "claude -p"
```

**Local model presets.** 16 current local vision models (Qwen3-VL, Qwen3.5/3.6/3.8, Gemma 4,
Ministral 3, MiniCPM-V 4.7, GLM-4.6V, Muse Glimmer, ...) on 10 runtimes (llama.cpp, llama-swap,
Ollama, vLLM, SGLang, LM Studio, MLX-VLM, LocalAI, Jan, KoboldCpp) are one flag away, with model
ids, thinking switches and frame sizes filled in:

```bash
scripts/drive_decks.sh talks/ --vision-model qwen3-vl-8b --vision-runtime ollama
python3 scripts/vision_presets.py list
```

See [references/vision-local-models.md](references/vision-local-models.md) for picks per GPU size.

`evidence.md` then gains a **"Visual descriptions"** section. Set `VISION_API_KEY` if the
endpoint needs a bearer token. If the endpoint is unreachable the pass gives up after three
failed frames (`VISION_MAX_FAILS`) and the run continues with OCR only — nothing breaks.
`--no-vision` always wins, even when `VISION_MODEL` is set.

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
  --vision            caption keyframes with a vision model (off by default)
  --vision-model ID   local vision preset (implies --vision); list: scripts/vision_presets.py list
  --vision-runtime ID llama-swap | llama-server | ollama | vllm | sglang | lmstudio | mlx-vlm | ...
  --no-vision         OCR only, skip the caption pass
  --no-finalize       skip Mermaid-sanitize + topic-rename (keeps stem folder names)
  --pdf               export every deck to PDF after authoring
  --background        detach; print pid + logfile + tail -f line
  --dry-run           print the resolved per-video plan; launch nothing
  -h | --help
```

Every run writes `<out>/logs/<UTC>-drive-<agent>.log` (inline secrets in `--agent-cmd` are masked).
Re-running the same command is safe: finished videos print `skip` and a completed media pass is
reused. `--background` prints a `kill -- -PID` line that stops the whole job, children included.

> **One driver per folder.** Two drivers against the same folder share `<out>/<stem>/` and will
> clobber each other's `frames/`, `ocr.txt`, and `evidence.md`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Transcription is slow on an NVIDIA box | `bash scripts/setup.sh` installs the CUDA wheels; a `WARNING cuda path failed` line in the log means it fell back to CPU. |
| Vision gave up after 3 frames | The endpoint is down or the model name is wrong. `bash scripts/setup.sh --check` tests reachability. |
| `render.sh: refusing to export` | The deck references an image outside its folder. Make the path relative (`frames/...`). |
| PDF/PPTX export fails | Needs marp-cli and a Chrome/Chromium. Set `CHROME_PATH` if the browser is somewhere unusual. |
| Two runs clobber each other | Run one driver per output folder. |

## Development

```bash
python3 -m unittest discover -s tests -v   # offline; a stub agent writes the decks
```

CI runs the same suite on Ubuntu and macOS (stock bash 3.2).

## Pro edition

**video-to-deck Pro** adds cloud providers per stage (OpenAI/Groq speech-to-text, Claude and
Gemini frame vision, Gemini whole-video understanding, direct API deck authoring), a cost
estimate before every run, per-call usage accounting, and a per-stage privacy banner with a
local-only switch. It is a paid skill; this repository stays the free, fully local core.

## Using it as a Claude Code skill

`SKILL.md` makes this directory usable as a [Claude Code](https://claude.com/claude-code) skill —
drop it in `~/.claude/skills/video-to-deck/` and ask Claude to "make a deck from this video".
The scripts are plain bash/Python and work standalone without it.

## License

Apache-2.0 — see [LICENSE](LICENSE).
