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
    public var documentPolicyRevision: Int? = nil

    public var isAccepted: Bool {
        documentPolicyRevision == InvoiceDocumentClassifier.policyRevision
            && (documentKind == .invoice || (documentKind == .unknown && manuallyConfirmed == true))
    }
}

@MainActor public final class InvoiceStore: ObservableObject {
    @Published public private(set) var invoices: [Invoice] = []
    @Published public private(set) var pendingIDs: Set<UUID> = []
    @Published public private(set) var lastError: String?

    private var directory: URL?

    public init() {}

    public var acceptedInvoices: [Invoice] { invoices.filter(\.isAccepted) }
    public var excludedCount: Int { invoices.filter { $0.documentKind == .nonInvoice && !pendingIDs.contains($0.id) }.count }
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
        lastError = nil
        do {
            try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
            let metadata = directory.appendingPathComponent("invoices.json")
            invoices = FileManager.default.fileExists(atPath: metadata.path)
                ? try JSONDecoder().decode([Invoice].self, from: Data(contentsOf: metadata)) : []
            validateLegacyInvoices()
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
        let existing = Set(invoices.map(\.id))
        invoices += stored.filter { !existing.contains($0.id) }
        validateLegacyInvoices()
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
        defer { pendingIDs.remove(id) }
        do {
            guard Self.isSupported(url) else {
                lastError = "不支持的发票格式：\(url.lastPathComponent)"
                return
            }
            let result = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                let classification = InvoiceDocumentClassifier.classify(at: url, text: "", filename: url.lastPathComponent)
                let text = classification.kind == .invoice ? ((try? Self.invoiceText(at: url)) ?? "") : ""
                let amount = classification.kind == .invoice
                    ? Self.amountInFilename(url.deletingPathExtension().lastPathComponent)
                        ?? (try? InvoiceAmountRecognition.total(at: url, text: text)) : nil
                return (data, classification.kind, classification.reason, amount)
            }.value
            guard directory == currentDirectory else { return }
            let hash = SHA256.hash(data: result.0).map { String(format: "%02x", $0) }.joined()
            guard !invoices.contains(where: { $0.fingerprint == hash }) else {
                lastError = "已跳过重复发票：\(url.lastPathComponent)"
                return
            }
            let filename = id.uuidString + "." + url.pathExtension.lowercased()
            try result.0.write(to: filesDirectory.appendingPathComponent(filename), options: .atomic)
            invoices.append(Invoice(id: id, storedFilename: filename,
                                    originalFilename: url.lastPathComponent, fingerprint: hash,
                                    amount: result.3,
                                    warning: result.1 == .invoice ? (result.3 == nil ? "未识别到价税合计，请手动填写。" : nil) : result.2,
                                    documentKind: result.1, documentReason: result.2,
                                    documentPolicyRevision: InvoiceDocumentClassifier.policyRevision))
            try save()
        } catch {
            lastError = "导入发票失败：\(error.localizedDescription)"
        }
    }

    private func validateLegacyInvoices() {
        guard let currentDirectory = directory else { return }
        for invoice in invoices where invoice.documentPolicyRevision != InvoiceDocumentClassifier.policyRevision && !pendingIDs.contains(invoice.id) {
            pendingIDs.insert(invoice.id)
            let source = sourceURL(for: invoice)
            Task {
                let result = await Task.detached(priority: .utility) {
                    InvoiceDocumentClassifier.classify(at: source, text: "", filename: invoice.originalFilename)
                }.value
                guard directory == currentDirectory,
                      let index = invoices.firstIndex(where: { $0.id == invoice.id }) else { return }
                let previousReason = invoices[index].documentReason
                invoices[index].documentKind = result.kind
                invoices[index].documentReason = result.reason
                invoices[index].manuallyConfirmed = nil
                if result.kind != .invoice { invoices[index].warning = result.reason }
                else if (invoices[index].amount ?? .zero) <= 0 {
                    invoices[index].warning = "请填写大于 0 的发票金额。"
                } else if invoices[index].warning == previousReason {
                    invoices[index].warning = nil
                }
                invoices[index].documentPolicyRevision = InvoiceDocumentClassifier.policyRevision
                pendingIDs.remove(invoice.id)
                do { try save() } catch { lastError = "保存发票识别结果失败：\(error.localizedDescription)" }
            }
        }
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
