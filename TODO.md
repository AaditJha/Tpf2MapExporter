# TODO — Vector Map Exporter

- [x] Bridges and tunnels on networks
- [ ] Optional route highlighter
- [x] Road/rail hierarchy styling
- [x] Legend layer (always-on bottom band; scales to canvas width; lists only drawn types)
- [x] Configurable export path (defaults to the mod's `map_exports/`; set
      `CUSTOM_OUTPUT_FOLDER` to an absolute path to override)
- [x] Scale stroke widths to canvas/map size (strokes are fixed pixels, so relative
      thickness changes across map sizes; multiply by `canvasW/6145` or `t.scale`)
- [x] Change toolbar menu icon (custom `res/textures/button/medium/vector_map_export@2x.tga`)
- [ ] Modularize the code (split the monolithic `vector_map_exporter.lua` into
      focused modules, e.g. config/styling, layer emitters, export driver, GUI)
- [x] Revisit the water layer (replaced water polygons with a terrain sea-level coastline contour)
- [ ] (Optional) Icon refurbishment — source cleaner glyphs from https://www.svgrepo.com/
      for the station/depot/town/industry markers and the toolbar button
- [ ] Publish the mod to the Steam Workshop
- [ ] Create a map viewer utility (standalone tool to browse/inspect the exported SVG maps)
- [x] Auto-detect the ocean/water level (it is constant per map) instead of assuming
      sea level = 0, and drive the coastline + below-water shading from it
