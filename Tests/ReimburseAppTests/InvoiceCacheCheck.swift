#if DIRECT_TEST_RUNNER
import Foundation

@main struct InvoiceCacheCheck {
    private struct Snapshot: Codable {
        var items: [InboxInvoice]
        var expandedArchives: [String: Set<UUID>] = [:]
    }

    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-cache-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "invoice-cache-check.\(UUID().uuidString)")!
        let remote = MailAttachmentReference(account: "test@qq.com", uidValidity: "9", uid: 1, partID: "2", encoding: "BASE64", size: 600_000)
        @MainActor func item(_ age: TimeInterval, recoverable: Bool = true) -> InboxInvoice {
            let id = UUID()
            var invoice = InboxInvoice(id: id, storedFilename: "\(id).pdf", originalFilename: "发票.pdf", fingerprint: id.uuidString,
                amount: 39, warning: nil, receivedAt: Date(timeIntervalSince1970: 10_000 - age), buyerTitle: "测试抬头",
                sellerTitle: "测试商家", itemDescription: "商品", source: "测试", mailID: nil, projectID: nil, projectInvoiceID: nil)
            invoice.remote = recoverable ? remote : nil
            invoice.lastAccessedAt = Date(timeIntervalSince1970: age)
            return invoice
        }
        @MainActor func store(_ name: String, items: [InboxInvoice], bytes: Int = 600_000) throws -> (InvoiceInboxStore, URL, URL) {
            let box = root.appendingPathComponent(name, isDirectory: true)
            let files = box.appendingPathComponent("files", isDirectory: true)
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            for value in items { try Data(repeating: 1, count: bytes).write(to: files.appendingPathComponent(value.storedFilename)) }
            let metadata = box.appendingPathComponent("inbox.json")
            try JSONEncoder().encode(Snapshot(items: items)).write(to: metadata)
            let projects = root.appendingPathComponent("projects", isDirectory: true)
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            return (InvoiceInboxStore(directory: box, projectsDirectory: projects), files, metadata)
        }
        func moved(_ url: URL, into trash: URL) throws {
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }

        let first = item(10), second = item(20), newest = item(30), manual = item(1, recoverable: false)
        let (inbox, files, metadata) = try store("lru", items: [newest, manual, first, second])
        let metadataBefore = try Data(contentsOf: metadata)
        var deleted: [String] = []
        let manager = InvoiceCacheManager(inbox: inbox, defaults: defaults) { url in
            deleted.append(url.lastPathComponent)
            try moved(url, into: root.appendingPathComponent("fake-trash"))
        }
        precondition(manager.limitMB == 200 && manager.cacheBytes == 1_800_000, "Only recoverable mail files count toward cache capacity")
        var refreshed = 0
        manager.onCleared = { refreshed += 1 }
        try manager.setLimitMB(1)
        precondition(deleted == [first.storedFilename, second.storedFilename], "Least recently accessed files are removed first, independent of receipt order")
        precondition(manager.cacheBytes == 600_000 && refreshed == 1)
        precondition(FileManager.default.fileExists(atPath: files.appendingPathComponent(newest.storedFilename).path))
        precondition(FileManager.default.fileExists(atPath: files.appendingPathComponent(manual.storedFilename).path))
        let metadataAfter = try Data(contentsOf: metadata)
        precondition(metadataAfter == metadataBefore, "Cache removal must not change invoice metadata")
        try manager.clearAll()
        precondition(manager.cacheBytes == 0 && inbox.items.count == 4 && inbox.items[0].amount == 39)
        precondition(FileManager.default.fileExists(atPath: files.appendingPathComponent(manual.storedFilename).path), "Manual originals are not recoverable cache")
        try manager.setLimitMB(350)
        precondition(manager.limitMB == 350, "The limit is user configurable, not capped at the 200 MB example")
        do { try manager.setLimitMB(0); preconditionFailure("Zero limit must be rejected") } catch {}
        do { try manager.setLimitMB(-1); preconditionFailure("Negative limit must be rejected") } catch {}
        precondition(InvoiceCacheManager(inbox: inbox, defaults: defaults, trash: { _ in }).limitMB == 350)

        let active = item(1), other = item(2)
        let (busyInbox, busyFiles, _) = try store("active", items: [active, other])
        busyInbox.activeCacheIDs = [active.id]
        let protected = InvoiceCacheManager(inbox: busyInbox, defaults: UserDefaults(suiteName: "cache-protect.\(UUID().uuidString)")!) { url in
            try moved(url, into: root.appendingPathComponent("protected-trash"))
        }
        try protected.setLimitMB(1)
        try protected.clearAll()
        precondition(FileManager.default.fileExists(atPath: busyFiles.appendingPathComponent(active.storedFilename).path), "Active attachment must survive limit and clear-all operations")
        precondition(!FileManager.default.fileExists(atPath: busyFiles.appendingPathComponent(other.storedFilename).path))
        busyInbox.activeCacheIDs = []
        try protected.clearAll()
        precondition(protected.cacheBytes == 0)

        var legacyOld = item(10), legacyNew = item(20)
        legacyOld.lastAccessedAt = nil; legacyNew.lastAccessedAt = nil
        let (legacyInbox, legacyFiles, _) = try store("legacy-access", items: [legacyNew, legacyOld])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: legacyFiles.appendingPathComponent(legacyOld.storedFilename).path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: legacyFiles.appendingPathComponent(legacyNew.storedFilename).path)
        var legacyRemoved: [String] = []
        let legacyManager = InvoiceCacheManager(inbox: legacyInbox, defaults: UserDefaults(suiteName: "cache-legacy.\(UUID())")!) { url in
            legacyRemoved.append(url.lastPathComponent)
            try moved(url, into: root.appendingPathComponent("legacy-trash"))
        }
        try legacyManager.setLimitMB(1)
        precondition(legacyRemoved == [legacyOld.storedFilename], "Legacy files use cache file age rather than the original email date")

        let failA = item(1), failB = item(2)
        let (failureInbox, failureFiles, _) = try store("failure", items: [failA, failB])
        var attempts = 0
        let failureManager = InvoiceCacheManager(inbox: failureInbox, defaults: defaults) { _ in
            attempts += 1
            throw CocoaError(.fileWriteNoPermission)
        }
        do { try failureManager.clearAll(); preconditionFailure("Cleanup failure must be visible") } catch {}
        precondition(attempts == 1 && !failureManager.working && failureManager.message.contains("已暂停") && failureManager.suspendedAfterFailure)
        precondition(FileManager.default.fileExists(atPath: failureFiles.appendingPathComponent(failB.storedFilename).path), "A failure must stop subsequent file removals")

        let linkItem = item(1)
        let (linkInbox, linkFiles, _) = try store("symlink", items: [])
        let outside = root.appendingPathComponent("outside.pdf")
        try Data("must remain".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: linkFiles.appendingPathComponent(linkItem.storedFilename), withDestinationURL: outside)
        let linkMetadata = linkFiles.deletingLastPathComponent().appendingPathComponent("inbox.json")
        try JSONEncoder().encode(Snapshot(items: [linkItem])).write(to: linkMetadata)
        let reopened = InvoiceInboxStore(directory: linkFiles.deletingLastPathComponent(), projectsDirectory: root.appendingPathComponent("projects"))
        var unsafeAttempts = 0
        let safe = InvoiceCacheManager(inbox: reopened, defaults: defaults) { _ in unsafeAttempts += 1 }
        try safe.clearAll()
        precondition(unsafeAttempts == 0 && safe.cacheBytes == 0 && FileManager.default.fileExists(atPath: outside.path), "Symbolic links never become cleanup targets")
        _ = linkInbox
        print("Invoice cache LRU, protection, metadata, failure-stop and symlink checks passed; test files retained at \(root.path)")
    }
}
#endif
