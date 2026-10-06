--!strict
-- Medieval Land - which pieces of the CargoBag model show for a given bag of goods (DESIGN.md
-- "visible carried bag"). Shared by the bag worn on the back (CargoBagService) and the bag dropped
-- at knockdown (FallenBagService), so both read the same way.
--
--   sack   -> SackSlack (load 1-8), SackHalf (9-16), SackFull (17-25)
--   heap   -> the good with the most load; accent -> the good with the second most
--   shown  -> how much of the heap rises above the mouth: ~1/3 when nearly empty, all of it full

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Cargo = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Cargo"))

local CargoBagLook = {}

-- Goods use Cargo's names; the model's pieces say "Iron" for Smelted Iron.
CargoBagLook.PIECE = { Wood = "Wood", Stone = "Stone", Ore = "Ore", Wool = "Wool", SmeltedIron = "Iron" }

export type Look = { show: { [string]: boolean }, heap: string?, shown: number, load: number }

function CargoBagLook.pick(contents: { [string]: number }): Look
	local load = Cargo.loadOf(contents)
	local list = {}
	for index, resource in Cargo.ORDER do
		local count = contents[resource] or 0
		if count > 0 and CargoBagLook.PIECE[resource] then
			table.insert(list, { resource = resource, load = count * Cargo.WEIGHT[resource], index = index })
		end
	end
	table.sort(list, function(a, b)
		if a.load ~= b.load then
			return a.load > b.load
		end
		return a.index < b.index
	end)
	local show: { [string]: boolean } = {}
	local heap: string? = nil
	if load > 0 then
		show[if load <= 8 then "SackSlack" elseif load <= 16 then "SackHalf" else "SackFull"] = true
		if list[1] then
			heap = "Heap" .. CargoBagLook.PIECE[list[1].resource]
			show[heap :: string] = true
		end
		if list[2] then
			show["Accent" .. CargoBagLook.PIECE[list[2].resource]] = true
		end
	end
	local fill = math.clamp((load - 1) / (Cargo.MAX_LOAD - 1), 0, 1)
	return { show = show, heap = heap, shown = 0.35 + 0.65 * fill, load = load }
end

-- How far (in the piece's own up direction) to sink the heap and accent below their modelled
-- position, given the model's current heap size.
function CargoBagLook.sink(model: Model, look: Look): number
	local heap = look.heap and model:FindFirstChild(look.heap)
	if heap and heap:IsA("BasePart") then
		return (1 - look.shown) * heap.Size.Y
	end
	return 0
end

function CargoBagLook.isGoods(partName: string): boolean
	return partName:match("^Heap") ~= nil or partName:match("^Accent") ~= nil
end

return CargoBagLook
