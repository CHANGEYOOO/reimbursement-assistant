#if DIRECT_TEST_RUNNER
import Foundation

@main struct SemanticStoreCheck {
    @MainActor static func main() {
        let store = ExpenseStore()
        let expense = Expense(number: 1, sourceURL: URL(fileURLWithPath: "/tmp/sample.png"),
            amount: 39, date: "2026-10-26", warning: "金额待核对；用途分类待确认")
        store.expenses = [expense]
        store.confirmedWarnings.insert(expense.id)
        store.applySemanticClassification(SemanticClassification(category: .meals, isCertain: true, reason: "购买的是可食用商品"), to: expense.id)
        precondition(store.expenses[0].category == .meals && store.expenses[0].purpose == "餐食费用")
        precondition(store.expenses[0].amount == 39 && store.expenses[0].date == "2026-10-26")
        precondition(!store.confirmedWarnings.contains(expense.id))
        precondition(store.expenses[0].warning?.contains("金额待核对") == true)
        precondition(store.expenses[0].warning?.contains("用途分类待确认") == false)
        precondition(store.exportBlocker != nil)
        store.expenses[0].purpose = "剧组购买食品"
        store.applySemanticClassification(SemanticClassification(category: .other, isCertain: false, reason: "证据不足"), to: expense.id)
        precondition(store.expenses[0].category == .meals && store.expenses[0].purpose == "剧组购买食品")
        store.applySemanticClassification(SemanticClassification(category: .purchases, isCertain: true, reason: "不可食用实物"), to: expense.id)
        precondition(store.expenses[0].category == .purchases && store.expenses[0].purpose == "剧组购买食品")
        store.reset()
        precondition(store.aiNotes.isEmpty && store.aiPendingIDs.isEmpty)
        print("Semantic store checks passed")
    }
}
#endif
