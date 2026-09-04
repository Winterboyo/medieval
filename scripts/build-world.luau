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

-- ---------------------------------------------------------------- the island
-- This used to be a 7x7 board of flat square tiles - a Catan grid, deliberately
-- legible and deliberately artificial. It is now an ISLAND: an irregular
-- landmass with real relief, beaches, and open water all the way round.
--
-- The square had to go because it read as a diagram no matter how well the seams
-- between tiles were blended. You cannot hide a grid; you can only decorate it.
--
-- What survives the change is the part that was load bearing: resources are
-- still grouped into REGIONS you have to travel between, because the whole
-- economy rests on that. The regions are just organic now - they follow height
-- and a noise field instead of a lattice - so you cross from forest into hills
-- without ever seeing a boundary.
-- Generously bigger than the island so the SQUARE EDGE of the terrain region is
-- far enough out to sit behind the haze. Ocean chunks are cheap - each one is
-- about a dozen voxels tall once its vertical range is fitted to its contents -
-- so the extra water costs far less than the extra land would.
local MAP_SIZE = 3200 -- the terrain region; the island sits well inside it
local SEA_LEVEL = 0
local SEA_FLOOR = -46

-- Nominal radius. The coastline wanders either side of it by COAST_WANDER, so
-- the island is never a disc.
local ISLAND_RADIUS = 880
local COAST_WANDER = 205
local PEAK_HEIGHT = 118

local VOXEL = 4 -- terrain resolution; every region has to be aligned to this
local CHUNK = 256 -- studs per WriteVoxels call

-- Published so MatchService can size the closing boundary off the world instead
-- of restating it. Same contract as the old BoardHalf, new shape.
local ISLAND_HALF = ISLAND_RADIUS + COAST_WANDER
Workspace:SetAttribute("BoardHalf", ISLAND_HALF)
Workspace:SetAttribute("WorldShape", "Island")

local rng = Random.new(20260903)

-- ---------------------------------------------------------------- surfaces
-- MaterialVariants generated for this place. They cost nothing at runtime - a
-- variant is a skin on an existing base material, not new geometry - and they
-- are the difference between "Roblox Sandstone" and a wall somebody plastered.
--
-- Each name must match a MaterialVariant under MaterialService, and each must be
-- applied together with the BASE material it was generated against, or Roblox
-- ignores the variant and you get the stock texture with no warning.
local SKIN = {
	thatch = { material = Enum.Material.Grass, variant = "MedievalThatch" },
	daub = { material = Enum.Material.Sandstone, variant = "MedievalDaub" },
	cobble = { material = Enum.Material.Cobblestone, variant = "MedievalCobble" },
	oreRock = { material = Enum.Material.Rock, variant = "MedievalOreRock" },
	wheat = { material = Enum.Material.Grass, variant = "MedievalWheat" },
}

local function skin(part: BasePart, which)
	part.Material = which.material
	part.MaterialVariant = which.variant
end

-- Check the variants can actually be resolved, LOUDLY.
--
-- Roblox matches BasePart.MaterialVariant against the DIRECT children of
-- MaterialService and nothing else. A name it cannot find is not an error: the
-- part quietly renders as its base material, so 800 parts can be wearing a skin
-- that does not exist and the only symptom is that the world looks like stock
-- Roblox. The generator drops new variants into a nested folder, so this is the
-- normal case rather than the exotic one.
do
	local MaterialService = game:GetService("MaterialService")
	local absent: { string } = {}
	for _, which in SKIN do
		local found = MaterialService:FindFirstChild(which.variant)
		if not (found and found:IsA("MaterialVariant")) then
			absent[#absent + 1] = which.variant
		end
	end
	if #absent > 0 then
		warn(("[Medieval Land] these MaterialVariants are not direct children of "
			.. "MaterialService, so every part using them will silently fall back "
			.. "to its base material: %s"):format(table.concat(absent, ", ")))
	end
end

-- A fixed seed for the terrain itself, separate from the rng above, so that
-- changing how many trees a forest has does not reshape the coastline.
local LAND_SEED = 71.3
local RELIEF_SEED = 12.9

-- ---------------------------------------------------------------- the shape
-- One height function, sampled by the terrain writer, by node placement and by
-- village placement. Everything agrees about where the land is because
-- everything asks the same question.
local function heightAt(x: number, z: number): number
	local distance = math.sqrt(x * x + z * z)
	-- Warp the radius by low-frequency noise: this is what turns a circle into
	-- a coastline with bays and headlands.
	-- Three octaves, each CLAMPED. math.noise is documented as roughly -0.5..0.5
	-- but overshoots, and multiplying the raw value pushed the coast in as far
	-- as r=350 on one bearing while leaving it past 900 on another - not a
	-- wandering coastline, a bite out of the island.
	--
	-- One octave gave a near-circle. Bays and headlands need scale: a broad
	-- lobe, a bay inside it, an inlet inside that.
	-- The frequencies matter more than the amplitudes. At 0.0007 a full lap of
	-- the coast covers well under one unit of noise space, so the field barely
	-- changes and the island comes out a circle whatever COAST_WANDER says -
	-- measured at 760..940 across sixteen bearings, a 12% wobble. These give
	-- roughly eight features around the shoreline instead of one.
	local wander =
		math.clamp(math.noise(x * 0.00165, z * 0.00165, LAND_SEED), -1, 1) * COAST_WANDER
		+ math.clamp(math.noise(x * 0.00380, z * 0.00380, LAND_SEED + 3), -1, 1) * COAST_WANDER * 0.50
		+ math.clamp(math.noise(x * 0.00760, z * 0.00760, LAND_SEED + 7), -1, 1) * COAST_WANDER * 0.22
	local edge = ISLAND_RADIUS + wander
	local t = 1 - math.clamp(distance / math.max(edge, 1), 0, 1)
	if t <= 0 then
		return SEA_FLOOR
	end

	-- Smoothstep inland, then flatten the middle a little. Raised to a power
	-- below 1 the dome stops being a cone with one summit and becomes a broad
	-- interior with room for several.
	local inland = t * t * (3 - 2 * t)
	local plateau = inland ^ 0.75

	-- Three octaves. The first cut used two and produced a smooth dome that fell
	-- away monotonically from the centre - a transect read 68, 68, 23, 6, which
	-- is a hillside, not a landscape. Relief has to be able to cut DOWN as well
	-- as up, which is why it is added signed rather than clamped positive.
	local relief = math.noise(x * 0.0026, z * 0.0026, RELIEF_SEED)
		+ 0.50 * math.noise(x * 0.0061, z * 0.0061, RELIEF_SEED + 5)
		+ 0.25 * math.noise(x * 0.0130, z * 0.0130, RELIEF_SEED + 9)

	-- A quick rise out of the water so beaches are narrow, then relief. The
	-- relief is scaled by how far inland you are so the coast stays low and the
	-- interior gets the drama.
	local shore = math.clamp(t * 7, 0, 1)
	local body = plateau * PEAK_HEIGHT * 0.58
	local broken = plateau * relief * PEAK_HEIGHT * 0.46
	return math.max(shore * 4, shore * 4 + body + broken)
end

-- ---------------------------------------------------------------- regions
-- Biomes are VORONOI CELLS, not thresholds on a noise field.
--
-- The previous version already snapped every voxel to exactly one material - it
-- never interpolated - but it read as mud anyway, and the reason is worth
-- writing down. Slicing one smooth noise field with thresholds puts the
-- boundary wherever the field happens to cross a number, and a smooth field
-- crosses a number many times in the same neighbourhood. You get tendrils,
-- fringes and little marooned islands of one material inside another, because
-- the boundary is a contour line of a wobbly surface rather than an edge.
-- Three similar earthy materials cut from the same field made that worse: their
-- boundaries interleaved instead of separating.
--
-- A Voronoi partition has the property being asked for by construction: every
-- point belongs to exactly one region, every region is contiguous, and the
-- boundary between two of them is a line. Warping the lookup position with a
-- little noise first keeps the edges from being suspiciously straight without
-- softening them - the edge is still a hard line, it is just not a chord.
-- A WEIGHTED CYCLE, not one of each. Round-robin over five materials gave the
-- two rock ones half the island between them, which reads as a quarry rather
-- than somewhere people farm. Seeds are dealt from this list in order, so the
-- proportions are exact rather than left to luck, and consecutive seeds still
-- differ - neighbouring regions contrast.
--
-- Over fifteen seeds this deals Grass 5, Mud 4, LeafyGrass 3, Slate 2, Basalt 1.
local REGION_MATERIALS = {
	Enum.Material.Grass,
	Enum.Material.Mud,
	Enum.Material.LeafyGrass,
	Enum.Material.Slate,
	Enum.Material.Grass,
	Enum.Material.Mud,
	Enum.Material.LeafyGrass,
	Enum.Material.Basalt,
	Enum.Material.Grass,
	Enum.Material.Mud,
}

local REGION_SEEDS = 15
local REGION_MIN_GAP = 250
local REGION_WARP = 120
local WARP_SEED = 63.7

type Region = { x: number, z: number, material: Enum.Material }
local regions: { Region } = {}

do
	-- Deliberately its own generator, seeded separately. Changing how many trees
	-- a forest has should not redraw the map.
	local seedRng = Random.new(90210)
	local attempts = 0
	while #regions < REGION_SEEDS and attempts < 4000 do
		attempts += 1
		local angle = seedRng:NextNumber(0, math.pi * 2)
		local radius = math.sqrt(seedRng:NextNumber(0, 1)) * ISLAND_RADIUS * 0.94
		local x, z = math.cos(angle) * radius, math.sin(angle) * radius
		local ok = true
		for _, other in regions do
			if (Vector2.new(x - other.x, z - other.z)).Magnitude < REGION_MIN_GAP then
				ok = false
				break
			end
		end
		if ok then
			-- Round robin rather than random, so every material is guaranteed to
			-- appear and no single one can swamp the island by luck.
			local material = REGION_MATERIALS[(#regions % #REGION_MATERIALS) + 1]
			regions[#regions + 1] = { x = x, z = z, material = material }
		end
	end
end

-- Which region a point falls in. Beach and summit still win outright: those are
-- real bands that follow the water and the tops, and they are legible precisely
-- because they are narrow and everywhere.
local function biomeAt(x: number, z: number, height: number): Enum.Material
	if height < 3.0 then
		return Enum.Material.Sand
	end
	-- 68, not 80. The island tops out around 82, so a threshold of 80 caught
	-- three sample cells in the whole world - a summit band that does not exist
	-- is not a region, it is a rounding error. At 68 the high ground actually
	-- reads as bare rock, which also tells a player where the ore is.
	if height > 68 then
		return Enum.Material.Rock
	end

	local warpX = x + math.noise(x * 0.0024, z * 0.0024, WARP_SEED) * REGION_WARP
	local warpZ = z + math.noise(x * 0.0024, z * 0.0024, WARP_SEED + 31) * REGION_WARP

	local best = regions[1]
	local bestDistance = math.huge
	for _, region in regions do
		local dx, dz = warpX - region.x, warpZ - region.z
		local distance = dx * dx + dz * dz -- squared; the ordering is all we need
		if distance < bestDistance then
			best = region
			bestDistance = distance
		end
	end
	return best.material
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
-- Written as VOXELS rather than filled as blocks. FillBlock can only place
-- rectangular solids, which is exactly why the old map was rectangular solids;
-- WriteVoxels sets a material and an occupancy per cell, so a column can end
-- part way through a voxel and the surface comes out smooth instead of stepped.
--
-- Done in chunks because one call covering the whole map would be millions of
-- cells. Each chunk is CHUNK studs square and spans the full height range.
local Y_BOTTOM = SEA_FLOOR - 12

local function writeChunk(originX: number, originZ: number)
	-- Size the vertical range to what is actually in THIS chunk. Spanning the
	-- full world height everywhere would be ~14 million cells, almost all of
	-- them empty sky over open water, and the Lua tables alone would take
	-- minutes to build. Sampling a coarse grid and padding generously turns a
	-- deep-ocean chunk into about a dozen voxels tall.
	local tallest = SEA_FLOOR
	for sx = 0, 4 do
		for sz = 0, 4 do
			local h = heightAt(originX + sx * CHUNK / 4, originZ + sz * CHUNK / 4)
			tallest = math.max(tallest, h)
		end
	end
	local ceiling = math.max(SEA_LEVEL, tallest) + VOXEL * 4

	local region = Region3.new(
		Vector3.new(originX, Y_BOTTOM, originZ),
		Vector3.new(originX + CHUNK, ceiling, originZ + CHUNK)
	):ExpandToGrid(VOXEL)

	local size = region.Size
	local countX = math.floor(size.X / VOXEL)
	local countY = math.floor(size.Y / VOXEL)
	local countZ = math.floor(size.Z / VOXEL)
	local base = region.CFrame.Position - size / 2

	local materials = table.create(countX)
	local occupancies = table.create(countX)

	-- Height and biome depend only on x and z, so they are resolved ONCE per
	-- column. They used to be recomputed for every voxel in the column, which
	-- meant heightAt ran tens of times per surface point for no reason - and a
	-- Voronoi lookup could not have afforded that.
	local columnHeight = table.create(countX)
	local columnBiome = table.create(countX)
	for ix = 1, countX do
		local worldX = base.X + (ix - 0.5) * VOXEL
		local heightRow = table.create(countZ)
		local biomeRow = table.create(countZ)
		for iz = 1, countZ do
			local worldZ = base.Z + (iz - 0.5) * VOXEL
			local height = heightAt(worldX, worldZ)
			heightRow[iz] = height
			biomeRow[iz] = biomeAt(worldX, worldZ, height)
		end
		columnHeight[ix] = heightRow
		columnBiome[ix] = biomeRow
	end

	for ix = 1, countX do
		local columnMaterials = table.create(countY)
		local columnOccupancies = table.create(countY)
		local heightRow = columnHeight[ix]
		local biomeRow = columnBiome[ix]

		for iy = 1, countY do
			local rowMaterials = table.create(countZ)
			local rowOccupancies = table.create(countZ)
			local voxelBottom = base.Y + (iy - 1) * VOXEL

			for iz = 1, countZ do
				local height = heightRow[iz]

				-- How much of this voxel is below the ground surface, and how
				-- much is below the waterline. Fractional occupancy at the top
				-- cell is the whole reason the result looks like a hill and not
				-- like a staircase.
				local groundFill = math.clamp((height - voxelBottom) / VOXEL, 0, 1)
				local waterFill = math.clamp((SEA_LEVEL - voxelBottom) / VOXEL, 0, 1)

				if groundFill > 0.02 then
					rowMaterials[iz] = biomeRow[iz]
					rowOccupancies[iz] = groundFill
				elseif waterFill > 0.02 then
					rowMaterials[iz] = Enum.Material.Water
					rowOccupancies[iz] = waterFill
				else
					rowMaterials[iz] = Enum.Material.Air
					rowOccupancies[iz] = 0
				end
			end

			columnMaterials[iy] = rowMaterials
			columnOccupancies[iy] = rowOccupancies
		end

		materials[ix] = columnMaterials
		occupancies[ix] = columnOccupancies
	end

	Terrain:WriteVoxels(region, VOXEL, materials, occupancies)
end

do
	local half = MAP_SIZE / 2
	local from = -half
	while from < half do
		local acrossZ = -half
		while acrossZ < half do
			writeChunk(from, acrossZ)
			acrossZ += CHUNK
		end
		from += CHUNK
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

-- ---------------------------------------------------------------- board folder
-- The seam-blending pass that used to live here existed to disguise the joins
-- between square tiles. There are no tiles now, so there is nothing to disguise:
-- the biome boundary is wherever a noise field crosses a threshold, which is
-- already an irregular curve.
local board = Instance.new("Folder")
board.Name = "MedievalLand_Board"
board.Parent = Workspace

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

-- The variant argument is optional and last, so every existing call site is
-- unaffected by its arrival.
local function newPart(name: string, size: Vector3, cframe: CFrame, parent: Instance,
	variant: string?): Part
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
			skin(stalk, SKIN.wheat)
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
		if isOre then
			-- Ore country looks different from ordinary hill stone before you
			-- swing at it, which is the whole point of walking to it.
			part.MaterialVariant = SKIN.oreRock.variant
		end
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

-- ---------------------------------------------------------------- placement
-- Nodes and villages both need the same thing: a spot that is on land, not too
-- steep to stand a building on, and far enough from everything already placed.
-- So they share one sampler.
--
-- This replaces a lattice. A tile used to BE its node, which made placement
-- trivial and the map a chessboard. Now candidates are thrown at the island and
-- rejected until they fit, which is slower to write and the only way to get a
-- distribution that does not look authored.
-- Two registers, not one. The first cut kept a single list and made villages
-- stay 250 studs from EVERYTHING already placed, nodes included - so once 48
-- nodes were down there was nowhere left, and it placed zero villages without
-- complaining. A village needs distance from other villages; it only needs
-- elbow room from a node.
local nodeSpots: { Vector2 } = {}
local plotSpots: { Vector2 } = {}

local function clearOf(list: { Vector2 }, point: Vector2, gap: number): boolean
	if gap <= 0 then
		return true
	end
	for _, other in list do
		if (other - point).Magnitude < gap then
			return false
		end
	end
	return true
end

-- Steepness matters: a node on a cliff face half-buries itself, and a village
-- foundation on a slope floats at one corner and sinks at the other. Sampled as
-- the largest height difference across a short cross.
local function slopeAt(x: number, z: number, reach: number): number
	local here = heightAt(x, z)
	local worst = 0
	for _, offset in { Vector2.new(reach, 0), Vector2.new(-reach, 0),
		Vector2.new(0, reach), Vector2.new(0, -reach) } do
		worst = math.max(worst, math.abs(heightAt(x + offset.X, z + offset.Y) - here))
	end
	return worst
end

-- Throw darts at the island until one sticks. Returns nil if the island simply
-- has no room left, which the callers treat as "stop asking".
type Spec = {
	minHeight: number,
	maxHeight: number,
	maxSlope: number,
	gapNodes: number,
	gapPlots: number,
	clearOfCentre: number,
	attempts: number,
}

local function findSpot(spec: Spec): Vector2?
	for _ = 1, spec.attempts do
		local angle = rng:NextNumber(0, math.pi * 2)
		local distance = math.sqrt(rng:NextNumber(0, 1)) * (ISLAND_RADIUS + COAST_WANDER * 0.5)
		local point = Vector2.new(math.cos(angle) * distance, math.sin(angle) * distance)
		if point.Magnitude >= spec.clearOfCentre then
			local height = heightAt(point.X, point.Y)
			if height >= spec.minHeight and height <= spec.maxHeight
				and slopeAt(point.X, point.Y, 14) <= spec.maxSlope
				and clearOf(nodeSpots, point, spec.gapNodes)
				and clearOf(plotSpots, point, spec.gapPlots)
			then
				return point
			end
		end
	end
	return nil
end

-- Each resource gets a QUOTA and its own stretch of terrain to look in.
--
-- The first cut let terrain alone decide, sampling anywhere and asking "what
-- belongs here?". The answer came back Grain 19, Wood 18, Wool 9, Stone 2, Ore
-- 0 - because the same slope limit that keeps a node off a cliff also keeps it
-- off every mountain, so the high ground where stone and ore live was filtered
-- out before it was ever classified. An economy missing an entire resource is
-- not a distribution quirk, it is a broken game.
--
-- So the quota comes first and the terrain search bends to it: stone and ore
-- look high and tolerate steeper ground, grain looks low and flat.
local NODE_PLAN = {
	{ resource = "Wood", count = 11, minHeight = 5, maxHeight = 48, maxSlope = 16 },
	{ resource = "Grain", count = 10, minHeight = 3, maxHeight = 32, maxSlope = 10 },
	{ resource = "Wool", count = 10, minHeight = 5, maxHeight = 42, maxSlope = 15 },
	{ resource = "Stone", count = 9, minHeight = 24, maxHeight = 96, maxSlope = 30 },
	-- Ore sat empty at minHeight 40 because the only ground that high was inside
	-- the centre exclusion. It looks lower and is allowed nearer the middle.
	{ resource = "Ore", count = 8, minHeight = 30, maxHeight = 160, maxSlope = 38 },
}

local nodeCount = 0
local shortfall: { string } = {}
for _, plan in NODE_PLAN do
	local placed = 0
	for _ = 1, plan.count do
		local spot = findSpot({
			minHeight = plan.minHeight,
			maxHeight = plan.maxHeight,
			maxSlope = plan.maxSlope,
			gapNodes = 104,
			gapPlots = 0,
			clearOfCentre = 165,
			attempts = 900,
		})
		if not spot then
			break
		end
		nodeSpots[#nodeSpots + 1] = spot
		nodeCount += 1
		placed += 1

		local origin = Vector3.new(spot.X, 0, spot.Y)
		local name = ("%s_%02d"):format(plan.resource, nodeCount)
		if plan.resource == "Wood" then
			makeForest(name, origin)
		elseif plan.resource == "Wool" then
			makePasture(name, origin)
		elseif plan.resource == "Grain" then
			makeField(name, origin)
		else
			makeOutcrop(name, origin, plan.resource)
		end
	end
	if placed < plan.count then
		shortfall[#shortfall + 1] = ("%s %d/%d"):format(plan.resource, placed, plan.count)
	end
end
if #shortfall > 0 then
	-- Loud on purpose. A quiet shortfall is how the map ended up with no ore.
	warn("[Medieval Land] the island had no room for: " .. table.concat(shortfall, ", "))
end

-- The plaza terrace, declared here because the plaza is built before villages
-- are. Same idea as terraceFor below: fill to a level, then clear above it.
local function terraceForPlaza(centre: Vector2, half: number, height: number)
	Terrain:FillCylinder(
		CFrame.new(centre.X, (SEA_FLOOR + height) / 2, centre.Y),
		height - SEA_FLOOR, half, Enum.Material.Ground
	)
	Terrain:FillCylinder(
		CFrame.new(centre.X, height + 100, centre.Y),
		200, half, Enum.Material.Air
	)
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

-- The plaza is the one fixed point on the island, and the zone closes onto it,
-- so it gets a terrace like the villages do. Without this the totem stands on
-- whatever slope the noise happened to put at the origin.
terraceForPlaza(Vector2.new(0, 0), 150, math.max(heightAt(0, 0), 12))
local plazaGround = groundHeight(0, 0)

local function plazaPart(name: string, size: Vector3, cframe: CFrame,
	material: Enum.Material, color: Color3, variant: string?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.Material = material
	if variant then
		part.MaterialVariant = variant
	end
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
	Enum.Material.Cobblestone, Color3.fromRGB(150, 144, 132), SKIN.cobble.variant)

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

local oldMessenger = ServerStorage:FindFirstChild("MessengerTemplate")
if oldMessenger then
	oldMessenger:Destroy()
end
-- The template itself is BUILT further down, immediately after the function that
-- makes it. Calling it here - above the declaration - was a call on a nil global,
-- which threw and took the villages, the tools and the entire lighting pass with
-- it. See the note on makeMessengerTemplate.

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
	material: Enum.Material, color: Color3, variant: string?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.Material = material
	if variant then
		part.MaterialVariant = variant
	end
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
-- Roofs used to be Slate with a thatch-coloured tint, which is a yellow slate
-- roof and reads as one. A thatch roof needs a thatch SURFACE.
local function gable(parent: Instance, eaves: CFrame, width: number, depth: number,
	height: number, color: Color3, roofSkin)
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
		if roofSkin then
			skin(half, roofSkin)
		else
			half.Material = Enum.Material.Slate
		end
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
	wallMaterial: Enum.Material, wallVariant: string?, roofSkin: any?)
	sitePart(into, "Floor", Vector3.new(width, 0.6, depth), at * CFrame.new(0, 0.3, 0),
		Enum.Material.WoodPlanks, Color3.fromRGB(126, 96, 62))

	sitePart(into, "WallBack", Vector3.new(width, wallHeight, WALL_THICK),
		at * CFrame.new(0, wallHeight / 2, -depth / 2 + WALL_THICK / 2), wallMaterial, wallColor,
		wallVariant)
	for _, sx in { -1, 1 } do
		sitePart(into, "WallSide", Vector3.new(WALL_THICK, wallHeight, depth),
			at * CFrame.new(sx * (width / 2 - WALL_THICK / 2), wallHeight / 2, 0),
			wallMaterial, wallColor, wallVariant)
	end

	-- The front, split around the doorway, with a lintel bridging the gap.
	local cheek = (width - doorWidth) / 2
	for _, sx in { -1, 1 } do
		sitePart(into, "WallFront", Vector3.new(cheek, wallHeight, WALL_THICK),
			at * CFrame.new(sx * (doorWidth + cheek) / 2, wallHeight / 2, depth / 2 - WALL_THICK / 2),
			wallMaterial, wallColor, wallVariant)
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
		wallHeight * 0.8, roofColor, roofSkin)
end

-- --- the four villager houses, deliberately identical -------------
local HOUSE = { width = 17, depth = 15, wallHeight = 9, door = 4.6 }

-- A villager standing outside their door. Four parts, no animation, no AI: the
-- point is only that a built cottage visibly houses SOMEBODY, because from this
-- tier a cottage is a labourer rather than scenery.
local function makeVillager(into: Instance, at: CFrame, shirt: Color3)
	local figure = Instance.new("Model")
	figure.Name = "Villager"
	sitePart(figure, "Legs", Vector3.new(1.5, 2.2, 1.1), at * CFrame.new(0, 1.1, 0),
		Enum.Material.Fabric, Color3.fromRGB(74, 62, 52))
	sitePart(figure, "Torso", Vector3.new(1.9, 2.4, 1.2), at * CFrame.new(0, 3.4, 0),
		Enum.Material.Fabric, shirt)
	sitePart(figure, "Head", Vector3.new(1.2, 1.2, 1.2), at * CFrame.new(0, 5.2, 0),
		Enum.Material.SmoothPlastic, Color3.fromRGB(214, 176, 140))
	sitePart(figure, "Hat", Vector3.new(1.7, 0.5, 1.7), at * CFrame.new(0, 5.9, 0),
		Enum.Material.Fabric, Color3.fromRGB(126, 98, 62))
	figure.Parent = into
end

-- The messenger. Built once into ServerStorage and cloned whenever a
-- negotiation opens, because unlike everything else in this file it appears at
-- runtime rather than at world build.
--
-- It is a PHYSICAL figure rather than a dialog box on purpose: DESIGN.md wants
-- either side to be able to escalate by killing the messenger, and if the
-- messenger is a real thing standing in your village then killing it is just
-- swinging at it - the combat that already exists - instead of a button that
-- says "kill messenger".
local function makeMessengerTemplate(): Model
	local figure = Instance.new("Model")
	figure.Name = "MessengerTemplate"

	local torso = sitePart(figure, "Torso", Vector3.new(2.0, 2.6, 1.3),
		CFrame.new(0, 3.5, 0), Enum.Material.Fabric, Color3.fromRGB(96, 74, 116))
	figure.PrimaryPart = torso

	sitePart(figure, "Legs", Vector3.new(1.6, 2.4, 1.2), CFrame.new(0, 1.2, 0),
		Enum.Material.Fabric, Color3.fromRGB(64, 56, 70))
	sitePart(figure, "Head", Vector3.new(1.3, 1.3, 1.3), CFrame.new(0, 5.4, 0),
		Enum.Material.SmoothPlastic, Color3.fromRGB(214, 176, 140))
	-- A tabard, so a messenger is not mistaken for a villager at a glance.
	sitePart(figure, "Tabard", Vector3.new(2.2, 1.6, 1.5), CFrame.new(0, 3.4, 0),
		Enum.Material.Fabric, Color3.fromRGB(150, 62, 58))
	-- The staff and its pennant: the thing you can see over a wall.
	sitePart(figure, "Staff", Vector3.new(0.3, 8, 0.3), CFrame.new(1.4, 4, 0),
		Enum.Material.Wood, TIMBER)
	sitePart(figure, "Pennant", Vector3.new(0.2, 1.8, 2.4), CFrame.new(1.4, 7.2, 1.2),
		Enum.Material.Fabric, Color3.fromRGB(214, 196, 132))
	sitePart(figure, "Scroll", Vector3.new(0.5, 0.5, 1.6), CFrame.new(-1.2, 3.6, 0.5),
		Enum.Material.Sandstone, Color3.fromRGB(226, 214, 184))

	return figure
end

-- Built here rather than up with the other ServerStorage teardown, because in
-- Lua a name does not exist until its declaration has run. Calling this from
-- line ~700 resolved to a nil GLOBAL: it parsed perfectly, threw at runtime, and
-- silently truncated the world at the resource nodes - no villages, no tools, no
-- lighting. Keep the call below the function.
makeMessengerTemplate().Parent = ServerStorage

local VILLAGER_SHIRTS = {
	Color3.fromRGB(122, 96, 72),
	Color3.fromRGB(96, 108, 88),
	Color3.fromRGB(134, 110, 96),
	Color3.fromRGB(104, 96, 116),
}

local function makeVillagerHouse(into: Instance, at: CFrame, index: number)
	hollowBuilding(into, at, HOUSE.width, HOUSE.depth, HOUSE.wallHeight, HOUSE.door,
		DAUB, THATCH, Enum.Material.Sandstone, SKIN.daub.variant, SKIN.thatch)
	for _, sx in { -1, 1 } do
		sitePart(into, "Window", Vector3.new(1.8, 1.8, 0.3),
			at * CFrame.new(sx * HOUSE.width * 0.34, 5.4, HOUSE.depth / 2),
			Enum.Material.Glass, Color3.fromRGB(62, 72, 68))
	end
	makeVillager(into, at * CFrame.new(HOUSE.width * 0.3, 0, HOUSE.depth / 2 + 3)
		* CFrame.Angles(0, math.rad(196), 0),
		VILLAGER_SHIRTS[((index - 1) % #VILLAGER_SHIRTS) + 1])
end

-- --- the three workshops, each unmistakably itself ----------------
local SHOP = { width = 23, depth = 19, wallHeight = 11, door = 5.2 }

-- A workshop carries two prompts on the same part: work it, and train the
-- specialist working it. Different keyboard keys, because ProximityPrompt
-- exclusivity is per BUTTON - two prompts on one part is fine as long as they do
-- not compete for the same key.
--
-- Both stay at bench height. A prompt about five studs over the character was
-- measured refusing to activate at nine studs while the same prompt lowered to
-- head height fired at seven.
--
-- The RECIPE and the training costs live in ResourceService, which is where game
-- rules live; these only say which role to look up.
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

	local train = Instance.new("ProximityPrompt")
	train.Name = "TrainPrompt"
	train.ActionText = "Train"
	train.ObjectText = label
	train.KeyboardKeyCode = Enum.KeyCode.R
	train.GamepadKeyCode = Enum.KeyCode.ButtonY
	train.HoldDuration = 0.5
	train.MaxActivationDistance = 16
	train.RequiresLineOfSight = false
	train:SetAttribute("Role", recipe)
	train.Parent = host
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
		Color3.fromRGB(150, 142, 162), Color3.fromRGB(78, 62, 104), Enum.Material.Sandstone,
		SKIN.daub.variant)
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
		Enum.Material.Cobblestone, Color3.fromRGB(148, 142, 130), SKIN.cobble.variant)
	sitePart(site, "StreetCross", Vector3.new(112, 0.3, 10), at(0, 6, 0),
		Enum.Material.Cobblestone, Color3.fromRGB(148, 142, 130), SKIN.cobble.variant)

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
		makeVillagerHouse(stage(i), at(spot.x, spot.z, spot.yaw), i)
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

-- A village needs FLAT ground. Its foundation is a single 148 stud slab, so on
-- a hillside it floats at one corner and buries itself at the other. Cut a
-- terrace: fill solid up to the pad height, then clear everything above it.
local function terraceFor(centre: Vector2, half: number, height: number)
	-- ROUND, not square. Sixteen square terraces cut into an island read from
	-- the air as sixteen brown plates - the grid the whole redesign was meant to
	-- get rid of, reintroduced by the flattening. A cylinder just wide enough to
	-- carry the corners of the foundation leaves a circular shelf instead.
	local radius = half * math.sqrt(2) + 6
	Terrain:FillCylinder(
		CFrame.new(centre.X, (SEA_FLOOR + height) / 2, centre.Y),
		height - SEA_FLOOR, radius, Enum.Material.Ground
	)
	Terrain:FillCylinder(
		CFrame.new(centre.X, height + 100, centre.Y),
		200, radius, Enum.Material.Air
	)
end

-- Roughly a dozen claimable plots, which is the player count Conquest is written
-- for. Thrown at the island rather than laid on a lattice, kept clear of the
-- totem so nobody spawns straight into somebody's keep, and kept well apart from
-- each other and from the nodes because they share the one spacing table.
local PLOT_TARGET = 16
local PLOT_SPACING = 250

local plotCount = 0
for _ = 1, PLOT_TARGET do
	local spot = findSpot({
		minHeight = 7,
		maxHeight = 58,
		maxSlope = 14,
		gapNodes = 86, -- elbow room from a node, not the full village spacing
		gapPlots = PLOT_SPACING,
		clearOfCentre = 300,
		attempts = 1400,
	})
	if not spot then
		break
	end
	plotSpots[#plotSpots + 1] = spot
	plotCount += 1
	terraceFor(spot, PLOT / 2, heightAt(spot.X, spot.Y))
	makePlot(("Base_%02d"):format(plotCount), spot)
end
if plotCount < PLOT_TARGET then
	warn(("[Medieval Land] only %d of %d village plots fit on the island"):format(
		plotCount, PLOT_TARGET))
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
-- No Technology line here on purpose. Roblox migrated this place to unified
-- lighting, so Enum.Technology is legacy and the property is not scriptable
-- anyway - it cannot even be READ from a plugin thread ("lacking capability
-- RobloxScript"). The old pcall that tried to set it was dead code pretending
-- to be a safeguard. Style is set by hand: Lighting -> LightingStyle -> Realistic.

-- A LOW SUN. The old 14.6 put it almost overhead, which is the flattest light
-- there is: nothing casts a shadow long enough to give a building form, and the
-- island read as a painted map. Late afternoon gives every wall a lit face and a
-- dark one, which is most of what makes geometry legible.
Lighting.ClockTime = 16.1
Lighting.GeographicLatitude = 12
Lighting.GlobalShadows = true
Lighting.ShadowSoftness = 0.22

-- Brightness 3 with exposure above zero was blowing the ground out to near
-- white. Pulled down, with the exposure slightly negative to hold the highlights
-- on sand and water.
Lighting.Brightness = 2.1
Lighting.ExposureCompensation = -0.08

-- Warm sun against a cool sky. Ambient is the light in shadow, and making it
-- BLUER than the sun is what stops shadows reading as dirty grey - it is the
-- single cheapest trick in outdoor lighting.
Lighting.Ambient = Color3.fromRGB(58, 62, 74)
Lighting.OutdoorAmbient = Color3.fromRGB(118, 132, 152)
Lighting.EnvironmentDiffuseScale = 0.65
Lighting.EnvironmentSpecularScale = 0.6

-- DepthOfFieldEffect and Sky are in this list because the place file carries a
-- stock Roblox skybox and an unconfigured DoF from the baseplate template. They
-- were never authored, never referenced, and - because they were not in this
-- list - survived every single rebuild.
for _, className in { "Atmosphere", "SunRaysEffect", "ColorCorrectionEffect", "BloomEffect",
	"DepthOfFieldEffect", "Sky" } do
	local existing = Lighting:FindFirstChildOfClass(className)
	if existing then
		existing:Destroy()
	end
end

-- HAZE WAS THE PROBLEM. At 0.9 it washed the far half of the map into a flat
-- cream band and took the horizon with it. Density does the work of "there is
-- air between us"; haze is the milkiness on top, and a little goes a long way.
--
-- Decay is deliberately blue: distant things losing saturation and drifting
-- toward the sky colour is aerial perspective, and it is what gives an island
-- surrounded by water any sense of scale at all.
local atmosphere = Instance.new("Atmosphere")
atmosphere.Density = 0.36
atmosphere.Offset = 0.05
atmosphere.Haze = 0.38
atmosphere.Glare = 0.12
atmosphere.Color = Color3.fromRGB(202, 214, 226)
atmosphere.Decay = Color3.fromRGB(88, 122, 162)
atmosphere.Parent = Lighting

-- Volumetric clouds. Free scale reference: an empty sky over open water gives
-- the eye nothing to judge distance against, and this is one instance.
local oldClouds = Terrain:FindFirstChildOfClass("Clouds")
if oldClouds then
	oldClouds:Destroy()
end
local clouds = Instance.new("Clouds")
clouds.Cover = 0.58
clouds.Density = 0.62
clouds.Color = Color3.fromRGB(255, 253, 248)
clouds.Parent = Terrain

local sunRays = Instance.new("SunRaysEffect")
sunRays.Intensity = 0.14
sunRays.Spread = 0.92
sunRays.Parent = Lighting

local colorCorrection = Instance.new("ColorCorrectionEffect")
colorCorrection.Brightness = 0
colorCorrection.Contrast = 0.14
colorCorrection.Saturation = 0.09
colorCorrection.TintColor = Color3.fromRGB(255, 251, 244)
colorCorrection.Parent = Lighting

-- Threshold raised so bloom picks out the genuinely bright things - the sun on
-- water, the forge, the totem beacon - instead of smearing every pale wall.
local bloom = Instance.new("BloomEffect")
bloom.Intensity = 0.26
bloom.Size = 24
bloom.Threshold = 1.95
bloom.Parent = Lighting

print(("[Medieval Land] Island r~%d, %d nodes, %d village plots, 4 tools."):format(
	ISLAND_RADIUS, nodeCount, plotCount
))

end
