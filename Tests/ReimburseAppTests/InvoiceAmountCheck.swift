#if DIRECT_TEST_RUNNER
import AppKit
import Foundation
import PDFKit

@main struct InvoiceAmountCheck {
    static func fixture(totals: [String], negative: Bool = false) throws -> URL {
        let data = NSMutableData()
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: nil, nil)!
        for total in totals {
            context.beginPDFPage([kCGPDFContextMediaBox as String: CGRect(x: 0, y: 0, width: 600, height: 430)] as CFDictionary)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
            func draw(_ text: String, _ x: CGFloat, _ y: CGFloat) { (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes) }
            draw("价税合计（大写）", 20, 120)
            draw("（小写）", 400, 120)
            // Draw table totals after labels: extraction order is deliberately unrelated to visual rows.
            draw("¥123.75", 400, 145)
            draw("¥3.71", 530, 145)
            draw((negative ? "-¥" : "¥") + total, 460, 120)
            draw("金额 99999.99", 400, 230)
            draw("发票号码：12345678901234567890", 200, 350)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-amount-\(UUID().uuidString).pdf")
        try (data as Data).write(to: url)
        return url
    }
    static func main() throws {
        let url = try fixture(totals: ["127.46"])
        let text = PDFDocument(url: url)!.string!
        let one = try InvoiceAmountRecognition.total(at: url, text: text)
        precondition(one == Decimal(string: "127.46"))
        let imageDocument = PDFDocument(url: url)!
        let image = withExtendedLifetime(imageDocument) { imageDocument.page(at: 0)!.thumbnail(of: CGSize(width: 1800, height: 1290), for: .mediaBox) }
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-amount-image-\(UUID().uuidString).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
        let scanned = try InvoiceAmountRecognition.total(at: imageURL, text: "")
        precondition(scanned == Decimal(string: "127.46"), "Scanned invoice keeps the same spatial total rule")
        let multi = try fixture(totals: ["127.46", "88.00"])
        let many = try InvoiceAmountRecognition.total(at: multi, text: PDFDocument(url: multi)!.string!)
        precondition(many == nil)
        let negative = try fixture(totals: ["127.46"], negative: true)
        let red = try InvoiceAmountRecognition.total(at: negative, text: PDFDocument(url: negative)!.string!)
        precondition(red == nil)
        precondition(InvoiceAmountRecognition.total(in: "价税合计（小写）：￥1,234.50") == Decimal(string: "1234.50"))
        precondition(InvoiceAmountRecognition.total(in: "价 税 合 计\n（⼩写）\n￥ 1 2 7 . 4 6") == Decimal(string: "127.46"))
        precondition(InvoiceAmountRecognition.total(in: "发票号码12345678901234567890\n金额123.75\n税额3.71") == nil)
        precondition(InvoiceAmountRecognition.total(in: "价税合计（小写）-￥127.46") == nil)
        precondition(InvoiceAmountRecognition.total(in: "价税合计（小写）￥-127.46") == nil)
        precondition(InvoiceAmountRecognition.total(in: "价税合计（小写）¥88.00，税前金额¥80.00 税额¥8.00") == nil)
        precondition(InvoiceAmountRecognition.total(in: "价税合计（小写）￥39.00\n税额0.00") == 39)
        precondition(InvoiceAmountRecognition.total(in: "价税合计 ¥39.00\n价税合计 ¥49.00") == nil)
        if CommandLine.arguments.count > 1 {
            let sample = URL(fileURLWithPath: CommandLine.arguments[1])
            let found = try InvoiceAmountRecognition.total(at: sample, text: PDFDocument(url: sample)?.string ?? "")
            precondition(found == Decimal(string: "127.46"))
            print("User invoice total matches expected amount")
        }
        print("Invoice amount label and layout checks passed; temporary fixtures retained")
    }
}
#endif
