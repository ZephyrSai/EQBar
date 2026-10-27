import AppKit
import EQBarCore

/// Search the AutoEq database and apply a headphone correction profile with one click.
final class AutoEQPanel: NSStackView, PanelContent, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  private let controller: EQBarController
  private let close: () -> Void
  private let layoutChanged: () -> Void

  private var searchField: NSSearchField!
  private var table: NSTableView!
  private var statusLabel: NSTextField!
  private var applyButton: NSButton!
  private var entries: [AutoEQEntry] = []
  private var results: [AutoEQEntry] = []
  private var applying = false

  init(controller: EQBarController, close: @escaping () -> Void, layoutChanged: @escaping () -> Void) {
    self.controller = controller
    self.close = close
    self.layoutChanged = layoutChanged
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 8
    build()
    loadIndex(force: false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func refresh() {}

  private func build() {
    let back = UI.iconButton("chevron.left", tooltip: "Back") { [weak self] in self?.close() }
    let refreshButton = UI.iconButton("arrow.clockwise", tooltip: "Refresh the database", size: 11) { [weak self] in
      self?.loadIndex(force: true)
    }
    addArrangedSubview(UI.fill(UI.row([back, UI.label("Headphone Profiles (AutoEQ)", weight: .medium, color: .labelColor),
                                       UI.spacer(), refreshButton])))

    searchField = NSSearchField()
    searchField.placeholderString = "Search headphones, e.g. HD 600, AirPods Pro"
    searchField.controlSize = .small
    searchField.font = .systemFont(ofSize: 11)
    searchField.delegate = self
    searchField.sendsSearchStringImmediately = true
    addArrangedSubview(UI.fill(searchField))

    table = NSTableView()
    table.headerView = nil
    table.rowHeight = 30
    table.intercellSpacing = NSSize(width: 0, height: 2)
    table.style = .plain
    table.usesAlternatingRowBackgroundColors = false
    let column = NSTableColumn(identifier: .init("entry"))
    column.width = UI.contentWidth - 20
    table.addTableColumn(column)
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(applySelected)
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true
    UI.fill(scroll)
    addArrangedSubview(scroll)

    statusLabel = UI.label("Loading database…", size: 10)
    applyButton = UI.button("Apply") { [weak self] in self?.applySelected() }
    applyButton.keyEquivalent = "\r"
    applyButton.isEnabled = false
    addArrangedSubview(UI.fill(UI.row([statusLabel, UI.spacer(), applyButton])))
    addArrangedSubview(UI.wrappingLabel("Profiles come from the AutoEq project by Jaakko Pasanen (MIT). They correct each headphone towards a neutral target and are applied as an Expert EQ preset you can tweak.", size: 10, color: .tertiaryLabelColor))
  }

  /// Memory tests can turn this off to measure the cost of the text input system separately.
  static var focusSearchOnShow = true

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil && Self.focusSearchOnShow { window?.makeFirstResponder(searchField) }
  }

  private func loadIndex(force: Bool) {
    statusLabel.stringValue = "Loading database…"
    AutoEQService.shared.loadIndex(forceRefresh: force) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let entries):
        self.entries = entries
        self.statusLabel.stringValue = "\(entries.count.formatted()) profiles"
        self.search()
      case .failure(let error):
        self.statusLabel.stringValue = "Couldn't load the database: \(error.localizedDescription)"
      }
    }
  }

  func controlTextDidChange(_ notification: Notification) { search() }

  private func search() {
    let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
    results = query.isEmpty ? [] : AutoEQService.search(query, in: entries)
    table.reloadData()
    applyButton.isEnabled = false
    if !entries.isEmpty {
      statusLabel.stringValue = query.isEmpty ? "\(entries.count.formatted()) profiles"
        : "\(results.count == 200 ? "200+" : "\(results.count)") matches"
    }
  }

  // MARK: Table

  func numberOfRows(in tableView: NSTableView) -> Int { results.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let entry = results[row]
    let cell = tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? EntryCell ?? EntryCell()
    cell.identifier = .init("cell")
    cell.title.stringValue = entry.name
    cell.subtitle.stringValue = entry.source.isEmpty ? "" : "Measured by \(entry.source)"
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    applyButton.isEnabled = table.selectedRow >= 0 && !applying
  }

  @objc private func applySelected() {
    let row = table.selectedRow >= 0 ? table.selectedRow : table.clickedRow
    guard results.indices.contains(row), !applying else { return }
    let entry = results[row]
    applying = true
    applyButton.isEnabled = false
    statusLabel.stringValue = "Downloading \(entry.name)…"
    AutoEQService.shared.fetchProfile(entry) { [weak self] result in
      guard let self else { return }
      self.applying = false
      switch result {
      case .success(let profile):
        self.controller.applyProfile(profile, name: entry.name)
        self.close()
      case .failure(let error):
        self.statusLabel.stringValue = "Download failed: \(error.localizedDescription)"
        self.applyButton.isEnabled = true
      }
    }
  }
}

private final class EntryCell: NSTableCellView {
  let title = UI.label("", size: 12, color: .labelColor)
  let subtitle = UI.label("", size: 10)

  init() {
    super.init(frame: .zero)
    let stack = UI.column([title, subtitle], spacing: 0)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor)
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
