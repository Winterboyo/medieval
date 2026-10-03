"""Original stylised skybox for the battlefield, in its own Blender scene ("Skybox").

Run inside Blender with __file__ set, then bpy.app.driver_namespace["sky"]["build"]()
and bpy.app.driver_namespace["sky"]["render"](out_dir). Writes Ft/Bk/Lf/Rt/Up/Dn.png.

Look: the concept image's golden-hour family. A smooth painted gradient (warm cream at
the horizon to soft blue overhead), a golden glow where Roblox's sun actually is, a cooler
lavender band opposite it, and faceted low-poly cumulus near the horizon lit warm on the
sun side with lavender shadows. Everything is emission with per-vertex / per-face colour,
so the render is exactly the painted colours (Standard view transform, no lights).

Sun: Lighting.ClockTime 16.4 at GeographicLatitude -12 (set in src/server/VisualQuality
.server.luau) gives Lighting:GetSunDirection() = (-0.744, 0.331, -0.581) in Roblox space:
19.3 degrees up, toward north-west, behind Team A's castle seen from the field.

Face layout, measured in Studio 2026-10-03 with a colour-coded test cube:
  Ft looks -Z, Bk +Z, Lf +X, Rt -X (all upright, seen from inside, not mirrored);
  Up: image top toward +X, image left toward +Z;  Dn: hidden by the sea, one colour.
Roblox (x, y, z) is Blender (x, -z, y).
"""
import bpy, bmesh, math, os, random
from mathutils import Vector, Matrix

SEED = 20261003
SIZE = 1024
SUN_RB = Vector((-0.744, 0.331, -0.581))                    # Roblox space
SUN = Vector((SUN_RB.x, -SUN_RB.z, SUN_RB.y)).normalized()   # Blender space

# sRGB 0-255
ZENITH = (92, 146, 212)
UPPER = (128, 178, 228)      # ~35 degrees up
HORIZON = (236, 226, 204)    # warm cream at the horizon
BELOW = (176, 190, 206)      # under the horizon; hidden by the sea in game
SUN_GLOW = (255, 196, 128)   # broad golden glow toward the sun
SUN_HALO = (255, 238, 206)   # tight halo round the sun disc Roblox draws
ANTI = (196, 202, 228)       # cooler, lavender horizon away from the sun
CLOUD_LIT = (255, 252, 244)
CLOUD_WARM = (255, 220, 172)
CLOUD_SHADE = (206, 208, 228)
CLOUD_BASE = (214, 212, 228)


def mix(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def sky_colour(d):
    """Colour of the sky in Blender direction d (unit)."""
    e = math.degrees(math.asin(max(-1.0, min(1.0, d.z))))
    if e < 0:
        base = mix(HORIZON, BELOW, smooth(-e / 8.0))
    elif e < 35:
        base = mix(HORIZON, UPPER, smooth(e / 35.0) ** 0.8)
    else:
        base = mix(UPPER, ZENITH, smooth((e - 35) / 55.0))
    c = max(0.0, d.dot(SUN))
    low = 1.0 - smooth(max(0.0, e) / 55.0)
    base = mix(base, SUN_GLOW, (c ** 5) * 0.62 * low)
    base = mix(base, SUN_HALO, (c ** 60) * 0.75)
    away = (1.0 - d.dot(SUN)) / 2.0
    base = mix(base, ANTI, away * 0.45 * (1.0 - smooth(abs(e) / 25.0)))
    return base


def emission_material(name):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    try:
        m.use_nodes = True
    except Exception:
        pass
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    attr = nt.nodes.new("ShaderNodeVertexColor")
    attr.layer_name = "Col"
    nt.links.new(attr.outputs[0], em.inputs["Color"])
    em.inputs["Strength"].default_value = 1.0
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    return m


def colour_layer(me, colours_per_loop):
    attr = me.color_attributes.new("Col", "BYTE_COLOR", "CORNER")
    flat = []
    for c in colours_per_loop:
        flat.extend((c[0] / 255, c[1] / 255, c[2] / 255, 1.0))
    attr.data.foreach_set("color_srgb", flat)


def build_dome(coll, mat):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=192, v_segments=96, radius=4000.0)
    bmesh.ops.reverse_faces(bm, faces=bm.faces)
    me = bpy.data.meshes.new("Sky_Dome")
    bm.to_mesh(me)
    bm.free()
    cols = []
    for poly in me.polygons:
        for li in range(poly.loop_start, poly.loop_start + poly.loop_total):
            v = me.vertices[me.loops[li].vertex_index].co.normalized()
            cols.append(sky_colour(v))
    colour_layer(me, cols)
    me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
    me.materials.append(mat)
    o = bpy.data.objects.new("Sky_Dome", me)
    coll.objects.link(o)
    return o


def build_clouds(coll, mat, rng):
    """Faceted cumulus: clusters of lumpy icospheres with flat bottoms, on a shell
    inside the dome, mostly low over the horizon."""
    bm = bmesh.new()
    face_cols = []
    clusters = []
    for k in range(64):
        az = rng.uniform(0, 2 * math.pi)
        elev = math.radians(rng.choice([rng.uniform(2.0, 8), rng.uniform(2.0, 8), rng.uniform(5, 16), rng.uniform(12, 30), rng.uniform(25, 48)]))
        clusters.append((az, elev))
    for az, elev in clusters:
        dist = 2600.0
        centre = Vector((math.cos(az) * math.cos(elev), math.sin(az) * math.cos(elev), math.sin(elev))) * dist
        # local frame: tangent along the horizon, world up
        side = Vector((-math.sin(az), math.cos(az), 0))
        width = rng.uniform(220, 520) * (0.55 + 0.45 * math.cos(elev))
        base_z = centre.z - width * 0.18
        for j in range(rng.randint(5, 10)):
            r = width * rng.uniform(0.22, 0.42) * (1.0 - 0.12 * j / 8)
            off = side * rng.uniform(-width * 0.55, width * 0.55)
            p = centre + off + Vector((0, 0, r * rng.uniform(0.05, 0.6)))
            res = bmesh.ops.create_icosphere(bm, subdivisions=2, radius=r)
            vs = res["verts"]
            for v in vs:
                n = v.co.normalized()
                jitter = 1.0 + rng.uniform(-0.09, 0.09)
                co = v.co * jitter
                co.z *= 0.72
                co += p
                if co.z < base_z:
                    co.z = base_z + rng.uniform(0, r * 0.03)   # flat underside
                v.co = co
    bm.normal_update()
    me = bpy.data.meshes.new("Sky_Clouds")
    bm.to_mesh(me)
    bm.free()
    cols = []
    for poly in me.polygons:
        n = poly.normal
        centre = poly.center
        d = centre.normalized()
        e = math.degrees(math.asin(max(-1.0, min(1.0, d.z))))
        lam = max(0.0, n.dot(SUN))
        if n.z < -0.6:
            c = CLOUD_BASE
        else:
            c = mix(CLOUD_SHADE, CLOUD_LIT, smooth(lam * 1.4 + 0.45 * max(0.0, n.z) + 0.15))
            c = mix(c, CLOUD_WARM, (max(0.0, d.dot(SUN)) ** 3) * 0.55 * smooth(lam * 2))
        # aerial perspective: low clouds sink into the horizon colour
        c = mix(c, sky_colour(d), 0.3 * (1.0 - smooth(e / 10.0)))
        cols.extend([c] * poly.loop_total)
    colour_layer(me, cols)
    me.polygons.foreach_set("use_smooth", [False] * len(me.polygons))
    me.materials.append(mat)
    o = bpy.data.objects.new("Sky_Clouds", me)
    coll.objects.link(o)
    return o


FACES = {   # Blender forward, Blender up (see the module docstring)
    "Ft": (Vector((0, 1, 0)), Vector((0, 0, 1))),
    "Bk": (Vector((0, -1, 0)), Vector((0, 0, 1))),
    "Lf": (Vector((1, 0, 0)), Vector((0, 0, 1))),
    "Rt": (Vector((-1, 0, 0)), Vector((0, 0, 1))),
    "Up": (Vector((0, 0, 1)), Vector((1, 0, 0))),
}


def camera_matrix(forward, up):
    right = forward.cross(up).normalized()
    up = right.cross(forward).normalized()
    m = Matrix((right, up, -forward)).transposed()
    return m.to_4x4()


def build():
    old = bpy.data.scenes.get("Skybox")
    if old:
        for o in list(old.objects):
            bpy.data.objects.remove(o)
        bpy.data.scenes.remove(old)
    scene = bpy.data.scenes.new("Skybox")
    coll = scene.collection
    mat = emission_material("Sky_Emission")
    rng = random.Random(SEED)
    build_dome(coll, mat)
    build_clouds(coll, mat, rng)
    cam_data = bpy.data.cameras.new("Sky_Camera")
    cam_data.type = "PERSP"
    cam_data.sensor_fit = "HORIZONTAL"
    cam_data.angle = math.radians(90.0)
    cam_data.clip_start = 1.0
    cam_data.clip_end = 10000.0
    cam = bpy.data.objects.new("Sky_Camera", cam_data)
    coll.objects.link(cam)
    scene.camera = cam
    r = scene.render
    r.resolution_x = r.resolution_y = SIZE
    r.resolution_percentage = 100
    r.image_settings.file_format = "PNG"
    r.image_settings.color_mode = "RGB"
    try:
        r.engine = "BLENDER_EEVEE_NEXT"
    except TypeError:
        r.engine = "BLENDER_EEVEE"
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0.0
    scene.view_settings.gamma = 1.0
    try:
        r.filter_size = 0.8
    except Exception:
        pass
    world = bpy.data.worlds.get("Sky_World") or bpy.data.worlds.new("Sky_World")
    scene.world = world
    return scene


def render(out_dir):
    scene = bpy.data.scenes["Skybox"]
    os.makedirs(out_dir, exist_ok=True)
    cam = scene.camera
    win = bpy.context.window
    prev = win.scene
    win.scene = scene
    try:
        for name, (fwd, up) in FACES.items():
            cam.matrix_world = camera_matrix(fwd, up)
            scene.render.filepath = os.path.join(out_dir, name + ".png")
            bpy.ops.render.render(write_still=True, scene=scene.name)
    finally:
        win.scene = prev
    # Dn: one colour, the under-horizon tone (the sea always covers it). Full SIZE like the
    # other faces: a smaller face broke Roblox's environment-lighting cubemap (magenta cast).
    img = bpy.data.images.new("Sky_Dn", SIZE, SIZE, alpha=False)
    c = [v / 255 for v in BELOW]
    img.pixels = [c[0], c[1], c[2], 1.0] * (SIZE * SIZE)
    img.filepath_raw = os.path.join(out_dir, "Dn.png")
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)
    return sorted(os.listdir(out_dir))


bpy.app.driver_namespace["sky"] = dict(build=build, render=render, sky_colour=sky_colour)
