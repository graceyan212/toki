/* ============================================================================
   Toki — page behaviour
   Audio cannot start before a user gesture, so everything below is arranged so
   the FIRST click or keypress both unlocks the context and plays the sound the
   visitor was expecting. Nothing autoplays.
   ========================================================================== */
import { PROFILES, Player, render, centroid, panFor, sizeFor, codeFor } from './synth.js';

const player = new Player();
let ready = false;
let building = false;

const $  = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];

/* --- reveal on scroll ------------------------------------------------------ */
const io = new IntersectionObserver((entries) => {
  for (const e of entries) if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
}, { rootMargin: '0px 0px -8% 0px' });
$$('.reveal').forEach((el) => io.observe(el));

/* header hairline once scrolled */
const head = $('#head');
addEventListener('scroll', () => head.classList.toggle('scrolled', scrollY > 8), { passive: true });

/* --- boot the audio engine on first gesture -------------------------------- */
async function boot() {
  if (ready || building) return ready;
  building = true;
  const hint = $('#hero-hint');
  if (hint) hint.textContent = 'warming up the synthesiser…';
  ready = await player.ensure();
  building = false;
  if (hint) {
    hint.textContent = ready
      ? 'Click a key — or just start typing. Nothing to install.'
      : 'Your browser blocked audio. Click anywhere and try again.';
  }
  if (ready) drawScope();
  return ready;
}

/* --- play one key ---------------------------------------------------------- */
function strike(keyName, { lightEl = null, phase = 'press' } = {}) {
  if (!ready) return;
  player.play(codeFor(keyName), {
    phase,
    size: sizeFor(keyName),
    pan: panFor(keyName),
  });
  if (lightEl) {
    lightEl.classList.add('lit');
    setTimeout(() => lightEl.classList.remove('lit'), 110);
  }
}

/* hero keys */
$$('#hero-keys .key').forEach((btn) => {
  const k = btn.dataset.key;
  btn.addEventListener('pointerdown', async () => { await boot(); strike(k, { lightEl: btn }); });
  btn.addEventListener('pointerup',   () => strike(k, { phase: 'release' }));
});

$('#hero-play')?.addEventListener('click', async () => {
  await boot();
  // a short run across the board, so the stereo image is audible
  'toki'.split('').forEach((ch, i) => {
    setTimeout(() => {
      const el = $(`#hero-keys .key[data-key="${ch}"]`);
      strike(ch, { lightEl: el });
    }, i * 105);
  });
});

$('#try-btn')?.addEventListener('click', () => {
  document.getElementById('top').scrollIntoView({ behavior: 'smooth' });
  setTimeout(() => $('#hero-play')?.click(), 500);
});

/* --- type anywhere on the page --------------------------------------------- */
addEventListener('keydown', async (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;         // leave shortcuts alone
  if (e.repeat) return;                                    // match the app: no machine-gun
  await boot();
  const el = $(`#hero-keys .key[data-key="${e.key.toLowerCase()}"]`);
  strike(e.key, { lightEl: el });
});
addEventListener('keyup', (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  strike(e.key, { phase: 'release' });
});

/* --- switch chips ----------------------------------------------------------- */
const chipRow = $('#switches');
PROFILES.forEach((p, i) => {
  const b = document.createElement('button');
  b.className = 'chip';
  b.type = 'button';
  b.textContent = p.name;
  b.setAttribute('aria-pressed', String(i === 0));
  b.addEventListener('click', async () => {
    await boot();
    $$('#switches .chip').forEach((c) => c.setAttribute('aria-pressed', 'false'));
    b.setAttribute('aria-pressed', 'true');
    b.disabled = true;
    await player.setProfile(p);
    b.disabled = false;
    $('#r-name').textContent = p.name;
    drawScope();
    strike('t');
  });
  chipRow.appendChild(b);
});

/* --- tuner sliders ---------------------------------------------------------- */
const tune = { bright: 0.5, body: 0.5, decay: 0.5 };
let rebuildTimer = null;

function wireSlider(id, key, out) {
  const el = $(id);
  el.addEventListener('input', async () => {
    tune[key] = el.value / 100;
    $(out).textContent = el.value;
    drawScope();                                  // instant visual feedback
    clearTimeout(rebuildTimer);
    // Debounced: re-rendering 96 buffers on every pixel of drag would stall the
    // page. The waveform updates live; the audible change lands when you stop.
    rebuildTimer = setTimeout(async () => {
      if (!ready) return;
      await player.setTune({ ...tune });
      strike('t');
    }, 220);
  });
}
wireSlider('#s-bright', 'bright', '#v-bright');
wireSlider('#s-body',   'body',   '#v-body');
wireSlider('#s-decay',  'decay',  '#v-decay');

/* --- oscilloscope ------------------------------------------------------------ */
const cv = $('#scope');
const ctx2d = cv?.getContext('2d');

function drawScope() {
  if (!ctx2d) return;
  const full = render(player.profile, { sr: 48000, phase: 'press', variant: 0, tune });
  // Show only the first 25 ms. The click is ~1.5 ms of excitation inside a buffer
  // that can run 340 ms, so plotting the whole thing draws a flat line with an
  // invisible spike at the very left — technically accurate and useless.
  const wave = full.subarray(0, Math.min(full.length, Math.floor(0.025 * 48000)));
  const W = cv.width, H = cv.height, mid = H / 2;
  ctx2d.clearRect(0, 0, W, H);

  // centre line
  ctx2d.strokeStyle = '#1b2030'; ctx2d.lineWidth = 2;
  ctx2d.beginPath(); ctx2d.moveTo(0, mid); ctx2d.lineTo(W, mid); ctx2d.stroke();

  // envelope, drawn as min/max per column so short transients stay visible
  ctx2d.fillStyle = '#8ce0c8';
  const step = Math.max(1, Math.floor(wave.length / W));
  for (let x = 0; x < W; x++) {
    let lo = 0, hi = 0;
    const start = x * step;
    for (let i = start; i < start + step && i < wave.length; i++) {
      if (wave[i] < lo) lo = wave[i];
      if (wave[i] > hi) hi = wave[i];
    }
    // Slight amplitude emphasis (^0.7) so the decay tail stays visible next to a
    // transient several times its height. A display curve, not a claim about level.
    const em = (v) => Math.sign(v) * Math.pow(Math.abs(v), 0.7);
    const y1 = mid - em(hi) * (mid - 8), y2 = mid - em(lo) * (mid - 8);
    ctx2d.globalAlpha = 0.9 - (x / W) * 0.35;
    ctx2d.fillRect(x, y1, 1, Math.max(1, y2 - y1));
  }
  ctx2d.globalAlpha = 1;

  $('#r-len').textContent = (full.length / 48000 * 1000).toFixed(0) + ' ms';
  $('#r-centroid').textContent = Math.round(centroid(full)) + ' Hz';
}

/* Draw something immediately — the scope is a picture of the sound and needs no
   audio context, so it should not wait for a gesture. */
if (ctx2d) {
  const fit = () => {
    const r = cv.getBoundingClientRect();
    cv.width = Math.max(320, Math.round(r.width * 2));
    cv.height = Math.round(r.height * 2);
    drawScope();
  };
  fit();
  addEventListener('resize', fit, { passive: true });
}

/* --- the demo field ---------------------------------------------------------- */
$('#demo')?.addEventListener('focus', boot);

/* --- checkout is intentionally inert until there is a build to sell ---------- */
$('#buy-btn')?.addEventListener('click', (e) => {
  e.preventDefault();
  const n = $('#prelaunch');
  n.style.borderColor = '#ffcf8b';
  n.scrollIntoView({ behavior: 'smooth', block: 'center' });
  setTimeout(() => { n.style.borderColor = ''; }, 1600);
});
