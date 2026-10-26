#if DIRECT_TEST_RUNNER
import AppKit
import Foundation
import PDFKit

@main struct InvoicePartyCheck {
    static func fixture(buyer: String?, seller: String?, invertedDrawingOrder: Bool, omitSellerRole: Bool = false, horizontalHeaders: Bool = false, farSideText: Bool = false) throws -> URL {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage([kCGPDFContextMediaBox as String: CGRect(x: 0, y: 0, width: 600, height: 430)] as CFDictionary)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10)]
        func draw(_ value: String, _ x: Double, _ y: Double) { (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes) }
        func role(_ value: String, _ x: Double) {
            if horizontalHeaders { draw(value, x, 370) }
            else { for (index, c) in value.enumerated() { draw(String(c), x, 350 - Double(index) * 12) } }
        }
        if invertedDrawingOrder { draw("名称：", 322, 347); if let buyer { draw(buyer, 61, 347) } }
        role("购买方信息", 18)
        draw("名称：", 36, 347)
        if !invertedDrawingOrder, let buyer { draw(buyer, 61, 347) }
        draw("纳税人识别号：示例", 36, 323)
        if !omitSellerRole { role("销售方信息", 304) }
        if !invertedDrawingOrder { draw("名称：", 322, 347) }
        if let seller { draw(seller, 347, 347) }
        draw("纳税人识别号：示例", 322, 323)
        if farSideText { draw("其他", 580, 347) }
        draw("项目名称", 70, 270)
        draw("*餐饮服务*餐费", 70, 240)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-party-\(UUID().uuidString).pdf")
        try (data as Data).write(to: url)
        return url
    }
    static func main() throws {
        let vertical = "购\n买\n方\n信\n息\n名 称：测试购买主体\n纳税人识别号：123\n销\n售\n方\n信\n息\n名称：张三\n*餐饮服务*餐费"
        let plain = InvoicePartyRecognition.details(in: vertical)
        precondition(plain.buyer == "测试购买主体" && plain.seller == "张三")
        for inverted in [false, true] {
            let url = try fixture(buyer: "测试购买主体", seller: "测试出售商店", invertedDrawingOrder: inverted)
            let text = PDFDocument(url: url)?.string ?? ""
            let parsed = try InvoicePartyRecognition.details(at: url, text: text)
            precondition(parsed.buyer == "测试购买主体" && parsed.seller == "测试出售商店", "Column roles must survive interleaved PDF extraction order")
        }
        let horizontal = try fixture(buyer: "测试购买主体", seller: "测试出售商店", invertedDrawingOrder: false, horizontalHeaders: true)
        let horizontalResult = try InvoicePartyRecognition.details(at: horizontal, text: PDFDocument(url: horizontal)?.string ?? "")
        precondition(horizontalResult.buyer == "测试购买主体" && horizontalResult.seller == "测试出售商店", "Horizontal role headers above the name must work")
        let noSellerRole = try fixture(buyer: "测试购买主体", seller: "测试出售商店", invertedDrawingOrder: true, omitSellerRole: true)
        let bounded = try InvoicePartyRecognition.details(at: noSellerRole, text: PDFDocument(url: noSellerRole)?.string ?? "")
        precondition(bounded.buyer == "测试购买主体" && bounded.seller.isEmpty, "Missing role must not merge the next name column")
        let separated = try fixture(buyer: "测试购买主体", seller: "测试出售商店", invertedDrawingOrder: true, farSideText: true)
        let separatedResult = try InvoicePartyRecognition.details(at: separated, text: PDFDocument(url: separated)?.string ?? "")
        precondition(separatedResult.seller == "测试出售商店", "A distant right margin label must not join a company name")
        let compatibility = InvoicePartyRecognition.details(in: "购买⽅信息\n名称：测试购买主体\n销售⽅信息\n名称：张三")
        precondition(compatibility.buyer == "测试购买主体" && compatibility.seller == "张三")
        let noBuyer = try fixture(buyer: nil, seller: "测试出售商店", invertedDrawingOrder: true)
        let absent = try InvoicePartyRecognition.details(at: noBuyer, text: PDFDocument(url: noBuyer)?.string ?? "")
        precondition(absent.buyer.isEmpty && absent.seller == "测试出售商店", "Missing buyer must never use seller name")
        let unlabeled = InvoicePartyRecognition.details(in: "名称：未知主体\n名称：另一主体")
        precondition(unlabeled.buyer.isEmpty && unlabeled.seller.isEmpty)
        let mixed = InvoicePartyRecognition.details(in: "购买方信息 销售方信息\n名称：测试购买主体 名称：测试出售商店")
        precondition(mixed.buyer.isEmpty && mixed.seller.isEmpty, "Ambiguous side-by-side plain text must remain unknown")
        print("Invoice party layout checks passed; temporary generated PDFs retained")
    }
}
#endif
