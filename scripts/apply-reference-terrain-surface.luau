--!strict
-- Ground-only Edit-time surface pass for DESIGN.md's approved Arcane Lineage references.
-- Pass decoded layout.json and assets/map/reference_terrain_surface.json to run().
-- Default: read-only preview. Applying requires apply=true and an explicit expectedPlaceId.
-- Reads existing voxels; changes soil materials, not occupancy, heights, or any model.
-- Castle pads, crater footprints, water, sand, and rock retain their voxel materials.
-- Both 18-stud ram routes come from layout.json; no copied coordinates or terrain clearing.

local SurfacePass = {}
local SOIL = {
	[Enum.Material.Grass] = true,
	[Enum.Material.LeafyGrass] = true,
	[Enum.Material.Ground] = true,
	[Enum.Material.Mud] = true,
}

local function protected(layout: any, x: number, z: number): string?
	for _, castle in layout.castles do
		local half = castle.pad.size / 2
		if math.abs(x - castle.center.x) <= half and math.abs(z - castle.center.z) <= half then
			return "castlePad"
		end
	end
	for _, crater in layout.craters do
		if (x - crater.x) ^ 2 + (z - crater.z) ^ 2 <= crater.outer_radius ^ 2 then
			return "crater"
		end
	end
	return nil
end

local function onRoad(layout: any, profile: any, x: number, z: number): boolean
	-- Mirror the small painted fringe; the traversable centerline retains its approved width.
	local ax, by = math.abs(x), -z
	local edge = profile.path_edge_wobble
		* (0.5 + 0.25 * math.sin(ax / 13 + by / 9) + 0.25 * math.sin(ax / 5.7 - by / 17))
	for _, route in layout.ram_routes do
		local points = route.centerline
		for index = 1, #points - 1 do
			local a, b = points[index], points[index + 1]
			local dx, dz = b.x - a.x, b.z - a.z
			local lengthSquared = dx * dx + dz * dz
			local along = if lengthSquared > 0
				then math.clamp(((x - a.x) * dx + (z - a.z) * dz) / lengthSquared, 0, 1)
				else 0
			local ox, oz = x - (a.x + along * dx), z - (a.z + along * dz)
			if ox * ox + oz * oz <= (route.width / 2 + edge) ^ 2 then
				return true
			end
		end
	end
	return false
end

function SurfacePass.run(layout: any, profile: any, options: any?): any
	options = options or {}
	assert(not game:GetService("RunService"):IsRunning(), "Run the surface pass in Edit mode")
	assert(layout.meta.version == profile.layout_version, "Surface profile does not match the layout")
	assert(profile.preserve_heights, "This pass requires the existing heights to be preserved")
	assert(profile.voxel_resolution == 4, "Roblox Terrain requires 4-stud voxel resolution")
	local fieldMaterial = (Enum.Material :: any)[profile.field_material]
	assert(fieldMaterial == Enum.Material.Grass or fieldMaterial == Enum.Material.LeafyGrass,
		"This reference profile requires a grass ground material")
	assert(workspace:FindFirstChild("Battlefield"), "The Medieval Land battlefield is not present")
	if options.apply then
		assert(typeof(options.expectedPlaceId) == "number", "Applying requires an explicit expectedPlaceId")
		assert(game.PlaceId == options.expectedPlaceId, "Wrong Studio place; no terrain was changed")
		assert(game.PlaceId ~= 0 or options.allowLocalCopy == true, "A local/recovered copy needs explicit authorization")
	end

	local terrain = workspace.Terrain
	local bounds, resolution = layout.map_bounds, profile.voxel_resolution
	local y0, y1 = profile.voxel_min_y, profile.voxel_max_y
	for _, value in { bounds.min_x, bounds.max_x, bounds.min_z, bounds.max_z, y0, y1 } do
		assert(value % resolution == 0, "Terrain pass bounds must be aligned to the voxel grid")
	end
	local report = {
		version = profile.version,
		placeId = game.PlaceId,
		applied = false,
		changedVoxels = 0,
		fieldColumns = 0,
		roadColumns = 0,
		protectedColumns = { castlePad = 0, crater = 0 },
		transitions = {},
		verifiedVoxels = 0,
		occupancyChanges = 0,
	}
	local chunks = {}
	local width = (bounds.max_x - bounds.min_x) / resolution
	for offset = 0, width - 1, 32 do
		local count = math.min(32, width - offset)
		local x0 = bounds.min_x + offset * resolution
		local region = Region3.new(Vector3.new(x0, y0, bounds.min_z), Vector3.new(x0 + count * resolution, y1, bounds.max_z))
		local before, occupancy = terrain:ReadVoxels(region, resolution)
		local size = before.Size
		local after = table.create(size.X)
		local changed = 0
		for i = 1, size.X do
			after[i] = table.create(size.Y)
			for j = 1, size.Y do
				after[i][j] = table.clone(before[i][j])
			end
			for k = 1, size.Z do
				local x = x0 + (i - 0.5) * resolution
				local z = bounds.min_z + (k - 0.5) * resolution
				local skip = protected(layout, x, z)
				if skip then
					report.protectedColumns[skip] += 1
					continue
				end
				local top = nil
				for j = size.Y, 1, -1 do
					if occupancy[i][j][k] > 0 then
						top = before[i][j][k]
						break
					end
				end
				if not top or not SOIL[top] then
					continue
				end
				local road = onRoad(layout, profile, x, z)
				local target = if road then Enum.Material.Ground else fieldMaterial
				if road then report.roadColumns += 1 else report.fieldColumns += 1 end
				for j = 1, size.Y do
					local old = before[i][j][k]
					if occupancy[i][j][k] > 0 and SOIL[old] and old ~= target then
						after[i][j][k] = target
						changed += 1
						local transition = old.Name .. "->" .. target.Name
						report.transitions[transition] = (report.transitions[transition] or 0) + 1
					end
				end
			end
		end
		report.changedVoxels += changed
		if changed > 0 then
			table.insert(chunks, { region = region, before = before, after = after, occupancy = occupancy, size = size })
		end
	end
	assert(report.fieldColumns > 10000, "Too little existing field terrain; inspect the map before applying")
	if not options.apply then
		return report
	end

	local colorsBefore = {}
	for name in profile.material_colors do
		local material = (Enum.Material :: any)[name]
		assert(material == Enum.Material.Grass or material == Enum.Material.LeafyGrass or material == Enum.Material.Ground,
			"This pass may recolor field and road materials only")
		colorsBefore[material] = terrain:GetMaterialColor(material)
	end
	local previousVersion = terrain:GetAttribute("ReferenceSurfaceVersion")
	local history = game:GetService("ChangeHistoryService")
	-- Studio's execute tool already records its command. Reuse that recording rather
	-- than attempting an unsupported nested one; direct command-bar runs start their own.
	local recording = nil
	if not history:IsRecordingInProgress() then
		recording = history:TryBeginRecording("ReferenceTerrainSurface", "Apply reference grass and terrain surfaces")
		assert(recording, "Could not start an undo recording; no terrain was changed")
	end
	report.undoRecording = if recording then "owned" else "existing Studio command"
	local written = {}
	local ok, failure = xpcall(function()
		for _, chunk in chunks do
			table.insert(written, chunk)
			terrain:WriteVoxels(chunk.region, resolution, chunk.after, chunk.occupancy)
			local readMaterials, readOccupancy = terrain:ReadVoxels(chunk.region, resolution)
			for i = 1, chunk.size.X do
				for j = 1, chunk.size.Y do
					for k = 1, chunk.size.Z do
						assert(readMaterials[i][j][k] == chunk.after[i][j][k], "Terrain material readback mismatch")
						assert(math.abs(readOccupancy[i][j][k] - chunk.occupancy[i][j][k]) < 0.000001,
							"Terrain occupancy changed; rolling back the surface pass")
							report.verifiedVoxels += 1
					end
				end
			end
		end
		for name, rgb in profile.material_colors do
			terrain:SetMaterialColor((Enum.Material :: any)[name], Color3.fromRGB(rgb[1], rgb[2], rgb[3]))
		end
		terrain:SetAttribute("ReferenceSurfaceVersion", profile.version)
	end, tostring)
	if not ok then
		for _, chunk in written do
			terrain:WriteVoxels(chunk.region, resolution, chunk.before, chunk.occupancy)
		end
		for material, color in colorsBefore do terrain:SetMaterialColor(material, color) end
		terrain:SetAttribute("ReferenceSurfaceVersion", previousVersion)
		if recording then history:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel) end
		error(failure)
	end
	if recording then history:FinishRecording(recording, Enum.FinishRecordingOperation.Commit) end
	report.applied = true
	return report
end

return SurfacePass
