#if DIRECT_TEST_RUNNER
import Foundation

@main struct OrderRecognitionModeCheck {
    @MainActor static func main() async throws {
        precondition(AppIdentity.isVisionTest)
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
        }

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
