import Foundation

/// Headphone crossfeed after Boris Mikhaylov's bs2b design: each ear gets a low-passed, slightly
/// delayed copy of the opposite channel, which takes the "inside the skull" edge off hard-panned mixes.
public struct CrossfeedCoefficients: Equatable {
  var a0Lo, b1Lo, a0Hi, a1Hi, b1Hi, gain: Double

  /// Presets match bs2b's: default (700 Hz, 4.5 dB), Chu Moy (700 Hz, 6 dB), Jan Meier (650 Hz, 9.5 dB).
  public static func make(_ level: CrossfeedLevel, sampleRate: Double) -> CrossfeedCoefficients? {
    let fc: Double, feed: Double
    switch level {
    case .off: return nil
    case .light: fc = 700; feed = 4.5
    case .medium: fc = 700; feed = 6.0
    case .strong: fc = 650; feed = 9.5
    }
    let gbLo = feed * -5.0 / 6.0 - 3.0
    let gbHi = feed / 6.0 - 3.0
    let gLo = pow(10, gbLo / 20)
    let gHi = 1 - pow(10, gbHi / 20)
    let fcHi = fc * pow(2, (gbLo - 20 * log10(gHi)) / 12)

    var x = exp(-2 * Double.pi * fc / sampleRate)
    let b1Lo = x
    let a0Lo = gLo * (1 - x)
    x = exp(-2 * Double.pi * fcHi / sampleRate)
    return CrossfeedCoefficients(a0Lo: a0Lo, b1Lo: b1Lo,
                                 a0Hi: 1 - gHi * (1 - x), a1Hi: -x, b1Hi: x,
                                 gain: 1 / (1 - gHi + gLo))
  }
}

struct CrossfeedState {
  private var loL = 0.0, loR = 0.0, hiL = 0.0, hiR = 0.0, lastL = 0.0, lastR = 0.0

  mutating func reset() { self = CrossfeedState() }

  mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames n: Int,
                        _ c: CrossfeedCoefficients) {
    for i in 0..<n {
      let l = Double(left[i]), r = Double(right[i])
      loL = c.a0Lo * l + c.b1Lo * loL
      loR = c.a0Lo * r + c.b1Lo * loR
      hiL = c.a0Hi * l + c.a1Hi * lastL + c.b1Hi * hiL
      hiR = c.a0Hi * r + c.a1Hi * lastR + c.b1Hi * hiR
      lastL = l
      lastR = r
      left[i] = Float((hiL + loR) * c.gain)
      right[i] = Float((hiR + loL) * c.gain)
    }
  }
}
