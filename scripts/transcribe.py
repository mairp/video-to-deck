#!/usr/bin/env python3
"""
transcribe.py <audio.wav> <out_dir>

Thin wrapper over faster-whisper. Writes:
  <out_dir>/transcript.txt   full plain-text transcript
  <out_dir>/segments.tsv     start<TAB>end<TAB>text   (seconds, 2 decimals)

Env:
  WHISPER_MODEL         model size/name (default: base). e.g. tiny|base|small|medium|large-v3
  WHISPER_DEVICE        cpu|cuda|auto (default: auto -> cuda if present, else cpu)
  WHISPER_COMPUTE_TYPE  override the compute type (default: float16 on cuda, int8 on cpu).
                        Useful values: int8_float16 (low-VRAM GPU), float32 (max accuracy),
                        int8 (fastest CPU).
  WHISPER_LANG          force a language code (default: autodetect)

GPU support: CUDA is the accelerated path. faster-whisper runs on CTranslate2, whose only
backends are CPU and CUDA — there is no ROCm or Metal build — so AMD and Apple-silicon hosts
transcribe on the (portable, slower) CPU path automatically. Nothing here is NVIDIA-only:
with no GPU at all the script still runs end to end, just slower.

Keeps the model's job to synthesis only: this script is deterministic media work.
"""
import os
import sys


def die(msg: str, code: int = 1):
    print(f"transcribe.py: {msg}", file=sys.stderr)
    sys.exit(code)


def ensure_cuda_libs_on_path():
    """Put the venv's pip-installed CUDA libs on the loader path, then re-exec.

    No-op on hosts without them (CPU-only, AMD, Apple silicon) — the caller falls
    through to the CPU path.

    CTranslate2 dlopen()s libcublas.so.12 and libcudnn.so.9 by soname. setup.sh installs
    them as pip wheels (nvidia-cublas-cu12, nvidia-cudnn-cu12) under
    site-packages/nvidia/*/lib, but that directory is NOT on the dynamic loader path and
    ldconfig knows nothing about it. So `ctranslate2.get_cuda_device_count()` returns 1,
    transcribe picks device=cuda, the model build then fails on the missing .so, and the
    except-branch below quietly falls back to cpu/int8 — a GPU host doing 4-core CPU ASR.
    Measured on this box: 38-minute audio, base model — 3 min on CPU vs 49 s on CUDA.

    LD_LIBRARY_PATH is read by the loader only at process start, so setting it in-process
    is useless and a ctypes RTLD_GLOBAL preload does not cover libcudnn's own internal
    dlopens of libcudnn_ops/cnn/engines. Re-exec is the reliable fix.
    """
    if os.environ.get("_V2D_CUDA_PATH_SET"):
        return                                    # already re-exec'd; don't loop
    base = os.path.join(sys.prefix, "lib", f"python{sys.version_info.major}."
                        f"{sys.version_info.minor}", "site-packages", "nvidia")
    if not os.path.isdir(base):
        return                                    # CPU-only install; nothing to do
    libdirs = [os.path.join(base, p, "lib") for p in sorted(os.listdir(base))]
    libdirs = [d for d in libdirs if os.path.isdir(d)]
    if not libdirs:
        return
    current = os.environ.get("LD_LIBRARY_PATH", "")
    if all(d in current.split(os.pathsep) for d in libdirs):
        return                                    # caller already set it
    os.environ["LD_LIBRARY_PATH"] = os.pathsep.join(
        libdirs + ([current] if current else []))
    os.environ["_V2D_CUDA_PATH_SET"] = "1"
    os.execv(sys.executable, [sys.executable] + sys.argv)


def main():
    if len(sys.argv) < 3:
        die("usage: transcribe.py <audio.wav> <out_dir>")
    audio, out_dir = sys.argv[1], sys.argv[2]
    if not os.path.isfile(audio):
        die(f"no such audio file: {audio}")
    os.makedirs(out_dir, exist_ok=True)

    # Must happen before faster_whisper/ctranslate2 is imported (it re-execs the process).
    if os.environ.get("WHISPER_DEVICE", "auto") != "cpu":
        ensure_cuda_libs_on_path()

    try:
        from faster_whisper import WhisperModel
    except ImportError:
        die("faster-whisper not installed. Run scripts/setup.sh "
            "(or: pip install faster-whisper)")

    model_name = os.environ.get("WHISPER_MODEL", "base")
    device = os.environ.get("WHISPER_DEVICE", "auto")
    lang = os.environ.get("WHISPER_LANG") or None

    # Resolve device/compute_type. int8 is fast + memory-light on CPU; float16 on GPU.
    # CTranslate2 exposes CPU and CUDA only, so any non-CUDA accelerator resolves to cpu.
    if device == "auto":
        try:
            import ctranslate2  # bundled with faster-whisper
            device = "cuda" if ctranslate2.get_cuda_device_count() > 0 else "cpu"
        except Exception:
            device = "cpu"
    compute_type = os.environ.get("WHISPER_COMPUTE_TYPE") or (
        "float16" if device == "cuda" else "int8")

    print(f"transcribe.py: model={model_name} device={device} "
          f"compute={compute_type} lang={lang or 'auto'}", file=sys.stderr)

    def run(dev, ctype):
        # Build the model AND fully consume the (lazy) generator here, so a missing
        # CUDA lib (libcublas/libcudnn) surfaces inside this try rather than later.
        wm = WhisperModel(model_name, device=dev, compute_type=ctype)
        segments, info = wm.transcribe(audio, language=lang, vad_filter=True)
        return list(segments), info

    try:
        seglist, info = run(device, compute_type)
    except Exception as e:
        # Common on GPU hosts without the CUDA runtime libs for CTranslate2.
        if device == "cuda":
            print(f"transcribe.py: WARNING cuda path failed ({e})", file=sys.stderr)
            print("transcribe.py: WARNING falling back to cpu/int8 — this is ~4x slower. "
                  "Fix with: pip install nvidia-cublas-cu12 nvidia-cudnn-cu12 "
                  "into the venv (scripts/setup.sh does this when a driver is present), "
                  "or set WHISPER_DEVICE=cpu to silence this.",
                  file=sys.stderr)
            seglist, info = run("cpu", "int8")
        else:
            raise

    print(f"transcribe.py: detected language={info.language} "
          f"prob={info.language_probability:.2f}", file=sys.stderr)

    txt_path = os.path.join(out_dir, "transcript.txt")
    tsv_path = os.path.join(out_dir, "segments.tsv")
    full = []
    with open(tsv_path, "w", encoding="utf-8") as tsv:
        for seg in seglist:
            text = seg.text.strip()
            if not text:
                continue
            tsv.write(f"{seg.start:.2f}\t{seg.end:.2f}\t{text}\n")
            full.append(text)
    with open(txt_path, "w", encoding="utf-8") as f:
        f.write(" ".join(full).strip() + "\n")

    print(f"transcribe.py: wrote {txt_path} and {tsv_path} "
          f"({len(full)} segments)", file=sys.stderr)


if __name__ == "__main__":
    main()
