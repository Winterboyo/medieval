# Medieval Land

Roblox game, built in tiers. See the tier order in
`~/.claude/projects/C--Users-winter-projects-medieval-land/memory/tier-build-order.md`.

**`DESIGN.md` is the authority on scope.** It is v2, post-Conquest-pivot, and it
says so itself: if anything here conflicts with an older note, the doc wins.

**Where this is:** a Catan board filling the whole map, five resources with a tool
each, and bases with a walled perimeter, a gate and a raidable stockpile.

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
| `src/server/ResourceService.server.luau` | The `ResourceService` Script in `ServerScriptService`. Rojo syncs it. |
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

A 7×7 grid of 72-stud square tiles. 7 × 72 = 504 against a 512 map, so the board
*is* the world — there is no surrounding countryside and no lake. It is dead
flat, because relief would fight the grid and bury nodes.

The layout is fixed rather than shuffled, so the map is a place you can learn:

```
F P G H M F P      F forest / Wood      H hills / Stone
G M H F P G H      P pasture / Wool     M mountains / Ore
P F M G H M F      G fields / Grain     V village (spawn)
H G P V F P G
M H F P G H M
F P G M H F P
G M H F P G M
```

Six terrain materials, one per tile kind, because a tile you cannot identify from
ground level is just coloured floor. **One node per resource tile, at its centre
— a tile *is* its node.** 48 nodes: 10 Wood, 10 Wool, 10 Grain, 9 Stone, 9 Ore.

The village at the centre has the spawn pad and the starter wall, and grows
nothing.

**A castle plot on every interior tile corner** — the Catan settlement spots —
minus the ring around the village, so spawn does not open onto somebody's keep.
32 of them.

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

A base is the doc's v1 structure: a perimeter wall on **one HP value**, **one
gate**, and a **stockpile**. 16 of them on a checkerboard of the interior tile
corners — roughly the player count Conquest is written for.

**The ring of blocks is not twenty-odd little walls.** It is a readout: how many
blocks stand is drawn from the single wall value. Each purchase of 4 Wood + 4
Stone buys 25 HP and raises one block; damage lowers the value and drops blocks
to match. A full wall is 19 blocks, 475 HP.

**The gate is the only place the wall can be hurt.** That is the point of there
being one — a raid is a commitment to one approach rather than chipping at
whichever face happens to be nearest.

**The stockpile holds the exposed slice.** When the wall falls, a snapshot is
taken of 20% of what the owner holds; that snapshot is the entire raid. The other
80% is safe. This is what makes a loss sting without being a wipe.

The snapshot matters. Recomputing "20% of what they hold" on every swing
converges on taking everything, which is exactly the wipe the doc is avoiding.

One swing does four things depending on what you are aimed at, in order:

| Priority | Target | Effect |
|---|---|---|
| 1 | Another player | 20 damage |
| 2 | An enemy gate, wall standing | 25 damage to the wall |
| 3 | An enemy stockpile, wall down | Loots 4 of a resource from the snapshot |
| 4 | A node your tool can work | Harvests 1 |

A person beats their gate, and all of it beats the node you happen to be standing
next to — otherwise you could not fight beside a node.

Breaching re-enables the owner's build prompt, so a wall can be repaired back up.

The spawn pad has an 8 second forcefield. It was 0 while nothing could hurt you;
with combat, a forcefield-free spawn is a place to be farmed on respawn.

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
