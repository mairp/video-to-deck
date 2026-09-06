# Optional vision pass — captioning keyframes with a VLM

The core path (transcript + OCR) needs no vision model. The **optional** vision pass adds a
"## Visual descriptions" section to `evidence.md` by asking a vision-language model to describe
each kept keyframe — useful for charts, diagrams, UI, and gestures that OCR misses.

It's off until you set `VISION_MODEL`. It calls an **OpenAI-compatible** `/v1/chat/completions`
endpoint with a base64 `image_url` (the standard VLM message format), so it works with anything
that speaks that API: llama.cpp / llama-swap, Ollama, vLLM, LM Studio, or a hosted provider.

## Env vars (set on the `process_video.sh` or `drive_decks.sh` command)

| var | default | meaning |
|-----|---------|---------|
| `VISION_MODEL` | `qwen2.5-vl` | model id; **setting this enables the pass** |
| `VISION_ENDPOINT` | `http://127.0.0.1:8081/v1/chat/completions` | any OpenAI-compatible endpoint |
| `VISION_API_KEY` | _(none)_ | bearer token, if the endpoint needs one |
| `VISION_PROMPT` | built-in | per-frame instruction |
| `VISION_MAX` | `40` | cap on frames captioned (bounds cost/time) |
| `VISION_TIMEOUT` | `120` | seconds per request |

## Example: Qwen2.5-VL on llama.cpp

A 7B VLM at Q4 is enough for frame captioning and fits comfortably on a 12 GB card. You need
**two** files: the weights and the **mmproj** vision projector — without the projector
llama.cpp cannot see images at all.

```
Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf        # ~4.7 GB weights
mmproj-Qwen2.5-VL-7B-Instruct-f16.gguf    # ~1.4 GB vision projector (mandatory)
```

Both are on the Hugging Face GGUF repo:

```bash
curl -L -C - -o <models-dir>/<file> \
  https://huggingface.co/ggml-org/Qwen2.5-VL-7B-Instruct-GGUF/resolve/main/<file>
```

Serve it directly:

```bash
llama-server --host 127.0.0.1 --port 8081 \
  -m <models-dir>/Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf \
  --mmproj <models-dir>/mmproj-Qwen2.5-VL-7B-Instruct-f16.gguf \
  -ngl 99 -fa on -c 8192 --parallel 1 --jinja --n-predict 512
```

Then:

```bash
VISION_MODEL=qwen2.5-vl \
VISION_ENDPOINT=http://127.0.0.1:8081/v1/chat/completions \
  scripts/drive_decks.sh /path/to/videos --agent-cmd "claude -p"
```

### Sharing one GPU with a text model

If the authoring model and the VLM both live on one card, a swapping proxy such as
[llama-swap](https://github.com/mostlygeek/llama-swap) will load the VLM on demand and unload it
after an idle TTL, so the vision pass costs nothing when idle:

```yaml
  "qwen2.5-vl":
    cmd: >
      llama-server --host 127.0.0.1 --port ${PORT}
      -m /models/Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf
      --mmproj /models/mmproj-Qwen2.5-VL-7B-Instruct-f16.gguf
      -ngl 99 -fa on -c 8192 --parallel 1 --jinja --n-predict 512
      --metrics
    ttl: 900          # unload after 15 min idle
```

## Example: Ollama

```bash
ollama pull qwen2.5vl
VISION_MODEL=qwen2.5vl \
VISION_ENDPOINT=http://127.0.0.1:11434/v1/chat/completions \
  scripts/drive_decks.sh /path/to/videos --agent-cmd "claude -p"
```

## Example: a hosted API

Any provider exposing OpenAI-compatible vision works — point `VISION_ENDPOINT` at it and set
`VISION_API_KEY`.

## Cost / latency

One request per **kept (deduped) keyframe**, capped by `VISION_MAX`. For a slide-deck video the
kept-frame count is small (roughly one per distinct slide). For long live-action footage, raise
`KEYFRAME_INTERVAL` so you don't caption near-identical frames.

If the endpoint is unreachable or errors, the run continues with OCR only — the vision pass never
blocks a deck.
