"""Terrain data for Roblox voxel Terrain, from the battlefield builder's own height function.

Run inside Blender after assets/map/build_battlefield.py's build() (its result must be stored as
bpy.app.driver_namespace["battlefield"]["B"]), then
bpy.app.driver_namespace["terrain_data"]["render"](path).

Writes one RGB PNG: one pixel per 4 x 4-stud terrain column, so Studio can read it back with
EditableImage and write voxels (scripts/build-terrain-v2-2.luau). Encoding, per pixel:
  R, G   height as a 16-bit number: h = (R * 256 + G) / SCALE - OFFSET   (2 mm steps)
  B      ground material code, MATERIALS below
Pixel (i, j) is the column centred on Roblox x = X0 + 4 i + 2, z = Z0 + 4 j + 2 (row 0 = north).

Field materials follow DESIGN.md's approved 2026-10-23 Arcane Lineage references: a coherent
textured green field, packed-dirt ram routes, mud crater floors, a light packed courtyard inside each castle
(grass at the wall foot, mud round the forge), rock on steep ground and cliffs, sand at the water.
Everything is mirrored across x = 0 like the map: noise is sampled at |x|.
"""
import bpy, math, os, json
from mathutils import noise, Vector

STEP = 4
X0, X1 = -936, 936          # past the coast on both ends (builder: HALF_X = 780 + 152)
Z0, Z1 = -480, 480          # (HALF_Y = 340 + 140)
SCALE, OFFSET = 500.0, 64.0  # 16-bit height: -64 .. +67 studs in 2 mm steps

MATERIALS = {   # code -> Roblox Enum.Material name (scripts/build-terrain-v2-2.luau has the same table)
    1: "Grass", 2: "LeafyGrass", 3: "Ground", 4: "Mud", 5: "Rock", 6: "Sand", 7: "Concrete",
}
CODE = {v: k for k, v in MATERIALS.items()}
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "reference_terrain_surface.json"), encoding="utf-8") as _profile_file:
    SURFACE_PROFILE = json.load(_profile_file)
assert SURFACE_PROFILE["preserve_heights"]
FIELD_MATERIAL = SURFACE_PROFILE["field_material"]
assert FIELD_MATERIAL in CODE


def _n(x, z, scale, seed):
    """Perlin noise in roughly -1..1, mirrored across x = 0."""
    return noise.noise(Vector((abs(x) / scale, z / scale, seed)))


def _reference_path(D, x, z, nearest_path):
    """Same mirrored painted fringe as apply-reference-terrain-surface.luau."""
    distance, _, _ = nearest_path(D, x, -z)
    ax, by = abs(x), -z
    edge = SURFACE_PROFILE["path_edge_wobble"] * (
        0.5 + 0.25 * math.sin(ax / 13 + by / 9)
        + 0.25 * math.sin(ax / 5.7 - by / 17))
    return distance <= D["routes"][0]["width"] / 2 + edge


def _courtyard(castle, x, z):
    """Inside one castle ring (Roblox coordinates, castle from layout.json)."""
    inter = castle["interior"]
    for s in inter["specialists"]:
        if s["role"] == "Blacksmith":   # smithy grime round the forge
            edge = max(s["min_x"] - x, x - s["max_x"], s["min_z"] - z, z - s["max_z"])
            if edge <= 9 + 3 * _n(x, z, 6, 5.5):
                return "Mud"
    half = castle["ring_size"]["x"] / 2
    cx, cz = castle["center"]["x"], castle["center"]["z"]
    to_wall = half - max(abs(x - cx), abs(z - cz))
    if to_wall < 15 + 5 * _n(x, z, 17, 2.2):
        return "Grass"   # grass survives along the foot of the walls, away from traffic
    if _n(x, z, 23, 9.7) + 0.4 * _n(x, z, 7, 3.3) > 0.3:
        return "Ground"  # worn dirt patches
    return "Concrete"    # light packed ground


def build():
    import importlib
    B = bpy.app.driver_namespace["battlefield"]["B"]
    D, height, inland = B["D"], B["height"], B["inland"]
    bf = bpy.app.driver_namespace["battlefield"]
    # the builder's helpers live in its module globals; reach them through a function's globals
    G = bf["verify"].__globals__
    nearest_path = G["nearest_path"]
    nx, nz = (X1 - X0) // STEP, (Z1 - Z0) // STEP
    H = [[0.0] * nx for _ in range(nz)]
    S = [[0.0] * nx for _ in range(nz)]
    for j in range(nz):
        z = Z0 + STEP * j + STEP / 2
        for i in range(nx):
            x = X0 + STEP * i + STEP / 2
            H[j][i] = height(x, -z)      # Blender y = -Roblox z
            S[j][i] = inland(x, -z)
    castles = D["L"]["castles"]
    mats = [[1] * nx for _ in range(nz)]
    counts = {}
    for j in range(nz):
        z = Z0 + STEP * j + STEP / 2
        for i in range(nx):
            x = X0 + STEP * i + STEP / 2
            h, s = H[j][i], S[j][i]
            gx = (H[j][min(i + 1, nx - 1)] - H[j][max(i - 1, 0)]) / (2 * STEP)
            gz = (H[min(j + 1, nz - 1)][i] - H[max(j - 1, 0)][i]) / (2 * STEP)
            slope = math.hypot(gx, gz)
            m = None
            if s < 0 or h < 0.4:
                m = "Sand"   # beach and seabed
            elif slope > 0.75:
                m = "Rock"   # cliffs and steep banks
            if m is None:
                for c in castles:
                    half = c["ring_size"]["x"] / 2
                    if abs(x - c["center"]["x"]) <= half and abs(z - c["center"]["z"]) <= half:
                        m = _courtyard(c, x, z)
                        break
            if m is None:
                for c in D["craters"]:
                    d = math.hypot(x - c["cx"], -z - c["cy"])
                    if d < c["rf"] + 0.5:
                        m = "Mud"
                    elif d < (c["rf"] + c["r"]) / 2:
                        m = "Ground"
                    if m:
                        break
            if m is None and _reference_path(D, x, z, nearest_path):
                m = "Ground"
            if m is None and s < 22 and slope > 0.45:
                m = "Rock"   # the cliff band near the coast
            if m is None:
                m = FIELD_MATERIAL  # the texture supplies detail; no camouflage-like bare patches
            mats[j][i] = CODE[m]
            counts[m] = counts.get(m, 0) + 1
    return dict(H=H, mats=mats, nx=nx, nz=nz, counts=counts)


def render(path):
    import numpy as np
    r = build()
    nx, nz = r["nx"], r["nz"]
    px = np.zeros((nz, nx, 4), dtype=np.float32)
    lo, hi = 1e9, -1e9
    for j in range(nz):
        for i in range(nx):
            h = r["H"][j][i]
            lo, hi = min(lo, h), max(hi, h)
            v = max(0, min(65535, int(round((h + OFFSET) * SCALE))))
            px[j, i] = (v >> 8, v & 255, r["mats"][j][i], 255)
    img = bpy.data.images.new("TerrainData_v2_2", nx, nz, alpha=False)
    img.colorspace_settings.name = "Non-Color"
    img.pixels.foreach_set((px[::-1] / 255.0).ravel())   # Blender rows run bottom-up; row 0 = north
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)
    # read back: the PNG must hold exactly the bytes intended
    chk = bpy.data.images.load(path, check_existing=False)
    back = np.array(chk.pixels[:], dtype=np.float32).reshape(nz, nx, 4)[::-1] * 255.0
    bpy.data.images.remove(chk)
    err = float(np.abs(np.round(back[..., :3]) - px[..., :3]).max())
    return dict(size=(nx, nz), height_range=(round(lo, 2), round(hi, 2)), counts=r["counts"], readback_max_byte_error=err)


bpy.app.driver_namespace["terrain_data"] = dict(build=build, render=render, MATERIALS=MATERIALS,
                                                 X0=X0, Z0=Z0, STEP=STEP, SCALE=SCALE, OFFSET=OFFSET)
