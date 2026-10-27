import Foundation

/// Stereo biquad cascade (transposed direct form II, double precision).
///
/// Filter state persists across parameter changes. When coefficients change, they are ramped
/// linearly across one render block so slider moves don't click. Real-time safe.
final class EQProcessor {
  static let maxBands = 64

  private let current: UnsafeMutablePointer<Double>   // maxBands × 5 coefficients in use
  private let state: UnsafeMutablePointer<Double>     // maxBands × 4: L z1, L z2, R z1, R z2
  private var activeCount = 0

  init() {
    current = .allocate(capacity: Self.maxBands * 5)
    current.initialize(repeating: 0, count: Self.maxBands * 5)
    state = .allocate(capacity: Self.maxBands * 4)
    state.initialize(repeating: 0, count: Self.maxBands * 4)
  }

  deinit {
    current.deallocate()
    state.deallocate()
  }

  func reset() {
    guard activeCount > 0 else { return }
    activeCount = 0
    state.update(repeating: 0, count: Self.maxBands * 4)
  }

  /// `target` holds `count` × (b0, b1, b2, a1, a2).
  func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames n: Int,
               target: UnsafePointer<Double>, count requested: Int) {
    let count = min(requested, Self.maxBands)
    if count > activeCount {
      // Newly activated bands start at their target with clean state, no ramp from stale values.
      for band in activeCount..<count {
        (current + band * 5).update(from: target + band * 5, count: 5)
        (state + band * 4).update(repeating: 0, count: 4)
      }
    }
    activeCount = count
    guard count > 0, n > 0 else { return }

    let inv = 1.0 / Double(n)
    for band in 0..<count {
      let c = current + band * 5
      let t = target + band * 5
      let s = state + band * 4
      var b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2 = c[4]
      let d0 = (t[0] - b0) * inv, d1 = (t[1] - b1) * inv, d2 = (t[2] - b2) * inv
      let d3 = (t[3] - a1) * inv, d4 = (t[4] - a2) * inv
      var l1 = s[0], l2 = s[1], r1 = s[2], r2 = s[3]
      let ramping = d0 != 0 || d1 != 0 || d2 != 0 || d3 != 0 || d4 != 0

      if ramping {
        for i in 0..<n {
          b0 += d0; b1 += d1; b2 += d2; a1 += d3; a2 += d4
          let xl = Double(left[i])
          let yl = b0 * xl + l1
          l1 = b1 * xl - a1 * yl + l2
          l2 = b2 * xl - a2 * yl
          left[i] = Float(yl)
          let xr = Double(right[i])
          let yr = b0 * xr + r1
          r1 = b1 * xr - a1 * yr + r2
          r2 = b2 * xr - a2 * yr
          right[i] = Float(yr)
        }
        c.update(from: t, count: 5)
      } else {
        for i in 0..<n {
          let xl = Double(left[i])
          let yl = b0 * xl + l1
          l1 = b1 * xl - a1 * yl + l2
          l2 = b2 * xl - a2 * yl
          left[i] = Float(yl)
          let xr = Double(right[i])
          let yr = b0 * xr + r1
          r1 = b1 * xr - a1 * yr + r2
          r2 = b2 * xr - a2 * yr
          right[i] = Float(yr)
        }
      }
      s[0] = l1; s[1] = l2; s[2] = r1; s[3] = r2
    }
  }
}
