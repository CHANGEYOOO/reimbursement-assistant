import Foundation
import PDFKit
import Vision

public enum InvoiceDocumentKind: String, Codable, Sendable {
    case invoice, nonInvoice, unknown
}

// This identifies document types, not the tax authority's invoice authenticity result.
enum InvoiceDocumentClassifier {
    private static let supportingDocuments = [
        "行程单", "行程明细", "行程记录", "出行记录", "行程确认单", "报销单", "报销汇总", "报销明细",
        "费用明细", "费用清单", "发票清单", "发票汇总", "订单明细", "订单详情", "对账单", "付款凭证", "支付凭证",
        "itinerary", "expensereport", "invoicelist", "invoicesummary", "paymentreceipt"
    ]

    static func shouldList(filename: String, subject: String) -> Bool {
        let name = compact((filename as NSString).lastPathComponent)
        if formalTransport(name) { return true }
        let suggestsInvoice = name.contains("发票") || name.contains("invoice") || name.hasPrefix("dzfp")
        // A bundle may contain both an invoice and supporting documents; inspect entries after explicit download.
        if (name as NSString).pathExtension == "zip", suggestsInvoice { return true }
        if supportingDocuments.contains(where: name.contains) { return false }
        return suggestsInvoice || compact(subject).contains("发票") || compact(subject).contains("invoice")
    }

    static func classify(at url: URL, text: String, filename: String) -> (kind: InvoiceDocumentKind, reason: String) {
        let direct = classify(text: text, filename: filename)
        guard direct.kind == .unknown, url.pathExtension.lowercased() == "pdf",
              let document = PDFDocument(url: url) else { return direct }
        defer { withExtendedLifetime(document) {} }
        guard let page = document.page(at: 0),
              let image = page.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return direct }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            return classify(text: recognized, filename: filename)
        } catch { return direct }
    }

    static func classify(text: String, filename: String) -> (kind: InvoiceDocumentKind, reason: String) {
        let normalized = text.precomposedStringWithCompatibilityMapping
        let lines = normalized.components(separatedBy: .newlines).map(compact).filter { !$0.isEmpty }
        let source = compact(normalized)
        guard !source.isEmpty else { return (.unknown, "尚未取得可识别的票面内容。") }

        let head = Array(lines.prefix(12))
        let invoiceLine = head.firstIndex(where: invoiceTitle)
        let supportingLine = head.firstIndex { line in
            !formalTransport(line) && supportingDocuments.contains(where: line.contains)
        }
        if let supportingLine, invoiceLine == nil || supportingLine <= invoiceLine! {
            return (.nonInvoice, "票面标题为行程、报销或明细材料，不作为发票计入。")
        }
        let number = ((source.contains("发票号码") || source.contains("发票号")) && has(#"(?<![0-9])[0-9]{8,20}(?![0-9])"#, normalized))
            || (formalTransport(source) && has(#"(?:电子客票号码|票证号码)[:：]?[0-9]{10,20}(?![0-9])"#, source))
        let date = source.contains("开票日期") && has(#"(?:19|20)[0-9]{2}[年./-](?:0?[1-9]|1[0-2])[月./-](?:0?[1-9]|[12][0-9]|3[01])"#, source)
        let amount = ["价税合计", "合计金额", "发票金额"].contains(where: source.contains)
            || (formalTransport(source) && ["票价", "票款合计", "合计"].contains(where: source.contains))
        let buyer = source.contains("购买方") || source.contains("付款方")
        let seller = source.contains("销售方") || source.contains("收款方")
        let taxNumber = source.contains("纳税人识别号") || source.contains("统一社会信用代码")
        let supportingFields = [amount, buyer, seller, taxNumber].filter { $0 }.count
        if invoiceLine != nil, number, date, supportingFields >= 1, amount || supportingFields >= 2 {
            return (.invoice, "票面包含发票标题、号码、日期及金额或购销方等信息。")
        }
        if invoiceLine == nil, ["非发票", "不作为发票", "不能作为发票"].contains(where: source.contains) {
            return (.nonInvoice, "文档明确注明非发票。")
        }
        return (.unknown, "未找到足够的发票票面信息，请人工确认附件类型。")
    }

    private static func invoiceTitle(_ line: String) -> Bool {
        if ["说明", "申请", "清单", "汇总", "报销单", "报销明细", "操作指南"].contains(where: line.contains) { return false }
        if formalTransport(line) { return true }
        return has(#"^(?:[\p{Han}]{0,12})?(?:增值税(?:电子)?(?:普通|专用)?发票|电子发票)"#, line)
    }

    private static func formalTransport(_ value: String) -> Bool {
        value.contains("航空运输电子客票行程单") || value.contains("铁路电子客票")
    }

    private static func compact(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased().filter { !$0.isWhitespace }
    }

    private static func has(_ pattern: String, _ value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
