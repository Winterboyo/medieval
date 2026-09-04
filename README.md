# Medieval Land

Roblox game, built in tiers. See the tier order in
`~/.claude/projects/C--Users-winter-projects-medieval-land/memory/tier-build-order.md`.

**`DESIGN.md` is the authority on scope.** It is v2, post-Conquest-pivot, and it
says so itself: if anything here conflicts with an older note, the doc wins.

**Where this is:** a Catan board filling the whole map, five raw resources and
three refined ones, villages built from an empty field in ten purchases, a
four-stage siege, knockdown instead of respawn, and the Conquest match clock
with its shrinking zone.

**Reputation is no longer next.** The doc moves it under "Negotiation & reputation
— stretch goal, needs specialists first" and corrects it to within-match only.
The persistent, recency-weighted version is explicitly cut.

**What still departs from the doc.** Combat is the one that matters: knockdown
and elimination-by-base-state are both built, but putting someone down takes
five swings at 20 damage where the doc specifies a *single-hit* knockout. This
paragraph used to say the Conquest match structure — timer, shrinking zone,
folding eliminated players into surviving teams — did not exist at all; it does
now, in `MatchService` and `FoldWeighting`, and that claim predated two tiers.
What is genuinely absent is what the doc parks behind a decision or behind
specialists: the rebellious flag, the spy variant, merchants, and the whole
negotiation loop. Reputation exists only as a number theft moves; nothing reads
it yet.

**The two-player backlog is cleared.** It stood open from T3 onwards and is now
verified end to end: 15 checks, 0 failures. Per-player notice isolation, PvP
damage, knockdown and revive at your own keep, gate battering against a real
owner, the 20% loot snapshot actually changing hands, specialist theft including
the denial branch, the fourth gate refusing to let a keep be touched while its
owner still holds anyone, and the full chain of keep → `Eliminated` → folded into
the raider's squad → match Ended.

See **[Verifying with two players](#verifying-with-two-players)** for how to
re-run it.

## Layout

| Path | What |
|---|---|
| `src/server/ResourceService.server.luau` | Nodes, tools, bases, raiding, reputation. Rojo syncs it. |
| `src/server/MatchService.server.luau` | The Conquest clock, the zone, squads and the win condition. |
| `src/server/FoldWeighting.luau` | Pure maths for dealing an eliminated player to a squad. |
| `scripts/build-world.luau` | Builds the board: terrain, tiles, all five node kinds, build sites, the four tools, lighting. Rojo syncs it to `ServerStorage.BuildWorld`; rebuild from the command bar with the clone snippet below (a plain `require` returns a cached, stale module). Re-runnable — it tears down what it built last time. |
| `src/client/Notifications.client.luau` | Per-player notices, driven by the `Notify` RemoteEvent. |
| `default.project.json` | Rojo's map from this repo into the DataModel. |
| `rokit.toml` | Pins the toolchain — Rojo 7.7.0, plus the `luau` CLI for checking scripts without Studio — so it is reproducible. |

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

## The island

It was a 7×7 board of flat square tiles — a Catan grid, deliberately legible and
deliberately artificial. It is now an **island**: an irregular landmass with real
relief, beaches, and open water all the way round.

The square had to go because it read as a diagram no matter how well the seams
between tiles were blended. **You cannot hide a grid; you can only decorate it.**

What survived the change is the part that was load bearing: resources are still
grouped into **regions you travel between**, because the whole economy rests on
that. The regions are organic now — they follow height and a noise field rather
than a lattice — so you cross from forest into hills without ever seeing a
boundary.

### Written as voxels, not filled as blocks

`FillBlock` can only place rectangular solids, which is precisely *why* the old
map looked like rectangular solids. `WriteVoxels` sets a material **and an
occupancy** per cell, so a column can end part-way through a voxel and the
surface comes out smooth instead of stepped.

Each chunk sizes its own vertical range from a coarse sample of its own terrain.
Spanning the full world height everywhere would be ~14 million cells, almost all
of them empty sky over open water; fitted, a deep-ocean chunk is about a dozen
voxels tall.

### One height function, asked by everything

`heightAt` is sampled by the terrain writer, by node placement and by village
placement. Everything agrees about where the land is because everything asks the
same question.

The coastline is a radial falloff whose radius is warped by **three octaves** of
noise, each clamped — `math.noise` is documented as roughly −0.5..0.5 and
overshoots. The frequencies matter more than the amplitudes: at 0.0007 a full lap
of the coast covers well under one unit of noise space, so the field barely
changes and the island comes out a circle whatever the amplitude says. Measured
at that frequency: 760–940 across sixteen bearings, a 12% wobble. At 0.00165 it
is 270–990, with a bay cutting deep on one side.

### Biomes are Voronoi cells, not thresholds

The first version already snapped every voxel to exactly one material — it never
interpolated — and it still read as mud. The reason is worth writing down.

**Slicing one smooth noise field with thresholds puts the boundary wherever the
field happens to cross a number, and a smooth field crosses a number many times
in the same neighbourhood.** You get tendrils, fringes and marooned islands of
one material inside another, because the boundary is a contour line of a wobbly
surface rather than an edge. Cutting three similar earthy materials from the same
field made it worse: their boundaries interleaved instead of separating.

A Voronoi partition has the wanted property by construction — every point belongs
to exactly one region, every region is contiguous, and the boundary between two
of them is a line. Fifteen seeds, dealt a **weighted cycle** of materials so the
proportions are exact rather than left to luck. The lookup position is warped by
a little noise first, which keeps edges from being suspiciously straight without
softening them: still a hard line, just not a chord.

Measured on the same 26-stud grid, before and after — blob counts and how much of
each material sits in its single largest blob:

| | thresholds | Voronoi |
|---|---|---|
| Grass | 8 blobs, biggest holds 37% | 4 blobs, 62% |
| LeafyGrass | 11 blobs, 43% | 2 blobs, 68% |
| Mud | 3 blobs, 48% | 6 blobs, 81% |
| Slate | 3 blobs, 89% | 2 blobs, 58% |

Two things the measurement caught that the eye did not:

- The equal round-robin gave the two rock materials **half the island between
  them**, which reads as a quarry rather than somewhere people farm. The cycle is
  weighted green-dominant now: Grass 5, Mud 4, LeafyGrass 3, Slate 2, Basalt 1.
- The summit band was `height > 80` on an island that tops out at 82, so it
  caught **three cells in the whole world**. A band that does not exist is not a
  region, it is a rounding error. At 68 the peaks read as bare rock, which also
  tells a player where the ore is.

`Ground` at 27% is not a biome — it is the seventeen village terraces, which is
why it shows as seventeen small blobs.

**Height and biome are resolved once per column**, not per voxel. They only
depend on x and z, and recomputing them for every voxel meant `heightAt` ran tens
of times per surface point. Build time went 4.3s → 1.7s, which is what paid for
the Voronoi lookup.

### Placement is thrown, not laid

A tile used to *be* its node, which made placement trivial and the map a
chessboard. Nodes and villages are now thrown at the island and rejected until
they fit — on land, not too steep, and far enough from what is already placed.

Two things this taught, both of which produced a silently broken map first:

- **Villages and nodes need separate registers.** One shared list made a village
  keep 250 studs from *everything*, nodes included, so once 48 nodes were down
  there was nowhere left and it placed **zero villages** without complaining.
- **Quota first, terrain second.** Letting the terrain decide — sample anywhere,
  ask "what belongs here?" — returned Grain 19, Wood 18, Wool 9, Stone 2, **Ore
  0**. The same slope limit that keeps a node off a cliff keeps it off every
  mountain, so the high ground where stone and ore live was filtered out before
  it was ever classified. An economy missing an entire resource is not a
  distribution quirk. Each resource now has a quota and its own stretch of
  terrain to look in, and a shortfall `warn`s loudly.

Villages cut a **round terrace**, because a 148-stud foundation slab on a
hillside floats at one corner and buries itself at the other. Round because the
first cut used squares, and sixteen square terraces cut into an island read from
the air as sixteen brown plates — the grid the whole redesign was meant to remove,
reintroduced by the flattening.

### The boundary is a ring

The zone was a square half-extent because the world was a square board. On an
island a square boundary would cut the coast at four arbitrary places and leave
corners of open sea inside the "safe" area. It is 48 tangential segments on a
circle now, sized so their chords overlap and there is no gap to walk through,
and all three places that ask "am I inside" — `MatchService`, `ResourceService`
and the HUD — use plain radial distance.

## The board (historical)

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
**four** stages, wall → stockpile → specialists → keep; the HP values and the
history are under **A base falls in four stages**.

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

Spawn on one of the eight pads ringing the totem, gather with the tool the tile
wants, then hold **E** at a village plot to buy the next stage of a base.

**There is one site kind left.** The world builder tags each build site with a
`Kind` attribute and `ResourceService` owns what that tag means, but the only
value it now recognises is `Base`. The Tier 1 sites — a `Wall` and a `Castle`,
24 blocks each, raised a block at a time for 10 Stone — are gone, superseded by
the ten-stage ladder under **Bases and raiding**.

Costs stayed **bundles rather than single numbers**: the repair that ends the
ladder is 4 Wood + 4 Stone, and every stage of the ladder mixes at least two
goods.
A single-resource price would let a village be built out of one column of the
economy. A refusal names the resource you are short of.

**Bases are owned.** Whoever makes the first purchase claims the plot; nobody
else can build there, but anybody can raid it.

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

### A base falls in four stages

The doc's own elimination condition — "walls breached + stockpile emptied +
specialists lost" — could not be built *when it was first read*, and the reason
is worth keeping. It depends on specialists, which the same doc files as a
stretch goal to build *after* the core loop; and "stockpile emptied" is
incoherent with the stockpile design, because only 15–25% of holdings is ever
exposed. Either it means the exposed pot, which empties in a single raid and is
far too easy for a win condition, or it means total holdings, which raiding can
never reach.

So the second half was pinned down — "emptied" means the exposed snapshot — and
the siege was built in three stages, with the specialist clause left as a fourth
gate to add once there were specialists to lose:

| Stage | What | Gate on the next stage |
|---|---|---|
| 1 | Breach the **wall** — one HP value, hit only at the gate | wall must reach 0 |
| 2 | Empty the **stockpile** — the 20% snapshot taken at the breach | loot must reach 0 |
| 3 | Take every **specialist** — see **The fourth gate** | roster must be empty |
| 4 | Raze the **keep** — 200 HP, 8 swings | owner eliminated |

There are specialists now, so stage 3 is in and the keep will not take a scratch
while the owner still holds one. Nothing else had to be reshaped to fit it,
which is the argument for building the ordering as gates in the first place.

Elimination is therefore always a completed siege, never a lucky hit on the way
past.

The keep darkens as it is broken and goes translucent when it falls, and the gate
darkens as the wall fails — both so a besieger can read how close a base is to
going without a health bar.

One swing does six things depending on what you are aimed at, in order:

| Priority | Target | Effect |
|---|---|---|
| 1 | Another player | 20 damage |
| 2 | An enemy gate, wall standing | 25 damage to the wall |
| 3 | An enemy stockpile, wall down | Loots 4 of a resource from the snapshot |
| 4 | An enemy workshop bench, wall down | Steals the specialist at `floor(rank × 0.85)` |
| 5 | An enemy keep, wall down, stockpile spent and roster empty | 25 damage to the keep |
| 6 | A node your tool can work | Harvests 1 |

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

The spawn pads have an 8 second forcefield. It was 0 while nothing could hurt you;
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
one number, not a shape**. It holds at the full 700 for the first 20% of the
match, closes linearly to 130 by 90%, then holds. 700 is not a chosen number — it
is half of 7 × 200, the board's own extent, so the zone opens flush with the edge
of the map and nothing starts out of bounds. The final ring is deliberately wide
enough to hold a village or two, since
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

## Verifying with two players

A pile of behaviour is unreachable from one client. The loot snapshot reads the
*owner's* counters, so solo there is no owner to read; theft needs someone to
steal from; the fourth gate needs a roster that is not yours; notice isolation is
about what a *second* window renders.

It is also not drivable from outside. Studio's **Start Server and Players** runs
the server and each client as separate processes, and the Studio plugin only
registers in the editor — so external tooling can see the place but not the
running test. `src/server/TwoPlayerCheck.server.luau` therefore runs *inside* the
server, drives both characters itself, and prints its own report.

1. In the editor, set `Workspace.TwoPlayerCheck = true`. It is opt-in because it
   hands out resources, so it must never fire during ordinary play.
2. **Test** tab → Players: 2 → **Start**.
3. One player builds a plot to "Village complete", the other builds as far as the
   Blacksmith. Which is which does not matter — the harness reads the roles from
   who actually built, not from join order.
4. Copy the block it prints between `COPY FROM HERE` and `TO HERE`.

The one thing it cannot check itself is notice isolation, because that is about
what each client renders. It fires a distinct line at each player; confirm each
window shows only its own.

### What writing it taught, mostly the hard way

Three of its early "failures" were the harness being wrong, not the game:

- **Roles came from join order.** `GetPlayers()[1]` is not something the tester
  picks, sees, or can predict, so swapping who built what left the harness
  waiting forever instead of failing with a message. Roles are read from the
  world now.
- **Roblox regenerates health.** Every character gets a `Health` script worth
  about 1%/sec, which ate 2 HP of a 40 HP measurement and reported 38. The swing
  was always right. The harness removes the script before measuring.
- **Labour outran the raid.** Both villages trickle a resource per cottage every
  12 seconds, so over a minute of looting the victim ended up 20 *up* while being
  robbed. Assert on the pot, which only moves one way, not on the victim's total.

And one that was neither — a hardcoded swing count. Roughly one swing in seven
does not land, so a keep needing exactly 8 hits got 7 out of 10 and stopped at 25
HP. **Loop to the outcome, not to a count**, and keep a cap so a genuine refusal
still fails instead of hanging.

## What the player can see

For a long time the answer was: almost nothing. The server published the match
clock once a second and **nothing read it, anywhere**. The zone was four
translucent walls on the horizon. Keep health had no readout at all, not even
prompt text. Specialists, reputation, build stage — all published, none drawn.

`src/client/Hud.client.luau` draws them, and it **opens no remote**. Attributes on
`Workspace`, on a `Player`, and on models in `Workspace` replicate to clients for
free, and every number was already published as one. So the HUD is purely a
reader: it asks the server for nothing and cannot desync from it, because it is
displaying the server's own values rather than a copy of them.

| Panel | Shows |
|---|---|
| Top centre | phase, clock, and how far the walls have closed |
| Bottom left | the eight goods, raw on the top row and refined below |
| Bottom right | village stage *n*/10, what is next, wall and keep meters, your specialists and standing |

The one thing it computes itself is whether you are inside the boundary, since
that depends on where you are standing. It uses the server's own max-axis rule.

**The zone alarm replaced the worst spam in the game.** `MatchService` fired a
toast *every second* you stood outside the boundary — and the toast is a single
shared line, so a raid warning or a theft notice could not get a word in
edgeways. It is a red screen edge now: permanent while it is true, silent
otherwise, and it costs the notice channel nothing.

**Ceilings are published, not assumed.** The meters first hardcoded 600 and 200
because the server sent `Wall` and `KeepHealth` but never their maximums — which
would have gone quietly wrong the moment either constant was retuned. `WallMax`
and `KeepMax` are published now.

### One palette

There were two. The negotiation panel deliberately took the world's colours out
of `build-world.luau`; the toast and the 48 node readouts predated it and used an
unrelated near-black scheme. Two surfaces built at different times looking like
they came from different games is most of what "unpolished" means, and it is the
cheapest thing to fix. `src/shared/Palette.luau` is the single source now.

Note its goods colours are deliberately **not** the tints in the node readouts:
those colour a bar by regen *rate*, which is why Wood and Stone are near-identical
greens there. Two different jobs need two different scales.

## Light and surface

### The lighting had never run

Worth stating plainly because it explains a lot of "this looks like a prototype":
the whole lighting block sat after a line that threw, so until recently the place
had no atmosphere, no bloom, no sun rays and no colour correction at all.

Once it ran, it needed tuning:

- **The sun was the problem.** `ClockTime 14.6` put it almost overhead, which is
  the flattest light there is — nothing casts a shadow long enough to give a
  building form, so the island read as a painted map. It went to 16.1, and then
  to 8.7 — see below, because 16.1 turned out to be wrong for a second reason.
- **Haze was the other problem.** At 0.9 it washed the far half of the map into a
  flat cream band and took the horizon with it. It is 0.38, with `Density` raised
  instead: density does the work of *there is air between us*, haze is only the
  milkiness on top.
- **Warm sun, cool shadow.** `Ambient` is deliberately bluer than the sunlight.
  That is what stops shadows reading as dirty grey, and it is the cheapest trick
  in outdoor lighting.
- Brightness came 3 → 2.1 with slightly negative exposure, because 3 was blowing
  the ground to near-white.
- One `Clouds` instance, for free scale reference — an empty sky over open water
  gives the eye nothing to judge distance against.

**`Lighting.Technology` is not scriptable and no longer meaningful.** It cannot
even be *read* from a plugin thread. This place was migrated to unified lighting,
so the style is set by hand at Lighting → LightingStyle → Realistic. The old
`pcall` that tried to set `Technology` was dead code pretending to be a
safeguard, and it is gone.

### Shadows were never missing — they were being filled in

The map read as flat and shadowless. The obvious diagnosis is wrong: `GlobalShadows`
was already `true`, `Terrain.CastShadow` was `true`, and **all 2,292 parts had
`CastShadow` on**. Every shadow was being cast. None of them were legible.

**A shadow is not a thing that gets drawn; it is the difference between the lit
and the unlit side.** Ambient light and `EnvironmentDiffuseScale` illuminate the
unlit side, so they erase shadows without ever touching a shadow setting. At
`OutdoorAmbient` (118,132,152) and `EnvironmentDiffuseScale` 0.65, a shadowed
surface still received over half the light of a sunlit one — a **2:1 ratio**,
which reads as slightly darker paint, not as shadow. The fix is to raise the sun
and drop the fill, landing near **5:1**, with total light on the lit side roughly
unchanged.

The second problem was the sun's *azimuth*, which is easy to miss because the
elevation was fine. 16.1 / lat 12 pointed the sun `(-0.861, 0.468, -0.199)` —
almost exactly down the X axis. The village plots are square and axis-aligned, so
axis-parallel light strikes one wall face-on and leaves the wall beside it no
darker: **the two faces you can see at once come out the same brightness**, and
the building flattens into a sticker.

Roblox has **no `DirectionalLight` object** — the sun is the only directional
source, and the sole way to aim it is `ClockTime` and `GeographicLatitude`. So
those two numbers were found by sweeping both and measuring `GetSunDirection()`,
rather than by guessing at the solar formula:

| | elevation | axis bias (0 = diagonal) |
|---|---|---|
| 16.1 / lat 12 | 27.9° | **0.749** — down an axis |
| 8.7 / lat −12 | 31.9° | **0.045** — rakes the corner |

31.9° lays down a shadow **1.61× the height** of whatever throws it. Verified two
ways: raycasts toward the sun from ground behind test pillars found 11 of 12
probes occluded — and the twelfth is the 22-stud probe behind the 10-stud pillar,
whose shadow only reaches ~16 studs, so the miss confirms the ratio rather than
contradicting it.

`ShadowSoftness` went 0.22 → 0.05: 0.22 was a deliberately soft penumbra, and the
brief was *well-defined*.

`Atmosphere.Haze` came down with the ambient (0.38 → 0.28). Haze is aerial fill —
it lifts distant shadows exactly the way ambient lifts near ones, so leaving it up
would have kept the far half of the island flat after fixing the near half.

### Generated materials, and a silent trap

Five `MaterialVariant`s — thatch, daub, cobble, ore-bearing rock, wheat. They cost
nothing at runtime: a variant is a skin on an existing base material, not new
geometry. 1,363 parts wear one.

The thatch one matters most. Roofs were previously **Slate with a yellow tint**,
which is a yellow slate roof and reads as exactly that.

**The trap:** Roblox resolves `BasePart.MaterialVariant` against the **direct
children of `MaterialService`** and nothing else. The generator drops new
variants into a nested `AssistantMaterials` folder, four variations apiece — where
nothing will ever look at them. A name that cannot be resolved is **not an
error**: the part quietly renders as its base material. So 800 parts were wearing
skins that did not exist, and the only symptom was that the world looked like
stock Roblox.

`build-world` now checks every name in `SKIN` against `MaterialService` at build
time and `warn`s loudly if one cannot be resolved.

> **The variants are not in this repo.** They live in the place file under
> `MaterialService`, because Rojo does not manage that service. A fresh clone
> builds the same geometry with stock materials and warns about all five. Either
> regenerate them or copy them across.

## Things that bit, so they don't bite twice

**A local function called above its own declaration silently truncated the whole
world.** `makeMessengerTemplate()` was called at line 707 of `build-world.luau`
and declared at line 869. In Lua a name does not exist until its declaration
runs, and an undefined name is `nil` rather than an error - so this parsed
perfectly and threw only when that line executed. Everything after it stopped:
all 16 villages, every blueprint, all four tools, **and the entire lighting
pass**, which therefore had never once run in the life of the project.

Nothing caught it. The `luau` parse check cannot - it is valid syntax. The
undeclared-identifier scan added after the `ZONE_START_HALF` incident only looked
at `ALL_CAPS` names, and this was camelCase. And it was introduced in a tier
whose verification never rebuilt the world.

The check now looks for a `local function` **called at column 0 before its
declaration line**. Indentation is the whole signal: a call from inside another
function body is fine, because that body runs later. A top-level call runs
immediately, and that is the fatal case.

**`Lighting.Technology` is not scriptable.** `build-world.luau` sets it inside a
`pcall`, which silently fails - the property cannot even be *read* from a plugin
thread ("lacking capability RobloxScript"). Inspecting the instance shows
`RBX_OriginalTechnologyOnFileLoad = 3`, i.e. **ShadowMap**, not Future. It has to
be set by hand: Lighting → Technology → Future. Any lighting tuning done before
checking which pipeline is actually live is tuning against the wrong renderer.

**Surface-aiming fixes tall targets and breaks flat ones.** Clamping the aim
point to a part's surface (`nearestPointOn`) was needed because range is measured
in 3D to whatever point you hand `isAimedAt`, and a 30-stud keep's centre sits 15
studs up — unhittable from its own wall. But the same clamp puts a *wide flat*
part's nearest point directly under your feet: the stockpile pallet is 22 × 18,
so a raider standing on it had a horizontal offset of ~0 and the facing test
bailed at `flat.Magnitude <= 0.01`. A breached stockpile could not be looted from
on top of it — 60 swings moved nothing. The facing test exists to stop you
hitting things *behind* you at range; at arm's length there is no behind, so a
near-zero horizontal offset now counts as aimed. Both extremes need handling.

**State that is only published on success reads as absent.** `LootLeft` was
written inside the loot branch, so between breaching a wall and landing the first
swing on the pile the attribute was `nil` — indistinguishable from "nothing left"
to anything watching from outside. It is published at the breach now, from
`refresh`. A value that means "how much is there" must be written when the amount
*becomes* known, not when someone first takes some.


**A big part becomes unhittable as it grows, because range is measured to its
CENTRE.** `isAimedAt` takes a point and checks 3D distance against
`MINE_RANGE` (15). Passing a part's `.Position` is fine for a rock and fatal for
a keep: at 30 studs tall its centre sits ~15 studs up, so standing against its
own wall measures **19.9 studs** and no swing ever lands. Elimination was
therefore impossible — and it passed every test in the stage-2 tier, because the
keep was half the height then. Nothing errored; the keep simply never took
damage.

The fix is `nearestPointOn`, which clamps the aim point to the part's surface, and
every base-part target now uses it. **Measure range to the surface, not the
middle** — and treat "this worked when the object was smaller" as a reason to
re-test, not a reason to assume.

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
