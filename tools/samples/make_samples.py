#!/usr/bin/env python3 -I
"""Renders manifest.json to raw 16 kHz mono PCM16 files with macOS voices.

Usage: python3 -I tools/samples/make_samples.py

Needs `say` (macOS) and `ffmpeg`. Writes tools/samples/out/<id>.pcm. Variants:
  noise  pink noise mixed in at roughly 10 dB SNR, like a busy room
  fast   played 30 percent faster, like a quick speaker
"""

import json
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "out"


def render(sample, workdir):
    aiff = workdir / f"{sample['id']}.aiff"
    speech = sample.get("speech", sample["text"])
    subprocess.run(["say", "-v", sample["voice"], "-o", str(aiff), speech], check=True)

    variant = sample.get("variant")
    filters = []
    inputs = ["-i", str(aiff)]
    if variant == "noise":
        inputs += ["-f", "lavfi", "-i", "anoisesrc=color=pink:amplitude=0.08:sample_rate=16000"]
        filters = ["-filter_complex", "[0:a]aresample=16000,aformat=channel_layouts=mono[s];[s][1:a]amix=inputs=2:duration=first:normalize=0[m]", "-map", "[m]"]
    elif variant == "fast":
        filters = ["-filter:a", "atempo=1.3"]
    elif variant:
        sys.exit(f"{sample['id']}: unknown variant {variant!r}")

    pcm = OUT / f"{sample['id']}.pcm"
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", *inputs, *filters, "-ar", "16000", "-ac", "1", "-f", "s16le", str(pcm)],
        check=True,
    )
    return pcm.stat().st_size / 32000


def main():
    manifest = json.loads((HERE / "manifest.json").read_text())
    OUT.mkdir(exist_ok=True)
    total = 0.0
    with tempfile.TemporaryDirectory() as tmp:
        for sample in manifest["samples"]:
            seconds = render(sample, pathlib.Path(tmp))
            total += seconds
            print(f"{sample['id']:<24} {seconds:5.1f}s  {sample['voice']}")
    print(f"{len(manifest['samples'])} samples, {total:.0f}s of speech, in {OUT}")


if __name__ == "__main__":
    main()
