import AppKit
import AudioToolbox
import CoreAudioKit
import EQBarCore

/// Third-party Audio Unit effects in the processing chain.
final class PluginsPanel: NSStackView, PanelContent, NSMenuDelegate {
  private let controller: EQBarController
  private let layoutChanged: () -> Void
  private let rows = NSStackView()
  private var addButton: NSPopUpButton!
  private var shownState: [String]?

  /// Scanning installed components takes a moment, so do it once per launch, on first use.
  private static var catalog: [PluginDescriptor]?

  init(controller: EQBarController, layoutChanged: @escaping () -> Void) {
    self.controller = controller
    self.layoutChanged = layoutChanged
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 8

    addButton = NSPopUpButton(frame: .zero, pullsDown: true)
    addButton.controlSize = .small
    addButton.font = .systemFont(ofSize: 11)
    addButton.addItem(withTitle: "Add Plugin…")
    addButton.menu?.delegate = self
    addArrangedSubview(UI.fill(UI.row([UI.label("Audio Unit Effects", weight: .medium, color: .labelColor),
                                       UI.spacer(), addButton])))
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 6
    addArrangedSubview(rows)
    addArrangedSubview(UI.wrappingLabel("Plugins run first in the chain, before the EQ and spatial audio. Their editor windows stay open when this panel closes."))
    refresh()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func refresh() {
    let plugins = controller.settings.plugins
    let state = plugins.map { p in
      "\(p.id)|\(p.bypassed)|\(controller.loadedPlugins[p.id] != nil)|\(controller.pluginErrors[p.id] ?? "")"
    }
    guard state != shownState else { return }
    shownState = state
    rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if plugins.isEmpty {
      rows.addArrangedSubview(UI.label("No plugins added.", color: .tertiaryLabelColor))
    }
    for (index, setting) in plugins.enumerated() {
      rows.addArrangedSubview(row(for: setting, index: index, count: plugins.count))
      if let error = controller.pluginErrors[setting.id] {
        rows.addArrangedSubview(UI.wrappingLabel(error, size: 10, color: .systemRed))
      }
    }
    layoutChanged()
  }

  private func row(for setting: PluginSetting, index: Int, count: Int) -> NSView {
    let id = setting.id
    let active = UI.checkbox("", on: !setting.bypassed) { [weak self] on in
      self?.controller.setPluginBypassed(id: id, !on)
    }
    active.toolTip = "Active"
    let loaded = controller.loadedPlugins[id] != nil
    let name = UI.label(setting.descriptor.name, color: loaded ? .labelColor : .tertiaryLabelColor)
    let maker = UI.label(setting.descriptor.manufacturerName, size: 9)
    let titles = UI.column([name, maker], spacing: 0)
    titles.setContentHuggingPriority(.init(1), for: .horizontal)
    let edit = UI.button("Edit") { [weak self] in
      guard let self, let plugin = self.controller.loadedPlugins[id] else { return }
      PluginWindows.shared.show(plugin, controller: self.controller)
    }
    edit.isEnabled = loaded
    let up = UI.iconButton("chevron.up", tooltip: "Move earlier", size: 10) { [weak self] in self?.controller.movePlugin(id: id, by: -1) }
    up.isEnabled = index > 0
    let down = UI.iconButton("chevron.down", tooltip: "Move later", size: 10) { [weak self] in self?.controller.movePlugin(id: id, by: 1) }
    down.isEnabled = index < count - 1
    let remove = UI.iconButton("xmark.circle", tooltip: "Remove", size: 12) { [weak self] in
      PluginWindows.shared.close(id)
      self?.controller.removePlugin(id: id)
    }
    return UI.fill(UI.row([active, titles, UI.spacer(), edit, up, down, remove], spacing: 6))
  }

  // MARK: - Add menu (built when opened)

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu.items.count <= 1 else { return }
    let catalog = Self.catalog ?? PluginCatalog.effects()
    Self.catalog = catalog
    if catalog.isEmpty {
      menu.addItem(NSMenuItem("No Audio Unit effects found", enabled: false) {})
      return
    }
    var byMaker: [String: [PluginDescriptor]] = [:]
    for descriptor in catalog { byMaker[descriptor.manufacturerName, default: []].append(descriptor) }
    for maker in byMaker.keys.sorted() {
      let submenu = NSMenu()
      for descriptor in byMaker[maker] ?? [] {
        submenu.addItem(NSMenuItem(descriptor.name) { [weak self] in
          self?.controller.addPlugin(descriptor)
          if let self { self.shownState = nil; self.refresh() }
        })
      }
      let item = NSMenuItem(title: maker, action: nil, keyEquivalent: "")
      item.submenu = submenu
      menu.addItem(item)
    }
  }
}

/// Plugin editor windows. Independent of the popover so they survive it closing.
final class PluginWindows: NSObject, NSWindowDelegate {
  static let shared = PluginWindows()
  private var windows: [UUID: NSWindow] = [:]
  private weak var controller: EQBarController?

  func show(_ plugin: HostedPlugin, controller: EQBarController) {
    self.controller = controller
    guard let id = controller.settings.plugins.first(where: { controller.loadedPlugins[$0.id] === plugin })?.id else { return }
    if let window = windows[id] {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    plugin.audioUnit.requestViewController { [weak self] viewController in
      DispatchQueue.main.async {
        guard let self else { return }
        let content = viewController ?? GenericPluginEditor(plugin: plugin)
        let window = NSWindow(contentViewController: content)
        window.title = plugin.descriptor.name
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        self.windows[id] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
  }

  func close(_ id: UUID) {
    windows[id]?.close()
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
          let raw = window.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
    windows[id] = nil
    controller?.capturePluginStates()
  }
}

/// Simple sliders for plugins that don't ship their own editor.
final class GenericPluginEditor: NSViewController {
  private let plugin: HostedPlugin
  private var tokens: [NSObject] = []

  init(plugin: HostedPlugin) {
    self.plugin = plugin
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func loadView() {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    let parameters = Array((plugin.audioUnit.parameterTree?.allParameters ?? []).prefix(48))
    if parameters.isEmpty {
      stack.addArrangedSubview(UI.label("This plugin has no adjustable parameters.", color: .labelColor))
    }
    for parameter in parameters {
      let name = UI.label(parameter.displayName, color: .labelColor)
      name.widthAnchor.constraint(equalToConstant: 150).isActive = true
      let value = UI.value(parameter.string(fromValue: nil), width: 80)
      let slider = UI.slider(Double(parameter.value), Double(parameter.minValue)...Double(max(parameter.maxValue, parameter.minValue + 0.0001))) { v in
        parameter.value = AUValue(v)
        value.stringValue = parameter.string(fromValue: nil)
      }
      slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
      stack.addArrangedSubview(UI.row([name, slider, value]))
    }
    view = stack
  }
}
