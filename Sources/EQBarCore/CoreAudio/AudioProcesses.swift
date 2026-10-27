import AppKit
import CoreAudio
import Darwin

/// One Core Audio client process (an app, or a helper such as a browser's audio service).
public struct AudioProcessInfo: Equatable {
  public let objectID: AudioObjectID
  public let pid: pid_t
  public let bundleID: String?
  public let isRunningOutput: Bool
}

/// Processes grouped by the app the user would recognise (helpers fold into their parent app).
public struct AudioApp: Equatable {
  public let key: String
  public let name: String
  public let pid: pid_t
  public var processObjects: [AudioObjectID]
  public var isPlaying: Bool
}

public enum AudioProcesses {
  public static func all() -> [AudioProcessInfo] {
    let ids = AudioObject.getArray(AudioObject.system, .init(kAudioHardwarePropertyProcessObjectList),
                                   of: AudioObjectID.self)
    return ids.map { id in
      let pid = (try? AudioObject.get(id, .init(kAudioProcessPropertyPID), initial: pid_t(-1))) ?? -1
      let bundle = AudioObject.getString(id, .init(kAudioProcessPropertyBundleID))
      let running = (try? AudioObject.get(id, .init(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0))) ?? 0
      return AudioProcessInfo(objectID: id, pid: pid, bundleID: bundle, isRunningOutput: running != 0)
    }
  }

  /// This app's own process object, which must never be tapped (it would feed back into itself).
  public static func ownObject() -> AudioObjectID? {
    var pid = getpid()
    var address = AudioObjectPropertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObject.system, &address,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
    return status == noErr && object != kAudioObjectUnknown ? object : nil
  }

  private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
  // Maps helper processes (e.g. WebKit's GPU process) to the app responsible for them.
  private static let responsiblePID: ResponsibleFn? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
      return nil
    }
    return unsafeBitCast(symbol, to: ResponsibleFn.self)
  }()

  public static func apps() -> [AudioApp] {
    let own = getpid()
    var byKey: [String: AudioApp] = [:]
    var order: [String] = []
    for process in all() where process.pid > 0 && process.pid != own {
      let owner = responsiblePID?(process.pid) ?? process.pid
      let app = NSRunningApplication(processIdentifier: owner > 0 ? owner : process.pid)
        ?? NSRunningApplication(processIdentifier: process.pid)
      let key = app?.bundleIdentifier ?? process.bundleID ?? "pid.\(process.pid)"
      let name = app?.localizedName ?? process.bundleID ?? "Process \(process.pid)"
      if var existing = byKey[key] {
        existing.processObjects.append(process.objectID)
        existing.isPlaying = existing.isPlaying || process.isRunningOutput
        byKey[key] = existing
      } else {
        byKey[key] = AudioApp(key: key, name: name, pid: app?.processIdentifier ?? process.pid,
                              processObjects: [process.objectID], isPlaying: process.isRunningOutput)
        order.append(key)
      }
    }
    return order.compactMap { byKey[$0] }
  }
}
