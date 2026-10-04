-- After importing assets/map/village_paths_A.fbx with Studio's 3D importer (Edit datamodel).
-- Places A_VillagePaths where assets/map/build_village_paths.py built it, gives it the
-- VillageHerringbone surface (creating that MaterialVariant), and parents it to Workspace.VillagePaths.
--
-- The importer turns models 180 degrees about Y and drops them near the camera, so the part is
-- moved to the known bounds centre and the turn is chosen by raycast: a point on the Fletcher
-- branch must be paved, and the same point turned 180 degrees about the centre must not be.

local Workspace = game:GetService("Workspace")
local MaterialService = game:GetService("MaterialService")

local CENTRE = Vector3.new(-260.1011, 9.85, -2.0840) -- bounds centre in Roblox space (from the builder)
local ON_PATH = Vector3.new(-228, 0, -20)

-- the paving surface: original herringbone from assets/textures/build_herringbone.py, uploaded
local variant = MaterialService:FindFirstChild("VillageHerringbone") or Instance.new("MaterialVariant")
variant.Name = "VillageHerringbone"
variant.BaseMaterial = Enum.Material.Pavement
variant.ColorMap = "rbxassetid://119328617010094"
variant.NormalMap = "rbxassetid://93747524144365"
variant.RoughnessMap = "rbxassetid://106348438972116"
variant.StudsPerTile = 8 -- bricks about 1 x 0.5 studs
variant.Parent = MaterialService

local part: MeshPart? = nil
for _, d in Workspace:GetDescendants() do
	if d:IsA("MeshPart") and d.Name == "A_VillagePaths" and not d:IsDescendantOf(Workspace:FindFirstChild("VillagePaths") or Workspace.Terrain) then
		part = d
	end
end
assert(part, "imported A_VillagePaths not found in Workspace")
local imported = part.Parent

local folder = Workspace:FindFirstChild("VillagePaths")
if folder then
	folder:ClearAllChildren() -- older copies, including the in-memory EditableMesh try
else
	folder = Instance.new("Folder")
	folder.Name = "VillagePaths"
	folder.Parent = Workspace
end
part.Parent = folder
if imported and imported ~= Workspace and #imported:GetChildren() == 0 then
	imported:Destroy()
end

part.Anchored = true
part.CanCollide = false
part.CanTouch = false
part.CastShadow = false
part.Material = Enum.Material.Pavement
part.MaterialVariant = "VillageHerringbone"
-- slight warm tint: the paving renders lum ~103-112, sat ~0.19, on The Forge's plaza tile (120,106,96)
part.Color = Color3.fromRGB(255, 242, 222)
part.CanQuery = true -- for the orientation test, off again below

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { part }
local function paved(p: Vector3): boolean
	return Workspace:Raycast(Vector3.new(p.X, 40, p.Z), Vector3.new(0, -60, 0), params) ~= nil
end
local mirrored = Vector3.new(2 * CENTRE.X - ON_PATH.X, 0, 2 * CENTRE.Z - ON_PATH.Z)

local chosen = nil
for _, yaw in { 0, 180 } do
	part.CFrame = CFrame.new(CENTRE) * CFrame.Angles(0, math.rad(yaw), 0)
	if paved(ON_PATH) and not paved(mirrored) then
		chosen = yaw
		break
	end
end
part.CanQuery = false
part.CollisionFidelity = Enum.CollisionFidelity.Box -- never collides; after the test, which needs the real shape
assert(chosen, "orientation test failed: neither 0 nor 180 degrees puts the Fletcher branch in place")
return string.format("A_VillagePaths placed at %s, yaw %d, size %s", tostring(part.Position), chosen, tostring(part.Size))
