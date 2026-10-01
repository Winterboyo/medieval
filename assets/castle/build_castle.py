"""Siege castle kit, after references/castle-1.jpg (towers and roofs also castle-2.jpg),
built in its own Blender scene ("Castle") and assembled from layout.json (v1.1).

Run inside Blender with __file__ set, then bpy.app.driver_namespace["castle"]["build"]().

Pieces (CLAUDE.md §4, §11), each its own named object in Castle_Kit:
  Wall_Segment            one 20.4-stud bay: crenellated parapet on corbels
  Wall_Corner_Tower       rear tower: two-stage drum, corbels, slate cone
  Wall_Corner_Tower_Gun   front tower: same body, open crenellated gun platform on top
  Gate, Gate_Door         gatehouse with arched opening and corner turrets; timber door
  Keep                    the king's keep: hollow, arched door, corner turrets
  King_Storage            chests, crates, barrels and sacks: the team's stockpile
  Barracks                hollow stone hall with a slate roof; the team spawns inside
  Workshop                open-fronted forge: hearth and chimney, anvil, bench, timber
  Cannon                  defensive gun on a timber carriage, aimed along +X
  Battering_Ram           roofed ram on wheels, iron head toward +X
  Siege_Cannon            big gun on a heavy wheeled carriage, aimed along +X
  Scaffold                timber scaffolding for one wall bay, shown during repair
  Banner                  hanging banner; neutral cloth tinted by Roblox's part Color
Damage states (same footprint, swap in place): <Piece>_Damaged and <Piece>_Rubble for
Wall_Segment, Wall_Corner_Tower, Wall_Corner_Tower_Gun, Gate_Door, Cannon, Workshop,
Barracks.

Assembly (Castle_Assembly) is team A's castle from layout.json: its 19 wall sections,
4 towers (front two are gun platforms), gate, keep with the king's storage, barracks,
workshop and 4 cannons, in castle-local Blender coordinates (gate toward +X).

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
    "SLATE": (106, 111, 117),       # big tower roof
    "TIMBER": (159, 137, 114),      # drawbridge planks
    "IRON": (61, 61, 61),           # the dark of the gate opening: windows, bands, guns
    "CLOTH": (178, 178, 178),       # banner cloth, neutral so the team colour tints it
    "EMBLEM": (255, 255, 255),      # banner emblem: tints to the full team colour
}
TEAM_A = (184, 65, 58)              # layout.json teams[0].banner_color_placeholder, preview only
STATES = ("intact", "damaged", "rubble")

BAY = 20.4                          # wall bay = the code's WALL_BLOCK length
WALL_T = 4.0                        # wall thickness
WALL_H = 11.0                       # walkway height (the code's WALL_BLOCK height)
TOWER_R = 7.0
TOWER_SIDES = 16
TOWER_TOP = 25.0                    # top of the shaft, under the battlement band (wall top is 14.4)
GATE_HW, GATE_D, GATE_H = 12.0, 5.0, 20.0          # gatehouse half width, half depth, roof walk
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
        for x, z, w, h in ((-6.5, 3.6, 3.0, 1.5), (1.6, 7.2, 3.6, 1.3), (7.2, 2.4, 2.4, 1.2)):   # offset stones
            if state == "intact" or abs(x) > 6:
                p.box(x - w / 2, x + w / 2, -t - 0.3, -t, z, z + h, "STONE")
        for k in keep_bays:
            x = -L + period * (k + 0.5)
            p.box(x - 0.5, x + 0.5, -t - 0.75, -t, WALL_H - 1.4, WALL_H, "STONE_DARK")            # corbel
            p.box(x - period / 2, x + period / 2, -t - 0.8, -t + 1.2, WALL_H, WALL_H + 1.6, "STONE")   # parapet bay
            p.box(x - 1.1, x + 1.1, -t - 0.8, -t + 1.2, WALL_H + 1.6, WALL_H + 3.4, "STONE")         # merlon
            p.box(x - period / 2, x + period / 2, t - 0.6, t, WALL_H, WALL_H + 0.7, "STONE")         # inner lip
    if state == "damaged":
        p.rubble(-6.0, 6.0, -6.5, -2.6, 10, 1.4, 1.0, seed=7)                     # fallen stone at the foot
    return p.finish("Wall_Segment" + suffix(state), mat)


def build_tower(mat, state="intact", gun=False):
    """Centred on its own origin. Windows face local (-1, -1), i.e. outward at a corner.
    Gun towers end in an open crenellated platform (floor at TOWER_TOP + 2.6) instead of
    a roof: castle-1 has both kinds, and the front towers carry cannons."""
    p, n, r = Piece(), TOWER_SIDES, TOWER_R
    top = TOWER_TOP
    drum0, ru = top - 7.0, r + 0.6
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
    p.frustum(0, 0, 2.6, r, drum0, r - 0.2, n, "STONE")                         # lower body
    p.frustum(0, 0, 9.0, r + 0.35, 9.8, r + 0.3, n, "STONE_DARK")               # band
    p.frustum(0, 0, drum0, ru, top, ru, n, "STONE")                             # upper drum

    def corbels(radius, z0, z1, every=1):
        for k in range(0, n, every):
            a = 2 * math.pi * (k + 0.5) / n
            m = Matrix.Translation((math.cos(a) * (radius + 0.1), math.sin(a) * (radius + 0.1), 0)) @ Matrix.Rotation(a, 4, "Z")
            p.box(-0.6, 0.9, -0.45, 0.45, z0, z1, "STONE_DARK", m)
    corbels(r - 0.2, drum0 - 1.4, drum0)
    corbels(ru, top - 1.5, top, every=1 if state == "intact" else 2)
    # damaged: a bite out of the band facing outward (windows side, local 200-250 deg)
    GAP = {12, 13, 14} if state == "damaged" else set()
    if not GAP:
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
        eave = floor
        p.frustum(0, 0, eave, ru + 2.7, eave + 1.0, ru + 1.9, n, "SLATE")       # flared eave (witch's-hat brim)
        if state == "intact":
            p.cone(0, 0, eave + 1.0, ru + 1.9, eave + 16.0, n, "SLATE")         # tall cone
            p.cone(0, 0, eave + 15.9, 0.35, eave + 18.5, 6, "IRON")             # spike
        else:
            p.frustum(0, 0, eave + 1.0, ru + 1.9, eave + 6.5, ru * 0.45, n, "SLATE")   # the cone's stub, top shot away
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
    segs = 9                                                                    # stone frame round the arch
    for k in range(segs):
        a0, a1 = math.pi - math.pi * k / segs, math.pi - math.pi * (k + 1) / segs
        r0, r1 = ARCH_HW, ARCH_HW + 1.5
        q = [(math.cos(a0) * r0, ARCH_SPRING + math.sin(a0) * r0), (math.cos(a0) * r1, ARCH_SPRING + math.sin(a0) * r1),
             (math.cos(a1) * r1, ARCH_SPRING + math.sin(a1) * r1), (math.cos(a1) * r0, ARCH_SPRING + math.sin(a1) * r0)]
        p.profile(list(reversed(q)), -GATE_D - 0.5, -GATE_D, "STONE_DARK")
    for s in (-1, 1):                                                           # jamb stones
        x0, x1 = sorted((s * ARCH_HW, s * (ARCH_HW + 1.5)))
        p.box(x0, x1, -GATE_D - 0.5, -GATE_D, 1.2, ARCH_SPRING, "STONE_DARK")
    for x in (-10, -6, -2, 2, 6, 10):                                           # corbels
        p.box(x - 0.55, x + 0.55, -GATE_D - 0.8, -GATE_D, GATE_H - 1.6, GATE_H, "STONE_DARK")
    p.box(-GATE_HW - 0.8, GATE_HW + 0.8, -GATE_D - 0.8, GATE_D + 0.8, GATE_H, GATE_H + 1.4, "STONE")   # roof walk (cannons stand here)
    for x in (-10.4, -6.25, -2.1, 2.1, 6.25, 10.4):                             # merlons, outer and inner edge
        for y0 in (-GATE_D - 0.8, GATE_D - 0.4):
            p.box(x - 1.1, x + 1.1, y0, y0 + 1.2, GATE_H + 1.4, GATE_H + 3.2, "STONE")
    for s in (-1, 1):                                                           # corner turrets (bartizans)
        cx, cy = s * (GATE_HW - 0.6), -GATE_D + 0.4
        p.cone(cx, cy, GATE_H - 1.4, 2.4, GATE_H - 4.8, 8, "STONE_DARK", rot=math.pi / 8)
        p.frustum(cx, cy, GATE_H - 1.4, 2.4, GATE_H + 4.2, 2.3, 8, "STONE", rot=math.pi / 8)
        p.frustum(cx, cy, GATE_H + 4.2, 3.0, GATE_H + 4.6, 2.9, 8, "SLATE", rot=math.pi / 8)
        p.cone(cx, cy, GATE_H + 4.6, 2.9, GATE_H + 11.0, 8, "SLATE", rot=math.pi / 8)
        p.cone(cx, cy, GATE_H + 10.9, 0.2, GATE_H + 12.4, 4, "IRON")
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
KEEP_HX, KEEP_HY, KEEP_H = 12.0, 14.0, 20.0       # half depth (door on +X), half width, wall height
KEEP_DOOR_HW, KEEP_DOOR_SPRING = 3.0, 6.2


def build_keep(mat):
    """Hollow, so raiders can walk in to the king's storage. Door on +X."""
    p = Piece()
    hx, hy, h, wt = KEEP_HX, KEEP_HY, KEEP_H, 1.6
    p.box(-hx - 0.5, hx + 0.5, -hy - 0.5, hy + 0.5, 0, 1.2, "STONE_DARK")       # plinth = floor
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
    p.box(-hx + wt, hx - wt, -hy + wt, hy - wt, h - 1.0, h - 0.4, "STONE_DARK")    # ceiling
    p.box(-hx - 0.7, hx + 0.7, -hy - 0.7, hy + 0.7, h - 0.4, h + 1.0, "STONE")   # roof walk, overhanging
    for k in range(int(2 * hx // 4)):                                           # corbels and merlons, long sides
        x = -hx + 2 + k * 4
        for s in (-1, 1):
            y0, y1 = sorted((s * hy, s * (hy + 0.7)))
            p.box(x - 0.5, x + 0.5, y0, y1, h - 1.8, h - 0.4, "STONE_DARK")
            y0, y1 = sorted((s * (hy + 0.7), s * (hy - 0.5)))
            p.box(x - 1.0, x + 1.0, y0, y1, h + 1.0, h + 2.6, "STONE")
    for k in range(int(2 * hy // 4)):                                           # merlons, short sides
        y = -hy + 2 + k * 4
        for s in (-1, 1):
            x0, x1 = sorted((s * (hx + 0.7), s * (hx - 0.5)))
            p.box(x0, x1, y - 1.0, y + 1.0, h + 1.0, h + 2.6, "STONE")
    for sx in (-1, 1):                                                          # corner turrets with slate cones
        for sy in (-1, 1):
            cx, cy = sx * hx, sy * hy
            p.frustum(cx, cy, 0, 3.0, 1.2, 2.7, 12, "STONE_DARK")
            p.frustum(cx, cy, 1.2, 2.7, h + 5.0, 2.6, 12, "STONE")
            p.frustum(cx, cy, h + 5.0, 3.4, h + 5.6, 3.2, 12, "SLATE")
            p.cone(cx, cy, h + 5.6, 3.2, h + 13.0, 12, "SLATE")
            p.cone(cx, cy, h + 12.9, 0.25, h + 14.6, 4, "IRON")
    for x in (-6.0, 0.0, 6.0):                                                  # window slits, long sides
        for s in (-1, 1):
            y0, y1 = sorted((s * hy, s * (hy + 0.12)))
            p.box(x - 0.45, x + 0.45, y0, y1, 11.0, 14.0, "IRON")
    for y in (-8.0, 8.0):                                                       # and over the door
        p.box(hx, hx + 0.12, y - 0.45, y + 0.45, 11.0, 14.0, "IRON")
    return p.finish("Keep", mat)


def build_storage(mat):
    """The king's storage: what the team has gathered. Centred on its own origin; fits 14 x 20."""
    p = Piece()
    for x, y in ((-5.0, -7.5), (-5.0, -3.5), (-5.0, 0.5)):                       # chests along the back
        p.box(x - 1.2, x + 1.2, y - 1.5, y + 1.5, 0, 1.6, "TIMBER")
        p.box(x - 1.3, x + 1.3, y - 1.6, y + 1.6, 1.6, 2.0, "TIMBER")
        for yy in (y - 0.9, y + 0.9):
            p.box(x - 1.3, x + 1.3, yy - 0.15, yy + 0.15, 0, 2.05, "IRON")
    for x, y, s, z in ((-1.0, 6.0, 1.8, 0), (1.0, 6.2, 1.6, 0), (-0.1, 6.1, 1.4, 1.8), (2.0, 8.2, 1.6, 0)):   # crates
        p.box(x - s / 2, x + s / 2, y - s / 2, y + s / 2, z, z + s, "TIMBER")
    for x, y in ((3.5, -6.5), (5.2, -6.0), (4.3, -4.4)):                         # barrels with hoops
        p.frustum(x, y, 0, 0.75, 1.0, 0.85, 8, "TIMBER")
        p.frustum(x, y, 1.0, 0.85, 2.0, 0.75, 8, "TIMBER")
        p.frustum(x, y, 0.45, 0.8, 0.6, 0.82, 8, "IRON")
        p.frustum(x, y, 1.4, 0.82, 1.55, 0.8, 8, "IRON")
    for x, y in ((3.6, 2.0), (4.8, 2.6), (4.2, 3.6), (5.4, 1.3)):                # grain sacks
        p.frustum(x, y, 0, 0.7, 0.8, 0.6, 6, "STONE")
        p.cone(x, y, 0.8, 0.6, 1.25, 6, "STONE")
    return p.finish("King_Storage", mat)


# ------------------------------------------------------------------ barracks and workshop
def build_barracks(mat, state="intact"):
    """Hollow hall; door on -Y. Local X +-16, Y +-7 (the layout's 32 x 14)."""
    p = Piece()
    hx, hy, h, wt = 16.0, 7.0, 8.0, 1.2
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
    door = [(-2.5, 0.8)] + [(x, z + 0.8) for x, z in arch_outline(2.5, 4.2, 6)] + [(2.5, 0.8)]   # 5 wide, 7.5 to the crown
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
        p.gable(-hx - 0.8, hx + 0.8, -hy - 1.2, hy + 1.2, h, h + 5.0, "SLATE")
    else:
        p.gable(-hx - 0.8, 2.0, -hy - 1.2, hy + 1.2, h, h + 5.0, "SLATE")          # the west half of the roof still on
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
    """Lit by Blender's bundled studio HDRI; the camera sees a plain sky colour."""
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
    o.location = loc
    o.rotation_euler = Euler((0, 0, math.radians(rot_deg)))
    if color:
        o.color = (lin(color[0]), lin(color[1]), lin(color[2]), 1.0)
    coll.objects.link(o)
    return o


def build_meshes(mat, bmat):
    meshes = {}
    for state in STATES:
        for fn, name in ((build_wall, "Wall_Segment"), (build_door, "Gate_Door"), (build_cannon, "Cannon"),
                         (build_workshop, "Workshop"), (build_barracks, "Barracks")):
            me = fn(mat, state)
            meshes[me.name] = me
        for gun in (False, True):
            me = build_tower(mat, state, gun)
            meshes[me.name] = me
    for fn in (build_gate, build_keep, build_storage, build_ram, build_siege_cannon, build_scaffold):
        me = fn(mat)
        meshes[me.name] = me
    meshes["Banner"] = build_banner(bmat)
    return meshes


def build():
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
    for name in ("Castle_Kit", "Castle_Assembly", "Castle_Preview"):
        c = bpy.data.collections.new(name); scene.collection.children.link(c); colls[name] = c

    with open(LAYOUT, encoding="utf-8") as f:
        L = json.load(f)
    C = L["castles"][0]                                    # team A; B is its mirror
    cx, cz, gy = C["center"]["x"], C["center"]["z"], C["pad"]["y"]
    loc = lambda o, up=0.0: (o["x"] - cx, -(o["z"] - cz), up)            # Roblox world -> castle-local Blender
    face_rot = lambda fx, fz: math.degrees(math.atan2(fx, fz))           # local -Y outer face -> Roblox facing (fx, fz)
    plus_x_rot = lambda fx, fz: math.degrees(math.atan2(-fz, fx))        # local +X -> Roblox facing (fx, fz)
    rect_c = lambda r: ((r["min_x"] + r["max_x"]) / 2 - cx, -((r["min_z"] + r["max_z"]) / 2 - cz), 0.0)

    mat, bmat = castle_material(), banner_material()
    meshes = build_meshes(mat, bmat)

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
        place(A, t["id"], meshes["Wall_Corner_Tower_Gun" if t["kind"] == "gun" else "Wall_Corner_Tower"], loc(t), rot)
    g, fg = C["gate"], C["gate_facing"]
    grot = face_rot(fg["x"], fg["z"])
    gl = loc(g)
    gate_line = (gl[0] - fg["x"] * (WALL_T / 2), gl[1] + fg["z"] * (WALL_T / 2), 0.0)   # gate stands on the wall's centre line
    place(A, g["id"], meshes["Gate"], gate_line, grot)
    place(A, g["door_id"], meshes["Gate_Door"], (gate_line[0] + fg["x"] * 1.5, gate_line[1] - fg["z"] * 1.5, 0.0), grot)
    for s, tag in ((-1, "N"), (1, "S")):
        bx = gate_line[0] + fg["x"] * (GATE_D + 0.15)
        place(A, "%s_Banner_Gate%s" % (C["team"], tag), meshes["Banner"], (bx, gate_line[1] - s * 8.4, GATE_H - 1.8), grot, TEAM_A)
    k = C["keep"]
    krot = plus_x_rot(k["door_facing"]["x"], k["door_facing"]["z"])
    place(A, k["id"], meshes["Keep"], rect_c(k), krot)
    place(A, k["storage"]["id"], meshes["King_Storage"], tuple(v + (1.2 if i == 2 else 0) for i, v in enumerate(rect_c(k["storage"]))), krot)
    b = C["barracks"]
    place(A, b["id"], meshes["Barracks"], rect_c(b), face_rot(b["door_facing"]["x"], b["door_facing"]["z"]))
    w = C["workshop"]
    place(A, w["id"], meshes["Workshop"], rect_c(w), face_rot(-w["door_facing"]["x"], -w["door_facing"]["z"]))   # open side is local +Y
    for c in C["cannon_mounts"]:
        place(A, c["id"], meshes["Cannon"], loc(c, c["height"]), plus_x_rot(c["aim"]["x"], c["aim"]["z"]))

    # preview only: ground, a 5-stud avatar, and an attacker's ram and siege cannon in the lane
    P = colls["Castle_Preview"]
    gp = Piece()
    gp.box(-130, 130, -110, 290, -0.5, 0.0, "STONE_DARK")
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
    place(P, "Preview_Ram", meshes["Battering_Ram"], (gate_line[0] + 26, -10, 0), 180.0)
    place(P, "Preview_Siege_Cannon", meshes["Siege_Cannon"], (gate_line[0] + 44, 16, 0), 180.0)

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


def show(scene, kit_visible=False, assembly_visible=True):
    win, area, sp = _v3d()
    win.scene = scene
    lcs = scene.view_layers[0].layer_collection.children
    if lcs.get("Castle_Kit"):
        lcs["Castle_Kit"].hide_viewport = not kit_visible
    if lcs.get("Castle_Assembly"):
        lcs["Castle_Assembly"].hide_viewport = not assembly_visible
    if lcs.get("Castle_Preview"):
        lcs["Castle_Preview"].hide_viewport = not assembly_visible
    sp.shading.type = "RENDERED"
    sp.shading.show_object_outline = False
    sp.clip_start, sp.clip_end = 0.1, 4000
    sp.overlay.show_floor = False
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
