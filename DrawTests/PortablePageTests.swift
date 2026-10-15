import XCTest
import UIKit
import PencilKit
import CryptoKit
@testable import Draw

@MainActor
final class PortablePageTests: XCTestCase {
    private let size = CGSize(width: 240, height: 180)
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ location: CGPoint, index: Int, width: CGFloat, opacity: CGFloat = 1,
                       extended: Bool = false) -> PKStrokePoint {
        if #available(iOS 27.0, *) {
            return PKStrokePoint(location: location, timeOffset: Double(index) * 0.1,
                size: CGSize(width: width, height: width), opacity: opacity, force: 0.75,
                azimuth: 0.3, altitude: 1.2, secondaryScale: extended ? 0.8 : 1,
                threshold: extended ? 0.2 : 0, lateralJitter: extended ? 0.15 : 0)
        }
        return PKStrokePoint(location: location, timeOffset: Double(index) * 0.1,
            size: CGSize(width: width, height: width), opacity: opacity, force: 0.75,
            azimuth: 0.3, altitude: 1.2, secondaryScale: extended ? 0.8 : 1,
            threshold: extended ? 0.2 : 0)
    }

    private func stroke(_ type: PKInk.InkType = .monoline, width: CGFloat = 4,
                        color: UIColor = .black, transform: CGAffineTransform = .identity,
                        mask: UIBezierPath? = nil, extended: Bool = false) -> PKStroke {
        let locations = [CGPoint(x: 20, y: 60), CGPoint(x: 45, y: 15), CGPoint(x: 95, y: 120),
                         CGPoint(x: 140, y: 20), CGPoint(x: 200, y: 70)]
        let points = locations.enumerated().map {
            point($0.element, index: $0.offset, width: width, opacity: type == .marker ? 0.5 : 1, extended: extended)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: date)
        return PKStroke(ink: PKInk(type, color: color), path: path, transform: transform, mask: mask, randomSeed: 12345)
    }

    private func canonical(_ drawing: PKDrawing) throws -> PKDrawing {
        try PKDrawing(data: drawing.dataRepresentation())
    }

    private func decoded(_ page: PortablePage) throws -> PortablePage {
        try JSONDecoder().decode(PortablePage.self, from: page.encoded())
    }

    private func assertPoints(_ expected: [PortablePoint], _ actual: [PortablePoint],
                              nativeForceTolerance: Double = 0.0001,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(expected.count, actual.count, file: file, line: line)
        for (a, b) in zip(expected, actual) {
            XCTAssertEqual(a.values.count, 12, file: file, line: line)
            for (index, pair) in zip(a.values, b.values).enumerated() {
                // Only field 6 (force) can opt into the measured native pressure quantization allowance.
                let tolerance = index == 6 ? nativeForceTolerance : 0.0001
                XCTAssertEqual(pair.0, pair.1, accuracy: tolerance, "Point field[\(index)]", file: file, line: line)
            }
        }
    }

    private func assertReexportsEqual(_ expected: PortablePage, _ actual: PortablePage,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try expected.encoded(), try actual.encoded(), "Independent export bytes", file: file, line: line)
        XCTAssertEqual(try expected.digest(), try actual.digest(), "Independent export digest", file: file, line: line)
        XCTAssertEqual(expected.strokes.count, actual.strokes.count, file: file, line: line)
        for (a, b) in zip(expected.strokes, actual.strokes) {
            XCTAssertEqual(a.id, b.id, "Stroke ID", file: file, line: line)
            XCTAssertEqual(a.pathID, b.pathID, "Path ID", file: file, line: line)
            XCTAssertEqual(a.creationDate, b.creationDate, "Creation date", file: file, line: line)
            XCTAssertEqual(a.points, b.points, "Independent control points", file: file, line: line)
            XCTAssertEqual(a.samples, b.samples, "Independent native samples", file: file, line: line)
        }
    }

    func testIndependentSameArchiveDecodesProduceExactPortableBytesAndDigests() throws {
        let controls = stroke(.pen, width: 12, extended: true).path.map { $0 }
        let creationDate = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let path: PKStrokePath
        if #available(iOS 27.0, *) {
            path = PKStrokePath(controlPoints: controls, creationDate: creationDate, id: UUID())
        } else {
            path = PKStrokePath(controlPoints: controls, creationDate: creationDate)
        }
        let pen = PKStroke(ink: PKInk(.pen, color: QuestionInk.color), path: path, randomSeed: 87654)
        let mask = UIBezierPath(rect: CGRect(x: 35, y: 35, width: 145, height: 75))
        mask.append(UIBezierPath(rect: CGRect(x: 75, y: 45, width: 35, height: 45)))
        mask.usesEvenOddFillRule = true
        let fixture = PKDrawing(strokes: [pen, stroke(.marker, width: 20, color: .yellow,
            transform: CGAffineTransform(a: 0.9, b: 0.1, c: -0.1, d: 1.1, tx: 10, ty: 5), mask: mask)])
        for archive in [fixture.dataRepresentation(), PKDrawing().dataRepresentation()] {
            let head = UUID()
            // Separate native decodes and separate exporters, not repeated encoding of one value.
            let firstDrawing = try PKDrawing(data: archive)
            let secondDrawing = try PKDrawing(data: archive)
            let first = try PortablePage(drawing: firstDrawing, pageSize: size, head: head)
            let second = try PortablePage(drawing: secondDrawing, pageSize: size, head: head)
            try assertReexportsEqual(first, second)
            for (source, portable) in zip(firstDrawing.strokes, first.strokes) {
                XCTAssertEqual(source.path.creationDate.timeIntervalSince1970, portable.creationDate)
                if #available(iOS 27.0, *) {
                    XCTAssertEqual(source.id, portable.id)
                    XCTAssertEqual(source.path.id, portable.pathID)
                }
            }
        }
    }

    func testDeterministicJSONUsesFixedArraysAndExactBytesDigest() throws {
        let head = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let page = try PortablePage(drawing: PKDrawing(strokes: [stroke(extended: true)]), pageSize: size, head: head)
        let bytes = try page.encoded()
        XCTAssertEqual(bytes, try page.encoded())
        XCTAssertEqual(bytes, try decoded(page).encoded())
        XCTAssertEqual(try page.digest(), SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try page.digest().count, 64)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["format"] as? Int, 1)
        XCTAssertEqual(object["head"] as? String, head.uuidString)
        let strokes = try XCTUnwrap(object["strokes"] as? [[String: Any]])
        XCTAssertEqual((strokes[0]["points"] as? [[Double]])?.first?.count, 12)
        XCTAssertEqual((strokes[0]["samples"] as? [[Double]])?.first?.count, 12)
        XCTAssertEqual((strokes[0]["transform"] as? [Double])?.count, 6)
        XCTAssertEqual((strokes[0]["color"] as? [Double])?.count, 4)
        XCTAssertEqual(strokes[0]["randomSeed"] as? Int, 12345)
        XCTAssertEqual(strokes[0]["creationDate"] as? Double, date.timeIntervalSince1970)
        let empty = try PortablePage(drawing: PKDrawing(), pageSize: size)
        let emptyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: empty.encoded()) as? [String: Any])
        XCTAssertNil(emptyObject["head"])
        XCTAssertEqual(try empty.drawing().strokes.count, 0)
    }

    func testOpacityMultiplierOnePointFiveSurvivesJSONAndNativeArchives() throws {
        let json = Data("[40,50,0,4,4,1.5,1,0,1.5707963267948966,1,0,0]".utf8)
        let point = try JSONDecoder().decode(PortablePoint.self, from: json)
        try point.validate()
        XCTAssertEqual(point.values[5], 1.5)
        let decodedPoint = try JSONDecoder().decode(PortablePoint.self, from: JSONEncoder().encode(point))
        XCTAssertEqual(decodedPoint, point)
        XCTAssertEqual(try decodedPoint.point().opacity, 1.5, accuracy: 0.0001)
        let upperLimit = try JSONDecoder().decode(PortablePoint.self,
            from: Data("[40,50,0,4,4,2,1,0,1,1,0,0]".utf8))
        XCTAssertNoThrow(try upperLimit.validate())
        let overLimit = try JSONDecoder().decode(PortablePoint.self,
            from: Data("[40,50,0,4,4,2.001,1,0,1,1,0,0]".utf8))
        XCTAssertThrowsError(try overLimit.validate())
        for type in [PKInk.InkType.pen, .monoline, .marker] {
            let controls = [try point.point()]
            let path = PKStrokePath(controlPoints: controls, creationDate: date)
            let stroke = PKStroke(ink: PKInk(type, color: .black), path: path, randomSeed: 12345)
            let native = try canonical(PKDrawing(strokes: [stroke]))
            let page = try PortablePage(drawing: native, pageSize: size)
            XCTAssertEqual(page.strokes[0].points[0].values[5], 1.5, accuracy: 0.0001)
            XCTAssertEqual(page.strokes[0].samples[0].values[5], 1.5, accuracy: 0.0001)
            let restored = try canonical(decodedPageDrawing(page))
            let reexport = try PortablePage(drawing: restored, pageSize: size)
            assertPoints(page.strokes[0].points, reexport.strokes[0].points)
            XCTAssertEqual(try pixels(native), try pixels(restored), "Opacity multiplier must preserve native ink exactly")
        }
    }

    func testControlFieldsTransformsTypeColorAndSeedSurviveNativeArchives() throws {
        let transform = CGAffineTransform(a: 0.85, b: 0.2, c: -0.15, d: 1.1, tx: 14, ty: 17)
        let original = try canonical(PKDrawing(strokes: [
            stroke(.pen, width: 0.5, color: QuestionInk.color, transform: transform, extended: true),
            stroke(.marker, width: 60, color: UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.7))
        ]))
        let page = try PortablePage(drawing: original, pageSize: size)
        let reconstructed = try decoded(page).drawing()
        let archived = try canonical(reconstructed)
        let reexport = try PortablePage(drawing: archived, pageSize: size)
        XCTAssertEqual(archived.strokes.count, 2)
        for (expected, actual) in zip(page.strokes, reexport.strokes) {
            XCTAssertEqual(expected.inkType, actual.inkType)
            XCTAssertEqual(expected.transform, actual.transform)
            XCTAssertEqual(expected.randomSeed, actual.randomSeed)
            XCTAssertEqual(expected.creationDate, actual.creationDate)
            assertPoints(expected.points, actual.points)
            for (a, b) in zip(expected.color, actual.color) { XCTAssertEqual(a, b, accuracy: 0.0001) }
            if #available(iOS 27.0, *) {
                XCTAssertEqual(expected.id, actual.id)
                XCTAssertEqual(expected.pathID, actual.pathID)
            }
        }
        XCTAssertTrue(QuestionInk.matches(archived.strokes[0].ink.color))
        var noSamples = try decoded(page)
        noSamples.strokes[0].samples = []
        assertPoints(page.strokes[0].points, try PortableStroke(noSamples.drawing().strokes[0]).points)
    }

    func testPublicIDsRenderGroupsGrainOffsetsAndJitterOn27() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Public identities and render state require iOS 27") }
        let strokeID = UUID(), pathID = UUID(), groupID = UUID()
        let controls = [point(CGPoint(x: 20, y: 30), index: 0, width: 6, extended: true),
                        point(CGPoint(x: 100, y: 80), index: 1, width: 6, extended: true)]
        let path = PKStrokePath(controlPoints: controls, creationDate: date, id: pathID)
        let native = PKStroke(ink: PKInk(.pencil, color: QuestionInk.color), path: path,
            randomSeed: 0xABCDEF, id: strokeID, renderGroupID: groupID,
            renderState: PKStroke.RenderState(grainOffset: CGPoint(x: 3.25, y: -4.5)))
        let source = try canonical(PKDrawing(strokes: [native]))
        let page = try PortablePage(drawing: source, pageSize: size)
        XCTAssertEqual(page.strokes[0].id, strokeID)
        XCTAssertEqual(page.strokes[0].pathID, pathID)
        XCTAssertEqual(page.strokes[0].renderGroupID, groupID)
        XCTAssertEqual(page.strokes[0].grainOffset, [3.25, -4.5])
        XCTAssertGreaterThan(page.strokes[0].points[0].values[11], 0)
        let restored = try decoded(page).drawing().strokes[0]
        XCTAssertEqual(restored.id, strokeID)
        XCTAssertEqual(restored.path.id, pathID)
        XCTAssertEqual(restored.renderGroupID, groupID)
        XCTAssertEqual(restored.renderState?.grainOffset, CGPoint(x: 3.25, y: -4.5))
        assertPoints(page.strokes[0].points, try PortableStroke(restored).points)
    }

    func testPublicMaskCommandsAndEvenOddFillRule() throws {
        let cg = CGMutablePath()
        cg.move(to: CGPoint(x: 15, y: 20))
        cg.addLine(to: CGPoint(x: 190, y: 20))
        cg.addQuadCurve(to: CGPoint(x: 190, y: 120), control: CGPoint(x: 220, y: 60))
        cg.addCurve(to: CGPoint(x: 15, y: 120), control1: CGPoint(x: 140, y: 150), control2: CGPoint(x: 40, y: 150))
        cg.closeSubpath()
        cg.addRect(CGRect(x: 80, y: 45, width: 30, height: 25))
        let mask = UIBezierPath(cgPath: cg)
        mask.usesEvenOddFillRule = true
        let portable = try PortableMask(mask)
        XCTAssertEqual(Array(portable.commands.prefix(5)), [
            [0, 15, 20], [1, 190, 20], [2, 220, 60, 190, 120],
            [3, 140, 150, 40, 150, 15, 120], [4]
        ])
        let bytes = try JSONEncoder().encode(portable)
        let decoded = try JSONDecoder().decode(PortableMask.self, from: bytes)
        XCTAssertEqual(try PortableMask(decoded.path()), portable)
        XCTAssertTrue(try decoded.path().usesEvenOddFillRule)
        let source = try canonical(PKDrawing(strokes: [stroke(.marker, width: 60, color: .yellow,
            transform: CGAffineTransform(translationX: 10, y: 15), mask: mask)]))
        let page = try PortablePage(drawing: source, pageSize: size)
        let restored = try canonical(decodedPageDrawing(page))
        let expectedMask = try PortableMask(XCTUnwrap(source.strokes[0].mask))
        let actualMask = try PortableMask(XCTUnwrap(restored.strokes[0].mask))
        XCTAssertEqual(expectedMask.evenOdd, actualMask.evenOdd)
        XCTAssertEqual(expectedMask.commands.count, actualMask.commands.count)
        for (expected, actual) in zip(expectedMask.commands, actualMask.commands) {
            XCTAssertEqual(expected.count, actual.count)
            XCTAssertEqual(expected.first, actual.first) // Command types/topology must remain exact.
            for (a, b) in zip(expected.dropFirst(), actual.dropFirst()) {
                // Observed native PKStroke/archive mask requantization is one 0.01 pt step.
                // Allow that step plus floating-point epsilon, only after the native roundtrip.
                XCTAssertEqual(a, b, accuracy: 0.010001)
            }
        }
        let expectedPixels = try pixels(source)
        let actualPixels = try pixels(restored)
        XCTAssertEqual(expectedPixels.count, actualPixels.count)
        let differences = zip(expectedPixels, actualPixels).map { abs(Int($0) - Int($1)) }
        // At 2x, 0.01 pt coordinate rounding is subpixel; reject visible clipping changes.
        XCTAssertLessThanOrEqual(Double(differences.reduce(0, +)) / Double(differences.count), 0.5)
        XCTAssertLessThanOrEqual(differences.max() ?? 0, 8)
    }

    private func decodedPageDrawing(_ page: PortablePage) throws -> PKDrawing {
        try decoded(page).drawing()
    }

    func testNativeSamplesFollowThinTransformedCurvesAndContainEndpoints() throws {
        let transform = CGAffineTransform(a: 2, b: 0.4, c: 0.3, d: 1.5, tx: 2, ty: 3)
        let native = try canonical(PKDrawing(strokes: [stroke(.pen, width: 0.5, transform: transform)])).strokes[0]
        let portable = try PortableStroke(native)
        XCTAssertGreaterThan(portable.samples.count, portable.points.count * 20)
        XCTAssertEqual(portable.samples.first, PortablePoint(native.path.interpolatedPoint(at: 0)))
        XCTAssertEqual(portable.samples.last, PortablePoint(native.path.interpolatedPoint(at: CGFloat(native.path.count - 1))))
        XCTAssertNotEqual(portable.samples[1].values[0], portable.points[1].values[0])
        for (a, b) in zip(portable.samples, portable.samples.dropFirst()) {
            let start = CGPoint(x: a.values[0], y: a.values[1]).applying(transform)
            let end = CGPoint(x: b.values[0], y: b.values[1]).applying(transform)
            // Native distance stepping is approximate; retain a small allowance for its estimator.
            XCTAssertLessThanOrEqual(hypot(end.x - start.x, end.y - start.y), 0.18)
        }
        let single = PKStroke(ink: PKInk(.monoline), path: PKStrokePath(
            controlPoints: [point(CGPoint(x: 50, y: 50), index: 0, width: 0.5)], creationDate: date), randomSeed: 1)
        XCTAssertEqual(try PortableStroke(single).samples.count, 1)
    }

    func testSRGBResolutionIncludesGrayscaleDynamicAndDisplayP3() throws {
        let colors = [UIColor(white: 0.4, alpha: 0.6),
                      UIColor(displayP3Red: 0.7, green: 0.3, blue: 0.2, alpha: 0.8),
                      UIColor { traits in traits.userInterfaceStyle == .dark ? .white : .black }]
        for color in colors {
            let portable = try PortableStroke(stroke(color: color))
            let resolved = color.resolvedColor(with: UITraitCollection.current)
            let converted = try XCTUnwrap(resolved.cgColor.converted(
                to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components)
            XCTAssertEqual(portable.color.count, 4)
            for (a, b) in zip(portable.color, converted) { XCTAssertEqual(a, Double(max(0, min(1, b))), accuracy: 0.000001) }
            XCTAssertEqual(try PortableStroke(portable.stroke()).color, portable.color)
        }
        XCTAssertTrue(QuestionInk.matches(try PortableStroke(stroke(color: QuestionInk.color)).stroke().ink.color))
    }

    func testStoreExportsActiveDeletedEmptyAndExtendedHeadsWithoutChangingSources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory)
        let book = try store.addNotebook("Portable")
        let page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [stroke()]))
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [
            stroke(transform: CGAffineTransform(translationX: 100, y: 160))
        ]))
        try store.update(book) { $0.deleted = [$0.pages.removeFirst()]; $0.pages = [Page()] }
        let before = try store.exportPackage().digest()
        let scenes = try store.exportPortablePages(pageSize: CGSize(width: 240.25, height: 180.5))
        let regenerated = try store.exportPortablePages(pageSize: CGSize(width: 240.25, height: 180.5))
        let reopened = try Store(directory: directory).exportPortablePages(pageSize: CGSize(width: 240.25, height: 180.5))
        XCTAssertEqual(Set(scenes.keys), Set(regenerated.keys))
        XCTAssertEqual(Set(scenes.keys), Set(reopened.keys))
        let images = try store.exportPageImages(pageSize: CGSize(width: 240.25, height: 180.5))
        XCTAssertEqual(scenes.count, 2)
        for (key, scene) in scenes {
            let image = try XCTUnwrap(images[key])
            XCTAssertEqual(scene.head, image.head)
            XCTAssertEqual(scene.width * 2, Double(image.width))
            XCTAssertEqual(scene.height * 2, Double(image.height))
            XCTAssertEqual(scene.strokes.count, image.strokeCount)
            try assertReexportsEqual(scene, XCTUnwrap(regenerated[key]))
            try assertReexportsEqual(scene, XCTUnwrap(reopened[key]))
        }
        XCTAssertEqual(scenes["\(book)/\(page)"]?.head, store.notebook(book)!.deleted[0].head)
        XCTAssertGreaterThan(try XCTUnwrap(scenes["\(book)/\(page)"]).height, 180.5)
        XCTAssertEqual(try store.exportPackage().digest(), before)
        XCTAssertEqual(store.notebook(book)!.deleted[0].nodes.count, 2)
    }

    func testMixedNotebookOrientationsApplyToActiveDeletedAndCustomBaseSizes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory)
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.monoline), path: PKStrokePath(
            controlPoints: [point(CGPoint(x: 40, y: 50), index: 0, width: 4)], creationDate: date), randomSeed: 12345)])
        var books: [UUID] = []
        for name in ["Legacy portrait", "Explicit portrait", "Landscape"] {
            let book = try store.addNotebook(name)
            books.append(book)
            let active = store.notebook(book)!.pages[0].id
            let deleted = Page()
            try store.update(book) { $0.pages.append(deleted) }
            try store.commit(book: book, page: active, drawing: drawing)
            try store.commit(book: book, page: deleted.id, drawing: drawing)
            try store.update(book) { $0.deleted = [$0.pages.removeLast()] }
        }
        let base = CGSize(width: 1024, height: 1361)
        let portraitScenes = try store.exportPortablePages(pageSize: base)
        let archives = try store.exportPackage().blobs
        try store.update(books[1]) { $0.orientation = "portrait" }
        try store.update(books[2]) { $0.orientation = "landscape" }
        let scenes = try store.exportPortablePages(pageSize: base)
        let custom = try store.exportPortablePages(pageSize: CGSize(width: 240, height: 180))
        let reopened = Store(directory: directory)
        let reopenedScenes = try reopened.exportPortablePages(pageSize: base)
        XCTAssertEqual(scenes.count, 6)
        XCTAssertNil(reopened.notebook(books[0])!.orientation)
        XCTAssertEqual(reopened.notebook(books[1])!.orientation, "portrait")
        XCTAssertEqual(reopened.notebook(books[2])!.orientation, "landscape")
        for (index, bookID) in books.enumerated() {
            let book = reopened.notebook(bookID)!
            XCTAssertEqual(book.pages.count, 1)
            XCTAssertEqual(book.deleted.count, 1)
            for page in book.pages + book.deleted {
                let key = "\(bookID)/\(page.id)"
                let scene = try XCTUnwrap(scenes[key])
                XCTAssertEqual(scene.width, index == 2 ? 1361 : 1024)
                XCTAssertEqual(scene.height, index == 2 ? 1024 : 1361)
                XCTAssertEqual(scene.head, page.head)
                let customScene = try XCTUnwrap(custom[key])
                // Swap the supplied base literally, even if its width already exceeds its height.
                XCTAssertEqual(customScene.width, index == 2 ? 180 : 240)
                XCTAssertEqual(customScene.height, index == 2 ? 240 : 180)
                try assertReexportsEqual(scene, XCTUnwrap(reopenedScenes[key]))
                var original = try XCTUnwrap(portraitScenes[key])
                original.width = scene.width
                original.height = scene.height
                try assertReexportsEqual(original, scene) // Only the frame changes, never ink or heads.
                try autoreleasepool {
                    let native = try reopened.drawing(book: bookID, page: page)
                    let image = try XCTUnwrap(ruledOracleImage(native, scene: scene).cgImage)
                    XCTAssertEqual(image.width, index == 2 ? 2722 : 2048)
                    XCTAssertEqual(image.height, index == 2 ? 2048 : 2722)
                }
            }
        }
        XCTAssertEqual(try store.exportPackage().blobs, archives)
    }

    func testMalformedPointsMasksInkAndPageBoundsFailExplicitly() throws {
        for array in ["[]", "[1,2,3]", "[0,0,0,1,1,1,1,0,1,1,0,0,9]"] {
            XCTAssertThrowsError(try JSONDecoder().decode(PortablePoint.self, from: Data(array.utf8)))
        }
        var page = try PortablePage(drawing: PKDrawing(strokes: [stroke()]), pageSize: size)
        page.strokes[0].inkType = "FutureUnknownInk"
        XCTAssertThrowsError(try page.drawing())
        page.strokes[0].inkType = PKInk.InkType.monoline.rawValue
        page.strokes[0].transform = [1]
        XCTAssertThrowsError(try page.drawing())
        var mask = try PortableMask(UIBezierPath(rect: CGRect(x: 0, y: 0, width: 1, height: 1)))
        let invalidCommands: [[[Double]]] = [[[2, 1]], [[5]], [[]], [[4, 1]], [[1, .nan, 2]]]
        for commands in invalidCommands {
            mask.commands = commands
            XCTAssertThrowsError(try mask.path())
        }
        XCTAssertThrowsError(try PortablePage(drawing: PKDrawing(), pageSize: .zero))
        XCTAssertThrowsError(try PortablePage(drawing: PKDrawing(), pageSize: CGSize(width: 4096.1, height: 100)))
        let boundary = try PortablePage(drawing: PKDrawing(), pageSize: CGSize(width: 4096, height: 4096))
        XCTAssertEqual(boundary.width, 4096)
        var invalid = boundary
        invalid.format = 2
        XCTAssertThrowsError(try invalid.drawing())
    }

    func testStrokeFingerprintExcludesIDsAndSamplesButIncludesCompleteRenderingData() throws {
        let mask = UIBezierPath(rect: CGRect(x: 30, y: 20, width: 150, height: 90))
        var base = try PortableStroke(stroke(.pencil, width: 6, color: .purple,
            transform: CGAffineTransform(a: 0.9, b: 0.1, c: -0.2, d: 1.1, tx: 5, ty: 9), mask: mask, extended: true))
        let fingerprint = try base.fingerprint()
        base.id = UUID(); base.pathID = UUID(); base.renderGroupID = UUID(); base.samples = []
        XCTAssertEqual(try base.fingerprint(), fingerprint)
        var mutations: [PortableStroke] = []
        var changed = base; changed.color[0] = 0.25; mutations.append(changed)
        changed = base; changed.transform[4] += 1; mutations.append(changed)
        changed = base; changed.randomSeed += 1; mutations.append(changed)
        changed = base; changed.creationDate += 1; mutations.append(changed)
        changed = base; changed.grainOffset = [2, 3]; mutations.append(changed)
        changed = base; changed.mask!.evenOdd.toggle(); mutations.append(changed)
        changed = base; changed.mask!.commands[0][1] += 1; mutations.append(changed)
        changed = base; changed.inkType = PKInk.InkType.monoline.rawValue; mutations.append(changed)
        changed = base
        changed.points[0] = PortablePoint(point(CGPoint(x: 21, y: 60), index: 0, width: 6, extended: true))
        mutations.append(changed)
        for value in mutations { XCTAssertNotEqual(try value.fingerprint(), fingerprint) }
        let noSamples = try PortableStroke(stroke(), includeSamples: false)
        XCTAssertTrue(noSamples.samples.isEmpty)
        XCTAssertEqual(try noSamples.fingerprint(), try PortableStroke(stroke()).fingerprint())
    }

    func testLegacyPortableSceneOmitsNewFieldsUntilExplicitlySet() throws {
        var scene = try PortablePage(drawing: PKDrawing(), pageSize: size)
        let original = try scene.encoded()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        XCTAssertNil(json["background"])
        XCTAssertNil(json["objects"])
        XCTAssertEqual(original, try decoded(scene).encoded())
        scene.background = 0
        XCTAssertNotEqual(try scene.encoded(), original)
        XCTAssertEqual(try decoded(scene).background, 0)
        scene.background = 4
        XCTAssertThrowsError(try scene.validate())
    }

    private func pixels(_ drawing: PKDrawing) throws -> Data {
        let rect = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(rect)
            drawing.image(from: rect, scale: 2).draw(in: rect)
        }
        let cg = try XCTUnwrap(image.cgImage)
        var data = Data(count: cg.width * cg.height * 4)
        try data.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return data
    }

    func testSmallDeterministicNativeImagesMatchPortableReconstruction() throws {
        let mask = UIBezierPath(rect: CGRect(x: 30, y: 20, width: 150, height: 95))
        mask.append(UIBezierPath(rect: CGRect(x: 75, y: 45, width: 30, height: 30)))
        mask.usesEvenOddFillRule = true
        let fixtures = [
            PKDrawing(strokes: [stroke(.pen, width: 0.5), stroke(width: 12, color: QuestionInk.color,
                transform: CGAffineTransform(translationX: 8, y: 28))]),
            PKDrawing(strokes: [stroke(.marker, width: 8, color: .yellow),
                stroke(.marker, width: 60, color: .cyan, transform: CGAffineTransform(translationX: 0, y: 25))]),
            PKDrawing(strokes: [stroke(.marker, width: 60, color: .yellow,
                transform: CGAffineTransform(a: 0.9, b: 0.1, c: -0.1, d: 0.9, tx: 10, ty: 10), mask: mask)])
        ]
        for (index, fixture) in fixtures.enumerated() {
            let native = try canonical(fixture)
            let scene = try PortablePage(drawing: native, pageSize: size)
            let restored = try canonical(decodedPageDrawing(scene))
            let expected = try pixels(native)
            XCTAssertEqual(expected, try pixels(native), "Native fixture must render deterministically")
            XCTAssertGreaterThan(expected.filter { $0 < 240 }.count, 20, "Fixture must contain visible ink")
            let actual = try pixels(restored)
            XCTAssertEqual(expected.count, actual.count)
            let differences = zip(expected, actual).map { abs(Int($0) - Int($1)) }
            XCTAssertLessThanOrEqual(Double(differences.reduce(0, +)) / Double(differences.count), 0.5,
                                     "Portable reconstruction changed native fixture \(index)")
            XCTAssertLessThanOrEqual(differences.max() ?? 0, 8, "A local ink feature changed")
            let attachment = XCTAttachment(data: try scene.encoded(), uniformTypeIdentifier: "public.json")
            attachment.name = "portable-native-fixture-\(index).json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testCumulativeGeometryBudgetAndValidationFailWithoutTruncation() throws {
        let original = try PortablePage(drawing: PKDrawing(strokes: [stroke()]), pageSize: size)
        let sample = try XCTUnwrap(original.strokes[0].samples.first)
        var page = try decoded(original)
        var first = page.strokes[0]
        first.samples = Array(repeating: sample, count: PortablePage.maximumGeometryCount / 2)
        page.strokes = [first, first]
        XCTAssertThrowsError(try page.validate())
        XCTAssertThrowsError(try page.encoded())
        XCTAssertThrowsError(try page.drawing())
        XCTAssertEqual(page.strokes[0].samples.count, PortablePage.maximumGeometryCount / 2)
        XCTAssertThrowsError(try PortableStroke(stroke(), geometryLimit: 10))
        XCTAssertEqual(try original.encoded(), try decoded(original).encoded())
        let invalid = try JSONDecoder().decode(PortablePoint.self,
            from: Data("[0,0,0,-1,1,1,1,0,1,1,0,0]".utf8))
        page = try decoded(original)
        page.strokes[0].samples = [invalid]
        XCTAssertThrowsError(try page.validate())
        XCTAssertThrowsError(try page.encoded())
    }

    private func oracleUUID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", UInt64(number)))!
    }

    private func oracleStroke(_ type: PKInk.InkType, width: CGFloat, number: Int,
                              horizontal: Bool = false, color: UIColor = .black,
                              transform: CGAffineTransform = .identity, mask: UIBezierPath? = nil,
                              group: UUID? = nil) -> PKStroke {
        let locations = horizontal
            ? [CGPoint(x: 20, y: 72), CGPoint(x: 200, y: 72)]
            : [CGPoint(x: 20, y: 60), CGPoint(x: 45, y: 15), CGPoint(x: 95, y: 120),
               CGPoint(x: 140, y: 20), CGPoint(x: 200, y: 70)]
        let controls = locations.enumerated().map {
            point($0.element, index: $0.offset, width: width, opacity: type == .marker ? 0.5 : 1)
        }
        if #available(iOS 27.0, *) {
            let path = PKStrokePath(controlPoints: controls, creationDate: date, id: oracleUUID(10_000 + number))
            return PKStroke(ink: PKInk(type, color: color), path: path, transform: transform, mask: mask,
                randomSeed: UInt32(number), id: oracleUUID(20_000 + number), renderGroupID: group)
        }
        let path = PKStrokePath(controlPoints: controls, creationDate: date)
        return PKStroke(ink: PKInk(type, color: color), path: path, transform: transform, mask: mask,
                        randomSeed: UInt32(number))
    }

    private func ruledOracleImage(_ drawing: PKDrawing, scene: PortablePage) -> UIImage {
        // Keep this sequence identical to Store.exportPageImages, including integral sizing and 2x ink.
        let rect = CGRect(x: 0, y: 0, width: scene.width, height: scene.height).integral
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(rect)
            context.cgContext.setStrokeColor(UIColor(white: 0.88, alpha: 1).cgColor)
            context.cgContext.setLineWidth(0.5)
            for y in stride(from: PaperView.spacing, through: rect.height, by: PaperView.spacing) {
                context.cgContext.move(to: CGPoint(x: 0, y: y))
                context.cgContext.addLine(to: CGPoint(x: rect.width, y: y))
            }
            context.cgContext.strokePath()
            drawing.image(from: rect, scale: 2).draw(in: rect)
        }
    }

    func testWritePortableRenderOracles() throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PortableRenderOracles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(PaperView.spacing, 36)
        var fixtures: [(String, PKDrawing)] = []
        var number = 1
        for (name, type) in [("pen", PKInk.InkType.pen), ("monoline", PKInk.InkType.monoline)] {
            for (widthName, width) in [("0p5", CGFloat(0.5)), ("4", CGFloat(4)), ("12", CGFloat(12))] {
                for horizontal in [false, true] {
                    let stroke = oracleStroke(type, width: width, number: number, horizontal: horizontal)
                    fixtures.append(("\(name)-\(widthName)-\(horizontal ? "horizontal" : "curve")", PKDrawing(strokes: [stroke])))
                    number += 1
                }
            }
        }
        fixtures.append(("marker-8-curve", PKDrawing(strokes: [
            oracleStroke(.marker, width: 8, number: 100, color: .yellow)
        ])))
        fixtures.append(("marker-60-horizontal", PKDrawing(strokes: [
            oracleStroke(.marker, width: 60, number: 101, horizontal: true, color: .yellow)
        ])))
        fixtures.append(("marker-overlaps", PKDrawing(strokes: [
            oracleStroke(.marker, width: 20, number: 102, horizontal: true, color: .yellow),
            oracleStroke(.marker, width: 20, number: 103, horizontal: true, color: .yellow,
                         transform: CGAffineTransform(translationX: 20, y: 8)),
            oracleStroke(.marker, width: 20, number: 104, color: .cyan)
        ])))
        if #available(iOS 27.0, *) {
            fixtures.append(("marker-wet-overlaps", PKDrawing(strokes: [
                oracleStroke(.marker, width: 20, number: 105, horizontal: true, color: .yellow, group: oracleUUID(30_000)),
                oracleStroke(.marker, width: 20, number: 106, horizontal: true, color: .yellow,
                    transform: CGAffineTransform(translationX: 20, y: 8), group: oracleUUID(30_000))
            ])))
        }
        fixtures.append(("affine-transforms", PKDrawing(strokes: [
            oracleStroke(.monoline, width: 0.5, number: 110,
                transform: CGAffineTransform(a: 1.1, b: 0.2, c: 0.3, d: 0.9, tx: 15, ty: 10)),
            oracleStroke(.pen, width: 4, number: 111, color: .blue,
                transform: CGAffineTransform(a: -0.9, b: 0.1, c: 0.2, d: 1.2, tx: 210, ty: 20)),
            oracleStroke(.marker, width: 20, number: 112, color: .yellow,
                transform: CGAffineTransform(a: 0.8, b: 0.3, c: -0.2, d: 1.1, tx: 30, ty: 40))
        ])))
        let clip = CGMutablePath()
        clip.move(to: CGPoint(x: 30, y: 20))
        clip.addLine(to: CGPoint(x: 170, y: 20))
        clip.addQuadCurve(to: CGPoint(x: 190, y: 110), control: CGPoint(x: 215, y: 60))
        clip.addCurve(to: CGPoint(x: 30, y: 110), control1: CGPoint(x: 140, y: 130), control2: CGPoint(x: 50, y: 130))
        clip.closeSubpath()
        let mask = UIBezierPath(cgPath: clip)
        fixtures.append(("clip-commands", PKDrawing(strokes: [
            oracleStroke(.marker, width: 60, number: 120, color: .yellow,
                transform: CGAffineTransform(translationX: 10, y: 20), mask: mask)
        ])))
        let evenOdd = UIBezierPath(rect: CGRect(x: 35, y: 35, width: 145, height: 75))
        evenOdd.append(UIBezierPath(rect: CGRect(x: 75, y: 45, width: 35, height: 45)))
        evenOdd.usesEvenOddFillRule = true
        fixtures.append(("clip-even-odd", PKDrawing(strokes: [
            oracleStroke(.marker, width: 60, number: 121, horizontal: true, color: .cyan, mask: evenOdd)
        ])))
        fixtures.append(("question-color", PKDrawing(strokes: [
            oracleStroke(.monoline, width: 4, number: 130, color: QuestionInk.color),
            oracleStroke(.marker, width: 20, number: 131, horizontal: true, color: QuestionInk.color,
                         transform: CGAffineTransform(translationX: 0, y: 50))
        ])))
        fixtures.append(("blank", PKDrawing()))
        let validationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: validationRoot) }
        let store = Store(directory: validationRoot)
        let book = try store.addNotebook("Oracle image validation")
        let pageID = store.notebook(book)!.pages[0].id
        for (index, fixture) in fixtures.enumerated() {
            let (name, drawing) = fixture
            let native = try canonical(drawing)
            let scene = try PortablePage(drawing: native, pageSize: CGSize(width: 320, height: 240),
                                         head: oracleUUID(40_000 + index))
            let json = try scene.encoded()
            let png = try XCTUnwrap(ruledOracleImage(native, scene: scene).pngData())
            XCTAssertEqual(json, try PortablePage(drawing: native, pageSize: CGSize(width: 320, height: 240),
                                                  head: scene.head).encoded())
            XCTAssertEqual(png, try XCTUnwrap(ruledOracleImage(native, scene: scene).pngData()))
            try store.commit(book: book, page: pageID, drawing: native)
            let exported = try XCTUnwrap(store.exportPageImages(pageSize: CGSize(width: 320, height: 240))["\(book)/\(pageID)"])
            XCTAssertEqual(png, exported.png, "Oracle paper/ink rendering must match PageImages")
            XCTAssertEqual(UIImage(data: png)?.cgImage?.width, Int(scene.width * 2))
            XCTAssertEqual(UIImage(data: png)?.cgImage?.height, Int(scene.height * 2))
            try json.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
            try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        }
        let locator = XCTAttachment(string: directory.path)
        locator.name = "PortableRenderOracles-folder"
        locator.lifetime = .keepAlways
        add(locator)
    }

    private struct DiagnosticCrossSection: Codable {
        var x: Double
        // Rows: [yPt, blankR, blankG, blankB, renderedR, renderedG, renderedB, equivalentOpacity].
        // RGB is encoded sRGB in [0,1]. Opacity is a least-squares source-over equivalent,
        // not a claim about the shader's physical opacity or linear-light compositing.
        var rows: [[Double]]
        var peakEquivalentOpacity: Double
        var equivalentWidth: Double
        // For each threshold: [threshold, spanPt, occupiedPt].
        var thresholdWidths: [[Double]]
    }

    private struct NativeBrushDiagnostic: Codable {
        var name: String
        var inkType: String
        var requestedSize: Double
        var requestedOpacity: Double
        var sourceUnmaskedRenderBounds: [Double]?
        var canonicalUnmaskedRenderBounds: [Double]?
        var controlAttributeRanges: [String: [Double]]
        var sampledAttributeRanges: [String: [Double]]
        var sourceControls: [[Double]]
        var canonicalControls: [[Double]]
        var controlCount: Int
        var sampleCount: Int
        var sourceID: UUID?
        var sourcePathID: UUID?
        var freshReplicaID: UUID?
        var freshReplicaPathID: UUID?
        var replicaMaximumChannelDifference: Int
        var replicaMeanChannelDifference: Double
        var blankSubtractedPixelBounds: [Double]?
        var sections: [DiagnosticCrossSection]
    }

    private struct NativeBrushDiagnostics: Codable {
        var runID: UUID
        var operatingSystem: String
        var pixelScale: Double
        var opacityDefinition: String
        var sources: [String]
        var strokes: [NativeBrushDiagnostic]
    }

    private struct DiagnosticRaster {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        func rgb(x: Int, y: Int) -> [Double] {
            let offset = (y * width + x) * 4
            return (0..<3).map { Double(bytes[offset + $0]) / 255 }
        }
    }

    private func diagnosticRaster(_ image: UIImage) throws -> DiagnosticRaster {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return DiagnosticRaster(width: cg.width, height: cg.height, bytes: bytes)
    }

    private func diagnosticStroke(_ type: PKInk.InkType, width: CGFloat) -> PKStroke {
        // Same non-size attributes as the original oracles; fresh identities on every construction.
        // A horizontal line centered in the bitmap makes a vertical cross-section unambiguous.
        let controls = [CGPoint(x: 40, y: 128), CGPoint(x: 280, y: 128)].enumerated().map {
            point($0.element, index: $0.offset, width: width, opacity: type == .marker ? 0.5 : 1)
        }
        let ink = PKInk(type, color: type == .marker ? .yellow : .black)
        if #available(iOS 27.0, *) {
            let path = PKStrokePath(controlPoints: controls, creationDate: date, id: UUID())
            return PKStroke(ink: ink, path: path, randomSeed: 12345, id: UUID())
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controls, creationDate: date), randomSeed: 12345)
    }

    private func diagnosticBounds(_ rect: CGRect) -> [Double]? {
        guard !rect.isNull else { return nil }
        return [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
    }

    private func diagnosticRanges(_ points: [PortablePoint]) -> [String: [Double]] {
        let fields = [("width", 3), ("height", 4), ("opacity", 5), ("force", 6),
                      ("azimuth", 7), ("altitude", 8), ("secondaryScale", 9), ("threshold", 10), ("lateralJitter", 11)]
        var result: [String: [Double]] = [:]
        for (name, index) in fields {
            let values = points.map { $0.values[index] }
            if let minimum = values.min(), let maximum = values.max() { result[name] = [minimum, maximum] }
        }
        return result
    }

    private func diagnosticSections(_ rendered: DiagnosticRaster, blank: DiagnosticRaster,
                                    color: [Double]) -> [DiagnosticCrossSection] {
        // Three centerline columns expose marker's spatially varying texture instead of hiding it
        // in an average. Blank subtraction removes ruled-paper contributions at each exact pixel.
        return [80.0, 160.0, 240.0].map { x in
            var rows: [[Double]] = []
            var coverage: [Double] = []
            for y in 0..<rendered.height {
                let background = blank.rgb(x: Int(x * 2), y: y)
                let output = rendered.rgb(x: Int(x * 2), y: y)
                let contrast = zip(background, color.prefix(3)).map { $0 - $1 }
                let loss = zip(background, output).map { $0 - $1 }
                let denominator = contrast.reduce(0) { $0 + $1 * $1 }
                let numerator = zip(contrast, loss).reduce(0) { $0 + $1.0 * $1.1 }
                let opacity = denominator > 0 ? max(0, min(1, numerator / denominator)) : 0
                coverage.append(opacity)
                rows.append([Double(y) / 2 + 0.25] + background + output + [opacity])
            }
            let widths: [[Double]] = [1.0 / 255, 0.1, 0.5, 0.9].map { threshold in
                let occupied = coverage.indices.filter { coverage[$0] > threshold }
                let span = occupied.first.flatMap { first in occupied.last.map { Double($0 - first + 1) / 2 } } ?? 0
                return [threshold, span, Double(occupied.count) / 2]
            }
            return DiagnosticCrossSection(x: x, rows: rows, peakEquivalentOpacity: coverage.max() ?? 0,
                equivalentWidth: coverage.reduce(0, +) / 2, thresholdWidths: widths)
        }
    }

    private func blankSubtractedBounds(_ rendered: DiagnosticRaster, blank: DiagnosticRaster) -> [Double]? {
        var minX = rendered.width, minY = rendered.height, maxX = -1, maxY = -1
        for y in 0..<rendered.height {
            for x in 0..<rendered.width {
                let offset = (y * rendered.width + x) * 4
                let changed = (0..<3).contains {
                    abs(Int(rendered.bytes[offset + $0]) - Int(blank.bytes[offset + $0])) > 0
                }
                if changed {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return [Double(minX) / 2, Double(minY) / 2, Double(maxX - minX + 1) / 2, Double(maxY - minY + 1) / 2]
    }

    func testWriteNativeBrushDiagnosticOracles() throws {
        let runID = UUID()
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PortableRenderOracles/BrushDiagnostics", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pageSize = CGSize(width: 320, height: 256)
        let blankScene = try PortablePage(drawing: PKDrawing(), pageSize: pageSize)
        let blankImage = ruledOracleImage(PKDrawing(), scene: blankScene)
        try blankScene.encoded().write(to: directory.appendingPathComponent("blank.json"), options: .atomic)
        try XCTUnwrap(blankImage.pngData()).write(to: directory.appendingPathComponent("blank.png"), options: .atomic)
        var diagnostics: [NativeBrushDiagnostic] = []
        var seenIDs: Set<UUID> = [], seenPathIDs: Set<UUID> = []
        for type in [PKInk.InkType.pen, .monoline, .marker] {
            let sizes: [CGFloat] = type == .marker ? [8, 20, 60] : [0.5, 1, 2, 3, 4, 6, 8, 10, 12]
            for width in sizes {
                let label = width == 0.5 ? "0p5" : String(Int(width))
                let name = (type == .pen ? "pen" : type == .monoline ? "monoline" : "marker") + "-" + label
                let source = diagnosticStroke(type, width: width)
                let replica = diagnosticStroke(type, width: width)
                XCTAssertNil(source.mask)
                XCTAssertEqual(source.transform, .identity)
                let canonicalSource = try canonical(PKDrawing(strokes: [source]))
                let scene = try PortablePage(drawing: canonicalSource, pageSize: pageSize)
                let portable = try XCTUnwrap(scene.strokes.first)
                let canonicalReplica = try canonical(PKDrawing(strokes: [replica]))
                let replicaScene = try PortablePage(drawing: canonicalReplica, pageSize: pageSize)
                let replicaPortable = try XCTUnwrap(replicaScene.strokes.first)
                XCTAssertEqual(portable.points, replicaPortable.points)
                XCTAssertEqual(portable.samples, replicaPortable.samples)
                XCTAssertEqual(portable.color, replicaPortable.color)
                XCTAssertEqual(portable.randomSeed, replicaPortable.randomSeed)
                if #available(iOS 27.0, *) {
                    for stroke in [source, replica] {
                        XCTAssertTrue(seenIDs.insert(stroke.id).inserted)
                        XCTAssertTrue(seenPathIDs.insert(stroke.path.id).inserted)
                    }
                }
                let image = ruledOracleImage(canonicalSource, scene: scene)
                let replicaImage = ruledOracleImage(canonicalReplica, scene: replicaScene)
                let raster = try diagnosticRaster(image)
                let replicaRaster = try diagnosticRaster(replicaImage)
                // Bounds may expand past the nominal page for large brushes. Always subtract a
                // same-size native paper image rather than cropping or indexing a smaller blank.
                let matchedBlankScene = try PortablePage(drawing: PKDrawing(),
                    pageSize: CGSize(width: scene.width, height: scene.height))
                let matchedBlankImage = ruledOracleImage(PKDrawing(), scene: matchedBlankScene)
                let blank = try diagnosticRaster(matchedBlankImage)
                guard raster.width == replicaRaster.width, raster.height == replicaRaster.height else {
                    XCTFail("Fresh replicas unexpectedly changed scene extents")
                    throw PortablePageError.invalidData
                }
                let differences = zip(raster.bytes, replicaRaster.bytes).map { abs(Int($0) - Int($1)) }
                let row = NativeBrushDiagnostic(name: name, inkType: portable.inkType,
                    requestedSize: Double(width), requestedOpacity: type == .marker ? 0.5 : 1,
                    sourceUnmaskedRenderBounds: diagnosticBounds(source.renderBounds),
                    canonicalUnmaskedRenderBounds: diagnosticBounds(canonicalSource.strokes[0].renderBounds),
                    controlAttributeRanges: diagnosticRanges(portable.points),
                    sampledAttributeRanges: diagnosticRanges(portable.samples),
                    sourceControls: source.path.map { PortablePoint($0).values },
                    canonicalControls: portable.points.map { $0.values },
                    controlCount: portable.points.count, sampleCount: portable.samples.count,
                    sourceID: portable.id, sourcePathID: portable.pathID,
                    freshReplicaID: replicaPortable.id, freshReplicaPathID: replicaPortable.pathID,
                    replicaMaximumChannelDifference: differences.max() ?? 0,
                    replicaMeanChannelDifference: Double(differences.reduce(0, +)) / Double(differences.count),
                    blankSubtractedPixelBounds: blankSubtractedBounds(raster, blank: blank),
                    sections: diagnosticSections(raster, blank: blank, color: portable.color))
                diagnostics.append(row)
                try scene.encoded().write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
                try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
                try XCTUnwrap(replicaImage.pngData()).write(to: directory.appendingPathComponent(name + "-fresh-replica.png"), options: .atomic)
                try XCTUnwrap(matchedBlankImage.pngData()).write(to: directory.appendingPathComponent(name + "-blank.png"), options: .atomic)
            }
        }
        let result = NativeBrushDiagnostics(runID: runID, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            pixelScale: 2, opacityDefinition: "Equivalent source-over opacity in encoded sRGB, fitted against matched ruled blank; not shader opacity. Rows use normalized bitmap coordinates; stroke is centered at y=128pt.",
            sources: ["https://developer.apple.com/documentation/pencilkit/pkstrokepoint-swift.struct/size",
                      "https://developer.apple.com/documentation/pencilkit/pkstrokepoint-swift.struct/opacity",
                      "https://developer.apple.com/documentation/pencilkit/pkstroke-swift.struct/renderbounds",
                      "https://developer.apple.com/documentation/pencilkit/pkinkingtool-swift.struct/width"],
            strokes: diagnostics)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(result).write(to: directory.appendingPathComponent("diagnostics.json"), options: .atomic)
        let locator = XCTAttachment(string: directory.path)
        locator.name = "NativeBrushDiagnostics-folder"
        locator.lifetime = .keepAlways
        add(locator)
    }

    private struct StoredPageRenderInput: Decodable {
        var name: String
        var file: String
        var width: Double
        var height: Double
        var head: UUID?
    }

    private struct StoredPageRenderMetrics: Codable {
        var file: String
        var head: UUID?
        var archiveDigest: String
        var portableDigest: String
        var width: Double
        var height: Double
        var strokeCount: Int
        var controlCount: Int
        var sampleCount: Int
        var meanRGBChannelDifference: Double
        var maximumRGBChannelDifference: Int
        var changedRGBChannelFraction: Double
    }

    private func isOracleBasename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }

    func testWriteStoredPageRenderOracles() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inputs = documents.appendingPathComponent("PortableRenderInputs", isDirectory: true)
        let metadata = inputs.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: metadata.path) else {
            throw XCTSkip("No staged Documents/PortableRenderInputs/metadata.json")
        }
        let pages = try JSONDecoder().decode([StoredPageRenderInput].self, from: Data(contentsOf: metadata))
        guard !pages.isEmpty else { throw XCTSkip("PortableRenderInputs metadata has no pages") }
        guard Set(pages.map { $0.name }).count == pages.count,
              pages.allSatisfy({ isOracleBasename($0.name) && isOracleBasename($0.file)
                  && URL(fileURLWithPath: $0.file).pathExtension.lowercased() == "pkdraw"
                  && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
                  && $0.width <= 4096 && $0.height <= 4096 }) else {
            XCTFail("Input names must be unique; names/files must be basenames and dimensions logical points in (0,4096]")
            throw PortablePageError.invalidData
        }
        let output = documents.appendingPathComponent("PortableRenderOracles/RealPages", isDirectory: true)
        let reconstructedOutput = output.appendingPathComponent("Reconstructed", isDirectory: true)
        let metricsOutput = output.appendingPathComponent("Metrics", isDirectory: true)
        for directory in [output, reconstructedOutput, metricsOutput] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for input in pages {
            try autoreleasepool {
                // Read staged copies only. Never instantiate the production Store or write an archive.
                let archiveURL = inputs.appendingPathComponent(input.file)
                let archive = try Data(contentsOf: archiveURL)
                let native = try canonical(PKDrawing(data: archive))
                let pageSize = CGSize(width: input.width, height: input.height)
                let exported = try PortablePage(drawing: native, pageSize: pageSize, head: input.head)
                // Decode the SAME original archive again, with the identical canonicalization path.
                // Native reconstruction quantization allowances do not apply to unchanged re-export.
                let independentlyDecoded = try canonical(PKDrawing(data: archive))
                let independentlyExported = try PortablePage(drawing: independentlyDecoded,
                    pageSize: pageSize, head: input.head)
                try assertReexportsEqual(exported, independentlyExported)
                let scene = try decoded(exported)
                let json = try scene.encoded()
                XCTAssertEqual(json, try exported.encoded(), input.name)
                XCTAssertEqual(exported.strokes.count, scene.strokes.count, input.name)
                for (before, after) in zip(exported.strokes, scene.strokes) {
                    // JSON decoding precedes any PKStrokePoint/PKStrokePath constructor: exact fields.
                    XCTAssertEqual(before.points, after.points, input.name)
                    XCTAssertEqual(before.samples, after.samples, input.name)
                }
                XCTAssertEqual(scene.head, input.head, input.name)
                // Metadata supplies the complete logical extent; never silently crop overflowing ink.
                XCTAssertEqual(scene.width, ceil(input.width), "Incomplete input extent: " + input.name)
                XCTAssertEqual(scene.height, ceil(input.height), "Incomplete input extent: " + input.name)
                let originalImage = ruledOracleImage(native, scene: scene)
                try json.write(to: output.appendingPathComponent(input.name + ".json"), options: .atomic)
                try XCTUnwrap(originalImage.pngData()).write(
                    to: output.appendingPathComponent(input.name + ".png"), options: .atomic)
                let restored = try canonical(scene.drawing())
                let restoredImage = ruledOracleImage(restored, scene: scene)
                try XCTUnwrap(restoredImage.pngData()).write(
                    to: reconstructedOutput.appendingPathComponent(input.name + ".png"), options: .atomic)
                XCTAssertEqual(native.strokes.count, scene.strokes.count, input.name)
                XCTAssertEqual(restored.strokes.count, scene.strokes.count, input.name)
                for (pair, expected) in zip(zip(native.strokes, restored.strokes), scene.strokes) {
                    assertPoints(pair.0.path.map { PortablePoint($0) }, expected.points)
                    // Field diagnostics on these real archives show force changing by at most
                    // 0.001 after native construction/rearchiving. Allow that measured pressure
                    // quantization step plus 0.000001 epsilon; all other fields stay tight.
                    assertPoints(expected.points, pair.1.path.map { PortablePoint($0) },
                                 nativeForceTolerance: 0.001001)
                    XCTAssertEqual(pair.0.ink.inkType, pair.1.ink.inkType, input.name)
                    XCTAssertEqual(pair.0.transform, pair.1.transform, input.name)
                    XCTAssertEqual(pair.0.randomSeed, pair.1.randomSeed, input.name)
                    XCTAssertEqual(pair.0.path.creationDate.timeIntervalSince1970,
                                   pair.1.path.creationDate.timeIntervalSince1970, input.name)
                    if #available(iOS 27.0, *) {
                        XCTAssertEqual(pair.0.id, pair.1.id, input.name)
                        XCTAssertEqual(pair.0.path.id, pair.1.path.id, input.name)
                        XCTAssertEqual(pair.0.renderGroupID, pair.1.renderGroupID, input.name)
                        XCTAssertEqual(pair.0.renderState?.grainOffset, pair.1.renderState?.grainOffset, input.name)
                    }
                }
                let expectedPixels = try diagnosticRaster(originalImage)
                let actualPixels = try diagnosticRaster(restoredImage)
                XCTAssertEqual(expectedPixels.width, Int(scene.width * 2), input.name)
                XCTAssertEqual(expectedPixels.height, Int(scene.height * 2), input.name)
                guard expectedPixels.width == actualPixels.width, expectedPixels.height == actualPixels.height else {
                    XCTFail("Reconstruction changed image extent: " + input.name)
                    throw PortablePageError.invalidData
                }
                // Stream the comparison rather than allocating an Int array for full-size real pages.
                var total = 0, maximum = 0, changed = 0
                for offset in stride(from: 0, to: expectedPixels.bytes.count, by: 4) {
                    for channel in 0..<3 {
                        let delta = abs(Int(expectedPixels.bytes[offset + channel]) - Int(actualPixels.bytes[offset + channel]))
                        total += delta
                        maximum = max(maximum, delta)
                        if delta > 0 { changed += 1 }
                    }
                }
                let channelCount = expectedPixels.width * expectedPixels.height * 3
                let mean = Double(total) / Double(channelCount)
                let metrics = StoredPageRenderMetrics(file: input.file, head: scene.head,
                    archiveDigest: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
                    portableDigest: try scene.digest(), width: scene.width, height: scene.height,
                    strokeCount: scene.strokes.count, controlCount: scene.strokes.reduce(0) { $0 + $1.points.count },
                    sampleCount: scene.strokes.reduce(0) { $0 + $1.samples.count }, meanRGBChannelDifference: mean,
                    maximumRGBChannelDifference: maximum, changedRGBChannelFraction: Double(changed) / Double(channelCount))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(metrics).write(to: metricsOutput.appendingPathComponent(input.name + ".json"), options: .atomic)
                // Same small native quantization allowance as the mask fixture, no looser controls.
                XCTAssertLessThanOrEqual(mean, 0.5, "Native reconstruction image: " + input.name)
                XCTAssertLessThanOrEqual(maximum, 8, "Native reconstruction image: " + input.name)
                XCTAssertEqual(try Data(contentsOf: archiveURL), archive, "Input archive changed: " + input.name)
            }
        }
        let locator = XCTAttachment(string: output.path)
        locator.name = "StoredPageRenderOracles-folder"
        locator.lifetime = .keepAlways
        add(locator)
    }
}
