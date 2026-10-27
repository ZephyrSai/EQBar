import AppKit
import EQBarCore

/// Per-app volume. Polls the audio process list only while visible.
final class MixerPanel: NSStackView, PanelContent {
  private let controller: EQBarController
  private let layoutChanged: () -> Void
  private let rows = NSStackView()
  private var shownKeys: [String] = []
  private var timer: Timer?

  init(controller: EQBarController, layoutChanged: @escaping () -> Void) {
    self.controller = controller
    self.layoutChanged = layoutChanged
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 8
    addArrangedSubview(UI.label("App Volume", weight: .medium, color: .labelColor))
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 6
    addArrangedSubview(rows)
    addArrangedSubview(UI.wrappingLabel("Apps appear here while they play sound. Changing an app's level gives it its own audio tap, which can cause a brief pause the first time."))
    reload()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    timer?.invalidate()
    timer = nil
    guard window != nil else { return }
    let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.reload() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func refresh() {}

  private func reload() {
    let apps = controller.audioApps()
    let keys = apps.map(\.key)
    guard keys != shownKeys else { return }
    shownKeys = keys
    rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if apps.isEmpty {
      rows.addArrangedSubview(UI.label("Nothing is playing right now.", color: .tertiaryLabelColor))
    }
    for app in apps {
      rows.addArrangedSubview(AppVolumeRow(app: app, controller: controller))
    }
    layoutChanged()
  }
}

final class AppVolumeRow: NSStackView {
  private let app: AudioApp
  private let controller: EQBarController
  private var slider: NSSlider!
  private var value: NSTextField!
  private var muteButton: NSButton!

  init(app: AudioApp, controller: EQBarController) {
    self.app = app
    self.controller = controller
    super.init(frame: .zero)
    orientation = .horizontal
    alignment = .centerY
    spacing = 8

    let icon = NSImageView()
    let appIcon = NSRunningApplication(processIdentifier: app.pid)?.icon
      ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
    appIcon?.size = NSSize(width: 18, height: 18)
    icon.image = appIcon
    icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

    let name = UI.label(app.name, color: app.isPlaying ? .labelColor : .secondaryLabelColor)
    name.widthAnchor.constraint(equalToConstant: 96).isActive = true

    let current = controller.appVolume(for: app.key)
    slider = UI.slider(current.volume, 0...1.5) { [weak self] v in
      guard let self else { return }
      let snapped = abs(v - 1) < 0.03 ? 1 : v
      self.controller.setAppVolume(key: self.app.key, name: self.app.name, volume: snapped,
                                   muted: self.controller.appVolume(for: self.app.key).muted)
      self.update()
    }
    slider.toolTip = "Above 100% boosts up to +6 dB"
    value = UI.value(width: 40)
    muteButton = UI.iconButton("speaker.wave.2.fill", tooltip: "Mute \(app.name)", size: 11) { [weak self] in
      guard let self else { return }
      let state = self.controller.appVolume(for: self.app.key)
      self.controller.setAppVolume(key: self.app.key, name: self.app.name, volume: state.volume, muted: !state.muted)
      self.update()
    }
    for view in [icon, name, slider!, value!, muteButton!] { addArrangedSubview(view) }
    UI.fill(self)
    update()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  private func update() {
    let state = controller.appVolume(for: app.key)
    slider.doubleValue = state.volume
    value.stringValue = state.muted ? "Off" : String(format: "%.0f%%", state.volume * 100)
    let symbol = state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
    muteButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mute")?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    muteButton.contentTintColor = state.muted ? .systemRed : .secondaryLabelColor
  }
}
