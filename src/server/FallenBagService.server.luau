--!strict
-- Medieval Land - the fallen cargo bag (DESIGN.md "fallen cargo" and "bag ransacking").
--
-- KNOCKDOWN: the player's carried materials move exactly once into a bag on the ground where
-- they fell, and their own bag is emptied (CargoStore.drain). Completed gear never enters it.
-- The bag lives 30 seconds from the knockdown, or until it is emptied; respawning creates no
-- second bag and does not restart the timer. Whatever is left at expiry leaves the match.
--
-- RANSACKING: anyone on either team within RANGE may take goods into their own carried bag.
--   * "Take all" (E, 2-second hold on the prompt): offered when everything left fits in the
--     player's free load.
--   * "Choose goods" (E): offered when it does not all fit. Opens FallenBagPanel; the player
--     picks goods and amounts, then stands still for HOLD_TIME while the server times the hold.
-- Moving, taking damage, leaving range, or the bag expiring cancels a hold with no transfer.
-- On completion the server rechecks the bag and the player's free load and moves only what is
-- still there and fits, unit by unit through CargoStore.give, subtracting exactly what it
-- granted. Transfers never yield, so two players finishing at once cannot duplicate goods.
--
-- Which prompt a player sees depends on their own free load, so FallenBagPanel (client) enables
-- one or the other locally; the server re-checks every request regardless.
--
-- The model is the CargoBag template at full size, showing its contents the same way as the
-- carried bag (CargoBagLook). Contents are published as attributes on the model for the client.
--
-- PLACEHOLDERS (DESIGN.md): RANGE 6 studs, HOLD_TIME 2 seconds. Decided: LIFETIME 30 seconds.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameMode = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameMode"))
if not GameMode.TwoTeam then
	return
end
local Cargo = require(ReplicatedStorage.Shared:WaitForChild("Cargo"))
local CargoStore = require(script.Parent:WaitForChild("CargoStore"))
local CargoBagLook = require(script.Parent:WaitForChild("CargoBagLook"))

local template = ServerStorage:WaitForChild("CargoBag") :: Model
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local notifyRemote = remotes:WaitForChild("Notify") :: RemoteEvent
local bagRemote = remotes:WaitForChild("FallenBag") :: RemoteEvent

local LIFETIME = 30 -- seconds from knockdown (decided)
local RANGE = 6 -- studs (placeholder)
local HOLD_TIME = 2 -- seconds (placeholder)
local STILL_TOLERANCE = 0.75 -- studs of drift allowed during a "stationary" hold
local RANGE_SLACK = 1 -- latency allowance on the server's range checks

type Bag = {
	id: string,
	model: Model,
	anchor: BasePart,
	contents: { [string]: number },
	expires: number,
	rest: { [BasePart]: CFrame },
}
local bags: { [string]: Bag } = {}
local nextId = 0

local folder = Workspace:FindFirstChild("FallenBags") or Instance.new("Folder")
folder.Name = "FallenBags"
folder.Parent = Workspace

local function notify(player: Player, text: string)
	notifyRemote:FireClient(player, text)
end

local function total(contents: { [string]: number }): number
	local n = 0
	for _, count in contents do
		n += count
	end
	return n
end

-- ---------------------------------------------------------------- the bag in the world
local function redraw(bag: Bag)
	local look = CargoBagLook.pick(bag.contents)
	local sink = CargoBagLook.sink(bag.model, look)
	for part, rest in bag.rest do
		part.Transparency = if look.show[part.Name] then 0 else 1
		part.CFrame = if CargoBagLook.isGoods(part.Name) then rest * CFrame.new(0, -sink, 0) else rest
	end
	for _, resource in Cargo.ORDER do
		bag.model:SetAttribute(resource, bag.contents[resource] or 0)
	end
	bag.model:SetAttribute("Load", look.load)
end

local function remove(bag: Bag)
	if bags[bag.id] then
		bags[bag.id] = nil
		bag.model:Destroy()
	end
end

local function groundBelow(position: Vector3, ignore: { Instance }): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	local hit = Workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -40, 0), params)
	return if hit then hit.Position else position - Vector3.new(0, 3, 0)
end

local function drop(player: Player, position: Vector3, contents: { [string]: number })
	nextId += 1
	local id = tostring(nextId)
	local model = template:Clone()
	model.Name = "FallenBag_" .. id
	local ignore: { Instance } = { folder }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	local ground = groundBelow(position, ignore)
	-- a random turn so dropped bags don't all face the same way
	model:PivotTo(CFrame.new(ground) * CFrame.Angles(0, math.rad(math.random(0, 359)), 0))

	local rest: { [BasePart]: CFrame } = {}
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			rest[part] = part.CFrame
		end
	end

	-- prompts sit on an invisible part at the middle of the sack
	local anchor = Instance.new("Part")
	anchor.Name = "PromptAnchor"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CFrame = CFrame.new(ground + Vector3.new(0, 1.2, 0))
	anchor.Parent = model
	for _, spec in {
		{ name = "TakeAll", action = "Take all", hold = HOLD_TIME },
		{ name = "ChooseGoods", action = "Choose goods", hold = 0 },
	} do
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = spec.name
		prompt.ObjectText = "Fallen bag"
		prompt.ActionText = spec.action
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
		prompt.HoldDuration = spec.hold
		prompt.MaxActivationDistance = RANGE
		prompt.RequiresLineOfSight = false
		prompt.Parent = anchor
	end

	local bag: Bag = {
		id = id,
		model = model,
		anchor = anchor,
		contents = table.clone(contents),
		expires = Workspace:GetServerTimeNow() + LIFETIME,
		rest = rest,
	}
	model:SetAttribute("BagId", id)
	model:SetAttribute("ExpiresAt", bag.expires)
	model:SetAttribute("OwnerName", player.Name)
	bags[id] = bag
	redraw(bag)
	model.Parent = folder

	task.delay(LIFETIME, function()
		remove(bag) -- anything left leaves the match, crediting nobody
	end)
end

-- ---------------------------------------------------------------- transfers
-- Move up to `wanted` of each good from the bag into the player's carried bag. Never yields.
-- Returns what was granted.
local function transfer(player: Player, bag: Bag, wanted: { [string]: number }): { [string]: number }
	local granted = {}
	for _, resource in Cargo.ORDER do
		local want = math.min(wanted[resource] or 0, bag.contents[resource] or 0)
		if want > 0 then
			local got = CargoStore.give(player, resource, want)
			if got > 0 then
				bag.contents[resource] -= got
				granted[resource] = got
			end
		end
	end
	if total(bag.contents) == 0 then
		remove(bag)
	else
		redraw(bag)
	end
	return granted
end

local function describe(goods: { [string]: number }): string
	local parts = {}
	for _, resource in Cargo.ORDER do
		local n = goods[resource]
		if n and n > 0 then
			table.insert(parts, ("%d %s"):format(n, Cargo.LABEL[resource]))
		end
	end
	return table.concat(parts, ", ")
end

-- Does everything left in the bag fit in this player's free load?
local function allFits(player: Player, bag: Bag): boolean
	return CargoStore.load(player) + Cargo.loadOf(bag.contents) <= Cargo.MAX_LOAD
end

-- ---------------------------------------------------------------- holds
-- One hold per player at a time. A hold is valid while the player stays alive, still, unhurt,
-- in range, and the bag still exists.
type Hold = { bag: Bag, start: Vector3, health: number, token: number }
local holds: { [Player]: Hold } = {}
local holdToken = 0

local function rootOf(player: Player): (BasePart?, Humanoid?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
		return root, humanoid
	end
	return nil, nil
end

local function holdBroken(player: Player, hold: Hold): string?
	local root, humanoid = rootOf(player)
	if not (root and humanoid) then
		return "knocked down"
	end
	if bags[hold.bag.id] ~= hold.bag then
		return "the bag is gone"
	end
	if (root.Position - hold.bag.anchor.Position).Magnitude > RANGE + RANGE_SLACK then
		return "you moved out of reach"
	end
	if (root.Position - hold.start).Magnitude > STILL_TOLERANCE then
		return "you moved"
	end
	if humanoid.Health < hold.health then
		return "you were hit"
	end
	return nil
end

local function beginHold(player: Player, bag: Bag): Hold?
	local root, humanoid = rootOf(player)
	if not (root and humanoid) then
		return nil
	end
	if (root.Position - bag.anchor.Position).Magnitude > RANGE + RANGE_SLACK then
		return nil
	end
	holdToken += 1
	local hold: Hold = { bag = bag, start = root.Position, health = humanoid.Health, token = holdToken }
	holds[player] = hold
	return hold
end

local function endHold(player: Player, hold: Hold)
	if holds[player] == hold then
		holds[player] = nil
	end
end

-- "Take all" uses the prompt's own 2-second hold; the server watches it while it runs.
local function bindTakeAll(prompt: ProximityPrompt, bag: Bag)
	local watching: { [Player]: string? } = {}
	prompt.PromptButtonHoldBegan:Connect(function(player)
		local hold = beginHold(player, bag)
		if not hold then
			return
		end
		watching[player] = nil
		task.spawn(function()
			while holds[player] == hold do
				local why = holdBroken(player, hold)
				if why then
					watching[player] = why
					break
				end
				task.wait(0.1)
			end
		end)
	end)
	prompt.PromptButtonHoldEnded:Connect(function(player)
		-- released early (or Triggered already finished it): either way this hold is over
		task.defer(function()
			local hold = holds[player]
			if hold and hold.bag == bag then
				endHold(player, hold)
			end
		end)
	end)
	prompt.Triggered:Connect(function(player)
		local hold = holds[player]
		if not (hold and hold.bag == bag) then
			return
		end
		local why = watching[player] or holdBroken(player, hold)
		endHold(player, hold)
		watching[player] = nil
		if why then
			notify(player, "Nothing taken: " .. why)
			return
		end
		if not allFits(player, bag) then
			notify(player, "Not enough room for everything - choose goods")
			return
		end
		local granted = transfer(player, bag, table.clone(bag.contents))
		if next(granted) then
			notify(player, "Took " .. describe(granted))
		end
	end)
end

-- "Choose goods": the panel sends ("take", bagId, selection); the server times the hold.
bagRemote.OnServerEvent:Connect(function(player: Player, action: any, bagId: any, selection: any)
	if action == "cancel" then
		local hold = holds[player]
		if hold then
			endHold(player, hold)
		end
		return
	end
	if action ~= "take" or typeof(bagId) ~= "string" or typeof(selection) ~= "table" then
		return
	end
	local bag = bags[bagId]
	if not bag then
		bagRemote:FireClient(player, "end", false, "The bag is gone")
		return
	end
	if holds[player] then
		return -- already holding
	end
	-- clean the selection: known goods, whole positive counts, no more than the bag holds
	local wanted = {}
	for key, value in selection do
		if typeof(key) ~= "string" or not Cargo.carries(key) then
			return
		end
		if typeof(value) ~= "number" or value ~= value or value < 0 or value ~= math.floor(value) then
			return
		end
		if value > 0 then
			wanted[key] = math.min(value, bag.contents[key] or 0)
		end
	end
	if Cargo.loadOf(wanted) == 0 then
		bagRemote:FireClient(player, "end", false, "Nothing selected")
		return
	end
	if Cargo.loadOf(wanted) + CargoStore.load(player) > Cargo.MAX_LOAD then
		bagRemote:FireClient(player, "end", false, "That doesn't fit in your bag")
		return
	end
	local hold = beginHold(player, bag)
	if not hold then
		bagRemote:FireClient(player, "end", false, "Too far from the bag")
		return
	end
	bagRemote:FireClient(player, "hold", HOLD_TIME)
	task.spawn(function()
		local finish = os.clock() + HOLD_TIME
		while os.clock() < finish do
			if holds[player] ~= hold then
				bagRemote:FireClient(player, "end", false, "Cancelled")
				return
			end
			local why = holdBroken(player, hold)
			if why then
				endHold(player, hold)
				bagRemote:FireClient(player, "end", false, "Nothing taken: " .. why)
				return
			end
			task.wait(0.1)
		end
		local why = holdBroken(player, hold)
		endHold(player, hold)
		if why then
			bagRemote:FireClient(player, "end", false, "Nothing taken: " .. why)
			return
		end
		local granted = transfer(player, bag, wanted)
		if next(granted) then
			notify(player, "Took " .. describe(granted))
			bagRemote:FireClient(player, "end", true, "Took " .. describe(granted))
		else
			bagRemote:FireClient(player, "end", false, "Nothing left that fits")
		end
	end)
end)

-- ---------------------------------------------------------------- knockdown and match
local function onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not (humanoid and humanoid:IsA("Humanoid")) then
		return
	end
	humanoid.Died:Connect(function()
		local hold = holds[player]
		if hold then
			endHold(player, hold)
		end
		local root = character:FindFirstChild("HumanoidRootPart")
		local contents = CargoStore.drain(player)
		if total(contents) == 0 then
			return
		end
		local position = if root and root:IsA("BasePart") then root.Position else character:GetPivot().Position
		drop(player, position, contents)
	end)
end

local function setup(player: Player)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
end
for _, player in Players:GetPlayers() do
	setup(player)
end
Players.PlayerAdded:Connect(setup)
Players.PlayerRemoving:Connect(function(player)
	holds[player] = nil
end)

-- prompts are bound once, when a bag appears
folder.ChildAdded:Connect(function(model)
	local id = model:GetAttribute("BagId")
	local bag = if typeof(id) == "string" then bags[id] else nil
	if not bag then
		return
	end
	local prompt = bag.anchor:FindFirstChild("TakeAll")
	if prompt and prompt:IsA("ProximityPrompt") then
		bindTakeAll(prompt, bag)
	end
end)

-- a new match (or the lobby) clears every fallen bag
local lastState = Workspace:GetAttribute("MatchState")
Workspace:GetAttributeChangedSignal("MatchState"):Connect(function()
	local now = Workspace:GetAttribute("MatchState")
	if (now == "Running" and lastState ~= "Running") or now == "Lobby" then
		for _, bag in bags do
			remove(bag)
		end
	end
	lastState = now
end)
