--!strict
-- Medieval Land - the carried bag worn on each player's back, showing what they carry.
-- User direction 2026-10-06; the model is the bag from assets/fallen-bag (AGENTS.md asset table).
--
-- The template is ServerStorage.CargoBag (built in Studio from fallen_bag.fbx): three sack bodies,
-- a heap per good and a smaller accent per good, all sharing the sack's bottom-centre pivot.
-- This script clones it onto every character and keeps it in step with Player.Cargo (the rules
-- live in CargoBagLook, shared with the fallen bag):
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
local CargoBagLook = require(script.Parent:WaitForChild("CargoBagLook"))

local template = ServerStorage:WaitForChild("CargoBag") :: Model

local BAG_SCALE = 0.75 -- the ground-sized model scaled to sit on a 2-stud torso
-- bag pivot (bottom centre of the sack) relative to the UpperTorso: centred on the back, far enough
-- behind it that the full (deepest) sack does not cut into the body
local BACK_OFFSET = CFrame.new(0, -0.4, 1.35)

type Rig = { model: Model, welds: { [BasePart]: Weld }, rest: { [BasePart]: CFrame } }
local rigs: { [Player]: Rig } = {}

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
	local look = CargoBagLook.pick(contents)
	local sink = CargoBagLook.sink(rig.model, look)
	for part, weld in rig.welds do
		part.Transparency = if look.show[part.Name] then 0 else 1
		local rest = rig.rest[part]
		weld.C0 = if CargoBagLook.isGoods(part.Name) then rest * CFrame.new(0, -sink, 0) else rest
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
