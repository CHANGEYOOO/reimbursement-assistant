import Combine
import Foundation
import UserNotifications

// Pure policy shared by the mailbox batch and notification text.
enum InvoiceNotificationPolicy {
    static func isHistorical(since: Date, previousSince: Date?) -> Bool {
        guard let previousSince else { return true }
        return since < previousSince
    }

    static func text(count: Int, historical: Bool) -> (title: String, body: String)? {
        guard count > 0 else { return nil }
        return historical
            ? ("已收集 \(count) 个历史附件", "历史邮件附件已整理到待下载附件，尚未检查是否为发票。点击查看。")
            : ("收到 \(count) 张新发票", "已自动下载、识别并加入发票箱。点击查看。")
    }
}

@MainActor final class InvoiceNotificationController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private static let enabledKey = "reimbursement.mail.notificationsEnabled"
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var permissionMessage = ""
    var openInbox: (() -> Void)?
    private let center = UNUserNotificationCenter.current()
    private var preferenceRevision = 0

    override init() {
        super.init()
        center.delegate = self
    }

    func setEnabled(_ value: Bool) async {
        preferenceRevision += 1
        let revision = preferenceRevision
        if !value {
            enabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            permissionMessage = "新发票通知已关闭，后台收票不受影响。"
            return
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard preferenceRevision == revision else { return }
            enabled = granted
            UserDefaults.standard.set(granted, forKey: Self.enabledKey)
            permissionMessage = granted ? "新发票通知已开启。" : "请在系统设置 → 通知 → 报销单助手中允许通知。"
        } catch {
            guard preferenceRevision == revision else { return }
            permissionMessage = "无法开启通知：\(error.localizedDescription)"
        }
    }

    func notify(count: Int, historical: Bool) {
        guard enabled, let text = InvoiceNotificationPolicy.text(count: count, historical: historical) else { return }
        Task {
            let settings = await center.notificationSettings()
            guard enabled else { return }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                permissionMessage = "系统通知未允许，请在系统设置 → 通知 → 报销单助手中开启。"
                return
            }
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            content.sound = .default
            let request = UNNotificationRequest(identifier: "invoice-batch-\(UUID().uuidString)", content: content, trigger: nil)
            do { try await center.add(request) }
            catch { permissionMessage = "发送通知失败：\(error.localizedDescription)" }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { self.enabled ? [.banner, .sound] : [] }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { self.openInbox?() }
    }
}
