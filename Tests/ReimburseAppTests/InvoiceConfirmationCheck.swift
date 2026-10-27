#if DIRECT_TEST_RUNNER
import Foundation

@main struct InvoiceConfirmationCheck {
    @MainActor static func main() async throws {
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
        try JSONEncoder().encode([pdf, rejected]).write(to: directory.appendingPathComponent("invoices.json"))
        store.configure(directory: directory)
        precondition(store.acceptedInvoices.count == 1 && store.total == 39 && store.excludedCount == 1)
        store.updateAmount("888", for: rejected.id)
        precondition(store.total == 39 && store.acceptedInvoices.count == 1)
        let filtered = try await store.exportFolder(to: directory, date: date)
        let filteredFiles = try FileManager.default.contentsOfDirectory(at: filtered, includingPropertiesForKeys: nil)
        precondition(filteredFiles.map(\.lastPathComponent) == ["001_发票.pdf"])
        var legacy = rejected
        legacy.documentKind = nil
        legacy.documentPolicyRevision = nil
        try JSONEncoder().encode([legacy]).write(to: directory.appendingPathComponent("invoices.json"))
        store.configure(directory: directory)
        precondition(store.acceptedInvoices.isEmpty && store.total == 0)
        while !store.pendingIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        precondition(store.excludedCount == 1 && store.total == 0)
        let invalid = directory.appendingPathComponent("报销单金额39.00.pdf")
        try Data("报销单 价税合计39.00".utf8).write(to: invalid)
        store.importFiles([invalid])
        try await Task.sleep(for: .milliseconds(20))
        while !store.pendingIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        precondition(store.invoices.count == 1 && store.acceptedInvoices.isEmpty)
        precondition(FileManager.default.fileExists(atPath: invalid.path))
        print("Invoice confirmation and unified export checks passed; temporary data retained at \(directory.path)")
    }
}
#endif
