# CLAUDE.md — Medieval Siege (Roblox)

Read this file and DESIGN.md before every task.

AUTHORITY: DESIGN.md still describes the OLD free-for-all game in places. Until DESIGN.md is updated, the PIVOT (sections 1, 3-5) wins over DESIGN.md on map, match format, win condition, and scope. On such a conflict: follow this file, name the DESIGN.md line that conflicts, and do NOT edit DESIGN.md unless the task says so. Working rules, the art pipeline, and tool notes live only in this file.
Anything marked (placeholder) is a working number, not a decision. Anything under OPEN needs the user's answer before you build on it.

---

## 1. Pivot record (2026-09-28)

Two-team medieval siege game. One static map with two mirrored castles, pre-built (no build phase). Each team gathers resources, converts them into power (wall repair, gear upgrades, siege weapons), then attacks the enemy castle and defends its own. Direct player combat. No AI troop regiments, no persistent world, no player-built bases. Short matches (12-15 min hard cap, placeholder) with instant requeue. Loss should feel like Clash of Clans: painful, not a full wipe.

Why: three research passes agreed that long last-man-standing matches lose players, while short respawn-based team matches with fast requeue keep them. Command An Army (12-player attack/defend team game, very large on Roblox) is a market benchmark for the genre, not a spec to copy. It uses AI squads and gacha collection, which this game deliberately does not.

What the pivot replaces: the 16-plot free-for-all island, player-built villages, last-squad-standing win, and the 45-minute match. What it keeps: the combat, wall breach, gate, theft/raiding core.

## 2. Repo status (from an audit on 2026-09-28; re-verify before relying on it)

- Built: combat, 8-second knockdown then return at your keep, wall breach, theft/raiding, gathering, a 15-second lobby phase, Hud.client.luau (435 lines, old spec), and a zone shrink over a 45-minute match.
- Built, and out of scope for the pivot: 16-plot island with player-built villages (ten purchases on an empty plot), MatchService last-squad-standing win, FoldWeighting.luau (eliminated players join a team), specialists (blacksmith, alchemist, carpenter, with outputs), a trebuchet (carpenter output, 55 damage to walls), NegotiationService, reputation score, cottages/shops/villagers/smoke.
- Old-map files: scripts/build-world.luau (~3,000 lines, builds the old island in Studio) and layout.old-island.json (old island export: 16 castles, no mirror axis, no team spawns, no lanes). layout.json is now the approved two-castle layout (2026-09-30; reasoning in LAYOUT-PROPOSAL.md).
- Stone: imported as Workspace.stone_node (80 tris) in the plaza. Not wired up as a resource node.
- Testing: only a scripted two-player test (15 checks). Never played by real people.
- Not built: two-team match flow, crossbow, tutorial, matchmaking/party queue, audio.
- Art built (2026-09-30): the two-castle terrain (assets/map, exported as map.fbx and imported into the place as Workspace.map; the old island is parked in ServerStorage.OldIsland, so the old scripts error in Play), and the castle kit in Blender (assets/castle/build_castle.py: Wall_Segment, Wall_Corner_Tower, Gate, Gate_Door, Stockpile, Banner on the 102 ring; not exported).
- Known mismatches with the HUD spec: resource counts live in leaderstats (all 8 goods), and messages show usernames.
- Known mismatch with the win condition (section 4): the stockpile is per player (the base owner's own counters); the 20% slice is re-snapshotted on every breach, so one repair plus one gate swing refills it; it reads as emptied at once for an owner holding under 5 of each good; and looting pays the raider the full slice even if the owner has since spent it, which creates resources. To be replaced by a later Track A task.

## 3. Existing-code policy (default; user may override)

Code that is out of scope for the pivot is DORMANT: do not delete it, do not extend it, do not build new work on top of it. Switch it off from the match flow with a config flag where a flag is a small change. If disabling something needs more than a small change, stop and ask. MatchService needs a two-team mode to replace last-squad-standing (that is a replacement, not dormant). Do not extend scripts/build-world.luau: the new map is an FBX import.

## 4. Locked decisions

- Two teams, team vs team (chosen to shorten match time). Not free-for-all.
- Pre-built castles. Build + battle + destroy cannot fit a short match.
- Map = two mirrored castles on one static island, sea around it. No individual plots or islands.
- Resources: Wood, Stone, Grain, Ore, Wool/Cloth (working default, not final; the code currently has 8 goods, 5 raw and 3 refined). Gathered resources are spent in-match on repairs, upgrades, and siege weapons.
- Resource nodes: finite supply that depletes as gathered; regenerates on a curve (faster when moderately depleted, slower near full or near empty).
- Weapons come from in-match resources only, never from purchase. Crossbow is the next hand weapon. Siege tools are built at the castle's workshop: a battering ram (hits the gate door only) and a movable siege cannon (bombards wall sections and towers). These replace the old trebuchet, which stays dormant. (Decided 2026-09-30.)
- Castle: a single wall ring of 19 wall sections, 4 corner towers and one gate. The gate is the only way in until a wall section is destroyed. Inside: the king's keep (holding the king's storage), barracks, workshop/forge, and defensive cannons. Only 15-25% of stored resources are exposed to raiders (code: 20%). (Structures decided 2026-09-30.)
- Structures: every gate door, wall section, tower, cannon, workshop and barracks has its own HP and three looks (intact, damaged, rubble), plus timber scaffolding while defenders rebuild it. Repairs cost team resources. The keep cannot be destroyed. (Decided 2026-09-30.)
- Cannons: fixed defensive cannons, manned by a defender, firing at attackers and siege engines. Destructible and rebuildable. (Decided 2026-09-30.)
- Stockpile: one pooled team stockpile per castle, kept in the king's storage inside the keep. Everything a team gathers goes into its castle's pot; the exposed share is taken from the pot. (Decided 2026-09-29; location 2026-09-30.)
- Breach: a castle is breached while its gate door or any wall section is destroyed. (Decided 2026-09-30.)
- Win condition: a castle falls when it is breached AND its stockpile is emptied. No keep stage, no specialists clause. A fallen castle ends the match; the match then resets to the lobby. (Decided 2026-09-29; end and reset 2026-09-30.)
- "Emptied" is stable: the exposed slice is snapshotted ONCE per match, at the castle's first breach. Repairs can close the wall again but never refill the slice. (Decided 2026-09-29.)
- Individual players respawn, at their own castle's barracks. No friendly fire.
- Team names replace usernames in any feed or message.
- Static FBX import, not EditableMesh.

## 5. Numbers

From the code (truth for gameplay): wall 600 HP, sword swing 20 damage (five hits to knock someone down), gate swing 25, 20% stockpile exposure, 8-second knockdown, 15-second lobby.
Placeholders: match cap 12-15 min with tiebreaker (highest total structure HP, then largest stockpile); raid timer 2-3 min; team size 6v6.
Structure placeholders (2026-09-30; tune in playtest): gate door 600 HP, wall section 300, tower 500, cannon 150, workshop 300, barracks 400; repair 25 HP for Wood 4 + Stone 4 (the code's current repair); battering ram 60 per hit on the gate door; siege cannon 55 per shot on walls and towers (the old trebuchet's number).
Castle and map dimensions: from layout.json (approved 2026-09-30): playable area 1,040 x 680, castle wall ring 102 x 102 (5 wall blocks of 20.4 per side), castle pad 118 x 118. The code still uses the old 148x148 plot and 140x140 ring (WALL_HALF = 70 is a half-width) until a Track A task changes it. Always read the numbers from layout.json, not from this file.

## 6. Map spec (layout-first)

The map is designed FROM a layout file, never the other way around. Decorative objects must not exist unless they trace to a layout entry or a rule below.

1. `layout.json` is the single source of truth, read by both Studio and Blender work. Units are studs. Ground plane is (x, z), height is y. Required contents: map_bounds, mirror axis, castles (id, team, center, gate position, gate facing), resource node slots (id, allowed types, position, mirror-pair id), spawn points per team, gate approach lanes, cover zones. The current layout.json (approved 2026-09-30) satisfies this; the old island export is layout.old-island.json, reference only.
2. FIRST layout task: PROPOSE dimensions and the full field list, and wait for approval before any terrain work. The proposal should say whether to keep the existing 140x140 ring or shrink it, with the reason.
3. Symmetry: mirror across the axis between the two castles. Both castles see the same map.
4. Node variation (build after the fixed layout works): node slots come in mirrored pairs. Each match, choose which slots are active and their types on one side and mirror to the other. Terrain stays static; only node placement varies. Later option, NOT now: randomly generate one half of the terrain and mirror it.
5. Rules for anything placed:
   - Flat pad under every castle and every node.
   - Keep each gate approach lane clear (no trees, rocks, or props).
   - Nothing decorative may be mistakable for a resource node. Wood nodes are the ONLY round-canopy faceted trees. Decorative trees are stacked-cone pines, only in edge belts and in cover clusters beside lanes (never in lanes, never on pads).
   - Island in a sea: sea surrounds the island, faceted shoreline, no water inside the playable area, no mountain ring. Players must not be able to leave the island: decide the boundary (invisible walls or a kill volume at the shore) in the layout proposal.
6. Coordinate conversion Roblox to Blender: (x, y, z) becomes (x, -z, y). Verify by placing a marker at the origin and one at a castle, then confirm in a screenshot.
7. Verification (required): top-down screenshot with layout markers overlaid. Every marker sits on a flat pad, every lane is clear. List every object that does not trace to layout.json or a rule above, then delete it.

## 7. Working rules

- ONE task per run. Finish, report, stop. Do not start the next asset or system.
- Two tracks that must not block each other: Track A gameplay (Claude Code in Studio), Track B art (Claude Code in Blender). Playtests use gray/placeholder art. Art never gates a playtest.
- Studio work = logic, placement from layout.json, wiring, HUD. Do NOT attempt aesthetic work in Studio (terrain sculpting, model appearance). Prior attempts there produced the ore box and dashed sheep pens.
- Never build visuals blind. Before any Blender visual task, confirm a viewport screenshot tool is available. If not, stop and tell the user.
- The user judges the look. Report differences against the references; do not declare "looks good."
- If the user proposes a new system, redesign, or scope beyond this file mid-task: finish the current task, append the idea to IDEAS.md, do not build it. If it is large, say so and ask.
- Do not polish before validation. No new systems before a real playtest. Placeholders stay placeholders until a playtest says otherwise.
- Verify claims about the repo by reading it. Do not assume a file or system exists or doesn't.

## 8. HUD spec

Hud.client.luau exists and follows the OLD spec. Changing it to this spec is a modification task, not a build task.

| Position | Element |
|---|---|
| Top-left | HP bar + stamina bar (sprinting) |
| Top-center | Empty on purpose, reserved |
| Top-right | Minimap; below it a match timer (replaces the old zone timer, confirm) |
| Bottom-left | Resource icons + counts, stacked vertically |
| Bottom-center | Context prompt ("E - Hold to gather"), only when relevant |
| Bottom-right | Event feed (contents TBD for two-team; uses team names) |

Rules: no wall-breach messages; no kill or elimination counters; M opens a large full map; Roblox built-in scoreboard is fine BUT resource counts must NOT appear on it (move them out of leaderstats; it also stops raiders reading who is rich); team names instead of usernames in messages; everything medium-sized and unobtrusive; respect mobile thumb zones. The old mockup still shows a "breached a wall" line: stale, omit it. Obsolete for two teams: teams-remaining counter, zone shrink (see OPEN).

## 9. Art direction

The target is the FAMILY of the reference images in /references/, not their texture detail. The style block below is the ONLY copy.

References (private reference only; never import, copy, or reproduce them). /references/ is gitignored. Files (renamed to these names 2026-09-29):
- terrain-meadow.jpg: PRIMARY ground target (soft green meadow, muted purple-grey faceted rock, blue haze, pines, long soft shadows). Ignore its mountains and lake: this map is an island in a sea.
- castle-1.jpg: castle target (warm grey stone, thick round towers, overhanging battlement band, tall conical dark-slate roofs, crenellations, banners, arched gate).
- castle-2.jpg: tower and roof shapes and colors only (city-scale; ignore its layout).
- village-cliff.png: faceted cliff bands, boulders, shoreline rocks.
- village-overhead.jpg: later village/props reference.

STYLE BLOCK
- Overall: stylized low-poly, chunky proportions, flat-shaded faces, warm and saturated, readable at a distance. Detail comes from silhouette and a few layered forms, not texture.
- Castle: warm light-grey stone. Tower = cylinder body, wider overhanging battlement band, tall conical dark-slate roof. Box crenellations on wall tops. Team-colored banners. Arched gate with wooden door. Suggest stonework with a few offset boxes per wall face, never per-brick modeling.
- Terrain: soft near-flat green ground. Rocks and shoreline cliffs hard flat-shaded facets, muted purple-grey. Cliff bands: bright grass top, olive-brown dirt side, grey rock below. Pines as stacked faceted cones on thin brown trunks. Sea: flat faceted grey-blue, outside the playable area only.
- Palette: SAMPLE actual colors from the reference images. PIL is not installed; use Blender's image loader or install Pillow. Max 8 flat colors per asset. Rough targets only: grass #7DAE3F, leaf #A5C93A (Wood-node canopies only), dirt #6B4A2B, stone #A9A79E, slate #4D5563, rock #6F7C8A, terracotta #C8542B, timber #6B3A22, plaster #E8DCB8, water #7A8794.
- Roblox lighting carries half the look. Before judging any art: Future lighting, Atmosphere, warm sun angle, light ColorCorrection, Bloom.
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
| Castle | SEPARATE named pieces so walls can have HP and breach: Wall_Segment, Wall_Corner_Tower, Gate, Gate door (own object), Stockpile, Banner (own object, recolorable per team). Assemble as a square wall ring, 4 corner towers, ONE gate, stockpile inside. Ring size comes from the approved layout.json. Walls ~12 tall, towers ~18 tall (placeholders). Towers up to ~3,000 tris, wall pieces at or under 1,500, reuse meshes. Gate wide enough for a 5-stud avatar. | Built in Blender after castle-1 (towers 27.6 to the battlement, 43.6 to the roof tip; walls 14.4); not exported |
| Castle interior | Keep (with the King_Storage room and a door), Barracks (team spawn inside), Workshop (forge + bench), Cannon (gun on a timber carriage, defensive), Battering_Ram, Siege_Cannon (movable), Scaffold. Positions come from layout.json. Same style, palette rules and budgets as the castle. | Phase 1, after the interior layout is approved |
| Damage states | `<Piece>_Damaged` and `<Piece>_Rubble` for Wall_Segment, Wall_Corner_Tower, Gate_Door, Cannon, Workshop, Barracks; Scaffold shown during repair. Same footprint as the intact piece so they swap in place. | Phase 1 |
| Terrain | Mirrored island built from layout.json (section 6). Tile chunks each under 15,000 tris. | To rebuild |
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

## 15. OPEN (ask before building on these)

- Existing out-of-scope code: section 3 default is dormant. User may choose strip instead.
- Tiebreaker at the match cap: highest total structure HP, then largest stockpile. Still a placeholder (section 5). The win condition itself is decided (section 4).
- Siege tool and cannon costs, cannon reload and ammo: not decided. Placeholders go in section 5 when they are first built.
- Team size (6v6 placeholder).
- Farming as a distinct opening phase, or continuous during the siege.
- Zone shrink: built for the free-for-all, likely obsolete with two fixed castles. Confirm cut.
- Final resource list (8 goods in code vs 5 here).
- Combat feel: the specific complaint.
- Tutorial (after playtest), audio, lobby/matchmaking/party queue, anti-cheat, game name/icon/thumbnail, weekly update plan.

## 16. Tool notes

- Editor: Cursor. Agent: Claude Code in the terminal. A .codex folder exists in the repo and is not used by this file.
- Blender: the community BlenderMCP (ahujasid, now published as mcp-for-blender) is the one in use. It provides code execution, viewport screenshots, and Poly Haven / Sketchfab / Poly Pizza search. NOT the official Blender Lab MCP (needs Blender 5.1+, no model generation). NOT the standalone RodinBridge panel (manual, unrelated to Claude Code).
- Paid or optional generators (Hyper3D Rodin, local ComfyUI + Hunyuan3D single-view workflow): only when the user asks.
- Files: CLAUDE.md, DESIGN.md, README.md, layout.json, /references/, ASSETS.md (CC-BY log), IDEAS.md (parked ideas).