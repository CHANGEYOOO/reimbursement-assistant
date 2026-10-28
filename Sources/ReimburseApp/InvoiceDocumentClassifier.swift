import Foundation
import PDFKit
import ImageIO
import Vision

public enum InvoiceDocumentKind: String, Codable, Sendable {
    case invoice, nonInvoice, unknown
}

// Document screening only; this does not establish tax-authority authenticity.
enum InvoiceDocumentClassifier {
    static let policyRevision = 4
    static let verificationRevision = 3
    static let supportedExtensions: Set<String> = ["pdf", "ofd", "xml", "png", "jpg", "jpeg", "heic", "heif"]
    private static let supportingDocuments = [
        "电子客票", "行程单", "行程明细", "行程记录", "出行记录", "行程确认单", "报销单", "报销汇总", "报销明细",
        "住宿明细", "住宿清单", "消费明细", "消费清单", "费用明细", "费用清单", "发票清单", "发票汇总",
        "订单明细", "订单详情", "对账单", "付款凭证", "支付凭证", "itinerary", "paymentreceipt"
    ]

    static func shouldList(filename: String, subject: String) -> Bool {
        // Mail names and subjects only select candidates; file content decides acceptance.
        let name = filename.lowercased()
        let hint = name.contains("发票") || name.contains("invoice") || name.hasPrefix("dzfp") || subject.lowercased().contains("发票") || subject.lowercased().contains("invoice")
        return hint && supportedExtensions.union(["zip"]).contains((filename as NSString).pathExtension.lowercased())
    }

    static func classify(at url: URL, text: String, filename: String) -> (kind: InvoiceDocumentKind, reason: String) {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: url), !document.isEncrypted, !document.isLocked,
                  document.pageCount > 0, document.pageCount <= 100 else { return (.unknown, "PDF 加密或无法读取，保留待确认。") }
            var results: [(kind: InvoiceDocumentKind, reason: String)] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { return (.unknown, "PDF页面无法读取。") }
                let direct = classify(text: page.string ?? "", filename: filename)
                if direct.kind != .unknown { results.append(direct); continue }
                guard let image = page.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) else { results.append(direct); continue }
                results.append(classify(text: recognizedText(image), filename: filename))
            }
            if results.allSatisfy({ $0.kind == .invoice }) { return (.invoice, "已按恢复的本地规则识别为电子发票。") }
            if results.allSatisfy({ $0.kind == .nonInvoice }) { return (.nonInvoice, results[0].reason) }
            return (.unknown, "PDF仍有无法确定或混合类型的页面：" + results.filter { $0.kind != .invoice }.map(\.reason).joined(separator: "；"))
        }
        if ["png", "jpg", "jpeg", "heic", "heif"].contains(ext),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return classify(text: recognizedText(image), filename: filename)
        }
        let content = LocalInvoiceContent.read(at: url)
        if let reason = content.reason { return (.unknown, reason) }
        return verify(text: content.text, filename: filename)
    }

    private static func recognizedText(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        } catch { return "" }
    }

    static func classify(text: String, filename: String) -> (kind: InvoiceDocumentKind, reason: String) {
        let normalized = text.precomposedStringWithCompatibilityMapping
        let lines = normalized.components(separatedBy: .newlines).map(compact).filter { !$0.isEmpty }
        let source = compact(normalized)
        guard !source.isEmpty else { return (.unknown, "尚未取得可识别的票面内容。") }

        let head = Array(lines.prefix(12))
        let invoiceLine = head.firstIndex(where: establishedInvoiceTitle)
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
        let extended = verify(text: text, filename: filename)
        return extended.kind == .invoice ? extended : (.unknown, "本地仍无法确认电子发票，等待AI兜底或人工确认。")
    }

    private static func establishedInvoiceTitle(_ line: String) -> Bool {
        if ["说明", "申请", "清单", "汇总", "报销单", "报销明细", "操作指南"].contains(where: line.contains) { return false }
        return has(#"^(?:[\p{Han}]{0,12})?(?:增值税电子普通发票|电子发票[（(]?普通发票[）)]?)"#, line)
    }

    private static func has(_ pattern: String, _ value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    static func verify(text: String, filename: String) -> (kind: InvoiceDocumentKind, reason: String) {
        let lines = text.precomposedStringWithCompatibilityMapping.components(separatedBy: .newlines).map(compact).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return (.unknown, "未取得可验证的文件内部文本。") }
        let titles = Array(lines.prefix(12))
        if let first = titles.firstIndex(where: { line in supportingDocuments.contains(where: line.contains) }),
           titles.firstIndex(where: invoiceTitle).map({ first <= $0 }) ?? true {
            return (.nonInvoice, "文档标题为行程单、客票、明细单或支付凭证，属于非目标附件。")
        }
        guard let title = titles.first(where: invoiceTitle) else {
            if lines.prefix(12).contains(where: { $0.contains("非发票") || $0.contains("不能作为发票") }) {
                return (.nonInvoice, "文档明确注明非发票。")
            }
            return (.unknown, "未找到白名单内的正式电子发票标题。")
        }
        let titleKinds = Set(titles.filter(invoiceTitle).map { $0.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "") })
        guard titleKinds.count == 1 else { return (.unknown, "出现多个不一致的发票票种标题。") }
        let digital = title.hasPrefix("电子发票")
        var missing: [String] = []
        let number = field("(?:发票号码|发票号)", lines: lines, value: digital ? #"[0-9]{20}"# : #"[0-9]{8}"#)
        if number == nil { missing.append(digital ? "20位发票号码" : "8位发票号码") }
        if !digital && field("发票代码", lines: lines, value: #"(?:[0-9]{12}|[0-9]{10})"#) == nil { missing.append("发票代码") }
        if let date = field("开票日期", lines: lines, value: #"[0-9]{4}[年./-][0-9]{1,2}[月./-][0-9]{1,2}日?"#) {
            if !validDate(date) { missing.append("有效开票日期") }
        } else { missing.append("开票日期") }
        let source = lines.joined(separator: "\n")
        for party in ["购买方", "销售方"] {
            guard let start = source.range(of: party) else { missing.append(party + "信息"); continue }
            let tail = String(source[start.upperBound...])
            let other = party == "购买方" ? "销售方" : "购买方"
            let block = String(tail.prefix(700).components(separatedBy: other)[0])
            let partyLines = block.components(separatedBy: .newlines)
            let name = field("(?:信息)?(?:名称|单位名称)", lines: partyLines, value: #"[\p{Han}A-Za-z][\p{Han}A-Za-z0-9()·&]{1,99}"#)
            let taxID = field("(?:统一社会信用代码/纳税人识别号|纳税人识别号|统一社会信用代码)", lines: partyLines, value: #"[0-9A-Z]{15}(?:[0-9A-Z]{3})?"#)
            if name == nil { missing.append(party + "名称") }
            if taxID == nil { missing.append(party + "税号") }
        }
        let amounts = totals(lines)
        let total = amounts.total, net = amounts.net, tax = amounts.tax
        if total == nil { missing.append("价税合计数值") }
        if net == nil { missing.append("不含税合计数值") }
        if tax == nil { missing.append("税额合计数值") }
        guard missing.isEmpty, let total, let net, let tax else { return (.unknown, "关键字段缺失或无法绑定：" + missing.joined(separator: "、") + "。") }
        guard total != 0, abs(total - net - tax) <= Decimal(string: "0.02")!,
              (total > 0 && net >= 0 && tax >= 0) || (total < 0 && net <= 0 && tax <= 0) else {
            return (.unknown, "价税合计与不含税金额、税额不一致，或金额符号不一致。")
        }
        return (.invoice, "白名单票种：\(title)；号码、开票日期、双方名称税号齐全；不含税金额＋税额＝价税合计（允许0.02元舍入差）。")
    }

    private static func totals(_ lines: [String]) -> (total: Decimal?, net: Decimal?, tax: Decimal?) {
        for label in ["(?:不含税金额|金额合计|合计金额|税前金额)", "(?:税额合计|合计税额)"] {
            guard fieldValues(label, lines: lines, value: moneyValue).count <= 1 else { return (nil, nil, nil) }
        }
        let total = decimalField("价税合计(?:(?:\\(大写\\)|大写)[^0-9\\n¥￥-]{0,40})?(?:\\(小写\\)|小写)?", lines: lines)
        var net = decimalField("(?:不含税金额|金额合计|合计金额|税前金额)", lines: lines)
        var tax = decimalField("(?:税额合计|合计税额)", lines: lines)
        for sumLine in lines where sumLine.hasPrefix("合计") && !sumLine.hasPrefix("合计金额") && !sumLine.hasPrefix("合计税额") {
            let amounts = decimalValues(String(sumLine.dropFirst(2)))
            if amounts.count == 2 {
                if let net, net != amounts[0] { return (total, nil, nil) }
                if let tax, tax != amounts[1] { return (total, nil, nil) }
                net = amounts[0]; tax = amounts[1]
            }
        }
        if tax == nil && lines.contains(where: { $0 == "税额合计:免税" || $0 == "税额合计:不征税" || $0 == "合计税额:免税" }) { tax = .zero }
        return (total, net, tax)
    }

    static func targetType(in text: String) -> String? {
        let titles = text.components(separatedBy: .newlines).map(compact).filter(invoiceTitle)
        guard let title = titles.first else { return nil }
        let types = Set(titles.map { title in
            (title.hasPrefix("电子发票") ? "digital_" : "vat_electronic_") + (title.contains("普通发票") ? "general" : "special")
        })
        guard types.count == 1 else { return nil }
        return (title.hasPrefix("电子发票") ? "digital_" : "vat_electronic_") + (title.contains("普通发票") ? "general" : "special")
    }
    static func fieldsAgree(_ first: String, _ second: String) -> Bool {
        verify(text: first, filename: "").kind == .invoice && verify(text: second, filename: "").kind == .invoice && identity(first) == identity(second)
    }

    private static func identity(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines).map(compact).filter { !$0.isEmpty }
        let source = lines.joined(separator: "\n")
        var values = [targetType(in: text) ?? "", field("(?:发票号码|发票号)", lines: lines, value: #"(?:[0-9]{20}|[0-9]{8})"#) ?? "",
                      field("发票代码", lines: lines, value: #"(?:[0-9]{12}|[0-9]{10})"#) ?? ""]
        let date = field("开票日期", lines: lines, value: #"[0-9]{4}[年./-][0-9]{1,2}[月./-][0-9]{1,2}日?"#) ?? ""
        values.append(date.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.map(String.init).joined(separator: "-"))
        let amounts = totals(lines)
        for value in [amounts.total, amounts.net, amounts.tax] {
            values.append(value.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
        }
        for party in ["购买方", "销售方"] {
            guard let range = source.range(of: party) else { values.append(""); continue }
            let block = String(source[range.upperBound...]).components(separatedBy: party == "购买方" ? "销售方" : "购买方")[0].components(separatedBy: .newlines)
            values.append(field("(?:信息)?(?:名称|单位名称)", lines: block, value: #"[\p{Han}A-Za-z][\p{Han}A-Za-z0-9()·&]{1,99}"#) ?? "")
            values.append(field("(?:统一社会信用代码/纳税人识别号|纳税人识别号|统一社会信用代码)", lines: block, value: #"[0-9A-Z]{15}(?:[0-9A-Z]{3})?"#) ?? "")
        }
        return values
    }

    private static func invoiceTitle(_ value: String) -> Bool {
        let title = value.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        return title.range(of: #"^(?:电子发票(?:普通发票|增值税专用发票|专用发票)|[\p{Han}]{0,12}增值税电子(?:普通|专用)发票)$"#, options: .regularExpression) != nil
    }
    private static func compact(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: #"(?<=\.[0-9]{2})[ \t]+(?=[¥￥-]?[0-9])"#, with: "|", options: .regularExpression)
            .filter { !$0.isWhitespace }
    }
    private static func field(_ label: String, lines: [String], value: String) -> String? {
        let values = fieldValues(label, lines: lines, value: value)
        return values.count == 1 ? values.first : nil
    }
    private static func fieldValues(_ label: String, lines: [String], value: String) -> Set<String> {
        var values: Set<String> = []
        for (index, line) in lines.enumerated() {
            if let found = capture("^(?:" + label + ")[:：]?(" + value + ")$", line) { values.insert(found) }
            if line.range(of: "^(?:" + label + ")[:：]?$", options: .regularExpression) != nil,
               index + 1 < lines.count, let found = capture("^(" + value + ")$", lines[index + 1]) { values.insert(found) }
        }
        return values
    }
    private static func capture(_ pattern: String, _ value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let result = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(result.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
    private static let moneyValue = #"[¥￥]?(-?[0-9]{1,12}(?:,[0-9]{3})*\.[0-9]{2})"#
    private static func decimalField(_ label: String, lines: [String]) -> Decimal? {
        guard let value = field(label, lines: lines, value: moneyValue) else { return nil }
        return Decimal(string: value.replacingOccurrences(of: "¥", with: "").replacingOccurrences(of: "￥", with: "").replacingOccurrences(of: ",", with: ""))
    }
    private static func decimalValues(_ text: String) -> [Decimal] {
        let regex = try! NSRegularExpression(pattern: #"(?<![0-9.])-?[0-9]{1,12}(?:,[0-9]{3})*\.[0-9]{2}(?![0-9.])"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).flatMap { Decimal(string: text[$0].replacingOccurrences(of: ",", with: "")) }
        }
    }
    private static func validDate(_ date: String) -> Bool {
        let parts = date.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard parts.count == 3, parts[0] >= 1900, parts[0] <= 2199 else { return false }
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let result = calendar.date(from: components) else { return false }
        return calendar.dateComponents([.year, .month, .day], from: result) == components
    }
}
