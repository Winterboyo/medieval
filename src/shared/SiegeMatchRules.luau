--!strict
-- First-playtest two-team clock and objective values. Keep these separate from
-- the old Conquest match so the server and a later siege damage service agree.
local Rules = {
	REGULATION_SECONDS = 13 * 60,
	OVERTIME_SECONDS = 2 * 60,
	VAULT_MAX_HEALTH = 750,
	KEEP_OVERTIME_MAX_HEALTH = 900,
}

-- Returns 1 or 2 for the winning side, or 0 for an exact draw. Vault health
-- breaks the tie before Keep exterior health, even if the latter differs more.
function Rules.winnerAtCap(vault1: number, keep1: number, vault2: number, keep2: number): number
	if vault1 ~= vault2 then
		return if vault1 > vault2 then 1 else 2
	end
	if keep1 ~= keep2 then
		return if keep1 > keep2 then 1 else 2
	end
	return 0
end

return Rules
