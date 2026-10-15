import Foundation
import UIKit
import PencilKit
import ImageIO

// ImageIO checks dimensions before UIKit allocates decoded pixels.
enum AIAssets {
    static func validate(data: Data, asset: AIAsset) throws {
        try asset.validate()
        guard data.count <= 128 * 1024 * 1024, AIHash.digest(data) == asset.sha256,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? Int) == asset.pixelWidth,
              (properties[kCGImagePropertyPixelHeight] as? Int) == asset.pixelHeight,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.colorSpace?.model == .rgb,
              image.alphaInfo == .premultipliedLast || image.alphaInfo == .premultipliedFirst ||
                image.alphaInfo == .last || image.alphaInfo == .first else { throw AIError.invalidAsset }
    }
}

enum AIInk {
    static func isLegacyTeal(_ color: UIColor) -> Bool {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.resolvedColor(with: UITraitCollection.current).cgColor
                .converted(to: space, intent: .defaultIntent, options: nil),
              let rgba = converted.components, rgba.count == 4 else { return false }
        let expected: [CGFloat] = [23.0 / 255, 127.0 / 255, 113.0 / 255, 1]
        return zip(rgba, expected).allSatisfy { abs($0 - $1) < 0.5 / 255 }
    }

    static func color(_ hex: String) throws -> UIColor {
        guard AIHash.validColor(hex), let rgb = UInt32(hex.dropFirst(), radix: 16) else { throw AIError.invalidResult }
        return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    static func moved(_ stroke: PKStroke, dx: Double, dy: Double) -> PKStroke {
        let moved = PKDrawing(strokes: [stroke]).transformed(using:
            CGAffineTransform(translationX: CGFloat(dx), y: CGFloat(dy))).strokes[0]
        if #available(iOS 27.0, *) {
            // A fresh identity invalidates PencilKit's live geometry cache.
            return PKStroke(ink: moved.ink, path: moved.path, transform: moved.transform, mask: moved.mask,
                randomSeed: moved.randomSeed, id: UUID(), renderGroupID: moved.renderGroupID,
                renderState: moved.renderState)
        }
        return moved
    }

    static func recolored(_ stroke: PKStroke, color: UIColor) -> PKStroke {
        let ink = PKInk(stroke.ink.inkType, color: color)
        if #available(iOS 27.0, *) {
            // Reusing a live stroke identity can retain PencilKit's old color cache.
            return PKStroke(ink: ink, path: stroke.path, transform: stroke.transform, mask: stroke.mask,
                randomSeed: stroke.randomSeed, id: UUID(), renderGroupID: stroke.renderGroupID,
                renderState: stroke.renderState)
        }
        return PKStroke(ink: ink, path: stroke.path, transform: stroke.transform, mask: stroke.mask,
            randomSeed: stroke.randomSeed)
    }
}

// Operates on public controls exported from the current native archive. Ambiguous
// identity is rejected before checking fingerprints, even if just one copy matches.
enum AIStrokeMatching {
    static func index(for edit: AIStrokeEdit, in strokes: [PortableStroke]) throws -> Int? {
        let matching = strokes.indices.filter { strokes[$0].targetID == edit.id }
        guard matching.count == 1, let index = matching.first,
              try strokes[index].fingerprint() == edit.fingerprint else { return nil }
        return index
    }

    // Native UUID lookup is cheap. Export/hash controls only for requested, unique
    // targets; object-only replies never enumerate canonical ink controls.
    static func matchingIndices(edits: [AIStrokeEdit], drawing: PKDrawing) throws -> [String: Int] {
        guard !edits.isEmpty else { return [:] }
        let strokes = drawing.strokes
        var result: [String: Int] = [:]
        if #available(iOS 27.0, *) {
            var identities: [String: [Int]] = [:]
            for (index, stroke) in strokes.enumerated() {
                identities[stroke.id.uuidString, default: []].append(index)
            }
            for edit in edits {
                guard let matching = identities[edit.id], matching.count == 1, let index = matching.first else { continue }
                let portable = try PortableStroke(strokes[index], includeSamples: false)
                if try portable.fingerprint() == edit.fingerprint { result[edit.id] = index }
            }
        } else {
            guard strokes.count <= PortablePage.maximumStrokeCount,
                  strokes.reduce(0, { $0 + $1.path.count }) <= PortablePage.maximumGeometryCount else { throw SyncError.tooLarge }
            let portable = try strokes.map { try PortableStroke($0, includeSamples: false) }
            for edit in edits {
                if let index = try index(for: edit, in: portable) { result[edit.id] = index }
            }
        }
        return result
    }
}

extension Store {
    func objects(book: UUID, page: Page) -> [AIObject] {
        page.nodes.first(where: { $0.id == page.head })?.objects ?? []
    }

    func appliedAIReceipt(requestID: UUID) -> AIApplyReceipt? {
        appliedAIRequests[requestID.uuidString]
    }

    func assetData(sha256: String) throws -> Data {
        guard let descriptor = notebooks.lazy.flatMap({ $0.pages + $0.deleted })
            .flatMap({ $0.nodes }).flatMap({ $0.objects ?? [] })
            .first(where: { $0.asset.sha256 == sha256 })?.asset else { throw AIError.invalidAsset }
        return try assetData(descriptor)
    }

    func assetData(_ asset: AIAsset) throws -> Data {
        try asset.validate()
        let data = try Data(contentsOf: fileRoot.appendingPathComponent("assets/" + asset.sha256 + ".png"))
        try AIAssets.validate(data: data, asset: asset)
        return data
    }

    func sceneAssets(_ books: [Notebook]) throws -> [String: Data] {
        var assets: [String: Data] = [:]
        for book in books {
            for page in book.pages + book.deleted {
                for node in page.nodes {
                    for object in node.objects ?? [] {
                        try object.validate()
                        // Check every descriptor, even when its bytes were already loaded.
                        let data = try assets[object.asset.sha256] ?? assetData(object.asset)
                        try AIAssets.validate(data: data, asset: object.asset)
                        assets[object.asset.sha256] = data
                    }
                }
            }
        }
        return assets
    }

    func stageAssets(_ assets: [String: Data], descriptors: [AIAsset]) throws {
        let expected = Set(descriptors.map(\.sha256))
        guard Set(assets.keys).isSubset(of: expected),
              assets.values.reduce(0, { $0 + $1.count }) <= 128 * 1024 * 1024 else { throw AIError.invalidAsset }
        var verified: [String: Data] = [:]
        for descriptor in descriptors {
            let data = try assets[descriptor.sha256] ?? assetData(descriptor)
            try AIAssets.validate(data: data, asset: descriptor)
            verified[descriptor.sha256] = data
        }
        let directory = fileRoot.appendingPathComponent("assets", isDirectory: true)
        if !verified.isEmpty { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for (hash, data) in verified {
            let file = directory.appendingPathComponent(hash + ".png")
            if FileManager.default.fileExists(atPath: file.path) {
                guard try Data(contentsOf: file) == data else { throw AIError.invalidAsset }
            } else { try data.write(to: file, options: .atomic) }
        }
    }

    func applyAI(_ result: AIResult, assets: [String: Data]) throws -> AIApplyReceipt {
        if let loadError { throw loadError }
        let hash = try result.digest()
        if let receipt = appliedAIRequests[result.requestID.uuidString] {
            guard receipt.resultSHA256 == hash else { throw AIError.duplicateRequest }
            return receipt // Independent of Undo, deleted pages, assets and relaunch.
        }
        guard result.format == 1, result.draftVersion >= 1,
              result.rendererSignature == "draw-ai-render-v1", AIHash.valid(result.contextSHA256),
              let b = notebooks.firstIndex(where: { $0.id == result.documentID }),
              !result.pageEdits.isEmpty, result.pageEdits.count <= 128,
              Set(result.pageEdits.map(\.pageID)).count == result.pageEdits.count,
              Set(result.insertPages.map(\.pageID)).count == result.insertPages.count,
              Set(result.previewSHA256s.keys) == Set(result.pageEdits.map { $0.pageID.uuidString }),
              result.previewSHA256s.values.allSatisfy(AIHash.valid) else { throw AIError.invalidResult }
        let edits = result.pageEdits.flatMap(\.objectEdits)
        guard edits.count <= 128,
              edits.contains(where: { ["add", "replace", "remove"].contains($0.op) }) ||
                result.pageEdits.flatMap(\.strokeEdits).contains(where: { ["remove", "recolor", "move"].contains($0.op) })
              else { throw AIError.invalidResult }
        var books = notebooks
        let existingPageIDs = Set(notebooks.flatMap { ($0.pages + $0.deleted).map(\.id) })
        let existingObjectIDs = Set(notebooks.flatMap { ($0.pages + $0.deleted).flatMap { $0.nodes.flatMap { ($0.objects ?? []).map(\.id) } } })
        var addedIDs = Set<UUID>()
        for insertion in result.insertPages {
            let landscape = books[b].orientation == "landscape"
            guard !existingPageIDs.contains(insertion.pageID), insertion.pageID != insertion.afterPageID,
                  result.pageEdits.contains(where: { $0.pageID == insertion.pageID }),
                  (0...3).contains(insertion.background), insertion.width.isFinite, insertion.height.isFinite,
                  insertion.width == (landscape ? 1361 : 1024), insertion.height == (landscape ? 1024 : 1361),
                  insertion.width <= 4096, insertion.height <= 4096,
                  let after = books[b].pages.firstIndex(where: { $0.id == insertion.afterPageID }) else { throw AIError.missingPage }
            books[b].pages.insert(Page(id: insertion.pageID, background: insertion.background), at: after + 1)
        }
        var receipt = AIApplyReceipt(requestID: result.requestID, resultSHA256: hash,
            appliedAt: AIHash.timestamp(), skippedStrokeTargets: [], skippedObjectTargets: [])
        var prepared: [(page: UUID, node: UUID, drawing: PKDrawing)] = []
        var descriptors: [AIAsset] = []
        for edit in result.pageEdits {
            guard let p = books[b].pages.firstIndex(where: { $0.id == edit.pageID }) else { throw AIError.missingPage }
            let page = books[b].pages[p]
            var scene = objects(book: result.documentID, page: page)
            var objectTargets = Set<UUID>()
            for operation in edit.objectEdits {
                switch operation.op {
                case "add":
                    guard operation.objectID == nil, operation.expectedRevision == nil, operation.expectedObject == nil,
                          let object = operation.object, object.revision == 1,
                          !existingObjectIDs.contains(object.id), addedIDs.insert(object.id).inserted,
                          objectTargets.insert(object.id).inserted else { throw AIError.invalidResult }
                    try validateObject(object, result: result)
                    scene.append(object); descriptors.append(object.asset)
                case "replace", "remove":
                    guard let id = operation.objectID, let revision = operation.expectedRevision, revision >= 1,
                          let expected = operation.expectedObject, expected.id == id, expected.revision == revision,
                          objectTargets.insert(id).inserted else { throw AIError.invalidResult }
                    // Validate captured metadata only. Its old PNG need not be downloaded
                    // or present locally when this target is no longer the latest scene.
                    try expected.validate()
                    if operation.op == "replace" {
                        guard let object = operation.object, object.id == id,
                              revision < Int.max, object.revision == revision + 1 else { throw AIError.invalidResult }
                        try validateObject(object, result: result)
                        descriptors.append(object.asset)
                    } else { guard operation.object == nil else { throw AIError.invalidResult } }
                    guard let i = scene.firstIndex(where: { $0.id == id }), scene[i].revision == revision,
                          scene[i] == expected else {
                        receipt.skippedObjectTargets.append(id); continue
                    }
                    if operation.op == "remove" { scene.remove(at: i) }
                    else { scene[i] = operation.object! }
                default: throw AIError.invalidResult
                }
            }
            let native = try drawing(book: result.documentID, page: page)
            var changes: [Int: AIStrokeEdit] = [:]
            var strokeTargets = Set<String>()
            for operation in edit.strokeEdits {
                try operation.validate()
                guard strokeTargets.insert(operation.id).inserted else { throw AIError.invalidResult }
            }
            let matching = try AIStrokeMatching.matchingIndices(edits: edit.strokeEdits, drawing: native)
            for operation in edit.strokeEdits {
                guard let index = matching[operation.id] else {
                    receipt.skippedStrokeTargets.append(operation.id); continue
                }
                changes[index] = operation
            }
            var inkChanged = false
            var strokes: [PKStroke] = []
            for (index, stroke) in (edit.strokeEdits.isEmpty ? [] : native.strokes).enumerated() {
                guard let operation = changes[index], operation.op != "keep" else { strokes.append(stroke); continue }
                if operation.op == "recolor" {
                    strokes.append(AIInk.recolored(stroke, color: try AIInk.color(operation.color!)))
                } else if operation.op == "move" {
                    let dx = (operation.dx! * 2).rounded() / 2, dy = (operation.dy! * 2).rounded() / 2
                    if dx == 0 && dy == 0 { strokes.append(stroke); continue }
                    strokes.append(AIInk.moved(stroke, dx: dx, dy: dy))
                }
                inkChanged = true
            }
            guard inkChanged || scene != objects(book: result.documentID, page: page) else { continue }
            let drawing = inkChanged ? PKDrawing(strokes: strokes) : native
            let node = HistoryNode(id: UUID(), parent: page.head, objects: scene.isEmpty ? nil : scene)
            if let head = page.head, let i = books[b].pages[p].nodes.firstIndex(where: { $0.id == head }) {
                books[b].pages[p].nodes[i].children.append(node.id)
                books[b].pages[p].nodes[i].preferredChild = node.id
            } else { books[b].pages[p].preferredRoot = node.id }
            books[b].pages[p].nodes.append(node)
            books[b].pages[p].head = node.id
            prepared.append((page.id, node.id, drawing))
        }
        // All destinations/operations were checked before immutable staging begins.
        try stageAssets(assets, descriptors: descriptors)
        for state in prepared {
            try stageSnapshot(book: result.documentID, page: state.page, node: state.node, drawing: state.drawing)
        }
        books[b].modified = Date()
        try commitAIState(books, receipt: receipt)
        return receipt
    }

    private func validateObject(_ object: AIObject, result: AIResult) throws {
        try object.validate()
        guard object.provenance.requestID == result.requestID,
              object.provenance.contextSHA256 == result.contextSHA256,
              object.provenance.rendererSignature == result.rendererSignature else { throw AIError.invalidResult }
    }
}
