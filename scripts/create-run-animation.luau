--!strict
-- Run in Studio Edit mode to author an original R15 running KeyframeSequence.
-- The sequence is stored at ReplicatedStorage/Animations/SiegeRun for inspection
-- and publishing. RegisterKeyframeSequence yields a temporary Studio preview ID;
-- publish this authored sequence as an Animation for live game use.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local folder = ReplicatedStorage:FindFirstChild("Animations") or Instance.new("Folder")
folder.Name = "Animations"
folder.Parent = ReplicatedStorage

local previous = folder:FindFirstChild("SiegeRun")
if previous then previous:Destroy() end

local sequence = Instance.new("KeyframeSequence")
sequence.Name = "SiegeRun"
sequence.Loop = true
sequence.Priority = Enum.AnimationPriority.Movement

local function pose(name: string, cf: CFrame, parent: Instance)
	local p = Instance.new("Pose")
	p.Name = name
	p.CFrame = cf
	p.EasingStyle = Enum.PoseEasingStyle.CubicV2
	p.EasingDirection = Enum.PoseEasingDirection.InOut
	p.Parent = parent
	return p
end

-- Two grounded strides, with a forward torso pitch and opposing arm drive.
-- The extra high points soften the foot transition without exaggerating bounce.
local frames = {
	{0.00,  0.0,  0.0},
	{0.10,  0.7,  1.0},
	{0.20,  1.0,  0.0},
	{0.30,  0.7, -1.0},
	{0.40,  0.0,  0.0},
	{0.50, -0.7,  1.0},
	{0.60, -1.0,  0.0},
	{0.70, -0.7, -1.0},
	{0.80,  0.0,  0.0},
}
for _, sample in frames do
	local t, drive, lift = sample[1], sample[2], sample[3]
	local key = Instance.new("Keyframe")
	key.Name = string.format("Run_%02d", math.floor(t * 100 + 0.5))
	key.Time = t
	key.Parent = sequence
	local root = pose("HumanoidRootPart", CFrame.new(0, 0.035 * lift, 0), key)
	local lower = pose("LowerTorso", CFrame.Angles(math.rad(-4), 0, math.rad(2.3 * drive)), root)
	local upper = pose("UpperTorso", CFrame.Angles(math.rad(-10), math.rad(2.5 * drive), math.rad(-1.8 * drive)), lower)
	pose("Head", CFrame.Angles(math.rad(7), 0, math.rad(-1.5 * drive)), upper)

	local leftArm = pose("LeftUpperArm", CFrame.Angles(math.rad(22 + 34 * drive), 0, math.rad(-8)), upper)
	pose("LeftLowerArm", CFrame.Angles(math.rad(-48), 0, 0), leftArm)
	local rightArm = pose("RightUpperArm", CFrame.Angles(math.rad(22 - 34 * drive), 0, math.rad(8)), upper)
	pose("RightLowerArm", CFrame.Angles(math.rad(-48), 0, 0), rightArm)

	local leftLeg = pose("LeftUpperLeg", CFrame.Angles(math.rad(-39 * drive), 0, math.rad(-3)), lower)
	pose("LeftLowerLeg", CFrame.Angles(math.rad(14 + 23 * math.max(0, drive)), 0, 0), leftLeg)
	local rightLeg = pose("RightUpperLeg", CFrame.Angles(math.rad(39 * drive), 0, math.rad(3)), lower)
	pose("RightLowerLeg", CFrame.Angles(math.rad(14 + 23 * math.max(0, -drive)), 0, 0), rightLeg)
end

sequence.Parent = folder
local ok, previewId = pcall(function()
	return KeyframeSequenceProvider:RegisterKeyframeSequence(sequence)
end)
if ok then
	sequence:SetAttribute("StudioPreviewId", previewId)
	print("SiegeRun authored; temporary Studio preview ID:", previewId)
else
	warn("SiegeRun authored. Temporary preview registration unavailable:", previewId)
end
