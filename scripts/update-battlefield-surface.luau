--!strict
-- Run once in Studio Edit after importing battlefield_surface_update.fbx
-- with Scale Unit: Stud. Replaces only BF_Terrain_* and adds BF_Grass_* to
-- Workspace.Battlefield. The grass is visual-only; old terrain collision stays.

local Workspace = game:GetService("Workspace")
local existing = Workspace:FindFirstChild("Battlefield")
assert(existing and existing:IsA("Model"), "Workspace.Battlefield is missing")

local function pieces(container: Instance, prefix: string): {MeshPart}
	local found = {}
	for _, child in container:GetDescendants() do
		if child:IsA("MeshPart") and child.Name:sub(1, #prefix) == prefix then
			table.insert(found, child)
		end
	end
	table.sort(found, function(a, b) return a.Name < b.Name end)
	return found
end

local oldTerrain = pieces(existing, "BF_Terrain_")
assert(#oldTerrain == 340, "Expected 340 existing battlefield terrain tiles")
assert(#pieces(existing, "BF_Grass_") == 0, "Groundcover is already installed")

local imported: Model? = nil
for _, child in Workspace:GetChildren() do
	if child ~= existing and child:IsA("Model") then
		if #pieces(child, "BF_Terrain_") == #oldTerrain and
			#pieces(child, "BF_Grass_") == 64 then
			assert(imported == nil, "More than one surface update model found")
			imported = child
		end
	end
end
assert(imported, "Import assets/map/battlefield_surface_update.fbx first")

local newTerrain = pieces(imported, "BF_Terrain_")
local newGrass = pieces(imported, "BF_Grass_")
for i, old in oldTerrain do
	assert(newTerrain[i].Name == old.Name, "Terrain tile names do not match")
end

-- Two distant tiles establish scale and yaw even when Studio places the
-- imported model far from the map or turns it 180 degrees.
local first, last = 1, #oldTerrain
local wanted = oldTerrain[last].Position - oldTerrain[first].Position
local span = newTerrain[last].Position - newTerrain[first].Position
assert(math.abs(span.Magnitude - wanted.Magnitude) < 1,
	"Surface import scale is wrong; choose Scale Unit: Stud")
local theta = math.atan2(-wanted.Z, wanted.X) - math.atan2(-span.Z, span.X)
local transform = CFrame.new(oldTerrain[first].Position) *
	CFrame.Angles(0, theta, 0) * CFrame.new(-newTerrain[first].Position)
imported:PivotTo(transform * imported:GetPivot())

-- Validate every replacement before touching the live terrain.
for i, old in oldTerrain do
	local replacement = newTerrain[i]
	assert((old.Position - replacement.Position).Magnitude < 0.2,
		old.Name .. " did not align with the battlefield")
	assert((old.Size - replacement.Size).Magnitude < 0.25,
		old.Name .. " imported at the wrong scale")
end

for i, old in oldTerrain do
	local replacement = newTerrain[i]
	replacement.Anchored = true
	replacement.Color = Color3.new(1, 1, 1) -- expose FBX vertex colours
	replacement.CollisionFidelity = old.CollisionFidelity
	replacement.CanCollide = old.CanCollide
	replacement.CanTouch = old.CanTouch
	replacement.CanQuery = old.CanQuery
	replacement.CastShadow = old.CastShadow
	replacement.Parent = existing
	old:Destroy()
end

for _, grass in newGrass do
	grass.Anchored = true
	grass.Color = Color3.new(1, 1, 1)
	grass.CanCollide = false
	grass.CanTouch = false
	grass.CanQuery = false
	grass.CastShadow = false -- grass shadows are too costly at this density
	grass.Parent = existing
end
imported:Destroy()
print("Updated 340 battlefield terrain tiles and added 64 noncolliding grass tiles")
