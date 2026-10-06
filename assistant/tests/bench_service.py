"""(dev, a lancer avec dev\\.venv qui a psutil) Cout reel du service tel que le jeu le lance.

  dev\\.venv\\Scripts\\python.exe tests/bench_service.py [--cpu] [--seconds 60] [--interval 3]

Mesure, sur le processus service.py (environnement d'execution .venv, sans PyTorch) :
  1. RAM au demarrage (regles seules), puis modele de texte charge ;
  2. latence HTTP de /suggest sur le jeu test (toutes les lignes, dont celles qui reveillent une tete) ;
  3. vision active pendant N s : CPU moyen (tous coeurs / un coeur), RAM, VRAM, ms par passage ;
  4. RAM apres dechargement du modele de texte (inactivite) et arret de la vision.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import statistics
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = ROOT / ".venv" / "Scripts" / "python.exe"


def vram_mb(pid: int) -> int:
    ps = ("$s = (Get-Counter ('\\GPU Process Memory(pid_' + %d + '*)\\Dedicated Usage') -ErrorAction SilentlyContinue)"
          ".CounterSamples; [int](($s | Measure-Object CookedValue -Sum).Sum / 1MB)") % pid
    out = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True).stdout.strip()
    return int(out or 0)


def call(port, token, path, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                 headers={"x-pompom-token": token, "content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def main() -> None:
    import psutil

    ap = argparse.ArgumentParser()
    ap.add_argument("--cpu", action="store_true")
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--interval", type=float, default=3.0)
    ap.add_argument("--port", type=int, default=47861)
    a = ap.parse_args()
    tok = secrets.token_hex(8)
    t0 = time.time()
    p = subprocess.Popen([str(PY), str(ROOT / "service.py"), "--port", str(a.port), "--token", tok, "--no-focus",
                          "--idle-unload", "25", "--vision-interval", str(a.interval), "--cpu" if a.cpu else "--gpu"],
                         creationflags=0x08000000)
    launcher = psutil.Process(p.pid)
    proc = launcher
    mb = lambda: round(proc.memory_info().rss / 2**20)  # noqa: E731
    res = {}
    try:
        while True:
            try:
                h = call(a.port, tok, "/health")
                break
            except OSError:
                time.sleep(0.05)
        res["http_ready_s"] = round(time.time() - t0, 2)
        kids = [c for c in launcher.children() if c.name().lower().startswith("python")]
        proc = kids[0] if kids else launcher  # le lanceur du venv demarre le vrai Python en enfant
        res["ram_rules_only_mb"] = mb()
        while h["heads"] not in ("ready", "error"):
            time.sleep(0.2)
            h = call(a.port, tok, "/health")
        res["text_model_ready_s"] = round(time.time() - t0, 2)
        res["ram_text_loaded_mb"] = mb()
        with open(ROOT / "data" / "test.jsonl", encoding="utf-8") as f:
            rows = [json.loads(line) for line in f]
        lat, lat_model, peak = [], [], 0
        c0 = proc.cpu_times()
        for r in rows:
            t = time.perf_counter()
            s = call(a.port, tok, "/suggest", {"field": r["field"], "candidates": r["candidates"]})
            lat.append((time.perf_counter() - t) * 1000)
            if s.get("model_ms"):
                lat_model.append((time.perf_counter() - t) * 1000)
            peak = max(peak, mb())
        lat.sort()
        lat_model.sort()
        res["suggest_http_p50_ms"] = round(statistics.median(lat), 1)
        res["suggest_http_p95_ms"] = round(lat[int(0.95 * (len(lat) - 1))], 1)
        res["suggest_with_model_n"] = len(lat_model)
        res["suggest_with_model_p50_ms"] = round(statistics.median(lat_model), 1) if lat_model else None
        res["suggest_with_model_p95_ms"] = round(lat_model[int(0.95 * (len(lat_model) - 1))], 1) if lat_model else None
        res["ram_peak_during_suggest_mb"] = peak
        # vision
        call(a.port, tok, "/vision/enable", {"on": True})
        tv = time.time()
        v = {}
        while time.time() - tv < 90 and not v.get("ready"):
            time.sleep(0.3)
            v = call(a.port, tok, "/vision")
        res["vision_ready_s"] = round(time.time() - tv, 1)
        res["vision_backend"] = v.get("backend")
        time.sleep(4)
        c0 = proc.cpu_times()
        w0 = time.time()
        ms, rams, last = [], [], 0
        while time.time() - w0 < a.seconds:
            time.sleep(1)
            v = call(a.port, tok, "/vision")
            if v.get("ts") != last and v.get("ms"):
                last = v["ts"]
                ms.append(v["ms"])
            rams.append(mb())
        c1 = proc.cpu_times()
        el = time.time() - w0
        used = (c1.user - c0.user) + (c1.system - c0.system)
        res["vision_interval_s"] = a.interval
        res["vision_ms_per_pass_p50"] = round(statistics.median(ms), 1) if ms else None
        res["vision_ms_per_pass_max"] = round(max(ms), 1) if ms else None
        res["vision_cpu_pct_all_cores"] = round(100 * used / el / (os.cpu_count() or 1), 2)
        res["vision_cpu_pct_one_core"] = round(100 * used / el, 1)
        res["ram_text_plus_vision_mb"] = round(statistics.median(rams))
        res["vram_mb"] = vram_mb(proc.pid)
        res["vision_last"] = {k: v.get(k) for k in ("top", "video_rect", "fullscreen", "paused", "foreground")}
        call(a.port, tok, "/vision/enable", {"on": False})
        time.sleep(40)  # idle-unload 25 s
        res["heads_state_after_idle"] = call(a.port, tok, "/health")["heads"]
        res["ram_after_unload_mb"] = mb()
        print(json.dumps(res, ensure_ascii=False, indent=1))
    finally:
        p.kill()


if __name__ == "__main__":
    sys.exit(main())
