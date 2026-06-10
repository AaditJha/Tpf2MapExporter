# Cartograph — TPF2 Vector Map Exporter

A [Transport Fever 2](https://store.steampowered.com/app/1066780/) mod that
exports the current map's layers — terrain, water, roads, rail, stations,
depots, towns and industries — as a single high-quality, self-contained
vector **SVG** file.

Unlike in-game minimap renderers that hit a hard ~5000 line-element engine
limit, this mod serialises geometry directly to SVG, so the output is sharp at
any zoom and captures the whole map at its true resolution.

## Features

- **One self-contained SVG** — all icons, glyphs and the terrain raster are
  embedded inline, so the file needs no external assets.
- **Terrain** rendered as an embedded hypsometric shaded-relief BMP raster
  (base64 data URI), with optional thin vector contour overlay.
- **Networks** — roads (coloured by hierarchy) and rail drawn as true curves
  using engine Hermite tangents converted to cubic béziers.
- **Markers** — stations (rail / road / water / air, passenger vs. cargo),
  depots, towns and industries placed as inline vector glyph badges.
- **Importance-based icon sizing** and a consistent **semantic colour palette**
  (goods = brown, passenger = blue, cities = near-black, depots = slate).
- **Town and industry labels** with a white halo for legibility over terrain.
- **Map-size aware export resolution** — reproduces the game's 4 m/pixel
  heightmap resolution, so non-square maps export at their true aspect ratio.
- **Layer toggles** — a toolbar panel with a checkbox per layer plus an Export
  button.

## Layout

```
vectormapexporter_1/
  mod.lua                                       Script_mod entry; injects a cargo-type
                                                modifier via loadConstruction
  res/
    scripts/
      vector_map_export_util.lua                geometry, transform, SVG and encoding helpers
    config/
      game_script/
        vector_map_exporter.lua                 main script: config, glyphs, per-layer
                                                emitters, export driver, GUI
    textures/ui/icons/*.svg                     source Material Symbols icons (path data is
                                                embedded inline in the main script)
  PROJECT_NOTES.md                              detailed, portable development notes
```

## Installing

Copy the `vectormapexporter_1` folder into your Transport Fever 2 local mods
folder:

```
<path_to_steam>\userdata\<userid>\1066780\local\mods
```

so it ends up at
`<path_to_steam>\userdata\<userid>\1066780\local\mods\vectormapexporter_1`.

Then enable the mod in the game's mod settings for a save, and use the toolbar
button to open the exporter panel.

## Usage

1. Open the exporter panel from the toolbar button.
2. Toggle the layers you want included.
3. Click **Export**.

By default the SVG is written to the mod's own `map_exports/` folder. To export
elsewhere, set `CUSTOM_OUTPUT_FOLDER` to an absolute path near the top of
`vectormapexporter_1/res/config/game_script/vector_map_exporter.lua`:

```lua
-- Leave empty to export into the mod's own "map_exports" folder.
-- Set an absolute path to export elsewhere (the folder must already exist).
local CUSTOM_OUTPUT_FOLDER = "C:/Users/you/Documents/TPF2Export"
```

The chosen folder must already exist — it is not created automatically.

## Configuration

All knobs live near the top of
`vectormapexporter_1/res/config/game_script/vector_map_exporter.lua`.

### Output & terrain

| Constant                | Purpose                                            |
|-------------------------|----------------------------------------------------|
| `CANVAS_MAX`            | Safety cap on either canvas axis (px)              |
| `CUSTOM_OUTPUT_FOLDER`  | Absolute export folder; empty = mod's `map_exports/` |
| `TERRAIN_RASTER_SIZE`   | Terrain raster resolution (NxN)                    |
| `TERRAIN_CONTOUR_LINES` | Overlay thin vector contour lines                  |
| `CONTOUR_GRID`          | Sampling grid for contour lines                    |
| `CONTOUR_LEVELS`        | Number of elevation contour lines                  |
| `TERRAIN_Z_FACTOR`      | Vertical exaggeration for hillshading              |
| `YIELD_EVERY`           | Operations between export-step yields              |

### Coastline

| Constant            | Purpose                                                |
|---------------------|--------------------------------------------------------|
| `TERRAIN_COASTLINE` | Draw the sea-level contour on the terrain layer        |
| `COASTLINE_COLOUR`  | Coastline stroke colour                                |
| `COASTLINE_WIDTH`   | Coastline stroke width (px, stroke-scaled)             |

### Roads & stroke scaling

| Constant                  | Purpose                                          |
|---------------------------|--------------------------------------------------|
| `roadColours`             | Per-category road colours (highway/country/…)    |
| `ROAD_WIDTH_PX_PER_M`     | Stroke px per metre of carriageway width         |
| `ROAD_MIN_WIDTH` / `ROAD_MAX_WIDTH` | Road stroke width clamp (px)           |
| `ROAD_DEFAULT_WIDTH_M`    | Fallback width when a type omits `streetWidth`   |
| `ROAD_CASING`             | Draw a casing outline under road fills           |
| `ROAD_CASING_THEME`       | Casing colour: `"light"` or `"dark"`             |
| `ROAD_CASING_PX`          | Extra casing width per side (px)                  |
| `STROKE_SCALE`            | Scale all strokes to canvas size                 |
| `STROKE_SCALE_REFERENCE`  | Canvas px where widths are authored (scale = 1)  |
| `STROKE_SCALE_MIN` / `STROKE_SCALE_MAX` | Stroke scale clamp                 |

### Rail, bridges & tunnels

| Constant                     | Purpose                                       |
|------------------------------|-----------------------------------------------|
| `RAIL_BASE_COLOUR`           | Solid light base line                         |
| `RAIL_DASH_COLOUR`           | Dark grey crossties (dashes)                  |
| `RAIL_WIDTH` / `RAIL_DASH` / `RAIL_GAP` | Track width and tie dash/gap (px)  |
| `BRIDGE_TUNNEL`              | Distinguish bridge / tunnel segments          |
| `BRIDGE_CASING_COLOUR` / `BRIDGE_CASING_PX` | Bridge casing colour and width |
| `BRIDGE_TICKS` / `BRIDGE_TICK_EXTRA` / `BRIDGE_TICK_WIDTH` | Bridge-end ticks |
| `TUNNEL_DASH` / `TUNNEL_GAP` | Tunnel dash and gap length (px)               |
| `TUNNEL_PARALLEL` / `TUNNEL_LINE_WIDTH` | Twin parallel tunnel lines         |

### Legend & markers

| Constant                   | Purpose                                         |
|----------------------------|-------------------------------------------------|
| `LEGEND_BASE_WIDTH`        | Legend design width (scaled to canvas width)    |
| `LEGEND_PAD` / `LEGEND_ROW_H` | Legend padding and row height (design units) |
| `LEGEND_FONT` / `LEGEND_HEADER_FONT` | Legend label and header font sizes    |
| `LEGEND_SWATCH`            | Network swatch line length                      |
| `LEGEND_BADGE_SCALE`       | Enlargement of marker badges in the legend      |
| `LEGEND_BG`                | Legend band background fill                      |
| `ICON_BASE_RADIUS`         | Badge radius before scaling                     |
| `*_ICON_SCALE` / `ROAD_STOP_SCALE` | Per-marker importance size tiers        |
| `COLOUR_*`                 | Semantic palette (goods/passenger/city/depot)   |

## License

Released under the [MIT License](LICENSE) — free to use, modify, share and
redistribute.

## Reference

Inspired by the **Minimap** mod (workshop id `3256290611`) by okeating, which
renders to the in-game UI via `api.gui.comp.LineRenderView`. This exporter
deliberately avoids that path's element limit by serialising to SVG instead.
