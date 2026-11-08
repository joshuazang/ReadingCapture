import AppKit
import CryptoKit

struct ReaderHighlight: Equatable {
    let key: String
    let text: String
    let book: String
    let modified: Date?
    var historicalAtConnection = false
    static func identity(reader: String, book: String, id: String) -> String {
        SHA256.hash(data: Data((reader + "\u{0}" + book + "\u{0}" + id).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One serial worker owns this probe. It never writes a reader's files.
final class ReaderProbe {
    private struct CachedFile { let date: Date?; let size: Int; let rows: [[String: Any]] }
    private var files: [String: CachedFile] = [:]
    private var baselines: [String: Set<String>] = [:]
    func resetConnection() { baselines.removeAll() }
    static let skimBundle = "net.sourceforge.skim-app.skim"
    static func isCalibre(bundle: String, name: String) -> Bool {
        bundle.lowercased().contains("calibre") || ["ebook-viewer", "e-book viewer", "ebook viewer"].contains(name.lowercased())
    }
    static func readJSON(_ url: URL, limit: Int = 16_000_000) throws -> Any {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= limit else { throw CaptureError.invalid("Reader metadata is missing or too large.") }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw CaptureError.invalid("Reader metadata is too large.") }
        return try JSONSerialization.jsonObject(with: data)
    }
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    func calibre(folder: URL, known: Set<String>) throws -> (String, [ReaderHighlight]) {
        guard let config = try Self.readJSON(folder.appendingPathComponent("viewer-webengine.json")) as? [String: Any],
              let session = config["session_data"] as? [String: Any],
              let recent = session["standalone_recently_opened"] as? [[String: Any]] else {
            throw CaptureError.invalid("Calibre book metadata is unavailable. Open a book, or choose the calibre settings folder.")
        }
        var highlights: [ReaderHighlight] = [], latestTitle = ""
        var activeURLs: Set<String> = []
        for entry in recent.prefix(25) {
            guard let path = entry["pathtoebook"] as? String, !path.isEmpty,
                  let title = entry["title"] as? String, !title.isEmpty, title.utf8.count <= 4096 else { continue }
            let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
            let url = folder.appendingPathComponent("viewer/annots").appendingPathComponent(hash + ".json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let cacheKey = url.path; activeURLs.insert(cacheKey)
            let info = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let rows: [[String: Any]]
            if let old = files[cacheKey], old.date == info.contentModificationDate, old.size == info.fileSize { rows = old.rows }
            else {
                guard let parsed = try Self.readJSON(url) as? [[String: Any]], parsed.count <= 20_000 else { throw CaptureError.invalid("Calibre annotations are not yet readable; waiting for a complete file.") }
                rows = parsed
                files[cacheKey] = CachedFile(date: info.contentModificationDate, size: info.fileSize ?? 0, rows: parsed)
            }
            if latestTitle.isEmpty { latestTitle = title }
            let items = Self.calibreRows(rows, bookPath: path, title: title)
            let group = "calibre:" + path
            if baselines[group] == nil { baselines[group] = Set(items.map(\.key)) }
            highlights += items.filter { !known.contains($0.key) }.map { item in var item = item; item.historicalAtConnection = baselines[group]?.contains(item.key) == true; return item }
        }
        files = files.filter { activeURLs.contains($0.key) }
        return (latestTitle, highlights)
    }
    static func calibreRows(_ rows: [[String: Any]], bookPath: String, title: String) -> [ReaderHighlight] {
        rows.compactMap { row in
            guard row["type"] as? String == "highlight", row["removed"] as? Bool != true, row["deleted"] as? Bool != true,
                  let id = row["uuid"] as? String, !id.isEmpty, id.utf8.count <= 4096,
                  let text = row["highlighted_text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1_000_000 else { return nil }
            return ReaderHighlight(key: ReaderHighlight.identity(reader: "calibre", book: bookPath, id: id), text: text, book: title, modified: Self.date(row["timestamp"] as? String))
        }
    }
    static func appleString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func execute(_ source: String) throws -> NSAppleEventDescriptor {
        if !Thread.isMainThread { return try DispatchQueue.main.sync { try execute(source) } }
        guard let script = NSAppleScript(source: source) else { throw CaptureError.invalid("Could not prepare Skim's read-only script.") }
        var problem: NSDictionary?
        let result = script.executeAndReturnError(&problem)
        if let problem {
            let code = (problem[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
            let text = code == -1743 ? "Skim access was denied. Allow Reading Capture under System Settings → Privacy & Security → Automation, then restart capture." : "Skim did not return highlights: \(problem[NSAppleScript.errorMessage] as? String ?? "reader unavailable")"
            throw NSError(domain: "ReadingCapture.Skim", code: code, userInfo: [NSLocalizedDescriptionKey: text])
        }
        return result
    }
    static let skimHeaderScript = """
    with timeout of 5 seconds
      tell application id "net.sourceforge.skim-app.skim"
        if (count of documents) is 0 then return {}
        set d to front document
        set bookName to name of d as text
        set bookPath to path of d as text
        set noteIDs to (id of every note of d whose type is highlight note)
        return {bookName, bookPath, noteIDs}
      end tell
    end timeout
    """
    static func skimHeader(_ value: NSAppleEventDescriptor) throws -> (String, String, [String])? {
        if value.numberOfItems == 0 { return nil }
        guard value.numberOfItems == 3, let title = value.atIndex(1)?.stringValue, let path = value.atIndex(2)?.stringValue,
              !title.isEmpty, title.utf8.count <= 4096, !path.isEmpty, let ids = value.atIndex(3), ids.numberOfItems <= 50_000 else { throw CaptureError.invalid("Unsupported Skim document metadata.") }
        let list = (0..<ids.numberOfItems).compactMap { ids.atIndex($0 + 1)?.stringValue }.filter { !$0.isEmpty && $0.utf8.count <= 4096 }
        return (title, path, list)
    }
    func skim(known: Set<String>) throws -> (String, [ReaderHighlight]) {
        guard let (title, path, ids) = try Self.skimHeader(Self.execute(Self.skimHeaderScript)) else { return ("", []) }
        let group = "skim:" + path
        if baselines[group] == nil { baselines[group] = Set(ids.map { ReaderHighlight.identity(reader: "skim", book: path, id: $0) }) }
        let missing = ids.filter { !known.contains(ReaderHighlight.identity(reader: "skim", book: path, id: $0)) }.prefix(20)
        if missing.isEmpty { return (title, []) }
        return (title, Self.skimRows(try Self.execute(Self.skimDetailScript(path: path, ids: Array(missing))), bookPath: path, title: title).map { item in var item = item; item.historicalAtConnection = baselines[group]?.contains(item.key) == true; return item })
    }
    static func skimDetailScript(path: String, ids: [String]) -> String {
        let missing = ids
        return """
        with timeout of 10 seconds
          tell application id "net.sourceforge.skim-app.skim"
            if (count of documents) is 0 then return {}
            set d to front document
            if (path of d as text) is not \(Self.appleString(path)) then return {}
            set resultRows to {}
            repeat with noteID in {\(missing.map(Self.appleString).joined(separator: ","))}
              set n to note id (contents of noteID) of d
              try
                set excerpt to (obtain text for (selection of n)) as text
              on error
                set excerpt to text of n as text
              end try
              set changedAt to missing value
              try
                set changedAt to modification date of n
              end try
              set end of resultRows to {contents of noteID, excerpt, changedAt}
            end repeat
            return resultRows
          end tell
        end timeout
        """
    }
    static func skimRows(_ rows: NSAppleEventDescriptor, bookPath: String, title: String) -> [ReaderHighlight] {
        (0..<rows.numberOfItems).compactMap { index in
            guard let row = rows.atIndex(index + 1), let id = row.atIndex(1)?.stringValue,
                  let text = row.atIndex(2)?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1_000_000 else { return nil }
            return ReaderHighlight(key: ReaderHighlight.identity(reader: "skim", book: bookPath, id: id), text: text, book: title, modified: row.atIndex(3)?.dateValue)
        }
    }
}

@MainActor final class NativeHighlightMonitor {
    var allowed: Set<String> = []
    var known: Set<String> = []
    var folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/calibre")
    var receive: ((ReaderHighlight, String, String, Bool) -> Bool)?
    var status: ((String) -> Void)?
    var failed: ((Error) -> Void)?
    private let queue = DispatchQueue(label: "ReadingCapture.Reader", qos: .utility)
    private let probe = ReaderProbe()
    private var timer: Timer?
    private var generation = 0
    private var busy = false
    private var started = Date()
    func start() {
        stop(); started = Date(); let worker = probe; queue.async { worker.resetConnection() }
        status?("Switch to an allowed Skim or calibre viewer to connect.")
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        timer?.tolerance = 0.1
    }
    func stop() { timer?.invalidate(); timer = nil; generation += 1; busy = false }
    private func poll() {
        guard timer != nil, !busy, let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier, allowed.contains(bundle) else { return }
        let name = app.localizedName ?? "Reader", skim = bundle == ReaderProbe.skimBundle
        guard skim || ReaderProbe.isCalibre(bundle: bundle, name: name) else { status?("Native highlights support Skim and calibre; use Clipboard mode for other readers."); return }
        busy = true
        let token = generation, keys = known, directory = folder, worker = probe
        queue.async {
            let result = Result { try skim ? worker.skim(known: keys) : worker.calibre(folder: directory, known: keys) }
            Task { @MainActor [weak self] in
                guard let self, token == self.generation, self.timer != nil else { return }
                self.busy = false
                switch result {
                case .failure(let error): self.failed?(error)
                case .success(let (book, highlights)):
                    for annotation in highlights {
                        let fresh = annotation.modified.map { $0 >= self.started.addingTimeInterval(-1) } ?? !annotation.historicalAtConnection
                        guard self.receive?(annotation, name, bundle, fresh) == true else { return }
                    }
                    self.status?(book.isEmpty ? "Open a book in the reader." : "Connected · " + book)
                }
            }
        }
    }
}
