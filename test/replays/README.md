# Replays

Recorded touch scenarios for `scripts\movie.ps1`. JSON arrays of
`{"f": physics_frame, "t": "touch"|"drag", "i": index, "x": px, "y": px, "p": pressed, "rx": dx, "ry": dy}`
in **viewport** coordinates.

## The coordinate space is the PROJECT's viewport, not movie.ps1's -Resolution

Measured on Stillwater, because getting it wrong is expensive in a specific way: the taps
miss, the run films perfectly anyway, and it reads as a broken game rather than a broken
coordinate.

**Movie Maker mode ignores `--resolution`.** It renders at the project's viewport size —
the log says "recording movie in 1080x1920 @ 60 FPS" — and with the standard
`stretch/aspect="expand"`, `get_visible_rect()` inside the run reports **1080x2338**: the
project width, with the height pulled out to the phone's shape. `movie.ps1 -Resolution`
sizes the window and changes nothing about the frames. ffmpeg downscales afterwards, which
is why the contact sheet still looks like a phone.

So write replay coordinates against **1080 x (1080 * phone aspect)**, about 1080x2338.

To find a control's real rect, print `get_global_rect()` from inside the game's tick on one
frame and film three seconds. A headless run cannot answer it: its viewport is 100x100, and
every anchored control reports nonsense against it.

## Recording and filming

Record one: `godot --path . -- record=test/replays/<name>.json touch`, play with the mouse,
close the window. Every game keeps at least `idle` (no input), `first-minute`, `boundary`,
`fail` and `shop`. `idle.json` is an empty array: film it with `movie.ps1 -Seconds 10 -Name
idle` and no `-Replay`.

Frames are full-resolution PNGs, so sixteen seconds is about 960 files and 2.4 GB, and the
ffmpeg pass afterwards is minutes rather than seconds. Film the shortest run that shows the
thing.
