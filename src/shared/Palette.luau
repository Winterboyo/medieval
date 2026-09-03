--!strict
-- Medieval Land - one palette, shared by everything that draws.
--
-- Before this there were two. The negotiation panel deliberately lifted the
-- world's colours out of build-world.luau, while the notice toast and the 48
-- node readouts predated that and used an unrelated near-black scheme. Two
-- surfaces built at different times looking like they came from different games
-- is most of what "unpolished" means, and it is the cheapest thing to fix.
--
-- The world is the authority: these are the colours the buildings are actually
-- made of, so UI drawn in them sits in the same world rather than on top of it.

local Palette = {}

-- ---------------------------------------------------------------- surfaces
Palette.DAUB = Color3.fromRGB(226, 218, 200) -- primary text, plaster walls
Palette.DAUB_DIM = Color3.fromRGB(168, 158, 140) -- secondary text
Palette.TIMBER = Color3.fromRGB(74, 52, 34) -- beams, headers
Palette.TIMBER_LIGHT = Color3.fromRGB(96, 66, 42) -- raised faces, strokes
Palette.BOARD = Color3.fromRGB(40, 35, 30) -- panel grounds
Palette.SLATE = Color3.fromRGB(84, 78, 76) -- rules, disabled faces
Palette.MOSS = Color3.fromRGB(84, 100, 72) -- affirmative
Palette.TILED = Color3.fromRGB(112, 62, 48) -- negative, danger
Palette.SHORT_TEXT = Color3.fromRGB(196, 132, 112) -- "you cannot afford this"
Palette.DISABLED_TEXT = Color3.fromRGB(126, 118, 108)
Palette.ALARM = Color3.fromRGB(198, 84, 62) -- outside the zone, keep falling

-- ---------------------------------------------------------------- goods
-- Identity colours, so a resource reads the same everywhere it appears.
--
-- Deliberately NOT the tints in ResourceService's node readouts: those colour a
-- bar by REGEN RATE, not by which resource it is, which is why Wood and Stone
-- are near-identical greens there. Two different jobs, two different scales.
Palette.GOODS = {
	Wood = Color3.fromRGB(138, 100, 62),
	Grain = Color3.fromRGB(214, 176, 84),
	Wool = Color3.fromRGB(226, 220, 208),
	Stone = Color3.fromRGB(146, 142, 134),
	Ore = Color3.fromRGB(178, 116, 72),
	Timber = Color3.fromRGB(176, 138, 88),
	Ingot = Color3.fromRGB(178, 186, 196),
	Tonic = Color3.fromRGB(126, 200, 148),
}

-- Raw first, then the three that can only be made. The HUD draws a gap between
-- the groups so the distinction is visible without a label.
Palette.RAW_ORDER = { "Wood", "Grain", "Wool", "Stone", "Ore" }
Palette.CRAFTED_ORDER = { "Timber", "Ingot", "Tonic" }

-- ---------------------------------------------------------------- type
-- One serif, used only for headings, against Gotham for everything else. The
-- negotiation panel set this and it is worth keeping to.
Palette.FONT_HEADING = Enum.Font.Merriweather
Palette.FONT_STRONG = Enum.Font.GothamBold
Palette.FONT_LABEL = Enum.Font.GothamMedium
Palette.FONT_BODY = Enum.Font.Gotham

-- Corner radii in use across the project: panels 8, chips and readouts 6,
-- buttons 5. Named so a new surface does not invent a fourth.
Palette.CORNER_PANEL = 8
Palette.CORNER_CHIP = 6
Palette.CORNER_BUTTON = 5

return Palette
