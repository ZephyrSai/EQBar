import Foundation
import Testing
@testable import EQBarCore

@Suite struct ParserTests {
  let autoEQ = """
  Preamp: -6.3 dB
  Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
  Filter 2: ON PK Fc 125 Hz Gain -2.7 dB Q 0.55
  Filter 3: ON HSC Fc 10000 Hz Gain -3.1 dB Q 0.70
  Filter 4: OFF PK Fc 3158 Hz Gain -1.8 dB Q 3.67
  """

  @Test func parsesAutoEqParametricFiles() throws {
    let profile = try #require(ParametricEQParser.parse(autoEQ))
    #expect(profile.preampDB == -6.3)
    #expect(profile.bands.count == 4)
    #expect(profile.bands[0].type == .lowShelf)
    #expect(profile.bands[0].frequency == 105)
    #expect(profile.bands[1].gain == -2.7)
    #expect(profile.bands[2].type == .highShelf)
    #expect(profile.bands[3].enabled == false)
  }

  @Test func formatRoundTrips() throws {
    let profile = try #require(ParametricEQParser.parse(autoEQ))
    let again = try #require(ParametricEQParser.parse(ParametricEQParser.format(profile)))
    #expect(again.bands.map(\.type) == profile.bands.map(\.type))
    #expect(again.bands.map(\.frequency) == profile.bands.map(\.frequency))
    #expect(again.preampDB == profile.preampDB)
  }

  @Test func importsEqMacPresetExports() throws {
    let json = #"[{"id":"x","name":"Rock","isDefault":false,"gains":{"global":-2,"bands":[5,4,3,1,0,-1,0,2,3,4]}}]"#
    guard case .presets(let presets)? = EQImport.parse(Data(json.utf8)) else {
      Issue.record("expected presets")
      return
    }
    #expect(presets.count == 1)
    #expect(presets[0].mode == .advanced)
    #expect(presets[0].graphic?.first == 5)
    #expect(presets[0].preampDB == -2)
  }

  @Test func parsesTheAutoEqIndexAndSearches() {
    let index = """
    # Index
    - [Sennheiser HD 600](./oratory1990/over-ear/Sennheiser%20HD%20600) by oratory1990
    - [Sennheiser HD 600](./crinacle/GRAS%2043AG-7%20over-ear/Sennheiser%20HD%20600) by crinacle on GRAS 43AG-7
    - [1MORE Aero (ANC On)](./HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20On)) by HypetheSonics on GRAS RA0045
    - [Apple AirPods Pro 2](./Rtings/in-ear/Apple%20AirPods%20Pro%202) by Rtings
    """
    let entries = AutoEQService.parseIndex(index)
    #expect(entries.count == 4)
    #expect(entries[0].path == "oratory1990/over-ear/Sennheiser%20HD%20600")
    #expect(entries[1].source == "crinacle on GRAS 43AG-7")
    #expect(entries[2].name == "1MORE Aero (ANC On)")
    #expect(AutoEQService.search("hd 600", in: entries).count == 2)
    #expect(AutoEQService.search("airpods pro", in: entries).first?.name == "Apple AirPods Pro 2")
    #expect(AutoEQService.search("zzz", in: entries).isEmpty)
  }
}

@Suite struct SettingsTests {
  @Test func partialFilesKeepDefaults() throws {
    let json = #"{"volume": 0.5, "eq": {"mode": "expert"}, "unknownKey": 1}"#
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    #expect(settings.volume == 0.5)
    #expect(settings.eq.mode == .expert)
    #expect(settings.eq.graphic.count == 10)
    #expect(settings.limiter == true)
    #expect(settings.spatial.room == .mediumRoom)
  }

  @Test func roundTripsThroughTheStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SettingsStore(directory: directory)
    var settings = AppSettings()
    settings.eq.graphic[3] = 4.5
    settings.appVolumes["com.apple.Music"] = AppVolume(volume: 0.4, muted: false, name: "Music")
    settings.spatial.room = .cathedral
    store.save(settings)
    #expect(store.load() == settings)
  }

  @Test func everyModeProducesBands() {
    var eq = EQSettings()
    eq.mode = .basic
    #expect(eq.bands().count == 3)
    eq.mode = .advanced
    #expect(eq.bands().count == 10)
    eq.mode = .expert
    #expect(eq.bands().count == EQSettings.defaultExpert.count)
  }

  @Test func builtInPresetsAreWellFormed() {
    for preset in BuiltInPresets.advanced {
      #expect(preset.graphic?.count == 10)
      #expect(preset.isBuiltIn)
      #expect((preset.graphic ?? []).allSatisfy { abs($0) <= 12 })
    }
  }

  @Test func volumeCurve() {
    #expect(EQBarController.volumeGain(0) == 0)
    #expect(EQBarController.volumeGain(1) == 1)
    #expect(abs(EQBarController.volumeGain(2) - pow(10, 12.0 / 20)) < 1e-9)
    #expect(EQBarController.volumeGain(0.5) == 0.25)
  }
}

@Suite struct VolumeKeyTests {
  typealias C = EQBarController

  @Test func hardwareVolumeBelowMaximumStaysWithMacOS() {
    #expect(C.resolveVolumeKey(.up(fine: false), volume: 1, muted: false, hardwareVolume: 0.5, hardwareMuted: false) == nil)
    #expect(C.resolveVolumeKey(.down(fine: false), volume: 1, muted: false, hardwareVolume: 0.5, hardwareMuted: false) == nil)
    #expect(C.resolveVolumeKey(.mute, volume: 1, muted: false, hardwareVolume: 0.5, hardwareMuted: false) == nil)
  }

  @Test func volumeUpAtHardwareMaximumBoosts() throws {
    let r = try #require(C.resolveVolumeKey(.up(fine: false), volume: 1, muted: false, hardwareVolume: 1, hardwareMuted: false))
    #expect(r.volume == 1 + 1.0 / 16)
    #expect(r.muted == false)
    // A muted device gets unmuted by macOS first.
    #expect(C.resolveVolumeKey(.up(fine: false), volume: 1, muted: false, hardwareVolume: 1, hardwareMuted: true) == nil)
  }

  @Test func volumeDownLeavesBoostThenHandsBack() throws {
    let r = try #require(C.resolveVolumeKey(.down(fine: false), volume: 1.0625, muted: false, hardwareVolume: 1, hardwareMuted: false))
    #expect(r.volume == 1)
    #expect(C.resolveVolumeKey(.down(fine: false), volume: 1, muted: false, hardwareVolume: 1, hardwareMuted: false) == nil)
  }

  @Test func boostIsCappedAndFineStepsWork() throws {
    let top = try #require(C.resolveVolumeKey(.up(fine: false), volume: 2, muted: false, hardwareVolume: 1, hardwareMuted: false))
    #expect(top.volume == 2)
    let fine = try #require(C.resolveVolumeKey(.up(fine: true), volume: 1, muted: false, hardwareVolume: 1, hardwareMuted: false))
    #expect(fine.volume == 1 + 1.0 / 64)
  }

  @Test func outputsWithoutVolumeAreFullyControlled() throws {
    let down = try #require(C.resolveVolumeKey(.down(fine: false), volume: 0.5, muted: false, hardwareVolume: nil, hardwareMuted: false))
    #expect(down.volume == 0.4375)
    let floor = try #require(C.resolveVolumeKey(.down(fine: false), volume: 0, muted: false, hardwareVolume: nil, hardwareMuted: false))
    #expect(floor.volume == 0)
    let mute = try #require(C.resolveVolumeKey(.mute, volume: 0.5, muted: false, hardwareVolume: nil, hardwareMuted: false))
    #expect(mute.muted && mute.volume == 0.5)
    let up = try #require(C.resolveVolumeKey(.up(fine: false), volume: 0.5, muted: true, hardwareVolume: nil, hardwareMuted: false))
    #expect(up.volume == 0.5625 && !up.muted)
  }
}

@Suite struct UnifiedVolumeTests {
  @Test func devicesWithVolumeOnlyGetBoostFromEQBar() {
    // 0–100% is the device's own volume, so EQBar applies no attenuation of its own…
    #expect(EQBarController.softwareGain(volume: 0.3, deviceHasVolume: true) == 1)
    #expect(EQBarController.softwareGain(volume: 1, deviceHasVolume: true) == 1)
    // …and only the boost above it.
    #expect(abs(EQBarController.softwareGain(volume: 1.5, deviceHasVolume: true) - pow(10, 6.0 / 20)) < 1e-9)
  }

  @Test func outputsWithoutVolumeUseEQBarsCurve() {
    #expect(EQBarController.softwareGain(volume: 0.5, deviceHasVolume: false) == 0.25)
    #expect(EQBarController.softwareGain(volume: 0, deviceHasVolume: false) == 0)
  }
}
