import Foundation
import PencilKit

struct HistoryNode: Codable {
    var id: UUID
    var parent: UUID?
    var children: [UUID] = []
    var preferredChild: UUID?
    var objects: [AIObject]? = nil
}

struct Page: Codable {
    var id = UUID()
    var background = 0
    var starred = false
    var nodes: [HistoryNode] = []
    var head: UUID?
    var preferredRoot: UUID?
}

struct Folder: Codable, Equatable {
    var id = UUID()
    var name: String
    var parentID: UUID? = nil

    static func validateGraph(_ folders: [Folder], notebooks: [Notebook]) throws {
        let ids = Set(folders.map(\.id))
        guard ids.count == folders.count,
              Set(notebooks.map(\.id)).count == notebooks.count,
              folders.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              notebooks.allSatisfy({ $0.folderID == nil || ids.contains($0.folderID!) }) else { throw SyncError.invalidPackage }
        let lookup = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var complete = Set<UUID>()
        for folder in folders {
            var seen = Set<UUID>(), next: UUID? = folder.id
            while let id = next, !complete.contains(id) {
                guard seen.insert(id).inserted, let current = lookup[id] else { throw SyncError.invalidPackage }
                next = current.parentID
            }
            complete.formUnion(seen)
        }
    }

    // Root first. Reject missing links/cycles before constructing a path or closure.
    static func ancestors(of id: UUID, in folders: [Folder]) throws -> [Folder] {
        guard Set(folders.map(\.id)).count == folders.count else { throw SyncError.invalidPackage }
        let lookup = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var path: [Folder] = [], seen = Set<UUID>(), next: UUID? = id
        while let current = next {
            guard seen.insert(current).inserted, let folder = lookup[current] else { throw SyncError.invalidPackage }
            path.append(folder)
            next = folder.parentID
        }
        return Array(path.reversed())
    }

    static func ancestorClosure(of id: UUID?, in folders: [Folder]) throws -> [Folder] {
        guard let id else { return [] }
        let ids = Set(try ancestors(of: id, in: folders).map(\.id))
        // Preserve legacy array ordering, hence flat package digests.
        return folders.filter { ids.contains($0.id) }
    }

    static func path(of id: UUID, in folders: [Folder]) -> String? {
        try? ancestors(of: id, in: folders).map(\.name).joined(separator: " / ")
    }
}

private struct Library: Codable {
    var notebooks: [Notebook]
    var folders: [Folder]
    var localHistory: LocalHistory?
    var historySchemaVersion: Int? = nil
    var appliedAIRequests: [String: AIApplyReceipt]? = nil
}

// Device-only metadata. Never encoded into a SyncPackage.
private struct LocalHistory: Codable {
    var pages: [String: PageRetention] = [:]
}

private struct HistoryCheckpoint: Codable {
    var nodes: Set<UUID>
    var head: UUID?
}

private struct PageRetention: Codable {
    var floors: Set<UUID> = []
    var allowsBlank = true
    var previousSync: HistoryCheckpoint?
}

struct Notebook: Codable {
    var id = UUID()
    var name: String
    var created = Date()
    var modified = Date()
    var pages: [Page] = [Page()]
    var deleted: [Page] = []
    var currentPage: UUID?
    var folderID: UUID?
    var orientation: String? = nil // Legacy nil means portrait; existing ink is never converted.
}

enum StoreError: LocalizedError {
    case missingSnapshot
    var errorDescription: String? { "A saved drawing could not be read. Its history was not changed." }
}

final class Store {
    private(set) var notebooks: [Notebook] = []
    private(set) var folders: [Folder] = []
    private(set) var loadError: Error?
    private let root: URL
    private let index: URL
    private var localHistory = LocalHistory()
    private var historySchemaVersion: Int? = 2
    private(set) var appliedAIRequests: [String: AIApplyReceipt] = [:]
    var fileRoot: URL { root }
    let aiCaptureCache = AICaptureCache()

    // Custom directories are test fixtures. Opt in explicitly to exercise the upgrade.
    init(directory: URL? = nil, migrateLegacyHistory: Bool? = nil) {
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Draw", isDirectory: true)
        index = root.appendingPathComponent("notebooks.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: index.path) {
                let data = try Data(contentsOf: index)
                var needsMigration = true
                historySchemaVersion = nil
                if let legacy = try? JSONDecoder().decode([Notebook].self, from: data) {
                    notebooks = legacy
                } else {
                    let library = try JSONDecoder().decode(Library.self, from: data)
                    notebooks = library.notebooks
                    folders = library.folders
                    historySchemaVersion = library.historySchemaVersion
                    appliedAIRequests = library.appliedAIRequests ?? [:]
                    if let history = library.localHistory {
                        localHistory = history
                        needsMigration = false
                    }
                }
                try Folder.validateGraph(folders, notebooks: notebooks)
                if (needsMigration || historySchemaVersion != 2) && (migrateLegacyHistory ?? (directory == nil)) {
                    try migrateHistory()
                } else if !needsMigration {
                    // A read/validation failure must never trigger destructive cleanup.
                    _ = try exportPackage()
                    cleanupSnapshots()
                }
            }
        } catch { loadError = error }
        aiCaptureCache.retainCurrent(notebooks)
    }

    func save() throws {
        if let loadError { throw loadError }
        try indexData(notebooks: notebooks, folders: folders).write(to: index, options: .atomic)
        aiCaptureCache.retainCurrent(notebooks)
    }

    private func indexData(notebooks: [Notebook], folders: [Folder]) throws -> Data {
        try Folder.validateGraph(folders, notebooks: notebooks)
        return try JSONEncoder().encode(Library(notebooks: notebooks, folders: folders, localHistory: localHistory,
            historySchemaVersion: historySchemaVersion, appliedAIRequests: appliedAIRequests.isEmpty ? nil : appliedAIRequests))
    }

    // Validate and durably write a candidate before publishing organization changes.
    private func commitOrganization(notebooks books: [Notebook], folders groups: [Folder]) throws {
        if let loadError { throw loadError }
        try indexData(notebooks: books, folders: groups).write(to: index, options: .atomic)
        notebooks = books
        folders = groups
        aiCaptureCache.retainCurrent(notebooks)
    }

    func addFolder(_ name: String, in parent: UUID? = nil) throws -> UUID {
        let folder = Folder(name: name, parentID: parent)
        try commitOrganization(notebooks: notebooks, folders: folders + [folder])
        return folder.id
    }

    func renameFolder(_ id: UUID, to name: String) throws {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        var candidate = folders
        candidate[i].name = name
        try commitOrganization(notebooks: notebooks, folders: candidate)
    }

    func moveFolder(_ id: UUID, into parent: UUID?) throws {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        var candidate = folders
        candidate[i].parentID = parent
        try commitOrganization(notebooks: notebooks, folders: candidate)
    }

    func folderDestinations(excluding id: UUID? = nil) -> [Folder] {
        folders.filter { folder in
            guard let id else { return true }
            return (try? Folder.ancestors(of: folder.id, in: folders).contains { $0.id == id }) == false
        }.sorted {
            (Folder.path(of: $0.id, in: folders) ?? $0.name).localizedStandardCompare(
                Folder.path(of: $1.id, in: folders) ?? $1.name) == .orderedAscending
        }
    }

    // Removing a folder promotes its direct contents; deeper trees/ink stay intact.
    func deleteFolder(_ id: UUID) throws {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        var groups = folders.filter { $0.id != id }, books = notebooks
        for i in groups.indices where groups[i].parentID == id { groups[i].parentID = folder.parentID }
        for i in books.indices where books[i].folderID == id { books[i].folderID = folder.parentID }
        try commitOrganization(notebooks: books, folders: groups)
    }

    func moveNotebook(_ id: UUID, into folder: UUID?) throws {
        guard folder == nil || folders.contains(where: { $0.id == folder }) else { throw SyncError.invalidPackage }
        guard let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        var books = notebooks
        books[i].folderID = folder
        try commitOrganization(notebooks: books, folders: folders)
    }

    func addNotebook(_ name: String, in folder: UUID? = nil, orientation: String? = nil) throws -> UUID {
        guard folder == nil || folders.contains(where: { $0.id == folder }),
              orientation == nil || orientation == "portrait" || orientation == "landscape" else { throw SyncError.invalidPackage }
        let book = Notebook(name: name, folderID: folder, orientation: orientation)
        notebooks.append(book)
        do { try save() } catch { notebooks.removeLast(); throw error }
        return book.id
    }

    func update(_ id: UUID, _ change: (inout Notebook) -> Void) throws {
        guard let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        let previous = notebooks[i]
        change(&notebooks[i])
        notebooks[i].modified = Date()
        do { try save() } catch { notebooks[i] = previous; throw error }
    }

    func notebook(_ id: UUID) -> Notebook? { notebooks.first { $0.id == id } }

    func drawing(book: UUID, page: Page) throws -> PKDrawing {
        guard let head = page.head else { return PKDrawing() }
        let file = snapshotURL(book: book, page: page.id, node: head)
        guard let data = try? Data(contentsOf: file), let drawing = try? PKDrawing(data: data) else {
            throw StoreError.missingSnapshot
        }
        return drawing
    }

    private func snapshotURL(book: UUID, page: UUID, node: UUID) -> URL {
        root.appendingPathComponent(book.uuidString, isDirectory: true)
            .appendingPathComponent(page.uuidString, isDirectory: true)
            .appendingPathComponent(node.uuidString + ".pkdraw")
    }

    // The snapshot is durable before the metadata points at it. Undo preserves old children.
    func commit(book: UUID, page: UUID, drawing: PKDrawing) throws {
        guard let b = notebooks.firstIndex(where: { $0.id == book }),
              let p = notebooks[b].pages.firstIndex(where: { $0.id == page }) else { return }
        let current = notebooks[b].pages[p]
        if drawing == (try self.drawing(book: book, page: current)) { return }
        let data = drawing.dataRepresentation()
        let node = HistoryNode(id: UUID(), parent: current.head, objects: current.nodes.first(where: { $0.id == current.head })?.objects)
        let file = snapshotURL(book: book, page: page, node: node.id)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        let previous = notebooks[b]
        if let head = current.head, let i = notebooks[b].pages[p].nodes.firstIndex(where: { $0.id == head }) {
            notebooks[b].pages[p].nodes[i].children.append(node.id)
            notebooks[b].pages[p].nodes[i].preferredChild = node.id
        }
        if current.head == nil { notebooks[b].pages[p].preferredRoot = node.id }
        notebooks[b].pages[p].nodes.append(node)
        notebooks[b].pages[p].head = node.id
        notebooks[b].modified = Date()
        do { try save() }
        catch {
            notebooks[b] = previous
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    func undo(book: UUID, page: UUID) throws -> PKDrawing? {
        try navigate(book: book, page: page) { target in
            guard let head = target.head, let node = target.nodes.first(where: { $0.id == head }),
                  !self.retention(book: book, page: page).floors.contains(head) else { return false }
            target.head = node.parent
            if let parent = node.parent, let i = target.nodes.firstIndex(where: { $0.id == parent }) {
                target.nodes[i].preferredChild = head
            } else { target.preferredRoot = head }
            return true
        }
    }

    func redo(book: UUID, page: UUID) throws -> PKDrawing? {
        try navigate(book: book, page: page) { target in
            let next: UUID?
            if let head = target.head {
                next = target.nodes.first(where: { $0.id == head })?.preferredChild
            } else {
                // Older files have no preferredRoot; retain their previous fallback.
                next = target.preferredRoot ?? target.nodes.last(where: { $0.parent == nil })?.id
            }
            guard let next else { return false }
            target.head = next
            return true
        }
    }

    // Like Vim g-/g+: visit changes by creation order, crossing branches.
    // The blank root precedes the first node. Reaching either end is a no-op.
    func stepHistory(book: UUID, page: UUID, forward: Bool) throws -> PKDrawing? {
        try navigate(book: book, page: page) { target in
            let position = target.nodes.firstIndex(where: { $0.id == target.head }) ?? -1
            let next = position + (forward ? 1 : -1)
            let minimum = self.retention(book: book, page: page).allowsBlank ? -1 : 0
            guard next >= minimum, next < target.nodes.count else { return false }
            target.head = next == -1 ? nil : target.nodes[next].id
            // Make ordinary undo/redo follow the branch just visited, including root.
            var child = next == -1 ? target.nodes.first?.id : target.head
            while let id = child, let node = target.nodes.first(where: { $0.id == id }) {
                if let parent = node.parent, let i = target.nodes.firstIndex(where: { $0.id == parent }) {
                    target.nodes[i].preferredChild = id
                } else { target.preferredRoot = id }
                child = node.parent
            }
            return true
        }
    }

    private func navigate(book: UUID, page: UUID, step: (inout Page) -> Bool) throws -> PKDrawing? {
        guard let b = notebooks.firstIndex(where: { $0.id == book }),
              let p = notebooks[b].pages.firstIndex(where: { $0.id == page }) else { return nil }
        let previous = notebooks[b].pages[p]
        var target = previous
        let original = try? drawing(book: book, page: previous)
        var restored: PKDrawing?
        // Skip duplicate states created by older versions without deleting history.
        // Validate every visited snapshot, and persist only the final move.
        while step(&target) {
            let candidate = try drawing(book: book, page: target)
            restored = candidate
            if candidate != original || objects(book: book, page: target) != objects(book: book, page: previous) { break }
        }
        guard let restored else { return nil }
        notebooks[b].pages[p] = target
        do { try save() }
        catch { notebooks[b].pages[p] = previous; throw error }
        return restored
    }

    // Caller flushes the canvas first. Copy the current combined state, never its history.
    func carryBelow(book: UUID, page: UUID, y: CGFloat) throws -> UUID {
        if let loadError { throw loadError }
        guard y.isFinite, y >= 0 else { throw SyncError.invalidPackage }
        guard let b = notebooks.firstIndex(where: { $0.id == book }),
              let p = notebooks[b].pages.firstIndex(where: { $0.id == page }) else { throw AIError.missingPage }
        let source = notebooks[b].pages[p]
        let selected = try drawing(book: book, page: source).strokes.filter { stroke in
            let bounds = stroke.renderBounds
            return !bounds.isNull && !bounds.isInfinite && !bounds.isEmpty &&
                [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy({ $0.isFinite }) && bounds.maxY >= y
        }
        // PencilKit applies the translation to native geometry/masks/rendering state.
        let shifted = PKDrawing(strokes: selected).transformed(using: CGAffineTransform(translationX: 0, y: -y))
        let copied = PKDrawing(strokes: shifted.strokes.map { stroke in
            if #available(iOS 27.0, *) {
                return PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform, mask: stroke.mask,
                    randomSeed: stroke.randomSeed, id: UUID(), renderGroupID: stroke.renderGroupID,
                    renderState: stroke.renderState)
            }
            return PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform, mask: stroke.mask,
                randomSeed: stroke.randomSeed)
        })
        let copiedObjects = try objects(book: book, page: source).filter { $0.frame.y + $0.frame.height >= Double(y) }.map { object in
            var copy = object
            copy.id = UUID()
            copy.revision = 1
            copy.frame.y -= Double(y)
            try copy.validate()
            _ = try assetData(copy.asset)
            return copy
        }
        var destination = Page(background: source.background)
        var books = notebooks
        var stagedFile: URL?
        do {
            if !copied.strokes.isEmpty || !copiedObjects.isEmpty {
                let node = HistoryNode(id: UUID(), parent: nil, objects: copiedObjects.isEmpty ? nil : copiedObjects)
                let file = snapshotURL(book: book, page: destination.id, node: node.id)
                // Only roll back a file owned by this operation, never an existing immutable snapshot.
                guard !FileManager.default.fileExists(atPath: file.path) else { throw SyncError.conflict }
                stagedFile = file
                try stageSnapshot(book: book, page: destination.id, node: node.id, drawing: copied)
                destination.nodes = [node]
                destination.head = node.id
                destination.preferredRoot = node.id
                _ = try drawing(book: book, page: destination) // Read the staged archive before publication, including AI-only blank ink.
            }
            books[b].pages.insert(destination, at: p + 1)
            books[b].currentPage = destination.id
            books[b].modified = Date()
            try commitOrganization(notebooks: books, folders: folders)
        } catch {
            if let stagedFile { try? FileManager.default.removeItem(at: stagedFile) }
            throw error
        }
        return destination.id
    }

    func duplicate(book: UUID, page: Page) throws {
        guard notebook(book)?.pages.contains(where: { $0.id == page.id }) == true else { return }
        var copy = Page(background: page.background, starred: page.starred)
        var file: URL?
        if !page.nodes.isEmpty {
            let data = try drawing(book: book, page: page).dataRepresentation()
            let copiedObjects = page.nodes.first(where: { $0.id == page.head })?.objects?.map { object in
                var copy = object
                copy.id = UUID()
                copy.revision = 1
                return copy
            }
            let node = HistoryNode(id: copy.id, parent: nil, objects: copiedObjects)
            copy.nodes = [node]
            copy.head = node.id
            let destination = snapshotURL(book: book, page: copy.id, node: node.id)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            file = destination
        }
        do {
            try update(book) { notebook in
                if let i = notebook.pages.firstIndex(where: { $0.id == page.id }) {
                    notebook.pages.insert(copy, at: i)
                }
            }
        } catch {
            if let file { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    // Shipping sync must use this API, not the full local-history fixture export.
    func exportCurrentPackage(book documentID: UUID? = nil) throws -> SyncPackage {
        if let loadError { throw loadError }
        guard documentID == nil || notebook(documentID!) != nil else { throw AIError.missingPage }
        var books = notebooks.filter { documentID == nil || $0.id == documentID }
        var blobs: [String: Data] = [:]
        for b in books.indices {
            for p in books[b].pages.indices {
                books[b].pages[p] = try currentPage(books[b].pages[p], book: books[b].id, blobs: &blobs)
            }
            for p in books[b].deleted.indices {
                books[b].deleted[p] = try currentPage(books[b].deleted[p], book: books[b].id, blobs: &blobs)
            }
        }
        let packageFolders = try (documentID == nil ? folders : Folder.ancestorClosure(of: books.first?.folderID, in: folders))
        let assets = try sceneAssets(books)
        let package = SyncPackage(format: SyncPackage.sourceFormat(folders: packageFolders, hasAssets: !assets.isEmpty), notebooks: books, blobs: blobs,
            folders: packageFolders.isEmpty ? nil : packageFolders, assets: assets.isEmpty ? nil : assets)
        try package.validate()
        return package
    }

    private func currentPage(_ page: Page, book: UUID, blobs: inout [String: Data]) throws -> Page {
        var current = page
        guard page.head == nil || page.nodes.contains(where: { $0.id == page.head }) else { throw SyncError.invalidPackage }
        current.nodes = page.head.map { [HistoryNode(id: $0, parent: nil, objects: page.nodes.first(where: { $0.id == page.head })?.objects)] } ?? []
        current.preferredRoot = page.head
        if let head = page.head {
            blobs[SyncPackage.key(book, page.id, head)] = try Data(contentsOf: snapshotURL(book: book, page: page.id, node: head))
        }
        return current
    }

    // Full local export retained for tests/recovery inspection only. Never upload it.
    func exportPackage() throws -> SyncPackage {
        if let loadError { throw loadError }
        var blobs: [String: Data] = [:]
        for book in notebooks {
            for page in book.pages + book.deleted {
                for node in page.nodes {
                    blobs[SyncPackage.key(book.id, page.id, node.id)] = try Data(contentsOf: snapshotURL(book: book.id, page: page.id, node: node.id))
                }
            }
        }
        let assets = try sceneAssets(notebooks)
        let package = SyncPackage(format: SyncPackage.sourceFormat(folders: folders, hasAssets: !assets.isEmpty), notebooks: notebooks, blobs: blobs,
            folders: folders.isEmpty ? nil : folders, assets: assets.isEmpty ? nil : assets)
        try package.validate()
        return package
    }

    // Only call after confirmed upload/download/unchanged success, never on failure.
    // A checkpoint describes the last success; it is not a network baseline digest.
    func completeSuccessfulSync(book documentID: UUID? = nil) throws {
        _ = try exportPackage() // Validate ALL retained snapshots before any prune.
        let oldBooks = notebooks, oldHistory = localHistory
        for b in notebooks.indices where documentID == nil || notebooks[b].id == documentID {
            let book = notebooks[b].id
            for p in notebooks[b].pages.indices {
                var page = notebooks[b].pages[p]
                rotate(&page, book: book)
                notebooks[b].pages[p] = page
            }
            for p in notebooks[b].deleted.indices {
                var page = notebooks[b].deleted[p]
                rotate(&page, book: book)
                notebooks[b].deleted[p] = page
            }
        }
        discardMissingPageRetention()
        do { try save() }
        catch { notebooks = oldBooks; localHistory = oldHistory; throw error }
        cleanupSnapshots() // The index is durable before a single snapshot is removed.
    }

    private func retentionKey(book: UUID, page: UUID) -> String {
        "\(book.uuidString)/\(page.uuidString)"
    }

    private func retention(book: UUID, page: UUID) -> PageRetention {
        localHistory.pages[retentionKey(book: book, page: page)] ?? PageRetention()
    }

    private func rotate(_ page: inout Page, book: UUID) {
        let key = retentionKey(book: book, page: page.id)
        var state = localHistory.pages[key] ?? PageRetention()
        if let checkpoint = state.previousSync {
            let recent = Set(page.nodes.map(\.id)).subtracting(checkpoint.nodes)
            var anchors = Set<UUID>()
            if let head = checkpoint.head { anchors.insert(head) }
            if let head = page.head { anchors.insert(head) }
            for node in page.nodes where recent.contains(node.id) {
                if let parent = node.parent, !recent.contains(parent) { anchors.insert(parent) }
            }
            let kept = recent.union(anchors)
            let blankBranch = page.nodes.contains { recent.contains($0.id) && $0.parent == nil }
            state.allowsBlank = checkpoint.head == nil || page.head == nil || blankBranch
            state.floors = anchors.subtracting(recent)
            page.nodes = page.nodes.filter { kept.contains($0.id) }.map { node in
                var node = node
                // Each old entry state is its own floor, even on an older branch.
                if state.floors.contains(node.id) { node.parent = nil }
                node.children = node.children.filter { recent.contains($0) }
                if let child = node.preferredChild, !node.children.contains(child) { node.preferredChild = nil }
                return node
            }
            if let preferred = page.preferredRoot,
               !page.nodes.contains(where: { $0.id == preferred && $0.parent == nil }) {
                page.preferredRoot = page.nodes.last(where: { $0.parent == nil })?.id
            }
        }
        state.previousSync = HistoryCheckpoint(nodes: Set(page.nodes.map(\.id)), head: page.head)
        localHistory.pages[key] = state
    }

    private func migrateHistory() throws {
        // Validate only current combined states. Incompatible old undo is expendable.
        let before = try exportCurrentPackage()
        let journalURL = root.appendingPathComponent("ai-migration-journal.json")
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            let bytes = try before.encoded()
            let journal = AIMigrationJournal(preMigrationDigest: AIHash.digest(bytes), preMigrationPackage: bytes,
                globalBaseline: UserDefaults.standard.data(forKey: "syncBaseline"))
            try AIHash.encoded(journal).write(to: journalURL, options: .atomic)
        } else {
            // Never silently replace evidence from an interrupted migration.
            let journal = try JSONDecoder().decode(AIMigrationJournal.self, from: Data(contentsOf: journalURL))
            guard AIHash.digest(journal.preMigrationPackage) == journal.preMigrationDigest,
                  try before.digest() == journal.preMigrationDigest else { throw SyncError.conflict }
        }
        let oldBooks = notebooks, oldHistory = localHistory, oldSchema = historySchemaVersion
        do {
            for b in notebooks.indices {
                let book = notebooks[b].id
                for p in notebooks[b].pages.indices {
                    notebooks[b].pages[p] = try migrateCurrentPage(notebooks[b].pages[p], book: book)
                }
                for p in notebooks[b].deleted.indices {
                    notebooks[b].deleted[p] = try migrateCurrentPage(notebooks[b].deleted[p], book: book)
                }
            }
            historySchemaVersion = 2
            try save()
        } catch {
            notebooks = oldBooks; localHistory = oldHistory; historySchemaVersion = oldSchema
            throw error
        }
        cleanupSnapshots()
    }

    private func migrateCurrentPage(_ original: Page, book: UUID) throws -> Page {
        var page = original
        let native = try drawing(book: book, page: original)
        var changed = false
        let strokes = native.strokes.map { stroke -> PKStroke in
            guard AIInk.isLegacyTeal(stroke.ink.color) else { return stroke }
            changed = true
            return AIInk.recolored(stroke, color: QuestionInk.color)
        }
        if changed {
            let node = HistoryNode(id: UUID(), parent: nil, objects: original.nodes.first(where: { $0.id == original.head })?.objects)
            try stageSnapshot(book: book, page: page.id, node: node.id, drawing: PKDrawing(strokes: strokes))
            page.nodes = [node]
            page.head = node.id
        }
        resetHistory(&page, book: book)
        return page
    }

    private func resetHistory(_ page: inout Page, book: UUID) {
        page.nodes = page.head.map { [HistoryNode(id: $0, parent: nil, objects: page.nodes.first(where: { $0.id == page.head })?.objects)] } ?? []
        page.preferredRoot = page.head
        localHistory.pages[retentionKey(book: book, page: page.id)] = PageRetention(
            floors: Set(page.nodes.map(\.id)), allowsBlank: page.head == nil)
    }

    private func discardMissingPageRetention() {
        let keys = Set(notebooks.flatMap { book in
            (book.pages + book.deleted).map { retentionKey(book: book.id, page: $0.id) }
        })
        localHistory.pages = localHistory.pages.filter { keys.contains($0.key) }
    }

    func importPackage(_ package: SyncPackage) throws {
        if let loadError { throw loadError }
        try package.validate()
        _ = try exportPackage() // Never prune unreadable local snapshots during a download.
        // Validate every collision before writing. Snapshot IDs are immutable.
        for (key, bytes) in package.blobs {
            let file = root.appendingPathComponent(key + ".pkdraw")
            if FileManager.default.fileExists(atPath: file.path), try Data(contentsOf: file) != bytes {
                throw SyncError.conflict
            }
        }
        for book in package.notebooks {
            if let local = notebook(book.id) {
                for page in book.pages + book.deleted {
                    if let retained = (local.pages + local.deleted).first(where: { $0.id == page.id }) {
                        for node in page.nodes {
                            if let same = retained.nodes.first(where: { $0.id == node.id }),
                               (same.objects ?? []) != (node.objects ?? []) { throw SyncError.conflict }
                        }
                    }
                }
            }
        }
        try stageAssets(package.assets ?? [:], descriptors: package.notebooks.flatMap { ($0.pages + $0.deleted).flatMap { $0.nodes.flatMap { ($0.objects ?? []).map(\.asset) } } })
        let oldBooks = notebooks, oldFolders = folders, oldHistory = localHistory
        var books = package.notebooks
        for b in books.indices {
            let book = books[b].id
            let local = notebooks.first { $0.id == book }
            for p in books[b].pages.indices {
                var page = books[b].pages[p]
                mergeDownloadedPage(&page, book: book, local: local)
                books[b].pages[p] = page
            }
            for p in books[b].deleted.indices {
                var page = books[b].deleted[p]
                mergeDownloadedPage(&page, book: book, local: local)
                books[b].deleted[p] = page
            }
        }
        var written: [URL] = []
        do {
            for (key, bytes) in package.blobs {
                let file = root.appendingPathComponent(key + ".pkdraw")
                if !FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: file, options: .atomic)
                    written.append(file)
                }
            }
            notebooks = books
            folders = package.folders ?? []
            discardMissingPageRetention()
            try save()
        } catch {
            notebooks = oldBooks; folders = oldFolders; localHistory = oldHistory
            for file in written { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        cleanupSnapshots()
    }

    private func mergeDownloadedPage(_ incoming: inout Page, book: UUID, local: Notebook?) {
        let key = retentionKey(book: book, page: incoming.id)
        // Full-history packages remain supported for local test/recovery fixtures.
        let currentOnly = incoming.nodes.isEmpty || (incoming.nodes.count == 1 &&
            incoming.nodes[0].id == incoming.head && incoming.nodes[0].parent == nil &&
            incoming.nodes[0].children.isEmpty)
        guard currentOnly else {
            localHistory.pages[key] = PageRetention()
            return
        }
        guard var retained = (local.map { $0.pages + $0.deleted })?.first(where: { $0.id == incoming.id }) else {
            resetHistory(&incoming, book: book)
            return
        }
        guard let head = incoming.head else {
            // A new nil head cannot encode an undo edge without inventing a wire ID.
            if retained.head == nil {
                incoming.nodes = retained.nodes
                incoming.preferredRoot = retained.preferredRoot
            } else { resetHistory(&incoming, book: book) }
            return
        }
        if !retained.nodes.contains(where: { $0.id == head }) {
            if let parent = retained.head, let i = retained.nodes.firstIndex(where: { $0.id == parent }) {
                retained.nodes[i].children.append(head)
                retained.nodes[i].preferredChild = head
            } else { retained.preferredRoot = head }
            retained.nodes.append(HistoryNode(id: head, parent: retained.head, objects: incoming.nodes.first?.objects))
        }
        incoming.nodes = retained.nodes
        incoming.preferredRoot = retained.preferredRoot
    }

    // Identity is relative to the library, never its absolute path spelling.
    // iOS may enumerate /var/mobile URLs as /private/var/mobile URLs.
    static func nativeSnapshotKey(_ file: URL) -> String? {
        let page = file.deletingLastPathComponent()
        let book = page.deletingLastPathComponent()
        guard file.pathExtension == "pkdraw",
              let bookID = UUID(uuidString: book.lastPathComponent),
              let pageID = UUID(uuidString: page.lastPathComponent),
              let nodeID = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return nil }
        return SyncPackage.key(bookID, pageID, nodeID)
    }

    // Restrict cleanup to native snapshot directories, not arbitrary fixture/subfolders.
    // Preflight the entire retained library/inventory before deleting anything.
    // Leftovers are harmless; incomplete reads/listings abort and retry next load/prune.
    private func cleanupSnapshots() {
        let manager = FileManager.default
        guard let package = try? exportPackage() else { return }
        let referenced = Set(package.blobs.keys)
        // Foundation directory enumeration need not traverse a symlink used as its root.
        // Resolve that root explicitly; snapshot identity still uses UUIDs, not paths.
        let directory = root.resolvingSymlinksInPath()
        guard let books = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        var inventory: [(file: URL, key: String)] = []
        for book in books where UUID(uuidString: book.lastPathComponent) != nil {
            guard let pages = try? manager.contentsOfDirectory(at: book, includingPropertiesForKeys: nil) else { return }
            for page in pages where UUID(uuidString: page.lastPathComponent) != nil {
                guard let files = try? manager.contentsOfDirectory(at: page, includingPropertiesForKeys: nil) else { return }
                for file in files {
                    if let key = Self.nativeSnapshotKey(file) { inventory.append((file, key)) }
                }
            }
        }
        guard referenced.isSubset(of: Set(inventory.map { $0.key })) else { return }
        let assetDirectory = directory.appendingPathComponent("assets", isDirectory: true)
        var assetInventory: [URL] = []
        if manager.fileExists(atPath: assetDirectory.path) {
            guard let files = try? manager.contentsOfDirectory(at: assetDirectory, includingPropertiesForKeys: nil) else { return }
            assetInventory = files.filter { $0.pathExtension == "png" && AIHash.valid($0.deletingPathExtension().lastPathComponent) }
        }
        let assetReferences = Set((package.assets ?? [:]).keys)
        guard assetReferences.isSubset(of: Set(assetInventory.map { $0.deletingPathExtension().lastPathComponent })) else { return }
        for entry in inventory where !referenced.contains(entry.key) {
            try? manager.removeItem(at: entry.file)
        }
        for file in assetInventory where !assetReferences.contains(file.deletingPathExtension().lastPathComponent) {
            try? manager.removeItem(at: file)
        }
        for file in books where file.lastPathComponent.hasPrefix("before-sync-") && file.pathExtension == "json" {
            try? manager.removeItem(at: file)
        }
    }
    // Assets and native snapshots are immutable; candidate index is the sole commit point.
    func stageSnapshot(book: UUID, page: UUID, node: UUID, drawing: PKDrawing) throws {
        let file = snapshotURL(book: book, page: page, node: node)
        let bytes = drawing.dataRepresentation()
        if FileManager.default.fileExists(atPath: file.path) {
            guard try Data(contentsOf: file) == bytes else { throw SyncError.conflict }
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
    }

    func commitAIState(_ books: [Notebook], receipt: AIApplyReceipt) throws {
        if let loadError { throw loadError }
        try Folder.validateGraph(folders, notebooks: books)
        var receipts = appliedAIRequests
        receipts[receipt.requestID.uuidString] = receipt
        let bytes = try JSONEncoder().encode(Library(notebooks: books, folders: folders, localHistory: localHistory,
            historySchemaVersion: historySchemaVersion, appliedAIRequests: receipts))
        try bytes.write(to: index, options: .atomic)
        notebooks = books
        appliedAIRequests = receipts
        aiCaptureCache.retainCurrent(notebooks)
    }

    func migrationJournal() throws -> AIMigrationJournal? {
        let file = root.appendingPathComponent("ai-migration-journal.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let journal = try JSONDecoder().decode(AIMigrationJournal.self, from: Data(contentsOf: file))
        guard AIHash.digest(journal.preMigrationPackage) == journal.preMigrationDigest else { throw SyncError.invalidPackage }
        return journal
    }

}
