#if DIRECT_TEST_RUNNER
import Foundation

@main struct OrderRecognitionModeCheck {
    @MainActor static func main() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        func mode(enabled: Bool, upload: Bool) {
            defaults.setVolatileDomain(previous.merging([
                "reimbursement.ai.enabled": enabled,
                "reimbursement.ai.orderVisionEnabled": upload,
                "reimbursement.ai.invoiceFallbackEnabled": false
            ]) { _, next in next }, forName: UserDefaults.argumentDomain)
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("recognition-mode-\(UUID().uuidString).png")
        try Data("offline fixture; recognizers are injected".utf8).write(to: fixture)
        let configuration = try AIRequestConfiguration(endpoint: URL(string: "https://example.invalid/chat/completions")!, model: "offline-vision", apiKey: "not-sent")
        var visionResult = SemanticClassification(category: .purchases, isCertain: true, reason: "截图备注为胶水", payment: SemanticPayment(amount: 200, isCertain: true, reason: "明确支出200元", candidates: []), transactionDate: SemanticDate(date: "2026-10-22", isCertain: true, reason: "截图交易日期", candidates: []))
        visionResult.purposeSummary = SemanticPurpose(text: "大力胶采购", isCertain: true, source: "remark", reason: "截图转账备注")
        let recognizedVision = visionResult
        let recognizedLocal = Suggestion(amount: 39, category: .meals, purpose: "本地餐食用途", warning: nil, recognizedText: "仅本地OCR文字", date: "2026-10-01")
        func waitForAI(_ store: ExpenseStore) async {
            for _ in 0..<200 where !store.aiPendingIDs.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
            precondition(store.aiPendingIDs.isEmpty, "Injected AI recognizer did not finish")
        }
        let store = ExpenseStore()

        mode(enabled: true, upload: true)
        let aiID = store.queue(fixture)
        var visualCalls = 0
        await store.recognizeExpense(id: aiID, url: fixture,
            recognizeLocally: { _ in preconditionFailure("AI-only import must never execute local OCR or rules") },
            recognizeVisually: { id in
                visualCalls += 1
                store.startVisionAI(id, configuration: configuration, recognize: { _, text, _ in
                    precondition(text.isEmpty, "AI-only import must not send OCR text")
                    return recognizedVision
                })
            })
        await waitForAI(store)
        precondition(visualCalls == 1 && store.expenses[0].amount == 200 && store.expenses[0].date == "2026-10-22" && store.expenses[0].purpose == "大力胶采购")
        precondition((store.recognizedTexts[aiID] ?? "").isEmpty && !store.pendingIDs.contains(aiID))

        // Initial imports keep a grounded generic AI summary even when the model is cautious.
        var billSummary = SemanticClassification(category: .uncategorized, isCertain: false, reason: "交易摘要无具体商品", payment: SemanticPayment(amount: Decimal(string: "41.70"), isCertain: true, reason: "消费扣款41.70", candidates: []), transactionDate: SemanticDate(date: "2026-10-23", isCertain: true, reason: "交易日期", candidates: []))
        billSummary.purposeSummary = SemanticPurpose(text: "某平台消费", isCertain: false, source: "bill", reason: "仅见平台名称及消费摘要，无具体商品明细")
        let cautiousSummary = billSummary
        store.reset(); let billID = store.queue(fixture)
        await store.recognizeExpense(id: billID, url: fixture,
            recognizeLocally: { _ in preconditionFailure("Purpose cannot fall back to OCR") },
            recognizeVisually: { id in
                store.startVisionAI(id, configuration: configuration, recognize: { _, text, _ in
                    precondition(text.isEmpty); return cautiousSummary
                })
            })
        await waitForAI(store)
        precondition(store.expenses[0].purpose == "某平台消费", "Automatic import must not erase an available grounded AI purpose summary")
        precondition(store.expenses[0].category == .uncategorized && store.expenses[0].amount == Decimal(string: "41.70"))
        precondition(store.exportBlocker != nil && store.expenses[0].warning?.contains("用途待确认") == true, "A cautious AI suggestion is prefilled but still needs review")
        precondition(store.aiNotes[billID]?.contains("用途建议：某平台消费") == true, "The actual model summary remains visible for diagnosis")
        store.automaticallyAssistUnresolvedExpenses()
        precondition(store.aiPendingIDs.isEmpty, "Uncertain purpose must not trigger automatic retries")
        store.startVisionAI(billID, configuration: configuration, recognize: { _, _, _ in cautiousSummary })
        await waitForAI(store)
        precondition(store.expenses[0].purpose == "某平台消费", "Manual retest of the same response has the same purpose behavior")
        var confident = cautiousSummary
        confident.purposeSummary = SemanticPurpose(text: "某平台消费", isCertain: true, source: "bill", reason: "账单摘要支持平台消费，不推测商品")
        let confidentSummary = confident
        store.startVisionAI(billID, configuration: configuration, recognize: { _, _, _ in confidentSummary })
        await waitForAI(store)
        precondition(store.expenses[0].purpose == "某平台消费" && store.expenses[0].category == .uncategorized && store.exportBlocker == nil, "Reliable generic purpose can export without forcing a category")

        var ungrounded = cautiousSummary
        ungrounded.purposeSummary = SemanticPurpose(text: "商户消费", isCertain: false, source: "unknown", reason: "看不清交易摘要")
        let ungroundedSummary = ungrounded
        store.reset(); let unknownID = store.queue(fixture)
        await store.recognizeExpense(id: unknownID, url: fixture,
            recognizeLocally: { _ in preconditionFailure("No OCR fallback") },
            recognizeVisually: { id in store.startVisionAI(id, configuration: configuration, recognize: { _, _, _ in ungroundedSummary }) })
        await waitForAI(store)
        precondition(store.expenses[0].purpose.isEmpty && store.exportBlocker != nil, "Unknown source stays unfilled rather than inventing a purpose")
        precondition(store.aiNotes[unknownID]?.contains("用途建议：商户消费") == true, "Even an ungrounded model summary is visible without treating it as confirmed data")

        var cautiousMoney = SemanticClassification(category: .uncategorized, isCertain: false, reason: "账单分类待定", payment: SemanticPayment(amount: nil, isCertain: false, reason: "两个金额待选", candidates: [Decimal(string: "41.70")!, 45]), transactionDate: cautiousSummary.transactionDate)
        cautiousMoney.purposeSummary = cautiousSummary.purposeSummary
        let cautiousFields = cautiousMoney
        store.reset(); let bothID = store.queue(fixture)
        await store.recognizeExpense(id: bothID, url: fixture,
            recognizeLocally: { _ in preconditionFailure("No OCR fallback") },
            recognizeVisually: { id in store.startVisionAI(id, configuration: configuration, recognize: { _, _, _ in cautiousFields }) })
        await waitForAI(store)
        let candidate = store.amountCandidates[bothID]!.first!
        store.selectAmountCandidate(candidate, for: bothID)
        precondition(store.expenses[0].purpose == "某平台消费" && store.expenses[0].amount == Decimal(string: "41.70"))
        precondition(store.expenses[0].warning?.contains("用途待确认") == true && store.exportBlocker != nil, "Choosing money must not silently confirm the cautious purpose draft")
        store.confirmAll()
        precondition(store.exportBlocker == nil, "Explicit manual review can confirm the remaining purpose")

        store.reset()
        let failedID = store.queue(fixture)
        await store.recognizeExpense(id: failedID, url: fixture,
            recognizeLocally: { _ in preconditionFailure("AI failure must not fall back to local OCR") },
            recognizeVisually: { id in
                store.startVisionAI(id, configuration: configuration, recognize: { _, text, _ in
                    precondition(text.isEmpty)
                    throw URLError(.cannotConnectToHost)
                })
            })
        await waitForAI(store)
        precondition(store.expenses[0].amount == nil && store.expenses[0].date.isEmpty && store.expenses[0].purpose.isEmpty)
        precondition((store.recognizedTexts[failedID] ?? "").isEmpty && store.exportBlocker != nil)
        precondition(store.aiNotes[failedID]?.contains("未完成") == true)

        for (enabled, upload) in [(false, true), (true, false)] {
            store.reset(); mode(enabled: enabled, upload: upload)
            let localID = store.queue(fixture)
            await store.recognizeExpense(id: localID, url: fixture,
                recognizeLocally: { _ in recognizedLocal },
                recognizeVisually: { _ in preconditionFailure("Disabled AI or upload consent must use local recognition") })
            precondition(store.expenses[0].amount == 39 && store.expenses[0].date == "2026-10-01" && store.expenses[0].purpose == "本地餐食用途")
            precondition(store.recognizedTexts[localID] == "仅本地OCR文字" && !store.pendingIDs.contains(localID))
            precondition(store.automaticAIPlan(for: localID) == nil, "Complete local records don't need text AI")
            mode(enabled: true, upload: true)
            store.automaticallyAssistUnresolvedExpenses()
            precondition(store.aiPendingIDs.isEmpty, "Enabling visual mode must not upload completed local records")
        }

        store.reset(); mode(enabled: true, upload: false)
        let unresolvedID = store.queue(fixture)
        // Isolate eligibility without invoking the real text service or reading credentials.
        await store.recognizeExpense(id: unresolvedID, url: fixture,
            recognizeLocally: { _ in recognizedLocal },
            recognizeVisually: { _ in preconditionFailure("Default recognition cannot dispatch vision") })
        store.applySuggestion(Suggestion(amount: nil, category: .uncategorized, purpose: "", warning: "用途分类待确认", recognizedText: "付款完成，但金额和用途尚未确定"), to: unresolvedID)
        let textFallback = store.automaticAIPlan(for: unresolvedID)
        precondition(textFallback?.category == true && textFallback?.amount == true && textFallback?.date == true, "Visual off retains original local OCR plus text-AI fallback eligibility")
        precondition(store.visionAIPlan(for: unresolvedID) == nil && store.aiPendingIDs.isEmpty)

        store.reset(); mode(enabled: false, upload: false)
        let switchedID = store.queue(fixture)
        var switchedVisualCalls = 0
        let switched = Task {
            await store.recognizeExpense(id: switchedID, url: fixture,
                recognizeLocally: { _ in
                    try await Task.sleep(nanoseconds: 60_000_000)
                    return recognizedLocal
                },
                recognizeVisually: { id in
                    switchedVisualCalls += 1
                    store.startVisionAI(id, configuration: configuration, recognize: { _, text, _ in
                        precondition(text.isEmpty, "Local work completed after enabling AI must be discarded")
                        return recognizedVision
                    })
                })
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        mode(enabled: true, upload: true)
        await switched.value; await waitForAI(store)
        precondition(switchedVisualCalls == 1 && store.expenses[0].amount == 200 && store.expenses[0].purpose == "大力胶采购")
        precondition((store.recognizedTexts[switchedID] ?? "").isEmpty)

        store.reset()
        let editedID = store.queue(fixture)
        await store.recognizeExpense(id: editedID, url: fixture,
            recognizeLocally: { _ in preconditionFailure("AI-only manual-edit check cannot use OCR") },
            recognizeVisually: { id in
                store.startVisionAI(id, configuration: configuration, recognize: { _, text, _ in
                    precondition(text.isEmpty)
                    try await Task.sleep(nanoseconds: 40_000_000)
                    return recognizedVision
                })
            })
        store.markEdited(editedID, field: .amount); store.expenses[0].amount = 888
        store.markEdited(editedID, field: .date); store.expenses[0].date = "2025-09-24"
        store.markEdited(editedID, field: .purpose); store.expenses[0].purpose = "人工用途"
        await waitForAI(store)
        precondition(store.expenses[0].amount == 888 && store.expenses[0].date == "2025-09-24" && store.expenses[0].purpose == "人工用途", "Visual responses must preserve in-flight manual edits")
        print("Order recognition modes: AI-only, no local fallback, local mode, mode change and manual preservation passed (offline); fixture retained at \(fixture.path)")
    }
}
#endif
