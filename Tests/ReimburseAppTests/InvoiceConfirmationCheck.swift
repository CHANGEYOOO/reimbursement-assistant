#if DIRECT_TEST_RUNNER
import Foundation
import AppKit

@main struct InvoiceConfirmationCheck {
    @MainActor static func main() async throws {
        let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(previousArguments.merging(["reimbursement.ai.enabled": false, "reimbursement.ai.invoiceFallbackEnabled": false]) { _, test in test }, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoice-confirmation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func invoice(_ amount: Decimal?, warning: String? = nil) -> Invoice {
            Invoice(id: UUID(), storedFilename: "sample.pdf", originalFilename: "sample.pdf",
                    fingerprint: UUID().uuidString, amount: amount, warning: warning, documentKind: .invoice,
                    documentPolicyRevision: InvoiceDocumentClassifier.policyRevision)
        }
        let samples = [invoice(39), invoice(nil), invoice(0), invoice(-20), invoice(100, warning: "识别失败")]
        try JSONEncoder().encode(samples).write(to: directory.appendingPathComponent("invoices.json"))
        let store = InvoiceStore()
        store.configure(directory: directory)
        precondition(store.lastError == nil)
        precondition(store.total == 39 && store.confirmationCount == 4)
        precondition(!store.needsConfirmation(samples[0]))
        precondition(samples.dropFirst().allSatisfy(store.needsConfirmation))
        store.updateAmount("100", for: samples[4].id)
        precondition(store.total == 139 && store.confirmationCount == 3)
        store.updateAmount("", for: samples[0].id)
        precondition(store.total == 100 && store.confirmationCount == 4)
        let files = directory.appendingPathComponent("invoices", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let pdf = Invoice(id: UUID(), storedFilename: "a.pdf", originalFilename: "发票.pdf", fingerprint: "a", amount: 39, warning: nil, documentKind: .invoice, documentPolicyRevision: InvoiceDocumentClassifier.policyRevision)
        let image = Invoice(id: UUID(), storedFilename: "b.png", originalFilename: "发票.png", fingerprint: "b", amount: 100, warning: nil, documentKind: .invoice, documentPolicyRevision: InvoiceDocumentClassifier.policyRevision)
        try Data("pdf bytes without buyer text".utf8).write(to: files.appendingPathComponent(pdf.storedFilename))
        try Data("image bytes without buyer text".utf8).write(to: files.appendingPathComponent(image.storedFilename))
        try JSONEncoder().encode([pdf, image]).write(to: directory.appendingPathComponent("invoices.json"))
        try "旧草稿备用抬头".write(to: directory.appendingPathComponent("invoice-company.txt"), atomically: true, encoding: .utf8)
        store.configure(directory: directory)
        let date = ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!
        let exported = try await store.exportFolder(to: directory, date: date)
        precondition(exported.lastPathComponent == "2026-10-26-139.00")
        let contents = try FileManager.default.contentsOfDirectory(at: exported, includingPropertiesForKeys: nil)
        precondition(contents.map(\.lastPathComponent).sorted() == ["001_发票.pdf", "002_发票.png"])
        let exportedData = try Data(contentsOf: exported.appendingPathComponent("001_发票.pdf"))
        let originalData = try Data(contentsOf: files.appendingPathComponent("a.pdf"))
        precondition(exportedData == originalData)
        let second = try await store.exportFolder(to: directory, date: date)
        precondition(second.lastPathComponent == "2026-10-26-139.00(2)")
        var rejected = invoice(999)
        rejected.documentKind = .nonInvoice
        var uncertain = invoice(777)
        uncertain.documentKind = .unknown
        uncertain.documentReason = "待确认：缺少关键字段。"
        try JSONEncoder().encode([pdf, rejected, uncertain]).write(to: directory.appendingPathComponent("invoices.json"))
        store.configure(directory: directory)
        precondition(store.acceptedInvoices.count == 1 && store.total == 39 && store.excludedCount == 1 && store.unknownCount == 1)
        precondition(store.invoices.first { $0.id == uncertain.id }?.documentReason == uncertain.documentReason)
        store.updateAmount("777", for: uncertain.id)
        precondition(store.total == 39 && !store.invoices.first { $0.id == uncertain.id }!.isAccepted,
                     "Editing an uncertain amount cannot bypass document screening")
        store.updateAmount("888", for: rejected.id)
        precondition(store.total == 39 && store.acceptedInvoices.count == 1)
        let filtered = try await store.exportFolder(to: directory, date: date)
        let filteredFiles = try FileManager.default.contentsOfDirectory(at: filtered, includingPropertiesForKeys: nil)
        precondition(filteredFiles.map(\.lastPathComponent) == ["001_发票.pdf"])
        do { try store.confirmInvoice(rejected.id); preconditionFailure("Explicit non-invoice files cannot be manually accepted") } catch {}
        try store.confirmInvoice(uncertain.id)
        let confirmed = store.invoices.first { $0.id == uncertain.id }!
        precondition(confirmed.isAccepted && confirmed.documentKind == .unknown && confirmed.manuallyConfirmed == true)
        precondition(confirmed.documentReason!.contains("人工确认") && store.unknownCount == 0 && store.total == 816)
        var legacy = confirmed
        legacy.documentKind = nil
        legacy.documentPolicyRevision = nil
        try JSONEncoder().encode([legacy]).write(to: directory.appendingPathComponent("invoices.json"))
        store.configure(directory: directory)
        precondition(store.acceptedInvoices.isEmpty && store.total == 0)
        while !store.pendingIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        precondition(store.excludedCount == 0 && store.unknownCount == 1 && store.total == 0,
                     "An unavailable legacy document stays uncertain rather than becoming a non-invoice")
        precondition(store.invoices[0].manuallyConfirmed == nil, "New screening policies require renewed manual confirmation")
        let invalid = directory.appendingPathComponent("报销单金额39.00.pdf")
        try Data("报销单 价税合计39.00".utf8).write(to: invalid)
        store.importFiles([invalid])
        try await Task.sleep(for: .milliseconds(20))
        while !store.pendingIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        precondition(store.invoices.count == 2 && store.acceptedInvoices.count == 1 && store.unknownCount == 1)
        let retained = store.invoices.first { $0.originalFilename == invalid.lastPathComponent }!
        precondition(retained.documentKind == .invoice && retained.manuallyImported == true && retained.documentReason != nil)
        precondition(FileManager.default.fileExists(atPath: store.sourceURL(for: retained).path),
                     "Manual files are retained as user-provided invoices without document screening")
        precondition(FileManager.default.fileExists(atPath: invalid.path))
        store.updateAmount("123.45", for: retained.id)
        try await store.rerecognize(retained.id)
        let retried = store.invoices.first { $0.id == retained.id }!
        precondition(retried.documentKind == .invoice && retried.manuallyImported == true && retried.amount == Decimal(string: "123.45") && store.pendingIDs.isEmpty,
                     "Manually imported invoices are not reclassified and preserve user amounts")
        let tripURL = directory.appendingPathComponent("发票金额99.00.pdf")
        let tripData = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let context = CGContext(consumer: CGDataConsumer(data: tripData)!, mediaBox: &bounds, nil)!
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("滴滴出行行程单\n此行程单非发票，请以电子发票作为报销凭证" as NSString).draw(
            at: CGPoint(x: 20, y: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        try (tripData as Data).write(to: tripURL)
        store.importFiles([tripURL])
        try await Task.sleep(for: .milliseconds(20))
        while !store.pendingIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let trip = store.invoices.first { $0.originalFilename == tripURL.lastPathComponent }!
        precondition(trip.documentKind == .invoice && trip.manuallyImported == true && store.excludedCount == 0)
        precondition(store.unknownCount == 1 && store.acceptedInvoices.count == 2)
        precondition(FileManager.default.fileExists(atPath: store.sourceURL(for: trip).path),
                     "Manual import follows the user's supplied-invoice decision, not local document classification")
        let noAmount = directory.appendingPathComponent("无金额文件.pdf")
        try Data("没有任何可识别的票面字段".utf8).write(to: noAmount)
        store.importFiles([noAmount])
        try await Task.sleep(for: .milliseconds(20))
        while !store.pendingIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let missingAmount = store.invoices.first { $0.originalFilename == noAmount.lastPathComponent }!
        precondition(missingAmount.isAccepted && missingAmount.manuallyImported == true && store.needsConfirmation(missingAmount),
                     "A manual invoice with unreadable fields stays accepted but still needs a valid amount")
        let oldUnknown = Invoice(id: retained.id, storedFilename: "missing-copy.pdf", originalFilename: retained.originalFilename,
            fingerprint: retained.fingerprint, amount: Decimal(string: "123.45"), warning: "旧待确认", documentKind: .unknown,
            documentReason: "旧待确认", documentPolicyRevision: InvoiceDocumentClassifier.policyRevision)
        try JSONEncoder().encode([oldUnknown]).write(to: directory.appendingPathComponent("invoices.json"))
        store.configure(directory: directory)
        store.importFiles([invalid])
        try await Task.sleep(for: .milliseconds(20))
        while !store.pendingIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        precondition(store.invoices.count == 1 && store.invoices[0].manuallyImported == true && store.invoices[0].isAccepted)
        precondition(store.invoices[0].amount == Decimal(string: "123.45"), "Repeat imports must preserve an existing user amount")
        let restoredCopy = try Data(contentsOf: store.sourceURL(for: store.invoices[0]))
        let suppliedCopy = try Data(contentsOf: invalid)
        precondition(restoredCopy == suppliedCopy,
                     "A repeat import restores a missing stored copy without duplicating the invoice")
        var manualAcrossPolicy = store.invoices[0]
        manualAcrossPolicy.documentPolicyRevision = 0
        manualAcrossPolicy.documentKind = .nonInvoice
        try JSONEncoder().encode([manualAcrossPolicy]).write(to: directory.appendingPathComponent("invoices.json"))
        store.configure(directory: directory)
        try await Task.sleep(for: .milliseconds(20))
        precondition(store.pendingIDs.isEmpty && store.invoices[0].manuallyImported == true && store.invoices[0].isAccepted && store.excludedCount == 0,
                     "User-provided invoices are not invalidated by a future local policy change")
        var refreshed = oldUnknown
        refreshed.amount = nil
        try JSONEncoder().encode([refreshed]).write(to: directory.appendingPathComponent("invoices.json"))
        store.configure(directory: directory)
        refreshed.manuallyImported = true
        refreshed.documentKind = .invoice
        refreshed.documentReason = "手动导入，按用户提供的发票保留。"
        refreshed.amount = 39
        refreshed.warning = nil
        try JSONEncoder().encode([refreshed]).write(to: directory.appendingPathComponent("invoices.json"))
        try store.refreshFromDisk()
        precondition(store.invoices.count == 1 && store.invoices[0].isAccepted && store.invoices[0].amount == 39 && store.invoices[0].warning == nil,
                     "Disk upgrades of an existing invoice must be reflected without duplicating its row")
        store.updateAmount("88", for: refreshed.id)
        refreshed.amount = 99
        try JSONEncoder().encode([refreshed]).write(to: directory.appendingPathComponent("invoices.json"))
        try store.refreshFromDisk()
        precondition(store.invoices[0].amount == 88, "Refreshing manual trust cannot overwrite an existing user amount")
        store.updateAmount("", for: refreshed.id)
        try store.refreshFromDisk()
        precondition(store.invoices[0].amount == nil && store.invoices[0].warning != nil,
                     "Refreshing manual trust cannot refill a deliberately cleared amount")
        print("Invoice confirmation and unified export checks passed; temporary data retained at \(directory.path)")
    }
}
#endif
