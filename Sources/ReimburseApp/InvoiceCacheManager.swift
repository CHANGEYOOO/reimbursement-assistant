import Combine
import Foundation
import SwiftUI

@MainActor final class InvoiceCacheManager: ObservableObject {
    private static let limitKey = "reimbursement.invoiceCache.limitMB"
    private static let pausedKey = "reimbursement.invoiceCache.pausedAfterFailure"
    private static let bytesPerMB = 1_000_000
    @Published private(set) var limitMB: Int
    @Published private(set) var cacheBytes = 0
    @Published private(set) var message = ""
    @Published private(set) var working = false
    var onCleared: (() -> Void)?
    var onAutomaticFailure: ((String) -> Void)?
    @Published private(set) var suspendedAfterFailure: Bool
    private let inbox: InvoiceInboxStore
    private let defaults: UserDefaults
    private let trash: (URL) throws -> Void
    private var pollingTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var recentProtection: Set<UUID> = []

    init(inbox: InvoiceInboxStore, defaults: UserDefaults = .standard,
         trash: @escaping (URL) throws -> Void = InvoiceCacheManager.trashFile) {
        self.inbox = inbox
        self.defaults = defaults
        self.trash = trash
        suspendedAfterFailure = defaults.bool(forKey: Self.pausedKey)
        let saved = defaults.integer(forKey: Self.limitKey)
        limitMB = saved > 0 && saved <= Int.max / Self.bytesPerMB ? saved : 200
        refresh()
        if suspendedAfterFailure { message = "自动清理已暂停，请检查权限后手动重试。" }
    }

    private func resume() {
        suspendedAfterFailure = false
        defaults.set(false, forKey: Self.pausedKey)
    }

    func retryCleanup() throws { resume(); try enforceLimit() }

    func setLimitMB(_ value: Int) throws {
        guard value > 0, value <= Int.max / Self.bytesPerMB else {
            throw failure("请输入大于 0 的整数缓存上限。")
        }
        limitMB = value
        defaults.set(value, forKey: Self.limitKey)
        resume()
        try enforceLimit()
    }

    func refresh() {
        do { cacheBytes = try entries().reduce(0) { $0 + $1.bytes } }
        catch { message = "无法统计缓存：\(error.localizedDescription)" }
    }

    func enforceLimit(protecting: Set<UUID> = []) throws {
        try clean(all: false, protecting: protecting.union(recentProtection))
    }

    func clearAll() throws {
        resume()
        try clean(all: true, protecting: [])
    }

    func scheduleMaintenance(protecting: Set<UUID>) {
        guard !suspendedAfterFailure else { refresh(); return }
        recentProtection.formUnion(protecting)
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            do { try self.enforceLimit() } catch { self.onAutomaticFailure?(self.message) }
        }
    }

    func start() {
        guard pollingTask == nil else { return }
        scheduleMaintenance(protecting: [])
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.recentProtection.removeAll()
                guard !self.suspendedAfterFailure else { continue }
                do { try self.enforceLimit() } catch { self.onAutomaticFailure?(self.message) }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        recentProtection.removeAll()
    }

    private struct Entry {
        let id: UUID
        let url: URL
        let bytes: Int
        let accessedAt: Date
    }

    private func entries() throws -> [Entry] {
        let directory = inbox.cacheDirectoryURL.standardizedFileURL
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw failure("缓存目录是符号链接，已停止清理。")
        }
        var result: [Entry] = []
        for item in inbox.items where item.remote != nil {
            guard item.storedFilename == (item.storedFilename as NSString).lastPathComponent,
                  item.storedFilename != ".", item.storedFilename != "..", !item.storedFilename.contains("\\") else { continue }
            let url = inbox.sourceURL(for: item).standardizedFileURL
            guard url.deletingLastPathComponent() == directory,
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            result.append(Entry(id: item.id, url: url, bytes: values.fileSize ?? 0,
                accessedAt: item.lastAccessedAt ?? values.contentModificationDate ?? item.receivedAt))
        }
        return result
    }

    private func clean(all: Bool, protecting: Set<UUID>) throws {
        guard !working else { return }
        working = true
        var removed = 0
        defer {
            working = false
            refresh()
            if removed > 0 { onCleared?() }
        }
        do {
            let files = try entries()
            var remaining = files.reduce(0) { $0 + $1.bytes }
            let maximum = limitMB * Self.bytesPerMB
            let eligible = files.filter { !inbox.pendingIDs.contains($0.id) && !inbox.activeCacheIDs.contains($0.id) && !protecting.contains($0.id) }
                .sorted { a, b in a.accessedAt == b.accessedAt ? a.id.uuidString < b.id.uuidString : a.accessedAt < b.accessedAt }
            for entry in eligible where all || remaining > maximum {
                try trash(entry.url)
                remaining -= entry.bytes
                removed += 1
            }
            cacheBytes = remaining
            message = remaining > maximum && !all
                ? "正在使用的附件暂不清理，将在后续检查时重试。"
                : "已清理 \(removed) 个缓存文件，发票记录和项目资料保留。"
        } catch {
            suspendedAfterFailure = true
            defaults.set(true, forKey: Self.pausedKey)
            message = "缓存清理未完成，自动清理已暂停：\(error.localizedDescription)"
            throw error
        }
    }

    nonisolated static func trashFile(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/trash")
        process.arguments = [url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw failure("无法将缓存移入废纸篓，请检查权限后重试。")
        }
    }

    private nonisolated static func failure(_ message: String) -> NSError {
        NSError(domain: "InvoiceCache", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func failure(_ message: String) -> NSError { Self.failure(message) }
}

struct CacheSettingsView: View {
    @ObservedObject var cache: InvoiceCacheManager
    @StateObject private var controls = InvoiceCacheSettingsControls()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("发票缓存管理").font(.title2)
            Text("当前可清理缓存：\(ByteCountFormatter.string(fromByteCount: Int64(cache.cacheBytes), countStyle: .file))")
                .font(.headline)
            HStack {
                Text("缓存上限")
                TextField("200", text: $controls.limitText).textFieldStyle(.roundedBorder).frame(width: 110)
                Text("MB")
                Button("保存") {
                    do {
                        guard let limit = Int(controls.limitText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                            throw NSError(domain: "InvoiceCache", code: 1, userInfo: [NSLocalizedDescriptionKey: "请输入大于 0 的整数缓存上限。"])
                        }
                        try cache.setLimitMB(limit)
                        controls.limitText = String(cache.limitMB)
                    } catch { controls.error = error.localizedDescription }
                }
            }.disabled(cache.working)
            Text("默认上限为 200 MB。超过上限时，优先清理最久未使用的邮箱附件；软件运行时会定期检查，下载或预览后也会检查。")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Button(cache.working ? "正在清理…" : "清理全部可恢复缓存", role: .destructive) {
                controls.confirming = true
            }.disabled(cache.working || cache.cacheBytes == 0)
            Text("仅清理可从邮箱重新下载的附件。手动导入、压缩包内无法单独恢复的发票、项目副本和已导出文件不会清理；发票金额、抬头与项目归属也会保留。正在处理的文件暂不清理；再次下载需要邮箱原件仍可访问。")
                .font(.callout).foregroundStyle(.secondary)
            Text("缓存会移入废纸篓，可从废纸篓恢复。需要释放磁盘空间时，请自行检查并清空废纸篓。")
                .font(.caption).foregroundStyle(.secondary)
            if cache.suspendedAfterFailure {
                Button("重试自动清理") {
                    do { try cache.retryCleanup() } catch { controls.error = error.localizedDescription }
                }
            }
            if !cache.message.isEmpty { Text(cache.message).font(.caption).textSelection(.enabled) }
            Spacer()
        }
        .padding(24).frame(width: 620, height: 510)
        .onAppear { controls.limitText = String(cache.limitMB); cache.refresh() }
        .confirmationDialog("清理全部可恢复缓存？", isPresented: $controls.confirming, titleVisibility: .visible) {
            Button("移入废纸篓", role: .destructive) {
                do { try cache.clearAll() } catch { controls.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("只清理软件内可重新下载的邮箱附件，保留发票记录、项目资料和导出文件。") }
        .alert("操作未完成", isPresented: Binding(get: { controls.error != nil }, set: { if !$0 { controls.error = nil } })) {
            Button("确定", role: .cancel) { controls.error = nil }
        } message: { Text(controls.error ?? "") }
    }
}

@MainActor private final class InvoiceCacheSettingsControls: ObservableObject {
    @Published var limitText = "200"
    @Published var confirming = false
    @Published var error: String?
}
