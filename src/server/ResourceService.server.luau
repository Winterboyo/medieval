--!strict
-- Medieval Land - Tier 2 resource economy.
-- Lives in ServerScriptService. Server-authoritative on purpose: Tier 4 is a
-- theft system, and a counter the client can write to would be worthless there.
--
-- Tier 0 was: swing at a rock, a number goes up. Tier 1 made the rock run out and
-- come back at a flat rate, and gave the stone somewhere to go. Tier 2 replaces
-- that flat rate with the real curve - see regenRate below. It is the first
-- number in this project that is a design decision rather than a placeholder.
--
-- Mining is a pickaxe swing, not a click. The swing is Roblox's own R15 ToolSlash
-- asset, played from the server so every client sees it (that matters from Tier 3
-- on). Two procedural approaches were tried first and do not work on this place's
-- rig: the characters here use AnimationConstraint joints, not Motor6D, so there
-- is no C0 to drive, and writing the constraint's Attachment0 on the server does
-- not replicate. ToolSlash is half a second long and is played at half speed so
-- the pickaxe lands like a tool with weight behind it rather than a fencing flick.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local STONE_PER_SWING = 1
local MINE_RANGE = 15 -- studs, character root to node
local FACING_DOT = 0.25 -- must be roughly looking at the node, not just near it

local SWING_ANIMATION_ID = "rbxassetid://522635514" -- Roblox R15 ToolSlash
local SWING_TIME = 1.0 -- the asset is stretched to fill this
local IMPACT_AT = 0.5 -- where in the swing the pick actually bites

-- Node regeneration. See regenRate for the shape and why it has a floor.
-- Mining is one stone a second, which is above NODE_REGEN_PEAK on purpose: a
-- node can always be drained faster than it heals. Draining it is just a bad
-- trade.
local NODE_CAPACITY = 24
local NODE_REGEN_PEAK = 0.55 -- stone/second at half full
local NODE_REGEN_FLOOR = 0.06 -- stone/second at empty or full
local REGEN_TICK = 0.25 -- seconds between accumulation steps

-- Roughly 40 seconds of mining a single node buys one wall section, which is
-- slow enough that running between the three outcrops is worth doing.
local WALL_COST = 10
local WALL_SECTIONS_PER_COURSE = 8
local WALL_COURSES = 3
local WALL_SECTION_SIZE = Vector3.new(4, 3, 2.2)

local rng = Random.new()

type Node = {
	model: Model,
	part: BasePart, -- what range and facing are measured against
	amount: number,
	-- Blocks that vanish as the node is worked down, lowest first, so it wears
	-- from the top like something actually being broken up.
	erodible: { BasePart },
	-- Regen is fractional per tick, so it banks here and is spent a whole stone
	-- at a time.
	progress: number,
	fill: Frame,
	label: TextLabel,
}

type State = {
	track: AnimationTrack?,
	swingSpeed: number,
	nextSwing: number,
}

local state: { [Player]: State } = {}
local nodes: { Node } = {}
local nodeByPart: { [BasePart]: Node } = {}

-- ---------------------------------------------------------------- leaderstats
-- "leaderstats" is a magic name, not a class. Roblox looks for a child with
-- exactly this name on a Player and renders its IntValues in the player list.
-- Free HUD, zero GUI work.
local function setupPlayer(player: Player)
	if player:FindFirstChild("leaderstats") then
		return
	end

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local stone = Instance.new("IntValue")
	stone.Name = "Stone"
	stone.Value = 0
	stone.Parent = leaderstats

	leaderstats.Parent = player
end

local function stoneValue(player: Player): IntValue?
	local leaderstats = player:FindFirstChild("leaderstats")
	local stone = leaderstats and leaderstats:FindFirstChild("Stone")
	if stone and stone:IsA("IntValue") then
		return stone
	end
	return nil
end

-- ---------------------------------------------------------------- node readout
local function buildReadout(node: Model, anchor: BasePart): (Frame, TextLabel)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NodeReadout"
	billboard.Adornee = anchor
	billboard.Size = UDim2.fromOffset(104, 30)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, anchor.Size.Y / 2 + 3.4, 0)
	billboard.AlwaysOnTop = false
	billboard.Parent = anchor

	local backing = Instance.new("Frame")
	backing.Size = UDim2.fromScale(1, 1)
	backing.BackgroundColor3 = Color3.fromRGB(24, 24, 26)
	backing.BackgroundTransparency = 0.35
	backing.BorderSizePixel = 0
	backing.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = backing

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -10, 0, 15)
	label.Position = UDim2.fromOffset(5, 2)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 13
	label.TextColor3 = Color3.fromRGB(240, 238, 232)
	label.Text = ""
	label.Parent = backing

	local barTrack = Instance.new("Frame")
	barTrack.Size = UDim2.new(1, -10, 0, 5)
	barTrack.Position = UDim2.new(0, 5, 1, -8)
	barTrack.BackgroundColor3 = Color3.fromRGB(58, 58, 62)
	barTrack.BorderSizePixel = 0
	barTrack.Parent = backing

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = barTrack

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(196, 190, 176)
	fill.BorderSizePixel = 0
	fill.Parent = barTrack

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	return fill, label
end

-- ---------------------------------------------------------------- regen curve
-- Fast at moderate depletion, slow near full and near empty.
--
-- The textbook fit is logistic growth, r*N*(1 - N/K), which peaks at half and
-- falls to zero at both ends. It cannot be used as written: it is exactly zero
-- at empty, so a node worked all the way down would never come back, and a dead
-- node is worse than a flat one. So the curve sits on a floor instead of
-- touching zero - slow at the ends, never stopped.
--
-- 4f(1-f) is 1 at f = 0.5 and 0 at both ends, which maps the rate from the floor
-- up to the peak and back.
--
-- The consequence is the whole point of the tier: at half full a node pays back
-- roughly nine times faster than at empty, so working one down to about half and
-- walking to the next beats standing on one until it dies.
local function regenRate(fraction: number): number
	local clamped = math.clamp(fraction, 0, 1)
	return NODE_REGEN_FLOOR + (NODE_REGEN_PEAK - NODE_REGEN_FLOOR) * 4 * clamped * (1 - clamped)
end

local function refreshNode(node: Node)
	local fraction = node.amount / NODE_CAPACITY

	-- The blocks are sorted lowest first, so showing the first N of them means
	-- the high ones disappear as the node is worked down.
	local visible = math.ceil(fraction * #node.erodible)
	for index, part in node.erodible do
		local shown = index <= visible
		part.Transparency = if shown then 0 else 1
		part.CanCollide = shown
		part.CanQuery = shown
	end

	node.label.Text = ("%d / %d"):format(node.amount, NODE_CAPACITY)
	node.fill.Size = UDim2.fromScale(math.max(fraction, 0), 1)

	-- The bar is tinted by how fast the node is currently healing, not by how
	-- full it is. Otherwise the curve is a hidden number and the player has no
	-- way to learn the thing the tier is about: green where it pays to stop
	-- mining, dull where the node has been worked past the point of being worth
	-- it. Reusing the existing bar rather than adding another readout.
	if node.amount <= 0 then
		node.fill.BackgroundColor3 = Color3.fromRGB(150, 96, 84)
	else
		local vigour = (regenRate(fraction) - NODE_REGEN_FLOOR) / (NODE_REGEN_PEAK - NODE_REGEN_FLOOR)
		node.fill.BackgroundColor3 = Color3.fromRGB(150, 146, 136)
			:Lerp(Color3.fromRGB(126, 208, 122), vigour)
	end

	node.model:SetAttribute("Amount", node.amount)
	node.model:SetAttribute("RegenRate", regenRate(fraction))
end

local function registerNode(model: Instance)
	if not model:IsA("Model") then
		return
	end

	local core = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not core then
		return
	end

	local erodible: { BasePart } = {}
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and child ~= core then
			table.insert(erodible, child)
		end
	end
	table.sort(erodible, function(a, b)
		return a.Position.Y < b.Position.Y
	end)

	local fill, label = buildReadout(model, core)

	local node: Node = {
		model = model,
		part = core,
		amount = NODE_CAPACITY,
		erodible = erodible,
		progress = 0,
		fill = fill,
		label = label,
	}

	table.insert(nodes, node)
	nodeByPart[core] = node
	refreshNode(node)
end

-- Nearest node that is both in range and roughly in front of the player. The
-- facing check is what makes this an aimed swing instead of a proximity button.
-- Depleted nodes are still returned: you should be able to hit a spent rock and
-- see that it gives nothing.
local function findNode(character: Model): Node?
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end

	local best: Node? = nil
	local bestDistance = math.huge

	for _, node in nodes do
		local delta = node.part.Position - root.Position
		local distance = delta.Magnitude
		if distance <= MINE_RANGE and distance < bestDistance then
			local flat = Vector3.new(delta.X, 0, delta.Z)
			if flat.Magnitude > 0.01 and root.CFrame.LookVector:Dot(flat.Unit) >= FACING_DOT then
				best = node
				bestDistance = distance
			end
		end
	end

	return best
end

local CHIP_COLORS = {
	Color3.fromRGB(126, 118, 108),
	Color3.fromRGB(104, 98, 90),
	Color3.fromRGB(146, 138, 126),
}

local function spawnChips(origin: Vector3, away: Vector3, count: number)
	for i = 1, count do
		local size = rng:NextNumber(0.25, 0.6)
		local chip = Instance.new("Part")
		chip.Name = "StoneChip"
		chip.Size = Vector3.new(size, size * rng:NextNumber(0.6, 1.0), size * rng:NextNumber(0.7, 1.1))
		chip.CFrame = CFrame.new(origin) * CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), 0)
		chip.Material = Enum.Material.Rock
		chip.Color = CHIP_COLORS[rng:NextInteger(1, #CHIP_COLORS)]
		chip.CanCollide = false
		chip.CanTouch = false
		chip.Parent = Workspace

		chip.AssemblyLinearVelocity = away * rng:NextNumber(6, 13)
			+ Vector3.new(rng:NextNumber(-6, 6), rng:NextNumber(9, 17), rng:NextNumber(-6, 6))
		chip.AssemblyAngularVelocity = Vector3.new(
			rng:NextNumber(-14, 14),
			rng:NextNumber(-14, 14),
			rng:NextNumber(-14, 14)
		)

		Debris:AddItem(chip, 2.5)
	end
end

-- ---------------------------------------------------------------- regen
-- The tick is short so the curve is sampled often enough to be a curve rather
-- than a staircase, which means it runs far more often than the old flat loop.
-- refreshNode walks every erodible part, so it is only called when a whole stone
-- actually landed.
task.spawn(function()
	while true do
		task.wait(REGEN_TICK)
		for _, node in nodes do
			if node.amount < NODE_CAPACITY then
				node.progress += regenRate(node.amount / NODE_CAPACITY) * REGEN_TICK

				local gained = false
				while node.progress >= 1 and node.amount < NODE_CAPACITY do
					node.progress -= 1
					node.amount += 1
					gained = true
				end

				if node.amount >= NODE_CAPACITY then
					node.progress = 0
				end
				if gained then
					refreshNode(node)
				end
			end
		end
	end
end)

-- ---------------------------------------------------------------- the swing
-- Loaded once per character rather than per swing: LoadAnimation has to fetch
-- the asset the first time, and doing that inside a click would put a stall on
-- the first hit.
local function loadSwingTrack(character: Model): (AnimationTrack?, number)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil, 1
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = SWING_ANIMATION_ID

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()

	if not ok or not track then
		return nil, 1
	end

	-- Action priority so it wins over the idle/walk the default Animate script
	-- keeps playing underneath.
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false

	-- Length is zero until the asset actually arrives.
	local deadline = os.clock() + 5
	while track.Length <= 0 and os.clock() < deadline do
		task.wait(0.05)
	end

	local speed = if track.Length > 0 then track.Length / SWING_TIME else 1
	return track, speed
end

local function attemptSwing(player: Player)
	local playerState = state[player]
	if not playerState then
		return
	end

	local now = os.clock()
	if now < playerState.nextSwing then
		return
	end
	playerState.nextSwing = now + SWING_TIME

	local character = player.Character
	if not character then
		return
	end

	-- The swing always plays, hit or miss. A whiff that looks identical to a
	-- hit is the cheapest way to make the world feel solid.
	-- Speed has to be passed to Play: Play resets it to 1 otherwise.
	local track = playerState.track
	if track then
		track:Play(0.1, 1, playerState.swingSpeed)
	end

	-- Resolved at impact, not at the start of the swing: walk away mid-swing and
	-- you get nothing.
	task.delay(IMPACT_AT, function()
		local liveCharacter = player.Character
		if not liveCharacter or liveCharacter ~= character then
			return
		end

		local humanoid = liveCharacter:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			return
		end

		local node = findNode(liveCharacter)
		if not node then
			return
		end

		local root = liveCharacter:FindFirstChild("HumanoidRootPart")
		local away = Vector3.new(0, 0, 1)
		if root and root:IsA("BasePart") then
			local delta = root.Position - node.part.Position
			delta = Vector3.new(delta.X, 0, delta.Z)
			away = if delta.Magnitude > 0.01 then delta.Unit else away
		end

		local impactPoint = node.part.Position
			+ away * (node.part.Size.Magnitude * 0.25)
			+ Vector3.new(0, rng:NextNumber(-0.5, 1.2), 0)

		if node.amount <= 0 then
			-- Spent. The swing still connects, it just does not pay.
			spawnChips(impactPoint, away, 2)
			return
		end

		node.amount -= STONE_PER_SWING
		refreshNode(node)

		local stone = stoneValue(player)
		if stone then
			stone.Value += STONE_PER_SWING
		end

		spawnChips(impactPoint, away, 7)
	end)
end

-- ---------------------------------------------------------------- wall site
-- Somewhere for the stone to go. One prompt, one growing wall, a fixed cost.
local function registerSite(site: Instance)
	if not site:IsA("Model") then
		return
	end

	local foundation = site.PrimaryPart or site:FindFirstChildWhichIsA("BasePart")
	local prompt = foundation and foundation:FindFirstChildOfClass("ProximityPrompt")
	local sections = site:FindFirstChild("Sections")
	if not foundation or not prompt or not sections then
		return
	end

	local maxSections = WALL_SECTIONS_PER_COURSE * WALL_COURSES
	local built = 0

	local function updatePrompt()
		if built >= maxSections then
			prompt.ActionText = "Wall complete"
			prompt.ObjectText = ("Wall %d/%d"):format(built, maxSections)
			prompt.Enabled = false
		else
			prompt.ActionText = ("Build section (%d Stone)"):format(WALL_COST)
			prompt.ObjectText = ("Wall %d/%d"):format(built, maxSections)
		end
	end
	updatePrompt()

	local function placeSection(index: number)
		local course = index // WALL_SECTIONS_PER_COURSE
		local column = index % WALL_SECTIONS_PER_COURSE

		local offset = CFrame.new(
			(column - (WALL_SECTIONS_PER_COURSE - 1) / 2) * WALL_SECTION_SIZE.X,
			foundation.Size.Y / 2 + course * WALL_SECTION_SIZE.Y + WALL_SECTION_SIZE.Y / 2,
			0
		)
		-- A touch of yaw per block so the courses do not look extruded.
		local final = foundation.CFrame * offset * CFrame.Angles(0, rng:NextNumber(-0.03, 0.03), 0)

		local block = Instance.new("Part")
		block.Name = "Section" .. (index + 1)
		block.Size = WALL_SECTION_SIZE - Vector3.new(0.15, 0.12, 0)
		block.Anchored = true
		block.Material = Enum.Material.Sandstone
		local tone = rng:NextInteger(158, 186)
		block.Color = Color3.fromRGB(tone, tone - 14, tone - 38)
		block.TopSurface = Enum.SurfaceType.Smooth
		block.BottomSurface = Enum.SurfaceType.Smooth
		-- Dropped in rather than blinked in: spending should be visible.
		block.CFrame = final * CFrame.new(0, 7, 0)
		block.Transparency = 1
		block.Parent = sections

		TweenService:Create(
			block,
			TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ CFrame = final, Transparency = 0 }
		):Play()
	end

	prompt.Triggered:Connect(function(player: Player)
		if built >= maxSections then
			return
		end

		local stone = stoneValue(player)
		if not stone or stone.Value < WALL_COST then
			-- No error channel on a prompt, so the prompt itself says it.
			prompt.ActionText = ("Need %d Stone"):format(WALL_COST)
			task.delay(1.5, function()
				if built < maxSections then
					updatePrompt()
				end
			end)
			return
		end

		stone.Value -= WALL_COST
		placeSection(built)
		built += 1
		updatePrompt()
	end)
end

-- ---------------------------------------------------------------- tools
local bound: { [Tool]: boolean } = {}

local function bindTool(player: Player, tool: Tool)
	if tool.Name ~= "Pickaxe" or bound[tool] then
		return
	end
	bound[tool] = true

	-- Tool.Activated fires on the server too - the engine replicates the
	-- activation - so this needs no RemoteEvent. That changes at Tier 3.
	tool.Activated:Connect(function()
		attemptSwing(player)
	end)

	tool.Destroying:Connect(function()
		bound[tool] = nil
	end)
end

local function watchForTools(player: Player, container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("Tool") then
			bindTool(player, child)
		end
	end
	container.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			bindTool(player, child)
		end
	end)
end

local function onCharacterAdded(player: Player, character: Model)
	local playerState = state[player]
	if not playerState then
		return
	end

	playerState.track = nil
	playerState.nextSwing = 0

	-- The rig is not assembled the instant the character appears.
	character:WaitForChild("Humanoid", 10)
	task.wait(0.2)
	playerState.track, playerState.swingSpeed = loadSwingTrack(character)

	watchForTools(player, character) -- equipped
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		watchForTools(player, backpack) -- holstered
	end

	-- Straight into the player's hands. The whole loop is "swing at rock", so
	-- making them press 1 first is a step with nothing behind it.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local pickaxe = backpack and backpack:FindFirstChild("Pickaxe")
	if humanoid and pickaxe and pickaxe:IsA("Tool") then
		humanoid:EquipTool(pickaxe)
	end
end

local function onPlayerAdded(player: Player)
	setupPlayer(player)
	state[player] = { track = nil, swingSpeed = 1, nextSwing = 0 }

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

-- ---------------------------------------------------------------- wiring
local nodeFolder = Workspace:WaitForChild("ResourceNodes")
for _, model in nodeFolder:GetChildren() do
	registerNode(model)
end
nodeFolder.ChildAdded:Connect(registerNode)

local siteFolder = Workspace:WaitForChild("BuildSites")
for _, model in siteFolder:GetChildren() do
	registerSite(model)
end
siteFolder.ChildAdded:Connect(registerSite)

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	state[player] = nil
end)

-- In Studio playtests the script can start after you are already in, so catch
-- anyone who beat it here.
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
