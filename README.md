# Medieval Land

Roblox game, built in tiers. See the tier order in
`~/.claude/projects/C--Users-winter-projects-medieval-land/memory/tier-build-order.md`.

**`DESIGN.md` is the authority on scope.** It is v2, post-Conquest-pivot, and it
says so itself: if anything here conflicts with an older note, the doc wins.

**Where this is:** a Catan board filling the whole map, five raw resources and
three refined ones, villages built from an empty field in ten purchases, a
three-stage siege, knockdown instead of respawn, and the Conquest match clock
with its shrinking zone.

**Reputation is no longer next.** The doc moves it under "Negotiation & reputation
— stretch goal, needs specialists first" and corrects it to within-match only.
The persistent, recency-weighted version is explicitly cut.

**Two things already built now contradict the doc** and need revisiting: combat
still has death and respawn where the doc specifies a single-hit knockout with
elimination by base state; and the Conquest match structure (timer, shrinking
zone, folding eliminated players into surviving teams) does not exist at all.

**T3 and the combat half of T4 have never been run with two players.** Everything
solo-testable is verified and the numbers are below; everything that needs a
second person is not. Treat those parts as written, not working.

## Layout

| Path | What |
|---|---|
| `src/server/ResourceService.server.luau` | Nodes, tools, bases, raiding, reputation. Rojo syncs it. |
| `src/server/MatchService.server.luau` | The Conquest clock, the zone, squads and the win condition. |
| `src/server/FoldWeighting.luau` | Pure maths for dealing an eliminated player to a squad. |
| `rokit.toml` | Toolchain: Rojo, plus `luau` for checking scripts without Studio. |
| `scripts/build-world.luau` | Builds the board: terrain, tiles, all five node kinds, build sites, the four tools, lighting. Rojo syncs it to `ServerStorage.BuildWorld`; rebuild from the command bar with the clone snippet below (a plain `require` returns a cached, stale module). Re-runnable — it tears down what it built last time. |
| `src/client/Notifications.client.luau` | Per-player notices, driven by the `Notify` RemoteEvent. |
| `default.project.json` | Rojo's map from this repo into the DataModel. |
| `rokit.toml` | Pins the toolchain (Rojo 7.7.0) so it is reproducible. |

The published experience on Roblox is the artifact. This repo is the source. A
local `.rbxl` is a working copy and is gitignored — it goes stale the moment you
publish, and a binary that contradicts the source sitting next to it is worse
than no binary at all.

## Working on it

Install the toolchain once, on a new machine:

```
rokit install          # gets Rojo at the pinned version
rojo plugin install    # installs the Rojo plugin into Studio
```

Then, every session:

```
rojo serve
```

Open the place in Studio, hit the Rojo plugin's **Connect**, and `src/` syncs
live on every file save. Edit here, not in Studio.

**`ServerScriptService` is a mirror of `src/server/`.** Rojo is not set to ignore
unknown instances there, so a Script you create by hand in Studio will be deleted
on the next sync. That is the point — it is what stops the two copies drifting.

### What Rojo does not cover

`default.project.json` maps `ServerScriptService`, `ReplicatedStorage.Remotes`,
`StarterPlayer.StarterPlayerScripts` and `ServerStorage.BuildWorld` — and nothing
else. Workspace, Terrain, Lighting and StarterPack are deliberately unmapped, so
Rojo will not touch them.

That is a limit, not laziness. Terrain is binary voxel data and cannot be
live-synced at all. And the world is *generated* — the palms, the outcrops, the
build sites and the pickaxe are the output of a script, not files on disk. Rojo
syncs static instance trees from files; it does not run generators. Freezing the
output into an `.rbxmx` would trade a readable generator for a binary blob.

So the split is: the thing that changes every session (the scripts) syncs
automatically; the thing that changes rarely (the world) stays a deliberate
one-shot, triggered by hand from `ServerStorage.BuildWorld`.

## The board

A 7×7 grid of **200-stud** square tiles. 7 × 200 = 1400 against a 1440 map, so the
board *is* the world — there is no surrounding countryside and no lake. It is
dead flat, because relief would fight the grid and bury nodes.

The tiles have grown twice: 72 → 160 → 200. The last step is not really about the
tiles, it is about what sits on their corners. Villages are built room by room
and you walk *inside* the buildings, so a plot is 148 studs across; on a 160 tile
neighbouring plots very nearly touched.

The layout is fixed rather than shuffled, so the map is a place you can learn:

```
F P G H M F P      F forest / Wood      H hills / Stone
G M H F P G H      P pasture / Wool     M mountains / Ore
P F M G H M F      G fields / Grain     V the totem plaza
H G P V F P G
M H F P G H M
F P G M H F P
G M H F P G M
```

Six terrain materials, one per tile kind, because a tile you cannot identify from
ground level is just coloured floor. **One node per resource tile** — a tile *is*
its node. 48 nodes: 10 Wood, 10 Wool, 10 Grain, 9 Stone, 9 Ore.

### The seams

The tiles used to be separated by sandstone kerbs, which made the board read as a
diagram rather than a place. The grid still has to be legible — knowing which
tile you stand on is what tells you what grows here — but a border between two
tiles should look like ground meeting ground.

So every interior border is broken up with overlapping patches of **both**
neighbours' materials, thrown to alternating sides of the line, so the two bite
into each other and the boundary comes out ragged instead of ruled. Measured
across one 160-stud seam: 8 material changes, where a ruled line gives 0–1.

Patches are square and randomly turned rather than round. A filled *ball* would
have to be sunk so deep to avoid doming above the surface that it would barely
tint the ground you actually walk on — its intersection with the surface plane
shrinks to a point exactly as it gets big enough to matter.

### The totem

The centre is a **totem**, not a spawn pad: a landmark tall enough to navigate by
from most of the board, standing on the one point the closing zone converges
toward. A ring of standing stones marks the plaza.

Spawning did not disappear with the pad, it moved *off* the centre — eight small
pads ringing the plaza, flush with the ground. The engine picks between them,
which spreads twelve arrivals out instead of stacking them on one square, and it
keeps the fallback `reviveAt` leans on when a knocked-down player has no keep
left to return to.

**A village plot on every interior tile corner** — the Catan settlement spots —
minus the ring around the totem, so nobody spawns straight into somebody's keep.
16 of them.

## Specialists

`DESIGN.md` files specialists as the stretch goal to build once Conquest's core
loop works. It does, so they are in — minus the **rebellious flag** and the **spy
variant**, which the doc itself says need a decision first and which Winter has
deferred, and minus **merchants**, which the doc keeps deliberately abstract.

**A specialist is per player, not per building.** You hold at most one of each
role; the workshop is what lets you *use* them. That is what makes stealing one
coherent — and it means an empty workshop makes nothing, which is where the bite
comes from.

| Role | Comes with | Makes |
|---|---|---|
| Carpenter | stage 5 | Timber |
| Blacksmith | stage 6 | Ingot |
| Alchemist | stage 7 | Tonic |

Building the workshop *is* hiring the specialist — there is no separate
recruitment step to forget about.

**Skill ranks 1–5**, trained at the workshop bench (**R**, next to the craft
prompt on the same part — prompt exclusivity is per *button*, so two prompts on
one part is fine as long as they take different keys). Output is **flat rank**:
a rank 3 blacksmith makes 3 Ingots a job where a rank 1 makes 1. Training is paid
in the goods specialists themselves make, so it loops back into the economy the
workshops created rather than sitting outside it.

**Stealing, at the doc's flat 85%.** Breach a wall, aim at a workshop bench,
swing. The specialist transfers at `floor(rank × 0.85)`, minimum 1. Flat matters:
a stolen rank 5 makes 4 and still out-produces an honest rank 4, so raids aim at
whoever is actually *worth* taking rather than at whatever is nearest. If the
thief already holds a better one of that role, theirs is kept and the victim's is
simply destroyed — denial is still worth the swing.

### The fourth gate

This finally lets the doc's own elimination condition be built as written —
"walls breached + stockpile emptied + specialists lost". A base now falls in
**four** stages:

| Stage | What | Gate on the next |
|---|---|---|
| 1 | Breach the **wall** | wall → 0 |
| 2 | Empty the **stockpile** | loot → 0 |
| 3 | Take every **specialist** | roster → empty |
| 4 | Raze the **keep** | owner eliminated |

The more you have built, the more there is to lose before anyone can finish you —
which is the right shape. A player who never built a workshop passes stage 3 for
free, and has nothing to show for it either.

Note the ordering is enforced on *elimination*, not on aiming: you can steal a
specialist while loot remains. Only the keep demands all three.

### Labourers

A cottage houses one. The doc lists "farmer/miner NPCs (classic resource
gathering)" as a role; this is that, kept abstract — a slow trickle every 12
seconds rather than an NPC with pathfinding, which is a project of its own and
not what makes the tier interesting. Each cottage carries a villager figure
outside it so a built cottage visibly houses somebody.

One resource per cottage in build order — Grain, Wood, Stone, Wool — so four
cottages is four visible trickles. **Ore is deliberately absent**: leaving it
hand-mined keeps it the scarce input, and the blacksmith, the keep and the wall
are all gated on it. A village outside the closing zone stops producing, the same
rule its nodes already follow.

## Refined goods and the workshops

Three goods you cannot gather. Each workshop consumes a different pair, so no two
compete for the same pile — and between them they are the sink Grain, Wool and
Ore never had. Every raw resource now feeds something.

| Workshop | Recipe |
|---|---|
| Carpenter | 5 Wood + 2 Stone → 1 **Timber** |
| Blacksmith | 4 Ore + 2 Wood → 1 **Ingot** |
| Alchemist | 4 Grain + 3 Wool → 1 **Tonic** |

Stages 8–10 need them, so a village cannot be finished without a working
economy behind it. They are looted like anything else: the 20% breach snapshot
covers all eight goods, not just the raw five.

## Resources

Five goods, one tool each. The numbers are deliberately *not* uniform, because
five resources that behave identically are one resource with five names.

| Resource | Tool | Capacity | Peak regen | Character |
|---|---|---|---|---|
| Grain | Hoe | 20 | 0.70/s | plentiful and quick, the bulk good |
| Wood | Axe | 20 | 0.60/s | plentiful, slightly slower |
| Stone | Pickaxe | 24 | 0.55/s | the T1 baseline, unchanged |
| Wool | Shears | 14 | 0.45/s | middling, capped low so a flock runs out fast |
| Ore | Pickaxe | 14 | 0.32/s | scarce and slow, worth travelling for |

The pickaxe does double duty on Stone and Ore, as it should.

**The wrong tool finds nothing at all**, rather than finding the node and
refusing it. Otherwise standing between a tree and a boulder with an axe would
silently target the boulder and look broken. Swinging at a node your tool cannot
work says which tool it needs.

Two attributes carry the contract between the world builder and the service:

- `Resource` on the node model — what it yields
- `Wears` on a part — it vanishes as the node is worked down

Parts *without* `Wears` are the permanent frame: trunks, sheep, bare earth. That
is what stops a spent node looking like an empty patch of ground — a chopped
forest is stumps and bare trunks, a shorn flock is still a flock.

## The loop

Spawn on the pad south of the board, mine an outcrop, then hold **E** at a build
site to spend 10 Stone on a block. Two site kinds, both 24 blocks:

| Kind | Shape |
|---|---|
| `Wall` | 8 sections wide, 3 courses high. The Tier 1 starter sink, kept. |
| `Castle` | A square ring stacked into a hollow tower, 8 blocks per course, 3 courses. |

A block costs **4 Wood + 4 Stone** — a bundle rather than a number, so building
consumes the economy instead of one column of it. A refusal names the resource
you are short of.

**Grain, Wool and Ore have no sink yet.** They are gathered and they stack up.
That is the next design decision, and it most likely hangs off the specialists in
the design doc rather than off more masonry.

The world builder tags each site with a `Kind` attribute; `ResourceService` owns
what that tag means. Adding a third shape is a new branch in `layoutOf` and
nothing else.

**Bases are owned.** Whoever raises the first stretch of wall claims the plot;
nobody else can build there, but anybody can raid it.

## Bases and raiding

**A plot starts as an empty field.** Bare ground, a claim stone, two streets, a
well and an empty stockpile pallet. Everything else is bought, one stage at a
time, in a fixed order — **ten purchases from empty field to fortified village.**

| # | Stage | Cost |
|---|---|---|
| 1–4 | Four **cottages**, all alike | 10–16 Wood + 5–10 Grain |
| 5 | **Carpenter** | 20 Wood + 10 Stone |
| 6 | **Blacksmith** | 20 Stone + 10 Ore |
| 7 | **Alchemist** | 18 Stone + 14 Wool + 8 Ore |
| 8 | **Keep** | 30 Stone + 6 Timber + 6 Ingot |
| 9 | **Palisade** — gate, footing, half the wall | 25 Wood + 8 Timber |
| 10 | **Rampart** — corner towers, full wall | 35 Stone + 8 Ingot + 4 Tonic |

The order is the point. You cannot wall off an empty field and you cannot raise a
keep before there is anyone to build it, so the early game is soft and open and a
village only becomes a fortress once its owner has actually done the work. The
last three stages need **refined** goods, which means the workshops are load
bearing rather than ornaments you put up after the walls are done.

Once the ladder is finished the prompt turns into **repair**, 25 HP for 4 Wood +
4 Stone. A breach has to be repairable or a village falls exactly once, forever.

**How a stage appears.** `build-world` builds every stage of every village up
front into `ServerStorage.VillageBlueprints.<site>.Stage<n>`, positioned in world
space. Buying one is a **reparent** — the service never has to know how a house
is made, only how to move a folder, and there is no duplicated geometry code
between the builder and the runtime.

### The buildings

Sized off the **character**, not the map. A Roblox humanoid is about 5 studs tall
and 2 wide, so cottages get 9-stud walls, workshops 11, and both get a 7-stud
doorway and a **hollow interior** — floor, four walls, a gap in the front with a
lintel over it. They are rooms you walk into, not solid blocks with a door
painted on.

Four cottages are deliberately identical: a village should read as ordinary
dwellings with a few special buildings among them, not as four landmarks. The
three workshops are unmistakable — a forge chimney with a lit crown, stacked logs
and a saw bench, a round turret and spire over a square room, because a hollow
cylinder would need a ring of parts and still be a worse room.

Roofs are two wedges meeting at a ridge. A `WedgePart` is tall at its +Z face and
tapers to nothing at −Z, measured in Studio rather than assumed. They also carry a
**ridge beam**: the two halves meet on an exact plane and a ray cast straight up
from inside slips between them — measured, 5 of 25 interior points saw open sky,
all on the x = 0 line. With the beam, 25 of 25 are covered.

### The stockpile is a heap

Not a shed with a number on it — a pallet with the owner's goods piled on it, and
the pile's **size and composition track what they are holding**. Logs, wool
bales, grain sacks, stone, ore, and a lit tonic on top. You can look at a village
from outside and tell whether it is worth raiding.

It is capped at 44 pieces and scaled **proportionally**, not first-come. Filling
in order meant a player holding a lot of wood got a heap of nothing but wood and
the other seven goods never appeared, which defeats the entire point of the pile.

Redraws are driven off a dirty flag rather than the counter change itself, so a
burst of swings collapses into one rebuild.

**The ring of blocks is not twenty-odd little walls.** It is a readout: how many
blocks stand is drawn from the single wall value. Each purchase of 4 Wood + 4
Stone buys 25 HP and raises one block; damage lowers the value and drops blocks
to match. A full wall is **600 HP** drawn across 27 blocks.

The wall's strength is a **fixed pool**, no longer "however many blocks the ring
happens to have, times 25". Decoupling the two lets the ring be drawn at whatever
density suits a 148-stud village without quietly turning a siege into a forty
swing grind.

**The gate is the only place the wall can be hurt.** That is the point of there
being one — a raid is a commitment to one approach rather than chipping at
whichever face happens to be nearest.

**The stockpile holds the exposed slice.** When the wall falls, a snapshot is
taken of 20% of what the owner holds; that snapshot is the entire raid. The other
80% is safe. This is what makes a loss sting without being a wipe.

The snapshot matters. Recomputing "20% of what they hold" on every swing
converges on taking everything, which is exactly the wipe the doc is avoiding.

### A base falls in three stages

The doc's own elimination condition — "walls breached + stockpile emptied +
specialists lost" — could not be built as written. It depends on specialists,
which the same doc files as a stretch goal to build *after* the core loop; and
"stockpile emptied" is incoherent with the stockpile design, because only 15–25%
of holdings is ever exposed. Either it means the exposed pot, which empties in a
single raid and is far too easy for a win condition, or it means total holdings,
which raiding can never reach.

So it was redesigned. A base falls in three stages, and only the third eliminates:

| Stage | What | Gate on the next stage |
|---|---|---|
| 1 | Breach the **wall** — one HP value, hit only at the gate | wall must reach 0 |
| 2 | Empty the **stockpile** — the 20% snapshot taken at the breach | loot must reach 0 |
| 3 | Raze the **keep** — 200 HP, 8 swings | owner eliminated *(stage 3 of the plan)* |

Elimination is therefore always a completed siege, never a lucky hit on the way
past. The specialist clause becomes a fourth gate later without reshaping any of
this.

The keep darkens as it is broken and goes translucent when it falls, and the gate
darkens as the wall fails — both so a besieger can read how close a base is to
going without a health bar.

One swing does five things depending on what you are aimed at, in order:

| Priority | Target | Effect |
|---|---|---|
| 1 | Another player | 20 damage |
| 2 | An enemy gate, wall standing | 25 damage to the wall |
| 3 | An enemy stockpile, wall down | Loots 4 of a resource from the snapshot |
| 4 | An enemy keep, wall down and stockpile spent | 25 damage to the keep |
| 5 | A node your tool can work | Harvests 1 |

A person beats their gate, and all of it beats the node you happen to be standing
next to — otherwise you could not fight beside a node.

Breaching re-enables the owner's build prompt, so a wall can be repaired back up.

### Knockdown, not death

Conquest has no lives and no respawn-on-death, so `Players.CharacterAutoLoads` is
off and every spawn goes through `reviveAt`. Losing a fight is a **knockdown**:
you go down and come back at your own keep 8 seconds later.

Killing cannot be the elimination path or sieges become pointless — you would
hunt people instead of ever breaching a wall. Combat decides whether an attacker
can hold ground long enough to finish a siege, which is the job it should be
doing.

Two cases send you to the village instead of your keep, and both matter:

- **Your keep has fallen.** Reviving at a razed keep drops you in the lap of
  whoever just razed it.
- **Your keep is outside the closing zone.** Reviving there is a loop of dying,
  respawning outside, and dying again. The village is at the origin, which the
  zone closes onto, so it is always inside.

The spawn pad has an 8 second forcefield. It was 0 while nothing could hurt you;
with combat, a forcefield-free spawn is a place to be farmed.

The world builder places geometry only. Everything that changes at runtime —
how much stone a node holds, how fast it comes back, what a block costs —
lives in `ResourceService`.

### Nodes

Capacity 24, one stone per swing. Regen follows the design doc's curve: fastest
at moderate depletion, slow near full and near empty. See `regenRate`.

| fill | rate | seconds per stone |
|---|---|---|
| half full | 0.55/s | ~1.8s |
| empty or full | 0.06/s | ~16s |

Mining is 1 stone/second, above the peak on purpose — a node can always be
drained faster than it heals, it is just a bad trade.

**The floor is load-bearing.** The textbook fit is logistic growth, which is
exactly zero at empty, so a node worked all the way down would never come back.
A dead node is worse than a flat one, so the curve sits on a floor instead of
touching zero: slow at the ends, never stopped.

Measured over 180 seconds, mining continuously:

| | 30s | 60s | 90s | 120s | 150s | 180s |
|---|---|---|---|---|---|---|
| camping one node | 30 | 42 | 44 | 46 | 47 | **48** |
| rotating three nodes | 25 | 51 | 78 | 99 | 126 | **151** |

Camping asymptotes as its node pins at the floor. Rotation is linear and
sustainable — 3.1x the stone, and it ends with every node back at 24/24 despite
spending 26 of those 180 seconds walking rather than mining.

**Those numbers are from the old three-node map**, where the nodes sat ~74 studs
apart. The board has five nodes ~160 studs apart, so the walk is longer and the
balance has shifted. Re-run this comparison before trusting it.

As a node is worked down its blocks disappear from the top, and a billboard over
it shows `amount / capacity`. The bar is tinted by the node's **current regen
rate**, not its fill — green where it pays to walk away, dull where the node has
been worked past the point of being worth it. Otherwise the curve is a hidden
number nobody can learn. Mining a spent node still swings and still throws chips,
it just pays nothing.

### Mining

`StarterPack` holds the `Pickaxe`; `ResourceService` auto-equips it on spawn and
listens for `Tool.Activated`, which the engine fires on the **server**, so mining
needs no RemoteEvent. Build sites use a `ProximityPrompt`, whose `Triggered` is
likewise a server event. The one RemoteEvent in the game is `Notify`, and it
exists for per-player feedback rather than for input.

A swing takes 1 second. Stone is granted at the **0.70s** mark — the measured
contact frame of the animation, not the click — and only if a node is within 15
studs **and** roughly in front of you.

## The match

`MatchService` owns the clock and the boundary. It owns nothing else — not bases,
not nodes, not elimination — and it talks to `ResourceService` the way that file
already talks to itself: through attributes on instances, not a shared module.

| Attribute on `Workspace` | Meaning |
|---|---|
| `MatchState` | `Lobby` → `Running` → `Ended` |
| `MatchClock` | seconds left in the current phase |
| `ZoneHalf` | half-extent of the playable square, in studs |

The board is a 7×7 grid centred on the origin and dead flat, so **the boundary is
one number, not a shape**. It holds at the full 560 for the first 20% of the
match, closes linearly to 130 by 90%, then holds. Both numbers scale with the
board; the final ring is deliberately wide enough to hold a village or two, since
closing onto something smaller than a single compound would decide the match by
whose walls happened to sit nearest the middle. A boundary that starts closing
on the first second gives nobody time to establish; one still closing at the
whistle never forces contact.

Outside it you take 4 damage a second — a push, not an execution — and **nodes
outside it stop yielding**, which is the scarcity half of what the doc wants
convergence to do. Four translucent slabs mark the edge, because a boundary you
only discover by taking damage is a bug disguised as a mechanic.

**Set `Workspace.MatchLength` before starting** to shorten a match. Without it the
default is the doc's 45 minutes, and nobody — including a playtest — wants to sit
through three quarters of an hour to find out whether the timer fires.

### Squads, elimination and the win

A **squad** is the minimal reading of the doc's "last player or team standing":
an original player plus whoever has been folded into them. There is no alliance
system and nothing to agree to — you do not negotiate a team, you acquire one by
taking somebody's keep. Roblox's Teams service does the grouping, which puts
squads in the player list for free, the same reasoning as leaderstats carrying
the resource columns.

**Elimination needed no change in `ResourceService`.** It already publishes
`Fallen` on a base the moment its keep is razed, and it already publishes
`Owner`, so `MatchService` watches that one attribute and resolves the rest. The
cheapest seam is the one that already exists.

A squad falls when its **leader's** keep is razed, and the whole squad falls with
it — the squad exists because the leader held a keep, so there is nothing left to
belong to. Everyone on it, leader and workers alike, is dealt back out to the
survivors.

**The fold is weighted toward the small.** `FoldWeighting` gives each surviving
squad a weight of `1 / size`, so a lone survivor is twice as likely to receive a
worker as a pair and four times as likely as a four:

| Surviving squads | Share of the next worker |
|---|---|
| 1, 1, 1 | 33% / 33% / 33% |
| 1, 2, 4 | 57% / 29% / 14% |
| 1, 7 | 88% / 12% |

Deliberately not uniform, and emphatically not weighted by strength. The reason
the eliminated are folded in at all is that a player who is out should still
matter to the match — but a uniform fold would pay the strongest player a free
workforce for winning, and the match would snowball to whoever won first. The
reward for taking a keep is the keep, not compounding labour.

It lives in its own ModuleScript for one reason: it is the only part of the win
condition that is pure arithmetic, and pure arithmetic can be checked against a
table of made-up squad sizes without twelve players in a server. The roll is
passed in rather than drawn inside, which makes `choose` deterministic and
therefore assertable — walk the roll from 0 to 1 and you see the whole
distribution.

**The match ends** when one squad is left, or at the whistle. At the whistle the
largest surviving squad takes it, because the fold means size *is* the record of
how many keeps a squad has taken; ties go to whoever still holds the most wall
and keep.

Two attributes carry it: `Player.Eliminated` (your keep fell, you are somebody's
worker now) and `Player.Squad`.

## Checking scripts without Studio

`rokit.toml` carries the `luau` CLI alongside Rojo. Running a Roblox script
through it stops at the first `game:GetService` — which is exactly the point: a
*runtime* stop on line 34 means the file **parsed**, while a syntax error looks
entirely different and reports a line you can go and fix.

```sh
luau src/server/ResourceService.server.luau   # "attempt to index nil with 'GetService'" = parses fine
```

This matters because Studio is not always available — it froze hard during the
specialist tier and stopped answering the plugin entirely, including
`get_studio_state`. A parse check that needs nothing but the repo is the
difference between "I cannot verify anything" and "I know it at least compiles".

Anything genuinely pure can go further and be **run**: `FoldWeighting` has no
Roblox dependencies, so its whole distribution is verifiable from the command
line with no engine at all. That is a good reason to keep pure logic in its own
module.

## Things that bit, so they don't bite twice

**`Terrain:FillBall(..., Enum.Material.Water)` is a silent no-op.** Since the
Shorelines change, water is not a material in the solid voxel grid — it is its
own `LiquidOccupancy` channel — and the whole `Fill*` family cannot write it.
Nothing errors; you just get a dry hole. When this map had a lake it was
written with `ReadVoxelChannels`/`WriteVoxelChannels` instead. There is no water
on the board now, but the trap is worth keeping written down.

**The ground is not at y = 0, and placing scenery as if it were will bury it.**
Terrain smoothing lifts the flat parts of the map to about y = 2, and the grass
rises push it past 6. Rock_03 sits at distance 126, right inside the band the
rises are placed in — at a hardcoded height the entire outcrop ended up inside a
hill: invisible, unmineable, and it silently broke the one test that needs three
working nodes. Every placement in `build-world.luau` now raycasts for the real
surface first (`groundHeight`). Test harnesses have to do the same: teleporting a
character to a guessed height puts it inside the hillside, where it dies and
respawns, and a stale `player.Character` reference then makes the run look like
it is still going when it has actually stopped.

**The `Grass` terrain material spawns decoration blades about head height.** At
eye level they swallow the player, the rocks and the wall. There is no property
to shorten them, and `Terrain.Decoration` is not reachable from the MCP's
scripting context. The ground is `LeafyGrass`, which reads as lush from a
distance and grows nothing.

**The swing is a custom overhead cut** (`rbxassetid://137439580267496`), authored
in the Animation Editor and played from the server so every client sees it.
Exactly 1.0s, so it plays at speed 1.

Two procedural approaches were tried before resorting to an asset, and neither
works on this place's rig: the characters here use `AnimationConstraint` joints
rather than `Motor6D`, so there is no `C0` to drive, and writing the constraint's
`Attachment0` from the server does not replicate to clients.

**The contact frame was measured, not guessed.** Stone is granted at `IMPACT_AT`,
so that constant has to match where the pick actually lands or the payout floats
free of the animation. To find it: play the track, `AdjustSpeed(0)` to turn
`TimePosition` into a scrubber, then step through it sampling the pick tip's
position. For this animation the tip peaks overhead at t≈0.45, reaches maximum
forward reach at t≈0.66, and descends at full speed until t≈0.71 where it
decelerates hard (step 1.01 → 0.82 → 0.45). That arrest is the strike; everything
after is follow-through. Hence `IMPACT_AT = 0.70`.

Note the naive heuristic — "lowest point of the tip" — returns t=0.05, which is
just the rest pose before the raise. Swap the animation and you must re-measure.

**`Tool.Grip` is expressed in the Handle's own frame.** The Handle is therefore a
plain unrotated invisible block, with the visible round shaft welded over it —
rotating the Handle to lay a cylinder along Z would twist every Grip value with
it.

**`Tool.Grip` is the *inverse* of where the Handle sits in the hand.** Writing it
directly is guesswork; describe the pose you want and invert it:

```lua
local heldPose = CFrame.new(0, 1.35, 0) * CFrame.Angles(math.rad(90), 0, 0)
tool.Grip = heldPose:Inverse()
```

The hand's frame has +Y up and −Z forward, and the shaft runs along the Handle's
local Z with the head at −Z. Rotating +90° about X carries −Z onto +Y, standing
the pickaxe upright instead of poking forward out of a straight arm. The 1.35
lift puts the grip point back in the hand after the rotation drops it.

**The two-handed look is an `IKControl`, not the animation.** The swing only
poses the arm holding the tool, so an IKControl drags the left hand onto a
`LeftGrip` attachment on the shaft and keeps it there for the whole arc — the off
hand follows the swing without the animation knowing about it.

`ChainRoot` is `UpperTorso`, not `LeftUpperArm`. Reaching a tool held out on the
right means crossing the body, and an arm-only chain cannot get there: measured
**1.78 studs short** with `LeftUpperArm` against **1.32** with the torso in the
chain. `LowerTorso` is worse again (3.36) — it bends the whole body and still
misses.

That 1.32 is close, not exact. It is a good approximation, not a real grip. The
exact version is to pose the left arm in the animation itself, where the hand can
be placed on the shaft by eye.

**A ProximityPrompt's reach is measured from the part it lives on.** The build
prompt sits on the base foundation, and the gate is 12 studs out from it, so a
16 stud reach left the owner unable to repair while standing at their own gate —
exactly where a defender is. It is 26 now, sized to the compound.

**Client-side writes do not replicate — to anything.** Set `leaderstats` from a
LocalScript and the server never sees it, so a build silently refuses for lack of
resources. Set a `Workspace` attribute from a LocalScript and the server never
sees that either, so a match "shortened" to 18 seconds ran for the default 45
minutes. Both cost a debugging round. If a test needs server state, set it from
the server.

**A `ProximityPrompt` well above head height will not activate, whatever its
`MaxActivationDistance` says.** A craft prompt on a signboard ~5 studs over the
character refused to fire at 9 studs with a 16 stud reach, line of sight off and
`Enabled` true. The same prompt lowered 5 studs fired at 7, and moving it to a
bench fired too. Plain 3D distance is not the gate. **Put interaction prompts at
roughly the height of the person using them.**

**MCP `Source` writes do not reach a playtest; `multi_edit` does.** Patching a
script by assigning `.Source` from `execute_luau` updates what the Edit datamodel
reports — a checksum of `.Source` matched disk exactly — but the *next play
session still ran the old code*, 64213 chars against Edit's 65431. Re-applying the
same change through `multi_edit` did reach it. So a `.Source` checksum is **not**
proof that a playtest will run that code. Verify inside the running session, or
edit through `multi_edit` (or Rojo) in the first place.

**A test harness that drops the character on top of scenery will frame a bug in
the wrong place.** Sweeping a build prompt outward to find its range gave
*non-monotonic* results — fires at 16, ignored at 18–22, fires at 24–28 — which
reads exactly like an engine cap on `MaxActivationDistance`. It was not. Those
dead bands are where the stockpile and the houses stand: the character was being
dropped onto a roof, shoved off, and ending up somewhere other than the test
position. Placing it on a raycast surface and asserting **drift ≈ 0** before
triggering, the prompt fires at every distance out to 70 studs, exactly as
configured.

Two lessons, and the second is the expensive one. Raycast for a standing spot —
the same fix as the buried node. And **treat a non-monotonic result as evidence
the harness is wrong**, not as a strange property of the thing being measured; a
real distance cutoff cannot switch back on when you move further away.

**`rojo serve` running during a playtest kills the session.** The plugin cannot
make HTTP requests from a play datamodel — the console shows *"Http requests can
only be executed by game server"* — and the playtest dies a few seconds in. Stop
the Rojo server before playtesting, restart it after. This is also why Studio-side
edits drift: **entering Play disconnects the plugin every single time**, so
anything typed in Studio afterwards is invisible to Rojo until you reconnect.

**A duplicated Script doubles its effects while looking fine.** Two copies of
`MatchService` in `ServerScriptService` ran two loops, so zone damage landed at
twice the intended rate — but the tick count looked correct, because both copies
wrote the *same* `MatchClock` value and the change signal only fires when a value
actually changes. Measure the effect, not the heartbeat. Note also that
`Destroy` on a running Script does not stop a loop it already spawned; that needs
a play restart.

**`require` caches per ModuleScript instance.** Rojo updating
`ServerStorage.BuildWorld` does *not* invalidate that cache, so a plain
`require(...)()` silently rebuilds the world from the module you loaded first
this session. Clone it to get a fresh instance and therefore a fresh cache entry:

```lua
local fresh = game.ServerStorage.BuildWorld:Clone()
fresh.Parent = game.ServerStorage
require(fresh)()
fresh:Destroy()
```

**Rojo syncs to the Edit datamodel, not a running playtest.** A play session
started before an edit keeps the old code. Stop, let it sync, start again.

## Studio MCP

Registered locally as `Roblox_Studio` (`cmd.exe /c %LOCALAPPDATA%\Roblox\mcp.bat`).
Studio must be open with the place loaded. `/mcp` to check the connection.

Known noise: Roblox's `mcp.bat` is malformed — its `else` sits after the closing
paren, so cmd prints `'else' is not recognized` to stderr after each run. Harmless.

The MCP runs with plugin permissions but not `RobloxScript`, so a handful of
properties are unreachable from it: `Lighting.Technology`, `Terrain.Decoration`,
`Terrain.MaterialColors`. If the place looks flat, set Technology by hand in
Properties → Lighting → Technology → Future.
