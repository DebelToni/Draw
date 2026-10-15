import Foundation
import CryptoKit
import PencilKit
import zlib

struct SyncPackage: Codable {
    var format = 1
    var notebooks: [Notebook]
    var blobs: [String: Data]
    var folders: [Folder]?
    var assets: [String: Data]? = nil

    static func sourceFormat(folders: [Folder], hasAssets: Bool) -> Int {
        folders.contains { $0.parentID != nil } ? 3 : (hasAssets ? 2 : 1)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func digest() throws -> String {
        SHA256.hash(data: try encoded()).map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        try validateMetadata(blobKeys: Set(blobs.keys))
        for bytes in blobs.values { _ = try PKDrawing(data: bytes) }
        for object in notebooks.flatMap({ $0.pages + $0.deleted }).flatMap(\.nodes).flatMap({ $0.objects ?? [] }) {
            guard let bytes = assets?[object.asset.sha256] else { throw SyncError.invalidPackage }
            try AIAssets.validate(data: bytes, asset: object.asset)
        }
    }

    fileprivate func validateMetadata(blobKeys: Set<String>, assetKeys: Set<String>? = nil) throws {
        guard (1...3).contains(format), Set(notebooks.map(\.id)).count == notebooks.count else { throw SyncError.invalidPackage }
        let allObjects = notebooks.flatMap { $0.pages + $0.deleted }.flatMap(\.nodes).flatMap { $0.objects ?? [] }
        let referenced = Set(allObjects.map { $0.asset.sha256 })
        guard referenced == (assetKeys ?? Set((assets ?? [:]).keys)),
              // Readers accept v3 subsets without nesting; writers still choose 1/2 for flat sources.
              (format == 3 || format == Self.sourceFormat(folders: folders ?? [], hasAssets: !referenced.isEmpty)),
              format != 1 || assets == nil else { throw SyncError.invalidPackage }
        for object in allObjects { try object.validate() }
        for node in notebooks.flatMap({ $0.pages + $0.deleted }).flatMap(\.nodes) {
            let objects = node.objects ?? []
            guard Set(objects.map(\.id)).count == objects.count else { throw SyncError.invalidPackage }
        }
        let folderIDs = Set((folders ?? []).map(\.id))
        try Folder.validateGraph(folders ?? [], notebooks: notebooks)
        var expected = Set<String>()
        for book in notebooks {
            guard book.orientation == nil || book.orientation == "portrait" || book.orientation == "landscape" else { throw SyncError.invalidPackage }
            guard book.folderID == nil || folderIDs.contains(book.folderID!) else { throw SyncError.invalidPackage }
            let pages = book.pages + book.deleted
            guard !book.pages.isEmpty, Set(pages.map(\.id)).count == pages.count,
                  book.currentPage == nil || book.pages.contains(where: { $0.id == book.currentPage }) else { throw SyncError.invalidPackage }
            for page in pages {
                guard (0...3).contains(page.background), Set(page.nodes.map(\.id)).count == page.nodes.count else { throw SyncError.invalidPackage }
                let nodes = Dictionary(uniqueKeysWithValues: page.nodes.map { ($0.id, $0) })
                guard page.head == nil || nodes[page.head!] != nil else { throw SyncError.invalidPackage }
                if let root = page.preferredRoot {
                    guard let node = nodes[root], node.parent == nil else { throw SyncError.invalidPackage }
                }
                var seen = Set<UUID>()
                for node in page.nodes {
                    guard node.parent == nil || seen.contains(node.parent!),
                          Set(node.children).count == node.children.count,
                          node.children.allSatisfy({ nodes[$0]?.parent == node.id }),
                          node.parent == nil || nodes[node.parent!]?.children.contains(node.id) == true,
                          node.preferredChild == nil || node.children.contains(node.preferredChild!) else { throw SyncError.invalidPackage }
                    seen.insert(node.id)
                    let key = Self.key(book.id, page.id, node.id)
                    expected.insert(key)
                }
            }
        }
        guard expected == blobKeys else { throw SyncError.invalidPackage }
    }

    // Wire packages contain current drawings only. Full local history remains
    // valid for Store fixtures and may still supply bytes for hash-based reuse.
    fileprivate func validateCurrentOnlyMetadata() throws {
        for book in notebooks {
            for page in book.pages + book.deleted {
                if let head = page.head {
                    guard page.nodes.count == 1, let node = page.nodes.first,
                          node.id == head, node.parent == nil, node.children.isEmpty,
                          node.preferredChild == nil,
                          page.preferredRoot == nil || page.preferredRoot == head else { throw SyncError.invalidPackage }
                } else {
                    guard page.nodes.isEmpty, page.preferredRoot == nil else { throw SyncError.invalidPackage }
                }
            }
        }
    }

    static func key(_ book: UUID, _ page: UUID, _ node: UUID) -> String {
        "\(book.uuidString)/\(page.uuidString)/\(node.uuidString)"
    }
}

enum SyncError: LocalizedError {
    case missingToken, invalidPackage, conflict, tooLarge, http(Int)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "This build has no DGX sync credential. Notes remain on this iPad."
        case .invalidPackage: return "The sync package could not be verified. No local document was replaced."
        case .conflict: return "Both copies have changed. Sync stopped without overwriting either copy."
        case .tooLarge: return "A sync object or its metadata exceeds the transfer size limit. Notes remain on this iPad."
        case .http(let status): return "DGX rejected sync (HTTP \(status)). No success was confirmed."
        }
    }
}

struct SyncState: Codable {
    var revision: Int
    var package: SyncPackage?
}

struct SyncBaseline: Codable, Equatable {
    var revision: Int
    var digest: String
}

// Operator-pinned repair of one known stale baseline, never a source merge.
struct SyncBaselineRepair: Codable {
    var previous: SyncBaseline
    var target: SyncBaseline
    var localDigest: String

    func apply(local: SyncPackage, remote: SyncState, baseline: SyncBaseline?) throws -> SyncBaseline? {
        guard baseline == previous else { return baseline }
        guard target.revision >= previous.revision, remote.revision == target.revision,
              let package = remote.package, try local.digest() == localDigest,
              try package.digest() == target.digest else { throw SyncError.conflict }
        return target
    }
}

enum SyncDecision: Equatable {
    case upload, download, unchanged

    static func choose(local: SyncPackage, remote: SyncState, baseline: SyncBaseline?) throws -> SyncDecision {
        guard let package = remote.package else {
            // A server reset must not silently erase the known remote history.
            guard baseline == nil || baseline?.revision == 0 else { throw SyncError.conflict }
            return .upload
        }
        let localHash = try local.digest()
        let remoteHash = try package.digest()
        if localHash == remoteHash { return .unchanged }
        if let baseline, remote.revision < baseline.revision { throw SyncError.conflict }
        if local.notebooks.isEmpty && (local.folders ?? []).isEmpty && baseline == nil { return .download }
        if baseline?.digest == localHash { return .download }
        if baseline?.revision == remote.revision && baseline?.digest == remoteHash { return .upload }
        throw SyncError.conflict
    }
}

// Wire-only metadata. SyncPackage encoding and its baseline digest stay legacy canonical.
private struct SyncManifest: Codable {
    var format: Int
    var notebooks: [Notebook]
    var blobs: [String: String]
    var folders: [Folder]?
    var assets: [String: String]?

    init(_ package: SyncPackage) {
        format = package.format
        notebooks = package.notebooks
        blobs = package.blobs.mapValues { SyncObjects.digest($0) }
        folders = package.folders
        assets = package.assets?.mapValues { SyncObjects.digest($0) }
    }

    func validate() throws {
        guard (assets ?? [:]).allSatisfy({ $0.key == $0.value && SyncObjects.validDigest($0.key) }),
              format != 1 || assets == nil, blobs.values.allSatisfy(SyncObjects.validDigest) else { throw SyncError.invalidPackage }
        let package = SyncPackage(format: format, notebooks: notebooks, blobs: [:], folders: folders)
        try package.validateCurrentOnlyMetadata()
        try package.validateMetadata(blobKeys: Set(blobs.keys), assetKeys: Set((assets ?? [:]).keys))
    }
}

enum SyncObjects {
    static let metadataLimit = 4 * 1024 * 1024
    static let objectLimit = 128 * 1024 * 1024

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

// zlib checks gzip CRC/length and requires a complete, single stream.
// Internal visibility also lets fixtures exercise the same wire compression.
enum SyncGzip {
    static func encode(_ data: Data, limit: Int) throws -> Data {
        try transform(data, compress: true, limit: limit)
    }

    static func decode(_ data: Data, limit: Int) throws -> Data {
        try transform(data, compress: false, limit: limit)
    }

    static func responseBody(_ data: Data, encoding: String?, expectedDigest: String? = nil, limit: Int) throws -> Data {
        guard data.count <= limit else { throw SyncError.tooLarge }
        // An already-decoded CAS object may itself be gzip. Its exact digest
        // takes precedence over a retained HTTP Content-Encoding header.
        if let expectedDigest, SyncObjects.digest(data) == expectedDigest {
            guard !data.isEmpty else { throw SyncError.invalidPackage }
            return data
        }
        let decoded = encoding == "gzip" && data.starts(with: [0x1f, 0x8b])
            ? try decode(data, limit: limit) : data
        if let expectedDigest {
            guard !decoded.isEmpty, SyncObjects.digest(decoded) == expectedDigest else { throw SyncError.invalidPackage }
        }
        return decoded
    }

    private static func transform(_ data: Data, compress: Bool, limit: Int) throws -> Data {
        guard data.count <= Int(UInt32.max) else { throw SyncError.tooLarge }
        var stream = z_stream()
        let initialized = compress
            ? deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw SyncError.invalidPackage }
        defer {
            if compress { deflateEnd(&stream) } else { inflateEnd(&stream) }
        }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let status = chunk.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return compress ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_NO_FLUSH)
                }
                let count = chunk.count - Int(stream.avail_out)
                guard count <= limit - result.count else { throw SyncError.tooLarge }
                result.append(contentsOf: chunk.prefix(count))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw SyncError.invalidPackage }
                    return result
                }
                guard status == Z_OK, count > 0 else { throw SyncError.invalidPackage }
            }
        }
    }
}

final class SyncClient {
    private let endpoint: URL
    private let token: String
    private let session: URLSession
    private let ownsSession: Bool

    init(endpoint: URL = DrawEndpoints.sync, token: String, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.token = token
        ownsSession = session == nil
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        // A commit can regenerate an entire legacy preview cache before replying.
        // Keep this explicit Home Sync bounded without timing out after 15s of rendering.
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 300
        config.urlCache = nil
        self.session = session ?? URLSession(configuration: config)
    }

    // An injected session belongs to its caller and may serve other clients.
    deinit { if ownsSession { session.invalidateAndCancel() } }

    private func request(body: Data? = nil) async throws -> Data {
        guard !token.isEmpty, !token.hasPrefix("$(") else { throw SyncError.missingToken }
        if let body, body.count > 128 * 1024 * 1024 { throw SyncError.tooLarge }
        var request = URLRequest(url: endpoint)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SyncError.invalidPackage }
        if response.statusCode == 409 { throw SyncError.conflict }
        if response.statusCode == 413 { throw SyncError.tooLarge }
        guard response.statusCode == 200 else { throw SyncError.http(response.statusCode) }
        return data
    }

    private func v2URL(_ path: String) -> URL {
        endpoint.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("v2").appendingPathComponent(path)
    }

    private func incrementalRequest(_ path: String, body: Data? = nil, object: Bool = false,
                                    expectedDigest: String? = nil) async throws -> Data {
        guard !token.isEmpty, !token.hasPrefix("$(") else { throw SyncError.missingToken }
        let requestLimit = object ? SyncObjects.objectLimit : SyncObjects.metadataLimit
        let limit = object && body == nil ? SyncObjects.objectLimit : SyncObjects.metadataLimit
        if let body, body.count > requestLimit { throw SyncError.tooLarge }
        var request = URLRequest(url: v2URL(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(object ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try SyncGzip.encode(body, limit: requestLimit)
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw SyncError.invalidPackage }
        if response.statusCode == 409 { throw SyncError.conflict }
        if response.statusCode == 413 { throw SyncError.tooLarge }
        guard response.statusCode == 200 else { throw SyncError.http(response.statusCode) }
        guard response.expectedContentLength <= Int64(limit) else { throw SyncError.tooLarge }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard encoding == nil || encoding == "identity" || encoding == "gzip" else { throw SyncError.invalidPackage }
        // AsyncBytes bounds the body before allocating a whole response. URLSession
        // normally decompresses gzip itself, sometimes retaining the response header.
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw SyncError.tooLarge }
            data.append(byte)
        }
        return try SyncGzip.responseBody(data, encoding: encoding, expectedDigest: expectedDigest, limit: limit)
    }

    private func decoded<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw SyncError.invalidPackage }
    }

    func fetchIncremental(local: SyncPackage) async throws -> SyncState {
        struct State: Decodable {
            var revision: Int
            var manifest: SyncManifest?
            enum CodingKeys: String, CodingKey { case revision, manifest }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                revision = try container.decode(Int.self, forKey: .revision)
                if try container.decodeNil(forKey: .manifest) { manifest = nil }
                else { manifest = try container.decode(SyncManifest.self, forKey: .manifest) }
            }
        }
        let state = try decoded(State.self, from: await incrementalRequest("state"))
        guard state.revision >= 0 else { throw SyncError.invalidPackage }
        guard let manifest = state.manifest else {
            guard state.revision == 0 else { throw SyncError.invalidPackage }
            return SyncState(revision: state.revision, package: nil)
        }
        return SyncState(revision: state.revision, package: try await reconstruct(manifest, local: local))
    }

    private func reconstruct(_ manifest: SyncManifest, local: SyncPackage) async throws -> SyncPackage {
        try manifest.validate()
        var objects: [String: Data] = [:]
        let needed = Set(manifest.blobs.values).union((manifest.assets ?? [:]).values)
        for data in Array(local.blobs.values) + Array((local.assets ?? [:]).values) {
            let digest = SyncObjects.digest(data)
            if needed.contains(digest) { objects[digest] = data }
        }
        for digest in needed.sorted() where objects[digest] == nil {
            objects[digest] = try await incrementalRequest("objects/" + digest, object: true, expectedDigest: digest)
        }
        let package = SyncPackage(format: manifest.format, notebooks: manifest.notebooks,
                                  blobs: manifest.blobs.mapValues { objects[$0]! }, folders: manifest.folders,
                                  assets: manifest.assets?.mapValues { objects[$0]! })
        try package.validate()
        return package
    }

    func uploadIncremental(_ package: SyncPackage, baseRevision: Int, pages: [String: PortablePage]) async throws -> Int {
        struct Upload: Encodable { var baseRevision: Int; var manifest: SyncManifest; var scenes: [String: String] }
        struct Receipt: Decodable { var revision: Int }
        guard baseRevision >= 0 else { throw SyncError.invalidPackage }
        let (manifest, objects, scenes) = try prepare(package, pages: pages)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try await uploadObjects(objects)
        let receipt = try decoded(Receipt.self, from: await incrementalRequest("state",
            body: encoder.encode(Upload(baseRevision: baseRevision, manifest: manifest, scenes: scenes))))
        guard receipt.revision >= baseRevision else { throw SyncError.invalidPackage }
        return receipt.revision
    }

    private func prepare(_ package: SyncPackage, pages: [String: PortablePage]) throws
        -> (SyncManifest, [String: Data], [String: String]) {
        try package.validateCurrentOnlyMetadata()
        try package.validate()
        let manifest = SyncManifest(package)
        var expected: [String: Page] = [:]
        for book in package.notebooks {
            for page in book.pages + book.deleted {
                expected["\(book.id.uuidString)/\(page.id.uuidString)"] = page
            }
        }
        guard Set(expected.keys) == Set(pages.keys) else { throw SyncError.invalidPackage }
        var objects: [String: Data] = [:]
        for data in Array(package.blobs.values) + Array((package.assets ?? [:]).values) {
            guard !data.isEmpty, data.count <= SyncObjects.objectLimit else { throw SyncError.tooLarge }
            objects[SyncObjects.digest(data)] = data
        }
        var scenes: [String: String] = [:]
        for (key, page) in pages {
            let data = try page.encoded()
            guard !data.isEmpty, data.count <= SyncObjects.objectLimit else { throw SyncError.tooLarge }
            guard page.format == 1, page.head == expected[key]?.head,
                  (page.objects ?? []) == (expected[key]?.nodes.first?.objects ?? []) else { throw SyncError.invalidPackage }
            let digest = SyncObjects.digest(data)
            objects[digest] = data
            scenes[key] = digest
        }
        return (manifest, objects, scenes)
    }

    private func uploadObjects(_ objects: [String: Data]) async throws {
        struct MissingRequest: Encodable { var digests: [String] }
        struct Missing: Decodable { var missing: [String] }
        struct ObjectReceipt: Decodable { var digest: String }
        let encoder = JSONEncoder()
        let missing = try decoded(Missing.self, from: await incrementalRequest("objects/missing",
            body: encoder.encode(MissingRequest(digests: objects.keys.sorted())))).missing
        guard Set(missing).count == missing.count, missing.allSatisfy({ objects[$0] != nil }) else { throw SyncError.invalidPackage }
        for digest in missing.sorted() {
            let receipt = try decoded(ObjectReceipt.self, from: await incrementalRequest("objects/" + digest,
                body: objects[digest]!, object: true))
            guard receipt.digest == digest else { throw SyncError.invalidPackage }
        }
    }

    func fetchDocument(_ id: UUID, local: SyncPackage) async throws -> DocumentSyncState {
        struct State: Decodable {
            var revision: Int
            var manifest: SyncManifest?
            var documentDigest: String?
            var lastSyncedAt: String?
            enum CodingKeys: String, CodingKey { case revision, manifest, documentDigest, lastSyncedAt }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                guard c.contains(.manifest), c.contains(.documentDigest), c.contains(.lastSyncedAt) else { throw SyncError.invalidPackage }
                revision = try c.decode(Int.self, forKey: .revision)
                manifest = try c.decodeIfPresent(SyncManifest.self, forKey: .manifest)
                documentDigest = try c.decodeIfPresent(String.self, forKey: .documentDigest)
                lastSyncedAt = try c.decodeIfPresent(String.self, forKey: .lastSyncedAt)
            }
        }
        let state = try decoded(State.self, from: await incrementalRequest("documents/\(id.uuidString)/state"))
        guard state.revision >= 0, (state.manifest == nil) == (state.documentDigest == nil) else { throw SyncError.invalidPackage }
        var package: SyncPackage?
        if let manifest = state.manifest { package = try await reconstruct(manifest, local: local) }
        else { package = nil }
        if let source = package {
            guard source.notebooks.count == 1, source.notebooks[0].id == id,
                  let digest = state.documentDigest, SyncObjects.validDigest(digest) else { throw SyncError.invalidPackage }
            // Match Store's re-export before caching native baseline/pending hashes.
            // The server's wire digest remains opaque and unchanged.
            package = try source.document(id)
        }
        return DocumentSyncState(revision: state.revision, package: package,
                                 documentDigest: state.documentDigest, lastSyncedAt: state.lastSyncedAt)
    }

    func uploadDocument(_ package: SyncPackage, documentID: UUID, syncID: UUID,
                        baseDocumentDigest: String?, pages: [String: PortablePage]) async throws -> DocumentSyncReceipt {
        struct Upload: Encodable {
            var syncID: UUID
            var baseDocumentDigest: String?
            var manifest: SyncManifest
            var scenes: [String: String]
            enum CodingKeys: String, CodingKey { case syncID, baseDocumentDigest, manifest, scenes }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(syncID, forKey: .syncID)
                try c.encode(baseDocumentDigest, forKey: .baseDocumentDigest)
                try c.encode(manifest, forKey: .manifest)
                try c.encode(scenes, forKey: .scenes)
            }
        }
        guard package.notebooks.count == 1, package.notebooks[0].id == documentID else { throw SyncError.invalidPackage }
        let (manifest, objects, scenes) = try prepare(package, pages: pages)
        try await uploadObjects(objects)
        let receipt = try decoded(DocumentSyncReceipt.self, from: await incrementalRequest("documents/\(documentID.uuidString)/state",
            body: JSONEncoder().encode(Upload(syncID: syncID, baseDocumentDigest: baseDocumentDigest, manifest: manifest, scenes: scenes))))
        guard receipt.syncID == syncID, receipt.revision >= 0, SyncObjects.validDigest(receipt.documentDigest) else { throw SyncError.invalidPackage }
        return receipt
    }

    func fetchSyncReceipt(_ id: UUID) async throws -> DocumentSyncReceipt {
        let receipt = try decoded(DocumentSyncReceipt.self, from: await incrementalRequest("sync-receipts/" + id.uuidString))
        guard receipt.syncID == id, receipt.revision >= 0, SyncObjects.validDigest(receipt.documentDigest) else { throw SyncError.invalidPackage }
        return receipt
    }

    func fetch() async throws -> SyncState {
        try JSONDecoder().decode(SyncState.self, from: await request())
    }

    func upload(_ package: SyncPackage, baseRevision: Int, images: [String: PageImage]? = nil) async throws -> Int {
        struct Upload: Encodable { var baseRevision: Int; var package: SyncPackage; var images: [String: PageImage]? }
        struct Receipt: Decodable { var revision: Int }
        let body = try JSONEncoder().encode(Upload(baseRevision: baseRevision, package: package, images: images))
        return try JSONDecoder().decode(Receipt.self, from: await request(body: body)).revision
    }
}

struct DocumentSyncState {
    var revision: Int
    var package: SyncPackage?
    var documentDigest: String?
    var lastSyncedAt: String?
}

struct DocumentSyncReceipt: Codable, Equatable {
    var revision: Int
    var documentDigest: String
    var lastSyncedAt: String
    var syncID: UUID
}

struct DocumentSyncBaseline: Codable, Equatable {
    var serverDigest: String
    var localDigest: String
    var revision: Int
    var lastSyncedAt: String
}

extension SyncDecision {
    static func document(local: SyncPackage, remote: DocumentSyncState, baseline: DocumentSyncBaseline?) throws -> SyncDecision {
        guard let package = remote.package else {
            guard baseline == nil else { throw SyncError.conflict }
            return .upload
        }
        let localDigest = try local.digest()
        if localDigest == (try package.digest()) { return .unchanged }
        guard let baseline, remote.revision >= baseline.revision else { throw SyncError.conflict }
        let localChanged = localDigest != baseline.localDigest
        let remoteChanged = remote.documentDigest != baseline.serverDigest
        if !localChanged && remoteChanged { return .download }
        if localChanged && !remoteChanged { return .upload }
        // Local representation migrations can leave the two baseline hashes unequal.
        if !localChanged && !remoteChanged { return .unchanged }
        throw SyncError.conflict
    }
}

extension SyncPackage {
    func document(_ id: UUID) throws -> SyncPackage {
        // Validate the source type before projecting away unrelated hierarchy/assets.
        try validateMetadata(blobKeys: Set(blobs.keys))
        guard let book = notebooks.first(where: { $0.id == id }) else { throw SyncError.invalidPackage }
        return try Self.combine([book], sources: [self], folders: Folder.ancestorClosure(of: book.folderID, in: folders ?? []))
    }

    // Keep native/asset bytes from the selected document's exact source, not an
    // unrelated local snapshot with coincidentally matching paths.
    static func combine(_ books: [Notebook], sources: [SyncPackage], folders: [Folder]) throws -> SyncPackage {
        var blobs: [String: Data] = [:], assets: [String: Data] = [:]
        for book in books {
            for page in book.pages + book.deleted {
                for node in page.nodes {
                    let key = key(book.id, page.id, node.id)
                    guard let bytes = sources.lazy.compactMap({ $0.blobs[key] }).first else { throw SyncError.invalidPackage }
                    blobs[key] = bytes
                    for object in node.objects ?? [] {
                        let sha = object.asset.sha256
                        guard let bytes = sources.lazy.compactMap({ $0.assets?[sha] }).first else { throw SyncError.invalidPackage }
                        assets[sha] = bytes
                    }
                }
            }
        }
        let package = SyncPackage(format: Self.sourceFormat(folders: folders, hasAssets: !assets.isEmpty), notebooks: books, blobs: blobs,
                                  folders: folders.isEmpty ? nil : folders, assets: assets.isEmpty ? nil : assets)
        try package.validate()
        return package
    }

    func portablePages() throws -> [String: PortablePage] {
        var scenes: [String: PortablePage] = [:]
        for book in notebooks {
            for page in book.pages + book.deleted {
                let drawing: PKDrawing
                if let head = page.head {
                    guard let bytes = blobs[Self.key(book.id, page.id, head)] else { throw SyncError.invalidPackage }
                    drawing = try PKDrawing(data: bytes)
                } else { drawing = PKDrawing() }
                var scene = try PortablePage(drawing: drawing,
                    pageSize: DocumentOrientation(metadata: book.orientation).pageSize, head: page.head)
                scene.background = page.background
                scene.objects = page.nodes.first(where: { $0.id == page.head })?.objects
                for object in scene.objects ?? [] {
                    scene.width = max(scene.width, ceil(object.frame.x + object.frame.width))
                    scene.height = max(scene.height, ceil(object.frame.y + object.frame.height))
                }
                try scene.validate()
                scenes["\(book.id.uuidString)/\(page.id.uuidString)"] = scene
            }
        }
        return scenes
    }
}

// A single persisted journal retains legacy authority and pending receipt IDs
// across migration, partial Sync and connection loss. No cleared-baseline reset.
struct SyncJournal: Codable {
    var documents: [String: DocumentSyncBaseline] = [:]
    var folders: [Folder]? = nil
    var legacy: SyncBaseline? = nil
    var legacyInvalidated = false
    var pendingDocuments: [String: PendingDocumentSync] = [:]

    struct PendingDocumentSync: Codable {
        var syncID: UUID
        var localDigest: String
        var localBeforeDigest: String? = nil
        var download = false
    }

    static func load(in defaults: UserDefaults = .standard) throws -> SyncJournal {
        if let bytes = defaults.data(forKey: "syncJournalV2") {
            return try JSONDecoder().decode(Self.self, from: bytes)
        }
        var journal = Self()
        if let bytes = defaults.data(forKey: "syncBaseline") {
            journal.legacy = try JSONDecoder().decode(SyncBaseline.self, from: bytes)
        }
        return journal
    }

    func save(in defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: "syncJournalV2")
    }

    // Only exact old-global proof can authorize unequal local/remote copies.
    // preMigration contains native-helper-persisted hashes before recoloring.
    mutating func establishLegacy(local: SyncPackage, remote: SyncState,
                                  preMigration: [String: String] = [:]) throws {
        guard !legacyInvalidated, let legacy, let package = remote.package,
              try package.digest() == legacy.digest else { return }
        for book in package.notebooks where documents[book.id.uuidString] == nil {
            guard local.notebooks.contains(where: { $0.id == book.id }) else { continue }
            let digest = try package.document(book.id).digest()
            // Server digest is opaque. This anchor is used only by Home's
            // native comparison until a document route confirms its wire hash.
            // Never bless unsynced pre-migration edits as baseline. Only a
            // pre-migration doc equal to the proved server copy can be an anchor.
            documents[book.id.uuidString] = DocumentSyncBaseline(serverDigest: "legacy:" + digest,
                localDigest: preMigration[book.id.uuidString] == digest ? preMigration[book.id.uuidString]! : digest,
                revision: remote.revision, lastSyncedAt: "")
        }
        folders = package.folders ?? []
    }

    func receiptIsSuperseded(_ receipt: DocumentSyncReceipt, document: UUID, localDigest: String) throws -> Bool {
        guard let baseline = documents[document.uuidString] else { return false }
        if baseline.revision != receipt.revision { return baseline.revision > receipt.revision }
        if baseline.localDigest != localDigest { return true }
        if !baseline.serverDigest.hasPrefix("legacy:"), baseline.serverDigest != receipt.documentDigest { return true }
        guard !baseline.lastSyncedAt.isEmpty else { return false }
        func date(_ value: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
        guard let acknowledged = date(baseline.lastSyncedAt), let pending = date(receipt.lastSyncedAt) else {
            throw SyncError.conflict // Unknown ordering cannot lower acknowledged freshness.
        }
        return acknowledged > pending
    }

    // A document receipt confirms only its ancestor closure. Preserve unrelated
    // anchors, including pending local deletions. nil remains globally unknown.
    mutating func confirmTargetFolder(in source: SyncPackage) {
        guard var baseline = folders,
              let closure = try? Folder.ancestorClosure(of: source.notebooks.first?.folderID, in: source.folders ?? []) else { return }
        for confirmed in closure {
            if let index = baseline.firstIndex(where: { $0.id == confirmed.id }) { baseline[index] = confirmed }
            else { baseline.append(confirmed) }
        }
        folders = baseline
    }

    static func folderDigest(_ folders: [Folder]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SyncObjects.digest(try encoder.encode(folders.sorted { $0.id.uuidString < $1.id.uuidString }))
    }

    // Pick each document independently. Remote-only documents and empty folders
    // survive. Stale local copies never get blessed by a partial-document Sync.
    func reconcile(local: SyncPackage, remote: SyncState) throws -> SyncPackage {
        let server = remote.package ?? SyncPackage(notebooks: [], blobs: [:])
        var chosen: [Notebook] = []
        let ids = local.notebooks.map(\.id) + server.notebooks.map(\.id).filter { id in !local.notebooks.contains(where: { $0.id == id }) }
        for id in ids {
            let localBook = local.notebooks.first { $0.id == id }
            let remoteBook = server.notebooks.first { $0.id == id }
            guard let localBook else { chosen.append(remoteBook!); continue }
            guard let remoteBook else {
                guard documents[id.uuidString] == nil else { throw SyncError.conflict }
                chosen.append(localBook); continue
            }
            let l = try local.document(id).digest(), r = try server.document(id).digest()
            if l == r { chosen.append(localBook); continue }
            guard let baseline = documents[id.uuidString], remote.revision >= baseline.revision else { throw SyncError.conflict }
            let remoteBase = baseline.serverDigest.hasPrefix("legacy:")
                ? String(baseline.serverDigest.dropFirst(7)) : baseline.localDigest
            // The current remote native digest is remembered separately once a
            // document receipt is fetched. Wire hashes cannot substitute for it.
            let remoteChanged = r != (remoteLocalDigests[id.uuidString] ?? remoteBase)
            let localChanged = l != baseline.localDigest
            if !remoteChanged { chosen.append(localBook) }
            else if !localChanged { chosen.append(remoteBook) }
            else { throw SyncError.conflict }
        }
        let lFolders = local.folders ?? [], rFolders = server.folders ?? []
        let lHash = try Self.folderDigest(lFolders), rHash = try Self.folderDigest(rFolders)
        let mergedFolders: [Folder]
        if lHash == rHash { mergedFolders = lFolders }
        else if let folders {
            let base = try Self.folderDigest(folders)
            if lHash == base { mergedFolders = rFolders }
            else if rHash == base { mergedFolders = lFolders }
            else { throw SyncError.conflict }
        } else if server.notebooks.isEmpty && rFolders.isEmpty { mergedFolders = lFolders }
        else if local.notebooks.isEmpty && lFolders.isEmpty { mergedFolders = rFolders }
        else { throw SyncError.conflict }
        return try SyncPackage.combine(chosen, sources: [local, server], folders: mergedFolders)
    }

    // Native digest of remote package at confirmation; opaque wire digest stays
    // in DocumentSyncBaseline. This avoids cross-language JSON canonicalization.
    var remoteLocalDigests: [String: String] = [:]
}
