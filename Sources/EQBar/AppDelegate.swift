import AppKit
import EQBarCore

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let controller = EQBarController()
  private var statusItem: NSStatusItem!
  private var panel: MenuPanel?
  private var panelClosedAt = Date.distantPast
  private var mediaKeys: MediaKeyTap?

  /// True once this copy owns audio processing. A duplicate copy that quits never touches settings or Core Audio.
  private var launched = false
  private var showObserver: NSObjectProtocol?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Only one copy may process audio. Settle that before creating anything.
    guard let runningPID = SingleInstance.acquire() else { return launch() }
    switch SingleInstance.ask(about: runningPID) {
    case .keepRunning:
      NSApp.terminate(nil)
    case .replace:
      SingleInstance.replace(runningPID) { [weak self] owned in
        if owned {
          self?.launch()
        } else {
          let alert = NSAlert()
          alert.messageText = "The other copy of EQBar didn't quit"
          alert.informativeText = "Quit it from its menu bar icon, then open EQBar again."
          alert.runModal()
          NSApp.terminate(nil)
        }
      }
    }
  }

  /// Opening EQBar again (Finder, Spotlight, Launchpad) while it runs shows its panel.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if launched { showPopover() }
    return false
  }

  private func showPopover() {
    if panel == nil { togglePopover() }
  }

  private func launch() {
    launched = true
    // A second copy that was started asks us to show where we are.
    showObserver = DistributedNotificationCenter.default().addObserver(
      forName: SingleInstance.showNotification, object: nil, queue: .main) { [weak self] _ in
        self?.showPopover()
      }

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem.button {
      button.target = self
      button.action = #selector(statusItemClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    updateStatusItem()
    NotificationCenter.default.addObserver(self, selector: #selector(controllerChanged),
                                           name: EQBarController.didChange, object: controller)
    // Let the menu bar icon appear first; connecting to Core Audio happens on the next run loop pass.
    DispatchQueue.main.async { [self] in
      controller.start()
      updateMediaKeys()
    }
    Self.releaseFreedMemory(after: 3)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, controller] in
      DebugSnapshots.runIfRequested(controller: controller) { [weak self] in
        self?.showPopover()
        return self?.panel
      }
      MemoryScenarios.runIfRequested(controller: controller, hooks: .init(
        openPopover: { [weak self] in
          guard let self else { return nil }
          if self.panel == nil { self.togglePopover() }
          return self.panel?.contentViewController as? PopoverViewController
        },
        closePopover: { [weak self] in self?.panel?.close() },
        statusButton: { [weak self] in self?.statusItem.button }))
    }

    if ProcessInfo.processInfo.environment["EQBAR_DEBUG"] != nil {
      NSLog("EQBar: launched in %.1f ms", LaunchTimer.elapsedMilliseconds)
      debugTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
        guard let self else { return }
        NSLog("EQBar: %@ ax=%@ keys=%@", self.controller.debugSummary, Permissions.accessibilityGranted ? "yes" : "no", self.mediaKeys == nil ? "off" : "on")
      }
    }
  }

  private var debugTimer: Timer?

  func applicationWillTerminate(_ notification: Notification) {
    guard launched else { return }
    controller.shutdown()
  }

  @objc private func controllerChanged() {
    updateStatusItem()
    updateMediaKeys()
  }

  private func updateStatusItem() {
    guard let button = statusItem.button else { return }
    let symbol: String
    var tooltip = "EQBar"
    switch controller.status {
    case .permissionRequired:
      symbol = "exclamationmark.triangle"
      tooltip += " — needs the System Audio Recording permission"
    case .failed(let message):
      symbol = "exclamationmark.triangle"
      tooltip += " — \(message)"
    case .off:
      symbol = "slider.vertical.3"
      tooltip += " — Off"
    case .starting, .running:
      symbol = "slider.vertical.3"
      tooltip += " — \(controller.outputDeviceName)"
    }
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "EQBar")
    image?.isTemplate = true
    button.image = image
    button.appearsDisabled = controller.status == .off
    button.toolTip = tooltip
  }

  // MARK: - Status item

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      showQuickMenu()
    } else {
      togglePopover()
    }
  }

  private func showQuickMenu() {
    let menu = NSMenu()
    let enabled = controller.settings.enabled
    menu.addItem(NSMenuItem(enabled ? "Turn EQBar Off" : "Turn EQBar On") { [weak self] in
      self?.controller.setEnabled(!enabled)
    })
    menu.addItem(.separator())
    menu.addItem(NSMenuItem("About EQBar") { AboutPanel.show() })
    menu.addItem(NSMenuItem("Quit EQBar") { NSApp.terminate(nil) })
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  private func togglePopover() {
    if let panel {
      panel.close()
      return
    }
    // Clicking the icon while the panel is open first closes it (it loses focus); don't reopen it.
    guard Date().timeIntervalSince(panelClosedAt) > 0.3, let button = statusItem.button else { return }
    // The resize callback goes through self (weakly), so the panel and its content don't retain each other.
    let content = PopoverViewController(controller: controller) { [weak self] in self?.panel?.fitContent() }
    let panel = MenuPanel(content: content)
    panel.onClose = { [weak self] in self?.panelDidClose() }
    self.panel = panel
    updateMediaKeys()
    panel.show(below: button)
  }

  /// Drop the whole view hierarchy when the panel closes; it's rebuilt in a few ms on the next click.
  private func panelDidClose() {
    panelClosedAt = Date()
    panel?.contentViewController = nil
    panel = nil
    Self.releaseFreedMemory(after: 1.5)
  }

  /// Startup and the panel's views leave freed-but-dirty malloc pages behind; give them back to the OS.
  private static func releaseFreedMemory(after delay: TimeInterval) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { malloc_zone_pressure_relief(nil, 0) }
  }

  // MARK: - Volume keys (boost past 100%, HDMI / DisplayPort volume)

  private var accessibilityObserver: NSObjectProtocol?

  private func updateMediaKeys() {
    let wanted = controller.settings.volumeKeys && controller.settings.enabled
    if wanted, mediaKeys == nil, Permissions.accessibilityGranted {
      let tap = MediaKeyTap { [weak self] key in self?.handleMediaKey(key) ?? false }
      if tap.start() {
        mediaKeys = tap
        if ProcessInfo.processInfo.environment["EQBAR_DEBUG"] != nil { NSLog("EQBar: volume keys active") }
      }
    } else if !wanted, let tap = mediaKeys {
      tap.stop()
      mediaKeys = nil
    }

    // Ask for Accessibility once, automatically, after the audio permission has been dealt with
    // so two system prompts never stack. Later it's offered from the popover and the Settings menu.
    if wanted, !Permissions.accessibilityGranted, !controller.settings.accessibilityPrompted,
       controller.status == .running || controller.status == .permissionRequired,
       ProcessInfo.processInfo.environment["EQBAR_SNAPSHOT"] == nil {
      controller.markAccessibilityPrompted()
      Permissions.promptAccessibility()
    }

    // Until the grant arrives, check every couple of seconds for a few minutes (the system
    // notification below can arrive before the new permission is visible to this process).
    if wanted, !Permissions.accessibilityGranted {
      watchForAccessibility()
    }

    // macOS posts this when the Accessibility list changes; pick the grant up without a relaunch.
    if wanted, accessibilityObserver == nil {
      accessibilityObserver = DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self?.updateMediaKeys()
            self?.controller.refreshObservers()
          }
        }
    } else if !wanted, let observer = accessibilityObserver {
      DistributedNotificationCenter.default().removeObserver(observer)
      accessibilityObserver = nil
    }
  }

  private var accessibilityTimer: Timer?

  /// Polls the Accessibility grant for up to five minutes, then gives up until the next prompt or popover open.
  func watchForAccessibility() {
    guard accessibilityTimer == nil else { return }
    var ticks = 0
    accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
      ticks += 1
      guard let self else { return timer.invalidate() }
      if Permissions.accessibilityGranted || ticks > 150 {
        timer.invalidate()
        self.accessibilityTimer = nil
        self.updateMediaKeys()
        self.controller.refreshObservers()
      }
    }
  }

  /// Returns true when EQBar took the key (macOS then never sees it).
  private func handleMediaKey(_ key: MediaKeyTap.Key) -> Bool {
    guard let indicator = controller.handleVolumeKey(key) else { return false }
    if ProcessInfo.processInfo.environment["EQBAR_DEBUG"] != nil {
      NSLog("EQBar: volume key %@ → EQBar volume %.4f muted=%d", String(describing: key), indicator.volume, indicator.muted ? 1 : 0)
    }
    VolumeHUD.shared.show(indicator, below: statusItem.button)
    return true
  }
}
