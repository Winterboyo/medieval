-- After importing assets/map/village_paths_v2_2.fbx with Studio's 3D importer (Edit datamodel).
-- Places A_VillagePaths and B_VillagePaths where assets/map/build_village_paths.py built them
-- (layout.json v2.2), gives them the VillageHerringbone surface (creating that MaterialVariant),
-- and parents them to Workspace.VillagePaths.
--
-- The importer turns models 180 degrees about Y and drops them near the camera, so each part is
-- moved to its known bounds centre and the turn is chosen by raycast on Castle A: a point on the
-- Fletcher branch must be paved, and the same point turned 180 degrees about the centre must not be.
-- Both parts were turned together, so B takes the same turn.

local Workspace = game:GetService("Workspace")
local MaterialService = game:GetService("MaterialService")

local CENTRES = { -- bounds centres in Roblox space (from the builder)
	A_VillagePaths = Vector3.new(-400.2667, 9.85, -2.0506),
	B_VillagePaths = Vector3.new(400.2667, 9.85, -2.0506),
}
local ON_PATH = Vector3.new(-368, 0, -20) -- Castle A's Fletcher branch

-- the paving surface: original herringbone from assets/textures/build_herringbone.py, uploaded
local variant = MaterialService:FindFirstChild("VillageHerringbone") or Instance.new("MaterialVariant")
variant.Name = "VillageHerringbone"
variant.BaseMaterial = Enum.Material.Pavement
variant.ColorMap = "rbxassetid://119328617010094"
variant.NormalMap = "rbxassetid://93747524144365"
variant.RoughnessMap = "rbxassetid://106348438972116"
variant.StudsPerTile = 8 -- bricks about 1 x 0.5 studs
variant.Parent = MaterialService

local folder = Workspace:FindFirstChild("VillagePaths")
local parts: { [string]: MeshPart } = {}
for _, d in Workspace:GetDescendants() do
	if d:IsA("MeshPart") and CENTRES[d.Name] and not (folder and d:IsDescendantOf(folder)) then
		parts[d.Name] = d
	end
end
assert(parts.A_VillagePaths and parts.B_VillagePaths, "import assets/map/village_paths_v2_2.fbx first")
local imported = parts.A_VillagePaths.Parent

if folder then
	folder:ClearAllChildren() -- older copies
else
	folder = Instance.new("Folder")
	folder.Name = "VillagePaths"
	folder.Parent = Workspace
end
for _, part in parts do
	part.Parent = folder
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Pavement
	part.MaterialVariant = "VillageHerringbone"
	-- slight warm tint: the paving renders lum ~103-112, sat ~0.19, on The Forge's plaza tile (120,106,96)
	part.Color = Color3.fromRGB(255, 242, 222)
end
if imported and imported ~= Workspace and #imported:GetChildren() == 0 then
	imported:Destroy()
end

local a = parts.A_VillagePaths
a.CanQuery = true -- for the orientation test, off again below
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { a }
local function paved(p: Vector3): boolean
	return Workspace:Raycast(Vector3.new(p.X, 40, p.Z), Vector3.new(0, -60, 0), params) ~= nil
end
local centre = CENTRES.A_VillagePaths
local mirrored = Vector3.new(2 * centre.X - ON_PATH.X, 0, 2 * centre.Z - ON_PATH.Z)
local chosen = nil
for _, yaw in { 0, 180 } do
	a.CFrame = CFrame.new(centre) * CFrame.Angles(0, math.rad(yaw), 0)
	if paved(ON_PATH) and not paved(mirrored) then
		chosen = yaw
		break
	end
end
assert(chosen, "orientation test failed: neither 0 nor 180 degrees puts the Fletcher branch in place")
for name, part in parts do
	part.CFrame = CFrame.new(CENTRES[name]) * CFrame.Angles(0, math.rad(chosen), 0)
	part.CanQuery = false
	part.CollisionFidelity = Enum.CollisionFidelity.Box -- never collides; after the test, which needs the real shape
end
return string.format("village paths placed, yaw %d", chosen)
