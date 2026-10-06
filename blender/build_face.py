"""
Pompom - yeux et bouches du visage (styles achetables en boutique).

Lancement (headless) :
    blender --background --factory-startup --python blender/build_face.py [-- quick]

Sorties :
    godot/assets/models/face.glb      styles d'yeux (eye_<style>), bouches (mouth_<style>) et pieces
                                      d'expression partagees (eye_arc, brow, mouth_o, mouth_frown, mouth_flat)
    godot/data/face.json              manifeste boutique (noms, prix, amplitude du regard, couleur d'iris)
    blender/previews/face_*.png       planches de verification (EEVEE) sur les vrais corps

Convention : Blender Z = haut, -Y = avant (vers le spectateur). Godot : (x, z, -y).
Chaque piece : origine = centre sur la surface du visage, l'avant bombe vers -Y.
"""
import bpy
import bmesh
import json
import math
import os
import sys

import numpy as np
from mathutils import Matrix, Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_MODELS = os.path.join(ROOT, "godot", "assets", "models")
OUT_DATA = os.path.join(ROOT, "godot", "data")
OUT_PREV = os.path.join(ROOT, "blender", "previews")
os.makedirs(OUT_PREV, exist_ok=True)

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
QUICK = "quick" in ARGS

bpy.ops.wm.read_factory_settings(use_empty=True)
SCENE = bpy.context.scene
TAU = math.pi * 2


# ---------------------------------------------------------------------------
# Materiaux (le jeu remplace les shaders d'apres le nom ; ici = rendu d'apercu)
# ---------------------------------------------------------------------------
def srgb(h):
    h = h.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


MAT_DEF = {
    "eye_black": dict(col="0b0a0e", rough=0.16, coat=1.0),
    "eye_white": dict(col="fbfbfd", rough=0.3, coat=0.6),
    "glint": dict(col="ffffff", emit=3.0),
    "iris": dict(col="6fb1f2", rough=0.2, coat=1.0),
    "tongue": dict(col="ff7a8e", rough=0.35, coat=0.5),
    "tooth": dict(col="fff8ea", rough=0.25, coat=0.6),
    "mouth_inside": dict(col="5c1a1f", rough=0.5),
    "beak": dict(col="ffa62b", rough=0.3, coat=0.8),
    "blush_mark": dict(col="ff8fa8", rough=0.6),
}


def make_mat(name, col=None, rough=0.4, coat=0.0, emit=0.0):
    m = bpy.data.materials.get(name)
    if m is not None:
        return m
    d = dict(MAT_DEF.get(name, {}))
    if col is not None:
        d["col"] = col
    m = bpy.data.materials.new(name)
    try:
        m.use_nodes = True
    except Exception:
        pass
    c = srgb(d.get("col", "cccccc"))
    m.diffuse_color = (*c, 1.0)
    m.roughness = d.get("rough", rough)
    try:
        b = m.node_tree.nodes.get("Principled BSDF")
        b.inputs["Base Color"].default_value = (*c, 1.0)
        b.inputs["Roughness"].default_value = d.get("rough", rough)
        if d.get("coat", coat) > 0:
            b.inputs["Coat Weight"].default_value = d.get("coat", coat)
            b.inputs["Coat Roughness"].default_value = 0.05
        if d.get("emit", emit) > 0:
            b.inputs["Emission Color"].default_value = (*c, 1.0)
            b.inputs["Emission Strength"].default_value = d.get("emit", emit)
            b.inputs["Base Color"].default_value = (1, 1, 1, 1)
    except Exception as e:
        print("mat setup", name, e)
    return m


def mat(name):
    return make_mat(name)


# ---------------------------------------------------------------------------
# Utilitaires scene
# ---------------------------------------------------------------------------
CUR_COLL = [SCENE.collection]


def link(obj):
    CUR_COLL[0].objects.link(obj)
    return obj


def empty(name, parent=None, loc=(0, 0, 0)):
    e = bpy.data.objects.new(name, None)
    e.empty_display_size = 0.03
    link(e)
    if parent is not None:
        e.parent = parent
    e.location = loc
    return e


def mesh_obj(name, bm, material, parent, smooth=True, recalc=True):
    if recalc:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    o = link(bpy.data.objects.new(name, me))
    if smooth:
        me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
        me.update()
    o.data.materials.append(mat(material))
    if parent is not None:
        o.parent = parent
    return o


# ---------------------------------------------------------------------------
# SDF 2D (plan XZ : x = droite, z = haut). Negatif = dedans.
# ---------------------------------------------------------------------------
def sd_ellipse(a, b, cx=0.0, cz=0.0):
    def f(x, z):
        u, v = (x - cx) / a, (z - cz) / b
        return (math.hypot(u, v) - 1.0) * min(a, b)
    return f


def sd_circle(r, cx=0.0, cz=0.0):
    return lambda x, z: math.hypot(x - cx, z - cz) - r


def sd_capsule(ax, az, bx, bz, r):
    def f(x, z):
        px, pz = x - ax, z - az
        dx, dz = bx - ax, bz - az
        h = max(0.0, min(1.0, (px * dx + pz * dz) / (dx * dx + dz * dz)))
        return math.hypot(px - dx * h, pz - dz * h) - r
    return f


def sd_polygon(pts):
    n = len(pts)

    def f(x, z):
        d = (x - pts[0][0]) ** 2 + (z - pts[0][1]) ** 2
        s = 1.0
        j = n - 1
        for i in range(n):
            ex, ez = pts[j][0] - pts[i][0], pts[j][1] - pts[i][1]
            wx, wz = x - pts[i][0], z - pts[i][1]
            h = max(0.0, min(1.0, (wx * ex + wz * ez) / (ex * ex + ez * ez)))
            bx, bz = wx - ex * h, wz - ez * h
            d = min(d, bx * bx + bz * bz)
            c1 = z >= pts[i][1]
            c2 = z < pts[j][1]
            c3 = ex * wz > ez * wx
            if (c1 and c2 and c3) or ((not c1) and (not c2) and (not c3)):
                s = -s
            j = i
        return s * math.sqrt(d)
    return f


def sd_star5(r, rf, cx=0.0, cz=0.0):
    k1x, k1y = 0.809016994375, -0.587785252292
    k2x, k2y = -k1x, k1y

    def f(x, z):
        px, py = abs(x - cx), z - cz
        d = max(k1x * px + k1y * py, 0.0)
        px -= 2 * d * k1x
        py -= 2 * d * k1y
        d = max(k2x * px + k2y * py, 0.0)
        px -= 2 * d * k2x
        py -= 2 * d * k2y
        px = abs(px)
        py -= r
        bax, bay = rf * -k1y, rf * k1x - 1.0
        h = max(0.0, min(r, (px * bax + py * bay) / (bax * bax + bay * bay)))
        qx, qy = px - bax * h, py - bay * h
        s = 1.0 if (py * bax - px * bay) > 0 else -1.0
        return math.hypot(qx, qy) * s
    return f


def sd_heart(scale, cx=0.0, cz=0.0):
    """Coeur (iq) : pointe en bas. Recentre sur sa boite."""
    zc = 0.552 * scale

    def f(x, z):
        px = abs(x - cx) / scale
        py = (z - cz + zc) / scale
        if px + py > 1.0:
            d = math.hypot(px - 0.25, py - 0.75) - math.sqrt(2) / 4
        else:
            m = max(px + py, 0) * 0.5
            d = math.sqrt(min(px * px + (py - 1) ** 2, (px - m) ** 2 + (py - m) ** 2)) * (1 if px - py > 0 else -1)
        return d * scale
    return f


def sd_vesica(w, h, cx=0.0, cz=0.0):
    a, b = w / 2, h / 2
    rc = (a * a + b * b) / (2 * a)
    off = rc - a

    def f(x, z):
        return max(math.hypot(x - cx - off, z - cz) - rc, math.hypot(x - cx + off, z - cz) - rc)
    return f


def op_round(f, r):
    return lambda x, z: f(x, z) - r


def op_inset(f, d):
    return lambda x, z: f(x, z) + d


def op_and(*fs):
    return lambda x, z: max(g(x, z) for g in fs)


def op_sub(f, g):
    return lambda x, z: max(f(x, z), -g(x, z))


def ray_R(f, cx, cz, th, rmax=0.3):
    dx, dz = math.cos(th), math.sin(th)
    step = 0.0015
    r = 0.0
    while r < rmax:
        r += step
        if f(cx + dx * r, cz + dz * r) > 0:
            break
    lo, hi = r - step, r
    for _ in range(28):
        m = (lo + hi) * 0.5
        if f(cx + dx * m, cz + dz * m) > 0:
            hi = m
        else:
            lo = m
    return (lo + hi) * 0.5


# ---------------------------------------------------------------------------
# Formes "coussin" : contour 2D etoile autour d'un centre, profil super-ellipse
# (avant bombe vers -Y, arriere plus plat vers +Y). Renvoie la fonction de surface
# avant surf(x, z) -> y pour poser des decalcomanies (iris, reflets...) dessus.
# ---------------------------------------------------------------------------
def add_puffy(bm, f, c=(0.0, 0.0), H=0.03, back=0.012, p=3.0, pb=2.0, segs=64, nf=8, nb=2,
              y0=0.0, phase=0.0, conform=None, lift=0.0, deform=None, squash_r=None):
    cx, cz = c
    ths = [phase + TAU * k / segs for k in range(segs)]
    Rs = [ray_R(f, cx, cz, t) for t in ths]
    if squash_r:
        Rs = [r * squash_r for r in Rs]

    def pos(s, y, k):
        x = cx + Rs[k] * s * math.cos(ths[k])
        z = cz + Rs[k] * s * math.sin(ths[k])
        return x, y0 + y, z

    profile = []
    for i in range(1, nf + 1):
        a = (math.pi / 2) * (i / nf) ** 0.85
        profile.append((math.sin(a) ** (2 / p), -H * max(math.cos(a), 0.0) ** (2 / p)))
    for j in range(1, nb):
        a = math.pi / 2 + (math.pi / 2) * j / nb
        profile.append((math.sin(a) ** (2 / pb), back * (-math.cos(a)) ** (2 / pb)))

    def V(x, y, z):
        if conform is not None:
            y += conform(x, z) - lift
        if deform is not None:
            x, y, z = deform(x, y, z)
        return bm.verts.new((x, y, z))

    pf = V(cx, y0 - H, cz)
    rings = [[V(*pos(s, y, k)) for k in range(segs)] for s, y in profile]
    pb_ = V(cx, y0 + back, cz)
    for k in range(segs):
        k2 = (k + 1) % segs
        bm.faces.new((pf, rings[0][k], rings[0][k2]))
        bm.faces.new((pb_, rings[-1][k2], rings[-1][k]))
    for a, b in zip(rings[:-1], rings[1:]):
        for k in range(segs):
            k2 = (k + 1) % segs
            bm.faces.new((a[k], b[k], b[k2], a[k2]))

    def surf(x, z):
        th = math.atan2(z - cz, x - cx) - phase
        fk = (th % TAU) / TAU * segs
        k0 = int(fk) % segs
        t = fk - int(fk)
        R = Rs[k0] * (1 - t) + Rs[(k0 + 1) % segs] * t
        u = min(math.hypot(x - cx, z - cz) / max(R, 1e-6), 1.0)
        y = y0 - H * (1 - u ** p) ** (1 / p)
        if conform is not None:
            y += conform(x, z) - lift
        return y
    surf.Rs = Rs
    surf.ths = ths
    surf.c = c
    return surf


def puffy(name, f, material, parent, **kw):
    bm = bmesh.new()
    s = add_puffy(bm, f, **kw)
    o = mesh_obj(name, bm, material, parent)
    return o, s


def outline_pts(surf, offset=0.0, a0=None, a1=None, n=None):
    """Points du contour d'une forme (sens trigo) ; optionnellement l'arc [a0, a1] (radians)."""
    Rs, ths, (cx, cz) = surf.Rs, surf.ths, surf.c
    segs = len(Rs)

    def at(th):
        fk = ((th - ths[0]) % TAU) / TAU * segs
        k0 = int(fk) % segs
        t = fk - int(fk)
        R = Rs[k0] * (1 - t) + Rs[(k0 + 1) % segs] * t + offset
        return (cx + R * math.cos(th), cz + R * math.sin(th))
    if a0 is None:
        return [at(ths[0] + TAU * k / segs) for k in range(segs)]
    n = n or 24
    return [at(a0 + (a1 - a0) * i / (n - 1)) for i in range(n)]


def add_tube(bm, pts2d, radius, y0=0.0, ys=1.0, segs=12, closed=False, caps=True, conform=None, lift=0.0,
             cap_sub=2):
    """Tube le long d'une polyligne du plan XZ (section elliptique : ys etire la profondeur)."""
    P = [Vector((x, 0.0, z)) for x, z in pts2d]
    n = len(P)
    start = len(bm.verts)

    def tangent(i):
        if closed:
            return (P[(i + 1) % n] - P[(i - 1) % n]).normalized()
        return (P[min(i + 1, n - 1)] - P[max(i - 1, 0)]).normalized()

    n1 = Vector((0, -1, 0))
    rings, radii = [], []
    for i, p in enumerate(P):
        t = tangent(i)
        n2 = t.cross(n1).normalized()
        r = radius(i / max(n - 1, 1)) if callable(radius) else radius
        radii.append(r)
        rings.append([bm.verts.new(p + (n1 * math.cos(a) + n2 * math.sin(a)) * r)
                      for a in [TAU * k / segs for k in range(segs)]])
    pairs = list(zip(rings[:-1], rings[1:]))
    if closed:
        pairs.append((rings[-1], rings[0]))
    for a, b in pairs:
        for k in range(segs):
            bm.faces.new((a[k], a[(k + 1) % segs], b[(k + 1) % segs], b[k]))
    if not closed and caps:
        for idx in (0, -1):
            if radii[idx] > 1e-4:
                bmesh.ops.create_icosphere(bm, subdivisions=cap_sub, radius=radii[idx],
                                           matrix=Matrix.Translation(P[idx]))
    bm.verts.ensure_lookup_table()
    for v in bm.verts[start:]:
        y = y0 + v.co.y * ys
        if conform is not None:
            y += conform(v.co.x, v.co.z) - lift
        v.co.y = y


def tube_obj(name, pts2d, radius, material, parent, **kw):
    bm = bmesh.new()
    add_tube(bm, pts2d, radius, **kw)
    return mesh_obj(name, bm, material, parent)


def arc_pts(cx, cz, r, a0, a1, n=28, sx=1.0, sz=1.0):
    return [(cx + r * sx * math.cos(a0 + (a1 - a0) * i / (n - 1)),
             cz + r * sz * math.sin(a0 + (a1 - a0) * i / (n - 1))) for i in range(n)]


def bezier(p0, p1, p2, n=20):
    out = []
    for i in range(n):
        t = i / (n - 1)
        out.append(((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0],
                    (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]))
    return out


def taper(r_mid, r_end, power=1.0):
    return lambda t: r_end + (r_mid - r_end) * math.sin(math.pi * t) ** power


def glints(parent, surf, specs, name, lift=0.002):
    """Reflets (decalcomanies blanches non eclairees) epousant la surface."""
    bm = bmesh.new()
    for sp in specs:
        x, z, w, h = sp[:4]
        rot = sp[4] if len(sp) > 4 else 0.0
        if rot:
            ca, sa = math.cos(rot), math.sin(rot)
            base = sd_ellipse(w / 2, h / 2)
            f = (lambda base, ca, sa, x, z: lambda px, pz: base((px - x) * ca + (pz - z) * sa,
                                                                -(px - x) * sa + (pz - z) * ca))(base, ca, sa, x, z)
        else:
            f = sd_ellipse(w / 2, h / 2, x, z)
        add_puffy(bm, f, c=(x, z), H=min(w, h) * 0.12 + 0.002, back=0.002, p=2.2, segs=28, nf=4, nb=1,
                  conform=surf, lift=lift)
    return mesh_obj(name, bm, "glint", parent)


def sparkle_glint(parent, surf, x, z, rw, rh, name, lift=0.002, q=0.62):
    """Etoile a 4 branches (astroide a cotes concaves)."""
    def f(px, pz):
        u, v = abs(px - x) / rw, abs(pz - z) / rh
        return u ** q + v ** q - 1.0
    bm = bmesh.new()
    add_puffy(bm, op_round(f, 0.0), c=(x, z), H=0.004, back=0.002, p=2.2, segs=96, nf=5, nb=1, conform=surf,
              lift=lift, phase=0.0)
    return mesh_obj(name, bm, "glint", parent)


# ---------------------------------------------------------------------------
# Collections par style (pour exporter, puis instancier dans les apercus)
# ---------------------------------------------------------------------------
STYLE_ROOTS = {}


def begin(name):
    c = bpy.data.collections.new("C_" + name)
    SCENE.collection.children.link(c)
    CUR_COLL[0] = c
    root = empty(name)
    STYLE_ROOTS[name] = root
    return root


# ===========================================================================
# YEUX
# ===========================================================================
EYES = {}


def eye(style, name, price, pupil_range=(0.0, 0.0), iris="", scale=1.0, mirror=False):
    def deco(fn):
        EYES[style] = dict(fn=fn, name=name, price=price, pupil_range=list(pupil_range), iris=iris,
                           scale=scale, mirror=mirror)
        return fn
    return deco


@eye("dot", "Points", 0, (0.012, 0.01))
def eye_dot(root):
    g = empty("eye_dot_pupil", root)
    o, s = puffy("eye_dot_ball", sd_ellipse(0.05, 0.075), "eye_black", g, H=0.044, back=0.02, p=2.6, segs=64, nf=9)
    glints(g, s, [(-0.017, 0.03, 0.026, 0.034, -0.35), (0.018, -0.032, 0.012, 0.012)], "eye_dot_glint")


@eye("googly", "Yeux rigolos", 0, (0.03, 0.03))
def eye_googly(root):
    # legerement avance (y0) : le bord du blanc reste hors de la fourrure meme sur les visages inclines
    o, s = puffy("eye_googly_white", sd_ellipse(0.098, 0.1), "eye_white", root, H=0.036, back=0.03, p=4.0,
                 segs=72, nf=9, y0=-0.008)
    g = empty("eye_googly_pupil", root)
    po, ps = puffy("eye_googly_ball", sd_circle(0.047), "eye_black", g, H=0.013, back=0.004, p=2.4, segs=48, nf=6,
                   nb=1, y0=-0.042)
    glints(g, ps, [(-0.016, 0.017, 0.024, 0.028, -0.4), (0.018, -0.017, 0.009, 0.009)], "eye_googly_glint")


@eye("shiny", "Yeux brillants", 180, (0.011, 0.013), iris="6fb1f2", mirror=True)
def eye_shiny(root):
    wo, ws = puffy("eye_shiny_white", sd_ellipse(0.064, 0.092), "eye_white", root, H=0.032, back=0.02, p=4.0,
                   segs=56, nf=8)
    g = empty("eye_shiny_pupil", root)
    bm = bmesh.new()
    iris_s = add_puffy(bm, sd_ellipse(0.047, 0.062, 0, -0.008), c=(0, -0.008), H=0.004, back=0.004, p=2.5, segs=48,
                       nf=5, nb=1, conform=ws, lift=0.006)
    mesh_obj("eye_shiny_iris", bm, "iris", g)
    bm = bmesh.new()
    pup_s = add_puffy(bm, sd_ellipse(0.025, 0.035, 0, -0.012), c=(0, -0.012), H=0.003, back=0.003, p=2.5, segs=36,
                      nf=4, nb=1, conform=iris_s, lift=0.0015)
    # anneau sombre autour de l'iris (lisibilite)
    add_tube(bm, outline_pts(iris_s, -0.002), 0.0035, segs=8, closed=True, ys=0.6, conform=ws, lift=0.0075)
    mesh_obj("eye_shiny_black", bm, "eye_black", g)
    glints(g, pup_s, [(-0.019, 0.016, 0.03, 0.038, -0.3), (0.019, -0.032, 0.011, 0.011)], "eye_shiny_glint",
           lift=0.0015)
    # ligne de cils superieure (epaisse vers l'exterieur = +X, petit relevé)
    pts = outline_pts(ws, -0.003, math.radians(160), math.radians(16), 24)
    pts += [(0.066, 0.046), (0.072, 0.058)]
    tube_obj("eye_shiny_lash", pts, lambda t: 0.004 + 0.0062 * math.sin(math.pi * min(t * 1.12, 1.0)) ** 0.7
             if t < 0.93 else 0.0045, "eye_black", root, y0=-0.016, ys=1.4, segs=10)


@eye("button", "Boutons", 120)
def eye_button(root):
    R = 0.063

    def deform(x, y, z):
        r = math.hypot(x, z)
        y += 0.007 * max(0.0, 1 - (r / 0.044) ** 2)  # cuvette centrale
        y -= 0.006 * math.exp(-((r - 0.05) / 0.009) ** 2)  # rebord
        return x, y, z
    bm = bmesh.new()
    s = add_puffy(bm, sd_circle(R), H=0.03, back=0.014, p=3.0, segs=64, nf=11, nb=2, deform=deform)
    btn = mesh_obj("eye_button_disc", bm, "eye_black", root)
    holes = [(0.016, 0.016), (-0.016, 0.016), (-0.016, -0.016), (0.016, -0.016)]
    # trous : booleen
    cutters = []
    for hx, hz in holes:
        bpy.ops.mesh.primitive_cylinder_add(vertices=20, radius=0.0072, depth=0.064, location=(hx, -0.04, hz),
                                            rotation=(math.pi / 2, 0, 0))
        cutters.append(bpy.context.active_object)
    bpy.ops.object.select_all(action="DESELECT")
    for c in cutters[1:]:
        c.select_set(True)
    cutters[0].select_set(True)
    bpy.context.view_layer.objects.active = cutters[0]
    bpy.ops.object.join()
    cutter = bpy.context.active_object
    m = btn.modifiers.new("holes", "BOOLEAN")
    m.operation = "DIFFERENCE"
    m.object = cutter
    try:
        m.solver = "EXACT"
    except Exception:
        pass
    with bpy.context.temp_override(object=btn, active_object=btn, selected_objects=[btn]):
        bpy.ops.object.modifier_apply(modifier=m.name)
    bpy.data.objects.remove(cutter, do_unlink=True)
    btn.data.materials.clear()
    btn.data.materials.append(mat("eye_black"))
    btn.data.polygons.foreach_set("material_index", [0] * len(btn.data.polygons))
    try:
        btn.data.set_sharp_from_angle(angle=math.radians(50))
    except Exception as e:
        print("sharp", e)

    def btn_surf(x, z):
        x2, y2, z2 = deform(x, s(x, z), z)
        return y2

    # fil en X (blanc)
    bm = bmesh.new()
    for (ax, az), (bx, bz) in ((holes[0], holes[2]), (holes[1], holes[3])):
        pts = [(ax + (bx - ax) * i / 15, az + (bz - az) * i / 15) for i in range(16)]
        add_tube(bm, pts, 0.0052, segs=10, y0=-0.0035, conform=lambda x, z: btn_surf(x, z) - 0.006 * max(
            0, 1 - (math.hypot(x, z) / 0.024) ** 2) + 0.004 * math.exp(-((math.hypot(x, z) - 0.0226) / 0.003) ** 2))
    mesh_obj("eye_button_thread", bm, "eye_white", root)
    # reflet en arc sur le rebord
    bm = bmesh.new()
    add_tube(bm, arc_pts(0, 0, 0.05, math.radians(115), math.radians(158), 14), taper(0.0042, 0.002), segs=8,
             ys=0.5, conform=btn_surf, lift=0.0022)
    add_puffy(bm, sd_circle(0.0045, 0.04, -0.026), c=(0.04, -0.026), H=0.0025, back=0.002, segs=20, nf=3, nb=1,
              conform=btn_surf, lift=0.002)
    mesh_obj("eye_button_glint", bm, "glint", root)


@eye("star", "Étoiles", 200, iris="ffcc33")
def eye_star(root):
    base = op_round(sd_star5(0.072, 0.5, 0, -0.006), 0.009)
    o, s = puffy("eye_star_back", base, "eye_black", root, c=(0, -0.004), H=0.04, back=0.02, p=3.0, segs=80,
                 nf=8, phase=math.pi / 2)
    bm = bmesh.new()
    st = add_puffy(bm, op_inset(base, 0.0085), c=(0, -0.004), H=0.004, back=0.003, p=2.5, segs=80, nf=5, nb=1,
                   phase=math.pi / 2, conform=s, lift=0.004)
    mesh_obj("eye_star_fill", bm, "iris", root)
    glints(root, st, [(-0.017, 0.016, 0.022, 0.028, -0.4), (0.014, -0.022, 0.009, 0.009)], "eye_star_glint")


@eye("heart", "Cœurs", 220, iris="ff5d86")
def eye_heart(root):
    base = op_round(sd_heart(0.118), 0.004)
    o, s = puffy("eye_heart_back", base, "eye_black", root, c=(0, 0.004), H=0.04, back=0.02, p=3.0, segs=80, nf=8,
                 phase=math.pi / 2)
    bm = bmesh.new()
    hs = add_puffy(bm, op_inset(base, 0.0085), c=(0, 0.004), H=0.004, back=0.003, p=2.5, segs=80, nf=5, nb=1,
                   phase=math.pi / 2, conform=s, lift=0.004)
    mesh_obj("eye_heart_fill", bm, "iris", root)
    glints(root, hs, [(-0.03, 0.024, 0.024, 0.02, 0.5), (0.03, 0.025, 0.009, 0.009)], "eye_heart_glint")


@eye("sleepy", "Endormis", 80)
def eye_sleepy(root):
    top = 0.016
    f = op_round(op_and(sd_ellipse(0.046, 0.058, 0, top - 0.006), lambda x, z: z - (top - 0.006)), 0.006)
    o, s = puffy("eye_sleepy_ball", f, "eye_black", root, c=(0, -0.014), H=0.04, back=0.02, p=2.6, segs=64, nf=9)
    glints(root, s, [(-0.019, -0.016, 0.017, 0.013, -0.25), (0.017, -0.036, 0.008, 0.008)], "eye_sleepy_glint")
    pts = [(x, top + 0.006 * (1 - (x / 0.066) ** 2) - 0.004 * max(0, abs(x) / 0.066 - 0.7) / 0.3)
           for x in [-0.066 + 0.132 * i / 27 for i in range(28)]]
    tube_obj("eye_sleepy_lid", pts, taper(0.0125, 0.0075, 0.6), "eye_black", root, y0=-0.017, ys=1.9, segs=12)


@eye("lashes", "Cils", 100, mirror=True)
def eye_lashes(root):
    o, s = puffy("eye_lashes_ball", sd_ellipse(0.047, 0.07, 0, -0.006), "eye_black", root, c=(0, -0.006), H=0.042,
                 back=0.02, p=2.6, segs=64, nf=9)
    glints(root, s, [(-0.016, 0.022, 0.024, 0.031, -0.35), (0.017, -0.036, 0.011, 0.011)], "eye_lashes_glint")
    bm = bmesh.new()
    for ang, ln, curl in ((62, 0.03, 0.55), (36, 0.034, 0.5), (12, 0.03, 0.45)):
        a = math.radians(ang)
        bx, bz = 0.047 * 0.9 * math.cos(a), -0.006 + 0.07 * 0.9 * math.sin(a)
        nx, nz = math.cos(a) / 0.047, math.sin(a) / 0.07
        nl = math.hypot(nx, nz)
        nx, nz = nx / nl, nz / nl
        # vers l'exterieur puis courbe vers le haut
        p1 = (bx + nx * ln * 0.6, bz + nz * ln * 0.6)
        p2 = (bx + nx * ln * 0.8 + 0.006, bz + nz * ln * 0.5 + ln * curl * 0.75)
        add_tube(bm, bezier((bx, bz), p1, p2, 14), lambda t: 0.0062 - 0.0035 * t, segs=10, y0=-0.016, ys=1.2)
    mesh_obj("eye_lashes_lash", bm, "eye_black", root)


@eye("beady", "Petites perles", 60, (0.012, 0.01))
def eye_beady(root):
    g = empty("eye_beady_pupil", root)
    r, cy = 0.029, -0.014
    bpy.ops.mesh.primitive_uv_sphere_add(segments=36, ring_count=18, radius=r, location=(0, cy, 0))
    b = bpy.context.active_object
    b.name = "eye_beady_ball"
    b.data.polygons.foreach_set("use_smooth", [True] * len(b.data.polygons))
    b.data.materials.append(mat("eye_black"))
    b.parent = g
    if b.users_collection[0] != CUR_COLL[0]:
        for c in b.users_collection:
            c.objects.unlink(b)
        CUR_COLL[0].objects.link(b)

    def surf(x, z):
        d = r * r - x * x - z * z
        return cy - math.sqrt(max(d, 0.0))
    glints(g, surf, [(-0.009, 0.01, 0.012, 0.014, -0.4)], "eye_beady_glint", lift=0.001)


@eye("sparkle", "Étincelles", 150, (0.01, 0.008))
def eye_sparkle(root):
    g = empty("eye_sparkle_pupil", root)
    o, s = puffy("eye_sparkle_ball", sd_ellipse(0.054, 0.078), "eye_black", g, H=0.045, back=0.02, p=2.6, segs=64,
                 nf=9)
    sparkle_glint(g, s, -0.014, 0.024, 0.027, 0.035, "eye_sparkle_star")
    glints(g, s, [(0.022, -0.03, 0.013, 0.013), (0.006, -0.046, 0.007, 0.007)], "eye_sparkle_glint")


@eye("cat", "Yeux de chat", 160, (0.014, 0.01), iris="a6d84b")
def eye_cat(root):
    o, s = puffy("eye_cat_back", sd_ellipse(0.056, 0.074), "eye_black", root, H=0.042, back=0.02, p=2.8, segs=64,
                 nf=9)
    bm = bmesh.new()
    ir = add_puffy(bm, sd_ellipse(0.048, 0.066), H=0.003, back=0.003, p=2.5, segs=56, nf=5, nb=1, conform=s,
                   lift=0.003)
    mesh_obj("eye_cat_iris", bm, "iris", root)
    g = empty("eye_cat_pupil", root)
    bm = bmesh.new()
    sl = add_puffy(bm, op_round(sd_vesica(0.018, 0.088), 0.002), H=0.004, back=0.003, p=2.4, segs=48, nf=5, nb=1,
                   conform=ir, lift=0.0015)
    mesh_obj("eye_cat_slit", bm, "eye_black", g)
    glints(g, ir, [(-0.021, 0.026, 0.02, 0.026, -0.35), (0.02, -0.03, 0.009, 0.009)], "eye_cat_glint",
           lift=0.006)


@eye("puppy", "Yeux de chiot", 140, (0.01, 0.008), iris="7ab8ff")
def eye_puppy(root):
    g = empty("eye_puppy_pupil", root)
    o, s = puffy("eye_puppy_ball", sd_ellipse(0.06, 0.08), "eye_black", g, H=0.046, back=0.02, p=2.5, segs=64,
                 nf=9)
    bm = bmesh.new()
    pts = arc_pts(0, 0.004, 1.0, math.radians(208), math.radians(332), 24, sx=0.044, sz=0.062)
    add_tube(bm, pts, taper(0.0085, 0.0015, 0.8), segs=10, ys=0.35, conform=s, lift=0.003, caps=False)
    mesh_obj("eye_puppy_shine", bm, "iris", g)
    glints(g, s, [(-0.02, 0.026, 0.034, 0.042, -0.4), (0.024, -0.006, 0.014, 0.014),
                  (0.008, 0.05, 0.007, 0.007)], "eye_puppy_glint")


@eye("swirl", "Spirales", 250)
def eye_swirl(root):
    o, s = puffy("eye_swirl_white", sd_circle(0.068), "eye_white", root, H=0.034, back=0.02, p=3.5, segs=56, nf=8)
    bm = bmesh.new()
    turns = 2.6
    pts = []
    for i in range(80):
        t = i / 79
        a = math.pi / 2 + t * turns * TAU
        rr = 0.004 + 0.044 * t
        pts.append((rr * math.cos(a), rr * math.sin(a)))
    add_tube(bm, pts, lambda t: 0.0042 + 0.0018 * t, segs=8, ys=0.7, conform=s, lift=0.0015)
    add_tube(bm, outline_pts(s, -0.002), 0.0048, segs=8, closed=True, ys=1.0, y0=-0.004)
    mesh_obj("eye_swirl_spiral", bm, "eye_black", root)


# ===========================================================================
# BOUCHES
# ===========================================================================
MOUTHS = {}
LR = 0.0105  # rayon des traits
LY0, LYS = -0.014, 2.0  # plan et etirement en profondeur des traits


def mouth(style, name, price):
    def deco(fn):
        MOUTHS[style] = dict(fn=fn, name=name, price=price)
        return fn
    return deco


def line(name, pts, parent, r=LR, end=0.75, mat_="eye_black", **kw):
    kw.setdefault("y0", LY0)
    kw.setdefault("ys", LYS)
    return tube_obj(name, pts, taper(r, r * end, 0.7) if end != 1 else r, mat_, parent, segs=kw.pop("segs", 16),
                    **kw)


def shift(pts, dx=0.0, dz=0.0):
    return [(x + dx, z + dz) for x, z in pts]


@mouth("smile", "Sourire", 0)
def mouth_smile(root):
    line("mouth_smile_line", shift(arc_pts(0, 0.036, 0.058, math.radians(-138), math.radians(-42), 30), 0, 0.006),
         root)


@mouth("cat", "Bouche de chat", 60)
def mouth_cat(root):
    bm = bmesh.new()
    for cx in (-0.023, 0.023):
        add_tube(bm, shift(arc_pts(cx, 0.0, 0.023, math.pi, TAU, 24, sz=0.8), 0, 0.008), taper(LR, LR * 0.8),
                 y0=LY0, ys=LYS)
    mesh_obj("mouth_cat_line", bm, "eye_black", root)


def d_shape(w, top, bottom, r=0.007):
    a = w / 2
    b = top - bottom
    return op_round(op_and(sd_ellipse(a - r, b - r, 0, top - r), lambda x, z: z - (top - r)), r)


@mouth("open", "Grand sourire", 80)
def mouth_open(root):
    f = d_shape(0.1, 0.024, -0.032)
    o, s = puffy("mouth_open_inside", f, "mouth_inside", root, c=(0, 0.0), H=0.006, back=0.012, p=3.0, segs=64,
                 nf=6, y0=-0.012)
    tf = op_and(op_inset(f, 0.004), sd_circle(0.03, 0.0, -0.04))
    puffy("mouth_open_tongue", tf, "tongue", root, c=(0, -0.022), H=0.007, back=0.004, p=2.5, segs=48, nf=6, nb=1,
          y0=-0.016)
    tube_obj("mouth_open_rim", outline_pts(s, 0.0), 0.0058, "eye_black", root, closed=True, y0=-0.018, ys=1.5,
             segs=10)


@mouth("fang", "Petit croc", 100)
def mouth_fang(root):
    pts = shift(arc_pts(0, 0.036, 0.056, math.radians(-136), math.radians(-44), 30), 0, 0.012)
    line("mouth_fang_line", pts, root)
    fx = 0.019
    fz = 0.036 + 0.012 - math.sqrt(0.056 ** 2 - fx ** 2)
    f = op_round(sd_polygon([(fx - 0.0095, fz + 0.002), (fx + 0.0095, fz + 0.004), (fx + 0.0015, fz - 0.024)]),
                 0.003)
    puffy("mouth_fang_tooth", f, "tooth", root, c=(fx, fz - 0.007), H=0.011, back=0.004, p=2.6, segs=40, nf=6, nb=1,
          y0=-0.02)


@mouth("grin", "Rire éclatant", 120)
def mouth_grin(root):
    top = 0.022

    def ztop(x):
        return top - 0.012 * (x / 0.07) ** 2

    r = 0.008
    base = op_and(sd_ellipse(0.07 - r, 0.056 - r, 0, top - r), lambda x, z: (z - (ztop(x) - r)) * 0.9)
    f = op_round(base, r)
    o, s = puffy("mouth_grin_inside", f, "mouth_inside", root, c=(0, -0.006), H=0.006, back=0.012, p=3.0, segs=56,
                 nf=5, y0=-0.012)
    inner = op_inset(f, 0.003)
    bm = bmesh.new()
    n = 6
    x0, x1 = -0.054, 0.054
    wtooth = (x1 - x0) / n
    for i in range(n):
        a, b = x0 + i * wtooth + 0.0014, x0 + (i + 1) * wtooth - 0.0014
        cxm = (a + b) / 2
        tf = op_and(inner, lambda x, z, a=a, b=b: max(a - x, x - b), lambda x, z: (ztop(x) - 0.019) - z)
        tf = op_round(op_inset(tf, 0.0015), 0.0015)
        add_puffy(bm, tf, c=(cxm, ztop(cxm) - 0.01), H=0.006, back=0.004, p=3.0, segs=24, nf=4, nb=1, y0=-0.016)
    mesh_obj("mouth_grin_teeth", bm, "tooth", root)
    tf = op_and(inner, sd_circle(0.034, 0.0, -0.05))
    puffy("mouth_grin_tongue", tf, "tongue", root, c=(0, -0.027), H=0.006, back=0.004, p=2.5, segs=48, nf=5, nb=1,
          y0=-0.016)
    tube_obj("mouth_grin_rim", outline_pts(s, 0.0), 0.0058, "eye_black", root, closed=True, y0=-0.019, ys=1.5,
             segs=10)


@mouth("tongue", "Langue tirée", 90)
def mouth_tongue(root):
    pts = shift(arc_pts(0, 0.04, 0.056, math.radians(-132), math.radians(-48), 30), 0, 0.0)
    line("mouth_tongue_line", pts, root)
    cx = 0.007
    zl = 0.04 - 0.056

    zl -= 0.004

    def groove(x, y, z):
        k = math.exp(-((x - cx) / 0.004) ** 2) * max(0.0, min(1.0, (z - (zl - 0.036)) / 0.012))
        return x, y + 0.004 * k * (1 if y < -0.012 else 0), z

    f = sd_capsule(cx, zl - 0.006, cx, zl - 0.026, 0.0175)
    puffy("mouth_tongue_tongue", f, "tongue", root, c=(cx, zl - 0.018), H=0.016, back=0.006, p=2.4, segs=56, nf=8,
          nb=1, y0=-0.016, deform=groove)


@mouth("wavy", "Gêné", 70)
def mouth_wavy(root):
    pts = [(x, 0.0075 * math.sin(4 * math.pi * (x + 0.048) / 0.096)) for x in
           [-0.048 + 0.096 * i / 47 for i in range(48)]]
    line("mouth_wavy_line", pts, root, r=0.0092, end=0.8)


@mouth("beak", "Bec", 150)
def mouth_beak(root):
    # bec superieur : dome dont le bord inferieur fait un petit sourire
    up_f = op_round(op_and(sd_ellipse(0.05, 0.029, 0, 0.006),
                           lambda x, z: (-0.006 + 0.013 * (x / 0.054) ** 2) - z), 0.01)
    o, us = puffy("mouth_beak_upper", up_f, "beak", root, c=(0, 0.01), H=0.06, back=0.01, p=2.3, segs=64, nf=10)
    # bec inferieur : petit menton qui depasse sous le sourire
    puffy("mouth_beak_lower", sd_ellipse(0.036, 0.016, 0, -0.015), "beak", root, c=(0, -0.015), H=0.038,
          back=0.008, p=2.3, segs=48, nf=8, y0=0.0)
    bm = bmesh.new()
    for sx in (-1, 1):
        add_puffy(bm, sd_ellipse(0.0052, 0.0032, sx * 0.0145, 0.022), c=(sx * 0.0145, 0.022), H=0.0015, back=0.0015,
                  p=2.2, segs=16, nf=3, nb=1, conform=us, lift=-0.0005)
    mesh_obj("mouth_beak_nostrils", bm, "eye_black", root)


@mouth("kiss", "Bisou", 110)
def mouth_kiss(root):
    bm = bmesh.new()
    r = 0.0115
    add_tube(bm, arc_pts(-0.002, r, r, math.radians(160), math.radians(-90), 26), taper(0.0098, 0.0082),
             y0=LY0, ys=LYS, segs=14)
    add_tube(bm, arc_pts(-0.002, -r, r, math.radians(90), math.radians(-160), 26), taper(0.0098, 0.0082),
             y0=LY0, ys=LYS, segs=14)
    mesh_obj("mouth_kiss_line", bm, "eye_black", root)


@mouth("tiny", "Mini sourire", 40)
def mouth_tiny(root):
    line("mouth_tiny_line", shift(arc_pts(0, 0.022, 0.026, math.radians(-145), math.radians(-35), 20), 0, -0.006),
         root, r=0.0095, end=0.8)


@mouth("bunny", "Lapinou", 130)
def mouth_bunny(root):
    bm = bmesh.new()
    j = (0.0, 0.006)
    add_tube(bm, [(0.0, 0.02), j], 0.0075, y0=LY0, ys=LYS, segs=14)
    for sx in (-1, 1):
        add_tube(bm, bezier(j, (sx * 0.006, -0.008), (sx * 0.023, -0.006), 16), taper(0.0078, 0.0068), y0=LY0,
                 ys=LYS, segs=14)
    mesh_obj("mouth_bunny_line", bm, "eye_black", root)
    bm = bmesh.new()
    for sx in (-1, 1):
        cx = sx * 0.0068
        f = op_round(sd_polygon([(cx - 0.0042, 0.0), (cx + 0.0042, 0.0), (cx + 0.0042, -0.02),
                                 (cx - 0.0042, -0.02)]), 0.0032)
        add_puffy(bm, f, c=(cx, -0.01), H=0.007, back=0.004, p=2.6, segs=36, nf=5, nb=1, y0=-0.019)
    mesh_obj("mouth_bunny_teeth", bm, "tooth", root)


@mouth("blep", "Blep", 90)
def mouth_blep(root):
    line("mouth_blep_line", shift(arc_pts(0, 0.06, 0.066, math.radians(-120), math.radians(-60), 24), 0, 0.004),
         root, r=0.0098)
    cx = 0.012
    f = sd_capsule(cx, -0.009, cx, -0.014, 0.0115)
    puffy("mouth_blep_tongue", f, "tongue", root, c=(cx, -0.012), H=0.013, back=0.005, p=2.4, segs=40, nf=6, nb=1,
          y0=-0.02)


# ===========================================================================
# PIECES D'EXPRESSION PARTAGEES
# ===========================================================================
def build_shared():
    roots = []
    c = bpy.data.collections.new("C_shared")
    SCENE.collection.children.link(c)
    CUR_COLL[0] = c
    # oeil ferme heureux "∩"
    pts = arc_pts(0, -0.03, 0.058, math.radians(40), math.radians(140), 30)
    zc = (0.028 + (-0.03 + 0.058 * math.sin(math.radians(40)))) / 2
    roots.append(tube_obj("eye_arc", shift(pts, 0, -zc), taper(0.014, 0.0105, 0.6), "eye_black", None,
                          y0=-0.016, ys=2.0, segs=14))
    # sourcil
    pts = [(x, 0.004 * (1 - (x / 0.044) ** 2) - 0.002) for x in [-0.044 + 0.088 * i / 19 for i in range(20)]]
    roots.append(tube_obj("brow", pts, taper(0.0125, 0.0095, 0.5), "eye_black", None, y0=-0.013, ys=1.8, segs=12))
    # bouche "o" surprise
    r = empty("mouth_o")
    f = sd_ellipse(0.021, 0.026)
    o, s = puffy("mouth_o_inside", f, "mouth_inside", r, H=0.006, back=0.012, p=3.0, segs=48, nf=6, y0=-0.012)
    puffy("mouth_o_tongue", op_and(op_inset(f, 0.003), sd_circle(0.016, 0, -0.028)), "tongue", r, c=(0, -0.016),
          H=0.005, back=0.003, p=2.5, segs=32, nf=4, nb=1, y0=-0.016)
    tube_obj("mouth_o_rim", outline_pts(s, 0.0), 0.0062, "eye_black", r, closed=True, y0=-0.018, ys=1.5, segs=10)
    roots.append(r)
    # bouche triste
    pts = arc_pts(0, -0.034, 0.054, math.radians(48), math.radians(132), 26)
    roots.append(tube_obj("mouth_frown", shift(pts, 0, -0.0005), taper(LR, LR * 0.75, 0.7), "eye_black", None,
                          y0=LY0, ys=LYS, segs=12))
    # bouche plate
    roots.append(tube_obj("mouth_flat", [(-0.03 + 0.06 * i / 9, 0.0) for i in range(10)], taper(LR, LR * 0.85, 0.5),
                          "eye_black", None, y0=LY0, ys=LYS, segs=12))
    return roots


# ===========================================================================
# CONSTRUCTION + EXPORT
# ===========================================================================
for k in MAT_DEF:
    mat(k)

all_roots = []
for style, d in EYES.items():
    root = begin("eye_" + style)
    d["fn"](root)
    all_roots.append(root)
for style, d in MOUTHS.items():
    root = begin("mouth_" + style)
    d["fn"](root)
    all_roots.append(root)
shared = build_shared()
all_roots += shared


def descendants(o):
    out = [o]
    for c in o.children:
        out += descendants(c)
    return out


def report(root):
    tris = 0
    vs = []
    for o in descendants(root):
        if o.type != "MESH":
            continue
        assert len(o.data.materials) == 1, o.name
        tris += sum(len(p.vertices) - 2 for p in o.data.polygons)
        mw = o.matrix_world
        vs += [mw @ v.co for v in o.data.vertices]
    xs = [v.x for v in vs]
    ys = [v.y for v in vs]
    zs = [v.z for v in vs]
    print("PART %-18s tris=%5d  w=%.3f h=%.3f  y=[%.3f, %.3f]  x=[%.3f,%.3f] z=[%.3f,%.3f]" % (
        root.name, tris, max(xs) - min(xs), max(zs) - min(zs), min(ys), max(ys), min(xs), max(xs), min(zs), max(zs)))


bpy.context.view_layer.update()
for r in all_roots:
    report(r)

bpy.ops.object.select_all(action="DESELECT")
for r in all_roots:
    for o in descendants(r):
        o.select_set(True)
glb = os.path.join(OUT_MODELS, "face.glb")
bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", use_selection=True, export_apply=True,
                          export_yup=True, export_normals=True, export_materials="EXPORT", export_animations=False)
print("EXPORTED", glb)

manifest = {"eyes": {}, "mouths": {}}
for style, d in EYES.items():
    manifest["eyes"][style] = {"name": d["name"], "price": d["price"],
                               "pupil_range": [round(v, 4) for v in d["pupil_range"]],
                               "iris": d["iris"], "scale": d["scale"], "mirror": d["mirror"]}
for style, d in MOUTHS.items():
    manifest["mouths"][style] = {"name": d["name"], "price": d["price"]}
with open(os.path.join(OUT_DATA, "face.json"), "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=1, ensure_ascii=False)
print("MANIFEST OK")

# ===========================================================================
# APERCUS (EEVEE) sur les vrais corps
# ===========================================================================
for c in list(SCENE.collection.children):
    SCENE.collection.children.unlink(c)
PREV = bpy.data.collections.new("preview")
SCENE.collection.children.link(PREV)
CUR_COLL[0] = PREV

bpy.ops.import_scene.gltf(filepath=os.path.join(OUT_MODELS, "bodies.glb"))
BODIES = {}
for o in list(bpy.data.objects):
    if o.name.startswith("body_") and o.type == "MESH":
        BODIES[o.name[5:]] = o
        for c in list(o.users_collection):
            c.objects.unlink(o)
with open(os.path.join(OUT_DATA, "species.json"), encoding="utf-8") as fh:
    SPECIES = json.load(fh)

FUR = 0.05
FUR_COL = {"mochi": "f7a8c0", "pico": "a8e6cf", "coco": "ffc89a", "nuage": "cfe3ff", "kiwi": "c9e48a"}
FUR_MATS = {}
for sid, col in FUR_COL.items():
    m = make_mat("fur_" + sid, col=col, rough=0.85)
    try:
        b = m.node_tree.nodes.get("Principled BSDF")
        b.inputs["Sheen Weight"].default_value = 0.6
        b.inputs["Sheen Tint"].default_value = (1, 1, 1, 1)
    except Exception:
        pass
    FUR_MATS[sid] = m

IRIS_MATS = {}
for style, d in EYES.items():
    if d["iris"]:
        IRIS_MATS[style] = make_mat("iris_prev_" + style, col=d["iris"], rough=0.2, coat=1.0)


def g2b(v):
    return Vector((v[0], -v[2], v[1]))


def place(pos_g, n_g):
    """Repere Godot basis_facing(n) converti en matrice Blender."""
    z = Vector(n_g).normalized()
    x = Vector((0, 1, 0)).cross(z)
    x = Vector((1, 0, 0)) if x.length < 0.01 else x.normalized()
    y = z.cross(x).normalized()
    cx, cy, cz = g2b(x), -g2b(z), g2b(y)
    M = Matrix(((cx.x, cy.x, cz.x, 0), (cx.y, cy.y, cz.y, 0), (cx.z, cy.z, cz.z, 0), (0, 0, 0, 1)))
    return Matrix.Translation(g2b(pos_g)) @ M


def eye_mat(a, side):
    n = (Vector(a["eye_" + side + "_n"]) + Vector((0, 0, 1.3))).normalized()
    p = Vector(a["eye_" + side]) + n * FUR * 0.5
    return place(p, n)


def mouth_mat(a):
    n = (Vector(a["mouth_n"]) + Vector((0, 0, 1.0))).normalized()
    p = Vector(a["mouth"]) + n * FUR * 0.5
    return place(p, n)


def instantiate(root, M, sz=1.0, pupil=None, iris_mat=None, rotz=0.0, sx=1.0):
    def cp(o, parent):
        c = o.copy()
        PREV.objects.link(c)
        c.parent = parent
        if parent is None:
            c.matrix_world = M @ Matrix.Rotation(rotz, 4, "Y") @ Matrix.Diagonal((sx, 1, sz, 1))
        else:
            c.matrix_parent_inverse = o.matrix_parent_inverse.copy()
            c.location = o.location.copy()
            if pupil is not None and o.name.endswith("_pupil"):
                c.location = (pupil[0], 0, pupil[1])
        if c.type == "MESH" and iris_mat is not None and o.data.materials[0].name == "iris":
            c.material_slots[0].link = "OBJECT"
            c.material_slots[0].material = iris_mat
        for ch in o.children:
            cp(ch, c)
        return c
    return cp(root, None)


TILE_OBJS = []


def add_body(sid, off):
    b = BODIES[sid].copy()
    b.data = BODIES[sid].data
    PREV.objects.link(b)
    b.matrix_world = Matrix.Translation(off)
    b.material_slots[0].link = "OBJECT"
    b.material_slots[0].material = FUR_MATS[sid]
    d = b.modifiers.new("fur", "DISPLACE")
    d.strength = FUR * 0.6
    d.mid_level = 0.0
    return b


def label(text, loc, size=0.045):
    cu = bpy.data.curves.new("lbl", "FONT")
    cu.body = text
    cu.size = size
    cu.align_x = "CENTER"
    o = bpy.data.objects.new("lbl", cu)
    PREV.objects.link(o)
    o.location = loc
    o.rotation_euler = (math.pi / 2, 0, 0)
    o.data.materials.append(make_mat("label_mat", col="4a3b48", rough=1.0))
    return o


def build_face(sid, off, eye_style, mouth_style, sz=1.0, gaze=None, eyes_mode="open"):
    a = SPECIES[sid]
    T = Matrix.Translation(off)
    ed = EYES.get(eye_style, {})
    for side in ("l", "r"):
        M = T @ eye_mat(a, side)
        sx = -1.0 if (side == "l" and ed.get("mirror")) else 1.0
        if eyes_mode == "open":
            pr = ed["pupil_range"]
            # oeil miroir (X = -1) : le jeu doit inverser le decalage X de la pupille
            pupil = (gaze[0] * pr[0] * sx, gaze[1] * pr[1]) if gaze else None
            instantiate(STYLE_ROOTS["eye_" + eye_style], M, sz=sz, pupil=pupil,
                        iris_mat=IRIS_MATS.get(eye_style), sx=sx)
        elif eyes_mode == "happy":
            instantiate(bpy.data.objects["eye_arc"], M)
        elif eyes_mode == "sleep":
            instantiate(bpy.data.objects["eye_arc"], M, rotz=math.pi)
        elif eyes_mode == "angry":
            instantiate(STYLE_ROOTS["eye_" + eye_style], M, sz=0.75, iris_mat=IRIS_MATS.get(eye_style), sx=sx)
            s = 1 if side == "l" else -1
            instantiate(bpy.data.objects["brow"], M @ Matrix.Translation((0, 0, 0.1)), rotz=0.45 * s)
    mroot = STYLE_ROOTS.get("mouth_" + mouth_style) or bpy.data.objects[mouth_style]
    instantiate(mroot, T @ mouth_mat(a))


def face_center(sid):
    a = SPECIES[sid]
    e = g2b(a["eye_r"])
    m = g2b(a["mouth"])
    return Vector((0, (e.y + m.y) / 2, (e.z + m.z) / 2 - 0.01))


# --- rendu ---
SCENE.render.engine = "BLENDER_EEVEE"
try:
    SCENE.eevee.taa_render_samples = 24
except Exception:
    pass
SCENE.render.film_transparent = False
try:
    SCENE.view_settings.view_transform = "Standard"
    SCENE.view_settings.look = "None"
except Exception:
    try:
        SCENE.view_settings.look = "None"
    except Exception:
        pass
world = bpy.data.worlds.new("w")
SCENE.world = world
world.use_nodes = True
bg = world.node_tree.nodes.get("Background")
bg.inputs[0].default_value = (*srgb("f4eef2"), 1)
bg.inputs[1].default_value = 0.45


def sun(rot, energy, angle=0.3):
    ld = bpy.data.lights.new("sun", "SUN")
    ld.energy = energy
    ld.angle = angle
    o = bpy.data.objects.new("sun", ld)
    SCENE.collection.objects.link(o)
    o.rotation_euler = rot
    return o


sun((math.radians(50), 0, math.radians(-28)), 2.2, 0.3)
sun((math.radians(70), 0, math.radians(40)), 0.6, 0.8)
sun((math.radians(-60), 0, math.radians(180)), 1.2, 0.5)

cam_d = bpy.data.cameras.new("cam")
cam_d.type = "ORTHO"
cam = bpy.data.objects.new("cam", cam_d)
SCENE.collection.objects.link(cam)
cam.rotation_euler = (math.pi / 2, 0, 0)
SCENE.camera = cam

TILE = 360
TMP = os.path.join(OUT_PREV, "_tile.png")


def clear_prev():
    for o in list(PREV.objects):
        bpy.data.objects.remove(o, do_unlink=True)


def render_tile(cam_pos, ortho, yaw=0.0):
    cam.rotation_euler = (math.pi / 2, 0, yaw)
    cam.location = cam_pos
    cam_d.ortho_scale = ortho
    SCENE.render.resolution_x = TILE
    SCENE.render.resolution_y = TILE
    SCENE.render.filepath = TMP
    bpy.ops.render.render(write_still=True)
    img = bpy.data.images.load(TMP, check_existing=False)
    arr = np.empty(TILE * TILE * 4, dtype=np.float32)
    img.pixels.foreach_get(arr)
    bpy.data.images.remove(img)
    return arr.reshape(TILE, TILE, 4)


def sheet(fname, tiles, cols=5):
    """tiles : liste de (titre, fonction(off) -> (cam_pos, ortho))."""
    rows = (len(tiles) + cols - 1) // cols
    big = np.ones((rows * TILE, cols * TILE, 4), dtype=np.float32)
    for i, (title, fn) in enumerate(tiles):
        clear_prev()
        off = Vector((i * 4.0, 0, 0))
        res = fn(off)
        cpos, ortho = res[0], res[1]
        yaw = res[2] if len(res) > 2 else 0.0
        R = Matrix.Rotation(yaw, 3, "Z")
        lb = label(title, cpos + R @ Vector((0, -1.2, -ortho * 0.44)), size=ortho * 0.075)
        lb.rotation_euler = (math.pi / 2, 0, yaw)
        arr = render_tile(cpos + R @ Vector((0, -6, 0)), ortho, yaw)
        r, c = i // cols, i % cols
        y0 = (rows - 1 - r) * TILE
        big[y0:y0 + TILE, c * TILE:(c + 1) * TILE] = arr
    img = bpy.data.images.new("sheet", cols * TILE, rows * TILE, alpha=True)
    img.pixels.foreach_set(big.ravel())
    img.filepath_raw = os.path.join(OUT_PREV, fname)
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)
    print("PREVIEW", fname)


def face_tile(sid, eye_style, mouth_style, ortho=None, focus=None, yaw=0.0, **kw):
    def fn(off):
        nonlocal ortho
        if ortho is None:
            a_ = SPECIES[sid]
            ex, ez, mz = abs(a_["eye_r"][0]), a_["eye_r"][1], a_["mouth"][1]
            ortho = max(2 * ex + 0.32, ez - mz + 0.42, 0.62)
        add_body(sid, off)
        build_face(sid, off, eye_style, mouth_style, **kw)
        a = SPECIES[sid]
        if focus == "eye":
            return off + g2b(a["eye_r"]), ortho, yaw
        if focus == "mouth":
            return off + g2b(a["mouth"]) + Vector((0, 0, 0.01)), ortho, yaw
        return off + face_center(sid), ortho, yaw
    return fn


def body_tile(sid, eye_style, mouth_style, **kw):
    def fn(off):
        add_body(sid, off)
        build_face(sid, off, eye_style, mouth_style, **kw)
        h = SPECIES[sid]["height"]
        return off + Vector((0, 0, h * 0.5)), h * 1.35
    return fn


eye_ids = list(EYES)
mouth_ids = list(MOUTHS)
sheet("face_eyes_mochi.png", [(e, face_tile("mochi", e, "smile")) for e in eye_ids])
sheet("face_mouths_mochi.png", [(m, face_tile("mochi", "dot", m)) for m in mouth_ids])
sheet("face_threequarter.png", [(e, face_tile("mochi", e, mouth_ids[i % len(mouth_ids)], ortho=0.7,
                                                 yaw=math.radians(-40)))
                                 for i, e in enumerate(eye_ids + ["dot", "dot"])])
sheet("face_eyes_closeup.png", [(e, face_tile("mochi", e, "smile", ortho=0.26, focus="eye")) for e in eye_ids])
sheet("face_mouths_closeup.png", [(m, face_tile("mochi", "dot", m, ortho=0.24, focus="mouth"))
                                  for m in mouth_ids + ["mouth_o", "mouth_frown", "mouth_flat"]])
if not QUICK:
    sheet("face_eyes_squash.png", [(e + " 45%", face_tile("mochi", e, "smile", sz=0.45)) for e in eye_ids])
    sheet("face_eyes_gaze.png", [(e + " look", face_tile("mochi", e, "smile", gaze=(1, 1))) for e in eye_ids])
    sheet("face_expressions.png", [
        ("happy", face_tile("mochi", "dot", "open", eyes_mode="happy")),
        ("sleep", face_tile("mochi", "dot", "mouth_flat", eyes_mode="sleep")),
        ("surprised", face_tile("mochi", "googly", "mouth_o")),
        ("sad", face_tile("mochi", "shiny", "mouth_frown")),
        ("angry", face_tile("mochi", "dot", "mouth_flat", eyes_mode="angry")),
    ], cols=5)
    for sid in ("pico", "coco", "kiwi", "nuage"):
        sheet("face_eyes_%s.png" % sid, [(e, face_tile(sid, e, mouth_ids[i % len(mouth_ids)]))
                                          for i, e in enumerate(eye_ids)])
        sheet("face_mouths_%s.png" % sid, [(m, face_tile(sid, eye_ids[i % len(eye_ids)], m))
                                            for i, m in enumerate(mouth_ids)])
    combos = [("mochi", "shiny", "cat"), ("pico", "googly", "open"), ("coco", "heart", "kiss"),
              ("nuage", "sleepy", "tiny"), ("kiwi", "star", "beak")]
    sheet("face_bodies.png", [("%s %s/%s" % c, body_tile(*c)) for c in combos], cols=5)
if os.path.exists(TMP):
    os.remove(TMP)
print("DONE")
