import Foundation
import UIKit
import PencilKit
import CryptoKit

enum PortablePageError: Error {
    case invalidData
    case unsupportedInk(String)
    case unsupportedRenderingVersion
    case unresolvedColor
}

// The wire value is exactly the twelve fields in portable-sync.md, never a JSON object.
struct PortablePoint: Codable, Equatable {
    private(set) var values: [Double]

    init(_ point: PKStrokePoint) {
        var secondaryScale: CGFloat = 1, threshold: CGFloat = 0, lateralJitter: CGFloat = 0
        if #available(iOS 17.0, *) { secondaryScale = point.secondaryScale }
        if #available(iOS 26.0, *) { threshold = point.threshold }
        if #available(iOS 27.0, *) { lateralJitter = point.lateralJitter }
        values = [Double(point.location.x), Double(point.location.y), point.timeOffset,
                  Double(point.size.width), Double(point.size.height), Double(point.opacity),
                  Double(point.force), Double(point.azimuth), Double(point.altitude),
                  Double(secondaryScale), Double(threshold), Double(lateralJitter)]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        values = try container.decode([Double].self)
        guard values.count == 12, values.allSatisfy({ $0.isFinite }) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected twelve finite point fields")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    func validate() throws {
        // Field 5 is a 0...2 ink-opacity multiplier, not compositing alpha.
        // Field 10 is the independent 0...1 rendering threshold.
        guard values.count == 12, values.allSatisfy({ $0.isFinite }),
              values[2] >= 0, values[3] >= 0, values[4] >= 0,
              (0...2).contains(values[5]), values[6] >= 0, values[9] >= 0,
              (0...1).contains(values[10]) else { throw PortablePageError.invalidData }
    }

    func point() throws -> PKStrokePoint {
        try validate()
        let v = values
        if #available(iOS 27.0, *) {
            return PKStrokePoint(location: CGPoint(x: v[0], y: v[1]), timeOffset: v[2],
                size: CGSize(width: v[3], height: v[4]), opacity: v[5], force: v[6],
                azimuth: v[7], altitude: v[8], secondaryScale: v[9], threshold: v[10], lateralJitter: v[11])
        }
        guard v[11] == 0 else { throw PortablePageError.unsupportedRenderingVersion }
        return PKStrokePoint(location: CGPoint(x: v[0], y: v[1]), timeOffset: v[2],
            size: CGSize(width: v[3], height: v[4]), opacity: v[5], force: v[6],
            azimuth: v[7], altitude: v[8], secondaryScale: v[9], threshold: v[10])
    }
}

struct PortableMask: Codable, Equatable {
    var commands: [[Double]]
    var evenOdd: Bool

    init(_ mask: UIBezierPath) throws {
        var commands: [[Double]] = []
        var unknownCommand = false
        evenOdd = mask.usesEvenOddFillRule
        mask.cgPath.applyWithBlock { pointer in
            let element = pointer.pointee
            func xy(_ i: Int) -> [Double] {
                [Double(element.points[i].x), Double(element.points[i].y)]
            }
            switch element.type {
            case .moveToPoint: commands.append([0] + xy(0))
            case .addLineToPoint: commands.append([1] + xy(0))
            case .addQuadCurveToPoint: commands.append([2] + xy(0) + xy(1))
            case .addCurveToPoint: commands.append([3] + xy(0) + xy(1) + xy(2))
            case .closeSubpath: commands.append([4])
            @unknown default: unknownCommand = true
            }
        }
        guard !unknownCommand else { throw PortablePageError.invalidData }
        self.commands = commands
    }

    func validate() throws {
        let lengths: [Double: Int] = [0: 3, 1: 3, 2: 5, 3: 7, 4: 1]
        for command in commands {
            guard let opcode = command.first, command.allSatisfy({ $0.isFinite }),
                  lengths[opcode] == command.count else { throw PortablePageError.invalidData }
        }
    }

    func path() throws -> UIBezierPath {
        try validate()
        let path = CGMutablePath()
        for command in commands {
            guard let opcode = command.first, command.allSatisfy({ $0.isFinite }) else {
                throw PortablePageError.invalidData
            }
            func xy(_ i: Int) -> CGPoint { CGPoint(x: command[i], y: command[i + 1]) }
            switch (opcode, command.count) {
            case (0, 3): path.move(to: xy(1))
            case (1, 3): path.addLine(to: xy(1))
            case (2, 5): path.addQuadCurve(to: xy(3), control: xy(1))
            case (3, 7): path.addCurve(to: xy(5), control1: xy(1), control2: xy(3))
            case (4, 1): path.closeSubpath()
            default: throw PortablePageError.invalidData
            }
        }
        let result = UIBezierPath(cgPath: path)
        result.usesEvenOddFillRule = evenOdd
        return result
    }
}

struct PortableStroke: Codable {
    var id: UUID?
    var pathID: UUID?
    var inkType: String
    var color: [Double]
    var transform: [Double]
    var randomSeed: UInt32
    var renderGroupID: UUID?
    var grainOffset: [Double]?
    var creationDate: Double
    var points: [PortablePoint]
    var samples: [PortablePoint]
    var mask: PortableMask?

    init(_ stroke: PKStroke, geometryLimit: Int = PortablePage.maximumGeometryCount, includeSamples: Bool = true) throws {
        guard geometryLimit >= 0, geometryLimit <= PortablePage.maximumGeometryCount,
              stroke.path.count <= geometryLimit else { throw SyncError.tooLarge }
        inkType = stroke.ink.inkType.rawValue
        // Resolve dynamic/grayscale/P3 colors, then convert instead of treating P3 components as sRGB.
        let resolved = stroke.ink.color.resolvedColor(with: UITraitCollection.current)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = resolved.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let rgba = converted.components, rgba.count == 4 else { throw PortablePageError.unresolvedColor }
        color = rgba.map { Double(max(0, min(1, $0))) }
        let t = stroke.transform
        transform = [t.a, t.b, t.c, t.d, t.tx, t.ty].map { Double($0) }
        randomSeed = stroke.randomSeed
        creationDate = stroke.path.creationDate.timeIntervalSince1970
        points = stroke.path.map { PortablePoint($0) }
        mask = try stroke.mask.map { try PortableMask($0) }
        if #available(iOS 27.0, *) {
            id = stroke.id
            pathID = stroke.path.id
            renderGroupID = stroke.renderGroupID
            grainOffset = stroke.renderState?.grainOffset.map { [Double($0.x), Double($0.y)] }
        }
        let remaining = geometryLimit - points.count - (mask?.commands.count ?? 0)
        guard remaining >= 0 else { throw SyncError.tooLarge }
        samples = includeSamples ? try Self.sample(stroke, limit: remaining) : []
        try validate()
    }

    // Native identities and interpolation samples are deliberately excluded.
    // Every rendering control, mask and public render-state value participates.
    // Capture/apply export the authoritative decoded Store archive, not unsaved
    // PKStroke constructor inputs: native archive quantization is part of the state.
    func fingerprint() throws -> String {
        struct Canonical: Encodable {
            var inkType: String
            var color: [Double]
            var transform: [Double]
            var randomSeed: UInt32
            var grainOffset: [Double]?
            var creationDate: Double
            var points: [PortablePoint]
            var mask: PortableMask?
        }
        var controls = self
        controls.samples = [] // Derived samples are outside the fingerprint domain.
        try controls.validate()
        return AIHash.digest(try AIHash.encoded(Canonical(inkType: inkType, color: color,
            transform: transform, randomSeed: randomSeed, grainOffset: grainOffset,
            creationDate: creationDate, points: points, mask: mask)))
    }

    var targetID: String { id?.uuidString ?? (try? fingerprint()) ?? "" }

    var geometryCount: Int { points.count + samples.count + (mask?.commands.count ?? 0) }

    private static func sample(_ stroke: PKStroke, limit: Int) throws -> [PortablePoint] {
        let path = stroke.path
        guard !path.isEmpty else { return [] }
        guard limit > 0 else { throw SyncError.tooLarge }
        if path.count == 1 { return [PortablePoint(path[0])] }
        // The largest singular value bounds stretching under rotation, scale and shear.
        let t = stroke.transform
        let sum = t.a * t.a + t.b * t.b + t.c * t.c + t.d * t.d
        let determinant = t.a * t.d - t.b * t.c
        let scale = sqrt((sum + sqrt(max(0, sum * sum - 4 * determinant * determinant))) / 2)
        let minimumWidth = path.map { min($0.size.width, $0.size.height) }.min() ?? 0.5
        let distance = min(0.5, max(0.0625, minimumWidth / 4)) / max(1, scale)
        guard distance.isFinite, distance > 0 else { throw PortablePageError.invalidData }
        var result: [PortablePoint] = []
        for point in path.interpolatedPoints(by: .distance(distance)) {
            // Bound payload/memory without silently losing any part of a long curve.
            guard result.count < limit else { throw SyncError.tooLarge }
            result.append(PortablePoint(point))
        }
        let first = PortablePoint(path.interpolatedPoint(at: 0))
        let last = PortablePoint(path.interpolatedPoint(at: CGFloat(path.count - 1)))
        if result.first != first { result.insert(first, at: 0) }
        if result.last != last { result.append(last) }
        guard result.count <= limit else { throw SyncError.tooLarge }
        return result
    }

    func validate() throws {
        guard color.count == 4, color.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              transform.count == 6, transform.allSatisfy({ $0.isFinite }), creationDate.isFinite,
              grainOffset == nil || (grainOffset!.count == 2 && grainOffset!.allSatisfy({ $0.isFinite })) else {
            throw PortablePageError.invalidData
        }
        guard PKInk.InkType(rawValue: inkType) != nil else { throw PortablePageError.unsupportedInk(inkType) }
        for point in points { try point.validate() }
        for sample in samples { try sample.validate() }
        try mask?.validate()
    }

    func stroke() throws -> PKStroke {
        try validate()
        guard let type = PKInk.InkType(rawValue: inkType) else { throw PortablePageError.unsupportedInk(inkType) }
        let controls = try points.map { try $0.point() }
        let date = Date(timeIntervalSince1970: creationDate)
        let path: PKStrokePath
        if #available(iOS 27.0, *), let pathID {
            path = PKStrokePath(controlPoints: controls, creationDate: date, id: pathID)
        } else {
            path = PKStrokePath(controlPoints: controls, creationDate: date)
        }
        let ink = PKInk(type, color: UIColor(red: color[0], green: color[1], blue: color[2], alpha: color[3]))
        let t = CGAffineTransform(a: transform[0], b: transform[1], c: transform[2],
                                 d: transform[3], tx: transform[4], ty: transform[5])
        let clipping = try mask?.path()
        if #available(iOS 27.0, *) {
            let state = grainOffset.map { PKStroke.RenderState(grainOffset: CGPoint(x: $0[0], y: $0[1])) }
            return PKStroke(ink: ink, path: path, transform: t, mask: clipping, randomSeed: randomSeed,
                            id: id ?? UUID(), renderGroupID: renderGroupID, renderState: state)
        }
        guard renderGroupID == nil, grainOffset == nil else { throw PortablePageError.unsupportedRenderingVersion }
        return PKStroke(ink: ink, path: path, transform: t, mask: clipping, randomSeed: randomSeed)
    }
}

struct PortablePage: Codable {
    // One scene budget, including controls, samples and mask commands. Never truncate geometry.
    static let maximumGeometryCount = 262_144
    static let maximumStrokeCount = 10_000

    var format = 1
    var head: UUID?
    var width: Double
    var height: Double
    var strokes: [PortableStroke]
    var background: Int? = nil
    var objects: [AIObject]? = nil

    init(drawing: PKDrawing, pageSize: CGSize, head: UUID? = nil) throws {
        // Compare/export the actual archived representation, not uncompressed synthetic inputs.
        let canonical = try PKDrawing(data: drawing.dataRepresentation())
        let ink = canonical.bounds
        let width = max(pageSize.width, ink.isNull ? 0 : ink.maxX)
        let height = max(pageSize.height, ink.isNull ? 0 : ink.maxY)
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 4096, height <= 4096 else {
            throw SyncError.tooLarge
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height).integral
        self.head = head
        self.width = Double(rect.width)
        self.height = Double(rect.height)
        guard canonical.strokes.count <= Self.maximumStrokeCount else { throw SyncError.tooLarge }
        strokes = []
        var remaining = Self.maximumGeometryCount
        for stroke in canonical.strokes {
            let portable = try PortableStroke(stroke, geometryLimit: remaining)
            remaining -= portable.geometryCount
            strokes.append(portable)
        }
        try validate()
    }

    func validate() throws {
        guard format == 1, width.isFinite, height.isFinite,
              width > 0, height > 0, width <= 4096, height <= 4096 else { throw PortablePageError.invalidData }
        guard strokes.count <= Self.maximumStrokeCount else { throw SyncError.tooLarge }
        guard background == nil || (0...3).contains(background!) else { throw PortablePageError.invalidData }
        guard Set((objects ?? []).map(\.id)).count == (objects ?? []).count else { throw PortablePageError.invalidData }
        for object in objects ?? [] { try object.validate() }
        var remaining = Self.maximumGeometryCount
        for stroke in strokes {
            guard stroke.geometryCount <= remaining else { throw SyncError.tooLarge }
            remaining -= stroke.geometryCount
            try stroke.validate()
        }
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func digest() throws -> String {
        SHA256.hash(data: try encoded()).map { String(format: "%02x", $0) }.joined()
    }

    // Verification/import only. The original .pkdraw archive remains the recovery source.
    func drawing() throws -> PKDrawing {
        try validate()
        return PKDrawing(strokes: try strokes.map { try $0.stroke() })
    }
}

extension Store {
    func exportPortablePages(pageSize: CGSize, book documentID: UUID? = nil) throws -> [String: PortablePage] {
        if let loadError { throw loadError }
        var pages: [String: PortablePage] = [:]
        for book in notebooks where documentID == nil || book.id == documentID {
            let notebookSize = book.orientation == "landscape"
                ? CGSize(width: pageSize.height, height: pageSize.width) : pageSize
            for page in book.pages + book.deleted {
                let drawing = try self.drawing(book: book.id, page: page)
                var scene = try PortablePage(drawing: drawing, pageSize: notebookSize, head: page.head)
                let objects = self.objects(book: book.id, page: page)
                // Legacy scenes remain byte compatible unless they have generated content.
                // Captured AI contexts always set the actual background explicitly.
                if !objects.isEmpty {
                    scene.objects = objects; scene.background = page.background
                    for object in objects {
                        scene.width = max(scene.width, ceil(object.frame.x + object.frame.width))
                        scene.height = max(scene.height, ceil(object.frame.y + object.frame.height))
                    }
                    try scene.validate()
                }
                pages["\(book.id.uuidString)/\(page.id.uuidString)"] = scene
            }
        }
        return pages
    }
}
