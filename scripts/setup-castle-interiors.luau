--!strict
-- Run once in Studio Edit mode after 3D-importing
-- assets/castle/castle_interiors.fbx (Scale Unit: Stud).
-- The file contains 40 named interior pieces at the approved mirrored layout.
-- This aligns the import with Workspace.Battlefield and prepares shadows/physics.

local Workspace = game:GetService("Workspace")
local refName = "A_Blacksmith_Forecourt"
local checkName = "B_Blacksmith_Forecourt"
local model: Model? = nil
for _, child in Workspace:GetChildren() do
	if child:IsA("Model") and child:FindFirstChild(refName, true)
		and child:FindFirstChild(checkName, true) then
		model = child
		break
	end
end
assert(model, "Import assets/castle/castle_interiors.fbx with Studio's 3D Importer first")

local ref = model:FindFirstChild(refName, true) :: MeshPart
local check = model:FindFirstChild(checkName, true) :: MeshPart
assert(ref:IsA("MeshPart") and check:IsA("MeshPart"), "Forecourt reference meshes were not imported")

-- Roblox's importer rotated battlefield.fbx by 180 degrees and dropped it
-- near the camera. The two symmetric forecourts make that correction measurable.
local target = Vector3.new(-278, 10.04 + ref.Size.Y / 2, 37.5)
local desiredSpan = Vector3.new(556, 0, 0)
local span = check.Position - ref.Position
assert(math.abs(span.Magnitude - desiredSpan.Magnitude) < 1,
	"Interior import scale is wrong; choose Scale Unit: Stud")
local theta = math.atan2(-desiredSpan.Z, desiredSpan.X) - math.atan2(-span.Z, span.X)
local transform = CFrame.new(target) * CFrame.Angles(0, theta, 0) * CFrame.new(-ref.Position)
model:PivotTo(transform * model:GetPivot())
local errorStuds = math.max((ref.Position - target).Magnitude,
	(check.Position - (target + desiredSpan)).Magnitude)
assert(errorStuds < 0.1, string.format("Interior placement error %.3f studs", errorStuds))

local solid, visual = 0, 0
for _, part in model:GetDescendants() do
	if part:IsA("MeshPart") then
		part.Anchored = true
		part.Color = Color3.new(1, 1, 1) -- preserve the Blender per-face colors
		part.CastShadow = true
		local name = part.Name
		local kind = name:match("^[AB]_(.+)$")
		local fidelity: Enum.CollisionFidelity? = nil
		if name:find("_Forecourt") then
			-- Curved terraces need their actual outline; a box makes invisible
			-- rectangular corners hover above the surrounding courtyard.
			fidelity = Enum.CollisionFidelity.PreciseConvexDecomposition
		elseif kind == "Keep" or kind == "Barracks" or kind == "Blacksmith_Forge"
			or kind == "Fletcher" or kind == "Alchemist" or kind == "Carpenter" then
			fidelity = Enum.CollisionFidelity.PreciseConvexDecomposition
		end
		if fidelity then
			part.CollisionFidelity = fidelity
			part.CanCollide = true
			solid += 1
		else
			-- Roofs still receive raycasts, so rain turns off under shelter.
			part.CanCollide = false
			part.CanTouch = false
			visual += 1
		end
	end
end

model.Name = "CastleInteriors"
print(string.format("Castle interiors aligned within %.3f studs: %d solid, %d visual pieces",
	errorStuds, solid, visual))
