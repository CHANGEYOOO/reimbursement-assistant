#if DIRECT_TEST_RUNNER
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct OrderVisionCheck {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("order-vision-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("synthetic.png")
        try picture(width: 800, height: 1800).write(to: source)
        let configuration = try AIRequestConfiguration(endpoint: URL(string: "https://example.invalid/chat/completions")!, model: "vision-test", apiKey: "offline-secret")
        let reference = ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z")!
        let request = try OrderVisionClassifier.makeRequest(imageURL: source, text: "", configuration: configuration, referenceDate: reference)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(body["model"] as? String == "vision-test")
        precondition(body["max_tokens"] as? Int == 4096, "Visual output budget must fit the complete JSON")
        precondition(body["thinking"] == nil && body["enable_thinking"] == nil, "Generic compatible endpoints must not get provider-specific parameters")
        for model in ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"] {
            let deepSeek = try AIRequestConfiguration(endpoint: URL(string: "https://api.deepseek.com/chat/completions")!, model: model, apiKey: "offline-not-sent")
            let deepSeekRequest = try OrderVisionClassifier.makeRequest(imageURL: source, text: "", configuration: deepSeek)
            let deepSeekBody = try JSONSerialization.jsonObject(with: deepSeekRequest.httpBody!) as! [String: Any]
            precondition((deepSeekBody["thinking"] as? [String: String])?["type"] == "disabled")
            precondition(deepSeekBody["enable_thinking"] == nil, "DeepSeek must not receive Qwen's parameter")
        }
        let otherDeepSeekModel = try AIRequestConfiguration(endpoint: URL(string: "https://api.deepseek.com/chat/completions")!, model: "custom-model", apiKey: "offline-not-sent")
        let otherRequest = try OrderVisionClassifier.makeRequest(imageURL: source, text: "", configuration: otherDeepSeekModel)
        let otherBody = try JSONSerialization.jsonObject(with: otherRequest.httpBody!) as! [String: Any]
        precondition(otherBody["thinking"] == nil)

        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer offline-secret")
        precondition(!String(data: request.httpBody!, encoding: .utf8)!.contains("offline-secret"))
        let messages = body["messages"] as! [[String: Any]]
        let defaultInstruction = messages[0]["content"] as! String
        precondition(defaultInstruction.contains("公历年2026") && !defaultInstruction.contains("{{CURRENT_YEAR}}"))
        precondition(OrderVisionClassifier.defaultRules.contains("{{CURRENT_YEAR}}"))
        precondition(defaultInstruction.contains("每个reason不超过60字") && defaultInstruction.contains("evidence不超过80字"), "Fixed output instructions keep explanations short even for saved custom rules")
        let customRequest = try OrderVisionClassifier.makeRequest(imageURL: source, text: "", configuration: configuration, referenceDate: reference, rules: "用户业务规则：年份{{CURRENT_YEAR}}，用途保留商户名")
        let customBody = try JSONSerialization.jsonObject(with: customRequest.httpBody!) as! [String: Any]
        let customInstruction = ((customBody["messages"] as! [[String: Any]])[0]["content"] as! String)
        precondition(customInstruction.contains("用户业务规则：年份2026") && customInstruction.contains("固定输出协议") && customInstruction.contains("candidate_details") && customInstruction.contains("不可信数据"), "Custom business rules cannot remove the fixed response and untrusted-input protocol")
        precondition(!customInstruction.contains("先找实付、已支付、实际扣款"), "Custom rules replace the default business portion")
        try rejects { _ = try OrderVisionClassifier.makeRequest(imageURL: source, text: "", configuration: configuration, rules: "  \n ") }
        try rejects { _ = try OrderVisionClassifier.makeRequest(imageURL: source, text: "", configuration: configuration, rules: String(repeating: "长", count: 16_001)) }
        let content = messages[1]["content"] as! [[String: Any]]
        let images = content.filter { $0["type"] as? String == "image_url" }
        precondition(images.count == 1, "Empty OCR must still send a readable image")
        let jpeg = Data(base64Encoded: ((images[0]["image_url"] as! [String: String])["url"]!).components(separatedBy: ",").last!)!
        let imageSource = CGImageSourceCreateWithData(jpeg as CFData, nil)!
        precondition(CGImageSourceGetType(imageSource) as String? == UTType.jpeg.identifier)
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)! as NSDictionary
        precondition(properties[kCGImagePropertyTIFFDictionary] == nil && properties[kCGImagePropertyGPSDictionary] == nil, "Metadata must not be uploaded")
        let response = try answer()
        let result = try OrderVisionClassifier.decodeResponse(response, statusCode: 200, referenceDate: reference)
        precondition(result.category == .meals && result.isCertain)
        precondition(result.payment?.amount == Decimal(string: "39.50") && result.payment?.isCertain == true, "Visual amount need not occur in OCR")
        precondition(result.transactionDate?.date == "2026-10-16")
        let negative = try OrderVisionClassifier.decodeResponse(answer(amount: "-39.50"), statusCode: 200, referenceDate: reference)
        precondition(negative.payment?.amount == Decimal(string: "39.50"))
        let refund = try OrderVisionClassifier.decodeResponse(answer(direction: "refund"), statusCode: 200, referenceDate: reference)
        precondition(refund.payment?.amount == nil && refund.payment?.candidates.isEmpty == true && refund.payment?.isNonExpense == true)
        let ambiguous = try OrderVisionClassifier.decodeResponse(answer(amount: nil, paymentCertainty: "uncertain", candidates: ["39.50", "45.00"]), statusCode: 200, referenceDate: reference)
        precondition(ambiguous.payment?.amount == nil && ambiguous.payment?.candidates == [Decimal(string: "39.50")!, 45])
        let list = try OrderVisionClassifier.decodeResponse(decorated(response, page: "order_list", state: "paid"), statusCode: 200, referenceDate: reference)
        precondition(list.payment?.amount == nil && list.payment?.isCertain == false && list.payment?.candidates == [Decimal(string: "39.50")!], "Order list is never silently one confirmed expense")
        for state in ["partial_refund", "split_payment", "refund_processing", "unknown", "future_state"] {
            let complex = try OrderVisionClassifier.decodeResponse(decorated(response, page: "order_detail", state: state), statusCode: 200, referenceDate: reference)
            precondition(complex.payment?.amount == nil && complex.payment?.isCertain == false, "Complex/unknown payment states require choice: " + state)
        }
        let refundEntry = try OrderVisionClassifier.decodeResponse(decorated(response, page: "order_detail", state: "refund_entry", evidence: "页面下方退款按钮；上方实际支付39.50"), statusCode: 200, referenceDate: reference)
        precondition(refundEntry.payment?.amount == Decimal(string: "39.50") && refundEntry.payment?.isCertain == true, "Refund action button does not mean money refunded")
        let fullRefund = try OrderVisionClassifier.decodeResponse(decorated(response, page: "refund_detail", state: "full_refund"), statusCode: 200, referenceDate: reference)
        precondition(fullRefund.payment?.isNonExpense == true && fullRefund.payment?.amount == nil && fullRefund.payment?.candidates.isEmpty == true, "Full refund cannot retain a paid amount")
        let otherPage = try OrderVisionClassifier.decodeResponse(decorated(response, page: "unrecognized_page", state: "paid"), statusCode: 200, referenceDate: reference)
        precondition(otherPage.payment?.amount == nil && otherPage.category == .meals && otherPage.transactionDate?.date != nil, "Unknown page holds money without losing unrelated fields")
        let explained = try OrderVisionClassifier.decodeResponse(decorated(answer(amount: nil, paymentCertainty: "uncertain", candidates: ["39.50", "45.00"]), page: "payment_detail", state: "paid", evidence: "支付标签对应39.50，45.00是订单合计", details: [["amount":"39.50","label":"实付候选"],["amount":"45.00","label":"订单合计"]]), statusCode: 200, referenceDate: reference)
        precondition(explained.payment?.candidateSources[Decimal(string: "39.50")!] == "实付候选" && explained.visionSummary?.contains("支付详情") == true && explained.visionSummary?.contains("支付标签") == true)
        let invalidDetail = try OrderVisionClassifier.decodeResponse(decorated(response, page: "payment_detail", state: "paid", details: [["amount":"999.00","label":"不属于候选"]]), statusCode: 200, referenceDate: reference)
        precondition(invalidDetail.payment?.amount == Decimal(string: "39.50") && invalidDetail.validationIssues.contains(where: { $0.contains("候选说明") }), "Invalid optional explanation cannot discard a valid amount")
        let merchantPurpose = try OrderVisionClassifier.decodeResponse(decorated(response, purpose: ["text":"便利店消费","certainty":"high","source":"merchant","reason":"无商品明细，按店名概括"]), statusCode: 200, referenceDate: reference)
        precondition(merchantPurpose.purposeSummary?.text == "便利店消费" && merchantPurpose.purposeSummary?.isCertain == true)
        let remarkPurpose = try OrderVisionClassifier.decodeResponse(decorated(response, purpose: ["text":"拍摄场地租赁","certainty":"high","source":"remark","reason":"转账备注明确写明场地租赁"]), statusCode: 200, referenceDate: reference)
        precondition(remarkPurpose.purposeSummary?.source == "remark")
        let unknownPurpose = try OrderVisionClassifier.decodeResponse(decorated(response, purpose: ["text":"商户消费","certainty":"uncertain","source":"unknown","reason":"仅有模糊商户名"]), statusCode: 200, referenceDate: reference)
        precondition(unknownPurpose.purposeSummary?.isCertain == false && result.purposeSummary == nil, "Unknown purpose not auto-filled; old payload remains compatible")
        for invalidPurpose in [
            ["text":"","certainty":"high","source":"merchant","reason":"没有内容"],
            ["text":"猜测用途","certainty":"high","source":"unknown","reason":"无法判断"],
            ["text":String(repeating:"长",count:41),"certainty":"high","source":"items","reason":"过长"]
        ] {
            let independent = try OrderVisionClassifier.decodeResponse(decorated(response, purpose: invalidPurpose), statusCode: 200, referenceDate: reference)
            precondition(independent.purposeSummary == nil && independent.purposeValidationFailed && independent.payment?.isCertain == true && independent.transactionDate?.date != nil && independent.validationIssues.contains(where: { $0.hasPrefix("用途：") }), "Bad purpose cannot discard payment/date")
        }
        let nullPurpose = try OrderVisionClassifier.decodeResponse(edited(response) { $0["purpose"] = NSNull() }, statusCode: 200, referenceDate: reference)
        precondition(nullPurpose.purposeValidationFailed && nullPurpose.purposeSummary == nil && nullPurpose.payment?.isCertain == true, "Explicit null purpose is invalid; only missing legacy purpose permits compatibility fallback")
        let monthDay = try OrderVisionClassifier.decodeResponse(answer(date: "10-16"), statusCode: 200, referenceDate: reference)
        precondition(monthDay.transactionDate?.date == "2026-10-16" && monthDay.transactionDate?.reason.contains("2026") == true)
        let approximate = try OrderVisionClassifier.decodeResponse(answer(date: nil, dateCertainty: "uncertain", dates: ["10-16"]), statusCode: 200, referenceDate: reference)
        precondition(approximate.transactionDate?.candidates == ["2026-10-16"])
        let explicitYear = try OrderVisionClassifier.decodeResponse(answer(date: "2024-10-16"), statusCode: 200, referenceDate: reference)
        precondition(explicitYear.transactionDate?.date == "2024-10-16")
        let noSupplement = try OrderVisionClassifier.decodeResponse(answer(date: "10-16"), statusCode: 200, referenceDate: reference, allowYearSupplement: false)
        precondition(noSupplement.transactionDate == nil && noSupplement.payment?.isCertain == true && noSupplement.validationIssues.contains(where: { $0.contains("不允许自动补充年份") }))
        let completeWithoutSupplement = try OrderVisionClassifier.decodeResponse(answer(date: "2024-10-16"), statusCode: 200, referenceDate: reference, allowYearSupplement: false)
        precondition(completeWithoutSupplement.transactionDate?.date == "2024-10-16")
        let invalidMetadata = try OrderVisionClassifier.decodeResponse(edited(response) { report in
            var payment = report["payment"] as! [String:Any]
            payment["candidate_details"] = "不是候选说明列表"; payment["evidence"] = 42
            report["payment"] = payment
        }, statusCode: 200, referenceDate: reference)
        precondition(invalidMetadata.payment?.amount == Decimal(string: "39.50") && invalidMetadata.payment?.isCertain == true && invalidMetadata.validationIssues.count == 2, "Malformed optional explanations cannot discard core fields")
        let longEvidence = try OrderVisionClassifier.decodeResponse(decorated(response, evidence: String(repeating: "长", count: 201)), statusCode: 200, referenceDate: reference)
        precondition(longEvidence.payment?.isCertain == true && longEvidence.validationIssues.contains(where: { $0.contains("说明过长") }))
        for badMoney in [try answer(amount: nil), try answer(amount: "1e3"), try answer(candidates: Array(repeating: "39.50", count: 7))] {
            let independent = try OrderVisionClassifier.decodeResponse(badMoney, statusCode: 200, referenceDate: reference)
            precondition(independent.payment == nil && independent.transactionDate?.date == "2026-10-16" && independent.isCertain && independent.validationIssues.contains(where: { $0.hasPrefix("金额：") }), "Bad payment cannot discard other fields")
        }
        let badCategory = try OrderVisionClassifier.decodeResponse(answer(category: "不支持分类"), statusCode: 200, referenceDate: reference)
        precondition(badCategory.categoryValidationFailed && badCategory.payment?.isCertain == true && badCategory.transactionDate?.date != nil)
        let badDate = try OrderVisionClassifier.decodeResponse(answer(date: "2026-02-30"), statusCode: 200, referenceDate: reference)
        precondition(badDate.transactionDate == nil && badDate.payment?.isCertain == true && badDate.validationIssues.contains(where: { $0.hasPrefix("日期：") }))
        let conflictingMoney = try OrderVisionClassifier.decodeResponse(answer(candidates: ["45.00"]), statusCode: 200, referenceDate: reference)
        precondition(conflictingMoney.payment?.isCertain == false && conflictingMoney.payment?.amount == nil && conflictingMoney.payment?.candidates == [Decimal(string:"39.50")!,45] && conflictingMoney.validationIssues.contains(where: { $0.contains("不一致") }))
        let conflictingDate = try OrderVisionClassifier.decodeResponse(answer(dates: ["2026-10-17"]), statusCode: 200, referenceDate: reference)
        precondition(conflictingDate.transactionDate == nil && conflictingDate.payment?.isCertain == true && conflictingDate.validationIssues.contains(where: { $0.contains("确定日期与候选日期不一致") }), "Conflicting date must not become an auto-filled approximate date")
        let numeric = try OrderVisionClassifier.decodeResponse(edited(response) { report in
            var payment = report["payment"] as! [String:Any]
            payment["amount"] = -39.5
            payment.removeValue(forKey: "candidates")
            report["payment"] = payment
            var date = report["transaction_date"] as! [String:Any]
            date["candidates"] = NSNull(); report["transaction_date"] = date
        }, statusCode: 200, referenceDate: reference)
        precondition(numeric.payment?.amount == Decimal(string:"39.50") && numeric.transactionDate?.date == "2026-10-16" && numeric.validationIssues.isEmpty, "Numeric amounts and absent/null candidates are valid")
        let malformedAmount = try OrderVisionClassifier.decodeResponse(edited(decorated(response, purpose: ["text":"停车费","certainty":"high","source":"items","reason":"停车服务"])) { report in
            var payment = report["payment"] as! [String:Any]; payment["amount"] = true; report["payment"] = payment
        }, statusCode: 200, referenceDate: reference)
        precondition(malformedAmount.payment == nil && malformedAmount.purposeSummary?.text == "停车费" && malformedAmount.transactionDate?.date != nil, "Malformed numeric field doesn't affect purpose/date")
        let missing = try OrderVisionClassifier.decodeResponse(edited(response) { $0.removeValue(forKey: "payment") }, statusCode: 200, referenceDate: reference)
        precondition(missing.payment == nil && missing.transactionDate?.date != nil && missing.validationIssues.contains(where: { $0.contains("AI 未返回") }))
        let wrongTypePurpose = try OrderVisionClassifier.decodeResponse(edited(response) { $0["purpose"] = ["text":42] }, statusCode: 200, referenceDate: reference)
        precondition(wrongTypePurpose.purposeValidationFailed && wrongTypePurpose.payment?.isCertain == true && wrongTypePurpose.transactionDate?.date != nil)
        try rejects { _ = try OrderVisionClassifier.decodeResponse(answer(finish: "length"), statusCode: 200, referenceDate: reference) }
        try rejects { _ = try OrderVisionClassifier.decodeResponse(answer(choiceCount: 2), statusCode: 200, referenceDate: reference) }
        try rejects { _ = try OrderVisionClassifier.decodeResponse(response, statusCode: 401, referenceDate: reference) }
        let longImage = folder.appendingPathComponent("long.png")
        try picture(width: 600, height: 10000).write(to: longImage)
        let longRequest = try OrderVisionClassifier.makeRequest(imageURL: longImage, text: "本地识别文字", configuration: configuration, referenceDate: reference)
        let longBody = try JSONSerialization.jsonObject(with: longRequest.httpBody!) as! [String: Any]
        let longContent = ((longBody["messages"] as! [[String: Any]])[1]["content"] as! [[String: Any]])
        let segments = longContent.filter { $0["type"] as? String == "image_url" }
        precondition(segments.count == 3, "Long screenshot is sent completely in ordered sections")
        var heights = 0, totalBytes = 0
        for segment in segments {
            let bytes = Data(base64Encoded: ((segment["image_url"] as! [String: String])["url"]!).components(separatedBy: ",").last!)!
            totalBytes += bytes.count
            let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(bytes as CFData, nil)!, 0, nil)!
            precondition(image.width == 600 && image.height <= 4000)
            heights += image.height
        }
        precondition(heights == 10000 && totalBytes <= 2 * 1024 * 1024)
        let tooLong = folder.appendingPathComponent("too-long.png")
        try picture(width: 400, height: 17000).write(to: tooLong)
        try rejects { _ = try OrderVisionClassifier.makeRequest(imageURL: tooLong, text: "", configuration: configuration) }
        let invalid = folder.appendingPathComponent("invalid.png"); try Data("not an image".utf8).write(to: invalid)
        try rejects { _ = try OrderVisionClassifier.makeRequest(imageURL: invalid, text: "", configuration: configuration) }
        let mock = MockSender(response: response)
        let classified = try await OrderVisionClassifier.classify(imageURL: source, text: "", configuration: configuration, referenceDate: reference, sender: mock.send)
        precondition(classified.payment?.amount == Decimal(string: "39.50"))
        for failure in [(try answer(finish: "length"), 200, false), (response, 429, false), (response, 200, true)] {
            let once = MockSender(response: failure.0, status: failure.1, networkFailure: failure.2)
            do {
                _ = try await OrderVisionClassifier.classify(imageURL: source, text: "", configuration: configuration, sender: once.send)
                preconditionFailure("Expected failure")
            } catch {
                if failure.1 == 200 && !failure.2 { precondition(error.localizedDescription.contains("不会自动重试")) }
            }
            let attempts = await once.count
            precondition(attempts == 1, "Truncation, HTTP and network failure must never retry automatically")
        }
        let count = await mock.count; precondition(count == 1)
        do {
            _ = try await OrderVisionClassifier.classify(imageURL: source, text: "", configuration: configuration, sender: mock.send, authorized: { false })
            preconditionFailure("Revoked upload authorization must stop request")
        } catch is CancellationError {}
        let afterRevocation = await mock.count; precondition(afterRevocation == 1)
        let authorization = UploadAuthorization()
        do {
            _ = try await OrderVisionClassifier.classify(imageURL: source, text: "", configuration: configuration, sender: mock.send, authorized: { await authorization.check() })
            preconditionFailure("Authorization revoked during image preparation must stop request")
        } catch is CancellationError {}
        let afterPreparation = await mock.count; precondition(afterPreparation == 1)
        print("Order vision request, image bounds/metadata, structured decisions and mock HTTP checks passed; fixtures retained at \(folder.path)")
    }

    static func picture(width: Int, height: Int) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let result = NSMutableData(); let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Private synthetic metadata"], kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12]] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination)); return result as Data
    }
    static func answer(category: String = "餐食", amount: String? = "39.50", paymentCertainty: String = "high", direction: String = "expense", candidates: [String] = [], date: String? = "2026-10-16", dateCertainty: String = "high", dates: [String] = [], finish: String = "stop", choiceCount: Int = 1) throws -> Data {
        let object: [String: Any] = ["category": category, "certainty": "high", "reason": "商品为食物", "payment": ["amount": amount as Any? ?? NSNull(), "certainty": paymentCertainty, "direction": direction, "reason": "页面实付金额", "candidates": candidates], "transaction_date": ["date": date as Any? ?? NSNull(), "certainty": dateCertainty, "reason": "页面支付日期", "candidates": dates]]
        let content = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        return try JSONSerialization.data(withJSONObject: ["choices": Array(repeating: ["message": ["content": content], "finish_reason": finish] as [String: Any], count: choiceCount)])
    }
    static func decorated(_ data: Data, page: String? = nil, state: String? = nil, evidence: String? = nil,
                          details: [[String:String]]? = nil, purpose: [String:String]? = nil) throws -> Data {
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String:Any]
        var choices = envelope["choices"] as! [[String:Any]]
        var message = choices[0]["message"] as! [String:Any]
        var report = try JSONSerialization.jsonObject(with: Data((message["content"] as! String).utf8)) as! [String:Any]
        var payment = report["payment"] as! [String:Any]
        if let page { report["page_type"] = page }
        if let state { payment["state"] = state }
        if let evidence { payment["evidence"] = evidence }
        if let details { payment["candidate_details"] = details }
        if let purpose { report["purpose"] = purpose }
        report["payment"] = payment
        message["content"] = String(data: try JSONSerialization.data(withJSONObject: report), encoding: .utf8)!
        choices[0]["message"] = message; envelope["choices"] = choices
        return try JSONSerialization.data(withJSONObject: envelope)
    }
    static func edited(_ data: Data, change: (inout [String:Any]) -> Void) throws -> Data {
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String:Any]
        var choices = envelope["choices"] as! [[String:Any]]
        var message = choices[0]["message"] as! [String:Any]
        var report = try JSONSerialization.jsonObject(with: Data((message["content"] as! String).utf8)) as! [String:Any]
        change(&report)
        message["content"] = String(data: try JSONSerialization.data(withJSONObject: report), encoding: .utf8)!
        choices[0]["message"] = message; envelope["choices"] = choices
        return try JSONSerialization.data(withJSONObject: envelope)
    }
    static func rejects(_ work: () throws -> Void) throws { do { try work() } catch { return }; preconditionFailure("Expected invalid input to be rejected") }
    actor UploadAuthorization {
        var checks = 0
        func check() -> Bool { checks += 1; return checks == 1 }
    }
    actor MockSender {
        var count = 0; let response: Data; let status: Int; let networkFailure: Bool
        init(response: Data, status: Int = 200, networkFailure: Bool = false) {
            self.response = response; self.status = status; self.networkFailure = networkFailure
        }
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            count += 1; precondition(request.url?.host == "example.invalid")
            if networkFailure { throw URLError(.cannotConnectToHost) }
            return (response, status)
        }
    }
}
#endif
