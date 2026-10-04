# Realism target: what "The Forge look" is, measured

**Status:** Phase 0 approved 2026-10-03 (wording applied to AGENTS.md §9 and DESIGN.md). Phase 1 proof-of-look patch built; results at the end, waiting for your judgement.

**Sources.** Three screenshots of *The Forge* (Roblox) in `references/` (private, gitignored, never imported or copied):
- an outdoor plaza;
- a wide forge cave;
- a smithy in a cave.

Colours are medians of small patches: sRGB, "lum" is perceived brightness 0–255, "sat" is saturation 0–1. Online sources don't describe how The Forge is built, so everything below is read from the screenshots.

## The main finding
**The Forge is not photo-realistic.** Its shapes are as low-poly as ours:
- faceted cone pines;
- blocky autumn trees;
- simple palm fronds;
- chunky faceted rocks;
- simple stalls.

Three things make it feel grounded and gritty:
1. **Real surface textures on almost everything:**
   - wood-plank grain on roofs and stalls;
   - a herringbone stone floor;
   - rough rock;
   - a speckled concrete or sand-like ground;
   - a dressed-stone chimney.

   No surface is a flat colour. This most likely comes from Roblox materials or MaterialVariants plus a few textures, not custom shaders, which Roblox doesn't have.
2. **Low-key values with saturated darks.** Most objects are dark (lum 25–60), with deep colours: brown wood, rust-red foliage, slate rock. Light comes from a few big surfaces (ground, sky) and from light sources.
3. **Lighting contrast and colour temperature:**
   - **Outdoors:** a flat, overcast, warm-grey sky; soft light; no hard sun.
   - **Inside:** near-black ambient, warm fire pools, cool blue fill from above.
   - Warm orange accents everywhere: lanterns, autumn foliage, embers.

Our current look misses on exactly these three: flat colours, everything mid-to-bright (grass lum 122, walls 167), and an even sunny light.

## Measured palette

### Outdoor plaza (overcast daylight)
| Surface | Colour | lum | sat |
|---|---|---:|---:|
| Ground (concrete or sand) | (155,134,119) | 137 | 0.21–0.23 |
| Herringbone tile | (120,106,96), light patches (142,128,119) | 108–130 | 0.16–0.20 |
| Sky, overcast | (181,172,156) | 173 | 0.14 |
| Rock cliffs (slate and brown) | (45,38,39) to (46,32,26) | 35–40 | 0.16–0.43 |
| Wood stalls | (83,56,50) | 61 | 0.40 |
| Autumn foliage, rust-red pine | (63,44,21), (46,27,28) | 31–46 | 0.41–0.67 |
| Palm and green foliage | (34,33,23) | 32 | 0.32 |
| Orange ground accent | (133,87,57) | 95 | 0.57 |

### Caves (firelit interiors)
| Surface | Colour | lum | sat |
|---|---|---:|---:|
| Ceiling and walls, ambient | (23,21,22) to (26,23,26) | 21–24 | ~0.1 |
| Wall near a fire | (47,36,28) | 38 | 0.40 |
| Floor, unlit | (34,34,41) | 35 | 0.17 |
| Floor under the cool top light | (73,100,130) | 96 | 0.44 |
| Wood roof | (46,27,17) to (47,29,20) | 30–32 | 0.57–0.63 |
| Tile and sand floor by the forge | (61,39,24), (75,49,32) | 43–53 | ~0.6 |
| Fire | (192,63,7) to (240,82,5) | 86–110 | 0.96+ |

### Our game now, for comparison (eye level, after the 2026-10-03 lighting pass)
| Surface | Colour | lum | sat |
|---|---|---:|---:|
| Grass, sunlit | (93,136,64) | 122 | 0.53 |
| Grass, shaded | (51,96,41) | 82 | 0.57 |
| Castle walls, shaded | (167,168,163) | 167 | 0.03 |
| Roofs | (48,60,85) | 59 | 0.44 |
| Pines | (30,55,33) | 48 | 0.45 |

**Gaps:**
- Our walls are **4× brighter** than The Forge's darkest structures and still brighter than its ground.
- Our green is mid-bright and **uniform**. The Forge's ground is light and low-saturation, while its objects are dark and saturated.
- We have **no texture anywhere**, and **no warm local light**: the forge glow is the only light source we have.

## What this means for this game (an outdoor siege battlefield)
- **Ground:** textured, low-saturation and fairly light, in the concrete and sand family. Ours would be dry meadow (grass and dirt) at lum ~110–130 and sat ≤ 0.35, with real grass, dirt and gravel textures. Roblox voxel Terrain with grass, ground, mud and rock materials (built-in or custom MaterialVariant) gives this, plus blending and grass decoration.
- **Castles:** dark, textured stone around lum 60–90 (sunlit up to ~110). Slate or wood roofs around lum 30–40. All of it textured: a stone-brick MaterialVariant (box-projected, so it works on our UV-less meshes) on walls and towers, wood on doors, stalls and barricades, slate on roofs.
- **Nature:** keep the low-poly pines and rocks, but darker and deeper. Pines around lum 30–40; rocks lum 35–60 in slate grey-blue and brown with rock texture. Add autumn and rust accents to break up the green, as The Forge does.
- **Sky and light:**
  - Offer an **overcast warm-grey** daylight (sky ~(180,172,156), soft shadows) as the gritty default.
  - Keep the golden-hour sky as an option.
  - Interiors and tunnels go near-black, with warm torches and braziers.
  - Warm lanterns on gates and walls.
- **Grading:** lower overall exposure. Keep saturation in the darks: The Forge's woods and foliage are sat 0.4–0.67, so don't desaturate globally. Add a subtle contrast boost. Fire and lanterns use bloom.
- **Detail:** props and clutter (crates, barrels, braziers, banners, weapon racks) carry much of The Forge's richness; our field is empty.

## Revised recommendation
"Full realistic" (UV-mapped hero assets, photographic textures and sky) is **more than The Forge does** and would replace most of our art. Matching The Forge takes:
1. **Texture everything.** Use Roblox materials or MaterialVariants on the existing meshes; box projection means no re-modelling. Move the ground to voxel Terrain with grass, dirt and rock materials.
2. **Re-value the palette** to the numbers above: darker stone and wood, a lighter, low-saturation ground, deep foliage, slate rock.
3. **Overcast lighting** plus warm local lights and torch-lit interiors.
4. **Props pass** for richness.

That's Phase 1's proof-of-look patch, done on the existing assets, which is cheaper and closer to the target than a rebuild.

## Wording approved and applied 2026-10-03
**AGENTS.md §9, replacing the style block:**
> - Overall: grounded stylised in the family of *The Forge* (Roblox): low-poly shapes kept, but every surface textured (Roblox materials or MaterialVariants; Terrain for ground). Low-key values with saturated darks; light, low-saturation ground; warm light sources against cool shadow.
> - Castle: dark textured stone (lum ~60–110), slate or wood roofs (lum ~30–40), wooden doors and props with grain, warm lanterns, team banners.
> - Terrain: Roblox Terrain with textured dry grass, dirt, gravel and rock; grass decoration; slate-grey textured rock; deep-green and rust pines.
> - Lighting: overcast warm-grey daylight as default (golden-hour as an option); torch-lit, near-black interiors and tunnels.
> - Palette: measured in REALISM-TARGET.md. Max 8 colours per asset still applies to base colours, not texture detail.

**AGENTS.md §9 references:** add the three The Forge screenshots as the primary look reference, with castle-1 for silhouette only. Retire terrain-meadow and the concept image as colour targets, but keep the concept image for the island composition.

**DESIGN.md (Map and look):** one line recording the 2026-10-03 change of look direction toward The Forge's textured, low-key style, with the map, layout and gameplay unchanged.

## Phase 1 results (proof-of-look patch at Castle A's gate, 2026-10-03)
Built in Studio on the v2.0 battlefield import by `scripts/proof-of-look-gate.luau` (reversible: set `MODE = "revert"`). Lit by the new "Gritty" preset in `src/server/VisualQuality.server.luau` (Workspace attribute `WeatherPreset = "Gritty"`).

- **Ground:** voxel Terrain over x -364..-28, z -152..136 (84 x 72 columns). Heights sampled by raycast from the mesh ground it replaces: within 0.2 studs at the probes. Grass, leafy grass, bare-dirt patches, Ground road, Mud crater floors, Cobblestone courtyard. The 25 mesh cells, 2 crater collision sets and 4 grass-blade pieces underneath are hidden, not deleted.
- **Castle A courtyard and village paths:** plain light packed ground (Concrete terrain, lum 132-146 against The Forge's 137) with worn dirt patches, grass at the wall foot and mud round the forge. On it, one crisp-edged paving mesh (`assets/map/build_village_paths.py`, imported as `village_paths_A.fbx`, placed by `scripts/setup-village-paths-import.luau`): a main street from the gate to a small square before the Keep, a lane across the Keep front, and a branch to every door. The surface is an original herringbone texture (`assets/textures/build_herringbone.py`, MaterialVariant VillageHerringbone) and renders lum 103-112, sat ~0.19, against The Forge's tile at (120,106,96). Terrain could not do this: it blends materials across 4-stud voxels, so no crisp edge, and Brick terrain swells into mounds.
- **Castle A:** Cobblestone with a (170,170,175) colour multiply on the vertex colours. Barricades WoodPlanks; banners Fabric; tunnel mouths and cover rocks Rock; pines Grass texture.
- **Light:** an overcast warm-grey skybox (`assets/sky/build_sky.py`, `build("overcast")`, uploaded), soft sun, warm-grey fill; two braziers and two gate torches.

Eye-level samples from the gate view, against the targets above:

| Surface | Now | Target | Before Phase 1 |
|---|---|---|---|
| Sky | (189,177,155) lum 178 | (181,172,156) lum 173 | blue / golden |
| Castle walls | lum 87-95, sat 0.32 | lum 60-110 | lum 167, sat 0.03 |
| Roofs | lum 31-39 | lum 30-40 | lum 59 |
| Grass | lum 102-113, sat 0.37-0.39 | lum 110-130, sat <= 0.35 | lum 122, sat 0.53 (field next to the patch: lum 114, sat 0.74) |
| Dirt road | lum 122-131, sat 0.31-0.36 | ground lum 137, sat 0.22 | painted mesh |
| Pines | lum 32 | lum 30-40 | lum 48 |
| Rocks | lum 43 | lum 35-60 | blue-grey |
| Brazier-lit ground | (187,136,80) lum 143 | warm accents | none |

Checks:
- **Walking:** road through the gate into the courtyard; in and out of both craters (floor y ~5.7); across the east and north seams onto the old mesh ground. All passed. A walk across the courtyard stopped at the A_Carpenter building, as it should.
- **Performance:** in Play, 235 fps looking at the patch against 240 fps at the untouched half, with a worst frame of 6.6 ms. Client memory: GraphicsTerrain 36.8 MB, TerrainVoxels 0.7 MB, GraphicsTexture 110.7 MB.

Known gaps:
- Terrain grass decoration is off: `Terrain.Decoration` can't be set from scripts.
- Craters 1.5 deep barely read under flat overcast light.
- Patch edges show next to the old bright map; some grass-blade pieces overhang the north edge.
- Castle interiors are untouched (cream).
- No custom MaterialVariants yet: built-in textures only.
