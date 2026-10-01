# Medieval Siege Game — Design Document (v3, post two-team pivot)

CLAUDE.md holds the pivot, locked decisions, map spec and working rules, and wins on map, match format, win condition and scope. This file keeps the design reasoning and the detail CLAUDE.md does not cover. Sections marked OUT OF SCOPE are parked design.

## Core concept
Two-team medieval siege on one static island. Two mirrored, pre-built castles. Each team gathers resources, turns them into power (wall repair, gear upgrades, siege weapons), then attacks the enemy castle while defending its own. Direct player combat; no AI troops, no player-built bases, no persistent world. Short matches with instant requeue. Loss should feel like Clash of Clans — painful, not a full Rust wipe: only the exposed part of the stockpile is ever at risk.

## Art direction (confirmed)
- Overall style: stylized low-poly — chunky, faceted geometry with flat angled surfaces, not smooth/rounded default Roblox shapes. Exaggerated proportions, saturated flat color separation between materials. Closer to a fantasy-medieval low-poly asset-pack look than realistic or default-Studio terrain.
- Resource node identity follows Catan's approach: ground material can stay simple and consistent — a node's identity comes from a distinct built prop scene sitting on top of it, not from ground color alone:
  - **Wood** — a cluster of low-poly trees with chunky faceted round canopies. These are the ONLY round-canopy trees on the map; decorative trees are stacked-cone pines.
  - **Stone** — a jagged angular rock outcropping, distinctly lighter/grayer than Ore so the two read as different at a glance.
  - **Ore** — a mine entrance or exposed vein: dark rock with small embedded glinting chunks.
  - **Grain** — a golden wheat-stalk cluster or a strongly colored field patch.
  - **Wool** — a small fenced pasture with a few sheep models scattered in it.
- Castle: see CLAUDE.md §9 (look) and §11 (pieces and budgets). Round towers are *faceted* cylinders and cones — low-poly, flat-shaded — never Roblox's smooth Cylinder part. Scale to a ~5-stud avatar, not a cinematic showpiece.
- **Ground terrain is part of the style, not just props.** It is built in Blender from layout.json and imported as static FBX tiles (CLAUDE.md §6, §12): an island with a faceted shoreline in a sea. SmoothTerrain is not used: it blends materials and cannot hold hard facets.

## Game mode: two-team siege (v1)
- Two teams, team vs team. Team size OPEN (6v6 placeholder).
- One static island, two mirrored castles, same terrain every match (CLAUDE.md §6). Node placement may vary per match later, mirrored between sides.
- Match: hard cap 12–15 min (placeholder). A castle is **breached** while its gate door or any wall section is destroyed, and it **falls** when it is breached AND its stockpile is emptied (decided; CLAUDE.md §4). "Emptied" is judged against a slice snapshotted once per match at the first breach, so repairs can't refill it. A fallen castle ends the match and the server goes back to the lobby. At the cap, highest total structure HP wins, then largest stockpile (placeholder).
- Individual players respawn in their own castle's barracks; there is no player elimination and no friendly fire.
- **The siege loop:** attackers break the gate door by hand or with a battering ram, or bring a siege cannon to knock down a wall section; defenders man the castle's cannons against attackers and siege engines, and rebuild whatever is knocked down (timber scaffolding shows while it goes back up). Once inside, attackers loot the king's storage in the keep.
- Shrinking zone: OPEN — built for free-for-all, likely cut (CLAUDE.md §15).
- Instant requeue after a match.

## Economy
- Catan-style resource set, medieval reskin, working default (not fully finalized): **Wood, Stone, Grain, Ore, Wool/Cloth.**
- Node slots come in mirrored pairs (CLAUDE.md §6.4), so both castles have equal access. Travel between node slots is still required.
- Gathered resources are spent in-match on repairs, gear upgrades and siege tools. Weapons come only from in-match resources, never from purchase. The crossbow is the next hand weapon. Siege tools — a battering ram and a movable siege cannon — are built at the castle's workshop; they replace the old trebuchet, which stays dormant.
- Node mechanics: finite stockpile per node, depletes on gathering, regenerates over time. Regen follows a curve — faster at moderate depletion, slower near full or near empty — not a flat rate.

## Castle (v1)
- One wall ring of 19 wall sections and 4 corner towers, and one gate — the only way in until a wall section comes down, so it is the real attack/defend commitment.
- Every gate door, wall section, tower, cannon, workshop and barracks has its own HP and three looks (intact, damaged, rubble). Defenders rebuild them with team resources; scaffolding shows while a piece goes back up. The keep cannot be destroyed. (CLAUDE.md §4, numbers in §5.)
- Inside the walls: the **king's keep**, whose storage holds the team's pooled stockpile; the **barracks**, where the team respawns; the **workshop/forge**, where siege tools are built; and **defensive cannons**, manned by defenders.
- Stockpile: a capped, exposed portion of held resources (~15–25%) is the actual raid target; the rest is safe. This is what makes losses sting without being a full wipe.
- One pooled stockpile per team, kept in the king's storage: everything the team gathers goes into it, and the exposed slice is taken from the pot (CLAUDE.md §4).
- Castles are pre-built; there is no build phase. The castle is made of separate named pieces so each can take HP and breach (CLAUDE.md §11). Village buildings and props wait until after a playtest.

## Specialists — OUT OF SCOPE for the pivot; code is dormant (CLAUDE.md §3). Do not build.
Parked design, written for free-for-all Conquest. Theft, ranks and the rebellious flag need rethinking for two fixed teams before any of it comes back.
- Roles: **blacksmith/armorer** (battle weapons), **alchemist** (research), **carpenter** (siege equipment like trebuchets, plus castle building), **farmer/miner** NPCs (classic resource gathering). **Merchants**: randomly-occurring near castles, kept deliberately abstract for now.
- Specialists have investable skill rankings.
- Stealable: thief gets the specialist at a flat 85% efficiency (not scaled by skill level).
- Rebellious flag (player-set, hidden from raiders): **currently unresolved.** As designed, it has no real cost, meaning flagging everyone rebellious is strictly optimal — needs a fix before building. Two live options:
  - **(A) Standing efficiency tax:** flagged specialist works at reduced output at all times, whether stolen or not — simple, no RNG needed.
  - **(B) Standing defection risk:** flagged specialist keeps full efficiency, but carries an ongoing small chance of defecting/sabotaging even with no raid involved — this is the version that actually uses "probabilistic," but creates a passive background-monitoring feel similar to the decay mechanic that was already deliberately rejected elsewhere, so weigh that tension before picking it.
  - Pick one before building the rebellious flag.
- Spy variant (rebellious specialist, alternate outcome): reveals the base layout and the specific building they're held in, aiding the original owner's counter-raid.

## Negotiation & reputation — OUT OF SCOPE for the pivot; code is dormant (CLAUDE.md §3). Do not build.
Parked design. Written for player-vs-player theft in free-for-all; in a two-team match the negotiating parties are teams, which changes most of this.
- Theft of a specialist triggers negotiation between the two players, capped at a fixed number of rounds. The messenger cannot be refused outright (theft is deliberate, engagement is forced).
- Either side can escalate by killing the messenger — this enrages the killer's own troops and damages their reputation.
- Hitting the round cap with no resolution costs the thief, treated similarly to killing the messenger.
- **Important scope correction:** reputation is now within-match only. The original design had it persistent across sessions with recency-weighted decay — that assumed a persistent world, which no longer exists post-pivot. Reputation effects (mercenary availability, etc.) should reset with each new match.
- Bait (deliberately under-defending a location to lure a raid) is a real, later-stage feature — needs the base raid loop solid first.

## Cut — do not build
- Persistent, no-wipe world.
- Cross-session/persistent faction reputation.
- Administrative distance decay from a faction capital.
- Player-vassals with real autonomy who can defect between factions.
- Resource node degradation as a check on compact monopolies.
- Free-for-all and last-squad-standing (replaced by two teams, CLAUDE.md §1).
- Player-built bases and villages (replaced by pre-built castles, CLAUDE.md §1).
- Folding eliminated players into another team (CLAUDE.md §2–§3: dormant).
- AI troop regiments (CLAUDE.md §1).
- No cross-match dominance; within-match snowball is untested — playtest.

## Open items
The live list is CLAUDE.md §15. Parked with the specialists: rebellious flag, option A vs B.
