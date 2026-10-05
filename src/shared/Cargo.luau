--!strict
-- Medieval Land - the carried bag's rules (DESIGN.md "First-playtest material bag").
--
-- Pure numbers and arithmetic, shared so the server that enforces them and any client that
-- shows them cannot disagree. Every value here is a first-playtest PLACEHOLDER from DESIGN.md,
-- tuned after the playtest, except where marked decided.
--
-- The bag holds raw materials and Smelted Iron only. Finished gear never enters it.

local Cargo = {}

-- The goods a bag and a team vault can hold, in display order. Grain is parked (DESIGN.md
-- "first-playable gathered resources"): no live node yields it and it has no load weight.
Cargo.ORDER = { "Wood", "Stone", "Ore", "Wool", "SmeltedIron" }

Cargo.LABEL = {
	Wood = "Wood",
	Stone = "Stone",
	Ore = "Ore",
	Wool = "Wool",
	SmeltedIron = "Smelted Iron",
}

-- Load points per unit. Ore and Smelted Iron weigh the same, so smelting never changes load.
Cargo.WEIGHT = {
	Wood = 1,
	Wool = 1,
	Stone = 2,
	Ore = 4,
	SmeltedIron = 4,
}

-- Up to NORMAL_LOAD carries at normal speed; a pickup may take the bag up to MAX_LOAD, and the
-- player is overloaded above NORMAL_LOAD. Nothing may take the bag past MAX_LOAD.
Cargo.NORMAL_LOAD = 20
Cargo.MAX_LOAD = 25

function Cargo.carries(resource: string): boolean
	return Cargo.WEIGHT[resource] ~= nil
end

-- Total load of a { [resource]: count } table. Unknown names count nothing.
function Cargo.loadOf(contents: { [string]: number }): number
	local total = 0
	for resource, count in contents do
		local weight = Cargo.WEIGHT[resource]
		if weight then
			total += weight * count
		end
	end
	return total
end

-- How many whole units of `resource` a bag at `load` accepts out of `wanted`. A bag with free
-- points may still refuse a heavier good: 3 free points take 3 Wood or 1 Stone but no Ore.
function Cargo.fits(load: number, resource: string, wanted: number): number
	local weight = Cargo.WEIGHT[resource]
	if not weight or wanted <= 0 then
		return 0
	end
	local room = math.floor((Cargo.MAX_LOAD - load) / weight)
	return math.clamp(math.floor(wanted), 0, math.max(room, 0))
end

function Cargo.overloaded(load: number): boolean
	return load > Cargo.NORMAL_LOAD
end

return Cargo
