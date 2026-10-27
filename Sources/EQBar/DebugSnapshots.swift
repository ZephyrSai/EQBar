import AppKit
import EQBarCore

/// Development aid: `EQBAR_SNAPSHOT=/some/dir` opens the menu panel and saves every page to PNG,
/// so the UI can be reviewed without screen-recording permission. Pages are shown with realistic
/// settings (a graphic preset, a real AutoEQ profile, spatial on, two Apple effects), and the
/// user's settings are put back afterwards. Never runs otherwise.
enum DebugSnapshots {
  static func runIfRequested(controller: EQBarController, openPopover: @escaping () -> NSWindow?) {
    guard let path = ProcessInfo.processInfo.environment["EQBAR_SNAPSHOT"] else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = controller.settings

    // A real profile for the Expert page, fetched while the first pages are captured.
    var profile: ParametricProfile?
    AutoEQService.shared.loadIndex { result in
      guard case .success(let entries) = result,
            let entry = entries.first(where: { $0.name == "Sennheiser HD 600" && $0.source == "oratory1990" }) else { return }
      AutoEQService.shared.fetchProfile(entry) { result in
        if case .success(let fetched) = result { DispatchQueue.main.async { profile = fetched } }
      }
    }

    let steps: [(name: String, delay: TimeInterval, action: (PopoverViewController) -> Void)] = [
      ("0-popover", 0.8, { _ in }),
      ("1-eq-advanced", 0.6, { vc in
        if let rock = BuiltInPresets.advanced.first(where: { $0.name == "Rock" }) { controller.applyPreset(rock) }
        vc.showTab(0)
      }),
      ("2-eq-basic", 0.6, { vc in
        controller.update { $0.eq.mode = .basic; $0.eq.basic = BasicGains(bass: 4, mid: -1.5, treble: 3) }
        vc.showTab(0)
      }),
      ("3-eq-expert", 0.6, { vc in
        if let profile { controller.applyProfile(profile, name: "Sennheiser HD 600") }
        vc.showTab(0)
      }),
      ("4-spatial", 0.8, { vc in controller.updateSpatial { $0.enabled = true }; vc.showTab(1) }),
      ("5-mixer", 0.6, { vc in vc.showTab(2) }),
      ("6-plugins", 1.5, { vc in
        for name in ["AUDynamicsProcessor", "AUMatrixReverb"]
        where !controller.settings.plugins.contains(where: { $0.descriptor.name == name }) {
          if let plugin = PluginCatalog.effects().first(where: { $0.name == name }) { controller.addPlugin(plugin) }
        }
        vc.showTab(3)
      }),
      ("7-autoeq", 2.5, { vc in
        vc.showAutoEQ()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          if let field = vc.view.firstDescendant(of: NSSearchField.self) {
            field.stringValue = "HD 600"
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
          }
        }
      })
    ]

    // The panel closes whenever it loses focus; reopen it if that happens mid-run.
    func current() -> (NSWindow, PopoverViewController)? {
      guard let panel = openPopover(), let vc = panel.contentViewController as? PopoverViewController else { return nil }
      return (panel, vc)
    }

    func finish() {
      current()?.0.close()
      controller.update { $0 = original }
      controller.updateSpatial { $0 = original.spatial }
      let added = controller.settings.plugins.filter { plugin in !original.plugins.contains { $0.id == plugin.id } }
      for plugin in added { controller.removePlugin(id: plugin.id) }
      // The volume HUD as it looks when the keys boost past 100%.
      VolumeHUD.shared.show(.init(volume: 1.5, muted: false, deviceHasVolume: true), below: nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        if let hud = VolumeHUD.shared.currentPanel { save(hud, to: directory.appendingPathComponent("9-hud.png")) }
        NSLog("EQBar: snapshots written to %@", directory.path)
      }
    }

    func run(_ index: Int, attempt: Int = 0) {
      guard index < steps.count else { return finish() }
      guard attempt < 10 else { return run(index + 1) }     // give up on this page
      guard let (_, vc) = current() else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { run(index, attempt: attempt + 1) }
        return
      }
      let step = steps[index]
      step.action(vc)
      DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) {
        if let (panel, shown) = current(), shown === vc {
          save(panel, to: directory.appendingPathComponent(step.name + ".png"))
          run(index + 1)
        } else {
          run(index, attempt: attempt + 1)     // closed while waiting: show the page again
        }
      }
    }
    // Let launch-time prompts and activation settle first.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { run(0) }
  }

  /// Renders the whole window, background included.
  private static func save(_ window: NSWindow, to url: URL) {
    guard let view = window.contentView?.superview ?? window.contentView else { return }
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
  }
}

extension NSView {
  func firstDescendant<T: NSView>(of type: T.Type) -> T? {
    for subview in subviews {
      if let match = subview as? T { return match }
      if let match = subview.firstDescendant(of: type) { return match }
    }
    return nil
  }
}
