--!strict
-- Run once in Studio's Edit datamodel after importing assets/map/battlefield_v2_2_props.fbx with
-- the 3D Importer (Scale Unit: Stud). Idempotent.
--
-- The v2.2 ground is voxel Terrain (scripts/build-terrain-v2-2.luau), so this file holds only what
-- stands on it: both castles' walls, towers, gates and banners, barricades, tunnel portals, cover
-- and shore rocks, pines, path stones and the sea.
--
-- 1. Orientation. Studio's importer turns these FBX files 180 degrees about Y and drops them near
--    the camera. The model is placed by A_Tower_FS's bounding-box centre (from the Blender build)
--    and checked against B_Tower_RN on the far side.
-- 2. Look (REALISM-TARGET.md, Phase 1 values): castle stone Cobblestone darkened by the Color
--    multiply on the vertex colours; barricades WoodPlanks; banners Fabric in team colours;
--    tunnel portals and rocks Rock; pines Grass texture; path stones Slate.
-- 3. Collision (AGENTS.md section 12): gate Precise (the arch is walked through), towers and tunnel
--    portals Hull, wall bays and barricades Box. Wide spread meshes (pine stands, rock sets, sea,
--    path stones) do not collide; the Terrain is the floor.
-- 4. The model is renamed Battlefield, so CastleService hides its grey placeholders.

local REF = { name = "A_Tower_FS", at = Vector3.new(-330.18, 42.312, 89.774) }
local CHECK = { name = "B_Tower_RN", at = Vector3.new(509.774, 42.312, -89.82) }
local TEAM_COLOUR = { A = Color3.fromRGB(184, 65, 58), B = Color3.fromRGB(58, 95, 184) }
local STONE = Color3.fromRGB(170, 170, 175)
local WOOD = Color3.fromRGB(170, 150, 130)
local ROCK = Color3.fromRGB(230, 215, 195)

local model: Model? = nil
for _, child in workspace:GetChildren() do
	if child:IsA("Model") and child:FindFirstChild(CHECK.name, true) and child:FindFirstChild(REF.name, true) then
		model = child
	end
end
assert(model, "import assets/map/battlefield_v2_2_props.fbx first")

-- 1. orientation
local ref = model:FindFirstChild(REF.name, true) :: BasePart
local check = model:FindFirstChild(CHECK.name, true) :: BasePart
if (ref.Position - REF.at).Magnitude > 0.01 then
	local want = CHECK.at - REF.at
	local have = check.Position - ref.Position
	local angle = math.atan2(-want.Z, want.X) - math.atan2(-have.Z, have.X)
	local T = CFrame.new(REF.at) * CFrame.Angles(0, angle, 0) * CFrame.new(-ref.Position)
	model:PivotTo(T * model:GetPivot())
end
local err = math.max((ref.Position - REF.at).Magnitude, (check.Position - CHECK.at).Magnitude)
assert(err < 0.05, string.format("placement off by %.3f studs", err))

-- 2 and 3. look and collision
local function style(name: string): (Enum.Material?, Color3?)
	local team = name:match("^([AB])_.*Banner")
	if team then
		return Enum.Material.Fabric, TEAM_COLOUR[team]
	elseif name:match("^[AB]_Wall_") or name:match("^[AB]_Tower_") or name:match("^[AB]_Gate$") then
		return Enum.Material.Cobblestone, STONE
	elseif name:match("^[AB]_Barricade_") then
		return Enum.Material.WoodPlanks, WOOD
	elseif name:match("^[AB]_Tunnel_") or name:match("^BF_Cover_") or name:match("^BF_Shore_") then
		return Enum.Material.Rock, ROCK
	elseif name:match("^BF_Pines_") then
		return Enum.Material.Grass, Color3.new(1, 1, 1)
	elseif name:match("^BF_Path_Stones_") then
		return Enum.Material.Slate, Color3.fromRGB(205, 200, 194)
	end
	return nil, nil
end
local function fidelity(name: string): Enum.CollisionFidelity?
	if name:match("_Gate$") then return Enum.CollisionFidelity.PreciseConvexDecomposition end
	if name:match("_Tower_") then return Enum.CollisionFidelity.Hull end
	if name:match("_Tunnel_Entrance$") then return Enum.CollisionFidelity.Hull end
	if name:match("_Wall_[FRNS]%d$") then return Enum.CollisionFidelity.Box end
	if name:match("_Barricade_") then return Enum.CollisionFidelity.Box end
	return nil
end
local counts = { collide = 0, off = 0 }
for _, d in model:GetDescendants() do
	if d:IsA("MeshPart") then
		d.Anchored = true
		local material, colour = style(d.Name)
		d.Material = material or Enum.Material.Plastic
		d.Color = colour or Color3.new(1, 1, 1)
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
			if d.Name:match("^BF_Path_Stones_") or d.Name:match("^BF_Sea") then
				d.CanQuery = false -- flat dressing: ground checks and shots should find the Terrain
			end
			counts.off += 1
		end
	end
end

-- 4. name
model.Name = "Battlefield"
print(string.format("Battlefield v2.2 set up: placement within %.3f studs, %d colliding pieces, %d visual-only",
	err, counts.collide, counts.off))
return string.format("placement %.3f studs, %d colliding, %d visual-only", err, counts.collide, counts.off)
