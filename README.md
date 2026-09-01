# Medieval Land

Roblox game, built in tiers. See the tier order in
`~/.claude/projects/C--Users-winter-projects-medieval-land/memory/tier-build-order.md`.

**Current tier: T2** — three rock nodes that deplete as you mine them and refill
on a curve, and a wall you spend the stone on.

## Layout

| Path | What |
|---|---|
| `src/server/ResourceService.server.luau` | The `ResourceService` Script in `ServerScriptService`. Rojo syncs it. |
| `scripts/build-world.luau` | Builds the board: terrain, lake, scenery, nodes, build sites, pickaxe, lighting. Rojo syncs it to `ServerStorage.BuildWorld`; rebuild from the command bar with the clone snippet below (a plain `require` returns a cached, stale module). Re-runnable — it tears down what it built last time. |
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

`default.project.json` deliberately maps **only** `ServerScriptService`. Nothing
else is named in it, so Rojo will not touch Workspace, Terrain, Lighting or
StarterPack.

That is not laziness, it is a limit. Terrain is binary voxel data and cannot be
live-synced at all. And the world is *generated* — 44 palms, three outcrops, the
wall site and the pickaxe are the output of a script, not files on disk. Rojo
syncs static instance trees from files; it does not run generators. Freezing the
output into an `.rbxmx` for Rojo to sync would trade a readable 700-line
generator for a binary blob, which is a downgrade.

So the split is: the thing that changes every session (the service) syncs
automatically; the thing that changes rarely (the world) stays a deliberate
one-shot. To rebuild a place from scratch: run `scripts/build-world.luau` in the
command bar, then connect Rojo.

## The board

A 5×5 grid of 72-stud square tiles, centred on the origin, laid out like a Catan
board. The layout is fixed rather than shuffled, in `LAYOUT`:

```
G W S G D      L lake     S stone
S G W D G      W wood     G grass
W D L G S      D desert
G S D W G
D G W S G
```

Each tile kind gets its own terrain material and its own scenery, which is what
makes a tile readable from ground level rather than only from above. The
surround is deliberately a *different* material from the grass tiles — when they
matched, the board stopped reading as a board and became landscape with lines
drawn on it.

**One stone outcrop per stone tile**, at the tile's centre — a stone tile *is*
the node. Five tiles, five nodes, roughly 160 studs apart. That spacing is not
decoration: the walk between nodes is what gives the regen curve teeth.

**A castle plot on every interior tile corner** — the Catan settlement spots, 16
of them, where four tiles meet.

## The loop

Spawn on the pad south of the board, mine an outcrop, then hold **E** at a build
site to spend 10 Stone on a block. Two site kinds, both 24 blocks:

| Kind | Shape |
|---|---|
| `Wall` | 8 sections wide, 3 courses high. The Tier 1 starter sink, kept. |
| `Castle` | A square ring stacked into a hollow tower, 8 blocks per course, 3 courses. |

The world builder tags each site with a `Kind` attribute; `ResourceService` owns
what that tag means. Adding a third shape is a new branch in `layoutOf` and
nothing else.

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
| rotating all three | 25 | 51 | 78 | 99 | 126 | **151** |

Camping asymptotes as its node pins at the floor. Rotation is linear and
sustainable — 3.1x the stone, and it ends with all three nodes back at 24/24
despite spending 26 of those 180 seconds walking rather than mining.

As a node is worked down its blocks disappear from the top, and a billboard over
it shows `amount / capacity`. The bar is tinted by the node's **current regen
rate**, not its fill — green where it pays to walk away, dull where the node has
been worked past the point of being worth it. Otherwise the curve is a hidden
number nobody can learn. Mining a spent node still swings and still throws chips,
it just pays nothing.

### Mining

`StarterPack` holds the `Pickaxe`; `ResourceService` auto-equips it on spawn and
listens for `Tool.Activated`, which the engine fires on the **server** — so there
is no RemoteEvent yet. That arrives at T3. The wall uses a `ProximityPrompt`,
whose `Triggered` is likewise a server event.

A swing takes 1 second. Stone is granted at the 0.5s mark, not on the click, and
only if a node is within 15 studs **and** roughly in front of you.

## Things that bit, so they don't bite twice

**`Terrain:FillBall(..., Enum.Material.Water)` is a silent no-op.** Since the
Shorelines change, water is not a material in the solid voxel grid — it is its
own `LiquidOccupancy` channel — and the whole `Fill*` family cannot write it.
Nothing errors; you just get a dry hole. The lake is written with
`ReadVoxelChannels`/`WriteVoxelChannels` instead.

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
