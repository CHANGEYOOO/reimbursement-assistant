#if DIRECT_TEST_RUNNER
import Foundation

@main struct SemanticAmountCheck {
    static func main() throws {
        func result(_ source: String, amount: Any = NSNull(), amountCertainty: String = "high",
                    amounts: [String] = [], date: Any = NSNull(), dateCertainty: String = "high",
                    dates: [String] = [], reference: Date? = nil) throws -> SemanticClassification {
            let object: [String: Any] = ["category": "交通", "certainty": "high", "reason": "本单是出行服务",
                "payment": ["amount": amount, "certainty": amountCertainty, "reason": "选择实付金额", "candidates": amounts],
                "transaction_date": ["date": date, "certainty": dateCertainty, "reason": "选择交易日期", "candidates": dates]]
            let content = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
            return try SemanticClassifier.decodeResponse(data, statusCode: 200, sourceText: source,
                referenceDate: reference ?? ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!)
        }
        let debit = try result("支出\n-39.00", amount: "39.00")
        precondition(debit.payment?.amount == 39 && debit.payment?.isCertain == true)
        let labels = try result("原价49.00\n优惠10.00\n实付39.00", amount: "39.00")
        precondition(labels.payment?.isCertain == true && labels.payment?.amount == 39)
        let inferred = try result("原价49.00\n优惠10.00", amount: "39.00")
        precondition(inferred.category == .transport && inferred.payment?.amount == nil && inferred.payment?.isCertain == false)
        precondition(Set(inferred.payment!.candidates) == [10, 49])
        let fabricated = try result("实付39.00", amount: "999.00", amounts: ["999.00", "39.00", "39.00"])
        precondition(fabricated.payment?.amount == nil && fabricated.payment?.candidates == [39])
        for source in ["订单号1234567890123456789", "电话13900000000", "订单号20260924", "支付日期2026-09-24", "实付2026-09-24", "支付日期2026.09.24", "优惠10%", "金额12,34"] {
            let invalid = try result(source, amount: "24", amounts: ["24", "10", "34"])
            precondition(invalid.payment?.amount == nil && invalid.payment?.candidates.isEmpty == true, source)
        }
        let uncertain = try result("¥39.00\n¥49.00", amount: "39", amountCertainty: "uncertain", amounts: ["39", "39", "49", "0", "999"])
        precondition(uncertain.payment?.isCertain == false && uncertain.payment?.candidates == [39, 49])
        let comma = try result("已支付￥1,234.50", amount: "1234.50")
        precondition(comma.payment?.isCertain == true && comma.payment?.amount == Decimal(string: "1234.5"))
        let integer = try result("已支付39", amount: "39")
        precondition(integer.payment?.isCertain == true)
        for source in ["已支付\n39", "实付款：\n\n39", "支付金额\n39"] {
            let linked = try result(source, amount: "39")
            precondition(linked.payment?.isCertain == true && linked.payment?.amount == 39, source)
        }
        for source in ["已支付\n\n\n39", "已支付\n订单号\n39", "已支付\n支付日期\n39", "已支付\n电话\n39", "已支付\n20260924", "已支付\n2026-09-24"] {
            let blocked = try result(source, amount: "39", amounts: ["39", "20260924", "24"])
            precondition(blocked.payment?.isCertain == false && blocked.payment?.candidates.isEmpty == true, source)
        }

        for source in ["退款成功\n-39.00", "收款成功\n39.00", "收入\n39.00", "已到账39元", "支付39元\n退款金额5元", "退款39元", "收入39元", "收款39元", "到账39元"] {
            let incoming = try result(source, amount: "39")
            precondition(incoming.payment?.isCertain == false && incoming.payment?.amount == nil, source)
        }
        let recipient = try result("收款方：某商家\n-39.00", amount: "39")
        precondition(recipient.payment?.isCertain == true)
        let many = try result((1...9).map { "¥\($0).00" }.joined(separator: "\n"), amountCertainty: "uncertain", amounts: (1...9).map(String.init))
        precondition(many.payment?.candidates.count == 6)

        let paid = try result("下单时间2026-9-23\n支付时间2026/9/24", date: "2026-09-24", dates: ["2026-09-23", "2026-09-24"])
        precondition(paid.transactionDate?.isCertain == true && paid.transactionDate?.date == "2026-09-24")
        let created = try result("创建时间2026-09-23", date: "2026-09-23")
        precondition(created.transactionDate?.isCertain == false && created.transactionDate?.candidates == ["2026-09-23"])
        let mismatched = try result("下单时间2026-09-23\n付款时间2026-09-24", date: "2026-09-23")
        precondition(mismatched.transactionDate?.isCertain == false)
        let compact = try result("交易日期\n20260924", date: "2026-09-24")
        precondition(compact.transactionDate?.isCertain == true)
        let standalone = try result("20260924", date: "2026-09-24")
        precondition(standalone.transactionDate?.isCertain == false && standalone.transactionDate?.candidates == ["2026-09-24"])
        for source in ["支付日期13-24", "支付日期2026-02-30", "订单号20260924123456789", "订单号20260924"] {
            let invalid = try result(source, date: "2026-09-24", dates: ["2026-09-24"])
            precondition(invalid.transactionDate?.date == nil && invalid.transactionDate?.candidates.isEmpty == true, source)
        }
        let reference2028 = ISO8601DateFormatter().date(from: "2028-01-01T12:00:00Z")!
        for source in ["支付日期9月24日", "付款时间09-24", "交易日期9/24", "扣款日期09.24", "支付时间\n09-24 12:11:54"] {
            let inferred = try result(source, date: "2026-09-24")
            precondition(inferred.transactionDate?.date == "2026-09-24" && inferred.transactionDate?.isCertain == true, source)
            precondition(inferred.transactionDate?.reason.contains("原文仅月日，按当前年份2026补全") == true)
        }
        let future = try result("支付日期09-24", date: "2028-09-24", reference: reference2028)
        precondition(future.transactionDate?.isCertain == true && future.transactionDate?.reason.contains("当前年份2028") == true)
        let oldYear = try result("支付日期2025-09-24", date: "2025-09-24")
        precondition(oldYear.transactionDate?.isCertain == true && oldYear.transactionDate?.reason.contains("补全") == false)
        let rewrittenYear = try result("支付日期2025-09-24", date: "2026-09-24")
        precondition(rewrittenYear.transactionDate?.isCertain == false && rewrittenYear.transactionDate?.candidates == ["2025-09-24"])
        for source in ["支付日期2025-02-29", "支付日期2026-02-30", "支付日期2/30", "支付日期2/29", "商品价格09.24元", "￥9.24", "09.24", "订单号09-24", "支付时间\n订单号\n09-24", "支付时间\n电话\n09-24"] {
            let invalidMonthDay = try result(source, date: "2026-09-24", dates: ["2026-09-24"], reference: reference2028)
            if source == "支付日期2/29" {
                precondition(invalidMonthDay.transactionDate?.candidates == ["2028-02-29"])
            } else {
                precondition(invalidMonthDay.transactionDate?.candidates.isEmpty == true, source)
            }
        }
        let nonLeap = try result("支付日期2/29", date: "2026-02-29")
        precondition(nonLeap.transactionDate?.date == nil && nonLeap.transactionDate?.candidates.isEmpty == true)
        let leap = try result("支付日期2/29", date: "2028-02-29", reference: reference2028)
        precondition(leap.transactionDate?.isCertain == true && leap.transactionDate?.reason.contains("当前年份2028") == true)
        let creationMonthDay = try result("创建日期09-24", dateCertainty: "uncertain")
        precondition(creationMonthDay.transactionDate?.isCertain == false && creationMonthDay.transactionDate?.candidates == ["2026-09-24"])
        precondition(creationMonthDay.transactionDate?.reason.contains("当前年份2026补全") == true)
        for source in ["支付日期\n09.24", "交易时间\n09.24 12:00", "支付时间\n39"] {
            let notMoney = try result(source, amount: "9.24", amounts: ["9.24", "39"])
            precondition(notMoney.payment?.amount == nil && notMoney.payment?.candidates.isEmpty == true, source)
        }

        let falseDate = try result("支付日期2026年9月24日", date: "2026-10-26", dates: ["2026-10-26"])
        precondition(falseDate.transactionDate?.isCertain == false && falseDate.transactionDate?.candidates == ["2026-09-24"])
        let competing = try result("支付日期2026-09-24\n支付日期2026-09-25", date: "2026-09-24")
        precondition(competing.transactionDate?.isCertain == false)
        let four = try result((1...7).map { "创建日期2026-09-\($0)" }.joined(separator: "\n"), dateCertainty: "uncertain")
        precondition(four.transactionDate?.candidates.count == 4)

        let malformedContent = "{\"category\":\"交通\",\"certainty\":\"high\",\"reason\":\"出行服务\",\"payment\":{\"amount\":{}},\"transaction_date\":[]}"
        let malformedData = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": malformedContent], "finish_reason": "stop"]]])
        let malformed = try SemanticClassifier.decodeResponse(malformedData, statusCode: 200, sourceText: "实付39元\n支付日期2026-09-24")
        precondition(malformed.category == .transport && malformed.payment?.isCertain == false && malformed.payment?.candidates == [39])
        precondition(malformed.transactionDate?.isCertain == false && malformed.transactionDate?.candidates == ["2026-09-24"])

        let configuration = try AIRequestConfiguration(endpoint: URL(string: "https://example.com/chat/completions")!, model: "sample", apiKey: "fake-key")
        func prompt(amount: Bool = false, date: Bool = false) throws -> String {
            let request = try SemanticClassifier.makeRequest(text: "实付39元", configuration: configuration, includeAmount: amount, includeDate: date,
                referenceDate: ISO8601DateFormatter().date(from: "2028-01-01T12:00:00Z")!)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            precondition(Set(body.keys) == ["model", "messages", "stream"])
            return (body["messages"] as! [[String: String]])[0]["content"]!
        }
        let original = try prompt()
        precondition(original.contains("只判断用途") && !original.contains("\"payment\"") && !original.contains("\"transaction_date\""))
        let combined = try prompt(amount: true, date: true)
        precondition(combined.contains("\"payment\"") && combined.contains("\"transaction_date\"") && combined.contains("不得计算"))
        precondition(combined.contains("本次参考公历年为2028") && !combined.contains("不得猜年份"))
        let amountOnly = try prompt(amount: true)
        precondition(amountOnly.contains("\"payment\"") && !amountOnly.contains("\"transaction_date\""))
        print("Semantic amount and date evidence checks passed (no network or credentials)")
    }
}
#endif
