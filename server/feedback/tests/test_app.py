"""Tests du serveur de contributions : python -m pytest -q (depuis server/feedback)."""

from __future__ import annotations

import base64
import json
import math
import os
import struct
import sys
from pathlib import Path

import pytest

os.environ["POMPOM_FEEDBACK_NO_APP"] = "1"
os.environ.setdefault("RATE_LIMIT", "5/3600")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app as srv  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

ADMIN = "admin-secret-test"


def emb(dim=768, dtype="float16", seed=1.0, scale=1.0):
    v = [math.sin(seed * (i + 1)) for i in range(dim)]
    n = math.sqrt(sum(x * x for x in v))
    v = [x / n * scale for x in v]
    fmt = "<%d%s" % (dim, "e" if dtype == "float16" else "f")
    return base64.b64encode(struct.pack(fmt, *v)).decode()


def item(**kw):
    d = {"task": "activity", "label": "music", "app": "spotify", "model_id": "siglip-b16-224.fp16",
         "model_version": "e79563a4df40", "dim": 768, "dtype": "float16", "emb": emb(),
         "pet": {"situation": "video_watch", "vision": "video", "mode": "video", "event": ""}}
    d.update(kw)
    return d


def body(*items, **kw):
    d = {"schema": 1, "client": "0.5.4-beta", "items": list(items) or [item()]}
    d.update(kw)
    return d


@pytest.fixture()
def client(tmp_path):
    a = srv.create_app(str(tmp_path / "t.db"), ADMIN)
    with TestClient(a) as c:
        yield c


def post(c, b, ip="1.2.3.4"):
    return c.post("/v1/contrib", content=json.dumps(b), headers={"content-type": "application/json",
                                                                 "x-forwarded-for": ip})


def test_health(client):
    r = client.get("/v1/health")
    assert r.status_code == 200 and r.json() == {"ok": True}
    assert "set-cookie" not in r.headers


def test_accept_and_dedup(client):
    r = post(client, body(item(), item(task="game_event", label="goal", emb=emb(seed=2.0))))
    assert r.status_code == 200, r.text
    assert r.json() == {"accepted": 2, "duplicates": 0}
    r = post(client, body(item()))
    assert r.json() == {"accepted": 0, "duplicates": 1}


def test_float32_and_dims(client):
    assert post(client, body(item(dtype="float32", emb=emb(dtype="float32")))).status_code == 200
    assert post(client, body(item(dim=128, emb=emb(128, seed=3.0)))).status_code == 200
    assert post(client, body(item(dim=1024, emb=emb(1024, seed=4.0)))).status_code == 200


@pytest.mark.parametrize("bad", [
    {"title": "Ma banque - Chrome"},          # champ interdit
    {"image": "AAAA"},
    {"text": "bonjour"},
    {"label": "cinema"},                      # hors vocabulaire
    {"task": "screen"},
    {"label": "goal"},                        # etiquette d'une autre tache
    {"dim": 64, "emb": emb(64)},              # trop petit
    {"dim": 2048, "emb": emb(2048)},          # trop grand
    {"dim": 512},                             # longueur incoherente
    {"emb": "pas du base64 !!"},
    {"emb": emb(scale=3.0)},                  # pas normalise
    {"app": "C:\\Users\\amin\\secret.exe"},   # nom d'appli non nettoye
    {"app": "x" * 60},
    {"model_id": "Bad Model"},
    {"dim": "768"},                           # type non strict
    {"pet": {"situation": "video_watch", "title": "x"}},
    {"pet": {"vision": "porn"}},
    {"pet": {"mode": "spy"}},
])
def test_rejects_invalid_items(client, bad):
    r = post(client, body(item(**bad)))
    assert r.status_code == 400, (bad, r.text)
    assert "secret" not in r.text and "banque" not in r.text  # jamais d'echo des valeurs


def test_rejects_extra_top_level_and_limits(client):
    assert post(client, body(user="amin")).status_code == 400
    assert post(client, body(schema=2)).status_code == 400
    assert post(client, {"schema": 1, "client": "x", "items": []}).status_code == 400
    assert post(client, body(*[item(emb=emb(seed=10 + i)) for i in range(srv.MAX_ITEMS + 1)])).status_code == 400
    r = client.post("/v1/contrib", content=b"x" * (srv.MAX_BODY + 1),
                    headers={"content-type": "application/json", "x-forwarded-for": "9.9.9.9"})
    assert r.status_code == 413
    r = client.post("/v1/contrib", content=b"{}", headers={"content-type": "text/plain", "x-forwarded-for": "9.9.9.8"})
    assert r.status_code == 415


def test_rate_limit_per_ip(client):
    codes = [post(client, body(item(emb=emb(seed=50 + i))), ip="5.5.5.5").status_code for i in range(srv.RATE_N + 1)]
    assert codes[-1] == 429 and all(c == 200 for c in codes[:-1])
    assert post(client, body(item(emb=emb(seed=99.0))), ip="6.6.6.6").status_code == 200  # autre IP


def test_ip_never_stored(client, tmp_path):
    post(client, body(), ip="203.0.113.77")
    store = client.app.state.store
    dump = "\n".join(store.db.iterdump())
    assert "203.0.113.77" not in dump
    assert all("203.0.113.77" not in k for k in client.app.state.limiter.buckets)


def test_admin_routes(client):
    post(client, body(item(), item(task="field_kind", label="email", emb=emb(seed=7.0))))
    assert client.get("/v1/export").status_code == 401
    assert client.get("/v1/stats", headers={"authorization": "Bearer nope"}).status_code == 401
    h = {"authorization": "Bearer " + ADMIN}
    r = client.get("/v1/export?since=0", headers=h)
    assert r.status_code == 200
    rows = [json.loads(x) for x in r.text.splitlines()]
    assert len(rows) == 2 and rows[0]["task"] == "activity" and rows[0]["pet"]["vision"] == "video"
    assert set(rows[0]) == {"id", "day", "task", "label", "app", "model_id", "model_version", "dim", "dtype", "emb",
                            "pet", "client"}
    assert r.headers["x-next-since"] == str(rows[-1]["id"])
    r = client.get(f"/v1/export?since={rows[0]['id']}", headers=h)
    assert len(r.text.splitlines()) == 1
    r = client.get(f"/v1/export?since={rows[0]['day']}", headers=h)
    assert len(r.text.splitlines()) == 2
    assert client.get("/v1/export?since=1;DROP", headers=h).status_code == 400
    s = client.get("/v1/stats", headers=h).json()
    assert s["total"] == 2 and s["by_task"] == {"activity": 1, "field_kind": 1}


def test_admin_disabled_without_token(tmp_path):
    a = srv.create_app(str(tmp_path / "n.db"), "")
    with TestClient(a) as c:
        assert c.get("/v1/stats", headers={"authorization": "Bearer "}).status_code == 503


def test_no_docs(client):
    for p in ("/docs", "/openapi.json", "/redoc"):
        assert client.get(p).status_code == 404


def test_wal_mode(client):
    assert client.app.state.store.db.execute("PRAGMA journal_mode").fetchone()[0] == "wal"


def test_godot_payload_is_accepted(client):
    """Lot produit par le jeu (godot/tests/feedback_test.tscn ecrit %APPDATA%/Pompom/feedback_payload_sample.json)."""
    p = Path(os.environ.get("POMPOM_GODOT_PAYLOAD") or Path(os.environ.get("APPDATA", "~")) / "Pompom" / "feedback_payload_sample.json")
    if not p.exists():
        pytest.skip("lancer d'abord godot/tests/feedback_test.tscn")
    r = client.post("/v1/contrib", content=p.read_bytes(), headers={"content-type": "application/json"})
    assert r.status_code == 200, r.text
    assert r.json()["accepted"] >= 1
