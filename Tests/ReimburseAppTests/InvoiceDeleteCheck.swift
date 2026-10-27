#if DIRECT_TEST_RUNNER
import Foundation
@main struct InvoiceDeleteCheck {
    private struct Snapshot: Codable { var items:[InboxInvoice]; var expandedArchives:[String:Set<UUID>] = [:] }
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-delete-\(UUID())")
        let box = root.appendingPathComponent("box"), files = box.appendingPathComponent("files"), trash = root.appendingPathComponent("mock-trash"), projects = root.appendingPathComponent("projects")
        for dir in [files,trash,projects] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories:true) }
        let reference = MailAttachmentReference(account:"test@qq.com",uidValidity:"1",uid:1,partID:"2",encoding:"BASE64",size:10)
        var item = InboxInvoice(id:UUID(),storedFilename:"test.pdf",originalFilename:"发票.pdf",fingerprint:"hash",amount:39,warning:nil,receivedAt:Date(),buyerTitle:"测试",sellerTitle:"",itemDescription:"",source:"测试",mailID:"mail1",projectID:nil,projectInvoiceID:nil)
        item.remote = reference
        try Data("cached invoice".utf8).write(to: files.appendingPathComponent(item.storedFilename))
        try JSONEncoder().encode(Snapshot(items:[item])).write(to:box.appendingPathComponent("inbox.json"))
        let inbox = InvoiceInboxStore(directory:box,projectsDirectory:projects)
        inbox.activeCacheIDs = [item.id]
        do { try inbox.delete(ids:[item.id],trash:{ _ in preconditionFailure("Active file must not be trashed") }); preconditionFailure("Active deletion must stop") } catch {}
        inbox.activeCacheIDs = []
        var attempts = 0
        do { try inbox.delete(ids:[item.id],trash:{ _ in attempts += 1; throw CocoaError(.fileWriteNoPermission) }); preconditionFailure("Trash error must stop") } catch {}
        precondition(attempts == 1 && inbox.items.count == 1 && inbox.isDownloaded(item))
        try inbox.delete(ids:[item.id],trash:{ source in try FileManager.default.moveItem(at:source,to:trash.appendingPathComponent(source.lastPathComponent)) })
        precondition(inbox.items.isEmpty && FileManager.default.fileExists(atPath:trash.appendingPathComponent(item.storedFilename).path))
        let reopened = InvoiceInboxStore(directory:box,projectsDirectory:projects)
        try reopened.registerRemote(InvoiceMailMessage(id:"mail1",receivedAt:Date(),subject:"发票",sender:"测试",attachments:[InvoiceMailAttachment(filename:"发票.pdf",remote:reference)],hasDownloadLink:false))
        precondition(reopened.items.isEmpty,"Deleted remote records must not reappear on repeat sync")
        print("Invoice delete, protection, failure-stop and sync tombstone checks passed; temporary files retained")
    }
}
#endif
