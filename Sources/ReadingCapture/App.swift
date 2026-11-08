import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class CaptureModel: ObservableObject {
    @Published var clips: [Clipping] = []
    @Published var selected: String?
    @Published var comment = ""
    @Published var book = ""
    @Published var recording = false
    @Published var error: String?
    @Published var allowed: [String: String] = UserDefaults.standard.dictionary(forKey: "readingApps") as? [String: String] ?? [:]
    let monitor = ClipboardMonitor()
    private var vault: Vault?
    private var pending: Clipping?
    var changed: (() -> Void)?
    init() {
        do { let store = try Vault.open(); clips = try store.load(); vault = store }
        catch { self.error = "Library could not be opened. Existing files are untouched. \(error.localizedDescription)" }
        monitor.receive = { [weak self] text, app in self?.capture(text, app: app) }
    }
    var current: Clipping? { clips.first { $0.id == selected } }
    @discardableResult func flush() -> Bool {
        guard var clip = current, clip.comment != comment else { return true }
        clip.comment = comment
        do { guard let vault else { return false }; try vault.save(clip); if let i = clips.firstIndex(where: { $0.id == clip.id }) { clips[i] = clip }; return true }
        catch { self.error = "Comment is still in this window. Saving failed: \(error.localizedDescription)"; return false }
    }
    func select(_ id: String?) { guard flush() else { return }; selected = id; comment = current?.comment ?? "" }
    func toggle() {
        if recording { pause(); return }
        guard vault != nil, pending == nil else { error = "Resolve the library or pending-save error before starting capture."; return }
        guard !allowed.isEmpty else { error = "Choose your Skim or calibre viewer application first."; return }
        monitor.allowed = Set(allowed.keys); monitor.start(); recording = true; changed?()
    }
    func pause() { monitor.stop(); recording = false; changed?() }
    func addReader() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.message = "Choose Skim or the calibre viewer application. Only chosen apps can supply captures."
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        allowed[id] = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
        UserDefaults.standard.set(allowed, forKey: "readingApps"); monitor.allowed = Set(allowed.keys)
    }
    func allowRunning(_ app: NSRunningApplication) { guard let id = app.bundleIdentifier else { return }; allowed[id] = app.localizedName ?? id; UserDefaults.standard.set(allowed, forKey: "readingApps"); monitor.allowed = Set(allowed.keys) }
    func removeReader(_ id: String) { allowed.removeValue(forKey: id); UserDefaults.standard.set(allowed, forKey: "readingApps"); monitor.allowed = Set(allowed.keys); if allowed.isEmpty { pause() } }
    private func capture(_ text: String, app: NSRunningApplication) {
        do { let clip = try Clipping.make(quote: text, book: book, app: app.localizedName ?? "Reader", bundle: app.bundleIdentifier ?? ""); pending = clip; retry() }
        catch { pause(); self.error = error.localizedDescription }
    }
    func retry() {
        guard let clip = pending, let vault else { return }
        do { try vault.save(clip); clips.insert(clip, at: 0); pending = nil; error = nil; if selected == nil { selected = clip.id; comment = clip.comment }; changed?() }
        catch { pause(); self.error = "Capture paused. The copied text is retained in memory; keep this app open and retry. \(error.localizedDescription)" }
    }
    var hasPending: Bool { pending != nil }
    var pendingQuote: String { pending?.quote ?? "" }
    func discardPending() { let alert = NSAlert(); alert.messageText = "Discard the unsaved capture?"; alert.informativeText = "This removes the pending copy from memory. Saved captures are kept."; alert.addButton(withTitle: "Keep capture"); alert.addButton(withTitle: "Discard"); if alert.runModal() == .alertSecondButtonReturn { pending = nil; error = nil } }
    func export(_ native: Bool) {
        guard flush() else { return }
        guard !clips.isEmpty else { error = "There are no captures to export."; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = native ? "Reading captures.json" : "Reading captures.txt"
        panel.message = "This export contains readable, unencrypted quotes and comments. Store it somewhere you trust."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let data = try native ? Exchange.archive(clips) : Exchange.forward(Array(clips.reversed())); try data.write(to: url, options: .atomic) }
        catch { self.error = "Export failed: \(error.localizedDescription)" }
    }
    func importArchive() {
        guard flush(), let vault else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.message = "Import a Reading Capture JSON archive. Existing captures are kept."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var imported = 0
        do {
            let info = try url.resourceValues(forKeys: [.fileSizeKey]); guard (info.fileSize ?? Int.max) <= 32_000_000 else { throw CaptureError.invalid("Archive exceeds 32 MB.") }
            let incoming = try Exchange.decode(Data(contentsOf: url)); var known = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
            for var clip in incoming {
                if let existing = known[clip.id] {
                    if existing == clip { continue }
                    clip.id = try Clipping.make(quote: clip.quote, book: clip.book, app: clip.sourceApp, bundle: clip.sourceBundle).id
                }
                try vault.save(clip); clips.append(clip); known[clip.id] = clip; imported += 1
            }
            clips.sort { $0.capturedAt > $1.capturedAt }; changed?()
        } catch { self.error = "Import stopped after \(imported) captures. Existing captures and successful imports are kept. \(error.localizedDescription)" }
    }
}

struct LibraryView: View {
    @ObservedObject var model: CaptureModel
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(model.recording ? "Pause capture" : "Start capture") { model.toggle() }
                Text("\(model.clips.count) captures").foregroundStyle(.secondary)
                Spacer()
                Menu("Export") { Button("IM / Mosaic — plain text") { model.export(false) }; Button("Backup JSON — plain text") { model.export(true) } }
                Button("Import backup") { model.importArchive() }
            }
            HStack { Text("Book / PDF"); TextField("Optional label for new captures", text: $model.book) }
            HStack {
                Menu("Reading apps (\(model.allowed.count))") {
                    ForEach(model.allowed.keys.sorted(), id: \.self) { id in Button("Remove \(model.allowed[id] ?? id)") { model.removeReader(id) } }
                    Divider(); ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in Button("Allow \(app.localizedName ?? "Reader")") { model.allowRunning(app) } }; Divider(); Button("Add reading app…") { model.addReader() }
                }
                Text("Copy while a chosen reader is active. Capture starts paused.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if let error = model.error {
                HStack { Text(error).foregroundStyle(.red).textSelection(.enabled); if model.hasPending { Button("Retry capture") { model.retry() } } }
            }
            if model.hasPending { ScrollView { Text(model.pendingQuote).textSelection(.enabled) }.frame(maxHeight: 100); Button("Discard pending capture…") { model.discardPending() } }
            HSplitView {
                List(selection: Binding(get: { model.selected }, set: { model.select($0) })) {
                    ForEach(model.clips) { clip in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(clip.quote).lineLimit(3)
                            Text(clip.book.isEmpty ? clip.sourceApp : clip.book).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).tag(clip.id)
                    }
                }.frame(minWidth: 220, idealWidth: 280)
                VStack(alignment: .leading, spacing: 12) {
                    if let clip = model.current {
                        Text(clip.book.isEmpty ? clip.sourceApp : clip.book).font(.headline)
                        Text(clip.capturedAt).font(.caption).foregroundStyle(.secondary)
                        ScrollView { Text(clip.quote).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(minHeight: 100)
                        Text("Comment (optional)").font(.headline)
                        TextEditor(text: $model.comment).frame(minHeight: 100)
                        HStack { Text("Saved when you switch captures or close this window.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Save comment") { _ = model.flush() }.keyboardShortcut(.return, modifiers: .command) }
                    } else { Text("Select a capture. Copying in a chosen reader saves a quote without opening this window.").foregroundStyle(.secondary) }
                }.padding(12).frame(minWidth: 350)
            }
        }.padding(16).frame(minWidth: 760, minHeight: 500)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: CaptureModel!
    var item: NSStatusItem!
    var window: NSWindow?
    var lockObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = CaptureModel(); item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        model.changed = { [weak self] in self?.refreshMenu() }; refreshMenu()
        lockObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.pause() } }
        openLibrary()
    }
    func refreshMenu() {
        item.button?.title = model.recording ? "● Capture \(model.clips.count)" : "Capture paused"
        let menu = NSMenu()
        for (title, action) in [(model.recording ? "Pause capture" : "Start capture", #selector(toggle)), ("Open library", #selector(openLibrary)), ("Quit", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
        }
        item.menu = menu
    }
    @objc func toggle() { model.toggle(); if model.error != nil { openLibrary() } }
    @objc func openLibrary() {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "Reading Capture"; created.isReleasedWhenClosed = false; created.delegate = self
            created.contentView = NSHostingView(rootView: LibraryView(model: model)); created.center(); window = created
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.flush() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.flush(), !model.hasPending else { openLibrary(); return .terminateCancel }
        model.pause(); return .terminateNow
    }
    @objc func quit() { NSApp.terminate(nil) }
}

@main struct ReadingCaptureApplication {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = AppDelegate()
        app.setActivationPolicy(.accessory); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
