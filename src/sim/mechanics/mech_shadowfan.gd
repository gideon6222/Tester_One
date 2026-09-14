class_name MechShadowFan
extends RefCounted

## Hard shadows on a grid: a fan of rays from a lamp, giving a 1D map of how far
## light gets at every angle.
##
## Ported from Coreward's `src/sim/light.ts`, and it is the other half of the
## lighting there. `MechLightField` answers "can light get here at all", softly:
## a cell reached by a longer path is dimmer. What a flood cannot produce is an
## EDGE. Light that turns a corner in a flood arrives from that corner in every
## direction at once, so a passage crossing yours lights up gently along its
## whole length, when what should happen is that the corner throws a shadow into
## it that grows the further away you are.
##
## That is a different question - a question about straight lines from a point -
## and it gets its own solver.
##
## ## The model
##
## Cast `rays` evenly around the lamp. For each, walk the grid until something
## solid stops it, and record how far it got. A point is in shadow if it is
## further from the lamp than the occluder at its own angle. Sharp by
## construction, exact for any geometry, and the wedge behind a corner widens
## with distance for free, because that is what a fan of rays does.
##
## ## The detail that decides whether it looks right
##
## **The recorded distance is to the FAR side of the first wall hit, not the
## near side.** The face of a wall is the surface the lamp is falling on and has
## to stay lit; the shadow starts behind it. Record the near side instead and
## every rock face in the game sits in its own shadow, which reads as the
## lighting being broken rather than as anything being shadowed.
##
## ## Cost
##
## A few hundred rays of grid DDA, and one lookup per pixel on the other side.
## It has to run every frame rather than on cell changes, because the entire
## point is that the shadow moves as the lamp does.

## Coreward uses 512. Enough that the angular gap between rays is under a pixel
## at the far edge of a phone screen; fewer and a distant shadow edge visibly
## steps as the lamp moves.
const RAYS_DEFAULT := 512

var cols: int = 0
var rows: int = 0
var rays: int = RAYS_DEFAULT

## How far a ray may travel before it is treated as unobstructed, in cells.
var max_distance: float = 64.0

var _hits := PackedFloat32Array()


func _init(grid_cols: int = 0, grid_rows: int = 0, ray_count: int = RAYS_DEFAULT) -> void:
	cols = maxi(grid_cols, 0)
	rows = maxi(grid_rows, 0)
	rays = maxi(ray_count, 8)
	_hits.resize(rays)


## Cast the whole fan from a lamp at (lx, ly) in CELL coordinates, which may be
## fractional: the lamp moves continuously and the grid does not.
func cast(solid: PackedByteArray, lx: float, ly: float) -> PackedFloat32Array:
	if cols == 0 or rows == 0 or solid.size() < cols * rows:
		for i in rays:
			_hits[i] = 0.0
		return _hits
	for i in rays:
		var a := TAU * float(i) / float(rays)
		_hits[i] = _ray(solid, lx, ly, cos(a), sin(a))
	return _hits


## How far light gets at a given angle, in cells. Interpolated between the two
## nearest rays, so the answer moves smoothly as the query angle sweeps rather
## than stepping from ray to ray.
func reach_at_angle(angle: float) -> float:
	if rays == 0:
		return 0.0
	var t := wrapf(angle, 0.0, TAU) / TAU * float(rays)
	var i := int(floor(t))
	var f := t - float(i)
	var a := _hits[i % rays]
	var b := _hits[(i + 1) % rays]
	return lerpf(a, b, f)


## Whether a point is in shadow from a lamp at (lx, ly), all in cell
## coordinates.
##
## `bias` is subtracted from the point's distance before comparing, and it is not
## a fudge: without it a surface exactly at the recorded distance flickers
## between lit and shadowed as the lamp moves by a fraction of a cell, which is
## shadow acne and reads as the wall crawling.
func in_shadow(lx: float, ly: float, px: float, py: float, bias: float = 0.05) -> bool:
	var dx := px - lx
	var dy := py - ly
	var d := sqrt(dx * dx + dy * dy)
	if d <= 0.0001:
		return false
	return (d - bias) > reach_at_angle(atan2(dy, dx))


## The fan as it stands, for uploading to a 1D texture.
func hits() -> PackedFloat32Array:
	return _hits


func state() -> Dictionary:
	var shortest := INF
	var longest := 0.0
	var total := 0.0
	for v in _hits:
		shortest = minf(shortest, v)
		longest = maxf(longest, v)
		total += v
	return {
		"rays": rays,
		"cols": cols,
		"rows": rows,
		"shortest": snappedf(shortest if is_finite(shortest) else 0.0, 0.001),
		"longest": snappedf(longest, 0.001),
		"mean": snappedf(total / float(maxi(rays, 1)), 0.001),
	}


# --- internals ------------------------------------------------------------

## Grid DDA along one ray. Returns the distance at which light stops, measured
## to the FAR side of the blocking cell.
func _ray(solid: PackedByteArray, lx: float, ly: float, dx: float, dy: float) -> float:
	var ix := int(floor(lx))
	var iy := int(floor(ly))
	if ix < 0 or ix >= cols or iy < 0 or iy >= rows:
		return 0.0

	var step_x := 1 if dx > 0.0 else -1
	var step_y := 1 if dy > 0.0 else -1
	var adx := absf(dx)
	var ady := absf(dy)
	# Distance along the ray between successive grid lines on each axis.
	var dt_x := (1.0 / adx) if adx > 1e-9 else INF
	var dt_y := (1.0 / ady) if ady > 1e-9 else INF

	# Distance to the first grid line on each axis.
	var next_x := ((float(ix + 1) - lx) / dx) if dx > 1e-9 else (((float(ix) - lx) / dx) if dx < -1e-9 else INF)
	var next_y := ((float(iy + 1) - ly) / dy) if dy > 1e-9 else (((float(iy) - ly) / dy) if dy < -1e-9 else INF)

	var travelled := 0.0
	while travelled < max_distance:
		if solid[iy * cols + ix] != 0:
			# The FAR side of this cell, not the near one. The face is lit; the
			# shadow begins behind it.
			return minf(minf(next_x, next_y), max_distance)
		if next_x < next_y:
			travelled = next_x
			next_x += dt_x
			ix += step_x
		else:
			travelled = next_y
			next_y += dt_y
			iy += step_y
		if ix < 0 or ix >= cols or iy < 0 or iy >= rows:
			return max_distance
	return max_distance
