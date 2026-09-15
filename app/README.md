# Toki

Mechanical keyboard sound for macOS. A menu-bar app that watches for keystrokes and
plays a switch sound.

```bash
./build.sh            # build + self-test + assemble ~/Applications/Toki.app
open ~/Applications/Toki.app
./package.sh          # build the downloadable DMG
./notarize.sh dist/Toki-1.0.0.dmg
```

On first launch Toki opens a setup window and asks for **Input Monitoring**.

## What it does

- 7 switch voices across three families — linear, tactile, clicky
- separate, quieter/brighter/shorter **key-up** sound
- **randomised pitch** per hit, so no two keystrokes are identical
- **key-size aware**: space and the modifiers get more cavity, more level, less top end
- **stereo by key position** — typing drifts across the image like it does on a real board
- ignores **remapped mouse buttons and macro keys** (see below)
- launch at login, key-repeat muting, volume, all persisted

## Input Monitoring, not Accessibility

This is the part worth reading.

A tap that **modifies** events needs Accessibility. A `.listenOnly` tap needs only
**Input Monitoring** (`kTCCServiceListenEvent`). Accessibility can drive other apps,
synthesise clicks and read window contents; Toki does none of that and cannot.

Asking for Accessibility on a listen-only tap therefore requests strictly more power
than the app uses, which quietly contradicts the privacy claim the product rests on.
The narrow permission is not a detail — it is the claim, made checkable. A user can
open Accessibility and see that Toki is not in it.

Accessibility is still *accepted* if present, because it also satisfies the tap. It is
never *requested*.

### Two things measured during this change, both counter-intuitive

**1. `CGEvent.tapCreate` succeeds without permission.** For a `.listenOnly` tap it
returns a valid `CFMachPort` that simply never delivers an event. So `start() == true`
means "a port exists", not "the listener works" — and calling it is what *provokes* the
system's "would like to receive keystrokes" prompt. Both facts shape the code: the
onboarding window will not call it before the user has read what is about to be asked,
and nothing anywhere treats it as proof.

**2. `IOHIDCheckAccess` reports `Denied` for an app that has never asked** — the same
value it reports for a user who actively refused. Trusting it greeted a brand-new user
with "permission declined" for a prompt they were never shown. Whether the app has ever
asked is now tracked by the app itself, in `UserDefaults`.

Both belong to one family of bug: **a proxy for the thing, mistaken for the thing.**

## The setup window

`Onboarding.swift`. It exists because the app is `LSUIElement` — no dock icon, no
window — which is right once it works and disastrous before it does. Without permission
the app is completely silent, and a silent sound app is indistinguishable from a broken
one, a failed download, or a muted Mac.

Its one rule: **finish on an observed keystroke, never on a permission check.** The
last step is not a checkmark beside a boolean, it is the user typing and a counter
moving. That matters because TCC-says-granted and events-actually-arrive disagree in
two real cases — a grant that landed after the process started, and a grant that does
not cover the tap's level — and both present as "permission looks fine and the app
makes no sound". If the counter never moves, the window has caught the exact failure
that would otherwise have become a refund request.

States are **derived from the world on every poll**, never advanced by hand, so
revoking the grant while the window is open is noticed rather than papered over.

One more measured thing: `NSApp.activate(ignoringOtherApps:)` is **not** enough to
front a window from an `LSUIElement` app — it opened behind the editor that had focus.
The app switches to `.regular` activation policy for the duration of setup (gaining a
Dock tile and a Cmd-Tab entry, so the window can also be found again if the user clicks
away) and drops back to `.accessory` when it closes.

## Why a remapped mouse button used to make a sound

A programmable mouse does not send a mouse event when you bind a button to "switch
window" — its driver **posts a synthetic keystroke**. Logi Options+, Karabiner, text
expanders and automation scripts all do this, and no keycode distinguishes them from
typing.

The discriminator is the event's source PID: an event originating in hardware carries
`0`, one posted by a process carries that process's PID. `ignoreSynthetic` (default on)
drops the latter.

`ignoreShortcuts` (default on) is the second line, for drivers that inject low enough
in the HID stack to look like hardware: function keys, Mission Control, Launchpad, and
Tab or arrows held with Command/Control/Fn. It is deliberately **not** a blanket
"ignore Command" — Command-S and Command-C are typed by hand and should still sound.

Both are in the menu.

## The sounds are synthesised, not sampled

There is **no audio file anywhere in this project**. Each voice is built from
parameters:

- a band-passed noise **transient** — the click itself
- a **modal body** of three *inharmonic* resonances (ratios 1 : 2.71 : 5.18). A keyboard
  case is a box, not a string, so its modes are not a harmonic series; integer ratios
  read as a pitched "boing" instead of a thock
- a very short, very high **edge snap**

Everything is rendered at launch into PCM buffers, so a keystroke costs one buffer
schedule — no filtering or allocation between key and sound.

One thing that had to be corrected during the build: the body started as an
*oscillator*, which was wrong. An oscillator concentrates all its power at a single
frequency while the noise spreads across a band, so matching them by gain left the body
inaudible next to the transient. Exciting band-passed noise for the body too puts both
voices on the same footing.

`Profiles.swift` is the whole sound design surface — one struct per switch.

**Slugs are frozen.** The synthesis seed is `stableHash(slug)`, so renaming a slug
changes the sound. The `name` and `family` fields are display-only and safe to edit.

### The switch names are real, and deliberately so

Cherry MX Black / Brown / Blue, Gateron Milky Yellow, NovelKeys Cream, Gazzew Boba U4T,
Kailh Box Jade — grouped in the menu by **type** (Linear, Tactile, Clicky), which is
what someone actually chooses by.

The names stay because they *are* the product's vocabulary. "Cherry MX Blue" tells a
buyer exactly what they are about to hear; an invented name like "Kraft" tells them
nothing, and a switch-sound app that will not name switches has thrown away the thing
that makes anyone want it. This was briefly changed to invented names and changed back
— correctly.

They are used **nominatively**: to identify what each voice was modelled against. Naming
the reference is not the exposure; implying you *are* it would be. So every surface that
shows a name also carries the disclaimer — a disabled line at the foot of the Switch
submenu, and an attribution paragraph in the site footer. No logos, no wordmarks, no
suggestion of partnership, and the sounds are original synthesis rather than recordings,
which the FAQ states plainly.

If a manufacturer ever objects, the invented names are still in the codebase as the
slugs (`graphite`, `cocoa`, `kraft`…) and swapping the display strings is a one-line
change per profile that **cannot** affect the audio — the synthesis seed is the slug.
That is the whole reason the slugs are frozen.

## Verification

```bash
./.build/release/toki --self-test    # render every voice, assert it is audible
./.build/release/toki --wav cocoa    # dump a voice to WAV to inspect
./.build/release/toki --diag         # counts only — see below
```

`--self-test` exists because **a synthesiser that outputs silence looks exactly like one
that works** until someone listens. It asserts peak, RMS, finiteness, and that variants
actually differ, then pins a golden peak/RMS/length so a regression is loud.

That golden check earned itself immediately. The seed was derived from
`String.hashValue`, which Swift **seeds randomly per process** — so every launch changed
every switch's sound. The original determinism test missed it by comparing two renders
*within one process*, where the seed is constant: the check was narrower than the claim
it printed. Caught by md5-ing the self-test output across two runs and getting different
digests. Fixed with a stable FNV-1a hash; three runs now produce identical output, and
the golden assertion was provoked (by perturbing the hash constant) and observed to fail.

Independently confirmed outside the app, via a Hann-windowed rFFT in Python: peak 0.72,
attack 0.65–1.4 ms, and the intended dull → bright ordering across profiles. Note the
in-app `centroid` column uses a coarse log-spaced DFT and reads lower than the rFFT
(e.g. 2292 vs 3556 Hz) — the *ordering* agrees, the absolute number is a rough
characterisation, not a measurement.

### What is NOT verified

**The full grant → hear-it path, end to end, by a human.** The setup window has been
observed rendering every state it has, and macOS's own Input Monitoring prompt has been
observed appearing for Toki. What has not been watched is a real grant followed by a
real keystroke producing a real sound in the bundled app.

Note that `--diag` **cannot** stand in for this. Run from a terminal, the binary
inherits the *terminal's* TCC grants, so it reports "granted" and receives keystrokes
regardless of what Toki itself is allowed to do. It measures the wrong code identity.
Three earlier attempts to prove the tap programmatically failed the same way:

1. AppleScript `keystroke` — drives the focused app through accessibility APIs rather
   than posting to the event stream, so a correct tap sees nothing.
2. Posting a `CGEvent` to `.cgSessionEventTap` — inserts the event *at* that point, so a
   tap at the same location cannot observe it.
3. Posting to `.cghidEventTap` from the bare CLI binary — tap eligibility is per-binary,
   and the unbundled executable is not the same code identity as the signed bundle.

Each time the *test* was wrong rather than the app. The remaining check needs a human:
grant Input Monitoring to `Toki.app` and type.

## Distribution status

**Not yet distributable.** `build.sh` signs with whatever certificate it finds and turns
on the Hardened Runtime, but notarisation requires a **Developer ID Application**
certificate, which requires Apple Developer Program membership. Without it the DMG fails
to open on every Mac but the one that built it, reporting "Toki is damaged" — which is
indistinguishable from a corrupt download.

`build.sh` says so explicitly rather than printing a success line, and `package.sh`
refuses to call an unsigned DMG shippable.

## Privacy

The listener is a **listen-only** `CGEventTap`: it observes and never modifies,
consumes or injects events, and it cannot see anything the system does not already route
to the focused app. macOS hides password fields from every app, including this one.

**No keystroke is stored, logged or transmitted.** Each event becomes `(key size, pan)`
and is discarded inside the callback. There is no logging path even in debug builds, and
`--diag` prints **aggregate counts only** — never a keycode, character or timing. That
line matters: a diagnostic that dumped keycodes would make this a keylogger with a
friendly flag name, and "it was only for debugging" is not a property a binary has.

The onboarding counter is fed by a callback that takes no parameters, so it cannot
report what was typed even by accident.

No network code exists in the project.

## Layout

```
Sources/toki/
  Profiles.swift   the 7 switch voices + key-size scalars — the sound design surface
  Synth.swift      biquad band-pass, seeded noise, offline render of one hit
  Engine.swift     AVAudioEngine, buffer cache, player pool, self-test, WAV dump
  KeyTap.swift     listen-only CGEventTap, permissions, source filters, key positions
  Onboarding.swift first-run permission flow
  MenuBar.swift    NSStatusItem + menu, persisted settings, drawn icon
  main.swift       headless modes, then the app
build.sh           build + self-test + bundle + sign (Hardened Runtime)
package.sh         staging + DMG with an Applications shortcut
notarize.sh        submit to Apple + staple
```

Three implementation notes that are easy to get wrong:

**The player pool.** One `AVAudioPlayerNode` *queues* scheduled buffers rather than
overlapping them, so a single node turns fast typing into a stutter. Sixteen nodes
round-robin into a mixer, so hits layer.

**The bundle is not cosmetic.** macOS ties a TCC grant to code identity, so a bare
SwiftPM binary loses permission whenever it is rebuilt at a new path — and then runs
silently with no explanation. `build.sh` bundles and signs to keep the grant stable, and
prints the designated requirement so that claim can be checked rather than believed.

**Never stage a bundle inside this repo.** It lives under `~/Desktop`, which is
iCloud-synced, and the sync daemon re-attaches extended attributes faster than `codesign`
can clear them — producing "resource fork, Finder information, or similar detritus not
allowed". `build.sh` installs to `~/Applications`; `package.sh` stages in `/tmp`.

## Launch at login

`SMAppService` (macOS 13+), toggled from the menu. This replaced a LaunchAgent plist
installed by a shell script: the plist hard-coded an absolute path, so moving Toki —
including the drag from the DMG into Applications that *every* user performs — left a
login item pointing at nothing, failing silently every boot.
