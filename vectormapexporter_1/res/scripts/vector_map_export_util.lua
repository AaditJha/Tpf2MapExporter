-- Vector Map Exporter - utility module
-- Self contained: coordinate transform, Hermite->Bezier conversion,
-- SVG string helpers and map boundary discovery.

local util = {}

----------------------------------------------------------------------
-- Small vector helpers (kept local to avoid depending on other mods)
----------------------------------------------------------------------
function util.vlen2(x, y)
	return math.sqrt(x * x + y * y)
end

----------------------------------------------------------------------
-- Map boundary discovery (probe valid coordinates outward)
----------------------------------------------------------------------
function util.discoverMapBoundary()
	local x, y = 0, 0
	local v = api.type.Vec2f.new(0, 0)
	for i = 0, 50000, 10 do
		v.x = i; v.y = 0
		if not api.engine.terrain.isValidCoordinate(v) then
			x = i - 10
			break
		end
	end
	for i = 0, 50000, 10 do
		v.x = 0; v.y = i
		if not api.engine.terrain.isValidCoordinate(v) then
			y = i - 10
			break
		end
	end
	return x, y
end

----------------------------------------------------------------------
-- Export canvas size from the map boundary.
-- TPF2's heightmap stores 1 pixel per 4x4 metre square, so the resolution
-- is (metres / 4) + 1 px per axis (e.g. a 4096 m map = 1025 px, a 24576 m
-- Megalomaniac map = 6145 px). A 256 m terrain tile is therefore 64 px.
-- The world origin is centred, so the full span is 2 * the probed boundary.
-- We snap the span to whole tiles and reproduce that resolution so the
-- export matches the map's real proportions and detail level.
----------------------------------------------------------------------
function util.tileCanvasSize(boundaryX, boundaryY)
	local TILE_METRES = 256
	local PX_PER_TILE = TILE_METRES / 4 -- 64 px per tile (4 m per pixel)
	local function axis(boundary)
		local tiles = math.floor((2 * boundary) / TILE_METRES + 0.5)
		if tiles < 1 then tiles = 1 end
		return tiles * PX_PER_TILE + 1
	end
	return axis(boundaryX), axis(boundaryY)
end

----------------------------------------------------------------------
-- Coordinate transform factory.
-- World: metres, origin at centre, +y is up (north).
-- Canvas: pixels, origin top-left, +y is down -> we flip y.
-- A uniform scale is used on both axes so the map is not distorted;
-- the drawing is centred within the (possibly non-square) canvas.
----------------------------------------------------------------------
function util.makeTransform(boundaryX, boundaryY, canvasW, canvasH)
	canvasH = canvasH or canvasW
	local spanX = 2 * boundaryX
	local spanY = 2 * boundaryY
	local scale = math.min(canvasW / spanX, canvasH / spanY)
	-- centre offsets so the map sits in the middle of the canvas
	local offX = (canvasW - spanX * scale) / 2
	local offY = (canvasH - spanY * scale) / 2

	local t = {}
	t.scale = scale
	t.canvasW = canvasW
	t.canvasH = canvasH
	t.canvas = canvasW -- backwards-compat alias
	-- Stroke-width scale: strokes are authored as fixed pixels, but canvas size
	-- grows with map size (4 m/px), so on big maps fixed strokes look thinner when
	-- fit-to-window. This factor keeps the apparent thickness consistent. Tuned so
	-- 1.0 at the largest (Megalomaniac, ~6145 px) map; smaller maps scale down.
	-- Callers may override via util.setStrokeScale before drawing.
	t.widthScale = 1
	t.strokeRef = 6145
	t.strokeMin = 0.35
	t.strokeMax = 1
	function t.computeWidthScale()
		local s = canvasW / t.strokeRef
		if s < t.strokeMin then s = t.strokeMin end
		if s > t.strokeMax then s = t.strokeMax end
		t.widthScale = s
		return s
	end
	t.computeWidthScale()
	-- Scale a fixed pixel value by the current width scale (rounded for tidy output).
	function t.sw(px)
		return px * t.widthScale
	end
	-- returns canvas x
	function t.x(wx)
		return offX + (wx + boundaryX) * scale
	end

	-- returns canvas y (flipped)
	function t.y(wy)
		return offY + (boundaryY - wy) * scale
	end

	return t
end

----------------------------------------------------------------------
-- Number formatting: trim to 2 decimals, drop trailing zeros, keep file small
----------------------------------------------------------------------
function util.num(n)
	if n ~= n then return "0" end -- NaN guard
	local s = string.format("%.2f", n)
	s = s:gsub("%.?0+$", "")
	if s == "" or s == "-0" then s = "0" end
	return s
end

----------------------------------------------------------------------
-- XML / SVG text escaping for labels
----------------------------------------------------------------------
function util.esc(s)
	if not s then return "" end
	s = tostring(s)
	s = s:gsub("&", "&amp;")
	s = s:gsub("<", "&lt;")
	s = s:gsub(">", "&gt;")
	s = s:gsub('"', "&quot;")
	s = s:gsub("'", "&apos;")
	return s
end

----------------------------------------------------------------------
-- Hermite (TPF2 edge) -> cubic bezier SVG path segment.
-- p0,p1 = node positions, m0,m1 = full length tangents (derivatives).
-- Bezier control points: c1 = p0 + m0/3 , c2 = p1 - m1/3.
-- The transform t maps world coords to canvas coords.
-- Returns a string starting with "M" (caller may concatenate, or strip M for joins).
----------------------------------------------------------------------
function util.edgeToBezier(t, p0, m0, p1, m1)
	local c1x = p0.x + m0.x / 3
	local c1y = p0.y + m0.y / 3
	local c2x = p1.x - m1.x / 3
	local c2y = p1.y - m1.y / 3

	local n = util.num
	return "M" .. n(t.x(p0.x)) .. "," .. n(t.y(p0.y)) ..
		"C" .. n(t.x(c1x)) .. "," .. n(t.y(c1y)) ..
		" " .. n(t.x(c2x)) .. "," .. n(t.y(c2y)) ..
		" " .. n(t.x(p1.x)) .. "," .. n(t.y(p1.y))
end

----------------------------------------------------------------------
-- Canvas-space cubic bezier control points for an edge (same maths as
-- edgeToBezier, but returns the four points so callers can build offset
-- curves, ticks, midpoints, etc).
----------------------------------------------------------------------
function util.edgeBezierPoints(t, p0, m0, p1, m1)
	local c1x = p0.x + m0.x / 3
	local c1y = p0.y + m0.y / 3
	local c2x = p1.x - m1.x / 3
	local c2y = p1.y - m1.y / 3
	return
		{ x = t.x(p0.x), y = t.y(p0.y) },
		{ x = t.x(c1x), y = t.y(c1y) },
		{ x = t.x(c2x), y = t.y(c2y) },
		{ x = t.x(p1.x), y = t.y(p1.y) }
end

local function perpUnit(ax, ay, bx, by, fallx, fally)
	local dx, dy = bx - ax, by - ay
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 1e-6 then dx, dy = fallx, fally; len = math.sqrt(dx * dx + dy * dy) end
	if len < 1e-6 then return 0, 0 end
	-- perpendicular (rotate 90deg), normalised
	return -dy / len, dx / len
end

----------------------------------------------------------------------
-- Offset copy of an edge's bezier, shifted perpendicular by `offset` px in
-- canvas space. Used to draw the two parallel "====" tunnel rails.
----------------------------------------------------------------------
function util.edgeToBezierOffset(t, p0, m0, p1, m1, offset)
	local P0, C1, C2, P1 = util.edgeBezierPoints(t, p0, m0, p1, m1)
	local fx, fy = P1.x - P0.x, P1.y - P0.y
	local n0x, n0y = perpUnit(P0.x, P0.y, C1.x, C1.y, fx, fy) -- normal at start
	local n1x, n1y = perpUnit(C2.x, C2.y, P1.x, P1.y, fx, fy) -- normal at end
	local n = util.num
	return "M" .. n(P0.x + n0x * offset) .. "," .. n(P0.y + n0y * offset) ..
		"C" .. n(C1.x + n0x * offset) .. "," .. n(C1.y + n0y * offset) ..
		" " .. n(C2.x + n1x * offset) .. "," .. n(C2.y + n1y * offset) ..
		" " .. n(P1.x + n1x * offset) .. "," .. n(P1.y + n1y * offset)
end

----------------------------------------------------------------------
-- Two short perpendicular ticks at the ends of an edge (bridge abutments).
-- `half` is the tick half-length in canvas px. Returns an SVG path "d".
----------------------------------------------------------------------
function util.edgeEndTicks(t, p0, m0, p1, m1, half)
	local P0, C1, C2, P1 = util.edgeBezierPoints(t, p0, m0, p1, m1)
	local fx, fy = P1.x - P0.x, P1.y - P0.y
	local n0x, n0y = perpUnit(P0.x, P0.y, C1.x, C1.y, fx, fy)
	local n1x, n1y = perpUnit(C2.x, C2.y, P1.x, P1.y, fx, fy)
	local n = util.num
	return "M" .. n(P0.x - n0x * half) .. "," .. n(P0.y - n0y * half) ..
		"L" .. n(P0.x + n0x * half) .. "," .. n(P0.y + n0y * half) ..
		"M" .. n(P1.x - n1x * half) .. "," .. n(P1.y - n1y * half) ..
		"L" .. n(P1.x + n1x * half) .. "," .. n(P1.y + n1y * half)
end

----------------------------------------------------------------------
-- Colour helpers
----------------------------------------------------------------------
function util.rgb(c)
	return string.format("#%02x%02x%02x",
		math.max(0, math.min(255, math.floor(c[1] + 0.5))),
		math.max(0, math.min(255, math.floor(c[2] + 0.5))),
		math.max(0, math.min(255, math.floor(c[3] + 0.5))))
end

----------------------------------------------------------------------
-- Build an SVG path "d" for a regular polygon centred at (cx, cy).
-- sides = number of vertices, r = circumradius (px), the first vertex
-- points straight up so triangles/pentagons sit upright.
----------------------------------------------------------------------
function util.polygonPath(cx, cy, r, sides)
	local d = ""
	for i = 0, sides - 1 do
		local a = -math.pi / 2 + (2 * math.pi * i) / sides
		local px = cx + r * math.cos(a)
		local py = cy + r * math.sin(a)
		d = d .. ((i == 0) and "M" or "L") .. util.num(px) .. "," .. util.num(py)
	end
	return d .. "Z"
end

----------------------------------------------------------------------
-- Hypsometric (elevation) colour ramp, OpenTopoMap / OSM-terrain style.
-- Input: frac in [0,1] from lowest land to highest land.
-- Returns { r, g, b } interpolated across green -> tan -> brown -> snow.
----------------------------------------------------------------------
local HYPSO_STOPS = {
	{ 0.00, { 168, 205, 162 } }, -- low land, green
	{ 0.12, { 150, 196, 135 } },
	{ 0.28, { 200, 211, 143 } }, -- yellow-green
	{ 0.45, { 230, 222, 154 } }, -- tan
	{ 0.62, { 214, 186, 130 } }, -- light brown
	{ 0.78, { 184, 150, 110 } }, -- brown
	{ 0.90, { 158, 130, 110 } }, -- dark brown
	{ 1.00, { 236, 236, 238 } }, -- snow / rock
}

function util.hypsoColor(frac)
	if frac ~= frac then frac = 0 end
	if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
	for i = 1, #HYPSO_STOPS - 1 do
		local a = HYPSO_STOPS[i]
		local b = HYPSO_STOPS[i + 1]
		if frac >= a[1] and frac <= b[1] then
			local span = b[1] - a[1]
			local tt = span == 0 and 0 or (frac - a[1]) / span
			return {
				a[2][1] + (b[2][1] - a[2][1]) * tt,
				a[2][2] + (b[2][2] - a[2][2]) * tt,
				a[2][3] + (b[2][3] - a[2][3]) * tt,
			}
		end
	end
	local last = HYPSO_STOPS[#HYPSO_STOPS][2]
	return { last[1], last[2], last[3] }
end

----------------------------------------------------------------------
-- Hillshade factor for a cell, given gradients dz/dx and dz/dy (metres/metre).
-- Light from NW (azimuth 315 deg), altitude 45 deg. Returns a multiplier in
-- roughly [0.45, 1.15] used to lighten/darken the hypsometric colour.
----------------------------------------------------------------------
local LIGHT = { -0.5, 0.5, 0.70710678 } -- precomputed unit-ish NW @ 45deg

function util.hillshade(dzdx, dzdy, zFactor)
	zFactor = zFactor or 2.0
	local nx = -dzdx * zFactor
	local ny = -dzdy * zFactor
	local nz = 1.0
	local len = math.sqrt(nx * nx + ny * ny + nz * nz)
	if len == 0 then len = 1 end
	local dot = (nx * LIGHT[1] + ny * LIGHT[2] + nz * LIGHT[3]) / len
	if dot < 0 then dot = 0 end
	-- soften so shadows are not pure black
	return 0.55 + 0.6 * dot
end

----------------------------------------------------------------------
-- Encode a 24-bit BMP image (top-down) as a binary string.
-- getPixel(x, y) must return r, g, b in 0..255 with y=0 at the top.
-- BMP is uncompressed and needs no deflate / bitwise ops, so it is safe
-- to build in the game's LuaJIT sandbox and opens efficiently in editors.
----------------------------------------------------------------------
function util.encodeBMP(width, height, getPixel)
	local schar = string.char
	local floor = math.floor
	local function u16(v)
		return schar(v % 256, floor(v / 256) % 256)
	end
	local function u32(v)
		return schar(v % 256, floor(v / 256) % 256,
			floor(v / 65536) % 256, floor(v / 16777216) % 256)
	end

	local rowBytes = width * 3
	local pad = (4 - (rowBytes % 4)) % 4
	local padStr = pad > 0 and string.rep("\0", pad) or ""
	local dataSize = (rowBytes + pad) * height
	local fileSize = 54 + dataSize

	local out = {}
	-- BITMAPFILEHEADER (14 bytes)
	out[#out + 1] = "BM"
	out[#out + 1] = u32(fileSize)
	out[#out + 1] = u32(0)
	out[#out + 1] = u32(54)
	-- BITMAPINFOHEADER (40 bytes)
	out[#out + 1] = u32(40)
	out[#out + 1] = u32(width)
	out[#out + 1] = u32(4294967296 - height) -- negative height => top-down rows
	out[#out + 1] = u16(1)
	out[#out + 1] = u16(24)
	out[#out + 1] = u32(0)
	out[#out + 1] = u32(dataSize)
	out[#out + 1] = u32(2835)
	out[#out + 1] = u32(2835)
	out[#out + 1] = u32(0)
	out[#out + 1] = u32(0)

	for y = 0, height - 1 do
		local row = {}
		for x = 0, width - 1 do
			local r, g, b = getPixel(x, y)
			r = r < 0 and 0 or (r > 255 and 255 or r)
			g = g < 0 and 0 or (g > 255 and 255 or g)
			b = b < 0 and 0 or (b > 255 and 255 or b)
			row[x + 1] = schar(floor(b), floor(g), floor(r)) -- BMP stores BGR
		end
		out[#out + 1] = table.concat(row)
		if padStr ~= "" then out[#out + 1] = padStr end
	end
	return table.concat(out)
end

----------------------------------------------------------------------
-- Base64 encode a binary string (standard alphabet, padded).
----------------------------------------------------------------------
local B64 = {}
do
	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, 64 do B64[i - 1] = alphabet:sub(i, i) end
end

function util.base64(data)
	local out = {}
	local oi = 0
	local n = #data
	local byte = string.byte
	local floor = math.floor
	local i = 1
	while i <= n do
		local b1 = byte(data, i)
		local b2 = (i + 1 <= n) and byte(data, i + 1) or nil
		local b3 = (i + 2 <= n) and byte(data, i + 2) or nil

		local n1 = floor(b1 / 4)
		local n2 = (b1 % 4) * 16 + (b2 and floor(b2 / 16) or 0)
		local c1 = B64[n1]
		local c2 = B64[n2]
		local c3, c4
		if b2 then
			local n3 = (b2 % 16) * 4 + (b3 and floor(b3 / 64) or 0)
			c3 = B64[n3]
		else
			c3 = "="
		end
		if b3 then
			c4 = B64[b3 % 64]
		else
			c4 = "="
		end
		oi = oi + 1
		out[oi] = c1 .. c2 .. c3 .. c4
		i = i + 3
	end
	return table.concat(out)
end

return util


