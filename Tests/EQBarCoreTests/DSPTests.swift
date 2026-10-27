import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import EQBarCore

private let rate = 48_000.0

private func sine(_ frequency: Double, frames: Int, amplitude: Float = 0.5) -> [Float] {
  (0..<frames).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
}

private func rms(_ x: ArraySlice<Float>) -> Float {
  sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1)))
}

@Suite struct BiquadTests {
  @Test func peakHitsItsGainAtTheCentreFrequency() {
    let band = EQBand(type: .peak, frequency: 1000, gain: 6, q: 1.41)
    let db = band.biquad(sampleRate: rate).magnitudeDB(at: 1000, sampleRate: rate)
    #expect(abs(db - 6) < 0.01)
  }

  @Test func shelvesReachTheirGainFarFromTheCorner() {
    let low = EQBand(type: .lowShelf, frequency: 200, gain: -8, q: 0.7).biquad(sampleRate: rate)
    #expect(abs(low.magnitudeDB(at: 20, sampleRate: rate) + 8) < 0.2)
    #expect(abs(low.magnitudeDB(at: 10_000, sampleRate: rate)) < 0.1)
    let high = EQBand(type: .highShelf, frequency: 4000, gain: 5, q: 0.7).biquad(sampleRate: rate)
    #expect(abs(high.magnitudeDB(at: 18_000, sampleRate: rate) - 5) < 0.3)
  }

  @Test func butterworthLowPassIsMinus3dBAtCutoff() {
    let lp = EQBand(type: .lowPass, frequency: 2000, q: 1 / sqrt(2)).biquad(sampleRate: rate)
    #expect(abs(lp.magnitudeDB(at: 2000, sampleRate: rate) + 3.01) < 0.05)
  }

  @Test func autoPreampMatchesThePeakOfTheCascade() {
    let bands = [EQBand(type: .peak, frequency: 100, gain: 4, q: 1), EQBand(type: .peak, frequency: 120, gain: 4, q: 1)]
    let peak = EQMath.peakGain(bands, sampleRate: rate)
    #expect(peak > 7 && peak < 8.5)
  }
}

@Suite struct ProcessorTests {
  @Test func eqProcessorAppliesGain() {
    let n = 4800
    var left = sine(1000, frames: n), right = sine(1000, frames: n)
    let band = EQBand(type: .peak, frequency: 1000, gain: 6.0206, q: 2).biquad(sampleRate: rate)
    let coefficients = [band.b0, band.b1, band.b2, band.a1, band.a2]
    let eq = EQProcessor()
    coefficients.withUnsafeBufferPointer { c in
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          eq.process(left: l.baseAddress!, right: r.baseAddress!, frames: n, target: c.baseAddress!, count: 1)
        }
      }
    }
    let gain = rms(left[2400...]) / rms(sine(1000, frames: n)[2400...])
    #expect(abs(gain - 2) < 0.02)
  }

  @Test func crossfeedKeepsMonoLevelAndNarrowsHardPans() throws {
    let c = try #require(CrossfeedCoefficients.make(.medium, sampleRate: rate))
    var state = CrossfeedState()
    var left = sine(200, frames: 9600), right = left
    left.withUnsafeMutableBufferPointer { l in
      right.withUnsafeMutableBufferPointer { r in state.process(left: l.baseAddress!, right: r.baseAddress!, frames: 9600, c) }
    }
    #expect(abs(rms(left[4800...]) / rms(sine(200, frames: 9600)[4800...]) - 1) < 0.05)

    state.reset()
    var hardLeft = sine(200, frames: 9600), silentRight = [Float](repeating: 0, count: 9600)
    hardLeft.withUnsafeMutableBufferPointer { l in
      silentRight.withUnsafeMutableBufferPointer { r in state.process(left: l.baseAddress!, right: r.baseAddress!, frames: 9600, c) }
    }
    #expect(rms(silentRight[4800...]) > 0.05)   // bass leaks into the other ear
  }
}

@Suite struct MailboxTests {
  @Test func retiredSnapshotsAreFreedOnlyAfterTheAudioThreadMovesOn() {
    let mailbox = SnapshotMailbox()
    weak var first: ParamSnapshot?
    do {
      let snapshot = ParamSnapshot()
      first = snapshot
      mailbox.publish(snapshot)
    }
    _ = mailbox.acquire()                 // audio thread is using generation 1
    mailbox.publish(ParamSnapshot())      // generation 2 replaces it
    #expect(first != nil)                 // still alive: not yet acknowledged
    _ = mailbox.acquire()                 // audio thread picks up generation 2
    mailbox.collect()
    #expect(first == nil)
    #expect(mailbox.pendingCount == 0)
  }
}

/// Drives RenderContext exactly like the I/O callback would, with synthetic Core Audio buffers.
@Suite struct RenderPathTests {
  private func render(_ context: RenderContext, input: [Float], frames: Int) -> [Float] {
    let inList = AudioBufferList.allocate(maximumBuffers: 1)
    let outList = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(inList.unsafeMutablePointer); free(outList.unsafeMutablePointer) }
    var inData = input
    var outData = [Float](repeating: 0, count: frames * 2)
    return inData.withUnsafeMutableBytes { inBytes in
      outData.withUnsafeMutableBytes { outBytes in
        inList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress)
        outList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress)
        context.render(input: inList.unsafePointer, output: outList.unsafeMutablePointer)
        return Array(outBytes.bindMemory(to: Float.self))
      }
    }
  }

  private func interleaved(_ mono: [Float]) -> [Float] { mono.flatMap { [$0, $0] } }

  private func makeContext() -> RenderContext {
    RenderContext(sampleRate: rate, maxFrames: 512,
                  taps: [ChannelPair(leftBuffer: 0, leftChannel: 0, rightBuffer: 0, rightChannel: 1)],
                  output: ChannelPair(leftBuffer: 0, leftChannel: 0, rightBuffer: 0, rightChannel: 1))
  }

  @Test func passesAudioThroughBeforeAnyConfiguration() {
    let context = makeContext()
    let n = 2048   // larger than maxFrames: exercises chunking
    let input = sine(440, frames: n)
    var out: [Float] = []
    for _ in 0..<3 { out = render(context, input: interleaved(input), frames: n) }   // let the fade-in settle
    let left = stride(from: 0, to: out.count, by: 2).map { out[$0] }
    #expect(abs(rms(left[1000...]) - rms(input[1000...])) < 0.01)
  }

  @Test func appliesVolumeBalanceAndLimiter() {
    let context = makeContext()
    context.mailbox.publish(ParamSnapshot(gainLeft: 4, gainRight: 0.5, tapGains: [1], limiter: true))
    let n = 2048
    let input = interleaved(sine(440, frames: n, amplitude: 0.8))
    var out: [Float] = []
    for _ in 0..<4 { out = render(context, input: input, frames: n) }
    let left = stride(from: 0, to: out.count, by: 2).map { out[$0] }
    let right = stride(from: 1, to: out.count, by: 2).map { out[$0] }
    #expect((left.map(abs).max() ?? 0) <= 0.98)          // ×4 of 0.8 would be 3.2; limiter holds it
    // The limiter is stereo-linked, so the balance ratio (0.5 / 4) survives limiting.
    #expect(abs(rms(right[1000...]) / rms(left[1000...]) - 0.125) < 0.01)
  }

  @Test func mutedTapProducesSilence() {
    let context = makeContext()
    context.mailbox.publish(ParamSnapshot(tapGains: [0]))
    let out = render(context, input: interleaved(sine(440, frames: 512)), frames: 512)
    #expect(out.allSatisfy { $0 == 0 })
  }
}

@Suite struct SpatialTests {
  /// Renders a 500 Hz tone through each renderer and reports output/input level.
  private func levelRatio(output: SpatialOutputKind, personalized: Bool, room: RoomType) throws -> Float {
    var settings = SpatialSettings()
    settings.enabled = true
    settings.room = room
    settings.personalizedHRTF = personalized
    let processor = try #require(SpatialProcessor(sampleRate: rate, maxFrames: 512, settings: settings, output: output))
    let n = 512
    var energyIn: Float = 0, energyOut: Float = 0
    var time = 0.0
    for block in 0..<40 {
      var left = (0..<n).map { 0.3 * Float(sin(2 * Double.pi * 500 * Double(block * n + $0) / rate)) }
      var right = left
      let before = rms(left[...])
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          processor.render(left: l.baseAddress!, right: r.baseAddress!, frames: n, sampleTime: time)
        }
      }
      time += Double(n)
      if block >= 20 {
        energyIn += before
        energyOut += (rms(left[...]) + rms(right[...])) / 2
      }
    }
    return energyOut / energyIn
  }

  @Test func headphoneRendererKeepsLevel() throws {
    let ratio = try levelRatio(output: .headphones, personalized: false, room: .none)
    print("spatial level, HRTF-HQ headphones:", ratio)
    #expect(ratio > 0.7 && ratio < 1.4)
  }

  @Test func personalizedRendererKeepsLevel() throws {
    let ratio = try levelRatio(output: .headphones, personalized: true, room: .none)
    print("spatial level, personalized renderer:", ratio)
    #expect(ratio > 0.7 && ratio < 1.4)
  }

  @Test func speakerRendererKeepsLevel() throws {
    let ratio = try levelRatio(output: .builtInSpeakers, personalized: false, room: .none)
    print("spatial level, speakers:", ratio)
    #expect(ratio > 0.7 && ratio < 1.4)
  }

  @Test func rendererChoiceFavoursLightAlgorithms() {
    #expect(SpatialProcessor.algorithm(for: .headphones, personalized: false) == 6)
    #expect(SpatialProcessor.algorithm(for: .headphones, personalized: true) == 7)
    #expect(SpatialProcessor.algorithm(for: .builtInSpeakers, personalized: true) == 0)
  }
}

@Suite struct PluginHostTests {
  @Test func hostsAnAppleAudioUnitThroughTheRenderPath() throws {
    let catalog = PluginCatalog.effects()
    let lowPass = try #require(catalog.first { $0.subtype == kAudioUnitSubType_LowPassFilter && $0.manufacturer == kAudioUnitManufacturer_Apple })
    let plugin = try HostedPlugin.makeSynchronously(lowPass, maxFrames: 512)
    try plugin.prepare(sampleRate: rate)
    #expect(plugin.sampleRate == rate)

    let n = 512
    var inEnergy: Float = 0, outEnergy: Float = 0
    for block in 0..<20 {
      var left = (0..<n).map { 0.5 * Float(sin(2 * Double.pi * 15_000 * Double(block * n + $0) / rate)) }
      var right = left
      let before = rms(left[...])
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          #expect(plugin.render(left: l.baseAddress!, right: r.baseAddress!, frames: n, sampleTime: Double(block * n)) == noErr)
        }
      }
      if block >= 10 { inEnergy += before; outEnergy += rms(left[...]) }
    }
    // Apple's low-pass defaults to a 6.9 kHz cutoff, so a 15 kHz tone must come out much quieter.
    #expect(outEnergy < inEnergy * 0.5)
    #expect(outEnergy > 0)
  }
}
