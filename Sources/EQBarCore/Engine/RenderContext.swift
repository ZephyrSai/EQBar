import Accelerate
import CoreAudio
import Foundation

/// Where a tap's left and right samples live in the aggregate device's input buffer list.
struct ChannelPair {
  var leftBuffer: Int
  var leftChannel: Int
  var rightBuffer: Int
  var rightChannel: Int

  var isMono: Bool { leftBuffer == rightBuffer && leftChannel == rightChannel }
}

/// Everything that runs on the real-time I/O thread. No allocation, no locks, no Objective-C messaging
/// in the steady state (hosted plugins and the spatial mixer may do their own internal work).
public final class RenderContext {
  public let sampleRate: Double
  let maxFrames: Int
  let taps: [ChannelPair]
  let output: ChannelPair
  let mailbox = SnapshotMailbox()
  public let analyzerRing = SampleRing()

  private let left: UnsafeMutablePointer<Float>
  private let right: UnsafeMutablePointer<Float>
  private let eq = EQProcessor()
  private var crossfeed = CrossfeedState()
  private var gainLeft: Float = 0      // starts silent and fades in
  private var gainRight: Float = 0
  private let smoothing: Float
  private var limiterGain: Float = 1
  private let limiterRelease: Float
  private let ceiling: Float = 0.977   // -0.2 dBFS
  private var sampleTime = 0.0
  private var silentFrames = 0
  private var idle = false

  /// Debug metering (EQBAR_DEBUG=1). Plain, racy reads from the main thread are fine for logging.
  public static var meteringEnabled = ProcessInfo.processInfo.environment["EQBAR_DEBUG"] != nil
  public private(set) var cycles = 0
  public private(set) var inputPeak: Float = 0
  public private(set) var outputPeak: Float = 0

  init(sampleRate: Double, maxFrames: Int, taps: [ChannelPair], output: ChannelPair) {
    self.sampleRate = sampleRate
    self.maxFrames = maxFrames
    self.taps = taps
    self.output = output
    left = .allocate(capacity: maxFrames)
    left.initialize(repeating: 0, count: maxFrames)
    right = .allocate(capacity: maxFrames)
    right.initialize(repeating: 0, count: maxFrames)
    smoothing = Float(1 - exp(-1 / (0.012 * sampleRate)))           // ~12 ms volume glide
    limiterRelease = Float(1 - exp(-1 / (0.150 * sampleRate)))      // ~150 ms recovery
    // Pass-through until the controller publishes the real configuration.
    mailbox.publish(ParamSnapshot(tapGains: Array(repeating: 1, count: taps.count)))
  }

  deinit {
    left.deallocate()
    right.deallocate()
  }

  /// I/O thread entry point.
  func render(input: UnsafePointer<AudioBufferList>, output outputList: UnsafeMutablePointer<AudioBufferList>) {
    let outs = UnsafeMutableAudioBufferListPointer(outputList)
    for buffer in outs { if let d = buffer.mData { memset(d, 0, Int(buffer.mDataByteSize)) } }
    guard output.leftBuffer < outs.count, output.rightBuffer < outs.count else { return }

    let outChannels = max(1, Int(outs[output.leftBuffer].mNumberChannels))
    let total = Int(outs[output.leftBuffer].mDataByteSize) / (outChannels * MemoryLayout<Float>.size)
    guard total > 0, let snapshot = mailbox.acquire() else { return }
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

    snapshot._withUnsafeGuaranteedRef { snap in
      var offset = 0
      while offset < total {
        let n = min(maxFrames, total - offset)
        process(snap, inputs: inputs, outputs: outs, offset: offset, frames: n)
        offset += n
      }
    }
  }

  @inline(__always)
  private func process(_ snap: ParamSnapshot, inputs: UnsafeMutableAudioBufferListPointer,
                       outputs: UnsafeMutableAudioBufferListPointer, offset: Int, frames n: Int) {
    let count = vDSP_Length(n)
    vDSP_vclr(left, 1, count)
    vDSP_vclr(right, 1, count)

    // 1. Mix the taps (global mix + any per-app taps), each with its own gain.
    for (index, tap) in taps.enumerated() {
      var gain = index < snap.tapCount ? snap.tapGains[index] : 1
      guard gain > 0 else { continue }
      mixChannel(inputs, buffer: tap.leftBuffer, channel: tap.leftChannel, gain: &gain, into: left, offset: offset, frames: n)
      mixChannel(inputs, buffer: tap.rightBuffer, channel: tap.rightChannel, gain: &gain, into: right, offset: offset, frames: n)
    }
    // Silence fast path. Apps often keep an output stream open while sending zeros (paused video,
    // idle web audio); once every effect tail has decayed there is nothing to compute.
    var peakL: Float = 0, peakR: Float = 0
    vDSP_maxmgv(left, 1, &peakL, count)
    vDSP_maxmgv(right, 1, &peakR, count)
    if Self.meteringEnabled {
      inputPeak = max(inputPeak * 0.9, max(peakL, peakR))
      cycles += 1
    }
    if peakL == 0 && peakR == 0 {
      silentFrames += n
      if silentFrames > snap.silenceFrames {
        if !idle {
          idle = true
          eq.reset()
          crossfeed.reset()
          limiterGain = 1
        }
        gainLeft = snap.gainLeft
        gainRight = snap.gainRight
        sampleTime += Double(n)
        return   // output buffers are already zeroed
      }
    } else {
      silentFrames = 0
      idle = false
    }

    // 2. Preamp.
    if snap.preamp != 1 {
      var p = snap.preamp
      vDSP_vsmul(left, 1, &p, left, 1, count)
      vDSP_vsmul(right, 1, &p, right, 1, count)
    }

    // 3. Third-party Audio Units.
    for plugin in snap.plugins {
      plugin.render(left: left, right: right, frames: n, sampleTime: sampleTime)
    }

    // 4. Equalizer.
    if snap.eqCount > 0 {
      eq.process(left: left, right: right, frames: n, target: snap.eqCoefficients, count: snap.eqCount)
    } else {
      eq.reset()
    }

    // 5. Spatial audio.
    if let spatial = snap.spatial {
      spatial.render(left: left, right: right, frames: n, sampleTime: sampleTime)
    }

    // 6. Crossfeed.
    if let c = snap.crossfeed {
      crossfeed.process(left: left, right: right, frames: n, c)
    } else {
      crossfeed.reset()
    }

    // 7. Stereo width (mid/side).
    if snap.width != 1 {
      let w = snap.width
      for i in 0..<n {
        let mid = 0.5 * (left[i] + right[i])
        let side = 0.5 * (left[i] - right[i]) * w
        left[i] = mid + side
        right[i] = mid - side
      }
    }

    // 8. Volume and balance, glided per sample.
    let targetL = snap.gainLeft, targetR = snap.gainRight
    if abs(gainLeft - targetL) < 1e-5 && abs(gainRight - targetR) < 1e-5 {
      gainLeft = targetL
      gainRight = targetR
      var gl = targetL, gr = targetR
      vDSP_vsmul(left, 1, &gl, left, 1, count)
      vDSP_vsmul(right, 1, &gr, right, 1, count)
    } else {
      var gl = gainLeft, gr = gainRight
      let k = smoothing
      for i in 0..<n {
        gl += (targetL - gl) * k
        gr += (targetR - gr) * k
        left[i] *= gl
        right[i] *= gr
      }
      gainLeft = gl
      gainRight = gr
    }

    // 9. Peak limiter: instant attack, smooth release. Also scrubs NaN/Inf from misbehaving plugins.
    if snap.limiter {
      var g = limiterGain
      let release = limiterRelease, ceiling = self.ceiling
      for i in 0..<n {
        let l = left[i], r = right[i]
        guard l.isFinite, r.isFinite else { left[i] = 0; right[i] = 0; continue }
        let peak = max(abs(l), abs(r))
        let needed: Float = peak > ceiling ? ceiling / peak : 1
        g = min(needed, g + (1 - g) * release)
        left[i] = l * g
        right[i] = r * g
      }
      limiterGain = g
    }

    // 10. Analyzer feed.
    if snap.analyzer {
      analyzerRing.write(left: left, right: right, frames: n)
    }

    if Self.meteringEnabled {
      var peak: Float = 0
      vDSP_maxmgv(left, 1, &peak, count)
      outputPeak = max(outputPeak * 0.9, peak)
    }

    // 11. Write to the device.
    writeOutput(outputs, offset: offset, frames: n)
    sampleTime += Double(n)
  }

  @inline(__always)
  private func mixChannel(_ inputs: UnsafeMutableAudioBufferListPointer, buffer: Int, channel: Int, gain: inout Float,
                          into destination: UnsafeMutablePointer<Float>, offset: Int, frames n: Int) {
    guard buffer < inputs.count, let data = inputs[buffer].mData else { return }
    let stride = max(1, Int(inputs[buffer].mNumberChannels))
    guard channel < stride else { return }
    let available = Int(inputs[buffer].mDataByteSize) / (stride * MemoryLayout<Float>.size) - offset
    let frames = min(n, available)
    guard frames > 0 else { return }
    let source = data.assumingMemoryBound(to: Float.self) + offset * stride + channel
    vDSP_vsma(source, vDSP_Stride(stride), &gain, destination, 1, destination, 1, vDSP_Length(frames))
  }

  @inline(__always)
  private func writeOutput(_ outputs: UnsafeMutableAudioBufferListPointer, offset: Int, frames n: Int) {
    let lb = outputs[output.leftBuffer], rb = outputs[output.rightBuffer]
    guard let ld = lb.mData, let rd = rb.mData else { return }
    let ls = max(1, Int(lb.mNumberChannels)), rs = max(1, Int(rb.mNumberChannels))
    let lp = ld.assumingMemoryBound(to: Float.self) + offset * ls + output.leftChannel
    if output.isMono {
      for i in 0..<n { lp[i * ls] = 0.5 * (left[i] + right[i]) }
      return
    }
    let rp = rd.assumingMemoryBound(to: Float.self) + offset * rs + output.rightChannel
    for i in 0..<n {
      lp[i * ls] = left[i]
      rp[i * rs] = right[i]
    }
  }
}
