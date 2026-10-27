import Accelerate
import CAtomics
import Foundation

/// Single-producer ring of recent output samples (mono) for the analyzer.
/// The audio thread writes only while the analyzer is visible.
public final class SampleRing {
  public let capacity: Int
  private let mask: Int
  private let buffer: UnsafeMutablePointer<Float>
  private let written: UnsafeMutablePointer<Int64>
  private var writerPosition: Int64 = 0

  init(capacity: Int = 8192) {
    precondition(capacity > 0 && capacity & (capacity - 1) == 0, "capacity must be a power of two")
    self.capacity = capacity
    mask = capacity - 1
    buffer = .allocate(capacity: capacity)
    buffer.initialize(repeating: 0, count: capacity)
    written = .allocate(capacity: 1)
    written.initialize(to: 0)
  }

  deinit {
    buffer.deallocate()
    written.deallocate()
  }

  /// Audio thread.
  func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames n: Int) {
    var position = Int(writerPosition)
    for i in 0..<n {
      buffer[position & mask] = 0.5 * (left[i] + right[i])
      position += 1
    }
    writerPosition = Int64(position)
    eqb_store_i64(written, writerPosition)
  }

  /// Total samples written so far; unchanged between reads means no new audio.
  public var totalWritten: Int64 { eqb_load_i64(written) }

  /// UI thread. Copies the most recent `count` samples; false until enough audio has arrived.
  public func copyLatest(_ count: Int, into destination: UnsafeMutablePointer<Float>) -> Bool {
    let end = Int(eqb_load_i64(written))
    guard count <= capacity, end >= count else { return false }
    let start = end - count
    for i in 0..<count { destination[i] = buffer[(start + i) & mask] }
    return true
  }
}

/// FFT analyzer producing log-spaced bars in dBFS. Runs on the UI thread only while visible.
public final class SpectrumAnalyzer {
  public let bandCount: Int
  public private(set) var levels: [Float]

  private let size = 4096
  private let log2n: vDSP_Length = 12
  private let setup: FFTSetup
  private var samples: [Float]
  private var window: [Float]
  private var real: [Float]
  private var imag: [Float]
  private var power: [Float]
  private var edges: [Int] = []
  private var edgesSampleRate = 0.0

  public init(bandCount: Int = 56) {
    self.bandCount = bandCount
    levels = Array(repeating: -90, count: bandCount)
    setup = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))!
    samples = Array(repeating: 0, count: size)
    window = Array(repeating: 0, count: size)
    vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    real = Array(repeating: 0, count: size / 2)
    imag = Array(repeating: 0, count: size / 2)
    power = Array(repeating: 0, count: size / 2)
  }

  deinit { vDSP_destroy_fftsetup(setup) }

  private func updateEdges(sampleRate: Double) {
    guard sampleRate != edgesSampleRate else { return }
    edgesSampleRate = sampleRate
    let binHz = sampleRate / Double(size)
    let freqs = EQMath.logFrequencies(count: bandCount + 1)
    edges = freqs.map { max(1, min(size / 2 - 1, Int(($0 / binHz).rounded()))) }
  }

  /// Pulls the newest audio from `ring` and updates `levels` (fast attack, slow fall).
  @discardableResult
  public func update(from ring: SampleRing, sampleRate: Double) -> Bool {
    updateEdges(sampleRate: sampleRate)
    let ok = samples.withUnsafeMutableBufferPointer { ring.copyLatest(size, into: $0.baseAddress!) }
    guard ok else { return false }

    samples.withUnsafeMutableBufferPointer { s in
      vDSP_vmul(s.baseAddress!, 1, window, 1, s.baseAddress!, 1, vDSP_Length(size))
    }
    real.withUnsafeMutableBufferPointer { realPtr in
      imag.withUnsafeMutableBufferPointer { imagPtr in
        var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
        samples.withUnsafeBufferPointer { input in
          input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
          }
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size / 2))
      }
    }

    // A full-scale sine through a Hann window and zrip's ×2 scaling peaks at (size / 2)².
    let reference = Float(size / 2) * Float(size / 2)
    for band in 0..<bandCount {
      let lo = edges[band], hi = max(edges[band + 1], lo + 1)
      var peak: Float = 0
      for bin in lo..<min(hi, size / 2) { peak = max(peak, power[bin]) }
      let db = max(-90, 10 * log10f(max(peak / reference, 1e-12)))
      levels[band] = db > levels[band] ? db : max(db, levels[band] - 2.5)
    }
    return true
  }

  public func decay() {
    for i in levels.indices { levels[i] = max(-90, levels[i] - 2.5) }
  }
}
