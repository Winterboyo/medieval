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
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Declared in default.project.json rather than created here, so the remote is
-- version-controlled instead of appearing at runtime.
local notifyRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Notify")

-- Signals, not shared state. The attribute seam this project uses everywhere
-- else describes what something IS; these describe something that HAPPENED, and
-- encoding an event as an incrementing attribute counter is a worse version of
-- a BindableEvent. They are server-only, so nothing crosses to a client here.
local eventsFolder = ServerStorage:WaitForChild("Events")
local specialistStolenSignal = eventsFolder:WaitForChild("SpecialistStolen") :: BindableEvent
local messengerStruckSignal = eventsFolder:WaitForChild("MessengerStruck") :: BindableEvent
local reputationDeltaSignal = eventsFolder:WaitForChild("ReputationDelta") :: BindableEvent
local specialistSetSignal = eventsFolder:WaitForChild("SpecialistSet") :: BindableEvent

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

-- Refined goods. You cannot gather these: they come out of the three workshops,
-- and the last three stages of a village need them. That is what makes the
-- workshops worth building instead of ornaments you put up once the walls are
-- done - the keep and the wall are gated behind having a working economy.
local CRAFTED_ORDER = { "Timber", "Ingot", "Tonic" }

local ALL_GOODS: { string } = {}
for _, name in RESOURCE_ORDER do
	table.insert(ALL_GOODS, name)
end
for _, name in CRAFTED_ORDER do
	table.insert(ALL_GOODS, name)
end

-- One recipe per workshop, each consuming a different pair, so no two workshops
-- compete for the same pile. This is also the sink Grain, Wool and Ore never
-- had: every raw resource now feeds something.
local RECIPES: { [string]: { makes: string, cost: { [string]: number } } } = {
	Carpenter = { makes = "Timber", cost = { Wood = 5, Stone = 2 } },
	Blacksmith = { makes = "Ingot", cost = { Ore = 4, Wood = 2 } },
	Alchemist = { makes = "Tonic", cost = { Grain = 4, Wool = 3 } },
}

local function describeCost(cost: { [string]: number }): string
	local bits = {}
	for _, name in ALL_GOODS do
		local amount = cost[name]
		if amount then
			table.insert(bits, ("%d %s"):format(amount, name))
		end
	end
	return table.concat(bits, " + ")
end

-- What one wall repair costs once the village is finished.
local BUILD_COST: { [string]: number } = {
	Wood = 4,
	Stone = 4,
}

-- The village is built in TEN purchases, in a fixed order: ordinary dwellings
-- first, then the workshops that refine what those dwellings gather, then the
-- keep, then the wall around all of it. A plot starts as bare ground.
--
-- The order is the point. You cannot wall off an empty field, and you cannot
-- raise a keep before you have anyone to build it - so early game is soft and
-- open, and a village only becomes a fortress once its owner has actually done
-- the work. Costs climb, and the last three need refined goods.
type Upgrade = { name: string, cost: { [string]: number } }

local UPGRADES: { Upgrade } = {
	{ name = "Cottage", cost = { Wood = 10, Grain = 5 } },
	{ name = "Second cottage", cost = { Wood = 12, Grain = 6 } },
	{ name = "Third cottage", cost = { Wood = 14, Grain = 8 } },
	{ name = "Fourth cottage", cost = { Wood = 16, Grain = 10 } },
	{ name = "Carpenter", cost = { Wood = 20, Stone = 10 } },
	{ name = "Blacksmith", cost = { Stone = 20, Ore = 10 } },
	{ name = "Alchemist", cost = { Stone = 18, Wool = 14, Ore = 8 } },
	{ name = "Keep", cost = { Stone = 30, Timber = 6, Ingot = 6 } },
	{ name = "Palisade", cost = { Wood = 25, Timber = 8 } },
	{ name = "Rampart", cost = { Stone = 35, Ingot = 8, Tonic = 4 } },
}

local KEEP_STAGE = 8
local PALISADE_STAGE = 9
local RAMPART_STAGE = 10

-- ---------------------------------------------------------------- specialists
-- DESIGN.md files specialists as the stretch goal to build once Conquest's core
-- loop works. It does, so here they are - minus the rebellious flag and the spy
-- variant, which the doc itself says need a decision first and which Winter has
-- deferred.
--
-- A specialist is per PLAYER, not per building. You hold at most one of each
-- role; the workshop is what lets you USE them. That is what makes stealing one
-- coherent: the thief needs somewhere to put them.
local SPECIALIST_ROLES = { "Blacksmith", "Alchemist", "Carpenter" }

-- Which upgrade stage grants which role. Building the workshop IS hiring the
-- specialist - there is no separate recruitment step to forget about.
local ROLE_FOR_STAGE: { [number]: string } = {
	[5] = "Carpenter",
	[6] = "Blacksmith",
	[7] = "Alchemist",
}

local MAX_RANK = 5

-- The doc's number: a thief gets the specialist at a FLAT 85%, not scaled by
-- skill. Flat matters - it means stealing a rank 5 is worth far more than
-- stealing a rank 1, so raids aim at who is actually worth taking.
local STOLEN_EFFICIENCY = 0.85

-- Investable skill rankings, and the costs are paid in the goods specialists
-- themselves make. Training loops back into the economy the workshops created
-- rather than sitting outside it.
local SKILL_COST: { [number]: { [string]: number } } = {
	[2] = { Grain = 10, Timber = 2 },
	[3] = { Wood = 20, Timber = 4, Ingot = 2 },
	[4] = { Stone = 25, Ingot = 4, Tonic = 2 },
	[5] = { Ore = 30, Ingot = 6, Tonic = 4 },
}

-- A cottage houses a labourer, so the four cottage stages stop being dressing.
-- The doc lists "farmer/miner NPCs (classic resource gathering)" as a role; this
-- is that, kept abstract - a slow trickle into the owner's stock rather than an
-- NPC with pathfinding, which is a project of its own.
local LABOUR_INTERVAL = 12 -- seconds between a village's labour tick
local LABOUR_PER_COTTAGE = 1
local COTTAGE_STAGES = 4

-- The wall is ONE hitpoint value. The ring of blocks is how much of it is
-- standing, drawn from that value - not twenty-odd separate little walls.
local WALL_BLOCK_SIZE = Vector3.new(20.4, 11, 3.6)
local WALL_HP_PER_SECTION = 25 -- what one repair buys

-- The wall's strength is a FIXED pool, no longer "however many blocks the ring
-- happens to have times 25". Decoupling the two means the ring can be drawn at
-- whatever density looks right for a 148 stud village without quietly turning a
-- siege into a forty swing grind.
local WALL_MAX_HP = 600
local PALISADE_FRACTION = 0.5 -- what the ninth stage raises; the tenth finishes it

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
local stockpileDirty: { [Player]: boolean } = {}

type Specialist = { role: string, rank: number, stolen: boolean }
-- One roster per player: role -> specialist. Absent means they do not have one.
local roster: { [Player]: { [string]: Specialist } } = {}
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

	-- One column per good, in a fixed order so the player list does not shuffle
	-- its columns between joins.
	for _, name in ALL_GOODS do
		local counter = Instance.new("IntValue")
		counter.Name = name
		counter.Value = 0
		-- The stockpile heap is a readout of what its owner holds, so every
		-- change to a counter makes it stale. Flag it rather than redrawing
		-- here: a swing a second per player would otherwise rebuild forty parts
		-- each time, and the flag collapses a burst into one redraw.
		counter.Changed:Connect(function()
			stockpileDirty[player] = true
		end)
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
	for _, name in ALL_GOODS do
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
-- The nearest point on a part to somebody standing outside it, in world space.
--
-- This exists because range is measured in 3D to whatever point we hand
-- isAimedAt, and handing it a big part's CENTRE makes that part unhittable as it
-- grows. The keep is 30 studs tall, so its centre sits ~15 studs up; from its
-- own wall the 3D distance to that centre is ~17 against a MINE_RANGE of 15, and
-- the keep could not be damaged from anywhere at all. Elimination was therefore
-- impossible - silently, because the same code passed when the keep was half the
-- height. Aim at the surface, not the middle.
local function nearestPointOn(part: BasePart, from: Vector3): Vector3
	local inPart = part.CFrame:PointToObjectSpace(from)
	local half = part.Size / 2
	return part.CFrame:PointToWorldSpace(Vector3.new(
		math.clamp(inPart.X, -half.X, half.X),
		math.clamp(inPart.Y, -half.Y, half.Y),
		math.clamp(inPart.Z, -half.Z, half.Z)))
end

local function isAimedAt(root: BasePart, position: Vector3, range: number): (boolean, number)
	local delta = position - root.Position
	local distance = delta.Magnitude
	if distance > range then
		return false, distance
	end
	local flat = Vector3.new(delta.X, 0, delta.Z)
	-- Standing on, or hard against, the target.
	--
	-- Since aim points are clamped to a part's SURFACE, a wide flat thing puts
	-- its nearest point directly under your feet: the stockpile pallet is 22 x
	-- 18, so a raider standing on it has essentially no horizontal offset to
	-- the surface at all. The old guard then bailed out and the pallet could
	-- not be looted from on top of it - measured as 60 swings moving nothing.
	--
	-- The facing test exists to stop you hitting things BEHIND you at range.
	-- At arm's length there is no behind, so count it as aimed rather than
	-- refusing. This is the other half of the surface-aiming change that fixed
	-- the keep: clamping to the surface helps big TALL targets and hurts big
	-- FLAT ones, and both need handling.
	if flat.Magnitude <= 2 then
		return true, distance
	end
	return root.CFrame.LookVector:Dot(flat.Unit) >= FACING_DOT, distance
end

-- Raiding only counts while a match is actually running. Without this a keep
-- could be razed during the lobby, and MatchService only records an elimination
-- while Running - so the keep fell, nobody was eliminated, and the two services
-- disagreed silently about whether a player was still in the game.
--
-- Absent is treated as running, the same rule zoneHalf follows below: a service
-- that has not spoken yet must not disable the game.
local function matchRunning(): boolean
	local value = Workspace:GetAttribute("MatchState")
	return value == nil or value == "Running"
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
	if not matchRunning() then
		return nil, nil
	end
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
	-- Gate and keep do NOT exist on a fresh plot. They arrive with stages 9 and
	-- 8, so everything that touches them has to cope with nil rather than assume
	-- a finished village.
	gate: BasePart?,
	stockpile: BasePart,
	goods: Instance,
	heap: Attachment,
	-- role -> the bench a raider aims at to take that specialist. Filled in when
	-- a workshop is installed, so the raid path never has to walk the model.
	workshops: { [string]: BasePart },
	blueprint: Instance?,
	stage: number,
	prompt: ProximityPrompt,
	sections: Instance,
	slots: { Attachment },
	wall: number, -- the single HP value
	wallMax: number,
	breached: boolean,
	keep: BasePart?,
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

-- ---------------------------------------------------------------- specialists
local function rosterOf(player: Player): { [string]: Specialist }
	local held = roster[player]
	if not held then
		held = {}
		roster[player] = held
	end
	return held
end

local function specialistCount(player: Player): number
	local n = 0
	for _ in rosterOf(player) do
		n += 1
	end
	return n
end

-- What a specialist actually produces per job. Flat rank, docked to 85% if they
-- are working for the person who took them - a stolen rank 5 out-produces an
-- honest rank 4, which is the point of stealing one.
local function outputOf(specialist: Specialist): number
	local efficiency = if specialist.stolen then STOLEN_EFFICIENCY else 1
	return math.max(1, math.floor(specialist.rank * efficiency))
end

local function describeSpecialist(specialist: Specialist): string
	return ("%s rank %d%s"):format(
		specialist.role, specialist.rank,
		if specialist.stolen then (" (taken, %d%%)"):format(STOLEN_EFFICIENCY * 100) else "")
end

local function publishRoster(player: Player)
	local held = rosterOf(player)
	local bits = {}
	for _, role in SPECIALIST_ROLES do
		local specialist = held[role]
		if specialist then
			bits[#bits + 1] = ("%s%d%s"):format(role:sub(1, 1), specialist.rank,
				if specialist.stolen then "*" else "")
		end
	end
	player:SetAttribute("Specialists", table.concat(bits, " "))
	player:SetAttribute("SpecialistCount", specialistCount(player))
end

local function grantSpecialist(player: Player, role: string, rank: number, stolen: boolean)
	rosterOf(player)[role] = { role = role, rank = rank, stolen = stolen }
	publishRoster(player)
end

local function takeSpecialist(player: Player, role: string): Specialist?
	local held = rosterOf(player)
	local specialist = held[role]
	held[role] = nil
	publishRoster(player)
	return specialist
end

-- ---------------------------------------------------------------- blueprints
-- build-world builds every stage of every village up front into ServerStorage
-- and leaves it there. Buying a stage is a reparent: the parts are already
-- positioned in world space, so nothing here needs to know what a house looks
-- like or where it goes.
local blueprintRoot = ServerStorage:FindFirstChild("VillageBlueprints")

local function blueprintFor(name: string): Instance?
	return blueprintRoot and blueprintRoot:FindFirstChild(name)
end

-- ---------------------------------------------------------------- the heap
-- The stockpile is not a shed with a number on it. It is a pile of actual goods
-- whose size and composition track what the owner is holding, so you can look
-- at somebody's village from outside and tell whether it is worth raiding.
local GOODS_LOOK: { [string]: { color: Color3, material: Enum.Material, size: Vector3, per: number } } = {
	Wood = { color = Color3.fromRGB(112, 80, 50), material = Enum.Material.Wood, size = Vector3.new(4.4, 1.6, 1.6), per = 3 },
	Grain = { color = Color3.fromRGB(198, 168, 92), material = Enum.Material.Fabric, size = Vector3.new(2.4, 2.4, 2.0), per = 3 },
	Wool = { color = Color3.fromRGB(238, 232, 220), material = Enum.Material.Fabric, size = Vector3.new(3.0, 2.0, 2.0), per = 2 },
	Stone = { color = Color3.fromRGB(126, 122, 116), material = Enum.Material.Rock, size = Vector3.new(2.6, 2.0, 2.2), per = 3 },
	Ore = { color = Color3.fromRGB(150, 104, 66), material = Enum.Material.Metal, size = Vector3.new(2.2, 1.8, 2.0), per = 2 },
	Timber = { color = Color3.fromRGB(168, 132, 84), material = Enum.Material.WoodPlanks, size = Vector3.new(5.0, 1.2, 2.4), per = 1 },
	Ingot = { color = Color3.fromRGB(178, 182, 190), material = Enum.Material.Metal, size = Vector3.new(2.4, 1.0, 1.4), per = 1 },
	Tonic = { color = Color3.fromRGB(126, 220, 148), material = Enum.Material.Neon, size = Vector3.new(1.2, 1.8, 1.2), per = 1 },
}

-- Capped, because a rich player should read as "very full" and not as a tower of
-- crates you can see from the next tile.
local HEAP_MAX_PIECES = 44
local HEAP_PER_LAYER = 11

local function redrawStockpile(base: Base)
	base.goods:ClearAllChildren()
	local ownerId = baseOwner(base)
	local owner = ownerId and Players:GetPlayerByUserId(ownerId)
	if not owner then
		return
	end

	-- How many pieces each good WANTS, before the cap.
	local want: { [string]: number } = {}
	local total = 0
	for _, name in ALL_GOODS do
		local look = GOODS_LOOK[name]
		local counter = counterFor(owner, name)
		local pieces = if look and counter then math.floor(counter.Value / look.per) else 0
		want[name] = pieces
		total += pieces
	end

	-- Scale to the cap PROPORTIONALLY rather than filling first-come. Filling in
	-- order meant a player holding a lot of wood got a heap of nothing but wood
	-- and the other seven goods never appeared, which defeats the point: the
	-- pile is supposed to tell you what is in there, not just that it is full.
	if total > HEAP_MAX_PIECES then
		local scale = HEAP_MAX_PIECES / total
		local scaled = 0
		for _, name in ALL_GOODS do
			if want[name] > 0 then
				want[name] = math.max(1, math.floor(want[name] * scale))
				scaled += want[name]
			end
		end
		-- The per-good floor of 1 can push the total back over; trim the
		-- overshoot off whichever pile is biggest.
		while scaled > HEAP_MAX_PIECES do
			local biggest, most = nil, 0
			for _, name in ALL_GOODS do
				if want[name] > most then
					biggest, most = name, want[name]
				end
			end
			if not biggest or most <= 1 then
				break
			end
			want[biggest] -= 1
			scaled -= 1
		end
	end

	local origin = base.heap.WorldCFrame
	local placed = 0
	for _, name in ALL_GOODS do
		local look = GOODS_LOOK[name]
		if look then
			for _ = 1, want[name] do
				if placed >= HEAP_MAX_PIECES then
					break
				end
				local layer = math.floor(placed / HEAP_PER_LAYER)
				local slot = placed % HEAP_PER_LAYER
				-- Each layer is turned half a slot off the one below, so the
				-- pile interlocks instead of stacking into neat columns.
				local angle = (slot / HEAP_PER_LAYER) * math.pi * 2 + layer * 0.42
				local radius = math.max(1.1, 7.6 - layer * 1.9)
				local piece = Instance.new("Part")
				piece.Name = name .. "Pile"
				piece.Size = look.size
				piece.CFrame = origin
					* CFrame.new(
						math.cos(angle) * radius,
						look.size.Y / 2 + layer * look.size.Y * 0.9,
						math.sin(angle) * radius)
					* CFrame.Angles(0, angle, 0)
				piece.Anchored = true
				piece.CanCollide = false -- goods you can walk through beat goods you get stuck on
				piece.Material = look.material
				piece.Color = look.color
				piece.TopSurface = Enum.SurfaceType.Smooth
				piece.BottomSurface = Enum.SurfaceType.Smooth
				piece.Parent = base.goods
				placed += 1
			end
		end
	end
end

-- ---------------------------------------------------------------- workshops
-- One recipe each, wired when the workshop is actually installed rather than up
-- front, because until it is bought the prompt is sitting in ServerStorage.
local craftBound: { [ProximityPrompt]: boolean } = {}

local function bindTrainPrompts(base: Base)
	for _, thing in base.model:GetDescendants() do
		if thing:IsA("ProximityPrompt") and thing.Name == "TrainPrompt" and not craftBound[thing] then
			local role = thing:GetAttribute("Role")
			if typeof(role) == "string" then
				craftBound[thing] = true
				thing.Triggered:Connect(function(player: Player)
					local owner = baseOwner(base)
					if owner and owner ~= player.UserId then
						notifyPlayer(player, "Someone else's workshop")
						return
					end
					local specialist = rosterOf(player)[role]
					if not specialist then
						notifyPlayer(player, ("No %s to train"):format(role))
						return
					end
					if specialist.rank >= MAX_RANK then
						notifyPlayer(player, ("%s is already rank %d"):format(role, MAX_RANK))
						return
					end
					local cost = SKILL_COST[specialist.rank + 1]
					local affordable, missing = canAfford(player, cost)
					if not affordable then
						notifyPlayer(player, ("Rank %d needs %s - short on %s"):format(
							specialist.rank + 1, describeCost(cost), tostring(missing)))
						return
					end
					spend(player, cost)
					specialist.rank += 1
					publishRoster(player)
					notifyPlayer(player, ("%s trained to rank %d - now makes %d a job"):format(
						role, specialist.rank, outputOf(specialist)))
				end)
			end
		end
	end
end

local function bindCraftPrompts(base: Base)
	bindTrainPrompts(base)
	for _, thing in base.model:GetDescendants() do
		if thing:IsA("ProximityPrompt") and thing.Name == "CraftPrompt" and not craftBound[thing] then
			local recipeName = thing:GetAttribute("Recipe")
			local recipe = if typeof(recipeName) == "string" then RECIPES[recipeName] else nil
			if recipe then
				craftBound[thing] = true
				-- Remember the bench now, while we are already walking the model
				-- for a reason. Raid targeting reads this table instead.
				local host = thing.Parent
				if host and host:IsA("BasePart") then
					base.workshops[recipeName :: string] = host
				end
				thing.ActionText = ("%s to %s"):format(describeCost(recipe.cost), recipe.makes)
				thing.Triggered:Connect(function(player: Player)
					local owner = baseOwner(base)
					if owner and owner ~= player.UserId then
						notifyPlayer(player, "Someone else's workshop")
						return
					end
					-- The workshop is the bench; the specialist is who works it.
					-- An empty workshop makes nothing, which is what gives
					-- stealing one its bite.
					local specialist = rosterOf(player)[recipeName :: string]
					if not specialist then
						notifyPlayer(player, ("No %s to work it"):format(tostring(recipeName)))
						return
					end
					local affordable, missing = canAfford(player, recipe.cost)
					if not affordable then
						notifyPlayer(player, ("Need %d %s"):format(
							recipe.cost[missing :: string], tostring(missing)))
						return
					end
					spend(player, recipe.cost)
					local yield = outputOf(specialist)
					local made = counterFor(player, recipe.makes)
					if made then
						made.Value += yield
					end
					notifyPlayer(player, ("%s made %d %s"):format(
						describeSpecialist(specialist), yield, recipe.makes), 1)
				end)
			end
		end
	end
end

-- ---------------------------------------------------------------- stages
-- Buying a stage moves its parts out of the blueprint and into the world. The
-- three stages that mean something mechanically say so here; the rest are
-- buildings, and a building is just geometry until specialists exist.
local function installStage(base: Base, index: number)
	local plan = base.blueprint
	local folder = plan and plan:FindFirstChild(("Stage%02d"):format(index))
	if folder then
		for _, piece in folder:GetChildren() do
			piece.Parent = base.model
		end
		folder:Destroy()
	end
	base.stage = index

	-- Building a workshop hires its specialist, at rank 1 and working honestly.
	local role = ROLE_FOR_STAGE[index]
	if role then
		local ownerId = baseOwner(base)
		local owner = ownerId and Players:GetPlayerByUserId(ownerId)
		if owner and not rosterOf(owner)[role] then
			grantSpecialist(owner, role, 1, false)
			notifyPlayer(owner, ("A %s has taken up the workshop"):format(role))
		end
	end

	if index == KEEP_STAGE then
		local keep = base.model:FindFirstChild("Keep")
		base.keep = if keep and keep:IsA("BasePart") then keep else nil
	elseif index == PALISADE_STAGE then
		local gate = base.model:FindFirstChild("Gate")
		base.gate = if gate and gate:IsA("BasePart") then gate else nil
		base.wall = math.floor(base.wallMax * PALISADE_FRACTION)
		base.breached = false
		redrawWall(base)
	elseif index == RAMPART_STAGE then
		base.wall = base.wallMax
		base.breached = false
		redrawWall(base)
	end

	bindCraftPrompts(base)
end

local function registerBase(model: Instance)
	if not model:IsA("Model") or model:GetAttribute("Kind") ~= "Base" then
		return
	end

	local foundation = model.PrimaryPart or model:FindFirstChild("Foundation")
	local stockpile = model:FindFirstChild("Stockpile")
	local goods = model:FindFirstChild("Goods")
	local sections = model:FindFirstChild("Sections")
	local prompt = foundation and foundation:FindFirstChildOfClass("ProximityPrompt")
	local heap = stockpile and stockpile:IsA("BasePart") and stockpile:FindFirstChild("HeapOrigin")
	-- Only what an EMPTY plot has is required. The gate and the keep are bought,
	-- so demanding them here would leave every fresh plot unregistered.
	if not (foundation and foundation:IsA("BasePart")
		and stockpile and stockpile:IsA("BasePart")
		and goods and sections and prompt
		and heap and heap:IsA("Attachment")) then
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
		gate = nil,
		stockpile = stockpile,
		goods = goods,
		heap = heap,
		workshops = {},
		blueprint = blueprintFor(model.Name),
		stage = 0,
		prompt = prompt,
		sections = sections,
		slots = slots,
		wall = 0,
		wallMax = WALL_MAX_HP,
		breached = true, -- an unbuilt base has nothing keeping anyone out
		keep = nil,
		keepHealth = KEEP_HP,
		loot = {},
		refresh = function() end,
	}

	base.refresh = function()
		local ownerName = model:GetAttribute("OwnerName")
		local who = if typeof(ownerName) == "string" then ownerName .. "'s village" else "Empty plot"
		local next = UPGRADES[base.stage + 1]

		if next then
			base.prompt.ObjectText = ("%s  (%d/%d built)"):format(who, base.stage, #UPGRADES)
			base.prompt.ActionText = ("%s - %s"):format(next.name, describeCost(next.cost))
			base.prompt.Enabled = true
		elseif base.wall < base.wallMax then
			-- The ladder is finished, so the prompt turns into repair. A breach
			-- has to be repairable or a village falls exactly once, forever.
			base.prompt.ObjectText = ("%s  wall %d/%d"):format(
				who, math.floor(base.wall), base.wallMax)
			base.prompt.ActionText = ("Repair - %s"):format(describeCost(BUILD_COST))
			base.prompt.Enabled = true
		else
			base.prompt.ObjectText = ("%s  wall %d/%d"):format(
				who, math.floor(base.wall), base.wallMax)
			base.prompt.ActionText = "Village complete"
			base.prompt.Enabled = false
		end

		model:SetAttribute("Stage", base.stage)
		model:SetAttribute("StageName", if next then next.name else "Complete")
		model:SetAttribute("Wall", math.floor(base.wall))
		model:SetAttribute("Breached", base.breached)
		-- What the breach exposed, published the moment it is taken rather than
		-- on the first successful loot swing. It used to be written only inside
		-- the loot branch, so between breaching a wall and landing a swing on
		-- the pile the attribute read nil - indistinguishable from "nothing
		-- left" to anything watching from outside. Computed inline because
		-- lootRemaining is declared further down the file than this closure.
		local exposed = 0
		for _, amount in base.loot do
			exposed += amount
		end
		model:SetAttribute("LootLeft", exposed)
		model:SetAttribute("KeepHealth", math.floor(base.keepHealth))
		model:SetAttribute("Fallen", base.keepHealth <= 0)
		-- The keep darkens and finally slumps as it is broken up, so its state
		-- reads from outside without a health bar - the same trick as the gate.
		local keepLeft = base.keepHealth / KEEP_HP
		if base.keep then
			base.keep.Color = Color3.fromRGB(58, 50, 46):Lerp(Color3.fromRGB(128, 118, 108), keepLeft)
			base.keep.Transparency = if base.keepHealth <= 0 then 0.55 else 0
		end
		-- The gate darkens as the wall fails, so an attacker can read how close
		-- a base is to falling without a health bar.
		local fraction = if base.wallMax > 0 then base.wall / base.wallMax else 0
		if base.gate then
			base.gate.Color = Color3.fromRGB(58, 40, 26):Lerp(Color3.fromRGB(104, 72, 44), fraction)
		end
	end
	base.refresh()

	base.prompt.Triggered:Connect(function(player: Player)
		local owner = baseOwner(base)
		if owner and owner ~= player.UserId then
			notifyPlayer(player, ("%s's village - raid it, do not build it"):format(
				tostring(model:GetAttribute("OwnerName") or "Someone")))
			return
		end

		-- An eliminated player is somebody's worker now. Letting them claim a
		-- fresh plot would hand them a new keep that MatchService can never tie
		-- back to a squad - squadLedBy only knows original leaders - so razing
		-- it would record no elimination at all. They keep gathering, crafting
		-- and fighting for the squad that took them; what they lose is the
		-- ability to start again as their own house.
		if not owner and player:GetAttribute("Eliminated") == true then
			notifyPlayer(player, "You have no house of your own to build")
			return
		end

		local next = UPGRADES[base.stage + 1]
		local cost = if next then next.cost else BUILD_COST
		if not next and base.wall >= base.wallMax then
			return
		end

		local affordable, missing = canAfford(player, cost)
		if not affordable then
			-- Straight to the one player who cannot afford it, naming what they
			-- are short of. This used to write the prompt's ActionText, which
			-- every player at the base shares - see notifyPlayer.
			notifyPlayer(player, ("Need %d %s"):format(cost[missing :: string], tostring(missing)))
			return
		end
		spend(player, cost)

		-- The first purchase claims the plot, whatever it was.
		if not owner then
			model:SetAttribute("Owner", player.UserId)
			model:SetAttribute("OwnerName", player.Name)
			redrawStockpile(base)
		end

		if next then
			installStage(base, base.stage + 1)
			notifyPlayer(player, ("Built: %s (%d/%d)"):format(next.name, base.stage, #UPGRADES))
		else
			base.wall = math.min(base.wallMax, base.wall + WALL_HP_PER_SECTION)
			if base.wall > 0 then
				base.breached = false
			end
			redrawWall(base)
		end

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
	for _, name in ALL_GOODS do
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
	if not matchRunning() then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local best: Base? = nil
	local bestDistance = math.huge
	for _, base in bases do
		local owner = baseOwner(base)
		if owner and owner ~= raider.UserId and base.wall > 0 and base.gate then
			local aimed, distance = isAimedAt(root, nearestPointOn(base.gate, root.Position), MINE_RANGE)
			if aimed and distance < bestDistance then
				best = base
				bestDistance = distance
			end
		end
	end
	return best
end

-- How many specialists the owner of this base still has. This is the doc's
-- fourth elimination clause, which could not be built until specialists existed.
--
-- Deliberately the OWNER's whole roster rather than anything per-base. A
-- specialist belongs to a player, not to a building - the workshop is only what
-- lets you use them - so "specialists lost" is a fact about the person, which is
-- also how DESIGN.md words it. The consequence is that a player holding two
-- villages has both keeps gated on one roster: strip their people once and both
-- are exposed. That is the intended reading, not an oversight.
local function specialistsLeft(base: Base): number
	local ownerId = baseOwner(base)
	local owner = ownerId and Players:GetPlayerByUserId(ownerId)
	return if owner then specialistCount(owner) else 0
end

-- Nearest enemy WORKSHOP you are aimed at, on a base whose wall has fallen, whose
-- owner still has that specialist. Returns the base and the role.
--
-- The workshop bench is the aim target because it is the thing already carrying
-- the role, so there is nothing new to place in the world.
local function findSpecialistTarget(raider: Player, character: Model): (Base?, string?, BasePart?)
	if not matchRunning() then
		return nil, nil, nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil, nil, nil
	end
	local bestBase: Base? = nil
	local bestRole: string? = nil
	local bestHost: BasePart? = nil
	local bestDistance = math.huge

	for _, base in bases do
		local ownerId = baseOwner(base)
		local owner = ownerId and Players:GetPlayerByUserId(ownerId)
		if owner and ownerId ~= raider.UserId and base.breached then
			-- base.workshops is at most three entries. This used to walk every
			-- descendant of every base on every swing, which is fine on an empty
			-- plot and thousands of traversals a second once villages are built.
			for role, host in base.workshops do
				if rosterOf(owner)[role] then
					local aimed, distance = isAimedAt(root, nearestPointOn(host, root.Position), MINE_RANGE)
					if aimed and distance < bestDistance then
						bestBase, bestRole, bestHost, bestDistance = base, role, host, distance
					end
				end
			end
		end
	end
	return bestBase, bestRole, bestHost
end

-- Nearest messenger you are aimed at. Messengers are the only raid target that
-- is not part of a base, because DESIGN.md wants killing one to be an
-- escalation open to either side - and if it is a real figure standing in a
-- village then killing it is an ordinary swing rather than a button in a menu.
local function findMessengerTarget(character: Model): Model?
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local folder = Workspace:FindFirstChild("Messengers")
	if not folder then
		return nil
	end
	local best: Model? = nil
	local bestDistance = math.huge
	for _, messenger in folder:GetChildren() do
		local anchor = if messenger:IsA("Model") then messenger.PrimaryPart else nil
		if anchor then
			local aimed, distance = isAimedAt(root, nearestPointOn(anchor, root.Position), MINE_RANGE)
			if aimed and distance < bestDistance then
				best = messenger :: Model
				bestDistance = distance
			end
		end
	end
	return best
end

-- Nearest enemy KEEP you are aimed at, and only on a base that has already lost
-- its wall, had its stockpile emptied AND lost every specialist. That ordering is
-- the whole design: elimination is a completed siege, never a lucky hit on the
-- way past. The specialist clause is DESIGN.md's own, finally buildable.
local function findKeepTarget(raider: Player, character: Model): Base?
	if not matchRunning() then
		return nil
	end
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
			and base.keep -- no keep bought yet means nothing to raze
			and specialistsLeft(base) == 0
		then
			local aimed, distance = isAimedAt(root, nearestPointOn(base.keep, root.Position), MINE_RANGE)
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
	if not matchRunning() then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local best: Base? = nil
	local bestDistance = math.huge
	for _, base in bases do
		local owner = baseOwner(base)
		if owner and owner ~= raider.UserId and base.breached then
			local aimed, distance = isAimedAt(root, nearestPointOn(base.stockpile, root.Position), MINE_RANGE)
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
			for _, name in ALL_GOODS do
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

		-- 4. an enemy specialist, once the wall is down. The doc's flat 85%: a
		-- stolen rank 5 still out-produces an honest rank 4, so a raid aims at
		-- whoever is actually worth taking rather than at whatever is nearest.
		local specialistBase, stolenRole, workshopHost = findSpecialistTarget(player, liveCharacter)
		if specialistBase and stolenRole and workshopHost then
			local victimId = baseOwner(specialistBase)
			local victim = victimId and Players:GetPlayerByUserId(victimId)
			if victim then
				local taken = takeSpecialist(victim, stolenRole)
				if taken then
					local incoming: Specialist = { role = stolenRole, rank = taken.rank, stolen = true }
					local existing = rosterOf(player)[stolenRole]
					local transferred = false
					if existing and outputOf(existing) >= outputOf(incoming) then
						-- Ours is better, so theirs is simply gone. Denial is
						-- still worth the swing.
						notifyPlayer(player, ("Took %s's %s - yours was better, theirs is lost"):format(
							victim.Name, stolenRole))
					else
						transferred = true
						rosterOf(player)[stolenRole] = incoming
						publishRoster(player)
						notifyPlayer(player, ("Took %s from %s - %s"):format(
							stolenRole, victim.Name, describeSpecialist(incoming)))
					end
					publishRoster(victim)

					local left = specialistCount(victim)
					notifyPlayer(victim, ("%s has taken your %s (%d specialist%s left)"):format(
						player.Name, stolenRole, left, if left == 1 then "" else "s"))
					if left == 0 then
						notifyPlayer(victim, "Your keep is exposed")
						notifyPlayer(player, ("%s has nobody left - the keep is open"):format(victim.Name))
					end

					adjustReputation(player, REPUTATION_THEFT_PENALTY,
						("took %s from %s"):format(stolenRole, victim.Name))

					-- NegotiationService takes it from here: the doc says a theft
					-- forces an engagement between the two players.
					--
					-- ONLY when the specialist actually changed hands. On the
					-- denial branch they were destroyed rather than taken, so
					-- there is nobody to ransom - and opening a session anyway
					-- would end by granting the thief a soured copy of someone
					-- they never had, overwriting the better one they kept.
					if transferred then
						specialistStolenSignal:Fire(player, victim, stolenRole, taken.rank)
					end

					local away = (root.Position - workshopHost.Position)
					away = Vector3.new(away.X, 0, away.Z)
					away = if away.Magnitude > 0.01 then away.Unit else Vector3.new(0, 0, 1)
					spawnChips(workshopHost.Position + Vector3.new(0, 2, 0), away, 5)
					return
				end
			end
		end

		-- 5. an enemy keep, once the wall is down, the stockpile is spent and
		-- every specialist is gone
		local keepTarget = findKeepTarget(player, liveCharacter)
		if keepTarget then
			local ownerName = tostring(keepTarget.model:GetAttribute("OwnerName") or "someone")
			keepTarget.keepHealth = math.max(0, keepTarget.keepHealth - GATE_DAMAGE)
			keepTarget.refresh()

			local ownerId = baseOwner(keepTarget)
			local owner = ownerId and Players:GetPlayerByUserId(ownerId)

			if keepTarget.keepHealth <= 0 then
				-- MatchService watches the Fallen attribute and turns this into
				-- an elimination, so this branch only has to make the keep fall
				-- and say so.
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

		-- 6. a messenger. The doc's escalation, and a swing rather than a menu
		-- choice on purpose - it should feel like something you did.
		local messenger = findMessengerTarget(liveCharacter)
		if messenger then
			messengerStruckSignal:Fire(player, messenger)
			return
		end

		-- 7. something to harvest, if this tool can harvest it
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

-- One redraw pass for every stockpile whose owner has gained or spent anything
-- since the last tick. Collapsing a burst of counter changes into a single
-- rebuild is the whole reason the flag exists.
task.spawn(function()
	while true do
		task.wait(0.4)
		for player in stockpileDirty do
			stockpileDirty[player] = nil
			if player.Parent then
				for _, base in bases do
					if baseOwner(base) == player.UserId then
						redrawStockpile(base)
					end
				end
			end
		end
	end
end)

-- ---------------------------------------------------------------- labour
-- A cottage houses a labourer. DESIGN.md lists "farmer/miner NPCs (classic
-- resource gathering)" as a specialist role; this is that, kept abstract - a
-- slow trickle rather than an NPC with pathfinding, which is a project of its
-- own and not what makes the tier interesting.
--
-- One resource per cottage, in build order, so four cottages is four different
-- trickles and you can see which ones you have. Ore is deliberately absent:
-- leaving it hand-mined keeps it the scarce input, which is what the blacksmith
-- and therefore the whole keep-and-wall chain is gated on.
local LABOUR_YIELD = { "Grain", "Wood", "Stone", "Wool" }

task.spawn(function()
	while true do
		task.wait(LABOUR_INTERVAL)
		if Workspace:GetAttribute("MatchState") ~= "Running" then
			continue
		end
		for _, base in bases do
			local ownerId = baseOwner(base)
			local owner = ownerId and Players:GetPlayerByUserId(ownerId)
			-- A village outside the closing boundary stops producing, the same
			-- rule its nodes already follow, and a razed one produces nothing.
			-- A village whose people have been enraged stops working. That is
			-- what "enrages the killer's own troops" cashes out to in a game
			-- with no troops: the labourers you do have put their tools down.
			local pausedUntil = owner and owner:GetAttribute("LabourPausedUntil")
			local paused = typeof(pausedUntil) == "number" and os.clock() < pausedUntil
			if owner and not paused and base.keepHealth > 0 and inZone(base.foundation.Position) then
				local cottages = math.min(base.stage, COTTAGE_STAGES)
				for i = 1, cottages do
					local counter = counterFor(owner, LABOUR_YIELD[i])
					if counter then
						counter.Value += LABOUR_PER_COTTAGE
					end
				end
			end
		end
	end
end)

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
	roster[player] = {}
	publishRoster(player)

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
-- The roster lives in this file too. A nil rank means "remove them"; anything
-- else grants at that rank. NegotiationService uses both ends of this when a
-- ransom settles: the thief loses them, the victim gets them back.
specialistSetSignal.Event:Connect(function(player: Player, role: string, rank: number?, stolen: boolean)
	if not (player and player:IsA("Player")) or typeof(role) ~= "string" then
		return
	end
	if rank == nil then
		takeSpecialist(player, role)
	elseif typeof(rank) == "number" then
		grantSpecialist(player, role, math.clamp(math.floor(rank), 1, MAX_RANK), stolen == true)
	end
end)

-- Reputation lives in this file, so anything else that wants to move it asks
-- rather than keeping its own copy.
reputationDeltaSignal.Event:Connect(function(player: Player, delta: number, reason: string)
	if typeof(delta) == "number" and player and player:IsA("Player") then
		adjustReputation(player, delta, tostring(reason))
	end
end)

Players.PlayerRemoving:Connect(function(player)
	state[player] = nil
	reputation[player] = nil
	roster[player] = nil
	stockpileDirty[player] = nil
end)

-- In Studio playtests the script can start after you are already in, so catch
-- anyone who beat it here.
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
