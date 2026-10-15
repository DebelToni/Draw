import XCTest
import PencilKit
@testable import Draw

@MainActor
final class OrientationTests: XCTestCase {
    func testManualModeDefaultsAndPersistsIndependentlyOfToolbar() throws {
        let suite = "OrientationTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DocumentOrientation.saved(in: defaults), .portrait)
        defaults.set("unknown", forKey: DocumentOrientation.defaultsKey)
        XCTAssertEqual(DocumentOrientation.saved(in: defaults), .portrait)
        DocumentOrientation.landscape.save(in: defaults)
        defaults.set("left", forKey: "toolbarPosition")
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(DocumentOrientation.saved(in: reopened), .landscape)
        DocumentOrientation.portrait.save(in: reopened)
        XCTAssertEqual(DocumentOrientation.saved(in: defaults), .portrait)
    }

    func testMetadataMasksAndPageGeometry() {
        XCTAssertEqual(DocumentOrientation(metadata: nil), .portrait)
        XCTAssertTrue(DocumentOrientation.portrait.fits(nil))
        XCTAssertFalse(DocumentOrientation.landscape.fits(nil))
        XCTAssertTrue(DocumentOrientation.landscape.fits("landscape"))
        XCTAssertEqual(DocumentOrientation.portrait.supportedInterfaceOrientations, .portrait)
        XCTAssertEqual(DocumentOrientation.landscape.supportedInterfaceOrientations, .landscapeRight)
        XCTAssertEqual(DocumentOrientation.landscape.interfaceOrientation, .landscapeRight)
        XCTAssertEqual(DocumentOrientation.portrait.pageSize, CGSize(width: 1024, height: 1361))
        XCTAssertEqual(DocumentOrientation.landscape.pageSize, CGSize(width: 1361, height: 1024))
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testHomeGatingAndDefensivePageAndOverviewRoutes() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: DocumentOrientation.defaultsKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.set(previous, forKey: DocumentOrientation.defaultsKey)
            try? FileManager.default.removeItem(at: directory)
        }
        DocumentOrientation.landscape.save()
        let store = Store(directory: directory)
        let old = try store.addNotebook("Legacy")
        let landscape = try store.addNotebook("Wide", orientation: "landscape")
        let controller = DrawController(store: store)
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.supportedInterfaceOrientations, .landscapeRight)
        let buttons = descendants(controller.view).compactMap { $0 as? UIButton }
        let legacy = try XCTUnwrap(buttons.first { $0.currentTitle?.contains("Legacy") == true })
        XCTAssertFalse(legacy.isEnabled)
        XCTAssertNotNil(legacy.image(for: .normal))
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.accessibilityLabel == "Document options Legacy" }).isEnabled)
        legacy.sendActions(for: .touchUpInside)
        XCTAssertFalse(descendants(controller.view).contains { $0 is DrawingCanvas })
        let wide = try XCTUnwrap(buttons.first { $0.currentTitle?.contains("Wide") == true })
        XCTAssertTrue(wide.isEnabled)
        wide.sendActions(for: .touchUpInside)
        XCTAssertTrue(descendants(controller.view).contains { $0 is DrawingCanvas })
        // A stale route must recheck metadata, not just rely on the Home button.
        try store.update(landscape) { $0.orientation = nil }
        controller.openPage(store.notebook(landscape)!.pages[0].id)
        XCTAssertFalse(descendants(controller.view).contains { $0 is DrawingCanvas })
        try store.update(landscape) { $0.orientation = "landscape" }
        try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.currentTitle?.contains("Wide") == true }).sendActions(for: .touchUpInside)
        DocumentOrientation.portrait.save()
        controller.showOverview()
        XCTAssertFalse(descendants(controller.view).contains { $0.accessibilityIdentifier == "pageOverviewGrid" })
        XCTAssertFalse(descendants(controller.view).contains { $0 is DrawingCanvas })
        XCTAssertNil(store.notebook(old)?.orientation)
    }

    func testLandscapeOverviewAndHistoryKeepFixedDocumentGeometry() throws {
        let defaults = UserDefaults.standard
        let previousOrientation = defaults.object(forKey: DocumentOrientation.defaultsKey)
        let previousPosition = defaults.object(forKey: "toolbarPosition")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.set(previousOrientation, forKey: DocumentOrientation.defaultsKey)
            defaults.set(previousPosition, forKey: "toolbarPosition")
            try? FileManager.default.removeItem(at: directory)
        }
        DocumentOrientation.landscape.save()
        let store = Store(directory: directory)
        let book = try store.addNotebook("Wide", orientation: "landscape")
        try store.update(book) {
            $0.pages.append(contentsOf: (0..<8).map { _ in Page() })
            $0.currentPage = $0.pages[0].id
        }
        let page = store.notebook(book)!.pages[0].id
        let strokes = (0..<2).map { i -> PKStroke in
            let points = [CGPoint(x: 100, y: 100 + i * 50), CGPoint(x: 200, y: 100 + i * 50)].enumerated().map { j, location in
                PKStrokePoint(location: location, timeOffset: Double(j) / 10, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: Array(strokes.prefix(1))))
        try store.commit(book: book, page: page, drawing: PKDrawing(strokes: strokes))
        let controller = DrawController(store: store)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1366, height: 1024)
        func tap(_ label: String) throws {
            try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label }).sendActions(for: .touchUpInside)
        }
        for edge in ToolbarPosition.allCases {
            defaults.set(edge.rawValue, forKey: "toolbarPosition")
            try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.currentTitle?.contains("Wide") == true }).sendActions(for: .touchUpInside)
            controller.view.layoutIfNeeded()
            let viewport = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PageViewport }.first)
            viewport.layoutIfNeeded()
            XCTAssertEqual(viewport.pageSize, DocumentOrientation.landscape.pageSize)
            let bounds = viewport.surface.bounds
            let transform = viewport.surface.transform
            let toolbar = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "drawingToolbar" })
            XCTAssertEqual(descendants(toolbar).compactMap { $0 as? UIButton }.count, 25)
            let toolbarFrame = toolbar.convert(toolbar.bounds, to: controller.view)
            let pageFrame = viewport.convert(viewport.bounds, to: controller.view)
            switch edge {
            case .bottom:
                XCTAssertEqual(toolbarFrame.minY, pageFrame.maxY, accuracy: 1)
                XCTAssertEqual(toolbarFrame.height, 44, accuracy: 1)
            case .top:
                XCTAssertEqual(toolbarFrame.maxY, pageFrame.minY, accuracy: 1)
                XCTAssertEqual(toolbarFrame.height, 44, accuracy: 1)
            case .right:
                XCTAssertEqual(toolbarFrame.minX, pageFrame.maxX, accuracy: 1)
                XCTAssertEqual(toolbarFrame.width, 44, accuracy: 1)
            case .left:
                XCTAssertEqual(toolbarFrame.maxX, pageFrame.minX, accuracy: 1)
                XCTAssertEqual(toolbarFrame.width, 44, accuracy: 1)
            }
            let canvas = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? DrawingCanvas }.first)
            let large = PKDrawing(strokes: strokes).transformed(using: CGAffineTransform(translationX: 1800, y: 0))
            for drawing in [large, PKDrawing()] {
                controller.canvasViewDidBeginUsingTool(canvas)
                canvas.drawing = drawing
                controller.canvasViewDidEndUsingTool(canvas)
                controller.finishSave()
            }
            for action in ["Undo", "Redo"] {
                try tap(action)
                controller.view.layoutIfNeeded()
                viewport.layoutIfNeeded()
                XCTAssertEqual(viewport.surface.bounds, bounds)
                XCTAssertEqual(viewport.surface.transform, transform)
            }
            try tap("Page overview")
            let grid = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "pageOverviewGrid" } as? UIStackView)
            XCTAssertEqual(grid.arrangedSubviews.count, 3)
            XCTAssertEqual(grid.arrangedSubviews.compactMap { $0 as? UIStackView }.map { $0.arrangedSubviews.count }, [3, 3, 3])
            try tap("Documents")
        }
    }
}
