# STYLE.md - what every asset in this game has to match

Fill this in when the game gets its look, and mirror the palette into
`C:\dev\asset-forge\palettes\<slug>.json` in the same commit. Every rung of the ladder
in `gamedev-notes\ASSETS.md` reads this file: a downloaded asset that cannot be
recoloured to this palette is not a fit, and a generator paints from these slot names
and no others.

**A game with no STYLE.md gets painted from `asset-forge\palettes\default.json`**, which
is a grey studio palette that matches nothing. The forge says so in the sidecar, but
nobody reads a sidecar, so fill this in.

## Palette

Seven slots, always these names. A generator never invents an eighth: when it needs one
more colour the request's `slots` field remaps an existing slot onto a different one.

| Slot | Colour | What it is in this game |
|---|---|---|
| `base` | `#8A8F98` | The main surface of most objects |
| `base_alt` | `#6C7279` | The second surface, for panels and faces that need to read apart from the base |
| `dark` | `#2E3238` | Rails, frames, recesses, anything that reads as a line at distance |
| `light` | `#D6D9DE` | The light surface, for a face that catches the key light |
| `trim` | `#B5892F` | Bolts, flanges, small metal. The colour that says "made" |
| `accent` | `#C4553A` | The one colour that is allowed to be loud. Used sparingly and on purpose |
| `glow` | `#F2C24A` | Anything emissive: a ring, a readout, a filament |

## Triangle budgets, by asset class

A request's `class` picks its budget from this table. They are starting points measured
against the forge's own first two generators (a 0.9 m bolted crate lands at about 2600
triangles with a vent and about 1500 without, a two metre pipe run with brackets at
about 2500) and they are meant to be replaced by a number measured on the phone the
first time this game has a scene full of them.

| Class | Budget | What it covers |
|---|---|---|
| `hero_prop` | 6000 | On screen constantly, or the thing the game is named after |
| `prop` | 2500 | Ordinary objects the player walks past or picks up |
| `modular` | 1500 | A piece meant to be repeated dozens of times: a wall, a pipe, a conveyor segment |
| `environment` | 4000 | Scenery, one instance or a few |
| `character` | 3500 | Rigged, and therefore always rung 0 or 1 |
| `vehicle` | 5000 | |

Every generated asset also ships an LOD at half its budget and a convex hull for
collision. A concave trimesh collider is a bill the phone pays every frame.

## Shading and materials

- **Shading**: flat. Set `smooth_shading: true` in a request only for something that is
  genuinely round.
- **Materials**: one per asset. The palette travels as vertex colour inside the mesh, so
  an imported GLB needs nothing wired up and costs one draw call. In Godot the material
  needs `vertex_color_use_as_albedo` on.
- **Textures**: none by default. If this game needs them, say the size here (512 is
  usually native on a phone) and say which asset classes get them.
- **Outline**: none by default. If this game uses one, say its width and colour here.

## What this game does not do

- No lettering on a model, ever. Stripes, symbols and colour blocks instead.
- No mixed style families. Pick one and say which here, so the asset scout can filter.
