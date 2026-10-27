#if DIRECT_TEST_RUNNER
import Foundation

@main struct InvoiceDocumentCheck {
    static func main() {
        precondition(!InvoiceDocumentClassifier.shouldList(filename: "滴滴行程单.pdf", subject: "电子发票已开具"))
        precondition(!InvoiceDocumentClassifier.shouldList(filename: "发票报销单.pdf", subject: "发票"))
        precondition(!InvoiceDocumentClassifier.shouldList(filename: "发票清单.pdf", subject: "发票"))
        precondition(InvoiceDocumentClassifier.shouldList(filename: "电子发票（航空运输电子客票行程单）.pdf", subject: ""))
        precondition(InvoiceDocumentClassifier.shouldList(filename: "航空运输电子客票行程单.pdf", subject: ""))
        precondition(InvoiceDocumentClassifier.shouldList(filename: "发票及行程单.zip", subject: ""))
        precondition(InvoiceDocumentClassifier.shouldList(filename: "7C55D9E1.pdf", subject: "您的电子发票"))
        precondition(!InvoiceDocumentClassifier.shouldList(filename: "7C55D9E1.pdf", subject: "会议材料"))
        let invoice = "电子发票（普通发票）\n发票号码：12345678901234567890\n开票日期：2026年10月27日\n购买方信息\n销售方信息\n价税合计（大写）（小写）\n¥127.46"
        precondition(InvoiceDocumentClassifier.classify(text: invoice, filename: "行程单.pdf").kind == .invoice, "Strong invoice content overrides filename hints")
        let reordered = "电子发票（普通发票）\n发票号码：\n开票日期：\n12345678901234567890\n2026年10月27日\n购买方信息\n销售方信息\n价税合计\n127.46"
        precondition(InvoiceDocumentClassifier.classify(text: reordered, filename: "uuid.pdf").kind == .invoice, "PDF field values can be reordered independently from labels")
        let trip = "滴滴出行行程单\n行程起止日期\n合计金额127.46\n此行程单非发票，请以电子发票作为报销凭证\n发票号码详见邮件"
        precondition(InvoiceDocumentClassifier.classify(text: trip, filename: "电子发票.pdf").kind == .nonInvoice)
        let report = "费用报销单\n电子发票报销明细\n发票号码 开票日期 购买方 销售方 价税合计\n12345678 2026-10-27 合计127.46"
        precondition(InvoiceDocumentClassifier.classify(text: report, filename: "发票.pdf").kind == .nonInvoice)
        let flight = "电子发票（航空运输电子客票行程单）\n发票号码：12345678901234567890\n开票日期：2026年10月27日\n购买方名称\n销售方名称\n价税合计127.46"
        precondition(InvoiceDocumentClassifier.classify(text: flight, filename: "电子行程单.pdf").kind == .invoice)
        let rail = "电子发票（铁路电子客票）\n发票号码：12345678901234567890\n开票日期：2026年10月27日\n购买方名称\n价税合计127.46"
        precondition(InvoiceDocumentClassifier.classify(text: rail, filename: "车票.pdf").kind == .invoice)
        precondition(InvoiceDocumentClassifier.classify(text: "普通PDF附件\n127.46", filename: "电子发票.pdf").kind == .unknown)
        precondition(InvoiceDocumentClassifier.classify(text: "", filename: "未知.pdf").kind == .unknown)
        let red = invoice.replacingOccurrences(of: "127.46", with: "-127.46")
        precondition(InvoiceDocumentClassifier.classify(text: red, filename: "红字发票.pdf").kind == .invoice)
        precondition(InvoiceDocumentClassifier.classify(text: "电子发票说明书\n开票日期和发票号码填写说明", filename: "发票说明.pdf").kind != .invoice)
        print("Invoice attachment classification checks passed (offline)")
    }
}
#endif
