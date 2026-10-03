--!strict
-- Run once in Studio Edit mode after importing blacksmith_floor_update.fbx
-- with Scale Unit: Stud. Replaces only the six mirrored blacksmith floor
-- meshes in Workspace.CastleInteriors; all other imported pieces stay put.

local Workspace = game:GetService("Workspace")
local existing = Workspace:FindFirstChild("CastleInteriors")
assert(existing and existing:IsA("Model"), "Workspace.CastleInteriors is missing")

local ids = {
	"A_Blacksmith_Forecourt", "A_Blacksmith_Forge_Detail",
	"A_Blacksmith_Forge",
	"B_Blacksmith_Forecourt", "B_Blacksmith_Forge_Detail",
	"B_Blacksmith_Forge",
}

local function piece(container: Instance, id: string): MeshPart
	local found = container:FindFirstChild(id, true)
	assert(found and found:IsA("MeshPart"), id .. " is missing from " .. container.Name)
	return found
end

local imported: Model? = nil
for _, child in Workspace:GetChildren() do
	if child ~= existing and child:IsA("Model") then
		local found = true
		for _, id in ids do
			if not child:FindFirstChild(id, true) then found = false; break end
		end
		if found then
			assert(imported == nil, "More than one floor-update import found; leave only one in Workspace")
			imported = child
		end
	end
end
assert(imported, "Import assets/castle/blacksmith_floor_update.fbx first")

local targetA = piece(existing, ids[1])
local targetB = piece(existing, ids[4])
local newA = piece(imported, ids[1])
local newB = piece(imported, ids[4])
local wanted = targetB.Position - targetA.Position
local span = newB.Position - newA.Position
assert(math.abs(span.Magnitude - wanted.Magnitude) < 1,
	"Floor import scale is wrong; choose Scale Unit: Stud")
local theta = math.atan2(-wanted.Z, wanted.X) - math.atan2(-span.Z, span.X)
local transform = CFrame.new(targetA.Position) * CFrame.Angles(0, theta, 0) * CFrame.new(-newA.Position)
imported:PivotTo(transform * imported:GetPivot())

-- Validate anchors before removing the old geometry. The updated visual detail
-- spans more of the forge floor, so its bounding-box center differs from the
-- old mesh even when the floor and shell are correctly aligned.
for _, id in ids do
	local old = piece(existing, id)
	local replacement = piece(imported, id)
	if id:find("_Forge_Detail") then
		local side = id:sub(1, 1)
		local oldShell = piece(existing, side .. "_Blacksmith_Forge")
		local newShell = piece(imported, side .. "_Blacksmith_Forge")
		assert(math.abs((old.Position - oldShell.Position).Y -
			(replacement.Position - newShell.Position).Y) < 0.15,
			id .. " is at the wrong floor height")
		assert(math.abs(replacement.Position.X - newShell.Position.X) < 1 and
			math.abs(replacement.Position.Z - newShell.Position.Z) < 1,
			id .. " is outside the forge shell")
	else
		assert((old.Position - replacement.Position).Magnitude < 0.15,
			id .. " did not align with the existing castle")
	end
	assert(replacement.Size.X > 1 and replacement.Size.Z > 1,
		id .. " has an invalid import scale")
end

for _, id in ids do
	local old = piece(existing, id)
	local replacement = piece(imported, id)
	replacement.Anchored = true
	replacement.Color = Color3.new(1, 1, 1) -- preserve Blender per-face colors
	replacement.CastShadow = true
	if id:find("_Forecourt") then
		-- The curved terrace is a walkable complex mesh, unlike the old flat grid.
		replacement.CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition
		replacement.CanCollide = true
	elseif id:find("_Forge_Detail") then
		replacement.CanCollide = false
		replacement.CanTouch = false
	else
		-- The shell carries the dark foundation floor and the physical forge walls.
		replacement.CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition
		replacement.CanCollide = true
	end
	replacement.Parent = existing
	old:Destroy()
end
imported:Destroy()
print("Updated six blacksmith forecourt, floor, and shell meshes; other castle meshes unchanged")
