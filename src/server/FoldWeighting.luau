--!strict
-- Medieval Land - how an eliminated player is dealt out to a surviving squad.
--
-- This is a ModuleScript for one reason: it is the only part of Stage 3 that is
-- pure arithmetic, and pure arithmetic can be checked against a table of made-up
-- squad sizes without needing twelve players in a server. Everything else about
-- teams needs real players and a real siege; this does not, so it is kept where
-- it can be tested on its own.
--
-- It holds no state and reads nothing. MatchService supplies the sizes and the
-- roll, which also makes `choose` deterministic and therefore assertable.

local FoldWeighting = {}

-- Inverse size. A lone survivor is twice as likely to receive a worker as a pair
-- and four times as likely as a squad of four.
--
-- Deliberately not uniform. DESIGN.md's whole reason for folding the eliminated
-- into somebody rather than spectating them is that a player who is out should
-- still matter to the match - and if the fold were uniform, or worse, weighted by
-- strength, then taking a keep would pay the strongest player a free workforce
-- and the match would snowball to whoever won first. Weighting toward the small
-- makes the reward for a kill the kill itself, not compounding labour.
function FoldWeighting.weightFor(size: number): number
	return 1 / math.max(1, size)
end

-- Which squad receives the next worker, given every candidate's size and a roll
-- in [0, 1). Returns an index into `sizes`, or nil if there is nobody to give to.
--
-- The roll is passed in rather than drawn here so the choice is reproducible: a
-- test can walk the roll from 0 to 1 and see the whole distribution.
function FoldWeighting.choose(sizes: { number }, roll: number): number?
	local total = 0
	for _, size in sizes do
		total += FoldWeighting.weightFor(size)
	end
	if total <= 0 then
		return nil
	end

	local target = math.clamp(roll, 0, 0.999999) * total
	local running = 0
	for index, size in sizes do
		running += FoldWeighting.weightFor(size)
		if target < running then
			return index
		end
	end
	-- Only reachable on floating point drift at the very top of the range.
	return #sizes
end

-- The share of workers each squad should expect, for a given set of sizes. Not
-- used by the match: this exists so the weighting can be stated as a number in a
-- test and in the README rather than argued about.
function FoldWeighting.shares(sizes: { number }): { number }
	local total = 0
	for _, size in sizes do
		total += FoldWeighting.weightFor(size)
	end
	local out: { number } = {}
	for index, size in sizes do
		out[index] = if total > 0 then FoldWeighting.weightFor(size) / total else 0
	end
	return out
end

return FoldWeighting
