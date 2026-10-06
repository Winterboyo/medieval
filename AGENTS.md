# AGENTS.md — Medieval Siege (Roblox)

Read this file and DESIGN.md before every task.

AUTHORITY: DESIGN.md is the current product design, including the 2026-10-01 Keep-win revision and the user's later answers. This file holds working rules, the art pipeline, and tool notes. `layout.json` v2.2 owns the approved exterior and mirrored interior coordinates. `CASTLE-INTERIOR-V2-PROPOSAL.md` records the approved measured interior; `MAP-PATHS-EXPANSION-PROPOSAL.md` records the approved longer field and twin ram routes. If an older statement below or in CLAUDE.md/README.md conflicts with DESIGN.md, follow DESIGN.md and name the conflicting line in the report. Do not edit DESIGN.md unless the task says so.
Anything marked (placeholder) is a working number, not a decision. Anything under DESIGN.md's Open decisions needs the user's answer before dependent work is built.

---

## 1. Pivot record (2026-09-28)

Two-team medieval siege game. One static map with two mirrored castles, pre-built (no build phase). Each team gathers resources, converts them into power (wall repair, gear upgrades, siege weapons), then attacks the enemy castle and defends its own. Direct player combat. No AI troop regiments, no persistent world, no player-built bases. Short matches (12-15 min hard cap, placeholder) with instant requeue. Loss should feel like Clash of Clans: painful, not a full wipe.

Why: three research passes agreed that long last-man-standing matches lose players, while short respawn-based team matches with fast requeue keep them. Command An Army (12-player attack/defend team game, very large on Roblox) is a market benchmark for the genre, not a spec to copy. It uses AI squads and gacha collection, which this game deliberately does not.

What the pivot replaces: the 16-plot free-for-all island, player-built villages, last-squad-standing win, and the 45-minute match. What it keeps: combat, wall breach, gate, and raiding. The 2026-10-01 revision in DESIGN.md replaces the 2026-09-29 breached-and-emptied win with a damageable Keep as the win target.

## 2. Repo status (from an audit on 2026-09-28; re-verify before relying on it)

- Built: combat, 8-second knockdown then return at your keep, wall breach, theft/raiding, gathering, a 15-second lobby phase, Hud.client.luau (435 lines, old spec), and a zone shrink over a 45-minute match.
- Built for the old mode and not a specification for the current siege: 16-plot island with player-built villages (ten purchases on an empty plot), MatchService last-squad-standing win, FoldWeighting.luau (eliminated players join a team), the old specialist system (blacksmith, alchemist, carpenter, with outputs), a trebuchet (carpenter output, 55 damage to walls), NegotiationService, reputation score, cottages/shops/villagers/smoke. New crafting-only specialists have been chosen for v1 but need their own two-team design.
- Old-map files: scripts/build-world.luau (~3,000 lines, builds the old island in Studio) and layout.old-island.json (old island export: 16 castles, no mirror axis, no team spawns, no lanes). `layout.json` v2.2 is the approved longer two-castle exterior with twin ram routes and the village-like interior geometry; `MAP-REVISION-PROPOSAL.md`, `CASTLE-INTERIOR-V2-PROPOSAL.md`, and `MAP-PATHS-EXPANSION-PROPOSAL.md` record the reasons and measurements. The v2.2 FBX files have been exported from Blender but are not verified in Studio; gameplay remains unbuilt.
- Stone: imported as Workspace.stone_node (80 tris) in the plaza. Not wired up as a resource node.
- Testing: only a scripted two-player test (15 checks). Never played by real people.
- Two-team core (Phase 2, 2026-09-30): src/shared/GameMode.luau switches TwoTeam on (Conquest code dormant behind it). CastleService builds both castles, team spawns, 16 nodes and the boundary from layout.json as grey placeholders; Teams "Red"/"Blue" hold the pooled goods (counterFor reads them; no leaderstats); no friendly fire; 13-min match, old structure-HP/stockpile tiebreaker, castle Fallen ends it, back to the lobby with castles rebuilt and stockpiles emptied. Structures have HP attributes but take no damage yet. The Keep has no HP in the two-team castle code.
- Rojo/luau executables are blocked by Windows Application Control in Codex's sandbox; Studio was synced over MCP with checksums against the repo. ServerStorage.Layout in Studio is a JSONDecode copy of layout.json until Rojo maps the file.
- Not built: crossbow, tutorial, matchmaking/party queue, audio.
- Art built (2026-09-30): the two-castle terrain (assets/map/map.fbx, reported imported into Studio as Workspace.map) and a castle kit (assets/castle/castle_kit.fbx). The kit includes pieces and states from the older interior plan; importing and verifying it in Studio is not established by the repo.
- Known HUD mismatch: the current TwoTeam HUD shows team goods but retains the old top-center clock and village panel layout; messages still include usernames. Resource counters are on Teams.Goods, not leaderstats in TwoTeam mode.
- Known siege mismatch: ResourceService's active attack, breach, loot, and repair targets are still the old BuildSites bases. The new Workspace.Castles pieces do not yet take damage; pooled goods go straight to Teams.Goods rather than being carried and deposited. The old loot path can re-snapshot or overpay, but it does not currently operate on the new castles.
- The old 15-check two-player harness returns immediately in TwoTeam mode. No two-team multiplayer validation or real-player playtest is recorded.

## 3. Existing-code policy (default; user may override)

Code that is out of scope for the pivot is DORMANT: do not delete it, do not extend it, do not build new work on top of it. Switch it off from the match flow with a config flag where a flag is a small change. If disabling something needs more than a small change, stop and ask. The user has now chosen specialists for the first playable two-team siege, but the old player-village specialist, theft, and negotiation code is not its specification. Redesign that system from DESIGN.md's open decisions before connecting it. Do not extend scripts/build-world.luau: the new map is an FBX import.

## 4. Current design pointer

Read DESIGN.md for the complete match, economy, castle, weapon, and scope decisions. The latest chosen direction is two fixed teams on one mirrored island; pre-built castles; gathered goods carried by each player to craft directly at a specialist or optionally deposit in one team stockpile inside the Keep; a cargo bag spawned immediately on knockdown whose contents either team can ransack within its own carry limit, without moving the bag; a damageable Keep whose destruction wins; a tunnel route; barracks and four separate village-like specialist buildings (blacksmith forge, fletcher, carpenter, alchemist); hand-tool wall damage that is inefficient; a ram for gates and walls; and a fixed defensive ballista. The old siege cannon, defensive cannon, trebuchet, free-for-all villages, and last-squad-standing win are parked. `layout.json` v2.2 expresses the approved interior geometry; its Blender meshes are exported but need Studio verification, and gameplay remains unbuilt. Team names replace usernames in feeds and messages. Static FBX import remains the art method.

## 5. Numbers

Current code numbers, not final balance: sword swing 20 damage, gate swing 25, 8-second knockdown, 15-second lobby, 13-minute TwoTeam match, 20% stockpile exposure. The new castle placeholders have gate door 600 HP, wall section 300, tower 500, cannon 150, workshop 300, barracks 400; they do not yet take damage. Keep HP and ballista stats are open. The first-playtest mixed material bag uses 24 load points: Wood and Wool 1 each, Stone 2, Ore and Smelted Iron 4 each (tunable placeholders). One Ore smelts into one Iron; both are lootable and carry the same load. Ransacking a death bag takes a 2-second stationary hold canceled by movement or damage; the bag expires within 30 seconds of appearing without timer refresh (not implemented). Old player-built-base code also contains a 600-HP wall, 25-HP repair for Wood 4 + Stone 4, and siege-cannon values; do not transfer those silently.
Current approved exterior dimensions in `layout.json` v2.2 are playable area 1,560 × 680, castle ring 183.6 × 183.6, castle pad 200 × 200, and centers at x = ±420. Two 18-stud ram routes connect the gates. `MAP-REVISION-PROPOSAL.md` records the earlier castle enlargement; `MAP-PATHS-EXPANSION-PROPOSAL.md` records the 2026-10-03 field expansion. The approved interior has a 44 × 44 Keep, an 18 × 12 stockpile room inside it, a barracks, four specialist buildings, and clear routes. `CASTLE-INTERIOR-V2-PROPOSAL.md` records the local measurements. Do not read dimensions from the old 148 × 148 plot, 140 × 140 ring, or the superseded 102 × 102 ring. See DESIGN.md for placeholder and open gameplay numbers.

## 6. Map spec (layout-first)

The map is designed FROM a layout file, never the other way around. Decorative objects must not exist unless they trace to a layout entry or a rule below.

1. `layout.json` is the source of truth for approved coordinates. Units are studs. Ground plane is (x, z), height is y. Its v2.2 exterior includes the enlarged castles, two ram routes, crouch cover, and L-shaped tunnel endpoints approved in `MAP-REVISION-PROPOSAL.md` and `MAP-PATHS-EXPANSION-PROPOSAL.md`. Both castle `interior` entries contain the approved village layout and stockpile room inside the Keep from `CASTLE-INTERIOR-V2-PROPOSAL.md`. Do not reuse the 2026-09-30 storage room coordinates, cannon, or workshop placement from old files or meshes. The old island export is `layout.old-island.json`, reference only.
2. The first layout proposal in `LAYOUT-PROPOSAL.md` shrank the old ring from 140 × 140 to 102 × 102; `MAP-REVISION-PROPOSAL.md` later enlarged it to 183.6 × 183.6; `MAP-PATHS-EXPANSION-PROPOSAL.md` then expanded the field while retaining that ring. New layout changes require their own proposal and approval before terrain or castle art is rebuilt.
3. Symmetry: mirror across the axis between the two castles. Both castles see the same map.
4. Node variation (build after the fixed layout works): node slots come in mirrored pairs. Each match, choose which slots are active and their types on one side and mirror to the other. Terrain stays static; only node placement varies. Later option, NOT now: randomly generate one half of the terrain and mirror it.
5. Rules for anything placed:
   - Flat pad under every castle and every node.
   - Keep each gate approach lane clear (no trees, rocks, or props).
   - Nothing decorative may be mistakable for a resource node. Wood nodes are the ONLY round-canopy faceted trees. Decorative trees are stacked-cone pines, only in edge belts and in cover clusters beside lanes (never in lanes, never on pads).
   - Island in a sea: sea surrounds the island, faceted shoreline, no water inside the playable area, no mountain ring. The approved boundary is an invisible wall on the beach plus a kill height safety net.
6. Coordinate conversion Roblox to Blender: (x, y, z) becomes (x, -z, y). Verify by placing a marker at the origin and one at a castle, then confirm in a screenshot.
7. Verification (required): top-down screenshot with layout markers overlaid. Every marker sits on a flat pad, every lane is clear. List every object that does not trace to layout.json or a rule above, then delete it.

## 7. Working rules

- ONE task per run. Finish, report, stop. Do not start the next asset or system.
- Two tracks that must not block each other: Track A gameplay (Codex in Studio), Track B art (Codex in Blender). Playtests use gray/placeholder art. Art never gates a playtest.
- Studio work = logic, placement from layout.json, wiring, HUD. Do NOT attempt aesthetic work in Studio (terrain sculpting, model appearance). Prior attempts there produced the ore box and dashed sheep pens.
- Never build visuals blind. Before any Blender visual task, confirm a viewport screenshot tool is available. If not, stop and tell the user.
- The user judges the look. Report differences against the references; do not declare "looks good."
- If the user proposes a new system, redesign, or scope beyond this file mid-task: finish the current task, append the idea to IDEAS.md, do not build it. If it is large, say so and ask.
- Do not polish before validation or add unsolicited systems. The user's 2026-10-01 choice to include workshop specialists in the first playable siege is an explicit scope exception; define their two-team behavior before implementation. Placeholders stay placeholders until a playtest says otherwise.
- Verify claims about the repo by reading it. Do not assume a file or system exists or doesn't.

## 8. HUD spec

Hud.client.luau exists and follows the OLD spec. Changing it to this spec is a modification task, not a build task.

| Position | Element |
|---|---|
| Top-left | HP bar + stamina bar (sprinting) |
| Top-center | Empty on purpose, reserved |
| Top-right | Minimap; below it a match timer (replaces the old zone timer, confirm) |
| Bottom-left | Resource icons + counts, stacked vertically; distinguish personally carried goods from deposited team stockpile goods |
| Bottom-center | Context prompt ("E - Hold to gather"), only when relevant |
| Bottom-right | Event feed (contents TBD for two-team; uses team names) |

Rules: no wall-breach messages; no kill or elimination counters; M opens a large full map; Roblox built-in scoreboard is fine BUT resource counts must NOT appear on it; team names instead of usernames in messages; everything medium-sized and unobtrusive; respect mobile thumb zones. The old mockup still shows a "breached a wall" line: stale, omit it. Obsolete for two teams: teams-remaining counter and zone shrink.

## 9. Art direction

The target is the FAMILY of the reference images in /references/. The style block below is the ONLY copy. Direction changed 2026-10-03 (user-approved) from flat stylised low-poly to the textured, low-key look of *The Forge*; measurements and reasoning are in REALISM-TARGET.md.

References (private reference only; never import, copy, or reproduce them). /references/ is gitignored. Files (renamed to these names 2026-09-29):
- "Screenshot 2026-10-03 192433.png", "Screenshot 2026-10-03 192103.png", "Screenshot 2026-10-03 192052.png" (The Forge, Roblox): PRIMARY look reference since 2026-10-03: textured surfaces, low-key values with saturated darks, overcast daylight, firelit interiors. Palette numbers in REALISM-TARGET.md.
- castle-1.jpg: castle SILHOUETTE only (thick round towers, overhanging battlement band, tall conical roofs, crenellations, banners, arched gate). No longer a colour target.
- terrain-meadow.jpg: retired as a colour target (2026-10-03); pine and rock shapes only.
- concepts/roman-battlefield-mirrored-castles.png: island COMPOSITION only (castle prominence, cliffs, pines at the edges); not a colour target.
- castle-2.jpg: tower and roof shapes and colors only (city-scale; ignore its layout).
- village-cliff.png: faceted cliff bands, boulders, shoreline rocks.
- village-overhead.jpg: later village/props reference.

STYLE BLOCK
- Overall: grounded stylised in the family of *The Forge* (Roblox): low-poly shapes kept, but every surface textured (Roblox materials or MaterialVariants; Terrain for ground). Low-key values with saturated darks; light, low-saturation ground; warm light sources against cool shadow.
- Castle: dark textured stone (lum ~60-110), slate or wood roofs (lum ~30-40), wooden doors and props with grain, warm lanterns, team banners. Tower = cylinder body, wider overhanging battlement band, tall conical roof; arched gate.
- Terrain: Roblox Terrain with textured dry grass, dirt, gravel and rock; grass decoration; slate-grey textured rock; deep-green and rust pines (stacked faceted cones). Sea outside the playable area only.
- Lighting: overcast warm-grey daylight as default (golden-hour as an option); torch-lit, near-black interiors and tunnels.
- Palette: measured in REALISM-TARGET.md; SAMPLE actual colors from the references (Blender's image loader; PIL is not installed). Max 8 colours per asset still applies to base colours, not texture detail.
- Roblox lighting carries half the look. Before judging any art: Unified Lighting with LightingStyle Realistic (Lighting.Technology no longer exists), Atmosphere, the weather preset in src/server/VisualQuality.server.luau, ColorCorrection, Bloom.
- Aim for the same family now, not a 1:1 match. Fine detail is the user's hand-refinement pass.

## 10. Asset run contract (Blender)

Method: community BlenderMCP, `execute_blender_code` only. Do NOT use Rodin/Hyper3D, Hunyuan3D, Sketchfab, or other generators unless the task says so.
Every asset task follows this:
1. Read this file, DESIGN.md, and open the relevant /references/ images.
2. Confirm a viewport screenshot tool exists (else stop).
3. Build the ONE named asset (or one named group). Objects have clear names.
4. Screenshot front, side, top, 3/4, and one at avatar eye level next to a 5-stud dummy. Compare each to the references and list the differences.
5. Fix and re-screenshot. MAX 3 rounds. Then stop.
6. Report triangle count per piece, object names, and remaining differences.
7. Export FBX only if the task says so.
Do NOT: touch any other object, run past 3 rounds, hand-wave palette (sample it), or begin the next asset.
Scale: 1 Blender unit = 1 stud. Avatar is 5 studs tall.

## 11. Asset specs

Default budget: props at or under 1,500 triangles unless noted. Flat shading. Per-face color attributes.

| Asset | Description | Status |
|---|---|---|
| Stone | Light-grey jagged outcrop, low and squat, waist-to-shoulder height. Faceted planes. Must read clearly different from Ore. | Imported as Workspace.stone_node (80 tris); not wired as a node. The ~1,000-tri target was a guess; the user decides if 80 is enough. |
| Grain | Golden stalk clump | Redo wanted |
| Ore | Dark rock or mine mouth with glinting chunks; clearly different from Stone | Redo wanted (currently a dark box) |
| Wood | Faceted round-canopy tree cluster (the only round-canopy tree) | Fine for now |
| Wool | Fenced pasture with sheep | Fine for now |
| Castle | Separate named Wall_Segment, Wall_Corner_Tower, Gate, Gate_Door, Stockpile, damageable Keep, and team-recolorable Banner pieces. The approved 183.6 × 183.6 ring is in `layout.json` v2.2. The gate fits a 5-stud avatar. Towers up to ~3,000 tris and wall pieces at or under 1,500, with reused meshes. | The exterior assembly is exported in `assets/map/battlefield_v2_2.fbx`; Studio import and playability are unverified. |
| Castle interior | Barracks with team spawns; four small specialist buildings around a courtyard (blacksmith forge, fletcher, carpenter, alchemist), with the forge replacing the old shared workshop; a distinct stockpile room inside the Keep; one tunnel exit per castle far from the Keep entrance and stockpile interaction; fixed defensive ballista; battering ram. Approved positions are in `layout.json` v2.2, with local measurements in `CASTLE-INTERIOR-V2-PROPOSAL.md`. | Mirrored interior meshes were exported as `assets/castle/castle_interiors_v2_2.fbx`; Studio import and playability are unverified. |
| Damage states | Intact, Damaged, Rubble for the gate door, wall sections, towers, and Keep; Scaffold during repair. Workshop, barracks, ballista states follow their final gameplay rules. Same footprint for swappable states. | Older states exist for walls, towers, gate door, cannon, workshop, and barracks; Keep states and ballista are missing. |
| Terrain | Mirrored island built from layout.json; tile chunks each under 15,000 tris. Tunnel endpoints are in `layout.json` v2.2; walkable tunnel geometry still needs a terrain task. | `assets/map/battlefield_v2_2.fbx` contains the longer field, twin paths, grass, coast, and exterior castle walls. Studio import is unverified; walkable tunnel geometry is absent. |
| Fallen bag | The ransackable cargo sack dropped at knockdown (DESIGN.md "fallen cargo"): `FallenBag_Sack` + `FallenBag_Rope`, origin at the bottom centre, open mouth left empty. User direction 2026-10-06: later versions show Wood, Ore, Stone and Wool in the mouth as the bag fills; until then, just the bag. | Built 2026-10-06 in `assets/fallen-bag/fallen_bag.blend` (364 tris, 2.4 × 2.0 × 1.8 studs); not exported or imported. |
| Later | Cart, barrel, fence, well, half-timbered houses | After playtest |

## 12. Roblox import checklist

- FBX, static. Split meshes under 20,000 triangles (aim under 15,000).
- Set MeshPart.Color to white so vertex/face colors show.
- CollisionFidelity: Box or Hull for simple props. PreciseConvexDecomposition only for walkable slopes or complex terrain.
- Test ONE tile or asset in Studio first: colors, scale next to a 5-stud avatar, walkability. Only then export the rest.
- Readability check at normal gameplay camera distance.

## 13. Validation

- Studio Test, Server & Clients mode, checks networking. It does not tell you if the game is fun. The scripted 15-check test is not a playtest either.
- Real playtest: 3-5 real people, placeholder art fine, scale team size to testers. Watch behavior, not opinions: do they requeue unprompted, where do they get stuck, when is the first fight.
- Design the tutorial from observed stuck points after a playtest, not before.
- Benchmarks: D1 retention about 12% or higher; average playtime of 1-6 minutes means the loop is broken.
- "Not fluid" must be named specifically before it is fixed (input lag, hit feedback, slow gathering, floaty movement, other).

## 14. Hard rules

- Coins never buy anything that affects gameplay. Allowed: coins, cosmetic battle pass, VIP (1.25x coins and EXP; EXP is display only), rewarded video ads in lobby or post-match only. No mid-match ads.
- Any third-party asset must be CC0 or CC-BY; log CC-BY in ASSETS.md; never NC or editorial licenses.
- Check free Toolbox models for hidden scripts (loadstring, HttpService, unfamiliar require).
- Do not import or reproduce copyrighted game art.

## 15. OPEN (ask before dependent work)

The live design questions are in DESIGN.md's **Open decisions blocking generation** section. In particular, do not treat the old cannon, siege cannon, stockpile, Keep, or specialist values in code and art as answers. The old shrinking zone is parked; `layout.json` sets `zone` to null. Existing out-of-scope code remains dormant under section 3 unless the user explicitly changes that policy.

## 16. Tool notes

- Editor: Cursor. Agent: Codex in the terminal. A .codex folder exists in the repo and is not used by this file.
- Blender: the community BlenderMCP (ahujasid, now published as mcp-for-blender) is the one in use. It provides code execution, viewport screenshots, and Poly Haven / Sketchfab / Poly Pizza search. NOT the official Blender Lab MCP (needs Blender 5.1+, no model generation). NOT the standalone RodinBridge panel (manual, unrelated to Codex).
- Paid or optional generators (Hyper3D Rodin, local ComfyUI + Hunyuan3D single-view workflow): only when the user asks.
- Files: AGENTS.md, DESIGN.md, README.md, layout.json, /references/, ASSETS.md (CC-BY log), IDEAS.md (parked ideas).
