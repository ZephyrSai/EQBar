import AppKit
import EQBarCore

/// Live spectrum of the processed output with the EQ curve drawn on top.
/// The analyzer only runs (and the audio thread only feeds it) while this view is on screen.
final class SpectrumView: NSView {
  private let controller: EQBarController
  private let showsSpectrum: Bool
  private var analyzer: SpectrumAnalyzer?
  private var timer: Timer?
  private var lastWritten: Int64 = -1
  private let curveFrequencies = EQMath.logFrequencies(count: 140)
  private var curve: [Double] = []
  private var handles: [(frequency: Double, gain: Double)] = []
  private let rangeDB = 15.0

  init(controller: EQBarController, showsSpectrum: Bool, height: CGFloat) {
    self.controller = controller
    self.showsSpectrum = showsSpectrum
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: height).isActive = true
    widthAnchor.constraint(equalToConstant: UI.contentWidth).isActive = true
    refreshCurve()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window == nil ? stop() : start()
  }

  private func start() {
    guard showsSpectrum, timer == nil else { return }
    analyzer = SpectrumAnalyzer()
    controller.analyzerActive = true
    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func stop() {
    timer?.invalidate()
    timer = nil
    analyzer = nil
    if showsSpectrum { controller.analyzerActive = false }
  }

  private func tick() {
    guard let analyzer else { return }
    if let ring = controller.analyzerRing, ring.totalWritten != lastWritten {
      lastWritten = ring.totalWritten
      if !analyzer.update(from: ring, sampleRate: controller.sampleRate) { analyzer.decay() }
    } else {
      analyzer.decay()
    }
    needsDisplay = true
  }

  func refreshCurve() {
    curve = controller.eqResponse(at: curveFrequencies)
    let eq = controller.settings.eq
    handles = eq.mode == .expert ? eq.expert.filter(\.enabled).map { ($0.frequency, $0.type.usesGain ? $0.gain : 0) } : []
    needsDisplay = true
  }

  private func x(_ frequency: Double) -> CGFloat {
    CGFloat(log(frequency / 20) / log(1000)) * bounds.width
  }

  private func y(_ db: Double) -> CGFloat {
    let clamped = max(-rangeDB, min(rangeDB, db))
    return bounds.midY + CGFloat(clamped / rangeDB) * (bounds.height / 2 - 6)
  }

  override func draw(_ dirtyRect: NSRect) {
    let background = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
    NSColor.black.withAlphaComponent(0.18).setFill()
    background.fill()
    background.addClip()

    // Grid.
    NSColor.white.withAlphaComponent(0.07).setFill()
    for f in [100.0, 1000, 10_000] { NSRect(x: x(f), y: 0, width: 1, height: bounds.height).fill() }
    NSRect(x: 0, y: y(0), width: bounds.width, height: 1).fill()
    let labelAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.tertiaryLabelColor
    ]
    for (f, text) in [(100.0, "100"), (1000, "1k"), (10_000, "10k")] {
      NSAttributedString(string: text, attributes: labelAttributes).draw(at: NSPoint(x: x(f) + 2, y: 2))
    }

    // Spectrum bars.
    if let levels = analyzer?.levels, !levels.isEmpty {
      let barWidth = bounds.width / CGFloat(levels.count)
      NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
      for (i, level) in levels.enumerated() {
        let height = CGFloat((Double(level) + 90) / 90) * bounds.height
        guard height > 0.5 else { continue }
        NSRect(x: CGFloat(i) * barWidth + 0.5, y: 0, width: max(1, barWidth - 1), height: height).fill()
      }
    }

    // EQ curve.
    guard !curve.isEmpty else { return }
    let path = NSBezierPath()
    for (i, f) in curveFrequencies.enumerated() {
      let point = NSPoint(x: x(f), y: y(curve[i]))
      i == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.lineWidth = 1.5
    (controller.settings.eq.enabled ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
    path.stroke()

    NSColor.labelColor.withAlphaComponent(0.8).setFill()
    for handle in handles {
      NSBezierPath(ovalIn: NSRect(x: x(handle.frequency) - 2.5, y: y(handle.gain) - 2.5, width: 5, height: 5)).fill()
    }
  }
}
