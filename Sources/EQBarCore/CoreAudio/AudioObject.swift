import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
  public let status: OSStatus
  public let context: String

  public var description: String { "\(context) failed (\(fourCC(status)))" }
}

/// Renders an OSStatus as a four-character code when it is one ('!obj'), otherwise as a number.
public func fourCC(_ status: OSStatus) -> String {
  let n = UInt32(bitPattern: status)
  let bytes = [24, 16, 8, 0].map { UInt8((n >> UInt32($0)) & 0xFF) }
  if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let s = String(bytes: bytes, encoding: .ascii) {
    return "'\(s)'"
  }
  return "\(status)"
}

@inline(__always)
func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
  if status != noErr { throw CoreAudioError(status: status, context: context()) }
}

public extension AudioObjectPropertyAddress {
  init(_ selector: AudioObjectPropertySelector,
       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
       _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
    self.init(mSelector: selector, mScope: scope, mElement: element)
  }
}

/// Thin, allocation-light wrappers around the AudioObject property API.
public enum AudioObject {
  public static let system = AudioObjectID(kAudioObjectSystemObject)

  public static func has(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
    var a = address
    return AudioObjectHasProperty(id, &a)
  }

  public static func isSettable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
    var a = address
    var settable: DarwinBoolean = false
    return AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
  }

  public static func get<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) throws -> T {
    var a = address
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    try check(status, "Reading \(fourCC(OSStatus(bitPattern: address.mSelector)))")
    return value
  }

  public static func set<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
    var a = address
    var v = value
    let status = withUnsafePointer(to: &v) { AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
    try check(status, "Writing \(fourCC(OSStatus(bitPattern: address.mSelector)))")
  }

  public static func getArray<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, of _: T.Type) -> [T] {
    var a = address
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    guard count > 0 else { return [] }
    return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
      var s = size
      let status = AudioObjectGetPropertyData(id, &a, 0, nil, &s, buffer.baseAddress!)
      initialized = status == noErr ? min(count, Int(s) / MemoryLayout<T>.stride) : 0
    }
  }

  public static func getString(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
    var a = address
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
    }
    guard status == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
  }

  /// Channel count of every buffer in a stream-configuration AudioBufferList.
  public static func bufferChannels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
    var a = AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return [] }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.map { Int($0.mNumberChannels) }
  }
}

/// Keeps a Core Audio property listener registered for as long as the object is alive.
public final class PropertyListener {
  private let objectID: AudioObjectID
  private var address: AudioObjectPropertyAddress
  private let queue: DispatchQueue
  // Stored as a block so the exact same block pointer is passed to add and remove.
  private let block: AudioObjectPropertyListenerBlock
  private var registered = false

  public init(_ objectID: AudioObjectID,
              _ address: AudioObjectPropertyAddress,
              queue: DispatchQueue = .main,
              handler: @escaping () -> Void) {
    self.objectID = objectID
    self.address = address
    self.queue = queue
    self.block = { _, _ in handler() }
    registered = AudioObjectAddPropertyListenerBlock(objectID, &self.address, queue, block) == noErr
  }

  public func cancel() {
    guard registered else { return }
    AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    registered = false
  }

  deinit { cancel() }
}
