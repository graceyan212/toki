/* ============================================================================
   Toki — the landing page IS a typing test.
   The visitor types one short paragraph; every sentence switches to a different
   voice. The copy gets read because typing it is the only way through, and the
   product demonstrates itself instead of being described.
   ========================================================================== */
import { PROFILES, Player, panFor, sizeFor, codeFor } from './synth.js';

/* One sentence per switch. Kept short — a typing test punishes long lines. */
const SCRIPT = [
  /* Ordered dull -> bright, so the paragraph climbs from the softest linear to
     the sharpest clicky.

     Deliberately SHORT. The first draft ran 294 characters, which at a plausible
     typing speed is a ~38 second autoplay — far longer than anyone will watch,
     and the whole point is to reach all seven switches. Every sentence still
     earns its place: one is the greeting, one is the hook, the rest answer the
     objections a buyer actually has.

     Copy sells the EXPERIENCE, not the mechanism. "Synthesised, not recorded" was
     the old hook, pointed at the wrong person: to an enthusiast "emulation"
     sounds like a downgrade, and everyone else does not care. The mechanism is in
     the FAQ. */
  { slug: 'cocoa',     text: "Hi! We're Toki." },
  { slug: 'butter',    text: "Your Mac, but it sounds good." },
  { slug: 'graphite',  text: "Hear that? New switch." },
  { slug: 'vermilion', text: "Seven to choose from." },
  { slug: 'amethyst',  text: "No two presses alike." },
  { slug: 'kraft',     text: "Nothing you type is saved." },
  { slug: 'porcelain', text: "Four ninety-nine, once." },
];

const player = new Player();
const $ = (s) => document.querySelector(s);

/* --- build the character stream -------------------------------------------- */
let chars = [];          // {ch, el, sentence, typed:null|'ok'|'bad'}
let pos = 0;
let started = 0;
let correct = 0, typedTotal = 0, sounds = 0;
let audioReady = false;

function build() {
  const holder = $('#text');
  holder.innerHTML = '';
  chars = [];
  SCRIPT.forEach((s, si) => {
    const span = document.createElement('span');
    span.className = 'sentence';
    span.dataset.i = si;
    [...s.text].forEach((ch) => {
      const c = document.createElement('span');
      c.className = 'ch';
      c.textContent = ch;
      span.appendChild(c);
      chars.push({ ch, el: c, sentence: si, typed: null });
    });
    if (si < SCRIPT.length - 1) {
      const sp = document.createElement('span');
      sp.className = 'ch';
      sp.textContent = ' ';
      span.appendChild(sp);
      chars.push({ ch: ' ', el: sp, sentence: si, typed: null });
    }
    holder.appendChild(span);
  });
  pos = 0; started = 0; correct = 0; typedTotal = 0; sounds = 0;
  paint();
  setSwitch(0);
  $('#result').hidden = true;
  $('#hint').textContent = 'Every sentence is a different switch.';
}

function paint() {
  chars.forEach((c, i) => {
    c.el.className = 'ch'
      + (c.typed === 'ok' ? ' ok' : '')
      + (c.typed === 'bad' ? ' bad' : '')
      + (i === pos ? ' at' : '');
  });
}

/* NO AUTO-SCROLL, deliberately.

   Two attempts at "keep the caret visible" both fought the reader. The first
   called scrollIntoView on every character, so autoplay dragged the page back
   ten times a second. The second only scrolled when the caret left a padding
   zone — which still yanked whenever the test was PARTLY scrolled off, and with
   `scroll-behavior: smooth` each correction was an animation competing with the
   next one.

   It turns out none of it was needed: the paragraph is 158 characters and fits
   unscrolled at every viewport measured, 390x667 and 740x360 landscape included.
   A scroll that corrects nothing is strictly worse than no scroll. */

/* --- the switch of the moment ---------------------------------------------- */
let currentSentence = -1;
function setSwitch(si) {
  if (si === currentSentence) return;
  currentSentence = si;
  const p = PROFILES.find((x) => x.slug === SCRIPT[si].slug) || PROFILES[0];
  $('#sw-name').textContent = p.name;
  $('#sw-fam').textContent = p.family;
  $('#st-prog').textContent = `${si + 1} / ${SCRIPT.length}`;
  const meta = document.querySelector('.switch-now');
  meta.classList.remove('flash');
  void meta.offsetWidth;                 // restart the animation
  meta.classList.add('flash');
  // dim any sentence that is not the live one
  document.querySelectorAll('.sentence').forEach((el, i) => {
    el.classList.toggle('live', i === si);
  });
}

/* --- stats ------------------------------------------------------------------ */
function stats() {
  const mins = started ? (performance.now() - started) / 60000 : 0;
  const wpm = mins > 0 ? Math.round((correct / 5) / mins) : 0;
  const acc = typedTotal ? Math.round((correct / typedTotal) * 100) : 100;
  $('#st-wpm').textContent = wpm;
  $('#st-acc').textContent = acc;
  return { wpm, acc };
}

/* --- audio ------------------------------------------------------------------ */
player.onProgress = (n, total) => {
  if (n < total) $('#hint').textContent = `warming up voice ${n} of ${total}…`;
  else if (pos === 0) $('#hint').textContent = 'All seven ready. Start typing.';
};

async function boot() {
  if (audioReady) return true;
  audioReady = await player.ensure();
  return audioReady;
}

function sound(ch, phase = 'press') {
  if (!audioReady) return;
  const slug = SCRIPT[chars[Math.min(pos, chars.length - 1)]?.sentence ?? 0].slug;
  player.play(slug, codeFor(ch), { phase, size: sizeFor(ch), pan: panFor(ch) });
  if (phase === 'press') sounds++;
}

/* --- input ------------------------------------------------------------------ */

/* One accepted character. Both real typing and the autoplay demo go through
   here, so the two can never drift apart — the demo is the same state machine
   driven by a timer instead of a finger. */
function commit(ch) {
  if (pos >= chars.length) return;
  if (!started) started = performance.now();

  const hit = ch === chars[pos].ch;
  chars[pos].typed = hit ? 'ok' : 'bad';
  typedTotal++;
  if (hit) correct++;

  sound(ch);
  pos++;
  if (pos < chars.length) setSwitch(chars[pos].sentence);
  paint();
  stats();
  if (pos >= chars.length) finish();
}

function onKey(e) {
  if (e.metaKey || e.ctrlKey || e.altKey) return;      // leave shortcuts alone

  if (e.key === 'Backspace') {
    e.preventDefault();
    stopAuto();                                        // typing takes over
    if (pos > 0) {
      pos--;
      chars[pos].typed = null;
      setSwitch(chars[pos].sentence);
      paint();
      sound('\b');
    }
    return;
  }

  if (e.key.length !== 1) return;                      // ignore Shift, arrows, F-keys
  e.preventDefault();
  if (pos >= chars.length) return;

  stopAuto();   // a real keystroke always wins over the demo

  // Never await audio before recording the keystroke. Doing so put a ~300 ms
  // render between the key and the character appearing, which reads as a
  // dropped keypress — the one thing a typing test cannot do.
  if (!audioReady) boot();
  commit(e.key);
}

/* --- autoplay ---------------------------------------------------------------
   For everyone who will not type: press play and it types itself. This is the
   primary path on a phone, where typing into a landing page is unpleasant.

   The rhythm matters more than the speed. A fixed interval sounds like a machine
   gun and undersells the product, so each keystroke gets jitter, punctuation gets
   a beat after it, and sentence ends get a longer one — which also gives the
   switch change somewhere to land audibly.
   -------------------------------------------------------------------------- */
let autoTimer = null;

function isAuto() { return autoTimer !== null; }

function gapAfter(ch) {
  let d = 88 * (0.60 + Math.random() * 0.80);       // brisk but human, unevenly
  if ('.?!'.includes(ch)) d += 240;                 // end of a thought
  else if (',;:'.includes(ch)) d += 130;
  else if (ch === ' ') d += 24;
  return d;
}

function autoStep() {
  if (pos >= chars.length) { stopAuto(); return; }
  const ch = chars[pos].ch;
  commit(ch);
  // the release lands a beat after the press, as a finger would
  setTimeout(() => { if (isAuto()) sound(ch, 'release'); }, 62);
  autoTimer = setTimeout(autoStep, gapAfter(ch));
}

function startAuto() {
  if (isAuto()) return;
  if (pos >= chars.length) build();                 // finished? start over
  // Fire-and-forget, never awaited. ctx.resume() does not settle without a
  // trusted gesture, so awaiting it hung startAuto before it drew anything —
  // the demo would silently refuse to run. The animation must not depend on the
  // audio being ready; sound joins in as soon as it is.
  boot();
  setAutoLabel(true);
  $('#hint').textContent = 'Playing. Type at any point to take over.';
  autoTimer = setTimeout(autoStep, 220);
}

function stopAuto() {
  if (!isAuto()) return;
  clearTimeout(autoTimer);
  autoTimer = null;
  setAutoLabel(false);
  if (pos < chars.length) $('#hint').textContent = 'Your turn — keep typing.';
}

function setAutoLabel(playing) {
  const b = $('#auto');
  if (!b) return;
  b.textContent = playing ? 'Stop' : 'Play it for me';
  b.setAttribute('aria-pressed', String(playing));
}

function finish() {
  stopAuto();
  const { wpm, acc } = stats();
  $('#r-wpm').textContent = wpm;
  $('#r-acc').textContent = acc + '%';
  $('#r-keys').textContent = sounds;
  $('#result').hidden = false;
  $('#hint').textContent = 'Done. Every sound you just heard was computed, not played back.';
  // Only pull the reader to the results if they were still watching the test.
  // If they scrolled off to read the FAQ, finishing must not yank them back —
  // same mistake as the caret-following scroll, one function further along.
  const t = $('#test')?.getBoundingClientRect();
  if (t && t.bottom > 0 && t.top < innerHeight) {
    $('#result').scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
}

/* Type anywhere on the page — no need to click into a box first. */
addEventListener('keydown', onKey);
addEventListener('keyup', (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey || e.key.length !== 1) return;
  sound(e.key, 'release');
});

$('#test')?.addEventListener('pointerdown', boot);
$('#auto')?.addEventListener('click', () => (isAuto() ? stopAuto() : startAuto()));
$('#restart')?.addEventListener('click', () => { stopAuto(); build(); boot(); });
$('#again')?.addEventListener('click', () => {
  stopAuto();
  build(); document.getElementById('top').scrollIntoView({ behavior: 'smooth' });
});
$('#skip')?.addEventListener('click', async () => {
  stopAuto();
  await boot();
  chars.forEach((c) => { c.typed = 'ok'; });
  correct = chars.length; typedTotal = chars.length;
  pos = chars.length;
  if (!started) started = performance.now() - 30000;   // a plausible 30s run
  paint();
  finish();
});

/* --- the tuner in the result panel ------------------------------------------ */
const tune = { bright: 0.5, body: 0.5, decay: 0.5 };
let tuneTimer = null;
let tuneSlug = PROFILES[0].slug;

const chipRow = $('#switches');
PROFILES.forEach((p, i) => {
  const b = document.createElement('button');
  b.className = 'chip'; b.type = 'button'; b.textContent = p.name;
  b.setAttribute('aria-pressed', String(i === 0));
  b.addEventListener('click', async () => {
    await boot();
    document.querySelectorAll('#switches .chip').forEach((c) => c.setAttribute('aria-pressed', 'false'));
    b.setAttribute('aria-pressed', 'true');
    tuneSlug = p.slug;
    player.play(tuneSlug, codeFor('t'), {});
  });
  chipRow?.appendChild(b);
});

function wireSlider(id, key, out) {
  const el = $(id); if (!el) return;
  el.addEventListener('input', async () => {
    tune[key] = el.value / 100;
    $(out).textContent = el.value;
    clearTimeout(tuneTimer);
    // Debounced: every change re-renders all seven voices, so doing it on each
    // pixel of a drag would stall the page.
    tuneTimer = setTimeout(async () => {
      if (!audioReady) return;
      await player.setTune({ ...tune });
      player.play(tuneSlug, codeFor('t'), {});
    }, 240);
  });
}
wireSlider('#s-bright', 'bright', '#v-bright');
wireSlider('#s-body', 'body', '#v-body');
wireSlider('#s-decay', 'decay', '#v-decay');

/* free-typing box in the result panel uses the currently selected chip */
$('#demo')?.addEventListener('keydown', async (e) => {
  if (e.key.length !== 1 || e.metaKey || e.ctrlKey) return;
  await boot();
  player.play(tuneSlug, codeFor(e.key), { size: sizeFor(e.key), pan: panFor(e.key) });
});
$('#demo')?.addEventListener('focus', boot);

/* checkout stays inert until there is a build to sell */
$('#buy-btn')?.addEventListener('click', (e) => {
  e.preventDefault();
  const n = $('#prelaunch');
  n.classList.add('pulse');
  n.scrollIntoView({ behavior: 'smooth', block: 'center' });
  setTimeout(() => n.classList.remove('pulse'), 1500);
});

/* header hairline */
addEventListener('scroll', () => {
  $('#head').classList.toggle('scrolled', scrollY > 8);
}, { passive: true });

build();

/* Compute every voice at page load, while the visitor is still reading the
   paragraph. render() is pure maths and needs no AudioContext, so this is
   allowed before any gesture — and it is why the first keystroke is audible
   instead of waiting on a render. */
if (typeof requestIdleCallback === 'function') requestIdleCallback(() => player.precompute());
else setTimeout(() => player.precompute(), 200);
