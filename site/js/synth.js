/* ============================================================================
   Toki — web synthesiser
   ----------------------------------------------------------------------------
   A faithful port of Sources/toki/Synth.swift and Profiles.swift from the macOS
   app. Same model, same parameters, same pre-render architecture:

     transient  band-passed noise, excited 1.5 ms then left to ring — the click
     body       three INHARMONIC modes (1 : 2.71 : 5.18), also band-passed noise
     snap       0.6 ms burst up high — plastic on plastic

   This matters for honesty, not just tidiness: the page claims you are hearing
   the product, so the browser must run the product's engine rather than a
   marketing approximation. If the Swift parameters change, change them here too.

   There are no audio files anywhere in this project. Nothing is fetched.
   ========================================================================== */

export const PROFILES = [
  /* Switches differ in KIND, not just in pitch. A shared band recipe shifted up
     and down makes every voice a sibling — measured: mean timbre distance 1.58,
     with the closest pair at 0.78, which is what "they all sound the same" is in
     numbers. So each profile now carries its own impact structure:

       thud   bottom-out weight — the board taking the hit. Linears live here.
       crack  the high transient. Clickies live here.
       lo/hi  where this switch's impact bands sit relative to its centre —
              a wide spread reads dry and papery, a narrow one reads focused.
       damp   top-end rolloff. High damp = "creamy"; low damp = open and ringy.
  */
  /* Ordered dull -> bright. `name` is the real switch each voice is modelled on
     and `family` is the switch TYPE, which is what a buyer actually chooses by.

     The names stay because they ARE the product's vocabulary: "Cherry MX Blue"
     tells a reader exactly what they are about to hear and an invented name
     tells them nothing. They are used nominatively — to identify what was
     modelled — and every surface that shows them also says these are original
     emulations with no affiliation or endorsement. That pairing is the point:
     naming the reference is not the risk, implying you ARE it would be.

     Slugs are frozen: the synthesis seed is stableHash(slug), so renaming a slug
     would change the sound itself. Names and families are display-only. */
  // slug         name                    family     body bodyHi bodyDec bodyGain  noise  nQ   nDec  nGain   hiHz  hiQ  hiDec hiGain gain  thud crack  lo    hi   damp
  ['cocoa',     'Gateron Milky Yellow', 'Linear', 98, 0.28, 0.072,  0.62,      880, 0.62, 0.030, 1.55,  2600, 0.80, .0060, 0.22, 1.06, 2.10, 0.14, 0.34, 1.35, 0.80],
  ['butter',    'NovelKeys Cream',      'Linear', 152, 0.70, 0.044,  0.38,     1750, 1.15, 0.020, 2.00,  4200, 1.15, .0050, 0.60, 0.99, 1.05, 0.55, 0.55, 1.55, 0.70],
  ['graphite',  'Cherry MX Black',      'Linear', 128, 0.42, 0.052,  0.40,     1350, 0.85, 0.022, 2.30,  3800, 0.95, .0048, 0.55, 1.00, 1.35, 0.45, 0.42, 1.75, 0.45],
  ['vermilion', 'Cherry MX Brown',      'Tactile',178, 0.85, 0.030,  0.26,     2450, 1.00, 0.015, 2.70,  5200, 1.00, .0038, 1.05, 1.00, 0.70, 0.95, 0.48, 2.10, 0.30],
  ['amethyst',  'Gazzew Boba U4T',      'Tactile',205, 1.05, 0.024,  0.16,     3400, 1.35, 0.011, 3.10,  7200, 1.35, .0032, 1.85, 0.95, 0.35, 1.55, 0.62, 2.60, 0.05],
  ['kraft',     'Cherry MX Blue',       'Clicky', 168, 0.62, 0.014,  0.10,     2100, 0.55, 0.008, 3.20,  6000, 0.70, .0026, 1.35, 1.00, 0.22, 1.30, 0.28, 3.10, 0.15],
  ['porcelain', 'Kailh Box Jade',       'Clicky', 232, 1.25, 0.020,  0.14,     4300, 1.50, 0.010, 3.70,  8600, 1.50, .0030, 2.40, 0.92, 0.18, 1.90, 0.70, 3.40, 0.00],
].map(([slug, name, family, body, bodyHi, bodyDec, bodyGain,
        noise, noiseQ, noiseDec, noiseGain, hiHz, hiQ, hiDec, hiGain, gain,
        thud, crack, lo, hi, damp]) =>
  ({ slug, name, family, body, bodyHi, bodyDec, bodyGain,
     noise, noiseQ, noiseDec, noiseGain, hiHz, hiQ, hiDec, hiGain, gain,
     thud, crack, lo, hi, damp,
     /* Peak level per switch. Normalising every voice to one target was the
        largest single homogeniser: a soft linear and a clicky are not the same
        loudness in the world, and making them equal removes the most obvious
        cue that two switches are different. */
     level: ({ cocoa: 0.50, butter: 0.58, graphite: 0.64, vermilion: 0.72,
               amethyst: 0.82, kraft: 0.86, porcelain: 0.98 })[slug] ?? 0.72 }));

export const MODE_RATIOS = [1.0, 2.71, 5.18];
const VARIANTS = 16;
/* Fewer variants in the browser than in the app: seven profiles are cached at
   once here, so 16 each would be 224 buffers and a slow first paint. */
const VARIANTS_WEB = 8;

/* Key size classes — a spacebar is a bigger box with more air in it. */
const SIZE = {
  normal: { dec: 1.00, gain: 1.00, centre: 1.00 },
  wide:   { dec: 1.22, gain: 1.08, centre: 0.94 },
  space:  { dec: 1.45, gain: 1.18, centre: 0.86 },
};

/* RBJ constant-peak-gain band-pass, one biquad, direct form I. */
function bandpass(freq, q, sr) {
  const f = Math.min(Math.max(freq, 20), sr * 0.45);
  const w0 = 2 * Math.PI * f / sr;
  const alpha = Math.sin(w0) / (2 * Math.max(q, 0.05));
  const a0 = 1 + alpha;
  const b0 = alpha / a0, b2 = -alpha / a0;
  const a1 = (-2 * Math.cos(w0)) / a0, a2 = (1 - alpha) / a0;
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  return (x) => {
    const y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1; x1 = x; y2 = y1; y1 = y;
    return y;
  };
}

/* Deterministic PRNG (xorshift64), so a given voice renders identically every
   load. Same reason as the app: with an unseeded source the sound would drift
   between page loads and nothing could be asserted about it. */
function rng(seed) {
  let s = BigInt.asUintN(64, BigInt(seed) || 1n);
  const M = (1n << 64n) - 1n;
  return () => {
    s ^= (s << 13n) & M;
    s ^= s >> 7n;
    s ^= (s << 17n) & M;
    return Number(BigInt.asIntN(64, s)) / 9223372036854775807;
  };
}

function stableHash(str) {
  let h = 0xcbf29ce484222325n;
  for (const ch of str) {
    h ^= BigInt(ch.codePointAt(0));
    h = BigInt.asUintN(64, h * 0x100000001b3n);
  }
  return h;
}

/**
 * Render one hit to a mono Float32Array.
 * `tune` is the live tuner: {bright, body, decay} each ~0.5 at neutral.
 */
export function render(p, { sr = 48000, phase = 'press', size = 'normal',
                            variant = 0, tune = null } = {}) {
  const sz = SIZE[size] || SIZE.normal;
  const seed = stableHash(p.slug) + BigInt(variant) * 7919n
             + (phase === 'press' ? 0n : 104729n)
             + BigInt(size === 'normal' ? 0 : size === 'wide' ? 1301 : 2603);
  const rand = rng(seed);

  const jit = (spread) => 1 + rand() * spread;
  const fJit = jit(0.03), gJit = jit(0.08);

  const rel = phase === 'release';
  const relBody = rel ? 0.35 : 1, relNoise = rel ? 0.55 : 1;
  const relHi = rel ? 0.60 : 1, relDec = rel ? 0.62 : 1, relBright = rel ? 1.15 : 1;

  // Tuner: multiplicative around neutral so the shipped voices are the midpoint.
  const tBright = tune ? 0.55 + tune.bright * 1.35 : 1;   // band centre
  const tBody   = tune ? 0.25 + tune.body   * 1.75 : 1;   // body level
  const tDecay  = tune ? 0.45 + tune.decay  * 1.45 : 1;   // ring length

  const bodyDec  = p.bodyDec * sz.dec * relDec * tDecay;
  const noiseDec = p.noiseDec * relDec * tDecay;
  const noiseF   = p.noise * sz.centre * relBright * fJit * tBright;
  const hiF      = p.hiHz * relBright * fJit * tBright;

  const tail = Math.max(bodyDec * 6, noiseDec * 6) + 0.01;
  const n = Math.floor(tail * sr);
  const out = new Float64Array(n);
  const burst = Math.floor(0.0015 * sr);

  // ---- IMPACT: broadband, not one band -------------------------------------
  // A stem hitting plastic excites a wide spectrum at once. Modelling that as a
  // single band-pass is the main reason v1 read as "filtered noise" rather than
  // "something hit something". Three overlapping bands at different centres and
  // decays sum to an impact: the low one carries weight, the high one carries
  // the crack, and their different decay rates give the spectrum motion as it
  // dies — which is what a recording has and a single band does not.
  const BANDS = [
    { f: p.lo,  q: 0.60, g: 0.90 * (1 + p.damp * 0.5), d: 1.40 },  // weight
    { f: 1.00,  q: 0.95, g: 1.00,                      d: 1.00 },  // the click
    { f: p.hi,  q: 1.25, g: 0.55 * p.crack * (1 - p.damp * 0.75), d: 0.50 },  // crack
  ];
  for (const b of BANDS) {
    if (b.g <= 0.001) continue;
    const bp = bandpass(noiseF * b.f, p.noiseQ * b.q, sr);
    const amp = p.noiseGain * relNoise * gJit * b.g;
    const dec = noiseDec * b.d;
    for (let i = 0; i < n; i++) {
      const v = bp(i < burst ? rand() : 0);
      out[i] += v * amp * Math.exp(-i / (dec * sr));
    }
  }

  // ---- BOTTOM-OUT THUD ------------------------------------------------------
  // The dominant low component of a real keypress, and absent from v1: the whole
  // board takes the impact. Low Q so it thumps instead of ringing a pitch, and a
  // short decay so it reads as weight rather than as a bass note.
  {
    const bp = bandpass(p.body * 0.82, 2.2, sr);
    const amp = p.bodyGain * relBody * 2.6 * p.thud * gJit * tBody;
    const dec = bodyDec * 0.7;
    const hit = Math.floor(0.0022 * sr);
    for (let i = 0; i < n; i++) {
      const v = bp(i < hit ? rand() : 0);
      out[i] += v * amp * Math.exp(-i / (dec * sr));
    }
  }

  // body — inharmonic, because a case is a box and not a string
  MODE_RATIOS.forEach((ratio, k) => {
    const f = p.body * ratio * fJit;
    if (f >= sr * 0.45) return;
    const modeGain = k === 0 ? 1 : p.bodyHi * (k === 1 ? 0.7 : 0.4);
    const modeDec = bodyDec * (k === 0 ? 1 : 0.55);
    // Q lowered from 7+3k: high-Q modes ring like a struck tube and were a
    // large part of the synthetic character. These should tint the impact.
    const bp = bandpass(f, 4.5 + k * 1.8, sr);
    const mrand = rng(9176n + BigInt(k) * 31n + BigInt(variant));
    const amp = p.bodyGain * relBody * modeGain * gJit * tBody;
    for (let i = 0; i < n; i++) {
      const v = bp(i < burst ? mrand() : 0);
      out[i] += v * amp * Math.exp(-i / (modeDec * sr));
    }
  });

  // edge snap
  {
    const bp = bandpass(hiF, p.hiQ, sr);
    const amp = p.hiGain * relHi * gJit;
    const hb = Math.floor(0.0006 * sr);
    for (let i = 0; i < n; i++) {
      const v = bp(i < hb ? rand() : 0);
      out[i] += v * amp * Math.exp(-i / (p.hiDec * sr));
    }
  }

  // shaping: soft clip, de-click both ends, normalise to consistent headroom
  const trim = p.gain * sz.gain;
  const fi = Math.max(Math.floor(0.0002 * sr), 1);
  const fo = Math.max(Math.floor(0.001 * sr), 1);
  let peak = 0;
  for (let i = 0; i < n; i++) {
    let v = Math.tanh(out[i] * trim * 1.4) / 1.4;
    if (i < fi) v *= i / fi;
    if (i > n - fo) v *= (n - i) / fo;
    out[i] = v;
    peak = Math.max(peak, Math.abs(v));
  }
  const norm = peak > 1e-9 ? (p.level ?? 0.72) / peak : 1;
  const f32 = new Float32Array(n);
  for (let i = 0; i < n; i++) f32[i] = out[i] * norm;
  return f32;
}

/** Spectral centroid — used by the page to show how bright a voice is. */
export function centroid(x, sr = 48000) {
  let num = 0, den = 0;
  for (let f = 200; f < sr * 0.45; f *= 1.12) {
    let re = 0, im = 0;
    const w = 2 * Math.PI * f / sr;
    for (let i = 0; i < x.length; i += 2) {   // stride 2: plenty for a readout
      re += x[i] * Math.cos(w * i);
      im += x[i] * Math.sin(w * i);
    }
    const mag = Math.hypot(re, im);
    num += mag * f; den += mag;
  }
  return den > 0 ? num / den : 0;
}

/* ---------------------------------------------------------------------------
   Playback. Mirrors the app: every buffer is rendered up front, so a keypress
   costs one buffer schedule. Voices are chosen PER KEY, not randomly — on a real
   board each key is its own physical switch, so pressing `a` twice sounds the
   same while `a` and `s` differ. Per-press liveliness comes from gain instead.
   --------------------------------------------------------------------------- */
export class Player {
  constructor() {
    this.ctx = null;
    this.master = null;
    /* buffers[slug][phase][size] -> [variant]
       ALL profiles are cached, not just the current one, because the typing test
       changes switch mid-sentence. Rebuilding 96 buffers at a sentence boundary
       would stall the page exactly when the visitor is mid-flow. */
    this.cache = {};
    this.tune = null;
    this.volume = 0.63;
    this.ready = new Set();
    this.onProgress = null;
  }

  async ensure() {
    if (!this.ctx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return false;
      this.ctx = new AC({ sampleRate: 48000 });
      this.master = this.ctx.createGain();
      this.master.gain.value = this.volume;
      this.master.connect(this.ctx.destination);
    }
    if (this.ctx.state === 'suspended') await this.ctx.resume();
    this.precompute();          // usually already done at page load
    if (this.ready.size < PROFILES.length) this.wrapAll();
    return this.ctx.state === 'running';
  }

  /* Compute raw PCM with no AudioContext. render() is pure maths, so this can
     run at page load, long before the browser will allow audio. On the first
     gesture all that remains is wrapping Float32Arrays into AudioBuffers, which
     is fast — otherwise the first keystroke waits ~300 ms for a render and the
     visitor hears nothing for the one keypress that matters most. */
  precompute() {
    if (this.pcm) return this.pcm;
    this.pcm = {};
    for (const p of PROFILES) {
      const bank = { press: {}, release: {} };
      for (const phase of ['press', 'release']) {
        for (const size of ['normal', 'space']) {
          const list = [];
          for (let v = 0; v < VARIANTS_WEB; v++) {
            list.push(render(p, { sr: 48000, phase, size, variant: v, tune: this.tune }));
          }
          bank[phase][size] = list;
        }
      }
      this.pcm[p.slug] = bank;
    }
    return this.pcm;
  }

  /** Wrap precomputed PCM into AudioBuffers. Cheap; needs a live context. */
  wrapAll() {
    const sr = this.ctx.sampleRate;
    for (const p of PROFILES) {
      const src = this.pcm[p.slug];
      const out = { press: {}, release: {} };
      for (const phase of ['press', 'release']) {
        for (const size of ['normal', 'space']) {
          out[phase][size] = src[phase][size].map((data) => {
            const buf = this.ctx.createBuffer(1, data.length, sr);
            buf.copyToChannel(data, 0);
            return buf;
          });
        }
      }
      this.cache[p.slug] = out;
      this.ready.add(p.slug);
    }
    this.onProgress?.(this.ready.size, PROFILES.length);
  }

  async buildProfile(p) {
    const sr = this.ctx.sampleRate;
    const out = { press: {}, release: {} };
    for (const phase of ['press', 'release']) {
      for (const size of ['normal', 'space']) {
        const list = [];
        for (let v = 0; v < VARIANTS_WEB; v++) {
          const data = render(p, { sr, phase, size, variant: v, tune: this.tune });
          const buf = this.ctx.createBuffer(1, data.length, sr);
          buf.copyToChannel(data, 0);
          list.push(buf);
        }
        out[phase][size] = list;
        await new Promise(r => setTimeout(r, 0));   // keep the page responsive
      }
    }
    this.cache[p.slug] = out;
    this.ready.add(p.slug);
    this.onProgress?.(this.ready.size, PROFILES.length);
  }

  async buildRest() {
    if (this._resting) return;
    this._resting = true;
    for (const p of PROFILES) {
      if (!this.ready.has(p.slug)) await this.buildProfile(p);
    }
    this._resting = false;
  }

  /** Re-render everything for new tuner settings. */
  async setTune(t) {
    this.tune = t;
    this.cache = {}; this.ready.clear(); this.pcm = null;
    this.precompute();
    if (this.ctx) this.wrapAll();
  }

  setVolume(v) { this.volume = v; if (this.master) this.master.gain.value = v; }

  isReady(slug) { return this.ready.has(slug); }

  /** Falls back to the first rendered voice if `slug` has not finished yet. */
  play(slug, keyCode = 0, { phase = 'press', size = 'normal', pan = 0 } = {}) {
    if (!this.ctx) return false;
    const bank = this.cache[slug] || this.cache[PROFILES[0].slug];
    if (!bank) return false;
    const list = bank[phase][size] || bank[phase].normal;
    if (!list?.length) return false;

    const vi = Math.abs(Math.imul(keyCode, 2654435761)) % list.length;
    const src = this.ctx.createBufferSource();
    src.buffer = list[vi];
    const g = this.ctx.createGain();
    g.gain.value = 1 + (Math.random() * 0.14 - 0.07);
    src.connect(g);
    if (this.ctx.createStereoPanner) {
      const pn = this.ctx.createStereoPanner();
      pn.pan.value = Math.max(-1, Math.min(1, pan));
      g.connect(pn); pn.connect(this.master);
    } else {
      g.connect(this.master);
    }
    src.start();
    return true;
  }
}

/* Approximate horizontal position per physical key, for the stereo image. */
const ROWS = ['`1234567890-=', 'qwertyuiop[]\\', "asdfghjkl;'", 'zxcvbnm,./'];
export function panFor(char) {
  const c = (char || '').toLowerCase();
  for (const row of ROWS) {
    const i = row.indexOf(c);
    if (i >= 0) return ((i / (row.length - 1)) * 2 - 1) * 0.55;
  }
  return 0;
}
export function sizeFor(key) { return (key === ' ') ? 'space' : 'normal'; }
export function codeFor(key) {
  let h = 0;
  for (const ch of String(key)) h = (h * 31 + ch.codePointAt(0)) | 0;
  return h;
}
