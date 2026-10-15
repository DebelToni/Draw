import XCTest
import UIKit
import PencilKit
@testable import Draw

private struct TestWireManifest: Encodable {
    var format: Int
    var notebooks: [Notebook]
    var folders: [Folder]?
    var blobs: [String: String]
    var assets: [String: String]?

    init(_ package: SyncPackage) {
        format = package.format
        notebooks = package.notebooks
        folders = package.folders
        blobs = package.blobs.mapValues { SyncObjects.digest($0) }
        assets = package.assets?.mapValues { SyncObjects.digest($0) }
    }
}

private final class AIHTTPStub: URLProtocol {
    static let lock = NSLock()
    static var handlers: [String: (URLRequest) throws -> (Int, Data)] = [:]
    private struct Pause { var path: String; var method: String?; var arrived: () -> Void; var pending: AIHTTPStub? }
    private static var pauses: [String: Pause] = [:]
    private var stopped = false

    static func pauseNext(_ host: String, path: String, method: String? = nil, arrived: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        pauses[host] = Pause(path: path, method: method, arrived: arrived)
    }

    static func resume(_ host: String) {
        lock.lock(); let pending = pauses.removeValue(forKey: host)?.pending; lock.unlock()
        pending?.deliver()
    }
    static func set(_ host: String, handler: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }; handlers[host] = handler
    }
    static func remove(_ host: String) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: host); pauses.removeValue(forKey: host)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        if var pause = Self.pauses[request.url!.host!], pause.path == request.url!.path,
           (pause.method == nil || pause.method == request.httpMethod), pause.pending == nil {
            pause.pending = self; Self.pauses[request.url!.host!] = pause
            Self.lock.unlock(); pause.arrived(); return
        }
        Self.lock.unlock()
        deliver()
    }

    private func deliver() {
        Self.lock.lock()
        let handler = stopped ? nil : Self.handlers[request.url!.host!]
        let wasStopped = stopped
        Self.lock.unlock()
        // Cancellation can drain after the owning fixture removes its host.
        guard !wasStopped, let handler else { return }
        do {
            let (status, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {
        Self.lock.lock(); stopped = true; Self.lock.unlock()
    }
}

final class AIClientTests: XCTestCase {
    private var host: String!
    private var client: AIClient!
    private var session: URLSession!
    private let fixtureLock = NSRecursiveLock()
    private var recordedRequests: [URLRequest] = []
    private var requestHandler: ((URLRequest) throws -> (Int, Data))?
    private var requests: [URLRequest] {
        fixtureLock.lock(); defer { fixtureLock.unlock() }
        return recordedRequests
    }
    private var handler: ((URLRequest) throws -> (Int, Data))? {
        get { fixtureLock.lock(); defer { fixtureLock.unlock() }; return requestHandler }
        set { fixtureLock.lock(); defer { fixtureLock.unlock() }; requestHandler = newValue }
    }

    override func setUpWithError() throws {
        host = UUID().uuidString.lowercased() + ".fixture"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AIHTTPStub.self]
        session = URLSession(configuration: config)
        client = AIClient(endpoint: URL(string: "https://\(host!)/draw-ai")!, token: "test-only", session: session, webSocketSession: session)
        AIHTTPStub.set(host) { [unowned self] request in
            self.fixtureLock.lock(); defer { self.fixtureLock.unlock() }
            self.recordedRequests.append(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
            return try self.handler?(request) ?? (200, Data("{}".utf8))
        }
    }

    override func tearDownWithError() throws {
        client = nil
        session.invalidateAndCancel(); session = nil
        AIHTTPStub.remove(host)
    }

    private func body(_ request: URLRequest) throws -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n >= 0 else { throw AIClientError.invalidResponse }
            if n == 0 { break }
            bytes.append(contentsOf: buffer.prefix(n))
        }
        return bytes
    }

    func testReadyUsesRealQueryAndNeverStartsInferenceOrUploads() async throws {
        let documentID = UUID(), clientID = UUID()
        handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url!.path, "/draw-ai/v1/documents/\(documentID.uuidString)/ready")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "clientID", value: clientID.uuidString)])
            return (200, Data("{\"requests\":[]}".utf8))
        }
        let ready = try await client.ready(documentID: documentID, clientID: clientID)
        XCTAssertTrue(ready.isEmpty)
        XCTAssertEqual(requests.count, 1)
    }

    func testInjectedClientDeinitPreservesSharedInFlightAndFutureHTTPRequests() async throws {
        let endpoint = URL(string: "https://\(host!)/draw-ai")!
        var departingAI: AIClient? = AIClient(endpoint: endpoint, token: "test-only", session: session, webSocketSession: session)
        var departingSync: SyncClient? = SyncClient(endpoint: URL(string: "https://\(host!)/draw-sync/v1/state")!,
                                                   token: "test-only", session: session)
        weak var weakAI = departingAI
        weak var weakSync = departingSync
        let survivor = AIClient(endpoint: endpoint, token: "test-only", session: session, webSocketSession: session)
        let document = UUID(), installation = UUID()
        handler = { _ in (200, Data("{\"requests\":[]}".utf8)) }
        let arrived = expectation(description: "Other client's request is in flight")
        AIHTTPStub.pauseNext(host, path: "/draw-ai/v1/documents/" + document.uuidString + "/ready") { arrived.fulfill() }
        defer { AIHTTPStub.resume(host) }
        let operation = Task { try await survivor.ready(documentID: document, clientID: installation) }
        await fulfillment(of: [arrived], timeout: 2)
        departingAI = nil
        departingSync = nil
        XCTAssertTrue(weakAI == nil && weakSync == nil, "Both clients must actually deinitialize")
        AIHTTPStub.resume(host)
        let ready = try await operation.value
        XCTAssertTrue(ready.isEmpty)
        var raw = URLRequest(url: endpoint.appendingPathComponent("driver"))
        raw.setValue("Bearer test-only", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: raw)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let subsequent = try await survivor.ready(documentID: document, clientID: installation)
        XCTAssertTrue(subsequent.isEmpty)
    }

    @MainActor
    func testOffWindowNetworkFailureIsCollectedWithoutPresentingAlert() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root.appendingPathComponent("notes"))
        let doc = try store.addNotebook("Error collector fixture")
        let requestID = UUID()
        var failures: [(domain: String, code: Int, title: String)] = []
        handler = { request in
            if request.url!.path.hasSuffix("/sync-started") { throw URLError(.networkConnectionLost) }
            return (200, Data("{\"requests\":[]}".utf8))
        }
        let controller = DrawController(store: store, aiClient: client,
            syncClient: SyncClient(endpoint: URL(string: "https://\(host!)/draw-sync/v1/state")!, token: "test-only", session: session),
            aiJournal: try AINetworkJournal(directory: root.appendingPathComponent("network")), onError: { error, title in
                let failure = error as NSError
                failures.append((failure.domain, failure.code, title))
            })
        controller.loadViewIfNeeded(); controller.becomeForeground()
        defer { controller.enterBackground() }
        XCTAssertNil(controller.view.window)
        await controller.handleSyncCommand(AIChannelCommand(kind: "sync_document", requestID: requestID, documentID: doc))
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.domain, NSURLErrorDomain)
        XCTAssertEqual(failures.first?.code, URLError.networkConnectionLost.rawValue)
        XCTAssertEqual(failures.first?.title, "Sync unsuccessful")
        XCTAssertNil(controller.presentedViewController)
        // The same off-window failure is also safe with normal presentation policy.
        let unobserved = DrawController(store: store, aiClient: client,
            syncClient: SyncClient(endpoint: URL(string: "https://\(host!)/draw-sync/v1/state")!, token: "test-only", session: session),
            aiJournal: try AINetworkJournal(directory: root.appendingPathComponent("unobserved-network")))
        unobserved.loadViewIfNeeded(); unobserved.becomeForeground()
        defer { unobserved.enterBackground() }
        await unobserved.handleSyncCommand(AIChannelCommand(kind: "sync_document", requestID: UUID(), documentID: doc))
        XCTAssertNil(unobserved.presentedViewController)
        XCTAssertEqual(store.notebook(doc)?.pages.count, 1)
    }

    @MainActor
    private func controllerButton(_ controller: DrawController, matching: (UIButton) -> Bool) throws -> UIButton {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        return try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first(where: matching))
    }

    @MainActor
    func testAutomaticReadyOfflineIsQuietAndRegistrationDoesNotRepeatCheckButExplicitAskReports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root.appendingPathComponent("notes"))
        let doc = try store.addNotebook("Foreground fixture", orientation: DocumentOrientation.saved().rawValue)
        let journal = try AINetworkJournal(directory: root.appendingPathComponent("network"))
        let registered = expectation(description: "Registration paused")
        let ready = expectation(description: "Automatic ready outage")
        let explicitError = expectation(description: "Explicit AI outage is visible")
        var failures: [String] = []
        handler = { request in
            if request.url!.path.hasSuffix("/ready") { ready.fulfill(); throw URLError(.notConnectedToInternet) }
            return (200, Data("{}".utf8))
        }
        let controller = DrawController(store: store, aiClient: client, aiJournal: journal, onError: { _, title in
            failures.append(title); explicitError.fulfill()
        })
        controller.loadViewIfNeeded()
        AIHTTPStub.pauseNext(host, path: "/draw-ai/v1/clients/register") { registered.fulfill() }
        defer { AIHTTPStub.resume(host); controller.enterBackground() }
        controller.becomeForeground()
        await fulfillment(of: [registered], timeout: 2)
        try controllerButton(controller) { $0.currentTitle?.contains("Foreground fixture") == true }.sendActions(for: .touchUpInside)
        await fulfillment(of: [ready], timeout: 2)
        AIHTTPStub.resume(host)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/ready") }.count, 1)
        // A structured pending submission avoids capture and tests the real button retry path.
        let pending = try journal.prepare(documentID: doc, focusPageID: store.notebook(doc)!.pages[0].id,
                                          context: Data("{}".utf8), assets: [:])
        handler = { _ in throw URLError(.notConnectedToInternet) }
        try controllerButton(controller) { $0.accessibilityIdentifier == "askAI" }.sendActions(for: .touchUpInside)
        await fulfillment(of: [explicitError], timeout: 2)
        XCTAssertEqual(failures, ["AI unavailable"])
        XCTAssertEqual(journal.state.pending[doc.uuidString]?.requestID, pending.requestID)
        XCTAssertFalse(requests.contains { $0.url!.path.contains("/assets/") || $0.url!.path == "/draw-ai/v1/requests" })
    }

    @MainActor
    func testRecoveredMissingRequestIsQuietAcrossForegroundCyclesAndKeepsExactRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root.appendingPathComponent("notes"))
        let doc = try store.addNotebook("Missing recovery", orientation: DocumentOrientation.saved().rawValue)
        let journal = try AINetworkJournal(directory: root.appendingPathComponent("network"))
        let pending = try journal.prepare(documentID: doc, focusPageID: store.notebook(doc)!.pages[0].id,
                                          context: Data("{}".utf8), assets: [:])
        let assets = try journal.assets(for: pending)
        var failures: [String] = []
        handler = { request in
            if request.url!.path == "/draw-ai/v1/requests/" + pending.requestID.uuidString {
                return (404, Data("{\"error\":{\"code\":\"not_found\",\"message\":\"Request not found\"}}".utf8))
            }
            return (200, Data((request.url!.path.hasSuffix("/ready") ? "{\"requests\":[]}" : "{}").utf8))
        }
        let controller = DrawController(store: store, aiClient: client, aiJournal: journal,
                                        onError: { _, title in failures.append(title) })
        controller.loadViewIfNeeded()
        defer { controller.enterBackground() }
        for _ in 0..<3 {
            let arrived = expectation(description: "Recovered missing status")
            AIHTTPStub.pauseNext(host, path: "/draw-ai/v1/requests/" + pending.requestID.uuidString) { arrived.fulfill() }
            controller.becomeForeground()
            await fulfillment(of: [arrived], timeout: 2)
            let polls = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "aiPolls" }?.value
                as? [UUID: (id: UUID, task: Task<Void, Never>)])
            let poll = try XCTUnwrap(polls[pending.requestID]).task
            AIHTTPStub.resume(host)
            await poll.value
            XCTAssertTrue(failures.isEmpty)
            XCTAssertEqual(journal.state.pending[doc.uuidString]?.requestID, pending.requestID)
            XCTAssertEqual(try journal.assets(for: pending), assets)
            XCTAssertEqual(try AINetworkJournal(directory: root.appendingPathComponent("network")).state.pending[doc.uuidString]?.requestID,
                           pending.requestID)
            controller.enterBackground()
        }
        XCTAssertFalse(requests.contains { $0.httpMethod != "GET" && $0.url!.path != "/draw-ai/v1/clients/register" })
    }

    @MainActor
    func testRecoveredRealFailureIsReportedOnceAndMissingApprovedResultStaysVisible() async throws {
        for status in ["failed", "ready"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = Store(directory: root.appendingPathComponent("notes"))
            let doc = try store.addNotebook("Real recovery failure", orientation: DocumentOrientation.saved().rawValue)
            let journal = try AINetworkJournal(directory: root.appendingPathComponent("network"))
            let pending = try journal.prepare(documentID: doc, focusPageID: store.notebook(doc)!.pages[0].id,
                                              context: Data("{}".utf8), assets: [:])
            let reported = expectation(description: "Genuine failure remains visible")
            var failures: [String] = []
            handler = { request in
                if request.url!.path == "/draw-ai/v1/requests/" + pending.requestID.uuidString {
                    let receipt = AIRequestReceipt(requestID: pending.requestID, documentID: doc, status: status,
                        resultSHA256: status == "ready" ? String(repeating: "a", count: 64) : nil,
                        error: status == "failed" ? AIServiceError(code: "page_output_missing", message: "Worker ended without approved page output") : nil)
                    return (200, try JSONEncoder().encode(receipt))
                }
                if request.url!.path.contains("/assets/") {
                    return (404, Data("{\"error\":{\"code\":\"not_found\",\"message\":\"Result unavailable\"}}".utf8))
                }
                return (200, Data((request.url!.path.hasSuffix("/ready") ? "{\"requests\":[]}" : "{}").utf8))
            }
            let controller = DrawController(store: store, aiClient: client, aiJournal: journal,
                onError: { _, title in failures.append(title); reported.fulfill() })
            controller.loadViewIfNeeded()
            controller.becomeForeground()
            await fulfillment(of: [reported], timeout: 2)
            controller.enterBackground()
            XCTAssertEqual(failures, [status == "failed" ? "AI request failed" : "AI unavailable"])
            if status == "failed" {
                XCTAssertNil(journal.state.pending[doc.uuidString])
                let before = requests.filter { $0.url!.path == "/draw-ai/v1/requests/" + pending.requestID.uuidString }.count
                controller.becomeForeground()
                try await Task.sleep(nanoseconds: 100_000_000)
                controller.enterBackground()
                XCTAssertEqual(failures.count, 1)
                XCTAssertEqual(requests.filter { $0.url!.path == "/draw-ai/v1/requests/" + pending.requestID.uuidString }.count, before)
            } else {
                XCTAssertEqual(journal.state.pending[doc.uuidString]?.requestID, pending.requestID)
            }
        }
    }

    @MainActor
    func testExplicitAskMissingStatusStillReportsAndPreservesRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root.appendingPathComponent("notes"))
        let doc = try store.addNotebook("Explicit missing", orientation: DocumentOrientation.saved().rawValue)
        let journal = try AINetworkJournal(directory: root.appendingPathComponent("network"))
        let opened = expectation(description: "Initial ready discovery")
        var submission: AIRequestSubmission?
        handler = { request in
            if request.url!.path.hasSuffix("/ready") { opened.fulfill(); return (200, Data("{\"requests\":[]}".utf8)) }
            if request.url!.path.hasSuffix("/assets/missing") { return (200, Data("{\"missing\":[]}".utf8)) }
            if request.url!.path == "/draw-ai/v1/requests", let submission {
                return (200, try JSONEncoder().encode(AIRequestReceipt(requestID: submission.requestID, documentID: doc, status: "queued")))
            }
            if request.url!.path == "/draw-ai/v1/requests/" + (submission?.requestID.uuidString ?? "") {
                return (404, Data("{\"error\":{\"code\":\"not_found\",\"message\":\"Request not found\"}}".utf8))
            }
            return (200, Data("{}".utf8))
        }
        let reported = expectation(description: "Explicit missing is visible")
        var failures: [String] = []
        let controller = DrawController(store: store, aiClient: client, aiJournal: journal,
            onError: { _, title in failures.append(title); reported.fulfill() })
        controller.loadViewIfNeeded(); controller.becomeForeground()
        defer { controller.enterBackground() }
        try controllerButton(controller) { $0.currentTitle?.contains("Explicit missing") == true }.sendActions(for: .touchUpInside)
        await fulfillment(of: [opened], timeout: 2)
        submission = try journal.prepare(documentID: doc, focusPageID: store.notebook(doc)!.pages[0].id,
                                         context: Data("{}".utf8), assets: [:])
        try controllerButton(controller) { $0.accessibilityIdentifier == "askAI" }.sendActions(for: .touchUpInside)
        await fulfillment(of: [reported], timeout: 2)
        XCTAssertEqual(failures, ["AI unavailable"])
        XCTAssertEqual(journal.state.pending[doc.uuidString]?.requestID, submission?.requestID)
    }

    @MainActor
    func testLateReadyErrorsAcrossRepeatedForegroundCyclesAreQuiet() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root.appendingPathComponent("notes"))
        let doc = try store.addNotebook("Ready lifecycle", orientation: DocumentOrientation.saved().rawValue)
        var failures: [String] = []
        let controller = DrawController(store: store, aiClient: client,
            aiJournal: try AINetworkJournal(directory: root.appendingPathComponent("network")), onError: { _, title in failures.append(title) })
        controller.loadViewIfNeeded()
        try controllerButton(controller) { $0.currentTitle?.contains("Ready lifecycle") == true }.sendActions(for: .touchUpInside)
        defer { AIHTTPStub.resume(host); controller.enterBackground() }
        for error: Error? in [URLError(.cancelled), AIClientError.notForeground, AIClientError.invalidResponse, nil] {
            let arrived = expectation(description: "Old ready paused")
            AIHTTPStub.pauseNext(host, path: "/draw-ai/v1/documents/" + doc.uuidString + "/ready") { arrived.fulfill() }
            handler = { request in
                if request.url!.path.hasSuffix("/ready") {
                    if let error { throw error }
                    return (200, try JSONSerialization.data(withJSONObject: ["requests": [["requestID": UUID().uuidString,
                        "documentID": doc.uuidString, "status": "ready", "resultSHA256": String(repeating: "a", count: 64)]]]))
                }
                return (200, Data("{}".utf8))
            }
            controller.becomeForeground()
            await fulfillment(of: [arrived], timeout: 2)
            let oldChecks = Mirror(reflecting: controller).children.first { $0.label == "aiReadyChecks" }?.value
                as? [UUID: Task<Void, Never>] ?? [:]
            // Deliver while the actor is occupied, then change cycles before its catch runs.
            AIHTTPStub.resume(host)
            controller.enterBackground()
            handler = { request in
                (200, Data((request.url!.path.hasSuffix("/ready") ? "{\"requests\":[]}" : "{}").utf8))
            }
            controller.becomeForeground()
            for check in oldChecks.values { await check.value }
            // Also run against the pre-fix controller, whose ready tasks were untracked.
            if oldChecks.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
            XCTAssertTrue(failures.isEmpty)
            XCTAssertTrue(try controllerButton(controller) { $0.accessibilityIdentifier == "askAI" }.isEnabled)
            controller.enterBackground()
        }
        XCTAssertFalse(requests.contains { $0.url!.path.contains("/assets/") || $0.url!.path == "/draw-ai/v1/requests" })
    }

    @MainActor
    func testCanceledOldPollCannotClearNewForegroundBusyStateOrPollSlot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root.appendingPathComponent("notes"))
        let doc = try store.addNotebook("Poll lifecycle", orientation: DocumentOrientation.saved().rawValue)
        let journal = try AINetworkJournal(directory: root.appendingPathComponent("network"))
        let pending = try journal.prepare(documentID: doc, focusPageID: store.notebook(doc)!.pages[0].id,
                                          context: Data("{}".utf8), assets: [:])
        var failures: [String] = []
        handler = { request in
            if request.url!.path == "/draw-ai/v1/requests/" + pending.requestID.uuidString {
                return (200, try JSONEncoder().encode(AIRequestReceipt(requestID: pending.requestID, documentID: doc, status: "running")))
            }
            return (200, Data((request.url!.path.hasSuffix("/ready") ? "{\"requests\":[]}" : "{}").utf8))
        }
        let controller = DrawController(store: store, aiClient: client, aiJournal: journal, onError: { _, title in failures.append(title) })
        controller.loadViewIfNeeded()
        try controllerButton(controller) { $0.currentTitle?.contains("Poll lifecycle") == true }.sendActions(for: .touchUpInside)
        func polls() throws -> [UUID: (id: UUID, task: Task<Void, Never>)] {
            try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "aiPolls" }?.value as? [UUID: (id: UUID, task: Task<Void, Never>)])
        }
        defer { AIHTTPStub.resume(host); controller.enterBackground() }
        for _ in 0..<3 {
            let arrived = expectation(description: "Poll paused before background")
            AIHTTPStub.pauseNext(host, path: "/draw-ai/v1/requests/" + pending.requestID.uuidString) { arrived.fulfill() }
            controller.becomeForeground()
            await fulfillment(of: [arrived], timeout: 2)
            let oldPoll = try XCTUnwrap(try polls()[pending.requestID]).task
            controller.enterBackground()
            let registered = expectation(description: "New cycle registration paused")
            AIHTTPStub.pauseNext(host, path: "/draw-ai/v1/clients/register") { registered.fulfill() }
            controller.becomeForeground()
            // New busy work is installed before the old poll can execute its defer.
            // Paused registration prevents recovery from masking a wrong busy clear.
            controller.canvasViewDidBeginUsingTool(PKCanvasView())
            try controllerButton(controller) { $0.accessibilityIdentifier == "askAI" }.sendActions(for: .touchUpInside)
            await oldPoll.value
            XCTAssertFalse(try controllerButton(controller) { $0.accessibilityIdentifier == "askAI" }.isEnabled)
            await fulfillment(of: [registered], timeout: 2)
            AIHTTPStub.resume(host)
            let newer = expectation(description: "New cycle poll paused")
            AIHTTPStub.pauseNext(host, path: "/draw-ai/v1/requests/" + pending.requestID.uuidString) { newer.fulfill() }
            await fulfillment(of: [newer], timeout: 2)
            let replacement = try XCTUnwrap(try polls()[pending.requestID])
            XCTAssertTrue(failures.isEmpty)
            XCTAssertEqual(try polls()[pending.requestID]?.id, replacement.id)
            XCTAssertFalse(try controllerButton(controller) { $0.accessibilityIdentifier == "askAI" }.isEnabled)
            XCTAssertEqual(journal.state.pending[doc.uuidString]?.requestID, pending.requestID)
            controller.enterBackground()
        }
    }

    @MainActor
    func testCanceledOldAskCannotClearNewOperationOrShowLateError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root.appendingPathComponent("notes"))
        let doc = try store.addNotebook("Ask lifecycle", orientation: DocumentOrientation.saved().rawValue)
        let journal = try AINetworkJournal(directory: root.appendingPathComponent("network"))
        let ready = expectation(description: "Initial discovery completed")
        var failures: [String] = []
        handler = { request in
            if request.url!.path.hasSuffix("/ready") { ready.fulfill(); return (200, Data("{\"requests\":[]}".utf8)) }
            return (200, Data("{}".utf8))
        }
        let controller = DrawController(store: store, aiClient: client, aiJournal: journal,
                                        onError: { _, title in failures.append(title) })
        controller.loadViewIfNeeded()
        try controllerButton(controller) { $0.currentTitle?.contains("Ask lifecycle") == true }.sendActions(for: .touchUpInside)
        controller.becomeForeground()
        await fulfillment(of: [ready], timeout: 2)
        let pending = try journal.prepare(documentID: doc, focusPageID: store.notebook(doc)!.pages[0].id,
                                          context: Data("{}".utf8), assets: [:])
        let arrived = expectation(description: "Explicit ask registration paused")
        AIHTTPStub.pauseNext(host, path: "/draw-ai/v1/clients/register") { arrived.fulfill() }
        defer { controller.enterBackground(); AIHTTPStub.resume(host) }
        let button = try controllerButton(controller) { $0.accessibilityIdentifier == "askAI" }
        button.sendActions(for: .touchUpInside)
        await fulfillment(of: [arrived], timeout: 2)
        func operations() throws -> [UUID: (id: UUID, task: Task<Void, Never>)] {
            try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "aiOperations" }?.value
                as? [UUID: (id: UUID, task: Task<Void, Never>)])
        }
        let old = try XCTUnwrap(try operations()[doc])
        controller.enterBackground()
        AIHTTPStub.resume(host)
        let registered = expectation(description: "New foreground registration paused")
        AIHTTPStub.pauseNext(host, path: "/draw-ai/v1/clients/register") { registered.fulfill() }
        controller.becomeForeground()
        // Install the replacement before yielding to the canceled ask's catch/defer.
        // Hold its capture at the real Pencil gate, without a new HTTP submission.
        controller.canvasViewDidBeginUsingTool(PKCanvasView())
        button.sendActions(for: .touchUpInside)
        let replacement = try XCTUnwrap(try operations()[doc])
        XCTAssertNotEqual(old.id, replacement.id)
        await fulfillment(of: [registered], timeout: 2)
        await old.task.value
        XCTAssertEqual(try operations()[doc]?.id, replacement.id)
        XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(journal.state.pending[doc.uuidString]?.requestID, pending.requestID)
        XCTAssertFalse(requests.contains { $0.url!.path.contains("/assets/") || $0.url!.path == "/draw-ai/v1/requests" })
    }

    @MainActor
    func testCanceledRegistrationCannotStartChannelOrRecoveryInNewCycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root.appendingPathComponent("notes"))
        let doc = try store.addNotebook("Register lifecycle")
        let journal = try AINetworkJournal(directory: root.appendingPathComponent("network"))
        _ = try journal.prepare(documentID: doc, focusPageID: store.notebook(doc)!.pages[0].id, context: Data("{}".utf8), assets: [:])
        let controller = DrawController(store: store, aiClient: client, aiJournal: journal)
        controller.loadViewIfNeeded()
        handler = { _ in (200, Data("{}".utf8)) }
        let old = expectation(description: "Old registration paused")
        AIHTTPStub.pauseNext(host, path: "/draw-ai/v1/clients/register") { old.fulfill() }
        defer { AIHTTPStub.resume(host); controller.enterBackground() }
        controller.becomeForeground()
        await fulfillment(of: [old], timeout: 2)
        let oldRegistration = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "aiRegistration" }?.value
            as? Task<Void, Never>)
        AIHTTPStub.resume(host)
        controller.enterBackground()
        let newer = expectation(description: "New registration paused")
        AIHTTPStub.pauseNext(host, path: "/draw-ai/v1/clients/register") { newer.fulfill() }
        controller.becomeForeground()
        await fulfillment(of: [newer], timeout: 2)
        await oldRegistration.value
        let newRegistration = Mirror(reflecting: controller).children.first { $0.label == "aiRegistration" }?.value as? Task<Void, Never>
        XCTAssertNotNil(newRegistration, "Old defer must leave the new registration slot intact")
        XCTAssertFalse(requests.contains { $0.url!.path.contains("/requests/") || $0.url!.path.hasSuffix("/ready") })
        let channel = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "aiChannel" }?.value as? AIForegroundChannel)
        let socket = try XCTUnwrap(Mirror(reflecting: channel).children.first { $0.label == "socket" })
        XCTAssertNil(socket.value as? URLSessionWebSocketTask)
        XCTAssertTrue(store.appliedAIRequests.isEmpty)
    }

    @MainActor
    func testCurrentReadyQueryResultAndApplyIntegrityFailuresRemainVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for failure in ["query", "result", "apply"] {
            let store = Store(directory: root.appendingPathComponent(failure + "-notes"))
            let doc = try store.addNotebook("Invalid ready", orientation: DocumentOrientation.saved().rawValue)
            let journal = try AINetworkJournal(directory: root.appendingPathComponent(failure + "-network"))
            let requestID = UUID(), pageID = store.notebook(doc)!.pages[0].id
            // Valid decoded JSON with no approved additions reaches Store.applyAI
            // and fails its integrity checks, rather than failing transport/decoding.
            let invalidApply = AIResult(requestID: requestID, documentID: doc, contextSHA256: String(repeating: "a", count: 64),
                draftVersion: 1, rendererSignature: "draw-ai-render-v1",
                pageEdits: [AIPageEdit(pageID: pageID, objectEdits: [], strokeEdits: [])],
                previewSHA256s: [pageID.uuidString: String(repeating: "b", count: 64)])
            let bytes = failure == "apply" ? try AIHash.encoded(invalidApply) : Data("invalid approved result".utf8)
            let sha = SyncObjects.digest(bytes)
            let failed = expectation(description: failure + " integrity alert")
            var failures: [String] = []
            handler = { request in
                if request.url!.path.hasSuffix("/ready") {
                    if failure == "query" { return (200, Data("{}".utf8)) }
                    return (200, try JSONSerialization.data(withJSONObject: ["requests": [["requestID": requestID.uuidString,
                        "documentID": doc.uuidString, "status": "ready", "resultSHA256": sha]]]))
                }
                if request.url!.path.hasSuffix("/" + sha) { return (200, bytes) }
                return (200, Data("{}".utf8))
            }
            let controller = DrawController(store: store, aiClient: client, aiJournal: journal, onError: { error, title in
                if failure == "apply" {
                    guard case AIError.invalidResult = error else { XCTFail("Must expose current Store.applyAI failure"); return }
                }
                failures.append(title); failed.fulfill()
            })
            controller.loadViewIfNeeded()
            try controllerButton(controller) { $0.currentTitle?.contains("Invalid ready") == true }.sendActions(for: .touchUpInside)
            let before = try store.exportCurrentPackage()
            controller.becomeForeground()
            await fulfillment(of: [failed], timeout: 2)
            XCTAssertEqual(failures, ["AI unavailable"])
            XCTAssertEqual(try store.exportCurrentPackage().encoded(), try before.encoded())
            XCTAssertTrue(store.appliedAIRequests.isEmpty)
            XCTAssertTrue(journal.state.applyAckIDs.isEmpty)
            XCTAssertFalse(requests.contains { $0.url!.path.hasSuffix("/applied") })
            controller.enterBackground()
        }
    }

    @MainActor
    func testFailedAndInterruptedActivePollsStillReportStructuredErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for status in ["failed", "interrupted"] {
            let store = Store(directory: root.appendingPathComponent(UUID().uuidString))
            let doc = try store.addNotebook("Active failure")
            let journal = try AINetworkJournal(directory: root.appendingPathComponent(UUID().uuidString))
            let pending = try journal.prepare(documentID: doc, focusPageID: store.notebook(doc)!.pages[0].id,
                                              context: Data("{}".utf8), assets: [:])
            let failed = expectation(description: status + " remains visible")
            var titles: [String] = []
            handler = { request in
                if request.url!.path == "/draw-ai/v1/requests/" + pending.requestID.uuidString {
                    return (200, try JSONEncoder().encode(AIRequestReceipt(requestID: pending.requestID, documentID: doc,
                        status: status, error: AIServiceError(code: status, message: "Structured failure"))))
                }
                return (200, Data("{}".utf8))
            }
            let controller = DrawController(store: store, aiClient: client, aiJournal: journal, onError: { error, title in
                XCTAssertTrue(error is AIClientError); titles.append(title); failed.fulfill()
            })
            controller.loadViewIfNeeded(); controller.becomeForeground()
            await fulfillment(of: [failed], timeout: 2)
            XCTAssertEqual(titles, [status == "failed" ? "AI request failed" : "AI unavailable"])
            XCTAssertEqual(journal.state.pending[doc.uuidString] != nil, status == "interrupted")
            XCTAssertFalse(requests.contains { $0.url!.path.hasSuffix("/retry") })
            controller.enterBackground()
        }
    }

    func testMissingCASUploadsOnlyExactRequestedBytesViaPUT() async throws {
        let bytes = Data("native context bytes".utf8), other = Data("already held".utf8)
        let sha = SyncObjects.digest(bytes), otherSHA = SyncObjects.digest(other)
        handler = { request in
            if request.url!.lastPathComponent == "missing" {
                let json = try JSONSerialization.jsonObject(with: self.body(request)) as! [String: [String]]
                XCTAssertEqual(Set(json["digests"]!), [sha, otherSHA])
                return (200, try JSONSerialization.data(withJSONObject: ["missing": [sha]]))
            }
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url!.lastPathComponent, sha)
            XCTAssertEqual(try self.body(request), bytes)
            return (200, try JSONSerialization.data(withJSONObject: ["sha256": sha]))
        }
        try await client.uploadAssets([sha: bytes, otherSHA: other])
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains { $0.url!.path.contains("draw-sync") })
    }

    func testCorruptCASAndUnknownMissingKeysAreRejected() async throws {
        let sha = SyncObjects.digest(Data("good".utf8))
        handler = { _ in (200, Data("corrupt".utf8)) }
        do { _ = try await client.download(sha); XCTFail("accepted corrupt CAS") } catch {}
        handler = { _ in (200, Data("{\"missing\":[\"unknown\"]}".utf8)) }
        do { try await client.uploadAssets([sha: Data("good".utf8)]); XCTFail("accepted missing key") } catch {}
        XCTAssertEqual(requests.count, 2)
        do { try await client.uploadAssets([sha: Data("changed".utf8)]); XCTFail("accepted wrong local hash") } catch {}
        XCTAssertEqual(requests.count, 2)
    }

    func testWebSocketIsAuthenticatedGETAtClientChannelNotIdleHTTPPoll() throws {
        let id = UUID()
        let socket = try client.channel(clientID: id)
        defer { socket.cancel(with: .goingAway, reason: nil) }
        let request = try XCTUnwrap(socket.originalRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url!.scheme, "wss")
        XCTAssertEqual(request.url!.path, "/draw-ai/v1/clients/\(id.uuidString)/channel")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
        XCTAssertTrue(requests.isEmpty)
    }

    func testRequestAndApplyAckIdentitiesSurviveCrashAndNewInk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AINetworkJournal(directory: directory)
        let doc = UUID(), page = UUID(), png = Data("image".utf8)
        let submission = try journal.prepare(documentID: doc, focusPageID: page,
            context: Data("first snapshot".utf8), assets: [SyncObjects.digest(png): png])
        let restored = try AINetworkJournal(directory: directory)
        XCTAssertEqual(restored.state.clientID, journal.state.clientID)
        let retry = try restored.prepare(documentID: doc, focusPageID: UUID(),
            context: Data("later ink must not change retry".utf8), assets: [:])
        XCTAssertEqual(retry.requestID, submission.requestID)
        XCTAssertEqual(retry.contextSHA256, submission.contextSHA256)
        XCTAssertEqual(try restored.assets(for: retry)[submission.contextSHA256], Data("first snapshot".utf8))
        try restored.finish(submission.requestID, needsAck: true)
        let afterApply = try AINetworkJournal(directory: directory)
        XCTAssertNil(afterApply.state.pending[doc.uuidString])
        XCTAssertEqual(afterApply.state.applyAckIDs, [submission.requestID])
        try afterApply.acknowledged(submission.requestID)
        XCTAssertTrue(try AINetworkJournal(directory: directory).state.applyAckIDs.isEmpty)
    }

    func testApprovedResultReceiptHashesExactBytesNotJSONReserialization() throws {
        let result = AIResult(requestID: UUID(), documentID: UUID(), contextSHA256: String(repeating: "a", count: 64),
            draftVersion: 1, rendererSignature: "draw-ai-render-v1", pageEdits: [], previewSHA256s: [:])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(result)
        let approved = try AIResult.approved(data: bytes)
        XCTAssertEqual(try approved.digest(), SyncObjects.digest(bytes))
        XCTAssertNotEqual(try approved.digest(), SyncObjects.digest(try AIHash.encoded(approved)))
    }
    func testSyncStartedAcknowledgesExactRequestBeforeLongWork() async throws {
        let requestID = UUID(), documentID = UUID(), clientID = UUID()
        handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url!.path, "/draw-ai/v1/requests/\(requestID.uuidString)/sync-started")
            let json = try JSONSerialization.jsonObject(with: self.body(request)) as! [String: String]
            XCTAssertEqual(json, ["clientID": clientID.uuidString])
            return (200, try JSONSerialization.data(withJSONObject: ["requestID": requestID.uuidString,
                "documentID": documentID.uuidString, "status": "synchronizing"]))
        }
        let receipt = try await client.syncStarted(requestID: requestID, clientID: clientID)
        XCTAssertEqual(receipt.status, "synchronizing")
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests.contains { $0.url!.path.contains("assets") || $0.url!.path.contains("draw-sync") })
    }

    func testSyncStartedRejectsWrongIdentityOrMissingActiveAck() async throws {
        let requestID = UUID(), documentID = UUID()
        for (id, status) in [(UUID(), "synchronizing"), (requestID, "awaiting_sync")] {
            handler = { _ in
                (200, try JSONSerialization.data(withJSONObject: ["requestID": id.uuidString,
                    "documentID": documentID.uuidString, "status": status]))
            }
            do { _ = try await client.syncStarted(requestID: requestID, clientID: UUID()); XCTFail("Accepted invalid active ACK") }
            catch {}
        }
        XCTAssertEqual(requests.count, 2)
    }

    @MainActor
    func testReceiptRecoveryCacheCapturesCommittedAWhilePreservingNewerLocalB() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory.appendingPathComponent("notes"))
        let doc = try store.addNotebook("Pinned source"), pageID = store.notebook(doc)!.pages[0].id
        func stroke(_ x: CGFloat) -> PKStroke {
            let points = [CGPoint(x: x, y: 40), CGPoint(x: x + 60, y: 40)].enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index) / 10, size: CGSize(width: 4, height: 4),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.monoline, color: .black),
                path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 100)))
        }
        try store.commit(book: doc, page: pageID, drawing: PKDrawing(strokes: [stroke(40)]))
        let publishedA = try store.exportCurrentPackage(book: doc), syncID = UUID()
        let journal = try AINetworkJournal(directory: directory.appendingPathComponent("network"))
        try journal.stageCommittedSource(publishedA, syncID: syncID)
        let currentA = try store.drawing(book: doc, page: store.notebook(doc)!.pages[0])
        try store.commit(book: doc, page: pageID, drawing: PKDrawing(strokes: currentA.strokes + [stroke(200)]))
        let localB = try store.exportCurrentPackage(book: doc)
        XCTAssertNotEqual(try localB.digest(), try publishedA.digest())
        let restored = try AINetworkJournal(directory: directory.appendingPathComponent("network"))
        let committedA = try XCTUnwrap(restored.committedSource(syncID: syncID))
        XCTAssertEqual(try committedA.encoded(), try publishedA.encoded())
        let capture = try await store.capturedAIContextAsync(book: doc, focusPage: pageID,
            pageSize: CGSize(width: 1024, height: 1361), source: committedA)
        XCTAssertEqual(capture.context.pages[0].head, publishedA.notebooks[0].pages[0].head)
        XCTAssertNotEqual(capture.context.pages[0].head, localB.notebooks[0].pages[0].head)
        XCTAssertEqual(capture.context.pages[0].strokeTargets.count, 1)
        XCTAssertEqual(try store.drawing(book: doc, page: store.notebook(doc)!.pages[0]).strokes.count, 2)
        XCTAssertEqual(try store.exportCurrentPackage(book: doc).encoded(), try localB.encoded())
        let nativeDigests = Set(committedA.blobs.values.map(SyncObjects.digest))
        XCTAssertTrue(nativeDigests.isDisjoint(with: Set(capture.assets.keys)), "Notes CAS must contain context images/scenes, not native archives")
        XCTAssertTrue(requests.isEmpty, "Receipt reconstruction/capture itself must not issue network requests")
    }

    @MainActor
    func testLostDocumentReceiptRestoresCommittedSourceNotLaterLocalOrRemoteCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AIReverseSync-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root.appendingPathComponent("notes"))
        let doc = try store.addNotebook("Committed A"), page = store.notebook(doc)!.pages[0].id
        func stroke(_ x: CGFloat) -> PKStroke {
            let point = PKStrokePoint(location: CGPoint(x: x, y: 40), timeOffset: 0, size: CGSize(width: 4, height: 4),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            return PKStroke(ink: PKInk(.monoline, color: .black),
                path: PKStrokePath(controlPoints: [point], creationDate: Date(timeIntervalSince1970: 100)))
        }
        try store.commit(book: doc, page: page, drawing: PKDrawing(strokes: [stroke(40)]))
        let sourceA = try store.exportCurrentPackage(book: doc)
        var remoteC = sourceA; remoteC.notebooks[0].name = "Remote C after committed A"
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIHTTPStub.self]
        let syncClient = SyncClient(endpoint: URL(string: "https://\(host!)/draw-sync/v1/state")!, token: "test-only",
                                    session: URLSession(configuration: config))
        var committed: DocumentSyncReceipt?
        var postCount = 0
        func json(_ value: [String: Any]) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: value)) }
        func manifest(_ source: SyncPackage) throws -> [String: Any] {
            var value = try JSONSerialization.jsonObject(with: source.encoded()) as! [String: Any]
            value["blobs"] = source.blobs.mapValues(SyncObjects.digest)
            return value
        }
        handler = { request in
            let path = request.url!.path
            if path.hasPrefix("/draw-ai/") { return (200, Data("{}".utf8)) }
            if path.hasSuffix("/objects/missing") { return try json(["missing": [String]()]) }
            if path.contains("/objects/") {
                let sha = request.url!.lastPathComponent
                return (200, try XCTUnwrap(sourceA.blobs.values.first { SyncObjects.digest($0) == sha }))
            }
            if path.contains("/sync-receipts/") {
                return (200, try JSONEncoder().encode(XCTUnwrap(committed)))
            }
            XCTAssertEqual(path, "/draw-sync/v2/documents/\(doc.uuidString)/state")
            if request.httpMethod == "POST" {
                postCount += 1
                let bytes = try SyncGzip.decode(self.body(request), limit: SyncObjects.metadataLimit)
                let payload = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                let syncID = try XCTUnwrap(UUID(uuidString: payload["syncID"] as! String))
                committed = DocumentSyncReceipt(revision: 1, documentDigest: String(repeating: "a", count: 64),
                    lastSyncedAt: "2026-10-10T10:00:00Z", syncID: syncID)
                return (503, Data()) // Publication succeeded, receipt response was lost.
            }
            if committed == nil {
                return try json(["revision": 0, "manifest": NSNull(), "documentDigest": NSNull(), "lastSyncedAt": NSNull()])
            }
            return try json(["revision": 2, "manifest": manifest(remoteC),
                "documentDigest": String(repeating: "c", count: 64), "lastSyncedAt": "2026-10-10T11:00:00Z"])
        }
        let journal = try AINetworkJournal(directory: root.appendingPathComponent("network"))
        let controller = DrawController(store: store, aiClient: client, syncClient: syncClient,
                                        aiJournal: journal, syncDefaults: defaults)
        controller.loadViewIfNeeded(); controller.becomeForeground()
        defer { controller.enterBackground() }
        do { _ = try await controller.syncDocument(doc); XCTFail("Expected lost response") }
        catch { guard case SyncError.http(503) = error else { return XCTFail("Unexpected failure: \(error)") } }
        XCTAssertNil(controller.lastSyncedSources[doc])
        let decodedA = try store.drawing(book: doc, page: store.notebook(doc)!.pages[0])
        try store.commit(book: doc, page: page, drawing: PKDrawing(strokes: decodedA.strokes + [stroke(200)]))
        let localB = try store.exportCurrentPackage(book: doc)
        let recovered = try await controller.syncDocument(doc)
        XCTAssertEqual(recovered.syncID, committed?.syncID)
        XCTAssertEqual(postCount, 1, "Receipt recovery must not republish newer local B")
        XCTAssertEqual(try controller.lastSyncedSources[doc]?.encoded(), try sourceA.encoded())
        XCTAssertNotEqual(try controller.lastSyncedSources[doc]?.digest(), try remoteC.digest())
        XCTAssertEqual(try store.exportCurrentPackage(book: doc).encoded(), try localB.encoded())
        XCTAssertEqual(try store.drawing(book: doc, page: store.notebook(doc)!.pages[0]).strokes.count, 2)
    }

    @MainActor
    func testLostReceiptAThenHomeBAndLocalCNeverRegressesConfirmedAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AIHomeReceiptAuthority-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root.appendingPathComponent("notes"))
        let doc = try store.addNotebook("Source A")
        let a = try store.exportCurrentPackage(book: doc)
        let network = try AINetworkJournal(directory: root.appendingPathComponent("network"))
        let sync = SyncClient(endpoint: URL(string: "https://\(host!)/draw-sync/v1/state")!, token: "test-only", session: session)
        var remote: SyncPackage?, sourceB: SyncPackage?, sourceC: SyncPackage?
        var receiptA: DocumentSyncReceipt?, docPosts = 0, receiptReads = 0, globalPosts = 0
        var events: [String] = []
        let wireA = String(repeating: "a", count: 64), wireB = String(repeating: "b", count: 64), wireC = String(repeating: "c", count: 64)
        struct DocumentState: Encodable {
            var revision: Int; var manifest: TestWireManifest?; var documentDigest: String?; var lastSyncedAt: String?
            enum CodingKeys: String, CodingKey { case revision, manifest, documentDigest, lastSyncedAt }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(revision, forKey: .revision); try c.encode(manifest, forKey: .manifest)
                try c.encode(documentDigest, forKey: .documentDigest); try c.encode(lastSyncedAt, forKey: .lastSyncedAt)
            }
        }
        struct LibraryState: Encodable { var revision: Int; var manifest: TestWireManifest? }
        handler = { request in
            let path = request.url!.path
            if path.hasPrefix("/draw-ai/") { return (200, Data("{}".utf8)) }
            if path.hasSuffix("/objects/missing") { return (200, Data("{\"missing\":[]}".utf8)) }
            if path.contains("/sync-receipts/") {
                receiptReads += 1; events.append("receipt-A")
                return (200, try JSONEncoder().encode(XCTUnwrap(receiptA)))
            }
            if path == "/draw-sync/v2/state" {
                if request.httpMethod == "GET" {
                    events.append("Home-reconcile")
                    return (200, try JSONEncoder().encode(LibraryState(revision: 1, manifest: remote.map(TestWireManifest.init))))
                }
                globalPosts += 1
                XCTAssertEqual(try SyncJournal.load(in: defaults).documents[doc.uuidString]?.serverDigest, wireA,
                               "Lost A must be acknowledged before publishing Home B")
                remote = try XCTUnwrap(sourceB)
                return (200, Data("{\"revision\":2}".utf8))
            }
            XCTAssertEqual(path, "/draw-sync/v2/documents/\(doc.uuidString)/state")
            if request.httpMethod == "GET" {
                let revision = globalPosts == 0 ? (remote == nil ? 0 : 1) : (docPosts == 1 ? 2 : 3)
                return (200, try JSONEncoder().encode(DocumentState(revision: revision,
                    manifest: remote.map(TestWireManifest.init), documentDigest: remote == nil ? nil : (globalPosts == 0 ? wireA : wireB),
                    lastSyncedAt: remote == nil ? nil : "2026-10-10T11:00:00Z")))
            }
            docPosts += 1
            let payload = try JSONSerialization.jsonObject(with: SyncGzip.decode(self.body(request), limit: SyncObjects.metadataLimit)) as! [String: Any]
            let syncID = try XCTUnwrap(UUID(uuidString: payload["syncID"] as! String))
            if docPosts == 1 {
                remote = a
                receiptA = DocumentSyncReceipt(revision: 1, documentDigest: wireA, lastSyncedAt: "2026-10-10T10:00:00Z", syncID: syncID)
                return (503, Data())
            }
            XCTAssertEqual(payload["baseDocumentDigest"] as? String, wireB)
            let before = try SyncJournal.load(in: defaults)
            XCTAssertEqual(before.documents[doc.uuidString]?.serverDigest, wireB)
            XCTAssertEqual(before.documents[doc.uuidString]?.revision, 2)
            remote = try XCTUnwrap(sourceC)
            return (200, try JSONEncoder().encode(DocumentSyncReceipt(revision: 3, documentDigest: wireC,
                lastSyncedAt: "2026-10-10T12:00:00Z", syncID: syncID)))
        }
        var errors = 0
        let controller = DrawController(store: store, aiClient: client, syncClient: sync, aiJournal: network,
                                        syncDefaults: defaults, onError: { _, _ in errors += 1 })
        controller.loadViewIfNeeded(); controller.becomeForeground()
        defer { controller.enterBackground() }
        do { _ = try await controller.syncDocument(doc); XCTFail("Expected lost A response") }
        catch { guard case SyncError.http(503) = error else { return XCTFail("Unexpected lost-response error") } }
        let pendingA = try XCTUnwrap(SyncJournal.load(in: defaults).pendingDocuments[doc.uuidString])
        try store.update(doc) { $0.name = "Source B" }
        sourceB = try store.exportCurrentPackage(book: doc)
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let home = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Sync with DGX" })
        home.sendActions(for: .touchUpInside)
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? SyncJournal.load(in: defaults).documents[doc.uuidString]?.serverDigest) == wireB
        }, object: nil)
        await fulfillment(of: [confirmed], timeout: 5)
        XCTAssertEqual(errors, 0)
        var journal = try SyncJournal.load(in: defaults)
        XCTAssertNil(journal.pendingDocuments[doc.uuidString])
        XCTAssertEqual(globalPosts, 1)
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "receipt-A")), try XCTUnwrap(events.firstIndex(of: "Home-reconcile")))
        // Simulate a stale persisted/late A receipt still present after Home.
        journal.pendingDocuments[doc.uuidString] = pendingA
        try journal.save(in: defaults)
        try store.update(doc) { $0.name = "Source C" }
        sourceC = try store.exportCurrentPackage(book: doc)
        let receiptC = try await controller.syncDocument(doc)
        XCTAssertEqual(receiptC.documentDigest, wireC)
        XCTAssertEqual(receiptReads, 2)
        XCTAssertEqual(docPosts, 2, "Recovery must publish C against B, not return obsolete A")
        XCTAssertEqual(try controller.lastSyncedSources[doc]?.encoded(), try sourceC?.encoded())
        XCTAssertEqual(try SyncJournal.load(in: defaults).documents[doc.uuidString]?.revision, 3)
    }

    @MainActor
    func testPendingDownloadCannotImportOldReceiptAfterRemoteAdvanceOrLocalWriting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for remoteAdvanced in [false, true] {
            let suite = "AIPendingDownload-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = Store(directory: root.appendingPathComponent(UUID().uuidString))
            let doc = try store.addNotebook("Before download")
            let before = try store.exportCurrentPackage(book: doc)
            var a = before; a.notebooks[0].name = "Downloaded A"
            let network = try AINetworkJournal(directory: root.appendingPathComponent(UUID().uuidString))
            let syncID = UUID(), wireA = String(repeating: "a", count: 64)
            try network.stageCommittedSource(a, syncID: syncID)
            var journal = SyncJournal()
            journal.pendingDocuments[doc.uuidString] = .init(syncID: syncID, localDigest: try a.digest(),
                localBeforeDigest: try before.digest(), download: true)
            try journal.save(in: defaults)
            var remote = a
            if remoteAdvanced { remote.notebooks[0].name = "Remote B" }
            else {
                let point = PKStrokePoint(location: CGPoint(x: 40, y: 40), timeOffset: 0, size: CGSize(width: 4, height: 4),
                                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                let stroke = PKStroke(ink: PKInk(.monoline, color: .black),
                                      path: PKStrokePath(controlPoints: [point], creationDate: Date(timeIntervalSince1970: 100)))
                try store.commit(book: doc, page: before.notebooks[0].pages[0].id, drawing: PKDrawing(strokes: [stroke]))
            }
            let current = try store.exportCurrentPackage(book: doc)
            struct State: Encodable { var revision: Int; var manifest: TestWireManifest; var documentDigest: String; var lastSyncedAt: String }
            handler = { request in
                if request.url!.path.hasPrefix("/draw-ai/") { return (200, Data("{}".utf8)) }
                XCTAssertEqual(request.httpMethod, "GET", "Conflicting recovery must not publish")
                if request.url!.path.contains("/sync-receipts/") {
                    return (200, try JSONEncoder().encode(DocumentSyncReceipt(revision: 2, documentDigest: wireA,
                        lastSyncedAt: "2026-10-10T10:00:00Z", syncID: syncID)))
                }
                return (200, try JSONEncoder().encode(State(revision: remoteAdvanced ? 3 : 2, manifest: TestWireManifest(remote),
                    documentDigest: remoteAdvanced ? String(repeating: "b", count: 64) : wireA, lastSyncedAt: "2026-10-10T11:00:00Z")))
            }
            let controller = DrawController(store: store, aiClient: client,
                syncClient: SyncClient(endpoint: URL(string: "https://\(host!)/draw-sync/v1/state")!, token: "test-only", session: session),
                aiJournal: network, syncDefaults: defaults)
            controller.loadViewIfNeeded(); controller.becomeForeground()
            defer { controller.enterBackground() }
            do { _ = try await controller.syncDocument(doc); XCTFail("Unsafe pending download must conflict") }
            catch { guard case SyncError.conflict = error else { return XCTFail("Unexpected recovery error") } }
            XCTAssertEqual(try store.exportCurrentPackage(book: doc).encoded(), try current.encoded())
            XCTAssertNotNil(try SyncJournal.load(in: defaults).pendingDocuments[doc.uuidString])
            XCTAssertNil(try SyncJournal.load(in: defaults).documents[doc.uuidString])
        }
    }

    @MainActor
    func testReverseCommandAcknowledgesBeforeWaitingForPencilEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root.appendingPathComponent("notes"))
        let documentID = try store.addNotebook("Long Pencil contact"), requestID = UUID()
        let networkJournal = try AINetworkJournal(directory: root.appendingPathComponent("network"))
        let acknowledged = expectation(description: "Active ACK before Pencil end")
        handler = { request in
            if request.url!.path.hasSuffix("/sync-started") {
                acknowledged.fulfill()
                return (200, try JSONSerialization.data(withJSONObject: ["requestID": requestID.uuidString,
                    "documentID": documentID.uuidString, "status": "synchronizing"]))
            }
            return (200, Data("{}".utf8))
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIHTTPStub.self]
        let syncClient = SyncClient(endpoint: URL(string: "https://\(host!)/draw-sync/v1/state")!, token: "test-only",
                                    session: URLSession(configuration: config))
        let controller = DrawController(store: store, aiClient: client, syncClient: syncClient, aiJournal: networkJournal)
        controller.loadViewIfNeeded(); controller.becomeForeground()
        let canvas = PKCanvasView()
        controller.canvasViewDidBeginUsingTool(canvas)
        let command = AIChannelCommand(kind: "sync_document", requestID: requestID, documentID: documentID)
        let operation = Task { await controller.handleSyncCommand(command) }
        await fulfillment(of: [acknowledged], timeout: 2)
        XCTAssertFalse(requests.contains { $0.url!.path.contains("draw-sync") || $0.url!.path.contains("assets") },
                       "Pencil contact must defer Sync/capture without deferring its active ACK")
        controller.enterBackground()
        operation.cancel()
        controller.canvasViewDidEndUsingTool(canvas)
        await operation.value
        XCTAssertFalse(requests.contains { $0.url!.path.contains("draw-sync") || $0.url!.path.contains("assets") })
        XCTAssertTrue(controller.lastSyncedSources.isEmpty)
    }

    @MainActor
    func testHomeSyncDefersReadyApplyUntilRemoteImportCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AIHomeMutationGate-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root.appendingPathComponent("notes"))
        let doc = try store.addNotebook("Ready answer document"), page = store.notebook(doc)!.pages[0].id
        let other = try store.addNotebook("Unrelated old name")
        let local = try store.exportCurrentPackage()
        var remote = local
        remote.notebooks[1].name = "Unrelated remote update"
        var baseline = SyncJournal(); baseline.folders = []
        for book in local.notebooks {
            let digest = try local.document(book.id).digest()
            baseline.documents[book.id.uuidString] = DocumentSyncBaseline(serverDigest: String(repeating: "a", count: 64),
                localDigest: digest, revision: 1, lastSyncedAt: "2026-10-10T10:00:00Z")
            baseline.remoteLocalDigests[book.id.uuidString] = digest
        }
        try baseline.save(in: defaults)
        let network = try AINetworkJournal(directory: root.appendingPathComponent("network"))
        let pending = try network.prepare(documentID: doc, focusPageID: page, context: Data("{}".utf8), assets: [:])
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: AICapture.rendererFormat()).image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(x: 2, y: 2, width: 16, height: 16))
        }
        let png = try AICapture.png(image), pngSHA = SyncObjects.digest(png)
        let object = AIObject(id: UUID(), revision: 1, kind: "text", source: "Answer",
            frame: AIFrame(x: 100, y: 100, width: 20, height: 20), style: AIStyle(),
            asset: AIAsset(sha256: pngSHA, pixelWidth: 40, pixelHeight: 40),
            provenance: AIProvenance(requestID: pending.requestID, contextSHA256: pending.contextSHA256, rendererSignature: "draw-ai-render-v1"))
        let result = AIResult(requestID: pending.requestID, documentID: doc, contextSHA256: pending.contextSHA256,
            draftVersion: 1, rendererSignature: "draw-ai-render-v1",
            pageEdits: [AIPageEdit(pageID: page, objectEdits: [AIObjectEdit(op: "add", object: object)], strokeEdits: [])],
            previewSHA256s: [page.uuidString: String(repeating: "b", count: 64)])
        let resultBytes = try AIHash.encoded(result), resultSHA = SyncObjects.digest(resultBytes)
        let captured = expectation(description: "Home captured local and awaits remote")
        let downloaded = expectation(description: "Concurrent ready answer downloaded")
        let acknowledged = expectation(description: "Applied after Home import")
        AIHTTPStub.pauseNext(host, path: "/draw-sync/v2/state") { captured.fulfill() }
        defer { AIHTTPStub.resume(host) }
        func json(_ value: [String: Any]) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: value)) }
        func manifest(_ source: SyncPackage) throws -> [String: Any] {
            var value = try JSONSerialization.jsonObject(with: source.encoded()) as! [String: Any]
            value["blobs"] = source.blobs.mapValues(SyncObjects.digest)
            return value
        }
        handler = { request in
            let path = request.url!.path
            if path == "/draw-sync/v2/state" {
                if request.httpMethod == "POST" { return try json(["revision": 2]) }
                return try json(["revision": 2, "manifest": manifest(remote)])
            }
            if path == "/draw-sync/v2/objects/missing" { return try json(["missing": [String]()]) }
            if path.hasPrefix("/draw-sync/v2/documents/") {
                let id = try XCTUnwrap(UUID(uuidString: request.url!.deletingLastPathComponent().lastPathComponent))
                return try json(["revision": 2, "manifest": manifest(remote.document(id)),
                    "documentDigest": String(repeating: "c", count: 64), "lastSyncedAt": "2026-10-10T11:00:00Z"])
            }
            if path == "/draw-ai/v1/requests/" + pending.requestID.uuidString {
                return try json(["requestID": pending.requestID.uuidString, "documentID": doc.uuidString,
                    "status": "ready", "resultSHA256": resultSHA])
            }
            if path == "/draw-ai/v1/assets/" + resultSHA { return (200, resultBytes) }
            if path == "/draw-ai/v1/assets/" + pngSHA { downloaded.fulfill(); return (200, png) }
            if path.hasSuffix("/applied") {
                let ack = try JSONSerialization.jsonObject(with: self.body(request)) as! [String: Any]
                XCTAssertEqual((ack["receipt"] as? [String: Any])?["resultSHA256"] as? String, resultSHA)
                acknowledged.fulfill(); return try json([:])
            }
            return try json([:]) // Isolated registration/channel transport.
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIHTTPStub.self]
        let syncClient = SyncClient(endpoint: URL(string: "https://\(host!)/draw-sync/v1/state")!, token: "test-only",
                                    session: URLSession(configuration: config))
        let controller = DrawController(store: store, aiClient: client, syncClient: syncClient, aiJournal: network, syncDefaults: defaults)
        controller.loadViewIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let sync = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Sync with DGX" })
        sync.sendActions(for: .touchUpInside)
        await fulfillment(of: [captured], timeout: 3)
        controller.becomeForeground()
        defer { controller.enterBackground() }
        await fulfillment(of: [downloaded], timeout: 5)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNil(store.appliedAIReceipt(requestID: pending.requestID), "Ready apply must wait while Home owns the mutation gate")
        XCTAssertTrue(store.objects(book: doc, page: store.notebook(doc)!.pages[0]).isEmpty)
        let canceledApply = Task { try await controller.applyApprovedAI(data: resultBytes, assets: [pngSHA: png]) }
        await Task.yield(); canceledApply.cancel()
        do { _ = try await canceledApply.value; XCTFail("Canceled gated apply must not commit") }
        catch is CancellationError {}
        XCTAssertNil(store.appliedAIReceipt(requestID: pending.requestID))
        AIHTTPStub.resume(host)
        await fulfillment(of: [acknowledged], timeout: 10)
        XCTAssertEqual(store.notebook(other)?.name, "Unrelated remote update")
        XCTAssertEqual(store.objects(book: doc, page: store.notebook(doc)!.pages[0]).map(\.id), [object.id])
        XCTAssertEqual(store.appliedAIReceipt(requestID: pending.requestID)?.resultSHA256, resultSHA)
        let reopened = Store(directory: root.appendingPathComponent("notes"))
        XCTAssertEqual(reopened.objects(book: doc, page: reopened.notebook(doc)!.pages[0]).map(\.id), [object.id])
        XCTAssertEqual(reopened.appliedAIReceipt(requestID: pending.requestID)?.resultSHA256, resultSHA)
    }

    @MainActor
    func testDocumentSyncConfirmsOnlyFThenHomeCanPublishNewEmptyG() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AIPartialFolder-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root.appendingPathComponent("notes"))
        var journal = SyncJournal(); journal.folders = []; try journal.save(in: defaults)
        let f = try store.addFolder("New F"), doc = try store.addNotebook("Document in F", in: f)
        let confirmed = try store.exportCurrentPackage(book: doc)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIHTTPStub.self]
        let syncClient = SyncClient(endpoint: URL(string: "https://\(host!)/draw-sync/v1/state")!, token: "test-only",
                                    session: URLSession(configuration: config))
        handler = { request in
            let path = request.url!.path
            if path == "/draw-sync/v2/objects/missing" {
                return (200, Data("{\"missing\":[]}".utf8))
            }
            if path.hasPrefix("/draw-sync/v2/documents/") {
                if request.httpMethod == "GET" {
                    return (200, Data("{\"revision\":0,\"manifest\":null,\"documentDigest\":null,\"lastSyncedAt\":null}".utf8))
                }
                let bytes = try SyncGzip.decode(self.body(request), limit: SyncObjects.metadataLimit)
                let payload = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                return (200, try JSONSerialization.data(withJSONObject: ["revision": 1,
                    "documentDigest": String(repeating: "a", count: 64), "lastSyncedAt": "2026-10-10T10:00:00Z",
                    "syncID": payload["syncID"]!]))
            }
            return (200, Data("{}".utf8))
        }
        let network = try AINetworkJournal(directory: root.appendingPathComponent("network"))
        let controller = DrawController(store: store, aiClient: client, syncClient: syncClient, aiJournal: network, syncDefaults: defaults)
        controller.loadViewIfNeeded(); controller.becomeForeground()
        defer { controller.enterBackground() }
        _ = try await controller.syncDocument(doc)
        let g = try store.addFolder("New empty G")
        let local = try store.exportCurrentPackage()
        let anchored = try SyncJournal.load(in: defaults)
        XCTAssertEqual(anchored.folders?.map(\.id), [f])
        XCTAssertFalse(anchored.folders?.contains(where: { $0.id == g }) ?? true)
        let merged = try anchored.reconcile(local: local, remote: SyncState(revision: 1, package: confirmed))
        XCTAssertEqual(Set((merged.folders ?? []).map(\.id)), [f, g])
        XCTAssertEqual(merged.notebooks.first?.folderID, f)
        XCTAssertEqual(try merged.digest(), try local.digest())
    }

    @MainActor
    func testReverseCommandCapturesRequestedPageBWithoutNavigatingVisiblePageA() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AIRequestedFocus-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root.appendingPathComponent("notes"))
        let doc = try store.addNotebook("Focus fixture", orientation: DocumentOrientation.saved().rawValue)
        let a = store.notebook(doc)!.pages[0].id, b = Page()
        try store.update(doc) { $0.pages.append(b); $0.currentPage = a }
        let requestID = UUID()
        var uploaded: [String: Data] = [:]
        var capturedContext: AIContext?
        func json(_ value: [String: Any]) throws -> (Int, Data) { (200, try JSONSerialization.data(withJSONObject: value)) }
        handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/sync-started") {
                return try json(["requestID": requestID.uuidString, "documentID": doc.uuidString, "status": "synchronizing"])
            }
            if path == "/draw-sync/v2/objects/missing" { return try json(["missing": [String]()]) }
            if path.hasPrefix("/draw-sync/v2/documents/") {
                if request.httpMethod == "GET" {
                    return try json(["revision": 0, "manifest": NSNull(), "documentDigest": NSNull(), "lastSyncedAt": NSNull()])
                }
                let payload = try JSONSerialization.jsonObject(with: SyncGzip.decode(self.body(request), limit: SyncObjects.metadataLimit)) as! [String: Any]
                return try json(["revision": 1, "documentDigest": String(repeating: "a", count: 64),
                    "lastSyncedAt": "2026-10-10T10:00:00Z", "syncID": payload["syncID"]!])
            }
            if path == "/draw-ai/v1/assets/missing" {
                let payload = try JSONSerialization.jsonObject(with: self.body(request)) as! [String: [String]]
                return try json(["missing": payload["digests"]!])
            }
            if path.hasPrefix("/draw-ai/v1/assets/") {
                let bytes = try self.body(request), sha = request.url!.lastPathComponent
                XCTAssertEqual(SyncObjects.digest(bytes), sha)
                uploaded[sha] = bytes
                return try json(["sha256": sha])
            }
            if path.hasSuffix("/sync-ready") {
                let payload = try JSONSerialization.jsonObject(with: self.body(request)) as! [String: String]
                capturedContext = try JSONDecoder().decode(AIContext.self, from: XCTUnwrap(uploaded[payload["contextSHA256"]!]))
                return try json(["requestID": requestID.uuidString, "documentID": doc.uuidString, "status": "queued"])
            }
            if path.hasSuffix("/ready") { return try json(["requests": [Any]()]) }
            if path == "/draw-ai/v1/requests/" + requestID.uuidString {
                return try json(["requestID": requestID.uuidString, "documentID": doc.uuidString, "status": "running"])
            }
            return try json([:])
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIHTTPStub.self]
        let syncClient = SyncClient(endpoint: URL(string: "https://\(host!)/draw-sync/v1/state")!, token: "test-only",
                                    session: URLSession(configuration: config))
        let network = try AINetworkJournal(directory: root.appendingPathComponent("network"))
        let controller = DrawController(store: store, aiClient: client, syncClient: syncClient, aiJournal: network, syncDefaults: defaults)
        controller.loadViewIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let open = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.currentTitle?.contains("Focus fixture") == true })
        open.sendActions(for: .touchUpInside)
        let visibleCanvas = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? DrawingCanvas }.first)
        let viewport = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PageViewport }.first)
        let transform = viewport.surface.transform
        controller.becomeForeground()
        defer { controller.enterBackground() }
        let commandBytes = try JSONSerialization.data(withJSONObject: ["kind": "sync_document", "requestID": requestID.uuidString,
            "documentID": doc.uuidString, "focusPageID": b.id.uuidString])
        let command = try JSONDecoder().decode(AIChannelCommand.self, from: commandBytes)
        let publishing = expectation(description: "Pinned source awaits document POST")
        AIHTTPStub.pauseNext(host, path: "/draw-sync/v2/documents/" + doc.uuidString + "/state", method: "POST") {
            publishing.fulfill()
        }
        defer { AIHTTPStub.resume(host) }
        let operation = Task { await controller.handleSyncCommand(command) }
        await fulfillment(of: [publishing], timeout: 5)
        // User ink while the pinned source is in flight must remain live, but
        // must not enter the terminal context claiming that older Sync receipt.
        let points = [CGPoint(x: 40, y: 40), CGPoint(x: 100, y: 40)].enumerated().map { i, point in
            PKStrokePoint(location: point, timeOffset: Double(i) / 10, size: CGSize(width: 4, height: 4),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.monoline, color: .black),
                              path: PKStrokePath(controlPoints: points, creationDate: Date()))
        controller.canvasViewDidBeginUsingTool(visibleCanvas)
        visibleCanvas.drawing = PKDrawing(strokes: [stroke])
        controller.canvasViewDidEndUsingTool(visibleCanvas)
        controller.finishSave()
        let laterHead = try XCTUnwrap(store.notebook(doc)!.pages[0].head)
        AIHTTPStub.resume(host)
        await operation.value
        let context = try XCTUnwrap(capturedContext)
        XCTAssertNil(try XCTUnwrap(context.pages.first { $0.pageID == a }).head)
        XCTAssertTrue(context.pages.allSatisfy { $0.strokeTargets.isEmpty })
        XCTAssertEqual(store.notebook(doc)!.pages[0].head, laterHead)
        XCTAssertEqual(visibleCanvas.drawing.strokes.count, 1)
        XCTAssertEqual(try store.drawing(book: doc, page: store.notebook(doc)!.pages[0]).strokes.count, 1)
        let profiles = store.aiCaptureCache.lastProfiles
        XCTAssertEqual(profiles.count, context.pages.count)
        XCTAssertTrue(profiles.allSatisfy { !$0.onMainThread }, "App terminal capture must render off UI")
        XCTAssertEqual(capturedContext?.focusPageID, b.id)
        XCTAssertEqual(capturedContext?.documentID, doc)
        XCTAssertEqual(store.notebook(doc)?.currentPage, a)
        XCTAssertTrue(descendants(controller.view).contains { $0 === visibleCanvas })
        XCTAssertEqual(viewport.surface.transform, transform)
    }

}
