import XCTest
import UIKit

final class DrawUITests: XCTestCase {
    private func launchFixture(fingerDrawing: Bool = false, isolated: Bool = false, aiAnswer: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture"]
        if fingerDrawing { app.launchArguments.append("--ui-test-finger-drawing") }
        if aiAnswer { app.launchArguments.append("--ui-test-ai-answer") }
        if isolated { app.launchEnvironment["DRAW_UI_TEST_FIXTURE_ID"] = UUID().uuidString }
        app.launch()
        setOrientation("Portrait", in: app)
        return app
    }

    private func setPenWidthFour(in app: XCUIApplication) {
        for _ in 0..<18 {
            guard let value = app.buttons["Pen"].value as? String,
                  let width = Double(value.replacingOccurrences(of: " pt", with: "")) else {
                XCTFail("Pen width is unavailable")
                return
            }
            if width == 4 { return }
            app.buttons[width < 4 ? "Thicker" : "Thinner"].tap()
        }
        XCTAssertEqual(app.buttons["Pen"].value as? String, "4 pt")
    }

    func testStartupInkBlueAndOnePointPersistChangesUntilRelaunch() {
        let app = launchFixture(isolated: true)
        setPosition("Bottom", in: app)
        openFixture(in: app)
        app.buttons["Pen"].tap() // Color/width defaults do not override a stored tool mode.
        func verifyDefaults() {
            XCTAssertTrue(app.buttons["Pen"].isSelected)
            XCTAssertEqual(app.buttons["Pen"].value as? String, "1 pt")
            XCTAssertTrue(app.buttons["Ink blue"].isSelected)
            XCTAssertFalse(app.buttons["Question"].isSelected)
        }
        verifyDefaults()
        app.buttons["Question"].tap()
        app.buttons["Thicker"].tap()
        app.buttons["New page"].tap()
        XCTAssertTrue(app.buttons["Question"].isSelected)
        XCTAssertEqual(app.buttons["Pen"].value as? String, "1.5 pt")
        app.buttons["Page overview"].tap()
        app.buttons["Documents"].tap()
        openFixture(in: app)
        XCTAssertTrue(app.buttons["Question"].isSelected)
        XCTAssertEqual(app.buttons["Pen"].value as? String, "1.5 pt")
        app.terminate()
        app.launch()
        openFixture(in: app)
        verifyDefaults()
    }

    private func recordKeyboardDiagnostics(_ stage: String, in app: XCUIApplication) {
        let value = app.otherElements["pageViewport"].value as? String ?? "missing"
        let counters = value.hasPrefix("observers=") ? value : "missing"
        let keyboard = app.keyboards.firstMatch
        let report = "stage=\(stage);AXKeyboard=\(keyboard.exists ? 1 : 0);frame=\(keyboard.exists ? keyboard.frame : .zero)\n\(counters)"
        let attachment = XCTAttachment(string: report)
        attachment.name = "keyboard-" + stage
        attachment.lifetime = .keepAlways
        add(attachment)
        if keyboard.exists {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "keyboard-" + stage + "-fixture"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    private func openFixture(in app: XCUIApplication) {
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'UI Test Notebook' AND NOT label BEGINSWITH 'Document options'")).firstMatch.tap()
    }

    private func setPosition(_ position: String, in app: XCUIApplication) {
        app.buttons["Settings"].tap()
        app.segmentedControls["toolbarPosition"].buttons[position].tap()
        app.buttons["Documents"].tap()
    }

    private func setOrientation(_ orientation: String, in app: XCUIApplication) {
        app.buttons["Settings"].tap()
        app.segmentedControls["documentOrientation"].buttons[orientation].tap()
        app.buttons["Documents"].tap()
        assertOrientation(orientation, in: app)
    }

    private func assertOrientation(_ orientation: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let landscape = orientation == "Landscape"
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            landscape ? app.frame.width > app.frame.height : app.frame.height > app.frame.width
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
    }

    func testManualLandscapePersistsGatesDocumentsAndKeepsAllToolbarEdgesAndThreeByThreeOverview() {
        XCUIDevice.shared.orientation = .portrait
        let app = launchFixture(fingerDrawing: true, isolated: true)
        defer {
            if app.alerts.buttons["Cancel"].exists { app.alerts.buttons["Cancel"].tap() }
            if app.buttons["Page overview"].exists { app.buttons["Page overview"].tap() }
            if app.buttons["Documents"].exists { app.buttons["Documents"].tap() }
            setOrientation("Portrait", in: app)
            setPosition("Bottom", in: app)
            XCUIDevice.shared.orientation = .portrait
        }
        // Physical device orientation alone must never opt in to landscape.
        XCUIDevice.shared.orientation = .landscapeLeft
        assertOrientation("Portrait", in: app)
        XCUIDevice.shared.orientation = .portrait
        setOrientation("Landscape", in: app)
        let legacy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'UI Test Notebook,'")).firstMatch
        XCTAssertTrue(legacy.exists)
        XCTAssertFalse(legacy.isEnabled)
        let options = app.buttons["Document options UI Test Notebook"]
        XCTAssertTrue(options.isEnabled)
        options.tap()
        app.descendants(matching: .any).matching(identifier: "Rename").firstMatch.tap()
        XCTAssertTrue(app.alerts.textFields.firstMatch.exists)
        app.alerts.buttons["Cancel"].tap()
        let name = "Landscape " + String(UUID().uuidString.prefix(6))
        app.buttons["New document"].tap()
        app.alerts.textFields.firstMatch.typeText(name)
        app.alerts.buttons["Create"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let page = app.otherElements["pageViewport"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        app.buttons["Pen"].tap()
        app.buttons["Black"].tap()
        setPenWidthFour(in: app)
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3)).press(forDuration: 0.05,
            thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.3)))
        let ink = app.otherElements.matching(NSPredicate(format: "label CONTAINS[c] 'black'")).firstMatch
        XCTAssertTrue(ink.waitForExistence(timeout: 5))
        let drawingImage = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        drawingImage.name = "landscape-native-ink"
        drawingImage.lifetime = .keepAlways
        add(drawingImage)
        app.buttons["Undo"].tap()
        XCTAssertFalse(ink.exists)
        app.buttons["Redo"].tap()
        XCTAssertTrue(ink.waitForExistence(timeout: 5))
        for _ in 0..<8 { app.buttons["New page"].tap() }
        app.buttons["Page overview"].tap()
        let grid = app.otherElements["pageOverviewGrid"]
        XCTAssertTrue(grid.exists)
        let cells = grid.buttons.allElementsBoundByIndex
        XCTAssertEqual(cells.count, 9)
        if cells.count == 9 {
            // Physical portrait AX axes must be rotated into the manual landscapeRight interface.
            let window = app.windows.firstMatch.frame
            let centers = cells.map { CGPoint(x: $0.frame.midY - window.minY,
                                               y: window.maxX - $0.frame.midX) }
            for r in 0..<3 {
                for c in 0..<3 {
                    XCTAssertEqual(centers[r * 3 + c].y, centers[r * 3].y, accuracy: 1)
                    XCTAssertEqual(centers[r * 3 + c].x, centers[c].x, accuracy: 1)
                }
            }
            XCTAssertLessThan(centers[0].x, centers[1].x)
            XCTAssertLessThan(centers[1].x, centers[2].x)
            XCTAssertLessThan(centers[0].y, centers[3].y)
            XCTAssertLessThan(centers[3].y, centers[6].y)
        }
        app.buttons["Documents"].tap()
        for edge in ["Bottom", "Top", "Right", "Left"] {
            setPosition(edge, in: app)
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch.tap()
            let bar = app.otherElements["drawingToolbar"]
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            XCTAssertEqual(bar.buttons.count, 25)
            // AX elements and windows use screen axes when the manual interface
            // orientation differs from the device. app.frame uses interface axes.
            let windowFrame = app.windows.firstMatch.frame
            for button in bar.buttons.allElementsBoundByIndex {
                XCTAssertTrue(windowFrame.contains(button.frame), "\(edge): \(button.label) outside window")
                if button.isEnabled { XCTAssertTrue(button.isHittable, "\(edge): \(button.label) inaccessible") }
            }
            for tool in ["Highlighter", "Selection", "Ruler", "Pen", "Question"] {
                XCTAssertTrue(app.buttons[tool].isEnabled)
                app.buttons[tool].tap()
            }
            app.buttons["Page overview"].tap()
            app.buttons["Documents"].tap()
        }
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app.launch() // Do not use launchFixture: this relaunch must retain the saved mode.
        assertOrientation("Landscape", in: app)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.segmentedControls["documentOrientation"].buttons["Landscape"].isSelected)
        app.buttons["Documents"].tap()
        XCTAssertFalse(legacy.isEnabled)
        XCUIDevice.shared.orientation = .landscapeLeft
        assertOrientation("Landscape", in: app)
        XCUIDevice.shared.orientation = .portrait
        assertOrientation("Landscape", in: app)
        let wide = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
        XCTAssertTrue(wide.isEnabled)
        wide.tap()
        XCTAssertTrue(app.otherElements["pageViewport"].waitForExistence(timeout: 5))
        app.buttons["Page overview"].tap()
        app.buttons["Documents"].tap()
        setOrientation("Portrait", in: app)
        XCTAssertTrue(legacy.isEnabled)
        XCTAssertFalse(wide.isEnabled)
        XCTAssertTrue(app.buttons["Document options \(name)"].isEnabled)
    }

    func testPortraitToolbarAndOverview() {
        let app = launchFixture()
        setPosition("Bottom", in: app)
        openFixture(in: app)
        XCTAssertTrue(app.buttons["Erase next stroke"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Ink blue"].exists)
        XCTAssertTrue(app.buttons["Redo"].exists)
        XCTAssertTrue(app.buttons["Highlighter"].isEnabled)
        XCTAssertTrue(app.buttons["Selection"].isEnabled)
        XCTAssertTrue(app.buttons["Ruler"].isEnabled)
        XCTAssertLessThan(app.buttons["Undo"].frame.midX, app.buttons["Redo"].frame.midX)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "drawing-toolbar"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["New page"].tap()
        app.buttons["Page overview"].tap()
        XCTAssertTrue(app.buttons["Duplicate to left"].exists)
        XCTAssertTrue(app.buttons["Deleted pages"].exists)
        let overview = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        overview.name = "overview-three-by-three"
        overview.lifetime = .keepAlways
        add(overview)
    }

    func testToolbarPositionsPersistAndKeepEveryControlVisible() {
        let app = launchFixture()
        for edge in ["Bottom", "Top", "Right", "Left"] {
            setPosition(edge, in: app)
            app.terminate()
            app.launch()
            app.buttons["Settings"].tap()
            XCTAssertTrue(app.segmentedControls["toolbarPosition"].buttons[edge].isSelected)
            app.buttons["Documents"].tap()
            openFixture(in: app)
            let bar = app.otherElements["drawingToolbar"]
            let page = app.otherElements["pageViewport"]
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            XCTAssertEqual(bar.buttons.count, 25)
            let surface = app.otherElements["drawingSurface"]
            XCTAssertEqual(surface.frame.minY, page.frame.minY, accuracy: 1)
            XCTAssertEqual(surface.frame.maxY, page.frame.maxY, accuracy: 1)
            XCTAssertEqual(surface.frame.minX, page.frame.minX, accuracy: 1)
            XCTAssertEqual(surface.frame.maxX, page.frame.maxX, accuracy: 1)
            for button in bar.buttons.allElementsBoundByIndex {
                XCTAssertTrue(app.frame.contains(button.frame), "\(edge): \(button.label) outside screen")
                if button.isEnabled { XCTAssertTrue(button.isHittable, "\(edge): \(button.label) inaccessible") }
            }
            switch edge {
            case "Bottom": XCTAssertGreaterThanOrEqual(bar.frame.minY, page.frame.maxY - 1)
            case "Top": XCTAssertLessThanOrEqual(bar.frame.maxY, page.frame.minY + 1)
            case "Right": XCTAssertGreaterThanOrEqual(bar.frame.minX, page.frame.maxX - 1)
            default: XCTAssertLessThanOrEqual(bar.frame.maxX, page.frame.minX + 1)
            }
            let first = app.buttons["Previous page"].frame
            let last = app.buttons["Carry to next page"].frame
            if edge == "Right" || edge == "Left" {
                XCTAssertEqual(first.midX, last.midX, accuracy: 1)
                XCTAssertLessThan(first.midY, last.midY)
            } else {
                XCTAssertEqual(first.midY, last.midY, accuracy: 1)
                XCTAssertLessThan(first.midX, last.midX)
            }
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "toolbar-\(edge)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.buttons["Page overview"].tap()
            app.buttons["Documents"].tap()
        }
        setPosition("Bottom", in: app)
    }

    func testFingerEditingDoesNotOpenMenuOrKeyboard() {
        let app = launchFixture()
        setPosition("Bottom", in: app)
        openFixture(in: app)
        app.buttons["Pen"].tap()
        // Touch the page rather than depending on PencilKit's private AX element type.
        let page = app.otherElements["pageViewport"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).press(forDuration: 1.5)
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        // XCTest's multi-touch hit testing treats PKCanvasView's internal surface
        // as an occluder. Multi-finger taps need a physical-iPad check.
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.buttons["Insert Space"].exists)
        XCTAssertFalse(app.buttons["Select All"].exists)
        XCTAssertFalse(app.menuItems["Select All"].exists)
        XCTAssertTrue(app.buttons["Pen"].isHittable)
    }

    func testPaperPatternsCycleBackToBlank() {
        let app = launchFixture()
        setPosition("Bottom", in: app)
        openFixture(in: app)
        let paper = app.buttons["Change paper"]
        var seen = Set<String>()
        for _ in 0..<4 {
            paper.tap()
            let pattern = paper.value as? String ?? ""
            seen.insert(pattern)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "paper-\(pattern)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertEqual(seen, Set(["Blank", "Dots", "Lines", "Grid"]))
    }

    func testRealDrawingGesturesDoNotNavigateHistory() {
        // Simulator fingers drive PencilKit's actual gesture/rendering pipeline.
        // This input override is unavailable in physical-device/Release builds.
        let app = launchFixture(fingerDrawing: true)
        setPosition("Bottom", in: app)
        openFixture(in: app)
        app.buttons["New page"].tap()
        app.buttons["Pen"].tap()
        app.buttons["Black"].tap()
        setPenWidthFour(in: app)
        let page = app.otherElements["pageViewport"]
        func draw(_ y: CGFloat) {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: y)).press(forDuration: 0.05,
                thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: y)))
        }
        func verify(_ visible: Set<Int>, file: StaticString = #filePath, line: UInt = #line) {
            let screenshot = XCUIScreen.main.screenshot().image.cgImage!
            let scale = CGFloat(screenshot.width) / app.frame.width
            for (i, y) in [0.2, 0.35, 0.5, 0.65, 0.75, 0.8, 0.9, 0.1].enumerated() {
                let area = CGRect(x: page.frame.minX + page.frame.width * 0.3,
                                  y: page.frame.minY + page.frame.height * y - 8,
                                  width: page.frame.width * 0.3, height: 16)
                let crop = screenshot.cropping(to: CGRect(x: area.minX * scale, y: area.minY * scale,
                                                         width: area.width * scale, height: area.height * scale).integral)!
                var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
                pixels.withUnsafeMutableBytes { data in
                    let context = CGContext(data: data.baseAddress, width: crop.width, height: crop.height,
                        bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                }
                let dark = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 80 && pixels[$0 + 1] < 80 && pixels[$0 + 2] < 80 }.count
                if visible.contains(i) { XCTAssertGreaterThan(dark, 30, "Missing stroke \(i)", file: file, line: line) }
                else { XCTAssertEqual(dark, 0, "History stroke \(i) unexpectedly appeared", file: file, line: line) }
            }
        }
        draw(0.2)
        draw(0.35)
        verify([0, 1])
        app.buttons["Undo"].tap()
        verify([0])
        draw(0.5)
        verify([0, 2])
        app.buttons["Undo"].tap()
        verify([0])
        app.buttons["Redo"].tap()
        verify([0, 2])
        draw(0.65)
        verify([0, 2, 3])
        app.buttons["Undo"].tap()
        app.buttons["Redo"].tap()
        draw(0.75)
        verify([0, 2, 3, 4])
        app.buttons["Undo"].tap()
        verify([0, 2, 3])
        draw(0.8) // Another abandoned branch stays in Store, without hidden UI controls.
        verify([0, 2, 3, 5])
        app.buttons["Page overview"].tap()
        app.buttons["Documents"].tap()
        openFixture(in: app)
        draw(0.9)
        verify([0, 2, 3, 5, 6])
        XCTAssertFalse(app.buttons["Object eraser"].exists)
        app.buttons["Erase next stroke"].tap()
        draw(0.2)
        verify([2, 3, 5, 6])
        app.buttons["Undo"].tap()
        verify([0, 2, 3, 5, 6])
        app.buttons["Redo"].tap()
        verify([2, 3, 5, 6])
        app.buttons["Black"].tap()
        draw(0.1)
        verify([2, 3, 5, 6, 7])
    }

    func testCarryRealTapCopiesCrossingInkAndAIWithoutChangingSourceOrNextPageOrder() {
        let app = launchFixture(fingerDrawing: true, isolated: true, aiAnswer: true)
        setPosition("Bottom", in: app)
        openFixture(in: app)
        app.buttons["New page"].tap() // Source is page 2; retain the fixture's page 1.
        app.buttons["New page"].tap() // Existing page 3 must become page 4.
        app.buttons["Previous page"].tap()
        app.buttons["Pen"].tap()
        app.buttons["Black"].tap()
        setPenWidthFour(in: app)
        let page = app.otherElements["pageViewport"]
        let surface = app.otherElements["drawingSurface"]
        let frame = surface.frame
        let scale = min(page.frame.width / 1024, page.frame.height / 1361)
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            page.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x * scale, dy: y * scale))
        }
        point(350, 120).press(forDuration: 0.05, thenDragTo: point(650, 120))
        point(350, 240).press(forDuration: 0.05, thenDragTo: point(350, 340))
        point(350, 500).press(forDuration: 0.05, thenDragTo: point(650, 500))
        app.buttons["AI"].tap()
        let layer = app.otherElements["aiObjectsLayer"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (layer.value as? String) == "3" && app.buttons["AI"].isEnabled
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        let strokes = app.otherElements.matching(NSPredicate(format: "label CONTAINS[c] 'black'"))
        XCTAssertEqual(strokes.count, 3)
        func pagePixels() -> Data? {
            let screenshot = XCUIScreen.main.screenshot().image.cgImage!
            let pixelScale = CGFloat(screenshot.width) / app.frame.width
            let crop = screenshot.cropping(to: CGRect(x: page.frame.minX * pixelScale, y: page.frame.minY * pixelScale,
                width: page.frame.width * pixelScale, height: page.frame.height * pixelScale).integral)
            guard let crop else { return nil }
            var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            pixels.withUnsafeMutableBytes { data in
                let context = CGContext(data: data.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            }
            return Data(pixels)
        }
        let sourcePixels = pagePixels()
        XCTAssertNotNil(sourcePixels)
        app.buttons["Carry to next page"].tap()
        XCTAssertTrue(app.buttons["Carry to next page"].isSelected)
        // An armed drag is consumed but must not count as the intentional tap.
        point(800, 280).press(forDuration: 0.05, thenDragTo: point(850, 330))
        XCTAssertTrue(app.buttons["Carry to next page"].isSelected)
        XCTAssertEqual(strokes.count, 3)
        point(850, 280).tap()
        XCTAssertFalse(app.buttons["Carry to next page"].isSelected)
        XCTAssertEqual(strokes.count, 2, "Tap must not draw or erase; crossing stroke remains")
        XCTAssertEqual(layer.value as? String, "3", "Whole crossing AI object must be copied")
        XCTAssertEqual(surface.frame, frame, "No refit to reveal the hidden upper portion")
        // The crossing stroke now runs from -40 to 60. Its visible part touches
        // the top edge, while the unrelated upper horizontal stroke is absent.
        let crossing = strokes.allElementsBoundByIndex.first { $0.frame.width < $0.frame.height }
        XCTAssertNotNil(crossing)
        if let crossing {
            XCTAssertLessThanOrEqual(crossing.frame.minY, page.frame.minY + 2)
            XCTAssertEqual(crossing.frame.maxY, page.frame.minY + 60 * scale, accuracy: 8)
        }
        app.buttons["Next page"].tap()
        XCTAssertEqual(strokes.count, 0, "Existing following page stays blank")
        XCTAssertEqual(layer.value as? String, "0")
        app.buttons["Previous page"].tap()
        XCTAssertEqual(strokes.count, 2)
        app.buttons["Previous page"].tap()
        XCTAssertEqual(strokes.count, 3)
        XCTAssertEqual(layer.value as? String, "3")
        XCTAssertEqual(pagePixels(), sourcePixels, "Source ink and generated content must be visually unchanged")
        app.buttons["Page overview"].tap()
        let cells = app.otherElements["pageOverviewGrid"].buttons.allElementsBoundByIndex
        XCTAssertEqual(cells.map(\.label), ["Page 1", "Page 2", "Page 3", "Page 4"])
    }

    func testCarryFingerTapWorksWithPencilOnlyCanvasAndCancelsOnSecondButtonTap() {
        let app = launchFixture(isolated: true)
        setPosition("Bottom", in: app)
        openFixture(in: app)
        app.buttons["Pen"].tap()
        let page = app.otherElements["pageViewport"]
        let carry = app.buttons["Carry to next page"]
        carry.tap()
        XCTAssertTrue(carry.isSelected)
        carry.tap()
        XCTAssertFalse(carry.isSelected)
        let strokes = app.otherElements.matching(NSPredicate(format: "label CONTAINS[c] 'black'"))
        for tool in ["Pen", "Selection", "Ruler", "Erase next stroke"] {
            app.buttons[tool].tap()
            carry.tap()
            XCTAssertTrue(carry.isSelected)
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7)).tap()
            XCTAssertFalse(carry.isSelected)
            XCTAssertEqual(strokes.count, 0, tool)
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            app.buttons["Previous page"].tap()
            XCTAssertEqual(strokes.count, 1, "\(tool): source stroke unchanged")
        }
        app.buttons["Page overview"].tap()
        XCTAssertEqual(app.otherElements["pageOverviewGrid"].buttons.count, 5)
    }

    func testQuestionAndInkBlueAreDistinctOnPaperAndAfterReopening() {
        let app = launchFixture(fingerDrawing: true)
        setPosition("Bottom", in: app)
        openFixture(in: app)
        app.buttons["New page"].tap()
        app.buttons["Pen"].tap()
        setPenWidthFour(in: app)
        let page = app.otherElements["pageViewport"]
        for (name, y) in [("Question", 0.2), ("Ink blue", 0.5)] {
            app.buttons[name].tap()
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: y)).press(forDuration: 0.05,
                thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: y)))
        }
        func verifyColors() {
            let screenshot = XCUIScreen.main.screenshot().image.cgImage!
            let scale = CGFloat(screenshot.width) / app.frame.width
            for (rgb, y) in [([175, 82, 222], 0.2), ([0, 51, 204], 0.5)] {
                let area = CGRect(x: page.frame.minX + page.frame.width * 0.3,
                                  y: page.frame.minY + page.frame.height * y - 8,
                                  width: page.frame.width * 0.3, height: 16)
                let crop = screenshot.cropping(to: CGRect(x: area.minX * scale, y: area.minY * scale,
                                                         width: area.width * scale, height: area.height * scale).integral)!
                var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
                pixels.withUnsafeMutableBytes { data in
                    let context = CGContext(data: data.baseAddress, width: crop.width, height: crop.height,
                        bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                }
                let matches = stride(from: 0, to: pixels.count, by: 4).filter { i in
                    (0..<3).allSatisfy { abs(Int(pixels[i + $0]) - rgb[$0]) <= 6 }
                }.count
                XCTAssertGreaterThan(matches, 30)
            }
        }
        verifyColors()
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "question-and-ink-blue-colors"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Page overview"].tap()
        app.buttons["Documents"].tap()
        openFixture(in: app)
        verifyColors()
    }

    func testSelectedInkRecolorsOnPaperAndNewDrawingDoesNotResurrectIt() {
        let app = launchFixture(fingerDrawing: true)
        setPosition("Bottom", in: app)
        openFixture(in: app)
        app.buttons["New page"].tap()
        app.buttons["Pen"].tap()
        app.buttons["Black"].tap()
        setPenWidthFour(in: app)
        let page = app.otherElements["pageViewport"]
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            page.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        }
        func draw(_ y: CGFloat) {
            point(0.25, y).press(forDuration: 0.05, thenDragTo: point(0.65, y))
        }
        func verifyColor(_ y: CGFloat, blue: Bool, file: StaticString = #filePath, line: UInt = #line) {
            let screenshot = XCUIScreen.main.screenshot().image.cgImage!
            let scale = CGFloat(screenshot.width) / app.frame.width
            let area = CGRect(x: page.frame.minX + page.frame.width * 0.3,
                              y: page.frame.minY + page.frame.height * y - 8,
                              width: page.frame.width * 0.3, height: 16)
            let crop = screenshot.cropping(to: CGRect(x: area.minX * scale, y: area.minY * scale,
                                                     width: area.width * scale, height: area.height * scale).integral)!
            var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            pixels.withUnsafeMutableBytes { data in
                let context = CGContext(data: data.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            }
            let blackPixels = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 80 && pixels[$0 + 1] < 80 && pixels[$0 + 2] < 80 }.count
            let bluePixels = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 100 && pixels[$0 + 2] > 150 && Int(pixels[$0 + 2]) - Int(pixels[$0]) > 100 }.count
            XCTAssertGreaterThan(blue ? bluePixels : blackPixels, 30, file: file, line: line)
            XCTAssertEqual(blue ? blackPixels : bluePixels, 0, file: file, line: line)
        }
        draw(0.2)
        draw(0.5)
        app.buttons["Selection"].tap()
        let viewportBeforeSelection = page.frame
        point(0.45, 0.2).press(forDuration: 1)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Selecting ink must not open the keyboard")
        XCTAssertEqual(page.frame, viewportBeforeSelection)
        recordKeyboardDiagnostics("selected-ink", in: app)
        let selectionImage = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        selectionImage.name = "ink-selection-before-color"
        selectionImage.lifetime = .keepAlways
        add(selectionImage)
        app.buttons["Blue"].tap()
        XCTAssertTrue(app.buttons["Selection"].isSelected)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        recordKeyboardDiagnostics("recolored-ink", in: app)
        app.buttons["Pen"].tap() // Hide native selection tint before sampling actual ink pixels.
        verifyColor(0.2, blue: true)
        verifyColor(0.5, blue: false)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "selected-ink-recolored"
        image.lifetime = .keepAlways
        add(image)
        app.buttons["Undo"].tap()
        verifyColor(0.2, blue: false)
        app.buttons["Redo"].tap()
        verifyColor(0.2, blue: true)
        app.buttons["Pen"].tap()
        draw(0.7)
        verifyColor(0.2, blue: true)
        verifyColor(0.5, blue: false)
        verifyColor(0.7, blue: true)
        app.buttons["Page overview"].tap()
        app.buttons["Documents"].tap()
        openFixture(in: app)
        verifyColor(0.2, blue: true)
        verifyColor(0.5, blue: false)
    }

    func testNativeHighlighterSelectionAndRuler() {
        let app = launchFixture(fingerDrawing: true)
        setPosition("Bottom", in: app)
        openFixture(in: app)
        app.buttons["New page"].tap()
        app.buttons["Pen"].tap()
        app.buttons["Black"].tap()
        setPenWidthFour(in: app)
        let page = app.otherElements["pageViewport"]
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            page.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        }
        point(0.25, 0.2).press(forDuration: 0.05, thenDragTo: point(0.65, 0.2))
        let blackStrokes = app.otherElements.matching(NSPredicate(format: "label CONTAINS[c] %@", "black"))
        let black = blackStrokes.firstMatch
        let originalY = black.frame.midY
        app.buttons["Highlighter"].tap()
        app.buttons["Yellow"].tap()
        // Other tests can persist the 8pt minimum. Establish at least 20pt here.
        for _ in 0..<6 { app.buttons["Thicker"].tap() }
        XCTAssertTrue(app.buttons["Highlighter"].isSelected)
        point(0.25, 0.5).press(forDuration: 0.05, thenDragTo: point(0.65, 0.5))
        let marker = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Marker")).firstMatch
        XCTAssertTrue(marker.exists)
        let markerHeight = marker.frame.height
        XCTAssertGreaterThan(markerHeight, 10)
        app.buttons["Selection"].tap()
        XCTAssertTrue(app.buttons["Selection"].isSelected)
        point(0.45, 0.2).press(forDuration: 1)
        point(0.45, 0.2).press(forDuration: 0.1, thenDragTo: point(0.45, 0.35))
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Moving selected ink must not open the keyboard")
        XCTAssertGreaterThan(black.frame.midY, originalY + 100)
        recordKeyboardDiagnostics("moved-ink", in: app)
        let selected = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        selected.name = "native-selection-moved"
        selected.lifetime = .keepAlways
        add(selected)
        black.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        let menu = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        menu.name = "native-selection-menu"
        menu.lifetime = .keepAlways
        add(menu)
        let delete = app.descendants(matching: .any).matching(identifier: "Delete").firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertFalse(black.exists)
        app.buttons["Undo"].tap()
        XCTAssertTrue(black.waitForExistence(timeout: 5))
        app.buttons["Redo"].tap()
        XCTAssertFalse(black.exists)
        XCTAssertEqual(marker.frame.height, markerHeight, accuracy: 1)
        app.buttons["Pen"].tap()
        app.buttons["Black"].tap()
        setPenWidthFour(in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["Ruler"].tap()
        XCTAssertTrue(app.buttons["Ruler"].isSelected)
        point(0.3, 0.7).press(forDuration: 0.05, thenDragTo: point(0.7, 0.8))
        let ruler = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        ruler.name = "native-highlighter-and-ruler"
        ruler.lifetime = .keepAlways
        add(ruler)
        app.buttons["Ruler"].tap()
        XCTAssertFalse(app.buttons["Ruler"].isSelected)
        point(0.25, 0.9).press(forDuration: 0.05, thenDragTo: point(0.65, 0.9))
        XCTAssertEqual(blackStrokes.count, 2)
        XCTAssertTrue(marker.exists)
    }

    func testFoldersOrganizeHomeAndSurviveRelaunchWithoutChangingInk() {
        var app = launchFixture()
        let name = "Folder " + String(UUID().uuidString.prefix(6))
        app.buttons["New folder"].tap()
        app.alerts.textFields.firstMatch.typeText(name)
        app.alerts.buttons["Create"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Open folder \(name)"].waitForExistence(timeout: 5))
        app.buttons["Document options UI Test Notebook"].tap()
        app.descendants(matching: .any).matching(identifier: "Move to").firstMatch.tap()
        app.descendants(matching: .any).matching(identifier: name).firstMatch.tap()
        XCTAssertFalse(app.buttons["Document options UI Test Notebook"].exists)
        app.terminate()
        app = launchFixture()
        app.buttons["Open folder \(name)"].tap()
        XCTAssertTrue(app.buttons["Document options UI Test Notebook"].exists)
        openFixture(in: app)
        XCTAssertTrue(app.buttons["Pen"].exists)
        app.buttons["Page overview"].tap()
        app.buttons["Documents"].tap()
        app.buttons["Back to Documents"].tap()
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "home-folders"
        image.lifetime = .keepAlways
        add(image)
        app.buttons["Folder options \(name)"].tap()
        app.descendants(matching: .any).matching(identifier: "Delete folder").firstMatch.tap()
        XCTAssertFalse(app.buttons["Open folder \(name)"].exists)
        XCTAssertTrue(app.buttons["Document options UI Test Notebook"].exists)
    }

    func testNestedFolderBrowsingMovesAndDeletionPreserveSubtreeAndNotes() {
        let app = launchFixture(isolated: true)
        func createFolder(_ name: String) {
            app.buttons["New folder"].tap()
            app.alerts.textFields.firstMatch.typeText(name)
            app.alerts.buttons["Create"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons["Open folder \(name)"].waitForExistence(timeout: 5))
        }
        func choose(_ name: String) {
            let item = app.descendants(matching: .any).matching(identifier: name).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            item.tap()
        }
        createFolder("Semester")
        createFolder("Other")
        app.buttons["Open folder Semester"].tap()
        createFolder("Math")
        app.buttons["Open folder Math"].tap()
        createFolder("Exercises")
        app.buttons["New document"].tap()
        app.alerts.textFields.firstMatch.typeText("Direct note")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["Page overview"].waitForExistence(timeout: 5))
        app.buttons["Page overview"].tap()
        app.buttons["Documents"].tap()
        XCTAssertTrue(app.buttons["Document options Direct note"].exists)
        app.buttons["Back to Semester"].tap()
        XCTAssertFalse(app.buttons["Open folder Exercises"].exists)
        XCTAssertFalse(app.buttons["Document options Direct note"].exists)
        app.buttons["Back to Documents"].tap()
        XCTAssertFalse(app.buttons["Open folder Math"].exists)
        app.buttons["Document options UI Test Notebook"].tap()
        choose("Move to")
        choose("Semester / Math / Exercises")
        XCTAssertFalse(app.buttons["Document options UI Test Notebook"].exists)
        app.buttons["Open folder Semester"].tap()
        app.buttons["Folder options Math"].tap()
        choose("Move to")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "Semester / Math").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "Semester / Math / Exercises").firstMatch.exists)
        choose("Other")
        XCTAssertFalse(app.buttons["Open folder Math"].exists)
        app.buttons["Back to Documents"].tap()
        app.buttons["Open folder Other"].tap()
        app.buttons["Open folder Math"].tap()
        XCTAssertTrue(app.buttons["Document options Direct note"].exists)
        app.buttons["Open folder Exercises"].tap()
        XCTAssertTrue(app.buttons["Document options UI Test Notebook"].exists)
        openFixture(in: app)
        let ink = app.otherElements.matching(NSPredicate(format: "label CONTAINS[c] 'black'")).firstMatch
        XCTAssertTrue(ink.waitForExistence(timeout: 5))
        app.buttons["Page overview"].tap()
        app.buttons["Documents"].tap()
        app.buttons["Back to Other / Math"].tap()
        app.buttons["Back to Other"].tap()
        app.buttons["Folder options Math"].tap()
        choose("Delete folder")
        XCTAssertFalse(app.buttons["Open folder Math"].exists)
        XCTAssertTrue(app.buttons["Document options Direct note"].exists)
        XCTAssertTrue(app.buttons["Open folder Exercises"].exists)
        app.terminate()
        app.launch()
        XCTAssertFalse(app.buttons["Open folder Exercises"].exists)
        app.buttons["Open folder Other"].tap()
        XCTAssertTrue(app.buttons["Document options Direct note"].exists)
        app.buttons["Open folder Exercises"].tap()
        XCTAssertTrue(app.buttons["Document options UI Test Notebook"].exists)
        app.buttons["Back to Other"].tap()
        app.buttons["Back to Documents"].tap()
        app.buttons["Folder options Other"].tap()
        choose("Delete folder")
        XCTAssertTrue(app.buttons["Document options Direct note"].exists)
        app.buttons["Open folder Exercises"].tap()
        XCTAssertTrue(app.buttons["Document options UI Test Notebook"].exists)
    }

    func testDocumentNameTextEntryStillWorks() {
        let app = launchFixture()
        app.buttons["New document"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Keyboard check")
        XCTAssertEqual(field.value as? String, "Keyboard check")
        XCTAssertTrue(app.alerts.buttons["Create"].isEnabled)
    }
    func testApprovedAIObjectsPreserveLaterInkAndViewportAtEveryEdgeBothOrientations() {
        let app = launchFixture(fingerDrawing: true, isolated: true, aiAnswer: true)
        defer {
            if app.buttons["Page overview"].exists { app.buttons["Page overview"].tap() }
            if app.buttons["Documents"].exists { app.buttons["Documents"].tap() }
            setOrientation("Portrait", in: app)
            setPosition("Bottom", in: app)
        }
        for orientation in ["Portrait", "Landscape"] {
            setOrientation(orientation, in: app)
            let name = "AI " + orientation + " " + String(UUID().uuidString.prefix(6))
            app.buttons["New document"].tap()
            app.alerts.textFields.firstMatch.typeText(name)
            app.alerts.buttons["Create"].tap()
            app.buttons["Page overview"].tap()
            app.buttons["Documents"].tap()
            for edge in ["Bottom", "Top", "Right", "Left"] {
                setPosition(edge, in: app)
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch.tap()
                app.buttons["New page"].tap()
                app.buttons["Pen"].tap()
                app.buttons["Black"].tap()
                setPenWidthFour(in: app)
                XCTAssertFalse(app.buttons["Missed"].exists)
                XCTAssertEqual(app.buttons.matching(identifier: "AI").count, 1)
                let page = app.otherElements["pageViewport"]
                let surface = app.otherElements["drawingSurface"]
                let frame = surface.frame
                func draw(_ y: CGFloat) {
                    page.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: y)).press(forDuration: 0.05,
                        thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: y)))
                }
                draw(0.15)
                app.buttons["AI"].tap()
                XCTAssertFalse(app.buttons["AI"].isEnabled)
                draw(0.6) // Later handwriting while the approved result is in flight.
                let layer = app.otherElements["aiObjectsLayer"]
                let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    (layer.value as? String) == "3" && app.buttons["AI"].isEnabled
                }, object: app)
                XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
                XCTAssertEqual(surface.frame, frame, "\(orientation) \(edge): result refit viewport")
                let strokes = app.otherElements.matching(NSPredicate(format: "label CONTAINS[c] 'black'"))
                XCTAssertGreaterThanOrEqual(strokes.count, 2, "Later native ink must remain")
                app.buttons["Undo"].tap()
                XCTAssertEqual(layer.value as? String, "0")
                XCTAssertGreaterThanOrEqual(strokes.count, 2)
                app.buttons["Redo"].tap()
                XCTAssertEqual(layer.value as? String, "3")
                let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                image.name = "approved-circle-math-text-\(orientation)-\(edge)"
                image.lifetime = .keepAlways
                add(image)
                app.buttons["Page overview"].tap()
                XCTAssertTrue(app.otherElements["pageOverviewGrid"].exists)
                app.buttons["Documents"].tap()
            }
        }
    }

}
