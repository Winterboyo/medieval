# Layout proposal — two mirrored castles (CLAUDE.md §6.2)

**Status: APPROVED 2026-09-30.** The data is now `layout.json`. The old 16-plot island
export was renamed to `layout.old-island.json` (reference only). Next: rebuild the Blender
map from `layout.json`. The file names in the sections below are as proposed.

Units are studs. Roblox ground plane (x, z), height y; −Z is north, +X is east. Blender
conversion stays (x, y, z) → (x, −z, y).

## Top-down sketch (north up)

```
 z=-340 +--------------------------------------------------------------------+
        | pine belt (60 deep, all edges)                                     |
        |   A1 W/G      A3 S/W         A6 O/S   C1 Ore   B6 O/S    B3 S/W   B1 W/G  |
        |                                                                    |
        |  +-------+  [cover]                                   [cover]  +-------+ |
   z=0  |  |  A  ▶ |=====lane====   A5 S/G     .      B5 S/G  ====lane====| ◀  B | |
        |  +-------+  [cover]                                   [cover]  +-------+ |
        |                                                                    |
        |   A2 Wo/G     A4 S/Wo        A7 O/W   C2 Ore   B7 O/W    B4 S/Wo  B2 Wo/G |
 z=+340 +--------------------------------------------------------------------+
      x=-520                           x=0 (mirror axis)                    x=+520
```
Letters: W Wood, G Grain, Wo Wool, S Stone, O Ore. ▶ ◀ = gates, facing each other.

## Dimensions

| Item | Proposed | Why |
|---|---|---|
| Playable area (`map_bounds`) | 1,040 × 680 (x −520..520, z −340..340) | Gate to enemy gate is 638 studs = **40 s** at the default walk speed of 16; a team reaches the middle in 20 s. Across a 12–15 min match that's ~20 crossings — short enough for the first fight inside the first minute, long enough that a raid is a commitment. |
| Castle wall ring | **102 × 102** (shrunk from 140 × 140) | 102 = exactly 5 of the code's 20.4-stud wall blocks per side, so the existing wall drawing works unchanged. The 140 ring was sized for a village (houses, workshops) that is now cut; for 6 defenders it's mostly empty space. At 102, a defender reaches any point inside in ~6 s after respawning. Wall HP is one number and the wall is only hit at the gate, so a smaller ring doesn't make it weaker. |
| Castle pad | 118 × 118, flat, y 10 | Ring + 8 each side. Castles sit slightly high (y 10 against 4 in the middle) so defenders see the approach. |
| Castle centres | A (−370, 0), B (370, 0) | 150 studs of land behind each castle for home nodes and the pine belt. |
| Gates | A at (−319, 0) facing east, B at (319, 0) facing west | Gates face each other across the middle, so the one chokepoint faces the fight. |
| Approach lanes | 30 wide × 80 long from each gate | CLAUDE.md §5 placeholder. Kept clear: no pad, tree or cover inside. |
| Cover zones | 4 blocks of 24 × 40, beside each lane, 6 studs off its edge | The only place decorative pines may stand besides the edge belt. |
| Spawns | 6 per team, inside the castle between the stockpile and the gate | 6v6 placeholder. Replaces respawning at a keep. |
| Stockpile | One per castle, 25 studs behind the centre (away from the gate) | The pooled team stockpile (CLAUDE.md §4). Attackers have to cross the courtyard to reach it. |
| Height range | y 4 (middle) to 10 (castles) | Gentle: steepest ramp between any two pads is 3.9°. Nothing like the cliffs the old layout forced. |

## Resource node slots — 16 (7 mirrored pairs + 2 shared)

Each slot lists the types it may hold; per match one type is picked on side A and mirrored
to B (CLAUDE.md §6.4, a later task). Pad radius fits the largest allowed type.

| Pair | Ring | Allowed | A position | Walk from own gate |
|---|---|---|---|---|
| A1/B1 | home | Wood, Grain | (−420, −190) | 13 s |
| A2/B2 | home | Wool, Grain | (−420, 195) | 14 s |
| A3/B3 | mid | Stone, Wood | (−250, −190) | 13 s |
| A4/B4 | mid | Stone, Wool | (−260, 185) | 12 s |
| A5/B5 | mid | Stone, Grain | (−170, 0) | 9 s — on the straight route to the enemy |
| A6/B6 | forward | Ore, Stone | (−120, −235) | 19 s |
| A7/B7 | forward | Ore, Wood | (−115, 245) | 20 s |
| C1 | center (shared) | Ore | (0, −110) | 21 s |
| C2 | center (shared) | Ore | (0, 110) | 21 s |

The shape of it: Wood, Grain and Wool are available at home without leaving safety; Stone
sits in the middle band; **Ore is only forward and in the shared centre**, so the scarce
resource forces contact. 16 slots for 12 players, against 48 for 16 on the old map —
fewer nodes, closer together, because matches are 12–15 minutes, not 45.

## Boundary (CLAUDE.md §6.5: decide it here)

**Proposed: an invisible wall**, a rounded rectangle 30 studs outside `map_bounds`, 60 tall,
standing on the beach — plus a kill volume at y −30 as a safety net. The terrain's coast
lies beyond the wall, so players can walk onto the beach and see the sea but can't wade out.
A kill volume at the shoreline instead would kill players for a misstep at the edge, which
reads as a bug; a wall just stops them.

## Field list (what `layout.proposed.json` contains)

`meta` · `map_bounds` · `mirror_axis` (plane x = 0) · `boundary` · `teams` (A west, B east,
placeholder banner colours) · `castles` (id, team, center, ring_size, wall_blocks_per_side,
pad, gate, gate_facing, stockpile, spawn_points) · `resource_node_slots` (id, side,
mirror_pair, position, ring, allowed_types, pad_radius) · `node_footprints` ·
`gate_approach_lanes` · `cover_zones` · `decoration_rules` (edge belt depth, where pines and
round-canopy trees may go) · `zone: null`.

Every field CLAUDE.md §6.1 requires is present. Checked by script: no pad overlaps
(closest pair 27 studs apart), both lanes clear, all pads inside bounds, every slot
exactly mirrored.

## Deliberately left out

- **Shrinking zone** — `zone: null`. CLAUDE.md §15 lists it as likely cut for two fixed
  castles. Add it back only if you approve.
- **Decorative props, village** — after the playtest (CLAUDE.md §11).
- **Per-match node randomisation** — the slots support it; building it is a later task.

## Approve, or change

1. The playable size (1,040 × 680) and the 40 s gate-to-gate walk.
2. Shrinking the castle ring to 102 × 102.
3. Gates facing each other across the middle.
4. The 16 slots and where Ore lives.
5. The boundary: invisible wall on the beach plus a kill volume.

---

# Addendum — castle interior (APPROVED 2026-09-30)

The data is now in `layout.json` (version 1.1), generated and checked by `assets/map/propose_layout.js`.
Everything outside the castles is byte-for-byte the approved layout; only the castle entries
gain fields.

Team A shown (gate east). Team B is the exact mirror. Local studs from the castle centre;
"f" points toward the gate.

```
            north wall (N1..N5)
   ┌RN●──────────────────────────────●FN┐   ● towers: F = front (gun platform, cannon on top)
   │          [ BARRACKS  32x14 ]        │             R = rear (slate cone)
   │           6 spawns inside           │
 R │ ┌─────────┐                          │ F   ┌ gate (one bay, F3) + 2 cannons on its roof
 e │ │  KEEP   │◄──── 16-wide clear ──────┤═▶  │
 a │ │[STORAGE]│      passage, 65 long    │ g  └ gate door
 r │ └─────────┘                          │ a
   │          [ WORKSHOP  30x14 ]        │ t
   │                                      │ e
   └RS●──────────────────────────────●FS┘
            south wall (S1..S5)
```

| Item | Where (local f, z) | Size | Notes |
|---|---|---|---|
| King's keep | f −45..−21, z −14..14 | 24 × 28, ~26 tall | Door on its gate side at f −21. Cannot be destroyed. |
| King's storage | f −41..−27, z −10..10 | 14 × 20, inside the keep | The pooled team stockpile; `stockpile` now points at its centre (f −34). Loot is taken here after a breach. |
| Barracks | f −10..22, z −44..−30 | 32 × 14, ~12 tall | Door faces the courtyard. All 6 spawns are inside; the gate is ~3 s away. |
| Workshop / forge | f −10..20, z 30..44 | 30 × 14, ~11 tall | Door faces the courtyard; rams and siege cannons roll out through the gate. |
| Cannons | front towers (f 49, z ±49) at 27.6 up; gatehouse roof (f 49, z ±6) at 21.4 up | 4 per castle | All aim at the enemy side. |
| Towers | 4 corners | | **Front two become open gun platforms** (crenellated, no cone); rear two keep their slate cones. |
| Wall sections | 19 per castle, ids `A_Wall_F1,F2,F4,F5` (gate side), `R1–R5`, `N1–N5`, `S1–S5` | one 20.4 bay each | Each has its own HP; any one destroyed = breached. |

**Checked by script:** buildings inside the walls and clear of the corner towers; closest
buildings 19.4 apart; storage inside the keep; a 16-wide passage from the gate to the keep
door with nothing in it; every spawn inside the barracks; 19 sections, 4 towers and 4
cannons per castle; 72 unique ids; team B an exact mirror of A.

**One change from the approved plan:** the plan put cannons on all four tower tops, but the
approved tower art has tall slate cones on top. castle-1 has both kinds of tower, so the two
front towers (facing the enemy) become open gun platforms and the rear two keep their cones;
the other two cannons go on the gatehouse roof.

## Approve, or change
1. Keep at the back with the storage inside, door facing the gate.
2. Barracks on the north side, workshop on the south side.
3. Cannons: 2 on the front towers (which lose their cones) + 2 on the gatehouse.
4. Wall-section ids and the 19-section count.
