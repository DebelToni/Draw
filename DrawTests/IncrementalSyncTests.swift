import XCTest
import PencilKit
import UIKit
import CryptoKit
@testable import Draw

private struct IncrementalReply {
    var status = 200
    var headers: [String: String] = [:]
    var data: Data
}

private final class IncrementalStub: URLProtocol {
    private static let lock = NSLock()
    private static var fixtures: [String: IncrementalFixture] = [:]

    static func register(_ fixture: IncrementalFixture, host: String) {
        lock.lock()
        defer { lock.unlock() }
        fixtures[host] = fixture
    }

    static func remove(host: String) {
        lock.lock()
        defer { lock.unlock() }
        fixtures.removeValue(forKey: host)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let fixture = Self.fixtures[request.url!.host!]
        Self.lock.unlock()
        do {
            let reply = try XCTUnwrap(fixture).route(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                           httpVersion: nil, headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class IncrementalFixture {
    var revision = 0
    var manifest: [String: Any]?
    var scenes: [String: String] = [:]
    var objects: [String: Data] = [:]
    var objectUploads = 0
    var objectDownloads = 0
    var commits: [[String: Any]] = []
    var requestCount = 0
    var gzipResponses = false
    var alreadyDecodedResponses = false
    var intercept: ((URLRequest, Data) throws -> IncrementalReply?)?

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sourceManifest(_ package: SyncPackage) throws -> [String: Any] {
        var manifest = try JSONSerialization.jsonObject(with: package.encoded()) as! [String: Any]
        manifest["blobs"] = package.blobs.mapValues { hash($0) }
        manifest["assets"] = package.assets?.mapValues { hash($0) }
        return manifest
    }

    private func body(_ request: URLRequest) throws -> Data {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw stream.streamError ?? SyncError.invalidPackage }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        if request.httpMethod == "POST" {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
            return try SyncGzip.decode(data, limit: 128 * 1024 * 1024)
        }
        return data
    }

    private func json(_ value: [String: Any]) throws -> IncrementalReply {
        try reply(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }

    private func reply(_ data: Data) throws -> IncrementalReply {
        guard gzipResponses else { return IncrementalReply(data: data) }
        return IncrementalReply(headers: ["Content-Encoding": "gzip"], data: alreadyDecodedResponses
            ? data : try SyncGzip.encode(data, limit: 128 * 1024 * 1024))
    }

    func route(_ request: URLRequest) throws -> IncrementalReply {
        requestCount += 1
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "gzip")
        let data = try body(request)
        if let response = try intercept?(request, data) { return response }
        let path = request.url!.path
        switch (request.httpMethod!, path) {
        case ("GET", "/draw-sync/v2/state"):
            return try json(["revision": revision, "manifest": manifest as Any? ?? NSNull()])
        case ("POST", "/draw-sync/v2/objects/missing"):
            let request = try JSONSerialization.jsonObject(with: data) as! [String: [String]]
            let digests = request["digests"]!
            XCTAssertEqual(Set(digests).count, digests.count)
            return try json(["missing": digests.filter { objects[$0] == nil }])
        case ("POST", "/draw-sync/v2/state"):
            let commit = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            guard commit["baseRevision"] as? Int == revision else {
                return IncrementalReply(status: 409, data: Data())
            }
            let next = commit["manifest"] as! [String: Any]
            let nextScenes = commit["scenes"] as! [String: String]
            let digests = (next["blobs"] as! [String: String]).values
            XCTAssertTrue(digests.allSatisfy { objects[$0] != nil })
            XCTAssertTrue(nextScenes.values.allSatisfy { objects[$0] != nil })
            if manifest == nil || !NSDictionary(dictionary: manifest!).isEqual(to: next) { revision += 1 }
            manifest = next
            scenes = nextScenes
            commits.append(commit)
            return try json(["revision": revision])
        default:
            guard path.hasPrefix("/draw-sync/v2/objects/") else { throw SyncError.invalidPackage }
            let digest = request.url!.lastPathComponent
            if request.httpMethod == "GET" {
                objectDownloads += 1
                guard let data = objects[digest] else { return IncrementalReply(status: 404, data: Data()) }
                return try reply(data)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            XCTAssertEqual(Self.hash(data), digest)
            objectUploads += 1
            objects[digest] = data
            return try json(["digest": digest])
        }
    }
}

// Ordinary HTTP transport, with redirects disabled so this optional test can
// never forward a fixture write or its test-only token to another origin.
private final class FixtureHTTPSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var objectMethods: [String] = []

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let request = task.originalRequest, let url = request.url,
              url.path.hasPrefix("/v2/objects/"), url.lastPathComponent.count == 64 else { return }
        lock.lock()
        defer { lock.unlock() }
        objectMethods.append(request.httpMethod ?? "GET")
    }

    func objectRequestCount(method: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return objectMethods.filter { $0 == method }.count
    }
}

final class IncrementalSyncTests: XCTestCase {
    private var host: String!
    private var fixture: IncrementalFixture!
    private var client: SyncClient!

    override func setUpWithError() throws {
        host = UUID().uuidString.lowercased() + ".fixture"
        fixture = IncrementalFixture()
        IncrementalStub.register(fixture, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IncrementalStub.self]
        client = SyncClient(endpoint: URL(string: "https://\(host!)/draw-sync/v1/state")!, token: "test-token",
                            session: URLSession(configuration: config))
    }

    override func tearDownWithError() throws {
        client = nil
        IncrementalStub.remove(host: host)
    }

    private func drawing(_ count: Int) -> PKDrawing {
        let strokes = (0..<count).map { i in
            let point = PKStrokePoint(location: CGPoint(x: 40 + i * 8, y: 40), timeOffset: 0,
                                      size: CGSize(width: 4, height: 4), opacity: 1, force: 1,
                                      azimuth: 0, altitude: .pi / 2)
            return PKStroke(ink: PKInk(.monoline, color: .black),
                            path: PKStrokePath(controlPoints: [point], creationDate: Date(timeIntervalSince1970: 100)))
        }
        return PKDrawing(strokes: strokes)
    }

    private func package() throws -> SyncPackage {
        let head = UUID(), deletedHead = UUID()
        let page = Page(nodes: [HistoryNode(id: head, parent: nil)], head: head, preferredRoot: head)
        let deleted = Page(nodes: [HistoryNode(id: deletedHead, parent: nil)],
                           head: deletedHead, preferredRoot: deletedHead)
        let book = Notebook(name: "Current pages", pages: [page, Page()], deleted: [deleted])
        let archive = drawing(3).dataRepresentation()
        // Current active/deleted snapshot keys share one exact archive object.
        let package = SyncPackage(notebooks: [book], blobs: [
            SyncPackage.key(book.id, page.id, head): archive,
            SyncPackage.key(book.id, deleted.id, deletedHead): archive
        ])
        try package.validate()
        return package
    }

    private func localHistoryVariants(_ current: SyncPackage) throws -> [SyncPackage] {
        var variants: [SyncPackage] = []
        // Both active and deleted pages must be normalized for the wire, even
        // though these parent/child and undone-to-blank states are valid locally.
        for deleted in [false, true] {
            let page = deleted ? current.notebooks[0].deleted[0] : current.notebooks[0].pages[0]
            let root = page.head!
            let child = HistoryNode(id: UUID(), parent: root)
            var branched = page
            branched.nodes[0].children = [child.id]
            branched.nodes[0].preferredChild = child.id
            branched.nodes.append(child)
            branched.head = child.id
            var history = current
            if deleted { history.notebooks[0].deleted[0] = branched }
            else { history.notebooks[0].pages[0] = branched }
            history.blobs[SyncPackage.key(current.notebooks[0].id, page.id, child.id)] = drawing(4).dataRepresentation()
            variants.append(history)
            var blank = current
            if deleted { blank.notebooks[0].deleted[0].head = nil }
            else { blank.notebooks[0].pages[0].head = nil }
            variants.append(blank)
        }
        // An off-head independent root is also local undo, not remote source.
        var extraRoot = current
        let node = HistoryNode(id: UUID(), parent: nil)
        extraRoot.notebooks[0].pages[0].nodes.append(node)
        extraRoot.blobs[SyncPackage.key(current.notebooks[0].id, current.notebooks[0].pages[0].id, node.id)] = drawing(2).dataRepresentation()
        variants.append(extraRoot)
        for package in variants { try package.validate() }
        return variants
    }

    private func pages(_ package: SyncPackage) throws -> [String: PortablePage] {
        var result: [String: PortablePage] = [:]
        for book in package.notebooks {
            let pageSize = book.orientation == "landscape" ? CGSize(width: 1361, height: 1024) : CGSize(width: 1024, height: 1361)
            for page in book.pages + book.deleted {
                let drawing = try page.head.map { try PKDrawing(data: package.blobs[SyncPackage.key(book.id, page.id, $0)]!) } ?? PKDrawing()
                result["\(book.id.uuidString)/\(page.id.uuidString)"] = try PortablePage(
                    drawing: drawing, pageSize: pageSize, head: page.head)
            }
        }
        return result
    }

    private func publish(_ package: SyncPackage) throws {
        fixture.revision = 4
        fixture.manifest = try IncrementalFixture.sourceManifest(package)
        for data in package.blobs.values { fixture.objects[IncrementalFixture.hash(data)] = data }
    }

    private func assertSyncError(_ expected: String, operation: () async throws -> Void,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Accepted \(expected)", file: file, line: line) }
        catch {
            guard let error = error as? SyncError else {
                XCTFail("Wrong error: \(error)", file: file, line: line)
                return
            }
            switch (expected, error) {
            case ("invalid", .invalidPackage), ("conflict", .conflict), ("large", .tooLarge),
                 ("missingToken", .missingToken), ("404", .http(404)), ("401", .http(401)): break
            default: XCTFail("Wrong sync error: \(error)", file: file, line: line)
            }
        }
    }

    func testBaselineRepairRequiresExactPinsAndIgnoresStaleReceipt() throws {
        let package = try package()
        var local = package
        local.notebooks.append(Notebook(name: "Today's unsynced notes"))
        let previous = SyncBaseline(revision: 7, digest: String(repeating: "a", count: 64))
        let target = SyncBaseline(revision: 9, digest: try package.digest())
        let receipt = SyncBaselineRepair(previous: previous, target: target, localDigest: try local.digest())
        let repair = try JSONDecoder().decode(SyncBaselineRepair.self, from: JSONEncoder().encode(receipt))
        let remote = SyncState(revision: 9, package: package)
        XCTAssertThrowsError(try SyncDecision.choose(local: local, remote: remote, baseline: previous))
        let rebased = try repair.apply(local: local, remote: remote, baseline: previous)
        XCTAssertEqual(rebased, target)
        XCTAssertEqual(try SyncDecision.choose(local: local, remote: remote, baseline: rebased), .upload)
        XCTAssertEqual(local.notebooks.count, 2)
        XCTAssertEqual(local.notebooks[0].pages[0].head, package.notebooks[0].pages[0].head)
        var changedLocal = local, changedRemote = package
        changedLocal.notebooks[1].name += " changed"
        changedRemote.notebooks[0].name += " changed"
        for (source, state) in [(changedLocal, remote), (local, SyncState(revision: 9, package: changedRemote)),
                                (local, SyncState(revision: 8, package: package)), (local, SyncState(revision: 10, package: package)),
                                (local, SyncState(revision: 9, package: nil))] {
            XCTAssertThrowsError(try repair.apply(local: source, remote: state, baseline: previous)) { error in
                guard case SyncError.conflict = error else { return XCTFail("Wrong error: \(error)") }
            }
        }
        let regressed = SyncBaselineRepair(previous: previous, target: SyncBaseline(revision: 6, digest: target.digest), localDigest: repair.localDigest)
        XCTAssertThrowsError(try regressed.apply(local: local, remote: SyncState(revision: 6, package: package), baseline: previous)) { error in
            guard case SyncError.conflict = error else { return XCTFail("Wrong error: \(error)") }
        }
        let existing: [SyncBaseline?] = [nil, target, SyncBaseline(revision: 7, digest: "different"), SyncBaseline(revision: 10, digest: previous.digest)]
        for baseline in existing {
            // Ignore an obsolete receipt before evaluating even changed/missing pins.
            XCTAssertEqual(try repair.apply(local: changedLocal, remote: SyncState(revision: 0, package: nil), baseline: baseline), baseline)
        }
        XCTAssertEqual(fixture.requestCount, 0)
    }

    func testOptionalLocalHTTPFixtureIncrementalSyncAndAgentPNG() async throws {
        // Parent owns the disposable DB, server and SSH forward. No production
        // URL, bundle credential, environment override or server-provided URL is used.
        let origin = URL(string: "http://127.0.0.1:48279")!
        let endpoint = origin.appendingPathComponent("v1/state")
        let token = "portable-fixture-only"
        let delegate = FixtureHTTPSessionDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        func get(_ path: String, revision: Int? = nil) async throws -> Data {
            var components = URLComponents(url: origin.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            if let revision { components.queryItems = [URLQueryItem(name: "revision", value: String(revision))] }
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            let (data, response) = try await session.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            guard http.statusCode == 200 else { throw SyncError.http(http.statusCode) }
            // URLSession's real gzip decoder must provide the original bytes.
            return data
        }

        let probe: Data
        do { probe = try await get("v1/state") }
        catch let error as URLError where [.cannotConnectToHost, .timedOut, .networkConnectionLost,
                                           .notConnectedToInternet].contains(error.code) {
            throw XCTSkip("Optional localhost:48279 fixture is not running")
        }
        let initial = try JSONDecoder().decode(SyncState.self, from: probe)
        guard initial.revision == 0, initial.package == nil else {
            throw XCTSkip("Optional HTTP fixture requires a freshly cleared temporary DB")
        }

        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.monoline, color: MissedInk.color),
            path: drawing(1).strokes[0].path)]) // Legacy teal at (40, 40), classified as Question without recoloring.
        let archive = drawing.dataRepresentation()
        let node = HistoryNode(id: UUID(), parent: nil)
        let page = Page(nodes: [node], head: node.id, preferredRoot: node.id)
        let date = Date(timeIntervalSince1970: 100)
        let book = Notebook(name: "Portable HTTP fixture", created: date, modified: date,
                            pages: [page], currentPage: page.id, orientation: "landscape")
        let source = SyncPackage(notebooks: [book], blobs: [SyncPackage.key(book.id, page.id, node.id): archive])
        try source.validate()
        let key = "\(book.id.uuidString)/\(page.id.uuidString)"
        let portable = try PortablePage(drawing: drawing, pageSize: CGSize(width: 1361, height: 1024), head: node.id)
        let pages = [key: portable]
        let client = SyncClient(endpoint: endpoint, token: token, session: session)
        let empty = try await client.fetchIncremental(local: source)
        XCTAssertNil(empty.package)
        XCTAssertEqual(try SyncDecision.choose(local: source, remote: empty, baseline: nil), .upload)
        let revision = try await client.uploadIncremental(source, baseRevision: empty.revision, pages: pages)
        XCTAssertEqual(revision, 1)
        XCTAssertEqual(delegate.objectRequestCount(method: "POST"), 2)

        let downloads = delegate.objectRequestCount(method: "GET")
        let reused = try await client.fetchIncremental(local: source)
        XCTAssertEqual(reused.revision, revision)
        XCTAssertEqual(try reused.package?.encoded(), try source.encoded())
        XCTAssertEqual(reused.package?.notebooks[0].orientation, "landscape")
        XCTAssertEqual(delegate.objectRequestCount(method: "GET"), downloads)
        let baseline = SyncBaseline(revision: revision, digest: try source.digest())
        XCTAssertEqual(try SyncDecision.choose(local: source, remote: reused, baseline: baseline), .unchanged)
        let uploads = delegate.objectRequestCount(method: "POST")
        let repeated = try await client.uploadIncremental(source, baseRevision: revision, pages: pages)
        XCTAssertEqual(repeated, revision)
        XCTAssertEqual(delegate.objectRequestCount(method: "POST"), uploads)

        let fresh = try await client.fetchIncremental(local: SyncPackage(notebooks: [], blobs: [:]))
        XCTAssertEqual(try fresh.package?.digest(), try source.digest())
        XCTAssertEqual(fresh.package?.notebooks[0].orientation, "landscape")
        XCTAssertEqual(delegate.objectRequestCount(method: "GET") - downloads, 1)
        let stateJSON = try JSONSerialization.jsonObject(with: await get("v2/state")) as! [String: Any]
        let manifest = try XCTUnwrap(stateJSON["manifest"] as? [String: Any])
        XCTAssertEqual(manifest["blobs"] as? [String: String], source.blobs.mapValues { IncrementalFixture.hash($0) })
        XCTAssertNil(manifest["images"])
        XCTAssertEqual((manifest["notebooks"] as? [[String: Any]])?.first?["orientation"] as? String, "landscape")
        let native = try await get("v2/objects/" + IncrementalFixture.hash(archive))
        XCTAssertEqual(native, archive)
        let scene = try await get("v2/objects/" + portable.digest())
        XCTAssertEqual(scene, try portable.encoded())
        let legacy = try JSONDecoder().decode(SyncState.self, from: await get("v1/state"))
        XCTAssertEqual(try legacy.package?.digest(), try source.digest())

        let documentPath = "v1/documents/\(book.id.uuidString)"
        let document = try JSONSerialization.jsonObject(with: await get(documentPath, revision: revision)) as! [String: Any]
        XCTAssertEqual(document["revision"] as? Int, revision)
        let pageInfo = try XCTUnwrap((document["pages"] as? [[String: Any]])?.first)
        XCTAssertEqual(pageInfo["id"] as? String, page.id.uuidString)
        XCTAssertEqual(pageInfo["head"] as? String, node.id.uuidString)
        XCTAssertEqual(pageInfo["historyCount"] as? Int, 1)
        XCTAssertEqual(pageInfo["imagePaper"] as? String, "lines")
        let metadata = try XCTUnwrap(pageInfo["image"] as? [String: Any])
        XCTAssertEqual(metadata["head"] as? String, node.id.uuidString)
        XCTAssertEqual(metadata["width"] as? Int, 2722)
        XCTAssertEqual(metadata["height"] as? Int, 2048)
        XCTAssertEqual(metadata["strokeCount"] as? Int, 1)
        XCTAssertEqual(metadata["inkTypes"] as? [String], Array(Set(portable.strokes.map(\.inkType))).sorted())
        XCTAssertEqual(metadata["rendererVersion"] as? Int, 3)
        XCTAssertEqual(metadata["tagStrokeCounts"] as? [String: Int], ["question": 1])
        XCTAssertEqual(pageInfo["tags"] as? [String], ["question"])
        let pngPath = documentPath + "/pages/\(page.id.uuidString).png"
        XCTAssertEqual(pageInfo["png"] as? String, "/draw-sync/" + pngPath + "?revision=\(revision)")
        // Reconstruct the localhost URL; never follow the metadata's URL directly.
        let png = try await get(pngPath, revision: revision)
        XCTAssertTrue(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
        XCTAssertEqual(image.width, 2722)
        XCTAssertEqual(image.height, 2048)

        // Replace the current root, then check that neither the old revision
        // nor its native/scene CAS objects remain remotely readable.
        let nextDrawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.monoline, color: MissedInk.color),
            path: self.drawing(2).strokes[1].path)])
        let nextNode = HistoryNode(id: UUID(), parent: nil)
        var next = source
        next.notebooks[0].pages[0].nodes = [nextNode]
        next.notebooks[0].pages[0].head = nextNode.id
        next.notebooks[0].pages[0].preferredRoot = nextNode.id
        next.blobs = [SyncPackage.key(book.id, page.id, nextNode.id): nextDrawing.dataRepresentation()]
        let nextPortable = try PortablePage(drawing: nextDrawing, pageSize: CGSize(width: 1361, height: 1024), head: nextNode.id)
        let nextRevision = try await client.uploadIncremental(next, baseRevision: revision, pages: [key: nextPortable])
        XCTAssertEqual(nextRevision, revision + 1)
        let latest = try await client.fetchIncremental(local: next)
        XCTAssertEqual(latest.revision, nextRevision)
        XCTAssertEqual(try latest.package?.encoded(), try next.encoded())
        let latestLegacy = try JSONDecoder().decode(SyncState.self, from: await get("v1/state"))
        XCTAssertEqual(try latestLegacy.package?.digest(), try next.digest())
        let latestDocument = try JSONSerialization.jsonObject(with: await get(documentPath, revision: nextRevision)) as! [String: Any]
        let latestPage = try XCTUnwrap((latestDocument["pages"] as? [[String: Any]])?.first)
        XCTAssertEqual(latestPage["historyCount"] as? Int, 1)
        XCTAssertEqual(latestPage["head"] as? String, nextNode.id.uuidString)
        await assertSyncError("404") { _ = try await get(documentPath, revision: revision) }
        await assertSyncError("404") { _ = try await get(pngPath, revision: revision) }
        await assertSyncError("404") { _ = try await get("v2/objects/" + IncrementalFixture.hash(archive)) }
        await assertSyncError("404") { _ = try await get("v2/objects/" + portable.digest()) }
        XCTAssertEqual(fixture.requestCount, 0, "Real HTTP integration must not use URLProtocol mocks")
    }

    func testOptionalLocalHTTPSlowCommitReceivesReceiptWithDefaultTimeouts() async throws {
        // Parent supplies a fresh scratch DB and a 17-second commit_manifest
        // delay on this separate loopback fixture. Never use production credentials.
        let endpoint = URL(string: "http://127.0.0.1:48280/v1/state")!
        let token = "portable-fixture-only"
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 10
        config.urlCache = nil
        let probeSession = URLSession(configuration: config, delegate: FixtureHTTPSessionDelegate(), delegateQueue: nil)
        defer { probeSession.invalidateAndCancel() }
        var probeRequest = URLRequest(url: endpoint)
        probeRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        probeRequest.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let initial: SyncState
        do {
            let (data, response) = try await probeSession.data(for: probeRequest)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            guard http.statusCode == 200 else { throw SyncError.http(http.statusCode) }
            initial = try JSONDecoder().decode(SyncState.self, from: data)
        } catch let error as URLError where [.cannotConnectToHost, .timedOut, .networkConnectionLost,
                                            .notConnectedToInternet].contains(error.code) {
            throw XCTSkip("Optional localhost:48280 slow-commit fixture is not running")
        }
        guard initial.revision == 0, initial.package == nil else {
            throw XCTSkip("Optional slow-commit fixture requires a freshly cleared temporary DB")
        }

        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.monoline, color: MissedInk.color),
            path: drawing(1).strokes[0].path)])
        let archive = drawing.dataRepresentation()
        let node = HistoryNode(id: UUID(), parent: nil)
        let page = Page(nodes: [node], head: node.id, preferredRoot: node.id)
        let date = Date(timeIntervalSince1970: 100)
        let book = Notebook(name: "Slow commit HTTP fixture", created: date, modified: date,
                            pages: [page], currentPage: page.id)
        let source = SyncPackage(notebooks: [book], blobs: [SyncPackage.key(book.id, page.id, node.id): archive])
        try source.validate()
        let portable = try PortablePage(drawing: drawing, pageSize: CGSize(width: 128, height: 160), head: node.id)
        let pages = ["\(book.id.uuidString)/\(page.id.uuidString)": portable]
        // Deliberately do not inject a session: regression coverage must exercise
        // SyncClient's production defaults, not the short presence-probe timeouts.
        let defaultClient = SyncClient(endpoint: endpoint, token: token)
        let empty = try await defaultClient.fetchIncremental(local: source)
        guard empty.revision == 0, empty.package == nil else {
            throw XCTSkip("Optional slow-commit fixture is no longer empty")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let revision = try await defaultClient.uploadIncremental(source, baseRevision: empty.revision, pages: pages)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 17,
                                   "Fixture must delay the commit past the old 15-second request timeout")
        XCTAssertEqual(revision, 1, "The delayed commit must return its receipt, not just publish server state")
        let reused = try await defaultClient.fetchIncremental(local: source)
        XCTAssertEqual(reused.revision, revision)
        XCTAssertEqual(try reused.package?.encoded(), try source.encoded())
        let currentPage = try XCTUnwrap(reused.package?.notebooks.first?.pages.first)
        XCTAssertEqual(currentPage.nodes.count, 1)
        XCTAssertEqual(currentPage.nodes[0].id, currentPage.head)
        XCTAssertNil(currentPage.nodes[0].parent)
        XCTAssertTrue(currentPage.nodes[0].children.isEmpty)
        let baseline = SyncBaseline(revision: revision, digest: try source.digest())
        XCTAssertEqual(try SyncDecision.choose(local: source, remote: reused, baseline: baseline), .unchanged)
        XCTAssertEqual(fixture.requestCount, 0, "Slow commit must use real HTTP without URLProtocol mocks")
    }

    func testRepeatedSyncUploadsNoObjectsAndCommitsOnlyMetadata() async throws {
        let package = try package()
        let portable = try pages(package)
        fixture.gzipResponses = true
        let empty = try await client.fetchIncremental(local: package)
        XCTAssertNil(empty.package)
        let revision = try await client.uploadIncremental(package, baseRevision: empty.revision, pages: portable)
        XCTAssertEqual(revision, 1)
        XCTAssertGreaterThan(fixture.objectUploads, 0)
        let firstUploads = fixture.objectUploads
        let state = try await client.fetchIncremental(local: package)
        XCTAssertEqual(try state.package?.digest(), try package.digest())
        XCTAssertEqual(fixture.objectDownloads, 0)
        XCTAssertEqual(try SyncDecision.choose(local: package, remote: state, baseline: nil), .unchanged)
        let repeated = try await client.uploadIncremental(package, baseRevision: state.revision, pages: portable)
        XCTAssertEqual(repeated, revision)
        XCTAssertEqual(fixture.objectUploads, firstUploads)
        let commit = try XCTUnwrap(fixture.commits.last)
        XCTAssertEqual(Set(commit.keys), ["baseRevision", "manifest", "scenes"])
        let manifest = commit["manifest"] as! [String: Any]
        let blobs = manifest["blobs"] as! [String: String]
        XCTAssertTrue(blobs.values.allSatisfy { $0.count == 64 })
        let metadata = try JSONSerialization.data(withJSONObject: commit)
        let text = String(decoding: metadata, as: UTF8.self)
        XCTAssertFalse(text.contains("png"))
        XCTAssertFalse(text.contains("images"))
        for data in package.blobs.values { XCTAssertFalse(text.contains(data.base64EncodedString())) }
        XCTAssertEqual(fixture.scenes.count, portable.count)
        for (key, page) in portable { XCTAssertEqual(fixture.scenes[key], try page.digest()) }
    }

    func testNestedFormatThreeManifestRoundTripWithoutAIAndInvalidGraphsFailBeforeTransfer() async throws {
        var source = try package()
        let parent = Folder(name: "Semester"), unrelated = Folder(name: "Unrelated")
        let child = Folder(name: "Math", parentID: parent.id)
        source.format = 3
        source.folders = [parent, child, unrelated]
        source.notebooks[0].folderID = child.id
        try source.validate()
        let revision = try await client.uploadIncremental(source, baseRevision: 0, pages: source.portablePages())
        XCTAssertEqual(fixture.manifest?["format"] as? Int, 3)
        XCTAssertNil(fixture.manifest?["assets"])
        let reused = try await client.fetchIncremental(local: source)
        XCTAssertEqual(try reused.package?.encoded(), try source.encoded())
        let fresh = try await client.fetchIncremental(local: SyncPackage(notebooks: [], blobs: [:]))
        XCTAssertEqual(fresh.revision, revision)
        XCTAssertEqual(try fresh.package?.encoded(), try source.encoded())
        let doc = try source.document(source.notebooks[0].id)
        XCTAssertEqual(doc.folders?.map(\.id), [parent.id, child.id])
        for kind in 0..<4 {
            var bad = source
            switch kind {
            case 0: bad.format = 1
            case 1: bad.folders![0].parentID = child.id
            case 2: bad.folders![1].parentID = UUID()
            default: bad.folders!.append(child)
            }
            let requests = fixture.requestCount, downloads = fixture.objectDownloads
            await assertSyncError("invalid") {
                _ = try await self.client.uploadIncremental(bad, baseRevision: revision, pages: source.portablePages())
            }
            XCTAssertEqual(fixture.requestCount, requests)
            fixture.manifest = try IncrementalFixture.sourceManifest(bad)
            await assertSyncError("invalid") {
                _ = try await self.client.fetchIncremental(local: SyncPackage(notebooks: [], blobs: [:]))
            }
            XCTAssertEqual(fixture.requestCount, requests + 1)
            XCTAssertEqual(fixture.objectDownloads, downloads)
        }
    }

    func testLegacySourceOnlySyncAddsScenesWithoutNativeUploads() async throws {
        let source = try package()
        try publish(source)
        let state = try await client.fetchIncremental(local: source)
        XCTAssertEqual(try SyncDecision.choose(local: source, remote: state,
            baseline: SyncBaseline(revision: 4, digest: try source.digest())), .unchanged)
        let portable = try pages(source)
        let revision = try await client.uploadIncremental(source, baseRevision: 4, pages: portable)
        XCTAssertEqual(revision, 4)
        XCTAssertEqual(fixture.objectUploads, Set(try portable.values.map { try $0.digest() }).count)
        XCTAssertEqual(fixture.objectDownloads, 0)
    }

    func testChangedDrawingUploadsOnlyNewArchiveAndScene() async throws {
        var source = try package()
        _ = try await client.uploadIncremental(source, baseRevision: 0, pages: pages(source))
        let uploads = fixture.objectUploads
        let book = source.notebooks[0].id
        let page = source.notebooks[0].pages[0].id
        let previous = source.notebooks[0].pages[0].head!
        let node = HistoryNode(id: UUID(), parent: nil)
        source.notebooks[0].pages[0].nodes = [node]
        source.notebooks[0].pages[0].head = node.id
        source.notebooks[0].pages[0].preferredRoot = node.id
        source.blobs.removeValue(forKey: SyncPackage.key(book, page, previous))
        source.blobs[SyncPackage.key(book, page, node.id)] = drawing(4).dataRepresentation()
        let revision = try await client.uploadIncremental(source, baseRevision: 1, pages: pages(source))
        XCTAssertEqual(revision, 2)
        XCTAssertEqual(fixture.objectUploads - uploads, 2)
        let latest = try await client.fetchIncremental(local: source)
        XCTAssertEqual(latest.package?.notebooks[0].pages[0].nodes.count, 1)
        XCTAssertEqual(latest.package?.notebooks[0].pages[0].nodes[0].id, node.id)
        XCTAssertNil(latest.package?.blobs[SyncPackage.key(book, page, previous)])
    }

    func testFreshInstallDownloadsUniqueHashesAndPreservesLegacyDigest() async throws {
        let source = try package()
        try publish(source)
        fixture.gzipResponses = true
        let state = try await client.fetchIncremental(local: SyncPackage(notebooks: [], blobs: [:]))
        let assembled = try XCTUnwrap(state.package)
        XCTAssertEqual(try assembled.encoded(), try source.encoded())
        XCTAssertEqual(fixture.objectDownloads, Set(source.blobs.values.map { IncrementalFixture.hash($0) }).count)
        XCTAssertEqual(try SyncDecision.choose(local: SyncPackage(notebooks: [], blobs: [:]), remote: state, baseline: nil), .download)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root)
        try store.importPackage(assembled)
        XCTAssertEqual(try store.exportCurrentPackage().digest(), try source.digest())
        XCTAssertEqual(store.notebooks[0].pages[0].nodes.count, 1)
        XCTAssertTrue(store.notebooks[0].pages[0].nodes[0].children.isEmpty)
        XCTAssertEqual(store.notebooks[0].deleted[0].nodes.count, 1)
        XCTAssertEqual(store.notebooks[0].deleted.count, 1)
        let baseline = SyncBaseline(revision: 4, digest: try source.digest())
        XCTAssertEqual(try SyncDecision.choose(local: source, remote: state, baseline: baseline), .unchanged)
        var changed = source
        changed.notebooks[0].name = "Changed metadata"
        XCTAssertEqual(try SyncDecision.choose(local: changed, remote: state, baseline: baseline), .upload)
        var advanced = state
        advanced.revision = 5
        advanced.package = changed
        XCTAssertEqual(try SyncDecision.choose(local: source, remote: advanced, baseline: baseline), .download)
        XCTAssertThrowsError(try SyncDecision.choose(local: changed, remote: SyncState(revision: 5, package: source), baseline: baseline))
        XCTAssertThrowsError(try SyncDecision.choose(local: source, remote: SyncState(revision: 0, package: nil), baseline: baseline))
    }

    func testLocalReuseIsByHashNotSnapshotKeyAndToleratesDecodedGzip() async throws {
        let source = try package()
        try publish(source)
        fixture.gzipResponses = true
        fixture.alreadyDecodedResponses = true
        let local = SyncPackage(notebooks: [], blobs: Dictionary(uniqueKeysWithValues:
            source.blobs.values.enumerated().map { ("other-key-\($0.offset)", $0.element) }))
        let state = try await client.fetchIncremental(local: local)
        XCTAssertEqual(try state.package?.digest(), try source.digest())
        XCTAssertEqual(fixture.objectDownloads, 0)
    }

    func testUploadLocalHistoryRejectedBeforeAnyObjectRequest() async throws {
        let current = try package()
        for history in try localHistoryVariants(current) {
            // The generalized validator must continue accepting full iPad history.
            try history.validate()
            let portable = try pages(history)
            await assertSyncError("invalid") {
                _ = try await self.client.uploadIncremental(history, baseRevision: 0, pages: portable)
            }
        }
        XCTAssertEqual(fixture.requestCount, 0, "Reject history before even the CAS missing-list request")
        XCTAssertEqual(fixture.objectUploads, 0)
        XCTAssertTrue(fixture.commits.isEmpty)
    }

    func testRemoteHistoryRejectedBeforeAnyObjectDownload() async throws {
        let current = try package()
        let empty = SyncPackage(notebooks: [], blobs: [:])
        fixture.revision = 4
        for history in try localHistoryVariants(current) {
            try history.validate()
            fixture.manifest = try IncrementalFixture.sourceManifest(history)
            let requests = fixture.requestCount
            await assertSyncError("invalid") { _ = try await self.client.fetchIncremental(local: empty) }
            XCTAssertEqual(fixture.requestCount, requests + 1, "Only the manifest GET is allowed")
        }
        XCTAssertEqual(fixture.objectDownloads, 0)
    }

    func testCurrentManifestReusesArchivesFromFullLocalHistory() async throws {
        let current = try package()
        let history = try localHistoryVariants(current)[0]
        try history.validate()
        try publish(current)
        let state = try await client.fetchIncremental(local: history)
        XCTAssertEqual(try state.package?.encoded(), try current.encoded())
        XCTAssertNotEqual(try history.digest(), try current.digest())
        let baseline = SyncBaseline(revision: state.revision, digest: try current.digest())
        XCTAssertEqual(try SyncDecision.choose(local: current, remote: state, baseline: baseline), .unchanged)
        XCTAssertEqual(fixture.objectDownloads, 0)
    }

    func testNonRootCurrentNodeFieldsAndBlankPreferredRootAreRejectedBeforeTransfer() async throws {
        let current = try package()
        var variants: [SyncPackage] = []
        var invalid = current
        invalid.notebooks[0].pages[0].nodes[0].parent = UUID()
        variants.append(invalid)
        invalid = current
        invalid.notebooks[0].pages[0].nodes[0].children = [UUID()]
        variants.append(invalid)
        invalid = current
        invalid.notebooks[0].pages[0].nodes[0].preferredChild = UUID()
        variants.append(invalid)
        invalid = current
        invalid.notebooks[0].pages[0].preferredRoot = UUID()
        variants.append(invalid)
        invalid = current
        invalid.notebooks[0].pages[1].preferredRoot = UUID()
        variants.append(invalid)
        let portable = try pages(current)
        for package in variants {
            let requests = fixture.requestCount
            await assertSyncError("invalid") {
                _ = try await self.client.uploadIncremental(package, baseRevision: 0, pages: portable)
            }
            XCTAssertEqual(fixture.requestCount, requests)
            fixture.revision = 4
            fixture.manifest = try IncrementalFixture.sourceManifest(package)
            await assertSyncError("invalid") {
                _ = try await self.client.fetchIncremental(local: SyncPackage(notebooks: [], blobs: [:]))
            }
            XCTAssertEqual(fixture.requestCount, requests + 1)
        }
        XCTAssertEqual(fixture.objectUploads, 0)
        XCTAssertEqual(fixture.objectDownloads, 0)
    }

    func testAllowedOrientationsRoundTripWithReusedAndFreshDownloads() async throws {
        let orientations: [String?] = [nil, "portrait", "landscape"]
        for orientation in orientations {
            var source = try package()
            source.notebooks[0].orientation = orientation
            try source.validate()
            let portable = try pages(source)
            let revision = try await client.uploadIncremental(source, baseRevision: fixture.revision, pages: portable)
            let commit = try XCTUnwrap(fixture.commits.last)
            let manifest = try XCTUnwrap(commit["manifest"] as? [String: Any])
            let book = try XCTUnwrap((manifest["notebooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(book["orientation"] as? String, orientation)
            if orientation == nil { XCTAssertNil(book["orientation"], "Legacy nil must stay omitted from canonical JSON") }
            let expectedSize = orientation == "landscape" ? CGSize(width: 1361, height: 1024) : CGSize(width: 1024, height: 1361)
            for page in portable.values {
                XCTAssertEqual(page.width, Double(expectedSize.width))
                XCTAssertEqual(page.height, Double(expectedSize.height))
            }
            let downloads = fixture.objectDownloads
            let reused = try await client.fetchIncremental(local: source)
            XCTAssertEqual(reused.revision, revision)
            XCTAssertEqual(reused.package?.notebooks[0].orientation, orientation)
            XCTAssertEqual(try reused.package?.encoded(), try source.encoded())
            XCTAssertEqual(fixture.objectDownloads, downloads)
            let uploads = fixture.objectUploads
            let repeated = try await client.uploadIncremental(source, baseRevision: revision, pages: portable)
            XCTAssertEqual(repeated, revision)
            XCTAssertEqual(fixture.objectUploads, uploads)
            let fresh = try await client.fetchIncremental(local: SyncPackage(notebooks: [], blobs: [:]))
            XCTAssertEqual(fresh.package?.notebooks[0].orientation, orientation)
            XCTAssertEqual(try fresh.package?.digest(), try source.digest())
            XCTAssertEqual(fixture.objectDownloads - downloads, 1)
        }
    }

    func testInvalidOrientationsRejectedBeforeObjectTransfers() async throws {
        for orientation in ["", "Portrait", "LANDSCAPE", "square", " landscape", "portrait "] {
            var source = try package()
            source.notebooks[0].orientation = orientation
            XCTAssertThrowsError(try source.validate()) { error in
                guard case SyncError.invalidPackage = error else { return XCTFail("Wrong error: \(error)") }
            }
            let portable = try pages(source)
            let requests = fixture.requestCount
            await assertSyncError("invalid") {
                _ = try await self.client.uploadIncremental(source, baseRevision: 0, pages: portable)
            }
            XCTAssertEqual(fixture.requestCount, requests)
            fixture.revision = 4
            fixture.manifest = try IncrementalFixture.sourceManifest(source)
            await assertSyncError("invalid") {
                _ = try await self.client.fetchIncremental(local: SyncPackage(notebooks: [], blobs: [:]))
            }
            XCTAssertEqual(fixture.requestCount, requests + 1, "Only the malformed manifest GET is allowed")
        }
        XCTAssertEqual(fixture.objectUploads, 0)
        XCTAssertEqual(fixture.objectDownloads, 0)
    }

    func testInvalidManifestReferencesAndUniquenessFailBeforeDownloads() async throws {
        let source = try package()
        let good = try IncrementalFixture.sourceManifest(source)
        var variants: [[String: Any]] = []
        var bad = good
        bad["blobs"] = [String: String]()
        variants.append(bad)
        bad = good
        var blobs = bad["blobs"] as! [String: String]
        blobs[blobs.keys.first!] = String(repeating: "G", count: 64)
        bad["blobs"] = blobs
        variants.append(bad)
        bad = good
        blobs = bad["blobs"] as! [String: String]
        blobs["unreferenced"] = String(repeating: "a", count: 64)
        bad["blobs"] = blobs
        variants.append(bad)
        var duplicate = source
        duplicate.notebooks.append(source.notebooks[0])
        variants.append(try IncrementalFixture.sourceManifest(duplicate))
        duplicate = source
        duplicate.notebooks[0].deleted.append(source.notebooks[0].pages[0])
        variants.append(try IncrementalFixture.sourceManifest(duplicate))
        duplicate = source
        duplicate.notebooks[0].pages[0].head = UUID()
        variants.append(try IncrementalFixture.sourceManifest(duplicate))
        for manifest in variants {
            fixture.manifest = manifest
            await assertSyncError("invalid") { _ = try await self.client.fetchIncremental(local: source) }
        }
        XCTAssertEqual(fixture.objectDownloads, 0)
    }

    func testMissingAndCorruptObjectsFailWithoutAssembly() async throws {
        let source = try package()
        try publish(source)
        fixture.objects = [:]
        let empty = SyncPackage(notebooks: [], blobs: [:])
        await assertSyncError("404") { _ = try await self.client.fetchIncremental(local: empty) }
        for data in source.blobs.values { fixture.objects[IncrementalFixture.hash(data)] = Data("corrupt".utf8) }
        await assertSyncError("invalid") { _ = try await self.client.fetchIncremental(local: empty) }
        for data in source.blobs.values { fixture.objects[IncrementalFixture.hash(data)] = Data() }
        await assertSyncError("invalid") { _ = try await self.client.fetchIncremental(local: empty) }
    }

    func testMatchingHashDoesNotMakeInvalidNativeBytesValid() async throws {
        let source = try package()
        try publish(source)
        let invalid = Data("not a native drawing".utf8)
        let digest = IncrementalFixture.hash(invalid)
        fixture.manifest!["blobs"] = source.blobs.mapValues { _ in digest }
        fixture.objects = [digest: invalid]
        do {
            _ = try await client.fetchIncremental(local: SyncPackage(notebooks: [], blobs: [:]))
            XCTFail("Accepted invalid native archive")
        } catch {}
    }

    func testMalformedAndMissingStateFieldsAreRejected() async {
        for body in ["broken", "{\"revision\":0}", "{\"revision\":-1,\"manifest\":null}",
                     "{\"revision\":1,\"manifest\":null}", "{\"manifest\":null}"] {
            fixture.intercept = { _, _ in IncrementalReply(data: Data(body.utf8)) }
            await assertSyncError("invalid") { _ = try await self.client.fetchIncremental(local: SyncPackage(notebooks: [], blobs: [:])) }
        }
    }

    func testMissingCredentialFailsBeforeAnyRequest() async {
        let client = SyncClient(endpoint: URL(string: "https://\(host!)/draw-sync/v1/state")!, token: "$(UNSET)")
        await assertSyncError("missingToken") { _ = try await client.fetchIncremental(local: SyncPackage(notebooks: [], blobs: [:])) }
        XCTAssertEqual(fixture.requestCount, 0)
    }

    func testMissingListAndObjectReceiptAreVerified() async throws {
        let source = try package(), portable = try pages(source)
        for missing in [[String(repeating: "a", count: 64)], [String(repeating: "a", count: 64), String(repeating: "a", count: 64)]] {
            fixture.intercept = { request, _ in
                guard request.url!.lastPathComponent == "missing" else { return nil }
                return IncrementalReply(data: try JSONSerialization.data(withJSONObject: ["missing": missing]))
            }
            await assertSyncError("invalid") { _ = try await self.client.uploadIncremental(source, baseRevision: 0, pages: portable) }
        }
        XCTAssertEqual(fixture.objectUploads, 0)
        fixture.intercept = { request, _ in
            guard request.httpMethod == "POST", request.url!.lastPathComponent.count == 64 else { return nil }
            return IncrementalReply(data: Data("{\"digest\":\"wrong\"}".utf8))
        }
        await assertSyncError("invalid") { _ = try await self.client.uploadIncremental(source, baseRevision: 0, pages: portable) }
        XCTAssertTrue(fixture.commits.isEmpty)
    }

    func testConflictAuthenticationAndInvalidRevisionNeverConfirmSuccess() async throws {
        let source = try package(), portable = try pages(source)
        fixture.revision = 1
        await assertSyncError("conflict") { _ = try await self.client.uploadIncremental(source, baseRevision: 0, pages: portable) }
        XCTAssertTrue(fixture.commits.isEmpty)
        for (status, expected) in [(401, "401"), (409, "conflict"), (413, "large")] {
            fixture.intercept = { _, _ in IncrementalReply(status: status, data: Data()) }
            await assertSyncError(expected) { _ = try await self.client.fetchIncremental(local: source) }
        }
        fixture.intercept = { request, _ in
            guard request.httpMethod == "POST", request.url!.lastPathComponent == "state" else { return nil }
            return IncrementalReply(data: Data("{\"revision\":0}".utf8))
        }
        await assertSyncError("invalid") { _ = try await self.client.uploadIncremental(source, baseRevision: 1, pages: portable) }
    }

    func testSceneKeysAndHeadsMustMatchSource() async throws {
        let source = try package()
        var portable = try pages(source)
        let key = portable.keys.first!
        portable.removeValue(forKey: key)
        await assertSyncError("invalid") { _ = try await self.client.uploadIncremental(source, baseRevision: 0, pages: portable) }
        portable = try pages(source)
        portable[key]!.head = UUID()
        await assertSyncError("invalid") { _ = try await self.client.uploadIncremental(source, baseRevision: 0, pages: portable) }
        XCTAssertEqual(fixture.requestCount, 0)
    }

    func testCASDigestPreventsDoubleDecodingGzipObject() throws {
        let payload = Data("Opaque CAS object with its own gzip representation".utf8)
        let object = try SyncGzip.encode(payload, limit: 1024)
        let digest = IncrementalFixture.hash(object)
        XCTAssertTrue(object.starts(with: [0x1f, 0x8b]))
        XCTAssertNotEqual(digest, IncrementalFixture.hash(payload))

        // URLSession removed the transport gzip layer but retained its header.
        XCTAssertEqual(try SyncGzip.responseBody(object, encoding: "gzip", expectedDigest: digest, limit: 1024), object)
        // When transport gzip is still present, remove exactly that outer layer.
        let transport = try SyncGzip.encode(object, limit: 1024)
        XCTAssertEqual(try SyncGzip.responseBody(transport, encoding: "gzip", expectedDigest: digest, limit: 1024), object)
        XCTAssertEqual(try SyncGzip.responseBody(object, encoding: nil, expectedDigest: digest, limit: 1024), object)

        let wrongDigest = IncrementalFixture.hash(Data("another object".utf8))
        for body in [object, transport] {
            XCTAssertThrowsError(try SyncGzip.responseBody(body, encoding: "gzip", expectedDigest: wrongDigest, limit: 1024)) { error in
                guard case SyncError.invalidPackage = error else { return XCTFail("Wrong error: \(error)") }
            }
        }
        // Digest matching must not bypass the byte limit, and fallback inflation
        // must not allow a tiny wire body to expand past that same limit.
        XCTAssertThrowsError(try SyncGzip.responseBody(object, encoding: "gzip", expectedDigest: digest, limit: object.count - 1)) { error in
            guard case SyncError.tooLarge = error else { return XCTFail("Wrong error: \(error)") }
        }
        let oversized = Data(repeating: 42, count: 4096)
        let compressed = try SyncGzip.encode(oversized, limit: 1024)
        XCTAssertThrowsError(try SyncGzip.responseBody(compressed, encoding: "gzip",
            expectedDigest: IncrementalFixture.hash(oversized), limit: 1024)) { error in
            guard case SyncError.tooLarge = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    func testGzipTruncationChecksumTrailingDataAndDecodedLimit() async throws {
        let data = Data(repeating: 42, count: 4096)
        let compressed = try SyncGzip.encode(data, limit: 8192)
        XCTAssertEqual(try SyncGzip.decode(compressed, limit: data.count), data)
        XCTAssertThrowsError(try SyncGzip.decode(Data(compressed.dropLast()), limit: 8192))
        var corrupt = compressed
        corrupt[corrupt.count - 8] ^= 1
        XCTAssertThrowsError(try SyncGzip.decode(corrupt, limit: 8192))
        XCTAssertThrowsError(try SyncGzip.decode(compressed + Data([0]), limit: 8192))
        XCTAssertThrowsError(try SyncGzip.decode(compressed, limit: 4095))
        XCTAssertThrowsError(try SyncGzip.encode(data, limit: 1))
        let state = try SyncGzip.encode(Data("{\"revision\":0,\"manifest\":null}".utf8), limit: 1024)
        fixture.intercept = { _, _ in IncrementalReply(headers: ["Content-Encoding": "gzip"], data: Data(state.dropLast())) }
        do {
            _ = try await client.fetchIncremental(local: SyncPackage(notebooks: [], blobs: [:]))
            XCTFail("Accepted truncated gzip response")
        } catch {}
    }

    func testResponseEncodingAndAdvertisedSizeAreBounded() async throws {
        fixture.intercept = { _, _ in IncrementalReply(headers: ["Content-Encoding": "br"], data: Data()) }
        let empty = SyncPackage(notebooks: [], blobs: [:])
        await assertSyncError("invalid") { _ = try await self.client.fetchIncremental(local: empty) }
        fixture.intercept = { _, _ in IncrementalReply(headers: ["Content-Length": "1000000000"], data: Data()) }
        await assertSyncError("large") { _ = try await self.client.fetchIncremental(local: empty) }
        let oversized = try SyncGzip.encode(Data(repeating: 32, count: 4 * 1024 * 1024 + 1), limit: 1024 * 1024)
        fixture.intercept = { _, _ in IncrementalReply(headers: ["Content-Encoding": "gzip"], data: oversized) }
        await assertSyncError("large") { _ = try await self.client.fetchIncremental(local: empty) }
    }
    func testDocumentOnlyRoutePublishesOneUUIDAndReturnsFreshUnchangedReceipt() async throws {
        var source = try package()
        source.notebooks.append(Notebook(name: "Other offline document"))
        let id = source.notebooks[0].id
        let doc = try source.document(id)
        let syncID = UUID(), wireDigest = String(repeating: "c", count: 64)
        var docPosts = 0
        fixture.intercept = { request, data in
            let path = request.url!.path
            guard path.contains("/documents/") || path.contains("/sync-receipts/") else { return nil }
            if request.httpMethod == "GET" && path.contains("/documents/") {
                return IncrementalReply(data: try JSONSerialization.data(withJSONObject: ["revision": 5,
                    "manifest": IncrementalFixture.sourceManifest(doc), "documentDigest": wireDigest,
                    "lastSyncedAt": "2026-10-09T10:00:00Z"]))
            }
            if request.httpMethod == "POST" {
                docPosts += 1
                XCTAssertEqual(path, "/draw-sync/v2/documents/\(id.uuidString)/state")
                let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                XCTAssertEqual(payload["baseDocumentDigest"] as? String, wireDigest)
                XCTAssertEqual(payload["syncID"] as? String, syncID.uuidString)
                let books = (payload["manifest"] as! [String: Any])["notebooks"] as! [[String: Any]]
                XCTAssertEqual(books.count, 1)
                XCTAssertEqual(books[0]["id"] as? String, id.uuidString)
            }
            return IncrementalReply(data: try JSONSerialization.data(withJSONObject: ["revision": 5,
                "documentDigest": wireDigest, "lastSyncedAt": "2026-10-09T11:00:00Z", "syncID": syncID.uuidString]))
        }
        for bytes in doc.blobs.values { fixture.objects[IncrementalFixture.hash(bytes)] = bytes }
        let remote = try await client.fetchDocument(id, local: doc)
        XCTAssertEqual(remote.documentDigest, wireDigest)
        let baseline = DocumentSyncBaseline(serverDigest: wireDigest, localDigest: try doc.digest(), revision: 5,
                                            lastSyncedAt: "2026-10-09T10:00:00Z")
        XCTAssertEqual(try SyncDecision.document(local: doc, remote: remote, baseline: baseline), .unchanged)
        let receipt = try await client.uploadDocument(doc, documentID: id, syncID: syncID,
            baseDocumentDigest: wireDigest, pages: doc.portablePages())
        XCTAssertEqual(receipt.revision, 5)
        XCTAssertEqual(receipt.lastSyncedAt, "2026-10-09T11:00:00Z")
        let recovered = try await client.fetchSyncReceipt(syncID)
        XCTAssertEqual(recovered, receipt)
        XCTAssertEqual(docPosts, 1)
        XCTAssertEqual(source.notebooks[1].name, "Other offline document")
        XCTAssertTrue(fixture.commits.isEmpty, "No global commit in document-only Sync")
    }

    func testFlatFormatThreeDocumentReadsUseCanonicalNativeBaselinesAndOpaqueWireAuthority() async throws {
        let folder = Folder(name: "Flat")
        var flat = try package()
        flat.folders = [folder]; flat.notebooks[0].folderID = folder.id
        var ai = flat
        let (frame, asset, bytes) = try AICapture.invisibleStroke()
        let object = AIObject(id: UUID(), revision: 1, kind: "text", source: "Answer", frame: frame,
            style: AIStyle(), asset: asset, provenance: AIProvenance(requestID: UUID(),
                contextSHA256: String(repeating: "a", count: 64), rendererSignature: "draw-ai-render-v1"))
        ai.format = 2; ai.assets = [asset.sha256: bytes]
        ai.notebooks[0].pages[0].nodes[0].objects = [object]
        var emptyAssets = flat; emptyAssets.assets = [:]
        let id = flat.notebooks[0].id, wire = String(repeating: "c", count: 64)
        for original in [flat, emptyAssets, ai] {
            var source = original; source.format = 3
            let canonical = try source.document(id)
            XCTAssertEqual(canonical.format, original.format)
            try publish(source)
            for data in (source.assets ?? [:]).values { fixture.objects[IncrementalFixture.hash(data)] = data }
            fixture.intercept = { request, _ in
                guard request.url!.path == "/draw-sync/v2/documents/\(id.uuidString)/state" else { return nil }
                return IncrementalReply(data: try JSONSerialization.data(withJSONObject: ["revision": 5,
                    "manifest": IncrementalFixture.sourceManifest(source), "documentDigest": wire,
                    "lastSyncedAt": "2026-10-09T10:00:00Z"]))
            }
            let whole = try await client.fetchIncremental(local: original)
            XCTAssertEqual(try whole.package?.encoded(), try source.encoded(), "Whole-library legacy proof stays exact")
            let remote = try await client.fetchDocument(id, local: original)
            let confirmed = try XCTUnwrap(remote.package)
            XCTAssertEqual(try confirmed.encoded(), try canonical.encoded())
            XCTAssertEqual(remote.documentDigest, wire, "Native projection must not rewrite opaque wire authority")
            XCTAssertEqual(try SyncDecision.document(local: canonical, remote: remote, baseline: nil), .unchanged)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = Store(directory: root)
            try store.importPackage(confirmed)
            let reexported = try store.exportCurrentPackage(book: id)
            let baseline = DocumentSyncBaseline(serverDigest: wire, localDigest: try confirmed.digest(), revision: 5,
                lastSyncedAt: "2026-10-09T10:00:00Z")
            XCTAssertEqual(try reexported.digest(), baseline.localDigest)
            XCTAssertEqual(try SyncDecision.document(local: reexported, remote: remote, baseline: baseline), .unchanged)
            var localEdit = reexported; localEdit.notebooks[0].name = "Unsynced local edit"
            XCTAssertEqual(try SyncDecision.document(local: localEdit, remote: remote, baseline: baseline), .upload)
            XCTAssertThrowsError(try SyncDecision.document(local: localEdit, remote: remote, baseline: nil))
            var remoteEdit = remote
            remoteEdit.package!.notebooks[0].name = "New remote edit"
            remoteEdit.documentDigest = String(repeating: "d", count: 64); remoteEdit.revision = 6
            XCTAssertEqual(try SyncDecision.document(local: reexported, remote: remoteEdit, baseline: baseline), .download)
            XCTAssertThrowsError(try SyncDecision.document(local: localEdit, remote: remoteEdit, baseline: baseline))
        }
    }

    func testHomeReconcilesPerDocumentAndPreservesRemoteOnlyDocsAndEmptyFolders() throws {
        var old = try package()
        let b = Notebook(name: "Second"), folder = Folder(name: "Empty")
        old.notebooks.append(b); old.folders = [folder]
        var local = old, remote = old
        local.notebooks[0].name = "Local new ink metadata"
        remote.notebooks[1].name = "Remote newer second document"
        let remoteOnly = Notebook(name: "Server only")
        remote.notebooks.append(remoteOnly)
        var journal = SyncJournal()
        journal.folders = old.folders
        for book in old.notebooks {
            let digest = try old.document(book.id).digest()
            journal.documents[book.id.uuidString] = DocumentSyncBaseline(serverDigest: String(repeating: "a", count: 64),
                localDigest: digest, revision: 4, lastSyncedAt: "2026-10-09T10:00:00Z")
            journal.remoteLocalDigests[book.id.uuidString] = digest
        }
        let merged = try journal.reconcile(local: local, remote: SyncState(revision: 9, package: remote))
        XCTAssertEqual(merged.notebooks.first { $0.id == old.notebooks[0].id }?.name, local.notebooks[0].name)
        XCTAssertEqual(merged.notebooks.first { $0.id == b.id }?.name, remote.notebooks[1].name)
        XCTAssertEqual(merged.notebooks.last?.id, remoteOnly.id)
        XCTAssertEqual(merged.folders?.map(\.id), [folder.id])
        var conflicting = local
        conflicting.notebooks[1].name = "Also edited offline"
        XCTAssertThrowsError(try journal.reconcile(local: conflicting, remote: SyncState(revision: 9, package: remote)))
    }

    func testPartialSyncCannotBlessStaleUnrelatedDocumentsAndLegacyProofSurvivesMigration() throws {
        var old = try package()
        old.notebooks.append(Notebook(name: "Second"))
        var migrated = old
        migrated.notebooks[0].name = "Migrated source representation"
        var journal = SyncJournal()
        journal.legacy = SyncBaseline(revision: 4, digest: try old.digest())
        let pre = try Dictionary(uniqueKeysWithValues: old.notebooks.map { ($0.id.uuidString, try old.document($0.id).digest()) })
        try journal.establishLegacy(local: migrated, remote: SyncState(revision: 4, package: old), preMigration: pre)
        let merged = try journal.reconcile(local: migrated, remote: SyncState(revision: 4, package: old))
        XCTAssertEqual(try merged.digest(), try migrated.digest())
        let b = old.notebooks[1].id
        var newer = old; newer.notebooks[1].name = "Server changed while this device was offline"
        // A document-only success invalidates whole-library authority. It must
        // not initialize unrelated B from its now-stale local copy.
        var partial = SyncJournal()
        partial.legacy = journal.legacy
        partial.legacyInvalidated = true
        try partial.establishLegacy(local: old, remote: SyncState(revision: 8, package: newer), preMigration: pre)
        XCTAssertNil(partial.documents[b.uuidString])
        XCTAssertThrowsError(try partial.reconcile(local: old, remote: SyncState(revision: 8, package: newer)))
        var unproven = SyncJournal()
        unproven.legacy = SyncBaseline(revision: 4, digest: String(repeating: "f", count: 64))
        try unproven.establishLegacy(local: old, remote: SyncState(revision: 8, package: newer))
        XCTAssertTrue(unproven.documents.isEmpty)
        XCTAssertThrowsError(try unproven.reconcile(local: old, remote: SyncState(revision: 8, package: newer)))
    }

    func testDivergentFolderEditsConflictRatherThanDeletingUnrelatedEmptyFolder() throws {
        var source = try package()
        let folder = Folder(name: "Original")
        source.folders = [folder]
        var local = source, remote = source
        local.folders![0].name = "Local rename"
        remote.folders![0].name = "Remote rename"
        var journal = SyncJournal(); journal.folders = source.folders
        XCTAssertThrowsError(try journal.reconcile(local: local, remote: SyncState(revision: 8, package: remote)))
    }

    func testReceiptSupersessionUsesRevisionDigestAndParsedFreshness() throws {
        let id = UUID(), wire = String(repeating: "b", count: 64)
        var journal = SyncJournal()
        journal.documents[id.uuidString] = DocumentSyncBaseline(serverDigest: wire, localDigest: "source-B", revision: 5,
            lastSyncedAt: "2026-10-10T10:00:00.100Z")
        func receipt(_ revision: Int, _ digest: String = String(repeating: "b", count: 64), _ time: String = "2026-10-10T10:00:00Z") -> DocumentSyncReceipt {
            DocumentSyncReceipt(revision: revision, documentDigest: digest, lastSyncedAt: time, syncID: UUID())
        }
        XCTAssertTrue(try journal.receiptIsSuperseded(receipt(4), document: id, localDigest: "source-B"))
        XCTAssertTrue(try journal.receiptIsSuperseded(receipt(5, String(repeating: "a", count: 64)), document: id, localDigest: "source-B"))
        XCTAssertTrue(try journal.receiptIsSuperseded(receipt(5), document: id, localDigest: "source-A"))
        // UTC strings with/without fractional seconds do not sort chronologically.
        XCTAssertTrue(try journal.receiptIsSuperseded(receipt(5), document: id, localDigest: "source-B"))
        XCTAssertFalse(try journal.receiptIsSuperseded(receipt(5, wire, "2026-10-10T10:00:00.200Z"), document: id, localDigest: "source-B"))
        journal.documents[id.uuidString]?.lastSyncedAt = "invalid"
        XCTAssertThrowsError(try journal.receiptIsSuperseded(receipt(5), document: id, localDigest: "source-B"))
    }

    func testFormatTwoManifestAssetsAreSHAReferencesAndReusedExactly() async throws {
        var source = try package()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: AICapture.rendererFormat()).image { context in
            context.cgContext.setStrokeColor(UIColor.black.cgColor)
            context.cgContext.strokeEllipse(in: CGRect(x: 1, y: 1, width: 18, height: 18))
        }
        // The approved-object contract requires 8-bit sRGB RGBA, not UIKit's
        // device-dependent automatic extended-range PNG representation.
        let bytes = try AICapture.png(image)
        let sha = IncrementalFixture.hash(bytes)
        let object = AIObject(id: UUID(), revision: 1, kind: "circle", source: "{}",
            frame: AIFrame(x: 100, y: 100, width: 20, height: 20), style: AIStyle(),
            asset: AIAsset(sha256: sha, pixelWidth: 40, pixelHeight: 40),
            provenance: AIProvenance(requestID: UUID(), contextSHA256: String(repeating: "a", count: 64), rendererSignature: "draw-ai-render-v1"))
        source.format = 2; source.assets = [sha: bytes]
        source.notebooks[0].pages[0].nodes[0].objects = [object]
        try source.validate()
        let revision = try await client.uploadIncremental(source, baseRevision: 0, pages: source.portablePages())
        XCTAssertEqual(fixture.manifest?["assets"] as? [String: String], [sha: sha])
        let uploads = fixture.objectUploads
        _ = try await client.uploadIncremental(source, baseRevision: revision, pages: source.portablePages())
        XCTAssertEqual(fixture.objectUploads, uploads)
        let reused = try await client.fetchIncremental(local: source)
        XCTAssertEqual(try reused.package?.encoded(), try source.encoded())
        XCTAssertEqual(fixture.objectDownloads, 0)
        var invalid = source; invalid.assets = nil
        XCTAssertThrowsError(try invalid.validate())
        invalid = source; invalid.format = 1
        XCTAssertThrowsError(try invalid.validate())
        let parent = Folder(name: "Semester")
        let child = Folder(name: "Math", parentID: parent.id)
        source.folders = [parent, child]
        source.notebooks[0].folderID = child.id
        source.format = 3
        try source.validate()
        let nestedRevision = try await client.uploadIncremental(source, baseRevision: revision, pages: source.portablePages())
        XCTAssertEqual(fixture.manifest?["format"] as? Int, 3)
        XCTAssertEqual(fixture.manifest?["assets"] as? [String: String], [sha: sha])
        XCTAssertEqual(fixture.objectUploads, uploads, "Changing folder metadata must reuse native, asset and scene bytes")
        let nested = try await client.fetchIncremental(local: source)
        XCTAssertEqual(nested.revision, nestedRevision)
        XCTAssertEqual(try nested.package?.encoded(), try source.encoded())
        XCTAssertEqual(fixture.objectDownloads, 0)
        invalid = source; invalid.assets = nil
        XCTAssertThrowsError(try invalid.validate())
    }

    func testPartialFolderConfirmationPreservesUnrelatedAnchorsAndUnknownAuthority() throws {
        let unrelated = Folder(name: "Unrelated baseline")
        let confirmed = Folder(name: "Confirmed F")
        let localOnly = Folder(name: "Unsynced empty G")
        let book = Notebook(name: "Target", folderID: confirmed.id)
        let source = SyncPackage(notebooks: [book], blobs: [:], folders: [confirmed, localOnly])
        var journal = SyncJournal(); journal.folders = [unrelated]
        journal.confirmTargetFolder(in: source)
        XCTAssertEqual(journal.folders?.map(\.id), [unrelated.id, confirmed.id])
        XCTAssertEqual(journal.folders?.first?.name, unrelated.name)
        XCTAssertFalse(journal.folders?.contains(where: { $0.id == localOnly.id }) ?? true)
        var unknown = SyncJournal()
        unknown.confirmTargetFolder(in: source)
        XCTAssertNil(unknown.folders, "A document confirmation cannot prove the global folder inventory")
    }

}
