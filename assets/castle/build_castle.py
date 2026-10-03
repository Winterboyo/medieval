"""Siege castle kit, after references/castle-1.jpg (towers and roofs also castle-2.jpg),
built in its own Blender scene ("Castle") from the approved layout.json v2.1.

Run inside Blender with __file__ set, then bpy.app.driver_namespace["castle"]["build"]().

Pieces (DESIGN.md and AGENTS.md), each its own named object in Castle_Kit:
  Wall_Segment            one 20.4-stud bay: crenellated parapet on corbels
  Wall_Corner_Tower       two-stage drum, corbels, slate cone and accessible deck
  Gate, Gate_Door         gatehouse with arched opening and corner turrets; timber door
  Keep                    damageable 44 x 44 keep with an internal stockpile room
  Stockpile               chests and goods inside that room, with a clear interaction aisle
  Barracks                hollow stone hall with a slate roof; the team spawns inside
  Blacksmith, Alchemist, Fletcher, Carpenter: separate crafting buildings
  Ballista                fixed gatehouse defense, aimed along +X
  Battering_Ram           roofed ram on wheels, iron head toward +X
  Tower_Ladder            access to a corner-tower fighting deck
  Scaffold                timber scaffolding for one wall bay, shown during repair
  Banner                  hanging banner; neutral cloth tinted by Roblox's part Color
Damage states (same footprint, swap in place): <Piece>_Damaged and <Piece>_Rubble for
Wall_Segment, Wall_Corner_Tower, Gate_Door, Keep, Barracks, and specialist buildings.

Castle_Assembly is team A's layout in castle-local Blender coordinates (gate toward
+X). Castle_Assembly_B is its exact x-axis mirror, checked against team B's layout.
The kit and both assemblies are previews; this script does not export unless asked.

1 unit = 1 stud. Flat shading, per-face colours (CORNER byte colour "Col"), every mesh
triangulated with outward normals (Roblox renders one side only).
"""
import bpy, bmesh, json, math, os, random
from mathutils import Vector, Euler, Matrix

_HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
LAYOUT = os.path.normpath(os.path.join(_HERE, "..", "..", "layout.json"))

# Sampled from references/castle-1.jpg (Blender image loader; PIL is not installed).
SRGB = {
    "STONE": (193, 185, 166),       # lit tower body: warm light grey
    "STONE_DARK": (129, 126, 117),  # shaded curtain wall: plinths, corbels, arch frame, rubble
    "SLATE": (106, 111, 117),       # big tower roof (median of the shingles)
    "SLATE_LIGHT": (128, 135, 141), # the lit shingles (80th percentile of the same roof)
    "TIMBER": (159, 137, 114),      # drawbridge planks
    "IRON": (61, 61, 61),           # the dark of the gate opening: windows, bands, guns
    "CLOTH": (178, 178, 178),       # banner cloth, neutral so the team colour tints it
    "EMBLEM": (255, 255, 255),      # banner emblem: tints to the full team colour
    # Forge reference photo: dark stone/wood and fire samples, lifted slightly so
    # the room remains legible at Roblox's normal third-person camera distance.
    "FORGE_STONE": (103, 95, 87),
    "FORGE_FLOOR": (77, 75, 73),
    "FORGE_WOOD": (130, 104, 77),
    "EMBER": (197, 103, 52),
    "FIRE": (255, 200, 97),
    # Sampled from references/village-cliff.png and lifted for readable game art.
    "PLASTER": (218, 202, 174),
    "FRAME": (93, 61, 38),
    "VILLAGE_ROOF": (168, 66, 30),
    "VILLAGE_ROOF_LIGHT": (194, 82, 38),
    # The user's Roblox blacksmith screenshot: golden canopy and dark timber shop.
    "FORGE_CANOPY": (189, 158, 83),
    "FORGE_CANOPY_LIGHT": (211, 179, 100),
    "FORGE_ROOF": (95, 74, 58),
    "FORGE_ROOF_LIGHT": (116, 88, 68),
    "LEATHER": (116, 76, 47),
    "PARCHMENT": (217, 200, 154),
    "HERB": (84, 123, 66),
    "GLASS_GREEN": (87, 145, 109),
    "GLASS_BLUE": (91, 136, 161),
    "GLASS_RED": (181, 82, 65),
    "FEATHER": (218, 211, 178),
    "COURT_STONE": (118, 111, 103),
    "COURT_LIGHT": (139, 131, 120),
    "COURT_DARK": (97, 93, 88),
    "COURT_GRAVEL": (145, 120, 88),
}
TEAM_A = (184, 65, 58)              # layout.json teams[0].banner_color_placeholder, preview only
TEAM_B = (58, 95, 184)
STATES = ("intact", "damaged", "rubble")

BAY = 20.4                          # validated against layout.json at build time
WALL_T = 4.0                        # wall thickness
WALL_H = 16.0                       # taller silhouette for the enlarged ring
TOWER_R = 7.0
TOWER_SIDES = 16
TOWER_TOP = 36.0                    # upper drum, roof tip about 58 studs
GATE_HW, GATE_D, GATE_H = 12.0, 5.0, 20.0       # roof deck 21.4 matches layout ballista y=31.4
ARCH_HW, ARCH_SPRING = 5.0, 9.0                    # gate opening 10 wide, 14 to the crown


def lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


# ------------------------------------------------------------------ geometry builder
class Piece:
    """Collects closed primitives (shared vertices within each) with a colour per face.
    `self.m`, when set, transforms everything added (used to lay cylinders on their side)."""
    def __init__(self):
        self.v, self.f, self.m = [], [], None

    def _add(self, verts, faces, col):
        b = len(self.v)
        for p in verts:
            q = Vector(p)
            self.v.append(self.m @ q if self.m is not None else q)
        for f in faces:
            self.f.append((tuple(b + i for i in f), col))

    def box(self, x0, x1, y0, y1, z0, z1, col, m=None):
        vs = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0), (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]
        if m is not None:
            vs = [m @ Vector(p) for p in vs]
        self._add(vs, [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)], col)

    def frustum(self, cx, cy, z0, r0, z1, r1, n, col, rot=0.0):
        ring = lambda r, z: [(cx + math.cos(rot + 2 * math.pi * k / n) * r, cy + math.sin(rot + 2 * math.pi * k / n) * r, z) for k in range(n)]
        faces = [(k, (k + 1) % n, n + (k + 1) % n, n + k) for k in range(n)]
        faces += [tuple(reversed(range(n))), tuple(range(n, 2 * n))]
        self._add(ring(r0, z0) + ring(r1, z1), faces, col)

    def cone(self, cx, cy, z0, r0, apex, n, col, rot=0.0):
        vs = [(cx + math.cos(rot + 2 * math.pi * k / n) * r0, cy + math.sin(rot + 2 * math.pi * k / n) * r0, z0) for k in range(n)]
        vs.append((cx, cy, apex))
        self._add(vs, [(k, (k + 1) % n, n) for k in range(n)] + [tuple(reversed(range(n)))], col)

    def profile(self, outline_xz, y0, y1, col):
        """Extrude an (x, z) outline, counter-clockwise seen from -Y, between y0 and y1."""
        n = len(outline_xz)
        vs = [(x, y0, z) for x, z in outline_xz] + [(x, y1, z) for x, z in outline_xz]
        faces = [tuple(range(n)), tuple(reversed(range(n, 2 * n)))]
        faces += [((k + 1) % n, k, n + k, n + (k + 1) % n) for k in range(n)]
        self._add(vs, faces, col)

    def gable(self, x0, x1, y0, y1, z0, zr, col):
        """Pitched roof, ridge along X."""
        ym = (y0 + y1) / 2
        vs = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0), (x0, ym, zr), (x1, ym, zr)]
        self._add(vs, [(0, 3, 2, 1), (0, 1, 5, 4), (2, 3, 4, 5), (1, 2, 5), (3, 0, 4)], col)

    def along_x(self, x, y, z, length, r0, r1, n, col, tilt=0.0):
        """A cylinder/frustum lying along +X from (x, y, z), optionally tilted up by `tilt` rad."""
        prev = self.m
        m = Matrix.Translation((x, y, z)) @ Matrix.Rotation(-tilt, 4, "Y") @ Matrix.Rotation(math.pi / 2, 4, "Y")
        self.m = m if prev is None else prev @ m
        self.frustum(0, 0, 0, r0, length, r1, n, col, rot=math.pi / n)    # local +Z becomes +X
        self.m = prev

    def wheel(self, x, y, z, r, w, n, col):
        """A disc on an axle along Y."""
        prev = self.m
        m = Matrix.Translation((x, y, z)) @ Matrix.Rotation(math.pi / 2, 4, "X")
        self.m = m if prev is None else prev @ m
        self.frustum(0, 0, -w / 2, r, w / 2, r, n, col, rot=math.pi / n)
        self.m = prev

    def chunk(self, x, y, z, s, rng, col):
        """A tumbled block of rubble."""
        m = (Matrix.Translation((x, y, z)) @ Matrix.Rotation(rng.uniform(0, math.pi), 4, "Z")
             @ Matrix.Rotation(rng.uniform(-0.6, 0.6), 4, "X") @ Matrix.Rotation(rng.uniform(-0.6, 0.6), 4, "Y"))
        sx, sy, sz = s * rng.uniform(0.7, 1.3), s * rng.uniform(0.6, 1.1), s * rng.uniform(0.4, 0.8)
        self.box(-sx / 2, sx / 2, -sy / 2, sy / 2, -sz / 2, sz / 2, col, m)

    def shingle_cone(self, cx, cy, z0, r0, apex, seed, tile_w=2.8, tile_h=3.0, step=1.9, kick=0.45,
                     thick=0.22, top=0.94, pointed=True, light_share=0.3):
        """A slate roof the way castle-1 builds it: rows of overlapping fish-scale tiles
        laid on a cone from the eave up, each row staggered by half a tile and kicked out
        at its lower edge, over a dark core cone so no gap shows the sky. Seeded jitter in
        size and angle keeps it hand-laid rather than machined."""
        rng = random.Random(seed)
        height = apex - z0
        slant = math.hypot(r0, height)
        if top >= 0.9:
            self.cone(cx, cy, z0, r0 * 0.97, apex - 0.2, 12, "SLATE")       # core
        else:                                                               # a roof with its top shot off
            self.frustum(cx, cy, z0, r0 * 0.97, z0 + height * top, r0 * (1 - top) * 0.97, 12, "SLATE")
        t, row = 0.0, 0
        while t < top:
            r = r0 * (1 - t)
            if r < 0.25:
                break
            n = max(5, int(round(2 * math.pi * r / tile_w)))
            w = 2 * math.pi * r / n * 1.16                                    # overlap side to side
            h = min(tile_h, slant * (1 - t))
            off = 0.5 if row % 2 else 0.0
            for k in range(n):
                phi = 2 * math.pi * (k + off + rng.uniform(-0.08, 0.08)) / n
                ux, uy = -math.sin(phi), math.cos(phi)                         # along the row
                dx, dy, dz = math.cos(phi) * r0, math.sin(phi) * r0, -height   # down the slope
                dl = math.sqrt(dx * dx + dy * dy + dz * dz)
                dx, dy, dz = dx / dl, dy / dl, dz / dl
                nx, ny, nz = uy * dz - 0 * dy, 0 * dx - ux * dz, ux * dy - uy * dx   # outward normal = u x d
                if nx * math.cos(phi) + ny * math.sin(phi) < 0:
                    nx, ny, nz = -nx, -ny, -nz
                bx = cx + math.cos(phi) * r
                by = cy + math.sin(phi) * r
                bz = z0 + height * t
                ww = w * rng.uniform(0.9, 1.08)
                hh = h * rng.uniform(0.9, 1.05)
                k_out = kick * rng.uniform(0.7, 1.3)
                outline = ([(-ww / 2, hh), (ww / 2, hh), (ww / 2, hh * 0.32), (0.0, 0.0), (-ww / 2, hh * 0.32)] if pointed
                           else [(-ww / 2, hh), (ww / 2, hh), (ww / 2, 0.0), (-ww / 2, 0.0)])
                vs = []
                for layer in (0.0, thick):
                    for (x, yv) in outline:
                        lift = layer + 0.04 + k_out * (1 - yv / hh)              # bottom edge stands proud
                        vs.append((bx + ux * x - dx * yv + nx * lift,
                                   by + uy * x - dy * yv + ny * lift,
                                   bz - dz * yv + nz * lift))
                m = len(outline)
                faces = [tuple(range(m)), tuple(reversed(range(m, 2 * m)))]
                faces += [(i, (i + 1) % m, m + (i + 1) % m, m + i) for i in range(m)]
                self._add(vs, faces, "SLATE_LIGHT" if rng.random() < light_share else "SLATE")
            t += step / slant
            row += 1

    def rubble(self, x0, x1, y0, y1, count, size, height, seed, cols=("STONE", "STONE_DARK")):
        """A heap: blocks scattered over a rectangle, piled higher toward its middle."""
        rng = random.Random(seed)
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        for i in range(count):
            x, y = rng.uniform(x0, x1), rng.uniform(y0, y1)
            d = max(abs(x - cx) / max(0.01, (x1 - x0) / 2), abs(y - cy) / max(0.01, (y1 - y0) / 2))
            z = size * 0.3 + rng.uniform(0, max(0.0, height * (1 - d)))
            self.chunk(x, y, z, size * rng.uniform(0.6, 1.2), rng, cols[i % len(cols)])

    def finish(self, name, mat):
        bm = bmesh.new()
        bv = [bm.verts.new(p) for p in self.v]
        names = sorted(set(c for _, c in self.f))
        for idx, col in self.f:
            face = bm.faces.new([bv[i] for i in idx])
            face.material_index = names.index(col)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        try:
            bmesh.ops.triangulate(bm, faces=bm.faces, quad_method="BEAUTY", ngon_method="EAR_CLIP")
        except TypeError:
            bmesh.ops.triangulate(bm, faces=bm.faces)
        me = bpy.data.meshes.new(name)
        bm.to_mesh(me)
        bm.free()
        attr = me.color_attributes.new("Col", "BYTE_COLOR", "CORNER")
        flat = []
        for poly in me.polygons:
            c = SRGB[names[poly.material_index]]
            flat.extend((c[0] / 255, c[1] / 255, c[2] / 255, 1.0) * poly.loop_total)
        attr.data.foreach_set("color_srgb", flat)
        me.color_attributes.active_color = attr
        me.color_attributes.render_color_index = me.color_attributes.active_color_index
        me.polygons.foreach_set("material_index", [0] * len(me.polygons))
        me.polygons.foreach_set("use_smooth", [False] * len(me.polygons))
        me.materials.append(mat)
        me.update()
        return me


def arch_outline(half_w, spring, segs=8):
    """Points over a round arch from (-half_w, spring) to (half_w, spring)."""
    return [(half_w * math.cos(math.pi - math.pi * k / segs), spring + half_w * math.sin(math.pi - math.pi * k / segs)) for k in range(segs + 1)]


def suffix(state):
    return "" if state == "intact" else "_" + state.capitalize()


# ------------------------------------------------------------------ walls and towers (wall frame: length along X, outer face -Y)
def build_wall(mat, state="intact"):
    p = Piece()
    L, t = BAY / 2, WALL_T / 2
    period = BAY / 5
    p.box(-L, L, -t - 0.4, t + 0.4, 0, 1.2, "STONE_DARK")                       # plinth (all states)
    if state == "intact":
        p.box(-L, L, -t, t, 1.2, WALL_H, "STONE")
        keep_bays = range(5)
    elif state == "damaged":
        # a ragged notch knocked out of the middle; the ends still stand to full height
        top = [(L, WALL_H), (6.5, WALL_H), (4.8, 9.2), (2.6, 10.1), (0.9, 7.4), (-1.8, 8.6), (-3.6, 7.0), (-5.2, 9.6), (-6.5, WALL_H), (-L, WALL_H)]
        p.profile([(-L, 1.2), (L, 1.2)] + top, -t, t, "STONE")
        keep_bays = (0, 4)
    else:
        # knocked flat: a low ragged stump you can climb over, buried in its own stone
        top = [(L, 3.8), (7.0, 3.0), (4.0, 2.1), (1.0, 1.5), (-2.0, 2.2), (-5.0, 1.6), (-8.0, 2.9), (-L, 3.6)]
        p.profile([(-L, 1.2), (L, 1.2)] + top, -t, t, "STONE")
        p.rubble(-8.5, 8.5, -5.5, 5.5, 26, 1.7, 1.6, seed=11)
        keep_bays = ()
    if state != "rubble":
        rng = random.Random(5)
        # castle-1's wall faces: a scatter of proud, irregular blocks low down
        stones = [(-7.8, 3.0, 2.6, 1.3), (-4.6, 2.2, 3.2, 1.2), (-1.4, 3.4, 2.4, 1.1), (1.9, 2.4, 3.0, 1.3),
                  (5.2, 3.2, 2.2, 1.2), (8.0, 2.0, 2.4, 1.1), (-6.0, 6.6, 2.6, 1.2), (3.4, 7.4, 3.0, 1.2)]
        for x, z, w, h in stones:
            if state == "intact" or abs(x) > 6:
                p.box(x - w / 2, x + w / 2, -t - rng.uniform(0.2, 0.45), -t, z, z + h, "STONE")
        for k in keep_bays:
            x = -L + period * (k + 0.5)
            x0, x1 = x - period / 2, x + period / 2
            # THE PROJECTING BAND under the parapet, as castle-1 builds it: rough blocks
            # of uneven width and drop, standing out over a dark recess
            p.box(x0, x1, -t - 0.35, -t, WALL_H - 2.3, WALL_H - 0.4, "IRON")                       # the dark behind
            edges = [x0, x - rng.uniform(0.3, 1.0), x1]
            for a, b in zip(edges, edges[1:]):
                drop = rng.uniform(1.6, 2.4)
                p.box(a + 0.08, b - 0.08, -t - rng.uniform(0.9, 1.25), -t, WALL_H - drop, WALL_H + 0.2, "STONE")
            p.box(x0, x1, -t - 1.0, -t + 1.2, WALL_H + 0.2, WALL_H + 1.4, "STONE")                 # parapet course
            mw = rng.uniform(0.95, 1.2)
            p.box(x - mw, x + mw, -t - 1.0, -t + 0.3, WALL_H + 1.4, WALL_H + 3.2, "STONE")           # merlon
            p.box(x - mw - 0.15, x + mw + 0.15, -t - 1.15, -t + 0.45, WALL_H + 3.2, WALL_H + 3.55, "STONE_DARK")   # its cap
            p.box(x0, x1, t - 0.6, t, WALL_H, WALL_H + 0.7, "STONE")                                 # inner lip
    if state == "damaged":
        p.rubble(-6.0, 6.0, -6.5, -2.6, 10, 1.4, 1.0, seed=7)                     # fallen stone at the foot
    return p.finish("Wall_Segment" + suffix(state), mat)


def build_tower(mat, state="intact", gun=False):
    """Centred on its own origin. Windows face local (-1, -1), i.e. outward at a corner.
    Gun towers end in an open crenellated platform (floor at TOWER_TOP + 2.6) instead of
    a roof: castle-1 has both kinds, and the front towers carry cannons."""
    p, n, r = Piece(), TOWER_SIDES, TOWER_R
    top = TOWER_TOP
    drum0, ru = top - 7.0, r + 1.1   # castle-1's upper drum overhangs the shaft clearly
    floor = top + 2.6
    p.frustum(0, 0, 0, r + 0.9, 2.6, r, n, "STONE_DARK")                        # flared base (all states)
    if state == "rubble":
        p.frustum(0, 0, 2.6, r, 6.0, r - 0.1, n, "STONE")                        # the stump
        rng = random.Random(23)
        for k in range(n):                                                      # ragged crown on the stump
            if rng.random() < 0.6:
                a = 2 * math.pi * (k + 0.5) / n
                m = Matrix.Translation((math.cos(a) * (r - 0.8), math.sin(a) * (r - 0.8), 6.0)) @ Matrix.Rotation(a, 4, "Z")
                p.box(-0.8, 0.8, -1.2, 1.2, 0, rng.uniform(0.8, 3.0), "STONE", m)
        p.rubble(-r - 4, r + 4, -r - 4, r + 4, 34, 2.0, 3.0, seed=29)
        return p.finish("Wall_Corner_Tower" + ("_Gun" if gun else "") + suffix(state), mat)
    rng = random.Random(77 + (1 if gun else 0))
    p.frustum(0, 0, 2.6, r, drum0, r - 0.2, n, "STONE")                         # lower body
    p.frustum(0, 0, drum0, ru, top, ru, n, "STONE")                             # upper drum

    # castle-1's mid band: a course of irregular blocks standing proud of the shaft
    for k in range(18):
        a = 2 * math.pi * (k + rng.uniform(-0.2, 0.2)) / 18
        w, hgt, out = rng.uniform(1.6, 2.6), rng.uniform(1.0, 1.7), rng.uniform(0.25, 0.6)
        m = Matrix.Translation((math.cos(a) * (r - 0.3), math.sin(a) * (r - 0.3), 0)) @ Matrix.Rotation(a, 4, "Z")
        z0 = 9.0 + rng.uniform(-0.3, 0.3)
        p.box(0.0, 0.3 + out, -w / 2, w / 2, z0, z0 + hgt, "STONE", m)
    # a few loose stones hanging under the band, as on castle-1's big tower
    for k in range(6):
        a = math.radians(180 + k * 18 + rng.uniform(-6, 6))
        m = Matrix.Translation((math.cos(a) * (r - 0.3), math.sin(a) * (r - 0.3), 0)) @ Matrix.Rotation(a, 4, "Z")
        z0 = rng.uniform(6.2, 8.3)
        p.box(0.0, 0.35, -0.7, 0.7, z0, z0 + 0.9, "STONE", m)

    # MACHICOLATION under the upper drum: corbel brackets with dark gaps between them,
    # and a ragged sloped lip on top (the overhang the drum sits on)
    p.frustum(0, 0, drum0 - 2.6, r + 0.05, drum0, r + 0.05, n, "IRON")         # the dark between the corbels
    for k in range(n):
        a = 2 * math.pi * (k + 0.5) / n
        m = Matrix.Translation((math.cos(a) * r, math.sin(a) * r, 0)) @ Matrix.Rotation(a, 4, "Z")
        p.box(-0.3, ru - r + 0.35, -0.66, 0.66, drum0 - 2.6, drum0, "STONE", m)   # chunky, narrow dark gaps between
        p.box(-0.3, 0.4, -0.6, 0.6, drum0 - 3.1, drum0 - 2.6, "STONE", m)    # the bracket's foot
    p.frustum(0, 0, drum0 - 0.1, ru + 0.45, drum0 + 0.9, ru + 0.1, n, "STONE_DARK")   # sloped lip
    if state == "intact":
        for k in range(10):                                                   # a few chipped blocks on the lip
            a = 2 * math.pi * (k + rng.uniform(0, 0.5)) / 10
            m = Matrix.Translation((math.cos(a) * (ru + 0.1), math.sin(a) * (ru + 0.1), 0)) @ Matrix.Rotation(a, 4, "Z")
            p.box(0.0, 0.45, -0.8, 0.8, drum0 + 0.2, drum0 + 1.1, "STONE", m)

    def corbels(radius, z0, z1, every=1):
        for k in range(0, n, every):
            a = 2 * math.pi * (k + 0.5) / n
            m = Matrix.Translation((math.cos(a) * (radius + 0.1), math.sin(a) * (radius + 0.1), 0)) @ Matrix.Rotation(a, 4, "Z")
            p.box(-0.6, 0.9, -0.45, 0.45, z0, z1, "STONE_DARK", m)
    if gun:   # the gun platform's battlement overhangs on its own corbels; a roofed drum runs straight up to the eave
        corbels(ru, top - 1.5, top, every=1 if state == "intact" else 2)
    # damaged: a bite out of the band facing outward (windows side, local 200-250 deg)
    GAP = {12, 13, 14} if state == "damaged" else set()
    if not gun:
        p.frustum(0, 0, top, ru, floor, ru, n, "STONE")                         # the drum continues to the eave
    elif not GAP:
        p.frustum(0, 0, top, ru + 1.3, floor, ru + 1.3, n, "STONE")             # battlement band; its top is the gun floor
    else:
        p.frustum(0, 0, top, ru - 0.2, floor - 0.2, ru - 0.2, n, "STONE")       # inner core so the floor stays whole
        for k in range(n):
            if k in GAP:
                continue
            a0, a1 = 2 * math.pi * k / n, 2 * math.pi * (k + 1) / n
            ri, ro = ru - 0.3, ru + 1.3
            q = [(math.cos(a0) * ri, math.sin(a0) * ri), (math.cos(a0) * ro, math.sin(a0) * ro),
                 (math.cos(a1) * ro, math.sin(a1) * ro), (math.cos(a1) * ri, math.sin(a1) * ri)]
            p._add([(x, y, top) for x, y in q] + [(x, y, floor) for x, y in q],
                   [(3, 2, 1, 0), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)], "STONE")
        for k in sorted(GAP):                                                   # ragged stumps in the gap
            a = 2 * math.pi * (k + 0.5) / n
            m = Matrix.Translation((math.cos(a) * (ru + 0.5), math.sin(a) * (ru + 0.5), top)) @ Matrix.Rotation(a, 4, "Z")
            p.box(-0.7, 0.7, -0.9, 0.9, 0, 0.6 + 0.5 * (k % 2), "STONE", m)
    if gun:
        rim = ru + 0.8
        for k in range(12):                                                     # parapet ring: low wall + merlons
            a = 2 * math.pi * k / 12
            if state == "damaged" and (190 <= math.degrees(a) <= 260 or k % 4 == 0):
                continue                                                         # gone over the breach, and a few more
            m = Matrix.Translation((math.cos(a) * rim, math.sin(a) * rim, floor)) @ Matrix.Rotation(a, 4, "Z")
            p.box(-0.5, 0.5, -1.95, 1.95, 0, 1.0, "STONE", m)
            if k % 2 == 0:
                p.box(-0.5, 0.5, -1.0, 1.0, 1.0, 2.8, "STONE", m)
    else:
        # castle-1's roof: a thick rolled eave overhanging the drum, then the shingled
        # cone, a dormer facing out, and a thin iron finial.
        # A narrow annular fighting deck below the eave keeps the four roofed towers
        # usable without replacing their silhouette with open cannon platforms.
        deck_z, inner_r, outer_r = top - 4.2, ru - 0.2, ru + 3.0
        for k in range(n):
            a0, a1 = 2 * math.pi * k / n, 2 * math.pi * (k + 1) / n
            verts = [(math.cos(a) * rr, math.sin(a) * rr, z)
                     for z in (deck_z - 0.35, deck_z) for rr in (inner_r, outer_r)
                     for a in (a0, a1)]
            p._add(verts, [(0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4),
                           (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)], "STONE")
        for k in range(0, n, 2):
            a = 2 * math.pi * (k + 0.5) / n
            m = Matrix.Translation((math.cos(a) * (outer_r - 0.2), math.sin(a) * (outer_r - 0.2), deck_z)) @ Matrix.Rotation(a, 4, "Z")
            p.box(-0.4, 0.4, -0.9, 0.9, 0, 1.8, "STONE", m)
        eave = floor
        rr = ru + 2.9
        p.frustum(0, 0, eave - 0.3, ru + 1.4, eave + 0.3, rr, n, "SLATE")         # underside of the brim
        p.frustum(0, 0, eave + 0.3, rr, eave + 1.1, rr - 0.15, n, "SLATE")        # rolled lip
        roof_top = eave + 1.1 + 15.0
        if state == "intact":
            p.shingle_cone(0, 0, eave + 1.0, rr - 0.2, roof_top, seed=101, tile_w=3.8, tile_h=3.5, step=2.5)
            p.cone(0, 0, roof_top - 0.4, 0.3, roof_top + 3.0, 6, "IRON")         # finial
            p.frustum(0, 0, roof_top + 0.6, 0.5, roof_top + 1.2, 0.5, 6, "IRON")  # its knop
            # dormer on the outward face, a third of the way up the roof
            a = math.radians(225)
            t = 0.3
            dr = (rr - 0.2) * (1 - t) + 0.4
            dz = eave + 1.0 + 15.0 * t
            m = Matrix.Translation((math.cos(a) * dr, math.sin(a) * dr, dz)) @ Matrix.Rotation(a, 4, "Z")
            p.box(-1.2, 0.9, -1.1, 1.1, -0.4, 1.9, "STONE", m)                   # cheeks
            p.box(0.9, 0.95, -0.7, 0.7, 0.0, 1.4, "IRON", m)                     # window
            gm = m @ Matrix.Rotation(math.pi / 2, 4, "Z")
            prev = p.m
            p.m = gm if prev is None else prev @ gm
            p.gable(-1.25, 1.25, -1.4, 1.1, 1.9, 2.9, "SLATE")                   # its little roof
            p.m = prev
        else:
            p.shingle_cone(0, 0, eave + 1.0, rr - 0.2, roof_top, seed=101, tile_w=3.8, tile_h=3.5, step=2.5,
                           top=0.42)   # top shot away
            for k in range(5):                                                  # broken rafters through the hole
                a = 2 * math.pi * k / 5 + 0.3
                m = Matrix.Translation((math.cos(a) * ru * 0.3, math.sin(a) * ru * 0.3, eave + 6.0)) @ Matrix.Rotation(a, 4, "Z") @ Matrix.Rotation(0.5, 4, "Y")
                p.box(-0.2, 0.2, -0.2, 0.2, 0, 3.0, "TIMBER", m)
    for deg, z in ((210, top - 5.0), (240, top - 5.0), (195, 5.5), (255, 5.5), (225, 12.5)):   # windows, outward side
        a = math.radians(deg)
        face = (ru if z > drum0 else r) - 0.3
        m = Matrix.Translation((math.cos(a) * face, math.sin(a) * face, 0)) @ Matrix.Rotation(a, 4, "Z")
        p.box(0.0, 0.5, -0.55, 0.55, z, z + 1.9, "IRON", m)
    if state == "damaged":
        p.rubble(-r - 3, r + 3, -r - 3.5, -r + 1, 12, 1.6, 1.2, seed=31)
    return p.finish("Wall_Corner_Tower" + ("_Gun" if gun else "") + suffix(state), mat)


# ------------------------------------------------------------------ gate
def build_gate(mat):
    p = Piece()
    outline = [(-GATE_HW, 0), (-ARCH_HW, 0)] + arch_outline(ARCH_HW, ARCH_SPRING) + [(ARCH_HW, 0), (GATE_HW, 0), (GATE_HW, GATE_H), (-GATE_HW, GATE_H)]
    p.profile(outline, -GATE_D, GATE_D, "STONE")
    for s in (-1, 1):                                                           # plinths beside the opening
        x0, x1 = sorted((s * ARCH_HW, s * (GATE_HW + 0.4)))
        p.box(x0, x1, -GATE_D - 0.4, GATE_D + 0.4, 0, 1.2, "STONE_DARK")
    rng = random.Random(17)
    # VOUSSOIRS: castle-1's arch is ringed in rough, uneven blocks, each its own depth
    segs = 9
    for k in range(segs):
        a0, a1 = math.pi - math.pi * k / segs + 0.02, math.pi - math.pi * (k + 1) / segs - 0.02
        r0, r1 = ARCH_HW, ARCH_HW + rng.uniform(1.3, 1.9)
        q = [(math.cos(a0) * r0, ARCH_SPRING + math.sin(a0) * r0), (math.cos(a0) * r1, ARCH_SPRING + math.sin(a0) * r1),
             (math.cos(a1) * r1, ARCH_SPRING + math.sin(a1) * r1), (math.cos(a1) * r0, ARCH_SPRING + math.sin(a1) * r0)]
        p.profile(list(reversed(q)), -GATE_D - rng.uniform(0.45, 0.85), -GATE_D, "STONE")
    # QUOINS: alternating long and short blocks up the jambs and up the outer corners
    def quoins(x_edge, sign, z0, z1, long_w, short_w):
        z, k = z0, 0
        while z < z1 - 0.4:
            hgt = min(rng.uniform(1.2, 1.7), z1 - z)
            w = long_w if k % 2 == 0 else short_w
            xa, xb = sorted((x_edge, x_edge + sign * w))
            p.box(xa, xb, -GATE_D - rng.uniform(0.35, 0.6), -GATE_D, z + 0.06, z + hgt - 0.06, "STONE")
            z += hgt
            k += 1
    for s in (-1, 1):
        quoins(s * ARCH_HW, s, 1.2, ARCH_SPRING, 1.9, 1.1)                       # door jambs
        quoins(s * GATE_HW, -s, 1.2, GATE_H - 2.6, 2.4, 1.4)                     # gatehouse corners
    # a row of small, high windows, as on castle-1's gatehouse face
    for x in (-8.0, -4.8, 4.8, 8.0):
        p.box(x - 0.45, x + 0.45, -GATE_D - 0.08, -GATE_D, GATE_H - 5.4, GATE_H - 4.0, "IRON")
    # THE PROJECTING BAND along the top, the same construction as the curtain walls
    p.box(-GATE_HW, GATE_HW, -GATE_D - 0.35, -GATE_D, GATE_H - 2.6, GATE_H - 0.4, "IRON")
    x = -GATE_HW
    while x < GATE_HW - 0.5:
        w = min(rng.uniform(1.8, 2.8), GATE_HW - x)
        p.box(x + 0.08, x + w - 0.08, -GATE_D - rng.uniform(0.95, 1.3), -GATE_D, GATE_H - rng.uniform(1.8, 2.6), GATE_H + 0.1, "STONE")
        x += w
    p.box(-GATE_HW - 0.8, GATE_HW + 0.8, -GATE_D - 1.2, GATE_D + 0.8, GATE_H, GATE_H + 1.4, "STONE")   # roof walk (cannons stand here)
    # the lowered drawbridge, planked, with its two chains up to the wall over the arch
    bridge_y0, bridge_y1 = -GATE_D - 0.4, -GATE_D - 9.0
    for i in range(7):
        x0 = -ARCH_HW + 0.2 + i * (2 * ARCH_HW - 0.4) / 7
        p.box(x0 + 0.05, x0 + (2 * ARCH_HW - 0.4) / 7 - 0.05, bridge_y1, bridge_y0, 0.0, 0.45, "TIMBER")
    for yy in (bridge_y0 - 1.2, bridge_y1 + 1.2):
        p.box(-ARCH_HW - 0.2, ARCH_HW + 0.2, yy - 0.3, yy + 0.3, 0.45, 0.75, "TIMBER")   # battens
    for s in (-1, 1):
        a = Vector((s * (ARCH_HW - 0.3), bridge_y1 + 0.6, 0.6))
        b = Vector((s * (ARCH_HW + 1.6), -GATE_D - 0.3, ARCH_SPRING + ARCH_HW + 2.4))
        d = b - a
        m = Matrix.Translation(a) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4()
        p.box(-0.12, 0.12, -0.12, 0.12, 0, d.length, "IRON", m)
    for x in (-10.4, -6.25, -2.1, 2.1, 6.25, 10.4):                             # merlons, outer and inner edge
        for y0 in (-GATE_D - 0.8, GATE_D - 0.4):
            p.box(x - 1.1, x + 1.1, y0, y0 + 1.2, GATE_H + 1.4, GATE_H + 3.2, "STONE")
    for s in (-1, 1):                                                           # corner turrets (bartizans)
        cx, cy = s * (GATE_HW - 0.6), -GATE_D + 0.4
        p.cone(cx, cy, GATE_H - 1.4, 2.4, GATE_H - 4.8, 8, "STONE_DARK", rot=math.pi / 8)
        p.frustum(cx, cy, GATE_H - 1.4, 2.4, GATE_H + 4.2, 2.3, 8, "STONE", rot=math.pi / 8)
        # castle-1's turret caps: steep "pine-cone" stacks of big slates, jagged at every row
        p.shingle_cone(cx, cy, GATE_H + 4.2, 3.1, GATE_H + 12.0, seed=200 + s,
                       tile_w=1.9, tile_h=2.2, step=1.25, kick=0.6, thick=0.18)
        p.cone(cx, cy, GATE_H + 11.6, 0.2, GATE_H + 13.6, 4, "IRON")
    return p.finish("Gate", mat)


def build_door(mat, state="intact"):
    """Arched timber door, 0.8 thick, centred on its own origin; outer face -Y."""
    p = Piece()
    hw = ARCH_HW - 0.1
    crown = lambda x: ARCH_SPRING + math.sqrt(max(0.0, hw * hw - x * x))
    if state == "intact":
        outline = [(-hw, 0), (hw, 0), (hw, ARCH_SPRING)] + list(reversed(arch_outline(hw, ARCH_SPRING)))[1:-1] + [(-hw, ARCH_SPRING)]
        p.profile(outline, -0.4, 0.4, "TIMBER")
        for z in (2.6, 6.6):                                                    # iron bands
            p.box(-hw + 0.3, hw - 0.3, -0.6, -0.4, z, z + 0.6, "IRON")
        for x in (-2.45, -0.8, 0.8, 2.45):                                      # plank seams
            p.box(x - 0.07, x + 0.07, -0.47, -0.4, 0.3, crown(x) - 0.4, "IRON")
    elif state == "damaged":
        # planks smashed through in the middle: five planks, the centre ones short and ragged
        edges = [-hw, -2.45, -0.8, 0.8, 2.45, hw]
        tops = [None, 4.6, 2.8, 5.4, None]
        for i in range(5):
            x0, x1 = edges[i] + 0.04, edges[i + 1] - 0.04
            if tops[i] is None:
                h0, h1 = crown(x0) - 0.05, crown(x1) - 0.05
                p.profile([(x0, 0), (x1, 0), (x1, h1), (x0, h0)], -0.4, 0.4, "TIMBER")
            else:
                t = tops[i]
                p.profile([(x0, 0), (x1, 0), (x1, t - 0.9), ((x0 + x1) / 2, t), (x0, t - 0.5)], -0.4, 0.4, "TIMBER")
        p.box(-hw + 0.3, -2.5, -0.6, -0.4, 6.6, 7.2, "IRON")                    # what's left of the upper band
        p.box(2.5, hw - 0.3, -0.6, -0.4, 6.6, 7.2, "IRON")
        p.box(-hw + 0.3, hw - 0.3, -0.6, -0.4, 2.0, 2.6, "IRON")
        rng = random.Random(41)
        for k in range(5):                                                      # splinters on the ground
            m = Matrix.Translation((rng.uniform(-3, 3), rng.uniform(-3.5, -1.5), 0.15)) @ Matrix.Rotation(rng.uniform(0, math.pi), 4, "Z")
            p.box(-1.6, 1.6, -0.3, 0.3, -0.15, 0.15, "TIMBER", m)
    else:
        # gone: stumps on the hinge side and the planks down on the floor of the passage
        for x0, x1, h in ((-hw, -3.2, 1.4), (3.2, hw, 0.9)):
            p.box(x0, x1, -0.4, 0.4, 0, h, "TIMBER")
        rng = random.Random(43)
        for k in range(9):
            m = (Matrix.Translation((rng.uniform(-4, 4), rng.uniform(-4, 1), 0.2)) @ Matrix.Rotation(rng.uniform(0, math.pi), 4, "Z")
                 @ Matrix.Rotation(rng.uniform(-0.15, 0.15), 4, "X"))
            p.box(-rng.uniform(1.5, 3.2), rng.uniform(1.5, 3.2), -0.45, 0.45, -0.18, 0.18, "TIMBER", m)
        p.box(-1.8, 1.8, -2.4, -2.0, 0.0, 0.3, "IRON")                          # a bent band
    return p.finish("Gate_Door" + suffix(state), mat)


# ------------------------------------------------------------------ keep and the king's storage
KEEP_HX, KEEP_HY, KEEP_H = 22.0, 22.0, 28.0
KEEP_DOOR_HW, KEEP_DOOR_SPRING = 5.0, 7.0


def build_keep(mat, room, state="intact"):
    """The 44 x 44 hollow Keep; local +X door, stockpile room in its rear-south corner."""
    p = Piece()
    hx, hy, h, wt = KEEP_HX, KEEP_HY, KEEP_H, 1.6
    p.box(-hx - 0.5, hx + 0.5, -hy - 0.5, hy + 0.5, 0, 1.2, "STONE_DARK")       # plinth = floor
    if state == "rubble":
        for x0, x1 in ((-hx, -hx + wt), (hx - wt, hx)):
            p.box(x0, x1, -hy, hy, 1.2, 5.0, "STONE")
        for y0, y1 in ((-hy, -hy + wt), (hy - wt, hy)):
            p.box(-hx + wt, hx - wt, y0, y1, 1.2, 4.3, "STONE")
        p.rubble(-hx + 2, hx - 2, -hy + 2, hy - 2, 70, 2.2, 3.3, seed=111)
        return p.finish("Keep_Rubble", mat)
    p.box(-hx, -hx + wt, -hy, hy, 1.2, h, "STONE")                              # back wall
    for s in (-1, 1):                                                           # side walls
        y0, y1 = sorted((s * hy, s * (hy - wt)))
        p.box(-hx + wt, hx - wt, y0, y1, 1.2, h, "STONE")
    # front wall, with the arched door: built in its own (u, z) plane, then stood on +X
    prev = p.m
    p.m = Matrix.Translation((hx - wt / 2, 0, 0)) @ Matrix.Rotation(math.pi / 2, 4, "Z")
    outline = ([(-hy, 1.2), (-KEEP_DOOR_HW, 1.2)] + [(x, z + 1.2) for x, z in arch_outline(KEEP_DOOR_HW, KEEP_DOOR_SPRING)]
               + [(KEEP_DOOR_HW, 1.2), (hy, 1.2), (hy, h), (-hy, h)])
    p.profile(outline, -wt / 2, wt / 2, "STONE")
    for k in range(7):                                                          # arch frame on the outer face
        a0, a1 = math.pi - math.pi * k / 7, math.pi - math.pi * (k + 1) / 7
        r0, r1 = KEEP_DOOR_HW, KEEP_DOOR_HW + 1.1
        sp = KEEP_DOOR_SPRING + 1.2
        q = [(math.cos(a0) * r0, sp + math.sin(a0) * r0), (math.cos(a0) * r1, sp + math.sin(a0) * r1),
             (math.cos(a1) * r1, sp + math.sin(a1) * r1), (math.cos(a1) * r0, sp + math.sin(a1) * r0)]
        p.profile(list(reversed(q)), -wt / 2 - 0.4, -wt / 2, "STONE_DARK")
    p.m = prev
    # Room bounds and door opening are projected from layout.json by build_meshes().
    # Its 8-stud interior door opens onto the central entrance hall.
    room_x0, room_x1, room_y0, room_y1, door_x, door_hw = room
    inner_h, inner_t = 10.0, 0.9
    p.box(room_x0, room_x0 + inner_t, room_y0, room_y1, 1.2, inner_h, "STONE")
    p.box(room_x1 - inner_t, room_x1, room_y0, room_y1, 1.2, inner_h, "STONE")
    p.box(room_x0, room_x1, room_y0, room_y0 + inner_t, 1.2, inner_h, "STONE")
    for x0, x1 in ((room_x0, door_x - door_hw), (door_x + door_hw, room_x1)):
        p.box(x0, x1, room_y1 - inner_t, room_y1, 1.2, inner_h, "STONE")
    p.box(door_x - door_hw, door_x + door_hw, room_y1 - inner_t, room_y1, 9.0, inner_h, "STONE")
    p.box(-hx + wt, hx - wt, -hy + wt, hy - wt, h - 1.0, h - 0.4, "STONE_DARK")    # ceiling
    p.box(-hx - 0.7, hx + 0.7, -hy - 0.7, hy + 0.7, h - 0.4, h + 1.0, "STONE")   # roof walk, overhanging
    for k in range(int(2 * hx // 4)):                                           # corbels under the roof walk, long sides
        x = -hx + 2 + k * 4
        for s in (-1, 1):
            y0, y1 = sorted((s * hy, s * (hy + 0.7)))
            p.box(x - 0.5, x + 0.5, y0, y1, h - 1.8, h - 0.4, "STONE_DARK")
    # castle-1's keep is a stepped stack of crenellated blocks with tall square towers
    # rising off it, not a box with cones: a second tier set toward the back, a tall
    # tower on one rear corner and a shorter one on the other.
    def crenellate(x0, x1, y0, y1, z, step=3.2, w=1.0):
        for y in (y0, y1):                                                      # long edges
            n_m = max(2, int((x1 - x0) // step))
            for k in range(n_m):
                x = x0 + (k + 0.5) * (x1 - x0) / n_m
                ya, yb = sorted((y, y - math.copysign(0.9, y - (y0 + y1) / 2)))
                p.box(x - w, x + w, ya, yb, z, z + 1.7, "STONE")
        for x in (x0, x1):                                                      # short edges
            n_m = max(2, int((y1 - y0) // step))
            for k in range(n_m):
                y = y0 + (k + 0.5) * (y1 - y0) / n_m
                xa, xb = sorted((x, x - math.copysign(0.9, x - (x0 + x1) / 2)))
                p.box(xa, xb, y - w, y + w, z, z + 1.7, "STONE")

    def arched_window(x, y, z, axis, sign, w=0.55, hgt=2.6):
        """A tall window with a stepped arch head, cut in a face normal to `axis`."""
        for (dz0, dz1, ww) in ((0.0, hgt, w), (hgt, hgt + 0.45, w * 0.62), (hgt + 0.45, hgt + 0.75, w * 0.28)):
            if axis == "x":
                xa, xb = sorted((x, x + sign * 0.14))
                p.box(xa, xb, y - ww, y + ww, z + dz0, z + dz1, "IRON")
            else:
                ya, yb = sorted((y, y + sign * 0.14))
                p.box(x - ww, x + ww, ya, yb, z + dz0, z + dz1, "IRON")

    crenellate(-hx - 0.7, hx + 0.7, -hy - 0.7, hy + 0.7, h + 1.0)                # tier 1 battlements
    if state == "damaged":
        p.rubble(3, hx - 2, -hy + 3, hy - 3, 22, 1.8, 1.8, seed=117)
        return p.finish("Keep_Damaged", mat)
    # tier 2: set back toward the rear, with its own corbelled roof walk
    t2x0, t2x1, t2y0, t2y1, t2h = -hx + 1.0, hx - 7.0, -hy + 3.5, hy - 3.5, h + 9.5
    p.box(t2x0, t2x1, t2y0, t2y1, h + 1.0, t2h, "STONE")
    p.box(t2x0 - 0.6, t2x1 + 0.6, t2y0 - 0.6, t2y1 + 0.6, t2h, t2h + 0.9, "STONE")
    crenellate(t2x0 - 0.6, t2x1 + 0.6, t2y0 - 0.6, t2y1 + 0.6, t2h + 0.9, step=3.0, w=0.9)
    for y in (-5.0, 0.0, 5.0):
        arched_window(t2x1, y, h + 3.5, "x", 1, w=0.5, hgt=2.4)
    # the tall rear tower and its shorter partner, both square and crenellated
    for (sy, side, top_h) in ((-1, 4.4, h + 30.0), (1, 3.4, h + 17.0)):   # castle-1: the keep tower tops the skyline
        cx = -hx + side - 0.4                       # stands 0.4 proud of the keep's back face
        cy = sy * (hy - side + 0.4)                 # ...and of its side face
        x0, x1, y0, y1 = cx - side, cx + side, cy - side, cy + side
        p.box(x0, x1, y0, y1, 1.2, top_h, "STONE")
        p.box(x0 - 0.6, x1 + 0.6, y0 - 0.6, y1 + 0.6, top_h, top_h + 0.9, "STONE")       # corbelled walk
        outer_y = y0 if sy < 0 else y1
        for k in range(4):                                                      # corbels under it, outer face
            xx = x0 + 0.8 + k * (2 * side - 1.6) / 3
            ya, yb = sorted((outer_y, outer_y + sy * 0.6))
            p.box(xx - 0.35, xx + 0.35, ya, yb, top_h - 1.2, top_h, "STONE_DARK")
        crenellate(x0 - 0.6, x1 + 0.6, y0 - 0.6, y1 + 0.6, top_h + 0.9, step=2.6, w=0.8)
        for z in (h + 4.0, h + 11.0, h + 18.0, h + 24.0):
            if z + 3 < top_h:
                arched_window(x1, cy, z, "x", 1, w=0.45, hgt=2.2)
                arched_window(cx, outer_y, z, "y", sy, w=0.45, hgt=2.2)
    # windows on the main block: tall arched lights on the long sides and over the door
    for x in (-6.0, 0.0, 6.0):
        for s in (-1, 1):
            arched_window(x, s * hy, 10.0, "y", s)
    for y in (-8.0, 8.0):
        arched_window(hx, y, 10.0, "x", 1)
    return p.finish("Keep", mat)


def build_stockpile(mat):
    """Goods stay against the room walls; the middle is the deposit/loot interaction."""
    p = Piece()
    for x, y in ((-6.3, -3.5), (-6.3, 0.0), (-6.3, 3.5)):
        p.box(x - 1.2, x + 1.2, y - 1.5, y + 1.5, 0, 1.6, "TIMBER")
        p.box(x - 1.3, x + 1.3, y - 1.6, y + 1.6, 1.6, 2.0, "TIMBER")
        for yy in (y - 0.9, y + 0.9):
            p.box(x - 1.3, x + 1.3, yy - 0.15, yy + 0.15, 0, 2.05, "IRON")
    for x, y, s, z in ((6.2, 3.3, 1.8, 0), (5.7, 1.0, 1.6, 0), (6.0, 3.0, 1.4, 1.8)):
        p.box(x - s / 2, x + s / 2, y - s / 2, y + s / 2, z, z + s, "TIMBER")
    for x, y in ((5.4, -3.7), (6.9, -3.0)):
        p.frustum(x, y, 0, 0.75, 1.0, 0.85, 8, "TIMBER")
        p.frustum(x, y, 1.0, 0.85, 2.0, 0.75, 8, "TIMBER")
        p.frustum(x, y, 0.45, 0.8, 0.6, 0.82, 8, "IRON")
        p.frustum(x, y, 1.4, 0.82, 1.55, 0.8, 8, "IRON")
    for x, y in ((5.0, 0.5), (6.4, 0.2)):
        p.frustum(x, y, 0, 0.7, 0.8, 0.6, 6, "STONE")
        p.cone(x, y, 0.8, 0.6, 1.25, 6, "STONE")
    return p.finish("Stockpile", mat)


# ------------------------------------------------------------------ barracks and workshop
def build_barracks(mat, state="intact"):
    """42 x 27 hollow spawn hall with a 10-stud courtyard doorway on -Y."""
    p = Piece()
    hx, hy, h, wt = 21.0, 13.5, 13.0, 1.2
    p.box(-hx - 0.4, hx + 0.4, -hy - 0.4, hy + 0.4, 0, 0.8, "STONE_DARK")
    if state == "rubble":
        top_back = [(hx, 2.6), (8, 1.6), (0, 3.0), (-8, 1.4), (-hx, 2.4)]
        p.profile([(-hx, 0.8), (hx, 0.8)] + top_back, hy - wt, hy, "STONE")
        top_front = [(hx, 1.8), (6, 2.8), (-3, 1.4), (-hx, 2.2)]
        p.profile([(-hx, 0.8), (hx, 0.8)] + top_front, -hy, -hy + wt, "STONE")
        p.rubble(-hx + 1, hx - 1, -hy + 1, hy - 1, 40, 2.0, 2.2, seed=51)
        rng = random.Random(53)
        for k in range(6):                                                      # roof beams down in the heap
            m = Matrix.Translation((rng.uniform(-12, 12), rng.uniform(-4, 4), 1.4)) @ Matrix.Rotation(rng.uniform(0, math.pi), 4, "Z") @ Matrix.Rotation(rng.uniform(-0.3, 0.3), 4, "Y")
            p.box(-3.5, 3.5, -0.3, 0.3, -0.3, 0.3, "TIMBER", m)
        for k in range(5):
            m = Matrix.Translation((rng.uniform(-12, 12), rng.uniform(-4, 4), 1.2)) @ Matrix.Rotation(rng.uniform(0, math.pi), 4, "Z") @ Matrix.Rotation(rng.uniform(-0.4, 0.4), 4, "X")
            p.box(-1.6, 1.6, -1.2, 1.2, -0.1, 0.1, "SLATE", m)
        return p.finish("Barracks_Rubble", mat)
    p.box(-hx, hx, hy - wt, hy, 0.8, h, "STONE")                                # back wall
    for s in (-1, 1):                                                           # gable ends
        x0, x1 = sorted((s * hx, s * (hx - wt)))
        p.box(x0, x1, -hy + wt, hy - wt, 0.8, h, "STONE")
        prev = p.m
        p.m = Matrix.Translation((s * (hx - wt / 2), 0, 0)) @ Matrix.Rotation(math.pi / 2, 4, "Z")
        p.profile([(-hy, h), (hy, h), (0, h + 4.6)], -wt / 2, wt / 2, "STONE")
        p.m = prev
    door = [(-5.0, 0.8)] + [(x, z + 0.8) for x, z in arch_outline(5.0, 6.2, 8)] + [(5.0, 0.8)]
    if state == "intact":
        outline = [(-hx, 0.8)] + door + [(hx, 0.8), (hx, h), (-hx, h)]
    else:   # a bite out of the wall east of the door; the door itself still stands
        outline = [(-hx, 0.8)] + door + [(hx, 0.8), (hx, h), (12.0, h), (10.5, 5.6), (8.0, 6.8), (6.0, 5.4), (4.4, h), (-hx, h)]
    p.profile(outline, -hy, -hy + wt, "STONE")
    for x in (-11.0, -6.0, 6.0, 11.0):                                          # windows
        if state == "intact" or x < 0:
            p.box(x - 0.6, x + 0.6, -hy - 0.12, -hy, 4.0, 6.2, "IRON")
        p.box(x - 0.6, x + 0.6, hy, hy + 0.12, 4.0, 6.2, "IRON")
    if state == "intact":
        p.gable(-hx - 0.8, hx + 0.8, -hy - 1.2, hy + 1.2, h, h + 6.0, "SLATE")
    else:
        p.gable(-hx - 0.8, 2.0, -hy - 1.2, hy + 1.2, h, h + 6.0, "SLATE")
        for k in range(4):                                                       # bare rafters over the hole
            x = 4.0 + k * 3.6
            m = Matrix.Translation((x, -2.8, h + 0.2)) @ Matrix.Rotation(-0.62, 4, "X")
            p.box(-0.2, 0.2, -0.2, 0.2, 0, 6.8, "TIMBER", m)
        p.rubble(4, hx - 2, -hy + 1.5, hy - 1.5, 16, 1.6, 1.4, seed=57)
    for x in (-12.0, -6.0, 0.0, 6.0, 12.0):                                     # bunks along the back wall
        if state == "intact" or x < 2:
            p.box(x - 1.3, x + 1.3, hy - wt - 2.4, hy - wt, 0.8, 1.6, "TIMBER")
            p.box(x - 1.3, x + 1.3, hy - wt - 2.4, hy - wt, 3.0, 3.6, "TIMBER")
    return p.finish("Barracks" + suffix(state), mat)


def build_workshop(mat, state="intact"):
    """Open-fronted forge; open side on +Y so rams and siege cannons can roll out.
    Local X +-15, Y +-7 (the layout's 30 x 14)."""
    p = Piece()
    hx, hy, h = 15.0, 7.0, 8.0
    p.box(-hx - 0.4, hx + 0.4, -hy - 0.4, hy + 0.4, 0, 0.6, "STONE_DARK")
    if state == "rubble":
        p.profile([(-hx, 0.6), (hx, 0.6), (hx, 2.4), (6, 3.2), (0, 1.6), (-7, 2.8), (-hx, 1.8)], -hy, -hy + 1.2, "STONE")
        p.box(-9, -5, -6, -3, 0.6, 2.0, "STONE_DARK")                            # the hearth survives, low
        p.rubble(-hx + 1, hx - 1, -hy + 1, hy - 1, 30, 1.8, 1.8, seed=61)
        rng = random.Random(63)
        for k in range(6):
            m = Matrix.Translation((rng.uniform(-12, 12), rng.uniform(-4, 5), 1.0)) @ Matrix.Rotation(rng.uniform(0, math.pi), 4, "Z") @ Matrix.Rotation(rng.uniform(-0.3, 0.3), 4, "Y")
            p.box(-3.0, 3.0, -0.3, 0.3, -0.3, 0.3, "TIMBER", m)
        return p.finish("Workshop_Rubble", mat)
    p.box(-hx, hx, -hy, -hy + 1.2, 0.6, h, "STONE")                             # back wall
    for s in (-1, 1):                                                           # side walls, part depth
        x0, x1 = sorted((s * hx, s * (hx - 1.2)))
        p.box(x0, x1, -hy + 1.2, 3.0, 0.6, h, "STONE")
    posts = (-14.4, -5.0, 5.0, 14.4)
    for x in posts:                                                             # front posts
        if state == "damaged" and x == 5.0:
            p.box(x - 0.35, x + 0.35, 6.25, 6.95, 0.6, 3.2, "TIMBER")           # snapped
            continue
        p.box(x - 0.35, x + 0.35, 6.25, 6.95, 0.6, h, "TIMBER")
    p.box(-hx, hx, 6.2, 7.0, h - 0.6, h, "TIMBER")                              # front beam
    if state == "intact":
        p.gable(-hx - 0.8, hx + 0.8, -hy - 1.2, hy + 1.2, h, h + 4.4, "SLATE")
    else:
        p.gable(-hx - 0.8, 1.0, -hy - 1.2, hy + 1.2, h, h + 4.4, "SLATE")
        m = Matrix.Translation((7.5, 3.0, 4.0)) @ Matrix.Rotation(0.45, 4, "X")   # a slab of roof slid down the front
        p.box(-6.0, 6.0, -3.2, 3.2, -0.15, 0.15, "SLATE", m)
        p.rubble(3, hx - 2, -hy + 1.5, 5, 12, 1.5, 1.2, seed=67)
    p.box(-9.0, -5.0, -6.0, -3.0, 0.6, 2.6, "STONE_DARK")                        # hearth
    p.cone(-7.0, -4.5, 3.6, 2.6, 6.8, 4, "STONE_DARK", rot=math.pi / 4)          # hood
    p.box(-7.8, -6.2, -5.3, -3.7, 5.6, h + 6.0, "STONE_DARK")                    # chimney through the roof
    p.box(-7.0, -5.8, -4.2, -3.2, 2.6, 2.75, "IRON")                             # coals
    p.box(-2.6, -1.4, -2.6, -1.6, 0.6, 2.0, "TIMBER")                            # anvil block
    p.box(-3.0, -1.0, -2.8, -1.4, 2.0, 2.7, "IRON")                              # anvil
    p.box(4.0, 10.0, -5.6, -3.6, 2.6, 3.0, "TIMBER")                             # bench top
    for x in (4.3, 9.7):
        for y in (-5.3, -3.9):
            p.box(x - 0.2, x + 0.2, y - 0.2, y + 0.2, 0.6, 2.6, "TIMBER")
    for k in range(3):                                                          # timber stack by the side wall
        p.along_x(10.0, 1.5 + k * 1.3, 1.1, 3.5, 0.55, 0.55, 6, "TIMBER")
    return p.finish("Workshop" + suffix(state), mat)


def build_specialist(mat, role, hx, hy, door_side, ram_side=0, state="intact"):
    """A distinct village building at its layout footprint. Door is on local +/-Y."""
    p = Piece()
    h, wt, door_hw = 10.5, 1.0, 4.0
    wall_col = "STONE" if role == "Blacksmith_Forge" else "PLASTER"
    frame_col = "FORGE_WOOD" if role == "Blacksmith_Forge" else "FRAME"
    p.box(-hx, hx, -hy, hy, 0, 0.7,
          "FORGE_FLOOR" if role == "Blacksmith_Forge" else "STONE_DARK")
    if state == "rubble":
        for yy in (-hy, hy - wt):
            p.box(-hx, hx, yy, yy + wt, 0.7, 2.3, "STONE")
        p.rubble(-hx + 1, hx - 1, -hy + 1, hy - 1, 24, 1.4, 1.5, seed=200 + len(role))
        return p.finish(role + "_Rubble", mat)
    for side in (-1, 1):
        y0, y1 = (side * hy - wt, side * hy) if side > 0 else (side * hy, side * hy + wt)
        if side == door_side:
            wall_runs = ((door_hw, hx),) if role == "Blacksmith_Forge" else ((-hx, -door_hw), (door_hw, hx))
            for x0, x1 in wall_runs:
                p.box(x0, x1, y0, y1, 0.7, h, wall_col)
            p.box(-door_hw, door_hw, y0, y1, 8.7, h, wall_col)
        else:
            p.box(-hx, hx, y0, y1, 0.7, h, wall_col)
    for side in (-1, 1):
        x0, x1 = (side * hx - wt, side * hx) if side > 0 else (side * hx, side * hx + wt)
        if side == ram_side:
            for y0, y1 in ((-hy + wt, -6.0), (6.0, hy - wt)):
                p.box(x0, x1, y0, y1, 0.7, h, wall_col)
            p.box(x0, x1, -6.0, 6.0, 8.7, h, "TIMBER")
        elif role == "Blacksmith_Forge" and side > 0:
            # Three high openings admit the shafts of daylight in the reference.
            p.box(x0, x1, -hy + wt, hy - wt, 0.7, 6.2, wall_col)
            p.box(x0, x1, -hy + wt, hy - wt, 9.4, h, wall_col)
            for ya, yb in ((-hy + wt, -9), (-5, -2), (2, 5), (9, hy - wt)):
                p.box(x0, x1, ya, yb, 6.2, 9.4, wall_col)
            for ya, yb in ((-9, -5), (-2, 2), (5, 9)):
                p.box(x0 - 0.1, x1 + 0.1, ya, yb, 7.65, 7.95, "TIMBER")
                ym = (ya + yb) / 2
                p.box(x0 - 0.1, x1 + 0.1, ym - 0.12, ym + 0.12, 6.2, 9.4, "TIMBER")
        else:
            p.box(x0, x1, -hy + wt, hy - wt, 0.7, h, wall_col)
    # A small village facade: thick timber posts, sill and lintel. Roofs are
    # separate meshes for interior inspection and third-person camera fading.
    for side in (-1, 1):
        y = side * (hy + 0.12)
        for x in (-hx + 0.55, hx - 0.55):
            p.box(x - 0.36, x + 0.36, y - 0.25, y + 0.25, 0.7, h, frame_col)
        if side == door_side:
            for x in (-door_hw - 0.4, door_hw + 0.4):
                p.box(x - 0.29, x + 0.29, y - 0.25, y + 0.25, 0.7, 9.1, frame_col)
            p.box(-door_hw - 0.7, door_hw + 0.7, y - 0.25, y + 0.25, 8.9, 9.4, frame_col)
        else:
            for x in (-hx / 3, hx / 3):
                p.box(x - 0.28, x + 0.28, y - 0.25, y + 0.25, 0.7, h, frame_col)
        p.box(-hx + 0.2, hx - 0.2, y - 0.25, y + 0.25, h - 0.7, h - 0.15, frame_col)
    for side in (-1, 1):
        x = side * (hx + 0.12)
        for y in (-hy + 0.55, hy - 0.55):
            p.box(x - 0.25, x + 0.25, y - 0.36, y + 0.36, 0.7, h, frame_col)
        if side != ram_side:
            p.box(x - 0.25, x + 0.25, -hy + 0.4, hy - 0.4, h - 0.7, h - 0.15, frame_col)
    # A stone foot and framed shutters break the large plain faces at eye height.
    for side in (-1, 1):
        y = side * (hy + 0.19)
        front_runs = ((door_hw + 0.7, hx - 0.3),) if role == "Blacksmith_Forge" else (
            (-hx + 0.3, -door_hw - 0.7), (door_hw + 0.7, hx - 0.3))
        for xa, xb in front_runs if side == door_side else ((-hx + 0.3, hx - 0.3),):
            p.box(xa, xb, y - 0.13, y + 0.13, 0.7, 1.65, "STONE_DARK")
        if role == "Blacksmith_Forge" and side != door_side:
            continue
        for x in (-hx + 5.0, hx - 5.0):
            if role == "Blacksmith_Forge" and x < 0:
                continue
            if side == door_side and abs(x) < door_hw + 2.0:
                continue
            p.box(x - 1.1, x + 1.1, y - 0.06, y + 0.06, 4.3, 7.8, "IRON")
            for xx in (x - 1.35, x + 1.35):
                p.box(xx - 0.15, xx + 0.15, y - 0.12, y + 0.12, 4.1, 8.0, frame_col)
            p.box(x - 1.35, x + 1.35, y - 0.12, y + 0.12, 5.9, 6.2, frame_col)
            for xx in (x - 1.85, x + 1.85):
                p.box(xx - 0.28, xx + 0.28, y - 0.2, y + 0.2, 4.0, 8.1, frame_col)
    back_y = -door_side * (hy - 3.8)
    if role == "Blacksmith_Forge":
        # One broad forge/worktable is the focal point from the front doorway.
        # Keep x=-4..4 near the door clear for a 5-stud avatar.
        p.box(-hx + 1.02, -hx + 1.14, -hy + 1, hy - 1, 0.72, 9.8, "FORGE_STONE")
        p.box(-hx + 1, hx - 1, -hy + 1.02, -hy + 1.14, 0.72, 9.8, "FORGE_STONE")
        for ya, yb in ((-hy + 1, -9), (-5, -2), (2, 5), (9, hy - 1)):
            p.box(hx - 1.14, hx - 1.02, ya, yb, 0.72, 9.8, "FORGE_STONE")
        for x0, x1, y0, y1 in ((-10, -2, -9.5, -3.7), (5.5, 11.5, -10.5, -7.0)):
            p.box(x0, x1, y0, y1, 0.72, 1.15, "STONE_DARK")
        # Central fire table: heavy timber base, stone bed, iron grate and coals.
        for x in (-9.4, -2.6):
            for y in (-8.2, -3.8):
                p.box(x - 0.42, x + 0.42, y - 0.42, y + 0.42, 0.72, 2.8, "FORGE_WOOD")
        p.box(-10.2, -1.8, -9.0, -3.0, 2.6, 3.15, "FORGE_WOOD")
        p.box(-9.5, -2.5, -8.3, -3.7, 3.15, 3.55, "STONE_DARK")
        p.box(-9.0, -3.0, -7.8, -4.2, 3.55, 3.77, "EMBER")
        for x in (-8.5, -6.5, -4.5):
            p.box(x - 0.12, x + 0.12, -8.0, -4.0, 3.8, 3.98, "IRON")
        for x, y, r, top in ((-8, -6.6, 0.95, 5.5), (-6, -5.2, 1.15, 6.2), (-4.5, -7, 0.72, 5.15)):
            p.cone(x, y, 4.0, r, top, 5, "FIRE", rot=0.2)
        p.frustum(-6, -6, 7.0, 4.3, 9.6, 1.8, 4, "IRON", rot=math.pi / 4)
        p.box(-7.6, -4.4, -7.6, -4.4, 9.2, 19.0, "FORGE_STONE")
        # Anvil and quench barrel occupy the right of the room, leaving a walk lane.
        p.box(5.8, 7.6, -2.8, -1.0, 0.72, 2.35, "FORGE_WOOD")
        p.box(5.0, 8.5, -3.35, -0.45, 2.35, 2.85, "IRON")
        p.box(5.7, 7.9, -2.8, -1.0, 2.85, 3.18, "IRON")
        p.frustum(9.6, 5.2, 0.72, 1.5, 3.5, 1.5, 8, "FORGE_WOOD")
        for z in (1.2, 3.0):
            p.frustum(9.6, 5.2, z, 1.55, z + 0.18, 1.55, 8, "IRON")
        # Rear bench, tool rack, large tongs and a few visibly forged blanks.
        p.box(4.6, 11.5, -11.7, -9.0, 2.35, 2.78, "FORGE_WOOD")
        for x in (5.0, 11.1):
            p.box(x - 0.3, x + 0.3, -11.3, -9.4, 0.72, 2.35, "FORGE_WOOD")
        p.box(4.7, 11.5, -12.55, -12.15, 5.2, 5.6, "FORGE_WOOD")
        for x in (5.5, 7.5, 9.5, 11.0):
            p.box(x - 0.1, x + 0.1, -12.25, -11.95, 3.4, 5.25, "IRON")
            p.box(x - 0.4, x + 0.4, -12.25, -11.95, 3.2, 3.5, "IRON")
        for x in (6.0, 8.5, 10.5):
            p.box(x - 0.45, x + 0.45, -11.1, -10.75, 2.78, 2.95, "IRON")
        # Ore/coal crate and a side-wall tool rail give the room a worked-in edge.
        p.box(-11.3, -7.2, 4.2, 8.0, 0.72, 1.05, "FORGE_WOOD")
        for x0, x1 in ((-11.3, -10.95), (-7.55, -7.2)):
            p.box(x0, x1, 4.2, 8.0, 1.05, 2.2, "FORGE_WOOD")
        for y0, y1 in ((4.2, 4.55), (7.65, 8.0)):
            p.box(-11.3, -7.2, y0, y1, 1.05, 2.2, "FORGE_WOOD")
        for x, y in ((-10.2, 5.1), (-8.5, 5.7), (-9.7, 7.0)):
            p.frustum(x, y, 1.4, 0.7, 2.65, 0.45, 5, "IRON")
        p.box(-12.65, -12.35, -2.5, 5.0, 5.1, 5.55, "FORGE_WOOD")
        for y in (-1.0, 1.4, 3.8):
            p.box(-12.35, -12.1, y - 0.1, y + 0.1, 3.1, 5.1, "IRON")
            p.box(-12.35, -12.1, y - 0.38, y + 0.38, 3.0, 3.3, "IRON")
        # Timber rafters under the roof expose the tall ceiling when viewed inside.
        def beam(a, b, width):
            va, vb = Vector(a), Vector(b)
            d = vb - va
            m = Matrix.Translation((va + vb) / 2) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4()
            p.box(-width/2, width/2, -width/2, width/2, -d.length/2, d.length/2, "FORGE_WOOD", m)
        for x in (-10.5, 0.0, 10.5):
            beam((x, -13, 10.5), (x, 0, 16.0), 0.55)
            beam((x, 0, 16.0), (x, 13, 10.5), 0.55)
            p.box(x - 0.28, x + 0.28, -12.5, 12.5, 10.3, 10.85, "FORGE_WOOD")
    return p.finish(role + suffix(state), mat)


def build_specialist_roof(mat, role, hx, hy, state="intact"):
    """Thin tiled roof exposes the interior and can fade separately in game."""
    p = Piece()
    dark_roof = role == "Blacksmith_Forge"
    roof_col = "FORGE_ROOF" if dark_roof else "VILLAGE_ROOF"
    tile_col = "FORGE_ROOF_LIGHT" if dark_roof else "VILLAGE_ROOF_LIGHT"
    frame_col = "FORGE_WOOD" if dark_roof else "FRAME"
    gable_col = "STONE" if dark_roof else "PLASTER"
    if state == "rubble":
        p.rubble(-hx + 2, hx - 2, -hy + 2, hy - 2, 8, 1.3, 0.5, seed=420,
                 cols=(roof_col,))
        return p.finish(role + "_Roof_Rubble", mat)
    slope_y, rise = hy + 0.8, 6.0
    slope_len = math.hypot(slope_y, rise)
    x1 = hx + 0.6 if state == "intact" else 0.0
    x0 = -3.9 if dark_roof else -hx - 0.6
    for side in (-1, 1):
        m = (Matrix.Translation((0, side * slope_y / 2, 13.5))
             @ Matrix.Rotation(-side * math.atan2(rise, slope_y), 4, "X"))
        p.box(x0, x1, -slope_len / 2, slope_len / 2,
              -0.28, 0.28, roof_col, m)
        p.box(x0, x1, side * (hy + 0.45) - 0.2,
              side * (hy + 0.45) + 0.2, 10.15, 10.75, frame_col)
        # Broad overlapping patches read as roof tiles without modeling bricks.
        cols, rows = max(1, math.ceil((x1 - x0) / 3.8)), 6
        for row in range(rows):
            t0, t1 = row / rows, (row + 1) / rows
            yy0, yy1 = side * slope_y * t0, side * slope_y * t1
            zz0, zz1 = 16.5 - rise * t0 + 0.35, 16.5 - rise * t1 + 0.35
            for col in range(cols):
                xx0 = x0 + (x1 - x0) * col / cols
                xx1 = x0 + (x1 - x0) * (col + 1) / cols
                verts = [(xx0, yy0, zz0), (xx1, yy0, zz0),
                         (xx1, yy1, zz1), (xx0, yy1, zz1)]
                p._add(verts, [(0, 1, 2, 3) if side > 0 else (3, 2, 1, 0)],
                       tile_col if (row + col) % 4 == 0 else roof_col)
    # Gable ends close the room while preserving the high inside roofline.
    for x in (x0 + 0.2, x1 - 0.2):
        width = 0.35
        vs = [(x-width/2, -hy, 10.5), (x-width/2, hy, 10.5),
              (x-width/2, 0, 16.2), (x+width/2, -hy, 10.5),
              (x+width/2, hy, 10.5), (x+width/2, 0, 16.2)]
        p._add(vs, [(0,1,2), (5,4,3), (0,3,4,1), (1,4,5,2), (2,5,3,0)], gable_col)
    if dark_roof and state == "intact":
        # The public work bay has a lower, sun-warmed lean-to. Its front is open.
        canopy_x0, canopy_x1 = -hx - 0.6, -3.7
        canopy_y = hy + 0.55
        drop = 3.4
        length = math.hypot(2 * canopy_y, drop)
        lean = (Matrix.Translation((0, 0, 12.2))
                @ Matrix.Rotation(-math.atan2(drop, 2 * canopy_y), 4, "X"))
        p.box(canopy_x0, canopy_x1, -length / 2, length / 2,
              -0.3, 0.3, "FORGE_CANOPY", lean)
        for row in range(6):
            for col in range(3):
                xx0 = canopy_x0 + (canopy_x1 - canopy_x0) * col / 3
                xx1 = canopy_x0 + (canopy_x1 - canopy_x0) * (col + 1) / 3
                yy0 = -canopy_y + 2 * canopy_y * row / 6
                yy1 = -canopy_y + 2 * canopy_y * (row + 1) / 6
                zz0 = 12.2 - drop * yy0 / (2 * canopy_y) + 0.34
                zz1 = 12.2 - drop * yy1 / (2 * canopy_y) + 0.34
                p._add([(xx0, yy0, zz0), (xx1, yy0, zz0),
                        (xx1, yy1, zz1), (xx0, yy1, zz1)],
                       [(0, 1, 2, 3)],
                       "FORGE_CANOPY_LIGHT" if (row + col) % 5 == 0 else "FORGE_CANOPY")
        p.box(canopy_x0, canopy_x1, hy + 0.35, hy + 0.75,
              10.05, 10.8, frame_col)
    return p.finish(role + "_Roof" + suffix(state), mat)


def build_blacksmith_detail(mat, state="intact"):
    """Separate readable forge frontage, so the workshop shell stays in budget."""
    p = Piece()
    if state == "rubble":
        p.rubble(-12, 11, -11, 12, 12, 0.65, 0.5, seed=484,
                 cols=("FORGE_STONE", "FORGE_WOOD"))
        return p.finish("Blacksmith_Detail_Rubble", mat)

    # The photo's worn dark flagstones, with thin foundation showing as grout.
    # These are visual faces only; the forge shell keeps the continuous walkable floor.
    rng = random.Random(617)
    for row in range(9):
        y0 = -12.65 + row * 2.85
        for col in range(9):
            x0 = -13.2 + col * 3.12 + (1.45 if row % 2 else 0)
            x1 = min(12.65, x0 + 2.92)
            if x1 - x0 < 0.75:
                continue
            y1 = min(12.65, y0 + 2.66)
            z = 0.73 + rng.uniform(0, 0.035)
            trim = rng.uniform(0.03, 0.17)
            p._add([(x0 + trim, y0 + 0.08, z), (x1 - 0.08, y0 + trim, z),
                    (x1 - trim, y1 - 0.08, z), (x0 + 0.08, y1 - trim, z)],
                   [(0, 1, 2, 3)],
                   ("FORGE_STONE", "COURT_DARK", "STONE_DARK")[(row * 5 + col * 7) % 3])

    # Hearth backplate and an open, dark firebox behind the working grate.
    p.box(-11.0, -1.0, -13.15, -12.76, 0.72, 9.1, "FORGE_STONE")
    p.box(-9.15, -2.85, -12.69, -12.56, 1.0, 4.3, "IRON")
    for x0, x1 in ((-10.9, -9.35), (-2.65, -1.1)):
        p.box(x0, x1, -12.56, -11.96, 0.72, 4.4, "FORGE_STONE")
    cx, cz, inner, outer = -6.0, 4.35, 2.95, 4.15
    for i in range(7):
        a0, a1 = math.pi * i / 7, math.pi * (i + 1) / 7
        outline = [(cx + r * math.cos(a), cz + r * math.sin(a))
                   for r, a in ((inner, a0), (outer, a0),
                                (outer, a1), (inner, a1))]
        p.profile(outline, -12.68, -11.98, "STONE" if i % 2 else "FORGE_STONE")
    for row in range(3):
        for col in range(5):
            x0 = -10.7 + 1.82 * col + (0.55 if row % 2 else 0)
            if x0 > -2.2:
                continue
            z0 = 8.0 + 0.43 * row
            p.box(x0, x0 + 1.42, -12.0, -11.84, z0, z0 + 0.24,
                  "STONE" if (row + col) % 3 == 0 else "FORGE_STONE")

    # Cobbles under the public work bay, raised enough to catch angled light.
    for row in range(4):
        for col in range(4):
            x0 = -12.55 + col * 2.25 + (0.42 if row % 2 else 0)
            y0 = 6.2 + row * 1.8
            p.box(x0, x0 + 1.75, y0, y0 + 1.3, 0.72, 0.83,
                  "COURT_LIGHT" if (row + col) % 3 == 0 else "FORGE_STONE")
    for x0, x1, y0, y1 in ((-2.3, 2.3, 10.8, 12.2),
                           (-1.7, 1.7, 12.25, 13.45)):
        p.box(x0, x1, y0, y1, 0.72, 0.91, "COURT_LIGHT")

    # Timber-framed shop wall behind the separate public forge bay. The gap
    # towards the rear lets an avatar walk from the working bay into the room.
    for ya, yb in ((-12.8, -1.2), (6.1, 13.2)):
        p.box(-4.15, -3.8, ya, yb, 0.76, 9.8, "PLASTER")
        for y in (ya + 0.5, yb - 0.5):
            p.box(-4.32, -3.68, y - 0.23, y + 0.23, 0.76, 9.8, "FORGE_WOOD")
    p.box(-4.32, -3.68, -1.2, 6.1, 8.5, 9.1, "FORGE_WOOD")

    # A readable hanging anvil sign, made from a small original silhouette.
    p.box(-11.55, -6.25, 13.38, 13.77, 6.4, 9.15, "FORGE_WOOD")
    p.box(-11.9, -5.9, 13.37, 13.79, 9.0, 9.35, "TIMBER")
    p.box(-11.9, -5.9, 13.37, 13.79, 6.2, 6.55, "TIMBER")
    p.profile([(-10.8, 8.2), (-7.0, 8.2), (-7.5, 7.75),
               (-8.15, 7.75), (-8.35, 6.95), (-9.35, 6.95),
               (-9.6, 7.75), (-10.4, 7.75)], 13.8, 13.95, "IRON")
    return p.finish("Blacksmith_Detail" + suffix(state), mat)


def build_blacksmith_forecourt(mat):
    """Curved, broad flagstone terraces like the user reference, inside 38 x 19."""
    p = Piece()
    cy = -9.5  # the shop threshold; arcs widen into the courtyard (+Y)
    rng = random.Random(1017)

    def slab(r0, r1, a0, a1, top, col):
        # Three angular samples give each tread a visibly curved front edge.
        angles = (a0, (a0 + a1) / 2, a1)
        outer = [(r1 * math.cos(a), cy + r1 * math.sin(a)) for a in angles]
        inner = ([(r0 * math.cos(a), cy + r0 * math.sin(a)) for a in reversed(angles)]
                 if r0 else [(0, cy)])
        outline = outer + inner
        n = len(outline)
        verts = [(x, y, 0.045) for x, y in outline] + [(x, y, top) for x, y in outline]
        faces = [tuple(reversed(range(n))), tuple(range(n, 2 * n))]
        faces += [(i, (i + 1) % n, n + (i + 1) % n, n + i) for i in range(n)]
        p._add(verts, faces, col)

    # Dark mortar follows the curved outline rather than leaving a rectangular pad.
    for k in range(20):
        slab(0, 18.9, math.pi * k / 20, math.pi * (k + 1) / 20,
             0.075, "COURT_DARK")

    # Each ring steps down only 0.1-0.2 stud, so it remains comfortable to walk.
    # Offset joints between courses; wide varied flagstones read at gameplay distance.
    courses = ((0, 7.4, 0.69, 10), (7.55, 11.8, 0.53, 8),
               (11.95, 15.4, 0.35, 10), (15.55, 17.25, 0.22, 11),
               (17.4, 18.82, 0.115, 13))
    for ring, (inner, outer, height, count) in enumerate(courses):
        for k in range(count):
            margin = 0 if ring in (0, 4) else 0.006 / max(1, outer / 9)
            a0 = math.pi * k / count + margin
            a1 = math.pi * (k + 1) / count - margin
            tone = ("COURT_GRAVEL" if ring == 4 else "COURT_STONE" if ring == 0 else
                    ("COURT_STONE", "COURT_LIGHT", "COURT_STONE", "COURT_DARK")[(k * 3 + ring * 5) % 4])
            slab(inner, outer, a0, a1,
                 height if ring in (0, 4) else height + rng.uniform(-0.018, 0.018), tone)

    # Large worn flags on the top landing instead of a starburst of radial joints.
    flags = (
        (-6.25, -2.25, -9.15, -7.55), (-2.00, 2.00, -9.15, -7.55),
        (2.25, 6.25, -9.15, -7.55), (-5.90, -2.05, -7.30, -5.45),
        (-1.80, 2.35, -7.30, -5.45), (2.60, 5.90, -7.30, -5.45),
        (-3.05, -0.10, -5.20, -2.98), (0.15, 3.05, -5.20, -2.98),
    )
    for k, (x0, x1, y0, y1) in enumerate(flags):
        c = 0.08 + (k % 3) * 0.025
        p._add([(x0 + c, y0 + 0.06, 0.701), (x1 - 0.06, y0 + c, 0.701),
                (x1 - c, y1 - 0.06, 0.701), (x0 + 0.06, y1 - c, 0.701)],
               [(0, 1, 2, 3)], "COURT_LIGHT" if k % 4 == 0 else "COURT_STONE")

    # Sparse, irregular small stones break up the gravel collar without noise.
    for k in range(62):
        a = math.pi * (k + 0.25 + rng.uniform(-0.2, 0.2)) / 62
        r = rng.uniform(17.65, 18.55)
        x, y = r * math.cos(a), cy + r * math.sin(a)
        sx, sy = rng.uniform(0.06, 0.18), rng.uniform(0.06, 0.17)
        p._add([(x - sx, y - sy, 0.124), (x + sx, y - sy * 0.7, 0.124),
                (x + sx * 0.3, y + sy, 0.124)],
               [(0, 1, 2)], "COURT_LIGHT" if k % 5 == 0 else "COURT_DARK")
    return p.finish("Blacksmith_Forecourt", mat)


def build_specialist_detail(mat, role, hx, hy, door_side, state="intact"):
    """Role-specific workstations with a clear path from the approved door."""
    p = Piece()
    if state == "rubble":
        p.rubble(-hx + 1, hx - 1, -hy + 1, hy - 1, 14, 0.7, 0.5,
                 seed=510 + len(role), cols=("TIMBER", "STONE"))
        return p.finish(role + "_Detail_Rubble", mat)

    def beam(a, b, width, col="TIMBER"):
        va, vb = Vector(a), Vector(b)
        d = vb - va
        m = Matrix.Translation((va + vb) / 2) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4()
        p.box(-width / 2, width / 2, -width / 2, width / 2,
              -d.length / 2, d.length / 2, col, m)

    def bench(x0, x1, y0, y1, top=2.7):
        p.box(x0, x1, y0, y1, top - 0.32, top, "TIMBER")
        for x in (x0 + 0.35, x1 - 0.35):
            for y in (y0 + 0.35, y1 - 0.35):
                p.box(x - 0.22, x + 0.22, y - 0.22, y + 0.22,
                      0.75, top - 0.2, "FRAME")

    rear = -door_side * (hy - 3.9)
    side_y = -door_side * (hy - 7.4)
    # Full plank floor, raised only a fraction above the stone foundation.
    # Boards are staggered in length so the floor does not read as one slab.
    for i in range(int((2 * hx - 2.2) / 1.55)):
        x0 = -hx + 1.1 + 1.55 * i
        joint = (-2.5 if i % 2 else 2.5)
        for ya, yb in ((-hy + 1.15, joint - 0.08),
                       (joint + 0.08, hy - 1.15)):
            p.box(x0, x0 + 1.4, ya, yb, 0.72, 0.81,
                  "FORGE_WOOD" if i % 3 == 0 else "TIMBER")
    # Exposed rafters and corner braces remain visible when the roof fades.
    for y in (-hy + 2.2, 0, hy - 2.2):
        p.box(-hx + 0.8, hx - 0.8, y - 0.22, y + 0.22,
              9.65, 10.2, "FRAME")
    for x in (-hx + 0.7, hx - 0.7):
        for y in (-hy + 1.1, hy - 1.1):
            p.box(x - 0.2, x + 0.2, y - 0.2, y + 0.2,
                  0.8, 9.9, "FRAME")
    rear_wall = -door_side * (hy - 1.05)
    p.box(-hx + 1.1, hx - 1.1, rear_wall - 0.15, rear_wall + 0.15,
          2.0, 2.35, "FRAME")
    for x in (-hx + 4, -hx / 3, hx / 3, hx - 4):
        p.box(x - 0.16, x + 0.16, rear_wall - 0.17, rear_wall + 0.17,
              2.25, 9.7, "FRAME")
    # One hanging lantern gives the workshop a warm focal point after import.
    p.box(-0.05, 0.05, -0.05, 0.05, 8.9, 10.0, "IRON")
    p.box(-0.65, 0.65, -0.65, 0.65, 7.95, 8.18, "FRAME")
    p.box(-0.42, 0.42, -0.42, 0.42, 6.75, 7.96, "FIRE")
    p.box(-0.65, 0.65, -0.65, 0.65, 6.62, 6.85, "IRON")
    for x in (-0.56, 0.56):
        for y in (-0.56, 0.56):
            p.box(x - 0.08, x + 0.08, y - 0.08, y + 0.08,
                  6.8, 8.06, "IRON")

    if role == "Fletcher":
        bench(-hx + 1.7, -4.1, rear - 1.7, rear + 1.5)
        # Arrow shafts, fletching and a compact rack behind the table.
        for i in range(8):
            x = -hx + 2.2 + i * 0.85
            p.box(x - 0.08, x + 0.08, rear - 0.8, rear + 0.95,
                  2.73, 2.83, "FORGE_WOOD")
            p.box(x - 0.2, x + 0.2, rear + 0.75, rear + 1.1,
                  2.8, 2.92, "FEATHER")
        shelf_y = rear + door_side * 3.05
        p.box(-hx + 1.6, -4.0, shelf_y - 0.28, shelf_y + 0.28,
              5.6, 5.95, "FRAME")
        for i in range(6):
            x = -hx + 2.1 + 1.1 * i
            p.box(x - 0.09, x + 0.09, shelf_y - 0.18, shelf_y + 0.18,
                  3.0, 6.5, "TIMBER")
            p.cone(x, shelf_y, 6.5, 0.24, 6.9, 5, "FEATHER")
        # Two hung bow staves and a quiver make the room legible from the door.
        for x in (hx - 4.3, hx - 2.0):
            points = [(x, side_y - 0.5, 2.3), (x - 0.45, side_y - 0.5, 3.35),
                      (x - 0.6, side_y - 0.5, 4.4), (x - 0.45, side_y - 0.5, 5.5),
                      (x, side_y - 0.5, 6.5)]
            for a, b in zip(points, points[1:]):
                beam(a, b, 0.18, "FORGE_WOOD")
            beam(points[0], points[-1], 0.06, "PARCHMENT")
        p.frustum(hx - 3.1, side_y + 3.3, 0.78, 1.15, 3.15, 0.8, 8, "LEATHER")
        for i in range(5):
            x = hx - 3.7 + 0.28 * i
            p.box(x - 0.055, x + 0.055, side_y + 3.1, side_y + 3.3,
                  2.7, 5.3, "TIMBER")
            p.cone(x, side_y + 3.2, 5.2, 0.17, 5.55, 5, "FEATHER")
        # Finished bundles ready to carry, stored clear of the central aisle.
        for i in range(3):
            y = side_y - 2.5 + i * 1.7
            p.box(-hx + 1.1, -hx + 0.75, y - 0.55, y + 0.55,
                  0.9, 2.6, "LEATHER")
            p.box(-hx + 0.7, -hx + 0.45, y - 0.3, y + 0.3,
                  1.4, 1.65, "FRAME")
    elif role == "Alchemist":
        bench(-hx + 1.6, -4.1, rear - 1.6, rear + 1.7)
        # Glassware on the mixing table and on two wall shelves.
        bottles = ((-hx + 2.5, "GLASS_BLUE"), (-hx + 4.1, "GLASS_GREEN"),
                   (-hx + 5.8, "GLASS_RED"), (-hx + 7.2, "GLASS_BLUE"))
        for x, col in bottles:
            p.frustum(x, rear, 2.75, 0.48, 3.75, 0.28, 8, col)
            p.box(x - 0.15, x + 0.15, rear - 0.15, rear + 0.15,
                  3.75, 4.05, "PARCHMENT")
        for z in (4.7, 6.4):
            p.box(4.2, hx - 1.2, rear - 0.6, rear + 0.15, z, z + 0.28, "FRAME")
            for i, col in enumerate(("GLASS_GREEN", "GLASS_BLUE", "GLASS_RED")):
                x = 5.1 + i * 1.85
                p.frustum(x, rear - 0.2, z + 0.3, 0.35, z + 1.15, 0.22, 7, col)
        # Cauldron, hanging herbs, mortar and parchment are static room cues.
        p.frustum(6.6, side_y, 0.8, 1.6, 3.2, 2.05, 10, "IRON")
        p.frustum(6.6, side_y, 3.2, 2.05, 3.4, 1.9, 10, "GLASS_GREEN")
        for x in (hx - 3.5, hx - 2.2, hx - 1.0):
            p.box(x - 0.05, x + 0.05, side_y + 3.7, side_y + 4.0,
                  6.0, 8.4, "TIMBER")
            p.cone(x, side_y + 3.8, 5.1, 0.45, 6.3, 5, "HERB")
        p.frustum(-5.0, side_y + 4.0, 0.8, 0.9, 2.2, 0.9, 8, "STONE")
        p.box(-hx + 2.2, -hx + 4.6, rear - 0.6, rear + 0.6,
              2.71, 2.77, "PARCHMENT")
        # Low storage chest with an iron latch near the entrance.
        front_y = door_side * (hy - 4.0)
        p.box(hx - 5.0, hx - 1.5, front_y - 1.4, front_y + 1.4,
              0.84, 2.2, "FORGE_WOOD")
        p.box(hx - 5.15, hx - 1.35, front_y - 1.55, front_y + 1.55,
              2.15, 2.4, "FRAME")
        p.box(hx - 3.5, hx - 3.1, front_y + door_side * 1.55 - 0.08,
              front_y + door_side * 1.55 + 0.08, 1.35, 1.8, "IRON")
    elif role == "Carpenter":
        bench(-hx + 1.8, -3.9, rear - 1.8, rear + 1.8)
        # Vice, half-cut board and saw blade on the bench.
        p.box(-hx + 3.5, -4.4, rear - 0.42, rear + 0.42,
              2.72, 3.07, "FORGE_WOOD")
        for x in (-hx + 2.7, -hx + 1.9):
            p.box(x - 0.16, x + 0.16, rear - 0.6, rear + 0.6,
                  2.74, 3.7, "IRON")
        p.profile([(-hx + 4.4, 3.2), (-hx + 7.6, 3.55),
                   (-hx + 7.1, 3.9), (-hx + 4.2, 3.55)],
                  rear + 0.4, rear + 0.52, "IRON")
        # Boards and round timber sorted on trestles down the right wall.
        for y in (side_y - 3.4, side_y, side_y + 3.4):
            for z in (1.3, 2.5):
                p.along_x(hx - 4.0, y, z, 5.8, 0.52, 0.52, 6, "TIMBER")
        for i in range(4):
            x = hx - 6.6 + i * 1.0
            p.box(x - 0.37, x + 0.37, rear - 2.4, rear + 2.7,
                  0.82, 1.16, "FORGE_WOOD")
        # Mallets and square on the back wall.
        p.box(4.1, hx - 1.4, rear - 0.3, rear + 0.3, 5.7, 6.0, "FRAME")
        for x in (5.2, 7.2, 9.2):
            p.box(x - 0.1, x + 0.1, rear - 0.4, rear + 0.4,
                  3.65, 5.7, "TIMBER")
            p.box(x - 0.42, x + 0.42, rear - 0.4, rear + 0.4,
                  3.6, 4.05, "IRON")
        # A handcart-sized material stack inside the approved footprint.
        for i in range(4):
            p.box(hx - 7.2, hx - 1.4,
                  side_y - 3.3 + i * 1.35, side_y - 2.7 + i * 1.35,
                  0.9 + i * 0.22, 1.3 + i * 0.22, "TIMBER")
    else:
        raise ValueError("No detail model for " + role)
    return p.finish(role + "_Detail" + suffix(state), mat)


def build_ballista(mat, state="intact"):
    """Fixed defensive crossbow, not a gun; muzzle is local +X."""
    p = Piece()
    p.box(-3.2, 3.2, -1.8, 1.8, 0, 0.6, "TIMBER")
    if state == "rubble":
        p.rubble(-3, 3, -2, 2, 8, 0.9, 0.5, seed=301, cols=("TIMBER", "IRON"))
        return p.finish("Ballista_Rubble", mat)
    p.frustum(0, 0, 0.6, 0.7, 2.1, 0.55, 8, "TIMBER")
    p.box(-2.4, 4.0, -0.45, 0.45, 2.0, 2.7, "TIMBER")
    p.box(3.2, 4.6, -0.8, 0.8, 2.0, 2.9, "IRON")
    for side in (-1, 1):
        m = Matrix.Translation((2.1, 0, 2.35)) @ Matrix.Rotation(side * 0.47, 4, "Z")
        p.box(-0.3, 0.3, min(0, side * 5.2), max(0, side * 5.2), -0.25, 0.25,
              "TIMBER", m)
    if state == "intact":
        p.box(0.6, 1.0, -5.2, 5.2, 2.2, 2.28, "IRON")
        p.along_x(0.8, 0, 2.38, 4.4, 0.12, 0.08, 6, "TIMBER")
    else:
        p.box(0.2, 0.6, -4.0, 1.0, 1.6, 1.7, "IRON")
    return p.finish("Ballista" + suffix(state), mat)


def build_tower_ladder(mat):
    """Visual access ladder with a short top bridge toward local +X; climb logic is in Studio."""
    p = Piece()
    top = TOWER_TOP - 4.2
    for y in (-1.1, 1.1):
        p.box(-0.2, 0.2, y - 0.15, y + 0.15, 0, top, "TIMBER")
    for k in range(1, int(top / 1.3)):
        z = k * 1.3
        p.box(-0.25, 0.25, -1.1, 1.1, z, z + 0.18, "TIMBER")
    p.box(0, 4.1, -1.5, 1.5, top - 0.25, top, "TIMBER")
    return p.finish("Tower_Ladder", mat)


def build_tunnel_exit(mat, width):
    """Surface portal only; the underground crawl geometry belongs to the terrain."""
    p = Piece()
    hw = width / 2
    for y in (-hw - 0.4, hw + 0.4):
        p.box(-hw - 0.8, hw + 0.8, y - 0.4, y + 0.4, 0, 1.2, "STONE_DARK")
    for x in (-hw - 0.4, hw + 0.4):
        p.box(x - 0.4, x + 0.4, -hw, hw, 0, 1.2, "STONE_DARK")
    return p.finish("Tunnel_Exit_Portal", mat)


# ------------------------------------------------------------------ cannons and siege tools (aim along +X)
def build_cannon(mat, state="intact"):
    p = Piece()
    if state == "rubble":
        p.along_x(-1.0, 0.6, 0.62, 4.6, 0.62, 0.46, 10, "IRON")                  # barrel down on the floor
        rng = random.Random(71)
        for k in range(6):
            m = Matrix.Translation((rng.uniform(-1.5, 1.5), rng.uniform(-1.6, 1.6), 0.2)) @ Matrix.Rotation(rng.uniform(0, math.pi), 4, "Z")
            p.box(-1.1, 1.1, -0.2, 0.2, -0.18, 0.18, "TIMBER", m)
        return p.finish("Cannon_Rubble", mat)
    cheek = [(-1.6, 0.5), (1.6, 0.5), (1.6, 1.7), (0.2, 1.7), (-0.8, 1.2), (-1.6, 1.2)]
    for s in (-1, 1):                                                           # carriage cheeks
        y0, y1 = sorted((s * 0.55, s * 0.85))
        if state == "damaged" and s > 0:
            p.box(-1.6, 0.4, y0, y1, 0.5, 1.2, "TIMBER")                         # one cheek split
        else:
            p.profile(cheek, y0, y1, "TIMBER")
    p.box(-1.2, 1.2, -0.55, 0.55, 0.5, 0.75, "TIMBER")                          # bed
    for x in (-1.0, 1.0):
        p.box(x - 0.15, x + 0.15, -1.25, 1.25, 0.35, 0.65, "TIMBER")            # axles
        for s in (-1, 1):
            if state == "damaged" and x > 0 and s > 0:
                continue                                                         # a wheel knocked off
            p.wheel(x, s * 1.1, 0.5, 0.5, 0.3, 8, "TIMBER")
    tilt = 0.09 if state == "intact" else -0.18
    p.along_x(-1.5, 0, 1.75, 4.5, 0.62, 0.46, 10, "IRON", tilt=tilt)            # barrel
    p.along_x(2.6 * math.cos(tilt) - 1.5 + 0.0, 0, 1.75 + 4.1 * math.sin(tilt), 0.45, 0.58, 0.58, 10, "IRON", tilt=tilt)   # muzzle ring
    p.along_x(-1.95, 0, 1.75, 0.45, 0.25, 0.25, 8, "IRON")                       # cascabel knob
    if state == "damaged":
        p.box(1.8, 2.4, 1.0, 1.4, 0.0, 0.3, "TIMBER")                            # the lost wheel on the ground
    return p.finish("Cannon" + suffix(state), mat)


def build_ram(mat):
    """A roofed ram on four wheels; the iron head points along +X."""
    p = Piece()
    L, W = 4.6, 2.4
    for s in (-1, 1):
        p.box(-L, L, s * W - 0.3, s * W + 0.3, 0.8, 1.4, "TIMBER")              # side beams
        for x in (-3.2, 3.2):
            p.wheel(x, s * (W + 0.5), 0.9, 0.9, 0.4, 8, "TIMBER")
        for x in (-L + 0.4, 0.0, L - 0.4):
            p.box(x - 0.25, x + 0.25, s * W - 0.25, s * W + 0.25, 1.4, 5.0, "TIMBER")   # posts
    for x in (-L + 0.4, L - 0.4):
        p.box(x - 0.25, x + 0.25, -W, W, 0.8, 1.2, "TIMBER")                    # cross beams
    p.gable(-L - 0.4, L + 0.4, -W - 0.8, W + 0.8, 5.0, 7.0, "TIMBER")           # plank roof
    p.along_x(-L - 0.6, 0, 3.0, 2 * L + 0.8, 0.5, 0.5, 8, "TIMBER")             # the log
    p.along_x(L + 0.2, 0, 3.0, 0.9, 0.6, 0.3, 8, "IRON")                        # iron head
    for x in (-2.0, 2.0):                                                       # chains it hangs from
        p.box(x - 0.08, x + 0.08, -0.08, 0.08, 3.4, 6.0, "IRON")
    return p.finish("Battering_Ram", mat)


def build_siege_cannon(mat):
    """Heavier than the defensive cannon: bigger bore, big wheels, a trail to steer it."""
    p = Piece()
    cheek = [(-2.6, 1.2), (2.4, 1.2), (2.4, 2.8), (0.4, 2.8), (-1.4, 2.0), (-2.6, 2.0)]
    for s in (-1, 1):
        y0, y1 = sorted((s * 0.75, s * 1.15))
        p.profile(cheek, y0, y1, "TIMBER")
        p.wheel(0.8, s * 1.7, 1.5, 1.5, 0.4, 12, "TIMBER")
        p.wheel(0.8, s * 1.95, 1.5, 0.35, 0.2, 6, "IRON")                       # hub
    p.box(0.55, 1.05, -1.9, 1.9, 1.3, 1.7, "TIMBER")                            # axle
    m = Matrix.Translation((-2.6, 0, 1.4)) @ Matrix.Rotation(0.32, 4, "Y")      # trail down to the ground behind
    p.box(-3.6, 0.0, -0.4, 0.4, -0.3, 0.3, "TIMBER", m)
    p.along_x(-2.2, 0, 2.9, 6.6, 1.0, 0.78, 12, "IRON", tilt=0.08)              # barrel
    p.along_x(3.9, 0, 3.4, 0.6, 0.95, 0.95, 12, "IRON", tilt=0.08)              # muzzle ring
    p.along_x(-2.75, 0, 2.9, 0.55, 0.4, 0.4, 8, "IRON")                          # cascabel
    return p.finish("Siege_Cannon", mat)


def build_scaffold(mat):
    """Timber scaffolding for one wall bay, standing against the outer face (-Y side)."""
    p = Piece()
    L = BAY / 2
    for x in (-L + 0.4, -L / 3, L / 3, L - 0.4):
        for y in (-WALL_T / 2 - 0.6, -WALL_T / 2 - 3.0):
            p.box(x - 0.2, x + 0.2, y - 0.2, y + 0.2, 0, 15.0, "TIMBER")        # poles
    for z in (4.0, 8.0, 12.0):
        for y in (-WALL_T / 2 - 0.6, -WALL_T / 2 - 3.0):
            p.box(-L, L, y - 0.15, y + 0.15, z - 0.15, z + 0.15, "TIMBER")      # ledgers
        p.box(-L + 0.2, L - 0.2, -WALL_T / 2 - 3.0, -WALL_T / 2 - 0.6, z + 0.15, z + 0.35, "TIMBER")   # plank deck
    for x0 in (-L + 0.4, L / 3):                                                # braces
        dx = (L - 0.4) - L / 3 if x0 > 0 else (-L / 3) - (-L + 0.4)
        length = math.hypot(dx, 8.0)
        m = Matrix.Translation((x0, -WALL_T / 2 - 3.25, 0.3)) @ Matrix.Rotation(-math.atan2(dx, 8.0), 4, "Y")
        p.box(-0.12, 0.12, -0.12, 0.12, 0, length, "TIMBER", m)
    return p.finish("Scaffold", mat)


def build_banner(mat):
    """Origin at the top centre of the bar; the cloth hangs down, front faces -Y."""
    p = Piece()
    p.box(-2.0, 2.0, -0.18, 0.18, -0.15, 0.25, "IRON")
    w, l = 1.6, 7.0
    p.profile([(-w, -l), (0.0, -l - 1.3), (w, -l), (w, -0.15), (-w, -0.15)], -0.06, 0.06, "CLOTH")
    p.profile(list(reversed([(0.0, -2.0), (0.85, -3.3), (0.0, -4.6), (-0.85, -3.3)])), -0.12, -0.06, "EMBLEM")
    return p.finish("Banner", mat)


# ------------------------------------------------------------------ materials and world
def castle_material():
    m = bpy.data.materials.get("Castle_Mat") or bpy.data.materials.new("Castle_Mat")
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
    return m


def banner_material():
    """Vertex colour x object colour: the same multiply Roblox does with MeshPart.Color."""
    m = bpy.data.materials.get("Banner_Mat") or bpy.data.materials.new("Banner_Mat")
    try:
        m.use_nodes = True
    except Exception:
        pass
    nt = m.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    vc = next((n for n in nt.nodes if n.type == "VERTEX_COLOR"), None) or nt.nodes.new("ShaderNodeVertexColor")
    vc.layer_name = "Col"
    info = next((n for n in nt.nodes if n.type == "OBJECT_INFO"), None) or nt.nodes.new("ShaderNodeObjectInfo")
    mix = next((n for n in nt.nodes if n.type == "VECT_MATH"), None) or nt.nodes.new("ShaderNodeVectorMath")
    mix.operation = "MULTIPLY"
    nt.links.new(vc.outputs[0], mix.inputs[0])
    nt.links.new(info.outputs["Color"], mix.inputs[1])
    nt.links.new(mix.outputs[0], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 1.0
    spec = bsdf.inputs.get("Specular IOR Level")
    if spec is not None:
        spec.default_value = 0.0
    return m


def preview_world():
    """Neutral daylight for judging colour: a soft grey-blue sky as the ambient fill, plus
    the Preview_Sun built in build(). The bundled HDRIs are warm (courtyard turned the stone
    pink, sunrise turned it orange), which made the sampled colours impossible to judge."""
    world = bpy.data.worlds.get("Castle_World") or bpy.data.worlds.new("Castle_World")
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
    fill = nt.nodes.new("ShaderNodeBackground")
    fill.inputs[0].default_value = (0.62, 0.66, 0.74, 1.0)
    fill.inputs[1].default_value = 0.32
    nt.links.new(cam.outputs["Is Camera Ray"], mix.inputs[0])
    nt.links.new(fill.outputs[0], mix.inputs[1])
    nt.links.new(sky.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], out.inputs[0])
    return world


def preview_world_hdri():
    """(Unused) lit by Blender's bundled studio HDRI; the camera sees a plain sky colour."""
    world = bpy.data.worlds.get("Castle_World") or bpy.data.worlds.new("Castle_World")
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
    folder = bpy.utils.system_resource("DATAFILES", path="studiolights/world")
    for name in ("courtyard.exr", "forest.exr", "sunrise.exr"):   # neutral daylight first, so colours read true
        f = os.path.join(folder or "", name)
        if os.path.exists(f):
            env = nt.nodes.new("ShaderNodeTexEnvironment")
            env.image = bpy.data.images.load(f, check_existing=True)
            nt.links.new(env.outputs[0], light.inputs[0])
            break
    nt.links.new(cam.outputs["Is Camera Ray"], mix.inputs[0])
    nt.links.new(light.outputs[0], mix.inputs[1])
    nt.links.new(sky.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], out.inputs[0])
    return world


# ------------------------------------------------------------------ assembly from layout.json
def place(coll, name, mesh, loc, rot_deg, color=None):
    o = bpy.data.objects.new(name, mesh)
    o["layout_id"] = name
    o.location = loc
    o.rotation_euler = Euler((0, 0, math.radians(rot_deg)))
    if color:
        o.color = (lin(color[0]), lin(color[1]), lin(color[2]), 1.0)
    coll.objects.link(o)
    return o


def room_shape(C):
    k = C["interior"]["keep"]
    r = k["stockpile_room"]
    kx = (k["min_x"] + k["max_x"]) / 2
    kz = (k["min_z"] + k["max_z"]) / 2
    return (r["min_x"] - kx, r["max_x"] - kx,
            -(r["max_z"] - kz), -(r["min_z"] - kz),
            r["door"]["x"] - kx, r["door"]["clear_width"] / 2)


def validate_layout(L):
    if L.get("meta", {}).get("version") != "2.1" or len(L["castles"]) != 2:
        raise ValueError("Castle builder requires approved layout.json v2.1 with two castles")
    A, B = L["castles"]
    for C in (A, B):
        if len(C["wall_sections"]) != 35 or len(C["towers"]) != 4:
            raise ValueError("Expected 35 wall sections and four towers per castle")
        if abs(C["ring_size"]["x"] - 9 * BAY) > 1e-4:
            raise ValueError("Wall bay width disagrees with approved ring")
        I = C["interior"]
        if len(I["specialists"]) != 4:
            raise ValueError("Four specialist buildings are required")
        k = I["keep"]
        if (k["max_x"] - k["min_x"], k["max_z"] - k["min_z"]) != (44, 44):
            raise ValueError("Keep mesh must be revised if its layout footprint changes")
        r = k["stockpile_room"]
        if not (k["min_x"] < r["min_x"] < r["max_x"] < k["max_x"]
                and k["min_z"] < r["min_z"] < r["max_z"] < k["max_z"]):
            raise ValueError("Stockpile room must be entirely within the Keep")
        if r["door"]["clear_width"] < 8 or k["front_door"]["clear_width"] < 10:
            raise ValueError("Keep doors are too narrow for the approved layout")
        if (k["front_door"]["x"] != (k["max_x"] if C["team"] == "A" else k["min_x"])
                or k["front_door"]["z"] != (k["min_z"] + k["max_z"]) / 2):
            raise ValueError("Keep front door moved; revise the Keep mesh")
        if r["door"]["z"] != r["min_z"]:
            raise ValueError("Stockpile door moved; revise the interior partition")
        if abs(I["ballista_mount"]["y"] - C["pad"]["y"] - (GATE_H + 1.4)) > 1e-4:
            raise ValueError("Ballista mount is not on the gatehouse deck")
        for s in I["specialists"]:
            if s["door"]["z"] not in (s["min_z"], s["max_z"]):
                raise ValueError("Specialist door moved off its front wall")
            if s["door"]["clear_width"] != 8:
                raise ValueError("Specialist door width changed; revise its mesh")
            if s["role"] == "Carpenter" and (s["ram_opening"]["clear_width"] != 12
                                             or s["ram_opening"]["x"] != (s["max_x"] if C["team"] == "A" else s["min_x"])):
                raise ValueError("Carpenter ram opening moved; revise its mesh")
    if A["center"]["x"] != -B["center"]["x"] or A["center"]["z"] != B["center"]["z"]:
        raise ValueError("Castles are not mirrored across x=0")
    for key in ("wall_sections", "towers"):
        for a, b in zip(A[key], B[key]):
            if abs(a["x"] + b["x"]) > 1e-4 or abs(a["z"] - b["z"]) > 1e-4:
                raise ValueError("Castle exterior is not mirrored: " + a["id"])
    for key in ("keep", "barracks"):
        a, b = A["interior"][key], B["interior"][key]
        if (a["min_x"] != -b["max_x"] or a["max_x"] != -b["min_x"]
                or a["min_z"] != b["min_z"] or a["max_z"] != b["max_z"]):
            raise ValueError("Interior footprint is not mirrored: " + key)
    for a, b in zip(A["interior"]["specialists"], B["interior"]["specialists"]):
        if (a["role"] != b["role"] or a["min_x"] != -b["max_x"]
                or a["max_x"] != -b["min_x"] or a["min_z"] != b["min_z"]
                or a["max_z"] != b["max_z"]):
            raise ValueError("Specialist footprint is not mirrored: " + a["role"])
    fa = A["interior"]["surfaces"]["blacksmith_forecourt"]
    fb = B["interior"]["surfaces"]["blacksmith_forecourt"]
    if (fa["max_x"] - fa["min_x"] != 38 or fa["max_z"] - fa["min_z"] != 19
            or fa["min_x"] != -fb["max_x"] or fa["max_x"] != -fb["min_x"]
            or fa["min_z"] != fb["min_z"] or fa["max_z"] != fb["max_z"]):
        raise ValueError("Blacksmith forecourts must be approved 38 x 19 mirrored footprints")
    return A, B


def build_meshes(mat, bmat, C, tunnel_width):
    meshes = {}
    role_lookup = {s["role"]: s for s in C["interior"]["specialists"]}
    for state in STATES:
        for fn, name in ((build_wall, "Wall_Segment"), (build_door, "Gate_Door"),
                         (build_barracks, "Barracks"), (build_ballista, "Ballista")):
            me = fn(mat, state)
            meshes[name + suffix(state)] = me
        me = build_tower(mat, state)
        meshes["Wall_Corner_Tower" + suffix(state)] = me
        me = build_keep(mat, room_shape(C), state)
        meshes["Keep" + suffix(state)] = me
        for role in ("Blacksmith", "Alchemist", "Fletcher", "Carpenter"):
            s = role_lookup[role]
            hx, hy = (s["max_x"] - s["min_x"]) / 2, (s["max_z"] - s["min_z"]) / 2
            mid_z = (s["min_z"] + s["max_z"]) / 2
            door_side = 1 if s["door"]["z"] < mid_z else -1
            ram_side = 1 if "ram_opening" in s and s["ram_opening"]["x"] == s["max_x"] else 0
            name = "Blacksmith_Forge" if role == "Blacksmith" else role
            me = build_specialist(mat, name, hx, hy, door_side, ram_side, state)
            meshes[name + suffix(state)] = me
            roof = build_specialist_roof(mat, name, hx, hy, state)
            meshes[name + "_Roof" + suffix(state)] = roof
            if role != "Blacksmith":
                meshes[name + "_Detail" + suffix(state)] = build_specialist_detail(
                    mat, name, hx, hy, door_side, state)
        meshes["Blacksmith_Detail" + suffix(state)] = build_blacksmith_detail(mat, state)
        # From the approved south-facing approach, the working forge reads on
        # the left and the enclosed shop on the right, as in the user reference.
        for name in ("Blacksmith_Forge", "Blacksmith_Forge_Roof", "Blacksmith_Detail"):
            me = meshes[name + suffix(state)]
            me.transform(Matrix.Scale(-1.0, 4, Vector((1, 0, 0))))
            me.flip_normals()
    for fn, name in ((build_gate, "Gate"), (build_stockpile, "Stockpile"),
                     (build_ram, "Battering_Ram"), (build_scaffold, "Scaffold"),
                     (build_tower_ladder, "Tower_Ladder")):
        me = fn(mat)
        meshes[name] = me
    meshes["Tunnel_Exit_Portal"] = build_tunnel_exit(mat, tunnel_width)
    meshes["Blacksmith_Forecourt"] = build_blacksmith_forecourt(mat)
    meshes["Banner"] = build_banner(bmat)
    return meshes


def build():
    with open(LAYOUT, encoding="utf-8") as f:
        L = json.load(f)
    C, C_b = validate_layout(L)
    tunnel = next(t for t in L["tunnels"] if t["team"] == C["team"])
    old = bpy.data.scenes.get("Castle")
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
    scene = bpy.data.scenes.new("Castle")
    try:
        scene.view_settings.view_transform = "Standard"
    except TypeError:
        pass
    scene.world = preview_world()
    colls = {}
    for name in ("Castle_Kit", "Castle_Assembly", "Castle_Assembly_B",
                 "Castle_Preview", "Castle_Layout_Markers"):
        c = bpy.data.collections.new(name); scene.collection.children.link(c); colls[name] = c

    cx, cz, gy = C["center"]["x"], C["center"]["z"], C["pad"]["y"]
    loc = lambda o, up=0.0: (o["x"] - cx, -(o["z"] - cz), up)
    face_rot = lambda fx, fz: math.degrees(math.atan2(fx, fz))           # local -Y outer face -> Roblox facing (fx, fz)
    plus_x_rot = lambda fx, fz: math.degrees(math.atan2(-fz, fx))        # local +X -> Roblox facing (fx, fz)
    rect_c = lambda r: ((r["min_x"] + r["max_x"]) / 2 - cx, -((r["min_z"] + r["max_z"]) / 2 - cz), 0.0)

    mat, bmat = castle_material(), banner_material()
    meshes = build_meshes(mat, bmat, C, tunnel["width"])

    # the kit: one of everything, in rows behind the castle (hidden in castle views)
    x, y = -110.0, 120.0
    for name, me in meshes.items():
        place(colls["Castle_Kit"], name, me, (x, y, 0), 0, TEAM_A if name == "Banner" else None)
        x += 38.0
        if x > 110:
            x, y = -110.0, y + 45.0

    A = colls["Castle_Assembly"]
    for s in C["wall_sections"]:
        place(A, s["id"], meshes["Wall_Segment"], loc(s), face_rot(s["facing"]["x"], s["facing"]["z"]))
    for t in C["towers"]:
        lx, ly, _ = loc(t)
        rot = math.degrees(math.atan2(ly, lx)) - 225.0     # windows (local 225 deg) face outward
        place(A, t["id"], meshes["Wall_Corner_Tower"], loc(t), rot)
    g, fg = C["gate"], C["gate_facing"]
    grot = face_rot(fg["x"], fg["z"])
    gl = loc(g)
    gate_line = (gl[0] - fg["x"] * (WALL_T / 2), gl[1] + fg["z"] * (WALL_T / 2), 0.0)   # gate stands on the wall's centre line
    place(A, g["id"], meshes["Gate"], gate_line, grot)
    place(A, g["door_id"], meshes["Gate_Door"], (gate_line[0] + fg["x"] * 1.5, gate_line[1] - fg["z"] * 1.5, 0.0), grot)
    for s, tag in ((-1, "N"), (1, "S")):
        bx = gate_line[0] + fg["x"] * (GATE_D + 0.15)
        place(A, "%s_Banner_Gate%s" % (C["team"], tag), meshes["Banner"], (bx, gate_line[1] - s * 8.4, GATE_H - 1.8), grot, TEAM_A)
    I = C["interior"]
    k = I["keep"]
    place(A, k["id"], meshes["Keep"], rect_c(k), 0)
    r = k["stockpile_room"]
    stock_loc = rect_c(r)
    place(A, C["team"] + "_Stockpile_Contents", meshes["Stockpile"],
          (stock_loc[0], stock_loc[1], 1.2), 0)
    b = I["barracks"]
    place(A, b["id"], meshes["Barracks"], rect_c(b), 0)
    for s in I["specialists"]:
        name = "Blacksmith_Forge" if s["role"] == "Blacksmith" else s["role"]
        place(A, s["id"], meshes[name], rect_c(s), 0)
        place(A, s["id"] + "_Roof", meshes[name + "_Roof"], rect_c(s), 0)
        if s["role"] == "Blacksmith":
            place(A, s["id"] + "_Detail", meshes["Blacksmith_Detail"], rect_c(s), 0)
        else:
            place(A, s["id"] + "_Detail", meshes[name + "_Detail"], rect_c(s), 0)
    court = I["surfaces"]["blacksmith_forecourt"]
    place(A, court["id"], meshes["Blacksmith_Forecourt"], rect_c(court), 0)
    c = I["ballista_mount"]
    place(A, c["id"], meshes["Ballista"], loc(c, c["y"] - gy),
          plus_x_rot(c["aim"]["x"], c["aim"]["z"]))
    tower_by_suffix = {t["id"].split("_")[-1]: t for t in C["towers"]}
    for marker in I["tower_access"]:
        t = tower_by_suffix[marker["id"].split("_")[-1]]
        mx, my, _ = loc(marker)
        tx, ty, _ = loc(t)
        direction = math.degrees(math.atan2(ty - my, tx - mx))
        place(A, marker["id"], meshes["Tower_Ladder"], loc(marker), direction)
    place(A, C["tunnel_exit"]["id"], meshes["Tunnel_Exit_Portal"], loc(C["tunnel_exit"]), 0)

    # Mirror geometry with positive object scale so normals remain usable for a
    # future assembled FBX, including the asymmetric room and carpenter opening.
    B = colls["Castle_Assembly_B"]
    mirror_axis = -cx
    mirrored_meshes = {}
    for original in A.objects:
        name = original["layout_id"].replace(C["team"] + "_", C_b["team"] + "_", 1)
        source = original.data
        if source not in mirrored_meshes:
            reflected = source.copy()
            reflected.name = source.name + "_Mirror"
            reflected.transform(Matrix.Scale(-1.0, 4, Vector((1, 0, 0))))
            reflected.flip_normals()
            mirrored_meshes[source] = reflected
        duplicate = bpy.data.objects.new(name, mirrored_meshes[source])
        duplicate["layout_id"] = name
        duplicate.location = (2 * mirror_axis - original.location.x,
                              original.location.y, original.location.z)
        duplicate.rotation_euler = Euler((0, 0, -original.rotation_euler.z))
        duplicate.color = original.color[:]
        if original.data == meshes["Banner"]:
            duplicate.color = (lin(TEAM_B[0]), lin(TEAM_B[1]), lin(TEAM_B[2]), 1.0)
        B.objects.link(duplicate)

    # Preview only: ground, a 5-stud avatar, and a completed ram on its layout pad.
    P = colls["Castle_Preview"]
    sun_data = bpy.data.lights.get("Preview_Sun") or bpy.data.lights.new("Preview_Sun", "SUN")
    sun_data.energy = 3.2
    sun_data.color = (1.0, 0.98, 0.95)
    sun_data.angle = math.radians(2.5)
    sun = bpy.data.objects.new("Preview_Sun", sun_data)
    # light from the gate side (+x) and a little south, high: castle-1 is lit from the front
    sun.rotation_euler = Vector((-0.8, 0.45, -1.0)).normalized().to_track_quat("-Z", "Y").to_euler()
    P.objects.link(sun)
    gp = Piece()
    gp.box(-130, 690, -110, 110, -0.5, 0.0, "STONE_DARK")
    gm = gp.finish("Preview_Ground", mat)
    gm.color_attributes["Col"].data.foreach_set("color_srgb", [x for _ in range(len(gm.loops)) for x in (124 / 255, 146 / 255, 82 / 255, 1.0)])
    place(P, "Preview_Ground", gm, (0, 0, 0), 0)
    d = Piece()
    for s in (-1, 1):
        d.box(min(s * 0.05, s * 0.95), max(s * 0.05, s * 0.95), -0.5, 0.5, 0, 2.0, "TIMBER")
        d.box(min(s * 1.05, s * 1.95), max(s * 1.05, s * 1.95), -0.5, 0.5, 2.1, 4.0, "TIMBER")
    d.box(-1.0, 1.0, -0.5, 0.5, 2.0, 4.0, "TIMBER")
    d.box(-0.6, 0.6, -0.6, 0.6, 4.0, 5.0, "TIMBER")
    place(P, "Dummy_5stud", d.finish("Dummy_5stud", mat), (gate_line[0] + 16, 7, 0), 90.0)
    place(P, "Preview_Ram", meshes["Battering_Ram"], rect_c(I["clear_areas"]["ram_assembly_pad"]), 0)

    # Verification overlay: points are raised only to stay visible above roofs in
    # top view. Their horizontal coordinates come directly from layout.json.
    M = colls["Castle_Layout_Markers"]
    markers = [g, k["front_door"], r["door"], r["interaction"], b["door"],
               C["tunnel_exit"], I["ballista_mount"]]
    markers += [s["door"] for s in I["specialists"]]
    markers += I["tower_access"]
    ram_area = I["clear_areas"]["ram_assembly_pad"]
    markers.append({"id": ram_area["id"], "x": (ram_area["min_x"] + ram_area["max_x"]) / 2,
                    "z": (ram_area["min_z"] + ram_area["max_z"]) / 2})
    labels = {g["id"]: "Gate", k["front_door"]["id"]: "Keep door",
              r["interaction"]["id"]: "Stockpile", C["tunnel_exit"]["id"]: "Tunnel",
              I["ballista_mount"]["id"]: "Ballista", ram_area["id"]: "Ram pad"}
    for point in markers:
        marker = bpy.data.objects.new("Marker_" + labels.get(point["id"], point["id"]), None)
        marker.location = loc(point, 68)
        marker.empty_display_size = 3.0
        marker.show_name = point["id"] in labels
        marker["layout_id"] = point["id"]
        M.objects.link(marker)
    M.hide_viewport = True

    scene.view_layers[0].update()
    stats = {}
    for name, me in meshes.items():
        me.calc_loop_triangles()
        stats[name] = len(me.loop_triangles)
    return dict(scene=scene, stats=stats, meshes=meshes, L=L, C=C)


# ------------------------------------------------------------------ export
def export_kit_fbx(scene, path):
    """Every kit piece as its own mesh, for Roblox's 3D Importer.
    Same axis settings as assets/map/map.fbx on purpose. The map came into Studio turned
    180 degrees about the vertical; whatever the importer does, it does the same to both
    files, so the one correction already applied to the map (rotate 180 about Y) also
    applies here. Changing the axes for one file only would make them disagree."""
    view_layer = scene.view_layers[0]
    objs = list(bpy.data.collections["Castle_Kit"].objects)
    selected = [o for o in view_layer.objects if o.select_get(view_layer=view_layer)]
    active = view_layer.objects.active
    win = bpy.context.window
    prev_scene = win.scene
    try:
        win.scene = scene
        lc = view_layer.layer_collection.children.get("Castle_Kit")
        hidden = lc.hide_viewport if lc else False
        if lc:
            lc.hide_viewport = False
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
        if lc:
            lc.hide_viewport = hidden
        win.scene = prev_scene
    return path, len(objs)


# ------------------------------------------------------------------ views
def _v3d():
    for win in bpy.context.window_manager.windows:
        for area in win.screen.areas:
            if area.type == "VIEW_3D":
                return win, area, area.spaces.active


def show(scene, kit_visible=False, assembly_visible=True, markers_visible=False):
    win, area, sp = _v3d()
    win.scene = scene
    lcs = scene.view_layers[0].layer_collection.children
    if lcs.get("Castle_Kit"):
        lcs["Castle_Kit"].hide_viewport = not kit_visible
    if lcs.get("Castle_Assembly"):
        lcs["Castle_Assembly"].hide_viewport = not assembly_visible
    if lcs.get("Castle_Assembly_B"):
        lcs["Castle_Assembly_B"].hide_viewport = not assembly_visible
    if lcs.get("Castle_Preview"):
        lcs["Castle_Preview"].hide_viewport = not assembly_visible
    if lcs.get("Castle_Layout_Markers"):
        lcs["Castle_Layout_Markers"].hide_viewport = not markers_visible
    bpy.data.collections["Castle_Layout_Markers"].hide_viewport = not markers_visible
    sp.shading.type = "RENDERED"
    sp.shading.show_object_outline = False
    sp.clip_start, sp.clip_end = 0.1, 4000
    sp.overlay.show_overlays = markers_visible
    sp.overlay.show_floor = False
    sp.overlay.show_cursor = False
    sp.overlay.show_axis_x = sp.overlay.show_axis_y = False


def orbit(yaw, pitch, dist, target=(0, 0, 10), ortho=False, lens=50):
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


bpy.app.driver_namespace["castle"] = dict(build=build, show=show, orbit=orbit, look=look, export_kit_fbx=export_kit_fbx)
