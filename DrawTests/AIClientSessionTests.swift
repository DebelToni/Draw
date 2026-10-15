import XCTest
import Foundation
@testable import Draw

private final class SessionSocketWitness: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let driverOpened = XCTestExpectation(description: "Driver WebSocket opened")
    let channelOpened = XCTestExpectation(description: "Foreground WebSocket opened")
    private let lock = NSLock()
    private var opened = 0

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock(); opened += 1; let count = opened; lock.unlock()
        if count == 1 { driverOpened.fulfill() }
        if count == 2 { channelOpened.fulfill() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never follow a fixture redirect to another host.
    }
}

// Callback, timeout and cancellation race through a single resume gate.
private final class SocketCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}

final class AIClientSessionTests: XCTestCase {
    private func socketOperation(_ socket: URLSessionWebSocketTask,
                                 start: @escaping (@escaping (Error?) -> Void) -> Void) async throws {
        let gate = SocketCompletionGate()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard gate.install(continuation) else { return }
                let timeout = DispatchWorkItem {
                    if gate.finish(.failure(NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: "Loopback WebSocket operation timed out after five seconds"]))) {
                        socket.cancel(with: .goingAway, reason: nil)
                    }
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5, execute: timeout)
                start { error in
                    timeout.cancel()
                    if let error {
                        let failure = error as NSError
                        // Numeric transport diagnostics only, never URLs/headers/bodies.
                        gate.finish(.failure(NSError(domain: failure.domain, code: failure.code,
                            userInfo: [NSLocalizedDescriptionKey: "Loopback WebSocket operation failed"])))
                    } else {
                        gate.finish(.success(Void()))
                    }
                }
            }
        }, onCancel: {
            if gate.finish(.failure(CancellationError())) { socket.cancel(with: .goingAway, reason: nil) }
        })
    }

    private func ping(_ socket: URLSessionWebSocketTask) async throws {
        try await socketOperation(socket) { completion in socket.sendPing(pongReceiveHandler: completion) }
    }

    func testCompletionGateIgnoresLateCallbacksAfterTimeoutOrCancellation() async throws {
        let failures: [Error] = [URLError(.timedOut), CancellationError()]
        for failure in failures {
            let gate = SocketCompletionGate()
            XCTAssertTrue(gate.finish(.failure(failure))) // Cancellation can precede installation.
            XCTAssertFalse(gate.finish(.success(Void())))
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    XCTAssertFalse(gate.install(continuation))
                }
                XCTFail("First failure must not be replaced by a late success")
            } catch {
                if failure is CancellationError { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual((error as NSError).code, URLError.timedOut.rawValue) }
            }
        }
        let gate = SocketCompletionGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            XCTAssertTrue(gate.install(continuation))
            XCTAssertTrue(gate.finish(.success(Void())))
            XCTAssertFalse(gate.finish(.failure(URLError(.timedOut))))
        }
    }

    @MainActor
    func testDedicatedSocketSurvivesShortHTTPResourceDeadline() async throws {
        #if DEBUG && targetEnvironment(simulator)
        let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DrawAIRealNotesInput", isDirectory: true)
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("Parent has not staged the loopback AI integration fixture")
        }
        let endpoint = URL(string: "http://127.0.0.1:48281")!
        let socketConfig = URLSessionConfiguration.ephemeral
        socketConfig.protocolClasses = []
        socketConfig.waitsForConnectivity = false
        socketConfig.timeoutIntervalForRequest = 10
        socketConfig.timeoutIntervalForResource = 900
        socketConfig.connectionProxyDictionary = [:]
        let socketSession = URLSession(configuration: socketConfig)
        defer { socketSession.invalidateAndCancel() }
        let registrar = AIClient(endpoint: endpoint, token: "portable-fixture-only", session: socketSession,
                                 webSocketSession: socketSession)
        // Both default dedicated transport and explicit WebSocket injection must
        // outlive the HTTP resource deadline; wrong routing to HTTP fails fast.
        for usesInjectedSocket in [false, true] {
            let httpConfig = URLSessionConfiguration.ephemeral
            httpConfig.timeoutIntervalForRequest = 0.05
            httpConfig.timeoutIntervalForResource = 0.05
            httpConfig.connectionProxyDictionary = [:]
            let http = URLSession(configuration: httpConfig)
            defer { http.invalidateAndCancel() }
            let clientID = UUID()
            try await registrar.register(clientID)
            let client = AIClient(endpoint: endpoint, token: "portable-fixture-only", session: http,
                                  webSocketSession: usesInjectedSocket ? socketSession : nil)
            let driver = try client.channel(clientID: clientID)
            driver.resume()
            let pump = Task {
                do { while !Task.isCancelled { _ = try await driver.receive() } }
                catch { /* Bounded send/ping independently assert transport health. */ }
            }
            defer {
                pump.cancel()
                driver.cancel(with: .goingAway, reason: nil)
                withExtendedLifetime(client) {} // Deinit owned transport only after socket cleanup.
            }
            try await socketOperation(driver) { completion in
                driver.send(.string("{\"kind\":\"open\",\"documentID\":null}"), completionHandler: completion)
            }
            try await ping(driver)
            try await Task.sleep(nanoseconds: 1_100_000_000)
            try await ping(driver)
            XCTAssertEqual(http.configuration.timeoutIntervalForResource, 0.05)
        }
        #else
        throw XCTSkip("Loopback WebSocket lifetime test is DEBUG simulator-only")
        #endif
    }

    @MainActor
    func testSharedInjectedClientsAndChannelStopLeaveLiveWebSocketAndHTTPDriverAlive() async throws {
        #if DEBUG && targetEnvironment(simulator)
        // Opt in with the same parent-staged fixture marker as AIIntegrationTests.
        // No fixture launch, production endpoint or live notebook access here.
        let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DrawAIRealNotesInput", isDirectory: true)
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("Parent has not staged the loopback AI integration fixture")
        }
        let endpoint = URL(string: "http://127.0.0.1:48281")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []
        config.urlCache = nil
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 900
        config.connectionProxyDictionary = [:]
        let witness = SessionSocketWitness()
        let shared = URLSession(configuration: config, delegate: witness, delegateQueue: nil)
        defer { shared.invalidateAndCancel() } // Only the caller owns this lifetime.
        var departingAI: AIClient? = AIClient(endpoint: endpoint, token: "portable-fixture-only", session: shared, webSocketSession: shared)
        var departingSync: SyncClient? = SyncClient(endpoint: URL(string: "http://127.0.0.1:48282/v1/state")!,
                                                   token: "portable-fixture-only", session: shared)
        weak var weakAI = departingAI
        weak var weakSync = departingSync
        let driverID = UUID()
        try await departingAI!.register(driverID)
        let driver = try departingAI!.channel(clientID: driverID)
        driver.resume()
        let receivePump = Task {
            do {
                while !Task.isCancelled { _ = try await driver.receive() }
            } catch {
                // Bounded ping/send must independently fail if the transport dies.
                // Cleanup cancels the receive and socket; no body is inspected/logged.
            }
        }
        defer {
            receivePump.cancel()
            driver.cancel(with: .goingAway, reason: nil)
        }
        await fulfillment(of: [witness.driverOpened], timeout: 10)
        try await socketOperation(driver) { completion in
            driver.send(.string("{\"kind\":\"open\",\"documentID\":null}"), completionHandler: completion)
        }
        try await ping(driver)
        departingAI = nil
        departingSync = nil
        XCTAssertTrue(weakAI == nil && weakSync == nil, "Both clients must actually deinitialize")
        try await ping(driver) // An established task must survive client deinit.
        var health = URLRequest(url: endpoint.appendingPathComponent("health"))
        health.setValue("Bearer portable-fixture-only", forHTTPHeaderField: "Authorization")
        let (_, response) = try await shared.data(for: health)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let channelClient = AIClient(endpoint: endpoint, token: "portable-fixture-only", session: shared, webSocketSession: shared)
        let channelID = UUID()
        try await channelClient.register(channelID)
        let channel = AIForegroundChannel()
        defer { channel.stop() }
        try channel.start(client: channelClient, clientID: channelID) { _ in
            XCTFail("Session-lifetime fixture must not initiate document work")
        }
        await fulfillment(of: [witness.channelOpened], timeout: 10)
        channel.stop()
        try await ping(driver) // Stop cancels only the channel's own socket.
        let (_, afterStop) = try await shared.data(for: health)
        XCTAssertEqual((afterStop as? HTTPURLResponse)?.statusCode, 200)
        #else
        throw XCTSkip("Loopback WebSocket lifetime test is DEBUG simulator-only")
        #endif
    }
}
