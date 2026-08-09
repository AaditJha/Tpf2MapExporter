----------------------------------------------------------------------
-- Layer styling
----------------------------------------------------------------------
local roadColours = {
	-- Base-game street categories only (api.res.streetTypeRep .categories[1]):
	--   highway -> one-way country roads; country -> rural roads;
	--   urban   -> town roads;            one-way -> town/entrance one-ways.
	highway = { 214, 110, 60 },  -- orange
	country = { 232, 168, 80 },  -- yellow
	urban = { 150, 150, 150 },   -- grey
	["one-way"] = { 150, 150, 150 }, -- grey (town/entrance one-ways)
	default = { 150, 150, 150 },
}
-- Road stroke width is driven by each street type's real carriageway width
-- (streetWidth, in metres) so the line thickness reflects how wide the road is.
-- Colour conveys the road category; width conveys its size.
local ROAD_WIDTH_PX_PER_M = 0.5   -- px of stroke per metre of streetWidth
local ROAD_MIN_WIDTH = 2          -- never thinner than this (px)
local ROAD_MAX_WIDTH = 10         -- never thicker than this (px)
local ROAD_DEFAULT_WIDTH_M = 8    -- fallback metres when a type omits streetWidth
-- Stroke-width scaling. Stroke widths are authored as fixed pixels, but the
-- canvas grows with map size (fixed 4 m/px), so on big maps fixed strokes look
-- thinner when the SVG is fit to a window. This scales every stroke/dash by
-- canvasW / STROKE_SCALE_REFERENCE so the apparent thickness stays consistent.
-- Tuned to look right on the largest (Megalomaniac, ~6145 px) map -> scale 1.0
-- there; smaller maps scale down (clamped).
local STROKE_SCALE = true             -- scale stroke widths to canvas size
local STROKE_SCALE_REFERENCE = 6145   -- canvas px where widths are authored (scale = 1)
local STROKE_SCALE_MIN = 0.35         -- floor so small maps keep legible strokes
local STROKE_SCALE_MAX = 1.0          -- ceiling so widths never exceed authored size
-- Road casing: each road is drawn as a slightly wider outline stroke first, then
-- the coloured fill on top, so every road shares a consistent edge and the
-- network lifts off the terrain. Switch ROAD_CASING_THEME between "light" and
-- "dark" to flip the casing colour.
local ROAD_CASING = true                 -- draw casing under road fills
local ROAD_CASING_THEME = "dark"        -- "light" (white) or "dark" (near-black)
local ROAD_CASING_COLOURS = {
	light = { 245, 245, 245 },
	dark = { 40, 40, 40 },
}
local ROAD_CASING_PX = 1.5         -- extra width per side added under the fill (px)
-- Railway as a "cased" line: a wider black casing under a thin white core.
-- The two exposed black edges read as a pair of parallel rails, which stands
-- apart from the flat, warm-toned road strokes.
-- Railway in the OSM "crosstie" style: a solid light base line with dark grey
-- dashes laid on top, which reads as the classic alternating tie pattern. The
-- base stays solid so the line never looks broken; only the dashes sit on top.
-- (Dash phase resets per edge since each is its own path, so ties can be a
-- little uneven at junctions.)
local RAIL_BASE_COLOUR = { 235, 235, 235 }   -- solid light base line
local RAIL_DASH_COLOUR = { 80, 80, 80 }      -- dark grey ties (dashes)
local RAIL_WIDTH = 5                          -- track width (px); matches the widest roads
local RAIL_DASH = 5                           -- dash (tie) length (px)
local RAIL_GAP = 5                            -- gap between ties (px)

-- Bridges & tunnels. Each edge carries a BASE_EDGE.type: 0 = on ground,
-- 1 = bridge, 2 = tunnel. Bridges get a darker, heavier casing so they read as
-- raised structures; tunnels are drawn dashed (same colour) so the route reads
-- as passing underground.
local BRIDGE_TUNNEL = true                    -- distinguish bridge/tunnel segments
local BRIDGE_CASING_COLOUR = { 40, 40, 40 }   -- dark casing under bridge segments
local BRIDGE_CASING_PX = 2.5                  -- extra width per side for bridges (px)
local BRIDGE_TICKS = true                     -- draw perpendicular ticks at bridge ends
local BRIDGE_TICK_EXTRA = 2                   -- tick overhang beyond casing per side (px)
local BRIDGE_TICK_WIDTH = 1.5                 -- tick stroke width (px)
-- Tunnels are drawn as two thin parallel dashed lines ("====") in the network's
-- own colour, so the route reads as passing underground.
local TUNNEL_DASH = 6                          -- tunnel dash length (px)
local TUNNEL_GAP = 8                           -- tunnel gap length (px)
local TUNNEL_PARALLEL = true                   -- draw two parallel lines instead of one
local TUNNEL_LINE_WIDTH = 1.5                  -- each parallel line's width (px)

-- Legend (bottom band). The legend is laid out in a fixed-width "design"
-- coordinate space (base units) and then scaled to span the canvas width, so
-- it appears the same relative size on every map. It lists ONLY the network /
-- marker types actually drawn. The map keeps its own height; the band is
-- appended below it (the SVG height is patched once the band size is known).
local LEGEND_BASE_WIDTH = 1920   -- design width in base units (scaled to canvas width)
local LEGEND_PAD = 36            -- outer padding (base units)
local LEGEND_FONT = 26           -- entry label font size (base units)
local LEGEND_HEADER_FONT = 32    -- section header font size (base units)
local LEGEND_ROW_H = 56          -- height of each entry row (base units)
local LEGEND_SWATCH = 84         -- network swatch line length (base units)
local LEGEND_BADGE_SCALE = 1.6   -- enlargement for station / marker badges in the legend
local LEGEND_BG = "#ffffff"      -- band background fill

-- Coastline colour base. The sea-level (elevation 0) contour of the terrain is
-- drawn as a stroked line in this colour (see TERRAIN_COASTLINE below). The old
-- water-polygon layer has been removed in favour of this terrain coastline.
local WATER_FILL = { 44, 90, 160 }          -- coastline colour base

-- Coastline (terrain layer). Draw the sea-level (elevation 0) contour of the
-- terrain as a stroked line. Drawn from the terrain height grid via marching
-- squares, only when the terrain layer is enabled.
local TERRAIN_COASTLINE = true              -- draw the elevation-0 coastline on terrain
local COASTLINE_COLOUR = WATER_FILL         -- coastline stroke colour
local COASTLINE_WIDTH = 4                    -- coastline stroke width (px, stroke-scaled)


-- Semantic palette: every marker/badge derives its colour from these so the
-- map reads consistently. Goods (freight) is brown, passenger is blue, and
-- cities/towns get their own near-black so they stand apart from both.
local COLOUR_GOODS = { 150, 95, 40 }    -- brown: cargo stations, cargo stops (and goods things)
local COLOUR_PASSENGER = { 40, 110, 210 } -- blue: passenger stations & stops
local COLOUR_CITY = { 20, 20, 20 }      -- near-black: towns / cities
local COLOUR_DEPOT = { 70, 80, 95 }     -- slate: depots (shared passenger/cargo)
local BADGE_OUTLINE = { 255, 255, 255 } -- white outline + glyph on badges

local STATION_CARGO = COLOUR_GOODS      -- (alias) cargo station/stop colour
local STATION_PASS = COLOUR_PASSENGER   -- (alias) passenger station/stop colour
local STATION_RADIUS = 16               -- marker size in canvas px
-- Importance-based size tiers (badge base radius is 14 in <defs>):
--   road stops  -> smallest (there are many of them)
--   depots      -> a little bigger, but still small
--   rail/water/air stops -> medium
--   towns / industries   -> biggest
local ROAD_STOP_SCALE = 0.8             -- road stops (bus/truck): smallest
local DEPOT_ICON_SCALE = 1.0            -- depots: small
local STATION_ICON_SCALE = 1.35         -- rail / water / air stops: medium
local TOWN_ICON_SCALE = 1.75            -- towns: biggest
local INDUSTRY_ICON_SCALE = 1.5         -- industries: biggest
local TOWN_COLOUR = BADGE_OUTLINE       -- town badge outline + glyph
local TOWN_FILL = COLOUR_CITY           -- town badge fill
local ICON_BASE_RADIUS = 14             -- badge radius before scaling (matches <defs>)
local LABEL_COLOUR = { 0, 0, 0 }        -- black labels under town / industry icons

-- Vector glyph path data (Material Symbols, viewBox "0 -960 960 960").
-- Sourced from res/textures/ui/icons/*.svg and embedded so the export stays
-- a single self-contained SVG file.
local RAILWAY_GLYPH = '<path d="M160-340v-380q0-41 19-71.5t58.5-50q39.5-19.5 100-29T480-880q86 0 146.5 9t99 28.5Q764-823 782-793t18 73v380q0 59-40.5 99.5T660-200l60 60v20h-70l-80-80H390l-80 80h-70v-20l60-60q-59 0-99.5-40.5T160-340Zm320-480q-120 0-173 15.5T231-760h501q-18-27-76.5-43.5T480-820ZM220-545h234v-155H220v155Zm440 60H220h520-80Zm-146-60h226v-155H514v155ZM374-331q16-16 16-39t-16-39q-16-16-39-16t-39 16q-16 16-16 39t16 39q16 16 39 16t39-16Zm290 0q16-16 16-39t-16-39q-16-16-39-16t-39 16q-16 16-16 39t16 39q16 16 39 16t39-16Zm-364 76h360q34 0 57-25t23-60v-145H220v145q0 35 23 60t57 25Zm180-505h252-501 249Z"/>'
local GOODS_GLYPH = '<path d="M450-154v-309L180-619v309l270 156Zm60 0 270-156v-310L510-463v309Zm-60 69L150-258q-14-8-22-22t-8-30v-340q0-16 8-30t22-22l300-173q14-8 30-8t30 8l300 173q14 8 22 22t8 30v340q0 16-8 30t-22 22L510-85q-14 8-30 8t-30-8Zm194-525 102-59-266-154-102 59 266 154Zm-164 96 104-61-267-154-104 60 267 155Z"/>'
local BUS_GLYPH = '<path d="M249-120q-13 0-23-7.5T216-147v-84q-29-16-42.5-46T160-341v-397q0-74 76.5-108T481-880q166 0 242.5 34T800-738v397q0 34-13.5 64T744-231v84q0 12-10 19.5t-23 7.5h-19q-14 0-24-7.5T658-147v-55H302v55q0 12-10 19.5t-24 7.5h-19Zm232-644h259-520 261Zm177 293H220h520-82Zm-438-60h520v-173H220v173Zm145 203q16-16 16-39t-16-39q-16-16-39-16t-39 16q-16 16-16 39t16 39q16 16 39 16t39-16Zm308 0q16-16 16-39t-16-39q-16-16-39-16t-39 16q-16 16-16 39t16 39q16 16 39 16t39-16ZM220-764h520q-24-26-92-41t-167-15q-118 0-181 13.5T220-764Zm82 502h356q35 0 58.5-27t23.5-62v-120H220v120q0 35 23.5 62t58.5 27Z"/>'
local TRUCK_GLYPH = '<path d="M140.5-195.42Q106-229.83 106-279H40v-461q0-24 18-42t42-18h579v167h105l136 181v173h-71q0 49.17-34.38 83.58Q780.24-161 731.12-161t-83.62-34.42Q613-229.83 613-279H342q0 49-34.38 83.5t-83.5 34.5q-49.12 0-83.62-34.42ZM265-238q17-17 17-41t-17-41q-17-17-41-17t-41 17q-17 17-17 41t17 41q17 17 41 17t41-17ZM100-339h22q17-27 43.04-43t58-16q31.96 0 58.46 16.5T325-339h294v-401H100v401Zm672 101q17-17 17-41t-17-41q-17-17-41-17t-41 17q-17 17-17 41t17 41q17 17 41 17t41-17Zm-93-187h186L754-573h-75v148ZM360-529Z"/>'
local SHIP_GLYPH = '<path d="M178-80h-58v-60h58q40 0 79-11t76-34q35 22 72 32.5t75 10.5q38 0 75-10.5t72-32.5q38 23 77.5 34t78.5 11h57v60h-57q-39 0-78-9t-77-28q-38 19-75 28t-73 9q-36 0-73-9.5T333-117q-38 18-77.5 27.5T178-80Zm226.5-169.5Q365-270 330-307q-33 33-71 52.5T182-230l-71-245q-4-12 2-22.5t18-14.5l55-16v-190q0-25 17.5-42.5T246-778h132v-103h204v103h132q25 0 42.5 17.5T774-718v190l55 16q12 4 18 14.5t2 22.5l-71 245q-39-5-77-24.5T630-307q-35 37-74.5 57.5T480-229q-36 0-75.5-20.5ZM481-289q32 0 58.5-18t47.5-43l41-48 36 38q16 17 34 31t38 25l48-159-304-92-304 92 48 159q20-11 38-25t34-31l36-38 41 48q22 25 49 43t59 18ZM246-547l234-71 234 72v-172H246v171Zm234 125Z"/>'
local AIR_GLYPH = '<path d="M285-80v-83l124-86v-172L80-288v-102l329-231v-188q0-29 21-50t50-21q29 0 50 21t21 50v188l329 231v102L551-421v172l123 86v83l-194-59-195 59Z"/>'
-- Depot glyphs (shared passenger/cargo per mode).
local RAILWAY_DEPOT_GLYPH = '<path d="M80-80v-534q0-82 42.5-144T241-850q56-21 119-25.5t120-4.5q57 0 120.5 4.5T720-850q76 30 118 92t42 144v534H80Zm267-60h266l-81-81H428l-81 81Zm-62-288h390v-175H285v175Zm363 116q11-11 11-28t-11-28q-11-11-28-11t-28 11q-11 11-11 28t11 28q11 11 28 11t28-11Zm-280 0q11-11 11-28t-11-28q-11-11-28-11t-28 11q-11 11-11 28t11 28q11 11 28 11t28-11ZM140-140h159v-20l61-61q-38 0-79-29.5T240-340v-263q0-72 67-94.5T480-720q90 0 165 22.5t75 94.5v263q0 56-36.5 87.5T600-221l61 61v20h159v-474q0-66-31.5-109.5T695-793q-47-19-104-23t-111-4q-54 0-110.5 4T266-793q-62 26-94 69.5T140-614v474Zm0 0h680-680Z"/>'
local ROAD_DEPOT_GLYPH = '<path d="M305-218v-373h350v373-373H305v373Zm-145 60v-414H59l421-306 420 306H800v414H160Zm60-60h85v-373h350v373h85v-396L480-804 220-615.18V-218Zm124 0h271v-85H344v85Zm0-124h271v-85H344v85Zm0-124h271v-85H344v85Zm136-189q12 0 21-9t9-21.5q0-12.5-9-21t-21.5-8.5q-12.5 0-21 8.62-8.5 8.63-8.5 21.38 0 12 8.63 21 8.62 9 21.37 9Z"/>'
local SHIP_DEPOT_GLYPH = '<path d="M349.5-104Q285-128 234-167t-82.5-88Q120-304 120-355v-100l135 101-58 58q31 58 106 103.5T450-142v-388H320v-60h130v-74q-38-14-59-42t-21-64q0-46 32.5-78t77.5-32q46 0 78 32t32 78q0 36-21 64t-59 42v74h130v60H510v388q72-5 147-50.5T763-296l-58-58 135-101v100q0 51-31.5 100T726-167q-51 39-115.5 63T480-80q-66 0-130.5-24ZM480-720q21 0 35.5-15t14.5-35q0-21-14.5-35.5T480-820q-20 0-35 14.5T430-770q0 20 15 35t35 15Z"/>'
local TRAM_DEPOT_GLYPH = '<path d="M140-180h120v-320h440v320h120v-460L480-776 140-640v460Zm-60 60v-560l400-160 400 160v560H640v-320H320v320H80Zm290 0v-60h60v60h-60Zm80-120v-60h60v60h-60Zm80 120v-60h60v60h-60ZM260-500h440-440Z"/>'
-- Industry glyph (factory) used for every industry, regardless of type.
local INDUSTRY_GLYPH = '<path d="M80-80v-481l280-119v80l200-81v121h320v480H80Zm60-60h680v-359.8H500V-592l-200 80v-79l-160 71v380Zm310-100h60v-160h-60v160Zm-160 0h60v-160h-60v160Zm320 0h60v-160h-60v160Zm270-320H700l40-320h100l40 320ZM140-140h680-680Z"/>'

return {
    ROAD_COLOURS = roadColours,
    ROAD_WIDTH_PX_PER_M = ROAD_WIDTH_PX_PER_M,
    ROAD_MIN_WIDTH = ROAD_MIN_WIDTH,
    ROAD_MAX_WIDTH = ROAD_MAX_WIDTH,
    ROAD_DEFAULT_WIDTH_M = ROAD_DEFAULT_WIDTH_M,
    STROKE_SCALE = STROKE_SCALE,
    STROKE_SCALE_REFERENCE = STROKE_SCALE_REFERENCE,
    STROKE_SCALE_MIN = STROKE_SCALE_MIN,
    STROKE_SCALE_MAX = STROKE_SCALE_MAX,
    ROAD_CASING = ROAD_CASING,
    ROAD_CASING_THEME = ROAD_CASING_THEME,
    ROAD_CASING_COLOURS = ROAD_CASING_COLOURS,
    ROAD_CASING_PX = ROAD_CASING_PX,
    RAIL_BASE_COLOUR = RAIL_BASE_COLOUR,
    RAIL_DASH_COLOUR = RAIL_DASH_COLOUR,
    RAIL_WIDTH = RAIL_WIDTH,
    RAIL_DASH = RAIL_DASH,
    RAIL_GAP = RAIL_GAP,
    BRIDGE_TUNNEL = BRIDGE_TUNNEL,
    BRIDGE_CASING_COLOUR = BRIDGE_CASING_COLOUR,
    BRIDGE_CASING_PX = BRIDGE_CASING_PX,
    BRIDGE_TICKS = BRIDGE_TICKS,
    BRIDGE_TICK_EXTRA = BRIDGE_TICK_EXTRA,
    BRIDGE_TICK_WIDTH = BRIDGE_TICK_WIDTH,
    TUNNEL_DASH = TUNNEL_DASH,
    TUNNEL_GAP = TUNNEL_GAP,
    TUNNEL_PARALLEL = TUNNEL_PARALLEL,
    TUNNEL_LINE_WIDTH = TUNNEL_LINE_WIDTH,
    LEGEND_BASE_WIDTH = LEGEND_BASE_WIDTH,
    LEGEND_PAD = LEGEND_PAD,
    LEGEND_FONT = LEGEND_FONT,
    LEGEND_HEADER_FONT = LEGEND_HEADER_FONT,
    LEGEND_ROW_H = LEGEND_ROW_H,
    LEGEND_SWATCH = LEGEND_SWATCH,
    LEGEND_BADGE_SCALE = LEGEND_BADGE_SCALE,
    LEGEND_BG = LEGEND_BG,
    WATER_FILL = WATER_FILL,
    TERRAIN_COASTLINE = TERRAIN_COASTLINE,
    COASTLINE_COLOUR = COASTLINE_COLOUR,
    COASTLINE_WIDTH = COASTLINE_WIDTH,
    COLOUR_GOODS = COLOUR_GOODS,
    COLOUR_PASSENGER = COLOUR_PASSENGER,
    COLOUR_CITY = COLOUR_CITY,
    COLOUR_DEPOT = COLOUR_DEPOT,
    BADGE_OUTLINE = BADGE_OUTLINE,
    STATION_CARGO = STATION_CARGO,
    STATION_PASS = STATION_PASS,
    STATION_RADIUS = STATION_RADIUS,
    ROAD_STOP_SCALE = ROAD_STOP_SCALE,
    DEPOT_ICON_SCALE = DEPOT_ICON_SCALE,
    STATION_ICON_SCALE = STATION_ICON_SCALE,
    TOWN_ICON_SCALE = TOWN_ICON_SCALE,
    INDUSTRY_ICON_SCALE = INDUSTRY_ICON_SCALE,
    TOWN_COLOUR = TOWN_COLOUR,
    TOWN_FILL = TOWN_FILL,
    ICON_BASE_RADIUS = ICON_BASE_RADIUS,
    LABEL_COLOUR = LABEL_COLOUR,
    RAILWAY_GLYPH = RAILWAY_GLYPH,
    GOODS_GLYPH = GOODS_GLYPH,
    BUS_GLYPH = BUS_GLYPH,
    TRUCK_GLYPH = TRUCK_GLYPH,
    SHIP_GLYPH = SHIP_GLYPH,
    AIR_GLYPH = AIR_GLYPH,
    RAILWAY_DEPOT_GLYPH = RAILWAY_DEPOT_GLYPH,
    ROAD_DEPOT_GLYPH = ROAD_DEPOT_GLYPH,
    SHIP_DEPOT_GLYPH = SHIP_DEPOT_GLYPH,
    TRAM_DEPOT_GLYPH = TRAM_DEPOT_GLYPH,
    INDUSTRY_GLYPH = INDUSTRY_GLYPH,
}
