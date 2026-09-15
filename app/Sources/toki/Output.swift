import CoreAudio
import Foundation

/// What the sound is coming out of, and how to voice for it.
///
/// The same click does not suit both. Built-in laptop speakers are small, sit far
/// from your ears and roll off below ~200 Hz, so they need the low thud pushed to
/// register at all. In-ear Bluetooth is the opposite on every count:
///
///   * bass is boosted by the tuning and coupled directly to your ear canal, so
///     the same thud turns boomy;
///   * lossy Bluetooth codecs smear sharp transients, and this sound is almost
///     nothing BUT a 1.5 ms transient — the worst case for a codec;
///   * a hard per-key stereo pan that is barely noticeable on two speakers a few
///     inches apart becomes keys ping-ponging between your ears.
///
/// Latency is the one thing that cannot be fixed here. Bluetooth audio runs
/// roughly 150-200 ms behind, which for keyboard feedback is the difference
/// between a keypress and an echo of one. No voicing repairs that; only a wired
/// or built-in output does.
enum OutputKind {
  case speakers      // built-in, or anything wired
  case headphones    // Bluetooth / in-ear

  /// Multipliers applied at render time, so the buffers themselves are voiced
  /// rather than a filter sitting on the playback path.
  ///
  /// Tuned through two wrong versions, both worth recording:
  ///
  /// 1. Scaling only the bottom-out thud moved nothing on most switches. On
  ///    thud-light voices the low end comes from the body modes and the low impact
  ///    band instead, so bass measured 102-112% of the speaker voicing — cuts that
  ///    did the opposite of the intent. Every voice feeding a band has to be scaled.
  /// 2. Then it was far too aggressive: bass 63%, mids 75%. That does not read as
  ///    the same switch on different hardware, it reads as a different switch.
  ///
  /// So: the mids carry the identity and are nearly untouched; only the low end,
  /// which in-ear tuning already exaggerates, is pulled back; the stereo is
  /// narrowed rather than halved. Measured result — bass 84-96%, mids 91-95%,
  /// treble 96-101%, log-spectral distance 0.056-0.064.
  /// Round numbers on purpose. The previous values (0.86 / 0.94 / 0.92) looked
  /// derived and were not — they were judgement, and the second digit implied a
  /// precision nobody has. A 1% gain change is ~0.09 dB against a ~1 dB threshold
  /// for noticing a broadband level shift, so that digit is below audibility.
  /// Rounding them moved the measured output by under a percentage point in every
  /// band, which is the proof the digit carried nothing.
  var weightScale: Double { self == .headphones ? 0.85 : 1.0 }  // low impact band
  var thudScale: Double  { self == .headphones ? 0.80 : 1.0 }   // bottom-out
  var bodyScale: Double  { self == .headphones ? 0.95 : 1.0 }   // cavity modes — identity
  var crackScale: Double { self == .headphones ? 1.00 : 1.0 }   // leave the click alone
  var snapScale: Double  { self == .headphones ? 0.90 : 1.0 }   // edge snap, barely
  var panScale: Double   { self == .headphones ? 0.75 : 1.0 }
  var label: String      { self == .headphones ? "Headphones" : "Speakers" }
}

enum OutputPreference: String {
  case auto, speakers, headphones
}

/// Reads the current default output device and watches for changes, so plugging
/// in AirPods re-voices without the user touching anything.
final class OutputWatcher {
  private(set) var kind: OutputKind = .speakers
  private(set) var deviceName: String = "—"
  private(set) var transport: String = "unknown"
  var preference: OutputPreference = .auto { didSet { refresh() } }
  var onChange: ((OutputKind) -> Void)?

  private var listening = false

  init() { refresh(); listen() }

  func refresh() {
    let detected = OutputWatcher.detect()
    deviceName = detected.name
    transport = detected.transport

    let resolved: OutputKind
    switch preference {
    case .speakers:   resolved = .speakers
    case .headphones: resolved = .headphones
    case .auto:       resolved = detected.kind
    }
    if resolved != kind {
      kind = resolved
      onChange?(kind)
    } else {
      kind = resolved
    }
  }

  // MARK: - CoreAudio

  private static func defaultOutputDevice() -> AudioDeviceID? {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                        &addr, 0, nil, &size, &id)
    return st == noErr ? id : nil
  }

  private static func detect() -> (kind: OutputKind, name: String, transport: String) {
    guard let dev = defaultOutputDevice() else { return (.speakers, "—", "none") }

    var t = UInt32(0)
    var tSize = UInt32(MemoryLayout<UInt32>.size)
    var tAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    _ = AudioObjectGetPropertyData(dev, &tAddr, 0, nil, &tSize, &t)

    // Read the name as an Unmanaged<CFString>?, not a CFString. Taking a raw
    // pointer to a CFString variable hands CoreAudio the address of a managed
    // object reference — the compiler warns about it, and it is the kind of thing
    // that works until it corrupts. This form transfers ownership explicitly.
    var cf: Unmanaged<CFString>?
    var nSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var nAddr = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let nameStatus = AudioObjectGetPropertyData(dev, &nAddr, 0, nil, &nSize, &cf)
    let name = (nameStatus == noErr ? cf?.takeRetainedValue() as String? : nil) ?? "—"

    let label: String
    let kind: OutputKind
    switch t {
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
      label = "bluetooth"; kind = .headphones
    case kAudioDeviceTransportTypeBuiltIn:
      label = "builtin"; kind = .speakers
    case kAudioDeviceTransportTypeUSB:
      label = "usb"; kind = .speakers
    case kAudioDeviceTransportTypeAirPlay:
      label = "airplay"; kind = .headphones      // also latent; voice it the same
    case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
      label = "virtual"; kind = .speakers
    default:
      label = "other(\(t))"; kind = .speakers
    }

    // A wired headset on the built-in jack reports builtin, so fall back to the
    // device name for the obvious cases rather than mis-voicing it.
    let lower = name.lowercased()
    if kind == .speakers,
       lower.contains("headphone") || lower.contains("airpod") || lower.contains("earbud") {
      return (.headphones, name, label)
    }
    return (kind, name, label)
  }

  private func listen() {
    guard !listening else { return }
    listening = true
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let me = Unmanaged.passUnretained(self).toOpaque()
    AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &addr, { _, _, _, ctx in
      guard let ctx else { return noErr }
      let w = Unmanaged<OutputWatcher>.fromOpaque(ctx).takeUnretainedValue()
      // Hop to main: the change fires on a CoreAudio thread and re-rendering
      // touches the engine's buffer tables.
      DispatchQueue.main.async { w.refresh() }
      return noErr
    }, me)
  }
}
