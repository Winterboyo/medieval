# Map revision proposal — prominent castles, foraging, and L tunnels

**Status: APPROVED FOR AN IN-GAME VISUAL PREVIEW (2026-10-01).** The user said the proposal looks good for now and will evaluate it after generation in-game. Treat these coordinates as approved for the first build and subject to revision from that evaluation. Migrate them into `layout.json` before generating Blender geometry. `DESIGN.md` records the chosen direction. `concepts/map-revision-topdown.svg` is a proportional schematic; the battle concept image is a perspective mood reference, not a measured plan.

Units are Roblox studs. Ground plane is `(x, z)` and `-z` is north. Team A is west, Team B east, mirrored across `x = 0`. The coordinates below are approved for the first in-game preview, but `layout.json` still contains the earlier geometry and must be migrated before Blender work.

## What changes

| Feature | Approved layout now | Proposed revision | Reason |
|---|---:|---:|---|
| Playable land | 1,040 × 680 | **Keep 1,040 × 680** | Retains the broad side meadows and all four gathering bands. |
| Castle ring | 102 × 102, 5 wall bays per side | **183.6 × 183.6, 9 bays per side** | Reuses the 20.4-stud wall bay while making each castle about 1.8× wider. |
| Castle centers | `(-370, 0)`, `(370, 0)` | **`(-280, 0)`, `(280, 0)`** | Brings the castles into the main composition without losing side fields. |
| Flat castle pad | 118 × 118 | **200 × 200** | Leaves 8.2 studs outside the enlarged ring on each side. |
| Facing gates | `x = -319`, `x = 319` | **`x = -188.2`, `x = 188.2`** | Gate-to-gate distance becomes 376.4 studs, about 24 seconds at 16 studs/s. |
| Castle width / gate gap | 0.16 | **0.49** | Gives the castles prominence closer to the perspective concept. This is a plan ratio, not a claim of exact pixel matching. |
| Wall sections | 19 per castle | **35 per castle** | Nine positions on each of four sides, less one gate bay; corner towers remain separate. |
| Vertical castle silhouette | Prototype walls ~14.4 high, tower roof tips ~43.6 | **Review walls around 18–20 and tower tips around 60–65** | Larger footprints need taller walls and towers to retain the concept image's visual weight; these heights are art placeholders to judge beside a 5-stud avatar. |

The shortened straight crossing will bring players into contact quickly. The side fields retain home, middle, forward, and shared resource destinations so gathering and carrying goods home remain meaningful. A resource run is not replaced by simply running down the road.

## Main battlefield

- **One central dirt road:** gate to gate on `z = 0`, 30 studs wide. Keep its middle clear of fixed props, nodes, and trees. The dirt color/path can meander gently and widen at the gates, but its collision-clear center stays 30 studs.
- **Resource pads:** retain all 16 mirrored/shared slots and their current type allowances. Move only `Node_A5` from `(-170, 0)` to **`(-125, 125)`**, and `Node_B5` from `(170, 0)` to **`(125, 125)`**. Their old positions would overlap the enlarged castle pads and central road. Both new pads remain off-road, near the southern side field.
- **Craters:** propose four shallow, mirrored bowls centered at `(-105, -65)`, `(105, -65)`, `(-55, 48)`, `(55, 48)`, each about 18 studs in outer radius. Placeholder section: floor 1.5 studs below ground and rim 1.5 above it, with walkable slopes and enough rim to hide a crouched avatar from ground-level fire. Collision and visibility need an avatar-scale test before final mesh detail.
- **Barricades:** propose four mirrored 12 × 4-stud low barriers centered at `(±125, ±37)`, about 3.5 studs high. They sit beside the road, not across it, and create crouch cover without closing flanking routes. The barrier mesh and collision must agree.
- **Gate-side cover zones:** replace the old zones, which would fall inside the enlarged castles. On Team A's approach, reserve `x = -177..-132` at `z = -68..-40` and `z = 40..68`; mirror to Team B. Keep stacked-cone pines and low rocks inside these zones only where they do not block the 30-stud road. A separate northern cover patch hides each tunnel entrance.
- **Shoreline and elevations:** keep the approved island/sea boundary and near-flat green field. Castle pad height remains around `y = 10`, central field around `y = 4`; use gentle, walkable approaches. Avoid an inland water feature or mountain ring.

## Mirrored L-shaped tunnels

The **long leg approaches the castle**; the **short leg ends inside its forward courtyard**. Entrances are concealed in northern cover patches, outside the walls. Each route bypasses some open-field and gate fighting, but exits away from the Keep and stockpile. It is a slow, risky option rather than the main route.

| Point | Team A `(x, z)` | Team B `(x, z)` |
|---|---:|---:|
| Covered exterior entrance | `(-85, -120)` | `(85, -120)` |
| L bend | `(-260, -120)` | `(260, -120)` |
| Interior exit | `(-260, -55)` | `(260, -55)` |

The outer leg is **175 studs straight** and the inner leg **65 studs**, for a 240-stud crawl. An illustrative 5-stud/s crawl takes about **48 seconds**, versus about 15 seconds to cover the same path length at normal running speed. Speed, portal elevation, tunnel width, and collision height are placeholders to verify with the actual Roblox crawl controller. Start with roughly 6 studs of width and 3.5 studs of clear height. No ram fits. Only one traveler may be in each tunnel at a time; there is no passing or combat while crawling. The straight outer leg and short inner leg create firing lanes for campers; the bend prevents a single shot down the entire tunnel. Keep the tunnel free of interior cover so its risk remains legible.

The exit is near the north/front quadrant of each courtyard, not next to either objective. Reserve the rear half of each enlarged castle for the Keep and separate stockpile, and keep their eventual entry points at least 60 studs of traversable courtyard route from the tunnel exit. The exact Keep, stockpile, barracks, workshop, spawn points, tower access, and ballista mounts still need an interior proposal. Their 2026-09-30 coordinates in `layout.json` are stale. Do not reuse the old storage-inside-Keep or cannon mounts when constructing the enlarged castle.

## Preliminary geometry audit

The proposed coordinates pass a 2D clearance check: all 16 resource slots retain exact `x` mirrors; the closest two resource pads have 11.9 studs between them; the closest node pad is 9.9 studs from a castle pad and 51 studs from the central road. Craters stop at least 15 studs from the road and 20.9 studs from node pads; barricades stop 20 studs from the road. Both tunnel exits fall inside the proposed rings. This checks plan geometry only; avatar collision, sightlines, and crawl travel still need Studio validation.

## Layout checks before Blender work

1. Retain each node's flat pad and type identity. Check every pad, crater, barricade, cover patch, and tunnel portal against castle pads and the road.
2. Verify the two halves are exact `x` mirrors, all four crater bowls and four barricades are traversable cover, and the central road stays clear at avatar and ram width.
3. Confirm from a 5-stud avatar camera that a crouched player gets useful cover, a standing player remains exposed, and tunnel sightlines behave as intended.
4. Update `layout.json` and its generator/validation together. Then generate terrain and castle assets in Blender using the viewport screenshot workflow in `AGENTS.md`. Test one tile and one castle piece in Studio before exporting the rest.

## Approval record

The user approved the **183.6-stud rings at `x = ±280`**, the **30-stud central road**, the **moved A5/B5 nodes**, the **four crater and four barricade placements**, and the **northern L-tunnel route** for an in-game visual preview on 2026-10-01. The exact crater profile and crawl speed remain playtest placeholders. Visual and gameplay adjustments may follow the in-game evaluation.
