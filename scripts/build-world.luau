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

-- ---------------------------------------------------------------- flatten
-- ONE PLACE DECIDES THE SURFACE LANGUAGE.
--
-- A cartoon world is matte. Every texture - the thatch weave, the daub render,
-- the cobbles, the wheat - is a photographic detail, and photographic detail is
-- the single loudest thing arguing against a drawn look. They were right when
-- the ground was voxel terrain; against a flat-shaded heightfield they read as
-- imports from another game.
--
-- This is a sweep rather than an edit at each call site because there are about
-- twenty of those, each passing its own Enum.Material, and a sweep cannot miss
-- one. Neon and Glass are spared: they are doing a JOB (the totem beacon, the
-- ore glints, the alchemist's brew, windows) rather than describing a surface.
local function flattenSurfaces(root: Instance): number
	local changed = 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			local material = d.Material
			if material ~= Enum.Material.Neon
				and material ~= Enum.Material.Glass
				and material ~= Enum.Material.ForceField
			then
				if material ~= Enum.Material.SmoothPlastic or d.MaterialVariant ~= "" then
					d.Material = Enum.Material.SmoothPlastic
					d.MaterialVariant = ""
					changed += 1
				end
			end
		end
	end
	return changed
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
for _, name in { "MedievalLand_Scenery", "MedievalLand_Board", "ResourceNodes", "BuildSites", "VillageSquare", "SpawnLocation", "Baseplate", "Birds", "MedievalLand_Ground" } do
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
-- The blade is NOT a starting tool - it is forged - so its template lives in
-- ServerStorage and has to be cleared from there instead.
do
	local oldBlade = ServerStorage:FindFirstChild("Blade")
	if oldBlade then
		oldBlade:Destroy()
	end
end
Terrain:Clear()

-- ---------------------------------------------------------------- ground
-- THE GROUND IS GEOMETRY, NOT TERRAIN.
--
-- SmoothTerrain resolves a material per voxel and then blends neighbours at the
-- ENGINE level: it dithers the transition and rounds the surface, both of which
-- are the opposite of what a flat-faceted look needs. That blending is not a
-- setting, so no amount of material tuning reaches it - the previous pass
-- proved it by fixing the assignment logic (hard Voronoi regions, one material
-- per voxel, no interpolation anywhere in this file) and still getting soft,
-- rounded boundaries out of the other end.
--
-- So the ground is built out of parts: a triangulated heightfield, one flat
-- colour per cell, hard edges by construction, because two facets that meet
-- simply have different colours.
--
-- WHAT DID NOT CHANGE: heightAt still draws the island and biomeAt still
-- decides the regions. The shape and the regions are the same; only how they
-- are realised is different.
--
-- WHAT DID CHANGE, beyond looks: the surface is now a PURE FUNCTION instead of
-- something you raycast. Nothing has to exist before something else can ask how
-- high the ground is, which is what lets plot placement stop depending on the
-- order things are built in.

-- Terraces are REGISTERED, NOT CARVED. With voxels a flat village pad meant
-- FillCylinder-ing a shelf into terrain that had already been written: a second
-- destructive pass over a thing that existed. A terrace is now a claim recorded
-- before the ground is generated, and the ground comes out with the claim
-- already in it. No carving, no second pass, no ordering hazard.
type Terrace = { centre: Vector2, radius: number, height: number }
local terraces: { Terrace } = {}

-- Studs of ramp outside the flat pad. A sheer cylinder wall would leave every
-- village unreachable on foot; this lands the shelf into the hillside.
local TERRACE_RAMP = 48 -- one facet cell: the shelf lands in a single row of them

local function registerTerrace(centre: Vector2, radius: number, height: number)
	terraces[#terraces + 1] = { centre = centre, radius = radius, height = height }
end

-- The surface: the island with every registered terrace stamped into it.
-- Returns the height, and whether the point is on worked ground.
--
-- The NEAREST terrace wins rather than the last one found, so two pads whose
-- ramps overlap give one sensible slope instead of whichever was registered
-- second.
local function surfaceInfo(x: number, z: number): (number, boolean)
	local base = heightAt(x, z)
	local nearest: Terrace? = nil
	local nearestDistance = math.huge
	for _, terrace in terraces do
		local distance = (Vector2.new(x, z) - terrace.centre).Magnitude
		if distance < nearestDistance then
			nearest, nearestDistance = terrace, distance
		end
	end
	if not nearest or nearestDistance > nearest.radius + TERRACE_RAMP then
		return base, false
	end
	if nearestDistance <= nearest.radius then
		return nearest.height, true
	end
	local t = (nearestDistance - nearest.radius) / TERRACE_RAMP
	local blend = t * t * (3 - 2 * t) -- smoothstep, so the ramp meets both ends flat
	-- FALSE, not true. The ramp is a natural slope that happens to have been
	-- graded; it is not worked ground and must not be coloured as it. Marking it
	-- worked painted the approach to every village brown, and with seventeen
	-- pads on a 1085 radius island those approaches met: 86% of the map came out
	-- one flat tan, which is what the measurement caught and the eye read as
	-- "it is all sand".
	return nearest.height + (base - nearest.height) * blend, false
end

-- ---------------------------------------------------------------- ground probe
-- This used to raycast the terrain. It evaluates the function instead: exact
-- rather than sampled, correct before any geometry exists, and free of the
-- raycast budget that placing a few hundred props used to spend.
local function groundHeight(x: number, z: number): number
	local height = surfaceInfo(x, z)
	return height
end

-- ---------------------------------------------------------------- facets
-- Saturated and separated on purpose. These are not the muted tints the voxel
-- world wore: a flat-shaded facet shows its colour honestly, with no texture to
-- mediate it, so the colour carries the whole read of the terrain type.
local GROUND_COLOUR: { [Enum.Material]: Color3 } = {
	-- CHROMA, NOT GREY. The realistic instinct is to desaturate rock and dirt
	-- towards grey and brown, and that instinct is what was keeping this map
	-- looking like a landscape rather than a drawing. Cartoon rock is BLUE, and
	-- cartoon dirt is orange; nothing in an animated film is actually grey.
	[Enum.Material.Sand] = Color3.fromRGB(252, 222, 138),
	[Enum.Material.Grass] = Color3.fromRGB(106, 208, 72),
	[Enum.Material.LeafyGrass] = Color3.fromRGB(158, 226, 86),
	[Enum.Material.Mud] = Color3.fromRGB(178, 116, 58),
	-- Violet, not blue. At (122,146,190) the slate regions read as LAKES from
	-- the air - a large cool-blue patch beside a cyan sea is a body of water
	-- until you look twice, and a player should never have to look twice at
	-- whether ground is ground.
	[Enum.Material.Slate] = Color3.fromRGB(146, 138, 198),
	[Enum.Material.Basalt] = Color3.fromRGB(88, 94, 136),
	-- Grey stone, not white. At 162 it read as snow, which is a different
	-- climate from the one the rest of the palette describes.
	[Enum.Material.Rock] = Color3.fromRGB(176, 184, 212),
}
local WORKED_COLOUR = Color3.fromRGB(202, 160, 104) -- terraces: turned earth

-- 48 studs a side. The brief is chunky and deliberate, and this is about as
-- coarse as the island tolerates before a village pad stops being able to hold
-- its own shape. It also sets the part budget: every cell is two triangles and
-- every triangle is two wedges.
local CELL = 48
local FACET_THICKNESS = 1.2

-- An arbitrary 3D triangle out of two WedgeParts. Rotate the vertices so the
-- longest edge is the hypotenuse, split there, and each wedge covers one half.
-- The two share the split edge exactly, so there is no seam between them - and
-- neighbouring cells share their corner heights, so there is none there either.
local function facet(a: Vector3, b: Vector3, c: Vector3, colour: Color3, parent: Instance): number
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b

	local cross = ac:Cross(ab)
	if cross.Magnitude < 1e-4 then
		return 0 -- three collinear points describe no triangle
	end
	local right = cross.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))

	local first = Instance.new("WedgePart")
	first.Anchored = true
	first.Material = Enum.Material.SmoothPlastic
	first.Color = colour
	first.TopSurface = Enum.SurfaceType.Smooth
	first.BottomSurface = Enum.SurfaceType.Smooth
	first.Size = Vector3.new(FACET_THICKNESS, height, math.abs(ab:Dot(back)))
	first.CFrame = CFrame.fromMatrix((a + b) / 2, right, up, back)
	first.Parent = parent

	local second = Instance.new("WedgePart")
	second.Anchored = true
	second.Material = Enum.Material.SmoothPlastic
	second.Color = colour
	second.TopSurface = Enum.SurfaceType.Smooth
	second.BottomSurface = Enum.SurfaceType.Smooth
	second.Size = Vector3.new(FACET_THICKNESS, height, math.abs(ac:Dot(back)))
	second.CFrame = CFrame.fromMatrix((a + c) / 2, -right, up, -back)
	second.Parent = parent

	return 2
end

-- Called at the very END of the build, once every terrace has been claimed.
-- Nothing needs it earlier, because everything else asks groundHeight.
local function buildGround(): string
	local ground = Instance.new("Folder")
	ground.Name = "MedievalLand_Ground"
	ground.Parent = Workspace

	local deep = SEA_LEVEL - 16
	local reach = math.ceil((ISLAND_HALF + CELL * 2) / CELL)

	-- Sample the grid ONCE. Corners are shared between four cells, so sampling
	-- per cell would evaluate every interior corner four times - and worse,
	-- could disagree at a shared corner and tear a seam open between two cells.
	local heights: { [number]: { [number]: number } } = {}
	for ix = -reach, reach do
		local column: { [number]: number } = {}
		for iz = -reach, reach do
			column[iz] = surfaceInfo(ix * CELL, iz * CELL)
		end
		heights[ix] = column
	end

	local cells, parts = 0, 0
	for ix = -reach, reach - 1 do
		for iz = -reach, reach - 1 do
			local h00 = heights[ix][iz]
			local h10 = heights[ix + 1][iz]
			local h11 = heights[ix + 1][iz + 1]
			local h01 = heights[ix][iz + 1]

			-- Skip cells entirely well under the sea. They are hidden by the
			-- water and the seabed, and they are most of the part budget.
			if math.max(h00, h10, h11, h01) > deep then
				local x0, z0 = ix * CELL, iz * CELL
				local x1, z1 = x0 + CELL, z0 + CELL

				-- COLOUR IS DECIDED AT THE CELL CENTRE, not from its corners.
				-- Taking "worked if any of the four corners is on a pad" bled
				-- every terrace outward by a whole cell - it grew each pad's
				-- painted area by about two and a half times, and with
				-- seventeen of them that was most of the island. The corner
				-- heights still build the geometry; only the colour moved to
				-- the centre, where a single sample answers it exactly.
				local cx, cz = x0 + CELL / 2, z0 + CELL / 2
				local middle, isWorked = surfaceInfo(cx, cz)
				local colour = if isWorked
					then WORKED_COLOUR
					else GROUND_COLOUR[biomeAt(cx, cz, middle)] or WORKED_COLOUR

				-- One colour for the whole cell, both triangles. Colouring per
				-- triangle halves the block size and starts to read as noise.
				parts += facet(Vector3.new(x0, h00, z0), Vector3.new(x1, h10, z0),
					Vector3.new(x1, h11, z1), colour, ground)
				parts += facet(Vector3.new(x0, h00, z0), Vector3.new(x1, h11, z1),
					Vector3.new(x0, h01, z1), colour, ground)
				cells += 1
			end
		end
	end

	-- The sea. A flat plane rather than Terrain water: the brief wants water to
	-- be one of the separated colours, and a voxel sea would drag the engine's
	-- blending back in at the shoreline, which is the whole thing being fixed.
	--
	-- It does not collide. Terrain water let you swim and a part cannot, so the
	-- seabed under it is solid: a player who wades out walks on the bottom
	-- rather than falling out of the world.
	local sea = Instance.new("Part")
	sea.Name = "Sea"
	sea.Anchored = true
	sea.CanCollide = false
	sea.CanQuery = false
	sea.Size = Vector3.new(MAP_SIZE, 2, MAP_SIZE)
	sea.CFrame = CFrame.new(0, SEA_LEVEL - 1, 0)
	sea.Material = Enum.Material.SmoothPlastic
	sea.Color = Color3.fromRGB(46, 182, 228)
	sea.Transparency = 0.22
	sea.TopSurface = Enum.SurfaceType.Smooth
	sea.BottomSurface = Enum.SurfaceType.Smooth
	sea.Parent = ground

	local bed = Instance.new("Part")
	bed.Name = "Seabed"
	bed.Anchored = true
	bed.Size = Vector3.new(MAP_SIZE, 8, MAP_SIZE)
	bed.CFrame = CFrame.new(0, deep - 8, 0)
	bed.Material = Enum.Material.SmoothPlastic
	bed.Color = Color3.fromRGB(32, 126, 176)
	bed.TopSurface = Enum.SurfaceType.Smooth
	bed.BottomSurface = Enum.SurfaceType.Smooth
	bed.Parent = ground

	return ("%d cells, %d facet parts, %d terraces"):format(cells, parts, #terraces)
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
	Color3.fromRGB(76, 168, 62),
	Color3.fromRGB(104, 194, 74),
	Color3.fromRGB(58, 142, 66),
}

-- THE MESH KIT LIVES IN THE PLACE FILE, NOT IN THIS REPO. Rojo does not manage
-- ServerStorage, so a fresh clone will not have it - exactly the trap the
-- MaterialVariants fall into. The difference is that this one is not allowed to
-- fail silently: without the kit the forests fall back to the old primitive
-- trees and the build warns, rather than producing a world with no wood in it.
--
-- Birches are excluded on purpose. Their leaves ship in an autumn palette on
-- flat slab geometry and read as orange boards in a green summer.
local treeSpecies: { Model } = {}
do
	local kit = ServerStorage:FindFirstChild("TreeKit")
	if kit then
		for _, child in kit:GetChildren() do
			if child:IsA("Model") and not child.Name:match("Birch") then
				treeSpecies[#treeSpecies + 1] = child
			end
		end
	end
	if #treeSpecies == 0 then
		warn("[build-world] ServerStorage.TreeKit is missing or empty - forests will "
			.. "use primitive trees. The mesh kit lives in the place file, not the repo.")
	end
end

-- One tree from the kit, seated on the ground and tagged for harvesting.
--
-- Only the LEAVES wear. Trunk, stump and the woody branch structure are the
-- permanent frame, so a worked-out wood reads as bare trunks and stumps rather
-- than as an empty field - the same contract the primitive trees had, mapped
-- onto the kit's part names.
local function plantTree(into: Model, index: number, x: number, z: number,
	ground: number, height: number): BasePart?
	local source = treeSpecies[rng:NextInteger(1, #treeSpecies)]
	local tree = source:Clone()
	tree.Name = ("Tree%d"):format(index)
	tree.Parent = into

	tree:ScaleTo(height / tree:GetExtentsSize().Y)

	-- Seat it: move the pivot by however far the model's underside currently
	-- sits above or below the ground.
	local bottom = tree:GetBoundingBox().Position.Y - tree:GetExtentsSize().Y / 2
	local pivot = tree:GetPivot()
	tree:PivotTo(CFrame.new(x, pivot.Y + (ground - bottom), z)
		* CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0))

	-- One green per tree. Picking per PART turns a stand into a sample book.
	local green = LEAF_GREENS[rng:NextInteger(1, #LEAF_GREENS)]
	local trunk: BasePart? = nil
	for _, d in tree:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CastShadow = true
			if d.Name:match("Leaf") then
				d.Color = green
				d.CanCollide = false
				wearing(d)
			else
				-- Branches are wood, not foliage - they keep their bark colour
				-- and they stay when the leaves have gone. They do not block:
				-- an eleven stud branch at head height is a wall you cannot see.
				if d.Name:match("Branch") or d.Name:match("Cube") then
					d.CanCollide = false
				end
				trunk = trunk or d
			end
		end
	end
	return trunk
end

local function makeForest(name: string, origin: Vector3): Model
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("Resource", "Wood")

	-- Eight trees spread over most of the tile. On a 160 stud tile the old five
	-- at a 22 stud radius sat in the middle like a potted plant.
	local trunkPrimary: BasePart? = nil
	for t = 1, 8 do
		local angle = (t / 8) * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
		local dist = if t == 1 then 0 else rng:NextNumber(16, 56)
		local x = origin.X + math.cos(angle) * dist
		local z = origin.Z + math.sin(angle) * dist
		local ground = groundHeight(x, z)

		if #treeSpecies > 0 then
			-- Varied heights. A stand of identical trees reads as wallpaper,
			-- and the kit is cheap enough to scale per tree.
			--
			-- The call is NOT folded into the assignment. Writing
			-- `trunkPrimary = trunkPrimary or plantTree(...)` short-circuits once
			-- the first tree exists, so plantTree never runs again and every
			-- forest is a single tree. Counting parts caught it; looking at it
			-- would not have.
			local trunk = plantTree(model, t, x, z, ground, rng:NextNumber(16, 23))
			trunkPrimary = trunkPrimary or trunk
		else
			local height = rng:NextNumber(9, 14)
			local radius = rng:NextNumber(0.7, 1.0)

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
	end

	model.PrimaryPart = trunkPrimary
	model.Parent = nodes
	return model
end

-- --- pasture -----------------------------------------------------
local PASTURE_FENCE = Color3.fromRGB(166, 116, 66)
local PASTURE_RADIUS = 58

-- Exaggerated, per the art direction. A realistically proportioned sheep is
-- about two thirds of a player's height and, at the distance you actually see a
-- pasture from, that is a white dot. The fence says "pasture"; the sheep have to
-- be big enough to say "of sheep".
local SHEEP = 1.5

local function makePasture(name: string, origin: Vector3): Model
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("Resource", "Wool")

	-- THE FENCE IS WHAT MAKES IT A PASTURE. Six sheep standing on open grass is
	-- six sheep; the same six inside a rail fence is somewhere a person keeps
	-- animals, and that is the difference between a prop and a place. It is also
	-- the silhouette that identifies the tile from outside it, since sheep are
	-- small and the fence is forty studs of straight line.
	--
	-- Permanent - nothing here wears. Shearing a flock should not dismantle the
	-- fence around it.
	local POSTS = 14
	local gate = rng:NextInteger(1, POSTS) -- one gap, so it reads as enterable
	local function cornerAt(index: number): Vector3
		local angle = (index / POSTS) * math.pi * 2
		local x = origin.X + math.cos(angle) * PASTURE_RADIUS
		local z = origin.Z + math.sin(angle) * PASTURE_RADIUS
		return Vector3.new(x, groundHeight(x, z), z)
	end

	for i = 0, POSTS - 1 do
		local here = cornerAt(i)
		local post = newPart(("Post%d"):format(i + 1), Vector3.new(0.8, 4.4, 0.8),
			CFrame.new(here + Vector3.new(0, 1.9, 0)), model)
		post.Material = Enum.Material.SmoothPlastic
		post.Color = PASTURE_FENCE

		if i + 1 ~= gate then
			-- Two rails per span, laid along the chord between neighbouring
			-- posts and pitched to follow the ground between them.
			local nextPost = cornerAt(i + 1)
			local span = nextPost - here
			local middle = here + span / 2
			for rail = 1, 2 do
				local lift = 1.4 + rail * 1.1
				local bar = newPart(("Rail%d_%d"):format(i + 1, rail),
					Vector3.new(0.4, 0.5, span.Magnitude),
					CFrame.lookAt(middle + Vector3.new(0, lift, 0), nextPost + Vector3.new(0, lift, 0)),
					model)
				bar.Material = Enum.Material.SmoothPlastic
				bar.Color = PASTURE_FENCE
				bar.CanCollide = false -- the posts fence you in; rails only draw it
			end
		end
	end

	local primary: Part? = nil
	for s = 1, 6 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = if s == 1 then 0 else rng:NextNumber(12, PASTURE_RADIUS - 14)
		local x = origin.X + math.cos(angle) * dist
		local z = origin.Z + math.sin(angle) * dist
		local ground = groundHeight(x, z)
		local facing = rng:NextNumber(0, math.pi * 2)
		local base = CFrame.new(x, ground + 1.5 * SHEEP + 0.6, z) * CFrame.Angles(0, facing, 0)

		-- The sheep itself does not wear away, only its fleece. A shorn flock
		-- should still be a flock standing there looking indignant.
		local body = newPart(("Body%d"):format(s),
			Vector3.new(2.4, 1.7, 1.6) * SHEEP, base, model)
		body.Shape = Enum.PartType.Ball
		body.Material = Enum.Material.Fabric
		body.Color = Color3.fromRGB(226, 216, 200)
		primary = primary or body

		local head = newPart(("Head%d"):format(s), Vector3.new(0.9, 0.9, 0.9) * SHEEP,
			base * CFrame.new(0, 0.25 * SHEEP, -1.2 * SHEEP), model)
		head.Shape = Enum.PartType.Ball
		head.Material = Enum.Material.SmoothPlastic
		head.Color = Color3.fromRGB(58, 54, 52)

		for leg = 1, 4 do
			local lx = (if leg % 2 == 0 then 0.7 else -0.7) * SHEEP
			local lz = (if leg <= 2 then 0.6 else -0.6) * SHEEP
			local shin = newPart(
				("Leg%d_%d"):format(s, leg),
				Vector3.new(0.26, 1.5, 0.26) * SHEEP,
				base * CFrame.new(lx, -1.2 * SHEEP, lz),
				model
			)
			shin.Material = Enum.Material.SmoothPlastic
			shin.Color = Color3.fromRGB(58, 54, 52)
		end

		for f = 1, 4 do
			local size = rng:NextNumber(1.1, 1.6) * SHEEP
			local tuft = wearing(newPart(
				("Fleece%d_%d"):format(s, f),
				Vector3.new(size, size * 0.85, size),
				base * CFrame.new(
					rng:NextNumber(-0.8, 0.8) * SHEEP,
					rng:NextNumber(0.6, 1.0) * SHEEP,
					rng:NextNumber(-0.7, 0.7) * SHEEP
				),
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
			stalk.Color = Color3.fromRGB(232, 190, 66)
		end
	end

	-- STOOKS. The crop itself is a flat mat of overlapping clumps - correct for
	-- a field seen from above, and completely silhouette-less from standing
	-- height. Four bundles propped against each other give the tile something
	-- that breaks the skyline, which is how you spot a grain tile across a
	-- valley rather than only once you are on it.
	--
	-- Permanent: a stook is cut grain already gathered, so it should still be
	-- standing when the field itself has been harvested flat.
	for stook = 1, 4 do
		local angle = (stook / 4) * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
		local dist = rng:NextNumber(20, 27)
		local sx = origin.X + math.cos(angle) * dist
		local sz = origin.Z + math.sin(angle) * dist
		local sy = groundHeight(sx, sz)
		-- Five sheaves leaning inward hard enough to read as a cone. At three
		-- bundles and a 0.2 radian lean they came out as a clump of upright
		-- posts, which is what a stook is NOT - the whole silhouette is the
		-- lean, so it is 0.46 now and the tops actually meet.
		for sheaf = 1, 5 do
			local lean = (sheaf / 5) * math.pi * 2
			local bundle = newPart(("Stook%d_%d"):format(stook, sheaf),
				Vector3.new(1.7, 7.4, 1.7),
				CFrame.new(sx + math.cos(lean) * 1.5, sy + 3.4, sz + math.sin(lean) * 1.5)
					* CFrame.Angles(math.sin(lean) * 0.46, 0, -math.cos(lean) * 0.46),
				model)
			skin(bundle, SKIN.wheat)
			bundle.Color = Color3.fromRGB(238, 196, 68)
		end
	end

	model.Parent = nodes
	return model
end

-- --- quarry (Stone) and mine (Ore) ------------------------------
-- THESE USED TO BE ONE FUNCTION WITH A DIFFERENT GREY, and that is exactly the
-- failure the design brief names: a label difference rather than a shape
-- difference. Same box cluster, same silhouette, one darker than the other -
-- from twenty studs away they were the same rock twice. They no longer share a
-- builder at all, because two things that must read apart at a glance cannot be
-- one function with a colour parameter.
--
-- Flat colour, no MaterialVariant. The ground is flat-shaded facets now and
-- these sit on it; a textured rock in a faceted world reads as an import.

local function newWedge(name: string, size: Vector3, cframe: CFrame, parent: Instance,
	colour: Color3): WedgePart
	local wedge = Instance.new("WedgePart")
	wedge.Name = name
	wedge.Size = size
	wedge.CFrame = cframe
	wedge.Anchored = true
	wedge.Material = Enum.Material.SmoothPlastic
	wedge.Color = colour
	wedge.TopSurface = Enum.SurfaceType.Smooth
	wedge.BottomSurface = Enum.SurfaceType.Smooth
	wedge.Parent = parent
	return wedge
end

-- Stone: the LIGHT one, and the angular one. Angularity comes from wedges - a
-- rotated box is still a box, but a wedge stood on end is a blade, and a cluster
-- of blades leaning different ways is what makes rock look broken rather than
-- stacked.
local QUARRY_GREYS = {
	Color3.fromRGB(206, 216, 240),
	Color3.fromRGB(182, 196, 226),
	Color3.fromRGB(224, 232, 248),
}

local function makeQuarry(name: string, origin: Vector3): Model
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("Resource", "Stone")

	local function grey(): Color3
		return QUARRY_GREYS[rng:NextInteger(1, #QUARRY_GREYS)]
	end

	-- One outcrop of the range. Three of these spread across the tile, so a
	-- stone tile is somewhere you walk into rather than a lump you stand on.
	local function outcrop(tag: string, at: Vector2, scale: number): BasePart
		local groundY = groundHeight(at.X, at.Y)

		-- A low plinth the blades grow out of. Permanent: quarry a seam out and
		-- what is left should still be a rock, not bare grass.
		local core = newPart(
			tag .. "Base",
			Vector3.new(7.0 * scale, 2.6 * scale, 6.2 * scale),
			CFrame.new(at.X, groundY + 1.0 * scale, at.Y)
				* CFrame.Angles(rng:NextNumber(-0.09, 0.09), rng:NextNumber(0, 6.28), rng:NextNumber(-0.09, 0.09)),
			model
		)
		core.Material = Enum.Material.SmoothPlastic
		core.Color = grey()

		-- The blades. Tall, thin, leaning hard, tops at different heights.
		for i = 1, 5 do
			local height = rng:NextNumber(4.2, 8.4) * scale
			local width = rng:NextNumber(1.6, 3.0) * scale
			local angle = (i / 5) * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
			local dist = rng:NextNumber(0.6, 2.9) * scale
			wearing(newWedge(
				("%sBlade%d"):format(tag, i),
				Vector3.new(width, height, width * rng:NextNumber(0.8, 1.5)),
				CFrame.new(
					at.X + math.cos(angle) * dist,
					groundY + 1.6 * scale + height / 2,
					at.Y + math.sin(angle) * dist
				) * CFrame.Angles(
					rng:NextNumber(-0.42, 0.42),
					rng:NextNumber(0, 6.28),
					rng:NextNumber(-0.42, 0.42)
				),
				model,
				grey()
			))
		end

		-- A couple of flat slabs sheared off and leaning against the pile.
		for i = 1, 2 do
			wearing(newWedge(
				("%sSlab%d"):format(tag, i),
				Vector3.new(rng:NextNumber(3.4, 5.2) * scale, rng:NextNumber(1.0, 1.8) * scale,
					rng:NextNumber(3.0, 4.6) * scale),
				CFrame.new(
					at.X + rng:NextNumber(-4.2, 4.2),
					groundY + rng:NextNumber(0.6, 2.2),
					at.Y + rng:NextNumber(-4.2, 4.2)
				) * CFrame.Angles(
					rng:NextNumber(-0.9, 0.9),
					rng:NextNumber(0, 6.28),
					rng:NextNumber(-0.9, 0.9)
				),
				model,
				grey()
			))
		end

		-- Chips around the foot. Permanent: they are what makes the outcrop sit
		-- IN the ground rather than on it.
		for i = 1, 5 do
			local angle = rng:NextNumber(0, math.pi * 2)
			local dist = rng:NextNumber(4.0, 7.4) * scale
			local size = rng:NextNumber(0.8, 1.9) * scale
			local chip = newWedge(
				("%sChip%d"):format(tag, i),
				Vector3.new(size, size * rng:NextNumber(0.5, 0.9), size * rng:NextNumber(0.8, 1.3)),
				CFrame.new(at.X + math.cos(angle) * dist, groundY + 0.3, at.Y + math.sin(angle) * dist)
					* CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, 6.28), rng:NextNumber(-0.3, 0.3)),
				model,
				grey()
			)
			chip.CanCollide = false -- ankle-height litter should not trip anyone
		end

		return core
	end

	local spin = rng:NextNumber(0, math.pi * 2)
	for i = 0, 2 do
		local angle = spin + (i / 3) * math.pi * 2
		local dist = rng:NextNumber(24, 42)
		local at = Vector2.new(origin.X + math.cos(angle) * dist, origin.Z + math.sin(angle) * dist)
		-- Scaled against the FACETS, not against the character. The ground is
		-- drawn in 48 stud cells now, and an outcrop that would have read fine
		-- on smooth terrain reads as gravel next to a triangle that size.
		local core = outcrop(("Rock%d"):format(i + 1), at, rng:NextNumber(1.6, 2.4))
		model.PrimaryPart = model.PrimaryPart or core
	end

	model.Parent = nodes
	return model
end

-- Ore: a MINE, not a darker quarry. The silhouette is the whole point - a
-- timber-framed portal into a dark mound reads as somewhere you dig from across
-- the tile, and nothing about a pile of grey blades does.
-- Ore stays the DARK one - that is how it reads apart from stone - but dark
-- violet rather than dark grey, so it is a colour and not an absence of one.
local MINE_ROCK = Color3.fromRGB(78, 68, 112)
local MINE_ROCK_LIGHT = Color3.fromRGB(102, 90, 142)
local MINE_TIMBER = Color3.fromRGB(122, 76, 44)
local MINE_DARK = Color3.fromRGB(26, 20, 40)
local ORE_GLINT = Color3.fromRGB(255, 190, 70)

local function makeMine(name: string, origin: Vector3): Model
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("Resource", "Ore")

	local function rock(partName: string, size: Vector3, cframe: CFrame, light: boolean): Part
		local part = newPart(partName, size, cframe, model)
		part.Material = Enum.Material.SmoothPlastic
		part.Color = if light then MINE_ROCK_LIGHT else MINE_ROCK
		return part
	end

	-- Small, saturated, and NEON so they catch the eye against near-black rock.
	-- These are the ore: they are what wears away when the seam is worked out,
	-- which leaves the mine itself standing and empty.
	local function glint(partName: string, at: CFrame, size: number)
		local chunk = wearing(newPart(partName, Vector3.new(size, size * 0.8, size * 0.9), at, model))
		chunk.Material = Enum.Material.Neon
		chunk.Color = ORE_GLINT
		chunk.CanCollide = false
	end

	-- --- the entrance, at the middle of the tile ---------------------
	local mouthAt = Vector2.new(origin.X, origin.Z)
	local groundY = groundHeight(mouthAt.X, mouthAt.Y)
	local facing = rng:NextNumber(0, math.pi * 2)
	local at = CFrame.new(mouthAt.X, groundY, mouthAt.Y) * CFrame.Angles(0, facing, 0)

	-- The hill it is cut into. Three slabs stepped back, so the mound has a
	-- profile instead of being one block with a hole in it.
	for i = 1, 3 do
		local width = 26 - i * 3.4
		local height = 8.5 + i * 3.2
		rock(
			("Mound%d"):format(i),
			Vector3.new(width, height, 11 + i * 5),
			at * CFrame.new(0, height / 2 - 1.5, -3.4 - i * 4.2)
				* CFrame.Angles(0, rng:NextNumber(-0.14, 0.14), 0),
			i == 2
		)
	end

	-- The opening. A dark box recessed into the mound - the single element that
	-- makes this read as a mine from any distance.
	local mouth = rock("Mouth", Vector3.new(8.2, 9.0, 5.0), at * CFrame.new(0, 4.5, -2.0), false)
	mouth.Color = MINE_DARK
	model.PrimaryPart = mouth

	-- Angular chunks over and around the mound. Three stacked slabs give a
	-- profile from the side and a CUBE from the front, which read as a tomb
	-- rather than as rock; these are what make it a hillside again.
	for i = 1, 7 do
		local side = if i % 2 == 0 then 1 else -1
		local size = rng:NextNumber(3.2, 6.4)
		newWedge(
			("Crag%d"):format(i),
			Vector3.new(size, size * rng:NextNumber(0.9, 1.8), size * rng:NextNumber(0.8, 1.4)),
			at * CFrame.new(
				side * rng:NextNumber(4.0, 12.5),
				rng:NextNumber(3.0, 13.0),
				-rng:NextNumber(2.0, 14.0)
			) * CFrame.Angles(
				rng:NextNumber(-0.5, 0.5),
				rng:NextNumber(0, 6.28),
				rng:NextNumber(-0.5, 0.5)
			),
			model,
			if i % 3 == 0 then MINE_ROCK_LIGHT else MINE_ROCK
		)
	end

	-- Timber frame around it: two posts and a lintel, plus a leaning brace.
	for _, side in { -1, 1 } do
		local post = newPart(
			("Post%d"):format(if side < 0 then 1 else 2),
			Vector3.new(1.5, 10.0, 1.5),
			at * CFrame.new(side * 5.0, 5.0, 0.6),
			model
		)
		post.Material = Enum.Material.SmoothPlastic
		post.Color = MINE_TIMBER
	end
	local lintel = newPart("Lintel", Vector3.new(12.6, 1.7, 2.0), at * CFrame.new(0, 10.6, 0.6), model)
	lintel.Material = Enum.Material.SmoothPlastic
	lintel.Color = MINE_TIMBER
	local brace = newPart("Brace", Vector3.new(1.2, 6.4, 1.2),
		at * CFrame.new(-6.6, 4.4, 3.4) * CFrame.Angles(0.36, 0, 0.22), model)
	brace.Material = Enum.Material.SmoothPlastic
	brace.Color = MINE_TIMBER

	-- Spoil heaped either side of the mouth, and ore in it.
	for i = 1, 6 do
		local side = if i % 2 == 0 then 1 else -1
		local size = rng:NextNumber(1.6, 3.4)
		rock(
			("Spoil%d"):format(i),
			Vector3.new(size, size * 0.7, size * 1.1),
			at * CFrame.new(side * rng:NextNumber(6.5, 11.0), 0.5, rng:NextNumber(2.5, 9.0))
				* CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, 6.28), rng:NextNumber(-0.3, 0.3)),
			true
		)
	end
	for i = 1, 5 do
		local side = if i % 2 == 0 then 1 else -1
		glint(("MouthOre%d"):format(i),
			at * CFrame.new(side * rng:NextNumber(6.0, 10.5), rng:NextNumber(0.9, 2.2), rng:NextNumber(2.5, 8.5))
				* CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), 0),
			rng:NextNumber(0.9, 1.6))
	end

	-- --- exposed veins elsewhere on the tile -------------------------
	-- Two smaller seams, so the tile is a mine WORKINGS rather than one doorway
	-- with empty ground around it.
	local spin = rng:NextNumber(0, math.pi * 2)
	for v = 1, 2 do
		local angle = spin + v * 2.3
		local dist = rng:NextNumber(28, 46)
		local vx = origin.X + math.cos(angle) * dist
		local vz = origin.Z + math.sin(angle) * dist
		local vy = groundHeight(vx, vz)

		for i = 1, 4 do
			local height = rng:NextNumber(3.0, 6.0)
			local width = rng:NextNumber(2.4, 4.2)
			rock(
				("Vein%d_%d"):format(v, i),
				Vector3.new(width, height, width * rng:NextNumber(0.8, 1.3)),
				CFrame.new(
					vx + rng:NextNumber(-3.6, 3.6),
					vy + height / 2 - 0.6,
					vz + rng:NextNumber(-3.6, 3.6)
				) * CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, 6.28), rng:NextNumber(-0.3, 0.3)),
				i % 2 == 0
			)
		end
		-- The glinting seam running through it
		for i = 1, 5 do
			glint(("Vein%dOre%d"):format(v, i),
				CFrame.new(
					vx + rng:NextNumber(-3.0, 3.0),
					vy + rng:NextNumber(1.2, 4.4),
					vz + rng:NextNumber(-3.0, 3.0)
				) * CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), 0),
				rng:NextNumber(0.8, 1.5))
		end
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
-- ---------------------------------------------------------------- plots first
-- PLOTS ARE CHOSEN BEFORE NODES, and that ordering is the point.
--
-- A plot is the constrained thing: it needs flat ground, a 250 stud gap from
-- every other plot, and clearance from the middle. A resource node needs
-- almost nothing - five kinds between them accept anything from the waterline
-- to the summit. Letting 48 nodes take the first pick and giving the plots
-- whatever survived had the scarce thing competing for scraps, and when the
-- pads grew to clear the new facet grid only NINE of sixteen plots still fit.
--
-- Selection is split from construction. Only the SPOT and the terrace claim
-- are decided here; makePlot needs several hundred lines of building
-- vocabulary that does not exist yet, so the villages themselves are built
-- from this list much further down.
local PLOT = 148 -- village footprint
local PLOT_TARGET = 16
local PLOT_SPACING = 250

-- The plaza is claimed here too, for the same reason and in the same breath.
-- It used to be registered after the nodes were placed, which meant a node
-- allowed as close as 165 studs to the middle could sit inside a 198 stud pad
-- and end up under the shelf. Every terrace on the island is now claimed before
-- a single thing is positioned.
local PLAZA_PAD = 150 + 14
registerTerrace(Vector2.new(0, 0), PLAZA_PAD, math.max(heightAt(0, 0), 12))

-- The flat pad a village stands on. It has to carry the CORNERS of the
-- foundation, hence the diagonal - that sets a floor of 104.6 and there is no
-- arguing with it, because the slab is 148 square.
--
-- The margin on top is deliberately SMALL. A whole facet cell of margin put the
-- pad diameter at 305 against a plot spacing of 250, so neighbouring villages
-- shared a shelf and each pair met in a step where the two flat heights
-- disagreed. Fourteen studs keeps 237 clear of 250 and still gives the slab
-- something to stand on past its corners.
local PLOT_PAD = PLOT / 2 * math.sqrt(2) + 14

for _ = 1, PLOT_TARGET do
	local spot = findSpot({
		minHeight = 7,
		maxHeight = 58,
		maxSlope = 14,
		gapNodes = 0, -- nothing has been placed yet; this is the first pick
		gapPlots = PLOT_SPACING,
		clearOfCentre = 300,
		attempts = 1400,
	})
	if not spot then
		break
	end
	plotSpots[#plotSpots + 1] = spot
	-- Claim the shelf now. heightAt rather than groundHeight on purpose: the
	-- pad should sit at the NATURAL height of the ground under it, not at the
	-- height of some neighbouring pad's ramp.
	registerTerrace(spot, PLOT_PAD, heightAt(spot.X, spot.Y))
end
if #plotSpots < PLOT_TARGET then
	warn(("[Medieval Land] only %d of %d village plots fit on the island"):format(
		#plotSpots, PLOT_TARGET))
end

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
			-- Off the village pads entirely. A node inside one would have been
			-- placed at the natural ground height and then found itself buried
			-- under a flat shelf - true of the old FillCylinder too, so this
			-- closes a long-standing hazard rather than inventing a new rule.
			gapPlots = PLOT_PAD + 24,
			clearOfCentre = PLAZA_PAD + 24,
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
		elseif plan.resource == "Stone" then
			makeQuarry(name, origin)
		else
			makeMine(name, origin)
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

-- The plaza is the one fixed point on the island and the zone closes onto it,
-- so it stands on a terrace like the villages do. That terrace was claimed at
-- the top of the file; groundHeight simply reports it back.
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

-- ---------------------------------------------------------------- birds
-- The sky over an island is the largest empty surface in the game, and empty is
-- what it reads as. Seven birds circling the totem fix that for twenty-one
-- parts and no server cost - they are animated by the same client loop that
-- walks the villagers, and by the same rule: anchored parts moved locally.
--
-- They orbit the ONE landmark everybody can see from anywhere, so they double
-- as a way to find the middle of the board from the far shore.
local birdFlock = Instance.new("Folder")
birdFlock.Name = "Birds"
birdFlock:SetAttribute("Centre", Vector3.new(0, plazaGround, 0))
birdFlock.Parent = Workspace

local BIRD_BODY = Color3.fromRGB(56, 52, 58)
for i = 1, 7 do
	local bird = Instance.new("Model")
	bird.Name = ("Bird%d"):format(i)

	-- Each on its own ring, height and clock, or seven birds fly as one bird.
	bird:SetAttribute("Radius", 34 + (i % 4) * 13 + rng:NextNumber(-4, 4))
	bird:SetAttribute("Height", 42 + (i % 3) * 11 + rng:NextNumber(-3, 3))
	bird:SetAttribute("Speed", 0.22 + rng:NextNumber(0, 0.12)) -- radians per second
	bird:SetAttribute("Phase", rng:NextNumber(0, math.pi * 2))
	bird:SetAttribute("Flap", 5.5 + rng:NextNumber(0, 2.5))

	-- Rest offsets from the bird's own root, read by the client exactly as the
	-- villager rig's are. Wings carry a sign so they beat as a mirrored pair.
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(0.8, 0.5, 2.0)
	body.Anchored = true
	body.CanCollide = false
	body.CanQuery = false
	body.Material = Enum.Material.SmoothPlastic
	body.Color = BIRD_BODY
	body.CFrame = CFrame.new(0, plazaGround + 50, 0)
	body:SetAttribute("Rest", CFrame.new())
	body:SetAttribute("Wing", 0)
	body.Parent = bird
	bird.PrimaryPart = body

	for _, sx in { -1, 1 } do
		local wing = Instance.new("Part")
		wing.Name = if sx < 0 then "WingL" else "WingR"
		wing.Size = Vector3.new(2.4, 0.14, 1.0)
		wing.Anchored = true
		wing.CanCollide = false
		wing.CanQuery = false
		wing.Material = Enum.Material.SmoothPlastic
		wing.Color = BIRD_BODY
		wing.CFrame = CFrame.new(0, plazaGround + 50, 0)
		-- The wing hinges at the shoulder, so its rest sits a half span out.
		wing:SetAttribute("Rest", CFrame.new(sx * 1.3, 0.1, 0))
		wing:SetAttribute("Pivot", CFrame.new(sx * 0.35, 0.1, 0))
		wing:SetAttribute("Wing", sx)
		wing.Parent = bird
	end

	bird.Parent = birdFlock
end

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

local WALL_HALF = 70 -- wall ring sits at +/- this
local WALL_BLOCK = Vector3.new(20.4, 11, 3.6)
local WALL_SPAN = 20 -- centre-to-centre along a side
local RING_STEPS = 7 -- blocks per side

local DAUB = Color3.fromRGB(248, 240, 214)
local TIMBER = Color3.fromRGB(116, 74, 44)
local THATCH = Color3.fromRGB(232, 182, 86)
local TILED = Color3.fromRGB(112, 62, 48)
local STONEWORK = Color3.fromRGB(186, 194, 214)

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

-- A FACETED SQUARE PRISM, not a cylinder. Enum.PartType.Cylinder is smooth and
-- round, which is exactly the look the art direction rules out - and once the
-- ground became flat triangles, a smooth tower was the one thing on the plot
-- still shaded like stock Roblox.
--
-- The first attempt tried an octagon from two square prisms at 45 degrees. That
-- is wrong and the screenshot said so: the INTERSECTION of two rotated squares
-- is a regular octagon, but two overlapping PARTS make a union, and the union
-- is an eight-pointed star. Parts cannot intersect, so a real octagon needs
-- eight panels - and at nineteen drums per plot across sixteen plots, that is
-- not a trade worth making for a shape nobody stands close enough to count.
--
-- One square prism it is. Four flat faces, one part, unambiguously faceted, and
-- HALF the cost of the star it replaces. Square towers with pyramid caps are
-- the standard low-poly castle read anyway.
--
-- Same signature and same return as the cylinder version, so every caller -
-- wells, turrets, cauldrons, towers - is faceted by this one change.
local function siteDrum(parent: Instance, name: string, radius: number, height: number,
	at: CFrame, material: Enum.Material, color: Color3): Part
	-- Across the flats rather than across the corners, so the prism sits inside
	-- the footprint the old cylinder had instead of overhanging it.
	local side = radius * 1.7
	return sitePart(parent, name, Vector3.new(side, height, side),
		at * CFrame.new(0, height / 2, 0), material, color)
end

-- ---------------------------------------------------------------- castle
-- Flat, saturated, separated - the stonework palette. The cottages keep their
-- daub and thatch MaterialVariants: they are peasant buildings and they read
-- well. The CASTLE is what the art direction names, and stone is what has to
-- go faceted and flat so it sits in the same world as the ground.
local CASTLE_STONE = Color3.fromRGB(166, 168, 176)
local CASTLE_STONE_DARK = Color3.fromRGB(128, 130, 140)
local CASTLE_ROOF = Color3.fromRGB(138, 62, 66) -- deep tile red, hard against the grey
local CASTLE_TIMBER = Color3.fromRGB(96, 62, 38)

-- Four angled panels meeting at a point. The brief asks for ANGLED ROOF PANELS,
-- and a stepped stack of shrinking drums - the cheaper option - is chunky but
-- it is not a roof.
--
-- A WedgePart is full height at its +Z face and tapers to nothing at -Z, so
-- each panel is turned to aim its TALL side at the centre and its thin edge at
-- the eave. Four of them overlap on the diagonals; the union is a pyramid.
local function spireCap(parent: Instance, name: string, span: number, height: number,
	at: CFrame, color: Color3)
	for side = 0, 3 do
		local panel = Instance.new("WedgePart")
		panel.Name = name
		panel.Size = Vector3.new(span, height, span / 2)
		panel.CFrame = at
			* CFrame.Angles(0, math.rad(90 * side), 0)
			* CFrame.new(0, height / 2, span / 4)
			* CFrame.Angles(0, math.rad(180), 0)
		panel.Anchored = true
		panel.Material = Enum.Material.SmoothPlastic
		panel.Color = color
		panel.TopSurface = Enum.SurfaceType.Smooth
		panel.BottomSurface = Enum.SurfaceType.Smooth
		panel.Parent = parent
	end
end

-- A gable roof from two wedges meeting at a ridge. A WedgePart is tall at its
-- +Z face and tapers to nothing at -Z - measured in Studio, not assumed - so
-- each half is turned to aim its tall side at the ridge line.
-- Roofs used to be Slate with a thatch-coloured tint, which is a yellow slate
-- roof and reads as one. A thatch roof needs a thatch SURFACE.
-- ---------------------------------------------------------------- plumes
-- Smoke, embers and steam. A ParticleEmitter is drawn entirely on the viewer's
-- machine: the server spawns nothing, replicates nothing and runs no loop, so
-- this is the cheapest life in the game - a village reads as INHABITED for the
-- price of one instance per chimney.
--
-- Textures are rbxasset paths that ship with the client. Nothing here is
-- uploaded, so a fresh clone of this repo renders it identically.
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

type Plume = {
	texture: string,
	rate: number,
	life: NumberRange,
	speed: NumberRange,
	sizeFrom: number,
	sizeTo: number,
	colour: ColorSequence,
	opacity: number,
	spread: number,
	drift: Vector3,
	glow: number,
	lit: number,
}

local function plume(parent: BasePart, name: string, offset: Vector3, spec: Plume)
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.Position = offset
	attachment.Parent = parent

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Texture = spec.texture
	emitter.Rate = spec.rate
	emitter.Lifetime = spec.life
	emitter.Speed = spec.speed
	emitter.SpreadAngle = Vector2.new(spec.spread, spec.spread)
	emitter.Acceleration = spec.drift
	emitter.Color = spec.colour
	emitter.LightEmission = spec.glow
	-- Smoke that ignores the sun is a bright grey smear at dusk, but smoke that
	-- obeys it COMPLETELY vanishes against a backlit sky - which is exactly what
	-- the first attempt did. Partial influence keeps it in the same world as the
	-- roof while leaving it legible from the shadowed side.
	emitter.LightInfluence = spec.lit
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, spec.sizeFrom),
		NumberSequenceKeypoint.new(1, spec.sizeTo),
	})
	-- Fade in as well as out: a particle that appears at full strength pops.
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.14, spec.opacity),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-24, 24)
	emitter.Parent = attachment
	return emitter
end

local HEARTH_SMOKE: Plume = {
	texture = SMOKE_TEXTURE,
	rate = 4,
	life = NumberRange.new(2.6, 4.0),
	speed = NumberRange.new(3.0, 4.2),
	sizeFrom = 1.4,
	sizeTo = 4.2,
	colour = ColorSequence.new(Color3.fromRGB(214, 214, 210), Color3.fromRGB(168, 168, 165)),
	opacity = 0.3,
	spread = 7,
	-- Drift is an ACCELERATION, not a velocity: 1.4 studs/s/s looks gentle and
	-- then compounds over a four second life into a plume raked flat sideways.
	drift = Vector3.new(0.6, 0.9, 0.25),
	glow = 0,
	lit = 0.7,
}

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

-- A villager is a RIG rather than a statue - but nothing here moves, and the
-- server never touches one after it is built. The walking happens entirely on
-- the client, in src/client/Villagers.client.luau.
--
-- WHY THE CLIENT. Villagers are decoration: no player outcome depends on where
-- one is standing. Walking them on the server would spend replication on every
-- frame, for sixty-four rigs, forever, to change nothing. Anchored parts
-- CFramed locally do not replicate back, so each player animates only the
-- villagers near their own camera and the server never learns it happened.
--
-- WHY NO Motor6D AND NO Animator. An Animator needs an uploaded Animation
-- asset, which this toolchain cannot produce, and Motor6D only drives UNANCHORED
-- parts - which would hand sixty-four rigs to the physics solver and raise a
-- network-ownership question for parts the server created. Procedural limb
-- CFrames need no asset, no solver and no ownership.
--
-- Each part carries the two CFrames the animator needs, both relative to the rig
-- root: Rest is where the part sits in the pose, Pivot is the joint it swings
-- around. THE LAYOUT IS AUTHORED ONCE, HERE. The client never hardcodes a hip
-- height; it reads what the rig tells it, so changing a limb below cannot
-- desynchronise the two files.
local VILLAGER_SKIN = Color3.fromRGB(214, 176, 140)
local VILLAGER_CLOTH = Color3.fromRGB(74, 62, 52)
local VILLAGER_HAT = Color3.fromRGB(126, 98, 62)

-- name, size, rest offset from root, pivot height, swing sign (0 = still), tone
-- Arms swing opposite their leg, which is the whole of what makes a walk read as
-- a walk rather than as a shuffle.
local VILLAGER_RIG = {
	{ "LegL", Vector3.new(0.7, 2.2, 0.9), Vector3.new(-0.45, 1.1, 0), 2.2, 1, "cloth" },
	{ "LegR", Vector3.new(0.7, 2.2, 0.9), Vector3.new(0.45, 1.1, 0), 2.2, -1, "cloth" },
	{ "Torso", Vector3.new(1.9, 2.4, 1.2), Vector3.new(0, 3.4, 0), 0, 0, "shirt" },
	{ "ArmL", Vector3.new(0.6, 2.0, 0.8), Vector3.new(-1.25, 3.6, 0), 4.5, -1, "shirt" },
	{ "ArmR", Vector3.new(0.6, 2.0, 0.8), Vector3.new(1.25, 3.6, 0), 4.5, 1, "shirt" },
	{ "Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 5.2, 0), 0, 0, "skin" },
	{ "Hat", Vector3.new(1.7, 0.5, 1.7), Vector3.new(0, 5.9, 0), 0, 0, "hat" },
}

local function makeVillager(into: Instance, at: CFrame, shirt: Color3,
	patrolA: Vector3, patrolB: Vector3, phase: number)
	local figure = Instance.new("Model")
	figure.Name = "Villager"

	for _, spec in VILLAGER_RIG do
		local name = spec[1] :: string
		local size = spec[2] :: Vector3
		local offset = spec[3] :: Vector3
		local pivotY = spec[4] :: number
		local swing = spec[5] :: number
		local tone = spec[6] :: string

		local colour = if tone == "shirt"
			then shirt
			elseif tone == "skin" then VILLAGER_SKIN
			elseif tone == "hat" then VILLAGER_HAT
			else VILLAGER_CLOTH
		local material = if tone == "skin"
			then Enum.Material.SmoothPlastic
			else Enum.Material.Fabric

		local rest = CFrame.new(offset)
		local part = sitePart(figure, name, size, at * rest, material, colour)
		-- A moving anchored part that can collide SHOVES players, and can wedge
		-- one against a wall with no way out. A villager is scenery with legs;
		-- let people walk through it.
		part.CanCollide = false
		part:SetAttribute("Rest", rest)
		part:SetAttribute("Pivot", CFrame.new(offset.X, pivotY, offset.Z))
		part:SetAttribute("Swing", swing)
		if name == "Torso" then
			figure.PrimaryPart = part
		end
	end

	-- The patrol, in world space. Phase desynchronises them: sixteen villagers
	-- stepping in time reads as a chorus line, which is worse than standing
	-- still.
	-- The animator needs the leg length to keep the feet on the ground (a rigid
	-- leg pivoting at the hip shortens its vertical reach), and it must not
	-- hardcode it - that is the number most likely to drift if a limb changes
	-- here. LegL's pivot height IS the leg length, since a foot rests at y=0.
	figure:SetAttribute("LegLength", VILLAGER_RIG[1][4] :: number)
	figure:SetAttribute("PatrolA", patrolA)
	figure:SetAttribute("PatrolB", patrolB)
	figure:SetAttribute("Phase", phase)
	figure:SetAttribute("Speed", 3.2 + phase * 1.8)
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
	-- The patrol is authored in HOUSE-LOCAL space and multiplied out, so it
	-- rotates with the house and never needs to know which way this plot faces.
	-- Out from the door towards the street and back: about eighteen studs, which
	-- stops short of the spine and stays clear of the next cottage. The village
	-- terrace is flat, so both ends share a Y and no ground raycast is needed.
	-- A CHIMNEY IS THE CHEAPEST SIGN OF LIFE THERE IS. A cottage with smoke
	-- coming out of it is occupied; the same cottage without is a model of a
	-- cottage. It clears the roof line at this x (the gable is about 13 studs up
	-- there, the stack tops out at 19).
	local chimney = sitePart(into, "Chimney", Vector3.new(2.2, 12, 2.2),
		at * CFrame.new(HOUSE.width * 0.28, 13, -HOUSE.depth * 0.2),
		Enum.Material.Brick, Color3.fromRGB(112, 96, 88), SKIN.cobble.variant)
	plume(chimney, "Hearth", Vector3.new(0, 6.2, 0), HEARTH_SMOKE)

	local doorSide = at * CFrame.new(HOUSE.width * 0.3, 0, HOUSE.depth / 2 + 3)
	local streetward = at * CFrame.new(HOUSE.width * 0.3, 0, HOUSE.depth / 2 + 21)
	makeVillager(into, doorSide * CFrame.Angles(0, math.rad(196), 0),
		VILLAGER_SHIRTS[((index - 1) % #VILLAGER_SHIRTS) + 1],
		doorSide.Position, streetward.Position, (index - 1) / #VILLAGER_SHIRTS)
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

-- The alchemist's second product. DESIGN.md gives the role "research", and a
-- tonic that only feeds a build menu is not that.
--
-- Three prompts, three keys, and they sit on the BREW rather than the cauldron
-- so the vat keeps E and R to itself. ProximityPrompt exclusivity is per button,
-- and all five are within activation range of each other, so every one needs a
-- key of its own: E works the vat, R trains the alchemist, F/G/H buy research.
local function researchPrompt(host: BasePart, subject: string, key: Enum.KeyCode,
	gamepad: Enum.KeyCode)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ResearchPrompt"
	prompt.ActionText = subject
	prompt.ObjectText = "Research"
	prompt.KeyboardKeyCode = key
	prompt.GamepadKeyCode = gamepad
	prompt.HoldDuration = 0.6
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("Research", subject)
	prompt.Parent = host
end

-- The blacksmith's second product, and the only prompt that hands out a TOOL.
--
-- Its own key. ProximityPrompt exclusivity is per BUTTON, so three prompts can
-- share the anvil as long as they do not share a keycode: E works it, R trains
-- the smith, F forges a blade.
local function forgePrompt(host: BasePart)
	local forge = Instance.new("ProximityPrompt")
	forge.Name = "ForgePrompt"
	forge.ActionText = "Forge a blade"
	forge.ObjectText = "Blacksmith"
	forge.KeyboardKeyCode = Enum.KeyCode.F
	forge.GamepadKeyCode = Enum.KeyCode.ButtonX
	forge.HoldDuration = 0.6
	forge.MaxActivationDistance = 16
	forge.RequiresLineOfSight = false
	forge.Parent = host
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
	local forgeGlow = sitePart(into, "ForgeGlow", Vector3.new(2.4, 1.2, 2.4),
		at * CFrame.new(-SHOP.width / 2 + 3, 19.6, -SHOP.depth / 2 + 3),
		Enum.Material.Neon, Color3.fromRGB(226, 128, 62))
	-- A working forge, so: dirtier and faster than a cottage hearth, with
	-- embers riding up on it.
	plume(forgeGlow, "ForgeSmoke", Vector3.new(0, 1.2, 0), {
		texture = SMOKE_TEXTURE,
		rate = 7,
		life = NumberRange.new(3.0, 4.6),
		speed = NumberRange.new(4.5, 6.0),
		sizeFrom = 2.0,
		sizeTo = 6.5,
		colour = ColorSequence.new(Color3.fromRGB(150, 146, 142), Color3.fromRGB(96, 94, 92)),
		opacity = 0.24,
		spread = 9,
		drift = Vector3.new(0.8, 1.1, 0.3),
		glow = 0,
		lit = 0.7,
	})
	plume(forgeGlow, "Embers", Vector3.new(0, 0.9, 0), {
		texture = SPARK_TEXTURE,
		rate = 16,
		life = NumberRange.new(0.7, 1.5),
		speed = NumberRange.new(7, 11),
		sizeFrom = 0.6,
		sizeTo = 0,
		colour = ColorSequence.new(Color3.fromRGB(255, 196, 96), Color3.fromRGB(214, 84, 34)),
		opacity = 0,
		spread = 18,
		-- Embers slow, stall and drop: gravity beats the updraught.
		drift = Vector3.new(0.8, -7, 0.3),
		glow = 1,
		lit = 0,
	})
	sitePart(into, "AnvilBlock", Vector3.new(2.6, 2, 2),
		at * CFrame.new(SHOP.width / 2 + 4, 1, 3), Enum.Material.Wood, Color3.fromRGB(78, 56, 38))
	local anvil = sitePart(into, "Anvil", Vector3.new(3.2, 1.3, 1.4),
		at * CFrame.new(SHOP.width / 2 + 4, 2.65, 3), Enum.Material.Metal,
		Color3.fromRGB(64, 66, 72))
	craftPrompt(anvil, "Blacksmith", "Blacksmith")
	forgePrompt(anvil)
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
	local brew = sitePart(into, "Brew", Vector3.new(4.2, 0.4, 4.2),
		at * CFrame.new(SHOP.width / 2 + 4.2, 2.7, 2), Enum.Material.Neon,
		Color3.fromRGB(126, 220, 148))
	-- Slow, cold and green: this should read as a vat working, not a fire.
	plume(brew, "Vapour", Vector3.new(0, 0.3, 0), {
		texture = SMOKE_TEXTURE,
		rate = 5,
		life = NumberRange.new(1.8, 3.0),
		speed = NumberRange.new(1.6, 2.6),
		sizeFrom = 0.7,
		sizeTo = 3.0,
		colour = ColorSequence.new(Color3.fromRGB(178, 246, 186), Color3.fromRGB(112, 176, 128)),
		opacity = 0.32,
		spread = 22,
		drift = Vector3.new(0.3, 0.6, 0.15),
		glow = 0.35,
		lit = 0.4,
	})
	craftPrompt(vat, "Alchemist", "Alchemist")
	researchPrompt(brew, "Masonry", Enum.KeyCode.F, Enum.KeyCode.ButtonX)
	researchPrompt(brew, "Husbandry", Enum.KeyCode.G, Enum.KeyCode.ButtonL1)
	researchPrompt(brew, "Toolcraft", Enum.KeyCode.H, Enum.KeyCode.ButtonR1)
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
	-- Paved, not tilled. Brown earth on a brown terrace is why an unclaimed plot
	-- read as a flat schematic square painted on the ground.
	foundation.Material = Enum.Material.SmoothPlastic
	foundation.Color = Color3.fromRGB(150, 146, 138)
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

	-- ---- the curtain wall, present from the start ----
	-- THIS IS WHAT REPLACES THE FLAT SQUARE. The wall footing, the gatehouse
	-- piers and the corner tower bases used to arrive at stages 9 and 10, so an
	-- unclaimed plot was a slab with a cobbled cross on it - a schematic, not a
	-- place. They are permanent stonework rather than anything the owner pays
	-- for, so the ladder loses nothing by having them here: stage 9 still hangs
	-- the gate, stage 10 still raises the towers to full height.
	--
	-- What a plot reads as now is a walled site waiting to be restored, which is
	-- also a better fit for a game about taking somebody else's castle.
	for side = 0, 3 do
		local yaw = math.rad(90 * side)
		local run = floor * CFrame.Angles(0, yaw, 0)
		-- Two courses, the lower one wider. A batter is what makes a wall base
		-- read as masonry that carries weight rather than as a kerb.
		sitePart(site, "WallFooting", Vector3.new(WALL_HALF * 2, 2.2, WALL_BLOCK.Z + 1.8),
			run * CFrame.new(0, 1.1, WALL_HALF), Enum.Material.SmoothPlastic, CASTLE_STONE_DARK)
		sitePart(site, "WallCourse", Vector3.new(WALL_HALF * 2 - 3, 1.8, WALL_BLOCK.Z),
			run * CFrame.new(0, 3.1, WALL_HALF), Enum.Material.SmoothPlastic, CASTLE_STONE)
	end

	-- Corner tower BASES. Stage 10 stacks the shaft and the spire on these.
	for corner = 0, 3 do
		local yaw = math.rad(90 * corner + 45)
		local reach = WALL_HALF * math.sqrt(2)
		local towerAt = at(math.sin(yaw) * reach, math.cos(yaw) * reach, 0)
		siteDrum(site, "TowerBase", 9.5, 6.5, towerAt, Enum.Material.SmoothPlastic,
			CASTLE_STONE_DARK)
		siteDrum(site, "TowerPlinth", 8.4, 1.4, towerAt * CFrame.new(0, 6.5, 0),
			Enum.Material.SmoothPlastic, CASTLE_STONE)
	end

	-- The gatehouse. Two piers and a lintel: the gate itself is stage 9 and
	-- hangs between them, so an unbuilt plot has an OPENING rather than a wall
	-- with a hole in it.
	local gateAt = foundation.CFrame * RING[GATE_SLOT]
	for _, hand in { -1, 1 } do
		local pier = gateAt * CFrame.new(hand * (WALL_BLOCK.X / 2 + 5.5), -0.5, 0)
		siteDrum(site, "GatePier", 5.6, 19, pier, Enum.Material.SmoothPlastic, CASTLE_STONE)
		siteDrum(site, "GatePierCap", 6.4, 1.6, pier * CFrame.new(0, 19, 0),
			Enum.Material.SmoothPlastic, CASTLE_STONE_DARK)
		spireCap(site, "GatePierRoof", 12.4, 7.0, pier * CFrame.new(0, 20.6, 0), CASTLE_ROOF)
	end
	sitePart(site, "GateLintel",
		Vector3.new(WALL_BLOCK.X + 12, 3.2, WALL_BLOCK.Z + 2.2),
		gateAt * CFrame.new(0, WALL_BLOCK.Y + 5.6, 0), Enum.Material.SmoothPlastic, CASTLE_STONE)
	for merlon = -2, 2 do
		sitePart(site, "GateMerlon", Vector3.new(2.8, 2.6, WALL_BLOCK.Z + 2.2),
			gateAt * CFrame.new(merlon * 5.2, WALL_BLOCK.Y + 8.5, 0),
			Enum.Material.SmoothPlastic, CASTLE_STONE_DARK)
	end

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

	-- 9: the palisade. The FOOTING is permanent stonework and now stands from
	-- the start; what stage 9 buys is the gate hung between the piers. The wall
	-- blocks themselves are drawn by ResourceService from the wall's HP, so they
	-- are not in the blueprint either.
	local palisade = stage(9)
	local gate = sitePart(palisade, "Gate",
		Vector3.new(WALL_BLOCK.X + 1.4, WALL_BLOCK.Y + 4, WALL_BLOCK.Z),
		foundation.CFrame * RING[GATE_SLOT] * CFrame.new(0, (WALL_BLOCK.Y + 4) / 2 + 0.5, 0),
		Enum.Material.SmoothPlastic, CASTLE_TIMBER)
	for band = -1, 1, 2 do
		sitePart(palisade, "GateBand", Vector3.new(WALL_BLOCK.X + 2.2, 1.2, WALL_BLOCK.Z + 0.5),
			gate.CFrame * CFrame.new(0, band * 4.2, 0), Enum.Material.SmoothPlastic,
			CASTLE_STONE_DARK)
	end
	local gateFace = Instance.new("Attachment")
	gateFace.Name = "GateFace"
	gateFace.Parent = gate

	-- 10: the rampart - corner towers closing the four gaps the straight runs
	-- leave, and the last of the wall's strength.
	-- EXAGGERATED PROPORTIONS, per the art direction. The shaft rises 24 studs
	-- off a base that already stands 8, so a finished tower is about 32 - call
	-- it six and a half times a player's height against an 11 stud wall. A tower
	-- that only just clears its own wall is a buttress; the silhouette is the
	-- whole reason a castle reads as a castle from across the island.
	local rampart = stage(10)
	for corner = 0, 3 do
		local yaw = math.rad(90 * corner + 45)
		local reach = WALL_HALF * math.sqrt(2)
		local tower = at(math.sin(yaw) * reach, math.cos(yaw) * reach, 0)
		local shaftAt = tower * CFrame.new(0, 7.9, 0)
		siteDrum(rampart, "CornerTower", 8.0, 24, shaftAt, Enum.Material.SmoothPlastic,
			CASTLE_STONE)
		-- An overhanging parapet, wider than the shaft it sits on.
		siteDrum(rampart, "CornerCap", 9.6, 2.2, shaftAt * CFrame.new(0, 24, 0),
			Enum.Material.SmoothPlastic, CASTLE_STONE_DARK)
		-- Two merlons per side of a SQUARE parapet. Spacing them around a circle
		-- left them floating off the corners once the tower stopped being round.
		local reachOut = 9.6 * 1.7 / 2
		for side = 0, 3 do
			for slot = 0, 1 do
				local yawEdge = math.rad(90 * side)
				local along = (slot * 2 - 1) * reachOut * 0.5
				sitePart(rampart, "TowerMerlon", Vector3.new(3.0, 3.0, 3.0),
					shaftAt * CFrame.Angles(0, yawEdge, 0)
						* CFrame.new(along, 27.7, reachOut - 1.5),
					Enum.Material.SmoothPlastic, CASTLE_STONE)
			end
		end
		spireCap(rampart, "TowerRoof", 17.5, 13, shaftAt * CFrame.new(0, 26.2, 0), CASTLE_ROOF)
	end

	site.Parent = buildSites
	return site
end

-- The villages themselves, built from the spots chosen right at the top of the
-- file. Everything scarce about a plot was settled then; this is only masonry.
for index, spot in plotSpots do
	makePlot(("Base_%02d"):format(index), spot)
end

-- ---------------------------------------------------------------- the ground
-- LAST, deliberately. Every terrace has now been claimed - the plaza and all
-- sixteen villages - so the heightfield can be generated once with every pad
-- already in it. Nothing above needed the ground to exist, because everything
-- above asked groundHeight, which is a function rather than a raycast.
print("[Medieval Land] ground: " .. buildGround())

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

-- The BLADE. Not in StarterPack: nobody starts with a weapon, it has to be
-- forged at a blacksmith, so the template waits in ServerStorage for
-- ResourceService to clone it.
--
-- Deliberately shaped nothing like the four tools. Every one of those is a haft
-- with a head on the end; this is a single long edge with a crossguard, so a
-- player carrying one is identifiable across a courtyard as someone who came to
-- fight rather than to harvest.
do
	local blade = buildTool("Blade", "A forged weapon. Fights, but harvests nothing", 2.4,
		function(headAt, add)
			add("Guard", Vector3.new(1.6, 0.26, 0.36), headAt, IRON_DARK)
			add("Ricasso", Vector3.new(0.44, 0.18, 0.5), headAt * CFrame.new(0, 0, -0.36), IRON)
			add("Edge", Vector3.new(0.36, 0.14, 2.7),
				headAt * CFrame.new(0, 0, -1.7), Color3.fromRGB(202, 208, 218))
			add("Fuller", Vector3.new(0.12, 0.16, 2.3),
				headAt * CFrame.new(0, 0, -1.6), IRON)
			add("Point", Vector3.new(0.22, 0.12, 0.6),
				headAt * CFrame.new(0, 0, -3.28), Color3.fromRGB(224, 230, 238))
			add("Pommel", Vector3.new(0.42, 0.42, 0.42),
				headAt * CFrame.new(0, 0, 2.0), IRON_DARK)
		end)
	blade.Parent = ServerStorage
end

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

-- ---------------------------------------------------------------- surfaces
-- Last, after every builder has had its say, so nothing can be added later in
-- the file and quietly keep a texture. ServerStorage and StarterPack are swept
-- too: the messenger, the unbuilt blueprint stages and the four tools all reach
-- the world eventually, and a tool that arrives textured is as wrong as a wall
-- that was built that way.
do
	local flattened = 0
	for _, root in { Workspace, ServerStorage, StarterPack } do
		flattened += flattenSurfaces(root)
	end
	print(("[Medieval Land] flattened %d surfaces to matte"):format(flattened))
end

-- ---------------------------------------------------------------- lighting
-- No Technology line here on purpose. Roblox migrated this place to unified
-- lighting, so Enum.Technology is legacy and the property is not scriptable
-- anyway - it cannot even be READ from a plugin thread ("lacking capability
-- RobloxScript"). The old pcall that tried to set it was dead code pretending
-- to be a safeguard. Style is set by hand: Lighting -> LightingStyle -> Realistic.

-- THE SUN IS THE DIRECTIONAL LIGHT. Roblox has no DirectionalLight object; the
-- one directional source is the sun, and the only way to aim it is ClockTime
-- (time of day) and GeographicLatitude (how high its arc runs). So "position the
-- directional light" means solving for those two numbers.
--
-- 16.1 / lat 12 put the sun 27.9 degrees up - a fine elevation - but pointing
-- (-0.861, 0.468, -0.199), which is almost straight down the X axis. Village
-- plots are square and axis-aligned, so axis-parallel light hits one wall
-- FACE ON and leaves the adjacent wall no darker: the two faces you can see at
-- once come out the same brightness, and the building reads as a flat sticker.
--
-- Both pairs were found by sweeping ClockTime and GeographicLatitude and
-- measuring GetSunDirection, not by guessing at the solar formula. Scoring for
-- a diagonal azimuth at ~31 degrees elevation:
--
--   axis bias (0 = perfectly diagonal, 1 = straight down an axis)
--     16.1 / lat  12  ->  0.749   one lit face, no contrast between walls
--      8.7 / lat -12  ->  0.045   light rakes across the corner
--
-- 31.9 degrees casts a shadow 1.61x the height of whatever throws it, so a
-- 30-stud keep lays down about 48 studs of shadow. Lower would be more dramatic
-- and would also let the terrain self-shadow into an unreadable mess.
Lighting.ClockTime = 8.7
Lighting.GeographicLatitude = -12
Lighting.GlobalShadows = true

-- SOFTER AGAIN, on purpose. 0.05 was chosen when the brief was "well-defined
-- shadows" and it did that job; a drawn look wants the shadow SHAPE to stay
-- readable while its edge stops being a knife. Animated films almost never show
-- a hard terminator outdoors.
Lighting.ShadowSoftness = 0.26

-- THE CONTRAST RATIO IS A STYLE CHOICE, and it just changed sides.
--
-- Shadows were being erased by ambient fill once, so the fix was to drop the
-- fill and drive the ratio to about 5:1. That is dramatic, and dramatic is a
-- LIVE-ACTION look: deep shadows, high contrast, a strong key. An animated film
-- lights almost the opposite way - a bright key, a lot of bounce, and shadows
-- that are lighter and unmistakably COLOURED rather than dark.
--
-- So the fill comes back up, but with the lesson kept: it comes up TINTED, hard,
-- towards blue-violet. The ratio lands near 2.5:1, which still reads as shadow
-- because the shadow is a different HUE, not merely a darker value. That is the
-- trade the first pass could not make, because its shadows were grey.
Lighting.Brightness = 2.6
-- Slightly under. Bloom, high ambient and a 0.42 saturation lift were each
-- adding apparent exposure and nothing was taking any back, so the first cartoon
-- pass came out bleached rather than bright.
Lighting.ExposureCompensation = -0.06

-- Lifted and tinted, but not so far that the terrain loses its form. At
-- (78,84,120) with 0.55 environment fill the ratio fell under 2:1 and the island
-- went mushy - a cartoon is flat-SHADED, not unshaded.
Lighting.Ambient = Color3.fromRGB(62, 68, 104)
Lighting.OutdoorAmbient = Color3.fromRGB(104, 122, 166)
Lighting.EnvironmentDiffuseScale = 0.42
-- Matte. A cartoon surface does not have a hot specular highlight on it.
Lighting.EnvironmentSpecularScale = 0.18

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
-- Thinner and cleaner. Aerial perspective is a realist's tool: it says "there
-- is a mile of air between us", and a drawn world would rather say "everything
-- is legible". Enough left to keep the far shore from cutting out flat.
atmosphere.Density = 0.24
atmosphere.Offset = 0.05
atmosphere.Haze = 0.12
-- Glare at 0.2 bloomed the whole horizon into the sky and took the coastline
-- with it. The sun is allowed to be bright; the air is not.
atmosphere.Glare = 0.08
atmosphere.Color = Color3.fromRGB(226, 238, 250)
atmosphere.Decay = Color3.fromRGB(112, 168, 214)
atmosphere.Parent = Lighting

-- Volumetric clouds. Free scale reference: an empty sky over open water gives
-- the eye nothing to judge distance against, and this is one instance.
local oldClouds = Terrain:FindFirstChildOfClass("Clouds")
if oldClouds then
	oldClouds:Destroy()
end
local clouds = Instance.new("Clouds")
-- SPARSE, not thick. Cover 0.74 did not read as fat drawn clouds, it read as a
-- grey ceiling over the whole map - past about 0.6 the individual shapes merge
-- and you lose the very thing they were for.
clouds.Cover = 0.46
clouds.Density = 0.5
clouds.Color = Color3.fromRGB(255, 253, 248)
clouds.Parent = Terrain

local sunRays = Instance.new("SunRaysEffect")
sunRays.Intensity = 0.22
sunRays.Spread = 0.94
sunRays.Parent = Lighting

local colorCorrection = Instance.new("ColorCorrectionEffect")
-- SATURATION IS THE WHOLE TRICK. Every colour in the palette was already
-- pushed at source, and this pushes the composite again on top - it is the one
-- control that acts on the mesh trees and the imported kit too, which have
-- colours this file does not own.
--
-- Contrast comes DOWN as saturation goes up. Both raised together is a garish
-- photograph; saturated and low-contrast is a cel.
colorCorrection.Brightness = 0.0
-- Low, but not flat. At 0.06 the palette had nothing to sit against and the
-- whole island read as one pale wash.
colorCorrection.Contrast = 0.14
colorCorrection.Saturation = 0.42
colorCorrection.TintColor = Color3.fromRGB(255, 253, 249)
colorCorrection.Parent = Lighting

-- Threshold raised so bloom picks out the genuinely bright things - the sun on
-- water, the forge, the totem beacon - instead of smearing every pale wall.
local bloom = Instance.new("BloomEffect")
-- A soft glow off genuinely bright things only. At threshold 1.15 every pale
-- wall and every sunlit facet cleared the bar, so the entire map glowed and the
-- effect stopped being a highlight and became a fog.
bloom.Intensity = 0.3
bloom.Size = 28
bloom.Threshold = 1.7
bloom.Parent = Lighting

print(("[Medieval Land] Island r~%d, %d nodes, %d village plots, 4 tools."):format(
	ISLAND_RADIUS, nodeCount, #plotSpots
))

end
