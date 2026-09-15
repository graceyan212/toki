import Cocoa
import ServiceManagement

/// The whole UI: one status-bar item and a menu. No window, no dock icon.
final class MenuBarController: NSObject, NSMenuDelegate {
  private let item: NSStatusItem
  private let engine: Engine
  private let tap: KeyTap
  private let output: OutputWatcher
  private let defaults = UserDefaults.standard

  /// Set by the app delegate; reopens the first-run window.
  var onOpenSetup: (() -> Void)?

  private enum Key {
    static let profile = "profile"
    static let volume = "volume"
    static let enabled = "enabled"
    static let onRelease = "playOnRelease"
    static let autorepeat = "suppressAutorepeat"
    static let spatial = "spatial"
    static let ignoreSynthetic = "ignoreSynthetic"
    static let ignoreShortcuts = "ignoreShortcuts"
  }

  init(engine: Engine, tap: KeyTap, output: OutputWatcher) {
    self.engine = engine
    self.tap = tap
    self.output = output
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()

    if let button = item.button {
      MenuBarController.applyIcon(to: button, active: true)
      button.toolTip = "Toki — synthesised keyboard sound"
    }

    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
    rebuildMenu()
  }

  // MARK: - persisted settings

  private var enabled: Bool {
    get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.enabled); apply() }
  }
  private var playOnRelease: Bool {
    get { defaults.object(forKey: Key.onRelease) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.onRelease); apply() }
  }
  private var suppressAutorepeat: Bool {
    get { defaults.object(forKey: Key.autorepeat) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.autorepeat); apply() }
  }
  private var spatial: Bool {
    get { defaults.object(forKey: Key.spatial) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.spatial); apply() }
  }
  private var ignoreSynthetic: Bool {
    get { defaults.object(forKey: Key.ignoreSynthetic) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.ignoreSynthetic); apply() }
  }
  private var ignoreShortcuts: Bool {
    get { defaults.object(forKey: Key.ignoreShortcuts) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.ignoreShortcuts); apply() }
  }
  private var volume: Double {
    get { defaults.object(forKey: Key.volume) as? Double ?? 0.63 }
    set { defaults.set(newValue, forKey: Key.volume); apply() }
  }
  private var profileSlug: String {
    get { defaults.string(forKey: Key.profile) ?? Profiles.defaultSlug }
    set { defaults.set(newValue, forKey: Key.profile) }
  }

  func loadSettings() {
    engine.volume = volume
    engine.spatial = spatial
    engine.rebuild(profile: Profiles.find(profileSlug))
    apply()
  }

  private func apply() {
    tap.enabled = enabled
    tap.playOnRelease = playOnRelease
    tap.suppressAutorepeat = suppressAutorepeat
    tap.ignoreSynthetic = ignoreSynthetic
    tap.ignoreShortcuts = ignoreShortcuts
    engine.volume = volume
    engine.spatial = spatial
    MenuBarController.applyIcon(to: item.button!, active: enabled && tap.isRunning)
    item.button?.image?.isTemplate = true
    rebuildMenu()
  }

  // MARK: - menu

  func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

  private func rebuildMenu() {
    guard let menu = item.menu else { return }
    menu.removeAllItems()

    // Permission state first — without it nothing else in here matters, and a
    // silent app with no explanation is the worst possible failure mode.
    // Distinguish the two failures rather than collapsing them. "Not permitted"
    // and "permitted but not receiving" need different actions from the user, and
    // showing the wrong one sends them to a settings pane that already looks
    // correct — the most demoralising possible dead end.
    if !tap.isRunning {
      let granted = KeyTap.hasPermission()
      let warn = NSMenuItem(
        title: granted ? "Permission granted — needs a restart" : "Toki can't hear your keyboard",
        action: nil, keyEquivalent: "")
      warn.isEnabled = false
      menu.addItem(warn)
      menu.addItem(withTitle: granted ? "Restart Toki" : "Set up Toki…",
                   action: granted ? #selector(relaunchApp) : #selector(openSetup),
                   keyEquivalent: "").target = self
      menu.addItem(withTitle: "Open Input Monitoring settings…",
                   action: #selector(openSettings), keyEquivalent: "").target = self
      menu.addItem(.separator())
    }

    let toggle = NSMenuItem(title: enabled ? "Sound on" : "Sound off",
                            action: #selector(toggleEnabled), keyEquivalent: "")
    toggle.state = enabled ? .on : .off
    toggle.target = self
    menu.addItem(toggle)
    menu.addItem(.separator())

    // switches, grouped by family
    let switchesItem = NSMenuItem(title: "Switch", action: nil, keyEquivalent: "")
    let switches = NSMenu()
    // Grouped here rather than by reordering Profiles.all, because that array's
    // order is dull -> bright and is relied on elsewhere (the landing page walks
    // it in that order). Families are listed in a fixed order so the menu does
    // not reshuffle if a profile is added.
    var first = true
    for family in ["Linear", "Tactile", "Clicky"] {
      let inFamily = Profiles.all.filter { $0.family == family }
      guard !inFamily.isEmpty else { continue }
      if !first { switches.addItem(.separator()) }
      first = false
      let header = NSMenuItem(title: family, action: nil, keyEquivalent: "")
      header.isEnabled = false
      switches.addItem(header)
      for p in inFamily {
        let mi = NSMenuItem(title: "   " + p.name, action: #selector(pickProfile(_:)), keyEquivalent: "")
        mi.representedObject = p.slug
        mi.state = (p.slug == profileSlug) ? .on : .off
        mi.target = self
        switches.addItem(mi)
      }
    }
    // Nominative framing, stated where the names are actually read.
    //
    // The switch names are the selling point — "Cherry MX Blue" tells a buyer
    // exactly what they are getting and an invented name tells them nothing.
    // What carries risk is not naming them, it is implying these ARE those
    // products. This line does the separating, costs nothing, and is the
    // standard mitigation: refer to the mark to describe what you modelled,
    // claim no affiliation.
    switches.addItem(.separator())
    let note = NSMenuItem(title: "Original emulations — no affiliation or endorsement",
                          action: nil, keyEquivalent: "")
    note.isEnabled = false
    switches.addItem(note)

    switchesItem.submenu = switches
    menu.addItem(switchesItem)

    // volume
    let volItem = NSMenuItem(title: "Volume", action: nil, keyEquivalent: "")
    let vol = NSMenu()
    for v in [0.15, 0.3, 0.45, 0.63, 0.8, 1.0] {
      let mi = NSMenuItem(title: "   \(Int(v * 100))%", action: #selector(pickVolume(_:)), keyEquivalent: "")
      mi.representedObject = v
      mi.state = abs(v - volume) < 0.01 ? .on : .off
      mi.target = self
      vol.addItem(mi)
    }
    volItem.submenu = vol
    menu.addItem(volItem)
    menu.addItem(.separator())

    let rel = NSMenuItem(title: "Key-up sound", action: #selector(toggleRelease), keyEquivalent: "")
    rel.state = playOnRelease ? .on : .off
    rel.target = self
    menu.addItem(rel)

    let rep = NSMenuItem(title: "Mute key repeat", action: #selector(toggleAutorepeat), keyEquivalent: "")
    rep.state = suppressAutorepeat ? .on : .off
    rep.target = self
    menu.addItem(rep)

    // Both default ON. A sound firing when no key was pressed is the kind of
    // wrongness a user notices immediately and cannot explain, so the quiet
    // behaviour is the default and the noisy one is opt-in.
    let syn = NSMenuItem(title: "Ignore remapped mouse & macro keys",
                         action: #selector(toggleSynthetic), keyEquivalent: "")
    syn.state = ignoreSynthetic ? .on : .off
    syn.toolTip = "Programmable mouse buttons and text expanders post keystrokes that "
                + "you never typed. With this on, Toki stays silent for them."
    syn.target = self
    menu.addItem(syn)

    let shortcut = NSMenuItem(title: "Ignore window & space shortcuts",
                              action: #selector(toggleShortcuts), keyEquivalent: "")
    shortcut.state = ignoreShortcuts ? .on : .off
    shortcut.toolTip = "Function keys, Mission Control, and Tab or arrows held with "
                     + "Command or Control. Typing shortcuts like Command-S still sound."
    shortcut.target = self
    menu.addItem(shortcut)

    // Output voicing. Auto covers almost everyone; the override exists because
    // "wired headset on the built-in jack" is indistinguishable from speakers to
    // CoreAudio, so detection cannot be right every time.
    let outItem = NSMenuItem(title: "Tuned for", action: nil, keyEquivalent: "")
    let outMenu = NSMenu()
    let detected = NSMenuItem(title: "   \(output.deviceName) — \(output.kind.label)",
                              action: nil, keyEquivalent: "")
    detected.isEnabled = false
    outMenu.addItem(detected)
    outMenu.addItem(.separator())
    for (title, pref) in [("Automatic", OutputPreference.auto),
                          ("Speakers", .speakers),
                          ("Headphones", .headphones)] {
      let mi = NSMenuItem(title: "   " + title, action: #selector(pickOutput(_:)), keyEquivalent: "")
      mi.representedObject = pref.rawValue
      mi.state = (output.preference == pref) ? .on : .off
      mi.target = self
      outMenu.addItem(mi)
    }
    outItem.submenu = outMenu
    menu.addItem(outItem)

    // Launch at login, via SMAppService (macOS 13+). This replaced a LaunchAgent
    // plist installed by a shell script: the plist hard-coded an absolute path to
    // the app, so moving Toki — including the drag from the DMG into
    // /Applications that every user performs — left a login item pointing at
    // nothing, failing silently every boot. SMAppService registers the bundle
    // itself and macOS tracks it, and the user can see and revoke it in
    // System Settings > General > Login Items.
    let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLoginItem), keyEquivalent: "")
    login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    login.target = self
    menu.addItem(login)

    let sp = NSMenuItem(title: "Stereo by key position", action: #selector(toggleSpatial), keyEquivalent: "")
    sp.state = spatial ? .on : .off
    sp.target = self
    menu.addItem(sp)
    menu.addItem(.separator())

    menu.addItem(withTitle: "Test sound", action: #selector(testSound), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Set up Toki…", action: #selector(openSetup), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Toki", action: #selector(quit), keyEquivalent: "q").target = self
  }

  // MARK: - actions

  @objc private func toggleEnabled() { enabled.toggle() }
  @objc private func toggleRelease() { playOnRelease.toggle() }
  @objc private func toggleAutorepeat() { suppressAutorepeat.toggle() }
  @objc private func toggleSpatial() { spatial.toggle() }
  @objc private func toggleSynthetic() { ignoreSynthetic.toggle() }
  @objc private func toggleShortcuts() { ignoreShortcuts.toggle() }
  @objc private func openSettings() { KeyTap.openInputMonitoringSettings() }
  @objc private func openSetup() { onOpenSetup?() }

  @objc private func toggleLoginItem() {
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
    } catch {
      // Surfaced rather than swallowed: this fails for a real, actionable reason
      // — an unsigned or quarantined bundle — and a checkbox that silently
      // refuses to stay checked is maddening.
      let a = NSAlert()
      a.messageText = "Couldn't change the login item"
      a.informativeText = """
        \(error.localizedDescription)

        This usually means Toki is running from somewhere macOS won't register, \
        such as the disk image itself or the Downloads folder. Move Toki to your \
        Applications folder and try again.
        """
      a.alertStyle = .warning
      a.runModal()
    }
    rebuildMenu()
  }
  @objc private func relaunchApp() { KeyTap.relaunch() }
  @objc private func quit() { NSApp.terminate(nil) }

  @objc private func retryTap() {
    if !tap.start() { KeyTap.requestInputMonitoring() }
    apply()
  }

  @objc private func pickProfile(_ sender: NSMenuItem) {
    guard let slug = sender.representedObject as? String else { return }
    profileSlug = slug
    engine.rebuild(profile: Profiles.find(slug))
    apply()
    engine.hit(phase: .press, size: .normal, pan: 0, keyCode: 0)
  }

  @objc private func pickOutput(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let pref = OutputPreference(rawValue: raw) else { return }
    defaults.set(raw, forKey: "outputPref")
    output.preference = pref            // triggers refresh -> onChange -> re-render
    engine.output = output.kind
    engine.rebuild(profile: engine.profile)
    apply()
    engine.hit(phase: .press, size: .normal, pan: 0, keyCode: 0)
  }

  @objc private func pickVolume(_ sender: NSMenuItem) {
    guard let v = sender.representedObject as? Double else { return }
    volume = v
    engine.hit(phase: .press, size: .normal, pan: 0, keyCode: 0)
  }

  @objc private func testSound() {
    // A short run across the board so the stereo image is audible, not a
    // single click that proves less than it seems to.
    let pans: [Double] = [-0.5, -0.2, 0.1, 0.4, 0.0]
    for (i, pan) in pans.enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.11) { [weak self] in
        self?.engine.hit(phase: .press, size: i == 4 ? .space : .normal, pan: pan, keyCode: Int64(i * 7))
      }
    }
  }

  /// Sets the status-bar button's appearance.
  ///
  /// Uses an SF Symbol first and falls back to a text glyph. The original
  /// hand-drawn icon was the reason the item was INVISIBLE: a variable-length
  /// status item whose image renders empty collapses to a sliver, so the app
  /// appeared not to launch at all — double-clicking it did nothing visible
  /// because there was nothing on screen to click. Always give the button a
  /// title as well, so a failed image can never leave it unfindable.
  static func applyIcon(to button: NSStatusBarButton, active: Bool) {
    let symbol = active ? "keyboard.fill" : "keyboard"
    if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Toki") {
      img.isTemplate = true
      button.image = img
      button.imagePosition = .imageLeading
      button.title = ""
    } else {
      button.image = nil
      button.title = active ? "⌨" : "⌨̶"
    }
    button.alphaValue = active ? 1.0 : 0.55
  }

  /// Kept as a fallback for systems without the symbol: three keycaps, middle struck.
  private static func icon(active: Bool) -> NSImage {
    let size = NSSize(width: 18, height: 14)
    let img = NSImage(size: size, flipped: false) { _ in
      let ctx = NSGraphicsContext.current!.cgContext
      ctx.setLineWidth(1.3)
      ctx.setStrokeColor(NSColor.black.cgColor)
      ctx.setFillColor(NSColor.black.cgColor)
      let caps = [CGRect(x: 1.0, y: 2.0, width: 4.6, height: 4.6),
                  CGRect(x: 6.7, y: 2.0, width: 4.6, height: 4.6),
                  CGRect(x: 12.4, y: 2.0, width: 4.6, height: 4.6)]
      for (i, r) in caps.enumerated() {
        let p = CGPath(roundedRect: r, cornerWidth: 1.2, cornerHeight: 1.2, transform: nil)
        ctx.addPath(p)
        if i == 1 && active { ctx.fillPath() } else { ctx.strokePath() }
      }
      if active {
        // two short sound arcs off the struck cap
        for (i, dy) in [(0, 2.2), (1, 4.0)] {
          ctx.setLineWidth(1.1 - Double(i) * 0.25)
          ctx.addArc(center: CGPoint(x: 9.0, y: 7.2), radius: dy,
                     startAngle: .pi * 0.18, endAngle: .pi * 0.82, clockwise: false)
          ctx.strokePath()
        }
      }
      return true
    }
    img.isTemplate = true
    return img
  }
}
