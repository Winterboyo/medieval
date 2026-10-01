# Skill Observation Log

Observations captured during task-oriented work.

**Status key:** OPEN = not yet actioned | ACTIONED (YYYY-MM-DD) = skill updated/created | DECLINED (YYYY-MM-DD) = user decided not to pursue.

---

## 2026-10-01

### Observation 1: Reconcile competing design authorities before editing

**Status:** OPEN
**Date:** 2026-10-01
**Session context:** Auditing a game project and revising its design document.
**Skill:** New skill candidate: design authority audit
**Type:** open-source
**Phase/Area:** Source review before specification editing

**Issue:** A working-rules file, a design document, and a legacy agent guide stated different locked win conditions. The newer files had uncommitted user edits, so a direct rewrite could have erased an intentional pivot.

**Suggested improvement:** A design-audit workflow should compare authority declarations, current file diffs, and implementation separately; ask the owner to resolve material conflicts; then update the authoritative document and cross references together.

**Principle:** Resolve contradictory source-of-truth claims before turning either one into an executable specification.

### Observation 2: Translate concept art into collision-checked layout constraints

**Status:** OPEN
**Date:** 2026-10-01
**Session context:** Turning a cinematic siege image into a proposed Roblox/Blender battlefield layout.
**Skill:** New skill candidate: concept art to playable map
**Type:** open-source
**Phase/Area:** Visual reference to coordinate proposal

**Issue:** Enlarging castles to match a perspective image displaced a resource pad and old cover zones; copying visible craters and battle props directly would have blocked routes or implied unchosen mechanics.

**Suggested improvement:** Before modeling, separate image composition from playable geometry, preserve mechanic-critical gathering space, propose measured mirrored placements, run clearance checks, and flag illustrative elements that are outside the game scope.

**Principle:** A cinematic image is a visual goal; a playable map needs explicit dimensions, routes, and collision checks.
