import Foundation

/// A switch's voice, as synthesis parameters rather than a recording.
///
/// `name`/`family` are the real switch each voice is MODELLED ON. These are
/// emulations, not samples — there is no recording anywhere in this project, and
/// the product says so plainly rather than implying these are the real captures.
///
/// The model: a band-passed noise TRANSIENT (the click itself) over a modal
/// BODY of three inharmonic resonances (the cavity ringing), plus a very short
/// high band-passed EDGE SNAP. Nothing here is sampled — there is no recording
/// in this project, by design.
///
/// The numbers were fitted by ear-and-measurement while building the web
/// prototype, then carried over. `noise` is the parameter that does most of the
/// perceptual work: it sets the transient's band centre, and the resulting
/// spectral centroid runs from the dullest voice at ~1.67 kHz to the brightest
/// at ~2.86 kHz.
struct Profile {
  let slug: String
  let name: String
  let family: String

  // modal body — the "thock"
  let body: Double        // Hz of the lowest cavity mode
  let bodyHi: Double      // how strongly the two upper modes ring vs the lowest
  let bodyDec: Double     // seconds, decay of the lowest mode
  let bodyGain: Double

  // transient — the "click"
  let noise: Double       // band-pass centre of the main transient
  let noiseQ: Double      // lower Q = broader, dryer
  let noiseDec: Double    // seconds
  let noiseGain: Double

  // edge snap — a much shorter, much higher burst
  let hiHz: Double
  let hiQ: Double
  let hiDec: Double
  let hiGain: Double

  let gain: Double        // per-voice trim

  /* Character. Switches differ in KIND, not just in pitch — a shared recipe
     shifted up and down makes every voice a sibling. Measured on the web port:
     with one shared band structure the closest pair sat at 0.78 timbre distance,
     which is what "they all sound the same" looks like as a number. */
  let thud: Double        // bottom-out weight — the board taking the hit
  let crack: Double       // the high transient — clickies live here
  let lo: Double          // low impact band, as a ratio of the noise centre
  let hi: Double          // high impact band, ditto — wide reads dry and papery
  let damp: Double        // top-end rolloff; high = creamy, low = open
  let level: Double       // PEAK LEVEL. Normalising every voice to one target was
                          // the single largest homogeniser: a soft linear and a
                          // clicky are not equally loud in the world.
}

enum Profiles {
  /// Inharmonic mode ratios for the body. Deliberately not integer multiples —
  /// a keyboard case is a box, not a string, so its modes are not a harmonic
  /// series. Integer ratios here read as a pitched "boing" instead of a thock.
  static let modeRatios: [Double] = [1.0, 2.71, 5.18]

  static let all: [Profile] = [
    Profile(slug: "graphite", name: "Cherry MX Black", family: "Linear",
            body: 128, bodyHi: 0.42, bodyDec: 0.052, bodyGain: 0.40,
            noise: 1350, noiseQ: 0.85, noiseDec: 0.022, noiseGain: 2.30,
            hiHz: 3800, hiQ: 0.95, hiDec: 0.0048, hiGain: 0.55, gain: 1.00,
            thud: 1.35, crack: 0.45, lo: 0.42, hi: 1.75, damp: 0.45, level: 0.64),

    Profile(slug: "amethyst", name: "Gazzew Boba U4T", family: "Tactile",
            body: 205, bodyHi: 1.05, bodyDec: 0.024, bodyGain: 0.16,
            noise: 3400, noiseQ: 1.35, noiseDec: 0.011, noiseGain: 3.10,
            hiHz: 7200, hiQ: 1.35, hiDec: 0.0032, hiGain: 1.85, gain: 0.95,
            thud: 0.35, crack: 1.55, lo: 0.62, hi: 2.60, damp: 0.05, level: 0.82),

    Profile(slug: "cocoa", name: "Gateron Milky Yellow", family: "Linear",
            body: 98, bodyHi: 0.28, bodyDec: 0.072, bodyGain: 0.62,
            noise: 880, noiseQ: 0.62, noiseDec: 0.030, noiseGain: 1.55,
            hiHz: 2600, hiQ: 0.80, hiDec: 0.0060, hiGain: 0.22, gain: 1.06,
            thud: 2.10, crack: 0.14, lo: 0.34, hi: 1.35, damp: 0.80, level: 0.50),

    Profile(slug: "kraft", name: "Cherry MX Blue", family: "Clicky",
            body: 168, bodyHi: 0.62, bodyDec: 0.014, bodyGain: 0.10,
            noise: 2100, noiseQ: 0.55, noiseDec: 0.008, noiseGain: 3.20,
            hiHz: 6000, hiQ: 0.70, hiDec: 0.0026, hiGain: 1.35, gain: 1.00,
            thud: 0.22, crack: 1.30, lo: 0.28, hi: 3.10, damp: 0.15, level: 0.86),

    Profile(slug: "butter", name: "NovelKeys Cream", family: "Linear",
            body: 152, bodyHi: 0.70, bodyDec: 0.044, bodyGain: 0.38,
            noise: 1750, noiseQ: 1.15, noiseDec: 0.020, noiseGain: 2.00,
            hiHz: 4200, hiQ: 1.15, hiDec: 0.0050, hiGain: 0.60, gain: 0.99,
            thud: 1.05, crack: 0.55, lo: 0.55, hi: 1.55, damp: 0.70, level: 0.58),

    Profile(slug: "vermilion", name: "Cherry MX Brown", family: "Tactile",
            body: 178, bodyHi: 0.85, bodyDec: 0.030, bodyGain: 0.26,
            noise: 2450, noiseQ: 1.00, noiseDec: 0.015, noiseGain: 2.70,
            hiHz: 5200, hiQ: 1.00, hiDec: 0.0038, hiGain: 1.05, gain: 1.00,
            thud: 0.70, crack: 0.95, lo: 0.48, hi: 2.10, damp: 0.30, level: 0.72),

    Profile(slug: "porcelain", name: "Kailh Box Jade", family: "Clicky",
            body: 232, bodyHi: 1.25, bodyDec: 0.020, bodyGain: 0.14,
            noise: 4300, noiseQ: 1.50, noiseDec: 0.010, noiseGain: 3.70,
            hiHz: 8600, hiQ: 1.50, hiDec: 0.0030, hiGain: 2.40, gain: 0.92,
            thud: 0.18, crack: 1.90, lo: 0.70, hi: 3.40, damp: 0.00, level: 0.98),
  ]

  static let defaultSlug = "graphite"

  static func find(_ slug: String) -> Profile {
    all.first { $0.slug == slug } ?? all.first { $0.slug == defaultSlug }!
  }
}

/// Big keys sound bigger: more cavity, slightly louder, a touch duller.
/// Applied as scalars rather than separate profiles so a new switch only has to
/// be described once.
enum KeySize {
  case normal, wide, space

  static func of(keyCode: Int64) -> KeySize {
    switch keyCode {
    case 49: return .space                       // space
    case 36, 76, 51, 48, 56, 60, 57, 59, 61, 55, 58, 54:
      return .wide                               // return, enter, delete, tab, shifts, caps, ctrl, opt, cmd
    default: return .normal
    }
  }

  var bodyDecayScale: Double {
    switch self { case .normal: return 1.0; case .wide: return 1.22; case .space: return 1.45 }
  }
  var gainScale: Double {
    switch self { case .normal: return 1.0; case .wide: return 1.08; case .space: return 1.18 }
  }
  var noiseCentreScale: Double {
    switch self { case .normal: return 1.0; case .wide: return 0.94; case .space: return 0.86 }
  }
}
