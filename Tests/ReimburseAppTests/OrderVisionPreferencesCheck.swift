#if DIRECT_TEST_RUNNER
import Foundation

@main struct OrderVisionPreferencesCheck {
    static func main() throws {
        precondition(AIProvider(rawValue: "aliyun") == .aliyun, "Old provider identity remains compatible")
        precondition(AIProvider.qianwen.rawValue != AIProvider.aliyun.rawValue, "New platform has a separate credential account")
        let profile = AIProvider.qianwen.defaultProfile
        let configuration = try AIRequestConfiguration(endpoint: URL(string: profile.endpoint)!, model: profile.model, apiKey: "offline-no-network")
        precondition(configuration.endpoint.absoluteString == "https://maas.qianwenaiapi.com/compatible-mode/v1/chat/completions" && configuration.model == "qwen3-vl-plus")
        let defaults = OrderVisionPreferences.defaults
        precondition(defaults.purposeStyle == .short && defaults.allowOrderDate && defaults.supplementYear)
        let base = "软件内置规则：优先商品内容；年份{{CURRENT_YEAR}}"
        let standard = defaults.composedRules(base: base)
        precondition(standard.contains("不能用分类费用覆盖具体用途"))
        precondition(standard.hasPrefix(base) && standard.contains("可食用、饮用") && standard.contains("不可食用") && standard.contains("不要求保留商户全名"))
        var changed = defaults
        changed.purposeStyle = .merchant
        changed.allowOrderDate = false
        changed.supplementYear = false
        changed.classificationNote = "  设备租赁归其他  "
        changed.extraInstructions = "  用途不超过十个字  "
        let clean = try changed.validated()
        precondition(clean.classificationNote.isEmpty && clean.extraInstructions == "分类补充：设备租赁归其他\n用途不超过十个字")
        let cleanAgain = try clean.validated()
        precondition(cleanAgain == clean, "Migration must be idempotent")
        let rules = clean.composedRules(base: base)
        precondition(rules.hasPrefix(base), "Preferences append to software-owned rules")
        precondition(rules.contains("优先于前面的业务偏好") && rules.contains("固定输出协议和上传授权始终有效"))
        precondition(rules.contains("保留商户名称") && rules.contains("不使用下单、创建日期") && rules.contains("日期及候选均留空"))
        precondition(rules.contains("分类补充：设备租赁归其他") && rules.contains("用途不超过十个字"))
        let restored = try JSONDecoder().decode(OrderVisionPreferences.self, from: JSONEncoder().encode(clean))
        precondition(restored == clean)
        changed.extraInstructions = String(repeating: "字", count: 4001)
        do { _ = try changed.validated(); preconditionFailure("Oversized supplementary requirements accepted") } catch {}
        changed = defaults
        changed.classificationNote = String(repeating: "甲", count: 1000)
        changed.extraInstructions = String(repeating: "乙", count: 2000)
        let migratedMaximum = try changed.validated()
        precondition(migratedMaximum.classificationNote.isEmpty && migratedMaximum.extraInstructions.contains(String(repeating: "甲", count: 1000)) && migratedMaximum.extraInstructions.contains(String(repeating: "乙", count: 2000)), "Valid old fields fit the single input without losing either text")
        precondition(!defaults.composedRules(base: base).contains("设备租赁归其他"), "Restoring default preferences removes supplementary rules")
        print("Vision preference defaults, single-input migration, composition, limits and serialization passed (offline)")
    }
}
#endif
