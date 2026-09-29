import Combine
import CryptoKit
import Foundation

@MainActor public final class ExpenseStore: ObservableObject {
    enum Field: Hashable { case amount, purpose, category, date }

    @Published public var expenses: [Expense] = []
    @Published public private(set) var pendingIDs: Set<UUID> = []
    @Published public var confirmedWarnings: Set<UUID> = []
    @Published public private(set) var recognizedTexts: [UUID: String] = [:]
    @Published public private(set) var amountCandidates: [UUID: [AmountCandidate]] = [:]
    private var fingerprints: [UUID: Data] = [:]
    private var editedFields: [UUID: Set<Field>] = [:]

    public init() {}

    public func reset() {
        expenses = []
        pendingIDs = []
        confirmedWarnings = []
        recognizedTexts = [:]
        amountCandidates = [:]
        fingerprints = [:]
        editedFields = [:]
    }

    func snapshot(title: String) -> DraftSnapshot {
        DraftSnapshot(
            title: title,
            updatedAt: Date(),
            expenses: expenses,
            pendingIDs: pendingIDs,
            confirmedWarnings: confirmedWarnings,
            recognizedTexts: recognizedTexts,
            amountCandidates: amountCandidates
        )
    }

    func restore(_ snapshot: DraftSnapshot) {
        expenses = snapshot.expenses
        pendingIDs = snapshot.pendingIDs
        confirmedWarnings = snapshot.confirmedWarnings
        recognizedTexts = snapshot.recognizedTexts
        amountCandidates = snapshot.amountCandidates
        editedFields = [:]
        fingerprints = [:]
        for expense in expenses {
            if let data = try? Data(contentsOf: expense.sourceURL) {
                fingerprints[expense.id] = Data(SHA256.hash(data: data))
            }
        }
        for id in pendingIDs {
            guard let expense = expenses.first(where: { $0.id == id }) else { continue }
            var edited: Set<Field> = []
            if expense.amount != nil { edited.insert(.amount) }
            if expense.category != .uncategorized { edited.insert(.category) }
            if !expense.purpose.isEmpty { edited.insert(.purpose) }
            if !expense.date.isEmpty { edited.insert(.date) }
            editedFields[id] = edited
            Task { await recognizeExpense(id: id, url: expense.sourceURL) }
        }
    }

    public var exportExpenses: [Expense] {
        expenses.filter { !$0.isDuplicate }.enumerated().map { index, original in
            var expense = original
            expense.number = index + 1
            return expense
        }
    }

    public var total: Decimal {
        exportExpenses.reduce(Decimal.zero) { sum, expense in
            guard !pendingIDs.contains(expense.id),
                  (expense.warning == nil || confirmedWarnings.contains(expense.id)),
                  let amount = expense.amount, amount > 0 else { return sum }
            return sum + amount
        }
    }

    public var amountTotal: Decimal {
        exportExpenses.reduce(Decimal.zero) { $0 + (($1.amount ?? .zero) > 0 ? ($1.amount ?? .zero) : .zero) }
    }

    public var reviewCount: Int {
        exportExpenses.filter { expense in
            pendingIDs.contains(expense.id) || !(expense.amount.map { $0 > 0 } ?? false) ||
            !ExpenseDate.isValid(expense.date) ||
            expense.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            (expense.warning != nil && !confirmedWarnings.contains(expense.id))
        }.count
    }

    public var exportBlocker: String? {
        if exportExpenses.isEmpty { return "请先导入截图。" }
        if !pendingIDs.isEmpty { return "请等待截图识别完成。" }
        for expense in exportExpenses {
            if !(expense.amount.map { $0 > 0 } ?? false) { return "第\(expense.number)笔请填写正数金额。" }
            if !ExpenseDate.isValid(expense.date) { return "第\(expense.number)笔请填写有效日期（年-月-日）。" }
            if expense.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "第\(expense.number)笔请填写用途。" }
            if expense.warning != nil && !confirmedWarnings.contains(expense.id) { return "第\(expense.number)笔请确认识别提示。" }
        }
        return nil
    }

    @discardableResult func insert(_ expense: Expense, fingerprint: Data) -> Bool {
        var expense = expense
        let unique = !fingerprints.values.contains(fingerprint)
        fingerprints[expense.id] = fingerprint
        if !unique {
            expense.isDuplicate = true
            expense.warning = "重复截图，已排除在合计和导出之外。"
        }
        expenses.append(expense)
        return unique
    }

    public func move(_ id: UUID, by offset: Int) {
        guard let index = expenses.firstIndex(where: { $0.id == id }),
              expenses.indices.contains(index + offset) else { return }
        let expense = expenses.remove(at: index)
        expenses.insert(expense, at: index + offset)
        renumber()
    }

    public func move(_ id: UUID, to targetID: UUID) {
        guard id != targetID,
              let source = expenses.firstIndex(where: { $0.id == id }),
              let target = expenses.firstIndex(where: { $0.id == targetID }) else { return }
        let expense = expenses.remove(at: source)
        expenses.insert(expense, at: target)
        renumber()
    }

    public func delete(_ id: UUID) {
        guard let index = expenses.firstIndex(where: { $0.id == id }) else { return }
        let wasDuplicate = expenses[index].isDuplicate
        let fingerprint = fingerprints.removeValue(forKey: id)
        expenses.remove(at: index)
        pendingIDs.remove(id)
        confirmedWarnings.remove(id)
        recognizedTexts.removeValue(forKey: id)
        amountCandidates.removeValue(forKey: id)
        editedFields.removeValue(forKey: id)
        renumber()
        if !wasDuplicate, let fingerprint,
           let next = expenses.firstIndex(where: { fingerprints[$0.id] == fingerprint }) {
            let nextID = expenses[next].id
            expenses[next].isDuplicate = false
            expenses[next].warning = "正在识别…"
            pendingIDs.insert(nextID)
            Task { await recognizeExpense(id: nextID, url: expenses[next].sourceURL) }
        }
    }

    public func selectCategory(_ category: ExpenseCategory, for id: UUID) {
        guard let index = expenses.firstIndex(where: { $0.id == id }) else { return }
        let previous = expenses[index].category
        let oldDefault = previous == .uncategorized ? "" : previous.rawValue + "费用"
        let purpose = expenses[index].purpose
        markEdited(id, field: .category)
        expenses[index].category = category
        if category == .uncategorized { confirmedWarnings.remove(id) }
        else { confirmedWarnings.insert(id) }
        if purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || purpose == oldDefault {
            expenses[index].purpose = category == .uncategorized ? "" : category.rawValue + "费用"
            markEdited(id, field: .purpose)
        }
    }

    public func confirmAll() {
        confirmedWarnings.formUnion(expenses.filter { !$0.isDuplicate }.map(\.id))
    }

    private func renumber() {
        for index in expenses.indices { expenses[index].number = index + 1 }
    }

    public func importFiles(_ urls: [URL]) {
        let queued = urls.map { url in (queue(url), url) }
        Task { for (id, url) in queued { await processExpense(id: id, url: url) } }
    }

    func importFile(_ url: URL) async {
        let id = queue(url)
        await processExpense(id: id, url: url)
    }

    func queue(_ url: URL) -> UUID {
        let expense = Expense(number: expenses.count + 1, sourceURL: url, warning: "正在识别…")
        expenses.append(expense)
        pendingIDs.insert(expense.id)
        return expense.id
    }

    func markEdited(_ id: UUID, field: Field) {
        editedFields[id, default: []].insert(field)
    }

    func selectAmountCandidate(_ candidate: AmountCandidate, for id: UUID) {
        guard amountCandidates[id]?.contains(candidate) == true,
              let index = expenses.firstIndex(where: { $0.id == id }),
              !expenses[index].isDuplicate else { return }
        markEdited(id, field: .amount)
        expenses[index].amount = candidate.amount
        confirmedWarnings.insert(id)
    }

    static func parseAmountInput(_ text: String) -> Decimal? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^[0-9]+(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    func applySuggestion(_ suggestion: Suggestion, to id: UUID) {
        guard let index = expenses.firstIndex(where: { $0.id == id }) else { return }
        let edited = editedFields[id] ?? []
        if !edited.contains(.amount) { expenses[index].amount = suggestion.amount }
        if !edited.contains(.category) { expenses[index].category = suggestion.category }
        if !edited.contains(.purpose) { expenses[index].purpose = suggestion.purpose }
        if !edited.contains(.date) { expenses[index].date = suggestion.date ?? "" }
        expenses[index].warning = suggestion.warning
        recognizedTexts[id] = suggestion.recognizedText
        amountCandidates[id] = suggestion.amountCandidates
        editedFields.removeValue(forKey: id)
    }

    private func processExpense(id: UUID, url: URL) async {
        do {
            let fingerprint = try await Task.detached(priority: .userInitiated) {
                Data(SHA256.hash(data: try Data(contentsOf: url)))
            }.value
            guard let index = expenses.firstIndex(where: { $0.id == id }) else { return }
            let unique = !fingerprints.values.contains(fingerprint)
            fingerprints[id] = fingerprint
            if !unique {
                expenses[index].isDuplicate = true
                expenses[index].warning = "重复截图，已排除在合计和导出之外。"
            } else {
                await recognizeExpense(id: id, url: url)
            }
        } catch {
            if let index = expenses.firstIndex(where: { $0.id == id }) {
                expenses[index].warning = "识别失败：\(error.localizedDescription)。请手动填写并确认。"
            }
        }
        pendingIDs.remove(id)
        editedFields.removeValue(forKey: id)
    }

    private func recognizeExpense(id: UUID, url: URL) async {
        do {
            let suggestion = try await Task.detached(priority: .userInitiated) {
                try await Recognition.recognize(url)
            }.value
            applySuggestion(suggestion, to: id)
        } catch {
            if let index = expenses.firstIndex(where: { $0.id == id }) {
                expenses[index].warning = "识别失败：\(error.localizedDescription)。请手动填写并确认。"
            }
        }
        pendingIDs.remove(id)
        editedFields.removeValue(forKey: id)
    }
}
