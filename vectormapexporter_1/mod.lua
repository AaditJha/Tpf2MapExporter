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
			minorVersion = 1,
			severityAdd = 'NONE',
			severityRemove = 'NONE',
			name = _('Cartograph - Vector Map Exporter'),
			description = _([[
Export a beautiful, high quality map of your game as a single SVG file.

Open it in any browser, Inkscape or Illustrator and zoom in as far as you like — it stays razor sharp at any size, perfect for printing or sharing.

What's on the map:
 - Shaded terrain with contour lines and coastlines
 - Roads, coloured by type
 - Railways, bridges and tunnels
 - Stations and stops (passenger and cargo)
 - Depots, towns and industries, with names
 - A legend that lists everything shown

Each feature sits on its own layer, so you can show or hide whatever you want.

How to use it: click the button in the top toolbar, pick the layers you want, and hit Export.

Source code: https://github.com/AaditJha/Tpf2MapExporter
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
