--!strict
-- Run once in Studio's command bar (or over MCP) after importing assets/map/battlefield.fbx
-- with the 3D Importer (Scale Unit: Stud). Idempotent: running it again changes nothing.
--
-- 1. Orientation. Studio's importer turns these FBX files 180 degrees about Y and drops
--    them near the camera (seen on every import, 2026-09-30 and 2026-10-01). The model
--    is rotated back and placed by a reference part whose layout position is known
--    (A_Tower_FS's bounding-box centre, from the Blender build), then checked against a
--    second reference on the other side of the map.
-- 2. Look. Every MeshPart is anchored and set to white so the per-face vertex colours
--    show unchanged; banners take their team colour (layout.json teams).
-- 3. Collision, by piece (AGENTS.md section 12). Ground pieces are cut small in Blender
--    so PreciseConvexDecomposition follows them (assets/map/build_battlefield.py,
--    terrain_cells). Meshes that span wide areas (pine stands, shore rocks, the cover
--    rock set, sea) would collide as one blob, so they do not collide for now.
-- 4. Crater cells get exact WedgePart collision (see the step below).
-- 5. The model is renamed Battlefield; CastleService then turns its grey placeholders
--    invisible and non-colliding (src/server/CastleService.server.luau).

local REF = { name = "A_Tower_FS", at = Vector3.new(-190.19, 36.152, 89.794) }
local CHECK = { name = "B_Tower_RN", at = Vector3.new(369.794, 36.152, -89.81) }
local TEAM_COLOUR = { A = Color3.fromRGB(184, 65, 58), B = Color3.fromRGB(58, 95, 184) }

local model: Model? = nil
for _, child in workspace:GetChildren() do
	if child:IsA("Model") and child:FindFirstChild(CHECK.name, true) and child:FindFirstChild(REF.name, true) then
		model = child
	end
end
assert(model, "import assets/map/battlefield.fbx first")

-- 1. orientation
local ref = model:FindFirstChild(REF.name, true) :: BasePart
local check = model:FindFirstChild(CHECK.name, true) :: BasePart
if (ref.Position - REF.at).Magnitude > 0.01 then
	-- rotate about Y by whatever turns the reference pair onto its layout direction
	local want = CHECK.at - REF.at
	local have = check.Position - ref.Position
	local angle = math.atan2(-want.Z, want.X) - math.atan2(-have.Z, have.X)
	local T = CFrame.new(REF.at) * CFrame.Angles(0, angle, 0) * CFrame.new(-ref.Position)
	model:PivotTo(T * model:GetPivot())
end
local err = math.max((ref.Position - REF.at).Magnitude, (check.Position - CHECK.at).Magnitude)
assert(err < 0.05, string.format("placement off by %.3f studs", err))

-- 2 and 3. look and collision
local function fidelity(name: string): Enum.CollisionFidelity?
	if name:match("^BF_Terrain_") then return Enum.CollisionFidelity.PreciseConvexDecomposition end
	if name:match("_Gate$") then return Enum.CollisionFidelity.PreciseConvexDecomposition end -- the arch is walked through
	if name:match("_Tower_") then return Enum.CollisionFidelity.Hull end
	if name:match("_Tunnel_Entrance$") then return Enum.CollisionFidelity.Hull end
	if name:match("_Wall_[FRNS]%d$") then return Enum.CollisionFidelity.Box end
	if name:match("_Barricade_") then return Enum.CollisionFidelity.Box end
	return nil -- everything else does not collide
end
local counts = { collide = 0, off = 0 }
for _, d in model:GetDescendants() do
	if d:IsA("MeshPart") then
		d.Anchored = true
		local team = d.Name:match("^([AB])_.*Banner")
		d.Color = if team then TEAM_COLOUR[team] else Color3.new(1, 1, 1)
		local f = fidelity(d.Name)
		if f then
			if d.CollisionFidelity ~= f then
				d.CollisionFidelity = f
			end
			d.CanCollide = true
			counts.collide += 1
		else
			d.CanCollide = false
			d.CanTouch = false
			counts.off += 1
		end
	end
end

-- 4. crater collision. Even a crater alone in its 50 x 60 cell is not reliable with
--    PreciseConvexDecomposition: in Studio (2026-10-01) the A/B_Crater_2 cells came out
--    exact while the A/B_Crater_1 cells put a lid 1.55 studs over the floor, unchanged by
--    regenerating. A crouched player must be able to get into the bowl, so each crater
--    cell gets exact collision from its own render triangles (two invisible WedgeParts
--    per triangle, a slab just under the surface) and the mesh itself stops colliding.
local AssetService = game:GetService("AssetService")
local SLAB = 1.0
local function wedge(parent: Instance, size: Vector3, cf: CFrame)
	local w = Instance.new("WedgePart")
	w.Anchored = true
	w.Size = size
	w.CFrame = cf
	w.Transparency = 1
	w.CanTouch = false
	w.CastShadow = false
	w.Parent = parent
end
local function triangle(parent: Instance, a: Vector3, b: Vector3, c: Vector3): number
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local normal = ac:Cross(ab)
	if normal.Magnitude < 1e-6 then
		return 0
	end
	local right = normal.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	local shift = (if right.Y > 0 then -right else right) * (SLAB / 2)
	wedge(parent, Vector3.new(SLAB, height, math.abs(ab:Dot(back))), CFrame.fromMatrix((a + b) / 2 + shift, right, up, back))
	wedge(parent, Vector3.new(SLAB, height, math.abs(ac:Dot(back))), CFrame.fromMatrix((a + c) / 2 + shift, -right, up, -back))
	return 2
end
local craterFolder = model:FindFirstChild("CraterCollision") or Instance.new("Folder")
craterFolder.Name = "CraterCollision"
craterFolder:ClearAllChildren()
craterFolder.Parent = model
local wedges = 0
for _, d in model:GetDescendants() do
	if d:IsA("MeshPart") and d.Name:match("^BF_Terrain_.*_Crater_%d$") then
		local em = AssetService:CreateEditableMeshAsync(Content.fromUri(d.MeshId))
		local scale = d.Size / d.MeshSize
		local cellFolder = Instance.new("Folder")
		cellFolder.Name = d.Name
		cellFolder.Parent = craterFolder
		for _, f in em:GetFaces() do
			local p = {}
			for i, v in em:GetFaceVertices(f) do
				p[i] = d.CFrame:PointToWorldSpace(em:GetPosition(v) * scale)
			end
			wedges += triangle(cellFolder, p[1], p[2], p[3])
		end
		em:Destroy()
		d.CanCollide = false
		d.CanTouch = false
		d.CanQuery = false -- its decomposition lid would still catch ray casts (shots, ground checks)
	end
end

-- 5. name
model.Name = "Battlefield"
print(string.format("Battlefield set up: placement within %.3f studs, %d colliding pieces, %d visual-only, %d crater collision wedges",
	err, counts.collide, counts.off, wedges))
