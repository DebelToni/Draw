import XCTest
@testable import Draw

private final class SyncStub: URLProtocol {
    static var status = 200
    static var body = Data("{\"revision\":0,\"package\":null}".utf8)
    static var offline = false
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        if Self.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SyncNetworkTests: XCTestCase {
    private func client() -> SyncClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncStub.self]
        SyncStub.status = 200
        SyncStub.offline = false
        SyncStub.body = Data("{\"revision\":0,\"package\":null}".utf8)
        return SyncClient(token: "test-token", session: URLSession(configuration: config))
    }

    func testFetchAuthenticates() async throws {
        let client = client()
        let state = try await client.fetch()
        XCTAssertEqual(state.revision, 0)
        XCTAssertNil(state.package)
        XCTAssertEqual(SyncStub.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func testHTTPFailuresAreNotSuccess() async {
        let client = client()
        for code in [401, 409, 413, 503] {
            SyncStub.status = code
            do { _ = try await client.fetch(); XCTFail("Accepted HTTP \(code)") }
            catch { XCTAssertTrue(error is SyncError) }
        }
    }

    func testOfflineFailsWithoutWaitingForConnectivity() async {
        let client = client()
        SyncStub.offline = true
        do { _ = try await client.fetch(); XCTFail("Offline reported success") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    func testUploadReadsCommitReceipt() async throws {
        let client = client()
        SyncStub.body = Data("{\"revision\":7}".utf8)
        let revision = try await client.upload(SyncPackage(notebooks: [], blobs: [:]), baseRevision: 6)
        XCTAssertEqual(revision, 7)
        XCTAssertEqual(SyncStub.lastRequest?.httpMethod, "POST")
    }

    func testLiveDGXTLSAndAuthenticationReadOnly() async throws {
        let token = Bundle.main.object(forInfoDictionaryKey: "DrawSyncToken") as? String ?? ""
        guard !token.isEmpty else { throw XCTSkip("Private sync credential not configured") }
        // The shipping client reads v2 metadata, not the legacy full-history body.
        var request = URLRequest(url: URL(string: "https://draw.example.invalid/draw-sync/v2/state")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertLessThan(data.count, 4 * 1024 * 1024)
        struct Manifest: Decodable {
            var format: Int
            var notebooks: [Notebook]
            var blobs: [String: String]
        }
        struct State: Decodable { var revision: Int; var manifest: Manifest? }
        let state = try JSONDecoder().decode(State.self, from: data)
        XCTAssertGreaterThanOrEqual(state.revision, 0)
        if let manifest = state.manifest {
            XCTAssertTrue((1...3).contains(manifest.format))
            XCTAssertEqual(manifest.blobs.count, manifest.notebooks.reduce(0) { total, book in
                total + (book.pages + book.deleted).reduce(0) { $0 + $1.nodes.count }
            })
            XCTAssertTrue(manifest.blobs.values.allSatisfy { $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil })
        } else { XCTAssertEqual(state.revision, 0) }
    }
}
