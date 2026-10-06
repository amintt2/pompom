"""
Pompom - lookdev Cycles : matcaps (fourrure / plastique / feutre) et rendus de reference.

Lancement (headless) :
    blender --background --factory-startup --python blender/render_lookdev.py -- [cibles] [cle=valeur ...]

Cibles (defaut : all) :
    rig                     ecrit godot/data/studio_rig.json
    fur fur_color gloss_black gloss_white felt   matcaps -> godot/assets/textures/*_matcap*.png
    sheet                   planche blender/previews/matcap_sheet.png
    mochi nuage coco kiwi   rendus blender/previews/ref_*.png
    matcaps / refs / all    groupes
Options : samples=N  ref_samples=N  cpu=1  (surcharge des echantillons / force CPU)

Conventions : Blender Z = haut, -Y = avant (le spectateur est en -Y, la camera regarde +Y).
Godot : (x, y, z)_godot = (x, z, -y)_blender. Espace vue Godot (camera frontale) : x droite, y haut,
z vers la camera  ->  vue = (bx, bz, -by).
"""
import bpy
import json
import math
import os
import sys
import time

import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS = os.path.join(ROOT, "godot", "assets", "models")
TEX_DIR = os.path.join(ROOT, "godot", "assets", "textures")
PREV_DIR = os.path.join(ROOT, "blender", "previews")
RIG_JSON = os.path.join(ROOT, "godot", "data", "studio_rig.json")
SPECIES = json.load(open(os.path.join(ROOT, "godot", "data", "species.json"), encoding="utf-8"))
os.makedirs(TEX_DIR, exist_ok=True)
os.makedirs(PREV_DIR, exist_ok=True)

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OPTS = dict(a.split("=", 1) for a in ARGS if "=" in a)
TARGETS = [a for a in ARGS if "=" not in a] or ["all"]
GROUPS = {
    "matcaps": ["fur", "fur_color", "gloss_black", "gloss_white", "felt"],
    "refs": ["mochi", "nuage", "coco", "kiwi"],
}
GROUPS["all"] = ["rig"] + GROUPS["matcaps"] + ["sheet"] + GROUPS["refs"]
TODO = []
for t in TARGETS:
    for x in GROUPS.get(t, [t]):
        if x not in TODO:
            TODO.append(x)

MATCAP_SAMPLES = int(OPTS.get("samples", 512))
REF_SAMPLES = int(OPTS.get("ref_samples", 256))
FORCE_CPU = OPTS.get("cpu", "0") == "1"


def srgb2lin(h):
    h = h.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


def lin2hex(c):
    out = []
    for x in c[:3]:
        x = max(0.0, min(1.0, x))
        s = x * 12.92 if x <= 0.0031308 else 1.055 * x ** (1 / 2.4) - 0.055
        out.append("%02x" % int(round(s * 255)))
    return "".join(out)


# ===========================================================================
# STUDIO RIG (partage par tous les rendus)
# dir = direction VERS la lumiere, en coordonnees Blender monde (camera en -Y, regarde +Y).
# ===========================================================================
RIG = {
    "exposure": 0.0,
    "lights": [
        # grande lumiere cle douce : haut-gauche-avant
        dict(name="key", dir=(-0.62, -0.62, 0.78), color=(1.0, 0.965, 0.93), strength=2.8, angle=55.0),
        # remplissage : droite-avant, un peu bas, froid
        dict(name="fill", dir=(0.9, -0.55, -0.05), color=(0.90, 0.94, 1.0), strength=0.85, angle=75.0),
        # contre-jour doux : arriere-haut-droite
        dict(name="rim", dir=(0.55, 0.85, 0.45), color=(1.0, 0.98, 0.98), strength=2.0, angle=30.0),
    ],
    # ciel degrade (ambiance) : couleurs lineaires x intensite
    "sky_top": (0.44, 0.445, 0.47),
    "sky_horizon": (0.37, 0.365, 0.38),
    "sky_ground": (0.22, 0.21, 0.22),
    "sky_strength": 1.4,
    # le ciel vu en REFLEXION (rayons glossy) est attenue : studio sombre + grandes boites a lumiere
    "sky_specular_factor": 0.35,
}


def b2view(v):
    """Blender monde -> espace vue Godot (camera frontale)."""
    v = Vector(v).normalized()
    return [round(v.x, 4), round(v.z, 4), round(-v.y, 4)]


def write_rig_json():
    key = RIG["lights"][0]["strength"]
    d = {
        "_doc": ("Studio rig shared by the Cycles matcaps (godot/assets/textures/*matcap*.png) and the "
                 "reference renders (blender/previews/ref_*.png). Directions point TOWARD the light, in "
                 "Godot VIEW space of the front camera (x right, y up, z toward the camera). Colours are "
                 "linear RGB (hex = sRGB). 'energy' = Cycles sun strength (W/m2) ; 'relative_energy' = "
                 "energy / key energy. 'softness_deg' = sun angular diameter (Godot DirectionalLight3D "
                 "light_angular_distance ~ half of it). Ambient = 3-colour gradient sky (top / horizon / "
                 "ground), like a Godot ProceduralSkyMaterial; sky_strength multiplies it; seen in REFLECTIONS (glossy rays) the sky is multiplied by sky_specular_factor (dark studio, bright softboxes = the sun discs). Camera is "
                 "fixed relative to the rig: lights move with the view (matcap convention). Colour "
                 "management: Standard view transform, exposure as given, no tonemapping."),
        "generator": "blender/render_lookdev.py",
        "view_transform": "Standard",
        "exposure": RIG["exposure"],
        "lights": [],
        "ambient": {
            "sky_top": [round(x, 4) for x in RIG["sky_top"]],
            "sky_top_hex": lin2hex(RIG["sky_top"]),
            "sky_horizon": [round(x, 4) for x in RIG["sky_horizon"]],
            "sky_horizon_hex": lin2hex(RIG["sky_horizon"]),
            "sky_ground": [round(x, 4) for x in RIG["sky_ground"]],
            "sky_ground_hex": lin2hex(RIG["sky_ground"]),
            "sky_strength": RIG["sky_strength"],
            "sky_specular_factor": RIG["sky_specular_factor"],
            "average_color": [round((a + 2 * b + c) / 4 * RIG["sky_strength"], 4) for a, b, c in
                              zip(RIG["sky_top"], RIG["sky_horizon"], RIG["sky_ground"])],
        },
    }
    for L in RIG["lights"]:
        d["lights"].append({
            "name": L["name"],
            "direction_view": b2view(L["dir"]),
            "direction_blender_world": [round(x, 4) for x in Vector(L["dir"]).normalized()],
            "color": [round(x, 4) for x in L["color"]],
            "color_hex": lin2hex(L["color"]),
            "energy": L["strength"],
            "relative_energy": round(L["strength"] / key, 4),
            "softness_deg": L["angle"],
            "shadows": True,
        })
    with open(RIG_JSON, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=1)
    print("WROTE", RIG_JSON)


# ===========================================================================
# Scene / Cycles
# ===========================================================================
def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def setup_cycles(res, samples):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    cy = sc.cycles
    dev = "CPU"
    if not FORCE_CPU:
        try:
            prefs = bpy.context.preferences.addons["cycles"].preferences
            prefs.compute_device_type = "HIP"
            prefs.get_devices()
            n = 0
            for d in prefs.devices:
                d.use = d.type == "HIP"
                n += d.use
            if n:
                dev = "GPU"
        except Exception as e:
            print("GPU setup failed:", e)
    cy.device = dev
    print("CYCLES DEVICE", dev)
    cy.samples = samples
    cy.use_adaptive_sampling = True
    cy.adaptive_threshold = 0.008
    cy.adaptive_min_samples = 64
    cy.use_denoising = True
    cy.denoiser = "OPENIMAGEDENOISE"
    try:
        cy.denoising_input_passes = "RGB_ALBEDO_NORMAL"
        cy.denoising_prefilter = "ACCURATE"
        cy.denoising_quality = "HIGH"
        cy.denoising_use_gpu = dev == "GPU"
    except Exception:
        pass
    cy.max_bounces = int(OPTS.get("bounces", 24))
    cy.diffuse_bounces = 4
    cy.glossy_bounces = int(OPTS.get("bounces", 24))
    cy.transmission_bounces = int(OPTS.get("bounces", 24))
    cy.transparent_max_bounces = 16
    cy.sample_clamp_indirect = float(OPTS.get("clamp", 0.0))
    cy.blur_glossy = 1.0
    cy.caustics_reflective = False
    cy.caustics_refractive = False
    try:
        sc.cycles_curves.shape = "THICK"
        sc.cycles_curves.subdivisions = 2
    except Exception as e:
        print("curves shape", e)
    sc.render.resolution_x = res
    sc.render.resolution_y = res
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = True
    sc.render.filter_size = 1.2
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.render.image_settings.color_depth = "8"
    try:
        sc.view_settings.view_transform = "Standard"
        sc.view_settings.look = "None"
    except Exception as e:
        print("view transform", e)
    sc.view_settings.exposure = RIG["exposure"]
    sc.view_settings.gamma = 1.0


def setup_rig():
    sc = bpy.context.scene
    w = bpy.data.worlds.new("studio")
    sc.world = w
    try:
        w.use_nodes = True
    except Exception:
        pass
    nt = w.node_tree
    nt.nodes.clear()
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    mr = nt.nodes.new("ShaderNodeMapRange")
    bg = nt.nodes.new("ShaderNodeBackground")
    out = nt.nodes.new("ShaderNodeOutputWorld")
    nt.links.new(tc.outputs["Generated"], sep.inputs[0])
    nt.links.new(sep.outputs["Z"], mr.inputs["Value"])
    mr.inputs["From Min"].default_value = -1.0
    mr.inputs["From Max"].default_value = 1.0
    nt.links.new(mr.outputs["Result"], ramp.inputs["Fac"])
    els = ramp.color_ramp.elements
    els[0].position = 0.0
    els[0].color = (*RIG["sky_ground"], 1)
    els[1].position = 1.0
    els[1].color = (*RIG["sky_top"], 1)
    e = els.new(0.5)
    e.color = (*RIG["sky_horizon"], 1)
    ramp.color_ramp.interpolation = "EASE"
    nt.links.new(ramp.outputs["Color"], bg.inputs["Color"])
    lp = nt.nodes.new("ShaderNodeLightPath")
    mr2 = nt.nodes.new("ShaderNodeMapRange")
    nt.links.new(lp.outputs["Is Glossy Ray"], mr2.inputs["Value"])
    mr2.inputs["To Min"].default_value = RIG["sky_strength"]
    mr2.inputs["To Max"].default_value = RIG["sky_strength"] * RIG["sky_specular_factor"]
    nt.links.new(mr2.outputs["Result"], bg.inputs["Strength"])
    nt.links.new(bg.outputs[0], out.inputs[0])
    for L in RIG["lights"]:
        ld = bpy.data.lights.new(L["name"], "SUN")
        ld.energy = L["strength"]
        ld.color = L["color"]
        ld.angle = math.radians(L["angle"])
        o = bpy.data.objects.new(L["name"], ld)
        sc.collection.objects.link(o)
        d = Vector(L["dir"]).normalized()
        # le soleil eclaire selon son -Z local : -Z doit pointer a l'oppose de d
        o.rotation_euler = d.to_track_quat("Z", "Y").to_euler()


def add_camera_ortho(scale=2.0):
    sc = bpy.context.scene
    cd = bpy.data.cameras.new("cam")
    cd.type = "ORTHO"
    cd.ortho_scale = scale
    cd.clip_start = 0.1
    cd.clip_end = 100
    cam = bpy.data.objects.new("cam", cd)
    sc.collection.objects.link(cam)
    cam.location = (0, -10, 0)
    cam.rotation_euler = (math.pi / 2, 0, 0)
    sc.camera = cam
    return cam


def add_camera_persp(target_z, dist, lens, eye_z=None):
    """Camera regardant +Y (horizontale, donc l'espace vue = le repere du rig). eye_z : hauteur de l'oeil,
    le cadrage sur target_z se fait par decentrement (shift), sans incliner la camera."""
    sc = bpy.context.scene
    cd = bpy.data.cameras.new("cam")
    cd.lens = lens
    cd.sensor_width = 36
    cd.sensor_fit = "HORIZONTAL"
    cd.clip_start = 0.05
    eye_z = target_z if eye_z is None else eye_z
    cd.shift_y = (target_z - eye_z) / dist * lens / 36.0
    cam = bpy.data.objects.new("cam", cd)
    sc.collection.objects.link(cam)
    cam.location = (0, -dist, eye_z)
    cam.rotation_euler = (math.pi / 2, 0, 0)
    sc.camera = cam
    return cam


# ===========================================================================
# Materiaux
# ===========================================================================
def new_mat(name):
    m = bpy.data.materials.new(name)
    try:
        m.use_nodes = True
    except Exception:
        pass
    return m


def principled(name, col, rough=0.5, coat=0.0, coat_rough=0.05, sheen=0.0, sheen_rough=0.5, spec=0.5,
               metal=0.0, emit=0.0, alpha=1.0):
    m = new_mat(name)
    b = m.node_tree.nodes.get("Principled BSDF")
    b.inputs["Base Color"].default_value = (*col, 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    b.inputs["Coat Weight"].default_value = coat
    b.inputs["Coat Roughness"].default_value = coat_rough
    b.inputs["Sheen Weight"].default_value = sheen
    b.inputs["Sheen Roughness"].default_value = sheen_rough
    b.inputs["Specular IOR Level"].default_value = spec
    if emit:
        b.inputs["Emission Color"].default_value = (*col, 1)
        b.inputs["Emission Strength"].default_value = emit
    if alpha < 1.0:
        b.inputs["Alpha"].default_value = alpha
    return m


def gloss_black_mat(name="gloss_black"):
    return principled(name, (0.008, 0.0075, 0.009), rough=0.22, coat=1.0, coat_rough=0.14, spec=0.2)


def gloss_white_mat(name="gloss_white"):
    return principled(name, (0.70, 0.695, 0.69), rough=0.3, coat=0.5, coat_rough=0.2, spec=0.5)


def felt_mat(name="felt", col=(0.62, 0.62, 0.62)):
    return principled(name, col, rough=0.9, sheen=1.0, sheen_rough=0.45, spec=0.15)


def fur_input(col, k=0.75):
    """Compensation : la diffusion multiple dans une fourrure dense assombrit et sature la couleur
    directe du Hair BSDF ; on eclaircit l'entree (puissance < 1 en lineaire) pour que la fourrure
    eclairee retombe sur la teinte voulue."""
    return tuple(c ** k for c in col)


def hair_mat(name, col, melanin=None, rough=0.42, radial=0.75, coat=0.0, rand_col=0.08, rand_rough=0.15,
             root_dark=0.0):
    """Principled Hair BSDF (Chiang). col = couleur directe lineaire (parametrisation COLOR)."""
    m = new_mat(name)
    nt = m.node_tree
    nt.nodes.clear()
    h = nt.nodes.new("ShaderNodeBsdfHairPrincipled")
    h.model = "CHIANG"
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    if melanin is not None:
        h.parametrization = "MELANIN"
        h.inputs["Melanin"].default_value = melanin
        h.inputs["Melanin Redness"].default_value = 0.5
        h.inputs["Tint"].default_value = (*col, 1)
    else:
        h.parametrization = "COLOR"
        if root_dark > 0:
            # racine legerement plus sombre/saturee (Hair Info > Intercept)
            hi = nt.nodes.new("ShaderNodeHairInfo")
            mix = nt.nodes.new("ShaderNodeMix")
            mix.data_type = "RGBA"
            mix.inputs["A"].default_value = (*[c * (1 - root_dark) for c in col], 1)
            mix.inputs["B"].default_value = (*col, 1)
            pw = nt.nodes.new("ShaderNodeMath")
            pw.operation = "POWER"
            nt.links.new(hi.outputs["Intercept"], pw.inputs[0])
            pw.inputs[1].default_value = 0.5
            nt.links.new(pw.outputs[0], mix.inputs["Factor"])
            nt.links.new(mix.outputs["Result"], h.inputs["Color"])
        else:
            h.inputs["Color"].default_value = (*col, 1)
    for k, v in (("Roughness", rough), ("Radial Roughness", radial), ("Coat", coat), ("IOR", 1.55),
                 ("Offset", math.radians(2.0)), ("Random Color", rand_col), ("Random Roughness", rand_rough)):
        sock = h.inputs.get(k)
        if sock is not None:
            sock.default_value = v
        else:
            print("  hair input missing:", k)
    nt.links.new(h.outputs[0], out.inputs["Surface"])
    return m


# ===========================================================================
# FOURRURE : courbes generees en numpy -> objet Curves (rendu natif Cycles)
# ===========================================================================
FUR_SPHERE = dict(density=60000, length=0.07, len_var=0.25, root_r=0.0016, tip_r=0.0004, segs=5,
                  tilt=0.30, frizz=0.22, clump=0.35, clump_n=14, curl=0.10, seed=1)
FUR_FELT = dict(density=400000, length=0.007, len_var=0.4, root_r=0.0005, tip_r=0.00012, segs=3,
                tilt=0.7, frizz=0.6, clump=0.0, clump_n=1, curl=0.3, seed=3)
FUR_BODY = dict(density=160000, length=0.042, len_var=0.25, root_r=0.0011, tip_r=0.00028, segs=5,
                tilt=0.30, frizz=0.22, clump=0.35, clump_n=14, curl=0.10, seed=2)


def mesh_triangles_world(obj):
    """(tri_pos (T,3,3), tri_nrm (T,3,3)) en monde, normales lissees par coin."""
    dg = bpy.context.evaluated_depsgraph_get()
    oe = obj.evaluated_get(dg)
    me = oe.to_mesh()
    me.calc_loop_triangles()
    nt = len(me.loop_triangles)
    vidx = np.empty(nt * 3, np.int32)
    me.loop_triangles.foreach_get("vertices", vidx)
    lidx = np.empty(nt * 3, np.int32)
    me.loop_triangles.foreach_get("loops", lidx)
    co = np.empty(len(me.vertices) * 3, np.float32)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    try:
        cn = np.empty(len(me.loops) * 3, np.float32)
        me.corner_normals.foreach_get("vector", cn)
        cn = cn.reshape(-1, 3)[lidx]
    except Exception:
        cn = np.empty(len(me.vertices) * 3, np.float32)
        me.vertices.foreach_get("normal", cn)
        cn = cn.reshape(-1, 3)[vidx]
    M = np.array(obj.matrix_world, dtype=np.float64)
    R = M[:3, :3]
    Ninv = np.linalg.inv(R).T
    pos = co[vidx].astype(np.float64) @ R.T + M[:3, 3]
    nrm = cn.astype(np.float64) @ Ninv.T
    nrm /= np.linalg.norm(nrm, axis=1, keepdims=True) + 1e-12
    oe.to_mesh_clear()
    return pos.reshape(-1, 3, 3), nrm.reshape(-1, 3, 3)


def sample_surface(tri_pos, tri_nrm, n, rng):
    a = tri_pos[:, 1] - tri_pos[:, 0]
    b = tri_pos[:, 2] - tri_pos[:, 0]
    area = 0.5 * np.linalg.norm(np.cross(a, b), axis=1)
    # stratification : nombre entier par triangle + reste aleatoire (repartition plus uniforme)
    expect = area / area.sum() * n
    cnt = np.floor(expect).astype(np.int64)
    cnt += (rng.random(len(cnt)) < (expect - cnt)).astype(np.int64)
    ti = np.repeat(np.arange(len(cnt)), cnt)
    r1 = np.sqrt(rng.random(len(ti)))
    r2 = rng.random(len(ti))
    w0, w1, w2 = 1 - r1, r1 * (1 - r2), r1 * r2
    P = tri_pos[ti, 0] * w0[:, None] + tri_pos[ti, 1] * w1[:, None] + tri_pos[ti, 2] * w2[:, None]
    N = tri_nrm[ti, 0] * w0[:, None] + tri_nrm[ti, 1] * w1[:, None] + tri_nrm[ti, 2] * w2[:, None]
    N /= np.linalg.norm(N, axis=1, keepdims=True) + 1e-12
    return P, N, area.sum()


def perp_basis(N):
    up = np.where(np.abs(N[:, 2:3]) < 0.9, np.array([[0, 0, 1.0]]), np.array([[1.0, 0, 0]]))
    T = np.cross(N, up)
    T /= np.linalg.norm(T, axis=1, keepdims=True)
    B = np.cross(N, T)
    return T, B


def build_strands(P0, N, p, rng, area):
    n = len(P0)
    K = p["segs"] + 1
    t = np.linspace(0, 1, K)
    T, B = perp_basis(N)
    L = p["length"] * (1 + p["len_var"] * (rng.random(n) * 2 - 1))
    # direction : normale + inclinaison aleatoire
    ang = rng.random(n) * math.tau
    tilt = p["tilt"] * np.sqrt(rng.random(n))
    D = N + (T * np.cos(ang)[:, None] + B * np.sin(ang)[:, None]) * tilt[:, None]
    D /= np.linalg.norm(D, axis=1, keepdims=True)
    # courbure douce (arc) + frisure (bruit par point)
    ang2 = rng.random(n) * math.tau
    C = (T * np.cos(ang2)[:, None] + B * np.sin(ang2)[:, None])
    pts = (P0[:, None, :] + D[:, None, :] * (L[:, None] * t[None, :])[:, :, None]
           + C[:, None, :] * (p["curl"] * L[:, None] * t[None, :] ** 2)[:, :, None])
    fr = rng.normal(size=(n, K, 3)) * (p["frizz"] * 0.25 * L)[:, None, None]
    fr *= (t ** 1.3)[None, :, None]
    # pas de frisure le long de la normale (garde la longueur)
    fr -= (fr * N[:, None, :]).sum(-1, keepdims=True) * N[:, None, :] * 0.7
    pts += fr
    # mechage (clumping) : guides = sous-ensemble, chaque meche tire vers le guide le plus proche
    if p["clump"] > 0 and p["clump_n"] > 1:
        ng = max(1, n // p["clump_n"])
        gi = rng.choice(n, ng, replace=False)
        kd = KDTree(ng)
        for j, idx in enumerate(gi):
            kd.insert(P0[idx], j)
        kd.balance()
        near = np.empty(n, np.int64)
        for i in range(n):
            near[i] = kd.find(P0[i])[1]
        G = pts[gi[near]]
        # pas de mechage pour les racines trop eloignees (bords de clusters)
        dist = np.linalg.norm(P0 - P0[gi[near]], axis=1)
        cell = math.sqrt(area / ng)
        w = np.clip(1.4 - dist / cell, 0, 1)
        f = p["clump"] * w[:, None] * (t ** 1.6)[None, :]
        # le guide garde sa longueur : on tire en direction du guide (offset lateral seulement)
        off = (G - P0[gi[near]][:, None, :]) + P0[:, None, :] - pts
        pts = pts + off * f[:, :, None]
    rad = p["root_r"] + (p["tip_r"] - p["root_r"]) * t ** 0.8
    rad = np.broadcast_to(rad, (n, K))
    return pts, rad, L


def make_curves_object(name, pts, rad, mat):
    n, K, _ = pts.shape
    cu = bpy.data.hair_curves.new(name)
    cu.add_curves([K] * n)
    cu.position_data.foreach_set("vector", pts.astype(np.float32).ravel())
    ra = cu.attributes.get("radius") or cu.attributes.new("radius", "FLOAT", "POINT")
    ra.data.foreach_set("value", np.ascontiguousarray(rad, dtype=np.float32).ravel())
    cu.materials.append(mat)
    o = bpy.data.objects.new(name, cu)
    bpy.context.scene.collection.objects.link(o)
    return o


def grow_fur(obj, params, mat, blockers=(), seed_extra=0):
    t0 = time.time()
    rng = np.random.default_rng(params["seed"] + seed_extra)
    tp, tn = mesh_triangles_world(obj)
    a = tp[:, 1] - tp[:, 0]
    b = tp[:, 2] - tp[:, 0]
    area = 0.5 * np.linalg.norm(np.cross(a, b), axis=1).sum()
    n = int(area * params["density"])
    P0, N, area = sample_surface(tp, tn, n, rng)
    pts, rad, L = build_strands(P0, N, params, rng, area)
    keep = np.ones(len(P0), bool)
    if blockers:
        # raccourcit / supprime les poils qui traversent yeux, bouche, accessoires
        trees = []
        for bo in blockers:
            tp2, _ = mesh_triangles_world(bo)
            verts = tp2.reshape(-1, 3)
            polys = np.arange(len(verts)).reshape(-1, 3)
            trees.append((BVHTree.FromPolygons([tuple(v) for v in verts], polys.tolist(), epsilon=0.0),
                          verts.min(0) - 0.08, verts.max(0) + 0.08))
        K = pts.shape[1]
        nshort = 0
        for tree, lo, hi in trees:
            inside = np.all((P0 >= lo) & (P0 <= hi), axis=1)
            for i in np.nonzero(inside & keep)[0]:
                tip = pts[i, -1]
                d = Vector(tip - P0[i])
                ln = d.length
                hit = tree.ray_cast(Vector(P0[i]), d.normalized(), ln + 0.01)
                if hit[0] is not None:
                    h = hit[3]
                    s = (h - 0.004) / ln
                    if s < 0.25:
                        keep[i] = False
                    else:
                        pts[i] = P0[i] + (pts[i] - P0[i]) * s
                        nshort += 1
                    continue
                # racine a l'interieur du bloqueur (rayon partant de dedans)
                hit2 = tree.ray_cast(Vector(P0[i]) + Vector(N[i]) * 0.0005, Vector(-N[i]), 0.003)
                if hit2[0] is not None and Vector(hit2[1]).dot(Vector(N[i])) > 0:
                    keep[i] = False
        print("  fur blockers: removed %d, shortened %d" % ((~keep).sum(), nshort))
    pts, rad = pts[keep], rad[keep]
    o = make_curves_object(obj.name + "_fur", pts, rad, mat)
    print("  fur %s: %d strands (area %.3f) in %.1fs" % (obj.name, len(pts), area, time.time() - t0))
    return o


# ===========================================================================
# Rendu / sauvegarde
# ===========================================================================
def render_to(path):
    sc = bpy.context.scene
    sc.render.filepath = path
    t0 = time.time()
    bpy.ops.render.render(write_still=True)
    dt = time.time() - t0
    print("RENDERED %s in %.1fs" % (path, dt))
    TIMES[os.path.basename(path)] = round(dt, 1)
    return dt


TIMES = {}


def load_rgba(path):
    img = bpy.data.images.load(path, check_existing=False)
    w, h = img.size
    px = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(px)
    bpy.data.images.remove(img)
    return px.reshape(h, w, 4)


def save_rgba(arr, path):
    h, w, _ = arr.shape
    img = bpy.data.images.new("out", w, h, alpha=True)
    img.pixels.foreach_set(np.clip(arr, 0, 1).astype(np.float32).ravel())
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)


# ===========================================================================
# MATCAPS
# ===========================================================================
FUR_WHITE = srgb2lin("fcfbfa")
FUR_PINK = srgb2lin("ff3f7f")


def sphere(name, mat, r=1.0):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=192, ring_count=96, radius=r, location=(0, 0, 0))
    o = bpy.context.active_object
    o.name = name
    bpy.ops.object.shade_smooth()
    o.data.materials.append(mat)
    return o


def matcap(kind):
    reset()
    setup_cycles(512, MATCAP_SAMPLES)
    setup_rig()
    add_camera_ortho(2.0)
    if kind in ("fur", "fur_color"):
        col = FUR_WHITE if kind == "fur" else FUR_PINK
        # sous-poil : meme teinte, plus sombre (on ne voit jamais la "peau")
        base = principled("fur_base", tuple(c * 0.7 for c in col), rough=1.0, spec=0.1)
        s = sphere("sphere", base, 1.0)
        hm = hair_mat("fur_hair", fur_input(col), root_dark=0.15)
        grow_fur(s, FUR_SPHERE, hm)
        name = "fur_matcap.png" if kind == "fur" else "fur_matcap_color.png"
    elif kind == "gloss_black":
        sphere("sphere", gloss_black_mat())
        name = "gloss_black_matcap.png"
    elif kind == "gloss_white":
        sphere("sphere", gloss_white_mat())
        name = "gloss_white_matcap.png"
    elif kind == "felt":
        sphere("sphere", felt_mat())
        name = "felt_matcap.png"
    render_to(os.path.join(TEX_DIR, name))


def matcap_sheet():
    names = ["fur_matcap", "fur_matcap_color", "gloss_black_matcap", "gloss_white_matcap", "felt_matcap"]
    tile, pad = 512, 16
    W, H = 3 * tile + 4 * pad, 2 * tile + 3 * pad
    sheet = np.zeros((H, W, 4), np.float32)
    # fond damier gris pour voir l'alpha
    yy, xx = np.mgrid[0:H, 0:W]
    chk = ((xx // 32 + yy // 32) % 2).astype(np.float32)
    sheet[..., :3] = (0.36 + 0.06 * chk)[..., None]
    sheet[..., 3] = 1
    imgs = []
    for nm in names:
        p = os.path.join(TEX_DIR, nm + ".png")
        imgs.append(load_rgba(p) if os.path.exists(p) else None)
    # 6e tuile : fur_matcap x couleur mochi (simulation du jeu)
    if imgs[0] is not None:
        tint = np.array([int("ff5c8a"[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], np.float32)
        t = imgs[0].copy()
        t[..., :3] = t[..., :3] * tint
        imgs.append(t)
    for k, im in enumerate(imgs):
        if im is None:
            continue
        # pixels Blender : origine en bas a gauche -> rangee du haut = y eleve
        r, c = k // 3, k % 3
        y0 = H - (r + 1) * (tile + pad)
        x0 = pad + c * (tile + pad)
        a = im[..., 3:4]
        reg = sheet[y0:y0 + tile, x0:x0 + tile, :3]
        sheet[y0:y0 + tile, x0:x0 + tile, :3] = im[..., :3] * a + reg * (1 - a)
    save_rgba(sheet, os.path.join(PREV_DIR, "matcap_sheet.png"))
    print("WROTE matcap_sheet.png")


# ===========================================================================
# REFERENCES
# ===========================================================================
C_G2B = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))


def g2b(v):
    return Vector((v[0], -v[2], v[1]))


def godot_xform(basis_cols, pos, scale=1.0):
    """Transform Godot (colonnes X,Y,Z + position) -> matrice monde Blender pour un objet importe du glb."""
    X, Y, Z = [Vector(c) for c in basis_cols]
    G = Matrix(((X.x, Y.x, Z.x, pos[0]), (X.y, Y.y, Z.y, pos[1]), (X.z, Y.z, Z.z, pos[2]), (0, 0, 0, 1)))
    G = G @ Matrix.Diagonal((scale, scale, scale, 1))
    return C_G2B @ G @ C_G2B.inverted()


def basis_facing(n):
    z = Vector(n).normalized()
    x = Vector((0, 1, 0)).cross(z)
    x = Vector((1, 0, 0)) if x.length < 0.01 else x.normalized()
    y = z.cross(x).normalized()
    return x, y, z


def import_glb(fname):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(MODELS, fname))
    new = [o for o in bpy.data.objects if o not in before]
    roots = {o.name: o for o in new if o.parent is None}
    return roots, new


def delete_hier(root):
    for o in [root] + list(root.children_recursive):
        bpy.data.objects.remove(o, do_unlink=True)


def dup_hier(root, M):
    sc = bpy.context.scene

    def cp(o, parent):
        c = o.copy()
        sc.collection.objects.link(c)
        if parent is None:
            c.parent = None
            c.matrix_world = M
        else:
            c.parent = parent
            c.matrix_parent_inverse = o.matrix_parent_inverse.copy()
            c.matrix_basis = o.matrix_basis.copy()
        for ch in o.children:
            cp(ch, c)
        return c

    return cp(root, None)


def meshes_of(root):
    return [o for o in [root] + list(root.children_recursive) if o.type == "MESH"]


PALETTE = {
    "blanc": "f7f4ee", "noir": "232027", "gris": "9a98a3", "rouge": "e5484d", "corail": "ff7f6e",
    "orange": "ff9f43", "jaune": "ffd23f", "vert": "5cc46b", "menthe": "7ee0c3", "ciel": "7cc8ff",
    "bleu": "3d6fe0", "violet": "9b5de5", "rose": "ff7eb3", "marron": "9c6644",
}


def face_mats():
    return {
        "eye_black": principled("r_eye_black", srgb2lin("0b0a0e"), rough=0.16, coat=1.0, coat_rough=0.05),
        "eye_white": principled("r_eye_white", srgb2lin("fbfbfd"), rough=0.3, coat=0.6, coat_rough=0.1),
        "glint": principled("r_glint", (1, 1, 1), rough=0.5, emit=3.0),
        "iris": principled("r_iris", srgb2lin("6fb1f2"), rough=0.2, coat=1.0),
        "tongue": principled("r_tongue", srgb2lin("ff7a8e"), rough=0.35, coat=0.5),
        "tooth": principled("r_tooth", srgb2lin("fff8ea"), rough=0.25, coat=0.6),
        "mouth_inside": principled("r_mouth_inside", srgb2lin("5c1a1f"), rough=0.5),
        "beak": principled("r_beak", srgb2lin("ffa62b"), rough=0.3, coat=0.8),
    }


def assign_mats(objs, table):
    for o in objs:
        if o.type != "MESH":
            continue
        for slot in o.material_slots:
            if slot.material is None:
                continue
            key = slot.material.name.split(".")[0]
            if key in table:
                slot.link = "OBJECT"
                slot.material = table[key]


REFS = {
    "mochi": dict(fur="ff5c8a", bg="f3e6fb", eyes="arc", mouth="mouth_smile", acc="headphones",
                  file="ref_mochi_headphones.png"),
    "nuage": dict(fur="6fb1f2", bg="fdeedd", eyes="eye_dot", mouth="mouth_smile", acc="beret",
                  file="ref_nuage_beret.png"),
    "coco": dict(fur="b04fc4", bg="e2f6ec", eyes="eye_dot", mouth="mouth_smile", acc="round_glasses",
                 file="ref_coco_sunglasses.png"),
    "kiwi": dict(fur="a8d94a", bg="e4f0fb", eyes="eye_googly", mouth="mouth_smile", acc=None,
                 file="ref_kiwi.png"),
}


def reference(sid):
    cfg = REFS[sid]
    a = SPECIES[sid]
    reset()
    setup_cycles(512, REF_SAMPLES)
    setup_rig()
    # --- corps
    roots, _ = import_glb("bodies.glb")
    body = roots["body_" + sid]
    for nm, o in roots.items():
        if o is not body:
            delete_hier(o)
    fur_col = srgb2lin(cfg["fur"])
    body.data.materials.clear()
    body.data.materials.append(principled("fur_base", tuple(c * 0.5 for c in fur_col), rough=1.0, spec=0.1))
    # --- visage
    fm = face_mats()
    froots, _ = import_glb("face.glb")
    face_objs = []
    for side in ("l", "r"):
        n = (Vector(a["eye_" + side + "_n"]) + Vector((0, 0, 1.3))).normalized()
        p = Vector(a["eye_" + side]) + n * 0.03
        M = godot_xform(basis_facing(n), p)
        src = froots["eye_arc"] if cfg["eyes"] == "arc" else froots[cfg["eyes"]]
        face_objs.append(dup_hier(src, M))
    n = (Vector(a["mouth_n"]) + Vector((0, 0, 1.0))).normalized()
    p = Vector(a["mouth"]) + n * 0.03
    face_objs.append(dup_hier(froots[cfg["mouth"]], godot_xform(basis_facing(n), p)))
    for o in froots.values():
        delete_hier(o)
    face_meshes = [m for r in face_objs for m in meshes_of(r)]
    assign_mats(face_meshes, fm)
    # --- accessoire
    acc_meshes = []
    if cfg["acc"]:
        aroots, _ = import_glb("accessories.glb")
        acc = cfg["acc"]
        hat = Vector(a["hat"])
        if acc == "beret":
            up = (Vector(a["hat_n"]) * 0.6 + Vector((0, 1, 0)) * 0.4).normalized()
            X = up.cross(Vector((0, 0, 1))).normalized()
            Z = X.cross(up).normalized()
            pos = hat + up * 0.05 * 0.4 - up * 0.02
            M = godot_xform((X, up, Z), pos, a["hat_width"] / 0.6)
            table = {"main": felt_mat("r_felt_black", srgb2lin("1e1c22")),
                     "accent": felt_mat("r_felt_red", srgb2lin(PALETTE["rouge"])),
                     "detail": principled("r_thread", srgb2lin(PALETTE["blanc"]), rough=0.8)}
        elif acc == "headphones":
            s = (a["ear_width"] * 0.5 + 0.05 + 0.03) / 0.38
            pos = hat + Vector((0, 1, 0)) * 0.025
            M = godot_xform(((1, 0, 0), (0, 1, 0), (0, 0, 1)), pos, s)
            table = {"main": gloss_black_mat("r_gloss_black"),
                     "accent": principled("r_cushion_leather", srgb2lin("1c1a1f"), rough=0.42, coat=0.3,
                                          coat_rough=0.3, sheen=0.3),
                     "detail": gloss_white_mat("r_gloss_white"),
                     "glow": principled("r_led", srgb2lin(PALETTE["rose"]), rough=0.3, emit=2.0),
                     "black": principled("r_cushion", srgb2lin("1a181d"), rough=0.6, sheen=0.6, spec=0.3),
                     "silver": principled("r_silver", srgb2lin("c9ced6"), metal=1.0, rough=0.25),
                     "fur_main": felt_mat("r_cush_felt", srgb2lin("1e1c22")),
                     "fur_accent": felt_mat("r_cush_felt2", srgb2lin("1e1c22"))}
        else:  # lunettes
            s = (a["eye_r"][0] - a["eye_l"][0]) / 0.32
            if a.get("eye_style") == "googly":
                s *= 1.15
            s = min(s, 1.25)
            pos = (Vector(a["eye_l"]) + Vector(a["eye_r"])) / 2 + Vector((0, 0, 0.05 + 0.05))
            M = godot_xform(((1, 0, 0), (0, 1, 0), (0, 0, 1)), pos, s)
            dark = principled("r_lens", srgb2lin("15131a"), rough=0.05, coat=1.0, coat_rough=0.02, spec=0.6)
            table = {"main": gloss_black_mat("r_gloss_black"), "accent": gloss_black_mat("r_gloss_black2"),
                     "detail": principled("r_gold", srgb2lin("f2b84b"), metal=1.0, rough=0.28),
                     "clear_glass": dark, "glass": dark,
                     "white": principled("r_glint_w", (1, 1, 1), rough=0.3, emit=1.5),
                     "silver": principled("r_silver", srgb2lin("c9ced6"), metal=1.0, rough=0.25),
                     "gold": principled("r_gold2", srgb2lin("f2b84b"), metal=1.0, rough=0.28)}
        inst = dup_hier(aroots[acc], M)
        for o in aroots.values():
            delete_hier(o)
        acc_meshes = meshes_of(inst)
        assign_mats(acc_meshes, table)
    bpy.context.view_layer.update()
    # --- duvet du feutre (beret) : tres court, sombre
    if cfg["acc"] == "beret":
        fz = hair_mat("felt_fuzz", srgb2lin("2a272e"), rough=0.5, radial=0.9)
        for m in acc_meshes:
            if m.name.startswith("beret_body") or m.name.startswith("beret_band"):
                grow_fur(m, FUR_FELT, fz if m.name.startswith("beret_body") else
                         hair_mat("felt_fuzz_r", srgb2lin(PALETTE["rouge"]), rough=0.5, radial=0.9))
    # --- fourrure
    hm = hair_mat("fur_hair_" + sid, fur_input(fur_col), root_dark=0.15)
    grow_fur(body, FUR_BODY, hm, blockers=face_meshes + acc_meshes)
    # --- ombre de contact (shadow catcher) + camera
    bpy.ops.mesh.primitive_plane_add(size=6, location=(0, 0, 0))
    pl = bpy.context.active_object
    pl.is_shadow_catcher = True
    top = a["height"] + {"beret": 0.17, "headphones": 0.05}.get(cfg["acc"], 0.0)
    add_camera_persp(target_z=top * 0.5 + 0.01, dist=2.3, lens=50, eye_z=top * 0.85)
    tmp = os.path.join(PREV_DIR, "_tmp_" + sid + ".png")
    render_to(tmp)
    # composition sur fond pastel uni
    im = load_rgba(tmp)
    os.remove(tmp)
    bgc = np.array([int(cfg["bg"][i:i + 2], 16) / 255.0 for i in (0, 2, 4)], np.float32)
    al = im[..., 3:4]
    out = np.ones_like(im)
    out[..., :3] = im[..., :3] * al + bgc * (1 - al)
    save_rgba(out, os.path.join(PREV_DIR, cfg["file"]))
    TIMES[cfg["file"]] = TIMES.pop(os.path.basename(tmp))
    print("WROTE", cfg["file"])


# ===========================================================================
T_ALL = time.time()
for job in TODO:
    print("=== JOB", job)
    if job == "rig":
        write_rig_json()
    elif job in GROUPS["matcaps"]:
        matcap(job)
    elif job == "sheet":
        matcap_sheet()
    elif job in REFS:
        reference(job)
    else:
        print("unknown target", job)
print("TIMES", json.dumps(TIMES))
print("TOTAL %.1fs" % (time.time() - T_ALL))
