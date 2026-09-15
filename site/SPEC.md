# Toki — Landing Spec

Greenfield (no source capture). Built with `landing-page-architect`.
Precedent drawn from the verified swipe entries: Lemonade, Granola, ElevenLabs.

**Note on method:** the persona walkthrough below was run inline rather than dispatched to
subagents. It is an objection-finding exercise, **not user testing and not evidence** — it
surfaces likely objections in a plausible order. Before this page takes real traffic it should
get a five-second test ("what does it do, who's it for, what's it cost?") with 5+ humans.

---

## 1. The one visitor

Someone who types all day on a laptop keyboard, has felt a good mechanical board, and knows
the difference. Not shopping. They saw a link. They will decide in about eight seconds
whether this is a delightful toy or a gimmick, and their thumb is already near the back button.

**The single question they're really asking:** *"Will this actually sound good, or is it a
looped sample that gets annoying in ten minutes?"*

**Emotion↔logic:** heavily emotional core (this is a pleasure purchase — nobody *needs* it),
with two hard rational gates: it must not be a keylogger, and it must not be irritating.

## 2. Reader profiles

**MAYA — "will I still like this tomorrow?"**
Writer/developer, works in cafés and an open-plan office. Wants the feel of a nice board
without buying one. Fears: it gets old fast; colleagues hear it; lag makes typing feel wrong.
Decisive moment: hearing it and *not* wanting to turn it off.

**SAM — "I own real switches; prove it"**
Keyboard enthusiast. Suspicious by default. Fears: it's one recording on loop; the switch
names are marketing; it sounds like a toy. **Our synthesis story cuts both ways for him** —
"synthesised" can read as *cheaper than a recording* unless we show why it's better.
Decisive moment: hearing two presses of the same key sound alike, and two different keys
sound different.

**CHRIS — "you want to read every keystroke"**
Developer, privacy-literate. Fears exactly one thing: an app that watches all typing.
Will not reach the price if this is unanswered. Decisive moment: a specific, checkable claim
— not a reassuring adjective.

## 3. Persona walkthrough — DERIVE

Walked against a first-draft outline (hero → features → how it works → privacy → price).
Blockers found, in the order they surfaced:

| At | Persona | Reaction | Fix |
|---|---|---|---|
| Hero | ALL | "Describing a sound in words is useless. Let me hear it." | Hero must be **playable**, not a screenshot. This is the whole page. |
| Hero | SAM | "'Synthesised' sounds like a downgrade from real recordings." | Reframe: synthesis is *why* it never repeats and *why* it's tunable. Show, don't argue. |
| After demo | MAYA | "Fine, one click sounds nice. What about 2,000 of them?" | A section that answers durability directly — per-key voices, per-press variation. |
| Features | CHRIS | "I'm not reading features. You want to see my keystrokes." | **Privacy moves ABOVE features and above price.** Chris never reaches a feature list. |
| Price | MAYA | "$4.99 for a toy?" | Price only after the demo has already done the selling. |
| Anywhere | SAM | "Does it work with my actual board?" | Compatibility stated plainly at the ask (Granola's move). |

**Reconciliation:** Sound has to be proved before anything else is read, and Chris's gate has
to clear before the price. Sam won't care about privacy until he believes the sound; Chris
won't reach the sound's payoff without the gate. So: **prove sound → answer privacy → ask.**

## 4. Section order (reconciled)

1. **Hero — the playable board.** H1 names the situation, not the category. Subhead carries
   negative positioning: no recordings. A real keyboard rendered on the page: click a key, or
   just *type*, and it sounds. No download, no account, nothing to install.
   → *ElevenLabs' try-before-signup, but the demo is the actual engine.*
2. **The tuner.** Three or four live controls (brightness / body / decay / snap) that change
   the sound as you type. **This is the section a sample-based competitor physically cannot
   build.** Let the star shine.
3. **"It doesn't get old."** Maya's question, answered with mechanism: every key has its own
   voice, every press varies. Visualised — same key twice looks alike, different keys don't.
4. **Privacy, as a first-class section.** Chris's gate. Specific and checkable:
   listen-only tap; nothing stored; no network code; the diagnostic prints counts only.
   Register shift — plain, technical, no marketing voice (doctrine #8).
5. **The app itself.** What you actually install: menu-bar, key-up sounds, per-key stereo,
   size-aware keys. Short, because the demo already sold it.
6. **Price + compatibility.** $4.99, one-time. macOS 13+, Apple silicon and Intel, works with
   any keyboard including the built-in one. State the catch at the offer (Granola).
7. **Close.** Belonging, then the low-friction ask.

## 5. Copy direction

- H1 candidate axis: the *situation* (typing all day on a laptop), not the category
  ("keyboard sounds"). Granola's `The [category] for [SITUATION]`.
- Subhead does the negative positioning: **not a single recording**.
- Kill any line Klack could also run. "Satisfying sound" is theirs and is generic anyway.
- Numbers we can actually stand behind, all measured this session: ~2–3 µs per keystroke;
  48 kHz; 16 voices; 0 bytes of audio shipped; 0 network calls.
- Register: sections 1–3 playful; section 4 flat and technical; sections 6–7 plain.

## 6. Visual direction

**To be chosen from rendered options, not from prose** — three hero mockups will be built and
opened side by side. Constraint: must not read as tryklack.com (they own warm cream + a
fuchsia marker highlight). Distinct territory, our own palette and type.

## 7. Honest gates before this ships

- **The purchase CTA must not go live** until there is a notarised, distributable build. The
  current signing identity is "Apple Development," which cannot be notarised for distribution.
- Publish-ready markup (real meta, OG image) but **kept local** until explicitly released.
- Any claim of "no recordings" / "nothing stored" is verifiable in the repo and must stay that
  way — if the app ever ships a sample, this page becomes false.
