"""
Pompom - accessoires "designer toy" (chapeaux, lunettes, cou, dos).

Lancement (headless) :
    blender --background --factory-startup --python blender/build_accessories.py [-- options]

Options (apres "--") :
    --only id1,id2     ne construit que ces accessoires (export + planche de test)
    --nopreview        pas de rendu
    --noexport         pas d'export glb / json (utile avec --only)
    --sheets a,b       ne rend que ces planches

Sorties :
    godot/assets/models/accessories.glb   un Empty racine par accessoire (nom = id)
    godot/data/accessories.json           manifeste
    blender/previews/accessories_*.png    planches de verification (EEVEE)

Conventions : Blender Z = haut, -Y = avant. Chaque racine est a l'origine, rotation/echelle identite.
Un seul materiau par mesh. Materiaux : main / accent / detail (couleurs du joueur), fur_main / fur_accent
(fourrure), et materiaux fixes (gold, silver, white, black, glass, clear_glass, gem_*, pearl, glow,
leather, wood, rubber).
"""
import bpy
import bmesh
import json
import math
import os
import sys
import time

from mathutils import Matrix, Vector, Quaternion

V = Vector
TAU = 2.0 * math.pi
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_GLB = os.path.join(ROOT, "godot", "assets", "models", "accessories.glb")
OUT_JSON = os.path.join(ROOT, "godot", "data", "accessories.json")
BODIES_GLB = os.path.join(ROOT, "godot", "assets", "models", "bodies.glb")
SPECIES_JSON = os.path.join(ROOT, "godot", "data", "species.json")
PREVIEW_DIR = os.path.join(ROOT, "blender", "previews")

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def _arg(name, default=None):
    if name in ARGS:
        i = ARGS.index(name)
        if i + 1 < len(ARGS) and not ARGS[i + 1].startswith("--"):
            return ARGS[i + 1]
        return True
    return default


ONLY = set(_arg("--only").split(",")) if isinstance(_arg("--only"), str) else None
DO_PREVIEW = not _arg("--nopreview", False)
DO_EXPORT = not _arg("--noexport", False)
SHEETS_ONLY = set(_arg("--sheets").split(",")) if isinstance(_arg("--sheets"), str) else None

bpy.ops.wm.read_factory_settings(use_empty=True)
SCENE = bpy.context.scene

# ---------------------------------------------------------------------------
# Materiaux (couleurs de previsualisation ; le jeu remplace par le nom)
# ---------------------------------------------------------------------------
PALETTE = {
    "blanc": "f7f4ee", "noir": "232027", "gris": "9a98a3", "rouge": "e5484d", "corail": "ff7f6e",
    "orange": "ff9f43", "jaune": "ffd23f", "vert": "5cc46b", "menthe": "7ee0c3", "ciel": "7cc8ff",
    "bleu": "3d6fe0", "violet": "9b5de5", "rose": "ff7eb3", "marron": "9c6644",
}


def hex_rgb(h):
    c = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    return tuple(x ** 2.2 for x in c)  # sRGB -> lineaire


# name: (hex, metallic, roughness, extra)
MAT_DEF = {
    "main": ("ff7eb3", 0.0, 0.5, {}), "accent": ("ffd23f", 0.0, 0.5, {}), "detail": ("7cc8ff", 0.0, 0.5, {}),
    "fur_main": ("ff9ec4", 0.0, 0.9, {"fur": True}), "fur_accent": ("f7f4ee", 0.0, 0.9, {"fur": True}),
    "gold": ("f2b84b", 1.0, 0.28, {}), "silver": ("c9ced6", 1.0, 0.25, {}),
    "white": ("f7f4ee", 0.0, 0.55, {}), "black": ("2a272e", 0.0, 0.45, {}),
    "glass": ("26232f", 0.3, 0.06, {"alpha": 0.85}), "clear_glass": ("dff3ff", 0.0, 0.03, {"alpha": 0.22}),
    "gem_red": ("ff2d55", 0.1, 0.05, {}), "gem_blue": ("2f7bff", 0.1, 0.05, {}),
    "gem_green": ("22c76a", 0.1, 0.05, {}), "gem_pink": ("ff74c8", 0.1, 0.05, {}),
    "pearl": ("fbf3ea", 0.15, 0.22, {"coat": True}), "glow": ("ffd96a", 0.0, 0.5, {"emit": 3.0}),
    "leather": ("7a4a2e", 0.0, 0.55, {}), "wood": ("a8774f", 0.0, 0.7, {}), "rubber": ("3a3640", 0.0, 0.8, {}),
}
ALL_MATS = list(MAT_DEF.keys())


def mat(name):
    assert name in MAT_DEF, name
    m = bpy.data.materials.get(name)
    if m is None:
        m = bpy.data.materials.new(name)
        hx, metal, rough, ex = MAT_DEF[name]
        c = hex_rgb(hx)
        m.diffuse_color = (*c, 1.0)
        m.metallic = metal
        m.roughness = rough
        try:
            m.use_nodes = True
        except Exception:
            pass
        b = m.node_tree.nodes.get("Principled BSDF")
        if b is not None:
            b.inputs["Base Color"].default_value = (*c, 1.0)
            b.inputs["Metallic"].default_value = metal
            b.inputs["Roughness"].default_value = rough
    return m


# ---------------------------------------------------------------------------
# Matrices
# ---------------------------------------------------------------------------
I4 = Matrix.Identity(4)


def T(x=0.0, y=0.0, z=0.0):
    if isinstance(x, (tuple, list, Vector)):
        return Matrix.Translation(V(x))
    return Matrix.Translation((x, y, z))


def R(axis, deg):
    return Matrix.Rotation(math.radians(deg), 4, axis)


def S(x, y=None, z=None):
    if y is None:
        y = z = x
    m = Matrix.Identity(4)
    m[0][0], m[1][1], m[2][2] = x, y, z
    return m


def basis(x, y, z, o=(0, 0, 0)):
    """Matrice a partir de 3 axes (colonnes) et d'une origine."""
    m = Matrix.Identity(4)
    for i in range(3):
        m[i][0], m[i][1], m[i][2], m[i][3] = x[i], y[i], z[i], o[i]
    return m


def frame_z(o, z, yhint=(0, 0, 1)):
    """Repere d'origine o dont l'axe Z local = z, Y local proche de yhint."""
    z = V(z).normalized()
    yh = V(yhint)
    if abs(yh.normalized().dot(z)) > 0.98:
        yh = V((0, 1, 0)) if abs(z.y) < 0.9 else V((1, 0, 0))
    x = yh.cross(z).normalized()
    y = z.cross(x).normalized()
    return basis(x, y, z, o)


def face_front(o, yhint=(0, 0, 1), n=(0, -1, 0)):
    """Repere pour une forme 2D (plan XY local, epaisseur Z) regardant vers n (par defaut l'avant -Y)."""
    return frame_z(o, V(n), yhint)


def smoothstep(a, b, x):
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


def lerp(a, b, t):
    return a + (b - a) * t


# ---------------------------------------------------------------------------
# Courbes 2D / 3D
# ---------------------------------------------------------------------------
def fillet(pts, r, n=4, closed=True):
    """Arrondit les coins d'une polyligne (bezier quadratique), r = distance de raccord (scalaire ou liste)."""
    P = [V(p) for p in pts]
    N = len(P)
    out = []
    for i in range(N):
        ri = r[i] if isinstance(r, (list, tuple)) else r
        if (not closed and (i == 0 or i == N - 1)) or ri <= 0:
            out.append(P[i].copy())
            continue
        p, a, b = P[i], P[i - 1], P[(i + 1) % N]
        da, db = a - p, b - p
        d = min(ri, da.length * 0.5, db.length * 0.5)
        p0 = p + da.normalized() * d
        p1 = p + db.normalized() * d
        for k in range(n + 1):
            t = k / n
            out.append((1 - t) ** 2 * p0 + 2 * (1 - t) * t * p + t * t * p1)
    return out


def spline(ctrl, n=8, closed=False):
    """Catmull-Rom uniforme passant par les points de controle."""
    P = [V(p) for p in ctrl]
    N = len(P)
    out = []
    segs = N if closed else N - 1
    for i in range(segs):
        p0 = P[(i - 1) % N] if (closed or i > 0) else 2 * P[0] - P[1]
        p1 = P[i % N]
        p2 = P[(i + 1) % N]
        p3 = P[(i + 2) % N] if (closed or i + 2 < N) else 2 * P[-1] - P[-2]
        for k in range(n):
            t = k / n
            t2, t3 = t * t, t * t * t
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                              + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
    if not closed:
        out.append(P[-1].copy())
    return out


def path_len(P):
    return sum((P[i + 1] - P[i]).length for i in range(len(P) - 1))


def resample(P, n, closed=False):
    """n points regulierement espaces (longueur d'arc). closed : P[0] n'est pas repete."""
    P = [V(p) for p in P]
    if closed:
        P = P + [P[0]]
    L = [0.0]
    for i in range(len(P) - 1):
        L.append(L[-1] + (P[i + 1] - P[i]).length)
    tot = L[-1]
    out = []
    cnt = n if closed else n - 1
    j = 0
    for k in range(n):
        s = tot * k / cnt if cnt > 0 else 0
        while j < len(L) - 2 and L[j + 1] < s:
            j += 1
        seg = max(L[j + 1] - L[j], 1e-9)
        t = (s - L[j]) / seg
        out.append(P[j].lerp(P[j + 1], min(max(t, 0), 1)))
    return out


def path_at(P, s):
    """Point et tangente a la fraction s (0..1) de la longueur."""
    L = [0.0]
    for i in range(len(P) - 1):
        L.append(L[-1] + (P[i + 1] - P[i]).length)
    tgt = s * L[-1]
    for i in range(len(P) - 1):
        if L[i + 1] >= tgt or i == len(P) - 2:
            seg = max(L[i + 1] - L[i], 1e-9)
            t = (tgt - L[i]) / seg
            return P[i].lerp(P[i + 1], min(max(t, 0), 1)), (P[i + 1] - P[i]).normalized()
    return P[-1], (P[-1] - P[-2]).normalized()


def c3(pts, z=0.0):
    return [V((p[0], p[1], z)) for p in pts]


def circle2(r, n=32, cx=0.0, cy=0.0, a0=0.0):
    return [V((cx + math.cos(a0 + TAU * k / n) * r, cy + math.sin(a0 + TAU * k / n) * r)) for k in range(n)]


def ellipse2(rx, ry, n=32, cx=0.0, cy=0.0):
    return [V((cx + math.cos(TAU * k / n) * rx, cy + math.sin(TAU * k / n) * ry)) for k in range(n)]


def rrect2(w, h, r, n=4):
    pts = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
    return fillet(pts, r, n)


def star2(ro, ri, points=5, rnd=0.0, rot=math.pi / 2, n=4):
    pts = []
    for k in range(points * 2):
        a = rot + math.pi * k / points
        r = ro if k % 2 == 0 else ri
        pts.append((math.cos(a) * r, math.sin(a) * r))
    if rnd > 0:
        return fillet(pts, [rnd if k % 2 == 0 else rnd * 0.6 for k in range(points * 2)], n)
    return [V(p) for p in pts]


def heart2(size, n=48):
    pts = []
    for k in range(n):
        t = TAU * k / n
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        pts.append(V((x / 16 * size, (y + 2) / 16 * size)))
    return pts


def poly_area(pts):
    a = 0.0
    for i in range(len(pts)):
        x0, y0 = pts[i][0], pts[i][1]
        x1, y1 = pts[(i + 1) % len(pts)][0], pts[(i + 1) % len(pts)][1]
        a += x0 * y1 - x1 * y0
    return a * 0.5


# ---------------------------------------------------------------------------
# Generateurs bmesh (tous prennent bm, M = Matrix 4x4)
# ---------------------------------------------------------------------------
def g_rows(bm, M, rows, closed_v=True, closed_u=False, cap0=False, cap1=False):
    """Maillage a partir d'une liste de rangees de points 3D (meme nombre de points par rangee,
    une rangee de points identiques devient un pole)."""
    vrows = []
    for row in rows:
        row = [V(p) for p in row]
        spread = max((p - row[0]).length for p in row)
        if spread < 1e-7:
            vrows.append([bm.verts.new(M @ row[0])])
        else:
            vrows.append([bm.verts.new(M @ p) for p in row])
    n = max(len(r) for r in vrows)
    pairs = list(zip(vrows[:-1], vrows[1:]))
    if closed_u:
        pairs.append((vrows[-1], vrows[0]))
    rng = n if closed_v else n - 1
    for a, b in pairs:
        for k in range(rng):
            k1 = (k + 1) % n
            if len(a) == 1 and len(b) == 1:
                continue
            if len(a) == 1:
                f = (a[0], b[k1], b[k])
            elif len(b) == 1:
                f = (a[k], a[k1], b[0])
            else:
                f = (a[k], a[k1], b[k1], b[k])
            try:
                bm.faces.new(f)
            except ValueError:
                pass
    if cap0 and len(vrows[0]) > 2:
        try:
            bm.faces.new(list(reversed(vrows[0])))
        except ValueError:
            pass
    if cap1 and len(vrows[-1]) > 2:
        try:
            bm.faces.new(vrows[-1])
        except ValueError:
            pass
    return vrows


def g_loft(bm, M, fn, nu, nv, closed_v=True, warp=None, cap0=False, cap1=False, u_pts=None):
    """Surface parametrique fn(u, v) -> point. Rangees en u, boucles en v."""
    us = u_pts if u_pts is not None else [i / nu for i in range(nu + 1)]
    rows = []
    cnt = nv if closed_v else nv + 1
    for u in us:
        row = [V(fn(u, j / nv)) for j in range(cnt)]
        if warp:
            row = [V(warp(p)) for p in row]
        rows.append(row)
    return g_rows(bm, M, rows, closed_v=closed_v, cap0=cap0, cap1=cap1)


def g_lathe(bm, M, prof, segs=48, mod=None, warp=None, closed_u=False, a0=0.0, a1=None, cap0=False, cap1=False,
            twist=0.0):
    """Revolution d'un profil [(r, z)] autour de Z. mod(a, s, r, z) -> (r, z) pour moduler."""
    prof = [V(p) for p in prof]
    n = len(prof)
    full = a1 is None
    cnt = segs if full else segs + 1
    span = TAU if full else (a1 - a0)
    rows = []
    for i, p in enumerate(prof):
        s = i / max(n - 1, 1)
        row = []
        for k in range(cnt):
            a = a0 + span * k / segs + twist * s
            r, z = p.x, p.y
            if mod is not None and r > 1e-7:
                r, z = mod(a, s, r, z)
            q = V((math.cos(a) * r, math.sin(a) * r, z))
            if warp:
                q = V(warp(q))
            row.append(q)
        rows.append(row)
    return g_rows(bm, M, rows, closed_v=full, closed_u=closed_u, cap0=cap0, cap1=cap1)


def superellipse(phi, p):
    c, s = math.cos(phi), math.sin(phi)
    e = 2.0 / p
    return math.copysign(abs(c) ** e, c), math.copysign(abs(s) ** e, s)


def tube_frames(P, closed=False, hint=None):
    n = len(P)

    def tangent(i):
        if closed:
            return (P[(i + 1) % n] - P[(i - 1) % n]).normalized()
        return (P[min(i + 1, n - 1)] - P[max(i - 1, 0)]).normalized()

    frames = []
    t0 = tangent(0)
    ref = V((0, 0, 1)) if abs(t0.z) < 0.9 else V((1, 0, 0))
    n1 = t0.cross(ref).normalized()
    for i in range(n):
        t = tangent(i)
        if hint is not None:
            h = V(hint(i / max(n - 1, 1), P[i])) if callable(hint) else V(hint)
            n1 = (h - t * h.dot(t))
            if n1.length < 1e-6:
                n1 = t.cross(ref)
            n1.normalize()
        else:
            n1 = (n1 - t * n1.dot(t)).normalized()
        n2 = t.cross(n1).normalized()
        frames.append((t, n1, n2))
    return frames


def g_tube(bm, M, pts, r, segs=12, cap=("round", "round"), closed=False, hint=None, aspect=1.0, p=2.0,
           cap_rings=3, twist=0.0, rmod=None):
    """Tube le long d'une polyligne. r : rayon ou r(t). aspect : largeur relative selon n1 (ou fonction).
    p : exposant de super-ellipse (2 = ellipse, 4 = rectangle arrondi). hint : direction de n1.
    rmod(t, phi) -> facteur multiplicatif du rayon (cotes, plis...)."""
    P = [V(q) for q in pts]
    n = len(P)
    if isinstance(cap, str) or cap is None:
        cap = (cap, cap)
    fr = tube_frames(P, closed, hint)

    def ring(i, scale=1.0, offset=0.0):
        t = i / max(n - 1, 1)
        t_, n1, n2 = fr[i]
        rr = r(t) if callable(r) else r
        asp = aspect(t) if callable(aspect) else aspect
        out = []
        for k in range(segs):
            phi = TAU * k / segs + twist * t
            cx, cy = superellipse(phi, p)
            m = rmod(t, phi) if rmod else 1.0
            out.append(P[i] + t_ * offset + (n1 * cx * asp + n2 * cy) * rr * scale * m)
        return out

    rows = [ring(i) for i in range(n)]
    pre, post = [], []
    if not closed:
        for which, idx, sign in ((0, 0, -1), (1, n - 1, 1)):
            kind = cap[which]
            if kind == "round":
                t = idx / max(n - 1, 1)
                rr = r(t) if callable(r) else r
                extra = []
                for k in range(1, cap_rings + 1):
                    a = (math.pi / 2) * k / cap_rings
                    if k == cap_rings:
                        c = P[idx] + fr[idx][0] * sign * rr
                        extra.append([c] * segs)
                    else:
                        extra.append(ring(idx, math.cos(a), sign * rr * math.sin(a)))
                if which == 0:
                    pre = list(reversed(extra))
                else:
                    post = extra
    rows = pre + rows + post
    g_rows(bm, M, rows, closed_v=True, closed_u=closed,
           cap0=(not closed and cap[0] == "flat"), cap1=(not closed and cap[1] == "flat"))


def g_sphere(bm, M, r=1.0, u=24, v=12):
    bmesh.ops.create_uvsphere(bm, u_segments=u, v_segments=v, radius=r, matrix=M)


def g_ico(bm, M, r=1.0, sub=2):
    bmesh.ops.create_icosphere(bm, subdivisions=sub, radius=r, matrix=M)


def g_cyl(bm, M, r1, r2, depth, segs=24, caps=True):
    bmesh.ops.create_cone(bm, cap_ends=caps, cap_tris=False, segments=segs, radius1=r1, radius2=r2,
                          depth=depth, matrix=M)


def g_torus(bm, M, R_, r_, segs=48, rsegs=12, aspect=1.0, p=2.0):
    pts = [V((math.cos(TAU * k / segs) * R_, math.sin(TAU * k / segs) * R_, 0)) for k in range(segs)]
    g_tube(bm, M, pts, r_, segs=rsegs, closed=True, hint=lambda t, q: V((q.x, q.y, 0)), aspect=aspect, p=p)


def g_cookie(bm, M, outline, depth, bevel=0.0, seg=3, puff=0.0, warp=None):
    """Prisme a partir d'un contour 2D (plan XY local), epaisseur selon Z (centre), bords biseautes.
    puff : bombe la face avant (+Z) par insets successifs."""
    pts = [V((p[0], p[1])) for p in outline]
    if poly_area(pts) < 0:
        pts.reverse()
    tmp = bmesh.new()
    bot = [tmp.verts.new((p.x, p.y, -depth / 2)) for p in pts]
    top = [tmp.verts.new((p.x, p.y, depth / 2)) for p in pts]
    tmp.faces.new(list(reversed(bot)))
    tmp.faces.new(top)
    n = len(pts)
    for k in range(n):
        tmp.faces.new((bot[k], bot[(k + 1) % n], top[(k + 1) % n], top[k]))
    tmp.normal_update()
    if bevel > 0:
        cap_faces = [fc for fc in tmp.faces if abs(fc.normal.z) > 0.99]
        edges = set()
        for fc in cap_faces:
            for e in fc.edges:
                edges.add(e)
        bmesh.ops.bevel(tmp, geom=list(edges), offset=bevel, offset_type="OFFSET", segments=seg, profile=0.5,
                        affect="EDGES", clamp_overlap=True)
    if puff > 0:
        top = [fc for fc in tmp.faces if fc.normal.z > 0.99]
        if top:
            fc = max(top, key=lambda q: q.calc_area())
            span = math.sqrt(max(fc.calc_area(), 1e-8))
            region = [fc]
            for k in range(3):
                bmesh.ops.inset_region(tmp, faces=region, thickness=span * 0.12, depth=puff * (0.5 - k * 0.15))
    bmesh.ops.triangulate(tmp, faces=[fc for fc in tmp.faces if len(fc.verts) > 4], quad_method="BEAUTY",
                          ngon_method="BEAUTY")
    me = bpy.data.meshes.new("tmp")
    tmp.to_mesh(me)
    tmp.free()
    me.transform(M)
    if warp is not None:
        for v in me.vertices:
            v.co = V(warp(V(v.co)))
    bm.from_mesh(me)
    bpy.data.meshes.remove(me)


def g_gem(bm, M, r=1.0, n=8, table=0.55, crown=0.38, pav=0.8, girdle=0.06, sx=1.0):
    """Pierre taillee (brillant simplifie) : table en +Z, pointe en -Z."""
    def P(x, y, z):
        return M @ V((x * sx, y, z))

    a_off = math.pi / n
    tbl = [bm.verts.new(P(math.cos(TAU * k / n + a_off) * r * table, math.sin(TAU * k / n + a_off) * r * table,
                          r * crown)) for k in range(n)]
    gt = [bm.verts.new(P(math.cos(TAU * k / n) * r, math.sin(TAU * k / n) * r, r * girdle)) for k in range(n)]
    gb = [bm.verts.new(P(math.cos(TAU * k / n) * r, math.sin(TAU * k / n) * r, -r * girdle)) for k in range(n)]
    tip = bm.verts.new(P(0, 0, -r * pav))
    bm.faces.new(tbl)
    for k in range(n):
        k1 = (k + 1) % n
        bm.faces.new((gt[k], gt[k1], tbl[k]))
        bm.faces.new((tbl[k], gt[k1], tbl[k1]))
        bm.faces.new((gb[k], gb[k1], gt[k1], gt[k]))
        bm.faces.new((gb[k1], gb[k], tip))


def g_leaf(bm, M, L, W, thick, nu=10, nv=10, cup=0.0, curl=0.0, shape=None, tip=0.6, twist=0.0, side_curl=0.0):
    """Feuille / petale / plume : axe +X (longueur L), largeur Y, epaisseur Z. Section en lentille.
    shape(u) -> largeur relative (0 aux extremites). cup : creusement transversal (vers +Z).
    curl : courbure longitudinale (vers +Z)."""
    if shape is None:
        def shape(u):
            return math.sin(math.pi * (u ** tip)) ** 0.8

    def fn(u, v):
        phi = TAU * v
        w = W * 0.5 * shape(u)
        cx, cy = math.cos(phi), math.sin(phi)
        th = thick * 0.5 * (max(shape(u), 0) ** 0.5) * (1 - 0.3 * u)
        x = u * L
        y = cx * w
        z = cy * th + cup * (cx * cx) * w + curl * L * u * u + side_curl * cx * w * u
        if twist:
            a = twist * u
            y, z = y * math.cos(a) - z * math.sin(a), y * math.sin(a) + z * math.cos(a)
        return (x, y, z)

    g_loft(bm, M, fn, nu, nv)


def g_stitches(bm, path, normal_fn, n, dash=0.35, r=0.0035, lift=0.002, segs=4):
    """Points de couture le long d'une polyligne (dash = fraction de l'espacement)."""
    P = resample(path, max(n * 4, 8))
    L = path_len(P)
    step = L / n
    for k in range(n):
        s = (k + 0.5) / n
        c, t = path_at(P, s)
        nn = V(normal_fn(c)).normalized()
        c = c + nn * lift
        h = step * dash * 0.5
        g_tube(bm, I4, [c - t * h, c + t * h], r, segs=segs, cap_rings=1,
               hint=lambda tt, q: nn, aspect=1.0)


# ---------------------------------------------------------------------------
# Objets
# ---------------------------------------------------------------------------
CUR = {"id": "", "n": 0, "pre": None}


def link(o):
    SCENE.collection.objects.link(o)
    return o


def world(o):
    if o is None:
        return Matrix.Identity(4)
    return world(o.parent) @ o.matrix_basis


def empty(name, parent=None, loc=(0, 0, 0), rot=None):
    e = link(bpy.data.objects.new(name, None))
    e.empty_display_size = 0.05
    if parent is not None:
        e.parent = parent
        W = T(loc) @ (rot if rot is not None else I4)
        if CUR.get("pre") is not None:
            W = CUR["pre"] @ W
        e.matrix_basis = world(parent).inverted() @ W
    else:
        e.location = loc
    return e


def mk(bm, material, parent, name="part", smooth=True, subsurf=0, bevel=0.0, bevel_seg=3, wn=False,
       solid=0.0, solid_off=0.0, recalc=True, even=True):
    if recalc:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    CUR["n"] += 1
    nm = "%s_%s" % (CUR["id"], name)
    me = bpy.data.meshes.new(nm)
    bm.to_mesh(me)
    bm.free()
    if CUR.get("pre") is not None:
        me.transform(CUR["pre"])
    o = link(bpy.data.objects.new(nm, me))
    W = world(parent)
    if W != I4:
        me.transform(W.inverted())
    o.parent = parent
    me.polygons.foreach_set("use_smooth", [smooth] * len(me.polygons))
    me.update()
    if solid:
        s = o.modifiers.new("Solid", "SOLIDIFY")
        s.thickness = solid
        s.offset = solid_off
        s.use_even_offset = even
    if bevel > 0:
        b = o.modifiers.new("Bevel", "BEVEL")
        b.width = bevel
        b.segments = bevel_seg
        b.limit_method = "ANGLE"
        b.angle_limit = math.radians(35)
        b.harden_normals = False
    if subsurf > 0:
        s = o.modifiers.new("Sub", "SUBSURF")
        s.levels = subsurf
        s.render_levels = subsurf
    if wn:
        w = o.modifiers.new("WN", "WEIGHTED_NORMAL")
        w.keep_sharp = True
        w.mode = "FACE_AREA"
    me.materials.append(mat(material))
    return o


def B():
    return bmesh.new()


def part(material, parent, name, gen, *a, **kw):
    """Raccourci : un generateur -> un objet."""
    mk_kw = {k: kw.pop(k) for k in list(kw.keys()) if k in ("smooth", "subsurf", "bevel", "bevel_seg", "wn",
                                                           "solid", "solid_off")}
    bm = B()
    gen(bm, *a, **kw)
    return mk(bm, material, parent, name, **mk_kw)


def mirror_x(M):
    return S(-1, 1, 1) @ M


# ---------------------------------------------------------------------------
# Registre des accessoires
# ---------------------------------------------------------------------------
ITEMS = []


def item(id_, fit, name, price, main, accent, detail, desc, anim=""):
    slot = {"hat": "head", "headphones": "head", "eyes": "face", "mouth": "face", "neck": "neck",
            "scarf": "neck", "back": "back"}[fit]

    def deco(fn):
        ITEMS.append(dict(id=id_, fn=fn, fit=fit, slot=slot, name=name, price=price, main=main, accent=accent,
                          detail=detail, desc=desc, anim=anim))
        return fn
    return deco


# Tete de reference pour les chapeaux : sphere r=0.32 centree en (0,0,-0.30)
HEAD_C = V((0, 0, -0.30))
HEAD_R = 0.32


def head_z(x, y=0.0):
    d = HEAD_R ** 2 - x * x - y * y
    return HEAD_C.z + math.sqrt(max(d, 0.0))


def on_lathe(prof, a, s):
    """Point d'un profil de revolution (liste (r,z)) a la fraction s (longueur) et l'angle a."""
    P = [V((p[0], p[1], 0)) for p in prof]
    c, t = path_at(P, s)
    r, z = c.x, c.y
    pos = V((math.cos(a) * r, math.sin(a) * r, z))
    # normale : perpendiculaire a la tangente du profil, vers l'exterieur
    nr, nz = t.y, -t.x
    if nr < 0:
        nr, nz = -nr, -nz
    nrm = V((math.cos(a) * nr, math.sin(a) * nr, nz)).normalized()
    return pos, nrm


# ===========================================================================
#                                   CHAPEAUX
# ===========================================================================
@item("crown", "hat", "Couronne", 750, "rouge", "blanc", "jaune",
      "Velours, perles et pierres précieuses : pour le roi ou la reine du bureau.")
def build_crown(root):
    # bandeau d'or legerement evase, avec levres arrondies
    prof = fillet([(0.172, 0.012), (0.196, 0.012), (0.212, 0.118), (0.190, 0.118)], 0.006, 3)
    part("gold", root, "band", g_lathe, I4, prof, segs=48, closed_u=True)
    # fourrure d'hermine (fur_accent) a la base + mouchetures noires
    part("fur_accent", root, "ermine", g_torus, T(0, 0, 0.03), 0.198, 0.03, segs=40, rsegs=10, aspect=1.0)
    bm = B()
    for k in range(10):
        a = TAU * k / 10 + TAU / 20
        c = V((math.cos(a) * 0.226, math.sin(a) * 0.226, 0.034))
        out = V((math.cos(a), math.sin(a), 0))
        g_tube(bm, I4, [c + V((0, 0, 0.012)), c + out * 0.006, c + V((0, 0, -0.014)) + out * 0.004],
               lambda t: 0.008 * (1 - 0.6 * t), segs=6, cap_rings=2)
    mk(bm, "black", root, "ermine_spots")
    # rebord superieur perle (petites billes d'or)
    bm = B()
    g_tube(bm, I4, [V((math.cos(a) * 0.211, math.sin(a) * 0.211, 0.118)) for a in [TAU * k / 96 for k in range(96)]],
           0.0068, segs=6, closed=True, rmod=lambda t, phi: 0.8 + 0.35 * abs(math.sin(t * math.pi * 48)))
    mk(bm, "gold", root, "beads")
    # coussin de velours (main) avec capitons entre les arches
    cus = [(0.0, 0.215), (0.08, 0.205), (0.15, 0.17), (0.185, 0.12), (0.188, 0.08)]
    cus = spline(cus, 4)

    def cmod(a, s, r, z):
        return r, z - 0.012 * (0.5 + 0.5 * math.cos(4 * (a - math.pi / 4))) * math.sin(math.pi * min(s * 1.4, 1))
    part("main", root, "cushion", g_lathe, I4, [(p.x, p.y) for p in cus], segs=40, mod=cmod)
    # bouton de capiton au sommet (sous l'orbe)
    # arches filigranees (4) avec rangee de perles
    arch_ctrl = [(0.205, 0.11), (0.212, 0.165), (0.17, 0.228), (0.09, 0.262), (0.0, 0.272)]
    arch2d = spline(arch_ctrl, 8)
    bm_a = B()
    bm_p = B()
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        ca, sa = math.cos(a), math.sin(a)
        pts = [V((ca * p.x, sa * p.x, p.y)) for p in arch2d]
        g_tube(bm_a, I4, resample(pts, 22), 0.0095, segs=8, hint=V((-sa, ca, 0)), aspect=1.5, p=3.0,
               cap=("flat", None))
        # perles sur le dessus de l'arche
        for j in range(4):
            s = 0.14 + j * 0.2
            c, t = path_at(pts, s)
            outn = t.cross(V((-sa, ca, 0))).normalized()
            if outn.z < 0:
                outn = -outn
            g_sphere(bm_p, T(c + outn * 0.014), 0.0098, 9, 6)
    mk(bm_a, "gold", root, "arches")
    mk(bm_p, "pearl", root, "arch_pearls")
    # fleurons : 4 grands (lys arrondi) + 4 petits (pointes a perle)
    bm_f = B()
    bm_fp = B()
    lily = fillet([(0, 0.0), (0.03, 0.0), (0.034, 0.02), (0.05, 0.035), (0.03, 0.05), (0.014, 0.045),
                   (0.0, 0.085), (-0.014, 0.045), (-0.03, 0.05), (-0.05, 0.035), (-0.034, 0.02), (-0.03, 0.0)],
                  0.008, 3)
    small = fillet([(-0.022, 0.0), (0.022, 0.0), (0.0, 0.05)], 0.008, 3)
    for k in range(8):
        a = -math.pi / 2 + k * math.pi / 4
        ca, sa = math.cos(a), math.sin(a)
        rr = 0.205
        Mf = basis(V((-sa, ca, 0)), V((ca * 0.15, sa * 0.15, 1)).normalized(), V((ca, sa, -0.15)).normalized(),
                   (ca * rr, sa * rr, 0.112))
        if k % 2 == 0:
            g_cookie(bm_f, Mf, lily, 0.014, bevel=0.004, seg=1)
            g_sphere(bm_fp, Mf @ T(0, 0.092, 0), 0.012, 12, 7)
        else:
            g_cookie(bm_f, Mf, small, 0.012, bevel=0.0035, seg=1)
            g_sphere(bm_fp, Mf @ T(0, 0.058, 0), 0.0095, 10, 6)
    mk(bm_f, "gold", root, "fleurons", wn=True)
    mk(bm_fp, "pearl", root, "fleuron_pearls")
    # pierres serties (chaton + griffes) sur le bandeau
    gems = [(-90, "gem_red", 0.026), (0, "gem_blue", 0.021), (180, "gem_blue", 0.021), (90, "gem_green", 0.021),
            (-45, "gem_pink", 0.012), (-135, "gem_pink", 0.012), (45, "gem_pink", 0.012), (135, "gem_pink", 0.012)]
    bm_b = B()
    for deg, gm, gr in gems:
        a = math.radians(deg)
        ca, sa = math.cos(a), math.sin(a)
        out = V((ca, sa, -0.15)).normalized()
        Mg = frame_z(V((ca * 0.207, sa * 0.207, 0.068)), out, (0, 0, 1))
        sx = 1.0 if gr < 0.025 else 0.8
        bm = B()
        g_gem(bm, Mg @ T(0, 0, 0.004) @ S(sx, 1, 1), gr, n=8)
        mk(bm, gm, root, "gem", smooth=False)
        g_tube(bm_b, Mg @ S(sx, 1, 1), c3(circle2(gr * 1.08, 16)), gr * 0.18, segs=5, closed=True)
        if gr > 0.015:
            for j in range(4):
                aa = TAU * j / 4 + math.pi / 4
                g_sphere(bm_b, Mg @ T(math.cos(aa) * gr * 0.95 * sx, math.sin(aa) * gr * 0.95, gr * 0.3), gr * 0.2,
                         8, 5)
    mk(bm_b, "gold", root, "bezels")
    # orbe + croix au sommet
    bm = B()
    g_sphere(bm, T(0, 0, 0.292), 0.026, 16, 10)
    g_torus(bm, T(0, 0, 0.292), 0.026, 0.004, segs=32, rsegs=6)
    g_cyl(bm, T(0, 0, 0.27), 0.012, 0.018, 0.012, 16)
    cross = fillet([(-0.006, 0), (0.006, 0), (0.006, 0.02), (0.018, 0.02), (0.018, 0.032), (0.006, 0.032),
                    (0.006, 0.046), (-0.006, 0.046), (-0.006, 0.032), (-0.018, 0.032), (-0.018, 0.02),
                    (-0.006, 0.02)], 0.003, 2)
    g_cookie(bm, face_front(V((0, 0, 0.314))), cross, 0.01, bevel=0.003, seg=2)
    mk(bm, "gold", root, "orb", wn=True)
    bm = B()
    g_sphere(bm, T(0, -0.006, 0.341), 0.0065, 12, 8)
    mk(bm, "pearl", root, "cross_pearl")


@item("top_hat", "hat", "Haut-de-forme", 320, "noir", "rouge", "blanc",
      "Bord roulé, ruban à boucle dorée et plume : l'élégance absolue.")
def build_top_hat(root):
    CUR["pre"] = T(0, 0, 0.035)
    prof = [(0.0, -0.035), (0.150, -0.035), (0.152, 0.07), (0.147, 0.15), (0.162, 0.285), (0.164, 0.30),
            (0.150, 0.312), (0.0, 0.316)]
    prof = fillet(prof, [0, 0.01, 0, 0, 0, 0.012, 0.015, 0], 4, closed=False)
    part("main", root, "crown", g_lathe, I4, [(p.x, p.y) for p in prof], segs=56)
    # bord roule : releve sur les cotes, descend devant/derriere
    sec = fillet([(0.14, 0.0), (0.262, -0.002), (0.284, 0.012), (0.272, 0.026), (0.252, 0.014),
                  (0.14, 0.016)], [0, 0.012, 0.01, 0.01, 0.008, 0], 3)

    def brim_mod(a, s, r, z):
        u = max(0.0, (r - 0.15) / 0.13)
        return r, z + 0.062 * (u ** 2.2) * (math.cos(a) ** 2) - 0.012 * (u ** 2) * (math.sin(a) ** 2)
    part("main", root, "brim", g_lathe, I4, [(p.x, p.y) for p in sec], segs=72, mod=brim_mod, closed_u=True)
    # ruban (accent)
    band = fillet([(0.149, 0.012), (0.1545, 0.012), (0.1555, 0.078), (0.1505, 0.078)], 0.002, 2)
    part("accent", root, "band", g_lathe, I4, [(p.x, p.y) for p in band], segs=56, closed_u=True)
    # boucle doree a l'avant (cadre en tube + ardillon)
    bm = B()
    Mb = frame_z(V((0, -0.157, 0.045)), V((0, -1, 0)), (0, 0, 1))
    loop = [V((p.x, p.y, 0)) for p in rrect2(0.05, 0.05, 0.012, 4)]
    g_tube(bm, Mb, loop, 0.0042, segs=8, closed=True, p=3.0)
    g_tube(bm, Mb, [V((0, -0.022, 0.003)), V((0, 0.022, 0.003))], 0.003, segs=6)
    g_cyl(bm, Mb @ T(0, 0, -0.001), 0.006, 0.006, 0.008, 12)
    mk(bm, "gold", root, "buckle")
    # petit noeud plat sur le cote gauche
    bm = B()
    Mn = frame_z(V((-0.158, 0, 0.045)), V((-1, 0, 0)), (0, 0, 1))
    for sx in (-1, 1):
        g_leaf(bm, Mn @ S(sx, 1, 1) @ T(0.004, 0, 0) @ R("Z", 8), 0.05, 0.045, 0.012, nu=8, nv=10, cup=-0.1,
               shape=lambda u: (math.sin(math.pi * u ** 0.8) ** 0.6) * (0.55 + 0.45 * u))
    g_sphere(bm, Mn @ S(0.016, 0.022, 0.012), 1.0, 14, 8)
    mk(bm, "accent", root, "bow")
    # plume glissee dans le ruban (detail) + rachis blanc
    bm = B()
    nrm = V((-1, 0.25, 0.08)).normalized()
    d = V((-0.05, 0.55, 1.0))
    d = (d - nrm * d.dot(nrm)).normalized()
    Mf = basis(d, nrm.cross(d), nrm, (-0.16, 0.035, 0.035))
    g_leaf(bm, Mf, 0.2, 0.058, 0.01, nu=18, nv=10, curl=0.12, tip=0.7,
           shape=lambda u: (math.sin(math.pi * u ** 0.7) ** 0.7) * (1 - 0.12 * math.sin(u * 36) ** 2))
    mk(bm, "detail", root, "feather")
    bm = B()
    sp = [Mf @ V((u * 0.2, 0, 0.12 * 0.2 * u * u + 0.0045)) for u in [i / 10 for i in range(11)]]
    g_tube(bm, I4, sp, lambda t: 0.0028 * (1 - 0.6 * t), segs=6)
    mk(bm, "white", root, "quill")


@item("cap", "hat", "Casquette", 120, "rouge", "blanc", "blanc",
      "Six panneaux cousus, visière courbée : style décontracté garanti.")
def build_cap(root):
    prof = spline([(0.205, 0.0), (0.204, 0.05), (0.185, 0.11), (0.13, 0.16), (0.06, 0.183), (0.0, 0.188)], 4)
    prof2 = [(p.x, p.y) for p in prof]
    seams = [-math.pi / 2 + k * math.pi / 3 + math.pi / 6 for k in range(6)]

    def seam_mod(a, s, r, z):
        d = min(abs(math.atan2(math.sin(a - sa), math.cos(a - sa))) for sa in seams)
        k = math.exp(-(d / 0.045) ** 2) * min(1.0, s * 6) * (1 - s ** 4)
        return r - 0.005 * k, z - 0.003 * k * s
    part("main", root, "crown", g_lathe, I4, prof2, segs=96, mod=seam_mod)
    # bourrelet interieur visible en bas
    part("main", root, "rim", g_torus, T(0, 0, 0.004), 0.201, 0.0065, segs=64, rsegs=8)
    # coutures doubles le long des panneaux
    bm = B()
    for sa in seams:
        for off in (-0.011, 0.011):
            pts = []
            for j in range(20):
                s = 0.06 + 0.78 * j / 19
                p0, _ = on_lathe(prof2, sa, s)
                rr = max(V((p0.x, p0.y)).length, 0.02)
                p, n = on_lathe(prof2, sa + off / rr, s)
                pts.append(p + n * 0.0015)
            g_stitches(bm, pts, lambda c: (c - V((0, 0, -0.05))).normalized(), 9, dash=0.5, r=0.0026)
    # couture horizontale au-dessus du bourrelet
    pts = [on_lathe(prof2, TAU * k / 80, 0.1)[0] * 1.01 for k in range(81)]
    g_stitches(bm, pts, lambda c: V((c.x, c.y, 0)), 46, dash=0.5, r=0.0026)
    mk(bm, "detail", root, "stitches")
    # bouton du sommet (accent)
    bm = B()
    g_sphere(bm, T(0, 0, 0.19) @ S(1, 1, 0.55), 0.026, 24, 12)
    mk(bm, "accent", root, "button")
    # oeillets d'aeration
    bm = B()
    for sa in seams:
        a = sa + math.pi / 6
        if abs(math.sin(a) + 1) < 0.1:
            continue
        p, n = on_lathe(prof2, a, 0.42)
        g_torus(bm, frame_z(p + n * 0.001, n), 0.008, 0.003, segs=16, rsegs=6)
    mk(bm, "accent", root, "eyelets")
    # visiere courbee (accent)
    a0, a1 = math.radians(-150), math.radians(-30)

    def visor(u, v):
        a = lerp(a0, a1, u)
        ac = (a - (a0 + a1) / 2) / ((a1 - a0) / 2)
        reach = 0.16 * math.sqrt(max(1 - ac * ac, 0)) ** 0.8
        r = 0.19 + reach * v
        z = 0.012 - 0.035 * (ac ** 2) * v - 0.012 * v * v
        return (math.cos(a) * r, math.sin(a) * r, z)
    bm = B()
    g_loft(bm, I4, visor, 20, 6, closed_v=False)
    mk(bm, "accent", root, "visor", solid=0.014, solid_off=0.0, subsurf=1)
    # surpiqures concentriques de la visiere
    bm = B()
    for vv in (0.35, 0.55, 0.75, 0.9):
        pts = [V(visor(0.04 + 0.92 * j / 40, vv)) + V((0, 0, 0.009)) for j in range(41)]
        g_stitches(bm, pts, lambda c: V((0, 0, 1)), int(18 + 14 * vv), dash=0.55, r=0.0024)
    mk(bm, "detail", root, "visor_stitches")
    # etoile brodee sur le panneau avant
    p, n = on_lathe(prof2, -math.pi / 2, 0.33)
    part("detail", root, "logo", g_cookie, frame_z(p + n * 0.002, n, (0, 0, 1)), star2(0.034, 0.015, 5, 0.006),
         0.006, bevel=0.002, seg=2, wn=True)


# ---------------------------------------------------------------------------
# Aides chapeaux
# ---------------------------------------------------------------------------
BAND_C, BAND_R = V((0, 0, -0.40)), 0.44


def headband(parent, material, half_deg=36, w=0.026, th=0.009, name="headband"):
    pts = [BAND_C + V((math.sin(a) * BAND_R, 0, math.cos(a) * BAND_R))
           for a in [math.radians(lerp(-half_deg, half_deg, i / 30)) for i in range(31)]]
    bm = B()
    g_tube(bm, I4, pts, th, segs=12, hint=V((0, 1, 0)), aspect=w / th, p=3.0)
    return mk(bm, material, parent, name)


def band_z(x):
    """hauteur du dessus du serre-tete a l'abscisse x"""
    return BAND_C.z + math.sqrt(max(BAND_R ** 2 - x * x, 0)) + 0.008


def petal_shape(u):
    u = min(max(u, 0.0), 1.0)
    return min(1.0, math.sqrt(u) * math.sqrt(max(1 - u ** 4, 0.0)) / 0.73)


def paddle_shape(u):
    u = min(max(u, 0.0), 1.0)
    return min(1.0, (u * 5) ** 0.5) * math.sqrt(max(1 - u ** 3, 0.0))


def flower(bm_pet, bm_ctr, M, R_, n=5, cup=0.25, curl=0.15, thick=0.012, center_r=None, rot=0.0, width=0.9,
           tilt=12, nu=7, nv=8):
    for k in range(n):
        a = rot + 360.0 * k / n
        Mp = M @ R("Z", a) @ R("Y", -tilt)
        g_leaf(bm_pet, Mp, R_, R_ * width, thick, nu=nu, nv=nv, cup=cup, curl=curl, shape=petal_shape)
    if bm_ctr is not None:
        g_sphere(bm_ctr, M @ T(0, 0, thick * 0.4) @ S(1, 1, 0.6), center_r or R_ * 0.3, 14, 8)


def crescent2(r, n=20):
    pts = []
    for k in range(n + 1):
        a = math.radians(lerp(77, 283, k / n))
        pts.append((math.cos(a) * r, math.sin(a) * r))
    for k in range(1, n):
        a = math.radians(lerp(257, 103, k / n))
        pts.append((0.45 * r + math.cos(a) * r, math.sin(a) * r))
    return fillet(pts, [0.06 * r if (i == 0 or i == n) else 0 for i in range(len(pts))], 3)


def rivet(bm, p, n, r=0.008):
    g_sphere(bm, frame_z(p, n) @ S(1, 1, 0.55), r, 10, 6)


# ---------------------------------------------------------------------------
@item("tiara", "hat", "Diadème", 480, "blanc", "rose", "ciel",
      "Filigrane d'argent, perles et pierre rose en goutte : une vraie princesse.")
def build_tiara(root):
    Rr, z0, ac, SW = 0.19, 0.035, -math.pi / 2, 0.2

    def cyl(sv, z, dr=0.0):
        a = ac + sv / Rr
        return V((math.cos(a) * (Rr + dr), math.sin(a) * (Rr + dr), z0 + z))

    def nrm(sv):
        a = ac + sv / Rr
        return V((math.cos(a), math.sin(a), 0))

    def ztop(sv):
        return 0.035 + 0.1 * math.exp(-(sv / 0.055) ** 2) + 0.03 * math.exp(-((abs(sv) - 0.12) / 0.028) ** 2)

    bm = B()
    g_tube(bm, I4, [cyl(lerp(-SW, SW, i / 40), 0) for i in range(41)], 0.0055, segs=10,
           hint=lambda t, q: V((0, 0, 1)), aspect=1.7)
    g_tube(bm, I4, [cyl(lerp(-SW, SW, i / 90), ztop(lerp(-SW, SW, i / 90))) for i in range(91)], 0.0052, segs=8)
    for sv in (-SW, SW):
        g_tube(bm, I4, [cyl(sv, 0), cyl(sv, ztop(sv))], 0.004, segs=8)
    # gouttes de filigrane
    for sc in (-0.172, -0.135, -0.1, -0.06, 0.06, 0.1, 0.135, 0.172):
        zt = ztop(sc) - 0.01
        w = 0.026 if abs(sc) > 0.05 else 0.03
        pts = []
        for k in range(24):
            t = TAU * k / 24
            x = w / 2 * math.sin(t) * ((1 + math.cos(t)) / 2) ** 0.45
            z = 0.008 + (zt - 0.008) * (1 - math.cos(t)) / 2
            pts.append(cyl(sc + x, z))
        g_tube(bm, I4, pts, 0.0034, segs=6, closed=True)
    # volutes
    for sc in (-0.08, 0.08, -0.155, 0.155):
        sg = 1 if sc > 0 else -1
        pts = []
        for k in range(22):
            t = k / 21
            ang = t * TAU * 1.3
            rr = 0.013 * (1 - 0.75 * t)
            pts.append(cyl(sc + sg * math.cos(ang) * rr, 0.022 + math.sin(ang) * rr))
        g_tube(bm, I4, pts, 0.0024, segs=6)
    # chaton central
    for zc, gr in ((0.062, 0.021), (0.108, 0.009)):
        Mg = frame_z(cyl(0, zc, 0.003), nrm(0), (0, 0, 1))
        sy = 1.25 if gr > 0.015 else 1.0
        g_tube(bm, Mg @ S(1, sy, 1), c3(circle2(gr * 1.1, 24)), gr * 0.16, segs=6, closed=True)
    mk(bm, "silver", root, "filigree")
    bm = B()
    g_gem(bm, frame_z(cyl(0, 0.062, 0.006), nrm(0), (0, 0, 1)) @ S(1, 1.25, 1), 0.021, n=10)
    mk(bm, "gem_pink", root, "gem_main", smooth=False)
    bm = B()
    g_gem(bm, frame_z(cyl(0, 0.108, 0.005), nrm(0), (0, 0, 1)), 0.009, n=8)
    for sv in (-0.12, 0.12):
        g_gem(bm, frame_z(cyl(sv, ztop(sv) - 0.022, 0.005), nrm(sv), (0, 0, 1)), 0.0075, n=8)
    mk(bm, "gem_blue", root, "gem_small", smooth=False)
    # perles
    bm = B()
    for sv in (0.0, -0.12, 0.12):
        g_sphere(bm, T(cyl(sv, ztop(sv) + 0.009)), 0.008, 12, 8)
    for sv in (-0.19, -0.16, -0.08, -0.04, 0.04, 0.08, 0.16, 0.19):
        g_sphere(bm, T(cyl(sv, ztop(sv) + 0.006)), 0.0055, 10, 6)
    for k in range(17):
        sv = lerp(-0.18, 0.18, k / 16)
        g_sphere(bm, T(cyl(sv, 0, 0.007)), 0.0048, 8, 6)
    mk(bm, "pearl", root, "pearls")


@item("beret", "hat", "Béret", 130, "noir", "rouge", "blanc",
      "Doux, plissé et un peu penché : très chic, très artiste.")
def build_beret(root):
    CUR["pre"] = T(0.012, 0, 0.012) @ R("Y", 10)
    prof = spline([(0.0, 0.035), (0.12, 0.03), (0.168, 0.035), (0.212, 0.046), (0.248, 0.066), (0.256, 0.083),
                   (0.236, 0.104), (0.17, 0.122), (0.08, 0.132), (0.0, 0.135)], 3)

    def mod(a, s, r, z):
        k = smoothstep(0.25, 0.55, s) * (1 - smoothstep(0.8, 1.0, s))
        return (r + 0.009 * k * math.sin(5 * a + 0.7) + 0.004 * k * math.sin(9 * a),
                z + 0.007 * k * math.sin(5 * a + 2.0))
    part("main", root, "body", g_lathe, I4, [(p.x, p.y) for p in prof], segs=80, mod=mod)
    part("accent", root, "band", g_torus, T(0, 0, 0.036), 0.168, 0.0115, segs=64, rsegs=10)
    bm = B()
    pts = [V((math.cos(a) * 0.1805, math.sin(a) * 0.1805, 0.037)) for a in [TAU * k / 90 for k in range(91)]]
    g_stitches(bm, pts, lambda c: V((c.x, c.y, 0)), 54, dash=0.5, r=0.0024)
    mk(bm, "detail", root, "stitches")
    bm = B()
    g_tube(bm, I4, spline([(0, 0, 0.13), (0.002, 0, 0.148), (0.012, 0.002, 0.16)], 5),
           lambda t: 0.0075 * (1 - 0.3 * t), segs=10, cap=("flat", "round"))
    mk(bm, "main", root, "stem")


@item("party_hat", "hat", "Chapeau de fête", 90, "ciel", "jaune", "rose",
      "Rayures en spirale, pois, collerette et pompon tout doux : c'est la fête !")
def build_party_hat(root):
    H, zb, rb = 0.4, 0.03, 0.15
    prof = [(rb * (1 - i / 24) + 0.006 * (i / 24), zb + H * (i / 24)) for i in range(25)]
    nst, tw = 8, TAU * 0.55
    bm_m, bm_a = B(), B()
    for k in range(nst):
        g_lathe(bm_m if k % 2 == 0 else bm_a, I4, prof, segs=8, a0=TAU * k / nst, a1=TAU * (k + 1) / nst, twist=tw)
    mk(bm_m, "main", root, "cone_main")
    mk(bm_a, "accent", root, "cone_accent")
    # pois sur les bandes principales
    bm = B()
    for k in range(0, nst, 2):
        amid = TAU * (k + 0.5) / nst
        for s in (0.18, 0.42, 0.66):
            p, n = on_lathe(prof, amid + tw * s, s)
            rr = 0.016 * (1 - 0.6 * s)
            g_cookie(bm, frame_z(p + n * 0.0015, n, (0, 0, 1)), circle2(rr, 16), 0.003, bevel=0.0012, seg=2)
    mk(bm, "white", root, "dots", wn=True)

    # collerette ondulee
    def frill(u, v):
        a = TAU * v
        r = 0.148 + 0.055 * u
        z = zb + 0.006 - 0.012 * u + 0.011 * u * math.sin(18 * a)
        return (math.cos(a) * r, math.sin(a) * r, z)
    bm = B()
    g_loft(bm, I4, frill, 4, 160, closed_v=True)
    mk(bm, "detail", root, "frill", solid=0.005, solid_off=0)
    bm = B()
    g_ico(bm, T(0, 0, zb + H + 0.012), 0.055, 3)
    mk(bm, "fur_accent", root, "pompom")


@item("beanie", "hat", "Bonnet", 130, "menthe", "blanc", "rose",
      "Grosses côtes tricotées, revers épais et pompon tout doux.")
def build_beanie(root):
    prof = spline([(0.198, 0.03), (0.205, 0.1), (0.2, 0.17), (0.165, 0.245), (0.09, 0.29), (0.0, 0.302)], 3)

    def rib(a, s, r, z):
        return r + 0.004 * math.cos(32 * a) * (1 - s ** 2), z
    part("main", root, "dome", g_lathe, I4, [(p.x, p.y) for p in prof], segs=128, mod=rib)
    cuff = fillet([(0.196, 0.0), (0.224, 0.0), (0.228, 0.105), (0.2, 0.105)], 0.012, 2)

    def crib(a, s, r, z):
        return r + 0.0065 * (0.5 + 0.5 * math.cos(32 * a)), z
    part("main", root, "cuff", g_lathe, I4, [(p.x, p.y) for p in cuff], segs=128, mod=crib, closed_u=True)
    bm = B()
    Mt = frame_z(V((0.0, -0.236, 0.055)), V((0, -1, 0)), (0, 0, 1))
    g_cookie(bm, Mt, rrect2(0.055, 0.032, 0.006), 0.004, bevel=0.0015, seg=2)
    mk(bm, "detail", root, "tag", wn=True)
    bm = B()
    g_cookie(bm, Mt @ T(0, 0, 0.0025), heart2(0.012), 0.002, bevel=0.0008, seg=1)
    mk(bm, "white", root, "tag_heart", wn=True)
    bm = B()
    g_ico(bm, T(0, 0, 0.345), 0.075, 3)
    mk(bm, "fur_accent", root, "pompom")


@item("cowboy", "hat", "Chapeau de cowboy", 240, "marron", "noir", "blanc",
      "Calotte pincée, bord relevé, bande cloutée et surpiqûres : Yee-haw !")
def build_cowboy(root):
    CUR["pre"] = T(0, 0, 0.035)
    prof = [(0.0, 0.0)] + list(spline([(0.148, 0.0), (0.152, 0.08), (0.146, 0.15), (0.128, 0.198), (0.07, 0.222),
                                       (0.0, 0.226)], 5))

    def cw(p):
        x, y, z = p
        h = smoothstep(0.12, 0.226, z)
        z -= 0.028 * h * math.exp(-(x / 0.06) ** 2) * (1 - 0.3 * max(0.0, y) / 0.15)
        if y < 0:
            x *= 1 - 0.12 * h * min(1.0, -y / 0.13)
        return (x, y, z)
    part("main", root, "crown", g_lathe, I4, [(p[0], p[1]) for p in prof], segs=64, warp=cw)
    sec = fillet([(0.135, 0.0), (0.31, 0.0), (0.324, 0.008), (0.31, 0.017), (0.135, 0.017)], [0, 0.008, 0.008,
                                                                                                0.008, 0], 3)

    def bmod(a, s, r, z):
        u = max(0.0, (r - 0.14) / 0.18)
        return r, z + 0.11 * u ** 2.2 * math.cos(a) ** 2 - 0.03 * u ** 2 * max(0.0, -math.sin(a)) ** 2

    part("main", root, "brim", g_lathe, I4, [(p.x, p.y) for p in sec], segs=72, mod=bmod, closed_u=True)
    band = fillet([(0.146, 0.012), (0.1535, 0.012), (0.152, 0.052), (0.1445, 0.052)], 0.0025, 2)
    part("accent", root, "band", g_lathe, I4, [(p.x, p.y) for p in band], segs=64, closed_u=True)
    bm = B()
    for k in range(10):
        a = TAU * k / 10 + TAU / 20
        n = V((math.cos(a), math.sin(a), 0))
        rivet(bm, n * 0.1535 + V((0, 0, 0.032)), n, 0.008)
    Mb = frame_z(V((0, -0.155, 0.032)), V((0, -1, 0)), (0, 0, 1))
    g_tube(bm, Mb, c3(rrect2(0.034, 0.03, 0.008)), 0.003, segs=6, closed=True, p=3)
    g_tube(bm, Mb, [V((-0.012, 0, 0.003)), V((0.012, 0, 0.003))], 0.0022, segs=6)
    mk(bm, "silver", root, "studs")
    bm = B()
    pts = []
    for k in range(121):
        a = TAU * k / 120
        r = 0.298
        z = 0.017 + bmod(a, 0, r, 0)[1] + 0.0015
        pts.append(V((math.cos(a) * r, math.sin(a) * r, z)))
    g_stitches(bm, pts, lambda c: V((0, 0, 1)), 84, dash=0.5, r=0.0024)
    mk(bm, "detail", root, "stitches")


@item("chef", "hat", "Toque", 190, "blanc", "bleu", "rouge",
      "Plis bien repassés et chapeau tout bouffant : pour les grands chefs.")
def build_chef(root):
    prof = spline([(0.156, 0.0), (0.158, 0.1), (0.17, 0.18), (0.19, 0.235)], 4)

    def pleat(a, s, r, z):
        return r + 0.009 * (abs(math.sin(8 * a)) ** 0.6 - 0.6) * smoothstep(0.0, 0.6, s), z
    part("main", root, "pleats", g_lathe, I4, [(p.x, p.y) for p in prof], segs=96, mod=pleat)
    top = spline([(0.17, 0.22), (0.228, 0.256), (0.248, 0.3), (0.238, 0.345), (0.19, 0.385), (0.1, 0.405),
                  (0.0, 0.41)], 3)

    def puff(a, s, r, z):
        return r * (1 + 0.055 * math.cos(8 * a) * math.sin(math.pi * min(s * 1.3, 1))), z + 0.008 * math.cos(8 * a) * s
    part("main", root, "puff", g_lathe, I4, [(p.x, p.y) for p in top], segs=96, mod=puff)
    band = fillet([(0.155, 0.02), (0.166, 0.02), (0.166, 0.07), (0.155, 0.07)], 0.003, 2)
    part("accent", root, "band", g_lathe, I4, [(p.x, p.y) for p in band], segs=64, closed_u=True)
    bm = B()
    g_cookie(bm, frame_z(V((0, -0.168, 0.045)), V((0, -1, 0)), (0, 0, 1)) @ T(0, -0.012, 0), heart2(0.024), 0.006,
             bevel=0.002, seg=2)
    mk(bm, "detail", root, "emblem", wn=True)


@item("witch", "hat", "Chapeau de sorcière", 280, "violet", "noir", "vert",
      "Pointe tordue, plis, pièce rapiécée et boucle dorée : un peu de magie sur le bureau.")
def build_witch(root):
    CUR["pre"] = T(0, 0, 0.03)
    sec = fillet([(0.14, 0.0), (0.33, -0.004), (0.343, 0.004), (0.33, 0.013), (0.14, 0.015)], 0.006, 3)

    def bmod(a, s, r, z):
        u = max(0.0, (r - 0.14) / 0.2)
        return r + u * 0.012 * math.sin(5 * a), z + u * u * (0.028 * math.sin(3 * a + 0.6) - 0.02)
    part("main", root, "brim", g_lathe, I4, [(p.x, p.y) for p in sec], segs=72, mod=bmod, closed_u=True)
    prof = spline([(0.152, 0.0), (0.15, 0.06), (0.125, 0.15), (0.085, 0.25), (0.045, 0.34), (0.0, 0.43)], 5)
    prof2 = [(p.x, p.y) for p in prof]

    def wr(a, s, r, z):
        return r + 0.005 * math.sin(z * 70 + 1.5 * math.sin(a * 2)) * smoothstep(0.08, 0.3, z), z

    def bend(p):
        x, y, z = p
        t = smoothstep(0.2, 0.43, z)
        return (x + 0.15 * t ** 2, y + 0.05 * t ** 2, z - 0.06 * t ** 3)
    part("main", root, "cone", g_lathe, I4, prof2, segs=56, mod=wr, warp=bend)
    band = fillet([(0.148, 0.008), (0.157, 0.008), (0.154, 0.056), (0.145, 0.056)], 0.0025, 2)
    part("accent", root, "band", g_lathe, I4, [(p.x, p.y) for p in band], segs=56, closed_u=True)
    bm = B()
    Mb = frame_z(V((0, -0.158, 0.032)), V((0, -1, 0.12)), (0, 0, 1))
    g_tube(bm, Mb, c3(rrect2(0.046, 0.042, 0.006)), 0.0045, segs=6, closed=True, p=4)
    g_tube(bm, Mb, [V((0, -0.017, 0.004)), V((0, 0.017, 0.004))], 0.003, segs=6)
    mk(bm, "gold", root, "buckle")
    # piece rapiecee + points de croix
    p, n = on_lathe(prof2, math.radians(-55), 0.42)
    Mp = frame_z(p + n * 0.002, n, (0, 0, 1)) @ R("Z", 8)
    part("detail", root, "patch", g_cookie, Mp, rrect2(0.062, 0.056, 0.008), 0.004, bevel=0.0015, seg=2, wn=True)
    bm = B()
    for cx, cy in ((-0.024, -0.021), (0.024, -0.021), (-0.024, 0.021), (0.024, 0.021), (0, 0.025), (0, -0.025),
                   (-0.028, 0), (0.028, 0)):
        for d in ((1, 1), (1, -1)):
            g_tube(bm, Mp, [V((cx - d[0] * 0.004, cy - d[1] * 0.004, 0.0035)), V((cx + d[0] * 0.004, cy + d[1] * 0.004,
                                                                                   0.0035))], 0.0012, segs=4, cap_rings=1)
    mk(bm, "white", root, "cross_stitches")


@item("wizard", "hat", "Chapeau de magicien", 300, "bleu", "violet", "jaune",
      "Constellé d'étoiles et de lunes dorées : abracadabra !")
def build_wizard(root):
    CUR["pre"] = T(0, 0, 0.03)
    sec = fillet([(0.14, 0.0), (0.26, -0.004), (0.272, 0.005), (0.26, 0.013), (0.14, 0.015)], 0.006, 3)

    def bmod(a, s, r, z):
        u = max(0.0, (r - 0.14) / 0.13)
        return r, z + u * u * (0.02 * math.sin(4 * a) - 0.012)
    part("main", root, "brim", g_lathe, I4, [(p.x, p.y) for p in sec], segs=64, mod=bmod, closed_u=True)
    prof = spline([(0.15, 0.0), (0.14, 0.08), (0.11, 0.2), (0.07, 0.33), (0.03, 0.45), (0.0, 0.53)], 5)
    prof2 = [(p.x, p.y) for p in prof]

    def bend(p):
        x, y, z = p
        t = smoothstep(0.22, 0.53, z)
        return (x - 0.08 * t ** 2, y + 0.06 * t ** 2, z - 0.02 * t ** 3)
    part("main", root, "cone", g_lathe, I4, prof2, segs=48, warp=bend)
    band = fillet([(0.146, 0.008), (0.156, 0.008), (0.153, 0.052), (0.143, 0.052)], 0.0025, 2)
    part("accent", root, "band", g_lathe, I4, [(p.x, p.y) for p in band], segs=56, closed_u=True)
    bm = B()
    for deg, s, r in ((-100, 0.33, 0.03), (-48, 0.52, 0.021), (-140, 0.6, 0.018), (25, 0.4, 0.025),
                      (150, 0.45, 0.024), (-75, 0.72, 0.014), (95, 0.62, 0.02)):
        p, n = on_lathe(prof2, math.radians(deg), s)
        p = V(bend(p))
        g_cookie(bm, frame_z(p + n * 0.002, n, (0, 0, 1)) @ R("Z", deg * 0.3), star2(r, r * 0.45, 5, r * 0.18),
                 0.006, bevel=0.002, seg=2)
    p, n = on_lathe(prof2, math.radians(-125), 0.25)
    g_cookie(bm, frame_z(p + n * 0.002, n, (0, 0, 1)) @ R("Z", -20), crescent2(0.03), 0.006, bevel=0.002, seg=2)
    tip = V(bend((0, 0, 0.53)))
    g_cookie(bm, T(tip) @ R("X", 90) @ R("Y", 15), star2(0.028, 0.013, 5, 0.005), 0.012, bevel=0.004, seg=2)
    mk(bm, "gold", root, "stars", wn=True)
    # lune sur le ruban
    bm = B()
    g_cookie(bm, frame_z(V((0, -0.155, 0.03)), V((0, -1, 0)), (0, 0, 1)), crescent2(0.017), 0.005, bevel=0.0018,
             seg=2)
    mk(bm, "detail", root, "band_moon", wn=True)


@item("flower_crown", "hat", "Couronne de fleurs", 260, "rose", "blanc", "vert",
      "Une couronne de fleurs fraîches, de feuilles et de gypsophile.")
def build_flower_crown(root):
    Rr, z0 = 0.2, 0.065
    bm = B()
    for ph in (0.0, math.pi):
        pts = []
        for k in range(160):
            a = TAU * k / 160
            rad = V((math.cos(a), math.sin(a), 0))
            pts.append(rad * Rr + rad * 0.008 * math.cos(9 * a + ph) + V((0, 0, z0 + 0.008 * math.sin(9 * a + ph))))
        g_tube(bm, I4, pts, 0.0075, segs=8, closed=True)
    # feuilles
    for k in range(14):
        a = TAU * k / 14 + 0.12
        rad = V((math.cos(a), math.sin(a), 0))
        tang = V((-math.sin(a), math.cos(a), 0)) * (1 if k % 2 else -1)
        nrm = (rad * 0.5 + V((0, 0, 1))).normalized()
        d = (tang + rad * 0.35 + V((0, 0, 0.1))).normalized()
        d = (d - nrm * d.dot(nrm)).normalized()
        g_leaf(bm, basis(d, nrm.cross(d), nrm, rad * Rr + V((0, 0, z0 + 0.004))), 0.09, 0.044, 0.009, nu=8, nv=8,
               cup=0.2, curl=-0.1)
    mk(bm, "detail", root, "vine_leaves")
    bm_m, bm_a, bm_c, bm_w = B(), B(), B(), B()
    for k in range(7):
        a = -math.pi / 2 + TAU * k / 7
        rad = V((math.cos(a), math.sin(a), 0))
        nrm = (rad * 0.65 + V((0, 0, 0.8))).normalized()
        big = k % 2 == 0
        M = frame_z(rad * (Rr + 0.008) + V((0, 0, z0 + 0.016)), nrm, V((0, 0, 1)))
        flower(bm_m if big else bm_a, bm_c, M, 0.068 if big else 0.052, n=5, cup=0.3, curl=0.2,
               rot=k * 17, center_r=0.019 if big else 0.015, thick=0.014)
        # gypsophile
        for j in range(3):
            aa = a + TAU / 14 + (j - 1) * 0.06
            rr = V((math.cos(aa), math.sin(aa), 0))
            g_sphere(bm_w, T(rr * (Rr + 0.01 + 0.006 * j) + V((0, 0, z0 + 0.018 + 0.008 * (j % 2)))), 0.007, 8, 6)
    mk(bm_m, "main", root, "flowers_big")
    mk(bm_a, "accent", root, "flowers_small")
    mk(bm_c, "gold", root, "hearts")
    mk(bm_w, "white", root, "babys_breath")


@item("flower", "hat", "Fleur", 70, "rose", "jaune", "vert",
      "Une grosse fleur qui se balance doucement sur la tête.", anim="sway")
def build_flower(root):
    piv = empty("flower_sway", root, loc=(0, 0, 0.02))
    CUR["pre"] = T(0, 0, 0.03) @ S(1.25)
    M = T(0.03, 0, 0.075) @ R("Y", 20) @ R("X", -12)
    bm = B()
    g_tube(bm, I4, spline([(0, 0, 0.0), (0.012, 0, 0.04), M @ V((0, 0, -0.01))], 5), 0.009, segs=10)
    for ang in (200, 330):
        g_leaf(bm, M @ T(0, 0, -0.012) @ R("Z", ang) @ R("Y", 10), 0.12, 0.06, 0.012, nu=10, nv=10, cup=0.25,
               curl=0.15)
    mk(bm, "detail", piv, "leaves")
    bm = B()
    flower(bm, None, M, 0.13, n=6, cup=0.3, curl=0.25, thick=0.016, width=0.85, tilt=8, nu=10, nv=12)
    mk(bm, "main", piv, "petals")
    bm = B()
    flower(bm, None, M @ T(0, 0, 0.012), 0.085, n=5, cup=0.35, curl=0.5, thick=0.014, width=0.85, rot=36, tilt=20,
           nu=9, nv=10)
    mk(bm, "white", piv, "petals_inner")
    bm = B()
    g_sphere(bm, M @ T(0, 0, 0.028) @ S(1, 1, 0.6), 0.034, 24, 12)
    mk(bm, "accent", piv, "center")
    bm = B()
    for k in range(16):
        rr = 0.026 * math.sqrt((k + 0.5) / 16)
        aa = k * 2.39996
        x, y = math.cos(aa) * rr, math.sin(aa) * rr
        zz = 0.028 + 0.0204 * math.sqrt(max(0, 1 - (rr / 0.034) ** 2))
        g_sphere(bm, M @ T(x, y, zz), 0.0035, 6, 4)
    mk(bm, "gold", piv, "seeds")


@item("ribbon", "hat", "Nœud", 80, "rouge", "rouge", "blanc",
      "Un gros nœud satiné à pois, posé de travers.")
def build_ribbon(root):
    CUR["pre"] = T(0.1, 0.0, 0.09) @ R("Y", 8) @ R("Z", -8)
    bm = B()
    bm_d = B()
    for sx in (-1, 1):
        # boucle : couche avant (y<0) vers l'exterieur, retour par l'arriere ; largeur du ruban selon Z
        def lp(t):
            ang = TAU * t
            c = (1 - math.cos(ang)) / 2
            return V((sx * (0.014 + 0.11 * c ** 0.8), -0.032 * math.sin(ang) * (0.4 + 0.6 * c), 0.028 * c ** 1.5))

        def wid(t):
            c = (1 - math.cos(TAU * t)) / 2
            return 0.022 + 0.05 * c ** 0.7

        def crease(t, phi):
            # deux plis doux sur la largeur du ruban
            c = (1 - math.cos(TAU * t)) / 2
            return 1.0 + 0.35 * c * math.cos(phi * 2) ** 8
        P = [lp(k / 56) for k in range(56)]
        g_tube(bm, I4, P, 0.005, segs=14, closed=True, hint=V((0, 0, 1)),
               aspect=lambda t: wid(t) / 0.005, p=4)
        for t, zo in ((0.2, 0.012), (0.26, -0.022), (0.33, 0.02), (0.36, -0.004), (0.42, -0.03), (0.44, 0.026),
                      (0.3, -0.04)):
            q = lp(1 - t)
            if abs(zo) > wid(1 - t) * 0.8:
                continue
            g_cookie(bm_d, frame_z(q + V((0, -0.0058, zo)), V((0, -1, 0)), (0, 0, 1)), circle2(0.0075, 14), 0.002,
                     bevel=0.0008, seg=1)
    # pans en V
    tail = fillet([(-0.022, 0.0), (0.022, 0.0), (0.024, -0.12), (0.0, -0.1), (-0.024, -0.12)], [0, 0, 0.004, 0.003,
                                                                                               0.004], 3)
    for sx in (-1, 1):
        def wrp(p):
            return (p[0], p[1] + 0.25 * max(0.0, -p[2]) ** 2 * 3, p[2])
        g_cookie(bm, T(0, 0.012, -0.004) @ R("Y", sx * 28) @ R("X", 90), tail, 0.008, bevel=0.0025, seg=2,
                 warp=wrp)
    mk(bm, "main", root, "loops")
    mk(bm_d, "detail", root, "dots", wn=True)
    bm = B()
    g_tube(bm, I4, [V((0, math.sin(a) * 0.024, math.cos(a) * 0.03)) for a in [TAU * k / 32 for k in range(32)]],
           0.006, segs=10, closed=True, hint=V((1, 0, 0)), aspect=0.019 / 0.006, p=4)
    g_sphere(bm, S(0.018, 0.022, 0.028), 1.0, 16, 10)
    mk(bm, "accent", root, "knot")
    bm = B()
    g_cookie(bm, face_front(V((0, -0.033, 0.002))) @ T(0, -0.008, 0), heart2(0.016), 0.005, bevel=0.0018, seg=2)
    mk(bm, "detail", root, "knot_heart", wn=True)


@item("bunny_ears", "hat", "Oreilles de lapin", 210, "blanc", "rose", "rose",
      "Des oreilles toutes douces, dont une un peu pliée.")
def build_bunny_ears(root):
    headband(root, "detail")
    bm_e, bm_i, bm_c = B(), B(), B()
    for sx in (-1, 1):
        x0 = sx * 0.085
        base = V((x0, 0, band_z(x0) - 0.004))
        if sx > 0:
            ctrl = [base, base + V((0.01, 0, 0.1)), base + V((0.035, 0.006, 0.22)), base + V((0.06, 0.012, 0.36))]
        else:
            ctrl = [base, base + V((-0.012, 0, 0.1)), base + V((-0.022, -0.012, 0.2)),
                    base + V((-0.035, -0.09, 0.255)), base + V((-0.045, -0.18, 0.205))]
        P = spline(ctrl, 10)

        def shape(t):
            return 0.42 + 0.58 * math.sin(math.pi * min(1.0, t * 1.1) ** 0.75)

        def rth(t):
            return 0.024 * (0.7 + 0.3 * shape(t))
        g_tube(bm_e, I4, P, rth, segs=16, hint=V((1, 0, 0)), aspect=lambda t: 2.5 * shape(t), p=2.2,
               cap=("round", "round"))
        fr = tube_frames(P, hint=V((1, 0, 0)))
        n = len(P)
        i0, i1 = int(n * 0.1), int(n * 0.9)
        Pin = []
        for i in range(i0, i1):
            t = i / (n - 1)
            Pin.append(P[i] - fr[i][2] * (rth(t) + 0.002))
        g_tube(bm_i, I4, Pin, 0.0065, segs=12, hint=V((1, 0, 0)),
               aspect=lambda t: 2.5 * shape(lerp(i0 / (n - 1), (i1 - 1) / (n - 1), t)) * rth(t) * 0.58 / 0.0065,
               p=2.2)
        g_sphere(bm_c, T(base) @ S(0.034, 0.028, 0.02), 1.0, 16, 10)
    mk(bm_e, "fur_main", root, "ears")
    mk(bm_i, "accent", root, "inner")
    mk(bm_c, "detail", root, "clips")


@item("cat_ears", "hat", "Oreilles de chat", 190, "noir", "rose", "rose",
      "Deux oreilles pointues avec une petite touffe de poils.")
def build_cat_ears(root):
    headband(root, "detail")
    bm_e, bm_i, bm_t = B(), B(), B()
    for sx in (-1, 1):
        x0 = sx * 0.14
        M = T(x0, 0.0, band_z(x0) - 0.012) @ R("Y", sx * 16)
        H = 0.2

        def w(u):
            return 0.1 * (1 - u ** 1.5) ** 0.9 * (1 - u) ** 0.25

        def d(u):
            return 0.034 * (1 - u) ** 0.7 + 0.003

        def ear(u, v):
            phi = TAU * v
            cx, cy = superellipse(phi, 2.4)
            y = d(u) * cy * (0.35 if cy < 0 else 1.0)
            return (w(u) * cx, y + 0.006, u * H + 0.008 * math.sin(math.pi * u))
        g_loft(bm_e, M, ear, 16, 24)

        def inner(u, v):
            uu = u * 0.78
            phi = TAU * v
            cx, cy = superellipse(phi, 2.4)
            return (w(uu) * 0.6 * cx, -0.35 * d(uu) + 0.006 - 0.008 + 0.0065 * cy, uu * H + 0.014)
        g_loft(bm_i, M, inner, 12, 20)
        g_ico(bm_t, M @ T(0, -0.012, 0.035) @ S(0.038, 0.016, 0.036), 1.0, 2)
    mk(bm_e, "fur_main", root, "ears")
    mk(bm_i, "accent", root, "inner")
    mk(bm_t, "fur_accent", root, "tufts")


@item("bear_ears", "hat", "Oreilles d'ourson", 170, "marron", "rose", "marron",
      "Deux oreilles rondes de nounours.")
def build_bear_ears(root):
    headband(root, "detail")
    bm_e, bm_i = B(), B()
    for sx in (-1, 1):
        x0 = sx * 0.16
        c = V((x0, 0, band_z(x0) + 0.07))
        Mr = T(c) @ R("Y", sx * 22)
        g_sphere(bm_e, Mr @ S(0.088, 0.046, 0.084), 1.0, 28, 16)
        g_cookie(bm_i, Mr @ T(0, -0.044, -0.01) @ R("X", 90), ellipse2(0.054, 0.048, 32), 0.012, bevel=0.005, seg=3,
                 puff=0.003)
    mk(bm_e, "fur_main", root, "ears")
    mk(bm_i, "accent", root, "inner")


@item("halo", "hat", "Auréole", 420, "jaune", "jaune", "blanc",
      "Une auréole lumineuse avec ses petites étincelles : un petit ange (presque).")
def build_halo(root):
    M = T(0, 0, 0.14) @ R("X", 10)
    part("glow", root, "ring", g_torus, M, 0.165, 0.022, segs=64, rsegs=14)
    bm = B()
    g_torus(bm, M, 0.1405, 0.0045, segs=64, rsegs=6)
    g_torus(bm, M, 0.1895, 0.0045, segs=64, rsegs=6)
    mk(bm, "gold", root, "rims")
    bm = B()
    for deg, rr, dz in ((-60, 0.028, 0.03), (130, 0.022, 0.04), (35, 0.018, -0.02)):
        a = math.radians(deg)
        p = M @ V((math.cos(a) * 0.2, math.sin(a) * 0.2, dz))
        g_cookie(bm, face_front(p), star2(rr, rr * 0.3, 4, rr * 0.12), 0.008, bevel=0.003, seg=2)
    mk(bm, "glow", root, "sparkles", wn=True)


@item("propeller", "hat", "Casquette hélice", 320, "jaune", "rouge", "bleu",
      "L'hélice tourne quand il est content !", anim="spin")
def build_propeller(root):
    prof = spline([(0.198, 0.0), (0.2, 0.05), (0.18, 0.115), (0.12, 0.17), (0.05, 0.192), (0.0, 0.196)], 4)
    prof2 = [(p.x, p.y) for p in prof]
    bm_m, bm_a = B(), B()
    for k in range(6):
        a0 = -math.pi / 2 + TAU * (k - 0.5) / 6
        g_lathe(bm_m if k % 2 == 0 else bm_a, I4, prof2, segs=12, a0=a0, a1=a0 + TAU / 6)
    mk(bm_m, "main", root, "panels_main")
    mk(bm_a, "accent", root, "panels_accent")
    bm = B()
    for k in range(6):
        a = -math.pi / 2 + TAU * (k - 0.5) / 6
        pts = []
        for j in range(16):
            p, n = on_lathe(prof2, a, 0.05 + 0.9 * j / 15)
            pts.append(p + n * 0.002)
        g_tube(bm, I4, pts, 0.004, segs=6)
    g_torus(bm, T(0, 0, 0.012), 0.2, 0.0085, segs=64, rsegs=8)
    mk(bm, "detail", root, "piping")
    a0, a1 = math.radians(-140), math.radians(-40)

    def visor(u, v):
        a = lerp(a0, a1, u)
        ac = (a - (a0 + a1) / 2) / ((a1 - a0) / 2)
        r = 0.195 + 0.1 * math.sqrt(max(1 - ac * ac, 0)) ** 0.8 * v
        return (math.cos(a) * r, math.sin(a) * r, 0.012 - 0.025 * ac * ac * v - 0.01 * v * v)
    bm = B()
    g_loft(bm, I4, visor, 20, 6, closed_v=False)
    mk(bm, "accent", root, "visor", solid=0.012, solid_off=0, subsurf=1)
    bm = B()
    g_cyl(bm, T(0, 0, 0.212), 0.01, 0.008, 0.04, 16)
    mk(bm, "silver", root, "stem")
    spin = empty("propeller_spin", root, loc=(0, 0, 0.238))
    bm = B()
    g_sphere(bm, T(0, 0, 0.238) @ S(1, 1, 0.75), 0.022, 20, 10)
    g_sphere(bm, T(0, 0, 0.257), 0.008, 10, 6)
    mk(bm, "gold", spin, "hub")
    bm = B()
    for k in range(3):
        g_leaf(bm, T(0, 0, 0.238) @ R("Z", 120 * k) @ T(0.012, 0, 0) @ R("X", 22), 0.17, 0.06, 0.012, nu=12, nv=10,
               shape=paddle_shape, curl=0.05)
    mk(bm, "detail", spin, "blades")


@item("viking", "hat", "Casque viking", 360, "gris", "marron", "blanc",
      "Cornes, bandes rivetées et pointe dorée : pour les guerriers du clavier.")
def build_viking(root):
    prof = spline([(0.205, 0.0), (0.207, 0.06), (0.19, 0.14), (0.13, 0.205), (0.06, 0.235), (0.0, 0.24)], 4)
    prof2 = [(p.x, p.y) for p in prof]
    part("main", root, "dome", g_lathe, I4, prof2, segs=64)
    rim = fillet([(0.2, 0.0), (0.218, 0.0), (0.218, 0.048), (0.2, 0.048)], 0.006, 2)
    part("accent", root, "rim", g_lathe, I4, [(p.x, p.y) for p in rim], segs=64, closed_u=True)
    bm = B()
    bm_r = B()
    for a in (-math.pi / 2, 0.0):
        pts = []
        for j in range(41):
            s = 0.2 + 0.8 * j / 40
            aa = a if j <= 40 else a
            p, n = on_lathe(prof2, a, s)
            pts.append(p + n * 0.003)
        for j in range(40, -1, -1):
            if j == 40:
                continue
            s = 0.2 + 0.8 * j / 40
            p, n = on_lathe(prof2, a + math.pi, s)
            pts.append(p + n * 0.003)
        side = V((-math.sin(a), math.cos(a), 0))
        g_tube(bm, I4, pts, 0.0055, segs=10, hint=side, aspect=3.4, p=4, cap="flat")
        for s in (0.35, 0.55, 0.75):
            for aa in (a, a + math.pi):
                p, n = on_lathe(prof2, aa, s)
                rivet(bm_r, p + n * 0.008, n, 0.007)
    mk(bm, "accent", root, "straps")
    for k in range(14):
        a = TAU * k / 14
        n = V((math.cos(a), math.sin(a), 0))
        rivet(bm_r, n * 0.219 + V((0, 0, 0.024)), n, 0.0075)
    mk(bm_r, "silver", root, "rivets")
    bm_h, bm_g = B(), B()
    for sx in (-1, 1):
        P = spline([(sx * 0.17, 0, 0.1), (sx * 0.26, -0.01, 0.13), (sx * 0.32, -0.02, 0.19), (sx * 0.335, -0.03, 0.27),
                    (sx * 0.315, -0.035, 0.32)], 6)
        rf = lambda t: 0.044 * (1 - t) ** 0.85 + 0.004
        g_tube(bm_h, I4, P, rf, segs=16, cap=("flat", "round"),
               rmod=lambda t, phi: 1 + 0.035 * math.sin(t * 46) * (1 - t))
        fr = tube_frames(P)
        for t in (0.13, 0.21):
            i = int(t * (len(P) - 1))
            g_torus(bm_g, frame_z(P[i], fr[i][0]), rf(t) + 0.003, 0.0055, segs=32, rsegs=8)
    mk(bm_h, "white", root, "horns")
    g_sphere(bm_g, T(0, 0, 0.243) @ S(1, 1, 0.7), 0.022, 16, 10)
    g_cyl(bm_g, T(0, 0, 0.268), 0.01, 0.0, 0.03, 12)
    mk(bm_g, "gold", root, "gold")


@item("pirate", "hat", "Tricorne de pirate", 380, "noir", "jaune", "rouge",
      "Bords relevés galonnés d'or, tête de mort et plume : à l'abordage !")
def build_pirate(root):
    CUR["pre"] = T(0, 0, 0.03)
    prof = spline([(0.0, 0.0), (0.148, 0.0), (0.152, 0.07), (0.13, 0.135), (0.07, 0.165), (0.0, 0.17)], 4)
    prof2 = [(p.x, p.y) for p in prof]
    part("main", root, "crown", g_lathe, I4, prof2, segs=56)

    def brim(u, v):
        a = TAU * v
        f = (1 + math.cos(3 * (a + math.pi / 2))) / 2
        f2 = f ** 1.5
        Lt = 0.2 + 0.05 * f2
        tmax = (math.pi / 2) * (0.93 - 0.6 * f2)
        r, z = 0.135, 0.01
        steps = 14
        for k in range(int(round(u * steps))):
            s = (k + 0.5) / steps
            th = tmax * smoothstep(0.12, 0.7, s)
            r += math.cos(th) * Lt / steps
            z += math.sin(th) * Lt / steps
        return (math.cos(a) * r, math.sin(a) * r, z)
    bm = B()
    g_loft(bm, I4, brim, 12, 132)
    mk(bm, "main", root, "brim", solid=0.012, solid_off=0)
    bm = B()
    edge = [V(brim(1.0, k / 120)) for k in range(120)]
    g_tube(bm, I4, edge, 0.0085, segs=8, closed=True,
           rmod=lambda t, phi: 1.0 + 0.18 * math.sin(t * 120 * 2 + phi * 1.0) ** 2)
    mk(bm, "accent", root, "braid")
    # tete de mort
    p, n = on_lathe(prof2, -math.pi / 2, 0.45)
    Ms = frame_z(p + n * 0.004, n, (0, 0, 1))
    bm = B()
    for sg in (-1, 1):
        g_tube(bm, Ms, [V((-0.04 * sg, -0.038, -0.003)), V((0.04 * sg, 0.034, -0.003))], 0.0055, segs=8)
        for e in ((-0.04 * sg, -0.038), (0.04 * sg, 0.034)):
            d = V((e[0], e[1], 0)).normalized()
            pp = V((e[0], e[1], -0.003))
            side = V((-d.y, d.x, 0))
            g_sphere(bm, Ms @ T(pp + side * 0.006), 0.0072, 10, 6)
            g_sphere(bm, Ms @ T(pp - side * 0.006), 0.0072, 10, 6)
    g_cookie(bm, Ms @ T(0, 0.008, 0.002), circle2(0.029, 28), 0.01, bevel=0.004, seg=2, puff=0.002)
    g_cookie(bm, Ms @ T(0, -0.018, 0.0), rrect2(0.032, 0.022, 0.008), 0.009, bevel=0.003, seg=2)
    mk(bm, "white", root, "skull", wn=True)
    bm = B()
    for sx in (-1, 1):
        g_cookie(bm, Ms @ T(sx * 0.011, 0.004, 0.0085), ellipse2(0.0085, 0.0095, 16), 0.004, bevel=0.0015, seg=1)
    g_cookie(bm, Ms @ T(0, -0.008, 0.0075), fillet([(-0.004, -0.003), (0.004, -0.003), (0.0, 0.004)], 0.001, 1),
             0.004, bevel=0.001, seg=1)
    for x in (-0.007, 0.0, 0.007):
        g_tube(bm, Ms, [V((x, -0.026, 0.0055)), V((x, -0.016, 0.0055))], 0.0012, segs=4, cap_rings=1)
    mk(bm, "black", root, "skull_face", wn=True)
    # plume
    bm = B()
    nrm = V((-1, 0.2, 0.3)).normalized()
    d = V((0.1, 0.6, 1.0))
    d = (d - nrm * d.dot(nrm)).normalized()
    Mf = basis(d, nrm.cross(d), nrm, (-0.12, 0.06, 0.12))
    g_leaf(bm, Mf, 0.24, 0.07, 0.012, nu=18, nv=10, curl=0.25, tip=0.7,
           shape=lambda u: (math.sin(math.pi * u ** 0.7) ** 0.7) * (1 - 0.12 * math.sin(u * 34) ** 2))
    mk(bm, "detail", root, "feather")


@item("sailor", "hat", "Bachi de marin", 200, "blanc", "rouge", "bleu",
      "Le bonnet de marin avec son pompon rouge et ses rubans.")
def build_sailor(root):
    CUR["pre"] = T(0, 0, 0.02)
    band = fillet([(0.152, 0.0), (0.165, 0.0), (0.166, 0.075), (0.153, 0.075)], 0.004, 2)
    part("detail", root, "band", g_lathe, I4, [(p.x, p.y) for p in band], segs=64, closed_u=True)
    top = spline([(0.0, 0.07), (0.15, 0.07), (0.2, 0.082), (0.219, 0.1), (0.2, 0.118), (0.12, 0.128), (0.0, 0.131)],
                 4)
    part("main", root, "top", g_lathe, I4, [(p.x, p.y) for p in top], segs=64)
    bm = B()
    pts = [V((math.cos(a) * 0.22, math.sin(a) * 0.22, 0.1)) for a in [TAU * k / 96 for k in range(97)]]
    g_stitches(bm, pts, lambda c: V((c.x, c.y, 0)), 60, dash=0.5, r=0.0022)
    mk(bm, "detail", root, "stitches")
    bm = B()
    g_ico(bm, T(0, 0, 0.152), 0.045, 3)
    mk(bm, "fur_accent", root, "pompom")
    tail = fillet([(-0.016, 0.0), (0.016, 0.0), (0.017, -0.13), (0.0, -0.115), (-0.017, -0.13)], [0, 0, 0.003, 0.002,
                                                                                                0.003], 3)
    bm = B()
    for sx in (-1, 1):
        def wrp(p):
            return (p[0], p[1] + 2.2 * max(0.0, 0.03 - p[2]) ** 2, p[2])
        g_cookie(bm, T(sx * 0.018, 0.17, 0.04) @ R("X", -48) @ R("Y", sx * 10) @ R("X", 90), tail, 0.006,
                 bevel=0.002, seg=2)
    mk(bm, "detail", root, "tails")
    # ancre doree
    bm = B()
    Ma = frame_z(V((0, -0.17, 0.04)), V((0, -1, 0)), (0, 0, 1))
    g_tube(bm, Ma, [V((0, -0.02, 0.003)), V((0, 0.018, 0.003))], 0.0028, segs=6)
    g_torus(bm, Ma @ T(0, 0.023, 0.003) @ R("X", 90), 0.005, 0.0018, segs=16, rsegs=4)
    g_tube(bm, Ma, [V((-0.009, 0.01, 0.003)), V((0.009, 0.01, 0.003))], 0.002, segs=6)
    arc = [V((math.sin(a) * 0.016, -0.006 - math.cos(a) * 0.014, 0.003)) for a in
           [math.radians(lerp(-75, 75, k / 12)) for k in range(13)]]
    g_tube(bm, Ma, arc, 0.0025, segs=6)
    for sx in (-1, 1):
        g_cookie(bm, Ma @ T(sx * 0.0158, -0.0098, 0.003) @ R("Z", sx * 40), fillet([(-0.004, -0.003), (0.004, -0.003),
                                                                                (0, 0.006)], 0.001, 1), 0.004,
                 bevel=0.001, seg=1)
    mk(bm, "gold", root, "anchor")


@item("grad_cap", "hat", "Toque de diplômé", 280, "noir", "jaune", "noir",
      "Mortier carré et pompon qui se balance : félicitations !", anim="sway")
def build_grad_cap(root):
    prof = spline([(0.168, 0.0), (0.172, 0.05), (0.16, 0.095), (0.0, 0.1)], 4)
    part("main", root, "skull", g_lathe, I4, [(p.x, p.y) for p in prof], segs=56)
    bm = B()
    bmesh.ops.create_cube(bm, size=1.0, matrix=T(0, 0, 0.11) @ R("Z", 4) @ S(0.43, 0.43, 0.016))
    mk(bm, "main", root, "board", smooth=False, bevel=0.004, bevel_seg=2, wn=True)
    bm = B()
    g_sphere(bm, T(0, 0, 0.12) @ S(1, 1, 0.5), 0.02, 16, 8)
    g_tube(bm, I4, spline([(0, 0, 0.122), (0.09, -0.05, 0.121), (0.2, -0.11, 0.12), (0.214, -0.117, 0.11)], 6),
           0.0042, segs=8)
    mk(bm, "accent", root, "button_cord")
    piv = empty("grad_cap_sway", root, loc=(0.214, -0.117, 0.11))
    bm = B()
    g_tube(bm, I4, [V((0.214, -0.117, 0.11)), V((0.215, -0.117, 0.07))], 0.0042, segs=8)
    for k in range(16):
        a = TAU * k / 16
        top = V((0.215 + math.cos(a) * 0.008, -0.117 + math.sin(a) * 0.008, 0.055))
        bot = V((0.215 + math.cos(a) * 0.019, -0.117 + math.sin(a) * 0.019, -0.05 + 0.006 * math.sin(a * 3)))
        g_tube(bm, I4, [top, top.lerp(bot, 0.5) + V((0, 0, 0)), bot], 0.0032, segs=5, cap_rings=2)
    mk(bm, "accent", piv, "tassel")
    bm = B()
    g_cyl(bm, T(0.215, -0.117, 0.062), 0.0105, 0.012, 0.02, 16)
    g_torus(bm, T(0.215, -0.117, 0.052), 0.0118, 0.0025, segs=16, rsegs=6)
    mk(bm, "gold", piv, "tassel_cap")


@item("santa", "hat", "Bonnet de Noël", 220, "rouge", "blanc", "vert",
      "Bonnet tombant, bordure en fourrure, pompon et brin de houx.")
def build_santa(root):
    prof = spline([(0.17, 0.05), (0.162, 0.13), (0.125, 0.23), (0.075, 0.33), (0.025, 0.42), (0.0, 0.45)], 5)

    def wr(a, s, r, z):
        return r + 0.006 * math.sin(z * 55 + a * 2) * smoothstep(0.08, 0.2, z), z

    def bend(p):
        x, y, z = p
        t = smoothstep(0.12, 0.45, z)
        return (x + 0.24 * t ** 2.0, y + 0.03 * t ** 2, z - 0.24 * t ** 3)
    part("main", root, "cone", g_lathe, I4, [(p.x, p.y) for p in prof], segs=56, mod=wr, warp=bend)
    bm = B()
    g_torus(bm, T(0, 0, 0.06), 0.172, 0.045, segs=56, rsegs=14)
    g_ico(bm, T(bend((0, 0, 0.45))) @ T(0.012, 0, -0.012), 0.058, 3)
    mk(bm, "fur_accent", root, "fur")
    bm = B()
    holly = []
    for k in range(40):
        t = TAU * k / 40
        rmod = 1 + 0.14 * abs(math.cos(4 * t)) ** 3
        holly.append((0.034 * math.cos(t) * rmod, 0.016 * math.sin(t) * rmod))
    base = V((-0.09, -0.2, 0.09))
    for ang in (25, 150):
        g_cookie(bm, face_front(base, (0, 0, 1), (-0.3, -1, 0.5)) @ R("Z", ang) @ T(0.03, 0, 0), holly, 0.005,
                 bevel=0.0015, seg=2)
    mk(bm, "detail", root, "holly", wn=True)
    bm = B()
    for off in ((0.0, 0.0, 0.004), (0.014, -0.004, -0.004), (-0.004, -0.006, -0.012)):
        g_sphere(bm, T(base + V(off) + V((0, -0.01, 0))), 0.01, 14, 8)
    mk(bm, "gem_red", root, "berries")


@item("bucket_hat", "hat", "Bob", 150, "jaune", "blanc", "noir",
      "Un bob tout doux avec ses rangées de surpiqûres.")
def build_bucket_hat(root):
    CUR["pre"] = T(0, 0, 0.03)
    prof = fillet([(0.158, 0.0), (0.148, 0.14), (0.128, 0.162), (0.0, 0.168)], [0, 0.02, 0.02, 0], 4, closed=False)
    prof2 = [(p.x, p.y) for p in prof]
    part("main", root, "crown", g_lathe, I4, prof2, segs=64)
    sec = fillet([(0.14, 0.008), (0.252, -0.035), (0.262, -0.03), (0.258, -0.021), (0.14, 0.021)], 0.004, 2)

    def bmod(a, s, r, z):
        u = max(0.0, (r - 0.14) / 0.12)
        return r, z + 0.008 * math.sin(3 * a + 0.4) * u
    part("main", root, "brim", g_lathe, I4, [(p.x, p.y) for p in sec], segs=72, mod=bmod, closed_u=True)
    bm = B()
    for u, cnt in ((0.3, 46), (0.55, 56), (0.8, 66)):
        r = lerp(0.142, 0.255, u)
        pts = []
        for k in range(97):
            a = TAU * k / 96
            z = lerp(0.021, -0.022, u) + 0.008 * math.sin(3 * a + 0.4) * min(1, (r - 0.14) / 0.12) + 0.0015
            pts.append(V((math.cos(a) * r, math.sin(a) * r, z)))
        g_stitches(bm, pts, lambda c: V((0, 0.0, 1)), cnt, dash=0.5, r=0.0023)
    for s in (0.12, 0.3):
        pts = [on_lathe(prof2, TAU * k / 80, s) for k in range(81)]
        g_stitches(bm, [p + n * 0.0015 for p, n in pts], lambda c: V((c.x, c.y, 0)), 50, dash=0.5, r=0.0023)
    mk(bm, "detail", root, "stitches")
    bm = B()
    for a in (0.25, -0.25, math.pi + 0.25, math.pi - 0.25):
        p, n = on_lathe(prof2, a, 0.3)
        g_torus(bm, frame_z(p + n * 0.001, n), 0.0075, 0.0028, segs=16, rsegs=6)
    mk(bm, "silver", root, "eyelets")
    p, n = on_lathe(prof2, math.radians(-60), 0.25)
    part("accent", root, "label", g_cookie, frame_z(p + n * 0.002, n, (0, 0, 1)), rrect2(0.05, 0.026, 0.005), 0.004,
         bevel=0.0015, seg=2, wn=True)


@item("devil_horns", "hat", "Cornes de diablotin", 160, "noir", "rouge", "jaune",
      "Deux petites cornes brillantes sur un serre-tête.")
def build_devil_horns(root):
    headband(root, "main")
    bm, bm_c = B(), B()
    for sx in (-1, 1):
        x0 = sx * 0.12
        b = V((x0, 0, band_z(x0) - 0.004))
        P = spline([b, b + V((sx * 0.025, 0, 0.06)), b + V((sx * 0.042, -0.006, 0.12)),
                    b + V((sx * 0.03, -0.018, 0.175)), b + V((0.0, -0.024, 0.205))], 6)
        g_tube(bm, I4, P, lambda t: 0.04 * (1 - t) ** 0.9 + 0.003, segs=16, cap=("flat", "round"),
               rmod=lambda t, phi: 1 + 0.05 * math.sin(t * 40) * (1 - t) ** 2)
        g_torus(bm_c, T(b + V((0, 0, 0.01))), 0.041, 0.009, segs=24, rsegs=8)
    mk(bm, "accent", root, "horns")
    mk(bm_c, "detail", root, "collars")


@item("sprout", "hat", "Petite pousse", 60, "vert", "menthe", "marron",
      "Une petite pousse qui se balance, avec sa goutte de rosée.", anim="sway")
def build_sprout(root):
    piv = empty("sprout_sway", root, loc=(0, 0, 0.02))
    bm = B()
    g_sphere(bm, T(0, 0, 0.03) @ S(0.032, 0.03, 0.02), 1.0, 16, 10)
    mk(bm, "detail", piv, "seed")
    tip = V((0, 0.005, 0.17))
    bm = B()
    g_tube(bm, I4, spline([(0, 0, 0.03), (0.006, 0, 0.08), (-0.008, 0.003, 0.13), tip], 6),
           lambda t: 0.011 * (1 - 0.35 * t), segs=10)
    L, W, TH, CURL = 0.12, 0.075, 0.014, 0.25
    Ms = [T(tip) @ R("Z", 0) @ R("Y", -28) @ R("X", 8), T(tip) @ R("Z", 180) @ R("Y", -22) @ R("X", -8)]
    for M in Ms:
        g_leaf(bm, M, L, W, TH, nu=12, nv=12, cup=0.3, curl=CURL)
    mk(bm, "main", piv, "leaves")
    bm = B()
    for M in Ms:
        pts = [M @ V((u * L, 0, CURL * L * u * u + TH * 0.5 * 0.9 * (1 - 0.3 * u) * math.sqrt(max(
            math.sin(math.pi * u ** 0.6) ** 0.8, 0)))) for u in [0.08 + 0.7 * k / 10 for k in range(11)]]
        g_tube(bm, I4, pts, lambda t: 0.0028 * (1 - 0.6 * t), segs=6)
    mk(bm, "accent", piv, "veins")
    bm = B()
    p = Ms[0] @ V((0.075, 0.016, CURL * L * 0.39 + 0.018))
    g_sphere(bm, T(p) @ S(1, 1, 0.85), 0.012, 14, 10)
    mk(bm, "clear_glass", piv, "dew")


@item("cherry", "hat", "Cerises", 75, "rouge", "vert", "vert",
      "Deux cerises bien brillantes, posées sur le dessus.", anim="sway")
def build_cherry(root):
    piv = empty("cherry_sway", root, loc=(0, 0, 0.0))
    prof = spline([(0, -0.055), (0.03, -0.05), (0.052, -0.025), (0.058, 0.005), (0.05, 0.035), (0.025, 0.05),
                   (0.008, 0.041), (0.0, 0.037)], 4)
    cs = [V((-0.045, -0.008, 0.058)), V((0.05, 0.012, 0.054))]
    bm = B()
    for i, c in enumerate(cs):
        g_lathe(bm, T(c) @ R("Z", 30 * i) @ R("X", 8 - 16 * i), [(p.x, p.y) for p in prof], segs=32)
    mk(bm, "main", piv, "cherries")
    bm = B()
    for c in cs:
        d = V((-0.45, -0.8, 0.45)).normalized()
        g_cookie(bm, frame_z(c + d * 0.057, d, (0, 0, 1)) @ R("Z", 30), ellipse2(0.012, 0.006, 16), 0.002,
                 bevel=0.0008, seg=1)
    mk(bm, "white", piv, "glints")
    J = V((0.006, 0.01, 0.22))
    bm = B()
    for c in cs:
        top = c + V((0, 0, 0.038))
        g_tube(bm, I4, spline([top, top + V(((J.x - top.x) * 0.15, 0, 0.07)), J], 8), 0.0045, segs=8)
    g_sphere(bm, T(J), 0.008, 10, 8)
    g_leaf(bm, T(J) @ R("Z", -20) @ R("Y", -25), 0.09, 0.045, 0.01, nu=10, nv=10, cup=0.25, curl=0.15)
    mk(bm, "detail", piv, "stems")


@item("umbrella_hat", "hat", "Chapeau parapluie", 340, "rouge", "blanc", "jaune",
      "Un mini parapluie qui tourne sur la tête : plus jamais mouillé !", anim="spin")
def build_umbrella_hat(root):
    part("detail", root, "base", g_lathe, I4,
         [(p.x, p.y) for p in spline([(0.09, 0.0), (0.088, 0.03), (0.055, 0.056), (0.0, 0.062)], 4)], segs=40)
    part("accent", root, "base_band", g_torus, T(0, 0, 0.012), 0.09, 0.008, segs=40, rsegs=8)
    bm = B()
    g_tube(bm, I4, [V((0, 0, 0.05)), V((0, 0, 0.3))], 0.0065, segs=10)
    mk(bm, "silver", root, "shaft")
    spin = empty("umbrella_hat_spin", root, loc=(0, 0, 0))
    Rm = 0.33

    def canopy(a0, a1):
        def fn(u, v):
            a = lerp(a0, a1, v)
            f = math.sin(math.pi * v)
            r = u * Rm * (1 - 0.07 * f * u ** 2)
            z = 0.305 - 0.13 * u ** 1.7 + 0.018 * f * u ** 4 + 0.01 * f * math.sin(math.pi * u)
            return (math.cos(a) * r, math.sin(a) * r, z)
        return fn
    bm_m, bm_a = B(), B()
    for k in range(8):
        a0 = TAU * k / 8
        g_loft(bm_m if k % 2 == 0 else bm_a, I4, canopy(a0, a0 + TAU / 8), 12, 10, closed_v=False)
    mk(bm_m, "main", spin, "canopy_main", solid=0.006, solid_off=0)
    mk(bm_a, "accent", spin, "canopy_accent", solid=0.006, solid_off=0)
    bm = B()
    for k in range(8):
        a = TAU * k / 8
        f = canopy(a, a + 1)
        pts = [V(f(u, 0)) - V((0, 0, 0.005)) for u in [0.15 + 0.85 * j / 12 for j in range(13)]]
        g_tube(bm, I4, pts, 0.0028, segs=6)
        g_sphere(bm, T(V(f(1.0, 0)) + V((0, 0, -0.002))), 0.0075, 10, 6)
        g_tube(bm, I4, [V((0, 0, 0.2)), V(f(0.55, 0)) - V((0, 0, 0.006))], 0.002, segs=5)
    mk(bm, "silver", spin, "ribs")
    bm = B()
    g_sphere(bm, T(0, 0, 0.312), 0.014, 14, 10)
    g_cyl(bm, T(0, 0, 0.334), 0.006, 0.0, 0.025, 10)
    mk(bm, "gold", spin, "finial")


# ===========================================================================
#                                CASQUE AUDIO
# ===========================================================================
@item("headphones", "headphones", "Casque audio", 300, "noir", "rose", "blanc",
      "Coussinets moelleux et petites lumières : pour écouter de la musique en travaillant.")
def build_headphones(root):
    # arceau principal (main) : ellipse au-dessus de la tete
    def arc(t, a=0.398, b=0.175, c=-0.14):
        ang = lerp(-math.pi / 2, math.pi / 2, t)
        sn, cs = math.sin(ang), math.cos(ang)
        return V((a * math.copysign(abs(sn) ** 0.8, sn), 0, c + b * abs(cs) ** 0.8))
    band = [arc(i / 48) for i in range(49)]
    part("main", root, "band", g_tube, I4, band, 0.012, segs=16, hint=V((0, 1, 0)), aspect=2.6, p=3.2)
    # coussin interieur (accent) + coutures
    cush = [arc(0.2 + 0.6 * i / 32, 0.383, 0.16) for i in range(33)]
    part("accent", root, "band_cushion", g_tube, I4, cush, 0.011, segs=16, hint=V((0, 1, 0)), aspect=2.0, p=2.4)
    bm = B()
    for sy in (-1, 1):
        pts = [arc(0.22 + 0.56 * i / 40, 0.383, 0.16) + V((0, sy * 0.017, 0)) for i in range(41)]
        g_stitches(bm, pts, lambda c: V((c.x, 0, c.z + 0.135)).normalized() * -1, 30, dash=0.5, r=0.0022)
    mk(bm, "detail", root, "band_stitches")
    for sx in (-1, 1):
        cx = sx * 0.38
        # glissieres (silver) avec crans
        bm = B()
        g_tube(bm, I4, [V((sx * 0.398, 0, -0.13)), V((sx * 0.4, 0, -0.2))], 0.0065, segs=10, hint=V((0, 1, 0)),
               aspect=2.2, p=4, cap="round")
        for j in range(4):
            g_cyl(bm, T(sx * 0.4, 0, -0.15 - j * 0.013) @ R("Y", 90), 0.003, 0.003, 0.016, 8)
        # fourche (yoke) autour de l'ecouteur
        yoke = [V((sx * 0.405, math.sin(a) * 0.125, -0.30 + math.cos(a) * 0.125))
                for a in [lerp(-math.pi / 2, math.pi / 2, i / 24) for i in range(25)]]
        g_tube(bm, I4, yoke, 0.007, segs=10, hint=V((1, 0, 0)), aspect=1.3, p=3)
        for sy in (-1, 1):
            g_cyl(bm, T(sx * 0.405, sy * 0.125, -0.30) @ R("Y", 90), 0.011, 0.011, 0.02, 16)
        mk(bm, "silver", root, "slider")
        # coque de l'ecouteur (main) : profil revolutionne selon X
        Mc = T(cx, 0, -0.30) @ R("Y", 90 * sx)  # Z local -> vers l'exterieur
        shell = fillet([(0.0, 0.058), (0.085, 0.058), (0.112, 0.035), (0.115, 0.0), (0.1, -0.004)],
                       [0, 0.02, 0.012, 0.004, 0], 4, closed=False)
        part("main", root, "cup", g_lathe, Mc, [(p.x, p.y) for p in shell], segs=48, cap1=True)
        # coussinet (accent) : tore moelleux cote tete
        part("accent", root, "cushion", g_torus, Mc @ T(0, 0, -0.022) @ S(1, 1, 0.8), 0.078, 0.032, segs=40,
             rsegs=12)
        bm = B()
        g_cyl(bm, Mc @ T(0, 0, -0.01), 0.07, 0.07, 0.02, 32)
        mk(bm, "black", root, "cushion_mesh")
        # plaque decorative (detail) + anneau lumineux
        part("detail", root, "plate", g_lathe, Mc,
             [(p.x, p.y) for p in fillet([(0.0, 0.07), (0.058, 0.068), (0.062, 0.06), (0.06, 0.056)],
                                         [0, 0.01, 0.003, 0], 3, closed=False)], segs=40)
        part("glow", root, "led", g_torus, Mc @ T(0, 0, 0.061), 0.07, 0.0045, segs=40, rsegs=6)
        # petite note de musique en relief sur la plaque
        bm = B()
        Mn = Mc @ T(0, 0, 0.071)
        g_sphere(bm, Mn @ T(-0.012, -0.016, 0) @ S(1.25, 1, 0.5), 0.011, 14, 8)
        g_tube(bm, Mn, [V((-0.002, -0.014, 0)), V((-0.002, 0.022, 0))], 0.0035, segs=8, cap="round")
        g_tube(bm, Mn, spline([(-0.002, 0.021, 0), (0.012, 0.012, 0), (0.02, 0.0, 0)], 4), 0.0032, segs=8)
        # Mn @ ...: les X locaux dependent du cote ; on garde le meme motif
        mk(bm, "silver", root, "note")


# ===========================================================================
#                                  LUNETTES
# ===========================================================================
LENS_Y = -0.05


def lens_disc(bm, M, outline, thick=0.006, bulge=0.006, warp=None):
    """Verre legerement bombe a partir d'un contour 2D (plan XY local, bombe vers +Z).
    Anneaux concentriques (contour mis a l'echelle depuis son centre) : pas d'artefacts sur les formes concaves."""
    pts = resample(c3(outline), max(len(outline), 40), closed=True)
    c = sum(pts, V((0, 0, 0))) / len(pts)
    rows = []
    nr = 5
    for k in range(nr + 1):  # face arriere : du centre vers le bord
        s = k / nr
        z = -thick / 2 - bulge * 0.25 * (1 - s * s)
        rows.append([V((c.x + (q.x - c.x) * s, c.y + (q.y - c.y) * s, z)) for q in pts])
    for k in range(nr, -1, -1):  # face avant : du bord vers le centre
        s = k / nr
        z = thick / 2 + bulge * (1 - s * s)
        rows.append([V((c.x + (q.x - c.x) * s, c.y + (q.y - c.y) * s, z)) for q in pts])
    if warp is not None:
        rows = [[V(warp(M @ q)) for q in row] for row in rows]
        M = I4
    g_rows(bm, M, rows, closed_v=True)


def glints(bm, cx, cz, r, y=LENS_Y - 0.009):
    """Reflets stylises (blanc) sur un verre."""
    M = face_front(V((cx - r * 0.38, y, cz + r * 0.38))) @ R("Z", -45)
    g_cookie(bm, M, rrect2(r * 0.5, r * 0.16, r * 0.08, 3), 0.0015, bevel=0.0006, seg=1)
    M = face_front(V((cx - r * 0.02, y, cz + r * 0.62))) @ R("Z", -45)
    g_cookie(bm, M, rrect2(r * 0.18, r * 0.11, r * 0.05, 3), 0.0015, bevel=0.0006, seg=1)


def temples(parent, x_hinge, mat_frame="main", mat_tip="accent", z=0.02):
    bm = B()
    bm2 = B()
    for sx in (-1, 1):
        x = sx * x_hinge
        path = spline([(x, LENS_Y + 0.02, z), (x + sx * 0.012, 0.08, z + 0.004), (x + sx * 0.02, 0.22, z),
                       (x + sx * 0.02, 0.29, z - 0.02)], 6)
        g_tube(bm, I4, path, 0.0065, segs=10, hint=V((0, 0, 1)), aspect=1.6, p=3.0, cap=("flat", "round"))
        tip = spline([(x + sx * 0.02, 0.24, z - 0.002), (x + sx * 0.02, 0.29, z - 0.02),
                      (x + sx * 0.018, 0.325, z - 0.06)], 5)
        g_tube(bm2, I4, tip, 0.0095, segs=10, hint=V((0, 0, 1)), aspect=1.3, p=2.5)
    mk(bm, mat_frame, parent, "temples")
    mk(bm2, mat_tip, parent, "temple_tips")


def hinges(parent, x, z=0.02, mat_="silver"):
    bm = B()
    for sx in (-1, 1):
        g_cyl(bm, T(sx * x, LENS_Y + 0.022, z), 0.0055, 0.0055, 0.022, 12)
        g_sphere(bm, T(sx * x, LENS_Y + 0.022, z + 0.012), 0.004, 10, 6)
    mk(bm, mat_, parent, "hinges")


@item("round_glasses", "eyes", "Lunettes rondes", 160, "noir", "noir", "jaune",
      "Montures rondes et plaquettes délicates : un air très intelligent.")
def build_round_glasses(root):
    r = 0.108
    bm = B()
    bmg = B()
    for sx in (-1, 1):
        cx = sx * 0.16
        Mf = face_front(V((cx, LENS_Y, 0)))
        g_tube(bm, Mf, [V((p.x, p.y, 0)) for p in circle2(r, 48)], 0.0125, segs=12, closed=True,
               hint=lambda t, q: V((0, 0, 1)), aspect=1.45, p=2.4)
        lens_disc(bmg, Mf, circle2(r * 0.98, 40), 0.004, 0.004)
        # tenon de charniere
        g_tube(bm, I4, [V((sx * (0.16 + r * 0.93), LENS_Y, 0.03)), V((sx * 0.282, LENS_Y + 0.004, 0.022)),
                        V((sx * 0.284, LENS_Y + 0.024, 0.02))], 0.0075, segs=10, aspect=1.3)
    # pont en trou de serrure
    br = spline([(-0.16 + r * 0.92, LENS_Y, 0.04), (-0.03, LENS_Y - 0.006, 0.058), (0.03, LENS_Y - 0.006, 0.058),
                 (0.16 - r * 0.92, LENS_Y, 0.04)], 6)
    g_tube(bm, I4, br, 0.0085, segs=10, hint=V((0, 1, 0)), aspect=1.3)
    mk(bm, "main", root, "frame")
    mk(bmg, "clear_glass", root, "lenses")
    bm = B()
    for sx in (-1, 1):
        glints(bm, sx * 0.16, 0, r)
    mk(bm, "white", root, "glints")
    # plaquettes : bras argentes + coussinets transparents
    bm = B()
    bmp = B()
    for sx in (-1, 1):
        x0 = sx * 0.065
        g_tube(bm, I4, [V((x0, LENS_Y + 0.002, 0.0)), V((sx * 0.05, LENS_Y + 0.012, -0.02)),
                        V((sx * 0.045, LENS_Y + 0.018, -0.03))], 0.0025, segs=6)
        g_sphere(bmp, T(sx * 0.044, LENS_Y + 0.022, -0.04) @ R("Z", sx * 25) @ S(0.5, 0.35, 1), 0.016, 12, 8)
    mk(bm, "silver", root, "pad_arms")
    mk(bmp, "clear_glass", root, "pads")
    hinges(root, 0.284, 0.02)
    temples(root, 0.286, "main", "accent", 0.02)


# ===========================================================================
#                                    COU
# ===========================================================================
@item("bow_tie", "neck", "Nœud papillon", 130, "noir", "noir", "blanc",
      "Plis soignés et petits pois : toujours sur son trente-et-un.")
def build_bow_tie(root):
    def wing(sx):
        def fn(u, v):
            phi = TAU * v
            cz, cy = superellipse(phi, 2.6)
            x = lerp(0.024, 0.152, u)
            # hauteur : pincee au centre, large au bout, bout legerement creuse
            h = 0.026 + 0.05 * smoothstep(0.0, 0.85, u)
            endround = math.sqrt(max(0.0, 1 - max(0.0, (u - 0.8) / 0.2) ** 2))
            h *= 0.35 + 0.65 * endround if u > 0.8 else 1.0
            d = 0.016 + 0.014 * math.sin(math.pi * min(u * 1.1, 1.0))
            z = cz * h
            y = cy * d
            # plis (vers l'interieur sur l'avant) qui convergent vers le noeud
            if cy < 0:
                for zc in (-0.36, 0.36):
                    y += 0.0065 * (1 - u) ** 0.7 * math.exp(-((cz - zc * (0.5 + 0.5 * u)) / 0.16) ** 2) * (-cy)
            # bout : petit creux central (forme papillon)
            x -= 0.012 * smoothstep(0.75, 1.0, u) * math.exp(-(cz / 0.35) ** 2)
            z -= 0.006 * u * u
            return (sx * x, y - 0.002, z)
        return fn

    bm = B()
    for sx in (-1, 1):
        g_loft(bm, I4, wing(sx), 22, 24)
    mk(bm, "main", root, "wings")
    # noeud central plisse
    def knot(u, v):
        phi = TAU * v
        cz, cy = superellipse(phi, 3.0)
        x = lerp(-0.03, 0.03, u)
        bulge = math.sin(math.pi * u) ** 0.5
        h = 0.03 * (0.85 + 0.15 * bulge)
        d = 0.02 + 0.008 * bulge
        y = cy * d - 0.008
        if cy < 0:
            y += 0.002 * math.sin(u * math.pi * 3) ** 2
        return (x, y, cz * h)
    bm = B()
    g_loft(bm, I4, knot, 12, 24, cap0=False)
    # extremites arrondies du noeud
    for sx in (-1, 1):
        g_sphere(bm, T(sx * 0.03, -0.008, 0) @ S(0.006, 0.02, 0.027), 1.0, 16, 10)
    mk(bm, "main", root, "knot")
    # petits pois (detail) sur l'avant des ailes
    bm = B()
    for sx in (-1, 1):
        fn = wing(sx)
        for (u, cz) in ((0.35, 0.45), (0.38, -0.5), (0.62, 0.0), (0.82, 0.62), (0.85, -0.6), (0.62, 0.85),
                        (0.62, -0.85)):
            # trouver v pour cz sur la face avant
            best, bv = 9, 0
            for j in range(200):
                vv = 0.5 + 0.5 * j / 200
                cz_, cy_ = superellipse(TAU * vv, 2.6)
                if abs(cz_ - cz) < best and cy_ < 0:
                    best, bv = abs(cz_ - cz), vv
            p = V(fn(u, bv))
            pu = V(fn(min(u + 0.01, 1), bv)) - V(fn(max(u - 0.01, 0), bv))
            pv = V(fn(u, bv + 0.005)) - V(fn(u, bv - 0.005))
            n = pu.cross(pv).normalized()
            if n.y > 0:
                n = -n
            g_cookie(bm, frame_z(p + n * 0.001, n, (0, 0, 1)), circle2(0.0085, 16), 0.003, bevel=0.0012, seg=2)
    mk(bm, "detail", root, "dots", wn=True)


@item("scarf", "scarf", "Écharpe", 170, "rouge", "blanc", "blanc",
      "Une écharpe rayée en grosse maille, avec ses franges.")
def build_scarf(root):
    stripe = math.radians(24)
    bm_m, bm_a = B(), B()
    # anneau tricote : bandes alternees, cotes dans la longueur
    n_str = int(round(TAU / stripe))
    for k in range(n_str):
        a0 = -math.pi / 2 + k * TAU / n_str
        pts = []
        for j in range(9):
            a = a0 + (TAU / n_str) * j / 8
            wob = 0.012 * math.sin(a * 3)
            pts.append(V((math.cos(a) * (1.045 + wob), math.sin(a) * (1.045 + wob), 0.01 * math.sin(a * 2))))
        g_tube(bm_m if k % 2 == 0 else bm_a, I4, pts, 0.092, segs=24, cap=(None, None),
               hint=lambda t, q: V((q.x, q.y, 0)), aspect=0.82, p=2.2,
               rmod=lambda t, phi: 1.0 + 0.045 * abs(math.cos(phi * 5)))
    # noeud et pans qui pendent a l'avant (-Y), legerement sur la droite
    knot_c = V((0.28, -0.99, -0.02))
    g_sphere(bm_m, T(knot_c + V((0, -0.06, 0))) @ S(0.12, 0.085, 0.115), 1.0, 24, 14)
    tails = [
        [knot_c + V((0.0, -0.02, -0.05)), V((0.24, -1.07, -0.17)), V((0.2, -1.09, -0.26)), V((0.19, -1.08, -0.35))],
        [knot_c + V((0.03, -0.01, -0.05)), V((0.37, -1.03, -0.15)), V((0.43, -1.02, -0.22)),
         V((0.45, -0.99, -0.29))],
    ]
    for ti, ctrl in enumerate(tails):
        ctrl = [c + V((0, -0.06, 0)) for c in ctrl]
        P = resample(spline(ctrl, 8), 30)
        nseg = 4
        for s in range(nseg):
            seg = P[s * 7: s * 7 + 8] if s < nseg - 1 else P[s * 7:]
            g_tube(bm_m if (s + ti) % 2 == 0 else bm_a, I4, seg, 0.03, segs=20,
                   cap=(None, "flat" if s == nseg - 1 else None),
                   hint=V((1, 0.1, 0)), aspect=lambda t: 3.6, p=3.2,
                   rmod=lambda t, phi: 1.0 + 0.06 * abs(math.cos(phi * 6)))
        # franges
        end, tng = P[-1], (P[-1] - P[-2]).normalized()
        side = V((1, 0.1, 0)).normalized()
        for f in range(7):
            o = end + side * lerp(-0.09, 0.09, f / 6)
            g_tube(bm_a if ti == 0 else bm_m, I4,
                   [o, o + tng * 0.05 + V((0, -0.005, 0)), o + tng * 0.1 + V((0.004 * (f - 3), -0.012, 0))],
                   0.012, segs=8, cap=("flat", "round"))
    mk(bm_m, "main", root, "knit_main")
    mk(bm_a, "accent", root, "knit_accent")


# ===========================================================================
#                                    DOS
# ===========================================================================
@item("angel_wings", "back", "Ailes d'ange", 520, "blanc", "jaune", "blanc",
      "Des ailes en plumes toutes douces qui battent de joie.", anim="flap")
def build_angel_wings_placeholder(root):
    pass


def frame_loop(bm, M, outline, r, depth_aspect=1.3, p=2.6, n=None):
    """Monture : tube ferme le long d'un contour 2D (plan XY local du repere M)."""
    pts = c3(resample(c3(outline), n or max(len(outline), 48), closed=True))
    g_tube(bm, M, pts, r, segs=10, closed=True, hint=lambda t, q: V((0, 0, 1)), aspect=depth_aspect, p=p)


def lens_pair(bm_frame, bm_lens, bm_glint, outline_r, r_frame, lens_mat_bm=None, glint_r=0.1, depth_aspect=1.4,
              p=2.6, mirror=True, cz=0.0, shrink=0.97, bm_lens_l=None):
    """outline_r : contour 2D du verre DROIT centre en (0,0) (x vers l'exterieur)."""
    for sx in (-1, 1):
        cx = sx * 0.16
        Mf = face_front(V((cx, LENS_Y, cz)))
        if sx < 0 and mirror:
            Mf = Mf @ S(-1, 1, 1)
        frame_loop(bm_frame, Mf, outline_r, r_frame, depth_aspect, p)
        lens_disc(bm_lens if (sx > 0 or bm_lens_l is None) else bm_lens_l, Mf, [V((q[0] * shrink, q[1] * shrink))
                                                                              for q in outline_r], 0.004, 0.004)
        if bm_glint is not None:
            glints(bm_glint, cx, cz, glint_r)


def nose_pads(parent):
    bm = B()
    bmp = B()
    for sx in (-1, 1):
        x0 = sx * 0.062
        g_tube(bm, I4, [V((x0, LENS_Y + 0.002, 0.0)), V((sx * 0.05, LENS_Y + 0.012, -0.02)),
                        V((sx * 0.045, LENS_Y + 0.018, -0.03))], 0.0025, segs=6)
        g_sphere(bmp, T(sx * 0.044, LENS_Y + 0.022, -0.04) @ R("Z", sx * 25) @ S(0.5, 0.35, 1), 0.016, 12, 8)
    mk(bm, "silver", parent, "pad_arms")
    mk(bmp, "clear_glass", parent, "pads")


@item("nerd_glasses", "eyes", "Lunettes d'intello", 170, "noir", "blanc", "jaune",
      "Grosses montures carrées, rivets et sparadrap au milieu : 100 % geek.")
def build_nerd_glasses(root):
    out = rrect2(0.205, 0.15, 0.035, 5)
    out = [V((q.x, q.y)) for q in out]
    bm_f, bm_l, bm_g = B(), B(), B()
    lens_pair(bm_f, bm_l, bm_g, out, 0.016, depth_aspect=1.25, p=3.4, glint_r=0.1)
    # sourcils epais (browline)
    for sx in (-1, 1):
        Mf = face_front(V((sx * 0.16, LENS_Y - 0.002, 0.0)))
        pts = [V((x, 0.075 - 0.01 * (x / 0.1) ** 2, 0)) for x in [lerp(-0.1, 0.1, k / 12) for k in range(13)]]
        g_tube(bm_f, Mf, pts, 0.014, segs=10, hint=V((0, 0, 1)), aspect=1.3, p=3.5)
        g_tube(bm_f, I4, [V((sx * 0.262, LENS_Y, 0.045)), V((sx * 0.286, LENS_Y + 0.006, 0.03)),
                          V((sx * 0.288, LENS_Y + 0.024, 0.024))], 0.0095, segs=10, p=3)
    # pont
    g_tube(bm_f, I4, [V((-0.06, LENS_Y, 0.03)), V((0.0, LENS_Y - 0.004, 0.034)), V((0.06, LENS_Y, 0.03))], 0.012,
           segs=12, p=3, aspect=1.2)
    mk(bm_f, "main", root, "frame")
    mk(bm_l, "clear_glass", root, "lenses")
    mk(bm_g, "white", root, "glints")
    # sparadrap froisse autour du pont
    bm = B()
    g_tube(bm, I4, [V((-0.026, LENS_Y - 0.002, 0.032)), V((0.0, LENS_Y - 0.004, 0.034)),
                    V((0.026, LENS_Y - 0.002, 0.032))], 0.019, segs=14, p=3.2, cap="flat",
           rmod=lambda t, phi: 1 + 0.06 * math.sin(phi * 3 + t * 9) + 0.04 * math.sin(phi * 7))
    mk(bm, "accent", root, "tape")
    bm = B()
    for sx in (-1, 1):
        for zz in (0.05, 0.022):
            g_sphere(bm, T(sx * 0.236, LENS_Y - 0.02, zz) @ S(1, 0.6, 1), 0.006, 10, 6)
    mk(bm, "silver", root, "rivets")
    nose_pads(root)
    hinges(root, 0.288, 0.024)
    temples(root, 0.29, "main", "main", 0.024)


def aviator_outline():
    ctrl = [(-0.085, 0.048), (0.0, 0.062), (0.088, 0.054), (0.112, 0.01), (0.09, -0.06), (0.03, -0.098),
            (-0.04, -0.085), (-0.088, -0.03)]
    return [V((p.x, p.y)) for p in spline(ctrl, 6, closed=True)]


@item("sunglasses", "eyes", "Lunettes aviateur", 220, "noir", "noir", "jaune",
      "Verres teintés en goutte, double pont doré : trop cool pour l'école.")
def build_sunglasses(root):
    out = aviator_outline()
    bm_f, bm_l, bm_g = B(), B(), B()
    lens_pair(bm_f, bm_l, bm_g, out, 0.0062, depth_aspect=1.2, p=2.2, glint_r=0.1)
    # double pont
    g_tube(bm_f, I4, [V((-0.085, LENS_Y, 0.055)), V((0.085, LENS_Y, 0.055))], 0.0055, segs=8)
    g_tube(bm_f, I4, spline([(-0.074, LENS_Y, 0.03), (-0.03, LENS_Y - 0.004, 0.036), (0.03, LENS_Y - 0.004, 0.036),
                             (0.074, LENS_Y, 0.03)], 5), 0.005, segs=8)
    for sx in (-1, 1):
        g_tube(bm_f, I4, [V((sx * 0.268, LENS_Y, 0.04)), V((sx * 0.284, LENS_Y + 0.008, 0.032)),
                          V((sx * 0.286, LENS_Y + 0.024, 0.028))], 0.006, segs=8)
    mk(bm_f, "gold", root, "frame")
    mk(bm_l, "glass", root, "lenses")
    mk(bm_g, "white", root, "glints")
    nose_pads(root)
    hinges(root, 0.286, 0.028, "gold")
    temples(root, 0.288, "gold", "main", 0.028)


@item("heart_glasses", "eyes", "Lunettes cœur", 200, "rose", "rouge", "jaune",
      "Des lunettes en forme de cœur pour les grands romantiques.")
def build_heart_glasses(root):
    hp = heart2(0.125, 56)
    cy = sum(q.y for q in hp) / len(hp)
    out = [V((q.x, q.y - cy)) for q in hp]
    bm_f, bm_l, bm_g = B(), B(), B()
    lens_pair(bm_f, bm_l, bm_g, out, 0.014, depth_aspect=1.35, p=2.4, glint_r=0.1, mirror=False)
    g_tube(bm_f, I4, spline([(-0.06, LENS_Y, 0.03), (0.0, LENS_Y - 0.008, 0.045), (0.06, LENS_Y, 0.03)], 5), 0.01,
           segs=10)
    for sx in (-1, 1):
        g_tube(bm_f, I4, [V((sx * 0.272, LENS_Y, 0.045)), V((sx * 0.288, LENS_Y + 0.008, 0.032)),
                          V((sx * 0.29, LENS_Y + 0.024, 0.026))], 0.009, segs=10)
    mk(bm_f, "main", root, "frame")
    mk(bm_l, "glass", root, "lenses")
    mk(bm_g, "white", root, "glints")
    bm = B()
    for sx in (-1, 1):
        g_cookie(bm, face_front(V((sx * 0.255, LENS_Y - 0.018, 0.075))) @ R("Z", sx * 15),
                 star2(0.022, 0.01, 5, 0.004), 0.008, bevel=0.003, seg=2)
    mk(bm, "gold", root, "stars", wn=True)
    hinges(root, 0.29, 0.026)
    temples(root, 0.292, "main", "accent", 0.026)


@item("star_glasses", "eyes", "Lunettes étoiles", 230, "jaune", "rose", "ciel",
      "Des lunettes étoiles à paillettes : une vraie star.")
def build_star_glasses(root):
    out = [V((q.x, q.y - 0.006)) for q in star2(0.128, 0.068, 5, 0.022, n=5)]
    bm_f, bm_l, bm_g = B(), B(), B()
    lens_pair(bm_f, bm_l, bm_g, out, 0.0125, depth_aspect=1.4, p=2.4, glint_r=0.085, mirror=False)
    g_tube(bm_f, I4, spline([(-0.07, LENS_Y, 0.01), (0.0, LENS_Y - 0.008, 0.026), (0.07, LENS_Y, 0.01)], 5), 0.01,
           segs=10)
    for sx in (-1, 1):
        g_tube(bm_f, I4, [V((sx * 0.272, LENS_Y, 0.03)), V((sx * 0.288, LENS_Y + 0.008, 0.022)),
                          V((sx * 0.29, LENS_Y + 0.024, 0.018))], 0.009, segs=10)
    mk(bm_f, "main", root, "frame")
    mk(bm_l, "clear_glass", root, "lenses")
    mk(bm_g, "white", root, "glints")
    # paillettes sur la monture
    bm = B()
    for sx in (-1, 1):
        for k in range(5):
            a = math.pi / 2 + TAU * k / 5
            p = V((sx * 0.16 + math.cos(a) * 0.118, LENS_Y - 0.017, math.sin(a) * 0.118 - 0.006))
            g_cookie(bm, face_front(p) @ R("Z", k * 20), star2(0.012, 0.005, 4, 0.002), 0.004, bevel=0.0015, seg=1)
    mk(bm, "accent", root, "sparkles", wn=True)
    bm = B()
    for sx in (-1, 1):
        for k in range(5):
            a = math.pi / 2 + TAU * k / 5 + TAU / 10
            p = V((sx * 0.16 + math.cos(a) * 0.06, LENS_Y - 0.012, math.sin(a) * 0.06 - 0.006))
            g_sphere(bm, T(p), 0.0045, 8, 6)
    mk(bm, "detail", root, "glitter")
    hinges(root, 0.29, 0.018)
    temples(root, 0.292, "main", "accent", 0.018)


@item("monocle", "eyes", "Monocle", 280, "jaune", "noir", "rouge",
      "Monture perlée et chaînette dorée : fort distingué, très cher.")
def build_monocle(root):
    cx, r = 0.16, 0.108
    Mf = face_front(V((cx, LENS_Y, 0)))
    bm = B()
    g_tube(bm, Mf, c3(circle2(r, 64)), 0.0115, segs=10, closed=True, hint=lambda t, q: V((0, 0, 1)), aspect=1.5,
           p=2.4, rmod=lambda t, phi: 1 + 0.12 * max(0.0, math.cos(phi)) * abs(math.sin(t * math.pi * 40)))
    g_tube(bm, Mf, c3(circle2(r - 0.014, 48)), 0.0035, segs=6, closed=True)
    # petite attache de chaine
    g_torus(bm, Mf @ T(r * 0.72, -r * 0.72, 0) @ R("Y", 90), 0.009, 0.0028, segs=16, rsegs=6)
    mk(bm, "gold", root, "rim")
    bm = B()
    lens_disc(bm, Mf, circle2(r * 0.97, 40), 0.004, 0.005)
    mk(bm, "clear_glass", root, "lens")
    bm = B()
    glints(bm, cx, 0, r)
    mk(bm, "white", root, "glints")
    # chainette : maillons alternes
    start = Mf @ V((r * 0.72 + 0.006, -r * 0.72 - 0.006, 0))
    P = spline([start, start + V((0.04, 0.02, -0.06)), start + V((0.09, 0.09, -0.1)), V((0.31, 0.2, -0.12)),
                V((0.33, 0.28, -0.08))], 8)
    P = resample(P, 40)
    fr = tube_frames(P)
    bm = B()
    for i, q in enumerate(P[1:-1], 1):
        t_, n1, n2 = fr[i]
        ax = n1 if i % 2 == 0 else n2
        M = basis(t_, ax, t_.cross(ax), q)
        g_torus(bm, M @ S(1.5, 1, 1), 0.0055, 0.0018, segs=10, rsegs=4)
    g_cyl(bm, T(P[-1]) @ R("X", 90), 0.006, 0.006, 0.018, 12)
    mk(bm, "gold", root, "chain")


@item("glasses_3d", "eyes", "Lunettes 3D", 140, "blanc", "noir", "noir",
      "Monture en carton et verres rouge et bleu : le cinéma à la maison !")
def build_glasses_3d(root):
    bm = B()
    for sx in (-1, 1):
        cx = sx * 0.16
        Mf = face_front(V((cx, LENS_Y, 0)))
        outer = [V(superellipse(TAU * k / 64, 5)) for k in range(64)]
        o_pts = [V((q.x * 0.128, q.y * 0.092)) for q in outer]
        i_pts = [V((q.x * 0.098, q.y * 0.064)) for q in outer]
        d = 0.012
        top_o = [bm.verts.new(Mf @ V((q.x, q.y, d / 2))) for q in o_pts]
        top_i = [bm.verts.new(Mf @ V((q.x, q.y, d / 2))) for q in i_pts]
        bot_o = [bm.verts.new(Mf @ V((q.x, q.y, -d / 2))) for q in o_pts]
        bot_i = [bm.verts.new(Mf @ V((q.x, q.y, -d / 2))) for q in i_pts]
        n = len(o_pts)
        for k in range(n):
            k1 = (k + 1) % n
            bm.faces.new((top_o[k], top_o[k1], top_i[k1], top_i[k]))
            bm.faces.new((bot_i[k], bot_i[k1], bot_o[k1], bot_o[k]))
            bm.faces.new((bot_o[k], bot_o[k1], top_o[k1], top_o[k]))
            bm.faces.new((top_i[k], top_i[k1], bot_i[k1], bot_i[k]))
        # branches plates
        g_cookie(bm, T(sx * 0.285, LENS_Y + 0.14, 0.01) @ R("Z", 90) @ R("X", 90),
                 rrect2(0.29, 0.03, 0.012), 0.008, bevel=0.002, seg=2)
    g_cookie(bm, face_front(V((0, LENS_Y, 0.012))), rrect2(0.08, 0.05, 0.015), 0.012, bevel=0.003, seg=2)
    mk(bm, "main", root, "frame", bevel=0.003, bevel_seg=2, smooth=False, wn=True)
    for sx, gm in ((-1, "gem_red"), (1, "gem_blue")):
        bm = B()
        lens_disc(bm, face_front(V((sx * 0.16, LENS_Y + 0.001, 0))),
                  [V((q[0] * 0.104, q[1] * 0.07)) for q in [superellipse(TAU * k / 48, 5) for k in range(48)]],
                  0.004, 0.002)
        mk(bm, gm, root, "lens")
    bm = B()
    for sx in (-1, 1):
        glints(bm, sx * 0.16, 0, 0.09, y=LENS_Y - 0.007)
    mk(bm, "white", root, "glints")
    # bordure imprimee + "3D" stylise sur le pont
    bm = B()
    for sx in (-1, 1):
        Mf = face_front(V((sx * 0.16, LENS_Y - 0.0065, 0)))
        frame_loop(bm, Mf, [V((q[0] * 0.122, q[1] * 0.086)) for q in [superellipse(TAU * k / 64, 5)
                                                                       for k in range(64)]], 0.0022, 0.6, 2.0)
    mk(bm, "accent", root, "print")


@item("ski_goggles", "eyes", "Masque de ski", 320, "blanc", "ciel", "rose",
      "Grand écran miroir et sangle rayée : prêt pour la piste !")
def build_ski_goggles(root):
    def curve(p):
        return (p[0], p[1] + 0.55 * p[0] * p[0], p[2])
    ol = []
    for k in range(80):
        t = TAU * k / 80
        cx, cy = superellipse(t, 3.2)
        x, y = cx * 0.285, cy * 0.105
        if cy < 0:
            y += 0.045 * math.exp(-(x / 0.05) ** 2)  # encoche du nez
        ol.append(V((x, y)))
    M0 = face_front(V((0, LENS_Y - 0.01, 0.0)))
    bm = B()
    pts = [V(curve(M0 @ V((q.x, q.y, 0)))) for q in resample(c3(ol), 96, closed=True)]
    g_tube(bm, I4, pts, 0.02, segs=12, closed=True, hint=lambda t, q: V((0, -1, 0)), aspect=1.25, p=2.6)
    mk(bm, "main", root, "frame")
    bm = B()
    lens_disc(bm, M0, [V((q.x * 0.95, q.y * 0.9)) for q in ol], 0.008, 0.008, warp=curve)
    mk(bm, "glass", root, "visor")
    bm = B()
    for (x, z, w, h, ang) in ((-0.17, 0.045, 0.1, 0.022, -18), (-0.08, 0.06, 0.04, 0.016, -18)):
        p = V(curve((x, LENS_Y - 0.026, z)))
        g_cookie(bm, face_front(p) @ R("Z", ang), rrect2(w, h, h * 0.45), 0.002, bevel=0.0008, seg=1)
    mk(bm, "white", root, "glints")
    # aerations sur le haut de la monture
    bm = B()
    for x in (-0.12, -0.06, 0.0, 0.06, 0.12):
        p = V(curve((x, LENS_Y - 0.012, 0.118)))
        g_cookie(bm, frame_z(p, V((0, -0.3, 1)), (0, 1, 0)), rrect2(0.032, 0.008, 0.0035), 0.004, bevel=0.0012, seg=1)
    mk(bm, "black", root, "vents")
    # sangle rayee + attaches
    bm_s, bm_d, bm_c = B(), B(), B()
    for sx in (-1, 1):
        P = spline([(sx * 0.29, LENS_Y + 0.05, 0.0), (sx * 0.32, 0.06, 0.0), (sx * 0.33, 0.18, -0.005),
                    (sx * 0.32, 0.3, -0.01)], 6)
        g_tube(bm_s, I4, P, 0.007, segs=10, hint=V((0, 0, 1)), aspect=6.5, p=4, cap=("flat", "flat"))
        P2 = [q + V((sx * 0.0075, 0, 0)) for q in P[1:]]
        g_tube(bm_d, I4, P2, 0.0025, segs=6, hint=V((0, 0, 1)), aspect=6.0, p=4)
        g_cookie(bm_c, T(sx * 0.3, LENS_Y + 0.055, 0) @ R("Z", 90) @ R("X", 90), rrect2(0.04, 0.06, 0.01), 0.014,
                 bevel=0.004, seg=2)
    mk(bm_s, "accent", root, "strap")
    mk(bm_d, "detail", root, "strap_stripe")
    mk(bm_c, "silver", root, "clips", wn=True)


# ===========================================================================
#                                  BOUCHE
# ===========================================================================
@item("mustache", "mouth", "Moustache", 90, "marron", "noir", "noir",
      "Une belle moustache en guidon, bien frisée au bout.")
def build_mustache(root):
    CUR["pre"] = S(0.9, 1, 0.95)
    bm = B()
    for sx in (-1, 1):
        ctrl = [(0.0, -0.03, 0.018), (0.035, -0.038, 0.016), (0.08, -0.036, 0.0), (0.12, -0.03, 0.006),
                (0.142, -0.028, 0.026), (0.138, -0.027, 0.046), (0.12, -0.026, 0.052), (0.106, -0.026, 0.04),
                (0.114, -0.027, 0.03)]
        P = spline([(sx * c[0], c[1], c[2]) for c in ctrl], 8)

        def rad(t):
            if t < 0.55:
                return 0.006 + 0.022 * max(0.0, math.sin(math.pi * min(1.0, 0.3 + t * 1.3))) ** 1.2
            return 0.004 + 0.012 * max(0.0, 1 - (t - 0.55) / 0.45) ** 1.3
        g_tube(bm, I4, P, rad, segs=16, hint=V((0, -1, 0)), aspect=0.55, p=2.2,
               rmod=lambda t, phi: 1 + 0.045 * math.cos(phi * 9 + t * 20))
    g_sphere(bm, T(0, -0.035, 0.016) @ S(0.026, 0.016, 0.02), 1.0, 16, 10)
    mk(bm, "main", root, "mustache")


@item("pacifier", "mouth", "Tétine", 60, "ciel", "blanc", "rose",
      "Une tétine toute ronde, pour faire de beaux rêves.")
def build_pacifier(root):
    def curve(p):
        return (p[0], p[1] + 1.4 * p[0] * p[0], p[2])
    sh = []
    for k in range(64):
        t = TAU * k / 64
        r = 1 - 0.22 * math.sin(t) ** 2
        sh.append(V((math.cos(t) * 0.08 * r, math.sin(t) * 0.055 * r)))
    M = face_front(V((0, -0.03, 0)))
    bm = B()
    g_cookie(bm, M, sh, 0.014, bevel=0.005, seg=3, puff=0.003, warp=curve)
    mk(bm, "main", root, "shield")
    bm = B()
    for sx in (-1, 1):
        g_cookie(bm, face_front(V(curve((sx * 0.048, -0.04, 0.0)))), ellipse2(0.012, 0.009, 16), 0.003, bevel=0.001,
                 seg=1)
    mk(bm, "black", root, "holes", wn=True)
    bm = B()
    g_sphere(bm, T(0, -0.045, 0) @ R("X", 90) @ S(1, 1, 0.7), 0.024, 20, 10)
    g_torus(bm, T(0, -0.062, -0.04) @ R("X", 90), 0.034, 0.008, segs=40, rsegs=10)
    mk(bm, "accent", root, "button_ring")
    bm = B()
    g_cookie(bm, face_front(V((0, -0.0625, 0.001))) @ T(0, -0.008, 0), heart2(0.014), 0.004, bevel=0.0015, seg=1)
    mk(bm, "detail", root, "heart", wn=True)
    bm = B()
    g_sphere(bm, T(0, -0.012, 0) @ S(0.016, 0.02, 0.014), 1.0, 14, 8)
    mk(bm, "clear_glass", root, "nipple")


@item("bubble_gum", "mouth", "Bulle de chewing-gum", 50, "rose", "rose", "blanc",
      "Pop ! Une énorme bulle de chewing-gum.")
def build_bubble_gum(root):
    Rb, cz = 0.105, 0.145
    prof = [(0.03, 0.0), (0.026, 0.02)]
    phi0 = math.asin(0.03 / Rb)
    for k in range(25):
        ph = lerp(phi0, math.pi, k / 24)
        prof.append((Rb * math.sin(ph) + (0.0 if k < 24 else 0.0), cz - Rb * math.cos(ph)))
    prof[-1] = (0.0, prof[-1][1])
    M = R("X", 90)  # Z local -> -Y (avant)
    part("main", root, "bubble", g_lathe, M, prof, segs=40,
         mod=lambda a, s, r, z: (r * (1 + 0.015 * math.sin(3 * a) * math.sin(math.pi * s)), z))
    part("main", root, "lips_gum", g_torus, M @ T(0, 0, 0.006), 0.03, 0.011, segs=32, rsegs=8)
    bm = B()
    c = V((0, -cz, 0))
    for d, w, h in ((V((-0.5, -0.72, 0.45)), 0.028, 0.011), (V((-0.08, -0.78, 0.62)), 0.009, 0.008)):
        d.normalize()
        g_cookie(bm, frame_z(c + d * (Rb + 0.001), d, (0, 0, 1)) @ R("Z", -40), ellipse2(w, h, 20), 0.002,
                 bevel=0.0008, seg=1)
    mk(bm, "white", root, "glints")


# ===========================================================================
#                                   COU (suite)
# ===========================================================================
@item("necktie", "neck", "Cravate", 150, "bleu", "jaune", "blanc",
      "Nœud bien serré, rayures en biais et pince dorée : prêt pour la réunion.")
def build_necktie(root):
    # noeud
    def knot(u, v):
        phi = TAU * v
        cx, cy = superellipse(phi, 2.8)
        z = lerp(0.012, -0.045, u)
        w = lerp(0.03, 0.019, u) * math.sqrt(max(0.0, 1 - ((u - 0.5) / 0.5) ** 6)) + 0.0005
        d = 0.016 * math.sqrt(max(0.0, 1 - ((u - 0.5) / 0.5) ** 6)) + 0.0005
        return (cx * w, -0.022 + cy * d - 0.004 * math.sin(math.pi * u), z)
    bm = B()
    g_loft(bm, I4, knot, 14, 24)
    mk(bm, "main", root, "knot")
    L0, L1 = -0.035, -0.175

    def width(u):
        w = 0.022 + 0.026 * u
        if u > 0.86:
            w *= max(0.0, (1 - u) / 0.14)
        return w

    def front(u, x, side=-1.0):
        z = lerp(L0, L1, u)
        yc = -0.022 - 0.012 * u
        th = 0.0055 * math.sqrt(max(0.0, 1 - x * x))
        # petite cambrure transversale
        return V((x * width(u), yc + side * th - 0.004 * (1 - x * x), z))

    def blade(u, v):
        phi = TAU * v
        x = math.cos(phi)
        side = -1.0 if math.sin(phi) < 0 else 1.0
        th = 0.0055 * abs(math.sin(phi))
        z = lerp(L0, L1, u)
        yc = -0.022 - 0.012 * u
        return (x * width(u), yc + side * th - 0.004 * (1 - x * x), z)
    bm = B()
    g_loft(bm, I4, blade, 30, 20)
    mk(bm, "main", root, "blade")
    # rayures en biais (decalques sur la face avant)
    bm = B()
    slope = 0.09
    for c in [0.12 + k * 0.16 for k in range(6)]:
        rows = []
        for i in range(5):
            s = i / 4
            row = []
            for j in range(13):
                x = lerp(-0.95, 0.95, j / 12)
                u = c + slope * x + (s - 0.5) * 0.05
                u = min(max(u, 0.0), 0.985)
                row.append(front(u, x) + V((0, -0.0012, 0)))
            rows.append(row)
        g_rows(bm, I4, rows, closed_v=False)
    mk(bm, "accent", root, "stripes", solid=0.0012, solid_off=1)
    # pince a cravate
    bm = B()
    p = front(0.5, 0.0)
    g_cookie(bm, face_front(p + V((0, -0.004, 0))), rrect2(0.062, 0.008, 0.003), 0.004, bevel=0.0015, seg=2)
    mk(bm, "gold", root, "clip", wn=True)


def ring_path(a, rr=1.0, dip=0.0, z=0.0):
    """Point sur l'anneau d'echarpe (rayon 1), avec descente vers l'avant (-Y)."""
    f = max(0.0, -math.sin(a)) ** 2
    return V((math.cos(a) * rr, math.sin(a) * rr, z - dip * f))


@item("pearl_necklace", "scarf", "Collier de perles", 450, "blanc", "rose", "jaune",
      "Un rang de perles nacrées avec un pendentif en goutte.")
def build_pearl_necklace(root):
    P = [ring_path(TAU * k / 240 - math.pi / 2, 1.0, 0.1, 0.0) for k in range(240)]
    P = resample(P, 480, closed=True)
    # placement gradue : perles plus grosses devant
    bm = B()
    s, Ltot = 0.0, path_len(P + [P[0]])
    placed = []
    while s < Ltot - 0.06:
        q, _ = path_at(P + [P[0]], s / Ltot)
        front = max(0.0, -q.y)
        rr = 0.045 + 0.016 * front ** 2
        placed.append((q, rr))
        s += rr * 2.05
    for q, rr in placed:
        g_sphere(bm, T(q), rr, 12, 8)
    mk(bm, "pearl", root, "pearls")
    # fermoir a l'arriere + pendentif
    bm = B()
    g_cyl(bm, T(0, 1.0, 0) @ R("Y", 90), 0.035, 0.035, 0.07, 16)
    front_q = V((0, -1.0, -0.1))
    Mp = frame_z(front_q + V((0, -0.06, -0.09)), V((0, -1, 0)), (0, 0, 1))
    g_torus(bm, Mp @ T(0, 0.075, 0) @ R("Y", 90), 0.022, 0.008, segs=20, rsegs=6)
    g_tube(bm, Mp @ S(1, 1.35, 1), c3(circle2(0.052, 28)), 0.011, segs=8, closed=True)
    for j in range(6):
        a = TAU * j / 6
        g_sphere(bm, Mp @ T(math.cos(a) * 0.05, math.sin(a) * 0.068, 0.012), 0.009, 8, 5)
    mk(bm, "gold", root, "clasp_pendant")
    bm = B()
    g_gem(bm, Mp @ T(0, 0, 0.006) @ S(1, 1.35, 1), 0.046, n=10)
    mk(bm, "gem_pink", root, "gem", smooth=False)
    bm = B()
    g_sphere(bm, T(Mp @ V((0, -0.095, 0.0))) @ S(1, 1, 1.2), 0.03, 14, 10)
    mk(bm, "pearl", root, "drop")


@item("medal", "neck", "Médaille d'or", 380, "rouge", "blanc", "bleu",
      "Une médaille d'or sur son ruban : champion du bureau !")
def build_medal(root):
    bm_r, bm_s = B(), B()
    for sx in (-1, 1):
        P = spline([(sx * 0.07, 0.05, 0.1), (sx * 0.06, -0.012, 0.02), (sx * 0.03, -0.02, -0.06),
                    (sx * 0.006, -0.024, -0.1)], 8)
        g_tube(bm_r, I4, P, 0.0035, segs=8, hint=V((0, -1, 0)).cross(V((0, 0, 1))), aspect=5.2, p=4)
        P2 = [q + V((0, -0.0035, 0)) for q in P]
        g_tube(bm_s, I4, P2, 0.0015, segs=6, hint=V((1, 0, 0)), aspect=4.5, p=4)
    mk(bm_r, "main", root, "ribbon")
    mk(bm_s, "accent", root, "ribbon_stripe")
    C = V((0, -0.028, -0.17))
    Mm = face_front(C)
    bm = B()
    g_torus(bm, T(0, -0.025, -0.107) @ R("Y", 90), 0.014, 0.004, segs=20, rsegs=6)
    g_cyl(bm, Mm, 0.058, 0.058, 0.012, 48)
    g_tube(bm, Mm @ T(0, 0, 0.007), c3(circle2(0.056, 64)), 0.0055, segs=8, closed=True,
           rmod=lambda t, phi: 1 + 0.25 * abs(math.sin(t * math.pi * 32)))
    g_cookie(bm, Mm @ T(0, 0, 0.011), star2(0.03, 0.014, 5, 0.004), 0.008, bevel=0.003, seg=2, puff=0.002)
    mk(bm, "gold", root, "medal", wn=True)
    bm = B()
    g_cyl(bm, Mm @ T(0, 0, 0.0065), 0.044, 0.044, 0.002, 40)
    mk(bm, "detail", root, "enamel")
    bm = B()
    g_tube(bm, Mm @ T(0, 0, 0.0085), c3(circle2(0.044, 48)), 0.002, segs=6, closed=True)
    mk(bm, "white", root, "enamel_rim")


@item("bell_collar", "scarf", "Collier à grelot", 160, "rouge", "noir", "blanc",
      "Un collier clouté avec son grelot doré qui tinte.")
def build_bell_collar(root):
    ring = [V((math.cos(a) * 1.03, math.sin(a) * 1.03, 0)) for a in [TAU * k / 96 for k in range(96)]]
    part("main", root, "band", g_tube, I4, ring, 0.024, segs=12, closed=True, hint=lambda t, q: V((0, 0, 1)),
         aspect=3.4, p=4.5)
    bm = B()
    for zz in (0.06, -0.06):
        pts = [V((math.cos(a) * 1.056, math.sin(a) * 1.056, zz)) for a in [TAU * k / 120 for k in range(121)]]
        g_stitches(bm, pts, lambda c: V((c.x, c.y, 0)), 64, dash=0.5, r=0.0065)
    mk(bm, "detail", root, "stitches")
    bm = B()
    for k in range(10):
        a = -math.pi / 2 + TAU * (k + 1) / 11
        n = V((math.cos(a), math.sin(a), 0))
        rivet(bm, n * 1.054, n, 0.026)
    # boucle sur le cote
    Mb = frame_z(V((1.058, 0, 0)), V((1, 0, 0)), (0, 0, 1))
    g_tube(bm, Mb, c3(rrect2(0.09, 0.15, 0.02)), 0.009, segs=6, closed=True, p=3)
    g_tube(bm, Mb, [V((0, -0.07, 0.006)), V((0, 0.07, 0.006))], 0.006, segs=6)
    mk(bm, "silver", root, "studs_buckle")
    # anneau en D + grelot
    bm = B()
    g_torus(bm, T(0, -1.075, -0.035) @ R("Y", 90), 0.035, 0.01, segs=20, rsegs=6)
    bell = spline([(0.0, 0.068), (0.03, 0.064), (0.055, 0.035), (0.062, -0.005), (0.07, -0.035), (0.078, -0.05),
                   (0.07, -0.058), (0.0, -0.05)], 4)
    Mbell = T(0, -1.13, -0.15) @ S(1.35)
    g_lathe(bm, Mbell, [(p.x, p.y) for p in bell], segs=40)
    g_torus(bm, Mbell @ T(0, 0, -0.012), 0.065, 0.0055, segs=40, rsegs=6)
    g_torus(bm, Mbell @ T(0, 0, 0.075) @ R("X", 90), 0.017, 0.006, segs=16, rsegs=6)
    mk(bm, "gold", root, "bell")
    bm = B()
    g_cookie(bm, face_front(V((0, -1.13 - 0.092, -0.197))), rrect2(0.066, 0.016, 0.008), 0.014, bevel=0.003, seg=2)
    g_sphere(bm, T(0, -1.212, -0.19), 0.013, 10, 6)
    mk(bm, "black", root, "bell_slit", wn=True)


@item("flower_lei", "scarf", "Collier de fleurs", 240, "rose", "jaune", "vert",
      "Un collier hawaïen de fleurs : aloha !")
def build_flower_lei(root):
    N = 14
    bm_m, bm_a, bm_c, bm_l = B(), B(), B(), B()
    for k in range(N):
        a = -math.pi / 2 + TAU * k / N
        p = ring_path(a, 1.06, 0.14, 0.0)
        rad = V((math.cos(a), math.sin(a), 0))
        nrm = (rad + V((0, 0, 0.35))).normalized()
        M = frame_z(p, nrm, (0, 0, 1))
        flower(bm_m if k % 2 == 0 else bm_a, bm_c, M, 0.165, n=5, cup=0.2, curl=0.25, thick=0.026, width=0.95,
               rot=k * 23, tilt=10, nu=6, nv=8, center_r=0.042)
        # feuilles entre les fleurs
        a2 = a + math.pi / N
        p2 = ring_path(a2, 1.02, 0.14, -0.04)
        rad2 = V((math.cos(a2), math.sin(a2), 0))
        tang = V((-math.sin(a2), math.cos(a2), 0))
        n2 = (rad2 + V((0, 0, 0.6))).normalized()
        d = (rad2 * 0.3 - V((0, 0, 1)) + tang * 0.3)
        d = (d - n2 * d.dot(n2)).normalized()
        g_leaf(bm_l, basis(d, n2.cross(d), n2, p2), 0.17, 0.08, 0.018, nu=7, nv=8, cup=0.2, curl=-0.1)
    mk(bm_m, "main", root, "flowers_a")
    mk(bm_a, "accent", root, "flowers_b")
    mk(bm_c, "white", root, "centers")
    mk(bm_l, "detail", root, "leaves")


@item("bandana", "neck", "Bandana", 110, "rouge", "blanc", "blanc",
      "Un bandana noué autour du cou, avec ses petits motifs.")
def build_bandana(root):
    def cloth(u, v, off=0.0):
        x0 = lerp(-1, 1, u)
        w = 0.2 * (1 - v) ** 0.95 + 0.022 * v
        x = x0 * w
        z = 0.012 - 0.2 * v * (1 - 0.15 * x0 * x0)
        y = -0.018 - 0.022 * v + 0.12 * (x / 0.2) ** 2 * (1 - v) ** 1.5 \
            + 0.008 * math.sin(x0 * math.pi * 2.5 + 0.6) * v ** 0.8 - 0.008 * (1 - x0 * x0) * v
        return (x, y + off, z)
    bm = B()
    g_loft(bm, I4, lambda u, v: cloth(u, v), 20, 14, closed_v=False)
    mk(bm, "main", root, "cloth", solid=0.006, solid_off=0, subsurf=1, even=False)
    # bord roule en haut
    bm = B()
    g_tube(bm, I4, [V(cloth(u, 0.0)) + V((0, 0.002, 0.006)) for u in [k / 24 for k in range(25)]], 0.012, segs=10,
           p=2.4, aspect=0.85)
    mk(bm, "main", root, "rolled_edge")

    def normal_at(u, v):
        du = V(cloth(min(u + 0.01, 1), v)) - V(cloth(max(u - 0.01, 0), v))
        dv = V(cloth(u, min(v + 0.01, 1))) - V(cloth(u, max(v - 0.01, 0)))
        n = du.cross(dv).normalized()
        return -n if n.y > 0 else n
    # liseres + motifs (petites fleurs a 4 petales)
    bm = B()
    for side in (0.08, 0.92):
        pts = [V(cloth(lerp(side, 0.5, v), v)) + normal_at(lerp(side, 0.5, v), v) * 0.0045 for v in
               [k / 20 * 0.92 + 0.04 for k in range(21)]]
        g_tube(bm, I4, pts, 0.0025, segs=6)
    flower4 = []
    for k in range(48):
        t = TAU * k / 48
        r = 0.011 * (0.55 + 0.45 * abs(math.cos(2 * t)))
        flower4.append((math.cos(t) * r, math.sin(t) * r))
    for (u, v) in ((0.3, 0.15), (0.5, 0.2), (0.7, 0.15), (0.4, 0.42), (0.6, 0.42), (0.5, 0.65), (0.2, 0.06),
                   (0.8, 0.06)):
        n = normal_at(u, v)
        g_cookie(bm, frame_z(V(cloth(u, v)) + n * 0.004, n, (0, 0, 1)) @ R("Z", u * 90), flower4, 0.002,
                 bevel=0.0008, seg=1)
    mk(bm, "detail", root, "pattern")


# ===========================================================================
#                                   DOS (suite)
# ===========================================================================
def feather_shape(u):
    u = min(max(u, 0.0), 1.0)
    return min(1.0, (u * 6) ** 0.5) * math.sqrt(max(0.0, 1 - u ** 2.5))


def feather_wing2(parent, sx, mat_f="main", mat_arm="main"):
    root_p = V((sx * 0.07, 0.05, 0.08))
    arm = spline([root_p, root_p + V((sx * 0.06, 0.03, 0.13)), root_p + V((sx * 0.17, 0.06, 0.26)),
                  root_p + V((sx * 0.3, 0.08, 0.31)), root_p + V((sx * 0.4, 0.09, 0.27))], 6)
    bm = B()
    g_tube(bm, I4, arm, lambda t: 0.042 * (1 - 0.5 * t), segs=14, hint=V((0, 1, 0)), aspect=0.8)
    mk(bm, mat_arm, parent, "arm")
    rows = [
        (6, 0.45, 1.0, 0.28, 0.24, 0.1, -80, -36, -0.004),
        (6, 0.04, 0.5, 0.22, 0.28, 0.1, -100, -84, 0.008),
        (9, 0.02, 0.97, 0.12, 0.11, 0.09, -98, -50, 0.022),
    ]
    bm = B()
    for (cnt, t0, t1, l0, l1, w, ang0, ang1, dy) in rows:
        for k in range(cnt):
            f = k / max(cnt - 1, 1)
            p, tg = path_at(arm, lerp(t0, t1, f))
            L = lerp(l0, l1, f)
            ang = math.radians(lerp(ang0, ang1, f))
            d = V((math.cos(ang) * sx, 0, math.sin(ang)))
            zax = V((0, 1, 0))
            yax = zax.cross(d).normalized()
            M = basis(d, yax, zax, p + V((0, dy, 0)) - d * 0.025)
            g_leaf(bm, M, L, w, 0.03, nu=8, nv=10, cup=-0.08, shape=feather_shape)
    mk(bm, mat_f, parent, "feathers")


def build_angel_wings(root):
    bm = B()
    g_cookie(bm, frame_z(V((0, 0.035, 0.08)), V((0, 1, 0)), (0, 0, 1)) @ T(0, 0.012, 0), heart2(0.05), 0.022,
             bevel=0.007, seg=3)
    mk(bm, "gold", root, "clasp", wn=True)
    for sx, nm in ((-1, "l"), (1, "r")):
        piv = empty("angel_wings_wing_%s" % nm, root, loc=(sx * 0.07, 0.05, 0.08))
        feather_wing2(piv, sx, "main", "main")


ITEMS[[i for i, it in enumerate(ITEMS) if it["id"] == "angel_wings"][0]]["fn"] = build_angel_wings


@item("bat_wings", "back", "Ailes de chauve-souris", 420, "violet", "noir", "noir",
      "Des petites ailes festonnées qui battent la nuit.", anim="flap")
def build_bat_wings(root):
    tips = [(0.5, 0.26), (0.55, 0.05), (0.43, -0.11), (0.25, -0.15)]
    wrist = V((0.22, 0.2))

    def scallop(a, b, depth=0.06, n=8):
        a, b = V(a), V(b)
        mid = (a + b) / 2
        inward = (wrist - mid).normalized()
        c = mid + inward * depth
        return [(1 - t) ** 2 * a + 2 * (1 - t) * t * c + t * t * b for t in [k / n for k in range(1, n)]]
    outline = [V((0.0, -0.03))]
    outline += scallop((0.0, -0.03), tips[3], 0.05)
    outline.append(V(tips[3]))
    for i in (3, 2, 1):
        outline += scallop(tips[i], tips[i - 1], 0.065)
        outline.append(V(tips[i - 1]))
    outline += [V((0.42, 0.25)), V((0.32, 0.23)), V((0.22, 0.21)), V((0.1, 0.13)), V((0.0, 0.07))]

    def bend(p):
        x = abs(p[0])
        return (p[0], p[1] + 0.03 + 0.28 * x * x, p[2])
    for sx, nm in ((-1, "l"), (1, "r")):
        piv = empty("bat_wings_wing_%s" % nm, root, loc=(sx * 0.06, 0.03, 0.06))
        Mw = T(sx * 0.06, 0.03, 0.06) @ S(sx, 1, 1) @ R("Z", -6) @ R("X", 90)
        bm = B()
        g_cookie(bm, Mw, fillet(outline, 0.008, 2), 0.01, bevel=0.0035, seg=2, warp=bend)
        mk(bm, "main", piv, "membrane", wn=True)
        bm = B()
        W3 = V(bend(Mw @ V((wrist.x, wrist.y, 0))))
        base = V(bend(Mw @ V((0.02, 0.06, 0))))
        g_tube(bm, I4, [base, base.lerp(W3, 0.5) + V((0, 0, 0.01)), W3], lambda t: 0.017 * (1 - 0.3 * t), segs=10)
        for tp in tips:
            end = V(bend(Mw @ V((tp[0], tp[1], 0))))
            mid = W3.lerp(end, 0.5)
            g_tube(bm, I4, [W3, mid, end], lambda t: 0.011 * (1 - 0.6 * t), segs=8)
        mk(bm, "detail", piv, "bones")
        bm = B()
        g_cyl(bm, T(W3 + V((0, 0, 0.022))) @ R("X", 0), 0.009, 0.0, 0.03, 10)
        mk(bm, "white", piv, "claw")
    bm = B()
    g_cookie(bm, frame_z(V((0, 0.03, 0.06)), V((0, 1, 0)), (0, 0, 1)), circle2(0.035, 24), 0.03, bevel=0.01, seg=3)
    mk(bm, "detail", root, "center", wn=True)


@item("butterfly_wings", "back", "Ailes de papillon", 480, "ciel", "rose", "jaune",
      "Des ailes de papillon aux motifs délicats.", anim="flap")
def build_butterfly_wings(root):
    up = [V((p.x, p.y)) for p in spline([(0.02, 0.0), (0.1, 0.1), (0.26, 0.24), (0.43, 0.25), (0.47, 0.14),
                                         (0.36, 0.04), (0.2, -0.01)], 6, closed=True)]
    lo = [V((p.x, p.y)) for p in spline([(0.02, -0.01), (0.18, -0.02), (0.3, -0.11), (0.26, -0.24), (0.14, -0.22),
                                         (0.05, -0.11)], 6, closed=True)]

    def scaled(o, s, c):
        return [c + (q - c) * s for q in o]

    def bend(p):
        x = abs(p[0])
        return (p[0], p[1] + 0.03 + 0.12 * x * x, p[2])
    for sx, nm in ((-1, "l"), (1, "r")):
        piv = empty("butterfly_wings_wing_%s" % nm, root, loc=(sx * 0.04, 0.035, 0.05))
        Mw = T(sx * 0.04, 0.035, 0.05) @ S(sx, 1, 1) @ R("Y", -5) @ R("X", 90)
        bm_b, bm_p, bm_d, bm_w, bm_k = B(), B(), B(), B(), B()
        for o, c in ((up, V((0.27, 0.13))), (lo, V((0.16, -0.12)))):
            g_cookie(bm_b, Mw, o, 0.012, bevel=0.004, seg=2, warp=bend)
            g_cookie(bm_p, Mw, scaled(o, 0.7, c), 0.0165, bevel=0.002, seg=1, warp=bend)
        # ocelles + points
        g_cookie(bm_d, Mw, circle2(0.042, 28, 0.32, 0.15), 0.019, bevel=0.002, seg=1, warp=bend)
        g_cookie(bm_w, Mw, circle2(0.02, 20, 0.32, 0.15), 0.0215, bevel=0.0015, seg=1, warp=bend)
        g_cookie(bm_d, Mw, circle2(0.03, 24, 0.19, -0.14), 0.019, bevel=0.002, seg=1, warp=bend)
        g_cookie(bm_w, Mw, circle2(0.013, 16, 0.19, -0.14), 0.0215, bevel=0.0015, seg=1, warp=bend)
        for (x, y, r) in ((0.42, 0.21, 0.012), (0.45, 0.16, 0.009), (0.38, 0.235, 0.009), (0.25, -0.215, 0.01),
                          (0.28, -0.17, 0.008)):
            g_cookie(bm_k, Mw, circle2(r, 14, x, y), 0.015, bevel=0.0015, seg=1, warp=bend)
        mk(bm_b, "main", piv, "wing", wn=True)
        mk(bm_p, "accent", piv, "pattern", wn=True)
        mk(bm_d, "detail", piv, "eyespots", wn=True)
        mk(bm_w, "white", piv, "eyespot_centers", wn=True)
        mk(bm_k, "black", piv, "edge_dots", wn=True)
    bm = B()
    g_sphere(bm, T(0, 0.04, 0.03) @ S(0.026, 0.026, 0.1), 1.0, 16, 12)
    mk(bm, "black", root, "body")


@item("backpack", "back", "Petit sac à dos", 260, "orange", "jaune", "marron",
      "Un petit sac à dos avec poche, fermeture éclair et porte-clés étoile.")
def build_backpack(root):
    bm = B()
    bmesh.ops.create_cube(bm, size=1.0, matrix=T(0, 0.1, -0.01) @ S(0.3, 0.14, 0.32))
    mk(bm, "main", root, "body", bevel=0.055, bevel_seg=5, smooth=True)
    # rabat superieur arrondi
    bm = B()
    bmesh.ops.create_cube(bm, size=1.0, matrix=T(0, 0.105, 0.125) @ S(0.29, 0.15, 0.07))
    mk(bm, "accent", root, "lid", bevel=0.03, bevel_seg=4)
    # poche avant
    bm = B()
    bmesh.ops.create_cube(bm, size=1.0, matrix=T(0, 0.185, -0.07) @ S(0.2, 0.05, 0.13))
    mk(bm, "accent", root, "pocket", bevel=0.022, bevel_seg=4)
    bm = B()
    pts = [V((x, 0.212, z)) for x, z in fillet([(-0.085, -0.125), (0.085, -0.125), (0.085, -0.015),
                                                (-0.085, -0.015)], 0.02, 3)]
    g_stitches(bm, pts + [pts[0]], lambda c: V((0, 1, 0)), 36, dash=0.5, r=0.0028)
    mk(bm, "white", root, "stitches")
    # fermeture eclair de la poche
    bm = B()
    zp = [V((x, 0.212, -0.03)) for x in [lerp(-0.075, 0.075, k / 20) for k in range(21)]]
    g_tube(bm, I4, zp, 0.0038, segs=6, rmod=lambda t, phi: 1 + 0.25 * abs(math.sin(t * math.pi * 30)))
    g_cookie(bm, frame_z(V((0.05, 0.216, -0.042)), V((0, 1, 0)), (0, 0, 1)), rrect2(0.014, 0.026, 0.005), 0.005,
             bevel=0.0015, seg=1)
    g_torus(bm, T(0.05, 0.218, -0.058) @ R("X", 90), 0.006, 0.0018, segs=12, rsegs=4)
    mk(bm, "silver", root, "zipper")
    bm = B()
    g_cookie(bm, frame_z(V((0.05, 0.222, -0.082)), V((0, 1, 0)), (0, 0, 1)), star2(0.018, 0.008, 5, 0.003), 0.007,
             bevel=0.0025, seg=2)
    mk(bm, "gold", root, "charm", wn=True)
    bm = B()
    g_cookie(bm, frame_z(V((-0.04, 0.213, -0.08)), V((0, 1, 0)), (0, 0, 1)) @ T(0, -0.012, 0), heart2(0.028), 0.006,
             bevel=0.002, seg=2)
    mk(bm, "detail", root, "patch", wn=True)
    # poignee + bretelles
    bm = B()
    g_tube(bm, I4, spline([(-0.04, 0.1, 0.155), (0.0, 0.1, 0.19), (0.04, 0.1, 0.155)], 6), 0.007, segs=8,
           hint=V((0, 1, 0)), aspect=1.8, p=3)
    for sx in (-1, 1):
        g_tube(bm, I4, spline([(sx * 0.09, 0.05, 0.12), (sx * 0.1, -0.0, 0.17), (sx * 0.12, -0.06, 0.17)], 6),
               0.006, segs=8, hint=V((1, 0, 0)), aspect=4.0, p=4)
        g_tube(bm, I4, spline([(sx * 0.12, 0.04, -0.15), (sx * 0.14, -0.02, -0.15), (sx * 0.15, -0.07, -0.12)], 6),
               0.006, segs=8, hint=V((1, 0, 0)), aspect=4.0, p=4)
    mk(bm, "detail", root, "straps")
    bm = B()
    for sx in (-1, 1):
        g_tube(bm, frame_z(V((sx * 0.1, 0.005, 0.168)), V((0, -0.3, 1)), (1, 0, 0)), c3(rrect2(0.034, 0.02, 0.006)),
               0.0028, segs=6, closed=True)
    mk(bm, "silver", root, "buckles")


@item("cape", "back", "Cape de héros", 340, "rouge", "jaune", "jaune",
      "Une grande cape qui flotte, avec col et fermoirs dorés.")
def build_cape(root):
    def cape(u, v, off=0.0):
        x0 = lerp(-1, 1, u)
        hw = lerp(0.28, 0.44, v ** 0.9)
        x = x0 * hw
        z = lerp(0.3, -0.38, v) + 0.014 * math.sin(x0 * math.pi * 3.5) * v ** 1.5
        wrap = lerp(0.22, 0.1, v ** 0.7)
        y = lerp(0.03, 0.12, v) - wrap * x0 * x0 + 0.03 * math.sin(x0 * math.pi * 3.5 + 0.4) * v ** 0.8
        return (x, y + off, z)
    bm = B()
    g_loft(bm, I4, lambda u, v: cape(u, v, 0.004), 22, 12, closed_v=False)
    mk(bm, "main", root, "outer", solid=0.005, solid_off=0, subsurf=1)
    bm = B()
    g_loft(bm, I4, lambda u, v: cape(u * 0.985 + 0.0075, v * 0.99, -0.003), 22, 12, closed_v=False)
    mk(bm, "accent", root, "lining", solid=0.004, solid_off=0, subsurf=1)
    # galon dore sur l'ourlet
    bm = B()
    hem = [V(cape(u, 1.0, 0.004)) for u in [k / 48 for k in range(49)]]
    g_tube(bm, I4, hem, 0.0055, segs=8)
    for sx in (-1, 1):
        g_cookie(bm, frame_z(V(cape(0.5 + sx * 0.5, 0.0, 0.0)) + V((sx * 0.005, -0.012, -0.01)),
                             V((sx * 0.6, -1, 0)).normalized(), (0, 0, 1)), circle2(0.026, 24), 0.012, bevel=0.004,
                 seg=2, puff=0.002)
    mk(bm, "gold", root, "trim_clasps", wn=True)
    bm = B()
    for sx in (-1, 1):
        g_gem(bm, frame_z(V(cape(0.5 + sx * 0.5, 0.0, 0.0)) + V((sx * 0.005, -0.012, -0.01)) +
                          V((sx * 0.6, -1, 0)).normalized() * 0.008, V((sx * 0.6, -1, 0)).normalized(), (0, 0, 1)),
              0.014, n=8)
    mk(bm, "gem_red", root, "clasp_gems", smooth=False)

    # col montant pointu
    def collar(u, v):
        x0 = lerp(-1, 1, u)
        base = V(cape(u, 0.0, 0.002))
        h = 0.06 + 0.035 * abs(x0) ** 3
        flare = 0.04 * v
        return (base.x * (1 + 0.12 * v), base.y + flare + 0.01 * v, base.z + h * v)
    bm = B()
    g_loft(bm, I4, collar, 20, 4, closed_v=False)
    mk(bm, "detail", root, "collar", solid=0.006, solid_off=0, subsurf=1)


@item("jetpack", "back", "Jetpack", 650, "blanc", "ciel", "rouge",
      "Deux réservoirs, des flammes et un cadran : décollage imminent !")
def build_jetpack(root):
    tank = spline([(0.0, 0.16), (0.04, 0.155), (0.062, 0.12), (0.066, 0.0), (0.066, -0.12), (0.058, -0.15),
                   (0.0, -0.16)], 4)
    bm = B()
    for sx in (-1, 1):
        g_lathe(bm, T(sx * 0.082, 0.11, -0.01), [(p.x, p.y) for p in tank], segs=40)
    mk(bm, "main", root, "tanks")
    bm = B()
    for sx in (-1, 1):
        g_lathe(bm, T(sx * 0.082, 0.11, 0.135), [(0.0, 0.035), (0.03, 0.03), (0.045, 0.012), (0.048, 0.0)], segs=32)
        # ailerons
        g_cookie(bm, T(sx * 0.148, 0.11, -0.11) @ S(sx, 1, 1) @ R("X", 90),
                 fillet([(0.0, -0.04), (0.05, -0.07), (0.05, -0.03), (0.0, 0.06)], 0.012, 3), 0.012, bevel=0.004,
                 seg=2)
    mk(bm, "detail", root, "caps_fins", wn=True)
    bm = B()
    for sx in (-1, 1):
        for zz in (0.07, -0.08):
            g_torus(bm, T(sx * 0.082, 0.11, zz), 0.068, 0.0065, segs=40, rsegs=6)
        g_lathe(bm, T(sx * 0.082, 0.11, -0.168), [(0.03, 0.0), (0.034, -0.02), (0.046, -0.045), (0.042, -0.05),
                                                   (0.028, -0.03), (0.02, -0.004)], segs=32, closed_u=True)
    mk(bm, "silver", root, "bands_nozzles")
    bm = B()
    for sx in (-1, 1):
        for k in range(8):
            a = TAU * k / 8
            n = V((math.cos(a), math.sin(a), 0))
            for zz in (0.07, -0.08):
                rivet(bm, V((sx * 0.082, 0.11, zz)) + n * 0.074, n, 0.0045)
    mk(bm, "gold", root, "rivets")
    # flammes
    bm = B()
    flame = spline([(0.0, 0.0), (0.028, -0.015), (0.03, -0.05), (0.018, -0.1), (0.0, -0.14)], 5)
    for sx in (-1, 1):
        g_lathe(bm, T(sx * 0.082, 0.11, -0.2), [(p.x, p.y) for p in flame], segs=24,
                mod=lambda a, s, r, z: (r * (1 + 0.15 * math.sin(5 * a + s * 6) * s), z))
    mk(bm, "glow", root, "flames")
    # bloc central + cadran
    bm = B()
    bmesh.ops.create_cube(bm, size=1.0, matrix=T(0, 0.075, 0.0) @ S(0.075, 0.07, 0.24))
    mk(bm, "accent", root, "spine", bevel=0.02, bevel_seg=4)
    Md = frame_z(V((0, 0.111, 0.05)), V((0, 1, 0)), (0, 0, 1))
    bm = B()
    g_cyl(bm, Md, 0.026, 0.026, 0.006, 32)
    mk(bm, "white", root, "dial")
    bm = B()
    g_tube(bm, Md @ T(0, 0, 0.003), c3(circle2(0.027, 40)), 0.004, segs=6, closed=True)
    g_cookie(bm, Md @ T(0, -0.055, 0.0), rrect2(0.04, 0.02, 0.006), 0.008, bevel=0.002, seg=1)
    mk(bm, "silver", root, "bezel")
    bm = B()
    g_tube(bm, Md @ T(0, 0, 0.004), [V((0, 0, 0)), V((0.012, 0.014, 0))], 0.0018, segs=4, cap_rings=1)
    for k in range(5):
        a = math.radians(-30 + k * 52)
        g_sphere(bm, Md @ T(math.cos(a) * 0.019, math.sin(a) * 0.019, 0.004), 0.0018, 6, 4)
    mk(bm, "black", root, "needle")
    bm = B()
    g_sphere(bm, T(-0.015, 0.113, -0.055) @ S(1, 0.5, 1), 0.007, 10, 6)
    mk(bm, "gem_green", root, "led_green")
    bm = B()
    g_sphere(bm, T(0.015, 0.113, -0.055) @ S(1, 0.5, 1), 0.007, 10, 6)
    mk(bm, "gem_red", root, "led_red")
    # bretelles
    bm = B()
    for sx in (-1, 1):
        g_tube(bm, I4, spline([(sx * 0.05, 0.04, 0.12), (sx * 0.07, -0.01, 0.17), (sx * 0.1, -0.07, 0.17)], 6),
               0.006, segs=8, hint=V((1, 0, 0)), aspect=3.8, p=4)
    mk(bm, "black", root, "straps")


# ===========================================================================
#                                 PLANCHES
# ===========================================================================
def build_all():
    roots = []
    for it in ITEMS:
        if ONLY and it["id"] not in ONLY:
            continue
        CUR["id"] = it["id"]
        CUR["n"] = 0
        CUR["pre"] = None
        r = empty(it["id"])
        t0 = time.time()
        it["fn"](r)
        roots.append(r)
        CUR["pre"] = None
        print("built %-18s %.2fs" % (it["id"], time.time() - t0))
    return roots


def tri_count(root):
    dg = bpy.context.evaluated_depsgraph_get()
    tot = 0
    objs = [root] + list(root.children_recursive)
    for o in objs:
        if o.type != "MESH":
            continue
        ev = o.evaluated_get(dg)
        me = ev.to_mesh()
        me.calc_loop_triangles()
        tot += len(me.loop_triangles)
        ev.to_mesh_clear()
    return tot


def validate(roots):
    ok = True
    for r in roots:
        for o in r.children_recursive:
            if o.type == "MESH" and len(o.data.materials) != 1:
                print("!! materials", o.name, len(o.data.materials))
                ok = False
        n = tri_count(r)
        flag = "  <-- TROP" if n > 15000 else ""
        pts = [o.matrix_world @ V(c) for o in r.children_recursive if o.type == "MESH" for c in o.bound_box]
        lo = V((min(q.x for q in pts), min(q.y for q in pts), min(q.z for q in pts)))
        hi = V((max(q.x for q in pts), max(q.y for q in pts), max(q.z for q in pts)))
        print("tris %-18s %6d%s   bbox x[%.2f %.2f] y[%.2f %.2f] z[%.2f %.2f]" % (r.name, n, flag, lo.x, hi.x, lo.y,
                                                                               hi.y, lo.z, hi.z))
        if n > 15000 or "--breakdown" in ARGS:
            dg = bpy.context.evaluated_depsgraph_get()
            for o in r.children_recursive:
                if o.type == "MESH":
                    me = o.evaluated_get(dg).to_mesh()
                    me.calc_loop_triangles()
                    print("      %-34s %6d" % (o.name, len(me.loop_triangles)))
                    o.evaluated_get(dg).to_mesh_clear()
    return ok


def export(roots):
    bpy.ops.object.select_all(action="DESELECT")
    for r in roots:
        r.select_set(True)
        for c in r.children_recursive:
            c.select_set(True)
    bpy.context.view_layer.objects.active = roots[0]
    bpy.ops.export_scene.gltf(
        filepath=OUT_GLB, export_format="GLB", use_selection=True, export_apply=True,
        export_yup=True, export_normals=True, export_materials="EXPORT", export_animations=False,
    )
    print("EXPORTED", OUT_GLB)


def write_manifest():
    data = {}
    for it in ITEMS:
        data[it["id"]] = {"name": it["name"], "slot": it["slot"], "fit": it["fit"], "price": it["price"],
                          "main": it["main"], "accent": it["accent"], "detail": it["detail"], "desc": it["desc"],
                          "anim": it["anim"]}
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, ensure_ascii=False)
    print("MANIFEST", OUT_JSON, len(data))


# ---------------------------------------------------------------------------
# Placement (formules du jeu, coordonnees Godot -> Blender)
# ---------------------------------------------------------------------------
C_G2B = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))
FUR = 0.05


def gv(a):
    return V((float(a[0]), float(a[1]), float(a[2])))


def godot_xform(sp, fit):
    """Transform du support (holder) en coordonnees Godot, comme dans pet.gd."""
    up_g = V((0, 1, 0))
    if fit == "hat":
        up = (gv(sp["hat_n"]) * 0.6 + up_g * 0.4).normalized()
        x = up.cross(V((0, 0, 1))).normalized()
        z = x.cross(up).normalized()
        s = sp["hat_width"] / 0.6
        o = gv(sp["hat"]) + up * FUR * 0.4 - up * 0.02
        return basis(x * s, up * s, z * s, o)
    if fit == "headphones":
        s = (sp["ear_width"] * 0.5 + FUR + 0.03) / 0.38
        return T(gv(sp["hat"]) + up_g * FUR * 0.5) @ S(s)
    if fit == "eyes":
        el, er = gv(sp["eye_l"]), gv(sp["eye_r"])
        g = sp["eye_style"] == "googly"
        s = (er.x - el.x) / 0.32 * (1.3 if g else 1.0)
        return T((el + er) * 0.5 + V((0, 0, FUR + (0.13 if g else 0.05)))) @ S(s)
    if fit == "mouth":
        return T(gv(sp["mouth"]) + V((0, 0, FUR * 0.6)))
    if fit == "neck":
        nn = (gv(sp["neck_n"]) + V((0, 0, 1))).normalized()
        x = up_g.cross(nn).normalized()
        y = nn.cross(x).normalized()
        return basis(x, y, nn, gv(sp["neck"]) + nn * (FUR + 0.02))
    if fit == "scarf":
        r = sp["neck_radius"] + FUR * 0.8
        return T(gv(sp["neck_center"])) @ S(r, r * 0.9, r)
    if fit == "back":
        n = (gv(sp["back_n"]) + V((0, 0, -1))).normalized()
        return T(gv(sp["back"]) + n * (FUR + 0.02))
    return I4


def blender_xform(sp, fit):
    return C_G2B @ godot_xform(sp, fit) @ C_G2B.inverted()


def preview_material(name, color_hex):
    """Materiau de rendu de previsualisation (plus joli que l'export, sans effet sur le glb)."""
    key = "PV_%s_%s" % (name, color_hex)
    m = bpy.data.materials.get(key)
    if m:
        return m
    m = bpy.data.materials.new(key)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes.get("Principled BSDF")
    c = hex_rgb(color_hex)
    base = name.split(".")[0]
    hx, metal, rough, ex = MAT_DEF.get(base, ("cccccc", 0, 0.5, {}))
    b.inputs["Base Color"].default_value = (*c, 1)
    b.inputs["Metallic"].default_value = metal
    b.inputs["Roughness"].default_value = rough
    if ex.get("fur"):
        b.inputs["Roughness"].default_value = 0.95
        try:
            b.inputs["Sheen Weight"].default_value = 0.8
            b.inputs["Sheen Tint"].default_value = (1, 1, 1, 1)
        except Exception:
            pass
        noise = nt.nodes.new("ShaderNodeTexNoise")
        noise.inputs["Scale"].default_value = 260.0
        noise.inputs["Detail"].default_value = 6.0
        bump = nt.nodes.new("ShaderNodeBump")
        bump.inputs["Strength"].default_value = 0.55
        bump.inputs["Distance"].default_value = 0.004
        nt.links.new(noise.outputs["Fac"], bump.inputs["Height"])
        nt.links.new(bump.outputs["Normal"], b.inputs["Normal"])
        mix = nt.nodes.new("ShaderNodeMix")
        mix.data_type = "RGBA"
        mix.inputs["Factor"].default_value = 1.0
        nt.links.new(noise.outputs["Fac"], mix.inputs["Factor"])
        mix.inputs["A"].default_value = (*[x * 0.75 for x in c], 1)
        mix.inputs["B"].default_value = (*[min(1, x * 1.15) for x in c], 1)
        nt.links.new(mix.outputs["Result"], b.inputs["Base Color"])
    if ex.get("coat"):
        try:
            b.inputs["Coat Weight"].default_value = 0.6
        except Exception:
            pass
    if ex.get("emit"):
        b.inputs["Emission Color"].default_value = (*c, 1)
        b.inputs["Emission Strength"].default_value = ex["emit"]
    if "alpha" in ex:
        b.inputs["Alpha"].default_value = ex["alpha"]
        try:
            m.surface_render_method = "BLENDED"
        except Exception:
            pass
    if base.startswith("gem_"):
        try:
            b.inputs["Coat Weight"].default_value = 1.0
            b.inputs["Specular IOR Level"].default_value = 1.0
        except Exception:
            pass
    return m


SHEETS = [
    ("hats1", ["crown", "tiara", "top_hat", "beret", "party_hat", "cap"], "mochi"),
    ("hats2", ["beanie", "cowboy", "chef", "witch", "wizard", "flower_crown"], "mochi"),
    ("hats3", ["flower", "ribbon", "bunny_ears", "cat_ears", "bear_ears", "halo"], "mochi"),
    ("hats4", ["propeller", "viking", "pirate", "sailor", "grad_cap", "santa"], "mochi"),
    ("hats5", ["bucket_hat", "devil_horns", "sprout", "cherry", "umbrella_hat", "headphones"], "mochi"),
    ("face1", ["round_glasses", "nerd_glasses", "sunglasses", "heart_glasses", "star_glasses", "monocle"], "mochi"),
    ("face2", ["glasses_3d", "ski_goggles", "mustache", "pacifier", "bubble_gum"], "mochi"),
    ("neck1", ["bow_tie", "necktie", "scarf", "pearl_necklace", "medal", "bell_collar"], "mochi"),
    ("neck2", ["flower_lei", "bandana"], "mochi"),
    ("back1", ["angel_wings", "bat_wings", "butterfly_wings", "backpack", "cape", "jetpack"], "mochi"),
    ("species1", ["crown", "headphones", "round_glasses", "top_hat", "scarf", "heart_glasses"],
     ["pico", "pico", "pico", "coco", "coco", "coco"]),
    ("species2", ["cap", "sunglasses", "bow_tie", "beanie", "angel_wings", "necktie"],
     ["kiwi", "kiwi", "kiwi", "nuage", "nuage", "nuage"]),
]

# vues par type d'ajustement : (azimut, elevation) principale et secondaire
VIEWS = {"hat": ((28, 16), (-60, 28)), "headphones": ((25, 12), (-15, 30)), "eyes": ((25, 8), (72, 6)),
         "mouth": ((25, 6), (65, 4)), "neck": ((28, 8), (-45, 4)), "scarf": ((28, 16), (-40, 25)),
         "back": ((35, 12), (150, 18))}
FUR_C = {"mochi": "f59ab8", "pico": "f7c948", "coco": "b04fc4", "nuage": "6fb1f2", "kiwi": "a8d94a"}
TILE = 560


def setup_render_scene():
    world_ = bpy.data.worlds.new("w")
    world_.use_nodes = True
    bg = world_.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (0.80, 0.82, 0.88, 1)
    bg.inputs["Strength"].default_value = 0.9
    SCENE.world = world_
    SCENE.render.engine = "BLENDER_EEVEE"
    try:
        SCENE.eevee.taa_render_samples = 32
        SCENE.eevee.use_raytracing = True
        SCENE.eevee.use_shadows = True
    except Exception:
        pass
    try:
        SCENE.view_settings.view_transform = "AgX"
    except Exception:
        pass
    SCENE.render.resolution_x = TILE
    SCENE.render.resolution_y = TILE


def render_previews():
    spec = json.load(open(SPECIES_JSON, encoding="utf-8"))
    meta = {it["id"]: it for it in ITEMS}
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for me in list(bpy.data.meshes):
        bpy.data.meshes.remove(me)
    bpy.ops.import_scene.gltf(filepath=BODIES_GLB)
    bodies = {o.name: o for o in bpy.data.objects if o.name.startswith("body_")}
    for o in bodies.values():
        o.hide_render = True
    bpy.ops.import_scene.gltf(filepath=OUT_GLB)
    acc_roots = {o.name: o for o in bpy.data.objects if o.parent is None and o.name in meta}
    for r in acc_roots.values():
        for o in [r] + list(r.children_recursive):
            o.hide_render = True
    setup_render_scene()
    for sheet_name, ids, species in SHEETS:
        if SHEETS_ONLY and sheet_name not in SHEETS_ONLY:
            continue
        multi = isinstance(species, list)
        sp_list = species if multi else [species] * len(ids)
        pairs = [(i, s) for i, s in zip(ids, sp_list) if i in acc_roots]
        if not pairs:
            continue
        tiles = []
        for iid, spn in pairs:
            v1, v2 = VIEWS[meta[iid]["fit"]]
            for k, (az, el) in enumerate((v1, v2)):
                label = iid if k == 0 else (spn if multi else "")
                tiles.append(render_tile(iid, spn, spec, meta, acc_roots, bodies, az, el, label, k))
        composite(tiles, 4, os.path.join(PREVIEW_DIR, "accessories_%s.png" % sheet_name))


def render_tile(iid, spn, spec, meta, acc_roots, bodies, az, el, label, k):
    tmp_objs = []
    sp = spec[spn]
    base = bodies["body_" + spn]
    b = base.copy()
    b.data = base.data.copy()
    link(b)
    tmp_objs.append(b)
    b.hide_render = False
    b.matrix_world = I4
    d = b.modifiers.new("fur", "DISPLACE")
    d.strength = 0.035
    d.mid_level = 0.0
    b.data.materials.clear()
    b.data.materials.append(preview_material("fur_main", FUR_C[spn]))
    it = meta[iid]
    cols = {"main": PALETTE[it["main"]], "accent": PALETTE[it["accent"]], "detail": PALETTE[it["detail"]],
            "fur_main": PALETTE[it["main"]], "fur_accent": PALETTE[it["accent"]]}

    def dup(o, parent):
        c = o.copy()
        link(c)
        tmp_objs.append(c)
        c.parent = parent
        c.hide_render = False
        if o.type == "MESH" and o.data.materials:
            mname = o.data.materials[0].name.split(".")[0]
            c.data = o.data.copy()
            c.data.materials.clear()
            c.data.materials.append(preview_material(mname, cols.get(mname, MAT_DEF.get(mname, ("cccccc",))[0])))
        for ch in o.children:
            dup(ch, c)
        return c
    rc = dup(acc_roots[iid], None)
    rc.matrix_world = blender_xform(sp, it["fit"])
    bpy.context.view_layer.update()
    azr, elr = math.radians(az), math.radians(el)
    view = V((math.sin(azr) * math.cos(elr), -math.cos(azr) * math.cos(elr), math.sin(elr)))
    right = V((0, 0, 1)).cross(view).normalized()
    upv = view.cross(right).normalized()
    pts = []
    for o in tmp_objs[1:]:
        if o.type == "MESH":
            pts += [o.matrix_world @ V(c) for c in o.bound_box]
    xs = [p.dot(right) for p in pts]
    ys = [p.dot(upv) for p in pts]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    ext = max(max(xs) - min(xs), max(ys) - min(ys))
    ext = max(ext * 1.3, 0.5)
    center = right * cx + upv * (cy - ext * 0.05)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    link(cam)
    tmp_objs.append(cam)
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = ext
    cam.data.clip_end = 50
    cam.matrix_world = basis(right, upv, view, center + view * 10)
    SCENE.camera = cam
    # lumieres relatives a la camera (x = droite, y = vers la camera, z = haut)
    for nm, dl, energy, size in (("key", (-0.8, 1.0, 1.2), 3.4, 25), ("fill", (1.0, 0.6, 0.2), 1.1, 45),
                                 ("rim", (0.5, -1.0, 0.9), 2.6, 15)):
        dw = (right * dl[0] + view * dl[1] + V((0, 0, dl[2]))).normalized()
        ld = bpy.data.lights.new(nm, "SUN")
        ld.energy = energy
        ld.angle = math.radians(size)
        lo = link(bpy.data.objects.new(nm, ld))
        lo.matrix_world = frame_z(V((0, 0, 0)), dw)
        tmp_objs.append(lo)
    if label:
        bpy.ops.object.text_add()
        tx = bpy.context.active_object
        tx.data.body = label
        tx.data.align_x = "CENTER"
        tx.data.size = ext * 0.065
        tx.matrix_world = basis(right, upv, view, center - upv * ext * 0.46 + view * 3)
        tx.data.materials.append(preview_material("black", "333333"))
        tmp_objs.append(tx)
    path = os.path.join(bpy.app.tempdir, "tile_%s_%s_%d.png" % (iid, spn, k))
    SCENE.render.filepath = path
    bpy.ops.render.render(write_still=True)
    for o in tmp_objs:
        bpy.data.objects.remove(o, do_unlink=True)
    return path


def composite(paths, ncol, out):
    import numpy as np
    nrow = (len(paths) + ncol - 1) // ncol
    W, H = TILE * ncol, TILE * nrow
    canvas = np.ones((H, W, 4), dtype=np.float32)
    canvas[..., :3] = 0.55
    for i, pth in enumerate(paths):
        img = bpy.data.images.load(pth)
        px = np.empty(img.size[0] * img.size[1] * 4, dtype=np.float32)
        img.pixels.foreach_get(px)
        px = px.reshape(img.size[1], img.size[0], 4)
        c, r = i % ncol, i // ncol
        y0 = H - (r + 1) * TILE
        canvas[y0:y0 + TILE, c * TILE:(c + 1) * TILE] = px[:TILE, :TILE]
        canvas[y0:y0 + TILE, c * TILE:c * TILE + 2, :3] = 0.45
        canvas[y0:y0 + 2, c * TILE:(c + 1) * TILE, :3] = 0.45
        bpy.data.images.remove(img)
    out_img = bpy.data.images.new("sheet", W, H, alpha=True)
    out_img.pixels.foreach_set(canvas.ravel())
    out_img.filepath_raw = out
    out_img.file_format = "PNG"
    out_img.save()
    bpy.data.images.remove(out_img)
    print("SHEET", out)


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    roots = build_all()
    validate(roots)
    if DO_EXPORT:
        export(roots)
        if not ONLY:
            write_manifest()
    if DO_PREVIEW:
        render_previews()
    print("DONE")
