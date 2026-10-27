import Foundation

/// Reads EQ files people already have:
///  • Equalizer APO / AutoEq `ParametricEQ.txt` (also what autoeq.app exports),
///  • eqMac's exported Advanced EQ presets (JSON array with 10-band gains),
///  • generic JSON with a `preamp` and a `bands`/`filters` array.
public enum EQImport {
  public enum Content {
    case profile(ParametricProfile)
    case presets([EQPreset])
  }

  public static func parse(_ data: Data) -> Content? {
    if let json = try? JSONSerialization.jsonObject(with: data) {
      if let array = json as? [[String: Any]] {
        let presets = array.compactMap(eqMacPreset)
        if !presets.isEmpty { return .presets(presets) }
      }
      if let object = json as? [String: Any], let profile = genericProfile(object) {
        return .profile(profile)
      }
      return nil
    }
    guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
          let profile = ParametricEQParser.parse(text) else { return nil }
    return .profile(profile)
  }

  private static func number(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
  }

  /// `{"name": "Rock", "gains": {"global": 0, "bands": [10 values]}}`
  private static func eqMacPreset(_ object: [String: Any]) -> EQPreset? {
    guard let name = object["name"] as? String,
          let gains = object["gains"] as? [String: Any],
          let bands = gains["bands"] as? [Any] else { return nil }
    let values = bands.compactMap(number)
    guard values.count == GraphicEQ.frequencies.count else { return nil }
    let global = number(gains["global"]) ?? 0
    return EQPreset(name: name, mode: .advanced, graphic: values.map { max(-24, min(24, $0)) },
                    preampDB: global == 0 ? nil : global)
  }

  private static func genericProfile(_ object: [String: Any]) -> ParametricProfile? {
    let list = (object["bands"] ?? object["filters"] ?? object["peqs"]) as? [[String: Any]] ?? []
    let bands: [EQBand] = list.compactMap { item in
      guard let frequency = number(item["frequency"] ?? item["fc"] ?? item["freq"]) else { return nil }
      let typeName = ((item["type"] as? String) ?? "peak").lowercased()
      let type: FilterType
      switch typeName {
      case "lowshelf", "low_shelf", "ls", "lsc": type = .lowShelf
      case "highshelf", "high_shelf", "hs", "hsc": type = .highShelf
      case "lowpass", "low_pass", "lp", "lpq": type = .lowPass
      case "highpass", "high_pass", "hp", "hpq": type = .highPass
      case "bandpass", "band_pass", "bp": type = .bandPass
      case "notch", "no": type = .notch
      default: type = .peak
      }
      let enabled = (item["enabled"] as? Bool) ?? true
      return EQBand(type: type, frequency: frequency, gain: number(item["gain"]) ?? 0,
                    q: number(item["q"] ?? item["Q"]) ?? 0.71, enabled: enabled)
    }
    guard !bands.isEmpty else { return nil }
    let preamp = number(object["preamp"] ?? object["preampDB"] ?? object["global"]) ?? 0
    return ParametricProfile(preampDB: preamp, bands: bands)
  }
}
