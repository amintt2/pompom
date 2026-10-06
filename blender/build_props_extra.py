"""
Pompom - objets "situations" (ce que le compagnon tient ou pose a cote de lui quand il imite l'utilisateur).

Lancement (headless, CPU) :
    blender --background --factory-startup --python blender/build_props_extra.py [-- --preview]

Sortie :
    godot/assets/models/props_extra.glb   un Empty racine par objet (nom = id), a l'origine
    blender/previews/props_extra.png      planche Workbench (seulement avec --preview)

Conventions (identiques a build_models.py / build_accessories.py) :
  - Blender Z = haut, -Y = avant (vers la camera) ; Godot : (x, z, -y).
  - Unites : le compagnon mesure ~1.0 de haut ; un objet tenu fait ~0.15 - 0.35.
  - Objets "tenus" (envelope, book, calculator...) : origine au centre, face avant vers -Y.
  - Objets "poses" (keyboard, mug_coffee, coins...) : origine au centre du dessous (z = 0).
  - Un seul materiau par mesh. Noms de materiaux interpretes par Godot (pet_situations.gd) :
      fixes PetAssets : gold, silver, metal, white, black, glass, clear_glass, glow, wood, leather, rubber, screen, glint
      propres a ce fichier : paper, news, ink, gray, red, pink, yellow, orange, green, mint, sky, blue, navy,
      purple, lilac, kraft, sand, coffee, cream, steam
  - Sous-noeuds animes par Godot (empties nommes) : book_page, notepad_check_1..3, clapper_arm,
    mug_coffee_steam, lightbulb_rays, thought_1, thought_2, thought_cloud, coins_top, camera_flash,
    sun_rays, pennant_flag, chess_pawn_w, chess_pawn_b.
"""
import bpy
import bmesh
import math
import os
import random
import sys

from mathutils import Matrix, Vector

V = Vector
TAU = 2.0 * math.pi
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_GLB = os.path.join(ROOT, "godot", "assets", "models", "props_extra.glb")
PREVIEW = os.path.join(ROOT, "blender", "previews", "props_extra.png")
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
DO_PREVIEW = "--preview" in ARGS

bpy.ops.wm.read_factory_settings(use_empty=True)
SCENE = bpy.context.scene

# ---------------------------------------------------------------------------
# Materiaux (couleurs de previsualisation ; Godot remplace d'apres le nom)
# ---------------------------------------------------------------------------
MAT_DEF = {
    "gold": "f2b84b", "silver": "c9ced6", "metal": "dfe3ea", "white": "f7f4ee", "black": "2a272e",
    "glass": "26232f", "clear_glass": "dff3ff", "glow": "ffd96a", "wood": "b07a4a", "leather": "7a4a2e",
    "rubber": "3a3640", "screen": "9fd8ff", "glint": "ffffff",
    "paper": "fffaf0", "news": "ece8de", "ink": "3a3550", "gray": "a9a7b4", "red": "ff5a6e", "pink": "ff8fbf",
    "yellow": "ffd45c", "orange": "ff9f45", "green": "6fd08c", "mint": "9ff0d0", "sky": "7cc8ff",
    "blue": "4f8dff", "navy": "3d4f8f", "purple": "a77bff", "lilac": "cdb8ff", "kraft": "d9b68a",
    "sand": "f2cf7a", "coffee": "6b3f22", "cream": "fff1dc", "steam": "ffffff",
}


def hex_rgb(h):
    c = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    return tuple(x ** 2.2 for x in c)


def mat(name):
    assert name in MAT_DEF, name
    m = bpy.data.materials.get(name)
    if m is None:
        m = bpy.data.materials.new(name)
        c = hex_rgb(MAT_DEF[name])
        m.diffuse_color = (*c, 1.0)
        try:
            m.use_nodes = True
            b = m.node_tree.nodes.get("Principled BSDF")
            if b is not None:
                b.inputs["Base Color"].default_value = (*c, 1.0)
                b.inputs["Roughness"].default_value = 0.5
        except Exception:
            pass
    return m


# ---------------------------------------------------------------------------
# Matrices / courbes (memes outils que build_accessories.py)
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


# forme 2D (plan XY local, epaisseur Z local) tournee vers l'avant (-Y)
FRONT = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))


def FF(x=0.0, y=0.0, z=0.0, turn=0.0, tilt=0.0, roll=0.0):
    """Repere 'face avant' en (x, y, z) ; turn : rotation autour de Z (deg), tilt : bascule vers l'arriere (deg),
    roll : rotation dans le plan (deg)."""
    return T(x, y, z) @ R("Z", turn) @ R("X", -tilt) @ FRONT @ R("Z", roll)


def fillet(pts, r, n=4, closed=True):
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


def circle2(r, n=32, cx=0.0, cy=0.0, a0=0.0):
    return [V((cx + math.cos(a0 + TAU * k / n) * r, cy + math.sin(a0 + TAU * k / n) * r)) for k in range(n)]


def ellipse2(rx, ry, n=32, cx=0.0, cy=0.0):
    return [V((cx + math.cos(TAU * k / n) * rx, cy + math.sin(TAU * k / n) * ry)) for k in range(n)]


def rrect2(w, h, r, n=4, cx=0.0, cy=0.0):
    pts = [(cx - w / 2, cy - h / 2), (cx + w / 2, cy - h / 2), (cx + w / 2, cy + h / 2), (cx - w / 2, cy + h / 2)]
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
# Generateurs bmesh
# ---------------------------------------------------------------------------
def g_rows(bm, M, rows, closed_v=True, closed_u=False, cap0=False, cap1=False):
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


def g_lathe(bm, M, prof, segs=40, mod=None, cap0=False, cap1=False):
    """Revolution d'un profil [(r, z)] autour de Z. mod(a, s, r, z) -> (r, z)."""
    prof = [V(p) for p in prof]
    n = len(prof)
    rows = []
    for i, p in enumerate(prof):
        s = i / max(n - 1, 1)
        row = []
        for k in range(segs):
            a = TAU * k / segs
            r, z = p.x, p.y
            if mod is not None and r > 1e-7:
                r, z = mod(a, s, r, z)
            row.append(V((math.cos(a) * r, math.sin(a) * r, z)))
        rows.append(row)
    return g_rows(bm, M, rows, closed_v=True, cap0=cap0, cap1=cap1)


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


def g_tube(bm, M, pts, r, segs=12, cap=("round", "round"), closed=False, hint=None, aspect=1.0, p=2.0, cap_rings=3):
    P = [V(q) for q in pts]
    n = len(P)
    if isinstance(cap, str) or cap is None:
        cap = (cap, cap)
    fr = tube_frames(P, closed, hint)

    def ring(i, scale=1.0, offset=0.0):
        t = i / max(n - 1, 1)
        t_, n1, n2 = fr[i]
        rr = r(t) if callable(r) else r
        out = []
        for k in range(segs):
            phi = TAU * k / segs
            cx, cy = superellipse(phi, p)
            out.append(P[i] + t_ * offset + (n1 * cx * aspect + n2 * cy) * rr * scale)
        return out

    rows = [ring(i) for i in range(n)]
    pre, post = [], []
    if not closed:
        for which, idx, sign in ((0, 0, -1), (1, n - 1, 1)):
            if cap[which] == "round":
                t = idx / max(n - 1, 1)
                rr = r(t) if callable(r) else r
                extra = []
                for k in range(1, cap_rings + 1):
                    a = (math.pi / 2) * k / cap_rings
                    if k == cap_rings:
                        extra.append([P[idx] + fr[idx][0] * sign * rr] * segs)
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


def g_torus(bm, M, R_, r_, segs=48, rsegs=12, a0=None, a1=None):
    if a0 is None:
        pts = [V((math.cos(TAU * k / segs) * R_, math.sin(TAU * k / segs) * R_, 0)) for k in range(segs)]
        g_tube(bm, M, pts, r_, segs=rsegs, closed=True, hint=lambda t, q: V((q.x, q.y, 0)))
    else:
        pts = [V((math.cos(a0 + (a1 - a0) * k / segs) * R_, math.sin(a0 + (a1 - a0) * k / segs) * R_, 0))
               for k in range(segs + 1)]
        g_tube(bm, M, pts, r_, segs=rsegs, hint=lambda t, q: V((q.x, q.y, 0)))


def g_cookie(bm, M, outline, depth, bevel=0.0, seg=3, puff=0.0):
    """Prisme a partir d'un contour 2D (plan XY local), epaisseur selon Z local, bords arrondis, face +Z bombee."""
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
    if puff > 0 and False:  # (l'inset bombe cassait les contours concaves : desactive)
        topf = [fc for fc in tmp.faces if fc.normal.z > 0.99]
        if topf:
            fc = max(topf, key=lambda q: q.calc_area())
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
    bm.from_mesh(me)
    bpy.data.meshes.remove(me)


def g_box(bm, M, w, d, h, r=0.004, seg=2):
    """Boite arrondie centree (largeur X, profondeur Y, hauteur Z)."""
    g_cookie(bm, M, rrect2(w, d, min(r * 1.5, w * 0.3, d * 0.3)), h, bevel=min(r, h * 0.45), seg=seg)


# ---------------------------------------------------------------------------
# Objets
# ---------------------------------------------------------------------------
CUR = {"id": ""}
ROOTS = []


def link(o):
    SCENE.collection.objects.link(o)
    return o


def world(o):
    if o is None:
        return Matrix.Identity(4)
    return world(o.parent) @ o.matrix_basis


def empty(name, parent=None, loc=(0, 0, 0), rot=None):
    e = link(bpy.data.objects.new(name, None))
    e.empty_display_size = 0.03
    W = T(loc) @ (rot if rot is not None else I4)
    if parent is not None:
        e.parent = parent
        e.matrix_basis = world(parent).inverted() @ W
    else:
        e.matrix_basis = W
    return e


def mk(bm, material, parent, name="part", smooth=True, subsurf=0, bevel=0.0, bevel_seg=3, solid=0.0):
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    nm = "%s_%s" % (CUR["id"], name)
    me = bpy.data.meshes.new(nm)
    bm.to_mesh(me)
    bm.free()
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
    if bevel > 0:
        b = o.modifiers.new("Bevel", "BEVEL")
        b.width = bevel
        b.segments = bevel_seg
        b.limit_method = "ANGLE"
        b.angle_limit = math.radians(35)
    if subsurf > 0:
        s = o.modifiers.new("Sub", "SUBSURF")
        s.levels = subsurf
        s.render_levels = subsurf
    me.materials.append(mat(material))
    return o


def part(material, parent, name, gen, *a, **kw):
    mk_kw = {k: kw.pop(k) for k in list(kw.keys()) if k in ("smooth", "subsurf", "bevel", "bevel_seg", "solid")}
    bm = bmesh.new()
    gen(bm, *a, **kw)
    return mk(bm, material, parent, name, **mk_kw)


def prop(id_):
    def deco(fn):
        CUR["id"] = id_
        root = empty(id_)
        fn(root)
        ROOTS.append(root)
        print("prop", id_)
        return fn
    return deco


def lines_on(root, name, M, x0, x1, zs, w=0.0055, depth=0.0025, material="gray", jitter=0.0, seed=1):
    """Lignes de texte (barres arrondies) dans le plan d'un repere M (local XY, +Z = avant)."""
    rnd = random.Random(seed)
    for i, z in enumerate(zs):
        xe = x1 - (rnd.uniform(0, jitter) if jitter else 0.0)
        part(material, root, "%s%d" % (name, i), g_cookie, M @ T((x0 + xe) / 2, z, 0), rrect2(xe - x0, w, w * 0.49), depth)


# =========================================================================== courrier
@prop("envelope")
def _envelope(root):
    # enveloppe fermee (dos) : rabat en V et cachet coeur
    part("paper", root, "body", g_cookie, FF(0, 0, 0), rrect2(0.27, 0.175, 0.02), 0.016, bevel=0.004, puff=0.003)
    flap = fillet([(-0.128, 0.083), (0.128, 0.083), (0.0, -0.012)], [0.012, 0.012, 0.02], 4)
    part("cream", root, "flap", g_cookie, FF(0, -0.0095, 0), flap, 0.004, bevel=0.0015)
    for sx in (-1, 1):
        part("cream", root, "fold%d" % (sx + 1), g_tube, I4,
             [V((sx * 0.128, -0.0092, -0.082)), V((sx * 0.03, -0.0092, -0.01))], 0.0028, segs=6)
    part("red", root, "seal", g_cookie, FF(0, -0.0135, -0.018), heart2(0.036), 0.007, bevel=0.002, puff=0.002)


@prop("letter")
def _letter(root):
    # enveloppe ouverte, la lettre depasse (lecture)
    part("sky", root, "back", g_cookie, FF(0, 0.004, 0), rrect2(0.27, 0.175, 0.02), 0.008, bevel=0.002)
    flap = fillet([(-0.131, 0.0), (0.131, 0.0), (0.0, 0.085)], [0.01, 0.01, 0.025], 4)
    part("sky", root, "flap", g_cookie, FF(0, 0.007, 0.087), flap, 0.004, bevel=0.0015)
    Ms = FF(0, -0.0005, 0.06, roll=-3)
    part("paper", root, "sheet", g_cookie, Ms, rrect2(0.225, 0.2, 0.01), 0.004, bevel=0.001)
    lines_on(root, "line", Ms @ T(0, 0, 0.0035), -0.085, 0.085, [0.075, 0.05, 0.025], material="gray", jitter=0.06,
             seed=3)
    part("pink", root, "heart", g_cookie, Ms @ T(0.07, 0.072, 0.0035), heart2(0.022), 0.003, bevel=0.001)
    pocket = [(-0.135, -0.0875), (0.135, -0.0875), (0.135, 0.03), (0.0, -0.035), (-0.135, 0.03)]
    part("sky", root, "pocket", g_cookie, FF(0, -0.008, 0), fillet(pocket, [0.02, 0.02, 0.01, 0.02, 0.01], 4), 0.008,
         bevel=0.003)
    for sx in (-1, 1):
        part("blue", root, "fold%d" % (sx + 1), g_tube, I4,
             [V((sx * 0.13, -0.0125, 0.026)), V((sx * 0.015, -0.0125, -0.028))], 0.0024, segs=6)
    part("red", root, "seal", g_cookie, FF(0, -0.0135, -0.045), heart2(0.03), 0.006, bevel=0.002, puff=0.002)


# =========================================================================== lecture / ecriture
@prop("book")
def _book(root):
    # livre ouvert, pages vers l'avant ; book_page pivote autour du dos (axe Z) pour tourner une page
    for side, a in ((-1, 16.0), (1, -16.0)):
        Mh = T(0, 0, 0) @ R("Z", a)
        part("red", root, "cover%d" % (side + 1), g_cookie, Mh @ FF(side * 0.088, 0.016, 0),
             rrect2(0.178, 0.25, 0.018), 0.012, bevel=0.003)
        part("paper", root, "pages%d" % (side + 1), g_cookie, Mh @ FF(side * 0.083, 0.0, 0.0),
             rrect2(0.16, 0.232, 0.01), 0.022, bevel=0.004, puff=0.004)
        Mp = Mh @ FF(side * 0.085, -0.0125, 0.0)
        lines_on(root, "txt%d_" % (side + 1), Mp, -0.06, 0.06, [0.08, 0.06, 0.04, 0.02, 0.0, -0.02, -0.04, -0.06],
                 w=0.0075, material="lilac", jitter=0.05, seed=5 + side)
    part("red", root, "spine", g_tube, I4, [V((0, 0.02, -0.125)), V((0, 0.02, 0.125))], 0.014, segs=12)
    part("pink", root, "ribbon", g_tube, I4, [V((0.004, -0.012, 0.11)), V((0.006, -0.016, -0.02)),
                                               V((0.01, -0.02, -0.145))], 0.005, segs=6, aspect=1.8)
    pg = empty("book_page", root, loc=(0, -0.016, 0), rot=R("Z", -16.0))
    part("paper", pg, "page", g_cookie, R("Z", -16.0) @ FF(0.08, -0.016, 0), rrect2(0.152, 0.226, 0.01), 0.003,
         bevel=0.001)
    lines_on(pg, "ptxt", R("Z", -16.0) @ FF(0.08, -0.018, 0), -0.055, 0.055, [0.07, 0.05, 0.03, 0.01, -0.01],
             w=0.0075, depth=0.0018, material="lilac", jitter=0.04, seed=9)


@prop("pencil")
def _pencil(root):
    # origine = la mine ; le crayon monte selon +Z
    part("ink", root, "tip", g_cyl, T(0, 0, 0.011), 0.002, 0.0055, 0.018, segs=12)
    part("kraft", root, "wood", g_cyl, T(0, 0, 0.034), 0.0055, 0.0145, 0.03, segs=12)
    part("yellow", root, "body", g_tube, I4, [V((0, 0, 0.049)), V((0, 0, 0.2))], 0.0145, segs=6,
         cap=("flat", "flat"), bevel=0.0018, bevel_seg=2, smooth=False)
    for k, z in enumerate((0.201, 0.21, 0.219)):
        part("silver", root, "band%d" % k, g_torus, T(0, 0, z), 0.0148, 0.0026, segs=24, rsegs=6)
    part("silver", root, "ferrule", g_cyl, T(0, 0, 0.21), 0.0148, 0.0148, 0.022, segs=24)
    part("pink", root, "eraser", g_tube, I4, [V((0, 0, 0.222)), V((0, 0, 0.238))], 0.0142, segs=16,
         cap=("flat", "round"))


@prop("notepad")
def _notepad(root):
    part("wood", root, "board", g_cookie, FF(0, 0, 0), rrect2(0.22, 0.29, 0.022), 0.014, bevel=0.004)
    Mp = FF(0, -0.008, -0.012)
    part("paper", root, "sheet", g_cookie, Mp, rrect2(0.19, 0.235, 0.008), 0.003, bevel=0.001)
    part("silver", root, "clip", g_cookie, FF(0, -0.012, 0.128), rrect2(0.09, 0.04, 0.012), 0.012, bevel=0.004)
    part("silver", root, "ring", g_torus, FF(0, -0.012, 0.15), 0.012, 0.0035, segs=24, rsegs=6)
    for i, z in enumerate((0.07, 0.015, -0.04, -0.095)):
        part("lilac", root, "box%d" % i, g_cookie, Mp @ T(-0.06, z, 0.003), rrect2(0.026, 0.026, 0.007), 0.0035,
             bevel=0.001)
        part("gray", root, "row%d" % i, g_cookie, Mp @ T(0.022, z, 0.003),
             rrect2(0.1 - (0.02 if i % 2 else 0.0), 0.009, 0.0044), 0.0025)
        if i < 3:
            ch = empty("notepad_check_%d" % (i + 1), root, loc=Mp @ V((-0.06, z, 0.006)))
            pts = [Mp @ V((-0.072, z + 0.002, 0.007)), Mp @ V((-0.062, z - 0.01, 0.007)), Mp @ V((-0.044, z + 0.016, 0.007))]
            part("green", ch, "check", g_tube, I4, pts, 0.0045, segs=8)


@prop("newspaper")
def _newspaper(root):
    for side, a in ((-1, 12.0), (1, -12.0)):
        Mh = R("Z", a)
        Mp = Mh @ FF(side * 0.078, 0.0, 0.0)
        part("news", root, "page%d" % (side + 1), g_cookie, Mp, rrect2(0.155, 0.215, 0.006), 0.005, bevel=0.0015)
        Mf = Mp @ T(0, 0, 0.003)
        if side < 0:
            part("ink", root, "head0", g_cookie, Mf @ T(0, 0.08, 0), rrect2(0.12, 0.022, 0.006), 0.002)
            part("ink", root, "head1", g_cookie, Mf @ T(-0.012, 0.052, 0), rrect2(0.095, 0.012, 0.004), 0.002)
            lines_on(root, "colA", Mf, -0.062, -0.006, [0.025, 0.01, -0.005, -0.02, -0.035, -0.05, -0.065, -0.08],
                     w=0.005, depth=0.002, material="gray", jitter=0.01, seed=11)
            lines_on(root, "colB", Mf, 0.006, 0.062, [0.025, 0.01, -0.005, -0.02, -0.035, -0.05, -0.065, -0.08],
                     w=0.005, depth=0.002, material="gray", jitter=0.01, seed=12)
        else:
            part("sky", root, "photo", g_cookie, Mf @ T(0, 0.05, 0), rrect2(0.12, 0.08, 0.008), 0.002)
            part("yellow", root, "sun", g_cookie, Mf @ T(0.03, 0.065, 0.0012), circle2(0.012, 20), 0.002)
            part("green", root, "hill", g_cookie, Mf @ T(-0.02, 0.022, 0.0012), ellipse2(0.05, 0.018, 24), 0.002)
            lines_on(root, "colC", Mf, -0.06, 0.06, [-0.01, -0.025, -0.04, -0.055, -0.07, -0.085],
                     w=0.005, depth=0.002, material="gray", jitter=0.03, seed=13)


@prop("map")
def _map(root):
    # carte depliee en accordeon (3 volets) + itineraire en pointilles + epingle
    folds = [V((-0.165, 0.0)), V((-0.055, -0.032)), V((0.055, 0.0)), V((0.165, -0.032))]
    rnd = random.Random(4)
    for i in range(3):
        a, b = folds[i], folds[i + 1]
        c = (a + b) * 0.5
        ang = math.degrees(math.atan2(b.y - a.y, b.x - a.x))
        L = (b - a).length
        Mp = T(c.x, c.y, 0) @ R("Z", ang) @ FRONT
        part("cream", root, "panel%d" % i, g_cookie, Mp, rrect2(L + 0.002, 0.23, 0.006), 0.004, bevel=0.001)
        Mf = Mp @ T(0, 0, 0.0025)
        part("green", root, "land%d" % i, g_cookie, Mf @ T(rnd.uniform(-0.02, 0.02), rnd.uniform(0.02, 0.06), 0),
             ellipse2(0.04, 0.03, 20), 0.0015)
        part("green", root, "landb%d" % i, g_cookie, Mf @ T(rnd.uniform(-0.02, 0.02), -0.07, 0),
             ellipse2(0.035, 0.022, 20), 0.0015)
        part("sky", root, "river%d" % i, g_cookie, Mf @ T(0, -0.02 + 0.01 * i, 0.0002), rrect2(L, 0.014, 0.007), 0.0015)
        for k in range(3):
            part("red", root, "dot%d_%d" % (i, k), g_cookie,
                 Mf @ T(-0.035 + 0.035 * k, 0.0 + 0.03 * math.sin(i * 1.7 + k), 0.0006), circle2(0.0055, 12), 0.002)
    # epingle sur le dernier volet
    a, b = folds[2], folds[3]
    c = (a + b) * 0.5
    pin = V((c.x + 0.01, c.y - 0.035, 0.06))
    part("red", root, "pin_head", g_sphere, T(pin), 0.02, u=20, v=10)
    part("red", root, "pin_tip", g_cyl, T(pin.x, pin.y + 0.008, pin.z - 0.026), 0.0015, 0.014, 0.03, segs=16)
    part("white", root, "pin_dot", g_sphere, T(pin.x, pin.y - 0.017, pin.z + 0.004), 0.0065, u=12, v=6)


# =========================================================================== bureau
@prop("keyboard")
def _keyboard(root):
    part("cream", root, "base", g_box, T(0, 0, 0.012), 0.36, 0.13, 0.024, r=0.008)
    rows = [-0.04, -0.013, 0.014, 0.041]
    rnd = random.Random(2)
    for ri, y in enumerate(rows):
        if ri == 0:
            part("white", root, "k0a", g_box, T(-0.12, y, 0.029), 0.05, 0.022, 0.012, r=0.004)
            part("mint", root, "space", g_box, T(0.0, y, 0.029), 0.16, 0.022, 0.012, r=0.004)
            part("white", root, "k0b", g_box, T(0.12, y, 0.029), 0.05, 0.022, 0.012, r=0.004)
            continue
        n = 11
        for k in range(n):
            x = -0.148 + k * 0.0296
            m = "white"
            if ri == 3 and k == 0:
                m = "sky"
            if ri == 2 and k == n - 1:
                m = "pink"
            if ri == 1 and k in (4,):
                m = "yellow"
            part(m, root, "k%d_%d" % (ri, k), g_box, T(x, y, 0.029), 0.024, 0.022, 0.012, r=0.004, bevel=0.0)


@prop("calculator")
def _calculator(root):
    part("orange", root, "body", g_cookie, FF(0, 0, 0), rrect2(0.15, 0.22, 0.026), 0.028, bevel=0.007, puff=0.002)
    part("ink", root, "bezel", g_cookie, FF(0, -0.0145, 0.068), rrect2(0.124, 0.05, 0.01), 0.003)
    part("screen", root, "lcd", g_cookie, FF(0, -0.0165, 0.068), rrect2(0.112, 0.038, 0.007), 0.002)
    for k in range(3):
        part("ink", root, "dig%d" % k, g_cookie, FF(0.028 - k * 0.022, -0.0178, 0.068),
             rrect2(0.012, 0.022, 0.003), 0.001)
    for r_ in range(4):
        for c in range(4):
            m = "cream"
            if c == 3:
                m = "pink"
            if c == 3 and r_ == 3:
                m = "yellow"
            part(m, root, "b%d%d" % (r_, c), g_cookie, FF(-0.0495 + c * 0.033, -0.016, 0.02 - r_ * 0.03),
                 rrect2(0.025, 0.022, 0.008), 0.006, bevel=0.002)


@prop("easel")
def _easel(root):
    for sx in (-1, 1):
        part("wood", root, "leg%d" % (sx + 1), g_tube, I4, [V((sx * 0.11, -0.045, 0.0)), V((sx * 0.025, 0.0, 0.34))],
             0.008, segs=8)
    part("wood", root, "legb", g_tube, I4, [V((0, 0.12, 0.0)), V((0, 0.012, 0.31))], 0.0075, segs=8)
    Mb = T(0, -0.03, 0.215) @ R("X", -10) @ FRONT
    part("white", root, "board", g_cookie, Mb, rrect2(0.27, 0.19, 0.014), 0.012, bevel=0.003)
    part("wood", root, "ledge", g_box, T(0, -0.05, 0.115), 0.25, 0.03, 0.012, r=0.004)
    Mf = Mb @ T(0, 0, 0.0065)
    for k, (h, m) in enumerate(((0.05, "sky"), (0.085, "mint"), (0.125, "pink"))):
        part(m, root, "bar%d" % k, g_cookie, Mf @ T(-0.07 + k * 0.05, -0.075 + h / 2, 0), rrect2(0.034, h, 0.008),
             0.004, bevel=0.0015)
    pts = [Mf @ V((-0.095, -0.025, 0.006)), Mf @ V((-0.04, 0.0, 0.006)), Mf @ V((-0.005, -0.012, 0.006)),
           Mf @ V((0.07, 0.055, 0.006))]
    part("red", root, "arrow", g_tube, I4, pts, 0.0055, segs=8)
    d = (pts[-1] - pts[-2]).normalized()
    tipM = Matrix.Translation(pts[-1] + d * 0.01) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4()
    part("red", root, "arrow_tip", g_cyl, tipM, 0.016, 0.0, 0.03, segs=16)


@prop("calendar")
def _calendar(root):
    Mfb = T(0, -0.03, 0.1) @ R("X", -14) @ FRONT
    part("kraft", root, "front", g_cookie, Mfb, rrect2(0.2, 0.205, 0.012), 0.008, bevel=0.002)
    part("kraft", root, "back", g_cookie, T(0, 0.03, 0.1) @ R("X", 14) @ FRONT, rrect2(0.2, 0.205, 0.012), 0.008)
    Mp = Mfb @ T(0, -0.008, 0.0055)
    part("paper", root, "page", g_cookie, Mp, rrect2(0.186, 0.18, 0.01), 0.003)
    part("red", root, "header", g_cookie, Mp @ T(0, 0.065, 0.0018), rrect2(0.186, 0.05, 0.01), 0.003)
    for sx in (-1, 1):
        part("silver", root, "ring%d" % (sx + 1), g_torus, Mfb @ T(sx * 0.055, 0.1, 0.0) @ R("Y", 90), 0.012, 0.0032,
             segs=24, rsegs=6)
    for r_ in range(4):
        for c in range(5):
            x = -0.07 + c * 0.035
            y = 0.012 - r_ * 0.03
            part("gray", root, "d%d%d" % (r_, c), g_cookie, Mp @ T(x, y, 0.0018), rrect2(0.016, 0.012, 0.004), 0.002)
    part("red", root, "circle", g_torus, Mp @ T(0.035, -0.048, 0.003), 0.015, 0.0025, segs=32, rsegs=6)


@prop("folder")
def _folder(root):
    part("kraft", root, "back", g_cookie, FF(0, 0.006, 0.005), rrect2(0.25, 0.18, 0.012), 0.005, bevel=0.0015)
    part("kraft", root, "tab", g_cookie, FF(-0.07, 0.006, 0.098), rrect2(0.08, 0.035, 0.01), 0.005, bevel=0.0015)
    part("paper", root, "sheet1", g_cookie, FF(0.01, 0.0, 0.03, roll=4), rrect2(0.21, 0.17, 0.006), 0.003)
    part("white", root, "sheet2", g_cookie, FF(-0.01, -0.002, 0.04, roll=-5), rrect2(0.2, 0.16, 0.006), 0.003)
    lines_on(root, "txt", FF(-0.01, -0.0038, 0.04, roll=-5), -0.07, 0.06, [0.065, 0.05], w=0.006, material="gray")
    part("sand", root, "front", g_cookie, FF(0, -0.008, -0.018), rrect2(0.25, 0.145, 0.012), 0.006, bevel=0.002,
         puff=0.002)
    part("white", root, "label", g_cookie, FF(0.0, -0.0118, -0.02), rrect2(0.08, 0.03, 0.006), 0.002)


@prop("stamp")
def _stamp(root):
    part("red", root, "base", g_box, T(0, 0, 0.022), 0.075, 0.055, 0.028, r=0.008)
    part("rubber", root, "pad", g_box, T(0, 0, 0.004), 0.07, 0.05, 0.008, r=0.003)
    part("wood", root, "neck", g_cyl, T(0, 0, 0.06), 0.012, 0.016, 0.05, segs=20)
    part("wood", root, "knob", g_sphere, T(0, 0, 0.1) @ S(1, 1, 0.85), 0.03, u=24, v=12)


@prop("hourglass")
def _hourglass(root):
    for z in (-0.088, 0.088):
        part("wood", root, "cap%d" % (z > 0), g_cyl, T(0, 0, z), 0.054, 0.054, 0.016, segs=32, bevel=0.004)
    for k in range(3):
        a = TAU * k / 3 + 0.5
        part("wood", root, "post%d" % k, g_tube, I4, [V((math.cos(a) * 0.044, math.sin(a) * 0.044, -0.08)),
                                                       V((math.cos(a) * 0.044, math.sin(a) * 0.044, 0.08))], 0.0055,
             segs=8, cap=("flat", "flat"))
    prof = [(0.0, -0.081), (0.026, -0.08), (0.037, -0.06), (0.036, -0.035), (0.016, -0.012), (0.006, 0.0),
            (0.016, 0.012), (0.036, 0.035), (0.037, 0.06), (0.026, 0.08), (0.0, 0.081)]
    part("clear_glass", root, "glass", g_lathe, I4, prof, segs=32)
    part("sand", root, "sand_top", g_lathe, I4, [(0.0, 0.012), (0.012, 0.022), (0.028, 0.045), (0.0, 0.048)], segs=24)
    part("sand", root, "sand_bot", g_lathe, I4, [(0.0, -0.079), (0.03, -0.078), (0.026, -0.064), (0.0, -0.052)],
         segs=24)
    part("sand", root, "stream", g_cyl, T(0, 0, -0.03), 0.0018, 0.0018, 0.05, segs=8)


@prop("wrench")
def _wrench(root):
    part("metal", root, "handle", g_cookie, FF(0, 0, -0.04), rrect2(0.032, 0.17, 0.015), 0.014, bevel=0.004)
    pts = []
    c = V((0, 0.06))
    for k in range(29):
        a = math.radians(120 + 300 * k / 28)
        pts.append(V((c.x + math.cos(a) * 0.042, c.y + math.sin(a) * 0.042)))
    pts += [V((0.014, 0.07)), V((-0.014, 0.07))]
    part("metal", root, "head", g_cookie, FF(0, 0, 0), pts, 0.014, bevel=0.004)
    part("pink", root, "grip", g_cookie, FF(0, 0, -0.085), rrect2(0.04, 0.08, 0.018), 0.02, bevel=0.007)


# =========================================================================== creation
@prop("paintbrush")
def _paintbrush(root):
    # origine au milieu du manche, poils vers +Z
    part("wood", root, "handle", g_tube, I4, [V((0, 0, -0.12)), V((0, 0, -0.02)), V((0, 0, 0.045))],
         lambda t: 0.008 + 0.005 * math.sin(t * math.pi * 0.8), segs=14)
    part("silver", root, "ferrule", g_cyl, T(0, 0, 0.062), 0.0105, 0.0125, 0.036, segs=20)
    part("sand", root, "bristles", g_lathe, I4, [(0.0, 0.078), (0.013, 0.08), (0.016, 0.098), (0.012, 0.115),
                                                   (0.0, 0.12)], segs=20)
    part("pink", root, "paint", g_lathe, I4, [(0.0, 0.105), (0.0125, 0.108), (0.011, 0.124), (0.004, 0.136),
                                               (0.0, 0.138)], segs=20)


@prop("palette")
def _palette(root):
    ctrl = [(-0.15, 0.0), (-0.12, 0.08), (0.0, 0.1), (0.12, 0.075), (0.15, 0.0), (0.11, -0.07), (0.03, -0.09),
            (-0.01, -0.055), (-0.06, -0.075), (-0.13, -0.06)]
    outline = spline(ctrl, n=6, closed=True)
    part("wood", root, "board", g_cookie, FF(0, 0, 0), outline, 0.014, bevel=0.004, puff=0.002)
    part("kraft", root, "hole", g_cookie, FF(-0.085, -0.0075, -0.02), ellipse2(0.022, 0.018, 24), 0.002)
    blobs = [(-0.06, 0.055, "red"), (0.0, 0.07, "yellow"), (0.06, 0.055, "sky"), (0.105, 0.015, "green"),
             (0.09, -0.04, "purple"), (0.03, -0.05, "white")]
    for i, (x, z, m) in enumerate(blobs):
        part(m, root, "blob%d" % i, g_sphere, T(x, -0.009, z) @ S(1, 0.45, 0.85), 0.02, u=16, v=8)


@prop("cube3d")
def _cube3d(root):
    part("lilac", root, "cube", g_box, I4, 0.11, 0.11, 0.11, r=0.018, seg=3)
    axes = (("red", V((1, 0, 0))), ("green", V((0, 0, 1))), ("blue", V((0, -1, 0))))
    for m, d in axes:
        part(m, root, "ax_" + m, g_tube, I4, [d * 0.055, d * 0.12], 0.006, segs=10, cap=("flat", "flat"))
        tipM = Matrix.Translation(d * 0.12) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4() @ T(0, 0, 0.014)
        part(m, root, "tip_" + m, g_cyl, tipM, 0.016, 0.0, 0.03, segs=16)
    part("white", root, "pivot", g_sphere, I4, 0.012, u=12, v=6)


@prop("clapper")
def _clapper(root):
    part("black", root, "slate", g_cookie, FF(0, 0, -0.03), rrect2(0.2, 0.13, 0.012), 0.016, bevel=0.003)
    lines_on(root, "lab", FF(0, -0.0085, -0.03), -0.08, 0.08, [0.03, 0.0, -0.03], w=0.004, depth=0.0015,
             material="white")

    def stripes(parent, x0, z0, name):
        part("black", parent, name + "bar", g_cookie, FF(x0 + 0.1, 0, z0 + 0.0165), rrect2(0.2, 0.033, 0.006), 0.014,
             bevel=0.002)
        for k in range(4):
            xs = x0 + 0.02 + k * 0.048
            quad = [(xs, z0 + 0.002), (xs + 0.022, z0 + 0.002), (xs + 0.036, z0 + 0.031), (xs + 0.014, z0 + 0.031)]
            part("white", parent, name + "s%d" % k, g_cookie, FF(0, -0.0075, 0) @ T(0, 0, 0), quad, 0.002)

    stripes(root, -0.1, 0.035, "low")
    arm = empty("clapper_arm", root, loc=(-0.1, 0, 0.069), rot=R("Y", -24))
    part("black", arm, "armbar", g_cookie, T(-0.1, 0, 0.069) @ R("Y", -24) @ FF(0.1, 0, 0.0165),
         rrect2(0.2, 0.033, 0.006), 0.014, bevel=0.002)
    for k in range(4):
        xs = 0.02 + k * 0.048
        quad = [(xs, 0.002), (xs + 0.022, 0.002), (xs + 0.036, 0.031), (xs + 0.014, 0.031)]
        part("white", arm, "as%d" % k, g_cookie, T(-0.1, 0, 0.069) @ R("Y", -24) @ FF(0, -0.0075, 0), quad, 0.002)
    part("silver", root, "hinge", g_cyl, T(-0.1, 0, 0.069) @ R("X", 90), 0.008, 0.008, 0.02, segs=16)


@prop("synth")
def _synth(root):
    part("lilac", root, "body", g_box, T(0, 0, 0.018), 0.37, 0.15, 0.036, r=0.01)
    whites = 13
    for k in range(whites):
        x = -0.162 + k * 0.027
        part("white", root, "w%d" % k, g_box, T(x, -0.03, 0.039), 0.024, 0.08, 0.012, r=0.003)
    for k in range(whites - 1):
        if k % 7 in (2, 6):
            continue
        x = -0.162 + k * 0.027 + 0.0135
        part("ink", root, "b%d" % k, g_box, T(x, -0.012, 0.047), 0.014, 0.048, 0.012, r=0.003)
    for k, m in enumerate(("pink", "yellow", "mint")):
        part(m, root, "knob%d" % k, g_cyl, T(-0.13 + k * 0.035, 0.048, 0.044), 0.011, 0.009, 0.016, segs=20,
             bevel=0.002)
    part("screen", root, "lcd", g_box, T(0.09, 0.048, 0.038), 0.11, 0.03, 0.006, r=0.003)


@prop("mic")
def _mic(root):
    part("black", root, "foot", g_cyl, T(0, 0, 0.007), 0.05, 0.055, 0.014, segs=32, bevel=0.004)
    part("black", root, "pole", g_tube, I4, [V((0, 0, 0.01)), V((0, 0, 0.115))], 0.007, segs=10)
    part("black", root, "yoke", g_torus, T(0, 0, 0.165) @ R("Y", 90) @ R("Z", 90), 0.045, 0.006, segs=32, rsegs=6,
         a0=math.radians(200), a1=math.radians(340))
    prof = [(0.0, 0.11), (0.024, 0.113), (0.033, 0.13), (0.034, 0.18), (0.03, 0.205), (0.018, 0.218), (0.0, 0.221)]
    part("metal", root, "capsule", g_lathe, I4, prof, segs=32)
    for k, z in enumerate((0.15, 0.165, 0.18, 0.195)):
        part("gray", root, "grille%d" % k, g_torus, T(0, 0, z), 0.0335 if z < 0.185 else 0.032, 0.0022, segs=32,
             rsegs=5)
    part("pink", root, "band", g_cyl, T(0, 0, 0.128), 0.0345, 0.0345, 0.016, segs=32, bevel=0.003)
    part("red", root, "led", g_sphere, T(0, -0.035, 0.128), 0.004, u=10, v=5)


@prop("camera")
def _camera(root):
    part("cream", root, "body", g_box, T(0, 0, 0), 0.16, 0.055, 0.1, r=0.014, seg=3)
    part("leather", root, "band", g_box, T(0, 0, -0.018), 0.163, 0.058, 0.044, r=0.008)
    Ml = T(0, -0.03, -0.004) @ R("X", 90)
    part("black", root, "lens", g_cyl, Ml @ T(0, 0, 0.012), 0.036, 0.032, 0.028, segs=32, bevel=0.003)
    part("metal", root, "lens_ring", g_torus, T(0, -0.057, -0.004) @ R("X", 90), 0.031, 0.004, segs=32, rsegs=8)
    part("glass", root, "lens_glass", g_sphere, T(0, -0.052, -0.004) @ S(1, 0.35, 1), 0.027, u=24, v=12)
    part("glint", root, "glint", g_sphere, T(-0.009, -0.061, 0.006), 0.0045, u=10, v=5)
    part("white", root, "flash", g_box, T(-0.05, -0.024, 0.03), 0.04, 0.012, 0.024, r=0.004)
    part("red", root, "button", g_cyl, T(0.055, 0.0, 0.055), 0.01, 0.01, 0.012, segs=20, bevel=0.002)
    part("black", root, "finder", g_box, T(0.045, -0.026, 0.032), 0.026, 0.008, 0.018, r=0.003)
    fl = empty("camera_flash", root, loc=(-0.05, -0.032, 0.03))
    part("glow", fl, "burst", g_cookie, FF(-0.05, -0.032, 0.03), star2(0.04, 0.016, 8, rnd=0.004), 0.003)


# =========================================================================== petites choses
@prop("mug_coffee")
def _mug_coffee(root):
    prof = [(0.0, 0.0), (0.05, 0.0), (0.06, 0.004), (0.065, 0.02), (0.066, 0.108), (0.064, 0.118), (0.059, 0.12),
            (0.055, 0.115), (0.055, 0.02), (0.0, 0.016)]
    part("cream", root, "cup", g_lathe, I4, prof, segs=40)
    part("coffee", root, "coffee", g_cyl, T(0, 0, 0.098), 0.0555, 0.0555, 0.004, segs=40)
    part("cream", root, "handle", g_tube, I4,
         [V((0.06 + math.cos(a) * 0.032, 0, 0.064 + math.sin(a) * 0.034)) for a in
          [math.radians(-80 + 160 * k / 12) for k in range(13)]], 0.0095, segs=10)
    part("pink", root, "heart", g_cookie, FF(0, -0.065, 0.058), heart2(0.032), 0.006, bevel=0.002, puff=0.002)
    st = empty("mug_coffee_steam", root, loc=(0, 0, 0.12))
    for k, x in enumerate((-0.022, 0.0, 0.022)):
        pts = [V((x + 0.008 * math.sin(t * 5.0 + k), 0, 0.125 + t * 0.07)) for t in [i / 8 for i in range(9)]]
        part("steam", st, "wisp%d" % k, g_tube, I4, pts, lambda t: 0.007 * (1 - 0.6 * t), segs=8)


@prop("coins")
def _coins(root):
    rnd = random.Random(6)
    for i in range(5):
        part("gold", root, "c%d" % i, g_cyl, T(rnd.uniform(-0.004, 0.004), rnd.uniform(-0.004, 0.004),
                                                0.0065 + i * 0.0128), 0.042, 0.042, 0.012, segs=36, bevel=0.002)
    part("gold", root, "c_side", g_cyl, T(-0.07, -0.01, 0.0065), 0.042, 0.042, 0.012, segs=36, bevel=0.002)
    top = empty("coins_top", root, loc=(0.065, -0.02, 0.045))
    part("gold", top, "coin", g_cyl, T(0.065, -0.02, 0.045) @ R("X", 90), 0.042, 0.042, 0.012, segs=36, bevel=0.002)
    part("yellow", top, "star", g_cookie, FF(0.065, -0.027, 0.045), star2(0.024, 0.011, 5, rnd=0.004), 0.004,
         bevel=0.001)


@prop("lightbulb")
def _lightbulb(root):
    prof = [(0.0, 0.062), (0.026, 0.058), (0.042, 0.04), (0.046, 0.015), (0.04, -0.008), (0.026, -0.026),
            (0.02, -0.036), (0.0, -0.036)]
    part("glow", root, "bulb", g_lathe, I4, prof, segs=32)
    for k, z in enumerate((-0.04, -0.049, -0.058)):
        part("silver", root, "thread%d" % k, g_torus, T(0, 0, z), 0.02, 0.0042, segs=24, rsegs=6)
    part("silver", root, "base", g_cyl, T(0, 0, -0.05), 0.02, 0.018, 0.026, segs=24)
    part("black", root, "tip", g_sphere, T(0, 0, -0.066) @ S(1, 1, 0.6), 0.01, u=12, v=6)
    rays = empty("lightbulb_rays", root)
    for k in range(5):
        a = math.radians(25 + 32.5 * k)
        d = V((math.cos(a), 0, math.sin(a)))
        part("glow", rays, "ray%d" % k, g_tube, I4, [d * 0.068 + V((0, 0, 0.012)), d * 0.095 + V((0, 0, 0.012))],
             0.0065, segs=8)


@prop("thought")
def _thought(root):
    t1 = empty("thought_1", root, loc=(0, 0, 0))
    part("white", t1, "dot", g_sphere, I4, 0.016, u=16, v=8)
    t2 = empty("thought_2", root, loc=(0.03, 0, 0.045))
    part("white", t2, "dot", g_sphere, T(0.03, 0, 0.045), 0.024, u=16, v=8)
    cl = empty("thought_cloud", root, loc=(0.09, 0, 0.12))
    for k, (x, z, r) in enumerate(((0.0, 0.0, 0.05), (-0.05, -0.01, 0.036), (0.05, -0.008, 0.038),
                                    (-0.025, 0.03, 0.036), (0.028, 0.032, 0.038))):
        part("white", cl, "puff%d" % k, g_sphere, T(0.09 + x, 0, 0.12 + z) @ S(1, 0.7, 1), r, u=20, v=10)
    for k in range(3):
        part("ink", cl, "dot%d" % k, g_sphere, T(0.06 + k * 0.03, -0.034, 0.122), 0.0085, u=12, v=6)


@prop("shopping_bag")
def _shopping_bag(root):
    part("pink", root, "bag", g_box, T(0, 0, 0.095), 0.17, 0.08, 0.19, r=0.008)
    part("white", root, "cuff", g_box, T(0, 0, 0.183), 0.172, 0.082, 0.016, r=0.004)
    for y in (-0.03, 0.03):
        pts = [V((-0.04, y, 0.185)), V((-0.035, y, 0.235)), V((0.0, y, 0.255)), V((0.035, y, 0.235)), V((0.04, y, 0.185))]
        part("white", root, "handle%d" % (y > 0), g_tube, I4, spline(pts, 4), 0.0045, segs=8)
    part("white", root, "logo", g_cookie, FF(0, -0.041, 0.1), heart2(0.045), 0.004, bevel=0.0015, puff=0.002)
    for k, (m, a) in enumerate((("mint", -14), ("yellow", 12))):
        part(m, root, "tissue%d" % k, g_cookie, T(-0.02 + k * 0.04, 0.0, 0.2) @ R("Y", a) @ FRONT,
             fillet([(-0.035, 0.0), (0.035, 0.0), (0.0, 0.07)], [0.0, 0.0, 0.02], 4), 0.004)


@prop("soda")
def _soda(root):
    part("red", root, "cup", g_lathe, I4, [(0.0, 0.0), (0.038, 0.0), (0.042, 0.005), (0.052, 0.14), (0.0, 0.14)],
         segs=36)
    part("white", root, "lid", g_lathe, I4, [(0.0, 0.158), (0.03, 0.155), (0.054, 0.145), (0.056, 0.138),
                                              (0.0, 0.136)], segs=36)
    part("white", root, "star", g_cookie, T(0, -0.0475, 0.075) @ R("X", -4) @ FRONT, star2(0.024, 0.011, 5, rnd=0.004),
         0.004, bevel=0.001)
    part("pink", root, "straw", g_tube, I4, [V((0.008, 0, 0.12)), V((0.012, 0, 0.215)), V((0.022, 0, 0.232)),
                                              V((0.045, 0, 0.238))], 0.0055, segs=10)


@prop("cupcake")
def _cupcake(root):
    part("sky", root, "liner", g_lathe, I4, [(0.0, 0.0), (0.034, 0.0), (0.046, 0.05), (0.0, 0.05)], segs=48,
         mod=lambda a, s, r, z: (r * (1 + 0.05 * math.cos(16 * a)), z))
    for k, (z, R_, r_) in enumerate(((0.06, 0.034, 0.016), (0.08, 0.024, 0.014), (0.097, 0.013, 0.011))):
        part("pink", root, "frost%d" % k, g_torus, T(0, 0, z), R_, r_, segs=40, rsegs=12)
    part("pink", root, "frost_top", g_sphere, T(0, 0, 0.1), 0.012, u=16, v=8)
    part("red", root, "cherry", g_sphere, T(0.0, 0, 0.122), 0.014, u=20, v=10)
    part("green", root, "stem", g_tube, I4, [V((0, 0, 0.13)), V((0.006, 0, 0.145)), V((0.016, 0, 0.152))], 0.0022,
         segs=6)
    rnd = random.Random(8)
    cols = ["yellow", "mint", "white", "purple", "sky"]
    for k in range(14):
        a = rnd.uniform(0, TAU)
        z = rnd.choice((0.064, 0.084))
        Rr = 0.036 if z < 0.07 else 0.026
        p = V((math.cos(a) * Rr, math.sin(a) * Rr, z + 0.012))
        d = V((rnd.uniform(-1, 1), rnd.uniform(-1, 1), rnd.uniform(-0.3, 0.3))).normalized() * 0.006
        part(cols[k % len(cols)], root, "spr%d" % k, g_tube, I4, [p - d, p + d], 0.0022, segs=6)


@prop("pennant")
def _pennant(root):
    part("wood", root, "stick", g_tube, I4, [V((0, 0, -0.05)), V((0, 0, 0.26))], 0.0065, segs=10)
    part("gold", root, "ball", g_sphere, T(0, 0, 0.265), 0.011, u=16, v=8)
    fl = empty("pennant_flag", root, loc=(0, 0, 0.25))
    part("red", fl, "flag", g_cookie, FF(0.0, 0, 0.25),
         fillet([(0.004, 0.0), (0.17, -0.045), (0.004, -0.095)], [0.0, 0.012, 0.0], 4), 0.006, bevel=0.0015)
    part("white", fl, "star", g_cookie, FF(0.055, -0.0035, 0.203), star2(0.02, 0.009, 5, rnd=0.003), 0.003)


@prop("rose")
def _rose(root):
    stem = spline([V((0, 0, -0.08)), V((0.006, 0, 0.0)), V((-0.004, 0, 0.08)), V((0, 0, 0.15))], 4)
    part("green", root, "stem", g_tube, I4, stem, 0.006, segs=8)
    for k, sx in enumerate((-1, 1)):
        Ml = T(0, 0, 0.02 + 0.04 * k) @ R("Z", 180 if sx < 0 else 0) @ R("Y", -30)
        part("green", root, "leaf%d" % k, g_cookie, Ml @ FRONT @ T(0.028, 0, 0),
             fillet([(-0.028, 0.0), (0.0, 0.012), (0.03, 0.0), (0.0, -0.012)], 0.01, 4), 0.004)
    part("red", root, "cup", g_lathe, I4, [(0.0, 0.14), (0.02, 0.145), (0.034, 0.165), (0.036, 0.19), (0.03, 0.198)],
         segs=40, mod=lambda a, s, r, z: (r * (1 + 0.08 * s * math.cos(5 * a)), z + 0.006 * s * math.cos(5 * a)),
         cap0=False)
    sp = [V((math.cos(t * 4.0) * 0.006 * (1 + t * 3), math.sin(t * 4.0) * 0.006 * (1 + t * 3), 0.19 - t * 0.012))
          for t in [i / 24 for i in range(25)]]
    part("red", root, "swirl", g_tube, I4, sp, 0.0065, segs=8)
    part("pink", root, "inner", g_sphere, T(0, 0, 0.178), 0.024, u=20, v=10)


@prop("sun_cloud")
def _sun_cloud(root):
    part("glow", root, "sun", g_sphere, T(-0.02, 0.01, 0.025), 0.045, u=24, v=12)
    rays = empty("sun_rays", root, loc=(-0.02, 0.01, 0.025))
    for k in range(8):
        a = TAU * k / 8
        d = V((math.cos(a), 0, math.sin(a)))
        part("glow", rays, "ray%d" % k, g_tube, I4,
             [V((-0.02, 0.01, 0.025)) + d * 0.058, V((-0.02, 0.01, 0.025)) + d * 0.078], 0.007, segs=8)
    for k, (x, z, r) in enumerate(((0.03, -0.02, 0.034), (0.0, -0.03, 0.026), (0.062, -0.028, 0.026),
                                    (0.045, 0.0, 0.026))):
        part("white", root, "cloud%d" % k, g_sphere, T(x, -0.03, z) @ S(1, 0.8, 0.9), r, u=20, v=10)


@prop("magnifier")
def _magnifier(root):
    # origine au centre de la lentille, manche vers le bas a droite
    part("gold", root, "ring", g_torus, FF(0, 0, 0), 0.068, 0.011, segs=48, rsegs=10)
    part("clear_glass", root, "lens", g_cyl, T(0, 0, 0) @ R("X", 90), 0.064, 0.064, 0.006, segs=40)
    part("glint", root, "glint", g_tube, I4, [V((math.cos(a) * 0.045, -0.006, math.sin(a) * 0.045)) for a in
                                               [math.radians(110 + 50 * k / 6) for k in range(7)]], 0.0045, segs=6)
    d = V((math.cos(math.radians(-55)), 0, math.sin(math.radians(-55))))
    a = d * 0.078
    part("gold", root, "collar", g_tube, I4, [a, a + d * 0.025], 0.0145, segs=16, cap=("flat", "flat"))
    part("wood", root, "handle", g_tube, I4, [a + d * 0.024, a + d * 0.07, a + d * 0.125],
         lambda t: 0.012 + 0.003 * math.sin(t * math.pi), segs=14)


@prop("chessboard")
def _chessboard(root):
    part("wood", root, "frame", g_box, T(0, 0, 0.009), 0.3, 0.3, 0.018, r=0.006)
    for i in range(4):
        for j in range(4):
            m = "cream" if (i + j) % 2 == 0 else "coffee"
            part(m, root, "sq%d%d" % (i, j), g_box, T(-0.099 + i * 0.066, -0.099 + j * 0.066, 0.0195), 0.066, 0.066,
                 0.004, r=0.0005, seg=1)
    prof = [(0.0, 0.0), (0.024, 0.0), (0.024, 0.007), (0.017, 0.012), (0.009, 0.03), (0.016, 0.036), (0.016, 0.04),
            (0.008, 0.042), (0.0, 0.042)]
    for nm, m, (x, y) in (("chess_pawn_w", "white", (-0.033, -0.099)), ("chess_pawn_b", "ink", (0.033, 0.033))):
        e = empty(nm, root, loc=(x, y, 0.022))
        part(m, e, "foot", g_lathe, T(x, y, 0.022), prof, segs=28)
        part(m, e, "head", g_sphere, T(x, y, 0.022 + 0.055), 0.016, u=20, v=10)


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
def export(path, roots):
    bpy.ops.object.select_all(action="DESELECT")

    def sel(o):
        o.select_set(True)
        for c in o.children:
            sel(c)

    for r in roots:
        sel(r)
    bpy.ops.export_scene.gltf(
        filepath=path, export_format="GLB", use_selection=True, export_apply=True,
        export_yup=True, export_normals=True, export_materials="EXPORT",
        export_texcoords=True, export_animations=False,
    )
    print("EXPORTED", path, len(roots), "props")


export(OUT_GLB, ROOTS)

if DO_PREVIEW:
    os.makedirs(os.path.dirname(PREVIEW), exist_ok=True)
    cols = 8
    for i, r in enumerate(ROOTS):
        r.location = ((i % cols) * 0.45, 0, -(i // cols) * 0.45)
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = cols * 0.45 + 0.2
    cam = link(bpy.data.objects.new("cam", cam_data))
    rows = (len(ROOTS) + cols - 1) // cols
    cam.location = ((cols - 1) * 0.45 / 2, -6, -(rows - 1) * 0.45 / 2 + 0.1)
    cam.rotation_euler = (math.radians(90), 0, 0)
    SCENE.camera = cam
    SCENE.render.engine = "BLENDER_WORKBENCH"
    SCENE.display.shading.light = "STUDIO"
    SCENE.display.shading.color_type = "MATERIAL"
    SCENE.render.resolution_x = 1600
    SCENE.render.resolution_y = int(1600 * rows / cols)
    SCENE.render.filepath = PREVIEW
    bpy.ops.render.render(write_still=True)
    print("PREVIEW", PREVIEW)
