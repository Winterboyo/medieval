"""Village paths inside Castle A, as one mesh for Roblox (REALISM-TARGET.md, proof of look).

Run inside Blender with __file__ set, then bpy.app.driver_namespace["village_paths"]["build"]()
and ["export"](path). Writes one object, A_VillagePaths, for the v2.0 battlefield import.

The street network is ONE mesh so the herringbone texture (MaterialVariant VillageHerringbone,
assets/textures/build_herringbone.py, box-projected by Roblox) runs unbroken through every
junction. It is a main street from the gate to the Keep with a small square before it, a lane
across the Keep front into the forge forecourt, and a branch to every door. Door positions:
layout.json v2.1 interior, shifted +140 in x onto the v2.0 import's castle centre (-280, 0).
Edges are crisp and slightly irregular (marching squares on a distance field with noise), and the
top sits TOP studs above the flat courtyard, with a short side face, like The Forge's paved pads.

Coordinates below are Roblox (x, z); Roblox (x, y, z) is Blender (x, -z, y).
"""
import bpy, bmesh, math
from mathutils import noise

GROUND = 10.0         # the courtyard terrain is flat at this height
TOP = 0.2             # paving surface above the ground
SKIRT = 0.5           # side face depth below the ground
STEP = 1.0            # marching-squares grid, studs
BOX = dict(x0=-336, x1=-186, z0=-56, z1=56)

PATHS = [   # (half width, polyline)
    (5.0, [(-193, 0), (-212, 1.5), (-232, -1.5), (-252, 1), (-272, -1), (-300, 0)]),    # main street
    (6.0, [(-298, 0), (-312, 0)]),                                                        # Keep stoop
    (4.5, [(-304, -46), (-305, -20), (-303, 0), (-305, 22), (-299, 37)]),                 # lane across the Keep front
    (3.5, [(-228, -2), (-229.5, -20), (-227, -38), (-226.5, -50)]),                       # Fletcher
    (3.5, [(-286, -3), (-288, -24), (-286, -50)]),                                        # Alchemist
    (3.5, [(-303, -40), (-317, -44.5), (-329, -48)]),                                     # Barracks
    (3.5, [(-238, 2), (-235.5, 22), (-237, 46)]),                                         # Carpenter
    (4.0, [(-278, 2), (-280, 15), (-278, 29)]),                                           # Blacksmith forecourt
]
SQUARES = [(-289.0, 0.0, 12.5)]   # small square before the Keep: x, z, radius


def _seg(px, pz, ax, az, bx, bz):
    dx, dz = bx - ax, bz - az
    t = max(0.0, min(1.0, ((px - ax) * dx + (pz - az) * dz) / (dx * dx + dz * dz)))
    return math.hypot(px - ax - t * dx, pz - az - t * dz)


def field(x, z):
    """Positive inside the paving."""
    wobble = 0.55 * noise.noise((x / 7.3, z / 7.3, 1.7)) + 0.3 * noise.noise((x / 2.9, z / 2.9, 8.2))
    best = -1e9
    for half, pts in PATHS:
        for a, b in zip(pts, pts[1:]):
            best = max(best, half + wobble - _seg(x, z, a[0], a[1], b[0], b[1]))
    for sx, sz, r in SQUARES:
        best = max(best, r + 1.2 * wobble - math.hypot(x - sx, z - sz))
    return best


def build():
    old = bpy.data.scenes.get("VillagePaths")
    if old:
        for o in list(old.objects):
            bpy.data.objects.remove(o)
        bpy.data.scenes.remove(old)
    scene = bpy.data.scenes.new("VillagePaths")
    nx, nz = int((BOX["x1"] - BOX["x0"]) / STEP), int((BOX["z1"] - BOX["z0"]) / STEP)
    F = [[field(BOX["x0"] + i * STEP, BOX["z0"] + k * STEP) for k in range(nz + 1)] for i in range(nx + 1)]
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
                x1, z1 = BOX["x0"] + c[0] * STEP, BOX["z0"] + c[1] * STEP
                if v > 0:
                    poly.append((x1, z1, False))
                if (v > 0) != (v2 > 0):
                    t = v / (v - v2)
                    x2, z2 = BOX["x0"] + c2[0] * STEP, BOX["z0"] + c2[1] * STEP
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
    me = bpy.data.meshes.new("A_VillagePaths")
    bm.to_mesh(me)
    bm.free()
    me.polygons.foreach_set("use_smooth", [False] * len(me.polygons))
    o = bpy.data.objects.new("A_VillagePaths", me)
    o["traces_to"] = "REALISM-TARGET.md Phase 1: village paths in Castle A (layout.json v2.1 doors, +140 x)"
    scene.collection.objects.link(o)
    lo = [min(v.co[a] for v in me.vertices) for a in range(3)]
    hi = [max(v.co[a] for v in me.vertices) for a in range(3)]
    centre_rb = ((lo[0] + hi[0]) / 2, (lo[2] + hi[2]) / 2, -(lo[1] + hi[1]) / 2)
    return dict(scene=scene, obj=o, tris=sum(len(p.vertices) - 2 for p in me.polygons),
                verts=len(me.vertices), bbox_centre_roblox=centre_rb)


def export(path):
    scene = bpy.data.scenes["VillagePaths"]
    view_layer = scene.view_layers[0]
    o = scene.objects["A_VillagePaths"]
    win = bpy.context.window
    prev = win.scene
    try:
        win.scene = scene
        for x in scene.objects:
            x.select_set(x is o, view_layer=view_layer)
        view_layer.objects.active = o
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
