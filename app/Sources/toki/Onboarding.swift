import Cocoa

/// First-run permission flow.
///
/// ## Why this window exists at all
///
/// The app is `LSUIElement` — no dock icon, no window. That is correct once it
/// works and disastrous before it does: without Input Monitoring the app is
/// completely silent, and a silent sound app is indistinguishable from a broken
/// one, a failed download, or a Mac with the volume muted. The menu-bar item is
/// 16 points wide and the user does not yet know to look at it.
///
/// ## The rule this flow is built on
///
/// **Finish on an observed keystroke, never on a permission check.**
///
/// `IOHIDCheckAccess` reports what TCC recorded. That is a different question
/// from "do events reach this process", and the two disagree in at least two
/// real situations:
///
///   1. a fresh grant that macOS will not apply until the app is relaunched —
///      TCC says granted, `tapCreate` still fails;
///   2. a grant that does not cover the level the tap was created at.
///
/// Both present as "permission looks fine and the app makes no sound". So the
/// last step here is not a checkmark next to a boolean — it is the user typing
/// and the counter moving. If the counter never moves we have caught the exact
/// failure that would otherwise become a refund request.
///
/// Nothing in this window records anything. The counter is incremented from a
/// callback that receives no keycode.
final class OnboardingController: NSWindowController, NSWindowDelegate {

  enum Step {
    case explain      // never asked, or asked and not yet granted
    case denied       // explicitly refused — the system prompt will not return
    case relaunch     // granted, but the listener needs a restart to pick it up
    case listen       // listener installed, waiting to hear a real keystroke
    case done         // heard it
  }

  private let tap: KeyTap
  private var step: Step = .explain
  private var poll: Timer?
  private var onFinish: (() -> Void)?

  /// When we entered `.listen` with permission in hand. Used to notice the
  /// silent-failure case: TCC granted, tap created, and no event ever arrives
  /// because the grant landed after this process started.
  private var listeningSince: Date?

  // palette — matches the landing page
  private static let ink     = NSColor(srgbRed: 0.055, green: 0.059, blue: 0.094, alpha: 1)
  private static let panel   = NSColor(srgbRed: 0.094, green: 0.102, blue: 0.149, alpha: 1)
  private static let mint    = NSColor(srgbRed: 0.549, green: 0.878, blue: 0.784, alpha: 1)
  private static let amber   = NSColor(srgbRed: 1.000, green: 0.812, blue: 0.545, alpha: 1)
  private static let text    = NSColor(white: 0.96, alpha: 1)
  private static let dim     = NSColor(white: 0.62, alpha: 1)

  // views rebuilt per step
  private var root: NSStackView!
  private var eyebrow: NSTextField!
  private var title: NSTextField!
  private var body: NSTextField!
  private var primary: NSButton!
  private var secondary: NSButton!
  private var testBox: NSView!
  private var testField: NSTextField!
  private var counter: NSTextField!
  private var dots: NSStackView!
  private var footer: NSTextField!

  init(tap: KeyTap, onFinish: @escaping () -> Void) {
    self.tap = tap
    self.onFinish = onFinish

    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
                     styleMask: [.titled, .closable, .fullSizeContentView],
                     backing: .buffered, defer: false)
    w.title = "Welcome to Toki"
    w.titlebarAppearsTransparent = true
    w.titleVisibility = .hidden
    w.isMovableByWindowBackground = true
    w.backgroundColor = OnboardingController.ink
    w.appearance = NSAppearance(named: .darkAqua)
    w.center()
    super.init(window: w)
    w.delegate = self
    buildViews()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  // MARK: - presentation

  func present() {
    refreshStep(initial: true)

    // MEASURED: `activate(ignoringOtherApps:)` alone is NOT enough. An
    // LSUIElement app is not a normal activation target, so the window opened
    // behind the editor that had focus — and a first-run window nobody sees is
    // the same as no first-run window, except the user also thinks the app
    // failed to install.
    //
    // Becoming a regular app for the duration is the fix macOS actually
    // supports: it gives Toki a Dock tile and a Cmd-Tab entry while setup is on
    // screen, so the window can take focus and can be found again if the user
    // clicks away mid-flow. We drop back to accessory the moment it closes.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
    window?.orderFrontRegardless()

    // macOS never notifies an app that a TCC grant landed, and the user grants it
    // in a different application entirely. Polling is the only way to notice, and
    // noticing is what makes the window feel alive rather than stuck.
    poll = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
      self?.refreshStep()
    }
  }

  func windowWillClose(_ notification: Notification) {
    poll?.invalidate()
    poll = nil
    // Back to menu-bar-only. Deferred, because flipping the policy while the
    // window is still tearing down leaves an orphaned Dock tile behind.
    DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    onFinish?()
  }

  // MARK: - state machine

  /// Recomputes which step we are on from the real world, every time.
  ///
  /// Deliberately derived rather than advanced by hand: the user can revoke the
  /// grant in System Settings while this window is open, and a hand-advanced
  /// wizard would happily keep showing "all set" while the app went deaf.
  private func refreshStep(initial: Bool = false) {
    let previous = step
    let permitted = KeyTap.hasPermission()

    // Only touch tapCreate once permission exists. Calling it beforehand is what
    // triggers the system's keystroke prompt, which would then appear ON TOP of
    // the explanation the user has not read yet — the system asking first and us
    // explaining second is precisely the order this window exists to prevent.
    let installed = permitted ? (tap.isRunning || tap.start()) : tap.isRunning

    if tap.eventCount > 0 {
      // The only definitive evidence. Checked first so it outranks every proxy.
      step = .done
    } else if !permitted {
      // "Have we asked?" is ours to know; the system API cannot tell us (see
      // KeyTap.hasEverAsked). Anyone who has not been shown the prompt gets the
      // explanation, never the refusal screen.
      step = KeyTap.hasEverAsked ? .denied : .explain
    } else if !installed {
      step = .relaunch
    } else if let since = listeningSince, Date().timeIntervalSince(since) > 7 {
      // Permission granted, port created, and still nothing after seven seconds
      // of an open window asking the user to type. This is the silent failure:
      // a grant made while the process was already running. It reads to the user
      // as "the app is broken", and a restart fixes it.
      step = .relaunch
    } else {
      step = .listen
    }

    if step == .listen && listeningSince == nil { listeningSince = Date() }
    if step != .listen { listeningSince = nil }

    if step != previous || initial { render() }
    if step == .listen { updateCounter() }
  }

  // MARK: - view construction

  private func buildViews() {
    guard let content = window?.contentView else { return }
    content.wantsLayer = true

    eyebrow = Self.label("", size: 11, color: Self.mint, weight: .semibold)
    eyebrow.alignment = .center
    title = Self.label("", size: 26, color: Self.text, weight: .bold)
    title.alignment = .center
    title.maximumNumberOfLines = 3
    body = Self.label("", size: 13.5, color: Self.dim, weight: .regular)
    body.alignment = .center
    body.maximumNumberOfLines = 8

    primary = Self.button("", action: #selector(primaryTapped))
    primary.target = self
    secondary = Self.linkButton("", action: #selector(secondaryTapped))
    secondary.target = self

    buildTestBox()

    footer = Self.label("", size: 11, color: NSColor(white: 0.42, alpha: 1), weight: .regular)
    footer.alignment = .center
    footer.maximumNumberOfLines = 3

    root = NSStackView(views: [eyebrow, title, body, testBox, primary, secondary, footer])
    root.orientation = .vertical
    root.alignment = .centerX
    root.spacing = 14
    root.translatesAutoresizingMaskIntoConstraints = false
    root.setCustomSpacing(8, after: eyebrow)
    root.setCustomSpacing(18, after: body)
    root.setCustomSpacing(22, after: testBox)
    root.setCustomSpacing(10, after: primary)
    root.setCustomSpacing(26, after: secondary)
    content.addSubview(root)

    NSLayoutConstraint.activate([
      root.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: 6),
      root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 44),
      root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -44),
    ])
  }

  /// The proof panel: a field to type into and a counter that moves.
  private func buildTestBox() {
    testBox = NSView()
    testBox.wantsLayer = true
    testBox.layer?.backgroundColor = Self.panel.cgColor
    testBox.layer?.cornerRadius = 12
    testBox.layer?.borderWidth = 1
    testBox.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
    testBox.translatesAutoresizingMaskIntoConstraints = false

    testField = NSTextField()
    testField.placeholderString = "type here…"
    testField.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)
    testField.alignment = .center
    testField.isBordered = false
    testField.drawsBackground = false
    testField.textColor = Self.text
    testField.focusRingType = .none
    testField.translatesAutoresizingMaskIntoConstraints = false

    dots = NSStackView()
    dots.orientation = .horizontal
    dots.spacing = 7
    dots.translatesAutoresizingMaskIntoConstraints = false
    for _ in 0..<8 {
      let d = NSView()
      d.wantsLayer = true
      d.layer?.cornerRadius = 3.5
      d.layer?.backgroundColor = NSColor(white: 1, alpha: 0.13).cgColor
      d.translatesAutoresizingMaskIntoConstraints = false
      d.widthAnchor.constraint(equalToConstant: 7).isActive = true
      d.heightAnchor.constraint(equalToConstant: 7).isActive = true
      dots.addArrangedSubview(d)
    }

    counter = Self.label("", size: 11, color: Self.dim, weight: .medium)
    counter.alignment = .center

    let inner = NSStackView(views: [testField, dots, counter])
    inner.orientation = .vertical
    inner.alignment = .centerX
    inner.spacing = 12
    inner.translatesAutoresizingMaskIntoConstraints = false
    testBox.addSubview(inner)

    NSLayoutConstraint.activate([
      testBox.widthAnchor.constraint(equalToConstant: 440),
      testBox.heightAnchor.constraint(equalToConstant: 132),
      inner.centerXAnchor.constraint(equalTo: testBox.centerXAnchor),
      inner.centerYAnchor.constraint(equalTo: testBox.centerYAnchor),
      testField.widthAnchor.constraint(equalToConstant: 380),
    ])
  }

  // MARK: - rendering one step

  private func render() {
    switch step {

    case .explain:
      eyebrow.stringValue = "ONE STEP LEFT"
      title.stringValue = "Let Toki hear your keyboard"
      body.stringValue = """
        macOS asks before any app can watch for keystrokes — as it should. Toki needs \
        Input Monitoring, which lets it know that a key moved and nothing else.

        It is not Accessibility. Toki cannot read your screen, control other apps, or \
        see what you type. It gets "a key went down", turns that into a sound, and \
        forgets it.
        """
      primary.title = "Grant Input Monitoring"
      setPrimaryTint(Self.mint)
      secondary.title = "What exactly does this let Toki do?"
      showTestBox(false)
      footer.stringValue = "Nothing is stored, logged, or sent anywhere. Toki has no network code."

    case .denied:
      eyebrow.stringValue = "ONE SWITCH TO FLIP"
      title.stringValue = "Turn Toki on\nin System Settings"
      body.stringValue = """
        macOS only offers that prompt once, so from here it has to be switched on \
        by hand. It takes about five seconds.

        The button below opens the exact pane — Privacy & Security → Input \
        Monitoring. Find Toki in the list and turn it on.
        """
      primary.title = "Open Input Monitoring Settings"
      setPrimaryTint(Self.amber)
      secondary.title = "Toki isn't in the list — show me the app"
      showTestBox(false)
      footer.stringValue = "Turn Toki on, then come back here. This window notices on its own."

    case .relaunch:
      eyebrow.stringValue = "ALMOST THERE"
      title.stringValue = "Toki needs to restart"
      body.stringValue = """
        Permission granted — thank you. macOS doesn't hand a running app a new \
        Input Monitoring grant, so Toki has to open again to pick it up.

        Takes about a second, and it's the last thing.
        """
      primary.title = "Restart Toki"
      setPrimaryTint(Self.mint)
      secondary.title = ""
      showTestBox(false)
      footer.stringValue = "Your settings are saved."

    case .listen:
      eyebrow.stringValue = "LAST THING"
      title.stringValue = "Type something"
      body.stringValue = "Toki is listening. Type below — or anywhere at all — and you should hear it."
      primary.title = ""
      secondary.title = "I don't hear anything"
      showTestBox(true)
      footer.stringValue = "Counting keystrokes only. No key, character or timing is recorded."
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.window?.makeFirstResponder(self.testField)
      }

    case .done:
      eyebrow.stringValue = "YOU'RE ALL SET"
      title.stringValue = "That's it."
      body.stringValue = """
        Toki lives in your menu bar — the keyboard icon up there. Seven switches, \
        volume, and a mute toggle are all in that menu.

        Close this window and just type.
        """
      primary.title = "Start typing"
      setPrimaryTint(Self.mint)
      secondary.title = "Open the menu for me"
      showTestBox(false)
      footer.stringValue = "Toki is listen-only. Nothing you type is stored or sent."
    }

    primary.isHidden = primary.title.isEmpty
    secondary.isHidden = secondary.title.isEmpty
  }

  private func showTestBox(_ visible: Bool) {
    testBox.isHidden = !visible
  }

  private func updateCounter() {
    let n = tap.eventCount
    counter.stringValue = n == 0
      ? "waiting for a keystroke"
      : "\(n) keystroke\(n == 1 ? "" : "s") heard · nothing recorded"
    for (i, d) in dots.arrangedSubviews.enumerated() {
      let lit = n > i
      d.layer?.backgroundColor = lit
        ? Self.mint.withAlphaComponent(0.9).cgColor
        : NSColor(white: 1, alpha: 0.13).cgColor
    }
  }

  private func setPrimaryTint(_ color: NSColor) {
    primary.bezelColor = color
    primary.contentTintColor = Self.ink
  }

  // MARK: - actions

  @objc private func primaryTapped() {
    switch step {
    case .explain:
      // Ask the system first. If TCC already has an answer on file it returns
      // false WITHOUT showing anything — so falling through to System Settings
      // is mandatory, not a nicety. A button that silently does nothing is how
      // a first run gets abandoned.
      if !KeyTap.requestInputMonitoring() {
        KeyTap.openInputMonitoringSettings()
      }
    case .denied:
      KeyTap.openInputMonitoringSettings()
    case .relaunch:
      KeyTap.relaunch()
    case .listen:
      break
    case .done:
      window?.close()
    }
    refreshStep()
  }

  @objc private func secondaryTapped() {
    switch step {
    case .explain:
      showPrivacyDetail()
    case .denied:
      // The genuinely stuck case: the pane is open but Toki is not listed, so
      // there is nothing to switch on. The + button needs a file to point at,
      // and a Finder window already showing it is the shortest path from "I am
      // stuck" to "done" — far shorter than describing a path to type.
      NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    case .listen:
      showTroubleshooting()
    case .done:
      window?.close()
    default:
      break
    }
  }

  private func showPrivacyDetail() {
    let a = NSAlert()
    a.messageText = "What Input Monitoring gives Toki"
    a.informativeText = """
      Toki installs what macOS calls a listen-only event tap. It observes that a key \
      moved. It cannot modify, block, or inject a keystroke, and it cannot see \
      anything the system doesn't already send to the app you're typing in. macOS \
      hides password fields from every app, including this one.

      Each keystroke becomes two numbers — how big the key is, and where it sits on \
      the board, so the sound has the right weight and lands in the right ear. Those \
      two numbers go to the synthesiser and are gone. There is no buffer, no log file, \
      and no debug mode that records them.

      Toki contains no networking code, so there is nowhere for anything to go.

      This is why Toki asks for Input Monitoring and not Accessibility. Accessibility \
      would let it read windows and control other apps. Toki doesn't need that, so it \
      doesn't ask — you can check that its Accessibility entry is empty.
      """
    a.addButton(withTitle: "Got it")
    a.alertStyle = .informational
    a.beginSheetModal(for: window!) { _ in }
  }

  private func showTroubleshooting() {
    let a = NSAlert()
    a.messageText = "No sound?"
    a.informativeText = """
      Three things, in the order worth trying:

      1. Check your Mac's volume, and that sound isn't going to a device you're not \
      wearing. Toki plays through whatever your Mac is using.

      2. Make sure Toki is switched on in System Settings → Privacy & Security → \
      Input Monitoring, and that it's this copy of Toki — a second copy in a \
      different folder counts as a different app to macOS.

      3. Restart Toki. A permission granted while the app was running doesn't take \
      effect until it reopens.

      If the counter above is moving, Toki is hearing you and the problem is audio \
      output, not permission.
      """
    a.addButton(withTitle: "Close")
    a.addButton(withTitle: "Open Input Monitoring")
    a.addButton(withTitle: "Restart Toki")
    a.alertStyle = .informational
    a.beginSheetModal(for: window!) { r in
      if r == .alertSecondButtonReturn { KeyTap.openInputMonitoringSettings() }
      if r == .alertThirdButtonReturn { KeyTap.relaunch() }
    }
  }

  // MARK: - small view helpers

  private static func label(_ s: String, size: CGFloat, color: NSColor,
                            weight: NSFont.Weight) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byWordWrapping
    l.maximumNumberOfLines = 0
    l.translatesAutoresizingMaskIntoConstraints = false
    l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return l
  }

  private static func button(_ s: String, action: Selector) -> NSButton {
    let b = NSButton(title: s, target: nil, action: action)
    b.bezelStyle = .rounded
    b.controlSize = .large
    b.font = .systemFont(ofSize: 14, weight: .semibold)
    b.translatesAutoresizingMaskIntoConstraints = false
    b.heightAnchor.constraint(equalToConstant: 36).isActive = true
    return b
  }

  private static func linkButton(_ s: String, action: Selector) -> NSButton {
    let b = NSButton(title: s, target: nil, action: action)
    b.isBordered = false
    b.font = .systemFont(ofSize: 12, weight: .regular)
    b.contentTintColor = OnboardingController.dim
    b.translatesAutoresizingMaskIntoConstraints = false
    return b
  }
}
