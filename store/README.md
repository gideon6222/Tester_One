# The store folder

Everything a store listing needs, in the layout the studio's pipeline uploads from
(`C:\dev\gamedev-notes\PLAY.md`). The dashboard's Store tab reads this folder to say
whether the game is ready, and its Sync listing button sends it to Google Play through
`scripts\play\play.py listing`. The layout is fastlane supply's, so any tool that speaks
that layout can use it too.

```
store/
  store.json                       which game states the screenshots are, and the feature graphic recipe
  listing/
    en-US/                         one folder per Play locale; en-US is the only one until a game earns more
      title.txt                    30 characters at most
      short_description.txt        80 characters at most
      full_description.txt         4000 characters at most, in his voice
      images/                      built by scripts\store.ps1, committed so the sync is from the repo
        icon.png                   512x512 PNG with alpha, no rounded corners (Play adds them)
        featureGraphic.png         1024x500, no transparency
        phoneScreenshots/          2 to 8 PNGs, each side 320 to 3840 px, aspect no wider than 2:1
  release-notes/
    en-US/
      default.txt                  500 characters at most; used when a version has no file of its own
      <versionCode>.txt            notes for one upload, in the player's words (optional)
```

`scripts\store.ps1` renders the screenshots and the feature graphic from the real game
and the icon from `icon.svg` (or `assets\icon\store.png` when one exists), then measures
every image against Play's limits and refuses one it would reject. Run it whenever a
screen the listing shows has changed, and commit the result.

The privacy policy is `PRIVACY.md` at the repo root; the pipeline publishes it, and the
Data safety answers are derived from the game's feature flags on the dashboard, so the
three cannot disagree.
