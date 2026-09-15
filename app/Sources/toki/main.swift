import Cocoa
import Foundation

// ---------------------------------------------------------------------------
// Headless modes first, so the synthesiser can be verified without an audio
// device, a display, or a permission grant. A sound generator that outputs
// silence is indistinguishable from a working one until someone listens, so
// there has to be a way to assert on level rather than trust it.
// ---------------------------------------------------------------------------
let args = CommandLine.arguments

if args.contains("--self-test") {
  exit(Engine.selfTest())
}

if let i = args.firstIndex(of: "--wav-voicing") {
  // Writes the same burst of typing in both voicings so the difference can be
  // judged by ear, which is the only instrument that actually settles this.
  let slug = i + 1 < args.count ? args[i + 1] : Profiles.defaultSlug
  let p = Profiles.find(slug)
  let synth = Synth(sampleRate: 48000)
  for (name, kind) in [("speakers", OutputKind.speakers), ("headphones", OutputKind.headphones)] {
    var out = [Float](repeating: 0, count: 48000 * 2)
    for k in 0..<10 {
      let at = Int((0.06 + Double(k) * 0.17) * 48000)
      let refH = kind == .speakers ? nil : synth.speakerPeak(profile: p, phase: .press, size: .normal, variant: k % 16)
      let hit = synth.render(profile: p, phase: .press, size: .normal, variant: k % 16, output: kind, normaliseAgainst: refH)
      for (j, v) in hit.enumerated() where at + j < out.count { out[at + j] += v * 0.85 }
      let refR = kind == .speakers ? nil : synth.speakerPeak(profile: p, phase: .release, size: .normal, variant: (k + 3) % 16)
      let rel = synth.render(profile: p, phase: .release, size: .normal, variant: (k + 3) % 16, output: kind, normaliseAgainst: refR)
      let at2 = at + Int(0.085 * 48000)
      for (j, v) in rel.enumerated() where at2 + j < out.count { out[at2 + j] += v * 0.85 }
    }
    let path = "/tmp/toki-\(slug)-\(name).wav"
    var d = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let bytes = UInt32(out.count * 2)
    d.append(contentsOf: Array("RIFF".utf8)); le32(36 + bytes)
    d.append(contentsOf: Array("WAVE".utf8)); d.append(contentsOf: Array("fmt ".utf8))
    le32(16); le16(1); le16(1); le32(48000); le32(96000); le16(2); le16(16)
    d.append(contentsOf: Array("data".utf8)); le32(bytes)
    for v in out { le16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32767))) }
    try? d.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
  }
  exit(0)
}

if args.contains("--output-test") {
  // Proves the manual override actually resolves, rather than assuming it does.
  let w = OutputWatcher()
  print("detected device : \(w.deviceName)  transport: \(w.transport)")
  for pref in [OutputPreference.auto, .speakers, .headphones] {
    w.preference = pref
    print("  preference \(pref.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) -> voicing \(w.kind.label)")
  }
  exit(0)
}

if args.contains("--voicing") {
  Engine.voicingReport()
  exit(0)
}

if args.contains("--list") {
  for p in Profiles.all {
    print("\(p.slug.padding(toLength: 12, withPad: " ", startingAt: 0))\(p.family)\t\(p.name)")
  }
  exit(0)
}

if let i = args.firstIndex(of: "--wav") {
  let slug = i + 1 < args.count ? args[i + 1] : Profiles.defaultSlug
  let out = i + 2 < args.count ? args[i + 2] : "/tmp/toki-\(slug).wav"
  do {
    try Engine.writeWav(slug: slug, phase: .press, path: out)
    try Engine.writeWav(slug: slug, phase: .release,
                        path: out.replacingOccurrences(of: ".wav", with: "-up.wav"))
    exit(0)
  } catch {
    FileHandle.standardError.write("failed to write wav: \(error)\n".data(using: .utf8)!)
    exit(1)
  }
}

if args.contains("--diag") {
  // Proves the listener is actually installed and receiving, which the menu-bar
  // app cannot show — there is deliberately no logging path in it.
  //
  // Prints AGGREGATE COUNTS ONLY: never a keycode, character or timing. That
  // distinction is the point. A diagnostic that dumped keycodes would make this
  // a keylogger with a friendly flag name, and "it was only for debugging" is
  // not a property the binary has.
  let seconds = 6.0
  print("Input Monitoring : \(KeyTap.inputMonitoring())")
  print("Accessibility    : \(KeyTap.hasAccessibility() ? "granted" : "not granted") (accepted if present, never requested)")
  guard KeyTap.hasPermission() else {
    print("Grant it in System Settings > Privacy & Security > Input Monitoring, then re-run.")
    exit(2)
  }
  let tap = KeyTap()
  var presses = 0, releases = 0
  var bySize: [String: Int] = [:]
  tap.onPress = { size, _, _ in
    presses += 1
    let k = "\(size)"
    bySize[k, default: 0] += 1
  }
  tap.onRelease = { _, _, _ in releases += 1 }

  guard tap.start() else {
    print("FAIL: tap did not install despite permission being granted.")
    exit(1)
  }
  // --synthetic posts real CGEvents into the session so the tap's wiring can be
  // verified without a human at the keyboard. This distinguishes two failures
  // that look identical from the outside: "my tap is misconfigured" and "the
  // injection method I tested with does not traverse session taps".
  // AppleScript's `keystroke` is the latter — it drives the focused app through
  // accessibility APIs rather than posting to the event stream, so a correct tap
  // still sees nothing.
  if args.contains("--synthetic") {
    print("posting 4 synthetic key events into the session…")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
      let src = CGEventSource(stateID: .hidSystemState)
      for code: CGKeyCode in [0, 1, 49] {   // two letters and space
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?
          .post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?
          .post(tap: .cghidEventTap)
        usleep(60_000)
      }
    }
  } else {
    print("listener installed — type anywhere for \(Int(seconds))s (counts only, nothing recorded)")
  }
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
  }
  tap.stop()
  print("presses=\(presses) releases=\(releases) byKeySize=\(bySize)")
  if presses == 0 {
    print("FAIL: zero events observed. The tap installed but received nothing.")
    exit(1)
  }
  print("ok: listener is receiving events")
  exit(0)
}

if args.contains("--diag-audio") {
  // Measures the LIVE playback path, not the renderer. --self-test proves the
  // synthesiser produces samples; it says nothing about whether AVAudioEngine
  // started, whether the buffers reach the output bus, or whether the mixer is
  // at zero. Those all present identically as "I hear nothing".
  //
  // Method: install a tap on the engine's output bus and measure the peak of
  // what actually gets rendered. A non-zero peak means audio is leaving the app
  // and the problem is downstream (routing, device, system volume). Zero means
  // the fault is inside.
  let engine = Engine(profile: Profiles.find(Profiles.defaultSlug))
  do { try engine.start() } catch {
    print("FAIL: engine.start() threw: \(error)")
    exit(1)
  }
  print("engine.isRunning = \(engine.isRunning)")
  guard engine.isRunning else {
    print("FAIL: engine did not start — nothing can be audible.")
    exit(1)
  }
  var peak: Float = 0
  var frames = 0
  engine.installOutputMeter { p, n in
    peak = max(peak, p)
    frames += n
  }
  print("firing 6 hits…")
  for i in 0..<6 {
    engine.hit(phase: .press, size: i == 5 ? .space : .normal, pan: 0, keyCode: Int64(i))
    usleep(120_000)
  }
  usleep(400_000)
  engine.removeOutputMeter()
  print("output bus: framesObserved=\(frames) peak=\(String(format: "%.5f", peak))")
  if frames == 0 {
    print("FAIL: the output bus rendered no frames at all.")
    exit(1)
  }
  if peak < 0.001 {
    print("FAIL: frames rendered but peak is ~0 — buffers are not reaching the mixer, or a gain is zero.")
    exit(1)
  }
  print("ok: audio is being rendered to the output bus (peak \(String(format: "%.3f", peak)))")
  print("If you still hear nothing, the fault is downstream: output device, per-app")
  print("volume, or the app is not the one you granted permission to.")
  exit(0)
}

if args.contains("--bench") {
  // Times the per-keystroke path, because "this change is free" is a claim and
  // not a measurement. What matters is the cost of hit(): bucket selection,
  // variant choice, and handing a buffer to the engine. Everything expensive
  // (synthesis, filtering, allocation) happens at launch instead.
  let engine = Engine(profile: Profiles.find(Profiles.defaultSlug))
  do { try engine.start() } catch {
    print("bench needs a working audio device: \(error)"); exit(1)
  }
  let iterations = 20_000
  // warm up so first-call effects are not counted
  for i in 0..<500 { engine.hit(phase: .press, size: .normal, pan: 0, keyCode: Int64(i % 80)) }

  var worst = 0.0
  let t0 = DispatchTime.now().uptimeNanoseconds
  for i in 0..<iterations {
    let a = DispatchTime.now().uptimeNanoseconds
    engine.hit(phase: i % 2 == 0 ? .press : .release,
               size: i % 7 == 0 ? .space : .normal,
               pan: Double(i % 21) / 10.0 - 1.0,
               keyCode: Int64(i % 80))
    let d = Double(DispatchTime.now().uptimeNanoseconds - a) / 1000.0
    if d > worst { worst = d }
  }
  let total = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000.0
  let mean = total / Double(iterations)
  print("hit() over \(iterations) calls:")
  print(String(format: "  mean  %.2f us", mean))
  print(String(format: "  worst %.2f us", worst))
  print(String(format: "  a 200 wpm typist issues ~20 keystrokes/sec = %.4f%% of one core",
               mean * 20 / 10_000))
  // For scale: one audio buffer at 48kHz/512 frames is ~10.7ms of wall time.
  print(String(format: "  for scale, one 512-frame audio buffer is 10667 us — hit() is %.0fx smaller",
               10667.0 / max(mean, 0.001)))
  engine.stop()
  exit(0)
}

if args.contains("--help") || args.contains("-h") {
  print("""
  Toki — synthesised mechanical keyboard sound for macOS

    toki                 run as a menu-bar app
    toki --self-test    render every voice and assert it is audible
    toki --list         list switch profiles
    toki --wav <slug> [path]
                         dump a voice to WAV for inspection
    toki --help

  Requires Input Monitoring to observe keystrokes — NOT Accessibility. A
  listen-only tap needs only the narrower grant; it never modifies, consumes or
  injects events, and no keystroke is stored, logged or transmitted anywhere.
  """)
  exit(0)
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var engine: Engine!
  private var tap: KeyTap!
  private var menu: MenuBarController!
  private var output: OutputWatcher!
  private var onboarding: OnboardingController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Accessory: menu-bar only, no dock icon, no window.
    NSApp.setActivationPolicy(.accessory)

    let slug = UserDefaults.standard.string(forKey: "profile") ?? Profiles.defaultSlug
    engine = Engine(profile: Profiles.find(slug))
    tap = KeyTap()

    // Voice for whatever the sound is actually coming out of, and re-voice when
    // that changes — putting in AirPods should not require touching a menu.
    output = OutputWatcher()
    output.preference = OutputPreference(
      rawValue: UserDefaults.standard.string(forKey: "outputPref") ?? "auto") ?? .auto
    engine.output = output.kind
    output.onChange = { [weak self] kind in
      guard let self else { return }
      self.engine.output = kind
      self.engine.rebuild(profile: self.engine.profile)
      self.menu?.loadSettings()
    }

    tap.onPress = { [weak self] size, pan, code in
      self?.engine.hit(phase: .press, size: size, pan: pan, keyCode: code)
    }
    tap.onRelease = { [weak self] size, pan, code in
      self?.engine.hit(phase: .release, size: size, pan: pan, keyCode: code)
    }

    do {
      try engine.start()
    } catch {
      NSLog("Toki: audio engine failed to start: \(error)")
    }

    menu = MenuBarController(engine: engine, tap: tap, output: output)
    menu.onOpenSetup = { [weak self] in self?.showOnboarding() }
    menu.loadSettings()

    // Gated on permission for the same reason the onboarding window is: calling
    // tap.start() without it provokes the system keystroke prompt, and a prompt
    // fired at launch — before any explanation exists on screen — is the one
    // most likely to be denied out of reflex.
    let listening = KeyTap.hasPermission() && tap.start()

    // Show the first-run flow when the listener is not running, and also on a
    // genuine first launch even if it IS running (an Accessibility grant carried
    // over from an older build). A user who never saw an explanation has no idea
    // the menu-bar icon is the app, so they get the window once regardless.
    let seenSetup = UserDefaults.standard.bool(forKey: "didOnboard")
    if !listening || !seenSetup {
      showOnboarding()
    }

    // Independently of the window: macOS never notifies an app that a grant
    // landed, and requiring a restart to notice reads as the app being broken.
    Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
      guard let self else { t.invalidate(); return }
      if self.tap.isRunning { t.invalidate(); return }
      guard KeyTap.hasPermission() else { return }
      if self.tap.start() { self.menu.loadSettings() }
    }
  }

  func showOnboarding() {
    if let existing = onboarding {
      NSApp.activate(ignoringOtherApps: true)
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    let c = OnboardingController(tap: tap) { [weak self] in
      guard let self else { return }
      // Only remember it as seen once the listener actually works. Closing the
      // window while still deaf must NOT count as onboarded, or the user is left
      // with a silent app and no route back to the explanation.
      if self.tap.isRunning && self.tap.eventCount > 0 {
        UserDefaults.standard.set(true, forKey: "didOnboard")
      }
      self.onboarding = nil
      self.menu.loadSettings()
    }
    onboarding = c
    c.present()
  }

  func applicationWillTerminate(_ notification: Notification) {
    tap?.stop()
    engine?.stop()
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
