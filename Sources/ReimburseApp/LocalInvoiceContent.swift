import Foundation
import PDFKit
import CoreGraphics

// Local, bounded structural extraction. Unsupported schemas stay pending rather than becoming invoices.
enum LocalInvoiceContent {
    static func read(at url: URL) -> (text: String, reason: String?) {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 25 * 1024 * 1024 else { return ("", "附件超过25MB本地筛选上限。") }
            switch url.pathExtension.lowercased() {
            case "pdf":
                guard let pdf = PDFDocument(url: url), !pdf.isEncrypted, !pdf.isLocked, pdf.pageCount > 0, pdf.pageCount <= 100 else { return ("", "PDF 加密、损坏或页数超过检查上限。") }
                return (pdf.string ?? "", nil)
            case "xml":
                let root = try parse(Data(contentsOf: url))
                return try invoiceXML(root)
            case "ofd": return try ofd(url)
            default: return ("", "图片或扫描件缺少可靠的结构化票面，保留为待确认。")
            }
        } catch { return ("", "文件内部结构无法安全解析，保留为待确认。") }
    }

    static func embeddedInvoices(at url: URL) -> (texts: [String], reason: String?) {
        embeddedInvoices(document: CGPDFDocument(url as CFURL))
    }
    static func embeddedInvoices(in data: Data) -> (texts: [String], reason: String?) {
        guard let provider = CGDataProvider(data: data as CFData) else { return ([], "PDF内部结构无法读取。") }
        return embeddedInvoices(document: CGPDFDocument(provider))
    }
    private static func embeddedInvoices(document: CGPDFDocument?) -> (texts: [String], reason: String?) {
        guard let pdf = document, let catalog = pdf.catalog else { return ([], "PDF内部结构无法读取。") }
        var names: CGPDFDictionaryRef?
        var tree: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names,
              CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &tree), let tree else { return ([], nil) }
        var texts: [String] = []
        var visited = 0
        var total = 0
        func file(_ spec: CGPDFDictionaryRef) throws {
            var filename: CGPDFStringRef?
            if !CGPDFDictionaryGetString(spec, "UF", &filename) { _ = CGPDFDictionaryGetString(spec, "F", &filename) }
            guard let filename, let copied = CGPDFStringCopyTextString(filename), (copied as String).lowercased().hasSuffix(".xml") else { return }
            var ef: CGPDFDictionaryRef?
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetDictionary(spec, "EF", &ef), let ef,
                  CGPDFDictionaryGetStream(ef, "F", &stream) || CGPDFDictionaryGetStream(ef, "UF", &stream), let stream else { throw CocoaError(.fileReadCorruptFile) }
            var format = CGPDFDataFormat.raw
            guard let bytes = CGPDFStreamCopyData(stream, &format) else { throw CocoaError(.fileReadCorruptFile) }
            let data = bytes as Data
            total += data.count
            guard data.count <= 2 * 1024 * 1024, total <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let root = try parse(data)
            // Other XML attachments are not invoice evidence; only this supported payload is compared.
            if ["Invoice", "EInvoice", "root"].contains(root.name), root.child("InvoiceNo") != nil {
                let content = try invoiceXML(root)
                guard content.reason == nil else { throw CocoaError(.fileReadCorruptFile) }
                texts.append(content.text)
            }
        }
        func visit(_ node: CGPDFDictionaryRef, depth: Int) throws {
            visited += 1
            guard depth <= 8, visited <= 64 else { throw CocoaError(.fileReadTooLarge) }
            var entries: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Names", &entries), let entries {
                let count = CGPDFArrayGetCount(entries)
                guard count % 2 == 0, count <= 64 else { throw CocoaError(.fileReadCorruptFile) }
                for index in stride(from: 1, to: count, by: 2) {
                    var spec: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(entries, index, &spec), let spec else { throw CocoaError(.fileReadCorruptFile) }
                    try file(spec)
                }
            }
            var children: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Kids", &children), let children {
                guard CGPDFArrayGetCount(children) <= 32 else { throw CocoaError(.fileReadTooLarge) }
                for index in 0..<CGPDFArrayGetCount(children) {
                    var child: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(children, index, &child), let child else { throw CocoaError(.fileReadCorruptFile) }
                    try visit(child, depth: depth + 1)
                }
            }
        }
        do { try visit(tree, depth: 0); return (texts, nil) }
        catch { return ([], "PDF内嵌XML结构异常、超出读取上限或存在冲突，保留待确认。") }
    }

    static func pageText(_ page: PDFPage) -> String {
        guard let raw = page.string, (raw as NSString).length <= 20000 else { return "" }
        let source = raw as NSString
        var rows: [[(text: String, box: CGRect)]] = []
        for index in 0..<source.length {
            let token = source.substring(with: NSRange(location: index, length: 1)).precomposedStringWithCompatibilityMapping
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let box = page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page), box.width > 0, box.height > 0 else { continue }
            if let row = rows.firstIndex(where: { abs(($0.first?.box.midY ?? 0) - box.midY) < min($0.first?.box.height ?? 0, box.height) * 0.45 }) {
                rows[row].append((token, box))
            } else {
                guard rows.count < 2000 else { return "" }
                rows.append([(token, box)])
            }
        }
        rows.sort { ($0.first?.box.midY ?? 0) > ($1.first?.box.midY ?? 0) }
        let sortedRows = rows.map { $0.sorted { $0.box.minX < $1.box.minX } }
        var lines = sortedRows.map { $0.map(\.text).joined() }
        // Real PDFs often store values separately from their labels; reconstruct spatial rows first.
        lines = lines.flatMap { line -> [String] in
            guard let range = line.range(of: "发票号码"), line[..<range.lowerBound].contains("电子") else { return [line] }
            return [String(line[..<range.lowerBound]), String(line[range.lowerBound...])]
        }
        // Buyer and seller fields share a horizontal row. Keep each side in its own labeled block.
        if let rowIndex = sortedRows.firstIndex(where: { row in row.map(\.text).joined().components(separatedBy: "名称").count == 3 }) {
            let nameRow = sortedRows[rowIndex]
            let nameText = nameRow.map(\.text).joined() as NSString
            let first = nameText.range(of: "名称")
            let second = nameText.range(of: "名称", range: NSRange(location: first.location + first.length, length: nameText.length - first.location - first.length))
            if second.location != NSNotFound, first.location < nameRow.count, second.location < nameRow.count {
                let left = nameRow[first.location].box.minX
                let right = nameRow[second.location].box.minX
                let y = nameRow[first.location].box.midY
                let partyRows = sortedRows.map { row in row.filter { $0.box.midY <= y + 3 && $0.box.midY >= y - 30 } }.filter { !$0.isEmpty }
                var partyLines: [String] = []
                for (title, lower, upper) in [("购买方信息", left - 1, right - 20), ("销售方信息", right - 1, page.bounds(for: .cropBox).maxX)] {
                    partyLines.append(title)
                    partyLines += partyRows.map { row in row.filter { $0.box.minX >= lower && $0.box.minX < upper }.map(\.text).joined() }
                }
                lines += partyLines
            }
        }
        for label in ["发票号码", "发票代码", "开票日期"] {
            let value = label == "开票日期" ? #"[0-9]{4}[年./-][0-9]{1,2}[月./-][0-9]{1,2}日?"# : #"[0-9]{8,20}"#
            let expression = try! NSRegularExpression(pattern: label + "[:：\\s]*(" + value + ")")
            for match in expression.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                if let range = Range(match.range(at: 1), in: raw) { lines.append(label + ":" + raw[range]) }
            }
        }
        return lines.joined(separator: "\n")
    }

    private final class Node {
        let name: String
        let attributes: [String: String]
        var text = ""
        var children: [Node] = []
        init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
        func child(_ name: String) -> Node? { let matches = children.filter { $0.name == name }; return matches.count == 1 ? matches[0] : nil }
        func path(_ names: String...) -> Node? { names.reduce(Optional(self)) { $0?.child($1) } }
        func descendants(_ name: String) -> [Node] { (self.name == name ? [self] : []) + children.flatMap { $0.descendants(name) } }
        var value: String { (text + children.map(\.value).joined()).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    private final class Reader: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        var count = 0
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            count += 1
            guard count <= 50000, stack.count < 64 else { parser.abortParsing(); return }
            let node = Node(elementName.components(separatedBy: ":").last!, attributeDict)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if !stack.isEmpty { stack.removeLast() } }
    }
    private static func parse(_ data: Data) throws -> Node {
        guard data.count <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        // Reject DTD even when encoded UTF-16; XMLParser never resolves external entities.
        let probe = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
        guard !probe.replacingOccurrences(of: "\0", with: "").uppercased().contains("<!DOCTYPE"), !probe.replacingOccurrences(of: "\0", with: "").uppercased().contains("<!ENTITY") else { throw CocoaError(.fileReadCorruptFile) }
        let reader = Reader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), let root = reader.root else { throw CocoaError(.fileReadCorruptFile) }
        return root
    }
    private static func invoiceXML(_ root: Node) throws -> (text: String, reason: String?) {
        // This concrete schema is the tax invoice payload used by OFD original_invoice.xml.
        guard ["Invoice", "EInvoice", "root"].contains(root.name),
              let buyer = root.child("Buyer"), let seller = root.child("Seller"),
              root.child("InvoiceNo") != nil, root.child("TaxInclusiveTotalAmount") != nil else {
            return ("", "XML 不属于已支持的发票结构，未按任意同名标签认定为发票。")
        }
        let critical = Set(["InvoiceTitle", "Title", "InvoiceNo", "InvoiceCode", "IssueDate", "Buyer", "Seller", "TaxExclusiveTotalAmount", "TaxTotalAmount", "TaxInclusiveTotalAmount"])
        guard critical.allSatisfy({ name in root.children.filter { $0.name == name }.count <= 1 }) else { return ("", "XML存在重复关键字段，不能自动确认。") }
        if let first = root.child("InvoiceTitle"), let second = root.child("Title"), first.value != second.value { return ("", "XML票种标题冲突。") }
        let scalarNames = ["InvoiceTitle", "Title", "InvoiceNo", "InvoiceCode", "IssueDate", "TaxExclusiveTotalAmount", "TaxTotalAmount", "TaxInclusiveTotalAmount"]
        let scalars = scalarNames.compactMap { root.child($0) } + [buyer.child("BuyerName"), buyer.child("BuyerTaxID"), seller.child("SellerName"), seller.child("SellerTaxID")].compactMap { $0 }
        guard scalars.allSatisfy({ $0.children.isEmpty && !$0.value.contains("\n") && !$0.value.contains("\r") }) else {
            return ("", "XML关键字段不是独立标量，保留待确认。")
        }
        guard root.descendants("ObjectRef").isEmpty else { return ("", "XML 引用OFD票面对象，需要完整OFD容器。") }
        let title = root.child("InvoiceTitle")?.value ?? root.child("Title")?.value ?? ""
        return (canonical(title: title, fields: [
            "InvoiceNo": root.child("InvoiceNo")?.value ?? "", "InvoiceCode": root.child("InvoiceCode")?.value ?? "",
            "IssueDate": root.child("IssueDate")?.value ?? "", "BuyerName": buyer.child("BuyerName")?.value ?? "",
            "BuyerTaxID": buyer.child("BuyerTaxID")?.value ?? "", "SellerName": seller.child("SellerName")?.value ?? "",
            "SellerTaxID": seller.child("SellerTaxID")?.value ?? "", "TaxExclusiveTotalAmount": root.child("TaxExclusiveTotalAmount")?.value ?? "",
            "TaxTotalAmount": root.child("TaxTotalAmount")?.value ?? "", "TaxInclusiveTotalAmount": root.child("TaxInclusiveTotalAmount")?.value ?? ""
        ]), nil)
    }
    private static func canonical(title: String, fields: [String: String]) -> String {
        """
        \(title)
        发票号码：\(fields["InvoiceNo"] ?? "")
        发票代码：\(fields["InvoiceCode"] ?? "")
        开票日期：\(fields["IssueDate"] ?? "")
        购买方信息
        名称：\(fields["BuyerName"] ?? "")
        纳税人识别号：\(fields["BuyerTaxID"] ?? "")
        销售方信息
        名称：\(fields["SellerName"] ?? "")
        纳税人识别号：\(fields["SellerTaxID"] ?? "")
        不含税金额：\(fields["TaxExclusiveTotalAmount"] ?? "")
        税额合计：\(fields["TaxTotalAmount"] ?? "")
        价税合计（小写）：\(fields["TaxInclusiveTotalAmount"] ?? "")
        """
    }

    private static func ofd(_ url: URL) throws -> (text: String, reason: String?) {
        let listing = try unzip(url, arguments: ["-Z1"], limit: 512 * 1024)
        guard let namesText = String(data: listing, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        let names = namesText.split(separator: "\n").map(String.init)
        guard names.count <= 500, Set(names).count == names.count,
              names.allSatisfy({ !$0.hasPrefix("/") && !$0.contains("\\") && !$0.split(separator: "/").contains("..") && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && !$0.contains(where: { "*:?[]".contains($0) }) }), names.contains("OFD.xml") else { throw CocoaError(.fileReadCorruptFile) }
        var budget = 16 * 1024 * 1024
        func xml(_ name: String) throws -> Node {
            guard names.contains(name), name.lowercased().hasSuffix(".xml"), budget > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let data = try unzip(url, arguments: ["-p", name], limit: min(budget, 2 * 1024 * 1024))
            budget -= data.count
            return try parse(data)
        }
        func resolve(_ reference: String, relativeTo base: String) throws -> String {
            guard !reference.hasPrefix("/"), !reference.contains("\\"), !reference.contains(":") else { throw CocoaError(.fileReadCorruptFile) }
            let path = ((base as NSString).deletingLastPathComponent as NSString).appendingPathComponent(reference)
            let normalized = (path as NSString).standardizingPath
            guard !normalized.hasPrefix("../"), names.contains(normalized) else { throw CocoaError(.fileReadCorruptFile) }
            return normalized
        }
        let envelope = try xml("OFD.xml")
        guard envelope.name == "OFD", envelope.children.filter({ $0.name == "DocBody" }).count == 1,
              let docRoot = envelope.path("DocBody", "DocRoot")?.value else { return ("", "OFD结构不完整或包含多个文档。") }
        let documentPath = try resolve(docRoot, relativeTo: "OFD.xml")
        let document = try xml(documentPath)
        guard document.name == "Document", let pages = document.child("Pages"), pages.children.count == 1,
              let page = pages.child("Page"), let pageID = page.attributes["ID"], let pageLoc = page.attributes["BaseLoc"] else { return ("", "OFD仅对单张完整票面自动筛选；多页或不完整文档保留待确认。") }
        let pageRoot = try xml(resolve(pageLoc, relativeTo: documentPath))
        var objects: [String: String] = [:]
        for object in pageRoot.descendants("TextObject") {
            guard let id = object.attributes["ID"], objects[id] == nil else { throw CocoaError(.fileReadCorruptFile) }
            objects[id] = object.descendants("TextCode").map(\.value).joined()
        }
        var titleTexts = pageRoot.descendants("TextCode").map(\.value)
        for template in document.path("CommonData")?.children.filter({ $0.name == "TemplatePage" }) ?? [] {
            if let path = template.attributes["BaseLoc"] { titleTexts += try xml(resolve(path, relativeTo: documentPath)).descendants("TextCode").map(\.value) }
        }
        let title = titleTexts.first { $0.contains("电子发票") || $0.contains("增值税电子") } ?? ""
        guard let tagsLoc = document.child("CustomTags")?.value else { return ("", "OFD缺少已支持的发票字段映射。") }
        let tagsPath = try resolve(tagsLoc, relativeTo: documentPath)
        let tags = try xml(tagsPath)
        guard let tag = tags.children.first(where: { $0.name == "CustomTag" && $0.attributes["TypeID"] == "root" }), let fieldLoc = tag.child("FileLoc")?.value else { return ("", "OFD未找到受支持的发票结构标签。") }
        let fieldsRoot = try xml(resolve(fieldLoc, relativeTo: tagsPath))
        guard fieldsRoot.name == "root" else { return ("", "OFD发票字段根结构无法确认。") }
        func value(_ node: Node?) throws -> String {
            guard let node else { return "" }
            let refs = node.children.filter { $0.name == "ObjectRef" }
            guard !refs.isEmpty, refs.count == node.children.count else { throw CocoaError(.fileReadCorruptFile) }
            return try refs.map { ref in
                guard ref.attributes["PageRef"] == pageID, let text = objects[ref.value] else { throw CocoaError(.fileReadCorruptFile) }
                return text
            }.joined()
        }
        var fields: [String: String] = [:]
        for name in ["InvoiceNo", "InvoiceCode", "IssueDate", "TaxExclusiveTotalAmount", "TaxTotalAmount", "TaxInclusiveTotalAmount"] { fields[name] = try value(fieldsRoot.child(name)) }
        for party in ["Buyer", "Seller"] {
            for suffix in ["Name", "TaxID"] { fields[party + suffix] = try value(fieldsRoot.child(party)?.child(party + suffix)) }
        }
        let metadata = envelope.path("DocBody", "DocInfo", "CustomDatas")?.children ?? []
        for (label, key) in [("发票号码", "InvoiceNo"), ("购买方纳税人识别号", "BuyerTaxID"), ("销售方纳税人识别号", "SellerTaxID")] {
            if metadata.filter({ $0.attributes["Name"] == label }).contains(where: { $0.value != fields[key] }) {
                return ("", "OFD内部元数据与票面字段冲突。")
            }
        }
        return (canonical(title: title, fields: fields), nil)
    }
    private static func unzip(_ url: URL, arguments: [String], limit: Int) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments.first == "-Z1" ? arguments + [url.path] : [arguments[0], url.path] + Array(arguments.dropFirst())
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: min(65536, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            if data.count > limit { process.terminate(); process.waitUntilExit(); throw CocoaError(.fileReadTooLarge) }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}
