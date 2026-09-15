import AVFoundation
import Foundation

/// Playback. Every buffer is rendered at launch (or on profile change) and then
/// only scheduled — no synthesis, filtering or allocation happens between a key
/// event and audio coming out.
final class Engine {
  static let sampleRate: Double = 48_000
  static let variantCount = 16

  private let engine = AVAudioEngine()
  private let mixer = AVAudioMixerNode()
  /// A pool, because one AVAudioPlayerNode QUEUES scheduled buffers rather than
  /// overlapping them. With a single node, fast typing would serialise into a
  /// stutter instead of layering. Round-robin across the pool lets hits overlap.
  private var players: [AVAudioPlayerNode] = []
  private var nextPlayer = 0
  private let poolSize = 16

  private let format = AVAudioFormat(standardFormatWithSampleRate: Engine.sampleRate, channels: 2)!

  /// [phase][size][variant] -> buffer, for the current profile.
  private var press: [[AVAudioPCMBuffer]] = []
  private var release: [[AVAudioPCMBuffer]] = []

  private(set) var profile: Profile
  var volume: Double = 0.63 { didSet { mixer.outputVolume = Float(max(0, min(1, volume))) } }
  var spatial: Bool = true
  /// Voicing for the current output. Built-in speakers need the low thud pushed;
  /// in-ear Bluetooth needs it pulled back, the top softened and the stereo
  /// narrowed. Applied at render time so no filter sits on the playback path.
  var output: OutputKind = .speakers

  private let lock = NSLock()

  init(profile: Profile) {
    self.profile = profile

    engine.attach(mixer)
    engine.connect(mixer, to: engine.mainMixerNode, format: format)
    for _ in 0..<poolSize {
      let p = AVAudioPlayerNode()
      engine.attach(p)
      engine.connect(p, to: mixer, format: format)
      players.append(p)
    }
    mixer.outputVolume = Float(volume)
    rebuild(profile: profile)
  }

  func start() throws {
    guard !engine.isRunning else { return }
    try engine.start()
    for p in players { p.play() }
  }

  func stop() {
    for p in players { p.stop() }
    engine.stop()
  }

  var isRunning: Bool { engine.isRunning }

  // MARK: - rendering

  func rebuild(profile p: Profile) {
    let synth = Synth(sampleRate: Engine.sampleRate)
    let out = self.output
    let sizes: [KeySize] = [.normal, .wide, .space]

    var newPress: [[AVAudioPCMBuffer]] = []
    var newRelease: [[AVAudioPCMBuffer]] = []

    for size in sizes {
      var pv: [AVAudioPCMBuffer] = []
      var rv: [AVAudioPCMBuffer] = []
      for v in 0..<Engine.variantCount {
        pv.append(buffer(from: synth.render(profile: p, phase: .press, size: size, variant: v)))
        rv.append(buffer(from: synth.render(profile: p, phase: .release, size: size, variant: v)))
      }
      newPress.append(pv)
      newRelease.append(rv)
    }

    lock.lock()
    self.profile = p
    self.press = newPress
    self.release = newRelease
    lock.unlock()
  }

  private func buffer(from mono: [Float]) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount(mono.count)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    guard let ch = buf.floatChannelData else { return buf }
    // Written to both channels; the stereo image is applied per-hit at
    // schedule time via the player node's pan.
    for i in 0..<mono.count {
      ch[0][i] = mono[i]
      ch[1][i] = mono[i]
    }
    return buf
  }

  // MARK: - playback

  private func sizeIndex(_ s: KeySize) -> Int {
    switch s { case .normal: return 0; case .wide: return 1; case .space: return 2 }
  }

  /// `pan` in -1...1. Called from the event-tap callback.
  ///
  /// Variant selection is PER KEY, not random. On a real board each key is a
  /// separate physical switch sitting at a different point in the case, so it has
  /// a consistent voice: pressing `a` twice sounds the same, while `a` and `s`
  /// differ. Keying the variant to the keycode reproduces that, and it is also
  /// strictly cheaper than the random pick it replaces — no RNG call at all.
  ///
  /// This supersedes an earlier no-immediate-repeat rule, which was solving the
  /// wrong problem. The sample-loop tell is every *different* key sounding
  /// identical, not the same key repeating; suppressing same-key repeats was
  /// actively less realistic than allowing them.
  ///
  /// Per-press liveliness comes from level instead: a small gain jitter standing
  /// in for how hard the finger landed. That is applied at the player node, so it
  /// costs no extra buffers — the alternative, rendering more timbral variants,
  /// would multiply launch cost and memory for a subtler effect.
  func hit(phase: Phase, size: KeySize, pan: Double, keyCode: Int64) {
    guard engine.isRunning else { return }

    lock.lock()
    let table = (phase == .press) ? press : release
    let si = sizeIndex(size)
    guard si < table.count, !table[si].isEmpty else { lock.unlock(); return }

    let n = table[si].count
    // Spread adjacent keycodes across the variant set rather than mapping them in
    // runs: macOS keycodes are laid out so neighbours on the board are often
    // numerically adjacent, and `keyCode % n` would hand whole rows the same
    // voice. An odd multiplier decorrelates them while staying deterministic.
    let vi = n > 1 ? Int((UInt64(bitPattern: keyCode) &* 2654435761) % UInt64(n)) : 0
    let buf = table[si][vi]

    let player = players[nextPlayer]
    nextPlayer = (nextPlayer + 1) % players.count
    lock.unlock()

    // Narrower image on headphones: the same pan that is subtle across two
    // laptop speakers becomes keys ping-ponging between your ears.
    player.pan = spatial ? Float(max(-1, min(1, pan * output.panScale))) : 0
    // +/-7% level, so a repeated key is recognisably the same switch struck
    // again rather than a replayed recording.
    player.volume = Float(1.0 + Double.random(in: -0.07...0.07))
    // .interrupts on this node only — the pool is what preserves overlap
    // between separate keystrokes. Without a reset the node's queue grows and
    // audio drifts further behind the keys the longer you type.
    player.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
  }

  // MARK: - output metering

  /// Taps the engine's output bus so the LIVE path can be measured rather than
  /// assumed. Without this, "engine started" and "audio is audible" are separate
  /// claims and only the first one is checkable.
  func installOutputMeter(_ onBuffer: @escaping (Float, Int) -> Void) {
    let bus = engine.mainMixerNode
    let fmt = bus.outputFormat(forBus: 0)
    bus.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
      guard let ch = buf.floatChannelData else { return }
      var peak: Float = 0
      let n = Int(buf.frameLength)
      for c in 0..<Int(buf.format.channelCount) {
        let p = ch[c]
        for i in 0..<n { peak = max(peak, abs(p[i])) }
      }
      onBuffer(peak, n)
    }
  }

  func removeOutputMeter() {
    engine.mainMixerNode.removeTap(onBus: 0)
  }

  /// Prints both voicings side by side.
  ///
  /// Read these percentages with care: they are crude band sums and they are NOT a
  /// clean readout of the voicing. Two things confound them — the tanh soft clip is
  /// nonlinear, so cutting the low voices lets the transient through harder, and
  /// the low-Q impact bands have wide skirts that dump energy into the 60-300 Hz
  /// window no matter what the thud is doing. That is why a cut can read as >100%.
  /// The voicing is real (every contributing voice is scaled, plus the stereo
  /// width); this report is only a sanity check that something moved.
  static func voicingReport() {
    let synth = Synth(sampleRate: sampleRate)
    func bands(_ x: [Float]) -> (lo: Double, hi: Double, peak: Double) {
      var lo = 0.0, hi = 0.0, pk = 0.0
      for f in stride(from: 60.0, to: 300.0, by: 20.0) { lo += mag(x, f) }
      for f in stride(from: 4000.0, to: 12000.0, by: 500.0) { hi += mag(x, f) }
      for v in x { pk = max(pk, Double(abs(v))) }
      return (lo, hi, pk)
    }
    func mag(_ x: [Float], _ f: Double) -> Double {
      var re = 0.0, im = 0.0
      let w = 2.0 * Double.pi * f / sampleRate
      for (i, v) in x.enumerated() where i % 3 == 0 {
        re += Double(v) * cos(w * Double(i)); im += Double(v) * sin(w * Double(i))
      }
      return (re * re + im * im).squareRoot()
    }
    print("profile      speakers(lo/hi)      headphones(lo/hi)     bass  treble  pan")
    for p in Profiles.all {
      let a = bands(synth.render(profile: p, phase: .press, size: .normal, variant: 0, output: .speakers))
      let b = bands(synth.render(profile: p, phase: .press, size: .normal, variant: 0,
                                 output: .headphones))
      let dBass = b.lo / max(a.lo, 1e-9), dTreb = b.hi / max(a.hi, 1e-9)
      print(String(format: "%-12@ %7.1f/%7.1f    %7.1f/%7.1f    %4.0f%%   %4.0f%%  %3.0f%%",
                   p.name as NSString, a.lo, a.hi, b.lo, b.hi,
                   dBass * 100, dTreb * 100, OutputKind.headphones.panScale * 100))
    }
  }

  // MARK: - self test

  /// Renders every profile and reports level, because a synthesiser that
  /// produces silence looks exactly like one that works until you listen. This
  /// runs headless in CI or over SSH where there is no audio device at all.
  static func selfTest() -> Int32 {
    let synth = Synth(sampleRate: sampleRate)
    var failures = 0
    func pad(_ s: String, _ w: Int) -> String {
      s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }
    print(pad("profile", 12) + pad("phase", 9) + pad("peak", 9)
          + pad("rms", 10) + pad("ms", 8) + "centroid")
    for p in Profiles.all {
      for (label, phase) in [("press", Phase.press), ("release", Phase.release)] {
        let s = synth.render(profile: p, phase: phase, size: .normal, variant: 0)
        var peak: Float = 0
        var sum: Double = 0
        for v in s { peak = max(peak, abs(v)); sum += Double(v) * Double(v) }
        let rms = sqrt(sum / Double(max(s.count, 1)))
        let ms = Double(s.count) / sampleRate * 1000
        let centroid = spectralCentroid(s, sampleRate: sampleRate)
        print(pad(p.slug, 12) + pad(label, 9)
              + pad(String(format: "%.4f", peak), 9)
              + pad(String(format: "%.5f", rms), 10)
              + pad(String(format: "%.1f", ms), 8)
              + String(format: "%.0f Hz", centroid))
        if peak < 0.2 { print("  FAIL \(p.slug)/\(label): peak \(peak) — effectively silent"); failures += 1 }
        if rms < 0.002 { print("  FAIL \(p.slug)/\(label): rms \(rms) — no sustained energy"); failures += 1 }
        if !s.allSatisfy({ $0.isFinite }) { print("  FAIL \(p.slug)/\(label): non-finite samples"); failures += 1 }
      }
    }

    // Determinism WITHIN this process.
    let a = synth.render(profile: Profiles.all[0], phase: .press, size: .normal, variant: 3)
    let b = synth.render(profile: Profiles.all[0], phase: .press, size: .normal, variant: 3)
    if a != b { print("  FAIL determinism: identical inputs produced different output"); failures += 1 }

    // Determinism ACROSS processes, which is the check that actually mattered and
    // the one this test originally lacked. The pair above passes even when every
    // launch sounds different, because the seed is constant within a run — that
    // is exactly how a per-process String.hashValue seed hid here until the
    // self-test output was md5'd across two runs.
    //
    // Golden values, printed by this same code path and pinned here so a
    // regression is loud rather than invisible. If a deliberate change to the
    // synthesis moves these, update them in the same commit and say so.
    let golden = synth.render(profile: Profiles.find("graphite"), phase: .press,
                              size: .normal, variant: 0)
    var gPeak: Float = 0, gSum: Double = 0
    for v in golden { gPeak = max(gPeak, abs(v)); gSum += Double(v) * Double(v) }
    let gRms = sqrt(gSum / Double(max(golden.count, 1)))
    // Updated deliberately when the impact model gained per-profile band structure,
    // a bottom-out thud and per-profile loudness. The old values (0.7200 / 0.02616 /
    // 13440) were correct for the previous synthesis and the check caught the change
    // on all three axes, which is what it is for.
    let expectPeak = 0.6400, expectRms = 0.02269, expectFrames = 15456
    if abs(Double(gPeak) - expectPeak) > 0.0005 {
      print("  FAIL golden peak: \(gPeak) vs expected \(expectPeak)"); failures += 1
    }
    if abs(gRms - expectRms) > 0.00005 {
      print("  FAIL golden rms: \(gRms) vs expected \(expectRms) — synthesis changed, or the seed is unstable again")
      failures += 1
    }
    if golden.count != expectFrames {
      print("  FAIL golden length: \(golden.count) frames vs expected \(expectFrames)"); failures += 1
    }

    // Variants must actually differ, or "randomised pitch" is a lie.
    let c = synth.render(profile: Profiles.all[0], phase: .press, size: .normal, variant: 4)
    if a == c { print("  FAIL variants: variant 3 and 4 are byte-identical"); failures += 1 }

    print(failures == 0
          ? "\nself-test ok: \(Profiles.all.count * 2) voices, all audible, deterministic, variants differ"
          : "\nself-test FAILED with \(failures) problem(s)")
    return failures == 0 ? 0 : 1
  }

  static func spectralCentroid(_ x: [Float], sampleRate: Double) -> Double {
    // Coarse DFT over a log-spaced band set — enough to characterise brightness
    // and to catch a filter that has collapsed to the wrong frequency.
    var num = 0.0, den = 0.0
    var f = 200.0
    while f < sampleRate * 0.45 {
      var re = 0.0, im = 0.0
      let w = 2.0 * Double.pi * f / sampleRate
      for (i, v) in x.enumerated() {
        re += Double(v) * cos(w * Double(i))
        im += Double(v) * sin(w * Double(i))
      }
      let mag = sqrt(re * re + im * im)
      num += mag * f
      den += mag
      f *= 1.12
    }
    return den > 0 ? num / den : 0
  }

  /// Dump one voice as a 16-bit WAV so it can be inspected with other tools.
  static func writeWav(slug: String, phase: Phase, path: String) throws {
    let synth = Synth(sampleRate: sampleRate)
    let s = synth.render(profile: Profiles.find(slug), phase: phase, size: .normal, variant: 0)
    var data = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(s.count * 2)
    data.append(contentsOf: Array("RIFF".utf8)); le32(36 + bytes)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
    le32(UInt32(sampleRate)); le32(UInt32(sampleRate) * 2); le16(2); le16(16)
    data.append(contentsOf: Array("data".utf8)); le32(bytes)
    for v in s { le16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32767))) }
    try data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(s.count) frames, \(Double(s.count) / sampleRate * 1000) ms)")
  }
}
