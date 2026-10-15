import XCTest
import PencilKit
import UIKit
@testable import Draw

final class NestedFolderTests: XCTestCase {
    private var root: URL!
    private var store: Store!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = Store(directory: root)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func drawing(_ x: CGFloat) -> PKDrawing {
        let point = PKStrokePoint(location: CGPoint(x: x, y: 40), timeOffset: 0,
            size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.monoline, color: .black),
            path: PKStrokePath(controlPoints: [point], creationDate: Date(timeIntervalSince1970: 100)))])
    }

    func testDeletingNestedFolderPromotesOnlyDirectContentsAndKeepsInkHistoryAndIDs() throws {
        let semester = try store.addFolder("Semester")
        let math = try store.addFolder("Math", in: semester)
        let exercises = try store.addFolder("Exercises", in: math)
        let week = try store.addFolder("Week", in: exercises)
        let direct = try store.addNotebook("Direct", in: math)
        let deep = try store.addNotebook("Deep", in: week)
        let page = store.notebook(direct)!.pages[0].id
        let firstDrawing = drawing(40)
        try store.commit(book: direct, page: page, drawing: firstDrawing)
        try store.commit(book: direct, page: page, drawing: drawing(80))
        let before = try store.exportPackage()
        let books = store.notebooks
        try store.deleteFolder(math)
        XCTAssertEqual(store.notebook(direct)?.folderID, semester)
        XCTAssertEqual(store.notebook(deep)?.folderID, week)
        XCTAssertEqual(store.folders.first { $0.id == exercises }?.parentID, semester)
        XCTAssertEqual(store.folders.first { $0.id == week }?.parentID, exercises)
        XCTAssertEqual(try store.exportPackage().blobs, before.blobs)
        XCTAssertEqual(store.notebook(direct)?.modified, books[0].modified)
        XCTAssertEqual(store.notebook(direct)?.pages[0].nodes.map(\.id), books[0].pages[0].nodes.map(\.id))
        store = Store(directory: root, migrateLegacyHistory: true)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.notebook(direct)?.pages[0].nodes.count, 2, "Folder metadata must not reset undo")
        XCTAssertEqual(Folder.path(of: week, in: store.folders), "Semester / Exercises / Week")
        try store.deleteFolder(semester)
        XCTAssertNil(store.notebook(direct)?.folderID)
        XCTAssertNil(store.folders.first { $0.id == exercises }?.parentID)
        XCTAssertEqual(store.folders.first { $0.id == week }?.parentID, exercises)
        XCTAssertEqual(store.notebook(deep)?.folderID, week)
        XCTAssertEqual(try store.exportPackage().blobs, before.blobs)
        XCTAssertEqual(try store.undo(book: direct, page: page), firstDrawing)
    }

    func testMovingFolderCarriesSubtreeAndPickerExcludesSelfAndDescendants() throws {
        let a = try store.addFolder("A"), b = try store.addFolder("B")
        let child = try store.addFolder("Child", in: a)
        let leaf = try store.addFolder("Leaf", in: child)
        let book = try store.addNotebook("Note", in: leaf)
        let before = try store.exportPackage()
        XCTAssertEqual(store.folderDestinations(excluding: a).map(\.id), [b])
        XCTAssertEqual(Set(store.folderDestinations(excluding: child).map(\.id)), Set([a, b]))
        XCTAssertEqual(Set(store.folderDestinations().map(\.id)), Set([a, b, child, leaf]))
        try store.moveFolder(a, into: b)
        try store.renameFolder(b, to: "Semester")
        XCTAssertEqual(Folder.path(of: leaf, in: store.folders), "Semester / A / Child / Leaf")
        XCTAssertEqual(store.notebook(book)?.folderID, leaf)
        XCTAssertEqual(store.notebook(book)?.modified, before.notebooks[0].modified)
        XCTAssertEqual(try store.exportPackage().blobs, before.blobs)
        store = Store(directory: root)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.folders.first { $0.id == a }?.parentID, b)
        try store.moveFolder(a, into: nil)
        XCTAssertEqual(Folder.path(of: leaf, in: store.folders), "A / Child / Leaf")
    }

    func testInvalidCandidateGraphsNeverChangeMemoryOrIndex() throws {
        let a = try store.addFolder("A"), child = try store.addFolder("Child", in: a)
        let book = try store.addNotebook("Note", in: child)
        let before = try store.exportPackage().encoded()
        let index = root.appendingPathComponent("notebooks.json")
        let disk = try Data(contentsOf: index)
        XCTAssertThrowsError(try store.moveFolder(a, into: child))
        XCTAssertThrowsError(try store.moveFolder(child, into: child))
        XCTAssertThrowsError(try store.moveFolder(child, into: UUID()))
        XCTAssertThrowsError(try store.addFolder("Missing parent", in: UUID()))
        XCTAssertThrowsError(try store.renameFolder(a, to: " "))
        XCTAssertThrowsError(try store.update(book) { $0.folderID = UUID() })
        XCTAssertEqual(try store.exportPackage().encoded(), before)
        XCTAssertEqual(try Data(contentsOf: index), disk)
        var bad = try store.exportPackage()
        bad.folders![0].parentID = child
        XCTAssertThrowsError(try store.importPackage(bad))
        bad.folders![0].parentID = UUID()
        XCTAssertThrowsError(try store.importPackage(bad))
        bad = try store.exportPackage()
        bad.folders!.append(bad.folders![0])
        XCTAssertThrowsError(try store.importPackage(bad))
        XCTAssertEqual(try Data(contentsOf: index), disk)
    }

    func testNestedOrganizationWriteFailureRollsBackWholeCandidate() throws {
        let a = try store.addFolder("A"), b = try store.addFolder("B")
        let child = try store.addFolder("Child", in: a)
        let leaf = try store.addFolder("Leaf", in: child)
        _ = try store.addNotebook("Direct", in: child)
        let before = try store.exportPackage().encoded()
        let index = root.appendingPathComponent("notebooks.json")
        let saved = root.appendingPathComponent("saved-index.json")
        try FileManager.default.moveItem(at: index, to: saved)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.moveFolder(child, into: b))
        XCTAssertThrowsError(try store.deleteFolder(child))
        XCTAssertThrowsError(try store.addFolder("New", in: leaf))
        XCTAssertEqual(try store.exportPackage().encoded(), before)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.moveItem(at: saved, to: index)
        store = Store(directory: root)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(try store.exportPackage().encoded(), before)
    }

    func testInvalidPersistedFolderGraphBlocksWritesAndHistoryMigration() throws {
        let parent = try store.addFolder("Parent")
        _ = try store.addFolder("Child", in: parent)
        _ = try store.addNotebook("Keep")
        let index = root.appendingPathComponent("notebooks.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! [String: Any]
        var groups = json["folders"] as! [[String: Any]]
        groups[0]["parentID"] = groups[1]["id"]
        json["folders"] = groups
        json.removeValue(forKey: "historySchemaVersion")
        let invalid = try JSONSerialization.data(withJSONObject: json)
        try invalid.write(to: index)
        store = Store(directory: root, migrateLegacyHistory: true)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.addFolder("Must not rewrite"))
        XCTAssertEqual(try Data(contentsOf: index), invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ai-migration-journal.json").path))
    }

    func testDocumentExportIncludesOnlyAncestorClosureAndKeepsOriginalOrdering() throws {
        let parent = Folder(name: "Semester")
        let child = Folder(name: "Math", parentID: parent.id)
        let leaf = Folder(name: "Exercises", parentID: child.id)
        let unrelated = Folder(name: "Empty")
        let book = Notebook(name: "Note", folderID: leaf.id)
        let rootBook = Notebook(name: "Root note", folderID: parent.id)
        let source = SyncPackage(format: 3, notebooks: [book, rootBook], blobs: [:], folders: [leaf, unrelated, parent, child])
        try store.importPackage(source)
        let doc = try store.exportCurrentPackage(book: book.id)
        XCTAssertEqual(doc.format, 3)
        XCTAssertNil(doc.assets)
        XCTAssertEqual(doc.folders?.map(\.id), [leaf.id, parent.id, child.id])
        XCTAssertEqual(try source.document(book.id).encoded(), try doc.encoded())
        let rootDoc = try store.exportCurrentPackage(book: rootBook.id)
        XCTAssertEqual(rootDoc.format, 1, "An unrelated nested folder cannot upgrade a root-only document")
        XCTAssertEqual(rootDoc.folders?.map(\.id), [parent.id])
        XCTAssertEqual(try source.document(rootBook.id).digest(), try rootDoc.digest())
        let receiver = Store(directory: root.appendingPathComponent("receiver"))
        try receiver.importPackage(try store.exportCurrentPackage())
        XCTAssertEqual(receiver.folders, source.folders)
        XCTAssertEqual(try receiver.exportCurrentPackage().encoded(), try source.encoded())
    }

    func testFlatLegacyFolderEncodingAndPackageDigestRemainUnchanged() throws {
        let folder = Folder(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Legacy")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let expected = Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Legacy\"}".utf8)
        XCTAssertEqual(try encoder.encode(folder), expected)
        let decoded = try JSONDecoder().decode(Folder.self, from: expected)
        XCTAssertNil(decoded.parentID)
        let source = SyncPackage(notebooks: [], blobs: [:], folders: [decoded])
        let legacy = Data(("{\"blobs\":{},\"folders\":[" + String(decoding: expected, as: UTF8.self) + "],\"format\":1,\"notebooks\":[]}").utf8)
        XCTAssertEqual(try source.encoded(), legacy)
        XCTAssertEqual(try source.digest(), SyncObjects.digest(legacy))
        try store.importPackage(source)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), legacy)
        var explicitNil = try JSONSerialization.jsonObject(with: expected) as! [String: Any]
        explicitNil["parentID"] = NSNull()
        let nilFolder = try JSONDecoder().decode(Folder.self, from: JSONSerialization.data(withJSONObject: explicitNil))
        XCTAssertEqual(try encoder.encode(nilFolder), expected)
    }

    func testNestedGraphRequiresFormatThreeAndAllowsOptionalEmptyAssets() throws {
        let a = Folder(name: "A"), child = Folder(name: "Child", parentID: a.id)
        let book = Notebook(name: "Flat subset", folderID: a.id)
        let source = SyncPackage(format: 3, notebooks: [book], blobs: [:], folders: [a, child])
        try source.validate()
        for format in [1, 2, 4] {
            var invalid = source; invalid.format = format
            XCTAssertThrowsError(try invalid.validate())
            XCTAssertThrowsError(try invalid.document(book.id), "Projection must not hide an invalid source format")
        }
        var emptyAssets = source; emptyAssets.assets = [:]
        try emptyAssets.validate() // Optional empty assets are allowed without AI in v3.
    }

    func testFlatFormatThreeWithoutAIImportsAndReexportsAsLegacyFormatOne() throws {
        let folder = Folder(name: "Flat")
        let folderVariants: [[Folder]?] = [nil, [folder]]
        let assetVariants: [[String: Data]?] = [nil, [:]]
        for folders in folderVariants {
            let book = Notebook(name: "Flat note", folderID: folders?.first?.id)
            let canonical = SyncPackage(notebooks: [book], blobs: [:], folders: folders)
            for assets in assetVariants {
                let source = SyncPackage(format: 3, notebooks: [book], blobs: [:], folders: folders, assets: assets)
                try source.validate()
                XCTAssertNotEqual(try source.digest(), try canonical.digest(), "Raw legacy proof must retain the received format")
                XCTAssertEqual(try source.document(book.id).encoded(), try canonical.encoded())
                try store.importPackage(source)
                XCTAssertEqual(try store.exportCurrentPackage().encoded(), try canonical.encoded())
                XCTAssertEqual(try store.exportCurrentPackage(book: book.id).digest(), try canonical.digest())
            }
        }
    }

    func testFlatFormatThreeWithAIImportsAndReexportsAsFormatTwo() throws {
        let folder = Folder(name: "Flat")
        let (frame, asset, bytes) = try AICapture.invisibleStroke()
        let object = AIObject(id: UUID(), revision: 1, kind: "text", source: "Answer", frame: frame,
            style: AIStyle(), asset: asset, provenance: AIProvenance(requestID: UUID(),
                contextSHA256: String(repeating: "a", count: 64), rendererSignature: "draw-ai-render-v1"))
        let node = HistoryNode(id: UUID(), parent: nil, objects: [object])
        let page = Page(nodes: [node], head: node.id, preferredRoot: node.id)
        let book = Notebook(name: "AI note", pages: [page], folderID: folder.id)
        let source = SyncPackage(format: 3, notebooks: [book], blobs: [
            SyncPackage.key(book.id, page.id, node.id): PKDrawing().dataRepresentation()
        ], folders: [folder], assets: [asset.sha256: bytes])
        try source.validate()
        var canonical = source; canonical.format = 2
        XCTAssertEqual(try source.document(book.id).encoded(), try canonical.encoded())
        try store.importPackage(source)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), try canonical.encoded())
        XCTAssertEqual(try store.exportCurrentPackage(book: book.id).digest(), try canonical.digest())
        let assetVariants: [[String: Data]?] = [nil, [:]]
        for assets in assetVariants {
            var invalid = source; invalid.assets = assets
            XCTAssertThrowsError(try invalid.validate(), "Format 3 must still require referenced assets")
        }
        var invalid = source; invalid.format = 1
        XCTAssertThrowsError(try invalid.validate())
    }

    func testFlatFormatThreeLegacyProofDoesNotBlessUnsyncedDocumentChanges() throws {
        let folder = Folder(name: "Flat")
        let book = Notebook(name: "Confirmed", folderID: folder.id)
        let source = SyncPackage(format: 3, notebooks: [book], blobs: [:], folders: [folder], assets: [:])
        try store.importPackage(source)
        let canonical = try store.exportCurrentPackage()
        try store.update(book.id) { $0.name = "Unsynced local change" }
        let local = try store.exportCurrentPackage()
        var journal = SyncJournal()
        journal.legacy = SyncBaseline(revision: 5, digest: try source.digest())
        let preMigration = [book.id.uuidString: try local.document(book.id).digest()]
        try journal.establishLegacy(local: local, remote: SyncState(revision: 5, package: source), preMigration: preMigration)
        let baseline = try XCTUnwrap(journal.documents[book.id.uuidString])
        XCTAssertEqual(baseline.localDigest, try canonical.document(book.id).digest())
        XCTAssertNotEqual(baseline.localDigest, preMigration[book.id.uuidString])
        XCTAssertEqual(try journal.reconcile(local: local, remote: SyncState(revision: 5, package: source)).encoded(), try local.encoded())
        var remote = source; remote.notebooks[0].name = "Independent remote change"
        XCTAssertThrowsError(try journal.reconcile(local: local, remote: SyncState(revision: 6, package: remote)))
        var unproven = SyncJournal()
        unproven.legacy = SyncBaseline(revision: 5, digest: try canonical.digest())
        try unproven.establishLegacy(local: local, remote: SyncState(revision: 5, package: source))
        XCTAssertTrue(unproven.documents.isEmpty, "Canonical equality cannot replace exact whole-library proof")
    }

    func testPartialConfirmationBlessesAncestorsOnlyAndJournalRemembersTree() throws {
        let old = Folder(name: "Old")
        let unrelated = Folder(name: "Unrelated")
        var confirmed = old; confirmed.name = "Semester"
        let child = Folder(name: "Math", parentID: old.id)
        let extra = Folder(name: "Unconfirmed empty", parentID: old.id)
        let book = Notebook(name: "Target", folderID: child.id)
        let source = SyncPackage(format: 3, notebooks: [book], blobs: [:], folders: [confirmed, child, extra])
        var journal = SyncJournal(); journal.folders = [old, unrelated]
        journal.confirmTargetFolder(in: source)
        XCTAssertEqual(journal.folders, [confirmed, unrelated, child])
        var unknown = SyncJournal(); unknown.confirmTargetFolder(in: source)
        XCTAssertNil(unknown.folders)
        let suite = "DrawNestedFolderTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try journal.save(in: defaults)
        XCTAssertEqual(try SyncJournal.load(in: defaults).folders, journal.folders)
    }

    func testHomeReconcileRetainsRemoteNestedEmptyFoldersAndDetectsCyclesInMerge() throws {
        let a = Folder(name: "A"), b = Folder(name: "B")
        let child = Folder(name: "Empty child", parentID: a.id)
        let local = SyncPackage(notebooks: [], blobs: [:], folders: [a, b])
        let remote = SyncPackage(format: 3, notebooks: [], blobs: [:], folders: [a, b, child])
        var journal = SyncJournal(); journal.folders = local.folders
        let merged = try journal.reconcile(local: local, remote: SyncState(revision: 1, package: remote))
        XCTAssertEqual(merged.folders, remote.folders)
        XCTAssertEqual(merged.format, 3)
        var invalid = remote; invalid.folders![0].parentID = child.id
        XCTAssertThrowsError(try journal.reconcile(local: local, remote: SyncState(revision: 2, package: invalid)))
        var moved = remote; moved.folders![2].parentID = b.id
        journal.folders = remote.folders
        let next = try journal.reconcile(local: remote, remote: SyncState(revision: 2, package: moved))
        XCTAssertEqual(Folder.path(of: child.id, in: next.folders!), "B / Empty child")
    }
}
