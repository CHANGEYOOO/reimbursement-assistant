import Foundation
import CoreFoundation

// Parses IMAP metadata only; no attachment contents are fetched during mailbox synchronization.
enum QQMailboxParser {
    static func literalCount(_ line: String) -> Int? {
        guard let range = line.range(of: #"\{([0-9]+)\+?\}\r\n$"#, options: .regularExpression) else { return nil }
        return Int(line[range].filter(\.isNumber))
    }
    static func uidValidity(_ data: Data) throws -> String {
        let text = String(decoding: data, as: UTF8.self)
        guard let value = capture(#"\[UIDVALIDITY ([0-9]+)\]"#, in: text), UInt64(value) != nil else { throw QQMailboxError.malformed }
        return value
    }
    static func searchIDs(_ data: Data) -> [UInt64] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
            .filter { $0.hasPrefix("* SEARCH") }.flatMap { $0.dropFirst(8).split(separator: " ").compactMap { UInt64($0) } }
    }
    static func literals(_ data: Data) -> [Data] {
        var found: [Data] = []
        var start = data.startIndex
        while start < data.endIndex, let range = data.range(of: Data([13, 10]), in: start..<data.endIndex) {
            let line = String(decoding: data[start..<range.upperBound], as: UTF8.self)
            start = range.upperBound
            if let length = literalCount(line), length <= data.distance(from: start, to: data.endIndex) {
                let end = data.index(start, offsetBy: length)
                found.append(Data(data[start..<end]))
                start = end
            }
        }
        return found
    }
    static func message(_ data: Data, account: String, uidValidity: String, uid: UInt64) throws -> InvoiceMailMessage {
        let text = String(decoding: data, as: UTF8.self)
        guard let stamp = capture(#"INTERNALDATE \"([^\"]+)\""#, in: text),
              let bodyRange = text.range(of: "BODYSTRUCTURE ", options: .caseInsensitive) else { throw QQMailboxError.malformed }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        guard let received = formatter.date(from: stamp) else { throw QQMailboxError.malformed }
        var parser = StructureParser(bytes: Array(text[bodyRange.upperBound...].utf8))
        let structure = try parser.node()
        let headerData = literals(data).first { bytes in
            let value = String(decoding: bytes, as: UTF8.self).lowercased()
            return value.hasPrefix("subject:") || value.hasPrefix("from:") || value.contains("\r\nsubject:") || value.contains("\r\nfrom:")
        } ?? Data()
        let headers = headers(headerData)
        let subject = decodeWords(headers["subject"] ?? "")
        let sender = decodeWords(headers["from"] ?? "")
        var parts: [Part] = []
        collect(structure, prefix: "", into: &parts)
        let isInvoice = subject.contains("发票") || subject.lowercased().contains("invoice")
        let supported = Set(["pdf", "png", "jpg", "jpeg", "heic", "heif", "zip"])
        let attachments = parts.compactMap { part -> InvoiceMailAttachment? in
            let filename = (part.filename as NSString).lastPathComponent
            let ext = (filename as NSString).pathExtension.lowercased()
            guard supported.contains(ext), !filename.isEmpty,
                  InvoiceDocumentClassifier.shouldList(filename: filename, subject: subject) else { return nil }
            if ["png", "jpg", "jpeg", "heic", "heif"].contains(ext) {
                guard part.disposition == "ATTACHMENT" || filename.contains("发票") else { return nil }
                if ["logo", "signature", "icon"].contains(where: filename.lowercased().contains) { return nil }
            }
            let remote = MailAttachmentReference(account: account, uidValidity: uidValidity, uid: uid,
                partID: part.id, encoding: part.encoding, size: part.size)
            return InvoiceMailAttachment(filename: filename, remote: remote)
        }
        let hasSupportedAttachment = parts.contains { supported.contains(($0.filename as NSString).pathExtension.lowercased()) }
        return InvoiceMailMessage(id: "\(account)|\(uidValidity)|\(uid)", receivedAt: received, subject: subject,
            sender: sender, attachments: attachments, hasDownloadLink: isInvoice && !hasSupportedAttachment)
    }

    private enum Node {
        case atom(String), list([Node])
        var string: String? { if case .atom(let value) = self { return value.uppercased() == "NIL" ? nil : value }; return nil }
        var list: [Node]? { if case .list(let value) = self { return value }; return nil }
    }
    private struct StructureParser {
        let bytes: [UInt8]
        var index = 0
        mutating func node(depth: Int = 0) throws -> Node {
            guard depth < 40 else { throw QQMailboxError.malformed }
            while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
            guard index < bytes.count else { throw QQMailboxError.malformed }
            if bytes[index] == 40 {
                index += 1
                var nodes: [Node] = []
                while true {
                    while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
                    guard index < bytes.count else { throw QQMailboxError.malformed }
                    if bytes[index] == 41 { index += 1; return .list(nodes) }
                    nodes.append(try node(depth: depth + 1))
                }
            }
            if bytes[index] == 34 {
                index += 1
                var value: [UInt8] = []
                while index < bytes.count {
                    let byte = bytes[index]
                    index += 1
                    if byte == 34 { return .atom(String(decoding: value, as: UTF8.self)) }
                    if byte == 92 {
                        guard index < bytes.count else { throw QQMailboxError.malformed }
                        value.append(bytes[index]); index += 1
                    } else { value.append(byte) }
                }
                throw QQMailboxError.malformed
            }
            if bytes[index] == 123 {
                index += 1
                let start = index
                while index < bytes.count && bytes[index] >= 48 && bytes[index] <= 57 { index += 1 }
                guard let length = Int(String(decoding: bytes[start..<index], as: UTF8.self)), length >= 0 else { throw QQMailboxError.malformed }
                if index < bytes.count && bytes[index] == 43 { index += 1 }
                guard index + 2 < bytes.count, bytes[index] == 125, bytes[index + 1] == 13, bytes[index + 2] == 10 else { throw QQMailboxError.malformed }
                index += 3
                guard length <= bytes.count - index else { throw QQMailboxError.malformed }
                let value = String(decoding: bytes[index..<index + length], as: UTF8.self)
                index += length
                return .atom(value)
            }
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 40, 41].contains(bytes[index]) { index += 1 }
            guard index > start else { throw QQMailboxError.malformed }
            return .atom(String(decoding: bytes[start..<index], as: UTF8.self))
        }
    }
    private struct Part {
        let id: String
        let filename: String
        let encoding: String
        let disposition: String
        let size: Int
    }
    private static func collect(_ node: Node, prefix: String, into parts: inout [Part]) {
        guard let list = node.list, !list.isEmpty else { return }
        if list[0].list != nil {
            for (offset, child) in list.prefix(while: { $0.list != nil }).enumerated() {
                collect(child, prefix: prefix.isEmpty ? "\(offset + 1)" : "\(prefix).\(offset + 1)", into: &parts)
            }
            return
        }
        guard list.count >= 7, let type = list[0].string?.uppercased(), let subtype = list[1].string?.uppercased(),
              let sizeText = list[6].string, let size = Int(sizeText), size >= 0 else { return }
        let dispositionIndex = type == "TEXT" ? 9 : type == "MESSAGE" && subtype == "RFC822" ? 11 : 8
        let disposition = list.count > dispositionIndex ? list[dispositionIndex].list : nil
        let parameters = disposition.flatMap { $0.count > 1 ? $0[1].list : nil }
        let filename = parameter("FILENAME", in: parameters) ?? parameter("NAME", in: list[2].list) ?? ""
        guard !filename.isEmpty else { return }
        parts.append(Part(id: prefix.isEmpty ? "1" : prefix, filename: decodeWords(filename),
            encoding: list[5].string?.uppercased() ?? "7BIT", disposition: disposition?.first?.string?.uppercased() ?? "", size: size))
    }
    private static func parameter(_ key: String, in nodes: [Node]?) -> String? {
        guard let nodes else { return nil }
        var params: [String: String] = [:]
        for index in stride(from: 0, to: nodes.count - 1, by: 2) {
            if let name = nodes[index].string, let value = nodes[index + 1].string { params[name.uppercased()] = value }
        }
        if let extended = params[key + "*"] { return decodeExtended(extended) }
        var segments: [String] = []
        var extended = false
        var index = 0
        while let part = params[key + "*\(index)*"] ?? params[key + "*\(index)"] {
            extended = extended || params[key + "*\(index)*"] != nil
            segments.append(part)
            index += 1
        }
        if !segments.isEmpty { return extended ? decodeExtended(segments.joined()) : segments.joined() }
        return params[key]
    }
    private static func decodeExtended(_ value: String) -> String {
        let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        let charset = pieces.count == 3 ? String(pieces[0]) : "UTF-8"
        let body = pieces.count == 3 ? String(pieces[2]) : value
        var bytes: [UInt8] = []
        let raw = Array(body.utf8)
        var i = 0
        while i < raw.count {
            if raw[i] == 37, i + 2 < raw.count, let byte = UInt8(String(decoding: raw[i + 1...i + 2], as: UTF8.self), radix: 16) {
                bytes.append(byte); i += 3
            } else { bytes.append(raw[i]); i += 1 }
        }
        return decodeText(Data(bytes), charset: charset)
    }
    static func decodeWords(_ value: String) -> String {
        let expression = try! NSRegularExpression(pattern: #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#)
        let ns = value as NSString
        let matches = expression.matches(in: value, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return value }
        var output = ""
        var end = 0
        var previousEncoded = false
        for match in matches {
            let gap = ns.substring(with: NSRange(location: end, length: match.range.location - end))
            if !previousEncoded || !gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output += gap }
            let charset = ns.substring(with: match.range(at: 1))
            let encoding = ns.substring(with: match.range(at: 2)).uppercased()
            let body = ns.substring(with: match.range(at: 3))
            let data = encoding == "B" ? Data(base64Encoded: body) : try? decodeAttachment(Data(body.replacingOccurrences(of: "_", with: " ").utf8), encoding: "QUOTED-PRINTABLE")
            output += data.map { decodeText($0, charset: charset) } ?? ns.substring(with: match.range)
            end = NSMaxRange(match.range)
            previousEncoded = true
        }
        output += ns.substring(from: end)
        return output
    }
    private static func decodeText(_ data: Data, charset: String) -> String {
        let encoding: String.Encoding
        switch charset.uppercased() {
        case "GB2312", "GBK", "GB18030": encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "ISO-8859-1": encoding = .isoLatin1
        default: encoding = .utf8
        }
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }
    static func decodeAttachment(_ data: Data, encoding: String) throws -> Data {
        switch encoding.uppercased() {
        case "BASE64":
            let clean = data.filter { ![9, 10, 13, 32].contains($0) }
            guard let decoded = Data(base64Encoded: clean) else { throw QQMailboxError.malformed }
            return decoded
        case "QUOTED-PRINTABLE":
            let bytes = Array(data)
            var decoded: [UInt8] = []
            var index = 0
            while index < bytes.count {
                if bytes[index] == 61 {
                    if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 { index += 3; continue }
                    if index + 1 < bytes.count, bytes[index + 1] == 10 { index += 2; continue }
                    guard index + 2 < bytes.count, let byte = UInt8(String(decoding: bytes[index + 1...index + 2], as: UTF8.self), radix: 16) else { throw QQMailboxError.malformed }
                    decoded.append(byte); index += 3
                } else { decoded.append(bytes[index]); index += 1 }
            }
            return Data(decoded)
        case "7BIT", "8BIT", "BINARY": return data
        default: throw QQMailboxError.malformed
        }
    }
    private static func headers(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var unfolded: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.first == " " || line.first == "\t", !unfolded.isEmpty { unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces) }
            else { unfolded.append(line) }
        }
        var result: [String: String] = [:]
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            result[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
    private static func capture(_ pattern: String, in value: String) -> String? {
        let expression = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let ns = value as NSString
        guard let match = expression.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}
