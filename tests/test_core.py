"""Offline tests for the local pipeline (stdlib unittest, no network, no GPU).

Run:  python3 -m unittest discover -s tests -v
Needs ffmpeg/ffprobe for the media tests (skipped otherwise). Videos are generated without an
audio track, so faster-whisper is not needed either. A stub agent writes the deck.
"""
import json
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(os.path.dirname(HERE), "scripts")
BASH = os.environ.get("V2D_TEST_BASH", "bash")   # CI sets /bin/bash (3.2 on macOS)
HAVE_FFMPEG = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))

STUB_AGENT = r'''#!/bin/bash
out=$(printf "%s" "$1" | sed -E "s/.*write a Marp slide deck to ([^,]*deck\.md).*/\1/")
printf -- "---\nmarp: true\n---\n\n# Stub Deck\n\n- body\n" > "$out"
'''


def rd(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def wr(path, data):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(data)


def make_silent_video(path, seconds=3):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
                    "-i", f"testsrc=duration={seconds}:size=320x240:rate=5",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", path], check=True)


class VisionServer:
    """OpenAI-compatible /chat/completions that always fails with the given status."""

    def __init__(self, status=500):
        self.hits = 0
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                outer.hits += 1
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                body = json.dumps({"error": "down"}).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}/v1/chat/completions"

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="v2d-core-")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("VISION", "V2D_"))}
        self.env.update({"V2D_NO_LOCAL_ENV": "1", "KEYFRAME_INTERVAL": "1"})
        self.agent = os.path.join(self.tmp, "agent.sh")
        wr(self.agent, STUB_AGENT)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_sh(self, script, *args, env=None):
        return subprocess.run([BASH, os.path.join(SCRIPTS, script), *args], env=env or self.env,
                              capture_output=True, text=True, timeout=300)


class TestScripts(Base):
    def test_regroup_then_rename_restores_hierarchy(self):
        root = os.path.join(self.tmp, "videos")
        decks = os.path.join(root, "decks")
        for stem, course, title in (("u1", "Course A", "Link Layer Basics"),
                                    ("u2", "Course A", "Link Layer Basics"),
                                    ("u3", "Course B", "Routing")):
            d = os.path.join(decks, stem)
            os.makedirs(d)
            wr(os.path.join(d, "evidence.md"), f"# Evidence\n- **Source:** `{root}/{course}/{stem}.mp4`\n")
            wr(os.path.join(d, "deck.md"), f"---\nmarp: true\n# Fill in placeholder\n---\n\n# {title}\n")
        for script in ("regroup_by_source.sh", "rename_by_topic.sh"):
            r = self.run_sh(script, decks)
            self.assertEqual(r.returncode, 0, script + r.stdout + r.stderr)
        for rel in ("Course A/link-layer-basics/link-layer-basics.md",
                    "Course A/link-layer-basics-2/link-layer-basics-2.md",
                    "Course B/routing/routing.md"):
            self.assertTrue(os.path.isfile(os.path.join(decks, rel)), rel)

    def test_find_videos_skips_output_and_working_dirs(self):
        for rel in ("a.mp4", "sub/b.MKV", "decks/x/video_native/proxy.mp4", "sub/c/frames/kf.mp4"):
            p = os.path.join(self.tmp, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            wr(p, "")
        r = self.run_sh("find_videos.sh", self.tmp, "--exclude", os.path.join(self.tmp, "decks"))
        found = sorted(os.path.relpath(l, self.tmp) for l in r.stdout.splitlines())
        self.assertEqual(found, ["a.mp4", "sub/b.MKV"])

    def test_render_refuses_paths_outside_the_deck(self):
        deck = os.path.join(self.tmp, "deck.md")
        wr(deck, "---\nmarp: true\n---\n\n![](/etc/passwd)\n")
        r = self.run_sh("render.sh", deck, "pdf")
        if "marp-cli not installed" in r.stderr:
            self.skipTest("marp not installed")
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("refusing to export", r.stderr)

    def test_dry_run_masks_secrets(self):
        vid = os.path.join(self.tmp, "a.mp4")
        wr(vid, "")
        r = self.run_sh("drive_decks.sh", vid, "--dry-run",
                        "--agent-cmd", "OPENAI_API_KEY=sk-secret0000 llm --api-key topsecret")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("sk-secret0000", r.stderr)
        self.assertNotIn("topsecret", r.stderr)
        self.assertFalse(any("secret" in f for f in os.listdir(os.path.join(self.tmp, "decks", "logs"))))


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestPipeline(Base):
    def test_batch_end_to_end_with_stub_agent(self):
        src = os.path.join(self.tmp, "My Course", "Unit 1 – intro.mp4")   # spaces + unicode
        os.makedirs(os.path.dirname(src))
        make_silent_video(src)
        r = self.run_sh("drive_decks.sh", os.path.join(self.tmp, "My Course"),
                        "--agent-cmd", f"bash {self.agent}", "--no-finalize")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        out = os.path.join(self.tmp, "My Course", "decks", "Unit 1 – intro")
        self.assertIn("Stub Deck", rd(os.path.join(out, "deck.md")))
        ev = rd(os.path.join(out, "evidence.md"))
        for h in ("## Full transcript", "## Timestamped transcript segments", "## On-screen text"):
            self.assertIn(h, ev)
        r2 = self.run_sh("drive_decks.sh", os.path.join(self.tmp, "My Course"),
                         "--agent-cmd", f"bash {self.agent}", "--no-finalize")
        self.assertIn("skip:", r2.stdout)
        self.assertEqual(r2.stdout.count("process:"), 0)

    def test_no_vision_wins_over_vision_model(self):
        srv = VisionServer()
        try:
            vid = os.path.join(self.tmp, "a.mp4")
            make_silent_video(vid)
            env = dict(self.env, VISION_MODEL="m", VISION_ENDPOINT=srv.url)
            r = self.run_sh("drive_decks.sh", vid, "--no-vision", "--no-finalize",
                            "--agent-cmd", f"bash {self.agent}", env=env)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertEqual(srv.hits, 0)
        finally:
            srv.close()

    def test_dead_vision_endpoint_trips_circuit_breaker(self):
        srv = VisionServer(status=500)
        try:
            os.makedirs(os.path.join(self.tmp, "frames"))
            rows = []
            for i in range(1, 9):
                wr(os.path.join(self.tmp, "frames", f"kf_{i:04d}.jpg"), "x")
                rows.append(f"{i}\tframes/kf_{i:04d}.jpg\n")
            wr(os.path.join(self.tmp, "kept.tsv"), "".join(rows))
            env = dict(self.env, VISION_MODEL="m", VISION_ENDPOINT=srv.url)
            r = subprocess.run(["python3", os.path.join(SCRIPTS, "caption_frames.py"),
                                os.path.join(self.tmp, "kept.tsv"), self.tmp],
                               env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 2, r.stderr)            # caller falls back to OCR
            self.assertEqual(srv.hits, 3)                           # stopped after 3, not 8
            self.assertIn("giving up on the vision pass", r.stderr)
        finally:
            srv.close()

if __name__ == "__main__":
    unittest.main()
