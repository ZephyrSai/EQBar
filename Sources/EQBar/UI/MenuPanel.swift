import AppKit

/// The window that drops down from the menu bar icon.
///
/// A plain borderless panel instead of NSPopover: on macOS 26 a popover that grows while visible
/// allocates ~120 MB of transient graphics memory and keeps ~10 MB of it, and an open popover costs
/// ~8 MB more than this panel. It closes like a popover: click elsewhere, press Esc, or click the icon.
final class MenuPanel: NSPanel {
  private let content: NSViewController
  private var outsideClickMonitor: Any?
  var onClose: (() -> Void)?

  init(content: NSViewController) {
    self.content = content
    super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
               styleMask: [.borderless], backing: .buffered, defer: true)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .popUpMenu
    isReleasedWhenClosed = false
    collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
    hidesOnDeactivate = false

    contentViewController = content   // gives the controller its appear/disappear callbacks
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// Shows the panel centred under `button`, kept on screen.
  func show(below button: NSStatusBarButton) {
    setContentSize(content.preferredContentSize)
    if let buttonWindow = button.window {
      let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
      let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
      var origin = NSPoint(x: anchor.midX - frame.width / 2, y: anchor.minY - 6 - frame.height)
      origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
      setFrameOrigin(origin)
    }
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    // Clicks in other apps or on the desktop close the panel.
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      self?.close()
    }
  }

  /// Resizes to the content's preferred size, keeping the top edge under the icon.
  func fitContent() {
    let size = content.preferredContentSize
    guard size != frame.size, size.height > 0 else { return }
    let top = frame.maxY
    setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true, animate: false)
  }

  override func resignKey() {
    super.resignKey()
    // Losing focus to another window of ours (an open/save panel, a plugin editor) or another app closes it,
    // exactly like a transient popover.
    close()
  }

  override func cancelOperation(_ sender: Any?) { close() }

  override func close() {
    guard isVisible else { return }
    if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    outsideClickMonitor = nil
    super.close()
    onClose?()
  }
}
