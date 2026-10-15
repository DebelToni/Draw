import Foundation

// Both services share a private origin and credential, but never a source route.
enum DrawEndpoints {
    static let sync = URL(string: "https://draw.example.invalid/draw-sync/v1/state")!
    static let manager = sync.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("draw-ai")

    static func configured(_ service: String) -> URL {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-fixture"),
           let raw = ProcessInfo.processInfo.environment[service == "ai" ? "DRAW_AI_FIXTURE_URL" : "DRAW_SYNC_FIXTURE_URL"],
           let url = URL(string: raw), ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
           ["http", "https"].contains(url.scheme ?? "") { return url }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-fixture") {
            return service == "ai" ? URL(string: "http://127.0.0.1:48281")! : URL(string: "http://127.0.0.1:48279/v1/state")!
        }
        #endif
        return service == "ai" ? manager : sync
    }

    static var token: String {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-fixture") {
            return ProcessInfo.processInfo.environment["DRAW_FIXTURE_TOKEN"] ?? "draw-ai-fixture-only"
        }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "DrawSyncToken") as? String ?? ""
    }
}

enum AIClientError: LocalizedError {
    case invalidResponse, server(Int, String), notForeground
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The AI answer could not be verified. Your notes were not replaced."
        case .server(_, let message): return message
        case .notForeground: return "Open Draw to finish this request."
        }
    }
}

struct AIRequestReceipt: Codable {
    var requestID: UUID
    var documentID: UUID
    var status: String
    var resultSHA256: String?
    var updatedAt: String?
    // Service errors are structured, not inferred from terminal output.
    var error: AIServiceError?
}

struct AIServiceError: Codable { var code: String; var message: String }

struct AIRequestSubmission: Codable {
    var requestID: UUID
    var documentID: UUID
    var focusPageID: UUID
    var contextSHA256: String
    var origin = "app"
    var clientID: UUID
}

// Network retry identity is independent of Undo. Asset files are immutable, and
// the small journal is atomic before a request/ack can leave this installation.
final class AINetworkJournal {
    struct State: Codable {
        var clientID = UUID()
        var pending: [String: AIRequestSubmission] = [:]
        var applyAckIDs: [UUID] = []
    }
    private let root: URL
    private let file: URL
    private(set) var state: State

    init(directory: URL? = nil) throws {
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Draw/ai-network", isDirectory: true)
        file = root.appendingPathComponent("journal.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        } else {
            state = State()
            try persist(state)
        }
    }

    private func persist(_ candidate: State) throws {
        try JSONEncoder().encode(candidate).write(to: file, options: .atomic)
    }

    func prepare(documentID: UUID, focusPageID: UUID, context: Data, assets: [String: Data]) throws -> AIRequestSubmission {
        if let existing = state.pending[documentID.uuidString] { return existing }
        var all = assets
        let sha = SyncObjects.digest(context)
        all[sha] = context
        for (digest, bytes) in all {
            guard SyncObjects.validDigest(digest), SyncObjects.digest(bytes) == digest,
                  bytes.count <= SyncObjects.objectLimit else { throw AIClientError.invalidResponse }
            try bytes.write(to: root.appendingPathComponent(digest), options: .atomic)
        }
        // Keep the exact captured CAS key set for explicit connection-loss retry.
        let submission = AIRequestSubmission(requestID: UUID(), documentID: documentID,
            focusPageID: focusPageID, contextSHA256: sha, clientID: state.clientID)
        try JSONEncoder().encode(all.keys.sorted()).write(to: root.appendingPathComponent(submission.requestID.uuidString + ".json"), options: .atomic)
        var candidate = state
        candidate.pending[documentID.uuidString] = submission
        try persist(candidate)
        state = candidate
        return submission
    }

    // Exact single-document native source is a local receipt-recovery cache,
    // separate from request assets. No native archive is sent to Notes CAS.
    func stageCommittedSource(_ package: SyncPackage, syncID: UUID) throws {
        try package.validate()
        guard package.notebooks.count == 1 else { throw SyncError.invalidPackage }
        let file = root.appendingPathComponent(syncID.uuidString + ".sync-source.json")
        let bytes = try package.encoded()
        if FileManager.default.fileExists(atPath: file.path) {
            guard try Data(contentsOf: file) == bytes else { throw SyncError.conflict }
        } else { try bytes.write(to: file, options: .atomic) }
    }

    func committedSource(syncID: UUID) throws -> SyncPackage? {
        let file = root.appendingPathComponent(syncID.uuidString + ".sync-source.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let source = try JSONDecoder().decode(SyncPackage.self, from: Data(contentsOf: file))
        try source.validate()
        guard source.notebooks.count == 1 else { throw SyncError.invalidPackage }
        return source
    }

    func assets(for submission: AIRequestSubmission) throws -> [String: Data] {
        let keys = try JSONDecoder().decode([String].self,
            from: Data(contentsOf: root.appendingPathComponent(submission.requestID.uuidString + ".json")))
        var assets: [String: Data] = [:]
        for key in keys {
            guard SyncObjects.validDigest(key) else { throw AIClientError.invalidResponse }
            let bytes = try Data(contentsOf: root.appendingPathComponent(key))
            guard SyncObjects.digest(bytes) == key else { throw AIClientError.invalidResponse }
            assets[key] = bytes
        }
        return assets
    }

    func finish(_ requestID: UUID, needsAck: Bool) throws {
        var candidate = state
        candidate.pending = candidate.pending.filter { $0.value.requestID != requestID }
        if needsAck && !candidate.applyAckIDs.contains(requestID) { candidate.applyAckIDs.append(requestID) }
        try persist(candidate)
        state = candidate
    }

    func acknowledged(_ requestID: UUID) throws {
        var candidate = state
        candidate.applyAckIDs.removeAll { $0 == requestID }
        try persist(candidate)
        state = candidate
    }
}

final class AIClient {
    private let endpoint: URL
    private let token: String
    private let session: URLSession
    private let ownsSession: Bool
    private let webSocketSession: URLSession
    private let ownsWebSocketSession: Bool

    init(endpoint: URL = DrawEndpoints.manager, token: String, session: URLSession? = nil,
         webSocketSession: URLSession? = nil) {
        self.endpoint = endpoint
        self.token = token
        ownsSession = session == nil
        ownsWebSocketSession = webSocketSession == nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 8
        self.session = session ?? URLSession(configuration: configuration)
        // Resource timeout covers a WebSocket's entire connection lifetime,
        // not each received message. Keep bounded HTTP and foreground sockets
        // on separate transports; background still closes the channel promptly.
        let socketConfiguration = URLSessionConfiguration.ephemeral
        socketConfiguration.urlCache = nil
        socketConfiguration.waitsForConnectivity = false
        socketConfiguration.timeoutIntervalForRequest = 30
        socketConfiguration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        self.webSocketSession = webSocketSession ?? URLSession(configuration: socketConfiguration)
    }

    // Each injected session belongs to its caller, even if both are the same.
    deinit {
        if ownsSession { session.invalidateAndCancel() }
        if ownsWebSocketSession { webSocketSession.invalidateAndCancel() }
    }

    private func url(_ path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1)
        var components = URLComponents(url: endpoint.appendingPathComponent(String(parts[0])), resolvingAgainstBaseURL: false)!
        if parts.count == 2 { components.percentEncodedQuery = String(parts[1]) }
        return components.url!
    }

    private func authorized(_ path: String, method: String, body: Data? = nil, object: Bool = false) throws -> URLRequest {
        guard !token.isEmpty, !token.hasPrefix("$(") else { throw SyncError.missingToken }
        guard (body?.count ?? 0) <= (object ? SyncObjects.objectLimit : SyncObjects.metadataLimit) else { throw SyncError.tooLarge }
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(object ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         object: Bool = false, digest: String? = nil, maxBytes: Int? = nil) async throws -> Data {
        try Task.checkCancellation()
        let request = try authorized(path, method: method, body: body, object: object)
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIClientError.invalidResponse }
        let limit = min(maxBytes ?? SyncObjects.objectLimit, object ? SyncObjects.objectLimit : SyncObjects.metadataLimit)
        guard response.expectedContentLength <= Int64(limit) else { throw SyncError.tooLarge }
        var data = Data()
        for try await byte in stream {
            guard data.count < limit else { throw SyncError.tooLarge }
            data.append(byte)
        }
        guard (200...299).contains(http.statusCode) else {
            struct Failure: Decodable { var error: AIServiceError }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error.message
                ?? "DGX could not complete the AI request (HTTP \(http.statusCode)). Your notes are safe."
            throw AIClientError.server(http.statusCode, message)
        }
        if let digest {
            guard SyncObjects.validDigest(digest), SyncObjects.digest(data) == digest else { throw AIClientError.invalidResponse }
        }
        return data
    }

    private func json<T: Decodable>(_ type: T.Type, path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let bytes = try await request(path, method: method, body: body)
        do { return try JSONDecoder().decode(type, from: bytes) }
        catch { throw AIClientError.invalidResponse }
    }

    func register(_ clientID: UUID) async throws {
        struct Registration: Encodable { var clientID: UUID }
        _ = try await request("v1/clients/register", method: "POST", body: JSONEncoder().encode(Registration(clientID: clientID)))
    }

    func uploadAssets(_ assets: [String: Data]) async throws {
        struct MissingRequest: Encodable { var digests: [String] }
        struct Missing: Decodable { var missing: [String] }
        struct Receipt: Decodable { var sha256: String }
        for (sha, bytes) in assets {
            try Task.checkCancellation()
            guard SyncObjects.validDigest(sha), SyncObjects.digest(bytes) == sha,
                  bytes.count <= SyncObjects.objectLimit else { throw AIClientError.invalidResponse }
        }
        let missing = try await json(Missing.self, path: "v1/assets/missing", method: "POST",
            body: JSONEncoder().encode(MissingRequest(digests: assets.keys.sorted()))).missing
        guard Set(missing).count == missing.count, missing.allSatisfy({ assets[$0] != nil }) else { throw AIClientError.invalidResponse }
        func upload(_ sha: String) async throws {
            try Task.checkCancellation()
            let data = try await request("v1/assets/" + sha, method: "PUT", body: assets[sha], object: true,
                                         maxBytes: SyncObjects.metadataLimit)
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.sha256 == sha else {
                throw AIClientError.invalidResponse
            }
        }
        // Eight immutable bodies in flight, replenished only after completion.
        // Throwing/cancellation cancels siblings; an explicit retry asks the
        // missing endpoint again and reuses whatever CAS already accepted.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var remaining = missing.sorted().makeIterator()
            for _ in 0..<min(8, missing.count) {
                if let sha = remaining.next() { group.addTask { try await upload(sha) } }
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                if let sha = remaining.next() { group.addTask { try await upload(sha) } }
            }
        }
        try Task.checkCancellation()
    }

    func submit(_ submission: AIRequestSubmission) async throws -> AIRequestReceipt {
        let receipt = try await json(AIRequestReceipt.self, path: "v1/requests", method: "POST", body: JSONEncoder().encode(submission))
        guard receipt.requestID == submission.requestID, receipt.documentID == submission.documentID else { throw AIClientError.invalidResponse }
        return receipt
    }

    func status(_ requestID: UUID) async throws -> AIRequestReceipt {
        let receipt = try await json(AIRequestReceipt.self, path: "v1/requests/" + requestID.uuidString)
        guard receipt.requestID == requestID else { throw AIClientError.invalidResponse }
        return receipt
    }

    func retry(_ requestID: UUID) async throws -> AIRequestReceipt {
        let receipt = try await json(AIRequestReceipt.self, path: "v1/requests/" + requestID.uuidString + "/retry",
            method: "POST", body: Data("{\"choice\":\"resume\"}".utf8))
        guard receipt.requestID == requestID else { throw AIClientError.invalidResponse }
        return receipt
    }

    func ready(documentID: UUID, clientID: UUID) async throws -> [AIRequestReceipt] {
        struct Ready: Decodable { var requests: [AIRequestReceipt] }
        // Query is assembled locally; no server-supplied URL is followed.
        let receipts = try await json(Ready.self, path: "v1/documents/" + documentID.uuidString + "/ready?clientID=" + clientID.uuidString).requests
        guard receipts.allSatisfy({ $0.documentID == documentID }) else { throw AIClientError.invalidResponse }
        return receipts
    }

    func download(_ sha: String, maxBytes: Int = SyncObjects.objectLimit) async throws -> Data {
        guard SyncObjects.validDigest(sha), maxBytes > 0 else { throw AIClientError.invalidResponse }
        return try await request("v1/assets/" + sha, object: true, digest: sha, maxBytes: maxBytes)
    }

    func acknowledge(_ receipt: AIApplyReceipt, clientID: UUID) async throws {
        struct Ack: Encodable { var clientID: UUID; var receipt: AIApplyReceipt }
        _ = try await request("v1/requests/" + receipt.requestID.uuidString + "/applied", method: "POST",
            body: JSONEncoder().encode(Ack(clientID: clientID, receipt: receipt)))
    }

    func syncStarted(requestID: UUID, clientID: UUID) async throws -> AIRequestReceipt {
        struct Started: Encodable { var clientID: UUID }
        let receipt = try await json(AIRequestReceipt.self, path: "v1/requests/" + requestID.uuidString + "/sync-started",
            method: "POST", body: JSONEncoder().encode(Started(clientID: clientID)))
        guard receipt.requestID == requestID, ["synchronizing", "ready"].contains(receipt.status) else { throw AIClientError.invalidResponse }
        return receipt
    }

    func syncReady(requestID: UUID, clientID: UUID, syncID: UUID, contextSHA256: String) async throws -> AIRequestReceipt {
        struct Ready: Encodable { var clientID: UUID; var syncID: UUID; var contextSHA256: String }
        return try await json(AIRequestReceipt.self, path: "v1/requests/" + requestID.uuidString + "/sync-ready", method: "POST",
            body: JSONEncoder().encode(Ready(clientID: clientID, syncID: syncID, contextSHA256: contextSHA256)))
    }

    func channel(clientID: UUID) throws -> URLSessionWebSocketTask {
        // URLSessionWebSocketTask performs the authenticated GET upgrade.
        var request = try authorized("v1/clients/" + clientID.uuidString + "/channel", method: "GET")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        request.url = components.url
        return webSocketSession.webSocketTask(with: request)
    }
}

struct AIChannelCommand: Decodable {
    var kind: String
    var requestID: UUID
    var documentID: UUID
    var focusPageID: UUID? = nil
}

@MainActor
final class AIForegroundChannel {
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var documentID: UUID?
    private var foreground = false

    func open(_ id: UUID?) {
        documentID = id
        sendOpen()
    }

    func start(client: AIClient, clientID: UUID, onSync: @escaping @MainActor (AIChannelCommand) async -> Void) throws {
        guard !foreground else { return }
        foreground = true
        let socket = try client.channel(clientID: clientID)
        self.socket = socket
        socket.resume()
        sendOpen()
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let bytes: Data
                    switch message {
                    case .data(let data): bytes = data
                    case .string(let text): bytes = Data(text.utf8)
                    @unknown default: throw AIClientError.invalidResponse
                    }
                    guard bytes.count <= SyncObjects.metadataLimit else { throw SyncError.tooLarge }
                    let command = try JSONDecoder().decode(AIChannelCommand.self, from: bytes)
                    guard self?.foreground == true else { return }
                    if command.kind == "sync_document" { await onSync(command) }
                }
            } catch {
                // No reconnect, HTTP idle polling or automatic upload fallback.
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private func sendOpen() {
        guard let socket else { return }
        struct Open: Encodable {
            var kind = "open"
            var documentID: UUID?
            enum CodingKeys: String, CodingKey { case kind, documentID }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(kind, forKey: .kind)
                try c.encode(documentID, forKey: .documentID)
            }
        }
        guard let bytes = try? JSONEncoder().encode(Open(documentID: documentID)) else { return }
        Task { try? await socket.send(.string(String(decoding: bytes, as: UTF8.self))) }
    }

    func stop() {
        foreground = false
        receiver?.cancel()
        receiver = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }
}
