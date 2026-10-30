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
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer offline-secret")
        precondition(!String(data: request.httpBody!, encoding: .utf8)!.contains("offline-secret"))
        let messages = body["messages"] as! [[String: Any]]
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
        let monthDay = try OrderVisionClassifier.decodeResponse(answer(date: "10-16"), statusCode: 200, referenceDate: reference)
        precondition(monthDay.transactionDate?.date == "2026-10-16" && monthDay.transactionDate?.reason.contains("2026") == true)
        let approximate = try OrderVisionClassifier.decodeResponse(answer(date: nil, dateCertainty: "uncertain", dates: ["10-16"]), statusCode: 200, referenceDate: reference)
        precondition(approximate.transactionDate?.candidates == ["2026-10-16"])
        let explicitYear = try OrderVisionClassifier.decodeResponse(answer(date: "2024-10-16"), statusCode: 200, referenceDate: reference)
        precondition(explicitYear.transactionDate?.date == "2024-10-16")
        try rejects { _ = try OrderVisionClassifier.decodeResponse(answer(amount: nil), statusCode: 200, referenceDate: reference) }
        try rejects { _ = try OrderVisionClassifier.decodeResponse(answer(category: "不支持分类"), statusCode: 200, referenceDate: reference) }
        try rejects { _ = try OrderVisionClassifier.decodeResponse(answer(date: "2026-02-30"), statusCode: 200, referenceDate: reference) }
        try rejects { _ = try OrderVisionClassifier.decodeResponse(answer(amount: "1e3"), statusCode: 200, referenceDate: reference) }
        try rejects { _ = try OrderVisionClassifier.decodeResponse(answer(candidates: Array(repeating: "39.50", count: 7)), statusCode: 200, referenceDate: reference) }
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
    static func rejects(_ work: () throws -> Void) throws { do { try work() } catch { return }; preconditionFailure("Expected invalid input to be rejected") }
    actor UploadAuthorization {
        var checks = 0
        func check() -> Bool { checks += 1; return checks == 1 }
    }
    actor MockSender {
        var count = 0; let response: Data
        init(response: Data) { self.response = response }
        func send(_ request: URLRequest) async throws -> (Data, Int) { count += 1; precondition(request.url?.host == "example.invalid"); return (response, 200) }
    }
}
#endif
