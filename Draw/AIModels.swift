import Foundation
import CryptoKit

struct AIFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    func validate() throws {
        guard [x, y, width, height].allSatisfy({ $0.isFinite }), width > 0, height > 0,
              abs(x) <= 4096, abs(y) <= 4096, width <= 4096, height <= 4096 else { throw AIError.invalidResult }
    }
}

struct AIStyle: Codable, Equatable {
    var fontSize: Double = 18
    var color: String = "#000000"
    var lineWidth: Double = 1
}

struct AIAsset: Codable, Equatable {
    var sha256: String
    var pixelWidth: Int
    var pixelHeight: Int
    var scale: Double = 2

    func validate() throws {
        guard AIHash.valid(sha256), scale == 2, pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 8192, pixelHeight <= 8192,
              pixelWidth * pixelHeight <= 32_000_000 else { throw AIError.invalidAsset }
    }
}

struct AIProvenance: Codable, Equatable {
    var requestID: UUID
    var contextSHA256: String
    var rendererSignature: String
}

struct AIObject: Codable, Equatable {
    var id: UUID
    var revision: Int
    var kind: String
    var source: String
    var frame: AIFrame
    var style: AIStyle
    var asset: AIAsset
    var provenance: AIProvenance

    func validate() throws {
        try frame.validate()
        try asset.validate()
        guard revision >= 1, ["text", "latex", "mermaid", "arrow", "circle", "highlight"].contains(kind),
              source.utf8.count <= 65_536, AIHash.validColor(style.color),
              style.fontSize.isFinite, style.fontSize > 0, style.fontSize <= 4096,
              style.lineWidth.isFinite, style.lineWidth >= 0, style.lineWidth <= 4096,
              abs(frame.width * 2 - Double(asset.pixelWidth)) < 0.001,
              abs(frame.height * 2 - Double(asset.pixelHeight)) < 0.001,
              AIHash.valid(provenance.contextSHA256), !provenance.rendererSignature.isEmpty else { throw AIError.invalidResult }
    }
}

struct AIStrokeTarget: Codable, Equatable {
    var id: String
    var fingerprint: String
    var index: Int
    var frame: AIFrame
    var asset: AIAsset
}

struct AIContextPage: Codable {
    var pageID: UUID
    var head: UUID?
    var background: Int
    var width: Double
    var height: Double
    var objects: [AIObject]
    var paperSHA256: String
    var inkSHA256: String
    var compositeSHA256: String
    var portableSHA256: String
    var strokeTargets: [AIStrokeTarget]
    enum CodingKeys: String, CodingKey {
        case pageID, head, background, width, height, objects
        case paperSHA256, inkSHA256, compositeSHA256, portableSHA256, strokeTargets
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(pageID, forKey: .pageID)
        try values.encode(head, forKey: .head) // Blank captured pages explicitly carry null.
        try values.encode(background, forKey: .background)
        try values.encode(width, forKey: .width)
        try values.encode(height, forKey: .height)
        try values.encode(objects, forKey: .objects)
        try values.encode(paperSHA256, forKey: .paperSHA256)
        try values.encode(inkSHA256, forKey: .inkSHA256)
        try values.encode(compositeSHA256, forKey: .compositeSHA256)
        try values.encode(portableSHA256, forKey: .portableSHA256)
        try values.encode(strokeTargets, forKey: .strokeTargets)
    }

}

struct AIContext: Codable {
    var format = 1
    var documentID: UUID
    var focusPageID: UUID
    var capturedAt: String
    var rendererSignature = "native-capture-v2"
    var orientation: String
    var pages: [AIContextPage]
    var documentName: String? = nil
    var folderName: String? = nil
    var folderID: UUID? = nil

    func encoded() throws -> Data { try AIHash.encoded(self) }
}

struct AIInsertPage: Codable {
    var pageID: UUID
    var afterPageID: UUID
    var background: Int
    var width: Double
    var height: Double
}

struct AIObjectEdit: Codable {
    var op: String
    var objectID: UUID? = nil
    var expectedRevision: Int? = nil
    var object: AIObject? = nil
    // Required for replace/remove. Revision numbers can be reused after Undo.
    var expectedObject: AIObject? = nil
}

struct AIStrokeEdit: Codable {
    var id: String
    var fingerprint: String
    var op: String
    var color: String? = nil
    var dx: Double? = nil
    var dy: Double? = nil

    func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 256, AIHash.valid(fingerprint) else { throw AIError.invalidResult }
        switch op {
        case "keep", "remove":
            guard color == nil, dx == nil, dy == nil else { throw AIError.invalidResult }
        case "recolor":
            guard let color, AIHash.validColor(color), dx == nil, dy == nil else { throw AIError.invalidResult }
        case "move":
            guard color == nil, let dx, let dy, dx.isFinite, dy.isFinite,
                  abs(dx) <= 4096, abs(dy) <= 4096,
                  abs(dx - (dx * 2).rounded() / 2) <= 1e-9,
                  abs(dy - (dy * 2).rounded() / 2) <= 1e-9 else { throw AIError.invalidResult }
        default: throw AIError.invalidResult
        }
    }
}

extension AIStrokeEdit {
    // Reject unknown and cross-operation fields, including explicit null extras.
    // Synthesized encoding still omits nil fields on the legacy wire.
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        func key(_ name: String) -> Key { Key(stringValue: name)! }
        op = try values.decode(String.self, forKey: key("op"))
        let extras: Set<String>
        switch op {
        case "keep", "remove": extras = []
        case "recolor": extras = ["color"]
        case "move": extras = ["dx", "dy"]
        default: throw AIError.invalidResult
        }
        guard Set(values.allKeys.map(\.stringValue)) == Set(["id", "fingerprint", "op"]).union(extras) else {
            throw AIError.invalidResult
        }
        id = try values.decode(String.self, forKey: key("id"))
        fingerprint = try values.decode(String.self, forKey: key("fingerprint"))
        if op == "recolor" { color = try values.decode(String.self, forKey: key("color")) }
        if op == "move" {
            dx = try values.decode(Double.self, forKey: key("dx"))
            dy = try values.decode(Double.self, forKey: key("dy"))
        }
        try validate()
    }
}

struct AIPageEdit: Codable {
    var pageID: UUID
    var objectEdits: [AIObjectEdit]
    var strokeEdits: [AIStrokeEdit]
}

struct AIResult: Codable {
    var format = 1
    var requestID: UUID
    var documentID: UUID
    var contextSHA256: String
    var draftVersion: Int
    var rendererSignature: String
    var insertPages: [AIInsertPage]
    var pageEdits: [AIPageEdit]
    var previewSHA256s: [String: String]
    // Exact approved transfer bytes, not JSON reserialization. Tests may build values directly.
    private var approvedBytes: Data? = nil
    enum CodingKeys: String, CodingKey {
        case format, requestID, documentID, contextSHA256, draftVersion, rendererSignature
        case insertPages, pageEdits, previewSHA256s
    }

    init(format: Int = 1, requestID: UUID, documentID: UUID, contextSHA256: String,
         draftVersion: Int, rendererSignature: String, insertPages: [AIInsertPage] = [],
         pageEdits: [AIPageEdit], previewSHA256s: [String: String]) {
        self.format = format; self.requestID = requestID; self.documentID = documentID
        self.contextSHA256 = contextSHA256; self.draftVersion = draftVersion
        self.rendererSignature = rendererSignature; self.insertPages = insertPages
        self.pageEdits = pageEdits; self.previewSHA256s = previewSHA256s
    }

    static func approved(data: Data) throws -> AIResult {
        guard data.count <= 4 * 1024 * 1024 else { throw SyncError.tooLarge }
        var result = try JSONDecoder().decode(AIResult.self, from: data)
        result.approvedBytes = data
        return result
    }

    func digest() throws -> String {
        // Detect mutation after approval rather than hashing stale approved bytes.
        if let approvedBytes {
            let approved = try JSONDecoder().decode(AIResult.self, from: approvedBytes)
            guard try AIHash.encoded(approved) == AIHash.encoded(self) else { throw AIError.invalidResult }
            return AIHash.digest(approvedBytes)
        }
        return AIHash.digest(try AIHash.encoded(self))
    }
}

struct AIApplyReceipt: Codable, Equatable {
    var requestID: UUID
    var resultSHA256: String
    var appliedAt: String
    var skippedStrokeTargets: [String]
    var skippedObjectTargets: [UUID]
}

// Kept outside undo and source packages, including after a migration restart.
struct AIMigrationJournal: Codable {
    var preMigrationDigest: String
    var preMigrationPackage: Data
    var globalBaseline: Data?
}

enum AIError: LocalizedError {
    case invalidResult, invalidAsset, missingPage, duplicateRequest
    var errorDescription: String? {
        switch self {
        case .invalidResult: return "The AI answer could not be verified. Notes were not changed."
        case .invalidAsset: return "An AI image could not be verified. Notes were not changed."
        case .missingPage: return "An AI destination page no longer exists. Notes were not changed."
        case .duplicateRequest: return "This AI request already has a different applied answer."
        }
    }
}

enum AIHash {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func valid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validColor(_ value: String) -> Bool {
        value.utf8.count == 7 && value.first == "#" && value.dropFirst().utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}
