import XCTest
import PencilKit
import UIKit
@testable import Draw

final class StoreTests: XCTestCase {
    private var folder: URL!
    private var store: Store!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = Store(directory: folder)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func drawing(_ count: Int) -> PKDrawing {
        let ink = PKInk(.monoline, color: .black)
        let strokes = (0..<count).map { i -> PKStroke in
            let point = PKStrokePoint(location: CGPoint(x: 40 + i * 8, y: 40), timeOffset: 0,
                                      size: CGSize(width: 4, height: 4), opacity: 1, force: 1,
                                      azimuth: 0, altitude: .pi / 2)
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: [point], creationDate: Date()))
        }
        return PKDrawing(strokes: strokes)
    }

    func testLegacyNotebookOrientationRemainsNilPortraitWithoutChangingInk() throws {
        let book = try store.addNotebook("Legacy portrait")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(2))
        let current = try store.exportCurrentPackage()
        let legacy = try JSONEncoder().encode(store.notebooks)
        let records = try JSONSerialization.jsonObject(with: legacy) as! [[String: Any]]
        XCTAssertNil(records[0]["orientation"])
        let decoded = try JSONDecoder().decode([Notebook].self, from: legacy)
        XCTAssertNil(decoded[0].orientation)
        XCTAssertEqual(decoded[0].orientation ?? "portrait", "portrait")
        try legacy.write(to: folder.appendingPathComponent("notebooks.json"))
        store = Store(directory: folder)
        XCTAssertNil(store.loadError)
        XCTAssertNil(store.notebook(book)?.orientation)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), try current.encoded())
        let landscape = try store.addNotebook("New landscape", orientation: "landscape")
        store = Store(directory: folder)
        XCTAssertNil(store.notebook(book)?.orientation)
        XCTAssertEqual(store.notebook(landscape)?.orientation, "landscape")
        XCTAssertEqual(store.notebook(book)?.pages[0].head, current.notebooks[0].pages[0].head)
        for (key, bytes) in current.blobs {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(key + ".pkdraw")), bytes)
        }
    }

    func testNotebookOrientationCreationRejectsInvalidValuesWithoutWriting() throws {
        let portrait = try store.addNotebook("Explicit portrait", orientation: "portrait")
        let index = folder.appendingPathComponent("notebooks.json")
        let before = try Data(contentsOf: index)
        for invalid in ["", "Landscape", "square", " portrait ", "PORTRAIT"] {
            XCTAssertThrowsError(try store.addNotebook("Invalid", orientation: invalid)) { error in
                guard let syncError = error as? SyncError else { return XCTFail("Unexpected error: \(error)") }
                guard case .invalidPackage = syncError else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertEqual(store.notebooks.map(\.id), [portrait])
        XCTAssertEqual(try Data(contentsOf: index), before)
        store = Store(directory: folder)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.notebook(portrait)?.orientation, "portrait")
    }

    func testLandscapeOrientationSurvivesCurrentSyncFoldersDeletedPagesAndRotation() throws {
        let group = try store.addFolder("School")
        let book = try store.addNotebook("Landscape", in: group, orientation: "landscape")
        let first = store.notebook(book)!.pages[0].id
        let deleted = Page()
        try store.update(book) { $0.pages.append(deleted) }
        for n in 1...2 {
            try store.commit(book: book, page: first, drawing: drawing(n))
            try store.commit(book: book, page: deleted.id, drawing: drawing(n + 2))
        }
        try store.update(book) {
            let removed = $0.pages.removeLast()
            $0.deleted.append(removed)
        }
        try store.completeSuccessfulSync()
        try store.commit(book: book, page: first, drawing: drawing(5))
        let wire = try store.exportCurrentPackage()
        let json = try JSONSerialization.jsonObject(with: wire.encoded()) as! [String: Any]
        XCTAssertEqual((json["notebooks"] as! [[String: Any]])[0]["orientation"] as? String, "landscape")
        try store.completeSuccessfulSync()
        store = Store(directory: folder)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.notebook(book)?.orientation, "landscape")
        XCTAssertEqual(store.notebook(book)?.folderID, group)
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 2)
        XCTAssertEqual(store.notebook(book)?.deleted[0].id, deleted.id)
        XCTAssertEqual(store.notebook(book)?.deleted[0].nodes.count, 1)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), try wire.encoded())
        try store.importPackage(wire) // Same-page download keeps local retained undo.
        XCTAssertEqual(store.notebook(book)?.orientation, "landscape")
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 2)
        let receiverRoot = folder.appendingPathComponent("receiver")
        var receiver = Store(directory: receiverRoot)
        try receiver.importPackage(wire)
        try receiver.completeSuccessfulSync()
        try receiver.completeSuccessfulSync()
        receiver = Store(directory: receiverRoot)
        XCTAssertNil(receiver.loadError)
        XCTAssertEqual(receiver.notebook(book)?.orientation, "landscape")
        XCTAssertEqual(receiver.notebook(book)?.folderID, group)
        XCTAssertEqual(receiver.folders.map(\.id), [group])
        XCTAssertEqual(receiver.notebook(book)?.deleted[0].id, deleted.id)
        XCTAssertEqual(try receiver.exportCurrentPackage().encoded(), try wire.encoded())
        XCTAssertEqual(try receiver.exportPackage().blobs, wire.blobs)
        XCTAssertNil(try receiver.undo(book: book, page: first))
    }

    func testFoldersPersistSyncAndOnlyOrganizeDocuments() throws {
        let book = try store.addNotebook("Math")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(2))
        let before = try store.exportPackage()
        let modified = store.notebook(book)!.modified
        let work = try store.addFolder("Work")
        let empty = try store.addFolder("Empty")
        try store.moveNotebook(book, into: work)
        try store.renameFolder(work, to: "School")
        store = Store(directory: folder)
        XCTAssertEqual(store.folders.map(\.name), ["School", "Empty"])
        XCTAssertEqual(store.notebook(book)?.folderID, work)
        XCTAssertEqual(store.notebook(book)?.modified, modified)
        let package = try store.exportPackage()
        XCTAssertEqual(package.blobs, before.blobs)
        let otherRoot = folder.appendingPathComponent("import")
        let other = Store(directory: otherRoot)
        try other.importPackage(package)
        XCTAssertEqual(other.folders.map(\.id), [work, empty])
        XCTAssertEqual(other.notebook(book)?.folderID, work)
        let new = try other.addNotebook("New", in: work)
        XCTAssertEqual(other.notebook(new)?.folderID, work)
        try other.deleteFolder(work)
        XCTAssertNil(other.notebook(book)?.folderID)
        XCTAssertNil(other.notebook(new)?.folderID)
        XCTAssertEqual(other.folders.map(\.id), [empty])
        XCTAssertEqual(try other.drawing(book: book, page: other.notebook(book)!.pages[0]).strokes.count, 2)
        XCTAssertEqual(try other.exportPackage().blobs, before.blobs)
        XCTAssertEqual(other.notebook(book)?.pages[0].nodes.count, 1)
    }

    func testLegacyLibrariesKeepTheirDigestAndInvalidFoldersCannotImport() throws {
        let book = try store.addNotebook("Legacy")
        let original = try store.exportPackage()
        let data = try original.encoded()
        XCTAssertNil((try JSONSerialization.jsonObject(with: data) as! [String: Any])["folders"])
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("notebooks.json"))) as! [String: Any]
        XCTAssertNotNil(index["localHistory"])
        XCTAssertNotNil(index["notebooks"])
        store = Store(directory: folder)
        XCTAssertEqual(try store.exportPackage().digest(), try original.digest())
        var bad = original
        bad.notebooks[0].folderID = UUID()
        XCTAssertThrowsError(try store.importPackage(bad))
        let group = Folder(name: "Test")
        let foldersOnly = SyncPackage(notebooks: [], blobs: [:], folders: [group])
        XCTAssertThrowsError(try SyncDecision.choose(local: foldersOnly, remote: SyncState(revision: 1, package: original), baseline: nil))
        bad = original
        bad.folders = [group, group]
        XCTAssertThrowsError(try store.importPackage(bad))
        bad.folders = [Folder(name: " ")]
        XCTAssertThrowsError(try store.importPackage(bad))
        XCTAssertNil(store.notebook(book)?.folderID)
        XCTAssertEqual(try store.exportPackage().digest(), try original.digest())
    }

    func testFolderChangesRollbackWhenIndexWriteFails() throws {
        let book = try store.addNotebook("Safe")
        let group = try store.addFolder("Folder")
        try store.moveNotebook(book, into: group)
        let index = folder.appendingPathComponent("notebooks.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.deleteFolder(group))
        XCTAssertThrowsError(try store.renameFolder(group, to: "Changed"))
        XCTAssertThrowsError(try store.moveNotebook(book, into: nil))
        XCTAssertThrowsError(try store.addFolder("Other"))
        XCTAssertEqual(store.folders.map(\.name), ["Folder"])
        XCTAssertEqual(store.notebook(book)?.folderID, group)
    }

    func testBranchingHistorySurvivesReopen() throws {
        let book = try store.addNotebook("Math")
        let page = try XCTUnwrap(store.notebook(book)?.pages.first?.id)
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.commit(book: book, page: page, drawing: drawing(2))
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 1)
        try store.commit(book: book, page: page, drawing: drawing(3))
        let saved = try XCTUnwrap(store.notebook(book)?.pages.first)
        let fork = try XCTUnwrap(saved.nodes.first)
        XCTAssertEqual(fork.children.count, 2)
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 1)
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 3)
        store = Store(directory: folder)
        XCTAssertEqual(store.notebook(book)?.pages.first?.nodes.first?.children.count, 2)
        XCTAssertEqual(store.notebook(book)?.pages.first?.head, saved.head)
    }

    func testChronologicalHistoryCrossesBranchesAndStopsAtEnds() throws {
        let book = try store.addNotebook("Branches")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.commit(book: book, page: page, drawing: drawing(2))
        _ = try store.undo(book: book, page: page)
        try store.commit(book: book, page: page, drawing: drawing(3))
        XCTAssertEqual(try store.stepHistory(book: book, page: page, forward: false)?.strokes.count, 2)
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 1)
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 2)
        XCTAssertEqual(try store.stepHistory(book: book, page: page, forward: true)?.strokes.count, 3)
        XCTAssertNil(try store.stepHistory(book: book, page: page, forward: true))
        for count in [2, 1, 0] {
            XCTAssertEqual(try store.stepHistory(book: book, page: page, forward: false)?.strokes.count, count)
        }
        XCTAssertNil(try store.stepHistory(book: book, page: page, forward: false))
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 3)
    }

    func testRedoRemembersSelectedRootBranchAfterReopen() throws {
        let book = try store.addNotebook("Root branches")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(1))
        _ = try store.undo(book: book, page: page)
        try store.commit(book: book, page: page, drawing: drawing(2))
        _ = try store.stepHistory(book: book, page: page, forward: false)
        _ = try store.undo(book: book, page: page)
        store = Store(directory: folder)
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 1)
        try store.exportPackage().validate()
    }

    func testLegacyDuplicateSnapshotsAreSkippedButRetained() throws {
        let book = try store.addNotebook("Legacy")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(1))
        let head = store.notebook(book)!.pages[0].head!
        let duplicate = HistoryNode(id: UUID(), parent: head)
        let directory = folder.appendingPathComponent(book.uuidString).appendingPathComponent(page.uuidString)
        try FileManager.default.copyItem(at: directory.appendingPathComponent(head.uuidString + ".pkdraw"),
                                         to: directory.appendingPathComponent(duplicate.id.uuidString + ".pkdraw"))
        try store.update(book) {
            $0.pages[0].nodes[0].children = [duplicate.id]
            $0.pages[0].nodes[0].preferredChild = duplicate.id
            $0.pages[0].nodes.append(duplicate)
            $0.pages[0].head = duplicate.id
        }
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 0)
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 1)
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 1)
        XCTAssertNil(try store.redo(book: book, page: page))
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 2)
    }

    func testFailedIndexWriteCannotAdvanceHistoryInMemory() throws {
        let book = try store.addNotebook("Write failure")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(1))
        let head = store.notebook(book)!.pages[0].head
        let index = folder.appendingPathComponent("notebooks.json")
        let backup = folder.appendingPathComponent("index-backup.json")
        try FileManager.default.moveItem(at: index, to: backup)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.undo(book: book, page: page))
        XCTAssertEqual(store.notebook(book)?.pages[0].head, head)
        XCTAssertThrowsError(try store.commit(book: book, page: page, drawing: drawing(2)))
        XCTAssertEqual(store.notebook(book)?.pages[0].head, head)
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 1)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.moveItem(at: backup, to: index)
        XCTAssertEqual(Store(directory: folder).notebook(book)?.pages[0].head, head)
    }

    func testDeletedPageAndInkSurviveReopen() throws {
        let book = try store.addNotebook("Notes")
        let page = try XCTUnwrap(store.notebook(book)?.pages.first?.id)
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.update(book) { $0.pages.append(Page()) }
        try store.update(book) { book in
            let removed = book.pages.removeFirst()
            book.deleted.append(removed)
        }
        store = Store(directory: folder)
        let deleted = try XCTUnwrap(store.notebook(book)?.deleted.first)
        XCTAssertEqual(deleted.id, page)
        XCTAssertEqual(try store.drawing(book: book, page: deleted).strokes.count, 1)
    }

    func testObjectEraseCanCommitEmptyPage() throws {
        let book = try store.addNotebook("Erase")
        let page = try XCTUnwrap(store.notebook(book)?.pages.first?.id)
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.commit(book: book, page: page, drawing: PKDrawing())
        XCTAssertEqual(store.notebook(book)?.pages.first?.nodes.count, 2)
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 1)
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 0)
    }

    func testMissingSnapshotCannotSilentlyReplaceInk() throws {
        let book = try store.addNotebook("Missing")
        let page = try XCTUnwrap(store.notebook(book)?.pages.first?.id)
        try store.commit(book: book, page: page, drawing: drawing(1))
        let head = try XCTUnwrap(store.notebook(book)?.pages.first?.head)
        let snapshot = folder.appendingPathComponent(book.uuidString)
            .appendingPathComponent(page.uuidString).appendingPathComponent(head.uuidString + ".pkdraw")
        try FileManager.default.removeItem(at: snapshot)
        XCTAssertThrowsError(try store.drawing(book: book, page: XCTUnwrap(store.notebook(book)?.pages.first)))
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 0)
        XCTAssertThrowsError(try store.redo(book: book, page: page))
        XCTAssertNil(store.notebook(book)?.pages.first?.head)
    }

    func testUndoIsIndependentPerPage() throws {
        let book = try store.addNotebook("Two pages")
        let first = try XCTUnwrap(store.notebook(book)?.pages.first?.id)
        let second = Page()
        try store.update(book) { $0.pages.append(second) }
        try store.commit(book: book, page: first, drawing: drawing(1))
        try store.commit(book: book, page: second.id, drawing: drawing(2))
        _ = try store.undo(book: book, page: first)
        XCTAssertEqual(try store.drawing(book: book, page: XCTUnwrap(store.notebook(book)?.pages.last)).strokes.count, 2)
    }

    func testSyncPackageRestoresDeletedPagesAndBranches() throws {
        let book = try store.addNotebook("Sync")
        let page = try XCTUnwrap(store.notebook(book)?.pages.first?.id)
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.commit(book: book, page: page, drawing: drawing(2))
        _ = try store.undo(book: book, page: page)
        try store.commit(book: book, page: page, drawing: drawing(3))
        try store.update(book) {
            let deleted = $0.pages.removeFirst()
            $0.deleted.append(deleted)
            $0.pages.append(Page())
        }
        let package = try store.exportPackage()
        let attachment = XCTAttachment(data: try package.encoded(), uniformTypeIdentifier: "public.json")
        attachment.name = "sync-package.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        let destination = Store(directory: folder.appendingPathComponent("receiver"))
        try destination.importPackage(package)
        XCTAssertEqual(try destination.exportPackage().digest(), try package.digest())
        let restored = try XCTUnwrap(destination.notebook(book)?.deleted.first)
        XCTAssertEqual(restored.nodes.first?.children.count, 2)
        XCTAssertEqual(try destination.drawing(book: book, page: restored).strokes.count, 3)
        let reopened = Store(directory: folder.appendingPathComponent("receiver"))
        XCTAssertEqual(try reopened.exportPackage().digest(), try package.digest())
    }

    func testInvalidSyncDoesNotReplaceLocalData() throws {
        let book = try store.addNotebook("Keep me")
        let page = try XCTUnwrap(store.notebook(book)?.pages.first?.id)
        try store.commit(book: book, page: page, drawing: drawing(1))
        let original = try store.exportPackage()
        var bad = original
        bad.blobs = [:]
        XCTAssertThrowsError(try store.importPackage(bad))
        XCTAssertEqual(try store.exportPackage().digest(), try original.digest())
        bad = original
        bad.notebooks[0].name = "Must not appear"
        bad.blobs[bad.blobs.keys.first!] = drawing(4).dataRepresentation()
        XCTAssertThrowsError(try store.importPackage(bad))
        XCTAssertEqual(try store.exportPackage().digest(), try original.digest())
    }

    func testSyncDecisionsProtectBothCopies() throws {
        let a = SyncPackage(notebooks: [Notebook(name: "A")], blobs: [:])
        let b = SyncPackage(notebooks: [Notebook(name: "B")], blobs: [:])
        let empty = SyncPackage(notebooks: [], blobs: [:])
        let remote = SyncState(revision: 1, package: a)
        let baseline = SyncBaseline(revision: 1, digest: try a.digest())
        XCTAssertEqual(try SyncDecision.choose(local: a, remote: remote, baseline: nil), .unchanged)
        XCTAssertEqual(try SyncDecision.choose(local: empty, remote: remote, baseline: nil), .download)
        XCTAssertEqual(try SyncDecision.choose(local: b, remote: remote, baseline: baseline), .upload)
        XCTAssertEqual(try SyncDecision.choose(local: a, remote: SyncState(revision: 2, package: b), baseline: baseline), .download)
        XCTAssertEqual(try SyncDecision.choose(local: a, remote: SyncState(revision: 0, package: nil), baseline: nil), .upload)
        XCTAssertThrowsError(try SyncDecision.choose(local: b, remote: remote, baseline: nil))
        XCTAssertThrowsError(try SyncDecision.choose(local: b, remote: SyncState(revision: 2, package: empty), baseline: baseline))
        XCTAssertThrowsError(try SyncDecision.choose(local: a, remote: SyncState(revision: 0, package: nil), baseline: baseline))
    }

    func testCorruptIndexIsNeverOverwritten() throws {
        let index = folder.appendingPathComponent("notebooks.json")
        let bad = Data("broken".utf8)
        try bad.write(to: index)
        store = Store(directory: folder)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.addNotebook("Must not overwrite"))
        XCTAssertEqual(try Data(contentsOf: index), bad)
    }

    private func snapshot(book: UUID, page: UUID, node: UUID) -> URL {
        folder.appendingPathComponent(book.uuidString).appendingPathComponent(page.uuidString)
            .appendingPathComponent(node.uuidString + ".pkdraw")
    }

    private func nativeFiles() throws -> Set<String> {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        return Set(enumerator.compactMap { ($0 as? URL)?.path }.filter { $0.hasSuffix(".pkdraw") })
    }

    private func withFailedIndexWrite(_ body: () throws -> Void) throws {
        let index = folder.appendingPathComponent("notebooks.json")
        let saved = folder.appendingPathComponent("saved-index.json")
        try FileManager.default.moveItem(at: index, to: saved)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: index)
            try? FileManager.default.moveItem(at: saved, to: index)
        }
        try body()
    }

    func testNativeSnapshotIdentityIgnoresAbsoluteRootAliases() throws {
        let book = UUID(), page = UUID(), node = UUID()
        let relative = SyncPackage.key(book, page, node) + ".pkdraw"
        let applicationSupport = URL(fileURLWithPath: "/var/mobile/Library/Application Support/Draw")
        let enumeratedRoot = URL(fileURLWithPath: "/private/var/mobile/Library/Application Support/Draw")
        let referenced = applicationSupport.appendingPathComponent(relative)
        let enumerated = enumeratedRoot.appendingPathComponent(relative)
        XCTAssertNotEqual(referenced.path, enumerated.path)
        XCTAssertEqual(Store.nativeSnapshotKey(referenced), SyncPackage.key(book, page, node))
        XCTAssertEqual(Store.nativeSnapshotKey(enumerated), Store.nativeSnapshotKey(referenced))
        XCTAssertNotEqual(Store.nativeSnapshotKey(enumeratedRoot.appendingPathComponent(
            SyncPackage.key(book, page, UUID()) + ".pkdraw")), Store.nativeSnapshotKey(referenced))
        XCTAssertNil(Store.nativeSnapshotKey(enumerated.deletingPathExtension().appendingPathExtension("txt")))
    }

    func testSymlinkRootPreservesHeadsThroughMigrationLoadAndPrune() throws {
        let book = try store.addNotebook("Aliased root")
        let first = store.notebook(book)!.pages[0].id
        let second = Page()
        try store.update(book) { $0.pages.append(second) }
        for n in 1...2 {
            try store.commit(book: book, page: first, drawing: drawing(n))
            try store.commit(book: book, page: second.id, drawing: drawing(n + 2))
        }
        try store.update(book) {
            let deleted = $0.pages.removeLast()
            $0.deleted.append(deleted)
        }
        let current = try store.exportCurrentPackage()
        let savedBook = store.notebook(book)!
        let obsolete = (savedBook.pages + savedBook.deleted).flatMap { page in
            page.nodes.filter { $0.id != page.head }.map { snapshot(book: book, page: page.id, node: $0.id) }
        }
        XCTAssertEqual(obsolete.count, 2)
        try JSONEncoder().encode(store.notebooks).write(to: folder.appendingPathComponent("notebooks.json"))
        let alias = folder.deletingLastPathComponent().appendingPathComponent("DrawAlias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder.resolvingSymlinksInPath())
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertEqual(alias.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        let firstHead = store.notebook(book)!.pages[0].head!
        let realHead = snapshot(book: book, page: first, node: firstHead).resolvingSymlinksInPath()
        let aliasedHead = alias.appendingPathComponent(SyncPackage.key(book, first, firstHead) + ".pkdraw")
        XCTAssertNotEqual(realHead.path, aliasedHead.path)
        XCTAssertEqual(Store.nativeSnapshotKey(realHead), Store.nativeSnapshotKey(aliasedHead))

        store = Store(directory: alias, migrateLegacyHistory: true)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), try current.encoded())
        XCTAssertEqual(try store.exportPackage().blobs, current.blobs)
        XCTAssertEqual(try nativeFiles().count, 2)
        for file in obsolete {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Obsolete archive survived migration: \(file.lastPathComponent)")
        }
        store = Store(directory: folder.resolvingSymlinksInPath())
        XCTAssertNil(store.loadError)
        XCTAssertEqual(try store.exportPackage().blobs, current.blobs)
        store = Store(directory: alias)
        XCTAssertNil(store.loadError)
        try store.completeSuccessfulSync()
        try store.commit(book: book, page: first, drawing: drawing(5))
        let wire = try store.exportCurrentPackage()
        try store.completeSuccessfulSync()
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), try wire.encoded())
        for (key, bytes) in current.blobs {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(key + ".pkdraw")), bytes)
        }
        XCTAssertEqual(try store.undo(book: book, page: first)?.strokes.count, 2)
        XCTAssertNil(try store.undo(book: book, page: first))
        XCTAssertNil(try store.stepHistory(book: book, page: first, forward: false))
        _ = try store.redo(book: book, page: first)
        try store.completeSuccessfulSync()
        XCTAssertEqual(try store.exportPackage().blobs, wire.blobs)
        XCTAssertEqual(try nativeFiles().count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: realHead.path), "Expired floor survived pruning")
        store = Store(directory: alias)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), try wire.encoded())
        XCTAssertNil(try store.undo(book: book, page: first))
    }

    func testOneTimeLegacyMigrationPreservesCurrentBytesAndIDs() throws {
        let book = try store.addNotebook("Upgrade")
        let group = try store.addFolder("School")
        try store.moveNotebook(book, into: group)
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.commit(book: book, page: page, drawing: drawing(2))
        let deleted = Page()
        let blank = Page()
        try store.update(book) { $0.pages += [deleted, blank] }
        try store.commit(book: book, page: deleted.id, drawing: drawing(3))
        try store.commit(book: book, page: blank.id, drawing: drawing(4))
        _ = try store.undo(book: book, page: blank.id)
        try store.update(book) {
            let removed = $0.pages.remove(at: 1)
            $0.deleted.append(removed)
        }
        let current = try store.exportCurrentPackage()
        let legacy = try store.exportPackage()
        // Deliberately omit retention metadata. Fresh stores themselves are initialized.
        let oldWrapper = try JSONSerialization.data(withJSONObject: [
            "notebooks": JSONSerialization.jsonObject(with: JSONEncoder().encode(store.notebooks)),
            "folders": JSONSerialization.jsonObject(with: JSONEncoder().encode(store.folders))
        ])
        try oldWrapper.write(to: folder.appendingPathComponent("notebooks.json"))
        store = Store(directory: folder, migrateLegacyHistory: true)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), try current.encoded())
        XCTAssertEqual(try store.exportPackage().blobs, current.blobs)
        XCTAssertEqual(store.notebook(book)?.folderID, group)
        XCTAssertEqual(store.notebook(book)?.pages[1].nodes.count, 0)
        XCTAssertNil(try store.undo(book: book, page: page))
        XCTAssertNil(try store.stepHistory(book: book, page: page, forward: false))
        XCTAssertEqual(try nativeFiles().count, current.blobs.count)
        XCTAssertGreaterThan(legacy.blobs.count, current.blobs.count)
        try store.commit(book: book, page: page, drawing: drawing(5))
        let retained = try store.exportPackage().encoded()
        store = Store(directory: folder, migrateLegacyHistory: true)
        XCTAssertEqual(try store.exportPackage().encoded(), retained)
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 2)
        XCTAssertNil(try store.undo(book: book, page: page))
    }

    func testLegacyArrayOnlyMigratesWithExplicitFixtureOptIn() throws {
        let book = try store.addNotebook("Array")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.commit(book: book, page: page, drawing: drawing(2))
        let legacy = try JSONEncoder().encode(store.notebooks)
        let index = folder.appendingPathComponent("notebooks.json")
        try legacy.write(to: index)
        let fixture = Store(directory: folder)
        XCTAssertEqual(fixture.notebook(book)?.pages[0].nodes.count, 2)
        XCTAssertEqual(try Data(contentsOf: index), legacy)
        store = Store(directory: folder, migrateLegacyHistory: true)
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 1)
        XCTAssertNil(try store.undo(book: book, page: page))
    }

    func testMigrationWithUnreadableCurrentHeadDoesNotPruneOrRewriteIndex() throws {
        let book = try store.addNotebook("Unreadable upgrade")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.commit(book: book, page: page, drawing: drawing(2))
        let head = store.notebook(book)!.pages[0].head!
        try Data("broken".utf8).write(to: snapshot(book: book, page: page, node: head))
        let index = folder.appendingPathComponent("notebooks.json")
        let legacy = try JSONEncoder().encode(store.notebooks)
        try legacy.write(to: index)
        let files = try nativeFiles()
        store = Store(directory: folder, migrateLegacyHistory: true)
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 2)
        XCTAssertEqual(try Data(contentsOf: index), legacy)
        XCTAssertEqual(try nativeFiles(), files)
    }

    func testMigrationIgnoresMissingAndCorruptObsoleteArchives() throws {
        let book = try store.addNotebook("Discarded undo")
        let page = store.notebook(book)!.pages[0].id
        for n in 1...3 { try store.commit(book: book, page: page, drawing: drawing(n)) }
        let saved = store.notebook(book)!.pages[0]
        let current = try store.exportCurrentPackage()
        let index = folder.appendingPathComponent("notebooks.json")
        try JSONEncoder().encode(store.notebooks).write(to: index)
        try FileManager.default.removeItem(at: snapshot(book: book, page: page, node: saved.nodes[0].id))
        try Data("discarded broken archive".utf8).write(to: snapshot(book: book, page: page, node: saved.nodes[1].id))

        store = Store(directory: folder, migrateLegacyHistory: true)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.notebook(book)?.pages[0].head, saved.head)
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.map(\.id), [saved.head!])
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), try current.encoded())
        XCTAssertEqual(try store.exportPackage().blobs, current.blobs)
        XCTAssertEqual(try nativeFiles().count, 1)
        XCTAssertNil(try store.undo(book: book, page: page))
        store = Store(directory: folder)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), try current.encoded())
    }

    func testSuccessfulSyncRotatesTwoWindowsAndPersistsNonblankFloor() throws {
        let book = try store.addNotebook("Windows")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.commit(book: book, page: page, drawing: drawing(2))
        let old = store.notebook(book)!.pages[0].nodes[0].id
        let baseline = store.notebook(book)!.pages[0].head!
        try store.completeSuccessfulSync()
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 2)
        try store.commit(book: book, page: page, drawing: drawing(3))
        try store.commit(book: book, page: page, drawing: drawing(4))
        let head = store.notebook(book)!.pages[0].head!
        let wire = try store.exportCurrentPackage().encoded()
        try store.completeSuccessfulSync()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot(book: book, page: page, node: old).path))
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 3)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), wire)
        store = Store(directory: folder)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 3)
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 2)
        XCTAssertEqual(store.notebook(book)?.pages[0].head, baseline)
        XCTAssertNil(try store.undo(book: book, page: page))
        XCTAssertNil(try store.stepHistory(book: book, page: page, forward: false))
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 3)
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 4)
        XCTAssertEqual(store.notebook(book)?.pages[0].head, head)
        try store.completeSuccessfulSync()
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.map(\.id), [head])
        XCTAssertNil(try store.undo(book: book, page: page))
    }

    func testTwoSuccessfulSyncsWithoutEditsRemoveOlderUndo() throws {
        let book = try store.addNotebook("No edits")
        let page = store.notebook(book)!.pages[0].id
        for n in 1...3 { try store.commit(book: book, page: page, drawing: drawing(n)) }
        let wire = try store.exportCurrentPackage().encoded()
        try store.completeSuccessfulSync()
        try store.completeSuccessfulSync()
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 1)
        XCTAssertEqual(try nativeFiles().count, 1)
        XCTAssertNil(try store.undo(book: book, page: page))
        XCTAssertNil(try store.stepHistory(book: book, page: page, forward: false))
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), wire)
    }

    func testBranchesSincePreviousSyncKeepTheirEntryFloors() throws {
        let book = try store.addNotebook("Old branch")
        let page = store.notebook(book)!.pages[0].id
        for n in 1...3 { try store.commit(book: book, page: page, drawing: drawing(n)) }
        let baseline = store.notebook(book)!.pages[0].head!
        try store.completeSuccessfulSync()
        _ = try store.undo(book: book, page: page)
        _ = try store.undo(book: book, page: page)
        let branchFloor = store.notebook(book)!.pages[0].head!
        try store.commit(book: book, page: page, drawing: drawing(4))
        let branchA = store.notebook(book)!.pages[0].head!
        _ = try store.undo(book: book, page: page)
        try store.commit(book: book, page: page, drawing: drawing(5))
        let branchB = store.notebook(book)!.pages[0].head!
        try store.completeSuccessfulSync()
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.map(\.id), [branchFloor, baseline, branchA, branchB])
        try store.exportPackage().validate()
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 1)
        XCTAssertNil(try store.undo(book: book, page: page))
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 5)
        XCTAssertEqual(try store.stepHistory(book: book, page: page, forward: false)?.strokes.count, 4)
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 1)
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 4)
        store = Store(directory: folder)
        XCTAssertEqual(try store.stepHistory(book: book, page: page, forward: false)?.strokes.count, 3)
        XCTAssertNil(try store.undo(book: book, page: page))
        XCTAssertEqual(try store.stepHistory(book: book, page: page, forward: false)?.strokes.count, 1)
        XCTAssertNil(try store.stepHistory(book: book, page: page, forward: false))
    }

    func testRotationPreservesHeadOnOldBranchEvenWithoutNewNode() throws {
        let book = try store.addNotebook("Old selected head")
        let page = store.notebook(book)!.pages[0].id
        for n in 1...3 { try store.commit(book: book, page: page, drawing: drawing(n)) }
        try store.completeSuccessfulSync()
        _ = try store.undo(book: book, page: page)
        let head = store.notebook(book)!.pages[0].head
        let wire = try store.exportCurrentPackage().encoded()
        try store.completeSuccessfulSync()
        XCTAssertEqual(store.notebook(book)?.pages[0].head, head)
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 2)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), wire)
        XCTAssertNil(try store.undo(book: book, page: page))
        try store.completeSuccessfulSync()
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 1)
    }

    func testBlankCheckpointAndNewRootBranchesRemainNavigable() throws {
        let book = try store.addNotebook("Blank roots")
        let page = store.notebook(book)!.pages[0].id
        try store.completeSuccessfulSync() // The baseline really is blank.
        try store.commit(book: book, page: page, drawing: drawing(1))
        _ = try store.undo(book: book, page: page)
        try store.commit(book: book, page: page, drawing: drawing(2))
        try store.completeSuccessfulSync()
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 2)
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 0)
        store = Store(directory: folder)
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 2)
        XCTAssertEqual(try store.stepHistory(book: book, page: page, forward: false)?.strokes.count, 1)
        XCTAssertEqual(try store.stepHistory(book: book, page: page, forward: false)?.strokes.count, 0)
        try store.completeSuccessfulSync() // Selected head nil stays blank; roots expire.
        XCTAssertNil(store.notebook(book)?.pages[0].head)
        try store.exportCurrentPackage().validate()
    }

    func testExportCurrentIncludesDeletedAndBlankPagesWithoutChangingLocalHistory() throws {
        let group = try store.addFolder("Empty")
        let book = try store.addNotebook("Wire", in: group)
        let page = store.notebook(book)!.pages[0].id
        for n in 1...3 { try store.commit(book: book, page: page, drawing: drawing(n)) }
        let blank = Page()
        try store.update(book) { $0.pages.append(blank) }
        try store.commit(book: book, page: blank.id, drawing: drawing(4))
        _ = try store.undo(book: book, page: blank.id)
        try store.update(book) {
            let removed = $0.pages.removeFirst()
            $0.deleted.append(removed)
        }
        let index = folder.appendingPathComponent("notebooks.json")
        let disk = try Data(contentsOf: index)
        let before = try store.exportPackage().encoded()
        let wire = try store.exportCurrentPackage()
        XCTAssertEqual(wire.folders?.first?.id, group)
        XCTAssertEqual(wire.notebooks[0].folderID, group)
        XCTAssertEqual(wire.blobs.count, 1)
        XCTAssertEqual(wire.notebooks[0].pages[0].nodes.count, 0)
        XCTAssertNil(wire.notebooks[0].pages[0].preferredRoot)
        let deleted = wire.notebooks[0].deleted[0]
        XCTAssertEqual(deleted.id, page)
        XCTAssertEqual(deleted.nodes.count, 1)
        XCTAssertNil(deleted.nodes[0].parent)
        XCTAssertTrue(deleted.nodes[0].children.isEmpty)
        XCTAssertNil(deleted.nodes[0].preferredChild)
        XCTAssertEqual(deleted.preferredRoot, deleted.head)
        try wire.validate()
        XCTAssertEqual(try store.exportPackage().encoded(), before)
        XCTAssertEqual(try Data(contentsOf: index), disk)
        store = Store(directory: folder)
        XCTAssertEqual(try store.exportPackage().encoded(), before)
    }

    func testDeletedPagesNewPagesDuplicatesAndFoldersSurviveRotation() throws {
        let book = try store.addNotebook("Organization")
        let page = store.notebook(book)!.pages[0].id
        let group = try store.addFolder("School")
        let emptyGroup = try store.addFolder("Empty")
        try store.moveNotebook(book, into: group)
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.commit(book: book, page: page, drawing: drawing(2))
        try store.completeSuccessfulSync()
        try store.duplicate(book: book, page: store.notebook(book)!.pages[0])
        let copy = store.notebook(book)!.pages[0].id
        let blank = Page()
        try store.update(book) { book in
            book.deleted.append(book.pages.removeLast())
            book.pages.append(blank)
        }
        try store.completeSuccessfulSync()
        store = Store(directory: folder)
        XCTAssertEqual(store.folders.map(\.id), [group, emptyGroup])
        XCTAssertEqual(store.notebook(book)?.folderID, group)
        XCTAssertEqual(store.notebook(book)?.deleted[0].nodes.count, 1)
        XCTAssertEqual(try store.drawing(book: book, page: store.notebook(book)!.deleted[0]).strokes.count, 2)
        XCTAssertEqual(try store.undo(book: book, page: copy)?.strokes.count, 0)
        try store.commit(book: book, page: blank.id, drawing: drawing(3))
        try store.completeSuccessfulSync()
        XCTAssertEqual(try store.undo(book: book, page: blank.id)?.strokes.count, 0)
        try store.exportPackage().validate()
    }

    func testFailedRotationCommitDuplicateAndImportRollbackMemoryAndSnapshots() throws {
        let book = try store.addNotebook("Atomic")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.commit(book: book, page: page, drawing: drawing(2))
        try store.completeSuccessfulSync()
        try store.commit(book: book, page: page, drawing: drawing(3))
        let before = try store.exportPackage().encoded()
        let files = try nativeFiles()
        let wire = try store.exportCurrentPackage()
        var remote = wire
        let remoteHead = UUID()
        remote.notebooks[0].pages[0].nodes = [HistoryNode(id: remoteHead, parent: nil)]
        remote.notebooks[0].pages[0].head = remoteHead
        remote.notebooks[0].pages[0].preferredRoot = remoteHead
        remote.blobs = [SyncPackage.key(book, page, remoteHead): drawing(4).dataRepresentation()]
        try withFailedIndexWrite {
            XCTAssertThrowsError(try store.completeSuccessfulSync())
            XCTAssertEqual(try store.exportPackage().encoded(), before)
            XCTAssertEqual(try nativeFiles(), files)
            XCTAssertThrowsError(try store.commit(book: book, page: page, drawing: drawing(5)))
            XCTAssertThrowsError(try store.duplicate(book: book, page: store.notebook(book)!.pages[0]))
            XCTAssertThrowsError(try store.importPackage(remote))
            XCTAssertThrowsError(try store.addNotebook("Failed"))
            XCTAssertThrowsError(try store.update(book) { $0.name = "Failed" })
            XCTAssertEqual(try store.exportPackage().encoded(), before)
            XCTAssertEqual(try nativeFiles(), files)
        }
        store = Store(directory: folder)
        XCTAssertEqual(try store.exportPackage().encoded(), before)
        try store.completeSuccessfulSync() // Failed rotation did not advance the checkpoint.
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 2)
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 2)
        XCTAssertNil(try store.undo(book: book, page: page))
    }

    func testUnreadableSnapshotStopsRotationAndLoadCleanup() throws {
        let book = try store.addNotebook("Read failure")
        let page = store.notebook(book)!.pages[0].id
        for n in 1...3 { try store.commit(book: book, page: page, drawing: drawing(n)) }
        try store.completeSuccessfulSync()
        let first = store.notebook(book)!.pages[0].nodes[0].id
        let orphan = snapshot(book: book, page: page, node: UUID())
        try drawing(4).dataRepresentation().write(to: orphan)
        let index = folder.appendingPathComponent("notebooks.json")
        let disk = try Data(contentsOf: index)
        let bytes = try Data(contentsOf: snapshot(book: book, page: page, node: first))
        try FileManager.default.removeItem(at: snapshot(book: book, page: page, node: first))
        let files = try nativeFiles()
        XCTAssertThrowsError(try store.completeSuccessfulSync())
        XCTAssertEqual(try Data(contentsOf: index), disk)
        XCTAssertEqual(try nativeFiles(), files)
        store = Store(directory: folder)
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(try nativeFiles(), files)
        try bytes.write(to: snapshot(book: book, page: page, node: first))
        store = Store(directory: folder)
        XCTAssertNil(store.loadError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try Data(contentsOf: index), disk)
    }

    func testFailedPruneLeavesOrphansAndRecoveryIndexUntilDurableCommit() throws {
        let book = try store.addNotebook("Cleanup ordering")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.commit(book: book, page: page, drawing: drawing(2))
        try store.completeSuccessfulSync()
        let orphan = snapshot(book: book, page: page, node: UUID())
        try drawing(3).dataRepresentation().write(to: orphan)
        let recovery = folder.appendingPathComponent("before-sync-old.json")
        try FileManager.default.copyItem(at: folder.appendingPathComponent("notebooks.json"), to: recovery)
        let unrelated = orphan.deletingLastPathComponent().appendingPathComponent("keep.txt")
        try Data("Keep".utf8).write(to: unrelated)
        let files = try nativeFiles()
        try withFailedIndexWrite {
            XCTAssertThrowsError(try store.completeSuccessfulSync())
            XCTAssertEqual(try nativeFiles(), files)
            XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        }
        try store.completeSuccessfulSync()
        XCTAssertEqual(try nativeFiles().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCurrentOnlyDownloadAppendsToRetainedLocalBranch() throws {
        let book = try store.addNotebook("Download")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.completeSuccessfulSync()
        try store.commit(book: book, page: page, drawing: drawing(2))
        let previous = store.notebook(book)!.pages[0].head!
        var remote = try store.exportCurrentPackage()
        let remoteHead = UUID()
        remote.notebooks[0].pages[0].nodes = [HistoryNode(id: remoteHead, parent: nil)]
        remote.notebooks[0].pages[0].head = remoteHead
        remote.notebooks[0].pages[0].preferredRoot = remoteHead
        remote.notebooks[0].pages[0].starred = true
        remote.blobs = [SyncPackage.key(book, page, remoteHead): drawing(3).dataRepresentation()]
        try store.importPackage(remote)
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.last?.parent, previous)
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 3)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), try remote.encoded())
        try store.completeSuccessfulSync()
        store = Store(directory: folder)
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 2)
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 1)
        XCTAssertNil(try store.undo(book: book, page: page))
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 2)
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 3)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(files.contains { $0.hasPrefix("before-sync-") })
        let full = try store.exportPackage().encoded()
        try store.importPackage(remote) // Identical head does not add or remove history.
        XCTAssertEqual(try store.exportPackage().encoded(), full)
    }

    func testCurrentOnlyDownloadCanSelectExistingBranchOrResetToBlank() throws {
        let book = try store.addNotebook("Download branch")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.commit(book: book, page: page, drawing: drawing(2))
        let branch = try store.exportCurrentPackage()
        _ = try store.undo(book: book, page: page)
        try store.commit(book: book, page: page, drawing: drawing(3))
        let files = try nativeFiles()
        try store.importPackage(branch)
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 3)
        XCTAssertEqual(try nativeFiles(), files)
        XCTAssertEqual(try store.drawing(book: book, page: store.notebook(book)!.pages[0]).strokes.count, 2)
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 1)
        var blank = branch
        blank.notebooks[0].pages[0].nodes = []
        blank.notebooks[0].pages[0].head = nil
        blank.notebooks[0].pages[0].preferredRoot = nil
        blank.blobs = [:]
        try store.importPackage(blank)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), try blank.encoded())
        XCTAssertEqual(try nativeFiles().count, 0)
        XCTAssertNil(try store.redo(book: book, page: page))
        try store.commit(book: book, page: page, drawing: drawing(4))
        _ = try store.undo(book: book, page: page)
        try store.importPackage(blank) // Identical nil head preserves a retained root branch.
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 1)
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 4)

        let receiver = Store(directory: folder.appendingPathComponent("receiver"))
        try receiver.importPackage(branch)
        XCTAssertEqual(receiver.notebook(book)?.pages[0].nodes.count, 1)
        XCTAssertNil(try receiver.undo(book: book, page: page))
        XCTAssertNil(try receiver.stepHistory(book: book, page: page, forward: false))
    }
    // Bounded numeric diagnostics only; do not dump notebook names or source bytes.
    private func sourceDateDifferences(_ before: Data, _ after: Data) throws -> String {
        let oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        let newJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: after) as? [String: Any])
        let oldBooks = try XCTUnwrap(oldJSON["notebooks"] as? [[String: Any]])
        let newBooks = try XCTUnwrap(newJSON["notebooks"] as? [[String: Any]])
        var differences: [String] = []
        for (index, pair) in zip(oldBooks, newBooks).enumerated() {
            for field in ["created", "modified"] {
                guard let old = pair.0[field] as? NSNumber, let new = pair.1[field] as? NSNumber,
                      old.doubleValue != new.doubleValue else { continue }
                let a = old.doubleValue, b = new.doubleValue
                differences.append("notebooks[\(index)].\(field): " +
                    String(format: "%.17g [0x%016llx] -> %.17g [0x%016llx]", a, a.bitPattern, b, b.bitPattern))
                if differences.count == 8 { return differences.joined(separator: "; ") }
            }
        }
        return differences.isEmpty ? "No numeric Date differences; inspect non-Date encoding if bytes differ." : differences.joined(separator: "; ")
    }

    func testNativeIndexDatesAndSourcePackageDigestsStayExactAcrossReloads() throws {
        // Exercise real Date() and fractional Date values, without rewriting JSON
        // through NSNumber/JSONSerialization as the migration fixture does.
        for i in 0..<12 {
            let book = try store.addNotebook("Date fixture")
            try store.update(book) {
                $0.created = Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(i) + Double(i + 1) * 0.0123456789)
            }
        }
        let baseline = try store.exportCurrentPackage().encoded()
        let digest = AIHash.digest(baseline)
        for round in 0..<4 {
            store = Store(directory: folder, migrateLegacyHistory: false)
            XCTAssertNil(store.loadError)
            let reloaded = try store.exportCurrentPackage().encoded()
            let indexDiagnostic = try sourceDateDifferences(baseline, reloaded)
            XCTAssertEqual(reloaded, baseline, "Index reload \(round): " + indexDiagnostic)
            XCTAssertEqual(AIHash.digest(reloaded), digest)
            let decoded = try JSONDecoder().decode(SyncPackage.self, from: reloaded)
            let packageBytes = try decoded.encoded()
            let packageDiagnostic = try sourceDateDifferences(baseline, packageBytes)
            XCTAssertEqual(packageBytes, baseline, "Source package roundtrip \(round): " + packageDiagnostic)
            // A migration writes a new index with decoded dates. Test that exact
            // same serialization path too, not only repeated reads of one index.
            try store.save()
        }
    }

    func testSchemaTwoTealMigrationRunsOncePreservesMetadataAndReconciliationEvidence() throws {
        let book = try store.addNotebook("Question merge", orientation: "landscape")
        let group = try store.addFolder("School")
        try store.moveNotebook(book, into: group)
        let page = store.notebook(book)!.pages[0].id
        let source = drawing(1).strokes[0]
        let teal = PKStroke(ink: PKInk(source.ink.inkType, color: MissedInk.color), path: source.path,
            transform: CGAffineTransform(translationX: 10, y: 15), mask: UIBezierPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100)), randomSeed: 123)
        try store.commit(book: book, page: page, drawing: drawing(2))
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [teal, source]))
        try store.update(book) { $0.pages[0].background = 3; $0.pages[0].starred = true; $0.currentPage = page }
        let freshBytes = try store.exportCurrentPackage().encoded()
        let oldHead = store.notebook(book)!.pages[0].head!
        let oldBytes = try Data(contentsOf: snapshot(book: book, page: page, node: oldHead))
        let beforeStroke = try PortableStroke(store.drawing(book: book, page: store.notebook(book)!.pages[0]).strokes[0])
        let index = folder.appendingPathComponent("notebooks.json")
        var wrapper = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        wrapper.removeValue(forKey: "historySchemaVersion") // Previous localHistory schema already exists.
        try JSONSerialization.data(withJSONObject: wrapper).write(to: index)
        // Migration starts from this persisted index, not the earlier in-memory
        // Date values or the test's JSONSerialization rewrite of the old wrapper.
        store = Store(directory: folder, migrateLegacyHistory: false)
        XCTAssertNil(store.loadError)
        let before = try store.exportCurrentPackage()
        let persistedBytes = try before.encoded()
        let oldModified = store.notebook(book)!.modified
        if freshBytes != persistedBytes {
            let diagnostic = try sourceDateDifferences(freshBytes, persistedBytes)
            print("Migration fixture rewrite: \(diagnostic)")
        }
        let savedBaseline = UserDefaults.standard.data(forKey: "syncBaseline")
        defer { UserDefaults.standard.set(savedBaseline, forKey: "syncBaseline") }
        let baseline = try JSONEncoder().encode(SyncBaseline(revision: 10, digest: AIHash.digest(persistedBytes)))
        UserDefaults.standard.set(baseline, forKey: "syncBaseline")
        store = Store(directory: folder, migrateLegacyHistory: true)
        XCTAssertNil(store.loadError)
        let afterBook = try XCTUnwrap(store.notebook(book))
        let afterPage = afterBook.pages[0]
        XCTAssertEqual(afterBook.id, before.notebooks[0].id)
        XCTAssertEqual(afterPage.id, page)
        XCTAssertEqual(afterPage.background, 3)
        XCTAssertTrue(afterPage.starred)
        XCTAssertEqual(afterBook.currentPage, page)
        XCTAssertEqual(afterBook.folderID, group)
        XCTAssertEqual(afterBook.orientation, "landscape")
        XCTAssertEqual(afterBook.modified, oldModified)
        XCTAssertEqual(afterPage.nodes.count, 1)
        XCTAssertNotEqual(afterPage.head, oldHead)
        let afterNative = try store.drawing(book: book, page: afterPage)
        XCTAssertEqual(afterNative.strokes.count, 2)
        XCTAssertTrue(QuestionInk.matches(afterNative.strokes[0].ink.color))
        let afterStroke = try PortableStroke(afterNative.strokes[0])
        XCTAssertEqual(afterStroke.points, beforeStroke.points)
        XCTAssertEqual(afterStroke.transform, beforeStroke.transform)
        XCTAssertEqual(afterStroke.mask, beforeStroke.mask)
        XCTAssertEqual(afterStroke.randomSeed, beforeStroke.randomSeed)
        XCTAssertNil(try store.undo(book: book, page: page))
        let journal = try XCTUnwrap(store.migrationJournal())
        XCTAssertEqual(journal.preMigrationDigest, AIHash.digest(persistedBytes))
        let journalDiagnostic = try sourceDateDifferences(persistedBytes, journal.preMigrationPackage)
        XCTAssertEqual(journal.preMigrationPackage, persistedBytes, journalDiagnostic)
        XCTAssertEqual(journal.globalBaseline, baseline)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "syncBaseline"), baseline)
        // The old immutable file may be cleaned, but was never overwritten under its ID.
        if FileManager.default.fileExists(atPath: snapshot(book: book, page: page, node: oldHead).path) {
            XCTAssertEqual(try Data(contentsOf: snapshot(book: book, page: page, node: oldHead)), oldBytes)
        }
        var expectedMigrated = try store.exportCurrentPackage()
        let journalBytes = try Data(contentsOf: folder.appendingPathComponent("ai-migration-journal.json"))
        try store.commit(book: book, page: page, drawing: drawing(4))
        let committedModified = try XCTUnwrap(store.notebook(book)?.modified)
        // Undo is per-page combined state, not a rollback of document metadata.
        expectedMigrated.notebooks[0].modified = committedModified
        store = Store(directory: folder, migrateLegacyHistory: true)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, 2)
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 2)
        XCTAssertEqual(store.notebook(book)?.modified, committedModified)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), try expectedMigrated.encoded())
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("ai-migration-journal.json")), journalBytes)
        let newWrapper = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        XCTAssertEqual(newWrapper["historySchemaVersion"] as? Int, 2)
    }

    func testSchemaTwoMigrationSkipsUnreadableObsoleteHistoryButFailsUnreadableCurrent() throws {
        let book = try store.addNotebook("Current validation")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.commit(book: book, page: page, drawing: drawing(2))
        let nodes = store.notebook(book)!.pages[0].nodes
        let index = folder.appendingPathComponent("notebooks.json")
        var wrapper = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        wrapper["historySchemaVersion"] = 1
        let legacy = try JSONSerialization.data(withJSONObject: wrapper)
        try legacy.write(to: index)
        let persisted = Store(directory: folder, migrateLegacyHistory: false)
        XCTAssertNil(persisted.loadError)
        let before = try persisted.exportCurrentPackage().encoded()
        try Data("obsolete".utf8).write(to: snapshot(book: book, page: page, node: nodes[0].id))
        let currentBytes = try Data(contentsOf: snapshot(book: book, page: page, node: nodes[1].id))
        try Data("current unreadable".utf8).write(to: snapshot(book: book, page: page, node: nodes[1].id))
        let inventory = try nativeFiles()
        store = Store(directory: folder, migrateLegacyHistory: true)
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(try Data(contentsOf: index), legacy)
        XCTAssertEqual(try nativeFiles(), inventory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ai-migration-journal.json").path))
        try currentBytes.write(to: snapshot(book: book, page: page, node: nodes[1].id))
        store = Store(directory: folder, migrateLegacyHistory: true)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), before)
        XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, 1)
        XCTAssertEqual(try nativeFiles().count, 1)
    }

}

@MainActor
final class CanvasLayoutTests: XCTestCase {
    func testCanvasDisablesEditingWithoutDisablingDrawingRecognizer() {
        let canvas = DrawingCanvas()
        canvas.drawingPolicy = .pencilOnly
        let child = UIView()
        let longPress = UILongPressGestureRecognizer()
        let tap = UITapGestureRecognizer()
        child.addGestureRecognizer(longPress)
        child.addGestureRecognizer(tap)
        canvas.addSubview(child)
        canvas.layoutSubviews()
        XCTAssertFalse(longPress.isEnabled)
        XCTAssertTrue(tap.isEnabled)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(canvas.editingInteractionConfiguration == .none)
        for action in ["selectAll:", "paste:", "cut:", "copy:", "insertSpace:"] {
            XCTAssertFalse(canvas.canPerformAction(NSSelectorFromString(action), withSender: nil))
        }
        // Also catch recognizers installed after the initial layout.
        let later = UILongPressGestureRecognizer()
        child.addGestureRecognizer(later)
        canvas.layoutSubviews()
        XCTAssertFalse(later.isEnabled)
        let alreadyDisabled = UILongPressGestureRecognizer()
        alreadyDisabled.isEnabled = false
        child.addGestureRecognizer(alreadyDisabled)
        canvas.selectionEditingEnabled = true
        canvas.layoutSubviews()
        XCTAssertTrue(longPress.isEnabled)
        XCTAssertTrue(later.isEnabled)
        XCTAssertFalse(alreadyDisabled.isEnabled)
        XCTAssertTrue(canvas.editingInteractionConfiguration == .default)
        for action in ["selectAll:", "insertSpace:", "undo:", "redo:"] {
            XCTAssertFalse(canvas.canPerformAction(NSSelectorFromString(action), withSender: nil))
        }
        canvas.selectionEditingEnabled = false
        canvas.layoutSubviews()
        XCTAssertFalse(longPress.isEnabled)
        XCTAssertFalse(later.isEnabled)
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
    }

    func testToolbarPositionDefaultAndPersistence() throws {
        let suite = "DrawTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ToolbarPosition.saved(in: defaults), .bottom)
        for position in ToolbarPosition.allCases {
            defaults.set(position.rawValue, forKey: "toolbarPosition")
            XCTAssertEqual(ToolbarPosition.saved(in: defaults), position)
        }
        defaults.set("invalid", forKey: "toolbarPosition")
        XCTAssertEqual(ToolbarPosition.saved(in: defaults), .bottom)
    }

    func testPageFillsViewportWithoutStretchingOrCroppingRequiredArea() {
        let viewport = PageViewport()
        let original = CGSize(width: 1024, height: 1278)
        viewport.pageSize = original
        for available in [original, CGSize(width: 980, height: 1322)] {
            viewport.frame = CGRect(origin: .zero, size: available)
            viewport.layoutSubviews()
            XCTAssertGreaterThanOrEqual(viewport.surface.bounds.width, original.width - 0.01)
            XCTAssertGreaterThanOrEqual(viewport.surface.bounds.height, original.height - 0.01)
            XCTAssertEqual(viewport.surface.frame.minX, 0, accuracy: 0.01)
            XCTAssertEqual(viewport.surface.frame.minY, 0, accuracy: 0.01)
            XCTAssertEqual(viewport.surface.frame.maxX, available.width, accuracy: 0.01)
            XCTAssertEqual(viewport.surface.frame.maxY, available.height, accuracy: 0.01)
            XCTAssertEqual(viewport.surface.transform.a, viewport.surface.transform.d)
        }
    }
}
