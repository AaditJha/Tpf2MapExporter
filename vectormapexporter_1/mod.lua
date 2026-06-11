-- Vector Map Exporter
-- Exports high quality vector (SVG) layers of the current game map:
-- roads, rail, stations, towns, industries and terrain contours.
-- Output canvas: 6145 x 6145 px, written to a fixed folder on disk.

-- The production (output cargo) of an industry is only known after its updateFn
-- has run. We hide that data inside the construction params here so the game
-- script can read it later to colour industries by their output cargo.
local function constructionModifier(filename, data)
	if data.type == "INDUSTRY" then
		xpcall(function()
			local params = {}
			params.seed = 0
			params.state = {}
			params.state.groups = {}
			local result = data.updateFn(params)

			local input = {}
			for i, stock in pairs(result.stocks) do
				table.insert(input, stock.cargoType)
			end
			local output = {}
			for cargoType, num in pairs(result.rule.output) do
				table.insert(output, cargoType)
			end
			if #input == 0 then input = { "NONE" } end
			if #output == 0 then output = { "NONE" } end

			local function stringify(tab)
				for i = 1, #tab do tab[i] = tostring(tab[i]) end
				return tab
			end

			table.insert(data.params, {
				key = "inputCargoTypeForVectorExport",
				name = "inputCargoTypeForVectorExport",
				values = stringify(input),
				yearFrom = 9999,
				yearTo = -1
			})
			table.insert(data.params, {
				key = "outputCargoTypeForVectorExport",
				name = "outputCargoTypeForVectorExport",
				values = stringify(output),
				yearFrom = 9999,
				yearTo = -1
			})
			for i = 1, #data.params do
				assert(#data.params[i].values > 0, " values missing for " .. data.params[i].key)
			end
		end,
		function(x)
			print("Vector Map Exporter: error discovering production data for ", filename)
			print(x)
		end)
	end
	return data
end

function data()
	return {
		info = {
			minorVersion = 0,
			severityAdd = 'NONE',
			severityRemove = 'NONE',
			name = _('Cartograph - Vector Map Exporter'),
			description = _([[
Exports a high quality, self-contained vector (SVG) map of your current game.

Unlike an in-game minimap, this writes a single resolution independent SVG file
to disk that you can open in Inkscape / Illustrator / a browser. Every feature
is on its own toggleable layer:
 - terrain as a shaded-relief raster with optional contour lines and a coastline
 - roads, coloured by class and sized by carriageway width
 - rail tracks in a crosstie style
 - bridges and tunnels distinguished on both roads and rail
 - stations and stops (rail / road / water / air, passenger vs. cargo)
 - depots, towns (with name labels) and industries (with name labels)
 - an always-on legend listing only the feature types actually drawn

Network curves are exported as true bezier paths using the in-game track
tangents, so they stay smooth at any zoom. The export resolution adapts to the
map size, so maps export at their true aspect ratio.

Open the exporter from the button in the top toolbar, choose your layers and export.
]]),
			tags = { 'Script Mod', 'Map' },
			authors = {
				{ name = 'aadit', role = 'CREATOR' }
			}
		},
		runFn = function(settings, modParams)
			addModifier("loadConstruction", constructionModifier)
		end,
	}
end
