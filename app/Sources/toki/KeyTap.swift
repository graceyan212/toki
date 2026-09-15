import ApplicationServices
import Cocoa
import CoreGraphics
import Foundation
import IOKit.hidsystem

/// Global keyboard listener.
///
/// Uses a listen-only CGEventTap, which observes events without modifying or
/// consuming them — nothing is injected, swallowed, or altered, and the tap
/// cannot see anything the system does not already route to the focused app.
///
/// ## Why Input Monitoring and not Accessibility
///
/// A tap that MODIFIES events needs Accessibility. A `.listenOnly` tap needs only
/// **Input Monitoring** (`kTCCServiceListenEvent`). The two are not interchangeable
/// requests: Accessibility can drive other applications, synthesise clicks and read
/// window contents, none of which this app does or can do.
///
/// Asking for Accessibility on a listen-only tap therefore requests strictly more
/// power than the app uses — which quietly contradicts the privacy claim the whole
/// product rests on. The narrow permission is not a detail; it is the claim, made
/// checkable. A user can open Input Monitoring and see that Accessibility is empty.
///
/// Accessibility is still ACCEPTED if present, because it also satisfies the tap and
/// some users granted it to an earlier build. It is never requested.
///
/// Deliberately NOT recorded: no keycode, character, timestamp or sequence is
/// ever stored or written anywhere. Each event is turned into (size, pan) and
/// discarded within the callback. There is no logging path even in debug —
/// a keystroke listener that keeps a buffer is a keylogger regardless of intent.
final class KeyTap {
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?

  var onPress: ((KeySize, Double, Int64) -> Void)?
  var onRelease: ((KeySize, Double, Int64) -> Void)?
  var suppressAutorepeat = true
  var playOnRelease = true
  var enabled = true

  /// Ignore keystrokes that were posted by software rather than typed.
  ///
  /// A programmable mouse or macro key does not send a mouse event — its driver
  /// POSTS a synthetic keystroke (Logi Options+, Karabiner, text expanders and
  /// automation scripts all do this). The tap cannot tell that apart from typing
  /// by keycode, and the result is a keyboard sound firing when the user pressed
  /// no key at all, which reads as the app being broken or listening to things
  /// it shouldn't.
  ///
  /// The discriminator is the event's source PID: an event originating in
  /// hardware carries 0, and one posted by a process carries that process's PID.
  var ignoreSynthetic = true

  /// Ignore window- and space-switching shortcuts.
  ///
  /// Second line of defence, because some drivers inject low enough in the HID
  /// stack to look like hardware (PID 0) and slip past `ignoreSynthetic`. These
  /// keys produce no character, so a typing sound is wrong for them regardless
  /// of where they came from. Deliberately NOT a blanket "ignore Cmd": Cmd-S and
  /// Cmd-C are typed by hand and should still sound.
  var ignoreShortcuts = true

  /// Fires on the first event this tap ever observes, then never again.
  ///
  /// This exists because a permission check is NOT proof the listener works.
  /// `IOHIDCheckAccess` reports what TCC recorded, which is a different question
  /// from whether events actually arrive — and those two disagree in at least
  /// two real cases: a grant that needs a relaunch to take effect, and a tap
  /// created at a level the grant does not cover. Both present identically as
  /// "permission looks fine and the app is silent", which is the single worst
  /// failure mode this app has. Onboarding therefore confirms on OBSERVED
  /// EVENTS, never on the permission check alone.
  ///
  /// Carries no information about the event — it takes no parameters on purpose.
  var onFirstEvent: (() -> Void)?
  private var sawEvent = false

  /// Count of observed events. Aggregate only; no keycode, character or timing.
  private(set) var eventCount = 0

  // MARK: - permission

  enum Permission {
    case granted
    case denied         // explicitly refused, or the checkbox is off
    case undetermined   // never asked — the system prompt is still available

    var isGranted: Bool { self == .granted }
  }

  /// Input Monitoring, as TCC currently records it for THIS code identity.
  static func inputMonitoring() -> Permission {
    switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
    case kIOHIDAccessTypeGranted: return .granted
    case kIOHIDAccessTypeDenied:  return .denied
    default:                      return .undetermined
    }
  }

  /// Accepted if already present, never requested. See the type comment.
  static func hasAccessibility() -> Bool { AXIsProcessTrusted() }

  /// Either grant satisfies a listen-only tap.
  static func hasPermission() -> Bool {
    inputMonitoring().isGranted || hasAccessibility()
  }

  /// Whether THIS app has ever put the system prompt on screen.
  ///
  /// Tracked by us because `IOHIDCheckAccess` cannot be used to answer it.
  /// MEASURED: for an app that has never asked, it reports `Denied`, not
  /// `Unknown` — the same value it reports for a user who actively refused.
  /// Trusting it would greet every brand-new user with "permission declined"
  /// for a prompt they were never shown, which is both false and alarming, and
  /// it is the accusation you least want to open a paid app with.
  private static let askedKey = "didRequestInputMonitoring"
  static var hasEverAsked: Bool {
    UserDefaults.standard.bool(forKey: askedKey)
  }

  /// Shows the system's Input Monitoring prompt — but ONLY the first time.
  ///
  /// After the user has answered once, TCC has a record and this returns false
  /// immediately without showing anything. A UI that calls this and then waits
  /// for a prompt that will never appear looks broken, so callers must treat a
  /// `false` return as "send them to System Settings instead".
  @discardableResult
  static func requestInputMonitoring() -> Bool {
    UserDefaults.standard.set(true, forKey: askedKey)
    return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
  }

  static func openInputMonitoringSettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
  }

  static func openAccessibilitySettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
  }

  private static func open(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }

  /// Quit and relaunch this bundle.
  ///
  /// Needed because macOS does not apply a fresh Input Monitoring grant to an
  /// already-running process — the system says so in its own alert ("will not be
  /// able to monitor input until it is quit and reopened"). Making the user find
  /// and perform that quit is exactly where a first run gets abandoned, so the
  /// app does it itself.
  static func relaunch() {
    let url = Bundle.main.bundleURL
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
      DispatchQueue.main.async { NSApp.terminate(nil) }
    }
  }

  @discardableResult
  func start() -> Bool {
    guard tap == nil else { return true }

    // MEASURED, and it is the opposite of what it looks like: for a `.listenOnly`
    // tap, `CGEvent.tapCreate` SUCCEEDS without permission. It hands back a valid
    // CFMachPort that simply never delivers an event. So a `true` return here
    // means "a port exists", not "the listener works", and nothing in this file
    // can tell the difference.
    //
    // Two consequences the rest of the app depends on:
    //   1. callers must not treat start() == true as proof of anything; only an
    //      observed event proves the listener works (see `onFirstEvent`);
    //   2. calling this without permission is what PROVOKES the system's
    //      "would like to receive keystrokes" prompt — so it must not be called
    //      before the user has been told what is about to be asked and why.

    let mask = (1 << CGEventType.keyDown.rawValue)
             | (1 << CGEventType.keyUp.rawValue)
             | (1 << CGEventType.flagsChanged.rawValue)

    let callback: CGEventTapCallBack = { _, type, event, refcon in
      guard let refcon else { return Unmanaged.passUnretained(event) }
      let me = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
      me.handle(type: type, event: event)
      // Always pass the event through untouched.
      return Unmanaged.passUnretained(event)
    }

    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                    place: .headInsertEventTap,
                                    options: .listenOnly,
                                    eventsOfInterest: CGEventMask(mask),
                                    callback: callback,
                                    userInfo: Unmanaged.passUnretained(self).toOpaque())
    else { return false }

    tap = t
    source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    return true
  }

  func stop() {
    if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
    if let s = source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
    tap = nil
    source = nil
  }

  var isRunning: Bool { tap != nil }

  /// Tracks which modifiers are currently down, so flagsChanged can be resolved
  /// into a press or a release. flagsChanged carries no up/down of its own.
  private var heldFlags: CGEventFlags = []

  private func handle(type: CGEventType, event: CGEvent) {
    // The system disables a tap that takes too long or if input is grabbed;
    // re-enable rather than silently going deaf for the rest of the session.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
      return
    }

    // Counted before the enabled/autorepeat filters below: this is "did the
    // listener receive anything at all", which stays true even with sound muted.
    eventCount += 1
    if !sawEvent {
      sawEvent = true
      DispatchQueue.main.async { [weak self] in self?.onFirstEvent?() }
    }

    guard enabled else { return }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let size = KeySize.of(keyCode: keyCode)
    let pan = KeyTap.pan(for: keyCode)

    switch type {
    case .keyDown:
      // Held keys autorepeat at the system rate; firing on every repeat turns a
      // held key into a machine-gun that no real keyboard makes.
      if suppressAutorepeat, event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
      onPress?(size, pan, keyCode)

    case .keyUp:
      if playOnRelease { onRelease?(size, pan, keyCode) }

    case .flagsChanged:
      let f = event.flags
      let watched: [CGEventFlags] = [.maskShift, .maskControl, .maskAlternate,
                                     .maskCommand, .maskAlphaShift, .maskSecondaryFn]
      var wentDown = false
      var wentUp = false
      for w in watched {
        let now = f.contains(w), before = heldFlags.contains(w)
        if now && !before { wentDown = true }
        if !now && before { wentUp = true }
      }
      heldFlags = f
      if wentDown { onPress?(size, pan, keyCode) }
      else if wentUp, playOnRelease { onRelease?(size, pan, keyCode) }

    default:
      break
    }
  }

  /// Keys that never produce a character, plus window/space navigation.
  static func isShortcut(keyCode: Int64, flags: CGEventFlags) -> Bool {
    if functionRow.contains(keyCode) { return true }
    // Tab and the arrows are ordinary keys on their own — Tab indents, arrows
    // move a cursor — and become window/space switching only with a modifier.
    let navigation: Set<Int64> = [48, 123, 124, 125, 126]   // tab, ← → ↓ ↑
    if navigation.contains(keyCode),
       flags.contains(.maskCommand) || flags.contains(.maskControl)
         || flags.contains(.maskSecondaryFn) {
      return true
    }
    return false
  }

  /// F1–F20 plus Mission Control and Launchpad.
  private static let functionRow: Set<Int64> = [
    122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,   // F1–F12
    105, 107, 113, 106, 64, 79, 80, 90,                        // F13–F20
    160, 131,                                                  // Mission Control, Launchpad
  ]

  /// Approximate horizontal position of each key on a US layout, 0 (left) to
  /// 1 (right), mapped to a stereo pan. Typing drifts across the image the way
  /// it does on a real board instead of arriving dead centre.
  ///
  /// Unmapped keycodes fall back to centre rather than to an arbitrary side:
  /// a wrong pan is more noticeable than no pan.
  static func pan(for keyCode: Int64) -> Double {
    guard let x = columnX[keyCode] else { return 0 }
    return (x * 2.0 - 1.0) * 0.55   // 0.55 keeps it wide but not gimmicky
  }

  private static let columnX: [Int64: Double] = {
    // rows as they sit physically; index within a row -> normalised x
    let rows: [[Int64]] = [
      [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24, 51],           // ` 1..0 - = delete
      [48, 12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42],           // tab q..p [ ] \
      [57, 0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39, 36],                     // caps a..; ' return
      [56, 6, 7, 8, 9, 11, 45, 46, 43, 47, 44, 60],                       // shift z..? shift
      [59, 58, 55, 49, 55, 61, 62],                                       // ctrl opt cmd space cmd fn arrows
    ]
    var map: [Int64: Double] = [:]
    for row in rows {
      let n = max(row.count - 1, 1)
      for (i, code) in row.enumerated() {
        // first mapping wins, so a key appearing twice keeps its leftmost slot
        if map[code] == nil { map[code] = Double(i) / Double(n) }
      }
    }
    // arrows and the numpad sit hard right regardless of row arithmetic
    for code: Int64 in [123, 124, 125, 126] { map[code] = 0.93 }
    for code: Int64 in [82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 65, 67, 69, 75, 78] { map[code] = 0.98 }
    return map
  }()
}
