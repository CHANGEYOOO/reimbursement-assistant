import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import Vision

public struct Invoice: Identifiable, Codable, Sendable {
    public let id: UUID
    public let storedFilename: String
    public let originalFilename: String
    public let fingerprint: String
    public var amount: Decimal?
    public var warning: String?
    public var documentKind: InvoiceDocumentKind? = nil
    public var documentPolicyRevision: Int? = nil

    public var isAccepted: Bool {
        documentKind == .invoice && documentPolicyRevision == InvoiceDocumentClassifier.policyRevision
    }
}

@MainActor public final class InvoiceStore: ObservableObject {
    @Published public private(set) var invoices: [Invoice] = []
    @Published public private(set) var pendingIDs: Set<UUID> = []
    @Published public private(set) var lastError: String?

    private var directory: URL?

    public init() {}

    public var acceptedInvoices: [Invoice] { invoices.filter(\.isAccepted) }
    public var excludedCount: Int { invoices.filter { !$0.isAccepted && !pendingIDs.contains($0.id) }.count }

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
                let text = try Self.invoiceText(at: url)
                let classification = InvoiceDocumentClassifier.classify(at: url, text: text, filename: url.lastPathComponent)
                let amount = classification.kind == .invoice
                    ? Self.amountInFilename(url.deletingPathExtension().lastPathComponent)
                        ?? (try? InvoiceAmountRecognition.total(at: url, text: text)) : nil
                return (data, classification.kind, classification.reason, amount)
            }.value
            guard directory == currentDirectory else { return }
            guard result.1 == .invoice else {
                lastError = "已排除：\(url.lastPathComponent)。\(result.2)"
                return
            }
            let hash = SHA256.hash(data: result.0).map { String(format: "%02x", $0) }.joined()
            guard !invoices.contains(where: { $0.fingerprint == hash }) else {
                lastError = "已跳过重复发票：\(url.lastPathComponent)"
                return
            }
            let filename = id.uuidString + "." + url.pathExtension.lowercased()
            try result.0.write(to: filesDirectory.appendingPathComponent(filename), options: .atomic)
            invoices.append(Invoice(id: id, storedFilename: filename,
                                    originalFilename: url.lastPathComponent, fingerprint: hash,
                                    amount: result.3, warning: result.3 == nil ? "未识别到价税合计，请手动填写。" : nil,
                                    documentKind: .invoice, documentPolicyRevision: InvoiceDocumentClassifier.policyRevision))
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
                let kind = await Task.detached(priority: .utility) {
                    guard let text = try? Self.invoiceText(at: source) else { return InvoiceDocumentKind.nonInvoice }
                    return InvoiceDocumentClassifier.classify(at: source, text: text, filename: invoice.originalFilename).kind
                }.value
                guard directory == currentDirectory,
                      let index = invoices.firstIndex(where: { $0.id == invoice.id }) else { return }
                invoices[index].documentKind = kind == .invoice ? .invoice : .nonInvoice
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
            let extract = Process()
            extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            extract.arguments = ["-x", "-k", url.path, temporary.path]
            try extract.run()
            extract.waitUntilExit()
            guard extract.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
            let files = FileManager.default.enumerator(at: temporary, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])?
                .allObjects.compactMap { $0 as? URL }
                .filter { file in
                    guard Self.isSupported(file),
                          let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                    return values.isRegularFile == true && values.isSymbolicLink != true
                } ?? []
            guard !files.isEmpty else { throw CocoaError(.fileReadUnknown) }
            for file in files { await importFile(file) }
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
        return ["png", "jpg", "jpeg", "heic", "heif", "pdf"].contains(url.pathExtension.lowercased())
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
        if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
            if let text = pdf.string, text.count > 30 { return text }
            return try (0..<min(pdf.pageCount, 3)).compactMap { index in
                guard let image = pdf.page(at: index)?.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                return try recognizedText(image)
            }.joined(separator: "\n")
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
