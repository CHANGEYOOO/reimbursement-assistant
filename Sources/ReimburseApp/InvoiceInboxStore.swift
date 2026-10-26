import Combine
import CryptoKit
import Foundation

public struct InboxInvoice: Identifiable, Codable, Sendable {
    public let id: UUID
    public let storedFilename: String
    public let originalFilename: String
    public var fingerprint: String
    public var amount: Decimal?
    public var warning: String?
    public let receivedAt: Date
    public var buyerTitle: String
    public var sellerTitle: String
    public var itemDescription: String
    public let source: String
    public let mailID: String?
    public var projectID: UUID?
    public var projectInvoiceID: UUID?
    public var remote: MailAttachmentReference? = nil
}

private struct InboxSnapshot: Codable {
    var items: [InboxInvoice]
    var expandedArchives: [String: Set<UUID>]
}

@MainActor public final class InvoiceInboxStore: ObservableObject {
    @Published public private(set) var items: [InboxInvoice] = []
    @Published public private(set) var pendingIDs: Set<UUID> = []
    @Published public private(set) var lastError: String?
    private let directory: URL
    private let projectsDirectory: URL
    private var editedIDs: Set<UUID> = []
    private var expandedArchives: [String: Set<UUID>] = [:]
    private var canWrite = true
    private var filesDirectory: URL { directory.appendingPathComponent("files", isDirectory: true) }

    public init(directory: URL? = nil, projectsDirectory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("报销单助手/InvoiceInbox", isDirectory: true)
        self.projectsDirectory = projectsDirectory ?? DraftStorage.directory
        do {
            try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
            let metadata = self.directory.appendingPathComponent("inbox.json")
            if FileManager.default.fileExists(atPath: metadata.path) {
                let saved = try JSONDecoder().decode(InboxSnapshot.self, from: Data(contentsOf: metadata))
                items = saved.items
                expandedArchives = saved.expandedArchives
            }
            try refreshAssignments()
        } catch {
            canWrite = false
            lastError = "读取发票箱失败，已停止写入以保护资料：\(error.localizedDescription)"
        }
    }

    public func sourceURL(for item: InboxInvoice) -> URL {
        filesDirectory.appendingPathComponent(item.storedFilename)
    }

    public func importFiles(_ urls: [URL], receivedAt: Date = Date(), source: String = "手动导入") async {
        lastError = nil
        for url in urls {
            do {
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                try await importData(data, filename: url.lastPathComponent, receivedAt: receivedAt, source: source, mailID: nil)
            } catch { lastError = "导入发票失败：\(error.localizedDescription)"; return }
        }
    }

    public func isDownloaded(_ item: InboxInvoice) -> Bool {
        FileManager.default.fileExists(atPath: sourceURL(for: item).path)
    }

    private func remoteKey(_ remote: MailAttachmentReference) -> String {
        "\(remote.account)|\(remote.uidValidity)|\(remote.uid)|\(remote.partID)"
    }

    public func registerRemote(_ message: InvoiceMailMessage) throws {
        var updated = items
        for attachment in message.attachments {
            let key = remoteKey(attachment.remote)
            guard expandedArchives[key] == nil,
                  !updated.contains(where: { $0.remote.map(remoteKey) == key }) else { continue }
            let name = URL(fileURLWithPath: attachment.filename).lastPathComponent
            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            guard ["pdf", "png", "jpg", "jpeg", "heic", "heif", "zip"].contains(ext) else { continue }
            let id = UUID()
            var item = InboxInvoice(id: id, storedFilename: id.uuidString + "." + ext, originalFilename: name,
                fingerprint: "remote:" + key, amount: InvoiceStore.amountInFilename(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent),
                warning: nil, receivedAt: message.receivedAt, buyerTitle: "", sellerTitle: "", itemDescription: "",
                source: message.sender + " · " + message.subject, mailID: message.id, projectID: nil, projectInvoiceID: nil)
            item.remote = attachment.remote
            updated.append(item)
        }
        try persist(updated)
        items = updated
    }

    @discardableResult public func download(_ id: UUID) async throws -> Set<UUID> {
        guard let item = items.first(where: { $0.id == id }) else { throw failure("发票不存在，请刷新后重试。") }
        if isDownloaded(item), !item.fingerprint.hasPrefix("remote:"), item.warning == nil,
           (item.amount ?? .zero) > 0 {
            if item.buyerTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do { try await rerecognize(id) }
                catch { lastError = "发票已下载，抬头补充识别失败：\(error.localizedDescription)" }
            }
            return [id]
        }
        guard !pendingIDs.contains(id) else { throw failure("该发票正在下载或识别，请稍后再试。") }
        pendingIDs.insert(id)
        defer { pendingIDs.remove(id) }
        let cached = isDownloaded(item)
        let data: Data
        if cached {
            let url = sourceURL(for: item)
            data = try await Task.detached { try Data(contentsOf: url) }.value
        } else {
            guard let remote = item.remote else { throw failure("找不到本地发票文件，请重新导入。") }
            data = try await QQMailboxClient.fetchAttachment(credentials: QQMailboxConfiguration.credentials(), reference: remote)
        }
        guard !data.isEmpty, data.count <= 40 * 1024 * 1024 else { throw failure("附件为空或超过 40 MB。") }
        if URL(fileURLWithPath: item.originalFilename).pathExtension.lowercased() == "zip" {
            guard let remote = item.remote else { throw failure("压缩包来源信息缺失，请重新导入。") }
            let attachments = try await Task.detached { try Self.readArchive(data) }.value
            var childIDs: Set<UUID> = []
            for attachment in attachments {
                try await importData(attachment.data, filename: attachment.name, receivedAt: item.receivedAt, source: item.source, mailID: item.mailID)
                let hash = SHA256.hash(data: attachment.data).map { String(format: "%02x", $0) }.joined()
                if let child = items.first(where: { $0.fingerprint == hash }) { childIDs.insert(child.id) }
            }
            var archives = expandedArchives
            archives[remoteKey(remote)] = childIDs
            let updated = items.filter { $0.id != id }
            try persist(updated, archives: archives)
            expandedArchives = archives
            items = updated
            return childIDs
        }
        let destination = sourceURL(for: item)
        if !cached { try data.write(to: destination, options: .atomic) }
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw failure("发票已移除。") }
        var updated = items
        updated[index].fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let duplicate = updated.contains { $0.id != id && $0.fingerprint == updated[index].fingerprint && isDownloaded($0) }
        updated[index].warning = duplicate ? "重复发票，发票箱中已有相同文件。" : "正在识别金额和抬头…"
        try persist(updated)
        items = updated
        try await recognize(id, at: destination, namedAmount: item.amount)
        if duplicate, let current = items.firstIndex(where: { $0.id == id }) {
            updated = items
            updated[current].warning = "重复发票，发票箱中已有相同文件。"
            try persist(updated)
            items = updated
        }
        return [id]
    }

    public func rerecognize(_ id: UUID) async throws {
        guard let item = items.first(where: { $0.id == id }), isDownloaded(item) else {
            throw failure("请先下载发票，再重新识别。")
        }
        guard !pendingIDs.contains(id) else { throw failure("该发票正在处理，请稍后再试。") }
        pendingIDs.insert(id)
        defer { pendingIDs.remove(id) }
        try await recognize(id, at: sourceURL(for: item), namedAmount: item.amount, metadataOnly: true)
    }

    public func refreshMissingTitles() async {
        guard canWrite else { return }
        let ids = items.filter { isDownloaded($0) && $0.buyerTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.id)
        for id in ids where !pendingIDs.contains(id) {
            guard !Task.isCancelled else { return }
            do { try await rerecognize(id) }
            catch { lastError = "补充识别发票抬头失败：\(error.localizedDescription)" }
        }
    }

    private func importData(_ data: Data, filename: String, receivedAt: Date, source: String, mailID: String?) async throws {
        guard !data.isEmpty, data.count <= 40 * 1024 * 1024 else { throw failure("发票文件为空或超过 40 MB。") }
        let name = URL(fileURLWithPath: filename).lastPathComponent
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if ext == "zip" {
            let attachments = try await Task.detached { try Self.readArchive(data) }.value
            for attachment in attachments {
                try await importData(attachment.data, filename: attachment.name, receivedAt: receivedAt, source: source, mailID: mailID)
            }
            return
        }
        guard ["pdf", "png", "jpg", "jpeg", "heic", "heif"].contains(ext) else { throw failure("不支持的发票格式：\(name)") }
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard !items.contains(where: { $0.fingerprint == fingerprint }) else { return }
        let id = UUID()
        let stored = id.uuidString + "." + ext
        let destination = filesDirectory.appendingPathComponent(stored)
        try data.write(to: destination, options: .atomic)
        let amount = InvoiceStore.amountInFilename(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent)
        var updated = items
        updated.append(InboxInvoice(id: id, storedFilename: stored, originalFilename: name, fingerprint: fingerprint,
                                    amount: amount, warning: "正在识别金额和抬头…", receivedAt: receivedAt,
                                    buyerTitle: "", sellerTitle: "", itemDescription: "", source: source, mailID: mailID,
                                    projectID: nil, projectInvoiceID: nil))
        try persist(updated)
        items = updated
        pendingIDs.insert(id)
        defer { pendingIDs.remove(id) }
        try await recognize(id, at: destination, namedAmount: amount)
    }

    private func recognize(_ id: UUID, at destination: URL, namedAmount: Decimal?, metadataOnly: Bool = false) async throws {
        let result: (text: String, buyer: String, seller: String, item: String)
        do {
            result = try await Task.detached(priority: .userInitiated) {
                let text = try InvoiceStore.invoiceText(at: destination)
                let details = try InvoicePartyRecognition.details(at: destination, text: text)
                return (text, details.buyer, details.seller, details.item)
            }.value
        } catch {
            if !metadataOnly, let index = items.firstIndex(where: { $0.id == id }) {
                var updated = items
                updated[index].warning = "文字识别失败，请核对金额和抬头，或重试下载识别。"
                try persist(updated)
                items = updated
            }
            throw failure("文件已下载，但文字识别失败，可重试识别或手动填写。")
        }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items
        if !metadataOnly, !editedIDs.contains(id) {
            updated[index].amount = namedAmount ?? InvoiceStore.totalAmount(in: result.text)
        }
        // Money edits do not suppress title completion; an existing title is never overwritten.
        if updated[index].buyerTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated[index].buyerTitle = result.buyer
        }
        if !metadataOnly || updated[index].sellerTitle.isEmpty { updated[index].sellerTitle = result.seller }
        if !metadataOnly || updated[index].itemDescription.isEmpty { updated[index].itemDescription = result.item }
        if !metadataOnly { updated[index].warning = (updated[index].amount ?? .zero) > 0 ? nil : "未识别到金额，请手动填写。" }
        try persist(updated)
        items = updated
    }

    public func update(_ id: UUID, amount: String, buyerTitle: String) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].projectID == nil else { throw failure("请先从项目中移除该发票，再修改发票箱中的金额或抬头。") }
        let input = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = input.range(of: #"^[0-9]+(?:\.[0-9]{1,2})?$"#, options: .regularExpression) == nil
            ? nil : Decimal(string: input, locale: Locale(identifier: "en_US_POSIX"))
        var updated = items
        updated[index].amount = value
        updated[index].buyerTitle = buyerTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        updated[index].warning = (value ?? .zero) > 0 ? nil : "请填写大于 0 的发票金额。"
        try persist(updated)
        editedIDs.insert(id)
        items = updated
    }

    public func assign(ids: Set<UUID>, to project: DraftSummary) throws {
        guard !ids.isEmpty else { return }
        try refreshAssignments()
        let expected = projectsDirectory.appendingPathComponent(project.id.uuidString, isDirectory: true)
        guard project.url.standardizedFileURL == expected.standardizedFileURL,
              FileManager.default.fileExists(atPath: project.url.appendingPathComponent("draft.json").path),
              try project.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw failure("项目不存在，请重新选择。")
        }
        let selected = items.filter { ids.contains($0.id) }
        guard selected.count == ids.count else { throw failure("部分发票不存在，请刷新后重试。") }
        guard selected.allSatisfy({ isDownloaded($0) && !$0.fingerprint.hasPrefix("remote:") }) else {
            throw failure("请先下载所选发票并完成识别，下载中断的发票可点击预览重试。")
        }
        guard !selected.contains(where: { pendingIDs.contains($0.id) || ($0.amount ?? .zero) <= 0 || $0.warning != nil }) else {
            throw failure("请等待识别完成，并补齐所选发票的金额。")
        }
        guard !selected.contains(where: { item in
            items.contains { $0.fingerprint == item.fingerprint && $0.projectID != nil && $0.projectID != project.id }
        }) else {
            throw failure("所选发票已加入其他项目，请先从原项目移除。")
        }
        let hashes = Set(selected.map(\.fingerprint))
        let projectFolders = try FileManager.default.contentsOfDirectory(at: projectsDirectory,
            includingPropertiesForKeys: [.isSymbolicLinkKey])
        for folder in projectFolders where folder.lastPathComponent != project.id.uuidString {
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent("draft.json").path) else { continue }
            let saved = folder.appendingPathComponent("invoices.json")
            guard FileManager.default.fileExists(atPath: saved.path) else { continue }
            let other = try JSONDecoder().decode([Invoice].self, from: Data(contentsOf: saved))
            guard !other.contains(where: { hashes.contains($0.fingerprint) }) else {
                throw failure("所选发票已存在于其他项目，请先从原项目移除。")
            }
        }
        let metadata = project.url.appendingPathComponent("invoices.json")
        var projectInvoices = FileManager.default.fileExists(atPath: metadata.path)
            ? try JSONDecoder().decode([Invoice].self, from: Data(contentsOf: metadata)) : []
        let projectFiles = project.url.appendingPathComponent("invoices", isDirectory: true)
        try FileManager.default.createDirectory(at: projectFiles, withIntermediateDirectories: true)
        var updated = items
        for item in selected {
            let projectInvoice: Invoice
            if let existing = projectInvoices.first(where: { $0.fingerprint == item.fingerprint }) {
                projectInvoice = existing
            } else {
                let id = UUID()
                let stored = id.uuidString + "." + URL(fileURLWithPath: item.storedFilename).pathExtension
                try FileManager.default.copyItem(at: sourceURL(for: item), to: projectFiles.appendingPathComponent(stored))
                projectInvoice = Invoice(id: id, storedFilename: stored, originalFilename: item.originalFilename,
                                         fingerprint: item.fingerprint, amount: item.amount, warning: item.warning)
                projectInvoices.append(projectInvoice)
            }
            if let index = updated.firstIndex(where: { $0.id == item.id }) {
                updated[index].projectID = project.id
                updated[index].projectInvoiceID = projectInvoice.id
            }
        }
        // Write the project first; retrying after an inbox save failure reuses the same fingerprint.
        try JSONEncoder().encode(projectInvoices).write(to: metadata, options: .atomic)
        try persist(updated)
        items = updated
    }

    public func refreshAssignments() throws {
        var updated = items
        var projects: [UUID: [Invoice]] = [:]
        for index in updated.indices {
            guard let projectID = updated[index].projectID else { continue }
            if projects[projectID] == nil {
                let project = projectsDirectory.appendingPathComponent(projectID.uuidString, isDirectory: true)
                let metadata = project.appendingPathComponent("invoices.json")
                if FileManager.default.fileExists(atPath: project.appendingPathComponent("draft.json").path),
                   FileManager.default.fileExists(atPath: metadata.path) {
                    projects[projectID] = try JSONDecoder().decode([Invoice].self, from: Data(contentsOf: metadata))
                } else { projects[projectID] = [] }
            }
            if projects[projectID]?.contains(where: { $0.id == updated[index].projectInvoiceID && $0.fingerprint == updated[index].fingerprint }) != true {
                updated[index].projectID = nil
                updated[index].projectInvoiceID = nil
            }
        }
        try persist(updated)
        items = updated
    }

    private func persist(_ updated: [InboxInvoice], archives: [String: Set<UUID>]? = nil) throws {
        guard canWrite else { throw failure("发票箱资料无法读取，已停止保存，请先处理读取错误。") }
        try JSONEncoder().encode(InboxSnapshot(items: updated, expandedArchives: archives ?? expandedArchives))
            .write(to: directory.appendingPathComponent("inbox.json"), options: .atomic)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "InvoiceInbox", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    nonisolated static func invoiceDetails(in text: String) -> (buyer: String, seller: String, item: String) {
        InvoicePartyRecognition.details(in: text)
    }

    nonisolated static func readArchive(_ data: Data) throws -> [(name: String, data: Data)] {
        func error() -> NSError { NSError(domain: "InvoiceInbox", code: 2, userInfo: [NSLocalizedDescriptionKey: "压缩包无效、含不安全路径或超过大小限制，请解压后手动导入。"] ) }
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard data.count >= 22 else { throw error() }
        guard let end = stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1)
            .first(where: { u32($0) == 0x06054b50 && $0 + 22 + u16($0 + 20) == data.count }) else { throw error() }
        let count = u16(end + 10)
        guard u16(end + 4) == 0, u16(end + 6) == 0, count == u16(end + 8), count <= 300 else { throw error() }
        var position = u32(end + 16)
        var names: [String] = []
        var total = 0
        for _ in 0..<count {
            guard position >= 0, position + 46 <= end, u32(position) == 0x02014b50 else { throw error() }
            let nameLength = u16(position + 28), extra = u16(position + 30), comment = u16(position + 32)
            guard position + 46 + nameLength + extra + comment <= end, u16(position + 8) & 1 == 0 else { throw error() }
            guard let name = String(data: data[(position + 46)..<(position + 46 + nameLength)], encoding: .utf8),
                  !name.hasPrefix("/"), !name.hasPrefix("\\"), !name.contains("\\"),
                  !name.split(separator: "/").contains(".."), !name.contains(":"),
                  name.rangeOfCharacter(from: .controlCharacters) == nil,
                  !name.contains("*"), !name.contains("?"), !name.contains("[") else { throw error() }
            let mode = u32(position + 38) >> 16
            guard mode & 0xf000 != 0xa000 else { throw error() }
            let size = u32(position + 24)
            guard size <= 40 * 1024 * 1024 else { throw error() }
            total += size
            guard total <= 100 * 1024 * 1024 else { throw error() }
            if ["pdf", "png", "jpg", "jpeg", "heic", "heif"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()), !name.hasSuffix("/") { names.append(name) }
            position += 46 + nameLength + extra + comment
        }
        guard !names.isEmpty, Set(names).count == names.count else { throw error() }
        // No archive paths are written: unzip streams only validated invoice entries to memory.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-inbox-\(UUID().uuidString).zip")
        try data.write(to: temporary, options: .atomic)
        var result: [(String, Data)] = []
        var extractionError: Error?
        do {
            var actualTotal = 0
            for name in names {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-p", temporary.path, name]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                var content = Data()
                while let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                    content.append(chunk)
                    if content.count > 40 * 1024 * 1024 || actualTotal + content.count > 100 * 1024 * 1024 {
                        process.terminate()
                        process.waitUntilExit()
                        throw error()
                    }
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw error() }
                actualTotal += content.count
                result.append((URL(fileURLWithPath: name).lastPathComponent, content))
            }
        } catch { extractionError = error }
        let trash = Process()
        trash.executableURL = URL(fileURLWithPath: "/usr/bin/trash")
        trash.arguments = [temporary.path]
        try trash.run()
        trash.waitUntilExit()
        guard trash.terminationStatus == 0 else {
            throw NSError(domain: "InvoiceInbox", code: 3, userInfo: [NSLocalizedDescriptionKey: "临时压缩包无法移入废纸篓，已停止：\(temporary.path)"])
        }
        if let extractionError { throw extractionError }
        return result
    }
}
