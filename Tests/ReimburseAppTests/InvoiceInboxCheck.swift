#if DIRECT_TEST_RUNNER
import Foundation
import AppKit

@main struct InvoiceInboxCheck {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-inbox-check-\(UUID().uuidString)", isDirectory: true)
        let box = root.appendingPathComponent("box", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let local = root.appendingPathComponent("发票金额39.00.pdf")
        try makePDF().write(to: local)
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
        precondition(store.items[0].isAcceptedInvoice, "Ordinary invoice is accepted automatically")
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
        precondition(store.items.count == 2 && pending.amount == 88 && !store.isDownloaded(pending) && !pending.isAcceptedInvoice, "Sync registers metadata without downloading or duplicating attachments")
        do { try store.assign(ids: [pending.id], to: project); preconditionFailure("Remote invoice must be downloaded before assignment") } catch {}
        try makePDF().write(to: store.sourceURL(for: pending))
        let recoveredIDs = try await store.download(pending.id)
        let recovered = store.items.first { $0.id == pending.id }!
        precondition(recoveredIDs == [pending.id] && !recovered.fingerprint.hasPrefix("remote:") && recovered.amount == 88,
            "A cached attachment must finish hash/recognition recovery without accessing credentials or network")
        precondition(recovered.receivedAt == received)
        let reopened = InvoiceInboxStore(directory: box, projectsDirectory: projects)
        precondition(reopened.items.count == 2 && reopened.items.first(where: { $0.id == pending.id })?.receivedAt == received)
        let rejectedFile = root.appendingPathComponent("发票报销单金额66.00.pdf")
        try makePDF(title: "费用报销单").write(to: rejectedFile)
        await store.importFiles([rejectedFile])
        let rejected = store.items.first { $0.originalFilename == rejectedFile.lastPathComponent }!
        precondition(!rejected.isAcceptedInvoice, "A filename amount cannot turn a report into an invoice")
        try store.update(rejected.id, amount: "66", buyerTitle: "手动抬头")
        do { try store.assign(ids: [rejected.id], to: project); preconditionFailure("Money edits cannot override document rejection") } catch {}
        var oldSnapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: boxMetadata)) as! [String: Any]
        var oldItems = oldSnapshot["items"] as! [[String: Any]]
        let rejectedIndex = oldItems.firstIndex { ($0["originalFilename"] as? String) == rejectedFile.lastPathComponent }!
        oldItems[rejectedIndex]["documentKind"] = "invoice"
        oldItems[rejectedIndex]["documentPolicyRevision"] = 1
        oldItems[rejectedIndex]["documentConfirmed"] = true
        oldSnapshot["items"] = oldItems
        try JSONSerialization.data(withJSONObject: oldSnapshot).write(to: boxMetadata)
        let migrated = InvoiceInboxStore(directory: box, projectsDirectory: projects)
        precondition(!migrated.items.first { $0.id == rejected.id }!.isAcceptedInvoice)
        await migrated.refreshMissingTitles()
        precondition(!migrated.items.first { $0.id == rejected.id }!.isAcceptedInvoice, "Legacy manual type confirmations cannot bypass the current whitelist")
        let queueDirectory = root.appendingPathComponent("automatic-box", isDirectory: true)
        let queue = InvoiceInboxStore(directory: queueDirectory, projectsDirectory: projects)
        func mail(_ uid: UInt64, account: String = "test@qq.com") -> InvoiceMailMessage {
            let reference = MailAttachmentReference(account: account, uidValidity: "99", uid: uid, partID: "2", encoding: "BASE64", size: 100)
            return InvoiceMailMessage(id: "auto\(uid)", receivedAt: received, subject: "发票", sender: "商家",
                attachments: [InvoiceMailAttachment(filename: "电子发票金额88.00.pdf", remote: reference)], hasDownloadLink: false)
        }
        try queue.registerRemote(mail(30))
        try queue.registerRemote(mail(30), automaticallyDownload: true)
        precondition(queue.items[0].autoDownloadPending == false, "Historical records must not be promoted on repeated sync")
        for uid: UInt64 in [31, 32, 33] { try queue.registerRemote(mail(uid), automaticallyDownload: true) }
        try queue.registerRemote(mail(34, account: "other@qq.com"), automaticallyDownload: true)
        let validID = queue.items.first { $0.mailID == "auto31" }!.id
        let reportID = queue.items.first { $0.mailID == "auto32" }!.id
        let failedID = queue.items.first { $0.mailID == "auto33" }!.id
        try makePDF().write(to: queue.sourceURL(for: queue.items.first { $0.id == validID }!))
        try makePDF(title: "费用报销单").write(to: queue.sourceURL(for: queue.items.first { $0.id == reportID }!))
        let paused = await queue.downloadPendingAttachments(account: "test@qq.com", shouldContinue: { false })
        precondition(paused.accepted == 0 && paused.failed == 0 && queue.items.first { $0.id == validID }!.autoDownloadPending == true)
        let automatic = await queue.downloadPendingAttachments(account: "test@qq.com", shouldContinue: { true }, downloadAttachment: { id in
            if id == failedID { throw CocoaError(.fileReadUnknown) }
            return try await queue.download(id)
        })
        precondition(automatic.accepted == 1 && automatic.failed == 1, "Only automatically validated invoice results count; reports do not")
        precondition(queue.items.first { $0.id == validID }!.autoDownloadPending == false)
        precondition(queue.items.first { $0.id == reportID }!.autoDownloadPending == false, "Rejected content completes processing instead of retrying forever")
        let resumed = InvoiceInboxStore(directory: queueDirectory, projectsDirectory: projects)
        precondition(resumed.items.first { $0.id == failedID }!.autoDownloadPending == true, "Download failure remains queued after restart")
        precondition(resumed.items.first { $0.mailID == "auto34" }!.autoDownloadPending == true, "Other mailbox queues are not processed")
        let retained = root.appendingPathComponent("retained-cache.pdf")
        try FileManager.default.moveItem(at: resumed.sourceURL(for: resumed.items.first { $0.id == validID }!), to: retained)
        var retried: [UUID] = []
        _ = await resumed.downloadPendingAttachments(account: "test@qq.com", shouldContinue: { true }, downloadAttachment: { id in
            retried.append(id)
            throw CocoaError(.fileReadUnknown)
        })
        precondition(retried == [failedID], "Completed attachments must not redownload after cache eviction; historical and other accounts stay untouched")
        let retryDirectory = root.appendingPathComponent("retry-box", isDirectory: true)
        let interrupted = InvoiceInboxStore(directory: retryDirectory, projectsDirectory: projects)
        await interrupted.importFiles([local])
        let interruptedID = interrupted.items[0].id
        try interrupted.update(interruptedID, amount: "49.50", buyerTitle: "保留手动抬头")
        let retryMetadata = retryDirectory.appendingPathComponent("inbox.json")
        var interruptedSnapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: retryMetadata)) as! [String: Any]
        var interruptedItems = interruptedSnapshot["items"] as! [[String: Any]]
        interruptedItems[0].removeValue(forKey: "documentPolicyRevision")
        interruptedItems[0].removeValue(forKey: "documentKind")
        interruptedItems[0]["warning"] = "正在识别金额和抬头…"
        interruptedSnapshot["items"] = interruptedItems
        try JSONSerialization.data(withJSONObject: interruptedSnapshot).write(to: retryMetadata)
        let retriedImport = InvoiceInboxStore(directory: retryDirectory, projectsDirectory: projects)
        await retriedImport.importFiles([local])
        precondition(retriedImport.items.count == 1 && retriedImport.items[0].id == interruptedID && retriedImport.items[0].isAcceptedInvoice,
            "Duplicate content from a retried ZIP/import must finish interrupted classification rather than skip forever")
        precondition(retriedImport.items[0].amount == Decimal(string: "49.50") && retriedImport.items[0].buyerTitle == "保留手动抬头" && retriedImport.items[0].warning == nil,
            "Classification retry preserves saved money and buyer edits and clears stale processing warnings")
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
    private static func makePDF(title: String = "增值税电子普通发票") -> Data {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &bounds, nil)!
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        ("\(title) 发票号码：12345678901234567890\n开票日期：2026年10月27日" as NSString).draw(at: CGPoint(x: 30, y: 360), withAttributes: font)
        ("购买方信息\n名称：测试购买公司\n纳税人识别号：TEST" as NSString).draw(at: CGPoint(x: 30, y: 300), withAttributes: font)
        ("销售方信息\n名称：测试销售公司\n纳税人识别号：SELLER" as NSString).draw(at: CGPoint(x: 320, y: 300), withAttributes: font)
        ("价税合计 ¥39.00\n*餐饮服务*餐费" as NSString).draw(at: CGPoint(x: 30, y: 150), withAttributes: font)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
#endif
