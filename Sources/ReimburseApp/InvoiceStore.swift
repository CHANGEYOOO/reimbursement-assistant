import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO
import Vision

public struct Invoice: Identifiable, Codable, Sendable {
    public let id: UUID
    public let storedFilename: String
    public let originalFilename: String
    public let fingerprint: String
    public var amount: Decimal?
    public var warning: String?
    public var documentKind: InvoiceDocumentKind? = nil
    public var documentReason: String? = nil
    public var manuallyConfirmed: Bool? = nil
    public var manuallyImported: Bool? = nil
    public var documentPolicyRevision: Int? = nil

    public var isAccepted: Bool {
        manuallyImported == true || (documentPolicyRevision == InvoiceDocumentClassifier.policyRevision
            && (documentKind == .invoice || (documentKind == .unknown && manuallyConfirmed == true)))
    }
}

@MainActor public final class InvoiceStore: ObservableObject {
    @Published public private(set) var invoices: [Invoice] = []
    @Published public private(set) var pendingIDs: Set<UUID> = []
    @Published public private(set) var lastError: String?
    @Published private var aiStatuses: [UUID: String] = [:]
    public var aiStatus: String? { aiStatuses.isEmpty ? nil : aiStatuses.values.sorted().joined(separator: "\n") }

    private var directory: URL?
    private var amountRevisions: [UUID: Int] = [:]

    public init() {}

    public var acceptedInvoices: [Invoice] { invoices.filter(\.isAccepted) }
    public var excludedCount: Int { invoices.filter { !$0.isAccepted && $0.documentKind == .nonInvoice && !pendingIDs.contains($0.id) }.count }
    public var unknownCount: Int { invoices.filter { !$0.isAccepted && $0.documentKind != .nonInvoice && !pendingIDs.contains($0.id) }.count }

    public var total: Decimal {
        acceptedInvoices.filter { !needsConfirmation($0) }.reduce(Decimal.zero) { $0 + ($1.amount ?? .zero) }
    }

    public var confirmationCount: Int {
        acceptedInvoices.filter(needsConfirmation).count + pendingIDs.count
    }

    public func needsConfirmation(_ invoice: Invoice) -> Bool {
        !invoice.isAccepted || pendingIDs.contains(invoice.id) || (invoice.amount ?? .zero) <= 0 || invoice.warning != nil
    }

    public func configure(directory: URL) {
        self.directory = directory
        pendingIDs.removeAll()
        aiStatuses.removeAll()
        amountRevisions.removeAll()
        lastError = nil
        do {
            try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
            let metadata = directory.appendingPathComponent("invoices.json")
            invoices = FileManager.default.fileExists(atPath: metadata.path)
                ? try JSONDecoder().decode([Invoice].self, from: Data(contentsOf: metadata)) : []
            validateLegacyInvoices()
            Task {
                guard self.directory == directory else { return }
                await automaticallyAssistUnresolvedInvoices()
            }
        } catch {
            invoices = []
            self.directory = nil
            lastError = "读取发票夹失败：\(error.localizedDescription)"
        }
    }

    public func refreshFromDisk() throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let metadata = directory.appendingPathComponent("invoices.json")
        guard FileManager.default.fileExists(atPath: metadata.path) else { return }
        let stored = try JSONDecoder().decode([Invoice].self, from: Data(contentsOf: metadata))
        for incoming in stored where incoming.manuallyImported == true {
            guard let index = invoices.firstIndex(where: { $0.id == incoming.id }) else { continue }
            invoices[index].manuallyImported = true
            invoices[index].documentKind = incoming.documentKind
            invoices[index].documentReason = incoming.documentReason
            invoices[index].documentPolicyRevision = incoming.documentPolicyRevision
            if invoices[index].amount == nil, amountRevisions[incoming.id, default: 0] == 0 {
                invoices[index].amount = incoming.amount
            }
            let hasAmount = (invoices[index].amount ?? .zero) > 0
            let amountWarnings = ["未识别到价税合计，请手动填写。", "请填写大于 0 的发票金额。"]
            invoices[index].warning = hasAmount
                ? (amountWarnings.contains(incoming.warning ?? "") ? nil : incoming.warning)
                : incoming.warning ?? "请填写大于 0 的发票金额。"
        }
        let existing = Set(invoices.map(\.id))
        invoices += stored.filter { !existing.contains($0.id) }
        validateLegacyInvoices()
        Task {
            guard self.directory == directory else { return }
            await automaticallyAssistUnresolvedInvoices()
        }
    }

    public func sourceURL(for invoice: Invoice) -> URL {
        filesDirectory.appendingPathComponent(invoice.storedFilename)
    }

    public func importFiles(_ urls: [URL]) {
        guard directory != nil else { lastError = "请先打开或新建报销单。"; return }
        for url in urls {
            Task {
                if url.pathExtension.lowercased() == "zip" { await importArchive(url) }
                else { await importFile(url) }
            }
        }
    }

    private func importFile(_ url: URL) async {
        let currentDirectory = directory
        let id = UUID()
        pendingIDs.insert(id)
        defer { if directory == currentDirectory { pendingIDs.remove(id) } }
        do {
            guard Self.isSupported(url) else {
                lastError = "不支持的发票格式：\(url.lastPathComponent)"
                return
            }
            let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
            guard directory == currentDirectory else { return }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let targetID: UUID
            let reason = "手动导入，按用户提供的发票保留。"
            if let index = invoices.firstIndex(where: { $0.fingerprint == hash }) {
                targetID = invoices[index].id
                let stored = sourceURL(for: invoices[index])
                if !FileManager.default.fileExists(atPath: stored.path) { try data.write(to: stored, options: .atomic) }
                invoices[index].manuallyImported = true
                invoices[index].documentKind = .invoice
                invoices[index].documentReason = reason
                invoices[index].documentPolicyRevision = InvoiceDocumentClassifier.policyRevision
            } else {
                targetID = id
                let filename = id.uuidString + "." + url.pathExtension.lowercased()
                try data.write(to: filesDirectory.appendingPathComponent(filename), options: .atomic)
                invoices.append(Invoice(id: id, storedFilename: filename, originalFilename: url.lastPathComponent,
                    fingerprint: hash, amount: nil, warning: "正在识别发票金额…", documentKind: .invoice,
                    documentReason: reason, manuallyImported: true, documentPolicyRevision: InvoiceDocumentClassifier.policyRevision))
            }
            try save()
            let amountRevision = amountRevisions[targetID, default: 0]
            let stored = sourceURL(for: invoices.first { $0.id == targetID }!)
            let amount = await Task.detached(priority: .userInitiated) {
                Self.amountInFilename(url.deletingPathExtension().lastPathComponent)
                    ?? (try? Self.recognizeTotal(at: stored))
            }.value
            guard directory == currentDirectory, let index = invoices.firstIndex(where: { $0.id == targetID }) else { return }
            if amountRevisions[targetID, default: 0] == amountRevision, (invoices[index].amount ?? .zero) <= 0 {
                invoices[index].amount = amount
            }
            invoices[index].warning = (invoices[index].amount ?? .zero) > 0 ? nil : "未识别到价税合计，请手动填写。"
            try save()
        } catch {
            if directory == currentDirectory { lastError = "导入发票失败：\(error.localizedDescription)" }
        }
    }

    private func validateLegacyInvoices() {
        guard let currentDirectory = directory else { return }
        for invoice in invoices where invoice.manuallyImported != true && invoice.documentPolicyRevision != InvoiceDocumentClassifier.policyRevision && !pendingIDs.contains(invoice.id) {
            pendingIDs.insert(invoice.id)
            let source = sourceURL(for: invoice)
            let amountRevision = amountRevisions[invoice.id, default: 0]
            Task {
                defer { if directory == currentDirectory { pendingIDs.remove(invoice.id) } }
                let local = await Task.detached(priority: .utility) {
                    InvoiceDocumentClassifier.classify(at: source, text: "", filename: invoice.originalFilename)
                }.value
                guard directory == currentDirectory, invoices.first(where: { $0.id == invoice.id })?.manuallyImported != true else { return }
                let result = invoice.manuallyConfirmed == true ? local : await reviewWithAI(at: source, local: local, id: invoice.id, filename: invoice.originalFilename)
                guard directory == currentDirectory else { return }
                let amount = await Task.detached(priority: .utility) {
                    guard result.kind == .invoice, (invoice.amount ?? .zero) <= 0 else { return Optional<Decimal>.none }
                    let text = (try? Self.invoiceText(at: source)) ?? ""
                    return Self.amountInFilename(invoice.originalFilename) ?? (try? InvoiceAmountRecognition.total(at: source, text: text))
                }.value
                guard directory == currentDirectory,
                      let index = invoices.firstIndex(where: { $0.id == invoice.id }), invoices[index].manuallyImported != true else { return }
                if amountRevisions[invoice.id, default: 0] == amountRevision, (invoices[index].amount ?? .zero) <= 0, let amount {
                    invoices[index].amount = amount
                }
                let previousReason = invoices[index].documentReason
                invoices[index].documentKind = result.kind
                invoices[index].documentReason = result.reason
                invoices[index].manuallyConfirmed = nil
                if result.kind != .invoice { invoices[index].warning = result.reason }
                else if (invoices[index].amount ?? .zero) <= 0 {
                    invoices[index].warning = "请填写大于 0 的发票金额。"
                } else if invoices[index].warning == previousReason || (amount != nil && ["未识别到价税合计，请手动填写。", "请填写大于 0 的发票金额。"].contains(invoices[index].warning ?? "")) {
                    invoices[index].warning = nil
                }
                invoices[index].documentPolicyRevision = InvoiceDocumentClassifier.policyRevision
                do { try save() } catch { lastError = "保存发票识别结果失败：\(error.localizedDescription)" }
            }
        }
    }

    private func reviewWithAI(at url: URL, local: (kind: InvoiceDocumentKind, reason: String), id: UUID, filename: String? = nil) async -> (kind: InvoiceDocumentKind, reason: String) {
        let currentDirectory = directory
        defer { if directory == currentDirectory { aiStatuses[id] = nil } }
        return await InvoiceAIFallback.reviewIfNeeded(at: url, local: local, willUpload: {
            guard self.directory == currentDirectory else { return }
            self.aiStatuses[id] = "本地待确认，AI正在发送提取文字及页面预览：" + (filename ?? url.lastPathComponent)
        })
    }

    private func importArchive(_ url: URL) async {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("reimbursement-invoices-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let attachments = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                guard data.count <= 40 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                return try InvoiceInboxStore.readArchive(data)
            }.value
            for attachment in attachments {
                let file = temporary.appendingPathComponent(attachment.name)
                try attachment.data.write(to: file, options: .atomic)
                await importFile(file)
            }
        } catch {
            lastError = "压缩包导入失败：\(error.localizedDescription)"
        }
        if FileManager.default.fileExists(atPath: temporary.path) {
            let trash = Process()
            trash.executableURL = URL(fileURLWithPath: "/usr/bin/trash")
            trash.arguments = [temporary.path]
            do {
                try trash.run()
                trash.waitUntilExit()
                guard trash.terminationStatus == 0 else { throw CocoaError(.fileWriteNoPermission) }
            } catch {
                lastError = "临时目录无法移入废纸篓，请手动处理：\(temporary.path)"
            }
        }
    }

    public func automaticallyAssistUnresolvedInvoices() async {
        guard AIConfiguration.enabled, AIConfiguration.invoiceFallbackEnabled, let currentDirectory = directory else { return }
        let ids = invoices.filter { $0.documentKind == .unknown && $0.manuallyConfirmed != true && $0.manuallyImported != true && !pendingIDs.contains($0.id) }.map(\.id)
        for id in ids {
            guard !Task.isCancelled, directory == currentDirectory,
                  AIConfiguration.enabled, AIConfiguration.invoiceFallbackEnabled else { return }
            guard !pendingIDs.contains(id) else { continue }
            do { try await rerecognize(id) }
            catch { if directory == currentDirectory { lastError = "自动补充识别发票失败：\(error.localizedDescription)" } }
        }
    }

    public func rerecognize(_ id: UUID) async throws {
        guard let currentDirectory = directory,
              let invoice = invoices.first(where: { $0.id == id }),
              invoice.documentKind == .unknown, invoice.manuallyConfirmed != true, invoice.manuallyImported != true,
              !pendingIDs.contains(id) else { return }
        let source = sourceURL(for: invoice)
        guard FileManager.default.fileExists(atPath: source.path) else { throw CocoaError(.fileNoSuchFile) }
        let amountRevision = amountRevisions[id, default: 0]
        pendingIDs.insert(id)
        defer { if directory == currentDirectory { pendingIDs.remove(id) } }
        let local = await Task.detached(priority: .userInitiated) {
            InvoiceDocumentClassifier.classify(at: source, text: "", filename: invoice.originalFilename)
        }.value
        guard directory == currentDirectory else { return }
        let result = await reviewWithAI(at: source, local: local, id: id, filename: invoice.originalFilename)
        guard directory == currentDirectory else { return }
        let amount = await Task.detached(priority: .userInitiated) {
            guard result.kind == .invoice else { return Optional<Decimal>.none }
            let text = (try? Self.invoiceText(at: source)) ?? ""
            return Self.amountInFilename(invoice.originalFilename) ?? (try? InvoiceAmountRecognition.total(at: source, text: text))
        }.value
        guard directory == currentDirectory, let index = invoices.firstIndex(where: { $0.id == id }), invoices[index].manuallyImported != true else { return }
        if amountRevisions[id, default: 0] == amountRevision, invoices[index].amount == nil {
            invoices[index].amount = amount
        }
        invoices[index].documentKind = result.kind
        invoices[index].documentReason = result.reason
        invoices[index].documentPolicyRevision = InvoiceDocumentClassifier.policyRevision
        invoices[index].warning = result.kind == .invoice
            ? ((invoices[index].amount ?? .zero) > 0 ? nil : "未识别到价税合计，请手动填写。") : result.reason
        try save()
    }

    public func confirmInvoice(_ id: UUID) throws {
        guard let index = invoices.firstIndex(where: { $0.id == id }),
              !pendingIDs.contains(id), invoices[index].documentKind == .unknown,
              invoices[index].documentPolicyRevision == InvoiceDocumentClassifier.policyRevision else {
            throw NSError(domain: "InvoiceStore", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "仅可人工确认已完成识别的待确认文件；明确的非发票附件不能确认。"])
        }
        guard invoices[index].manuallyConfirmed != true else { return }
        invoices[index].manuallyConfirmed = true
        invoices[index].documentReason = (invoices[index].documentReason ?? "自动识别无法确定文件类型。") + " 已由用户人工确认是电子发票。"
        invoices[index].warning = (invoices[index].amount ?? .zero) > 0 ? nil : "请填写大于 0 的发票金额。"
        try save()
    }

    public func updateAmount(_ text: String, for id: UUID) {
        guard let index = invoices.firstIndex(where: { $0.id == id }) else { return }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = input.range(of: #"^[0-9]+(?:\.[0-9]{1,2})?$"#, options: .regularExpression) == nil
            ? nil : Decimal(string: input, locale: Locale(identifier: "en_US_POSIX"))
        amountRevisions[id, default: 0] += 1
        invoices[index].amount = amount
        invoices[index].warning = (amount ?? .zero) <= 0 ? "请填写大于 0 的发票金额。" : nil
        do { try save() } catch { lastError = "保存发票金额失败：\(error.localizedDescription)" }
    }

    public func delete(_ id: UUID) throws {
        guard let index = invoices.firstIndex(where: { $0.id == id }) else { return }
        let source = sourceURL(for: invoices[index])
        if FileManager.default.fileExists(atPath: source.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/trash")
            process.arguments = [source.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "InvoiceStore", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "移入废纸篓失败，发票未删除。"])
            }
        }
        invoices.remove(at: index)
        pendingIDs.remove(id)
        try save()
    }

    public func exportFolder(to parent: URL, date: Date = Date()) async throws -> URL {
        guard pendingIDs.isEmpty else { throw NSError(domain: "InvoiceStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "请等待发票识别完成。"]) }
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let selected = acceptedInvoices
        guard !selected.isEmpty else { throw NSError(domain: "InvoiceStore", code: 4, userInfo: [NSLocalizedDescriptionKey: "请先导入发票。"]) }
        for invoice in selected {
            guard !needsConfirmation(invoice) else {
                throw NSError(domain: "InvoiceStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "请先确认发票金额：\(invoice.originalFilename)"])
            }
            let source = directory.appendingPathComponent("invoices", isDirectory: true).appendingPathComponent(invoice.storedFilename)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw NSError(domain: "InvoiceStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到发票文件：\(invoice.originalFilename)"])
            }
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        let money = NumberFormatter()
        money.locale = Locale(identifier: "en_US_POSIX")
        money.minimumFractionDigits = 2
        money.maximumFractionDigits = 2
        money.usesGroupingSeparator = false
        let total = selected.reduce(Decimal.zero) { $0 + ($1.amount ?? .zero) }
        let amount = money.string(from: total as NSDecimalNumber) ?? "0.00"
        let name = "\(day)-\(amount)"
        var folder = parent.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(name)(\(suffix))", isDirectory: true)
            suffix += 1
        }
        try export(selected, from: directory, to: folder)
        return folder
    }

    private func export(_ selected: [Invoice], from directory: URL, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, invoice) in selected.enumerated() {
            let source = directory.appendingPathComponent("invoices", isDirectory: true).appendingPathComponent(invoice.storedFilename)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw NSError(domain: "InvoiceStore", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "找不到发票文件：\(invoice.originalFilename)"])
            }
            let original = URL(fileURLWithPath: invoice.originalFilename).lastPathComponent
            var target = folder.appendingPathComponent(String(format: "%03d_", index + 1) + original)
            if FileManager.default.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent(String(format: "%03d_", index + 1) +
                    String(invoice.id.uuidString.prefix(8)) + "_" + original)
            }
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    private var filesDirectory: URL {
        (directory ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("invoices", isDirectory: true)
    }

    private func save() throws {
        guard let directory else { return }
        let data = try JSONEncoder().encode(invoices)
        try data.write(to: directory.appendingPathComponent("invoices.json"), options: .atomic)
    }

    private nonisolated static func isSupported(_ url: URL) -> Bool {
        return InvoiceDocumentClassifier.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func amountInFilename(_ name: String) -> Decimal? {
        let filename = name.replacingOccurrences(
            of: #"(?<!\d)(?:19|20)\d{2}[-._年]\d{1,2}[-._月]\d{1,2}日?(?!\d)|(?<!\d)(?:19|20)\d{6}(?!\d)"#,
            with: " ", options: .regularExpression)
        let patterns = [
            #"(?:价税合计|发票金额|总金额|金额|[¥￥])\s*[:：]?\s*[¥￥]?\s*(\d{1,9}(?:,\d{3})*(?:\.\d{1,2})?)"#,
            #"(?<![\d.])(\d{1,9}(?:\.\d{1,2})?)\s*元"#,
            #"(?<![\d.])(\d{1,9}\.\d{2})(?![\d.])"#,
        ]
        for pattern in patterns {
            let expression = try! NSRegularExpression(pattern: pattern)
            let source = filename as NSString
            let values = Set(expression.matches(in: filename, range: NSRange(location: 0, length: source.length)).compactMap { match -> Decimal? in
                guard let range = Range(match.range(at: 1), in: filename) else { return nil }
                return Decimal(string: filename[range].replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX"))
            }.filter { $0 > 0 })
            if values.count > 1 { return nil }
            if let value = values.first { return value }
        }
        return nil
    }

    nonisolated static func recognizeTotal(at url: URL) throws -> Decimal? {
        let text = try invoiceText(at: url)
        return try InvoiceAmountRecognition.total(at: url, text: text)
    }

    nonisolated static func invoiceText(at url: URL) throws -> String {
        if ["pdf", "ofd", "xml"].contains(url.pathExtension.lowercased()) {
            return LocalInvoiceContent.read(at: url).text
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        return try recognizedText(image)
    }

    private nonisolated static func recognizedText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    nonisolated static func totalAmount(in text: String) -> Decimal? {
        InvoiceAmountRecognition.total(in: text)
    }
}
