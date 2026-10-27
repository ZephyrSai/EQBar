import Foundation

/// A parametric EQ profile: what AutoEq publishes per headphone, and what Equalizer APO files contain.
public struct ParametricProfile: Equatable {
  public var preampDB: Double
  public var bands: [EQBand]

  public init(preampDB: Double, bands: [EQBand]) {
    self.preampDB = preampDB
    self.bands = bands
  }
}

/// Parses Equalizer APO / AutoEq "ParametricEQ.txt" text, e.g.
///   Preamp: -6.3 dB
///   Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
public enum ParametricEQParser {
  public static func parse(_ text: String) -> ParametricProfile? {
    var preamp = 0.0
    var bands: [EQBand] = []
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
      guard let head = tokens.first?.lowercased() else { continue }

      if head.hasPrefix("preamp") {
        if let value = tokens.dropFirst().compactMap(Double.init).first { preamp = value }
        continue
      }
      guard head.hasPrefix("filter"), let onIndex = tokens.firstIndex(where: { $0 == "ON" || $0 == "OFF" }),
            onIndex + 1 < tokens.count else { continue }

      let enabled = tokens[onIndex] == "ON"
      let typeCode = tokens[onIndex + 1].uppercased()
      let type: FilterType
      switch typeCode {
      case "PK", "PEQ", "MODAL": type = .peak
      case "LS", "LSC", "LSQ": type = .lowShelf
      case "HS", "HSC", "HSQ": type = .highShelf
      case "LP", "LPQ": type = .lowPass
      case "HP", "HPQ": type = .highPass
      case "BP": type = .bandPass
      case "NO": type = .notch
      default: continue
      }

      func number(after key: String) -> Double? {
        guard let i = tokens.firstIndex(where: { $0.caseInsensitiveCompare(key) == .orderedSame }), i + 1 < tokens.count else {
          return nil
        }
        return Double(tokens[i + 1])
      }
      guard let frequency = number(after: "Fc") else { continue }
      let gain = number(after: "Gain") ?? 0
      let q: Double
      if let explicit = number(after: "Q") {
        q = explicit
      } else if let bandwidth = number(after: "BW") {
        // Bandwidth in octaves → Q.
        let p = pow(2, bandwidth)
        q = sqrt(p) / (p - 1)
      } else {
        q = 0.71
      }
      bands.append(EQBand(type: type, frequency: frequency, gain: gain, q: q, enabled: enabled))
    }
    return bands.isEmpty ? nil : ParametricProfile(preampDB: preamp, bands: bands)
  }

  public static func format(_ profile: ParametricProfile) -> String {
    var lines = [String(format: "Preamp: %.1f dB", profile.preampDB)]
    for (i, band) in profile.bands.enumerated() {
      let code: String
      switch band.type {
      case .peak: code = "PK"
      case .lowShelf: code = "LSC"
      case .highShelf: code = "HSC"
      case .lowPass: code = "LPQ"
      case .highPass: code = "HPQ"
      case .bandPass: code = "BP"
      case .notch: code = "NO"
      }
      lines.append(String(format: "Filter %d: %@ %@ Fc %.0f Hz Gain %.1f dB Q %.2f",
                          i + 1, band.enabled ? "ON" : "OFF", code, band.frequency, band.gain, band.q))
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

/// One headphone measurement in the AutoEq database.
public struct AutoEQEntry: Hashable {
  public let name: String
  public let source: String
  /// Percent-encoded path below `results/`, e.g. `oratory1990/over-ear/Sennheiser%20HD%20600`.
  public let path: String

  public var searchKey: String { name.lowercased() }
}

/// Searches Jaakko Pasanen's AutoEq database (github.com/jaakkopasanen/AutoEq, MIT) and downloads
/// headphone correction profiles. Nothing is fetched until the user opens the search.
public final class AutoEQService {
  public static let shared = AutoEQService()

  private let base = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/")!
  private let session: URLSession
  private let cacheURL: URL
  private let maxCacheAge: TimeInterval = 7 * 24 * 3600

  public init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 20
    config.urlCache = nil                      // the index is cached on disk by us; don't keep a copy in RAM
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: config)
    cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("EQBar", isDirectory: true)
      .appendingPathComponent("autoeq-index.md")
  }

  /// The index (~9,000 entries), from a week-old-at-most disk cache or the network.
  public func loadIndex(forceRefresh: Bool = false, completion: @escaping (Result<[AutoEQEntry], Error>) -> Void) {
    let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)
    let age = (attributes?[.modificationDate] as? Date).map { Date().timeIntervalSince($0) } ?? .infinity
    if !forceRefresh, age < maxCacheAge, let text = try? String(contentsOf: cacheURL, encoding: .utf8) {
      let entries = Self.parseIndex(text)
      if !entries.isEmpty { return DispatchQueue.main.async { completion(.success(entries)) } }
    }
    let cached = cacheURL
    session.dataTask(with: base.appendingPathComponent("INDEX.md")) { data, response, error in
      let result: Result<[AutoEQEntry], Error>
      if let data, let text = String(data: data, encoding: .utf8), (response as? HTTPURLResponse)?.statusCode == 200 {
        try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cached, options: .atomic)
        result = .success(Self.parseIndex(text))
      } else if let text = try? String(contentsOf: cached, encoding: .utf8) {
        result = .success(Self.parseIndex(text))   // offline: fall back to a stale cache
      } else {
        result = .failure(error ?? URLError(.badServerResponse))
      }
      DispatchQueue.main.async { completion(result) }
    }.resume()
  }

  /// Lines look like: `- [Sennheiser HD 600](./oratory1990/over-ear/Sennheiser%20HD%20600) by oratory1990`
  public static func parseIndex(_ text: String) -> [AutoEQEntry] {
    var entries: [AutoEQEntry] = []
    entries.reserveCapacity(9000)
    for line in text.split(separator: "\n") where line.hasPrefix("- [") {
      guard let close = line.range(of: "](./", options: .backwards),
            let end = line.range(of: ")", range: close.upperBound..<line.endIndex) else { continue }
      let name = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
      let path = String(line[close.upperBound..<end.lowerBound])
      let tail = line[end.upperBound...]
      let source = tail.hasPrefix(" by ") ? String(tail.dropFirst(4)) : ""
      entries.append(AutoEQEntry(name: name, source: source, path: path))
    }
    return entries
  }

  /// Every query word must appear; names that start with the query rank first.
  public static func search(_ query: String, in entries: [AutoEQEntry], limit: Int = 200) -> [AutoEQEntry] {
    let words = query.lowercased().split(separator: " ").map(String.init)
    guard !words.isEmpty else { return [] }
    let q = query.lowercased()
    var prefix: [AutoEQEntry] = [], rest: [AutoEQEntry] = []
    for entry in entries {
      let key = entry.searchKey
      guard words.allSatisfy({ key.contains($0) }) else { continue }
      if key.hasPrefix(q) { prefix.append(entry) } else { rest.append(entry) }
      if prefix.count >= limit { break }
    }
    return Array((prefix + rest).prefix(limit))
  }

  public func fetchProfile(_ entry: AutoEQEntry, completion: @escaping (Result<ParametricProfile, Error>) -> Void) {
    let folder = entry.path.split(separator: "/").last.map(String.init) ?? ""
    guard let url = URL(string: base.absoluteString + entry.path + "/" + folder + "%20ParametricEQ.txt") else {
      return completion(.failure(URLError(.badURL)))
    }
    session.dataTask(with: url) { data, response, error in
      let result: Result<ParametricProfile, Error>
      if let data, (response as? HTTPURLResponse)?.statusCode == 200,
         let text = String(data: data, encoding: .utf8), let profile = ParametricEQParser.parse(text) {
        result = .success(profile)
      } else {
        result = .failure(error ?? URLError(.cannotParseResponse))
      }
      DispatchQueue.main.async { completion(result) }
    }.resume()
  }
}
