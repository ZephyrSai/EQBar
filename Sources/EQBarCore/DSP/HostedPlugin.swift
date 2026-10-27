import AVFAudio
import AudioToolbox
import Foundation

public enum PluginError: Error, CustomStringConvertible {
  case instantiation(String)
  case format(String)

  public var description: String {
    switch self {
    case .instantiation(let m): return "Couldn't load plugin: \(m)"
    case .format(let m): return "Plugin doesn't support stereo float audio: \(m)"
    }
  }
}

/// Lists Audio Unit effects installed on this Mac (AUv2 components and AUv3 extensions).
public enum PluginCatalog {
  public static func effects() -> [PluginDescriptor] {
    let manager = AVAudioUnitComponentManager.shared()
    var result: [PluginDescriptor] = []
    for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
      let match = AudioComponentDescription(componentType: type, componentSubType: 0,
                                            componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
      for c in manager.components(matching: match) {
        let d = c.audioComponentDescription
        result.append(PluginDescriptor(type: d.componentType, subtype: d.componentSubType,
                                       manufacturer: d.componentManufacturer,
                                       name: c.name, manufacturerName: c.manufacturerName))
      }
    }
    return result.sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
  }
}

/// A third-party Audio Unit inserted into the processing chain.
public final class HostedPlugin {
  public let descriptor: PluginDescriptor
  public let audioUnit: AUAudioUnit
  public private(set) var sampleRate = 0.0

  private var renderBlock: AURenderBlock?
  private var pullInput: AURenderPullInputBlock?
  private let maxFrames: Int
  private let inLeft, inRight, outLeft, outRight: UnsafeMutablePointer<Float>
  private let outList: UnsafeMutableAudioBufferListPointer

  private init(descriptor: PluginDescriptor, audioUnit: AUAudioUnit, maxFrames: Int) {
    self.descriptor = descriptor
    self.audioUnit = audioUnit
    self.maxFrames = maxFrames
    inLeft = .allocate(capacity: maxFrames)
    inRight = .allocate(capacity: maxFrames)
    outLeft = .allocate(capacity: maxFrames)
    outRight = .allocate(capacity: maxFrames)
    for p in [inLeft, inRight, outLeft, outRight] { p.initialize(repeating: 0, count: maxFrames) }
    outList = AudioBufferList.allocate(maximumBuffers: 2)
  }

  deinit {
    if audioUnit.renderResourcesAllocated { audioUnit.deallocateRenderResources() }
    for p in [inLeft, inRight, outLeft, outRight] { p.deallocate() }
    free(outList.unsafeMutablePointer)
  }

  public static func instantiate(_ descriptor: PluginDescriptor, maxFrames: Int = 4096,
                                 completion: @escaping (Result<HostedPlugin, Error>) -> Void) {
    let description = AudioComponentDescription(componentType: descriptor.type, componentSubType: descriptor.subtype,
                                                componentManufacturer: descriptor.manufacturer,
                                                componentFlags: 0, componentFlagsMask: 0)
    AUAudioUnit.instantiate(with: description, options: []) { unit, error in
      DispatchQueue.main.async {
        if let unit {
          completion(.success(HostedPlugin(descriptor: descriptor, audioUnit: unit, maxFrames: maxFrames)))
        } else {
          completion(.failure(PluginError.instantiation(error?.localizedDescription ?? descriptor.name)))
        }
      }
    }
  }

  /// Synchronous creation for in-process (AUv2) units; used by tests.
  static func makeSynchronously(_ descriptor: PluginDescriptor, maxFrames: Int = 4096) throws -> HostedPlugin {
    let description = AudioComponentDescription(componentType: descriptor.type, componentSubType: descriptor.subtype,
                                                componentManufacturer: descriptor.manufacturer,
                                                componentFlags: 0, componentFlagsMask: 0)
    let unit = try AUAudioUnit(componentDescription: description, options: [])
    return HostedPlugin(descriptor: descriptor, audioUnit: unit, maxFrames: maxFrames)
  }

  /// Configures stereo float I/O at the engine's rate. Must not be called while the plugin is rendering.
  public func prepare(sampleRate: Double) throws {
    guard sampleRate != self.sampleRate || !audioUnit.renderResourcesAllocated else { return }
    if audioUnit.renderResourcesAllocated { audioUnit.deallocateRenderResources() }
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
      throw PluginError.format("\(sampleRate) Hz")
    }
    do {
      // Busses start disabled on bridged AUv2 units; without enabling them rendering fails with NoConnection.
      if audioUnit.inputBusses.count > 0 {
        try audioUnit.inputBusses[0].setFormat(format)
        audioUnit.inputBusses[0].isEnabled = true
      }
      if audioUnit.outputBusses.count > 0 {
        try audioUnit.outputBusses[0].setFormat(format)
        audioUnit.outputBusses[0].isEnabled = true
      }
      audioUnit.maximumFramesToRender = AUAudioFrameCount(maxFrames)
      try audioUnit.allocateRenderResources()
    } catch {
      throw PluginError.format(error.localizedDescription)
    }
    self.sampleRate = sampleRate
    renderBlock = audioUnit.renderBlock

    // Captures raw pointers only, so calling it from the audio thread never touches ARC on self.
    let l = inLeft, r = inRight
    pullInput = { _, _, frameCount, _, inputData in
      let byteCount = Int(frameCount) * MemoryLayout<Float>.size
      let list = UnsafeMutableAudioBufferListPointer(inputData)
      for index in 0..<list.count {
        let source = index == 0 ? l : r
        if let data = list[index].mData {
          memcpy(data, source, byteCount)
        } else {
          list[index].mData = UnsafeMutableRawPointer(source)
        }
        list[index].mDataByteSize = UInt32(byteCount)
      }
      return noErr
    }
  }

  /// Audio thread. On failure the audio passes through unchanged.
  @discardableResult
  func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames n: Int, sampleTime: Double) -> OSStatus {
    guard let renderBlock, let pullInput, n <= maxFrames else { return kAudioUnitErr_Uninitialized }
    let bytes = n * MemoryLayout<Float>.size
    memcpy(inLeft, left, bytes)
    memcpy(inRight, right, bytes)
    outList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: UnsafeMutableRawPointer(outLeft))
    outList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: UnsafeMutableRawPointer(outRight))
    var flags = AudioUnitRenderActionFlags()
    var timeStamp = AudioTimeStamp()
    timeStamp.mSampleTime = sampleTime
    timeStamp.mFlags = .sampleTimeValid
    let status = renderBlock(&flags, &timeStamp, AUAudioFrameCount(n), 0, outList.unsafeMutablePointer, pullInput)
    guard status == noErr else { return status }
    if let data = outList[0].mData { memcpy(left, data, bytes) }
    if let data = outList[1].mData { memcpy(right, data, bytes) }
    return noErr
  }

  // MARK: State

  public func stateData() -> Data? {
    guard let state = audioUnit.fullState else { return nil }
    return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
  }

  public func restore(_ data: Data?) {
    guard let data,
          let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
    audioUnit.fullState = state
  }
}
