"""(dev) RAM / VRAM / latence d'un composant charge seul : texte (Laya ONNX) ou vision (SigLIP ONNX).

  python tests/mem_probe.py text  fp16 gpu|cpu
  python tests/mem_probe.py vision int8 gpu|cpu
"""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


def vram(pid: int) -> int:
    ps = ("$s = (Get-Counter ('\\GPU Process Memory(pid_' + %d + '*)\\Dedicated Usage') -ErrorAction SilentlyContinue)"
          ".CounterSamples; [int](($s | Measure-Object CookedValue -Sum).Sum / 1MB)") % pid
    out = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True).stdout.strip()
    return int(out or 0)


def main() -> None:
    import psutil

    what, prec, dev = sys.argv[1], sys.argv[2], sys.argv[3]
    pr = psutil.Process()

    def mem():
        m = pr.memory_info()
        return round(m.rss / 2**20), round(m.private / 2**20)

    base = mem()
    t0 = time.perf_counter()
    ts = []
    if what == "text":
        from pompom_assist.heads import OnnxHeads

        h = OnnxHeads(gpu=dev == "gpu", prefer=prec)
        load = time.perf_counter() - t0
        h.warm()
        for i in range(15):
            ts.append(h.ask("field_kind", f"app: chrome.exe | window: Page {i} | control: edit | name: Adresse e-mail").ms)
        backend = h.backend
    else:
        from PIL import Image

        from pompom_assist import vision

        eyes = vision.SiglipEyes(gpu=dev == "gpu", threads=2, precision=prec)
        load = time.perf_counter() - t0
        im = Image.new("RGB", (2560, 1440), "gray")
        for _ in range(15):
            t = time.perf_counter()
            eyes.embed_images([im])
            ts.append((time.perf_counter() - t) * 1000)
        backend = eyes.backend
    ts = sorted(ts[3:])
    print(f"{what} {prec} {backend}: charge {load:.1f} s | RAM (working set, prive) avant {base} apres {mem()} Mo | "
          f"VRAM {vram(pr.pid)} Mo | p50 {ts[len(ts) // 2]:.1f} ms p95 {ts[-1]:.1f} ms")


if __name__ == "__main__":
    main()
