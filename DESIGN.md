# Medieval Siege — game design (working v5, 2026-10-01)

This is the target game design for the two-team pivot. `AGENTS.md` holds working rules, the art pipeline, and tool instructions; `layout.json` holds implemented map coordinates. `MAP-REVISION-PROPOSAL.md` holds the approved preview coordinates until they are migrated into `layout.json`. The repository shows implementation progress, not design authority. `CLAUDE.md` and `README.md` contain older descriptions and must not override this design. A change to this document does not silently change `layout.json` or the game code.

**Status words:** **Decided** means the user chose it. **Placeholder** is a number or simple behavior to test and tune. **Open** requires a user answer before dependent gameplay or art is built. **Parked** means preserve existing work but do not extend it. The open list at the end is part of the spec, not permission for an agent to invent answers.

## Core concept

Two-team medieval siege on one static island. Red and Blue defend mirrored, pre-built castles. Players gather resources, bring them home, improve their team's equipment and defenses, then assault the enemy Keep. Combat is between players. A match is short and resets for the next queue. There are no AI troop regiments, player-built bases, persistent world, or cross-match resource losses. Raids can steal resources, while destroying the Keep wins the match.

## Art direction (decided)
- Overall style: stylized low-poly — chunky, faceted geometry with flat angled surfaces, not smooth/rounded default Roblox shapes. Exaggerated proportions, saturated flat color separation between materials. Closer to a fantasy-medieval low-poly asset-pack look than realistic or default-Studio terrain.
- Resource node identity follows Catan's approach: ground material can stay simple and consistent — a node's identity comes from a distinct built prop scene sitting on top of it, not from ground color alone:
  - **Wood** — a cluster of low-poly trees with chunky faceted round canopies. These are the ONLY round-canopy trees on the map; decorative trees are stacked-cone pines.
  - **Stone** — a jagged angular rock outcropping, distinctly lighter/grayer than Ore so the two read as different at a glance.
  - **Ore** — a mine entrance or exposed vein: dark rock with small embedded glinting chunks.
  - **Grain** — a golden wheat-stalk cluster or a strongly colored field patch.
  - **Wool** — a small fenced pasture with a few sheep models scattered in it.
- Castle: use the reference family and asset contract in `AGENTS.md` §§9–12. Round towers are faceted cylinders and cones, scaled to a 5-stud avatar. The current castle kit is a prototype; new Keep damage states, tunnel pieces, and any weapon change need their own approved asset tasks.
- **Decided 2026-10-01:** inside the castle walls, use a compact village-like arrangement of distinct small working buildings around paths and a courtyard. The user's Minecraft-village comparison describes the spatial feel, not art or trading mechanics to copy. The blacksmith's forge replaces the single shared workshop in the earlier interior sketch. Other specialist buildings and their exact positions need a revised interior proposal.
- **Ground terrain is part of the style, not just props.** Build it in Blender from `layout.json` and import static FBX tiles: a green island, faceted shoreline, and sea outside the playable area. Avoid Roblox SmoothTerrain for this look.

## Battlefield composition (approved for first in-game preview; layout migration pending)

- Use `concepts/roman-battlefield-mirrored-castles.png` as a composition reference. The two mirrored castles should be much more prominent relative to the visible field than they are in the current 102 × 102 ring layout. Their vertical silhouette must grow with their footprint so the towers do not become visually squat. Preserve enough open meadow around the road for meaningful gathering on home, middle, forward, and shared resource nodes. `MAP-REVISION-PROPOSAL.md` is approved for the first in-game preview; migrate it into `layout.json` before Blender terrain is rebuilt.
- One readable dirt road connects the two facing gates through the middle. Its painted/dirt edges may meander gently, while the traversable center line stays clear. Resource pads, trees, and fixed cover do not block the road or gate approaches.
- Shallow craters and small barricades are permanent battlefield cover. Players can crouch behind crater rims and barricades; each must provide actual sightline protection at avatar scale. Place them in mirrored pairs beside the road, with clear routes around them. Their exact footprints, heights, and positions belong in the revised layout proposal.
- The book-inspired battle scene is visual direction for terrain, castle presence, and atmosphere. Armies, elephant, and water cannon in the concept image are not automatically game assets or match mechanics.

## Match contract

- **Decided:** two fixed teams, Red and Blue; no player elimination or friendly fire. Players respawn on their own side after being knocked down. The pre-built castles and map reset between matches. Team size is **open** (6v6 placeholder).
- **Decided:** the terrain and castle positions are mirrored across `layout.json`'s x = 0 axis. The map stays static. Resource slots are mirrored; varying their active types per match is a later task.
- **Decided:** a team wins when the enemy Keep reaches 0 HP. The Keep can be damaged whenever an attacker reaches it; a gate or wall breach is not a prerequisite. Looting is a separate goal, not a win condition. A win ends the match and returns players to the lobby for the next match.
- **Placeholder:** 12–15 minute hard cap (the current code uses 13 minutes), 15-second lobby, 8-second knockdown. At timeout, compare remaining Keep HP, then total wall HP; an exact tie is a draw. Confirm this tiebreaker before implementing it against the new Keep.
- **Open:** whether gathering runs continuously or has a distinct opening phase; final team size; matchmaking and party behavior. `layout.json` has no shrinking zone. The old free-for-all zone is parked unless the user explicitly restores it.

## Resources and team economy

- **Working resource set:** Wood, Stone, Grain, Ore, Wool/Cloth. The code also carries Timber, Ingot, and Tonic from the old specialist economy. The final list, conversions, and which goods can be looted are **open**. Do not silently omit Grain or add the three refined goods to the live economy because they exist in code.
- **Decided:** gathering and foraging remain a meaningful part of the siege loop, including after the castles become visually larger. The map must retain reachable home, middle, forward, and shared resource areas off the central road. Nodes have finite supply, deplete when gathered, and regenerate on a curve that is fastest at moderate depletion. Mirrored slots give each side equal opportunities. Ore appears forward and in the shared center in the current approved layout. Whether gathering has a distinct opening phase is still open.
- **Decided 2026-10-01:** gathered goods are carried by the player, brought home, and deposited into one pooled team stockpile. Carried goods drop on death. The current instant deposit code is a gap, not the desired behavior. Carry limit, drop pickup rules, and deposit interaction are **open**.
- **Decided:** team resources pay for repairs, gear upgrades, and siege equipment during the match. Weapons cannot be bought with coins or other purchases. The crossbow is the next hand weapon. Costs and upgrade paths are **open**.
- **Decided 2026-10-01:** redesign stockpile looting without a one-time snapshot. The old 20% exposed-slice rule is superseded. Looting has diminishing returns: cumulative goods stolen should rise roughly logarithmically with sustained looting effort, so taking each later bundle of the same size requires more effort. A candidate tuning curve is `cumulative loot = K × ln(1 + effort / T)`; `K`, `T`, interaction pacing, and the unit of effort are **placeholders**, not approved balance. Loot must come from goods the defender actually holds, and every transfer subtracts exactly what it grants. A raider can loot by reaching the stockpile, including through the tunnel, without a gate or wall breach. Whether progress is shared by all raiders, whether loot must be carried out, and any protected reserve are **open**.

## Castle and assault

- **Decided:** each castle has one mirrored wall ring with individually identified wall sections, four corner towers, one gate with a separate door, one team stockpile, and a damageable Keep. Banners recolor for Red and Blue. The current `layout.json` still has a 102 × 102 ring and 19 wall sections. For the first in-game visual preview, the user approved `MAP-REVISION-PROPOSAL.md`'s 183.6 × 183.6 ring, 35 wall sections, centers at `x = ±280`, and facing gates at `x = ±188.2`. Migrate these approved coordinates into `layout.json` before generating art. The old 140 × 140 free-for-all ring remains obsolete.
- **Decided:** defenders can stand on tower tops via stairs or ladders. Gate, wall sections, towers, and Keep have independent HP and intact, damaged, and rubble looks. Repairable structures consume team resources and show timber scaffolding. Keep HP, whether it can be repaired, and exact damage thresholds are **open**; its destruction ends the match.
- **Decided:** the first playable siege includes a pre-built barracks and crafting-only blacksmith, alchemist, and carpenter specialists. The blacksmith works in a dedicated forge that takes the place of the shared workshop in the earlier interior proposal; it is the weapon-crafting and smelting location. The user is considering a fletcher for ranged gear, including crossbows; that addition is **open**, not yet part of the required roster. Specialist buildings should read as a compact village inside the walls. Ranks, specialist theft, negotiation, and Minecraft-style trading are not part of v1. The barracks' minimum function is team respawn with a courtyard exit; it adds no AI troop regiment. The specialists' exact output ownership, recipes, costs, crafting time, and interface are **open**. The stockpile is its own part inside the walls, not a room inside the Keep.
- **Gate route:** the widest entrance, opened by heavy player hits or a battering ram. The ram is built from team resources; more investment should yield more damage, but its recipe, scaling, movement, and counterplay are **open**.
- **Wall route:** destroying any wall section makes an entrance. Players can damage wall sections with hand tools, but this is deliberately inefficient. The battering ram can strike both gates and wall sections; its damage against each is **open**. Other dedicated siege tools may be designed later. A breach remains a gate door or wall section at 0 HP, even though a Keep can also be reached by tunnel.
- **Tunnel route:** one mirrored L-shaped, low-ceiling route per castle. The long leg begins at a concealed entrance outside the walls and runs toward the castle; the short leg turns into a forward part of the castle courtyard. It bypasses some open-field and gate fighting, but does not emerge beside the Keep or stockpile. The tunnel admits one traveler at a time, is crawl-only, slower than open-ground travel, and too narrow for a ram. Crawlers cannot fight while inside. Straight sections expose them to long-range fire and camping; the bend breaks a full-length sightline. Attackers must cross defended courtyard space to reach either objective. A tunnel raider who reaches the stockpile may loot without a gate or wall breach. Entrance, bend, exit, width, height, and travel-time placeholders require an approved `layout.json` revision before tunnel art or gameplay is generated.
- **Decided 2026-10-01:** park the planned movable siege cannon. A fixed castle ballista targets attacking players and siege tools, replacing the planned defensive cannon role. Whether a defender operates it, plus its placement, HP, rate of fire, ammunition, and cost are **open**. The old trebuchet and cannons remain parked. Ladders over the wall and personal vaults are later ideas.

## Legacy concepts — parked until redesigned for two teams

The following details describe the old free-for-all game. Their code and notes may remain for reference. They are not instructions to build these mechanics into the current siege. The v1 blacksmith uses a dedicated forge; other specialist stations and buildings await the village-like interior revision. Old rank, theft, negotiation, and villager systems stay parked.

### Old specialists

Old roles were blacksmith/armorer, alchemist, carpenter, farmer/miner, and merchants. The former theft, ranks, and rebellious flag assumed player-owned villages.
- Roles: **blacksmith/armorer** (battle weapons), **alchemist** (research), **carpenter** (siege equipment like trebuchets, plus castle building), **farmer/miner** NPCs (classic resource gathering). **Merchants**: randomly-occurring near castles, kept deliberately abstract for now.
- Specialists have investable skill rankings.
- Stealable: thief gets the specialist at a flat 85% efficiency (not scaled by skill level).
- Rebellious flag (player-set, hidden from raiders): **currently unresolved.** As designed, it has no real cost, meaning flagging everyone rebellious is strictly optimal — needs a fix before building. Two live options:
  - **(A) Standing efficiency tax:** flagged specialist works at reduced output at all times, whether stolen or not — simple, no RNG needed.
  - **(B) Standing defection risk:** flagged specialist keeps full efficiency, but carries an ongoing small chance of defecting/sabotaging even with no raid involved — this is the version that actually uses "probabilistic," but creates a passive background-monitoring feel similar to the decay mechanic that was already deliberately rejected elsewhere, so weigh that tension before picking it.
  - Pick one before building the rebellious flag.
- Spy variant (rebellious specialist, alternate outcome): reveals the base layout and the specific building they're held in, aiding the original owner's counter-raid.

### Old negotiation and reputation

Parked design. Written for player-vs-player theft in free-for-all; in a two-team match the negotiating parties are teams, which changes most of this.
- Theft of a specialist triggers negotiation between the two players, capped at a fixed number of rounds. The messenger cannot be refused outright (theft is deliberate, engagement is forced).
- Either side can escalate by killing the messenger — this enrages the killer's own troops and damages their reputation.
- Hitting the round cap with no resolution costs the thief, treated similarly to killing the messenger.
- **Important scope correction:** reputation is now within-match only. The original design had it persistent across sessions with recency-weighted decay — that assumed a persistent world, which no longer exists post-pivot. Reputation effects (mercenary availability, etc.) should reset with each new match.
- Bait (deliberately under-defending a location to lure a raid) is a real, later-stage feature — needs the base raid loop solid first.

## Cut or parked
- Persistent, no-wipe world.
- Cross-session/persistent faction reputation.
- Administrative distance decay from a faction capital.
- Player-vassals with real autonomy who can defect between factions.
- Resource node degradation as a check on compact monopolies.
- Free-for-all and last-squad-standing; player-built bases and villages; folding eliminated players into another team; AI troop regiments.
- Old trebuchet, defensive cannons, movable siege cannon, and tunnel collapse. Existing assets and code may remain dormant.
- No cross-match dominance; within-match snowball is untested — playtest.

## HUD and feedback target

Use `AGENTS.md` §8 as the HUD layout contract: HP and stamina top-left; minimap and match clock top-right; team resource counts bottom-left; contextual prompt bottom-center; team-named event feed bottom-right; full map on M. Leave top-center empty. No wall-breach feed messages, kill counters, elimination counters, or resource columns in Roblox leaderstats. Confirm the event feed contents and mobile thumb-zone layout before implementing the HUD update.

## Validation for the first playable siege

- In Studio Server & Clients mode, verify both teams see the same mirrored map, spawn at their own barracks, cannot hurt teammates, and can damage opponents. A knockdown returns the player to the correct side.
- Verify a player can gather, carry, drop on death, recover or lose a drop according to the chosen pickup rule, and deposit into the team pot. Every spend and loot transfer conserves goods. Test that each equal amount of later loot takes more effort, and that breaching, tunnel access, death, or swapping raiders cannot reset the curve contrary to the chosen rule.
- Verify gate, wall, tower, and Keep HP and state swaps; movement through opened routes; repairs and scaffolding; Keep destruction immediately ending the match; timeout handling; stockpile and castle reset before the next match.
- Test a match with 3–5 real people using placeholder art. Record first fight, first siege, stuck points, and whether players requeue without prompting. Do not design the tutorial from the scripted old-mode test.

## Open decisions blocking generation

1. **Castle and routes:** revise the enlarged castle interior as a compact village with the forge in place of the old shared workshop, separate locations for any other approved specialists, and clear routes between the Keep, stockpile, barracks, spawn points, tower access, ballista mounts, and tunnel exit; decide Keep HP and repair rule; ballista placement, HP, firing rules, and cost; hand-tool wall damage; ram damage, cost, and movement.
2. **Economy:** decide whether the proposed fletcher joins v1; final live goods, specialist output ownership, and recipes; loot-curve tracker scope and parameters, whether loot must be carried out, and any protected reserve; carry capacity, death-drop ownership/lifetime/pickup, stockpile deposit interaction, crafting time, and crafting interface.
3. **Match:** team size; timeout tiebreaker; opening farming phase versus continuous gathering; lobby/matchmaking/party behavior.
4. **Interface and feel:** event feed contents, mobile controls, the specific combat-fluidity complaint, audio, anti-cheat, tutorial after playtest, and identity/marketing assets.

An agent may implement independent, decided slices with placeholders where explicitly marked. It must stop at a dependent open decision instead of choosing one from old code, an asset, or a reference image.
