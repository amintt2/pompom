"""
Pompom - lookdev Cycles des matieres TRANSPARENTES (gelee, slime, verre) et opaques (pate, chrome,
plastique, bois) : environment matting (Zongker et al. 1999), matcaps et rendus de reference.

Lancement (headless) :
    blender --background --factory-startup --python blender/render_materials.py -- [cibles] [cle=valeur ...]

Cibles (defaut : all) :
    backdrop                        blender/previews/backdrop.png (faux bureau colore, 1024x1024)
    env_gelee env_slime env_verre   cartes d'environment matting -> godot/assets/textures/mat_<m>_*.png
    mc_pate mc_pate_color mc_chrome mc_plastique mc_bois   matcaps opaques
    ref_gelee ref_slime ref_verre ref_pate ref_chrome ref_plastique ref_bois   rendus de reference
    sheet                           planche blender/previews/mat_sheet.png
    json                            godot/data/materials_lookdev.json
    envs / matcaps / refs / all     groupes
Options : self_samples=N code_samples=N mc_samples=N ref_samples=N cpu=0 (GPU HIP ; CPU par defaut)

Conventions : Blender Z = haut, -Y = avant (camera en -Y, regarde +Y). Le rig studio (lumieres + ciel)
est relu depuis godot/data/studio_rig.json (genere par render_lookdev.py) : eclairage identique.
"""
import bpy
import json
import math
import os
import struct
import sys
import time
import zlib

import numpy as np
from mathutils import Matrix, Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS = os.path.join(ROOT, "godot", "assets", "models")
TEX_DIR = os.path.join(ROOT, "godot", "assets", "textures")
PREV_DIR = os.path.join(ROOT, "blender", "previews")
OUT_JSON = os.path.join(ROOT, "godot", "data", "materials_lookdev.json")
RIG = json.load(open(os.path.join(ROOT, "godot", "data", "studio_rig.json"), encoding="utf-8"))
SPECIES = json.load(open(os.path.join(ROOT, "godot", "data", "species.json"), encoding="utf-8"))
BACKDROP = os.path.join(PREV_DIR, "backdrop.png")
TMP = os.environ.get("POMPOM_TMP") or os.path.join(os.environ.get("TEMP", ROOT), "pompom_mat_tmp")
os.makedirs(TMP, exist_ok=True)
os.makedirs(TEX_DIR, exist_ok=True)
os.makedirs(PREV_DIR, exist_ok=True)

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OPTS = dict(a.split("=", 1) for a in ARGS if "=" in a)
TARGETS = [a for a in ARGS if "=" not in a] or ["all"]
TRANSP = ["gelee", "slime", "verre"]
OPAQUE = ["pate", "chrome", "plastique", "bois"]
GROUPS = {
    "envs": ["env_" + m for m in TRANSP],
    "matcaps": ["mc_pate", "mc_pate_color", "mc_chrome", "mc_plastique", "mc_bois"],
    "refs": ["ref_" + m for m in TRANSP + OPAQUE],
}
GROUPS["all"] = ["backdrop"] + GROUPS["envs"] + GROUPS["matcaps"] + ["sheet"] + GROUPS["refs"] + ["json"]
TODO = []
for t in TARGETS:
    for x in GROUPS.get(t, [t]):
        if x not in TODO:
            TODO.append(x)

SELF_SAMPLES = int(OPTS.get("self_samples", 1024))
CODE_SAMPLES = int(OPTS.get("code_samples", 2048))
MC_SAMPLES = int(OPTS.get("mc_samples", 512))
REF_SAMPLES = int(OPTS.get("ref_samples", 768))
FORCE_CPU = OPTS.get("cpu", "1") == "1"  # CPU par defaut (GPU HIP : gpu=... cpu=0)
RES = 512

# --- environment matting : geometrie fixe (documentee dans materials_lookdev.json)
# density_scale : la sphere (rayon 1) represente un compagnon de rayon ~0.5 agrandi x2 -> coefficients
# volumiques x0.5 pour que l'epaisseur optique corresponde au vrai compagnon (~1 unite d'epaisseur).
ENV = dict(sphere_radius=1.0, ortho_scale=2.0, plane_y=2.0, plane_half=6.0, resolution=RES, density_scale=0.5)
GT_SAMPLES = int(OPTS.get("gt_samples", 256))
# --- rendu de reference (le jeu doit reproduire exactement ce cadrage)
REF = dict(cam_loc=(0.0, -6.0, 0.55), fov_v_deg=24.0, res=600, plane_y=0.62, plane_center=(0.0, 0.62, 0.55),
           plane_size=6.0)
# zone du plan (x,z) couverte par backdrop.png dans le controle de reconstruction de la sphere
CHECK_TEX = dict(x0=-2.0, z0=-2.0, size=4.0)


def srgb2lin(h):
    h = h.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


def lin2srgb_np(x):
    x = np.clip(x, 0, None)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(x, 1 / 2.4) - 0.055)


def srgb2lin_np(x):
    return np.where(x <= 0.04045, x / 12.92, np.power((x + 0.055) / 1.055, 2.4))


# ===========================================================================
# PNG (8/16 bits) ecrit a la main : valeurs brutes, aucune gestion de couleur implicite.
# arr : (H, W, C) float 0..1, convention Blender (rangee 0 = BAS) -> retournee a l'ecriture.
# ===========================================================================
def write_png(path, arr, bits=16):
    arr = np.ascontiguousarray(arr[::-1])
    h, w, c = arr.shape
    ct = {1: 0, 2: 4, 3: 2, 4: 6}[c]
    if bits == 16:
        data = (np.clip(arr, 0, 1) * 65535 + 0.5).astype(">u2")
    else:
        data = (np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8)
    data = data.reshape(h, w * c)
    raw = np.concatenate([np.zeros((h, 1), data.dtype), data], axis=1) if bits == 8 else None
    if bits == 16:
        rows = data.view(np.uint8).reshape(h, -1)
        raw = np.concatenate([np.zeros((h, 1), np.uint8), rows], axis=1)
    raw = raw.astype(np.uint8).tobytes()

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, bits, ct, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)
    print("WROTE", path)


def load_pixels(path):
    """Pixels bruts (float) d'une image ; EXR = lineaire scene ; PNG 8 bits = valeurs encodees."""
    img = bpy.data.images.load(path, check_existing=False)
    w, h = img.size
    px = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(px)
    bpy.data.images.remove(img)
    return px.reshape(h, w, 4)


# ===========================================================================
# Scene / Cycles
# ===========================================================================
def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


DEVICE = ["CPU"]


def setup_cycles(res_x, res_y, samples, denoise=True, adaptive=True, caustics=False):
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
    DEVICE[0] = dev
    cy.samples = samples
    cy.seed = 0
    cy.use_animated_seed = False
    cy.use_adaptive_sampling = adaptive
    cy.adaptive_threshold = 0.006
    cy.adaptive_min_samples = 64
    cy.use_denoising = denoise
    cy.denoiser = "OPENIMAGEDENOISE"
    try:
        cy.denoising_input_passes = "RGB_ALBEDO_NORMAL"
        cy.denoising_prefilter = "ACCURATE"
        cy.denoising_quality = "HIGH"
        cy.denoising_use_gpu = dev == "GPU"
    except Exception:
        pass
    cy.max_bounces = 32
    cy.diffuse_bounces = 4
    cy.glossy_bounces = 32
    cy.transmission_bounces = 32
    cy.volume_bounces = 12
    cy.transparent_max_bounces = 16
    cy.sample_clamp_direct = 0.0
    cy.sample_clamp_indirect = 0.0
    cy.blur_glossy = float(OPTS.get("blur_glossy", 0.3))
    cy.caustics_reflective = caustics
    cy.caustics_refractive = caustics
    try:
        cy.volume_step_rate = 1.0
    except Exception:
        pass
    sc.render.resolution_x = res_x
    sc.render.resolution_y = res_y
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    sc.render.filter_size = 1.2
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.render.image_settings.color_depth = "8"
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    sc.view_settings.exposure = 0.0
    sc.view_settings.gamma = 1.0
    try:
        sc.display_settings.display_device = "sRGB"
    except Exception:
        pass


def setup_world(lit=True):
    """Ciel degrade du rig studio (identique a render_lookdev.py). lit=False : monde noir."""
    sc = bpy.context.scene
    w = bpy.data.worlds.new("studio" if lit else "black")
    sc.world = w
    try:
        w.use_nodes = True
    except Exception:
        pass
    nt = w.node_tree
    nt.nodes.clear()
    bg = nt.nodes.new("ShaderNodeBackground")
    out = nt.nodes.new("ShaderNodeOutputWorld")
    nt.links.new(bg.outputs[0], out.inputs[0])
    if not lit:
        bg.inputs["Color"].default_value = (0, 0, 0, 1)
        bg.inputs["Strength"].default_value = 0.0
        return
    amb = RIG["ambient"]
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    mr = nt.nodes.new("ShaderNodeMapRange")
    nt.links.new(tc.outputs["Generated"], sep.inputs[0])
    nt.links.new(sep.outputs["Z"], mr.inputs["Value"])
    mr.inputs["From Min"].default_value = -1.0
    mr.inputs["From Max"].default_value = 1.0
    nt.links.new(mr.outputs["Result"], ramp.inputs["Fac"])
    els = ramp.color_ramp.elements
    els[0].position = 0.0
    els[0].color = (*amb["sky_ground"], 1)
    els[1].position = 1.0
    els[1].color = (*amb["sky_top"], 1)
    e = els.new(0.5)
    e.color = (*amb["sky_horizon"], 1)
    ramp.color_ramp.interpolation = "EASE"
    nt.links.new(ramp.outputs["Color"], bg.inputs["Color"])
    lp = nt.nodes.new("ShaderNodeLightPath")
    mr2 = nt.nodes.new("ShaderNodeMapRange")
    nt.links.new(lp.outputs["Is Glossy Ray"], mr2.inputs["Value"])
    mr2.inputs["To Min"].default_value = amb["sky_strength"]
    mr2.inputs["To Max"].default_value = amb["sky_strength"] * amb["sky_specular_factor"]
    nt.links.new(mr2.outputs["Result"], bg.inputs["Strength"])


def setup_lights():
    sc = bpy.context.scene
    objs = []
    for L in RIG["lights"]:
        ld = bpy.data.lights.new(L["name"], "SUN")
        ld.energy = L["energy"]
        ld.color = L["color"]
        ld.angle = math.radians(L["softness_deg"])
        o = bpy.data.objects.new(L["name"], ld)
        sc.collection.objects.link(o)
        d = Vector(L["direction_blender_world"]).normalized()
        o.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
        o.visible_camera = False
        objs.append(o)
    return objs


def setup_rig(lit=True):
    setup_world(lit)
    return setup_lights() if lit else []


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


def add_camera_ref():
    sc = bpy.context.scene
    cd = bpy.data.cameras.new("cam")
    cd.sensor_fit = "VERTICAL"
    cd.sensor_height = 24.0
    cd.sensor_width = 24.0
    cd.lens_unit = "FOV"
    cd.angle_y = math.radians(REF["fov_v_deg"])
    cd.clip_start = 0.05
    cd.clip_end = 100
    cam = bpy.data.objects.new("cam", cd)
    sc.collection.objects.link(cam)
    cam.location = REF["cam_loc"]
    cam.rotation_euler = (math.pi / 2, 0, 0)
    sc.camera = cam
    return cam


# ===========================================================================
# Materiaux : utilitaires
# ===========================================================================
def new_mat(name):
    m = bpy.data.materials.new(name)
    try:
        m.use_nodes = True
    except Exception:
        pass
    return m


def principled(name, col, rough=0.5, coat=0.0, coat_rough=0.05, sheen=0.0, sheen_rough=0.5, spec=0.5,
               metal=0.0, emit=0.0):
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
    return m


def node(nt, kind, **inputs):
    n = nt.nodes.new(kind)
    for k, v in inputs.items():
        n.inputs[k].default_value = v
    return n


def emission_mat(name, col, strength=1.0):
    m = new_mat(name)
    nt = m.node_tree
    nt.nodes.clear()
    e = node(nt, "ShaderNodeEmission", Color=(*col, 1), Strength=strength)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(e.outputs[0], out.inputs["Surface"])
    no_emission_sampling(m)
    return m


def no_emission_sampling(m):
    for tgt in (m, getattr(m, "cycles", None)):
        if tgt is not None and hasattr(tgt, "emission_sampling"):
            tgt.emission_sampling = "NONE"
            return


def volume_nodes(nt, sigma_a=(0, 0, 0), sigma_s=0.0, scat_col=(1, 1, 1), aniso=0.0):
    """Volume homogene : absorption sigma_a (par unite, par canal) + diffusion sigma_s * scat_col."""
    shaders = []
    D = max(sigma_a)
    if D > 1e-6:
        col = tuple(1.0 - s / D for s in sigma_a)
        shaders.append(node(nt, "ShaderNodeVolumeAbsorption", Color=(*col, 1), Density=D))
    if sigma_s > 1e-6:
        sc = node(nt, "ShaderNodeVolumeScatter", Color=(*scat_col, 1), Density=sigma_s, Anisotropy=aniso)
        shaders.append(sc)
    if not shaders:
        return None
    if len(shaders) == 1:
        return shaders[0]
    add = nt.nodes.new("ShaderNodeAddShader")
    nt.links.new(shaders[0].outputs[0], add.inputs[0])
    nt.links.new(shaders[1].outputs[0], add.inputs[1])
    return add


def sigma_from_color(hexcol, thickness):
    """Coefficient d'absorption (Beer-Lambert) tel que la transmittance a `thickness` unites = couleur."""
    c = srgb2lin(hexcol)
    return tuple(-math.log(max(x, 1e-4)) / thickness for x in c)


def bump_chain(nt, specs, strength_scale=1.0):
    """specs : liste de (type, scale, strength, distance, extra) ; renvoie la sortie Normal chainee."""
    tc = nt.nodes.new("ShaderNodeTexCoord")
    prev = None
    for kind, scale, strength, dist, extra in specs:
        if kind == "noise":
            t = node(nt, "ShaderNodeTexNoise", Scale=scale, Detail=extra.get("detail", 4.0),
                     Roughness=extra.get("rough", 0.5))
            nt.links.new(tc.outputs["Object"], t.inputs["Vector"])
            h = t.outputs["Fac"]
        else:  # voronoi : petites alveoles (F1 distance, inverse)
            t = nt.nodes.new("ShaderNodeTexVoronoi")
            t.feature = "SMOOTH_F1" if extra.get("smooth") else "F1"
            t.inputs["Scale"].default_value = scale
            if "Randomness" in t.inputs:
                t.inputs["Randomness"].default_value = 1.0
            nt.links.new(tc.outputs["Object"], t.inputs["Vector"])
            h = t.outputs["Distance"]
        b = node(nt, "ShaderNodeBump", Strength=strength * strength_scale, Distance=dist)
        if extra.get("invert"):
            b.invert = True
        nt.links.new(h, b.inputs["Height"])
        if prev is not None:
            nt.links.new(prev, b.inputs["Normal"])
        prev = b.outputs["Normal"]
    return prev


# ===========================================================================
# Materiaux transparents
# variant : "neutral" (teinte quasi blanche, pour les cartes / teinte de jeu) ou "color"
# opts : absorb=True/False (thickness pass : remplace le volume par une absorption grise pure)
# ===========================================================================
TRANSP_CFG = {
    "gelee": dict(ior=1.38, rough=0.01, color_hex="ff4f86", color_thickness=1.0,
                  neutral_sigma=(0.06, 0.06, 0.06), scatter=0.12, scatter_aniso=0.25, coat=0.0),
    "slime": dict(ior=1.34, rough=0.06, color_hex="8ef25c", color_thickness=1.0,
                  neutral_sigma=(0.05, 0.05, 0.05), scatter=3.0, scatter_aniso=0.45, coat=1.0),
    "verre": dict(ior=1.5, rough=0.0, color_hex=None, color_thickness=1.0,
                  neutral_sigma=(0.0, 0.0, 0.0), scatter=0.0, scatter_aniso=0.0, coat=0.0,
                  dispersion=(1.488, 1.500, 1.518)),
}


def transparent_mat(kind, variant="neutral", vol_override=None, density=1.0):
    cfg = dict(TRANSP_CFG[kind])
    for k in list(cfg):  # surcharges en ligne de commande (essais) : ex. slime.scatter=2
        if "%s.%s" % (kind, k) in OPTS:
            cfg[k] = type(cfg[k])(float(OPTS["%s.%s" % (kind, k)]))
    m = new_mat("%s_%s" % (kind, variant))
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    if kind == "verre":
        # dispersion : 3 Glass BSDF (R, G, B) a IOR differents (Abbe ~ 45)
        add1 = nt.nodes.new("ShaderNodeAddShader")
        add2 = nt.nodes.new("ShaderNodeAddShader")
        gl = []
        for col, ior in zip(((1, 0, 0), (0, 1, 0), (0, 0, 1)), cfg["dispersion"]):
            g = nt.nodes.new("ShaderNodeBsdfGlass")
            g.distribution = "MULTI_GGX"
            g.inputs["Color"].default_value = (*col, 1)
            g.inputs["IOR"].default_value = ior
            g.inputs["Roughness"].default_value = cfg["rough"]
            gl.append(g)
        nt.links.new(gl[0].outputs[0], add1.inputs[0])
        nt.links.new(gl[1].outputs[0], add1.inputs[1])
        nt.links.new(add1.outputs[0], add2.inputs[0])
        nt.links.new(gl[2].outputs[0], add2.inputs[1])
        nt.links.new(add2.outputs[0], out.inputs["Surface"])
        sigma = cfg["neutral_sigma"]
        scat = 0.0
    else:
        b = nt.nodes.new("ShaderNodeBsdfPrincipled")
        b.inputs["Base Color"].default_value = (1, 1, 1, 1)
        b.inputs["Transmission Weight"].default_value = 1.0
        b.inputs["IOR"].default_value = cfg["ior"]
        b.inputs["Roughness"].default_value = cfg["rough"]
        b.inputs["Specular IOR Level"].default_value = 0.5
        if cfg["coat"]:
            b.inputs["Coat Weight"].default_value = cfg["coat"]
            b.inputs["Coat Roughness"].default_value = 0.02
            b.inputs["Coat IOR"].default_value = 1.4
        if kind == "slime":
            # ondulations douces de surface (slime) + micro-relief tres fin
            nrm = bump_chain(nt, [("noise", 2.2, 0.22, 0.06, dict(detail=2.0, rough=0.45)),
                                  ("noise", 14.0, 0.05, 0.01, dict(detail=3.0))])
            nt.links.new(nrm, b.inputs["Normal"])
            if cfg["coat"]:
                nt.links.new(nrm, b.inputs["Coat Normal"])
        nt.links.new(b.outputs[0], out.inputs["Surface"])
        if variant == "color":
            sigma = sigma_from_color(cfg["color_hex"], cfg["color_thickness"])
        else:
            sigma = cfg["neutral_sigma"]
        scat = cfg["scatter"]
    scat_col = (1, 1, 1)
    if kind == "slime" and variant == "color":
        c = srgb2lin(cfg["color_hex"])
        mixk = float(OPTS.get("slime.scatmix", 1.0))
        scat_col = tuple(1 - mixk + mixk * x for x in c)
    sigma = tuple(x * density for x in sigma)
    scat = scat * density
    if vol_override is not None:  # passes d'epaisseur / balistique : absorption pure (deja a l'echelle)
        sigma, scat = vol_override, 0.0
    v = volume_nodes(nt, sigma, scat, scat_col, cfg["scatter_aniso"])
    if v is not None:
        nt.links.new(v.outputs[0], out.inputs["Volume"])
    try:
        m.cycles.homogeneous_volume = True
    except Exception:
        pass
    return m


# ===========================================================================
# Materiaux opaques
# ===========================================================================
PATE = dict(neutral_base=(0.80, 0.795, 0.785), color_hex="f1d6a8", radius_color=(1.0, 0.6, 0.35),
            radius_neutral=(1.0, 0.9, 0.8), sss_scale=0.03, rough=0.42, flour_rough=0.95, sheen=0.3,
            sheen_rough=0.3, spec=0.5, flour_max=0.95)


def pate_mat(variant="neutral"):
    """Pate a pain crue : SSS chaud (random walk), satinee, bosses molles + pores + grain, poudrage de
    farine fin (speckles concentres par zones)."""
    P = PATE
    m = new_mat("pate_" + variant)
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    b = nt.nodes.new("ShaderNodeBsdfPrincipled")
    b.subsurface_method = "RANDOM_WALK"
    if variant == "color":
        base = srgb2lin(P["color_hex"])
        radius = P["radius_color"]
        flour = tuple(min(1.0, 0.25 + 0.8 * c) for c in base)  # farine sur pate doree : plus clair/blanc
        flour = tuple(0.5 * f + 0.5 * 0.93 for f in flour)
    else:
        base = P["neutral_base"]
        radius = P["radius_neutral"]
        flour = (0.93, 0.93, 0.925)
    tc = nt.nodes.new("ShaderNodeTexCoord")

    def noise(scale, detail=4.0, rough=0.5):
        n = node(nt, "ShaderNodeTexNoise", Scale=scale, Detail=detail, Roughness=rough)
        nt.links.new(tc.outputs["Object"], n.inputs["Vector"])
        return n.outputs["Fac"]

    def remap(sock, a, b_, lo=0.0, hi=1.0):
        r = nt.nodes.new("ShaderNodeMapRange")
        r.inputs["From Min"].default_value = a
        r.inputs["From Max"].default_value = b_
        r.inputs["To Min"].default_value = lo
        r.inputs["To Max"].default_value = hi
        nt.links.new(sock, r.inputs["Value"])
        return r.outputs["Result"]

    def math(op, x, y):
        n = node(nt, "ShaderNodeMath")
        n.operation = op
        for i, v in enumerate((x, y)):
            if isinstance(v, (int, float)):
                n.inputs[i].default_value = v
            else:
                nt.links.new(v, n.inputs[i])
        return n.outputs[0]

    # zones farinees (basse frequence) x poussiere fine (haute frequence) + voile leger
    zones = remap(noise(2.2, 3.0, 0.55), 0.36, 0.66)
    dust = remap(noise(120.0, 3.0, 0.65), 0.44, 0.62)
    speck = math("MULTIPLY", zones, dust)
    veil = math("MULTIPLY", zones, 0.35)
    fl = math("MULTIPLY", math("MAXIMUM", speck, veil), P["flour_max"])
    mixc = nt.nodes.new("ShaderNodeMix")
    mixc.data_type = "RGBA"
    mixc.inputs["A"].default_value = (*base, 1)
    mixc.inputs["B"].default_value = (*flour, 1)
    nt.links.new(fl, mixc.inputs["Factor"])
    nt.links.new(mixc.outputs["Result"], b.inputs["Base Color"])
    nt.links.new(remap(fl, 0.0, 1.0, P["rough"], P["flour_rough"]), b.inputs["Roughness"])
    b.inputs["Subsurface Weight"].default_value = 1.0
    b.inputs["Subsurface Radius"].default_value = radius
    b.inputs["Subsurface Scale"].default_value = P["sss_scale"]
    if "Subsurface IOR" in b.inputs:
        b.inputs["Subsurface IOR"].default_value = 1.4
    b.inputs["Specular IOR Level"].default_value = P["spec"]
    b.inputs["IOR"].default_value = 1.42
    b.inputs["Sheen Weight"].default_value = P["sheen"]
    b.inputs["Sheen Roughness"].default_value = P["sheen_rough"]
    b.inputs["Sheen Tint"].default_value = (1, 1, 1, 1)
    # relief : bosses molles + petits pores (bulles de fermentation) + grain fin
    nrm = bump_chain(nt, [("noise", 2.4, 0.6, 0.08, dict(detail=3.0, rough=0.5)),
                          ("voronoi", 30.0, 0.55, 0.012, dict(smooth=True)),
                          ("noise", 110.0, 0.3, 0.003, dict(detail=3.0, rough=0.6))])
    nt.links.new(nrm, b.inputs["Normal"])
    nt.links.new(b.outputs[0], out.inputs["Surface"])
    return m



def chrome_mat():
    return principled("chrome", (0.93, 0.93, 0.95), rough=0.035, metal=1.0)


def plastique_mat(col=(0.86, 0.86, 0.86)):
    m = principled("plastique", col, rough=0.32, coat=0.85, coat_rough=0.05, spec=0.5)
    b = m.node_tree.nodes.get("Principled BSDF")
    b.subsurface_method = "RANDOM_WALK"
    b.inputs["Subsurface Weight"].default_value = 0.12
    b.inputs["Subsurface Radius"].default_value = (1.0, 0.9, 0.8)
    b.inputs["Subsurface Scale"].default_value = 0.03
    return m


BOIS_HEX = "8a5a36"


def bois_mat():
    # vernis : coat epais tres lisse sur un bois satine
    return principled("bois", srgb2lin(BOIS_HEX), rough=0.5, coat=1.0, coat_rough=0.03, spec=0.4)


def opaque_mat(kind, variant="neutral"):
    if kind == "pate":
        return pate_mat(variant)
    if kind == "chrome":
        return chrome_mat()
    if kind == "plastique":
        return plastique_mat()
    if kind == "bois":
        return bois_mat()
    raise ValueError(kind)


# ===========================================================================
# Geometrie
# ===========================================================================
def sphere(name, mat, r=1.0):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=7, radius=r, location=(0, 0, 0))
    o = bpy.context.active_object
    o.name = name
    bpy.ops.object.shade_smooth()
    o.data.materials.append(mat)
    return o


def set_vis(o, camera=True, diffuse=True, glossy=True, transmission=True, volume=True, shadow=True):
    o.visible_camera = camera
    o.visible_diffuse = diffuse
    o.visible_glossy = glossy
    o.visible_transmission = transmission
    o.visible_volume_scatter = volume
    o.visible_shadow = shadow


def env_plane(mode, y, half, z_center=0.0, primary_only=False):
    """Plan emissif non eclaire, face a la camera. mode :
       ('const', v)  emission grise v
       'u' / 'v'     code de position (x+6)/12 / (z+6)/12 (gris)
       'q'           (x^2 + z^2) / 72 (gris) : second moment pour l'etalement
       ('tex', path, x0, z0, size)  image (sRGB) sur [x0,x0+size] x [z0,z0+size]"""
    bpy.ops.mesh.primitive_plane_add(size=2 * half, location=(0, y, z_center))
    pl = bpy.context.active_object
    pl.name = "env_plane"
    pl.rotation_euler = (math.pi / 2, 0, 0)
    m = new_mat("env_plane_mat")
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Strength"].default_value = 1.0
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    if primary_only:
        # seuls les chemins camera -> refraction entree -> refraction sortie -> plan (Ray Depth == 2) ;
        # exclut le reflet externe (depth 1, qui touche le fond loin sur le cote aux incidences > 45 deg),
        # les reflexions internes et la diffusion (depth >= 3)
        lp = nt.nodes.new("ShaderNodeLightPath")
        cmp = node(nt, "ShaderNodeMath")
        cmp.operation = "COMPARE"
        nt.links.new(lp.outputs["Ray Depth"], cmp.inputs[0])
        cmp.inputs[1].default_value = 2.0
        cmp.inputs[2].default_value = 0.25
        nt.links.new(cmp.outputs[0], em.inputs["Strength"])
    if isinstance(mode, tuple) and mode[0] == "const":
        em.inputs["Color"].default_value = (mode[1], mode[1], mode[1], 1)
    else:
        geo = nt.nodes.new("ShaderNodeNewGeometry")
        sep = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(geo.outputs["Position"], sep.inputs[0])
        if mode in ("u", "v"):
            mr = nt.nodes.new("ShaderNodeMapRange")
            mr.clamp = False
            mr.inputs["From Min"].default_value = -6.0
            mr.inputs["From Max"].default_value = 6.0
            nt.links.new(sep.outputs["X" if mode == "u" else "Z"], mr.inputs["Value"])
            nt.links.new(mr.outputs["Result"], em.inputs["Color"])
        elif mode == "q":
            mx = node(nt, "ShaderNodeMath")
            mx.operation = "MULTIPLY"
            nt.links.new(sep.outputs["X"], mx.inputs[0])
            nt.links.new(sep.outputs["X"], mx.inputs[1])
            mz = node(nt, "ShaderNodeMath")
            mz.operation = "MULTIPLY"
            nt.links.new(sep.outputs["Z"], mz.inputs[0])
            nt.links.new(sep.outputs["Z"], mz.inputs[1])
            ad = node(nt, "ShaderNodeMath")
            ad.operation = "ADD"
            nt.links.new(mx.outputs[0], ad.inputs[0])
            nt.links.new(mz.outputs[0], ad.inputs[1])
            dv = node(nt, "ShaderNodeMath")
            dv.operation = "DIVIDE"
            nt.links.new(ad.outputs[0], dv.inputs[0])
            dv.inputs[1].default_value = 72.0
            nt.links.new(dv.outputs[0], em.inputs["Color"])
        elif mode[0] == "tex":
            _, path, x0, z0, size = mode
            img = bpy.data.images.load(path, check_existing=True)
            img.colorspace_settings.name = "sRGB"
            t = nt.nodes.new("ShaderNodeTexImage")
            t.image = img
            t.interpolation = "Linear"
            t.extension = "EXTEND"
            comb = nt.nodes.new("ShaderNodeCombineXYZ")
            mu = nt.nodes.new("ShaderNodeMapRange")
            mu.clamp = False
            mu.inputs["From Min"].default_value = x0
            mu.inputs["From Max"].default_value = x0 + size
            nt.links.new(sep.outputs["X"], mu.inputs["Value"])
            mv = nt.nodes.new("ShaderNodeMapRange")
            mv.clamp = False
            mv.inputs["From Min"].default_value = z0
            mv.inputs["From Max"].default_value = z0 + size
            nt.links.new(sep.outputs["Z"], mv.inputs["Value"])
            nt.links.new(mu.outputs["Result"], comb.inputs["X"])
            nt.links.new(mv.outputs["Result"], comb.inputs["Y"])
            nt.links.new(comb.outputs[0], t.inputs["Vector"])
            nt.links.new(t.outputs["Color"], em.inputs["Color"])
    no_emission_sampling(m)
    pl.data.materials.append(m)
    # non eclaire, ne projette pas d'ombre, n'eclaire pas en diffus ; vu par camera / refraction /
    # reflexion / diffusion volumique (comme un fond d'ecran vu a travers la matiere)
    set_vis(pl, camera=True, diffuse=False, glossy=True, transmission=True, volume=True, shadow=False)
    return pl


# ===========================================================================
# Rendu
# ===========================================================================
TIMES = {}


def render_png(path):
    sc = bpy.context.scene
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.render.image_settings.color_depth = "8"
    sc.render.filepath = path
    t0 = time.time()
    bpy.ops.render.render(write_still=True)
    dt = time.time() - t0
    TIMES[os.path.basename(path)] = round(dt, 1)
    print("RENDERED %s in %.1fs" % (path, dt))


def render_lin(tag):
    """Rend en EXR float (lineaire scene) et renvoie le tableau (H, W, 4), rangee 0 = bas."""
    sc = bpy.context.scene
    sc.render.image_settings.file_format = "OPEN_EXR"
    sc.render.image_settings.color_depth = "32"
    sc.render.image_settings.color_mode = "RGBA"
    path = os.path.join(TMP, tag + ".exr")
    sc.render.filepath = path
    t0 = time.time()
    bpy.ops.render.render(write_still=True)
    dt = time.time() - t0
    TIMES[tag] = round(dt, 1)
    print("RENDERED %s in %.1fs (%s)" % (tag, dt, DEVICE[0]))
    a = load_pixels(path)
    try:
        os.remove(path)
    except Exception:
        pass
    return a


# ===========================================================================
# BACKDROP : faux bureau colore 1024x1024 (genere en numpy)
# ===========================================================================
def make_backdrop():
    N = 1024
    rng = np.random.default_rng(7)
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
    u, v = xx / N, yy / N  # v = 0 en HAUT (on travaille en convention image ici)

    def hexc(h):
        return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], np.float32)

    # fond : degrade diagonal bleu -> violet -> orange + vagues douces
    t = np.clip(0.55 * u + 0.75 * v - 0.15 + 0.06 * np.sin(u * 9.0 + v * 4.0), 0, 1)[..., None]
    c0, c1, c2 = hexc("1f3cff"), hexc("b13cff"), hexc("ff8a3d")
    img = np.where(t < 0.5, c0 + (c1 - c0) * (t / 0.5), c1 + (c2 - c1) * ((t - 0.5) / 0.5))
    waves = 0.5 + 0.5 * np.sin((u * 3.0 - v * 2.2) * 6.28 + 2.0 * np.sin(v * 7.0))
    img = img * (0.86 + 0.14 * waves[..., None])
    # bulles lumineuses (fond d'ecran)
    for _ in range(14):
        cx, cy, r = rng.random() * N, rng.random() * N, 20 + rng.random() * 90
        d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
        a = np.clip((r - d) / 3.0, 0, 1)[..., None] * 0.18
        img = img * (1 - a) + np.array([1, 1, 1], np.float32) * a

    def rrect(x0, y0, x1, y1, rad):
        dx = np.maximum(np.maximum(x0 + rad - xx, xx - (x1 - rad)), 0)
        dy = np.maximum(np.maximum(y0 + rad - yy, yy - (y1 - rad)), 0)
        d = np.sqrt(dx * dx + dy * dy) - rad
        return np.clip(0.5 - d, 0, 1)[..., None]

    def paint(mask, col, alpha=1.0):
        nonlocal img
        a = mask * alpha
        img = img * (1 - a) + np.asarray(col, np.float32) * a

    def shadow(x0, y0, x1, y1, rad, off=10, blur=18, alpha=0.35):
        dx = np.maximum(np.maximum(x0 + rad - xx, xx - (x1 - rad)), 0)
        dy = np.maximum(np.maximum(y0 + off + rad - yy, yy - (y1 + off - rad)), 0)
        d = np.sqrt(dx * dx + dy * dy) - rad
        a = np.clip(1 - d / blur, 0, 1)[..., None] ** 2 * alpha
        img[...] = img * (1 - a)

    def text_lines(x0, y0, x1, y1, col, step=22, h=8, seed=0, colors=None):
        r = np.random.default_rng(seed)
        y = y0
        while y + h <= y1:
            x = x0 + (r.integers(0, 3) * 18 if colors else 0)
            while x < x1 - 30:
                w = r.integers(20, 90)
                if x + w > x1:
                    break
                c = colors[r.integers(len(colors))] if colors else col
                paint(rrect(x, y, x + w, y + h, h / 2), c)
                x += w + 10
                if r.random() < 0.15:
                    break
            y += step

    # --- icones du bureau (colonne gauche)
    icon_cols = ["ff4f86", "ffd23f", "3ddc97", "36c5f0", "ff8a3d", "9b5de5"]
    for i, hc in enumerate(icon_cols):
        y0 = 40 + i * 120
        paint(rrect(38, y0, 118, y0 + 80, 18), hexc(hc))
        paint(rrect(56, y0 + 22, 100, y0 + 58, 8), np.array([1, 1, 1], np.float32), 0.85)
        paint(rrect(42, y0 + 88, 114, y0 + 98, 5), np.array([1, 1, 1], np.float32), 0.9)

    # --- fenetre 1 : navigateur clair avec photo et texte
    X0, Y0, X1, Y1 = 230, 220, 640, 640
    shadow(X0, Y0, X1, Y1, 16)
    paint(rrect(X0, Y0, X1, Y1, 16), hexc("fbfbfe"))
    paint(rrect(X0, Y0, X1, Y0 + 40, 16), hexc("e6e4ef"))
    paint(rrect(X0, Y0 + 24, X1, Y0 + 40, 0), hexc("e6e4ef"))
    for k, hc in enumerate(["ff5f57", "febc2e", "28c840"]):
        cx, cy = X0 + 24 + k * 22, Y0 + 20
        paint(np.clip(7.5 - np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2), 0, 1)[..., None], hexc(hc))
    paint(rrect(X0 + 100, Y0 + 10, X1 - 20, Y0 + 30, 10), hexc("ffffff"))
    # photo : ciel, soleil, collines, lac
    px0, py0, px1, py1 = X0 + 20, Y0 + 56, X1 - 20, Y0 + 236
    pm = rrect(px0, py0, px1, py1, 10)
    pv = np.clip((yy - py0) / (py1 - py0), 0, 1)[..., None]
    pu = np.clip((xx - px0) / (px1 - px0), 0, 1)[..., None]
    sky = hexc("3fa9ff") * (1 - pv) + hexc("ffd1e8") * pv
    photo = sky.copy() + np.zeros_like(img)
    sun = np.clip(1 - np.sqrt((pu - 0.72) ** 2 + (pv - 0.32) ** 2) / 0.11, 0, 1) ** 0.5
    photo = photo * (1 - sun[..., :1]) + hexc("fff27a") * sun[..., :1]
    hill1 = (pv[..., 0] > 0.62 + 0.12 * np.sin(pu[..., 0] * 7.0 + 0.5))[..., None].astype(np.float32)
    photo = photo * (1 - hill1) + (hexc("2fbf71") * (1 - 0.35 * pv) + 0.08) * hill1
    hill2 = (pv[..., 0] > 0.78 + 0.07 * np.sin(pu[..., 0] * 11.0 + 2.0))[..., None].astype(np.float32)
    photo = photo * (1 - hill2) + hexc("137a52") * hill2
    lake = ((pv[..., 0] > 0.9) & (np.abs(pu[..., 0] - 0.35) < 0.2))[..., None].astype(np.float32)
    photo = photo * (1 - lake) + hexc("1e6fe0") * lake
    img = img * (1 - pm) + photo * pm
    # titre + texte
    paint(rrect(X0 + 20, Y0 + 256, X0 + 260, Y0 + 274, 9), hexc("2a2440"))
    text_lines(X0 + 20, Y0 + 290, X1 - 20, Y1 - 60, hexc("9a96ad"), step=20, h=8, seed=3)
    paint(rrect(X0 + 20, Y1 - 48, X0 + 140, Y1 - 18, 15), hexc("ff4f86"))
    paint(rrect(X0 + 150, Y1 - 48, X0 + 270, Y1 - 18, 15), hexc("ffffff"))
    paint(rrect(X0 + 152, Y1 - 46, X0 + 268, Y1 - 20, 13), hexc("ece9f5"))

    # --- fenetre 2 : editeur de code sombre (coloration syntaxique)
    X0, Y0, X1, Y1 = 560, 330, 900, 760
    shadow(X0, Y0, X1, Y1, 14)
    paint(rrect(X0, Y0, X1, Y1, 14), hexc("1d1b2b"))
    paint(rrect(X0, Y0, X1, Y0 + 34, 14), hexc("2b2840"))
    paint(rrect(X0, Y0 + 20, X1, Y0 + 34, 0), hexc("2b2840"))
    paint(rrect(X0 + 14, Y0 + 50, X0 + 34, Y1 - 14, 4), hexc("27243a"))
    text_lines(X0 + 48, Y0 + 52, X1 - 16, Y1 - 16, None, step=18, h=7, seed=5,
               colors=[hexc("ff79c6"), hexc("8be9fd"), hexc("50fa7b"), hexc("f1fa8c"), hexc("bd93f9"),
                       hexc("ffb86c"), hexc("f8f8f2")])

    # --- widget : graphique en barres + damier
    X0, Y0, X1, Y1 = 690, 90, 960, 300
    shadow(X0, Y0, X1, Y1, 18)
    paint(rrect(X0, Y0, X1, Y1, 18), hexc("ffffff"), 0.92)
    bars = ["ff4f86", "ff8a3d", "ffd23f", "3ddc97", "36c5f0", "6c63ff", "b13cff"]
    for k, hc in enumerate(bars):
        hgt = 40 + (k * 37 % 110)
        bx = X0 + 22 + k * 34
        paint(rrect(bx, Y1 - 22 - hgt, bx + 24, Y1 - 22, 5), hexc(hc))
    paint(rrect(X0 + 20, Y0 + 18, X0 + 150, Y0 + 32, 7), hexc("2a2440"))

    # --- widget meteo / horloge (cercle a anneaux colores)
    cx, cy = 300, 800
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    ang = np.arctan2(yy - cy, xx - cx)
    paint(np.clip(110 - d, 0, 1)[..., None], hexc("ffffff"), 0.9)
    ring = ((d > 70) & (d < 95)).astype(np.float32)[..., None]
    hue = (ang / (2 * np.pi) + 0.5)[..., None]
    rainbow = np.concatenate([0.5 + 0.5 * np.cos(6.283 * (hue + s)) for s in (0.0, 0.33, 0.67)], -1)
    paint(ring, rainbow)
    paint(np.clip(30 - d, 0, 1)[..., None], hexc("2a2440"))

    # --- damier fin (montre bien la refraction)
    chk = (((xx // 16) + (yy // 16)) % 2).astype(np.float32)[..., None]
    cm = rrect(60, 760, 180, 990, 10)
    paint(cm, hexc("ffffff") * chk + hexc("1d1b2b") * (1 - chk))

    # --- barre des taches
    paint(rrect(150, 950, 874, 1010, 22), hexc("15132a"), 0.75)
    for k, hc in enumerate(["ff4f86", "ffd23f", "3ddc97", "36c5f0", "ff8a3d", "9b5de5", "ffffff", "6c63ff"]):
        bx = 190 + k * 84
        paint(rrect(bx, 960, bx + 42, 1000, 11), hexc(hc))

    # --- petites etiquettes colorees au centre (zone vue derriere le compagnon)
    for k in range(10):
        r2 = np.random.default_rng(100 + k)
        x0 = 380 + r2.integers(0, 260)
        y0 = 660 + r2.integers(0, 100)
        hc = ["ff4f86", "3ddc97", "36c5f0", "ffd23f", "ff8a3d"][k % 5]
        paint(rrect(x0, y0, x0 + 70 + r2.integers(0, 60), y0 + 26, 13), hexc(hc))
        paint(rrect(x0 + 10, y0 + 10, x0 + 50, y0 + 16, 3), hexc("ffffff"))

    img = np.clip(img, 0, 1)
    write_png(BACKDROP, img[::-1].copy(), bits=8)  # write_png attend la convention Blender (bas en 0)


# ===========================================================================
# ENVIRONMENT MATTING
# ===========================================================================
def env_scene(mat_fn, plane_mode, lit, samples, denoise, adaptive, caustics=True, primary_only=False):
    reset()
    setup_cycles(RES, RES, samples, denoise=denoise, adaptive=adaptive, caustics=caustics)
    setup_rig(lit)
    add_camera_ortho(ENV["ortho_scale"])
    s = sphere("sphere", mat_fn(), ENV["sphere_radius"])
    env_plane(plane_mode, ENV["plane_y"], ENV["plane_half"], primary_only=primary_only)
    return s


def coverage_pass():
    reset()
    setup_cycles(RES, RES, 64, denoise=False, adaptive=False)
    setup_rig(False)
    add_camera_ortho(ENV["ortho_scale"])
    sphere("sphere", emission_mat("blk", (0, 0, 0), 0.0), 1.0)
    env_plane(("const", 1.0), ENV["plane_y"], ENV["plane_half"])
    a = render_lin("coverage")
    return np.clip(1.0 - a[..., :3].mean(-1), 0, 1)


def box_blur(img, r):
    if r < 1:
        return img
    out = img
    for axis in (0, 1):
        for _ in range(3):
            c = np.cumsum(np.pad(out, [(r + 1, r) if a == axis else (0, 0) for a in range(out.ndim)],
                                 mode="edge"), axis=axis)
            sl_hi = [slice(None)] * out.ndim
            sl_lo = [slice(None)] * out.ndim
            sl_hi[axis] = slice(2 * r + 1, None)
            sl_lo[axis] = slice(0, -(2 * r + 1))
            out = (c[tuple(sl_hi)] - c[tuple(sl_lo)]) / (2 * r + 1)
    return out


def sample_bilinear(img, u, v):
    """img (H, W, C) rangee 0 = bas ; u, v dans [0,1] (centres de pixels a (i+0.5)/W)."""
    H, W = img.shape[:2]
    x = np.clip(u * W - 0.5, 0, W - 1.001)
    y = np.clip(v * H - 0.5, 0, H - 1.001)
    x0 = np.floor(x).astype(int)
    y0 = np.floor(y).astype(int)
    fx = (x - x0)[..., None]
    fy = (y - y0)[..., None]
    a = img[y0, x0] * (1 - fx) + img[y0, x0 + 1] * fx
    b = img[y0 + 1, x0] * (1 - fx) + img[y0 + 1, x0 + 1] * fx
    return a * (1 - fy) + b * fy


def bg_lookup(px, pz, spread, bd_levels, sig_levels):
    """Fond (lineaire) a la position (px, pz) du plan, flou gaussien d'ecart-type `spread` (unites)."""
    u = (px - CHECK_TEX["x0"]) / CHECK_TEX["size"]
    v = (pz - CHECK_TEX["z0"]) / CHECK_TEX["size"]
    s = np.clip(spread, sig_levels[0], sig_levels[-1])
    idx = np.clip(np.searchsorted(sig_levels, s, side="right") - 1, 0, len(sig_levels) - 2)
    t = ((s - sig_levels[idx]) / (sig_levels[idx + 1] - sig_levels[idx]))[..., None]
    out = np.zeros(px.shape + (3,))
    for k in range(len(sig_levels) - 1):
        m = idx == k
        if not m.any():
            continue
        a = sample_bilinear(bd_levels[k], u[m], v[m])
        b = sample_bilinear(bd_levels[k + 1], u[m], v[m])
        out[m] = a * (1 - t[m]) + b * t[m]
    return out


ENV_STATS = {}


def code_passes(kind, mat_fn, tag, samples, modes=("black", "white", "u", "v", "q"), primary_only=False):
    """Passes codees sans lumieres (monde noir), meme graine, sans adaptatif ni denoise : les chemins sont
    identiques d'une passe a l'autre, seule l'emission du plan change -> rapports quasi sans bruit.
    Renvoie chaque passe moins la passe 'black' (fond noir)."""
    plane = {"black": ("const", 0.0), "white": ("const", 1.0), "u": "u", "v": "v", "q": "q"}
    out = {}
    for m in modes:
        env_scene(mat_fn, plane[m], lit=False, samples=samples, denoise=False, adaptive=False,
                  primary_only=primary_only)
        out[m] = render_lin("%s_%s_%s" % (kind, tag, m))[..., :3].astype(np.float64)
    blk = out.get("black", 0.0)
    return {k: out[k] - blk for k in out if k != "black"}


def decode_layer(T, U, V, Q, x_px, z_px, min_t=3e-3, smooth=0):
    """T,U,V,Q (H,W,3) -> position moyenne (x,z) sur le plan, ecart-type, debit (somme des canaux).
    L'ecart-type est calcule PAR CANAL puis moyenne (la separation R/G/B due a la dispersion n'est pas un
    flou). smooth > 0 : numerateurs/denominateurs lisses (box) avant division (couche diffuse, bruitee)."""
    if smooth:
        T, U, V, Q = (box_blur(a, smooth) for a in (T, U, V, Q))
    Ts = T.sum(-1)
    ok = Ts > min_t
    xp = np.where(ok, 12.0 * U.sum(-1) / np.maximum(Ts, 1e-9) - 6.0, x_px)
    zp = np.where(ok, 12.0 * V.sum(-1) / np.maximum(Ts, 1e-9) - 6.0, z_px)
    Tc = np.maximum(T, 1e-9)
    xc = 12.0 * U / Tc - 6.0
    zc = 12.0 * V / Tc - 6.0
    var_c = np.clip(72.0 * Q / Tc - xc ** 2 - zc ** 2, 0, None)
    var = np.where(ok, (var_c * np.clip(T, 0, None)).sum(-1) / np.maximum(Ts, 1e-9), 0.0)
    # la variance estimee est bruitee (difference de deux grands termes) : leger lissage spatial
    var = box_blur(var[..., None], 1)[..., 0]
    return xp, zp, np.sqrt(np.clip(var, 0, None)), Ts


def env_maps(kind):
    t_all = time.time()
    stats = {}
    cfg = TRANSP_CFG[kind]
    DS = ENV["density_scale"]
    cov = coverage_pass()
    H = W = RES
    jj, ii = np.meshgrid(np.arange(W), np.arange(H))
    x_px = -1.0 + (jj + 0.5) * 2.0 / W  # rayon droit (ortho) : x du pixel = x sur le plan
    z_px = -1.0 + (ii + 0.5) * 2.0 / H
    # ----- transport TOTAL (materiau complet)
    tot = code_passes(kind, lambda: transparent_mat(kind, "neutral", density=DS), "tot", CODE_SAMPLES)
    T = tot["white"]  # = rendu(fond blanc) - rendu(fond noir), par canal
    if cfg.get("dispersion"):
        # dispersion = 3 closures R/G/B tirees au hasard -> bruit de chroma enorme par canal ; le debit du
        # verre est physiquement incolore (la dispersion ne fait que decaler les positions) : on stocke la
        # luminance, lissee (convolution normalisee, interieur uniquement)
        g = T.mean(-1)
        M = (cov > 0.999).astype(np.float64)
        gs = box_blur((g * M)[..., None], 2)[..., 0] / np.maximum(box_blur(M[..., None], 2)[..., 0], 1e-6)
        T = np.repeat(np.where(M > 0, gs, g)[..., None], 3, -1)
    # ----- transport PRIMAIRE (image nette) : chemins a 2 refractions exactement (Ray Depth <= 2), jamais
    #       diffuses : diffusion remplacee par une absorption egale a l'extinction (sigma_a + sigma_s),
    #       ce qui donne exactement (et sans bruit) la part des chemins non diffuses.
    ext = tuple((a + cfg["scatter"]) * DS for a in cfg["neutral_sigma"])
    bal = code_passes(kind, lambda: transparent_mat(kind, "neutral", vol_override=ext), "prim",
                      max(256, CODE_SAMPLES // 2), modes=("white", "u", "v", "q"), primary_only=True)
    # + vue DIRECTE du fond (rayons camera qui ratent la sphere, Ray Depth 0, exclus par le masque) : ils
    #   touchent exactement le point "tout droit" ; fraction = 1 - couverture (meme filtre de pixel)
    direct = (1.0 - cov)[..., None]
    bal["white"] = bal["white"] + direct
    bal["u"] = bal["u"] + direct * ((x_px + 6) / 12)[..., None]
    bal["v"] = bal["v"] + direct * ((z_px + 6) / 12)[..., None]
    bal["q"] = bal["q"] + direct * ((x_px ** 2 + z_px ** 2) / 72)[..., None]
    xb, zb, sb, Tbs = decode_layer(bal["white"], bal["u"], bal["v"], bal["q"], x_px, z_px)
    # ----- part DIFFUSEE = total - balistique
    Tsc = np.clip(T - bal["white"], 0, None)
    xs, zs, ss, Tss = decode_layer(Tsc, tot["u"] - bal["u"], tot["v"] - bal["v"], tot["q"] - bal["q"], x_px, z_px,
                                   min_t=2e-2, smooth=3)
    # dispersion (verre) : ecart R-B de la position balistique
    xc = np.where(bal["white"] > 1e-3, bal["u"] / np.maximum(bal["white"], 1e-9), 0.5) * 12 - 6
    inner = (cov > 0.999) & ((x_px ** 2 + z_px ** 2) < 0.8 ** 2) & np.all(bal["white"] > 0.02, -1)
    stats["dispersion_dx_R_minus_B_mean_abs"] = round(float(np.abs(xc[..., 0] - xc[..., 2])[inner].mean()), 5) \
        if inner.any() else 0
    # ----- epaisseur effective : copie non diffusante, claire vs absorption grise sigma=1
    ta = {}
    for tag, vol in (("clear", (0.0, 0.0, 0.0)), ("abs", (1.0, 1.0, 1.0))):
        env_scene(lambda: transparent_mat(kind, "neutral", vol_override=vol), ("const", 1.0), lit=False,
                  samples=max(256, CODE_SAMPLES // 4), denoise=False, adaptive=False)
        ta[tag] = render_lin("%s_thick_%s" % (kind, tag))[..., :3].sum(-1).astype(np.float64)
    okt = (ta["clear"] > 3e-3) & (ta["abs"] > 1e-6)
    thick = np.where(okt, np.log(np.maximum(ta["clear"], 1e-9) / np.maximum(ta["abs"], 1e-9)), 0.0)
    thick = np.where(cov > 0.02, np.clip(thick, 0, 4), 0.0)
    # ----- self : eclairage studio, fond noir, denoise
    variants = ("neutral", "color") if cfg["color_hex"] else ("neutral",)
    self_lin = {}
    for variant in variants:
        env_scene(lambda: transparent_mat(kind, variant, density=DS), ("const", 0.0), lit=True, samples=SELF_SAMPLES,
                  denoise=True, adaptive=True)
        self_lin[variant] = render_lin("%s_self_%s" % (kind, variant))[..., :3].astype(np.float64)
    # transmittance totale de la version coloree
    T_col = None
    if cfg["color_hex"]:
        T_col = code_passes(kind, lambda: transparent_mat(kind, "color", density=DS), "col", CODE_SAMPLES // 2,
                            modes=("black", "white"))["white"]
    # ----- verite terrain : sphere eclairee devant le fond d'ecran (controle de la reconstruction)
    gt = {}
    for variant in variants:
        env_scene(lambda: transparent_mat(kind, variant, density=DS),
                  ("tex", BACKDROP, CHECK_TEX["x0"], CHECK_TEX["z0"], CHECK_TEX["size"]), lit=True,
                  samples=GT_SAMPLES, denoise=True, adaptive=True)
        gt[variant] = render_lin("%s_gt_%s" % (kind, variant))[..., :3].astype(np.float64)

    # ----- ecriture des cartes
    cov4 = cov[..., None]
    write_png(os.path.join(TEX_DIR, "mat_%s_self.png" % kind),
              np.concatenate([lin2srgb_np(self_lin["neutral"]), cov4], -1), 16)
    write_png(os.path.join(TEX_DIR, "mat_%s_trans.png" % kind), np.clip(T, 0, 1), 16)
    tb = np.clip(Tbs / 3.0, 0, 1)
    refr = np.stack([np.clip((xb + 6) / 12, 0, 1), np.clip((zb + 6) / 12, 0, 1), tb], -1)
    write_png(os.path.join(TEX_DIR, "mat_%s_refr.png" % kind), refr, 16)
    scat = np.stack([np.clip((xs + 6) / 12, 0, 1), np.clip((zs + 6) / 12, 0, 1), np.clip(ss / 4.0, 0, 1)], -1)
    write_png(os.path.join(TEX_DIR, "mat_%s_scat.png" % kind), scat, 16)
    aux = np.stack([np.clip(thick / 4.0, 0, 1), np.clip(sb / 2.0, 0, 1), cov], -1)
    write_png(os.path.join(TEX_DIR, "mat_%s_aux.png" % kind), aux, 16)
    if T_col is not None:
        write_png(os.path.join(TEX_DIR, "mat_%s_color_self.png" % kind),
                  np.concatenate([lin2srgb_np(self_lin["color"]), cov4], -1), 16)
        write_png(os.path.join(TEX_DIR, "mat_%s_color_trans.png" % kind), np.clip(T_col, 0, 1), 16)

    # ----- reconstruction "comme dans le jeu" a partir des valeurs QUANTIFIEES des fichiers
    q = lambda a: np.round(np.clip(a, 0, 1) * 65535) / 65535
    Tq, rq, sq, aq = q(np.clip(T, 0, 1)), q(refr), q(scat), q(aux)
    xb_, zb_, Tb_ = rq[..., 0] * 12 - 6, rq[..., 1] * 12 - 6, rq[..., 2]
    xs_, zs_, ss_ = sq[..., 0] * 12 - 6, sq[..., 1] * 12 - 6, sq[..., 2] * 4
    th_, sb_ = aq[..., 0] * 4, aq[..., 1] * 2
    bd = srgb2lin_np(load_pixels(BACKDROP)[..., :3].astype(np.float64))
    px_per_unit = bd.shape[1] / CHECK_TEX["size"]
    sig_levels = np.array([0.0, 0.01, 0.025, 0.05, 0.1, 0.2, 0.4, 0.8, 1.6, 4.0])
    bd_levels = [bd] + [box_blur(bd, int(round(s * px_per_unit / math.sqrt(3.0)))) for s in sig_levels[1:]]

    def recon(self_l, T_total, T_ball):
        T_sc = np.clip(T_total - T_ball, 0, None)
        return (self_l + T_ball * bg_lookup(xb_, zb_, sb_, bd_levels, sig_levels)
                + T_sc * bg_lookup(xs_, zs_, ss_, bd_levels, sig_levels))

    Tb3 = Tb_[..., None] * np.ones(3)
    rec = recon(self_lin["neutral"], Tq, Tb3)

    def err(a, b):
        return float(np.abs(lin2srgb_np(a) - lin2srgb_np(b))[cov > 0.5].mean())

    stats["recon_mean_abs_err_srgb"] = round(err(rec, gt["neutral"]), 4)
    stretch = np.stack([np.clip((xb + 2) / 4, 0, 1), np.clip((zb + 2) / 4, 0, 1), tb], -1)
    row1 = [lin2srgb_np(self_lin["neutral"]), lin2srgb_np(np.clip(T, 0, 1)), stretch,
            np.stack([aux[..., 0] * 2, scat[..., 2] * 2, Tss / 3.0], -1)]
    row2 = [lin2srgb_np(rec), lin2srgb_np(gt["neutral"])]
    if T_col is not None:
        # teinte de jeu : balistique = T_bal * exp(-(sigma_col - sigma_neutre) * epaisseur)
        dsig = (np.array(sigma_from_color(cfg["color_hex"], cfg["color_thickness"]))
                - np.array(cfg["neutral_sigma"])) * DS
        Tb_col = Tb3 * np.exp(-dsig * th_[..., None])
        rec_c = recon(self_lin["color"], q(np.clip(T_col, 0, 1)), Tb_col)
        stats["recon_color_mean_abs_err_srgb"] = round(err(rec_c, gt["color"]), 4)
        row2 += [lin2srgb_np(rec_c), lin2srgb_np(gt["color"])]
        stats["T_color_center"] = [round(float(x), 4) for x in
                                   T_col[H // 2 - 4:H // 2 + 4, W // 2 - 4:W // 2 + 4].mean((0, 1))]
    else:
        row2 += [np.clip(np.abs(lin2srgb_np(rec) - lin2srgb_np(gt["neutral"])) * 4, 0, 1),
                 lin2srgb_np(self_lin["neutral"])]
    c = (slice(H // 2 - 4, H // 2 + 4), slice(W // 2 - 4, W // 2 + 4))
    stats["T_center"] = [round(float(x), 4) for x in T[c].mean((0, 1))]
    stats["T_ballistic_center"] = round(float(Tbs[c].mean() / 3), 4)
    stats["T_mean_inside"] = [round(float(x), 4) for x in T[cov > 0.999].mean(0)]
    stats["thickness_center"] = round(float(thick[H // 2, W // 2]), 4)
    stats["thickness_max"] = round(float(thick.max()), 4)
    stats["spread_ballistic_center"] = round(float(sb[H // 2, W // 2]), 4)
    stats["spread_scattered_center"] = round(float(ss[H // 2, W // 2]), 4)
    stats["refr_center_xz"] = [round(float(xb[H // 2, W // 2]), 4), round(float(zb[H // 2, W // 2]), 4)]
    stats["refr_x_at_r"] = {str(r): round(float(xb[H // 2, int(W * (0.5 + r / 2))]), 4)
                            for r in (0.25, 0.5, 0.75, 0.9, 0.97)}
    stats["scat_x_at_r"] = {str(r): round(float(xs[H // 2, int(W * (0.5 + r / 2))]), 4)
                            for r in (0.25, 0.5, 0.75, 0.9)}
    sheet = np.concatenate([np.concatenate(row2, 1), np.concatenate(row1, 1)], 0)  # rangee 0 = bas
    write_png(os.path.join(PREV_DIR, "mat_%s_envmatte_check.png" % kind), sheet, 8)
    stats["total_time_s"] = round(time.time() - t_all, 1)
    ENV_STATS[kind] = stats
    print("ENVSTATS", kind, json.dumps(stats))
    with open(os.path.join(TMP, "envstats_%s.json" % kind), "w") as f:
        json.dump(stats, f, indent=1)


# ===========================================================================
# MATCAPS opaques
# ===========================================================================
MATCAPS = {
    "mc_pate": ("pate", "neutral", "mat_pate_matcap.png"),
    "mc_pate_color": ("pate", "color", "mat_pate_matcap_color.png"),
    "mc_chrome": ("chrome", "neutral", "mat_chrome_matcap.png"),
    "mc_plastique": ("plastique", "neutral", "mat_plastique_matcap.png"),
    "mc_bois": ("bois", "neutral", "mat_bois_matcap.png"),
}


def matcap(job):
    kind, variant, fname = MATCAPS[job]
    reset()
    setup_cycles(RES, RES, MC_SAMPLES)
    bpy.context.scene.render.film_transparent = True
    setup_rig(True)
    add_camera_ortho(2.0)
    sphere("sphere", opaque_mat(kind, variant), 1.0)
    render_png(os.path.join(TEX_DIR, fname))


def sheet():
    names = ["mat_pate_matcap", "mat_pate_matcap_color", "mat_chrome_matcap", "mat_plastique_matcap",
             "mat_bois_matcap"]
    tile = 512
    W, H = 3 * tile, 2 * tile
    out = np.zeros((H, W, 4), np.float32)
    yy, xx = np.mgrid[0:H, 0:W]
    chk = ((xx // 32 + yy // 32) % 2).astype(np.float32)
    out[..., :3] = (0.36 + 0.06 * chk)[..., None]
    out[..., 3] = 1
    imgs = []
    for nm in names:
        p = os.path.join(TEX_DIR, nm + ".png")
        imgs.append(load_pixels(p) if os.path.exists(p) else None)
    if imgs[0] is not None:  # pate neutre x teinte f1d6a8 (simulation du jeu, en sRGB)
        t = imgs[0].copy()
        tint = np.array(srgb2lin("f1d6a8"), np.float32)
        t[..., :3] = lin2srgb_np(srgb2lin_np(t[..., :3]) * tint)
        imgs.append(t)
    for k, im in enumerate(imgs):
        if im is None:
            continue
        r, c = k // 3, k % 3
        y0 = H - (r + 1) * tile
        x0 = c * tile
        a = im[..., 3:4]
        reg = out[y0:y0 + tile, x0:x0 + tile, :3]
        out[y0:y0 + tile, x0:x0 + tile, :3] = im[..., :3] * a + reg * (1 - a)
    write_png(os.path.join(PREV_DIR, "mat_sheet.png"), out[..., :3], 8)


# ===========================================================================
# REFERENCES : vrai compagnon (body_mochi + yeux eye_dot + bouche mouth_smile) devant le faux bureau
# ===========================================================================
C_G2B = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))


def godot_xform(basis_cols, pos, scale=1.0):
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
    return {o.name: o for o in new if o.parent is None}, new


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


def face_mats():
    return {
        "eye_black": principled("r_eye_black", srgb2lin("0b0a0e"), rough=0.16, coat=1.0, coat_rough=0.05),
        "eye_white": principled("r_eye_white", srgb2lin("fbfbfd"), rough=0.3, coat=0.6, coat_rough=0.1),
        "glint": principled("r_glint", (1, 1, 1), rough=0.5, emit=3.0),
    }


REF_MATS = {
    "gelee": lambda: transparent_mat("gelee", "color"),
    "slime": lambda: transparent_mat("slime", "color"),
    "verre": lambda: transparent_mat("verre", "neutral"),
    "pate": lambda: pate_mat("color"),
    "chrome": chrome_mat,
    "plastique": lambda: plastique_mat(srgb2lin("ff7eb3")),
    "bois": bois_mat,
}
REF_TINT = {"gelee": "ff4f86", "slime": "8ef25c", "verre": None, "pate": "f1d6a8", "chrome": None,
            "plastique": "ff7eb3", "bois": BOIS_HEX}


def reference(kind, sid="mochi"):
    a = SPECIES[sid]
    reset()
    transparent = kind in TRANSP
    setup_cycles(REF["res"], REF["res"], REF_SAMPLES, caustics=transparent)
    setup_rig(True)
    roots, _ = import_glb("bodies.glb")
    body = roots["body_" + sid]
    for nm, o in roots.items():
        if o is not body:
            delete_hier(o)
    body.data.materials.clear()
    body.data.materials.append(REF_MATS[kind]())
    for p in body.data.polygons:
        p.use_smooth = True
    fm = face_mats()
    froots, _ = import_glb("face.glb")
    face_objs = []
    for side in ("l", "r"):
        n = (Vector(a["eye_" + side + "_n"]) + Vector((0, 0, 1.3))).normalized()
        p = Vector(a["eye_" + side]) + n * 0.01
        face_objs.append(dup_hier(froots["eye_dot"], godot_xform(basis_facing(n), p)))
    n = (Vector(a["mouth_n"]) + Vector((0, 0, 1.0))).normalized()
    p = Vector(a["mouth"]) + n * 0.01
    face_objs.append(dup_hier(froots["mouth_smile"], godot_xform(basis_facing(n), p)))
    for o in froots.values():
        delete_hier(o)
    for o in [m for r in face_objs for m in meshes_of(r)]:
        for slot in o.material_slots:
            if slot.material is None:
                continue
            key = slot.material.name.split(".")[0]
            if key in fm:
                slot.link = "OBJECT"
                slot.material = fm[key]
    bpy.context.view_layer.update()
    add_camera_ref()
    pl = env_plane(("tex", BACKDROP, -REF["plane_size"] / 2, REF["plane_center"][2] - REF["plane_size"] / 2,
                    REF["plane_size"]), REF["plane_y"], REF["plane_size"] / 2, z_center=REF["plane_center"][2])
    if not transparent:
        # opaques : le fond n'apparait pas dans les reflets (comme un matcap dans le jeu)
        pl.visible_glossy = False
        pl.visible_transmission = False
        pl.visible_volume_scatter = False
    render_png(os.path.join(PREV_DIR, "mat_ref_%s%s.png" % (kind, OPTS.get("suffix", ""))))


# ===========================================================================
# JSON
# ===========================================================================
def write_json():
    stats = {}
    for k in TRANSP:
        p = os.path.join(TMP, "envstats_%s.json" % k)
        if os.path.exists(p):
            stats[k] = json.load(open(p))
    mats = {}
    for k in TRANSP:
        cfg = TRANSP_CFG[k]
        d = {
            "ior": cfg["ior"],
            "roughness": cfg["rough"],
            "neutral_absorption_per_unit": list(cfg["neutral_sigma"]),
            "scatter_density_per_unit": cfg["scatter"],
            "scatter_anisotropy": cfg["scatter_aniso"],
            "files": {s: "res://assets/textures/mat_%s_%s.png" % (k, s) for s in ("self", "trans", "refr", "scat", "aux")},
        }
        if cfg["color_hex"]:
            sig = sigma_from_color(cfg["color_hex"], cfg["color_thickness"])
            d["reference_color_hex"] = cfg["color_hex"]
            d["reference_color_absorption_per_unit"] = [round(x, 4) for x in sig]
            d["reference_color_definition"] = ("Beer-Lambert: transmittance over %.2f units of material = the "
                                               "colour (linear)" % cfg["color_thickness"])
            d["files"]["color_self"] = "res://assets/textures/mat_%s_color_self.png" % k
            d["files"]["color_trans"] = "res://assets/textures/mat_%s_color_trans.png" % k
        if k == "verre":
            d["dispersion_ior_rgb"] = list(cfg["dispersion"])
        if k == "slime":
            d["coat"] = {"weight": 1.0, "roughness": 0.02, "ior": 1.4}
            d["bump"] = "noise scale 2.2 strength 0.22 (wobble) + noise scale 14 strength 0.05"
        if k in stats:
            d["measured"] = stats[k]
        mats[k] = d
    opaque = {
        "pate": {"matcap": "res://assets/textures/mat_pate_matcap.png",
                 "matcap_color": "res://assets/textures/mat_pate_matcap_color.png",
                 "tint_hex_for_neutral": "f1d6a8",
                 "shader": ("Principled, random-walk SSS weight 1 (radius colour (1,.6,.35) / neutral (1,.9,.8), "
                            "scale .03), roughness .42 -> .95 under flour, specular .5, sheen .3/.3; flour = "
                            "low-freq zones (noise 2.2) x fine dust (noise 120) + light veil; bump = soft lumps "
                            "(noise 2.4, .6) + fermentation pores (smooth voronoi 30, .55) + grain (noise 110, .3)"),
                 "params": PATE},
        "chrome": {"matcap": "res://assets/textures/mat_chrome_matcap.png",
                   "shader": "metallic 1, base (.93,.93,.95), roughness .035"},
        "plastique": {"matcap": "res://assets/textures/mat_plastique_matcap.png", "neutral_base_linear": 0.86,
                      "shader": "base .86 grey, roughness .32, coat .85/.05, SSS .12 scale .03 (tint: multiply)"},
        "bois": {"matcap": "res://assets/textures/mat_bois_matcap.png", "base_hex": BOIS_HEX,
                 "shader": "base 8a5a36, roughness .5, varnish coat 1.0 roughness .03; grain procedural in game "
                           "(matcap = lighting/varnish response on this mid-brown; divide by base colour to re-tint)"},
    }
    d = {
        "_doc": ("Cycles lookdev for Pompom's transparent (environment matting, Zongker et al. 1999) and opaque "
                 "(matcap) materials. Generator: blender/render_materials.py. Lighting = studio rig in "
                 "godot/data/studio_rig.json (same lights + gradient sky as the fur matcaps). All maps are indexed "
                 "like a matcap: the 512x512 image is an orthographic front view of a unit sphere filling the image "
                 "(pixel uv = view-space normal.xy * 0.5 + 0.5, v up)."),
        "generator": "blender/render_materials.py",
        "view_transform": "Standard", "look": "None", "exposure": 0.0,
        "environment_matting": {
            "setup": {
                "sphere_radius": ENV["sphere_radius"], "sphere_center_blender": [0, 0, 0],
                "camera": "orthographic, Blender (0,-10,0) looking +Y, ortho_scale 2.0 (image spans x,z in [-1,1])",
                "ortho_scale": ENV["ortho_scale"], "resolution": RES,
                "background_plane": "emissive, unlit, Blender y = +2.0 (2 units behind sphere centre = 1 unit behind "
                                    "its back), spans x,z in [-6,6], no shadows, invisible to diffuse rays, visible "
                                    "to camera/glossy/transmission/volume-scatter rays",
                "plane_distance_from_center": ENV["plane_y"], "plane_half_size": ENV["plane_half"],
                "density_scale": ENV["density_scale"],
                "density_scale_doc": ("the radius-1 sphere stands for a pet of radius ~0.5 scaled x2: all volume "
                                      "coefficients (absorption, scattering) were multiplied by density_scale so the "
                                      "optical depth through the sphere equals the one through the real pet (the "
                                      "*_per_unit values below are at pet scale, as used in the reference renders)."),
                "godot_view_space": "Blender (x, y, z) -> Godot view (x, z, -y): plane x = view right, plane z = view up",
            },
            "composite_formula": ("C_lin = self_lin + Tp * Bg_lin(Pp, blur sp) + max(trans_lin - Tp, 0) * Bg_lin(Ps, "
                                  "blur ss). Two layers: PRIMARY = rays refracted exactly twice (camera -> enter -> exit "
                                  "-> background, never scattered or internally reflected): sharp refracted image, "
                                  "position Pp = refr.rg, throughput Tp = refr.b, blur sp = aux.g*2. SECONDARY = "
                                  "everything else that reaches the background (volume scattering, internal "
                                  "reflections, external Fresnel reflection of the background at grazing rim angles): "
                                  "mean position Ps = scat.rg, blur ss = scat.b*4. Outside the sphere: self=0, trans=1, "
                                  "Tp=1, Pp = straight-through, so the formula needs no alpha. Positions/blur are in "
                                  "plane units (sphere radius = 1). Validated in numpy against a Cycles render of the "
                                  "sphere in front of backdrop.png (see measured.recon_*_err and "
                                  "blender/previews/mat_<m>_envmatte_check.png)."),
            "files": {
                "mat_<m>_self.png": ("RGBA 16-bit. RGB = light the material sends to the camera with a BLACK "
                                     "background (studio reflections, internal scatter of studio light, rim), "
                                     "sRGB-ENCODED (decode to linear before adding), premultiplied by coverage "
                                     "(black outside). A = sphere coverage (antialiased, linear). Import: sRGB / "
                                     "source_color, disable fix_alpha_border, no premultiply."),
                "mat_<m>_trans.png": ("RGB 16-bit LINEAR (raw, import as non-colour). Total per-channel transmittance "
                                      "T = render(bg emission 1.0) - render(bg emission 0), computed in numpy on float "
                                      "EXR pixels, lights off + world black in both (by linearity identical to the lit "
                                      "subtraction, minus the light noise). Same seed, no adaptive sampling, no "
                                      "denoise. Outside sphere = 1."),
                "mat_<m>_refr.png": ("RGB 16-bit LINEAR raw codes, PRIMARY layer. The plane emitted the codes "
                                     "R=(x+6)/12, G=(z+6)/12, B=1 (rendered as separate grey passes with the same seed "
                                     "so paths are identical; RG = sum_c U_c / sum_c T_c, i.e. 'divided by the B / "
                                     "throughput pass'). Decode: x_plane = R*12-6, z_plane = G*12-6 (Blender plane "
                                     "coords = Godot view x / view y, units = sphere radii, plane 2.0 behind the "
                                     "centre). B = primary throughput (mean over RGB, linear). An undistorted pixel at "
                                     "image coords (sx, sz) in [-1,1] would have R=(sx+6)/12; where throughput ~0 the "
                                     "straight-through code is stored. Do NOT mipmap / filter across the silhouette."),
                "mat_<m>_scat.png": ("RGB 16-bit LINEAR, SECONDARY layer: R,G = mean hit position (same code as refr), "
                                     "B = std-dev of the hit position / 4 (plane units). Secondary throughput = "
                                     "trans - refr.b (per channel)."),
                "mat_<m>_aux.png": ("RGB 16-bit LINEAR. R = effective optical path length inside the material / 4 "
                                    "(units; = ln(T_clear / T_absorbing) for a non-scattering copy with grey sigma=1 "
                                    "absorption) -> Beer-Lambert tinting of the primary layer: Tp_tinted = Tp * "
                                    "exp(-(sigma_tint - sigma_neutral) * density_scale * R*4) with sigma in per-unit "
                                    "at PET scale (materials.*_per_unit). G = primary-layer spread / 2 (std-dev "
                                    "of the primary hit position; ~0 except dispersion/rim). B = coverage."),
                "mat_<m>_color_self.png / _color_trans.png": ("same as self / trans for the reference colour version "
                                                              "(pink gelee, green slime); refr/scat/aux are shared "
                                                              "(same IOR / geometry)."),
            },
            "game_mapping_hint": ("Real-time: sample all maps with the view-space normal (matcap uv = n.xy*0.5+0.5). "
                                  "For a matcap pixel with straight-through point S=(sx,sz)=n.xy, the background is "
                                  "displaced by D = P - S plane units; on screen D * (pet radius in pixels) when the "
                                  "desktop is considered 1 pet radius behind the pet's back (that is the setup the "
                                  "maps encode; scale D for artistic strength). Background blur radius = spread * "
                                  "pet radius in pixels (use mip LOD / a pre-blurred desktop). Tint = multiply the "
                                  "neutral maps (self roughly by tint, Tp by exp(-sigma*thickness), secondary by "
                                  "tint), or use the *_color_* maps directly for the reference colours."),
            "materials": mats,
        },
        "opaque_matcaps": {
            "_doc": ("512x512 RGBA 8-bit sRGB, transparent background (straight alpha), same ortho unit sphere + "
                     "studio rig, like fur_matcap.png. Neutral matcaps are meant to be multiplied by the tint in "
                     "linear space."),
            "materials": opaque,
        },
        "reference_renders": {
            "_doc": ("blender/previews/mat_ref_<m>.png : what the game must match. The pet (body_mochi + 2x eye_dot "
                     "+ mouth_smile, eyes at anchor + n*0.01 with n = normalize(eye_n + (0,0,1.3)) Godot, mouth n = "
                     "normalize(mouth_n + (0,0,1))) stands on z=0 (no floor, no shadow catcher) in front of "
                     "blender/previews/backdrop.png shown on an unlit emissive plane. Standard view transform."),
            "camera_blender": {"location": list(REF["cam_loc"]), "look_direction": [0, 1, 0], "up": [0, 0, 1],
                               "projection": "perspective", "sensor_fit": "VERTICAL",
                               "fov_vertical_deg": REF["fov_v_deg"], "resolution": [REF["res"], REF["res"]]},
            "camera_godot": {"position": [REF["cam_loc"][0], REF["cam_loc"][2], -REF["cam_loc"][1]],
                             "look_direction": [0, 0, -1], "keep_aspect": "KEEP_HEIGHT",
                             "fov": REF["fov_v_deg"]},
            "backdrop_plane_blender": {"center": list(REF["plane_center"]), "size": [REF["plane_size"], REF["plane_size"]],
                                       "normal": [0, -1, 0],
                                       "uv": "image u -> +X (right), image v -> +Z (up); image top row at z = 3.55",
                                       "image": "blender/previews/backdrop.png (1024x1024 sRGB)",
                                       "emission_strength": 1.0, "lit": False, "casts_shadow": False},
            "backdrop_plane_godot": {"center": [REF["plane_center"][0], REF["plane_center"][2], -REF["plane_center"][1]],
                                     "size": [REF["plane_size"], REF["plane_size"]], "normal": [0, 0, 1]},
            "plane_ray_visibility": ("transparent materials: camera, glossy, transmission, volume-scatter (not "
                                     "diffuse, no shadow). Opaque materials: camera only (matcap-like)."),
            "colors": {k: v for k, v in REF_TINT.items()},
            "files": {k: "blender/previews/mat_ref_%s.png" % k for k in TRANSP + OPAQUE},
        },
        "render_times_s_last_run": TIMES,
    }
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=1)
    print("WROTE", OUT_JSON)


# ===========================================================================
T_ALL = time.time()
for job in TODO:
    print("=== JOB", job)
    t0 = time.time()
    if job == "backdrop":
        make_backdrop()
    elif job.startswith("env_"):
        env_maps(job[4:])
    elif job in MATCAPS:
        matcap(job)
    elif job == "sheet":
        sheet()
    elif job.startswith("ref_"):
        reference(job[4:])
    elif job == "json":
        write_json()
    else:
        print("unknown target", job)
    print("JOB %s done in %.1fs" % (job, time.time() - t0))
print("TIMES", json.dumps(TIMES))
print("TOTAL %.1fs" % (time.time() - T_ALL))
