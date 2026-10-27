import CoreAudio
import Foundation

/// An app whose audio gets its own tap so it can have its own volume.
public struct AppTap: Equatable {
  public let key: String
  public let processes: [AudioObjectID]

  public init(key: String, processes: [AudioObjectID]) {
    self.key = key
    self.processes = processes
  }
}

/// Captures system audio with Core Audio process taps and plays the processed result on the
/// output device — no virtual driver, no admin rights.
///
/// Layout: a private aggregate device whose clock is the real output device, containing
///   • one stereo tap of every process except EQBar itself and any per-app-tapped processes, and
///   • one stereo tap per app that has a custom volume.
/// Tapped processes are muted at the source while EQBar reads them, so only the processed mix is heard.
/// With tap auto-start the I/O thread only runs while something is actually playing.
public final class TapEngine {
  public let outputDeviceID: AudioDeviceID
  public let sampleRate: Double
  public let appTaps: [AppTap]
  public let context: RenderContext

  private var tapIDs: [AudioObjectID] = []
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?
  private var stopped = false

  public var maxFrames: Int { context.maxFrames }

  public init(outputDeviceID: AudioDeviceID, appTaps: [AppTap]) throws {
    self.outputDeviceID = outputDeviceID
    self.appTaps = appTaps

    guard let outputUID = Devices.uid(outputDeviceID) else {
      throw CoreAudioError(status: OSStatus(kAudioHardwareBadDeviceError), context: "Finding output device")
    }
    // Make sure EQBar's own audio is never captured (that would be a feedback loop).
    guard let ownProcess = AudioProcesses.ownObject() else {
      throw CoreAudioError(status: OSStatus(kAudioHardwareUnspecifiedError), context: "Finding EQBar's audio process")
    }

    var built: (taps: [AudioObjectID], aggregate: AudioObjectID) = ([], AudioObjectID(kAudioObjectUnknown))
    do {
      // 1. Taps.
      let excluded = [ownProcess] + appTaps.flatMap(\.processes)
      let global = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
      built.taps.append(try Self.createTap(global, name: "EQBar"))
      for app in appTaps {
        built.taps.append(try Self.createTap(CATapDescription(stereoMixdownOfProcesses: app.processes), name: "EQBar \(app.key)"))
      }
      let tapUIDs = try built.taps.map { tap -> String in
        guard let uid = AudioObject.getString(tap, .init(kAudioTapPropertyUID)) else {
          throw CoreAudioError(status: OSStatus(kAudioHardwareUnspecifiedError), context: "Reading tap UID")
        }
        return uid
      }

      // 2. Private aggregate clocked by the output device.
      let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: "EQBar",
        kAudioAggregateDeviceUIDKey: "eqbar.aggregate." + UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
        kAudioAggregateDeviceTapListKey: tapUIDs.map { [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: true] }
      ]
      var aggregate = AudioObjectID(kAudioObjectUnknown)
      try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate), "Creating aggregate device")
      built.aggregate = aggregate

      // 3. Work out where each tap's channels and the output's stereo pair sit in the I/O buffers.
      let rate = Devices.nominalSampleRate(aggregate)
      sampleRate = rate > 0 ? rate : Devices.nominalSampleRate(outputDeviceID)
      let tapLayouts = try Self.tapLayouts(aggregate: aggregate, taps: built.taps)
      let outputLayout = try Self.outputLayout(aggregate: aggregate, device: outputDeviceID)
      let frameSize = (try? AudioObject.get(aggregate, .init(kAudioDevicePropertyBufferFrameSize), initial: UInt32(512))) ?? 512
      context = RenderContext(sampleRate: sampleRate, maxFrames: max(4096, Int(frameSize)),
                              taps: tapLayouts, output: outputLayout)
    } catch {
      Self.destroy(aggregate: built.aggregate, taps: built.taps)
      throw error
    }

    tapIDs = built.taps
    aggregateID = built.aggregate

    // 4. I/O.
    let context = self.context
    var proc: AudioDeviceIOProcID?
    do {
      try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) { _, input, _, output, _ in
        context.render(input: input, output: output)
      }, "Creating I/O callback")
      procID = proc
      try check(AudioDeviceStart(aggregateID, procID), "Starting audio")
    } catch {
      stop()
      throw error
    }
  }

  deinit { stop() }

  /// Tears everything down; tapped apps immediately play directly again. Idempotent.
  public func stop() {
    guard !stopped else { return }
    stopped = true
    if let procID {
      AudioDeviceStop(aggregateID, procID)
      AudioDeviceDestroyIOProcID(aggregateID, procID)
      self.procID = nil
    }
    Self.destroy(aggregate: aggregateID, taps: tapIDs)
    aggregateID = AudioObjectID(kAudioObjectUnknown)
    tapIDs = []
  }

  // MARK: - Helpers

  private static func createTap(_ description: CATapDescription, name: String) throws -> AudioObjectID {
    description.name = name
    description.uuid = UUID()
    description.isPrivate = true
    description.muteBehavior = .mutedWhenTapped
    var tap = AudioObjectID(kAudioObjectUnknown)
    try check(AudioHardwareCreateProcessTap(description, &tap), "Creating process tap")
    return tap
  }

  private static func destroy(aggregate: AudioObjectID, taps: [AudioObjectID]) {
    if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
    for tap in taps { AudioHardwareDestroyProcessTap(tap) }
  }

  /// Taps follow the sub-device's own input streams, in tap-list order, at the end of the input buffer list.
  private static func tapLayouts(aggregate: AudioObjectID, taps: [AudioObjectID]) throws -> [ChannelPair] {
    let inputBuffers = AudioObject.bufferChannels(aggregate, scope: kAudioObjectPropertyScopeInput)
    var perTap: [(buffers: Int, channels: Int)] = []
    for tap in taps {
      let format = try AudioObject.get(tap, .init(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription())
      let channels = max(1, Int(format.mChannelsPerFrame))
      let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
      perTap.append((nonInterleaved ? channels : 1, channels))
    }
    let needed = perTap.reduce(0) { $0 + $1.buffers }
    guard inputBuffers.count >= needed else {
      throw CoreAudioError(status: OSStatus(kAudioHardwareUnspecifiedError),
                           context: "Matching tap streams (\(inputBuffers.count) buffers, \(needed) expected)")
    }
    var buffer = inputBuffers.count - needed
    return perTap.map { tap in
      defer { buffer += tap.buffers }
      if tap.buffers > 1 { return ChannelPair(leftBuffer: buffer, leftChannel: 0, rightBuffer: buffer + 1, rightChannel: 0) }
      let stereo = inputBuffers[buffer] >= 2
      return ChannelPair(leftBuffer: buffer, leftChannel: 0, rightBuffer: buffer, rightChannel: stereo ? 1 : 0)
    }
  }

  /// Maps the device's preferred stereo channels (1-based, across all streams) to buffer/channel pairs.
  private static func outputLayout(aggregate: AudioObjectID, device: AudioDeviceID) throws -> ChannelPair {
    let buffers = AudioObject.bufferChannels(aggregate, scope: kAudioObjectPropertyScopeOutput)
    guard !buffers.isEmpty, buffers.reduce(0, +) > 0 else {
      throw CoreAudioError(status: OSStatus(kAudioHardwareUnspecifiedError), context: "Reading output channels")
    }
    func locate(_ channel: Int) -> (Int, Int)? {
      var remaining = channel - 1
      for (index, count) in buffers.enumerated() {
        if remaining < count { return (index, remaining) }
        remaining -= count
      }
      return nil
    }
    let (l, r) = Devices.preferredStereoChannels(device)
    if let left = locate(l), let right = locate(r) {
      return ChannelPair(leftBuffer: left.0, leftChannel: left.1, rightBuffer: right.0, rightChannel: right.1)
    }
    let first = buffers.firstIndex { $0 > 0 } ?? 0
    let stereo = buffers[first] >= 2
    return ChannelPair(leftBuffer: first, leftChannel: 0, rightBuffer: first, rightChannel: stereo ? 1 : 0)
  }
}
