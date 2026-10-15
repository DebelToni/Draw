import XCTest
import UIKit
import PencilKit
@testable import Draw

@MainActor
final class CarryPageTests: XCTestCase {
    private var root: URL!
    private var store: Store!
    private var book: UUID!
    private var page: UUID!
    private let contextHash = String(repeating: "a", count: 64)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = Store(directory: root)
        book = try store.addNotebook("Carry fixture", orientation: "landscape")
        page = store.notebook(book)!.pages[0].id
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func saved(_ id: UUID) -> Page { store.notebook(book)!.pages.first { $0.id == id }! }
    private func native(_ id: UUID) throws -> PKDrawing { try store.drawing(book: book, page: saved(id)) }
    private func scene(_ id: UUID) -> [AIObject] { store.objects(book: book, page: saved(id)) }
    private func canonical(_ drawing: PKDrawing) throws -> PKDrawing { try PKDrawing(data: drawing.dataRepresentation()) }

    private func stroke(_ ys: [CGFloat], type: PKInk.InkType = .monoline,
                        transform: CGAffineTransform = .identity, mask: UIBezierPath? = nil) -> PKStroke {
        let controls = ys.enumerated().map { i, y in
            PKStrokePoint(location: CGPoint(x: 40 + CGFloat(i) * 50, y: y), timeOffset: Double(i) / 8,
                size: CGSize(width: type == .marker ? 20 : 6, height: type == .marker ? 20 : 6),
                opacity: type == .marker ? 0.5 : 1, force: 0.75, azimuth: 0.25, altitude: 1.25,
                secondaryScale: 0.875, threshold: 0.25)
        }
        let path = PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSince1970: 1_700_000_000))
        let ink = PKInk(type, color: type == .marker ? .yellow : .blue)
        if #available(iOS 27.0, *) {
            return PKStroke(ink: ink, path: path, transform: transform, mask: mask, randomSeed: 0xBEEF,
                id: UUID(), renderGroupID: UUID(),
                renderState: PKStroke.RenderState(grainOffset: CGPoint(x: 3.25, y: -4.5)))
        }
        return PKStroke(ink: ink, path: path, transform: transform, mask: mask, randomSeed: 0xBEEF)
    }

    private func result(_ request: UUID, _ edits: [AIObjectEdit]) -> AIResult {
        AIResult(requestID: request, documentID: book, contextSHA256: contextHash, draftVersion: 1,
            rendererSignature: "draw-ai-render-v1", insertPages: [],
            pageEdits: [AIPageEdit(pageID: page, objectEdits: edits, strokeEdits: [])],
            previewSHA256s: [page.uuidString: contextHash])
    }

    @discardableResult
    private func addObjects(_ ys: [Double]) throws -> AIApplyReceipt {
        let request = UUID()
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10),
            format: AICapture.rendererFormat()).image { context in
                UIColor.purple.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
            }.pngData())
        let asset = AIAsset(sha256: AIHash.digest(png), pixelWidth: 40, pixelHeight: 20)
        let objects = ys.map { y in
            AIObject(id: UUID(), revision: 1, kind: "text", source: "Immutable answer", frame: AIFrame(x: 35, y: y, width: 20, height: 10),
                style: AIStyle(fontSize: 18, color: "#0033CC", lineWidth: 2), asset: asset,
                provenance: AIProvenance(requestID: request, contextSHA256: contextHash, rendererSignature: "draw-ai-render-v1"))
        }
        return try store.applyAI(result(request, objects.map { AIObjectEdit(op: "add", object: $0) }), assets: [asset.sha256: png])
    }

    private func assertTranslatedAttributes(_ expected: PKStroke, _ actual: PKStroke,
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        let e = try PortableStroke(expected, includeSamples: false), a = try PortableStroke(actual, includeSamples: false)
        XCTAssertEqual(a.inkType, e.inkType, file: file, line: line)
        XCTAssertEqual(a.color, e.color, file: file, line: line)
        XCTAssertEqual(a.randomSeed, e.randomSeed, file: file, line: line)
        XCTAssertEqual(a.points, e.points, file: file, line: line)
        XCTAssertEqual(a.creationDate, e.creationDate, file: file, line: line)
        XCTAssertEqual(a.pathID, e.pathID, file: file, line: line)
        XCTAssertEqual(a.renderGroupID, e.renderGroupID, file: file, line: line)
        XCTAssertEqual(a.grainOffset, e.grainOffset, file: file, line: line)
        for (actual, expected) in zip(a.transform, e.transform) {
            XCTAssertEqual(actual, expected, accuracy: 0.010001, file: file, line: line)
        }
        XCTAssertEqual(a.mask?.evenOdd, e.mask?.evenOdd, file: file, line: line)
        XCTAssertEqual(a.mask?.commands.count, e.mask?.commands.count, file: file, line: line)
        for (actual, expected) in zip(a.mask?.commands ?? [], e.mask?.commands ?? []) {
            XCTAssertEqual(actual.count, expected.count, file: file, line: line)
            XCTAssertEqual(actual.first, expected.first, file: file, line: line)
            // Native archive mask requantization can change coordinates by one 0.01 pt step.
            for (x, y) in zip(actual.dropFirst(), expected.dropFirst()) {
                XCTAssertEqual(x, y, accuracy: 0.010001, file: file, line: line)
            }
        }
    }

    private func pixels(_ drawing: PKDrawing, rect: CGRect) throws -> Data {
        let image = try XCTUnwrap(drawing.image(from: rect, scale: 2).cgImage)
        var data = Data(count: image.width * image.height * 4)
        let rendered = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(rendered)
        return data
    }

    func testWholeNativeStrokesMasksTransformsMarkerAndNegativeBoundsSurviveCopyAndCropping() throws {
        let mask = UIBezierPath(rect: CGRect(x: 30, y: 40, width: 140, height: 170))
        mask.append(UIBezierPath(rect: CGRect(x: 65, y: 105, width: 25, height: 20)))
        mask.usesEvenOddFillRule = true
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [
            stroke([20, 30]), stroke([70, 170], mask: mask),
            stroke([65, 160], type: .marker, transform: CGAffineTransform(a: 1, b: 0.125, c: -0.125, d: 1, tx: 90, ty: 15), mask: mask)
        ]))
        let source = try native(page)
        let cut: CGFloat = 100
        XCTAssertLessThan(source.strokes[0].renderBounds.maxY, cut)
        XCTAssertTrue(source.strokes.dropFirst().allSatisfy { $0.renderBounds.maxY >= cut && $0.renderBounds.minY < cut })
        // SDK translation and its persisted archive are the oracle, not constructor inputs.
        let expected = try canonical(PKDrawing(strokes: Array(source.strokes.dropFirst()))
            .transformed(using: CGAffineTransform(translationX: 0, y: -cut)))
        let new = try store.carryBelow(book: book, page: page, y: cut)
        let actual = try native(new)
        XCTAssertEqual(actual.strokes.count, 2)
        XCTAssertLessThan(actual.bounds.minY, 0)
        for (e, a) in zip(expected.strokes, actual.strokes) {
            try assertTranslatedAttributes(e, a)
            XCTAssertEqual(a.renderBounds.minX, e.renderBounds.minX, accuracy: 0.02)
            XCTAssertEqual(a.renderBounds.minY, e.renderBounds.minY, accuracy: 0.02)
        }
        if #available(iOS 27.0, *) {
            let originals = Set(source.strokes.map(\.id)), copies = Set(actual.strokes.map(\.id))
            XCTAssertTrue(originals.isDisjoint(with: copies))
            XCTAssertEqual(copies.count, actual.strokes.count)
        }
        // Visible-page crop and the complete negative-Y region must both match native translation.
        for rect in [CGRect(x: 0, y: 0, width: 300, height: 150), CGRect(x: 0, y: -100, width: 300, height: 250)] {
            let expectedPixels = try pixels(expected, rect: rect), actualPixels = try pixels(actual, rect: rect)
            XCTAssertEqual(actualPixels.count, expectedPixels.count)
            let differences = zip(expectedPixels, actualPixels).map { abs(Int($0) - Int($1)) }
            XCTAssertLessThanOrEqual(Double(differences.reduce(0, +)) / Double(differences.count), 0.5)
            XCTAssertLessThanOrEqual(differences.max() ?? 0, 8)
        }
        XCTAssertEqual(try native(page), source)
    }

    func testNativeSelectionUsesInclusivePersistedRenderBoundsNotControlPointY() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke([45, 45], type: .marker)]))
        let source = try native(page), boundary = source.strokes[0].renderBounds.maxY
        XCTAssertGreaterThan(boundary, 45)
        let touching = try store.carryBelow(book: book, page: page, y: boundary)
        XCTAssertEqual(try native(touching).strokes.count, 1)
        XCTAssertLessThan(try native(touching).bounds.minY, 0)
        let beyond = try store.carryBelow(book: book, page: page, y: boundary + 1)
        XCTAssertTrue(try native(beyond).strokes.isEmpty)
        XCTAssertNil(saved(beyond).head)
    }

    func testCombinedRootCopiesCurrentObjectsWithFreshIDsRevisionOneAndUnchangedAssets() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke([80, 150])]))
        let receipt = try addObjects([20, 90, 140])
        var changed = scene(page)[1]
        let old = changed, request = UUID()
        changed.revision = 2
        changed.provenance.requestID = request
        _ = try store.applyAI(result(request, [AIObjectEdit(op: "replace", objectID: old.id, expectedRevision: old.revision,
            object: changed, expectedObject: old)]), assets: [:])
        let source = saved(page), originals = scene(page), snapshot = try native(page)
        let png = try store.assetData(originals[0].asset)
        let new = try store.carryBelow(book: book, page: page, y: 100)
        let copied = saved(new), objects = scene(new)
        XCTAssertEqual(copied.nodes.count, 1)
        XCTAssertNil(copied.nodes[0].parent)
        XCTAssertTrue(copied.nodes[0].children.isEmpty)
        XCTAssertEqual(copied.head, copied.preferredRoot)
        XCTAssertEqual(objects.count, 2)
        for (original, actual) in zip(originals.dropFirst(), objects) {
            XCTAssertNotEqual(actual.id, original.id)
            var expected = original
            expected.id = actual.id
            expected.revision = 1
            expected.frame.y -= 100
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(try store.assetData(actual.asset), png)
        }
        XCTAssertEqual(objects[0].frame.y, -10)
        XCTAssertEqual(Set(objects.map(\.id)).count, 2)
        XCTAssertEqual(try AIHash.encoded(saved(page)), try AIHash.encoded(source))
        XCTAssertEqual(try native(page), snapshot)
        XCTAssertEqual(store.appliedAIReceipt(requestID: receipt.requestID), receipt)
        XCTAssertEqual(try store.undo(book: book, page: new)?.strokes.count, 0)
        XCTAssertTrue(scene(new).isEmpty)
        XCTAssertNil(saved(new).head)
        XCTAssertEqual(try store.redo(book: book, page: new)?.strokes.count, 1)
        XCTAssertEqual(scene(new), objects)
        store = Store(directory: root)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(scene(new), objects)
        XCTAssertEqual(try AIHash.encoded(saved(page)), try AIHash.encoded(source))
        XCTAssertEqual(store.appliedAIReceipt(requestID: receipt.requestID), receipt)
    }

    func testAIOnlyCopyStagesRealBlankNativeArchiveAndCanUndoAfterReload() throws {
        try addObjects([90])
        let new = try store.carryBelow(book: book, page: page, y: 100)
        let copied = saved(new), head = try XCTUnwrap(copied.head)
        let bytes = try XCTUnwrap(store.exportPackage().blobs[SyncPackage.key(book, new, head)])
        XCTAssertTrue(try PKDrawing(data: bytes).strokes.isEmpty)
        XCTAssertEqual(scene(new)[0].frame.y, -10)
        store = Store(directory: root)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(try store.undo(book: book, page: new)?.strokes.count, 0)
        XCTAssertTrue(scene(new).isEmpty)
        XCTAssertEqual(try store.redo(book: book, page: new)?.strokes.count, 0)
        XCTAssertEqual(scene(new).count, 1)
    }

    func testInsertAfterSourceKeepsFollowingPagesPaperFoldersReceiptsAndHistoryRetention() throws {
        let group = try store.addFolder("School"), child = try store.addFolder("Math", in: group)
        try store.moveNotebook(book, into: child)
        let before = Page(), after = Page(), tail = Page(), deleted = Page()
        try store.update(book) { notebook in
            notebook.pages = [before, notebook.pages[0], after, tail]
            notebook.pages[1].background = 3
            notebook.pages[1].starred = true
            notebook.currentPage = after.id
            notebook.deleted = [deleted]
        }
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke([120, 160])]))
        try store.completeSuccessfulSync()
        try store.completeSuccessfulSync()
        let receipt = try addObjects([120])
        let index = root.appendingPathComponent("notebooks.json")
        let oldIndex = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! NSDictionary
        let original = saved(page), nextPages = [saved(after.id), saved(tail.id)]
        let new = try store.carryBelow(book: book, page: page, y: 100)
        let newIndex = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! NSDictionary
        XCTAssertEqual(store.notebook(book)!.pages.map(\.id), [before.id, page, new, after.id, tail.id])
        XCTAssertEqual(store.notebook(book)!.currentPage, new)
        XCTAssertEqual(store.notebook(book)!.orientation, "landscape")
        XCTAssertEqual(store.notebook(book)!.folderID, child)
        XCTAssertEqual(saved(new).background, 3)
        XCTAssertFalse(saved(new).starred)
        XCTAssertEqual(try AIHash.encoded(saved(page)), try AIHash.encoded(original))
        XCTAssertEqual(try AIHash.encoded([saved(after.id), saved(tail.id)]), try AIHash.encoded(nextPages))
        XCTAssertEqual(try AIHash.encoded(store.notebook(book)!.deleted), try AIHash.encoded([deleted]))
        XCTAssertEqual(newIndex["localHistory"] as? NSDictionary, oldIndex["localHistory"] as? NSDictionary)
        XCTAssertEqual(newIndex["appliedAIRequests"] as? NSDictionary, oldIndex["appliedAIRequests"] as? NSDictionary)
        XCTAssertEqual(store.folders.map(\.id), [group, child])
        XCTAssertEqual(store.appliedAIReceipt(requestID: receipt.requestID), receipt)
        XCTAssertEqual(try store.undo(book: book, page: new)?.strokes.count, 0)
        // Source's preexisting floor still stops undo after its newer AI-only entry.
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 1)
        XCTAssertNil(try store.undo(book: book, page: page))
    }

    func testEmptySelectionAndZeroCutAlwaysCreateNewPagesWithoutAnArbitraryExtentCap() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke([40, 50])]))
        let empty = try store.carryBelow(book: book, page: page, y: 100_000)
        XCTAssertNil(saved(empty).head)
        XCTAssertTrue(saved(empty).nodes.isEmpty)
        XCTAssertTrue(try native(empty).strokes.isEmpty)
        XCTAssertNil(try store.undo(book: book, page: empty))
        let all = try store.carryBelow(book: book, page: page, y: 0)
        XCTAssertEqual(try native(all).strokes.count, 1)
        let blank = try store.carryBelow(book: book, page: empty, y: 0)
        XCTAssertNil(saved(blank).head)
        XCTAssertEqual(store.notebook(book)!.currentPage, blank)
    }

    func testInvalidCutsMissingAndDeletedPagesDoNotPublish() throws {
        let index = root.appendingPathComponent("notebooks.json"), before = try Data(contentsOf: index)
        for cut: CGFloat in [-1, .nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try store.carryBelow(book: book, page: page, y: cut))
        }
        XCTAssertThrowsError(try store.carryBelow(book: UUID(), page: page, y: 0))
        XCTAssertThrowsError(try store.carryBelow(book: book, page: UUID(), y: 0))
        XCTAssertEqual(try Data(contentsOf: index), before)
        try store.update(book) { $0.deleted = [$0.pages.removeFirst()]; $0.pages = [Page()] }
        let deletedBefore = try Data(contentsOf: index)
        XCTAssertThrowsError(try store.carryBelow(book: book, page: page, y: 0))
        XCTAssertEqual(try Data(contentsOf: index), deletedBefore)
    }

    func testMissingNativeSnapshotOrUnreadableSelectedAssetDoesNotPublish() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke([100, 150])]))
        try addObjects([120])
        let index = root.appendingPathComponent("notebooks.json"), before = try Data(contentsOf: index)
        let asset = scene(page)[0].asset, assetFile = root.appendingPathComponent("assets/" + asset.sha256 + ".png")
        let assetBytes = try Data(contentsOf: assetFile)
        try FileManager.default.removeItem(at: assetFile)
        XCTAssertThrowsError(try store.carryBelow(book: book, page: page, y: 100))
        XCTAssertEqual(try Data(contentsOf: index), before)
        try Data("bad PNG".utf8).write(to: assetFile)
        XCTAssertThrowsError(try store.carryBelow(book: book, page: page, y: 100))
        XCTAssertEqual(try Data(contentsOf: index), before)
        try assetBytes.write(to: assetFile)
        let head = try XCTUnwrap(saved(page).head)
        try FileManager.default.removeItem(at: root.appendingPathComponent(SyncPackage.key(book, page, head) + ".pkdraw"))
        XCTAssertThrowsError(try store.carryBelow(book: book, page: page, y: 100))
        XCTAssertEqual(try Data(contentsOf: index), before)
        XCTAssertEqual(store.notebook(book)!.pages.count, 1)
    }

    func testIndexWriteFailureRollsBackCandidateAndOwnedStagedSnapshot() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke([80, 160])]))
        try addObjects([90])
        let before = try store.exportPackage().encoded(), books = try AIHash.encoded(store.notebooks)
        let filesBefore = snapshotFiles()
        let index = root.appendingPathComponent("notebooks.json"), backup = root.appendingPathComponent("saved-index.json")
        try FileManager.default.moveItem(at: index, to: backup)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.carryBelow(book: book, page: page, y: 100))
        XCTAssertEqual(try AIHash.encoded(store.notebooks), books)
        XCTAssertEqual(try store.exportPackage().encoded(), before)
        XCTAssertEqual(snapshotFiles(), filesBefore)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.moveItem(at: backup, to: index)
        store = Store(directory: root)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(try store.exportPackage().encoded(), before)
        _ = try store.carryBelow(book: book, page: page, y: 100)
        XCTAssertEqual(store.notebook(book)!.pages.count, 2)
    }

    func testSnapshotStagingFailureDoesNotPublishCandidate() throws {
        try addObjects([90])
        let index = root.appendingPathComponent("notebooks.json"), before = try Data(contentsOf: index)
        let directory = root.appendingPathComponent(book.uuidString)
        let filesBefore = snapshotFiles()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: directory.path), "Fixture host bypasses directory permissions")
        // Source archive remains readable, but staging a new page directory must fail.
        XCTAssertTrue(try native(page).strokes.isEmpty)
        XCTAssertThrowsError(try store.carryBelow(book: book, page: page, y: 100))
        XCTAssertEqual(store.notebook(book)!.pages.count, 1)
        XCTAssertEqual(try Data(contentsOf: index), before)
        XCTAssertEqual(snapshotFiles(), filesBefore)
    }

    func testOnlyCurrentHeadIsCopiedNotUndoneInkOrObjects() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke([120, 160])]))
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke([20, 40])]))
        try addObjects([140])
        _ = try store.undo(book: book, page: page)
        let current = saved(page)
        let new = try store.carryBelow(book: book, page: page, y: 100)
        XCTAssertNil(saved(new).head)
        XCTAssertTrue(try native(new).strokes.isEmpty)
        XCTAssertTrue(scene(new).isEmpty)
        XCTAssertEqual(try AIHash.encoded(saved(page)), try AIHash.encoded(current))
        _ = try store.redo(book: book, page: page)
        XCTAssertEqual(scene(page).count, 1)
    }

    private func snapshotFiles() -> Set<String> {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        return Set(files.compactMap { ($0 as? URL).flatMap(Store.nativeSnapshotKey) })
    }
}
