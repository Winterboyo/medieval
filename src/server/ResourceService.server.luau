--!strict
-- Medieval Land - Tier 4 resource economy and raiding.
-- Lives in ServerScriptService. Server-authoritative from the first tier on
-- purpose, which is what makes theft possible to write at all: a counter the
-- client could edit would be worthless the moment stone is worth stealing.
--
-- Tier 4 is a raid in stripped form. One swing does three different things
-- depending on what is in front of you - hit a person, tear a block off their
-- castle, or mine a rock - see attemptSwing for the priority and why.
--
-- Castles are claimed by whoever lays the first block. The starter wall stays
-- unowned: it is the shared sink the loop is learned on, and nobody should be
-- able to fence it off.
--
-- Tier 0 was: swing at a rock, a number goes up. Tier 1 made the rock run out and
-- come back at a flat rate, and gave the stone somewhere to go. Tier 2 replaced
-- that flat rate with the real curve - see regenRate below.
--
-- Tier 3 is two players. Most of it was already done, because everything here
-- has been server-authoritative from Tier 0: node amounts live in one table on
-- the server, characters and leaderstats replicate themselves, and mining goes
-- through Tool.Activated which the engine fires server-side. What was NOT right
-- was feedback - see notifyPlayer. That is what the RemoteEvent is for, and it
-- arrived because a bug demanded it rather than because a checklist did.
--
-- Mining is a pickaxe swing, not a click. The swing is a custom overhead cut
-- authored in the Animation Editor, played from the server so every client sees
-- it (that matters from Tier 3 on). Two procedural approaches were tried first
-- and do not work on this place's rig: the characters here use AnimationConstraint
-- joints, not Motor6D, so there is no C0 to drive, and writing the constraint's
-- Attachment0 on the server does not replicate. See SWING_ANIMATION_ID for how
-- the contact frame was measured rather than guessed.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Declared in default.project.json rather than created here, so the remote is
-- version-controlled instead of appearing at runtime.
local notifyRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Notify")

local YIELD_PER_SWING = 1
local MINE_RANGE = 15 -- studs, character root to node
local FACING_DOT = 0.25 -- must be roughly looking at the node, not just near it

-- Winter's overhead cut, authored in the Animation Editor. Exactly 1.0s long, so
-- it plays at speed 1 and needs no stretching.
local SWING_ANIMATION_ID = "rbxassetid://137439580267496"
local SWING_TIME = 1.0 -- also the cooldown: one swing per second

-- Where the pick actually bites, measured rather than guessed. Freezing the
-- track and scrubbing it, the tip reaches maximum forward reach at t=0.66 and
-- keeps descending at full speed until t=0.71, where it decelerates hard
-- (step 1.01 -> 0.82 -> 0.45). That arrest is the strike; the rest is follow
-- through. Granting at the old 0.5 would have paid out while the pick was still
-- above the player's head.
local IMPACT_AT = 0.70

local REGEN_TICK = 0.25 -- seconds between accumulation steps

-- ---------------------------------------------------------------- resources
-- The five Catan goods. Each one is a kind of node, the tool that harvests it,
-- and its own regen curve - see regenRate for the shape and why it has a floor.
--
-- The numbers are deliberately not uniform, because five resources that all
-- behave identically are one resource with five names:
--   Grain  plentiful and quick, the bulk good
--   Wood   plentiful, slightly slower
--   Stone  the Tier 1 baseline, unchanged
--   Wool   middling, and capped low so a flock runs out fast
--   Ore    scarce and slow to come back, so it is worth travelling for
--
-- Harvesting is one unit a second, which is above every peak on purpose: any
-- node can be drained faster than it heals. Draining it is just a bad trade.
export type ResourceConfig = {
	tool: string,
	capacity: number,
	peak: number, -- units/second at half full
	floor: number, -- units/second at empty or full
	tint: Color3, -- readout bar when the node is regenerating fast
	debris: { Color3 }, -- what flies off when you hit it
}

local RESOURCES: { [string]: ResourceConfig } = {
	Grain = {
		tool = "Hoe",
		capacity = 20,
		peak = 0.70,
		floor = 0.08,
		tint = Color3.fromRGB(226, 194, 92),
		debris = { Color3.fromRGB(222, 190, 96), Color3.fromRGB(198, 164, 78) },
	},
	Wood = {
		tool = "Axe",
		capacity = 20,
		peak = 0.60,
		floor = 0.07,
		tint = Color3.fromRGB(146, 200, 118),
		debris = { Color3.fromRGB(126, 92, 58), Color3.fromRGB(104, 74, 46) },
	},
	Stone = {
		tool = "Pickaxe",
		capacity = 24,
		peak = 0.55,
		floor = 0.06,
		tint = Color3.fromRGB(126, 208, 122),
		debris = { Color3.fromRGB(126, 118, 108), Color3.fromRGB(104, 98, 90) },
	},
	Wool = {
		tool = "Shears",
		capacity = 14,
		peak = 0.45,
		floor = 0.05,
		tint = Color3.fromRGB(232, 228, 220),
		debris = { Color3.fromRGB(244, 242, 236), Color3.fromRGB(220, 216, 208) },
	},
	Ore = {
		tool = "Pickaxe", -- the pickaxe does double duty, as it should
		capacity = 14,
		peak = 0.32,
		floor = 0.04,
		tint = Color3.fromRGB(196, 148, 96),
		debris = { Color3.fromRGB(148, 106, 66), Color3.fromRGB(92, 84, 78) },
	},
}

-- Fixed order, because leaderstats renders columns in creation order and it
-- should not shuffle between joins.
local RESOURCE_ORDER = { "Wood", "Grain", "Wool", "Stone", "Ore" }

-- What one block costs. A bundle rather than a number, so building actually
-- consumes the economy instead of one column of it.
--
-- Grain, Wool and Ore have NO sink yet. They are gathered and they stack up.
-- That is the next design decision, and it most likely hangs off the
-- specialists in the design doc rather than off more masonry.
local BUILD_COST: { [string]: number } = {
	Wood = 4,
	Stone = 4,
}

local function describeCost(): string
	local bits = {}
	for _, name in RESOURCE_ORDER do
		local amount = BUILD_COST[name]
		if amount then
			table.insert(bits, ("%d %s"):format(amount, name))
		end
	end
	return table.concat(bits, " + ")
end

-- The wall is ONE hitpoint value. The ring of blocks is how much of it is
-- standing, drawn from that value - not twenty-odd separate little walls.
local WALL_BLOCK_SIZE = Vector3.new(4.6, 4.5, 2.6)
local WALL_HP_PER_SECTION = 25 -- what one purchase buys, and one block draws

-- Raiding. The same swing that harvests also fights, batters a gate and loots.
local SWING_DAMAGE = 20 -- five swings to put someone down from full health
local GATE_DAMAGE = 25 -- one purchase of wall per swing, so a wall is as slow to
-- break as it was to raise

-- The doc's number: a capped 15-25% of what the owner holds sits in the
-- stockpile and is the only thing a raid can take. The rest is safe, which is
-- what makes a loss sting without being a wipe.
local EXPOSED_FRACTION = 0.20
local LOOT_PER_SWING = 4

-- The keep is the third and last stage of a siege. Shorter than the wall on
-- purpose: by the time an attacker is standing in a breached, emptied base they
-- have already committed, and a long grind there is just tax.
local KEEP_HP = 200

-- Conquest has no lives and no respawn-on-death. Losing a fight is a KNOCKDOWN:
-- you go down and come back at your own keep. Killing cannot be the elimination
-- path or sieges become pointless - you would hunt people instead of ever
-- breaching a wall.
local KNOCKDOWN_SECONDS = 8

-- Tier 5: reputation, minimal. DESIGN.md's negotiation/reputation system is a
-- stretch goal that needs specialists first - this is just the number it
-- would eventually gate, added now so theft has *a* consequence and the
-- number itself can be checked before anything reads it. No UI, no mercenary
-- gating: see reputationOf/adjustReputation.
local REPUTATION_THEFT_PENALTY = -10

local rng = Random.new()

type Node = {
	model: Model,
	part: BasePart, -- what range and facing are measured against
	resource: string,
	config: ResourceConfig,
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
	nextNotice: number,
	offHandIK: IKControl?,
}

local state: { [Player]: State } = {}
local reputation: { [Player]: number } = {}
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

	-- One column per resource, in RESOURCE_ORDER so the player list does not
	-- shuffle its columns between joins.
	for _, name in RESOURCE_ORDER do
		local counter = Instance.new("IntValue")
		counter.Name = name
		counter.Value = 0
		counter.Parent = leaderstats
	end

	leaderstats.Parent = player
end

-- ---------------------------------------------------------------- notices
-- Anything true of one player and not another goes down this channel.
--
-- The rule this enforces: shared world state may live on a shared instance -
-- the wall's "Wall 6/24" is the same fact for everybody, and still sits on the
-- prompt. Per-player facts may not. Writing "Need 10 Stone" onto the prompt's
-- ActionText looked fine with one player and was wrong the moment there were
-- two: it is one property on one instance, so a broke player relabelled the
-- wall for someone standing next to them who could afford it.
local function notifyPlayer(player: Player, text: string, throttleSeconds: number?)
	if throttleSeconds then
		local playerState = state[player]
		if playerState then
			if os.clock() < playerState.nextNotice then
				return
			end
			playerState.nextNotice = os.clock() + throttleSeconds
		end
	end
	notifyRemote:FireClient(player, text)
end

local function counterFor(player: Player, resource: string): IntValue?
	local leaderstats = player:FindFirstChild("leaderstats")
	local counter = leaderstats and leaderstats:FindFirstChild(resource)
	if counter and counter:IsA("IntValue") then
		return counter
	end
	return nil
end

-- Can this player pay a bundle? Returns false and the first thing they are short
-- of, so the refusal can say which resource is missing rather than just "no".
local function canAfford(player: Player, cost: { [string]: number }): (boolean, string?)
	for _, name in RESOURCE_ORDER do
		local needed = cost[name]
		if needed then
			local counter = counterFor(player, name)
			if not counter or counter.Value < needed then
				return false, name
			end
		end
	end
	return true, nil
end

local function spend(player: Player, cost: { [string]: number })
	for name, amount in cost do
		local counter = counterFor(player, name)
		if counter then
			counter.Value -= amount
		end
	end
end

-- ---------------------------------------------------------------- reputation
local function reputationOf(player: Player): number
	return reputation[player] or 0
end

local function adjustReputation(player: Player, delta: number, reason: string)
	local updated = reputationOf(player) + delta
	reputation[player] = updated
	player:SetAttribute("Reputation", updated)
	print(("[Reputation] %s %s%d (%s) -> %d"):format(
		player.Name, if delta >= 0 then "+" else "", delta, reason, updated))
end

-- ---------------------------------------------------------------- node readout
local function buildReadout(node: Model, anchor: BasePart): (Frame, TextLabel)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NodeReadout"
	billboard.Adornee = anchor
	billboard.Size = UDim2.fromOffset(104, 30)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, anchor.Size.Y / 2 + 3.4, 0)
	billboard.AlwaysOnTop = false
	-- Without this every readout on the board draws at once and the view from
	-- any height is a wall of overlapping labels. You only need to read a node
	-- you could actually walk to.
	billboard.MaxDistance = 110
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
-- The shape is shared by every resource; only the two endpoints differ, so each
-- one gets its own pace without getting its own maths.
local function regenRate(config: ResourceConfig, fraction: number): number
	local clamped = math.clamp(fraction, 0, 1)
	return config.floor + (config.peak - config.floor) * 4 * clamped * (1 - clamped)
end

local function refreshNode(node: Node)
	local config = node.config
	local fraction = node.amount / config.capacity

	-- The blocks are sorted lowest first, so showing the first N of them means
	-- the high ones disappear as the node is worked down.
	local visible = math.ceil(fraction * #node.erodible)
	for index, part in node.erodible do
		local shown = index <= visible
		part.Transparency = if shown then 0 else 1
		part.CanCollide = shown
		part.CanQuery = shown
	end

	node.label.Text = ("%s  %d / %d"):format(node.resource, node.amount, config.capacity)
	node.fill.Size = UDim2.fromScale(math.max(fraction, 0), 1)

	-- The bar is tinted by how fast the node is currently healing, not by how
	-- full it is. Otherwise the curve is a hidden number and the player has no
	-- way to learn the thing the tier is about: green where it pays to stop
	-- mining, dull where the node has been worked past the point of being worth
	-- it. Reusing the existing bar rather than adding another readout.
	if node.amount <= 0 then
		node.fill.BackgroundColor3 = Color3.fromRGB(150, 96, 84)
	else
		local rate = regenRate(config, fraction)
		local vigour = (rate - config.floor) / (config.peak - config.floor)
		node.fill.BackgroundColor3 = Color3.fromRGB(150, 146, 136):Lerp(config.tint, vigour)
	end

	node.model:SetAttribute("Amount", node.amount)
	node.model:SetAttribute("RegenRate", regenRate(config, fraction))
end

local function registerNode(model: Instance)
	if not model:IsA("Model") then
		return
	end

	local core = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not core then
		return
	end

	-- The world builder tags each node with what it yields; the service owns
	-- what that means. An untagged node is Stone, which is what every node was
	-- before there were five of them.
	local resource = model:GetAttribute("Resource")
	if typeof(resource) ~= "string" or not RESOURCES[resource] then
		resource = "Stone"
	end
	local config = RESOURCES[resource]

	-- Anything the builder marked as wearable disappears as the node is worked
	-- down: canopies off a tree, stalks off a field, fleece off a sheep. Parts
	-- without the tag are the permanent frame - trunks, legs, bare earth - so a
	-- spent node still looks like the thing it is.
	local erodible: { BasePart } = {}
	for _, child in model:GetDescendants() do
		if child:IsA("BasePart") and child ~= core and child:GetAttribute("Wears") == true then
			table.insert(erodible, child)
		end
	end
	-- Fall back to the old behaviour for nodes that tag nothing.
	if #erodible == 0 then
		for _, child in model:GetChildren() do
			if child:IsA("BasePart") and child ~= core then
				table.insert(erodible, child)
			end
		end
	end
	table.sort(erodible, function(a, b)
		return a.Position.Y < b.Position.Y
	end)

	local fill, label = buildReadout(model, core)

	local node: Node = {
		model = model,
		part = core,
		resource = resource,
		config = config,
		amount = config.capacity,
		erodible = erodible,
		progress = 0,
		fill = fill,
		label = label,
	}

	table.insert(nodes, node)
	nodeByPart[core] = node
	refreshNode(node)
end

-- In range AND roughly in front. The facing half is what makes a swing aimed
-- rather than a proximity button, and every target type shares it.
local function isAimedAt(root: BasePart, position: Vector3, range: number): (boolean, number)
	local delta = position - root.Position
	local distance = delta.Magnitude
	if distance > range then
		return false, distance
	end
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude <= 0.01 then
		return false, distance
	end
	return root.CFrame.LookVector:Dot(flat.Unit) >= FACING_DOT, distance
end

-- MatchService publishes the playable boundary. Absent before a match starts,
-- which reads as no boundary rather than a boundary of zero - a service that has
-- not spoken yet must not shut the whole map down.
local function zoneHalf(): number
	local value = Workspace:GetAttribute("ZoneHalf")
	return if typeof(value) == "number" then value else math.huge
end

-- The zone is a square centred on the origin, so "outside" is the larger of the
-- two axis distances rather than a radius.
local function inZone(position: Vector3): boolean
	return math.max(math.abs(position.X), math.abs(position.Z)) <= zoneHalf()
end

-- A node is a cluster - five trees, a flock, a 32 stud field - so aiming at the
-- model's anchor makes the far side of a tile unhittable. Aim at whichever piece
-- of it is actually nearest.
local function closestPoint(node: Node, from: Vector3): Vector3
	local bestPart = node.part
	local bestDistance = (node.part.Position - from).Magnitude
	for _, part in node.erodible do
		local distance = (part.Position - from).Magnitude
		if distance < bestDistance then
			bestPart, bestDistance = part, distance
		end
	end
	return bestPart.Position
end

-- Nearest aimed-at node THIS TOOL CAN WORK. Swinging an axe at a rock should
-- find nothing rather than find the rock and refuse it - otherwise standing
-- between a tree and a boulder with the wrong tool would silently target the
-- boulder and look broken.
--
-- Depleted nodes are still returned: you should be able to hit a spent field and
-- see that it gives nothing.
local function findNode(character: Model, toolName: string): (Node?, Vector3?)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil, nil
	end

	local best: Node? = nil
	local bestPoint: Vector3? = nil
	local bestDistance = math.huge

	for _, node in nodes do
		-- Outside the closing boundary a node yields nothing. That is the
		-- scarcity half of what the doc wants convergence to do: the map does not
		-- just get smaller, the economy inside it gets tighter.
		if node.config.tool == toolName and inZone(node.part.Position) then
			local point = closestPoint(node, root.Position)
			local aimed, distance = isAimedAt(root, point, MINE_RANGE)
			if aimed and distance < bestDistance then
				best, bestPoint, bestDistance = node, point, distance
			end
		end
	end

	return best, bestPoint
end

-- Anything harvestable in front of you, whatever the tool. Used only to tell a
-- player they brought the wrong one.
local function findAnyNode(character: Model): Node?
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end

	local best: Node? = nil
	local bestDistance = math.huge
	for _, node in nodes do
		local point = closestPoint(node, root.Position)
		local aimed, distance = isAimedAt(root, point, MINE_RANGE)
		if aimed and distance < bestDistance then
			best = node
			bestDistance = distance
		end
	end
	return best
end

-- Nearest other player you are aimed at and who is still alive.
local function findVictim(attacker: Player, character: Model): (Player?, Humanoid?)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil, nil
	end

	local bestPlayer: Player? = nil
	local bestHumanoid: Humanoid? = nil
	local bestDistance = math.huge

	for _, other in Players:GetPlayers() do
		if other ~= attacker then
			local otherCharacter = other.Character
			local otherRoot = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
			local otherHumanoid = otherCharacter and otherCharacter:FindFirstChildOfClass("Humanoid")
			if otherRoot and otherRoot:IsA("BasePart") and otherHumanoid and otherHumanoid.Health > 0 then
				local aimed, distance = isAimedAt(root, otherRoot.Position, MINE_RANGE)
				if aimed and distance < bestDistance then
					bestPlayer = other
					bestHumanoid = otherHumanoid
					bestDistance = distance
				end
			end
		end
	end

	return bestPlayer, bestHumanoid
end

-- Debris takes the colour of whatever was hit, so chopping throws splinters and
-- shearing throws fleece rather than everything throwing grey rock.
local function spawnChips(origin: Vector3, away: Vector3, count: number, palette: { Color3 }?)
	local colours = palette or { Color3.fromRGB(126, 118, 108), Color3.fromRGB(104, 98, 90) }
	for i = 1, count do
		local size = rng:NextNumber(0.25, 0.6)
		local chip = Instance.new("Part")
		chip.Name = "StoneChip"
		chip.Size = Vector3.new(size, size * rng:NextNumber(0.6, 1.0), size * rng:NextNumber(0.7, 1.1))
		chip.CFrame = CFrame.new(origin) * CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), 0)
		chip.Material = Enum.Material.Rock
		chip.Color = colours[rng:NextInteger(1, #colours)]
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
			local capacity = node.config.capacity
			if node.amount < capacity then
				node.progress += regenRate(node.config, node.amount / capacity) * REGEN_TICK

				local gained = false
				while node.progress >= 1 and node.amount < capacity do
					node.progress -= 1
					node.amount += 1
					gained = true
				end

				if node.amount >= capacity then
					node.progress = 0
				end
				if gained then
					refreshNode(node)
				end
			end
		end
	end
end)

-- ---------------------------------------------------------------- bases
-- DESIGN.md v1: a perimeter wall on a SINGLE HP value, one gate, and a stockpile
-- holding a capped exposed slice of the owner's goods. The rest of what they own
-- is safe. That is what makes a loss sting without being a wipe.
--
-- The ring of blocks is NOT twenty-odd little hitpoints. It is a readout: how
-- many stand is drawn from the one wall value. Building raises that value and
-- raises blocks to match; damage lowers it and drops blocks to match.
type Base = {
	model: Model,
	foundation: BasePart,
	gate: BasePart,
	stockpile: BasePart,
	prompt: ProximityPrompt,
	sections: Instance,
	slots: { Attachment },
	wall: number, -- the single HP value
	wallMax: number,
	breached: boolean,
	keep: BasePart,
	keepHealth: number,
	-- Snapshot of what can be taken, taken at the moment of the breach. Without
	-- the snapshot, "20% of what they hold" recomputed per swing converges on
	-- taking everything, which is the wipe the doc is trying to avoid.
	loot: { [string]: number },
	refresh: () -> (),
}

local bases: { Base } = {}

local function baseOwner(base: Base): number?
	local owner = base.model:GetAttribute("Owner")
	return if typeof(owner) == "number" then owner else nil
end

-- How many blocks should be standing for the current wall value.
local function standingSections(base: Base): number
	if base.wallMax <= 0 then
		return 0
	end
	return math.ceil((base.wall / base.wallMax) * #base.slots)
end

local function redrawWall(base: Base)
	local wanted = standingSections(base)
	for index, slot in base.slots do
		local existing = base.sections:FindFirstChild(slot.Name)
		if index <= wanted and not existing then
			local block = Instance.new("Part")
			block.Name = slot.Name
			block.Size = WALL_BLOCK_SIZE
			block.CFrame = slot.WorldCFrame
			block.Anchored = true
			block.Material = Enum.Material.Sandstone
			local tone = rng:NextInteger(158, 186)
			block.Color = Color3.fromRGB(tone, tone - 14, tone - 38)
			block.TopSurface = Enum.SurfaceType.Smooth
			block.BottomSurface = Enum.SurfaceType.Smooth
			-- Dropped in rather than blinked in: spending should be visible.
			block.CFrame = slot.WorldCFrame * CFrame.new(0, 7, 0)
			block.Transparency = 1
			block.Parent = base.sections
			TweenService:Create(
				block,
				TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ CFrame = slot.WorldCFrame, Transparency = 0 }
			):Play()
		elseif index > wanted and existing and existing:IsA("BasePart") then
			existing.Name = "Rubble"
			existing.Anchored = false
			existing.CanCollide = false
			existing.AssemblyLinearVelocity = Vector3.new(
				rng:NextNumber(-10, 10),
				rng:NextNumber(6, 13),
				rng:NextNumber(-10, 10)
			)
			Debris:AddItem(existing, 2.5)
		end
	end
end

local function registerBase(model: Instance)
	if not model:IsA("Model") or model:GetAttribute("Kind") ~= "Base" then
		return
	end

	local foundation = model.PrimaryPart or model:FindFirstChild("Foundation")
	local gate = model:FindFirstChild("Gate")
	local stockpile = model:FindFirstChild("Stockpile")
	local keep = model:FindFirstChild("Keep")
	local sections = model:FindFirstChild("Sections")
	local prompt = foundation and foundation:FindFirstChildOfClass("ProximityPrompt")
	if not (foundation and foundation:IsA("BasePart") and gate and gate:IsA("BasePart")
		and stockpile and stockpile:IsA("BasePart") and keep and keep:IsA("BasePart")
		and sections and prompt) then
		return
	end

	local slots: { Attachment } = {}
	for _, child in foundation:GetChildren() do
		if child:IsA("Attachment") and child.Name:match("^Slot%d+$") then
			table.insert(slots, child)
		end
	end
	table.sort(slots, function(a, b)
		return a.Name < b.Name
	end)

	local base: Base = {
		model = model,
		foundation = foundation,
		gate = gate,
		stockpile = stockpile,
		prompt = prompt,
		sections = sections,
		slots = slots,
		wall = 0,
		wallMax = #slots * WALL_HP_PER_SECTION,
		breached = true, -- an unbuilt base has nothing keeping anyone out
		keep = keep,
		keepHealth = KEEP_HP,
		loot = {},
		refresh = function() end,
	}

	base.refresh = function()
		local ownerName = model:GetAttribute("OwnerName")
		local who = if typeof(ownerName) == "string" then ownerName .. "'s base" else "Unclaimed base"
		base.prompt.ObjectText = ("%s  wall %d/%d"):format(who, math.floor(base.wall), base.wallMax)

		if base.wall >= base.wallMax then
			base.prompt.ActionText = "Wall complete"
			base.prompt.Enabled = false
		else
			-- Re-enabled deliberately: a breach has to make the wall repairable.
			base.prompt.Enabled = true
			base.prompt.ActionText = ("%s (%s)"):format(
				if base.wall > 0 then "Repair" else "Build wall", describeCost())
		end

		model:SetAttribute("Wall", math.floor(base.wall))
		model:SetAttribute("Breached", base.breached)
		model:SetAttribute("KeepHealth", math.floor(base.keepHealth))
		model:SetAttribute("Fallen", base.keepHealth <= 0)
		-- The keep darkens and finally slumps as it is broken up, so its state
		-- reads from outside without a health bar - the same trick as the gate.
		local keepLeft = base.keepHealth / KEEP_HP
		base.keep.Color = Color3.fromRGB(58, 50, 46):Lerp(Color3.fromRGB(128, 118, 108), keepLeft)
		base.keep.Transparency = if base.keepHealth <= 0 then 0.55 else 0
		-- The gate darkens as the wall fails, so an attacker can read how close
		-- a base is to falling without a health bar.
		local fraction = if base.wallMax > 0 then base.wall / base.wallMax else 0
		base.gate.Color = Color3.fromRGB(58, 40, 26):Lerp(Color3.fromRGB(104, 72, 44), fraction)
	end
	base.refresh()

	base.prompt.Triggered:Connect(function(player: Player)
		if base.wall >= base.wallMax then
			return
		end

		local owner = baseOwner(base)
		if owner and owner ~= player.UserId then
			notifyPlayer(player, ("%s's base - raid it, do not build it"):format(
				tostring(model:GetAttribute("OwnerName") or "Someone")))
			return
		end

		local affordable, missing = canAfford(player, BUILD_COST)
		if not affordable then
			-- Straight to the one player who cannot afford it, naming what they
			-- are short of. This used to write the prompt's ActionText, which
			-- every player at the base shares - see notifyPlayer.
			notifyPlayer(player, ("Need %d %s"):format(BUILD_COST[missing :: string], tostring(missing)))
			return
		end

		spend(player, BUILD_COST)
		base.wall = math.min(base.wallMax, base.wall + WALL_HP_PER_SECTION)
		if base.wall > 0 then
			base.breached = false
		end

		-- Raising the first stretch of wall claims the plot.
		if not owner then
			model:SetAttribute("Owner", player.UserId)
			model:SetAttribute("OwnerName", player.Name)
		end

		redrawWall(base)
		base.refresh()
	end)

	table.insert(bases, base)
end

-- Take the snapshot. Only ever called on the swing that drops the wall to zero.
local function openStockpile(base: Base)
	local ownerId = baseOwner(base)
	local owner = ownerId and Players:GetPlayerByUserId(ownerId)
	base.loot = {}
	if not owner then
		return
	end
	for _, name in RESOURCE_ORDER do
		local held = counterFor(owner, name)
		base.loot[name] = if held then math.floor(held.Value * EXPOSED_FRACTION) else 0
	end
end

local function lootRemaining(base: Base): number
	local total = 0
	for _, amount in base.loot do
		total += amount
	end
	return total
end

-- Nearest enemy GATE you are aimed at on a base that still has a wall. The gate
-- is the only place the wall can be hurt: that is the whole point of there being
-- one, per the doc - a single chokepoint you have to commit to.
local function findGateTarget(raider: Player, character: Model): Base?
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local best: Base? = nil
	local bestDistance = math.huge
	for _, base in bases do
		local owner = baseOwner(base)
		if owner and owner ~= raider.UserId and base.wall > 0 then
			local aimed, distance = isAimedAt(root, base.gate.Position, MINE_RANGE)
			if aimed and distance < bestDistance then
				best = base
				bestDistance = distance
			end
		end
	end
	return best
end

-- Nearest enemy KEEP you are aimed at, and only on a base that has already lost
-- its wall AND had its stockpile emptied. That ordering is the whole design:
-- elimination is a completed siege, never a lucky hit on the way past.
local function findKeepTarget(raider: Player, character: Model): Base?
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local best: Base? = nil
	local bestDistance = math.huge
	for _, base in bases do
		local owner = baseOwner(base)
		if owner and owner ~= raider.UserId
			and base.breached
			and lootRemaining(base) <= 0
			and base.keepHealth > 0
		then
			local aimed, distance = isAimedAt(root, base.keep.Position, MINE_RANGE)
			if aimed and distance < bestDistance then
				best = base
				bestDistance = distance
			end
		end
	end
	return best
end

-- Nearest enemy STOCKPILE you are aimed at on a base whose wall has fallen.
local function findStockpileTarget(raider: Player, character: Model): Base?
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local best: Base? = nil
	local bestDistance = math.huge
	for _, base in bases do
		local owner = baseOwner(base)
		if owner and owner ~= raider.UserId and base.breached then
			local aimed, distance = isAimedAt(root, base.stockpile.Position, MINE_RANGE)
			if aimed and distance < bestDistance then
				best = base
				bestDistance = distance
			end
		end
	end
	return best
end

-- ---------------------------------------------------------------- off hand
-- The swing animation only poses the arm holding the tool. To make it look
-- two-handed, an IKControl drags the left hand onto a second grip point on the
-- shaft, and keeps it there for the whole arc - so the off hand follows the
-- swing without the animation having to know about it.
--
-- ChainRoot is UpperTorso, not LeftUpperArm. Reaching a tool held out on the
-- right side means crossing the body, and an arm-only chain simply cannot get
-- there: measured 1.78 studs short with LeftUpperArm against 1.32 with the
-- torso in the chain. LowerTorso is worse again (3.36) - it bends the whole
-- body and still misses.
--
-- 1.32 studs is close, not exact. This is a good approximation, not a real
-- grip; the exact version is to pose the left arm in the animation itself,
-- where the hand can be put on the shaft by eye.
local OFF_HAND_IK = "OffHandIK"
local OFF_HAND_RAMP = 0.12 -- seconds to bring the second hand on and off the shaft

local function buildOffHandIK(character: Model): IKControl?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local leftHand = character:FindFirstChild("LeftHand")
	local chainRoot = character:FindFirstChild("UpperTorso")
	-- R6 has none of these. No off hand, no crash.
	if not (humanoid and leftHand and chainRoot) then
		return nil
	end

	local existing = humanoid:FindFirstChild(OFF_HAND_IK)
	if existing then
		existing:Destroy()
	end

	local ik = Instance.new("IKControl")
	ik.Name = OFF_HAND_IK
	ik.Type = Enum.IKControlType.Position
	ik.ChainRoot = chainRoot
	ik.EndEffector = leftHand
	ik.Weight = 1
	ik.SmoothTime = 0.06
	ik.Enabled = false -- nothing to hold onto until a tool is equipped
	ik.Parent = humanoid
	return ik
end

-- Called on equip and unequip. This only ARMS the off hand - it points the IK at
-- the shaft and leaves it switched off. Holding the tool is a one-handed pose.
local function setOffHandTarget(player: Player, tool: Tool?)
	local playerState = state[player]
	local ik = playerState and playerState.offHandIK
	if not ik or not ik.Parent then
		return
	end

	local handle = tool and tool:FindFirstChild("Handle")
	local grip = handle and handle:FindFirstChild("LeftGrip")
	ik.Target = if grip and grip:IsA("Attachment") then grip else nil
	ik.Weight = 0
	ik.Enabled = false
end

-- The off hand comes up for the swing and drops again afterwards.
--
-- Leaving it engaged the whole time the tool was equipped was a mistake: it
-- dragged the left arm across the body permanently and fought the idle and walk
-- animations, which read as constant glitching. Standing still holding a pickaxe
-- is a one-handed pose; you only bring the second hand up to swing it.
--
-- Weight is ramped rather than switched so the arm arrives and leaves smoothly
-- instead of snapping.
local function engageOffHand(player: Player, engaged: boolean)
	local playerState = state[player]
	local ik = playerState and playerState.offHandIK
	if not ik or not ik.Parent or not ik.Target then
		return
	end

	if engaged then
		ik.Enabled = true
		TweenService:Create(ik, TweenInfo.new(OFF_HAND_RAMP), { Weight = 1 }):Play()
		return
	end

	local release = TweenService:Create(ik, TweenInfo.new(OFF_HAND_RAMP), { Weight = 0 })
	release.Completed:Connect(function()
		-- Only actually switch off if nothing re-engaged it in the meantime.
		if ik.Parent and ik.Weight <= 0.01 then
			ik.Enabled = false
		end
	end)
	release:Play()
end

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

local function attemptSwing(player: Player, toolName: string)
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

	-- Second hand on for the duration of the swing only.
	engageOffHand(player, true)
	task.delay(SWING_TIME, function()
		engageOffHand(player, false)
	end)

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

		local root = liveCharacter:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			return
		end

		-- One swing, three possible things to hit. Order matters: a person in
		-- front of you takes precedence over their wall, and both take
		-- precedence over the rock you happen to be standing next to. Otherwise
		-- you could not fight beside a node.

		-- 1. someone standing in front of you
		local victim, victimHumanoid = findVictim(player, liveCharacter)
		if victim and victimHumanoid then
			victimHumanoid:TakeDamage(SWING_DAMAGE)
			local killed = victimHumanoid.Health <= 0
			notifyPlayer(player, if killed
				then ("You killed %s"):format(victim.Name)
				else ("Hit %s"):format(victim.Name))
			notifyPlayer(victim, if killed
				then ("%s killed you"):format(player.Name)
				else ("%s is attacking you"):format(player.Name), 2)
			return
		end

		-- 2. an enemy gate. The wall can only be hurt here, so a raid is a
		-- commitment to one approach rather than chipping at whichever face
		-- happens to be nearest.
		local gateTarget = findGateTarget(player, liveCharacter)
		if gateTarget then
			local ownerName = tostring(gateTarget.model:GetAttribute("OwnerName") or "someone")
			gateTarget.wall = math.max(0, gateTarget.wall - GATE_DAMAGE)

			local justBreached = gateTarget.wall <= 0 and not gateTarget.breached
			if justBreached then
				gateTarget.breached = true
				openStockpile(gateTarget)
			end

			redrawWall(gateTarget)
			gateTarget.refresh()

			local ownerId = baseOwner(gateTarget)
			local owner = ownerId and Players:GetPlayerByUserId(ownerId)
			if justBreached then
				notifyPlayer(player, ("%s's wall is down - the stockpile is open"):format(ownerName))
				if owner then
					notifyPlayer(owner, ("%s has breached your wall"):format(player.Name))
				end
			else
				notifyPlayer(player, ("Battering %s's gate"):format(ownerName), 2)
				if owner then
					notifyPlayer(owner, ("%s is at your gate"):format(player.Name), 3)
				end
			end

			local away = (root.Position - gateTarget.gate.Position)
			away = Vector3.new(away.X, 0, away.Z)
			away = if away.Magnitude > 0.01 then away.Unit else Vector3.new(0, 0, 1)
			spawnChips(gateTarget.gate.Position, away, 5, { Color3.fromRGB(120, 84, 52), Color3.fromRGB(92, 64, 40) })
			return
		end

		-- 3. an open stockpile. Only the exposed slice snapshotted at the breach
		-- can be taken; everything else the owner holds is safe.
		local lootTarget = findStockpileTarget(player, liveCharacter)
		if lootTarget then
			local ownerId = baseOwner(lootTarget)
			local owner = ownerId and Players:GetPlayerByUserId(ownerId)
			local ownerName = tostring(lootTarget.model:GetAttribute("OwnerName") or "someone")

			-- Take from whichever resource has the most left, so a raid empties
			-- the pot evenly rather than draining one column first.
			local pick, most = nil, 0
			for _, name in RESOURCE_ORDER do
				local left = lootTarget.loot[name] or 0
				if left > most then
					pick, most = name, left
				end
			end

			if not pick then
				notifyPlayer(player, ("%s's stockpile is empty"):format(ownerName), 3)
				return
			end

			local taken = math.min(LOOT_PER_SWING, most)
			lootTarget.loot[pick] = most - taken

			if owner then
				local held = counterFor(owner, pick)
				if held then
					held.Value = math.max(0, held.Value - taken)
				end
				notifyPlayer(owner, ("%s is looting your stockpile"):format(player.Name), 3)
			end
			local mine = counterFor(player, pick)
			if mine then
				mine.Value += taken
			end

			-- Tier 5: the one thing the number does so far. Per swing that
			-- actually takes something, not per raid - each is its own theft
			-- event, and stretching one raid over several swings should cost
			-- more than a single grab.
			adjustReputation(player, REPUTATION_THEFT_PENALTY, ("looted %s from %s"):format(pick, ownerName))

			notifyPlayer(player, ("Looted %d %s from %s"):format(taken, pick, ownerName))
			lootTarget.model:SetAttribute("LootLeft", lootRemaining(lootTarget))

			local away = (root.Position - lootTarget.stockpile.Position)
			away = Vector3.new(away.X, 0, away.Z)
			away = if away.Magnitude > 0.01 then away.Unit else Vector3.new(0, 0, 1)
			spawnChips(lootTarget.stockpile.Position + Vector3.new(0, 2, 0), away, 5)
			return
		end

		-- 4. an enemy keep, once the wall is down and the stockpile is spent
		local keepTarget = findKeepTarget(player, liveCharacter)
		if keepTarget then
			local ownerName = tostring(keepTarget.model:GetAttribute("OwnerName") or "someone")
			keepTarget.keepHealth = math.max(0, keepTarget.keepHealth - GATE_DAMAGE)
			keepTarget.refresh()

			local ownerId = baseOwner(keepTarget)
			local owner = ownerId and Players:GetPlayerByUserId(ownerId)

			if keepTarget.keepHealth <= 0 then
				-- Stage 3 turns this into elimination. For now the keep simply
				-- falls, and says so.
				notifyPlayer(player, ("%s's keep has fallen"):format(ownerName))
				if owner then
					notifyPlayer(owner, ("%s has razed your keep"):format(player.Name))
				end
			else
				notifyPlayer(player, ("Breaking %s's keep"):format(ownerName), 2)
				if owner then
					notifyPlayer(owner, ("%s is inside your walls"):format(player.Name), 3)
				end
			end

			local away = (root.Position - keepTarget.keep.Position)
			away = Vector3.new(away.X, 0, away.Z)
			away = if away.Magnitude > 0.01 then away.Unit else Vector3.new(0, 0, 1)
			spawnChips(keepTarget.keep.Position + Vector3.new(0, 3, 0), away, 6)
			return
		end

		-- 5. something to harvest, if this tool can harvest it
		local node, hitPoint = findNode(liveCharacter, toolName)
		if not node or not hitPoint then
			-- Aimed at something harvestable but holding the wrong thing. Worth
			-- saying, because a swing that connects and pays nothing otherwise
			-- looks like a bug.
			local wrong = findAnyNode(liveCharacter)
			if wrong then
				-- Two different failures that look identical from the outside, so
				-- they get different words: wrong tool, or right tool on ground
				-- the zone has already abandoned.
				if not inZone(wrong.part.Position) then
					notifyPlayer(player, "Outside the zone - nothing here yields", 3)
				else
					notifyPlayer(player, ("%s needs a %s"):format(wrong.resource, wrong.config.tool), 3)
				end
			end
			return
		end

		local away = (root.Position - hitPoint)
		away = Vector3.new(away.X, 0, away.Z)
		away = if away.Magnitude > 0.01 then away.Unit else Vector3.new(0, 0, 1)

		-- Chips fly from whichever tree/sheep/stalk/rock was actually hit, not
		-- always the tile's anchor.
		local impactPoint = hitPoint + away * 1.2 + Vector3.new(0, rng:NextNumber(-0.5, 1.2), 0)

		if node.amount <= 0 then
			-- Spent. The swing still connects, it just does not pay. Throttled:
			-- you can swing at a dead node once a second and do not need telling
			-- once a second.
			spawnChips(impactPoint, away, 2, node.config.debris)
			notifyPlayer(player, ("This %s is spent"):format(node.resource:lower()), 4)
			return
		end

		node.amount -= YIELD_PER_SWING
		refreshNode(node)

		local counter = counterFor(player, node.resource)
		if counter then
			counter.Value += YIELD_PER_SWING
		end

		spawnChips(impactPoint, away, 7, node.config.debris)
	end)
end

-- ---------------------------------------------------------------- knockdown
-- Roblox respawns a dead character at a SpawnLocation by default. Conquest does
-- not want that, so auto-loading is turned off and every spawn goes through here.
Players.CharacterAutoLoads = false

local function homeBaseOf(player: Player): Base?
	for _, base in bases do
		if baseOwner(base) == player.UserId then
			return base
		end
	end
	return nil
end

local function reviveAt(player: Player)
	player:LoadCharacter()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	local home = homeBaseOf(player)
	-- Back at your own keep, unless it has fallen or the closing boundary has
	-- already abandoned it. Reviving someone outside the zone would put them in a
	-- loop of dying, respawning outside, and dying again.
	if home and home.keepHealth > 0 and inZone(home.keep.Position) then
		root.CFrame = CFrame.new(home.keep.Position + Vector3.new(0, 4, 13))
	end
	-- Otherwise they keep the SpawnLocation the engine gave them, which is one of
	-- the pads ringing the totem plaza at the centre - the point the zone closes
	-- onto, so always inside it.
end

-- ---------------------------------------------------------------- tools
local bound: { [Tool]: boolean } = {}

-- Every tool named by a resource is a real tool. Derived from RESOURCES rather
-- than listed again, so adding a sixth good cannot leave its tool inert.
local HARVEST_TOOLS: { [string]: boolean } = {}
for _, config in RESOURCES do
	HARVEST_TOOLS[config.tool] = true
end

local function bindTool(player: Player, tool: Tool)
	if not HARVEST_TOOLS[tool.Name] or bound[tool] then
		return
	end
	bound[tool] = true

	-- Tool.Activated fires on the server too - the engine replicates the
	-- activation - so harvesting needs no RemoteEvent. The tool that fired is
	-- what decides which nodes this swing can work.
	local toolName = tool.Name
	tool.Activated:Connect(function()
		attemptSwing(player, toolName)
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

	playerState.offHandIK = buildOffHandIK(character)

	local downHumanoid = character:FindFirstChildOfClass("Humanoid")
	if downHumanoid then
		downHumanoid.Died:Connect(function()
			notifyPlayer(player, ("Knocked down - up again in %ds"):format(KNOCKDOWN_SECONDS))
			task.delay(KNOCKDOWN_SECONDS, function()
				if player.Parent then
					reviveAt(player)
				end
			end)
		end)
	end

	-- Equipping parents the Tool to the character, unequipping moves it back to
	-- the Backpack, so the off hand follows those two events.
	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and HARVEST_TOOLS[child.Name] then
			setOffHandTarget(player, child)
		end
	end)
	character.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") and HARVEST_TOOLS[child.Name] then
			setOffHandTarget(player, nil)
		end
	end)

	watchForTools(player, character) -- equipped
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		watchForTools(player, backpack) -- holstered
	end

	-- Start with the pickaxe in hand. With four tools the player now has a real
	-- choice of which to hold, but landing with empty hands and a full hotbar is
	-- a worse first second than landing holding the one they started the game
	-- with.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local pickaxe = backpack and backpack:FindFirstChild("Pickaxe")
	if humanoid and pickaxe and pickaxe:IsA("Tool") then
		humanoid:EquipTool(pickaxe)
	end
end

local function onPlayerAdded(player: Player)
	setupPlayer(player)
	state[player] = { track = nil, swingSpeed = 1, nextSwing = 0, nextNotice = 0, offHandIK = nil }
	reputation[player] = 0
	player:SetAttribute("Reputation", 0)

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	else
		-- CharacterAutoLoads is off, so the first body has to be asked for.
		player:LoadCharacter()
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
	registerBase(model)
end
siteFolder.ChildAdded:Connect(registerBase)

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	state[player] = nil
	reputation[player] = nil
end)

-- In Studio playtests the script can start after you are already in, so catch
-- anyone who beat it here.
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
