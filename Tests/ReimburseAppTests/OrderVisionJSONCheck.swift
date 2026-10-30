#if DIRECT_TEST_RUNNER
import Foundation

@main struct OrderVisionJSONCheck {
    static func main() throws {
        let plain = #"{"payment":{"amount":"39.50","candidates":["39.50"]},"purpose":{"text":"咖啡杯采购"}}"#
        for wrapped in [plain, " \n\u{FEFF}" + plain + " \n", "```json\n" + plain + "\n```", "```JSON\n" + plain + "\n```", "```\n" + plain + "\n```", "以下是结果：\n```json\n" + plain + "\n```\n以上为识别结果。"] {
            let object = try OrderVisionJSON.object(from: wrapped)
            precondition((object["payment"] as? [String: Any])?["amount"] as? String == "39.50")
            precondition((object["purpose"] as? [String: Any])?["text"] as? String == "咖啡杯采购")
        }
        let escaped = #"{"purpose":{"text":"中文 {用途} [清单] \\"},"reason":"\"商户\" ,} ,]","payment":{"amount":200}}"#
        let escapedObject = try OrderVisionJSON.object(from: escaped)
        precondition(escapedObject["reason"] as? String == #""商户" ,} ,]"#)
        precondition((escapedObject["payment"] as? [String: Any])?["amount"] as? Int == 200)
        let trailing = #"{"payment":{"amount":"200.00","candidates":["200.00",],},"reason":"不修改 ,} ,] 内容",}"#
        let normalized = try OrderVisionJSON.object(from: trailing)
        precondition(normalized["reason"] as? String == "不修改 ,} ,] 内容")
        precondition((normalized["payment"] as? [String: Any])?["amount"] as? String == "200.00")
        for invalid in [
            plain + "\n" + plain,
            "示例：" + #"{"payment":{"amount":1}}"# + "实际：" + plain,
            "[" + plain + "]",
            "结果：[" + plain + "]",
            #"{"payment":{"amount":200}"#,
            #"{"payment":{"amount":200}]"#,
            #"{"payment":{"amount":200},"x":}"#,
            #"{"payment":{"amount":200},"x":,}"#,
            #"{,}"#, #"{"x":[1,,]}"#,
            #"{"payment":{"amount":1,"amount":200}}"#,
            #"{"payment":{"amount":1,"\u0061mount":200}}"#,
            #"{"payment":{"amount":200},"payment":{"amount":1}}"#,
            #"{'payment':{'amount':200}}"#,
            #"{payment:{amount:200}}"#,
            #"{"payment":{"amount":NaN}}"#,
            String(repeating: " ", count: 12_001),
            String(repeating: "{\"x\":", count: 129) + "1" + String(repeating: "}", count: 129)
        ] {
            do { _ = try OrderVisionJSON.object(from: invalid); preconditionFailure("Invalid/ambiguous JSON accepted: " + String(invalid.prefix(100))) }
            catch { precondition(error is OrderVisionError) }
        }
        let repeatedAcrossObjects = try OrderVisionJSON.object(from: #"{"payment":{"reason":"金额"},"purpose":{"reason":"用途"}}"#)
        precondition(repeatedAcrossObjects.count == 2, "Same key at different scopes is valid")
        print("Visual JSON wrappers, safe trailing commas, escaping, ambiguity, duplicate keys and malformed-input checks passed (offline)")
    }
}
#endif
