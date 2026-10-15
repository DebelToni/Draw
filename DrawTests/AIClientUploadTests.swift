import XCTest
import Foundation
@testable import Draw

private final class ParallelAssetFixture {
    struct Reply { var bytes: Data; var delay: TimeInterval; var sha: String? }
    struct Snapshot { var active: Int; var peak: Int; var puts: [String]; var stored: Set<String>; var cancelled: Int; var cancellationSeconds: [TimeInterval] }
    private let lock = NSLock()
    private let assets: [String: Data]
    private var stored: Set<String>
    private var active = 0, peak = 0, cancelled = 0
    private var cancellationSeconds: [TimeInterval] = []
    private var puts: [String] = []
    private var wrongReceipt: String?
    private var delay: TimeInterval = 0.08
    private var windowArrived: (() -> Void)?

    init(assets: [String: Data], stored: Set<String> = []) { self.assets = assets; self.stored = stored }
    func configure(wrongReceipt: String? = nil, delay: TimeInterval = 0.08, windowArrived: (() -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.wrongReceipt = wrongReceipt; self.delay = delay; self.windowArrived = windowArrived
    }
    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(active: active, peak: peak, puts: puts, stored: stored, cancelled: cancelled, cancellationSeconds: cancellationSeconds)
    }
    private func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw URLError(.badServerResponse) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
    func prepare(_ request: URLRequest) throws -> Reply {
        let bytes = try body(request)
        lock.lock(); defer { lock.unlock() }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only" else { throw URLError(.userAuthenticationRequired) }
        if request.url!.lastPathComponent == "missing" {
            guard request.httpMethod == "POST" else { throw URLError(.badServerResponse) }
            let payload = try JSONDecoder().decode([String: [String]].self, from: bytes)
            guard Set(payload["digests"] ?? []) == Set(assets.keys) else { throw URLError(.badServerResponse) }
            return Reply(bytes: try JSONSerialization.data(withJSONObject: ["missing": assets.keys.filter { !stored.contains($0) }.sorted()]), delay: 0, sha: nil)
        }
        let sha = request.url!.lastPathComponent
        guard request.httpMethod == "PUT", assets[sha] == bytes, SyncObjects.digest(bytes) == sha else { throw URLError(.badServerResponse) }
        let receipt = sha == wrongReceipt ? String(repeating: "0", count: 64) : sha
        let response = try JSONSerialization.data(withJSONObject: ["sha256": receipt])
        active += 1; peak = max(peak, active); puts.append(sha)
        if active == 8 { windowArrived?() }
        return Reply(bytes: response, delay: sha == wrongReceipt ? 0.005 : delay, sha: sha)
    }
    func finish(_ sha: String, committed: Bool, cancellationAfter: TimeInterval? = nil) {
        lock.lock(); defer { lock.unlock() }
        active -= 1
        if committed { stored.insert(sha) }
        else {
            cancelled += 1
            if let cancellationAfter { cancellationSeconds.append(cancellationAfter) }
        }
    }
}

private final class ParallelAssetHTTP: URLProtocol {
    private static let registryLock = NSLock()
    private static var fixtures: [String: ParallelAssetFixture] = [:]
    private let stateLock = NSLock()
    private var finished = false
    private var fixture: ParallelAssetFixture?
    private var uploadSHA: String?
    private var uploadStartedAt: TimeInterval?
    static func set(_ fixture: ParallelAssetFixture?, host: String) {
        registryLock.lock(); defer { registryLock.unlock() }
        fixtures[host] = fixture
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        stateLock.lock()
        guard !finished else { stateLock.unlock(); return }
        Self.registryLock.lock(); let fixture = Self.fixtures[request.url!.host!]; Self.registryLock.unlock()
        do {
            let fixture = try XCTUnwrap(fixture)
            let reply = try fixture.prepare(request)
            self.fixture = fixture; uploadSHA = reply.sha
            if reply.sha != nil { uploadStartedAt = ProcessInfo.processInfo.systemUptime }
            stateLock.unlock()
            // Hold independent responses asynchronously, never serializing the
            // network window with a sleep or an unlocked mutable dictionary.
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
                stateLock.lock()
                guard !finished else { stateLock.unlock(); return }
                finished = true
                if let sha = uploadSHA { fixture.finish(sha, committed: true) }
                stateLock.unlock()
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.bytes)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            finished = true; stateLock.unlock()
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !finished else { return }
        finished = true
        if let sha = uploadSHA {
            let elapsed = uploadStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 }
            fixture?.finish(sha, committed: false, cancellationAfter: elapsed)
        }
    }
}

final class AIClientUploadTests: XCTestCase {
    private var host: String!
    private var session: URLSession!
    private var client: AIClient!
    override func setUpWithError() throws {
        host = UUID().uuidString.lowercased() + ".fixture"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ParallelAssetHTTP.self]
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
        client = AIClient(endpoint: URL(string: "https://\(host!)/draw-ai")!, token: "test-only",
                          session: session, webSocketSession: session)
    }
    override func tearDownWithError() throws {
        client = nil; session.invalidateAndCancel(); session = nil
        ParallelAssetHTTP.set(nil, host: host)
    }
    private func assets(_ count: Int) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { i in
            let data = Data("immutable-native-tile-\(i)".utf8)
            return (SyncObjects.digest(data), data)
        })
    }
    private func cancelledDrain(_ fixture: ParallelAssetFixture) async throws -> ParallelAssetFixture.Snapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while true {
            let state = fixture.snapshot
            // Task cancellation completes before Cocoa dispatches stopLoading.
            // Natural successful response timers must NOT satisfy this predicate.
            if state.active == 0 && state.cancelled > 0 { return state }
            if ProcessInfo.processInfo.systemUptime >= deadline { return state }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testMissingUploadsHaveParallelPeakAtMostEightAndExactBodies() async throws {
        let assets = assets(35), held = Set(assets.keys.sorted().prefix(3))
        let fixture = ParallelAssetFixture(assets: assets, stored: held)
        ParallelAssetHTTP.set(fixture, host: host)
        try await client.uploadAssets(assets)
        let state = fixture.snapshot
        XCTAssertGreaterThan(state.peak, 1)
        XCTAssertLessThanOrEqual(state.peak, 8)
        XCTAssertEqual(state.active, 0)
        XCTAssertEqual(Set(state.puts), Set(assets.keys).subtracting(held))
        XCTAssertEqual(state.puts.count, assets.count - held.count)
        XCTAssertEqual(state.stored, Set(assets.keys))
    }
    func testWrongReceiptCancelsWindowAndExplicitRetryReusesAcceptedCAS() async throws {
        let assets = assets(40), badSHA = assets.keys.sorted()[0]
        let fixture = ParallelAssetFixture(assets: assets)
        fixture.configure(wrongReceipt: badSHA, delay: 0.2)
        ParallelAssetHTTP.set(fixture, host: host)
        do { try await client.uploadAssets(assets); XCTFail("Wrong receipt SHA must reject the upload") }
        catch { guard case AIClientError.invalidResponse = error else { return XCTFail("Unexpected upload error type") } }
        let partial = try await cancelledDrain(fixture)
        XCTAssertLessThanOrEqual(partial.peak, 8)
        XCTAssertLessThanOrEqual(partial.puts.count, 8)
        XCTAssertEqual(partial.active, 0)
        XCTAssertGreaterThan(partial.cancelled, 0)
        XCTAssertTrue(partial.stored.contains(badSHA)) // Server accepted bytes but returned a bad receipt.
        fixture.configure()
        try await client.uploadAssets(assets) // Explicit call, never an automatic retry.
        let retried = fixture.snapshot
        let subsequent = Array(retried.puts.dropFirst(partial.puts.count))
        XCTAssertTrue(Set(subsequent).isDisjoint(with: partial.stored))
        XCTAssertEqual(retried.stored, Set(assets.keys))
        XCTAssertLessThanOrEqual(retried.peak, 8)
    }
    func testCallerCancellationDoesNotScheduleBeyondActiveWindow() async throws {
        let assets = assets(40), fixture = ParallelAssetFixture(assets: assets)
        let arrived = expectation(description: "Eight uploads are in flight")
        fixture.configure(delay: 0.5, windowArrived: { arrived.fulfill() })
        ParallelAssetHTTP.set(fixture, host: host)
        let operation = Task { try await self.client.uploadAssets(assets) }
        await fulfillment(of: [arrived], timeout: 3)
        operation.cancel()
        do { try await operation.value; XCTFail("Cancelled upload must not succeed") }
        catch { XCTAssertTrue(error is CancellationError || (error as NSError).code == URLError.cancelled.rawValue) }
        let state = try await cancelledDrain(fixture)
        XCTAssertLessThanOrEqual(state.puts.count, 8)
        XCTAssertEqual(state.active, 0)
        XCTAssertGreaterThan(state.cancelled, 0)
        XCTAssertEqual(state.cancellationSeconds.count, state.cancelled)
        XCTAssertTrue(state.cancellationSeconds.allSatisfy { $0 < 0.5 },
                      "stopLoading must arrive before held response timers complete naturally")
    }
}
