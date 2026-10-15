import XCTest
import PencilKit
@testable import Draw

@MainActor
final class CanvasHistoryTests: XCTestCase {
    private var folder: URL!
    private var store: Store!
    private var controller: DrawController!
    private var window: UIWindow!
    private var book: UUID!
    private var page: UUID!
    private var canvas: DrawingCanvas!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = Store(directory: folder)
        book = try store.addNotebook("History regression")
        page = store.notebook(book)!.pages[0].id
        try store.commit(book: book, page: page, drawing: drawing(1))
        try store.commit(book: book, page: page, drawing: drawing(2))
        controller = DrawController(store: store, aiClient: AIClient(endpoint: URL(string: "https://ai.fixture/draw-ai")!, token: ""),
            aiJournal: try AINetworkJournal(directory: folder.appendingPathComponent("network")))
        window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        let open = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.currentTitle?.contains("History regression") == true })
        open.sendActions(for: .touchUpInside)
        window.layoutIfNeeded()
        canvas = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? DrawingCanvas }.first)
        settle()
    }

    override func tearDownWithError() throws {
        controller.enterBackground()
        window.isHidden = true
        window.rootViewController = nil
        controller = nil
        window = nil
        try FileManager.default.removeItem(at: folder)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func drawing(_ count: Int) -> PKDrawing {
        PKDrawing(strokes: (0..<count).map { i in
            let points = (0..<40).map { j in
                PKStrokePoint(location: CGPoint(x: 40 + j * 3, y: 50 + i * 15), timeOffset: Double(j) / 120,
                              size: CGSize(width: 4, height: 4), opacity: 1, force: 0.5,
                              azimuth: 0.2, altitude: .pi / 3)
            }
            return PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        })
    }

    private func tap(_ name: String) throws {
        let button = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == name })
        button.sendActions(for: .touchUpInside)
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    }

    private func settleWindowLayout(for orientation: DocumentOrientation) async throws {
        let scene = try XCTUnwrap(window.windowScene)
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var previousSize: CGSize?
        var stableSince: TimeInterval?
        while ProcessInfo.processInfo.systemUptime < deadline {
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            let size = window.bounds.size
            let aspectMatches = orientation == .landscape ? size.width > size.height : size.height > size.width
            let orientationMatches = scene.interfaceOrientation == orientation.interfaceOrientation
            let layoutMatches = controller.view.bounds.size == size && controller.transitionCoordinator == nil
            let now = ProcessInfo.processInfo.systemUptime
            if aspectMatches && orientationMatches && layoutMatches {
                if previousSize != size { previousSize = size; stableSince = now }
                if let stableSince, now - stableSince >= 0.4 { return }
            } else {
                previousSize = nil
                stableSince = nil
            }
            // Drain native geometry/transition callbacks on the main actor.
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "CanvasHistoryTests", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Window did not settle to \(orientation.rawValue): scene=\(scene.interfaceOrientation.rawValue), bounds=\(window.bounds)"])
    }

    func testRapidUndoRedoAndDelayedCallbacksDoNotCreateEdits() throws {
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        for _ in 0..<10 {
            try tap("Undo")
            XCTAssertEqual(canvas.drawing.strokes.count, 1)
            // Simulate PencilKit reporting a programmatic change after the setter returned.
            controller.canvasViewDrawingDidChange(canvas)
            controller.finishSave()
            try tap("Undo")
            XCTAssertTrue(canvas.drawing.strokes.isEmpty)
            try tap("Redo")
            XCTAssertEqual(canvas.drawing.strokes.count, 1)
            try tap("Redo")
            XCTAssertEqual(canvas.drawing.strokes.count, 2)
        }
        settle()
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 2)
        XCTAssertEqual(Store(directory: folder).notebook(book)?.pages[0].nodes.count, 2)
    }

    func testRetainedStoreHistoryVisitsAbandonedBranchWithoutHiddenButtons() throws {
        try tap("Undo")
        controller.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = drawing(3)
        controller.canvasViewDidEndUsingTool(canvas)
        controller.finishSave()
        XCTAssertEqual(try store.stepHistory(book: book, page: page, forward: false)?.strokes.count, 2)
        try reopenController()
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertEqual(try store.stepHistory(book: book, page: page, forward: true)?.strokes.count, 3)
        try reopenController()
        XCTAssertEqual(canvas.drawing.strokes.count, 3)
        let controls = descendants(controller.view).compactMap { $0 as? UIButton }
        XCTAssertFalse(controls.contains { $0.accessibilityLabel == "Older change across branches" || $0.accessibilityLabel == "Newer change across branches" })
        try tap("Undo")
        XCTAssertEqual(canvas.drawing.strokes.count, 1)
        settle()
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 3)
    }

    private func reopenController() throws {
        controller.enterBackground()
        controller = DrawController(store: store, aiClient: AIClient(token: ""),
            aiJournal: try AINetworkJournal(directory: folder.appendingPathComponent("network")))
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        let open = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.currentTitle?.contains("History regression") == true })
        open.sendActions(for: .touchUpInside)
        window.layoutIfNeeded()
        canvas = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? DrawingCanvas }.first)
        settle()
    }

    func testNewControllerDefaultsToInkBlueAndOnePointWithoutResettingStoredPalette() throws {
        let defaults = UserDefaults.standard
        let previous = ["ink", "tool", "lastInkTool"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in previous { defaults.set(value, forKey: key) } }
        defaults.set(0, forKey: "tool")
        defaults.set(0, forKey: "lastInkTool")
        for storedInk in [7, 0, 8, 99] {
            defaults.set(storedInk, forKey: "ink")
            try reopenController()
            let ink = try XCTUnwrap(canvas.tool as? PKInkingTool)
            XCTAssertEqual(ink.inkType, .monoline)
            XCTAssertEqual(ink.width, 1)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(ink.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            XCTAssertEqual(red, 0, accuracy: 0.001)
            XCTAssertEqual(green, 0.2, accuracy: 0.001)
            XCTAssertEqual(blue, 0.8, accuracy: 0.001)
            XCTAssertEqual(alpha, 1, accuracy: 0.001)
            XCTAssertEqual(defaults.integer(forKey: "ink"), storedInk)
            XCTAssertEqual(canvas.drawing.strokes.count, 2)
        }
    }

    func testPaletteAndPenWidthStayLiveUntilNewController() throws {
        let defaults = UserDefaults.standard
        let previous = ["ink", "tool", "lastInkTool"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in previous { defaults.set(value, forKey: key) } }
        try tap("Pen")
        try tap("Question")
        try tap("Thicker")
        try tap("New page")
        XCTAssertTrue(QuestionInk.matches(try XCTUnwrap(canvas.tool as? PKInkingTool).color))
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 1.5)
        XCTAssertEqual(defaults.integer(forKey: "ink"), 7)
        try tap("Previous page")
        XCTAssertTrue(QuestionInk.matches(try XCTUnwrap(canvas.tool as? PKInkingTool).color))
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 1.5)
        try reopenController()
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 1)
        XCTAssertFalse(QuestionInk.matches(try XCTUnwrap(canvas.tool as? PKInkingTool).color))
        XCTAssertEqual(defaults.integer(forKey: "ink"), 7)
    }

    func testStartupDefaultsPreserveHighlighterSelectionAndLastInkTool() throws {
        let defaults = UserDefaults.standard
        let previous = ["ink", "tool", "lastInkTool"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in previous { defaults.set(value, forKey: key) } }
        for tool in [2, 3] {
            defaults.set(tool, forKey: "tool")
            defaults.set(2, forKey: "lastInkTool")
            defaults.set(7, forKey: "ink")
            try reopenController()
            XCTAssertEqual(defaults.integer(forKey: "tool"), tool)
            XCTAssertEqual(defaults.integer(forKey: "lastInkTool"), 2)
            if tool == 3 { XCTAssertTrue(canvas.tool is PKLassoTool) }
            else {
                XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .marker)
                XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 20)
            }
            try tap("Black") // Empty selection must return to the restored last ink tool.
            XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .marker)
            XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 20)
            try tap("Pen")
            XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 1)
        }
    }

    func testInkBlueReplacesPinkWithoutRecoloringExistingInk() throws {
        let existing = canvas.drawing
        try tap("Ink blue")
        let ink = try XCTUnwrap(canvas.tool as? PKInkingTool)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(ink.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(red, 0, accuracy: 0.001)
        XCTAssertEqual(green, 0.2, accuracy: 0.001)
        XCTAssertEqual(blue, 0.8, accuracy: 0.001)
        XCTAssertEqual(canvas.drawing, existing)
    }

    func testSelectedInkRecolorsWithoutChangingGeometryAndSupportsUndoRedo() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Public stroke selection requires iOS 27") }
        var strokes = drawing(3).strokes
        strokes[1].ink = PKInk(.marker, color: .systemYellow)
        strokes[1].transform = CGAffineTransform(translationX: 10, y: 70)
        strokes[1].mask = UIBezierPath(rect: CGRect(x: 50, y: 55, width: 80, height: 20))
        canvas.drawing = PKDrawing(strokes: strokes)
        controller.finishSave()
        settle()
        let original = canvas.drawing
        let nodes = store.notebook(book)!.pages[0].nodes.count
        try tap("Selection")
        let selected = Set(original.strokes.prefix(2).map(\.id))
        canvas.selection = selected
        settle()
        XCTAssertEqual(canvas.selection, selected, "Selection must be active before tapping the swatch")
        try tap("Blue")
        let recolored = canvas.drawing
        XCTAssertTrue(canvas.tool is PKLassoTool)
        XCTAssertTrue(canvas.selectionEditingEnabled)
        XCTAssertEqual(canvas.selection, Set(recolored.strokes.prefix(2).map(\.id)))
        XCTAssertEqual(recolored.strokes.count, original.strokes.count)
        for (before, after) in zip(original.strokes, recolored.strokes) {
            if selected.contains(before.id) { XCTAssertNotEqual(after.id, before.id) }
            else { XCTAssertEqual(after.id, before.id) }
            XCTAssertEqual(after.ink.inkType, before.ink.inkType)
            XCTAssertEqual(after.transform, before.transform)
            XCTAssertEqual(after.path.map(\.location), before.path.map(\.location))
            XCTAssertEqual(after.path.map(\.size), before.path.map(\.size))
            XCTAssertEqual(after.randomSeed, before.randomSeed)
            if let mask = before.mask { XCTAssertEqual(after.mask?.cgPath, mask.cgPath) }
            XCTAssertEqual(after.ink.color, selected.contains(before.id) ? PKInk(before.ink.inkType, color: UIColor.systemBlue.resolvedColor(with: canvas.traitCollection)).color : before.ink.color)
        }
        XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, nodes + 1)
        try tap("Blue")
        settle()
        XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, nodes + 1)
        func verifyRestored(_ actual: PKDrawing, _ expected: PKDrawing) throws {
            let archived = try PKDrawing(data: expected.dataRepresentation())
            XCTAssertEqual(actual.strokes.count, archived.strokes.count)
            for (after, before) in zip(actual.strokes, archived.strokes) {
                XCTAssertEqual(after.id, before.id)
                XCTAssertEqual(after.ink.inkType, before.ink.inkType)
                var actualRed: CGFloat = 0, actualGreen: CGFloat = 0, actualBlue: CGFloat = 0, actualAlpha: CGFloat = 0
                var expectedRed: CGFloat = 0, expectedGreen: CGFloat = 0, expectedBlue: CGFloat = 0, expectedAlpha: CGFloat = 0
                XCTAssertTrue(after.ink.color.getRed(&actualRed, green: &actualGreen, blue: &actualBlue, alpha: &actualAlpha))
                XCTAssertTrue(before.ink.color.getRed(&expectedRed, green: &expectedGreen, blue: &expectedBlue, alpha: &expectedAlpha))
                XCTAssertEqual(actualRed, expectedRed, accuracy: 0.0001)
                XCTAssertEqual(actualGreen, expectedGreen, accuracy: 0.0001)
                XCTAssertEqual(actualBlue, expectedBlue, accuracy: 0.0001)
                XCTAssertEqual(actualAlpha, expectedAlpha, accuracy: 0.0001)
                XCTAssertEqual(after.transform, before.transform)
                XCTAssertEqual(after.path.map(\.location), before.path.map(\.location))
                XCTAssertEqual(after.path.map(\.size), before.path.map(\.size))
                if let mask = before.mask { XCTAssertEqual(after.mask?.cgPath, mask.cgPath) }
            }
        }
        try tap("Undo")
        try verifyRestored(canvas.drawing, original)
        try tap("Redo")
        try verifyRestored(canvas.drawing, recolored)
        settle()
        canvas.selection = Set(canvas.drawing.strokes.prefix(2).map(\.id))
        settle()
        try tap("Blue")
        XCTAssertEqual(store.notebook(book)!.pages[0].nodes.count, nodes + 1)
        let reopened = Store(directory: folder)
        try verifyRestored(reopened.drawing(book: book, page: reopened.notebook(book)!.pages[0]), recolored)
    }

    func testQuestionSelectionTagDisappearsWhenRecoloredAndUndoRestoresIt() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Public stroke selection requires iOS 27") }
        try tap("Selection")
        canvas.selection = [canvas.drawing.strokes[0].id]
        settle()
        try tap("Question")
        func counts() throws -> [String: Int]? {
            try store.exportPageImages(pageSize: CGSize(width: 200, height: 300))["\(book!)/\(page!)"]?.tagStrokeCounts
        }
        XCTAssertEqual(try counts(), ["question": 1])
        XCTAssertTrue(QuestionInk.matches(canvas.drawing.strokes[0].ink.color))
        XCTAssertFalse(QuestionInk.matches(canvas.drawing.strokes[1].ink.color))
        try tap("Black")
        XCTAssertEqual(try counts(), [:])
        try tap("Undo")
        XCTAssertEqual(try counts(), ["question": 1])
        try tap("Redo")
        XCTAssertEqual(try counts(), [:])
    }

    func testAIReplacesMissedButPreservesEveryOtherPaletteIndex() throws {
        let controls = descendants(controller.view).compactMap { $0 as? UIButton }
        XCTAssertFalse(controls.contains { $0.accessibilityLabel == "Missed" })
        XCTAssertEqual(controls.filter { $0.accessibilityLabel == "AI" }.count, 1)
        let question = try XCTUnwrap(controls.first { $0.accessibilityLabel == "Question" })
        XCTAssertTrue(descendants(question).compactMap { $0 as? UILabel }.contains { $0.text == "?" })
        for (index, color) in ["Black", "Blue", "Green", "Orange", "Yellow", "Red", "Ink blue", "Question"].enumerated() {
            try tap(color)
            XCTAssertEqual(UserDefaults.standard.integer(forKey: "ink"), index)
        }
    }

    private func approvedAnswer(x: Double = 200) throws -> (Data, [String: Data]) {
        let requestID = UUID(), contextSHA = String(repeating: "a", count: 64)
        var objects: [AIObject] = [], assets: [String: Data] = [:]
        for (i, kind) in ["circle", "latex", "text"].enumerated() {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 50), format: AICapture.rendererFormat()).image { context in
                if kind == "circle" {
                    context.cgContext.setStrokeColor(UIColor.black.cgColor)
                    context.cgContext.strokeEllipse(in: CGRect(x: 1, y: 1, width: 198, height: 48))
                } else {
                    (kind == "latex" ? "x² = 4" : "Answer").draw(at: CGPoint(x: 4, y: 4),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.black])
                }
            }
            let bytes = try AICapture.png(image), sha = SyncObjects.digest(bytes)
            assets[sha] = bytes
            objects.append(AIObject(id: UUID(), revision: 1, kind: kind, source: kind == "latex" ? "x^2=4" : "Answer",
                frame: AIFrame(x: x, y: Double(200 + i * 60), width: 200, height: 50), style: AIStyle(),
                asset: AIAsset(sha256: sha, pixelWidth: 400, pixelHeight: 100),
                provenance: AIProvenance(requestID: requestID, contextSHA256: contextSHA, rendererSignature: "draw-ai-render-v1")))
        }
        let result = AIResult(requestID: requestID, documentID: book, contextSHA256: contextSHA, draftVersion: 1,
            rendererSignature: "draw-ai-render-v1", pageEdits: [AIPageEdit(pageID: page,
                objectEdits: objects.map { AIObjectEdit(op: "add", object: $0) }, strokeEdits: [])],
            previewSHA256s: [page.uuidString: String(repeating: "b", count: 64)])
        return (try AIHash.encoded(result), assets)
    }

    func testApprovedAnswerWaitsForPencilEndPreservesLaterInkAndUndoRetryDoesNotDuplicate() async throws {
        controller.becomeForeground() // Injected empty credential cannot touch a service.
        let answer = try approvedAnswer()
        controller.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = drawing(3)
        let apply = Task { try await self.controller.applyApprovedAI(data: answer.0, assets: answer.1) }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(store.objects(book: book, page: store.notebook(book)!.pages[0]).isEmpty)
        controller.canvasViewDidEndUsingTool(canvas)
        let receipt = try await apply.value
        XCTAssertEqual(canvas.drawing.strokes.count, 3)
        XCTAssertEqual(receipt.resultSHA256, SyncObjects.digest(answer.0))
        let layer = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? AIObjectsView }.first)
        XCTAssertEqual(layer.accessibilityValue, "3")
        XCTAssertFalse(layer.isUserInteractionEnabled)
        XCTAssertLessThan(layer.superview!.subviews.firstIndex(of: layer)!, layer.superview!.subviews.firstIndex(of: canvas)!)
        try tap("Undo")
        XCTAssertEqual(canvas.drawing.strokes.count, 3)
        XCTAssertEqual(layer.accessibilityValue, "0")
        let retry = try await controller.applyApprovedAI(data: answer.0, assets: answer.1)
        XCTAssertEqual(retry, receipt)
        XCTAssertEqual(layer.accessibilityValue, "0")
        try tap("Redo")
        XCTAssertEqual(layer.accessibilityValue, "3")
        controller.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = drawing(4)
        controller.canvasViewDidEndUsingTool(canvas)
        controller.finishSave()
        XCTAssertEqual(store.objects(book: book, page: store.notebook(book)!.pages[0]).count, 3)
        XCTAssertEqual(canvas.drawing.strokes.count, 4)
        let preview = try PageComposite.image(drawing: canvas.drawing,
            objects: store.objects(book: book, page: store.notebook(book)!.pages[0]), store: store,
            background: 0, size: CGSize(width: 1024, height: 1361), scale: 0.25)
        XCTAssertNotNil(preview.cgImage)
    }

    func testApprovedObjectExtentsNeverRefitCurrentViewportAllEdgesBothOrientations() async throws {
        let defaults = UserDefaults.standard
        let oldPosition = defaults.object(forKey: "toolbarPosition")
        let oldOrientation = defaults.object(forKey: DocumentOrientation.defaultsKey)
        defer {
            defaults.set(oldPosition, forKey: "toolbarPosition")
            defaults.set(oldOrientation, forKey: DocumentOrientation.defaultsKey)
        }
        for orientation in DocumentOrientation.allCases {
            orientation.save()
            try store.update(book) { $0.orientation = orientation.rawValue }
            // Request this axis, not the old saved axis before entering the loop.
            controller.becomeForeground()
            for edge in ToolbarPosition.allCases {
                defaults.set(edge.rawValue, forKey: "toolbarPosition")
                controller.openPage(page)
                try await settleWindowLayout(for: orientation)
                let viewport = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PageViewport }.first)
                viewport.layoutIfNeeded()
                let bounds = viewport.surface.bounds, transform = viewport.surface.transform
                let canvas = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? DrawingCanvas }.first)
                let point = canvas.convert(CGPoint(x: 100, y: 100), to: controller.view)
                let answer = try approvedAnswer(x: Double(viewport.surface.bounds.width + 100))
                try await controller.applyApprovedAI(data: answer.0, assets: answer.1)
                controller.view.layoutIfNeeded(); viewport.layoutIfNeeded()
                XCTAssertEqual(viewport.surface.bounds, bounds, "\(orientation) \(edge)")
                XCTAssertEqual(viewport.surface.transform, transform)
                XCTAssertEqual(canvas.convert(CGPoint(x: 100, y: 100), to: controller.view), point)
                try tap("Undo") // Do not accumulate oversized assets across the next opened page.
            }
        }
        // Do not leave a pending rotation for the next unit test's window.
        defaults.set(oldOrientation, forKey: DocumentOrientation.defaultsKey)
        controller.requestManualOrientation()
        try await settleWindowLayout(for: DocumentOrientation.saved())
    }

    func testRetiredPersistentEraserRestoresLastInkTool() throws {
        let defaults = UserDefaults.standard
        let oldTool = defaults.object(forKey: "tool"), oldInkTool = defaults.object(forKey: "lastInkTool")
        defer {
            defaults.set(oldTool, forKey: "tool")
            defaults.set(oldInkTool, forKey: "lastInkTool")
        }
        defaults.set(1, forKey: "tool")
        defaults.set(2, forKey: "lastInkTool")
        let replacement = DrawController(store: store)
        window.rootViewController = replacement
        replacement.loadViewIfNeeded()
        let open = try XCTUnwrap(descendants(replacement.view).compactMap { $0 as? UIButton }.first { $0.currentTitle?.contains("History regression") == true })
        open.sendActions(for: .touchUpInside)
        window.layoutIfNeeded()
        let restored = try XCTUnwrap(descendants(replacement.view).compactMap { $0 as? DrawingCanvas }.first)
        XCTAssertEqual((restored.tool as? PKInkingTool)?.inkType, .marker)
        XCTAssertEqual(defaults.integer(forKey: "tool"), 2)
        let controls = descendants(replacement.view).compactMap { $0 as? UIButton }
        XCTAssertFalse(controls.contains { $0.accessibilityLabel == "Object eraser" })
        XCTAssertTrue(controls.contains { $0.accessibilityLabel == "Erase next stroke" })
        XCTAssertTrue(controls.contains { $0.accessibilityLabel == "Question" })
    }

    func testWidthsAreGradualAndClampAtBothEnds() throws {
        XCTAssertEqual(PKInkingTool.InkType.monoline.validWidthRange.lowerBound, 0.5)
        try tap("Pen")
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 1)
        for _ in 0..<30 { try tap("Thinner") }
        let expected: [CGFloat] = [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6, 7, 8, 9, 10, 11, 12]
        for width in expected {
            XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, width)
            try tap("Thicker")
        }
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 12)
    }

    func testPencilSqueezeArmsOneStrokeEraserAndQueuesDuringDrawing() throws {
        try tap("Pen")
        let interaction = try XCTUnwrap(canvas.interactions.compactMap { $0 as? UIPencilInteraction }.first)
        XCTAssertTrue(interaction.delegate === controller)
        controller.handlePencilSqueeze(phase: .began)
        controller.handlePencilSqueeze(phase: .cancelled)
        XCTAssertTrue(canvas.tool is PKInkingTool)
        controller.handlePencilSqueeze(phase: .ended)
        XCTAssertTrue(canvas.tool is PKEraserTool)
        controller.canvasViewDidBeginUsingTool(canvas)
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(canvas.tool is PKInkingTool)
        controller.canvasViewDidBeginUsingTool(canvas)
        controller.handlePencilSqueeze(phase: .ended)
        XCTAssertTrue(canvas.tool is PKInkingTool)
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(canvas.tool is PKEraserTool)
        controller.canvasViewDidBeginUsingTool(canvas)
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(canvas.tool is PKInkingTool)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 1)
    }

    func testHistoryNeverChangesViewportGeometryAtAnyToolbarEdge() throws {
        let defaults = UserDefaults.standard
        let previousPosition = defaults.object(forKey: "toolbarPosition")
        defer { defaults.set(previousPosition, forKey: "toolbarPosition") }
        for edge in ToolbarPosition.allCases {
            defaults.set(edge.rawValue, forKey: "toolbarPosition")
            try tap("Page overview")
            try tap("Documents")
            let open = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.currentTitle?.contains("History regression") == true })
            open.sendActions(for: .touchUpInside)
            controller.view.layoutIfNeeded()
            let viewport = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PageViewport }.first)
            viewport.layoutIfNeeded()
            let transform = viewport.surface.transform
            let surfaceBounds = viewport.surface.bounds
            let canvasBounds = canvas.bounds
            let inkPoint = CGPoint(x: 100, y: 100)
            let screenPoint = canvas.convert(inkPoint, to: controller.view)
            // History may contain ink beyond the current visible area (e.g. from
            // a different toolbar edge), followed by an erase-to-empty change.
            let large = drawing(1).transformed(using: CGAffineTransform(translationX: 0, y: canvas.bounds.height * 1.02))
            for ink in [large, PKDrawing()] {
                controller.canvasViewDidBeginUsingTool(canvas)
                canvas.drawing = ink
                controller.canvasViewDidEndUsingTool(canvas)
                controller.finishSave()
            }
            for action in ["Undo", "Undo", "Redo", "Redo"] {
                try tap(action)
                controller.view.layoutIfNeeded()
                viewport.layoutIfNeeded()
                XCTAssertEqual(viewport.surface.transform, transform, "\(edge): \(action)")
                XCTAssertEqual(viewport.surface.bounds, surfaceBounds, "\(edge): \(action)")
                XCTAssertEqual(canvas.bounds, canvasBounds, "\(edge): \(action)")
                XCTAssertEqual(canvas.convert(inkPoint, to: controller.view), screenPoint, "\(edge): \(action)")
            }
        }
    }

    func testOverviewUsesNineOrderedCellsIncludingDeletedPages() throws {
        try store.update(book) {
            $0.pages.append(contentsOf: (0..<11).map { _ in Page() })
            $0.deleted = (0..<12).map { _ in Page() }
        }
        let pages = store.notebook(book)!.pages
        let deleted = store.notebook(book)!.deleted
        try tap("Page overview")
        func verify(_ expected: [Page]) throws {
            let grid = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "pageOverviewGrid" } as? UIStackView)
            XCTAssertEqual(grid.arrangedSubviews.count, 3)
            let rows = grid.arrangedSubviews.compactMap { $0 as? UIStackView }
            XCTAssertEqual(rows.map { $0.arrangedSubviews.count }, [3, 3, 3])
            let buttons = rows.flatMap { $0.arrangedSubviews }.compactMap { $0 as? UIButton }
            XCTAssertEqual(buttons.compactMap(\.accessibilityIdentifier), expected.map { $0.id.uuidString })
        }
        try verify(Array(pages.prefix(9)))
        try tap("Next 9 pages")
        try verify(Array(pages.suffix(3)))
        try tap("Previous 9 pages")
        try verify(Array(pages.prefix(9)))
        try tap("Deleted pages")
        try verify(Array(deleted.prefix(9)))
        try tap("Next 9 pages")
        try verify(Array(deleted.suffix(3)))
    }

    func testHighlighterHasIndependentWidthsAndColorsAndQuickEraserReturnsToPen() throws {
        try tap("Pen")
        try tap("Thinner")
        try tap("Highlighter")
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .marker)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 20)
        try tap("Thicker")
        try tap("Yellow")
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .marker)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 22)
        controller.handlePencilSqueeze(phase: .ended)
        XCTAssertTrue(canvas.tool is PKEraserTool)
        controller.canvasViewDidBeginUsingTool(canvas)
        controller.canvasViewDidEndUsingTool(canvas)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .monoline)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 0.5)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "tool"), 0)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "lastInkTool"), 0)
        try tap("Highlighter")
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 22)
        for _ in 0..<50 { try tap("Thinner") }
        XCTAssertEqual(try XCTUnwrap(canvas.tool as? PKInkingTool).width, 8, accuracy: 0.001)
        for _ in 0..<50 { try tap("Thicker") }
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 60)
    }

    func testSelectionCallbackKeepsNativeSelectionAndViewportWhenNoTextEditorHasFocus() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Public stroke selection requires iOS 27") }
        try tap("Selection")
        let selected = Set(canvas.drawing.strokes.map(\.id))
        canvas.selection = selected
        let original = canvas.drawing
        let viewport = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PageViewport }.first)
        let bounds = viewport.surface.bounds, transform = viewport.surface.transform
        controller.canvasViewSelectionDidChange(canvas)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(canvas.selection, selected)
        XCTAssertEqual(canvas.drawing, original)
        XCTAssertTrue(canvas.tool is PKLassoTool)
        XCTAssertTrue(canvas.selectionEditingEnabled)
        XCTAssertEqual(viewport.surface.bounds, bounds)
        XCTAssertEqual(viewport.surface.transform, transform)
    }

    func testSelectionAndRulerAreExplicitTransientModes() throws {
        let nodes = store.notebook(book)!.pages[0].nodes.count
        try tap("Selection")
        XCTAssertTrue(canvas.tool is PKLassoTool)
        XCTAssertTrue(canvas.selectionEditingEnabled)
        XCTAssertFalse(canvas.isRulerActive)
        try tap("Ruler")
        XCTAssertTrue(canvas.tool is PKInkingTool)
        XCTAssertFalse(canvas.selectionEditingEnabled)
        XCTAssertTrue(canvas.isRulerActive)
        try tap("Ruler")
        XCTAssertFalse(canvas.isRulerActive)
        try tap("Ruler")
        try tap("Selection")
        XCTAssertFalse(canvas.isRulerActive)
        try tap("Pen")
        XCTAssertFalse(canvas.selectionEditingEnabled)
        controller.finishSave()
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, nodes)
        try tap("Ruler")
        try tap("Page overview")
        XCTAssertFalse(canvas.isRulerActive)
        XCTAssertFalse(canvas.selectionEditingEnabled)
    }

    func testNativeSelectionIsTransientAndQuickEraserReturnsToPen() throws {
        if #available(iOS 27.0, *) {
            let nodes = store.notebook(book)!.pages[0].nodes.count
            try tap("Selection")
            canvas.selection = Set(canvas.drawing.strokes.map(\.id))
            settle()
            XCTAssertFalse(canvas.selection.isEmpty)
            controller.finishSave()
            XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, nodes)
            controller.handlePencilSqueeze(phase: .ended)
            XCTAssertTrue(canvas.tool is PKEraserTool)
            XCTAssertFalse(canvas.selectionEditingEnabled)
            controller.canvasViewDidBeginUsingTool(canvas)
            controller.canvasViewDidEndUsingTool(canvas)
            XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .monoline)
            XCTAssertFalse(canvas.selectionEditingEnabled)
            XCTAssertEqual(UserDefaults.standard.integer(forKey: "tool"), 0)
            XCTAssertFalse(canvas.canPerformAction(NSSelectorFromString("delete:"), withSender: nil))
        }
    }

    func testReopenedPageFitsInkFromExtendedSideArea() throws {
        controller.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = drawing(1).transformed(using: CGAffineTransform(translationX: 0, y: 1400))
        controller.canvasViewDidEndUsingTool(canvas)
        try tap("Page overview")
        try tap("Documents")
        let open = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.currentTitle?.contains("History regression") == true })
        open.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        let viewport = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PageViewport }.first)
        viewport.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(viewport.surface.bounds.height, canvas.drawing.bounds.maxY)
        XCTAssertEqual(viewport.surface.frame.height, viewport.bounds.height, accuracy: 0.01)
    }

    private func carryOverlay() throws -> CarryTapOverlay {
        try XCTUnwrap(descendants(controller.view).compactMap { $0 as? CarryTapOverlay }.first)
    }

    private func carryButton() throws -> UIButton {
        try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Carry to next page" })
    }

    func testCarryButtonHasVisibleIconWhenIdleAndArmed() throws {
        let button = try carryButton()
        for armed in [false, true] {
            if armed { try tap("Carry to next page") }
            XCTAssertEqual(button.isSelected, armed)
            let image = try XCTUnwrap(button.currentImage, "Carry must display an available SF Symbol")
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
            XCTAssertGreaterThan(button.alpha, 0)
            XCTAssertFalse(button.isHidden)
        }
    }

    func testCarryIsOneShotAndCancelsOnToolNavigationAndBackground() throws {
        let toolbar = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "drawingToolbar" })
        let controls = descendants(toolbar).compactMap { $0 as? UIButton }
        XCTAssertEqual(controls.count, 25)
        XCTAssertEqual(controls.suffix(5).map(\.accessibilityLabel), ["AI", "Star page", "Undo", "Redo", "Carry to next page"])
        XCTAssertEqual(canvas.drawingPolicy, .pencilOnly)
        try tap("Carry to next page")
        XCTAssertTrue(try carryButton().isSelected)
        let overlay = try carryOverlay()
        let tapRecognizer = try XCTUnwrap(overlay.gestureRecognizers?.first as? UITapGestureRecognizer)
        XCTAssertEqual(tapRecognizer.numberOfTouchesRequired, 1)
        XCTAssertEqual(tapRecognizer.numberOfTapsRequired, 1)
        XCTAssertEqual(tapRecognizer.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)])
        XCTAssertTrue(tapRecognizer.cancelsTouchesInView)
        XCTAssertTrue(overlay.superview is PageViewport)
        for action in ["Carry to next page", "Pen", "Highlighter", "Selection", "Ruler", "Erase next stroke", "Thicker", "Question", "Undo"] {
            if !carryButtonIsSelected() { try tap("Carry to next page") }
            try tap(action)
            XCTAssertFalse(try carryButton().isSelected, action)
            XCTAssertFalse(descendants(controller.view).contains { $0 is CarryTapOverlay }, action)
        }
        try tap("Carry to next page")
        controller.enterBackground()
        XCTAssertFalse(try carryButton().isSelected)
        try tap("Carry to next page")
        try tap("New page")
        XCTAssertFalse(try carryButton().isSelected)
        try tap("Carry to next page")
        try tap("Page overview")
        try tap("Documents")
        XCTAssertFalse(descendants(controller.view).contains { $0 is CarryTapOverlay })
    }

    private func carryButtonIsSelected() -> Bool { (try? carryButton().isSelected) == true }

    func testCarryCannotArmOrChangeToolsDuringAnExistingContact() throws {
        try tap("Pen")
        controller.canvasViewDidBeginUsingTool(canvas)
        for action in ["Carry to next page", "Selection", "Highlighter", "Ruler", "Question", "Thicker"] { try tap(action) }
        XCTAssertTrue(canvas.tool is PKInkingTool)
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.width, 1)
        XCTAssertFalse(descendants(controller.view).contains { $0 is CarryTapOverlay })
        controller.canvasViewDidEndUsingTool(canvas)
        try tap("Carry to next page")
        XCTAssertTrue(try carryButton().isSelected)
    }

    func testCarryUsesTransformedTapYAllToolbarEdgesBothDocumentOrientations() async throws {
        let defaults = UserDefaults.standard
        let oldPosition = defaults.object(forKey: "toolbarPosition")
        let oldOrientation = defaults.object(forKey: DocumentOrientation.defaultsKey)
        defer {
            defaults.set(oldPosition, forKey: "toolbarPosition")
            defaults.set(oldOrientation, forKey: DocumentOrientation.defaultsKey)
        }
        let baselinePage = store.notebook(book)!.pages[0]
        for orientation in DocumentOrientation.allCases {
            orientation.save()
            try store.update(book) { $0.orientation = orientation.rawValue }
            controller.becomeForeground()
            for edge in ToolbarPosition.allCases {
                defaults.set(edge.rawValue, forKey: "toolbarPosition")
                // Keep a pre-existing next page, proving insertion is immediately right.
                let following = Page()
                try store.update(book) { $0.pages = [baselinePage, following] }
                controller.openPage(page)
                try await settleWindowLayout(for: orientation)
                let viewport = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PageViewport }.first)
                viewport.layoutIfNeeded()
                let bounds = viewport.surface.bounds, transform = viewport.surface.transform
                let answer = try approvedAnswer()
                try await controller.applyApprovedAI(data: answer.0, assets: answer.1)
                let sourceObjects = store.objects(book: book, page: store.notebook(book)!.pages[0])
                let y: CGFloat = 220
                let locations = [CGPoint(x: 70, y: y - 40), CGPoint(x: 70, y: y + 50)]
                let points = locations.enumerated().map { i, location in
                    PKStrokePoint(location: location, timeOffset: Double(i) / 10,
                        size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                let crossing = PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
                let below = drawing(1).transformed(using: CGAffineTransform(translationX: 0, y: 300)).strokes[0]
                // Legitimate latest ink is still unsaved when Carry is armed.
                let pending = PKDrawing(strokes: [drawing(1).strokes[0], crossing, below])
                canvas.drawing = pending
                controller.canvasViewDrawingDidChange(canvas)
                let sourceNodes = store.notebook(book)!.pages[0].nodes.count
                try tap("Carry to next page")
                controller.view.layoutIfNeeded(); viewport.layoutIfNeeded()
                let overlay = try carryOverlay()
                XCTAssertEqual(overlay.frame, viewport.bounds)
                let tapPoint = overlay.convert(CGPoint(x: 500, y: y), from: canvas)
                XCTAssertEqual(viewport.surface.convert(tapPoint, from: overlay).y, y, accuracy: 0.001)
                XCTAssertEqual(viewport.surface.bounds, bounds)
                XCTAssertEqual(viewport.surface.transform, transform)
                overlay.onTap?(tapPoint)
                let pages = store.notebook(book)!.pages
                XCTAssertEqual(pages.count, 3, "\(orientation) \(edge)")
                XCTAssertEqual(pages[0].id, page)
                XCTAssertEqual(pages[2].id, following.id)
                XCTAssertEqual(store.notebook(book)?.currentPage, pages[1].id)
                XCTAssertEqual(pages[0].nodes.count, sourceNodes + 1)
                let original = try store.drawing(book: book, page: pages[0])
                if #available(iOS 27.0, *) {
                    XCTAssertEqual(original.strokes.map(\.id), pending.strokes.map(\.id))
                }
                for (before, after) in zip(pending.strokes, original.strokes) {
                    XCTAssertEqual(after.path.map(\.location), before.path.map(\.location))
                    XCTAssertEqual(after.transform, before.transform)
                }
                XCTAssertEqual(store.objects(book: book, page: pages[0]), sourceObjects)
                let copied = try store.drawing(book: book, page: pages[1])
                XCTAssertEqual(copied.strokes.count, 2)
                for (before, after) in zip([crossing, below], copied.strokes) {
                    XCTAssertEqual(after.path.map(\.location), before.path.map(\.location))
                    XCTAssertEqual(after.transform.ty, before.transform.ty - y, accuracy: 0.001)
                    XCTAssertEqual(after.mask?.cgPath, before.mask?.cgPath)
                }
                XCTAssertLessThan(copied.bounds.minY, 0, "Crossing stroke remains whole")
                let copiedObjects = store.objects(book: book, page: pages[1])
                XCTAssertEqual(copiedObjects.count, 3)
                for (copy, original) in zip(copiedObjects, sourceObjects) {
                    XCTAssertEqual(copy.frame.y, original.frame.y - Double(y), accuracy: 0.0001)
                }
                XCTAssertLessThan(copiedObjects[0].frame.y, 0)
                let opened = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PageViewport }.first)
                controller.view.layoutIfNeeded(); opened.layoutIfNeeded()
                XCTAssertEqual(opened.surface.bounds.origin, .zero, "Never reveal hidden negative content")
                XCTAssertEqual(opened.surface.transform, transform, "No minY-driven refit")
                XCTAssertTrue(opened.surface.clipsToBounds)
                XCTAssertFalse(try carryButton().isSelected)
                XCTAssertFalse(descendants(controller.view).contains { $0 is CarryTapOverlay })
                XCTAssertEqual(canvas.drawing.strokes.count, 2, "Cut click must not make ink")
                controller.carryPage(at: tapPoint) // A late callback cannot carry again.
                XCTAssertEqual(store.notebook(book)?.pages.count, 3)
                controller.openPage(page)
            }
        }
        defaults.set(oldOrientation, forKey: DocumentOrientation.defaultsKey)
        controller.requestManualOrientation()
        try await settleWindowLayout(for: DocumentOrientation.saved())
    }

    func testCarryBelowEmptyRegionStillOpensOneBlankPage() throws {
        try tap("Carry to next page")
        controller.view.layoutIfNeeded()
        let overlay = try carryOverlay()
        overlay.onTap?(overlay.convert(CGPoint(x: 200, y: 800), from: canvas))
        let pages = store.notebook(book)!.pages
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(store.notebook(book)?.currentPage, pages[1].id)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
        XCTAssertEqual(try store.drawing(book: book, page: pages[0]).strokes.count, 2)
        XCTAssertFalse(try carryButton().isSelected)
    }

    func testCarryFlushAndHelperFailuresDisarmWithoutCreatingOrOpeningPage() throws {
        var errors = 0
        controller.enterBackground()
        controller = DrawController(store: store, aiClient: AIClient(token: ""),
            aiJournal: try AINetworkJournal(directory: folder.appendingPathComponent("network")),
            onError: { _, _ in errors += 1 })
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        let open = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.currentTitle?.contains("History regression") == true })
        open.sendActions(for: .touchUpInside)
        window.layoutIfNeeded()
        canvas = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? DrawingCanvas }.first)
        let index = folder.appendingPathComponent("notebooks.json")
        let bytes = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: index)
            try? bytes.write(to: index)
        }
        for count in [2, 3] {
            // First helper publication fails; then dirty-ink flush fails before carry.
            if count == 3 { canvas.drawing = drawing(3) }
            try tap("Carry to next page")
            controller.view.layoutIfNeeded()
            try carryOverlay().onTap?(CGPoint(x: 200, y: 20))
            XCTAssertEqual(errors, count - 1)
            XCTAssertEqual(store.notebook(book)?.pages.count, 1)
            XCTAssertEqual(store.notebook(book)?.currentPage, page)
            XCTAssertEqual(canvas.drawing.strokes.count, count)
            XCTAssertFalse(try carryButton().isSelected)
            XCTAssertFalse(descendants(controller.view).contains { $0 is CarryTapOverlay })
        }
    }

    func testUndoFlushesPendingInkAndLateEndCallback() throws {
        controller.canvasViewDidBeginUsingTool(canvas)
        // PencilKit may deliver the final drawing AFTER the end-tool callback.
        controller.canvasViewDidEndUsingTool(canvas)
        canvas.drawing = drawing(3)
        controller.canvasViewDrawingDidChange(canvas)
        try tap("Undo")
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        settle()
        try tap("Redo")
        XCTAssertEqual(canvas.drawing.strokes.count, 3)
        XCTAssertEqual(store.notebook(book)?.pages[0].nodes.count, 3)
    }
}
