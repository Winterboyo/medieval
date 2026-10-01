--!strict
-- Medieval Land - which game this server runs.
--
-- CLAUDE.md §3: code that is out of scope for the two-team pivot stays DORMANT,
-- switched off from the match flow by a flag rather than deleted. This is that
-- flag. Every script that behaves differently between the two reads it here, so
-- there is exactly one place that decides.
--
--   TwoTeam   two teams, two pre-built castles from layout.json, pooled team
--             goods, respawn at your own barracks (the game being built)
--   Conquest  the old free-for-all: 16 player-built villages, squads, the fold,
--             the shrinking zone (dormant; needs the parked old island back)

local GameMode = {}

GameMode.MODE = "TwoTeam"
GameMode.TwoTeam = GameMode.MODE == "TwoTeam"

return GameMode
