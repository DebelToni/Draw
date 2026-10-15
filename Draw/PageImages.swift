import UIKit
import PencilKit

enum QuestionInk {
    static let color = UIColor(red: 175.0 / 255, green: 82.0 / 255, blue: 222.0 / 255, alpha: 1)

    static func matches(_ color: UIColor) -> Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        let tolerance: CGFloat = 0.5 / 255
        return abs(red - 175.0 / 255) < tolerance && abs(green - 82.0 / 255) < tolerance
            && abs(blue - 222.0 / 255) < tolerance && abs(alpha - 1) < tolerance
    }
}

enum MissedInk {
    static let color = UIColor(red: 23.0 / 255, green: 127.0 / 255, blue: 113.0 / 255, alpha: 1)

    static func matches(_ color: UIColor) -> Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        let tolerance: CGFloat = 0.5 / 255
        return abs(red - 23.0 / 255) < tolerance && abs(green - 127.0 / 255) < tolerance
            && abs(blue - 113.0 / 255) < tolerance && abs(alpha - 1) < tolerance
    }
}

struct PageImage: Codable {
    var head: UUID?
    var width: Int
    var height: Int
    var strokeCount: Int
    var inkTypes: [String]
    var tagStrokeCounts: [String: Int]? = nil
    var png: Data
}

// Generated PNGs live below native ink and have no editing or hit-test surface.
final class AIObjectsView: UIView {
    private var images: [(AIObject, UIImage)] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityIdentifier = "aiObjectsLayer"
        isAccessibilityElement = true
        accessibilityLabel = "Generated content"
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(_ objects: [AIObject], store: Store) throws {
        let prepared = try objects.map { object -> (AIObject, UIImage) in
            guard let image = UIImage(data: try store.assetData(object.asset), scale: 2) else { throw AIError.invalidAsset }
            return (object, image)
        }
        images = prepared
        accessibilityValue = String(objects.count)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        for (object, image) in images {
            image.draw(in: CGRect(x: object.frame.x, y: object.frame.y,
                                 width: object.frame.width, height: object.frame.height))
        }
    }
}

enum PageComposite {
    static func image(drawing: PKDrawing, objects: [AIObject], store: Store,
                      background: Int, size: CGSize, scale: CGFloat) throws -> UIImage {
        let images = try objects.map { object -> (AIObject, UIImage) in
            guard let image = UIImage(data: try store.assetData(object.asset), scale: 2) else { throw AIError.invalidAsset }
            return (object, image)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            PaperDrawing.draw(context: context.cgContext, size: size, pattern: background)
            for (object, image) in images {
                image.draw(in: CGRect(x: object.frame.x, y: object.frame.y,
                                     width: object.frame.width, height: object.frame.height))
            }
            let rect = CGRect(origin: .zero, size: size)
            drawing.image(from: rect, scale: scale).draw(in: rect)
        }
    }
}

extension Store {
    // A derived agent image, never an editable source or part of the sync digest.
    // Called on Home during explicit Sync, not by handwriting callbacks.
    func exportPageImages(pageSize: CGSize) throws -> [String: PageImage] {
        var images: [String: PageImage] = [:]
        for book in notebooks {
            for page in book.pages + book.deleted {
                let drawing = try self.drawing(book: book.id, page: page)
                let objects = self.objects(book: book.id, page: page)
                let ink = drawing.bounds
                let base = book.orientation == "landscape" ? CGSize(width: pageSize.height, height: pageSize.width) : pageSize
                let width = max(base.width, max(ink.isNull ? 0 : ink.maxX, CGFloat(objects.map { $0.frame.x + $0.frame.width }.max() ?? 0)))
                let height = max(base.height, max(ink.isNull ? 0 : ink.maxY, CGFloat(objects.map { $0.frame.y + $0.frame.height }.max() ?? 0)))
                guard width > 0, height > 0, width <= 4096, height <= 4096 else { throw SyncError.tooLarge }
                let rect = CGRect(x: 0, y: 0, width: width, height: height).integral
                let image = try PageComposite.image(drawing: drawing, objects: objects, store: self,
                    background: objects.isEmpty ? 2 : page.background, size: rect.size, scale: 2)
                guard let png = image.pngData() else { throw SyncError.invalidPackage }
                // Legacy teal archives remain readable, with the same unified
                // meaning as purple. Classification never rewrites source ink.
                let questionCount = drawing.strokes.filter {
                    QuestionInk.matches($0.ink.color) || MissedInk.matches($0.ink.color)
                }.count
                var tags: [String: Int] = [:]
                if questionCount > 0 { tags["question"] = questionCount }
                images["\(book.id.uuidString)/\(page.id.uuidString)"] = PageImage(
                    head: page.head, width: Int(rect.width * 2), height: Int(rect.height * 2),
                    strokeCount: drawing.strokes.count,
                    inkTypes: Array(Set(drawing.strokes.map { $0.ink.inkType.rawValue })).sorted(),
                    tagStrokeCounts: tags, png: png)
            }
        }
        return images
    }
}
