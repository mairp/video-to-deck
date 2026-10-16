"""Local vision presets: resolution, request shape, reply parsing, retries (stdlib, offline).

Shared verbatim by the free core and the Pro edition.
Run:  python3 -m unittest discover -s tests -v
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(os.path.dirname(HERE), "scripts")
sys.path.insert(0, SCRIPTS)

import vision_presets as vp  # noqa: E402

LEGACY_BODY = {
    "model": "qwen2.5-vl",
    "messages": [{"role": "user", "content": [
        {"type": "text", "text": "P"},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,B64"}}]}],
    "max_tokens": 300,
    "temperature": 0.2,
}


def reply(content, finish="stop", **msg):
    return {"choices": [{"message": dict(content=content, **msg), "finish_reason": finish}],
            "usage": {"prompt_tokens": 7, "completion_tokens": 3}}


class HTTPErr(Exception):
    def __init__(self, status, body):
        super().__init__(body)
        self.status, self.body = status, body


class TestResolve(unittest.TestCase):
    def test_no_preset_is_byte_identical_to_the_legacy_request(self):
        r = vp.resolve({})
        self.assertEqual(r.endpoint, "http://127.0.0.1:8081/v1/chat/completions")
        body = vp.build_payload(r, "P", "B64")
        self.assertEqual(json.dumps(body), json.dumps(LEGACY_BODY))     # same keys, same order

    def test_explicit_settings_beat_the_preset(self):
        r = vp.resolve({"VISION_PRESET": "qwen3-vl-8b", "VISION_RUNTIME": "ollama",
                        "VISION_MODEL": "my-alias", "VISION_ENDPOINT": "http://h:9/v1/chat/completions",
                        "VISION_MAX_TOKENS": "123", "V2D_VISION_EXTRA_BODY": '{"seed": 1}'})
        self.assertEqual((r.model, r.endpoint, r.max_tokens, r.extra_body),
                         ("my-alias", "http://h:9/v1/chat/completions", 123, {"seed": 1}))
        self.assertEqual(r.models_url, "http://h:9/v1/models")

    def test_every_preset_resolves_on_every_runtime(self):
        for mid, m in vp.models().items():
            for rid, rt in vp.runtimes().items():
                r = vp.resolve({"VISION_PRESET": mid, "VISION_RUNTIME": rid})
                self.assertTrue(r.model and r.endpoint.endswith("/chat/completions"), (mid, rid))
                body = vp.build_payload(r, "P", "B64")
                self.assertIn("image_url", json.dumps(body))
                off = rt.get("disable_thinking") or {}
                sends_off = all(body.get(k) == v for k, v in off.items()) and bool(off)
                if m["thinking"] == "none" or not m.get("disable_via_runtime", True):
                    self.assertFalse(sends_off and m["thinking"] == "none", (mid, rid))
                elif off:
                    self.assertTrue(sends_off, (mid, rid))
                else:   # no switch on this runtime: the token budget must cover the thinking
                    self.assertGreaterEqual(r.max_tokens, m["max_tokens_thinking"], (mid, rid))

    def test_served_ids(self):
        self.assertEqual(vp.resolve({"VISION_PRESET": "qwen3-vl-8b", "VISION_RUNTIME": "ollama"}).model,
                         "qwen3-vl:8b-instruct")                       # not the thinking tag
        self.assertEqual(vp.resolve({"VISION_PRESET": "qwen2.5-vl-7b"}).model, "qwen2.5-vl")
        self.assertEqual(vp.resolve({"VISION_PRESET": "gemma4-12b", "VISION_RUNTIME": "vllm"}).model,
                         "google/gemma-4-12B-it")

    def test_preset_shapes(self):
        g = vp.build_payload(vp.resolve({"VISION_PRESET": "gemma4-12b"}), "P", "B64")
        self.assertEqual(g["messages"][0]["content"][0]["type"], "image_url")   # image first
        q = vp.build_payload(vp.resolve({"VISION_PRESET": "qwen3.5-9b", "VISION_RUNTIME": "vllm"}), "P", "B64")
        self.assertEqual(q["chat_template_kwargs"], {"enable_thinking": False})
        n = vp.build_payload(vp.resolve({"VISION_PRESET": "qwen3-vl-8b"}), "P", "B64")
        self.assertNotIn("chat_template_kwargs", n)
        m = vp.build_payload(vp.resolve({"VISION_PRESET": "muse-glimmer-30b"}), "P", "B64")
        self.assertEqual(m["messages"][0], {"role": "system", "content": "Reasoning strength: low"})

    def test_unknown_names_fail_clearly(self):
        with self.assertRaises(vp.PresetError):
            vp.resolve({"VISION_PRESET": "nope"})
        with self.assertRaises(vp.PresetError):
            vp.resolve({"VISION_RUNTIME": "nope"})
        with self.assertRaises(vp.PresetError):
            vp.resolve({"V2D_VISION_EXTRA_BODY": "[1]"})
        r = subprocess.run([sys.executable, os.path.join(SCRIPTS, "vision_presets.py"), "describe"],
                           env=dict(os.environ, VISION_PRESET="nope"), capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)


class TestParse(unittest.TestCase):
    def test_parse_cases(self):
        P = vp.parse_reply
        self.assertEqual(P(reply("<think>hmm</think> A bar chart.")), ("A bar chart.", "ok"))
        self.assertEqual(P(reply("leaked reasoning</think>A slide.")), ("A slide.", "ok"))
        self.assertEqual(P(reply("<|channel>thought\n<channel|>A diagram.")), ("A diagram.", "ok"))
        self.assertEqual(P(reply("<|begin_of_box|>A UI.<|end_of_box|>")), ("A UI.", "ok"))
        self.assertEqual(P(reply([{"type": "text", "text": "Part one."}, {"type": "image"}])), ("Part one.", "ok"))
        self.assertEqual(P(reply("<think>never closed")), ("", "thinking"))
        self.assertEqual(P(reply(None, reasoning_content="long thoughts")), ("", "thinking"))
        self.assertEqual(P(reply("", finish="length")), ("", "thinking"))
        self.assertEqual(P(reply("")), ("", "empty"))
        self.assertEqual(P({"error": {"message": "boom"}})[1], "error:boom")


class TestCaption(unittest.TestCase):
    def test_reasoning_only_is_retried_with_the_thinking_budget(self):
        r = vp.resolve({"VISION_PRESET": "qwen3.5-9b", "VISION_RUNTIME": "lmstudio"})
        sent = []

        def send(p):
            sent.append(p)
            return reply(None, reasoning_content="...") if len(sent) == 1 else reply("A chart.")
        self.assertEqual(vp.caption(send, r, "P", "B64")[0], "A chart.")
        self.assertEqual(sent[1]["max_tokens"], max(r.max_tokens_thinking, r.max_tokens * 4))

    def test_never_falls_back_to_reasoning(self):
        r = vp.resolve({})
        with self.assertRaises(ValueError):
            vp.caption(lambda p: reply(None, reasoning="only thoughts"), r, "P", "B64")

    def test_rejected_extra_fields_are_dropped_once_and_remembered(self):
        r = vp.resolve({"VISION_PRESET": "qwen3.5-9b", "VISION_RUNTIME": "vllm"})
        sent = []

        def send(p):
            sent.append(p)
            if "chat_template_kwargs" in p:
                raise HTTPErr(400, "Extra inputs are not permitted: chat_template_kwargs")
            return reply("ok caption")
        self.assertEqual(vp.caption(send, r, "P", "B64")[0], "ok caption")
        vp.caption(send, r, "P", "B64")
        self.assertEqual(["chat_template_kwargs" in p for p in sent], [True, False, False])

    def test_other_http_errors_propagate(self):
        r = vp.resolve({"VISION_PRESET": "qwen3.5-9b"})

        def send(p):
            raise HTTPErr(404, "model not found")
        with self.assertRaises(HTTPErr):
            vp.caption(send, r, "P", "B64")


class TestCaptionFramesEndToEnd(unittest.TestCase):
    """caption_frames.py against a fake server, with a preset: request shape + cleaned captions."""

    def setUp(self):
        self.bodies = []
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                outer.bodies.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                out = json.dumps(reply("<think>let me look</think> A rising line chart.")).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.tmp = tempfile.mkdtemp(prefix="v2d-vp-")

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_preset_request_and_clean_caption(self):
        os.makedirs(os.path.join(self.tmp, "frames"))
        with open(os.path.join(self.tmp, "frames", "kf_0001.jpg"), "wb") as fh:
            fh.write(b"\xff\xd8\xff\xe0not-a-real-jpeg")
        with open(os.path.join(self.tmp, "kept.tsv"), "w") as fh:
            fh.write("0\tframes/kf_0001.jpg\n")
        env = {k: v for k, v in os.environ.items() if not k.startswith(("VISION", "V2D_"))}
        env.update({"VISION_PRESET": "qwen3.5-9b", "VISION_RUNTIME": "vllm",
                    "VISION_ENDPOINT": f"http://127.0.0.1:{self.srv.server_address[1]}/v1/chat/completions"})
        r = subprocess.run([sys.executable, os.path.join(SCRIPTS, "caption_frames.py"),
                            os.path.join(self.tmp, "kept.tsv"), self.tmp],
                           env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        body = self.bodies[0]
        self.assertEqual(body["model"], "Qwen/Qwen3.5-9B")
        self.assertEqual(body["chat_template_kwargs"], {"enable_thinking": False})
        with open(os.path.join(self.tmp, "captions.tsv")) as fh:
            self.assertEqual(fh.read(), "0\tframes/kf_0001.jpg\tA rising line chart.\n")


if __name__ == "__main__":
    unittest.main()
