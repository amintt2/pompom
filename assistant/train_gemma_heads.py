"""(DEVELOPPEMENT, dev\\gemma_venv) Nouvelles tetes de decision sur EmbeddingGemma 2 FIGE (aucun ajustement de
l'encodeur), entrainees sur CPU, en priorite basse, 4 fils.

  dev\\gemma_venv\\Scripts\\python.exe train_gemma_heads.py --text            # field_kind + text_kind
  dev\\gemma_venv\\Scripts\\python.exe train_gemma_heads.py --vision          # activite + « video dans la case »
  dev\\gemma_venv\\Scripts\\python.exe train_gemma_heads.py --vision --encoder siglip   # meme chose sur SigLIP

TEXTE (memes donnees que les tetes stuntd actuelles, pour une comparaison loyale) :
  data/train_field_kind.jsonl, data/train_text_kind.jsonl (data/gen_train.py) ; 20 % de fin mis de cote
  (comme stuntd) pour la temperature et le SEUIL (certitude a 99 % d'accord = stuntd.metrics.operating_point).
  Choix de la variante (MLP sur le vecteur 768, MLP sur Matryoshka 256, attention apprise sur les jetons) sur
  data/test.jsonl (ancien jeu test, vocabulaire disjoint) - JAMAIS sur eval_v2.
VISION : ecrans synthetiques d'ENTRAINEMENT (dev/vision_train, data/gen_screens.py --split train), jamais l'eval.
  activite : une tete par strategie (moyenne des vecteurs des recadrages) ; cases 3x3 : « video » / « interface ».
  Les vecteurs sont calcules par l'encodeur ONNX d'execution (meme quantification que le service).
Sorties : models/gemma2/text_heads.npz, models/gemma2/vision_heads.npz (ou dev/heads_vision/siglip_vision_heads.npz),
          rapport dev/heads_report_<partie>.json.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import math
import os
import sys
import time
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "4")
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "data"))
CACHE = ROOT / "dev" / "cache"

import numpy as np  # noqa: E402

from pompom_assist import rules  # noqa: E402
from pompom_assist.heads import describe_field, text_kind_input  # noqa: E402
from pompom_assist.np_heads import save_heads  # noqa: E402

TEXT_LABELS = {"field_kind": list(rules.FIELD_KINDS), "text_kind": list(rules.CONTENT_TYPES) + ["none"]}


def lowprio() -> None:
    from pompom_assist.lowprio import set_low_priority

    assert set_low_priority(idle=True)  # IDLE : les jeux passent avant


# --------------------------------------------------------------------------- calibration (= stuntd.train.metrics)
def certainty(p: np.ndarray) -> np.ndarray:
    ent = -(p * np.log(np.clip(p, 1e-12, 1))).sum(-1)
    return np.round(np.clip(1 - ent / math.log(p.shape[-1]), 0, 1), 9)


def softmax(x, t=1.0):
    z = x / t
    z = z - z.max(-1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(-1, keepdims=True)


def fit_temperature(logits: np.ndarray, y: np.ndarray) -> float:
    def nll(s):
        z = logits * s
        z = z - z.max(1, keepdims=True)
        return float((np.log(np.exp(z).sum(1)) - z[np.arange(len(y)), y]).mean())

    lo, hi = 0.05, 20.0
    for _ in range(60):
        a, b = lo + (hi - lo) / 3, hi - (hi - lo) / 3
        if nll(a) <= nll(b):
            hi = b
        else:
            lo = a
    return 1.0 / ((lo + hi) / 2)


def operating_point(logits: np.ndarray, y: np.ndarray, t: float, target: float = 0.99):
    p = softmax(logits, t)
    pred = p.argmax(1)
    conf = certainty(p)
    order = np.argsort(-conf, kind="stable")
    best = None
    correct = 0
    for i, j in enumerate(order, start=1):
        correct += pred[j] == y[j]
        if i < len(order) and conf[order[i]] == conf[j]:
            continue
        agree = correct / i
        if agree >= target and (best is None or i / len(order) >= best[1]):
            best = (float(conf[j]), i / len(order), agree)
    return best  # (seuil, couverture, accord) ou None


# --------------------------------------------------------------------------- tetes (PyTorch, CPU)
def train_head(X, y, k, Xtok=None, attn=False, hidden=256, epochs=40, lr=1e-3, seed=0, noise=0.02):
    import torch
    import torch.nn as nn

    torch.manual_seed(seed)
    torch.set_num_threads(4)
    d = X.shape[1] if not attn else Xtok[0].shape[1]

    class Head(nn.Module):
        def __init__(self):
            super().__init__()
            self.q = nn.Parameter(torch.zeros(d)) if attn else None
            self.ln = nn.LayerNorm(d)
            self.l1 = nn.Linear(d, hidden)
            self.drop = nn.Dropout(0.2)
            self.l2 = nn.Linear(hidden, k)

        def forward(self, x, toks=None, mask=None):
            if attn:
                a = (toks @ self.q) / math.sqrt(d)
                a = a.masked_fill(~mask, -1e9).softmax(-1)
                x = (a[..., None] * toks).sum(1)
            return self.l2(self.drop(torch.relu(self.l1(self.ln(x)))))

    h = Head()
    opt = torch.optim.AdamW(h.parameters(), lr=lr, weight_decay=0.01)
    yt = torch.tensor(y)
    if attn:
        n = max(t.shape[0] for t in Xtok)
        T = torch.zeros(len(Xtok), n, d)
        M = torch.zeros(len(Xtok), n, dtype=torch.bool)
        for i, t in enumerate(Xtok):
            T[i, : len(t)] = torch.from_numpy(t.astype(np.float32))
            M[i, : len(t)] = True
    Xt = torch.from_numpy(X.astype(np.float32)) if X is not None else None
    loss_f = nn.CrossEntropyLoss(label_smoothing=0.05)
    idx = np.arange(len(y))
    rng = np.random.default_rng(seed)
    for _ in range(epochs):
        h.train()
        rng.shuffle(idx)
        for i in range(0, len(idx), 64):
            b = torch.from_numpy(idx[i:i + 64])
            if attn:
                tb = T[b] + noise * torch.randn_like(T[b])
                out = h(None, tb, M[b])
            else:
                xb = Xt[b] + noise * torch.randn_like(Xt[b])
                out = h(xb)
            loss = loss_f(out, yt[b])
            opt.zero_grad()
            loss.backward()
            opt.step()
    h.eval()
    arrs = {"ln_g": h.ln.weight.detach().numpy(), "ln_b": h.ln.bias.detach().numpy(),
            "W1": h.l1.weight.detach().numpy().T, "b1": h.l1.bias.detach().numpy(),
            "W2": h.l2.weight.detach().numpy().T, "b2": h.l2.bias.detach().numpy()}
    if attn:
        arrs["q"] = h.q.detach().numpy()
    return arrs


def np_forward(arrs, X=None, toks=None):
    from pompom_assist.np_heads import NpHead

    h = NpHead(arrs, "", {"dim": arrs["W1"].shape[0]})
    if toks is not None:
        X = np.stack([h.pool(t.astype(np.float32)) for t in toks])
    return np.stack([h.logits(x) for x in X]) if X is not None else None


# --------------------------------------------------------------------------- texte
def read_jsonl(p: Path) -> list[dict]:
    return [json.loads(line) for line in p.open(encoding="utf-8") if line.strip()]


def val_rows(site: str, with_rules: bool = False) -> list[tuple]:
    """Validation de selection : ancien data/test.jsonl (vocabulaire disjoint de l'entrainement).
    with_rules : ajoute (reponse des regles, regles sures ?) pour simuler le mode hybride."""
    from pompom_assist.decider import Decider

    dec = Decider(None)
    out = []
    for r in read_jsonl(ROOT / "data" / "test.jsonl"):
        if site == "field_kind":
            g = rules.guess_field_kind(r["field"])
            row = (describe_field(r["field"]), r["kind"], None, g.kind, g.confidence >= dec.kind_threshold)
        else:
            types = [rules.content_type(c) for c in r["candidates"]]
            if not types:
                continue
            want = r["types"][r["best"]] if r["best"] >= 0 else "none"
            s = dec.suggest(r["field"], r["candidates"])
            rule_ans = types[s.index] if s.index >= 0 else "none"
            row = (text_kind_input(r["kind"], r["field"], types), want, list(dict.fromkeys(types)) + ["none"], rule_ans, False)
        out.append(row if with_rules else row[:3])
    return out


def embed_cached(enc, name: str, texts: list[str]):
    """(vecteurs [n,768], jetons [liste de [n_i,768]]) avec cache disque."""
    CACHE.mkdir(parents=True, exist_ok=True)
    p = CACHE / f"gemma_text_{name}.npz"
    if p.exists():
        z = np.load(p)
        if int(z["n"]) == len(texts):
            off, tok = z["off"], z["tok"]  # (z["tok"] relit tout le tableau a chaque acces : une seule fois)
            return z["vec"], [tok[off[i]:off[i + 1]] for i in range(len(texts))]
    t0 = time.time()
    vec, toks = enc.embed_texts(texts, prefix=True, batch=16, return_tokens=True)
    off = np.cumsum([0] + [len(t) for t in toks])
    np.savez(p, n=len(texts), vec=vec, tok=np.concatenate(toks).astype(np.float16), off=off)
    print(f"  {name}: {len(texts)} textes encodes en {time.time() - t0:.0f} s")
    return vec, [t.astype(np.float16) for t in toks]


def run_text(args) -> None:
    from pompom_assist.gemma_onnx import GemmaEncoder

    enc = GemmaEncoder(gpu=False, threads=4)
    report, heads = {}, {}
    for site, labels in TEXT_LABELS.items():
        rows = read_jsonl(ROOT / "data" / f"train_{site}.jsonl")
        texts = [r["text"] for r in rows]
        y = np.array([labels.index(r["answer"]) for r in rows])
        vec, toks = embed_cached(enc, f"train_{site}", texts)
        cut = int(len(rows) * 0.8)  # derniers 20 % mis de cote (comme stuntd)
        vr = val_rows(site, with_rules=True)
        vvec, vtoks = embed_cached(enc, f"val_{site}", [v[0] for v in vr])
        vy = np.array([labels.index(v[1]) for v in vr])
        vmask = np.array([[(lab in v[2]) if v[2] else True for lab in labels] for v in vr])
        v_rule_ok = np.array([v[3] == v[1] for v in vr])
        v_rule_sure = np.array([v[4] for v in vr])
        variants = {"mlp768": dict(dim=768), "mlp256": dict(dim=256), "attn768": dict(dim=768, attn=True)}
        res = {}
        for name, v in variants.items():
            def feats(V, T):
                if v.get("attn"):
                    return None, [t.astype(np.float32) for t in T]
                X = V[:, : v["dim"]]
                return X / np.linalg.norm(X, axis=1, keepdims=True), None

            Xtr, Ttr = feats(vec[:cut], toks[:cut])
            t0 = time.time()
            arrs = train_head(Xtr, y[:cut], len(labels), Xtok=Ttr, attn=bool(v.get("attn")), epochs=args.epochs)
            Xho, Tho = feats(vec[cut:], toks[cut:])
            lg = np_forward(arrs, Xho, Tho)
            temp = fit_temperature(lg, y[cut:])
            op = operating_point(lg, y[cut:], temp)
            Xv, Tv = feats(vvec, vtoks)
            lv = np_forward(arrs, Xv, Tv)
            pv = softmax(lv, temp) * vmask
            val_acc = float((pv.argmax(1) == vy).mean())
            conf = certainty(softmax(lv, temp))
            sure = conf >= (op[0] if op else 2)
            res[name] = {"holdout_acc": round(float((lg.argmax(1) == y[cut:]).mean()), 4), "temperature": round(temp, 4),
                         "threshold": op[0] if op else None, "coverage": round(op[1], 3) if op else 0.0,
                         "agreement": round(op[2], 4) if op else None, "val_acc_old_test": round(val_acc, 4),
                         "val_coverage": round(float(sure.mean()), 3),
                         "val_acc_when_sure": round(float((pv.argmax(1) == vy)[sure].mean()), 4) if sure.any() else None,
                         # mode hybride simule : regles si elles sont sures, sinon la tete si ELLE est sure, sinon regles
                         "val_hybrid": round(float(np.where(v_rule_sure, v_rule_ok, np.where(sure, pv.argmax(1) == vy, v_rule_ok)).mean()), 4),
                         "train_s": round(time.time() - t0, 1)}
            res[name]["_arrs"] = arrs
            print(f"  {site:10} {name:8} {json.dumps({k: v2 for k, v2 in res[name].items() if k != '_arrs'})}")
        # choix sur la VALIDATION (ancien test) en mode hybride simule, puis precision de la tete seule
        best = max(res, key=lambda n: (res[n]["val_hybrid"], res[n]["val_acc_old_test"]))
        b = res[best]
        meta = {"labels": labels, "temperature": b["temperature"], "threshold": b["threshold"],
                "dim": 768 if best != "mlp256" else 256, "variant": best, "coverage": b["coverage"],
                "agreement": b["agreement"], "n_train": cut, "encoder": "google/embeddinggemma-2 (fige)",
                "prompt": "Classification"}
        heads[site] = (b["_arrs"], meta)
        report[site] = {n: {k: v2 for k, v2 in r.items() if k != "_arrs"} for n, r in res.items()}
        report[site]["chosen"] = best
        print(f"  -> {site}: {best}")
    out = ROOT / "models" / "gemma2" / "text_heads.npz"
    if out.exists():  # garde la tete « secret » (--secret) si elle existe deja
        z = np.load(out)
        old = json.loads(str(z["meta"]))
        if "secret" in old:
            heads["secret"] = ({k.split(".", 1)[1]: z[k] for k in z.files if k.startswith("secret.")}, old["secret"])
    save_heads(out, heads)
    (ROOT / "dev" / "heads_report_text.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    print(f"-> {out}")


# --------------------------------------------------------------------------- champs secrets (option)
# Libelles d'ENTRAINEMENT, ecrits a part : aucun n'est identique a un libelle secret d'eval_v2 (verifie plus bas),
# volontairement en francais/anglais seulement (on mesure si l'encodeur generalise a Passwort, Senha...).
SECRET_TRAIN = [
    "Saisir le mot de passe", "Votre mot de passe", "Mot de passe (8 caractères minimum)", "Répétez le mot de passe",
    "Mot de passe administrateur", "Mot de passe du compte", "Choisissez un mot de passe", "Code secret de la carte",
    "Code d'activation", "Code OTP reçu", "Entrez le code de sécurité", "Clé privée", "Token d'API", "Secret client",
    "Code à usage unique", "Code de connexion reçu par e-mail", "Numéro de CB", "16 chiffres de la carte",
    "Date d'expiration et cryptogramme", "Code PIN de la carte SIM", "Mot de passe du réseau sans fil", "Clé WPA",
    "Code de validation", "Saisissez votre code confidentiel", "Code d'authentification", "Clé secrète TOTP",
    "Phrase secrète du portefeuille", "Les 24 mots de récupération", "Mot de passe de déverrouillage",
    "Enter your password", "Your password", "Password (min. 8 characters)", "Repeat password", "Admin password",
    "Account password", "Create a password", "Card PIN", "Activation code", "OTP code", "Enter the security code",
    "Private key", "API token", "Client secret", "One-time code", "Login code sent by email", "Credit card number",
    "16-digit card number", "Expiry date and CVV", "SIM PIN", "Wireless network password", "WPA key",
    "Validation code", "Enter your confidential code", "Two-factor authentication code", "TOTP secret",
    "Wallet passphrase", "Your 24 recovery words", "Unlock password", "Security answer: mother's maiden name",
    "Réponse secrète", "Secret answer", "Access token", "Bearer token", "SSH key passphrase", "Master key",
]


def run_secret(args) -> None:
    import random

    from gen_train import BROWSERS, SERVICE_SITES, SHOP_SITES  # noqa: E402

    from pompom_assist.gemma_onnx import GemmaEncoder

    sys.path.insert(0, str(ROOT / "data"))
    import gen_eval_v2 as ge

    eval_norm = {ge.norm(s) for s, _ in ge.SECRETS}
    assert not any(ge.norm(s) in eval_norm for s in SECRET_TRAIN), "fuite vers eval_v2"
    rng = random.Random(3)
    pos = []
    for lab in SECRET_TRAIN:
        for _ in range(4):
            proc = rng.choice(BROWSERS + ["steam.exe", "outlook.exe"])
            site = rng.choice(SHOP_SITES + SERVICE_SITES)
            f = {"process": proc, "window_title": f"{rng.choice(['Connexion', 'Sécurité', 'Paiement', 'Sign in', 'Account'])} - {site}",
                 "control_type": "edit", "name": lab if rng.random() < 0.85 else "",
                 "automation_id": rng.choice(["", "", "field_3", "secretInput", "codeField"]),
                 "help_text": rng.choice(["", "", "••••••", "XXXX"])}
            if not f["name"]:
                f["name"] = lab
            pos.append(describe_field(f))
    enc = GemmaEncoder(gpu=False, threads=4)
    neg_rows = read_jsonl(ROOT / "data" / "train_field_kind.jsonl")
    neg_vec = np.load(CACHE / "gemma_text_train_field_kind.npz")["vec"]  # vecteurs deja calcules (--text)
    assert len(neg_vec) == len(neg_rows)
    pos_vec = enc.embed_texts(pos, prefix=True)
    X = np.concatenate([pos_vec, neg_vec])
    y = np.array([1] * len(pos_vec) + [0] * len(neg_vec))
    rng2 = np.random.default_rng(0)
    perm = rng2.permutation(len(y))
    cut = int(len(y) * 0.8)
    tr, ho = perm[:cut], perm[cut:]
    arrs = train_head(X[tr][:, :256] / np.linalg.norm(X[tr][:, :256], axis=1, keepdims=True), y[tr], 2, epochs=args.epochs)
    def feats(V):
        V = V[:, :256]
        return V / np.linalg.norm(V, axis=1, keepdims=True)
    lg = np_forward(arrs, feats(X[ho]))
    temp = fit_temperature(lg, y[ho])
    p = softmax(lg, temp)[:, 1]
    vvec = np.load(CACHE / "gemma_text_val_field_kind.npz")["vec"]
    pv = softmax(np_forward(arrs, feats(vvec)), temp)[:, 1]
    neg_scores = np.concatenate([p[y[ho] == 0], pv])
    thr = float(max(0.5, np.quantile(neg_scores, 0.999) + 1e-4, pv.max() + 1e-4))
    rep = {"n_pos": int(len(pos_vec)), "n_neg": int(len(neg_vec)), "temperature": round(temp, 4), "threshold": round(thr, 4),
           "holdout_recall": round(float((p[y[ho] == 1] >= thr).mean()), 4),
           "holdout_false_pos": round(float((p[y[ho] == 0] >= thr).mean()), 4), "val_false_pos": round(float((pv >= thr).mean()), 4)}
    print("  secret :", rep)
    out = ROOT / "models" / "gemma2" / "text_heads.npz"
    from pompom_assist.np_heads import load_heads

    z = np.load(out)
    old = json.loads(str(z["meta"]))
    keep = {name: ({k.split(".", 1)[1]: z[k] for k in z.files if k.startswith(name + ".")}, m) for name, m in old.items() if name != "secret"}
    keep["secret"] = (arrs, {"labels": ["field", "secret"], "temperature": temp, "threshold": None, "dim": 256,
                             "secret_threshold": thr, "variant": "mlp256", "n_train": int(cut)})
    save_heads(out, keep)
    load_heads(out)
    (ROOT / "dev" / "heads_report_secret.json").write_text(json.dumps(rep, indent=1), encoding="utf-8")
    print(f"-> {out}")


# --------------------------------------------------------------------------- vision
def run_vision(args) -> None:
    from eval_v2_vision import CLASSES, encode_all, load_set, make_eyes

    from pompom_assist import vision_strategies as vs

    folder = ROOT / "dev" / "vision_train"
    rows = load_set(folder, args.limit)
    eyes = make_eyes(args.encoder, gpu=False, threads=4)
    emb = encode_all(args.encoder, eyes, rows, "train")
    rng = np.random.default_rng(0)
    perm = rng.permutation(len(rows))
    cut = int(len(rows) * 0.8)
    tr, ho = [rows[i] for i in perm[:cut]], [rows[i] for i in perm[cut:]]
    heads, report = {}, {}
    if args.encoder == "gemma2":
        # echelle du zero-shot (cosinus -> logits) ajustee sur les ecrans d'ENTRAINEMENT : sert au melange avec
        # l'a priori du processus dans la chaine du service (vision.ACT_TEMPERATURE = 2 est applique en plus)
        from pompom_assist import vision

        cent = np.stack([(lambda e: e / np.linalg.norm(e))(eyes.embed_texts(vision.ACTIVITIES[c]).mean(0)) for c in CLASSES])
        cos = np.stack([cent @ emb[f"{r['id']}|full"] for r in rows])
        t = fit_temperature(cos, np.array([CLASSES.index(r["cls"]) for r in rows]))
        meta_p = ROOT / "models" / "gemma2" / "gemma2.json"
        meta = json.loads(meta_p.read_text(encoding="utf-8"))
        meta["zs_scale"] = round(vision.ACT_TEMPERATURE / t, 3)
        meta_p.write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
        report["zs_scale"] = meta["zs_scale"]
        print(f"  echelle zero-shot : {meta['zs_scale']}")
    for strat in vs.STRATEGIES:
        def X(rs):
            out = []
            for r in rs:
                keys = vs.strategy_keys(strat, {k.split("|", 1)[1] for k in emb if k.startswith(r["id"] + "|")})
                x = np.mean([emb[f"{r['id']}|{k}"] for k in keys], axis=0)
                out.append(x / np.linalg.norm(x))
            return np.stack(out)

        ytr = np.array([CLASSES.index(r["cls"]) for r in tr])
        yho = np.array([CLASSES.index(r["cls"]) for r in ho])
        arrs = train_head(X(tr), ytr, len(CLASSES), epochs=args.epochs * 2, noise=0.01)
        lg = np_forward(arrs, X(ho))
        temp = fit_temperature(lg, yho)
        op = operating_point(lg, yho, temp, 0.95)
        heads[f"activity:{strat}"] = (arrs, {"labels": CLASSES, "temperature": temp, "threshold": op[0] if op else None,
                                             "dim": X(tr[:1]).shape[1], "n_train": cut})
        report[strat] = {"holdout_acc": round(float((lg.argmax(1) == yho).mean()), 4), "temperature": round(temp, 3)}
        print(f"  activite {strat:16} {report[strat]}")
    # cases 3x3 : video si la case est couverte a >= 40 % par le lecteur, interface si 0 %, ignoree sinon
    Xt, yt, Xh, yh = [], [], [], []
    for part, (xs, ys) in ((tr, (Xt, yt)), (ho, (Xh, yh))):
        for r in part:
            ov = vs.tile_overlap(r.get("video_rect"), 2560, 1440, 3)
            for i in range(9):
                if ov[i] >= 0.4 or ov[i] == 0:
                    xs.append(emb[f"{r['id']}|g3_{i}"])
                    ys.append(1 if ov[i] >= 0.4 else 0)
    Xt, Xh = np.stack(Xt), np.stack(Xh)
    yt, yh = np.array(yt), np.array(yh)
    arrs = train_head(Xt, yt, 2, epochs=args.epochs * 2, noise=0.01)
    lg = np_forward(arrs, Xh)
    temp = fit_temperature(lg, yh)
    heads["tile_video:g3"] = (arrs, {"labels": ["ui", "video"], "temperature": temp, "threshold": None, "dim": Xt.shape[1],
                                     "n_train": len(yt)})
    report["tile_video:g3"] = {"holdout_acc": round(float((lg.argmax(1) == yh).mean()), 4), "pos_share": round(float(yt.mean()), 3)}
    print(f"  cases video : {report['tile_video:g3']}")
    if args.encoder == "gemma2":
        out = ROOT / "models" / "gemma2" / "vision_heads.npz"
    else:
        out = ROOT / "dev" / "heads_vision" / f"{args.encoder}_vision_heads.npz"
        out.parent.mkdir(parents=True, exist_ok=True)
    save_heads(out, heads)
    (ROOT / "dev" / f"heads_report_vision_{args.encoder}.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    print(f"-> {out}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", action="store_true")
    ap.add_argument("--vision", action="store_true")
    ap.add_argument("--secret", action="store_true", help="tete « champ secret » (garde semantique, option)")
    ap.add_argument("--encoder", default="gemma2", choices=["gemma2", "siglip"])
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    lowprio()
    t0 = time.time()
    if a.text:
        run_text(a)
    if a.secret:
        run_secret(a)
    if a.vision:
        run_vision(a)
    print(f"{time.time() - t0:.0f} s")


if __name__ == "__main__":
    main()
