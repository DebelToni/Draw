import XCTest
import Foundation
import UIKit
import PencilKit
@testable import Draw

// Optional fixture-only bridge. Stage COPY inputs in the test runner's Documents,
// never Application Support/Draw. No HTTP, controller, Sync or Notes CAS is used.
private struct BenchmarkCaptureIdentity: Decodable {
    struct Document: Decodable { var original: UUID; var isolated: UUID }
    var documentID: Document
    var pageIDs: [String: UUID]
    var folderIDs: [String: UUID]
}

private struct BenchmarkCaptureTarget: Decodable {
    var caseID: String
    var documentID: UUID
    var focusPageID: UUID
    var identityMapping: BenchmarkCaptureIdentity
}

private struct BenchmarkCaptureFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

@MainActor
final class AIBenchmarkCaptureTests: XCTestCase {
    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func inventory(_ root: URL) throws -> [String: String] {
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              let entries = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else {
            throw BenchmarkCaptureFailure("Unsafe benchmark input directory")
        }
        var result: [String: String] = [:]
        for case let file as URL in entries {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw BenchmarkCaptureFailure("Benchmark input must not contain symbolic links")
            }
            if values.isRegularFile == true {
                result[String(file.path.dropFirst(root.path.count + 1))] = AIHash.digest(try Data(contentsOf: file))
            }
        }
        return result
    }

    private func target(_ input: URL) throws -> BenchmarkCaptureTarget {
        let file = input.appendingPathComponent("targets.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("No DrawBenchmarkInput/targets.json staged")
        }
        // Preflight symlinks before even reading the target.
        _ = try inventory(input)
        let bytes = try Data(contentsOf: file)
        if bytes.isEmpty { throw XCTSkip("Benchmark targets file is empty") }
        guard bytes.count <= SyncObjects.metadataLimit else { throw SyncError.tooLarge }
        let targets = try JSONDecoder().decode([BenchmarkCaptureTarget].self, from: bytes)
        if targets.isEmpty { throw XCTSkip("No benchmark target staged") }
        guard targets.count == 1, let target = targets.first,
              target.caseID.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$", options: .regularExpression) != nil else {
            throw BenchmarkCaptureFailure("Expected one safe benchmark case ID")
        }
        return target
    }

    private func validateCopy(_ store: Store, target: BenchmarkCaptureTarget) throws {
        if let error = store.loadError { throw error }
        let book = try XCTUnwrap(store.notebooks.first)
        let mapping = target.identityMapping
        let originalPages = try mapping.pageIDs.keys.map { try XCTUnwrap(UUID(uuidString: $0)) }
        let originalFolders = try mapping.folderIDs.keys.map { try XCTUnwrap(UUID(uuidString: $0)) }
        let originals = Set([mapping.documentID.original] + originalPages + originalFolders)
        let isolated = [book.id] + Array(mapping.pageIDs.values) + Array(mapping.folderIDs.values)
        guard store.notebooks.count == 1, book.id == target.documentID,
              mapping.documentID.isolated == book.id,
              Set(isolated).count == isolated.count, Set(isolated).isDisjoint(with: originals),
              book.name.hasPrefix("Test "), store.folders.allSatisfy({ $0.name.hasPrefix("Test ") }),
              Set(mapping.pageIDs.values) == Set((book.pages + book.deleted).map(\.id)),
              Set(mapping.folderIDs.values) == Set(store.folders.map(\.id)),
              book.pages.contains(where: { $0.id == target.focusPageID }) else {
            throw BenchmarkCaptureFailure("Benchmark identity isolation or focus validation failed")
        }
        for page in book.pages + book.deleted {
            guard page.nodes.count == (page.head == nil ? 0 : 1),
                  page.preferredRoot == nil || page.preferredRoot == page.head,
                  page.nodes.allSatisfy({ $0.id == page.head && $0.parent == nil &&
                      $0.children.isEmpty && $0.preferredChild == nil }) else {
                throw BenchmarkCaptureFailure("Benchmark copy must retain current heads only")
            }
        }
        let ancestors = try Folder.ancestorClosure(of: book.folderID, in: store.folders)
        guard Set(ancestors.map(\.id)) == Set(store.folders.map(\.id)) else {
            throw BenchmarkCaptureFailure("Benchmark copy contains unrelated folders")
        }
    }

    func testExportStagedBenchmarkNativeCapture() async throws {
        let input = documents.appendingPathComponent("DrawBenchmarkInput", isDirectory: true)
        let target = try self.target(input)
        let inputBefore = try inventory(input)
        let baseline = UserDefaults.standard.data(forKey: "syncBaseline")
        let journal = UserDefaults.standard.data(forKey: "syncJournalV2")
        defer {
            XCTAssertEqual(try? inventory(input), inputBefore, "Staged source was modified")
            XCTAssertEqual(UserDefaults.standard.data(forKey: "syncBaseline"), baseline)
            XCTAssertEqual(UserDefaults.standard.data(forKey: "syncJournalV2"), journal)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DrawBenchmark-" + UUID().uuidString)
        try FileManager.default.copyItem(at: input, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(directory: root, migrateLegacyHistory: false)
        try validateCopy(store, target: target)
        // Exact isolated current package supplies every native archive and object.
        // Do not migrate/recolor, import through Sync, or use procedural scenes.
        let source = try store.exportCurrentPackage(book: target.documentID)
        let before = try source.encoded()
        let copyBefore = try inventory(root)
        let size = source.notebooks.first?.orientation == "landscape"
            ? CGSize(width: 1361, height: 1024) : CGSize(width: 1024, height: 1361)
        let captured = try await store.capturedAIContextAsync(book: target.documentID,
            focusPage: target.focusPageID, pageSize: size, source: source)
        XCTAssertEqual(try store.exportCurrentPackage(book: target.documentID).encoded(), before)
        XCTAssertEqual(try inventory(root), copyBefore, "Native capture modified its isolated source")
        XCTAssertEqual(captured.context.documentID, target.documentID)
        XCTAssertEqual(captured.context.focusPageID, target.focusPageID)
        let book = try XCTUnwrap(source.notebooks.first)
        XCTAssertEqual(captured.context.pages.map(\.pageID), book.pages.map(\.id))
        for page in captured.context.pages {
            let native = try XCTUnwrap(book.pages.first { $0.id == page.pageID })
            XCTAssertEqual(page.head, native.head)
            XCTAssertEqual(page.background, native.background)
            XCTAssertEqual(try AIHash.encoded(page.objects), try AIHash.encoded(native.nodes.first?.objects ?? []))
            let drawing = try store.drawing(book: book.id, page: native)
            XCTAssertEqual(page.strokeTargets.count, drawing.strokes.count)
            for sha in [page.paperSHA256, page.inkSHA256, page.compositeSHA256] {
                try AIAssets.validate(data: XCTUnwrap(captured.assets[sha]), asset: AIAsset(sha256: sha,
                    pixelWidth: Int(page.width * 2), pixelHeight: Int(page.height * 2)))
            }
            let portable = try JSONDecoder().decode(PortablePage.self, from: XCTUnwrap(captured.assets[page.portableSHA256]))
            XCTAssertEqual(portable.head, page.head)
            XCTAssertEqual(portable.strokes.count, drawing.strokes.count)
            XCTAssertEqual(try AIHash.encoded(portable.objects ?? []), try AIHash.encoded(page.objects))
        }
        let contextBytes = try captured.context.encoded()
        guard contextBytes.count <= SyncObjects.metadataLimit,
              captured.assets.values.reduce(0, { $0 + $1.count }) <= SyncObjects.objectLimit else {
            throw SyncError.tooLarge
        }
        let exports = documents.appendingPathComponent("DrawBenchmarkExports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        guard try exports.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw BenchmarkCaptureFailure("Benchmark exports directory must not be a symbolic link")
        }
        let destination = exports.appendingPathComponent(target.caseID, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BenchmarkCaptureFailure("Benchmark export already exists; refusing replacement")
        }
        let temporary = exports.appendingPathComponent(".capture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("assets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try contextBytes.write(to: temporary.appendingPathComponent("context.json"), options: .atomic)
        for (sha, bytes) in captured.assets {
            guard AIHash.digest(bytes) == sha else { throw AIError.invalidAsset }
            // Exact raw PNG/JSON bytes, extensionless SHA filenames for import_case.
            try bytes.write(to: temporary.appendingPathComponent("assets/" + sha), options: .atomic)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
