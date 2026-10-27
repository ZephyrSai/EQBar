import AppKit

/// Makes sure only one EQBar processes audio. Two copies would each tap and replay the system's
/// sound, so the second one has to stand down before it touches Core Audio.
///
/// Ownership is an exclusive lock on a file in Application Support, held for the life of the process.
/// The kernel drops it when the process exits or crashes, so a stale lock can't block a launch.
enum SingleInstance {
  /// Posted (distributed) by a second copy so the running one shows its popover.
  static let showNotification = Notification.Name("app.eqbar.showPopover")

  private static var lockDescriptor: Int32 = -1

  private static var lockPath: String {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("EQBar", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("instance.lock").path
  }

  /// Takes ownership. Returns nil on success, or the process ID of the running copy
  /// (0 if it couldn't be read).
  static func acquire() -> pid_t? {
    guard lockDescriptor < 0 else { return nil }
    let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else { return nil }   // can't create the lock file: don't block launching
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
      let pid = Array("\(getpid())\n".utf8)
      ftruncate(descriptor, 0)
      _ = pid.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
      lockDescriptor = descriptor
      return nil
    }
    var buffer = [UInt8](repeating: 0, count: 32)
    let count = pread(descriptor, &buffer, buffer.count - 1, 0)
    close(descriptor)
    let text = String(decoding: buffer.prefix(max(0, count)), as: UTF8.self)
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
  }

  enum Choice { case keepRunning, replace }

  /// Asks whether to keep the running copy (this one quits) or to quit it and continue with this one.
  /// `EQBAR_DUPLICATE=keep|replace` answers without the dialog (used by automated tests).
  static func ask(about pid: pid_t) -> Choice {
    // Point the user at the running copy first.
    DistributedNotificationCenter.default().postNotificationName(showNotification, object: nil,
                                                                 userInfo: nil, deliverImmediately: true)
    switch ProcessInfo.processInfo.environment["EQBAR_DUPLICATE"] {
    case "keep": return .keepRunning
    case "replace": return .replace
    default: break
    }
    let running = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
    let location = running?.bundleURL?.deletingLastPathComponent().path ?? "another location"
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "EQBar is already running"
    alert.informativeText = """
      Another copy of EQBar is already running (from \(location)), and it's shown in the menu bar.

      Only one copy can process your Mac's audio at a time. Keep using the running copy, or quit it \
      and use this one instead.
      """
    alert.addButton(withTitle: "Keep the Running Copy")
    alert.addButton(withTitle: "Quit It and Use This Copy")
    return alert.runModal() == .alertFirstButtonReturn ? .keepRunning : .replace
  }

  /// Quits the running copy (gracefully, so it releases its audio taps), then takes ownership.
  /// Calls back on the main thread with whether this copy now owns audio.
  static func replace(_ pid: pid_t, completion: @escaping (Bool) -> Void) {
    let running = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
    running?.terminate()
    var attempts = 0
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
      attempts += 1
      if acquire() == nil {
        timer.invalidate()
        completion(true)
      } else if attempts == 50 {
        running?.forceTerminate()        // didn't quit within 5 s
      } else if attempts > 80 {
        timer.invalidate()
        completion(false)
      }
    }
  }
}
