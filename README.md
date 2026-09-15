# Toki

Mechanical keyboard sound for macOS — a menu-bar app that watches for keystrokes
and synthesises a switch sound, plus the landing page that sells it.

**Live site:** https://thock-site.vercel.app/

```
app/     the macOS menu-bar app — 2,479 lines of Swift, 8 files
site/    the landing page — static HTML/CSS/JS, in-browser synth demo
```

## The app

```bash
cd app
./build.sh          # build + self-test + assemble ~/Applications/Toki.app
./package.sh        # build the downloadable DMG
./notarize.sh dist/Toki-1.0.0.dmg
```

Swift Package Manager, no Xcode project, no dependencies. The interesting files:

| File | Lines | |
|---|---|---|
| `Onboarding.swift` | 511 | First-launch flow and the Input Monitoring permission request |
| `MenuBar.swift` | 397 | The menu-bar UI and all persisted settings |
| `main.swift` | 361 | App lifecycle |
| `Engine.swift` | 338 | Voice selection, key-size and key-position logic |
| `KeyTap.swift` | 326 | The event tap — and the filtering that makes it trustworthy |
| `Synth.swift` | 233 | Sound generation and per-hit pitch randomisation |

What it does: 7 switch voices across linear, tactile and clicky families; a
separate quieter/shorter key-*up* sound; randomised pitch per hit so no two
keystrokes are identical; key-size awareness (space and modifiers get more cavity
and less top end); stereo placement by key position, so typing drifts across the
image like it does on a real board.

**It asks for Input Monitoring, not Accessibility.** Accessibility would grant far
more than this app needs. A keyboard-sound app that can read your screen is a
keyboard-sound app nobody should install — `KeyTap.swift` takes the narrower
permission and also ignores remapped mouse buttons and macro keys.

## The site

Static — no framework, no build step. 1,407 lines of CSS and JS total.

The demo is the pitch: `js/synth.js` (413 lines) reproduces the app's synthesis in
Web Audio, so you can hear all 7 voices by typing in the page before downloading
anything. `samples/` holds the seven reference `.wav` files. `variants.html` and
`directions.html` are the design exploration that preceded the final page.

## Note

`site/` currently ships `robots.txt` with `Disallow: /` and an `X-Robots-Tag:
noindex` header — it was deployed as a private preview. Remove both when the
product is meant to be found.
