#if DIRECT_TEST_RUNNER
import Foundation

@main struct InvoiceInboxCheck {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-inbox-check-\(UUID().uuidString)", isDirectory: true)
        let box = root.appendingPathComponent("box", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let local = root.appendingPathComponent("发票金额39.00.pdf")
        try Data("invoice sample one".utf8).write(to: local)
        let store = InvoiceInboxStore(directory: box, projectsDirectory: projects)
        let received = ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z")!
        await store.importFiles([local], receivedAt: received)
        precondition(store.items.count == 1 && store.items[0].amount == 39 && store.items[0].receivedAt == received)
        await store.importFiles([local], receivedAt: Date())
        precondition(store.items.count == 1 && store.items[0].receivedAt == received, "Duplicate imports preserve original receipt time")
        let id = store.items[0].id
        try store.update(id, amount: "49.50", buyerTitle: "项目购买方")
        let projectID = UUID()
        let projectURL = projects.appendingPathComponent(projectID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try Data("legacy draft unchanged".utf8).write(to: projectURL.appendingPathComponent("draft.json"))
        let legacy = Invoice(id: UUID(), storedFilename: "old.pdf", originalFilename: "old.pdf", fingerprint: "old", amount: 10, warning: nil)
        try JSONEncoder().encode([legacy]).write(to: projectURL.appendingPathComponent("invoices.json"))
        let project = DraftSummary(id: projectID, title: "测试项目", updatedAt: Date(), url: projectURL)
        do { try store.assign(ids: [id], to: project); preconditionFailure("Unknown attachment type must require confirmation") } catch {}
        try store.confirmInvoice(id)
        try store.assign(ids: [id], to: project)
        try store.assign(ids: [id], to: project)
        var assigned = try JSONDecoder().decode([Invoice].self, from: Data(contentsOf: projectURL.appendingPathComponent("invoices.json")))
        precondition(assigned.count == 2 && assigned.contains(where: { $0.id == legacy.id }), "Existing invoices remain and reassigning is idempotent")
        precondition(store.items[0].projectID == projectID && store.items[0].buyerTitle == "项目购买方")
        let anotherID = UUID()
        let anotherURL = projects.appendingPathComponent(anotherID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: anotherURL, withIntermediateDirectories: true)
        try Data().write(to: anotherURL.appendingPathComponent("draft.json"))
        do {
            try store.assign(ids: [id], to: DraftSummary(id: anotherID, title: "另一个项目", updatedAt: Date(), url: anotherURL))
            preconditionFailure("Already assigned invoice must not enter a different project")
        } catch {}
        let boxMetadata = box.appendingPathComponent("inbox.json")
        var orphanSnapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: boxMetadata)) as! [String: Any]
        var orphanItems = orphanSnapshot["items"] as! [[String: Any]]
        orphanItems[0].removeValue(forKey: "projectID")
        orphanItems[0].removeValue(forKey: "projectInvoiceID")
        orphanSnapshot["items"] = orphanItems
        try JSONSerialization.data(withJSONObject: orphanSnapshot).write(to: boxMetadata, options: .atomic)
        let orphan = InvoiceInboxStore(directory: box, projectsDirectory: projects)
        do {
            try orphan.assign(ids: [id], to: DraftSummary(id: anotherID, title: "另一个项目", updatedAt: Date(), url: anotherURL))
            preconditionFailure("Project metadata must prevent cross-project reuse after an interrupted inbox save")
        } catch {}
        try orphan.assign(ids: [id], to: project)
        precondition(orphan.items[0].projectID == projectID, "Retrying the original project repairs interrupted assignment without duplicates")
        assigned = [legacy]
        try JSONEncoder().encode(assigned).write(to: projectURL.appendingPathComponent("invoices.json"))
        try store.refreshAssignments()
        precondition(store.items[0].projectID == nil && store.isDownloaded(store.items[0]), "Removing from a project preserves the inbox original")
        let remote = MailAttachmentReference(account: "test@qq.com", uidValidity: "99", uid: 20, partID: "2", encoding: "BASE64", size: 100)
        let message = InvoiceMailMessage(id: "mail20", receivedAt: received, subject: "发票", sender: "商家", attachments: [InvoiceMailAttachment(filename: "电子发票金额88.00.pdf", remote: remote)], hasDownloadLink: false)
        try store.registerRemote(message)
        try store.registerRemote(message)
        let pending = store.items.first { $0.mailID == "mail20" }!
        precondition(store.items.count == 2 && pending.amount == 88 && !store.isDownloaded(pending), "Sync registers metadata without downloading or duplicating attachments")
        do { try store.assign(ids: [pending.id], to: project); preconditionFailure("Remote invoice must be downloaded before assignment") } catch {}
        try Data("cached invoice body".utf8).write(to: store.sourceURL(for: pending))
        let recoveredIDs = try await store.download(pending.id)
        let recovered = store.items.first { $0.id == pending.id }!
        precondition(recoveredIDs == [pending.id] && !recovered.fingerprint.hasPrefix("remote:") && recovered.amount == 88,
            "A cached attachment must finish hash/recognition recovery without accessing credentials or network")
        precondition(recovered.receivedAt == received)
        let reopened = InvoiceInboxStore(directory: box, projectsDirectory: projects)
        precondition(reopened.items.count == 2 && reopened.items.first(where: { $0.id == pending.id })?.receivedAt == received)
        let details = InvoiceInboxStore.invoiceDetails(in: "购买方信息\n名称：示例购买公司\n纳税人识别号：123\n销售方信息\n名称：示例销售公司\n*餐饮服务*餐费")
        precondition(details.buyer == "示例购买公司" && details.seller == "示例销售公司" && details.item.contains("餐费"))
        func unsafeArchive(name: String, attributes: UInt32 = 0) -> Data {
            var central = Data(repeating: 0, count: 46)
            func write(_ number: UInt32, at offset: Int, into bytes: inout Data) {
                for index in 0..<4 { bytes[offset + index] = UInt8((number >> (8 * index)) & 255) }
            }
            write(0x02014b50, at: 0, into: &central)
            let nameBytes = Data(name.utf8)
            central[28] = UInt8(nameBytes.count)
            write(attributes, at: 38, into: &central)
            central.append(nameBytes)
            var end = Data(repeating: 0, count: 22)
            write(0x06054b50, at: 0, into: &end)
            end[8] = 1; end[10] = 1
            central.append(end)
            return central
        }
        for archive in [unsafeArchive(name: "../发票.pdf"), unsafeArchive(name: "发票.pdf", attributes: 0xa0000000)] {
            do { _ = try InvoiceInboxStore.readArchive(archive); preconditionFailure("Unsafe ZIP paths and symlinks must be rejected before extraction") } catch {}
        }
        print("Invoice inbox persistence, metadata-only sync, deduplication, project assignment checks passed; temporary files retained at \(root.path)")
    }
}
#endif
