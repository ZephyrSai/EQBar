import AudioToolbox
import Foundation

/// Pointers the spatial mixer's input callback reads from. Lives at a fixed address.
private struct SpatialInput {
  var left: UnsafeMutablePointer<Float>?
  var right: UnsafeMutablePointer<Float>?
}

private func spatialInputCallback(_ refCon: UnsafeMutableRawPointer,
                                  _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                  _ timeStamp: UnsafePointer<AudioTimeStamp>,
                                  _ bus: UInt32,
                                  _ frames: UInt32,
                                  _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
  let input = refCon.assumingMemoryBound(to: SpatialInput.self).pointee
  guard let ioData, let source = bus == 0 ? input.left : input.right else { return noErr }
  let byteCount = Int(frames) * MemoryLayout<Float>.size
  for buffer in UnsafeMutableAudioBufferListPointer(ioData) {
    if let data = buffer.mData { memcpy(data, source, byteCount) }
  }
  return noErr
}

/// Spatial audio built on Apple's AUSpatialMixer: the stereo signal becomes two virtual speakers
/// placed in front of the listener, rendered for headphones (HRTF, personalised when available)
/// or speakers, inside an optional simulated room (small room → concert hall → cathedral).
///
/// Structural settings (room, output kind) are fixed per instance; the controller builds a new
/// processor when they change. Angle and room amount are live parameters.
public final class SpatialProcessor {
  private var unit: AudioUnit?
  private let input: UnsafeMutablePointer<SpatialInput>
  private let outLeft: UnsafeMutablePointer<Float>
  private let outRight: UnsafeMutablePointer<Float>
  private let outList: UnsafeMutableAudioBufferListPointer
  private let maxFrames: Int
  /// Which spatialization algorithm a configuration uses (kSpatializationAlgorithm_* values).
  static func algorithm(for output: SpatialOutputKind, personalized: Bool) -> UInt32 {
    switch output {
    case .headphones, .auto: return personalized ? 7 : 6   // UseOutputType : HRTFHQ
    case .builtInSpeakers, .externalSpeakers: return 0      // EqualPowerPanning
    }
  }

  private var algorithm: UInt32 = 6
  /// Level trims so toggling spatial audio doesn't change loudness (measured in SpatialTests).
  private var makeup: Float {
    switch algorithm {
    case 7: return 1.05     // personalized renderer measures 0.96
    case 0: return 0.816    // equal-power panning measures 1.22
    default: return 1.046   // HRTF-HQ measures 0.96
    }
  }

  public init?(sampleRate: Double, maxFrames: Int, settings: SpatialSettings, output: SpatialOutputKind) {
    self.maxFrames = maxFrames
    input = .allocate(capacity: 1)
    input.initialize(to: SpatialInput())
    outLeft = .allocate(capacity: maxFrames)
    outLeft.initialize(repeating: 0, count: maxFrames)
    outRight = .allocate(capacity: maxFrames)
    outRight.initialize(repeating: 0, count: maxFrames)
    outList = AudioBufferList.allocate(maximumBuffers: 2)

    var description = AudioComponentDescription(componentType: kAudioUnitType_Mixer,
                                                componentSubType: kAudioUnitSubType_SpatialMixer,
                                                componentManufacturer: kAudioUnitManufacturer_Apple,
                                                componentFlags: 0, componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &description) else { return nil }
    var instance: AudioUnit?
    guard AudioComponentInstanceNew(component, &instance) == noErr, let au = instance else { return nil }
    unit = au

    guard configure(au, sampleRate: sampleRate, settings: settings, output: output),
          AudioUnitInitialize(au) == noErr else {
      AudioComponentInstanceDispose(au)
      unit = nil
      return nil
    }
    update(settings)
  }

  deinit {
    if let unit {
      AudioUnitUninitialize(unit)
      AudioComponentInstanceDispose(unit)
    }
    input.deallocate()
    outLeft.deallocate()
    outRight.deallocate()
    free(outList.unsafeMutablePointer)
  }

  private func configure(_ au: AudioUnit, sampleRate: Double, settings: SpatialSettings, output: SpatialOutputKind) -> Bool {
    func setProperty<T>(_ id: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: UInt32, _ value: T) -> Bool {
      var v = value
      return withUnsafePointer(to: &v) {
        AudioUnitSetProperty(au, id, scope, element, $0, UInt32(MemoryLayout<T>.size)) == noErr
      }
    }

    var ok = true
    ok = ok && setProperty(kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, UInt32(2))
    ok = ok && setProperty(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, UInt32(maxFrames))

    let mono = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                                           mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                           mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var stereo = mono
    stereo.mChannelsPerFrame = 2
    ok = ok && setProperty(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, stereo)

    // Renderer choice is driven by memory (measured at 48 / 96 kHz, rooms included):
    //   headphones → HRTF-HQ with the classic room reverb            ~12–25 / 26–50 MB
    //   speakers   → equal-power panning with the classic room reverb   ~5 MB
    //   personalized profile → Apple's newer renderer, whose convolution
    //                rooms cost ~50 / ~100 MB; opt-in only.
    let algorithm = Self.algorithm(for: output, personalized: settings.personalizedHRTF)
    self.algorithm = algorithm
    if algorithm == 7 {   // kSpatializationAlgorithm_UseOutputType
      _ = setProperty(kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global, 0, UInt32(1))  // headphones
      _ = setProperty(kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode, kAudioUnitScope_Global, 0, UInt32(2))  // auto
    }

    let usesRoom = settings.room != .none
    _ = setProperty(kAudioUnitProperty_UsesInternalReverb, kAudioUnitScope_Global, 0, UInt32(usesRoom ? 1 : 0))
    if usesRoom {
      _ = setProperty(kAudioUnitProperty_ReverbRoomType, kAudioUnitScope_Global, 0, UInt32(settings.room.rawValue))
    }

    var callback = AURenderCallbackStruct(inputProc: spatialInputCallback, inputProcRefCon: UnsafeMutableRawPointer(input))
    for bus: UInt32 in 0..<2 {
      ok = ok && setProperty(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, bus, mono)
      ok = ok && setProperty(kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input, bus, algorithm)
      ok = ok && setProperty(kAudioUnitProperty_SpatialMixerSourceMode, kAudioUnitScope_Input, bus,
                             UInt32(2))     // kSpatialMixerSourceMode_PointSource
      _ = setProperty(kAudioUnitProperty_SpatialMixerRenderingFlags, kAudioUnitScope_Input, bus,
                      UInt32(1))             // kSpatialMixerRenderingFlags_InterAuralDelay
      ok = ok && AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, bus,
                                      &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
      AudioUnitSetParameter(au, kSpatialMixerParam_Distance, kAudioUnitScope_Input, bus, 1.0, 0)
      AudioUnitSetParameter(au, kSpatialMixerParam_Elevation, kAudioUnitScope_Input, bus, 0, 0)
    }
    return ok
  }

  /// Live parameters. Safe to call while rendering.
  public func update(_ settings: SpatialSettings) {
    guard let unit else { return }
    let angle = Float(max(5, min(90, settings.speakerAngle)))
    AudioUnitSetParameter(unit, kSpatialMixerParam_Azimuth, kAudioUnitScope_Input, 0, -angle, 0)
    AudioUnitSetParameter(unit, kSpatialMixerParam_Azimuth, kAudioUnitScope_Input, 1, angle, 0)
    let blend = settings.room == .none ? 0 : Float(max(0, min(100, settings.roomAmount)))
    for bus: UInt32 in 0..<2 {
      AudioUnitSetParameter(unit, kSpatialMixerParam_ReverbBlend, kAudioUnitScope_Input, bus, blend, 0)
    }
  }

  /// Audio thread. Replaces left/right in place.
  func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames n: Int, sampleTime: Double) {
    guard let unit, n <= maxFrames else { return }
    input.pointee.left = left
    input.pointee.right = right
    let bytes = UInt32(n * MemoryLayout<Float>.size)
    outList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outLeft))
    outList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outRight))
    var flags = AudioUnitRenderActionFlags()
    var timeStamp = AudioTimeStamp()
    timeStamp.mSampleTime = sampleTime
    timeStamp.mFlags = .sampleTimeValid
    guard AudioUnitRender(unit, &flags, &timeStamp, 0, UInt32(n), outList.unsafeMutablePointer) == noErr else { return }
    let l = outList[0].mData?.assumingMemoryBound(to: Float.self) ?? outLeft
    let r = outList[1].mData?.assumingMemoryBound(to: Float.self) ?? outRight
    for i in 0..<n {
      left[i] = l[i] * makeup
      right[i] = r[i] * makeup
    }
  }
}
