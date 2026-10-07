"""Strategies d'entree pour la vision : quelles parties de l'ecran donner a l'encodeur, et comment combiner.

Utilise par l'evaluation (tests/eval_v2_vision.py), l'entrainement des tetes (train_gemma_heads.py) et, pour
la strategie retenue, par le service. Aucune dependance lourde (numpy + PIL).

  crops(img, fg_rect)    -> {"full": img, "fg": recadrage fenetre au premier plan, "g2_0".."g2_3", "g3_0".."g3_8"}
  tiles -> rectangle     : cases « video » voisines -> rectangle englobant (plus grande composante)
"""

from __future__ import annotations

import numpy as np

GRID3 = 3
GRID2 = 2


def grid_boxes(w: int, h: int, n: int) -> list[tuple[int, int, int, int]]:
    return [(int(c * w / n), int(r * h / n), int((c + 1) * w / n), int((r + 1) * h / n)) for r in range(n) for c in range(n)]


def make_crops(img, fg_rect=None, grids=(2, 3)) -> dict:
    """Recadrages pour toutes les strategies. fg_rect = [x, y, w, h] de la fenetre au premier plan (ou None)."""
    w, h = img.size
    out = {"full": img}
    if fg_rect:
        x, y, fw, fh = fg_rect
        x0, y0 = max(0, x), max(0, y)
        x1, y1 = min(w, x + fw), min(h, y + fh)
        if x1 - x0 > 64 and y1 - y0 > 64 and (x1 - x0) * (y1 - y0) < 0.9 * w * h:
            out["fg"] = img.crop((x0, y0, x1, y1))
    for n in grids:
        for i, b in enumerate(grid_boxes(w, h, n)):
            out[f"g{n}_{i}"] = img.crop(b)
    return out


STRATEGIES = {
    # nom : (recadrages utilises pour l'activite, poids du plein ecran)
    "full": ["full"],
    "full+fg": ["full", "fg"],
    "grid2+full": ["full"] + [f"g2_{i}" for i in range(4)],
    "grid3+full": ["full"] + [f"g3_{i}" for i in range(9)],
    "grid3+full+fg": ["full", "fg"] + [f"g3_{i}" for i in range(9)],
}


def strategy_keys(name: str, available) -> list[str]:
    return [k for k in STRATEGIES[name] if k in available]


def tile_overlap(rect, w: int, h: int, n: int) -> np.ndarray:
    """Part de chaque case couverte par le rectangle (pour fabriquer les etiquettes « video dans la case »)."""
    out = np.zeros(n * n, np.float32)
    if not rect:
        return out
    rx, ry, rw, rh = rect
    for i, (x0, y0, x1, y1) in enumerate(grid_boxes(w, h, n)):
        ix = max(0, min(x1, rx + rw) - max(x0, rx))
        iy = max(0, min(y1, ry + rh) - max(y0, ry))
        out[i] = ix * iy / max(1, (x1 - x0) * (y1 - y0))
    return out


def rect_from_tiles(scores: np.ndarray, w: int, h: int, n: int, thr: float = 0.5) -> list[int] | None:
    """Plus grande composante (4-voisins) de cases au-dessus du seuil -> rectangle englobant [x, y, w, h]."""
    m = (scores.reshape(n, n) >= thr)
    if not m.any():
        return None
    seen = np.zeros_like(m)
    best = None
    for r in range(n):
        for c in range(n):
            if not m[r, c] or seen[r, c]:
                continue
            stack, comp = [(r, c)], []
            seen[r, c] = True
            while stack:
                y, x = stack.pop()
                comp.append((y, x))
                for yy, xx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                    if 0 <= yy < n and 0 <= xx < n and m[yy, xx] and not seen[yy, xx]:
                        seen[yy, xx] = True
                        stack.append((yy, xx))
            sc = sum(scores.reshape(n, n)[p] for p in comp)
            if best is None or sc > best[0]:
                best = (sc, comp)
    ys = [p[0] for p in best[1]]
    xs = [p[1] for p in best[1]]
    x0, y0 = int(min(xs) * w / n), int(min(ys) * h / n)
    x1, y1 = int((max(xs) + 1) * w / n), int((max(ys) + 1) * h / n)
    return [x0, y0, x1 - x0, y1 - y0]


def iou(a, b) -> float:
    if not a or not b:
        return 0.0
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ix = max(0, min(ax + aw, bx + bw) - max(ax, bx))
    iy = max(0, min(ay + ah, by + bh) - max(ay, by))
    inter = ix * iy
    return inter / max(1, aw * ah + bw * bh - inter)


def tile_mean(scores: np.ndarray, rect, w: int, h: int, n: int) -> float:
    """Score video moyen des cases, pondere par leur recouvrement avec un rectangle (confirmation sans passe)."""
    ov = tile_overlap(rect, w, h, n)
    if ov.sum() <= 0:
        return 0.0
    return float((scores * ov).sum() / ov.sum())


def motion_region_any(frames: list, diff_thr: float = 10.0, min_share: float = 0.012):
    """Variante plus large de vision.motion_region : une case compte si elle a change dans AU MOINS une paire
    d'images, puis on dilate d'une case (les zones unies d'une video - ciel, bandes - ne changent pas toujours).
    Renvoie (x0, y0, x1, y1, part_de_l_ecran) en cases 96x54, ou None. A confirmer par les cases de l'encodeur
    (un defilement de page ou un jeu fenetre bougent aussi)."""
    if len(frames) < 3:
        return None
    hits = np.zeros(frames[0].shape, bool)
    for a, b in zip(frames[:-1], frames[1:]):
        hits |= np.abs(b - a) > diff_thr
    m = hits.copy()
    m[1:, :] |= hits[:-1, :]
    m[:-1, :] |= hits[1:, :]
    m[:, 1:] |= hits[:, :-1]
    m[:, :-1] |= hits[:, 1:]
    from .vision import _largest_component

    comp = _largest_component(m)
    if comp is None:
        return None
    x0, y0, x1, y1, n = comp
    h, w = m.shape
    share = (x1 - x0) * (y1 - y0) / (w * h)
    if share < min_share:
        return None
    return x0, y0, x1, y1, share
