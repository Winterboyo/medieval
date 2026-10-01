# Art recipe: how the castle kit got from weak to detailed

Written 2026-10-01 from this Claude Code session's own transcript and the live Blender "Castle" scene. Where the history doesn't record something, this file says so instead of guessing.

## Summary

There were four castle passes, all through `execute_blender_code` only. No generators or downloaded assets were used.

| Pass | What you asked for | Rounds | Result | What you said |
|---|---|---|---|---|
| 1 | A pasted spec: chunky low-poly "Bad North" style, 4–6 colours, no tiny details, under 1,500 tris per piece, ring ~60 × 60 | 3 | 1,754 tris assembled; pieces 44–240 tris | "no i dont like it" |
| 2 | "make sure that the recreatio is faithful to the reference" | 3 | 8,216 tris assembled; first build after `castle-1.jpg` | You moved on to siege mechanics, with no verdict on the look |
| 3 | Siege kit (Phase 1): interior structures and damage states | 3 | 13,732-tri kit; 13,962 assembled | "i dont like the blender creation. its not faithful… i want a perfect replica." |
| 4 | "go with option 1, castle-1, fix the roofs and keep iterating… there isnt enough detail" | 9 rebuild-and-screenshot cycles (see below) | 21,696-tri kit; 27,034 assembled | "it looks good. commit to github please." (`217bada`) |

The biggest single change was **how the reference was used**:
- Passes 1–3 matched the *overall impression*.
- Pass 4 started by cropping and enlarging parts of `castle-1.jpg` (roofs, tower bands, gate) in Blender. It then copied *how each part is built*: tile rows, corbel brackets, block courses.
- Detail density went up about 2.6× (kit 8.2k → 21.7k tris).

## Pass by pass

### Pass 1: generic low-poly (rejected)
- **The ask:**
  - The spec named a style family ("Bad North"), not an image.
  - It capped colours at 4–6, banned "tiny details", and gave placeholder sizes (walls ~12, towers ~18, ring ~60 × 60).
  - Each piece had to be under 1,500 tris, with self-critique over up to 3 rounds.
  - It did not point at `references/castle-1.jpg`.
- **Colours:** five flat colours taken from the game's existing castle palette: stone, dark stone, tile red, timber and banner blue. They were **not sampled from a reference**.
- **Geometry:** very low counts per piece. Wall_Segment was 48 tris, Wall_Corner_Tower 54, Gate 240, Gate_Door 44, Stockpile 92 and Banner 50. The transcript doesn't record the exact shapes. The tower count means it was a simple prism with a roof.
- **Rounds:**
  1. Towers looked stubby, only ~5 studs above the wall, and the copies were named `.001`. → Made the towers and flags taller and fixed the names.
  2. Found a scale bug: the storehouse was 4.6 tall with a 2.8-stud door, shorter than the avatar. → Rebuilt it at avatar scale.
  3. The gate didn't stand out from the top. → Added red-capped flanking turrets.
- **Left open:** seams between wall segments, merlons only on the outer face, and stone versus dark stone too close to tell apart.
- **Builder:** a temporary script in the job folder, never saved to the repo.

### Pass 2: first build after castle-1 (replaced the pass 1 castle)
- **The ask:** "faithful to the reference". I followed the asset contract (the §10 contract, then in CLAUDE.md, now AGENTS.md):
  - opened `castle-1.jpg` and `castle-2.jpg`;
  - **sampled the palette from castle-1** with Blender's image loader: warm light stone, shaded stone, slate, timber and iron, plus neutral banner cloth and emblem;
  - took 5 views next to a 5-stud dummy.
- **Techniques introduced:**
  - **Towers:** round, 16-sided, with a flared base and a band, then a corbel ring under an overhanging battlement band. Each had a tall slate cone with a flared brim and an iron spike.
  - **Walls:** a crenellated parapet on corbels, plus a few offset stones on the face. This is the "few offset boxes per wall face" rule, not per-brick modelling.
  - **Gatehouse:** taller than the walls, with a stone-framed arch, a timber door with iron bands, and slate-capped corner turrets.
- **Rounds:**
  1. Towers barely cleared the walls, the gatehouse was too low, and the warm "sunrise" preview lighting turned the stone yellow.
  2. Raised the towers (to 27.6 at the battlement, 43.6 at the tip) and the gatehouse, flared the roof eaves, and switched to neutral lighting.
  3. Added castle-1's two-stage tower: a corbelled, wider upper drum. Windows were then placed on whichever stage they sit in.
- **Left open, in my own report at the time:**
  - straight smooth cones instead of shingled roofs with dormers;
  - solid corbels instead of open dark gaps;
  - little block detail;
  - no drawbridge;
  - identical towers;
  - stone reading pinkish under the preview light.

### Pass 3: the siege kit (Phase 1, art judged not faithful)
- **What it added:** damage states for every damageable piece, plus the keep, king's storage, barracks, workshop, cannon, ram, siege cannon and scaffold, all in the pass 2 style.
- **Rounds:**
  1. The whole set built cleanly, but the damaged gun tower looked like the intact one.
  2. Knocked a chunk out of its battlement band and parapet.
  3. Checked the ram at the gate.
- **Left open:** the keep was a single block, unlike castle-1's stepped keep.
- **Not a look-improvement pass:** it was about mechanics, which is part of why the look stayed at the pass 2 level.

### Pass 4: the detailed rebuild (approved)
- **The ask:**
  - You named the image (castle-1) and the worst part (roofs), and asked for more detail and iteration.
  - First I declined to make a "perfect replica". castle-1 is a commercial asset-pack render, and the rules forbid reproducing it.
  - I offered three options. You chose **option 1, a close same-family rebuild**.
- **Method change:** I cropped and enlarged regions of `castle-1.jpg` in Blender (roof, tower bands, gate) and built from those close-ups.
- **Techniques, and what each fixed:**
  - **Roofs** (the main complaint about smooth cones). Fix: a `shingle_cone()` builder with rows of overlapping fish-scale tiles. Each row:
    - is staggered by half a tile;
    - is kicked out at its lower edge;
    - has seeded jitter so it reads hand-laid;
    - sits over a dark core cone so no sky shows through.

    The big tower roof also got a thick rolled eave, a dormer and an iron finial. The gate turrets got steep, jagged "pine-cone" stacks of big slates.
  - **Roof colours** (one flat slate read as plastic). Fix: two slate tones re-sampled from the castle-1 roof, the median shingle `(106,111,117)` and the lit 80th percentile `(128,135,141)`. About 30% of tiles are light.
  - **Overhang bands and machicolation** (solid corbels read light; there was no dark gap). Fix:
    - on towers, a dark band behind chunky corbel brackets with narrow gaps, a ragged sloped lip on top, and an upper drum overhanging the shaft by 1.1;
    - on walls, a projecting band of rough blocks of uneven width and drop over a dark recess, with capped merlons and an inner lip.
  - **Stonework** (flat faces). Fix:
    - a mid-height course of irregular proud blocks on the towers, with a few loose stones under it;
    - scattered proud blocks low on the wall faces;
    - on the gate, **voussoirs**: rough, uneven blocks of differing depth ringing the arch;
    - on the gate, **quoins**: alternating long and short blocks up the jambs and corners;
    - a row of small, high gatehouse windows.

    Still offset boxes, never per-brick.
  - **Gate** (a flat door). Fix: a lowered plank drawbridge with battens and two iron chains.
  - **Keep** (a single box). Fix: castle-1's stepped, crenellated block, with a second tier toward the back, a tall square tower topping the skyline, a shorter one beside it, and arched windows. The tower block was rewritten once because the first version came out convoluted.
  - **Lighting** (stone looked pink or orange; the bundled "courtyard" and "sunrise" HDRIs are warm). Fix: a neutral grey-blue world fill plus one sun from the gate side. castle-1 is front-lit, and the sampled warm grey then read as warm grey. This changed the preview only, not the asset.
- **Iterations:**
  - The transcript shows **9 rebuilds**, each followed by viewport screenshots: 12 screenshots and 14 Blender code runs in total.
  - **That is over the 3-round limit.** You had said "keep iterating", which I took as permission. I didn't label the rounds at the time, so I can't map each rebuild to a numbered round.
  - The order of work: roofs → gate and keep turret roofs → preview lighting → tower drum overhang and corbels → wall-face stones → gate voussoirs and quoins → sun direction → stepped keep (twice) → corbel and gap proportions.
- **Cost:** Gate 620 → **2,720** tris and Keep 1,404 → **2,312**, both over the 1,500 default. The decision on raising the budgets was never made.
- **Still different from castle-1, in my report at the time:**
  - front towers are open gun platforms, not roofed;
  - walls are lower relative to a person;
  - the door isn't recessed into a deep arch passage;
  - the banner is a plain pennant, with no lion;
  - there's no moat;
  - damaged and rubble states are simpler than intact.

## What I don't know
- Which single change made you approve pass 4. You approved the whole pass.
- Exactly what was weak in pass 1 beyond "no i dont like it". You gave no specifics, and its builder wasn't kept.
- The geometry of pass 1, beyond triangle counts and my own report.
- A round-by-round mapping for pass 4.

## Every object in the castle file

The "castle file" here means Blender scene **"Castle"**, rebuilt by `assets/castle/build_castle.py`; the `.blend` is not saved. `assets/castle/castle_kit.fbx` contains **only the 28 `Castle_Kit` pieces**. Counts were read from the scene today.

CLAUDE.md is now a 10-line pointer file and defines no assets. "Traceable" below therefore means traceable to **DESIGN.md**, or to AGENTS.md as DESIGN.md directs. ⚠ marks anything that isn't, or that conflicts.

### Castle_Kit (28 objects, 21,696 tris, all in the FBX)

| Object | Tris | Traceable? |
|---|---:|---|
| Wall_Segment | 540 | Yes: wall sections with HP (DESIGN Castle) |
| Wall_Segment_Damaged | 368 | Yes: intact, damaged and rubble looks |
| Wall_Segment_Rubble | 360 | Yes |
| Wall_Corner_Tower | 2,936 | Yes: four corner towers. ⚠ No stairs or ladders; DESIGN requires tower-top access. Under the ~3,000 tower budget. |
| Wall_Corner_Tower_Damaged | 2,516 | Yes |
| Wall_Corner_Tower_Rubble | 636 | Yes |
| Wall_Corner_Tower_Gun | 1,620 | ⚠ An open platform built to carry the **parked** defensive cannons. DESIGN has no gun tower. |
| Wall_Corner_Tower_Gun_Damaged | 1,656 | ⚠ Same |
| Wall_Corner_Tower_Gun_Rubble | 636 | ⚠ Same |
| Gate | 2,720 | Yes. ⚠ Over the 1,500 default budget, and the decision on it is still pending. |
| Gate_Door | 112 | Yes: separate door |
| Gate_Door_Damaged | 168 | Yes |
| Gate_Door_Rubble | 144 | Yes |
| Keep | 2,312 | Partly. A Keep is decided, but this one is the old indestructible design: ⚠ no damaged or rubble states (DESIGN requires them), ⚠ over the 1,500 default budget, and DESIGN.md §Castle calls the kit a prototype that needs a new Keep task. |
| King_Storage | 648 | ⚠ Storage inside the Keep. DESIGN now has a **separate** stockpile and the proposal says not to reuse storage-inside-Keep. |
| Barracks | 336 | Yes: barracks decided. Its position is stale. |
| Barracks_Damaged | 524 | ⚠ Barracks states "follow their final gameplay rules" (AGENTS §11), which are not decided |
| Barracks_Rubble | 668 | ⚠ Same |
| Workshop | 302 | Yes: workshop decided. Its position is stale. |
| Workshop_Damaged | 458 | ⚠ Same as Barracks states |
| Workshop_Rubble | 480 | ⚠ Same |
| Cannon | 288 | ⚠ **Parked.** DESIGN: "the old trebuchet and cannons remain parked"; a fixed ballista replaces them. |
| Cannon_Damaged | 264 | ⚠ Parked |
| Cannon_Rubble | 108 | ⚠ Parked |
| Siege_Cannon | 308 | ⚠ **Parked.** "Park the planned movable siege cannon." |
| Battering_Ram | 320 | Yes: ram decided (damage, cost and movement are open) |
| Scaffold | 228 | Yes: repairs show timber scaffolding |
| Banner | 40 | Yes: banners recolour Red and Blue |

**Missing from the kit:** a ballista, tunnel pieces, tower stairs or ladders, and Keep damage states.

### Castle_Assembly (35 objects, 27,034 tris; team A's castle; not in the FBX)

⚠ **The whole assembly follows layout.json v1.1**: the 102 × 102 ring at x = −370 with the 2026-09-30 interior. As of today layout.json is v2.0 (183.6 ring at x = −280, no interior), so every position below is stale.

| Object | Mesh | Tris | Traceable? |
|---|---|---:|---|
| A_Wall_F1, F2, F4, F5 | Wall_Segment | 540 each | Yes, but these are v1.1 ids (5 bays a side; v2.0 has 9) |
| A_Wall_N1–N5 | Wall_Segment | 540 each | Same |
| A_Wall_R1–R5 | Wall_Segment | 540 each | Same |
| A_Wall_S1–S5 | Wall_Segment | 540 each | Same |
| A_Tower_RN, A_Tower_RS | Wall_Corner_Tower | 2,936 each | Yes |
| A_Tower_FN, A_Tower_FS | Wall_Corner_Tower_Gun | 1,620 each | ⚠ Gun platforms for parked cannons |
| A_Gate | Gate | 2,720 | Yes |
| A_Gate_Door | Gate_Door | 112 | Yes |
| A_Banner_GateN, A_Banner_GateS | Banner | 40 each | Yes |
| A_Keep | Keep | 2,312 | ⚠ Stale position and old design; DESIGN says do not infer the Keep from older work |
| A_King_Storage | King_Storage | 648 | ⚠ Storage inside the Keep is superseded |
| A_Barracks | Barracks | 336 | ⚠ Stale position |
| A_Workshop | Workshop | 302 | ⚠ Stale position |
| A_Cannon_TowerN, A_Cannon_TowerS, A_Cannon_GateN, A_Cannon_GateS | Cannon | 288 each | ⚠ Parked |

### Castle_Preview (5 objects; preview only; not in the FBX)

| Object | Tris | Traceable? |
|---|---:|---|
| Dummy_5stud | 72 | Yes: AGENTS §10 requires a 5-stud dummy |
| Preview_Ground | 12 | A preview floor only. ⚠ It doesn't trace to the design and isn't exported. |
| Preview_Ram | 320 | Yes: ram, for scale |
| Preview_Siege_Cannon | 308 | ⚠ Parked |
| Preview_Sun (light) | — | Preview lighting only |

## Triangle budgets (AGENTS.md §11)

| Rule | Status |
|---|---|
| Wall pieces at or under 1,500 | Met: 540 |
| Towers up to ~3,000 | Met: 2,936 is the highest |
| Gate and Keep | Over the 1,500 default (2,720 and 2,312). Raising them or slimming the pieces is your decision and is still open. |
