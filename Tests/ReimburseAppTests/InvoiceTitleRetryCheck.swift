#if DIRECT_TEST_RUNNER
import AppKit
import CryptoKit
import Foundation

@main struct InvoiceTitleRetryCheck {
    private struct Snapshot: Codable {
        var items: [InboxInvoice]
        var expandedArchives: [String: Set<UUID>] = [:]
    }

    @MainActor static func main() async throws {
        let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(previousArguments.merging(["reimbursement.ai.enabled": false, "reimbursement.ai.invoiceFallbackEnabled": false]) { _, test in test }, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-title-retry-\(UUID().uuidString)", isDirectory: true)
        let box = root.appendingPathComponent("box", isDirectory: true)
        let files = box.appendingPathComponent("files", isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let pdf = makePDF()
        let id = UUID()
        let received = Date(timeIntervalSince1970: 1_790_000_000)
        let hash = SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined()
        let item = InboxInvoice(id: id, storedFilename: "cached.pdf", originalFilename: "invoice.pdf", fingerprint: hash,
            amount: 49.50, warning: nil, receivedAt: received, buyerTitle: "", sellerTitle: "", itemDescription: "",
            source: "测试邮件", mailID: "test-only", projectID: nil, projectInvoiceID: nil)
        try pdf.write(to: files.appendingPathComponent(item.storedFilename))
        try JSONEncoder().encode(Snapshot(items: [item])).write(to: box.appendingPathComponent("inbox.json"))
        let store = InvoiceInboxStore(directory: box, projectsDirectory: projects)
        try store.update(id, amount: "88.25", buyerTitle: "")
        let cachedIDs = try await store.download(id)
        precondition(cachedIDs == [id])
        precondition(store.items[0].buyerTitle == "测试购买公司" && store.items[0].sellerTitle == "测试销售公司", "Editing only money must not suppress or swap party recognition")
        precondition(store.items[0].amount == Decimal(string: "88.25") && store.items[0].receivedAt == received && store.items[0].fingerprint == hash)
        try store.update(id, amount: "88.25", buyerTitle: "人工确认购买方")
        try await store.rerecognize(id)
        precondition(store.items[0].buyerTitle == "人工确认购买方", "Existing manual title must remain unchanged")

        let projectID = UUID()
        let projectURL = projects.appendingPathComponent(projectID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try Data().write(to: projectURL.appendingPathComponent("draft.json"))
        let project = DraftSummary(id: projectID, title: "测试项目", updatedAt: Date(), url: projectURL)
        try store.assign(ids: [id], to: project)
        let projectMetadata = projectURL.appendingPathComponent("invoices.json")
        let priorProject = try Data(contentsOf: projectMetadata)
        var assigned = store.items[0]
        assigned.buyerTitle = ""
        assigned.sellerTitle = ""
        assigned.warning = "重复发票，发票箱中已有相同文件。"
        try JSONEncoder().encode(Snapshot(items: [assigned])).write(to: box.appendingPathComponent("inbox.json"))
        let reopened = InvoiceInboxStore(directory: box, projectsDirectory: projects)
        let remote = MailAttachmentReference(account: "test@qq.com", uidValidity: "7", uid: 21, partID: "2", encoding: "BASE64", size: 100)
        try reopened.registerRemote(InvoiceMailMessage(id: "mail21", receivedAt: received, subject: "发票", sender: "测试", attachments: [InvoiceMailAttachment(filename: "未下载发票.pdf", remote: remote)], hasDownloadLink: false))
        await reopened.refreshMissingTitles()
        let repaired = reopened.items.first { $0.id == id }!
        precondition(repaired.buyerTitle == "测试购买公司" && repaired.projectID == projectID && repaired.projectInvoiceID == assigned.projectInvoiceID)
        precondition(repaired.amount == assigned.amount && repaired.receivedAt == received && repaired.fingerprint == hash && repaired.warning == assigned.warning)
        let afterProject = try Data(contentsOf: projectMetadata)
        precondition(afterProject == priorProject, "Title repair must not rewrite project invoices or money")
        precondition(reopened.items.first { $0.mailID == "mail21" }.map { !reopened.isDownloaded($0) } == true, "Background repair must never download uncached attachments")
        print("Invoice local title retry checks passed; temporary data retained at \(root.path)")
    }

    private static func makePDF() -> Data {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &bounds, nil)!
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        ("电子发票（普通发票）\n发票号码：12345678901234567890\n开票日期：2026年10月27日" as NSString).draw(at: CGPoint(x: 30, y: 360), withAttributes: font)
        ("购买方信息\n名称：测试购买公司\n纳税人识别号：91310101123456789A" as NSString).draw(at: CGPoint(x: 30, y: 300), withAttributes: font)
        ("销售方信息\n名称：测试销售公司\n纳税人识别号：91310101987654321B" as NSString).draw(at: CGPoint(x: 320, y: 300), withAttributes: font)
        ("金额合计 ¥36.79\n税额合计 ¥2.21\n价税合计 ¥39.00\n*餐饮服务*餐费" as NSString).draw(at: CGPoint(x: 30, y: 150), withAttributes: font)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
#endif
