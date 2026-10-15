import XCTest
import UIKit
@testable import Draw

@MainActor
final class PaperViewTests: XCTestCase {
    private func render(_ patterns: [Int], size: CGSize = CGSize(width: 180, height: 180)) -> UIImage {
        let paper = PaperView(frame: CGRect(origin: .zero, size: size))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            // Simulate a reused backing store. Each draw must replace its old pixels.
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(paper.bounds)
            for pattern in patterns {
                paper.pattern = pattern
                paper.draw(paper.bounds)
            }
        }
    }

    func testEveryPatternReplacesEarlierPatterns() {
        for pattern in 0...3 {
            XCTAssertEqual(render([1, 2, 3, 0, 3, 2, 1, pattern]).pngData(), render([pattern]).pngData())
        }
        let blank = render([1, 2, 3, 0]).cgImage!
        let data = blank.dataProvider!.data!
        let bytes = CFDataGetBytePtr(data)!
        for y in 0..<blank.height {
            for x in 0..<blank.width {
                let offset = y * blank.bytesPerRow + x * 4
                XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes + offset, count: 4)), [255, 255, 255, 255])
            }
        }
    }

    func testGridSpacingIsLargerAndConsistentAfterResize() {
        XCTAssertEqual(PaperView.spacing, 36)
        let paper = PaperView()
        XCTAssertEqual(paper.contentMode, .redraw)
        XCTAssertTrue(paper.isOpaque)
        for size in [CGSize(width: 180, height: 180), CGSize(width: 220, height: 320)] {
            let grid = render([3], size: size).cgImage!
            let data = grid.dataProvider!.data!
            let bytes = CFDataGetBytePtr(data)!
            func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                Array(UnsafeBufferPointer(start: bytes + y * grid.bytesPerRow + x * 4, count: 4))
            }
            XCTAssertEqual(pixel(24, 24), [255, 255, 255, 255])
            XCTAssertNotEqual(pixel(36, 36), [255, 255, 255, 255])
        }
    }
}
