-- Phase 1 proof-of-look patch at Castle A's gate (REALISM-TARGET.md). Run in Studio's Edit
-- datamodel (command bar or MCP). Works on the v2.0 battlefield import (Workspace.Battlefield).
--
-- What it does, all reversible (set MODE = "revert" and run again):
--   * voxel Terrain over x -440..-28, z -152..136, sampled by raycast from the mesh ground it
--     replaces (the BF_Terrain cells and crater wedges there are hidden, not deleted);
--     grass / leafy grass / bare dirt / road / crater mud / slope rock; inside Castle A a light
--     packed courtyard with worn patches, grass verges and forge mud (paths: assets/map/build_village_paths.py);
--   * Castle A shell: Cobblestone, darkened by the Color multiply on the vertex colours;
--     barricades WoodPlanks, banners Fabric, tunnel mouths and rocks Rock, pines Grass texture;
--   * two braziers and two gate torches (warm local light, no collision).
-- Every changed property is stored first as a Proof_* attribute on the instance it belongs to.
-- Terrain grass decoration (Workspace.Terrain.Decoration) cannot be set from scripts; tick it
-- by hand in Properties.

local MODE = "apply" -- or "revert"

local Workspace = game:GetService("Workspace")
local T = Workspace.Terrain
local bf = Workspace:FindFirstChild("Battlefield")
assert(bf, "needs Workspace.Battlefield (the v2.0 battlefield import)")

local X0, X1, Z0, Z1 = -440, -28, -152, 136 -- multiples of 4; all of Castle A and the ground behind it
local RES = 4
local GRASS_PIECES = { "BF_Grass_02_03", "BF_Grass_02_04", "BF_Grass_03_03", "BF_Grass_03_04" }

-- v2.0 layout features in the patch (Roblox coordinates)
local CASTLE = { x = -280, z = 0, half = 91.8 }
local ROAD = { x0 = -188.2, x1 = 188.2, half = 15 }
local CRATERS = { { x = -105, z = -65, r = 18, rf = 9 }, { x = -55, z = 48, r = 18, rf = 9 } }
-- Castle A buildings (v2.1 interior as imported: Workspace.CastleInteriors footprints)
local BUILDINGS = {
	{ x = -334, z = 0, hx = 23, hz = 23 }, -- Keep
	{ x = -329, z = -61, hx = 22, hz = 14.5 }, -- Barracks
	{ x = -286, z = -63, hx = 12.5, hz = 13.5 }, -- Alchemist
	{ x = -227, z = -63, hx = 13, hz = 13.5 }, -- Fletcher
	{ x = -278, z = 61, hx = 14.5, hz = 14.5, mud = true }, -- Blacksmith forge
	{ x = -237, z = 60, hx = 12.5, hz = 14.5 }, -- Carpenter
}

-- base colours multiply the material textures; tuned under the Gritty preset until the eye-level
-- samples hit REALISM-TARGET.md (grass lum ~105-115, road ~125, walls ~90, roofs ~35, pines ~32)
local TERRAIN_COLOURS = {
	[Enum.Material.Grass] = Color3.fromRGB(148, 150, 130),
	[Enum.Material.LeafyGrass] = Color3.fromRGB(132, 136, 116),
	[Enum.Material.Ground] = Color3.fromRGB(186, 174, 160),
	[Enum.Material.Mud] = Color3.fromRGB(120, 104, 90),
	[Enum.Material.Cobblestone] = Color3.fromRGB(160, 150, 138),
	[Enum.Material.Rock] = Color3.fromRGB(110, 104, 100),
	-- courtyard ground, tuned to The Forge's plaza ground: lum ~137 (ours 132-146)
	[Enum.Material.Concrete] = Color3.fromRGB(150, 144, 138),
}
local STONE = Color3.fromRGB(170, 170, 175) -- multiplies the baked light-grey stone and blue roofs
local WOOD = Color3.fromRGB(170, 150, 130)
local ROCK = Color3.fromRGB(230, 215, 195) -- warm multiply: the baked rock colours are blue-grey
local PINE = Color3.fromRGB(255, 255, 255) -- Grass texture only; the overcast light already darkens them

local function remember(p: BasePart)
	if p:GetAttribute("Proof_OrigMaterial") == nil then
		p:SetAttribute("Proof_OrigMaterial", p.Material.Name)
		p:SetAttribute("Proof_OrigColor", p.Color)
	end
end

local function restyle(p: BasePart, material: Enum.Material, color: Color3)
	remember(p)
	p.Material = material
	p.Color = color
end

local function hide(p: BasePart)
	if p:GetAttribute("Proof_Hidden") == nil then
		p:SetAttribute("Proof_Hidden", true)
		p:SetAttribute("Proof_OrigTransparency", p.Transparency)
		p:SetAttribute("Proof_OrigCanCollide", p.CanCollide)
		p:SetAttribute("Proof_OrigCanQuery", p.CanQuery)
		p:SetAttribute("Proof_OrigCanTouch", p.CanTouch)
		p:SetAttribute("Proof_OrigCastShadow", p.CastShadow)
	end
	p.Transparency = 1
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
end

local function inside(p: BasePart, grow: number): boolean
	local lo, hi = p.Position - p.Size / 2, p.Position + p.Size / 2
	return lo.X >= X0 - grow and hi.X <= X1 + grow and lo.Z >= Z0 - grow and hi.Z <= Z1 + grow
end

local function revert()
	for _, d in Workspace:GetDescendants() do
		if d:IsA("BasePart") then
			if d:GetAttribute("Proof_OrigMaterial") ~= nil then
				d.Material = (Enum.Material :: any)[d:GetAttribute("Proof_OrigMaterial")]
				d.Color = d:GetAttribute("Proof_OrigColor")
				d:SetAttribute("Proof_OrigMaterial", nil)
				d:SetAttribute("Proof_OrigColor", nil)
			end
			if d:GetAttribute("Proof_Hidden") then
				d.Transparency = d:GetAttribute("Proof_OrigTransparency")
				d.CanCollide = d:GetAttribute("Proof_OrigCanCollide")
				d.CanQuery = d:GetAttribute("Proof_OrigCanQuery")
				d.CanTouch = d:GetAttribute("Proof_OrigCanTouch")
				d.CastShadow = d:GetAttribute("Proof_OrigCastShadow")
				for _, a in { "Hidden", "OrigTransparency", "OrigCanCollide", "OrigCanQuery", "OrigCanTouch", "OrigCastShadow" } do
					d:SetAttribute("Proof_" .. a, nil)
				end
			end
		end
	end
	for material in TERRAIN_COLOURS do
		local saved = T:GetAttribute("Proof_MC_" .. material.Name)
		if saved ~= nil then
			T:SetMaterialColor(material, saved)
			T:SetAttribute("Proof_MC_" .. material.Name, nil)
		end
	end
	if T:GetAttribute("Proof_TerrainWasEmpty") then
		T:Clear()
		T:SetAttribute("Proof_TerrainWasEmpty", nil)
	end
	local f = Workspace:FindFirstChild("ProofOfLook")
	if f then
		f:Destroy()
	end
	return "reverted"
end

if MODE == "revert" then
	return revert()
end

-- 1. sample the existing mesh ground (on a re-run, the hidden pieces are made queryable again first)
local function queryable(p: BasePart)
	if p:GetAttribute("Proof_Hidden") then
		p.CanQuery = p:GetAttribute("Proof_OrigCanQuery")
	end
end
local cells, include = {}, {}
for _, p in bf:GetChildren() do
	if p:IsA("BasePart") and p.Name:match("^BF_Terrain_") and inside(p, 2.5) then
		table.insert(cells, p)
		queryable(p)
		if p.CanQuery then
			table.insert(include, p)
		end
	end
end
local craterFolders = {}
local cc = bf:FindFirstChild("CraterCollision")
for _, p in cells do
	local f = cc and cc:FindFirstChild(p.Name)
	if f then
		table.insert(craterFolders, f)
		table.insert(include, f)
		for _, w in f:GetDescendants() do
			if w:IsA("BasePart") then
				queryable(w)
			end
		end
	end
end
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = include

local NX, NZ = (X1 - X0) // RES, (Z1 - Z0) // RES
local H, misses = {}, 0
local hmin, hmax = math.huge, -math.huge
for i = 1, NX do
	H[i] = {}
	for k = 1, NZ do
		local x, z = X0 + (i - 0.5) * RES, Z0 + (k - 0.5) * RES
		local hit = Workspace:Raycast(Vector3.new(x, 80, z), Vector3.new(0, -140, 0), params)
		local h = hit and hit.Position.Y
		if not h then
			misses += 1
		else
			hmin, hmax = math.min(hmin, h), math.max(hmax, h)
		end
		H[i][k] = h
	end
end
for i = 1, NX do -- fill misses from the nearest sampled neighbour
	for k = 1, NZ do
		if not H[i][k] then
			for r = 1, 6 do
				for di = -r, r do
					for dk = -r, r do
						local row = H[i + di]
						if not H[i][k] and row and row[k + dk] then
							H[i][k] = row[k + dk]
						end
					end
				end
			end
			H[i][k] = H[i][k] or 10
		end
	end
end

-- 2. materials per column
-- The courtyard follows The Forge's plaza: a light, plain packed ground with worn patches. The paved
-- streets are a separate crisp-edged mesh on top (assets/map/build_village_paths.py): terrain blends
-- materials across its 4-stud voxels, so it cannot draw a clean paving edge. (Also measured: Brick
-- terrain fills its whole voxel at any occupancy; Pavement and Concrete snap to whole studs.)
local function courtyard(x: number, z: number): Enum.Material
	for _, b in BUILDINGS do
		local edge = math.max(math.abs(x - b.x) - b.hx, math.abs(z - b.z) - b.hz)
		if b.mud and edge <= 9 + 3 * math.noise(x / 6, z / 6, 5.5) then
			return Enum.Material.Mud -- smithy grime
		end
	end
	-- grass survives along the foot of the walls, away from traffic
	local toWall = CASTLE.half - math.max(math.abs(x - CASTLE.x), math.abs(z - CASTLE.z))
	if toWall < 15 + 5 * math.noise(x / 17, z / 17, 2.2) then
		return Enum.Material.Grass
	end
	if math.noise(x / 23, z / 23, 9.7) + 0.4 * math.noise(x / 7, z / 7, 3.3) > 0.3 then
		return Enum.Material.Ground -- worn dirt patches
	end
	return Enum.Material.Concrete -- light packed ground
end

local function material(x: number, z: number, slope: number): Enum.Material
	if math.abs(x - CASTLE.x) <= CASTLE.half and math.abs(z - CASTLE.z) <= CASTLE.half then
		return courtyard(x, z)
	end
	for _, c in CRATERS do
		local d = math.sqrt((x - c.x) ^ 2 + (z - c.z) ^ 2)
		if d < c.rf + 0.5 then
			return Enum.Material.Mud
		elseif d < (c.rf + c.r) / 2 then
			return Enum.Material.Ground
		end
	end
	local y = -z -- the Blender builder's wobble, so the dirt edge matches the old painted road
	local wobble = 3 * (0.5 + 0.25 * math.sin(x / 13 + y / 9) + 0.25 * math.sin(x / 5.7 - y / 17))
	if x >= ROAD.x0 - 6 and x <= ROAD.x1 and math.abs(z) <= ROAD.half + wobble then
		return Enum.Material.Ground
	end
	if slope > 0.75 then
		return Enum.Material.Rock
	end
	local n = math.noise(x / 46, z / 46, 0.37) + 0.5 * math.noise(x / 13, z / 13, 4.1)
	if n < -0.42 then
		return Enum.Material.Ground -- dry bare patches
	elseif n > 0.3 then
		return Enum.Material.LeafyGrass
	end
	return Enum.Material.Grass
end

local Y0 = math.floor((hmin - 8) / RES) * RES
local Y1 = math.ceil((hmax + 4) / RES) * RES
local NY = (Y1 - Y0) // RES
local mats, occ = {}, {}
for i = 1, NX do
	mats[i], occ[i] = {}, {}
	for j = 1, NY do
		mats[i][j], occ[i][j] = {}, {}
	end
	for k = 1, NZ do
		local h = H[i][k]
		local gx = ((H[i + 1] and H[i + 1][k] or h) - (H[i - 1] and H[i - 1][k] or h)) / (2 * RES)
		local gz = ((H[i][k + 1] or h) - (H[i][k - 1] or h)) / (2 * RES)
		local m = material(X0 + (i - 0.5) * RES, Z0 + (k - 0.5) * RES, math.sqrt(gx * gx + gz * gz))
		for j = 1, NY do
			local y0 = Y0 + (j - 1) * RES
			-- measured in Studio: over a full voxel, the surface sits at (partial voxel's base + 2 + 4 * occupancy)
			local o = math.clamp((h - 2 - y0) / RES, 0, 1)
			occ[i][j][k] = o
			mats[i][j][k] = if o > 0 then m else Enum.Material.Air
		end
	end
end

if T:GetAttribute("Proof_TerrainWasEmpty") == nil then
	T:SetAttribute("Proof_TerrainWasEmpty", T:CountCells() == 0)
end
for m, c in TERRAIN_COLOURS do
	if T:GetAttribute("Proof_MC_" .. m.Name) == nil then
		T:SetAttribute("Proof_MC_" .. m.Name, T:GetMaterialColor(m))
	end
	T:SetMaterialColor(m, c)
end
T:WriteVoxels(Region3.new(Vector3.new(X0, Y0, Z0), Vector3.new(X1, Y1, Z1)), RES, mats, occ)

-- 3. hide what the terrain replaces
for _, p in cells do
	hide(p)
end
for _, f in craterFolders do
	for _, w in f:GetDescendants() do
		if w:IsA("BasePart") then
			hide(w)
		end
	end
end
for _, name in GRASS_PIECES do
	local p = bf:FindFirstChild(name)
	if p then
		hide(p)
	end
end

-- 4. textured materials on Castle A and the nearby props
local styled = 0
for _, p in bf:GetChildren() do
	if p:IsA("BasePart") then
		local n = p.Name
		if n:match("^A_Wall_") or n:match("^A_Tower_") or n == "A_Gate" then
			restyle(p, Enum.Material.Cobblestone, STONE)
		elseif n:match("^A_Barricade_") then
			restyle(p, Enum.Material.WoodPlanks, WOOD)
		elseif n:match("^A_Banner") then
			restyle(p, Enum.Material.Fabric, p.Color)
		elseif n:match("^A_Tunnel") or n:match("^BF_Cover") then
			restyle(p, Enum.Material.Rock, ROCK)
		elseif n:match("^BF_Pines_") then
			restyle(p, Enum.Material.Grass, PINE)
		else
			continue
		end
		styled += 1
	end
end

-- 5. warm local light at the gate: two braziers on the field side and two torches on the gatehouse
local folder = Workspace:FindFirstChild("ProofOfLook") or Instance.new("Folder")
folder.Name = "ProofOfLook"
folder.Parent = Workspace
folder:ClearAllChildren()
local gate = bf:FindFirstChild("A_Gate") :: BasePart
local front = gate.Position.X + gate.Size.X / 2

local function part(name: string, size: Vector3, cf: CFrame, mat: Enum.Material, color: Color3, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Material = mat
	p.Color = color
	p.Shape = shape or Enum.PartType.Block
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false -- the light sits on these; a shadow would black out the ground under them
	p.Parent = folder
	return p
end

local function flame(p: BasePart, lift: number, size: number, brightness: number, range: number)
	local a = Instance.new("Attachment") -- just above the part, so the part does not shade its own light
	a.Parent = p
	a.WorldPosition = p.Position + Vector3.new(0, lift, 0)
	local fire = Instance.new("Fire")
	fire.Size = size
	fire.Heat = size * 1.5
	fire.Color = Color3.fromRGB(236, 139, 61)
	fire.SecondaryColor = Color3.fromRGB(139, 70, 40)
	fire.Parent = a
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 150, 80)
	light.Brightness = brightness
	light.Range = range
	light.Shadows = true
	light.Parent = a
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { T }
for _, side in { -1, 1 } do
	local x, z = front + 6, side * 19
	local hit = Workspace:Raycast(Vector3.new(x, 60, z), Vector3.new(0, -100, 0), groundParams)
	local y = hit and hit.Position.Y or 10
	part("Brazier_Post_" .. side, Vector3.new(0.9, 3.2, 0.9), CFrame.new(x, y + 1.6, z), Enum.Material.WoodPlanks, Color3.fromRGB(92, 66, 48))
	local bowl = part("Brazier_Bowl_" .. side, Vector3.new(1.2, 2.6, 2.6), CFrame.new(x, y + 3.7, z) * CFrame.Angles(0, 0, math.pi / 2),
		Enum.Material.CorrodedMetal, Color3.fromRGB(70, 62, 56), Enum.PartType.Cylinder)
	flame(bowl, 0.9, 3.5, 2.2, 26)
	local torch = part("GateTorch_" .. side, Vector3.new(0.5, 2.2, 0.5), CFrame.new(front + 0.8, 13, side * 9.5) * CFrame.Angles(0, 0, math.rad(-20)),
		Enum.Material.WoodPlanks, Color3.fromRGB(80, 58, 42))
	flame(torch, 1.3, 1.6, 1.4, 16)
end

return string.format("terrain %dx%dx%d voxels, y %d..%d, ground h %.1f..%.1f, %d ray misses; hid %d cells, %d crater folders; styled %d parts",
	NX, NY, NZ, Y0, Y1, hmin, hmax, misses, #cells, #craterFolders, styled)
