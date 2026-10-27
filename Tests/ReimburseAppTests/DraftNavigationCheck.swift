#if DIRECT_TEST_RUNNER
import Foundation

@main struct DraftNavigationCheck {
    @MainActor static func main() throws {
        func check(_ condition: Bool) { precondition(condition) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-navigation-\(UUID().uuidString)", isDirectory: true)
        let suite = "draft-navigation-\(UUID().uuidString)"
        DraftStorage.directoryOverride = directory
        DraftStorage.defaults = UserDefaults(suiteName: suite)!
        defer {
            DraftStorage.directoryOverride = nil
            DraftStorage.defaults = .standard
        }
        let first = try DraftStorage.create(title: "甲")
        let second = try DraftStorage.create(title: "乙")
        let initial = try DraftStorage.list().map(\.id)
        let store = ExpenseStore()
        for draft in [first, second, first, second] {
            let metadata = draft.url.appendingPathComponent("draft.json")
            let before = try Data(contentsOf: metadata)
            let opened = try DraftStorage.open(draft, into: store)
            let saved = try DraftStorage.save(store, title: opened.title, draft: opened)
            check(saved.updatedAt == opened.updatedAt)
            check(try Data(contentsOf: metadata) == before)
            check(try DraftStorage.list().map(\.id) == initial)
        }
        let opened = try DraftStorage.open(first, into: store)
        let source = directory.appendingPathComponent("fixture.png")
        try Data("offline fixture".utf8).write(to: source)
        let expense = Expense(number: 1, sourceURL: source, amount: 39, purpose: "餐食费用", date: "2026-10-28")
        store.expenses = [expense]
        let modified = try DraftStorage.save(store, title: opened.title, draft: opened)
        check(modified.updatedAt > opened.updatedAt)
        check(try DraftStorage.list().map(\.id) == initial)
        let reopened = try DraftStorage.open(modified, into: store)
        check(store.expenses.first?.id == expense.id && store.expenses.first?.amount == 39)
        let unchangedSave = try DraftStorage.save(store, title: reopened.title, draft: reopened)
        check(unchangedSave.updatedAt == modified.updatedAt)
        _ = try DraftStorage.open(second, into: store)
        let changed = try DraftStorage.rename(first, to: "重命名甲")
        check(changed.id == first.id && changed.url == first.url)
        check(try DraftStorage.list().map(\.id) == initial)
        let before = try Data(contentsOf: changed.url.appendingPathComponent("draft.json"))
        let unchanged = try DraftStorage.rename(changed, to: "重命名甲")
        check(unchanged.updatedAt == changed.updatedAt)
        check(try Data(contentsOf: changed.url.appendingPathComponent("draft.json")) == before)
        check(DraftStorage.lastOpened() == second.id)
        print("Draft navigation checks passed; fixtures retained at \(directory.path)")
    }
}
#endif
