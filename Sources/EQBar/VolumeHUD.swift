import AppKit
import EQBarCore

/// Permissions EQBar may need, and where to grant them.
enum Permissions {
  static var accessibilityGranted: Bool { AXIsProcessTrusted() }

  /// Shows macOS's own "EQBar would like to control this computer using accessibility features" prompt.
  static func promptAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  static let accessibilitySettingsURL =
    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

  static func openAccessibilitySettings() { NSWorkspace.shared.open(accessibilitySettingsURL) }

  /// macOS doesn't always tell a running app that it was just granted Accessibility; a relaunch always works.
  static func relaunch() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
    try? task.run()
    NSApp.terminate(nil)
  }
}

/// Small on-screen volume indicator for the levels macOS can't show itself:
/// boost above 100% and outputs without hardware volume (HDMI, DisplayPort).
/// Created on demand and released again once it fades out.
final class VolumeHUD {
  static let shared = VolumeHUD()

  private var panel: NSPanel?
  private var icon: NSImageView!
  private var bar: LevelBar!
  private var label: NSTextField!
  private var hideWork: DispatchWorkItem?

  /// For the snapshot tool.
  var currentPanel: NSPanel? { panel }

  func show(_ indicator: EQBarController.VolumeIndicator, below anchor: NSView?) {
    let panel = self.panel ?? makePanel()
    self.panel = panel

    let symbol = indicator.muted || indicator.volume == 0 ? "speaker.slash.fill"
      : indicator.volume > 1 ? "speaker.wave.3.fill"
      : indicator.volume > 0.5 ? "speaker.wave.2.fill" : "speaker.wave.1.fill"
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Volume")?
      .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
    bar.level = indicator.muted ? 0 : indicator.volume
    label.stringValue = indicator.muted ? "Muted"
      : indicator.volume > 1 ? String(format: "+%.1f dB", (indicator.volume - 1) * 12)
      : String(format: "%.0f%%", indicator.volume * 100)

    position(panel, below: anchor)
    hideWork?.cancel()
    panel.alphaValue = 1
    panel.orderFrontRegardless()

    let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
  }

  private func fadeOut() {
    guard let panel else { return }
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.25
      panel.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      guard let self, self.panel === panel, panel.alphaValue == 0 else { return }
      panel.orderOut(nil)
      self.panel = nil
    })
  }

  private func position(_ panel: NSPanel, below anchor: NSView?) {
    let size = panel.frame.size
    let screen = anchor?.window?.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? .zero
    var origin = NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 8)
    if let anchor, let window = anchor.window {
      let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
      origin.x = anchorFrame.midX - size.width / 2
      origin.y = anchorFrame.minY - size.height - 8
    }
    origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
    panel.setFrameOrigin(origin)
  }

  private func makePanel() -> NSPanel {
    let size = NSSize(width: 236, height: 44)
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.level = .popUpMenu
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    panel.isReleasedWhenClosed = false

    let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    background.material = .hudWindow
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 12
    background.layer?.masksToBounds = true

    icon = NSImageView()
    icon.contentTintColor = .labelColor
    icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
    bar = LevelBar()
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
    bar.widthAnchor.constraint(equalToConstant: 132).isActive = true
    label = UI.label("", size: 11, weight: .medium, color: .labelColor, align: .right)
    label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    label.widthAnchor.constraint(equalToConstant: 52).isActive = true

    let row = UI.row([icon, bar, label], spacing: 8)
    row.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(row)
    NSLayoutConstraint.activate([
      row.centerXAnchor.constraint(equalTo: background.centerXAnchor),
      row.centerYAnchor.constraint(equalTo: background.centerYAnchor)
    ])
    panel.contentView = background
    return panel
  }
}

/// 0–1 fills the bar in white; boost (1–2) is drawn over it in orange.
final class LevelBar: NSView {
  var level = 0.0 { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    let radius = bounds.height / 2
    NSColor.labelColor.withAlphaComponent(0.2).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

    let normal = min(max(level, 0), 1)
    if normal > 0 {
      NSColor.labelColor.setFill()
      NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * normal, height: bounds.height),
                   xRadius: radius, yRadius: radius).fill()
    }
    let boost = min(max(level - 1, 0), 1)
    if boost > 0 {
      NSColor.systemOrange.setFill()
      NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * boost, height: bounds.height),
                   xRadius: radius, yRadius: radius).fill()
    }
  }
}
