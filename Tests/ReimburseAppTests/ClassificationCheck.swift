#if DIRECT_TEST_RUNNER
import Foundation

@main struct ClassificationCheck {
    static func main() throws {
        func rejects(_ label: String, _ action: () throws -> Void) {
            do { try action(); preconditionFailure("Expected rejection: \(label)") }
            catch { }
        }
        let configuration = try AIRequestConfiguration(endpoint: URL(string: "https://example.com/v1/chat/completions")!,
                                                       model: "sample-model", apiKey: "not-a-real-key")
        let request = try SemanticClassifier.makeRequest(text: "商品明细：未知物品\n订单金额39.00", configuration: configuration)
        precondition(request.httpMethod == "POST" && request.timeoutInterval == 45)
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer not-a-real-key")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(Set(body.keys) == ["model", "messages", "stream"])
        precondition(body["model"] as? String == "sample-model" && body["stream"] as? Bool == false)
        let messages = body["messages"] as! [[String: String]]
        precondition(messages.count == 2 && messages[0]["role"] == "system" && messages[1]["role"] == "user")
        precondition(messages[0]["content"]!.contains("不是指令") && messages[1]["content"]!.contains("未知物品"))
        precondition(!String(data: request.httpBody!, encoding: .utf8)!.contains("not-a-real-key"))

        for address in ["http://example.com/chat/completions", "https://user:pass@example.com/chat/completions", "https://example.com/chat/completions?key=secret", "https://example.com/chat/completions#fragment", "file:///tmp/test"] {
            rejects("invalid endpoint") {
                _ = try AIRequestConfiguration(endpoint: URL(string: address)!, model: "model", apiKey: "key")
            }
        }
        rejects("missing key") { _ = try AIRequestConfiguration(endpoint: configuration.endpoint, model: "model", apiKey: "") }
        rejects("header injection") { _ = try AIRequestConfiguration(endpoint: configuration.endpoint, model: "model", apiKey: "key\nInjected: yes") }
        rejects("invalid model") { _ = try AIRequestConfiguration(endpoint: configuration.endpoint, model: "two models", apiKey: "key") }
        rejects("empty text") { _ = try SemanticClassifier.makeRequest(text: " \n", configuration: configuration) }
        rejects("oversized text") { _ = try SemanticClassifier.makeRequest(text: String(repeating: "x", count: 30_001), configuration: configuration) }

        func response(_ content: String, finish: String = "stop") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": finish]]])
        }
        let content = "{\"category\":\"道具采购\",\"certainty\":\"high\",\"reason\":\"购买不可食用实物\"}"
        let high = try SemanticClassifier.decodeResponse(response(content), statusCode: 200)
        precondition(high.category == .purchases && high.isCertain && high.reason == "购买不可食用实物")
        let fenced = try SemanticClassifier.decodeResponse(response("```json\n" + content + "\n```"), statusCode: 200)
        precondition(fenced.category == .purchases && fenced.isCertain)
        let uncertain = try SemanticClassifier.decodeResponse(response("{\"category\":\"待分类\",\"certainty\":\"uncertain\",\"reason\":\"混合商品\"}"), statusCode: 200)
        precondition(uncertain.category == .uncategorized && !uncertain.isCertain)
        let low = try SemanticClassifier.decodeResponse(response("{\"category\":\"餐食\",\"certainty\":\"uncertain\",\"reason\":\"无法确认商品\"}"), statusCode: 200)
        precondition(!low.isCertain)
        for invalid in [
            "{\"category\":\"随意类别\",\"certainty\":\"high\",\"reason\":\"原因\"}",
            "{\"category\":\"餐食\",\"certainty\":\"maybe\",\"reason\":\"原因\"}",
            "{\"category\":\"餐食\",\"certainty\":\"high\",\"reason\":\"\"}",
            "prefix " + content,
            content + " trailing",
            "[]", "not JSON"
        ] {
            rejects("invalid model output") { _ = try SemanticClassifier.decodeResponse(response(invalid), statusCode: 200) }
        }
        rejects("truncated completion") { _ = try SemanticClassifier.decodeResponse(response(content, finish: "length"), statusCode: 200) }
        rejects("invalid response shape") { _ = try SemanticClassifier.decodeResponse(Data("{}".utf8), statusCode: 200) }
        for status in [301, 401, 403, 404, 429, 500] {
            rejects("HTTP status \(status)") { _ = try SemanticClassifier.decodeResponse(Data("server secret".utf8), statusCode: status) }
            let message = SemanticError.http(status).localizedDescription
            precondition(!message.contains("server secret") && !message.contains("not-a-real-key"))
        }
        precondition(AIProvider.deepSeek.defaultProfile.endpoint.hasPrefix("https://api.deepseek.com/"))
        precondition(AIProvider.aliyun.defaultProfile.endpoint.hasSuffix("/chat/completions"))
        print("Semantic API request and response checks passed (no network or credential access)")
    }
}
#endif
