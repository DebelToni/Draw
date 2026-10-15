import XCTest
import Foundation
import UIKit
import PencilKit
@testable import Draw

// Parent stages a COPY of current heads, never the app's real library:
// Documents/DrawAIRealNotesInput/notebooks.json + BOOK/PAGE/HEAD.pkdraw (+ assets).
// capture-targets.json is [{"label":"factorial","documentID":"UUID","focusPageID":"UUID"},
//                         {"label":"mixed",...}, {"label":"homework",...}].
// Names must contain "Test"; UUIDs decode case-insensitively and encode uppercase.
// Include this file in the DrawTests target. No fixture server is started here.
private struct CopiedNoteTarget: Codable {
    var label: String
    var documentID: UUID
    var focusPageID: UUID
}

private struct IntegrationFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

// Only numeric error/status and fixed route categories enter diagnostics, never
// credentials, request/response bodies, source names or raw URLs.
private struct TransportOutcome: Codable {
    var stage: String
    var completedAtUptime: TimeInterval
    var statusCode: Int?
    var errorDomain: String?
    var errorCode: Int?
    var failed: Bool { errorCode != nil || (statusCode ?? 0) >= 400 }
    var summary: String { "\(stage): HTTP \(statusCode ?? 0), \(errorDomain ?? "none") \(errorCode ?? 0)" }
}

// Refuse redirects rather than following a local server response to production.
private final class LocalOnlyRedirects: NSObject, URLSessionTaskDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0, completed = 0
    private var outcomes: [TransportOutcome] = []
    private var latestOutcome: TransportOutcome?
    var transportOutcomes: [TransportOutcome] {
        lock.lock(); defer { lock.unlock() }
        if let latestOutcome, outcomes.last?.completedAtUptime != latestOutcome.completedAtUptime {
            return outcomes + [latestOutcome]
        }
        return outcomes
    }

    private func stage(_ task: URLSessionTask) -> String {
        let path = task.originalRequest?.url?.path ?? ""
        if task is URLSessionWebSocketTask { return "foreground-channel" }
        if path.hasSuffix("/register") { return "registration" }
        if path.hasSuffix("/sync-started") { return "sync-started-ack" }
        if path.hasSuffix("/sync-ready") { return "sync-ready-ack" }
        if path.contains("/documents/") && path.hasSuffix("/state") {
            return task.originalRequest?.httpMethod == "POST" ? "source-publication" : "source-document-read"
        }
        if path.hasSuffix("/assets/missing") { return "context-cas-missing" }
        if path.contains("/assets/") {
            return task.originalRequest?.httpMethod == "PUT" ? "context-asset-upload" : "context-asset-read"
        }
        if path.contains("/objects/") { return "source-object-transfer" }
        if path.hasSuffix("/terminal-requests") { return "terminal-submission" }
        if path.contains("/requests/") { return "request-status" }
        return "source-or-ready-read"
    }
    var webSocketCounts: (opened: Int, completed: Int) {
        lock.lock(); defer { lock.unlock() }
        return (opened, completed)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock(); opened += 1; lock.unlock()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let failure = error.map { $0 as NSError }
        let outcome = TransportOutcome(stage: stage(task), completedAtUptime: ProcessInfo.processInfo.systemUptime, statusCode: (task.response as? HTTPURLResponse)?.statusCode,
            errorDomain: failure?.domain, errorCode: failure?.code)
        lock.lock(); defer { lock.unlock() }
        if task is URLSessionWebSocketTask { completed += 1 }
        latestOutcome = outcome
        // Keep every failure, but bound successful asset-transfer diagnostics.
        if outcomes.count < 256 || outcome.failed { outcomes.append(outcome) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Decode the additive manager pins without changing the production client model.
private struct TerminalReceipt: Codable {
    var requestID: UUID
    var documentID: UUID
    var status: String
    var focusPageID: UUID?
    var contextSHA256: String?
    var lastSyncedAt: String?
    var syncStartedAt: String?
    var syncDeadlineAt: String?
    var error: AIServiceError?
}

@MainActor
final class AIIntegrationTests: XCTestCase {
    private let pageSize = CGSize(width: 1024, height: 1361)
    private let fixtureToken = "portable-fixture-only"
    private let managerURL = URL(string: "http://127.0.0.1:48281")!
    private let sourceURL = URL(string: "http://127.0.0.1:48282/v1/state")!
    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var input: URL { documents.appendingPathComponent("DrawAIRealNotesInput", isDirectory: true) }
    private var oracles: URL { documents.appendingPathComponent("DrawAIIntegrationOracles", isDirectory: true) }

    private func targets() throws -> [CopiedNoteTarget] {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Copied-note HTTP tests are simulator-only")
        #else
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw XCTSkip("Parent has not staged DrawAIRealNotesInput")
        }
        let targets = try JSONDecoder().decode([CopiedNoteTarget].self,
            from: Data(contentsOf: input.appendingPathComponent("capture-targets.json")))
        guard targets.count == 3, Set(targets.map(\.label)) == Set(["factorial", "mixed", "homework"]),
              Set(targets.map(\.documentID)).count == targets.count else {
            throw IntegrationFailure("Expected three distinct copied-note targets")
        }
        return targets
        #endif
    }

    private func session(delegate: LocalOnlyRedirects = LocalOnlyRedirects(),
                         requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 120,
                         maximumConnectionsPerHost: Int = 6) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [] // Real HTTP, never AIHTTPStub / URLProtocol fixtures.
        config.urlCache = nil
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private func inventory(_ directory: URL) throws -> [String: String] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []))
        var result: [String: String] = [:]
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw IntegrationFailure("Copied-note input must not contain symbolic links")
            }
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(file.path.dropFirst(directory.path.count + 1))] = AIHash.digest(try Data(contentsOf: file))
            }
        }
        return result
    }

    private func write(_ bytes: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
    }

    private func writeJSON<T: Encodable>(_ value: T, to file: URL) throws {
        try write(AIHash.encoded(value), to: file)
    }

    private func page(_ target: CopiedNoteTarget, in store: Store) throws -> Page {
        try XCTUnwrap(store.notebook(target.documentID)?.pages.first { $0.id == target.focusPageID })
    }

    private func canonical(_ drawing: PKDrawing) throws -> [PortableStroke] {
        try drawing.strokes.map { try PortableStroke($0, includeSamples: false) }
    }

    // Load/migrate ONLY the temporary copy. The migration's permitted differences
    // are history reset and exact legacy teal -> purple, including fresh recolor ID.
    private func copiedStore(_ targets: [CopiedNoteTarget]) throws -> (store: Store, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DrawAIIntegration-" + UUID().uuidString)
        try FileManager.default.copyItem(at: input, to: root)
        do {
            let legacy = Store(directory: root, migrateLegacyHistory: false)
            if let error = legacy.loadError { throw error }
            let before = try legacy.exportCurrentPackage()
            for target in targets {
                let book = try XCTUnwrap(legacy.notebook(target.documentID))
                guard book.name.localizedCaseInsensitiveContains("test") else {
                    throw IntegrationFailure("Refusing a copied document without a test name")
                }
                _ = try page(target, in: legacy)
            }
            for book in legacy.notebooks {
                for page in book.pages + book.deleted {
                    guard page.nodes.count == (page.head == nil ? 0 : 1),
                          page.nodes.allSatisfy({ $0.id == page.head && $0.parent == nil && $0.children.isEmpty && $0.preferredChild == nil }) else {
                        throw IntegrationFailure("Input must contain current heads only")
                    }
                }
            }
            let baseline = UserDefaults.standard.data(forKey: "syncBaseline")
            let migrated = Store(directory: root, migrateLegacyHistory: true)
            if let error = migrated.loadError { throw error }
            XCTAssertEqual(UserDefaults.standard.data(forKey: "syncBaseline"), baseline)
            if let journal = try migrated.migrationJournal() {
                XCTAssertEqual(journal.preMigrationPackage, try before.encoded())
                XCTAssertEqual(journal.preMigrationDigest, try before.digest())
                XCTAssertEqual(journal.globalBaseline, baseline)
            }
            let after = try migrated.exportCurrentPackage()
            XCTAssertEqual(before.notebooks.map(\.id), after.notebooks.map(\.id))
            XCTAssertEqual(try AIHash.encoded(before.folders), try AIHash.encoded(after.folders))
            var originalHeadBytes = 0, retainedHeadBytes = 0, tealPages = 0
            for oldBook in before.notebooks {
                let newBook = try XCTUnwrap(after.notebooks.first { $0.id == oldBook.id })
                XCTAssertEqual(oldBook.name, newBook.name)
                XCTAssertEqual(oldBook.folderID, newBook.folderID)
                XCTAssertEqual(oldBook.currentPage, newBook.currentPage)
                XCTAssertEqual(oldBook.created, newBook.created)
                XCTAssertEqual(oldBook.modified, newBook.modified)
                XCTAssertEqual(oldBook.orientation, newBook.orientation)
                XCTAssertEqual(oldBook.pages.map(\.id), newBook.pages.map(\.id))
                XCTAssertEqual(oldBook.deleted.map(\.id), newBook.deleted.map(\.id))
                for oldPage in oldBook.pages + oldBook.deleted {
                    let newPage = try XCTUnwrap((newBook.pages + newBook.deleted).first { $0.id == oldPage.id })
                    XCTAssertEqual(oldPage.background, newPage.background)
                    XCTAssertEqual(oldPage.starred, newPage.starred)
                    let oldBytes = oldPage.head.flatMap { before.blobs[SyncPackage.key(oldBook.id, oldPage.id, $0)] }
                    let newBytes = newPage.head.flatMap { after.blobs[SyncPackage.key(newBook.id, newPage.id, $0)] }
                    originalHeadBytes += oldBytes?.count ?? 0
                    retainedHeadBytes += newBytes?.count ?? 0
                    let oldDrawing = try oldBytes.map { try PKDrawing(data: $0) } ?? PKDrawing()
                    let newDrawing = try newBytes.map { try PKDrawing(data: $0) } ?? PKDrawing()
                    let oldStrokes = try canonical(oldDrawing), newStrokes = try canonical(newDrawing)
                    XCTAssertEqual(oldStrokes.count, newStrokes.count)
                    let containsTeal = oldDrawing.strokes.contains { AIInk.isLegacyTeal($0.ink.color) }
                    if !containsTeal {
                        XCTAssertEqual(oldPage.head, newPage.head)
                        XCTAssertTrue(oldBytes == newBytes, "Non-teal native head bytes changed")
                    } else {
                        tealPages += 1
                        XCTAssertNotEqual(oldPage.head, newPage.head)
                    }
                    for (index, pair) in zip(oldStrokes, newStrokes).enumerated() {
                        var expected = pair.0
                        if AIInk.isLegacyTeal(oldDrawing.strokes[index].ink.color) {
                            let recolored = AIInk.recolored(oldDrawing.strokes[index], color: QuestionInk.color)
                            let archived = try PKDrawing(data: PKDrawing(strokes: [recolored]).dataRepresentation())
                            expected.color = try PortableStroke(XCTUnwrap(archived.strokes.first), includeSamples: false).color
                            expected.id = pair.1.id // Recolor deliberately creates a fresh native identity.
                            XCTAssertFalse(AIInk.isLegacyTeal(newDrawing.strokes[index].ink.color))
                        }
                        XCTAssertTrue(try AIHash.encoded(expected) == AIHash.encoded(pair.1), "Migration changed native controls or attributes")
                    }
                    XCTAssertEqual(newPage.nodes.count, newPage.head == nil ? 0 : 1)
                    XCTAssertTrue(newPage.nodes.allSatisfy { $0.parent == nil && $0.children.isEmpty })
                    XCTAssertEqual(try AIHash.encoded(oldPage.nodes.first?.objects),
                                   try AIHash.encoded(newPage.nodes.first?.objects))
                }
            }
            try writeJSON(["originalHeadBytes": originalHeadBytes, "migratedHeadBytes": retainedHeadBytes,
                           "tealPages": tealPages], to: oracles.appendingPathComponent("migration-metrics.json"))
            return (migrated, root)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func capture(_ target: CopiedNoteTarget, store: Store, directory: URL) throws -> (context: AIContext, assets: [String: Data]) {
        let before = try store.exportCurrentPackage().encoded()
        let captured = try store.capturedAIContext(book: target.documentID, focusPage: target.focusPageID, pageSize: pageSize)
        XCTAssertTrue(try store.exportCurrentPackage().encoded() == before, "Capture must not mutate native heads")
        XCTAssertEqual(captured.context.documentID, target.documentID)
        XCTAssertEqual(captured.context.focusPageID, target.focusPageID)
        XCTAssertEqual(captured.context.documentName, store.notebook(target.documentID)?.name)
        let book = try XCTUnwrap(store.notebook(target.documentID))
        let folderName = book.folderID.flatMap { id in store.folders.first { $0.id == id }?.name } ?? "Home"
        XCTAssertEqual(captured.context.folderName, folderName)
        XCTAssertEqual(captured.context.folderID, book.folderID)
        XCTAssertEqual(captured.context.pages.map(\.pageID), store.notebook(target.documentID)?.pages.map(\.id))
        for page in captured.context.pages {
            let nativePage = try XCTUnwrap(store.notebook(target.documentID)?.pages.first { $0.id == page.pageID })
            XCTAssertEqual(page.head, nativePage.head)
            XCTAssertEqual(page.background, nativePage.background)
            let drawing = try store.drawing(book: target.documentID, page: nativePage)
            XCTAssertEqual(page.strokeTargets.count, drawing.strokes.count)
            for sha in [page.paperSHA256, page.inkSHA256, page.compositeSHA256] {
                let bytes = try XCTUnwrap(captured.assets[sha])
                try AIAssets.validate(data: bytes, asset: AIAsset(sha256: sha,
                    pixelWidth: Int(page.width * 2), pixelHeight: Int(page.height * 2)))
            }
            let portable = try JSONDecoder().decode(PortablePage.self, from: XCTUnwrap(captured.assets[page.portableSHA256]))
            XCTAssertEqual(portable.background, page.background)
            XCTAssertEqual(portable.strokes.count, drawing.strokes.count)
            for (index, target) in page.strokeTargets.enumerated() {
                let original = try PortableStroke(drawing.strokes[index], includeSamples: false)
                XCTAssertEqual(target.index, index)
                XCTAssertEqual(target.id, original.targetID)
                XCTAssertEqual(target.fingerprint, try original.fingerprint())
                try AIAssets.validate(data: XCTUnwrap(captured.assets[target.asset.sha256]), asset: target.asset)
            }
        }
        let source = try store.exportCurrentPackage(book: target.documentID)
        XCTAssertTrue(Set(source.blobs.values.map(AIHash.digest)).isDisjoint(with: Set(captured.assets.keys)),
                      "Native archives must never be sent to Notes CAS")
        try write(try captured.context.encoded(), to: directory.appendingPathComponent("context.json"))
        for (sha, bytes) in captured.assets {
            XCTAssertEqual(AIHash.digest(bytes), sha)
            try write(bytes, to: directory.appendingPathComponent("assets/" + sha))
        }
        return captured
    }

    func testCopiedCurrentNotesNativeCaptureOracles() throws {
        let targets = try targets(), inputBefore = try inventory(input)
        defer { XCTAssertEqual(try? inventory(input), inputBefore, "Staged notes were modified") }
        let (store, root) = try copiedStore(targets)
        defer { try? FileManager.default.removeItem(at: root) }
        for target in targets {
            let directory = oracles.appendingPathComponent(target.label)
            var seconds: [Double] = [], reference: Data?
            for pass in 1...3 {
                let start = Date()
                let location = pass == 1 ? directory : directory.appendingPathComponent("capture-\(pass)")
                let captured = try capture(target, store: store, directory: location)
                seconds.append(Date().timeIntervalSince(start))
                var stable = captured.context
                stable.capturedAt = "" // Timestamp is the only varying capture field.
                let bytes = try stable.encoded()
                if let reference { XCTAssertTrue(bytes == reference, "Repeated native captures differ") }
                else { reference = bytes }
            }
            try writeJSON(seconds, to: directory.appendingPathComponent("capture-seconds.json"))
        }
    }

    private func assetDigests(_ page: AIContextPage) -> Set<String> {
        Set([page.paperSHA256, page.inkSHA256, page.compositeSHA256, page.portableSHA256]
            + page.strokeTargets.map { $0.asset.sha256 } + page.objects.map { $0.asset.sha256 })
    }

    func testCopiedCurrentNotesAsyncCaptureProfilesAndUIHeartbeat() async throws {
        let targets = try targets(), inputBefore = try inventory(input)
        defer { XCTAssertEqual(try? inventory(input), inputBefore, "Staged notes were modified") }
        let (store, root) = try copiedStore(targets)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheLimit = 128 * 1024 * 1024
        // Model the documented per-entry byte accounting (shared PNGs count in
        // each entry). Profiles verify hits; eviction counts below are modeled,
        // since production intentionally exposes no mutable cache inventory.
        var retainedEntries: [String: Int] = [:]
        for target in targets {
            let source = try store.exportCurrentPackage(book: target.documentID)
            var reference: Data?
            for pass in 1...2 {
                let started = ProcessInfo.processInfo.systemUptime
                let failuresBefore = testRun?.failureCount ?? 0
                var ticks = 0, lastTick = started, maxGap = 0.0
                let heartbeat = Task { @MainActor in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 20_000_000) }
                        catch { return }
                        let now = ProcessInfo.processInfo.systemUptime
                        maxGap = max(maxGap, now - lastTick)
                        lastTick = now
                        ticks += 1
                    }
                }
                defer { heartbeat.cancel() }
                let captured: (context: AIContext, assets: [String: Data])
                do {
                    captured = try await store.capturedAIContextAsync(book: target.documentID,
                        focusPage: target.focusPageID, pageSize: pageSize, source: source)
                } catch {
                    heartbeat.cancel()
                    await heartbeat.value
                    let failure = error as NSError
                    let report: [String: String] = ["pass": String(pass), "stage": "native-async-capture",
                        "responseError": "\(failure.domain) \(failure.code)",
                        "seconds": String(ProcessInfo.processInfo.systemUptime - started),
                        "uiHeartbeatTicks": String(ticks), "uiHeartbeatMaxGapSeconds": String(maxGap),
                        "completedPages": String(store.aiCaptureCache.lastProfiles.count)]
                    try writeJSON(report, to: oracles.appendingPathComponent(target.label + "/async-capture-\(pass)-profile.json"))
                    throw IntegrationFailure("Native async capture failed: \(failure.domain) \(failure.code)")
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                maxGap = max(maxGap, ProcessInfo.processInfo.systemUptime - lastTick)
                heartbeat.cancel()
                await heartbeat.value
                let profiles = store.aiCaptureCache.lastProfiles
                XCTAssertEqual(profiles.count, captured.context.pages.count)
                XCTAssertTrue(profiles.allSatisfy { !$0.onMainThread }, "Native capture ran on UI thread")
                XCTAssertEqual(Set(profiles.map(\.pageID)), Set(captured.context.pages.map(\.pageID)))
                let hits = profiles.filter(\.cacheHit).count, misses = profiles.count - hits
                var entryBytes = 0, evictedEntries = 0
                for profile in profiles {
                    let page = try XCTUnwrap(captured.context.pages.first { $0.pageID == profile.pageID })
                    let bytes = try assetDigests(page).reduce(0) { total, digest in
                        total + (try XCTUnwrap(captured.assets[digest])).count
                    }
                    entryBytes += bytes
                    let key = target.documentID.uuidString + "/" + page.pageID.uuidString
                    if profile.cacheHit {
                        XCTAssertNotNil(retainedEntries[key], "Warm hit has no accounted retained entry")
                    } else {
                        let retained = retainedEntries.filter { $0.key != key }.values.reduce(0, +)
                        if retained + bytes > cacheLimit {
                            evictedEntries += retainedEntries.count
                            retainedEntries.removeAll()
                        }
                        if bytes <= cacheLimit { retainedEntries[key] = bytes }
                    }
                    XCTAssertLessThanOrEqual(retainedEntries.values.reduce(0, +), cacheLimit)
                }
                XCTAssertLessThanOrEqual(captured.assets.values.reduce(0) { $0 + $1.count }, cacheLimit)
                if pass == 1 {
                    XCTAssertEqual(hits, 0, "New copied document was not a cold capture")
                    XCTAssertGreaterThan(ticks, 0, "UI heartbeat never ran during cold native capture")
                } else if entryBytes <= cacheLimit {
                    XCTAssertGreaterThan(hits, 0, "A document fitting the bounded cache must reuse warm entries")
                }
                XCTAssertLessThan(maxGap, 1.0, "Native capture stalled UI for a second")
                var stable = captured.context
                stable.capturedAt = ""
                let bytes = try stable.encoded()
                if let reference { XCTAssertEqual(bytes, reference, "Warm capture changed native context") }
                else { reference = bytes }
                XCTAssertEqual(try store.exportCurrentPackage(book: target.documentID).encoded(), try source.encoded())
                let report: [String: Any] = ["pass": pass, "seconds": elapsed, "uiHeartbeatTicks": ticks,
                    "cacheHits": hits, "cacheMisses": misses, "cacheLimitBytes": cacheLimit,
                    "entryBytesIncludingSharedAssets": entryBytes, "modeledEvictedEntries": evictedEntries,
                    "modeledRetainedBytes": retainedEntries.values.reduce(0, +),
                    "responseError": (testRun?.failureCount ?? 0) > failuresBefore ? "XCTest capture assertion failed" : "none",
                    "uiHeartbeatMaxGapSeconds": maxGap, "pages": profiles.map { profile -> [String: Any] in
                        ["pageID": profile.pageID.uuidString, "strokeCount": profile.strokeCount,
                         "cacheHit": profile.cacheHit, "onMainThread": profile.onMainThread,
                         "archiveSeconds": profile.archiveSeconds, "portableSeconds": profile.portableSeconds,
                         "strokeSeconds": profile.strokeSeconds, "layerSeconds": profile.layerSeconds]
                    }]
                try write(JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
                    to: oracles.appendingPathComponent(target.label + "/async-capture-\(pass)-profile.json"))
            }
        }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func terminalReceipt(_ transport: URLSession, path: String, body: [String: String]? = nil,
                                 timeout: TimeInterval = 30) async throws -> TerminalReceipt {
        var request = URLRequest(url: managerURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        request.setValue("Bearer " + fixtureToken, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (bytes, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              bytes.count <= SyncObjects.metadataLimit else {
            struct Failure: Decodable { var error: AIServiceError }
            let code = (try? JSONDecoder().decode(Failure.self, from: bytes))?.error.code
            let safeCode = code.flatMap { value in
                value.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) != nil ? value : nil
            } ?? "invalid-response"
            throw IntegrationFailure("Loopback terminal API failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0), " + safeCode)
        }
        return try JSONDecoder().decode(TerminalReceipt.self, from: bytes)
    }

    private func waitForTerminalReceipt(_ transport: URLSession, requestID: UUID, documentID: UUID,
        deadline: TimeInterval, controller: DrawController, nativeDelegates: [LocalOnlyRedirects],
        observed: (TerminalReceipt) -> Void, matching: (TerminalReceipt) -> Bool) async throws -> TerminalReceipt {
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let failure = nativeDelegates.flatMap({ $0.transportOutcomes }).first(where: \.failed) {
                throw IntegrationFailure("Native reverse Sync transport failed: " + failure.summary)
            }
            if controller.presentedViewController is UIAlertController {
                let stage = controller.lastSyncedSources[documentID] == nil ? "source-sync" : "native-capture-or-context-upload"
                throw IntegrationFailure("Native controller reported an error at " + stage)
            }
            let receipt = try await terminalReceipt(transport, path: "v1/requests/" + requestID.uuidString,
                timeout: min(30, max(0.01, deadline - ProcessInfo.processInfo.systemUptime)))
            observed(receipt)
            guard receipt.requestID == requestID, receipt.documentID == documentID else {
                throw IntegrationFailure("Terminal API returned the wrong request/document")
            }
            guard !["failed", "interrupted", "needs_stale_choice"].contains(receipt.status) else {
                throw IntegrationFailure("Native reverse Sync ended: " + receipt.status + " / " + (receipt.error?.code ?? "unknown"))
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            if matching(receipt) {
                if let failure = nativeDelegates.flatMap({ $0.transportOutcomes }).first(where: \.failed) {
                    throw IntegrationFailure("Native reverse Sync transport failed: " + failure.summary)
                }
                if controller.presentedViewController is UIAlertController {
                    throw IntegrationFailure("Native controller reported an error before the pinned receipt")
                }
                return receipt
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw IntegrationFailure("Native WebSocket ACK/context exceeded the shared 120-second deadline")
    }

    private func settleWindow(_ window: UIWindow, controller: DrawController, orientation: DocumentOrientation) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var stableSince: TimeInterval?
        while ProcessInfo.processInfo.systemUptime < deadline {
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            let matches = window.windowScene?.interfaceOrientation == orientation.interfaceOrientation
                && (orientation == .portrait ? window.bounds.height > window.bounds.width : window.bounds.width > window.bounds.height)
                && controller.view.bounds.size == window.bounds.size && controller.transitionCoordinator == nil
            if matches {
                if stableSince == nil { stableSince = ProcessInfo.processInfo.systemUptime }
                if ProcessInfo.processInfo.systemUptime - stableSince! >= 0.4 { return }
            } else { stableSince = nil }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw IntegrationFailure("Native test window did not settle before foreground Sync")
    }

    private func activeTasks(_ session: URLSession) async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private func drainForeground(_ controller: DrawController?, sessions: [URLSession]) async -> Bool {
        controller?.enterBackground()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var quietSince: TimeInterval?
        while ProcessInfo.processInfo.systemUptime < deadline {
            var count = 0
            for session in sessions { count += await activeTasks(session).count }
            if count == 0 {
                if quietSince == nil { quietSince = ProcessInfo.processInfo.systemUptime }
                if ProcessInfo.processInfo.systemUptime - quietSince! >= 0.2 { return true }
            } else { quietSince = nil }
            // Untracked registration/ready callbacks get actor turns to finish;
            // cancellation guards prevent a detached render from starting uploads.
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func testRealWebSocketTerminalDocumentSyncFocusBWhileHome() async throws {
        try await reverseSyncCopiedNote(label: "mixed", visiblePageA: false)
    }

    func testRealWebSocketTerminalDocumentSyncFocusBWhilePageAVisible() async throws {
        try await reverseSyncCopiedNote(label: "homework", visiblePageA: true)
    }

    // Clone only the requested test document identity, not page/head/stroke IDs.
    // Import writes the exact native bytes under NEW document-relative paths in
    // the temporary library. Existing fixture intents/workers are left alone.
    private func freshReverseTarget(_ template: CopiedNoteTarget, store: Store) throws -> CopiedNoteTarget {
        let library = try store.exportCurrentPackage()
        var clone = try library.document(template.documentID)
        let documentID = UUID()
        clone.notebooks[0].id = documentID
        clone.notebooks[0].name += " WS " + documentID.uuidString
        clone.blobs = Dictionary(uniqueKeysWithValues: clone.blobs.map { key, bytes in
            (documentID.uuidString + String(key.dropFirst(template.documentID.uuidString.count)), bytes)
        })
        if let original = clone.folders?.first {
            let folder = Folder(id: UUID(), name: original.name + " WS " + documentID.uuidString)
            clone.notebooks[0].folderID = folder.id
            clone.folders = [folder]
        }
        try clone.validate()
        let books = library.notebooks.map { $0.id == template.documentID ? clone.notebooks[0] : $0 }
        let folders = (library.folders ?? []) + (clone.folders ?? [])
        try store.importPackage(SyncPackage.combine(books, sources: [clone, library], folders: folders))
        let imported = try store.exportCurrentPackage(book: documentID)
        XCTAssertEqual(try imported.encoded(), try clone.encoded(), "Re-keying changed native source bytes or metadata")
        XCTAssertEqual(imported.notebooks[0].pages.map(\.id),
                       try library.document(template.documentID).notebooks[0].pages.map(\.id))
        for other in library.notebooks where other.id != template.documentID {
            XCTAssertEqual(try store.exportCurrentPackage(book: other.id).encoded(), try library.document(other.id).encoded())
        }
        XCTAssertNil(store.notebook(template.documentID))
        return CopiedNoteTarget(label: template.label, documentID: documentID, focusPageID: template.focusPageID)
    }

    private func reverseSyncCopiedNote(label: String, visiblePageA: Bool) async throws {
        var targets = try targets()
        let inputBefore = try inventory(input)
        defer { XCTAssertEqual(try? inventory(input), inputBefore, "Staged notes were modified") }
        let template = try XCTUnwrap(targets.first { $0.label == label })
        if ProcessInfo.processInfo.arguments.contains("--ui-test-fixture"),
           ProcessInfo.processInfo.environment["DRAW_AI_FIXTURE_URL"] == nil {
            throw IntegrationFailure("Parent must set DRAW_AI_FIXTURE_URL for native foreground channel tests")
        }
        let (store, root) = try copiedStore(targets)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try freshReverseTarget(template, store: store)
        targets = targets.map { $0.label == label ? target : $0 }
        let driverDelegate = LocalOnlyRedirects(), socketDelegate = LocalOnlyRedirects(), sourceDelegate = LocalOnlyRedirects()
        // Each owner has a distinct transport. In particular, dropping an AI
        // client must never invalidate a session used by Source or the driver.
        let transport = session(delegate: driverDelegate)
        // Match AIClient's eight parallel immutable CAS PUTs; Source and the
        // raw receipt driver remain on their own separately bounded sessions.
        let aiSession = session(delegate: socketDelegate, maximumConnectionsPerHost: 8)
        XCTAssertEqual(aiSession.configuration.httpMaximumConnectionsPerHost, 8)
        let sourceSession = session(delegate: sourceDelegate, requestTimeout: 90, resourceTimeout: 300)
        // A socket resource timeout bounds the entire upgraded connection, not
        // individual messages. Outlive the broker's 300-second ACK allowance;
        // the test's 120-second deadline/background close remain unchanged.
        let socketSession = session(delegate: socketDelegate, resourceTimeout: 600)
        let sessions = [transport, aiSession, sourceSession, socketSession]
        let ai = AIClient(endpoint: managerURL, token: fixtureToken, session: aiSession,
                          webSocketSession: socketSession)
        let sync = SyncClient(endpoint: sourceURL, token: fixtureToken, session: sourceSession)
        defer {
            // The injecting owner closes external transports after the async
            // cleanup below, including when writing diagnostics throws.
            withExtendedLifetime((ai, sync, sessions)) {
                sessions.forEach { $0.finishTasksAndInvalidate() }
            }
        }
        let suite = "AIRealWebSocket-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let networkRoot = root.appendingPathComponent("reverse-network")
        let network = try AINetworkJournal(directory: networkRoot) // Fresh installation UUID, no old polling IDs.
        XCTAssertTrue(network.state.pending.isEmpty)
        XCTAssertTrue(network.state.applyAckIDs.isEmpty)

        let directory = oracles.appendingPathComponent("reverse-" + (visiblePageA ? "page-a" : "home"))
        let startedAt = ProcessInfo.processInfo.systemUptime
        var stage = "fixture-source-setup", lastReceipt: TerminalReceipt?, pipelineStarted: TimeInterval?
        var testController: DrawController?, testWindow: UIWindow?, testFailure: Error?
        var foregroundOutcomes: [TransportOutcome] = []
        var backgroundStarted = false
        let failuresBefore = testRun?.failureCount ?? 0
        let originalOrientation = UserDefaults.standard.object(forKey: DocumentOrientation.defaultsKey)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let hostWindow = scene.windows.first { $0.isKeyWindow }
        do {
            // Establish test Source only if absent. Never publish the factorial UUID,
            // which the separate app-inference test deliberately keeps unsynced.
            for note in targets where note.label != "factorial" {
                let local = try store.exportCurrentPackage(book: note.documentID)
                let remote = try await sync.fetchDocument(note.documentID, local: local)
                if remote.package == nil {
                    let scenes = try await Task.detached { try local.portablePages() }.value
                    _ = try await sync.uploadDocument(local, documentID: note.documentID, syncID: UUID(),
                        baseDocumentDigest: nil, pages: scenes)
                }
            }
            let localLibrary = try store.exportCurrentPackage()
            let initialState = try await sync.fetchIncremental(local: localLibrary)
            let before = try XCTUnwrap(initialState.package)
            var unrelatedStates: [UUID: DocumentSyncState] = [:]
            var baseline = SyncJournal()
            baseline.legacyInvalidated = true
            baseline.folders = before.folders ?? []
            // Use latest GET's EXACT native package for the local anchor, never the
            // post-open local digest. Opening A may itself change modified/currentPage.
            for book in store.notebooks {
                let remote = try await sync.fetchDocument(book.id, local: localLibrary.document(book.id))
                if let source = remote.package, let wire = remote.documentDigest {
                    let digest = try source.digest()
                    baseline.documents[book.id.uuidString] = DocumentSyncBaseline(serverDigest: wire,
                        localDigest: digest, revision: remote.revision, lastSyncedAt: try XCTUnwrap(remote.lastSyncedAt))
                    baseline.remoteLocalDigests[book.id.uuidString] = digest
                    if book.id != target.documentID { unrelatedStates[book.id] = remote }
                }
            }
            try baseline.save(in: defaults)
            let prior = try XCTUnwrap(baseline.documents[target.documentID.uuidString])
            let orientation = DocumentOrientation(metadata: store.notebook(target.documentID)?.orientation)
            orientation.save()
            var visibleCanvas: DrawingCanvas?, viewport: PageViewport?, pageA: UUID?
            if visiblePageA {
                pageA = try XCTUnwrap(store.notebook(target.documentID)?.pages.first { $0.id != target.focusPageID }?.id,
                                     "Copied homework must have a page A distinct from requested B")
                try store.update(target.documentID) { $0.currentPage = pageA }
            }
            let controller = DrawController(store: store, aiClient: ai, syncClient: sync,
                aiJournal: network, syncDefaults: defaults)
            testController = controller
            stage = "visible-window-setup"
            let window = UIWindow(windowScene: scene)
            testWindow = window
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.loadViewIfNeeded()
            controller.requestManualOrientation()
            try await settleWindow(window, controller: controller, orientation: orientation)
            XCTAssertTrue(window.isKeyWindow)
            XCTAssertTrue(controller.view.window === window)
            if visiblePageA {
                let book = try XCTUnwrap(store.notebook(target.documentID))
                if let folderID = book.folderID {
                    let folder = try XCTUnwrap(store.folders.first { $0.id == folderID })
                    let openFolder = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }
                        .first { $0.accessibilityLabel == "Open folder " + folder.name })
                    openFolder.sendActions(for: .touchUpInside)
                }
                let open = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }
                    .first { $0.currentTitle?.contains(book.name) == true })
                XCTAssertTrue(open.isEnabled)
                open.sendActions(for: .touchUpInside)
                visibleCanvas = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? DrawingCanvas }.first)
                viewport = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PageViewport }.first)
            }
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            viewport?.layoutIfNeeded()
            let transform = viewport?.surface.transform, surfaceBounds = viewport?.surface.bounds
            let visibleDrawing = visibleCanvas?.drawing
            if let viewport {
                XCTAssertGreaterThan(viewport.bounds.width, 0)
                XCTAssertGreaterThan(viewport.bounds.height, 0)
            }
            let rootSubviews = controller.view.subviews
            let expected = try store.exportCurrentPackage(book: target.documentID)
            let pencil = (visibleCanvas as PKCanvasView?) ?? PKCanvasView()
            controller.canvasViewDidBeginUsingTool(pencil)
            controller.becomeForeground() // Registers and opens the actual URLSession WebSocket, also on Home.
            // This defer only lifts the Pencil gate; async foreground draining below
            // runs while the real window, controller and all transports are retained.
            defer { controller.canvasViewDidEndUsingTool(pencil) }
            pipelineStarted = ProcessInfo.processInfo.systemUptime
            let requestID = UUID(), deadline = pipelineStarted! + 120
            stage = "terminal-submission"
            let submitted = try await terminalReceipt(transport,
                path: "v1/documents/" + target.documentID.uuidString + "/terminal-requests",
                body: ["requestID": requestID.uuidString, "focusPageID": target.focusPageID.uuidString,
                       "prompt": "On the requested page, write one short clarification question about the copied notes. Preserve all existing ink."])
            XCTAssertEqual(submitted.requestID, requestID)
            XCTAssertEqual(submitted.documentID, target.documentID)
            XCTAssertEqual(submitted.focusPageID, target.focusPageID)
            stage = "native-websocket-and-sync-started-ack"
            let started = try await waitForTerminalReceipt(transport, requestID: requestID,
                documentID: target.documentID, deadline: deadline, controller: controller,
                nativeDelegates: [socketDelegate, sourceDelegate], observed: { lastReceipt = $0 }) { $0.status == "synchronizing" }
            try writeJSON(started, to: directory.appendingPathComponent("sync-started.json"))
            XCTAssertEqual(started.documentID, target.documentID)
            XCTAssertEqual(started.status, "synchronizing")
            XCTAssertEqual(socketDelegate.webSocketCounts.opened, 1, "Native URLSession never completed WebSocket upgrade")
            XCTAssertEqual(socketDelegate.webSocketCounts.completed, 0)
            XCTAssertNotNil(started.syncStartedAt)
            XCTAssertNotNil(started.syncDeadlineAt)
            XCTAssertNil(started.contextSHA256, "Pencil contact must defer capture, not the active ACK")
            XCTAssertTrue(controller.lastSyncedSources.isEmpty)
            let held = try await sync.fetchDocument(target.documentID, local: expected)
            XCTAssertEqual(held.documentDigest, prior.serverDigest)
            XCTAssertEqual(held.lastSyncedAt, prior.lastSyncedAt)
            XCTAssertEqual(try store.exportCurrentPackage(book: target.documentID).encoded(), try expected.encoded())
            controller.canvasViewDidEndUsingTool(pencil)
            stage = "native-source-sync-capture-and-context-upload"
            let queued = try await waitForTerminalReceipt(transport, requestID: requestID,
                documentID: target.documentID, deadline: deadline, controller: controller,
                nativeDelegates: [socketDelegate, sourceDelegate], observed: { lastReceipt = $0 }) { $0.contextSHA256 != nil }
            try writeJSON(queued, to: directory.appendingPathComponent("queued-receipt.json"))
            foregroundOutcomes = socketDelegate.transportOutcomes + sourceDelegate.transportOutcomes
            stage = "background-close-and-receipt-verification"
            backgroundStarted = true
            controller.enterBackground() // Close socket/polls immediately; do not wait for full model completion.
            let closeDeadline = ProcessInfo.processInfo.systemUptime + 5
            while socketDelegate.webSocketCounts.completed == 0 && ProcessInfo.processInfo.systemUptime < closeDeadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(socketDelegate.webSocketCounts.completed, 1, "Background did not close native WebSocket")
            XCTAssertTrue(["queued", "running", "ready"].contains(queued.status))
            XCTAssertEqual(queued.focusPageID, target.focusPageID)
            let committed = try XCTUnwrap(controller.lastSyncedSources[target.documentID])
            XCTAssertEqual(committed.notebooks.map(\.id), [target.documentID])
            XCTAssertEqual(try committed.encoded(), try expected.encoded())
            let sourceState = try await sync.fetchDocument(target.documentID, local: committed)
            XCTAssertEqual(try XCTUnwrap(sourceState.package).encoded(), try committed.encoded())
            let confirmed = try XCTUnwrap(try SyncJournal.load(in: defaults).documents[target.documentID.uuidString])
            XCTAssertEqual(confirmed.serverDigest, sourceState.documentDigest)
            XCTAssertEqual(confirmed.localDigest, try committed.digest())
            XCTAssertEqual(queued.lastSyncedAt, sourceState.lastSyncedAt)
            XCTAssertNotEqual(sourceState.lastSyncedAt, prior.lastSyncedAt)
            let cachedFiles = try FileManager.default.contentsOfDirectory(at: networkRoot, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(".sync-source.json") }
            XCTAssertEqual(cachedFiles.count, 1)
            let syncID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(cachedFiles.first).lastPathComponent
                .replacingOccurrences(of: ".sync-source.json", with: "")))
            let receipt = try await sync.fetchSyncReceipt(syncID)
            XCTAssertEqual(receipt.documentDigest, confirmed.serverDigest)
            XCTAssertEqual(receipt.lastSyncedAt, queued.lastSyncedAt)
            XCTAssertEqual(try XCTUnwrap(network.committedSource(syncID: syncID)).encoded(), try committed.encoded())
            let contextSHA = try XCTUnwrap(queued.contextSHA256)
            let contextBytes = try await ai.download(contextSHA, maxBytes: SyncObjects.metadataLimit)
            let context = try JSONDecoder().decode(AIContext.self, from: contextBytes)
            XCTAssertEqual(AIHash.digest(contextBytes), contextSHA)
            XCTAssertEqual(context.documentID, target.documentID)
            XCTAssertEqual(context.focusPageID, target.focusPageID)
            let book = try XCTUnwrap(committed.notebooks.first)
            XCTAssertEqual(context.documentName, book.name)
            XCTAssertEqual(context.folderID, book.folderID)
            XCTAssertEqual(context.folderName, book.folderID.flatMap { id in committed.folders?.first { $0.id == id }?.name } ?? "Home")
            XCTAssertEqual(context.pages.map(\.pageID), book.pages.map(\.id))
            let scenes = try await Task.detached { try committed.portablePages() }.value
            var contextRefs: Set<String> = [contextSHA]
            for capturedPage in context.pages {
                let sourcePage = try XCTUnwrap(book.pages.first { $0.id == capturedPage.pageID })
                XCTAssertEqual(capturedPage.head, sourcePage.head)
                XCTAssertEqual(capturedPage.background, sourcePage.background)
                XCTAssertEqual(capturedPage.objects, sourcePage.nodes.first { $0.id == sourcePage.head }?.objects ?? [])
                let scene = try XCTUnwrap(scenes[target.documentID.uuidString + "/" + sourcePage.id.uuidString])
                XCTAssertEqual(capturedPage.strokeTargets.count, scene.strokes.count)
                for (index, pair) in zip(capturedPage.strokeTargets, scene.strokes).enumerated() {
                    XCTAssertEqual(pair.0.index, index)
                    XCTAssertEqual(pair.0.id, pair.1.targetID)
                    XCTAssertEqual(pair.0.fingerprint, try pair.1.fingerprint())
                }
                contextRefs.formUnion(assetDigests(capturedPage))
            }
            XCTAssertTrue(Set(committed.blobs.values.map(AIHash.digest)).isDisjoint(with: contextRefs),
                          "Reverse bridge exposed native archives in Notes CAS")
            let profiles = store.aiCaptureCache.lastProfiles
            XCTAssertEqual(profiles.count, context.pages.count)
            XCTAssertTrue(profiles.allSatisfy { !$0.onMainThread })
            let finalState = try await sync.fetchIncremental(local: localLibrary)
            let after = try XCTUnwrap(finalState.package)
            for (id, oldState) in unrelatedStates {
                let newState = try await sync.fetchDocument(id, local: localLibrary.document(id))
                XCTAssertEqual(newState.documentDigest, oldState.documentDigest)
                XCTAssertEqual(newState.lastSyncedAt, oldState.lastSyncedAt, "Terminal Sync republished an unrelated document")
            }
            XCTAssertEqual(after.notebooks.map(\.id).sorted { $0.uuidString < $1.uuidString },
                           before.notebooks.map(\.id).sorted { $0.uuidString < $1.uuidString })
            for other in before.notebooks where other.id != target.documentID {
                XCTAssertEqual(try after.document(other.id).encoded(), try before.document(other.id).encoded(),
                               "Terminal document Sync changed unrelated Source")
            }
            XCTAssertEqual(try AIHash.encoded(after.folders), try AIHash.encoded(before.folders))
            XCTAssertEqual(store.notebook(target.documentID)?.currentPage, visiblePageA ? pageA : book.currentPage)
            XCTAssertTrue(zip(rootSubviews, controller.view.subviews).allSatisfy { pair in pair.0 === pair.1 })
            XCTAssertEqual(rootSubviews.count, controller.view.subviews.count)
            if let visibleCanvas, let viewport {
                XCTAssertTrue(descendants(controller.view).contains { $0 === visibleCanvas })
                XCTAssertTrue(descendants(controller.view).contains { $0 === viewport })
                XCTAssertEqual(viewport.surface.transform, transform)
                XCTAssertEqual(viewport.surface.bounds, surfaceBounds)
                XCTAssertEqual(visibleCanvas.drawing, try XCTUnwrap(visibleDrawing))
            } else {
                XCTAssertFalse(descendants(controller.view).contains { $0 is DrawingCanvas || $0 is PageViewport })
            }
            try write(contextBytes, to: directory.appendingPathComponent("context.json"))
            try write(try committed.encoded(), to: directory.appendingPathComponent("committed-source.json"))
            try writeJSON(receipt, to: directory.appendingPathComponent("source-receipt.json"))
            stage = "verified"
        } catch { testFailure = error }
        if !backgroundStarted { foregroundOutcomes = socketDelegate.transportOutcomes + sourceDelegate.transportOutcomes }
        if testFailure == nil, let failure = foregroundOutcomes.first(where: \.failed) {
            testFailure = IntegrationFailure("Native foreground transport failed: " + failure.summary)
        }
        if testFailure == nil && (testRun?.failureCount ?? 0) > failuresBefore {
            testFailure = IntegrationFailure("Native reverse Sync verification assertion failed")
        }

        // Do not tear down a detached presenting root or let early ARC release
        // close a transport while foreground callbacks are still unwinding.
        let drained = await drainForeground(testController, sessions: sessions)
        if let controller = testController, controller.presentedViewController != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                controller.dismiss(animated: false) { continuation.resume() }
            }
        }
        UserDefaults.standard.set(originalOrientation, forKey: DocumentOrientation.defaultsKey)
        testWindow?.isHidden = true
        testWindow?.rootViewController = nil
        hostWindow?.makeKeyAndVisible()
        hostWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: DocumentOrientation.saved().supportedInterfaceOrientations))
        if !drained && testFailure == nil { testFailure = IntegrationFailure("Foreground transports did not quiesce within 5 seconds") }
        let failureDescription: String?
        if let failure = testFailure as? IntegrationFailure { failureDescription = failure.description }
        else if let failure = testFailure {
            let error = failure as NSError
            failureDescription = "\(error.domain) \(error.code)"
        } else { failureDescription = nil }
        let nativeOutcomes = (socketDelegate.transportOutcomes + sourceDelegate.transportOutcomes)
            .sorted { $0.completedAtUptime < $1.completedAtUptime }
        let report: [String: String] = ["outcome": testFailure == nil ? "passed" : "failed", "stage": stage,
            "responseError": failureDescription ?? "none", "lastManagerStatus": lastReceipt?.status ?? "none",
            "documentID": target.documentID.uuidString, "templateDocumentID": template.documentID.uuidString,
            "requestID": lastReceipt?.requestID.uuidString ?? "none", "focusPageID": target.focusPageID.uuidString,
            "lastNativeTransportStage": nativeOutcomes.last?.stage ?? "none",
            "nativeTransportFailures": String(foregroundOutcomes.filter(\.failed).count),
            "driverTransportFailures": String(driverDelegate.transportOutcomes.filter(\.failed).count),
            "webSocketOpened": String(socketDelegate.webSocketCounts.opened),
            "webSocketCompleted": String(socketDelegate.webSocketCounts.completed),
            "foregroundTransportsDrained": String(drained), "seconds": String(ProcessInfo.processInfo.systemUptime - startedAt),
            "pipelineSeconds": pipelineStarted.map { String(ProcessInfo.processInfo.systemUptime - $0) } ?? "not-started"]
        try writeJSON(report, to: directory.appendingPathComponent("outcomes.json"))
        try writeJSON(nativeOutcomes, to: directory.appendingPathComponent("transport-outcomes.json"))
        try writeJSON(driverDelegate.transportOutcomes, to: directory.appendingPathComponent("driver-outcomes.json"))
        withExtendedLifetime((testController, testWindow, ai, sync, sessions)) {}
        if let failureDescription { throw IntegrationFailure("\(stage): \(failureDescription)") }
    }

    private func waitForApproval(_ client: AIClient, submission: AIRequestSubmission,
                                 statuses: @escaping @MainActor (String) -> Void) async throws -> AIRequestReceipt {
        try await withThrowingTaskGroup(of: AIRequestReceipt.self) { group in
            group.addTask { @MainActor in
                while true {
                    try Task.checkCancellation()
                    let receipt = try await client.status(submission.requestID)
                    guard receipt.documentID == submission.documentID else { throw IntegrationFailure("Wrong document receipt") }
                    statuses(receipt.status)
                    if ["failed", "interrupted"].contains(receipt.status) {
                        throw IntegrationFailure("Live request ended: " + receipt.status + " / " + (receipt.error?.code ?? "unknown"))
                    }
                    if receipt.status == "ready" { return receipt }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 180_000_000_000)
                throw IntegrationFailure("Live model/renderer exceeded 180 seconds")
            }
            defer { group.cancelAll() }
            let receipt = try await group.next()
            return try XCTUnwrap(receipt)
        }
    }

    private func freshBlueStroke(beyond bounds: CGRect) -> PKStroke {
        let x = max(20, bounds.isNull ? 20 : bounds.maxX + 24)
        let y: CGFloat = 48
        let points = [CGPoint(x: x, y: y), CGPoint(x: x + 18, y: y + 9)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.123456,
                size: CGSize(width: 4.12345, height: 5.23456), opacity: 1.25, force: 0.723456,
                azimuth: 0.321456, altitude: 1.234567, secondaryScale: 0.87654, threshold: 0.23456)
        }
        return PKStroke(ink: PKInk(.monoline, color: .systemBlue),
            path: PKStrokePath(controlPoints: points, creationDate: Date()), randomSeed: 0xBEEF)
    }

    func testRealHTTPCopiedFactorialModelNativeApplyPreservesLaterInk() async throws {
        let targets = try targets(), inputBefore = try inventory(input)
        defer { XCTAssertEqual(try? inventory(input), inputBefore, "Staged notes were modified") }
        let target = try XCTUnwrap(targets.first { $0.label.contains("factorial") })
        let (store, root) = try copiedStore(targets)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = oracles.appendingPathComponent(target.label)
        let ai = AIClient(endpoint: managerURL, token: fixtureToken, session: session())
        let sync = SyncClient(endpoint: sourceURL, token: fixtureToken, session: session())
        let source = try store.exportCurrentPackage(book: target.documentID)
        let absent = try await sync.fetchDocument(target.documentID, local: source)
        XCTAssertNil(absent.package, "App request test must remain unsynced")
        XCTAssertNil(absent.documentDigest)
        guard absent.package == nil else { throw IntegrationFailure("Copied UUID already published; restage fresh inputs") }
        let captured = try capture(target, store: store, directory: directory)
        let focusDrawing = try store.drawing(book: target.documentID, page: page(target, in: store))
        XCTAssertGreaterThan(focusDrawing.strokes.filter { QuestionInk.matches($0.ink.color) }.count, 1,
                             "Factorial target must contain the copied purple question")
        let journal = try AINetworkJournal(directory: root.appendingPathComponent("network"))
        let submission = try journal.prepare(documentID: target.documentID, focusPageID: target.focusPageID,
            context: captured.context.encoded(), assets: captured.assets)
        XCTAssertEqual(submission.contextSHA256, AIHash.digest(try captured.context.encoded()))
        try await ai.register(journal.state.clientID)
        try await ai.uploadAssets(journal.assets(for: submission))
        let started = Date()
        var outcomes: [String: String] = ["outcome": "failed", "documentID": target.documentID.uuidString,
                                        "requestID": submission.requestID.uuidString]
        var statuses: [String] = []
        defer {
            outcomes["totalSeconds"] = String(Date().timeIntervalSince(started))
            outcomes["statuses"] = statuses.joined(separator: ",")
            try? writeJSON(outcomes, to: directory.appendingPathComponent("outcomes.json"))
        }
        let submitted = try await ai.submit(submission)
        statuses.append(submitted.status)
        // Append after request capture/submission, before waiting for the worker.
        let currentPage = try page(target, in: store)
        let current = try store.drawing(book: target.documentID, page: currentPage)
        let blue = freshBlueStroke(beyond: current.bounds)
        XCTAssertFalse(blue.renderBounds.intersects(current.bounds), "Later stroke must not overlap captured ink")
        try store.commit(book: target.documentID, page: target.focusPageID,
            drawing: PKDrawing(strokes: current.strokes + [blue]))
        let committed = try store.drawing(book: target.documentID, page: page(target, in: store))
        let expected = try PortableStroke(XCTUnwrap(committed.strokes.last), includeSamples: false)
        XCTAssertFalse(captured.context.pages.flatMap(\.strokeTargets).contains { $0.id == expected.targetID })
        let approved = try await waitForApproval(ai, submission: submission) { status in
            if statuses.last != status { statuses.append(status) }
        }
        outcomes["modelSeconds"] = String(Date().timeIntervalSince(started))
        let sha = try XCTUnwrap(approved.resultSHA256)
        let bytes = try await ai.download(sha, maxBytes: SyncObjects.metadataLimit)
        XCTAssertEqual(AIHash.digest(bytes), sha)
        let result = try AIResult.approved(data: bytes)
        XCTAssertEqual(try result.digest(), sha)
        XCTAssertEqual(result.requestID, submission.requestID)
        XCTAssertEqual(result.documentID, target.documentID)
        XCTAssertEqual(result.contextSHA256, submission.contextSHA256)
        try write(bytes, to: directory.appendingPathComponent("approved-result.json"))
        let objects = result.pageEdits.flatMap(\.objectEdits).compactMap(\.object)
        XCTAssertFalse(objects.isEmpty, "Live model must produce page objects")
        for object in objects {
            try object.validate()
            XCTAssertFalse(object.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(object.style.color.uppercased(), "#000000", "Generated answer must be black")
        }
        var assets: [String: Data] = [:]
        for object in objects where assets[object.asset.sha256] == nil {
            let bytes = try await ai.download(object.asset.sha256)
            try AIAssets.validate(data: bytes, asset: object.asset)
            assets[object.asset.sha256] = bytes
            try write(bytes, to: directory.appendingPathComponent("assets/" + object.asset.sha256))
        }
        var aggregateBytes = assets.values.reduce(0) { $0 + $1.count }
        for (pageID, digest) in result.previewSHA256s.sorted(by: { $0.key < $1.key }) {
            let preview = try await ai.download(digest)
            aggregateBytes += preview.count
            guard aggregateBytes <= 128 * 1024 * 1024 else { throw SyncError.tooLarge }
            let image = try XCTUnwrap(UIImage(data: preview)), cg = try XCTUnwrap(image.cgImage)
            try AIAssets.validate(data: preview, asset: AIAsset(sha256: digest, pixelWidth: cg.width, pixelHeight: cg.height))
            try write(preview, to: directory.appendingPathComponent("preview-" + pageID + ".PNG"))
            if pageID == target.focusPageID.uuidString || pageID == result.previewSHA256s.keys.sorted().first {
                try write(preview, to: directory.appendingPathComponent("preview.PNG"))
            }
        }
        let applyStart = Date()
        let receipt = try store.applyAI(result, assets: assets)
        XCTAssertEqual(receipt.resultSHA256, sha)
        XCTAssertTrue(receipt.skippedStrokeTargets.isEmpty)
        XCTAssertTrue(receipt.skippedObjectTargets.isEmpty)
        let reopened = Store(directory: root, migrateLegacyHistory: true)
        if let error = reopened.loadError { throw error }
        let remaining = try canonical(reopened.drawing(book: target.documentID, page: page(target, in: reopened)))
        let actual = try XCTUnwrap(remaining.first { $0.targetID == expected.targetID })
        XCTAssertEqual(try actual.fingerprint(), try expected.fingerprint())
        XCTAssertTrue(try AIHash.encoded(actual) == AIHash.encoded(expected), "Later archived stroke lost ID/geometry/attributes")
        let scene = reopened.notebook(target.documentID)!.pages.flatMap { reopened.objects(book: target.documentID, page: $0) }
        XCTAssertTrue(objects.allSatisfy { scene.contains($0) })
        let post = try capture(target, store: reopened, directory: directory.appendingPathComponent("postapply"))
        let focus = try XCTUnwrap(post.context.pages.first { $0.pageID == target.focusPageID })
        try write(XCTUnwrap(post.assets[focus.compositeSHA256]), to: directory.appendingPathComponent("postapply.PNG"))
        try write(try reopened.exportCurrentPackage(book: target.documentID).encoded(),
                  to: directory.appendingPathComponent("postapply-current-source.json"))
        try writeJSON(receipt, to: directory.appendingPathComponent("apply-receipt.json"))
        outcomes["applySeconds"] = String(Date().timeIntervalSince(applyStart))
        for edit in result.pageEdits { _ = try reopened.undo(book: target.documentID, page: edit.pageID) }
        let afterUndo = Store(directory: root, migrateLegacyHistory: true)
        let undoneBytes = try afterUndo.exportCurrentPackage().encoded()
        XCTAssertEqual(try afterUndo.applyAI(try AIResult.approved(data: bytes), assets: [:]), receipt)
        XCTAssertTrue(try afterUndo.exportCurrentPackage().encoded() == undoneBytes, "Receipt replay resurrected an undone answer")
        XCTAssertEqual(afterUndo.appliedAIReceipt(requestID: submission.requestID), receipt)
        try await ai.acknowledge(receipt, clientID: journal.state.clientID)
        try journal.finish(submission.requestID, needsAck: false)
        let stillAbsent = try await sync.fetchDocument(target.documentID, local: source)
        XCTAssertNil(stillAbsent.package, "App inference/apply must not publish native Source")
        XCTAssertNil(stillAbsent.documentDigest)
        outcomes["outcome"] = "passed"
        try writeJSON(outcomes, to: directory.appendingPathComponent("outcomes.json"))
    }

    // Re-key only these test copies, so this Source test cannot publish the UUIDs
    // used by the unsynced app test, regardless of XCTest ordering.
    private func freshSource(_ target: CopiedNoteTarget, store: Store) throws -> (SyncPackage, [String: PortablePage]) {
        var package = try store.exportCurrentPackage(book: target.documentID)
        let oldID = target.documentID, newID = UUID()
        package.notebooks[0].id = newID
        package.notebooks[0].name = "Test Source " + target.label + " " + newID.uuidString
        if package.notebooks[0].folderID != nil {
            let folder = UUID()
            package.notebooks[0].folderID = folder
            package.folders = [Folder(id: folder, name: "Test Folder " + folder.uuidString)]
        }
        package.blobs = Dictionary(uniqueKeysWithValues: package.blobs.map { key, value in
            (newID.uuidString + String(key.dropFirst(oldID.uuidString.count)), value)
        })
        let original = try store.exportPortablePages(pageSize: pageSize, book: oldID)
        let pages = Dictionary(uniqueKeysWithValues: original.map { key, value in
            (newID.uuidString + String(key.dropFirst(oldID.uuidString.count)), value)
        })
        try package.validate()
        return (package, pages)
    }

    func testRealHTTPCopiedDocumentSyncReceiptAndUnrelatedSourceCAS() async throws {
        let targets = try targets(), inputBefore = try inventory(input)
        defer { XCTAssertEqual(try? inventory(input), inputBefore, "Staged notes were modified") }
        let (store, root) = try copiedStore(targets)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SyncClient(endpoint: sourceURL, token: fixtureToken, session: session())
        let (unrelated, unrelatedPages) = try freshSource(XCTUnwrap(targets.first { $0.label == "mixed" }), store: store)
        let unrelatedID = unrelated.notebooks[0].id
        _ = try await client.uploadDocument(unrelated, documentID: unrelatedID, syncID: UUID(),
            baseDocumentDigest: nil, pages: unrelatedPages)
        let unrelatedBefore = try await client.fetchDocument(unrelatedID, local: unrelated)
        let (target, pages) = try freshSource(XCTUnwrap(targets.first { $0.label == "factorial" }), store: store)
        let documentID = target.notebooks[0].id, syncID = UUID()
        let receipt = try await client.uploadDocument(target, documentID: documentID, syncID: syncID,
            baseDocumentDigest: nil, pages: pages)
        let fetchedReceipt = try await client.fetchSyncReceipt(syncID)
        XCTAssertEqual(fetchedReceipt, receipt)
        let state = try await client.fetchDocument(documentID, local: target)
        XCTAssertEqual(state.documentDigest, receipt.documentDigest)
        XCTAssertEqual(state.lastSyncedAt, receipt.lastSyncedAt)
        XCTAssertTrue(try XCTUnwrap(state.package).encoded() == target.encoded(), "Native Source roundtrip changed bytes or metadata")
        let replay = try await client.uploadDocument(target, documentID: documentID, syncID: syncID,
            baseDocumentDigest: nil, pages: pages)
        XCTAssertEqual(replay, receipt)
        var changed = target
        changed.notebooks[0].name += " CAS update"
        do {
            _ = try await client.uploadDocument(changed, documentID: documentID, syncID: UUID(),
                baseDocumentDigest: nil, pages: pages)
            XCTFail("Absent baseline overwrote an existing copied document")
        } catch SyncError.conflict { /* Required CAS rejection. */ }
        let updated = try await client.uploadDocument(changed, documentID: documentID, syncID: UUID(),
            baseDocumentDigest: receipt.documentDigest, pages: pages)
        XCTAssertNotEqual(updated.documentDigest, receipt.documentDigest)
        let unrelatedAfter = try await client.fetchDocument(unrelatedID, local: unrelated)
        XCTAssertEqual(unrelatedAfter.documentDigest, unrelatedBefore.documentDigest)
        XCTAssertEqual(unrelatedAfter.lastSyncedAt, unrelatedBefore.lastSyncedAt)
        XCTAssertTrue(try XCTUnwrap(unrelatedAfter.package).encoded() == XCTUnwrap(unrelatedBefore.package).encoded(),
                      "Document Sync changed unrelated native Source")
        let originalReceipt = try await client.fetchSyncReceipt(syncID)
        XCTAssertEqual(originalReceipt, receipt, "Later Source publication changed a durable receipt")
        try writeJSON(receipt, to: oracles.appendingPathComponent("document-sync-receipt.json"))
        try writeJSON(["outcome": "passed", "documentID": documentID.uuidString,
                       "unrelatedDocumentID": unrelatedID.uuidString, "updatedDigest": updated.documentDigest],
                      to: oracles.appendingPathComponent("document-sync-outcomes.json"))
    }
}
