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
}

@MainActor public final class InvoiceStore: ObservableObject {
    @Published public private(set) var invoices: [Invoice] = []
    @Published public private(set) var pendingIDs: Set<UUID> = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var companyTitleFallback = ""

    private var directory: URL?
    private var editedIDs: Set<UUID> = []

    public init() {}

    public var total: Decimal {
        invoices.reduce(Decimal.zero) { $0 + ($1.amount ?? .zero) }
    }

    public func configure(directory: URL) {
        self.directory = directory
        pendingIDs.removeAll()
        editedIDs.removeAll()
        lastError = nil
        do {
            try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
            let metadata = directory.appendingPathComponent("invoices.json")
            invoices = FileManager.default.fileExists(atPath: metadata.path)
                ? try JSONDecoder().decode([Invoice].self, from: Data(contentsOf: metadata)) : []
            companyTitleFallback = (try? String(contentsOf: directory.appendingPathComponent("invoice-company.txt"), encoding: .utf8)) ?? ""
        } catch {
            invoices = []
            companyTitleFallback = ""
            self.directory = nil
            lastError = "读取发票夹失败：\(error.localizedDescription)"
        }
    }

    public func sourceURL(for invoice: Invoice) -> URL {
        filesDirectory.appendingPathComponent(invoice.storedFilename)
    }

    public func updateCompanyTitleFallback(_ value: String) {
        companyTitleFallback = value
        guard let directory else { return }
        do {
            try value.write(to: directory.appendingPathComponent("invoice-company.txt"), atomically: true, encoding: .utf8)
        } catch { lastError = "保存发票公司抬头失败：\(error.localizedDescription)" }
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
        do {
            let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
            guard directory == currentDirectory else { return }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard !invoices.contains(where: { $0.fingerprint == hash }) else {
                lastError = "已跳过重复发票：\(url.lastPathComponent)"
                return
            }
            guard Self.isSupported(url) else {
                lastError = "不支持的发票格式：\(url.lastPathComponent)"
                return
            }
            let id = UUID()
            let filename = id.uuidString + "." + url.pathExtension.lowercased()
            let destination = filesDirectory.appendingPathComponent(filename)
            try data.write(to: destination, options: .atomic)
            let namedAmount = Self.amountInFilename(url.deletingPathExtension().lastPathComponent)
            let invoice = Invoice(id: id, storedFilename: filename,
                                  originalFilename: url.lastPathComponent, fingerprint: hash,
                                  amount: namedAmount, warning: namedAmount == nil ? "正在识别价税合计…" : nil)
            invoices.append(invoice)
            try save()
            guard namedAmount == nil else { return }
            pendingIDs.insert(id)
            do {
                let amount = try await Task.detached(priority: .userInitiated) {
                    try Self.recognizeTotal(at: destination)
                }.value
                guard directory == currentDirectory,
                      let index = invoices.firstIndex(where: { $0.id == id }) else { return }
                if !editedIDs.contains(id) { invoices[index].amount = amount }
                invoices[index].warning = amount == nil ? "未识别到价税合计，请手动填写。" : nil
            } catch {
                if let index = invoices.firstIndex(where: { $0.id == id }) {
                    invoices[index].warning = "识别失败，请手动填写。"
                }
            }
            pendingIDs.remove(id)
            try save()
        } catch {
            lastError = "导入发票失败：\(error.localizedDescription)"
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
        editedIDs.insert(id)
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
        editedIDs.remove(id)
        try save()
    }

    public func exportGrouped(to parent: URL, date: Date = Date()) async throws -> [URL] {
        guard pendingIDs.isEmpty else { throw NSError(domain: "InvoiceStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "请等待发票识别完成。"]) }
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let selected = invoices
        var groups: [String: [Invoice]] = [:]
        for invoice in selected {
            guard let amount = invoice.amount, amount > 0 else {
                throw NSError(domain: "InvoiceStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "请先填写发票金额：\(invoice.originalFilename)"])
            }
            let source = directory.appendingPathComponent("invoices", isDirectory: true).appendingPathComponent(invoice.storedFilename)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw NSError(domain: "InvoiceStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到发票文件：\(invoice.originalFilename)"])
            }
            let detected = try await Task.detached(priority: .userInitiated) { try Self.buyerName(at: source) }.value
            guard self.directory == directory else { throw CocoaError(.userCancelled) }
            let buyer = (detected ?? companyTitleFallback).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !buyer.isEmpty else {
                throw NSError(domain: "InvoiceStore", code: 4, userInfo: [NSLocalizedDescriptionKey: "未识别到购买方抬头：\(invoice.originalFilename)。请在发票夹填写抬头。"])
            }
            groups[buyer, default: []].append(invoice)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        let money = NumberFormatter()
        money.locale = Locale(identifier: "en_US_POSIX")
        money.minimumFractionDigits = 2
        money.maximumFractionDigits = 2
        money.usesGroupingSeparator = false
        var exported: [URL] = []
        for buyer in groups.keys.sorted() {
            let group = groups[buyer]!
            let total = group.reduce(Decimal.zero) { $0 + ($1.amount ?? .zero) }
            let amount = money.string(from: total as NSDecimalNumber) ?? "0.00"
            let safeBuyer = buyer.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let name = "\(day)-\(amount)-\(safeBuyer)"
            var folder = parent.appendingPathComponent(name, isDirectory: true)
            var suffix = 2
            while FileManager.default.fileExists(atPath: folder.path) {
                folder = parent.appendingPathComponent("\(name)(\(suffix))", isDirectory: true)
                suffix += 1
            }
            try export(group, from: directory, to: folder)
            exported.append(folder)
        }
        return exported
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

    private nonisolated static func buyerName(at url: URL) throws -> String? {
        if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
            if let name = buyerName(in: pdf.string ?? "") { return name }
            guard let image = pdf.page(at: 0)?.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return try buyerName(in: recognizedText(image))
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return try buyerName(in: recognizedText(image))
    }

    private nonisolated static func buyerName(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("名称：") || line.hasPrefix("名称:") || line.hasPrefix("购买方名称：") else { continue }
            let suffix = line.split(separator: "：", maxSplits: 1).dropFirst().first.map(String.init)
                ?? line.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let candidate = suffix.isEmpty && index + 1 < lines.count ? lines[index + 1] : suffix
            let name = candidate.components(separatedBy: "统一社会信用代码")[0]
                .components(separatedBy: "纳税人识别号")[0]
                .components(separatedBy: .whitespacesAndNewlines).joined()
            if name.count >= 4 { return name }
        }
        return nil
    }

    private nonisolated static func amountInFilename(_ name: String) -> Decimal? {
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

    private nonisolated static func recognizeTotal(at url: URL) throws -> Decimal? {
        if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
            if let amount = totalAmount(in: pdf.string ?? "") { return amount }
            for index in 0..<min(pdf.pageCount, 3) {
                guard let image = pdf.page(at: index)?.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                if let amount = try totalAmount(in: recognizedText(image)) { return amount }
            }
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return try totalAmount(in: recognizedText(image))
    }

    private nonisolated static func recognizedText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private nonisolated static func totalAmount(in text: String) -> Decimal? {
        let lines = text.components(separatedBy: .newlines)
        let amountPattern = #"[¥￥]\s*\d{1,9}(?:,\d{3})*(?:\.\d{1,2})?|\b\d{1,9}\.\d{2}\b"#
        let labels = ["价税合计", "合计金额", "发票金额"]
        var values: [Decimal] = []
        for (index, line) in lines.enumerated() where labels.contains(where: line.contains) {
            let nearby = lines[index..<min(lines.count, index + 9)]
            let small = nearby.firstIndex(where: { $0.contains("小写") })
            let candidates = small.map { position in
                [lines[position]] + (position + 1 < lines.count ? [lines[position + 1]] : [])
            } ?? []
            let source = candidates.first(where: { $0.range(of: amountPattern, options: .regularExpression) != nil }) ?? line
            guard let range = source.range(of: amountPattern, options: .regularExpression),
                  let amount = Decimal(string: String(source[range]).replacingOccurrences(of: ",", with: "")
                    .replacingOccurrences(of: "¥", with: "").replacingOccurrences(of: "￥", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines), locale: Locale(identifier: "en_US_POSIX")), amount > 0 else { continue }
            values.append(amount)
        }
        return Set(values).count == 1 ? values.first : nil
    }
}
