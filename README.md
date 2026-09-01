# Medieval Land

Roblox game, built in tiers. See the tier order in
`~/.claude/projects/C--Users-winter-projects-medieval-land/memory/tier-build-order.md`.

**Current tier: T2** — three rock nodes that deplete as you mine them and refill
on a curve, and a wall you spend the stone on.

## Layout

| Path | What |
|---|---|
| `medieval-land.rbxl` | The place file. Save it here from Studio: File → Save to File As. |
| `scripts/build-world.luau` | One-shot world setup: terrain, the lake, palms, the rock nodes, the wall site, and the pickaxe tool. Run in Studio, don't put it in the place. Re-runnable. |
| `src/ResourceService.server.luau` | Source of truth for the `ResourceService` Script in `ServerScriptService`. |

These `.luau` files are the source of truth; they get pushed into the place via
the Studio MCP. Edit here, not in Studio, or the two drift.

## The loop

Spawn on the pad at `(0, 86)`, mine one of the three outcrops, walk to the wall
site at `(0, 72)` and hold **E** to spend 10 Stone on a section. The wall is 8
sections wide and 3 courses high, 24 in total, then it is finished.

The world builder places geometry only. Everything that changes at runtime —
how much stone a node holds, how fast it comes back, what a wall section costs —
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

**The swing animation is Roblox's own R15 ToolSlash** (`rbxassetid://522635514`),
played from the server at half speed to stretch its 0.5s to 1s. Two procedural
approaches were tried first and do not work on this place's rig: the characters
here use `AnimationConstraint` joints rather than `Motor6D`, so there is no `C0`
to drive, and writing the constraint's `Attachment0` from the server does not
replicate to clients.

**`Tool.Grip` is expressed in the Handle's own frame.** The Handle is therefore a
plain unrotated invisible block, with the visible round shaft welded over it —
rotating the Handle to lay a cylinder along Z would twist every Grip value with
it.

## Studio MCP

Registered locally as `Roblox_Studio` (`cmd.exe /c %LOCALAPPDATA%\Roblox\mcp.bat`).
Studio must be open with the place loaded. `/mcp` to check the connection.

Known noise: Roblox's `mcp.bat` is malformed — its `else` sits after the closing
paren, so cmd prints `'else' is not recognized` to stderr after each run. Harmless.

The MCP runs with plugin permissions but not `RobloxScript`, so a handful of
properties are unreachable from it: `Lighting.Technology`, `Terrain.Decoration`,
`Terrain.MaterialColors`. If the place looks flat, set Technology by hand in
Properties → Lighting → Technology → Future.
