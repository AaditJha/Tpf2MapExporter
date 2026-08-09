local util = require("vector_map_export_util")

local styles = require("vector_map_export_styles")

----------------------------------------------------------------------
-- Configuration
----------------------------------------------------------------------
local CANVAS_MAX = 14000                                  -- safety cap on either canvas axis (px)
-- Custom output folder. Leave empty to export into the mod's own "map_exports"
-- folder. To export elsewhere, put your own absolute path here (make sure it
-- already exists) e.g. "C:/Users/you/Documents/TPF2Export".
local CUSTOM_OUTPUT_FOLDER = ""
-- Resolved output folder: the custom path if set, otherwise the mod's own
-- "map_exports" folder (derived from this script's path via debug.getinfo).
local OUTPUT_FOLDER = (function()
	if CUSTOM_OUTPUT_FOLDER ~= "" then return CUSTOM_OUTPUT_FOLDER end
	local info = debug.getinfo(1, "S")
	local src = (info and info.source or ""):gsub("^@", ""):gsub("\\", "/")
	local r = src:find("/res/")
	return src:sub(1, r - 1) .. "/map_exports"   -- "<mod>/map_exports"
end)()
local TERRAIN_RASTER_SIZE = 1024                          -- terrain raster resolution (NxN pixels embedded as one image)
local TERRAIN_CONTOUR_LINES = true                        -- overlay thin contour lines on the relief
local CONTOUR_GRID = 256                                  -- sampling grid used only for contour lines
local CONTOUR_LEVELS = 15                                 -- number of elevation contour lines
local TERRAIN_Z_FACTOR = 2.2                              -- vertical exaggeration for hillshading
local YIELD_EVERY = 1500                                  -- operations between coroutine yields

local function trace(...) print("[VectorMapExporter]", ...) end



----------------------------------------------------------------------
-- GUI / export state
----------------------------------------------------------------------
local guiState = {
	layers = {
		terrain = true,
		roads = true,
		rail = true,
		stations = true,
		depots = true,
		towns = true,
		industries = true,
	},
	exporting = false,
	co = nil,
	progressText = nil,
	statusText = nil,
	exportButton = nil,
	init = false,
}

----------------------------------------------------------------------
-- Reusable scratch objects
----------------------------------------------------------------------
local scratchV2
local function heightAt(x, y)
	if not scratchV2 then scratchV2 = api.type.Vec2f.new(0, 0) end
	scratchV2.x = x
	scratchV2.y = y
	return api.engine.terrain.getBaseHeightAt(scratchV2)
end

-- Detect the water surface height from the engine's WATER_MESH components.
-- Each mesh contour is the polygon outline where water meets land (the
-- shoreline), so terrain height sampled at a contour vertex equals the water
-- surface height there. We take the median across all shoreline vertices to
-- shrug off the few that read slightly high. Returns 0 (sea level) if no water
-- mesh is present.
local function computeWaterLevel()
	local heights = {}
	local ok = pcall(function()
		api.engine.forEachEntityWithComponent(function(e)
			local m = api.engine.getComponent(e, api.type.ComponentType.WATER_MESH)
			if not m or not m.contours then return end
			for ci = 1, #m.contours do
				local verts = m.contours[ci].vertices
				for vi = 1, #verts do
					local p = verts[vi]
					heights[#heights + 1] = heightAt(p.x, p.y)
				end
			end
		end, api.type.ComponentType.WATER_MESH)
	end)
	if not ok or #heights == 0 then return 0 end
	table.sort(heights)
	return heights[math.floor(#heights / 2) + 1]
end

----------------------------------------------------------------------
-- Street style lookup.
-- Returns the street's category (categories[1], used for colour) and its
-- carriageway width in metres (streetWidth, used for stroke width). Both come
-- from the street type config resolved via streetTypeRep.
----------------------------------------------------------------------
local function streetStyle(edgeId)
	local se = api.engine.getComponent(edgeId, api.type.ComponentType.BASE_EDGE_STREET)
	if not se then return nil end
	local ok, edgeType = pcall(function() return api.res.streetTypeRep.get(se.streetType) end)
	if not ok or not edgeType then return nil end
	local cat = edgeType.categories and edgeType.categories[1] or nil
	local widthM = edgeType.streetWidth
	return cat, widthM
end

----------------------------------------------------------------------
-- File handle wrapper with buffered writes
----------------------------------------------------------------------
local function openOutput()
	local stamp = "unknown"
	pcall(function() stamp = os.date("%Y%m%d_%H%M%S") end)
	local path = OUTPUT_FOLDER .. "/map_export_" .. stamp .. ".svg"

	local f, err = io.open(path, "wb")
	if not f then
		return nil, nil, ("Could not open file for writing: " .. tostring(err) ..
			"\nPath: " .. path .. "\nMake sure the output folder exists.")
	end
	return f, path, nil
end

----------------------------------------------------------------------
-- Terrain layer: OSM / OpenTopoMap style hypsometric shaded relief.
-- The relief is rendered to a single raster (BMP) embedded as a base64
-- data URI, so the SVG contains ONE <image> node instead of tens of
-- thousands of <rect>s. Thin contour lines are optionally overlaid as
-- lightweight vectors on top, sampled from a separate coarse grid.
----------------------------------------------------------------------
local function emitTerrain(f, t, bx, by, yield)
	local N = TERRAIN_RASTER_SIZE
	trace("terrain: sampling " .. N .. "x" .. N .. " height grid for raster")
	local stepX = (2 * bx) / N
	local stepY = (2 * by) / N

	-- sample height field ((N+1) x (N+1)); index i -> world x, j -> world y
	local h = {}
	local minH, maxH = math.huge, -math.huge
	local ops = 0
	for i = 0, N do
		h[i] = {}
		local wx = -bx + i * stepX
		for j = 0, N do
			local wy = -by + j * stepY
			local z = heightAt(wx, wy)
			h[i][j] = z
			if z < minH then minH = z end
			if z > maxH then maxH = z end
			ops = ops + 1
		end
	end

	if maxH <= minH then return end
	trace("terrain: sampled, minH=" .. util.num(minH) .. " maxH=" .. util.num(maxH))

	-- Water surface height detected from the engine's WATER_MESH shoreline.
	-- Used as the land/water threshold so the below-water tint and the bottom
	-- of the land colour ramp follow the actual water level, not a hardcoded 0.
	local waterLevel = computeWaterLevel()
	trace("terrain: water level = " .. util.num(waterLevel))

	-- The water level is the bottom of the land ramp so coastal terrain reads
	-- green; fall back to the data minimum if the whole map is below it.
	local landMin = math.max(waterLevel, minH)
	if maxH <= landMin then landMin = minH end
	local landSpan = maxH - landMin
	if landSpan <= 0 then landSpan = 1 end

	-- Pixel colour callback. Pixel (px, py) with py=0 at the TOP maps to the
	-- cell whose corners are the four surrounding height samples. Top row =
	-- highest world y, so cj = (N-1) - py.
	local hypso = util.hypsoColor
	local hillshade = util.hillshade
	local zf = TERRAIN_Z_FACTOR
	local invX = 1 / (2 * stepX)
	local invY = 1 / (2 * stepY)
	local function getPixel(px, py)
		local ci = px
		local cj = (N - 1) - py
		local hBL = h[ci][cj]
		local hBR = h[ci + 1][cj]
		local hTR = h[ci + 1][cj + 1]
		local hTL = h[ci][cj + 1]
		local avg = (hBL + hBR + hTR + hTL) * 0.25
		if avg < waterLevel then
			-- below water: flat fill, no hillshade so the seabed relief is hidden
			return 150, 180, 175
		end
		local base = hypso((avg - landMin) / landSpan)
		local dzdx = ((hBR + hTR) - (hBL + hTL)) * invX
		local dzdy = ((hTL + hTR) - (hBL + hBR)) * invY
		local shade = hillshade(dzdx, dzdy, zf)
		return base[1] * shade, base[2] * shade, base[3] * shade
	end

	trace("terrain: encoding BMP")
	local bmp = util.encodeBMP(N, N, getPixel)
	trace("terrain: base64 encoding (" .. math.floor(#bmp / 1024) .. " KB raw)")
	local b64 = util.base64(bmp)
	bmp = nil

	-- place the image over the map's world extent within the canvas
	local left = t.x(-bx)
	local right = t.x(bx)
	local top = t.y(by)
	local bottom = t.y(-by)
	f:write('<g inkscape:label="relief" id="relief">\n')
	f:write('<image x="' .. util.num(left) .. '" y="' .. util.num(top) ..
		'" width="' .. util.num(right - left) .. '" height="' .. util.num(bottom - top) ..
		'" preserveAspectRatio="none" image-rendering="optimizeQuality" ' ..
		'xlink:href="data:image/bmp;base64,' .. b64 .. '"/>\n')
	f:write('</g>\n')
	b64 = nil
	trace("terrain: relief image embedded (" .. N .. "x" .. N .. ")")

	-- ---- coastline: the water-level contour, stroked in the water colour.
	-- Built with marching squares over the same fine height grid used for the
	-- relief raster and at the SAME threshold (waterLevel), so the coastline
	-- traces the exact boundary of the rasterised water fill. ----
	if styles.TERRAIN_COASTLINE then
		local function interpC(x1, y1, h1, x2, y2, h2, L)
			local d = h2 - h1
			local tt = d == 0 and 0.5 or (L - h1) / d
			return x1 + tt * (x2 - x1), y1 + tt * (y2 - y1)
		end
		local L = waterLevel
		f:write('<g inkscape:groupmode="layer" inkscape:label="coastline" id="coastline" ' ..
			'fill="none" stroke="' .. util.rgb(styles.COASTLINE_COLOUR) .. '" stroke-width="' ..
			util.num(t.sw(styles.COASTLINE_WIDTH)) .. '" stroke-linecap="round" stroke-linejoin="round">\n')
		f:write('<path d="')
		for i = 0, N - 1 do
			local x0 = -bx + i * stepX
			local x1w = x0 + stepX
			for j = 0, N - 1 do
				local y0 = -by + j * stepY
				local y1w = y0 + stepY
				local hBL = h[i][j]
				local hBR = h[i + 1][j]
				local hTR = h[i + 1][j + 1]
				local hTL = h[i][j + 1]
				local idx = 0
				if hBL >= L then idx = idx + 1 end
				if hBR >= L then idx = idx + 2 end
				if hTR >= L then idx = idx + 4 end
				if hTL >= L then idx = idx + 8 end
				if idx ~= 0 and idx ~= 15 then
					local function eB() return interpC(x0, y0, hBL, x1w, y0, hBR, L) end
					local function eR() return interpC(x1w, y0, hBR, x1w, y1w, hTR, L) end
					local function eT() return interpC(x1w, y1w, hTR, x0, y1w, hTL, L) end
					local function eL() return interpC(x0, y1w, hTL, x0, y0, hBL, L) end
					local segs
					if idx == 1 or idx == 14 then segs = { eL, eB }
					elseif idx == 2 or idx == 13 then segs = { eB, eR }
					elseif idx == 3 or idx == 12 then segs = { eL, eR }
					elseif idx == 4 or idx == 11 then segs = { eR, eT }
					elseif idx == 6 or idx == 9 then segs = { eB, eT }
					elseif idx == 7 or idx == 8 then segs = { eL, eT }
					elseif idx == 5 then segs = { eL, eB, eR, eT } -- saddle
					elseif idx == 10 then segs = { eB, eR, eT, eL } -- saddle
					end
					if segs then
						local k = 1
						while k < #segs do
							local ax, ay = segs[k]()
							local bxp, byp = segs[k + 1]()
							f:write("M" .. util.num(t.x(ax)) .. "," .. util.num(t.y(ay)) ..
								"L" .. util.num(t.x(bxp)) .. "," .. util.num(t.y(byp)))
							k = k + 2
						end
					end
				end
			end
		end
		f:write('"/>\n')
		f:write('</g>\n')
		trace("terrain: coastline drawn")
	end

	-- ---- optional contour line overlay (separate coarse grid) ----
	if not TERRAIN_CONTOUR_LINES then
		trace("terrain: done (relief only)")
		return
	end

	local cn = CONTOUR_GRID
	local csx = (2 * bx) / cn
	local csy = (2 * by) / cn
	local ch = {}
	for i = 0, cn do
		ch[i] = {}
		local wx = -bx + i * csx
		for j = 0, cn do
			ch[i][j] = heightAt(wx, -by + j * csy)
		end
	end

	local interval = (maxH - minH) / (CONTOUR_LEVELS + 1)
	if interval <= 0 then
		trace("terrain: done (no contour interval)")
		return
	end

	local function interp(x1, y1, h1, x2, y2, h2, L)
		local d = h2 - h1
		local tt = d == 0 and 0.5 or (L - h1) / d
		return x1 + tt * (x2 - x1), y1 + tt * (y2 - y1)
	end

	f:write('<g inkscape:label="contours" id="contours" fill="none" stroke="#6b5630" stroke-opacity="0.45" stroke-width="1.2">\n')
	for level = 1, CONTOUR_LEVELS do
		local L = minH + level * interval
		-- skip levels at or below the water surface; we don't draw seabed contours
		if L >= waterLevel then
		f:write('<path d="')
		for i = 0, cn - 1 do
			local x0 = -bx + i * csx
			local x1w = x0 + csx
			for j = 0, cn - 1 do
				local y0 = -by + j * csy
				local y1w = y0 + csy
				local hBL = ch[i][j]
				local hBR = ch[i + 1][j]
				local hTR = ch[i + 1][j + 1]
				local hTL = ch[i][j + 1]
				local idx = 0
				if hBL >= L then idx = idx + 1 end
				if hBR >= L then idx = idx + 2 end
				if hTR >= L then idx = idx + 4 end
				if hTL >= L then idx = idx + 8 end
				if idx ~= 0 and idx ~= 15 then
					local function eB() return interp(x0, y0, hBL, x1w, y0, hBR, L) end
					local function eR() return interp(x1w, y0, hBR, x1w, y1w, hTR, L) end
					local function eT() return interp(x1w, y1w, hTR, x0, y1w, hTL, L) end
					local function eL() return interp(x0, y1w, hTL, x0, y0, hBL, L) end
					local segs = {}
					if idx == 1 or idx == 14 then segs = { eL, eB }
					elseif idx == 2 or idx == 13 then segs = { eB, eR }
					elseif idx == 3 or idx == 12 then segs = { eL, eR }
					elseif idx == 4 or idx == 11 then segs = { eR, eT }
					elseif idx == 6 or idx == 9 then segs = { eB, eT }
					elseif idx == 7 or idx == 8 then segs = { eL, eT }
					elseif idx == 5 then segs = { eL, eB, eR, eT } -- saddle
					elseif idx == 10 then segs = { eB, eR, eT, eL } -- saddle
					end
					local k = 1
					while k < #segs do
						local ax, ay = segs[k]()
						local bxp, byp = segs[k + 1]()
						f:write("M" .. util.num(t.x(ax)) .. "," .. util.num(t.y(ay)) ..
							"L" .. util.num(t.x(bxp)) .. "," .. util.num(t.y(byp)))
						k = k + 2
					end
				end
			end
		end
		f:write('"/>\n')
		end
	end
	f:write('</g>\n')
	trace("terrain: done (relief image + " .. CONTOUR_LEVELS .. " contour levels)")
end

----------------------------------------------------------------------
-- Network layers (roads / rail) as bezier paths
----------------------------------------------------------------------
local function emitNetworks(f, t, doRoads, doRail, yield, legend)
	trace("networks: start (roads=" .. tostring(doRoads) .. " rail=" .. tostring(doRail) .. ")")
	-- Stroke-width scale (1.0 on the largest map; smaller maps scale down) so
	-- fixed-pixel strokes keep a consistent apparent thickness across map sizes.
	local ws = t.widthScale or 1
	-- collect edges grouped by style key
	local roadGroups = {} -- category -> { path strings }
	local railPaths = {}
	local hasBridge, hasTunnel = false, false
	local ops = 0

	-- node position cache (BASE_NODE.position is the authoritative world pos).
	-- NOTE: nc.position is sol2 userdata aliasing engine memory; it must be copied
	-- into a plain Lua table immediately, or later getComponent calls reuse the
	-- buffer and the cached reference yields garbage coords (causes stray streaks).
	local nodePos = {}
	local function getNodePos(node)
		local p = nodePos[node]
		if p == nil then
			local nc = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE)
			p = (nc and nc.position) and { x = nc.position.x, y = nc.position.y, z = nc.position.z } or false
			nodePos[node] = p
		end
		return p or nil
	end

	api.engine.forEachEntityWithComponent(function(entity)
		-- Read the BASE_EDGE component directly. Its tangent0/tangent1 are the
		-- full-length Hermite tangents (game.interface.getEntity returns these
		-- normalized, which flattens curves into straight chords).
		local edge = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE)
		if not edge then return end
		local n0 = getNodePos(edge.node0)
		local n1 = getNodePos(edge.node1)
		if not n0 or not n1 then return end
		local p0 = { x = n0.x, y = n0.y }
		local p1 = { x = n1.x, y = n1.y }
		local dx = p1.x - p0.x
		local dy = p1.y - p0.y
		if (dx * dx + dy * dy) < 1 then return end -- skip near-zero edges (<1m)
		local m0, m1
		if edge.tangent0 and edge.tangent1 then
			m0 = { x = edge.tangent0.x, y = edge.tangent0.y }
			m1 = { x = edge.tangent1.x, y = edge.tangent1.y }
		else
			m0 = { x = dx, y = dy }
			m1 = { x = dx, y = dy }
		end
		local d = util.edgeToBezier(t, p0, m0, p1, m1)

		-- Bridge/tunnel classification from BASE_EDGE.type (0=ground,1=bridge,2=tunnel).
		local kind = 0
		if styles.BRIDGE_TUNNEL and edge.type then kind = edge.type end
		-- Bridge/tunnel segments keep their geometry so the emit pass can build
		-- offset curves (tunnel "====") and end ticks (bridges).
		local geo = (kind ~= 0) and { p0 = p0, m0 = m0, p1 = p1, m1 = m1 } or nil

		-- An edge is a track if it carries a BASE_EDGE_TRACK component.
		local isTrack = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE_TRACK) ~= nil
		if isTrack then
			if doRail then
				table.insert(railPaths, { d = d, kind = kind, geo = geo })
				if kind == 1 then hasBridge = true elseif kind == 2 then hasTunnel = true end
			end
		elseif doRoads then
			local cat, widthM = streetStyle(entity)
			cat = cat or "default"
			-- Map the real carriageway width (metres) to a stroke width (px),
			-- clamped so very narrow/wide roads stay legible.
			local wpx = (widthM or styles.ROAD_DEFAULT_WIDTH_M) * styles.ROAD_WIDTH_PX_PER_M
			if wpx < styles.ROAD_MIN_WIDTH then wpx = styles.ROAD_MIN_WIDTH end
			if wpx > styles.ROAD_MAX_WIDTH then wpx = styles.ROAD_MAX_WIDTH end
			if not roadGroups[cat] then roadGroups[cat] = {} end
			table.insert(roadGroups[cat], { d = d, w = wpx, kind = kind, geo = geo })
			if kind == 1 then hasBridge = true elseif kind == 2 then hasTunnel = true end
		end
		ops = ops + 1
		if ops % YIELD_EVERY == 0 then yield("networks") end
	end, api.type.ComponentType.BASE_EDGE)
	trace("networks: gathered " .. ops .. " edges, " .. #railPaths .. " rail paths")

	-- Record what was actually drawn so the legend lists only those types.
	if legend then
		legend.roadCats = legend.roadCats or {}
		if doRoads then for cat in pairs(roadGroups) do legend.roadCats[cat] = true end end
		if doRail and #railPaths > 0 then legend.hasRail = true end
		if hasBridge then legend.hasBridge = true end
		if hasTunnel then legend.hasTunnel = true end
	end

	if doRoads then
		f:write('<g inkscape:groupmode="layer" inkscape:label="roads" id="roads" fill="none" stroke-linecap="round" stroke-linejoin="round">\n')
		-- Casing pass: draw every road as a wider outline first so junctions and
		-- overlaps stay clean, then the coloured fills go on top.
		if styles.ROAD_CASING then
			local caseCol = styles.ROAD_CASING_COLOURS[styles.ROAD_CASING_THEME] or styles.ROAD_CASING_COLOURS.light
			f:write('<g inkscape:label="roads_casing" stroke="' .. util.rgb(caseCol) .. '">\n')
			for cat, paths in pairs(roadGroups) do
				for _i, seg in ipairs(paths) do
					-- Only ground roads get the solid casing. Bridges get their own
					-- heavier casing below; tunnels are drawn as two dashed outline
					-- lines (further down) so they read as passing underground.
					if seg.kind == 0 then
						f:write('<path stroke-width="' .. util.num((seg.w + 2 * styles.ROAD_CASING_PX) * ws) ..
							'" d="' .. seg.d .. '"/>')
					end
				end
			end
			f:write('\n</g>\n')
			yield("roads:casing")
		end
		-- Tunnels: two parallel dashed lines in the casing/outline colour, placed at
		-- the road's outline edges, so the route reads as passing underground.
		if styles.BRIDGE_TUNNEL then
			local caseCol = styles.ROAD_CASING_COLOURS[styles.ROAD_CASING_THEME] or styles.ROAD_CASING_COLOURS.light
			f:write('<g inkscape:label="roads_tunnel" stroke="' .. util.rgb(caseCol) ..
				'" stroke-width="' .. util.num(styles.TUNNEL_LINE_WIDTH * ws) .. '" stroke-linecap="butt" ' ..
				'stroke-dasharray="' .. util.num(styles.TUNNEL_DASH * ws) .. ',' .. util.num(styles.TUNNEL_GAP * ws) .. '">\n')
			for cat, paths in pairs(roadGroups) do
				for _i, seg in ipairs(paths) do
					if seg.kind == 2 then
						if seg.geo then
							-- align each dash's outer edge with the road outline edge
							local off = (seg.w / 2 + styles.ROAD_CASING_PX - styles.TUNNEL_LINE_WIDTH / 2) * ws
							local g = seg.geo
							f:write('<path d="' .. util.edgeToBezierOffset(t, g.p0, g.m0, g.p1, g.m1, off) .. '"/>')
							f:write('<path d="' .. util.edgeToBezierOffset(t, g.p0, g.m0, g.p1, g.m1, -off) .. '"/>')
						else
							f:write('<path stroke-width="' .. util.num(seg.w * ws) .. '" d="' .. seg.d .. '"/>')
						end
					end
				end
			end
			f:write('\n</g>\n')
		end
		-- Bridge casing: a darker, heavier outline so bridge spans read as raised.
		if styles.BRIDGE_TUNNEL then
			f:write('<g inkscape:label="roads_casing_bridge" stroke="' ..
				util.rgb(styles.BRIDGE_CASING_COLOUR) .. '">\n')
			for cat, paths in pairs(roadGroups) do
				for _i, seg in ipairs(paths) do
					if seg.kind == 1 then
						f:write('<path stroke-width="' .. util.num((seg.w + 2 * styles.BRIDGE_CASING_PX) * ws) ..
							'" d="' .. seg.d .. '"/>')
					end
				end
			end
			f:write('\n</g>\n')
			-- Bridge end ticks: short perpendicular abutment marks at each span end.
			if styles.BRIDGE_TICKS then
				f:write('<g inkscape:label="roads_bridge_ticks" stroke="' ..
					util.rgb(styles.BRIDGE_CASING_COLOUR) .. '" stroke-width="' .. util.num(styles.BRIDGE_TICK_WIDTH * ws) ..
					'" stroke-linecap="butt">\n')
				for cat, paths in pairs(roadGroups) do
					for _i, seg in ipairs(paths) do
						if seg.kind == 1 and seg.geo then
							local half = (seg.w / 2 + styles.BRIDGE_CASING_PX + styles.BRIDGE_TICK_EXTRA) * ws
							f:write('<path d="' .. util.edgeEndTicks(t, seg.geo.p0, seg.geo.m0,
								seg.geo.p1, seg.geo.m1, half) .. '"/>')
						end
					end
				end
				f:write('\n</g>\n')
			end
		end
		for cat, paths in pairs(roadGroups) do
			-- Colour is per category (the group stroke); width is per road,
			-- emitted on each path from its real carriageway width.
			local col = styles.ROAD_COLOURS[cat] or styles.ROAD_COLOURS.default
			f:write('<g inkscape:label="roads_' .. util.esc(cat) .. '" stroke="' ..
				util.rgb(col) .. '">\n')
			for _i, seg in ipairs(paths) do
				-- Tunnels are drawn as dashed outline lines above, not as a fill.
				if not (styles.BRIDGE_TUNNEL and seg.kind == 2) then
					f:write('<path stroke-width="' .. util.num(seg.w * ws) .. '" d="' .. seg.d .. '"/>')
				end
			end
			f:write('\n</g>\n')
			trace("roads: " .. cat .. " = " .. #paths .. " paths")
			yield("roads:" .. cat)
		end
		f:write('</g>\n')
	end

	if doRail then
		-- OSM crosstie style: a solid light base line, then dark grey dashes on
		-- top so the gaps reveal the base and the dashes read as ties. Butt caps
		-- keep the ties crisp and rectangular.
		f:write('<g inkscape:groupmode="layer" inkscape:label="rail" id="rail" fill="none" stroke-linejoin="round">\n')
		-- Bridge casing: a darker, heavier outline under bridge spans.
		if styles.BRIDGE_TUNNEL then
			f:write('<g inkscape:label="rail_bridge_casing" stroke="' ..
				util.rgb(styles.BRIDGE_CASING_COLOUR) .. '" stroke-width="' ..
				util.num((styles.RAIL_WIDTH + 2 * styles.BRIDGE_CASING_PX) * ws) .. '" stroke-linecap="round">\n')
			for _i, seg in ipairs(railPaths) do
				if seg.kind == 1 then f:write('<path d="' .. seg.d .. '"/>') end
			end
			f:write('\n</g>\n')
			-- Bridge end ticks.
			if styles.BRIDGE_TICKS then
				f:write('<g inkscape:label="rail_bridge_ticks" stroke="' ..
					util.rgb(styles.BRIDGE_CASING_COLOUR) .. '" stroke-width="' .. util.num(styles.BRIDGE_TICK_WIDTH * ws) ..
					'" stroke-linecap="butt">\n')
				for _i, seg in ipairs(railPaths) do
					if seg.kind == 1 and seg.geo then
						local half = (styles.RAIL_WIDTH / 2 + styles.BRIDGE_CASING_PX + styles.BRIDGE_TICK_EXTRA) * ws
						f:write('<path d="' .. util.edgeEndTicks(t, seg.geo.p0, seg.geo.m0,
							seg.geo.p1, seg.geo.m1, half) .. '"/>')
					end
				end
				f:write('\n</g>\n')
			end
		end
		f:write('<g inkscape:label="rail_base" stroke="' .. util.rgb(styles.RAIL_BASE_COLOUR) ..
			'" stroke-width="' .. util.num(styles.RAIL_WIDTH * ws) .. '" stroke-linecap="round">\n')
		for _i, seg in ipairs(railPaths) do
			-- Tunnels are drawn separately (dashed); base/ties cover ground + bridge.
			if not (styles.BRIDGE_TUNNEL and seg.kind == 2) then f:write('<path d="' .. seg.d .. '"/>') end
		end
		f:write('\n</g>\n')
		f:write('<g inkscape:label="rail_ties" stroke="' .. util.rgb(styles.RAIL_DASH_COLOUR) ..
			'" stroke-width="' .. util.num(styles.RAIL_WIDTH * ws) .. '" stroke-linecap="butt" stroke-dasharray="' ..
			util.num(styles.RAIL_DASH * ws) .. ',' .. util.num(styles.RAIL_GAP * ws) .. '">\n')
		for _i, seg in ipairs(railPaths) do
			if not (styles.BRIDGE_TUNNEL and seg.kind == 2) then f:write('<path d="' .. seg.d .. '"/>') end
		end
		f:write('\n</g>\n')
		-- Tunnels: two thin parallel dashed lines ("====") in the tie colour so the
		-- route reads as passing underground.
		if styles.BRIDGE_TUNNEL then
			local railTunnelW = styles.TUNNEL_LINE_WIDTH / 2
			f:write('<g inkscape:label="rail_tunnel" stroke="' .. util.rgb(styles.RAIL_DASH_COLOUR) ..
				'" stroke-width="' .. util.num(railTunnelW * ws) .. '" stroke-linecap="butt" stroke-dasharray="' ..
				util.num(styles.TUNNEL_DASH * ws) .. ',' .. util.num(styles.TUNNEL_GAP * ws) .. '">\n')
			for _i, seg in ipairs(railPaths) do
				if seg.kind == 2 then
					if styles.TUNNEL_PARALLEL and seg.geo then
						local off = (styles.RAIL_WIDTH / 2 - railTunnelW / 2) * ws
						local g = seg.geo
						f:write('<path d="' .. util.edgeToBezierOffset(t, g.p0, g.m0, g.p1, g.m1, off) .. '"/>')
						f:write('<path d="' .. util.edgeToBezierOffset(t, g.p0, g.m0, g.p1, g.m1, -off) .. '"/>')
					else
						f:write('<path d="' .. seg.d .. '"/>')
					end
				end
			end
			f:write('\n</g>\n')
		end
		f:write('</g>\n')
		trace("rail: " .. #railPaths .. " paths")
	end
	trace("networks: done")
end

----------------------------------------------------------------------
-- Stations layer.
-- Road stops      -> triangle, train stops -> pentagon.
-- Cargo           -> brown,    passenger    -> blue.
-- Other carriers (air/water) fall back to a circle so they still appear.
----------------------------------------------------------------------
local function emitStations(f, t, yield, legend)
	trace("stations: start")
	f:write('<g inkscape:groupmode="layer" inkscape:label="stations" id="stations" stroke="#222222" stroke-width="2" fill-opacity="0.9">\n')
	local seen = {}
	local ops = 0
	local drawn = 0

	local nodePos = {}
	local function getNodePos(node)
		local p = nodePos[node]
		if p == nil then
			local nc = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE)
			-- copy out of the aliasing userdata immediately (see networks note)
			p = (nc and nc.position) and { x = nc.position.x, y = nc.position.y, z = nc.position.z } or false
			nodePos[node] = p
		end
		return p or nil
	end

	-- Resolve a world position for a station, from its construction if it has
	-- one, otherwise from its terminal vehicle node (bus/truck stops).
	local function stationWorldPos(stationComp, constructionId)
		if constructionId ~= -1 then
			local c = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
			if c then
				local o = c.transf:cols(3)
				return o.x, o.y
			end
		end
		local term = stationComp.terminals and stationComp.terminals[1]
		if term and term.vehicleNodeId then
			local ent = term.vehicleNodeId.entity
			local e = api.engine.getComponent(ent, api.type.ComponentType.BASE_EDGE)
			if e then
				local n0 = getNodePos(e.node0)
				local n1 = getNodePos(e.node1)
				if n0 and n1 then return (n0.x + n1.x) / 2, (n0.y + n1.y) / 2 end
			end
			local nc = api.engine.getComponent(ent, api.type.ComponentType.BASE_NODE)
			if nc and nc.position then return nc.position.x, nc.position.y end
		end
		return nil
	end

	api.engine.forEachEntityWithComponent(function(entity)
		local station = api.engine.getComponent(entity, api.type.ComponentType.STATION)
		if not station then return end
		local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(entity)
		-- de-duplicate multi-station constructions (rail stations); road stops
		-- have no construction so each is kept.
		if constructionId ~= -1 then
			if seen[constructionId] then return end
			seen[constructionId] = true
		end

		local wx, wy = stationWorldPos(station, constructionId)
		if not wx then return end
		local cx = t.x(wx)
		local cy = t.y(wy)

		-- The raw STATION component's `carriers` is NOT a string-keyed table;
		-- the interface entity exposes carriers.RAIL/ROAD/AIR/WATER + cargo.
		local iface
		local okI = pcall(function() iface = game.interface.getEntity(entity) end)
		local carriers = (okI and iface and iface.carriers) or {}
		local isCargo = (okI and iface and iface.cargo) or station.cargo

		local colour = isCargo and styles.STATION_CARGO or styles.STATION_PASS
		-- Record the carrier+kind combo for the legend (same priority as drawing).
		local ckey = (carriers.RAIL and "RAIL") or (carriers.ROAD and "ROAD") or
			(carriers.WATER and "WATER") or (carriers.AIR and "AIR") or nil
		if legend and ckey then
			legend.stations = legend.stations or {}
			local e = legend.stations[ckey]
			if not e then e = {}; legend.stations[ckey] = e end
			if isCargo then e.goods = true else e.pass = true end
		end
		if carriers.RAIL then
			-- Rail stations use the railway icon; goods variant overlays a boxcar.
			local href = isCargo and "#station-rail-goods" or "#station-rail-pass"
			f:write('<use xlink:href="' .. href .. '" transform="translate(' ..
				util.num(cx) .. ',' .. util.num(cy) .. ') scale(' .. util.num(styles.STATION_ICON_SCALE) .. ')"/>\n')
		elseif carriers.ROAD then
			-- Road stops use the bus/truck icon (passenger vs goods). They are
			-- the most numerous markers, so they are drawn smallest.
			local href = isCargo and "#station-road-goods" or "#station-road-pass"
			f:write('<use xlink:href="' .. href .. '" transform="translate(' ..
				util.num(cx) .. ',' .. util.num(cy) .. ') scale(' .. util.num(styles.ROAD_STOP_SCALE) .. ')"/>\n')
		elseif carriers.WATER then
			-- Water stops use the ship icon; goods variant overlays a boxcar.
			local href = isCargo and "#station-water-goods" or "#station-water-pass"
			f:write('<use xlink:href="' .. href .. '" transform="translate(' ..
				util.num(cx) .. ',' .. util.num(cy) .. ') scale(' .. util.num(styles.STATION_ICON_SCALE) .. ')"/>\n')
		elseif carriers.AIR then
			-- Air stops use the plane icon; goods variant overlays a boxcar.
			local href = isCargo and "#station-air-goods" or "#station-air-pass"
			f:write('<use xlink:href="' .. href .. '" transform="translate(' ..
				util.num(cx) .. ',' .. util.num(cy) .. ') scale(' .. util.num(styles.STATION_ICON_SCALE) .. ')"/>\n')
		else
			-- unknown carrier: circle fallback
			f:write('<circle cx="' .. util.num(cx) .. '" cy="' .. util.num(cy) ..
				'" r="' .. styles.STATION_RADIUS .. '" fill="' .. util.rgb(colour) .. '"/>\n')
		end
		drawn = drawn + 1
		ops = ops + 1
		if ops % 100 == 0 then yield("stations") end
	end, api.type.ComponentType.STATION)
	f:write('</g>\n')
	trace("stations: done, " .. drawn .. " markers")
end

----------------------------------------------------------------------
-- Depots layer.
-- Each depot is one construction; its mode (rail / road / tram / water) is
-- read from the construction fileName. Depots are shared passenger/cargo, so
-- there is a single icon per mode. Airports have no separate depot, so AIR is
-- intentionally not handled.
----------------------------------------------------------------------
local function depotHref(fileName)
	local fn = string.lower(fileName or "")
	if string.find(fn, "tram") then return "#depot-tram" end
	if string.find(fn, "train") or string.find(fn, "rail") then return "#depot-rail" end
	if string.find(fn, "ship") or string.find(fn, "water") then return "#depot-water" end
	if string.find(fn, "street") or string.find(fn, "road") or string.find(fn, "truck") or string.find(fn, "bus") then
		return "#depot-road"
	end
	return "#depot-road" -- sensible default for unknown street-type depots
end

local function emitDepots(f, t, yield, legend)
	trace("depots: start")
	f:write('<g inkscape:groupmode="layer" inkscape:label="depots" id="depots">\n')
	local ops = 0
	local drawn = 0
	-- Depots are constructions whose fileName lives under "depot/". Iterate
	-- CONSTRUCTION entities (there is no DEPOT component enum to query) and
	-- match by filename.
	api.engine.forEachEntityWithComponent(function(entity)
		local construction = api.engine.getComponent(entity, api.type.ComponentType.CONSTRUCTION)
		if not construction then return end
		local fn = string.lower(construction.fileName or "")
		if not string.find(fn, "depot") then return end
		local pos = construction.transf:cols(3)
		local cx = t.x(pos.x)
		local cy = t.y(pos.y)
		local href = depotHref(fn)
		if legend then
			legend.depots = legend.depots or {}
			legend.depots[(href:gsub("#depot%-", ""))] = true
		end
		f:write('<use xlink:href="' .. href .. '" transform="translate(' ..
			util.num(cx) .. ',' .. util.num(cy) .. ') scale(' .. util.num(styles.DEPOT_ICON_SCALE) .. ')"/>\n')
		drawn = drawn + 1
		ops = ops + 1
		if ops % 100 == 0 then yield("depots") end
	end, api.type.ComponentType.CONSTRUCTION)
	f:write('</g>\n')
	trace("depots: done, " .. drawn .. " markers")
end

----------------------------------------------------------------------
-- Towns layer (marker + name label)
----------------------------------------------------------------------
local function emitTowns(f, t, yield, legend)
	trace("towns: start")
	f:write('<g inkscape:groupmode="layer" inkscape:label="towns" id="towns">\n')
	local ops = 0
	api.engine.forEachEntityWithComponent(function(entity)
		local ok, town = pcall(function() return game.interface.getEntity(entity) end)
		if not ok or not town or not town.position then return end
		local cx = t.x(town.position[1])
		local cy = t.y(town.position[2])
		f:write('<use xlink:href="#town-marker" transform="translate(' ..
			util.num(cx) .. ',' .. util.num(cy) .. ') scale(' .. util.num(styles.TOWN_ICON_SCALE) .. ')"/>')
		if legend then legend.hasTowns = true end
		if town.name then
			-- name in black, centred directly below the icon
			local ly = cy + styles.ICON_BASE_RADIUS * styles.TOWN_ICON_SCALE + 22
			f:write('<text x="' .. util.num(cx) .. '" y="' .. util.num(ly) ..
				'" text-anchor="middle" font-family="sans-serif" font-size="22" ' ..
				'fill="' .. util.rgb(styles.LABEL_COLOUR) .. '" stroke="#ffffff" stroke-width="3" ' ..
				'paint-order="stroke">' .. util.esc(town.name) .. '</text>')
		end
		f:write("\n")
		ops = ops + 1
		if ops % 100 == 0 then yield("towns") end
	end, api.type.ComponentType.TOWN)
	f:write('</g>\n')
	trace("towns: done, " .. ops .. " towns")
end

----------------------------------------------------------------------
-- Industries layer (marker + name label)
----------------------------------------------------------------------
local function emitIndustries(f, t, yield, legend)
	trace("industries: start")
	f:write('<g inkscape:groupmode="layer" inkscape:label="industries" id="industries">\n')
	local ops = 0
	api.engine.forEachEntityWithComponent(function(entity)
		local constructionId = api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(entity)
		if constructionId == -1 then return end
		local construction = api.engine.getComponent(constructionId, api.type.ComponentType.CONSTRUCTION)
		if not construction then return end
		local fileName = construction.fileName or ""
		if not string.find(fileName, "industry") or string.find(fileName, "extension") then return end
		local pos = construction.transf:cols(3)
		local cx = t.x(pos.x)
		local cy = t.y(pos.y)
		f:write('<use xlink:href="#industry-marker" transform="translate(' ..
			util.num(cx) .. ',' .. util.num(cy) .. ') scale(' .. styles.INDUSTRY_ICON_SCALE .. ')"/>')
		if legend then legend.hasIndustries = true end
		local nameComp = api.engine.getComponent(constructionId, api.type.ComponentType.NAME)
		local label = nameComp and nameComp.name
		if label then
			-- name in black, centred directly below the icon
			local ly = cy + styles.ICON_BASE_RADIUS * styles.INDUSTRY_ICON_SCALE + 20
			f:write('<text x="' .. util.num(cx) .. '" y="' .. util.num(ly) ..
				'" text-anchor="middle" font-family="sans-serif" font-size="18" ' ..
				'fill="' .. util.rgb(styles.LABEL_COLOUR) .. '" stroke="#ffffff" stroke-width="3" ' ..
				'paint-order="stroke">' .. util.esc(label) .. '</text>')
		end
		f:write("\n")
		ops = ops + 1
		if ops % 100 == 0 then yield("industries") end
	end, api.type.ComponentType.SIM_BUILDING)
	f:write('</g>\n')
	trace("industries: done, " .. ops .. " industries")
end

----------------------------------------------------------------------
-- Legend band (bottom). Renders ONLY the network and marker types that were
-- actually drawn, as collected into `legend` by the emit functions. The band
-- is laid out in a fixed-width "design" coordinate space (LEGEND_BASE_WIDTH)
-- and then scaled so it spans the full canvas width, which makes it appear the
-- same relative size on every map. It is appended BELOW the map (the map keeps
-- its own height; the SVG height is patched afterwards to include the band).
-- Returns the band's height in canvas pixels (0 if nothing was drawn).
----------------------------------------------------------------------
local function emitLegend(f, t, legend, canvasW, mapH)
	if not legend then return 0 end

	local ROAD_ORDER = { "highway", "country", "urban", "one-way", "default" }
	local ROAD_LABELS = {
		highway = "Highway", country = "Country road", urban = "Urban road",
		["one-way"] = "One-way road", default = "Other road",
	}
	local CARRIER_ORDER = { "RAIL", "ROAD", "WATER", "AIR" }
	local CARRIER_LABELS = { RAIL = "Rail", ROAD = "Road", WATER = "Water", AIR = "Air" }
	local DEPOT_ORDER = { "rail", "road", "tram", "water" }
	local DEPOT_LABELS = {
		rail = "Rail depot", road = "Road depot", tram = "Tram depot", water = "Water depot",
	}

	local roadCats = legend.roadCats or {}
	local hasNetworks = legend.hasRail or legend.hasBridge or legend.hasTunnel or false
	for _ in pairs(roadCats) do hasNetworks = true; break end
	local hasStations = legend.stations ~= nil
	local hasDepots = legend.depots ~= nil
	local hasOther = hasDepots or legend.hasTowns or legend.hasIndustries
	if not (hasNetworks or hasStations or hasOther) then return 0 end

	-- All coordinates below are in design space (units), scaled to the canvas
	-- width at the end via `scale`.
	local pad = styles.LEGEND_PAD
	local rowH = styles.LEGEND_ROW_H
	local font = styles.LEGEND_FONT
	local hfont = styles.LEGEND_HEADER_FONT
	local parts = {}
	local function push(s) parts[#parts + 1] = s end

	local function headerAt(cx, cy, label)
		push('<text x="' .. util.num(cx) .. '" y="' .. util.num(cy + hfont * 0.82) ..
			'" font-family="sans-serif" font-size="' .. hfont .. '" font-weight="bold" fill="#111111">' ..
			util.esc(label) .. '</text>')
		return cy + hfont + 20
	end
	local function labelAt(lx, cy, label, size, fill)
		push('<text x="' .. util.num(lx) .. '" y="' .. util.num(cy + (size or font) * 0.34) ..
			'" font-family="sans-serif" font-size="' .. (size or font) .. '" fill="' ..
			(fill or "#111111") .. '">' .. util.esc(label) .. '</text>')
	end
	local function lineSwatch(x1, cy, col, w, extra)
		return '<line x1="' .. util.num(x1) .. '" y1="' .. util.num(cy) ..
			'" x2="' .. util.num(x1 + styles.LEGEND_SWATCH) .. '" y2="' .. util.num(cy) ..
			'" stroke="' .. col .. '" stroke-width="' .. w .. '"' .. (extra or '') .. '/>'
	end

	-- Decide which columns are present and their design widths.
	local cols = {}
	if hasNetworks then cols[#cols + 1] = { kind = "networks", w = 560 } end
	if hasStations then cols[#cols + 1] = { kind = "stations", w = 620 } end
	if hasOther then cols[#cols + 1] = { kind = "other", w = 460 } end

	local colGap = 60
	local x = pad
	for _i, c in ipairs(cols) do
		c.x = x
		x = x + c.w + colGap
	end
	local contentRight = x - colGap
	local topY = pad
	local maxBottom = topY

	-- ---- Networks column ----
	local function drawNetworks(cx)
		local labelX = cx + styles.LEGEND_SWATCH + 20
		local y = headerAt(cx, topY, "Networks")
		local function row(label, swatchFn)
			local cy = y + rowH / 2
			push(swatchFn(cy))
			labelAt(labelX, cy, label)
			y = y + rowH
		end
		local caseCol = util.rgb(styles.ROAD_CASING_COLOURS[styles.ROAD_CASING_THEME] or styles.ROAD_CASING_COLOURS.light)
		for _i, cat in ipairs(ROAD_ORDER) do
			if roadCats[cat] then
				local col = util.rgb(styles.ROAD_COLOURS[cat] or styles.ROAD_COLOURS.default)
				row(ROAD_LABELS[cat] or cat, function(cy)
					local s = ""
					if styles.ROAD_CASING then s = lineSwatch(cx, cy, caseCol, 14, ' stroke-linecap="round"') end
					return s .. lineSwatch(cx, cy, col, 9, ' stroke-linecap="round"')
				end)
			end
		end
		if legend.hasRail then
			row("Railway", function(cy)
				return lineSwatch(cx, cy, util.rgb(styles.RAIL_BASE_COLOUR), styles.RAIL_WIDTH, ' stroke-linecap="round"') ..
					lineSwatch(cx, cy, util.rgb(styles.RAIL_DASH_COLOUR), styles.RAIL_WIDTH,
						' stroke-linecap="butt" stroke-dasharray="' .. styles.RAIL_DASH .. ',' .. styles.RAIL_GAP .. '"')
			end)
		end
		if legend.hasBridge then
			row("Bridge", function(cy)
				local th = 12
				local cc = util.rgb(styles.BRIDGE_CASING_COLOUR)
				local s = lineSwatch(cx, cy, cc, 14, ' stroke-linecap="butt"')
				s = s .. '<line x1="' .. util.num(cx) .. '" y1="' .. util.num(cy - th) ..
					'" x2="' .. util.num(cx) .. '" y2="' .. util.num(cy + th) ..
					'" stroke="' .. cc .. '" stroke-width="3"/>'
				s = s .. '<line x1="' .. util.num(cx + styles.LEGEND_SWATCH) .. '" y1="' .. util.num(cy - th) ..
					'" x2="' .. util.num(cx + styles.LEGEND_SWATCH) .. '" y2="' .. util.num(cy + th) ..
					'" stroke="' .. cc .. '" stroke-width="3"/>'
				return s
			end)
		end
		if legend.hasTunnel then
			row("Tunnel", function(cy)
				local off = 5
				local cc = util.rgb(styles.ROAD_CASING_COLOURS[styles.ROAD_CASING_THEME] or styles.ROAD_CASING_COLOURS.light)
				local da = ' stroke-linecap="butt" stroke-dasharray="' .. styles.TUNNEL_DASH .. ',' .. styles.TUNNEL_GAP .. '"'
				return lineSwatch(cx, cy - off, cc, 3, da) .. lineSwatch(cx, cy + off, cc, 3, da)
			end)
		end
		return y
	end

	-- ---- Stations column (tabular: row per carrier, passenger / goods) ----
	local function drawStations(cx, cw)
		local colP = cx + cw - 220
		local colG = cx + cw - 80
		local y = headerAt(cx, topY, "Stations")
		-- centre the column headers over their badge columns
		push('<text x="' .. util.num(colP) .. '" y="' .. util.num(y + (font - 4) * 0.82) ..
			'" text-anchor="middle" font-family="sans-serif" font-size="' .. (font - 4) ..
			'" fill="#333333">Passenger</text>')
		push('<text x="' .. util.num(colG) .. '" y="' .. util.num(y + (font - 4) * 0.82) ..
			'" text-anchor="middle" font-family="sans-serif" font-size="' .. (font - 4) ..
			'" fill="#333333">Goods</text>')
		y = y + font + 10
		for _i, c in ipairs(CARRIER_ORDER) do
			local st = legend.stations[c]
			if st then
				local cy = y + rowH / 2
				labelAt(cx, cy, CARRIER_LABELS[c])
				local low = string.lower(c)
				if st.pass then
					push('<use xlink:href="#station-' .. low .. '-pass" transform="translate(' ..
						util.num(colP) .. ',' .. util.num(cy) .. ') scale(' .. util.num(styles.LEGEND_BADGE_SCALE) .. ')"/>')
				end
				if st.goods then
					push('<use xlink:href="#station-' .. low .. '-goods" transform="translate(' ..
						util.num(colG) .. ',' .. util.num(cy) .. ') scale(' .. util.num(styles.LEGEND_BADGE_SCALE) .. ')"/>')
				end
				y = y + rowH
			end
		end
		return y
	end

	-- ---- Other column (depots / towns / industries) ----
	local function drawOther(cx)
		local badgeR = 14 * styles.LEGEND_BADGE_SCALE
		local labelX = cx + badgeR * 2 + 18
		local y = headerAt(cx, topY, "Other")
		local function markerRow(href, label)
			local cy = y + rowH / 2
			push('<use xlink:href="' .. href .. '" transform="translate(' ..
				util.num(cx + badgeR) .. ',' .. util.num(cy) .. ') scale(' .. util.num(styles.LEGEND_BADGE_SCALE) .. ')"/>')
			labelAt(labelX, cy, label)
			y = y + rowH
		end
		if hasDepots then
			for _i, m in ipairs(DEPOT_ORDER) do
				if legend.depots[m] then markerRow("#depot-" .. m, DEPOT_LABELS[m]) end
			end
		end
		if legend.hasTowns then markerRow("#town-marker", "Town") end
		if legend.hasIndustries then markerRow("#industry-marker", "Industry") end
		return y
	end

	for _i, c in ipairs(cols) do
		local bottom
		if c.kind == "networks" then
			bottom = drawNetworks(c.x)
		elseif c.kind == "stations" then
			bottom = drawStations(c.x, c.w)
		else
			bottom = drawOther(c.x)
		end
		if bottom > maxBottom then maxBottom = bottom end
	end

	-- Total design height of the band, then scale to span the canvas width.
	local bandDesignH = maxBottom + pad
	local s = canvasW / styles.LEGEND_BASE_WIDTH
	local bandCanvasH = bandDesignH * s

	f:write('<g inkscape:groupmode="layer" inkscape:label="legend" id="legend">\n')
	-- Band background + a divider line at the seam with the map.
	f:write('<rect x="0" y="' .. util.num(mapH) .. '" width="' .. util.num(canvasW) ..
		'" height="' .. util.num(bandCanvasH) .. '" fill="' .. styles.LEGEND_BG .. '"/>\n')
	f:write('<line x1="0" y1="' .. util.num(mapH) .. '" x2="' .. util.num(canvasW) ..
		'" y2="' .. util.num(mapH) .. '" stroke="#333333" stroke-width="' .. util.num(2 * s) .. '"/>\n')
	f:write('<g transform="translate(0,' .. util.num(mapH) .. ') scale(' .. util.num(s) .. ')">\n')
	f:write(table.concat(parts))
	f:write('</g>\n</g>\n')
	trace("legend: done, band height", bandCanvasH)
	return bandCanvasH
end

----------------------------------------------------------------------
-- Build the list of export steps.
-- IMPORTANT: the engine query API (forEachEntityWithComponent,
-- getBaseHeightAt, getComponent, game.interface.*) only returns data when
-- called on the main script thread. We therefore do NOT use a coroutine;
-- instead each step runs synchronously inside guiUpdate, one per frame, so
-- the game can breathe between layers while every query runs on the main
-- thread.
----------------------------------------------------------------------
local NOOP = function() end

local function buildSteps()
	local steps = {}
	local ctx = {}

	table.insert(steps, { "preparing", function()
		ctx.bx, ctx.by = util.discoverMapBoundary()
		trace("map boundary", ctx.bx, ctx.by)
		-- Derive the export resolution from the map's real dimensions: TPF2
		-- terrain is tiled, so px = tiles*256+1 per axis (matches the in-game
		-- heightmap sizes). Non-square maps therefore export at their true
		-- aspect ratio. Clamp to a safety maximum.
		local cw, ch = util.tileCanvasSize(ctx.bx, ctx.by)
		if cw > CANVAS_MAX then cw = CANVAS_MAX end
		if ch > CANVAS_MAX then ch = CANVAS_MAX end
		ctx.canvasW, ctx.canvasH = cw, ch
		trace("canvas size", cw, ch)
		ctx.t = util.makeTransform(ctx.bx, ctx.by, cw, ch)
		-- Apply the configured stroke-width scaling to the transform.
		if styles.STROKE_SCALE then
			ctx.t.strokeRef = styles.STROKE_SCALE_REFERENCE
			ctx.t.strokeMin = styles.STROKE_SCALE_MIN
			ctx.t.strokeMax = styles.STROKE_SCALE_MAX
			ctx.t.computeWidthScale()
		else
			ctx.t.widthScale = 1
		end
		trace("stroke width scale", ctx.t.widthScale)
		ctx.legend = {}
		local f, path, err = openOutput()
		if not f then error(err) end
		ctx.f = f
		ctx.path = path
		f:write('<?xml version="1.0" encoding="UTF-8"?>\n')
		-- The height is written as a fixed-width zero-padded placeholder so that,
		-- once the legend band size is known, we can seek back and patch it in
		-- place (binary mode keeps byte offsets exact). It starts equal to the
		-- map height, so if no legend is drawn the value is already correct.
		f:write('<svg xmlns="http://www.w3.org/2000/svg" ' ..
			'xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" ' ..
			'xmlns:xlink="http://www.w3.org/1999/xlink" ' ..
			'width="' .. cw .. '" height="')
		ctx.heightPos1 = f:seek("cur")
		f:write(string.format("%06d", ch))
		f:write('" viewBox="0 0 ' .. cw .. ' ')
		ctx.heightPos2 = f:seek("cur")
		f:write(string.format("%06d", ch))
		f:write('">\n')
		f:write('<!-- map boundary metres: ' .. ctx.bx .. ' x ' .. ctx.by .. ' -->\n')
		f:write('<rect width="' .. cw .. '" height="' .. ch .. '" fill="#0d1b2a"/>\n')
		-- Reusable town marker: the Material "location_city" glyph
		-- (res/textures/ui/icons/location_city_icon.svg) on a coloured badge,
		-- centred on the town point. The glyph's source viewBox is
		-- "0 -960 960 960"; we scale it to ~22px and recentre on the origin.
		f:write('<defs>\n' ..
			'<g id="town-marker">' ..
			'<circle cx="0" cy="0" r="14" fill="' .. util.rgb(styles.TOWN_FILL) ..
			'" stroke="' .. util.rgb(styles.TOWN_COLOUR) .. '" stroke-width="2"/>' ..
			'<g transform="translate(-11,11) scale(0.0229)" fill="' .. util.rgb(styles.TOWN_COLOUR) .. '">' ..
			'<path d="M120-120v-560h240v-80l120-120 120 120v240h240v400H120Zm80-80h80v-80h-80v80Zm0-160h80v-80h-80v80Zm0-160h80v-80h-80v80Zm240 320h80v-80h-80v80Zm0-16<PASSWORD>h8<PASSWORD> v-8<PASSWORD> h-8<PASSWORD> v8<PASSWORD> Zm<PASSWORD> 48<PASSWORD> h8<PASSWORD> v-8<PASSWORD> h-8<PASSWORD> v8<PASSWORD> Zm<PASSWORD> -16<PASSWORD> h8<PASSWORD> v-8<PASSWORD> h-8<PASSWORD> v8<PASSWORD> Z"/>' ..
			'</g>' ..
			'</g>\n' ..
			-- Passenger rail station: railway glyph on a blue badge.
			'<g id="station-rail-pass">' ..
			'<circle cx="0" cy="0" r="14" fill="' .. util.rgb(styles.STATION_PASS) ..
			'" stroke="' .. util.rgb(styles.TOWN_COLOUR) .. '" stroke-width="2"/>' ..
			'<g transform="translate(-11,11) scale(0.0229)" fill="' .. util.rgb(styles.TOWN_COLOUR) .. '">' ..
			styles.RAILWAY_GLYPH ..
			'</g>' ..
			'</g>\n' ..
			-- Goods rail station: railway glyph on a brown badge, with a small
			-- goods (boxcar) badge overlaid in the lower-right corner.
			'<g id="station-rail-goods">' ..
			'<circle cx="0" cy="0" r="14" fill="' .. util.rgb(styles.STATION_CARGO) ..
			'" stroke="' .. util.rgb(styles.TOWN_COLOUR) .. '" stroke-width="2"/>' ..
			'<g transform="translate(-11,11) scale(0.0229)" fill="' .. util.rgb(styles.TOWN_COLOUR) .. '">' ..
			styles.RAILWAY_GLYPH ..
			'</g>' ..
			'<circle cx="9" cy="9" r="8.5" fill="' .. util.rgb(styles.TOWN_COLOUR) ..
			'" stroke="' .. util.rgb(styles.STATION_CARGO) .. '" stroke-width="1.5"/>' ..
			'<g transform="translate(3.4,14.6) scale(0.0117)" fill="' .. util.rgb(styles.STATION_CARGO) .. '">' ..
			styles.GOODS_GLYPH ..
			'</g>' ..
			'</g>\n')
		f:write(
			-- Passenger road stop: bus glyph on a blue badge.
			'<g id="station-road-pass">' ..
			'<circle cx="0" cy="0" r="14" fill="' .. util.rgb(styles.STATION_PASS) ..
			'" stroke="' .. util.rgb(styles.TOWN_COLOUR) .. '" stroke-width="2"/>' ..
			'<g transform="translate(-11,11) scale(0.0229)" fill="' .. util.rgb(styles.TOWN_COLOUR) .. '">' ..
			styles.BUS_GLYPH ..
			'</g>' ..
			'</g>\n' ..
			-- Goods road stop: truck glyph on a brown badge.
			'<g id="station-road-goods">' ..
			'<circle cx="0" cy="0" r="14" fill="' .. util.rgb(styles.STATION_CARGO) ..
			'" stroke="' .. util.rgb(styles.TOWN_COLOUR) .. '" stroke-width="2"/>' ..
			'<g transform="translate(-11,11) scale(0.0229)" fill="' .. util.rgb(styles.TOWN_COLOUR) .. '">' ..
			styles.TRUCK_GLYPH ..
			'</g>' ..
			'</g>\n')
		f:write(
			-- Passenger water stop: ship glyph on a blue badge.
			'<g id="station-water-pass">' ..
			'<circle cx="0" cy="0" r="14" fill="' .. util.rgb(styles.STATION_PASS) ..
			'" stroke="' .. util.rgb(styles.TOWN_COLOUR) .. '" stroke-width="2"/>' ..
			'<g transform="translate(-11,11) scale(0.0229)" fill="' .. util.rgb(styles.TOWN_COLOUR) .. '">' ..
			styles.SHIP_GLYPH ..
			'</g>' ..
			'</g>\n' ..
			-- Goods water stop: ship glyph on a brown badge, with a small goods
			-- (boxcar) badge overlaid in the lower-right corner.
			'<g id="station-water-goods">' ..
			'<circle cx="0" cy="0" r="14" fill="' .. util.rgb(styles.STATION_CARGO) ..
			'" stroke="' .. util.rgb(styles.TOWN_COLOUR) .. '" stroke-width="2"/>' ..
			'<g transform="translate(-11,11) scale(0.0229)" fill="' .. util.rgb(styles.TOWN_COLOUR) .. '">' ..
			styles.SHIP_GLYPH ..
			'</g>' ..
			'<circle cx="9" cy="9" r="8.5" fill="' .. util.rgb(styles.TOWN_COLOUR) ..
			'" stroke="' .. util.rgb(styles.STATION_CARGO) .. '" stroke-width="1.5"/>' ..
			'<g transform="translate(3.4,14.6) scale(0.0117)" fill="' .. util.rgb(styles.STATION_CARGO) .. '">' ..
			styles.GOODS_GLYPH ..
			'</g>' ..
			'</g>\n')
		f:write(
			-- Passenger air stop: plane glyph on a blue badge.
			'<g id="station-air-pass">' ..
			'<circle cx="0" cy="0" r="14" fill="' .. util.rgb(styles.STATION_PASS) ..
			'" stroke="' .. util.rgb(styles.TOWN_COLOUR) .. '" stroke-width="2"/>' ..
			'<g transform="translate(-11,11) scale(0.0229)" fill="' .. util.rgb(styles.TOWN_COLOUR) .. '">' ..
			styles.AIR_GLYPH ..
			'</g>' ..
			'</g>\n' ..
			-- Goods air stop: plane glyph on a brown badge, with a small goods
			-- (boxcar) badge overlaid in the lower-right corner.
			'<g id="station-air-goods">' ..
			'<circle cx="0" cy="0" r="14" fill="' .. util.rgb(styles.STATION_CARGO) ..
			'" stroke="' .. util.rgb(styles.TOWN_COLOUR) .. '" stroke-width="2"/>' ..
			'<g transform="translate(-11,11) scale(0.0229)" fill="' .. util.rgb(styles.TOWN_COLOUR) .. '">' ..
			styles.AIR_GLYPH ..
			'</g>' ..
			'<circle cx="9" cy="9" r="8.5" fill="' .. util.rgb(styles.TOWN_COLOUR) ..
			'" stroke="' .. util.rgb(styles.STATION_CARGO) .. '" stroke-width="1.5"/>' ..
			'<g transform="translate(3.4,14.6) scale(0.0117)" fill="' .. util.rgb(styles.STATION_CARGO) .. '">' ..
			styles.GOODS_GLYPH ..
			'</g>' ..
			'</g>\n')
		f:write(
			-- Depots (shared passenger/cargo) on a slate badge, one per mode.
			'<g id="depot-rail">' ..
			'<circle cx="0" cy="0" r="14" fill="' .. util.rgb(styles.COLOUR_DEPOT) ..
			'" stroke="' .. util.rgb(styles.TOWN_COLOUR) .. '" stroke-width="2"/>' ..
			'<g transform="translate(-11,11) scale(0.0229)" fill="' .. util.rgb(styles.TOWN_COLOUR) .. '">' ..
			styles.RAILWAY_DEPOT_GLYPH ..
			'</g>' ..
			'</g>\n' ..
			'<g id="depot-road">' ..
			'<circle cx="0" cy="0" r="14" fill="' .. util.rgb(styles.COLOUR_DEPOT) ..
			'" stroke="' .. util.rgb(styles.TOWN_COLOUR) .. '" stroke-width="2"/>' ..
			'<g transform="translate(-11,11) scale(0.0229)" fill="' .. util.rgb(styles.TOWN_COLOUR) .. '">' ..
			styles.ROAD_DEPOT_GLYPH ..
			'</g>' ..
			'</g>\n' ..
			'<g id="depot-tram">' ..
			'<circle cx="0" cy="0" r="14" fill="' .. util.rgb(styles.COLOUR_DEPOT) ..
			'" stroke="' .. util.rgb(styles.TOWN_COLOUR) .. '" stroke-width="2"/>' ..
			'<g transform="translate(-11,11) scale(0.0229)" fill="' .. util.rgb(styles.TOWN_COLOUR) .. '">' ..
			styles.TRAM_DEPOT_GLYPH ..
			'</g>' ..
			'</g>\n' ..
			'<g id="depot-water">' ..
			'<circle cx="0" cy="0" r="14" fill="' .. util.rgb(styles.COLOUR_DEPOT) ..
			'" stroke="' .. util.rgb(styles.TOWN_COLOUR) .. '" stroke-width="2"/>' ..
			'<g transform="translate(-11,11) scale(0.0229)" fill="' .. util.rgb(styles.TOWN_COLOUR) .. '">' ..
			styles.SHIP_DEPOT_GLYPH ..
			'</g>' ..
			'</g>\n')
		f:write(
			-- Industry marker: factory glyph in white on a brown badge,
			-- used unconditionally for every industry.
			'<g id="industry-marker">' ..
			'<circle cx="0" cy="0" r="14" fill="' .. util.rgb(styles.COLOUR_GOODS) ..
			'" stroke="' .. util.rgb(styles.TOWN_COLOUR) .. '" stroke-width="2"/>' ..
			'<g transform="translate(-11,11) scale(0.0229)" fill="' .. util.rgb(styles.TOWN_COLOUR) .. '">' ..
			styles.INDUSTRY_GLYPH ..
			'</g>' ..
			'</g>\n' ..
			'</defs>\n')
	end })

	if guiState.layers.terrain then
		table.insert(steps, { "terrain", function()
			ctx.f:write('<g inkscape:groupmode="layer" inkscape:label="terrain" id="terrain">\n')
			emitTerrain(ctx.f, ctx.t, ctx.bx, ctx.by, NOOP)
			ctx.f:write('</g>\n')
		end })
	end
	if guiState.layers.roads or guiState.layers.rail then
		table.insert(steps, { "networks", function()
			emitNetworks(ctx.f, ctx.t, guiState.layers.roads, guiState.layers.rail, NOOP, ctx.legend)
		end })
	end
	if guiState.layers.stations then
		table.insert(steps, { "stations", function() emitStations(ctx.f, ctx.t, NOOP, ctx.legend) end })
	end
	if guiState.layers.depots then
		table.insert(steps, { "depots", function() emitDepots(ctx.f, ctx.t, NOOP, ctx.legend) end })
	end
	if guiState.layers.industries then
		table.insert(steps, { "industries", function() emitIndustries(ctx.f, ctx.t, NOOP, ctx.legend) end })
	end
	if guiState.layers.towns then
		table.insert(steps, { "towns", function() emitTowns(ctx.f, ctx.t, NOOP, ctx.legend) end })
	end
	-- The legend is always drawn (not a toggleable layer). It returns the height
	-- (canvas px) of the band it appended below the map, so the SVG height can be
	-- patched to include it.
	table.insert(steps, { "legend", function()
		ctx.bandH = emitLegend(ctx.f, ctx.t, ctx.legend, ctx.canvasW, ctx.canvasH) or 0
	end })

	table.insert(steps, { "finalizing", function()
		ctx.f:write('</svg>\n')
		-- Patch the placeholder height / viewBox height to map height + legend band.
		local total = math.floor(ctx.canvasH + (ctx.bandH or 0) + 0.5)
		if ctx.heightPos1 and ctx.heightPos2 then
			ctx.f:seek("set", ctx.heightPos1)
			ctx.f:write(string.format("%06d", total))
			ctx.f:seek("set", ctx.heightPos2)
			ctx.f:write(string.format("%06d", total))
		end
		ctx.f:close()
		ctx.f = nil
	end })

	return steps, ctx
end

----------------------------------------------------------------------
-- Drive one export step per frame from the game tick (main thread)
----------------------------------------------------------------------
local function finishExport(message, savedPath)
	guiState.exporting = false
	guiState.steps = nil
	guiState.stepIndex = nil
	if guiState.ctx and guiState.ctx.f then
		pcall(function() guiState.ctx.f:close() end)
	end
	guiState.ctx = nil
	if guiState.exportButton then guiState.exportButton:setEnabled(true) end
	if guiState.statusText and message then guiState.statusText:setText(message) end
end

local function stepExport()
	if not guiState.steps then return end
	local i = guiState.stepIndex
	local step = guiState.steps[i]
	if not step then
		finishExport(_("Saved: ") .. tostring(guiState.ctx and guiState.ctx.path))
		if guiState.progressText then guiState.progressText:setText(_("Done")) end
		trace("Saved", guiState.ctx and guiState.ctx.path)
		return
	end

	local label = step[1]
	if guiState.progressText then
		guiState.progressText:setText(_("Working: ") .. label ..
			" (" .. i .. "/" .. #guiState.steps .. ")")
	end
	trace("step " .. i .. "/" .. #guiState.steps .. ": " .. label)

	local ok, err = pcall(step[2])
	if not ok then
		trace("Export error at step", label, err)
		finishExport(_("Export failed: ") .. tostring(err))
		if guiState.progressText then guiState.progressText:setText(_("Failed")) end
		return
	end
	guiState.stepIndex = i + 1
end

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local function startExport()
	if guiState.exporting then return end
	if not io or not io.open then
		if guiState.statusText then
			guiState.statusText:setText(_("File writing (io) is not available in this game build."))
		end
		return
	end
	guiState.steps, guiState.ctx = buildSteps()
	guiState.stepIndex = 1
	guiState.exporting = true
	if guiState.exportButton then guiState.exportButton:setEnabled(false) end
	if guiState.progressText then guiState.progressText:setText(_("Starting...")) end
	if guiState.statusText then guiState.statusText:setText(_("Output folder: ") .. OUTPUT_FOLDER) end
end

local function buildWindow()
	local layout = api.gui.layout.BoxLayout.new("VERTICAL")

	layout:addItem(api.gui.comp.TextView.new(_("Select layers to export:")))

	local layerOrder = { "terrain", "roads", "rail", "stations", "depots", "towns", "industries" }
	for _i, key in ipairs(layerOrder) do
		local cb = api.gui.comp.CheckBox.new(_(key))
		cb:setSelected(guiState.layers[key], false)
		cb:onToggle(function(b) guiState.layers[key] = b end)
		layout:addItem(cb)
	end

	layout:addItem(api.gui.comp.Component.new("HorizontalLine"))

	local exportButton = api.gui.comp.Button.new(api.gui.comp.TextView.new(_("Export SVG")), true)
	exportButton:onClick(startExport)
	guiState.exportButton = exportButton
	layout:addItem(exportButton)

	guiState.progressText = api.gui.comp.TextView.new(_("Idle"))
	layout:addItem(guiState.progressText)
	guiState.statusText = api.gui.comp.TextView.new(_("Output: ") .. OUTPUT_FOLDER)
	layout:addItem(guiState.statusText)

	local wrap = api.gui.comp.Component.new("")
	wrap:setLayout(layout)

	local window = api.gui.comp.Window.new(_("Cartograph - Vector Map Exporter"), wrap)
	window:setMinimumSize(api.gui.util.Size.new(420, 300))
	window:addHideOnCloseHandler()
	return window
end

local function createComponents()
	-- Set the guard immediately so that, even if something below throws, we do
	-- not re-enter and spawn another toolbar button on every gui update.
	guiState.init = true

	local icon = api.gui.comp.ImageView.new("button/medium/vector_map_export@2x.tga")
	icon:setMaximumSize(api.gui.util.Size.new(56, 56))
	icon:setMinimumSize(api.gui.util.Size.new(56, 56))

	local button = api.gui.comp.ToggleButton.new(icon)
	button:setTooltip(_("Cartograph - Vector Map Exporter"))
	button:setName("ConstructionMenuIndicator")
	button:setMinimumSize(api.gui.util.Size.new(48, 48))

	local layout = api.gui.util.getById("mainButtonsLayout"):getItem(0)
	layout:insertItem(button, 0)

	local window = buildWindow()
	window:setVisible(false, false)

	button:onToggle(function(b)
		if b then
			local mainView = game.gui.getContentRect("mainView")
			local x = math.floor(mainView[3] / 2)
			local y = math.floor(mainView[4] * (1 / 3))
			window:setPosition(x, y)
			window:setVisible(true, false)
		else
			window:close()
		end
	end)
	window:onClose(function() button:setSelected(false, false) end)

	trace("toolbar button added")
end

local function err(x)
	print("[VectorMapExporter] error caught:", x)
	print(debug.traceback())
end

----------------------------------------------------------------------
-- Game script entry point
----------------------------------------------------------------------
function data()
	return {
		save = function() return {} end,
		load = function(state) end,
		guiInit = function()
			xpcall(createComponents, err)
		end,
		guiUpdate = function()
			if not guiState.init then xpcall(createComponents, err) end
			if guiState.exporting then xpcall(stepExport, err) end
		end,
		update = function() end,
		guiHandleEvent = function(id, name, param) end,
		handleEvent = function(src, id, name, param) end,
	}
end
