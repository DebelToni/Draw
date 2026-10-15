import XCTest
import PencilKit
@testable import Draw

@MainActor
final class PageImageTests: XCTestCase {
    func testMarkerMasksAndSelectionTransformsSurviveHistoryReopenAndImages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory)
        let book = try store.addNotebook("Marker")
        let page = store.notebook(book)!.pages[0].id
        let points = [CGPoint(x: 30, y: 50), CGPoint(x: 150, y: 50)].enumerated().map { i, point in
            PKStrokePoint(location: point, timeOffset: Double(i) / 10, size: CGSize(width: 20, height: 20), opacity: 0.5, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.marker, color: .systemYellow), path: PKStrokePath(controlPoints: points, creationDate: Date()), mask: UIBezierPath(rect: CGRect(x: 50, y: 30, width: 100, height: 40)))
        let original = PKDrawing(strokes: [stroke])
        try store.commit(book: book, page: page, drawing: original)
        var moved = stroke
        moved.transform = CGAffineTransform(translationX: 10, y: 70)
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [moved]))
        XCTAssertEqual(try store.undo(book: book, page: page), original)
        _ = try store.redo(book: book, page: page)
        let reopened = Store(directory: directory)
        let savedPage = reopened.notebook(book)!.pages[0]
        let restored = try reopened.drawing(book: book, page: savedPage)
        XCTAssertEqual(restored.strokes.first?.ink.inkType, .marker)
        XCTAssertEqual(restored.strokes.first?.transform, moved.transform)
        XCTAssertNotNil(restored.strokes.first?.mask)
        XCTAssertEqual(restored.strokes.count, 1)
        let image = try XCTUnwrap(reopened.exportPageImages(pageSize: CGSize(width: 200, height: 300))["\(book)/\(page)"])
        XCTAssertEqual(image.inkTypes, [PKInk.InkType.marker.rawValue])
        XCTAssertEqual(image.strokeCount, 1)
        XCTAssertNotNil(UIImage(data: image.png))
        XCTAssertEqual(savedPage.nodes.count, 2)
    }

    func testPurpleAndLegacyTealShareQuestionTagWithoutRecoloringArchiveOrDeletedPages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory)
        let book = try store.addNotebook("Questions")
        let page = store.notebook(book)!.pages[0].id
        let points = [CGPoint(x: 40, y: 40), CGPoint(x: 100, y: 40)].enumerated().map { i, point in
            PKStrokePoint(location: point, timeOffset: Double(i) / 10, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: [
            PKStroke(ink: PKInk(.monoline, color: QuestionInk.color), path: path),
            PKStroke(ink: PKInk(.monoline, color: .systemBlue), path: path),
            PKStroke(ink: PKInk(.marker, color: QuestionInk.color), path: path),
            PKStroke(ink: PKInk(.monoline, color: MissedInk.color), path: path),
            PKStroke(ink: PKInk(.marker, color: MissedInk.color), path: path)
        ]))
        try store.update(book) { $0.deleted = [$0.pages.removeFirst()]; $0.pages = [Page()] }
        let restored = Store(directory: directory)
        let package = try restored.exportPackage()
        let before = try package.digest()
        let images = try restored.exportPageImages(pageSize: CGSize(width: 200, height: 300))
        XCTAssertEqual(images["\(book)/\(page)"]?.tagStrokeCounts, ["question": 4])
        let active = restored.notebook(book)!.pages[0].id
        XCTAssertEqual(images["\(book)/\(active)"]?.tagStrokeCounts, [:])
        XCTAssertEqual(try restored.exportPackage().digest(), before)
        let native = try restored.drawing(book: book, page: restored.notebook(book)!.deleted[0])
        XCTAssertEqual(native.strokes.filter { MissedInk.matches($0.ink.color) }.count, 2,
                       "Read-only tag classification must preserve the legacy teal ink")
        var legacy = try XCTUnwrap(images["\(book)/\(page)"])
        legacy.tagStrokeCounts = nil
        XCTAssertNil(try JSONDecoder().decode(PageImage.self, from: JSONEncoder().encode(legacy)).tagStrokeCounts)
        XCTAssertFalse(QuestionInk.matches(.systemPink))
        XCTAssertFalse(QuestionInk.matches(MissedInk.color))
        XCTAssertFalse(MissedInk.matches(QuestionInk.color))
        for color: UIColor in [.black, .systemBlue, .systemGreen, .systemOrange, .systemYellow, .systemRed,
                               UIColor(red: 0, green: 0.2, blue: 0.8, alpha: 1)] {
            XCTAssertFalse(MissedInk.matches(color))
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(MissedInk.color.getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertEqual(r, 23.0 / 255, accuracy: 0.000001)
        XCTAssertEqual(g, 127.0 / 255, accuracy: 0.000001)
        XCTAssertEqual(b, 113.0 / 255, accuracy: 0.000001)
        XCTAssertEqual(a, 1)
    }

    func testImagesMatchHeadsIncludeDeletedPagesAndDoNotChangeHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory)
        let book = try store.addNotebook("Agent images")
        let page = store.notebook(book)!.pages[0]
        let points = [CGPoint(x: 40, y: 40), CGPoint(x: 100, y: 40)].enumerated().map { i, point in
            PKStrokePoint(location: point, timeOffset: Double(i) / 10, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        try store.commit(book: book, page: page.id, drawing: drawing)
        try store.update(book) { $0.deleted = [$0.pages.removeFirst()]; $0.pages = [Page()] }
        let before = try store.exportPackage().digest()
        let images = try store.exportPageImages(pageSize: CGSize(width: 200, height: 300))
        XCTAssertEqual(images.count, 2)
        let image = try XCTUnwrap(images["\(book.uuidString)/\(page.id.uuidString)"])
        XCTAssertEqual(image.head, store.notebook(book)?.deleted[0].head)
        XCTAssertEqual(image.strokeCount, 1)
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 600)
        XCTAssertEqual(UIImage(data: image.png)?.cgImage?.width, 400)
        XCTAssertEqual(try store.exportPackage().digest(), before)
        XCTAssertEqual(try store.exportPageImages(pageSize: CGSize(width: 200, height: 300))["\(book.uuidString)/\(page.id.uuidString)"]?.png, image.png)
        let packageAttachment = XCTAttachment(data: try store.exportPackage().encoded(), uniformTypeIdentifier: "public.json")
        packageAttachment.name = "agent-package.json"
        packageAttachment.lifetime = .keepAlways
        add(packageAttachment)
        let attachment = XCTAttachment(data: try JSONEncoder().encode(images), uniformTypeIdentifier: "public.json")
        attachment.name = "agent-images.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
