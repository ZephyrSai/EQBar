import Foundation

/// The "System Audio Recording" permission (TCC service kTCCServiceAudioCapture) that Core Audio taps need.
///
/// macOS has no public API to query or request it, so this uses the TCC framework's C entry points,
/// the same approach Apple-adjacent samples such as AudioCap use. If the symbols are missing the
/// status is `.unknown` and the system prompt appears when the tap first delivers audio.
public enum CapturePermission {
  public enum Status { case authorized, denied, unknown }

  private static let service = "kTCCServiceAudioCapture" as CFString
  private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

  private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
  // The completion block is retained by TCC until the user answers, so it must be escaping.
  private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

  public static var status: Status {
    guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
    switch unsafeBitCast(symbol, to: PreflightFn.self)(service, nil) {
    case 0: return .authorized
    case 1: return .denied
    default: return .unknown
    }
  }

  /// Shows the system prompt. Returns false if the request API isn't available.
  @discardableResult
  public static func request(_ completion: @escaping (Bool) -> Void) -> Bool {
    guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return false }
    unsafeBitCast(symbol, to: RequestFn.self)(service, nil) { granted in completion(granted) }
    return true
  }

  public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}
