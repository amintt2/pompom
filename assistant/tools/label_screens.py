"""Etiquetage (developpeur) des captures collectees par le mode developpeur du jeu, par un grand modele de
vision, avec une sortie JSON STRICTE (schema ci-dessous). Les etiquettes servent ensuite a entrainer nos
petites tetes locales (build_real_dataset.py puis train_real_heads.py).

  python tools/label_screens.py --dry-run                 # estimation du cout + 1re requete, AUCUN appel
  python tools/label_screens.py [--limit 200] [--yes]     # OpenAI (Responses API + Structured Outputs)
  python tools/label_screens.py --provider anthropic      # SDK anthropic (pip install anthropic)
  python tools/label_screens.py --provider gemini

Entrees : %APPDATA%/Pompom/dataset/screens/*.webp (ou .jpg/.png) + leur fichier .json (processus, titre, categorie, decision du
compagnon...). Sortie : data/real/labels.jsonl (une ligne par image ; relancer reprend la ou on s'etait arrete :
les images deja etiquetees, reconnues par leur empreinte sha1, ne sont jamais renvoyees).

Cles : variables d'environnement OPENAI_API_KEY / ANTHROPIC_API_KEY (ou profil `ant auth login`) /
GEMINI_API_KEY. Jamais dans le code, jamais affichees.

ATTENTION : les captures et leur titre de fenetre partent chez le fournisseur choisi. Ne lancer que sur TES
propres captures (le mode developpeur ne collecte que sur ton PC, et saute deja les ecrans prives).
"""

from __future__ import annotations

import argparse
import base64
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from real_common import (  # noqa: E402
    ACTIVITY_LABELS, GAME_EVENT_LABELS, OUT_DIR, append_jsonl, dataset_dir, low_priority, read_jsonl, sha1_file,
)

DEFAULT_MODELS = {"openai": "gpt-6-luna", "anthropic": "claude-opus-5-5", "gemini": "gemini-flash-lite-latest"}
# USD par million de jetons (entree, sortie). Estimation : verifier les tarifs du jour (--price-in/--price-out).
PRICES = {"gpt-6-luna": (0.10, 0.50), "gpt-6.1-sol": (2.0, 10.0), "claude-opus-5-5": (4.0, 20.0),
          "claude-sonnet-5-5": (2.0, 10.0), "claude-haiku-4-5": (1.0, 5.0), "gemini-flash-lite-latest": (0.10, 0.40)}
KEY_ENV = {"openai": ("OPENAI_API_KEY",), "anthropic": ("ANTHROPIC_API_KEY",), "gemini": ("GEMINI_API_KEY", "GOOGLE_API_KEY")}
OUT_TOKENS = 140  # sortie JSON typique

ACTIVITY_HELP = {
    "video": "watching a video/film/series/stream (YouTube, Netflix, Twitch, a video player); a moving picture is the main content",
    "music": "listening to music or a podcast (Spotify, Deezer, YouTube Music, audio player); no video is the main content",
    "game": "playing a video game (gameplay, game menus, launcher in game)",
    "code": "programming: code editor, IDE, terminal with code, git",
    "ai": "using an AI coding agent or AI chat (Claude Code, Codex, ChatGPT, Claude, Copilot chat)",
    "email": "reading or writing e-mails (Gmail, Outlook, Thunderbird)",
    "docs": "writing or reading documents, notes, slides (Word, Google Docs, Notion, PowerPoint, PDF to edit)",
    "spreadsheet": "spreadsheet (Excel, Google Sheets, LibreOffice Calc)",
    "chat": "messaging / chat apps (Discord, WhatsApp, Slack, Teams chat, Messenger)",
    "social": "social networks feeds (X/Twitter, Instagram, Reddit, TikTok web, Facebook, LinkedIn feed)",
    "reading": "reading articles, news, documentation, books, PDFs to read",
    "design": "graphic design, drawing, photo/video editing, 3D modeling (Figma, Photoshop, Blender, Canva)",
    "browse": "general web browsing, shopping, search results, maps, other websites",
    "meeting": "video call / meeting (Zoom, Teams, Meet) with participants",
    "other": "anything else: desktop, file explorer, settings, installers, empty screen",
}
EVENT_HELP = ("Visible HUD event of the player in a game at this exact moment: goal (the player/their team just scored), "
              "goal_against (the other team scored), kill (the player eliminated someone; kill feed/medal), death "
              "(the player is dead / spectating / respawn timer), round_won, round_lost, match_won (victory screen), "
              "match_lost (defeat screen), none (nothing notable or not a game).")

SCHEMA: dict = {
    "type": "object",
    "additionalProperties": False,
    "required": ["activity", "activity_confidence", "video_present", "video_rect", "game", "hud_event",
                 "hud_event_confidence"],
    "properties": {
        "activity": {"type": "string", "enum": list(ACTIVITY_LABELS)},
        "activity_confidence": {"type": "number"},
        "video_present": {"type": "boolean"},
        "video_rect": {"anyOf": [
            {"type": "object", "additionalProperties": False, "required": ["x", "y", "w", "h"],
             "properties": {k: {"type": "number"} for k in ("x", "y", "w", "h")}},
            {"type": "null"}]},
        "game": {"type": ["string", "null"]},
        "hud_event": {"type": "string", "enum": list(GAME_EVENT_LABELS)},
        "hud_event_confidence": {"type": "number"},
    },
}


def build_prompt(meta: dict) -> str:
    acts = "\n".join(f"- {k}: {v}" for k, v in ACTIVITY_HELP.items())
    hints = {k: meta.get(k) for k in ("proc", "title", "category", "fullscreen", "game") if meta.get(k) not in (None, "")}
    return (
        "You label a screenshot of a Windows PC (primary screen, native resolution) to train a small on-device "
        "classifier. Answer ONLY with the JSON object of the schema.\n\n"
        f"activity = what the user is mainly doing, one of:\n{acts}\n"
        "If the screen shows both a video and something else, pick what is in the foreground / largest.\n"
        "activity_confidence, hud_event_confidence: 0..1.\n"
        "video_present: true only if a playing video / film / stream frame is visible (not a thumbnail grid).\n"
        "video_rect: the visible video area as fractions of the screenshot (x, y, w, h in 0..1), or null.\n"
        "game: the game name if a game is visible, else null.\n"
        f"hud_event: {EVENT_HELP}\n\n"
        f"Hints from the OS (may be wrong or stale): {json.dumps(hints, ensure_ascii=False)}"
    )


# --------------------------------------------------------------------------- cout
def image_tokens(provider: str, w: int, h: int, detail: str) -> int:
    if provider == "openai":
        if detail == "low":  # tient dans 512x512
            s = min(1.0, 512 / max(w, h))
            w, h = int(w * s), int(h * s)
        patches = math.ceil(w / 32) * math.ceil(h / 32)
        return math.ceil(min(patches, 1536) * 1.2)  # modeles « par patchs » (multiplicateur 1,2 : estimation)
    if provider == "anthropic":
        return math.ceil(w * h / 750)
    return 258 * math.ceil(w / 768) * math.ceil(h / 768)  # gemini : tuiles de 768


def estimate(provider: str, model: str, n: int, detail: str, price_in: float | None, price_out: float | None,
             prompt_chars: int, w: int = 2560, h: int = 1440) -> dict:
    pin, pout = PRICES.get(model, (None, None))
    pin = price_in if price_in is not None else pin
    pout = price_out if price_out is not None else pout
    tin = image_tokens(provider, w, h, detail) + prompt_chars // 3 + 400  # + schema
    usd = None if pin is None or pout is None else n * (tin * pin + OUT_TOKENS * pout) / 1e6
    return {"images": n, "tokens_in_per_image": tin, "tokens_out_per_image": OUT_TOKENS, "usd": usd,
            "price_in": pin, "price_out": pout}


# --------------------------------------------------------------------------- fournisseurs
def get_key(provider: str) -> str:
    for name in KEY_ENV[provider]:
        v = os.environ.get(name, "")
        if v:
            return v
    return ""


def post_json(url: str, body: dict, headers: dict, timeout: float = 60.0) -> dict:
    """POST JSON (urllib). Remplace dans les tests."""
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"),
                                 headers={"content-type": "application/json", **headers}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 (URL fixe du fournisseur)
        return json.loads(r.read().decode("utf-8"))


IMAGE_TYPES = {".webp": "image/webp", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png"}


def media_type(path: Path | str) -> str:
    return IMAGE_TYPES.get(Path(path).suffix.lower(), "image/jpeg")


def openai_request(model: str, prompt: str, b64: str, detail: str, mime: str = "image/webp") -> dict:
    return {
        "model": model,
        "input": [{"role": "user", "content": [
            {"type": "input_text", "text": prompt},
            {"type": "input_image", "image_url": f"data:{mime};base64," + b64, "detail": detail},
        ]}],
        "text": {"format": {"type": "json_schema", "name": "screen_label", "schema": SCHEMA, "strict": True}},
        "max_output_tokens": 400,
        "store": False,
    }


def call_openai(model: str, prompt: str, b64: str, detail: str, key: str, mime: str) -> tuple[dict, dict]:
    r = post_json("https://api.openai.com/v1/responses", openai_request(model, prompt, b64, detail, mime),
                  {"authorization": "Bearer " + key})
    for item in r.get("output") or []:
        for c in item.get("content") or []:
            if c.get("type") == "refusal":
                raise ValueError("refusal: " + str(c.get("refusal", ""))[:120])
            if c.get("type") == "output_text":
                return json.loads(c["text"]), r.get("usage") or {}
    raise ValueError("no output_text")


def call_anthropic(model: str, prompt: str, b64: str, key: str, mime: str) -> tuple[dict, dict]:
    import anthropic  # SDK officiel (pip install anthropic)

    client = anthropic.Anthropic(api_key=key) if key else anthropic.Anthropic()  # sinon profil `ant auth login`
    resp = client.beta.messages.create(
        model=model,
        max_tokens=1024,
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",
        output_config={"effort": "low", "format": {"type": "json_schema", "schema": SCHEMA}},
        messages=[{"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": mime, "data": b64}},
            {"type": "text", "text": prompt},
        ]}],
    )
    if resp.stop_reason == "refusal":
        raise ValueError("refusal")
    text = next(b.text for b in resp.content if b.type == "text")
    u = resp.usage
    return json.loads(text), {"input_tokens": u.input_tokens, "output_tokens": u.output_tokens}


def call_gemini(model: str, prompt: str, b64: str, key: str, mime: str) -> tuple[dict, dict]:
    body = {
        "contents": [{"role": "user", "parts": [{"inline_data": {"mime_type": mime, "data": b64}},
                                                 {"text": prompt}]}],
        "generationConfig": {"responseMimeType": "application/json", "responseJsonSchema": SCHEMA,
                             "maxOutputTokens": 400},
    }
    r = post_json(f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent", body,
                  {"x-goog-api-key": key})
    text = r["candidates"][0]["content"]["parts"][0]["text"]
    um = r.get("usageMetadata") or {}
    return json.loads(text), {"input_tokens": um.get("promptTokenCount"), "output_tokens": um.get("candidatesTokenCount")}


def validate(lab: dict) -> dict:
    """Controle (et bornage) de la reponse : on ne garde que les champs du schema."""
    if lab.get("activity") not in ACTIVITY_LABELS:
        raise ValueError("activity hors vocabulaire")
    if lab.get("hud_event") not in GAME_EVENT_LABELS:
        raise ValueError("hud_event hors vocabulaire")
    rect = lab.get("video_rect")
    if isinstance(rect, dict):
        x, y = (min(1.0, max(0.0, float(rect.get(k, 0.0)))) for k in ("x", "y"))
        w = min(1.0 - x, max(0.0, float(rect.get("w", 0.0))))
        h = min(1.0 - y, max(0.0, float(rect.get("h", 0.0))))
        rect = {"x": round(x, 4), "y": round(y, 4), "w": round(w, 4), "h": round(h, 4)} if w > 0.01 and h > 0.01 else None
    else:
        rect = None
    clamp = lambda v: round(min(1.0, max(0.0, float(v or 0.0))), 3)  # noqa: E731
    game = lab.get("game")
    return {"activity": lab["activity"], "activity_confidence": clamp(lab.get("activity_confidence")),
            "video_present": bool(lab.get("video_present")),
            "video_rect": rect, "game": str(game)[:60] if game else None, "hud_event": lab["hud_event"],
            "hud_event_confidence": clamp(lab.get("hud_event_confidence"))}


# --------------------------------------------------------------------------- travail
def image_size(path: Path) -> tuple[int, int]:
    try:
        from PIL import Image

        with Image.open(path) as im:  # lit seulement l'en-tete
            return im.size
    except Exception:  # noqa: BLE001
        return 2560, 1440


def collect(screens: Path, done: set[str]) -> list[tuple[Path, dict, str]]:
    jobs = []
    for img in sorted(p for p in screens.glob("*") if p.suffix.lower() in IMAGE_TYPES):
        side = img.with_suffix(".json")
        meta = {}
        if side.exists():
            try:
                meta = json.loads(side.read_text(encoding="utf-8"))
            except ValueError:
                meta = {}
        sha = sha1_file(img)
        if sha not in done:
            jobs.append((img, meta, sha))
    return jobs


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--screens", default=str(dataset_dir() / "screens"))
    ap.add_argument("--out", default=str(OUT_DIR / "labels.jsonl"))
    ap.add_argument("--provider", default="openai", choices=list(DEFAULT_MODELS))
    ap.add_argument("--model", default="")
    ap.add_argument("--detail", default="high", choices=["low", "high", "auto"], help="OpenAI : finesse de l'image")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--yes", action="store_true", help="ne pas demander de confirmation")
    ap.add_argument("--max-usd", type=float, default=5.0, help="refuse de lancer au-dela de cette estimation")
    ap.add_argument("--price-in", type=float, default=None)
    ap.add_argument("--price-out", type=float, default=None)
    ap.add_argument("--pause", type=float, default=0.2, help="s entre deux appels")
    a = ap.parse_args(argv)
    low_priority()
    model = a.model or DEFAULT_MODELS[a.provider]
    out = Path(a.out)
    done = {str(d.get("sha1")) for d in read_jsonl(out) if d.get("label")}
    jobs = collect(Path(a.screens), done)
    if a.limit > 0:
        jobs = jobs[: a.limit]
    sample_prompt = build_prompt(jobs[0][1] if jobs else {})
    w, h = image_size(jobs[0][0]) if jobs else (2560, 1440)
    est = estimate(a.provider, model, len(jobs), a.detail, a.price_in, a.price_out, len(sample_prompt), w, h)
    usd = "inconnu (prix du modele non renseigne : --price-in/--price-out)" if est["usd"] is None else f"~{est['usd']:.4f} $"
    print(f"{len(jobs)} image(s) a etiqueter ({len(done)} deja faites) avec {a.provider}:{model}")
    print(f"estimation : ~{est['tokens_in_per_image']} jetons d'entree + ~{est['tokens_out_per_image']} de sortie "
          f"par image -> {usd} (estimation grossiere)")
    if a.dry_run:
        if jobs:
            req = openai_request(model, sample_prompt, "<base64 %d octets>" % jobs[0][0].stat().st_size, a.detail,
                                 media_type(jobs[0][0])) \
                if a.provider == "openai" else {"model": model, "prompt": sample_prompt, "schema": SCHEMA}
            print("1re requete (image omise) :")
            print(json.dumps(req, ensure_ascii=False, indent=1)[:6000])
        print("--dry-run : aucun appel.")
        return 0
    if not jobs:
        return 0
    if est["usd"] is not None and est["usd"] > a.max_usd:
        print(f"estimation au-dela de --max-usd {a.max_usd} : utilise --limit ou --max-usd.")
        return 2
    key = get_key(a.provider)
    if not key and a.provider != "anthropic":
        print(f"cle absente : definis {' ou '.join(KEY_ENV[a.provider])} (variable d'environnement).")
        return 2
    if not a.yes:
        if input("Lancer ? [o/N] ").strip().lower() not in ("o", "oui", "y", "yes"):
            return 1
    ok = err = 0
    for i, (img, meta, sha) in enumerate(jobs):
        b64 = base64.b64encode(img.read_bytes()).decode("ascii")
        mime = media_type(img)
        prompt = build_prompt(meta)
        rec = {"file": img.name, "sha1": sha, "provider": a.provider, "model": model, "time": int(time.time()),
               "meta": meta}
        for attempt in range(4):
            try:
                if a.provider == "openai":
                    lab, usage = call_openai(model, prompt, b64, a.detail, key, mime)
                elif a.provider == "anthropic":
                    lab, usage = call_anthropic(model, prompt, b64, key, mime)
                else:
                    lab, usage = call_gemini(model, prompt, b64, key, mime)
                rec["label"] = validate(lab)
                rec["usage"] = usage
                break
            except urllib.error.HTTPError as exc:
                if exc.code in (429, 500, 502, 503, 504) and attempt < 3:
                    time.sleep(2.0 * 2 ** attempt)
                    continue
                rec["error"] = f"http {exc.code}"
                break
            except Exception as exc:  # noqa: BLE001
                rec["error"] = type(exc).__name__ + ": " + str(exc)[:120]
                break
        if "label" in rec:
            ok += 1
            append_jsonl(out, rec)  # reprise : une ligne par image terminee
        else:
            err += 1
            print(f"  {img.name} : {rec['error']}")
        if (i + 1) % 20 == 0:
            print(f"  {i + 1}/{len(jobs)}")
        time.sleep(a.pause)
    print(f"termine : {ok} etiquetee(s), {err} erreur(s) -> {out}")
    return 0 if err == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
