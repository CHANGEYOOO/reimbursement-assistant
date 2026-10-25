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
        store.applySemanticPayment(SemanticPayment(amount: 99, isCertain: true, reason: "实付款", candidates: []), to: expense.id)
        store.applySemanticDate(SemanticDate(date: "2026-10-20", isCertain: true, reason: "交易日期", candidates: []), to: expense.id)
        precondition(store.expenses[0].amount == 39 && store.expenses[0].date == "2026-10-26", "Resolved local fields remain unchanged")
        store.expenses[0].amount = nil
        store.expenses[0].date = ""
        store.applySemanticPayment(SemanticPayment(amount: nil, isCertain: false, reason: "两笔金额", candidates: [39, 49, 39]), to: expense.id)
        precondition(store.expenses[0].amount == nil && store.amountCandidates[expense.id]?.map(\.amount) == [39, 49])
        store.applySemanticDate(SemanticDate(date: nil, isCertain: false, reason: "日期有歧义", candidates: ["2026-10-20", "2026-10-26"]), to: expense.id)
        precondition(store.expenses[0].date == "" && store.dateCandidates[expense.id]?.count == 2)
        store.selectDateCandidate("2026-10-20", for: expense.id)
        precondition(store.expenses[0].date == "2026-10-20")
        store.expenses[0].date = ""
        store.applySemanticPayment(SemanticPayment(amount: 49, isCertain: true, reason: "明确实付", candidates: [49]), to: expense.id)
        store.applySemanticDate(SemanticDate(date: "2026-10-26", isCertain: true, reason: "明确支付日期", candidates: []), to: expense.id)
        precondition(store.expenses[0].amount == 49 && store.expenses[0].date == "2026-10-26")
        precondition(store.amountCandidates[expense.id]?.isEmpty == true && store.dateCandidates[expense.id]?.isEmpty == true)
        precondition(!store.confirmedWarnings.contains(expense.id) && store.aiAmountUpdates[expense.id] == 1)
        store.expenses[0].warning = "仅识别到订单合计，未见实付标识，请人工核对"
        store.markEdited(expense.id, field: .amount)
        store.expenses[0].amount = 88
        store.applySemanticPayment(SemanticPayment(amount: 99, isCertain: true, reason: "实付款", candidates: []), to: expense.id)
        precondition(store.expenses[0].amount == 88, "Manual amount survives even when a local warning remains")
        store.delete(expense.id)
        store.undoLastAction()
        store.applySemanticPayment(SemanticPayment(amount: 99, isCertain: true, reason: "实付款", candidates: []), to: expense.id)
        precondition(store.expenses[0].amount == 88, "Undo deletion preserves manual amount provenance")
        let saved = store.snapshot(title: "保存记录")
        store.restore(saved)
        store.applySemanticPayment(SemanticPayment(amount: 99, isCertain: true, reason: "实付款", candidates: []), to: expense.id)
        precondition(store.expenses[0].amount == 88, "Reopening protects previously saved amounts")
        store.reset()
        precondition(store.aiNotes.isEmpty && store.aiPendingIDs.isEmpty)
        print("Semantic store checks passed")
    }
}
#endif
