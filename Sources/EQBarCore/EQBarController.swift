import AppKit
import CoreAudio
import Foundation

public enum EngineStatus: Equatable {
  case off
  case starting
  case running
  case permissionRequired
  case failed(String)
}

/// Owns the settings, the audio engine and everything around it. Main thread only.
///
/// UI code mutates settings through the methods here; each change is turned into an immutable
/// parameter snapshot for the audio thread, and settings are saved to disk shortly afterwards.
public final class EQBarController {
  public static let didChange = Notification.Name("EQBarControllerDidChange")

  public private(set) var settings: AppSettings
  public private(set) var status: EngineStatus = .off { didSet { if status != oldValue { notify() } } }
  public private(set) var outputDeviceID: AudioDeviceID?
  public private(set) var outputDeviceName = ""
  public private(set) var outputHasHardwareVolume = true
  public private(set) var outputHasHardwareMute = false
  public private(set) var loadedPlugins: [UUID: HostedPlugin] = [:]
  public private(set) var pluginErrors: [UUID: String] = [:]

  /// Set while the spectrum view is on screen; the audio thread only feeds the analyzer then.
  public var analyzerActive = false { didSet { if analyzerActive != oldValue { publish() } } }
  public var sampleRate: Double { context?.sampleRate ?? 48_000 }
  public var analyzerRing: SampleRing? { context?.analyzerRing }

  /// One-line engine summary for EQBAR_DEBUG logging.
  public var debugSummary: String {
    var line = "status=\(status) device=\(outputDeviceName)"
    line += String(format: " volume=%.3f muted=%d", settings.volume, settings.muted ? 1 : 0)
    if let engine, let context {
      line += String(format: " rate=%.0f taps=%d cycles=%d in=%.3f out=%.3f",
                     engine.sampleRate, engine.appTaps.count + 1, context.cycles, context.inputPeak, context.outputPeak)
    }
    return line
  }

  private let store: SettingsStore
  private let engineQueue = DispatchQueue(label: "eqbar.engine", qos: .userInitiated)
  private var engine: TapEngine?
  private var context: RenderContext?
  private var spatial: SpatialProcessor?
  private var buildToken = 0
  private var rebuildWork: DispatchWorkItem?
  private var saveWork: DispatchWorkItem?
  private var defaultDeviceListener: PropertyListener?
  private var sampleRateListener: PropertyListener?
  private var processListener: PropertyListener?
  private var hardwareVolumeListener: PropertyListener?
  private var hardwareMuteListener: PropertyListener?
  private var listenedDevice: AudioDeviceID?
  private var spatialRebuildWork: DispatchWorkItem?
  /// Set when something large (spatial renderer, plugin) was dropped; its memory goes back to the OS once freed.
  private var releaseMemoryAfterCollect = false
  private var wakeObserver: NSObjectProtocol?

  public init(store: SettingsStore = SettingsStore()) {
    self.store = store
    settings = store.load()
  }

  // MARK: - Lifecycle

  public func start() {
    defaultDeviceListener = PropertyListener(AudioObject.system, .init(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
      self?.scheduleRebuild()
    }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
        self?.scheduleRebuild(after: 1.5)
      }
    refreshDevice()
    loadPlugins()
    updateProcessListener()
    if settings.enabled { startWithPermission() } else { status = .off }
  }

  /// Synchronous teardown for app termination.
  public func shutdown() {
    rebuildWork?.cancel()
    saveWork?.cancel()
    capturePluginStates()
    store.save(settings)
    let old = engine
    detach()
    if let old { engineQueue.sync { old.stop() } }
  }

  public func setEnabled(_ enabled: Bool) {
    guard settings.enabled != enabled else { return }
    settings.enabled = enabled
    if !enabled && settings.volume > 1 { settings.volume = 1 }   // boost can't apply while off
    scheduleSave()
    notify()
    if enabled { startWithPermission() } else { teardown(); status = .off }
  }

  /// Retry after the user grants the permission in System Settings.
  public func retryPermission() {
    if settings.enabled { startWithPermission() }
  }

  private func startWithPermission() {
    switch CapturePermission.status {
    case .authorized:
      rebuildNow()
    case .denied:
      teardown()
      status = .permissionRequired
    case .unknown:
      status = .starting
      let asked = CapturePermission.request { [weak self] granted in
        DispatchQueue.main.async {
          guard let self else { return }
          if granted {
            self.rebuildNow()
          } else {
            self.teardown()
            self.status = .permissionRequired
          }
        }
      }
      if !asked { rebuildNow() }
    }
  }

  public func scheduleRebuild(after delay: TimeInterval = 0.25) {
    rebuildWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if self.settings.enabled {
        self.startWithPermission()
      } else {
        self.refreshDevice()
        self.notify()
      }
    }
    rebuildWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func refreshDevice() {
    outputDeviceID = Devices.defaultOutput()
    if let id = outputDeviceID {
      outputDeviceName = Devices.name(id) ?? "Output"
      outputHasHardwareVolume = Devices.hasHardwareVolume(id)
      outputHasHardwareMute = Devices.hasHardwareMute(id)
    } else {
      outputDeviceName = "No Output"
      outputHasHardwareVolume = false
      outputHasHardwareMute = false
    }
    // Follow the device's own volume and mute, whoever changes them (keys, Control Center, other apps).
    if outputDeviceID != listenedDevice {
      listenedDevice = outputDeviceID
      hardwareVolumeListener = nil
      hardwareMuteListener = nil
      if let id = outputDeviceID {
        if outputHasHardwareVolume {
          hardwareVolumeListener = PropertyListener(id, Devices.mainVolumeAddress) { [weak self] in self?.syncFromHardware() }
        }
        if outputHasHardwareMute {
          hardwareMuteListener = PropertyListener(id, Devices.muteAddress) { [weak self] in self?.syncFromHardware() }
        }
      }
    }
    syncFromHardware()
  }

  /// Mirrors the device's volume and mute into EQBar's single volume control.
  /// Boost (above 100%) survives as long as the device stays at its maximum.
  private func syncFromHardware() {
    guard let id = outputDeviceID else { return }
    var changed = false
    if outputHasHardwareVolume, let hardware = Devices.hardwareVolume(id) {
      let boosting = settings.volume > 1 && hardware >= 0.999
      if !boosting && abs(settings.volume - Double(hardware)) > 0.0005 {
        settings.volume = Double(hardware)
        changed = true
      }
    }
    if outputHasHardwareMute {
      let muted = Devices.isHardwareMuted(id)
      if muted != settings.muted {
        settings.muted = muted
        changed = true
      }
    }
    if changed {
      publish()
      scheduleSave()
      notify()
    }
  }

  private func detach() {
    engine = nil
    context = nil
    spatial = nil
    sampleRateListener = nil
  }

  private func teardown() {
    rebuildWork?.cancel()
    buildToken += 1
    let old = engine
    detach()
    if let old { engineQueue.async { old.stop() } }
  }

  private func rebuildNow() {
    rebuildWork?.cancel()
    buildToken += 1
    let token = buildToken
    let old = engine
    detach()
    refreshDevice()
    guard let device = outputDeviceID else {
      if let old { engineQueue.async { old.stop() } }
      status = .failed("No output device")
      return
    }
    let taps = currentAppTaps()
    status = .starting
    notify()
    // Core Audio setup takes a few tens of milliseconds; keep it off the main thread.
    engineQueue.async { [weak self] in
      old?.stop()
      let result = Result { try TapEngine(outputDeviceID: device, appTaps: taps) }
      DispatchQueue.main.async {
        guard let self, token == self.buildToken else {
          if case .success(let stale) = result { stale.stop() }
          return
        }
        switch result {
        case .success(let engine): self.attach(engine)
        case .failure(let error): self.status = .failed(String(describing: error))
        }
      }
    }
  }

  private func attach(_ engine: TapEngine) {
    self.engine = engine
    context = engine.context
    sampleRateListener = PropertyListener(engine.outputDeviceID, .init(kAudioDevicePropertyNominalSampleRate)) { [weak self] in
      self?.scheduleRebuild()
    }
    rebuildSpatial()
    preparePlugins()
    publish()
    status = .running
    notify()
  }

  // MARK: - Parameters → audio thread

  public static func volumeGain(_ v: Double) -> Double {
    if v <= 0 { return 0 }
    if v <= 1 { return v * v }
    return pow(10, min(v - 1, 1) * 12 / 20)          // boost: up to +12 dB
  }

  /// The part of the volume EQBar applies itself. When the device has its own volume, 0–100% is the
  /// device's system volume and EQBar only adds the boost above it.
  public static func softwareGain(volume: Double, deviceHasVolume: Bool) -> Double {
    if deviceHasVolume { return volume > 1 ? volumeGain(volume) : 1 }
    return volumeGain(volume)
  }

  /// Sets EQBar's volume: 0–1 is the device's system volume (when it has one), above 1 is boost.
  public func setVolume(_ value: Double) {
    // Boost needs the engine; while EQBar is off the control is plain system volume.
    let volume = min(settings.enabled ? 2 : 1, max(0, value))
    if outputHasHardwareVolume, let id = outputDeviceID {
      Devices.setHardwareVolume(id, Float(min(volume, 1)))
      if volume > 0 && outputHasHardwareMute && settings.muted { Devices.setHardwareMute(id, false) }
    }
    update { s in
      s.volume = volume
      if volume > 0 { s.muted = false }
    }
  }

  public func setMuted(_ muted: Bool) {
    if outputHasHardwareMute, let id = outputDeviceID { Devices.setHardwareMute(id, muted) }
    update { $0.muted = muted }
  }

  public static func appGain(_ app: AppVolume) -> Double {
    if app.muted { return 0 }
    let v = app.volume
    return v <= 1 ? v * v : pow(10, min(v - 1, 0.5) * 12 / 20)   // up to +6 dB
  }

  public func publish() {
    guard let context else { return }
    let s = settings
    let rate = context.sampleRate

    var coefficients: [Double] = []
    var preampDB = 0.0
    if s.eq.enabled {
      let bands = Array(s.eq.bands().filter(\.enabled).prefix(EQProcessor.maxBands))
      coefficients.reserveCapacity(bands.count * 5)
      for band in bands {
        let b = band.biquad(sampleRate: rate)
        coefficients += [b.b0, b.b1, b.b2, b.a1, b.a2]
      }
      preampDB = s.eq.autoPreamp ? -max(0, EQMath.peakGain(bands, sampleRate: rate)) : s.eq.preampDB
    }

    let master = s.muted ? 0 : Self.softwareGain(volume: s.volume, deviceHasVolume: outputHasHardwareVolume)
    let gainLeft = master * (s.balance > 0 ? 1 - s.balance : 1)
    let gainRight = master * (s.balance < 0 ? 1 + s.balance : 1)

    var tapGains: [Float] = [1]
    if let engine {
      tapGains += engine.appTaps.map { Float(Self.appGain(s.appVolumes[$0.key] ?? AppVolume())) }
    }
    let plugins = s.plugins.filter { !$0.bypassed }.compactMap { setting -> HostedPlugin? in
      guard let plugin = loadedPlugins[setting.id], plugin.sampleRate == rate else { return nil }
      return plugin
    }

    context.mailbox.publish(ParamSnapshot(
      eq: coefficients,
      preamp: Float(pow(10, preampDB / 20)),
      gainLeft: Float(gainLeft),
      gainRight: Float(gainRight),
      tapGains: tapGains,
      crossfeed: CrossfeedCoefficients.make(s.crossfeed, sampleRate: rate),
      width: Float(s.stereoWidth),
      limiter: s.limiter,
      analyzer: analyzerActive,
      spatial: s.spatial.enabled ? spatial : nil,
      plugins: plugins,
      silenceFrames: Int(rate * tailSeconds(s, hasPlugins: !plugins.isEmpty))))

    // Release replaced snapshots once the grace period has passed, even if nothing publishes again.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak context] in
      context?.mailbox.collect()
      if let self, self.releaseMemoryAfterCollect {
        self.releaseMemoryAfterCollect = false
        malloc_zone_pressure_relief(nil, 0)
      }
    }
  }

  /// Longest time an effect can keep ringing after the input goes silent.
  private func tailSeconds(_ s: AppSettings, hasPlugins: Bool) -> Double {
    if hasPlugins { return 10 }            // unknown plugins may be delays or reverbs
    if s.spatial.enabled && s.spatial.room != .none { return 8 }
    return 0.25
  }

  public func update(_ body: (inout AppSettings) -> Void) {
    body(&settings)
    publish()
    scheduleSave()
    notify()
  }

  /// Changes made by hand mark the EQ as "Custom" rather than the last preset.
  public func updateEQ(_ body: (inout EQSettings) -> Void) {
    update { s in
      body(&s.eq)
      s.eq.presetName = "Custom"
    }
  }

  // MARK: - Volume keys

  public enum VolumeKey: Equatable {
    case up(fine: Bool)
    case down(fine: Bool)
    case mute
  }

  /// What to show after EQBar handled a volume key.
  public struct VolumeIndicator: Equatable {
    public let volume: Double            // EQBar volume, 0–2 (above 1 is boost)
    public let muted: Bool
    public let deviceHasVolume: Bool     // true: the indicator is about boost on top of the device's volume

    public init(volume: Double, muted: Bool, deviceHasVolume: Bool) {
      self.volume = volume
      self.muted = muted
      self.deviceHasVolume = deviceHasVolume
    }
  }

  /// Decides whether EQBar takes a volume key, and the resulting EQBar volume.
  /// Returns nil to let macOS handle it normally.
  ///
  /// - Outputs with their own volume: macOS keeps control of the hardware volume. Once that is at
  ///   maximum, Volume Up continues into EQBar's range (up to +12 dB boost); Volume Down comes back
  ///   out of the boost first, then hands control back to macOS. Mute stays with macOS.
  /// - Outputs without volume (HDMI, DisplayPort): the keys drive EQBar's volume and mute.
  public static func resolveVolumeKey(_ key: VolumeKey, volume: Double, muted: Bool,
                                      hardwareVolume: Float?, hardwareMuted: Bool) -> (volume: Double, muted: Bool)? {
    func step(_ value: Double, up: Bool, fine: Bool, floor: Double) -> Double {
      let size = fine ? 1.0 / 64 : 1.0 / 16
      let next = ((value + (up ? size : -size)) / size).rounded() * size
      return min(2, max(floor, next))
    }
    if let hardwareVolume {
      switch key {
      case .up(let fine):
        guard !hardwareMuted, hardwareVolume >= 0.999 else { return nil }
        return (step(volume, up: true, fine: fine, floor: 0), false)
      case .down(let fine):
        guard volume > 1 else { return nil }
        return (step(volume, up: false, fine: fine, floor: 1), false)
      case .mute:
        return nil
      }
    }
    switch key {
    case .up(let fine): return (step(volume, up: true, fine: fine, floor: 0), false)
    case .down(let fine): return (step(volume, up: false, fine: fine, floor: 0), false)
    case .mute: return (volume, !muted)
    }
  }

  /// Called for every volume key press while volume keys are enabled.
  public func handleVolumeKey(_ key: VolumeKey) -> VolumeIndicator? {
    guard settings.enabled, settings.volumeKeys, status == .running, let id = outputDeviceID else { return nil }
    let hardware = Devices.hardwareVolume(id)
    let hardwareMuted = hardware != nil && Devices.isHardwareMuted(id)
    guard let result = Self.resolveVolumeKey(key, volume: settings.volume, muted: settings.muted,
                                             hardwareVolume: hardware, hardwareMuted: hardwareMuted) else { return nil }
    if result.volume != settings.volume { setVolume(result.volume) }
    if result.muted != settings.muted { setMuted(result.muted) }
    return VolumeIndicator(volume: result.volume, muted: result.muted, deviceHasVolume: hardware != nil)
  }

  /// Asks open UI to re-read state, e.g. after a permission changed in System Settings.
  public func refreshObservers() { notify() }

  public func markAccessibilityPrompted() {
    guard !settings.accessibilityPrompted else { return }
    settings.accessibilityPrompted = true
    scheduleSave()
  }

  // MARK: - Devices

  public func outputDevices() -> [OutputDevice] { Devices.outputDevices() }

  /// Switches the system output; the default-device listener rebuilds the engine.
  public func selectOutput(_ id: AudioDeviceID) { Devices.setDefaultOutput(id) }

  public func outputFormats() -> (current: DeviceFormat?, available: [DeviceFormat]) {
    guard let id = outputDeviceID else { return (nil, []) }
    return Devices.outputFormats(id)
  }

  /// Sets the output device's sample rate / bit depth. The sample-rate listener rebuilds the engine.
  public func setOutputFormat(_ format: DeviceFormat) throws {
    guard let id = outputDeviceID else { return }
    defer { notify() }
    try Devices.setOutputFormat(format, device: id)
  }

  // MARK: - EQ

  public var effectivePreampDB: Double {
    guard settings.eq.enabled else { return 0 }
    let bands = settings.eq.bands().filter(\.enabled)
    return settings.eq.autoPreamp ? -max(0, EQMath.peakGain(bands, sampleRate: sampleRate)) : settings.eq.preampDB
  }

  /// EQ curve (excluding preamp) for drawing.
  public func eqResponse(at frequencies: [Double]) -> [Double] {
    guard settings.eq.enabled else { return frequencies.map { _ in 0 } }
    let filters = settings.eq.bands().filter(\.enabled).map { $0.biquad(sampleRate: sampleRate) }
    return EQMath.response(filters, at: frequencies, sampleRate: sampleRate)
  }

  public func presets(for mode: EQMode) -> [EQPreset] {
    BuiltInPresets.presets(for: mode)
      + settings.userPresets.filter { $0.mode == mode }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  public func applyPreset(_ preset: EQPreset) {
    update { s in
      s.eq.mode = preset.mode
      switch preset.mode {
      case .basic: s.eq.basic = preset.basic ?? BasicGains()
      case .advanced: s.eq.graphic = preset.graphic ?? Array(repeating: 0, count: GraphicEQ.frequencies.count)
      case .expert: s.eq.expert = preset.expert ?? EQSettings.defaultExpert
      }
      if let preamp = preset.preampDB {
        s.eq.preampDB = preamp
        s.eq.autoPreamp = false
      } else {
        s.eq.autoPreamp = true
      }
      s.eq.presetName = preset.name
    }
  }

  @discardableResult
  public func saveCurrentAsPreset(named name: String) -> EQPreset {
    let eq = settings.eq
    var preset = EQPreset(name: name, mode: eq.mode)
    switch eq.mode {
    case .basic: preset.basic = eq.basic
    case .advanced: preset.graphic = eq.graphic
    case .expert: preset.expert = eq.expert
    }
    preset.preampDB = eq.autoPreamp ? nil : eq.preampDB
    update { s in
      s.userPresets.removeAll { $0.name == name && $0.mode == eq.mode }
      s.userPresets.append(preset)
      s.eq.presetName = name
    }
    return preset
  }

  public func deletePreset(id: String) {
    update { s in
      s.userPresets.removeAll { $0.id == id }
      s.eq.presetName = "Custom"
    }
  }

  /// Applies a parametric profile (AutoEq download or imported file) in Expert mode and keeps it as a preset.
  public func applyProfile(_ profile: ParametricProfile, name: String) {
    let preset = EQPreset(name: name, mode: .expert, expert: profile.bands, preampDB: profile.preampDB)
    update { s in
      s.userPresets.removeAll { $0.name == name && $0.mode == .expert }
      s.userPresets.append(preset)
    }
    applyPreset(preset)
  }

  /// Adds presets from an imported file (e.g. eqMac's preset export). Same-named presets are replaced.
  public func importPresets(_ presets: [EQPreset]) {
    update { s in
      for preset in presets {
        s.userPresets.removeAll { $0.name == preset.name && $0.mode == preset.mode }
        s.userPresets.append(preset)
      }
    }
  }

  public func currentProfile() -> ParametricProfile {
    ParametricProfile(preampDB: effectivePreampDB, bands: settings.eq.bands())
  }

  // MARK: - Spatial

  public var resolvedSpatialOutput: SpatialOutputKind {
    if settings.spatial.output != .auto { return settings.spatial.output }
    guard let id = outputDeviceID else { return .headphones }
    return Devices.spatialKind(for: id)
  }

  public func updateSpatial(_ body: (inout SpatialSettings) -> Void) {
    let old = settings.spatial
    body(&settings.spatial)
    let new = settings.spatial
    if new.enabled != old.enabled {
      rebuildSpatial()
    } else if new.room != old.room || new.output != old.output || new.personalizedHRTF != old.personalizedHRTF {
      // Each renderer holds ~18 MB of HRTF data; debounce so clicking through rooms doesn't stack them.
      spatialRebuildWork?.cancel()
      let work = DispatchWorkItem { [weak self] in
        self?.rebuildSpatial()
        self?.publish()
      }
      spatialRebuildWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    } else {
      spatial?.update(new)
    }
    publish()
    scheduleSave()
    notify()
  }

  private func rebuildSpatial() {
    spatialRebuildWork?.cancel()
    if spatial != nil { releaseMemoryAfterCollect = true }
    guard let context, settings.spatial.enabled else {
      spatial = nil
      return
    }
    spatial = SpatialProcessor(sampleRate: context.sampleRate, maxFrames: context.maxFrames,
                               settings: settings.spatial, output: resolvedSpatialOutput)
  }

  // MARK: - Per-app volume

  /// Apps currently playing, plus any with a saved custom volume.
  public func audioApps() -> [AudioApp] {
    AudioProcesses.apps().filter { $0.isPlaying || settings.appVolumes[$0.key] != nil }
  }

  public func appVolume(for key: String) -> AppVolume { settings.appVolumes[key] ?? AppVolume() }

  public func setAppVolume(key: String, name: String, volume: Double, muted: Bool) {
    let value = AppVolume(volume: volume, muted: muted, name: name)
    settings.appVolumes[key] = value.isDefault ? nil : value
    // An app needs its own tap the first time it leaves 100%; after that only the gain changes.
    let tapped = engine?.appTaps.contains { $0.key == key } ?? false
    if !value.isDefault && !tapped && settings.enabled { scheduleRebuild(after: 0.15) }
    updateProcessListener()
    publish()
    scheduleSave()
  }

  private func currentAppTaps() -> [AppTap] {
    let custom = settings.appVolumes.filter { !$0.value.isDefault }
    guard !custom.isEmpty else { return [] }
    let apps = AudioProcesses.apps()
    return custom.keys.sorted().compactMap { key in
      guard let app = apps.first(where: { $0.key == key }), !app.processObjects.isEmpty else { return nil }
      return AppTap(key: key, processes: app.processObjects.sorted())
    }
  }

  /// Only watched while some app has a custom volume: new helper processes need to join its tap.
  private func updateProcessListener() {
    guard !settings.appVolumes.isEmpty else {
      processListener = nil
      return
    }
    guard processListener == nil else { return }
    processListener = PropertyListener(AudioObject.system, .init(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
      guard let self, self.settings.enabled, let engine = self.engine else { return }
      if self.currentAppTaps() != engine.appTaps { self.scheduleRebuild(after: 0.5) }
    }
  }

  // MARK: - Audio Unit plugins

  public func addPlugin(_ descriptor: PluginDescriptor) {
    let setting = PluginSetting(descriptor: descriptor)
    settings.plugins.append(setting)
    scheduleSave()
    notify()
    load(setting)
  }

  public func removePlugin(id: UUID) {
    settings.plugins.removeAll { $0.id == id }
    loadedPlugins[id] = nil      // a retired snapshot keeps it alive until the audio thread is done with it
    releaseMemoryAfterCollect = true
    pluginErrors[id] = nil
    publish()
    scheduleSave()
    notify()
  }

  public func movePlugin(id: UUID, by offset: Int) {
    guard let index = settings.plugins.firstIndex(where: { $0.id == id }) else { return }
    let target = max(0, min(settings.plugins.count - 1, index + offset))
    guard target != index else { return }
    update { s in s.plugins.insert(s.plugins.remove(at: index), at: target) }
  }

  public func setPluginBypassed(id: UUID, _ bypassed: Bool) {
    update { s in
      if let i = s.plugins.firstIndex(where: { $0.id == id }) { s.plugins[i].bypassed = bypassed }
    }
  }

  public func capturePluginStates() {
    for i in settings.plugins.indices {
      if let plugin = loadedPlugins[settings.plugins[i].id], let state = plugin.stateData() {
        settings.plugins[i].state = state
      }
    }
    scheduleSave()
  }

  private func loadPlugins() {
    for setting in settings.plugins { load(setting) }
  }

  private func load(_ setting: PluginSetting) {
    HostedPlugin.instantiate(setting.descriptor) { [weak self] result in
      guard let self, let current = self.settings.plugins.first(where: { $0.id == setting.id }) else { return }
      switch result {
      case .success(let plugin):
        plugin.restore(current.state)
        self.loadedPlugins[setting.id] = plugin
        self.pluginErrors[setting.id] = nil
        if let context = self.context {
          do { try plugin.prepare(sampleRate: context.sampleRate) } catch { self.pluginErrors[setting.id] = "\(error)" }
        }
        self.publish()
      case .failure(let error):
        self.pluginErrors[setting.id] = "\(error)"
      }
      self.notify()
    }
  }

  /// Called after a rebuild, when no snapshot that references the plugins is live.
  private func preparePlugins() {
    guard let context else { return }
    for (id, plugin) in loadedPlugins {
      do { try plugin.prepare(sampleRate: context.sampleRate) } catch { pluginErrors[id] = "\(error)" }
    }
  }

  // MARK: - Persistence & notifications

  private func scheduleSave() {
    saveWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.store.save(self.settings)
    }
    saveWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
  }

  private func notify() {
    NotificationCenter.default.post(name: Self.didChange, object: self)
  }
}
