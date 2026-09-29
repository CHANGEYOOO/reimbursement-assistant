import Foundation
#if !DIRECT_TEST_RUNNER
@testable import ReimburseApp
#endif
#if canImport(XCTest) && !DIRECT_TEST_RUNNER
import XCTest
#endif

private enum StoreChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    @MainActor static func run() async throws {
        let store = ExpenseStore()
        let image = URL(fileURLWithPath: "/tmp/receipt.png")
        let first = Expense(number: 1, sourceURL: image, amount: 12, purpose: "交通费用", date: "2026-09-01")
        let repeated = Expense(number: 2, sourceURL: image, amount: 12, purpose: "交通费用", date: "2026-09-01")
        store.insert(first, fingerprint: Data([1, 2, 3]))
        store.insert(repeated, fingerprint: Data([1, 2, 3]))
        check(store.expenses.count == 2, "duplicate remains visible")
        check(store.expenses[1].isDuplicate, "same image is marked duplicate")
        check(store.total == 12, "duplicate is excluded from total")
        check(store.exportExpenses.count == 1, "duplicate is excluded from export")
        let later = Expense(number: 3, sourceURL: image, amount: 7, purpose: "餐食费用")
        store.insert(later, fingerprint: Data([9, 9, 9]))
        check(store.exportExpenses.map(\.number) == [1, 2], "export numbering skips duplicate row")
        store.expenses.removeLast()

        store.expenses[0].amount = nil
        check(store.exportBlocker != nil, "missing amount blocks export")
        store.expenses[0].amount = 12
        store.expenses[0].date = ""
        check(store.exportBlocker != nil, "missing date blocks export")
        store.expenses[0].date = "2026-09-01"
        store.expenses[0].purpose = ""
        check(store.exportBlocker != nil, "missing purpose blocks export")
        store.expenses[0].purpose = "交通费用"
        check(store.exportBlocker == nil, "completed expense can be exported")
        store.expenses[0].amount = 25.5
        check(store.total == Decimal(string: "25.5")!, "edited amount updates total")
        store.expenses[0].warning = "金额待核对"
        check(store.exportBlocker != nil && store.total == 0, "uncertain amount is excluded until review")
        store.confirmedWarnings.insert(store.expenses[0].id)
        check(store.exportBlocker == nil && store.total == Decimal(string: "25.5")!, "reviewed amount becomes exportable")

        let categoryReview = ExpenseStore()
        let categoryExpense = Expense(number: 1, sourceURL: image, amount: 12, purpose: "交通费用",
            date: "2026-09-01", warning: "用途分类待确认")
        categoryReview.insert(categoryExpense, fingerprint: Data([8]))
        check(categoryReview.exportBlocker != nil, "unconfirmed warning blocks export")
        categoryReview.selectCategory(.transport, for: categoryExpense.id)
        check(categoryReview.confirmedWarnings.contains(categoryExpense.id), "manual category selection confirms review")
        check(categoryReview.exportBlocker == nil, "selected category clears review blocker")
        let candidateReview = ExpenseStore()
        let candidateExpense = Expense(number: 1, sourceURL: image, purpose: "交通费用",
            date: "2026-09-01", warning: "多笔金额待选择")
        candidateReview.insert(candidateExpense, fingerprint: Data([7]))
        var ambiguous = Suggestion(amount: nil, category: .transport, purpose: "交通费用",
            warning: "多笔金额待选择", recognizedText: "实付款108\n实付款29.9")
        let chosen = AmountCandidate(amount: 108, source: "整单实付")
        ambiguous.date = "2026-09-01"
        ambiguous.amountCandidates = [chosen, AmountCandidate(amount: Decimal(string: "29.9")!, source: "整单实付")]
        candidateReview.applySuggestion(ambiguous, to: candidateExpense.id)
        check(candidateReview.exportBlocker != nil, "unselected candidates block export")
        candidateReview.selectAmountCandidate(chosen, for: candidateExpense.id)
        check(candidateReview.expenses[0].amount == 108 && candidateReview.confirmedWarnings.contains(candidateExpense.id),
            "clicking a candidate fills amount and confirms manual review")
        check(candidateReview.exportBlocker == nil, "selected candidate can be exported")
        candidateReview.delete(candidateExpense.id)
        check(candidateReview.amountCandidates[candidateExpense.id] == nil, "deletion clears candidates")
        let pendingCategory = ExpenseStore()
        let pendingID = pendingCategory.queue(image)
        pendingCategory.selectCategory(.meals, for: pendingID)
        pendingCategory.applySuggestion(Suggestion(amount: 12, category: .transport, purpose: "交通费用",
            warning: "负数支出金额，请人工核对", recognizedText: "-12.00"), to: pendingID)
        check(pendingCategory.confirmedWarnings.contains(pendingID), "manual selection during OCR stays confirmed")
        check(pendingCategory.expenses[0].category == .meals, "OCR preserves manually selected category")

        let invalid = URL(fileURLWithPath: "/private/tmp/reimbursement-sdd/invalid-image-\(UUID().uuidString).png")
        try Data([0, 1, 2, 3]).write(to: invalid)
        let failedStore = ExpenseStore()
        await failedStore.importFile(invalid)
        await failedStore.importFile(invalid)
        check(failedStore.expenses[1].isDuplicate, "failed OCR still detects duplicate bytes")

        let batch = ExpenseStore()
        batch.importFiles([invalid, invalid])
        check(batch.expenses.count == 2 && batch.pendingIDs.count == 2,
            "all selected screenshots appear in the list before OCR completes")

        let review = ExpenseStore()
        let id = review.queue(image)
        review.expenses[0].amount = 99
        review.markEdited(id, field: .amount)
        review.expenses[0].purpose = "项目交通"
        review.markEdited(id, field: .purpose)
        let suggestion = Suggestion(amount: 12, category: .transport, purpose: "交通费用",
            warning: nil, recognizedText: "已支付12元")
        review.applySuggestion(suggestion, to: id)
        check(review.expenses[0].amount == 99 && review.expenses[0].purpose == "项目交通",
            "OCR must preserve fields edited while pending")
        check(review.expenses[0].category == .transport, "OCR fills untouched category")
        check(review.recognizedTexts[id] == "已支付12元", "OCR clues remain visible")
        let secondID = review.queue(image)
        review.expenses[1].category = .lodging
        review.markEdited(secondID, field: .category)
        review.applySuggestion(suggestion, to: secondID)
        check(review.expenses[1].category == .lodging && review.expenses[1].amount == 12,
            "OCR preserves edited category and fills untouched amount")
        check(ExpenseDate.isValid("2026-09-01"), "valid transaction date")
        check(!ExpenseDate.isValid("2026-02-30"), "invalid calendar day is rejected")
        check(!ExpenseDate.isValid("2026/09/01"), "manual date uses ISO format")
        let dateID = review.queue(image)
        review.expenses[2].date = "2026-09-02"
        review.markEdited(dateID, field: .date)
        review.applySuggestion(Suggestion(amount: 12, category: .transport, purpose: "交通费用",
            warning: nil, recognizedText: "支付时间 2026-09-01", date: "2026-09-01"), to: dateID)
        check(review.expenses[2].date == "2026-09-02", "OCR preserves manually edited date")
        check(ExpenseStore.parseAmountInput("12abc") == nil, "malformed visible amount cannot export as 12")
        check(ExpenseStore.parseAmountInput("12.34") == Decimal(string: "12.34"), "valid amount parses fully")

        let changes = ExpenseStore()
        let a = Expense(number: 1, sourceURL: image, amount: 10, purpose: "交通费用")
        let b = Expense(number: 2, sourceURL: image, amount: 20, purpose: "餐食费用")
        changes.insert(a, fingerprint: Data([1]))
        changes.insert(b, fingerprint: Data([2]))
        changes.move(b.id, by: -1)
        check(changes.expenses.map(\.id) == [b.id, a.id], "move changes visible order")
        check(changes.expenses.map(\.number) == [1, 2], "move renumbers visible rows")
        check(changes.exportExpenses.map(\.amount) == [20, 10], "export follows moved order")
        changes.move(b.id, to: a.id)
        check(changes.expenses.map(\.id) == [a.id, b.id], "drag target controls row order")
        check(changes.exportExpenses.map(\.amount) == [10, 20], "export follows dragged order")
        changes.move(a.id, to: b.id)
        changes.selectCategory(.transport, for: b.id)
        check(changes.expenses[0].purpose == "餐食费用", "custom purpose survives category change")
        let blank = Expense(number: 3, sourceURL: image)
        changes.insert(blank, fingerprint: Data([3]))
        changes.selectCategory(.transport, for: blank.id)
        check(changes.expenses[2].purpose == "交通费用", "category fills blank purpose")
        changes.selectCategory(.meals, for: blank.id)
        check(changes.expenses[2].purpose == "餐食费用", "category updates generated purpose")
        changes.delete(a.id)
        check(changes.expenses.map(\.number) == [1, 2], "delete renumbers rows")
        check(changes.exportExpenses.map(\.id) == [b.id, blank.id], "delete removes export record")
        let reimported = Expense(number: 3, sourceURL: image)
        check(changes.insert(reimported, fingerprint: Data([1])), "deleted image may be imported again")
        let duplicateDeletion = ExpenseStore()
        duplicateDeletion.insert(first, fingerprint: Data([4]))
        duplicateDeletion.insert(repeated, fingerprint: Data([4]))
        duplicateDeletion.delete(first.id)
        check(duplicateDeletion.expenses.count == 1 && !duplicateDeletion.expenses[0].isDuplicate,
            "deleting original activates remaining duplicate")
    }
}

#if canImport(XCTest) && !DIRECT_TEST_RUNNER
final class ExpenseStoreTests: XCTestCase {
    func testStoreWorkflow() async throws {
        try await StoreChecks.run()
    }
}
#endif

#if DIRECT_TEST_RUNNER
@main struct RunStoreChecks {
    static func main() async throws {
        try await StoreChecks.run()
        print("ExpenseStore checks passed")
    }
}
#endif
