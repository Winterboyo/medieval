"""Map terrain built AROUND a layout file, in its own Blender scene ("Map").

STATUS: written for the pre-pivot island schema, so it reads
layout.old-island.json (castles with plot_size, resource_nodes with one type and
a footprint, village_square). The approved two-castle layout.json uses a
different schema (resource_node_slots with allowed_types and pad_radius, team
spawn_points, gate_approach_lanes, cover_zones, boundary). Adapting load_layout()
and the marker/verify code to it is the next Blender task; the pad, lane, coast,
pine-belt, colour and verification logic carry over unchanged.

Roblox is Y-up, Blender is Z-up: (x, y, z)_roblox -> (x, -z, y)_blender.
1 unit = 1 stud. Everything placed here traces to a layout entry or to a rule
of the brief; every object carries a "traces_to" custom property, and audit()
lists (and deletes) anything in the scene that does not.

Island, Catan-style: land fills map_bounds, the coast sits just outside it,
sea beyond. No mountains. Colours are per-face (CORNER-domain byte colour
attribute "Col"), sampled from references/terrain-meadow.jpg.

Run inside Blender (Text Editor > Run Script, or exec() over the MCP bridge
with __file__ set), then call bpy.app.driver_namespace["map"]["build"]().
"""
import bpy, json, math, os, random
from mathutils import Vector, Euler

_HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
LAYOUT = os.path.normpath(os.path.join(_HERE, "..", "..", "layout.old-island.json"))
SEED = 20260928

SRGB = {
    "GRASS": (124, 146, 82),
    "SAND": (169, 149, 92),        # beach, pads, approach lanes
    "WATER": (162, 179, 194),      # shallows
    "SEA_DEEP": (89, 115, 166),    # open sea (reference upper sky)
    "ROCK": (109, 103, 127),       # only on steep ground
    "PINE": (56, 60, 45),
    "TRUNK": (81, 59, 61),
    "CANOPY": (74, 80, 68),        # round-canopy trees: Wood nodes only
}
MARKER = {   # verification overlay only, not terrain
    "origin": (255, 0, 255), "castle": (235, 40, 40), "gate": (255, 215, 0), "spawn": (0, 255, 130),
    "Wood": (255, 130, 0), "Stone": (255, 255, 255), "Grain": (0, 200, 255), "Ore": (150, 0, 255), "Wool": (255, 110, 200),
}

CELL = 8.0
GRID_HALF = 1088.0
GRID_CY = 48.0            # grid centred on the map, in Blender y
TILES = 4
SEA_LEVEL, SHORE_H, SEABED = 0.0, 0.6, -20.0
COAST_MARGIN, COAST_RADIUS = 60.0, 150.0
COAST_BLEND = 70.0        # inland distance over which land eases down to the shore
BEACH = 22.0
PAD_MARGIN = 8.0          # around a castle plot / node footprint: one full grid cell, so no edge face leans into it
PAD_BLEND = 40.0
PLAZA_RADIUS = 70.0
LANE_WIDTH, LANE_LENGTH = 30.0, 80.0
EDGE_BELT = 150.0         # pine belt depth inside the map edge


def rb(x, y, z):
    """Roblox (x, y, z) -> Blender (x, y, z)."""
    return (x, -z, y)


def smooth(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


# ------------------------------------------------------------------ layout -> pads, lanes
def load_layout():
    with open(LAYOUT, encoding="utf-8") as f:
        L = json.load(f)
    pads, lanes = [], []
    for c in L["castles"]:
        cx, cy, _ = rb(c["center"]["x"], 0, c["center"]["z"])
        half = c["plot_size"]["x"] / 2 + PAD_MARGIN
        pads.append(dict(kind="castle", id=c["id"], cx=cx, cy=cy, shape="square", half=half,
                         h=c["center"]["y"] - 1.0))          # foundation is 1 thick, its top is center.y
        gx, gy, _ = rb(c["gate"]["x"], 0, c["gate"]["z"])
        fx, fy, _ = rb(c["gate_facing"]["x"], 0, c["gate_facing"]["z"])
        n = math.hypot(fx, fy)
        lanes.append(dict(id=c["id"], gx=gx, gy=gy, dx=fx / n, dy=fy / n))
    for n_ in L["resource_nodes"]:
        cx, cy, _ = rb(n_["position"]["x"], 0, n_["position"]["z"])
        r = max(n_["footprint"]["x"], n_["footprint"]["z"]) / 2 + PAD_MARGIN
        pads.append(dict(kind="node", id=n_["id"], type=n_["type"], cx=cx, cy=cy, shape="circle", r=r,
                         h=n_["position"]["y"], fx=n_["footprint"]["x"], fz=n_["footprint"]["z"]))
    vs = L["village_square"]["totem"]
    spawn_top = min(s["position"]["y"] for s in L["spawn_points"])
    cx, cy, _ = rb(vs["x"], 0, vs["z"])
    pads.append(dict(kind="plaza", id="village_square", cx=cx, cy=cy, shape="circle", r=PLAZA_RADIUS,
                     h=spawn_top - 1.0))                      # spawn pads are 1 thick
    b = L["map_bounds"]
    # Roblox z range becomes Blender -y range
    bounds = dict(x0=b["min_x"], x1=b["max_x"], y0=-b["max_z"], y1=-b["min_z"])
    return L, pads, lanes, bounds


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
    return -grow <= along <= LANE_LENGTH + grow and abs(side) <= LANE_WIDTH / 2 + grow


# ------------------------------------------------------------------ coast
def make_coast(bounds, rng):
    cx, cy = (bounds["x0"] + bounds["x1"]) / 2, (bounds["y0"] + bounds["y1"]) / 2
    hx = (bounds["x1"] - bounds["x0"]) / 2 + COAST_MARGIN
    hy = (bounds["y1"] - bounds["y0"]) / 2 + COAST_MARGIN
    knots = [rng.uniform(0, 24) for _ in range(72)]       # outward-only wobble: never cuts into the map

    def wobble(x, y):
        a = (math.atan2(y - cy, x - cx) % (2 * math.pi)) / (2 * math.pi) * len(knots)
        i = int(a) % len(knots); f = a - int(a)
        return knots[i] * (1 - f) + knots[(i + 1) % len(knots)] * f

    def sdf(x, y):
        qx = abs(x - cx) - (hx - COAST_RADIUS); qy = abs(y - cy) - (hy - COAST_RADIUS)
        return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - COAST_RADIUS

    def inland(x, y):
        return wobble(x, y) - sdf(x, y)

    def outline(push=0.0, rng2=None, n=160):
        """Points on the coast (or pushed out to sea), walking the rounded rect."""
        pts = []
        for i in range(n):
            a = 2 * math.pi * i / n
            dx, dy = math.cos(a), math.sin(a)
            lo, hi = 0.0, 4000.0                       # bisect along the ray for inland == -push
            for _ in range(40):
                mid = (lo + hi) / 2
                if inland(cx + dx * mid, cy + dy * mid) > -push - (rng2.uniform(0, 10) if rng2 else 0):
                    lo = mid
                else:
                    hi = mid
            pts.append((cx + dx * lo, cy + dy * lo))
        return pts
    return inland, outline, (cx, cy)


# ------------------------------------------------------------------ height
def undulation(x, y):
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
            return best["h"], best
        far = hsum / wsum + undulation(x, y) * smooth(0, PAD_BLEND, bd)
        t = smooth(0, PAD_BLEND, bd)
        return best["h"] * (1 - t) + far * t, None

    def height(x, y):
        s = inland(x, y)
        if s < 0:
            return SHORE_H + (SEABED - SHORE_H) * smooth(0, 45, -s)
        h, _ = land(x, y)
        if s < COAST_BLEND:
            h = SHORE_H + (h - SHORE_H) * smooth(0, COAST_BLEND, s)
        return h
    return height, land


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
    step = 2 * GRID_HALF / TILES
    c = lambda v, o: max(0, min(TILES - 1, int((v - o + GRID_HALF) // step)))
    return c(x, 0.0), c(y, GRID_CY)


def face_normal_z(a, b, c):
    n = (Vector(b) - Vector(a)).cross(Vector(c) - Vector(a))
    return abs(n.z) / max(n.length, 1e-9)


# ------------------------------------------------------------------ ground
def build_ground(coll, height, inland, pads, lanes, mat):
    n = int(round(2 * GRID_HALF / CELL))
    per = n // TILES
    X = lambda i: -GRID_HALF + i * CELL
    Y = lambda j: GRID_CY - GRID_HALF + j * CELL
    H = [[height(X(i), Y(j)) for j in range(n + 1)] for i in range(n + 1)]

    def vnormal(i, j):
        i0, i1, j0, j1 = max(i - 1, 0), min(i + 1, n), max(j - 1, 0), min(j + 1, n)
        v = Vector((-(H[i1][j] - H[i0][j]) / ((i1 - i0) * CELL), -(H[i][j1] - H[i][j0]) / ((j1 - j0) * CELL), 1.0))
        return tuple(v.normalized())

    stats = {}
    for ti in range(TILES):
        for tj in range(TILES):
            verts, index, vnorms = [], {}, []
            for i in range(ti * per, (ti + 1) * per + 1):
                for j in range(tj * per, (tj + 1) * per + 1):
                    index[(i, j)] = len(verts)
                    verts.append((X(i), Y(j), H[i][j]))
                    vnorms.append(vnormal(i, j))
            faces, cols, smooths = [], [], []
            for i in range(ti * per, (ti + 1) * per):
                for j in range(tj * per, (tj + 1) * per):
                    a, b, c, d = index[(i, j)], index[(i + 1, j)], index[(i + 1, j + 1)], index[(i, j + 1)]
                    for t in ([(a, b, c), (a, c, d)] if (i + j) % 2 == 0 else [(a, b, d), (b, c, d)]):
                        p = [verts[k] for k in t]
                        cx = sum(q[0] for q in p) / 3; cy = sum(q[1] for q in p) / 3
                        if inland(cx, cy) < BEACH:
                            col = "SAND"
                        elif any(pad_dist(pd, cx, cy) == 0.0 for pd in pads) or any(in_lane(l, cx, cy) for l in lanes):
                            col = "SAND"
                        elif face_normal_z(*p) < 0.7:
                            col = "ROCK"
                        else:
                            col = "GRASS"
                        faces.append(t); cols.append(SRGB[col]); smooths.append(True)
            name = "Terrain_Tile_%d_%d" % (ti, tj)
            me = colour_mesh(name, verts, faces, cols, smooths, mat, vnorms)
            add_object(coll, name, me, "rule: terrain around layout.json (pads, lanes, map_bounds)")
            stats[name] = len(faces)
    return stats, H


# ------------------------------------------------------------------ sea
def build_sea(coll, outline, mat):
    s = 3000.0
    verts = [(-s, -s + GRID_CY, SEA_LEVEL), (s, -s + GRID_CY, SEA_LEVEL), (s, s + GRID_CY, SEA_LEVEL), (-s, s + GRID_CY, SEA_LEVEL)]
    faces, cols = [(0, 1, 2), (0, 2, 3)], [SRGB["SEA_DEEP"]] * 2
    shallows = outline(push=30.0, rng2=random.Random(SEED + 1))
    c0 = len(verts)
    verts.append((0.0, GRID_CY, SEA_LEVEL + 0.05))
    verts.extend((x, y, SEA_LEVEL + 0.05) for x, y in shallows)
    k = len(shallows)
    faces += [(c0, c0 + 1 + i, c0 + 1 + (i + 1) % k) for i in range(k)]
    cols += [SRGB["WATER"]] * k
    me = colour_mesh("Sea", verts, faces, cols, [False] * len(faces), mat)
    add_object(coll, "Sea", me, "rule: water only outside map_bounds, as backdrop")
    return {"Sea": len(faces)}


# ------------------------------------------------------------------ trees
_PHI = (1 + 5 ** 0.5) / 2
ICO_V = [(-1, _PHI, 0), (1, _PHI, 0), (-1, -_PHI, 0), (1, -_PHI, 0), (0, -1, _PHI), (0, 1, _PHI),
         (0, -1, -_PHI), (0, 1, -_PHI), (_PHI, 0, -1), (_PHI, 0, 1), (-_PHI, 0, -1), (-_PHI, 0, 1)]
ICO_F = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6),
         (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]


def trunk(x, y, z, w, top):
    q = [(x - w, y - w), (x + w, y - w), (x + w, y + w), (x - w, y + w)]
    out = []
    for i in range(4):
        a, b = q[i], q[(i + 1) % 4]
        out.append((((a[0], a[1], z - 0.5), (b[0], b[1], z - 0.5), (b[0], b[1], top)), "TRUNK"))
        out.append((((a[0], a[1], z - 0.5), (b[0], b[1], top), (a[0], a[1], top)), "TRUNK"))
    return out


def round_tree(x, y, z, s, rng):
    """Wood-node tree: thin trunk, faceted icosahedral canopy."""
    top = z + 7.5 * s
    tris = trunk(x, y, z, 0.55 * s, top + 2 * s)
    cr = 6.0 * s
    vs = []
    for vx, vy, vz in ICO_V:
        v = Vector((vx, vy, vz)).normalized() * rng.uniform(0.85, 1.12)
        vs.append((x + v.x * cr, y + v.y * cr, top + cr * 0.8 + v.z * cr * 0.85))
    tris += [((vs[a], vs[b], vs[c]), "CANOPY") for a, b, c in ICO_F]
    return tris, cr


def pine(x, y, z, s, rng):
    tris = trunk(x, y, z, 0.35 * s, z + 4.5 * s)
    rot = rng.uniform(0, math.pi)
    for rad, z0, hh in ((4.4, 3.2, 6.8), (3.4, 7.2, 6.0), (2.3, 10.8, 5.4)):
        ring = [(x + math.cos(rot + 2 * math.pi * i / 6) * rad * s, y + math.sin(rot + 2 * math.pi * i / 6) * rad * s, z + z0 * s) for i in range(6)]
        apex = (x, y, z + (z0 + hh) * s)
        for i in range(6):
            tris.append(((ring[i], ring[(i + 1) % 6], apex), "PINE"))
        for i in range(1, 5):
            tris.append(((ring[0], ring[i + 1], ring[i]), "PINE"))
    return tris, 4.4 * s


def build_wood_nodes(coll, height, pads, lanes, rng, mat):
    stats, placed = {}, []
    for p in pads:
        if p.get("type") != "Wood":
            continue
        tris, trees = [], []
        ax, ay = p["fx"] * 0.36, p["fz"] * 0.36
        for _ in range(400):
            if len(trees) >= 8:
                break
            a, d = rng.uniform(0, 2 * math.pi), math.sqrt(rng.uniform(0, 1))
            x, y = p["cx"] + math.cos(a) * ax * d, p["cy"] + math.sin(a) * ay * d
            s = rng.uniform(1.0, 1.3)
            cr = 6.0 * s
            if any(in_lane(l, x, y, grow=cr) for l in lanes):
                continue
            if all(math.hypot(x - tx, y - ty) > 11 for tx, ty, _ in trees):
                trees.append((x, y, s))
        for x, y, s in trees:
            t, cr = round_tree(x, y, p["h"], s, rng)
            tris += t
            placed.append((x, y, cr, "wood:" + p["id"]))
        name = "WoodNode_" + p["id"]
        stats[name] = tri_object(coll, name, tris, mat, "layout.json resource_nodes " + p["id"])
    return stats, placed


def build_pines(coll, height, inland, pads, lanes, bounds, rng, mat):
    def edge_depth(x, y):
        return min(x - bounds["x0"], bounds["x1"] - x, y - bounds["y0"], bounds["y1"] - y)

    def blocked(x, y, cr):
        if inland(x, y) < BEACH + 8:
            return True
        if any(pad_dist(p, x, y) < cr + 2 for p in pads):
            return True
        return any(in_lane(l, x, y, grow=cr + 1) for l in lanes)

    placed = []

    def plant(x, y, why):
        s = rng.uniform(0.9, 1.4)
        cr = 4.4 * s
        if blocked(x, y, cr) or any(math.hypot(x - px, y - py) < 6.5 for px, py, _, _ in placed):
            return False
        placed.append((x, y, s, why))
        return True

    # 1. the edge belt
    belt_clusters = 0
    for _ in range(4000):
        if belt_clusters >= 70:
            break
        x, y = rng.uniform(bounds["x0"] - 40, bounds["x1"] + 40), rng.uniform(bounds["y0"] - 40, bounds["y1"] + 40)
        if edge_depth(x, y) > EDGE_BELT or blocked(x, y, 5):
            continue
        belt_clusters += 1
        for _ in range(rng.randint(4, 9)):
            a, d = rng.uniform(0, 2 * math.pi), rng.uniform(0, 22)
            px_, py_ = x + math.cos(a) * d, y + math.sin(a) * d
            if edge_depth(px_, py_) <= EDGE_BELT:
                plant(px_, py_, "rule: pine belt near map edge")
    # 2. cover clusters beside each approach lane (outside it)
    for l in lanes:
        for side in (-1, 1):
            along = rng.uniform(30, 60)
            off = LANE_WIDTH / 2 + 12
            cx = l["gx"] + l["dx"] * along - l["dy"] * off * side
            cy = l["gy"] + l["dy"] * along + l["dx"] * off * side
            for _ in range(rng.randint(3, 5)):
                a, d = rng.uniform(0, 2 * math.pi), rng.uniform(0, 7)
                plant(cx + math.cos(a) * d, cy + math.sin(a) * d, "rule: cover cluster beside lane " + l["id"])

    buckets, why = {}, {}
    for x, y, s, reason in placed:
        k = tile_of(x, y)
        t, cr = pine(x, y, height(x, y), s, rng)
        buckets.setdefault(k, []).extend(t)
    stats = {}
    for k, tris in sorted(buckets.items()):
        name = "Pines_Tile_%d_%d" % k
        stats[name] = tri_object(coll, name, tris, mat, "rule: decorative pines (edge belt + lane cover clusters)")
    return stats, [(x, y, 4.4 * s, reason) for x, y, s, reason in placed]


# ------------------------------------------------------------------ markers
def build_markers(coll, L, mat):
    def post(x, y, z, w, h, col):
        v = [(x - w, y - w, z), (x + w, y - w, z), (x + w, y + w, z), (x - w, y + w, z),
             (x - w, y - w, z + h), (x + w, y - w, z + h), (x + w, y + w, z + h), (x - w, y + w, z + h)]
        f = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
        return [(tuple(v[i] for i in q), col) for q in f]

    def ring(x, y, z, r, w, col, n=24):
        out = []
        for i in range(n):
            a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
            p = lambda a, rr: (x + math.cos(a) * rr, y + math.sin(a) * rr, z)
            out.append(((p(a0, r - w), p(a1, r - w), p(a1, r + w), p(a0, r + w)), col))
        return out

    def square(x, y, z, half, w, col):
        out = []
        for (x0, y0, x1, y1) in ((x - half, y - half, x + half, y - half + w), (x - half, y + half - w, x + half, y + half),
                                 (x - half, y - half, x - half + w, y + half), (x + half - w, y - half, x + half, y + half)):
            out.append((((x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)), col))
        return out

    def arrow(x, y, z, dx, dy, size, col):
        px, py = -dy, dx
        tip = (x + dx * size, y + dy * size, z)
        l = (x + px * size * 0.6, y + py * size * 0.6, z)
        r = (x - px * size * 0.6, y - py * size * 0.6, z)
        return [((l, r, tip), col)]

    stats = {}
    lift = 0.35
    ox, oy, oz = rb(0, L["village_square"]["totem"]["y"], 0)
    t = post(ox, oy, oz - 3, 2.5, 40, MARKER["origin"]) + square(ox, oy, oz + lift - 1.7, 12, 2, MARKER["origin"])
    stats["Marker_Origin"] = tri_object(coll, "Marker_Origin", t, mat, "layout.json meta: origin (0,0)", MARKER)
    for c in L["castles"]:
        x, y, z = rb(c["center"]["x"], c["center"]["y"], c["center"]["z"])
        t = post(x, y, z - 1, 2, 30, MARKER["castle"]) + square(x, y, z + lift - 1, c["plot_size"]["x"] / 2, 2.5, MARKER["castle"])
        gx, gy, gz = rb(c["gate"]["x"], c["gate"]["y"], c["gate"]["z"])
        fx, fy, _ = rb(c["gate_facing"]["x"], 0, c["gate_facing"]["z"])
        t += arrow(gx, gy, gz + lift, fx, fy, 14, MARKER["gate"]) + post(gx, gy, gz - 1, 1.2, 18, MARKER["gate"])
        name = "Marker_" + c["id"]
        stats[name] = tri_object(coll, name, t, mat, "layout.json castles " + c["id"], MARKER)
    for n_ in L["resource_nodes"]:
        x, y, z = rb(n_["position"]["x"], n_["position"]["y"], n_["position"]["z"])
        r = max(n_["footprint"]["x"], n_["footprint"]["z"]) / 2
        t = post(x, y, z - 1, 1.5, 22, MARKER[n_["type"]]) + ring(x, y, z + lift, r, 1.5, MARKER[n_["type"]])
        name = "Marker_" + n_["id"]
        stats[name] = tri_object(coll, name, t, mat, "layout.json resource_nodes " + n_["id"], MARKER)
    t = []
    for s in L["spawn_points"]:
        x, y, z = rb(s["position"]["x"], s["position"]["y"], s["position"]["z"])
        t += post(x, y, z - 1.5, 1.5, 8, MARKER["spawn"])
    stats["Marker_Spawns"] = tri_object(coll, "Marker_Spawns", t, mat, "layout.json spawn_points (8)", MARKER)
    return stats


# ------------------------------------------------------------------ verification
def verify(scene, L, pads, lanes, trees, inland, bounds):
    # Rays against the terrain tiles ONLY (tiles have identity transforms), so a
    # marker post standing flush on the ground can never be mistaken for it.
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
        pts = []
        if p["shape"] == "square":
            inner = p["half"] - PAD_MARGIN
            for i in range(-4, 5):
                for j in range(-4, 5):
                    pts.append((p["cx"] + inner * i / 4, p["cy"] + inner * j / 4))
        else:
            inner = p["r"] - PAD_MARGIN
            pts.append((p["cx"], p["cy"]))
            for k in range(16):
                for f in (0.5, 1.0):
                    a = 2 * math.pi * k / 16
                    pts.append((p["cx"] + math.cos(a) * inner * f, p["cy"] + math.sin(a) * inner * f))
        owner = lambda x, y: next((q for q in pads if pad_dist(q, x, y) == 0.0), None)
        owned = [(x, y) for x, y in pts if owner(x, y) is p]
        zs = [ground(x, y) for x, y in owned]
        miss = sum(z is None for z in zs)
        dev = max((abs(z - p["h"]) for z in zs if z is not None), default=0.0)
        centre = ground(p["cx"], p["cy"])
        pad_report.append((p["id"], round(dev, 3), miss, round(1 - len(owned) / len(pts), 2),
                           None if centre is None else round(abs(centre - p["h"]), 3)))
    lane_hits = []
    for l in lanes:
        for x, y, cr, why in trees:
            if in_lane(l, x, y, grow=cr):
                lane_hits.append((l["id"], why, round(x), round(y)))
    lane_pad = []
    for l in lanes:
        for p in pads:
            if p["id"] == l["id"]:
                continue
            # sample the lane
            for a in range(0, int(LANE_LENGTH) + 1, 8):
                for sd in (-LANE_WIDTH / 2, 0, LANE_WIDTH / 2):
                    x = l["gx"] + l["dx"] * a - l["dy"] * sd
                    y = l["gy"] + l["dy"] * a + l["dx"] * sd
                    if pad_dist(p, x, y) == 0.0:
                        lane_pad.append((l["id"], p["id"]))
                        break
                else:
                    continue
                break
    tree_on_pad = [(why, round(x), round(y), p["id"]) for x, y, cr, why in trees if not why.startswith("wood:")
                   for p in pads if pad_dist(p, x, y) < cr]
    wood_off_pad = [(why, round(x), round(y)) for x, y, cr, why in trees if why.startswith("wood:")
                    and pad_dist(next(p for p in pads if p["id"] == why[5:]), x, y) > 0]
    # water inside the playable area: walk the map_bounds perimeter and a grid inside it
    water_inside = []
    xs = [bounds["x0"] + (bounds["x1"] - bounds["x0"]) * i / 60 for i in range(61)]
    ys = [bounds["y0"] + (bounds["y1"] - bounds["y0"]) * j / 60 for j in range(61)]
    min_s = min(inland(x, y) for x in xs for y in ys)
    for x in xs:
        for y in ys:
            z = ground(x, y)
            if z is not None and z <= SEA_LEVEL + 0.05:
                water_inside.append((round(x), round(y)))
    overlaps = []
    for i, a in enumerate(pads):
        for b in pads[i + 1:]:
            # sample a's outline against b
            if a["shape"] == "circle":
                probe = [(a["cx"] + math.cos(t) * a["r"], a["cy"] + math.sin(t) * a["r"]) for t in [k * math.pi / 8 for k in range(16)]]
            else:
                h_ = a["half"]
                probe = [(a["cx"] + h_ * u, a["cy"] + h_ * v) for u in (-1, -0.5, 0, 0.5, 1) for v in (-1, -0.5, 0, 0.5, 1) if abs(u) == 1 or abs(v) == 1]
            gap = min(pad_dist(b, x, y) for x, y in probe)
            if gap < 12 and abs(a["h"] - b["h"]) > 2:
                overlaps.append((a["id"], b["id"], round(gap, 1), round(abs(a["h"] - b["h"]), 1)))
    return dict(pads=pad_report, lane_tree_hits=lane_hits, lanes_crossing_pads=lane_pad, trees_on_pads=tree_on_pad,
                wood_trees_off_pad=wood_off_pad, water_inside_bounds=water_inside, min_inland_inside_bounds=round(min_s, 1),
                close_pads_with_height_step=overlaps)


def slope_report(H, bounds):
    worst = []
    n = len(H) - 1
    for i in range(n):
        for j in range(n):
            x = -GRID_HALF + i * CELL; y = GRID_CY - GRID_HALF + j * CELL
            if not (bounds["x0"] <= x <= bounds["x1"] and bounds["y0"] <= y <= bounds["y1"]):
                continue
            g = max(abs(H[i + 1][j] - H[i][j]), abs(H[i][j + 1] - H[i][j])) / CELL
            worst.append((round(math.degrees(math.atan(g)), 1), round(x), round(y)))
    worst.sort(reverse=True)
    over30 = sum(1 for w in worst if w[0] > 30)
    over45 = sum(1 for w in worst if w[0] > 45)
    return dict(max=worst[:8], cells_over_30deg=over30, cells_over_45deg=over45, cells=len(worst))


def audit(scene, delete=True):
    stray = [o.name for o in scene.objects if "traces_to" not in o.keys()]
    if delete:
        for name in stray:
            bpy.data.objects.remove(bpy.data.objects[name])
    return stray


def preview_world():
    """World, not objects: lit by Blender's bundled studio HDRI, while the camera
    sees the sky colour sampled from the reference. Nothing is added to the scene."""
    import os
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


# ------------------------------------------------------------------ scene
def build():
    for old_name in ("Map", "Terrain"):     # "Terrain" was the previous island draft; this replaces it
        old = bpy.data.scenes.get(old_name)
        if old:
            meshes = {o.data for o in old.objects if o.type == "MESH"}
            lights = {o.data for o in old.objects if o.type == "LIGHT"}
            for o in list(old.objects):
                bpy.data.objects.remove(o)
            for c in list(old.collection.children_recursive):
                bpy.data.collections.remove(c)
            bpy.data.scenes.remove(old)
            for d in meshes:
                if d.users == 0:
                    bpy.data.meshes.remove(d)
            for d in lights:
                if d.users == 0:
                    bpy.data.lights.remove(d)
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
    L, pads, lanes, bounds = load_layout()
    inland, outline, _ = make_coast(bounds, rng)
    height, land = make_height(pads, inland)
    stats = {}
    g, H = build_ground(colls["Map_Terrain"], height, inland, pads, lanes, mat)
    stats.update(g)
    stats.update(build_sea(colls["Map_Sea"], outline, mat))
    w, wood_trees = build_wood_nodes(colls["Map_Trees"], height, pads, lanes, rng, mat)
    stats.update(w)
    p, pines = build_pines(colls["Map_Trees"], height, inland, pads, lanes, bounds, rng, mat)
    stats.update(p)
    mk = build_markers(colls["Layout_Markers"], L, mmat)
    bpy.context.view_layer.update()
    return dict(scene=scene, stats=stats, markers=mk, L=L, pads=pads, lanes=lanes, bounds=bounds, inland=inland,
                trees=wood_trees + pines, H=H, height=height, n_pines=len(pines), n_wood=len(wood_trees))


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


bpy.app.driver_namespace["map"] = dict(build=build, verify=verify, slope_report=slope_report, audit=audit,
                                        show=show, set_markers=set_markers, orbit=orbit, look=look, rb=rb)
