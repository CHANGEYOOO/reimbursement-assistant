import Combine
import CryptoKit
import Foundation

public enum ExpenseReviewStatus: String {
    case processing = "识别中"
    case incomplete = "待补全"
    case needsReview = "待核对"
    case reviewed = "已核对"
    case aiRecognized = "AI 已识别"
    case ready = "待人工核对"
    case duplicate = "重复"
}

public struct ExpenseExportIssue: Identifiable {
    public let id: UUID
    public let number: Int
    public let reasons: [String]
}

@MainActor public final class ExpenseStore: ObservableObject {
    enum Field: Hashable { case amount, purpose, category, date }
    struct AutomaticAIPlan {
        let category: Bool
        let amount: Bool
        let date: Bool
    }

    @Published public var expenses: [Expense] = []
    @Published public private(set) var pendingIDs: Set<UUID> = []
    @Published public var confirmedWarnings: Set<UUID> = []
    @Published public private(set) var recognizedTexts: [UUID: String] = [:]
    @Published public private(set) var amountCandidates: [UUID: [AmountCandidate]] = [:]
    @Published public private(set) var aiPendingIDs: Set<UUID> = []
    @Published public private(set) var aiNotes: [UUID: String] = [:]
    private var aiTokens: [UUID: UUID] = [:]
    private var categoryRevisions: [UUID: Int] = [:]
    private var amountRevisions: [UUID: Int] = [:]
    private var dateRevisions: [UUID: Int] = [:]
    @Published public private(set) var aiAmountUpdates: [UUID: Int] = [:]
    @Published public private(set) var dateCandidates: [UUID: [String]] = [:]
    private var fingerprints: [UUID: Data] = [:]
    private var editedFields: [UUID: Set<Field>] = [:]
    private var recognitionTokens: [UUID: UUID] = [:]
    public let actionUndoManager = UndoManager()
    @Published public private(set) var undoActionName: String?

    public init() { actionUndoManager.groupsByEvent = false }

    public func undoLastAction() {
        guard actionUndoManager.canUndo else { return }
        actionUndoManager.undo()
        updateUndoName()
    }

    private func updateUndoName() {
        undoActionName = actionUndoManager.canUndo ? actionUndoManager.undoActionName : nil
    }

    private func registerUndo(_ name: String, action: @escaping @MainActor (ExpenseStore) -> Void) {
        actionUndoManager.beginUndoGrouping()
        actionUndoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { action(store) }
        }
        actionUndoManager.setActionName(name)
        actionUndoManager.endUndoGrouping()
        updateUndoName()
    }

    private func clearUndo() {
        aiTokens = [:]
        aiPendingIDs = []
        aiNotes = [:]
        categoryRevisions = [:]
        amountRevisions = [:]
        dateRevisions = [:]
        aiAmountUpdates = [:]
        dateCandidates = [:]
        actionUndoManager.removeAllActions()
        undoActionName = nil
        recognitionTokens = [:]
    }

    public func reset() {
        clearUndo()
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
        clearUndo()
        expenses = snapshot.expenses
        pendingIDs = snapshot.pendingIDs
        confirmedWarnings = snapshot.confirmedWarnings
        recognizedTexts = snapshot.recognizedTexts
        amountCandidates = snapshot.amountCandidates
        editedFields = [:]
        fingerprints = [:]
        for expense in expenses {
            // 旧草稿未记录数值来源，已保存的数值优先保留，避免覆盖历史人工填写。
            if expense.amount != nil { amountRevisions[expense.id] = 1 }
            if !expense.date.isEmpty { dateRevisions[expense.id] = 1 }
            if !expense.purpose.isEmpty { categoryRevisions[expense.id] = 1 }
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
            scheduleRecognition(id: id, url: expense.sourceURL)
        }
        automaticallyAssistUnresolvedExpenses()
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
        expenses.filter { needsReview($0) }.count
    }

    func needsReview(_ expense: Expense) -> Bool {
        !issues(for: expense).isEmpty
    }

    private func missingFields(for expense: Expense) -> [String] {
        var reasons: [String] = []
        if !(expense.amount.map { $0 > 0 } ?? false) { reasons.append("请填写正数金额") }
        if !ExpenseDate.isValid(expense.date) { reasons.append("请填写有效日期（年-月-日）") }
        if expense.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append("请填写用途") }
        return reasons
    }

    public func issues(for expense: Expense) -> [String] {
        guard !expense.isDuplicate else { return [] }
        var reasons = pendingIDs.contains(expense.id) ? ["正在识别，请等待完成"] : []
        if aiPendingIDs.contains(expense.id) { reasons.append("AI 正在判断用途，请等待完成或手动选择分类") }
        reasons += missingFields(for: expense)
        if let warning = expense.warning, !confirmedWarnings.contains(expense.id), !pendingIDs.contains(expense.id) {
            reasons.append("\(warning)；请人工核对")
        }
        return reasons
    }

    public func status(for expense: Expense) -> ExpenseReviewStatus {
        if expense.isDuplicate { return .duplicate }
        if pendingIDs.contains(expense.id) || aiPendingIDs.contains(expense.id) { return .processing }
        if !missingFields(for: expense).isEmpty { return .incomplete }
        if expense.warning != nil && !confirmedWarnings.contains(expense.id) { return .needsReview }
        if confirmedWarnings.contains(expense.id) { return .reviewed }
        return expense.aiRecognized == true ? .aiRecognized : .ready
    }

    public var exportIssues: [ExpenseExportIssue] {
        expenses.compactMap { expense in
            let reasons = issues(for: expense)
            return reasons.isEmpty ? nil : ExpenseExportIssue(id: expense.id, number: expense.number, reasons: reasons)
        }
    }

    func matchesFilters(_ expense: Expense, amountQuery: String, onlyNeedsReview: Bool) -> Bool {
        if onlyNeedsReview && !needsReview(expense) { return false }
        let query = amountQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        guard let amount = expense.amount else { return false }
        let text = amount.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
            .grouping(.never).precision(.fractionLength(2)))
        return text.contains(query)
    }

    public var exportBlocker: String? {
        if exportExpenses.isEmpty { return "请先导入截图。" }
        if !pendingIDs.isEmpty { return "请等待截图识别完成。" }
        if !aiPendingIDs.isEmpty { return "请等待 AI 用途判断完成，或手动选择分类。" }
        if let issue = exportIssues.first, let reason = issue.reasons.first {
            return "第\(issue.number)笔\(reason)。"
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
        moveToIndex(id, index + offset)
    }

    public func move(_ id: UUID, to targetID: UUID) {
        guard id != targetID,
              expenses.contains(where: { $0.id == id }),
              let target = expenses.firstIndex(where: { $0.id == targetID }) else { return }
        moveToIndex(id, target)
    }

    private func moveToIndex(_ id: UUID, _ destination: Int) {
        guard let source = expenses.firstIndex(where: { $0.id == id }), source != destination else { return }
        let expense = expenses.remove(at: source)
        expenses.insert(expense, at: min(max(0, destination), expenses.count))
        renumber()
        registerUndo("调整顺序") { $0.moveToIndex(id, source) }
    }

    private struct DeletedExpense {
        let expense: Expense
        let index: Int
        let fingerprint: Data?
        let confirmed: Bool
        let text: String?
        let candidates: [AmountCandidate]?
        let dates: [String]?
        let edited: Set<Field>?
        let pending: Bool
        let categoryRevision: Int
        let amountRevision: Int
        let dateRevision: Int
    }

    public func delete(_ id: UUID) {
        guard let index = expenses.firstIndex(where: { $0.id == id }) else { return }
        let deleted = DeletedExpense(expense: expenses[index], index: index, fingerprint: fingerprints[id],
            confirmed: confirmedWarnings.contains(id), text: recognizedTexts[id], candidates: amountCandidates[id],
            dates: dateCandidates[id], edited: editedFields[id], pending: pendingIDs.contains(id),
            categoryRevision: categoryRevisions[id, default: 0], amountRevision: amountRevisions[id, default: 0],
            dateRevision: dateRevisions[id, default: 0])
        aiTokens.removeValue(forKey: id)
        aiPendingIDs.remove(id)
        aiNotes.removeValue(forKey: id)
        categoryRevisions.removeValue(forKey: id)
        amountRevisions.removeValue(forKey: id)
        dateRevisions.removeValue(forKey: id)
        aiAmountUpdates.removeValue(forKey: id)
        dateCandidates.removeValue(forKey: id)
        recognitionTokens.removeValue(forKey: id)
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
            scheduleRecognition(id: nextID, url: expenses[next].sourceURL)
        }
        registerUndo("删除订单") { $0.restoreDeleted(deleted) }
    }

    private func restoreDeleted(_ deleted: DeletedExpense) {
        let id = deleted.expense.id
        guard !expenses.contains(where: { $0.id == id }) else { return }
        expenses.insert(deleted.expense, at: min(deleted.index, expenses.count))
        fingerprints[id] = deleted.fingerprint
        if deleted.confirmed { confirmedWarnings.insert(id) }
        recognizedTexts[id] = deleted.text
        amountCandidates[id] = deleted.candidates
        dateCandidates[id] = deleted.dates
        categoryRevisions[id] = deleted.categoryRevision
        amountRevisions[id] = deleted.amountRevision
        dateRevisions[id] = deleted.dateRevision
        editedFields[id] = deleted.edited
        if !deleted.expense.isDuplicate, let fingerprint = deleted.fingerprint {
            for index in expenses.indices where expenses[index].id != id && fingerprints[expenses[index].id] == fingerprint {
                let otherID = expenses[index].id
                expenses[index].isDuplicate = true
                expenses[index].warning = "重复截图，已排除在合计和导出之外。"
                recognitionTokens.removeValue(forKey: otherID)
                pendingIDs.remove(otherID)
                aiTokens.removeValue(forKey: otherID)
                aiPendingIDs.remove(otherID)
                aiNotes.removeValue(forKey: otherID)
            }
        }
        renumber()
        if deleted.pending {
            pendingIDs.insert(id)
            if deleted.fingerprint != nil {
                scheduleRecognition(id: id, url: deleted.expense.sourceURL)
            } else {
                let token = UUID()
                recognitionTokens[id] = token
                Task { await processExpense(id: id, url: deleted.expense.sourceURL, token: token) }
            }
        }
        registerUndo("删除订单") { $0.delete(id) }
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
        let queued = urls.map { url in
            let id = queue(url)
            return (id, url, recognitionTokens[id]!)
        }
        Task { for (id, url, token) in queued { await processExpense(id: id, url: url, token: token) } }
    }

    func importFile(_ url: URL) async {
        let id = queue(url)
        await processExpense(id: id, url: url, token: recognitionTokens[id]!)
    }

    func queue(_ url: URL) -> UUID {
        let expense = Expense(number: expenses.count + 1, sourceURL: url, warning: "正在识别…")
        expenses.append(expense)
        pendingIDs.insert(expense.id)
        recognitionTokens[expense.id] = UUID()
        return expense.id
    }

    func markEdited(_ id: UUID, field: Field) {
        if let index = expenses.firstIndex(where: { $0.id == id }) { expenses[index].aiRecognized = nil }
        if field == .category || field == .purpose { categoryRevisions[id, default: 0] += 1 }
        if field == .amount {
            amountRevisions[id, default: 0] += 1
            aiAmountUpdates.removeValue(forKey: id)
        }
        if field == .date { dateRevisions[id, default: 0] += 1 }
        if aiTokens.removeValue(forKey: id) != nil {
            aiPendingIDs.remove(id)
            aiNotes[id] = "已保留你的手动修改。"
        }
        editedFields[id, default: []].insert(field)
    }

    func needsAIAmount(_ expense: Expense) -> Bool {
        if expense.amount == nil || expense.amount! <= 0 { return true }
        guard amountRevisions[expense.id, default: 0] == 0,
              !confirmedWarnings.contains(expense.id) else { return false }
        let warning = expense.warning ?? ""
        return ["仅识别到订单合计", "金额未标明实付", "金额未紧邻实付标识"].contains(where: warning.contains)
            || (amountCandidates[expense.id]?.count ?? 0) > 1
    }

    func automaticAIPlan(for id: UUID) -> AutomaticAIPlan? {
        guard !pendingIDs.contains(id), !aiPendingIDs.contains(id),
              let expense = expenses.first(where: { $0.id == id }), !expense.isDuplicate,
              let text = recognizedTexts[id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let category = expense.category == .uncategorized && categoryRevisions[id, default: 0] == 0
        let amount = needsAIAmount(expense) && amountRevisions[id, default: 0] == 0
        let date = !ExpenseDate.isValid(expense.date) && dateRevisions[id, default: 0] == 0
        return category || amount || date ? AutomaticAIPlan(category: category, amount: amount, date: date) : nil
    }

    public func automaticallyAssistUnresolvedExpenses() {
        guard AIConfiguration.enabled else { return }
        for id in expenses.map(\.id) { automaticallyAssist(id) }
    }

    private func automaticallyAssist(_ id: UUID) {
        guard AIConfiguration.enabled, let plan = automaticAIPlan(for: id) else { return }
        classifyWithAI(id, includeCategory: plan.category, includeAmount: plan.amount, includeDate: plan.date)
    }

    public func classifyWithAI(_ id: UUID, includeCategory: Bool = true,
                               includeAmount: Bool? = nil, includeDate: Bool? = nil) {
        guard !pendingIDs.contains(id), !aiPendingIDs.contains(id),
              let expense = expenses.first(where: { $0.id == id }), !expense.isDuplicate else { return }
        guard let text = recognizedTexts[id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            aiNotes[id] = "没有可供 AI 判断的识别文字。"
            return
        }
        let assessAmount = (includeAmount ?? needsAIAmount(expense)) && needsAIAmount(expense)
        let assessDate = (includeDate ?? !ExpenseDate.isValid(expense.date)) && !ExpenseDate.isValid(expense.date)
        guard includeCategory || assessAmount || assessDate else { return }
        do {
            guard let configuration = try AIConfiguration.currentRequest() else {
                aiNotes[id] = "请先在 AI 设置中配置并启用服务。"
                return
            }
            let token = UUID()
            let configurationRevision = AIConfiguration.revision
            let revision = categoryRevisions[id, default: 0]
            let amountRevision = amountRevisions[id, default: 0]
            let dateRevision = dateRevisions[id, default: 0]
            let wasConfirmed = confirmedWarnings.contains(id)
            aiTokens[id] = token
            aiPendingIDs.insert(id)
            aiNotes[id] = "AI 正在辅助识别…"
            Task {
                do {
                    let result = try await SemanticClassifier.classify(text: text, configuration: configuration,
                        includeAmount: assessAmount, includeDate: assessDate)
                    guard aiTokens[id] == token else { return }
                    guard AIConfiguration.enabled, AIConfiguration.revision == configurationRevision else {
                        aiNotes[id] = "AI 配置已更新，旧请求结果未应用。"
                        finishAI(id)
                        return
                    }
                    guard let current = expenses.first(where: { $0.id == id }),
                          categoryRevisions[id, default: 0] == revision,
                          amountRevisions[id, default: 0] == amountRevision,
                          dateRevisions[id, default: 0] == dateRevision,
                          current.amount == expense.amount, current.date == expense.date,
                          confirmedWarnings.contains(id) == wasConfirmed else {
                        aiNotes[id] = "已保留你在 AI 判断期间的手动修改。"
                        finishAI(id)
                        return
                    }
                    aiNotes[id] = ""
                    if includeCategory { applySemanticClassification(result, to: id) }
                    if assessAmount, let payment = result.payment { applySemanticPayment(payment, to: id) }
                    if assessDate, let date = result.transactionDate { applySemanticDate(date, to: id) }
                    if aiNotes[id]?.isEmpty != false { aiNotes[id] = "AI 未找到可确定的结果，请手动核对。" }
                } catch {
                    guard aiTokens[id] == token else { return }
                    aiNotes[id] = "AI 未完成：\(error.localizedDescription)。可继续手动填写。"
                }
                guard aiTokens[id] == token else { return }
                finishAI(id)
            }
        } catch {
            aiNotes[id] = "AI 配置不可用：\(error.localizedDescription)"
        }
    }

    private func appendAINote(_ note: String, to id: UUID) {
        aiNotes[id] = [aiNotes[id], note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func acceptAIResult(at index: Int, removing fragments: [String]) {
        let id = expenses[index].id
        confirmedWarnings.remove(id)
        let warnings = (expenses[index].warning ?? "").components(separatedBy: "；")
            .filter { warning in
                !warning.isEmpty && !fragments.contains(where: warning.contains) && !warning.hasPrefix("AI")
            }
        expenses[index].warning = warnings.isEmpty ? nil : warnings.joined(separator: "；")
        expenses[index].aiRecognized = true
    }

    func applySemanticPayment(_ payment: SemanticPayment, to id: UUID) {
        guard let index = expenses.firstIndex(where: { $0.id == id }), !expenses[index].isDuplicate,
              needsAIAmount(expenses[index]) else { return }
        if payment.isCertain, let amount = payment.amount, amount > 0 {
            expenses[index].amount = amount
            amountCandidates[id] = []
            aiAmountUpdates[id, default: 0] += 1
            acceptAIResult(at: index, removing: ["未能确定实付金额", "未标明实付", "金额未紧邻实付标识", "仅识别到订单合计", "多笔订单", "多个不同的实付金额", "多个不同的支出金额", "多个订单合计", "金额待核对"])
            appendAINote("AI 建议金额 ¥\(amount)：\(payment.reason)", to: id)
        } else {
            var candidates = payment.candidates.map { AmountCandidate(amount: $0, source: "AI候选：原文金额") }
            candidates += amountCandidates[id] ?? []
            var seen: Set<Decimal> = []
            amountCandidates[id] = Array(candidates.filter { seen.insert($0.amount).inserted }.prefix(6))
            appendAINote("AI 尚不能确定金额，请选择候选或手动填写：\(payment.reason)", to: id)
        }
    }

    func applySemanticDate(_ result: SemanticDate, to id: UUID) {
        guard let index = expenses.firstIndex(where: { $0.id == id }), !expenses[index].isDuplicate,
              !ExpenseDate.isValid(expenses[index].date) else { return }
        let date = result.isCertain ? result.date : result.candidates.first(where: ExpenseDate.isValid) ?? result.date
        if let date, ExpenseDate.isValid(date) {
            expenses[index].date = date
            dateCandidates[id] = []
            acceptAIResult(at: index, removing: [])
            appendAINote("AI 已填写日期 \(date)\(result.isCertain ? "" : "（参考日期）")：\(result.reason)", to: id)
        } else {
            dateCandidates[id] = result.candidates.filter(ExpenseDate.isValid)
            appendAINote("AI 未找到有效日期，请手动填写：\(result.reason)", to: id)
        }
    }

    func selectDateCandidate(_ date: String, for id: UUID) {
        guard dateCandidates[id]?.contains(date) == true,
              let index = expenses.firstIndex(where: { $0.id == id }), !expenses[index].isDuplicate else { return }
        markEdited(id, field: .date)
        expenses[index].date = date
        dateCandidates[id] = []
    }

    func applySemanticClassification(_ result: SemanticClassification, to id: UUID) {
        guard let index = expenses.firstIndex(where: { $0.id == id }), !expenses[index].isDuplicate else { return }
        if result.isCertain && result.category != .uncategorized {
            let oldCategory = expenses[index].category
            let oldDefault = oldCategory == .uncategorized ? "" : oldCategory.rawValue + "费用"
            if expenses[index].purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expenses[index].purpose == oldDefault {
                expenses[index].purpose = result.category.rawValue + "费用"
            }
            expenses[index].category = result.category
            acceptAIResult(at: index, removing: ["用途分类待确认"])
            appendAINote("AI 建议\(result.category.rawValue)：\(result.reason)", to: id)
        } else {
            appendAINote("AI 尚不能确定用途，请手动选择分类：\(result.reason)", to: id)
        }
    }

    private func finishAI(_ id: UUID) {
        aiTokens.removeValue(forKey: id)
        aiPendingIDs.remove(id)
    }

    public func invalidateAIRequests() {
        for id in aiPendingIDs { aiNotes[id] = "AI 配置已更新，旧请求结果不再应用。" }
        aiTokens = [:]
        aiPendingIDs = []
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
        expenses[index].aiRecognized = nil
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

    private func processExpense(id: UUID, url: URL, token: UUID) async {
        guard recognitionTokens[id] == token else { return }
        do {
            let fingerprint = try await Task.detached(priority: .userInitiated) {
                Data(SHA256.hash(data: try Data(contentsOf: url)))
            }.value
            guard recognitionTokens[id] == token,
                  let index = expenses.firstIndex(where: { $0.id == id }) else { return }
            let unique = !fingerprints.values.contains(fingerprint)
            fingerprints[id] = fingerprint
            if !unique {
                expenses[index].isDuplicate = true
                expenses[index].warning = "重复截图，已排除在合计和导出之外。"
            } else {
                await recognizeExpense(id: id, url: url, token: token)
            }
        } catch {
            if recognitionTokens[id] == token, let index = expenses.firstIndex(where: { $0.id == id }) {
                expenses[index].warning = "识别失败：\(error.localizedDescription)。请手动填写并确认。"
            }
        }
        guard recognitionTokens[id] == token else { return }
        recognitionTokens.removeValue(forKey: id)
        pendingIDs.remove(id)
        editedFields.removeValue(forKey: id)
    }

    private func scheduleRecognition(id: UUID, url: URL) {
        let token = UUID()
        recognitionTokens[id] = token
        Task { await recognizeExpense(id: id, url: url, token: token) }
    }

    private func recognizeExpense(id: UUID, url: URL, token: UUID) async {
        guard recognitionTokens[id] == token else { return }
        do {
            let suggestion = try await Task.detached(priority: .userInitiated) {
                try await Recognition.recognize(url)
            }.value
            guard recognitionTokens[id] == token else { return }
            applySuggestion(suggestion, to: id)
        } catch {
            if recognitionTokens[id] == token, let index = expenses.firstIndex(where: { $0.id == id }) {
                expenses[index].warning = "识别失败：\(error.localizedDescription)。请手动填写并确认。"
            }
        }
        guard recognitionTokens[id] == token else { return }
        recognitionTokens.removeValue(forKey: id)
        pendingIDs.remove(id)
        editedFields.removeValue(forKey: id)
        automaticallyAssist(id)
    }
}
