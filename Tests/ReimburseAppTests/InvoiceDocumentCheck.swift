#if DIRECT_TEST_RUNNER
import Foundation
import PDFKit
import AppKit

@main struct InvoiceDocumentCheck {
    static let invoice = """
    电子发票（普通发票）
    发票号码：12345678901234567890
    开票日期：2026年10月27日
    购买方信息
    名称：北京测试有限公司
    纳税人识别号：91110108123456789X
    销售方信息
    名称：上海测试有限公司
    纳税人识别号：91310101123456789X
    不含税金额：36.79
    税额合计：2.21
    价税合计（小写）：39.00
    """
    static func main() throws {
        var count = 0
        func check(_ text: String, _ kind: InvoiceDocumentKind) {
            let result = InvoiceDocumentClassifier.classify(text: text, filename: "电子发票.pdf")
            precondition(result.kind == kind, "expected \(kind), got \(result): \(text)")
            count += 1
        }
        check(invoice, .invoice)
        check(invoice.replacingOccurrences(of: "（", with: "").replacingOccurrences(of: "）", with: ""), .invoice)
        check(invoice.replacingOccurrences(of: "普通发票", with: "增值税专用发票"), .invoice)
        let legacy = invoice.replacingOccurrences(of: "电子发票（普通发票）", with: "北京增值税电子普通发票").replacingOccurrences(of: "12345678901234567890", with: "12345678") + "\n发票代码：011001900111"
        check(legacy, .invoice)
        check(legacy.replacingOccurrences(of: "普通发票", with: "专用发票"), .invoice)
        for title in ["滴滴行程单", "酒店住宿明细", "订单详情", "消费清单", "付款凭证", "电子发票（铁路电子客票）", "电子发票（航空运输电子客票行程单）"] {
            check(title + "\n" + invoice, .nonInvoice)
        }
        check("订单明细\n发票号码：12345678901234567890\n税额合计：2.21\n" + invoice, .nonInvoice)
        check(invoice.replacingOccurrences(of: "39.00", with: "139.00"), .unknown)
        check(invoice + "\n发票号码：99999999999999999999", .unknown)
        check(invoice + "\n价税合计（小写）：40.00", .unknown)
        check(invoice.replacingOccurrences(of: "2026年10月27日", with: "2026年02月30日"), .unknown)
        check(invoice.replacingOccurrences(of: "销售方信息", with: ""), .unknown)
        check(invoice.replacingOccurrences(of: "发票号码：12345678901234567890", with: "发票号码：\n开票日期：2026年10月27日\n12345678901234567890"), .unknown)
        check(invoice.replacingOccurrences(of: "纳税人识别号：91310101123456789X", with: "纳税人识别号："), .unknown)
        check("发票号码 开票日期 购买方 销售方 税额 价税合计\n12345678901234567890", .unknown)
        check("", .unknown)
        check(invoice.replacingOccurrences(of: "2.21", with: "0.00").replacingOccurrences(of: "36.79", with: "39.00"), .invoice)
        check(invoice.replacingOccurrences(of: "36.79", with: "-36.79").replacingOccurrences(of: "2.21", with: "-2.21").replacingOccurrences(of: "39.00", with: "-39.00"), .invoice)
        precondition(InvoiceDocumentClassifier.shouldList(filename: "滴滴行程单.pdf", subject: "您的发票"))
        precondition(InvoiceDocumentClassifier.shouldList(filename: "uuid.ofd", subject: "发票"))
        precondition(!InvoiceDocumentClassifier.shouldList(filename: "invoice.exe", subject: "发票"))
        check(invoice + "\n合计 99.00 2.21", .unknown)
        check(invoice + "\n不含税金额：99.00\n合计 36.79 2.21", .unknown)
        check(invoice.replacingOccurrences(of: "发票号码：", with: "电子发票（增值税专用发票）\n发票号码："), .unknown)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-invoice-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let xml = """
        <?xml version="1.0"?><Invoice><InvoiceTitle>电子发票（普通发票）</InvoiceTitle><InvoiceNo>12345678901234567890</InvoiceNo><IssueDate>2026年10月27日</IssueDate><Buyer><BuyerName>北京测试有限公司</BuyerName><BuyerTaxID>91110108123456789X</BuyerTaxID></Buyer><Seller><SellerName>上海测试有限公司</SellerName><SellerTaxID>91310101123456789X</SellerTaxID></Seller><TaxExclusiveTotalAmount>36.79</TaxExclusiveTotalAmount><TaxTotalAmount>2.21</TaxTotalAmount><TaxInclusiveTotalAmount>39.00</TaxInclusiveTotalAmount></Invoice>
        """
        let xmlURL = directory.appendingPathComponent("sample.xml")
        try Data(xml.utf8).write(to: xmlURL)
        precondition(InvoiceDocumentClassifier.classify(at: xmlURL, text: "", filename: "bad.xml").kind == .invoice)
        try Data(xml.replacingOccurrences(of: "<Invoice>", with: "<Order>").replacingOccurrences(of: "</Invoice>", with: "</Order>").utf8).write(to: xmlURL)
        precondition(InvoiceDocumentClassifier.classify(at: xmlURL, text: invoice, filename: "invoice.xml").kind == .unknown)
        try Data("<?xml version=\"1.0\"?><!DOCTYPE Invoice [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><Invoice>&x;</Invoice>".utf8).write(to: xmlURL)
        precondition(InvoiceDocumentClassifier.classify(at: xmlURL, text: invoice, filename: "invoice.xml").kind == .unknown)
        let utf16DTD = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE Invoice [<!ENTITY x \"unexpected\">]><Invoice>&x;</Invoice>"
        try utf16DTD.data(using: .utf16LittleEndian)!.write(to: xmlURL)
        precondition(InvoiceDocumentClassifier.classify(at: xmlURL, text: invoice, filename: "invoice.xml").kind == .unknown)
        try Data(xml.replacingOccurrences(of: "</Invoice>", with: "<InvoiceNo>99999999999999999999</InvoiceNo></Invoice>").utf8).write(to: xmlURL)
        precondition(InvoiceDocumentClassifier.classify(at: xmlURL, text: invoice, filename: "invoice.xml").kind == .unknown)
        func nativePDF(_ pages: [String], to url: URL) {
            let data = NSMutableData()
            let consumer = CGDataConsumer(data: data)!
            var box = CGRect(x: 0, y: 0, width: 600, height: 850)
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
            for text in pages {
                context.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                    (line as NSString).draw(at: NSPoint(x: 30, y: 810 - index * 22), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
                }
                NSGraphicsContext.restoreGraphicsState()
                context.endPDFPage()
            }
            context.closePDF()
            precondition(data.write(to: url, atomically: true))
        }
        func embeddedPDF(_ xml: String, base: URL, name: String) throws -> URL {
            var data = try Data(contentsOf: base)
            let source = String(decoding: data, as: UTF8.self)
            func capture(_ pattern: String) -> String {
                let regex = try! NSRegularExpression(pattern: pattern)
                let match = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).last!
                return String(source[Range(match.range(at: 1), in: source)!])
            }
            let size = Int(capture(#"/Size\s+(\d+)"#))!
            let pages = capture(#"/Type\s*/Catalog\s*/Pages\s+(\d+\s+0\s+R)"#)
            let previous = capture(#"startxref\s+(\d+)"#)
            let payload = Data(xml.utf8)
            var offsets: [Int] = []
            let objects = [
                Data("<< /Type /Catalog /Pages \(pages) /Names << /EmbeddedFiles \(size + 1) 0 R >> >>".utf8),
                Data("<< /Kids [\(size + 4) 0 R] >>".utf8),
                Data("<< /Type /Filespec /F (invoice.xml) /EF << /F \(size + 3) 0 R >> >>".utf8),
                Data("<< /Type /EmbeddedFile /Length \(payload.count) >>\nstream\n".utf8) + payload + Data("\nendstream".utf8),
                Data("<< /Names [(invoice.xml) \(size + 2) 0 R] >>".utf8)
            ]
            data.append(Data("\n".utf8))
            for (index, object) in objects.enumerated() {
                offsets.append(data.count)
                data.append(Data("\(size + index) 0 obj\n".utf8)); data.append(object); data.append(Data("\nendobj\n".utf8))
            }
            let xref = data.count
            data.append(Data("xref\n\(size) \(objects.count)\n".utf8))
            for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
            data.append(Data("trailer\n<< /Size \(size + objects.count) /Root \(size) 0 R /Prev \(previous) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
            let destination = directory.appendingPathComponent(name)
            try data.write(to: destination)
            return destination
        }
        let nativeURL = directory.appendingPathComponent("native.pdf")
        nativePDF([invoice], to: nativeURL)
        precondition(InvoiceDocumentClassifier.classify(at: nativeURL, text: "", filename: "neutral.pdf").kind == .invoice)
        let embedded = try embeddedPDF(xml, base: nativeURL, name: "embedded.pdf")
        precondition(LocalInvoiceContent.embeddedInvoices(at: embedded).texts.count == 1, "Embedded XML name-tree Kids must be read")
        precondition(InvoiceDocumentClassifier.classify(at: embedded, text: "", filename: "embedded.pdf").kind == .invoice)
        let conflict = try embeddedPDF(xml.replacingOccurrences(of: "上海测试有限公司", with: "另外一家有限公司"), base: nativeURL, name: "conflict.pdf")
        precondition(InvoiceDocumentClassifier.classify(at: conflict, text: "", filename: "conflict.pdf").kind == .unknown, "Embedded and visible seller must agree")
        let taxConflict = try embeddedPDF(xml.replacingOccurrences(of: "36.79", with: "35.79").replacingOccurrences(of: "2.21", with: "3.21"), base: nativeURL, name: "tax-conflict.pdf")
        precondition(InvoiceDocumentClassifier.classify(at: taxConflict, text: "", filename: "tax-conflict.pdf").kind == .unknown, "Balanced but different embedded tax must not pass")
        nativePDF([legacy], to: nativeURL)
        precondition(InvoiceDocumentClassifier.classify(at: nativeURL, text: "", filename: "neutral.pdf").kind == .invoice)
        nativePDF([invoice, "酒店住宿明细\n发票号码和税额仅供参考"], to: nativeURL)
        precondition(InvoiceDocumentClassifier.classify(at: nativeURL, text: invoice, filename: "invoice.pdf").kind == .unknown)
        let malformedOFD = directory.appendingPathComponent("invalid.ofd")
        try Data("not a zip".utf8).write(to: malformedOFD)
        precondition(InvoiceDocumentClassifier.classify(at: malformedOFD, text: invoice, filename: "invoice.ofd").kind == .unknown)
        let image = NSImage(size: NSSize(width: 600, height: 800))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 800).fill(); image.unlockFocus()
        let scanned = PDFDocument(); scanned.insert(PDFPage(image: image)!, at: 0)
        let pdfURL = directory.appendingPathComponent("scanned.pdf")
        precondition(scanned.write(to: pdfURL))
        precondition(InvoiceDocumentClassifier.classify(at: pdfURL, text: invoice, filename: "invoice.pdf").kind == .unknown)
        let encryptedURL = directory.appendingPathComponent("encrypted.pdf")
        precondition(scanned.write(to: encryptedURL, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        precondition(InvoiceDocumentClassifier.classify(at: encryptedURL, text: invoice, filename: "invoice.pdf").kind == .unknown)
        let imageURL = directory.appendingPathComponent("invoice.tiff")
        try image.tiffRepresentation!.write(to: imageURL)
        precondition(InvoiceDocumentClassifier.classify(at: imageURL, text: invoice, filename: "invoice.tiff").kind == .unknown)
        for argument in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: argument)
            let result = InvoiceDocumentClassifier.classify(at: url, text: "", filename: url.lastPathComponent)
            if url.pathExtension == "ofd" { precondition(result.kind == .invoice, "Reference OFD must pass structured checks") }
            print("Real fixture \(url.lastPathComponent): \(result.kind) — \(result.reason)")
        }
        print("Local invoice filter checks passed: \(count) text cases; structured XML, unknown XML, DTD, scanned/encrypted PDF, image input checked. Fixtures retained: \(directory.path)")
    }
}
#endif
