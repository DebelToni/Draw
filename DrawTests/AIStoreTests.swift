import XCTest
import UIKit
import PencilKit
@testable import Draw

@MainActor
final class AIStoreTests: XCTestCase {
    private var root: URL!
    private var store: Store!
    private var book: UUID!
    private var page: UUID!
    private let contextHash = String(repeating: "a", count: 64)
    private let previewHash = String(repeating: "b", count: 64)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = Store(directory: root)
        book = try store.addNotebook("AI fixture")
        page = store.notebook(book)!.pages[0].id
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func ink(_ x: CGFloat, color: UIColor = .black, seed: UInt32 = 9) -> PKStroke {
        let point = PKStrokePoint(location: CGPoint(x: x, y: 50), timeOffset: 0,
            size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        return PKStroke(ink: PKInk(.monoline, color: color), path: PKStrokePath(controlPoints: [point],
            creationDate: Date(timeIntervalSince1970: 1_700_000_000)), randomSeed: seed)
    }

    private func object(request: UUID, id: UUID = UUID(), revision: Int = 1) throws -> (AIObject, Data) {
        let format = AICapture.rendererFormat()
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 10, height: 5), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 5))
        }.pngData())
        let asset = AIAsset(sha256: AIHash.digest(png), pixelWidth: 20, pixelHeight: 10)
        return (AIObject(id: id, revision: revision, kind: "text", source: "Answer", frame: AIFrame(x: 40, y: 40, width: 10, height: 5),
            style: AIStyle(), asset: asset, provenance: AIProvenance(requestID: request,
                contextSHA256: contextHash, rendererSignature: "draw-ai-render-v1")), png)
    }

    private func result(request: UUID, edits: [AIPageEdit], inserts: [AIInsertPage] = []) -> AIResult {
        AIResult(requestID: request, documentID: book, contextSHA256: contextHash, draftVersion: 1,
            rendererSignature: "draw-ai-render-v1", insertPages: inserts, pageEdits: edits,
            previewSHA256s: Dictionary(uniqueKeysWithValues: edits.map { ($0.pageID.uuidString, previewHash) }))
    }

    private func addAnswer(strokeEdits: [AIStrokeEdit] = []) throws -> (AIResult, AIApplyReceipt, AIObject) {
        let request = UUID()
        let (object, bytes) = try object(request: request)
        let result = result(request: request, edits: [AIPageEdit(pageID: page,
            objectEdits: [AIObjectEdit(op: "add", object: object)], strokeEdits: strokeEdits)])
        let receipt = try store.applyAI(result, assets: [object.asset.sha256: bytes])
        return (result, receipt, object)
    }

    private func scene() -> [AIObject] { store.objects(book: book, page: store.notebook(book)!.pages.first { $0.id == page }!) }
    private func native() throws -> PKDrawing { try store.drawing(book: book, page: store.notebook(book)!.pages.first { $0.id == page }!) }

    private func assertNativeAttributes(_ expected: PortableStroke, _ actual: PortableStroke,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.id, expected.id, "Stroke ID", file: file, line: line)
        XCTAssertEqual(actual.pathID, expected.pathID, "Path ID", file: file, line: line)
        XCTAssertEqual(actual.renderGroupID, expected.renderGroupID, "Render-group ID", file: file, line: line)
        XCTAssertEqual(actual.inkType, expected.inkType, "Ink type", file: file, line: line)
        XCTAssertEqual(actual.color, expected.color, "Canonical sRGB color", file: file, line: line)
        XCTAssertEqual(actual.transform, expected.transform, "Transform", file: file, line: line)
        XCTAssertEqual(actual.randomSeed, expected.randomSeed, "Random seed", file: file, line: line)
        XCTAssertEqual(actual.grainOffset, expected.grainOffset, "Grain offset", file: file, line: line)
        XCTAssertEqual(actual.creationDate, expected.creationDate, "Creation date", file: file, line: line)
        XCTAssertEqual(actual.points, expected.points, "All twelve native control fields", file: file, line: line)
        XCTAssertEqual(actual.mask, expected.mask, "Complete mask", file: file, line: line)
    }

    private func highlight(request: UUID, fontSize: Double = 18) throws -> (AIObject, Data) {
        let size = CGSize(width: 120, height: 30)
        let image = UIGraphicsImageRenderer(size: size, format: AICapture.rendererFormat()).image { context in
            UIColor(red: 0, green: 184.0 / 255, blue: 217.0 / 255, alpha: 0.2).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let bytes = try AICapture.png(image)
        let asset = AIAsset(sha256: AIHash.digest(bytes), pixelWidth: 240, pixelHeight: 60)
        return (AIObject(id: UUID(), revision: 1, kind: "highlight", source: "{\"opacity\":0.2}",
            frame: AIFrame(x: 20, y: 40, width: 120, height: 30),
            style: AIStyle(fontSize: fontSize, color: "#00B8D9", lineWidth: 1), asset: asset,
            provenance: AIProvenance(requestID: request, contextSHA256: contextHash,
                rendererSignature: "draw-ai-render-v1")), bytes)
    }

    func testHighlightApplyUndoRedoReopenPreservesCombinedHistoryOriginalInkAndAsset() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(80)]))
        let original = try native(), originalHead = store.notebook(book)!.pages[0].head
        let request = UUID(), (object, bytes) = try highlight(request: request)
        let answer = result(request: request, edits: [AIPageEdit(pageID: page,
            objectEdits: [AIObjectEdit(op: "add", object: object)], strokeEdits: [])])
        let receipt = try store.applyAI(answer, assets: [object.asset.sha256: bytes])
        XCTAssertEqual(scene(), [object])
        XCTAssertEqual(try native(), original)
        XCTAssertEqual(try store.assetData(object.asset), bytes)
        XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, 2)
        XCTAssertEqual(store.notebook(book)!.pages[0].nodes.last?.parent, originalHead)
        XCTAssertEqual(object.style.fontSize, 18)
        XCTAssertEqual(AIStyle().fontSize, 18)
        _ = try store.undo(book: book, page: page)
        XCTAssertTrue(scene().isEmpty)
        XCTAssertEqual(store.notebook(book)!.pages[0].head, originalHead)
        XCTAssertEqual(try native(), original)
        store = Store(directory: root)
        XCTAssertNil(store.loadError)
        _ = try store.redo(book: book, page: page)
        XCTAssertEqual(scene(), [object])
        XCTAssertEqual(try native(), original)
        XCTAssertEqual(try store.assetData(object.asset), bytes)
        XCTAssertEqual(try store.applyAI(answer, assets: [:]), receipt)
        XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, 2)
    }

    func testHighlightCurrentSourceRoundtripsFormatsTwoAndThreeWithFourteenPointStyle() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(80)]))
        let request = UUID(), (object, bytes) = try highlight(request: request, fontSize: 14)
        _ = try store.applyAI(result(request: request, edits: [AIPageEdit(pageID: page,
            objectEdits: [AIObjectEdit(op: "add", object: object)], strokeEdits: [])]),
            assets: [object.asset.sha256: bytes])
        for format in [2, 3] {
            if format == 3 {
                let parent = try store.addFolder("Semester"), child = try store.addFolder("Math", in: parent)
                try store.moveNotebook(book, into: child)
            }
            let source = try store.exportCurrentPackage()
            XCTAssertEqual(source.format, format)
            XCTAssertEqual(source.notebooks[0].pages[0].nodes.count, 1)
            try source.validate()
            let encoded = try source.encoded()
            let decoded = try JSONDecoder().decode(SyncPackage.self, from: encoded)
            try decoded.validate()
            let receiver = Store(directory: root.appendingPathComponent("receiver-\(format)"))
            try receiver.importPackage(decoded)
            XCTAssertEqual(try receiver.exportCurrentPackage().encoded(), encoded)
            XCTAssertEqual(receiver.objects(book: book, page: receiver.notebook(book)!.pages[0]), [object])
            XCTAssertEqual(try receiver.assetData(object.asset), bytes)
            XCTAssertEqual(object.style.fontSize, 14)
            var unknown = source
            unknown.notebooks[0].pages[0].nodes[0].objects![0].kind = "future-highlight"
            XCTAssertThrowsError(try unknown.validate())
            XCTAssertThrowsError(try receiver.importPackage(unknown))
            XCTAssertEqual(try receiver.exportCurrentPackage().encoded(), encoded)
            if format == 3 {
                var flattened = source
                flattened.format = 2
                XCTAssertThrowsError(try flattened.validate())
            }
        }
    }

    func testHighlightCarryPreservesCrossingGeometryAssetAndSourceInkAcrossUndoReopen() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(80)]))
        let request = UUID(), (object, bytes) = try highlight(request: request)
        _ = try store.applyAI(result(request: request, edits: [AIPageEdit(pageID: page,
            objectEdits: [AIObjectEdit(op: "add", object: object)], strokeEdits: [])]),
            assets: [object.asset.sha256: bytes])
        let original = try native(), source = try AIHash.encoded(store.notebook(book)!.pages[0])
        let copiedPage = try store.carryBelow(book: book, page: page, y: 50)
        func copied() -> [AIObject] {
            store.objects(book: book, page: store.notebook(book)!.pages.first { $0.id == copiedPage }!)
        }
        let copy = try XCTUnwrap(copied().first)
        XCTAssertNotEqual(copy.id, object.id)
        var expected = object
        expected.id = copy.id
        expected.frame.y = -10
        XCTAssertEqual(copy, expected)
        try copy.validate()
        XCTAssertEqual(try store.assetData(copy.asset), bytes)
        XCTAssertEqual(try native(), original)
        XCTAssertEqual(try AIHash.encoded(store.notebook(book)!.pages[0]), source)
        _ = try store.undo(book: book, page: copiedPage)
        XCTAssertTrue(copied().isEmpty)
        store = Store(directory: root)
        XCTAssertNil(store.loadError)
        _ = try store.redo(book: book, page: copiedPage)
        XCTAssertEqual(copied(), [copy])
        XCTAssertEqual(try store.assetData(copy.asset), bytes)
        XCTAssertEqual(scene(), [object])
        XCTAssertEqual(try native(), original)
        try store.exportCurrentPackage().validate()
    }

    func testHighlightResolvedValidationDoesNotParseGeometryAndRejectsUnknownKindStyleAndAssets() throws {
        let request = UUID(), (object, bytes) = try highlight(request: request)
        try object.validate()
        var historical = object
        historical.source = "Historical metadata"
        try historical.validate() // The native renderer uses the verified PNG, never source JSON.
        var invalid = object
        invalid.kind = "future-highlight"
        XCTAssertThrowsError(try invalid.validate())
        invalid = object
        invalid.style.color = "#00B8D933"
        XCTAssertThrowsError(try invalid.validate())
        invalid = object
        invalid.frame.height += 0.5
        XCTAssertThrowsError(try invalid.validate())
        let answer = result(request: request, edits: [AIPageEdit(pageID: page,
            objectEdits: [AIObjectEdit(op: "add", object: object)], strokeEdits: [])])
        let before = try store.exportCurrentPackage().encoded()
        XCTAssertThrowsError(try store.applyAI(answer, assets: [:]))
        XCTAssertThrowsError(try store.applyAI(answer, assets: [object.asset.sha256: Data("bad".utf8)]))
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), before)
        XCTAssertNil(store.appliedAIReceipt(requestID: request))
        try AIAssets.validate(data: bytes, asset: object.asset)
    }

    func testObjectOnlyUndoRedoAndDrawingCommitsShareCombinedHistory() throws {
        let (_, _, answer) = try addAnswer()
        XCTAssertEqual(scene(), [answer])
        XCTAssertEqual(try native().strokes.count, 0)
        XCTAssertNotNil(store.notebook(book)!.pages[0].head)
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 0)
        XCTAssertTrue(scene().isEmpty)
        XCTAssertEqual(try store.redo(book: book, page: page)?.strokes.count, 0)
        XCTAssertEqual(scene(), [answer])
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(80)]))
        XCTAssertEqual(scene(), [answer])
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 0)
        XCTAssertEqual(scene(), [answer])
        XCTAssertEqual(try store.undo(book: book, page: page)?.strokes.count, 0)
        XCTAssertTrue(scene().isEmpty)
        store = Store(directory: root)
        XCTAssertNil(store.loadError)
        _ = try store.redo(book: book, page: page)
        _ = try store.redo(book: book, page: page)
        XCTAssertEqual(scene(), [answer])
        XCTAssertEqual(try native().strokes.count, 1)
    }

    func testReceiptSurvivesUndoRestartAndDoesNotReinsertAnswer() throws {
        let (result, receipt, _) = try addAnswer()
        _ = try store.undo(book: book, page: page)
        store = Store(directory: root)
        XCTAssertTrue(scene().isEmpty)
        XCTAssertEqual(try store.applyAI(result, assets: [:]), receipt)
        XCTAssertNil(store.notebook(book)!.pages[0].head)
        XCTAssertEqual(store.appliedAIReceipt(requestID: result.requestID), receipt)
        var changed = result
        changed.draftVersion += 1
        XCTAssertThrowsError(try store.applyAI(changed, assets: [:]))
        XCTAssertTrue(scene().isEmpty)
    }

    func testExactApprovedBytesDigestAndMutationProtection() throws {
        let request = UUID()
        let (object, bytes) = try object(request: request)
        let value = result(request: request, edits: [AIPageEdit(pageID: page,
            objectEdits: [AIObjectEdit(op: "add", object: object)], strokeEdits: [])])
        let encoded = try JSONEncoder().encode(value)
        let exact = Data("  ".utf8) + encoded + Data("\n".utf8)
        var approved = try AIResult.approved(data: exact)
        let receipt = try store.applyAI(approved, assets: [object.asset.sha256: bytes])
        XCTAssertEqual(receipt.resultSHA256, AIHash.digest(exact))
        XCTAssertNotEqual(receipt.resultSHA256, try value.digest())
        XCTAssertEqual(try store.applyAI(try AIResult.approved(data: exact), assets: [:]), receipt)
        approved.draftVersion = 2
        XCTAssertThrowsError(try approved.digest())
    }

    func testMultiPageApplyPreservesCurrentPageAndAtomicReceipt() throws {
        try store.update(book) { $0.currentPage = page }
        let request = UUID(), newPage = UUID()
        let (one, bytes) = try object(request: request)
        let (two, _) = try object(request: request)
        let answer = result(request: request, edits: [
            AIPageEdit(pageID: page, objectEdits: [AIObjectEdit(op: "add", object: one)], strokeEdits: []),
            AIPageEdit(pageID: newPage, objectEdits: [AIObjectEdit(op: "add", object: two)], strokeEdits: [])
        ], inserts: [AIInsertPage(pageID: newPage, afterPageID: page, background: 2, width: 1024, height: 1361)])
        let receipt = try store.applyAI(answer, assets: [one.asset.sha256: bytes])
        XCTAssertEqual(store.notebook(book)!.pages.map(\.id), [page, newPage])
        XCTAssertEqual(store.notebook(book)!.currentPage, page)
        _ = try store.undo(book: book, page: page)
        XCTAssertTrue(scene().isEmpty)
        XCTAssertEqual(store.objects(book: book, page: store.notebook(book)!.pages[1]), [two])
        store = Store(directory: root)
        XCTAssertEqual(try store.applyAI(answer, assets: [:]), receipt)
        XCTAssertEqual(store.notebook(book)!.pages.count, 2)
    }

    func testIndexFailureCannotCommitAnyPageOrReceipt() throws {
        let request = UUID(), newPage = UUID()
        let (one, bytes) = try object(request: request)
        let (two, _) = try object(request: request)
        let answer = result(request: request, edits: [
            AIPageEdit(pageID: page, objectEdits: [AIObjectEdit(op: "add", object: one)], strokeEdits: []),
            AIPageEdit(pageID: newPage, objectEdits: [AIObjectEdit(op: "add", object: two)], strokeEdits: [])
        ], inserts: [AIInsertPage(pageID: newPage, afterPageID: page, background: 0, width: 1024, height: 1361)])
        let before = try store.exportCurrentPackage().encoded()
        let index = root.appendingPathComponent("notebooks.json"), backup = root.appendingPathComponent("saved-index.json")
        try FileManager.default.moveItem(at: index, to: backup)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.applyAI(answer, assets: [one.asset.sha256: bytes]))
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), before)
        XCTAssertNil(store.appliedAIReceipt(requestID: request))
        try FileManager.default.removeItem(at: index)
        try FileManager.default.moveItem(at: backup, to: index)
        store = Store(directory: root)
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), before)
        _ = try store.applyAI(answer, assets: [one.asset.sha256: bytes])
        XCTAssertEqual(store.notebook(book)!.pages.count, 2)
    }

    func testMissingDeletedDestinationAndBadAssetsLeaveWholeAnswerUntouched() throws {
        let request = UUID(), absent = UUID()
        let (object, bytes) = try object(request: request)
        var answer = result(request: request, edits: [AIPageEdit(pageID: absent,
            objectEdits: [AIObjectEdit(op: "add", object: object)], strokeEdits: [])])
        let before = try store.exportCurrentPackage().encoded()
        XCTAssertThrowsError(try store.applyAI(answer, assets: [object.asset.sha256: bytes]))
        answer.pageEdits[0].pageID = page
        answer.previewSHA256s = [page.uuidString: previewHash]
        XCTAssertThrowsError(try store.applyAI(answer, assets: [:]))
        XCTAssertThrowsError(try store.applyAI(answer, assets: [object.asset.sha256: Data("bad".utf8)]))
        var bad = object
        bad.asset.pixelWidth = 21
        answer.pageEdits[0].objectEdits[0].object = bad
        XCTAssertThrowsError(try store.applyAI(answer, assets: [object.asset.sha256: bytes]))
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), before)
        XCTAssertNil(store.appliedAIReceipt(requestID: request))
        try store.update(book) { $0.deleted.append($0.pages.removeFirst()); $0.pages = [Page()] }
        answer.pageEdits[0].objectEdits[0].object = object
        let deletedBefore = try store.exportCurrentPackage().encoded()
        XCTAssertThrowsError(try store.applyAI(answer, assets: [object.asset.sha256: bytes]))
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), deletedBefore)
    }

    func testScopedRemovalPreservesInkWrittenAfterCapture() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(40)]))
        let captured = try PortableStroke(native().strokes[0], includeSamples: false)
        let later = ink(100)
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: try native().strokes + [later]))
        let committed = try native()
        let unchangedTarget = try PortableStroke(committed.strokes[0], includeSamples: false)
        let expectedLater = try PortableStroke(committed.strokes[1], includeSamples: false)
        XCTAssertEqual(try unchangedTarget.fingerprint(), try captured.fingerprint())
        assertNativeAttributes(captured, unchangedTarget)
        let (_, receipt, _) = try addAnswer(strokeEdits: [AIStrokeEdit(id: captured.targetID,
            fingerprint: captured.fingerprint(), op: "remove")])
        XCTAssertTrue(receipt.skippedStrokeTargets.isEmpty)
        XCTAssertEqual(try native().strokes.count, 1)
        // Compare with the authoritative committed state, not unarchived constructor
        // inputs which PencilKit legitimately quantizes on the first save.
        let remaining = try PortableStroke(native().strokes[0], includeSamples: false)
        assertNativeAttributes(expectedLater, remaining)
        XCTAssertEqual(try remaining.fingerprint(), try expectedLater.fingerprint())
        _ = try store.undo(book: book, page: page)
        XCTAssertEqual(try native().strokes.count, 2)
        XCTAssertTrue(scene().isEmpty)
    }

    func testCapturedUnchangedTargetFingerprintSurvivesRecommitsAndPreservesNewNativeAttributes() throws {
        let controls = (0..<3).map { i in
            PKStrokePoint(location: CGPoint(x: 25.125 + Double(i) * 21.75, y: 32.625 + Double(i) * 13.125),
                timeOffset: Double(i) * 0.123456, size: CGSize(width: 4.12345, height: 5.23456),
                opacity: 1.5, force: 0.723456, azimuth: 0.321456, altitude: 1.234567,
                secondaryScale: 0.87654, threshold: 0.23456)
        }
        let color = UIColor(red: 0.173456, green: 0.314567, blue: 0.635678, alpha: 0.734567)
        let target = PKStroke(ink: PKInk(.monoline, color: color), path: PKStrokePath(controlPoints: controls,
                creationDate: Date(timeIntervalSince1970: 1_700_000_000.123456)),
            transform: CGAffineTransform(a: 0.97, b: 0.11, c: -0.09, d: 1.03, tx: 3.125, ty: 8.75),
            mask: UIBezierPath(rect: CGRect(x: 15.23, y: 20.34, width: 90.45, height: 100.56)), randomSeed: 0xBEEF)
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [target]))
        let captured = try store.capturedAIContext(book: book, focusPage: page, pageSize: CGSize(width: 240, height: 180))
        let capturedTarget = try XCTUnwrap(captured.context.pages[0].strokeTargets.first)
        let original = try PortableStroke(native().strokes[0], includeSamples: false)
        XCTAssertEqual(capturedTarget.fingerprint, try original.fingerprint())
        for i in 0..<3 {
            let fresh = PKStroke(ink: PKInk(.pen, color: color),
                path: PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSince1970: 1_700_000_100.123456 + Double(i))),
                transform: CGAffineTransform(translationX: CGFloat(100 + i * 10), y: CGFloat(i) * 3.125),
                randomSeed: UInt32(200 + i))
            try store.commit(book: book, page: page, drawing: PKDrawing(strokes: try native().strokes + [fresh]))
            let unchanged = try PortableStroke(native().strokes[0], includeSamples: false)
            XCTAssertEqual(try unchanged.fingerprint(), capturedTarget.fingerprint, "Recommit \(i)")
            assertNativeAttributes(original, unchanged)
        }
        let expectedLater = try native().strokes.dropFirst().map { try PortableStroke($0, includeSamples: false) }
        let (_, receipt, _) = try addAnswer(strokeEdits: [AIStrokeEdit(id: capturedTarget.id,
            fingerprint: capturedTarget.fingerprint, op: "remove")])
        XCTAssertTrue(receipt.skippedStrokeTargets.isEmpty)
        let remaining = try native().strokes.map { try PortableStroke($0, includeSamples: false) }
        XCTAssertEqual(remaining.count, expectedLater.count)
        for (expected, actual) in zip(expectedLater, remaining) {
            assertNativeAttributes(expected, actual)
            XCTAssertEqual(try actual.fingerprint(), try expected.fingerprint())
        }
    }

    func testAmbiguousMatchingLogicRejectsDuplicatesWithoutNativeArchiveDependency() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(40)]))
        var first = try PortableStroke(native().strokes[0], includeSamples: false)
        first.id = UUID()
        let edit = AIStrokeEdit(id: first.targetID, fingerprint: try first.fingerprint(), op: "remove")
        XCTAssertEqual(try AIStrokeMatching.index(for: edit, in: [first]), 0)
        XCTAssertNil(try AIStrokeMatching.index(for: edit, in: [first, first]))
        var different = first
        different.transform[4] += 10
        // One matching fingerprint still does not disambiguate a duplicated identity.
        XCTAssertNil(try AIStrokeMatching.index(for: edit, in: [first, different]))
        XCTAssertNil(try AIStrokeMatching.index(for: edit, in: [different]))
        first.id = nil
        let fallback = AIStrokeEdit(id: first.targetID, fingerprint: try first.fingerprint(), op: "remove")
        XCTAssertEqual(try AIStrokeMatching.index(for: fallback, in: [first]), 0)
        XCTAssertNil(try AIStrokeMatching.index(for: fallback, in: [first, first]))
    }

    func testModifiedOrDeletedStrokeIsSkippedWithoutLosingLaterInk() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(40)]))
        let captured = try PortableStroke(native().strokes[0], includeSamples: false)
        // A target removed by the user is never resurrected; later ink survives.
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(140)]))
        let (_, receipt, _) = try addAnswer(strokeEdits: [AIStrokeEdit(id: captured.targetID,
            fingerprint: captured.fingerprint(), op: "recolor", color: "#32ADE6")])
        XCTAssertEqual(receipt.skippedStrokeTargets, [captured.targetID])
        XCTAssertEqual(try native().strokes.count, 1)
        XCTAssertEqual(try native().strokes[0].path[0].location.x, 140, accuracy: 0.01)
    }

    func testUnchangedIdentityWithChangedTransformSkipsCapturedFingerprint() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Stable public stroke IDs require iOS 27") }
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(40)]))
        let original = try native().strokes[0]
        let captured = try PortableStroke(original, includeSamples: false)
        let changed = PKStroke(ink: original.ink, path: original.path,
            transform: CGAffineTransform(translationX: 25, y: 10), mask: original.mask,
            randomSeed: original.randomSeed, id: original.id, renderGroupID: original.renderGroupID,
            renderState: original.renderState)
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [changed, ink(150)]))
        let (_, receipt, _) = try addAnswer(strokeEdits: [AIStrokeEdit(id: captured.targetID,
            fingerprint: captured.fingerprint(), op: "remove")])
        XCTAssertEqual(receipt.skippedStrokeTargets, [captured.targetID])
        XCTAssertEqual(try native().strokes.count, 2)
        XCTAssertEqual(try native().strokes[0].transform, changed.transform)
    }

    func testAmbiguousNativeStrokeIdentitySkipsBothTargets() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Public stroke identities require iOS 27") }
        let first = ink(40)
        let second = PKStroke(ink: first.ink, path: first.path,
            transform: CGAffineTransform(translationX: 20, y: 0), randomSeed: first.randomSeed,
            id: first.id, renderGroupID: first.renderGroupID, renderState: first.renderState)
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [first, second]))
        let current = try native().strokes
        let target = try PortableStroke(current[0], includeSamples: false)
        // Some future native archive versions may repair duplicate identities themselves.
        guard current.count == 2, current[0].id == current[1].id else {
            throw XCTSkip("Native archive normalized duplicate stroke identities")
        }
        let (_, receipt, _) = try addAnswer(strokeEdits: [AIStrokeEdit(id: target.targetID,
            fingerprint: target.fingerprint(), op: "remove")])
        XCTAssertEqual(receipt.skippedStrokeTargets, [target.targetID])
        XCTAssertEqual(try native().strokes.count, 2)
    }

    func testRequestedNativeIDMatchingKeepsFingerprintAndMissingTargetSemantics() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(40), ink(80), ink(120)]))
        let drawing = try native()
        let target = try PortableStroke(drawing.strokes[1], includeSamples: false)
        let valid = AIStrokeEdit(id: target.targetID, fingerprint: try target.fingerprint(), op: "recolor", color: "#32ADE6")
        let missing = AIStrokeEdit(id: UUID().uuidString, fingerprint: String(repeating: "a", count: 64), op: "remove")
        XCTAssertEqual(try AIStrokeMatching.matchingIndices(edits: [], drawing: drawing), [:])
        XCTAssertEqual(try AIStrokeMatching.matchingIndices(edits: [valid, missing], drawing: drawing), [valid.id: 1])
        var changed = valid; changed.fingerprint = String(repeating: "b", count: 64)
        XCTAssertEqual(try AIStrokeMatching.matchingIndices(edits: [changed], drawing: drawing), [:])
    }

    func testRecolorPreservesControlsTransformMaskSeedAndOtherStroke() throws {
        let mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let original = ink(40, color: QuestionInk.color)
        let target = PKStroke(ink: original.ink, path: original.path,
            transform: CGAffineTransform(translationX: 8, y: 5), mask: mask, randomSeed: 127)
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [target, ink(150)]))
        let before = try native().strokes.map { try PortableStroke($0) }
        let (_, receipt, _) = try addAnswer(strokeEdits: [AIStrokeEdit(id: before[0].targetID,
            fingerprint: before[0].fingerprint(), op: "recolor", color: "#32ADE6")])
        XCTAssertTrue(receipt.skippedStrokeTargets.isEmpty)
        let after = try native().strokes.map { try PortableStroke($0) }
        XCTAssertEqual(after[0].points, before[0].points)
        XCTAssertEqual(after[0].transform, before[0].transform)
        XCTAssertEqual(after[0].mask, before[0].mask)
        XCTAssertEqual(after[0].randomSeed, before[0].randomSeed)
        XCTAssertEqual(try after[1].fingerprint(), try before[1].fingerprint())
        XCTAssertNotEqual(try after[0].fingerprint(), try before[0].fingerprint())
    }

    func testObjectRevisionMismatchRetainsNewerObjectAndUnrelatedScene() throws {
        let (_, _, original) = try addAnswer()
        let request = UUID()
        let (replacement, bytes) = try object(request: request, id: original.id, revision: 2)
        let update = result(request: request, edits: [AIPageEdit(pageID: page,
            objectEdits: [AIObjectEdit(op: "replace", objectID: original.id, expectedRevision: 1, object: replacement, expectedObject: original)], strokeEdits: [])])
        _ = try store.applyAI(update, assets: [replacement.asset.sha256: bytes])
        let next = UUID()
        let (extra, _) = try object(request: next)
        let stale = result(request: next, edits: [AIPageEdit(pageID: page,
            objectEdits: [AIObjectEdit(op: "remove", objectID: original.id, expectedRevision: 1, expectedObject: original),
                AIObjectEdit(op: "add", object: extra)], strokeEdits: [])])
        let receipt = try store.applyAI(stale, assets: [extra.asset.sha256: bytes])
        XCTAssertEqual(receipt.skippedObjectTargets, [original.id])
        XCTAssertEqual(scene(), [replacement, extra])
        _ = try store.undo(book: book, page: page)
        XCTAssertEqual(scene(), [replacement])
    }

    func testDelayedObjectEditsCannotOverwriteDivergentSameRevisionAfterUndo() throws {
        let (_, _, original) = try addAnswer()
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(40)]))
        let firstRequest = UUID()
        var (branchA, bytes) = try object(request: firstRequest, id: original.id, revision: 2)
        branchA.source = "Branch A"
        let first = result(request: firstRequest, edits: [AIPageEdit(pageID: page, objectEdits: [
            AIObjectEdit(op: "replace", objectID: original.id, expectedRevision: 1, object: branchA, expectedObject: original)
        ], strokeEdits: [])])
        _ = try store.applyAI(first, assets: [branchA.asset.sha256: bytes])
        let captured = try store.capturedAIContext(book: book, focusPage: page, pageSize: CGSize(width: 240, height: 180))
        let expected = try XCTUnwrap(captured.context.pages[0].objects.first)
        XCTAssertEqual(expected, branchA)
        _ = try store.undo(book: book, page: page)
        XCTAssertEqual(scene(), [original])

        let secondRequest = UUID()
        var (branchB, _) = try object(request: secondRequest, id: original.id, revision: 2)
        branchB.source = "Branch B"
        let second = result(request: secondRequest, edits: [AIPageEdit(pageID: page, objectEdits: [
            AIObjectEdit(op: "replace", objectID: original.id, expectedRevision: 1, object: branchB, expectedObject: original)
        ], strokeEdits: [])])
        _ = try store.applyAI(second, assets: [branchB.asset.sha256: bytes])
        let (_, _, unrelated) = try addAnswer()
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: try native().strokes + [ink(140)]))
        let preservedInk = try native().strokes.map { try PortableStroke($0, includeSamples: false) }
        XCTAssertEqual(branchB.id, expected.id)
        XCTAssertEqual(branchB.revision, expected.revision)
        XCTAssertNotEqual(branchB, expected)
        var preservedObjects = [branchB, unrelated]
        for op in ["replace", "remove"] {
            let delayedRequest = UUID()
            let (replacement, _) = try object(request: delayedRequest, id: original.id, revision: 3)
            let (answer, _) = try object(request: delayedRequest)
            let delayed = result(request: delayedRequest, edits: [AIPageEdit(pageID: page, objectEdits: [
                AIObjectEdit(op: op, objectID: original.id, expectedRevision: 2,
                    object: op == "replace" ? replacement : nil, expectedObject: expected),
                AIObjectEdit(op: "add", object: answer)
            ], strokeEdits: [])])
            let receipt = try store.applyAI(delayed, assets: [answer.asset.sha256: bytes])
            XCTAssertEqual(receipt.skippedObjectTargets, [original.id])
            preservedObjects.append(answer)
            XCTAssertEqual(scene(), preservedObjects)
            let remaining = try native().strokes.map { try PortableStroke($0, includeSamples: false) }
            XCTAssertEqual(remaining.count, preservedInk.count)
            for (before, after) in zip(preservedInk, remaining) { assertNativeAttributes(before, after) }
        }
        store = Store(directory: root)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(scene(), preservedObjects)
        _ = try store.undo(book: book, page: page)
        XCTAssertEqual(scene(), Array(preservedObjects.dropLast()))
        _ = try store.redo(book: book, page: page)
        XCTAssertEqual(scene(), preservedObjects)
    }

    func testObjectEditsRequireValidCapturedDescriptorWithoutDownloadingOldAsset() throws {
        let (_, _, original) = try addAnswer()
        let request = UUID()
        let (replacement, bytes) = try object(request: request, id: original.id, revision: 2)
        let (answer, _) = try object(request: request)
        let before = try store.exportCurrentPackage().encoded()
        var invalid: [AIObjectEdit] = [
            AIObjectEdit(op: "replace", objectID: original.id, expectedRevision: 1, object: replacement),
            AIObjectEdit(op: "remove", objectID: original.id, expectedRevision: 1)
        ]
        var wrong = original
        wrong.id = UUID()
        invalid.append(AIObjectEdit(op: "remove", objectID: original.id, expectedRevision: 1, expectedObject: wrong))
        wrong = original; wrong.revision = 2
        invalid.append(AIObjectEdit(op: "remove", objectID: original.id, expectedRevision: 1, expectedObject: wrong))
        wrong = original; wrong.style.color = "invalid"
        invalid.append(AIObjectEdit(op: "remove", objectID: original.id, expectedRevision: 1, expectedObject: wrong))
        let (freshAdd, _) = try object(request: request)
        invalid.append(AIObjectEdit(op: "add", object: freshAdd, expectedObject: original))
        for operation in invalid {
            let malformed = result(request: request, edits: [AIPageEdit(pageID: page,
                objectEdits: [operation, AIObjectEdit(op: "add", object: answer)], strokeEdits: [])])
            XCTAssertThrowsError(try store.applyAI(malformed, assets: [answer.asset.sha256: bytes]))
            XCTAssertEqual(try store.exportCurrentPackage().encoded(), before)
            XCTAssertNil(store.appliedAIReceipt(requestID: request))
        }

        // Valid captured metadata from an obsolete scene is enough to identify a
        // mismatch. Do not demand that its no-longer-needed PNG is downloaded.
        var old = original
        old.asset.sha256 = String(repeating: "c", count: 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("assets/" + old.asset.sha256 + ".png").path))
        let stale = result(request: request, edits: [AIPageEdit(pageID: page, objectEdits: [
            AIObjectEdit(op: "remove", objectID: original.id, expectedRevision: 1, expectedObject: old),
            AIObjectEdit(op: "add", object: answer)
        ], strokeEdits: [])])
        let receipt = try store.applyAI(stale, assets: [answer.asset.sha256: bytes])
        XCTAssertEqual(receipt.skippedObjectTargets, [original.id])
        XCTAssertEqual(scene(), [original, answer])
    }

    func testCurrentFormatTwoRoundTripAndUndoOnlyAssetsStayLocal() throws {
        let (answer, receipt, object) = try addAnswer()
        let current = try store.exportCurrentPackage()
        XCTAssertEqual(current.format, 2)
        XCTAssertEqual(current.assets?.keys.sorted(), [object.asset.sha256])
        let receiver = Store(directory: root.appendingPathComponent("receiver"))
        try receiver.importPackage(current)
        XCTAssertEqual(try receiver.exportCurrentPackage().encoded(), try current.encoded())
        XCTAssertNil(receiver.appliedAIReceipt(requestID: answer.requestID))
        _ = try store.undo(book: book, page: page)
        let blank = try store.exportCurrentPackage()
        XCTAssertEqual(blank.format, 1)
        XCTAssertNil(blank.assets)
        XCTAssertEqual(try store.exportPackage().assets?.keys.sorted(), [object.asset.sha256])
        try store.completeSuccessfulSync()
        try store.completeSuccessfulSync()
        XCTAssertNil(try store.exportPackage().assets)
        XCTAssertEqual(store.appliedAIReceipt(requestID: answer.requestID), receipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("assets/" + object.asset.sha256 + ".png").path))
    }

    func testDeletedPageObjectsAndAssetsRemainReconstructableCurrentState() throws {
        let (result, receipt, object) = try addAnswer()
        try store.update(book) { $0.deleted.append($0.pages.removeFirst()); $0.pages = [Page()] }
        let package = try store.exportCurrentPackage()
        XCTAssertEqual(package.format, 2)
        XCTAssertEqual(package.notebooks[0].deleted[0].nodes.count, 1)
        XCTAssertEqual(package.assets?.keys.sorted(), [object.asset.sha256])
        let receiver = Store(directory: root.appendingPathComponent("receiver"))
        try receiver.importPackage(package)
        XCTAssertEqual(receiver.objects(book: book, page: receiver.notebook(book)!.deleted[0]), [object])
        XCTAssertEqual(try receiver.exportCurrentPackage().encoded(), try package.encoded())
        XCTAssertEqual(try store.applyAI(result, assets: [:]), receipt)
    }

    func testMissingRetainedAssetAbortsSnapshotAndAssetCleanup() throws {
        let (_, _, object) = try addAnswer()
        let currentPage = store.notebook(book)!.pages[0]
        let snapshotFolder = root.appendingPathComponent(book.uuidString).appendingPathComponent(page.uuidString)
        let orphan = snapshotFolder.appendingPathComponent(UUID().uuidString + ".pkdraw")
        try PKDrawing(strokes: [ink(140)]).dataRepresentation().write(to: orphan)
        let asset = root.appendingPathComponent("assets/" + object.asset.sha256 + ".png")
        let bytes = try Data(contentsOf: asset)
        let indexBytes = try Data(contentsOf: root.appendingPathComponent("notebooks.json"))
        try FileManager.default.removeItem(at: asset)
        XCTAssertThrowsError(try store.completeSuccessfulSync())
        store = Store(directory: root)
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(store.notebook(book)!.pages[0].head, currentPage.head)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("notebooks.json")), indexBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        try bytes.write(to: asset)
        store = Store(directory: root)
        XCTAssertNil(store.loadError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(scene(), [object])
    }

    func testDocumentOnlyExportAndRetentionLeaveOtherBookUntouched() throws {
        let other = try store.addNotebook("Other")
        let otherPage = store.notebook(other)!.pages[0].id
        for n in 1...3 {
            try store.commit(book: other, page: otherPage, drawing: PKDrawing(strokes: [ink(CGFloat(n * 20))]))
            try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(CGFloat(n * 30))]))
        }
        let before = try store.exportCurrentPackage(book: other).encoded()
        let group = try store.addFolder("Only required")
        _ = try store.addFolder("Unrelated empty")
        try store.moveNotebook(book, into: group)
        let single = try store.exportCurrentPackage(book: book)
        XCTAssertEqual(single.notebooks.map(\.id), [book])
        XCTAssertEqual(single.folders?.map(\.id), [group])
        XCTAssertTrue(single.blobs.keys.allSatisfy { $0.hasPrefix(book.uuidString) })
        try store.completeSuccessfulSync(book: book)
        try store.completeSuccessfulSync(book: book)
        XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, 1)
        XCTAssertEqual(store.notebook(other)!.pages[0].nodes.count, 3)
        XCTAssertEqual(try store.exportCurrentPackage(book: other).encoded(), before)
    }

    func testImmutableHeadObjectCollisionCannotOverwriteSceneOnDownload() throws {
        _ = try addAnswer()
        let before = try store.exportCurrentPackage()
        var corrupt = before
        corrupt.notebooks[0].pages[0].nodes[0].objects![0].source = "Changed under immutable ID"
        XCTAssertThrowsError(try store.importPackage(corrupt))
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), try before.encoded())
    }

    func testDuplicatePageCopiesAssetsWithFreshObjectIdentities() throws {
        let (_, _, original) = try addAnswer()
        try store.duplicate(book: book, page: store.notebook(book)!.pages[0])
        let copied = store.objects(book: book, page: store.notebook(book)!.pages[0])
        XCTAssertEqual(copied.count, 1)
        XCTAssertNotEqual(copied[0].id, original.id)
        XCTAssertEqual(copied[0].asset, original.asset)
        XCTAssertEqual(copied[0].frame, original.frame)
        XCTAssertEqual(scene(), [original])
        _ = try store.capturedAIContext(book: book, focusPage: page, pageSize: CGSize(width: 240, height: 180))
    }

    func testMalformedOperationsAndUnapprovedMetadataFailBeforeApply() throws {
        let request = UUID()
        let (object, bytes) = try object(request: request)
        let valid = result(request: request, edits: [AIPageEdit(pageID: page,
            objectEdits: [AIObjectEdit(op: "add", object: object)], strokeEdits: [])])
        let before = try store.exportCurrentPackage().encoded()
        var mutations: [AIResult] = []
        var bad = valid; bad.format = 2; mutations.append(bad)
        bad = valid; bad.pageEdits[0].objectEdits[0].op = "execute"; mutations.append(bad)
        bad = valid; bad.previewSHA256s = [:]; mutations.append(bad)
        bad = valid; bad.pageEdits.append(bad.pageEdits[0]); mutations.append(bad)
        bad = valid; bad.pageEdits[0].objectEdits[0].object!.frame.width = .nan; mutations.append(bad)
        bad = valid; bad.pageEdits[0].objectEdits[0].object!.provenance.requestID = UUID(); mutations.append(bad)
        for strokeEdit in [
            AIStrokeEdit(id: "native", fingerprint: contextHash, op: "move", dx: 1),
            AIStrokeEdit(id: "native", fingerprint: contextHash, op: "move", color: "#007AFF", dx: 1, dy: 2),
            AIStrokeEdit(id: "native", fingerprint: contextHash, op: "move", dx: 4097, dy: 2),
            AIStrokeEdit(id: "native", fingerprint: contextHash, op: "keep", dx: 0),
            AIStrokeEdit(id: "native", fingerprint: contextHash, op: "recolor", color: "#007AFF", dy: 1)
        ] {
            bad = valid; bad.pageEdits[0].strokeEdits = [strokeEdit]; mutations.append(bad)
        }
        for invalid in mutations {
            XCTAssertThrowsError(try store.applyAI(invalid, assets: [object.asset.sha256: bytes]))
            XCTAssertEqual(try store.exportCurrentPackage().encoded(), before)
        }
    }

    func testMoveOnlyUsesLatestInkAndSceneAndPreservesWholeNativeAttributes() throws {
        let controls = [CGPoint(x: 20, y: 30), CGPoint(x: 90, y: 120)].enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: Double(index) / 8,
                size: CGSize(width: 20, height: 20), opacity: 0.5, force: 0.75,
                azimuth: 0.25, altitude: 1.25, secondaryScale: 0.875, threshold: 0.25)
        }
        let path = PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSince1970: 1_700_000_000))
        let mask = UIBezierPath(rect: CGRect(x: 10, y: 20, width: 100, height: 130))
        mask.append(UIBezierPath(rect: CGRect(x: 30, y: 40, width: 10, height: 10)))
        mask.usesEvenOddFillRule = true
        let transform = CGAffineTransform(a: 0.97, b: 0.11, c: -0.09, d: 1.03, tx: 3.125, ty: 8.75)
        let target: PKStroke
        if #available(iOS 27.0, *) {
            target = PKStroke(ink: PKInk(.marker, color: .yellow), path: path, transform: transform,
                mask: mask, randomSeed: 0xBEEF, id: UUID(), renderGroupID: UUID(),
                renderState: PKStroke.RenderState(grainOffset: CGPoint(x: 3.25, y: -4.5)))
        } else {
            target = PKStroke(ink: PKInk(.marker, color: .yellow), path: path, transform: transform,
                mask: mask, randomSeed: 0xBEEF)
        }
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [target]))
        let captured = try PortableStroke(native().strokes[0], includeSamples: false)
        // Object and handwriting produced after capture must survive a move-only reply.
        let (_, _, currentObject) = try addAnswer()
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: try native().strokes + [ink(150)]))
        let before = try native(), nodes = store.notebook(book)!.pages[0].nodes.count
        let translation = CGAffineTransform(translationX: -60, y: -80)
        let oracle = try PKDrawing(data: PKDrawing(strokes: [before.strokes[0]])
            .transformed(using: translation).dataRepresentation())
        let expected = try PortableStroke(oracle.strokes[0], includeSamples: false)
        let later = try PortableStroke(before.strokes[1], includeSamples: false)
        let answer = result(request: UUID(), edits: [AIPageEdit(pageID: page, objectEdits: [], strokeEdits: [
            AIStrokeEdit(id: captured.targetID, fingerprint: try captured.fingerprint(), op: "move", dx: -60, dy: -80)
        ])])
        let receipt = try store.applyAI(answer, assets: [:])
        XCTAssertTrue(receipt.skippedStrokeTargets.isEmpty)
        let after = try native()
        XCTAssertLessThan(after.strokes[0].renderBounds.minX, 0)
        XCTAssertLessThan(after.strokes[0].renderBounds.minY, 0)
        var actual = try PortableStroke(after.strokes[0], includeSamples: false)
        if #available(iOS 27.0, *) { XCTAssertNotEqual(after.strokes[0].id, before.strokes[0].id) }
        actual.id = expected.id // Cache identity alone is intentionally fresh.
        for (a, e) in zip(actual.transform, expected.transform) { XCTAssertEqual(a, e, accuracy: 0.010001) }
        XCTAssertEqual(actual.mask?.evenOdd, expected.mask?.evenOdd)
        XCTAssertEqual(actual.mask?.commands.count, expected.mask?.commands.count)
        for (a, e) in zip(actual.mask?.commands ?? [], expected.mask?.commands ?? []) {
            XCTAssertEqual(a.count, e.count)
            XCTAssertEqual(a.first, e.first)
            for (x, y) in zip(a.dropFirst(), e.dropFirst()) { XCTAssertEqual(x, y, accuracy: 0.010001) }
        }
        // As in Carry, native archive mask requantization may differ by 0.01 pt.
        actual.transform = expected.transform; actual.mask = expected.mask
        assertNativeAttributes(expected, actual)
        assertNativeAttributes(later, try PortableStroke(after.strokes[1], includeSamples: false))
        XCTAssertEqual(scene(), [currentObject])
        XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, nodes + 1)
        _ = try store.undo(book: book, page: page)
        XCTAssertEqual(try native(), before)
        XCTAssertEqual(scene(), [currentObject])
        store = Store(directory: root)
        XCTAssertNil(store.loadError)
        _ = try store.redo(book: book, page: page)
        XCTAssertEqual(try native(), after)
        XCTAssertEqual(scene(), [currentObject])
        XCTAssertEqual(try store.applyAI(answer, assets: [:]), receipt)
        XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, nodes + 1)
    }

    func testEditOnlyObjectAndStrokeRemovalShareOneCombinedUndoNode() throws {
        let (_, _, removed) = try addAnswer()
        let (_, _, retained) = try addAnswer()
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(40), ink(150)]))
        let before = try native(), nodes = store.notebook(book)!.pages[0].nodes.count
        let target = try PortableStroke(before.strokes[0], includeSamples: false)
        let receipt = try store.applyAI(result(request: UUID(), edits: [AIPageEdit(pageID: page, objectEdits: [
            AIObjectEdit(op: "remove", objectID: removed.id, expectedRevision: removed.revision, expectedObject: removed)
        ], strokeEdits: [AIStrokeEdit(id: target.targetID, fingerprint: try target.fingerprint(), op: "remove")])]), assets: [:])
        XCTAssertTrue(receipt.skippedObjectTargets.isEmpty)
        XCTAssertTrue(receipt.skippedStrokeTargets.isEmpty)
        XCTAssertEqual(scene(), [retained])
        XCTAssertEqual(try native().strokes.count, 1)
        XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, nodes + 1)
        assertNativeAttributes(try PortableStroke(before.strokes[1], includeSamples: false),
            try PortableStroke(native().strokes[0], includeSamples: false))
        _ = try store.undo(book: book, page: page)
        XCTAssertEqual(try native(), before)
        XCTAssertEqual(scene(), [removed, retained])
        _ = try store.redo(book: book, page: page)
        XCTAssertEqual(scene(), [retained])
        XCTAssertEqual(try native().strokes.count, 1)
    }

    func testObjectRemoveOnlyAndNativeRemoveRecolorOnlyAreValid() throws {
        let (_, _, object) = try addAnswer()
        _ = try store.applyAI(result(request: UUID(), edits: [AIPageEdit(pageID: page, objectEdits: [
            AIObjectEdit(op: "remove", objectID: object.id, expectedRevision: 1, expectedObject: object)
        ], strokeEdits: [])]), assets: [:])
        XCTAssertTrue(scene().isEmpty)
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(40)]))
        let target = try PortableStroke(native().strokes[0], includeSamples: false)
        _ = try store.applyAI(result(request: UUID(), edits: [AIPageEdit(pageID: page, objectEdits: [], strokeEdits: [
            AIStrokeEdit(id: target.targetID, fingerprint: try target.fingerprint(), op: "recolor", color: "#007AFF")
        ])]), assets: [:])
        let recolored = try PortableStroke(native().strokes[0], includeSamples: false)
        XCTAssertNotEqual(recolored.color, target.color)
        _ = try store.applyAI(result(request: UUID(), edits: [AIPageEdit(pageID: page, objectEdits: [], strokeEdits: [
            AIStrokeEdit(id: recolored.targetID, fingerprint: try recolored.fingerprint(), op: "remove")
        ])]), assets: [:])
        XCTAssertTrue(try native().strokes.isEmpty)
        _ = try store.undo(book: book, page: page)
        XCTAssertEqual(try native().strokes.count, 1)
    }

    func testEmptyKeepOnlyRejectAndZeroMoveDoesNotCreateHistory() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(40)]))
        let before = try native(), savedPage = store.notebook(book)!.pages[0]
        let target = try PortableStroke(before.strokes[0], includeSamples: false)
        for edits in [[], [AIStrokeEdit(id: target.targetID, fingerprint: try target.fingerprint(), op: "keep")]] {
            let empty = result(request: UUID(), edits: [AIPageEdit(pageID: page, objectEdits: [], strokeEdits: edits)])
            XCTAssertThrowsError(try store.applyAI(empty, assets: [:]))
            XCTAssertNil(store.appliedAIReceipt(requestID: empty.requestID))
        }
        let zero = result(request: UUID(), edits: [AIPageEdit(pageID: page, objectEdits: [], strokeEdits: [
            AIStrokeEdit(id: target.targetID, fingerprint: try target.fingerprint(), op: "move", dx: 0, dy: 0)
        ])])
        let receipt = try store.applyAI(zero, assets: [:])
        XCTAssertTrue(receipt.skippedStrokeTargets.isEmpty)
        XCTAssertEqual(try native(), before)
        XCTAssertEqual(store.notebook(book)!.pages[0].head, savedPage.head)
        XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, savedPage.nodes.count)
    }

    func testMissingChangedAndAmbiguousMoveTargetsSkipWithoutHistoryOrRestoringCapture() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(40)]))
        let stroke = try native().strokes[0]
        let target = try PortableStroke(stroke, includeSamples: false)
        let move = AIStrokeEdit(id: target.targetID, fingerprint: try target.fingerprint(), op: "move", dx: 10, dy: 20)
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(150)]))
        func applySkipped() throws {
            let before = try native(), savedPage = store.notebook(book)!.pages[0]
            let answer = result(request: UUID(), edits: [AIPageEdit(pageID: page, objectEdits: [], strokeEdits: [move])])
            let receipt = try store.applyAI(answer, assets: [:])
            XCTAssertEqual(receipt.skippedStrokeTargets, [move.id])
            XCTAssertEqual(try native(), before)
            XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, savedPage.nodes.count)
            XCTAssertEqual(store.notebook(book)!.pages[0].head, savedPage.head)
        }
        try applySkipped()
        if #available(iOS 27.0, *) {
            let changed = PKStroke(ink: stroke.ink, path: stroke.path,
                transform: CGAffineTransform(translationX: 25, y: 10), mask: stroke.mask,
                randomSeed: stroke.randomSeed, id: stroke.id, renderGroupID: stroke.renderGroupID,
                renderState: stroke.renderState)
            try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [changed, ink(150)]))
            try applySkipped()
            try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke, changed, ink(150)]))
            if try native().strokes[0].id == native().strokes[1].id { try applySkipped() }
        }
        // Ambiguity is rejected even when exactly one fingerprint matches.
        var first = target; first.id = UUID()
        var changed = first; changed.transform[4] += 5
        let ambiguous = AIStrokeEdit(id: first.targetID, fingerprint: try first.fingerprint(), op: "move", dx: 10, dy: 20)
        XCTAssertNil(try AIStrokeMatching.index(for: ambiguous, in: [first, changed]))
    }

    func testStrokeMoveWireIsStrictAndLegacyNilFieldsRemainOmitted() throws {
        let fingerprint = String(repeating: "a", count: 64)
        for op in ["keep", "remove", "recolor", "move"] {
            let edit = AIStrokeEdit(id: "native", fingerprint: fingerprint, op: op,
                color: op == "recolor" ? "#007AFF" : nil, dx: op == "move" ? -4096 : nil, dy: op == "move" ? 4096 : nil)
            let bytes = try AIHash.encoded(edit)
            let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let extras: Set<String> = op == "move" ? ["dx", "dy"] : op == "recolor" ? ["color"] : []
            XCTAssertEqual(Set(wire.keys), Set(["id", "fingerprint", "op"]).union(extras))
            let decoded = try JSONDecoder().decode(AIStrokeEdit.self, from: bytes)
            XCTAssertEqual(decoded.dx, edit.dx)
            XCTAssertEqual(decoded.dy, edit.dy)
            XCTAssertEqual(try AIHash.encoded(decoded), bytes)
        }
        let valid: [String: Any] = ["id": "native", "fingerprint": fingerprint, "op": "move", "dx": 1, "dy": 2]
        var malformed: [[String: Any]] = []
        for key in ["dx", "dy"] {
            var missing = valid; missing.removeValue(forKey: key); malformed.append(missing)
            for value in [NSNull(), true, "1", 4096.1, -4096.1] as [Any] {
                var bad = valid; bad[key] = value; malformed.append(bad)
            }
        }
        for (key, value) in [("color", "#007AFF"), ("unknown", "field")] {
            var bad = valid; bad[key] = value; malformed.append(bad)
        }
        for op in ["keep", "remove", "recolor"] {
            var bad = valid; bad["op"] = op; malformed.append(bad)
        }
        for bad in malformed {
            XCTAssertThrowsError(try JSONDecoder().decode(AIStrokeEdit.self, from: JSONSerialization.data(withJSONObject: bad)))
        }
        for value in [Double.nan, .infinity, -.infinity, 4096.1] {
            let bad = AIStrokeEdit(id: "native", fingerprint: fingerprint, op: "move", dx: value, dy: 0)
            XCTAssertThrowsError(try bad.validate())
        }
    }


    func testFractionalMoveApprovalRequiresCanonicalHalfPointDeltasAndNativeMatchesThem() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(40), ink(150)]))
        let original = try native()
        for (rawDX, rawDY, dx, dy) in [(0.24, -0.24, 0.0, 0.0), (0.26, -0.26, 0.5, -0.5),
                                     (1.24, -1.26, 1.0, -1.5)] {
            try store.commit(book: book, page: page, drawing: original)
            let before = try native(), saved = store.notebook(book)!.pages[0]
            let captured = try PortableStroke(before.strokes[0], includeSamples: false)
            var operation = AIStrokeEdit(id: captured.targetID, fingerprint: try captured.fingerprint(),
                op: "move", dx: rawDX, dy: rawDY)
            let unapproved = result(request: UUID(), edits: [AIPageEdit(pageID: page, objectEdits: [], strokeEdits: [operation])])
            XCTAssertThrowsError(try store.applyAI(unapproved, assets: [:]))
            XCTAssertThrowsError(try AIResult.approved(data: AIHash.encoded(unapproved)))
            XCTAssertEqual(try native(), before)
            XCTAssertNil(store.appliedAIReceipt(requestID: unapproved.requestID))
            operation.dx = dx; operation.dy = dy
            let canonical = result(request: UUID(), edits: [AIPageEdit(pageID: page, objectEdits: [], strokeEdits: [operation])])
            let approved = try AIResult.approved(data: AIHash.encoded(canonical))
            let receipt = try store.applyAI(approved, assets: [:])
            XCTAssertTrue(receipt.skippedStrokeTargets.isEmpty)
            let after = try native()
            let oracle = try PKDrawing(data: PKDrawing(strokes: [before.strokes[0]])
                .transformed(using: CGAffineTransform(translationX: dx, y: dy)).dataRepresentation())
            let expected = try PortableStroke(oracle.strokes[0], includeSamples: false)
            var actual = try PortableStroke(after.strokes[0], includeSamples: false)
            actual.id = expected.id
            assertNativeAttributes(expected, actual)
            assertNativeAttributes(try PortableStroke(before.strokes[1], includeSamples: false),
                try PortableStroke(after.strokes[1], includeSamples: false))
            XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, saved.nodes.count + (dx == 0 && dy == 0 ? 0 : 1))
        }
    }

    func testNearGridToleranceStillAppliesCanonicalZeroWithoutHistory() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [ink(40)]))
        let before = try native(), saved = store.notebook(book)!.pages[0]
        let target = try PortableStroke(before.strokes[0], includeSamples: false)
        let op = AIStrokeEdit(id: target.targetID, fingerprint: try target.fingerprint(), op: "move", dx: 1e-10, dy: -1e-10)
        try op.validate()
        let answer = result(request: UUID(), edits: [AIPageEdit(pageID: page, objectEdits: [], strokeEdits: [op])])
        _ = try store.applyAI(answer, assets: [:])
        XCTAssertEqual(try native(), before)
        XCTAssertEqual(store.notebook(book)!.pages[0].head, saved.head)
        XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, saved.nodes.count)
        var invalid = op; invalid.dx = 1e-8
        XCTAssertThrowsError(try invalid.validate())
    }

}
