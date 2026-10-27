import Foundation

public struct EQPreset: Codable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var mode: EQMode
  public var basic: BasicGains?
  public var graphic: [Double]?
  public var expert: [EQBand]?
  /// nil means "use auto preamp".
  public var preampDB: Double?

  public var isBuiltIn: Bool { id.hasPrefix("builtin.") }

  public init(id: String = UUID().uuidString, name: String, mode: EQMode,
              basic: BasicGains? = nil, graphic: [Double]? = nil, expert: [EQBand]? = nil, preampDB: Double? = nil) {
    self.id = id
    self.name = name
    self.mode = mode
    self.basic = basic
    self.graphic = graphic
    self.expert = expert
    self.preampDB = preampDB
  }
}

public enum BuiltInPresets {
  private static func graphic(_ name: String, _ gains: [Double]) -> EQPreset {
    let id = "builtin." + name.lowercased().replacingOccurrences(of: " ", with: "-")
    return EQPreset(id: id, name: name, mode: .advanced, graphic: gains)
  }

  // Bands: 32, 64, 125, 250, 500, 1K, 2K, 4K, 8K, 16K Hz.
  public static let advanced: [EQPreset] = [
    graphic("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    graphic("Acoustic", [4, 4, 3, 1, 1.5, 1.5, 3, 3.5, 3, 2]),
    graphic("Bass Boost", [6, 5, 4, 2.5, 1, 0, 0, 0, 0, 0]),
    graphic("Bass Cut", [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0]),
    graphic("Classical", [4, 3, 2.5, 2, -1, -1, 0, 2, 3, 3.5]),
    graphic("Dance", [3.5, 5, 4, 0, 1, 2.5, 4, 3.5, 3, 0]),
    graphic("Electronic", [4, 3.5, 1, 0, -2, 1.5, 1, 1, 3.5, 4]),
    graphic("Hip-Hop", [5, 4, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]),
    graphic("Jazz", [3.5, 2.5, 1, 2, -1.5, -1.5, 0, 1, 2.5, 3.5]),
    graphic("Loudness", [6, 4, 0, -1, -2, -1, 0, 1, 4, 5]),
    graphic("Pop", [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
    graphic("R&B", [2.5, 5.5, 4.5, 1.5, -2, -1.5, 2, 2.5, 3, 3.5]),
    graphic("Rock", [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
    graphic("Small Speakers", [-6, -3, 3, 3, 1, 0, 1, 2, 2, 1]),
    graphic("Spoken Word", [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 4.5, 4, 2.5, 0]),
    graphic("Treble Boost", [0, 0, 0, 0, 0, 1.5, 3, 4.5, 5.5, 6]),
    graphic("Treble Cut", [0, 0, 0, 0, 0, -1.5, -3, -4.5, -5.5, -6]),
    graphic("Vocal Boost", [-1.5, -3, -3, 1.5, 3.5, 3.5, 3, 1.5, 0, -1.5])
  ]

  public static let basicFlat = EQPreset(id: "builtin.basic-flat", name: "Flat", mode: .basic, basic: BasicGains())
  public static let expertFlat = EQPreset(id: "builtin.expert-flat", name: "Flat", mode: .expert,
                                          expert: EQSettings.defaultExpert)

  public static func presets(for mode: EQMode) -> [EQPreset] {
    switch mode {
    case .basic: return [basicFlat]
    case .advanced: return advanced
    case .expert: return [expertFlat]
    }
  }
}
