import Combine
import Foundation
import SwiftUI

@MainActor final class MailboxSyncController: ObservableObject {
    @Published private(set) var syncing = false
    @Published private(set) var configurationGeneration = 0
    @Published private(set) var lastSyncAt = UserDefaults.standard.object(forKey: "reimbursement.mail.lastSync." + QQMailboxConfiguration.address) as? Date
    var onNewInvoices: ((Int, Bool) -> Void)?
    @Published private(set) var status = "连接 QQ 邮箱后，新收到的发票附件会自动下载并识别。"
    @Published private(set) var manualMessages: [MailboxManualNotice] = []

    func configurationChanged() {
        configurationGeneration += 1
        manualMessages = Self.notices(account: QQMailboxConfiguration.address)
        lastSyncAt = UserDefaults.standard.object(forKey: "reimbursement.mail.lastSync." + QQMailboxConfiguration.address) as? Date
        status = QQMailboxConfiguration.enabled ? "邮箱配置已保存，等待同步邮件信息。" : "自动收集已关闭，已有发票保留。"
    }

    func run(inbox: InvoiceInboxStore) async {
        while !Task.isCancelled {
            if QQMailboxConfiguration.enabled { await sync(inbox: inbox) }
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
        }
    }

    func sync(inbox: InvoiceInboxStore) async {
        guard !syncing else { return }
        guard QQMailboxConfiguration.enabled else { status = "请先在“设置 → QQ 邮箱”中连接并启用邮箱。"; return }
        syncing = true
        defer { syncing = false }
        let revision = QQMailboxConfiguration.revision
        do {
            let credentials = try QQMailboxConfiguration.credentials()
            let account = credentials.address
            let key = "reimbursement.mail.processed.\(account)"
            let processed = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            let since = QQMailboxConfiguration.since
            let pendingKey = "reimbursement.mail.pendingNotificationCount.\(account)"
            let automaticKey = "reimbursement.mail.automaticDownloadsSince.\(account)"
            let automaticSince = UserDefaults.standard.object(forKey: automaticKey) as? Date ?? Date()
            UserDefaults.standard.set(automaticSince, forKey: automaticKey)
            manualMessages = Self.notices(account: account)
            status = "正在收集邮件并准备识别新发票…"
            try await QQMailboxClient.fetch(credentials: credentials, since: since,
                excluding: processed) { message in
                try await MainActor.run {
                    guard QQMailboxConfiguration.revision == revision, QQMailboxConfiguration.enabled else {
                        throw CancellationError()
                    }
                    if !message.attachments.isEmpty {
                        let before = inbox.items.count
                        let automatic = message.receivedAt >= automaticSince
                        try inbox.registerRemote(message, automaticallyDownload: automatic)
                        if !automatic {
                            let added = max(0, inbox.items.count - before)
                            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: pendingKey) + added, forKey: pendingKey)
                        }
                    }
                    if message.attachments.isEmpty && message.hasDownloadLink {
                        if !self.manualMessages.contains(where: { $0.id == message.id }) {
                            self.manualMessages.append(MailboxManualNotice(id: message.id, subject: message.subject,
                                sender: message.sender, receivedAt: message.receivedAt))
                            try Self.saveNotices(self.manualMessages, account: account)
                        }
                    }
                    var handled = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
                    handled.insert(message.id)
                    UserDefaults.standard.set(Array(handled), forKey: key)
                }
            }
            guard QQMailboxConfiguration.revision == revision else { status = "邮箱配置已变更，请重新同步。"; return }
            lastSyncAt = Date()
            UserDefaults.standard.set(lastSyncAt, forKey: "reimbursement.mail.lastSync.\(account)")
            let pending = UserDefaults.standard.integer(forKey: pendingKey)
            if pending > 0 { onNewInvoices?(pending, true) }
            UserDefaults.standard.set(0, forKey: pendingKey)
            status = "正在自动下载并识别新附件…"
            let result = await inbox.downloadPendingAttachments(account: account) {
                QQMailboxConfiguration.revision == revision && QQMailboxConfiguration.enabled && !Task.isCancelled
            }
            guard QQMailboxConfiguration.revision == revision, QQMailboxConfiguration.enabled, !Task.isCancelled else {
                throw CancellationError()
            }
            if result.accepted > 0 { onNewInvoices?(result.accepted, false) }
            status = "同步完成，自动识别入箱 \(result.accepted) 张发票。"
                + (pending > 0 ? "另有 \(pending) 个历史附件可按需下载。" : "")
                + (result.failed > 0 ? "\(result.failed) 个附件下载未完成，将在下次同步重试，也可手动下载。" : "")
        } catch is CancellationError {
            status = "同步已停止，已收集的信息保留。"
        } catch {
            status = "邮箱同步未完成：\(error.localizedDescription)；已收集的信息保留，可再次同步。"
        }
    }

    func dismissNotice(_ id: String) {
        let previous = manualMessages
        manualMessages.removeAll { $0.id == id }
        do { try Self.saveNotices(manualMessages, account: QQMailboxConfiguration.address) }
        catch { manualMessages = previous; status = "保存邮件处理状态失败：\(error.localizedDescription)" }
    }

    private static func notices(account: String) -> [MailboxManualNotice] {
        guard let data = UserDefaults.standard.data(forKey: "reimbursement.mail.manual.\(account)") else { return [] }
        return (try? JSONDecoder().decode([MailboxManualNotice].self, from: data)) ?? []
    }
    private static func saveNotices(_ notices: [MailboxManualNotice], account: String) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(notices), forKey: "reimbursement.mail.manual.\(account)")
    }
}

struct MailboxManualNotice: Identifiable, Codable {
    let id: String
    let subject: String
    let sender: String
    let receivedAt: Date
}

struct QQMailboxSettingsView: View {
    let saved: () -> Void
    @StateObject private var state = QQMailboxSettingsState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接 QQ 邮箱").font(.title2)
            Text("开启 QQ 邮箱的 IMAP 服务并生成授权码后填写。授权码不是 QQ 登录密码，只保存在 Mac 钥匙串中。")
                .foregroundStyle(.secondary)
            TextField("QQ 邮箱地址", text: $state.address).textFieldStyle(.roundedBorder)
            SecureField("邮箱授权码（留空保留此邮箱已保存的授权码）", text: $state.code).textFieldStyle(.roundedBorder)
            Toggle("启用自动收集发票", isOn: $state.enabled)
            DatePicker("从这个日期开始收集", selection: $state.since, in: ...Date(), displayedComponents: .date)
            Text("软件运行且电脑联网、未休眠时，每 5 分钟检查一次。新收到的发票附件自动下载并识别，合格发票进入发票箱，缓存按设置上限清理。启用前的历史附件仍按需下载。不会改变邮件已读状态或删除邮件。")
                .font(.callout).foregroundStyle(.secondary)
            if !state.message.isEmpty { Text(state.message).font(.callout).textSelection(.enabled) }
            HStack {
                Button(state.testing ? "正在测试…" : "测试连接") { state.test() }
                Spacer()
                Button("保存") {
                    do {
                        try QQMailboxConfiguration.save(address: state.address, authorizationCode: state.code,
                            enabled: state.enabled, since: state.since)
                        state.code = ""
                        state.message = "邮箱配置已保存。"
                        saved()
                    } catch { state.message = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 620)
        .disabled(state.testing)
    }
}

@MainActor private final class QQMailboxSettingsState: ObservableObject {
    @Published var address = QQMailboxConfiguration.address
    @Published var code = ""
    @Published var enabled = QQMailboxConfiguration.enabled
    @Published var since = QQMailboxConfiguration.since
    @Published var message = ""
    @Published var testing = false

    func test() {
        testing = true
        Task {
            defer { testing = false }
            do {
                let credentials: QQMailboxCredentials
                if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    credentials = try QQMailboxConfiguration.credentials()
                    guard credentials.address.caseInsensitiveCompare(address.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else {
                        throw NSError(domain: "MailboxSettings", code: 1, userInfo: [NSLocalizedDescriptionKey: "更换邮箱时请填写新邮箱的授权码。"])
                    }
                } else { credentials = try QQMailboxCredentials(address: address, authorizationCode: code) }
                try await QQMailboxClient.test(credentials: credentials)
                message = "连接成功。测试没有下载附件，保存后开始收集。"
            } catch { message = "连接失败：\(error.localizedDescription)" }
        }
    }
}
