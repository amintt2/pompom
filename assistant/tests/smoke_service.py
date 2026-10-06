"""Test de bout en bout du service (sans Godot) : demarrage, securite, /suggest, /decide, arret.

  python tests/smoke_service.py [--cpu] [--no-model] [--base multilingual|english]
"""

from __future__ import annotations

import argparse
import json
import secrets
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = ROOT / ".venv" / "Scripts" / "python.exe"


def call(port, path, body=None, token="", headers=None, timeout=10):
    h = {"content-type": "application/json"}
    if token:
        h["x-pompom-token"] = token
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cpu", action="store_true")
    ap.add_argument("--no-model", action="store_true")
    ap.add_argument("--no-vision", action="store_true")
    ap.add_argument("--base", default="")
    ap.add_argument("--port", type=int, default=47831)
    a = ap.parse_args()
    token = secrets.token_hex(12)
    args = [str(PY), str(ROOT / "service.py"), "--port", str(a.port), "--token", token, "--no-focus"]
    args += ["--cpu"] if a.cpu else ["--gpu"]
    if a.no_model:
        args.append("--no-model")
    if a.base:
        args += ["--base", a.base]
    t0 = time.time()
    p = subprocess.Popen(args, creationflags=0x08000000)
    ok = True
    h = {}
    try:
        while time.time() - t0 < 10:
            try:
                st, h = call(a.port, "/health")
                if st == 200:
                    break
            except OSError:
                time.sleep(0.05)
        print(f"service up in {time.time() - t0:.2f}s", h)
        # securite
        assert call(a.port, "/focus")[0] == 401, "token requis"
        assert call(a.port, "/focus", token="bad")[0] == 401
        assert call(a.port, "/focus", token=token, headers={"origin": "https://evil.example"})[0] == 403
        # regles seules tout de suite (le modele charge en fond)
        f_email = {"control_type": "edit", "name": "Adresse e-mail", "process": "chrome.exe",
                   "window_title": "Inscription", "is_password": False}
        cands = ["on se voit demain ?", "lea.martin@gmail.com", "06 12 34 56 78"]
        st, s = call(a.port, "/suggest", {"field": f_email, "candidates": cands}, token)
        print("email ->", s)
        ok &= st == 200 and s["kind"] == "email" and s["index"] == 1 and s["label_fr"] == "Coller ton email ?"
        st, s = call(a.port, "/suggest", {"field": {"skip": "password"}, "candidates": cands}, token)
        ok &= s["index"] == -1 and s["skip"] == "password"
        if not a.no_model:
            while time.time() - t0 < 180:
                h = call(a.port, "/health")[1]
                if h["heads"] in ("ready", "error"):
                    break
                time.sleep(0.2)
            print(f"heads {h['heads']} ({h['backend']}) after {time.time() - t0:.2f}s")
            ok &= h["heads"] == "ready"
            amb = {"control_type": "edit", "name": "Chercher", "process": "chrome.exe",
                   "window_title": "Plans - OpenStreetMap", "is_password": False}
            st, s = call(a.port, "/suggest", {"field": amb, "candidates": ["vélo électrique occasion",
                                                                           "8 place Bellecour 69002 Lyon"]}, token)
            print("osm ->", s)
            ok &= s["index"] == 1
            lat = []
            for i in range(20):
                f = dict(amb, window_title=f"Plans {i} - OpenStreetMap")
                t = time.perf_counter()
                call(a.port, "/suggest", {"field": f, "candidates": ["vélo électrique occasion",
                                                                     "8 place Bellecour 69002 Lyon"]}, token)
                lat.append((time.perf_counter() - t) * 1000)
            lat.sort()
            print(f"suggest via HTTP avec tetes stuntd (kind+pick) : p50={statistics.median(lat):.1f} ms p95={lat[int(0.95 * 19)]:.1f} ms")
            st, d = call(a.port, "/decide", {"question": "Le compagnon a faim et il est 13h. Que fait-il ?",
                                             "options": ["manger", "dormir", "jouer"]}, token)
            print("decide ->", st, d)
            ok &= st == 200 and d["answer"] in ("manger", "dormir", "jouer")
        if not a.no_vision:
            st, v = call(a.port, "/vision", token=token)
            ok &= st == 200 and v["enabled"] is False  # opt-in : rien ne tourne par defaut
            st, v = call(a.port, "/vision/enable", {"on": True}, token)
            t1 = time.time()
            while time.time() - t1 < 60 and not v.get("ready"):
                time.sleep(0.5)
                v = call(a.port, "/vision", token=token)[1]
            print(f"vision prete en {time.time() - t1:.1f}s :", {k: v.get(k) for k in ("backend", "top", "probs", "video_rect", "fullscreen", "paused", "ms")})
            ok &= bool(v.get("ready")) and len(v.get("probs", {})) == 7 and abs(sum(v["probs"].values()) - 1) < 0.01
            st, v = call(a.port, "/vision/pause", {"paused": True}, token)
            time.sleep(2.0)
            v = call(a.port, "/vision", token=token)[1]
            print("pause demandee ->", v.get("paused"))
            ok &= v.get("paused") == "client"
            call(a.port, "/vision/pause", {"paused": False}, token)
            st, v = call(a.port, "/vision/enable", {"on": False}, token)
            ok &= v["enabled"] is False
        call(a.port, "/shutdown", {}, token)
        p.wait(10)
        print("shutdown OK, code", p.returncode)
    finally:
        if p.poll() is None:
            p.kill()
            ok = False
    print("SMOKE", "OK" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
