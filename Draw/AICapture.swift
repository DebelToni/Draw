import Foundation
import UIKit
import PencilKit
import ImageIO
import UniformTypeIdentifiers

// Native layers and per-stroke assets all use the same 2 pixels/page-point scale.
// Individually compositing overlapping marker strokes is not pixel-equivalent to
// PencilKit's render-group shader. The full unedited ink layer is authoritative.
enum AICapture {
    static func rendererFormat(opaque: Bool = false) -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = opaque
        format.preferredRange = .standard
        return format
    }

    static func paper(background: Int, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size, format: rendererFormat(opaque: true)).image { context in
            PaperDrawing.draw(context: context.cgContext, size: size, pattern: background)
        }
    }

    static func png(_ image: UIImage) throws -> Data {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0,
              cg.width <= 8192, cg.height <= 8192, cg.width * cg.height <= 32_000_000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw AIError.invalidAsset }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let srgb = context.makeImage() else { throw AIError.invalidAsset }
        // UIImage.pngData may optimize blank/grayscale images to non-RGBA PNG.
        // Encode the explicit 8-bit sRGB RGBA bitmap, including its alpha channel.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { throw AIError.invalidAsset }
        CGImageDestinationAddImage(destination, srgb, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGsRGBIntent: 0]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AIError.invalidAsset }
        return data as Data
    }

    // Preflight full native geometry before PencilKit or bitmap allocation. Page
    // clipping here would lose hidden ink that a later translation reveals.
    static func strokeBounds(_ stroke: PKStroke) throws -> CGRect {
        let raw = PKDrawing(strokes: [stroke]).bounds
        if raw.isNull { return .null }
        guard [raw.minX, raw.minY, raw.width, raw.height].allSatisfy({ $0.isFinite }) else { throw SyncError.tooLarge }
        let bounds = raw.integral
        guard bounds.width * 2 <= 8192, bounds.height * 2 <= 8192,
              bounds.width * bounds.height * 4 <= 32_000_000 else { throw SyncError.tooLarge }
        return bounds
    }

    static func croppedStroke(_ stroke: PKStroke) throws -> (AIFrame, AIAsset, Data) {
        let bounds = try strokeBounds(stroke)
        if bounds.isNull || bounds.isEmpty { return try invisibleStroke() }
        let single = PKDrawing(strokes: [stroke])
        let image = single.image(from: bounds, scale: 2)
        guard let cg = image.cgImage else {
            throw AICaptureFailure(detail: "native stroke render has no CGImage; rect=\(bounds)")
        }
        guard cg.width > 0, cg.height > 0, cg.width <= 8192, cg.height <= 8192,
              cg.width * cg.height <= 32_000_000 else { throw SyncError.tooLarge }
        var rgba = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw AICaptureFailure(detail: "alpha bitmap allocation \(cg.width)x\(cg.height)")
            }
            // Match CGImage's top-left pixel coordinates when inspecting alpha.
            context.translateBy(x: 0, y: CGFloat(cg.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var minX = cg.width, minY = cg.height, maxX = -1, maxY = -1
        // Unsafe-buffer reads avoid per-pixel Swift Array access overhead in Debug
        // builds. Bounds above and this loop prove every accessed alpha offset.
        rgba.withUnsafeBufferPointer { pixels in
            guard let data = pixels.baseAddress else { return }
            for y in 0..<cg.height {
                var x = 0
                let row = data.advanced(by: y * cg.width * 4 + 3)
                while x < cg.width {
                    if row[x * 4] != 0 {
                        minX = min(minX, x); minY = min(minY, y)
                        maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                    x += 1
                }
            }
        }
        if maxX < minX || maxY < minY { return try invisibleStroke() }
        let crop = maxX >= minX && maxY >= minY
            ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            : CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let cropped = cg.cropping(to: crop) else { throw AIError.invalidAsset }
        let bytes = try png(UIImage(cgImage: cropped, scale: 2, orientation: .up))
        let frame = AIFrame(x: Double(bounds.minX + crop.minX / 2), y: Double(bounds.minY + crop.minY / 2),
            width: Double(crop.width / 2), height: Double(crop.height / 2))
        let asset = AIAsset(sha256: AIHash.digest(bytes), pixelWidth: cropped.width, pixelHeight: cropped.height)
        try frame.validate()
        do { try AIAssets.validate(data: bytes, asset: asset) }
        catch { throw AICaptureFailure(detail: "cropped PNG verification: " + pngDescription(bytes)) }
        return (frame, asset, bytes)
    }

    static func invisibleStroke() throws -> (AIFrame, AIAsset, Data) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let image = context.makeImage() else { throw AIError.invalidAsset }
        let bytes = try png(UIImage(cgImage: image, scale: 2, orientation: .up))
        let asset = AIAsset(sha256: AIHash.digest(bytes), pixelWidth: 1, pixelHeight: 1)
        do { try AIAssets.validate(data: bytes, asset: asset) }
        catch { throw AICaptureFailure(detail: "invisible PNG verification: " + pngDescription(bytes)) }
        return (AIFrame(x: 0, y: 0, width: 0.5, height: 0.5), asset, bytes)
    }

    static func pngDescription(_ bytes: Data) -> String {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "undecodable PNG (\(bytes.count) bytes)" }
        return "\(image.width)x\(image.height), bpc=\(image.bitsPerComponent), bpp=\(image.bitsPerPixel), alpha=\(image.alphaInfo.rawValue), model=\(image.colorSpace?.model.rawValue ?? -1)"
    }
}

struct AICaptureFailure: LocalizedError {
    var detail: String
    var errorDescription: String? { "AI capture could not be verified: " + detail }
}

// Only immutable Codable values and raw bytes cross into the worker. No Store,
// UIView or open file is passed to detached rendering.
struct AICaptureSnapshot: @unchecked Sendable {
    var notebook: Notebook
    var folders: [Folder]
    var archives: [UUID: Data]
    var assets: [String: Data]
}

struct AICaptureProfile {
    var pageID: UUID
    var strokeCount = 0
    var cacheHit = false
    var onMainThread = Thread.isMainThread
    var archiveSeconds: Double = 0
    var portableSeconds: Double = 0
    var strokeSeconds: Double = 0
    var layerSeconds: Double = 0
}

// Ask-only, in-memory, current-state cache. Save invalidation prevents retaining
// Undo states, including when an old pinned worker finishes after newer writing.
final class AICaptureCache: @unchecked Sendable {
    private struct Identity: Equatable {
        var head: UUID?
        var background: Int
        var objects: [AIObject]
        init(_ page: Page) {
            head = page.head; background = page.background
            objects = page.nodes.first(where: { $0.id == page.head })?.objects ?? []
        }
    }
    struct Entry {
        var key: String
        var page: AIContextPage
        var assets: [String: Data]
    }
    private let lock = NSLock()
    private var current: [String: Identity] = [:]
    private var entries: [String: Entry] = [:]
    private var profiles: [AICaptureProfile] = []

    func retainCurrent(_ books: [Notebook]) {
        var next: [String: Identity] = [:]
        for book in books {
            for page in book.pages { next["\(book.id)/\(page.id)"] = Identity(page) }
        }
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { current[$0.key] == next[$0.key] && next[$0.key] != nil }
        current = next
    }
    func entry(book: UUID, page: UUID, key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        let entry = entries["\(book)/\(page)"]
        return entry?.key == key ? entry : nil
    }
    func store(_ entry: Entry, book: UUID, page: Page) {
        lock.lock(); defer { lock.unlock() }
        let id = "\(book)/\(page.id)"
        guard current[id] == Identity(page) else { return }
        // Same 128 MiB bound as a captured transfer. Never accumulate a history.
        let bytes = entry.assets.values.reduce(0) { $0 + $1.count }
        let retainedBytes = entries.filter { $0.key != id }.values.reduce(0) { total, entry in
            total + entry.assets.values.reduce(0) { $0 + $1.count }
        }
        if retainedBytes + bytes > 128 * 1024 * 1024 { entries.removeAll() }
        if bytes <= 128 * 1024 * 1024 { entries[id] = entry }
    }
    func beginProfiles() { lock.lock(); profiles = []; lock.unlock() }
    func record(_ profile: AICaptureProfile) { lock.lock(); profiles.append(profile); lock.unlock() }
    var lastProfiles: [AICaptureProfile] {
        lock.lock(); defer { lock.unlock() }
        return profiles
    }
}

extension AICapture {
    static func render(snapshot: AICaptureSnapshot, focusPage: UUID, pageSize: CGSize,
                       cache: AICaptureCache) throws -> (context: AIContext, assets: [String: Data]) {
        let notebook = snapshot.notebook
        let base = notebook.orientation == "landscape"
            ? CGSize(width: pageSize.height, height: pageSize.width) : pageSize
        var pages: [UUID: AIContextPage] = [:]
        var assets: [String: Data] = [:]
        var remainingStrokePixels = 128 * 1024 * 1024 / 4
        cache.beginProfiles()
        // Focus first, without changing the manifest's pinned document order.
        let ordered = notebook.pages.sorted { ($0.id == focusPage ? 0 : 1) < ($1.id == focusPage ? 0 : 1) }
        for page in ordered {
            try autoreleasepool {
                let objects = page.nodes.first(where: { $0.id == page.head })?.objects ?? []
                for object in objects {
                    try object.validate()
                    guard let bytes = snapshot.assets[object.asset.sha256], AIHash.digest(bytes) == object.asset.sha256 else { throw AIError.invalidAsset }
                }
                struct Key: Encodable {
                    var page: UUID; var head: UUID?; var background: Int; var objects: [AIObject]
                    var width: Double; var height: Double; var archiveSHA256: String
                    var renderer = "native-capture-v2"
                }
                let archive = snapshot.archives[page.id]
                guard page.head == nil || archive != nil else { throw StoreError.missingSnapshot }
                let key = AIHash.digest(try AIHash.encoded(Key(page: page.id, head: page.head, background: page.background,
                    objects: objects, width: Double(base.width), height: Double(base.height), archiveSHA256: archive.map(AIHash.digest) ?? "blank")))
                if let cached = cache.entry(book: notebook.id, page: page.id, key: key) {
                    for target in cached.page.strokeTargets {
                        remainingStrokePixels -= target.asset.pixelWidth * target.asset.pixelHeight
                        guard remainingStrokePixels >= 0 else { throw SyncError.tooLarge }
                    }
                    pages[page.id] = cached.page
                    assets.merge(cached.assets) { first, _ in first }
                    cache.record(AICaptureProfile(pageID: page.id, strokeCount: cached.page.strokeTargets.count, cacheHit: true))
                } else {
                    do {
                        let (entry, profile) = try renderPage(page, book: notebook.id, archive: archive,
                            objectAssets: snapshot.assets, base: base, key: key, remainingStrokePixels: &remainingStrokePixels)
                        pages[page.id] = entry.page
                        assets.merge(entry.assets) { first, _ in first }
                        cache.store(entry, book: notebook.id, page: page)
                        cache.record(profile)
                    } catch {
                        throw AICaptureFailure(detail: "page \(page.id.uuidString): \(error.localizedDescription)")
                    }
                }
                guard assets.values.reduce(0, { $0 + $1.count }) <= 128 * 1024 * 1024 else { throw SyncError.tooLarge }
            }
        }
        return (AIContext(documentID: notebook.id, focusPageID: focusPage, capturedAt: AIHash.timestamp(),
            orientation: notebook.orientation ?? "portrait", pages: try notebook.pages.map {
                guard let page = pages[$0.id] else { throw AIError.missingPage }
                return page
            }, documentName: notebook.name,
            folderName: notebook.folderID.flatMap { id in Folder.path(of: id, in: snapshot.folders) } ?? "Home",
            folderID: notebook.folderID), assets)
    }

    private static func renderPage(_ page: Page, book: UUID, archive: Data?, objectAssets: [String: Data],
                                   base: CGSize, key: String, remainingStrokePixels: inout Int) throws -> (AICaptureCache.Entry, AICaptureProfile) {
        var profile = AICaptureProfile(pageID: page.id)
        var started = Date.timeIntervalSinceReferenceDate
        let drawing = try archive.map { try PKDrawing(data: $0) } ?? PKDrawing()
        profile.archiveSeconds = Date.timeIntervalSinceReferenceDate - started
        profile.strokeCount = drawing.strokes.count
        // Bound aggregate uncompressed full tiles before rendering any of them.
        for stroke in drawing.strokes {
            let bounds = try strokeBounds(stroke)
            remainingStrokePixels -= bounds.isNull || bounds.isEmpty ? 1 : Int(bounds.width * bounds.height * 4)
            guard remainingStrokePixels >= 0 else { throw SyncError.tooLarge }
        }
        let objects = page.nodes.first(where: { $0.id == page.head })?.objects ?? []
        started = Date.timeIntervalSinceReferenceDate
        var portable = try PortablePage(drawing: drawing, pageSize: base, head: page.head)
        portable.background = page.background
        portable.objects = objects.isEmpty ? nil : objects
        for object in objects {
            portable.width = max(portable.width, ceil(object.frame.x + object.frame.width))
            portable.height = max(portable.height, ceil(object.frame.y + object.frame.height))
        }
        let portableBytes = try portable.encoded()
        profile.portableSeconds = Date.timeIntervalSinceReferenceDate - started
        let rect = CGRect(x: 0, y: 0, width: portable.width, height: portable.height)
        guard rect.width * rect.height * 4 <= 32_000_000 else { throw SyncError.tooLarge }
        var assets: [String: Data] = [:]
        var assetBytes = 0
        func add(_ bytes: Data) throws -> String {
            let hash = AIHash.digest(bytes)
            if assets[hash] == nil {
                guard bytes.count <= 128 * 1024 * 1024 - assetBytes else { throw SyncError.tooLarge }
                assetBytes += bytes.count
                assets[hash] = bytes
            }
            return hash
        }
        started = Date.timeIntervalSinceReferenceDate
        let paper = paper(background: page.background, size: rect.size)
        let ink = drawing.image(from: rect, scale: 2)
        var objectImages: [(AIFrame, UIImage)] = []
        for object in objects {
            guard let bytes = objectAssets[object.asset.sha256] else { throw AIError.invalidAsset }
            try AIAssets.validate(data: bytes, asset: object.asset)
            _ = try add(bytes)
            guard let image = UIImage(data: bytes) else { throw AIError.invalidAsset }
            objectImages.append((object.frame, image))
        }
        let composite = UIGraphicsImageRenderer(size: rect.size, format: rendererFormat(opaque: true)).image { _ in
            paper.draw(in: rect)
            for (frame, image) in objectImages {
                image.draw(in: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
            }
            ink.draw(in: rect)
        }
        let paperHash = try add(png(paper)), inkHash = try add(png(ink)), compositeHash = try add(png(composite))
        profile.layerSeconds = Date.timeIntervalSinceReferenceDate - started
        started = Date.timeIntervalSinceReferenceDate
        var targets: [AIStrokeTarget] = []
        for (index, stroke) in drawing.strokes.enumerated() {
            do {
                // Reuse the canonical controls already exported for the scene;
                // fingerprints exclude interpolation samples, without rewalking PK.
                let (target, bytes) = try autoreleasepool { () throws -> (AIStrokeTarget, Data) in
                    let canonical = portable.strokes[index]
                    let (frame, asset, bytes) = try croppedStroke(stroke)
                    return (AIStrokeTarget(id: canonical.targetID, fingerprint: try canonical.fingerprint(),
                        index: index, frame: frame, asset: asset), bytes)
                }
                _ = try add(bytes)
                targets.append(target)
            } catch {
                throw AICaptureFailure(detail: "stroke \(index): \(error.localizedDescription)")
            }
        }
        profile.strokeSeconds = Date.timeIntervalSinceReferenceDate - started
        let context = AIContextPage(pageID: page.id, head: page.head, background: page.background,
            width: portable.width, height: portable.height, objects: objects, paperSHA256: paperHash,
            inkSHA256: inkHash, compositeSHA256: compositeHash, portableSHA256: try add(portableBytes), strokeTargets: targets)
        return (AICaptureCache.Entry(key: key, page: context, assets: assets), profile)
    }
}

extension Store {
    // Pin only current live heads and required object bytes on main actor. No PK
    // decoding, interpolation, image rendering or PNG verification occurs here.
    @MainActor
    private func captureSnapshot(book: UUID, focusPage: UUID, source: SyncPackage?) throws -> AICaptureSnapshot {
        if source == nil, let loadError { throw loadError }
        if let source, !(1...3).contains(source.format) { throw SyncError.invalidPackage }
        let candidate: Notebook?
        if let source { candidate = source.notebooks.first { $0.id == book } }
        else { candidate = notebook(book) }
        guard var selected = candidate, selected.pages.contains(where: { $0.id == focusPage }) else { throw AIError.missingPage }
        let captureFolders = source.map { $0.folders ?? [] } ?? folders
        try Folder.validateGraph(captureFolders, notebooks: [selected])
        if let source, captureFolders.contains(where: { $0.parentID != nil }), source.format != 3 { throw SyncError.invalidPackage }
        guard selected.orientation == nil || selected.orientation == "portrait" || selected.orientation == "landscape",
              Set(selected.pages.map(\.id)).count == selected.pages.count else { throw SyncError.invalidPackage }
        var archives: [UUID: Data] = [:]
        var assets: [String: Data] = [:]
        for i in selected.pages.indices {
            var page = selected.pages[i]
            guard (0...3).contains(page.background) else { throw SyncError.invalidPackage }
            if let head = page.head {
                guard let node = page.nodes.first(where: { $0.id == head }) else { throw SyncError.invalidPackage }
                if let source {
                    guard let data = source.blobs[SyncPackage.key(book, page.id, head)] else { throw StoreError.missingSnapshot }
                    archives[page.id] = data
                } else {
                    archives[page.id] = try Data(contentsOf: fileRoot.appendingPathComponent(SyncPackage.key(book, page.id, head) + ".pkdraw"))
                }
                page.nodes = [HistoryNode(id: head, parent: nil, objects: node.objects)]
            } else { page.nodes = [] }
            page.preferredRoot = page.head
            for object in page.nodes.first?.objects ?? [] {
                try object.validate()
                if assets[object.asset.sha256] == nil {
                    if let source {
                        guard let bytes = source.assets?[object.asset.sha256] else { throw AIError.invalidAsset }
                        assets[object.asset.sha256] = bytes
                    } else {
                        assets[object.asset.sha256] = try Data(contentsOf: fileRoot.appendingPathComponent("assets/" + object.asset.sha256 + ".png"))
                    }
                }
            }
            selected.pages[i] = page
        }
        selected.deleted = []
        return AICaptureSnapshot(notebook: selected, folders: captureFolders, archives: archives, assets: assets)
    }

    @MainActor
    func capturedAIContext(book: UUID, focusPage: UUID, pageSize: CGSize,
                           source: SyncPackage? = nil) throws -> (context: AIContext, assets: [String: Data]) {
        aiCaptureCache.retainCurrent(notebooks)
        return try AICapture.render(snapshot: captureSnapshot(book: book, focusPage: focusPage, source: source),
            focusPage: focusPage, pageSize: pageSize, cache: aiCaptureCache)
    }

    @MainActor
    func capturedAIContextAsync(book: UUID, focusPage: UUID, pageSize: CGSize,
                                source: SyncPackage? = nil) async throws -> (context: AIContext, assets: [String: Data]) {
        aiCaptureCache.retainCurrent(notebooks)
        let snapshot = try captureSnapshot(book: book, focusPage: focusPage, source: source)
        let cache = aiCaptureCache
        return try await Task.detached(priority: .userInitiated) {
            try AICapture.render(snapshot: snapshot, focusPage: focusPage, pageSize: pageSize, cache: cache)
        }.value
    }
}
