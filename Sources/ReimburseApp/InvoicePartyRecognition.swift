import Foundation
import PDFKit

// Party names follow their visual column, not PDFKit's text extraction order.
enum InvoicePartyRecognition {
    private struct Glyph {
        let value: String
        let box: CGRect
    }

    static func details(at url: URL, text: String) throws -> (buyer: String, seller: String, item: String) {
        let plain = details(in: text)
        guard url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) else { return plain }
        for index in 0..<min(document.pageCount, 3) {
            guard let page = document.page(at: index), let source = page.string, !source.isEmpty else { continue }
            let spatial = details(on: page, text: source)
            if spatial.hasRoles { return (spatial.buyer, spatial.seller, plain.item) }
        }
        return plain
    }

    static func details(in text: String) -> (buyer: String, seller: String, item: String) {
        var normalized = text.precomposedStringWithCompatibilityMapping
        for role in ["购买方", "销售方", "付款方", "收款方"] {
            let pattern = role.map(String.init).joined(separator: #"\s*"#) + #"(?:\s*信\s*息)?"#
            normalized = normalized.replacingOccurrences(of: pattern, with: role, options: .regularExpression)
        }
        normalized = normalized.replacingOccurrences(of: #"名\s*称"#, with: "名称", options: .regularExpression)
        let ns = normalized as NSString
        let roles = matches(#"购买方|付款方|销售方|收款方"#, in: normalized)
        let ambiguousColumns = zip(roles, roles.dropFirst()).contains { first, second in
            guard NSIntersectionRange(ns.lineRange(for: first.range), second.range).length > 0 else { return false }
            let between = ns.substring(with: NSRange(location: NSMaxRange(first.range), length: second.range.location - NSMaxRange(first.range)))
            return matches(#"[:：]\s*[^\s:：]+"#, in: between).isEmpty
        }
        func extract(_ names: [String]) -> String {
            guard !ambiguousColumns, let role = roles.first(where: { names.contains(ns.substring(with: $0.range)) }) else { return "" }
            let end = roles.first(where: { $0.range.location > role.range.location })?.range.location ?? ns.length
            let region = ns.substring(with: NSRange(location: NSMaxRange(role.range), length: end - NSMaxRange(role.range)))
            if let name = matches(#"名称\s*[:：]\s*([^\r\n]+)"#, in: region).first {
                return cleaned((region as NSString).substring(with: name.range(at: 1)))
            }
            if let direct = matches(#"^\s*[:：]\s*([^\r\n]+)"#, in: region).first {
                return cleaned((region as NSString).substring(with: direct.range(at: 1)))
            }
            return ""
        }
        let item = text.components(separatedBy: .newlines).first { $0.contains("*") || $0.contains("＊") } ?? ""
        return (extract(["购买方", "付款方"]), extract(["销售方", "收款方"]), item)
    }

    private static func details(on page: PDFPage, text: String) -> (buyer: String, seller: String, hasRoles: Bool) {
        let ns = text as NSString
        var glyphs: [Glyph] = []
        for index in 0..<ns.length {
            let value = ns.substring(with: NSRange(location: index, length: 1))
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let box = page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page),
                  box.width > 0, box.height > 0, box.minX.isFinite, box.minY.isFinite else { continue }
            glyphs.append(Glyph(value: value.precomposedStringWithCompatibilityMapping, box: box))
        }
        func role(_ word: String) -> CGRect? {
            let characters = word.map(String.init)
            for vertical in [true, false] {
                for first in glyphs where first.value == characters[0] {
                    var chain = [first]
                    for character in characters.dropFirst() {
                        let previous = chain.last!
                        let candidates = glyphs.filter { next in
                            guard next.value == character else { return false }
                            if vertical {
                                return abs(next.box.midX - previous.box.midX) <= max(previous.box.width, next.box.width) * 0.6 &&
                                    next.box.midY < previous.box.midY && previous.box.midY - next.box.midY < max(previous.box.height, next.box.height) * 2.5
                            }
                            return abs(next.box.midY - previous.box.midY) <= max(previous.box.height, next.box.height) * 0.6 &&
                                next.box.midX > previous.box.midX && next.box.midX - previous.box.midX < max(previous.box.width, next.box.width) * 2.5
                        }
                        guard let next = candidates.min(by: { a, b in
                            hypot(a.box.midX - previous.box.midX, a.box.midY - previous.box.midY) < hypot(b.box.midX - previous.box.midX, b.box.midY - previous.box.midY)
                        }) else { break }
                        chain.append(next)
                    }
                    if chain.count == characters.count { return chain.dropFirst().reduce(first.box) { $0.union($1.box) } }
                }
            }
            return nil
        }
        let buyer = role("购买方") ?? role("付款方")
        let seller = role("销售方") ?? role("收款方")
        let roles = [buyer, seller].compactMap { $0 }
        let labels = matches(#"名\s*称"#, in: text).compactMap { match -> CGRect? in
            let prefix = ns.substring(with: NSRange(location: max(0, match.range.location - 8), length: min(8, match.range.location)))
                .filter { !$0.isWhitespace }
            guard !["项目", "商品", "货物", "服务"].contains(where: prefix.hasSuffix) else { return nil }
            return page.selection(for: match.range)?.bounds(for: page)
        }
        func name(at anchor: CGRect?) -> String {
            guard let anchor else { return "" }
            let rightEdge = roles.filter { $0.minX > anchor.maxX + 8 }.map(\.minX).min() ?? page.bounds(for: .mediaBox).maxX
            let horizontal = anchor.width > anchor.height
            let candidates = labels.filter { label in
                label.minX >= (horizontal ? anchor.minX : anchor.maxX) - 2 && label.maxX < rightEdge &&
                    label.midY >= anchor.minY - label.height * 3 && label.midY <= anchor.maxY + label.height
            }
            func score(_ label: CGRect) -> CGFloat {
                horizontal ? abs(label.minX - anchor.minX) + abs(label.midY - anchor.minY) * 2
                    : (label.minX - anchor.maxX) + abs(label.midY - anchor.maxY) * 2
            }
            guard let label = candidates.min(by: { score($0) < score($1) }) else { return "" }
            let nextLabel = labels.filter { $0.minX > label.maxX && abs($0.midY - label.midY) < max($0.height, label.height) }
                .map(\.minX).min() ?? rightEdge
            let columnEnd = min(rightEdge, nextLabel)
            let row = glyphs.filter {
                $0.box.midX > label.maxX && $0.box.midX < columnEnd - 1 &&
                    abs($0.box.midY - label.midY) < max($0.box.height, label.height) * 0.55
            }.sorted { $0.box.midX < $1.box.midX }
            var connected: [Glyph] = []
            for glyph in row {
                if let previous = connected.last,
                   glyph.box.minX - previous.box.maxX > max(previous.box.height, glyph.box.height) * 2 { break }
                connected.append(glyph)
            }
            return cleaned(connected.map(\.value).joined())
        }
        return (name(at: buyer), name(at: seller), !roles.isEmpty)
    }

    private static func cleaned(_ source: String) -> String {
        var value = source.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":：")))
        if let stop = matches(#"(?:纳税人识别号|统一社会信用代码|税号|地址[、，]?电话|开户行及账号)\s*[:：]"#, in: value).first {
            value = (value as NSString).substring(to: stop.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard value.contains(where: \.isLetter), !["名称", "购买方", "销售方", "付款方", "收款方", "信息"].contains(value) else { return "" }
        return value
    }

    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        let expression = try! NSRegularExpression(pattern: pattern)
        return expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
}
