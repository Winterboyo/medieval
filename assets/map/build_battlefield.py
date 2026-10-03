"""The mirrored battlefield exterior (layout.json v2.1), in its own Blender scene
("Battlefield"), for the first in-game visual review.

Run inside Blender with __file__ set, then bpy.app.driver_namespace["battlefield"]["build"]().

Roblox is Y-up, Blender is Z-up: (x, y, z)_roblox -> (x, -z, y)_blender. 1 unit = 1 stud.
Everything placed traces to a layout.json entry or an AGENTS.md §6 rule; every object
carries a "traces_to" property and audit() lists anything that does not.

What it builds:
- Ground: low-poly constrained-Delaunay island, flat castle pads (y 10) and node pads,
  near-flat meadow (y ~4), one central dirt road gate to gate whose 30-stud middle is
  kept clear, four shallow craters, a cliffed faceted shoreline of chunky rock, sea.
- Castle shells: the castle kit's wall bay, corner tower, gatehouse and banners
  (assets/castle/build_castle.py), scaled to avatar proportions measured against a 5-stud
  soldier in the concept image (TARGET-LAYOUT-PROPOSAL.md option C): walls 20.4, tower
  battlements 30.9, roof tips ~49; at the layout's 35 wall sections, 4 towers and gate.
  No interior meshes in this exterior preview. The approved Keep, stockpile room,
  barracks, specialists and ballista now have positions in layout.json, but require
  their own castle-art task. The gate door is left out so players can walk out.
- Props: four timber barricades, tunnel entrance portals hidden in their cover patches,
  courtyard tunnel exits (hatches), low rocks in cover zones.
- Pines only in the edge belt and the cover zones.
The ground, pines and shore rocks are generated for the west half and mirrored.

Per-face colours (CORNER byte attribute "Col"), flat shading. Palette sampled from
concepts/roman-battlefield-mirrored-castles.png and references/terrain-meadow.jpg
(Blender image loader), pulled toward AGENTS.md §9's targets where the concept's
sunset light shifts them.
"""
import bpy, bmesh, json, math, os, random, importlib.util
from mathutils import Vector, Euler, Matrix

_HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
LAYOUT = os.path.normpath(os.path.join(_HERE, "..", "..", "layout.json"))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MAP = _load("bf_map_helpers", os.path.join(_HERE, "build_map.py"))
KIT = _load("bf_castle_kit", os.path.normpath(os.path.join(_HERE, "..", "castle", "build_castle.py")))

SEED = 20261001
SRGB = {
    "GRASS": (88, 123, 56),        # deeper greens, sampled against the user's forest screenshot
    "GRASS_2": (82, 116, 53),
    "GRASS_SHADE": (74, 106, 50),
    "MEADOW": (97, 132, 62),
    "BLADE_DARK": (38, 83, 33),
    "BLADE_MID": (55, 103, 42),
    "BLADE_LIGHT": (72, 122, 51),
    "DIRT": (130, 112, 72),        # road and crater walls (round 3: toward the concept's olive-tan path, was 134,108,70)
    "DIRT_DARK": (104, 86, 62),    # crater floors
    "ROCK": (104, 100, 124),       # cliff faces, boulders: muted purple-grey
    "ROCK_DARK": (80, 78, 102),
    "SEA_DEEP": (70, 96, 138),
    "WATER": (98, 126, 160),       # shallows
    "FOAM": (196, 208, 218),       # surf at the cliff foot
    "PINE": (46, 68, 44),
    "PINE_2": (58, 82, 50),
    "TRUNK": (90, 64, 46),
}
# props (barricades, portals, hatches) use the castle kit's Piece, so their colours go
# into the kit's palette under their own names
KIT.SRGB.update({"BF_TIMBER": (122, 90, 60), "BF_TIMBER_DARK": (92, 66, 44), "BF_HOLE": (34, 30, 28),
                 "BF_ROCK": SRGB["ROCK"], "BF_ROCK_DARK": SRGB["ROCK_DARK"], "BF_DUMMY": (230, 120, 40)})
MARKER = {"castle": (235, 40, 40), "gate": (255, 215, 0), "road": (255, 215, 0), "spawn": (255, 255, 255),
          "home": (0, 220, 120), "mid": (0, 200, 255), "forward": (255, 130, 0), "center": (200, 0, 255),
          "cover": (120, 255, 60), "crater": (255, 80, 200), "barricade": (255, 255, 255), "tunnel": (255, 140, 0),
          "boundary": (255, 0, 255), "axis": (255, 255, 255), "origin": (255, 0, 255), "rear": (120, 120, 255),
          "interior": (220, 80, 180), "stockpile": (255, 180, 40), "clear_route": (255, 245, 90)}
TEAM_COL = {"A": (184, 65, 58), "B": (58, 95, 184)}

HALF_X, HALF_Y = 672.0, 480.0
RELIEF = 1.5
PAD_BLEND = 40.0
GRASS_2_SHARE = 0.18
CLIFF = 12.0                 # land drops to the waterline over this many studs inland of the coast
SHORE_LOW, SEABED = -2.0, -22.0
SEA_HALF = 1000.0
ROAD_WOBBLE = 1.6            # dirt edge meanders up to ~3 beyond the clear 30
ROAD_GATE_WIDEN = 9.0        # and widens by this much at the gates
WALL_SZ = 1.4                # wall bay scaled up: top of merlons 14.55 -> 20.4 (measured 20-23)
TOWER_S = 1.12               # corner tower, uniform: battlement 27.6 -> 30.9, roof tip 43.7 -> 48.9
                             # (measured 31-35 / 42-45 plus spike; was 1.33 = tip 62 from the proposal)
GATE_S = 1.3                 # gatehouse scaled uniformly: roof walk 21.4 -> 27.8, opening 13 x 18.2 (measured ~18 tall)
BANNER_S = 1.15


def rb(x, y, z):
    return (x, -z, y)


def smooth(a, b, x):
    if b == a:
        return 1.0 if x >= b else 0.0
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


# ------------------------------------------------------------------ layout (Blender coordinates)
def load_layout():
    with open(LAYOUT, encoding="utf-8") as f:
        L = json.load(f)
    assert L["meta"]["version"].startswith("2."), "build_battlefield needs layout.json v2"
    pads = []
    for c in L["castles"]:
        cx, cy, _ = rb(c["center"]["x"], 0, c["center"]["z"])
        pads.append(dict(kind="castle", id=c["id"], team=c["team"], cx=cx, cy=cy, shape="square",
                         half=c["pad"]["size"] / 2, inner=c["ring_size"]["x"] / 2, h=c["pad"]["y"]))
    for s in L["resource_node_slots"]:
        cx, cy, _ = rb(s["position"]["x"], 0, s["position"]["z"])
        pads.append(dict(kind="node", id=s["id"], ring=s["ring"], cx=cx, cy=cy, shape="circle",
                         r=s["pad_radius"], inner=s["pad_radius"] - 8.0, h=s["position"]["y"]))
    r = L["central_road"]
    road = dict(id=r["id"], x0=r["min_x"], x1=r["max_x"], half=r["width"] / 2)
    craters = [dict(id=c["id"], cx=c["x"], cy=-c["z"], r=c["outer_radius"], rf=c["floor_radius"],
                    depth=c["floor_depth"], rim=c["rim_height"]) for c in L["craters"]]
    barricades = [dict(id=b["id"], cx=b["x"], cy=-b["z"], lx=b["length_x"], dz=b["depth_z"], h=b["height"]) for b in L["barricades"]]
    cover = [dict(id=z["id"], x0=z["min_x"], x1=z["max_x"], y0=-z["max_z"], y1=-z["min_z"]) for z in L["cover_zones"]]
    tunnels = []
    for t in L["tunnels"]:
        p = lambda q: (q["x"], -q["z"])
        tunnels.append(dict(id=t["id"], team=t["team"], entrance=p(t["entrance"]), bend=p(t["bend"]), exit=p(t["exit"]),
                            width=t["width"], cover=t["cover_zone"]))
    b = L["map_bounds"]
    bounds = dict(x0=b["min_x"], x1=b["max_x"], y0=-b["max_z"], y1=-b["min_z"])
    return dict(L=L, pads=pads, road=road, craters=craters, barricades=barricades, cover=cover, tunnels=tunnels, bounds=bounds)


def pad_dist(p, x, y):
    return MAP.pad_dist(p, x, y)


def in_rect(z, x, y, grow=0.0):
    return z["x0"] - grow <= x <= z["x1"] + grow and z["y0"] - grow <= y <= z["y1"] + grow


def road_half(R, x):
    """Half width of the dirt (not the clear strip, which is R['half'] everywhere)."""
    ax = abs(x)
    wob = ROAD_WOBBLE * (1.0 + 0.6 * math.sin(ax / 23.0 + 0.4) + 0.4 * math.sin(ax / 9.7 + 1.1))
    widen = ROAD_GATE_WIDEN * (1.0 - smooth(0.0, 45.0, R["x1"] - ax))
    return R["half"] + max(0.0, wob) + widen


def in_road_dirt(R, x, y):
    return abs(x) <= R["x1"] + 4.0 and abs(y) <= road_half(R, x)


def in_road_clear(R, x, y, grow=0.0):
    return abs(x) <= R["x1"] and abs(y) <= R["half"] + grow


def crater_profile(c, d):
    """Placeholder section from the layout: floor depth below, rim height above the field."""
    rim_r = (c["rf"] + c["r"]) / 2
    if d <= c["rf"]:
        return -c["depth"]
    if d <= rim_r:
        return -c["depth"] + (c["depth"] + c["rim"]) * (d - c["rf"]) / (rim_r - c["rf"])
    if d <= c["r"]:
        return c["rim"] * (c["r"] - d) / (c["r"] - rim_r)
    return 0.0


# ------------------------------------------------------------------ height
def make_height(D, inland):
    pads, R, craters = D["pads"], D["road"], D["craters"]

    def base(x, y, und=1.0):
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
        far = hsum / wsum + MAP.undulation(x, y) * RELIEF * t * und
        return best["h"] * (1 - t) + far * t

    def height(x, y):
        s = inland(x, y)
        if s < 0:
            return SHORE_LOW + (SEABED - SHORE_LOW) * smooth(0, 30, -s)
        h = base(x, y)
        if abs(x) <= R["x1"] + 12:
            hw = road_half(R, x)
            w = 1.0 - smooth(hw, hw + 14.0, abs(y))
            if w > 0:
                h = h * (1 - w) + base(x, 0.0, 0.0) * w
        for c in craters:
            d = math.hypot(x - c["cx"], y - c["cy"])
            if d < c["r"]:
                h += crater_profile(c, d)
        if s < CLIFF:
            h = SHORE_LOW + (h - SHORE_LOW) * smooth(0, CLIFF, s) ** 0.6
        return h
    return height, base


# ------------------------------------------------------------------ ground
def west_constraints(D):
    pts, edges = [], []

    def poly(vs, closed=True):
        base = len(pts)
        pts.extend(vs)
        n = len(vs)
        for i in range(n if closed else n - 1):
            edges.append((base + i, base + (i + 1) % n))

    def circle(cx, cy, r, n):
        return [(cx + math.cos(2 * math.pi * k / n) * r, cy + math.sin(2 * math.pi * k / n) * r) for k in range(n)]

    for p in D["pads"]:
        if p["shape"] == "square":
            if p["cx"] > 0:
                continue
            h = p["half"]
            poly([(p["cx"] - h, p["cy"] - h), (p["cx"] + h, p["cy"] - h), (p["cx"] + h, p["cy"] + h), (p["cx"] - h, p["cy"] + h)])
        else:
            n = max(16, int(2 * math.pi * p["r"] / 8.0) // 4 * 4)
            ring = [(0.0 if abs(x) < 1e-6 else x, y) for x, y in circle(p["cx"], p["cy"], p["r"], n)]
            if p["cx"] < -p["r"]:
                poly(ring)
            elif abs(p["cx"]) < 1e-6:
                start = n // 4
                poly([ring[(start + k) % n] for k in range(n // 2 + 1)], closed=False)
    # the road's dirt outline, west half, open at the axis
    R = D["road"]
    xs = [0.0]
    x = 0.0
    while x > -(R["x1"] + 4.0) + 10:
        x -= 10.0
        xs.append(x)
    xs.append(-(R["x1"] + 4.0))
    top = [(x, road_half(R, x)) for x in xs]
    bot = [(x, -road_half(R, x)) for x in reversed(xs)]
    poly(top + bot, closed=False)
    # collision cell lines: no triangle may cross one, so every ground piece stays cell-sized
    # (large flat pad triangles spilling across cells made 200-stud pieces, 0.9 studs off)
    xs, ys = terrain_cells(D)
    for x in xs:
        if -HALF_X < x < 0:
            poly([(x, -HALF_Y + k * 8) for k in range(int(2 * HALF_Y // 8) + 1)], closed=False)
    for y in ys:
        if -HALF_Y < y < HALF_Y:
            poly([(-HALF_X + k * 8, y) for k in range(int(HALF_X // 8) + 1)], closed=False)
    # craters: floor edge, rim crest, outer edge, centre
    for c in D["craters"]:
        if c["cx"] > 0:
            continue
        rim_r = (c["rf"] + c["r"]) / 2
        for r, n in ((c["rf"], 10), (rim_r, 14), (c["r"], 18)):
            poly(circle(c["cx"], c["cy"], r, n))
        pts.append((c["cx"], c["cy"]))
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


def face_col(D, inland, V, tri):
    p = [V[i] for i in tri]
    cx = sum(q[0] for q in p) / 3; cy = sum(q[1] for q in p) / 3
    nz = MAP.face_normal_z(*p)
    s = inland(cx, cy)
    if s < 0:
        return "ROCK_DARK"
    if s < CLIFF or nz < 0.72:
        return "ROCK" if MAP.facet_hash(cx, cy) < 0.6 else "ROCK_DARK"
    for c in D["craters"]:
        d = math.hypot(cx - c["cx"], cy - c["cy"])
        if d < c["rf"] + 0.5:
            return "DIRT_DARK"
        if d < (c["rf"] + c["r"]) / 2 + 0.5:
            return "DIRT"
        if d < c["r"]:
            return "GRASS_2"
    if in_road_dirt(D["road"], cx, cy):
        return "DIRT"
    for pd in D["pads"]:
        if pd["kind"] == "node" and pad_dist(pd, cx, cy) == 0.0:
            return "MEADOW" if MAP.facet_hash(cx, cy) < 0.7 else "GRASS"
    # Broad mottled swaths, not a random colour on every triangle. The 11-stud
    # terrain facets still catch light; the colour reads as meadow from afar.
    swath = (0.52 * math.sin(cx / 54.0 + 0.4) * math.cos(cy / 62.0 - 0.6)
             + 0.31 * math.sin((cx + 0.65 * cy) / 91.0))
    if swath < -0.42:
        return "GRASS_SHADE"
    if swath > 0.43:
        return "MEADOW"
    return "GRASS_2" if MAP.facet_hash(cx, cy) < GRASS_2_SHARE else "GRASS"


# Ground pieces are cut for ROBLOX COLLISION, measured in Studio (2026-10-01):
# PreciseConvexDecomposition blurs at a fixed fraction of a piece's size. A 380 x 274
# tile was off by up to 2.3 studs; 168 x 120 by up to 1.3; 84 x 60 averaged 0.1-0.2
# (worst ~0.5); a crater alone in a ~50-stud piece was exact. Any piece with a hole or a
# bite cut out of it gets a "lid" over the gap, so a crater is never cut out of anything:
# each sits whole in its own cell. Cells are at most MAX_CELL_X x MAX_CELL_Y, with
# breakpoints centred on the craters, mirrored across x = 0.
MAX_CELL_X, MAX_CELL_Y = 84.0, 60.0
CRATER_CELL_X, CRATER_CELL_Y = 50.0, 60.0


def _breaks(lo, hi, centres, cell, max_cell):
    """Sorted breakpoints from lo to hi: a cell of width `cell` centred on each centre,
    the gaps between filled with near-equal cells no wider than max_cell."""
    fixed = []
    for c in sorted(centres):
        fixed += [c - cell / 2, c + cell / 2]
    pts, prev = [lo], lo
    for f in fixed + [hi]:
        f = min(max(f, prev), hi)
        gap = f - prev
        if gap > 1e-6:
            n = max(1, int(math.ceil(gap / max_cell - 1e-9)))
            pts += [prev + gap * k / n for k in range(1, n + 1)]
        prev = f
    out = []
    for p in pts:
        if not out or p - out[-1] > 1e-6:
            out.append(p)
    return out


def terrain_cells(D):
    """(x breakpoints, y breakpoints) in Blender coordinates; x mirrored about 0."""
    west_cx = sorted({c["cx"] for c in D["craters"] if c["cx"] < 0})
    west = _breaks(-HALF_X, 0.0, west_cx, CRATER_CELL_X, MAX_CELL_X)
    xs = west + [-x for x in reversed(west[:-1])]
    ys = _breaks(-HALF_Y, HALF_Y, sorted({c["cy"] for c in D["craters"]}), CRATER_CELL_Y, MAX_CELL_Y)
    return xs, ys


def cell_of(xs, ys, x, y):
    import bisect
    i = max(0, min(len(xs) - 2, bisect.bisect_right(xs, x) - 1))
    j = max(0, min(len(ys) - 2, bisect.bisect_right(ys, y) - 1))
    return i, j


def build_ground(coll, D, height, inland, rng, mat):
    from mathutils import geometry
    cpts, cedges = west_constraints(D)
    cell_xs, cell_ys = terrain_cells(D)
    spacing_at = lambda x, y: MAP.SPACING if inland(x, y) > -40 else MAP.SPACING_SEA
    free = MAP.poisson_points(rng, -HALF_X + 2, -2, -HALF_Y + 2, HALF_Y - 2, spacing_at, 60000)
    R = D["road"]

    def near_outline(x, y):
        for p in D["pads"]:
            d = (abs(math.hypot(x - p["cx"], y - p["cy"]) - p["r"]) if p["shape"] == "circle"
                 else abs(max(abs(x - p["cx"]), abs(y - p["cy"])) - p["half"]))
            if d < 3.0:
                return True
        if abs(x) <= R["x1"] + 7 and abs(abs(y) - road_half(R, x)) < 3.0:
            return True
        if any(abs(x - b) < 2.5 for b in cell_xs) or any(abs(y - b) < 2.5 for b in cell_ys):
            return True
        return any(math.hypot(x - c["cx"], y - c["cy"]) < c["r"] + 3.0 for c in D["craters"])
    free = [(x, y) for x, y in free if not near_outline(x, y)]
    coords = [Vector(p) for p in cpts + free]
    out_v, _, out_f, _, _, _ = geometry.delaunay_2d_cdt(coords, cedges, [], 0, 1e-4, True)
    west = [(v.x, v.y) for v in out_v]
    index, verts = {}, []

    def vid(x, y):
        k = (round(x, 4), round(y, 4))
        if k not in index:
            index[k] = len(verts)
            verts.append((x, y))
        return index[k]
    tris = []
    for f in out_f:
        a, b, c = (west[i] for i in f)
        tris.append((vid(*a), vid(*b), vid(*c)))
        tris.append((vid(-a[0], a[1]), vid(-c[0], c[1]), vid(-b[0], b[1])))
    V3 = [(x, y, height(x, y)) for x, y in verts]
    # Cut into collision-sized cells (see terrain_cells); a crater sits whole in its cell.
    xs, ys = terrain_cells(D)
    buckets = {}
    for t in tris:
        p = [V3[i] for i in t]
        cx = sum(q[0] for q in p) / 3; cy = sum(q[1] for q in p) / 3
        buckets.setdefault(cell_of(xs, ys, cx, cy), []).append((t, face_col(D, inland, V3, t)))
    crater_cells = {cell_of(xs, ys, c["cx"], c["cy"]): c["id"] for c in D["craters"]}
    stats = {}
    for key, items in sorted(buckets.items()):
        used = sorted({i for t, _ in items for i in t})
        remap = {old: new for new, old in enumerate(used)}
        tv = [V3[i] for i in used]
        tf = [tuple(remap[i] for i in t) for t, _ in items]
        # named by Roblox-facing cell indices; a crater's cell also carries the crater id
        name = "BF_Terrain_%02d_%02d" % key + ("_" + crater_cells[key] if key in crater_cells else "")
        me = MAP.colour_mesh(name, tv, tf, [SRGB[c] for _, c in items], [False] * len(tf), mat)
        MAP.add_object(coll, name, me, "layout.json v2: ground around pads, road, craters (AGENTS §6)")
        stats[name] = len(tf)
    return stats, V3, tris


# ---------------------------------------------------------- meadow groundcover
def build_groundcover(coll, D, height, inland, mat):
    """Visual-only, mirrored grass tufts. Terrain tiles remain the walkable floor.

    Five narrow double-sided blades per tuft provide a silhouette at avatar
    height without textures or alpha sorting. Castle routes, the road, structures,
    resource pads, craters, and tunnel mouths retain their gameplay readability.
    """
    rng = random.Random(SEED + 317)
    stride = 3.8
    buckets = {}
    counts = {"tufts": 0, "field": 0, "castle": 0, "node": 0}

    def box_contains(rect, x, y, margin):
        return (rect["min_x"] - margin <= x <= rect["max_x"] + margin and
                -rect["max_z"] - margin <= y <= -rect["min_z"] + margin)

    def castle_exclusion(x, y):
        for castle in D["L"]["castles"]:
            interior = castle["interior"]
            structures = [interior["keep"], interior["barracks"],
                          *interior["specialists"],
                          interior["surfaces"]["blacksmith_forecourt"]]
            if any(box_contains(b, x, y, 2.2) for b in structures):
                return True
            if any(box_contains(b, x, y, 1.0)
                   for b in interior["clear_areas"].values()):
                return True
        return False

    def bucket_for(x, y):
        # Smaller than terrain collision cells' budget but few enough parts to
        # stream efficiently in Roblox (8 columns x 8 rows over the island).
        return (min(7, max(0, int((x + HALF_X) / (2 * HALF_X / 8)))),
                min(7, max(0, int((y + HALF_Y) / (2 * HALF_Y / 8)))))

    for i in range(int(HALF_X / stride)):
        for j in range(int(2 * HALF_Y / stride)):
            x = -HALF_X + (i + 0.5) * stride + rng.uniform(-0.9, 0.9)
            y = -HALF_Y + (j + 0.5) * stride + rng.uniform(-0.9, 0.9)
            if x > -2.5 or inland(x, y) < CLIFF + 5:
                continue
            if in_road_dirt(D["road"], x, y) or (
                    abs(x) <= D["road"]["x1"] + 5 and
                    abs(y) < road_half(D["road"], x) + 1.5):
                continue
            if any(math.hypot(x - c["cx"], y - c["cy"]) < c["r"] + 0.5
                   for c in D["craters"]):
                continue
            if any(abs(x - b["cx"]) < b["lx"] / 2 + 2 and
                   abs(y - b["cy"]) < b["dz"] / 2 + 2
                   for b in D["barricades"]):
                continue
            if any(math.hypot(x - t["entrance"][0], y - t["entrance"][1]) < 10
                   for t in D["tunnels"]):
                continue

            pad = next((p for p in D["pads"] if pad_dist(p, x, y) == 0), None)
            if pad and pad["kind"] == "castle":
                if castle_exclusion(x, y) or rng.random() < 0.52:
                    continue
                kind, low, high = "castle", 0.32, 0.75
            elif pad and pad["kind"] == "node":
                if rng.random() < 0.25:
                    continue
                kind, low, high = "node", 0.45, 0.95
            else:
                kind, low, high = "field", 0.75, 1.6
            if any(in_rect(z, x, y) for z in D["cover"]):
                low, high = max(low, 1.1), max(high, 2.1)
            if abs(x) <= D["road"]["x1"] + 6 and \
                    road_half(D["road"], x) + 1.5 < abs(y) < road_half(D["road"], x) + 10:
                low, high = max(low, 0.95), max(high, 1.75)

            z = height(x, y) + 0.015
            h = rng.uniform(low, high)
            rot = rng.uniform(0, 2 * math.pi)
            blades = []
            for blade in range(5):
                a = rot + blade * 2 * math.pi / 5 + rng.uniform(-0.2, 0.2)
                ax, ay = math.cos(a), math.sin(a)
                spread = rng.uniform(0.08, 0.56)
                bx, by = x + ax * spread, y + ay * spread
                bh = h * rng.uniform(0.68, 1.14)
                width = rng.uniform(0.18, 0.36) * (0.7 + 0.3 * bh)
                side = (-ay, ax)
                v0 = (bx - side[0] * width / 2, by - side[1] * width / 2, z)
                v1 = (bx + side[0] * width / 2, by + side[1] * width / 2, z)
                tip = (bx + ax * bh * 0.30, by + ay * bh * 0.30, z + bh)
                tone = rng.choices(("BLADE_DARK", "BLADE_MID", "BLADE_LIGHT"),
                                   weights=(3, 4, 1), k=1)[0]
                blades.append(((v0, v1, tip), tone))
            for mx in (x, -x):
                tris = buckets.setdefault(bucket_for(mx, y), [])
                for (v0, v1, tip), tone in blades:
                    if mx > 0:
                        v0, v1, tip = ((-v[0], v[1], v[2]) for v in (v0, v1, tip))
                    tris.extend((((v0, v1, tip), tone),
                                 ((v1, v0, tip), tone)))
            counts["tufts"] += 2
            counts[kind] += 2

    stats = {}
    for key, tris in sorted(buckets.items()):
        name = "BF_Grass_%02d_%02d" % key
        stats[name] = MAP.tri_object(
            coll, name, tris, mat,
            "AGENTS §6.5 and layout.json: visual mirrored meadow groundcover; no collision",
            SRGB)
    if max(stats.values(), default=0) >= 15000:
        raise AssertionError("A grass tile exceeded the 15k triangle target")
    return stats, counts


# ------------------------------------------------------------------ sea and shore
def build_sea(coll, outline, inland, rng, mat):
    from mathutils import geometry
    # Open sea to the horizon: a 3 x 3 grid of separate 2,000-stud squares, each under
    # Roblox's 2,048-stud MeshPart limit, plus the faceted shallows ring round the coast.
    s = SEA_HALF
    stats = {}
    for i in (-1, 0, 1):
        for j in (-1, 0, 1):
            ox, oy = i * 2 * s, j * 2 * s
            name = "BF_Sea_Deep_%d_%d" % (i + 1, j + 1)
            me = MAP.colour_mesh(name, [(ox - s, oy - s, 0.0), (ox + s, oy - s, 0.0), (ox + s, oy + s, 0.0), (ox - s, oy + s, 0.0)],
                                 [(0, 1, 2), (0, 2, 3)], [SRGB["SEA_DEEP"]] * 2, [False, False], mat)
            MAP.add_object(coll, name, me, "AGENTS §6.5: open sea outside the playable area")
            stats[name] = 2
    verts, faces, cols = [], [], []
    rim = outline(push=45.0)
    xs = [p[0] for p in rim]; ys = [p[1] for p in rim]
    inner = MAP.poisson_points(rng, min(xs), max(xs), min(ys), max(ys), lambda x, y: 14.0, 30000)
    inner = [(x, y) for x, y in inner if -42 < inland(x, y) < 8]
    coords = [Vector(p) for p in rim] + [Vector(p) for p in inner]
    ring_edges = [(i, (i + 1) % len(rim)) for i in range(len(rim))]
    out_v, _, out_f, _, _, _ = geometry.delaunay_2d_cdt(coords, ring_edges, [list(range(len(rim)))], 1, 1e-4, True)
    verts += [(v.x, v.y, 0.12 + (MAP.facet_hash(v.x, v.y) - 0.5) * 0.35) for v in out_v]
    for f in out_f:
        faces.append(tuple(f))
        cx = sum(out_v[i].x for i in f) / 3; cy = sum(out_v[i].y for i in f) / 3
        sv = inland(cx, cy)
        foam = sv > -7 or (sv > -14 and MAP.facet_hash(cx * 1.7, cy) < 0.35)
        cols.append(SRGB["FOAM"] if foam else SRGB["WATER"])
    me = MAP.colour_mesh("BF_Sea_Shallows", verts, faces, cols, [False] * len(faces), mat)
    MAP.add_object(coll, "BF_Sea_Shallows", me, "AGENTS §6.5: faceted shallows and surf round the coast")
    stats["BF_Sea_Shallows"] = len(faces)
    return stats


def hull_rock(rng, cx, cy, z0, sx, sy, top, yaw, pts=11):
    """A chunky faceted boulder: the convex hull of jittered points, flat bottom at z0."""
    bm = bmesh.new()
    for k in range(pts):
        a = 2 * math.pi * k / pts + rng.uniform(-0.25, 0.25)
        for zf, rf in ((0.0, 1.0), (rng.uniform(0.55, 0.8), rng.uniform(0.75, 1.0)), (1.0, rng.uniform(0.25, 0.6))):
            if zf == 1.0 and k % 2:
                continue
            x = math.cos(a) * sx * rf * rng.uniform(0.85, 1.05)
            y = math.sin(a) * sy * rf * rng.uniform(0.85, 1.05)
            bm.verts.new((x, y, z0 + (top - z0) * zf * rng.uniform(0.9, 1.0)))
    bmesh.ops.convex_hull(bm, input=bm.verts)
    cy_, sy_ = math.cos(yaw), math.sin(yaw)
    tris = []
    bm.faces.ensure_lookup_table()
    bmesh.ops.triangulate(bm, faces=bm.faces)
    for f in bm.faces:
        vs = []
        for v in f.verts:
            x, y, z = v.co
            vs.append((cx + x * cy_ - y * sy_, cy + x * sy_ + y * cy_, z))
        n = f.normal
        col = "ROCK" if (n.z > 0.35 or (n.x * 0.6 - n.y * 0.8) > 0.0) else "ROCK_DARK"
        tris.append((tuple(vs), col))
    bm.free()
    return tris


def build_shore(coll, outline, inland, rng, mat):
    """The concept's cliff: chunky rock blocks along the whole coast, a few sea stacks.
    West half only (x < -8), mirrored."""
    west = []
    coast = outline(push=0.0, n=320)
    acc = 0.0
    for i in range(len(coast)):
        (x0, y0), (x1, y1) = coast[i], coast[(i + 1) % len(coast)]
        acc += math.hypot(x1 - x0, y1 - y0)
        if acc < 13.0 or x0 > -8:
            continue
        acc = rng.uniform(-3.0, 3.0)
        nx, ny = x0, y0
        L = math.hypot(nx, ny) or 1.0
        out = rng.uniform(0.0, 8.0)                         # at the cliff foot, a little out to sea
        x, y = x0 + nx / L * out, y0 + ny / L * out
        size = rng.uniform(13.0, 24.0)                      # round 1: bigger, taller blocks, like the concept's cliff
        west.append((x, y, -8.0, size, size * rng.uniform(0.7, 1.0), rng.uniform(8.0, 15.0), rng.uniform(0, math.pi)))
        if rng.random() < 0.45:                              # a second, lower block in front
            o2 = out + rng.uniform(8, 14)
            west.append((x0 + nx / L * o2, y0 + ny / L * o2, -6.0, size * 0.7, size * 0.55, rng.uniform(1.0, 4.0), rng.uniform(0, math.pi)))
    far = outline(push=90.0, n=48)
    for k in rng.sample(range(len(far)), 24):                # sea stacks
        x, y = far[k]
        if x > -40 or len([w for w in west if w[6] == -1]) >= 7:
            continue
        x += rng.uniform(-30, 30); y += rng.uniform(-30, 30)
        west.append((x, y, -10.0, rng.uniform(10, 16), rng.uniform(8, 13), rng.uniform(16, 32), -1))
    tris_by_tile = {}
    for x, y, z0, sx, sy, top, yaw in west:
        yaw = rng.uniform(0, math.pi) if yaw == -1 else yaw
        t = hull_rock(rng, x, y, z0, sx, sy, top, yaw)
        tm = [(tuple((-px, py, pz) for px, py, pz in reversed(vs)), c) for vs, c in t]
        for tri_set, (tx, ty) in ((t, (x, y)), (tm, (-x, y))):
            tris_by_tile.setdefault(MAP.tile_of(tx, ty), []).extend(tri_set)
    stats = {}
    for k, tris in sorted(tris_by_tile.items()):
        name = "BF_Shore_Rocks_%d_%d" % k
        stats[name] = MAP.tri_object(coll, name, tris, mat, "AGENTS §6.5: faceted shoreline (cliff rocks, sea stacks), mirrored", SRGB)
    return stats, len(west) * 2


# ------------------------------------------------------------------ pines and cover rocks
def pine(x, y, z, s, rot, tone):
    tris = MAP.pine(x, y, z, s, rot)
    return [(t, tone if c == "PINE" else c) for t, c in tris]


def build_pines(coll, D, height, inland, rng, mat):
    B, R = D["bounds"], D["road"]
    belt = D["L"]["decoration_rules"]["edge_belt_depth"]

    def edge_depth(x, y):
        return min(x - B["x0"], B["x1"] - x, y - B["y0"], B["y1"] - y)

    def blocked(x, y, cr):
        if inland(x, y) < CLIFF + 6:
            return True
        if any(pad_dist(p, x, y) < cr + 2 for p in D["pads"]):
            return True
        if in_road_clear(R, x, y, grow=cr + 4) or in_road_dirt(R, x, y):
            return True
        if any(math.hypot(x - c["cx"], y - c["cy"]) < c["r"] + cr for c in D["craters"]):
            return True
        if any(in_rect(dict(x0=b["cx"] - b["lx"] / 2, x1=b["cx"] + b["lx"] / 2, y0=b["cy"] - b["dz"] / 2, y1=b["cy"] + b["dz"] / 2), x, y, cr + 3)
               for b in D["barricades"]):
            return True
        for t in D["tunnels"]:
            ex, ey = t["entrance"]
            side = 1 if t["team"] == "A" else -1             # A's portal opens east (+x)
            if math.hypot(x - ex, y - ey) < 6 + cr or (0 < (x - ex) * side < 16 and abs(y - ey) < 4 + cr):
                return True
        return False

    west = []

    def plant(x, y, why, smin=0.7, smax=0.95):   # 11-15 studs tall, as the concept's pines beside a 5-stud soldier
        if x > -4:
            return
        s = rng.uniform(smin, smax)
        cr = 4.4 * s
        if blocked(x, y, cr) or any(math.hypot(x - px_, y - py_) < 6.0 for px_, py_, _, _, _, _ in west):
            return
        west.append((x, y, s, rng.uniform(0, math.pi), why, "PINE_2" if rng.random() < 0.35 else "PINE"))

    clusters = 0
    for _ in range(3000):
        if clusters >= 52:
            break
        cx = rng.uniform(B["x0"] - 40, -30)
        cy = rng.uniform(B["y0"] - 40, B["y1"] + 40)
        if edge_depth(cx, cy) > belt - 8 or blocked(cx, cy, 6):
            continue
        clusters += 1
        radius = rng.uniform(12, 28)
        for _ in range(rng.randint(7, 15)):
            a, d = rng.uniform(0, 2 * math.pi), radius * math.sqrt(rng.uniform(0, 1))
            x, y = cx + math.cos(a) * d, cy + math.sin(a) * d
            if edge_depth(x, y) <= belt:
                plant(x, y, "AGENTS §6.5: pine belt near the map edge")
    for z in D["cover"]:
        if z["x1"] > 0:
            continue
        for _ in range(60):
            plant(rng.uniform(z["x0"] + 3, z["x1"] - 3), rng.uniform(z["y0"] + 3, z["y1"] - 3),
                  "layout.json cover_zones " + z["id"], 0.65, 0.85)
    placed = []
    for x, y, s, rot, why, tone in west:
        placed.append((x, y, s, rot, why, tone))
        placed.append((-x, y, s, math.pi - rot, why.replace("A_Cover", "B_Cover"), tone))
    buckets = {}
    for x, y, s, rot, _, tone in placed:
        buckets.setdefault(MAP.tile_of(x, y), []).extend(pine(x, y, height(x, y), s, rot, tone))
    stats = {}
    for k, tris in sorted(buckets.items()):
        name = "BF_Pines_%d_%d" % k
        stats[name] = MAP.tri_object(coll, name, tris, mat, "AGENTS §6.5: pines (edge belt + cover zones), mirrored", SRGB)
    return stats, [(x, y, 4.4 * s, why) for x, y, s, _, why, _ in placed]


def build_cover_rocks(coll, D, height, rng, mat):
    """A few low rocks in each gate-side cover zone and beside each tunnel portal: crouch
    cover, never in the road."""
    west, tris = [], []
    for z in D["cover"]:
        if z["x1"] > 0:
            continue
        n = 2 if "Tunnel" in z["id"] else 3
        for _ in range(40):
            if n == 0:
                break
            x, y = rng.uniform(z["x0"] + 4, z["x1"] - 4), rng.uniform(z["y0"] + 4, z["y1"] - 4)
            if any(math.hypot(x - t["entrance"][0], y - t["entrance"][1]) < 9 for t in D["tunnels"]):
                continue
            if any(math.hypot(x - a, y - b) < 9 for a, b, *_ in west):
                continue
            west.append((x, y, rng.uniform(2.4, 3.6), rng.uniform(1.6, 2.6), rng.uniform(2.2, 3.4), rng.uniform(0, math.pi), z["id"]))
            n -= 1
    for x, y, sx, sy, top, yaw, zid in west:
        for mx in (x, -x):
            g = height(mx, y)
            t = hull_rock(random.Random(int(abs(x) * 10 + y)), mx, y, g - 0.8, sx, sy, g + top, yaw if mx < 0 else math.pi - yaw, pts=7)
            if mx > 0:
                t = [(tuple((-px + 2 * mx, py, pz) for px, py, pz in vs), c) for vs, c in t]   # keep winding: rebuilt per side
            tris.extend(t)
    n = MAP.tri_object(coll, "BF_Cover_Rocks", tris, mat, "layout.json cover_zones: low rocks for crouch cover", SRGB)
    return {"BF_Cover_Rocks": n}, [(x, y) for x, y, *_ in west] + [(-x, y) for x, y, *_ in west]


# ------------------------------------------------------------------ props
def make_barricade(mat):
    """12 x 4 x 3.5 timber barricade (layout.json barricades), length along local X.
    A wall of sharpened stakes on two braces, with propped X-frames in front and behind:
    solid enough to hide a crouched avatar; its box is the collision."""
    p = KIT.Piece()
    for k in range(12):
        x = -5.5 + k
        h = 2.85 + (0.25 if k % 3 == 0 else 0.0) - (0.2 if k % 4 == 1 else 0.0)
        p.frustum(x, 0, -0.6, 0.48, h, 0.44, 5, "BF_TIMBER", rot=0.3 * k)
        p.cone(x, 0, h, 0.44, h + 0.55, 5, "BF_TIMBER_DARK", rot=0.3 * k)
    for z in (0.7, 2.1):
        p.along_x(-6.0, 0.55, z, 12.0, 0.26, 0.26, 6, "BF_TIMBER_DARK")
        p.along_x(-6.0, -0.55, z + 0.3, 12.0, 0.24, 0.24, 6, "BF_TIMBER_DARK")
    for x in (-4.5, 0.0, 4.5):
        for side in (-1, 1):                                    # X-frames: two stakes crossed, leaning out
            for lean in (-1, 1):
                a = Vector((x + lean * 0.9, side * 0.6, -0.3))
                b = Vector((x - lean * 0.9, side * 1.9, 2.4))
                d = b - a
                m = Matrix.Translation(a) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4()
                p.box(-0.17, 0.17, -0.17, 0.17, 0, d.length, "BF_TIMBER", m)
    return p.finish("BF_Barricade", mat)


def make_tunnel_entrance(mat):
    """Opening faces local +X; the tunnel runs away along -X. A low rock mound with a
    timber frame and a dark mouth, half-covered by leaning planks."""
    p = KIT.Piece()
    rng = random.Random(7)
    for k in range(9):                                          # mound of rocks behind and beside
        a = math.radians(100 + k * 20)
        x, y = math.cos(a) * 4.0 - 2.5, math.sin(a) * 5.0
        s = rng.uniform(1.8, 2.6)
        m = Matrix.Translation((x, y, s * 0.5)) @ Matrix.Rotation(rng.uniform(0, 3), 4, "Z") @ Matrix.Rotation(rng.uniform(-0.3, 0.3), 4, "X")
        p.box(-s, s, -s * 0.8, s * 0.8, -s * 0.7, s * 0.7, "BF_ROCK" if k % 2 else "BF_ROCK_DARK", m)
    p.box(-6.0, -0.8, -3.0, 3.0, 0.0, 4.6, "BF_ROCK_DARK")      # the mound's core above the mouth
    p.box(-0.9, 0.1, -3.0, 3.0, -0.5, 4.0, "BF_HOLE")           # the dark mouth
    for s in (-1, 1):
        p.box(0.0, 0.7, s * 3.0 - 0.35, s * 3.0 + 0.35, -0.6, 4.5, "BF_TIMBER")   # posts
    p.box(-0.1, 0.8, -3.8, 3.8, 4.2, 4.9, "BF_TIMBER")          # lintel
    for k, y in enumerate((-2.2, -0.9, 1.6)):                   # planks leaning over the mouth
        m = Matrix.Translation((2.4, y, 0.0)) @ Matrix.Rotation(-0.42 - 0.05 * k, 4, "Y")
        p.box(-0.08, 0.08, -0.5, 0.5, 0.0, 4.4, "BF_TIMBER_DARK", m)
    return p.finish("BF_Tunnel_Entrance", mat)


def make_tunnel_exit(mat):
    """Courtyard hatch, 6 x 6 opening, lid propped open toward -X."""
    p = KIT.Piece()
    p.box(-4.0, 4.0, -4.0, -3.0, -0.4, 0.5, "BF_TIMBER")
    p.box(-4.0, 4.0, 3.0, 4.0, -0.4, 0.5, "BF_TIMBER")
    p.box(-4.0, -3.0, -3.0, 3.0, -0.4, 0.5, "BF_TIMBER")
    p.box(3.0, 4.0, -3.0, 3.0, -0.4, 0.5, "BF_TIMBER")
    p.box(-3.0, 3.0, -3.0, 3.0, -0.4, 0.06, "BF_HOLE")
    m = Matrix.Translation((-3.6, 0, 0.5)) @ Matrix.Rotation(-math.radians(70), 4, "Y")
    p.box(-6.0, 0.0, -3.0, 3.0, 0.0, 0.35, "BF_TIMBER_DARK", m)
    for y in (-1.8, 0.0, 1.8):
        p.box(-5.8, -0.2, y - 0.25, y + 0.25, 0.35, 0.5, "BF_TIMBER", m)
    return p.finish("BF_Tunnel_Exit", mat)


def make_dummy(mat, h=5.0, name="BF_Dummy_5stud"):
    d = KIT.Piece()
    k = h / 5.0
    for s in (-1, 1):
        d.box(min(s * 0.05, s * 0.95), max(s * 0.05, s * 0.95), -0.5, 0.5, 0, 2.0 * k, "BF_DUMMY")
        d.box(min(s * 1.05, s * 1.95), max(s * 1.05, s * 1.95), -0.5, 0.5, 2.1 * k, 4.0 * k, "BF_DUMMY")
    d.box(-1.0, 1.0, -0.5, 0.5, 2.0 * k, 4.0 * k, "BF_DUMMY")
    d.box(-0.6, 0.6, -0.6, 0.6, 4.0 * k, 5.0 * k, "BF_DUMMY")
    return d.finish(name, mat)


def scaled(me, name, sx, sy, sz):
    m2 = me.copy()
    m2.name = name
    m2.transform(Matrix.Diagonal((sx, sy, sz, 1.0)))
    m2.update()
    return m2


def place(coll, name, mesh, loc, rot_deg, traces_to, color=None):
    o = bpy.data.objects.new(name, mesh)
    o["export_name"] = name     # Blender names are global: another scene (the Castle kit's
                                # assembly) may already own this id, so o.name can carry a suffix
    o.location = loc
    o.rotation_euler = Euler((0, 0, math.radians(rot_deg)))
    o["traces_to"] = traces_to
    if color:
        o.color = (KIT.lin(color[0]), KIT.lin(color[1]), KIT.lin(color[2]), 1.0)
    coll.objects.link(o)
    return o


def build_castles(coll, D, kmat, bmat):
    # Round 2: the concept's roofs are dark; use AGENTS §9's slate target on these copies only
    # (this module's own copy of the kit palette; castle_kit.fbx is not affected).
    KIT.SRGB["SLATE"], KIT.SRGB["SLATE_LIGHT"] = (77, 85, 99), (97, 106, 120)
    face_rot = lambda fx, fz: math.degrees(math.atan2(fx, fz))     # local -Y outer face -> Roblox facing
    wall = scaled(KIT.build_wall(kmat), "BF_Wall_Segment", 1, 1, WALL_SZ)
    tower = scaled(KIT.build_tower(kmat), "BF_Wall_Corner_Tower", TOWER_S, TOWER_S, TOWER_S)
    gate = scaled(KIT.build_gate(kmat), "BF_Gate", GATE_S, GATE_S, GATE_S)
    banner = scaled(KIT.build_banner(bmat), "BF_Banner", BANNER_S, BANNER_S, BANNER_S)
    meshes = dict(wall=wall, tower=tower, gate=gate, banner=banner)
    for c in D["L"]["castles"]:
        T, y = c["team"], c["pad"]["y"]
        cx, cy, _ = rb(c["center"]["x"], 0, c["center"]["z"])
        why = "layout.json castles %s " % c["id"]
        for s in c["wall_sections"]:
            place(coll, s["id"], wall, rb(s["x"], y, s["z"]), face_rot(s["facing"]["x"], s["facing"]["z"]), why + "wall_sections")
        for t in c["towers"]:
            lx, ly, _ = rb(t["x"] - c["center"]["x"], 0, t["z"] - c["center"]["z"])
            place(coll, t["id"], tower, rb(t["x"], y, t["z"]), math.degrees(math.atan2(ly, lx)) - 225.0, why + "towers")
        g, fg = c["gate"], c["gate_facing"]
        grot = face_rot(fg["x"], fg["z"])
        wt = c["wall_thickness"]
        gx, gy, _ = rb(g["x"] - fg["x"] * wt / 2, 0, g["z"] - fg["z"] * wt / 2)   # on the wall's centre line
        place(coll, g["id"], gate, (gx, gy, y), grot, why + "gate")
        fx, fy = fg["x"], -fg["z"]                                               # Blender facing
        for s, tag in ((-1, "N"), (1, "S")):
            out = (KIT.GATE_D + 0.15) * GATE_S
            lat = 8.4 * GATE_S * s
            place(coll, "%s_Banner_Gate%s" % (T, tag), banner, (gx + fx * out - fy * lat, gy + fy * out + fx * lat, y + (KIT.GATE_H - 1.8) * GATE_S),
                  grot, why + "gate banners (team colour, art)", TEAM_COL[T])
        for s in c["wall_sections"]:
            if s["id"].endswith(("_F3", "_F7")):
                sx, sy, _ = rb(s["x"], 0, s["z"])
                out = wt / 2 + 1.45
                place(coll, s["id"] + "_Banner", banner, (sx + fx * out, sy + fy * out, y + (KIT.WALL_H - 0.2) * WALL_SZ - 1.6),
                      grot, why + "wall banners (team colour, art)", TEAM_COL[T])
    return meshes


def build_props(coll, D, height, base, mat):
    bar = make_barricade(mat)
    portal = make_tunnel_entrance(mat)
    hatch = make_tunnel_exit(mat)
    for b in D["barricades"]:
        g = min(height(b["cx"] + dx, b["cy"] + dy) for dx in (-6, 0, 6) for dy in (-2, 0, 2))
        place(coll, b["id"], bar, (b["cx"], b["cy"], g), 0.0, "layout.json barricades " + b["id"])
    for t in D["tunnels"]:
        ex, ey = t["entrance"]
        place(coll, t["id"] + "_Entrance", portal, (ex, ey, height(ex, ey)), 0.0 if t["team"] == "A" else 180.0,
              "layout.json tunnels %s entrance" % t["id"])
        xx, xy = t["exit"]
        place(coll, t["id"] + "_Exit", hatch, (xx, xy, height(xx, xy)), 0.0 if t["team"] == "A" else 180.0,
              "layout.json tunnels %s exit (castles tunnel_exit)" % t["id"])
    return dict(barricade=bar, portal=portal, hatch=hatch)


# ------------------------------------------------------------------ markers (verification only)
def build_markers(coll, D, mat, height):
    L = D["L"]

    def strip(x0, y0, x1, y1, w, col, lift=0.6, step=8.0):
        n = max(1, int(math.hypot(x1 - x0, y1 - y0) // step))
        nx_, ny_ = y1 - y0, -(x1 - x0); nl = math.hypot(nx_, ny_) or 1
        nx_, ny_ = nx_ / nl * w / 2, ny_ / nl * w / 2
        out = []
        for k in range(n):
            ax, ay = x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n
            bx, by = x0 + (x1 - x0) * (k + 1) / n, y0 + (y1 - y0) * (k + 1) / n
            z = max(height(ax, ay), height(bx, by), 0.0) + lift
            out.append((((ax - nx_, ay - ny_, z), (bx - nx_, by - ny_, z), (bx + nx_, by + ny_, z), (ax + nx_, ay + ny_, z)), col))
        return out

    def rect(x0, y0, x1, y1, w, col, lift=0.6):
        return (strip(x0, y0, x1, y0, w, col, lift) + strip(x1, y0, x1, y1, w, col, lift)
                + strip(x1, y1, x0, y1, w, col, lift) + strip(x0, y1, x0, y0, w, col, lift))

    def ring(x, y, r, w, col, n=36, lift=0.6):
        out = []
        for i in range(n):
            a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
            out += strip(x + math.cos(a0) * r, y + math.sin(a0) * r, x + math.cos(a1) * r, y + math.sin(a1) * r, w, col, lift, 100)
        return out

    def post(x, y, z, w, h, col):
        v = [(x - w, y - w, z), (x + w, y - w, z), (x + w, y + w, z), (x - w, y + w, z),
             (x - w, y - w, z + h), (x + w, y - w, z + h), (x + w, y + w, z + h), (x - w, y + w, z + h)]
        f = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
        return [(tuple(v[i] for i in q), col) for q in f]

    stats = {}

    def emit(name, t, why):
        stats["BF_" + name] = MAP.tri_object(coll, "BF_" + name, t, mat, why, MARKER)

    emit("Marker_Origin_Axis", post(0, 0, 0, 2.5, 40, MARKER["origin"]) + strip(0, -400, 0, 400, 2, MARKER["axis"], 1.0),
         "layout.json mirror_axis")
    for c in L["castles"]:
        x, y, z = rb(c["center"]["x"], c["pad"]["y"], c["center"]["z"])
        half = c["ring_size"]["x"] / 2
        t = post(x, y, z, 2, 70, MARKER["castle"]) + rect(x - half, y - half, x + half, y + half, 2.5, MARKER["castle"], 0.8)
        ph = c["pad"]["size"] / 2
        t += rect(x - ph, y - ph, x + ph, y + ph, 1.5, MARKER["castle"], 0.8)
        gx, gy, gz = rb(c["gate"]["x"], c["gate"]["y"], c["gate"]["z"])
        t += post(gx, gy, gz, 1.5, 45, MARKER["gate"])
        r = c["reserved_rear_half"]
        t += rect(r["min_x"], -r["max_z"], r["max_x"], -r["min_z"], 1.2, MARKER["rear"], 0.8)
        for s in c["interior"]["spawn_points"]:
            px_, py_, pz_ = rb(s["x"], s["y"], s["z"])
            t += post(px_, py_, pz_, 1.2, 9, MARKER["spawn"])
        emit("Marker_" + c["id"], t, "layout.json castles " + c["id"])
        interior = c["interior"]
        t = []
        for b in [interior["keep"], interior["barracks"], *interior["specialists"]]:
            t += rect(b["min_x"], -b["max_z"], b["max_x"], -b["min_z"], 1.2, MARKER["interior"], 1.0)
        stock = interior["keep"]["stockpile_room"]
        t += rect(stock["min_x"], -stock["max_z"], stock["max_x"], -stock["min_z"], 1.5, MARKER["stockpile"], 1.2)
        emit("Marker_Interior_" + c["id"], t, "layout.json castles " + c["id"] + " interior footprints")
        t = []
        for route in interior["clear_areas"].values():
            t += rect(route["min_x"], -route["max_z"], route["max_x"], -route["min_z"], 0.7, MARKER["clear_route"], 0.9)
        emit("Marker_ClearRoutes_" + c["id"], t, "layout.json castles " + c["id"] + " interior clear_areas")
    for p in D["pads"]:
        if p["kind"] != "node":
            continue
        emit("Marker_" + p["id"], post(p["cx"], p["cy"], p["h"], 1.5, 24, MARKER[p["ring"]]) + ring(p["cx"], p["cy"], p["r"], 1.6, MARKER[p["ring"]]),
             "layout.json resource_node_slots " + p["id"])
    R = D["road"]
    emit("Marker_Road_Clear", rect(R["x0"], -R["half"], R["x1"], R["half"], 2.0, MARKER["road"], 1.0), "layout.json central_road")
    t = []
    for c in D["craters"]:
        t += ring(c["cx"], c["cy"], c["r"], 1.2, MARKER["crater"], 24, 2.2)
    for b in D["barricades"]:
        t += rect(b["cx"] - b["lx"] / 2, b["cy"] - b["dz"] / 2, b["cx"] + b["lx"] / 2, b["cy"] + b["dz"] / 2, 0.8, MARKER["barricade"], 4.2)
    emit("Marker_Crouch_Cover", t, "layout.json craters + barricades")
    t = []
    for z in D["cover"]:
        t += rect(z["x0"], z["y0"], z["x1"], z["y1"], 2.0, MARKER["cover"], 1.0)
    emit("Marker_Cover_Zones", t, "layout.json cover_zones")
    t = []
    for tn in D["tunnels"]:
        (ex, ey), (bx, by), (xx, xy) = tn["entrance"], tn["bend"], tn["exit"]
        t += strip(ex, ey, bx, by, tn["width"], MARKER["tunnel"], 1.2) + strip(bx, by, xx, xy, tn["width"], MARKER["tunnel"], 1.2)
        for x, y in (tn["entrance"], tn["bend"], tn["exit"]):
            t += post(x, y, height(x, y), 1.4, 16, MARKER["tunnel"])
    emit("Marker_Tunnels", t, "layout.json tunnels (underground; plan only)")
    b, bd = L["map_bounds"], L["boundary"]
    hx = (b["max_x"] - b["min_x"]) / 2 + bd["offset_outside_bounds"]
    hy = (b["max_z"] - b["min_z"]) / 2 + bd["offset_outside_bounds"]
    rad = bd["corner_radius"]
    pts = []
    for qx, qy, a0 in ((1, 1, 0), (-1, 1, 90), (-1, -1, 180), (1, -1, 270)):
        for k in range(9):
            a = math.radians(a0 + k * 90 / 8)
            pts.append((qx * (hx - rad) + math.cos(a) * rad, qy * (hy - rad) + math.sin(a) * rad))
    t = []
    for i in range(len(pts)):
        (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % len(pts)]
        t += strip(x0, y0, x1, y1, 3.0, MARKER["boundary"])
    emit("Marker_Boundary", t, "layout.json boundary (invisible wall)")
    return stats, pts


# ------------------------------------------------------------------ verification
def verify(B):
    scene, D, height, inland = B["scene"], B["D"], B["height"], B["inland"]
    by_id = {o.get("export_name", o.name): o for o in scene.objects}
    dg = bpy.context.evaluated_depsgraph_get()
    terrain = [o for o in scene.objects if o.name.startswith("BF_Terrain_")]   # tiles and crater pieces

    def ground(x, y):
        origin = Vector((x + 0.013, y + 0.017, 500.0))
        for o in terrain:
            hit, loc, _, _ = o.ray_cast(origin, Vector((0, 0, -1)))
            if hit:
                return loc.z
        return None

    # pads flat: castles over the whole pad, nodes over their footprint
    pad_dev = []
    for p in D["pads"]:
        pts = [(p["cx"], p["cy"])]
        if p["shape"] == "square":
            for i in range(-8, 9):
                for j in range(-8, 9):
                    pts.append((p["cx"] + (p["half"] - 0.5) * i / 8, p["cy"] + (p["half"] - 0.5) * j / 8))
        else:
            for k in range(24):
                for f in (0.5, 1.0):
                    a = 2 * math.pi * k / 24
                    pts.append((p["cx"] + math.cos(a) * p["inner"] * f, p["cy"] + math.sin(a) * p["inner"] * f))
        zs = [ground(x, y) for x, y in pts]
        pad_dev.append((p["id"], round(max(abs(z - p["h"]) for z in zs if z is not None), 4), sum(z is None for z in zs)))
    # road: clear of every placed object's footprint (castle pieces at the gates excepted), and
    # nothing above its surface at avatar and ram height
    R = D["road"]
    road_objects = []
    for o in scene.objects:
        if o.type != "MESH" or o.name.startswith(("BF_Terrain", "BF_Sea", "BF_Marker", "BF_Shore")) or o.users_collection[0].name == "BF_Preview":
            continue
        if o.name.startswith(("BF_Pines", "BF_Cover_Rocks")) or o.users_collection[0].name == "BF_Castles":
            continue                          # trees are checked below; the road ends AT the castles' gates
        ws = [o.matrix_world @ Vector(c) for c in o.bound_box]
        x0, x1 = min(v.x for v in ws), max(v.x for v in ws)
        y0, y1 = min(v.y for v in ws), max(v.y for v in ws)
        if x1 > -R["x1"] and x0 < R["x1"] and y1 > -R["half"] and y0 < R["half"]:
            road_objects.append(o.name)
    blocked = []
    for k in range(0, int(2 * R["x1"]) + 1, 2):
        x = -R["x1"] + k
        for y in (-R["half"] + 1, -6, 0, 6, R["half"] - 1):
            g = ground(x, y)
            origin = Vector((x, y, (g or 0) + 0.3))
            hit, loc, _, _, ob, _ = scene.ray_cast(dg, origin, Vector((0, 0, 1)))
            if hit and loc.z - origin.z < 12 and not ob.name.startswith(("BF_Marker", "BF_Terrain")) and not ob.get("export_name", ob.name).endswith("_Gate"):
                blocked.append((round(x), y, ob.name))
    road_slope = max(abs((ground(x + 4, 0) or 0) - (ground(x, 0) or 0)) / 4 for x in range(-180, 176, 4))
    # trees: rules and clearances
    trees = B["trees"]
    belt = D["L"]["decoration_rules"]["edge_belt_depth"]
    Bd = D["bounds"]
    edge = lambda x, y: min(x - Bd["x0"], Bd["x1"] - x, y - Bd["y0"], Bd["y1"] - y)
    tree_rule = [(round(x), round(y)) for x, y, cr, why in trees if edge(x, y) > belt and not any(in_rect(z, x, y) for z in D["cover"])]
    tree_road = [(round(x), round(y)) for x, y, cr, why in trees if in_road_clear(R, x, y, grow=cr)]
    tree_pad = [(round(x), round(y), p["id"]) for x, y, cr, why in trees for p in D["pads"] if pad_dist(p, x, y) < cr]
    tree_crater = [(round(x), round(y)) for x, y, cr, why in trees for c in D["craters"] if math.hypot(x - c["cx"], y - c["cy"]) < c["r"] + cr]
    unmirrored = sum(1 for x, y, cr, why in trees if not any(abs(-x - x2) < 1e-6 and abs(y - y2) < 1e-6 for x2, y2, _, _ in trees))
    # craters: measured depth and rim from the mesh
    crater_meas = []
    for c in D["craters"]:
        field = sum(ground(c["cx"] + math.cos(a) * (c["r"] + 6), c["cy"] + math.sin(a) * (c["r"] + 6)) for a in (0, 1.57, 3.14, 4.71)) / 4
        floor = ground(c["cx"], c["cy"])
        rim = max(ground(c["cx"] + math.cos(a) * (c["rf"] + c["r"]) / 2, c["cy"] + math.sin(a) * (c["rf"] + c["r"]) / 2) for a in [k * 0.4 for k in range(16)])
        crater_meas.append((c["id"], round(floor - field, 2), round(rim - field, 2), round(rim - floor, 2)))
    # barricades: height above the ground they stand on
    bar_meas = []
    for b in D["barricades"]:
        o = by_id[b["id"]]
        top = max((o.matrix_world @ Vector(c)).z for c in o.bound_box)
        g = ground(b["cx"], b["cy"])
        dims = o.dimensions
        bar_meas.append((b["id"], round(top - g, 2), round(dims.x, 2), round(dims.y, 2)))
    # tunnels: portals at their layout points, entrance inside its cover patch
    tun = []
    for t in D["tunnels"]:
        e = by_id[t["id"] + "_Entrance"].location
        x = by_id[t["id"] + "_Exit"].location
        cz = next(z for z in D["cover"] if z["id"] == t["cover"])
        tun.append((t["id"], round((Vector((e.x, e.y)) - Vector(t["entrance"])).length, 3), round((Vector((x.x, x.y)) - Vector(t["exit"])).length, 3),
                    in_rect(cz, e.x, e.y), round(x.z - 10.0, 3)))
    # castle pieces at their layout coordinates, every id present, mirror of A
    L = D["L"]
    missing, misplaced = [], []
    for c in L["castles"]:
        for s in c["wall_sections"] + c["towers"]:
            o = by_id.get(s["id"])
            if o is None:
                missing.append(s["id"]); continue
            if (o.location - Vector(rb(s["x"], s["y"], s["z"]))).length > 1e-3:
                misplaced.append(s["id"])
    # terrain mirror
    V3 = B["V3"]
    at = {(round(x, 4), round(y, 4)): z for x, y, z in V3}
    miss, err = 0, 0.0
    for x, y, z in V3:
        tw = at.get((round(-x, 4), round(y, 4)))
        if tw is None:
            miss += 1
        else:
            err = max(err, abs(tw - z))
    # water inside the playable area
    xs = [Bd["x0"] + (Bd["x1"] - Bd["x0"]) * i / 60 for i in range(61)]
    ys = [Bd["y0"] + (Bd["y1"] - Bd["y0"]) * j / 40 for j in range(41)]
    wet = [(round(x), round(y)) for x in xs for y in ys if (ground(x, y) or 0) <= 0.05]
    wall_min_inland = min(inland(x, y) for x, y in B["boundary_pts"])
    return dict(pads_max_dev=max(d for _, d, _ in pad_dev), pads_missing=sum(m for _, _, m in pad_dev), pads=pad_dev,
                road_objects_over_clear_strip=road_objects, road_blocked=blocked[:10], road_blocked_count=len(blocked),
                road_max_grade=round(road_slope, 3), trees=len(trees), trees_outside_rules=tree_rule, trees_in_road=tree_road,
                trees_on_pads=tree_pad, trees_in_craters=tree_crater, unmirrored_trees=unmirrored,
                craters_floor_rim_depth=crater_meas, barricades_height_len_depth=bar_meas, tunnels_entrance_exit_err_incover_exitz=tun,
                castle_missing=missing, castle_misplaced=misplaced, terrain_mirror=(round(err, 6), miss),
                water_inside_bounds=wet, boundary_wall_min_inland=round(wall_min_inland, 1))


def slope_report(B):
    V3, tris, Bd = B["V3"], B["tris"], B["D"]["bounds"]
    worst = []
    for t in tris:
        p = [V3[i] for i in t]
        cx = sum(q[0] for q in p) / 3; cy = sum(q[1] for q in p) / 3
        if not (Bd["x0"] <= cx <= Bd["x1"] and Bd["y0"] <= cy <= Bd["y1"]):
            continue
        nz = MAP.face_normal_z(*p)
        worst.append((round(math.degrees(math.acos(max(-1.0, min(1.0, nz)))), 1), round(cx), round(cy)))
    worst.sort(reverse=True)
    return dict(max=worst[:6], over_20=sum(1 for w in worst if w[0] > 20), over_35=sum(1 for w in worst if w[0] > 35), faces=len(worst))


def audit(scene, delete=False):
    stray = [o.name for o in scene.objects if "traces_to" not in o.keys()]
    if delete:
        for name in stray:
            bpy.data.objects.remove(bpy.data.objects[name])
    return stray


def tri_counts(scene):
    out = {}
    for o in scene.objects:
        if o.type == "MESH":
            o.data.calc_loop_triangles()
            out[o.name] = len(o.data.loop_triangles)
    return out


# ------------------------------------------------------------------ export
EXPORT_COLLECTIONS = ("BF_Terrain", "BF_Groundcover", "BF_Sea", "BF_Shore", "BF_Trees", "BF_Props", "BF_Castles")


def export_fbx(scene, path, names=None):
    """Same settings as map.fbx and castle_kit.fbx on purpose (the importer turns all of
    them the same way). `names` limits the export to those objects (the Studio test)."""
    view_layer = scene.view_layers[0]
    objs = [o for c in EXPORT_COLLECTIONS for o in bpy.data.collections[c].objects]
    if names is not None:
        objs = [o for o in objs if o.get("export_name", o.name) in names]
    # swap in the exact layout ids; whoever holds one elsewhere steps aside and gets it back
    swaps = []
    for o in objs:
        want = o.get("export_name")
        if want and o.name != want:
            holder = bpy.data.objects.get(want)
            if holder is not None:
                holder.name = want + "__swap"
            swaps.append((o, o.name, holder, want))
            o.name = want
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
        for o, old, holder, want in reversed(swaps):
            o.name = old + "__tmp"
            if holder is not None:
                holder.name = want
            o.name = old
    return path, len(objs)


# ------------------------------------------------------------------ scene
def preview_world():
    world = bpy.data.worlds.get("Battlefield_World") or bpy.data.worlds.new("Battlefield_World")
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
    sky.inputs[0].default_value = (KIT.lin(150), KIT.lin(172), KIT.lin(204), 1.0)   # the concept's hazy upper sky
    fill = nt.nodes.new("ShaderNodeBackground")
    fill.inputs[0].default_value = (0.64, 0.68, 0.78, 1.0)
    fill.inputs[1].default_value = 0.38
    nt.links.new(cam.outputs["Is Camera Ray"], mix.inputs[0])
    nt.links.new(fill.outputs[0], mix.inputs[1])
    nt.links.new(sky.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], out.inputs[0])
    return world


def clear_scene(name):
    old = bpy.data.scenes.get(name)
    if not old:
        return
    meshes = {o.data for o in old.objects if o.type == "MESH"}
    for o in list(old.objects):
        bpy.data.objects.remove(o)
    for c in list(old.collection.children_recursive):
        bpy.data.collections.remove(c)
    bpy.data.scenes.remove(old)
    for d in meshes:
        if d.users == 0:
            bpy.data.meshes.remove(d)


def build():
    clear_scene("Battlefield")
    scene = bpy.data.scenes.new("Battlefield")
    try:
        scene.view_settings.view_transform = "Standard"
    except TypeError:
        pass
    scene.world = preview_world()
    colls = {}
    for name in EXPORT_COLLECTIONS + ("BF_Preview", "BF_Layout_Markers"):
        c = bpy.data.collections.new(name); scene.collection.children.link(c); colls[name] = c
    rng = random.Random(SEED)
    mat, mmat = MAP.material("BF_Mat"), MAP.material("BF_Marker_Mat", emissive=True)
    kmat, bmat = KIT.castle_material(), KIT.banner_material()
    D = load_layout()
    renamed = []   # nothing outside this scene is renamed; see place() and export_fbx()
    inland, outline = MAP.make_coast(D["bounds"], rng)
    height, base = make_height(D, inland)
    stats = {}
    g, V3, tris = build_ground(colls["BF_Terrain"], D, height, inland, rng, mat)
    stats.update(g)
    grass, grass_counts = build_groundcover(colls["BF_Groundcover"], D, height, inland, mat)
    stats.update(grass)
    stats.update(build_sea(colls["BF_Sea"], outline, inland, rng, mat))
    sh, n_rocks = build_shore(colls["BF_Shore"], outline, inland, rng, mat)
    stats.update(sh)
    p, trees = build_pines(colls["BF_Trees"], D, height, inland, rng, mat)
    stats.update(p)
    cr, rocks = build_cover_rocks(colls["BF_Props"], D, height, rng, mat)
    stats.update(cr)
    castle_meshes = build_castles(colls["BF_Castles"], D, kmat, bmat)
    prop_meshes = build_props(colls["BF_Props"], D, height, base, kmat)
    # preview only: sun, and 5-stud dummies at the crouch cover
    P = colls["BF_Preview"]
    sun_data = bpy.data.lights.get("BF_Sun") or bpy.data.lights.new("BF_Sun", "SUN")
    sun_data.energy = 3.4
    sun_data.color = (1.0, 0.95, 0.86)
    sun_data.angle = math.radians(3.0)
    sun = bpy.data.objects.new("BF_Sun", sun_data)
    sun.rotation_euler = Vector((0.55, 0.65, -0.62)).normalized().to_track_quat("-Z", "Y").to_euler()   # from the south-west, warm, mid-high
    sun["traces_to"] = "preview lighting"
    P.objects.link(sun)
    dummy = make_dummy(kmat)
    b = next(b for b in D["barricades"] if b["id"] == "A_Barricade_N")
    place(P, "BF_Dummy_Barricade", dummy, (b["cx"] - 1.0, b["cy"] + 3.2, height(b["cx"] - 1.0, b["cy"] + 3.2)), 90.0, "preview: 5-stud avatar behind A_Barricade_N")
    c = next(c for c in D["craters"] if c["id"] == "A_Crater_1")
    place(P, "BF_Dummy_Crater", dummy, (c["cx"], c["cy"], height(c["cx"], c["cy"])), 90.0, "preview: 5-stud avatar standing in A_Crater_1")
    gA = D["L"]["castles"][0]["gate"]
    place(P, "BF_Dummy_Gate", dummy, (gA["x"] + 22, 6, height(gA["x"] + 22, 6)), 90.0, "preview: 5-stud avatar at A_Gate")
    mk, boundary_pts = build_markers(colls["BF_Layout_Markers"], D, mmat, height)
    scene.view_layers[0].update()
    return dict(scene=scene, stats=stats, markers=mk, D=D, renamed_in_other_scenes=renamed, inland=inland, height=height, base=base, trees=trees, grass_counts=grass_counts, V3=V3, tris=tris,
                boundary_pts=boundary_pts, castle_meshes=castle_meshes, prop_meshes=prop_meshes, shore_rocks=n_rocks, cover_rocks=rocks)


# ------------------------------------------------------------------ views
def show(scene, markers=False):
    win, area, sp = MAP._v3d()
    win.scene = scene
    for o in scene.objects:
        o.select_set(False, view_layer=scene.view_layers[0])
    lc = scene.view_layers[0].layer_collection.children.get("BF_Layout_Markers")
    if lc:
        lc.hide_viewport = not markers
    sp.shading.type = "RENDERED"
    sp.shading.show_object_outline = False
    sp.clip_start, sp.clip_end = 0.3, 12000
    sp.overlay.show_floor = False
    sp.overlay.show_axis_x = sp.overlay.show_axis_y = False
    try:
        sp.overlay.show_overlays = False
    except Exception:
        pass


bpy.app.driver_namespace["battlefield"] = dict(build=build, verify=verify, slope_report=slope_report, audit=audit,
                                               tri_counts=tri_counts, export_fbx=export_fbx, show=show, orbit=MAP.orbit,
                                               look=MAP.look, rb=rb)
