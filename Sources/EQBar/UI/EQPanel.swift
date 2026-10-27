import AppKit
import EQBarCore
import UniformTypeIdentifiers

final class EQPanel: NSStackView, PanelContent {
  private let controller: EQBarController
  private let layoutChanged: () -> Void
  private let openAutoEQ: () -> Void

  private var enableSwitch: NSSwitch!
  private var modeControl: NSSegmentedControl!
  private var presetPopup: NSPopUpButton!
  private var actionsButton: NSButton!
  private var spectrum: SpectrumView?
  private let modeContainer = NSStackView()
  private var preampSlider: NSSlider!
  private var preampValue: NSTextField!
  private var autoPreampBox: NSButton!
  private var saveRow: NSStackView!
  private var saveField: NSTextField!

  private var builtMode: EQMode?
  private var builtExpertIDs: [UUID] = []
  private var basicSliders: [NSSlider] = []
  private var basicValues: [NSTextField] = []
  private var graphicSliders: [NSSlider] = []
  private var graphicValues: [NSTextField] = []
  private var expertRows: [ExpertBandRow] = []
  private var presets: [EQPreset] = []

  private var eq: EQSettings { controller.settings.eq }

  init(controller: EQBarController, layoutChanged: @escaping () -> Void, openAutoEQ: @escaping () -> Void) {
    self.controller = controller
    self.layoutChanged = layoutChanged
    self.openAutoEQ = openAutoEQ
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 8
    build()
    refresh()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  private func build() {
    enableSwitch = UI.toggle(eq.enabled) { [weak self] on in self?.controller.update { $0.eq.enabled = on } }
    enableSwitch.toolTip = "Equalizer on/off"
    modeControl = UI.segmented(EQMode.allCases.map(\.title), selected: 0) { [weak self] index in
      self?.controller.update { $0.eq.mode = EQMode.allCases[index] }
    }
    addArrangedSubview(UI.fill(UI.row([enableSwitch, UI.label("Equalizer", weight: .medium, color: .labelColor),
                                       UI.spacer(), modeControl])))

    presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    presetPopup.controlSize = .small
    presetPopup.font = .systemFont(ofSize: 11)
    presetPopup.setContentHuggingPriority(.init(1), for: .horizontal)
    presetPopup.onAction { [weak self] in self?.presetChosen() }
    let autoEQ = UI.button("AutoEQ…") { [weak self] in self?.openAutoEQ() }
    autoEQ.toolTip = "Find your headphones in the AutoEq database and apply their correction profile"
    actionsButton = UI.iconButton("ellipsis.circle", tooltip: "Save, import and export") { [weak self] in self?.showActions() }
    addArrangedSubview(UI.fill(UI.row([presetPopup, autoEQ, actionsButton])))

    saveField = NSTextField(string: "")
    saveField.placeholderString = "Preset name"
    saveField.controlSize = .small
    saveField.font = .systemFont(ofSize: 11)
    saveField.onAction { [weak self] in self?.commitSave() }
    saveRow = UI.row([saveField, UI.button("Save") { [weak self] in self?.commitSave() },
                      UI.button("Cancel") { [weak self] in self?.setSaveRowHidden(true) }])
    UI.fill(saveRow)
    saveRow.isHidden = true
    addArrangedSubview(saveRow)

    let spectrumView = SpectrumView(controller: controller, showsSpectrum: controller.settings.showSpectrum,
                                    height: controller.settings.showSpectrum ? 92 : 64)
    spectrum = spectrumView
    addArrangedSubview(spectrumView)

    modeContainer.orientation = .vertical
    modeContainer.alignment = .leading
    modeContainer.spacing = 6
    addArrangedSubview(modeContainer)

    preampSlider = UI.slider(eq.preampDB, -24...12) { [weak self] v in
      self?.controller.update { s in s.eq.preampDB = (v * 2).rounded() / 2; s.eq.autoPreamp = false }
    }
    preampValue = UI.value(width: 56)
    autoPreampBox = UI.checkbox("Auto", on: eq.autoPreamp) { [weak self] on in
      self?.controller.update { $0.eq.autoPreamp = on }
    }
    autoPreampBox.toolTip = "Lower the level automatically so boosted bands can't clip"
    addArrangedSubview(UI.fill(UI.row([UI.label("Preamp"), preampSlider, preampValue, autoPreampBox])))
  }

  // MARK: - Refresh

  func refresh() {
    let eq = self.eq
    enableSwitch.state = eq.enabled ? .on : .off
    modeControl.selectedSegment = EQMode.allCases.firstIndex(of: eq.mode) ?? 0
    let expertIDs = eq.expert.map(\.id)
    if builtMode != eq.mode || (eq.mode == .expert && expertIDs != builtExpertIDs) {
      rebuildModeContent()
    } else {
      updateModeValues()
    }
    preampSlider.doubleValue = controller.effectivePreampDB
    preampValue.stringValue = UI.formatDB(controller.effectivePreampDB)
    autoPreampBox.state = eq.autoPreamp ? .on : .off
    refreshPresets()
    spectrum?.refreshCurve()
  }

  private func rebuildModeContent() {
    modeContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
    basicSliders = []; basicValues = []; graphicSliders = []; graphicValues = []; expertRows = []
    builtMode = eq.mode
    builtExpertIDs = eq.expert.map(\.id)
    switch eq.mode {
    case .basic: buildBasic()
    case .advanced: buildAdvanced()
    case .expert: buildExpert()
    }
    updateModeValues()
    layoutChanged()
  }

  private func updateModeValues() {
    let eq = self.eq
    let basic = [eq.basic.bass, eq.basic.mid, eq.basic.treble]
    for (i, slider) in basicSliders.enumerated() {
      slider.doubleValue = basic[i]
      basicValues[i].stringValue = UI.formatDB(basic[i])
    }
    for (i, slider) in graphicSliders.enumerated() where i < eq.graphic.count {
      slider.doubleValue = eq.graphic[i]
      graphicValues[i].stringValue = String(format: "%+.0f", eq.graphic[i]).replacingOccurrences(of: "+0", with: "0")
    }
    for row in expertRows {
      if let band = eq.expert.first(where: { $0.id == row.bandID }) { row.update(band) }
    }
  }

  // MARK: - Basic

  private func buildBasic() {
    let names = ["Bass", "Mid", "Treble"]
    for (i, name) in names.enumerated() {
      let value = UI.value(width: 56)
      let slider = UI.slider(0, -12...12) { [weak self] v in
        let rounded = (v * 2).rounded() / 2
        self?.controller.updateEQ { eq in
          switch i {
          case 0: eq.basic.bass = rounded
          case 1: eq.basic.mid = rounded
          default: eq.basic.treble = rounded
          }
        }
      }
      let label = UI.label(name, color: .labelColor)
      label.widthAnchor.constraint(equalToConstant: 46).isActive = true
      basicSliders.append(slider)
      basicValues.append(value)
      modeContainer.addArrangedSubview(UI.fill(UI.row([label, slider, value])))
    }
  }

  // MARK: - Advanced (10-band graphic)

  private func buildAdvanced() {
    var columns: [NSView] = []
    for (i, label) in GraphicEQ.labels.enumerated() {
      let value = UI.label("0", size: 9, color: .secondaryLabelColor, align: .center)
      value.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
      let slider = UI.verticalSlider(0, -12...12, height: 118) { [weak self] v in
        let rounded = (v * 2).rounded() / 2
        self?.controller.updateEQ { $0.graphic[i] = rounded }
      }
      slider.toolTip = "\(label) Hz"
      graphicSliders.append(slider)
      graphicValues.append(value)
      let column = UI.column([value, slider, UI.label(label, size: 9, color: .secondaryLabelColor, align: .center)], spacing: 2)
      column.alignment = .centerX
      column.widthAnchor.constraint(equalToConstant: 28).isActive = true
      columns.append(column)
    }
    let row = UI.row(columns, spacing: 3)
    row.distribution = .equalSpacing
    modeContainer.addArrangedSubview(UI.fill(row))
  }

  // MARK: - Expert (parametric, unlimited bands)

  private func buildExpert() {
    let header = UI.row([
      fixed(UI.label("On", size: 9), 22), fixed(UI.label("Type", size: 9), 86),
      fixed(UI.label("Freq (Hz)", size: 9, align: .right), 58), fixed(UI.label("Gain (dB)", size: 9, align: .right), 52),
      fixed(UI.label("Q", size: 9, align: .right), 40)
    ], spacing: 6)
    modeContainer.addArrangedSubview(header)

    let rows = NSStackView()
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 4
    for band in eq.expert {
      let row = ExpertBandRow(band: band,
                              changed: { [weak self] updated in self?.updateBand(updated) },
                              removed: { [weak self] id in self?.removeBand(id) })
      expertRows.append(row)
      rows.addArrangedSubview(row)
    }

    let visibleRows = min(eq.expert.count, 7)
    if eq.expert.count > visibleRows {
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.drawsBackground = false
      scroll.borderType = .noBorder
      let document = FlippedView()
      document.translatesAutoresizingMaskIntoConstraints = false
      rows.translatesAutoresizingMaskIntoConstraints = false
      document.addSubview(rows)
      NSLayoutConstraint.activate([
        rows.topAnchor.constraint(equalTo: document.topAnchor),
        rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
        rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        document.widthAnchor.constraint(equalToConstant: UI.contentWidth - 4)
      ])
      scroll.documentView = document
      scroll.translatesAutoresizingMaskIntoConstraints = false
      scroll.heightAnchor.constraint(equalToConstant: CGFloat(visibleRows) * 26).isActive = true
      UI.fill(scroll)
      modeContainer.addArrangedSubview(scroll)
    } else {
      modeContainer.addArrangedSubview(rows)
    }

    let add = UI.button("Add Band") { [weak self] in self?.addBand() }
    let count = UI.label("\(eq.expert.count) band\(eq.expert.count == 1 ? "" : "s")", size: 10)
    modeContainer.addArrangedSubview(UI.row([add, count]))
  }

  private func fixed(_ view: NSView, _ width: CGFloat) -> NSView {
    view.widthAnchor.constraint(equalToConstant: width).isActive = true
    return view
  }

  private func updateBand(_ band: EQBand) {
    controller.updateEQ { eq in
      if let i = eq.expert.firstIndex(where: { $0.id == band.id }) { eq.expert[i] = band }
    }
  }

  private func removeBand(_ id: UUID) {
    controller.updateEQ { $0.expert.removeAll { $0.id == id } }
  }

  private func addBand() {
    controller.updateEQ { eq in
      // Put the new band in the widest gap between existing ones.
      let used = eq.expert.map(\.frequency).sorted()
      var frequency = 1000.0
      if !used.isEmpty {
        let edges = [20.0] + used + [20_000.0]
        var best = 0.0
        for i in 0..<(edges.count - 1) where log(edges[i + 1] / edges[i]) > best {
          best = log(edges[i + 1] / edges[i])
          frequency = (sqrt(edges[i] * edges[i + 1])).rounded()
        }
      }
      eq.expert.append(EQBand(type: .peak, frequency: frequency, gain: 0, q: 1))
    }
  }

  // MARK: - Presets

  /// Shows the preset whose values match the current EQ, or "Custom".
  private func refreshPresets() {
    presets = controller.presets(for: eq.mode)
    let menu = NSMenu()
    let match = matchingPreset()
    if match == nil {
      let custom = NSMenuItem(title: "Custom", action: nil, keyEquivalent: "")
      custom.representedObject = nil
      menu.addItem(custom)
    }
    var addedSeparator = false
    for preset in presets {
      if !preset.isBuiltIn && !addedSeparator {
        menu.addItem(.separator())
        addedSeparator = true
      }
      let item = NSMenuItem(title: preset.name, action: nil, keyEquivalent: "")
      item.representedObject = preset.id
      menu.addItem(item)
    }
    presetPopup.menu = menu
    if let match, let item = menu.items.first(where: { ($0.representedObject as? String) == match.id }) {
      presetPopup.select(item)
    } else {
      presetPopup.selectItem(at: 0)
    }
  }

  private func matchingPreset() -> EQPreset? {
    let eq = self.eq
    func same(_ a: [Double], _ b: [Double]) -> Bool {
      a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.01 }
    }
    func matches(_ p: EQPreset) -> Bool {
      switch eq.mode {
      case .basic:
        guard let b = p.basic else { return false }
        return same([b.bass, b.mid, b.treble], [eq.basic.bass, eq.basic.mid, eq.basic.treble])
      case .advanced:
        return same(p.graphic ?? [], eq.graphic)
      case .expert:
        guard let bands = p.expert, bands.count == eq.expert.count else { return false }
        return zip(bands, eq.expert).allSatisfy {
          $0.type == $1.type && $0.enabled == $1.enabled && same([$0.frequency, $0.gain, $0.q], [$1.frequency, $1.gain, $1.q])
        }
      }
    }
    let candidates = presets.filter(matches)
    return candidates.first { $0.name == eq.presetName } ?? candidates.last
  }

  private func presetChosen() {
    guard let id = presetPopup.selectedItem?.representedObject as? String,
          let preset = presets.first(where: { $0.id == id }) else { return }
    controller.applyPreset(preset)
  }

  private func showActions() {
    let menu = NSMenu()
    menu.addItem(NSMenuItem("Save as Preset…") { [weak self] in self?.setSaveRowHidden(false) })
    if let current = matchingPreset(), !current.isBuiltIn {
      menu.addItem(NSMenuItem("Delete “\(current.name)”") { [weak self] in self?.controller.deletePreset(id: current.id) })
    }
    menu.addItem(.separator())
    menu.addItem(NSMenuItem("Find Headphone Profile (AutoEQ)…") { [weak self] in self?.openAutoEQ() })
    menu.addItem(NSMenuItem("Import EQ File…") { [weak self] in self?.importFile() })
    menu.addItem(NSMenuItem("Export Current EQ…") { [weak self] in self?.exportFile() })
    menu.addItem(.separator())
    menu.addItem(NSMenuItem("Reset to Flat") { [weak self] in self?.resetFlat() })
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: actionsButton.bounds.height + 4), in: actionsButton)
  }

  private func setSaveRowHidden(_ hidden: Bool) {
    saveRow.isHidden = hidden
    if !hidden {
      saveField.stringValue = eq.presetName == "Custom" ? "" : eq.presetName
      window?.makeFirstResponder(saveField)
    }
    layoutChanged()
  }

  private func commitSave() {
    let name = saveField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    controller.saveCurrentAsPreset(named: name)
    setSaveRowHidden(true)
  }

  private func resetFlat() {
    controller.update { s in
      switch s.eq.mode {
      case .basic: s.eq.basic = BasicGains()
      case .advanced: s.eq.graphic = Array(repeating: 0, count: GraphicEQ.frequencies.count)
      case .expert: s.eq.expert = EQSettings.defaultExpert
      }
      s.eq.autoPreamp = true
      s.eq.presetName = "Flat"
    }
  }

  // MARK: - Files

  private func importFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.plainText, .text, .json]
    panel.allowsMultipleSelection = false
    panel.message = "Choose an Equalizer APO / AutoEq ParametricEQ.txt file, or an eqMac preset export"
    let controller = self.controller
    NSApp.activate(ignoringOtherApps: true)
    panel.begin { response in
      guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
      switch EQImport.parse(data) {
      case .profile(let profile)?:
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ParametricEQ", with: "")
        controller.applyProfile(profile, name: name)
      case .presets(let presets)?:
        controller.importPresets(presets)
        if let first = presets.first { controller.applyPreset(first) }
      case nil:
        let alert = NSAlert()
        alert.messageText = "Couldn't read that file"
        alert.informativeText = "EQBar understands Equalizer APO / AutoEq ParametricEQ.txt files and eqMac preset exports."
        alert.runModal()
      }
    }
  }

  private func exportFile() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    let name = eq.presetName == "Custom" ? "EQBar" : eq.presetName
    panel.nameFieldStringValue = "\(name) ParametricEQ.txt"
    let text = ParametricEQParser.format(controller.currentProfile())
    NSApp.activate(ignoringOtherApps: true)
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      try? text.write(to: url, atomically: true, encoding: .utf8)
    }
  }
}

/// One editable parametric band.
final class ExpertBandRow: NSStackView {
  let bandID: UUID
  private var band: EQBand
  private let changed: (EQBand) -> Void
  private var enabledBox: NSButton!
  private var typePopup: NSPopUpButton!
  private var frequencyField: NSTextField!
  private var gainField: NSTextField!
  private var qField: NSTextField!

  init(band: EQBand, changed: @escaping (EQBand) -> Void, removed: @escaping (UUID) -> Void) {
    self.band = band
    bandID = band.id
    self.changed = changed
    super.init(frame: .zero)
    orientation = .horizontal
    alignment = .centerY
    spacing = 6

    enabledBox = UI.checkbox("", on: band.enabled) { [weak self] on in self?.edit { $0.enabled = on } }
    enabledBox.widthAnchor.constraint(equalToConstant: 22).isActive = true
    typePopup = UI.popup(FilterType.allCases.map(\.shortName),
                         selected: FilterType.allCases.firstIndex(of: band.type) ?? 0) { [weak self] i in
      self?.edit { $0.type = FilterType.allCases[i] }
    }
    typePopup.widthAnchor.constraint(equalToConstant: 86).isActive = true
    frequencyField = UI.numberField(band.frequency, range: 10...22_000, decimals: 0, width: 58) { [weak self] v in
      self?.edit { $0.frequency = v }
    }
    gainField = UI.numberField(band.gain, range: -30...30, decimals: 1, width: 52) { [weak self] v in
      self?.edit { $0.gain = v }
    }
    qField = UI.numberField(band.q, range: 0.05...30, decimals: 2, width: 40) { [weak self] v in
      self?.edit { $0.q = v }
    }
    let remove = UI.iconButton("minus.circle", tooltip: "Remove band", size: 12) { [weak self] in
      guard let self else { return }
      removed(self.bandID)
    }
    for view in [enabledBox!, typePopup!, frequencyField!, gainField!, qField!, remove] { addArrangedSubview(view) }
    update(band)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  private func edit(_ body: (inout EQBand) -> Void) {
    body(&band)
    changed(band)
  }

  func update(_ band: EQBand) {
    self.band = band
    enabledBox.state = band.enabled ? .on : .off
    typePopup.selectItem(at: FilterType.allCases.firstIndex(of: band.type) ?? 0)
    // Don't fight the user while they type.
    if frequencyField.currentEditor() == nil { frequencyField.doubleValue = band.frequency }
    if gainField.currentEditor() == nil { gainField.doubleValue = band.gain }
    if qField.currentEditor() == nil { qField.doubleValue = band.q }
    gainField.isEnabled = band.type.usesGain
  }
}

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
