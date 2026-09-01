--!strict
-- Medieval Land - world builder. A Catan-style board: a 5x5 grid of square
-- resource tiles around a central lake, with castle plots on the tile corners.
-- One-shot setup script. Safe to re-run: it tears down what it built last time first.

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local StarterPack = game:GetService("StarterPack")
local Terrain = Workspace.Terrain

-- Exposed as a function so it can be re-run. Rojo syncs this file to
-- ServerStorage.BuildWorld, so rebuilding the world is one line in the command
-- bar rather than pasting the whole file in:
--
--   require(game.ServerStorage.BuildWorld)()
--
-- The body below is deliberately left at column 0. Indenting 700 lines by one
-- level to satisfy the wrapper would make every future diff unreadable.
return function()

local MAP_SIZE = 512
local SOIL_THICK = 30 -- terrain slab, top surface at y = 0

local GRID = 5 -- tiles per side
local TILE = 72 -- studs per tile
local BOARD = GRID * TILE -- 360; the board is centred on the origin

-- The lake occupies the centre tile and is kept well inside it, so the four
-- castle plots on that tile's corners stay on dry land.
local LAKE_RADIUS = 30
local LAKE_SINK = 18

-- Row-major, row 1 at -Z. Fixed rather than shuffled: the stone tiles need to be
-- spread but not maximally distant, because the walk between them is what makes
-- the regen curve in ResourceService worth anything.
--   L lake   S stone   W wood   G grass   D desert
local LAYOUT = {
	"GWSGD",
	"SGWDG",
	"WDLGS",
	"GSDWG",
	"DGWSG",
}

local TILE_MATERIAL = {
	L = Enum.Material.LeafyGrass, -- the water is carved into it separately
	S = Enum.Material.Rock,
	W = Enum.Material.Mud, -- forest floor, and distinct from the surround
	G = Enum.Material.LeafyGrass,
	D = Enum.Material.Sand,
}

-- Everything off the board. Deliberately NOT LeafyGrass: when the surround
-- matched the grass tiles, the board stopped reading as a board and became
-- landscape with lines drawn on it. Dull earth makes the tiles pop.
local SURROUND_MATERIAL = Enum.Material.Ground

-- Outside the board, so the horizon is not a flat edge.
local SURROUND_RISES = 10

local SPAWN_POS = Vector3.new(0, 0.5, 205)
local WALL_SITE_POS = Vector3.new(0, 0.5, 188)

local rng = Random.new(20260902)

-- ---------------------------------------------------------------- tile helpers
-- Tile (row, col) with 1-based indices; row 1 is the -Z edge.
local function tileKind(row: number, col: number): string
	return LAYOUT[row]:sub(col, col)
end

local function tileCentre(row: number, col: number): Vector2
	return Vector2.new((col - (GRID + 1) / 2) * TILE, (row - (GRID + 1) / 2) * TILE)
end

-- Corners are the lattice points between tiles. Corner (i, j) with 1-based
-- indices runs 1..GRID+1; the interior ones (2..GRID) are where four tiles meet,
-- which is where a castle can go.
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
local oldTool = StarterPack:FindFirstChild("Pickaxe")
if oldTool then
	oldTool:Destroy()
end
Terrain:Clear()

-- ---------------------------------------------------------------- terrain
-- Base slab for everything outside the board.
Terrain:FillBlock(
	CFrame.new(0, -SOIL_THICK / 2, 0),
	Vector3.new(MAP_SIZE, SOIL_THICK, MAP_SIZE),
	SURROUND_MATERIAL
)

-- Rises only OUTSIDE the board. The board itself stays dead flat, which is what
-- makes it read as a board rather than as landscape.
for i = 1, SURROUND_RISES do
	local angle = (i / SURROUND_RISES) * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
	local dist = rng:NextNumber(BOARD / 2 + 60, 230)
	local radius = rng:NextNumber(40, 70)
	local rise = rng:NextNumber(5, 12)
	Terrain:FillBall(
		Vector3.new(math.cos(angle) * dist, -radius + rise, math.sin(angle) * dist),
		radius,
		SURROUND_MATERIAL
	)
end

-- Paint each tile. Squared-off fills are exactly what we want here.
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

-- Water on the centre tile.
--
-- Terrain:FillBall(..., Enum.Material.Water) is a SILENT NO-OP on current
-- Roblox. Since the Shorelines change, water is not a material in the solid
-- voxel grid at all - it is its own LiquidOccupancy channel - and the Fill*
-- family cannot write it. Nothing errors; you just get no water.
local LAKE_CENTRE = Vector3.new(0, -LAKE_SINK, 0)
local VOXEL = 4

local lakeRegion = Region3.new(
	Vector3.new(-LAKE_RADIUS - 12, -LAKE_SINK - 14, -LAKE_RADIUS - 12),
	Vector3.new(LAKE_RADIUS + 12, 8, LAKE_RADIUS + 12)
):ExpandToGrid(VOXEL)

local channels = Terrain:ReadVoxelChannels(
	lakeRegion,
	VOXEL,
	{ "SolidMaterial", "SolidOccupancy", "LiquidOccupancy" }
)
local solidMaterial = channels.SolidMaterial
local solidOccupancy = channels.SolidOccupancy
local liquidOccupancy = channels.LiquidOccupancy

local regionSize = lakeRegion.Size
local regionCorner = lakeRegion.CFrame.Position - regionSize / 2
local countX, countY, countZ = regionSize.X // VOXEL, regionSize.Y // VOXEL, regionSize.Z // VOXEL

for xi = 1, countX do
	for yi = 1, countY do
		for zi = 1, countZ do
			local centre = regionCorner
				+ Vector3.new((xi - 0.5) * VOXEL, (yi - 0.5) * VOXEL, (zi - 0.5) * VOXEL)
			if (centre - LAKE_CENTRE).Magnitude <= LAKE_RADIUS then
				solidMaterial[xi][yi][zi] = Enum.Material.Air
				solidOccupancy[xi][yi][zi] = 0
				liquidOccupancy[xi][yi][zi] = if centre.Y < 0 then 1 else 0
			end
		end
	end
end

Terrain:WriteVoxelChannels(lakeRegion, VOXEL, {
	SolidMaterial = solidMaterial,
	SolidOccupancy = solidOccupancy,
	LiquidOccupancy = liquidOccupancy,
})

-- ---------------------------------------------------------------- ground probe
-- Nothing below may assume the ground is at y = 0. Terrain smoothing lifts the
-- flat parts of the map, and the surrounding rises push it further. Placing at a
-- hardcoded height once buried a whole resource node inside a hill.
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { Terrain }

local function groundHeight(x: number, z: number): number
	local hit = Workspace:Raycast(Vector3.new(x, 220, z), Vector3.new(0, -440, 0), groundParams)
	return if hit then hit.Position.Y else 0
end

-- ---------------------------------------------------------------- board edges
-- Thin kerbs along the tile boundaries. Without these the terrain colours blur
-- into each other and it stops reading as a board.
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

-- ---------------------------------------------------------------- scenery
local scenery = Instance.new("Folder")
scenery.Name = "MedievalLand_Scenery"
scenery.Parent = Workspace

local FROND_GREENS = {
	Color3.fromRGB(72, 130, 56),
	Color3.fromRGB(94, 148, 62),
	Color3.fromRGB(58, 112, 50),
	Color3.fromRGB(110, 158, 70),
}

local function makePalm(origin: Vector3)
	local palm = Instance.new("Model")
	palm.Name = "PalmTree"

	local height = rng:NextNumber(17, 27)
	local segments = 7
	local segHeight = height / segments
	local baseRadius = rng:NextNumber(0.75, 1.0)
	local lean = rng:NextNumber(0.045, 0.115) -- radians added per segment; the curve
	local facing = rng:NextNumber(0, math.pi * 2)

	local cursor = CFrame.new(origin) * CFrame.Angles(0, facing, 0)
	local trunkColor = Color3.fromRGB(
		rng:NextInteger(126, 152),
		rng:NextInteger(104, 124),
		rng:NextInteger(78, 94)
	)

	local firstSegment: Part? = nil
	for i = 1, segments do
		cursor = cursor * CFrame.Angles(lean, 0, 0)

		local radius = baseRadius * (1 - 0.42 * ((i - 1) / segments))
		local segment = Instance.new("Part")
		segment.Name = "Trunk" .. i
		segment.Shape = Enum.PartType.Cylinder
		-- Cylinder parts run along their X axis, so the part is rolled 90 degrees
		-- to stand the length up along the cursor's Y.
		segment.Size = Vector3.new(segHeight + 0.4, radius * 2, radius * 2)
		segment.CFrame = cursor * CFrame.new(0, segHeight / 2, 0) * CFrame.Angles(0, 0, math.rad(90))
		segment.Anchored = true
		segment.Material = Enum.Material.Wood
		segment.Color = trunkColor
		segment.Parent = palm

		firstSegment = firstSegment or segment
		cursor = cursor * CFrame.new(0, segHeight, 0)
	end

	local crown = cursor
	local frondCount = rng:NextInteger(7, 9)
	local frondColor = FROND_GREENS[rng:NextInteger(1, #FROND_GREENS)]

	for f = 1, frondCount do
		local around = (f / frondCount) * math.pi * 2 + rng:NextNumber(-0.16, 0.16)
		local outward = CFrame.new(crown.Position) * CFrame.Angles(0, around, 0)

		-- Fronds are two segments: one lifting away from the crown, one drooping
		-- off the end of it. One straight blade looks like a spike, not a leaf.
		local rise = math.rad(rng:NextNumber(10, 30))
		local innerLength = rng:NextNumber(5.0, 6.8)
		local innerFrame = outward * CFrame.Angles(rise, 0, 0)

		local inner = Instance.new("Part")
		inner.Name = "Frond"
		inner.Size = Vector3.new(2.1, 0.22, innerLength)
		inner.CFrame = innerFrame * CFrame.new(0, 0, -innerLength / 2)
		inner.Anchored = true
		inner.Material = Enum.Material.Grass
		inner.Color = frondColor
		inner.Parent = palm

		local droop = math.rad(rng:NextNumber(38, 62))
		local outerLength = rng:NextNumber(5.0, 7.5)
		local outerFrame = innerFrame * CFrame.new(0, 0, -innerLength) * CFrame.Angles(-droop, 0, 0)

		local outer = Instance.new("Part")
		outer.Name = "FrondTip"
		outer.Size = Vector3.new(1.4, 0.2, outerLength)
		outer.CFrame = outerFrame * CFrame.new(0, 0, -outerLength / 2)
		outer.Anchored = true
		outer.Material = Enum.Material.Grass
		outer.Color = frondColor:Lerp(Color3.fromRGB(150, 178, 92), 0.35)
		outer.Parent = palm
	end

	for c = 1, rng:NextInteger(2, 4) do
		local coconut = Instance.new("Part")
		coconut.Name = "Coconut"
		coconut.Shape = Enum.PartType.Ball
		local size = rng:NextNumber(0.9, 1.2)
		coconut.Size = Vector3.new(size, size, size)
		coconut.CFrame = crown
			* CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
			* CFrame.new(0, rng:NextNumber(-1.4, -0.4), -rng:NextNumber(0.7, 1.3))
		coconut.Anchored = true
		coconut.Material = Enum.Material.Wood
		coconut.Color = Color3.fromRGB(74, 52, 34)
		coconut.Parent = palm
	end

	palm.PrimaryPart = firstSegment
	palm.Parent = scenery
end

local function makeShrub(x: number, z: number)
	local shrub = Instance.new("Model")
	shrub.Name = "Shrub"
	local main: Part? = nil
	local ground = groundHeight(x, z)
	for lobe = 1, rng:NextInteger(2, 4) do
		local size = rng:NextNumber(2.2, 4.0)
		local blob = Instance.new("Part")
		blob.Shape = Enum.PartType.Ball
		blob.Size = Vector3.new(size, size * 0.78, size)
		blob.Position = Vector3.new(x, ground + size * 0.24, z)
			+ Vector3.new(rng:NextNumber(-1.6, 1.6), 0, rng:NextNumber(-1.6, 1.6))
		blob.Anchored = true
		blob.Material = Enum.Material.LeafyGrass
		blob.Color = FROND_GREENS[rng:NextInteger(1, #FROND_GREENS)]
		blob.Parent = shrub
		main = main or blob
	end
	shrub.PrimaryPart = main
	shrub.Parent = scenery
end

local function makeBoulder(x: number, z: number)
	local size = rng:NextNumber(2.0, 4.6)
	local boulder = Instance.new("Part")
	boulder.Name = "Boulder"
	boulder.Size = Vector3.new(size, size * rng:NextNumber(0.5, 0.8), size * rng:NextNumber(0.7, 1.2))
	boulder.CFrame = CFrame.new(x, groundHeight(x, z) + size * 0.2, z)
		* CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, 6.28), rng:NextNumber(-0.3, 0.3))
	boulder.Anchored = true
	boulder.Material = Enum.Material.Rock
	local grey = rng:NextInteger(112, 142)
	boulder.Color = Color3.fromRGB(grey + 6, grey + 3, grey)
	boulder.Parent = scenery
end

-- Scenery is dressed per tile kind, which is what makes a tile readable from
-- ground level rather than only from above.
local INSET = TILE / 2 - 9 -- keep scenery off the kerbs

for row = 1, GRID do
	for col = 1, GRID do
		local kind = tileKind(row, col)
		local centre = tileCentre(row, col)

		local function scatter(count: number, place: (number, number) -> ())
			for _ = 1, count do
				place(
					centre.X + rng:NextNumber(-INSET, INSET),
					centre.Y + rng:NextNumber(-INSET, INSET)
				)
			end
		end

		if kind == "W" then
			scatter(rng:NextInteger(5, 7), function(x, z)
				makePalm(Vector3.new(x, groundHeight(x, z) - 0.6, z))
			end)
			scatter(2, makeShrub)
		elseif kind == "G" then
			scatter(rng:NextInteger(3, 5), makeShrub)
		elseif kind == "S" then
			scatter(rng:NextInteger(3, 5), makeBoulder)
		elseif kind == "D" then
			scatter(rng:NextInteger(1, 2), makeBoulder)
		elseif kind == "L" then
			scatter(3, function(x, z)
				-- palms on the lake shore only, not in the water
				if Vector2.new(x, z).Magnitude > LAKE_RADIUS + 4 then
					makePalm(Vector3.new(x, groundHeight(x, z) - 0.6, z))
				end
			end)
		end
	end
end

-- ---------------------------------------------------------------- spawn
local spawnPad = Instance.new("SpawnLocation")
spawnPad.Name = "SpawnLocation"
spawnPad.Size = Vector3.new(12, 1, 12)
spawnPad.Position = Vector3.new(SPAWN_POS.X, groundHeight(SPAWN_POS.X, SPAWN_POS.Z) + 0.5, SPAWN_POS.Z)
spawnPad.Anchored = true
spawnPad.Material = Enum.Material.Sandstone
spawnPad.Color = Color3.fromRGB(196, 174, 138)
spawnPad.Duration = 0
spawnPad.Parent = Workspace

-- ---------------------------------------------------------------- resource nodes
-- Geometry only. Every number that changes at runtime - how much stone is left,
-- how fast it comes back - lives in ResourceService.
local nodes = Instance.new("Folder")
nodes.Name = "ResourceNodes"
nodes.Parent = Workspace

local function makeOutcrop(name: string, origin: Vector3)
	local outcrop = Instance.new("Model")
	outcrop.Name = name

	-- origin.Y is the core centre, which the caller sets to ground + 2.4.
	local groundY = origin.Y - 2.4

	local function stone(partName: string, size: Vector3, cframe: CFrame, parent: Instance): Part
		local part = Instance.new("Part")
		part.Name = partName
		part.Size = size
		part.CFrame = cframe
		part.Anchored = true
		-- Rock only. Slate's texture is noticeably purple, which the warm colour
		-- correction on this place pushes all the way to mauve.
		part.Material = Enum.Material.Rock
		-- One grey, jittered equally on all three channels so it stays neutral
		-- rather than drifting into a tint.
		local grey = rng:NextInteger(102, 134)
		part.Color = Color3.fromRGB(grey + 5, grey + 3, grey)
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = parent
		return part
	end

	-- No dominant centre block: one big box with smaller boxes tucked against it
	-- just reads as a box. A cluster of similar blocks whose TOPS sit at
	-- different heights is what gives a rock its broken silhouette.
	local core = stone(
		"Core",
		Vector3.new(3.4, 4.6, 3.0),
		CFrame.new(origin) * CFrame.Angles(math.rad(5), math.rad(22), math.rad(-7)),
		outcrop
	)

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
			) * CFrame.Angles(
				rng:NextNumber(-0.22, 0.22),
				rng:NextNumber(0, 6.28),
				rng:NextNumber(-0.26, 0.26)
			),
			outcrop
		)
	end

	for i = 1, 2 do
		local height = rng:NextNumber(3.0, 4.4)
		stone(
			"Shard" .. i,
			Vector3.new(rng:NextNumber(1.3, 2.0), height, rng:NextNumber(1.3, 2.0)),
			CFrame.new(
				origin.X + rng:NextNumber(-1.6, 1.6),
				origin.Y + 1.6 + height / 2,
				origin.Z + rng:NextNumber(-1.6, 1.6)
			) * CFrame.Angles(
				rng:NextNumber(-0.28, 0.28),
				rng:NextNumber(0, 6.28),
				rng:NextNumber(-0.28, 0.28)
			),
			outcrop
		)
	end

	for i = 1, 7 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(3.2, 6.0)
		local size = rng:NextNumber(0.7, 1.9)
		stone(
			"Rubble" .. i,
			Vector3.new(size, size * rng:NextNumber(0.5, 0.9), size * rng:NextNumber(0.7, 1.2)),
			CFrame.new(origin.X + math.cos(angle) * dist, groundY + 0.25, origin.Z + math.sin(angle) * dist)
				* CFrame.Angles(rng:NextNumber(-0.4, 0.4), rng:NextNumber(0, 6.28), rng:NextNumber(-0.4, 0.4)),
			outcrop
		)
	end

	outcrop.PrimaryPart = core
	outcrop.Parent = nodes
	return outcrop
end

-- One outcrop per stone tile, at the tile's centre. A stone tile IS the node.
local nodeCount = 0
for row = 1, GRID do
	for col = 1, GRID do
		if tileKind(row, col) == "S" then
			nodeCount += 1
			local centre = tileCentre(row, col)
			makeOutcrop(
				("Rock_%02d"):format(nodeCount),
				Vector3.new(centre.X, groundHeight(centre.X, centre.Y) + 2.4, centre.Y)
			)
		end
	end
end

-- ---------------------------------------------------------------- build sites
-- Geometry and prompts live here; costs, layouts and progress live in
-- ResourceService. The Kind attribute tells the service which layout to use.
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

-- The starter wall, kept from Tier 1 so its verified behaviour survives.
makeSite(
	"WallSite",
	"Wall",
	Vector3.new(WALL_SITE_POS.X, groundHeight(WALL_SITE_POS.X, WALL_SITE_POS.Z) + 0.5, WALL_SITE_POS.Z),
	Vector3.new(34, 1, 3.4)
)

-- A castle plot on every interior tile corner - the Catan settlement spots.
local plotCount = 0
for i = 2, GRID do
	for j = 2, GRID do
		local point = cornerPoint(i, j)
		-- Skip anything that would sit in the lake.
		if point.Magnitude > LAKE_RADIUS + 8 then
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

-- ---------------------------------------------------------------- pickaxe
-- Built here rather than by hand in Studio so the tool is reproducible from
-- source like everything else. ResourceService drives it; it carries no scripts.
local function buildPickaxe(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Pickaxe"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Swing at a rock to mine stone"
	-- Hand grips near the butt of the shaft, head out front, angled down a little.
	tool.Grip = CFrame.new(0, 0, 1.35) * CFrame.Angles(math.rad(15), 0, 0)

	local WOOD = Color3.fromRGB(122, 84, 50)
	local IRON = Color3.fromRGB(96, 100, 107)
	local IRON_DARK = Color3.fromRGB(72, 76, 83)

	-- The shaft runs along the handle's local Z, with the head at -Z.
	--
	-- The Handle is a plain unrotated block and is invisible; the wooden shaft
	-- you actually see is a cylinder welded over it. Tool.Grip is expressed in
	-- the Handle's own frame, so rotating the Handle to lay a cylinder along Z
	-- would twist every Grip value with it.
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.30, 0.30, 3.9)
	handle.CFrame = CFrame.new()
	handle.Transparency = 1
	handle.Anchored = false
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool

	local handleFrame = CFrame.new()
	local function attach(part: BasePart, localCFrame: CFrame)
		part.CFrame = handleFrame * localCFrame
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

	local function metal(name: string, size: Vector3, localCFrame: CFrame, color: Color3)
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size
		part.Material = Enum.Material.Metal
		part.Color = color
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		attach(part, localCFrame)
	end

	local shaft = Instance.new("Part")
	shaft.Name = "Shaft"
	shaft.Shape = Enum.PartType.Cylinder
	shaft.Size = Vector3.new(3.9, 0.33, 0.33)
	shaft.Material = Enum.Material.Wood
	shaft.Color = WOOD
	attach(shaft, CFrame.Angles(0, math.rad(90), 0))

	-- Both arms of the head sweep BACK toward the user in a curve and taper to a
	-- point. Each arm is five short segments, each rotated a little further round.
	local HEAD_AT = CFrame.new(0, 0, -1.72)
	local ARM_SEGMENTS = 5
	local SEG_LENGTH = 0.42
	local SEG_CURVE = math.rad(13)

	for _, side in { 1, -1 } do
		local cursor = HEAD_AT * CFrame.Angles(0, 0, if side == 1 then 0 else math.pi)
		cursor = cursor * CFrame.new(0, 0.16, 0)

		for seg = 1, ARM_SEGMENTS do
			cursor = cursor * CFrame.Angles(SEG_CURVE, 0, 0)

			local taper = 1 - (seg - 1) / ARM_SEGMENTS
			local thickness = 0.10 + 0.20 * taper
			local depth = 0.20 + 0.26 * taper

			metal(
				("Head%s%d"):format(if side == 1 then "Up" else "Down", seg),
				Vector3.new(thickness, SEG_LENGTH + 0.06, depth),
				cursor * CFrame.new(0, SEG_LENGTH / 2, 0),
				IRON
			)

			cursor = cursor * CFrame.new(0, SEG_LENGTH, 0)
		end

		metal(
			("Tip%s"):format(if side == 1 then "Up" else "Down"),
			Vector3.new(0.09, 0.28, 0.11),
			cursor * CFrame.new(0, 0.12, 0),
			IRON_DARK
		)
	end

	metal("Eye", Vector3.new(0.52, 0.62, 0.62), HEAD_AT, IRON_DARK)
	metal("Wedge", Vector3.new(0.30, 0.18, 0.42), HEAD_AT * CFrame.new(0, 0.42, 0), IRON)

	local ferrule = Instance.new("Part")
	ferrule.Name = "Ferrule"
	ferrule.Shape = Enum.PartType.Cylinder
	ferrule.Size = Vector3.new(0.34, 0.42, 0.42)
	ferrule.Material = Enum.Material.Metal
	ferrule.Color = IRON_DARK
	attach(ferrule, CFrame.new(0, 0, -1.38) * CFrame.Angles(0, math.rad(90), 0))

	local grip = Instance.new("Part")
	grip.Name = "GripWrap"
	grip.Shape = Enum.PartType.Cylinder
	grip.Size = Vector3.new(1.1, 0.42, 0.42)
	grip.Material = Enum.Material.Fabric
	grip.Color = Color3.fromRGB(64, 48, 36)
	attach(grip, CFrame.new(0, 0, 1.28) * CFrame.Angles(0, math.rad(90), 0))

	local butt = Instance.new("Part")
	butt.Name = "Butt"
	butt.Shape = Enum.PartType.Cylinder
	butt.Size = Vector3.new(0.22, 0.40, 0.40)
	butt.Material = Enum.Material.Wood
	butt.Color = Color3.fromRGB(96, 66, 40)
	attach(butt, CFrame.new(0, 0, 1.98) * CFrame.Angles(0, math.rad(90), 0))

	return tool
end

local pickaxe = buildPickaxe()
pickaxe.Parent = StarterPack

-- ---------------------------------------------------------------- lighting
-- Lighting.Technology is not scriptable from a normal script and the MCP cannot
-- write it either. If the place still looks flat, set it by hand in
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

print(("[Medieval Land] Board built: %dx%d tiles, %d stone nodes, %d castle plots."):format(
	GRID, GRID, nodeCount, plotCount
))

end
