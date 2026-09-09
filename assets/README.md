# assets/

Imported files live here — HDRIs, textures, fonts, sound. Committed, because a native APK
has no download-size constraint worth designing around: the first game built from this
template added an environment map and a concrete PBR set for **1.6 MB**, and the APK went
from 27.1 to 29.7.

That is a real change from the web stack, where every kilobyte was a download over mobile
data. **Re-read `ASSETS.md` in `gamedev-notes` before importing anything** — the rule at the
top of it was rewritten once the native stack existed, and the exception it names ("an object
that is stationary, close to the camera, and looked at while nothing else is happening")
turns out to describe an entire interior you drive around inside.

Both of these are fetchable unattended, no key needed:

```bash
# Poly Haven: 994 HDRIs, 521 models. One JSON object keyed on the asset id.
curl -s "https://api.polyhaven.com/assets?t=hdris"
curl -s "https://api.polyhaven.com/files/<id>"          # download URLs and exact sizes
curl -sL -o assets/<name>_1k.hdr \
  "https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/1k/<name>_1k.hdr"

# ambientCG: CC0 PBR textures. Take the NORMAL map and leave the colour map -
# that half is style-neutral and keeps the hand-tuned palette intact.
curl -s "https://ambientcg.com/api/v2/full_json?type=Material&q=concrete&limit=20"
curl -sL -o m.zip "https://ambientcg.com/get?file=Concrete034_1K-JPG.zip"
```

Shrink before committing — 512px WebP is usually native size on a phone, and the arithmetic
is worth doing before the download rather than after.

**Audio is still the gap.** Kenney's URLs are not guessable and freesound needs an API key,
both re-checked 2026-09-08. The route that works is generating WAVs offline with a short
Python script and committing them: an impact is a filtered noise burst with a fast attack
over a low thump, rubble is layered short grains, a collapse is a descending rumble.
