#if DIRECT_TEST_RUNNER
import AppKit
import Foundation

private actor InvoiceAICounter {
    var calls = 0
    func increment() { calls += 1 }
}

@main struct InvoiceAIFallbackCheck {
    static func response(type: String = "digital_general", target: Bool? = true, certainty: String = "high", uncertainty: String = "") throws -> Data {
        let report: [String: Any] = ["document_type": type, "is_target_invoice": target.map { $0 as Any } ?? NSNull(),
            "certainty": certainty, "reason": "依据发票标题和票面信息判断", "uncertainty": uncertainty]
        let content = String(data: try JSONSerialization.data(withJSONObject: report), encoding: .utf8)!
        return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
    }

    @MainActor static func main() async throws {
        let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(previousArguments.merging(["reimbursement.ai.enabled": false, "reimbursement.ai.invoiceFallbackEnabled": false]) { _, test in test }, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        for kind in [InvoiceDocumentKind.invoice, .nonInvoice] {
            precondition(!InvoiceAIFallback.permits(local: kind, enabled: true, uploadAllowed: true))
            let unchanged = await InvoiceAIFallback.reviewIfNeeded(at: URL(fileURLWithPath: "/missing"), local: (kind, "本地确定"))
            precondition(unchanged.kind == kind && unchanged.reason == "本地确定")
        }
        precondition(!InvoiceAIFallback.permits(local: .unknown, enabled: false, uploadAllowed: true))
        precondition(!InvoiceAIFallback.permits(local: .unknown, enabled: true, uploadAllowed: false))
        precondition(InvoiceAIFallback.permits(local: .unknown, enabled: true, uploadAllowed: true))
        let configuration = try AIRequestConfiguration(endpoint: URL(string: "https://example.invalid/chat/completions")!, model: "test-vision", apiKey: "offline-dummy")
        let verified = InvoiceAIInput(text: "已验证的发票字段", images: [Data([1, 2])], verification: .invoice, verificationReason: "", verifiedType: .digitalGeneral)
        let missing = InvoiceAIInput(text: "缺字段", images: [Data([1, 2])], verification: .unknown, verificationReason: "缺购买方税号")
        let invoice = """
        电子发票（普通发票）
        发票号码：12345678901234567890
        开票日期：2026年10月27日
        购买方信息
        名称：北京测试有限公司
        纳税人识别号：91110108123456789X
        销售方信息
        名称：上海测试有限公司
        纳税人识别号：91310101123456789X
        不含税金额：36.79
        税额合计：2.21
        价税合计（小写）：39.00
        """
        precondition(InvoiceAIInput.verify(native: invoice, recognized: invoice, embedded: ([], nil), pageCount: 1).kind == .invoice)
        let changed = invoice.replacingOccurrences(of: "36.79", with: "35.79").replacingOccurrences(of: "2.21", with: "3.21")
        precondition(InvoiceAIInput.verify(native: invoice, recognized: changed, embedded: ([], nil), pageCount: 1).kind == .unknown, "Conflicting OCR cannot confirm an invoice")
        precondition(InvoiceAIInput.verify(native: invoice, recognized: invoice, embedded: ([changed], nil), pageCount: 1).kind == .unknown, "AI cannot bypass an embedded XML conflict")
        precondition(InvoiceAIInput.verify(native: invoice, recognized: invoice, embedded: ([], "内部结构冲突"), pageCount: 1).kind == .unknown)
        let special = "电子发票普通发票说明\n" + invoice.replacingOccurrences(of: "（普通发票）", with: "（增值税专用发票）")
        precondition(InvoiceAIInput.verify(native: special, recognized: "", embedded: ([], nil), pageCount: 1).type == .digitalSpecial, "Only the actual anchored invoice title determines type")
        let report = try InvoiceAIRequest.decode(response(), status: 200)
        precondition(InvoiceAIRequest.decision(report: report, input: verified).kind == .invoice)
        precondition(InvoiceAIRequest.decision(report: report, input: missing).kind == .unknown)
        let wrongType = try InvoiceAIRequest.decode(response(type: "digital_special"), status: 200)
        precondition(InvoiceAIRequest.decision(report: wrongType, input: verified).kind == .unknown, "AI and local invoice type must agree")
        let nonInvoice = try InvoiceAIRequest.decode(response(type: "itinerary", target: false), status: 200)
        precondition(InvoiceAIRequest.decision(report: nonInvoice, input: missing).kind == .nonInvoice)
        let conflictingInput = InvoiceAIInput(text: "存在冲突", images: [Data([1, 2])], verification: .unknown, verificationReason: "OCR矛盾", hasConflict: true)
        precondition(InvoiceAIRequest.decision(report: nonInvoice, input: conflictingInput).kind == .unknown, "Contradictions also block negative AI classification")

        precondition(InvoiceAIRequest.decision(report: nonInvoice, input: verified).kind == .unknown, "Conflicting local and AI decisions stay pending")
        let unsure = try InvoiceAIRequest.decode(response(type: "uncertain", target: nil, certainty: "uncertain", uncertainty: "票面模糊"), status: 200)
        precondition(InvoiceAIRequest.decision(report: unsure, input: verified).kind == .unknown)
        for bad in [try response(type: "itinerary", target: true), try response(target: true, uncertainty: "缺字段"), Data("bad JSON".utf8)] {
            do { _ = try InvoiceAIRequest.decode(bad, status: 200); preconditionFailure("Contradictory or malformed AI output cannot pass") } catch {}
        }
        do { _ = try InvoiceAIRequest.decode(response(), status: 429); preconditionFailure("HTTP errors stay pending") } catch {}
        let request = try InvoiceAIRequest.make(input: verified, configuration: configuration)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        let parts = messages[1]["content"] as! [[String: Any]]
        precondition((body["model"] as? String) == configuration.model && parts.count == 2)
        precondition((parts[1]["image_url"] as! [String: String])["url"]!.hasPrefix("data:image/jpeg;base64,"))
        precondition(request.url == configuration.endpoint && request.value(forHTTPHeaderField: "Authorization") == "Bearer offline-dummy")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-ai-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 600, height: 800))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 800).fill(); image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let file = root.appendingPathComponent("blank.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
        let counter = InvoiceAICounter()
        let answer = try response()
        let cache = root.appendingPathComponent("cache.json")
        let service = InvoiceAIService(cacheURL: cache) { _ in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(20))
            return (answer, 200)
        }
        async let first = service.review(at: file, configuration: configuration)
        async let second = service.review(at: file, configuration: configuration)
        let pair = await (first, second)
        precondition(pair.0.kind == .unknown && pair.1.kind == .unknown, "AI alone cannot confirm a blank invoice")
        let firstCalls = await counter.calls
        precondition(firstCalls == 1, "Concurrent identical files share one request; calls=\(firstCalls); result=\(pair.0.reason)")
        _ = await service.review(at: file, configuration: configuration)
        let renamed = root.appendingPathComponent("renamed.png")
        try FileManager.default.copyItem(at: file, to: renamed)
        _ = await service.review(at: renamed, configuration: configuration)
        let repeatedCalls = await counter.calls
        precondition(repeatedCalls == 1, "Repeated and renamed content must hit the cache")
        let restored = InvoiceAIService(cacheURL: cache) { _ in await counter.increment(); return (answer, 200) }
        _ = await restored.review(at: file, configuration: configuration)
        let restoredCalls = await counter.calls
        precondition(restoredCalls == 1, "Cache survives restart")
        let another = try AIRequestConfiguration(endpoint: configuration.endpoint, model: "other-vision", apiKey: configuration.apiKey)
        _ = await restored.review(at: file, configuration: another)
        let changedCalls = await counter.calls
        precondition(changedCalls == 2, "Changed models cannot reuse stale results")
        let denied = InvoiceAIService(cacheURL: root.appendingPathComponent("denied.json")) { _ in await counter.increment(); return (answer, 200) }
        _ = await denied.review(at: file, configuration: configuration, authorizeUpload: { false })
        let deniedCalls = await counter.calls
        precondition(deniedCalls == 2, "Revoked upload permission must prevent HTTP dispatch")
        _ = await denied.review(at: file, configuration: configuration)
        let allowedCalls = await counter.calls
        precondition(allowedCalls == 3, "A request never uploaded must not poison the cache")
        let failures = InvoiceAIService(cacheURL: root.appendingPathComponent("failures.json")) { _ in await counter.increment(); throw SemanticError.connection }
        let failure = await failures.review(at: file, configuration: configuration)
        _ = await failures.review(at: file, configuration: configuration)
        let failedCalls = await counter.calls
        precondition(failure.kind == .unknown && failedCalls == 4, "Failed requests are not automatically repeated during this run")
        let restoredFailure = InvoiceAIService(cacheURL: root.appendingPathComponent("failures.json")) { _ in await counter.increment(); return (answer, 200) }
        _ = await restoredFailure.review(at: file, configuration: configuration)
        let restoredFailureCalls = await counter.calls
        precondition(restoredFailureCalls == 4, "Failed calls are cached across restarts until explicitly cleared")
        let cancelledService = InvoiceAIService(cacheURL: root.appendingPathComponent("cancelled.json")) { _ in await counter.increment(); return (answer, 200) }
        let cancelled = Task { await cancelledService.review(at: file, configuration: configuration) }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        let cancelledCalls = await counter.calls
        precondition(cancelledResult.kind == .unknown && cancelledCalls == 4, "Cancellation before dispatch must not upload")
        let unsupported = root.appendingPathComponent("unknown.ofd")
        try Data("unsupported".utf8).write(to: unsupported)
        let skipped = await service.review(at: unsupported, configuration: configuration)
        let skippedCalls = await counter.calls
        precondition(skipped.kind == .unknown && skippedCalls == 4, "No reliable page preview means no upload")
        precondition(FileManager.default.fileExists(atPath: file.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600, "AI result cache must remain private to the current user")
        let stored = try String(contentsOf: cache, encoding: .utf8)
        precondition(!stored.contains("offline-dummy") && !stored.contains("data:image"), "Cache must not contain secrets or uploaded images")
        print("Invoice AI fallback checks passed: privacy gates, multimodal request, strict JSON, field verification, contradictions, persistent cache, deduplication, model changes, failures and unsupported files. Offline fixtures retained: \(root.path)")
    }
}
#endif
