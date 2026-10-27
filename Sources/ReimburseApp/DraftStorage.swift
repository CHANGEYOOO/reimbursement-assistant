import Foundation

public struct DraftSummary: Identifiable, Hashable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let url: URL
    public var createdAt: Date = .distantPast
}

struct DraftSnapshot: Codable {
    var title: String
    var updatedAt: Date
    var expenses: [Expense]
    var pendingIDs: Set<UUID>
    var confirmedWarnings: Set<UUID>
    var recognizedTexts: [UUID: String]
    var amountCandidates: [UUID: [AmountCandidate]]
}

@MainActor public enum DraftStorage {
    private static let lastOpenedKey = "reimbursement.lastDraftID"
    private static let filename = "draft.json"

    static var directoryOverride: URL?
    static var defaults = UserDefaults.standard

    public static var directory: URL {
        if let directoryOverride { return directoryOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("报销单助手/Drafts", isDirectory: true)
    }

    public static func list() throws -> [DraftSummary] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .compactMap { url -> DraftSummary? in
                guard let id = UUID(uuidString: url.lastPathComponent),
                      FileManager.default.fileExists(atPath: url.appendingPathComponent(filename).path) else { return nil }
                let snapshot = try read(url)
                let createdAt = try url.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
                return DraftSummary(id: id, title: snapshot.title, updatedAt: snapshot.updatedAt, url: url, createdAt: createdAt)
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    public static func create(title: String = "未命名报销单") throws -> DraftSummary {
        let id = UUID()
        let url = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let snapshot = DraftSnapshot(title: cleanedTitle(title), updatedAt: Date(), expenses: [], pendingIDs: [], confirmedWarnings: [], recognizedTexts: [:], amountCandidates: [:])
        try write(snapshot, to: url)
        defaults.set(id.uuidString, forKey: lastOpenedKey)
        return DraftSummary(id: id, title: snapshot.title, updatedAt: snapshot.updatedAt, url: url)
    }

    @discardableResult public static func save(_ store: ExpenseStore, title: String, draft: DraftSummary) throws -> DraftSummary {
        let orders = draft.url.appendingPathComponent("orders", isDirectory: true)
        try FileManager.default.createDirectory(at: orders, withIntermediateDirectories: true)
        for index in store.expenses.indices {
            let expense = store.expenses[index]
            let itemDirectory = orders.appendingPathComponent(expense.id.uuidString, isDirectory: true)
            let destination = itemDirectory.appendingPathComponent(expense.sourceURL.lastPathComponent)
            if expense.sourceURL.standardizedFileURL != destination.standardizedFileURL {
                try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: expense.sourceURL, to: destination)
                }
                store.expenses[index].sourceURL = destination
            }
        }
        let snapshot = store.snapshot(title: cleanedTitle(title))
        let previous = try read(draft.url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if snapshot.title == previous.title,
           snapshot.pendingIDs == previous.pendingIDs,
           snapshot.confirmedWarnings == previous.confirmedWarnings,
           snapshot.recognizedTexts == previous.recognizedTexts,
           snapshot.amountCandidates == previous.amountCandidates,
           try encoder.encode(snapshot.expenses) == encoder.encode(previous.expenses) {
            return DraftSummary(id: draft.id, title: previous.title, updatedAt: previous.updatedAt, url: draft.url, createdAt: draft.createdAt)
        }
        try write(snapshot, to: draft.url)
        defaults.set(draft.id.uuidString, forKey: lastOpenedKey)
        return DraftSummary(id: draft.id, title: snapshot.title, updatedAt: snapshot.updatedAt, url: draft.url, createdAt: draft.createdAt)
    }

    @discardableResult public static func open(_ draft: DraftSummary, into store: ExpenseStore) throws -> DraftSummary {
        let snapshot = try read(draft.url)
        store.restore(snapshot)
        defaults.set(draft.id.uuidString, forKey: lastOpenedKey)
        return DraftSummary(id: draft.id, title: snapshot.title, updatedAt: snapshot.updatedAt, url: draft.url, createdAt: draft.createdAt)
    }

    public static func lastOpened() -> UUID? {
        defaults.string(forKey: lastOpenedKey).flatMap(UUID.init(uuidString:))
    }

    public static func rename(_ draft: DraftSummary, to title: String) throws -> DraftSummary {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw NSError(domain: "DraftStorage", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "报销单名称不能为空。"])
        }
        var snapshot = try read(draft.url)
        guard snapshot.title != title else { return draft }
        snapshot.title = title
        snapshot.updatedAt = Date()
        try write(snapshot, to: draft.url)
        return DraftSummary(id: draft.id, title: title, updatedAt: snapshot.updatedAt, url: draft.url, createdAt: draft.createdAt)
    }

    public static func moveToTrash(_ draft: DraftSummary) throws {
        let expected = directory.appendingPathComponent(draft.id.uuidString, isDirectory: true)
        guard draft.url.standardizedFileURL == expected.standardizedFileURL,
              try draft.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/trash")
        process.arguments = [draft.url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DraftStorage", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "移入废纸篓失败，报销单未删除。请检查权限后重试。"])
        }
        if lastOpened() == draft.id { defaults.removeObject(forKey: lastOpenedKey) }
    }

    private static func cleanedTitle(_ title: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "未命名报销单" : title
    }

    private static func read(_ url: URL) throws -> DraftSnapshot {
        try JSONDecoder().decode(DraftSnapshot.self, from: Data(contentsOf: url.appendingPathComponent(filename)))
    }

    private static func write(_ snapshot: DraftSnapshot, to url: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url.appendingPathComponent(filename), options: .atomic)
    }
}
