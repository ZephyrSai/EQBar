import AppKit
import EQBarCore
import ServiceManagement

enum LaunchTimer {
  private static var start: UInt64 = 0

  static func mark() { start = DispatchTime.now().uptimeNanoseconds }

  /// Time since the process started, using the kernel's process start time when available.
  static var elapsedMilliseconds: Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    if sysctl(&mib, 4, &info, &size, nil, 0) == 0 {
      let started = info.kp_proc.p_un.__p_starttime
      let startSeconds = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
      return (Date().timeIntervalSince1970 - startSeconds) * 1000
    }
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
  }
}

enum LoginItem {
  static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

  static func toggle() {
    do {
      if isEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
    } catch {
      let alert = NSAlert()
      alert.messageText = "Couldn't change Launch at Login"
      alert.informativeText = "\(error.localizedDescription)\n\nMove EQBar to the Applications folder and try again."
      alert.runModal()
    }
  }
}

enum AboutPanel {
  static func show() {
    let credits = NSMutableAttributedString()
    let body: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor
    ]
    func add(_ text: String, link: String? = nil) {
      var attributes = body
      if let link, let url = URL(string: link) { attributes[.link] = url }
      credits.append(NSAttributedString(string: text, attributes: attributes))
    }
    add("A lean menu bar equalizer, spatial audio and volume mixer for macOS.\n")
    add("By ")
    add("ZephyrSai", link: "https://github.com/ZephyrSai/EQBar")
    add(". Open source under Apache 2.0.\n\n")
    add("Inspired by ")
    add("eqMac", link: "https://github.com/bitgapp/eqMac")
    add(" by Roman Kisil (Nodeful / Bitgapp), licensed under Apache 2.0.\n")
    add("Headphone profiles from ")
    add("AutoEq", link: "https://github.com/jaakkopasanen/AutoEq")
    add(" by Jaakko Pasanen (MIT).\n")
    add("Crossfeed after Boris Mikhaylov's bs2b. Filters from Robert Bristow-Johnson's Audio EQ Cookbook.")
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "EQBar"])
  }
}

/// Watches the keyboard's volume keys (needs the Accessibility permission). The handler decides
/// per press whether EQBar takes the key or macOS handles it as usual.
final class MediaKeyTap {
  typealias Key = EQBarController.VolumeKey

  private let handler: (Key) -> Bool
  private var port: CFMachPort?
  private var source: CFRunLoopSource?

  init(handler: @escaping (Key) -> Bool) { self.handler = handler }

  func start() -> Bool {
    guard AXIsProcessTrusted() else { return false }
    let systemDefined: CGEventMask = 1 << 14   // NX_SYSDEFINED
    let callback: CGEventTapCallBack = { _, type, event, refcon in
      guard let refcon else { return Unmanaged.passUnretained(event) }
      let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
      }
      return tap.handle(event) ? nil : Unmanaged.passUnretained(event)
    }
    guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                       eventsOfInterest: systemDefined, callback: callback,
                                       userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
    self.port = port
    source = CFMachPortCreateRunLoopSource(nil, port, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    return true
  }

  func stop() {
    if let port { CGEvent.tapEnable(tap: port, enable: false) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    port = nil
    source = nil
  }

  private func handle(_ event: CGEvent) -> Bool {
    guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return false }
    let keyCode = (ns.data1 & 0xFFFF_0000) >> 16
    let keyDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
    let fine = ns.modifierFlags.contains(.shift) && ns.modifierFlags.contains(.option)
    let key: Key
    switch Int32(keyCode) {
    case NX_KEYTYPE_SOUND_UP: key = .up(fine: fine)
    case NX_KEYTYPE_SOUND_DOWN: key = .down(fine: fine)
    case NX_KEYTYPE_MUTE: key = .mute
    default: return false
    }
    // Swallow the key-up too when EQBar took the key-down, so macOS doesn't act on half a press.
    if !keyDown { return handlerWouldHandle }
    handlerWouldHandle = handler(key)
    return handlerWouldHandle
  }

  private var handlerWouldHandle = false
}
