#if DIRECT_TEST_RUNNER
import Foundation

@main struct InvoiceConfirmationCheck {
    @MainActor static func main() throws {
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
        print("Invoice confirmation checks passed; temporary data retained at \(directory.path)")
    }
}
#endif
