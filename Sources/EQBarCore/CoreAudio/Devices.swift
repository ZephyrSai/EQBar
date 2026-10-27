import AudioToolbox
import CoreAudio
import Foundation

public struct OutputDevice: Equatable, Hashable {
  public let id: AudioDeviceID
  public let uid: String
  public let name: String
  public let transportType: UInt32
}

/// What kind of listener the spatial renderer should target.
public enum SpatialOutputKind: String, Codable, CaseIterable {
  case auto, headphones, builtInSpeakers, externalSpeakers

  public var title: String {
    switch self {
    case .auto: return "Auto"
    case .headphones: return "Headphones"
    case .builtInSpeakers: return "Built-in Speakers"
    case .externalSpeakers: return "External Speakers"
    }
  }
}

/// One hardware format an output stream supports, as Audio MIDI Setup lists them.
public struct DeviceFormat: Equatable {
  public let streamID: AudioStreamID
  public let sampleRate: Double
  public let channels: Int
  public let bits: Int
  public let isFloat: Bool
  let description: AudioStreamBasicDescription

  init(streamID: AudioStreamID, description: AudioStreamBasicDescription) {
    self.streamID = streamID
    self.description = description
    sampleRate = description.mSampleRate
    channels = Int(description.mChannelsPerFrame)
    bits = Int(description.mBitsPerChannel)
    isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
  }

  /// "2 ch 24-bit Integer"
  public var title: String { "\(channels) ch \(bits)-bit \(isFloat ? "Float" : "Integer")" }
  /// "96.0 kHz"
  public var rateTitle: String { String(format: "%.1f kHz", sampleRate / 1000) }
  /// "2 ch 24-bit Integer 96.0 kHz"
  public var fullTitle: String { "\(title) \(rateTitle)" }

  public static func == (a: DeviceFormat, b: DeviceFormat) -> Bool {
    a.streamID == b.streamID && a.sampleRate == b.sampleRate && a.channels == b.channels
      && a.bits == b.bits && a.isFloat == b.isFloat
  }
}

public enum Devices {
  private static let standardRates: [Double] = [8000, 11025, 16000, 22050, 32000, 44100, 48000,
                                                88200, 96000, 176400, 192000, 352800, 384000]

  /// Formats of the device's first output stream, sorted by rate, plus the one in use.
  public static func outputFormats(_ id: AudioDeviceID) -> (current: DeviceFormat?, available: [DeviceFormat]) {
    let streams = AudioObject.getArray(id, .init(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput),
                                       of: AudioStreamID.self)
    guard let stream = streams.first else { return (nil, []) }
    let current = (try? AudioObject.get(stream, .init(kAudioStreamPropertyPhysicalFormat),
                                        initial: AudioStreamBasicDescription()))
      .map { DeviceFormat(streamID: stream, description: $0) }

    var formats: [DeviceFormat] = []
    let ranged = AudioObject.getArray(stream, .init(kAudioStreamPropertyAvailablePhysicalFormats),
                                      of: AudioStreamRangedDescription.self)
    for entry in ranged {
      let low = entry.mSampleRateRange.mMinimum, high = entry.mSampleRateRange.mMaximum
      // Some devices report a continuous range; offer the standard rates inside it.
      let rates = low == high ? [low] : standardRates.filter { $0 >= low && $0 <= high }
      for rate in rates where rate > 0 {
        var description = entry.mFormat
        description.mSampleRate = rate
        let format = DeviceFormat(streamID: stream, description: description)
        if !formats.contains(format) { formats.append(format) }
      }
    }
    formats.sort { ($0.sampleRate, $0.channels, $0.bits, $0.isFloat ? 1 : 0) < ($1.sampleRate, $1.channels, $1.bits, $1.isFloat ? 1 : 0) }
    return (current, formats)
  }

  /// Changes the hardware format system-wide, like Audio MIDI Setup does.
  public static func setOutputFormat(_ format: DeviceFormat, device: AudioDeviceID) throws {
    if nominalSampleRate(device) != format.sampleRate {
      try AudioObject.set(device, .init(kAudioDevicePropertyNominalSampleRate), Float64(format.sampleRate))
    }
    try AudioObject.set(format.streamID, .init(kAudioStreamPropertyPhysicalFormat), format.description)
  }

  public static func defaultOutput() -> AudioDeviceID? {
    let id = try? AudioObject.get(AudioObject.system,
                                  .init(kAudioHardwarePropertyDefaultOutputDevice),
                                  initial: AudioDeviceID(kAudioObjectUnknown))
    guard let id, id != kAudioObjectUnknown else { return nil }
    return id
  }

  public static func setDefaultOutput(_ id: AudioDeviceID) {
    try? AudioObject.set(AudioObject.system, .init(kAudioHardwarePropertyDefaultOutputDevice), id)
    try? AudioObject.set(AudioObject.system, .init(kAudioHardwarePropertyDefaultSystemOutputDevice), id)
  }

  public static func uid(_ id: AudioDeviceID) -> String? {
    AudioObject.getString(id, .init(kAudioDevicePropertyDeviceUID))
  }

  public static func name(_ id: AudioDeviceID) -> String? {
    AudioObject.getString(id, .init(kAudioObjectPropertyName))
  }

  public static func transportType(_ id: AudioDeviceID) -> UInt32 {
    (try? AudioObject.get(id, .init(kAudioDevicePropertyTransportType), initial: UInt32(0))) ?? 0
  }

  public static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
    (try? AudioObject.get(id, .init(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
  }

  public static func outputChannelCount(_ id: AudioDeviceID) -> Int {
    AudioObject.bufferChannels(id, scope: kAudioObjectPropertyScopeOutput).reduce(0, +)
  }

  public static func inputStreamCount(_ id: AudioDeviceID) -> Int {
    AudioObject.getArray(id, .init(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput),
                         of: AudioStreamID.self).count
  }

  /// 1-based channel numbers macOS uses for stereo playback on this device.
  public static func preferredStereoChannels(_ id: AudioDeviceID) -> (Int, Int) {
    let pair = AudioObject.getArray(id, .init(kAudioDevicePropertyPreferredChannelsForStereo,
                                              kAudioObjectPropertyScopeOutput), of: UInt32.self)
    if pair.count == 2, pair[0] > 0, pair[1] > 0 { return (Int(pair[0]), Int(pair[1])) }
    return (1, 2)
  }

  /// The device volume macOS shows in the menu bar and Control Center (0–1).
  public static let mainVolumeAddress = AudioObjectPropertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                                   kAudioObjectPropertyScopeOutput)
  public static let muteAddress = AudioObjectPropertyAddress(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)

  /// True when macOS can change this device's volume itself (HDMI and DisplayPort often can't).
  public static func hasHardwareVolume(_ id: AudioDeviceID) -> Bool {
    AudioObject.has(id, mainVolumeAddress) && AudioObject.isSettable(id, mainVolumeAddress)
  }

  /// The device's system volume (0–1), or nil if it has none.
  public static func hardwareVolume(_ id: AudioDeviceID) -> Float? {
    guard hasHardwareVolume(id) else { return nil }
    return try? AudioObject.get(id, mainVolumeAddress, initial: Float32(0))
  }

  public static func setHardwareVolume(_ id: AudioDeviceID, _ volume: Float) {
    try? AudioObject.set(id, mainVolumeAddress, Float32(max(0, min(1, volume))))
  }

  public static func hasHardwareMute(_ id: AudioDeviceID) -> Bool {
    AudioObject.has(id, muteAddress) && AudioObject.isSettable(id, muteAddress)
  }

  public static func isHardwareMuted(_ id: AudioDeviceID) -> Bool {
    guard AudioObject.has(id, muteAddress) else { return false }
    return ((try? AudioObject.get(id, muteAddress, initial: UInt32(0))) ?? 0) != 0
  }

  public static func setHardwareMute(_ id: AudioDeviceID, _ muted: Bool) {
    try? AudioObject.set(id, muteAddress, UInt32(muted ? 1 : 0))
  }

  public static func outputDevices() -> [OutputDevice] {
    let ids = AudioObject.getArray(AudioObject.system, .init(kAudioHardwarePropertyDevices), of: AudioDeviceID.self)
    return ids.compactMap { id in
      guard outputChannelCount(id) > 0,
            let uid = uid(id),
            let name = name(id),
            !name.contains("CADefaultDeviceAggregate") else { return nil }
      let canBeDefault = (try? AudioObject.get(id, .init(kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                                         kAudioObjectPropertyScopeOutput), initial: UInt32(1))) ?? 1
      guard canBeDefault != 0 else { return nil }
      return OutputDevice(id: id, uid: uid, name: name, transportType: transportType(id))
    }
  }

  /// Best guess at whether the listener is on headphones or speakers.
  public static func spatialKind(for id: AudioDeviceID) -> SpatialOutputKind {
    // 1. What the device itself says its output is (USB audio class devices report this).
    let streams = AudioObject.getArray(id, .init(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput),
                                       of: AudioStreamID.self)
    if let stream = streams.first {
      let terminal = (try? AudioObject.get(stream, .init(kAudioStreamPropertyTerminalType), initial: UInt32(0))) ?? 0
      if terminal == kAudioStreamTerminalTypeHeadphones { return .headphones }
    }
    // 2. Built-in output: the jack's data source tells headphones from the speakers.
    let transport = transportType(id)
    if transport == kAudioDeviceTransportTypeBuiltIn {
      let source = (try? AudioObject.get(id, .init(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput),
                                         initial: UInt32(0))) ?? 0
      return source == 0x6864706E /* 'hdpn' */ ? .headphones : .builtInSpeakers
    }
    if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
      return .headphones
    }
    // 3. Names of USB and other headsets.
    let lowered = (name(id) ?? "").lowercased()
    let headphoneWords = ["headphone", "earbud", "earphone", "airpods", "buds", "headset", "iem", "beats"]
    return headphoneWords.contains(where: lowered.contains) ? .headphones : .externalSpeakers
  }
}
