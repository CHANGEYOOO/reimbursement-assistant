import Foundation
import Vision

public struct Suggestion: Sendable {
    public var amount: Decimal?
    public var category: ExpenseCategory
    public var purpose: String
    public var warning: String?
    public var recognizedText: String
    public var date: String? = nil
    public var amountCandidates: [AmountCandidate] = []
}

public struct AmountCandidate: Codable, Sendable, Hashable {
    public let amount: Decimal
    public let source: String
}

public enum Recognition {
    struct PositionedText {
        let text: String
        let x: CGFloat
        let y: CGFloat
    }

    private static let paidAmountPattern = #"(?:实付款合计|订单实付款|订单实付|实付款|实付(?!价)|已支付|实际支付|支付金额|付款金额|合计支付)[ \t]*[:：]?[ \t]*[¥￥]?[ \t]*(\d[\d,]*(?:\.\d{1,2})?)"#
    private static let orderTotalPattern = #"(?:商品费用合计|商家合计|订单合计)[ \t]*[:：]?[ \t]*[¥￥]?[ \t]*(\d[\d,]*(?:\.\d{1,2})?)"#
    private static let signedAmountPattern = #"^\s*(?:(?:实付|已支付|实际支付|支付金额|付款金额|合计支付|支出|交易金额|扣款金额|金额)\s*[:：]?\s*)?(?:[¥￥]\s*)?[-−–]\s*(?:[¥￥]\s*)?(\d{1,9}(?:,\d{3})*(?:\.\d{1,2})?)\s*元?\s*$"#

    public static func recognize(_ url: URL) async throws -> Suggestion {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        try VNImageRequestHandler(url: url).perform([request])
        let positioned = (request.results ?? []).compactMap { observation -> PositionedText? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return PositionedText(text: text, x: observation.boundingBox.midX, y: observation.boundingBox.midY)
        }
        let text = positioned.map(\.text).joined(separator: "\n")
        var suggestion = suggest(from: text)
        if let resolved = positionedAmount(in: positioned) {
            suggestion.amount = resolved.amount
            suggestion.warning = [resolved.warning, category(for: text) == .uncategorized ? "用途分类待确认" : nil]
                .compactMap { $0 }.joined(separator: "；")
            if suggestion.warning == "" { suggestion.warning = nil }
        }
        if suggestion.amount == nil {
            suggestion.amountCandidates = amountCandidates(in: positioned)
        }
        return suggestion
    }

    static func amountCandidates(in lines: [PositionedText]) -> [AmountCandidate] {
        var ranked: [(AmountCandidate, Int, Int)] = []
        func add(_ amount: Decimal, source: String, score: Int, order: Int) {
            guard amount > 0 else { return }
            ranked.append((AmountCandidate(amount: amount, source: source), score, order))
        }
        for (index, line) in lines.enumerated() {
            let value = line.text
            for amount in amounts(in: value, pattern: #"(?:实付款合计|订单实付款|订单实付|实付款)\s*[:：]?[ \t]*[¥￥]?[ \t]*(\d[\d,]*(?:\.\d{1,2})?)"#) {
                add(amount, source: "整单实付", score: 100, order: index)
            }
            if value.contains("实付") && !value.contains("实付满") && !value.contains("实付价") {
                for amount in amounts(in: value, pattern: paidAmountPattern) {
                    add(amount, source: "实付", score: 80, order: index)
                }
            }
            if !isNonPaidLine(value) {
                for amount in amounts(in: value, pattern: signedAmountPattern) {
                    add(amount, source: "支出", score: line.y > 0.6 ? 85 : 55, order: index)
                }
                for amount in amounts(in: value, pattern: #"^\s*合计\s*[¥￥]\s*(\d[\d,]*(?:\.\d{1,2})?)"#) {
                    add(amount, source: "订单合计", score: 65, order: index)
                }
            }
            if value.contains("实付款") || value == "合计" {
                for nearby in lines where abs(nearby.y - line.y) < 0.016 && nearby.x > max(0.65, line.x + 0.2) {
                    let found = amounts(in: nearby.text, pattern: #"[¥￥]\s*(\d[\d,]*(?:\.\d{1,2})?)"#)
                    if found.count == 1, let amount = found.first {
                        add(amount, source: value == "合计" ? "订单合计" : "整单实付", score: 90, order: index)
                    }
                }
            }
            guard !isNonPaidLine(value) else { continue }
            for amount in amounts(in: value, pattern: #"(?<![\dA-Za-z])[-−–]\s*[¥￥]?\s*(\d{1,6}(?:\.\d{1,2})?)(?![\d.,A-Za-z])"#) {
                add(amount, source: "扣款数字", score: 55, order: index)
            }
            for amount in amounts(in: value, pattern: #"[¥￥]\s*(\d{1,6}(?:,\d{3})*(?:\.\d{1,2})?)(?![\d,])"#) {
                add(amount, source: "带货币符号", score: 45, order: index)
            }
            for amount in amounts(in: value, pattern: #"(?<![\dA-Za-z])(\d{1,6}(?:\.\d{1,2})?)\s*元"#) {
                add(amount, source: "金额文字", score: 40, order: index)
            }
            for amount in amounts(in: value, pattern: #"(?<![\d./-])(\d{1,6}\.\d{1,2})(?![\d./-])"#) {
                add(amount, source: "小数金额", score: 30, order: index)
            }
            if lines[max(0, index - 2)..<index].contains(where: { containsPaidLabel($0.text) }) {
                for amount in amounts(in: value, pattern: #"^\s*(\d{1,6})\s*$"#) {
                    add(amount, source: "支付附近金额", score: 25, order: index)
                }
            }
        }
        var seen = Set<Decimal>()
        return ranked.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }
            .compactMap { candidate, _, _ in seen.insert(candidate.amount).inserted ? candidate : nil }
            .prefix(5).map { $0 }
    }

    static func positionedAmount(in lines: [PositionedText]) -> (amount: Decimal, warning: String?)? {
        let allText = lines.map(\.text).joined(separator: "\n")
        if lines.contains(where: { $0.text == "全部订单" || $0.text == "订单列表" }) { return nil }
        if ["退款成功", "已退款", "收款成功", "已收款", "转入成功", "收入到账"].contains(where: allText.contains) { return nil }

        let orderPaid = lines.flatMap { line in
            amounts(in: line.text, pattern: #"(?:实付款合计|订单实付款|订单实付|实付款)\s*[:：]?[ \t]*[¥￥]?[ \t]*(\d[\d,]*(?:\.\d{1,2})?)"#)
        }
        if Set(orderPaid).count == 1, let amount = orderPaid.first { return (amount, nil) }

        for label in lines where label.text.contains("实付款") && !label.text.contains("实付价") {
            let aligned = lines.filter { abs($0.y - label.y) < 0.016 && $0.x > max(0.65, label.x + 0.2) }
            for value in aligned.sorted(by: { $0.x > $1.x }) {
                let totals = amounts(in: value.text, pattern: #"合计\s*[¥￥]?\s*(\d[\d,]*(?:\.\d{1,2})?)"#)
                if let amount = totals.first { return (amount, nil) }
                let currency = amounts(in: value.text, pattern: #"[¥￥]\s*(\d[\d,]*(?:\.\d{1,2})?)"#)
                if currency.count == 1, let amount = currency.first { return (amount, nil) }
            }
        }

        if allText.contains("支付成功") || allText.contains("交易成功") {
            let debits = lines.filter { $0.y > 0.68 }.flatMap { line in
                amounts(in: line.text, pattern: signedAmountPattern).map { (amount: $0, y: line.y) }
            }
            if let debit = debits.max(by: { $0.y < $1.y }) { return (debit.amount, nil) }
        }

        for label in lines where label.text == "合计" {
            let aligned = lines.filter { abs($0.y - label.y) < 0.016 && $0.x > 0.65 }
            for value in aligned {
                let currency = amounts(in: value.text, pattern: #"[¥￥]\s*(\d[\d,]*(?:\.\d{1,2})?)"#)
                if currency.count == 1, let amount = currency.first { return (amount, "仅识别到订单合计，未见实付标识，请人工核对") }
            }
        }
        let orderTotals = lines.flatMap { line in
            amounts(in: line.text, pattern: #"^\s*合计\s*[¥￥]\s*(\d[\d,]*(?:\.\d{1,2})?)"#)
        }
        if Set(orderTotals).count == 1, let amount = orderTotals.first {
            return (amount, "仅识别到订单合计，未见实付标识，请人工核对")
        }
        return nil
    }

    static func suggest(from text: String) -> Suggestion {
        let category = category(for: text)
        let lines = text.components(separatedBy: .newlines)
        let directAmounts = lines.reduce(into: Set<Decimal>()) { values, line in
            if !line.contains("实付价") { values.formUnion(amounts(in: line, pattern: paidAmountPattern)) }
        }
        let hasUnpairedPaidLabel = lines.contains { line in
            containsPaidLabel(line) && !line.contains("实付价") && amounts(in: line, pattern: paidAmountPattern).isEmpty
        }
        let paidAmounts = hasUnpairedPaidLabel
            ? directAmounts.union(candidateAmounts(in: lines))
            : directAmounts
        let amount: Decimal?
        var warnings: [String] = []
        if hasUnpairedPaidLabel && paidAmounts.count == 1 {
            warnings.append("金额未紧邻实付标识，请人工核对")
        }

        let isOrderList = lines.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "全部订单" || $0.contains("订单列表") }
        if isOrderList {
            amount = nil
            warnings.append("订单列表包含多笔订单，请点选正确金额并核对")
        } else if paidAmounts.count == 1 {
            amount = paidAmounts.first
        } else if paidAmounts.count > 1 {
            amount = nil
            warnings.append("识别到多个不同的实付金额，请人工核对")
        } else {
            let signedAmounts = lines.filter { !isNonPaidLine($0) }.reduce(into: Set<Decimal>()) { values, line in
                values.formUnion(amounts(in: line, pattern: signedAmountPattern))
            }
            let indicatesIncoming = ["退款成功", "已退款", "收款成功", "已收款", "转入成功", "收入到账"].contains { text.contains($0) }
            let orderTotals = lines.reduce(into: Set<Decimal>()) { values, line in
                values.formUnion(amounts(in: line, pattern: orderTotalPattern))
            }
            let allAmounts = lines.filter { !isNonPaidLine($0) }.reduce(into: Set<Decimal>()) { values, line in
                values.formUnion(amounts(in: line, pattern: #"[¥￥]\s*(\d[\d,]*(?:\.\d{1,2})?)"#))
            }
            if !indicatesIncoming && signedAmounts.count == 1 {
                amount = signedAmounts.first
            } else if signedAmounts.count > 1 {
                amount = nil
                warnings.append("识别到多个不同的支出金额，请人工核对")
            } else if orderTotals.count == 1 {
                amount = orderTotals.first
                warnings.append("仅识别到订单合计，未见实付标识，请人工核对")
            } else if orderTotals.count > 1 {
                amount = nil
                warnings.append("识别到多个订单合计，请人工核对")
            } else if allAmounts.count == 1 && !lines.contains(where: containsPaidLabel) {
                amount = allAmounts.first
                warnings.append("金额未标明实付，请人工核对")
            } else {
                amount = nil
                warnings.append("未能确定实付金额，请人工填写")
            }
        }

        if category == .uncategorized {
            warnings.append("用途分类待确认")
        }
        return Suggestion(
            amount: amount,
            category: category,
            purpose: category == .uncategorized ? "" : category.rawValue + "费用",
            warning: warnings.isEmpty ? nil : warnings.joined(separator: "；"),
            recognizedText: text,
            date: transactionDate(in: lines)
        )
    }

    private static func transactionDate(in lines: [String]) -> String? {
        let pattern = #"(?<!\d)(20\d{2})[年./-]\s*(\d{1,2})[月./-]\s*(\d{1,2})日?(?!\d)"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let dates: [(Int, String)] = lines.enumerated().flatMap { index, line in
            let source = line as NSString
            return expression.matches(in: line, range: NSRange(location: 0, length: source.length)).compactMap { match -> (Int, String)? in
                guard let year = Int(source.substring(with: match.range(at: 1))),
                      let month = Int(source.substring(with: match.range(at: 2))),
                      let day = Int(source.substring(with: match.range(at: 3))),
                      let date = ExpenseDate.normalized(year: year, month: month, day: day) else { return nil }
                return (index, date)
            }
        }
        for label in ["支付时间", "付款时间", "交易时间", "扣款时间", "转账时间", "成交时间"] {
            let labelIndices = lines.indices.filter { lines[$0].contains(label) }
            let matched = labelIndices.compactMap { labelIndex in
                dates.first { $0.0 >= labelIndex && $0.0 <= labelIndex + 12 }?.1
            }
            if !matched.isEmpty { return Set(matched).count == 1 ? matched.first : nil }
        }
        let unique = Set(dates.map(\.1))
        return unique.count == 1 ? unique.first : nil
    }

    private static func candidateAmounts(in lines: [String]) -> Set<Decimal> {
        lines.filter { !isNonPaidLine($0) }.reduce(into: Set<Decimal>()) { values, line in
            values.formUnion(amounts(in: line, pattern: #"[¥￥]\s*(\d[\d,]*(?:\.\d{1,2})?)"#))
            values.formUnion(amounts(in: line, pattern: #"(?<![0-9A-Za-z])(\d[\d,]*(?:\.\d{1,2})?)\s*元"#))
        }
    }

    private static func isNonPaidLine(_ line: String) -> Bool {
        ["优惠", "节省", "返", "券", "劵", "减", "折扣", "原价", "应付", "订单金额", "商品金额", "总价", "退款", "退回", "实付价", "推荐", "广告"]
            .contains(where: line.contains) || line.contains("元卷")
    }

    private static func containsPaidLabel(_ line: String) -> Bool {
        ["实付", "已支付", "实际支付", "支付金额", "付款金额", "合计支付"].contains(where: line.contains) && !line.contains("实付价") && !line.contains("实付满")
    }

    private static func category(for text: String) -> ExpenseCategory {
        let ignored = ["推荐", "广告", "优惠", "红包", "积分", "退款", "退货", "售后", "价格明细", "实付", "总价", "合计", "账单分类", "订单编号", "交易单号", "支付时间", "付款方式", "配送地址", "收货地址", "发票", "搜索订单", "全部订单", "飞猪旅行", "商品说明", "商户全称", "收单机构", "团购特价", "商家小程序"]
        // 商品名称中的“咖啡”“酒店”等可能只是容器的用途或摆放场景，实物名优先。
        let objects = ["道具", "器材", "设备", "工具", "电子", "数码", "文具", "家具", "家居", "灯具", "台灯", "布料", "地毯", "支架", "容器", "空瓶", "分装瓶", "玻璃瓶", "杯子", "餐具", "雨衣", "牙膏", "棉签", "清洁用品", "防尘罩", "读卡器", "硬盘盒", "亚克力", "花瓶", "仿真花", "干花", "纤维板", "板夹", "托盘", "切菜机", "桌布", "日用百货", "办公用品", "耗材"]
        let strong: [(ExpenseCategory, [String])] = [
            (.transport, ["打车", "网约车", "出租车", "地铁", "公交", "高铁", "火车票", "机票", "车费", "滴滴", "渡口", "渡轮", "停车费", "货拉拉", "乘车后付款", "高速通行费", "过路费", "ETC"]),
            (.meals, ["食品", "食物", "餐饮", "小吃", "快餐", "火锅", "麻辣烫", "拌饭", "盖浇饭", "面馆", "烧烤", "汉堡", "披萨", "奶茶", "咖啡", "果汁", "饮料", "茶饮", "零食", "面包", "甜品", "蛋糕", "水果", "酒类", "酒庄", "张裕", "双人餐", "把子肉", "酸汤", "美食市集", "古茗"]),
            (.lodging, ["酒店", "住宿", "宾馆", "民宿", "房费"]),
        ]
        let weak: [(ExpenseCategory, [String])] = [
            (.meals, ["餐厅", "饭店", "外卖", "午餐", "晚餐", "早餐", "美食"]),
            (.purchases, ["超市"]),
        ]
        var scores: [ExpenseCategory: Int] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard !ignored.contains(where: line.contains) else { continue }
            if objects.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                scores[.purchases, default: 0] += 3
                continue
            }
            for (category, words) in strong where words.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                scores[category, default: 0] += 3
            }
            for (category, words) in weak where words.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                scores[category, default: 0] += 1
            }
        }
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 3,
              best.value >= (ranked.dropFirst().first?.value ?? 0) + 2 else { return .uncategorized }
        return best.key
    }

    private static func amounts(in text: String, pattern: String) -> Set<Decimal> {
        let expression = try! NSRegularExpression(pattern: pattern)
        let source = text as NSString
        return Set(expression.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return Decimal(string: text[range].replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX"))
        })
    }
}
