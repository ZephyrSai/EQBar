import CAtomics
import Foundation

/// Immutable bundle of everything the audio thread needs for one configuration.
/// Built on the main thread, handed over through `SnapshotMailbox`.
final class ParamSnapshot {
  var generation: Int64 = 0

  let eqCoefficients: UnsafeMutablePointer<Double>
  let eqCount: Int
  let preamp: Float
  let gainLeft: Float
  let gainRight: Float
  let tapGains: UnsafeMutablePointer<Float>
  let tapCount: Int
  let crossfeed: CrossfeedCoefficients?
  let width: Float
  let limiter: Bool
  let analyzer: Bool
  let spatial: SpatialProcessor?
  let plugins: ContiguousArray<HostedPlugin>
  /// After this many frames of digital silence the effect tails have died out and processing is skipped.
  let silenceFrames: Int

  init(eq: [Double] = [], preamp: Float = 1, gainLeft: Float = 1, gainRight: Float = 1,
       tapGains: [Float] = [], crossfeed: CrossfeedCoefficients? = nil, width: Float = 1,
       limiter: Bool = false, analyzer: Bool = false, spatial: SpatialProcessor? = nil,
       plugins: [HostedPlugin] = [], silenceFrames: Int = 12_000) {
    self.silenceFrames = silenceFrames
    eqCount = eq.count / 5
    let coefficients = UnsafeMutablePointer<Double>.allocate(capacity: max(eq.count, 5))
    coefficients.initialize(repeating: 0, count: max(eq.count, 5))
    eq.withUnsafeBufferPointer { if let base = $0.baseAddress { coefficients.update(from: base, count: eq.count) } }
    eqCoefficients = coefficients
    self.preamp = preamp
    self.gainLeft = gainLeft
    self.gainRight = gainRight
    tapCount = tapGains.count
    let gains = UnsafeMutablePointer<Float>.allocate(capacity: max(tapGains.count, 1))
    gains.initialize(repeating: 1, count: max(tapGains.count, 1))
    tapGains.withUnsafeBufferPointer { if let base = $0.baseAddress { gains.update(from: base, count: tapGains.count) } }
    self.tapGains = gains
    self.crossfeed = crossfeed
    self.width = width
    self.limiter = limiter
    self.analyzer = analyzer
    self.spatial = spatial
    self.plugins = ContiguousArray(plugins)
  }

  deinit {
    eqCoefficients.deallocate()
    tapGains.deallocate()
  }
}

/// Lock-free single-slot handoff (RCU style).
///
/// The main thread publishes a new snapshot by atomically swapping the slot. A replaced snapshot stays
/// alive on the main thread until either the audio thread acknowledges a newer generation, or a grace
/// period has passed (an I/O cycle that grabbed it before the swap finishes in milliseconds; the grace
/// period uses uptime, so it doesn't elapse while the Mac sleeps). Nothing is ever freed on, or while
/// in use by, the audio thread.
final class SnapshotMailbox {
  private let slot: UnsafeMutablePointer<UnsafeMutableRawPointer?>
  private let acknowledged: UnsafeMutablePointer<Int64>
  private var retired: [(snapshot: ParamSnapshot, at: UInt64)] = []
  private var generation: Int64 = 0
  private let gracePeriod: UInt64 = 1_000_000_000

  init() {
    slot = .allocate(capacity: 1)
    slot.initialize(to: nil)
    acknowledged = .allocate(capacity: 1)
    acknowledged.initialize(to: 0)
  }

  deinit {
    if let p = slot.pointee { Unmanaged<ParamSnapshot>.fromOpaque(p).release() }
    slot.deallocate()
    acknowledged.deallocate()
  }

  /// Publishing thread only (main).
  func publish(_ snapshot: ParamSnapshot) {
    generation += 1
    snapshot.generation = generation
    let fresh = Unmanaged.passRetained(snapshot).toOpaque()
    if let old = eqb_exchange_ptr(slot, fresh) {
      retired.append((Unmanaged<ParamSnapshot>.fromOpaque(old).takeRetainedValue(), DispatchTime.now().uptimeNanoseconds))
    }
    collect()
  }

  /// Frees snapshots the audio thread can no longer be using.
  func collect() {
    guard !retired.isEmpty else { return }
    let ack = eqb_load_i64(acknowledged)
    let now = DispatchTime.now().uptimeNanoseconds
    retired.removeAll { $0.snapshot.generation < ack || now - $0.at > gracePeriod }
  }

  var pendingCount: Int { retired.count }

  /// Audio thread. The returned reference must be used via `_withUnsafeGuaranteedRef`.
  @inline(__always)
  func acquire() -> Unmanaged<ParamSnapshot>? {
    guard let p = eqb_load_ptr(slot) else { return nil }
    let snapshot = Unmanaged<ParamSnapshot>.fromOpaque(p)
    eqb_store_i64(acknowledged, snapshot._withUnsafeGuaranteedRef { $0.generation })
    return snapshot
  }
}
