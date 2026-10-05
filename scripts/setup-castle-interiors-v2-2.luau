--!strict
-- Run once in Studio's Edit datamodel after 3D-importing assets/castle/castle_interiors_v2_2.fbx
-- (Scale Unit: Stud). The v2.2 version of scripts/setup-castle-interiors.luau: the same 40 named
-- interior pieces, with the castles at x = +-420 (layout.json v2.2).
--
-- Placement: the two blacksmith forecourts sit at known layout positions (A at x -437..-399,
-- z 28..47; B mirrored), which makes the importer's 180-degree turn and offset measurable.

local Workspace = game:GetService("Workspace")
local refName = "A_Blacksmith_Forecourt"
local checkName = "B_Blacksmith_Forecourt"
local model: Model? = nil
for _, child in Workspace:GetChildren() do
	if child:IsA("Model") and child:FindFirstChild(refName, true) and child:FindFirstChild(checkName, true)
		and child.Name ~= "CastleInteriors" then
		model = child
		break
	end
end
assert(model, "Import assets/castle/castle_interiors_v2_2.fbx with Studio's 3D Importer first")

local ref = model:FindFirstChild(refName, true) :: MeshPart
local check = model:FindFirstChild(checkName, true) :: MeshPart
assert(ref:IsA("MeshPart") and check:IsA("MeshPart"), "Forecourt reference meshes were not imported")

local target = Vector3.new(-418, 10.04 + ref.Size.Y / 2, 37.5)
local desiredSpan = Vector3.new(836, 0, 0)
local span = check.Position - ref.Position
assert(math.abs(span.Magnitude - desiredSpan.Magnitude) < 1,
	("Interior import span %.1f, expected 836: wrong file or Scale Unit"):format(span.Magnitude))
local theta = math.atan2(-desiredSpan.Z, desiredSpan.X) - math.atan2(-span.Z, span.X)
local transform = CFrame.new(target) * CFrame.Angles(0, theta, 0) * CFrame.new(-ref.Position)
model:PivotTo(transform * model:GetPivot())
local errorStuds = math.max((ref.Position - target).Magnitude, (check.Position - (target + desiredSpan)).Magnitude)
assert(errorStuds < 0.1, string.format("Interior placement error %.3f studs", errorStuds))

local solid, visual = 0, 0
for _, part in model:GetDescendants() do
	if part:IsA("MeshPart") then
		part.Anchored = true
		part.Color = Color3.new(1, 1, 1) -- preserve the Blender per-face colors
		part.CastShadow = true
		local kind = part.Name:match("^[AB]_(.+)$")
		local fidelity: Enum.CollisionFidelity? = nil
		if part.Name:find("_Forecourt") or kind == "Keep" or kind == "Barracks" or kind == "Blacksmith_Forge"
			or kind == "Fletcher" or kind == "Alchemist" or kind == "Carpenter" then
			fidelity = Enum.CollisionFidelity.PreciseConvexDecomposition
		end
		if fidelity then
			part.CollisionFidelity = fidelity
			part.CanCollide = true
			solid += 1
		else
			part.CanCollide = false -- roofs still receive raycasts, so rain turns off under shelter
			part.CanTouch = false
			visual += 1
		end
	end
end

model.Name = "CastleInteriors"
return string.format("Castle interiors v2.2 aligned within %.3f studs: %d solid, %d visual pieces", errorStuds, solid, visual)
