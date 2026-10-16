#!/usr/bin/env python3
"""
vision_presets.py — presets for LOCAL vision models and the servers that run them.

The vision pass always speaks the same wire format: an OpenAI-compatible
POST /v1/chat/completions with one base64 image_url per request. What differs between models and
servers is the details: the served model id, the port, how to switch off a "thinking" model's
reasoning, how many tokens a caption needs, how large an image should be. This module turns two
names into those details:

  VISION_PRESET   a model from references/vision-models.json   (e.g. qwen3-vl-8b, gemma-3-12b)
  VISION_RUNTIME  a server from references/vision-runtimes.json (e.g. ollama, llama-swap, vllm)

Explicit settings always win: VISION_MODEL overrides the served model id, VISION_ENDPOINT the URL,
V2D_VISION_EXTRA_BODY (a JSON object) the extra request fields, VISION_MAX_TOKENS the token budget.
With neither VISION_PRESET nor VISION_RUNTIME set, the request is exactly what it was before
presets existed (model qwen2.5-vl @ 127.0.0.1:8081, max_tokens 300, temperature 0.2).

Replies are parsed robustly: list content is joined; <think>...</think>, Gemma's empty
<|channel>thought...<channel|> block and GLM's box tokens are stripped; reasoning fields are never
used as the caption; and a reply that spent its whole budget thinking is retried once with the
preset's larger thinking budget.

CLI:
  vision_presets.py list            models and runtimes, one per line
  vision_presets.py describe        the resolved settings for the current environment
  vision_presets.py label           short "model @ runtime" label (used in banners)
Stdlib only, Python >= 3.8. Shared verbatim by the free core and the Pro edition.
"""
from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass, field

SKILL_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEGACY_MODEL = "qwen2.5-vl"
LEGACY_ENDPOINT = "http://127.0.0.1:8081/v1/chat/completions"
LEGACY_MAX_TOKENS = 300
LEGACY_TEMPERATURE = 0.2


class PresetError(Exception):
    pass


def _load(name: str) -> dict:
    path = os.path.join(SKILL_ROOT, "references", name)
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as e:
        raise PresetError(f"cannot read {path}: {e}")


def models() -> dict:
    return {m["id"]: m for m in _load("vision-models.json")["models"]}


def runtimes() -> dict:
    return {r["id"]: r for r in _load("vision-runtimes.json")["runtimes"]}


@dataclass
class Resolved:
    model: str                      # served model id sent in the request
    endpoint: str
    models_url: str
    runtime: str                    # runtime id, or "custom" / "legacy"
    preset: str                     # model preset id, or ""
    max_tokens: int = LEGACY_MAX_TOKENS
    temperature: float | None = LEGACY_TEMPERATURE
    max_edge: int = 0               # 0 = send frames as-is
    extra_body: dict = field(default_factory=dict)
    thinking: str = "none"          # none | optional | default-on
    max_tokens_thinking: int = 2048 # budget for the one retry after thinking ate the first one
    system_prompt: str = ""         # optional per-model system message (e.g. reasoning level)
    image_first: bool = False

    @property
    def label(self) -> str:
        where = self.runtime if self.runtime not in ("legacy", "custom") else self.endpoint
        return f"{self.model} @ {where}"


def _env(env, name: str) -> str:
    v = env.get(name)
    return v if v not in (None, "") else ""


def resolve(env=None) -> Resolved:
    """Resolve the vision settings from the environment (see module docstring for precedence)."""
    env = os.environ if env is None else env
    preset_id, runtime_id = _env(env, "VISION_PRESET"), _env(env, "VISION_RUNTIME")
    r = Resolved(model=LEGACY_MODEL, endpoint=LEGACY_ENDPOINT,
                 models_url=LEGACY_ENDPOINT.replace("/chat/completions", "/models"),
                 runtime="legacy", preset="")
    rt = None
    if runtime_id:
        rts = runtimes()
        if runtime_id not in rts:
            raise PresetError(f"unknown VISION_RUNTIME '{runtime_id}' (known: {', '.join(sorted(rts))})")
        rt = rts[runtime_id]
        r.runtime, r.endpoint, r.models_url = runtime_id, rt["endpoint"], rt["models_url"]
    if preset_id:
        ms = models()
        if preset_id not in ms:
            raise PresetError(f"unknown VISION_PRESET '{preset_id}' (known: {', '.join(sorted(ms))}); "
                              f"see references/vision-local-models.md")
        m = ms[preset_id]
        r.preset = preset_id
        served = m.get("served", {})
        key = runtime_id or "llama-swap"
        r.model = served.get(key) or served.get("default") or preset_id
        r.max_tokens = int(m.get("max_tokens", LEGACY_MAX_TOKENS))
        r.temperature = m.get("temperature", LEGACY_TEMPERATURE)
        r.max_edge = int(m.get("max_edge", 0))
        r.thinking = m.get("thinking", "none")
        r.max_tokens_thinking = int(m.get("max_tokens_thinking", 2048))
        r.system_prompt = m.get("system_prompt") or ""
        r.image_first = bool(m.get("image_first", False))
        r.extra_body = dict(m.get("sampling") or {})
        if r.thinking != "none":
            # Only send a disable-thinking field to a model that thinks and whose template honours
            # it, and only the field this runtime is known to consume.
            rt_ = rt or runtimes().get("llama-swap", {})
            off = rt_.get("disable_thinking") if m.get("disable_via_runtime", True) else None
            if off:
                r.extra_body.update(off)
            else:
                r.max_tokens = max(r.max_tokens, r.max_tokens_thinking)
    elif runtime_id:
        r.model = LEGACY_MODEL
    # explicit overrides
    if _env(env, "VISION_MODEL"):
        r.model = env["VISION_MODEL"]
    if _env(env, "VISION_ENDPOINT"):
        r.endpoint = env["VISION_ENDPOINT"]
        r.models_url = r.endpoint.split("/chat/completions")[0] + "/models"
        if r.runtime == "legacy" and preset_id:
            r.runtime = "custom"
    if _env(env, "V2D_VISION_EXTRA_BODY"):
        try:
            extra = json.loads(env["V2D_VISION_EXTRA_BODY"])
            if not isinstance(extra, dict):
                raise ValueError("not a JSON object")
        except ValueError as e:
            raise PresetError(f"V2D_VISION_EXTRA_BODY must be a JSON object: {e}")
        r.extra_body = extra
    if _env(env, "VISION_MAX_TOKENS"):
        r.max_tokens = int(env["VISION_MAX_TOKENS"])
    return r


def build_payload(r: Resolved, prompt: str, b64_jpeg: str, *, max_tokens: int | None = None,
                  extra: bool = True) -> dict:
    """The chat/completions body. Key order and values match the pre-preset request exactly when
    no preset/runtime is configured."""
    text = {"type": "text", "text": prompt}
    image = {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64_jpeg}"}}
    content = [image, text] if r.image_first else [text, image]
    messages = [{"role": "user", "content": content}]
    if r.system_prompt:
        messages.insert(0, {"role": "system", "content": r.system_prompt})
    payload: dict = {"model": r.model, "messages": messages,
                     "max_tokens": max_tokens or r.max_tokens}
    if r.temperature is not None:
        payload["temperature"] = r.temperature
    if extra and r.extra_body:
        payload.update(r.extra_body)   # inline at top level, as servers expect
    return payload


_THINK_BLOCK = re.compile(r"(?is)<think>.*?</think>")
_GEMMA_THOUGHT = re.compile(r"(?s)<\|channel>thought.*?<channel\|>")
_BOX_TOKENS = re.compile(r"<\|(?:begin|end)_of_box\|>")
_LEAD_CLOSE = re.compile(r"(?is)^.*?</think>")


def parse_reply(resp: dict) -> tuple[str, str]:
    """(caption, status). status: ok | thinking (budget spent reasoning) | empty | error:<msg>."""
    if not isinstance(resp, dict):
        return "", "error:non-JSON reply"
    if resp.get("error"):
        err = resp["error"]
        return "", "error:" + (err.get("message", str(err)) if isinstance(err, dict) else str(err))
    choices = resp.get("choices") or []
    if not choices:
        return "", "error:no choices in reply"
    ch = choices[0] or {}
    msg = ch.get("message") or {}
    content = msg.get("content")
    if isinstance(content, list):
        content = "".join(p if isinstance(p, str) else p.get("text", "") for p in content
                          if isinstance(p, str) or (isinstance(p, dict) and p.get("type") in ("text", "output_text")))
    text = content or ""
    had_think = "<think>" in text.lower() or "</think>" in text.lower()
    had_think = had_think or "<|channel>thought" in text
    text = _BOX_TOKENS.sub("", _GEMMA_THOUGHT.sub("", _THINK_BLOCK.sub("", text)))
    if "</think>" in text.lower():
        text = _LEAD_CLOSE.sub("", text)
    if "<think>" in text.lower():          # unterminated: budget ran out mid-thought
        text = ""
    text = " ".join(text.split())
    if text.startswith("```") and text.endswith("```"):
        text = text.strip("`").strip()
    if text:
        return text[:1500], "ok"
    reasoning = any(msg.get(k) for k in ("reasoning_content", "reasoning", "thinking"))
    if had_think or reasoning or ch.get("finish_reason") == "length":
        return "", "thinking"
    return "", "empty"


def mentions_extra_field(body: str, r: Resolved) -> bool:
    b = (body or "").lower()
    return any(k.lower() in b for k in r.extra_body) or "extra" in b or "unknown" in b or "unrecognized" in b


def caption(send, r: Resolved, prompt: str, b64_jpeg: str) -> tuple[str, int, int]:
    """Caption one frame. `send(payload) -> dict` performs the HTTP POST and raises an exception
    with `.status` and `.body` attributes on HTTP errors. Returns (caption, in_tok, out_tok);
    raises ValueError when no caption could be obtained (counts as a failed frame)."""
    use_extra = r.extra_body and not getattr(r, "_extra_rejected", False)
    try:
        resp = send(build_payload(r, prompt, b64_jpeg, extra=bool(use_extra)))
    except Exception as e:   # noqa: BLE001 — inspect, then re-raise anything we can't fix
        if use_extra and getattr(e, "status", None) in (400, 422) and mentions_extra_field(getattr(e, "body", ""), r):
            r._extra_rejected = True          # remember for the rest of the run
            resp = send(build_payload(r, prompt, b64_jpeg, extra=False))
        else:
            raise
    text, status = parse_reply(resp)
    if status == "thinking":
        # Thinking used the whole budget: one retry with the preset's thinking budget. Never fall
        # back to the reasoning text itself.
        budget = max(r.max_tokens_thinking, r.max_tokens * 4)
        resp = send(build_payload(r, prompt, b64_jpeg, max_tokens=budget,
                                  extra=not getattr(r, "_extra_rejected", False)))
        text, status = parse_reply(resp)
    if status != "ok":
        raise ValueError(f"no caption ({status})")
    u = resp.get("usage") or {}
    return text, int(u.get("prompt_tokens", 0) or 0), int(u.get("completion_tokens", 0) or 0)


def jpeg_bytes(path: str, max_edge: int = 0) -> bytes:
    """Frame bytes, long edge capped at max_edge px via ffmpeg (0 = as-is). The resized copy is a
    temp file outside frames/, so it is never mistaken for a keyframe."""
    if max_edge > 0:
        import subprocess
        import tempfile
        fd, tmp = tempfile.mkstemp(suffix=".jpg", prefix="v2d-frame-")
        os.close(fd)
        try:
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", path, "-vf",
                            f"scale='min({max_edge},iw)':-2", "-q:v", "3", tmp],
                           check=True, capture_output=True, timeout=60)
            with open(tmp, "rb") as fh:
                data = fh.read()
            if data:
                return data
        except (OSError, subprocess.SubprocessError):
            pass
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass
    with open(path, "rb") as fh:
        return fh.read()


def main(argv: list) -> int:
    cmd = argv[1] if len(argv) > 1 else "describe"
    try:
        if cmd == "list":
            print("models (VISION_PRESET):")
            for m in models().values():
                think = "" if m.get("thinking", "none") == "none" else f"  [thinking: {m['thinking']}]"
                print(f"  {m['id']:22s} {m.get('recommended_for', '?'):>18}  {m['name']}{think}")
            print("runtimes (VISION_RUNTIME):")
            for rt in runtimes().values():
                print(f"  {rt['id']:12s} {rt['endpoint']}")
            return 0
        r = resolve()
        if cmd == "label":
            print(r.label)
            return 0
        if cmd == "describe":
            d = {k: v for k, v in r.__dict__.items() if not k.startswith("_")}
            print(json.dumps(d, indent=1))
            return 0
    except PresetError as e:
        print(f"vision_presets.py: {e}", file=sys.stderr)
        return 2
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
