import AppKit
import EQBarCore

/// Root of the menu bar popover. Created when the popover opens and released when it closes,
/// so the UI costs nothing while it isn't on screen.
final class PopoverViewController: NSViewController {
  private let controller: EQBarController
  private let onLayoutChange: () -> Void

  private let root = NSStackView()
  private var powerSwitch: NSSwitch!
  private var statusLabel: NSTextField!
  private var devicePopup: NSPopUpButton!
  private var formatPopup: NSPopUpButton!
  private var formats: [DeviceFormat] = []
  private var formatKey = ""
  private var bannerContainer = NSStackView()
  private var volumeSlider: NSSlider!
  private var volumeValue: NSTextField!
  private var muteButton: NSButton!
  private var balanceSlider: NSSlider!
  private var tabs: NSSegmentedControl!
  private var gearButton: NSButton!
  private let contentContainer = NSStackView()
  private var content: PanelContent?
  private var observer: NSObjectProtocol?
  private var devices: [OutputDevice] = []

  private static var lastTab = 0
  private let tabTitles = ["EQ", "Spatial", "Mixer", "Plugins"]

  init(controller: EQBarController, onLayoutChange: @escaping () -> Void) {
    self.controller = controller
    self.onLayoutChange = onLayoutChange
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func loadView() {
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 10
    root.edgeInsets = NSEdgeInsets(top: UI.inset, left: UI.inset, bottom: UI.inset, right: UI.inset)
    root.translatesAutoresizingMaskIntoConstraints = false
    root.widthAnchor.constraint(equalToConstant: UI.width).isActive = true
    // Shrink-wrap the content: never spread rows apart to fill extra height.
    root.setHuggingPriority(.required, for: .vertical)

    // Header: power, name/status, output device, settings menu.
    powerSwitch = UI.toggle(controller.settings.enabled) { [weak self] on in self?.controller.setEnabled(on) }
    powerSwitch.toolTip = "Turn EQBar processing on or off"
    let title = UI.label("EQBar", size: 13, weight: .semibold, color: .labelColor)
    statusLabel = UI.label("", size: 10)
    let titleColumn = UI.column([title, statusLabel], spacing: 0)
    devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    devicePopup.controlSize = .small
    devicePopup.font = .systemFont(ofSize: 11)
    devicePopup.toolTip = "Output device"
    devicePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
    devicePopup.onAction { [weak self] in self?.deviceChosen() }
    gearButton = UI.iconButton("gearshape", tooltip: "Settings") { [weak self] in self?.showSettingsMenu() }
    root.addArrangedSubview(UI.fill(UI.row([powerSwitch, titleColumn, UI.spacer(), devicePopup, gearButton])))

    // Output format (sample rate / bit depth), like Audio MIDI Setup.
    formatPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    formatPopup.controlSize = .small
    formatPopup.font = .systemFont(ofSize: 11)
    formatPopup.toolTip = "Output format of the current device. Changes it for the whole Mac, like Audio MIDI Setup."
    formatPopup.setContentHuggingPriority(.init(1), for: .horizontal)
    root.addArrangedSubview(UI.fill(UI.row([UI.label("Format"), formatPopup])))

    bannerContainer.orientation = .vertical
    bannerContainer.alignment = .leading
    bannerContainer.isHidden = true
    root.addArrangedSubview(bannerContainer)

    // Master volume and balance.
    muteButton = UI.iconButton("speaker.wave.2.fill", tooltip: "Mute") { [weak self] in
      guard let self else { return }
      self.controller.setMuted(!self.controller.settings.muted)
    }
    volumeSlider = UI.slider(controller.settings.volume, 0...2) { [weak self] v in
      // Snap to 100% so it's easy to leave boost.
      let snapped = abs(v - 1) < 0.025 ? 1 : v
      self?.controller.setVolume(snapped)
    }
    volumeSlider.toolTip = "System volume. Above 100% EQBar boosts up to +12 dB."
    volumeValue = UI.value()
    root.addArrangedSubview(UI.fill(UI.row([muteButton, volumeSlider, volumeValue])))

    balanceSlider = UI.slider(controller.settings.balance, -1...1) { [weak self] v in
      let snapped = abs(v) < 0.04 ? 0 : v
      self?.controller.update { $0.balance = snapped }
    }
    balanceSlider.toolTip = "Balance"
    root.addArrangedSubview(UI.fill(UI.row([UI.label("L", size: 10), balanceSlider, UI.label("R", size: 10)])))

    root.addArrangedSubview(UI.separator())

    tabs = UI.segmented(tabTitles, selected: Self.lastTab) { [weak self] index in self?.showTab(index) }
    tabs.segmentDistribution = .fillEqually
    root.addArrangedSubview(UI.fill(tabs))

    contentContainer.orientation = .vertical
    contentContainer.alignment = .leading
    root.addArrangedSubview(contentContainer)

    // Native frosted background with rounded corners; the menu bar panel itself is transparent.
    let background = NSVisualEffectView()
    background.material = .popover
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 12
    background.layer?.masksToBounds = true
    background.addSubview(root)
    NSLayoutConstraint.activate([
      root.topAnchor.constraint(equalTo: background.topAnchor),
      root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      root.bottomAnchor.constraint(equalTo: background.bottomAnchor)
    ])
    view = background
    showTab(Self.lastTab)
    refresh()
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    Self.configureFieldEditor(of: view.window)
    observer = NotificationCenter.default.addObserver(forName: EQBarController.didChange, object: controller,
                                                      queue: .main) { [weak self] _ in self?.refresh() }
  }

  override func viewDidDisappear() {
    super.viewDidDisappear()
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }

  /// The popover's text fields only take search terms and numbers. Turning off macOS's language features
  /// (inline predictions, Writing Tools, completion, autocorrect) stops the system loading its text
  /// models into EQBar the first time a field is shown or focused.
  static func configureFieldEditor(of window: NSWindow?) {
    guard let editor = window?.fieldEditor(true, for: nil) as? NSTextView else { return }
    editor.inlinePredictionType = .no
    editor.isAutomaticTextCompletionEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isContinuousSpellCheckingEnabled = false
    editor.isGrammarCheckingEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticDataDetectionEnabled = false
    editor.isAutomaticLinkDetectionEnabled = false
    if #available(macOS 15.0, *) {
      editor.writingToolsBehavior = .none
      editor.mathExpressionCompletionType = .no
    }
  }

  // MARK: - Tabs and sub-pages

  func showTab(_ index: Int) {
    Self.lastTab = index
    tabs.selectedSegment = index
    let panel: PanelContent
    switch index {
    case 1: panel = SpatialPanel(controller: controller, layoutChanged: { [weak self] in self?.layoutChanged() })
    case 2: panel = MixerPanel(controller: controller, layoutChanged: { [weak self] in self?.layoutChanged() })
    case 3: panel = PluginsPanel(controller: controller, layoutChanged: { [weak self] in self?.layoutChanged() })
    default:
      panel = EQPanel(controller: controller,
                      layoutChanged: { [weak self] in self?.layoutChanged() },
                      openAutoEQ: { [weak self] in self?.showAutoEQ() })
    }
    setContent(panel)
  }

  func showAutoEQ() {
    Self.lastTab = 0
    tabs.selectedSegment = 0
    let page = AutoEQPanel(controller: controller, close: { [weak self] in
      guard let self else { return }
      self.showTab(Self.lastTab)
    }, layoutChanged: { [weak self] in self?.layoutChanged() })
    setContent(page)
  }

  private func setContent(_ panel: PanelContent) {
    content?.removeFromSuperview()
    content = panel
    contentContainer.addArrangedSubview(panel)
    layoutChanged()
  }

  private func layoutChanged() {
    root.layoutSubtreeIfNeeded()
    preferredContentSize = root.fittingSize
    onLayoutChange()
  }

  // MARK: - Refresh

  private func refresh() {
    let s = controller.settings
    powerSwitch.state = s.enabled ? .on : .off
    statusLabel.stringValue = statusText()
    volumeSlider.doubleValue = s.volume
    volumeValue.stringValue = s.muted ? "Muted" : volumeText(s.volume)
    let symbol = s.muted || s.volume == 0 ? "speaker.slash.fill"
      : s.volume > 1 ? "speaker.wave.3.fill" : "speaker.wave.2.fill"
    muteButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mute")?
      .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    balanceSlider.doubleValue = s.balance
    refreshDevices()
    refreshFormats()
    refreshBanner()
    content?.refresh()
  }

  private func volumeText(_ v: Double) -> String {
    v > 1 ? String(format: "+%.1f dB", (v - 1) * 12) : String(format: "%.0f%%", v * 100)
  }

  private func statusText() -> String {
    switch controller.status {
    case .off: return "Off"
    case .starting: return "Starting…"
    case .running: return "On"
    case .permissionRequired: return "Needs permission"
    case .failed: return "Error"
    }
  }

  private func refreshDevices() {
    devices = controller.outputDevices()
    devicePopup.removeAllItems()
    for device in devices { devicePopup.addItem(withTitle: device.name) }
    if let current = controller.outputDeviceID, let index = devices.firstIndex(where: { $0.id == current }) {
      devicePopup.selectItem(at: index)
    }
  }

  /// Rebuilt only when the device or its format changes, not on every volume tick.
  private func refreshFormats() {
    let (current, available) = controller.outputFormats()
    let key = "\(controller.outputDeviceID ?? 0)|\(current?.fullTitle ?? "")|\(available.count)"
    guard key != formatKey else { return }
    formatKey = key
    formats = available

    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(NSMenuItem(title: current?.fullTitle ?? "Unknown format", action: nil, keyEquivalent: ""))
    var lastRate = -1.0
    for format in available {
      if format.sampleRate != lastRate {
        lastRate = format.sampleRate
        if menu.items.count > 1 { menu.addItem(.separator()) }
        let header = NSMenuItem(title: format.rateTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
      }
      let item = NSMenuItem(format.title, checked: format == current) { [weak self] in self?.formatChosen(format) }
      item.indentationLevel = 1
      menu.addItem(item)
    }
    formatPopup.menu = menu
    formatPopup.isEnabled = !available.isEmpty
  }

  private func formatChosen(_ format: DeviceFormat) {
    do {
      try controller.setOutputFormat(format)
    } catch {
      let alert = NSAlert()
      alert.messageText = "Couldn't switch to \(format.fullTitle)"
      alert.informativeText = "\(error)"
      alert.runModal()
    }
  }

  private func deviceChosen() {
    let index = devicePopup.indexOfSelectedItem
    guard devices.indices.contains(index) else { return }
    controller.selectOutput(devices[index].id)
  }

  private var lastBanner: String?

  private var needsAccessibility: Bool {
    controller.settings.volumeKeys && controller.settings.enabled && !Permissions.accessibilityGranted
  }

  private func refreshBanner() {
    // Rebuild only when what should be shown changes; refresh() runs on every settings change.
    var key = ""
    switch controller.status {
    case .permissionRequired: key = "permission"
    case .failed(let message): key = "failed:" + message
    default: break
    }
    if needsAccessibility { key += "|accessibility|\(controller.settings.accessibilityPrompted)" }
    guard key != lastBanner else { return }
    lastBanner = key
    bannerContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
    defer {
      bannerContainer.isHidden = bannerContainer.arrangedSubviews.isEmpty   // no gap when there's nothing to say
      layoutChanged()
    }

    if case .permissionRequired = controller.status {
      bannerContainer.addArrangedSubview(UI.wrappingLabel(
        "EQBar needs the System Audio Recording permission to process your Mac's sound. Audio never leaves your Mac.",
        color: .systemOrange))
      bannerContainer.addArrangedSubview(UI.row([
        UI.button("Open System Settings") { NSWorkspace.shared.open(CapturePermission.settingsURL) },
        UI.button("Try Again") { [weak self] in self?.controller.retryPermission() }
      ]))
    } else if case .failed(let message) = controller.status {
      bannerContainer.addArrangedSubview(UI.wrappingLabel(message, color: .systemRed))
      bannerContainer.addArrangedSubview(UI.button("Try Again") { [weak self] in self?.controller.scheduleRebuild(after: 0) })
    }

    if needsAccessibility {
      let asked = controller.settings.accessibilityPrompted
      bannerContainer.addArrangedSubview(UI.wrappingLabel(asked
        ? "To use the volume keys for boost and HDMI volume, switch EQBar on in System Settings → Privacy & Security → Accessibility, then relaunch EQBar."
        : "Allow Accessibility so the volume keys can boost past 100% and control HDMI and DisplayPort volume. EQBar only reacts to the volume and mute keys.",
        color: .systemOrange))
      var buttons: [NSView] = []
      if asked {
        buttons.append(UI.button("Open Settings") {
          // Re-requesting puts EQBar back in the list if it was removed.
          Permissions.promptAccessibility()
          Permissions.openAccessibilitySettings()
          (NSApp.delegate as? AppDelegate)?.watchForAccessibility()
        })
        buttons.append(UI.button("Relaunch EQBar") { Permissions.relaunch() })
      } else {
        buttons.append(UI.button("Allow…") { [weak self] in
          self?.controller.markAccessibilityPrompted()
          Permissions.promptAccessibility()
          (NSApp.delegate as? AppDelegate)?.watchForAccessibility()
          self?.refreshBanner()
        })
      }
      buttons.append(UI.button("Not Now") { [weak self] in self?.controller.update { $0.volumeKeys = false } })
      bannerContainer.addArrangedSubview(UI.row(buttons))
    }
  }

  // MARK: - Settings menu

  private func showSettingsMenu() {
    let s = controller.settings
    let menu = NSMenu()
    menu.addItem(NSMenuItem("Launch at Login", checked: LoginItem.isEnabled) { LoginItem.toggle() })
    menu.addItem(NSMenuItem("Show Spectrum", checked: s.showSpectrum) { [weak self] in
      self?.controller.update { $0.showSpectrum.toggle() }
      self?.showTab(Self.lastTab)
    })
    menu.addItem(NSMenuItem("Prevent Clipping (Limiter)", checked: s.limiter) { [weak self] in
      self?.controller.update { $0.limiter.toggle() }
    })
    let keysItem = NSMenuItem("Volume Keys: Boost & HDMI Volume", checked: s.volumeKeys) { [weak self] in
      guard let self else { return }
      self.controller.update { $0.volumeKeys.toggle() }
      if self.controller.settings.volumeKeys && !Permissions.accessibilityGranted {
        self.controller.markAccessibilityPrompted()
        Permissions.promptAccessibility()
      }
    }
    keysItem.toolTip = "Volume Up past the device's maximum boosts up to +12 dB, and the keys control outputs that have no volume of their own (HDMI, DisplayPort). Needs Accessibility."
    menu.addItem(keysItem)

    let permissions = NSMenu()
    let audioAllowed = CapturePermission.status == .authorized || controller.status == .running
    permissions.addItem(NSMenuItem("System Audio Recording: \(audioAllowed ? "Allowed" : "Not Allowed")",
                                   checked: audioAllowed) {
      NSWorkspace.shared.open(CapturePermission.settingsURL)
    })
    let axAllowed = Permissions.accessibilityGranted
    permissions.addItem(NSMenuItem("Accessibility (volume keys): \(axAllowed ? "Allowed" : "Not Allowed")",
                                   checked: axAllowed) {
      Permissions.openAccessibilitySettings()
    })
    let permissionsItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
    permissionsItem.submenu = permissions
    menu.addItem(permissionsItem)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem("About EQBar") { AboutPanel.show() })
    menu.addItem(NSMenuItem("Quit EQBar") { NSApp.terminate(nil) })
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: gearButton.bounds.height + 4), in: gearButton)
  }
}
