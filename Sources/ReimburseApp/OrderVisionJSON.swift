import Foundation

/// Repairs presentation only; never completes truncated data or guesses field values.
enum OrderVisionJSON {
    static func object(from content: String) throws -> [String: Any] {
        guard content.count <= 12_000 else { throw invalid("返回内容过长") }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard !text.isEmpty else { throw invalid("未返回识别内容") }
        guard text.first != "\"" else { throw invalid("需要 JSON 对象，返回的却是字符串") }
        let characters = Array(text)
        var start: Int?
        var stack: [Character] = []
        var quoted = false
        var escaped = false
        var objectText: String?
        for (index, character) in characters.enumerated() {
            if start == nil {
                if character == "{" || character == "[" {
                    start = index
                    stack.append(character == "{" ? "}" : "]")
                } else if character == "}" || character == "]" {
                    throw invalid("括号不匹配")
                }
                continue
            }
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
                continue
            }
            if character == "\"" { quoted = true }
            else if character == "{" || character == "[" {
                guard stack.count < 128 else { throw invalid("嵌套层数过多") }
                stack.append(character == "{" ? "}" : "]")
            } else if character == "}" || character == "]" {
                guard stack.popLast() == character else { throw invalid("括号不匹配") }
                if stack.isEmpty {
                    guard let first = start, characters[first] == "{" else { throw invalid("需要单个订单对象，不能返回数组") }
                    guard objectText == nil else { throw invalid("返回了多个 JSON 对象，无法确定采用哪一个") }
                    objectText = String(characters[first...index])
                    start = nil
                }
            }
        }
        guard start == nil, !quoted else { throw invalid("JSON 未完整结束") }
        guard let objectText else { throw invalid("未找到完整 JSON 对象") }
        let normalized = try normalize(objectText)
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(normalized.utf8)) as? [String: Any] else { throw invalid("需要 JSON 对象") }
            return object
        } catch let error as OrderVisionError { throw error }
        catch { throw invalid("JSON 语法错误，不能可靠读取") }
    }

    private struct Frame {
        let object: Bool
        var expectingKey: Bool
        var keys: Set<String> = []
    }

    private static func normalize(_ text: String) throws -> String {
        let characters = Array(text)
        var output = ""
        var frames: [Frame] = []
        var stringStart: Int?
        var escaped = false
        var lastToken: Character?
        for (index, character) in characters.enumerated() {
            if let start = stringStart {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" {
                    if frames.last?.object == true, frames.last?.expectingKey == true {
                        let key: String
                        do {
                            guard let decoded = try JSONSerialization.jsonObject(with: Data(String(characters[start...index]).utf8), options: .fragmentsAllowed) as? String else { throw invalid("字段名格式错误") }
                            key = decoded
                        } catch { throw invalid("字段名格式错误") }
                        guard frames[frames.count - 1].keys.insert(key).inserted else { throw invalid("同一对象中存在重复字段，无法可靠取值") }
                    }
                    stringStart = nil
                    lastToken = "\""
                }
                continue
            }
            if character == "\"" {
                stringStart = index
            } else if character == "{" || character == "[" {
                frames.append(Frame(object: character == "{", expectingKey: character == "{"))
            } else if character == "}" || character == "]" {
                _ = frames.popLast()
            } else if character == ":" {
                if frames.last?.object == true { frames[frames.count - 1].expectingKey = false }
            } else if character == "," {
                guard let previousToken = lastToken, !["{", "[", ",", ":"].contains(previousToken) else { throw invalid("存在缺少字段或值的逗号") }
                if frames.last?.object == true { frames[frames.count - 1].expectingKey = true }
                var next = index + 1
                while next < characters.count && characters[next].isWhitespace { next += 1 }
                if next < characters.count && (characters[next] == "}" || characters[next] == "]") {
                    lastToken = character
                    continue
                }
            }
            output.append(character)
            if !character.isWhitespace { lastToken = character }
        }
        return output
    }

    private static func invalid(_ reason: String) -> OrderVisionError {
        .unavailable("视觉模型返回格式异常：" + reason + "，未应用；不会自动重试。")
    }
}
