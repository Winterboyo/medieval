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

### Observation 3: Preserve source identifiers in shared 3D scenes

**Status:** OPEN
**Date:** 2026-10-01
**Session context:** Updating a layout-driven Blender castle builder inside a scene that already contained similarly named objects.
**Skill:** New skill candidate: layout-driven Blender asset validation
**Type:** open-source
**Phase/Area:** Generated-object identity and verification

**Issue:** Blender automatically suffixed new object names when another scene already used the same layout-derived names, so mirror validation by object name falsely failed even though the geometry was placed correctly.

**Suggested improvement:** Store a stable source identifier in a custom object property, use that property for mirror and export checks, and treat the Blender display name as advisory. Validate openings and passages with geometric rays after building.

**Principle:** When a tool may rewrite display names, keep machine-readable source IDs separate from presentation names.

### Observation 4: Check the final asset-import path before a large 3D build

**Status:** OPEN
**Date:** 2026-10-02
**Session context:** Building mirrored Blender castle interiors and integrating them with a live Roblox Studio place.
**Skill:** New skill candidate: Blender-to-Roblox asset handoff
**Type:** open-source
**Phase/Area:** Pipeline capability check

**Issue:** The Blender bridge could build, inspect, and export the meshes, while the Studio bridge could edit scripts and inspect the place but could not select a local FBX in Studio's 3D Importer. The art and in-game lighting could be completed independently, but the final visual integration required a human UI import.

**Suggested improvement:** Verify both screenshot capability and the final Studio import mechanism at the start of a 3D asset task. If the import is UI-only, export a small test asset first, write an idempotent alignment script based on two layout anchors, and communicate the exact one-step handoff before undertaking a large batch.

**Principle:** A verified export is not an in-game asset until the import and alignment path has been exercised.

### Observation 5: Resolve visual versus collision complaints before changing a floor

**Status:** OPEN
**Date:** 2026-10-02
**Session context:** Revising the blacksmith floor after the user said it "doesn't work."
**Skill:** New skill candidate: reference-driven 3D revision
**Type:** open-source
**Phase/Area:** Interpreting feedback and preparing partial imports

**Issue:** The phrase first suggested a collision failure, but the user meant that the flat rectangular paving did not match the curved stone reference. The revised dark foundation also lived in the forge shell, so an export containing only the visible paving and detail meshes would have left Studio with the old floor color.

**Suggested improvement:** Ask which failure mode the user means while inspecting the current view. Trace every changed face back to its owning mesh before making a partial FBX export; include all changed owners and test the replacement script against a rotated test import.

**Principle:** Visual changes are complete only when the exported and in-game mesh set matches the reviewed Blender view.
