import AppKit

/// Lets AppKit controls and menu items call a Swift closure instead of a target/selector pair.
final class ClosureTarget: NSObject {
  private let handler: () -> Void
  init(_ handler: @escaping () -> Void) { self.handler = handler }
  @objc func invoke(_ sender: Any?) { handler() }
}

private var closureTargetKey: UInt8 = 0

extension NSControl {
  func onAction(_ handler: @escaping () -> Void) {
    let target = ClosureTarget(handler)
    objc_setAssociatedObject(self, &closureTargetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    self.target = target
    action = #selector(ClosureTarget.invoke(_:))
  }
}

extension NSMenuItem {
  convenience init(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
    self.init(title: title, action: #selector(ClosureTarget.invoke(_:)), keyEquivalent: "")
    let target = ClosureTarget(handler)
    objc_setAssociatedObject(self, &closureTargetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    self.target = target
    state = checked ? .on : .off
    isEnabled = enabled
  }
}

/// Small factory for the popover's controls so every view looks consistent.
enum UI {
  static let width: CGFloat = 340
  static let inset: CGFloat = 12
  static var contentWidth: CGFloat { width - inset * 2 }

  static func label(_ text: String, size: CGFloat = 11, weight: NSFont.Weight = .regular,
                    color: NSColor = .secondaryLabelColor, align: NSTextAlignment = .left) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.alignment = align
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }

  static func wrappingLabel(_ text: String, size: CGFloat = 11, color: NSColor = .secondaryLabelColor) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size)
    label.textColor = color
    label.preferredMaxLayoutWidth = contentWidth
    // A fixed width gives the label a deterministic height, so the popover sizes exactly to its content.
    label.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    return label
  }

  static func value(_ text: String = "", width: CGFloat = 46) -> NSTextField {
    let label = self.label(text, size: 11, color: .labelColor, align: .right)
    label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    label.widthAnchor.constraint(equalToConstant: width).isActive = true
    return label
  }

  static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    return stack
  }

  static func column(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    return stack
  }

  /// Makes a stack fill the popover's content width.
  @discardableResult
  static func fill(_ view: NSView) -> NSView {
    view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    return view
  }

  static func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.init(1), for: .horizontal)
    view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    return view
  }

  static func slider(_ value: Double, _ range: ClosedRange<Double>, handler: @escaping (Double) -> Void) -> NSSlider {
    let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
    slider.controlSize = .small
    slider.isContinuous = true
    slider.onAction { [weak slider] in if let slider { handler(slider.doubleValue) } }
    slider.setContentHuggingPriority(.init(1), for: .horizontal)
    return slider
  }

  static func verticalSlider(_ value: Double, _ range: ClosedRange<Double>, height: CGFloat,
                             handler: @escaping (Double) -> Void) -> NSSlider {
    let slider = self.slider(value, range, handler: handler)
    slider.isVertical = true
    slider.translatesAutoresizingMaskIntoConstraints = false
    slider.heightAnchor.constraint(equalToConstant: height).isActive = true
    slider.widthAnchor.constraint(equalToConstant: 20).isActive = true
    return slider
  }

  static func popup(_ items: [String], selected: Int, handler: @escaping (Int) -> Void) -> NSPopUpButton {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.controlSize = .small
    popup.font = .systemFont(ofSize: 11)
    popup.addItems(withTitles: items)
    if selected >= 0 && selected < items.count { popup.selectItem(at: selected) }
    popup.onAction { [weak popup] in if let popup { handler(popup.indexOfSelectedItem) } }
    return popup
  }

  static func segmented(_ labels: [String], selected: Int, handler: @escaping (Int) -> Void) -> NSSegmentedControl {
    let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
    control.controlSize = .small
    control.font = .systemFont(ofSize: 11)
    control.selectedSegment = selected
    control.onAction { [weak control] in if let control { handler(control.selectedSegment) } }
    return control
  }

  static func checkbox(_ title: String, on: Bool, handler: @escaping (Bool) -> Void) -> NSButton {
    let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
    box.controlSize = .small
    box.font = .systemFont(ofSize: 11)
    box.state = on ? .on : .off
    box.onAction { [weak box] in if let box { handler(box.state == .on) } }
    return box
  }

  static func toggle(_ on: Bool, handler: @escaping (Bool) -> Void) -> NSSwitch {
    let toggle = NSSwitch()
    toggle.controlSize = .mini
    toggle.state = on ? .on : .off
    toggle.onAction { [weak toggle] in if let toggle { handler(toggle.state == .on) } }
    return toggle
  }

  static func button(_ title: String, handler: @escaping () -> Void) -> NSButton {
    let button = NSButton(title: title, target: nil, action: nil)
    button.controlSize = .small
    button.bezelStyle = .rounded
    button.font = .systemFont(ofSize: 11)
    button.onAction(handler)
    return button
  }

  static func iconButton(_ symbol: String, tooltip: String, size: CGFloat = 13, handler: @escaping () -> Void) -> NSButton {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
      .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) ?? NSImage()
    let button = NSButton(image: image, target: nil, action: nil)
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.toolTip = tooltip
    button.contentTintColor = .secondaryLabelColor
    button.onAction(handler)
    return button
  }

  static func separator() -> NSView {
    let box = NSBox()
    box.boxType = .separator
    return fill(box)
  }

  static func numberField(_ value: Double, range: ClosedRange<Double>, decimals: Int, width: CGFloat,
                          handler: @escaping (Double) -> Void) -> NSTextField {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = decimals
    formatter.minimum = NSNumber(value: range.lowerBound)
    formatter.maximum = NSNumber(value: range.upperBound)
    let field = NSTextField(string: formatter.string(from: NSNumber(value: value)) ?? "")
    field.formatter = formatter
    field.controlSize = .small
    field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    field.alignment = .right
    field.cell?.sendsActionOnEndEditing = true
    field.widthAnchor.constraint(equalToConstant: width).isActive = true
    field.onAction { [weak field] in
      guard let field, let number = formatter.number(from: field.stringValue) else { return }
      handler(min(range.upperBound, max(range.lowerBound, number.doubleValue)))
    }
    return field
  }

  static func formatDB(_ db: Double) -> String {
    String(format: "%@%.1f dB", db > 0.05 ? "+" : "", abs(db) < 0.05 ? 0 : db)
  }

  static func formatHz(_ hz: Double) -> String {
    hz >= 1000 ? String(format: hz >= 10_000 ? "%.0fk" : "%.1fk", hz / 1000) : String(format: "%.0f", hz)
  }
}

/// A tab's view inside the popover.
protocol PanelContent: NSView {
  /// Re-reads the controller's settings into the controls.
  func refresh()
}
