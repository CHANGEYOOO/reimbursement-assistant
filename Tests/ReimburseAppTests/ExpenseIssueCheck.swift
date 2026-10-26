#if DIRECT_TEST_RUNNER
import Foundation

@main struct ExpenseIssueCheck {
    @MainActor static func main() {
        let store = ExpenseStore()
        let image = URL(fileURLWithPath: "/private/tmp/order-status-sample.png")
        let complete = Expense(number: 1, sourceURL: image, amount: 39, purpose: "餐食费用", date: "2026-10-26")
        var incomplete = Expense(number: 3, sourceURL: image)
        incomplete.date = "2026-02-30"
        var uncertain = Expense(number: 4, sourceURL: image, amount: 139, purpose: "交通费用", date: "2026-10-26")
        uncertain.warning = "有多个可能金额"
        var repeated = Expense(number: 2, sourceURL: image)
        repeated.isDuplicate = true
        store.expenses = [complete, repeated, incomplete, uncertain]
        precondition(store.status(for: complete) == .ready && store.status(for: complete).title == "可导出")
        precondition(store.status(for: uncertain).title == "待处理")
        precondition(store.total == store.amountTotal && store.total == 178 && store.hasUnresolvedAmounts)
        precondition(store.status(for: repeated) == .duplicate && store.issues(for: repeated).isEmpty)
        precondition(store.status(for: incomplete) == .incomplete && store.issues(for: incomplete).count == 3)
        precondition(store.status(for: uncertain) == .needsReview)
        precondition(store.exportIssues.map(\.number) == [3, 4])
        precondition(store.exportIssues.map(\.id) == [incomplete.id, uncertain.id])
        precondition(store.reviewCount == store.exportIssues.count && store.exportBlocker?.hasPrefix("第3笔") == true)
        store.confirmedWarnings.insert(uncertain.id)
        precondition(store.status(for: uncertain) == .reviewed && store.issues(for: uncertain).isEmpty)
        store.confirmedWarnings.insert(incomplete.id)
        precondition(store.status(for: incomplete) == .incomplete, "Confirmation must not hide missing fields")
        store.expenses = [complete]
        precondition(store.exportBlocker == nil, "Complete records without warnings may still export without manual confirmation")
        let pending = store.queue(image)
        let pendingExpense = store.expenses.first { $0.id == pending }!
        precondition(store.status(for: pendingExpense) == .processing)
        precondition(store.issues(for: pendingExpense).contains("正在识别，请等待完成"))
        print("Expense status and export issue checks passed")
    }
}
#endif
