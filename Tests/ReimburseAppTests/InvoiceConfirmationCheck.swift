#if DIRECT_TEST_RUNNER
import Foundation

@main struct InvoiceConfirmationCheck {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoice-confirmation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func invoice(_ amount: Decimal?, warning: String? = nil) -> Invoice {
            Invoice(id: UUID(), storedFilename: "sample.pdf", originalFilename: "sample.pdf",
                    fingerprint: UUID().uuidString, amount: amount, warning: warning)
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
        let pdf = Invoice(id: UUID(), storedFilename: "a.pdf", originalFilename: "发票.pdf", fingerprint: "a", amount: 39, warning: nil)
        let image = Invoice(id: UUID(), storedFilename: "b.png", originalFilename: "发票.png", fingerprint: "b", amount: 100, warning: nil)
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
        print("Invoice confirmation and unified export checks passed; temporary data retained at \(directory.path)")
    }
}
#endif
