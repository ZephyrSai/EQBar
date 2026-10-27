import Foundation

public enum CrossfeedLevel: String, Codable, CaseIterable {
  case off, light, medium, strong

  public var title: String {
    switch self {
    case .off: return "Off"
    case .light: return "Light"
    case .medium: return "Medium"
    case .strong: return "Strong"
    }
  }
}

public enum RoomType: Int, Codable, CaseIterable {
  case none = -1
  case smallRoom = 0, mediumRoom, largeRoom, mediumHall, largeHall, plate
  case mediumChamber, largeChamber, cathedral, largeRoom2, mediumHall2, mediumHall3, largeHall2

  public var title: String {
    switch self {
    case .none: return "Dry (no room)"
    case .smallRoom: return "Small Room"
    case .mediumRoom: return "Medium Room"
    case .largeRoom: return "Large Room"
    case .largeRoom2: return "Large Room 2"
    case .mediumHall: return "Medium Hall"
    case .mediumHall2: return "Medium Hall 2"
    case .mediumHall3: return "Medium Hall 3"
    case .largeHall: return "Concert Hall"
    case .largeHall2: return "Concert Hall 2"
    case .plate: return "Plate"
    case .mediumChamber: return "Medium Chamber"
    case .largeChamber: return "Large Chamber"
    case .cathedral: return "Cathedral"
    }
  }

  /// Ordered roughly by size for the picker.
  public static let menuOrder: [RoomType] = [
    .none, .smallRoom, .mediumRoom, .largeRoom, .largeRoom2, .mediumChamber, .largeChamber,
    .mediumHall, .mediumHall2, .mediumHall3, .largeHall, .largeHall2, .cathedral, .plate
  ]
}

public struct SpatialSettings: Codable, Equatable {
  public var enabled = false
  public var output: SpatialOutputKind = .auto
  public var room: RoomType = .mediumRoom
  /// Wet/dry blend of the room, 0–100.
  public var roomAmount = 25.0
  /// Angle of each virtual speaker from centre, in degrees.
  public var speakerAngle = 30.0
  /// Apple's newer renderer with the user's personalized HRTF. Much heavier (its rooms are convolution
  /// reverbs), so it's opt-in.
  public var personalizedHRTF = false

  public init() {}
}

public struct AppVolume: Codable, Equatable {
  /// 0–1.5; above 1 boosts up to +6 dB.
  public var volume = 1.0
  public var muted = false
  public var name = ""

  public init(volume: Double = 1, muted: Bool = false, name: String = "") {
    self.volume = volume
    self.muted = muted
    self.name = name
  }

  public var isDefault: Bool { abs(volume - 1) < 0.001 && !muted }
}

public struct PluginDescriptor: Codable, Hashable {
  public var type: UInt32
  public var subtype: UInt32
  public var manufacturer: UInt32
  public var name: String
  public var manufacturerName: String

  public init(type: UInt32, subtype: UInt32, manufacturer: UInt32, name: String, manufacturerName: String) {
    self.type = type
    self.subtype = subtype
    self.manufacturer = manufacturer
    self.name = name
    self.manufacturerName = manufacturerName
  }
}

public struct PluginSetting: Codable, Equatable, Identifiable {
  public var id = UUID()
  public var descriptor: PluginDescriptor
  public var bypassed = false
  public var state: Data?

  public init(descriptor: PluginDescriptor) { self.descriptor = descriptor }
}

public struct AppSettings: Codable, Equatable {
  public var enabled = true
  /// 0–2; above 1 is boost (up to +12 dB).
  public var volume = 1.0
  public var balance = 0.0
  public var muted = false
  public var eq = EQSettings()
  public var spatial = SpatialSettings()
  public var crossfeed: CrossfeedLevel = .off
  /// 0 = mono, 1 = unchanged, 2 = extra wide.
  public var stereoWidth = 1.0
  public var limiter = true
  public var appVolumes: [String: AppVolume] = [:]
  public var plugins: [PluginSetting] = []
  public var userPresets: [EQPreset] = []
  public var showSpectrum = true
  /// Volume keys continue past 100% into boost, and control outputs without their own volume (HDMI).
  /// Needs the Accessibility permission.
  public var volumeKeys = true
  /// The Accessibility prompt is shown automatically only once.
  public var accessibilityPrompted = false

  public init() {}
}

// MARK: - Tolerant decoding
// Every field falls back to its default, so settings files survive new versions adding or renaming fields.

extension KeyedDecodingContainer {
  func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) -> T {
    ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
  }
}

extension AppSettings {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = AppSettings()
    enabled = c.value(.enabled, d.enabled)
    volume = c.value(.volume, d.volume)
    balance = c.value(.balance, d.balance)
    muted = c.value(.muted, d.muted)
    eq = c.value(.eq, d.eq)
    spatial = c.value(.spatial, d.spatial)
    crossfeed = c.value(.crossfeed, d.crossfeed)
    stereoWidth = c.value(.stereoWidth, d.stereoWidth)
    limiter = c.value(.limiter, d.limiter)
    appVolumes = c.value(.appVolumes, d.appVolumes)
    plugins = c.value(.plugins, d.plugins)
    userPresets = c.value(.userPresets, d.userPresets)
    showSpectrum = c.value(.showSpectrum, d.showSpectrum)
    volumeKeys = c.value(.volumeKeys, d.volumeKeys)
    accessibilityPrompted = c.value(.accessibilityPrompted, d.accessibilityPrompted)
  }
}

extension SpatialSettings {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = SpatialSettings()
    enabled = c.value(.enabled, d.enabled)
    output = c.value(.output, d.output)
    room = c.value(.room, d.room)
    roomAmount = c.value(.roomAmount, d.roomAmount)
    speakerAngle = c.value(.speakerAngle, d.speakerAngle)
    personalizedHRTF = c.value(.personalizedHRTF, d.personalizedHRTF)
  }
}

/// Settings live in one small JSON file in Application Support.
public final class SettingsStore {
  public let url: URL

  public init(directory: URL? = nil) {
    let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("EQBar", isDirectory: true)
    url = base.appendingPathComponent("settings.json")
  }

  public func load() -> AppSettings {
    guard let data = try? Data(contentsOf: url),
          let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
    return settings
  }

  public func save(_ settings: AppSettings) {
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(settings).write(to: url, options: .atomic)
    } catch {
      NSLog("EQBar: saving settings failed: \(error)")
    }
  }
}
