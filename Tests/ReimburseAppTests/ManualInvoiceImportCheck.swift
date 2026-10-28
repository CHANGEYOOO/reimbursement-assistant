#if DIRECT_TEST_RUNNER
import Foundation

@main struct ManualInvoiceImportCheck {
    @MainActor static func main() async throws {
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(previous.merging(["reimbursement.ai.enabled": false, "reimbursement.ai.invoiceFallbackEnabled": false]) { _, test in test }, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manual-invoice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent(":12345678901234567890_手动发票.pdf")
        try Data("This deliberately has no invoice title, fields, or readable PDF structure".utf8).write(to: source)
        let store = InvoiceInboxStore(directory: root.appendingPathComponent("box"), projectsDirectory: root.appendingPathComponent("projects"))
        await store.importFiles([source])
        precondition(store.lastError == nil && store.items.count == 1)
        let item = store.items[0]
        precondition(item.isAcceptedInvoice && item.manuallyImported == true && item.documentKind == .invoice,
                     "User-selected files are invoices even when local parsing cannot identify type")
        precondition(store.isDownloaded(item) && item.warning != nil, "Missing amount may need editing, but must not hide the invoice")
        try store.update(item.id, amount: "157", buyerTitle: "测试购买方")
        await store.importFiles([source])
        precondition(store.items.count == 1 && store.items[0].amount == 157 && store.items[0].isAcceptedInvoice)
        let cacheURL = store.sourceURL(for: store.items[0])
        let held = root.appendingPathComponent("held-copy.pdf")
        try FileManager.default.moveItem(at: cacheURL, to: held)
        await store.importFiles([source])
        precondition(store.items.count == 1 && store.isDownloaded(store.items[0]) && store.items[0].amount == 157,
                     "Manual re-import restores a cleared cache without adding duplicates or losing edits")
        let metadata = root.appendingPathComponent("box/inbox.json")
        var snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: Any]
        var records = snapshot["items"] as! [[String: Any]]
        records[0].removeValue(forKey: "manuallyImported")
        records[0]["documentKind"] = "unknown"
        records[0]["documentPolicyRevision"] = 1
        snapshot["items"] = records
        try JSONSerialization.data(withJSONObject: snapshot).write(to: metadata)
        let legacy = InvoiceInboxStore(directory: root.appendingPathComponent("box"), projectsDirectory: root.appendingPathComponent("projects"))
        precondition(legacy.items[0].isManuallyImported && legacy.items[0].isAcceptedInvoice,
                     "Older manual imports previously stuck as pending remain visible as invoices")
        await legacy.refreshMissingTitles()
        precondition(legacy.items[0].documentKind == .invoice && legacy.items[0].manuallyImported == true)
        if CommandLine.arguments.count > 1 && FileManager.default.fileExists(atPath: CommandLine.arguments[1]) {
            let actual = InvoiceInboxStore(directory: root.appendingPathComponent("provided"), projectsDirectory: root.appendingPathComponent("projects"))
            await actual.importFiles([URL(fileURLWithPath: CommandLine.arguments[1])])
            precondition(actual.lastError == nil && actual.items.count == 1 && actual.items[0].isAcceptedInvoice && actual.items[0].manuallyImported == true)
            print("Provided PDF imported directly as an invoice; amount extraction completed: \(actual.items[0].amount != nil)")
        }
        precondition(FileManager.default.fileExists(atPath: source.path))
        print("Manual inbox import, colon filename, duplicate recovery, amount preservation and legacy trust checks passed; fixtures retained: \(root.path)")
    }
}
#endif
