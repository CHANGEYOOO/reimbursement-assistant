import Foundation

public struct DraftSummary: Identifiable, Hashable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let url: URL
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

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("报销单助手/Drafts", isDirectory: true)
    }

    public static func list() throws -> [DraftSummary] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .compactMap { url -> DraftSummary? in
                guard let id = UUID(uuidString: url.lastPathComponent),
                      FileManager.default.fileExists(atPath: url.appendingPathComponent(filename).path) else { return nil }
                let snapshot = try read(url)
                return DraftSummary(id: id, title: snapshot.title, updatedAt: snapshot.updatedAt, url: url)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func create(title: String = "未命名报销单") throws -> DraftSummary {
        let id = UUID()
        let url = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let snapshot = DraftSnapshot(title: cleanedTitle(title), updatedAt: Date(), expenses: [], pendingIDs: [], confirmedWarnings: [], recognizedTexts: [:], amountCandidates: [:])
        try write(snapshot, to: url)
        UserDefaults.standard.set(id.uuidString, forKey: lastOpenedKey)
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
        try write(snapshot, to: draft.url)
        UserDefaults.standard.set(draft.id.uuidString, forKey: lastOpenedKey)
        return DraftSummary(id: draft.id, title: snapshot.title, updatedAt: snapshot.updatedAt, url: draft.url)
    }

    @discardableResult public static func open(_ draft: DraftSummary, into store: ExpenseStore) throws -> DraftSummary {
        let snapshot = try read(draft.url)
        store.restore(snapshot)
        UserDefaults.standard.set(draft.id.uuidString, forKey: lastOpenedKey)
        return DraftSummary(id: draft.id, title: snapshot.title, updatedAt: snapshot.updatedAt, url: draft.url)
    }

    public static func lastOpened() -> UUID? {
        UserDefaults.standard.string(forKey: lastOpenedKey).flatMap(UUID.init(uuidString:))
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
