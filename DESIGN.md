# Medieval Siege Game — Design Document (v2, post-Conquest-pivot)

This supersedes earlier persistent-world assumptions. If anything here conflicts with an older note elsewhere, this file wins.

## Core concept
Minecraft-style voxel building + Rust-style raiding, medieval reskin (castles, not forts), with base/economy management between raids and tactical live raiding as the driver that makes the economy matter. Loss should create distress out of proportion to the material value lost — Clash of Clans style, not a full Rust wipe. Armies persist after a raid loss.

## Game mode: Conquest (v1 — this is what gets built first)
- ~12 players, one generated map, one match, last player/team standing wins.
- Match length: full session, closer to Catan pacing (45–60 min) than a fast round.
- **Convergence mechanic:** the playable map shrinks over the match timer (battle-royale style). This does two jobs at once — it naturally increases resource scarcity late-game without scripted stockpile step-downs, and it forces surviving factions into contact so the match actually resolves inside the time window instead of stalling in mutual turtling.
- **Elimination condition:** walls breached + stockpile emptied + specialists lost, single-hit knockout. No lives/respawn system.
- **On elimination:** player is folded into a surviving team as a worker, chosen at random but *weighted toward smaller/weaker surviving teams* — not pure random, to avoid the leading team snowballing a free workforce every time anyone dies.
- Because the whole match runs in one server instance for its full duration, "raids are live siege combat, both sides present" is trivially true here — this was the exact problem the persistent-world version couldn't solve, and the bounded-match structure resolves it for free.
- Other modes (non-Conquest) are deliberately deferred, not designed yet.

## Economy
- Catan-style resource set, medieval reskin, working default (not fully finalized): **Wood, Stone, Grain, Ore, Wool/Cloth.**
- Resources and specialists are spread across the generated map, not clustered, so movement/expansion is required within a match.
- Node mechanics: finite stockpile per node, depletes on gathering, regenerates over time. Regen follows a curve — faster at moderate depletion, slower near full or near empty — not a flat rate.

## Base structure (v1)
- Perimeter wall, single HP value, one ring (no segments/tiers yet).
- One gate — single chokepoint, creates real attack/defend commitment.
- Stockpile: a capped, exposed portion of held resources (~15–25%) is the actual raid target; the rest is safe. This is what makes losses sting without being a full wipe.
- Village should be laid out and *dressed* with multiple distinct buildings (blacksmith, alchemist, etc.) now, visually — but only one building is functionally the stockpile until specialists (below) are actually built. Don't wire up per-building raid logic yet.

## Specialists — stretch goal, build after Conquest's core loop works
- Roles: **blacksmith/armorer** (battle weapons), **alchemist** (research), **carpenter** (siege equipment like trebuchets, plus castle building), **farmer/miner** NPCs (classic resource gathering). **Merchants**: randomly-occurring near castles, kept deliberately abstract for now.
- Specialists have investable skill rankings.
- Stealable: thief gets the specialist at a flat 85% efficiency (not scaled by skill level).
- Rebellious flag (player-set, hidden from raiders): **currently unresolved.** As designed, it has no real cost, meaning flagging everyone rebellious is strictly optimal — needs a fix before building. Two live options:
  - **(A) Standing efficiency tax:** flagged specialist works at reduced output at all times, whether stolen or not — simple, no RNG needed.
  - **(B) Standing defection risk:** flagged specialist keeps full efficiency, but carries an ongoing small chance of defecting/sabotaging even with no raid involved — this is the version that actually uses "probabilistic," but creates a passive background-monitoring feel similar to the decay mechanic that was already deliberately rejected elsewhere, so weigh that tension before picking it.
  - Pick one before building the rebellious flag.
- Spy variant (rebellious specialist, alternate outcome): reveals the base layout and the specific building they're held in, aiding the original owner's counter-raid.

## Negotiation & reputation — stretch goal, needs specialists first
- Theft of a specialist triggers negotiation between the two players, capped at a fixed number of rounds. The messenger cannot be refused outright (theft is deliberate, engagement is forced).
- Either side can escalate by killing the messenger — this enrages the killer's own troops and damages their reputation.
- Hitting the round cap with no resolution costs the thief, treated similarly to killing the messenger.
- **Important scope correction:** reputation is now within-match only. The original design had it persistent across sessions with recency-weighted decay — that assumed a persistent world, which no longer exists post-pivot. Reputation effects (mercenary availability, etc.) should reset with each new match.
- Bait (deliberately under-defending a location to lure a raid) is a real, later-stage feature — needs the base raid loop solid first.

## Explicitly cut by the Conquest pivot — do not build these, listed so they don't get confused with active scope
- Persistent, no-wipe world.
- Cross-session/persistent faction reputation.
- Administrative distance decay from a faction capital.
- Player-vassals with real autonomy who can defect between factions.
- Resource node degradation as a check on compact monopolies.
- These all assumed a world that persists between matches. Conquest is bounded and resets every match, so the problems these systems solved (checking long-term runaway dominance) don't apply — the shrinking zone now serves the "force resolution" role these were partly meant to play.

## Open items still needing a decision
- Exact final resource list (working default above, not locked).
- Rebellious flag: option A vs B above.
- Whether distance-based mechanics have any place on a single large generated map even without persistence (optional revisit, not blocking).
