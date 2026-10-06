--!strict
-- Medieval Land - the carried bag worn on each player's back, showing what they carry.
-- User direction 2026-10-06; the model is the bag from assets/fallen-bag (AGENTS.md asset table).
--
-- The template is ServerStorage.CargoBag (built in Studio from fallen_bag.fbx): three sack bodies,
-- a heap per good and a smaller accent per good, all sharing the sack's bottom-centre pivot.
-- This script clones it onto every character and keeps it in step with Player.Cargo:
--   * empty bag      -> hidden
--   * sack body      -> Slack (load 1-8), Half (9-16), Full (17-25)
--   * heap           -> the good with the most load in the bag
--   * accent         -> the good with the second most load, if any
--   * heap height    -> lighter bags sink the heap (and accent) further into the mouth
-- Purely visual: it never changes the bag's contents (CargoStore owns those).
--
-- PLACEHOLDERS: BAG_SCALE and BACK_OFFSET (fit to the default R15 body).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local GameMode = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameMode"))
if not GameMode.TwoTeam then
	return
end
local Cargo = require(ReplicatedStorage.Shared:WaitForChild("Cargo"))

local template = ServerStorage:WaitForChild("CargoBag") :: Model

local BAG_SCALE = 0.75 -- the ground-sized model scaled to sit on a 2-stud torso
-- bag pivot (bottom centre of the sack) relative to the UpperTorso: centred on the back, far enough
-- behind it that the full (deepest) sack does not cut into the body
local BACK_OFFSET = CFrame.new(0, -0.4, 1.35)

-- Goods use Cargo's names; the model's pieces say "Iron" for Smelted Iron.
local PIECE = { Wood = "Wood", Stone = "Stone", Ore = "Ore", Wool = "Wool", SmeltedIron = "Iron" }

type Rig = { model: Model, welds: { [BasePart]: Weld }, rest: { [BasePart]: CFrame } }
local rigs: { [Player]: Rig } = {}

local function sackFor(load: number): string
	if load <= 8 then
		return "SackSlack"
	elseif load <= 16 then
		return "SackHalf"
	end
	return "SackFull"
end

-- Goods in the bag ranked by load (weight x count); ties follow Cargo.ORDER.
local function ranked(bag: Instance): { string }
	local list = {}
	for index, resource in Cargo.ORDER do
		local v = bag:FindFirstChild(resource)
		local count = if v and v:IsA("IntValue") then v.Value else 0
		if count > 0 and PIECE[resource] then
			table.insert(list, { resource = resource, load = count * Cargo.WEIGHT[resource], index = index })
		end
	end
	table.sort(list, function(a, b)
		if a.load ~= b.load then
			return a.load > b.load
		end
		return a.index < b.index
	end)
	local names = {}
	for _, entry in list do
		table.insert(names, entry.resource)
	end
	return names
end

local function refresh(player: Player)
	local rig = rigs[player]
	local bag = player:FindFirstChild("Cargo")
	if not (rig and bag) then
		return
	end
	local contents = {}
	for _, resource in Cargo.ORDER do
		local v = bag:FindFirstChild(resource)
		contents[resource] = if v and v:IsA("IntValue") then v.Value else 0
	end
	local load = Cargo.loadOf(contents)
	local order = ranked(bag)
	local show: { [string]: boolean } = {}
	if load > 0 then
		show[sackFor(load)] = true
		if order[1] then
			show["Heap" .. PIECE[order[1]]] = true
		end
		if order[2] then
			show["Accent" .. PIECE[order[2]]] = true
		end
	end
	-- heap height follows the load: about a third showing when nearly empty, all of it when full
	local fill = math.clamp((load - 1) / (Cargo.MAX_LOAD - 1), 0, 1)
	local shown = 0.35 + 0.65 * fill
	for part, weld in rig.welds do
		part.Transparency = if show[part.Name] then 0 else 1
		local rest = rig.rest[part]
		if part.Name:match("^Heap") or part.Name:match("^Accent") then
			local heap = order[1] and rig.model:FindFirstChild("Heap" .. PIECE[order[1]])
			local height = if heap and heap:IsA("BasePart") then heap.Size.Y else 0
			weld.C0 = rest * CFrame.new(0, -(1 - shown) * height, 0)
		else
			weld.C0 = rest
		end
	end
end

local function attach(player: Player, character: Model)
	local torso = character:WaitForChild("UpperTorso", 10)
	if not (torso and torso:IsA("BasePart")) then
		return -- not an R15 body; nothing to hang the bag on
	end
	local model = template:Clone()
	model:ScaleTo(BAG_SCALE)
	model:PivotTo(torso.CFrame * BACK_OFFSET)
	local rig: Rig = { model = model, welds = {}, rest = {} }
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
			local weld = Instance.new("Weld")
			weld.Part0 = torso
			weld.Part1 = part
			weld.C0 = torso.CFrame:Inverse() * part.CFrame
			weld.Parent = part
			rig.welds[part] = weld
			rig.rest[part] = weld.C0
		end
	end
	model.Name = "CargoBag"
	model.Parent = character
	rigs[player] = rig
	refresh(player)
end

local watched: { [Instance]: boolean } = {}
local function watchBag(player: Player, bag: Instance)
	if watched[bag] then
		return
	end
	watched[bag] = true
	for _, v in bag:GetChildren() do
		if v:IsA("IntValue") then
			v.Changed:Connect(function()
				refresh(player)
			end)
		end
	end
	bag.ChildAdded:Connect(function(v)
		if v:IsA("IntValue") then
			v.Changed:Connect(function()
				refresh(player)
			end)
			refresh(player)
		end
	end)
end

local function setup(player: Player)
	local function onCharacter(character: Model)
		rigs[player] = nil
		attach(player, character)
	end
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
	player.CharacterAdded:Connect(onCharacter)
	local bag = player:FindFirstChild("Cargo")
	if bag then
		watchBag(player, bag)
	end
	player.ChildAdded:Connect(function(child)
		if child.Name == "Cargo" then
			watchBag(player, child)
			refresh(player)
		end
	end)
end

for _, player in Players:GetPlayers() do
	setup(player)
end
Players.PlayerAdded:Connect(setup)
Players.PlayerRemoving:Connect(function(player)
	rigs[player] = nil
end)
