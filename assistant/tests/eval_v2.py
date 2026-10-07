"""Banc d'evaluation eval_v2 : MEME protocole pour la pile actuelle (Laya + SigLIP) et EmbeddingGemma 2.

  .venv\\Scripts\\python.exe tests\\eval_v2.py                    # tout ce qui est disponible (texte + vision)
  .venv\\Scripts\\python.exe tests\\eval_v2.py --text             # texte seulement
  .venv\\Scripts\\python.exe tests\\eval_v2.py --vision           # vision seulement
  .venv\\Scripts\\python.exe tests\\eval_v2.py --backends laya,gemma2 --limit 300 --gpu
  .venv\\Scripts\\python.exe tests\\eval_v2.py --ram              # RAM (working set) dans des processus separes
  .venv\\Scripts\\python.exe tests\\eval_v2.py --text --real chemin\\real_eval.jsonl   # meme comparaison, donnees REELLES
  .venv\\Scripts\\python.exe tests\\eval_v2.py --vision --real-vision chemin\\dossier   # captures reelles etiquetees

Environnement d'EXECUTION (.venv : onnxruntime + numpy + tokenizers + pillow, sans PyTorch). Le processus se
met en priorite BELOW_NORMAL et limite ses fils (4) : la machine sert aussi a jouer.
Resultats : data/eval_v2/results/<date>_<partie>.json + tableaux imprimes.

Jeux figes : data/eval_v2/text.jsonl (data/gen_eval_v2.py) et data/eval_v2/vision/ (data/gen_screens.py).
"""

from __future__ import annotations

import argparse
import ctypes
import json
import math
import os
import statistics
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "4")
os.environ.setdefault("HF_HUB_OFFLINE", "1")
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
EVAL = ROOT / "data" / "eval_v2"
RESULTS = EVAL / "results"

from pompom_assist import rules  # noqa: E402
from pompom_assist.decider import Decider  # noqa: E402


# --------------------------------------------------------------------------- machine partagee
def lowprio(idle: bool = False) -> None:
    """BELOW_NORMAL (mesures) ou IDLE (gros calculs) : les jeux restent fluides."""
    from pompom_assist.lowprio import set_low_priority

    set_low_priority(idle)


class _PMC(ctypes.Structure):
    _fields_ = [("cb", ctypes.c_ulong), ("PageFaultCount", ctypes.c_ulong), ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t), ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t), ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t), ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t), ("PrivateUsage", ctypes.c_size_t)]


def mem_mb() -> tuple[int, int]:
    """(working set, prive) du processus courant, en Mo."""
    if os.name != "nt":
        return 0, 0
    c = _PMC()
    c.cb = ctypes.sizeof(c)
    k = ctypes.WinDLL("kernel32")
    k.GetCurrentProcess.restype = ctypes.c_void_p  # pseudo-poignee -1 : sinon tronquee en 32 bits (echec muet)
    ps = ctypes.WinDLL("psapi")
    ps.GetProcessMemoryInfo.argtypes = [ctypes.c_void_p, ctypes.POINTER(_PMC), ctypes.c_ulong]
    ps.GetProcessMemoryInfo(k.GetCurrentProcess(), ctypes.byref(c), c.cb)
    return round(c.WorkingSetSize / 2**20), round(c.PrivateUsage / 2**20)


def pct(xs: list[float], q: float) -> float:
    if not xs:
        return 0.0
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]


def r3(x):
    return None if x is None else round(float(x), 3)


# --------------------------------------------------------------------------- chargeurs
def load_text_backend(name: str, threads: int, gpu: bool = False):
    if name == "laya":
        from pompom_assist.heads import OnnxHeads

        return OnnxHeads(gpu=gpu, threads=threads)
    if name == "gemma2":
        from pompom_assist.gemma_onnx import GemmaHeads

        return GemmaHeads(gpu=gpu, threads=threads)
    raise ValueError(name)


def text_backend_available(name: str) -> bool:
    if name == "laya":
        return (ROOT / "models" / "heads.json").exists()
    if name == "gemma2":
        return (ROOT / "models" / "gemma2" / "gemma2.json").exists()
    return False


# --------------------------------------------------------------------------- texte
def normalize_row(r: dict, i: int, src: str) -> dict:
    """Ligne d'un jeu REEL (assistant/tools/build_real_dataset.py) ou synthetique -> schema eval_v2.
    Requis : field, kind, candidates, best. Optionnels : types (sinon rules.content_type), secret (sinon
    field.is_password ou kind == "secret"), lang, tags, id."""
    r = dict(r)
    r.setdefault("id", f"{src}{i:05d}")
    r["candidates"] = [str(c) for c in (r.get("candidates") or [])]
    r.setdefault("types", [rules.content_type(c) for c in r["candidates"]])
    r["secret"] = bool(r.get("secret", False) or r.get("kind") == "secret"
                       or (r.get("field") or {}).get("is_password"))
    if r["secret"]:
        r["kind"], r["best"] = "other", -1
    r["best"] = int(r.get("best", -1))
    r.setdefault("lang", "?")
    r["tags"] = list(r.get("tags") or []) + ([src] if src == "real" else [])
    return r


def load_rows(limit: int = 0, path: Path | None = None) -> list[dict]:
    src = "real" if path else "synthetic"
    with open(path or (EVAL / "text.jsonl"), encoding="utf-8") as f:
        rows = [normalize_row(json.loads(line), i, src) for i, line in enumerate(f) if line.strip()]
    if limit:
        step = max(1, len(rows) // limit)
        rows = rows[::step][:limit]  # echantillon regulier : garde toutes les familles
    return rows


def gold_text_kind(r: dict) -> str:
    return r["types"][r["best"]] if r["best"] >= 0 else "none"


def eval_decider(name: str, dec: Decider, rows: list[dict]) -> dict:
    for r in rows[:5]:  # chauffe
        dec.suggest(r["field"], r["candidates"])
    lat, model_lat = [], []
    agg = defaultdict(lambda: [0, 0])
    k_ok = p_ok = e_ok = n_ns = 0
    sec_ok = sec_n = false_secret = 0
    errors = []
    for r in rows:
        t0 = time.perf_counter()
        s = dec.suggest(r["field"], r["candidates"])
        lat.append((time.perf_counter() - t0) * 1000)
        if s.model_ms:
            model_lat.append(s.model_ms)
        pick = s.index == r["best"]
        p_ok += pick
        if r["secret"]:
            sec_n += 1
            sec_ok += s.index == -1
            agg["secret"][0] += s.index == -1
            agg["secret"][1] += 1
            continue
        n_ns += 1
        false_secret += s.skip == "secret"
        kk = s.kind == r["kind"]
        k_ok += kk
        e_ok += kk and pick
        for key in [f"kind:{r['kind']}", f"lang:{r['lang']}"] + [f"tag:{t}" for t in r["tags"]]:
            agg[key][0] += kk and pick
            agg[key][1] += 1
        if not (kk and pick) and len(errors) < 25:
            errors.append({"id": r["id"], "want": [r["kind"], r["best"]], "got": [s.kind, s.index, s.kind_source,
                                                                                   s.pick_source],
                           "name": r["field"]["name"], "title": r["field"]["window_title"]})
    n = len(rows)
    return {
        "config": name, "n": n, "n_non_secret": n_ns, "n_secret": sec_n,
        "field_kind_acc": r3(k_ok / max(1, n_ns)),
        "right_suggestion_acc": r3(p_ok / n),  # le texte propose (ou rien) est le bon, sur TOUT le jeu
        "end_to_end_acc": r3(e_ok / max(1, n_ns)),  # sorte ET texte justes (champs non secrets)
        "secrets_never_suggested": r3(sec_ok / max(1, sec_n)), "secret_rows_leaked": sec_n - sec_ok,
        "false_secret_rows": false_secret,
        "p50_ms": round(statistics.median(lat), 2), "p95_ms": round(pct(lat, 0.95), 2),
        "model_call_share": r3(len(model_lat) / n),
        "model_call_p50_ms": round(statistics.median(model_lat), 1) if model_lat else None,
        "model_call_p95_ms": round(pct(model_lat, 0.95), 1) if model_lat else None,
        "breakdown": {k: [r3(v[0] / v[1]), v[1]] for k, v in sorted(agg.items())},
        "errors": errors,
    }


def _ece(conf: list[float], ok: list[bool], bins: int = 15) -> float:
    tot = len(conf)
    e = 0.0
    for b in range(bins):
        idx = [i for i, c in enumerate(conf) if min(bins - 1, max(0, math.ceil(c * bins) - 1)) == b]
        if idx:
            e += len(idx) / tot * abs(sum(conf[i] for i in idx) / len(idx) - sum(ok[i] for i in idx) / len(idx))
    return e


def eval_heads_direct(heads, rows: list[dict]) -> dict:
    """Les tetes SEULES (sans regles) : precision, couverture au seuil, precision des cas couverts, ECE."""
    from pompom_assist.heads import describe_field, text_kind_input

    out = {}
    for site in ("field_kind", "text_kind"):
        if not heads.has(site):
            continue
        ok, conf, sure, lat = [], [], [], []
        per = defaultdict(lambda: [0, 0])
        for r in rows:
            if r["secret"]:
                continue
            if site == "field_kind":
                text, allowed, want = describe_field(r["field"]), None, r["kind"]
            else:
                types = [rules.content_type(c) for c in r["candidates"]]
                if not types:
                    continue
                text = text_kind_input(r["kind"], r["field"], types)
                allowed = list(dict.fromkeys(types)) + ["none"]
                want = gold_text_kind(r)
            a = heads.ask(site, text, allowed=allowed)
            lat.append(a.ms)
            ok.append(a.label == want)
            conf.append(a.certainty)
            sure.append(a.confident)
            per[want][0] += a.label == want
            per[want][1] += 1
        cov = [o for o, s in zip(ok, sure) if s]
        out[site] = {"n": len(ok), "acc": r3(sum(ok) / len(ok)), "coverage_at_threshold": r3(len(cov) / len(ok)),
                     "acc_when_confident": r3(sum(cov) / len(cov)) if cov else None,
                     "ece_certainty": r3(_ece(conf, ok)),
                     "p50_ms": round(statistics.median(lat), 1), "p95_ms": round(pct(lat, 0.95), 1),
                     "per_class": {k: [r3(v[0] / v[1]), v[1]] for k, v in sorted(per.items())}}
    return out


def run_text(args) -> dict:
    real = Path(args.real) if args.real else None
    rows = load_rows(args.limit, real)
    res = {"n_rows": len(rows), "source": str(real or "data/eval_v2/text.jsonl"), "configs": [],
           "heads_direct": {}, "load": {}}
    print(f"\n=== TEXTE : {len(rows)} cas ({res['source']}) ===")
    res["configs"].append(eval_decider("rules (avant garde secrets)", Decider(None, secret_guard=False), rows))
    res["configs"].append(eval_decider("rules + garde secrets", Decider(None), rows))
    for b in args.backends:
        if not text_backend_available(b):
            print(f"  [{b}] modeles absents : ignore")
            continue
        m0 = mem_mb()
        t0 = time.perf_counter()
        heads = load_text_backend(b, args.threads, gpu=args.text_gpu)
        heads.warm()
        res["load"][b] = {"load_s": round(time.perf_counter() - t0, 2), "ram_before_mb": m0, "ram_after_mb": mem_mb(),
                          "backend": heads.backend}
        if b == "laya":
            res["configs"].append(eval_decider(f"{b} hybride (tel que livre, sans garde)",
                                               Decider(heads, mode="hybrid", secret_guard=False), rows))
        if hasattr(heads, "is_secret") and getattr(heads, "heads", {}).get("secret") is not None:
            res["configs"].append(eval_decider(f"{b} hybride + garde regles seule",
                                               Decider(heads, mode="hybrid", semantic_secret=False), rows))
        res["configs"].append(eval_decider(f"{b} hybride + garde", Decider(heads, mode="hybrid"), rows))
        if not args.hybrid_only:
            res["configs"].append(eval_decider(f"{b} tetes seules + garde", Decider(heads, mode="heads"), rows))
            res["heads_direct"][b] = eval_heads_direct(heads, rows)
        del heads
        import gc

        gc.collect()
    print_text(res)
    return res


def print_text(res: dict) -> None:
    print(f"\n{'config':44} {'sorte':>6} {'texte':>6} {'b-en-b':>6} {'secret':>6} {'p50ms':>7} {'p95ms':>7} {'appel%':>6}")
    for c in res["configs"]:
        print(f"{c['config']:44} {c['field_kind_acc']:6.3f} {c['right_suggestion_acc']:6.3f} {c['end_to_end_acc']:6.3f} "
              f"{c['secrets_never_suggested']:6.3f} {c['p50_ms']:7.2f} {c['p95_ms']:7.2f} {c['model_call_share']:6.3f}")
    for b, d in res["heads_direct"].items():
        for site, m in d.items():
            print(f"  [{b}] tete {site:10} seule : acc {m['acc']:.3f} | couverture au seuil {m['coverage_at_threshold']:.3f} "
                  f"acc si sure {m['acc_when_confident']} | ECE {m['ece_certainty']:.3f} | p50 {m['p50_ms']} ms")


def run_latency(args) -> dict:
    """Latence d'un appel de tete (field_kind) sur 200 descriptions, chaque pile chargee seule, a la suite :
    memes conditions pour toutes (la machine est partagee : a relancer si un jeu tournait)."""
    from pompom_assist.heads import describe_field

    rows = load_rows(200)
    texts = [describe_field(r["field"]) for r in rows]
    out = {}
    for b in args.backends:
        for gpu in ([False, True] if args.text_gpu else [False]):
            if not text_backend_available(b):
                continue
            h = load_text_backend(b, args.threads, gpu=gpu)
            h.warm()
            for t in texts[:10]:
                h.ask("field_kind", t)
            ts = []
            for t in texts:
                t0 = time.perf_counter()
                h.ask("field_kind", t)
                ts.append((time.perf_counter() - t0) * 1000)
            key = f"{b}/{h.backend}"
            out[key] = {"p50_ms": round(statistics.median(ts), 1), "p95_ms": round(pct(ts, 0.95), 1),
                        "mean_ms": round(sum(ts) / len(ts), 1)}
            print(f"  latence {key:18} {out[key]}")
            del h
            if b == "gemma2":
                from pompom_assist.gemma_onnx import release_shared

                release_shared()
            import gc

            gc.collect()
    return out


# --------------------------------------------------------------------------- vision
def run_vision(args) -> dict:
    from eval_v2_vision import run as vrun  # noqa: E402  (meme dossier)

    return vrun(args)


# --------------------------------------------------------------------------- RAM (processus separes)
RAM_CASES = {
    "idle": "pass",
    "laya_text": "from pompom_assist.heads import OnnxHeads; h=OnnxHeads(gpu=False); h.warm(); "
                 "[h.ask('field_kind', 'app: chrome.exe | window: x | control: edit | name: Adresse %d' % i) for i in range(20)]",
    "gemma2_text": "from pompom_assist.gemma_onnx import GemmaHeads; h=GemmaHeads(gpu=False); h.warm(); "
                   "[h.ask('field_kind', 'app: chrome.exe | window: x | control: edit | name: Adresse %d' % i) for i in range(20)]",
    "siglip_vision": "from PIL import Image; from pompom_assist import vision; e=vision.SiglipEyes(gpu=GPU, threads=2); "
                     "im=Image.new('RGB',(2560,1440),'gray'); [e.embed_images([im]) for _ in range(5)]",
    "gemma2_vision": "from PIL import Image; from pompom_assist.gemma_onnx import GemmaEyes; e=GemmaEyes(gpu=GPU, threads=2); "
                     "im=Image.new('RGB',(2560,1440),'gray'); [e.embed_images([im]) for _ in range(5)]",
}


def ram_child(case: str, gpu: bool) -> None:
    lowprio()
    code = RAM_CASES[case].replace("GPU", "True" if gpu else "False")
    t0 = time.perf_counter()
    g: dict = {}
    exec(code, g)  # g garde les modeles en vie pendant la mesure
    ws, priv = mem_mb()
    print(json.dumps({"case": case, "gpu": gpu, "working_set_mb": ws, "private_mb": priv,
                      "s": round(time.perf_counter() - t0, 1)}))


def run_ram(args) -> list[dict]:
    out = []
    for case in RAM_CASES:
        if case.startswith("gemma2") and not text_backend_available("gemma2"):
            continue
        for gpu in ([False, True] if "vision" in case else [False]):
            p = subprocess.run([sys.executable, __file__, "--ram-child", case] + (["--gpu"] if gpu else []),
                               capture_output=True, text=True, timeout=900)
            line = (p.stdout.strip().splitlines() or ["{}"])[-1]
            try:
                d = json.loads(line)
            except ValueError:
                d = {"case": case, "error": (p.stderr or p.stdout)[-300:]}
            print("  RAM", d)
            out.append(d)
    return out


def save(part: str, obj) -> Path:
    RESULTS.mkdir(parents=True, exist_ok=True)
    p = RESULTS / f"{time.strftime('%Y%m%d_%H%M')}_{part}.json"
    p.write_text(json.dumps(obj, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"-> {p}")
    return p


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", action="store_true")
    ap.add_argument("--vision", action="store_true")
    ap.add_argument("--ram", action="store_true")
    ap.add_argument("--ram-child", default="")
    ap.add_argument("--latency", action="store_true", help="latence d'un appel de tete texte, piles a la suite")
    ap.add_argument("--hybrid-only", action="store_true", help="texte : seulement les modes hybrides (rapide)")
    ap.add_argument("--no-timing", action="store_true", help="vision : pas de mesure de temps (precision seule, depuis le cache)")
    ap.add_argument("--backends", default="laya,gemma2")
    ap.add_argument("--vision-backends", default="siglip,gemma2")
    ap.add_argument("--strategies", default="")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--gpu", action="store_true", help="vision sur DirectML (mesures courtes)")
    ap.add_argument("--text-gpu", action="store_true")
    ap.add_argument("--tag", default="")
    ap.add_argument("--real", default="", help="jeu texte REEL (jsonl, meme schema ; ex. split eval de "
                    "tools/build_real_dataset.py) a la place du synthetique")
    ap.add_argument("--real-vision", default="", help="dossier vision REEL (labels.jsonl + <id>.jpg [+ motion.npz])")
    args = ap.parse_args()
    args.backends = [b for b in args.backends.split(",") if b]
    args.vision_backends = [b for b in args.vision_backends.split(",") if b]
    if args.ram_child:
        ram_child(args.ram_child, args.gpu)
        return
    lowprio()
    if args.latency:
        save("latency" + args.tag, run_latency(args))
        return
    everything = not (args.text or args.vision or args.ram)
    if args.text or everything:
        save("text" + ("_real" if args.real else "") + args.tag, run_text(args))
    if args.vision or everything:
        save("vision" + ("_real" if args.real_vision else "") + args.tag, run_vision(args))
    if args.ram:
        save("ram" + args.tag, run_ram(args))


if __name__ == "__main__":
    main()
