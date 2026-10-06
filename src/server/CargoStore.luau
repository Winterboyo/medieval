--!strict
-- Medieval Land - every transfer into, out of, and between carried bags and team vaults.
--
-- THE STATE IS THE INSTANCES. A player's bag is the Player child folder "Cargo" (one IntValue per
-- good, the HUD's published contract); a team's vault is the Team child folder "Goods" that
-- CastleService creates. No shadow tables: whatever reads those folders, on any script or client,
-- reads the truth.
--
-- CONSERVATION. Each function changes counts only after it has validated the whole request, and
-- none of them yields, so a transfer cannot be half-done or interleaved with another. Every unit
-- leaving one place arrives in exactly one other place, except gathering (the node depletes by the
-- same amount in ResourceService) and the match reset (everything clears).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Cargo = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Cargo"))

local CargoStore = {}

local function counter(folder: Instance, resource: string): IntValue
	local existing = folder:FindFirstChild(resource)
	if existing and existing:IsA("IntValue") then
		return existing
	end
	local made = Instance.new("IntValue")
	made.Name = resource
	made.Parent = folder
	return made
end

local function publishLoad(player: Player, bag: Folder)
	local contents = {}
	for _, resource in Cargo.ORDER do
		contents[resource] = counter(bag, resource).Value
	end
	local load = Cargo.loadOf(contents)
	bag:SetAttribute("Load", load)
	bag:SetAttribute("Overloaded", Cargo.overloaded(load))
	player:SetAttribute("CargoOverloaded", Cargo.overloaded(load))
end

-- The player's bag, created on first use with every good at zero.
function CargoStore.bag(player: Player): Folder
	local bag = player:FindFirstChild("Cargo")
	if not (bag and bag:IsA("Folder")) then
		bag = Instance.new("Folder")
		bag.Name = "Cargo"
		bag:SetAttribute("NormalLoad", Cargo.NORMAL_LOAD)
		bag:SetAttribute("MaxLoad", Cargo.MAX_LOAD)
		for _, resource in Cargo.ORDER do
			counter(bag :: Folder, resource)
		end
		publishLoad(player, bag :: Folder)
		bag.Parent = player
	end
	return bag :: Folder
end

function CargoStore.contents(player: Player): { [string]: number }
	local bag = CargoStore.bag(player)
	local contents = {}
	for _, resource in Cargo.ORDER do
		contents[resource] = counter(bag, resource).Value
	end
	return contents
end

function CargoStore.load(player: Player): number
	return Cargo.loadOf(CargoStore.contents(player))
end

-- A team's vault, with a counter for every good a bag can hold. CastleService made the folder;
-- this only adds counters it lacks (Smelted Iron is not in its older goods list).
function CargoStore.vault(team: Team): Folder?
	local goods = team:FindFirstChild("Goods")
	if not (goods and goods:IsA("Folder")) then
		return nil
	end
	for _, resource in Cargo.ORDER do
		counter(goods, resource)
	end
	return goods
end

-- Put up to `wanted` whole units into the bag; returns how many were accepted. The caller takes
-- exactly that many from wherever they came from (a node depletes by the return value).
function CargoStore.give(player: Player, resource: string, wanted: number): number
	if not Cargo.carries(resource) then
		return 0
	end
	local bag = CargoStore.bag(player)
	local accepted = Cargo.fits(Cargo.loadOf(CargoStore.contents(player)), resource, wanted)
	if accepted > 0 then
		local c = counter(bag, resource)
		c.Value += accepted
		publishLoad(player, bag)
	end
	return accepted
end

-- Remove exactly `count` units, or nothing if the bag holds fewer. For crafting and ram
-- contributions later; nothing calls it yet.
function CargoStore.take(player: Player, resource: string, count: number): boolean
	if not Cargo.carries(resource) or count <= 0 or count ~= math.floor(count) then
		return false
	end
	local bag = CargoStore.bag(player)
	local c = counter(bag, resource)
	if c.Value < count then
		return false
	end
	c.Value -= count
	publishLoad(player, bag)
	return true
end

-- Validate a client's deposit selection without trusting any of it: a table of known goods to
-- whole, non-negative counts no larger than what the player carries. Returns the clean table or
-- the reason it was refused. Any bad entry refuses the whole request.
local function cleanSelection(player: Player, raw: any): ({ [string]: number }?, string?)
	if typeof(raw) ~= "table" then
		return nil, "bad request"
	end
	local held = CargoStore.contents(player)
	local clean = {}
	local count = 0
	for key, value in raw do
		if typeof(key) ~= "string" or not Cargo.carries(key) then
			return nil, "unknown good"
		end
		if typeof(value) ~= "number" or value ~= value or value < 0 or value ~= math.floor(value) then
			return nil, "bad amount"
		end
		if value > held[key] then
			return nil, ("you carry only %d %s"):format(held[key], Cargo.LABEL[key])
		end
		if value > 0 then
			clean[key] = value
			count += 1
		end
	end
	if count == 0 then
		return nil, "nothing selected"
	end
	return clean, nil
end

-- Move goods from the player's bag into their own team's vault. `selection` nil means Deposit
-- all; otherwise it is the client's chosen amounts, validated here. Returns what was credited,
-- or nil and the reason nothing moved. The caller checks the player is at their own vault.
function CargoStore.deposit(player: Player, selection: any?): ({ [string]: number }?, string?)
	local team = player.Team
	local vault = team and CargoStore.vault(team)
	if not vault then
		return nil, "no team vault"
	end
	local chosen: { [string]: number }
	if selection == nil then
		chosen = {}
		for resource, n in CargoStore.contents(player) do
			if n > 0 then
				chosen[resource] = n
			end
		end
		if next(chosen) == nil then
			return nil, "your bag is empty"
		end
	else
		local clean, why = cleanSelection(player, selection)
		if not clean then
			return nil, why
		end
		chosen = clean
	end
	local bag = CargoStore.bag(player)
	for resource, n in chosen do
		counter(bag, resource).Value -= n
		counter(vault, resource).Value += n
	end
	publishLoad(player, bag)
	return chosen, nil
end

-- Move everything out of the bag and hand it to the caller, which must put every unit somewhere
-- (knockdown: into the fallen bag). Returns only goods with a count above zero.
function CargoStore.drain(player: Player): { [string]: number }
	local bag = CargoStore.bag(player)
	local taken = {}
	for _, resource in Cargo.ORDER do
		local c = counter(bag, resource)
		if c.Value > 0 then
			taken[resource] = c.Value
			c.Value = 0
		end
	end
	publishLoad(player, bag)
	return taken
end

-- Empty a bag without crediting anyone: the match reset only. Knockdown goes through drain, into
-- a ransackable fallen bag (DESIGN.md "fallen cargo").
function CargoStore.empty(player: Player)
	local bag = CargoStore.bag(player)
	for _, resource in Cargo.ORDER do
		counter(bag, resource).Value = 0
	end
	publishLoad(player, bag)
end

function CargoStore.emptyAll()
	for _, player in Players:GetPlayers() do
		CargoStore.empty(player)
	end
end

return CargoStore
