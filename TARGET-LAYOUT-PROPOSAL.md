# Target layout proposal: measured from the battle concept image

**Status: heights adopted 2026-10-01 (option C, "heights only").** Walls are now 20.4 and towers 30.9 to the battlement, about 49 to the roof tip. Pines are now 11–15 tall. The plan is unchanged: 1,040 × 680, a 183.6 ring at ±280 and 16 pads. Trenches, the thinner back belt, the shore-rule wording and option B are **not** adopted and still need your answer.

## Which image was measured

`references/target-composite.png` **does not exist.** I searched the whole repo. The only candidate is `references/ChatGPT Image Oct 1, 2026, 03_04_37 AM.png`, which is byte-identical to `concepts/roman-battlefield-mirrored-castles.png` (1983 × 793 px). **All numbers below come from that image.** If you meant a different composite, these numbers don't apply. Send the file and I'll re-measure.

- The image was read with Blender's image loader, cropped and enlarged with a pixel grid, and measured by eye on the crops. Nothing was imported or copied into any asset.
- **Reference document caveat:** you asked for the field list "per CLAUDE.md §6". CLAUDE.md is now a 10-line pointer file, and §6 (map spec) lives in AGENTS.md, so I followed **AGENTS.md §6**.
- **Placeholder caveat:** the "§11 placeholders" (walls ~12, towers ~18) are in the pre-2026-10-01 CLAUDE.md §11, which is in git history only. AGENTS.md §11 no longer gives heights.

## Method and error

- **Scale:** one soldier = 5 studs. Soldiers are upright, so they give a scale for upright things (walls, towers) and for left-right distances at the same depth in the picture.
  - Soldier height in pixels grows toward the bottom of the image, from **24 px** around row 360 (the central army) to **29–31 px** around rows 450–460 (the Red gate squad).
  - At the castle bases (rows 400–445) it is **25–30 px**, about 5.0–5.8 px per stud.
- **Depth:** front-to-back ground distances are foreshortened. I estimated the camera elevation from the ellipse of each round crater: about **21–24°** (height/width 0.36–0.41). Depth was then integrated row by row with the soldier scale.
- **Error, from best to worst:**
  - **Heights, ±15%:** ±3 px per soldier and per edge.
  - **Left-right distances at the same depth, ±20%.**
  - **Castle widths, ±30%:** the faces are seen at an angle.
  - **Front-to-back depths, ±35%:** the elevation estimate and a simple perspective model.
  - **Island width is a lower bound:** the island runs off both sides of the frame.
- **Scale is not consistent in the image itself.** It's an AI illustration: defenders on the walls draw smaller than soldiers on the ground at the same depth, and the castles look diorama-scaled next to the soldiers.

## Measurements (5-stud soldier)

| Item | Pixels | Studs | Error |
|---|---|---:|---|
| Curtain wall height, Red south wall | 108 px | **20** | ±15% → 17–23 |
| Curtain wall height, Blue south wall | 128 px | **23** | ±15% → 20–26 |
| Corner tower to battlement top, Red front | 163–180 px | **31–32** | ±15% |
| Corner tower to battlement top, Blue front | 198 px | **35** | ±15% |
| Corner tower to roof tip, flag excluded (Red / Blue) | 218–243 / 250 px | **42–45** | ±15% |
| Gate opening, Blue (oblique) | 37 × 92 px | **~8–10 wide × 18 tall** | ±20% |
| Castle width, face toward the camera, tower centre to tower centre (Red / Blue) | 275 / 265 px | **47–53** | ±30% |
| Castle depth, gate face, Blue (strongly foreshortened) | — | **~70–80** | ±40% |
| **Castle footprint, best single figure** | — | **~65 × 65** | ±20 |
| Gate-to-gate distance (both gates at about the same depth) | ~1,025 px | **~205** | ±20% → 165–245 |
| Island width at the castle row | ≥ 1,930 px | **≥ 340–370** | ±25%; runs off frame |
| Island depth, front cliff to back shore, along the centre | rows 175–700 | **~270** | ±35% → 180–370 |
| Cliff band height above the sea (front) | ~80–100 px | **10–12** | ±20% |
| Cliff band width in plan (one to two rock blocks) | — | **10–20** | ±40% |
| Open central field (castle front to castle front × back trees to front trees) | — | **~190 × ~180** | ±25% / ±35% |
| Crater bowls | — | **4**, outer radius **~10–12** | ±30% |
| Trench segments (long dug ditches) | — | **~5**, each **~25–40 long × 4–6 wide** | ±35% |
| Wooden barricades (A-frame and cheval clusters) | — | **~7 clusters** | count ±1 |

**Where the craters and trenches are, by image position.** None are mirrored in the image.
- **Craters:**
  - back-centre, near the axis;
  - centre-left, between the Red castle and the axis;
  - front-centre, a small pit;
  - front-right, toward the Blue side.
- **Trenches:**
  - front-left, two segments in front of the Red castle;
  - front-centre, one;
  - front-right, one large one by the Blue castle's south wall, full of soldiers;
  - back-left, one short one behind the Red siege engines.
- **Barricades:** beside the Red approach, behind the centre, and beside the Blue gate.

**Tree belts:**
- pines all round the island edge, in clusters;
- deepest at the front (south) edge, 2–4 trees deep, about 30–50 studs;
- thinner at the back (north) edge, about 15–30;
- dense stands hugging each castle's outer flank and rear;
- **the open centre is almost treeless.**

**Rocks:**
- large rock outcrops on the back shore;
- 4–6 sea stacks behind each castle;
- the whole front and side shore is a continuous band of big faceted blocks, the cliff.

**Ratios** (more reliable than absolute studs):

| Ratio | Concept image | Approved preview (layout.json v2.0) |
|---|---|---|
| Castle width : gate gap | 0.32 (0.24–0.45) | 0.49 (183.6 : 376.4) |
| Island width : gate gap | ≥ 1.7 | 2.76 (1,040 : 376.4) |
| Tower tip : wall height | 2.1 (1.8–2.6) | 3.3 (62 : 19) |
| Castle rear wall to shore | almost on the cliff (≤ 1 tower width) | 148 studs |

## Height flags (measured vs the old §11 placeholders and the preview)

| Item | Old §11 placeholder (CLAUDE.md history) | Preview build (layout v2.0) | Measured | Flag |
|---|---:|---:|---:|---|
| Wall height | ~12 | 18.9 | 20–23 | ⚠ **Old placeholder is 40–48% low.** The preview is within error (−5 to −18%). |
| Tower to battlement | — (the old ~18 was the whole tower) | 27.6 × 1.33 ≈ 36.7 | 31–35 | Preview is within error (+5 to +18%) |
| Tower to roof tip | ~18 | 62.1 | 42–45 | ⚠ **Old placeholder is 57–60% low.** ⚠ **The preview's 62 is 38–48% high** against the concept: the proposal's 60–65 came from visual weight, not from soldier scale. |
| Gate opening | "fits a 5-stud avatar" | 13 wide × 18.2 tall | ~8–10 × 18 | Height agrees. The preview is wider, which helps the ram. |

## Proposal

### 1. Ring: no 140 × 140 to keep
That ring was superseded twice:
- **v1.1:** 102 × 102;
- **v2.0:** 183.6 × 183.6, approved 2026-10-01 for the in-game preview.

The real question is whether the concept argues for changing 183.6. Three options:

| Option | Plan | What it means |
|---|---|---|
| **A. Literal soldier scale** | island ~360 × 290 playable, castles ~65 square (3 bays + towers ≈ 61), gate gap ~205 (13 s run) | ✗ Not recommended. 16 resource pads at their current radii (44–66.5) can't fit. DESIGN.md requires broad home, middle, forward and shared gathering bands. It makes a cramped arena. |
| **B. Concept proportions at gameplay scale** (×1.83, keeping the 376-stud gate gap) | castles **6 bays = 122.4** square at x = ±249.4, island ~660 × 530, rear walls ~20 from the cliff | Matches the concept's ratios. ✗ But it **shrinks the land by ~35%**, and the 16 pads would need smaller radii or fewer slots. That's a DESIGN-level change. |
| **C. Keep the approved v2.0 plan, adopt the measured heights** (recommended) | 1,040 × 680, ring 183.6 at x = ±280, gate gap 376.4, as approved | Walls stay ~19–20 (within error). Tower tips drop toward **~45–50**, battlement ~33–36. Ratios stay those of the approved plan. |

**Recommendation: option C, decided after your in-game review of the v2.0 preview.** You approved 183.6 to judge in game. The concept's soldier scale is inconsistent, and options A and B both break the 16-slot economy.
- If the castles feel too big in game, option B's **6-bay 122.4 ring** is the measured fallback.
- Its tunnel pair is listed below so the choice is ready.

### 2. layout.json dimensions and field list (AGENTS.md §6)
Everything below except `shore` and `trenches` **already exists in the uncommitted layout.json v2.0** written earlier this run. This proposal changes only the marked lines.

```
meta                 version, date, status, interior_status, units, coords, compass, generator
map_bounds           min_x -520, max_x 520, min_z -340, max_z 340          (C: unchanged)
mirror_axis          plane x = 0
boundary             invisible_wall, 30 outside map_bounds, corner_radius 120, height 60; kill y = -30
shore      [NEW]     method "cliff", cliff_top_y ≈ field height, cliff_drop 10–12 to sea level,
                     band_width 15–25 (outside the boundary wall), rock_block_size 13–24,
                     sea_stacks 6–8 per side behind the castles, collision off (outside the wall)
heights              castle_pad_y 10, field_y 4
teams                A west #B8413A, B east #3A5FB8
castles[]            id, team, center (±280, 10, 0), ring_size 183.6, wall_bays_per_side 9,
                     wall_thickness 4, pad 200 × 200, gate (±188.2) + door_id + bay, gate_facing,
                     art_heights_placeholder {wall_top 19–20, tower_battlement 33–36,
                     tower_tip 45–50 [CHANGED from 62]}, towers[4], wall_sections[35],
                     tunnel_exit, reserved_rear_half, temporary_preview_spawns[6], interior null
central_road         gate to gate on z = 0, 30 wide clear, dirt may meander/widen at the gates
resource_node_slots  16: A1–A7, B1–B7 mirrored, C1–C2 on the axis (A5/B5 at (∓125, 125))
node_footprints      Wood 100, Wool 117, Grain 65, Stone 85, Ore 72
craters[]            4 mirrored, at (±105, -65) and (±55, 48); outer r 18, floor r 9, floor -1.5, rim +1.5
                     (measured bowls r ~10–12 at soldier scale; 18 is the approved gameplay size)
trenches[] [NEW]     4 mirrored segments along x, depth 2.5 below field, walkable ramps at both ends:
                     A_Trench_1 centre (-150, -88) 30 × 5;  A_Trench_2 centre (-75, -88) 20 × 5;
                     mirrored for B. Hand-checked clearances: castle pad 15, A_Cover_N 17.5,
                     A_Crater_1 10.6, A_Cover_Tunnel 11.5, Node_C1 23.9, road 70.
                     ⚠ The concept's trenches are mostly on the FRONT (south, +z) side, but that band is
                     full in v2.0 (Node_A5 at (-125, 125), A_Cover_S, A_Barricade_S, A_Crater_2), and a
                     south trench overlaps Node_A5's pad. South placement needs A5 moved again.
                     propose_layout.js would check all of this before any write.
barricades[]         4 mirrored at (±125, ±37), 12 × 4 × 3.5; optionally +2 by each gate's flank (concept has ~7)
cover_zones[]        A/B_Cover_N, A/B_Cover_S (x ∓177..∓132, z ±40..±68), A/B_Cover_Tunnel
tunnels[]            see §3
decoration_rules     edge_belt_depth 60 at the south (front) edge and sides, 30 at the north (back) edge
                     [CHANGED: the concept's back belt is thinner]; pines only in edge belt and
                     cover zones; round-canopy trees only on Wood pads; never on road, pads,
                     craters, trenches, barricades
zone                 null
```

### 3. Tunnel entrance and exit, mirrored pair

| Ring | Team A entrance | Bend | Courtyard exit | Team B |
|---|---|---|---|---|
| **C (183.6 at ±280)**, approved | (−85, −120) in A_Cover_Tunnel | (−260, −120) | (−260, −55), north-front courtyard, 20 into the front half | x mirrored |
| **B (122.4 at ±249.4)**, fallback | (−85, −110) | (−230, −110) | (−230, −30), inside: inner face 57.2 from centre, exit 19.4 forward, 30 north | x mirrored |

Both keep the long leg approaching the castle, the short leg ending in the north-front courtyard, an entrance hidden in a northern cover patch, and the exit away from the reserved rear half.

### 4. Shore boundary method
- **Keep:** the approved invisible wall, 30 studs outside `map_bounds` on the island's flat edge, plus the kill height at y = −30.
- **Change:** the concept's shore is a **cliff of big rock blocks**, not a beach.
  - Outside the wall, the ground drops 10–12 studs to the sea through the rock band.
  - The rocks are non-colliding art.
  - So a player who somehow passes the wall falls into the sea and the kill height catches them.
- The preview build already does this. Asking you to confirm it as the rule replaces "on the beach" in the boundary text.

## What this proposal does not decide
- Interior positions: Keep, stockpile, barracks, workshop, ballista, tower access. These need their own approved interior layout. `concepts/castle-interior-topdown.png` appeared in the repo during this run; I haven't read it.
- Whether trenches are wanted at all. They are in the concept but not in DESIGN.md or the approved proposal.
