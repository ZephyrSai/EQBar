import Foundation

public enum FilterType: String, Codable, CaseIterable {
  case peak, lowShelf, highShelf, lowPass, highPass, bandPass, notch

  public var shortName: String {
    switch self {
    case .peak: return "Peak"
    case .lowShelf: return "Low Shelf"
    case .highShelf: return "High Shelf"
    case .lowPass: return "Low Pass"
    case .highPass: return "High Pass"
    case .bandPass: return "Band Pass"
    case .notch: return "Notch"
    }
  }

  public var usesGain: Bool { self == .peak || self == .lowShelf || self == .highShelf }
}

public struct EQBand: Codable, Equatable, Identifiable {
  public var id = UUID()
  public var type: FilterType = .peak
  public var frequency: Double = 1000
  public var gain: Double = 0
  public var q: Double = 1.0
  public var enabled = true

  public init(type: FilterType = .peak, frequency: Double = 1000, gain: Double = 0, q: Double = 1.0, enabled: Bool = true) {
    self.type = type
    self.frequency = frequency
    self.gain = gain
    self.q = q
    self.enabled = enabled
  }
}

/// Normalised biquad (a0 == 1).
public struct Biquad: Equatable {
  public var b0, b1, b2, a1, a2: Double

  public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

  public func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
    let w = 2 * Double.pi * frequency / sampleRate
    let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
    let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
    let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
    return 10 * log10(max(nr * nr + ni * ni, 1e-30) / max(dr * dr + di * di, 1e-30))
  }
}

public extension EQBand {
  /// RBJ "Audio EQ Cookbook" coefficients. Shelf Q follows the same convention as Equalizer APO / AutoEq.
  func biquad(sampleRate: Double) -> Biquad {
    let f = min(max(frequency, 10), sampleRate * 0.49)
    let q = max(self.q, 0.05)
    let a = pow(10, gain / 40)
    let w0 = 2 * Double.pi * f / sampleRate
    let cw = cos(w0), sw = sin(w0)
    let alpha = sw / (2 * q)
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0

    switch type {
    case .peak:
      b0 = 1 + alpha * a; b1 = -2 * cw; b2 = 1 - alpha * a
      a0 = 1 + alpha / a; a1 = -2 * cw; a2 = 1 - alpha / a
    case .lowShelf:
      let s = 2 * sqrt(a) * alpha
      b0 = a * ((a + 1) - (a - 1) * cw + s)
      b1 = 2 * a * ((a - 1) - (a + 1) * cw)
      b2 = a * ((a + 1) - (a - 1) * cw - s)
      a0 = (a + 1) + (a - 1) * cw + s
      a1 = -2 * ((a - 1) + (a + 1) * cw)
      a2 = (a + 1) + (a - 1) * cw - s
    case .highShelf:
      let s = 2 * sqrt(a) * alpha
      b0 = a * ((a + 1) + (a - 1) * cw + s)
      b1 = -2 * a * ((a - 1) + (a + 1) * cw)
      b2 = a * ((a + 1) + (a - 1) * cw - s)
      a0 = (a + 1) - (a - 1) * cw + s
      a1 = 2 * ((a - 1) - (a + 1) * cw)
      a2 = (a + 1) - (a - 1) * cw - s
    case .lowPass:
      b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2
      a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
    case .highPass:
      b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2
      a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
    case .bandPass:
      b0 = alpha; b1 = 0; b2 = -alpha
      a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
    case .notch:
      b0 = 1; b1 = -2 * cw; b2 = 1
      a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
    }
    return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
  }
}

public enum EQMath {
  /// Log-spaced frequencies between 20 Hz and 20 kHz.
  public static func logFrequencies(count: Int, from low: Double = 20, to high: Double = 20_000) -> [Double] {
    guard count > 1 else { return [low] }
    let ratio = log(high / low)
    return (0..<count).map { low * exp(ratio * Double($0) / Double(count - 1)) }
  }

  /// Combined response of a filter cascade, in dB, at each frequency.
  public static func response(_ filters: [Biquad], at frequencies: [Double], sampleRate: Double) -> [Double] {
    frequencies.map { f in filters.reduce(0) { $0 + $1.magnitudeDB(at: f, sampleRate: sampleRate) } }
  }

  /// Highest point of the cascade's response — what auto-preamp has to cut to avoid clipping.
  public static func peakGain(_ bands: [EQBand], sampleRate: Double) -> Double {
    let filters = bands.filter(\.enabled).map { $0.biquad(sampleRate: sampleRate) }
    guard !filters.isEmpty else { return 0 }
    return response(filters, at: logFrequencies(count: 160), sampleRate: sampleRate).max() ?? 0
  }
}

public enum EQMode: String, Codable, CaseIterable {
  case basic, advanced, expert

  public var title: String {
    switch self {
    case .basic: return "Basic"
    case .advanced: return "Advanced"
    case .expert: return "Expert"
    }
  }
}

public struct BasicGains: Codable, Equatable {
  public var bass = 0.0
  public var mid = 0.0
  public var treble = 0.0

  public init(bass: Double = 0, mid: Double = 0, treble: Double = 0) {
    self.bass = bass
    self.mid = mid
    self.treble = treble
  }
}

public enum GraphicEQ {
  public static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
  public static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
  /// One-octave bands: adjacent bands overlap smoothly instead of leaving dips between them.
  public static let q = 1.41
}

public struct EQSettings: Codable, Equatable {
  public var enabled = true
  public var mode: EQMode = .advanced
  public var basic = BasicGains()
  public var graphic: [Double] = Array(repeating: 0, count: 10)
  public var expert: [EQBand] = EQSettings.defaultExpert
  public var preampDB = 0.0
  public var autoPreamp = true
  public var presetName = "Flat"

  public init() {}

  public static let defaultExpert: [EQBand] = [
    EQBand(type: .lowShelf, frequency: 105, gain: 0, q: 0.7),
    EQBand(type: .peak, frequency: 1000, gain: 0, q: 1.0),
    EQBand(type: .highShelf, frequency: 10000, gain: 0, q: 0.7)
  ]

  /// The filter cascade the current mode produces.
  public func bands() -> [EQBand] {
    switch mode {
    case .basic:
      return [
        EQBand(type: .lowShelf, frequency: 120, gain: basic.bass, q: 0.7),
        EQBand(type: .peak, frequency: 1000, gain: basic.mid, q: 0.6),
        EQBand(type: .highShelf, frequency: 6000, gain: basic.treble, q: 0.7)
      ]
    case .advanced:
      return zip(GraphicEQ.frequencies, graphic).map { EQBand(type: .peak, frequency: $0, gain: $1, q: GraphicEQ.q) }
    case .expert:
      return expert
    }
  }
}

// Tolerant decoding (see Settings.swift). Must live in the same file as the types' synthesized CodingKeys.

extension EQSettings {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = EQSettings()
    enabled = c.value(.enabled, d.enabled)
    mode = c.value(.mode, d.mode)
    basic = c.value(.basic, d.basic)
    graphic = c.value(.graphic, d.graphic)
    if graphic.count != GraphicEQ.frequencies.count { graphic = d.graphic }
    expert = c.value(.expert, d.expert)
    preampDB = c.value(.preampDB, d.preampDB)
    autoPreamp = c.value(.autoPreamp, d.autoPreamp)
    presetName = c.value(.presetName, d.presetName)
  }
}

extension EQBand {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = EQBand()
    id = c.value(.id, UUID())
    type = c.value(.type, d.type)
    frequency = c.value(.frequency, d.frequency)
    gain = c.value(.gain, d.gain)
    q = c.value(.q, d.q)
    enabled = c.value(.enabled, d.enabled)
  }
}
