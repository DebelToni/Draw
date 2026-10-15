import XCTest
import UIKit
import PencilKit
import ImageIO
@testable import Draw

@MainActor
final class AICaptureTests: XCTestCase {
    private var root: URL!
    private var store: Store!
    private var book: UUID!
    private var page: UUID!
    private let size = CGSize(width: 240, height: 180)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = Store(directory: root)
        book = try store.addNotebook("Capture")
        page = store.notebook(book)!.pages[0].id
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func stroke(color: UIColor = .black) -> PKStroke {
        let points = [CGPoint(x: 25, y: 35), CGPoint(x: 65, y: 42), CGPoint(x: 90, y: 80)].enumerated().map {
            PKStrokePoint(location: $0.element, timeOffset: Double($0.offset) / 10,
                size: CGSize(width: 6, height: 6), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.monoline, color: color),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_700_000_000)), randomSeed: 123)
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return bytes
    }

    private func image(_ hash: String, assets: [String: Data]) throws -> UIImage {
        try XCTUnwrap(UIImage(data: XCTUnwrap(assets[hash])))
    }

    func testNestedLogicalPathUsesPinnedSourceGraphAfterLiveFolderMoveAndRename() async throws {
        let semester = try store.addFolder("Semester")
        let math = try store.addFolder("Math", in: semester)
        let leaf = try store.addFolder("Exercises", in: math)
        try store.moveNotebook(book, into: leaf)
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke()]))
        let source = try store.exportCurrentPackage(book: book)
        XCTAssertEqual(source.format, 3)
        let other = try store.addFolder("Other")
        try store.moveFolder(math, into: other)
        try store.renameFolder(leaf, to: "Renamed")
        let live = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        XCTAssertEqual(live.context.folderName, "Other / Math / Renamed")
        XCTAssertEqual(live.context.folderID, leaf)
        let pinned = try store.capturedAIContext(book: book, focusPage: page, pageSize: size, source: source)
        XCTAssertEqual(pinned.context.folderName, "Semester / Math / Exercises")
        XCTAssertEqual(pinned.context.folderID, leaf)
        let asyncPinned = try await store.capturedAIContextAsync(book: book, focusPage: page, pageSize: size, source: source)
        XCTAssertEqual(asyncPinned.context.folderName, pinned.context.folderName)
        let independent = Store(directory: root.appendingPathComponent("empty"))
        let standalone = try independent.capturedAIContext(book: book, focusPage: page, pageSize: size, source: source)
        XCTAssertEqual(standalone.context.folderName, pinned.context.folderName)
        var bad = source; bad.folders!.removeAll { $0.id == semester }
        XCTAssertThrowsError(try store.capturedAIContext(book: book, focusPage: page, pageSize: size, source: bad))
        bad = source; bad.folders![0].parentID = leaf
        XCTAssertThrowsError(try store.capturedAIContext(book: book, focusPage: page, pageSize: size, source: bad))
    }

    func testActualPaperAndTransparentNativeInkLayersAreHashedAtTwoTimesScale() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke()]))
        for background in 0...3 {
            try store.update(book) { $0.pages[0].background = background }
            let capture = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
            let manifest = capture.context.pages[0]
            XCTAssertEqual(manifest.background, background)
            XCTAssertEqual(manifest.width, 240)
            XCTAssertEqual(manifest.height, 180)
            XCTAssertEqual(capture.context.rendererSignature, "native-capture-v2")
            for (hash, bytes) in capture.assets { XCTAssertEqual(hash, AIHash.digest(bytes)) }
            let paper = try image(manifest.paperSHA256, assets: capture.assets)
            XCTAssertEqual(try pixels(paper), try pixels(AICapture.paper(background: background, size: size)))
            let ink = try image(manifest.inkSHA256, assets: capture.assets)
            XCTAssertEqual(ink.cgImage?.width, 480)
            XCTAssertEqual(ink.cgImage?.height, 360)
            let alpha = try pixels(ink).enumerated().filter { $0.offset % 4 == 3 }.map(\.element)
            XCTAssertTrue(alpha.contains(0))
            XCTAssertTrue(alpha.contains(255))
            let portable = try JSONDecoder().decode(PortablePage.self, from: XCTUnwrap(capture.assets[manifest.portableSHA256]))
            XCTAssertEqual(portable.background, background)
            XCTAssertEqual(portable.head, manifest.head)
            XCTAssertEqual(portable.strokes.count, 1)
        }
    }

    func testPerStrokeAssetCropsAndOffsetsReconstructSingleNativeInk() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke()]))
        let capture = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        let manifest = capture.context.pages[0]
        let target = try XCTUnwrap(manifest.strokeTargets.first)
        XCTAssertEqual(target.index, 0)
        let native = try store.drawing(book: book, page: store.notebook(book)!.pages[0])
        let portable = try PortableStroke(native.strokes[0], includeSamples: false)
        XCTAssertEqual(target.id, portable.targetID)
        XCTAssertEqual(target.fingerprint, try portable.fingerprint())
        XCTAssertEqual(target.frame.width * 2, Double(target.asset.pixelWidth))
        XCTAssertEqual(target.frame.height * 2, Double(target.asset.pixelHeight))
        XCTAssertLessThan(target.frame.width, Double(size.width))
        XCTAssertLessThan(target.frame.height, Double(size.height))
        let data = try XCTUnwrap(capture.assets[target.asset.sha256])
        try AIAssets.validate(data: data, asset: target.asset)
        let crop = try XCTUnwrap(UIImage(data: data))
        let rebuilt = UIGraphicsImageRenderer(size: size, format: AICapture.rendererFormat()).image { _ in
            crop.draw(in: CGRect(x: target.frame.x, y: target.frame.y, width: target.frame.width, height: target.frame.height))
        }
        let expected = try pixels(image(manifest.inkSHA256, assets: capture.assets))
        let actual = try pixels(rebuilt)
        let differences = zip(expected, actual).map { abs(Int($0) - Int($1)) }
        XCTAssertLessThanOrEqual(differences.max() ?? 0, 1)
        XCTAssertLessThanOrEqual(Double(differences.reduce(0, +)) / Double(differences.count), 0.01)
    }

    func testFullStrokeTilePreservesHiddenInkAndMatchesNativeTranslationIntoView() throws {
        let crossing = PKStroke(ink: stroke().ink, path: stroke().path,
            transform: CGAffineTransform(translationX: 0, y: -50), randomSeed: 123)
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [crossing]))
        let native = try store.drawing(book: book, page: store.notebook(book)!.pages[0])
        let before = try store.exportPackage().encoded()
        let capture = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        let manifest = capture.context.pages[0], target = try XCTUnwrap(manifest.strokeTargets.first)
        XCTAssertEqual(capture.context.rendererSignature, "native-capture-v2")
        XCTAssertEqual(capture.context.format, 1)
        XCTAssertLessThan(target.frame.y, 0)
        XCTAssertGreaterThan(target.frame.y + target.frame.height, 0)
        let tile = try image(target.asset.sha256, assets: capture.assets)
        let tileAlpha = try pixels(tile).enumerated().filter { $0.offset % 4 == 3 }.map(\.element)
        XCTAssertTrue(tileAlpha.contains(0), "Native alpha and transparent holes are retained")
        XCTAssertTrue(tileAlpha.contains(255))
        XCTAssertEqual(target.asset.pixelWidth, Int(target.frame.width * 2))
        XCTAssertEqual(target.asset.pixelHeight, Int(target.frame.height * 2))
        let pageRect = CGRect(origin: .zero, size: size)
        XCTAssertEqual(try pixels(image(manifest.inkSHA256, assets: capture.assets)),
            try pixels(native.image(from: pageRect, scale: 2)))
        for dy in [0.0, 50.0] {
            let rebuilt = UIGraphicsImageRenderer(size: size, format: AICapture.rendererFormat()).image { _ in
                tile.draw(in: CGRect(x: target.frame.x, y: target.frame.y + dy,
                    width: target.frame.width, height: target.frame.height))
            }
            let moved = native.transformed(using: CGAffineTransform(translationX: 0, y: CGFloat(dy)))
            let expected = try pixels(moved.image(from: pageRect, scale: 2))
            let actual = try pixels(rebuilt)
            let differences = zip(expected, actual).map { abs(Int($0) - Int($1)) }
            XCTAssertLessThanOrEqual(differences.max() ?? 0, 1)
            XCTAssertLessThanOrEqual(Double(differences.reduce(0, +)) / Double(differences.count), 0.01)
        }
        XCTAssertEqual(try store.exportPackage().encoded(), before)
        // Applying the declared translation reveals the same ink as its approved tile.
        let result = AIResult(requestID: UUID(), documentID: book,
            contextSHA256: AIHash.digest(try capture.context.encoded()), draftVersion: 1,
            rendererSignature: "draw-ai-render-v1", pageEdits: [AIPageEdit(pageID: page, objectEdits: [],
                strokeEdits: [AIStrokeEdit(id: target.id, fingerprint: target.fingerprint, op: "move", dx: 0, dy: 50)])],
            previewSHA256s: [page.uuidString: manifest.compositeSHA256])
        let receipt = try store.applyAI(result, assets: [:])
        XCTAssertTrue(receipt.skippedStrokeTargets.isEmpty)
        let movedNative = try store.drawing(book: book, page: store.notebook(book)!.pages[0])
        XCTAssertGreaterThan(movedNative.bounds.minY, 0)
        let differences = zip(try pixels(movedNative.image(from: pageRect, scale: 2)),
            try pixels(native.transformed(using: CGAffineTransform(translationX: 0, y: 50)).image(from: pageRect, scale: 2)))
            .map { abs(Int($0) - Int($1)) }
        XCTAssertLessThanOrEqual(differences.max() ?? 0, 1)
        _ = try store.undo(book: book, page: page)
        XCTAssertEqual(try store.exportPackage().notebooks[0].pages[0].head, capture.context.pages[0].head)
        XCTAssertEqual(try store.drawing(book: book, page: store.notebook(book)!.pages[0]), native)
    }

    func testColoredEntirelyOffpageStrokeHasFullTileAndCanMoveIntoView() throws {
        let outside = PKStroke(ink: stroke().ink, path: stroke().path,
            transform: CGAffineTransform(translationX: -150, y: -120), randomSeed: 123)
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [outside]))
        let capture = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        let manifest = capture.context.pages[0], target = try XCTUnwrap(manifest.strokeTargets.first)
        XCTAssertLessThan(target.frame.x + target.frame.width, 0)
        XCTAssertLessThan(target.frame.y + target.frame.height, 0)
        XCTAssertGreaterThan(target.asset.pixelWidth, 1)
        XCTAssertGreaterThan(target.asset.pixelHeight, 1)
        let tile = try image(target.asset.sha256, assets: capture.assets)
        XCTAssertTrue(try pixels(tile).enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 })
        XCTAssertTrue(try pixels(image(manifest.inkSHA256, assets: capture.assets)).allSatisfy { $0 == 0 })
        let rebuilt = UIGraphicsImageRenderer(size: size, format: AICapture.rendererFormat()).image { _ in
            tile.draw(in: CGRect(x: target.frame.x + 150, y: target.frame.y + 120,
                width: target.frame.width, height: target.frame.height))
        }
        let native = try store.drawing(book: book, page: store.notebook(book)!.pages[0])
            .transformed(using: CGAffineTransform(translationX: 150, y: 120))
        let differences = zip(try pixels(rebuilt), try pixels(native.image(from: CGRect(origin: .zero, size: size), scale: 2)))
            .map { abs(Int($0) - Int($1)) }
        XCTAssertLessThanOrEqual(differences.max() ?? 0, 1)
    }

    func testFullStrokeRasterAxisPixelAndAggregateBudgetsFailBeforeAllocation() throws {
        let wide = PKStroke(ink: stroke().ink, path: stroke().path,
            transform: CGAffineTransform(scaleX: 100, y: 1), randomSeed: 123)
        XCTAssertThrowsError(try AICapture.croppedStroke(wide)) { error in
            guard case SyncError.tooLarge = error else { return XCTFail("Expected preflight size rejection") }
        }
        func diagonal(_ span: CGFloat, seed: UInt32) -> PKStroke {
            let points = [CGPoint(x: -span, y: -span), CGPoint(x: -10, y: -10)].enumerated().map {
                PKStrokePoint(location: $0.element, timeOffset: Double($0.offset) / 10,
                    size: CGSize(width: 6, height: 6), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: points,
                creationDate: Date(timeIntervalSince1970: 1_700_000_000)), randomSeed: seed)
        }
        let large = diagonal(3100, seed: 1)
        XCTAssertThrowsError(try AICapture.croppedStroke(large)) { error in
            guard case SyncError.tooLarge = error else { return XCTFail("Expected pixel preflight rejection") }
        }
        // Each full bound fits; their aggregate exceeds 128 MiB even though every
        // visible page is blank. No full-stroke tile may be allocated on failure.
        let strokes = (1...3).map { diagonal(1800, seed: UInt32($0)) }
        XCTAssertTrue(try strokes.allSatisfy { !(try AICapture.strokeBounds($0)).isEmpty })
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: strokes))
        let before = try store.exportPackage().encoded()
        XCTAssertThrowsError(try store.capturedAIContext(book: book, focusPage: page, pageSize: size))
        XCTAssertTrue(store.aiCaptureCache.lastProfiles.isEmpty)
        XCTAssertEqual(try store.exportPackage().encoded(), before)
    }

    func testV2CacheKeyCannotReuseLegacyClippedTiles() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke()]))
        let capture = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        let saved = store.notebook(book)!.pages[0], source = try store.exportCurrentPackage(book: book)
        struct LegacyKey: Encodable {
            var page: UUID; var head: UUID?; var background: Int; var objects: [AIObject]
            var width: Double; var height: Double; var archiveSHA256: String
            var renderer = "native-capture-v1"
        }
        let archive = try XCTUnwrap(source.blobs[SyncPackage.key(book, page, saved.head!)])
        let key = AIHash.digest(try AIHash.encoded(LegacyKey(page: page, head: saved.head, background: saved.background,
            objects: [], width: Double(size.width), height: Double(size.height), archiveSHA256: AIHash.digest(archive))))
        var legacyPage = capture.context.pages[0]
        legacyPage.strokeTargets = []
        store.aiCaptureCache.store(AICaptureCache.Entry(key: key, page: legacyPage, assets: capture.assets), book: book, page: saved)
        let fresh = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        XCTAssertEqual(fresh.context.rendererSignature, "native-capture-v2")
        XCTAssertEqual(fresh.context.pages[0].strokeTargets.count, 1)
        XCTAssertFalse(store.aiCaptureCache.lastProfiles[0].cacheHit)
        _ = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        XCTAssertTrue(store.aiCaptureCache.lastProfiles[0].cacheHit)
    }

    func testCompositeHasGeneratedObjectsBelowHandwriting() throws {
        let request = UUID(), contextHash = String(repeating: "a", count: 64)
        let objectSize = CGSize(width: 120, height: 100)
        let bytes = try XCTUnwrap(UIGraphicsImageRenderer(size: objectSize, format: AICapture.rendererFormat()).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: objectSize))
        }.pngData())
        let asset = AIAsset(sha256: AIHash.digest(bytes), pixelWidth: 240, pixelHeight: 200)
        let object = AIObject(id: UUID(), revision: 1, kind: "text", source: "Answer",
            frame: AIFrame(x: 0, y: 0, width: 120, height: 100), style: AIStyle(), asset: asset,
            provenance: AIProvenance(requestID: request, contextSHA256: contextHash, rendererSignature: "draw-ai-render-v1"))
        let result = AIResult(requestID: request, documentID: book, contextSHA256: contextHash,
            draftVersion: 1, rendererSignature: "draw-ai-render-v1", pageEdits: [AIPageEdit(pageID: page,
                objectEdits: [AIObjectEdit(op: "add", object: object)], strokeEdits: [])],
            previewSHA256s: [page.uuidString: String(repeating: "b", count: 64)])
        _ = try store.applyAI(result, assets: [asset.sha256: bytes])
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke(color: .red)]))
        let capture = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        let manifest = capture.context.pages[0]
        XCTAssertEqual(manifest.objects, [object])
        XCTAssertEqual(capture.assets[asset.sha256], bytes)
        let paper = try image(manifest.paperSHA256, assets: capture.assets)
        let ink = try image(manifest.inkSHA256, assets: capture.assets)
        let objectImage = try XCTUnwrap(UIImage(data: bytes))
        let expected = UIGraphicsImageRenderer(size: size, format: AICapture.rendererFormat(opaque: true)).image { _ in
            paper.draw(in: CGRect(origin: .zero, size: size))
            objectImage.draw(in: CGRect(origin: .zero, size: objectSize))
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
        XCTAssertEqual(try pixels(image(manifest.compositeSHA256, assets: capture.assets)), try pixels(expected))
    }

    func testCyanHighlightScreenshotPreservesBlackNativeInkAndRawStrokeClipPixels() throws {
        let controls = stroke(color: .black)
        let blackPen = PKStroke(ink: PKInk(.pen, color: .black), path: controls.path, randomSeed: controls.randomSeed)
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [blackPen]))
        let original = try store.drawing(book: book, page: store.notebook(book)!.pages[0])
        let before = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        let beforePage = before.context.pages[0]
        let originalPixels = try pixels(original.image(from: CGRect(origin: .zero, size: size), scale: 2))
        XCTAssertEqual(try pixels(image(beforePage.inkSHA256, assets: before.assets)), originalPixels)
        let request = UUID(), contextHash = String(repeating: "a", count: 64)
        let objectSize = CGSize(width: 120, height: 100)
        let bytes = try AICapture.png(UIGraphicsImageRenderer(size: objectSize, format: AICapture.rendererFormat()).image { context in
            UIColor(red: 0, green: 184.0 / 255, blue: 217.0 / 255, alpha: 0.2).setFill()
            context.fill(CGRect(origin: .zero, size: objectSize))
        })
        let asset = AIAsset(sha256: AIHash.digest(bytes), pixelWidth: 240, pixelHeight: 200)
        let object = AIObject(id: UUID(), revision: 1, kind: "highlight", source: "{\"opacity\":0.2}",
            frame: AIFrame(x: 0, y: 0, width: 120, height: 100),
            style: AIStyle(color: "#00B8D9"), asset: asset,
            provenance: AIProvenance(requestID: request, contextSHA256: contextHash, rendererSignature: "draw-ai-render-v1"))
        let result = AIResult(requestID: request, documentID: book, contextSHA256: contextHash,
            draftVersion: 1, rendererSignature: "draw-ai-render-v1", pageEdits: [AIPageEdit(pageID: page,
                objectEdits: [AIObjectEdit(op: "add", object: object)], strokeEdits: [])],
            previewSHA256s: [page.uuidString: String(repeating: "b", count: 64)])
        _ = try store.applyAI(result, assets: [asset.sha256: bytes])
        let after = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        let manifest = after.context.pages[0]
        XCTAssertEqual(manifest.objects, [object])
        XCTAssertEqual(after.assets[asset.sha256], bytes)
        XCTAssertEqual(manifest.inkSHA256, beforePage.inkSHA256)
        XCTAssertEqual(after.assets[manifest.inkSHA256], before.assets[beforePage.inkSHA256])
        XCTAssertEqual(try pixels(image(manifest.inkSHA256, assets: after.assets)), originalPixels)
        let rawClip = try XCTUnwrap(beforePage.strokeTargets.first)
        let currentClip = try XCTUnwrap(manifest.strokeTargets.first)
        XCTAssertEqual(currentClip.asset, rawClip.asset)
        XCTAssertEqual(currentClip.frame, rawClip.frame)
        XCTAssertEqual(currentClip.fingerprint, rawClip.fingerprint)
        XCTAssertEqual(after.assets[currentClip.asset.sha256], before.assets[rawClip.asset.sha256])
        let clipImage = try image(currentClip.asset.sha256, assets: after.assets)
        let rebuiltInk = UIGraphicsImageRenderer(size: size, format: AICapture.rendererFormat()).image { _ in
            clipImage.draw(in: CGRect(x: currentClip.frame.x, y: currentClip.frame.y,
                width: currentClip.frame.width, height: currentClip.frame.height))
        }
        let differences = zip(originalPixels, try pixels(rebuiltInk)).map { abs(Int($0) - Int($1)) }
        XCTAssertLessThanOrEqual(differences.max() ?? 0, 1)
        XCTAssertLessThanOrEqual(Double(differences.reduce(0, +)) / Double(differences.count), 0.01)
        XCTAssertEqual(try store.drawing(book: book, page: store.notebook(book)!.pages[0]), original)
        let paper = try image(manifest.paperSHA256, assets: after.assets)
        let ink = try image(manifest.inkSHA256, assets: after.assets)
        let objectImage = try XCTUnwrap(UIImage(data: bytes))
        let layerPixels = try pixels(objectImage)
        let alpha = stride(from: 3, to: layerPixels.count, by: 4).map { layerPixels[$0] }
        XCTAssertEqual(alpha.min(), 51)
        XCTAssertEqual(alpha.max(), 51)
        XCTAssertEqual(Double(alpha.reduce(0) { $0 + Int($1) }) / Double(alpha.count), 51)
        let expected = UIGraphicsImageRenderer(size: size, format: AICapture.rendererFormat(opaque: true)).image { _ in
            paper.draw(in: CGRect(origin: .zero, size: size))
            objectImage.draw(in: CGRect(origin: .zero, size: objectSize))
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
        let composite = try pixels(image(manifest.compositeSHA256, assets: after.assets))
        XCTAssertEqual(composite, try pixels(expected))
        let blackPixels = stride(from: 0, to: originalPixels.count, by: 4).filter {
            originalPixels[$0] == 0 && originalPixels[$0 + 1] == 0 && originalPixels[$0 + 2] == 0 && originalPixels[$0 + 3] == 255
        }
        XCTAssertFalse(blackPixels.isEmpty)
        for offset in blackPixels {
            XCTAssertEqual(Array(composite[offset..<(offset + 4)]), [0, 0, 0, 255])
        }
    }

    func testCaptureIsStableReadOnlyAndUsesLiveOrderOrientationAndExtent() throws {
        try store.update(book) { $0.orientation = "landscape" }
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke()]))
        let added = Page(background: 3), deleted = Page(background: 1)
        try store.update(book) { $0.pages.insert(added, at: 0); $0.deleted.append(deleted); $0.currentPage = page }
        let before = try store.exportPackage().encoded()
        let first = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        let second = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        XCTAssertEqual(first.context.orientation, "landscape")
        XCTAssertEqual(first.context.focusPageID, page)
        XCTAssertEqual(first.context.pages.map(\.pageID), [added.id, page])
        XCTAssertEqual(first.context.pages.map(\.width), [180, 180])
        XCTAssertEqual(first.context.pages.map(\.height), [240, 240])
        XCTAssertEqual(first.assets, second.assets)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: first.context.encoded()) as? [String: Any])
        let encodedPages = try XCTUnwrap(json["pages"] as? [[String: Any]])
        XCTAssertTrue(encodedPages[0]["head"] is NSNull)
        XCTAssertEqual(try store.exportPackage().encoded(), before)
        XCTAssertEqual(store.notebook(book)!.currentPage, page)
        XCTAssertThrowsError(try store.capturedAIContext(book: book, focusPage: deleted.id, pageSize: size))
    }
    private func addGeneratedObject(color: UIColor, text: String) throws -> AIObject {
        let request = UUID(), contextHash = String(repeating: "a", count: 64)
        let bytes = try AICapture.png(UIGraphicsImageRenderer(size: CGSize(width: 10, height: 5),
            format: AICapture.rendererFormat()).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 5))
        })
        let asset = AIAsset(sha256: AIHash.digest(bytes), pixelWidth: 20, pixelHeight: 10)
        let object = AIObject(id: UUID(), revision: 1, kind: "text", source: text,
            frame: AIFrame(x: 120, y: 90, width: 10, height: 5), style: AIStyle(), asset: asset,
            provenance: AIProvenance(requestID: request, contextSHA256: contextHash, rendererSignature: "draw-ai-render-v1"))
        let result = AIResult(requestID: request, documentID: book, contextSHA256: contextHash,
            draftVersion: 1, rendererSignature: "draw-ai-render-v1", pageEdits: [AIPageEdit(pageID: page,
                objectEdits: [AIObjectEdit(op: "add", object: object)], strokeEdits: [])],
            previewSHA256s: [page.uuidString: String(repeating: "b", count: 64)])
        _ = try store.applyAI(result, assets: [asset.sha256: bytes])
        return object
    }

    func testUnsyncedDocumentAndFolderLabelsAreCapturedWithOptionalLegacyDecoding() throws {
        let folder = try store.addFolder("Unpublished school")
        try store.moveNotebook(book, into: folder)
        try store.update(book) { $0.name = "Unsynced note" }
        let capture = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        XCTAssertEqual(capture.context.documentName, "Unsynced note")
        XCTAssertEqual(capture.context.folderName, "Unpublished school")
        XCTAssertEqual(capture.context.folderID, folder)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: capture.context.encoded()) as? [String: Any])
        XCTAssertEqual(json["documentName"] as? String, "Unsynced note")
        XCTAssertEqual(json["folderName"] as? String, "Unpublished school")
        XCTAssertEqual(json["folderID"] as? String, folder.uuidString)
        for key in ["documentName", "folderName", "folderID"] { json.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(AIContext.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.documentName)
        XCTAssertNil(legacy.folderName)
        XCTAssertNil(legacy.folderID)
        try store.deleteFolder(folder)
        let home = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        XCTAssertEqual(home.context.folderName, "Home")
        XCTAssertNil(home.context.folderID)
    }

    func testExactSyncedSourceCaptureIgnoresLaterLocalInkObjectsPagesAndLabels() throws {
        let folder = try store.addFolder("Confirmed school")
        try store.moveNotebook(book, into: folder)
        try store.update(book) { $0.name = "Confirmed note" }
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke(color: .blue)]))
        let originalObject = try addGeneratedObject(color: .blue, text: "Confirmed answer")
        let extra = Page(background: 3), deleted = Page(background: 1)
        try store.update(book) { $0.pages.insert(extra, at: 0); $0.deleted.append(deleted); $0.currentPage = page }
        _ = try store.addNotebook("Unrelated source document")
        let confirmed = try store.exportCurrentPackage() // Whole library is also supported.
        let reference = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        let confirmedHead = reference.context.pages[1].head

        // These are ordinary local changes made while upload/receipt completed.
        let localOnlyPage = Page(background: 2)
        try store.update(book) {
            $0.name = "Still writing"
            $0.orientation = "landscape"
            $0.pages[1].background = 2
            $0.deleted.append($0.pages.removeFirst())
            $0.pages.append(localOnlyPage)
        }
        try store.renameFolder(folder, to: "Renamed after Sync")
        let current = try store.drawing(book: book, page: store.notebook(book)!.pages[0])
        let later = PKStroke(ink: PKInk(.monoline, color: .red), path: stroke().path,
            transform: CGAffineTransform(translationX: 100, y: 15), randomSeed: 456)
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: current.strokes + [later]))
        let newerObject = try addGeneratedObject(color: .red, text: "New unsynced answer")
        let localBefore = try store.exportPackage().encoded()
        let localHead = store.notebook(book)!.pages[0].head
        XCTAssertNotEqual(localHead, confirmedHead)

        let pinned = try store.capturedAIContext(book: book, focusPage: page, pageSize: size, source: confirmed)
        XCTAssertEqual(pinned.context.documentName, "Confirmed note")
        XCTAssertEqual(pinned.context.folderName, "Confirmed school")
        XCTAssertEqual(pinned.context.folderID, folder)
        XCTAssertEqual(pinned.context.orientation, "portrait")
        XCTAssertEqual(pinned.context.pages.map(\.pageID), [extra.id, page])
        XCTAssertEqual(pinned.context.pages[1].head, confirmedHead)
        XCTAssertEqual(pinned.context.pages[1].objects, [originalObject])
        XCTAssertNil(pinned.assets[newerObject.asset.sha256])
        XCTAssertEqual(pinned.assets, reference.assets)
        XCTAssertEqual(try AIHash.encoded(pinned.context.pages), try AIHash.encoded(reference.context.pages))
        XCTAssertTrue(confirmed.blobs.values.allSatisfy { !pinned.assets.values.contains($0) }, "Notes context never uploads native archives")
        XCTAssertEqual(try store.exportPackage().encoded(), localBefore)
        XCTAssertEqual(store.notebook(book)!.pages[0].head, localHead)
        XCTAssertThrowsError(try store.capturedAIContext(book: book, focusPage: localOnlyPage.id,
            pageSize: size, source: confirmed)) // No fallback to a newer live focus.

        // Source bytes also work with no local notebook, archives or assets at all.
        let emptyRoot = root.appendingPathComponent("empty-receiver")
        let empty = Store(directory: emptyRoot)
        let inventory = try FileManager.default.contentsOfDirectory(atPath: emptyRoot.path)
        let independent = try empty.capturedAIContext(book: book, focusPage: page, pageSize: size, source: confirmed)
        XCTAssertEqual(independent.assets, pinned.assets)
        XCTAssertEqual(try AIHash.encoded(independent.context.pages), try AIHash.encoded(pinned.context.pages))
        XCTAssertTrue(empty.notebooks.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: emptyRoot.path), inventory)
    }

    func testSourceCaptureMissingDocumentOrInvalidArchiveFailsWithoutLiveFallback() throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke()]))
        let confirmed = try store.exportCurrentPackage(book: book)
        let other = try store.addNotebook("New local document")
        let otherPage = store.notebook(other)!.pages[0].id
        XCTAssertThrowsError(try store.capturedAIContext(book: other, focusPage: otherPage,
            pageSize: size, source: confirmed))
        var corrupt = confirmed
        corrupt.blobs[corrupt.blobs.keys.first!] = Data("broken native archive".utf8)
        let before = try store.exportPackage().encoded()
        XCTAssertThrowsError(try store.capturedAIContext(book: book, focusPage: page, pageSize: size, source: corrupt))
        XCTAssertEqual(try store.exportPackage().encoded(), before)
    }

    func testCurrentHeadCaptureCacheReusesPagesAndNeverRetainsUndoStates() throws {
        let extra = Page(background: 3)
        try store.update(book) { $0.pages.append(extra) }
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke()]))
        let original = try store.exportCurrentPackage(book: book)
        let cold = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        XCTAssertEqual(store.aiCaptureCache.lastProfiles.filter { !$0.cacheHit }.count, 2)
        let warm = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        XCTAssertEqual(store.aiCaptureCache.lastProfiles.filter(\.cacheHit).count, 2)
        XCTAssertEqual(warm.assets, cold.assets)
        XCTAssertEqual(try AIHash.encoded(warm.context.pages), try AIHash.encoded(cold.context.pages))
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke(), stroke(color: .red)]))
        let latest = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        XCTAssertEqual(store.aiCaptureCache.lastProfiles.filter { !$0.cacheHit }.map(\.pageID), [page])
        XCTAssertEqual(store.aiCaptureCache.lastProfiles.filter(\.cacheHit).map(\.pageID), [extra.id])
        // Rendering an old pinned receipt must not replace the latest cached head.
        _ = try store.capturedAIContext(book: book, focusPage: page, pageSize: size, source: original)
        let stillLatest = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        XCTAssertTrue(store.aiCaptureCache.lastProfiles.allSatisfy(\.cacheHit))
        XCTAssertEqual(stillLatest.assets, latest.assets)
        _ = try store.undo(book: book, page: page)
        let restored = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        XCTAssertEqual(store.aiCaptureCache.lastProfiles.filter { !$0.cacheHit }.map(\.pageID), [page])
        XCTAssertEqual(restored.assets, cold.assets)
        try store.update(book) { $0.pages[0].background = 2 }
        _ = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        XCTAssertEqual(store.aiCaptureCache.lastProfiles.filter { !$0.cacheHit }.map(\.pageID), [page])
        _ = try store.capturedAIContext(book: book, focusPage: page, pageSize: CGSize(width: 260, height: 200))
        XCTAssertEqual(store.aiCaptureCache.lastProfiles.filter { !$0.cacheHit }.count, 2)
    }

    func testDetachedCaptureMatchesSyncOracleAndAllowsNewerWritingWithoutChangingPinnedInk() async throws {
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke()]))
        for i in 0..<5 {
            let other = Page(background: i % 4)
            try store.update(book) { $0.pages.append(other) }
            try store.commit(book: book, page: other.id, drawing: PKDrawing(strokes: [stroke(color: .blue)]))
        }
        let pinnedSource = try store.exportCurrentPackage(book: book)
        let oldHead = store.notebook(book)!.pages[0].head
        let oldKey = try XCTUnwrap(pinnedSource.blobs.keys.first { $0.hasSuffix(oldHead!.uuidString) })
        let oldBytes = try XCTUnwrap(pinnedSource.blobs[oldKey])
        var wrote = false
        let heartbeat = Task { @MainActor in
            // First profile proves the worker already pinned its input. This is
            // not a deadline-based assertion or a timing-dependent head gate.
            while self.store.aiCaptureCache.lastProfiles.isEmpty {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try self.store.commit(book: self.book, page: self.page,
                drawing: PKDrawing(strokes: [self.stroke(), self.stroke(color: .red)]))
            wrote = true
        }
        defer { heartbeat.cancel() }
        let detached = try await store.capturedAIContextAsync(book: book, focusPage: page, pageSize: size)
        try await heartbeat.value
        XCTAssertTrue(wrote)
        XCTAssertTrue(store.aiCaptureCache.lastProfiles.allSatisfy { !$0.onMainThread })
        XCTAssertEqual(detached.context.pages[0].head, oldHead)
        XCTAssertEqual(detached.context.pages[0].strokeTargets.count, 1)
        XCTAssertNotEqual(store.notebook(book)!.pages[0].head, oldHead)
        XCTAssertEqual(try store.drawing(book: book, page: store.notebook(book)!.pages[0]).strokes.count, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(oldKey + ".pkdraw")), oldBytes)
        // Use an independent empty Store so no warm cache can hide a background
        // PencilKit rendering difference from the synchronous oracle.
        let oracle = Store(directory: root.appendingPathComponent("sync-oracle"))
        let sync = try oracle.capturedAIContext(book: book, focusPage: page, pageSize: size, source: pinnedSource)
        XCTAssertEqual(detached.assets, sync.assets)
        XCTAssertEqual(try AIHash.encoded(detached.context.pages), try AIHash.encoded(sync.context.pages))
        let currentBefore = try store.exportPackage().encoded()
        let warm = try await store.capturedAIContextAsync(book: book, focusPage: page, pageSize: size)
        XCTAssertEqual(warm.context.pages[0].strokeTargets.count, 2)
        let again = try await store.capturedAIContextAsync(book: book, focusPage: page, pageSize: size)
        XCTAssertTrue(store.aiCaptureCache.lastProfiles.allSatisfy(\.cacheHit))
        XCTAssertEqual(again.assets, warm.assets)
        XCTAssertEqual(try store.exportPackage().encoded(), currentBefore)
    }

    func testInvisibleStrokeAssetsRemainExplicitTransparentRGBA8() throws {
        let point = PKStrokePoint(location: CGPoint(x: 50, y: 50), timeOffset: 0,
            size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let transparent = PKStroke(ink: PKInk(.monoline, color: .clear),
            path: PKStrokePath(controlPoints: [point], creationDate: Date(timeIntervalSince1970: 1_700_000_000)))
        let masked = PKStroke(ink: stroke().ink, path: stroke().path,
            mask: UIBezierPath(rect: CGRect(x: 500, y: 500, width: 10, height: 10)), randomSeed: 3)
        for value in [transparent, masked] {
            let (_, asset, bytes) = try AICapture.croppedStroke(value)
            try AIAssets.validate(data: bytes, asset: asset)
            XCTAssertEqual(asset.pixelWidth, 1)
            XCTAssertEqual(asset.pixelHeight, 1)
            XCTAssertEqual(bytes[24], 8, "PNG IHDR bit depth")
            XCTAssertEqual(bytes[25], 6, "PNG IHDR must be RGBA, not optimized grayscale/RGB")
            let image = try XCTUnwrap(UIImage(data: bytes))
            XCTAssertEqual(try pixels(image), [0, 0, 0, 0])
        }
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [transparent]))
        let capture = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        let storedCount = try store.drawing(book: book, page: store.notebook(book)!.pages[0]).strokes.count
        XCTAssertEqual(capture.context.pages[0].strokeTargets.count, storedCount)
        for target in capture.context.pages[0].strokeTargets {
            try AIAssets.validate(data: XCTUnwrap(capture.assets[target.asset.sha256]), asset: target.asset)
        }
    }

    func testZeroOpacityMultiplierStrokeProducesValidatedRGBAWithoutAssumingInvisibility() throws {
        let point = PKStrokePoint(location: CGPoint(x: 50, y: 50), timeOffset: 0,
            size: CGSize(width: 4, height: 4), opacity: 0, force: 1, azimuth: 0, altitude: .pi / 2)
        let native = PKStroke(ink: PKInk(.monoline, color: .black),
            path: PKStrokePath(controlPoints: [point], creationDate: Date(timeIntervalSince1970: 1_700_000_000)))
        let before = try PortableStroke(native, includeSamples: false)
        let (_, asset, bytes) = try AICapture.croppedStroke(native)
        try AIAssets.validate(data: bytes, asset: asset)
        XCTAssertEqual(bytes[24], 8, "PNG IHDR bit depth")
        XCTAssertEqual(bytes[25], 6, "Native opacity multipliers do not change the RGBA encoding contract")
        // PencilKit can render a visible disk for this multiplier. Capture must
        // preserve native controls, not infer transparency or rewrite opacity.
        XCTAssertEqual(try PortableStroke(native, includeSamples: false).points, before.points)
    }

    func testWarmCacheCannotHideCorruptedPinnedArchiveOrObjectBytes() throws {
        let object = try addGeneratedObject(color: .blue, text: "Answer")
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke()]))
        let source = try store.exportCurrentPackage(book: book)
        _ = try store.capturedAIContext(book: book, focusPage: page, pageSize: size)
        var badArchive = source
        badArchive.blobs[badArchive.blobs.keys.first!] = Data("invalid".utf8)
        XCTAssertThrowsError(try store.capturedAIContext(book: book, focusPage: page, pageSize: size, source: badArchive))
        var badAsset = source
        badAsset.assets![object.asset.sha256] = Data("invalid".utf8)
        XCTAssertThrowsError(try store.capturedAIContext(book: book, focusPage: page, pageSize: size, source: badAsset))
        XCTAssertEqual(try store.exportCurrentPackage().encoded(), try source.encoded())
    }

}
