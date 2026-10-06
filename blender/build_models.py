"""
Pompom - generation procedurale de tous les modeles 3D.

Lancement (headless) :
    blender --background --factory-startup --python blender/build_models.py

Sorties :
    godot/assets/models/bodies.glb       corps des compagnons (materiau fur_main)
    (face.glb et accessories.glb : voir build_face.py et build_accessories.py)
    godot/assets/models/props.glb        objets d'activite (ordi, manette, tasse)
    godot/data/species.json              points d'ancrage (yeux, chapeau, cou...) en coordonnees Godot
    blender/preview.png                  planche de verification (rendu Workbench)

Convention : Blender Z = haut, -Y = avant. Godot : (x, z, -y).
Les corps sont des surfaces SDF projetees sur une icosphere (formes "etoilees"),
avec des normales analytiques pour que les coques de fourrure soient bien lisses.
"""
import bpy
import bmesh
import json
import math
import os

import numpy as np
from mathutils import Matrix, Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_MODELS = os.path.join(ROOT, "godot", "assets", "models")
OUT_DATA = os.path.join(ROOT, "godot", "data")
os.makedirs(OUT_MODELS, exist_ok=True)
os.makedirs(OUT_DATA, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
SCENE = bpy.context.scene

# ---------------------------------------------------------------------------
# Materiaux (les couleurs reelles sont appliquees dans Godot via le nom)
# ---------------------------------------------------------------------------
MAT_COLORS = {
    "fur_main": (0.95, 0.55, 0.7), "fur_accent": (1, 1, 1), "main": (0.2, 0.2, 0.25),
    "accent": (0.9, 0.3, 0.35), "gold": (1.0, 0.75, 0.25), "metal": (0.75, 0.77, 0.8),
    "white": (0.97, 0.96, 0.93), "black": (0.04, 0.04, 0.05), "glass": (0.1, 0.1, 0.12),
    "glow": (1.0, 0.85, 0.4), "gem": (0.3, 0.6, 1.0), "glint": (1, 1, 1), "screen": (0.5, 0.8, 1.0),
    "eye_black": (0.03, 0.03, 0.035), "eye_white": (1, 1, 1),
}


def mat(name):
    m = bpy.data.materials.get(name)
    if m is None:
        m = bpy.data.materials.new(name)
        try:
            m.use_nodes = True
        except Exception:
            pass
        c = MAT_COLORS.get(name, (0.8, 0.8, 0.8))
        m.diffuse_color = (*c, 1.0)
        try:
            bsdf = m.node_tree.nodes.get("Principled BSDF")
            bsdf.inputs["Base Color"].default_value = (*c, 1.0)
        except Exception:
            pass
    return m


def clear_scene():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for me in list(bpy.data.meshes):
        bpy.data.meshes.remove(me)


def set_smooth(obj):
    me = obj.data
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    me.update()


def link(obj):
    SCENE.collection.objects.link(obj)
    return obj


def empty(name):
    e = bpy.data.objects.new(name, None)
    return link(e)


def finish(o, material, parent, bevel=0.0, subsurf=0, smooth=True):
    if smooth:
        set_smooth(o)
    if bevel > 0:
        b = o.modifiers.new("Bevel", "BEVEL")
        b.width = bevel
        b.segments = 4
        b.limit_method = "ANGLE"
        try:
            b.harden_normals = True
        except Exception:
            pass
    if subsurf > 0:
        s = o.modifiers.new("Sub", "SUBSURF")
        s.levels = subsurf
        s.render_levels = subsurf
    o.data.materials.clear()
    o.data.materials.append(mat(material))
    if parent is not None:
        o.parent = parent
    return o


def prim(kind, material, parent, loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1), bevel=0.0, subsurf=0, name=None, **kw):
    ops = {
        "cyl": bpy.ops.mesh.primitive_cylinder_add,
        "cone": bpy.ops.mesh.primitive_cone_add,
        "sphere": bpy.ops.mesh.primitive_uv_sphere_add,
        "ico": bpy.ops.mesh.primitive_ico_sphere_add,
        "torus": bpy.ops.mesh.primitive_torus_add,
        "cube": bpy.ops.mesh.primitive_cube_add,
    }
    if kind == "sphere":
        kw.setdefault("segments", 40)
        kw.setdefault("ring_count", 20)
    if kind in ("cyl", "cone"):
        kw.setdefault("vertices", 48)
    if kind == "torus":
        kw.setdefault("major_segments", 64)
        kw.setdefault("minor_segments", 16)
    ops[kind](location=loc, rotation=rot, **kw)
    o = bpy.context.active_object
    o.scale = scale
    if name:
        o.name = name
    return finish(o, material, parent, bevel=bevel, subsurf=subsurf)


def mesh_obj(name, bm, material, parent, smooth=True):
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    o = link(bpy.data.objects.new(name, me))
    return finish(o, material, parent, smooth=smooth)


def tube(name, pts, radius, material, parent, segs=14, cap_start=True, cap_end=True, closed=False):
    """Tube le long d'une polyligne (reperes par transport parallele)."""
    bm = bmesh.new()
    P = [Vector(p) for p in pts]
    n = len(P)

    def tangent(i):
        if closed:
            return (P[(i + 1) % n] - P[(i - 1) % n]).normalized()
        return (P[min(i + 1, n - 1)] - P[max(i - 1, 0)]).normalized()

    t0 = tangent(0)
    ref = Vector((0, 0, 1)) if abs(t0.z) < 0.9 else Vector((1, 0, 0))
    n1 = t0.cross(ref).normalized()
    rings = []
    radii = []
    for i, p in enumerate(P):
        t = tangent(i)
        n1 = (n1 - t * n1.dot(t)).normalized()
        n2 = t.cross(n1).normalized()
        r = radius(i / max(n - 1, 1)) if callable(radius) else radius
        radii.append(r)
        ring = [bm.verts.new(p + (n1 * math.cos(a) + n2 * math.sin(a)) * r)
                for a in [2 * math.pi * k / segs for k in range(segs)]]
        rings.append(ring)
    pairs = list(zip(rings[:-1], rings[1:]))
    if closed:
        pairs.append((rings[-1], rings[0]))
    for a, b in pairs:
        for k in range(segs):
            bm.faces.new((a[k], a[(k + 1) % segs], b[(k + 1) % segs], b[k]))
    if not closed:
        if cap_start and radii[0] > 1e-4:
            bmesh.ops.create_icosphere(bm, subdivisions=2, radius=radii[0], matrix=Matrix.Translation(P[0]))
        if cap_end and radii[-1] > 1e-4:
            bmesh.ops.create_icosphere(bm, subdivisions=2, radius=radii[-1], matrix=Matrix.Translation(P[-1]))
    return mesh_obj(name, bm, material, parent)


def hemi(name, material, parent, r, loc=(0, 0, 0), scale=(1, 1, 1), rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=24, radius=r)
    o = bpy.context.active_object
    o.name = name
    bm = bmesh.new()
    bm.from_mesh(o.data)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z < -1e-4], context="VERTS")
    bm.to_mesh(o.data)
    bm.free()
    o.location = loc
    o.scale = scale
    o.rotation_euler = rot
    return finish(o, material, parent)


def annulus(name, material, parent, r0, r1, zfunc, rings=10, segs=72, thickness=0.02, loc=(0, 0, 0)):
    bm = bmesh.new()
    grid = []
    for i in range(rings + 1):
        r = r0 + (r1 - r0) * i / rings
        row = []
        for k in range(segs):
            a = 2 * math.pi * k / segs
            x, y = math.cos(a) * r, math.sin(a) * r
            row.append(bm.verts.new((x, y, zfunc(x, y, r))))
        grid.append(row)
    for i in range(rings):
        for k in range(segs):
            bm.faces.new((grid[i][k], grid[i][(k + 1) % segs], grid[i + 1][(k + 1) % segs], grid[i + 1][k]))
    o = mesh_obj(name, bm, material, parent)
    o.location = loc
    s = o.modifiers.new("Solid", "SOLIDIFY")
    s.thickness = thickness
    s.offset = 0
    sub = o.modifiers.new("Sub", "SUBSURF")
    sub.levels = 1
    sub.render_levels = 1
    return o


def flat_shape(name, outline, depth, material, parent):
    """Prisme a partir d'un contour 2D (x, z) dans le plan XZ, epaisseur selon Y."""
    bm = bmesh.new()
    front = [bm.verts.new((x, -depth / 2, z)) for x, z in outline]
    back = [bm.verts.new((x, depth / 2, z)) for x, z in outline]
    bm.faces.new(front)
    bm.faces.new(list(reversed(back)))
    n = len(outline)
    for k in range(n):
        bm.faces.new((front[k], front[(k + 1) % n], back[(k + 1) % n], back[k]))
    bmesh.ops.triangulate(bm, faces=[f for f in bm.faces if len(f.verts) > 4])
    return mesh_obj(name, bm, material, parent, smooth=False)


def star_outline(r_out, r_in, points=5, rot=math.pi / 2, cx=0.0, cz=0.0):
    out = []
    for k in range(points * 2):
        a = rot + math.pi * k / points
        r = r_out if k % 2 == 0 else r_in
        out.append((cx + math.cos(a) * r, cz + math.sin(a) * r))
    return out


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
    print("EXPORTED", path)


# ---------------------------------------------------------------------------
# SDF (numpy, vectorise)
# ---------------------------------------------------------------------------
def L(v):
    return np.sqrt(np.sum(v * v, axis=-1))


def sd_ellipsoid(p, c, r):
    q = p - np.asarray(c, dtype=float)
    r = np.asarray(r, dtype=float)
    k0 = L(q / r)
    k1 = L(q / (r * r))
    return k0 * (k0 - 1.0) / np.maximum(k1, 1e-9)


def sd_sphere(p, c, r):
    return L(p - np.asarray(c, dtype=float)) - r


def smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
    return b * (1 - h) + a * h - k * h * (1 - h)


def sd_tri2(px, py, r):
    k = math.sqrt(3.0)
    px = np.abs(px) - r
    py = py + r / k
    cond = px + k * py > 0
    nx = np.where(cond, (px - k * py) / 2, px)
    ny = np.where(cond, (-k * px - py) / 2, py)
    nx = nx - np.clip(nx, -2 * r, 0)
    return -np.sqrt(nx * nx + ny * ny) * np.sign(ny)


def sd_heart2(px, py):
    px = np.abs(px)
    a = np.sqrt((px - 0.25) ** 2 + (py - 0.75) ** 2) - math.sqrt(2) / 4
    m = np.maximum(px + py, 0) * 0.5
    b = np.sqrt(np.minimum(px ** 2 + (py - 1) ** 2, (px - m) ** 2 + (py - m) ** 2)) * np.sign(px - py)
    return np.where(py + px > 1, a, b)


def extrude(d2, y, half, rnd):
    wx = d2
    wy = np.abs(y) - half
    return np.minimum(np.maximum(wx, wy), 0) + np.sqrt(np.maximum(wx, 0) ** 2 + np.maximum(wy, 0) ** 2) - rnd


def sdf_mochi(p):
    d = sd_ellipsoid(p, (0, 0, 0.52), (0.62, 0.54, 0.52))
    for sx in (-1, 1):
        d = smin(d, sd_sphere(p, (0.31 * sx, 0.04, 0.97), 0.18), 0.09)
    return d


def sdf_pico(p):
    d2 = sd_tri2(p[:, 0], p[:, 2] - 0.62, 0.40)
    return extrude(d2, p[:, 1], 0.07, 0.25)


def sdf_coco(p):
    s = 0.9
    d2 = sd_heart2(p[:, 0] / s, p[:, 2] / s) * s
    return extrude(d2 + 0.1, p[:, 1], 0.06, 0.22)


def sdf_nuage(p):
    c = np.array([0, 0, 0.55])
    d = sd_ellipsoid(p, c, (0.42, 0.30, 0.42))
    for i in range(6):
        a = i * math.pi / 3 + math.pi / 6
        lc = c + np.array([math.cos(a) * 0.36, 0, math.sin(a) * 0.36])
        d = smin(d, sd_ellipsoid(p, lc, (0.25, 0.25, 0.25)), 0.12)
    return d


def sdf_kiwi(p):
    d = sd_ellipsoid(p, (0, 0, 0.46), (0.64, 0.50, 0.46))
    for sx in (-1, 1):
        d = smin(d, sd_sphere(p, (0.27 * sx, -0.06, 0.84), 0.19), 0.10)
    return d


# id, sdf, centre de projection, hauteur finale, mise en page du visage (coords normalisees)
SPECIES = {
    "mochi": dict(sdf=sdf_mochi, center=(0, 0, 0.5), height=1.0,
                  eye=(0.16, 0.50), mouth=0.37, blush=(0.30, 0.41), hat_x=0.0, neck=0.2, eye_style="dot", hat_w=0.5),
    "pico": dict(sdf=sdf_pico, center=(0, 0, 0.62), height=1.1,
                 eye=(0.14, 0.50), mouth=0.33, blush=(0.27, 0.38), hat_x=0.0, neck=0.17, eye_style="googly", hat_w=0.5),
    "coco": dict(sdf=sdf_coco, center=(0, 0, 0.55), height=1.05,
                 eye=(0.2, 0.62), mouth=0.49, blush=(0.36, 0.52), hat_x=0.25, neck=0.3, eye_style="dot", hat_w=0.55),
    "nuage": dict(sdf=sdf_nuage, center=(0, 0, 0.55), height=1.0,
                  eye=(0.11, 0.52), mouth=0.42, blush=(0.24, 0.44), hat_x=0.06, neck=0.18, eye_style="dot", hat_w=0.52),
    "kiwi": dict(sdf=sdf_kiwi, center=(0, 0, 0.45), height=0.95,
                 eye=(0.255, 0.79), mouth=0.42, blush=(0.38, 0.47), hat_x=0.0, neck=0.17, eye_style="googly", hat_w=0.5),
}


def project_dirs(sdf, center, dirs, r_max=3.0, iters=48):
    lo = np.zeros(len(dirs))
    hi = np.full(len(dirs), r_max)
    for _ in range(iters):
        mid = (lo + hi) * 0.5
        inside = sdf(center + dirs * mid[:, None]) < 0
        lo = np.where(inside, mid, lo)
        hi = np.where(inside, hi, mid)
    return center + dirs * ((lo + hi) * 0.5)[:, None]


def grad(sdf, p, eps=1e-4):
    g = np.zeros_like(p)
    for i in range(3):
        e = np.zeros(3)
        e[i] = eps
        g[:, i] = sdf(p + e) - sdf(p - e)
    return g / np.maximum(L(g)[:, None], 1e-12)


def bisect_line(sdf, a, b, iters=48):
    """a dehors, b dedans -> premier point de surface (approx)."""
    a = np.array(a, dtype=float)
    b = np.array(b, dtype=float)
    for _ in range(iters):
        m = (a + b) * 0.5
        if sdf(m[None, :])[0] < 0:
            b = m
        else:
            a = m
    return (a + b) * 0.5


def march_first(sdf, start, end, steps=400):
    """Avance de start vers end et renvoie le premier point de surface."""
    start = np.array(start, dtype=float)
    end = np.array(end, dtype=float)
    prev = start
    for i in range(1, steps + 1):
        cur = start + (end - start) * (i / steps)
        if sdf(cur[None, :])[0] < 0:
            return bisect_line(sdf, prev, cur)
        prev = cur
    return None


def to_godot(v):
    return [round(float(v[0]), 5), round(float(v[2]), 5), round(float(-v[1]), 5)]


def build_body(sid, cfg, parent_list):
    sdf0 = cfg["sdf"]
    center = np.array(cfg["center"], dtype=float)
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=5, radius=1.0)
    dirs = np.array([v.co[:] for v in bm.verts])
    dirs /= L(dirs)[:, None]
    pts = project_dirs(sdf0, center, dirs)
    zmin, zmax = pts[:, 2].min(), pts[:, 2].max()
    xc = (pts[:, 0].min() + pts[:, 0].max()) * 0.5
    yc = (pts[:, 1].min() + pts[:, 1].max()) * 0.5
    s = cfg["height"] / (zmax - zmin)
    off = np.array([xc, yc, zmin])

    def sdf(p):
        return sdf0(p / s + off) * s

    pts = (pts - off) * s
    nrm = grad(sdf, pts)
    for v, p in zip(bm.verts, pts):
        v.co = Vector(p)
    me = bpy.data.meshes.new("body_" + sid)
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    me.update()
    try:
        me.normals_split_custom_set_from_vertices([Vector(n) for n in nrm])
    except Exception as e:
        print("custom normals failed", e)
    o = link(bpy.data.objects.new("body_" + sid, me))
    o.data.materials.append(mat("fur_main"))
    parent_list.append(o)

    # --- ancrages ---
    H = cfg["height"]
    width = float(pts[:, 0].max() - pts[:, 0].min())
    depth = float(pts[:, 1].max() - pts[:, 1].min())

    def front(x, z):
        hit = march_first(sdf, (x, -2.0, z), (x, 2.0, z))
        n = grad(sdf, hit[None, :])[0]
        return hit, n

    def top(x):
        hit = march_first(sdf, (x, 0.0, H + 1.0), (x, 0.0, 0.0))
        n = grad(sdf, hit[None, :])[0]
        return hit, n

    ex, ez = cfg["eye"]
    eye_l, n_l = front(-ex, ez)
    eye_r, n_r = front(ex, ez)
    mouth, n_m = front(0.0, cfg["mouth"])
    bx, bz = cfg["blush"]
    bl, _ = front(-bx, bz)
    br, _ = front(bx, bz)
    hat, n_h = top(cfg["hat_x"])
    neck, n_n = front(0.0, cfg["neck"])
    side = march_first(sdf, (2.0, 0.0, cfg["neck"]), (0.0, 0.0, cfg["neck"]))
    back = march_first(sdf, (0.0, 2.0, cfg["neck"]), (0.0, 0.0, cfg["neck"]))
    neck_radius = float((abs(side[0]) + abs(back[1]) + abs(neck[1])) / 3.0)
    back_pt = march_first(sdf, (0.0, 2.0, H * 0.45), (0.0, 0.0, H * 0.45))
    back_n = grad(sdf, back_pt[None, :])[0]
    # largeur de la tete a la hauteur du chapeau (pour mettre les chapeaux a l'echelle)
    hz = max(hat[2] - 0.12, H * 0.5)
    hs = march_first(sdf, (2.0, 0.0, hz), (0.0, 0.0, hz))
    hat_width = float(cfg.get("hat_w", abs(hs[0]) * 2))
    # largeur pour le casque audio (a hauteur des oreilles)
    ez_ = max(hat[2] - 0.35, H * 0.45)
    es = march_first(sdf, (2.0, 0.0, ez_), (0.0, 0.0, ez_))
    ear_width = float(abs(es[0]) * 2)

    anchors = {
        "height": H, "width": width, "depth": depth, "eye_style": cfg["eye_style"],
        "eye_l": to_godot(eye_l), "eye_l_n": to_godot(n_l),
        "eye_r": to_godot(eye_r), "eye_r_n": to_godot(n_r),
        "mouth": to_godot(mouth), "mouth_n": to_godot(n_m),
        "blush_l": to_godot(bl), "blush_r": to_godot(br),
        "hat": to_godot(hat), "hat_n": to_godot(n_h), "hat_width": hat_width, "ear_width": ear_width,
        "neck": to_godot(neck), "neck_n": to_godot(n_n), "neck_center": to_godot((0, 0, cfg["neck"])),
        "neck_radius": neck_radius, "neck_rx": float(abs(side[0])), "neck_rz": float((abs(back[1]) + abs(neck[1])) * 0.5), "back": to_godot(back_pt), "back_n": to_godot(back_n),
    }
    return o, anchors


# ---------------------------------------------------------------------------
# 1) Corps
# ---------------------------------------------------------------------------
clear_scene()
bodies = []
species_json = {}
for sid, cfg in SPECIES.items():
    o, anchors = build_body(sid, cfg, bodies)
    species_json[sid] = anchors
    print("body", sid, anchors["width"], anchors["hat_width"])
export(os.path.join(OUT_MODELS, "bodies.glb"), bodies)
with open(os.path.join(OUT_DATA, "species.json"), "w", encoding="utf-8") as f:
    json.dump(species_json, f, indent=1)

# ---------------------------------------------------------------------------
# 4) Objets d'activite
# ---------------------------------------------------------------------------
clear_scene()
props = []
e = empty("laptop")
props.append(e)
prim("cube", "metal", e, loc=(0, 0, 0.012), scale=(0.2, 0.14, 0.012), bevel=0.01)
prim("cube", "black", e, loc=(0, -0.06, 0.026), scale=(0.16, 0.06, 0.003), bevel=0.002)
hinge = empty("laptop_lid")
hinge.parent = e
hinge.location = (0, 0.135, 0.024)
hinge.rotation_euler = (math.radians(-18), 0, 0)
prim("cube", "metal", hinge, loc=(0, 0.01, 0.14), scale=(0.2, 0.01, 0.14), bevel=0.008)
prim("cube", "screen", hinge, loc=(0, -0.002, 0.14), scale=(0.18, 0.002, 0.12))

e = empty("gamepad")
props.append(e)
body_pts = []
prim("sphere", "main", e, loc=(0, 0, 0), scale=(0.16, 0.06, 0.08))
for sx in (-1, 1):
    prim("sphere", "main", e, loc=(sx * 0.12, 0.0, -0.05), scale=(0.07, 0.06, 0.09))
prim("cyl", "black", e, loc=(-0.07, -0.055, 0.01), rot=(math.pi / 2, 0, 0), radius=0.03, depth=0.02, bevel=0.006)
for k, col in enumerate(("accent", "gem", "gold", "white")):
    a = math.pi / 2 * k
    prim("sphere", col, e, loc=(0.075 + math.cos(a) * 0.028, -0.055, 0.01 + math.sin(a) * 0.028), radius=0.013)

e = empty("mug")
props.append(e)
bpy.ops.mesh.primitive_cylinder_add(vertices=48, radius=0.07, depth=0.13, location=(0, 0, 0.065), end_fill_type="NGON")
o = bpy.context.active_object
bm = bmesh.new()
bm.from_mesh(o.data)
top = [f for f in bm.faces if f.normal.z > 0.9]
bmesh.ops.delete(bm, geom=top, context="FACES")
bm.to_mesh(o.data)
bm.free()
s = o.modifiers.new("Solid", "SOLIDIFY")
s.thickness = 0.012
finish(o, "accent", e, bevel=0.004)
prim("cyl", "black", e, loc=(0, 0, 0.11), radius=0.062, depth=0.005)
prim("torus", "accent", e, loc=(0.075, 0, 0.07), rot=(math.pi / 2, 0, 0), major_radius=0.035, minor_radius=0.011)

# petit telephone : coque arrondie (accent), ecran lumineux, camera, boutons
e = empty("phone")
props.append(e)
prim("cube", "accent", e, loc=(0, 0, 0), scale=(0.062, 0.009, 0.12), bevel=0.02)
prim("cube", "screen", e, loc=(0, -0.0095, 0.004), scale=(0.054, 0.0012, 0.105), bevel=0.012)
prim("cube", "black", e, loc=(0, -0.0105, 0.098), scale=(0.014, 0.001, 0.0035), bevel=0.003)
prim("cyl", "black", e, loc=(-0.032, 0.0095, 0.09), rot=(math.pi / 2, 0, 0), radius=0.012, depth=0.004, bevel=0.002)
prim("cyl", "glass", e, loc=(-0.032, 0.0115, 0.09), rot=(math.pi / 2, 0, 0), radius=0.008, depth=0.002)
for z in (0.05, 0.02):
    prim("cube", "accent", e, loc=(0.064, 0, z), scale=(0.003, 0.004, 0.012), bevel=0.002)

export(os.path.join(OUT_MODELS, "props.glb"), props)

# ---------------------------------------------------------------------------
# 5) Planche de verification des corps (Workbench)
# ---------------------------------------------------------------------------
clear_scene()
bpy.ops.import_scene.gltf(filepath=os.path.join(OUT_MODELS, "bodies.glb"))
x = 0.0
for o in list(bpy.data.objects):
    if o.name.startswith("body_"):
        o.location = (x, 0, 0)
        x += 1.6
cam_data = bpy.data.cameras.new("cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = x + 0.2
cam = bpy.data.objects.new("cam", cam_data)
link(cam)
cam.location = ((x - 1.6) / 2, -6, 0.6)
cam.rotation_euler = (math.pi / 2, 0, 0)
SCENE.camera = cam
SCENE.render.engine = "BLENDER_WORKBENCH"
SCENE.display.shading.light = "STUDIO"
SCENE.render.resolution_x = 1800
SCENE.render.resolution_y = 500
SCENE.render.filepath = os.path.join(ROOT, "blender", "preview_bodies.png")
bpy.ops.render.render(write_still=True)
print("PREVIEW OK")
