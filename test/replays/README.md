# Replays

Recorded touch scenarios for `scripts\movie.ps1`. JSON arrays of
`{"f": physics_frame, "t": "touch"|"drag", "i": index, "x": px, "y": px, "p": pressed, "rx": dx, "ry": dy}`
in viewport coordinates at the 460x996 test resolution.

Record one: `godot --path . --resolution 460x996 -- record=test/replays/<name>.json touch`
then play with the mouse and close the window. Every game keeps at least `idle` (no input),
`first-minute`, `boundary`, `fail` and `shop`. `idle.json` here is an empty array: film it
with `movie.ps1 -Seconds 10 -Name idle` and no `-Replay`.
