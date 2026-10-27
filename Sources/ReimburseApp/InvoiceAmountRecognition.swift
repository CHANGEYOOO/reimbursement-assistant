import Foundation
import ImageIO
import PDFKit
import Vision

// Select the printed total by its label and visual row, never by largest value or extraction order.
enum InvoiceAmountRecognition {
    private struct Piece { let text: String; let box: CGRect }
    private struct Reading { var values: [Decimal] = [] }
    private static let amountPattern = #"(?<![\d.])(?:[-−–]\s*[¥￥]?|[¥￥]\s*[-−–]?)?\s*(?:\d{1,3}(?:,\d{3})+|\d(?:[ \t]*\d){0,8})(?:\s*\.\s*\d(?:[ \t]*\d)?)?(?![\d.%])"#

    static func total(at url: URL, text: String) throws -> Decimal? {
        if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) {
            defer { withExtendedLifetime(document) {} }
            var native = Reading()
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let content = page.string else { continue }
                let ns = content as NSString
                let pieces = (0..<ns.length).compactMap { index -> Piece? in
                    let value = ns.substring(with: NSRange(location: index, length: 1)).precomposedStringWithCompatibilityMapping
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let box = page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page), box.width > 0, box.height > 0 else { return nil }
                    return Piece(text: value, box: box)
                }
                let result = spatial(pieces)
                native.values += result.values
            }
            if !native.values.isEmpty { return uniquePositive(native.values) }
            // A scanned PDF has no usable text geometry; OCR keeps the same label/position rule.
            if document.pageCount <= 3 {
                var scanned: [Decimal] = []
                for index in 0..<document.pageCount {
                    guard let image = document.page(at: index)?.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)
                        .cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                    scanned += try spatial(ocr(image)).values
                }
                if !scanned.isEmpty { return uniquePositive(scanned) }
            }
            return total(in: text)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return total(in: text) }
        let values = try spatial(ocr(image)).values
        return values.isEmpty ? total(in: text) : uniquePositive(values)
    }

    static func total(in text: String) -> Decimal? {
        var source = text.precomposedStringWithCompatibilityMapping
        for label in ["价税合计", "合计金额", "发票金额", "小写"] {
            source = source.replacingOccurrences(of: label.map(String.init).joined(separator: #"\s*"#), with: label, options: .regularExpression)
        }
        let lines = source.components(separatedBy: .newlines)
        var values: [Decimal] = []
        for (index, line) in lines.enumerated() {
            let label = ["价税合计", "合计金额", "发票金额"].first { line.contains($0) }
            guard let label else { continue }
            let section = Array(lines[index..<min(lines.count, index + 8)])
            if let small = section.firstIndex(where: { $0.contains("小写") }), let range = section[small].range(of: "小写") {
                let sameLine = String(section[small][range.upperBound...])
                var found = amounts(sameLine)
                if found.isEmpty, small + 1 < section.count { found = amounts(section[small + 1]) }
                // More distant extraction-order values can be table amounts, so remain unresolved.
                values += found
            } else if let range = line.range(of: label) {
                values += amounts(String(line[range.upperBound...]))
            }
        }
        return uniquePositive(values)
    }

    private static func uniquePositive(_ values: [Decimal]) -> Decimal? {
        let distinct = Set(values)
        guard distinct.count == 1, let value = distinct.first, value > 0 else { return nil }
        return value
    }
    private static func amounts(_ source: String) -> [Decimal] {
        let expression = try! NSRegularExpression(pattern: amountPattern)
        let ns = source as NSString
        return expression.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let token = ns.substring(with: match.range)
                .replacingOccurrences(of: "¥", with: "").replacingOccurrences(of: "￥", with: "")
                .replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "–", with: "-")
                .filter { !$0.isWhitespace }
            return Decimal(string: token, locale: Locale(identifier: "en_US_POSIX"))
        }
    }

    private static func spatial(_ pieces: [Piece]) -> Reading {
        var rows: [[Piece]] = []
        for piece in pieces.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let index = rows.firstIndex(where: { abs(($0.first?.box.midY ?? 0) - piece.box.midY) < min($0.first?.box.height ?? 0, piece.box.height) * 0.45 }) {
                rows[index].append(piece)
            } else { rows.append([piece]) }
        }
        var result = Reading()
        for row in rows {
            let sorted = row.sorted { $0.box.minX < $1.box.minX }
            let joined = sorted.map(\.text).joined()
            let ns = joined as NSString
            let labelPattern = #"小\s*写|价\s*税\s*合\s*计|合\s*计\s*金\s*额|发\s*票\s*金\s*额"#
            let labels = try! NSRegularExpression(pattern: labelPattern)
            let found = labels.matches(in: joined, range: NSRange(location: 0, length: ns.length))
            guard !found.isEmpty else { continue }
            // Prefer 小写 when uppercase total and lowercase amount share the row.
            let label = found.first(where: { ns.substring(with: $0.range).filter { !$0.isWhitespace } == "小写" }) ?? found[0]
            let after = ns.substring(from: NSMaxRange(label.range))
            let values = amounts(after)
            result.values += values
        }
        return result
    }

    private static func ocr(_ image: CGImage) throws -> [Piece] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        var pieces: [Piece] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            for index in candidate.string.indices {
                let end = candidate.string.index(after: index)
                guard let rectangle = try? candidate.boundingBox(for: index..<end) else { continue }
                let box = rectangle.boundingBox
                pieces.append(Piece(text: String(candidate.string[index..<end]).precomposedStringWithCompatibilityMapping,
                    box: CGRect(x: box.minX * CGFloat(image.width), y: box.minY * CGFloat(image.height), width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height))))
            }
        }
        return pieces
    }
}
