import Foundation

/// Offline synthesis of one keypress. Everything is rendered ahead of time at
/// launch and played back from memory, so a keystroke costs a buffer schedule
/// and nothing else — no filtering or allocation on the audio path.

/// RBJ constant-peak-gain band-pass. One biquad, direct form I.
struct BandPass {
  private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
  private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

  init(freq: Double, q: Double, sampleRate: Double) {
    // Guard against a centre above Nyquist, which would fold the band down to
    // an audibly wrong frequency instead of failing.
    let f = min(max(freq, 20.0), sampleRate * 0.45)
    let w0 = 2.0 * Double.pi * f / sampleRate
    let alpha = sin(w0) / (2.0 * max(q, 0.05))
    let a0 = 1.0 + alpha
    b0 = alpha / a0
    b1 = 0.0
    b2 = -alpha / a0
    a1 = (-2.0 * cos(w0)) / a0
    a2 = (1.0 - alpha) / a0
  }

  mutating func process(_ x: Double) -> Double {
    let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
    x2 = x1; x1 = x
    y2 = y1; y1 = y
    return y
  }
}

/// Stable string hash (FNV-1a, 64-bit).
///
/// NOT `String.hashValue`: Swift seeds that randomly per process, so using it to
/// derive a synthesis seed made every switch sound subtly different on every
/// launch. It went unnoticed because the self-test's determinism check compared
/// two renders *within one process*, where the seed is constant — the check was
/// narrower than the claim it printed. Caught by md5-ing the self-test output
/// across two runs and getting different digests.
func stableHash(_ s: String) -> UInt64 {
  var h: UInt64 = 0xcbf29ce484222325
  for b in s.utf8 {
    h ^= UInt64(b)
    h = h &* 0x100000001b3
  }
  return h
}

/// Small deterministic PRNG so a given (profile, phase, variant) always renders
/// identically — across runs, not just within one. Determinism is what makes the
/// self-test meaningful: with a per-process seed, "peak = 0.72" is unreproducible
/// and cannot be asserted against.
struct SeededRandom {
  private var state: UInt64
  init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
  mutating func nextUnit() -> Double {   // white noise in [-1, 1)
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return Double(Int64(bitPattern: state)) / Double(Int64.max)
  }
}

enum Phase { case press, release }

struct Synth {
  let sampleRate: Double

  /// Render one hit to mono float samples.
  ///
  /// `variant` selects a deterministic jitter set. Pre-rendering several
  /// variants is what produces the randomised-pitch character without doing any
  /// resampling at playback time: a real keyboard never makes the exact same
  /// sound twice, and repeating one buffer verbatim is instantly recognisable as
  /// synthetic.
  /// `normaliseAgainst` supplies the peak to normalise by, instead of this mix's
  /// own peak.
  ///
  /// Without it the voicing does nothing measurable. Normalising each render to
  /// its own peak means a quieter mix is simply scaled back up: measured with an
  /// FFT, the headphone and speaker voicings came out at exactly 100% of each
  /// other's peak, with bass at 85% and treble at 101% — i.e. the cuts were being
  /// undone. Normalising the headphone mix against the SPEAKER peak keeps them.
  func render(profile p: Profile, phase: Phase, size: KeySize, variant: Int,
              output: OutputKind = .speakers,
              normaliseAgainst: Double? = nil,
              peakOnly: UnsafeMutablePointer<Double>? = nil) -> [Float] {
    var rng = SeededRandom(seed: stableHash(p.slug)
                                 &+ UInt64(variant) &* 7919
                                 &+ (phase == .press ? 0 : 104729)
                                 &+ UInt64(sizeSalt(size)))

        // Jitter: +/-3% on frequencies, +/-8% on gains. Enough to break the
    // xerox-copy effect, small enough that the switch keeps its identity.
    let j = { (spread: Double) -> Double in 1.0 + rng.nextUnit() * spread }
    let fJit = j(0.03), gJit = j(0.08)

    // The release is a quieter, brighter, shorter version of the press: the
    // stem hitting the top housing has less cavity behind it than the bottom-out.
    let isRelease = (phase == .release)
    let relBody  = isRelease ? 0.35 : 1.0
    let relNoise = isRelease ? 0.55 : 1.0
    let relHi    = isRelease ? 0.60 : 1.0
    let relDec   = isRelease ? 0.62 : 1.0
    let relBright = isRelease ? 1.15 : 1.0

    let bodyDec  = p.bodyDec * size.bodyDecayScale * relDec
    let noiseDec = p.noiseDec * relDec
    let noiseF   = p.noise * size.noiseCentreScale * relBright * fJit
    let hiF      = p.hiHz * relBright * fJit

    // Long enough for the slowest mode to fall below audibility.
    let tail = max(bodyDec * 6.0, noiseDec * 6.0) + 0.01
    let n = Int(tail * sampleRate)
    var out = [Double](repeating: 0.0, count: n)

    // --- IMPACT: broadband, not one band -------------------------------------
    // A stem hitting plastic excites a wide spectrum at once. Modelling that as a
    // single band-pass is why the first version read as "filtered noise" rather
    // than "something hit something". Three overlapping bands with different
    // centres and decays give the spectrum motion as it dies, which a recording
    // has and a single band cannot. The ratios are PER PROFILE, so a linear and a
    // clicky differ in kind rather than in pitch.
    let burst = Int(0.0015 * sampleRate)
    let bands: [(f: Double, q: Double, g: Double, d: Double)] = [
      (p.lo,  0.60, 0.90 * (1 + p.damp * 0.5) * output.weightScale, 1.40),   // weight
      (1.00,  0.95, 1.00,                      1.00),   // the click
      (p.hi,  1.25, 0.55 * p.crack * (1 - p.damp * 0.75) * output.crackScale, 0.50),  // crack
    ]
    for b in bands where b.g > 0.001 {
      var bp = BandPass(freq: noiseF * b.f, q: p.noiseQ * b.q, sampleRate: sampleRate)
      let amp = p.noiseGain * relNoise * gJit * b.g
      let dec = noiseDec * b.d
      for i in 0..<n {
        let drive = i < burst ? rng.nextUnit() : 0.0
        let v = bp.process(drive)
        out[i] += v * amp * exp(-Double(i) / (dec * sampleRate))
      }
    }

    // --- BOTTOM-OUT THUD -------------------------------------------------------
    // The dominant low component of a real keypress, and missing entirely from
    // the first model: the whole board takes the impact. Low Q so it thumps
    // instead of ringing a pitch.
    do {
      var bp = BandPass(freq: p.body * 0.82, q: 2.2, sampleRate: sampleRate)
      let amp = p.bodyGain * relBody * 2.6 * p.thud * output.thudScale * gJit
      let dec = bodyDec * 0.7
      let hit = Int(0.0022 * sampleRate)
      for i in 0..<n {
        let drive = i < hit ? rng.nextUnit() : 0.0
        let v = bp.process(drive)
        out[i] += v * amp * exp(-Double(i) / (dec * sampleRate))
      }
    }

    // --- body: three inharmonic modes, also band-passed noise ---------------
    // These were oscillators at first, which was wrong: an oscillator puts all
    // its power at one frequency while the noise is spread across a band, so
    // matching them by gain made the body inaudible next to the transient.
    // Exciting band-passed noise instead puts both voices on the same footing.
    for (k, ratio) in Profiles.modeRatios.enumerated() {
      let modeF = p.body * ratio * fJit
      guard modeF < sampleRate * 0.45 else { continue }
      // Upper modes ring relative to the lowest — this is the thock/clack knob.
      let modeGain = (k == 0 ? 1.0 : p.bodyHi * (k == 1 ? 0.7 : 0.4))
      let modeDec = bodyDec * (k == 0 ? 1.0 : 0.55)
      // Q lowered from 7+3k: high-Q modes ring like a struck tube, which was a
      // large part of the synthetic character. These should tint, not sing.
      var bp = BandPass(freq: modeF, q: 4.5 + Double(k) * 1.8, sampleRate: sampleRate)
      var mrng = SeededRandom(seed: UInt64(9176 &+ k &* 31 &+ variant))
      let amp = p.bodyGain * relBody * modeGain * output.bodyScale * gJit
      for i in 0..<n {
        let drive = i < burst ? mrng.nextUnit() : 0.0
        let v = bp.process(drive)
        out[i] += v * amp * exp(-Double(i) / (modeDec * sampleRate))
      }
    }

    // --- edge snap: very short, very high ----------------------------------
    var bpHi = BandPass(freq: hiF, q: p.hiQ, sampleRate: sampleRate)
    let hiAmp = p.hiGain * relHi * output.snapScale * gJit
    let hiBurst = Int(0.0006 * sampleRate)
    for i in 0..<n {
      let drive = i < hiBurst ? rng.nextUnit() : 0.0
      let v = bpHi.process(drive)
      out[i] += v * hiAmp * exp(-Double(i) / (p.hiDec * sampleRate))
    }

    // --- shaping -----------------------------------------------------------
    let trim = p.gain * size.gainScale
    // A 0.2 ms fade-in removes the DC step at t=0. Without it every keystroke
    // carries a thump that is not part of the switch.
    let fadeIn = max(Int(0.0002 * sampleRate), 1)
    // A 1 ms fade-out prevents a discontinuity at buffer end.
    let fadeOut = max(Int(0.001 * sampleRate), 1)

    var peak = 0.0
    for i in 0..<n {
      var v = out[i] * trim
      v = tanh(v * 1.4) / 1.4                       // soft clip, keeps transients honest
      if i < fadeIn { v *= Double(i) / Double(fadeIn) }
      if i > n - fadeOut { v *= Double(n - i) / Double(fadeOut) }
      out[i] = v
      peak = max(peak, abs(v))
    }

    // Per-profile peak, NOT a single shared target. Normalising every voice to
    // one level was the single largest homogeniser — a soft linear and a clicky
    // are not equally loud in the world, and making them equal removes the most
    // obvious cue that two switches are different.
    if let peakOnly { peakOnly.pointee = peak; return [] }
    let target = p.level
    let basis = normaliseAgainst ?? peak
    let norm = basis > 1e-9 ? target / basis : 1.0
    return out.map { Float($0 * norm) }
  }

  /// Pre-normalisation peak of the speaker mix — the reference a voiced render
  /// must normalise against so its cuts survive.
  func speakerPeak(profile p: Profile, phase: Phase, size: KeySize, variant: Int) -> Double {
    var pk = 0.0
    _ = render(profile: p, phase: phase, size: size, variant: variant,
               output: .speakers, peakOnly: &pk)
    return pk
  }

  private func sizeSalt(_ s: KeySize) -> Int {
    switch s { case .normal: return 0; case .wide: return 1301; case .space: return 2603 }
  }
}
