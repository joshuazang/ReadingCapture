import XCTest
import CryptoKit
import AppKit
import SwiftUI
@testable import ReadingCapture

final class CaptureModelTests: XCTestCase {
    @MainActor func testIncomingCapturesKeepCommentAndSelectionAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Vault(directory: directory, key: SymmetricKey(size: .bits256)), model = CaptureModel(store: store)
        model.record("First passage", app: "Skim", bundle: "reader")
        let first = try XCTUnwrap(model.selected)
        model.editComment("Unfinished comment\nwith another line", for: first)
        for i in 0..<30 { model.record("Next passage \(i)", app: "calibre", bundle: "viewer") }
        XCTAssertEqual(model.selected, first)
        XCTAssertEqual(model.comment(for: first), "Unfinished comment\nwith another line")
        XCTAssertEqual(model.clips.count, 31)
        model.select(nil); XCTAssertEqual(model.selected, first)
        let reopened = CaptureModel(store: store)
        XCTAssertEqual(reopened.clips.first(where: { $0.id == first })?.comment, "Unfinished comment\nwith another line")
        XCTAssertEqual(reopened.clips.count, 31)
        let second = try XCTUnwrap(reopened.clips.first(where: { $0.id != first })?.id)
        reopened.select(first); reopened.editComment("Continued", for: first)
        reopened.select(second); XCTAssertEqual(reopened.comment(for: first), "Continued")
        XCTAssertEqual(reopened.comment(for: second), "")
    }
    @MainActor func testFailedCommentWriteRetainsDraftAndNewQuoteForRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Vault(directory: directory, key: SymmetricKey(size: .bits256)), model = CaptureModel(store: store)
        model.record("Original", app: "Skim", bundle: "reader")
        let original = try XCTUnwrap(model.selected)
        let savedDirectory = directory.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: directory, to: savedDirectory)
        defer { try? FileManager.default.removeItem(at: savedDirectory) }
        try Data("blocked".utf8).write(to: directory)
        model.editComment("Keep this draft", for: original)
        model.record("Keep this new quote", app: "Skim", bundle: "reader")
        XCTAssertEqual(model.commentDrafts[original], "Keep this draft")
        XCTAssertEqual(model.pendingQuote, "Keep this new quote")
        XCTAssertEqual(model.selected, original); XCTAssertEqual(model.clips.count, 1)
        XCTAssertFalse(model.flush())
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: savedDirectory, to: directory)
        model.retry()
        XCTAssertFalse(model.hasPending); XCTAssertEqual(model.clips.count, 2)
        XCTAssertEqual(try store.load().first(where: { $0.id == original })?.comment, "Keep this draft")
    }
    @MainActor func testRenderedCommentEditorSurvivesNewCaptureAndWindowReopen() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CaptureModel(store: try Vault(directory: directory, key: SymmetricKey(size: .bits256)))
        model.record("First", app: "Skim", bundle: "reader")
        let id = try XCTUnwrap(model.selected)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: LibraryView(model: model)); window.contentView = hosting
        let delegate = AppDelegate(); delegate.model = model; delegate.window = window; window.delegate = delegate
        window.orderFront(nil)
        model.editComment("Partly typed comment", for: id)
        model.record("Second", app: "calibre", bundle: "viewer")
        try await Task.sleep(nanoseconds: 200_000_000)
        hosting.layoutSubtreeIfNeeded()
        func editors(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors) }
        let editor = try XCTUnwrap(editors(hosting).first(where: { $0.isEditable }))
        XCTAssertEqual(editor.string, "Partly typed comment")
        XCTAssertGreaterThan(editor.bounds.width, 100); XCTAssertGreaterThan(editor.bounds.height, 40)
        window.close(); XCTAssertFalse(window.isVisible)
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(window.isVisible); XCTAssertEqual(model.selected, id)
        window.orderOut(nil)
    }
}
