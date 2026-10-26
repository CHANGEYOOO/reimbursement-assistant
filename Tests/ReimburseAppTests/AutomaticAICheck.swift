#if DIRECT_TEST_RUNNER
import Foundation

@main struct AutomaticAICheck {
    @MainActor static func main() throws {
        let store = ExpenseStore()
        let row = Expense(number: 1, sourceURL: URL(fileURLWithPath: "/tmp/automatic-ai-sample.png"))
        store.expenses = [row]
        store.applySuggestion(Suggestion(amount: nil, category: .uncategorized, purpose: "",
            warning: "未能确定实付金额，请人工填写；用途分类待确认", recognizedText: "支付金额39元\n支付时间09-24"), to: row.id)
        let initial = store.automaticAIPlan(for: row.id)!
        precondition(initial.category && initial.amount && initial.date)
        store.selectCategory(.transport, for: row.id)
        let partial = store.automaticAIPlan(for: row.id)!
        precondition(!partial.category && partial.amount && partial.date,
                     "Manual category confirmation must not suppress missing money/date assistance")
        store.markEdited(row.id, field: .amount)
        let edited = store.automaticAIPlan(for: row.id)!
        precondition(!edited.category && !edited.amount && edited.date)
        store.markEdited(row.id, field: .date)
        precondition(store.automaticAIPlan(for: row.id) == nil, "Manual fields are not automatically replaced")
        store.reset()
        var complete = row
        complete.amount = 39
        complete.date = "2026-09-24"
        complete.category = .meals
        complete.purpose = "餐食费用"
        store.expenses = [complete]
        store.applySuggestion(Suggestion(amount: 39, category: .meals, purpose: "餐食费用",
            warning: nil, recognizedText: "餐饮\n实付39元", date: "2026-09-24"), to: row.id)
        precondition(store.automaticAIPlan(for: row.id) == nil)
        store.expenses[0].amount = 0
        precondition(store.automaticAIPlan(for: row.id)?.amount == true, "Nonpositive local amounts need assistance")
        store.expenses[0].isDuplicate = true
        store.expenses[0].amount = nil
        precondition(store.automaticAIPlan(for: row.id) == nil)
        store.reset()
        store.expenses = [row]
        precondition(store.automaticAIPlan(for: row.id) == nil, "No OCR text means no AI request")
        let pending = store.queue(URL(fileURLWithPath: "/tmp/pending-ai.png"))
        store.applySuggestion(Suggestion(amount: nil, category: .uncategorized, purpose: "",
            warning: nil, recognizedText: "支付金额39元"), to: pending)
        precondition(store.automaticAIPlan(for: pending) == nil, "Wait for local OCR before AI")
        store.reset()
        store.expenses = [row]
        store.applySuggestion(Suggestion(amount: nil, category: .uncategorized, purpose: "",
            warning: "未能确定实付金额，请人工填写；用途分类待确认", recognizedText: "实付39元\n支付日期09-24"), to: row.id)
        store.applySemanticClassification(SemanticClassification(category: .meals, isCertain: true, reason: "餐食"), to: row.id)
        precondition(store.exportBlocker != nil, "Other unresolved fields continue to block export")
        store.applySemanticPayment(SemanticPayment(amount: 39, isCertain: true, reason: "明确实付", candidates: []), to: row.id)
        store.applySemanticDate(SemanticDate(date: "2026-09-24", isCertain: true, reason: "支付日期", candidates: []), to: row.id)
        precondition(store.exportBlocker == nil && store.reviewCount == 0 && store.total == 39)
        precondition(!store.confirmedWarnings.contains(row.id), "AI must not claim a person checked the record")
        precondition(store.status(for: store.expenses[0]) == .aiRecognized)
        let encoded = try JSONEncoder().encode(store.expenses[0])
        let decoded = try JSONDecoder().decode(Expense.self, from: encoded)
        precondition(decoded.aiRecognized == true)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "aiRecognized")
        let legacyExpense = try JSONDecoder().decode(Expense.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(legacyExpense.aiRecognized == nil, "Existing drafts without the optional marker remain readable")
        print("Automatic AI eligibility checks passed (no network or credentials)")
    }
}
#endif
