-- Builds the whole layout.json v2.2 island as Roblox voxel Terrain. Run in Studio's Edit datamodel.
--
-- Source: assets/map/terrain_v2_2.png, written by assets/map/build_terrain_data.py from the
-- battlefield builder's own height function and uploaded as an image asset (DATA_IMAGE). One
-- pixel per 4 x 4-stud column: R, G = 16-bit height, B = material code. The upload was checked
-- byte-exact against the file (sample pixels and a whole-image checksum).
--
-- Surface rule, measured in Studio 2026-10-03: over a full voxel, smooth terrain's surface sits at
-- (partial voxel's base + 2 + 4 * occupancy), so a column of height h gets
-- occupancy = clamp((h - 2 - voxel base) / 4, 0, 1).
-- Replaces the mesh ground of battlefield_v2_2.fbx; the meshes above the ground come from
-- assets/map/battlefield_v2_2_props.fbx. Clears all existing Terrain first.

local DATA_IMAGE = "rbxassetid://72718303007861"
local X0, Z0, STEP = -936, -480, 4 -- must match build_terrain_data.py
local SCALE, OFFSET = 500, 64
local Y0, Y1 = -32, 16 -- heights run -22 .. +10
local STRIP = 32 -- columns per WriteVoxels call

local MATERIALS = {
	[1] = Enum.Material.Grass,
	[2] = Enum.Material.LeafyGrass,
	[3] = Enum.Material.Ground,
	[4] = Enum.Material.Mud,
	[5] = Enum.Material.Rock,
	[6] = Enum.Material.Sand,
	[7] = Enum.Material.Concrete,
}
-- base colours multiply the material textures; tuned under the Gritty preset (REALISM-TARGET.md)
local COLOURS = {
	[Enum.Material.Grass] = Color3.fromRGB(148, 150, 130),
	[Enum.Material.LeafyGrass] = Color3.fromRGB(132, 136, 116),
	[Enum.Material.Ground] = Color3.fromRGB(186, 174, 160),
	[Enum.Material.Mud] = Color3.fromRGB(120, 104, 90),
	[Enum.Material.Rock] = Color3.fromRGB(110, 104, 100),
	[Enum.Material.Sand] = Color3.fromRGB(178, 166, 146),
	[Enum.Material.Concrete] = Color3.fromRGB(150, 144, 138),
}

local AssetService = game:GetService("AssetService")
local T = workspace.Terrain

local image = AssetService:CreateEditableImageAsync(Content.fromUri(DATA_IMAGE))
local w, h = image.Size.X, image.Size.Y
local pixels = image:ReadPixelsBuffer(Vector2.zero, image.Size)
local function column(i: number, j: number): (number, Enum.Material)
	local o = (j * w + i) * 4
	local height = (buffer.readu8(pixels, o) * 256 + buffer.readu8(pixels, o + 1)) / SCALE - OFFSET
	return height, MATERIALS[buffer.readu8(pixels, o + 2)] or Enum.Material.Grass
end

for material, colour in COLOURS do
	T:SetMaterialColor(material, colour)
end
T:Clear()

local NY = (Y1 - Y0) // STEP
local lo, hi = math.huge, -math.huge
for i0 = 0, w - 1, STRIP do
	local n = math.min(STRIP, w - i0)
	local mats, occ = {}, {}
	for a = 1, n do
		mats[a], occ[a] = {}, {}
		for b = 1, NY do
			mats[a][b], occ[a][b] = {}, {}
		end
		for j = 0, h - 1 do
			local height, material = column(i0 + a - 1, j)
			lo, hi = math.min(lo, height), math.max(hi, height)
			for b = 1, NY do
				local o = math.clamp((height - 2 - (Y0 + (b - 1) * STEP)) / STEP, 0, 1)
				occ[a][b][j + 1] = o
				mats[a][b][j + 1] = if o > 0 then material else Enum.Material.Air
			end
		end
	end
	local x0 = X0 + i0 * STEP
	T:WriteVoxels(Region3.new(Vector3.new(x0, Y0, Z0), Vector3.new(x0 + n * STEP, Y1, Z0 + h * STEP)), STEP, mats, occ)
	task.wait()
end
image:Destroy()
return string.format("terrain %d x %d columns, heights %.2f .. %.2f", w, h, lo, hi)
