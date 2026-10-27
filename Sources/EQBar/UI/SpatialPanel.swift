import AppKit
import EQBarCore

final class SpatialPanel: NSStackView, PanelContent {
  private let controller: EQBarController
  private let layoutChanged: () -> Void

  private var enableSwitch: NSSwitch!
  private var outputPopup: NSPopUpButton!
  private var roomPopup: NSPopUpButton!
  private var amountSlider: NSSlider!
  private var amountValue: NSTextField!
  private var angleSlider: NSSlider!
  private var angleValue: NSTextField!
  private var hrtfBox: NSButton!
  private var spatialControls: [NSControl] = []
  private var crossfeedControl: NSSegmentedControl!
  private var widthSlider: NSSlider!
  private var widthValue: NSTextField!

  private let outputs = SpatialOutputKind.allCases
  private let rooms = RoomType.menuOrder

  init(controller: EQBarController, layoutChanged: @escaping () -> Void) {
    self.controller = controller
    self.layoutChanged = layoutChanged
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 8
    build()
    refresh()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  private func labeled(_ title: String, _ views: [NSView]) -> NSView {
    let label = UI.label(title, color: .labelColor)
    label.widthAnchor.constraint(equalToConstant: 92).isActive = true
    return UI.fill(UI.row([label] + views))
  }

  private func build() {
    let s = controller.settings.spatial
    enableSwitch = UI.toggle(s.enabled) { [weak self] on in self?.controller.updateSpatial { $0.enabled = on } }
    addArrangedSubview(UI.fill(UI.row([enableSwitch, UI.label("Spatial Audio", weight: .medium, color: .labelColor), UI.spacer()])))
    addArrangedSubview(UI.wrappingLabel(
      "Puts your stereo sound on two virtual speakers in front of you inside a simulated room, using Apple's spatial audio engine."))

    outputPopup = UI.popup(outputs.map(\.title), selected: 0) { [weak self] i in
      guard let self else { return }
      self.controller.updateSpatial { $0.output = self.outputs[i] }
    }
    addArrangedSubview(labeled("Listening on", [outputPopup, UI.spacer()]))

    roomPopup = UI.popup(rooms.map(\.title), selected: 0) { [weak self] i in
      guard let self else { return }
      self.controller.updateSpatial { $0.room = self.rooms[i] }
    }
    addArrangedSubview(labeled("Room", [roomPopup, UI.spacer()]))

    amountValue = UI.value()
    amountSlider = UI.slider(s.roomAmount, 0...100) { [weak self] v in
      self?.controller.updateSpatial { $0.roomAmount = v.rounded() }
    }
    addArrangedSubview(labeled("Room amount", [amountSlider, amountValue]))

    angleValue = UI.value()
    angleSlider = UI.slider(s.speakerAngle, 10...90) { [weak self] v in
      self?.controller.updateSpatial { $0.speakerAngle = v.rounded() }
    }
    angleSlider.toolTip = "How far apart the virtual speakers are. 30° matches a standard stereo setup."
    addArrangedSubview(labeled("Speaker angle", [angleSlider, angleValue]))

    hrtfBox = UI.checkbox("Personalized profile (Apple renderer, uses more memory)", on: s.personalizedHRTF) { [weak self] on in
      self?.controller.updateSpatial { $0.personalizedHRTF = on }
    }
    addArrangedSubview(hrtfBox)
    spatialControls = [outputPopup, roomPopup, amountSlider, angleSlider, hrtfBox]

    addArrangedSubview(UI.separator())

    crossfeedControl = UI.segmented(CrossfeedLevel.allCases.map(\.title), selected: 0) { [weak self] i in
      self?.controller.update { $0.crossfeed = CrossfeedLevel.allCases[i] }
    }
    crossfeedControl.toolTip = "Blends a little of each channel into the other ear, like listening to speakers. Easier on the ears with headphones."
    addArrangedSubview(labeled("Crossfeed", [crossfeedControl, UI.spacer()]))

    widthValue = UI.value()
    widthSlider = UI.slider(controller.settings.stereoWidth, 0...2) { [weak self] v in
      let snapped = abs(v - 1) < 0.04 ? 1 : v
      self?.controller.update { $0.stereoWidth = snapped }
    }
    widthSlider.toolTip = "0% is mono, 100% is unchanged, 200% is extra wide"
    addArrangedSubview(labeled("Stereo width", [widthSlider, widthValue]))
  }

  func refresh() {
    let settings = controller.settings
    let s = settings.spatial
    enableSwitch.state = s.enabled ? .on : .off
    outputPopup.selectItem(at: outputs.firstIndex(of: s.output) ?? 0)
    if s.output == .auto {
      outputPopup.item(at: 0)?.title = "Auto (\(controller.resolvedSpatialOutput.title))"
    }
    roomPopup.selectItem(at: rooms.firstIndex(of: s.room) ?? 0)
    amountSlider.doubleValue = s.roomAmount
    amountValue.stringValue = String(format: "%.0f%%", s.roomAmount)
    angleSlider.doubleValue = s.speakerAngle
    angleValue.stringValue = String(format: "%.0f°", s.speakerAngle)
    hrtfBox.state = s.personalizedHRTF ? .on : .off
    let headphones = controller.resolvedSpatialOutput == .headphones
    for control in spatialControls { control.isEnabled = s.enabled }
    amountSlider.isEnabled = s.enabled && s.room != .none
    hrtfBox.isEnabled = s.enabled && headphones
    crossfeedControl.selectedSegment = CrossfeedLevel.allCases.firstIndex(of: settings.crossfeed) ?? 0
    widthSlider.doubleValue = settings.stereoWidth
    widthValue.stringValue = String(format: "%.0f%%", settings.stereoWidth * 100)
  }
}
