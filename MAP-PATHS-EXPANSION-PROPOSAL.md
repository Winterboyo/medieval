# Battlefield paths and length revision

**Status: APPROVED 2026-10-03 and built in `layout.json` v2.2.** The user selected the winding stone-and-dirt paths in [Roblox forest path reference #4](https://devforum.roblox.com/t/what-if-roblox-forests-looked-more-like-this/284170) and the layered grass in [The Wild West field reference #2](https://x.com/KazuhiraRBLX/status/1532617980797919232). These are visual references, not assets to import or copy. [Top-down plan](concepts/map-paths-expansion-proposal.svg).

Units are Roblox studs. Ground plane is `(x, z)`; `-z` is north. Team A is west. Every eastern coordinate mirrors across `x = 0`. Castle buildings, wall rings, interior footprints, and heights stay at their approved sizes.

## Scale and travel

| Measure | Current v2.1 | Proposed | Effect |
|---|---:|---:|---|
| Playable x length | 1,040 (`-520..520`) | **1,560 (`-780..780`)** | Exactly 1.5× as long; z width remains 680. |
| Castle centers | `x = ±280` | **`x = ±420`** | Center-to-center distance rises 560 → 840, exactly 1.5×. |
| Facing gates | `x = ±188.2` | **`x = ±328.2`** | Gate gap rises 376.4 → 656.4. |
| Unobstructed walking at 16 studs/s | 23.5 seconds gate to gate | **41.0 seconds straight; about 42 seconds along either route** | Movement abilities, ram speed, and fighting will change actual travel time. |
| Castle pad and ring | 200 / 183.6 square | **unchanged** | Preserves approved castle art and interior layout. |

The extra 520 studs are split between a longer central field and room behind the castles for foraging. Outer margins from the castle-pad rear edge to the playable x boundary become 260 studs on each side, compared with 140 now. The coast, invisible beach boundary, and terrain extent move outward with `map_bounds`; shoreline and elevation rules remain the same. The existing 13-minute match cap is a gameplay placeholder to evaluate after the longer walking distance is in Studio.

## Two ram routes

Replace the single painted 30-stud `central_road` with **two continuous ram-capable path corridors**. Both start at Team A's gate, divide across the field, and meet Team B's gate. They are alternative approaches; this plan does not decide how many rams a team may construct at once.

| Route | Centerline `(x, z)` from west gate to east gate | Clear width |
|---|---|---:|
| North | `(-328.2, 0) → (-260, -20) → (-180, -42) → (180, -42) → (260, -20) → (328.2, 0)` | **18** |
| South | `(-328.2, 0) → (-260, 20) → (-180, 42) → (180, 42) → (260, 20) → (328.2, 0)` | **18** |

The routes are equal in length and mirrored around `z = 0`, so neither team gains a shorter ram approach. At the middle they are 84 studs apart center to center, leaving about 66 studs of grass and cover between their clear edges. A 12-stud-wide ram placeholder has 3 studs of clearance on either side of an 18-stud route. The paths converge for the last 68 studs before each gate, so the gate still forms a defensible choke. Keep the **full 18-stud corridor free of collision props, steep lips, resource nodes, and tall grass**. The paver and dirt coloring may wander *inside* that clear corridor without making the collision route crooked. A ram turning/collision test in Studio is required before treating 18 studs as final.

The visual treatment follows reference #4's ground language: uneven compacted-earth bands, intermittent broad flat stone pieces, irregular edges, and small worn grass patches. Keep the center of each route smooth enough for a ram. This is a style target, not a copy of the reference's exact stone shapes or arrangement.

## Field grass

Use reference #2 for the **open flat field**: a green ground base with broad tonal variation, layered short and medium grass clumps, and restrained yellow-green patches rather than a single uniform green sheet. Denser clumps can frame the paths and cover; keep the route surfaces, castle pads, and resource interaction pads readable. Preserve the project's stacked-cone pines and its rule that only Wood resource nodes use round-canopy trees. Grass is visual-only and should not form a collision wall or conceal crouched players everywhere. Sample the reference palette before the Blender build and check it under the game's Studio lighting.

## Relocated layout features

These are candidate placements, not a new resource count. The 16 node slots and their allowed types remain the same. A-side values below mirror to B; the two Ore pads on `x = 0` mirror to themselves.

| Feature | Proposed Team A / shared coordinates `(x, z)` | Reason |
|---|---|---|
| Home A1, A2 | `(-560, -190)`, `(-560, 195)` | Follow the moved castle and retain home-side gathering. |
| Mid A3, A4, A5 | `(-390, -190)`, `(-400, 185)`, `(-250, 135)` | Stay outside the 200-stud castle pad and off both ram routes. |
| Forward A6, A7 | `(-190, -235)`, `(-185, 245)` | Offer field trips between castle and center. |
| Shared C1, C2 | `(0, -140)`, `(0, 140)` | Clear the two paths while keeping center Ore contested. |
| Gate-side cover zones | `x = -317..-272`, `z = -68..-40` and `40..68` | Shift with the gate and stay outside the ram corridors. |
| Tunnel cover and entrance | cover `x = -245..-205`, `z = -138..-102`; entrance `(-225, -120)` | Preserve the concealed approach away from the paths. |
| Tunnel bend / interior exit | `(-400, -120)` / `(-400, -55)` | Translate the approved L route with the castle. Its 175 + 65 stud crawl remains unchanged. |
| Craters | `(-105, 0)` and `(105, 0)` | Keep both 18-stud-radius bowls in the grassy median, clear of each ram route. |
| Barricades | `(-155, 0)`, `(-45, 0)`, `(45, 0)`, `(155, 0)` | Provide crouch cover in the median without barricading a ram. |

The central field remains open enough for fighting and gathering. The two paths are clear routes, not fences: players can cross the meadow between them. The craters and barricades provide the cover the user requested; check crouch sightlines at avatar height after terrain generation.

A preliminary one-stud sample along both proposed 18-stud corridors found **45 studs to the nearest node pad**, **13.6 to a cover zone**, **15 to a crater rim**, and **31 to a barricade**. Neither path is blocked by the listed features. This is a 2D proposal check; the generator and avatar/ram collision checks remain required after approval.

## Validation and change boundary

The approved change updated `assets/map/propose_layout.js`, regenerated `layout.json`, and made the Blender battlefield builder use the two paths and resized bounds. The layout audit reports no blocked route samples, no missing ground samples, and an exact terrain mirror. The steepest sampled ram route grade is 0.057; castle and node pads deviate at most 0.0021 studs from their intended heights. The exterior and relocated interiors are exported as `assets/map/battlefield_v2_2.fbx` and `assets/castle/castle_interiors_v2_2.fbx`. [Full preview](concepts/battlefield-paths-preview-full-three-quarter.png), [marked top view](concepts/battlefield-paths-preview-top.png), and [avatar-height route view](concepts/battlefield-paths-preview-route.png) capture the Blender result. Studio still needs a play test for ram turning, grass visibility, path collision, import colors, and first-contact timing before the layout is considered final.

`DESIGN.md` line 26 currently specifies **one** dirt road. That line conflicts with the user's newer choice of two ram routes. Per `AGENTS.md`'s authority rule, this proposal records the conflict without editing `DESIGN.md` in this map task.
