#if DIRECT_TEST_RUNNER
import Foundation

@main struct ExpenseUndoCheck {
    @MainActor static func main() async throws {
        let image = URL(fileURLWithPath: "/private/tmp/undo-test-absent-image.png")
        func row(_ number: Int, _ amount: Decimal) -> Expense {
            Expense(number: number, sourceURL: image, amount: amount, purpose: "餐食费用", date: "2026-10-26")
        }
        let store = ExpenseStore()
        let a = row(1, 10), b = row(2, 20), c = row(3, 30)
        store.insert(a, fingerprint: Data([1]))
        store.insert(b, fingerprint: Data([2]))
        store.move(b.id, by: -1)
        precondition(store.undoActionName == "调整顺序")
        store.expenses[0].amount = 99
        store.undoLastAction()
        precondition(store.expenses.map(\.id) == [a.id, b.id] && store.expenses[1].amount == 99)
        precondition(store.undoActionName == nil)
        store.move(a.id, to: b.id)
        store.undoLastAction()
        precondition(store.expenses.map(\.id) == [a.id, b.id])
        store.confirmedWarnings.insert(a.id)
        store.applySuggestion(Suggestion(amount: 10, category: .meals, purpose: "餐食费用", warning: nil,
            recognizedText: "实付10", date: "2026-10-26"), to: a.id)
        store.delete(a.id)
        precondition(store.undoActionName == "删除订单" && store.expenses.count == 1)
        store.expenses[0].purpose = "另行修改的用途"
        store.insert(c, fingerprint: Data([3]))
        store.undoLastAction()
        precondition(store.expenses.map(\.id) == [a.id, b.id, c.id])
        precondition(store.expenses[1].purpose == "另行修改的用途")
        precondition(store.confirmedWarnings.contains(a.id) && store.recognizedTexts[a.id] == "实付10")
        store.actionUndoManager.redo()
        precondition(store.expenses.map(\.id) == [b.id, c.id])
        store.undoLastAction()
        precondition(store.expenses.map(\.id) == [a.id, b.id, c.id])
        let duplicates = ExpenseStore()
        duplicates.insert(a, fingerprint: Data([4]))
        duplicates.insert(b, fingerprint: Data([4]))
        duplicates.delete(a.id)
        precondition(!duplicates.expenses[0].isDuplicate)
        duplicates.expenses[0].purpose = "保留提升后的手动修改"
        duplicates.undoLastAction()
        precondition(!duplicates.expenses[0].isDuplicate && duplicates.expenses[1].isDuplicate)
        precondition(duplicates.expenses[1].purpose == "保留提升后的手动修改")
        precondition(duplicates.exportExpenses.map(\.id) == [a.id])
        for _ in 0..<10 { await Task.yield() }
        precondition(duplicates.expenses[1].isDuplicate && !duplicates.pendingIDs.contains(b.id))
        let pending = ExpenseStore()
        let pendingID = pending.queue(image)
        pending.expenses[0].amount = 88
        pending.markEdited(pendingID, field: .amount)
        pending.delete(pendingID)
        pending.undoLastAction()
        precondition(pending.expenses[0].id == pendingID && pending.pendingIDs.contains(pendingID))
        for _ in 0..<100 where pending.pendingIDs.contains(pendingID) {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(!pending.pendingIDs.contains(pendingID) && pending.expenses[0].amount == 88)
        pending.delete(pendingID)
        pending.reset()
        pending.undoLastAction()
        precondition(pending.expenses.isEmpty && pending.undoActionName == nil && !pending.actionUndoManager.canUndo)
        store.delete(a.id)
        store.restore(DraftSnapshot(title: "另一个草稿", updatedAt: Date(), expenses: [c], pendingIDs: [],
            confirmedWarnings: [], recognizedTexts: [:], amountCandidates: [:]))
        store.undoLastAction()
        precondition(store.expenses.map(\.id) == [c.id] && !store.actionUndoManager.canUndo)
        print("Expense deletion and order undo checks passed")
    }
}
#endif
