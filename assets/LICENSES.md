# LICENSES.md - every asset in this repo that we did not write

One line per file that reaches `assets\`, including everything under
`assets\generated\` and `assets\library\`. `doctor.ps1` FAILs this repo for a
GLB with no line here, because an asset with no recorded licence is an asset that cannot
ship.

Add the line in the same commit as the file. A generated asset's line comes straight off
its `<name>.json` sidecar.

| File | Source | Licence | URL | Date | What was changed |
|---|---|---|---|---|---|
| | | | | | |

## How to fill a line

- **Source** - `asset-forge` for anything the Smith made, otherwise the site it came
  from: Kenney, Quaternius, Poly Haven, ambientCG, Sketchfab, Mixamo.
- **Licence** - CC0, MIT, CC BY, or the exact name. **CC BY is only allowed when this
  game already has an attribution screen** and the credit is on it.
- **URL** - where a person could fetch it again. For a generated asset, the generator:
  `asset-forge/generators/<type>.py`.
- **What was changed** - recoloured to the palette, decimated to a budget, joined with
  another piece, nothing. For a rung 3 asset name the Space and the model as well, and
  check the text-to-image model's licence before shipping.
