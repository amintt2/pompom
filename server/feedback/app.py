"""Serveur de contributions ANONYMES de Pompom (auto-heberge, ex. Coolify).

Les joueurs qui l'activent (reglage « Aider à améliorer Pompom (anonyme) », desactive par defaut) envoient
uniquement des EMBEDDINGS (vecteurs de 128 a 1024 nombres calcules sur leur PC) + l'etiquette corrigee + la
tache + le nom du processus au premier plan + l'identifiant du modele. Jamais d'image, de titre de fenetre,
de texte saisi, d'identifiant de joueur.

Vie privee cote serveur :
  - aucun journal des requetes (uvicorn --no-access-log ; ce module ne journalise rien) ;
  - l'adresse IP ne sert qu'a la limite de debit, en memoire, hachee avec un sel aleatoire renouvele toutes les
    24 h (jamais ecrite) ; aucun cookie ; seule la DATE de reception (jour UTC) est gardee, pas l'heure ;
  - schema strict : tout champ inconnu fait rejeter la requete entiere.

Variables d'environnement :
  ADMIN_TOKEN         jeton des routes d'administration (export, stats) ; vide = routes desactivees
  DB_PATH             /data/feedback.db
  MAX_BODY            taille max d'une requete en octets (262144)
  MAX_ITEMS           exemples max par requete (32)
  RATE_LIMIT          requetes max par IP et par fenetre, "N/secondes" (120/3600)
  TRUSTED_PROXY_HOPS  nombre de proxys de confiance devant le serveur (1 avec Coolify/Traefik ; 0 = direct)
  RETENTION_DAYS      duree de conservation des exemples (730)

Routes :
  POST /v1/contrib                 {"schema": 1, "client": "0.5.4-beta", "items": [...]}  -> {accepted, duplicates}
  GET  /v1/health                  -> {ok}
  GET  /v1/export?since=ID|JOUR    (Authorization: Bearer ADMIN_TOKEN) -> application/x-ndjson
  GET  /v1/stats                   (Authorization: Bearer ADMIN_TOKEN) -> comptes
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import sqlite3
import struct
import threading
import time
from typing import Literal

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator

# --------------------------------------------------------------------------- vocabulaire (= jeu et service)
TASKS: dict[str, tuple[str, ...]] = {
    "activity": ("video", "music", "game", "code", "ai", "email", "docs", "spreadsheet", "chat", "social",
                 "reading", "design", "browse", "meeting", "other"),
    "game_event": ("goal", "goal_against", "kill", "death", "round_won", "round_lost", "match_won", "match_lost",
                   "none"),
    "field_kind": ("email", "phone", "address", "url", "search", "name", "code", "chat_message", "username",
                   "number", "date", "other"),
}
VISION_CLASSES = ("", "game", "video", "work_code", "work_docs", "browse", "chat", "other")
MODES = ("", "normal", "game", "fs", "comp", "meeting", "video")


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


DB_PATH = os.environ.get("DB_PATH", "/data/feedback.db")
ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "")
MAX_BODY = _env_int("MAX_BODY", 262144)
MAX_ITEMS = max(1, min(256, _env_int("MAX_ITEMS", 32)))
TRUSTED_PROXY_HOPS = max(0, _env_int("TRUSTED_PROXY_HOPS", 1))
RETENTION_DAYS = max(1, _env_int("RETENTION_DAYS", 730))
_rl = os.environ.get("RATE_LIMIT", "120/3600").split("/")
RATE_N = int(_rl[0]) if _rl[0].isdigit() else 120
RATE_WINDOW = int(_rl[1]) if len(_rl) > 1 and _rl[1].isdigit() else 3600


# --------------------------------------------------------------------------- schema strict
class Pet(BaseModel):
    """Ce que le compagnon avait decide (vocabulaire ferme, pas de texte libre)."""

    model_config = ConfigDict(extra="forbid", strict=True)
    situation: str = Field("", pattern=r"^[a-z_]{0,32}$")
    vision: str = ""
    mode: str = ""
    event: str = Field("", pattern=r"^[a-z_]{0,24}$")

    @model_validator(mode="after")
    def _check(self):
        if self.vision not in VISION_CLASSES:
            raise ValueError("vision")
        if self.mode not in MODES:
            raise ValueError("mode")
        return self


class Item(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    task: Literal["activity", "game_event", "field_kind"]
    label: str = Field(max_length=32)
    app: str = Field("", pattern=r"^([a-z0-9][a-z0-9._+ -]{0,39})?$")
    model_id: str = Field(pattern=r"^[a-z0-9][a-z0-9._:-]{2,63}$")
    model_version: str = Field(pattern=r"^[a-z0-9._-]{1,32}$")
    dim: int = Field(ge=128, le=1024)
    dtype: Literal["float16", "float32"]
    emb: str = Field(max_length=5600)  # 1024 float32 en base64 = 5464 caracteres
    pet: Pet = Field(default_factory=Pet)

    @model_validator(mode="after")
    def _check(self):
        if self.label not in TASKS[self.task]:
            raise ValueError("label")
        try:
            raw = base64.b64decode(self.emb, validate=True)
        except (ValueError, TypeError):
            raise ValueError("emb") from None
        size = 2 if self.dtype == "float16" else 4
        if len(raw) != self.dim * size:
            raise ValueError("emb length")
        vals = struct.unpack("<%d%s" % (self.dim, "e" if size == 2 else "f"), raw)
        if not all(math.isfinite(v) for v in vals):
            raise ValueError("emb finite")
        norm = math.sqrt(sum(v * v for v in vals))
        if not 0.9 <= norm <= 1.1:  # vecteurs normalises L2 (tolerance float16)
            raise ValueError("emb norm")
        return self


class Contrib(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, populate_by_name=True)
    version: Literal[1] = Field(alias="schema")
    client: str = Field(pattern=r"^[0-9A-Za-z.+-]{1,24}$")
    items: list[Item] = Field(min_length=1, max_length=MAX_ITEMS)


# --------------------------------------------------------------------------- stockage
class Store:
    def __init__(self, path: str) -> None:
        if path != ":memory:":
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.lock = threading.Lock()
        with self.lock:
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.execute("PRAGMA synchronous=NORMAL")
            self.db.execute("PRAGMA busy_timeout=5000")
            self.db.execute("""CREATE TABLE IF NOT EXISTS contrib (
                id INTEGER PRIMARY KEY AUTOINCREMENT, day TEXT NOT NULL, task TEXT NOT NULL, label TEXT NOT NULL,
                app TEXT NOT NULL, model_id TEXT NOT NULL, model_version TEXT NOT NULL, dim INTEGER NOT NULL,
                dtype TEXT NOT NULL, emb TEXT NOT NULL, pet TEXT NOT NULL, client TEXT NOT NULL, h TEXT NOT NULL UNIQUE)""")
            self.db.execute("CREATE INDEX IF NOT EXISTS contrib_day ON contrib(day)")
        self._purged = ""

    def add(self, c: Contrib) -> tuple[int, int]:
        day = time.strftime("%Y-%m-%d", time.gmtime())
        acc = dup = 0
        with self.lock:
            self.db.execute("BEGIN")
            try:
                for it in c.items:
                    h = hashlib.sha256(f"{it.task}|{it.label}|{it.model_id}|{it.emb}".encode()).hexdigest()
                    cur = self.db.execute(
                        "INSERT OR IGNORE INTO contrib(day,task,label,app,model_id,model_version,dim,dtype,emb,pet,client,h)"
                        " VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                        (day, it.task, it.label, it.app, it.model_id, it.model_version, it.dim, it.dtype, it.emb,
                         json.dumps(it.pet.model_dump(), separators=(",", ":")), c.client, h))
                    if cur.rowcount:
                        acc += 1
                    else:
                        dup += 1
                self.db.execute("COMMIT")
            except Exception:
                self.db.execute("ROLLBACK")
                raise
            if self._purged != day:  # retention, une fois par jour
                self._purged = day
                limit = time.strftime("%Y-%m-%d", time.gmtime(time.time() - RETENTION_DAYS * 86400))
                self.db.execute("DELETE FROM contrib WHERE day < ?", (limit,))
        return acc, dup

    def export(self, since: str, limit: int):
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", since):
            q, arg = "day >= ?", since
        else:
            q, arg = "id > ?", int(since or 0)
        with self.lock:
            rows = self.db.execute(
                f"SELECT id,day,task,label,app,model_id,model_version,dim,dtype,emb,pet,client FROM contrib WHERE {q}"
                " ORDER BY id LIMIT ?", (arg, limit)).fetchall()
        return rows

    def stats(self) -> dict:
        with self.lock:
            one = lambda sql: {k: n for k, n in self.db.execute(sql).fetchall()}  # noqa: E731
            return {
                "total": self.db.execute("SELECT COUNT(*) FROM contrib").fetchone()[0],
                "by_task": one("SELECT task, COUNT(*) FROM contrib GROUP BY task"),
                "by_label": one("SELECT task || ':' || label, COUNT(*) FROM contrib GROUP BY task, label"),
                "by_model": one("SELECT model_id || '@' || model_version, COUNT(*) FROM contrib GROUP BY 1"),
                "by_day": one("SELECT day, COUNT(*) FROM contrib GROUP BY day ORDER BY day DESC LIMIT 30"),
                "top_apps": one("SELECT app, COUNT(*) AS n FROM contrib GROUP BY app ORDER BY n DESC LIMIT 20"),
            }


# --------------------------------------------------------------------------- limite de debit (memoire seule)
class RateLimiter:
    """Compteurs par IP HACHEE (HMAC, sel aleatoire renouvele toutes les 24 h), jamais ecrits sur disque."""

    def __init__(self, n: int, window: int) -> None:
        self.n, self.window = n, window
        self.lock = threading.Lock()
        self._rotate()

    def _rotate(self) -> None:
        self.salt = secrets.token_bytes(32)
        self.salt_t = time.monotonic()
        self.buckets: dict[str, list[float]] = {}

    def hit(self, ip: str) -> float:
        """0 si accepte, sinon secondes avant de reessayer."""
        now = time.monotonic()
        with self.lock:
            if now - self.salt_t > 86400 or len(self.buckets) > 200_000:
                self._rotate()
            k = hmac.new(self.salt, ip.encode(), hashlib.sha256).hexdigest()[:24]
            b = self.buckets.get(k)
            if b is None or now - b[0] >= self.window:
                self.buckets[k] = [now, 1]
                return 0.0
            if b[1] >= self.n:
                return max(1.0, self.window - (now - b[0]))
            b[1] += 1
            return 0.0


def client_ip(request: Request) -> str:
    xff = request.headers.get("x-forwarded-for", "")
    if TRUSTED_PROXY_HOPS > 0 and xff:
        parts = [p.strip() for p in xff.split(",") if p.strip()]
        if parts:
            return parts[-TRUSTED_PROXY_HOPS] if len(parts) >= TRUSTED_PROXY_HOPS else parts[0]
    return request.client.host if request.client else "?"


# --------------------------------------------------------------------------- application
def create_app(db_path: str | None = None, admin_token: str | None = None) -> FastAPI:
    store = Store(db_path or DB_PATH)
    token = ADMIN_TOKEN if admin_token is None else admin_token
    limiter = RateLimiter(RATE_N, RATE_WINDOW)
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    app.state.store = store
    app.state.limiter = limiter

    def err(code: int, msg: str, headers: dict | None = None) -> JSONResponse:
        return JSONResponse({"error": msg}, status_code=code, headers={"cache-control": "no-store", **(headers or {})})

    def admin_ok(request: Request) -> bool:
        auth = request.headers.get("authorization", "")
        return bool(token) and auth.startswith("Bearer ") and hmac.compare_digest(auth[7:].encode(), token.encode())

    @app.get("/v1/health")
    def health():
        return JSONResponse({"ok": True}, headers={"cache-control": "no-store"})

    @app.post("/v1/contrib")
    async def contrib(request: Request):
        wait = limiter.hit(client_ip(request))
        if wait > 0:
            return err(429, "rate_limited", {"retry-after": str(int(math.ceil(wait)))})
        if not request.headers.get("content-type", "").lower().startswith("application/json"):
            return err(415, "json_only")
        try:
            declared = int(request.headers.get("content-length", "0") or 0)
        except ValueError:
            return err(400, "length")
        if declared > MAX_BODY:
            return err(413, "too_large")
        raw = b""
        async for chunk in request.stream():
            raw += chunk
            if len(raw) > MAX_BODY:
                return err(413, "too_large")
        try:
            c = Contrib.model_validate_json(raw)
        except ValidationError as exc:
            # on ne renvoie que le chemin du champ fautif, jamais la valeur recue
            locs = sorted({".".join(str(p) for p in e.get("loc", ())) for e in exc.errors()})[:5]
            return err(400, "invalid: " + ", ".join(locs))
        acc, dup = store.add(c)
        return JSONResponse({"accepted": acc, "duplicates": dup}, headers={"cache-control": "no-store"})

    @app.get("/v1/export")
    def export(request: Request, since: str = "0", limit: int = 10000):
        if not admin_ok(request):
            return err(401 if token else 503, "admin")
        if not re.fullmatch(r"\d{1,12}|\d{4}-\d{2}-\d{2}", since):
            return err(400, "since")
        rows = store.export(since, max(1, min(100000, limit)))
        cols = ("id", "day", "task", "label", "app", "model_id", "model_version", "dim", "dtype", "emb", "pet", "client")

        def gen():
            for r in rows:
                d = dict(zip(cols, r))
                d["pet"] = json.loads(d["pet"])
                yield json.dumps(d, separators=(",", ":")) + "\n"

        last = str(rows[-1][0]) if rows else since
        return StreamingResponse(gen(), media_type="application/x-ndjson",
                                 headers={"x-next-since": last, "cache-control": "no-store"})

    @app.get("/v1/stats")
    def stats(request: Request):
        if not admin_ok(request):
            return err(401 if token else 503, "admin")
        return JSONResponse(store.stats(), headers={"cache-control": "no-store"})

    @app.exception_handler(404)
    async def not_found(_request, _exc):
        return err(404, "not_found")

    return app


app = create_app() if os.environ.get("POMPOM_FEEDBACK_NO_APP") != "1" else None

if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app:app", host="0.0.0.0", port=int(os.environ.get("PORT", "8000")), access_log=False,
                server_header=False, date_header=False, proxy_headers=False)
