#if DIRECT_TEST_RUNNER
import Foundation

@main struct OrderVisionStoreCheck {
    @MainActor static func main() async throws {
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        func consent(_ enabled: Bool) {
            UserDefaults.standard.setVolatileDomain(previous.merging([
                "reimbursement.ai.enabled": true, "reimbursement.ai.orderVisionEnabled": enabled,
                "reimbursement.ai.invoiceFallbackEnabled": false
            ]) { _, value in value }, forName: UserDefaults.argumentDomain)
        }
        consent(true)
        let config = try AIRequestConfiguration(endpoint: URL(string: "https://example.invalid/chat/completions")!, model: "vision-offline", apiKey: "offline-not-sent")
        func row() -> Expense { Expense(number: 1, sourceURL: URL(fileURLWithPath: "/tmp/vision-store-no-image-needed.png"), amount: 39, category: .meals, purpose: "餐食费用", date: "2026-10-28") }
        let certainResult = SemanticClassification(category: .transport, isCertain: true, reason: "视觉出行服务", payment: SemanticPayment(amount: 40, isCertain: true, reason: "截图实付40", candidates: []), transactionDate: SemanticDate(date: "2026-10-29", isCertain: true, reason: "截图日期", candidates: []))
        func wait(_ store: ExpenseStore) async {
            for _ in 0..<200 where !store.aiPendingIDs.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
            precondition(store.aiPendingIDs.isEmpty, "Offline vision task must finish")
        }
        let store = ExpenseStore(); let initial = row(); store.expenses = [initial]
        precondition(store.automaticAIPlan(for: initial.id) == nil, "Formal text fallback does not need a complete row")
        precondition(store.visionAIPlan(for: initial.id) != nil, "Vision tests include complete rows even without OCR text")
        store.startVisionAI(initial.id, configuration: config, recognize: { _, text, _ in
            precondition(text.isEmpty, "Empty OCR must still permit visual recognition")
            return certainResult
        })
        await wait(store)
        precondition(store.expenses[0].amount == 40 && store.expenses[0].category == .transport && store.expenses[0].date == "2026-10-29", "Visual result replaces unedited local fields")
        precondition(store.aiNotes[initial.id]?.contains("识别前") == true && store.aiNotes[initial.id]?.contains("视觉结果") == true)
        store.automaticallyAssistUnresolvedExpenses()
        precondition(store.aiPendingIDs.isEmpty, "Saving settings cannot repeatedly upload an already attempted row")

        let edited = row(); store.reset(); store.expenses = [edited]
        store.startVisionAI(edited.id, configuration: config, recognize: { _, _, _ in
            try await Task.sleep(nanoseconds: 20_000_000)
            return certainResult
        })
        store.markEdited(edited.id, field: .amount); store.expenses[0].amount = 88
        store.markEdited(edited.id, field: .date); store.expenses[0].date = "2025-09-24"
        store.selectCategory(.purchases, for: edited.id)
        await wait(store)
        precondition(store.expenses[0].amount == 88 && store.expenses[0].date == "2025-09-24" && store.expenses[0].category == .purchases, "In-flight visual results cannot overwrite manual edits")

        store.reset(); let uncertain = row(); store.expenses = [uncertain]
        store.startVisionAI(uncertain.id, configuration: config, recognize: { _, _, _ in
            SemanticClassification(category: .meals, isCertain: true, reason: "餐食", payment: SemanticPayment(amount: nil, isCertain: false, reason: "两个可能实付", candidates: [39,45]))
        })
        await wait(store)
        precondition(store.expenses[0].amount == nil && store.amountCandidates[uncertain.id]?.map(\.amount) == [39,45], "Uncertain vision cannot silently keep a local amount as confirmed")
        precondition(store.exportBlocker != nil, "Uncertain money still requires user choice")

        store.reset(); let refund = row(); store.expenses = [refund]
        store.startVisionAI(refund.id, configuration: config, recognize: { _, _, _ in
            SemanticClassification(category: .uncategorized, isCertain: false, reason: "退款", payment: SemanticPayment(isNonExpense: true, amount: nil, isCertain: false, reason: "退款/收入，不作为报销支出", candidates: []))
        })
        await wait(store)
        precondition(store.expenses[0].amount == nil && store.amountCandidates[refund.id]?.isEmpty == true && store.exportBlocker != nil, "Refund cannot retain local paid amount or candidates")

        store.reset(); let failed = row(); store.expenses = [failed]
        store.startVisionAI(failed.id, configuration: config, recognize: { _, _, _ in throw URLError(.cannotConnectToHost) })
        await wait(store)
        precondition(store.expenses[0].amount == 39 && store.aiNotes[failed.id]?.contains("未完成") == true, "Failure clearly retains local data")
        let saved = store.snapshot(title: "离线测试")
        store.restore(saved)
        precondition(store.aiPendingIDs.isEmpty, "Opening an existing project does not repeat paid vision requests")
        consent(false)
        precondition(store.visionAIPlan(for: failed.id) == nil)
        store.startVisionAI(failed.id, configuration: config, recognize: { _, _, _ in preconditionFailure("No consent must never dispatch") })
        precondition(store.aiPendingIDs.isEmpty)
        consent(true)
        store.startVisionAI(failed.id, configuration: config, recognize: { _, _, _ in
            try await Task.sleep(nanoseconds: 20_000_000); return certainResult
        })
        consent(false)
        await wait(store)
        precondition(store.expenses[0].amount == 39, "Revoked authorization rejects in-flight results")
        consent(true)
        store.reset()
        let ocrFailure = Expense(number: 1, sourceURL: URL(fileURLWithPath: "/tmp/ocr-failure.png"), warning: "识别失败：本地OCR不可用。请手动填写并确认。")
        store.expenses = [ocrFailure]
        store.startVisionAI(ocrFailure.id, configuration: config, recognize: { _, _, _ in certainResult })
        await wait(store)
        precondition(store.expenses[0].warning == nil && store.exportBlocker == nil, "Successful complete visual result resolves an OCR-failure warning")
        var merchantResult = certainResult
        merchantResult = SemanticClassification(category: .uncategorized, isCertain: false, reason: "综合商户无法确定商品", payment: certainResult.payment, transactionDate: certainResult.transactionDate)
        merchantResult.purposeSummary = SemanticPurpose(text: "便利店消费", isCertain: true, source: "merchant", reason: "截图仅显示便利店名称")
        let merchant = merchantResult
        store.reset(); let merchantRow = row(); store.expenses = [merchantRow]
        store.startVisionAI(merchantRow.id, configuration: config, recognize: { _, _, _ in merchant })
        await wait(store)
        precondition(store.expenses[0].purpose == "便利店消费" && store.expenses[0].category == .uncategorized && store.exportBlocker == nil)
        store.expenses[0].warning = "用途待确认（视觉 AI）；金额未标明实付"
        store.markEdited(merchantRow.id, field: .purpose)
        precondition(store.expenses[0].warning == "金额未标明实付", "Editing purpose must preserve amount warnings")
        // A malformed purpose must not discard valid money/date or replace the local purpose.
        var invalidPurpose = certainResult
        invalidPurpose.purposeValidationFailed = true
        invalidPurpose.validationIssues = ["用途：缺少有效依据，保留原值"]
        let invalidPurposeResult = invalidPurpose
        store.reset(); let partialRow = row(); store.expenses = [partialRow]
        store.startVisionAI(partialRow.id, configuration: config, recognize: { _, _, _ in invalidPurposeResult })
        await wait(store)
        precondition(store.expenses[0].amount == 40 && store.expenses[0].date == "2026-10-29", "Good fields still fill")
        precondition(store.expenses[0].purpose == "餐食费用", "Malformed purpose must preserve existing purpose despite a changed AI category")
        precondition(store.aiNotes[partialRow.id]?.contains("用途：缺少有效依据") == true && store.exportBlocker != nil, "Invalid field has a specific issue and remains reviewable")

        var invalidAmount = SemanticClassification(category: .uncategorized, isCertain: false, reason: "分类不明", transactionDate: certainResult.transactionDate)
        invalidAmount.purposeSummary = SemanticPurpose(text: "场地定金", isCertain: true, source: "remark", reason: "转账备注")
        invalidAmount.validationIssues = ["金额：格式无效，保留原值"]
        let invalidAmountResult = invalidAmount
        store.reset(); let invalidMoneyRow = row(); store.expenses = [invalidMoneyRow]
        store.startVisionAI(invalidMoneyRow.id, configuration: config, recognize: { _, _, _ in invalidAmountResult })
        await wait(store)
        precondition(store.expenses[0].amount == 39 && store.expenses[0].purpose == "场地定金" && store.expenses[0].date == "2026-10-29")
        precondition(store.exportBlocker != nil, "A malformed AI amount retains local amount and review warning")
        store.markEdited(invalidMoneyRow.id, field: .amount)
        store.expenses[0].amount = 200
        precondition(store.expenses[0].warning?.contains("金额待核对") != true, "Manual amount resolves only its own validation warning")

        var localPurpose = row(); localPurpose.purpose = "本地笼统用途"
        store.reset(); store.expenses = [localPurpose]
        store.startVisionAI(localPurpose.id, configuration: config, recognize: { _, _, _ in merchant })
        await wait(store)
        precondition(store.expenses[0].purpose == "便利店消费", "Unedited local purpose yields to AI semantic summary")
        store.reset(); store.expenses = [localPurpose]
        store.startVisionAI(localPurpose.id, configuration: config, recognize: { _, _, _ in
            try await Task.sleep(nanoseconds: 20_000_000); return merchant
        })
        store.markEdited(localPurpose.id, field: .purpose); store.expenses[0].purpose = "我填写的用途"
        await wait(store)
        precondition(store.expenses[0].purpose == "我填写的用途", "Higher AI purpose priority never overrides a manual edit")

        let defaults = UserDefaults.standard
        let archiveKey = "reimbursement.ai.orderVisionRules"
        let preferencesKey = "reimbursement.ai.orderVisionPreferences"
        let originalArchive = defaults.string(forKey: archiveKey)
        let originalPreferenceData = defaults.data(forKey: preferencesKey)
        defer {
            if let originalArchive { defaults.set(originalArchive, forKey: archiveKey) }
            else { defaults.removeObject(forKey: archiveKey) }
            if let originalPreferenceData { defaults.set(originalPreferenceData, forKey: preferencesKey) }
            else { defaults.removeObject(forKey: preferencesKey) }
        }
        defaults.set("旧整段规则：不得参与当前识别", forKey: archiveKey)
        var legacyPreferences = OrderVisionPreferences.defaults
        legacyPreferences.classificationNote = "设备租赁归其他"
        legacyPreferences.extraInstructions = "用途保留转账备注"
        defaults.set(try JSONEncoder().encode(legacyPreferences), forKey: preferencesKey)
        var preferences = AIConfiguration.orderVisionPreferences
        precondition(preferences.classificationNote.isEmpty && preferences.extraInstructions == "分类补充：设备租赁归其他\n用途保留转账备注")
        precondition(AIConfiguration.archivedOrderVisionRules == "旧整段规则：不得参与当前识别")
        precondition(AIConfiguration.effectiveOrderVisionRules.hasPrefix(OrderVisionClassifier.defaultRules) && !AIConfiguration.effectiveOrderVisionRules.contains("不得参与当前识别"), "Archived whole rules are never sent to the model")
        let migratedRules = AIConfiguration.effectiveOrderVisionRules
        let stableRevision = AIConfiguration.revision
        try AIConfiguration.saveOrderVisionSettings(preferences: preferences)
        precondition(AIConfiguration.revision == stableRevision && AIConfiguration.effectiveOrderVisionRules == migratedRules, "Saving migration without changing effective rules does not invalidate requests")
        let savedPreferences = try JSONDecoder().decode(OrderVisionPreferences.self, from: defaults.data(forKey: preferencesKey)!)
        precondition(savedPreferences.classificationNote.isEmpty && savedPreferences.extraInstructions == preferences.extraInstructions, "Migration is persisted once")
        precondition(AIConfiguration.archivedOrderVisionRules == "旧整段规则：不得参与当前识别", "Saving current preferences preserves the old archive")
        var badPreferences = preferences; badPreferences.extraInstructions = String(repeating: "x", count: 4001)
        do { try AIConfiguration.saveOrderVisionSettings(preferences: badPreferences); preconditionFailure("Invalid settings accepted") } catch {}
        precondition(AIConfiguration.orderVisionPreferences == preferences && AIConfiguration.revision == stableRevision && AIConfiguration.archivedOrderVisionRules == "旧整段规则：不得参与当前识别", "Validation occurs before any settings mutation")
        store.reset(); let rulesRow = row(); store.expenses = [rulesRow]
        store.startVisionAI(rulesRow.id, configuration: config, recognize: { _, _, _ in
            try await Task.sleep(nanoseconds: 20_000_000); return merchant
        })
        preferences.purposeStyle = .merchant
        try AIConfiguration.saveOrderVisionSettings(preferences: preferences)
        await wait(store)
        precondition(store.expenses[0].purpose == rulesRow.purpose && store.aiNotes[rulesRow.id]?.contains("已改变") == true, "Changed preferences discard in-flight old results")
        store.automaticallyAssistUnresolvedExpenses()
        precondition(store.aiPendingIDs.isEmpty, "Changed preferences don't repeat attempted rows")
        AIConfiguration.resetOrderVisionSettings()
        precondition(AIConfiguration.orderVisionPreferences == .defaults && AIConfiguration.effectiveOrderVisionRules.hasPrefix(OrderVisionClassifier.defaultRules), "Reset restores active defaults")
        precondition(AIConfiguration.archivedOrderVisionRules == "旧整段规则：不得参与当前识别", "Reset never deletes the legacy archive")
        print("Vision store: all new rows, empty OCR, comparison, manual protection, candidates, refunds, failure, repeat and consent checks passed (offline)")
    }
}
#endif
