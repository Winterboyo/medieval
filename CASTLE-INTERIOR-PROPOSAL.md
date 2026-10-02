# Castle interior proposal — mirrored first playable siege

**Status: SUPERSEDED by `CASTLE-INTERIOR-V2-PROPOSAL.md` (2026-10-01).** The user chose four separate crafting-only specialist buildings: blacksmith forge, fletcher, carpenter, and alchemist, with the stockpile room inside the Keep. The forge replaces the shared workshop in this sketch. This whole page and its diagram are historical, not approved construction instructions. Do not add this interior to `layout.json` or build it. The approved village-like interior is in `layout.json` v2.1.

## Coordinate convention

Use local `(f, z)` coordinates measured from each castle center. `f` increases toward the enemy-facing gate. For Team A, world `x = -280 + f`; for Team B, world `x = 280 - f`. World `z` is unchanged. The wall ring runs from `-91.8` to `+91.8` on both axes; the inner wall face is approximately `±87.8`. All ground-level placements start at `y = 10`.

The layout is a working fortress around an open courtyard. The gate-to-Keep line remains clear for assault and defense. The tunnel exits in the northern forward courtyard; it does not place attackers next to the Keep, stockpile, or barracks spawn room.

## Buildings and access

| Piece | Local footprint `(f, z)` | Access point `(f, z)` | Purpose |
|---|---|---|---|
| **Keep** | `f -76..-32`, `z -22..22` (44 × 44) | Forward door `(-32, 0)`, 12 studs wide | Rear-center win target, visible from the gate down the main courtyard. Separate damage states later; HP and repair rule remain open. |
| **Stockpile/storehouse** | `f -76..-48`, `z 42..68` (28 × 26) | Courtyard door `(-48, 55)`, 8 studs wide | Separate from the Keep. One team resource pot; deposit and looting happen here after their interaction rules are specified. |
| **Barracks** | `f -70..-28`, `z -75..-48` (42 × 27) | Courtyard door `(-49, -48)`, 10 studs wide | Six provisional spawn markers inside. Door leads into the northern courtyard, away from the tunnel exit. No troops or AI regiments. |
| **Workshop** | `f -8..35`, `z 43..75` (43 × 32) | Player door `(5, 43)`; broad ram exit `(35, 59)` | One building with blacksmith forge, alchemist bench, and carpenter bench. Their recipes and interfaces are separate design decisions. |
| **Ram assembly pad** | `f 43..59`, `z 46..64` (16 × 18) | Opens toward the gate | Reserve flat space outside the workshop for the first ram. The route to the gate stays clear; ram cost and movement remain open. |

The main courtyard corridor is `z = -9..9` from the gate at `f = 91.8` to the Keep door at `f = -32`. It is 18 studs clear, matching the single gate bay more closely than the wider road outside. Other courtyard space remains open for fighting and movement between the buildings. Do not place decorative props in this corridor.

### Barracks spawn markers

Use six provisional local positions: `(-60,-66)`, `(-50,-66)`, `(-40,-66)`, `(-60,-57)`, `(-50,-57)`, `(-40,-57)`. They sit inside the barracks and mirror to Team B. Six is a preview capacity, not a final team-size decision. Retire `temporary_preview_spawns` in `layout.json` when the interior is approved and implemented.

### Specialists inside the workshop

Reserve three distinct stations along its south wall: blacksmith toward the west/rear, alchemist in the middle, carpenter toward the east/front and ram exit. This is spatial zoning only. Outputs, recipes, crafting time, and NPC interaction are still open.

## Defense and circulation

- **Ballista placement recommendation:** one fixed defensive ballista per castle on a widened gatehouse roof, centered over the gate at local `(f = 91.8, z = 0)`. This commands the main road without consuming a conical corner-tower roof. A ladder or stair from inside the gatehouse near `(79, -23)` reaches it. Whether a defender operates it, firing arc, damage, reload, and cost remain open.
- **Corner towers:** retain all four prominent roof silhouettes from the reference family. Give each a reachable fighting deck below or around its conical roof. Reserve interior ladder positions near local `(-82,-80)`, `(-82,80)`, `(80,-80)`, and `(80,80)`; exact ladder mesh footprints are art placeholders. This preserves tower access even if a wall section is destroyed.
- **Wall circulation:** keep at least a walkable strip between buildings and the inner wall. The tightest proposed gap is 11.8 studs behind the rear buildings. Test tower ladders and the wall walk with a 5-stud avatar.
- **Courtyard:** leave the gate-to-Keep line and the space between tunnel exit, barracks, and center open. Do not add a second wall ring, houses, or permanent props that block the routes.

## Tunnel and objective distances

The approved tunnel exit is local `(20, -55)` in both castles. Proposed straight-line distances from that exit to access points are about **76 studs to the Keep door**, **129 to the stockpile door**, and **69 to the barracks door**. Actual walking routes are at least as long. This meets the map proposal's minimum 60-stud courtyard route to the Keep and stockpile. Attackers who use the tunnel skip the gate fight but must still cross defended courtyard space.

## Preliminary fit check

Every footprint sits inside the ring's inner face. The main 18-stud corridor is clear. The closest building-to-building gap is 20 studs between Keep and stockpile; the workshop and ram pad are intentionally 8 studs apart. No building overlaps the tunnel exit or a corner-ladder marker. These are 2D checks only; doors, roof access, ram turning, spawn safety, and sightlines need a Studio preview before final art.

## Historical approval question — replaced by village-like revision

The earlier question proposed a shared workshop. It is no longer current. Review `CASTLE-INTERIOR-V2-PROPOSAL.md` for the new four-building footprint. Structure HP, recipes, and ballista combat rules remain separate decisions.
