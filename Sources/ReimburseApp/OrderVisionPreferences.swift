import Foundation

struct OrderVisionPreferences: Codable, Equatable, Sendable {
    enum PurposeStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case short, merchant
        var id: String { rawValue }
        var title: String {
            switch self {
            case .short: "简短概括"
            case .merchant: "保留商户名称"
            }
        }
    }

    var purposeStyle: PurposeStyle = .short
    var classificationNote = ""
    var allowOrderDate = true
    var supplementYear = true
    var extraInstructions = ""
    static let defaults = Self()

    func validated() throws -> Self {
        var value = self
        value.classificationNote = classificationNote.trimmingCharacters(in: .whitespacesAndNewlines)
        value.extraInstructions = extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.classificationNote.count <= 1000 else {
            throw OrderVisionPreferenceError.invalid("分类偏好不能超过1000字。")
        }
        guard value.extraInstructions.count <= 2000 else {
            throw OrderVisionPreferenceError.invalid("补充要求不能超过2000字。")
        }
        return value
    }

    func composedRules(base: String) -> String {
        let purpose = purposeStyle == .short
            ? "用途尽量简短，直接概括商品、服务或转账备注；只有商户信息时可用‘便利店消费’等概括，不要求保留商户全名。"
            : "用途在能确认实际商户时保留商户名称，并简要概括消费内容；只有商户名称时用‘商户名称＋消费’，不编造商品。"
        let date = allowOrderDate
            ? "优先支付或交易日期，没有时允许使用截图中的下单、创建日期作为大致参考日期。"
            : "只使用截图中的支付或交易日期，不使用下单、创建日期；没有依据时保留日期待确认。"
        let year = supplementYear
            ? "截图仅有月日时允许补当前公历年{{CURRENT_YEAR}}，说明补年依据。"
            : "截图仅有月日时不补年份，日期及候选均留空，并说明年份缺失；不得沿用基础规则补年。"
        var lines = [base, "用户识别偏好（以下选项优先于前面的业务偏好，固定输出协议和上传授权始终有效）：",
                     "用途优先采用模型对实际订单内容的语义总结，分类仅作辅助；不能用分类费用覆盖具体用途，不强制用途贴合分类。商品、服务和转账备注优先于商户名称；信息不足不编造。", purpose,
                     "默认分类：可食用、饮用的商品归餐食；不可食用的实物、器材、用品归道具采购。按实际订单内容判断，不凭店名编造商品。", date, year]
        if !classificationNote.isEmpty { lines.append("分类补充偏好：" + classificationNote) }
        if !extraInstructions.isEmpty { lines.append("其他补充要求：" + extraInstructions) }
        return lines.joined(separator: "\n")
    }
}

enum OrderVisionPreferenceError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}
