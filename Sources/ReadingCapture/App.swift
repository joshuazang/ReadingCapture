import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class CaptureModel: ObservableObject {
    @Published var clips: [Clipping] = []
    @Published private(set) var selected: String?
    @Published private(set) var commentDrafts: [String: String] = [:]
    @Published var book = ""
    @Published var recording = false
    @Published var nativeHighlights = true
    @Published var readerStatus = ""
    @Published var error: String?
    @Published var allowed: [String: String] = UserDefaults.standard.dictionary(forKey: "readingApps") as? [String: String] ?? [:]
    let monitor = ClipboardMonitor()
    let nativeMonitor = NativeHighlightMonitor()
    private var annotationKeys: Set<String> = []
    private var pendingNotify = true
    private var vault: Vault?
    private var pending: Clipping?
    var changed: (() -> Void)?
    var captured: ((Clipping) -> Void)?
    init(store: Vault? = nil) {
        do { let opened = try store ?? Vault.open(); clips = try opened.load(); vault = opened }
        catch { self.error = "Library could not be opened. Existing files are untouched. \(error.localizedDescription)" }
        annotationKeys = Set(clips.compactMap(\.annotationKey))
        nativeMonitor.known = annotationKeys
        if let path = UserDefaults.standard.string(forKey: "calibreSettingsFolder") { nativeMonitor.folder = URL(fileURLWithPath: path) }
        monitor.receive = { [weak self] text, app in self?.capture(text, app: app) }
        nativeMonitor.status = { [weak self] text in if self?.readerStatus != text { self?.readerStatus = text } }
        nativeMonitor.failed = { [weak self] issue in
            self?.readerStatus = issue.localizedDescription
            if (issue as NSError).code == -1743 { self?.pause(); self?.error = issue.localizedDescription }
        }
        nativeMonitor.receive = { [weak self] annotation, app, bundle, notify in self?.recordAnnotation(annotation, app: app, bundle: bundle, notify: notify) ?? false }
    }
    var current: Clipping? { clips.first { $0.id == selected } }
    func comment(for id: String) -> String { commentDrafts[id] ?? clips.first(where: { $0.id == id })?.comment ?? "" }
    func editComment(_ value: String, for id: String) {
        guard clips.contains(where: { $0.id == id }) else { return }
        commentDrafts[id] = value
        _ = saveComment(id)
    }
    @discardableResult func saveComment(_ id: String) -> Bool {
        guard let value = commentDrafts[id] else { return true }
        guard let index = clips.firstIndex(where: { $0.id == id }), let vault else { return false }
        var clip = clips[index]; clip.comment = value
        do {
            try vault.save(clip); clips[index] = clip; commentDrafts.removeValue(forKey: id)
            if error?.hasPrefix("Comment is still") == true { error = nil }; return true
        } catch { self.error = "Comment is still in memory. Saving failed: \(error.localizedDescription)"; return false }
    }
    @discardableResult func flush() -> Bool {
        for id in Array(commentDrafts.keys) { if !saveComment(id) { return false } }
        return true
    }
    func select(_ id: String?) {
        guard let id, clips.contains(where: { $0.id == id }), flush() else { return }
        selected = id
    }
    func toggle() {
        if recording { pause(); return }
        guard vault != nil, pending == nil else { error = "Resolve the library or pending-save error before starting capture."; return }
        guard !allowed.isEmpty else { error = "Choose your Skim or calibre viewer application first."; return }
        monitor.allowed = Set(allowed.keys); nativeMonitor.allowed = Set(allowed.keys)
        recording = true
        if nativeHighlights { nativeMonitor.start() } else { monitor.start() }
        changed?()
    }
    func pause() { monitor.stop(); nativeMonitor.stop(); recording = false; changed?() }
    func addReader() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.message = "Choose Skim or the calibre viewer application. Only chosen apps can supply captures."
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        allowed[id] = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
        UserDefaults.standard.set(allowed, forKey: "readingApps"); monitor.allowed = Set(allowed.keys); nativeMonitor.allowed = Set(allowed.keys)
    }
    func allowRunning(_ app: NSRunningApplication) { guard let id = app.bundleIdentifier else { return }; allowed[id] = app.localizedName ?? id; UserDefaults.standard.set(allowed, forKey: "readingApps"); monitor.allowed = Set(allowed.keys); nativeMonitor.allowed = Set(allowed.keys) }
    func removeReader(_ id: String) { allowed.removeValue(forKey: id); UserDefaults.standard.set(allowed, forKey: "readingApps"); monitor.allowed = Set(allowed.keys); nativeMonitor.allowed = Set(allowed.keys); if allowed.isEmpty { pause() } }
    private func capture(_ text: String, app: NSRunningApplication) { record(text, app: app.localizedName ?? "Reader", bundle: app.bundleIdentifier ?? "") }
    func record(_ text: String, app: String, bundle: String) {
        guard pending == nil else { pause(); return }
        do { let clip = try Clipping.make(quote: text, book: book, app: app, bundle: bundle); pending = clip; pendingNotify = true; retry() }
        catch { pause(); self.error = error.localizedDescription }
    }
    func recordAnnotation(_ annotation: ReaderHighlight, app: String, bundle: String, notify: Bool) -> Bool {
        if annotationKeys.contains(annotation.key) { return true }
        guard pending == nil else { return false }
        do {
            var clip = try Clipping.make(quote: annotation.text, book: annotation.book, app: app, bundle: bundle)
            clip.annotationKey = annotation.key; pending = clip; pendingNotify = notify; retry()
            return annotationKeys.contains(annotation.key)
        } catch { pause(); self.error = error.localizedDescription; return false }
    }
    func chooseCalibreFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = nativeMonitor.folder
        panel.message = "Choose calibre’s settings folder containing viewer-webengine.json. Reading Capture only reads metadata and viewer/annots files."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("viewer-webengine.json").path) else { error = "That folder does not contain viewer-webengine.json."; return }
        nativeMonitor.folder = folder; UserDefaults.standard.set(folder.path, forKey: "calibreSettingsFolder")
    }
    func retry() {
        guard let clip = pending, let vault else { return }
        guard flush() else { pause(); return }
        do { try vault.save(clip); clips.insert(clip, at: 0); pending = nil; error = nil; if selected == nil { selected = clip.id }; if let key = clip.annotationKey { annotationKeys.insert(key); nativeMonitor.known.insert(key) }; changed?(); if pendingNotify { captured?(clip) } }
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
                try vault.save(clip); clips.append(clip); if let key = clip.annotationKey { annotationKeys.insert(key); nativeMonitor.known.insert(key) }; known[clip.id] = clip; imported += 1
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
            HStack {
                Picker("Capture", selection: $model.nativeHighlights) { Text("Native highlights").tag(true); Text("Clipboard").tag(false) }.pickerStyle(.segmented).frame(maxWidth: 330).disabled(model.recording)
                if model.nativeHighlights { Button("calibre settings folder…") { model.chooseCalibreFolder() }.disabled(model.recording) }
                else { TextField("Optional book label for clipboard captures", text: $model.book) }
            }
            if model.nativeHighlights { Text(model.readerStatus.isEmpty ? "Book titles are recorded automatically. Start capture, then highlight in your reader." : model.readerStatus).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Menu("Reading apps (\(model.allowed.count))") {
                    ForEach(model.allowed.keys.sorted(), id: \.self) { id in Button("Remove \(model.allowed[id] ?? id)") { model.removeReader(id) } }
                    Divider(); ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in Button("Allow \(app.localizedName ?? "Reader")") { model.allowRunning(app) } }; Divider(); Button("Add reading app…") { model.addReader() }
                }
                Text("Highlight or copy in your chosen mode. Capture starts paused.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if let error = model.error {
                HStack { Text(error).foregroundStyle(.red).textSelection(.enabled); if model.hasPending { Button("Retry capture") { model.retry() } } }
            }
            if model.hasPending { ScrollView { Text(model.pendingQuote).textSelection(.enabled) }.frame(maxHeight: 100); Button("Discard pending capture…") { model.discardPending() } }
            HSplitView {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.clips) { clip in
                            Button { model.select(clip.id) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(clip.quote).lineLimit(3)
                                    Text(clip.book.isEmpty ? clip.sourceApp : clip.book).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                  .background(model.selected == clip.id ? Color.accentColor.opacity(0.12) : Color.clear)
                                  .clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }.padding(4)
                }.frame(minWidth: 220, idealWidth: 280)
                VStack(alignment: .leading, spacing: 12) {
                    if let clip = model.current {
                        Text(clip.book.isEmpty ? clip.sourceApp : clip.book).font(.headline)
                        Text(clip.capturedAt).font(.caption).foregroundStyle(.secondary)
                        ScrollView { Text(clip.quote).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(minHeight: 100)
                        Text("Comment (optional)").font(.headline)
                        TextEditor(text: Binding(get: { model.comment(for: clip.id) }, set: { model.editComment($0, for: clip.id) })).id(clip.id).frame(minHeight: 100)
                        HStack { Text("Comments save automatically as you type.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Save comment") { _ = model.flush() }.keyboardShortcut(.return, modifiers: .command) }
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
    var commentPanel: CommentPanel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"), let image = NSImage(contentsOfFile: path) { NSApp.applicationIconImage = image }
        model = CaptureModel(); item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        model.changed = { [weak self] in self?.refreshMenu() }; refreshMenu()
        lockObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.pause() } }
        model.captured = { [weak self] clip in self?.showComment(clip) }
        openLibrary()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openLibrary(); return true }
    func showComment(_ clip: Clipping) {
        if commentPanel == nil { commentPanel = CommentPanel() }
        commentPanel?.contentView = NSHostingView(rootView: QuickCommentView(model: model, clip: clip, close: { [weak self] in self?.commentPanel?.orderOut(nil) }))
        commentPanel?.orderFrontRegardless()
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
            created.contentMinSize = NSSize(width: 760, height: 500)
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
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        menu.addItem(appItem); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Reading Capture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(), editMenu = NSMenu(title: "Edit"); menu.addItem(editItem); editItem.submenu = editMenu
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { editMenu.addItem(withTitle: title, action: action, keyEquivalent: key) }
        app.mainMenu = menu
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class CommentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 390, height: 250), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Comment on capture"; level = .floating; hidesOnDeactivate = false
        isReleasedWhenClosed = false; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; center()
    }
}
struct QuickCommentView: View {
    @ObservedObject var model: CaptureModel
    let clip: Clipping
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(clip.quote).lineLimit(3).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { model.comment(for: clip.id) }, set: { model.editComment($0, for: clip.id) })).id(clip.id).frame(minHeight: 80)
            if model.commentDrafts[clip.id] != nil { Text("Comment is not saved yet. Keep this window open and retry.").foregroundStyle(.red) }
            HStack { Text("Optional · saves automatically").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Done") { if model.saveComment(clip.id) { close() } }.keyboardShortcut(.return, modifiers: .command) }
        }.padding(12).frame(width: 366, height: 226)
    }
}
