"""Two-castle map terrain, built AROUND layout.json, in its own Blender scene ("Map").

Run inside Blender (Text Editor > Run Script, or exec() over the MCP bridge with
__file__ set), then call bpy.app.driver_namespace["map"]["build"]().

Roblox is Y-up, Blender is Z-up: (x, y, z)_roblox -> (x, -z, y)_blender.
1 unit = 1 stud. Everything placed here traces to a layout.json entry or to a
rule in CLAUDE.md §6; every object carries a "traces_to" custom property, and
audit() lists (and deletes) anything in the scene that does not.

What it builds (CLAUDE.md §6):
- An island: land fills map_bounds, a faceted coast lies beyond the boundary
  wall, sea outside. No mountains, no water inside the playable area.
- A flat pad under both castles (the layout's pad square) and under every node
  slot (the layout's pad_radius). Pads only: which node type stands on a slot is
  chosen per match, so node props (including Wood's round-canopy trees) are not
  part of the terrain.
- A sand approach lane in front of each gate, kept clear.
- Decorative stacked-cone pines only in the edge belt and the cover zones.
- The whole thing MIRRORED across x = 0: ground ripples, coast wobble and pines
  are generated for the west half and reflected, so both castles see the same map.

Colours are per-face (CORNER-domain byte colour attribute "Col"), sampled from
references/terrain-meadow.jpg. Layout markers are a separate, verification-only
collection (Layout_Markers) and are not part of the map.
"""
import bpy, json, math, os, random
from mathutils import Vector, Euler

_HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
LAYOUT = os.path.normpath(os.path.join(_HERE, "..", "..", "layout.json"))
SEED = 20260930

SRGB = {
    "GRASS": (124, 146, 82),
    "GRASS_2": (107, 123, 64),     # second tone (terrain-meadow's foreground grass), GRASS_2_SHARE of grass facets
    "SAND": (169, 149, 92),        # beach, pads, approach lanes
    "WATER": (162, 179, 194),      # shallows
    "SEA_DEEP": (89, 115, 166),    # open sea (the reference has none: its upper sky)
    "ROCK": (109, 103, 127),       # only on steep ground
    "PINE": (56, 60, 45),
    "TRUNK": (81, 59, 61),
}
MARKER = {   # verification overlay only, not terrain
    "castle": (235, 40, 40), "gate": (255, 215, 0), "lane": (255, 215, 0), "spawn_A": (255, 90, 90),
    "spawn_B": (90, 140, 255), "stockpile": (255, 255, 255), "home": (0, 220, 120), "mid": (0, 200, 255),
    "forward": (255, 130, 0), "center": (200, 0, 255), "cover": (120, 255, 60), "boundary": (255, 0, 255),
    "axis": (255, 255, 255), "origin": (255, 0, 255),
}

HALF_X, HALF_Y = 672.0, 480.0     # terrain half-extents (Blender), centred on the origin
SPACING = 11.0                    # typical facet size on land (subtle low-poly)
SPACING_SEA = 30.0                # seabed facets, hidden under the water
RELIEF = 1.5                      # undulation strength away from pads, so facets catch the light
GRASS_2_SHARE = 0.15              # share of grass facets in the second tone: enough to break it up, not camouflage
TILES = 4
SEA_LEVEL, SHORE_H, SEABED = 0.0, 0.6, -20.0
SEA_HALF = 1000.0                 # deep-sea plane is 2,000 square: under Roblox's 2,048-stud part limit
COAST_MARGIN, COAST_RADIUS = 60.0, 150.0   # coast rounded rect: encloses the boundary wall with 30 to spare
COAST_BLEND = 70.0
BEACH = 36.0              # sand band inland of the waterline: the boundary wall (30 out) stands on it
PAD_BLEND = 40.0


def rb(x, y, z):
    """Roblox (x, y, z) -> Blender (x, y, z)."""
    return (x, -z, y)


def smooth(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


# ------------------------------------------------------------------ layout -> pads, lanes, cover
def load_layout():
    with open(LAYOUT, encoding="utf-8") as f:
        L = json.load(f)
    pads, lanes, cover = [], [], []
    for c in L["castles"]:
        cx, cy, _ = rb(c["center"]["x"], 0, c["center"]["z"])
        pads.append(dict(kind="castle", id=c["id"], team=c["team"], cx=cx, cy=cy, shape="square",
                         half=c["pad"]["size"] / 2, inner=c["ring_size"]["x"] / 2, h=c["pad"]["y"]))
    for s in L["resource_node_slots"]:
        cx, cy, _ = rb(s["position"]["x"], 0, s["position"]["z"])
        pads.append(dict(kind="node", id=s["id"], ring=s["ring"], cx=cx, cy=cy, shape="circle",
                         r=s["pad_radius"], inner=s["pad_radius"] - 8.0, h=s["position"]["y"]))
    for l in L["gate_approach_lanes"]:
        gx, gy, _ = rb(l["from"]["x"], 0, l["from"]["z"])
        dx, dy, _ = rb(l["direction"]["x"], 0, l["direction"]["z"])
        n = math.hypot(dx, dy)
        lanes.append(dict(id=l["id"], castle=l["castle"], gx=gx, gy=gy, dx=dx / n, dy=dy / n,
                          width=l["width"], length=l["length"]))
    for z in L["cover_zones"]:
        cover.append(dict(id=z["id"], x0=z["min_x"], x1=z["max_x"], y0=-z["max_z"], y1=-z["min_z"]))
    b = L["map_bounds"]
    bounds = dict(x0=b["min_x"], x1=b["max_x"], y0=-b["max_z"], y1=-b["min_z"])
    return L, pads, lanes, cover, bounds


def pad_dist(p, x, y):
    """Distance from (x, y) to the pad's edge; 0 inside."""
    if p["shape"] == "square":
        dx = max(0.0, abs(x - p["cx"]) - p["half"]); dy = max(0.0, abs(y - p["cy"]) - p["half"])
        return math.hypot(dx, dy)
    return max(0.0, math.hypot(x - p["cx"], y - p["cy"]) - p["r"])


def in_lane(lane, x, y, grow=0.0):
    rx, ry = x - lane["gx"], y - lane["gy"]
    along = rx * lane["dx"] + ry * lane["dy"]
    side = -rx * lane["dy"] + ry * lane["dx"]
    return -grow <= along <= lane["length"] + grow and abs(side) <= lane["width"] / 2 + grow


def in_cover(z, x, y, shrink=0.0):
    return z["x0"] + shrink <= x <= z["x1"] - shrink and z["y0"] + shrink <= y <= z["y1"] - shrink


def rounded_rect_sdf(x, y, cx, cy, hx, hy, radius):
    qx = abs(x - cx) - (hx - radius); qy = abs(y - cy) - (hy - radius)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius


# ------------------------------------------------------------------ coast (mirrored)
def make_coast(bounds, rng):
    cx, cy = (bounds["x0"] + bounds["x1"]) / 2, (bounds["y0"] + bounds["y1"]) / 2
    hx = (bounds["x1"] - bounds["x0"]) / 2 + COAST_MARGIN
    hy = (bounds["y1"] - bounds["y0"]) / 2 + COAST_MARGIN
    knots = [rng.uniform(0, 24) for _ in range(37)]      # east half only; the west half is its mirror

    def wobble(x, y):
        a = math.atan2(y - cy, abs(x - cx))                # -pi/2 .. pi/2, same for x and -x
        t = (a + math.pi / 2) / math.pi * (len(knots) - 1)
        i = min(int(t), len(knots) - 2); f = t - i
        return knots[i] * (1 - f) + knots[i + 1] * f

    def inland(x, y):
        return wobble(x, y) - rounded_rect_sdf(x, y, cx, cy, hx, hy, COAST_RADIUS)

    def outline(push=0.0, n=160):
        """Points on the coast pushed `push` out to sea. n even, so the set is mirrored."""
        pts = []
        for i in range(n):
            a = 2 * math.pi * i / n
            dx, dy = math.cos(a), math.sin(a)
            lo, hi = 0.0, 4000.0
            for _ in range(40):
                mid = (lo + hi) / 2
                if inland(cx + dx * mid, cy + dy * mid) > -push:
                    lo = mid
                else:
                    hi = mid
            pts.append((cx + dx * lo, cy + dy * lo))
        return pts
    return inland, outline


# ------------------------------------------------------------------ height (mirrored)
def undulation(x, y):
    x = abs(x)
    return (0.6 * math.sin(x / 71 + 0.7) * math.cos(y / 83 - 0.4)
            + 0.4 * math.sin((x + y) / 57 + 1.3) + 0.3 * math.cos((x - 1.7 * y) / 109))


def make_height(pads, inland):
    def land(x, y):
        best, bd, wsum, hsum = None, 1e9, 0.0, 0.0
        for p in pads:
            d = pad_dist(p, x, y)
            if d < bd:
                best, bd = p, d
            w = 1.0 / (d + 25.0) ** 2.5
            wsum += w; hsum += w * p["h"]
        if bd == 0.0:
            return best["h"]
        t = smooth(0, PAD_BLEND, bd)
        far = hsum / wsum + undulation(x, y) * RELIEF * t
        return best["h"] * (1 - t) + far * t

    def height(x, y):
        s = inland(x, y)
        if s < 0:
            return SHORE_H + (SEABED - SHORE_H) * smooth(0, 45, -s)
        h = land(x, y)
        if s < COAST_BLEND:
            h = SHORE_H + (h - SHORE_H) * smooth(0, COAST_BLEND, s)
        return h
    return height


# ------------------------------------------------------------------ mesh helpers
def lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def material(name, emissive=False):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    try:
        m.use_nodes = True
    except Exception:
        pass
    nt = m.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    vc = next((n for n in nt.nodes if n.type == "VERTEX_COLOR"), None) or nt.nodes.new("ShaderNodeVertexColor")
    vc.layer_name = "Col"
    nt.links.new(vc.outputs[0], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 1.0
    spec = bsdf.inputs.get("Specular IOR Level")
    if spec is not None:
        spec.default_value = 0.0
    if emissive:
        em = bsdf.inputs.get("Emission Color")
        if em is not None:
            nt.links.new(vc.outputs[0], em)
            bsdf.inputs["Emission Strength"].default_value = 0.8
    return m


def colour_mesh(name, verts, faces, face_cols, face_smooth, mat, vert_normals=None):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.update()
    attr = me.color_attributes.new("Col", "BYTE_COLOR", "CORNER")
    flat = []
    for poly, c in zip(me.polygons, face_cols):
        flat.extend((c[0] / 255, c[1] / 255, c[2] / 255, 1.0) * poly.loop_total)
    attr.data.foreach_set("color_srgb", flat)
    me.color_attributes.active_color = attr
    me.color_attributes.render_color_index = me.color_attributes.active_color_index
    me.polygons.foreach_set("use_smooth", face_smooth)
    if vert_normals is not None:
        # Smooth faces take the normal of the WHOLE heightfield at each vertex, so
        # tile borders shade continuously; flat faces keep their own face normal.
        loop_normals = []
        for poly, sm in zip(me.polygons, face_smooth):
            for li in range(poly.loop_start, poly.loop_start + poly.loop_total):
                loop_normals.append(vert_normals[me.loops[li].vertex_index] if sm else tuple(poly.normal))
        me.normals_split_custom_set(loop_normals)
    me.materials.append(mat)
    me.update()
    return me


def add_object(coll, name, me, traces_to):
    o = bpy.data.objects.new(name, me)
    o["traces_to"] = traces_to
    coll.objects.link(o)
    return o


def tri_object(coll, name, tris, mat, traces_to, palette=SRGB):
    verts, faces, cols = [], [], []
    for t, col in tris:
        faces.append(tuple(range(len(verts), len(verts) + len(t))))
        verts.extend(t); cols.append(palette[col] if isinstance(col, str) else col)
    me = colour_mesh(name, verts, faces, cols, [False] * len(faces), mat)
    add_object(coll, name, me, traces_to)
    return sum(len(f) - 2 for f in faces)


def tile_of(x, y):
    sx, sy = 2 * HALF_X / TILES, 2 * HALF_Y / TILES
    return (max(0, min(TILES - 1, int((x + HALF_X) // sx))), max(0, min(TILES - 1, int((y + HALF_Y) // sy))))


def face_normal_z(a, b, c):
    n = (Vector(b) - Vector(a)).cross(Vector(c) - Vector(a))
    return abs(n.z) / max(n.length, 1e-9)


# ------------------------------------------------------------------ low-poly ground
def facet_hash(x, y):
    """A repeatable 0..1 value per position, the same at (x, y) and (-x, y)."""
    v = math.sin(abs(round(x, 3)) * 12.9898 + round(y, 3) * 78.233) * 43758.5453
    return v - math.floor(v)


def poisson_points(rng, x0, x1, y0, y1, spacing_at, attempts):
    """Jittered, roughly even points: rejection against a hash grid. spacing_at(x, y)
    gives the local spacing, so the hidden seabed can be coarser than the land."""
    cell = SPACING * 0.75
    grid, pts = {}, []
    for _ in range(attempts):
        x, y = rng.uniform(x0, x1), rng.uniform(y0, y1)
        s = spacing_at(x, y) * 0.75
        gx, gy = int(x // cell), int(y // cell)
        reach = int(s // cell) + 1
        ok = True
        for i in range(gx - reach, gx + reach + 1):
            for j in range(gy - reach, gy + reach + 1):
                for (qx, qy) in grid.get((i, j), ()):
                    if (qx - x) ** 2 + (qy - y) ** 2 < s * s:
                        ok = False; break
                if not ok: break
            if not ok: break
        if ok:
            grid.setdefault((gx, gy), []).append((x, y))
            pts.append((x, y))
    return pts


def west_constraints(pads, lanes):
    """Outlines no triangle may cross, clipped to the west half (x <= 0). Returns
    (points, edges) with edges as index pairs into points."""
    pts, edges = [], []

    def poly(vs, closed=True):
        base = len(pts)
        pts.extend(vs)
        n = len(vs)
        for i in range(n if closed else n - 1):
            edges.append((base + i, base + (i + 1) % n))

    for p in pads:
        if p["shape"] == "square":
            if p["cx"] > 0:
                continue
            h = p["half"]
            poly([(p["cx"] - h, p["cy"] - h), (p["cx"] + h, p["cy"] - h), (p["cx"] + h, p["cy"] + h), (p["cx"] - h, p["cy"] + h)])
        else:
            n = max(16, int(2 * math.pi * p["r"] / 8.0) // 4 * 4)   # multiple of 4: vertices land ON the axis
            ring = []
            for k in range(n):
                a = 2 * math.pi * k / n
                x = p["cx"] + math.cos(a) * p["r"]; y = p["cy"] + math.sin(a) * p["r"]
                if abs(x) < 1e-6:
                    x = 0.0
                ring.append((x, y))
            if p["cx"] < -p["r"]:
                poly(ring)
            elif abs(p["cx"]) < 1e-6:          # straddles the axis: keep the west arc, open
                start = n // 4                  # angle 90 degrees, on the axis
                arc = [ring[(start + k) % n] for k in range(n // 2 + 1)]   # 90 .. 270 degrees, x <= 0
                poly(arc, closed=False)
    for l in lanes:
        if l["gx"] > 0:
            continue
        ex, ey = l["gx"] + l["dx"] * l["length"], l["gy"] + l["dy"] * l["length"]
        w = l["width"] / 2
        poly([(l["gx"] - l["dy"] * w, l["gy"] + l["dx"] * w), (ex - l["dy"] * w, ey + l["dx"] * w),
              (ex + l["dy"] * w, ey - l["dx"] * w), (l["gx"] + l["dy"] * w, l["gy"] - l["dx"] * w)])
    # the west half's own border, including the mirror axis, in 8-stud steps
    border = []
    for k in range(int(HALF_X // 8) + 1):
        border.append((-HALF_X + k * 8, -HALF_Y))
    for k in range(1, int(2 * HALF_Y // 8) + 1):
        border.append((0.0, -HALF_Y + k * 8))
    for k in range(1, int(HALF_X // 8) + 1):
        border.append((-k * 8, HALF_Y))
    for k in range(1, int(2 * HALF_Y // 8)):
        border.append((-HALF_X, HALF_Y - k * 8))
    poly(border)
    return pts, edges


def build_ground_lowpoly(coll, height, inland, pads, lanes, rng, mat):
    """Irregular, flat-shaded triangles (constrained Delaunay) instead of a grid.
    The west half is triangulated with the axis as a constraint, then reflected."""
    from mathutils import geometry
    cpts, cedges = west_constraints(pads, lanes)
    spacing_at = lambda x, y: SPACING if inland(x, y) > -40 else SPACING_SEA
    free = poisson_points(rng, -HALF_X + 2, -2, -HALF_Y + 2, HALF_Y - 2, spacing_at, 60000)
    # keep free points off the outlines so they don't make slivers
    def near_outline(x, y):
        for p in pads:
            d = (abs(math.hypot(x - p["cx"], y - p["cy"]) - p["r"]) if p["shape"] == "circle"
                 else abs(max(abs(x - p["cx"]), abs(y - p["cy"])) - p["half"]))
            if d < 3.0:
                return True
        return any(in_lane(l, x, y, grow=3.0) and not in_lane(l, x, y, grow=-3.0) for l in lanes)
    free = [(x, y) for x, y in free if not near_outline(x, y)]
    coords = [Vector(p) for p in cpts + free]
    out_v, _, out_f, _, _, _ = geometry.delaunay_2d_cdt(coords, cedges, [], 0, 1e-4, True)
    # west half -> both halves. Axis vertices are shared; the reflection reverses winding.
    west = [(v.x, v.y) for v in out_v]
    key = lambda x, y: (round(x, 4), round(y, 4))
    verts, index = [], {}
    def vid(x, y):
        k = key(x, y)
        if k not in index:
            index[k] = len(verts)
            verts.append((x, y))
        return index[k]
    tris = []
    for f in out_f:
        a, b, c = (west[i] for i in f)
        tris.append((vid(*a), vid(*b), vid(*c)))
        tris.append((vid(-a[0], a[1]), vid(-c[0], c[1]), vid(-b[0], b[1])))
    zs = [height(x, y) for x, y in verts]
    V3 = [(x, y, z) for (x, y), z in zip(verts, zs)]
    # colour per face; the grass tone is hashed on |x| so it mirrors too
    buckets = {}
    for t in tris:
        p = [V3[i] for i in t]
        cx = sum(q[0] for q in p) / 3; cy = sum(q[1] for q in p) / 3
        if inland(cx, cy) < BEACH:
            col = "SAND"
        elif any(pad_dist(pd, cx, cy) == 0.0 for pd in pads) or any(in_lane(l, cx, cy) for l in lanes):
            col = "SAND"
        elif face_normal_z(*p) < 0.7:
            col = "ROCK"
        else:
            col = "GRASS_2" if facet_hash(cx, cy) < GRASS_2_SHARE else "GRASS"
        buckets.setdefault(tile_of(cx, cy), []).append((t, col))
    stats = {}
    for (ti, tj), items in sorted(buckets.items()):
        used = sorted({i for t, _ in items for i in t})
        remap = {old: new for new, old in enumerate(used)}
        tv = [V3[i] for i in used]
        tf = [tuple(remap[i] for i in t) for t, _ in items]
        cols = [SRGB[c] for _, c in items]
        name = "Terrain_Tile_%d_%d" % (ti, tj)
        me = colour_mesh(name, tv, tf, cols, [False] * len(tf), mat)
        add_object(coll, name, me, "rule §6: terrain around layout.json (pads, lanes, map_bounds)")
        stats[name] = len(tf)
    return stats, V3, tris


# ------------------------------------------------------------------ sea
def build_sea(coll, outline, inland, rng, mat):
    """Deep sea: one flat plane. Shallows: irregular faceted triangles with a small
    height jitter, so the water catches light in facets like the references."""
    from mathutils import geometry
    s = SEA_HALF
    verts = [(-s, -s, SEA_LEVEL), (s, -s, SEA_LEVEL), (s, s, SEA_LEVEL), (-s, s, SEA_LEVEL)]
    faces, cols = [(0, 1, 2), (0, 2, 3)], [SRGB["SEA_DEEP"]] * 2
    rim = outline(push=30.0)
    xs = [p[0] for p in rim]; ys = [p[1] for p in rim]
    inner = poisson_points(rng, min(xs), max(xs), min(ys), max(ys), lambda x, y: 16.0, 30000)
    inner = [(x, y) for x, y in inner if -28 < inland(x, y) < 12]     # the ring itself, not under the island
    coords = [Vector(p) for p in rim] + [Vector(p) for p in inner]
    ring_edges = [(i, (i + 1) % len(rim)) for i in range(len(rim))]
    out_v, _, out_f, _, _, _ = geometry.delaunay_2d_cdt(coords, ring_edges, [list(range(len(rim)))], 1, 1e-4, True)
    c0 = len(verts)
    verts += [(v.x, v.y, SEA_LEVEL + 0.05 + (facet_hash(v.x, v.y) - 0.5) * 0.3) for v in out_v]
    faces += [tuple(c0 + i for i in f) for f in out_f]
    cols += [SRGB["WATER"]] * len(out_f)
    me = colour_mesh("Sea", verts, faces, cols, [False] * len(faces), mat)
    add_object(coll, "Sea", me, "rule §6.5: sea around the island, outside the playable area")
    return {"Sea": sum(len(f) - 2 for f in faces)}


# ------------------------------------------------------------------ pines (mirrored)
def trunk(x, y, z, w, top):
    q = [(x - w, y - w), (x + w, y - w), (x + w, y + w), (x - w, y + w)]
    out = []
    for i in range(4):
        a, b = q[i], q[(i + 1) % 4]
        out.append((((a[0], a[1], z - 0.5), (b[0], b[1], z - 0.5), (b[0], b[1], top)), "TRUNK"))
        out.append((((a[0], a[1], z - 0.5), (b[0], b[1], top), (a[0], a[1], top)), "TRUNK"))
    return out


def pine(x, y, z, s, rot):
    tris = trunk(x, y, z, 0.35 * s, z + 4.5 * s)
    for rad, z0, hh in ((4.4, 3.2, 6.8), (3.4, 7.2, 6.0), (2.3, 10.8, 5.4)):
        ring = [(x + math.cos(rot + 2 * math.pi * i / 6) * rad * s, y + math.sin(rot + 2 * math.pi * i / 6) * rad * s, z + z0 * s) for i in range(6)]
        apex = (x, y, z + (z0 + hh) * s)
        for i in range(6):
            tris.append(((ring[i], ring[(i + 1) % 6], apex), "PINE"))
        for i in range(1, 5):
            tris.append(((ring[0], ring[i + 1], ring[i]), "PINE"))
    return tris


def build_pines(coll, height, inland, pads, lanes, cover, bounds, belt, rng, mat):
    def edge_depth(x, y):
        return min(x - bounds["x0"], bounds["x1"] - x, y - bounds["y0"], bounds["y1"] - y)

    def blocked(x, y, cr):
        if inland(x, y) < BEACH + 6:
            return True
        if any(pad_dist(p, x, y) < cr + 2 for p in pads):
            return True
        return any(in_lane(l, x, y, grow=cr + 1) for l in lanes)

    west = []   # authored on the west half only, then mirrored

    def plant(x, y, why):
        if x > -4:   # keep a strip clear on the axis so mirrored copies never overlap
            return
        s = rng.uniform(0.9, 1.4)
        cr = 4.4 * s
        if blocked(x, y, cr) or any(math.hypot(x - px_, y - py_) < 6.5 for px_, py_, _, _, _ in west):
            return
        west.append((x, y, s, rng.uniform(0, math.pi), why))

    # 1. the edge belt, as GROUPS with open ground between them (the reference's
    #    pines stand in stands, not in a continuous hedge round the map)
    clusters = 0
    for _ in range(2000):
        if clusters >= 26:
            break
        cx = rng.uniform(bounds["x0"] - 10, -30)
        cy = rng.uniform(bounds["y0"] - 10, bounds["y1"] + 10)
        if edge_depth(cx, cy) > belt - 10 or blocked(cx, cy, 6):
            continue
        clusters += 1
        radius = rng.uniform(9, 20)
        for _ in range(rng.randint(4, 9)):
            a, d = rng.uniform(0, 2 * math.pi), radius * math.sqrt(rng.uniform(0, 1))
            x, y = cx + math.cos(a) * d, cy + math.sin(a) * d
            if edge_depth(x, y) <= belt:
                plant(x, y, "rule §6.5: pine belt near map edge")
    for z in cover:                                        # 2. inside each west cover zone
        if z["x1"] > 0:
            continue
        for _ in range(40):
            plant(rng.uniform(z["x0"] + 4, z["x1"] - 4), rng.uniform(z["y0"] + 4, z["y1"] - 4),
                  "layout.json cover_zones " + z["id"])

    placed = []
    for x, y, s, rot, why in west:
        placed.append((x, y, s, rot, why))
        placed.append((-x, y, s, math.pi - rot, why.replace("A_Cover", "B_Cover")))
    buckets = {}
    for x, y, s, rot, _ in placed:
        buckets.setdefault(tile_of(x, y), []).extend(pine(x, y, height(x, y), s, rot))
    stats = {}
    for k, tris in sorted(buckets.items()):
        name = "Pines_Tile_%d_%d" % k
        stats[name] = tri_object(coll, name, tris, mat, "rule §6.5: decorative pines (edge belt + cover zones), mirrored")
    return stats, [(x, y, 4.4 * s, why) for x, y, s, _, why in placed]


# ------------------------------------------------------------------ markers (verification only)
def build_markers(coll, L, pads, lanes, cover, mat, height):
    def strip(x0, y0, x1, y1, w, col, lift=0.6, step=8.0):
        """A flat line from (x0, y0) to (x1, y1), in short pieces laid on the ground."""
        n = max(1, int(math.hypot(x1 - x0, y1 - y0) // step))
        nx_, ny_ = y1 - y0, -(x1 - x0); nl = math.hypot(nx_, ny_) or 1
        nx_, ny_ = nx_ / nl * w / 2, ny_ / nl * w / 2
        out = []
        for k in range(n):
            ax, ay = x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n
            bx, by = x0 + (x1 - x0) * (k + 1) / n, y0 + (y1 - y0) * (k + 1) / n
            z = max(height(ax, ay), height(bx, by), SEA_LEVEL) + lift
            out.append((((ax - nx_, ay - ny_, z), (bx - nx_, by - ny_, z), (bx + nx_, by + ny_, z), (ax + nx_, ay + ny_, z)), col))
        return out

    def outline_rect(x0, y0, x1, y1, w, col):
        return (strip(x0, y0, x1, y0, w, col) + strip(x1, y0, x1, y1, w, col)
                + strip(x1, y1, x0, y1, w, col) + strip(x0, y1, x0, y0, w, col))

    def post(x, y, z, w, h, col):
        v = [(x - w, y - w, z), (x + w, y - w, z), (x + w, y + w, z), (x - w, y + w, z),
             (x - w, y - w, z + h), (x + w, y - w, z + h), (x + w, y + w, z + h), (x - w, y + w, z + h)]
        f = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
        return [(tuple(v[i] for i in q), col) for q in f]

    def ring(x, y, z, r, w, col, n=32):
        out = []
        for i in range(n):
            a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
            p = lambda a, rr: (x + math.cos(a) * rr, y + math.sin(a) * rr, z)
            out.append(((p(a0, r - w), p(a1, r - w), p(a1, r + w), p(a0, r + w)), col))
        return out

    def rect(x0, y0, x1, y1, z, w, col):
        out = []
        for (a, b, c, d) in ((x0, y0, x1, y0 + w), (x0, y1 - w, x1, y1), (x0, y0, x0 + w, y1), (x1 - w, y0, x1, y1)):
            out.append((((a, b, z), (c, b, z), (c, d, z), (a, d, z)), col))
        return out

    def arrow(x, y, z, dx, dy, size, col):
        px, py = -dy, dx
        return [(((x + px * size * 0.6, y + py * size * 0.6, z), (x - px * size * 0.6, y - py * size * 0.6, z),
                  (x + dx * size, y + dy * size, z)), col)]

    stats, lift = {}, 0.35
    t = post(0, 0, 0, 2.5, 40, MARKER["origin"]) + rect(-1, -400, 1, 400, 20, 2, MARKER["axis"])
    stats["Marker_Origin_Axis"] = tri_object(coll, "Marker_Origin_Axis", t, mat, "layout.json mirror_axis (x = 0) and origin", MARKER)
    for c in L["castles"]:
        x, y, z = rb(c["center"]["x"], c["pad"]["y"], c["center"]["z"])
        half = c["ring_size"]["x"] / 2
        t = post(x, y, z, 2, 30, MARKER["castle"]) + rect(x - half, y - half, x + half, y + half, z + lift, 2.5, MARKER["castle"])
        gx, gy, gz = rb(c["gate"]["x"], c["gate"]["y"], c["gate"]["z"])
        fx, fy, _ = rb(c["gate_facing"]["x"], 0, c["gate_facing"]["z"])
        t += arrow(gx, gy, gz + lift + 0.2, fx, fy, 14, MARKER["gate"]) + post(gx, gy, gz, 1.2, 18, MARKER["gate"])
        sx, sy, sz = rb(c["stockpile"]["x"], c["stockpile"]["y"], c["stockpile"]["z"])
        t += post(sx, sy, sz, 3, 6, MARKER["stockpile"])
        for s in c["spawn_points"]:
            px_, py_, pz_ = rb(s["x"], s["y"], s["z"])
            t += post(px_, py_, pz_, 1.2, 7, MARKER["spawn_" + c["team"]])
        name = "Marker_" + c["id"]
        stats[name] = tri_object(coll, name, t, mat, "layout.json castles " + c["id"], MARKER)
    for p in pads:
        if p["kind"] != "node":
            continue
        t = post(p["cx"], p["cy"], p["h"], 1.5, 22, MARKER[p["ring"]]) + ring(p["cx"], p["cy"], p["h"] + lift, p["r"], 1.5, MARKER[p["ring"]])
        name = "Marker_" + p["id"]
        stats[name] = tri_object(coll, name, t, mat, "layout.json resource_node_slots " + p["id"], MARKER)
    t = []
    for l in lanes:
        ex, ey = l["gx"] + l["dx"] * l["length"], l["gy"] + l["dy"] * l["length"]
        x0, x1 = sorted((l["gx"], ex)); y0, y1 = sorted((l["gy"] - l["width"] / 2, l["gy"] + l["width"] / 2))
        t += outline_rect(x0, y0, x1, y1, 2.4, MARKER["lane"])
    stats["Marker_Lanes"] = tri_object(coll, "Marker_Lanes", t, mat, "layout.json gate_approach_lanes", MARKER)
    t = []
    for z in cover:
        t += outline_rect(z["x0"], z["y0"], z["x1"], z["y1"], 2.4, MARKER["cover"])
    stats["Marker_Cover"] = tri_object(coll, "Marker_Cover", t, mat, "layout.json cover_zones", MARKER)
    # the boundary wall: a rounded rectangle offset outside map_bounds
    b, bd = L["map_bounds"], L["boundary"]
    hx = (b["max_x"] - b["min_x"]) / 2 + bd["offset_outside_bounds"]
    hy = (b["max_z"] - b["min_z"]) / 2 + bd["offset_outside_bounds"]
    rad = bd["corner_radius"]
    pts = []
    for qx, qy, a0 in ((1, 1, 0), (-1, 1, 90), (-1, -1, 180), (1, -1, 270)):
        ccx, ccy = qx * (hx - rad), qy * (hy - rad)
        for k in range(9):
            a = math.radians(a0 + k * 90 / 8)
            pts.append((ccx + math.cos(a) * rad, ccy + math.sin(a) * rad))
    t = []
    for i in range(len(pts)):
        (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % len(pts)]
        t += strip(x0, y0, x1, y1, 3.0, MARKER["boundary"])
    stats["Marker_Boundary"] = tri_object(coll, "Marker_Boundary", t, mat, "layout.json boundary (invisible wall)", MARKER)
    return stats, pts


# ------------------------------------------------------------------ verification
def verify(scene, L, pads, lanes, cover, trees, inland, bounds, V3, boundary_pts):
    terrain = [o for o in scene.objects if o.name.startswith("Terrain_Tile")]

    def ground(x, y):
        origin = Vector((x + 0.013, y + 0.017, 500.0))    # off exact tile seams
        for o in terrain:
            hit, loc, _, _ = o.ray_cast(origin, Vector((0, 0, -1)))
            if hit:
                return loc.z
        return None

    pad_report = []
    for p in pads:
        pts = [(p["cx"], p["cy"])]
        if p["shape"] == "square":        # the whole castle ring must be flat
            for i in range(-6, 7):
                for j in range(-6, 7):
                    pts.append((p["cx"] + p["inner"] * i / 6, p["cy"] + p["inner"] * j / 6))
        else:                             # the node's footprint (pad radius minus the 8 margin)
            for k in range(24):
                for f in (0.5, 1.0):
                    a = 2 * math.pi * k / 24
                    pts.append((p["cx"] + math.cos(a) * p["inner"] * f, p["cy"] + math.sin(a) * p["inner"] * f))
        zs = [ground(x, y) for x, y in pts]
        miss = sum(z is None for z in zs)
        dev = max((abs(z - p["h"]) for z in zs if z is not None), default=0.0)
        pad_report.append((p["id"], round(dev, 4), miss))
    lane_hits = [(l["id"], why, round(x), round(y)) for l in lanes for x, y, cr, why in trees if in_lane(l, x, y, grow=cr)]
    tree_on_pad = [(why, round(x), round(y), p["id"]) for x, y, cr, why in trees for p in pads if pad_dist(p, x, y) < cr]
    pines_outside_rules = []
    edge = lambda x, y: min(x - bounds["x0"], bounds["x1"] - x, y - bounds["y0"], bounds["y1"] - y)
    belt = L["decoration_rules"]["edge_belt_depth"]
    for x, y, cr, why in trees:
        if edge(x, y) > belt and not any(in_cover(z, x, y) for z in cover):
            pines_outside_rules.append((round(x), round(y), why))
    xs = [bounds["x0"] + (bounds["x1"] - bounds["x0"]) * i / 60 for i in range(61)]
    ys = [bounds["y0"] + (bounds["y1"] - bounds["y0"]) * j / 40 for j in range(41)]
    water_inside = [(round(x), round(y)) for x in xs for y in ys if (ground(x, y) or 0) <= SEA_LEVEL + 0.05]
    # the boundary wall must stand on land and the coast must lie beyond it
    wall_min_inland = min(inland(x, y) for x, y in boundary_pts)
    corner_outside_wall = []
    bd = L["boundary"]; b = L["map_bounds"]
    hx = (b["max_x"] - b["min_x"]) / 2 + bd["offset_outside_bounds"]; hy = (b["max_z"] - b["min_z"]) / 2 + bd["offset_outside_bounds"]
    for cx_, cy_ in ((bounds["x0"], bounds["y0"]), (bounds["x1"], bounds["y1"])):
        d = rounded_rect_sdf(cx_, cy_, 0, 0, hx, hy, bd["corner_radius"])
        if d > 0:
            corner_outside_wall.append(round(d, 1))
    # mirror: every terrain vertex has a twin at (-x, y) with the same height
    at = {(round(x, 4), round(y, 4)): z for x, y, z in V3}
    missing, mirror_err = 0, 0.0
    for x, y, z in V3:
        twin = at.get((round(-x, 4), round(y, 4)))
        if twin is None:
            missing += 1
        else:
            mirror_err = max(mirror_err, abs(twin - z))
    mirror_err = (mirror_err, missing)
    tree_mirror = sum(1 for x, y, cr, why in trees if not any(abs(-x - x2) < 1e-6 and abs(y - y2) < 1e-6 for x2, y2, _, _ in trees))
    return dict(pads=pad_report, lane_tree_hits=lane_hits, trees_on_pads=tree_on_pad, pines_outside_rules=pines_outside_rules,
                water_inside_bounds=water_inside, boundary_wall_min_inland=round(wall_min_inland, 1),
                map_corner_outside_wall=corner_outside_wall, height_mirror_max_err=mirror_err, unmirrored_trees=tree_mirror)


def slope_report(V3, tris, bounds):
    """Steepness of every terrain face whose centre is inside map_bounds."""
    worst = []
    for t in tris:
        p = [V3[i] for i in t]
        cx = sum(q[0] for q in p) / 3; cy = sum(q[1] for q in p) / 3
        if not (bounds["x0"] <= cx <= bounds["x1"] and bounds["y0"] <= cy <= bounds["y1"]):
            continue
        nz = face_normal_z(*p)
        worst.append((round(math.degrees(math.acos(max(-1.0, min(1.0, nz)))), 1), round(cx), round(cy)))
    worst.sort(reverse=True)
    return dict(max=worst[:5], cells_over_20deg=sum(1 for w in worst if w[0] > 20),
                cells_over_30deg=sum(1 for w in worst if w[0] > 30), cells=len(worst))


def audit(scene, delete=True):
    stray = [o.name for o in scene.objects if "traces_to" not in o.keys()]
    if delete:
        for name in stray:
            bpy.data.objects.remove(bpy.data.objects[name])
    return stray


# ------------------------------------------------------------------ export
EXPORT_COLLECTIONS = ("Map_Terrain", "Map_Trees", "Map_Sea")   # never Layout_Markers


def export_fbx(scene, path):
    """The whole map as one FBX, one mesh per object, for Roblox's 3D Importer.
    Same settings as the Stone asset: Y-up with the axis change baked into the
    meshes, face smoothing (flat facets), vertex colours as sRGB. Blender
    (x, y, z) becomes FBX (x, z, -y), which is exactly Roblox's (x, y, z) for this
    layout. Selection and the active object are restored afterwards."""
    view_layer = scene.view_layers[0]
    objs = [o for name in EXPORT_COLLECTIONS for o in bpy.data.collections[name].objects]
    selected = [o for o in view_layer.objects if o.select_get(view_layer=view_layer)]
    active = view_layer.objects.active
    win = bpy.context.window
    prev_scene = win.scene
    try:
        win.scene = scene
        for o in selected:
            o.select_set(False, view_layer=view_layer)
        for o in objs:
            o.select_set(True, view_layer=view_layer)
        view_layer.objects.active = objs[0]
        with bpy.context.temp_override(window=win, scene=scene, view_layer=view_layer):
            bpy.ops.export_scene.fbx(
                filepath=path, use_selection=True, object_types={"MESH"},
                axis_forward="-Z", axis_up="Y", bake_space_transform=True,
                apply_scale_options="FBX_SCALE_ALL", mesh_smooth_type="FACE",
                colors_type="SRGB", use_mesh_modifiers=True, add_leaf_bones=False,
                bake_anim=False, path_mode="STRIP")
    finally:
        for o in objs:
            o.select_set(False, view_layer=view_layer)
        for o in selected:
            o.select_set(True, view_layer=view_layer)
        view_layer.objects.active = active
        win.scene = prev_scene
    return path, len(objs)


# ------------------------------------------------------------------ scene
def preview_world():
    """World, not objects: lit by Blender's bundled studio HDRI, while the camera
    sees the sky colour sampled from the reference. Nothing is added to the scene."""
    world = bpy.data.worlds.get("Map_World") or bpy.data.worlds.new("Map_World")
    try:
        world.use_nodes = True
    except Exception:
        pass
    nt = world.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputWorld")
    mix = nt.nodes.new("ShaderNodeMixShader")
    cam = nt.nodes.new("ShaderNodeLightPath")
    sky = nt.nodes.new("ShaderNodeBackground")
    sky.inputs[0].default_value = (lin(103), lin(127), lin(174), 1.0)
    light = nt.nodes.new("ShaderNodeBackground")
    light.inputs[1].default_value = 1.0
    folder = bpy.utils.system_resource("DATAFILES", path="studiolights/world")
    hdri = None
    if folder and os.path.isdir(folder):
        for name in ("sunrise.exr", "forest.exr", "courtyard.exr"):
            if os.path.exists(os.path.join(folder, name)):
                hdri = os.path.join(folder, name)
                break
    if hdri:
        env = nt.nodes.new("ShaderNodeTexEnvironment")
        env.image = bpy.data.images.load(hdri, check_existing=True)
        nt.links.new(env.outputs[0], light.inputs[0])
    nt.links.new(cam.outputs["Is Camera Ray"], mix.inputs[0])
    nt.links.new(light.outputs[0], mix.inputs[1])
    nt.links.new(sky.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], out.inputs[0])
    return world


def build():
    old = bpy.data.scenes.get("Map")
    if old:
        meshes = {o.data for o in old.objects if o.type == "MESH"}
        for o in list(old.objects):
            bpy.data.objects.remove(o)
        for c in list(old.collection.children_recursive):
            bpy.data.collections.remove(c)
        bpy.data.scenes.remove(old)
        for d in meshes:
            if d.users == 0:
                bpy.data.meshes.remove(d)
    scene = bpy.data.scenes.new("Map")
    try:
        scene.view_settings.view_transform = "Standard"
    except TypeError:
        pass
    scene.world = preview_world()
    colls = {}
    for name in ("Map_Terrain", "Map_Trees", "Map_Sea", "Layout_Markers"):
        c = bpy.data.collections.new(name); scene.collection.children.link(c); colls[name] = c
    rng = random.Random(SEED)
    mat, mmat = material("Map_Mat"), material("Marker_Mat", emissive=True)
    L, pads, lanes, cover, bounds = load_layout()
    inland, outline = make_coast(bounds, rng)
    height = make_height(pads, inland)
    stats = {}
    g, V3, tris = build_ground_lowpoly(colls["Map_Terrain"], height, inland, pads, lanes, rng, mat)
    stats.update(g)
    stats.update(build_sea(colls["Map_Sea"], outline, inland, rng, mat))
    p, trees = build_pines(colls["Map_Trees"], height, inland, pads, lanes, cover, bounds,
                           L["decoration_rules"]["edge_belt_depth"], rng, mat)
    stats.update(p)
    mk, boundary_pts = build_markers(colls["Layout_Markers"], L, pads, lanes, cover, mmat, height)
    scene.view_layers[0].update()
    return dict(scene=scene, stats=stats, markers=mk, L=L, pads=pads, lanes=lanes, cover=cover, bounds=bounds,
                inland=inland, trees=trees, V3=V3, tris=tris, height=height, boundary_pts=boundary_pts)


# ------------------------------------------------------------------ views
def _v3d():
    for win in bpy.context.window_manager.windows:
        for area in win.screen.areas:
            if area.type == "VIEW_3D":
                return win, area, area.spaces.active


def show(scene):
    win, area, sp = _v3d()
    win.scene = scene
    for o in scene.objects:
        o.select_set(False, view_layer=scene.view_layers[0])
    sp.shading.type = "RENDERED"             # lit by the scene world (see preview_world)
    sp.shading.show_object_outline = False
    sp.clip_start, sp.clip_end = 0.5, 12000
    sp.overlay.show_floor = False
    sp.overlay.show_axis_x = sp.overlay.show_axis_y = False


def set_markers(scene, visible):
    lc = scene.view_layers[0].layer_collection.children.get("Layout_Markers")
    if lc:
        lc.hide_viewport = not visible


def orbit(yaw, pitch, dist, target=(0, 0, 0), ortho=False, lens=50):
    win, area, sp = _v3d()
    sp.lens = lens
    r = sp.region_3d
    r.view_perspective = "ORTHO" if ortho else "PERSP"
    r.view_location = Vector(target)
    r.view_distance = dist
    r.view_rotation = Euler((math.radians(90 - pitch), 0, math.radians(yaw))).to_quaternion()
    area.tag_redraw()


def look(eye, target, lens=28):
    win, area, sp = _v3d()
    sp.lens = lens
    r = sp.region_3d
    r.view_perspective = "PERSP"
    eye, target = Vector(eye), Vector(target)
    r.view_rotation = (target - eye).to_track_quat("-Z", "Y")
    r.view_location = target
    r.view_distance = (target - eye).length
    area.tag_redraw()


bpy.app.driver_namespace["map"] = dict(build=build, verify=verify, slope_report=slope_report, audit=audit, export_fbx=export_fbx,
                                        show=show, set_markers=set_markers, orbit=orbit, look=look, rb=rb)
