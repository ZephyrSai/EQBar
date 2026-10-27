import AppKit
import AudioToolbox
import EQBarCore

/// Development aid: `EQBAR_MEMTEST=/path/report.txt` drives the app through every feature and records
/// the process's physical footprint (what Activity Monitor shows as "Memory") after each step.
/// Settings are restored at the end. Never runs otherwise.
enum MemoryScenarios {
  struct Hooks {
    let openPopover: () -> PopoverViewController?
    let closePopover: () -> Void
    let statusButton: () -> NSView?
  }

  static func footprintMB() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
  }

  static func runIfRequested(controller: EQBarController, hooks: Hooks) {
    guard let path = ProcessInfo.processInfo.environment["EQBAR_MEMTEST"] else { return }
    let original = controller.settings
    var lines: [String] = []
    var popover: PopoverViewController?

    func record(_ name: String) {
      let before = footprintMB()
      malloc_zone_pressure_relief(nil, 0)
      let after = footprintMB()
      let line = String(format: "%-46@ %6.1f MB   settled %6.1f MB   peak %6.1f MB",
                        name as NSString, before.now, after.now, after.peak)
      lines.append(line)
      NSLog("EQBar memtest: %@", line)
    }

    // (name, action, seconds to wait before measuring)
    var steps: [(String, () -> Void, Double)] = [
      ("idle, popover never opened", {}, 1),
      ("popover open — EQ Advanced", { controller.update { $0.eq.mode = .advanced }; popover = hooks.openPopover() }, 1.5),
      ("  EQ Basic", { controller.update { $0.eq.mode = .basic } }, 1),
      ("  EQ Expert", { controller.update { $0.eq.mode = .expert } }, 1),
      ("  Spatial tab", { popover?.showTab(1) }, 1),
      ("  Mixer tab (polling)", { popover?.showTab(2) }, 3.5),
      ("  Plugins tab", { popover?.showTab(3) }, 1),
      ("  AutoEQ search 'HD 600'", {
        popover?.showAutoEQ()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          if let field = popover?.view.firstDescendant(of: NSSearchField.self) {
            field.stringValue = "HD 600"
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
          }
        }
      }, 3.5),
      ("popover closed", { popover = nil; hooks.closePopover() }, 3),
      ("spatial ON (headphones, medium room)", {
        controller.updateSpatial { s in s.enabled = true; s.output = .headphones; s.room = .mediumRoom; s.personalizedHRTF = false }
      }, 5),
      ("  spatial: 6 rapid room changes", {
        for (i, room) in [RoomType.smallRoom, .largeHall, .cathedral, .plate, .mediumHall, .largeRoom].enumerated() {
          DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) { controller.updateSpatial { $0.room = room } }
        }
      }, 5),
      ("  spatial: cathedral", { controller.updateSpatial { $0.room = .cathedral } }, 5),
      ("  spatial: speakers output", { controller.updateSpatial { $0.output = .builtInSpeakers; $0.room = .mediumRoom } }, 5),
      ("spatial OFF", { controller.updateSpatial { $0.enabled = false } }, 3),
      ("crossfeed medium + width 150%", { controller.update { $0.crossfeed = .medium; $0.stereoWidth = 1.5 } }, 1.5),
      ("crossfeed off + width 100%", { controller.update { $0.crossfeed = .off; $0.stereoWidth = 1 } }, 1.5),
      ("per-app volume 50% (extra tap)", {
        if let app = AudioProcesses.apps().first {
          controller.setAppVolume(key: app.key, name: app.name, volume: 0.5, muted: false)
        }
      }, 3),
      ("per-app volume back to 100%", {
        for key in controller.settings.appVolumes.keys {
          controller.setAppVolume(key: key, name: "", volume: 1, muted: false)
        }
        controller.scheduleRebuild(after: 0)
      }, 3),
      ("plugin catalog scanned", { _ = PluginCatalog.effects() }, 1.5),
      ("plugin added (Apple AUDelay)", {
        if let delay = PluginCatalog.effects().first(where: { $0.subtype == kAudioUnitSubType_Delay && $0.manufacturer == kAudioUnitManufacturer_Apple }) {
          controller.addPlugin(delay)
        }
      }, 3),
      ("plugin removed", {
        for plugin in controller.settings.plugins { controller.removePlugin(id: plugin.id) }
      }, 3),
      ("AutoEQ profile applied (HD 600)", {
        AutoEQService.shared.loadIndex { result in
          guard case .success(let entries) = result, let entry = AutoEQService.search("HD 600", in: entries).first else { return }
          AutoEQService.shared.fetchProfile(entry) { profile in
            if case .success(let p) = profile { controller.applyProfile(p, name: "memtest HD 600") }
          }
        }
      }, 4),
      ("volume indicator shown", {
        VolumeHUD.shared.show(.init(volume: 1.25, muted: false, deviceHasVolume: true), below: hooks.statusButton())
      }, 0.5),
      ("volume indicator faded out", {}, 2.5)
    ]
    for cycle in 1...15 {
      steps.append(("popover open/close cycle \(cycle)", {
        let vc = hooks.openPopover()
        vc?.showTab(cycle % 4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { hooks.closePopover() }
      }, 2.6))
    }
    // Last, because Apple keeps its tables cached for the rest of the process's life.
    steps.append(("spatial ON, personalized renderer (opt-in)", {
      controller.updateSpatial { s in s.enabled = true; s.output = .headphones; s.room = .mediumRoom; s.personalizedHRTF = true }
    }, 7))
    steps.append(("restore settings", {
      controller.update { $0 = original }
      controller.updateSpatial { $0 = original.spatial }
      controller.scheduleRebuild(after: 0)
    }, 3))
    steps.append(("final idle", {}, 3))

    if let focus = ProcessInfo.processInfo.environment["EQBAR_MEMTEST_STEPS"] {
      let hold = 8.0
      switch focus {
      case "popover":
        steps = [("idle", {}, hold),
                 ("popover open EQ", { popover = hooks.openPopover() }, hold),
                 ("popover closed", { popover = nil; hooks.closePopover() }, hold)]
      case "autoeq-quick":
        steps = [("idle", {}, 1.5),
                 ("popover open EQ", { popover = hooks.openPopover() }, 2.5),
                 ("autoeq page", { AutoEQPanel.focusSearchOnShow = false; popover?.showAutoEQ() }, 4),
                 ("popover closed", { popover = nil; hooks.closePopover() }, 2)]
      default: break
      }
    }

    func run(_ index: Int) {
      guard index < steps.count else {
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        NSLog("EQBar memtest: report written to %@", path)
        return
      }
      let (name, action, wait) = steps[index]
      action()
      DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
        record(name)
        run(index + 1)
      }
    }
    // Let launch settle first.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { run(0) }
  }
}
