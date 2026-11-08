import XCTest
import CryptoKit
import AppKit
@testable import ReadingCapture

final class NativeHighlightsTests: XCTestCase {
    func testCalibreBooksAndHighlightsAreAttributedWithoutClipboard() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("viewer/annots"), withIntermediateDirectories: true)
        let books: [[String: String]] = [["pathtoebook": "/Books/one.epub", "title": "First Book"], ["pathtoebook": "/Books/two.epub", "title": "Second Book"]]
        try JSONSerialization.data(withJSONObject: ["session_data": ["standalone_recently_opened": books]]).write(to: folder.appendingPathComponent("viewer-webengine.json"))
        for book in books {
            let hash = SHA256.hash(data: Data(book["pathtoebook"]!.utf8)).map { String(format: "%02x", $0) }.joined()
            let rows: [[String: Any]] = [["type":"highlight","uuid":"same-id","highlighted_text":"  Exact quote\r\n🙂", "timestamp":"2026-11-08T10:00:00.123456+00:00"], ["type":"highlight","uuid":"deleted","highlighted_text":"Do not import", "removed":true], ["type":"bookmark","uuid":"bookmark","highlighted_text":"Not a highlight"]]
            try JSONSerialization.data(withJSONObject: rows).write(to: folder.appendingPathComponent("viewer/annots/" + hash + ".json"))
        }
        let probe = ReaderProbe(), result = try await probe.calibre(folder: folder, known: [])
        XCTAssertEqual(Set(result.1.map(\.book)), ["First Book", "Second Book"])
        XCTAssertEqual(result.1.count, 2); XCTAssertNotEqual(result.1[0].key, result.1[1].key)
        XCTAssertTrue(result.1.allSatisfy { $0.text == "  Exact quote\r\n🙂" && $0.modified != nil && $0.historicalAtConnection })
        let repeated = try await probe.calibre(folder: folder, known: Set(result.1.map(\.key))); XCTAssertTrue(repeated.1.isEmpty)
        let bad = folder.appendingPathComponent("viewer-webengine.json")
        try Data("{".utf8).write(to: bad)
        do { _ = try await probe.calibre(folder: folder, known: []); XCTFail("Partial JSON must be rejected") } catch {}
    }
    @MainActor func testSkimScriptsCompileAgainstInstalledReader() async throws {
        guard FileManager.default.fileExists(atPath: "/Applications/Skim.app") else { throw XCTSkip("Skim dictionary is not installed on this machine") }
        for source in [ReaderProbe.skimHeaderScript, ReaderProbe.skimDetailScript(path: "/tmp/quote\"book.pdf", ids: ["sample-id"])] {
            let script = try XCTUnwrap(NSAppleScript(source: source)); var issue: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&issue), "\(issue ?? [:])")
        }
    }
    func testSkimDescriptorDecodingAndScriptStringSafety() throws {
        let header = NSAppleEventDescriptor.list(), ids = NSAppleEventDescriptor.list()
        ids.insert(NSAppleEventDescriptor(string: "note-1"), at: 1)
        header.insert(NSAppleEventDescriptor(string: "My PDF"), at: 1)
        header.insert(NSAppleEventDescriptor(string: "/Books/book.pdf"), at: 2); header.insert(ids, at: 3)
        let parsed = try XCTUnwrap(ReaderProbe.skimHeader(header)); XCTAssertEqual(parsed.0, "My PDF"); XCTAssertEqual(parsed.2, ["note-1"])
        let rows = NSAppleEventDescriptor.list(), row = NSAppleEventDescriptor.list()
        row.insert(NSAppleEventDescriptor(string: "note-1"), at: 1); row.insert(NSAppleEventDescriptor(string: "Exact\nquote"), at: 2)
        row.insert(NSAppleEventDescriptor(date: Date()), at: 3); rows.insert(row, at: 1)
        let annotation = try XCTUnwrap(ReaderProbe.skimRows(rows, bookPath: parsed.1, title: parsed.0).first)
        XCTAssertEqual(annotation.text, "Exact\nquote"); XCTAssertEqual(annotation.book, "My PDF"); XCTAssertNotNil(annotation.modified)
        XCTAssertEqual(ReaderProbe.appleString("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }
    @MainActor func testNewHighlightDoesNotReplaceKeyCommentPanel() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = CaptureModel(store: try Vault(directory: folder, key: SymmetricKey(size: .bits256)))
        model.record("First", app: "Skim", bundle: "reader")
        let first = try XCTUnwrap(model.clips.first)
        model.editComment("Still typing", for: first.id)
        model.record("Second", app: "calibre", bundle: "viewer")
        let second = try XCTUnwrap(model.clips.first)
        let delegate = AppDelegate(); delegate.model = model
        NSApp.activate(ignoringOtherApps: true)
        delegate.showComment(first)
        let panel = try XCTUnwrap(delegate.commentPanel)
        panel.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(panel.isKeyWindow)
        let originalContent = panel.contentView
        delegate.showComment(second)
        XCTAssertTrue(panel.contentView === originalContent)
        XCTAssertEqual(model.comment(for: first.id), "Still typing")
        panel.orderOut(nil)
    }
    @MainActor func testNativeCaptureDeduplicatesAcrossReopenAndKeepsComment() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try Vault(directory: folder, key: SymmetricKey(size: .bits256)), model = CaptureModel(store: store)
        let first = ReaderHighlight(key: ReaderHighlight.identity(reader: "skim", book: "one", id: "1"), text: "First highlight", book: "Automatic PDF Title", modified: nil)
        let second = ReaderHighlight(key: ReaderHighlight.identity(reader: "calibre", book: "two", id: "2"), text: "Second highlight", book: "Automatic EPUB Title", modified: nil)
        var popups: [String] = []; model.captured = { popups.append($0.quote) }
        XCTAssertTrue(model.recordAnnotation(first, app: "Skim", bundle: "reader", notify: false))
        let selected = try XCTUnwrap(model.selected); model.editComment("My own comment", for: selected)
        XCTAssertTrue(model.recordAnnotation(second, app: "calibre", bundle: "viewer", notify: true))
        XCTAssertEqual(popups, ["Second highlight"]); XCTAssertEqual(model.comment(for: selected), "My own comment")
        XCTAssertEqual(model.clips.first?.book, "Automatic EPUB Title")
        let reopened = CaptureModel(store: store)
        XCTAssertTrue(reopened.recordAnnotation(first, app: "Skim", bundle: "reader", notify: true))
        XCTAssertEqual(reopened.clips.count, 2)
        XCTAssertEqual(try Exchange.decode(Exchange.archive(reopened.clips)).first?.annotationKey, reopened.clips.first?.annotationKey)
    }
}
