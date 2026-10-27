import Foundation
import PDFKit
import Vision

public enum InvoiceDocumentKind: String, Codable, Sendable {
    case invoice, nonInvoice, unknown
}

// This identifies document types, not the tax authority's invoice authenticity result.
enum InvoiceDocumentClassifier {
    static let policyRevision = 2
    private static let supportingDocuments = [
        "电子客票", "行程单", "行程明细", "行程记录", "出行记录", "行程确认单", "报销单", "报销汇总", "报销明细",
        "费用明细", "费用清单", "发票清单", "发票汇总", "订单明细", "订单详情", "对账单", "付款凭证", "支付凭证",
        "itinerary", "expensereport", "invoicelist", "invoicesummary", "paymentreceipt"
    ]

    static func shouldList(filename: String, subject: String) -> Bool {
        let name = compact((filename as NSString).lastPathComponent)
        let suggestsInvoice = name.contains("发票") || name.contains("invoice") || name.hasPrefix("dzfp")
        // A bundle may contain both an invoice and supporting documents; inspect entries after explicit download.
        if (name as NSString).pathExtension == "zip", suggestsInvoice { return true }
        if supportingDocuments.contains(where: name.contains) { return false }
        return suggestsInvoice || compact(subject).contains("发票") || compact(subject).contains("invoice")
    }

    static func classify(at url: URL, text: String, filename: String) -> (kind: InvoiceDocumentKind, reason: String) {
        guard url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) else {
            return classify(text: text, filename: filename)
        }
        defer { withExtendedLifetime(document) {} }
        guard document.pageCount > 0 else { return (.nonInvoice, "PDF 没有可识别的票面。") }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { return (.nonInvoice, "PDF 页面无法读取。") }
            let result = classify(page: page, filename: filename)
            guard result.kind == .invoice else { return result }
        }
        return (.invoice, "所有页面均通过电子普通发票检查。")
    }

    private static func classify(page: PDFPage, filename: String) -> (kind: InvoiceDocumentKind, reason: String) {
        let direct = classify(text: page.string ?? "", filename: filename)
        guard direct.kind == .unknown,
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
            supportingDocuments.contains(where: line.contains)
        }
        if let supportingLine, invoiceLine == nil || supportingLine <= invoiceLine! {
            return (.nonInvoice, "票面标题为行程、报销或明细材料，不作为发票计入。")
        }
        let number = (source.contains("发票号码") || source.contains("发票号"))
            && has(#"(?<![0-9])[0-9]{8,20}(?![0-9])"#, normalized)
        let date = source.contains("开票日期") && has(#"(?:19|20)[0-9]{2}[年./-](?:0?[1-9]|1[0-2])[月./-](?:0?[1-9]|[12][0-9]|3[01])"#, source)
        let amount = source.contains("价税合计")
        let buyer = source.contains("购买方")
        let seller = source.contains("销售方")
        if invoiceLine != nil, number, date, amount, buyer, seller {
            return (.invoice, "已识别为电子普通发票，关键票面字段齐全。")
        }
        if invoiceLine == nil, ["非发票", "不作为发票", "不能作为发票"].contains(where: source.contains) {
            return (.nonInvoice, "文档明确注明非发票。")
        }
        return (.unknown, "未能自动确认是字段齐全的电子普通发票，已排除。")
    }

    private static func invoiceTitle(_ line: String) -> Bool {
        if ["说明", "申请", "清单", "汇总", "报销单", "报销明细", "操作指南"].contains(where: line.contains) { return false }
        return has(#"^(?:[\p{Han}]{0,12})?(?:增值税电子普通发票|电子发票[（(]?普通发票[）)]?)"#, line)
    }

    private static func compact(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased().filter { !$0.isWhitespace }
    }

    private static func has(_ pattern: String, _ value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
