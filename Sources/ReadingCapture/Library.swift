import Foundation
import CryptoKit
import Security

enum CaptureError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

struct Clipping: Codable, Identifiable, Equatable {
    var id: String
    var capturedAt: String
    var quote: String
    var comment: String
    var book: String
    var sourceApp: String
    var sourceBundle: String

    static func make(quote: String, book: String, app: String, bundle: String) throws -> Clipping {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CaptureError.invalid("Could not generate a capture identity.") }
        let id = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return Clipping(id: id, capturedAt: ISO8601DateFormatter().string(from: Date()), quote: quote, comment: "", book: book, sourceApp: app, sourceBundle: bundle)
    }
    func validate() throws {
        guard id.range(of: "^[A-Za-z0-9_-]{21}[AQgw]$", options: .regularExpression) != nil,
              ISO8601DateFormatter().date(from: capturedAt) != nil,
              !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              quote.utf8.count <= 1_000_000, comment.utf8.count <= 1_000_000,
              book.utf8.count <= 4096, sourceApp.utf8.count <= 4096, sourceBundle.utf8.count <= 4096 else {
            throw CaptureError.invalid("Invalid or oversized capture. Nothing was replaced.")
        }
    }
}

enum Exchange {
    struct Archive: Codable { var format = "reading-capture"; var version = 1; var clips: [Clipping] }
    struct Message: Encodable {
        var id: String; var text: String; var createdAt: String
        var readingCapture: SourceContext
    }
    struct SourceContext: Encodable { var sourceApp: String; var sourceBundle: String; var book: String }
    struct Forward: Encodable {
        var format = "im-style-forward"; var version = 2; var sourceNoteId = "reading-capture"
        var messages: [Message]; var settings: [String: String] = [:]
    }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func archive(_ clips: [Clipping]) throws -> Data { try encoded(Archive(clips: clips)) }
    static func decode(_ data: Data) throws -> [Clipping] {
        guard data.count <= 32_000_000 else { throw CaptureError.invalid("Archive exceeds 32 MB.") }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.format == "reading-capture", archive.version == 1, archive.clips.count <= 20_000 else { throw CaptureError.invalid("Unsupported capture archive.") }
        var ids = Set<String>()
        for clip in archive.clips { try clip.validate(); guard ids.insert(clip.id).inserted else { throw CaptureError.invalid("Duplicate capture identities in archive.") } }
        return archive.clips
    }
    static func forward(_ clips: [Clipping]) throws -> Data {
        for clip in clips { try clip.validate() }
        let messages = clips.map { clip in
            Message(id: clip.id, text: clip.quote + (clip.comment.isEmpty ? "" : "\n\nComment:\n" + clip.comment), createdAt: clip.capturedAt, readingCapture: SourceContext(sourceApp: clip.sourceApp, sourceBundle: clip.sourceBundle, book: clip.book))
        }
        return Data("#!im-style-forward 2\n".utf8) + (try encoded(Forward(messages: messages))) + Data("\n".utf8)
    }
}

final class Vault {
    let directory: URL
    private let key: SymmetricKey
    private static let magic = Data("RCV1".utf8)
    static func open(directory: URL? = nil, service: String = "ReadingCapture.Vault.v1") throws -> Vault {
        let folder = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ReadingCapture", isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: folder.path) ? try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).contains { $0.pathExtension == "rcclip" } : false
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "encryption-key", kSecAttrSynchronizable as String: false]
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        let data: Data
        if status == errSecSuccess, let found = result as? Data, found.count == 32 { data = found }
        else if status == errSecItemNotFound && !exists {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CaptureError.invalid("Key generation failed.") }
            data = Data(bytes); var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CaptureError.invalid("Could not save the encryption key in Keychain. Capture is disabled.") }
        } else { throw CaptureError.invalid("The encryption key is missing, locked or unavailable. Existing captures are untouched. Unlock/restore your Keychain; no replacement key was created.") }
        return try Vault(directory: folder, key: SymmetricKey(data: data))
    }
    init(directory: URL, key: SymmetricKey) throws {
        self.directory = directory; self.key = key
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    func load() throws -> [Clipping] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]).filter { $0.pathExtension == "rcclip" }
        return try urls.map { url in
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 3_000_000 else { throw CaptureError.invalid("An invalid vault file was found. Files are untouched.") }
            let data = try Data(contentsOf: url)
            guard data.starts(with: Self.magic) else { throw CaptureError.invalid("Unsupported vault file. Files are untouched.") }
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(Self.magic.count)), using: key)
            let clip = try JSONDecoder().decode(Clipping.self, from: plain); try clip.validate()
            guard url.deletingPathExtension().lastPathComponent == clip.id else { throw CaptureError.invalid("Capture identity does not match its file. Files are untouched.") }
            return clip
        }.sorted { $0.capturedAt > $1.capturedAt }
    }
    func save(_ clip: Clipping) throws {
        try clip.validate()
        let plain = try JSONEncoder().encode(clip)
        guard plain.count <= 2_900_000 else { throw CaptureError.invalid("Encoded capture exceeds the storage limit.") }
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else { throw CaptureError.invalid("Encryption failed.") }
        let url = directory.appendingPathComponent(clip.id).appendingPathExtension("rcclip")
        // Only ciphertext ever reaches the atomic-write temporary file.
        try (Self.magic + combined).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
