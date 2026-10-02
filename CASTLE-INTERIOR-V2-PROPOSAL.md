# Castle interior v2 — village layout proposal

**Status: PROPOSED 2026-10-01; awaiting user approval for `layout.json` and Blender generation.** The exterior ring, gate, and tunnel endpoints are already in `layout.json` v2.0. Its `interior` fields are still `null`. This proposal replaces the shared-workshop sketch in `CASTLE-INTERIOR-PROPOSAL.md` with the four separate specialist buildings chosen in `DESIGN.md`. [Top-down schematic](concepts/castle-interior-village-proposal.svg) shows the measured footprints and clear routes.

This approval concerns **positions, footprints, doors, and reserved paths**. Recipes, Keep HP, ballista combat, ram damage, and final art detail remain separate gameplay and asset decisions. No coordinates below are approved until the user accepts this proposal.

## Coordinates and mirror

Use local `(f, z)` ground coordinates from each castle center. `f` increases toward that castle's enemy-facing gate. `-z` is north. All ground-level footprints and door markers start at Roblox `y = 10`.

- Team A world `x = -280 + f`; Team B world `x = 280 - f`; world `z` is unchanged. This is an exact mirror across `x = 0`.
- The existing square wall ring spans `f,z = -91.8..91.8`; its inner face is about `±87.8`. The gate is at `(91.8, 0)`, facing outward. The tunnel exit is already fixed at `(20, -55)`.
- A rectangle written `f a..b; z c..d` includes its footprint edges. Door points are on the building edge and face the open courtyard. Keep footprint and all proposed buildings remain within the existing ring; no wall, gate, tower, or tunnel coordinate changes.

## Buildings and objective positions

| Named piece | Local footprint `(f, z)` | Door / interaction point `(f, z)` | Placement reason |
|---|---|---|---|
| Keep | `-76..-32; -22..22` (44 × 44) | front door `(-32, 0)`, target clear opening 10 studs | Rear-center, visible from the gate along the open courtyard. It is the damageable win target and contains the team stockpile room. |
| Stockpile room inside Keep | `-72..-54; 6..18` (18 × 12), within the Keep footprint | interior door `(-63, 6)`, target opening 8 studs; deposit and loot interaction `(-63, 12)` | A distinct room reached from the Keep entrance hall. There is no separate courtyard storehouse. A raider can reach and loot it via the tunnel without a gate or wall breach. |
| Barracks | `-70..-28; -75..-48` (42 × 27) | courtyard door `(-49, -48)`, target opening 10 | Rear-north team spawn, away from the tunnel exit. No AI troop spawns. |
| Blacksmith forge | `-12..16; 47..75` (28 × 28) | north/courtyard door `(2, 47)`, target opening 8 | South-middle working building, reachable from the gate and stockpile; replaces the old shared workshop. |
| Alchemist | `-18..6; -76..-50` (24 × 26) | south/courtyard door `(-6, -50)`, target opening 8 | North-middle, with a lane behind the Keep and room before the tunnel landing. |
| Fletcher | `41..66; -76..-50` (25 × 26) | south/courtyard door `(53.5, -50)`, target opening 8 | North-forward, convenient for the gatehouse and wall defenders without blocking the tunnel exit. |
| Carpenter | `31..55; 46..74` (24 × 28) | north player door `(43, 46)`, target opening 8; forward ram opening `(55, 60)`, target 12 | South-forward, beside the ram assembly pad and its clear route to the gate. |

The Keep has an unobstructed ground-level entrance hall at `f = -72..-32; z = -6..6`, connecting its front door to the stockpile room's interior door. The stockpile interaction sits inside that room; no special gate or wall breach condition is added to looting. The remaining former storehouse area at `f = -76..-48; z = 43..69` is open courtyard, with no replacement building or permanent prop in this proposal.

The specialist buildings are distinct small village-like structures around open courtyard paths. They are crafting-only in v1; no old rank, trading, theft, or negotiation stations. The blacksmith may have a forge chimney and the carpenter a broad ram opening, but exact furnishing and roof art are not layout decisions. Roof massing targets for the first visual pass: specialist eaves about 9–11 studs above the pad and peaks about 15–18; barracks peak about 18–21; the Keep remains the dominant interior silhouette. These are art placeholders to inspect beside a 5-stud avatar, not approved final mesh heights.

## Circulation and defensive fixtures

- **Main gate-to-Keep route:** reserve `z = -9..9` from the inside of the gate at `f = 87.8` to the Keep door at `f = -32`; 18 studs clear of all props and collision. This is the main fight and ram approach lane. The existing 10-stud gate arch is the narrowest passage; the ram body must fit it, or the gate asset must be widened before export.
- **Tunnel landing and egress:** reserve `f = 14..26; z = -61..-49` around the exit `(20,-55)`, and a 12-stud clear egress strip `f = 14..26; z = -49..-9` to the courtyard. No building, barricade, tree, or decorative prop in this strip. The exit remains exposed to defenders and is not beside either objective.
- **Ram assembly and turning:** reserve a 20 × 20 pad `f = 57..77; z = 44..64`, adjacent to the carpenter's forward opening. Reserve `f = 57..82; z = 9..44` as a clear turning area into the main corridor. No prop or parked siege tool may permanently block the route. The ram's actual width, turning radius, and collision still require an avatar-scale Studio test.
- **Access around the Keep:** keep a north passage between the Keep and barracks and an open south rear courtyard where the separate storehouse was proposed. Keep the `f = -30..-18` strip open beside the Keep's front corners so players can circulate around it from the main courtyard. The minimum rear building-to-wall strip is 11.8 studs; reserve it for foot traffic and repair access.
- **Tower access:** reserve ladder or stair markers near `(-80,-80)`, `(-80,80)`, `(80,-80)`, and `(80,80)`. Defenders must be able to reach a fighting deck on each corner tower. The final ladder meshes must preserve the perimeter strip.
- **Gatehouse ballista:** reserve one fixed mount at `(91.8,0)` on the gatehouse roof and an inside ladder or stair near `(79,-23)`. The mount faces the central road. This is a location reservation, not an answer to operator, ammunition, arc, HP, or reload rules.
- **Barracks preview spawns:** place six provisional ground markers at `(-60,-66)`, `(-50,-66)`, `(-40,-66)`, `(-60,-57)`, `(-50,-57)`, and `(-40,-57)`, mirrored for Team B. These are spatial test points, not a final 6v6 team-size decision. Remove `temporary_preview_spawns` when this interior is migrated into `layout.json`.

## Geometric check

- All exterior building footprints fit inside the inner wall face; the stockpile room fits inside the Keep with a 4-stud minimum setback from its outer footprint. The smallest building-to-wall gap is **11.8 studs**; the ram pad leaves **10.8 studs** toward the front wall. The carpenter and ram pad intentionally sit **2 studs** apart at their adjacent edges; all other exterior building pairs are separated by at least 10 studs.
- No building crosses the 18-stud main corridor, the 12-stud tunnel egress strip, the 20 × 20 ram pad, or the ram turning area. The tunnel landing lies between the alchemist and fletcher, with an unobstructed route south into the courtyard.
- Straight-line distances from the tunnel exit are about **76 studs to the Keep's front door**, **107 studs to the stockpile interaction**, and **69 studs to the barracks door**. The stockpile route must go through the Keep entrance and interior room door, so its actual walk is longer than 107 studs. A tunnel raider still crosses defended courtyard space and enters the Keep to loot.
- This is a 2D footprint check, not a collision or sightline test. In Studio, verify a 5-stud avatar can enter each exterior door and the stockpile room, leave every spawn, reach each tower deck, and move a ram from its pad through the gate; view the Keep, stockpile room, and tunnel exit from attacker and defender cameras.

## On approval

1. Add these proposed local footprints, the Keep's internal stockpile room and access hall, doors, spawns, pads, clear routes, tower access, and ballista mount to both castles' `interior` entries in `layout.json`, applying the exact mirror transform. Keep the existing exterior and tunnel endpoints.
2. Update any generator or validator that creates or reads castle interior data. The old Blender `assets/castle/build_castle.py` expects `keep`, `workshop`, `King_Storage`, and cannons from the superseded v1.1 layout; it is not a source for the new geometry and must be revised before using it for this interior.
3. Build one named asset or group at a time under `AGENTS.md`'s Blender screenshot contract. Test the full gray footprint layout and one art piece in Studio before finishing/exporting the castle set.

**Approval requested:** accept this mirrored interior footprint and route plan for `layout.json` and castle generation, or name the building or route to move.
