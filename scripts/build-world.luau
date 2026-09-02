--!strict
-- Medieval Land - world builder. A Catan board filling the whole map: a 7x7 grid
-- of square resource tiles, a village at the centre, castle plots on the tile
-- corners. One-shot setup. Safe to re-run: it tears down what it built first.

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local StarterPack = game:GetService("StarterPack")
local Terrain = Workspace.Terrain

-- Exposed as a function so it can be re-run. Rojo syncs this file to
-- ServerStorage.BuildWorld, so rebuilding the world is a command bar line:
--
--   local fresh = game.ServerStorage.BuildWorld:Clone()
--   fresh.Parent = game.ServerStorage
--   require(fresh)()
--   fresh:Destroy()
--
-- The clone matters: require() caches per ModuleScript INSTANCE, so after Rojo
-- updates this file a plain require() keeps handing back the stale function.
--
-- The body below is deliberately left at column 0. Indenting it by one level to
-- satisfy the wrapper would make every future diff unreadable.
return function()

local MAP_SIZE = 512
local SOIL_THICK = 30 -- terrain slab, top surface at y = 0

-- 7 x 72 = 504 against a 512 map, so the board IS the world with a hair of
-- margin. There is no surrounding countryside any more and no lake.
local GRID = 7
local TILE = 72
local BOARD = GRID * TILE

-- Row-major, row 1 at -Z. Fixed rather than shuffled so the map is a place you
-- can learn, and so the stone and ore tiles stay spread: the walk between nodes
-- is what gives the regen curve in ResourceService any teeth.
--   F forest/wood   P pasture/wool   G grain
--   H hills/stone   M mountains/ore  V village (spawn)
local LAYOUT = {
	"FPGHMFP",
	"GMHFPGH",
	"PFMGHMF",
	"HGPVFPG",
	"MHFPGHM",
	"FPGMHFP",
	"GMHFPGM",
}

-- Six materials, one per tile kind, because a tile you cannot identify from
-- ground level is just coloured floor.
local TILE_MATERIAL = {
	F = Enum.Material.Mud, -- forest floor
	P = Enum.Material.LeafyGrass, -- pasture
	G = Enum.Material.Ground, -- tilled earth
	H = Enum.Material.Rock,
	M = Enum.Material.Basalt, -- darker than the stone hills, on purpose
	V = Enum.Material.Cobblestone, -- the village
}

-- Which resource a tile grows, and therefore which node goes on it. The village
-- grows nothing; it is where you spawn and where the starter wall is.
local TILE_RESOURCE = {
	F = "Wood",
	P = "Wool",
	G = "Grain",
	H = "Stone",
	M = "Ore",
}

local rng = Random.new(20260903)

-- ---------------------------------------------------------------- tile helpers
local function tileKind(row: number, col: number): string
	return LAYOUT[row]:sub(col, col)
end

local function tileCentre(row: number, col: number): Vector2
	return Vector2.new((col - (GRID + 1) / 2) * TILE, (row - (GRID + 1) / 2) * TILE)
end

-- Corners are the lattice points between tiles; the interior ones are where four
-- tiles meet, which is where a castle can go.
local function cornerPoint(i: number, j: number): Vector2
	return Vector2.new((j - 1 - GRID / 2) * TILE, (i - 1 - GRID / 2) * TILE)
end

-- ---------------------------------------------------------------- teardown
for _, name in { "MedievalLand_Scenery", "MedievalLand_Board", "ResourceNodes", "BuildSites", "SpawnLocation", "Baseplate" } do
	local existing = Workspace:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
end
for _, toolName in { "Pickaxe", "Axe", "Hoe", "Shears" } do
	local old = StarterPack:FindFirstChild(toolName)
	if old then
		old:Destroy()
	end
end
Terrain:Clear()

-- ---------------------------------------------------------------- terrain
-- Flat. A board is flat; landscape relief would fight the grid and bury nodes.
Terrain:FillBlock(
	CFrame.new(0, -SOIL_THICK / 2, 0),
	Vector3.new(MAP_SIZE, SOIL_THICK, MAP_SIZE),
	Enum.Material.Ground
)

for row = 1, GRID do
	for col = 1, GRID do
		local centre = tileCentre(row, col)
		Terrain:FillBlock(
			CFrame.new(centre.X, -SOIL_THICK / 2, centre.Y),
			Vector3.new(TILE, SOIL_THICK, TILE),
			TILE_MATERIAL[tileKind(row, col)]
		)
	end
end

-- ---------------------------------------------------------------- ground probe
-- Nothing below may assume the ground is at y = 0; terrain smoothing lifts it.
-- Placing at a hardcoded height once buried a whole resource node inside a hill.
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { Terrain }

local function groundHeight(x: number, z: number): number
	local hit = Workspace:Raycast(Vector3.new(x, 220, z), Vector3.new(0, -440, 0), groundParams)
	return if hit then hit.Position.Y else 0
end

-- ---------------------------------------------------------------- board edges
local board = Instance.new("Folder")
board.Name = "MedievalLand_Board"
board.Parent = Workspace

local function kerb(name: string, centre: Vector3, size: Vector3)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = centre
	part.Anchored = true
	part.CanCollide = false -- you walk over tile lines, not into them
	part.Material = Enum.Material.Sandstone
	part.Color = Color3.fromRGB(206, 196, 172)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = board
end

for line = 1, GRID + 1 do
	local offset = (line - 1 - GRID / 2) * TILE
	local y = groundHeight(offset, 0) + 0.08
	kerb(("KerbZ%d"):format(line), Vector3.new(offset, y, 0), Vector3.new(1.1, 0.35, BOARD))
	kerb(("KerbX%d"):format(line), Vector3.new(0, y, offset), Vector3.new(BOARD, 0.35, 1.1))
end

-- ---------------------------------------------------------------- nodes
-- Geometry only. Capacity, regen and which tool works which node all live in
-- ResourceService; the builder just tags what a thing IS.
--
-- Two attributes carry that contract:
--   Resource  on the model  - what it yields
--   Wears     on a part     - it vanishes as the node is worked down
-- Parts without Wears are the permanent frame: trunks, legs, bare earth. That is
-- what stops a spent node looking like an empty patch of ground.
local nodes = Instance.new("Folder")
nodes.Name = "ResourceNodes"
nodes.Parent = Workspace

local function wearing(part: BasePart): BasePart
	part:SetAttribute("Wears", true)
	return part
end

local function newPart(name: string, size: Vector3, cframe: CFrame, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- --- forest ------------------------------------------------------
local LEAF_GREENS = {
	Color3.fromRGB(64, 116, 52),
	Color3.fromRGB(82, 134, 60),
	Color3.fromRGB(54, 100, 46),
}

local function makeForest(name: string, origin: Vector3): Model
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("Resource", "Wood")

	local trunkPrimary: Part? = nil
	for t = 1, 5 do
		local angle = (t / 5) * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
		local dist = if t == 1 then 0 else rng:NextNumber(9, 22)
		local x = origin.X + math.cos(angle) * dist
		local z = origin.Z + math.sin(angle) * dist
		local ground = groundHeight(x, z)
		local height = rng:NextNumber(9, 14)
		local radius = rng:NextNumber(0.7, 1.0)

		-- Trunks stay. A chopped-out forest should read as stumps and bare
		-- trunks, not as nothing at all.
		local trunk = newPart(
			("Trunk%d"):format(t),
			Vector3.new(height, radius * 2, radius * 2),
			CFrame.new(x, ground + height / 2, z) * CFrame.Angles(0, 0, math.rad(90)),
			model
		)
		trunk.Shape = Enum.PartType.Cylinder
		trunk.Material = Enum.Material.Wood
		trunk.Color = Color3.fromRGB(96, 68, 44)
		trunkPrimary = trunkPrimary or trunk

		local leafColor = LEAF_GREENS[rng:NextInteger(1, #LEAF_GREENS)]
		for c = 1, 3 do
			local size = rng:NextNumber(5.0, 7.5) - c * 0.7
			local canopy = wearing(newPart(
				("Canopy%d_%d"):format(t, c),
				Vector3.new(size, size * 0.8, size),
				CFrame.new(
					x + rng:NextNumber(-0.8, 0.8),
					ground + height * 0.72 + c * 1.7,
					z + rng:NextNumber(-0.8, 0.8)
				),
				model
			))
			canopy.Shape = Enum.PartType.Ball
			canopy.Material = Enum.Material.LeafyGrass
			canopy.Color = leafColor
		end
	end

	model.PrimaryPart = trunkPrimary
	model.Parent = nodes
	return model
end

-- --- pasture -----------------------------------------------------
local function makePasture(name: string, origin: Vector3): Model
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("Resource", "Wool")

	local primary: Part? = nil
	for s = 1, 4 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = if s == 1 then 0 else rng:NextNumber(7, 20)
		local x = origin.X + math.cos(angle) * dist
		local z = origin.Z + math.sin(angle) * dist
		local ground = groundHeight(x, z)
		local facing = rng:NextNumber(0, math.pi * 2)
		local base = CFrame.new(x, ground + 1.5, z) * CFrame.Angles(0, facing, 0)

		-- The sheep itself does not wear away, only its fleece. A shorn flock
		-- should still be a flock standing there looking indignant.
		local body = newPart(("Body%d"):format(s), Vector3.new(2.4, 1.7, 1.6), base, model)
		body.Shape = Enum.PartType.Ball
		body.Material = Enum.Material.Fabric
		body.Color = Color3.fromRGB(226, 216, 200)
		primary = primary or body

		local head = newPart(("Head%d"):format(s), Vector3.new(0.9, 0.9, 0.9), base * CFrame.new(0, 0.25, -1.2), model)
		head.Shape = Enum.PartType.Ball
		head.Material = Enum.Material.SmoothPlastic
		head.Color = Color3.fromRGB(58, 54, 52)

		for leg = 1, 4 do
			local lx = if leg % 2 == 0 then 0.7 else -0.7
			local lz = if leg <= 2 then 0.6 else -0.6
			local shin = newPart(
				("Leg%d_%d"):format(s, leg),
				Vector3.new(0.26, 1.5, 0.26),
				base * CFrame.new(lx, -1.2, lz),
				model
			)
			shin.Material = Enum.Material.SmoothPlastic
			shin.Color = Color3.fromRGB(58, 54, 52)
		end

		for f = 1, 4 do
			local size = rng:NextNumber(1.1, 1.6)
			local tuft = wearing(newPart(
				("Fleece%d_%d"):format(s, f),
				Vector3.new(size, size * 0.85, size),
				base * CFrame.new(rng:NextNumber(-0.8, 0.8), rng:NextNumber(0.6, 1.0), rng:NextNumber(-0.7, 0.7)),
				model
			))
			tuft.Shape = Enum.PartType.Ball
			tuft.Material = Enum.Material.Fabric
			tuft.Color = Color3.fromRGB(246, 242, 234)
		end
	end

	model.PrimaryPart = primary
	model.Parent = nodes
	return model
end

-- --- field -------------------------------------------------------
local function makeField(name: string, origin: Vector3): Model
	local model = Instance.new("Model")
	local ground = groundHeight(origin.X, origin.Z)
	model.Name = name
	model:SetAttribute("Resource", "Grain")

	-- The plot stays; the crop is what you harvest. A cut field is bare earth,
	-- which is exactly what it should look like.
	local plot = newPart(
		"Plot",
		Vector3.new(32, 0.5, 32),
		CFrame.new(origin.X, ground + 0.25, origin.Z),
		model
	)
	plot.Material = Enum.Material.Ground
	plot.Color = Color3.fromRGB(112, 88, 62)
	model.PrimaryPart = plot

	local rows = 5
	for r = 1, rows do
		for c = 1, rows do
			local x = origin.X + (c - (rows + 1) / 2) * 6.0
			local z = origin.Z + (r - (rows + 1) / 2) * 6.0
			local height = rng:NextNumber(2.6, 3.4)
			local stalk = wearing(newPart(
				("Wheat%d_%d"):format(r, c),
				Vector3.new(4.2, height, 4.2),
				CFrame.new(x, ground + 0.5 + height / 2, z)
					* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
				model
			))
			stalk.Material = Enum.Material.Grass
			stalk.Color = Color3.fromRGB(216, 182, 88)
		end
	end

	model.Parent = nodes
	return model
end

-- --- quarry and mine ---------------------------------------------
local function makeOutcrop(name: string, origin: Vector3, resource: string): Model
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("Resource", resource)

	local isOre = resource == "Ore"
	local groundY = groundHeight(origin.X, origin.Z)
	local coreCentre = groundY + 2.4

	local function stone(partName: string, size: Vector3, cframe: CFrame, wears: boolean): Part
		local part = newPart(partName, size, cframe, model)
		part.Material = Enum.Material.Rock
		-- One grey, jittered equally on all three channels so it stays neutral
		-- rather than drifting into a tint. Ore is darker, and its wearing
		-- chunks carry the rusty colour so a rich seam reads at a glance.
		local grey = if isOre then rng:NextInteger(74, 96) else rng:NextInteger(102, 134)
		part.Color = Color3.fromRGB(grey + 5, grey + 3, grey)
		if wears then
			wearing(part)
			if isOre then
				part.Material = Enum.Material.Metal
				part.Color = Color3.fromRGB(rng:NextInteger(132, 168), rng:NextInteger(92, 116), rng:NextInteger(56, 74))
			end
		end
		return part
	end

	-- No dominant centre block: one big box with smaller boxes tucked against it
	-- reads as a box. A cluster whose TOPS sit at different heights is what gives
	-- a rock its broken silhouette.
	local core = stone(
		"Core",
		Vector3.new(3.4, 4.6, 3.0),
		CFrame.new(origin.X, coreCentre, origin.Z) * CFrame.Angles(math.rad(5), math.rad(22), math.rad(-7)),
		false
	)
	model.PrimaryPart = core

	for i = 1, 8 do
		local width = rng:NextNumber(2.2, 3.6)
		local height = rng:NextNumber(2.4, 5.2)
		local angle = (i / 8) * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
		local dist = rng:NextNumber(1.7, 3.1)
		local baseY = groundY + rng:NextNumber(0, 1.1)
		stone(
			"Block" .. i,
			Vector3.new(width, height, width * rng:NextNumber(0.75, 1.2)),
			CFrame.new(
				origin.X + math.cos(angle) * dist,
				baseY + height / 2,
				origin.Z + math.sin(angle) * dist
			) * CFrame.Angles(rng:NextNumber(-0.22, 0.22), rng:NextNumber(0, 6.28), rng:NextNumber(-0.26, 0.26)),
			true
		)
	end

	for i = 1, 2 do
		local height = rng:NextNumber(3.0, 4.4)
		stone(
			"Shard" .. i,
			Vector3.new(rng:NextNumber(1.3, 2.0), height, rng:NextNumber(1.3, 2.0)),
			CFrame.new(
				origin.X + rng:NextNumber(-1.6, 1.6),
				coreCentre + 1.6 + height / 2,
				origin.Z + rng:NextNumber(-1.6, 1.6)
			) * CFrame.Angles(rng:NextNumber(-0.28, 0.28), rng:NextNumber(0, 6.28), rng:NextNumber(-0.28, 0.28)),
			true
		)
	end

	-- Rubble stays: it is what makes the outcrop sit in the ground rather than
	-- on it, and it should survive the seam being worked out.
	for i = 1, 6 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(3.2, 6.0)
		local size = rng:NextNumber(0.7, 1.9)
		stone(
			"Rubble" .. i,
			Vector3.new(size, size * rng:NextNumber(0.5, 0.9), size * rng:NextNumber(0.7, 1.2)),
			CFrame.new(origin.X + math.cos(angle) * dist, groundY + 0.25, origin.Z + math.sin(angle) * dist)
				* CFrame.Angles(rng:NextNumber(-0.4, 0.4), rng:NextNumber(0, 6.28), rng:NextNumber(-0.4, 0.4)),
			false
		)
	end

	model.Parent = nodes
	return model
end

-- One node per resource tile, at the tile's centre. A tile IS its node.
local nodeCount = 0
for row = 1, GRID do
	for col = 1, GRID do
		local kind = tileKind(row, col)
		local resource = TILE_RESOURCE[kind]
		if resource then
			nodeCount += 1
			local centre = tileCentre(row, col)
			local origin = Vector3.new(centre.X, 0, centre.Y)
			local name = ("%s_%02d"):format(resource, nodeCount)

			if resource == "Wood" then
				makeForest(name, origin)
			elseif resource == "Wool" then
				makePasture(name, origin)
			elseif resource == "Grain" then
				makeField(name, origin)
			else
				makeOutcrop(name, origin, resource)
			end
		end
	end
end

-- ---------------------------------------------------------------- village
local villageGround = groundHeight(0, 0)

local spawnPad = Instance.new("SpawnLocation")
spawnPad.Name = "SpawnLocation"
spawnPad.Size = Vector3.new(14, 1, 14)
spawnPad.Position = Vector3.new(0, villageGround + 0.5, 0)
spawnPad.Anchored = true
spawnPad.Material = Enum.Material.Sandstone
spawnPad.Color = Color3.fromRGB(196, 174, 138)
-- Spawn protection. It was 0 while nothing could hurt you; from Tier 4 there is
-- combat, and a forcefield-free spawn pad is a place to be farmed on respawn.
spawnPad.Duration = 8
spawnPad.Parent = Workspace

-- ---------------------------------------------------------------- build sites
local buildSites = Instance.new("Folder")
buildSites.Name = "BuildSites"
buildSites.Parent = Workspace

local function makeSite(name: string, kind: string, position: Vector3, footprint: Vector3)
	local site = Instance.new("Model")
	site.Name = name
	site:SetAttribute("Kind", kind)

	local foundation = Instance.new("Part")
	foundation.Name = "Foundation"
	foundation.Size = footprint
	foundation.Position = position
	foundation.Anchored = true
	foundation.Material = Enum.Material.Sandstone
	foundation.Color = Color3.fromRGB(168, 152, 126)
	foundation.TopSurface = Enum.SurfaceType.Smooth
	foundation.BottomSurface = Enum.SurfaceType.Smooth
	foundation.Parent = site

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BuildPrompt"
	prompt.ActionText = "Build"
	prompt.ObjectText = kind
	prompt.HoldDuration = 0.35
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = foundation

	local sections = Instance.new("Folder")
	sections.Name = "Sections"
	sections.Parent = site

	site.PrimaryPart = foundation
	site.Parent = buildSites
	return site
end

-- The starter wall, on the village tile. Left unowned by ResourceService on
-- purpose: it is the shared sink the loop is learned on.
makeSite("WallSite", "Wall", Vector3.new(0, villageGround + 0.5, 26), Vector3.new(34, 1, 3.4))

-- A castle plot on every interior tile corner, minus the ring around the
-- village so spawn does not open onto somebody's keep.
local plotCount = 0
for i = 2, GRID do
	for j = 2, GRID do
		local point = cornerPoint(i, j)
		if point.Magnitude > TILE * 0.9 then
			plotCount += 1
			makeSite(
				("CastlePlot_%02d"):format(plotCount),
				"Castle",
				Vector3.new(point.X, groundHeight(point.X, point.Y) + 0.5, point.Y),
				Vector3.new(11, 1, 11)
			)
		end
	end
end

-- ---------------------------------------------------------------- tools
-- Four tools, one shaft. Only the head differs, so the haft, grip, hold pose and
-- off-hand attachment are written once.
--
-- The shaft runs along the Handle's local Z with the head at -Z. The Handle is a
-- plain unrotated invisible block and the visible shaft is welded over it,
-- because Tool.Grip is expressed in the Handle's own frame: rotating the Handle
-- to lay a cylinder along Z would twist every Grip value with it.
local WOOD = Color3.fromRGB(122, 84, 50)
local IRON = Color3.fromRGB(96, 100, 107)
local IRON_DARK = Color3.fromRGB(72, 76, 83)

local function buildTool(
	name: string,
	tooltip: string,
	shaftLength: number,
	head: (headAt: CFrame, add: (string, Vector3, CFrame, Color3) -> Part) -> ()
): Tool
	local tool = Instance.new("Tool")
	tool.Name = name
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = tooltip

	-- Held upright, like a torch. Tool.Grip is the INVERSE of where the Handle
	-- sits in the hand, so the readable way to write it is to describe the pose
	-- and invert. The hand's frame is +Y up and -Z forward; rotating +90 about X
	-- carries the handle's -Z onto the hand's +Y, standing the head up. The lift
	-- puts the grip point back in the palm after the rotation drops it.
	local holdAt = shaftLength * 0.35
	tool.Grip = (CFrame.new(0, holdAt, 0) * CFrame.Angles(math.rad(90), 0, 0)):Inverse()

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.30, 0.30, shaftLength)
	handle.CFrame = CFrame.new()
	handle.Transparency = 1
	handle.Anchored = false
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool

	local function attach(part: BasePart, localCFrame: CFrame)
		part.CFrame = localCFrame
		part.Anchored = false
		part.CanCollide = false
		part.Massless = true
		-- Explicit Weld, not WeldConstraint: a WeldConstraint only captures its
		-- offset once both parts are live in the world, and this tool is built
		-- straight into StarterPack.
		local weld = Instance.new("Weld")
		weld.Part0 = handle
		weld.Part1 = part
		weld.C0 = handle.CFrame:Inverse() * part.CFrame
		weld.C1 = CFrame.new()
		weld.Parent = handle
		part.Parent = tool
	end

	local function add(partName: string, size: Vector3, localCFrame: CFrame, color: Color3): Part
		local part = Instance.new("Part")
		part.Name = partName
		part.Size = size
		part.Material = Enum.Material.Metal
		part.Color = color
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		attach(part, localCFrame)
		return part
	end

	-- Cylinder parts run along their X axis, so a 90 degree yaw lays the shaft
	-- down the handle's Z.
	local shaft = Instance.new("Part")
	shaft.Name = "Shaft"
	shaft.Shape = Enum.PartType.Cylinder
	shaft.Size = Vector3.new(shaftLength, 0.33, 0.33)
	shaft.Material = Enum.Material.Wood
	shaft.Color = WOOD
	attach(shaft, CFrame.Angles(0, math.rad(90), 0))

	local grip = Instance.new("Part")
	grip.Name = "GripWrap"
	grip.Shape = Enum.PartType.Cylinder
	grip.Size = Vector3.new(math.min(1.1, shaftLength * 0.3), 0.42, 0.42)
	grip.Material = Enum.Material.Fabric
	grip.Color = Color3.fromRGB(64, 48, 36)
	attach(grip, CFrame.new(0, 0, holdAt) * CFrame.Angles(0, math.rad(90), 0))

	head(CFrame.new(0, 0, -shaftLength / 2 + 0.23), add)

	-- Where the off hand goes: further up the shaft than the gripping hand, the
	-- way you would actually hold a long tool. ResourceService points an
	-- IKControl at this during a swing, which is what makes it two-handed.
	local leftGrip = Instance.new("Attachment")
	leftGrip.Name = "LeftGrip"
	leftGrip.CFrame = CFrame.new(0, 0, holdAt - 0.55)
	leftGrip.Parent = handle

	tool.Parent = StarterPack
	return tool
end

-- Pickaxe: both arms of the head sweep BACK toward the user in a curve and taper
-- to a point. Each arm is five short segments, each rotated a little further.
buildTool("Pickaxe", "Stone and ore", 3.9, function(headAt, add)
	local SEGMENTS, SEG_LENGTH, SEG_CURVE = 5, 0.42, math.rad(13)
	for _, side in { 1, -1 } do
		local cursor = headAt * CFrame.Angles(0, 0, if side == 1 then 0 else math.pi) * CFrame.new(0, 0.16, 0)
		for seg = 1, SEGMENTS do
			cursor = cursor * CFrame.Angles(SEG_CURVE, 0, 0)
			local taper = 1 - (seg - 1) / SEGMENTS
			add(
				("Head%s%d"):format(if side == 1 then "Up" else "Down", seg),
				Vector3.new(0.10 + 0.20 * taper, SEG_LENGTH + 0.06, 0.20 + 0.26 * taper),
				cursor * CFrame.new(0, SEG_LENGTH / 2, 0),
				IRON
			)
			cursor = cursor * CFrame.new(0, SEG_LENGTH, 0)
		end
		add(("Tip%s"):format(if side == 1 then "Up" else "Down"), Vector3.new(0.09, 0.28, 0.11), cursor * CFrame.new(0, 0.12, 0), IRON_DARK)
	end
	add("Eye", Vector3.new(0.52, 0.62, 0.62), headAt, IRON_DARK)
end)

-- Axe: a bit flaring out to one side, widening toward the edge.
buildTool("Axe", "Chop trees for wood", 3.6, function(headAt, add)
	add("Eye", Vector3.new(0.50, 0.70, 0.50), headAt, IRON_DARK)
	add("BitInner", Vector3.new(0.30, 0.85, 0.80), headAt * CFrame.new(0, 0.62, 0), IRON)
	add("BitOuter", Vector3.new(0.24, 0.80, 1.35), headAt * CFrame.new(0, 1.20, 0), IRON)
	add("Edge", Vector3.new(0.10, 0.46, 1.55), headAt * CFrame.new(0, 1.66, 0), Color3.fromRGB(186, 190, 196))
	add("Poll", Vector3.new(0.34, 0.55, 0.50), headAt * CFrame.new(0, -0.52, 0), IRON_DARK)
end)

-- Hoe: a flat plate set across the haft, angled the way a hoe actually sits.
buildTool("Hoe", "Harvest grain", 4.1, function(headAt, add)
	add("Neck", Vector3.new(0.26, 0.70, 0.26), headAt * CFrame.new(0, 0.30, 0), IRON_DARK)
	add(
		"Blade",
		Vector3.new(1.70, 0.18, 1.05),
		headAt * CFrame.new(0, 0.72, -0.42) * CFrame.Angles(math.rad(-28), 0, 0),
		IRON
	)
	add(
		"BladeEdge",
		Vector3.new(1.70, 0.10, 0.30),
		headAt * CFrame.new(0, 0.62, -0.92) * CFrame.Angles(math.rad(-28), 0, 0),
		Color3.fromRGB(186, 190, 196)
	)
end)

-- Shears: two blades crossing at a pivot. Short, because they are held not swung
-- from the shoulder - though the swing animation does not know that yet.
buildTool("Shears", "Shear sheep for wool", 2.2, function(headAt, add)
	add("Pivot", Vector3.new(0.34, 0.34, 0.34), headAt, IRON_DARK)
	for _, side in { 1, -1 } do
		local lean = math.rad(9) * side
		add(
			("Blade%s"):format(if side == 1 then "A" else "B"),
			Vector3.new(0.12, 1.45, 0.34),
			headAt * CFrame.Angles(0, 0, lean) * CFrame.new(0.10 * side, 0.80, 0),
			Color3.fromRGB(190, 194, 200)
		)
		add(
			("Bow%s"):format(if side == 1 then "A" else "B"),
			Vector3.new(0.12, 0.75, 0.28),
			headAt * CFrame.Angles(0, 0, -lean) * CFrame.new(0.16 * side, -0.55, 0),
			IRON
		)
	end
end)

-- ---------------------------------------------------------------- lighting
-- Lighting.Technology is not scriptable from a normal script and the MCP cannot
-- write it either. If the place looks flat, set it by hand in
-- Properties -> Lighting -> Technology -> Future.
pcall(function()
	Lighting.Technology = Enum.Technology.Future
end)

Lighting.ClockTime = 14.6
Lighting.Brightness = 3
Lighting.GlobalShadows = true
Lighting.Ambient = Color3.fromRGB(72, 70, 62)
Lighting.OutdoorAmbient = Color3.fromRGB(140, 136, 118)
Lighting.EnvironmentDiffuseScale = 0.5
Lighting.EnvironmentSpecularScale = 0.5
Lighting.ExposureCompensation = 0.1

for _, className in { "Atmosphere", "SunRaysEffect", "ColorCorrectionEffect", "BloomEffect" } do
	local existing = Lighting:FindFirstChildOfClass(className)
	if existing then
		existing:Destroy()
	end
end

local atmosphere = Instance.new("Atmosphere")
atmosphere.Density = 0.28
atmosphere.Offset = 0.15
atmosphere.Haze = 0.9
atmosphere.Glare = 0.35
atmosphere.Color = Color3.fromRGB(224, 220, 200)
atmosphere.Decay = Color3.fromRGB(126, 152, 178)
atmosphere.Parent = Lighting

local sunRays = Instance.new("SunRaysEffect")
sunRays.Intensity = 0.09
sunRays.Spread = 0.5
sunRays.Parent = Lighting

local colorCorrection = Instance.new("ColorCorrectionEffect")
colorCorrection.Brightness = 0.02
colorCorrection.Contrast = 0.08
colorCorrection.Saturation = 0.06
colorCorrection.TintColor = Color3.fromRGB(255, 249, 238)
colorCorrection.Parent = Lighting

local bloom = Instance.new("BloomEffect")
bloom.Intensity = 0.35
bloom.Size = 20
bloom.Threshold = 1.6
bloom.Parent = Lighting

print(("[Medieval Land] Board: %dx%d tiles, %d nodes, %d castle plots, 4 tools."):format(
	GRID, GRID, nodeCount, plotCount
))

end
