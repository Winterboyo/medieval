"""Village paths inside both castles, as Roblox meshes (REALISM-TARGET.md).

Run inside Blender with __file__ set, then bpy.app.driver_namespace["village_paths"]["build"]()
and ["export"](path). Writes two objects, A_VillagePaths and B_VillagePaths, for layout.json v2.2.

Each castle's street network is ONE mesh so the herringbone texture (MaterialVariant
VillageHerringbone, assets/textures/build_herringbone.py, box-projected by Roblox) runs unbroken
through every junction: a main street from the gate to the Keep with a small square before it, a
lane across the Keep front into the forge forecourt, and a branch to every door. The streets are
drawn once for Castle A against its layout.json v2.2 interior (doors, Keep front, forecourt) and
mirrored across x = 0 for Castle B, edge noise included. Edges are crisp and slightly irregular
(marching squares on a distance field with noise), and the top sits TOP studs above the flat
courtyard, with a short side face, like The Forge's paved pads.

Coordinates below are Roblox (x, z); Roblox (x, y, z) is Blender (x, -z, y).
"""
import bpy, bmesh, math
from mathutils import noise

GROUND = 10.0         # the courtyard terrain is flat at this height
TOP = 0.2             # paving surface above the ground
SKIRT = 0.5           # side face depth below the ground
STEP = 1.0            # marching-squares grid, studs

# Castle A (west, gate at x = -328.2, Keep front door at x = -452)
PATHS_A = [   # (half width, polyline)
    (5.0, [(-333, 0), (-352, 1.5), (-372, -1.5), (-392, 1), (-412, -1), (-440, 0)]),    # main street
    (6.0, [(-438, 0), (-452, 0)]),                                                        # Keep stoop
    (4.5, [(-444, -46), (-445, -20), (-443, 0), (-445, 22), (-439, 37)]),                 # lane across the Keep front
    (3.5, [(-368, -2), (-369.5, -20), (-367, -38), (-366.5, -50)]),                       # Fletcher
    (3.5, [(-426, -3), (-428, -24), (-426, -50)]),                                        # Alchemist
    (3.5, [(-443, -40), (-457, -44.5), (-469, -48)]),                                     # Barracks
    (3.5, [(-378, 2), (-375.5, 22), (-377, 46)]),                                         # Carpenter
    (4.0, [(-418, 2), (-420, 15), (-418, 29)]),                                           # Blacksmith forecourt
]
SQUARES_A = [(-429.0, 0.0, 12.5)]   # small square before the Keep: x, z, radius
BOX_A = dict(x0=-476, x1=-326, z0=-56, z1=56)


def _mirror(paths, squares, box):
    return ([(h, [(-x, z) for x, z in pts]) for h, pts in paths],
            [(-x, z, r) for x, z, r in squares],
            dict(x0=-box["x1"], x1=-box["x0"], z0=box["z0"], z1=box["z1"]))


CASTLES = {"A": (PATHS_A, SQUARES_A, BOX_A), "B": _mirror(PATHS_A, SQUARES_A, BOX_A)}


def _seg(px, pz, ax, az, bx, bz):
    dx, dz = bx - ax, bz - az
    t = max(0.0, min(1.0, ((px - ax) * dx + (pz - az) * dz) / (dx * dx + dz * dz)))
    return math.hypot(px - ax - t * dx, pz - az - t * dz)


def field(x, z, paths, squares):
    """Positive inside the paving. Noise is sampled at |x|, so Castle B mirrors Castle A."""
    ax = abs(x)
    wobble = 0.55 * noise.noise((ax / 7.3, z / 7.3, 1.7)) + 0.3 * noise.noise((ax / 2.9, z / 2.9, 8.2))
    best = -1e9
    for half, pts in paths:
        for a, b in zip(pts, pts[1:]):
            best = max(best, half + wobble - _seg(x, z, a[0], a[1], b[0], b[1]))
    for sx, sz, r in squares:
        best = max(best, r + 1.2 * wobble - math.hypot(x - sx, z - sz))
    return best


def _mesh(name, paths, squares, box):
    nx, nz = int((box["x1"] - box["x0"]) / STEP), int((box["z1"] - box["z0"]) / STEP)
    F = [[field(box["x0"] + i * STEP, box["z0"] + k * STEP, paths, squares) for k in range(nz + 1)]
         for i in range(nx + 1)]
    bm = bmesh.new()
    cache = {}

    def vert(x, y, z):   # Roblox coordinates in, Blender vertex out
        key = (round(x, 3), round(y, 3), round(z, 3))
        v = cache.get(key)
        if v is None:
            v = bm.verts.new((x, -z, y))
            cache[key] = v
        return v

    def face(vs):
        try:
            bm.faces.new(vs)
        except ValueError:   # duplicate face; skip
            pass

    y_top, y_bot = GROUND + TOP, GROUND - SKIRT
    for i in range(nx):
        for k in range(nz):
            corners = [(i, k), (i, k + 1), (i + 1, k + 1), (i + 1, k)]
            vals = [F[c[0]][c[1]] for c in corners]
            if not any(v > 0 for v in vals):
                continue
            poly = []   # (x, z, on_contour)
            for n in range(4):
                c, v = corners[n], vals[n]
                c2, v2 = corners[(n + 1) % 4], vals[(n + 1) % 4]
                x1, z1 = box["x0"] + c[0] * STEP, box["z0"] + c[1] * STEP
                if v > 0:
                    poly.append((x1, z1, False))
                if (v > 0) != (v2 > 0):
                    t = v / (v - v2)
                    x2, z2 = box["x0"] + c2[0] * STEP, box["z0"] + c2[1] * STEP
                    poly.append((x1 + (x2 - x1) * t, z1 + (z2 - z1) * t, True))
            if len(poly) < 3:
                continue
            top = [vert(p[0], y_top, p[1]) for p in poly]
            for n in range(1, len(top) - 1):
                face([top[0], top[n], top[n + 1]])
            for n in range(len(poly)):
                p, q = poly[n], poly[(n + 1) % len(poly)]
                if p[2] and q[2]:
                    pt, qt = vert(p[0], y_top, p[1]), vert(q[0], y_top, q[1])
                    pb, qb = vert(p[0], y_bot, p[1]), vert(q[0], y_bot, q[1])
                    face([pt, qt, qb, pb])
    # one connected sheet (top and sides share vertices): make the winding consistent
    bm.faces.ensure_lookup_table()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # recalc can flip the open sheet as a whole; the top must face up (Blender +Z)
    tops = [f for f in bm.faces if abs(f.normal.z) > 0.9]
    if tops and sum(f.normal.z for f in tops) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [False] * len(me.polygons))
    return me


def build():
    old = bpy.data.scenes.get("VillagePaths")
    if old:
        for o in list(old.objects):
            bpy.data.objects.remove(o)
        bpy.data.scenes.remove(old)
    scene = bpy.data.scenes.new("VillagePaths")
    result = {}
    for team, (paths, squares, box) in CASTLES.items():
        name = team + "_VillagePaths"
        me = _mesh(name, paths, squares, box)
        o = bpy.data.objects.new(name, me)
        o["traces_to"] = "REALISM-TARGET.md: village paths in Castle %s (layout.json v2.2 interior)" % team
        scene.collection.objects.link(o)
        lo = [min(v.co[a] for v in me.vertices) for a in range(3)]
        hi = [max(v.co[a] for v in me.vertices) for a in range(3)]
        result[name] = dict(tris=sum(len(p.vertices) - 2 for p in me.polygons),
                            bbox_centre_roblox=((lo[0] + hi[0]) / 2, (lo[2] + hi[2]) / 2, -(lo[1] + hi[1]) / 2))
    return dict(scene=scene, objects=result)


def export(path):
    scene = bpy.data.scenes["VillagePaths"]
    view_layer = scene.view_layers[0]
    win = bpy.context.window
    prev = win.scene
    try:
        win.scene = scene
        for x in scene.objects:
            x.select_set(True, view_layer=view_layer)
        view_layer.objects.active = scene.objects[0]
        with bpy.context.temp_override(window=win, scene=scene, view_layer=view_layer):
            bpy.ops.export_scene.fbx(   # same settings as battlefield.fbx
                filepath=path, use_selection=True, object_types={"MESH"},
                axis_forward="-Z", axis_up="Y", bake_space_transform=True,
                apply_scale_options="FBX_SCALE_ALL", mesh_smooth_type="FACE",
                use_mesh_modifiers=True, add_leaf_bones=False, bake_anim=False, path_mode="STRIP")
    finally:
        win.scene = prev
    return path


bpy.app.driver_namespace["village_paths"] = dict(build=build, export=export, field=field)
