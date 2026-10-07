# King and throne chamber layout proposal

**Status: PROPOSED, not approved.** The user chose the King himself as the damageable win target. This proposal places a throne chamber inside each already approved Keep without moving either Keep, gate, castle wall, barracks, specialist building, tunnel, or resource vault. Do not change `layout.json`, rebuild castle art, or place a permanent King model from this proposal until its measurements are approved. `DESIGN.md` owns the King objective; `layout.json` v2.2 still owns the currently approved coordinates.

## Existing approved space

- Each Keep exterior is 44 × 44 studs, on a floor at y = 10. Team A occupies x = -496..-452 and z = -22..22; Team B mirrors across x = 0.
- The central entrance hall runs from each front door to the rear of the Keep in z = -6..6. Its clear front door is 10 studs wide.
- The former stockpile room is 18 × 12 studs in the **south** side of the Keep, z = 6..18. It stays the team vault deposit room. Its door is at z = 6, with an 8-stud opening. It is not the damage target.
- The **north** side of the same Keep, z = -18..-6, has no named room in `layout.json` v2.2. This is a footprint observation, not proof that the exported mesh is clear; the current mesh must be checked before art changes.

## Proposed mirrored throne chambers

- **Team A:** `A_Throne_Room`, x = -492..-474, z = -18..-6, floor y = 10 (18 × 12 studs). Door at (-483, 10, -6), with an 8-stud clear opening from the central hall.
- **Team B:** `B_Throne_Room`, x = 474..492, z = -18..-6, floor y = 10 (18 × 12 studs). Door at (483, 10, -6), also 8 studs clear.
- **King and throne center:** A (-483, 10, -15); B (483, 10, -15). The seated Kings face toward +z and the doorway. Keep the throne against the rear wall and leave a walkable approach in front. A proposed maximum throne/dais footprint is 6 × 4 studs; the King, not the chair or dais, is the damage target.
- The existing vault room remains opposite the throne chamber at z = 6..18. Both rooms branch from the central hall. From the gate, attackers enter the Keep, reach the hall, and turn into the north throne chamber. The vault deposit interaction remains available to its own team in the south chamber.

```text
                  NORTH (-z)
         +-----------------------------+
         |  KING + THRONE  |           |
         |  chamber 18×12  |           |
         |       door      |           |
         +---------+-------+-----------+
rear     |        central entrance hall |  front door -> gate
         +---------+-------+-----------+
         |       door      |           |
         |  TEAM VAULT     |           |
         |  deposit 18×12  |           |
         +-----------------------------+
                  SOUTH (+z)
```

## Gameplay and verification boundary

- The King begins each match seated with 750 HP. Only an enemy hit reaching the King's visible body may reduce King HP. Own-team attacks and hits through the chamber wall, closed door, floor, or throne do not count. Hand tools, swords, Bow Arrows, and Crossbow Bolts may hit him; the ram still damages only the outer gate. The team vault remains a separate, non-lootable resource balance.
- The King's exact body-matched collision/hit volumes should be fitted to the approved model or a 5-stud avatar-scale placeholder and validated from normal player camera angles. This proposal approves no invisible oversized target or weak point.
- At 0 King HP the match ends immediately in the first playable. The later throne-takeover scene is recorded in `IDEAS.md` and does not block the first playtest.
- In Studio, check that a 5-stud avatar can reach the throne from the gate and tunnel routes, both room doors remain clear, several attackers and defenders can fight without becoming stuck, the deposit prompt does not overlap the King interaction, and no attack registers through a wall. Review crowding at 3v3 before judging 15v15 capacity.
- This room is deliberately compact. If fights inside it prove too cramped, propose a larger chamber with new measured geometry rather than expanding the hitbox or moving the throne informally.

## Approval requested

Approve or revise the two 18 × 12 throne rooms, 8-stud doors, and King centers above. Approval would permit adding these entries to `layout.json` and coordinating a separate King/throne art task with the other builder. It would not approve the King model's appearance or the later ending animation.
