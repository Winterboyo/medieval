--!strict
-- Medieval Land - world builder. A Catan board filling the whole map: a 7x7 grid
-- of square resource tiles, a village at the centre, castle plots on the tile
-- corners. One-shot setup. Safe to re-run: it tears down what it built first.

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local StarterPack = game:GetService("StarterPack")
local ServerStorage = game:GetService("ServerStorage")
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

local MAP_SIZE = 1440
local SOIL_THICK = 30 -- terrain slab, top surface at y = 0

-- 7 x 200 = 1400 against a 1440 map, so the board IS the world with a hair of
-- margin. There is no surrounding countryside any more and no lake.
--
-- The tiles have grown twice: 72 to 160 to 200. The last step is not about the
-- tiles at all, it is about what sits on their corners. Villages are now built
-- room by room and you walk INSIDE the buildings, so a plot is 148 studs across;
-- at a 160 tile the neighbouring plots very nearly touched.
local GRID = 7
local TILE = 200
local BOARD = GRID * TILE

-- Row-major, row 1 at -Z. Fixed rather than shuffled so the map is a place you
-- can learn, and so the stone and ore tiles stay spread: the walk between nodes
-- is what gives the regen curve in ResourceService any teeth.
--   F forest/wood   P pasture/wool   G grain
--   H hills/stone   M mountains/ore  V the totem plaza at the centre
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
	V = Enum.Material.Cobblestone, -- the totem plaza
}

-- Which resource a tile grows, and therefore which node goes on it. The centre
-- tile grows nothing; it is the totem plaza.
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
for _, name in { "MedievalLand_Scenery", "MedievalLand_Board", "ResourceNodes", "BuildSites", "VillageSquare", "SpawnLocation", "Baseplate" } do
	local existing = Workspace:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
end
-- Older worlds put a bare SpawnLocation at the origin. Sweep any survivor by
-- class as well as by name, or the engine keeps spawning people on a pad that
-- is no longer part of the map.
for _, thing in Workspace:GetDescendants() do
	if thing:IsA("SpawnLocation") then
		thing:Destroy()
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

-- ---------------------------------------------------------------- tile seams
-- The tiles used to be separated by sandstone kerbs, which made the board read
-- as a diagram rather than a place. The grid still has to be legible - you
-- should always know which tile you are standing on, because that is what tells
-- you what grows here - but the seam between two tiles should look like ground
-- meeting ground.
--
-- So each interior border is broken up with overlapping patches of BOTH
-- neighbours' materials, thrown to alternating sides of the line. The two
-- materials bite into each other and the boundary comes out ragged instead of
-- ruled. Patches are square and randomly turned rather than round: a filled
-- ball would have to be sunk so deep to avoid doming above the surface that it
-- would barely tint the ground you actually walk on.
local board = Instance.new("Folder")
board.Name = "MedievalLand_Board"
board.Parent = Workspace

local SEAM_PATCHES = 8

local function blendSeam(from: Vector2, to: Vector2, matA: Enum.Material, matB: Enum.Material)
	local along = to - from
	local length = along.Magnitude
	local dir = along.Unit
	local perp = Vector2.new(-dir.Y, dir.X)

	for i = 1, SEAM_PATCHES do
		local t = ((i - 0.5) / SEAM_PATCHES + rng:NextNumber(-0.05, 0.05)) * length
		local side = if i % 2 == 0 then 1 else -1
		local spill = rng:NextNumber(3, 13)
		local at = from + dir * t + perp * (side * spill)
		local size = rng:NextNumber(16, 34)
		Terrain:FillBlock(
			CFrame.new(at.X, -SOIL_THICK / 2, at.Y) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
			Vector3.new(size, SOIL_THICK, size),
			if side > 0 then matA else matB
		)
	end
end

for row = 1, GRID do
	for col = 1, GRID do
		local here = TILE_MATERIAL[tileKind(row, col)]
		local centre = tileCentre(row, col)
		local half = TILE / 2
		-- Only the +X and +Z borders, so every seam is walked exactly once.
		if col < GRID then
			blendSeam(
				Vector2.new(centre.X + half, centre.Y - half),
				Vector2.new(centre.X + half, centre.Y + half),
				here, TILE_MATERIAL[tileKind(row, col + 1)]
			)
		end
		if row < GRID then
			blendSeam(
				Vector2.new(centre.X - half, centre.Y + half),
				Vector2.new(centre.X + half, centre.Y + half),
				here, TILE_MATERIAL[tileKind(row + 1, col)]
			)
		end
	end
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

	-- Eight trees spread over most of the tile. On a 160 stud tile the old five
	-- at a 22 stud radius sat in the middle like a potted plant.
	local trunkPrimary: Part? = nil
	for t = 1, 8 do
		local angle = (t / 8) * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
		local dist = if t == 1 then 0 else rng:NextNumber(16, 56)
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
	for s = 1, 6 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = if s == 1 then 0 else rng:NextNumber(14, 50)
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
		Vector3.new(62, 0.5, 62),
		CFrame.new(origin.X, ground + 0.25, origin.Z),
		model
	)
	plot.Material = Enum.Material.Ground
	plot.Color = Color3.fromRGB(112, 88, 62)
	model.PrimaryPart = plot

	-- Clumps deliberately WIDER than their spacing, so they overlap into a
	-- continuous crop. Spaced apart they read as a tray of yellow cubes, which
	-- is the one look this whole map is trying not to have.
	local rows = 7
	for r = 1, rows do
		for c = 1, rows do
			local x = origin.X + (c - (rows + 1) / 2) * 8.2 + rng:NextNumber(-1.1, 1.1)
			local z = origin.Z + (r - (rows + 1) / 2) * 8.2 + rng:NextNumber(-1.1, 1.1)
			local height = rng:NextNumber(2.6, 3.4)
			local stalk = wearing(newPart(
				("Wheat%d_%d"):format(r, c),
				Vector3.new(10.4, height, 10.4),
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
-- A hill tile is a RANGE now, not a boulder: three outcrops spread across the
-- tile rather than one lump at the centre. At 160 studs a single rock left the
-- rest of the tile as empty floor, and made a stone tile something you stood on
-- top of instead of somewhere you walked into.
local function makeOutcrop(name: string, origin: Vector3, resource: string): Model
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("Resource", resource)

	local isOre = resource == "Ore"

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

	-- One outcrop of the range. Scale varies per outcrop so the three do not
	-- read as the same rock stamped out three times.
	local function outcrop(tag: string, at: Vector2, scale: number): Part
		local groundY = groundHeight(at.X, at.Y)
		local coreCentre = groundY + 2.4 * scale

		-- No dominant centre block: one big box with smaller boxes tucked
		-- against it reads as a box. A cluster whose TOPS sit at different
		-- heights is what gives a rock its broken silhouette.
		local core = stone(
			tag .. "Core",
			Vector3.new(3.4, 4.6, 3.0) * scale,
			CFrame.new(at.X, coreCentre, at.Y) * CFrame.Angles(math.rad(5), math.rad(22), math.rad(-7)),
			false
		)

		for i = 1, 6 do
			local width = rng:NextNumber(2.2, 3.6) * scale
			local height = rng:NextNumber(2.4, 5.2) * scale
			local angle = (i / 6) * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
			local dist = rng:NextNumber(1.7, 3.1) * scale
			local baseY = groundY + rng:NextNumber(0, 1.1)
			stone(
				("%sBlock%d"):format(tag, i),
				Vector3.new(width, height, width * rng:NextNumber(0.75, 1.2)),
				CFrame.new(
					at.X + math.cos(angle) * dist,
					baseY + height / 2,
					at.Y + math.sin(angle) * dist
				) * CFrame.Angles(rng:NextNumber(-0.22, 0.22), rng:NextNumber(0, 6.28), rng:NextNumber(-0.26, 0.26)),
				true
			)
		end

		for i = 1, 2 do
			local height = rng:NextNumber(3.0, 4.4) * scale
			stone(
				("%sShard%d"):format(tag, i),
				Vector3.new(rng:NextNumber(1.3, 2.0) * scale, height, rng:NextNumber(1.3, 2.0) * scale),
				CFrame.new(
					at.X + rng:NextNumber(-1.6, 1.6),
					coreCentre + 1.6 * scale + height / 2,
					at.Y + rng:NextNumber(-1.6, 1.6)
				) * CFrame.Angles(rng:NextNumber(-0.28, 0.28), rng:NextNumber(0, 6.28), rng:NextNumber(-0.28, 0.28)),
				true
			)
		end

		-- Rubble stays: it is what makes the outcrop sit IN the ground rather
		-- than on it, and it should survive the seam being worked out.
		for i = 1, 4 do
			local angle = rng:NextNumber(0, math.pi * 2)
			local dist = rng:NextNumber(3.2, 6.0) * scale
			local size = rng:NextNumber(0.7, 1.9) * scale
			stone(
				("%sRubble%d"):format(tag, i),
				Vector3.new(size, size * rng:NextNumber(0.5, 0.9), size * rng:NextNumber(0.7, 1.2)),
				CFrame.new(at.X + math.cos(angle) * dist, groundY + 0.25, at.Y + math.sin(angle) * dist)
					* CFrame.Angles(rng:NextNumber(-0.4, 0.4), rng:NextNumber(0, 6.28), rng:NextNumber(-0.4, 0.4)),
				false
			)
		end

		return core
	end

	-- Three outcrops on a wide triangle, jittered, so the range has no obvious
	-- centre to stand in the middle of.
	local spin = rng:NextNumber(0, math.pi * 2)
	for i = 0, 2 do
		local angle = spin + (i / 3) * math.pi * 2
		local dist = rng:NextNumber(24, 42)
		local at = Vector2.new(origin.X + math.cos(angle) * dist, origin.Z + math.sin(angle) * dist)
		local core = outcrop(("Rock%d"):format(i + 1), at, rng:NextNumber(1.15, 1.75))
		model.PrimaryPart = model.PrimaryPart or core
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

-- ---------------------------------------------------------------- totem
-- The centre used to be a bare sandstone spawn pad. It is now a totem: a
-- landmark tall enough to navigate by from most of the board, standing on the
-- one point the closing zone converges toward.
--
-- Spawning did not disappear with the pad, it moved OFF the centre - eight
-- small pads ringing the plaza. The engine picks between them, which spreads
-- arrivals out instead of stacking twelve players on one square, and it keeps
-- the fallback ResourceService leans on when a knocked-down player has no keep
-- left to return to.
local square = Instance.new("Folder")
square.Name = "VillageSquare"
square.Parent = Workspace

local plazaGround = groundHeight(0, 0)

local function plazaPart(name: string, size: Vector3, cframe: CFrame,
	material: Enum.Material, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.Material = material
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = square
	return part
end

local function drum(name: string, radius: number, height: number, atY: number,
	material: Enum.Material, color: Color3, yaw: number): Part
	-- A Cylinder part runs along its own X, so the length goes in Size.X and the
	-- part is stood upright by rolling 90 degrees about Z.
	local part = plazaPart(name, Vector3.new(height, radius * 2, radius * 2),
		CFrame.new(0, plazaGround + atY + height / 2, 0)
			* CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, 0, math.rad(90)),
		material, color)
	part.Shape = Enum.PartType.Cylinder
	return part
end

plazaPart("TotemStep", Vector3.new(26, 1.2, 26),
	CFrame.new(0, plazaGround + 0.6, 0) * CFrame.Angles(0, math.rad(45), 0),
	Enum.Material.Cobblestone, Color3.fromRGB(150, 144, 132))

drum("TotemPlinth", 4.2, 2.0, 1.2, Enum.Material.Slate, Color3.fromRGB(104, 100, 96), 0)

-- The shaft: carved sections separated by proud collars, each section turned a
-- little off the last so the stack reads as carved rather than extruded. Tall
-- and NARROW is the whole point - at five studs across it was a barrel, and a
-- landmark you are meant to navigate by has to be legible as a shape from a
-- long way off, not just tall.
local TOTEM_SECTIONS = {
	{ radius = 2.7, height = 5.4, color = Color3.fromRGB(96, 66, 42) },
	{ radius = 2.5, height = 4.8, color = Color3.fromRGB(78, 54, 36) },
	{ radius = 2.6, height = 5.2, color = Color3.fromRGB(112, 78, 46) },
	{ radius = 2.3, height = 4.6, color = Color3.fromRGB(88, 60, 40) },
	{ radius = 2.1, height = 4.2, color = Color3.fromRGB(96, 66, 42) },
}
local bandY = 3.2
for i, band in TOTEM_SECTIONS do
	drum(("TotemBand%d"):format(i), band.radius, band.height, bandY,
		Enum.Material.Wood, band.color, rng:NextNumber(0, 6.28))
	bandY += band.height
	if i < #TOTEM_SECTIONS then
		drum(("TotemCollar%d"):format(i), band.radius + 0.9, 0.8, bandY,
			Enum.Material.Wood, Color3.fromRGB(150, 122, 70), rng:NextNumber(0, 6.28))
		bandY += 0.8
	end
end

-- Crossbeam near the top, so the silhouette is not just a post.
plazaPart("TotemArms", Vector3.new(13, 1.0, 1.4),
	CFrame.new(0, plazaGround + bandY - 3.0, 0) * CFrame.Angles(0, math.rad(28), 0),
	Enum.Material.Wood, Color3.fromRGB(78, 54, 36))
for _, sx in { -1, 1 } do
	plazaPart("TotemPennant", Vector3.new(0.3, 2.6, 1.8),
		CFrame.new(sx * 5.6, plazaGround + bandY - 4.5, 0) * CFrame.Angles(0, math.rad(28), 0),
		Enum.Material.Fabric, Color3.fromRGB(148, 62, 54))
end

drum("TotemCap", 3.0, 1.2, bandY, Enum.Material.Slate, Color3.fromRGB(84, 78, 76), 0)

-- A lit crown. The totem has to be findable at dusk as well as at noon, and
-- this is the one thing on the board allowed to glow.
local beacon = plazaPart("TotemBeacon", Vector3.new(3.6, 3.6, 3.6),
	CFrame.new(0, plazaGround + bandY + 3.4, 0) * CFrame.Angles(math.rad(45), 0, math.rad(45)),
	Enum.Material.Neon, Color3.fromRGB(238, 196, 108))
local glow = Instance.new("PointLight")
glow.Brightness = 2.4
glow.Range = 46
glow.Color = Color3.fromRGB(255, 214, 140)
glow.Parent = beacon

-- Standing stones around the plaza, which give the square an edge without
-- walling it in.
for i = 1, 8 do
	local angle = (i / 8) * math.pi * 2
	local x, z = math.cos(angle) * 25, math.sin(angle) * 25
	local height = rng:NextNumber(8.5, 12.0)
	plazaPart(("StandingStone%d"):format(i), Vector3.new(2.8, height, 1.9),
		CFrame.new(x, groundHeight(x, z) + height / 2, z)
			* CFrame.Angles(rng:NextNumber(-0.05, 0.05), -angle, rng:NextNumber(-0.06, 0.06)),
		Enum.Material.Rock, Color3.fromRGB(120, 116, 110))
end

-- The spawn ring. Small and flush with the ground: these are where you arrive,
-- not something to look at.
for i = 1, 8 do
	local angle = (i / 8) * math.pi * 2 + math.pi / 8
	local x, z = math.cos(angle) * 34, math.sin(angle) * 34
	local pad = Instance.new("SpawnLocation")
	pad.Name = ("SpawnPad%d"):format(i)
	-- Flush and the same stone as the plaza. Raised pads read as slabs somebody
	-- dropped on the grass; these are meant to be paving you arrive on and then
	-- stop noticing.
	pad.Size = Vector3.new(7, 0.5, 7)
	pad.CFrame = CFrame.new(x, groundHeight(x, z) + 0.25, z) * CFrame.Angles(0, -angle, 0)
	pad.Anchored = true
	pad.Neutral = true
	pad.Material = Enum.Material.Cobblestone
	pad.Color = Color3.fromRGB(150, 144, 132)
	pad.TopSurface = Enum.SurfaceType.Smooth
	-- Spawn protection. It was 0 while nothing could hurt you; from Tier 4 there
	-- is combat, and a forcefield-free pad is a place to be farmed on respawn.
	pad.Duration = 8
	pad.Parent = square
end

-- ---------------------------------------------------------------- bases
-- A claimable plot starts EMPTY: bare ground, a claim stone and a build prompt.
-- Everything above that is bought one stage at a time and appears when it is
-- paid for - four villager houses, then the three specialist workshops, then the
-- keep, then the wall. Ten purchases from empty field to fortified village.
--
-- The geometry for every stage is built HERE, at world-build time, into
--   ServerStorage.VillageBlueprints.<site>.Stage<n>
-- and ResourceService reparents a stage's parts into the site when someone buys
-- it. All the building code stays in this file: the service never has to know
-- how a house is made, only how to move a folder. Blueprint parts are already
-- positioned in world space, so installing a stage is a reparent and nothing
-- else - no repositioning, no physics, no duplicated geometry code.
--
-- Buildings are sized off the CHARACTER, not off the map. A Roblox humanoid is
-- about 5 studs tall and 2 wide, so these get 9 stud walls, 7 stud doorways and
-- hollow interiors: somewhere you walk in and stand up, rather than a solid
-- block with a door painted on the front.
local buildSites = Instance.new("Folder")
buildSites.Name = "BuildSites"
buildSites.Parent = Workspace

local oldBlueprints = ServerStorage:FindFirstChild("VillageBlueprints")
if oldBlueprints then
	oldBlueprints:Destroy()
end
local blueprints = Instance.new("Folder")
blueprints.Name = "VillageBlueprints"
blueprints.Parent = ServerStorage

local PLOT = 148 -- village footprint
local WALL_HALF = 70 -- wall ring sits at +/- this
local WALL_BLOCK = Vector3.new(20.4, 11, 3.6)
local WALL_SPAN = 20 -- centre-to-centre along a side
local RING_STEPS = 7 -- blocks per side

local DAUB = Color3.fromRGB(214, 204, 182)
local TIMBER = Color3.fromRGB(74, 52, 34)
local THATCH = Color3.fromRGB(146, 118, 68)
local TILED = Color3.fromRGB(112, 62, 48)
local STONEWORK = Color3.fromRGB(132, 126, 116)

local function sitePart(parent: Instance, name: string, size: Vector3, cframe: CFrame,
	material: Enum.Material, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.Material = material
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function siteDrum(parent: Instance, name: string, radius: number, height: number,
	at: CFrame, material: Enum.Material, color: Color3): Part
	local part = sitePart(parent, name, Vector3.new(height, radius * 2, radius * 2),
		at * CFrame.new(0, height / 2, 0) * CFrame.Angles(0, 0, math.rad(90)), material, color)
	part.Shape = Enum.PartType.Cylinder
	return part
end

-- A gable roof from two wedges meeting at a ridge. A WedgePart is tall at its
-- +Z face and tapers to nothing at -Z - measured in Studio, not assumed - so
-- each half is turned to aim its tall side at the ridge line.
local function gable(parent: Instance, eaves: CFrame, width: number, depth: number,
	height: number, color: Color3)
	-- A ridge beam along the apex. The two halves meet on an exact plane, and a
	-- ray cast straight up from inside slips between them - measured: 5 of 25
	-- interior points saw open sky, all of them on the x = 0 line. The beam
	-- covers the seam, and a roof with a ridge looks more like a roof anyway.
	local ridge = Instance.new("Part")
	ridge.Name = "Ridge"
	ridge.Size = Vector3.new(1.3, 1.0, depth)
	ridge.CFrame = eaves * CFrame.new(0, height - 0.3, 0)
	ridge.Anchored = true
	ridge.Material = Enum.Material.Wood
	ridge.Color = Color3.fromRGB(74, 52, 34)
	ridge.TopSurface = Enum.SurfaceType.Smooth
	ridge.BottomSurface = Enum.SurfaceType.Smooth
	ridge.Parent = parent

	for _, side in { 1, -1 } do
		local half = Instance.new("WedgePart")
		half.Name = "RoofHalf"
		half.Size = Vector3.new(depth, height, width / 2)
		half.CFrame = eaves
			* CFrame.new(-side * width / 4, height / 2, 0)
			* CFrame.Angles(0, math.rad(90) * side, 0)
		half.Anchored = true
		half.Material = Enum.Material.Slate
		half.Color = color
		half.TopSurface = Enum.SurfaceType.Smooth
		half.BottomSurface = Enum.SurfaceType.Smooth
		half.Parent = parent
	end
end

-- A building you can actually walk into: floor, four walls, a doorway gap in the
-- +Z face with a lintel over it, and a pitched roof. Everything here is driven
-- off the doorway, because the doorway is the part that has to fit a person.
local WALL_THICK = 1.0
local DOOR_HEIGHT = 7

local function hollowBuilding(into: Instance, at: CFrame, width: number, depth: number,
	wallHeight: number, doorWidth: number, wallColor: Color3, roofColor: Color3,
	wallMaterial: Enum.Material)
	sitePart(into, "Floor", Vector3.new(width, 0.6, depth), at * CFrame.new(0, 0.3, 0),
		Enum.Material.WoodPlanks, Color3.fromRGB(126, 96, 62))

	sitePart(into, "WallBack", Vector3.new(width, wallHeight, WALL_THICK),
		at * CFrame.new(0, wallHeight / 2, -depth / 2 + WALL_THICK / 2), wallMaterial, wallColor)
	for _, sx in { -1, 1 } do
		sitePart(into, "WallSide", Vector3.new(WALL_THICK, wallHeight, depth),
			at * CFrame.new(sx * (width / 2 - WALL_THICK / 2), wallHeight / 2, 0),
			wallMaterial, wallColor)
	end

	-- The front, split around the doorway, with a lintel bridging the gap.
	local cheek = (width - doorWidth) / 2
	for _, sx in { -1, 1 } do
		sitePart(into, "WallFront", Vector3.new(cheek, wallHeight, WALL_THICK),
			at * CFrame.new(sx * (doorWidth + cheek) / 2, wallHeight / 2, depth / 2 - WALL_THICK / 2),
			wallMaterial, wallColor)
	end
	if wallHeight > DOOR_HEIGHT then
		sitePart(into, "Lintel", Vector3.new(doorWidth, wallHeight - DOOR_HEIGHT, WALL_THICK),
			at * CFrame.new(0, DOOR_HEIGHT + (wallHeight - DOOR_HEIGHT) / 2, depth / 2 - WALL_THICK / 2),
			Enum.Material.Wood, TIMBER)
	end

	-- Framing: corner posts and a mid rail, proud of the wall. Most of the
	-- difference between a cottage and a box.
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			sitePart(into, "Post", Vector3.new(0.7, wallHeight, 0.7),
				at * CFrame.new(sx * (width / 2 - 0.2), wallHeight / 2, sz * (depth / 2 - 0.2)),
				Enum.Material.Wood, TIMBER)
		end
	end
	for _, sz in { -1, 1 } do
		sitePart(into, "Rail", Vector3.new(width + 0.3, 0.6, 0.45),
			at * CFrame.new(0, wallHeight * 0.72, sz * (depth / 2 + 0.05)),
			Enum.Material.Wood, TIMBER)
	end

	gable(into, at * CFrame.new(0, wallHeight, 0), width + 2.0, depth + 2.0,
		wallHeight * 0.8, roofColor)
end

-- --- the four villager houses, deliberately identical -------------
local HOUSE = { width = 17, depth = 15, wallHeight = 9, door = 4.6 }

local function makeVillagerHouse(into: Instance, at: CFrame)
	hollowBuilding(into, at, HOUSE.width, HOUSE.depth, HOUSE.wallHeight, HOUSE.door,
		DAUB, THATCH, Enum.Material.Sandstone)
	for _, sx in { -1, 1 } do
		sitePart(into, "Window", Vector3.new(1.8, 1.8, 0.3),
			at * CFrame.new(sx * HOUSE.width * 0.34, 5.4, HOUSE.depth / 2),
			Enum.Material.Glass, Color3.fromRGB(62, 72, 68))
	end
end

-- --- the three workshops, each unmistakably itself ----------------
local SHOP = { width = 23, depth = 19, wallHeight = 11, door = 5.2 }

-- A workshop's crafting prompt. The RECIPE lives in ResourceService, which is
-- where game rules live; this only says which recipe to look up.
local function craftPrompt(host: BasePart, recipe: string, label: string)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CraftPrompt"
	prompt.ActionText = "Work"
	prompt.ObjectText = label
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("Recipe", recipe)
	prompt.Parent = host
end

local function makeCarpenter(into: Instance, at: CFrame)
	hollowBuilding(into, at, SHOP.width, SHOP.depth, SHOP.wallHeight, SHOP.door,
		Color3.fromRGB(168, 132, 84), Color3.fromRGB(122, 96, 58), Enum.Material.WoodPlanks)
	-- Stacked logs and a sawhorse: you should know what this shed is before you
	-- read the prompt.
	for i = 1, 5 do
		local row = math.floor((i - 1) / 3)
		local col = (i - 1) % 3
		local log = siteDrum(into, "LogStack", 1.1, 9,
			at * CFrame.new(-SHOP.width / 2 - 3.4, 1.1 + row * 2.1, -3 + col * 2.4 - row * 1.2)
				* CFrame.Angles(0, math.rad(90), 0),
			Enum.Material.Wood, Color3.fromRGB(104, 74, 46))
		log.Name = "LogStack"
	end
	for _, sx in { -1, 1 } do
		sitePart(into, "Sawhorse", Vector3.new(0.6, 3, 0.6),
			at * CFrame.new(sx * 2.2 + SHOP.width / 2 + 3.6, 1.5, 2), Enum.Material.Wood, TIMBER)
	end
	local bench = sitePart(into, "SawBench", Vector3.new(7, 0.6, 2.4),
		at * CFrame.new(SHOP.width / 2 + 3.6, 3.2, 2), Enum.Material.Wood,
		Color3.fromRGB(148, 116, 74))
	sitePart(into, "CarpenterSign", Vector3.new(4.4, 0.5, 3),
		at * CFrame.new(0, 8.2, SHOP.depth / 2 + 1.4), Enum.Material.Wood, TIMBER)
	-- The prompt goes on the BENCH, not on the sign above the door. A prompt
	-- five studs over the character was measured refusing to activate at nine
	-- studs while the same prompt lowered to head height fired at seven, so
	-- every interaction here sits at roughly the height of the person using it.
	craftPrompt(bench, "Carpenter", "Carpenter")
end

local function makeBlacksmith(into: Instance, at: CFrame)
	hollowBuilding(into, at, SHOP.width, SHOP.depth, SHOP.wallHeight, SHOP.door,
		Color3.fromRGB(126, 120, 112), Color3.fromRGB(96, 54, 44), Enum.Material.Brick)
	sitePart(into, "ForgeChimney", Vector3.new(4.2, 19, 4.2),
		at * CFrame.new(-SHOP.width / 2 + 3, 9.5, -SHOP.depth / 2 + 3),
		Enum.Material.Brick, Color3.fromRGB(96, 74, 64))
	sitePart(into, "ForgeGlow", Vector3.new(2.4, 1.2, 2.4),
		at * CFrame.new(-SHOP.width / 2 + 3, 19.6, -SHOP.depth / 2 + 3),
		Enum.Material.Neon, Color3.fromRGB(226, 128, 62))
	sitePart(into, "AnvilBlock", Vector3.new(2.6, 2, 2),
		at * CFrame.new(SHOP.width / 2 + 4, 1, 3), Enum.Material.Wood, Color3.fromRGB(78, 56, 38))
	local anvil = sitePart(into, "Anvil", Vector3.new(3.2, 1.3, 1.4),
		at * CFrame.new(SHOP.width / 2 + 4, 2.65, 3), Enum.Material.Metal,
		Color3.fromRGB(64, 66, 72))
	craftPrompt(anvil, "Blacksmith", "Blacksmith")
end

local function makeAlchemist(into: Instance, at: CFrame)
	-- Square below so it is enterable, round turret above so the silhouette is
	-- unmistakable from outside the wall. A hollow cylinder would need a ring of
	-- parts and would still be a worse room.
	hollowBuilding(into, at, SHOP.width, SHOP.depth, SHOP.wallHeight, SHOP.door,
		Color3.fromRGB(150, 142, 162), Color3.fromRGB(78, 62, 104), Enum.Material.Sandstone)
	local turretAt = at * CFrame.new(0, SHOP.wallHeight + SHOP.wallHeight * 0.8 - 1, 0)
	siteDrum(into, "TurretBase", 5.6, 1.4, turretAt, Enum.Material.Slate,
		Color3.fromRGB(112, 104, 124))
	siteDrum(into, "Turret", 4.8, 9, turretAt * CFrame.new(0, 1.4, 0), Enum.Material.Brick,
		Color3.fromRGB(150, 142, 162))
	for i = 0, 5 do
		siteDrum(into, ("TurretSpire%d"):format(i), 4.8 * (1 - i * 0.16), 1.5,
			turretAt * CFrame.new(0, 10.4 + i * 1.35, 0), Enum.Material.Slate,
			Color3.fromRGB(72, 60, 92))
	end
	local vat = siteDrum(into, "Cauldron", 2.4, 2.6,
		at * CFrame.new(SHOP.width / 2 + 4.2, 0, 2), Enum.Material.Metal,
		Color3.fromRGB(66, 70, 78))
	sitePart(into, "Brew", Vector3.new(4.2, 0.4, 4.2),
		at * CFrame.new(SHOP.width / 2 + 4.2, 2.7, 2), Enum.Material.Neon,
		Color3.fromRGB(126, 220, 148))
	craftPrompt(vat, "Alchemist", "Alchemist")
end

-- --- the keep -----------------------------------------------------
local function makeKeep(into: Instance, at: CFrame)
	-- Hollow like everything else, and big enough to stand in, but the walls are
	-- what matter: this is the thing a siege is finally for.
	local keep = sitePart(into, "Keep", Vector3.new(24, 30, 24), at * CFrame.new(0, 15, 0),
		Enum.Material.Brick, Color3.fromRGB(128, 118, 108))
	sitePart(into, "KeepDoor", Vector3.new(5.4, DOOR_HEIGHT, 1.2),
		at * CFrame.new(0, DOOR_HEIGHT / 2, 12), Enum.Material.Wood, Color3.fromRGB(72, 48, 30))
	local crown = sitePart(into, "KeepCrown", Vector3.new(27, 2.2, 27),
		at * CFrame.new(0, 31, 0), Enum.Material.Slate, Color3.fromRGB(84, 78, 76))
	for merlon = 0, 11 do
		local ring = merlon / 12 * math.pi * 2
		sitePart(into, "Merlon", Vector3.new(3, 2.8, 3),
			crown.CFrame * CFrame.new(math.cos(ring) * 11.8, 2.5, math.sin(ring) * 11.8),
			Enum.Material.Brick, Color3.fromRGB(118, 108, 100))
	end
	return keep
end

-- --- wall scenery: footing, towers, gate --------------------------
local function ringSlots(): { CFrame }
	local slots: { CFrame } = {}
	local half = (RING_STEPS - 1) / 2
	for side = 0, 3 do
		local yaw = math.rad(90 * side)
		for i = 0, RING_STEPS - 1 do
			local along = (i - half) * WALL_SPAN
			slots[#slots + 1] = CFrame.Angles(0, yaw, 0) * CFrame.new(along, 0, WALL_HALF)
		end
	end
	return slots
end

local RING = ringSlots()
local GATE_SLOT = math.ceil(RING_STEPS / 2) -- middle of the first side

local function makePlot(name: string, centre: Vector2)
	local ground = groundHeight(centre.X, centre.Y)
	local site = Instance.new("Model")
	site.Name = name
	site:SetAttribute("Kind", "Base")

	local foundation = Instance.new("Part")
	foundation.Name = "Foundation"
	foundation.Size = Vector3.new(PLOT, 1, PLOT)
	foundation.Position = Vector3.new(centre.X, ground + 0.5, centre.Y)
	foundation.Anchored = true
	foundation.Material = Enum.Material.Ground
	foundation.Color = Color3.fromRGB(122, 106, 84)
	foundation.TopSurface = Enum.SurfaceType.Smooth
	foundation.BottomSurface = Enum.SurfaceType.Smooth
	foundation.Parent = site
	site.PrimaryPart = foundation

	local floor = foundation.CFrame * CFrame.new(0, 0.5, 0)
	local function at(x: number, z: number, yaw: number): CFrame
		return floor * CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yaw), 0)
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BuildPrompt"
	prompt.ActionText = "Build"
	prompt.ObjectText = "Empty plot"
	prompt.HoldDuration = 0.35
	-- Has to reach the gate line at 70, or the owner cannot repair while standing
	-- where a defender actually stands.
	prompt.MaxActivationDistance = 96
	prompt.RequiresLineOfSight = false
	prompt.Parent = foundation

	-- The claim stone. An empty plot still has to look like a plot rather than a
	-- patch of dirt somebody forgot.
	local cairn = sitePart(site, "ClaimStone", Vector3.new(3, 4.4, 2.4),
		at(0, 8, 18) * CFrame.new(0, 2.2, 0), Enum.Material.Rock, Color3.fromRGB(126, 120, 112))
	sitePart(site, "ClaimStoneCap", Vector3.new(3.8, 0.7, 3.2),
		cairn.CFrame * CFrame.new(0, 2.5, 0), Enum.Material.Slate, Color3.fromRGB(88, 82, 78))

	local sections = Instance.new("Folder")
	sections.Name = "Sections"
	sections.Parent = site

	for index, slot in RING do
		if index ~= GATE_SLOT then
			local marker = Instance.new("Attachment")
			marker.Name = ("Slot%02d"):format(index)
			marker.CFrame = slot * CFrame.new(0, WALL_BLOCK.Y / 2 + 0.5, 0)
			marker.Parent = foundation
		end
	end

	-- The stockpile. Not a shed: a low pallet whose HEAP is built by
	-- ResourceService out of whatever the owner is actually holding, so the pile
	-- across the village is a readout of how rich the place is. The pallet is
	-- the part a raider aims at, so it exists from the start.
	local stockpile = sitePart(site, "Stockpile", Vector3.new(22, 1.4, 18),
		at(26, 44, 0) * CFrame.new(0, 0.7, 0), Enum.Material.WoodPlanks,
		Color3.fromRGB(134, 102, 66))
	local goods = Instance.new("Folder")
	goods.Name = "Goods"
	goods.Parent = site
	-- Where the heap is stacked from, published so the service does not need the
	-- plot's layout maths.
	local heap = Instance.new("Attachment")
	heap.Name = "HeapOrigin"
	heap.CFrame = CFrame.new(0, 0.7, 0)
	heap.Parent = stockpile

	-- Streets, laid from the start: they are what make an empty plot read as a
	-- place that is GOING to be a village.
	sitePart(site, "StreetSpine", Vector3.new(12, 0.3, 132), at(0, -4, 0),
		Enum.Material.Cobblestone, Color3.fromRGB(148, 142, 130))
	sitePart(site, "StreetCross", Vector3.new(112, 0.3, 10), at(0, 6, 0),
		Enum.Material.Cobblestone, Color3.fromRGB(148, 142, 130))

	local well = at(0, 6, 0)
	siteDrum(site, "WellWall", 3.6, 3, well, Enum.Material.Cobblestone,
		Color3.fromRGB(126, 120, 110))
	siteDrum(site, "WellMouth", 2.8, 0.5, well * CFrame.new(0, 3, 0), Enum.Material.Slate,
		Color3.fromRGB(38, 40, 44))

	-- ---- the blueprint: every stage, built now, installed later ----
	local plan = Instance.new("Folder")
	plan.Name = name
	plan.Parent = blueprints

	local function stage(index: number): Folder
		local folder = Instance.new("Folder")
		folder.Name = ("Stage%02d"):format(index)
		folder.Parent = plan
		return folder
	end

	-- 1-4: the villager houses, all alike on purpose. A village should read as
	-- ordinary dwellings with a few special buildings among them, not as four
	-- landmarks.
	local HOUSE_SPOTS = {
		{ x = -48, z = 26, yaw = 90 },
		{ x = 48, z = 26, yaw = -90 },
		{ x = -48, z = -8, yaw = 90 },
		{ x = 48, z = -8, yaw = -90 },
	}
	for i, spot in HOUSE_SPOTS do
		makeVillagerHouse(stage(i), at(spot.x, spot.z, spot.yaw))
	end

	-- 5-7: the workshops
	makeCarpenter(stage(5), at(-30, 50, 0))
	makeBlacksmith(stage(6), at(-46, -44, 20))
	makeAlchemist(stage(7), at(46, -44, -20))

	-- 8: the keep
	makeKeep(stage(8), at(0, -46, 0))

	-- 9: the palisade - the gate and the footing it stands on. The wall blocks
	-- themselves are drawn by ResourceService from the wall's HP, so they are not
	-- in the blueprint; this is the permanent scenery around them.
	local palisade = stage(9)
	for side = 0, 3 do
		local yaw = math.rad(90 * side)
		sitePart(palisade, "WallFooting", Vector3.new(WALL_HALF * 2, 1.6, WALL_BLOCK.Z),
			floor * CFrame.Angles(0, yaw, 0) * CFrame.new(0, 0.8, WALL_HALF),
			Enum.Material.Cobblestone, Color3.fromRGB(124, 118, 108))
	end
	local gate = sitePart(palisade, "Gate",
		Vector3.new(WALL_BLOCK.X + 1.4, WALL_BLOCK.Y + 4, WALL_BLOCK.Z),
		foundation.CFrame * RING[GATE_SLOT] * CFrame.new(0, (WALL_BLOCK.Y + 4) / 2 + 0.5, 0),
		Enum.Material.WoodPlanks, Color3.fromRGB(104, 72, 44))
	local gateFace = Instance.new("Attachment")
	gateFace.Name = "GateFace"
	gateFace.Parent = gate

	-- 10: the rampart - corner towers closing the four gaps the straight runs
	-- leave, and the last of the wall's strength.
	local rampart = stage(10)
	for corner = 0, 3 do
		local yaw = math.rad(90 * corner + 45)
		local reach = WALL_HALF * math.sqrt(2)
		local tower = at(math.sin(yaw) * reach, math.cos(yaw) * reach, 0)
		siteDrum(rampart, "CornerTower", 7, 16, tower, Enum.Material.Cobblestone, STONEWORK)
		siteDrum(rampart, "CornerCap", 8, 1.8, tower * CFrame.new(0, 16, 0),
			Enum.Material.Slate, Color3.fromRGB(88, 82, 78))
		for merlon = 0, 7 do
			local ring = merlon / 8 * math.pi * 2
			sitePart(rampart, "TowerMerlon", Vector3.new(2.2, 2.4, 2.2),
				tower * CFrame.new(math.cos(ring) * 6.6, 18.6, math.sin(ring) * 6.6),
				Enum.Material.Cobblestone, STONEWORK)
		end
	end

	site.Parent = buildSites
	return site
end

-- Roughly a dozen claimable plots, which is the player count Conquest is written
-- for. A checkerboard of the interior tile corners, minus the ring around the
-- totem so nobody spawns straight into somebody's keep.
local plotCount = 0
for i = 2, GRID do
	for j = 2, GRID do
		if (i + j) % 2 == 0 then
			local point = cornerPoint(i, j)
			if point.Magnitude > TILE * 1.4 then
				plotCount += 1
				makePlot(("Base_%02d"):format(plotCount), point)
			end
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
