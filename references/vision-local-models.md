# Local vision models: presets for the caption pass

The optional vision pass captions slide keyframes, describing the charts, diagrams and UI that OCR
can't read. It works with any local server that speaks the OpenAI-compatible
`/v1/chat/completions` API with base64 images. Presets fill in each model's and each server's
details, so one flag is enough:

```bash
scripts/drive_decks.sh talks/ --vision-model qwen3-vl-8b --vision-runtime ollama
python3 scripts/vision_presets.py list         # every preset and runtime
python3 scripts/vision_presets.py describe     # what the current settings resolve to
```

A preset sets these:

- the model id that server expects (for example `qwen3-vl:8b-instruct` on Ollama, the Hugging Face
  repo on vLLM);
- the endpoint and port;
- sampling settings and a caption token budget;
- the frame size to send;
- whether the image goes before the text;
- for models that "think", the request field that switches thinking off.

Replies are cleaned before use:

- `<think>…</think>`, Gemma's empty thought block and GLM's box tokens are stripped;
- reasoning fields are never used as the caption;
- a reply that spent its whole budget thinking is retried once with a larger budget, then counts as
  a failed frame.

## Pick a model by GPU memory

| VRAM | Default | Why |
|---|---|---|
| 8 GB | `qwen3-vl-8b` | No thinking mode at all, strong OCR in 32 languages |
| 12 GB | `qwen3.5-9b` | Native multimodal Qwen; thinking switched off per request |
| 16 GB | `gemma4-12b` | Thinking off by default; Google's 4-bit build is about 7.4 GB |
| 24 GB | `qwen3.8-27b` | Best vendor-reported document and chart scores in this list |

`qwen2.5-vl-7b` (the skill's original model) remains supported. With no preset set, the requests
are exactly what they were before presets existed.

## All presets

| Preset | Model | Fits | Thinks? | Ollama tag | GGUF repo (llama.cpp, with mmproj) | Licence |
|---|---|---|---|---|---|---|
| `qwen3.8-27b` | Qwen3.8-27B (native VLM) | 24GB | yes (disabled per request) | `qwen3.8:27b` | ggml-org/Qwen3.8-27B-GGUF | Apache-2.0 |
| `qwen3.6-35b-a3b` | Qwen3.6-35B-A3B (MoE, native VLM) | 24GB | yes (disabled per request) | `qwen3.6:35b-a3b` | ggml-org/Qwen3.6-35B-A3B-GGUF | Apache-2.0 |
| `qwen3.6-27b` | Qwen3.6-27B (native VLM) | 24GB | yes (disabled per request) | `qwen3.6:27b` | ggml-org/Qwen3.6-27B-GGUF | Apache-2.0 |
| `qwen3.5-9b` | Qwen3.5-9B (native VLM) | 12GB | yes (disabled per request) | `qwen3.5:9b` | unsloth/Qwen3.5-9B-GGUF | Apache-2.0 |
| `qwen3.5-4b` | Qwen3.5-4B (native VLM) | 8GB | yes (disabled per request) | `qwen3.5:4b` | unsloth/Qwen3.5-4B-GGUF | Apache-2.0 |
| `qwen3-vl-8b` | Qwen3-VL-8B-Instruct | 8GB | no | `qwen3-vl:8b-instruct` | Qwen/Qwen3-VL-8B-Instruct-GGUF | Apache-2.0 |
| `qwen3-vl-4b` | Qwen3-VL-4B-Instruct | 6-8GB | no | `qwen3-vl:4b-instruct` | Qwen/Qwen3-VL-4B-Instruct-GGUF | Apache-2.0 |
| `qwen2.5-vl-7b` | Qwen2.5-VL-7B-Instruct (current pipeline default) | 8GB | no | `qwen2.5vl:7b` | ggml-org/Qwen2.5-VL-7B-Instruct-GGUF | Apache-2.0 |
| `gemma4-12b` | Gemma 4 12B Unified (it) | 12-16GB | off by default | `gemma4:12b` | ggml-org/gemma-4-12B-it-GGUF | Apache-2.0 |
| `gemma4-e4b` | Gemma 4 E4B (it) | 8GB | off by default | `gemma4:e4b` | ggml-org/gemma-4-E4B-it-GGUF | Apache-2.0 |
| `gemma4-26b-a4b` | Gemma 4 26B-A4B (it, MoE) | 24GB (16GB tight) | off by default | `gemma4:26b` | ggml-org/gemma-4-26B-A4B-it-GGUF | Apache-2.0 |
| `gemma3-12b` | Gemma 3 12B it (QAT) | 12GB | no | `gemma3:12b-it-qat` | ggml-org/gemma-3-12b-it-qat-GGUF | Gemma Terms of Use (not OSI) |
| `ministral3-14b` | Ministral 3 14B Instruct 2512 | 12-16GB | no | `ministral-3:14b` | mistralai/Ministral-3-14B-Instruct-2512-GGUF | Apache-2.0 |
| `minicpm-v4.7-35b-a3b` | MiniCPM-V 4.7 35B-A3B | 24GB | off by default | `openbmb/minicpm-v4.7:35b-a3b` | openbmb/MiniCPM-V-4.7-35B-A3B-gguf | Apache-2.0 |
| `glm4.6v-flash` | GLM-4.6V-Flash (9B) | 12GB | yes (disabled per request) | `hf.co/ggml-org/GLM-4.6V-Flash-GGUF:Q4_K_M` | ggml-org/GLM-4.6V-Flash-GGUF | MIT |
| `muse-glimmer-30b` | Muse Glimmer 30B (Meta) | 24GB | yes (set to low via system prompt) | `muse-glimmer:30b` | meta-models/Muse-Glimmer-30B-GGUF | Apache-2.0 |

Facts are vendor-reported and were researched on 2026-10-17. The skill only checks request-format
compatibility; it does not run these models. Notes and sources for each preset are in
`references/vision-models.json`.

## Runtimes

| `--vision-runtime` | Default endpoint | How to serve a vision model |
|---|---|---|
| `llama-swap` (default) | `127.0.0.1:8081` | A llama-server entry with `--mmproj`. Use the preset id as the config key, or set `VISION_MODEL` to your key. |
| `llama-server` | `127.0.0.1:8080` | `llama-server -m model.gguf --mmproj mmproj.gguf -c 8192` (or `-hf <gguf repo>`, which fetches the mmproj) |
| `ollama` | `127.0.0.1:11434` | `ollama pull <tag>` (the tag from the table above) |
| `vllm` | `127.0.0.1:8000` | `vllm serve <hf repo> --max-model-len 8192 --limit-mm-per-prompt '{"image":1}'` |
| `sglang` | `127.0.0.1:30000` | `python -m sglang.launch_server --model-path <hf repo>` |
| `lmstudio` | `127.0.0.1:1234` | Load the model in LM Studio and start the server; set `VISION_MODEL` to the id from `/v1/models` |
| `mlx-vlm` | `127.0.0.1:8080` | `python -m mlx_vlm.server --port 8080` (Apple silicon; set `VISION_MODEL` to the mlx-community repo) |
| `localai`, `jan`, `koboldcpp` | 8080 / 1337 / 5001 | Load a vision model with its projector; set `VISION_MODEL` if the id differs |

Each runtime's thinking switch:

- `chat_template_kwargs.enable_thinking=false`: llama-server, llama-swap, vLLM and SGLang;
- `reasoning_effort=none`: Ollama;
- top-level `enable_thinking=false`: MLX-VLM;
- no per-request switch: LM Studio, LocalAI, Jan and KoboldCpp. For these, the preset uses the
  larger thinking budget and the reply is stripped.

## Overrides

Anything you set explicitly beats the preset:

| Setting | Effect |
|---|---|
| `VISION_MODEL` | Served model id (your own alias or tag) |
| `VISION_ENDPOINT` | Full chat URL (another host or port) |
| `VISION_API_KEY` | Bearer token (Jan, LM Studio with auth, vLLM `--api-key`) |
| `VISION_MAX_TOKENS` | Caption token budget |
| `V2D_VISION_EXTRA_BODY` | JSON object of extra request fields; replaces the preset's |
| `VISION_MAX`, `VISION_TIMEOUT`, `VISION_MAX_FAILS`, `VISION_PROMPT` | Unchanged; see `vision-qwen-vl.md` |

If a server rejects one of the preset's extra fields with a 400 or 422, the request is retried once
without them, and the rest of the run leaves them out.

`setup.sh --check` checks that the endpoint answers and that the resolved model id is in its
`/v1/models` list.
