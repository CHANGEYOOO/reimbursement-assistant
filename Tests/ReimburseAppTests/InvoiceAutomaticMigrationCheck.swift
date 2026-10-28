#if DIRECT_TEST_RUNNER
import AppKit
import Foundation
@main struct InvoiceAutomaticMigrationCheck {
    @MainActor static func main() async throws {
        let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(previousArguments.merging(["reimbursement.ai.enabled": false, "reimbursement.ai.invoiceFallbackEnabled": false]) { _, test in test }, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-auto-migration-" + UUID().uuidString)
        let files = root.appendingPathComponent("invoices")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(consumer: CGDataConsumer(data: bytes)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let text = "电子发票（普通发票）\n发票号码：12345678901234567890\n开票日期：2026年10月27日\n购买方信息\n名称：北京测试有限公司\n销售方信息\n名称：上海测试有限公司\n价税合计（小写）：39.00"
        for (i, line) in text.components(separatedBy: .newlines).enumerated() {
            (line as NSString).draw(at: CGPoint(x: 30, y: 750 - i * 25), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        }
        NSGraphicsContext.restoreGraphicsState(); context.endPDFPage(); context.closePDF()
        var records: [Invoice] = []
        for index in 0..<4 {
            let id = UUID(), name = "\(index).pdf"
            try (bytes as Data).write(to: files.appendingPathComponent(name))
            records.append(Invoice(id: id, storedFilename: name, originalFilename: "历史发票金额39.00.pdf", fingerprint: id.uuidString,
                amount: index == 1 ? 999 : nil, warning: index == 3 ? "未识别到价税合计，请手动填写。" : "旧严格规则待确认", documentKind: index == 3 ? .invoice : .unknown, documentReason: "旧严格规则待确认", documentPolicyRevision: 3))
        }
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("invoices.json"))
        let store = InvoiceStore(); store.configure(directory: root)
        store.updateAmount("88", for: records[2].id)
        while !store.pendingIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        precondition(store.acceptedInvoices.count == 4)
        precondition(store.invoices[0].amount == 39, "Policy migration must restore missing amount")
        precondition(store.invoices[1].amount == 999, "Policy migration must preserve an existing positive amount")
        precondition(store.invoices[2].amount == 88, "Late recognition must preserve manual edits")
        precondition(store.invoices[3].amount == 39 && store.invoices[3].warning == nil, "Recovered amounts must clear their stale amount warning")
        precondition(store.invoices.allSatisfy { $0.warning == nil })
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try JSONEncoder().encode([Invoice]()).write(to: other.appendingPathComponent("invoices.json"))
        // Force another old-policy check, then switch immediately before its task can finish.
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("invoices.json"))
        store.configure(directory: root); store.configure(directory: other)
        try await Task.sleep(for: .milliseconds(150))
        precondition(store.invoices.isEmpty && store.pendingIDs.isEmpty, "Old project tasks must not alter the new project")
        print("Automatic migration amount recovery, manual amount protection, and directory-switch checks passed; fixtures retained: \(root.path)")
    }
}
#endif
